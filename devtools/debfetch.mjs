#!/usr/bin/env node
// Resolves a set of Debian packages to their shared-library closure, downloads the .debs
// (SHA256-checked) and unpacks their data members into one staging directory.
//   node debfetch.mjs --dest DIR --cache DIR [--suite trixie] [--mirror URL] pkg...
// Only library packages are followed (see isLibraryPackage): the result is a glibc
// library set to sit next to a musl userland, not a Debian system.
import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { gunzipSync } from 'node:zlib';

const args = process.argv.slice(2);
const opt = { suite: 'trixie', mirror: 'https://deb.debian.org/debian', arch: 'arm64' };
const roots = [];
for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) opt[a.slice(2)] = args[++i];
    else roots.push(a);
}
if (!opt.dest || !opt.cache || roots.length === 0) {
    console.error('usage: debfetch.mjs --dest DIR --cache DIR [--suite S] [--mirror URL] pkg...');
    process.exit(2);
}
// Never follow these even though they are named lib*: they are config/data or pull in
// a whole subsystem (perl, systemd) that a library consumer never loads.
const skip = new Set((opt.skip ?? '').split(',').filter(Boolean));

function isLibraryPackage(name) {
    if (skip.has(name)) return false;
    if (name === 'libc6' || name === 'zlib1g') return true;
    if (!name.startsWith('lib')) return false;
    return !/-(common|data|bin|dev|doc|utils|tools|locales)$/.test(name) && !name.startsWith('libperl');
}

function run(cmd, cmdArgs, input) {
    return new Promise((resolve, reject) => {
        const child = spawn(cmd, cmdArgs, { stdio: ['pipe', 'pipe', 'inherit'] });
        const out = [];
        child.stdout.on('data', (c) => out.push(c));
        child.on('error', reject);
        child.on('close', (code) => code === 0 ? resolve(Buffer.concat(out)) : reject(new Error(`${cmd} exited ${code}`)));
        child.stdin.end(input);
    });
}

async function fetchBuffer(url) {
    for (let attempt = 1; ; attempt++) {
        try {
            const res = await fetch(url);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            return Buffer.from(await res.arrayBuffer());
        } catch (err) {
            if (attempt >= 4) throw new Error(`${url}: ${err.message}`);
            await new Promise((r) => setTimeout(r, 1000 * attempt));
        }
    }
}

function parseIndex(text) {
    const packages = new Map();
    const provides = new Map();
    for (const stanza of text.split('\n\n')) {
        const fields = {};
        let key = null;
        for (const line of stanza.split('\n')) {
            if (line.startsWith(' ') && key) fields[key] += line;
            else {
                const at = line.indexOf(':');
                if (at < 0) continue;
                key = line.slice(0, at);
                fields[key] = line.slice(at + 1).trim();
            }
        }
        if (!fields.Package) continue;
        packages.set(fields.Package, fields);
        for (const p of (fields.Provides ?? '').split(',')) {
            const name = p.trim().split(/[ (]/)[0];
            if (name && !provides.has(name)) provides.set(name, fields.Package);
        }
    }
    return { packages, provides };
}

function dependencyNames(fields) {
    const groups = [fields['Pre-Depends'], fields.Depends].filter(Boolean).join(',').split(',');
    return groups.map((g) => g.split('|').map((alt) => alt.trim().split(/[ (:]/)[0]).filter(Boolean)).filter((g) => g.length);
}

function resolveClosure(index) {
    const chosen = new Map();
    const queue = [...roots];
    const pick = (alternatives) => {
        for (const alt of alternatives) {
            if (index.packages.has(alt)) return alt;
            if (index.provides.has(alt)) return index.provides.get(alt);
        }
        return null;
    };
    while (queue.length) {
        const name = queue.shift();
        if (chosen.has(name)) continue;
        const fields = index.packages.get(name) ?? index.packages.get(index.provides.get(name));
        if (!fields) throw new Error(`package not found: ${name}`);
        chosen.set(fields.Package, fields);
        for (const group of dependencyNames(fields)) {
            const dep = pick(group);
            if (dep && isLibraryPackage(dep) && !chosen.has(dep)) queue.push(dep);
        }
    }
    return [...chosen.values()];
}

// .deb files are `ar` archives: "!<arch>\n", then 60-byte headers, 2-byte aligned members.
function arMembers(buf) {
    if (buf.toString('latin1', 0, 8) !== '!<arch>\n') throw new Error('not an ar archive');
    const members = new Map();
    for (let off = 8; off + 60 <= buf.length;) {
        const name = buf.toString('latin1', off, off + 16).trim().replace(/\/$/, '');
        const size = parseInt(buf.toString('latin1', off + 48, off + 58).trim(), 10);
        members.set(name, buf.subarray(off + 60, off + 60 + size));
        off += 60 + size + (size & 1);
    }
    return members;
}

async function unpackData(deb, dest) {
    const members = arMembers(deb);
    const [name, data] = [...members].find(([n]) => n.startsWith('data.tar')) ?? [];
    if (!data) throw new Error('no data member');
    let tar;
    if (name.endsWith('.xz')) tar = await run('xzcat', [], data);
    else if (name.endsWith('.gz')) tar = gunzipSync(data);
    else if (name.endsWith('.zst')) tar = await run('zstdcat', [], data);
    else tar = data;
    await run('tar', ['-x', '-C', dest], tar);
}

mkdirSync(opt.cache, { recursive: true });
mkdirSync(opt.dest, { recursive: true });
const indexPath = join(opt.cache, `Packages-${opt.suite}-${opt.arch}`);
if (!existsSync(indexPath)) {
    const xz = await fetchBuffer(`${opt.mirror}/dists/${opt.suite}/main/binary-${opt.arch}/Packages.xz`);
    writeFileSync(indexPath, await run('xzcat', [], xz));
}
const selected = resolveClosure(parseIndex(readFileSync(indexPath, 'utf8')));
console.log(`resolved ${selected.length} packages`);

const queue = [...selected];
let downloaded = 0;
async function worker() {
    for (let fields; (fields = queue.shift());) {
        const file = join(opt.cache, fields.Filename.split('/').pop());
        let deb = existsSync(file) ? readFileSync(file) : null;
        const sha = (b) => createHash('sha256').update(b).digest('hex');
        if (!deb || sha(deb) !== fields.SHA256) {
            deb = await fetchBuffer(`${opt.mirror}/${fields.Filename}`);
            if (sha(deb) !== fields.SHA256) throw new Error(`checksum mismatch: ${fields.Package}`);
            writeFileSync(file, deb);
            downloaded += deb.length;
        }
        await unpackData(deb, opt.dest);
    }
}
await Promise.all(Array.from({ length: 4 }, worker));
writeFileSync(join(opt.dest, '.packages'), selected.map((f) => `${f.Package} ${f.Version}`).sort().join('\n') + '\n');
console.log(`unpacked into ${opt.dest} (${(downloaded / 1048576).toFixed(1)} MB downloaded)`);

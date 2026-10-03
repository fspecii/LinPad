#!/usr/bin/env node
// Builds LinPad Store's app index (store-index.json) from
//   - Alpine's APKINDEX (main + community): version, licence, sizes, dependencies;
//   - Alpine's AppStream catalog (appstream.alpinelinux.org): names, descriptions,
//     categories, icons and screenshots of every package with a desktop app;
//   - the packages that ship /usr/share/applications/*.desktop without AppStream data
//     (pkgs.alpinelinux.org file search, at build time only);
//   - LinPad's own catalog.json packs and curation.json (collections, compatibility).
//
//   Build (host):  node linpad-store-index.mjs build [--out FILE] [--cache DIR] [--offline]
//   Refresh (guest, `linpad-apps refresh-index`):
//                  node linpad-store-index.mjs refresh [--base FILE] [--out FILE]
//     reads the local APKINDEX caches that `apk update` wrote, re-downloads AppStream
//     only when it changed (ETag), and reuses the base index's desktop-file list.
//
// AppStream metadata is CC0-1.0 per the AppStream specification; icons and screenshots
// stay on Alpine's media server and are fetched by the desktop on demand.
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BRANCH = 'v3.21';
const ARCH = 'aarch64';
const REPOS = ['main', 'community'];
const MIRROR = 'https://dl-cdn.alpinelinux.org/alpine';
const APPSTREAM = 'https://appstream.alpinelinux.org/data';
const MEDIA = `https://appstream.alpinelinux.org/media/${BRANCH}`;
const CONTENTS = 'https://pkgs.alpinelinux.org/contents';
const DESCRIPTION_LIMIT = 1600;
const SCREENSHOT_LIMIT = 5;

// ---------------------------------------------------------------- APKINDEX

/** apk's cache file name for a package: name-version.<first 4 checksum bytes, hex>.apk */
export function cacheFileName(pkg) {
    const hash = pkg.checksum.startsWith('Q1') ? Buffer.from(pkg.checksum.slice(2), 'base64').subarray(0, 4).toString('hex') : '';
    return `${pkg.name}-${pkg.version}.${hash}.apk`;
}

/** name -> contents of every regular file in a .tar.gz (one or more gzip members). */
export function readTarGz(gz) {
    const tar = zlib.gunzipSync(gz);
    const files = new Map();
    for (let offset = 0; offset + 512 <= tar.length;) {
        const name = tar.toString('latin1', offset, offset + 100).replace(/\0.*$/s, '');
        if (!name) break;
        const size = parseInt(tar.toString('latin1', offset + 124, offset + 136).replace(/\0.*$/s, '').trim() || '0', 8);
        const type = tar.toString('latin1', offset + 156, offset + 157);
        const body = offset + 512;
        if (type === '0' || type === '\0') files.set(name.replace(/^\.\//, ''), tar.subarray(body, body + size));
        offset = body + Math.ceil(size / 512) * 512;
    }
    return files;
}

/** Parses an APKINDEX.tar.gz (two concatenated gzip members) into name -> package. */
export function parseApkIndex(gz, repo) {
    const tar = zlib.gunzipSync(gz);
    const packages = new Map();
    for (let offset = 0; offset + 512 <= tar.length;) {
        const name = tar.toString('latin1', offset, offset + 100).replace(/\0.*$/s, '');
        if (!name) break;
        const size = parseInt(tar.toString('latin1', offset + 124, offset + 136).replace(/\0.*$/s, '').trim() || '0', 8);
        const body = offset + 512;
        if (name === 'APKINDEX') parseIndexText(tar.toString('utf8', body, body + size), repo, packages);
        offset = body + Math.ceil(size / 512) * 512;
    }
    return packages;
}

export function parseIndexText(text, repo, packages = new Map()) {
    for (const record of text.split('\n\n')) {
        const fields = {};
        for (const line of record.split('\n')) {
            if (line[1] !== ':') continue;
            fields[line[0]] = line.slice(2);
        }
        if (!fields.P) continue;
        packages.set(fields.P, {
            name: fields.P,
            version: fields.V || '',
            summary: fields.T || '',
            homepage: fields.U || '',
            license: fields.L || '',
            origin: fields.o || fields.P,
            downloadBytes: Number(fields.S || 0),
            installedBytes: Number(fields.I || 0),
            depends: (fields.D || '').split(' ').filter(Boolean),
            checksum: fields.C || '',
            repo,
        });
    }
    return packages;
}

// ---------------------------------------------------------------- AppStream XML

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'" };
function decode(text) {
    return text.replace(/&(#x[0-9a-f]+|#\d+|\w+);/gi, (m, e) => {
        if (e[0] === '#') return String.fromCodePoint(e[1] === 'x' || e[1] === 'X' ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10));
        return ENTITIES[e] ?? m;
    });
}

/** A small XML reader, enough for AppStream catalogs: elements, attributes, text. */
export function parseXml(xml) {
    const root = { tag: '#root', attrs: {}, children: [], text: '' };
    const stack = [root];
    const re = /<!--[\s\S]*?-->|<\?[\s\S]*?\?>|<!\[CDATA\[([\s\S]*?)\]\]>|<\/([\w:.-]+)\s*>|<([\w:.-]+)((?:\s+[\w:.-]+\s*=\s*(?:"[^"]*"|'[^']*'))*)\s*(\/?)>|([^<]+)/g;
    let m;
    while ((m = re.exec(xml))) {
        const top = stack[stack.length - 1];
        if (m[1] !== undefined) top.text += m[1];
        else if (m[2]) { if (stack.length > 1) stack.pop(); }
        else if (m[3]) {
            const attrs = {};
            for (const a of m[4].matchAll(/([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)) attrs[a[1]] = decode(a[2] ?? a[3]);
            const node = { tag: m[3], attrs, children: [], text: '' };
            top.children.push(node);
            if (!m[5]) stack.push(node);
        } else if (m[6]) top.text += decode(m[6]);
    }
    return root;
}

const child = (node, tag, pred = () => true) => node.children.find(c => c.tag === tag && pred(c));
const childrenOf = (node, tag) => node.children.filter(c => c.tag === tag);
const unlocalized = c => !c.attrs['xml:lang'];
const clean = s => s.replace(/\s+/g, ' ').trim();

function inlineText(node) {
    return clean(node.text + node.children.map(inlineText).join(' '));
}

/** <description> as plain text: paragraphs, and list items as bullets. */
export function descriptionText(node) {
    if (!node) return '';
    const parts = [];
    for (const c of node.children) {
        if (!unlocalized(c)) continue;
        if (c.tag === 'p') parts.push(inlineText(c));
        else if (c.tag === 'ul' || c.tag === 'ol') {
            parts.push(childrenOf(c, 'li').filter(unlocalized).map(li => `• ${inlineText(li)}`).join('\n'));
        }
    }
    let text = parts.filter(Boolean).join('\n\n');
    if (text.length > DESCRIPTION_LIMIT) text = text.slice(0, text.lastIndexOf(' ', DESCRIPTION_LIMIT)) + '…';
    return text;
}

/** desktop-application components of one catalog. */
export function parseAppStream(xml) {
    const root = parseXml(xml);
    const components = child(root, 'components');
    if (!components) return [];
    const apps = [];
    for (const c of childrenOf(components, 'component')) {
        if (c.attrs.type !== 'desktop-application') continue;
        const pkg = child(c, 'pkgname')?.text.trim();
        if (!pkg) continue;
        const icons = childrenOf(c, 'icon');
        const remote = icons.filter(i => i.attrs.type === 'remote')
            .sort((a, b) => Number(b.attrs.width || 0) - Number(a.attrs.width || 0));
        const shots = [];
        for (const s of childrenOf(child(c, 'screenshots') || { children: [] }, 'screenshot')) {
            const images = childrenOf(s, 'image');
            const source = images.find(i => i.attrs.type === 'source');
            const thumbs = images.filter(i => i.attrs.type === 'thumbnail')
                .sort((a, b) => Math.abs(Number(a.attrs.width) - 752) - Math.abs(Number(b.attrs.width) - 752));
            const pick = thumbs[0] || source;
            if (!pick) continue;
            const entry = { url: pick.text.trim(), w: Number(pick.attrs.width || 0), h: Number(pick.attrs.height || 0) };
            if (source && source !== pick) entry.full = source.text.trim();
            const caption = child(s, 'caption', unlocalized);
            if (caption) entry.caption = clean(caption.text);
            if (s.attrs.type === 'default') shots.unshift(entry); else shots.push(entry);
        }
        apps.push({
            appstreamID: child(c, 'id')?.text.trim() || '',
            pkg,
            name: clean(child(c, 'name', unlocalized)?.text || pkg),
            summary: clean(child(c, 'summary', unlocalized)?.text || ''),
            description: descriptionText(childrenOf(c, 'description').find(unlocalized)),
            license: child(c, 'project_license')?.text.trim() || '',
            homepage: child(c, 'url', u => u.attrs.type === 'homepage')?.text.trim() || '',
            categories: childrenOf(child(c, 'categories') || { children: [] }, 'category').map(x => x.text.trim()),
            keywords: childrenOf(childrenOf(c, 'keywords').find(unlocalized) || { children: [] }, 'keyword')
                .filter(unlocalized).map(k => clean(k.text)).slice(0, 12),
            desktopID: child(c, 'launchable', l => l.attrs.type === 'desktop-id')?.text.trim().replace(/\.desktop$/, '')
                || child(c, 'id')?.text.trim().replace(/\.desktop$/, '') || pkg,
            stockIcon: icons.find(i => i.attrs.type === 'stock')?.text.trim() || '',
            icon: remote[0]?.text.trim() || '',
            cachedIcon: icons.find(i => i.attrs.type === 'cached')?.text.trim() || '',
            binaries: childrenOf(child(c, 'provides') || { children: [] }, 'binary').map(b => b.text.trim()),
            screenshots: shots.slice(0, SCREENSHOT_LIMIT),
        });
    }
    return apps;
}

// ---------------------------------------------------------------- classification

const CATEGORY_ORDER = [
    ['Game', 'Games'], ['AudioVideo', 'Audio & Video'], ['Audio', 'Audio & Video'], ['Video', 'Audio & Video'],
    ['Graphics', 'Graphics'], ['Office', 'Office'], ['Development', 'Developer tools'], ['Network', 'Internet'],
    ['Education', 'Education & Science'], ['Science', 'Education & Science'], ['Utility', 'Utilities'],
    ['Settings', 'System'], ['System', 'System'],
];
const PACK_CATEGORIES = {
    Mail: 'Internet', Internet: 'Internet', Office: 'Office', Graphics: 'Graphics', Utilities: 'Utilities',
    Development: 'Developer tools', Multimedia: 'Audio & Video',
};
export const STORE_CATEGORIES = ['Internet', 'Office', 'Graphics', 'Audio & Video', 'Developer tools', 'Games',
    'Education & Science', 'Utilities', 'System', 'Windows apps'];

export function storeCategory(freedesktop) {
    for (const [key, name] of CATEGORY_ORDER) if (freedesktop.includes(key)) return name;
    return 'Utilities';
}

/** What a package needs to show a window under LinPad's Wayland bridge. */
export function toolkitOf(depends) {
    const has = re => depends.some(d => re.test(d));
    if (has(/^so:libgtk-4\.so/)) return 'gtk4';
    if (has(/^so:libgtk-3\.so/) || has(/^so:libwx_gtk3/)) return 'gtk3';
    if (has(/^so:libQt6(Gui|Widgets|Quick)\.so/)) return 'qt6';
    if (has(/^so:libQt5(Gui|Widgets|Quick)\.so/)) return 'qt5';
    // Alpine's SDL 1.2 is sdl12-compat on SDL2, so SDL 1.2 games run on Wayland too.
    if (has(/^so:libSDL2-2\.0\.so/) || has(/^so:libSDL3/) || has(/^so:libSDL-1\.2\.so/)) return 'sdl';
    if (has(/^so:libgtk-x11-2\.0\.so/)) return 'gtk2';
    if (has(/^so:libX11\.so/) || has(/^so:libfltk/) || has(/^so:libtk8/) || has(/^so:libXm\.so/)) return 'x11';
    return 'other';
}

/** Extra packages and the X11 launch rule a toolkit needs on LinPad. */
export function launchNeeds(toolkit) {
    switch (toolkit) {
    case 'qt5': return { extras: ['qt5-qtwayland'], x11: false };
    case 'qt6': return { extras: ['qt6-qtwayland'], x11: false };
    case 'gtk2': case 'x11': return { extras: ['xwayland'], x11: true };
    default: return { extras: [], x11: false };
    }
}

const SKIP_SUFFIXES = /-(doc|dev|dbg|lang|static|openrc|bash-completion|zsh-completion|fish-completion|libs|pyc)$/;

// ---------------------------------------------------------------- merge

/**
 * The store index. `apkIndex`: name -> package; `components`: parseAppStream output;
 * `desktopFiles`: package -> [desktop ids] (packages with a .desktop file, AppStream or not);
 * `catalog`: catalog.json; `curation`: curation.json.
 */
export function buildIndex({ apkIndex, components, desktopFiles, catalog, curation, generated, appstreamETags = {}, extra = {} }) {
    const apps = new Map();
    const curated = new Set(curatedRefs(curation));
    const packs = catalog.packs || [];
    const packByPackage = new Map();
    for (const pack of packs) for (const p of pack.packages || []) if (!packByPackage.has(p)) packByPackage.set(p, pack);

    const componentsByPkg = new Map();
    for (const c of components) {
        if (!componentsByPkg.has(c.pkg)) componentsByPkg.set(c.pkg, []);
        componentsByPkg.get(c.pkg).push(c);
    }
    const primary = (pkg, list) => list.slice().sort((a, b) => score(b) - score(a))[0];
    function score(c) {
        let s = c.screenshots.length ? 4 : 0;
        if (c.desktopID.toLowerCase().includes(c.pkg.toLowerCase())) s += 3;
        if (c.description) s += 2;
        if (c.icon) s += 1;
        if (/settings|preferences|-url-handler/i.test(c.desktopID)) s -= 5;
        return s;
    }

    for (const pack of packs) {
        const meta = (pack.packages || []).map(p => componentsByPkg.get(p)).find(Boolean);
        const c = meta && primary(pack.packages[0], meta.filter(x => !pack.desktop || x.desktopID === pack.desktop.replace(/\.desktop$/, '')).length
            ? meta.filter(x => x.desktopID === pack.desktop.replace(/\.desktop$/, '')) : meta);
        const main = (pack.packages || []).map(p => apkIndex.get(p)).find(Boolean);
        apps.set(`pack:${pack.id}`, compact({
            id: pack.id,
            kind: 'pack',
            name: pack.name,
            summary: pack.description.split(/(?<=\.)\s/)[0],
            description: [pack.description, c?.description].filter(Boolean).join('\n\n'),
            category: pack.id.startsWith('wine') ? 'Windows apps' : (PACK_CATEGORIES[pack.category] || pack.category),
            packages: pack.packages,
            version: main?.version,
            license: c?.license || main?.license || (pack.installer ? 'See the vendor' : ''),
            homepage: c?.homepage || main?.homepage,
            appstreamID: c?.appstreamID,
            sizeMB: pack.sizeMB,
            desktopID: pack.desktop ? pack.desktop.replace(/\.desktop$/, '') : (c?.desktopID),
            iconNames: uniq([pack.icon, c?.stockIcon, c?.desktopID].filter(Boolean)),
            icon: c?.icon,
            screenshots: c?.screenshots,
            keywords: c?.keywords,
            cli: pack.cli || undefined,
            experimental: pack.experimental || undefined,
        }));
    }

    const candidates = new Set([...componentsByPkg.keys(), ...Object.keys(desktopFiles)]);
    for (const pkg of candidates) {
        const apk = apkIndex.get(pkg);
        if (!apk || SKIP_SUFFIXES.test(pkg) || packByPackage.has(pkg)) continue;
        const list = componentsByPkg.get(pkg);
        const c = list && primary(pkg, list);
        const desktopIDs = desktopFiles[pkg] || (c ? [c.desktopID] : []);
        if (!c && !desktopIDs.length) continue;
        if (!c && HELPER_PACKAGES.test(pkg) && !curated.has(pkg)) continue;
        const toolkit = toolkitOf(apk.depends);
        const needs = launchNeeds(toolkit);
        const desktopID = c?.desktopID || pickDesktop(pkg, desktopIDs);
        apps.set(pkg, compact({
            id: `apk:${pkg}`,
            kind: 'apk',
            name: c?.name || prettyName(desktopID, pkg),
            summary: c?.summary || capitalize(apk.summary),
            description: c?.description || capitalize(apk.summary),
            category: c ? storeCategory(c.categories) : guessCategory(pkg, apk),
            packages: [pkg, ...needs.extras],
            version: apk.version,
            license: c?.license || apk.license,
            homepage: c?.homepage || apk.homepage,
            appstreamID: c?.appstreamID,
            downloadBytes: apk.downloadBytes,
            installedBytes: apk.installedBytes,
            desktopID,
            iconNames: uniq([c?.stockIcon, desktopID, pkg].filter(Boolean)),
            icon: c?.icon,
            screenshots: c?.screenshots,
            keywords: c?.keywords,
            toolkit,
            x11: needs.x11 || undefined,
            metadata: c ? undefined : 'package',
        }));
    }

    const resolve = ref => apps.get(ref);
    for (const [ref, more] of Object.entries(extra)) {
        const app = resolve(ref);
        if (!app) continue;
        if (!app.screenshots && more.screenshots?.length) app.screenshots = more.screenshots;
        if (more.description && more.description.length > (app.kind === 'pack' ? 0 : (app.description || '').length + 40)) {
            app.description = app.kind === 'pack' ? `${app.description.split('\n\n')[0]}\n\n${more.description}` : more.description;
        }
        if (!app.icon && more.icon) app.icon = more.icon;
        app.metadataSource = 'flathub';
    }
    const missing = [];
    const compat = curation.compat || {};
    for (const [ref, entry] of Object.entries(compat)) {
        const app = resolve(ref);
        if (!app) { missing.push(ref); continue; }
        app.compat = entry.status;
        if (entry.note) app.compatNote = entry.note;
    }
    // Store fixups: a script in fixups/ (and its arguments) linpad-apps runs after
    // installing the app and before removing it, for apps that need help to run on iSH.
    for (const [ref, fixup] of Object.entries(curation.fixups || {})) {
        const app = resolve(ref);
        if (app) app.fixup = fixup; else missing.push(ref);
    }
    const collections = (curation.collections || []).map(col => ({
        id: col.id, title: col.title, subtitle: col.subtitle,
        apps: col.apps.map(ref => { const a = resolve(ref); if (!a) missing.push(ref); return a?.id; }).filter(Boolean),
    }));
    const hero = (curation.hero || []).map(h => { const a = resolve(h.app); if (!a) missing.push(h.app); return a && { ...h, app: a.id }; }).filter(Boolean);
    const featured = new Set(collections.flatMap(c => c.apps));
    const list = [...apps.values()].sort((a, b) =>
        (featured.has(b.id) - featured.has(a.id)) || (b.screenshots ? 1 : 0) - (a.screenshots ? 1 : 0) || a.name.localeCompare(b.name));
    return {
        index: compact({
            format: 1,
            generated,
            branch: BRANCH,
            arch: ARCH,
            mediaBase: MEDIA,
            warnSizeMB: curation.warnSizeMB || 400,
            categories: STORE_CATEGORIES,
            hero,
            collections,
            apps: list,
            desktopFiles,
            appstreamETags,
        }),
        missing: uniq(missing),
    };
}

/** Desktop-file-only packages that are plug-ins, wizards or phone/watch shells, not apps. */
const HELPER_PACKAGES = /^(asteroid-|qt[56]-|kdepim-|akonadi|plasma-|kf[56]-|lxqt-|xfce4-.*-plugin|mate-|gnome-shell|phosh|sxmo)|-(config|settings|plugin|wizard|daemon|runtime)$/;

export function curatedRefs(curation) {
    return [
        ...(curation.hero || []).map(h => h.app),
        ...(curation.collections || []).flatMap(c => c.apps),
        ...Object.keys(curation.compat || {}),
    ];
}

function pickDesktop(pkg, ids) {
    return ids.slice().sort((a, b) => (b.toLowerCase().includes(pkg) - a.toLowerCase().includes(pkg)) || a.length - b.length)[0];
}

function guessCategory(pkg, apk) {
    const text = `${pkg} ${apk.summary}`.toLowerCase();
    if (/game|puzzle|chess|solitaire|arcade/.test(text)) return 'Games';
    if (/audio|music|video|player|sound|media/.test(text)) return 'Audio & Video';
    if (/image|photo|paint|draw|graphic/.test(text)) return 'Graphics';
    if (/editor|ide|debug|git|develop|compiler/.test(text)) return 'Developer tools';
    if (/mail|browser|chat|irc|ftp|torrent|network|web/.test(text)) return 'Internet';
    if (/office|document|spreadsheet|pdf|word/.test(text)) return 'Office';
    if (/settings|config|system|monitor|manager/.test(text)) return 'System';
    return 'Utilities';
}

function prettyName(desktopID, pkg) {
    const last = (desktopID || pkg).split('.').pop();
    return capitalize(last.replace(/[-_]+/g, ' '));
}

const capitalize = s => s ? s[0].toUpperCase() + s.slice(1) : s;
const uniq = xs => [...new Set(xs)];

/** Drops empty fields so the shipped JSON stays small. */
function compact(o) {
    for (const k of Object.keys(o)) {
        const v = o[k];
        if (v === undefined || v === null || v === '' || (Array.isArray(v) && !v.length)) delete o[k];
    }
    return o;
}

// ---------------------------------------------------------------- network + cache

async function fetchCached(url, file, { offline = false, etag } = {}) {
    if (offline) {
        if (fs.existsSync(file)) return { body: fs.readFileSync(file), etag, cached: true };
        throw new Error(`offline and no cached copy of ${url}`);
    }
    const headers = { 'user-agent': 'linpad-store-index/1' };
    if (etag && fs.existsSync(file)) headers['if-none-match'] = etag;
    const res = await fetch(url, { headers });
    if (res.status === 304) return { body: fs.readFileSync(file), etag, cached: true };
    if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
    const body = Buffer.from(await res.arrayBuffer());
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, body);
    return { body, etag: res.headers.get('etag') || undefined, cached: false };
}

/** package -> desktop ids, from the pkgs.alpinelinux.org file search (paginated HTML). */
async function fetchDesktopFiles(cacheDir, offline) {
    const result = {};
    for (const repo of REPOS) {
        for (let page = 1; page < 200; page++) {
            const url = `${CONTENTS}?file=*.desktop&path=/usr/share/applications&name=&branch=${BRANCH}&repo=${repo}&arch=${ARCH}&page=${page}`;
            const file = path.join(cacheDir, `contents-${repo}-${page}.html`);
            const html = fs.existsSync(file) ? fs.readFileSync(file, 'utf8')
                : (await fetchCached(url, file, { offline })).body.toString('utf8');
            let rows = 0;
            for (const m of html.matchAll(/<td[^>]*>\/usr\/share\/applications\/([^<]+)\.desktop<\/td>\s*<td>\s*<a href="[^"]*">([^<]+)<\/a>/g)) {
                (result[m[2]] ||= []).push(m[1]);
                rows++;
            }
            if (!rows) break;
        }
    }
    for (const k of Object.keys(result)) result[k] = uniq(result[k]).sort();
    return result;
}

/**
 * Flathub's AppStream API fills in screenshots and descriptions Alpine's catalog lacks, for
 * curated apps only (a few dozen requests, cached). Matched by AppStream id, or the
 * curation's "flathub" map. Metadata is the upstream projects' metainfo (CC0/FSFAP);
 * screenshots are linked, not copied.
 */
async function flathubExtras(index, curation, cacheDir, offline) {
    const extra = {};
    const wanted = new Set(curatedRefs(curation).map(r => (r.startsWith('pack:') ? r.slice(5) : `apk:${r}`)));
    for (const app of index.apps) {
        if (!wanted.has(app.id)) continue;
        if (app.screenshots && (app.description || '').length > 200) continue;
        const ref = app.kind === 'pack' ? `pack:${app.id}` : app.id.slice(4);
        const ids = uniq([curation.flathub?.[ref], app.appstreamID, app.desktopID].filter(id => id && id.split('.').length >= 3));
        for (const id of ids) {
            const file = path.join(cacheDir, 'flathub', `${id}.json`);
            let data;
            try {
                if (fs.existsSync(file)) data = JSON.parse(fs.readFileSync(file, 'utf8'));
                else if (!offline) {
                    const res = await fetch(`https://flathub.org/api/v2/appstream/${id}`, { headers: { 'user-agent': 'linpad-store-index/1' } });
                    data = res.ok ? await res.json() : null;
                    fs.mkdirSync(path.dirname(file), { recursive: true });
                    fs.writeFileSync(file, JSON.stringify(data));
                }
            } catch { data = null; }
            if (!data) continue;
            extra[ref] = {
                description: data.description ? descriptionText(parseXml(`<d>${data.description}</d>`).children[0]) : '',
                icon: data.icon || '',
                screenshots: (data.screenshots || []).slice(0, SCREENSHOT_LIMIT).map(s => {
                    const sizes = (s.sizes || []).filter(x => x.scale === '1x' || !x.scale);
                    const pick = sizes.slice().sort((a, b) => Math.abs(a.width - 752) - Math.abs(b.width - 752))[0];
                    const full = sizes.slice().sort((a, b) => b.width - a.width)[0];
                    return pick && compact({ url: pick.src, w: Number(pick.width), h: Number(pick.height), full: full?.src, caption: s.caption });
                }).filter(Boolean),
            };
            break;
        }
    }
    return extra;
}

// ---------------------------------------------------------------- commands

function argValue(args, name, fallback) {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : fallback;
}

async function loadAppStream(cacheDir, offline, etags) {
    const components = [];
    const newTags = {};
    for (const repo of REPOS) {
        const url = `${APPSTREAM}/${BRANCH}/${repo}/Components-${ARCH}.xml.gz`;
        const file = path.join(cacheDir, `Components-${repo}-${ARCH}.xml.gz`);
        try {
            const got = await fetchCached(url, file, { offline, etag: etags[repo] });
            if (got.etag) newTags[repo] = got.etag;
            components.push(...parseAppStream(zlib.gunzipSync(got.body).toString('utf8')));
        } catch (e) {
            process.stderr.write(`appstream ${repo}: ${e.message}\n`);
            return { components: null, etags };
        }
    }
    return { components, etags: newTags };
}

async function build(args) {
    const out = argValue(args, '--out', path.join(HERE, 'store-index.json'));
    const cacheDir = argValue(args, '--cache', path.join(process.env.TMPDIR || '/tmp', 'linpad-store-cache'));
    const offline = args.includes('--offline');
    const apkIndex = new Map();
    for (const repo of REPOS) {
        const got = await fetchCached(`${MIRROR}/${BRANCH}/${repo}/${ARCH}/APKINDEX.tar.gz`,
            path.join(cacheDir, `APKINDEX-${repo}.tar.gz`), { offline });
        for (const [k, v] of parseApkIndex(got.body, repo)) apkIndex.set(k, v);
    }
    const { components, etags } = await loadAppStream(cacheDir, offline, {});
    if (!components) throw new Error('AppStream catalog unavailable');
    for (const repo of REPOS) {
        await fetchCached(`${APPSTREAM}/${BRANCH}/${repo}/icons-64x64.tar.gz`, path.join(cacheDir, `icons-64x64-${repo}.tar.gz`), { offline })
            .catch(e => process.stderr.write(`icons ${repo}: ${e.message}\n`));
    }
    const desktopFiles = await fetchDesktopFiles(cacheDir, offline);
    const catalog = JSON.parse(fs.readFileSync(argValue(args, '--catalog', path.join(HERE, '..', 'catalog.json')), 'utf8'));
    const curation = JSON.parse(fs.readFileSync(argValue(args, '--curation', path.join(HERE, 'curation.json')), 'utf8'));
    const first = buildIndex({ apkIndex, components, desktopFiles, catalog, curation, generated: '', appstreamETags: etags });
    const extra = await flathubExtras(first.index, curation, cacheDir, offline);
    const { index, missing } = buildIndex({
        apkIndex, components, desktopFiles, catalog, curation,
        generated: new Date().toISOString(), appstreamETags: etags, extra,
    });
    write(out, index);
    // The desktop ships the same index, so the Store opens instantly and before Linux boots,
    // and the guest's icon cache renders the icons of the apps the Store features.
    // Alpine's media server lacks some apps' remote icons; the desktop bundles AppStream's
    // cached 64 px icons (Store/icons/<id>.png, id with ':' as '_') as the fallback.
    const iconDir = argValue(args, '--icon-dir', path.join(HERE, '..', '..', '..', '..', 'desktop', 'DesktopKit', 'Sources', 'DesktopKit', 'Resources', 'Store', 'icons'));
    if (iconDir !== 'none' && fs.existsSync(path.dirname(iconDir))) bundleIcons(index, components, cacheDir, iconDir, offline);
    const appCopy = argValue(args, '--app-copy', path.join(HERE, '..', '..', '..', '..', 'desktop', 'DesktopKit', 'Sources', 'DesktopKit', 'Resources', 'Store', 'store-index.json'));
    if (appCopy !== 'none' && fs.existsSync(path.dirname(appCopy))) write(appCopy, index);
    const featured = new Set([...index.collections.flatMap(c => c.apps), ...index.hero.map(h => h.app)]);
    const iconNames = uniq(index.apps.filter(a => featured.has(a.id)).map(a => a.iconNames?.[0]).filter(Boolean)).sort();
    fs.writeFileSync(path.join(path.dirname(out), 'store-icons.txt'), iconNames.join('\n') + '\n');
    report(index, missing);
}

function bundleIcons(index, components, cacheDir, iconDir, offline) {
    const cached = new Map();
    for (const repo of REPOS) {
        const file = path.join(cacheDir, `icons-64x64-${repo}.tar.gz`);
        if (!fs.existsSync(file)) continue;
        for (const [name, data] of readTarGz(fs.readFileSync(file))) cached.set(name, data);
    }
    const byPkg = new Map(components.filter(c => c.cachedIcon).map(c => [c.pkg, c.cachedIcon]));
    fs.rmSync(iconDir, { recursive: true, force: true });
    fs.mkdirSync(iconDir, { recursive: true });
    let count = 0;
    for (const app of index.apps) {
        const pkg = app.kind === 'apk' ? app.id.slice(4) : (app.packages || [])[0];
        const data = cached.get(byPkg.get(pkg));
        if (!data) continue;
        fs.writeFileSync(path.join(iconDir, `${app.id.replace(/[^A-Za-z0-9._-]/g, '_')}.png`), data);
        count++;
    }
    process.stdout.write(`${count} bundled icons\n`);
}

/** Guest refresh: local APKINDEX caches + (changed) AppStream; keeps the base index otherwise. */
async function refresh(args) {
    const base = JSON.parse(fs.readFileSync(argValue(args, '--base', '/usr/share/linpad/store-index.json'), 'utf8'));
    const out = argValue(args, '--out', '/var/lib/linpad/store-index.json');
    const cacheDir = argValue(args, '--cache', '/var/cache/linpad-store');
    const apkCache = argValue(args, '--apk-cache', '/var/cache/apk');
    const apkIndex = new Map();
    for (const f of fs.readdirSync(apkCache).filter(f => /^APKINDEX\..*\.tar\.gz$/.test(f))) {
        for (const [k, v] of parseApkIndex(fs.readFileSync(path.join(apkCache, f)), '')) {
            const old = apkIndex.get(k);
            if (!old || compareVersions(v.version, old.version) > 0) apkIndex.set(k, v);
        }
    }
    if (!apkIndex.size) throw new Error('no APKINDEX in ' + apkCache + '; run apk update');
    const previous = fs.existsSync(out) ? JSON.parse(fs.readFileSync(out, 'utf8')) : base;
    let { components, etags } = await loadAppStream(cacheDir, args.includes('--offline'), previous.appstreamETags || {});
    if (!components) {
        // Offline: keep the metadata of the index we have and refresh versions and sizes only.
        components = [];
        etags = previous.appstreamETags || {};
        for (const app of previous.apps) {
            const pkg = app.kind === 'apk' ? app.id.slice(4) : null;
            const live = pkg && apkIndex.get(pkg);
            if (live) Object.assign(app, { version: live.version, downloadBytes: live.downloadBytes, installedBytes: live.installedBytes });
        }
        previous.generated = new Date().toISOString();
        write(out, previous);
        return;
    }
    const catalog = JSON.parse(fs.readFileSync(argValue(args, '--catalog', '/usr/share/linpad/catalog.json'), 'utf8'));
    const curation = JSON.parse(fs.readFileSync(argValue(args, '--curation', '/usr/share/linpad/store-curation.json'), 'utf8'));
    const { index } = buildIndex({
        apkIndex, components, desktopFiles: base.desktopFiles || {}, catalog, curation,
        generated: new Date().toISOString(), appstreamETags: etags,
    });
    write(out, index);
    process.stdout.write(`==> Store index: ${index.apps.length} apps\n`);
}

/** apk version order, enough to pick the newer of two indexes' copies of a package. */
export function compareVersions(a, b) {
    const split = v => v.split(/[._-]|(?<=\d)(?=[a-z])|(?<=[a-z])(?=\d)/i).map(x => (/^\d+$/.test(x) ? Number(x) : x.replace(/^r/, '')));
    const x = split(a), y = split(b);
    for (let i = 0; i < Math.max(x.length, y.length); i++) {
        if (x[i] === undefined) return -1;
        if (y[i] === undefined) return 1;
        if (x[i] === y[i]) continue;
        const nx = Number(x[i]), ny = Number(y[i]);
        if (!Number.isNaN(nx) && !Number.isNaN(ny)) return nx < ny ? -1 : 1;
        return String(x[i]) < String(y[i]) ? -1 : 1;
    }
    return 0;
}

function write(out, index) {
    fs.mkdirSync(path.dirname(out), { recursive: true });
    const tmp = out + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(index));
    fs.renameSync(tmp, out);
}

function report(index, missing) {
    const byCategory = {};
    for (const a of index.apps) byCategory[a.category] = (byCategory[a.category] || 0) + 1;
    process.stdout.write(`${index.apps.length} apps (${index.apps.filter(a => a.screenshots).length} with screenshots)\n`);
    process.stdout.write(JSON.stringify(byCategory) + '\n');
    if (missing.length) process.stdout.write(`curation entries not in the index: ${missing.join(' ')}\n`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === fs.realpathSync(process.argv[1])) {
    const [command, ...args] = process.argv.slice(2);
    const run = { build, refresh }[command];
    if (!run) {
        process.stderr.write('usage: linpad-store-index.mjs build [--out F] [--cache D] [--offline] | refresh [--base F] [--out F]\n');
        process.exit(2);
    }
    run(args).catch(e => { process.stderr.write(`linpad-store-index: ${e.message}\n`); process.exit(1); });
}

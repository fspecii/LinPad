// node --test release/guest/linpad/store/tests/test-store-index.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';
import {
    buildIndex, cacheFileName, compareVersions, launchNeeds, parseApkIndex, parseAppStream,
    parseIndexText, storeCategory, toolkitOf,
} from '../linpad-store-index.mjs';

const FIXTURES = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures');
const read = name => fs.readFileSync(path.join(FIXTURES, name), 'utf8');

function fixtureIndex() {
    return buildIndex({
        apkIndex: parseIndexText(read('APKINDEX'), 'community'),
        components: parseAppStream(read('Components.xml')),
        desktopFiles: { filezilla: ['filezilla'], dillo: ['dillo'], qtapp: ['org.example.QtApp'], 'asteroid-calculator': ['asteroid-calculator'], 'filezilla-doc': ['x'] },
        catalog: JSON.parse(read('catalog.json')),
        curation: JSON.parse(read('curation.json')),
        generated: '2026-10-03T00:00:00.000Z',
    });
}

/** A minimal APKINDEX.tar.gz: a signature member, then the index member. */
function apkIndexArchive(text) {
    const entry = (name, body) => {
        const header = Buffer.alloc(512);
        header.write(name, 0);
        header.write('0000644\0', 100);
        header.write(body.length.toString(8).padStart(11, '0') + '\0', 124);
        header.write('ustar\0', 257);
        const padded = Buffer.alloc(Math.ceil(body.length / 512) * 512);
        body.copy(padded);
        return Buffer.concat([header, padded]);
    };
    const signature = zlib.gzipSync(entry('.SIGN.RSA.key.pub', Buffer.from('sig')));
    const index = zlib.gzipSync(Buffer.concat([entry('DESCRIPTION', Buffer.from('v3.21')), entry('APKINDEX', Buffer.from(text)), Buffer.alloc(1024)]));
    return Buffer.concat([signature, index]);
}

test('APKINDEX archives with two gzip members parse', () => {
    const packages = parseApkIndex(apkIndexArchive(read('APKINDEX')), 'community');
    const filezilla = packages.get('filezilla');
    assert.equal(filezilla.version, '3.68.1-r0');
    assert.equal(filezilla.downloadBytes, 2729453);
    assert.equal(filezilla.installedBytes, 5714655);
    assert.equal(filezilla.license, 'GPL-2.0-or-later');
    assert.ok(filezilla.depends.includes('so:libgtk-3.so.0'));
    assert.equal(packages.size, 6);
});

test("apk's cache file name comes from the checksum", () => {
    const packages = parseIndexText(read('APKINDEX'), 'community');
    assert.equal(cacheFileName(packages.get('filezilla')), 'filezilla-3.68.1-r0.5289ae73.apk');
    assert.equal(cacheFileName(packages.get('dillo')), 'dillo-3.1.1-r0.55707f29.apk');
});

test('AppStream: unlocalized text, entities, bullets, best icon, default screenshot first', () => {
    const [filezilla, gimp, ...rest] = parseAppStream(read('Components.xml'));
    assert.equal(rest.length, 0, 'addons are skipped');
    assert.equal(filezilla.name, 'FileZilla');
    assert.equal(filezilla.summary, 'Download and upload files via FTP, FTPS and SFTP');
    assert.equal(filezilla.description, 'FileZilla Client is a fast & reliable cross-platform FTP client.\n\n• Easy to use\n• Supports SFTP');
    assert.equal(filezilla.icon, 'f/fi/filezilla/128x128/filezilla.png');
    assert.equal(filezilla.stockIcon, 'filezilla');
    assert.equal(filezilla.desktopID, 'filezilla');
    assert.deepEqual(filezilla.keywords, ['ftp', 'sftp']);
    assert.equal(filezilla.screenshots[0].url, 'f/fi/filezilla/screenshots/1_752x423.png');
    assert.equal(filezilla.screenshots[0].full, 'f/fi/filezilla/screenshots/1_orig.png');
    assert.equal(filezilla.screenshots[0].caption, 'Main window');
    assert.equal(filezilla.screenshots[1].url, 'f/fi/filezilla/screenshots/2_orig.png');
    assert.equal(gimp.desktopID, 'gimp');
});

test('categories and toolkits', () => {
    assert.equal(storeCategory(['Network', 'FileTransfer']), 'Internet');
    assert.equal(storeCategory(['AudioVideo', 'Audio']), 'Audio & Video');
    assert.equal(storeCategory(['Game', 'Graphics']), 'Games');
    assert.equal(storeCategory([]), 'Utilities');
    assert.equal(toolkitOf(['so:libgtk-3.so.0']), 'gtk3');
    assert.equal(toolkitOf(['so:libQt5Widgets.so.5']), 'qt5');
    assert.equal(toolkitOf(['so:libgtk-x11-2.0.so.0']), 'gtk2');
    assert.equal(toolkitOf(['so:libfltk.so.1.3', 'so:libX11.so.6']), 'x11');
    assert.deepEqual(launchNeeds('qt5'), { extras: ['qt5-qtwayland'], x11: false });
    assert.deepEqual(launchNeeds('x11'), { extras: ['xwayland'], x11: true });
});

test('the index merges packs, AppStream apps and desktop-only packages', () => {
    const { index, missing } = fixtureIndex();
    const ids = index.apps.map(a => a.id);
    assert.ok(ids.includes('image-editor'), 'catalog packs are apps');
    assert.ok(!ids.includes('apk:gimp'), 'a package a pack installs is not listed twice');
    assert.ok(!ids.includes('apk:filezilla-doc'), 'subpackages are skipped');
    assert.ok(!ids.includes('apk:asteroid-calculator'), 'helper/shell packages without AppStream are skipped');

    const filezilla = index.apps.find(a => a.id === 'apk:filezilla');
    assert.equal(filezilla.category, 'Internet');
    assert.equal(filezilla.version, '3.68.1-r0');
    assert.deepEqual(filezilla.packages, ['filezilla']);
    assert.equal(filezilla.compat, 'works');
    assert.equal(filezilla.compatNote, 'Tested.');
    assert.equal(filezilla.fixup, 'wrap filezilla --sysvipc');

    const dillo = index.apps.find(a => a.id === 'apk:dillo');
    assert.equal(dillo.metadata, 'package', 'no AppStream data: named from the package');
    assert.equal(dillo.x11, true);
    assert.deepEqual(dillo.packages, ['dillo', 'xwayland']);

    const qt = index.apps.find(a => a.id === 'apk:qtapp');
    assert.deepEqual(qt.packages, ['qtapp', 'qt5-qtwayland']);

    const gimp = index.apps.find(a => a.id === 'image-editor');
    assert.equal(gimp.kind, 'pack');
    assert.match(gimp.description, /^Raster image editor/);
    assert.equal(gimp.version, '2.10.38-r2');

    const wine = index.apps.find(a => a.id === 'wine');
    assert.equal(wine.category, 'Windows apps');
    assert.equal(wine.compat, 'experimental');

    assert.deepEqual(index.collections[0].apps, ['apk:filezilla', 'apk:dillo']);
    assert.deepEqual(index.collections[1].apps, ['wine']);
    assert.equal(index.hero[0].app, 'apk:filezilla');
    assert.deepEqual(missing, ['nonexistent']);
    assert.equal(index.generated, '2026-10-03T00:00:00.000Z');
    assert.ok(index.apps.findIndex(a => a.id === 'apk:filezilla') < index.apps.findIndex(a => a.id === 'apk:qtapp'), 'featured apps first');
});

test('apk version order', () => {
    assert.equal(compareVersions('3.68.1-r0', '3.68.1-r1'), -1);
    assert.equal(compareVersions('3.68.10-r0', '3.68.9-r0'), 1);
    assert.equal(compareVersions('1.0-r0', '1.0-r0'), 0);
});

test('the shipped index matches the curation and decodes', () => {
    const shipped = JSON.parse(fs.readFileSync(path.join(FIXTURES, '..', '..', 'store-index.json'), 'utf8'));
    const curation = JSON.parse(fs.readFileSync(path.join(FIXTURES, '..', '..', 'curation.json'), 'utf8'));
    assert.equal(shipped.collections.length, curation.collections.length);
    const ids = new Set(shipped.apps.map(a => a.id));
    for (const c of shipped.collections) for (const id of c.apps) assert.ok(ids.has(id), id);
    const audacity = shipped.apps.find(a => a.id === 'apk:audacity');
    assert.equal(audacity.fixup, 'wrap audacity --sysvipc --wayland --preload-svg');
});

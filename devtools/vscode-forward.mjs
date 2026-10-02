// `code FILE` while VS Code is running: hands the request straight to the running
// instance over its main IPC socket, the way a second Electron process would after starting
// up. Under emulation a second Electron start costs 20-60 s before it gets that far; this
// takes about a second.
//   node vscode-forward.mjs USER_DATA_DIR [args...]
// Exit 0: the running instance took the request. Exit 3: nothing to forward to, or an
// argument this does not handle; the caller starts Electron normally.
//
// Speaks VS Code's internal IPC (src/vs/base/parts/ipc: ipc.ts serialization, ipc.net.ts
// framing) to the "launch" channel's start(args, env), the same call
// CodeMain.claimInstance makes. Checked against VS Code 1.140.
import { createHash } from 'node:crypto';
import { readdirSync } from 'node:fs';
import { connect } from 'node:net';
import { join, resolve } from 'node:path';

const FALLBACK = 3;
const [userDataDir, ...argv] = process.argv.slice(2);

// Only the forms a terminal user types; anything else goes through Electron.
const args = { _: [], goto: false, 'reuse-window': false, 'new-window': false, add: false,
    diff: false, merge: false, remove: false, wait: false };
for (const arg of argv) {
    if (arg === '-g' || arg === '--goto') args.goto = true;
    else if (arg === '-r' || arg === '--reuse-window') args['reuse-window'] = true;
    else if (arg === '-n' || arg === '--new-window') args['new-window'] = true;
    else if (arg === '-a' || arg === '--add') args.add = true;
    else if (arg.startsWith('-')) process.exit(FALLBACK);
    else args._.push(arg);
}
// A relative path (with a :line:column suffix under --goto) is made absolute here.
args._ = args._.map((path) => {
    if (!args.goto) return resolve(path);
    const match = /^(.*?)(:\d+(?::\d+)?)?$/.exec(path);
    return resolve(match[1]) + (match[2] ?? '');
});

// $XDG_RUNTIME_DIR/vscode-<sha256(user data dir), 8>-<version, 4>-main.sock
const runtime = process.env.XDG_RUNTIME_DIR || '/tmp/xdg-runtime';
const scope = createHash('sha256').update(userDataDir).digest('hex').slice(0, 8);
let socket;
try {
    socket = readdirSync(runtime).find((name) => name.startsWith(`vscode-${scope}-`) && name.endsWith('-main.sock'));
} catch { /* no runtime directory: no running instance */ }
if (!socket) process.exit(FALLBACK);

// ipc.ts serialization: a type byte, then a variable-length size or value.
const vql = (value) => {
    const bytes = [];
    do {
        let byte = value & 0x7f;
        value >>>= 7;
        if (value > 0) byte |= 0x80;
        bytes.push(byte);
    } while (value > 0);
    return Buffer.from(bytes);
};
const serialize = (data) => {
    if (data === undefined) return Buffer.from([0]);
    if (typeof data === 'string') {
        const bytes = Buffer.from(data);
        return Buffer.concat([Buffer.from([1]), vql(bytes.length), bytes]);
    }
    if (Array.isArray(data)) return Buffer.concat([Buffer.from([4]), vql(data.length), ...data.map(serialize)]);
    if (typeof data === 'number' && (data | 0) === data) return Buffer.concat([Buffer.from([6]), vql(data)]);
    const bytes = Buffer.from(JSON.stringify(data));
    return Buffer.concat([Buffer.from([5]), vql(bytes.length), bytes]);
};
const deserialize = (buffer, at = { offset: 0 }) => {
    const readVql = () => {
        let value = 0;
        for (let shift = 0; ; shift += 7) {
            const byte = buffer[at.offset++];
            value |= (byte & 0x7f) << shift;
            if (!(byte & 0x80)) return value >>> 0;
        }
    };
    const type = buffer[at.offset++];
    switch (type) {
        case 0: return undefined;
        case 1: case 2: case 3: case 5: {
            const length = readVql();
            const bytes = buffer.subarray(at.offset, at.offset + length);
            at.offset += length;
            return type === 1 ? bytes.toString() : type === 5 ? JSON.parse(bytes.toString()) : bytes;
        }
        case 4: return Array.from({ length: readVql() }, () => deserialize(buffer, at));
        case 6: return readVql();
        default: throw new Error(`unknown IPC data type ${type}`);
    }
};
// ipc.net.ts framing: type (1 = regular), id, ack, size, then the payload.
const frame = (payload) => {
    const header = Buffer.alloc(13);
    header.writeUInt8(1, 0);
    header.writeUInt32BE(payload.length, 9);
    return Buffer.concat([header, payload]);
};

const timer = setTimeout(() => process.exit(FALLBACK), 15000);
const connection = connect(join(runtime, socket));
connection.on('error', () => process.exit(FALLBACK));
connection.on('connect', () => {
    connection.write(frame(serialize('main')));
    const env = { ...process.env, VSCODE_CWD: process.cwd() };
    // RequestType.Promise = 100: [type, id, channel, command], then the argument list.
    connection.write(frame(Buffer.concat([serialize([100, 1, 'launch', 'start']), serialize([args, env])])));
});
let pending = Buffer.alloc(0);
connection.on('data', (data) => {
    pending = Buffer.concat([pending, data]);
    while (pending.length >= 13) {
        const size = pending.readUInt32BE(9);
        if (pending.length < 13 + size) return;
        const type = pending[0];
        const payload = pending.subarray(13, 13 + size);
        pending = pending.subarray(13 + size);
        if (type !== 1) continue;
        const at = { offset: 0 };
        const header = deserialize(payload, at);
        // ResponseType: 200 initialize, 201 success, 202/203 error.
        if (header[0] === 201 && header[1] === 1) {
            clearTimeout(timer);
            connection.end();
            process.exit(0);
        }
        if ((header[0] === 202 || header[0] === 203) && header[1] === 1) process.exit(FALLBACK);
    }
});

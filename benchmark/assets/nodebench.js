// Node.js Performance Benchmark: 文本处理 / 数学运算 / JSON / 加密 / Buffer
const crypto = require('crypto');
const { performance } = require('perf_hooks');

const results = [];

function bench(name, func) {
    const t0 = performance.now();
    const ret = func();
    const t1 = performance.now();
    const ms = Math.round(t1 - t0);
    results.push([name, ms]);
    console.log(`${name.padEnd(40)} ${String(ms).padStart(6)} ms`);
    return ret;
}

// ━━━ 文本处理 ━━━
function textConcat() {
    let s = "";
    for (let i = 0; i < 50000; i++) s += String(i);
    return s.length;
}

function textSplitJoin() {
    const arr = [];
    for (let i = 0; i < 50000; i++) arr.push(String(i));
    const s = arr.join(" ");
    const parts = s.split(" ");
    return parts.length;
}

function textReplace() {
    let s = "hello world ".repeat(10000);
    for (let i = 0; i < 100; i++) {
        s = s.replace(/hello/g, "HELLO").replace(/HELLO/g, "hello");
    }
    return s.length;
}

function textTemplate() {
    const results = [];
    for (let i = 0; i < 50000; i++) {
        results.push(`item_${i}: value=${(i * 3.14).toFixed(4)}, hex=0x${i.toString(16).padStart(8, '0')}`);
    }
    return results.length;
}

function regexSearch() {
    const text = "The quick brown fox 123 jumps over 456 lazy dogs 789\n".repeat(1000);
    const pat = /\b\d{3}\b/g;
    const matches = text.match(pat);
    return matches.length;
}

function regexReplace() {
    const text = "foo123bar456baz789qux012\n".repeat(5000);
    const result = text.replace(/(\d+)/g, (m) => String(Number(m) * 2));
    return result.length;
}

// ━━━ 数学运算 ━━━
function mathIntArith() {
    let a = 123456789, b = 987654321, c = 0;
    for (let i = 0; i < 2000000; i++) {
        c = (a * b + c) | 0;
        a = c % 1000000007;
        b = ((a ^ b) + i) | 0;
        c = (a + b) | 0;
    }
    return c;
}

function mathFloat() {
    let x = 1.0, y = 0.0;
    for (let i = 0; i < 1000000; i++) {
        x = Math.sin(x) + Math.cos(y);
        y = Math.sqrt(Math.abs(x)) + Math.log(Math.abs(y) + 1);
    }
    return x + y;
}

function mathFibonacci() {
    function fib(n) {
        if (n < 2) return n;
        return fib(n - 1) + fib(n - 2);
    }
    return fib(35);
}

function mathPrimeSieve() {
    const n = 500000;
    const sieve = new Uint8Array(n + 1);
    sieve.fill(1);
    sieve[0] = sieve[1] = 0;
    for (let i = 2; i * i <= n; i++) {
        if (sieve[i]) {
            for (let j = i * i; j <= n; j += i) sieve[j] = 0;
        }
    }
    let count = 0;
    for (let i = 0; i <= n; i++) if (sieve[i]) count++;
    return count;
}

function mathMatrix() {
    const N = 64;
    const A = [], B = [], C = [];
    for (let i = 0; i < N; i++) {
        A[i] = new Float64Array(N);
        B[i] = new Float64Array(N);
        C[i] = new Float64Array(N);
        for (let j = 0; j < N; j++) {
            A[i][j] = i * N + j;
            B[i][j] = i * N + j;
        }
    }
    for (let i = 0; i < N; i++)
        for (let j = 0; j < N; j++) {
            let s = 0;
            for (let k = 0; k < N; k++) s += A[i][k] * B[k][j];
            C[i][j] = s;
        }
    return C[0][0];
}

// ━━━ JSON ━━━
function jsonSerialize() {
    const data = [];
    for (let i = 0; i < 10000; i++) {
        data.push({id: i, name: `user_${i}`, email: `user${i}@example.com`,
                    scores: [i * 0.1, i * 0.2, i * 0.3]});
    }
    return JSON.stringify(data).length;
}

function jsonParse() {
    const data = [];
    for (let i = 0; i < 10000; i++) {
        data.push({id: i, name: `user_${i}`, scores: [i, i*2, i*3]});
    }
    const s = JSON.stringify(data);
    return JSON.parse(s).length;
}

function jsonRoundtrip() {
    let data = {users: []};
    for (let i = 0; i < 5000; i++) {
        data.users.push({id: i, tags: [`t0`, `t1`, `t2`, `t3`, `t4`]});
    }
    for (let r = 0; r < 10; r++) {
        data = JSON.parse(JSON.stringify(data));
    }
    return data.users.length;
}

// ━━━ 加密 & 哈希 ━━━
function hashMd5() {
    const data = Buffer.alloc(4500, 'A');
    for (let i = 0; i < 10000; i++) {
        crypto.createHash('md5').update(data).digest('hex');
    }
}

function hashSha256() {
    const data = Buffer.alloc(4500, 'A');
    for (let i = 0; i < 10000; i++) {
        crypto.createHash('sha256').update(data).digest('hex');
    }
}

function base64EncodeDecode() {
    const data = Buffer.alloc(10000, 'A');
    for (let i = 0; i < 10000; i++) {
        const enc = data.toString('base64');
        Buffer.from(enc, 'base64');
    }
}

// ━━━ Buffer / TypedArray ━━━
function bufferOps() {
    const buf = Buffer.alloc(1024 * 1024); // 1MB
    for (let r = 0; r < 20; r++) {
        buf.fill(r & 0xFF);
        const copy = Buffer.alloc(buf.length);
        buf.copy(copy);
    }
    return buf.length;
}

function typedArraySort() {
    const arr = new Float64Array(200000);
    for (let i = 0; i < arr.length; i++) arr[i] = Math.random();
    arr.sort();
    return arr[0];
}

// ━━━ Run ━━━
console.log("=".repeat(52));
console.log("Node.js Performance Benchmark");
console.log("=".repeat(52));

console.log("\n--- 文本处理 ---");
bench("string concat 50K", textConcat);
bench("string split+join 50K", textSplitJoin);
bench("string replace 100x (regex)", textReplace);
bench("string template 50K", textTemplate);
bench("regex search", regexSearch);
bench("regex replace", regexReplace);

console.log("\n--- 数学运算 ---");
bench("int arithmetic 2M", mathIntArith);
bench("float sin/cos/sqrt/log 1M", mathFloat);
bench("fibonacci(35) recursive", mathFibonacci);
bench("prime sieve 500K", mathPrimeSieve);
bench("matrix multiply 64x64", mathMatrix);

console.log("\n--- JSON ---");
bench("json serialize 10K objects", jsonSerialize);
bench("json parse 10K objects", jsonParse);
bench("json roundtrip 5K x10", jsonRoundtrip);

console.log("\n--- 加密 & 哈希 ---");
bench("md5 x10K (4.5KB each)", hashMd5);
bench("sha256 x10K (4.5KB each)", hashSha256);
bench("base64 encode+decode x10K", base64EncodeDecode);

console.log("\n--- Buffer/Array ---");
bench("buffer fill+copy 1MB x20", bufferOps);
bench("typed array sort 200K", typedArraySort);

console.log("\n" + "=".repeat(52));
const total = results.reduce((s, [_, ms]) => s + ms, 0);
console.log(`Total: ${total} ms (${(total/1000).toFixed(1)}s)`);

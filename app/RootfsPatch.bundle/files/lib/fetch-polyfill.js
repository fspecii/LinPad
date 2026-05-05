"use strict";
// Lazy fetch polyfill: defer require of http/https/url/zlib until fetch() is
// actually called. The previous version eager-required these on startup, which
// alone added ~580ms to `node -e 0` on iSH ARM64 (4 internal modules compiled
// into V8 bytecode by --no-lazy mode). Profile via Node's --cpu-prof showed
// 18.5% spent in compileForInternalLoader; this slashes that for scripts that
// never call fetch (the vast majority).
//
// Validated 2026-05-05 on iSH ARM64:
//   node -e 'process.exit(0)' : 1.18s → 0.60s  (+49%)
//   npm --version              : 2.40s → 1.70s  (+30%)
//
if (typeof globalThis.WebAssembly === "undefined") {
  let _impl = null;
  function _lazy() {
    if (_impl) return _impl;
    const http = require("http");
    const https = require("https");
    const { URL: U } = require("url");
    const zlib = require("zlib");
    class R {
      constructor(b, s, t, h, u) {
        this._buf = b; this.status = s; this.statusText = t;
        this.ok = s >= 200 && s < 300; this.url = u; this._h = h;
        this.headers = {
          get: k => h[k.toLowerCase()] || null,
          has: k => k.toLowerCase() in h,
          entries: () => Object.entries(h),
          forEach: fn => Object.entries(h).forEach(([k, v]) => fn(v, k)),
        };
      }
      async text() { return this._buf.toString("utf8"); }
      async json() { return JSON.parse(this._buf.toString("utf8")); }
      async arrayBuffer() {
        return this._buf.buffer.slice(
          this._buf.byteOffset,
          this._buf.byteOffset + this._buf.byteLength,
        );
      }
      clone() { return new R(this._buf, this.status, this.statusText, this._h, this.url); }
    }
    _impl = function _fetch(input, init) {
      return new Promise((resolve, reject) => {
        const url = typeof input === "string" ? new U(input) : new U(input.url || input);
        const opts = Object.assign({}, init || {});
        const mod = url.protocol === "https:" ? https : http;
        const ro = {
          hostname: url.hostname,
          port: url.port || (url.protocol === "https:" ? 443 : 80),
          path: url.pathname + url.search,
          method: (opts.method || "GET").toUpperCase(),
          headers: Object.assign({}, opts.headers || {}),
        };
        const req = mod.request(ro, res => {
          if (res.statusCode >= 301 && res.statusCode <= 308 && res.headers.location) {
            _impl(new U(res.headers.location, url).href, init).then(resolve, reject);
            return;
          }
          const chunks = [];
          let s = res;
          const enc = res.headers["content-encoding"];
          if (enc === "gzip") s = res.pipe(zlib.createGunzip());
          else if (enc === "deflate") s = res.pipe(zlib.createInflate());
          else if (enc === "br") s = res.pipe(zlib.createBrotliDecompress());
          s.on("data", c => chunks.push(c));
          s.on("end", () => {
            const body = Buffer.concat(chunks);
            resolve(new R(body, res.statusCode, res.statusMessage, res.headers, url.href));
          });
          s.on("error", reject);
        });
        req.on("error", reject);
        if (opts.body) {
          req.write(typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body));
        }
        req.end();
      });
    };
    return _impl;
  }
  // Install a getter on globalThis.fetch — first read materialises the impl.
  // Re-installs on nextTick + setImmediate to defeat Node's bootstrap, which
  // overwrites globalThis.fetch with the (broken-on-jitless) undici fetch.
  let _installed = false;
  const installLazy = () => {
    if (_installed) return;
    _installed = true;
    Object.defineProperty(globalThis, "fetch", {
      configurable: true,
      get() {
        const f = _lazy();
        Object.defineProperty(globalThis, "fetch", {
          value: f, writable: true, configurable: true,
        });
        return f;
      },
      set(v) {
        Object.defineProperty(globalThis, "fetch", {
          value: v, writable: true, configurable: true,
        });
      },
    });
  };
  installLazy();
  process.nextTick(installLazy);
  setImmediate(installLazy);
}

"use strict";
// WebAssembly polyfill for --jitless Node.js environments.
// Provides a pure JS implementation of the llhttp HTTP response parser
// that undici uses via WebAssembly. This allows undici-based libraries
// (MCP servers, node-fetch, etc.) to work without real WebAssembly support.

if (typeof globalThis.WebAssembly === "undefined") {

// llhttp state machine states
const S_START = 0, S_RES_H = 1, S_RES_LINE = 2, S_STATUS = 3,
      S_HEADER_FIELD = 4, S_HEADER_VALUE = 5, S_HEADERS_DONE = 6,
      S_BODY_IDENTITY = 7, S_BODY_CHUNKED_SIZE = 8, S_BODY_CHUNKED_DATA = 9,
      S_BODY_CHUNKED_END = 10, S_COMPLETE = 11, S_DEAD = 12, S_PAUSED = 13;

const OK = 0, PAUSED = 21, PAUSED_UPGRADE = 22;

// Simulated WebAssembly.Memory as a growable ArrayBuffer
const INITIAL_MEM = 1024 * 1024; // 1MB
let memBuf = new ArrayBuffer(INITIAL_MEM);
let memU8 = new Uint8Array(memBuf);
const memory = {
  buffer: memBuf,
  grow(pages) {
    const newSize = memBuf.byteLength + pages * 65536;
    const newBuf = new ArrayBuffer(newSize);
    new Uint8Array(newBuf).set(memU8);
    memBuf = newBuf;
    memU8 = new Uint8Array(memBuf);
    memory.buffer = memBuf;
  }
};

// Simple bump allocator for wasm memory simulation
let heapPtr = 4096; // start after null page
function walloc(size) {
  const aligned = (size + 7) & ~7;
  if (heapPtr + aligned > memBuf.byteLength) {
    memory.grow(Math.ceil(aligned / 65536) + 1);
  }
  const ptr = heapPtr;
  heapPtr += aligned;
  return ptr;
}

// Parser instance storage (indexed by pointer)
const parsers = new Map();
let nextParserId = 8192;

// Callbacks from the env object - will be set by undici when instantiating
let envCallbacks = {};

function createParser(type) {
  const id = nextParserId;
  nextParserId += 256; // space between parsers
  parsers.set(id, {
    type, // 1=REQUEST, 2=RESPONSE
    state: S_START,
    statusCode: 0,
    upgrade: false,
    shouldKeepAlive: true,
    contentLength: -1,
    chunked: false,
    remaining: 0,
    chunkSize: 0,
    errorReason: 0,
    errorPos: 0,
    paused: false
  });
  return id;
}

// Write a C string into wasm memory, return pointer
function writeStr(str) {
  const ptr = walloc(str.length + 1);
  for (let i = 0; i < str.length; i++) memU8[ptr + i] = str.charCodeAt(i);
  memU8[ptr + str.length] = 0;
  return ptr;
}

// Parse HTTP response data
function llhttp_execute(ptr, bufPtr, bufLen) {
  const p = parsers.get(ptr);
  if (!p) return 1; // INTERNAL error
  if (p.paused) return PAUSED;

  const data = new Uint8Array(memory.buffer, bufPtr, bufLen);
  let i = 0;

  while (i < bufLen) {
    switch (p.state) {
      case S_START: {
        // Look for "HTTP/"
        if (data[i] === 0x48) { // 'H'
          p.state = S_RES_H;
        } else {
          i++;
        }
        break;
      }

      case S_RES_H: {
        // Scan for end of status line (first \r\n)
        const lineEnd = findCRLF(data, i, bufLen);
        if (lineEnd === -1) { p.errorPos = bufPtr + i; return OK; } // need more data

        // Parse "HTTP/x.x SSS Reason"
        const line = decodeAscii(data, i - 1, lineEnd); // -1 to include 'H'
        const match = line.match(/^HTTP\/\d\.\d\s+(\d{3})\s*(.*)/);
        if (match) {
          p.statusCode = parseInt(match[1], 10);
          // Notify status
          const statusStart = bufPtr + i - 1 + line.indexOf(match[2]);
          const statusLen = match[2].length;
          let rc = envCallbacks.wasm_on_message_begin(ptr);
          if (rc) { p.errorPos = bufPtr + i; return rc; }
          if (statusLen > 0) {
            rc = envCallbacks.wasm_on_status(ptr, bufPtr + i - 1 + line.indexOf(match[1]) + match[1].length + 1, statusLen);
            if (rc) { p.errorPos = bufPtr + i; return rc; }
          }
        }
        i = lineEnd + 2; // skip \r\n
        p.state = S_HEADER_FIELD;
        p.chunked = false;
        p.contentLength = -1;
        p.upgrade = false;
        p.shouldKeepAlive = true;
        break;
      }

      case S_HEADER_FIELD: {
        // Check for end of headers (\r\n)
        if (i < bufLen && data[i] === 0x0d) {
          if (i + 1 < bufLen && data[i + 1] === 0x0a) {
            i += 2;
            p.state = S_HEADERS_DONE;
            break;
          }
        }
        // Find ':'
        const colonIdx = findByte(data, 0x3a, i, bufLen);
        if (colonIdx === -1) { p.errorPos = bufPtr + i; return OK; }

        const fieldStart = bufPtr + i;
        const fieldLen = colonIdx - i;
        const rc = envCallbacks.wasm_on_header_field(ptr, fieldStart, fieldLen);
        if (rc) { p.errorPos = bufPtr + i; return rc; }

        // Track transfer-encoding and content-length
        const fieldName = decodeAscii(data, i, colonIdx).toLowerCase();
        i = colonIdx + 1;
        // skip optional spaces
        while (i < bufLen && data[i] === 0x20) i++;

        // Find end of header value
        const valEnd = findCRLF(data, i, bufLen);
        if (valEnd === -1) { p.errorPos = bufPtr + i; return OK; }

        const valueStart = bufPtr + i;
        const valueLen = valEnd - i;
        const rc2 = envCallbacks.wasm_on_header_value(ptr, valueStart, valueLen);
        if (rc2) { p.errorPos = bufPtr + i; return rc2; }

        const value = decodeAscii(data, i, valEnd).toLowerCase().trim();
        if (fieldName === "transfer-encoding" && value.includes("chunked")) p.chunked = true;
        if (fieldName === "content-length") p.contentLength = parseInt(value, 10);
        if (fieldName === "connection" && value === "close") p.shouldKeepAlive = false;
        if (fieldName === "upgrade") p.upgrade = true;

        i = valEnd + 2;
        break;
      }

      case S_HEADERS_DONE: {
        const rc = envCallbacks.wasm_on_headers_complete(ptr, p.statusCode,
          p.upgrade ? 1 : 0, p.shouldKeepAlive ? 1 : 0);
        if (rc === 1) {
          // skip body
          p.state = S_COMPLETE;
          break;
        }
        if (rc === 2) {
          p.upgrade = true;
          p.errorPos = bufPtr + i;
          return PAUSED_UPGRADE;
        }
        if (rc) { p.errorPos = bufPtr + i; return rc; }

        if (p.upgrade) {
          p.errorPos = bufPtr + i;
          return PAUSED_UPGRADE;
        }

        if (p.chunked) {
          p.state = S_BODY_CHUNKED_SIZE;
        } else if (p.contentLength > 0) {
          p.state = S_BODY_IDENTITY;
          p.remaining = p.contentLength;
        } else if (p.contentLength === 0) {
          p.state = S_COMPLETE;
        } else {
          // No content-length, no chunked: read until close (for responses)
          // or no body (for 1xx, 204, 304)
          if (p.statusCode === 204 || p.statusCode === 304 || (p.statusCode >= 100 && p.statusCode < 200)) {
            p.state = S_COMPLETE;
          } else {
            p.state = S_BODY_IDENTITY;
            p.remaining = Infinity;
          }
        }
        break;
      }

      case S_BODY_IDENTITY: {
        const available = bufLen - i;
        const toConsume = p.remaining === Infinity ? available : Math.min(available, p.remaining);
        if (toConsume > 0) {
          const rc = envCallbacks.wasm_on_body(ptr, bufPtr + i, toConsume);
          if (rc) { p.errorPos = bufPtr + i; return rc; }
          i += toConsume;
          if (p.remaining !== Infinity) p.remaining -= toConsume;
        }
        if (p.remaining === 0) p.state = S_COMPLETE;
        if (i >= bufLen) { p.errorPos = bufPtr + i; return OK; }
        break;
      }

      case S_BODY_CHUNKED_SIZE: {
        const lineEnd = findCRLF(data, i, bufLen);
        if (lineEnd === -1) { p.errorPos = bufPtr + i; return OK; }
        const sizeStr = decodeAscii(data, i, lineEnd).replace(/;.*/, "").trim();
        p.chunkSize = parseInt(sizeStr, 16);
        i = lineEnd + 2;
        if (p.chunkSize === 0) {
          p.state = S_BODY_CHUNKED_END;
        } else {
          p.state = S_BODY_CHUNKED_DATA;
          p.remaining = p.chunkSize;
        }
        break;
      }

      case S_BODY_CHUNKED_DATA: {
        const available = bufLen - i;
        const toConsume = Math.min(available, p.remaining);
        if (toConsume > 0) {
          const rc = envCallbacks.wasm_on_body(ptr, bufPtr + i, toConsume);
          if (rc) { p.errorPos = bufPtr + i; return rc; }
          i += toConsume;
          p.remaining -= toConsume;
        }
        if (p.remaining === 0) {
          // Expect \r\n after chunk data
          if (i + 1 < bufLen) {
            i += 2; // skip \r\n
            p.state = S_BODY_CHUNKED_SIZE;
          } else {
            p.errorPos = bufPtr + i;
            return OK; // need more data
          }
        } else {
          p.errorPos = bufPtr + i;
          return OK;
        }
        break;
      }

      case S_BODY_CHUNKED_END: {
        // Trailing headers or final \r\n
        if (data[i] === 0x0d && i + 1 < bufLen && data[i + 1] === 0x0a) {
          i += 2;
          p.state = S_COMPLETE;
        } else {
          // Skip trailing headers
          const lineEnd = findCRLF(data, i, bufLen);
          if (lineEnd === -1) { p.errorPos = bufPtr + i; return OK; }
          i = lineEnd + 2;
        }
        break;
      }

      case S_COMPLETE: {
        const rc = envCallbacks.wasm_on_message_complete(ptr);
        if (rc) { p.errorPos = bufPtr + i; return rc; }
        p.state = S_START; // ready for next message (keep-alive)
        p.errorPos = bufPtr + i;
        return OK;
      }

      default:
        p.errorPos = bufPtr + i;
        return 1; // INTERNAL
    }
  }

  p.errorPos = bufPtr + bufLen;
  return OK;
}

function findCRLF(data, from, to) {
  for (let j = from; j < to - 1; j++) {
    if (data[j] === 0x0d && data[j + 1] === 0x0a) return j;
  }
  return -1;
}

function findByte(data, byte, from, to) {
  for (let j = from; j < to; j++) {
    if (data[j] === byte) return j;
  }
  return -1;
}

function decodeAscii(data, from, to) {
  let s = "";
  for (let j = from; j < to; j++) s += String.fromCharCode(data[j]);
  return s;
}

// Build the fake WebAssembly module exports
const wasmExports = {
  memory,
  llhttp_alloc(type) { return createParser(type); },
  llhttp_free(ptr) { parsers.delete(ptr); },
  llhttp_execute,
  llhttp_resume(ptr) {
    const p = parsers.get(ptr);
    if (p) p.paused = false;
  },
  llhttp_get_error_pos(ptr) {
    const p = parsers.get(ptr);
    return p ? p.errorPos : 0;
  },
  llhttp_get_error_reason(ptr) {
    const p = parsers.get(ptr);
    if (!p) return 0;
    if (!p.errorReasonPtr) p.errorReasonPtr = writeStr("OK");
    return p.errorReasonPtr;
  },
  malloc(size) { return walloc(size); },
  free(ptr) { /* bump allocator, no-op */ }
};

// Create a fake compiled WebAssembly module token
const fakeModule = Symbol("llhttp-js-module");

globalThis.WebAssembly = {
  async compile(bytes) { return fakeModule; },
  async instantiate(mod, importObj) {
    if (importObj && importObj.env) {
      envCallbacks = importObj.env;
    }
    return { exports: wasmExports };
  },
  Module: function() {},
  Instance: function() {},
  Memory: function(desc) {
    return memory;
  },
  Table: function() {},
  validate(bytes) { return true; },
  compileStreaming() { return Promise.resolve(fakeModule); },
  instantiateStreaming(source, importObj) {
    return Promise.resolve({ module: fakeModule, instance: { exports: wasmExports } });
  }
};

} // end if WebAssembly undefined

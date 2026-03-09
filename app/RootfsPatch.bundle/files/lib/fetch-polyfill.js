"use strict";
// Override fetch AFTER Node.js bootstrap completes.
// Node sets globalThis.fetch from undici during bootstrap (after --require).
// We use setImmediate to run after bootstrap, replacing the broken undici fetch.
if(typeof globalThis.WebAssembly==="undefined"){
const http=require("http"),https=require("https"),{URL:U}=require("url"),zlib=require("zlib");
class R{constructor(b,s,t,h,u){this._buf=b;this.status=s;this.statusText=t;this.ok=s>=200&&s<300;this.url=u;this._h=h;this.headers={get:k=>h[k.toLowerCase()]||null,has:k=>k.toLowerCase()in h,entries:()=>Object.entries(h),forEach:fn=>Object.entries(h).forEach(([k,v])=>fn(v,k))}}
async text(){return this._buf.toString("utf8")}async json(){return JSON.parse(this._buf.toString("utf8"))}async arrayBuffer(){return this._buf.buffer.slice(this._buf.byteOffset,this._buf.byteOffset+this._buf.byteLength)}
clone(){return new R(this._buf,this.status,this.statusText,this._h,this.url)}}
function _fetch(input,init){return new Promise((resolve,reject)=>{
const url=typeof input==="string"?new U(input):new U(input.url||input);
const opts=Object.assign({},init||{});const mod=url.protocol==="https:"?https:http;
const ro={hostname:url.hostname,port:url.port||(url.protocol==="https:"?443:80),path:url.pathname+url.search,method:(opts.method||"GET").toUpperCase(),headers:Object.assign({},opts.headers||{})};
const req=mod.request(ro,res=>{
if(res.statusCode>=301&&res.statusCode<=308&&res.headers.location){_fetch(new U(res.headers.location,url).href,init).then(resolve,reject);return}
const chunks=[];let s=res;const enc=res.headers["content-encoding"];
if(enc==="gzip")s=res.pipe(zlib.createGunzip());else if(enc==="deflate")s=res.pipe(zlib.createInflate());else if(enc==="br")s=res.pipe(zlib.createBrotliDecompress());
s.on("data",c=>chunks.push(c));s.on("end",()=>{const body=Buffer.concat(chunks);resolve(new R(body,res.statusCode,res.statusMessage,res.headers,url.href))});s.on("error",reject)});
req.on("error",reject);if(opts.body)req.write(typeof opts.body==="string"?opts.body:JSON.stringify(opts.body));req.end()})}
// Replace globalThis.fetch immediately and also on next tick (to catch bootstrap override)
globalThis.fetch=_fetch;
process.nextTick(()=>{globalThis.fetch=_fetch});
setImmediate(()=>{globalThis.fetch=_fetch});
}

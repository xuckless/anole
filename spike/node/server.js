// spike/node/server.js - THROWAWAY: a trivial JS handler behind libanole.
//   node server.js <executors> <port>      (or: bun server.js ...)
// Routes: /native (fixed response in Anole's config, never enters JS),
// /hello (JS returns a string), /users/:id (JS reads a route parameter).
// Runs until SIGTERM/SIGINT (the binding's own handler: Anole installs none),
// then drains and prints the batch counters.
'use strict';
const path = require('path');
const addon = require(process.env.ANOLE_ADDON || path.join(__dirname, 'build', 'anole.node'));

const executors = Number(process.argv[2] || 1);
const port = Number(process.argv[3] || 18500);

const EV = new ArrayBuffer(1 << 20);   // events land here (JS-owned, no external buffers)
const RP = new ArrayBuffer(1 << 20);   // replies go back from here
const dv = new DataView(EV), eu8 = new Uint8Array(EV);
const rdv = new DataView(RP), ru8 = new Uint8Array(RP);
const latin1 = new TextDecoder('latin1');
const enc = new TextEncoder();

// A lazy request over one record: nothing decoded until asked.
class Req {
  constructor(base) { this.base = base; }
  span(at) { const b = this.base; const off = dv.getUint32(b + at, true), len = dv.getUint32(b + at + 4, true); return latin1.decode(eu8.subarray(b + off, b + off + len)); }
  get method() { return this.span(24); }
  get path() { return this.span(32); }
  get query() { return this.span(40); }
  param(name) {
    const b = this.base, nh = dv.getUint16(b + 56, true), np = dv.getUint16(b + 58, true);
    let s = b + 64 + nh * 16;
    for (let i = 0; i < np; i++, s += 16) {
      const ko = dv.getUint32(s, true), kl = dv.getUint32(s + 4, true);
      if (latin1.decode(eu8.subarray(b + ko, b + ko + kl)) === name) {
        const vo = dv.getUint32(s + 8, true), vl = dv.getUint32(s + 12, true);
        return latin1.decode(eu8.subarray(b + vo, b + vo + vl));
      }
    }
    return undefined;
  }
}

const routes = {
  1: (req) => 'Hello, World!',
  4: (req) => 'user ' + req.param('id'),
};

function onBatch(n) {
  let off = 0, w = 0;
  while (off < n) {
    const type = dv.getUint32(off, true), len = dv.getUint32(off + 4, true);
    if (type === 1) {
      const route = dv.getUint32(off + 16, true);
      const body = routes[route](new Req(off));
      rdv.setUint32(w, dv.getUint32(off + 8, true), true);       // handle lo
      rdv.setUint32(w + 4, dv.getUint32(off + 12, true), true);  // handle hi
      rdv.setUint16(w + 8, 200, true);
      rdv.setUint16(w + 10, 1, true);                            // text/plain
      const { written } = enc.encodeInto(body, ru8.subarray(w + 16));
      rdv.setUint32(w + 12, written, true);
      w += 16 + ((written + 3) & ~3);
    }
    off += len;
  }
  return w;
}

const config = {
  listeners: [{ address: '127.0.0.1', port }],
  executors,
  limits: { max_inflight: 4096 },
  routes: [
    { method: 'GET', path: '/native', respond: { status: 200, body: 'Hello, World!', headers: { 'content-type': 'text/plain' } } },
    { method: 'GET', path: '/hello', handler: 1 },
    { method: 'GET', path: '/users/:id', handler: 4 },
  ],
};
const actual = addon.start(JSON.stringify(config), onBatch, EV, RP);
console.error(`anole-node spike on 127.0.0.1:${actual} (${executors} executors) under ${typeof Bun !== 'undefined' ? 'bun ' + Bun.version : 'node ' + process.version}`);
const stop = () => { console.error(JSON.stringify(addon.stop())); process.exit(0); };
process.on('SIGTERM', stop);
process.on('SIGINT', stop);

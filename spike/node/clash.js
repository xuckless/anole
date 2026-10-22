// spike/node/clash.js - the addon's BoringSSL, nghttp2, zstd, brotli, sqlite and
// zlib-ng live in the same process as Node's own OpenSSL, nghttp2, nghttp3,
// zstd, brotli, sqlite and zlib (Homebrew's node links them dynamically).
// Node's HTTP/2 client (Node's nghttp2) talks h2c to Anole (Anole's
// nghttp2) while Node's crypto/zlib/zstd run; any interposed symbol would
// crash or corrupt. node clash.js | bun clash.js
'use strict';
const path = require('path');
const crypto = require('crypto');
const zlib = require('zlib');
const http2 = require('http2');
const addon = require(path.join(__dirname, 'build', 'anole.node'));
const EV = new ArrayBuffer(1 << 20), RP = new ArrayBuffer(1 << 20);
const dv = new DataView(EV), rdv = new DataView(RP), ru8 = new Uint8Array(RP);
const enc = new TextEncoder();
function onBatch(n) {
  let off = 0, w = 0;
  while (off < n) {
    const type = dv.getUint32(off, true), len = dv.getUint32(off + 4, true);
    if (type === 1) {
      rdv.setUint32(w, dv.getUint32(off + 8, true), true); rdv.setUint32(w + 4, dv.getUint32(off + 12, true), true);
      rdv.setUint16(w + 8, 200, true); rdv.setUint16(w + 10, 1, true);
      const { written } = enc.encodeInto('from js', ru8.subarray(w + 16));
      rdv.setUint32(w + 12, written, true); w += 16 + ((written + 3) & ~3);
    }
    off += len;
  }
  return w;
}
const port = addon.start(JSON.stringify({ listeners: [{ port: 0 }], executors: 2, routes: [
  { method: 'GET', path: '/native', respond: { body: 'native' } }, { method: 'GET', path: '/js', handler: 1 }] }), onBatch, EV, RP);
const sha = crypto.createHash('sha256').update('abc').digest('hex');
if (sha !== 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') throw new Error('sha256 broken');
const gz = zlib.gunzipSync(zlib.gzipSync(Buffer.from('x'.repeat(1000)))).length;
const zs = zlib.zstdDecompressSync ? zlib.zstdDecompressSync(zlib.zstdCompressSync(Buffer.from('y'.repeat(1000)))).length : 1000;
const br = zlib.brotliDecompressSync(zlib.brotliCompressSync(Buffer.from('z'.repeat(1000)))).length;
const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const sig = crypto.sign('sha256', Buffer.from('m'), privateKey);
if (!crypto.verify('sha256', Buffer.from('m'), publicKey, sig) || gz !== 1000 || zs !== 1000 || br !== 1000) throw new Error('node crypto/zlib broken');
const client = http2.connect(`http://127.0.0.1:${port}`);
let left = 200, ok = 0;
for (let i = 0; i < 200; i++) {
  const req = client.request({ ':path': i % 2 ? '/js' : '/native' });
  let body = '';
  req.on('data', (d) => body += d);
  req.on('end', () => {
    if (body === (i % 2 ? 'from js' : 'native')) ok++;
    if (--left === 0) {
      client.close();
      const s = addon.stop();
      console.log(`clash check under ${typeof Bun !== 'undefined' ? 'bun' : 'node ' + process.version}: ${ok}/200 h2c answers right (Node's nghttp2 client -> Anole's nghttp2 server), sha256/ECDSA/gzip/zstd/brotli in Node fine; batches ${s.batches}`);
      process.exit(ok === 200 ? 0 : 1);
    }
  });
}

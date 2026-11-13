// Node's http2 client against the h2count TLS listener: a page-like burst,
// a download, a cancelled stream, an upload; then a PING burst that is
// tool-driven (a client API, not what an application does) and reported apart.
// usage: node node-h2.mjs <https://host:port> <cert.pem> <phase>
import http2 from 'node:http2';
import fs from 'node:fs';

const [base, certFile, phase] = process.argv.slice(2);
const session = http2.connect(base, { ca: fs.readFileSync(certFile) });
await new Promise((res, rej) => { session.once('connect', res); session.once('error', rej); });
const { NGHTTP2_CANCEL } = http2.constants;
let failed = false;
const check = (ok, what) => { if (!ok) { failed = true; console.error('FAIL:', what); } };

function get(path, { cancelAfter, method = 'GET', body } = {}) {
  return new Promise(resolve => {
    const req = session.request({ ':path': path, ':method': method });
    let n = 0, status = 0, text = '';
    req.on('response', h => { status = h[':status']; });
    req.on('data', c => { n += c.length; if (n < 64) text += c; if (cancelAfter && n >= cancelAfter) req.close(NGHTTP2_CANCEL); });
    req.on('close', () => resolve({ n, text, status, err: !!req.rstCode && !cancelAfter && req.rstCode !== 0 }));
    req.on('error', () => {});
    if (body) req.end(body); else req.end();
  });
}

if (phase === 'page') {
  const rs = await Promise.all(Array.from({ length: 100 }, (_, i) => get(`/r/${i}.png`)));
  check(rs.every(r => r.status === 200 && !r.err), 'every page stream answered 200');
} else if (phase === 'download') {
  const r = await get('/download'); console.log('downloaded', r.n);
  check(r.status === 200 && r.n === 67108864, 'download is 200 with 67108864 bytes');
} else if (phase === 'cancel') {
  const rs = await Promise.all(Array.from({ length: 20 }, () => get('/download', { cancelAfter: 100_000 })));
  check(rs.every(r => r.status === 200), 'every cancelled download started with 200');
} else if (phase === 'upload') {
  const r = await get('/upload', { method: 'POST', body: Buffer.alloc(16 << 20) }); console.log('uploaded', r.text);
  check(r.status === 200 && r.text === '16777216', 'upload echo is 16777216');
} else if (phase === 'ping') {
  for (let i = 0; i < 50; i++) await new Promise(r => session.ping(() => r()));
}
session.close();
if (failed) process.exit(1);

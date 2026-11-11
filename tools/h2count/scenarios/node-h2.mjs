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

function get(path, { cancelAfter, method = 'GET', body } = {}) {
  return new Promise(resolve => {
    const req = session.request({ ':path': path, ':method': method });
    let n = 0;
    req.on('data', c => { n += c.length; if (cancelAfter && n >= cancelAfter) req.close(NGHTTP2_CANCEL); });
    req.on('close', () => resolve(n));
    req.on('error', () => {});
    if (body) req.end(body); else req.end();
  });
}

if (phase === 'page') {
  await Promise.all(Array.from({ length: 100 }, (_, i) => get(`/r/${i}.png`)));
} else if (phase === 'download') {
  console.log('downloaded', await get('/download'));
} else if (phase === 'cancel') {
  await Promise.all(Array.from({ length: 20 }, () => get('/download', { cancelAfter: 100_000 })));
} else if (phase === 'upload') {
  console.log('uploaded', await get('/upload', { method: 'POST', body: Buffer.alloc(16 << 20) }));
} else if (phase === 'ping') {
  for (let i = 0; i < 50; i++) await new Promise(r => session.ping(() => r()));
}
session.close();

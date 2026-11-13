// Hand-built HTTP/2 requests whose header block is split over CONTINUATION
// frames, to see where the server stops (the engine's max_continuations and
// max_header_list_size). Not a real client: it exists because curl and Node
// refuse to send a header list larger than the server advertises.
// usage: node rawcont.mjs <host> <port>   (h2c prior knowledge)
import net from 'node:net';

const [host, port] = process.argv.slice(2);
const frame = (type, flags, stream, payload) => {
  const b = Buffer.alloc(9 + payload.length);
  b.writeUIntBE(payload.length, 0, 3); b[3] = type; b[4] = flags; b.writeUInt32BE(stream, 5);
  payload.copy(b, 9);
  return b;
};
const intHpack = (n) => { // 7-bit prefix integer, no Huffman flag
  if (n < 127) return Buffer.from([n]);
  const o = [127]; n -= 127;
  while (n >= 128) { o.push((n & 127) | 128); n >>= 7; }
  o.push(n); return Buffer.from(o);
};
function block(valueLen) {
  const name = Buffer.from('x-big');
  return Buffer.concat([Buffer.from([0x82, 0x86, 0x84, 0x01, 0x09]), Buffer.from('localhost'), // GET, http, /, :authority
    Buffer.from([0x00, name.length]), name, intHpack(valueLen), Buffer.alloc(valueLen, 0x61)]);
}
function run(label, valueLen, frames) { // frames: header block fragments (HEADERS + CONTINUATIONs); 0 = full 16 KiB frames
  return new Promise(resolve => {
    const hb = block(valueLen);
    const chunk = frames ? Math.ceil(hb.length / frames) : 1 << 14;
    const parts = [];
    for (let i = 0; i < hb.length; i += chunk) parts.push(hb.subarray(i, i + chunk));
    const out = [Buffer.from('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'), frame(4, 0, 0, Buffer.alloc(0))];
    parts.forEach((p, i) => {
      const last = i === parts.length - 1;
      out.push(i === 0 ? frame(1, 0x1 | (last ? 4 : 0), 1, p) : frame(9, last ? 4 : 0, 1, p));
    });
    const s = net.connect(+port, host, () => s.write(Buffer.concat(out)));
    let buf = Buffer.alloc(0); const seen = [];
    s.on('data', d => {
      buf = Buffer.concat([buf, d]);
      while (buf.length >= 9) {
        const len = buf.readUIntBE(0, 3);
        if (buf.length < 9 + len) break;
        const t = buf[3], pl = buf.subarray(9, 9 + len);
        if (t === 1) { let i = 0; while (i < pl.length && (pl[i] & 0xe0) === 0x20) i++; /* dynamic table size updates */ seen.push(pl[i] === 0x88 ? 'HEADERS 200' : `HEADERS status-byte 0x${(pl[i] ?? 0).toString(16)}`); }
        else if (t === 3) seen.push(`RST_STREAM code ${pl.readUInt32BE(0)}`);
        else if (t === 7) seen.push(`GOAWAY code ${pl.readUInt32BE(4)}`);
        buf = buf.subarray(9 + len);
      }
    });
    const done = () => { console.log(`${label}: ${parts.length - 1} CONTINUATION frames, header block ${hb.length} B -> ${seen.join(', ') || 'no answer'}`); s.destroy(); resolve(); };
    s.on('close', done); s.on('error', () => {});
    setTimeout(() => s.end(), 800); // enough for the server to answer or give up
  });
}
await run('1 fragment', 20, 1);
await run('8 fragments (7 CONTINUATION)', 200, 8);
await run('9 fragments (8 CONTINUATION)', 200, 9);
await run('10 fragments (9 CONTINUATION)', 200, 10);
await run('21 fragments (20 CONTINUATION)', 200, 21);
await run('48 KiB value in full frames', 48 << 10, 0);
await run('70 KiB value in full frames', 70 << 10, 0);

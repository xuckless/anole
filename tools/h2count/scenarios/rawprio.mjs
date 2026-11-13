// Hand-built PRIORITY_UPDATE (RFC 9218) and PRIORITY frames at thousands per
// second, well past the glitch rate (330/s, burst 10000): neither is charged
// to any budget, so the connection must stay open and still answer a request.
// Synthetic: no browser has been seen sending enough of them (see the M3
// smoke README). usage: node rawprio.mjs <host> <port>   (h2c prior knowledge)
import net from 'node:net';

const [host, port] = process.argv.slice(2);
const frame = (type, flags, stream, payload) => {
  const b = Buffer.alloc(9 + payload.length);
  b.writeUIntBE(payload.length, 0, 3); b[3] = type; b[4] = flags; b.writeUInt32BE(stream, 5);
  payload.copy(b, 9);
  return b;
};
function run(label, type, n) {
  return new Promise(resolve => {
    const out = [Buffer.from('PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'), frame(4, 0, 0, Buffer.alloc(0))];
    for (let i = 0; i < n; i++) {
      const id = 1 + 2 * (i % 50);
      if (type === 0x10) out.push(frame(0x10, 0, 0, Buffer.concat([Buffer.from([0, 0, 0, id]), Buffer.from('u=3')])));
      else out.push(frame(2, 0, id, Buffer.from([0, 0, 0, 0, 15]))); // no dependency on stream 0, weight 16
    }
    out.push(frame(1, 0x5, 101, Buffer.from([0x82, 0x86, 0x84, 0x01, 0x09, ...Buffer.from('localhost')]))); // GET / at the end
    const s = net.connect(+port, host, () => s.write(Buffer.concat(out)));
    let buf = Buffer.alloc(0); const seen = [];
    s.on('data', d => {
      buf = Buffer.concat([buf, d]);
      while (buf.length >= 9) {
        const len = buf.readUIntBE(0, 3);
        if (buf.length < 9 + len) break;
        const t = buf[3], pl = buf.subarray(9, 9 + len);
        if (t === 1) seen.push(pl[0] === 0x88 ? 'HEADERS 200' : `HEADERS status-byte 0x${pl[0].toString(16)}`);
        else if (t === 7) seen.push(`GOAWAY code ${pl.readUInt32BE(4)}`);
        buf = buf.subarray(9 + len);
      }
    });
    s.on('close', () => { console.log(`${label} x${n} in one write -> ${seen.join(', ') || 'no answer'}`); resolve(); });
    s.on('error', () => {});
    setTimeout(() => s.end(), 800);
  });
}
await run('PRIORITY_UPDATE', 0x10, 5000);
await run('PRIORITY', 0x02, 5000);

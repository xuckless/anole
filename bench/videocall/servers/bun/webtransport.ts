// WebTransport (HTTP/3, draft-02) on UDP PORT with
// @fails-components/webtransport and its QUICHE transport (a napi addon).
//
// Framing (SPEC.md): the client's first bidirectional stream is the control
// stream, carrying u32 LE length + JSON both ways. Client media comes on
// unidirectional streams as u32 LE length + (header + payload); the server
// opens one unidirectional stream per kind to each user, lazily, and keeps it.
import { randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Http3Server } from '@fails-components/webtransport';
import { Conn, MAX_MEDIA, connClosed, connOpened, handleMedia, handleText, userByToken, type User } from './app.ts';

const encoder = new TextEncoder();
const decoder = new TextDecoder();

const frame = (...parts: Uint8Array[]): Uint8Array => {
  let len = 0;
  for (const p of parts) len += p.length;
  const out = new Uint8Array(4 + len);
  new DataView(out.buffer).setUint32(0, len, true);
  let off = 4;
  for (const p of parts) {
    out.set(p, off);
    off += p.length;
  }
  return out;
};

// Writes in order to a stream that may still be opening; the writer's own
// queue does the buffering (the library's default send behaviour).
class LazyWriter {
  private writer: WritableStreamDefaultWriter<Uint8Array> | null = null;
  private pending: Uint8Array[] | null = [];
  constructor(open: Promise<WritableStream<Uint8Array>>, onError: () => void) {
    open.then(
      (ws) => {
        this.writer = ws.getWriter();
        for (const chunk of this.pending!) this.write(chunk);
        this.pending = null;
      },
      onError,
    );
  }
  write(chunk: Uint8Array): void {
    if (this.writer) this.writer.write(chunk).catch(() => {});
    else this.pending?.push(chunk);
  }
}

class WtConn extends Conn {
  private control!: WritableStreamDefaultWriter<Uint8Array>;
  private media = new Map<number, LazyWriter>();
  constructor(user: User, readonly session: any) {
    super(user);
  }
  attachControl(writable: WritableStream<Uint8Array>): void {
    this.control = writable.getWriter();
  }
  sendText(text: string): void {
    this.control.write(frame(encoder.encode(text))).catch(() => {});
  }
  sendMedia(kind: number, header: Uint8Array, body: Uint8Array): void {
    let w = this.media.get(kind);
    if (!w) {
      w = new LazyWriter(this.session.createUnidirectionalStream(), () => {});
      this.media.set(kind, w);
    }
    w.write(frame(header, body));
  }
  close(reason: string): void {
    try {
      this.session.close({ closeCode: 0, reason });
    } catch {}
  }
}

// Reads u32 LE length-prefixed frames; returns false when a frame is too big.
async function readFrames(readable: ReadableStream<Uint8Array>, onFrame: (f: Uint8Array) => void): Promise<boolean> {
  const reader = readable.getReader();
  let buf = new Uint8Array(0);
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) return true;
      if (buf.length === 0) buf = value;
      else {
        const joined = new Uint8Array(buf.length + value.length);
        joined.set(buf, 0);
        joined.set(value, buf.length);
        buf = joined;
      }
      while (buf.length >= 4) {
        const len = new DataView(buf.buffer, buf.byteOffset, 4).getUint32(0, true);
        if (len > MAX_MEDIA) return false;
        if (buf.length < 4 + len) break;
        onFrame(buf.subarray(4, 4 + len));
        buf = buf.subarray(4 + len);
      }
    }
  } catch {
    return true; // the stream was reset or the session ended
  }
}

async function runSession(session: any): Promise<void> {
  const user: User = session.userData.user;
  session.closed.catch(() => {});
  try {
    await session.ready;
  } catch {
    if (user.conn === 'pending') user.conn = null;
    return;
  }
  const conn = new WtConn(user, session);
  let opened = false;
  session.closed.finally(() => {
    if (opened) connClosed(conn);
    else if (user.conn === 'pending') user.conn = null;
  });

  // Client media: every incoming unidirectional stream is read the same way.
  (async () => {
    const uni = session.incomingUnidirectionalStreams.getReader();
    while (true) {
      let next;
      try {
        next = await uni.read();
      } catch {
        return;
      }
      if (next.done) return;
      readFrames(next.value, (m) => handleMedia(conn, m)).then((ok) => {
        if (!ok) conn.close('message too big');
      });
    }
  })();

  // The first bidirectional stream is the control stream; others are ignored.
  const bidi = session.incomingBidirectionalStreams.getReader();
  let first;
  try {
    first = await bidi.read();
  } catch {
    return;
  }
  if (first.done) return;
  conn.attachControl(first.value.writable);
  opened = true;
  connOpened(conn);
  readFrames(first.value.readable, (f) => handleText(conn, decoder.decode(f))).then((ok) => {
    if (!ok) conn.close('message too big');
  });
  (async () => {
    while (true) {
      let next;
      try {
        next = await bidi.read();
      } catch {
        return;
      }
      if (next.done) return;
      next.value.readable.cancel().catch(() => {});
      next.value.writable.abort().catch(() => {});
    }
  })();
}

export function startWebTransport(opts: { port: number; cert: string; key: string }): void {
  const server = new Http3Server({
    port: opts.port,
    host: '0.0.0.0',
    secret: randomBytes(32).toString('hex'),
    cert: readFileSync(opts.cert, 'utf8'),
    privKey: readFileSync(opts.key, 'utf8'),
  });

  // Checks the token before the session is accepted: 401 or 409 refuse it.
  server.setRequestCallback(async (args: any) => {
    const url: string = args.header[':path'] ?? '';
    const q = url.indexOf('?');
    const path = q < 0 ? url : url.slice(0, q);
    if (path !== '/wt') return { ...args, path, status: 404 };
    const user = userByToken(new URLSearchParams(q < 0 ? '' : url.slice(q + 1)).get('token'));
    if (!user) return { ...args, path, status: 401 };
    if (user.conn) return { ...args, path, status: 409 };
    user.conn = 'pending';
    return { ...args, path, status: 200, userData: { user }, header: { ...args.header, ':path': path } };
  });

  const sessions = server.sessionStream('/wt').getReader();
  server.startServer();
  server.ready.catch((err: unknown) => console.error('vc-bun: WebTransport failed to start', err));
  (async () => {
    while (true) {
      const { done, value } = await sessions.read();
      if (done) return;
      runSession(value);
    }
  })();
}

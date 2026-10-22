// Bun video-call server (bench/videocall/SPEC.md): the HTTP API and the
// WebSocket transport on Bun.serve (TLS, TCP PORT), and WebTransport on
// UDP PORT (webtransport.ts). One process, Bun's single thread.
import type { ServerWebSocket } from 'bun';
import {
  Conn, MAX_MEDIA, connClosed, connOpened, createUser, getCall, handleMedia, handleText, userByToken,
  type User,
} from './app.ts';
import { startWebTransport } from './webtransport.ts';

const PORT = Number.parseInt(process.env.PORT ?? '8443', 10) || 8443;
const CERT = process.env.CERT ?? '/certs/cert.pem';
const KEY = process.env.KEY ?? '/certs/key.pem';

const JSON_HEADERS = { 'Content-Type': 'application/json' };
const json = (status: number, body: unknown) =>
  new Response(typeof body === 'string' ? body : JSON.stringify(body), { status, headers: JSON_HEADERS });

class WsConn extends Conn {
  constructor(user: User, readonly ws: ServerWebSocket<WsData>) {
    super(user);
  }
  sendText(text: string): void {
    this.ws.sendText(text);
  }
  sendMedia(_kind: number, header: Uint8Array, body: Uint8Array): void {
    const out = new Uint8Array(header.length + body.length);
    out.set(header, 0);
    out.set(body, header.length);
    this.ws.sendBinary(out);
  }
}

interface WsData {
  user: User;
  conn?: WsConn;
}

const bearer = (req: Request): string | null => {
  const h = req.headers.get('authorization');
  return h && h.startsWith('Bearer ') ? h.slice(7).trim() : null;
};

const server = Bun.serve<WsData, any>({
  port: PORT,
  tls: { cert: Bun.file(CERT), key: Bun.file(KEY) },
  routes: {
    '/health': () => json(200, { status: 'ok' }),
    '/api/users': {
      POST: async (req) => {
        let body: any;
        try {
          body = await req.json();
        } catch {
          return json(400, { error: 'malformed JSON body' });
        }
        const user = createUser(body?.name);
        if (!user) return json(400, { error: 'invalid name' });
        return json(201, { id: user.id, name: user.name, token: user.token });
      },
    },
    '/api/calls/:id/messages': {
      GET: (req) => {
        const user = userByToken(bearer(req));
        if (!user) return json(401, { error: 'unauthorized' });
        const id = req.params.id;
        const call = /^[0-9]+$/.test(id) ? getCall(Number(id)) : undefined;
        if (!call) return json(404, { error: 'call not found' });
        if (call.users[0] !== user && call.users[1] !== user) return json(403, { error: 'forbidden' });
        return json(200, `{"call_id":${call.id},"messages":[${call.history.join(',')}]}`);
      },
    },
    '/ws': (req, srv) => {
      const user = userByToken(new URL(req.url).searchParams.get('token'));
      if (!user) return json(401, { error: 'unauthorized' });
      if (user.conn) return json(409, { error: 'already connected' });
      // Reserved before upgrade(): Bun may run open() inside upgrade().
      user.conn = 'pending';
      if (srv.upgrade(req, { data: { user } })) return undefined;
      user.conn = null;
      return json(400, { error: 'websocket upgrade required' });
    },
  },
  fetch: () => json(404, { error: 'not found' }),
  websocket: {
    perMessageDeflate: false,
    open(ws) {
      const conn = new WsConn(ws.data.user, ws);
      ws.data.conn = conn;
      connOpened(conn);
    },
    message(ws, message) {
      const conn = ws.data.conn!;
      if (typeof message === 'string') {
        handleText(conn, message);
        return;
      }
      if (message.length > MAX_MEDIA) {
        ws.close(1009, 'message too big');
        return;
      }
      handleMedia(conn, message);
    },
    close(ws) {
      const { conn, user } = ws.data;
      if (conn) connClosed(conn);
      else if (user.conn === 'pending') user.conn = null;
    },
  },
});

startWebTransport({ port: PORT, cert: CERT, key: KEY });

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));
console.warn(`vc-bun: listening on ${server.url} (TCP) and UDP ${PORT}`);

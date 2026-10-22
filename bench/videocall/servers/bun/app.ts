// The video-call app itself, independent of the transport: users and tokens,
// the lobby, calls, chat and the media relay (bench/videocall/SPEC.md).
// server.ts (WebSocket) and webtransport.ts (WebTransport) wrap each realtime
// connection in a Conn and hand messages to handleText / handleMedia.
import { randomBytes } from 'node:crypto';
import { deflateRawSync } from 'node:zlib';

export const HEADER_LEN = 24;
export const MAX_MEDIA = 1 << 20; // 1 MiB
const FLAG_COMPRESSED = 0x02;
const HISTORY_MAX = 100;

export interface User {
  id: number;
  name: string;
  token: string;
  // The user's realtime connection, or 'pending' between the accepted
  // upgrade and the open connection (so a second one gets 409 meanwhile).
  conn: Conn | 'pending' | null;
}

export interface Call {
  id: number;
  users: [User, User];
  nextChatId: number;
  history: string[]; // each chat message exactly as it was broadcast
  ended: boolean;
}

// One realtime connection; the transport implements the two sends.
export abstract class Conn {
  call: Call | null = null;
  closed = false;
  constructor(readonly user: User) {}
  abstract sendText(json: string): void;
  // `header` is the relayed 24-byte header, `body` the compressed payload.
  abstract sendMedia(kind: number, header: Uint8Array, body: Uint8Array): void;
}

const users = new Map<number, User>();
const byToken = new Map<string, User>();
const calls = new Map<number, Call>();
const lobby = new Set<Conn>(); // insertion order: first in, first out
let nextUserId = 1;
let nextCallId = 1;

const NAME_RE = /^[A-Za-z0-9_-]{1,32}$/;

export function createUser(name: unknown): User | null {
  if (typeof name !== 'string' || !NAME_RE.test(name)) return null;
  const user: User = { id: nextUserId++, name, token: randomBytes(16).toString('hex'), conn: null };
  users.set(user.id, user);
  byToken.set(user.token, user);
  return user;
}

export const userByToken = (token: string | null | undefined): User | undefined =>
  token ? byToken.get(token) : undefined;

export const getCall = (id: number): Call | undefined => calls.get(id);

// Called once the connection is open and can send: hello, then the lobby.
export function connOpened(conn: Conn): void {
  conn.user.conn = conn;
  const { id, name } = conn.user;
  conn.sendText(JSON.stringify({ type: 'hello', user: { id, name } }));
  joinLobby(conn);
}

export function connClosed(conn: Conn): void {
  if (conn.closed) return;
  conn.closed = true;
  if (conn.user.conn === conn) conn.user.conn = null;
  lobby.delete(conn);
  if (conn.call) endCall(conn);
}

function joinLobby(conn: Conn): void {
  if (conn.closed) return;
  lobby.add(conn);
  while (lobby.size >= 2) {
    const it = lobby.values();
    const a = it.next().value as Conn;
    const b = it.next().value as Conn;
    lobby.delete(a);
    lobby.delete(b);
    startCall(a, b);
  }
}

function startCall(a: Conn, b: Conn): void {
  const call: Call = { id: nextCallId++, users: [a.user, b.user], nextChatId: 1, history: [], ended: false };
  calls.set(call.id, call);
  a.call = call;
  b.call = call;
  a.sendText(JSON.stringify({ type: 'call', call_id: call.id, peer: { id: b.user.id, name: b.user.name } }));
  b.sendText(JSON.stringify({ type: 'call', call_id: call.id, peer: { id: a.user.id, name: a.user.name } }));
}

const peerOf = (conn: Conn): Conn | null => {
  const call = conn.call;
  if (!call) return null;
  const other = call.users[0] === conn.user ? call.users[1] : call.users[0];
  return other.conn instanceof Conn && other.conn.call === call ? other.conn : null;
};

// Ends conn's call: the peer (if still connected) gets peer_left and goes
// back into the lobby. The caller decides what happens to conn itself.
function endCall(conn: Conn): void {
  const call = conn.call!;
  const peer = peerOf(conn);
  call.ended = true;
  conn.call = null;
  if (peer) {
    peer.call = null;
    peer.sendText(JSON.stringify({ type: 'peer_left', call_id: call.id }));
    joinLobby(peer);
  }
}

const errorMsg = (error: string) => JSON.stringify({ type: 'error', error });

function codePoints(s: string): number {
  let n = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) {
      const d = s.charCodeAt(i + 1);
      if (d >= 0xdc00 && d <= 0xdfff) i++;
    }
    n++;
  }
  return n;
}

export function handleText(conn: Conn, data: string): void {
  let msg: any;
  try {
    msg = JSON.parse(data);
  } catch {
    conn.sendText(errorMsg('bad message'));
    return;
  }
  if (msg === null || typeof msg !== 'object' || Array.isArray(msg)) {
    conn.sendText(errorMsg('bad message'));
    return;
  }
  switch (msg.type) {
    case 'chat': {
      const { text, sent_us } = msg;
      if (typeof text !== 'string' || text.length === 0 || codePoints(text) > 500) {
        conn.sendText(errorMsg('invalid chat'));
        return;
      }
      const call = conn.call;
      if (!call) {
        conn.sendText(errorMsg('not in a call'));
        return;
      }
      const out = JSON.stringify({
        type: 'chat',
        call_id: call.id,
        id: call.nextChatId++,
        from: conn.user.name,
        text,
        sent_us,
      });
      call.history.push(out);
      if (call.history.length > HISTORY_MAX) call.history.shift();
      conn.sendText(out);
      peerOf(conn)?.sendText(out);
      return;
    }
    case 'leave': {
      if (!conn.call) {
        conn.sendText(errorMsg('not in a call'));
        return;
      }
      endCall(conn);
      joinLobby(conn);
      return;
    }
    default:
      conn.sendText(errorMsg('bad message'));
  }
}

// A media message (header + payload), already checked to be at most 1 MiB.
export function handleMedia(conn: Conn, msg: Uint8Array): void {
  if (msg.length < HEADER_LEN) return;
  if (msg[1] & FLAG_COMPRESSED) return;
  const peer = peerOf(conn);
  if (!peer) return;
  const header = msg.slice(0, HEADER_LEN);
  header[1] |= FLAG_COMPRESSED;
  const body = deflateRawSync(msg.subarray(HEADER_LEN));
  peer.sendMedia(header[0], header, body);
}

// Bun bench server: the raw routes, the WebSockets (/ws/echo, /ws/feed,
// /ws/trade) and the $12 routes (twelve.ts). See bench/SPEC.md.
// One process per CPU sharing the port with reusePort, as Bun's docs do it.
import { twelveRoutes } from './twelve.ts';

const env = process.env;
const MODE = env.MODE ?? 'h1';
const WORKERS = Number.parseInt(env.WORKERS ?? '1', 10) || 1;

if (!['h1', 'h2c', 'tls', 'h3'].includes(MODE)) {
  console.error(`bun: mode ${MODE} is not supported (h1, h2c, tls, h3)`);
  process.exit(3);
}

if (WORKERS > 1 && !env.BUN_WORKER) {
  const procs = Array.from({ length: WORKERS }, () =>
    Bun.spawn([process.execPath, import.meta.path], { env: { ...env, BUN_WORKER: '1' }, stdio: ['inherit', 'inherit', 'inherit'] }));
  const stop = () => { for (const p of procs) p.kill(); process.exit(0); };
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  await Promise.race(procs.map((p) => p.exited));
  console.error('bun: a worker exited');
  stop();
} else {
  process.on('SIGTERM', () => process.exit(0));
  process.on('SIGINT', () => process.exit(0));

  const items = () => {
    const out = [];
    for (let i = 1; i <= 50; i++) out.push({ id: i, name: `item-${i}`, active: i % 2 === 0, score: i * 7 });
    return { items: out };
  };
  const secure = MODE === 'tls' || MODE === 'h3';
  const twelve = env.DATABASE_URL
    ? twelveRoutes({
        databaseUrl: env.DATABASE_URL,
        pgPool: Math.ceil((Number.parseInt(env.PG_POOL ?? '20', 10) || 20) / WORKERS),
        jwtSecret: env.JWT_SECRET ?? 'twelve-dollar-challenge',
      })
    : {};

  // /ws/feed: one ticker per process, waking every 10 ms with TICK_HZ/100
  // ticks, published to the 'feed' topic (Bun's pub/sub). Each wake is
  // scheduled from the previous deadline, not from now, so timer lateness
  // doesn't accumulate.
  const tickHz = Number.parseInt(env.TICK_HZ ?? '1000', 10) || 1000;
  const perWake = Math.max(1, Math.floor(tickHz / 100));
  let seq = 0;
  let deadline = performance.now();
  let server: any;
  const wake = () => {
    for (let k = 0; k < perWake; k++) {
      seq++;
      if (!server || server.subscriberCount('feed') === 0) continue;
      const ts = Math.round((performance.timeOrigin + performance.now()) * 1000);
      server.publish('feed', JSON.stringify({ seq, ts, sym: 'BTCUSD', px: 100000 + (seq % 1000), qty: 1 + (seq % 10) }));
    }
    deadline += 10;
    setTimeout(wake, Math.max(0, deadline - performance.now()));
  };
  if (tickHz > 0) wake();

  // /ws/trade: per-symbol net position, shared by every connection in this process.
  const positions = new Map<string, number>();
  const wsPaths = new Set(['/ws/echo', '/ws/feed', '/ws/trade']);

  server = Bun.serve({
    hostname: '0.0.0.0',
    port: Number(secure ? (env.HTTPS_PORT ?? 8443) : (env.HTTP_PORT ?? 8080)),
    reusePort: true,
    idleTimeout: 255, // seconds, Bun's maximum (the suite wants at least 75)
    ...(secure ? { tls: { cert: Bun.file(env.CERT_FILE ?? '/certs/cert.pem'), key: Bun.file(env.KEY_FILE ?? '/certs/key.pem') } } : {}),
    ...(MODE === 'h2c' || MODE === 'tls' ? { http2: true } : {}),
    ...(MODE === 'h3' ? { http3: true } : {}),
    routes: {
      '/plaintext': () => new Response('Hello, World!', { headers: { 'Content-Type': 'text/plain' } }),
      '/json': () => Response.json({ message: 'Hello, World!' }),
      '/users/:id': (req) => new Response(`user ${req.params.id}`, { headers: { 'Content-Type': 'text/plain' } }),
      '/list': () => Response.json(items()),
      ...twelve,
    },
    fetch(req, server) {
      const path = new URL(req.url).pathname;
      if (wsPaths.has(path) && server.upgrade(req, { data: { path } })) return;
      return Response.json({ error: 'not found' }, { status: 404 });
    },
    // Bun's own WebSocket server (uWebSockets).
    websocket: {
      idleTimeout: 960, // seconds, Bun's maximum
      maxPayloadLength: 1 << 20,
      open(ws: any) {
        if (ws.data.path === '/ws/feed') ws.subscribe('feed');
      },
      message(ws: any, message) {
        switch (ws.data.path) {
          case '/ws/echo':
            ws.send(message);
            break;
          case '/ws/trade': {
            let order: any;
            try {
              order = JSON.parse(String(message));
            } catch {
              return;
            }
            const { id, sym, side, px, qty, t } = order;
            const pos = (positions.get(sym) ?? 0) + (side === 'buy' ? qty : -qty);
            positions.set(sym, pos);
            ws.send(JSON.stringify({ id, status: 'filled', px, qty, pos, t }));
            break;
          }
        }
      },
    },
  });
}

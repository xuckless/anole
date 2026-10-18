// Fastify 5 bench server: WebSockets through @fastify/websocket (HTTP/1.1 upgrade).
import fastifyWebsocket from '@fastify/websocket';

export default async function websockets(app, { tickHz }) {
  await app.register(fastifyWebsocket);

  // /ws/feed: one ticker per process, waking every 10 ms with TICK_HZ/100 ticks.
  const subscribers = new Set();
  const perWake = Math.max(1, Math.floor(tickHz / 100));
  let seq = 0;
  // A fixed 10 ms grid: each wake is scheduled from the previous deadline, not from now,
  // so timer lateness doesn't accumulate (setInterval drifts by ~1% here).
  let deadline = performance.now();
  let timer;
  const wake = () => {
    for (let k = 0; k < perWake; k++) {
      seq++;
      if (subscribers.size === 0) continue;
      const ts = Math.round((performance.timeOrigin + performance.now()) * 1000);
      const msg = JSON.stringify({ seq, ts, sym: 'BTCUSD', px: 100000 + (seq % 1000), qty: 1 + (seq % 10) });
      for (const socket of subscribers) if (socket.readyState === socket.OPEN) socket.send(msg);
    }
    deadline += 10;
    timer = setTimeout(wake, Math.max(0, deadline - performance.now()));
  };
  wake();
  app.addHook('onClose', async () => clearTimeout(timer));

  // /ws/trade: per-symbol net position, shared by every connection in this process.
  const positions = new Map();

  app.get('/ws/echo', { websocket: true }, (socket) => {
    socket.on('message', (data, isBinary) => socket.send(data, { binary: isBinary }));
  });

  app.get('/ws/feed', { websocket: true }, (socket) => {
    subscribers.add(socket);
    socket.on('close', () => subscribers.delete(socket));
  });

  app.get('/ws/trade', { websocket: true }, (socket) => {
    socket.on('message', (data) => {
      let order;
      try {
        order = JSON.parse(data);
      } catch {
        return;
      }
      const { id, sym, side, px, qty, t } = order;
      const pos = (positions.get(sym) ?? 0) + (side === 'buy' ? qty : -qty);
      positions.set(sym, pos);
      socket.send(JSON.stringify({ id, status: 'filled', px, qty, pos, t }));
    });
  });
}

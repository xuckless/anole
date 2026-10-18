// Express 5 bench server: WebSockets through the `ws` package on the same HTTP(S) server.
import { WebSocket, WebSocketServer } from 'ws';

export function attachWebSockets(server, tickHz) {
  const wss = new WebSocketServer({ noServer: true });

  // /ws/feed: one ticker per process, waking every 10 ms with TICK_HZ/100 ticks.
  const subscribers = new Set();
  const perWake = Math.max(1, Math.floor(tickHz / 100));
  let seq = 0;
  // A fixed 10 ms grid: each wake is scheduled from the previous deadline, not from now,
  // so timer lateness doesn't accumulate (setInterval drifts by ~1% here).
  let deadline = performance.now();
  const wake = () => {
    for (let k = 0; k < perWake; k++) {
      seq++;
      if (subscribers.size === 0) continue;
      const ts = Math.round((performance.timeOrigin + performance.now()) * 1000);
      const msg = JSON.stringify({ seq, ts, sym: 'BTCUSD', px: 100000 + (seq % 1000), qty: 1 + (seq % 10) });
      for (const ws of subscribers) if (ws.readyState === WebSocket.OPEN) ws.send(msg);
    }
    deadline += 10;
    setTimeout(wake, Math.max(0, deadline - performance.now()));
  };
  wake();

  // /ws/trade: per-symbol net position, shared by every connection in this process.
  const positions = new Map();

  const routes = {
    '/ws/echo'(ws) {
      ws.on('message', (data, isBinary) => ws.send(data, { binary: isBinary }));
    },
    '/ws/feed'(ws) {
      subscribers.add(ws);
      ws.on('close', () => subscribers.delete(ws));
    },
    '/ws/trade'(ws) {
      ws.on('message', (data) => {
        let order;
        try {
          order = JSON.parse(data);
        } catch {
          return;
        }
        const { id, sym, side, px, qty, t } = order;
        const pos = (positions.get(sym) ?? 0) + (side === 'buy' ? qty : -qty);
        positions.set(sym, pos);
        ws.send(JSON.stringify({ id, status: 'filled', px, qty, pos, t }));
      });
    },
  };

  server.on('upgrade', (req, socket, head) => {
    const route = routes[new URL(req.url, 'http://localhost').pathname];
    if (!route) {
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => route(ws));
  });
}

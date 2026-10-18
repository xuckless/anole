// Express 5 bench server: HTTP routes. See bench/SPEC.md.
import express from 'express';
import { twelveRouter } from './twelve.mjs';

export function createApp({ mediaDir, retain, databaseUrl, pgPool, jwtSecret }) {
  // GC test: RETAIN objects kept reachable for the life of the process.
  const retained = [];
  for (let i = 0; i < retain; i++) {
    retained.push({ id: i, name: `retained-${i}`, tags: [`x${i % 7}`, `y${i % 11}`, `z${i % 13}`] });
  }

  const app = express();

  app.get('/plaintext', (req, res) => {
    res.type('text/plain').send('Hello, World!');
  });

  app.get('/json', (req, res) => {
    res.json({ message: 'Hello, World!' });
  });

  app.get('/users/:id', (req, res) => {
    res.type('text/plain').send(`user ${req.params.id}`);
  });

  app.get('/list', (req, res) => {
    const items = [];
    for (let i = 1; i <= 50; i++) {
      items.push({ id: i, name: `item-${i}`, active: i % 2 === 0, score: i * 7 });
    }
    res.json({ items });
  });

  // type: every request, including one without a Content-Type ('*/*' needs the header).
  app.post('/echo', express.raw({ type: () => true, limit: '8mb' }), (req, res) => {
    res.type('application/octet-stream').send(req.body ?? Buffer.alloc(0));
  });

  app.get('/gc/alloc', (req, res) => {
    const parsed = Number.parseInt(req.query.n, 10);
    const n = parsed >= 0 ? parsed : 2000;
    const nodes = [];
    for (let i = 0; i < n; i++) {
      nodes.push({ id: i, name: `node-${i}`, tags: [`a${i % 7}`, `b${i % 11}`, `c${i % 13}`], active: i % 2 === 0 });
    }
    res.json({ n, bytes: Buffer.byteLength(JSON.stringify(nodes)) });
  });

  app.get('/gc/stats', (req, res) => {
    res.json({ retained: retained.length });
  });

  app.use('/static', express.static(mediaDir));

  if (databaseUrl) app.use(twelveRouter({ databaseUrl, pgPool, jwtSecret }));

  app.use((req, res) => {
    res.status(404).json({ error: 'not found' });
  });

  app.use((err, req, res, next) => {
    if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'malformed JSON body' });
    const status = err.status ?? err.statusCode ?? 500;
    if (status >= 400 && status < 500) return res.status(status).json({ error: err.message });
    console.error(err);
    res.status(500).json({ error: 'internal server error' });
  });

  return app;
}

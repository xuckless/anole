// Bun bench server (raw routes only, for now). See bench/SPEC.md.
// One process per CPU sharing the port with reusePort, as Bun's docs do it.
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

  Bun.serve({
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
    },
    fetch: () => Response.json({ error: 'not found' }, { status: 404 }),
  });
}

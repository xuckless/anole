// Express 5 bench server: bootstrap (modes, cluster, listeners). See bench/SPEC.md.
import cluster from 'node:cluster';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import { createApp } from './app.mjs';
import { attachWebSockets } from './ws.mjs';

const env = process.env;
const MODE = env.MODE ?? 'h1';
const WORKERS = Number.parseInt(env.WORKERS ?? '1', 10) || 1;

if (MODE !== 'h1' && MODE !== 'tls') {
  console.error(`express: mode ${MODE} is not supported (h1, tls)`);
  process.exit(3);
}
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));

if (WORKERS > 1 && cluster.isPrimary) {
  for (let i = 0; i < WORKERS; i++) cluster.fork();
  cluster.on('exit', (worker, code, signal) => {
    console.error(`express: worker ${worker.process.pid} exited (${signal ?? code})`);
  });
} else {
  const app = createApp({
    mediaDir: env.MEDIA_DIR ?? '/media',
    retain: Number.parseInt(env.RETAIN ?? '0', 10) || 0,
    databaseUrl: env.DATABASE_URL,
    pgPool: Math.ceil((Number.parseInt(env.PG_POOL ?? '20', 10) || 20) / WORKERS),
    jwtSecret: env.JWT_SECRET ?? 'twelve-dollar-challenge',
  });

  let server, port;
  if (MODE === 'tls') {
    server = https.createServer(
      { cert: readFileSync(env.CERT_FILE ?? '/certs/cert.pem'), key: readFileSync(env.KEY_FILE ?? '/certs/key.pem') },
      app,
    );
    port = Number(env.HTTPS_PORT ?? 8443);
  } else {
    server = http.createServer(app);
    port = Number(env.HTTP_PORT ?? 8080);
  }
  server.keepAliveTimeout = 75_000;
  attachWebSockets(server, Number.parseInt(env.TICK_HZ ?? '1000', 10) || 1000);
  server.listen(port, '0.0.0.0');
}

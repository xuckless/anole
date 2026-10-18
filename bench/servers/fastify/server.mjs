// Fastify 5 bench server: bootstrap (modes, cluster, listeners). See bench/SPEC.md.
import cluster from 'node:cluster';
import { readFileSync } from 'node:fs';

const env = process.env;
const MODE = env.MODE ?? 'h1';
const WORKERS = Number.parseInt(env.WORKERS ?? '1', 10) || 1;

if (!['h1', 'h2c', 'tls', 'grpc'].includes(MODE)) {
  console.error(`fastify: mode ${MODE} is not supported (h1, h2c, tls, grpc)`);
  process.exit(3);
}
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));

if (WORKERS > 1 && cluster.isPrimary) {
  for (let i = 0; i < WORKERS; i++) cluster.fork();
  cluster.on('exit', (worker, code, signal) => {
    console.error(`fastify: worker ${worker.process.pid} exited (${signal ?? code})`);
  });
} else if (MODE === 'grpc') {
  const { startGrpc } = await import('./grpc.mjs');
  await startGrpc(Number(env.GRPC_PORT ?? 50051));
} else {
  const { buildApp } = await import('./app.mjs');
  const options = { logger: false, keepAliveTimeout: 75_000, http2SessionTimeout: 75_000 };
  if (MODE === 'h2c') options.http2 = true;
  if (MODE === 'tls') {
    options.http2 = true;
    options.https = {
      allowHTTP1: true,
      cert: readFileSync(env.CERT_FILE ?? '/certs/cert.pem'),
      key: readFileSync(env.KEY_FILE ?? '/certs/key.pem'),
    };
  }
  const app = await buildApp(options, {
    mediaDir: env.MEDIA_DIR ?? '/media',
    retain: Number.parseInt(env.RETAIN ?? '0', 10) || 0,
    tickHz: Number.parseInt(env.TICK_HZ ?? '1000', 10) || 1000,
    databaseUrl: env.DATABASE_URL,
    pgPool: Math.ceil((Number.parseInt(env.PG_POOL ?? '20', 10) || 20) / WORKERS),
    jwtSecret: env.JWT_SECRET ?? 'twelve-dollar-challenge',
  });
  // Fastify applies keepAliveTimeout to HTTP/1 servers only; the allowHTTP1 fallback of the
  // HTTP/2 TLS server would otherwise keep Node's 5 s default.
  if (MODE === 'tls') app.server.keepAliveTimeout = 75_000;
  const port = Number(MODE === 'tls' ? (env.HTTPS_PORT ?? 8443) : (env.HTTP_PORT ?? 8080));
  await app.listen({ port, host: '0.0.0.0' });
}

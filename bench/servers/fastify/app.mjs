// Fastify 5 bench server: HTTP routes. See bench/SPEC.md.
import fastifyStatic from '@fastify/static';
import Fastify from 'fastify';
import twelve from './twelve.mjs';
import websockets from './ws.mjs';

const jsonSchema = {
  response: {
    200: { type: 'object', properties: { message: { type: 'string' } } },
  },
};

const listSchema = {
  response: {
    200: {
      type: 'object',
      properties: {
        items: {
          type: 'array',
          items: {
            type: 'object',
            properties: {
              id: { type: 'integer' },
              name: { type: 'string' },
              active: { type: 'boolean' },
              score: { type: 'integer' },
            },
          },
        },
      },
    },
  },
};

export async function buildApp(options, { mediaDir, retain, tickHz, databaseUrl, pgPool, jwtSecret }) {
  // GC test: RETAIN objects kept reachable for the life of the process.
  const retained = [];
  for (let i = 0; i < retain; i++) {
    retained.push({ id: i, name: `retained-${i}`, tags: [`x${i % 7}`, `y${i % 11}`, `z${i % 13}`] });
  }

  const app = Fastify(options);

  // Set first, so the encapsulated plugins below inherit them.
  app.setNotFoundHandler(async (request, reply) => {
    reply.code(404);
    return { error: 'not found' };
  });

  app.setErrorHandler(async (err, request, reply) => {
    if (err.code === 'FST_ERR_CTP_INVALID_JSON_BODY' || err.code === 'FST_ERR_CTP_EMPTY_JSON_BODY') {
      reply.code(400);
      return { error: 'malformed JSON body' };
    }
    const status = err.statusCode ?? 500;
    if (status >= 400 && status < 500) {
      reply.code(status);
      return { error: err.message };
    }
    console.error(err);
    reply.code(500);
    return { error: 'internal server error' };
  });

  app.get('/plaintext', async () => 'Hello, World!');

  app.get('/json', { schema: jsonSchema }, async () => ({ message: 'Hello, World!' }));

  app.get('/users/:id', async (request) => `user ${request.params.id}`);

  app.get('/list', { schema: listSchema }, async () => {
    const items = [];
    for (let i = 1; i <= 50; i++) {
      items.push({ id: i, name: `item-${i}`, active: i % 2 === 0, score: i * 7 });
    }
    return { items };
  });

  // /echo takes any content type as a raw Buffer, in its own encapsulated scope.
  await app.register(async (scope) => {
    scope.removeAllContentTypeParsers();
    scope.addContentTypeParser('*', { parseAs: 'buffer' }, (request, body, done) => done(null, body));
    scope.post('/echo', { bodyLimit: 8 * 1024 * 1024 }, async (request, reply) => {
      reply.type('application/octet-stream');
      return request.body ?? Buffer.alloc(0);
    });
  });

  app.get('/gc/alloc', async (request) => {
    const parsed = Number.parseInt(request.query.n, 10);
    const n = parsed >= 0 ? parsed : 2000;
    const nodes = [];
    for (let i = 0; i < n; i++) {
      nodes.push({ id: i, name: `node-${i}`, tags: [`a${i % 7}`, `b${i % 11}`, `c${i % 13}`], active: i % 2 === 0 });
    }
    return { n, bytes: Buffer.byteLength(JSON.stringify(nodes)) };
  });

  app.get('/gc/stats', async () => ({ retained: retained.length }));

  await app.register(fastifyStatic, { root: mediaDir, prefix: '/static/' });

  await app.register(websockets, { tickHz });

  if (databaseUrl) await app.register(twelve, { databaseUrl, pgPool, jwtSecret });

  return app;
}

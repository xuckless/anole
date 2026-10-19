// Fastify 5 bench server: the $12 challenge routes (bench/twelve/SPEC.md) on Postgres.
import fastifyJwt from '@fastify/jwt';
import pg from 'pg';

// bigint columns and count(*) come back as JS numbers (ids stay below 2^53).
pg.types.setTypeParser(pg.types.builtins.INT8, (v) => Number.parseInt(v, 10));

const FEED_SQL = `SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 ORDER BY p.created_at DESC, p.id DESC LIMIT 20`;
const POST_SQL = `SELECT p.id, p.body, p.created_at, u.username,
       (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
  FROM posts p JOIN users u ON u.id = p.user_id
 WHERE p.id = $1`;
const INSERT_SQL = `INSERT INTO posts (user_id, body) VALUES ($1, $2) RETURNING id, created_at`;
const LIKE_SQL = `WITH p AS (SELECT id FROM posts WHERE id = $2),
     ins AS (INSERT INTO likes (user_id, post_id) SELECT $1, id FROM p
             ON CONFLICT (user_id, post_id) DO NOTHING RETURNING 1)
SELECT (SELECT count(*) FROM p) AS found, (SELECT count(*) FROM ins) AS inserted`;

const POSITIVE_INT = /^[1-9][0-9]*$/;

const post = {
  type: 'object',
  properties: {
    id: { type: 'integer' },
    body: { type: 'string' },
    created_at: { type: 'string' },
    author: { type: 'string' },
    like_count: { type: 'integer' },
  },
};
const liked = {
  type: 'object',
  properties: { liked: { type: 'boolean' }, already_liked: { type: 'boolean' }, post_id: { type: 'integer' } },
};
const healthSchema = {
  response: {
    200: { type: 'object', properties: { status: { type: 'string' }, db: { type: 'string' }, uptime_s: { type: 'integer' } } },
  },
};
const feedSchema = { response: { 200: { type: 'object', properties: { posts: { type: 'array', items: post } } } } };
const postSchema = { response: { 200: { type: 'object', properties: { post } } } };
const createSchema = { response: { 201: { type: 'object', properties: { post } } } };
const likeSchema = { response: { 200: liked, 201: liked } };

const toPost = (r) => ({ id: r.id, body: r.body, created_at: r.created_at, author: r.username, like_count: r.like_count });

export default async function twelve(app, { databaseUrl, pgPool, jwtSecret }) {
  const pool = new pg.Pool({ connectionString: databaseUrl, max: pgPool });
  app.addHook('onClose', () => pool.end());
  const started = Date.now();

  await app.register(fastifyJwt, { secret: jwtSecret, verify: { algorithms: ['HS256'] } });

  // load.js likes a post with Content-Type: application/json and no body,
  // which Fastify's JSON parser rejects (FST_ERR_CTP_EMPTY_JSON_BODY): an
  // empty body is no body here, anything else goes to Fastify's own parser.
  const json = app.getDefaultJsonParser('error', 'error');
  app.removeContentTypeParser('application/json');
  app.addContentTypeParser('application/json', { parseAs: 'string' }, (request, body, done) =>
    body === '' ? done(null, undefined) : json(request, body, done));

  // onRequest runs before the body is parsed, so auth is checked before anything else.
  async function authenticate(request, reply) {
    const header = request.headers.authorization;
    if (typeof header !== 'string' || !header.startsWith('Bearer ')) {
      return reply.code(401).send({ error: 'missing bearer token' });
    }
    let claims;
    try {
      claims = await request.jwtVerify();
    } catch {
      return reply.code(401).send({ error: 'invalid or expired token' });
    }
    if (typeof claims.sub !== 'string' || !POSITIVE_INT.test(claims.sub) || typeof claims.username !== 'string') {
      return reply.code(401).send({ error: 'invalid token payload' });
    }
  }

  function postId(request, reply) {
    const id = request.params.id;
    if (!POSITIVE_INT.test(id)) {
      reply.code(400).send({ error: 'invalid post id' });
      return 0;
    }
    return Number(id);
  }

  app.get('/health', { schema: healthSchema }, async (request, reply) => {
    try {
      await pool.query('SELECT 1');
    } catch (err) {
      reply.code(503);
      return { status: 'degraded', db: 'unreachable', error: err.message };
    }
    return { status: 'ok', db: 'ok', uptime_s: Math.floor((Date.now() - started) / 1000) };
  });

  app.get('/feed', { schema: feedSchema }, async () => {
    const { rows } = await pool.query(FEED_SQL);
    return { posts: rows.map(toPost) };
  });

  app.get('/posts/:id', { schema: postSchema }, async (request, reply) => {
    const id = postId(request, reply);
    if (!id) return reply;
    const { rows } = await pool.query(POST_SQL, [id]);
    if (rows.length === 0) return reply.code(404).send({ error: 'post not found' });
    return { post: toPost(rows[0]) };
  });

  app.post('/posts', { schema: createSchema, onRequest: authenticate }, async (request, reply) => {
    const raw = request.body?.body;
    const body = typeof raw === 'string' ? raw.trim() : '';
    if (!body) return reply.code(400).send({ error: 'body is required' });
    // Characters are code points (as Postgres' char_length counts them).
    if (body.length > 500 && [...body].length > 500) {
      return reply.code(400).send({ error: 'body must be at most 500 characters' });
    }
    const { rows } = await pool.query(INSERT_SQL, [Number(request.user.sub), body]);
    const { id, created_at } = rows[0];
    reply.code(201);
    return { post: { id, body, created_at, author: request.user.username, like_count: 0 } };
  });

  app.post('/posts/:id/like', { schema: likeSchema, onRequest: authenticate }, async (request, reply) => {
    const id = postId(request, reply);
    if (!id) return reply;
    const { rows } = await pool.query(LIKE_SQL, [Number(request.user.sub), id]);
    if (rows[0].found === 0) return reply.code(404).send({ error: 'post not found' });
    const inserted = rows[0].inserted === 1;
    reply.code(inserted ? 201 : 200);
    return { liked: true, already_liked: !inserted, post_id: id };
  });
}

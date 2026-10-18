// Express 5 bench server: the $12 challenge routes (bench/twelve/SPEC.md) on Postgres.
import express from 'express';
import jwt from 'jsonwebtoken';
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

const toPost = (r) => ({ id: r.id, body: r.body, created_at: r.created_at, author: r.username, like_count: r.like_count });

export function twelveRouter({ databaseUrl, pgPool, jwtSecret }) {
  const pool = new pg.Pool({ connectionString: databaseUrl, max: pgPool });
  const started = Date.now();
  const router = express.Router();

  function requireAuth(req, res, next) {
    const header = req.get('authorization');
    if (!header || !header.startsWith('Bearer ')) return res.status(401).json({ error: 'missing bearer token' });
    let claims;
    try {
      claims = jwt.verify(header.slice(7), jwtSecret, { algorithms: ['HS256'] });
    } catch {
      return res.status(401).json({ error: 'invalid or expired token' });
    }
    if (typeof claims.sub !== 'string' || !POSITIVE_INT.test(claims.sub) || typeof claims.username !== 'string') {
      return res.status(401).json({ error: 'invalid token payload' });
    }
    req.user = { id: Number(claims.sub), username: claims.username };
    next();
  }

  function postId(req, res) {
    const id = req.params.id;
    if (!POSITIVE_INT.test(id)) {
      res.status(400).json({ error: 'invalid post id' });
      return 0;
    }
    return Number(id);
  }

  router.get('/health', async (req, res) => {
    try {
      await pool.query('SELECT 1');
    } catch (err) {
      return res.status(503).json({ status: 'degraded', db: 'unreachable', error: err.message });
    }
    res.json({ status: 'ok', db: 'ok', uptime_s: Math.floor((Date.now() - started) / 1000) });
  });

  router.get('/feed', async (req, res) => {
    const { rows } = await pool.query(FEED_SQL);
    res.json({ posts: rows.map(toPost) });
  });

  router.get('/posts/:id', async (req, res) => {
    const id = postId(req, res);
    if (!id) return;
    const { rows } = await pool.query(POST_SQL, [id]);
    if (rows.length === 0) return res.status(404).json({ error: 'post not found' });
    res.json({ post: toPost(rows[0]) });
  });

  router.post('/posts', requireAuth, express.json({ strict: false }), async (req, res) => {
    const raw = req.body?.body;
    const body = typeof raw === 'string' ? raw.trim() : '';
    if (!body) return res.status(400).json({ error: 'body is required' });
    // Characters are code points (as Postgres' char_length counts them).
    if (body.length > 500 && [...body].length > 500) {
      return res.status(400).json({ error: 'body must be at most 500 characters' });
    }
    const { rows } = await pool.query(INSERT_SQL, [req.user.id, body]);
    const { id, created_at } = rows[0];
    res.status(201).json({ post: { id, body, created_at, author: req.user.username, like_count: 0 } });
  });

  router.post('/posts/:id/like', requireAuth, async (req, res) => {
    const id = postId(req, res);
    if (!id) return;
    const { rows } = await pool.query(LIKE_SQL, [req.user.id, id]);
    if (rows[0].found === 0) return res.status(404).json({ error: 'post not found' });
    const inserted = rows[0].inserted === 1;
    res.status(inserted ? 201 : 200).json({ liked: true, already_liked: !inserted, post_id: id });
  });

  return router;
}

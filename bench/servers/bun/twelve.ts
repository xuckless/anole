// Bun bench server: the $12 challenge routes (bench/twelve/SPEC.md) on
// Postgres, with Bun's built-in client (Bun.SQL) and jsonwebtoken.
import { SQL } from 'bun';
import jwt from 'jsonwebtoken';

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

// bigint columns and count(*) arrive as strings; ids stay below 2^53.
const toPost = (r: any) => ({ id: Number(r.id), body: r.body, created_at: r.created_at, author: r.username, like_count: Number(r.like_count) });
const fail = (status: number, error: string) => Response.json({ error }, { status });

export function twelveRoutes({ databaseUrl, pgPool, jwtSecret }: { databaseUrl: string; pgPool: number; jwtSecret: string }) {
  const sql = new SQL({ url: databaseUrl, max: pgPool });
  const started = Date.now();

  // Auth comes before anything else; a failure is the 401 response itself.
  function authenticate(req: Request): { sub: number; username: string } | Response {
    const header = req.headers.get('authorization');
    if (!header || !header.startsWith('Bearer ')) return fail(401, 'missing bearer token');
    let claims: any;
    try {
      claims = jwt.verify(header.slice(7), jwtSecret, { algorithms: ['HS256'] });
    } catch {
      return fail(401, 'invalid or expired token');
    }
    if (typeof claims.sub !== 'string' || !POSITIVE_INT.test(claims.sub) || typeof claims.username !== 'string') {
      return fail(401, 'invalid token payload');
    }
    return { sub: Number(claims.sub), username: claims.username };
  }

  const postId = (raw: string) => (POSITIVE_INT.test(raw) ? Number(raw) : 0);

  return {
    '/health': {
      GET: async () => {
        try {
          await sql.unsafe('SELECT 1');
        } catch (err: any) {
          return Response.json({ status: 'degraded', db: 'unreachable', error: err.message }, { status: 503 });
        }
        return Response.json({ status: 'ok', db: 'ok', uptime_s: Math.floor((Date.now() - started) / 1000) });
      },
    },
    '/feed': {
      GET: async () => Response.json({ posts: (await sql.unsafe(FEED_SQL)).map(toPost) }),
    },
    '/posts/:id': {
      GET: async (req: any) => {
        const id = postId(req.params.id);
        if (!id) return fail(400, 'invalid post id');
        const rows = await sql.unsafe(POST_SQL, [id]);
        if (rows.length === 0) return fail(404, 'post not found');
        return Response.json({ post: toPost(rows[0]) });
      },
    },
    '/posts': {
      POST: async (req: Request) => {
        const who = authenticate(req);
        if (who instanceof Response) return who;
        const text = await req.text();
        let parsed: any;
        try {
          parsed = text === '' ? undefined : JSON.parse(text);
        } catch {
          return fail(400, 'malformed JSON body');
        }
        const raw = parsed?.body;
        const body = typeof raw === 'string' ? raw.trim() : '';
        if (!body) return fail(400, 'body is required');
        // Characters are code points (as Postgres' char_length counts them).
        if (body.length > 500 && [...body].length > 500) return fail(400, 'body must be at most 500 characters');
        const [row] = await sql.unsafe(INSERT_SQL, [who.sub, body]);
        return Response.json(
          { post: { id: Number(row.id), body, created_at: row.created_at, author: who.username, like_count: 0 } },
          { status: 201 },
        );
      },
    },
    '/posts/:id/like': {
      POST: async (req: any) => {
        const who = authenticate(req);
        if (who instanceof Response) return who;
        const id = postId(req.params.id);
        if (!id) return fail(400, 'invalid post id');
        const [row] = await sql.unsafe(LIKE_SQL, [who.sub, id]);
        if (Number(row.found) === 0) return fail(404, 'post not found');
        const inserted = Number(row.inserted) === 1;
        return Response.json({ liked: true, already_liked: !inserted, post_id: id }, { status: inserted ? 201 : 200 });
      },
    },
  };
}

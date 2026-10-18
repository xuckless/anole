CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
CREATE INDEX posts_user_id_idx       ON posts (user_id);
CREATE INDEX likes_post_id_idx       ON likes (post_id);
SELECT setval(pg_get_serial_sequence('users', 'id'), (SELECT max(id) FROM users));
SELECT setval(pg_get_serial_sequence('posts', 'id'), (SELECT max(id) FROM posts));
ANALYZE;

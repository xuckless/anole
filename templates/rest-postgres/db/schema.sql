-- The table the API uses. compose.yaml mounts this file into Postgres, so it
-- runs the first time the database container starts; run it by hand (psql
-- "$DATABASE_URL" -f db/schema.sql) against any other database.
CREATE TABLE IF NOT EXISTS todos (
  id bigserial PRIMARY KEY,
  title text NOT NULL UNIQUE CHECK (title <> ''),
  done boolean NOT NULL DEFAULT false
);

# Storage, email and outbound clients

Object storage, mail and outbound HTTP are built in, with retries and circuit breakers shared by every client; never hand-roll SigV4 signing, an SMTP session, MIME encoding, a connection pool or a retry/backoff loop.

Up: [SKILL.md](../../SKILL.md). Full docs: docs/storage.md, docs/email.md, docs/clients.md, docs/resilience.md. Examples: examples/clients/main.zig, templates/full/src/main.zig (`upstream`, `app.s3`, `app.smtp`).

| Need | Use | File |
| --- | --- | --- |
| Files in S3, R2, MinIO, B2, Supabase: put, get, stream, serve with Range/ETag, presigned URLs, multipart | `app.s3`, `anole.s3.Client`, `anole.s3.Bucket` | [s3.md](s3.md) |
| Send email: HTML, text, attachments, inline images, pooled SMTP | `app.smtp`, `anole.smtp.Client` | [smtp.md](smtp.md) |
| Call another HTTP service from a handler or a task | `anole.client(req).fetch`, `app.client()`, `anole.ClientResponse` | [http-client.md](http-client.md) |
| Retries with backoff, retry throttling, circuit breakers, for the clients or your own code | `anole.resilience` | [resilience.md](resilience.md) |

S3 and SMTP have the database connectors' shape: a handle in App state, every call takes the request (or a `*Job`, `*Msg`) first, errors are `anole.db.Error` so a handler's `try` gives the right status, `Options.errors` remaps classes, and `anole.db.lastError(c)` has the class, code and the server's words. See [databases](../databases/index.md).

Build flags: `-Ds3` and `-Dsmtp`; `anole.client` and `anole.resilience` are in every build; TLS needs `-Dtls=boringssl`. Profiles: [config-cli](../config-cli.md#feature-flags-and-profiles). With a flag off, `app.s3` / `app.smtp` is a compile error naming the flag (src/server.zig).

Shared runtime rules: [never block an executor](../runtime.md#never-block-an-executor), [re-raise error.Canceled](../runtime.md#re-raise-errorcanceled), [writes return once buffered](../runtime.md#writes-return-once-buffered), [request arena and lifetimes](../runtime.md#request-arena-and-lifetimes).

Related areas: [messaging and jobs](../messaging/index.md) (send mail or call slow services from a job), [HTTP](../http/index.md) (`ServerOptions`, handlers), [observability](../observability.md) (breaker and retry metrics), [testing](../testing.md) (the S3 and SMTP fakes).

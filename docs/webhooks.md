# Webhooks

Webhooks are HTTP calls between servers: you send one to tell your customer's
server something happened, and you receive one when a service like Stripe or
GitHub wants to tell you. Anole does both, signed and retried, in a few lines.

Needs `-Dwebhooks` (on in the `web` and `full` profiles) and `-Djobs`, because
each delivery runs as a job.

## Sending

```zig
const jobs = try app.jobs(.{ .store = .{ .postgres = pg } });
const hooks = try app.webhooks(.{ .jobs = jobs });

// Once per customer endpoint (a settings page, an API call of yours):
const made = try hooks.createEndpoint(req, .{
    .owner = "acme",                    // your customer's account id
    .url = "https://acme.test/hooks",
    .types = &.{"invoice.*"},           // empty: every event
});
// made.secret is "whsec_...": show it to your customer once.

// When something happens:
_ = try hooks.publish(req, .{ .owner = "acme", .type = "invoice.paid" }, .{ .id = 7, .total = 4200 });
```

`publish` stores the message once and enqueues one delivery per enabled
endpoint of the owner whose `types` match. It returns when that is stored, not
when the customer's server has answered. `EventHead.id` makes a publish
idempotent: the same id for the same owner is published once. `publishIn(tx, ...)`
enqueues the deliveries in your own database transaction, so they exist only if
it commits.

### What the receiver sees

A `POST` with the JSON body `{"type":"invoice.paid","timestamp":"...","data":{...}}`
and the headers of [Standard Webhooks](https://www.standardwebhooks.com):

- `webhook-id`: the message id (`msg_...`), the same on every attempt;
- `webhook-timestamp`: seconds, of this attempt;
- `webhook-signature`: `v1,<base64 HMAC-SHA256>` over `id.timestamp.body`, one
  entry per active secret.

Every language has an off-the-shelf verifier for it.

### Retries and failures

A 2xx is delivered. Anything else, a timeout or a transport error is retried:
10 attempts with ceilings of 5 s, 25 s, 2 min, 10 min, 52 min, 4.3 h, 21.7 h and
24 h, about three days (`attempts`, `backoff`). `429` and `503` honour
`Retry-After`. A `410 Gone` disables the endpoint. A redirect is a failure. One
circuit breaker per origin keeps a dead receiver from spending every queued
delivery's attempts. An endpoint whose deliveries have all failed for
`disable_after` (5 days) is disabled and `on_event` is called, so you can tell
your customer; `hooks.enable(req, id)` puts it back, `hooks.recover(req,
endpoint, since)` re-sends what failed, and `hooks.replay(req, message_id, null)`
re-sends one message. `hooks.attempts` and `hooks.messages` read the log.

There is no ordering between deliveries: a slow endpoint must not hold the
others up.

### Addresses and secrets

Endpoint URLs come from your customers, so they are untrusted input. In
production a delivery refuses loopback, private, link-local and cloud-metadata
addresses (checked after DNS, on the address connected to) and plain `http://`.
In development both are allowed so you can point at `localhost`. Set
`allow_private_addresses` and `require_https` to decide otherwise.

`rotateSecret(req, id, .fromSeconds(24 * 3600))` makes a new secret and keeps the
old one signing for that long, so receivers can switch over. Secrets are stored as
they are unless `secrets_key` (or `ANOLE_WEBHOOKS_KEY`, 32 bytes of base64) is
set: then they are encrypted with XChaCha20-Poly1305. The HMAC needs the plain
secret, so hashing is not an option.

### Storage

Endpoints, messages and the delivery log live in the jobs store's database
(tables `<table_prefix>webhook_endpoints`, `_messages` and `_attempts`, made at
start unless the jobs client has `migrate = false`), or in memory. `hooks.messages` pages by
message id, newest first: pass the last id of a page as `before` for the next.
Ids compare by bytes on every store (`msg_D` sorts below `msg_c`). Generated
ids (`msg_` and a ULID) sort by time; your own `EventHead.id`s sort as text.

On PostgreSQL the id columns are `COLLATE "C"`, whatever the database's
collation. Tables made before 0.4.2 took the database's default collation (often
`en_US.UTF-8` or ICU), which pages in a different order. The first start of
0.4.2 or later finds that in `pg_attribute` and runs, once per table,

```sql
ALTER TABLE anole_webhook_messages ALTER COLUMN id TYPE text COLLATE "C";
ALTER TABLE anole_webhook_attempts ALTER COLUMN message_id TYPE text COLLATE "C",
                                   ALTER COLUMN endpoint_id TYPE text COLLATE "C";
```

The table is not rewritten, but its indexes are rebuilt under an `ACCESS
EXCLUSIVE` lock, so publishing and listing wait until it is done. To pick the
moment yourself, run those statements before upgrading; later starts only read
the catalog.

## Receiving

```zig
const hook = app.webhookVerify(.{
    .preset = .stripe,
    .secrets = &.{secret},          // one or more: rotation
});
app.with(.{hook}).post("/hooks/stripe", stripeHook);

fn stripeHook(req: *anole.Request, res: *anole.Response) !void {
    const body = (try req.body()) orelse "";   // the bytes that were signed
    ...
}
```

Presets: `.standard`, `.stripe`, `.github`, `.slack`, and `.hmac` for anything
that signs the body with a shared secret (name the header, algorithm, encoding
and prefix). The signature is checked over the body as received, with a
constant-time comparison; parse that same body in the handler, never a
re-serialized copy. A missing or wrong signature, or a timestamp more than
`tolerance` (5 minutes) away, answers 400 and nothing else (the reason goes to the
log at info).

Senders deliver more than once, so the middleware also drops duplicates: the
delivery's id is claimed before your handler runs and marked after a 2xx. An id
already processed answers 200 without running the handler; one still running
answers 409 with `Retry-After`, so the sender tries again later; a handler that
fails releases the id, so the retry is processed. `dedup` is `.{ .memory = .{} }`
by default (this process only, bounded), `.{ .redis = .{ .client = redis } }`
when several instances run, or `.none`. When the store fails the request gets 503
(`on_store_error = .process` runs the handler anyway). A route behind `Verify`
is never `noWait`.

`anole.webhooks.inbound(req)` tells a handler what was checked (the preset and
the delivery id). `anole.webhooks.standard.sign` and `.verify` are the plain
functions, for tests and for senders of your own.

## From other languages

The C ABI has the same thing: the `"webhooks"` configuration and the
`webhook_verify` middleware in the JSON, `anole_webhooks_publish` to send,
`anole_webhooks_watch` for status events, and `anole_jobs_admin` for endpoints.
See [the C ABI](c-abi.md#webhooks).

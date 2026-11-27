# Webhooks

Up: [index](index.md). Related: [jobs](jobs.md) (each delivery is a job), [http client](../storage-email-clients/http-client.md), [middleware and auth](../middleware-auth/index.md).

Out: signed (Standard Webhooks), retried, per-endpoint deliveries with a circuit breaker per origin, SSRF protection and secret rotation. In: a `Verify` middleware for Standard Webhooks, Stripe, GitHub, Slack and any HMAC scheme, with duplicate suppression. Never hand-roll HMAC signing, a delivery retry loop or a signature check. Needs `-Dwebhooks` **and** `-Djobs`: build.zig fails with "-Dwebhooks=true requires -Djobs=true (webhook deliveries run as jobs)" ([config-cli](../config-cli.md#feature-flags-and-profiles)). Full docs: docs/webhooks.md. Tests: src/webhooks/webhooks_test.zig.

Use:
- `anole.App.webhooks` (src/server.zig): `app.webhooks(.{ .jobs = jobs })` returns `*anole.webhooks.Client`
- `anole.webhooks.Client`: `createEndpoint`, `updateEndpoint`, `deleteEndpoint`, `getEndpoint`, `listEndpoints`, `publish`, `publishJson`, `publishIn`, `rotateSecret`, `enable`, `replay`, `recover`, `attempts`, `messages` (src/webhooks/root.zig)
- `anole.webhooks.Options`, `anole.webhooks.NewEndpoint`, `anole.webhooks.EndpointPatch`, `anole.webhooks.EventHead`, `anole.webhooks.Created`, `anole.webhooks.Published` (src/webhooks/root.zig)
- `anole.App.webhookVerify` (src/server.zig) returns `*anole.webhooks.Verify`; `anole.webhooks.Verify.Options`, `anole.webhooks.Verify.Preset`, `anole.webhooks.Verify.Hmac` (src/webhooks/verify.zig)
- `anole.webhooks.inbound`, `anole.webhooks.Inbound` (src/webhooks/verify.zig); `anole.webhooks.standard.sign`, `anole.webhooks.standard.verify` (src/webhooks/sign.zig)

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

`publish` stores the message once and enqueues one delivery per enabled matching endpoint of the owner; it returns when stored, not when delivered. `EventHead.id` makes it idempotent per owner. `publishIn(&tx, req, ...)` enqueues inside your transaction. The receiver gets a `POST` with `{"type","timestamp","data"}` and `webhook-id`, `webhook-timestamp`, `webhook-signature` (`v1,<base64 HMAC-SHA256>` per active secret).

Retries: 10 attempts over about three days (`attempts`, `backoff`); `429`/`503` honour `Retry-After`; `410 Gone` disables the endpoint; a redirect is a failure. After `disable_after` (5 days) of failures the endpoint is disabled and `on_event` fires; `hooks.enable`, `hooks.recover(req, endpoint, since)` and `hooks.replay(req, message_id, null)` put things back.

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

Presets: `.standard`, `.stripe`, `.github`, `.slack`, `.hmac` (set `.hmac = .{ .header, .algorithm, .encoding, .prefix, .id_header }`). A missing or wrong signature, or a timestamp outside `tolerance` (5 min), answers 400. Duplicates: an id already processed answers 200 without the handler; one in progress answers 409 with `Retry-After`; a failing handler releases the id. `dedup`: `.{ .memory = .{} }` (default, one process), `.{ .redis = .{ .client = redis } }` for several instances, or `.none`. `anole.webhooks.inbound(req)` says which preset and delivery id were checked.

Traps:
- Parse the body the middleware checked (`req.body()`), never a re-serialized copy (docs/webhooks.md#receiving).
- Several instances behind a load balancer: set `dedup` to Redis, or each process dedups only its own deliveries.
- A dedup store failure answers 503 unless `on_store_error = .process`.
- Endpoint URLs are untrusted. In production private, loopback, link-local and metadata addresses and plain `http://` are refused (after DNS); in development both are allowed. Set `allow_private_addresses` / `require_https` explicitly if you depend on either.
- Without `secrets_key` (or `ANOLE_WEBHOOKS_KEY`, 32 bytes base64) endpoint secrets are stored in plain text. Set it in production.
- Deliveries are at least once and unordered: receivers must dedup by `webhook-id`.
- `app.webhookVerify` panics on invalid options (src/server.zig `webhookVerify`); it is meant for startup, not per request.
- Rotate with `hooks.rotateSecret(req, id, .fromSeconds(24 * 3600))`: the old secret keeps signing for that long.
- PostgreSQL: the first start after upgrading from 0.4.0 runs an `ALTER TABLE ... COLLATE "C"` and a `CREATE INDEX` under locks; on a large table run them yourself first (docs/webhooks.md#storage).

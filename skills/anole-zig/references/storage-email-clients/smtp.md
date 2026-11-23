# Email (SMTP)

Up: [index](index.md). Related: [jobs](../messaging/jobs.md) (send from a job when it must survive a restart), [resilience](resilience.md).

`anole.smtp` sends mail over SMTP: STARTTLS or implicit TLS, AUTH PLAIN and LOGIN, text and HTML, attachments and inline images, a connection pool per executor, header-injection checks. Pure Zig. Needs `-Dsmtp` ([config-cli](../config-cli.md#feature-flags-and-profiles)). Full docs: docs/email.md. Tests: src/smtp/smtp_test.zig.

Use:
- `anole.App.smtp` (src/server.zig): `app.smtp(.{})` returns `*anole.smtp.Client`
- `anole.smtp.Client`: `send`, `sendRaw`, `with`, `closeIdle` (src/smtp/root.zig)
- `anole.smtp.Options`, `anole.smtp.CallOptions`, `anole.smtp.Sent`, `anole.smtp.Envelope` (src/smtp/root.zig)
- `anole.smtp.Message`, `anole.smtp.Attachment`, `anole.smtp.Header` (src/smtp/mime.zig)
- `anole.smtp.testing.FakeServer` (`init`, `url`, `messageCount`, `message`, `queueFinalCodes`, `deinit`) (src/smtp/testing.zig)

## Setup and send

```zig
const App = struct { mail: *anole.smtp.Client };

var state: App = undefined;
var app = try anole.Server(App).init(gpa, .{}, &state);
state.mail = try app.smtp(.{}); // SMTP_URL, else Mailpit on 127.0.0.1:1025

fn forgot(app: *App, req: *anole.Request, res: *anole.Response) !void {
    const body = try req.bind(struct { email: []const u8 });
    const token = try makeResetToken(req, body.email); // yours
    const link = try std.fmt.allocPrint(req.arena, "https://example.com/reset?token={s}", .{token});
    _ = try app.mail.send(req, .{
        .to = &.{body.email},
        .subject = "Reset your password",
        .text = link,
    });
    res.status = .accepted;
}
```

`SMTP_URL`: `smtp://user:password@host:587` (STARTTLS, required on a public host), `smtps://user:password@host:465` (TLS from the first byte), `smtp://127.0.0.1:1025?tls=none` (plain, local sink). Percent-encode special characters (`you%40gmail.com`). `SMTP_FROM` or `Options.from` is the default `From`. `Options`: `url`, `from`, `username`, `password`, `tls_mode` (`.auto`, `.starttls`, `.implicit`, `.none`), `tls`, `max_connections`, `timeout` (30 s plus size at `min_throughput`), `max_message_bytes` (25 MiB), `retry`, `breaker`, `readiness`, `errors`.

## A full message

```zig
_ = try app.mail.send(req, .{
    .from = "App <hello@example.com>",
    .reply_to = "support@example.com",
    .to = &.{ "Ada Lovelace <ada@example.com>", "bob@example.com" },
    .cc = &.{"carol@example.com"},
    .bcc = &.{"audit@example.com"},      // sent to, never written into the message
    .subject = "Your invoice",
    .text = "Plain version.",
    .html = "<p>Rich version <img src=\"cid:logo\"></p>",
    .headers = &.{.{ "List-Unsubscribe", "<mailto:unsub@example.com>" }},
    .attachments = &.{
        .{ .filename = "logo.png", .content = .{ .bytes = logo }, .content_id = "logo" }, // inline
        .{ .filename = "invoice.pdf", .content = .{ .file = "/var/app/invoices/42.pdf" } },
    },
});
```

The MIME tree, encodings (quoted-printable, base64, RFC 2047/2231) and dot-stuffing are done for you. A `.file` attachment is streamed while sending. `Sent` has `message_id`, `accepted`, `rejected` (some recipients refused is not an error), `response`, `code`. `sendRaw(req, .{ .from = ..., .to = ... }, bytes)` sends RFC 5322 bytes composed elsewhere.

## Retries

```zig
_ = try app.mail.with(.{ .retry = true }).send(req, msg);
```

Retries are **opt-in**: they repeat failures before the final "." and 4xx "try later" answers (`Options.retry`: 3 attempts, 500 ms to 5 s). A connection lost after the final "." is never retried. A breaker is on by default (`circuit_open`).

Traps:
- Do not hold up the response for mail that must not be lost: send it from a [job](../messaging/jobs.md) (`app.mail.send(job, msg)`), with `.retry = true`. A job retry after a post-"." loss is the one place a duplicate can come from (docs/email.md#after-the-response).
- In production a missing `SMTP_URL` fails `app.smtp` with `error.InvalidOptions`; in development it sends to Mailpit (`docker run -d -p 1025:1025 -p 8025:8025 axllent/mailpit`).
- Never build headers by string concatenation: CR, LF or NUL in a subject, address, file name or header is `error.BadRequest` (`invalid_header`); `Date`, `From`, `To`, `Subject`, `Message-ID`, `MIME-Version`, `Content-*` and the other address headers cannot go in `headers`.
- Over 100 recipients in one message is `too_many_recipients`; batch them.
- Keep the password in an `anole.Secret` and pass `.expose()` to `Options.password`.
- Before freezing a process (Lambda), `app.mail.closeIdle()`.
- No DKIM, CRAM-MD5, XOAUTH2 or bounce handling (docs/email.md#what-it-leaves-out); use a relay that signs.
- Tests: `anole.smtp.testing.FakeServer.init(gpa, io, .{})`, point `Client.init(gpa, io, .{ .url = fake.url(&url_buf), .from = ... })` at it, then `fake.messageCount()` and `fake.message(0)` ([testing](../testing.md)).

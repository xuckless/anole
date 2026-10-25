# Email

`anole.smtp` sends mail over SMTP: STARTTLS or TLS from the first byte,
AUTH PLAIN and LOGIN, HTML and plain text, attachments and inline images,
and a pool of connections per executor. It is a pure Zig connector (no C
dependency) behind `-Dsmtp`, on in the `web` and `full` profiles. It has the
same shape as every connector (docs/database.md): a handle in the App
state, every call takes the request first, errors are `anole.db.Error` with
`lastError`, and a call has a timeout.

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

## In development: Mailpit

[Mailpit](https://mailpit.axllent.org) is a mail server that keeps what it
receives and shows it in a web page. With nothing set, Anole sends to its
SMTP port, `127.0.0.1:1025`, and says so once in the log:

```sh
docker run -d -p 1025:1025 -p 8025:8025 axllent/mailpit
# open http://localhost:8025
```

In production a missing `SMTP_URL` stops `app.smtp` (`error.InvalidOptions`,
"SMTP_URL is not set; mail would go to a local test server"), so a
production run never loses mail to a sink without saying so.

## SMTP_URL

| URL | Meaning |
| --- | --- |
| `smtp://user:password@host:587` | STARTTLS on the port (587 by default). A server on a public address that does not offer it fails the connect (`starttls_unavailable`): the password would cross the network in clear text. |
| `smtps://user:password@host:465` | TLS from the first byte (465 by default). |
| `smtp://127.0.0.1:1025?tls=none` | Plain SMTP, for a local sink. Credentials over plain SMTP are refused unless the host is loopback. |
| `smtp://localhost:1025` | Loopback: STARTTLS when the server offers it, plain otherwise. |

Percent-encode special characters in the user name and password
(`p%40ss` is `p@ss`). `Options.username` and `Options.password` override the
URL's; keep the password in an `anole.Secret` and pass `.expose()`.
`Options.tls_mode` (`.auto`, `.starttls`, `.implicit`, `.none`) overrides what
the URL implies. The certificate is checked against the system store; give
`tls.ca` for a private CA.

`SMTP_FROM` (or `Options.from`) is the default `From`, so a message can leave
`from` out.

### Per provider

| Provider | `SMTP_URL` | Notes |
| --- | --- | --- |
| Amazon SES | `smtps://USER:PASSWORD@email-smtp.eu-west-1.amazonaws.com:465` | SMTP credentials, not your IAM key. The `From` address or domain must be verified. |
| Postmark | `smtp://TOKEN:TOKEN@smtp.postmarkapp.com:587` | The server token is both user and password. |
| Resend | `smtps://resend:API_KEY@smtp.resend.com:465` | |
| Mailgun | `smtp://postmaster@mg.example.com:PASSWORD@smtp.mailgun.org:587` | Percent-encode the `@` in the user name. |
| SendGrid | `smtp://apikey:API_KEY@smtp.sendgrid.net:587` | |
| Gmail | `smtp://you%40gmail.com:APP_PASSWORD@smtp.gmail.com:587` | An app password; the account needs 2-step verification. |
| Fastmail | `smtps://you%40fastmail.com:APP_PASSWORD@smtp.fastmail.com:465` | |

## Composing a message

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

- **Addresses** are `local@domain` or `Name <local@domain>` (a quoted name
  may hold commas: `"Lovelace, Ada" <ada@example.com>`). A mistyped one is
  `error.BadRequest` with `lastError` code `invalid_address`, before
  anything is sent.
- **MIME** is the tree mail clients expect: `multipart/mixed` (attachments)
  around `multipart/related` (inline images, referenced as `cid:<content_id>`)
  around `multipart/alternative` (text and HTML), each level only when it is
  needed. Text is 7bit when it is ASCII with short lines, quoted-printable
  otherwise; attachments are base64 in 76-column lines. Non-ASCII subjects
  and names are RFC 2047 encoded words, non-ASCII file names RFC 2231.
- **A file attachment** is read while sending, in pieces, so a 20 MiB file
  does not sit in memory. The file's size is checked when the message is
  composed.
- **Header injection** is not possible: a CR, LF or NUL in the subject, an
  address, a file name, a content id or an extra header is
  `error.BadRequest` (`invalid_header`). `Date`, `From`, `To`, `Cc`, `Bcc`,
  `Reply-To`, `Subject`, `Message-ID`, `MIME-Version` and `Content-*` cannot
  be given in `headers`; they are set from the message's fields.
- **Size**: a message over `Options.max_message_bytes` (25 MiB) or over the
  server's announced `SIZE` fails before anything is sent
  (`message_too_large`).
- The result is `Sent`: `message_id`, `accepted`, `rejected` (each with the
  server's code and words) and the server's `response` to the final ".",
  often its queue id.

### A message composed elsewhere

`sendRaw(req, .{ .from = ..., .to = ... }, bytes)` sends RFC 5322 bytes as
they are, dot-stuffed and with line ends made CRLF. nodemailer's
`MailComposer` and Python's `email` produce such bytes, so a binding can
send mail through Anole without giving up the library its users know.

## Connections

A pool per executor, opened when needed. `max_connections` (2 per executor
by default) is split between the executors; a send waits up to
`acquire_timeout` (5 s) for one, then fails `pool_timeout`. A connection
sends `max_messages_per_connection` (100) messages and says QUIT; idle ones
are closed after `idle_timeout` (30 s), because providers drop idle SMTP
sessions after 30 to 300 seconds. When the server offers PIPELINING, MAIL,
every RCPT and DATA go out in one write.

A connection taken idle that the server had closed meanwhile fails before
it accepted anything. That send goes to a new connection at once; it is not
a failure and not a retry. `app.mail.closeIdle()` closes the idle
connections now, for a process about to be frozen (a Lambda execution
environment): the next send opens a new one.

## Timeouts, retries and the breaker

`Options.timeout` (30 s) bounds a send, connecting included, plus the
message's size at `min_throughput` (1 MiB/s): a 10 MiB message gets 40 s.
`with(.{ .timeout = .fromSeconds(5) })` sets one for a call; `.max` lifts it.

Retries are **opt-in**: `app.mail.with(.{ .retry = true }).send(req, msg)`
tries a failure again (`Options.retry`: 3 attempts, 500 ms to 5 s) when the
server could not be reached, said "try later" (any 4xx, the answer to the
final "." included), or the attempt timed out. A connection lost **after**
the final "." is never retried, `.retry = true` or not: the server may have
kept the message, and a duplicate email is something a user sees. A job
that sends mail repeats the whole job after such a loss, which is the one
place a duplicate can come from.

A circuit breaker is on by default (`Options.breaker`): after repeated
connection failures sends fail at once with `circuit_open` until the server
answers again. Readiness is off by default (`Options.readiness`): a mail
outage hits every instance at once, and pulling them all out of the load
balancer would make it worse.

## Errors

A call fails with one of `anole.db.Error`; `anole.db.lastError(req)` has the
class, a code and the server's own words (never sent to a client).

| Cause | Error | Status | Class | Code |
| --- | --- | --- | --- | --- |
| Cannot connect, TLS fails, the connection is lost, 421, any 4xx | `ServiceUnavailable` | 503 | `unavailable` | `connect_failed`, `connect_timeout`, `connection_failed`, `connection_closed`, `service_unavailable`, `4.x.x` or the number, `starttls_unavailable`, `starttls_failed`, `auth_temporary` (a 4xx during AUTH), `recipients_deferred`, `pool_timeout`, `circuit_open`, `draining` |
| The send ran past its timeout | `GatewayTimeout` | 504 | `timeout` | `timeout` |
| The credentials refused (535, 534, 530) | `Database` | 500 | `other` | `authentication_failed` |
| No AUTH mechanism Anole speaks | `Database` | 500 | `other` | `auth_unsupported` |
| Credentials over a connection without TLS | `Database` | 500 | `other` | `insecure_auth` |
| Every recipient refused (5xx) | `BadRequest` | 400 | `invalid` | `recipient_rejected` |
| Some recipients refused | none: `Sent.rejected` | | | |
| A malformed address, header or file name | `BadRequest` | 400 | `invalid` | `invalid_address`, `invalid_header` |
| Message over the limit or the server's SIZE, or 552 (5.3.4) after DATA | `BadRequest` | 400 | `invalid` | `message_too_large` |
| More than 100 recipients in one message | `BadRequest` | 400 | `invalid` | `too_many_recipients` |
| The server needs SMTPUTF8 and does not offer it | `BadRequest` | 400 | `invalid` | `smtputf8_unsupported` |
| Another 5xx after DATA (554, say) | `Database` | 500 | `other` | the enhanced status ("5.7.1") or the number |
| An attachment file cannot be read | `Database` | 500 | `other` | `attachment_unreadable` |

`Options.errors` (an `anole.db.ErrorMap`) moves classes to other statuses.

## After the response

A password-reset mail does not need to hold up the response. Send it in a
background task with an `anole.db.Ctx` (docs/database.md), or, when it must
survive a restart, as a job (docs/jobs.md): the job context works like a
request, so `app.mail.send(job, msg)` is the whole call. `.retry = true`
suits it too: it repeats only failures before the final "." and "try later"
answers, so it never sends twice; a connection lost after the "." fails the
job, and the job's own retry is what may send a duplicate.

## There is no DKIM

Every relay above signs outgoing mail with your domain's key. Signing in the
app matters only for direct-to-MX delivery, which needs IP reputation,
reverse DNS and SPF work that an application server does not do well, and a
wrong signature hurts deliverability more than none. Anole does not offer it.

## Testing

`anole.smtp.testing.FakeServer` is an SMTP server in the test process:

```zig
var fake = try anole.smtp.testing.FakeServer.init(gpa, io, .{});
defer fake.deinit();
var url_buf: [96]u8 = undefined;
const mail = try anole.smtp.Client.init(gpa, io, .{ .url = fake.url(&url_buf), .from = "app@example.com" });
defer mail.deinit();

_ = try mail.send(&ctx, .{ .to = &.{"ada@example.com"}, .subject = "Hi", .text = "Hello" });
try std.testing.expectEqual(@as(usize, 1), fake.messageCount());
const sent = fake.message(0).?; // envelope_from, recipients, data
```

It can refuse recipients (`.reject_recipients`), offer STARTTLS, AUTH and
SIZE, answer the final "." with a code you queue
(`fake.queueFinalCodes(&.{451})`) and drop a connection. With
`-Dsmtp-test-url` and `-Dmailpit-api-url` the live tests send to a real
Mailpit and read the raw messages back from its API (`tests/smtp/run.sh`).

## The C ABI

`"mail"` in the configuration, `anole_smtp_send` and `anole_smtp_send_raw`
(docs/c-abi.md). Nothing waits on the caller's thread; the answer is an
`ANOLE_EV_SMTP_RESULT` event.

## What it leaves out

DKIM signing, CRAM-MD5 and XOAUTH2 (Microsoft 365 and Gmail OAuth need a
token provider; ask if you need one), and bounce handling (that is a mailbox
read, not SMTP).

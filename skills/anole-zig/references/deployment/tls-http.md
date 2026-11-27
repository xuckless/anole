# TLS, HTTP/2 and HTTP/3

Up: [deployment](index.md), [SKILL.md](../../SKILL.md). Related: [listeners-proxy.md](listeners-proxy.md), [lifecycle.md](lifecycle.md), [build flags](../config-cli.md#feature-flags-and-profiles).

Full docs: docs/server.md (listen and listenTls, TLS, HTTP/2, HTTP/3). Source: src/server.zig, src/http/core/tls_options.zig.

TLS is BoringSSL built into the binary. Do not put stunnel or a hand-rolled TLS loop in front just to get HTTPS, HTTP/2 or HTTP/3.

## listenTls and Cert

Use: `anole.App.listenTls(address, cert)` (src/server.zig); `anole.Cert` = `.fromFiles(cert, key)`, `.fromPem(cert, key)`, `.dev_self_signed` (src/http/core/tls_options.zig).

```zig
try app.listenTls(":443", .fromFiles("fullchain.pem", "privkey.pem"));
try app.listenTls("localhost:8443", .dev_self_signed);
```

Cleartext and TLS from one process: name both in the options and call `run`.

```zig
var app = try anole.App.init(init.gpa, .{
    .http = .{ .port = 8080 },
    .https = .{ .port = 8443, .cert = .dev_self_signed },
});
defer app.deinit();
app.get("/", hello);
try app.run();
```

Traps:
- `listen`/`listenTls` on a server whose options name `http` or `https` fail with `error.ListenersAlreadySet`.
- `.dev_self_signed` off loopback logs a warning: development only.
- Keys are PKCS#8 or SEC1 PEM without a passphrase. Relative paths are from the working directory.
- TLS 1.2 and 1.3 only, ECDHE + AEAD suites. No OCSP stapling or CRL checks.
- Needs `-Dtls=boringssl` (off in `minimal`). Guard optional listeners with `anole.features` ([flags](../config-cli.md#feature-flags-and-profiles)).

## Certificate reload

Use: `anole.App.reloadCertificates()`, `anole.App.setCertificate(cert)`; errors `anole.TlsLoadError` (src/server.zig, src/errors.zig).

SIGHUP calls `reloadCertificates` while `run` serves, so a renewal hook runs `kill -HUP <pid>`. All TLS listeners and HTTP/3 switch, or on any error none do. New connections get the new certificate; open ones keep theirs; session tickets still resume.

Traps:
- Call either from a task of the server's runtime (a handler, or a task from `app.io().concurrent`). One reload runs at a time.
- `setCertificate` changes the source later reloads read (new PEM from a secret store, other files).
- Changing `client_auth` CAs on reload makes earlier sessions never resume: every client re-verifies.

## Mutual TLS

Use: `anole.ClientAuth` (`.ca`, `.mode = .require | .request`), `anole.Ca` (`.fromFile`, `.fromPem`, `.system`, `.dir`), `anole.Request.peerCertificate()` (src/http/core/tls_options.zig, src/http/core/request.zig).

```zig
.https = .{
    .port = 8443,
    .cert = .fromPem(cert_pem, key_pem),
    .client_auth = .{
        .ca = .fromFile("clients-ca.pem"), // or .{ .dir = "cas" }, .system
        .mode = .require, // .request also accepts a client that sends none
    },
},
```

```zig
fn whoami(req: *anole.Request, res: *anole.Response) !void {
    const der = req.peerCertificate() orelse return res.print(.text, "anonymous", .{});
    const cert: std.crypto.Certificate = .{ .buffer = der, .index = 0 };
    const parsed = try cert.parse();
    try res.print(.text, "CN={s}", .{parsed.commonName()});
}
```

Traps:
- `peerCertificate()` is the verified leaf (DER), valid for the request, or null without `client_auth` or behind a TLS-terminating proxy.
- No revocation checking: use short-lived certificates or a CA you can drop and reload.

## HTTP/2

h2 by ALPN on TLS listeners; h2c (prior knowledge) beside HTTP/1.1 on cleartext ones by default. Settings: `ServerOptions.http2` (`max_concurrent_streams` 250, windows, rapid-reset limits, `enable_connect_protocol` off). Needs `-Dhttp2`.

Traps:
- `.http = .{ .h2c = false }` turns h2c off; a listener with `http1 = false` speaks h2c only. `Upgrade: h2c` is not supported.
- A client RST_STREAM cancels the handler: its next wait on `req.io` returns `error.Canceled` ([re-raise it](../runtime.md#re-raise-errorcanceled)); `res.peerGone()` checks without waiting.
- Chrome shares one connection per origin across tabs; past 250 open streams (EventSource, long polls) new streams queue silently. One EventSource per page.
- WebSockets over HTTP/2 (RFC 8441) are opt-in (`http2.enable_connect_protocol = true`).

## HTTP/3 and Alt-Svc

Use: `ServerOptions.http3` (`anole.ServerOptions.Http3`: `.address`, `.port`, `.alt_svc` true, `.max_streams_bidi`, `.idle_timeout`, `.handshake_timeout`, `.validate_address`, `.early_data`, `.prefer_v2`, `.sockets`, `.webtransport`, `.send_memory`), `ServerOptions.listen_tls_http3`, `Listener.http3`, `anole.App.http3Address()` (src/server.zig).

`listenTls` already serves HTTP/3 on the same port number over UDP when it is built in (`full` profile), advertised with `Alt-Svc: h3=":443"; ma=86400`. With `https` in the options, add `.http3 = .{}`; with `listeners`, `http3 = true` on one TLS listener.

Traps:
- Needs `-Dhttp3` (only in `full`) and a TLS listener. One HTTP/3 listener per server (`error.SeveralHttp3Listeners`).
- Open the UDP port in firewalls and container port maps; a browser that cannot reach it stays on HTTP/2.
- `behind_proxy` and `platform` deployments turn off HTTP/3 from `listenTls` (the proxy terminates TLS); `listen_tls_http3 = false` does it explicitly.
- `early_data` (0-RTT) is off by default; when on, only GET/HEAD/OPTIONS run early (`anole.early_data.isEarly`).
- Linux caps UDP buffers at `net.core.rmem_max`/`wmem_max`; raise them for bursty HTTP/3 loads (`anole_h3_socket_rcvbuf_bytes` shows what was granted).

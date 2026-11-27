# Deployment

Up: [SKILL.md](../../SKILL.md). Related: [config-cli.md](../config-cli.md) (environment, deployment modes, build flags, root declarations), [observability.md](../observability.md), [runtime.md](../runtime.md).

Full docs: docs/server.md, docs/net.md, docs/lambda.md, docs/getting-started.md (Deploy). Examples: examples/net, examples/lambda, examples/observe.

The server already owns TLS, HTTP/2 and HTTP/3, listeners, signals, the graceful drain, zero-downtime restarts and AWS Lambda. Configure them through `anole.ServerOptions`; do not add a signal handler, a reverse-proxy-in-process, or a Lambda runtime loop.

- [tls-http.md](tls-http.md): `listenTls`, `Cert`, `Ca`, `ClientAuth` (mTLS), certificate reload, HTTP/2 (ALPN, h2c), HTTP/3 and Alt-Svc.
- [listeners-proxy.md](listeners-proxy.md): `listen` addresses, `ServerOptions.listeners`, unix sockets, `anole.onlyOn`, proxies and the PROXY protocol, timeouts and limits.
- [lifecycle.md](lifecycle.md): `run`/`stop`/`waitReady`, startup errors, graceful drain, SIGUSR2 hand-off and systemd, release builds, Docker.
- [lambda.md](lambda.md): `deployment = lambda`, `zig build lambda`, non-HTTP events, `anole.lambda.context`.
- [net.md](net.md): raw TCP and UDP beside HTTP (`app.tcp`, `app.udp`, `anole.net`).

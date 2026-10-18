# Go WebTransport (webtransport-go) — ease-of-use notes

webtransport-go v0.10.0 on quic-go v0.59.0 (its `http3` package), Go 1.27.2. One file,
`main.go`, about 90 lines with comments; 2 direct dependencies.

| Feature | What it took | Dependencies |
|---|---|---|
| `/wt/echo` | `webtransport.Server{H3: &http3.Server{...}}` + `ConfigureHTTP3Server`, a `ServeMux` handler that calls `Upgrade`, then an `AcceptStream` loop (`io.Copy(str, str)` + `Close`) and a `ReceiveDatagram`/`SendDatagram` loop, about 30 lines | webtransport-go v0.10.0, quic-go v0.59.0 |
| `/plaintext` over h3 | One more `ServeMux` route: webtransport-go serves on quic-go's `http3.Server`, so ordinary requests and sessions share the endpoint | same |

## Why v0.10.0

webtransport-go v0.10.0 (2026-01-12) is the last release that speaks draft-02: its
README says "It currently implements draft-02", `protocol.go` has
`settingsEnableWebtransport = 0x2b603742` and `protocolHeader = "webtransport"`, and the
stream signals are 0x41/0x54 with the 0x2843 close capsule. v0.11.0 (2026-06-15) moved to
draft-15 (`webtransport-h3`, `SETTINGS_WT_ENABLED` 0x2c7cf000, WT_* flow-control
capsules) and its README says so; v0.12 and v0.13 follow. The quic-go it requires,
v0.59.0, builds unchanged with Go 1.27.2. The main `gohttp` server keeps quic-go v0.64.0,
so this is a separate module.

## Friction

- **Idle timeout.** quic-go's default is 30 s; `QUICConfig.MaxIdleTimeout = 120 s`.
- **Origin check.** `Upgrade` rejects a request whose `Origin` doesn't match its `Host`
  unless `CheckOrigin` is set; it is set to allow all (the load client sends none).
- **TLS config.** The `tls.Config` needs `http3.ConfigureTLSConfig` for the h3 ALPN.
- The server requires QUIC's RESET_STREAM_AT (`EnableStreamResetPartialDelivery`) on its
  own side and turns it on itself; draft-02 peers don't use it, and that is fine.

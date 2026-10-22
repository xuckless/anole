module github.com/xuckless/anole/bench/tools/vcload

go 1.27.2

require (
	github.com/coder/websocket v1.8.15
	github.com/quic-go/quic-go v0.59.0
	github.com/quic-go/webtransport-go v0.10.0
)

require (
	github.com/dunglas/httpsfv v1.1.0 // indirect
	github.com/quic-go/qpack v0.6.0 // indirect
	golang.org/x/crypto v0.41.0 // indirect
	golang.org/x/net v0.43.0 // indirect
	golang.org/x/sys v0.35.0 // indirect
	golang.org/x/text v0.28.0 // indirect
)

// draft-02 client SETTINGS fix; see ../wtload/third_party/webtransport-go/PATCH.txt.
replace github.com/quic-go/webtransport-go => ../wtload/third_party/webtransport-go

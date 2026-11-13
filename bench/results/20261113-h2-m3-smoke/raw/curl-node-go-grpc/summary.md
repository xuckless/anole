| scenario | conns | streams | req/s | PING/s | PING tot | SETT frames | ent/frame | RST/s | RST/100ms | RST unans. | empty DATA | empty HDR | empty CONT | unknown | CONT/blk | hdr blk B | WU/s | PRIO/s | PRIO tot | PRIO_UPD/s | PRIO_UPD tot |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| curl-load-tls | 1 | 96 | 96 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 38 | 193 | 0 | 0 | 0 | 0 |
| curl-load-h2c | 1 | 99 | 100 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 38 | 201 | 0 | 0 | 0 | 0 |
| curl-abort | 4 | 20 | 20 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 41 | 163 | 0 | 0 | 0 | 0 |
| curl-upload | 1 | 1 | 1 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 72 | 3 | 0 | 0 | 0 | 0 |
| curl-sse | 1 | 1 | 1 | 0 | 0 | 1 | 3 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 35 | 3 | 0 | 0 | 0 | 0 |
| curl-header-30k | 1 | 1 | 1 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 24067 | 3 | 0 | 0 | 0 | 0 |
| curl-header-200k | 1 | 0 | 0 | 0 | 0 | 1 | 3 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 0 |
| raw-continuation | 7 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 20 | 71705 | 0 | 0 | 0 | 0 | 0 |
| raw-priority | 2 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 14 | 0 | 5000 | 5000 | 5000 | 5000 |
| node-page | 1 | 100 | 100 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 23 | 0 | 0 | 0 | 0 | 0 |
| node-download | 1 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 24 | 4096 | 0 | 0 | 0 | 0 |
| node-cancel | 1 | 20 | 20 | 0 | 0 | 1 | 0 | 20 | 20 | 20 | 0 | 0 | 0 | 0 | 0 | 24 | 131 | 0 | 0 | 0 | 0 |
| node-upload | 1 | 1 | 1 | 0 | 0 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 22 | 0 | 0 | 0 | 0 | 0 |
| node-ping-tool-driven | 1 | 0 | 0 | 50 | 50 | 1 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| gohttp-tls | 100 | 93 | 122 | 0 | 0 | 1 | 4 | 20 | 20 | 20 | 0 | 0 | 0 | 0 | 0 | 41 | 771 | 0 | 0 | 0 | 0 |
| gohttp-h2c | 1 | 93 | 122 | 0 | 0 | 1 | 4 | 20 | 20 | 20 | 0 | 0 | 0 | 0 | 0 | 41 | 724 | 0 | 0 | 0 | 0 |
| grpc-go | 1 | 50 | 1020 | 22 | 22 | 1 | 0 | 20 | 20 | 20 | 0 | 0 | 0 | 0 | 0 | 94 | 22 | 0 | 0 | 0 | 0 |

| highest legitimate value (synthetic rows excluded) | value | scenario |
|---|---|---|
| PING/s | 22 | grpc-go |
| PING/100ms | 17 | grpc-go |
| SETTINGS frames per connection | 1 | node-upload |
| SETTINGS entries per frame | 4 | gohttp-tls |
| RST_STREAM/s | 20 | node-cancel |
| RST_STREAM/100ms | 20 | node-cancel |
| unanswered RST_STREAM/s | 20 | node-cancel |
| empty DATA total | 0 | node-upload |
| empty HEADERS total | 0 | node-upload |
| empty CONTINUATION total | 0 | node-upload |
| unknown frames total | 0 | node-upload |
| CONTINUATION per block | 1 | curl-header-30k |
| header block bytes | 24067 | curl-header-30k |
| WINDOW_UPDATE/s | 4096 | node-download |
| PRIORITY/s | 0 | node-upload |
| PRIORITY/100ms | 0 | node-upload |
| PRIORITY_UPDATE/s | 0 | node-upload |
| PRIORITY_UPDATE/100ms | 0 | node-upload |
| peak concurrent streams | 100 | node-page |
| requests/s | 1020 | grpc-go |

| scenario | server frame:code | count |
|---|---|---|
| raw-continuation | s2c_goaway:0xb | 3 |

GOAWAY debug data in raw-continuation: `too many CONTINUATION frames`

GOAWAY debug data in raw-continuation: `too many CONTINUATION frames`

GOAWAY debug data in raw-continuation: `header block too large`

| server SETTINGS entry (id=value) | frames |
|---|---|
| 0x0003=250 | 27 |
| 0x0004=65536 | 27 |
| 0x0006=65536 | 27 |
| 0x0009=1 | 27 |

| budget | limit | highest legitimate | headroom |
|---|---|---|---|
| empty DATA/HEADERS/CONT per second | 100 | 0 | no observation |
| SETTINGS entries per frame | 32 | 4 | 8.0x |
| CONTINUATION per block | 8 | 1 | 8.0x |
| peak concurrent streams | 250 | 100 | 2.5x |
| header block bytes | 65536 | 24067 | 2.7x |
| unanswered RST_STREAM in 1 s (bucket burst 1000; the 33/s refill is not observable here) | 1000 | 20 | 50.0x |
| PRIORITY/s (glitch rate 330/s) | exempt | 0 | not charged |
| PRIORITY_UPDATE/s (glitch rate 330/s) | exempt | 0 | not charged |

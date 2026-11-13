| scenario | conns | streams | req/s | PING/s | PING tot | SETT frames | ent/frame | RST/s | RST/100ms | RST unans. | empty DATA | empty HDR | empty CONT | unknown | CONT/blk | hdr blk B | WU/s | PRIO/s | PRIO tot | PRIO_UPD/s | PRIO_UPD tot |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| envoy-default | 28 | 8 | 9 | 0 | 0 | 1 | 5 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 97 | 2 | 0 | 0 | 0 | 0 |
| envoy-keepalive | 28 | 7 | 8 | 1 | 2 | 1 | 5 | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 97 | 2 | 0 | 0 | 0 | 0 |

| highest legitimate value (synthetic rows excluded) | value | scenario |
|---|---|---|
| PING/s | 1 | envoy-keepalive |
| PING/100ms | 1 | envoy-keepalive |
| SETTINGS frames per connection | 1 | envoy-keepalive |
| SETTINGS entries per frame | 5 | envoy-keepalive |
| RST_STREAM/s | 1 | envoy-keepalive |
| RST_STREAM/100ms | 1 | envoy-keepalive |
| unanswered RST_STREAM/s | 1 | envoy-keepalive |
| empty DATA total | 0 | envoy-keepalive |
| empty HEADERS total | 0 | envoy-keepalive |
| empty CONTINUATION total | 0 | envoy-keepalive |
| unknown frames total | 0 | envoy-keepalive |
| CONTINUATION per block | 0 | envoy-keepalive |
| header block bytes | 97 | envoy-keepalive |
| WINDOW_UPDATE/s | 2 | envoy-keepalive |
| PRIORITY/s | 0 | envoy-keepalive |
| PRIORITY/100ms | 0 | envoy-keepalive |
| PRIORITY_UPDATE/s | 0 | envoy-keepalive |
| PRIORITY_UPDATE/100ms | 0 | envoy-keepalive |
| peak concurrent streams | 8 | envoy-default |
| requests/s | 9 | envoy-default |

| scenario | server frame:code | count |
|---|---|---|

| server SETTINGS entry (id=value) | frames |
|---|---|
| 0x0003=250 | 56 |
| 0x0004=65536 | 56 |
| 0x0006=65536 | 56 |
| 0x0009=1 | 56 |

| budget | limit | highest legitimate | headroom |
|---|---|---|---|
| empty DATA/HEADERS/CONT per second | 100 | 0 | no observation |
| SETTINGS entries per frame | 32 | 5 | 6.4x |
| CONTINUATION per block | 8 | 0 | no observation |
| peak concurrent streams | 250 | 8 | 31.2x |
| header block bytes | 65536 | 97 | 675.6x |
| unanswered RST_STREAM in 1 s (bucket burst 1000; the 33/s refill is not observable here) | 1000 | 1 | 1000.0x |
| PRIORITY/s (glitch rate 330/s) | exempt | 0 | not charged |
| PRIORITY_UPDATE/s (glitch rate 330/s) | exempt | 0 | not charged |

| scenario | conns | streams | req/s | PING/s | PING tot | SETT frames | ent/frame | RST/s | RST/100ms | RST unans. | empty DATA | empty HDR | empty CONT | unknown | CONT/blk | hdr blk B | WU/s | PRIO/s | PRIO tot | PRIO_UPD/s | PRIO_UPD tot |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| firefox-load | 2 | 71 | 204 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 281 | 205 | 0 | 0 | 0 | 0 |
| firefox-reload | 2 | 52 | 1515 | 0 | 0 | 1 | 4 | 8 | 8 | 8 | 0 | 0 | 0 | 0 | 0 | 283 | 1515 | 0 | 0 | 0 | 0 |
| firefox-abort | 3 | 48 | 49 | 0 | 0 | 1 | 4 | 26 | 15 | 26 | 0 | 0 | 0 | 0 | 0 | 282 | 67 | 0 | 0 | 0 | 0 |
| firefox-sse | 2 | 4 | 5 | 0 | 0 | 1 | 4 | 3 | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 280 | 6 | 0 | 0 | 0 | 0 |
| firefox-upload | 1 | 1 | 4 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 283 | 5 | 0 | 0 | 0 | 0 |
| firefox-download | 1 | 1 | 4 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 284 | 222 | 0 | 0 | 0 | 0 |
| firefox-nav | 2 | 1 | 5 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 281 | 221 | 0 | 0 | 0 | 0 |

| highest legitimate value (synthetic rows excluded) | value | scenario |
|---|---|---|
| PING/s | 0 | firefox-upload |
| PING/100ms | 0 | firefox-upload |
| SETTINGS frames per connection | 1 | firefox-upload |
| SETTINGS entries per frame | 4 | firefox-upload |
| RST_STREAM/s | 26 | firefox-abort |
| RST_STREAM/100ms | 15 | firefox-abort |
| unanswered RST_STREAM/s | 26 | firefox-abort |
| empty DATA total | 0 | firefox-upload |
| empty HEADERS total | 0 | firefox-upload |
| empty CONTINUATION total | 0 | firefox-upload |
| unknown frames total | 0 | firefox-upload |
| CONTINUATION per block | 0 | firefox-upload |
| header block bytes | 284 | firefox-download |
| WINDOW_UPDATE/s | 1515 | firefox-reload |
| PRIORITY/s | 0 | firefox-upload |
| PRIORITY/100ms | 0 | firefox-upload |
| PRIORITY_UPDATE/s | 0 | firefox-upload |
| PRIORITY_UPDATE/100ms | 0 | firefox-upload |
| peak concurrent streams | 71 | firefox-load |
| requests/s | 1515 | firefox-reload |

| scenario | server frame:code | count |
|---|---|---|

| server SETTINGS entry (id=value) | frames |
|---|---|
| 0x0003=250 | 13 |
| 0x0004=65536 | 13 |
| 0x0006=65536 | 13 |
| 0x0009=1 | 13 |

| budget | limit | highest legitimate | headroom |
|---|---|---|---|
| empty DATA/HEADERS/CONT per second | 100 | 0 | no observation |
| SETTINGS entries per frame | 32 | 4 | 8.0x |
| CONTINUATION per block | 8 | 0 | no observation |
| peak concurrent streams | 250 | 71 | 3.5x |
| header block bytes | 65536 | 284 | 230.8x |
| unanswered RST_STREAM in 1 s (bucket burst 1000; the 33/s refill is not observable here) | 1000 | 26 | 38.5x |
| PRIORITY/s (glitch rate 330/s) | exempt | 0 | not charged |
| PRIORITY_UPDATE/s (glitch rate 330/s) | exempt | 0 | not charged |

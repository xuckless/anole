| scenario | conns | streams | req/s | PING/s | PING tot | SETT frames | ent/frame | RST/s | RST/100ms | RST unans. | empty DATA | empty HDR | empty CONT | unknown | CONT/blk | hdr blk B | WU/s | PRIO/s | PRIO tot | PRIO_UPD/s | PRIO_UPD tot |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| chromium-load | 3 | 93 | 202 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 457 | 1 | 134 | 134 | 0 | 0 |
| chromium-reload | 3 | 86 | 1515 | 0 | 0 | 1 | 4 | 80 | 80 | 80 | 0 | 0 | 0 | 0 | 0 | 460 | 1 | 657 | 1036 | 0 | 0 |
| chromium-abort | 3 | 49 | 50 | 0 | 0 | 1 | 4 | 48 | 34 | 48 | 0 | 0 | 0 | 0 | 0 | 444 | 2 | 0 | 0 | 0 | 0 |
| chromium-sse | 3 | 4 | 5 | 0 | 0 | 1 | 4 | 3 | 3 | 3 | 0 | 0 | 0 | 0 | 0 | 442 | 1 | 0 | 0 | 0 | 0 |
| chromium-upload | 2 | 1 | 4 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 445 | 1 | 0 | 0 | 0 | 0 |
| chromium-download | 2 | 2 | 4 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 446 | 30 | 0 | 0 | 0 | 0 |
| chromium-nav | 3 | 2 | 3 | 0 | 0 | 1 | 4 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 459 | 30 | 0 | 0 | 0 | 0 |

| highest legitimate value (synthetic rows excluded) | value | scenario |
|---|---|---|
| PING/s | 0 | chromium-upload |
| PING/100ms | 0 | chromium-upload |
| SETTINGS frames per connection | 1 | chromium-upload |
| SETTINGS entries per frame | 4 | chromium-upload |
| RST_STREAM/s | 80 | chromium-reload |
| RST_STREAM/100ms | 80 | chromium-reload |
| unanswered RST_STREAM/s | 80 | chromium-reload |
| empty DATA total | 0 | chromium-upload |
| empty HEADERS total | 0 | chromium-upload |
| empty CONTINUATION total | 0 | chromium-upload |
| unknown frames total | 0 | chromium-upload |
| CONTINUATION per block | 0 | chromium-upload |
| header block bytes | 460 | chromium-reload |
| WINDOW_UPDATE/s | 30 | chromium-nav |
| PRIORITY/s | 657 | chromium-reload |
| PRIORITY/100ms | 207 | chromium-reload |
| PRIORITY_UPDATE/s | 0 | chromium-upload |
| PRIORITY_UPDATE/100ms | 0 | chromium-upload |
| peak concurrent streams | 93 | chromium-load |
| requests/s | 1515 | chromium-reload |

| scenario | server frame:code | count |
|---|---|---|

| server SETTINGS entry (id=value) | frames |
|---|---|
| 0x0003=250 | 12 |
| 0x0004=65536 | 12 |
| 0x0006=65536 | 12 |
| 0x0009=1 | 12 |

| budget | limit | highest legitimate | headroom |
|---|---|---|---|
| empty DATA/HEADERS/CONT per second | 100 | 0 | no observation |
| SETTINGS entries per frame | 32 | 4 | 8.0x |
| CONTINUATION per block | 8 | 0 | no observation |
| peak concurrent streams | 250 | 93 | 2.7x |
| header block bytes | 65536 | 460 | 142.5x |
| unanswered RST_STREAM in 1 s (bucket burst 1000; the 33/s refill is not observable here) | 1000 | 80 | 12.5x |
| PRIORITY/s (glitch rate 330/s) | exempt | 657 | not charged |
| PRIORITY_UPDATE/s (glitch rate 330/s) | exempt | 0 | not charged |

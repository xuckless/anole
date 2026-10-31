| cell | backend | max req/s | ins:u/req | cyc:u/req | IPC:u | ins:k/req | pf/req | ctx-sw/req | kernel % of CPU | peak RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| h1-plain | epoll | 220,353 | 8,346 | 4,905 | 1.70 | 31,251 | 0.000 | 0.000 | 79 | 11.1 |
| h1-plain | uring | 241,207 | 8,209 | 4,293 | 1.91 | 31,103 | 0.000 | 0.000 | 81 | 10.6 |
| h1-json | epoll | 221,826 | 9,243 | 5,041 | 1.83 | 31,105 | 0.000 | 0.000 | 79 | 11.2 |
| h1-json | uring | 239,054 | 9,100 | 4,525 | 2.01 | 30,975 | 0.000 | 0.000 | 79 | 10.6 |
| h1-json-noconsole | epoll | 221,724 | 9,242 | 5,057 | 1.83 | 31,018 | 0.000 | 0.000 | 79 | 10.4 |
| h1-json-noconsole | uring | 238,703 | 9,102 | 4,514 | 2.02 | 31,160 | 0.000 | 0.000 | 80 | 9.7 |
| h1-jsoncomp-gzip | epoll | 25,103 | 741,742 | 189,037 | 3.92 | 32,314 | 0.004 | 0.000 | 11 | 19.1 |
| h1-jsoncomp-gzip | uring | 25,350 | 741,638 | 188,192 | 3.94 | 31,897 | 0.003 | 0.000 | 10 | 18.2 |
| h1-jsoncomp-br | epoll | 12,686 | 1,369,642 | 393,877 | 3.48 | 32,674 | 0.004 | 0.001 | 6 | 21.6 |
| h1-jsoncomp-br | uring | 12,662 | 1,369,774 | 394,991 | 3.47 | 32,300 | 0.004 | 0.001 | 5 | 20.4 |
| h1-jsoncomp-zstd | epoll | 23,066 | 524,378 | 202,765 | 2.59 | 32,475 | 0.030 | 0.001 | 13 | 80.1 |
| h1-jsoncomp-zstd | uring | 23,744 | 524,285 | 197,487 | 2.65 | 32,007 | 0.027 | 0.001 | 13 | 72.3 |
| tls-h1-json | epoll | 193,348 | 16,251 | 8,140 | 2.00 | 31,202 | 0.001 | 0.000 | 72 | 17.3 |
| tls-h1-json | uring | 208,542 | 16,055 | 7,858 | 2.04 | 30,772 | 0.001 | 0.000 | 72 | 16.6 |
| h2c-json-m10 | epoll | 543,309 | 16,867 | 5,995 | 2.81 | 3,243 | 0.002 | 0.000 | 33 | 38.7 |
| h2c-json-m10 | uring | 663,911 | 16,893 | 5,875 | 2.88 | 3,245 | 0.002 | 0.000 | 29 | 37.4 |
| h2c-json-m64 | epoll | 556,763 | 19,287 | 8,553 | 2.26 | 1,044 | 0.004 | 0.000 | 22 | 95.9 |
| h2c-json-m64 | uring | 578,025 | 19,413 | 8,262 | 2.35 | 1,033 | 0.003 | 0.000 | 20 | 93.4 |
| h2-static | epoll | 34,995 | 81,540 | 83,864 | 0.97 | 104,844 | 0.080 | 11.090 | 58 | 207.9 |
| h2-static | uring | 47,370 | 78,463 | 73,684 | 1.06 | 38,311 | 0.081 | 0.300 | 45 | 211.0 |
| h3-json | epoll | 347,382 | 30,174 | 12,030 | 2.51 | 4,970 | 0.006 | 0.000 | 23 | 37.3 |
| h3-json | uring | 361,211 | 29,570 | 11,452 | 2.58 | 5,015 | 0.003 | 0.000 | 26 | 43.4 |
| h3-static | epoll | 27,587 | 157,432 | 91,936 | 1.71 | 183,033 | 0.044 | 18.870 | 58 | 191.9 |
| h3-static | uring | 40,255 | 155,573 | 85,008 | 1.83 | 70,903 | 0.071 | 0.215 | 44 | 200.2 |
| h3-post | epoll | 40,191 | 230,381 | 93,402 | 2.47 | 53,028 | 0.011 | 0.001 | 33 | 46.6 |
| h3-post | uring | 39,960 | 231,496 | 93,519 | 2.48 | 53,853 | 0.010 | 0.001 | 32 | 45.8 |
| grpc-unary | epoll | 317,849 | 34,761 | 15,478 | 2.25 | 1,210 | 0.069 | 0.000 | 21 | 839.1 |
| grpc-unary | uring | 321,752 | 34,820 | 15,300 | 2.28 | 1,265 | 0.080 | 0.000 | 20 | 951.9 |
| sse-h1 | epoll |  |  |  |  |  |  |  | 0 | 93.4 |
| sse-h1 | uring |  |  |  |  |  |  |  | 0 | 83.4 |
| sse-h2c | epoll |  |  |  |  |  |  |  | 0 | 210.6 |
| sse-h2c | uring |  |  |  |  |  |  |  | 0 | 199.9 |
| net-tcp | epoll | 264,375 | 2,099 | 2,204 | 0.95 | 32,053 | 0.000 | 0.000 | 89 | 11.3 |
| net-tcp | uring | 244,165 | 1,664 | 1,333 | 1.25 | 30,967 | 0.000 | 0.000 | 93 | 11.0 |

## CPU by component (self time, % of the server's samples at the fixed load)

| cell | backend | kernel net | kernel netfilter | kernel io_uring | kernel file I/O | kernel sched/epoll | kernel syscall entry | kernel memory | kernel copy | kernel other | BoringSSL | nghttp2 | ngtcp2 | nghttp3 | compression | json | memcpy/memset | malloc (libc) | zig heap | zio runtime | anole http/net | h2 glue | h3/quic glue | tls glue | grpc | other user | unknown |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| h1-plain | epoll | 20.1 | 35.4 |  |  | 5.3 | 5.4 | 1.6 | 1.3 | 10.3 |  |  |  |  |  |  | 0.4 |  | 1.3 | 9.3 | 9.5 |  |  |  |  |  |  |
| h1-plain | uring | 19.9 | 37.3 | 1.8 |  | 5.3 | 2.9 | 2.0 | 1.5 | 10.1 |  |  |  |  |  |  | 0.4 |  | 1.3 | 7.6 | 10.0 |  |  |  |  |  |  |
| h1-json | epoll | 18.3 | 34.9 |  |  | 5.8 | 6.0 | 1.8 | 1.3 | 10.4 |  |  |  |  |  | 0.5 | 0.5 |  | 1.6 | 9.5 | 9.3 |  |  |  |  |  |  |
| h1-json | uring | 20.8 | 36.2 | 1.9 |  | 5.4 | 2.5 | 1.8 | 1.4 | 9.3 |  |  |  |  |  | 0.6 | 0.5 |  | 1.8 | 8.2 | 9.5 |  |  |  |  |  |  |
| h1-json-noconsole | epoll | 19.6 | 35.0 |  |  | 5.8 | 4.7 | 1.8 | 1.2 | 10.3 |  |  |  |  |  | 0.5 | 0.7 |  | 1.7 | 9.9 | 8.8 |  |  |  |  |  |  |
| h1-json-noconsole | uring | 19.5 | 36.6 | 1.7 |  | 5.9 | 3.0 | 1.7 | 1.6 | 9.8 |  |  |  |  |  | 0.5 | 0.6 |  | 1.7 | 8.2 | 9.3 |  |  |  |  |  |  |
| h1-jsoncomp-gzip | epoll | 2.4 | 4.5 |  |  | 1.1 | 0.8 | 0.4 | 0.1 | 1.6 |  |  |  |  | 50.2 | 22.7 | 9.1 | 0.1 | 0.8 | 1.6 | 4.3 |  |  |  |  |  | 0.3 |
| h1-jsoncomp-gzip | uring | 2.4 | 4.0 | 0.3 |  | 0.8 | 0.4 | 0.4 | 0.3 | 1.3 |  |  |  |  | 52.1 | 22.2 | 9.4 | 0.2 | 0.7 | 1.1 | 4.2 |  |  |  |  |  | 0.2 |
| h1-jsoncomp-br | epoll | 1.2 | 2.1 |  |  | 0.7 | 0.6 | 0.2 | 0.1 | 0.9 |  |  |  |  | 71.4 | 11.5 | 6.4 | 0.6 | 0.3 | 1.0 | 2.3 |  |  |  |  |  | 0.6 |
| h1-jsoncomp-br | uring | 1.2 | 2.2 | 0.2 |  | 0.4 | 0.3 | 0.1 | 0.1 | 0.9 |  |  |  |  | 71.0 | 11.9 | 7.0 | 0.6 | 0.5 | 0.7 | 2.3 |  |  |  |  |  | 0.6 |
| h1-jsoncomp-zstd | epoll | 2.8 | 4.8 |  |  | 1.3 | 1.0 | 0.6 | 0.3 | 1.8 |  |  |  |  | 27.9 | 22.0 | 27.3 | 0.3 | 1.3 | 2.7 | 5.2 |  |  |  |  |  | 0.7 |
| h1-jsoncomp-zstd | uring | 3.0 | 4.5 | 0.6 |  | 0.9 | 0.6 | 0.5 | 0.5 | 2.0 |  |  |  |  | 33.4 | 27.3 | 17.8 | 0.2 | 1.3 | 1.6 | 5.4 |  |  |  |  |  | 0.4 |
| tls-h1-json | epoll | 17.9 | 31.4 |  |  | 5.8 | 4.9 | 1.4 | 1.2 | 10.0 | 7.6 |  |  |  |  | 0.6 | 0.8 | 0.9 | 1.1 | 7.7 | 8.6 |  |  |  |  |  | 0.2 |
| tls-h1-json | uring | 18.2 | 33.9 | 2.6 |  | 4.2 | 1.9 | 1.3 | 1.4 | 8.9 | 8.3 |  |  |  |  | 0.5 | 1.0 | 0.8 | 1.1 | 6.5 | 9.4 |  |  |  |  |  | 0.1 |
| h2c-json-m10 | epoll | 7.1 | 13.8 |  |  | 2.7 | 3.5 | 0.7 | 0.5 | 4.5 |  | 18.0 |  |  | 0.4 | 1.0 | 3.0 | 2.9 | 10.8 | 8.2 | 4.8 | 14.3 |  |  |  |  | 3.8 |
| h2c-json-m10 | uring | 6.6 | 12.6 | 0.8 |  | 2.0 | 1.4 | 0.5 | 0.7 | 4.0 |  | 19.2 |  |  | 0.5 | 1.3 | 2.4 | 4.2 | 12.1 | 6.3 | 5.5 | 15.8 |  |  |  |  | 4.0 |
| h2c-json-m64 | epoll | 5.0 | 8.4 |  |  | 2.1 | 2.1 | 0.4 | 0.4 | 3.3 |  | 21.5 |  |  | 0.5 | 1.3 | 3.7 | 3.8 | 13.4 | 7.7 | 6.0 | 15.5 |  |  |  |  | 4.9 |
| h2c-json-m64 | uring | 4.3 | 8.4 | 0.8 |  | 1.8 | 0.9 | 0.4 | 0.5 | 2.9 |  | 22.0 |  |  | 0.6 | 1.2 | 2.7 | 3.4 | 14.4 | 5.6 | 7.0 | 17.4 |  |  |  |  | 5.7 |
| h2-static | epoll | 3.1 | 6.8 |  | 1.3 | 12.2 | 6.3 | 2.7 | 3.4 | 22.3 | 6.5 | 3.7 |  |  |  |  | 8.1 | 0.6 | 2.2 | 11.2 | 3.1 | 3.0 |  |  |  | 1.7 | 1.8 |
| h2-static | uring | 4.4 | 9.5 | 3.3 | 2.1 | 2.5 | 2.3 | 3.9 | 5.4 | 11.4 | 8.3 | 4.9 |  |  | 0.1 |  | 14.1 | 1.2 | 2.9 | 11.3 | 5.5 | 4.0 |  |  |  |  | 2.9 |
| h3-json | epoll | 3.9 | 10.5 |  |  | 2.3 | 0.5 | 0.1 | 1.2 | 5.0 | 2.2 |  | 13.0 | 20.5 |  | 1.0 | 3.1 | 3.3 | 7.0 | 1.1 | 3.7 |  | 14.9 |  |  |  | 6.8 |
| h3-json | uring | 4.8 | 10.9 | 0.8 |  | 1.9 | 0.8 |  | 1.3 | 5.4 | 2.0 |  | 12.5 | 21.2 |  | 1.2 | 2.5 | 2.8 | 6.6 | 2.3 | 3.5 |  | 15.0 |  |  |  | 4.5 |
| h3-static | epoll | 4.9 | 10.7 |  | 0.7 | 12.4 | 5.4 | 1.1 | 2.5 | 20.1 | 6.1 |  | 9.6 | 5.5 |  |  | 3.2 | 0.3 | 1.0 | 7.8 | 1.8 |  | 4.9 |  |  | 1.5 | 0.4 |
| h3-static | uring | 5.9 | 14.4 | 2.6 | 1.2 | 2.0 | 1.7 | 2.0 | 3.3 | 11.0 | 8.2 |  | 13.8 | 8.2 |  |  | 5.6 | 0.6 | 1.7 | 6.7 | 2.9 |  | 6.9 |  |  |  | 1.5 |
| h3-post | epoll | 5.7 | 13.5 |  |  | 1.9 | 0.8 | 1.6 | 4.1 | 5.8 | 13.2 |  | 19.6 | 7.9 | 0.1 |  | 8.2 | 0.4 | 0.7 | 3.6 | 0.8 |  | 11.6 |  |  |  | 0.7 |
| h3-post | uring | 5.9 | 13.0 | 0.3 |  | 1.6 | 0.5 | 1.5 | 4.1 | 5.4 | 12.7 |  | 21.1 | 8.6 |  |  | 8.0 | 0.4 | 0.8 | 3.2 | 0.8 |  | 11.5 |  |  |  | 0.6 |
| grpc-unary | epoll | 4.4 | 7.9 |  |  | 2.0 | 2.1 | 0.4 | 0.2 | 4.3 |  | 21.1 |  |  | 0.4 |  | 4.3 | 2.8 | 9.9 | 12.3 | 5.7 | 15.4 |  |  | 4.0 |  | 2.7 |
| grpc-unary | uring | 4.1 | 7.8 | 0.9 |  | 1.7 | 0.8 | 0.3 | 0.6 | 3.9 |  | 20.7 |  |  | 0.4 |  | 3.9 | 2.7 | 11.2 | 11.2 | 6.9 | 16.1 |  |  | 4.1 |  | 2.7 |
| sse-h1 | epoll |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| sse-h1 | uring |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| sse-h2c | epoll |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| sse-h2c | uring |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| net-tcp | epoll | 22.7 | 38.6 |  |  | 5.8 | 6.8 | 1.5 | 1.1 | 12.7 |  |  |  |  |  |  |  |  |  | 6.7 | 4.3 |  |  |  |  |  |  |
| net-tcp | uring | 23.8 | 42.9 | 0.7 |  | 5.8 | 4.4 | 1.5 | 1.7 | 11.9 |  |  |  |  |  |  |  |  |  | 4.0 | 3.3 |  |  |  |  |  |  |

## Top-5 self-time symbols

- **h1-plain / epoll:** `nft_do_chain_[k]` 13.2%; `server.Server(main.App).handleRequests` 3.6%; `nft_meta_store_ifname_[k]` 2.5%; `nft_meta_get_eval_[k]` 1.9%; `__nf_conntrack_find_get_[k]` 1.8%
- **h1-plain / uring:** `nft_do_chain_[k]` 13.7%; `server.Server(main.App).handleRequests` 3.9%; `nft_meta_store_ifname_[k]` 2.9%; `__raw_spin_lock_irqsave_[k]` 2.1%; `nft_meta_get_eval_[k]` 2.0%
- **h1-json / epoll:** `nft_do_chain_[k]` 13.9%; `server.Server(main.App).handleRequests` 3.4%; `nft_meta_store_ifname_[k]` 2.6%; `__raw_spin_lock_irqsave_[k]` 2.0%; `fdget_[k]` 1.9%
- **h1-json / uring:** `nft_do_chain_[k]` 12.8%; `server.Server(main.App).handleRequests` 3.3%; `nft_meta_store_ifname_[k]` 2.7%; `nft_meta_get_eval_[k]` 2.0%; `__raw_spin_lock_irqsave_[k]` 2.0%
- **h1-json-noconsole / epoll:** `nft_do_chain_[k]` 14.1%; `server.Server(main.App).handleRequests` 2.9%; `nft_meta_store_ifname_[k]` 2.4%; `__raw_spin_lock_irqsave_[k]` 2.2%; `nft_meta_get_eval_[k]` 2.0%
- **h1-json-noconsole / uring:** `nft_do_chain_[k]` 13.1%; `server.Server(main.App).handleRequests` 3.4%; `nft_meta_store_ifname_[k]` 2.7%; `__raw_spin_lock_irqsave_[k]` 2.3%; `nft_meta_get_eval_[k]` 2.1%
- **h1-jsoncomp-gzip / epoll:** `longest_match_avx2` 16.9%; `json.Stringify.encodeJsonString` 10.2%; `insert_string` 8.8%; `deflate_medium` 7.7%; `quick_insert_string` 6.5%
- **h1-jsoncomp-gzip / uring:** `longest_match_avx2` 17.9%; `json.Stringify.encodeJsonString` 9.4%; `insert_string` 8.9%; `deflate_medium` 8.2%; `quick_insert_string` 6.3%
- **h1-jsoncomp-br / epoll:** `CreateBackwardReferencesNH40` 48.3%; `BrotliCreateHuffmanTree` 5.5%; `json.Stringify.encodeJsonString` 4.8%; `compiler_rt.fastMemset` 3.6%; `BrotliStoreMetaBlock` 3.2%
- **h1-jsoncomp-br / uring:** `CreateBackwardReferencesNH40` 48.1%; `BrotliCreateHuffmanTree` 5.5%; `json.Stringify.encodeJsonString` 5.0%; `compiler_rt.fastMemset` 4.1%; `json.Stringify.valueStartAssumeTypeOk` 3.2%
- **h1-jsoncomp-zstd / epoll:** `compiler_rt.fastMemset` 20.9%; `ZSTD_compressBlock_doubleFast` 12.1%; `json.Stringify.encodeJsonString` 9.4%; `compiler_rt.memcpy.memcpyFast` 6.4%; `json.Stringify.valueStartAssumeTypeOk` 5.5%
- **h1-jsoncomp-zstd / uring:** `ZSTD_compressBlock_doubleFast` 14.4%; `compiler_rt.fastMemset` 11.5%; `json.Stringify.encodeJsonString` 11.1%; `json.Stringify.valueStartAssumeTypeOk` 6.9%; `compiler_rt.memcpy.memcpyFast` 6.3%
- **tls-h1-json / epoll:** `nft_do_chain_[k]` 11.6%; `nft_meta_store_ifname_[k]` 2.4%; `server.Server(main.App).handleRequests` 2.1%; `__raw_spin_lock_irqsave_[k]` 1.8%; `nft_meta_get_eval_[k]` 1.6%
- **tls-h1-json / uring:** `nft_do_chain_[k]` 11.3%; `nft_meta_store_ifname_[k]` 2.7%; `server.Server(main.App).handleRequests` 2.3%; `nft_meta_get_eval_[k]` 1.9%; `__raw_spin_lock_irqsave_[k]` 1.7%
- **h2c-json-m10 / epoll:** `heap.ArenaAllocator.alloc` 10.1%; `nft_do_chain_[k]` 5.8%; `?` 3.8%; `server.h2.Engine(main.App).onBeginHeaders` 3.2%; `server.h2.Engine(main.App).serveStream` 2.5%
- **h2c-json-m10 / uring:** `heap.ArenaAllocator.alloc` 11.4%; `nft_do_chain_[k]` 4.4%; `server.h2.Engine(main.App).onBeginHeaders` 4.3%; `?` 4.0%; `malloc` 3.5%
- **h2c-json-m64 / epoll:** `heap.ArenaAllocator.alloc` 12.6%; `?` 4.9%; `server.h2.Engine(main.App).onBeginHeaders` 4.1%; `nft_do_chain_[k]` 3.5%; `malloc` 3.0%
- **h2c-json-m64 / uring:** `heap.ArenaAllocator.alloc` 13.5%; `?` 5.7%; `server.h2.Engine(main.App).onBeginHeaders` 4.4%; `server.h2.Engine(main.App).serveStream` 3.5%; `nft_do_chain_[k]` 3.1%
- **h2-static / epoll:** `compiler_rt.memcpy.memcpyFast` 8.0%; `aes_gcm_enc_update_vaes_avx2` 4.6%; `nft_do_chain_[k]` 2.8%; `entry_SYSCALL_64_[k]` 2.4%; `heap.ArenaAllocator.alloc` 2.1%
- **h2-static / uring:** `compiler_rt.memcpy.memcpyFast` 13.9%; `aes_gcm_enc_update_vaes_avx2` 6.0%; `nft_do_chain_[k]` 4.1%; `_copy_to_iter_[k]` 3.3%; `?` 2.9%
- **h3-json / epoll:** `?` 6.8%; `heap.ArenaAllocator.alloc` 6.2%; `nft_do_chain_[k]` 3.8%; `compiler_rt.memcpy.memcpyFast` 2.6%; `malloc` 2.5%
- **h3-json / uring:** `heap.ArenaAllocator.alloc` 6.3%; `?` 4.5%; `nft_do_chain_[k]` 4.0%; `compiler_rt.memcpy.memcpyFast` 2.2%; `malloc` 2.0%
- **h3-static / epoll:** `nft_do_chain_[k]` 4.2%; `aes_gcm_enc_update_vaes_avx2` 2.8%; `compiler_rt.memcpy.memcpyFast` 2.5%; `entry_SYSCALL_64_[k]` 2.0%; `Thread.PosixThreadImpl.spawn__func_1513.Instance.entryFn` 1.5%
- **h3-static / uring:** `nft_do_chain_[k]` 5.7%; `compiler_rt.memcpy.memcpyFast` 4.5%; `aes_gcm_enc_update_vaes_avx2` 4.3%; `_copy_to_iter_[k]` 1.7%; `heap.ArenaAllocator.alloc` 1.5%
- **h3-post / epoll:** `compiler_rt.memcpy.memcpyFast` 6.6%; `nft_do_chain_[k]` 4.9%; `aes_gcm_enc_update_vaes_avx2` 4.2%; `aes_gcm_dec_update_vaes_avx2` 3.6%; `_copy_to_iter_[k]` 2.7%
- **h3-post / uring:** `compiler_rt.memcpy.memcpyFast` 6.6%; `nft_do_chain_[k]` 5.1%; `aes_gcm_dec_update_vaes_avx2` 3.8%; `aes_gcm_enc_update_vaes_avx2` 3.7%; `_copy_to_iter_[k]` 2.6%
- **grpc-unary / epoll:** `heap.ArenaAllocator.alloc` 9.1%; `compiler_rt.memcpy.memcpyFast` 3.6%; `nghttp2_hd_huff_decode` 3.4%; `nft_do_chain_[k]` 3.3%; `?` 2.7%
- **grpc-unary / uring:** `heap.ArenaAllocator.alloc` 10.6%; `compiler_rt.memcpy.memcpyFast` 3.4%; `sync.Futex.wake` 2.9%; `?` 2.7%; `nft_do_chain_[k]` 2.7%
- **net-tcp / epoll:** `nft_do_chain_[k]` 13.5%; `nft_meta_store_ifname_[k]` 3.4%; `__raw_spin_lock_irqsave_[k]` 2.3%; `nft_meta_get_eval_[k]` 2.0%; `__nf_conntrack_find_get_[k]` 1.8%
- **net-tcp / uring:** `nft_do_chain_[k]` 14.8%; `nft_meta_store_ifname_[k]` 4.1%; `sized_strscpy_[k]` 2.2%; `__raw_spin_lock_irqsave_[k]` 2.2%; `nft_meta_get_eval_[k]` 2.1%

## Memory: bytes allocated per request (low fixed load; sse: per subscriber), calls per request

≥: bpftrace's live-allocation map filled (4,096 keys), so the held figure is a lower bound; the allocated bytes are complete.

| cell | backend | malloc | calloc | realloc | arena | block | page | mmap | brk | taskpool | reqbufs | stackpool | malloc held at end (KB, blocks) |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| h1-plain | epoll | 2 B / 0.00 |  |  | 1,099 B / 2.08 |  |  |  |  / 0.00 |  |  / 1.01 |  | 176, 11 |
| h1-plain | uring |  |  |  | 1,103 B / 2.09 |  |  |  |  / 0.00 |  |  / 1.02 |  | 0, 0 |
| h1-json | epoll |  |  |  | 1,686 B / 3.16 |  |  |  |  / 0.00 |  |  / 1.02 |  | 0, 0 |
| h1-json | uring |  |  |  | 1,665 B / 3.12 |  |  |  |  / 0.00 |  |  / 1.01 |  | 0, 0 |
| h1-json-noconsole | epoll | 0 B / 0.00 |  |  | 1,666 B / 3.12 |  |  |  |  / 0.00 |  |  / 1.01 |  | 32, 2 |
| h1-json-noconsole | uring |  |  |  | 1,674 B / 3.14 |  |  |  |  / 0.00 |  |  / 1.01 |  | 0, 0 |
| h1-jsoncomp-gzip | epoll | 36,171 B / 3.24 |  |  | 26,008 B / 14.84 | 296,209 B / 1.04 |  |  |  |  |  / 1.02 |  | 0, 0 |
| h1-jsoncomp-gzip | uring | 36,171 B / 3.24 |  |  | 26,008 B / 14.84 | 296,209 B / 1.04 |  |  |  |  |  / 1.02 |  | 0, 0 |
| h1-jsoncomp-br | epoll | 108,902 B / 26.40 |  |  | 25,763 B / 14.70 |  |  |  |  |  |  / 1.00 |  | 4,107, 454 |
| h1-jsoncomp-br | uring | 108,902 B / 26.40 |  |  | 25,763 B / 14.70 |  |  |  |  |  |  / 1.01 |  | 1,822, 228 |
| h1-jsoncomp-zstd | epoll | 516,037 B / 3.24 |  |  | 324,030 B / 18.02 |  |  |  |  |  |  / 1.02 |  | 0, 0 |
| h1-jsoncomp-zstd | uring | 516,037 B / 3.24 |  |  | 320,209 B / 17.81 |  |  |  |  |  |  / 1.02 |  | 18,783, 129 |
| tls-h1-json | epoll | 1,218 B / 2.23 |  |  | 1,678 B / 3.15 |  |  |  |  / 0.00 |  |  / 1.02 |  | 2,675, 166 |
| tls-h1-json | uring | 5,234 B / 2.44 |  |  | 1,666 B / 3.12 |  |  |  |  / 0.00 |  |  / 1.01 |  | 1,017, 64 |
| h2c-json-m10 | epoll | 832 B / 5.62 |  |  | 2,758 B / 16.10 |  |  |  |  |  |  |  | ≥ 332, 4096 |
| h2c-json-m10 | uring | 827 B / 5.59 |  |  | 2,756 B / 16.09 |  |  |  |  |  |  |  | ≥ 481, 4096 |
| h2c-json-m64 | epoll | 817 B / 5.52 |  |  | 2,727 B / 15.92 |  |  |  |  |  |  |  | ≥ 300, 4096 |
| h2c-json-m64 | uring | 817 B / 5.52 |  |  | 2,724 B / 15.90 |  |  |  |  |  |  |  | ≥ 321, 4096 |
| h2-static | epoll | 29,520 B / 11.79 |  |  | 53,935 B / 25.24 |  |  |  |  |  / 1.02 |  |  / 0.17 | 944, 1390 |
| h2-static | uring | 27,592 B / 11.69 |  |  | 54,248 B / 25.39 |  |  |  |  / 0.00 |  / 1.02 |  |  / 0.03 | 959, 1630 |
| h3-json | epoll | 7,613 B / 7.07 |  |  | 7,028 B / 16.91 |  |  |  |  |  |  |  | 1,834, 876 |
| h3-json | uring | 14,657 B / 8.46 | 2 B / 0.00 | 0 B / 0.00 | 6,375 B / 15.34 |  |  |  |  / 0.00 |  |  |  | ≥ 9,699, 4096 |
| h3-static | epoll | 1,429 B / 8.30 |  |  | 7,137 B / 31.36 |  |  |  |  |  / 1.02 |  |  / 0.01 | 44, 116 |
| h3-static | uring | 1,602 B / 8.54 |  | 0 B / 0.00 | 7,099 B / 31.19 |  |  |  |  |  / 1.02 |  |  / 0.04 | 804, 379 |
| h3-post | epoll | 1,216 B / 7.58 | 0 B / 0.00 | 0 B / 0.00 | 6,413 B / 16.76 |  |  |  |  |  / 1.02 |  |  | 47, 146 |
| h3-post | uring | 1,224 B / 7.55 | 0 B / 0.00 | 0 B / 0.00 | 6,395 B / 16.71 |  |  |  |  |  / 1.02 |  |  | 69, 212 |
| grpc-unary | epoll | 48,642 B / 8.40 | 3 B / 0.00 | 5 B / 0.01 | 64,512 B / 20.45 |  |  |  |  |  |  |  | ≥ 236,056, 4096 |
| grpc-unary | uring | 47,787 B / 8.16 | 2 B / 0.00 | 5 B / 0.01 | 62,981 B / 19.97 |  |  |  |  |  |  |  | ≥ 209,580, 4096 |
| sse-h1 | epoll | 11,784 B / 6.68 |  | 33 B / 0.00 | 2,015 B / 3.81 |  |  | 1,609,242 B / 0.06 |  / 0.08 |  / 2.02 |  / 1.00 |  / 1.98 | ≥ 3,667, 3634 |
| sse-h1 | uring | 13,607 B / 6.75 |  | 37 B / 0.01 | 2,278 B / 4.04 |  |  | 1,648,520 B / 0.08 |  / 0.09 |  / 2.02 |  / 1.00 |  / 1.98 | ≥ 4,090, 3592 |
| sse-h2c | epoll | 47,050 B / 44.19 | 5,688 B / 4.00 | 16,452 B / 2.00 | 6,284 B / 18.48 |  |  | 2,641,227 B / 0.15 |  / 0.36 |  / 4.02 |  / 1.00 |  / 2.99 | ≥ 7,944, 4096 |
| sse-h2c | uring | 47,295 B / 44.12 | 5,688 B / 4.00 | 16,452 B / 2.00 | 6,318 B / 18.57 |  |  | 2,725,935 B / 0.15 |  / 0.36 |  / 4.02 |  / 1.00 |  / 2.97 | ≥ 7,692, 4096 |
| net-tcp | epoll |  |  |  |  |  |  |  |  |  |  |  | 0, 0 |
| net-tcp | uring |  |  |  |  |  |  |  |  |  |  |  | 0, 0 |

## Off-CPU (top stacks by time, all threads)

- **h1-plain / epoll** (13,150 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 69%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 31%; anole-bench: ev.backends.linux.epoll.checkCompletion;os.net.send -> finish_task_switch.isra.0 0%
- **h1-plain / uring** (18,177 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 50%; iou-wrk-1685937: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 28%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 22%
- **h1-json / epoll** (12,966 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 70%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 30%; anole-bench: ev.backends.linux.epoll.checkCompletion;os.net.send -> finish_task_switch.isra.0 0%
- **h1-json / uring** (18,227 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 49%; iou-wrk-1691452: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 28%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 22%
- **h1-json-noconsole / epoll** (4,214 ms): anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 100%; anole-bench: ev.backends.linux.epoll.checkCompletion;os.net.send -> finish_task_switch.isra.0 0%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h1-json-noconsole / uring** (9,089 ms): iou-wrk-1696966: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 56%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 44%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h1-jsoncomp-gzip / epoll** (12,814 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 70%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 30%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h1-jsoncomp-gzip / uring** (12,944 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 70%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 30%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h1-jsoncomp-br / epoll** (12,698 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 71%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 29%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h1-jsoncomp-br / uring** (17,902 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 50%; iou-wrk-1708628: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 29%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 21%
- **h1-jsoncomp-zstd / epoll** (13,369 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 67%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 33%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h1-jsoncomp-zstd / uring** (19,306 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 47%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 27%; iou-wrk-1714680: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 27%
- **tls-h1-json / epoll** (13,226 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 68%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 32%; anole-bench: ev.backends.linux.epoll.checkCompletion;os.net.send -> finish_task_switch.isra.0 0%
- **tls-h1-json / uring** (18,227 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 49%; iou-wrk-1720281: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 28%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 22%
- **h2c-json-m10 / epoll** (11,649 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 77%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 23%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h2c-json-m10 / uring** (17,808 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 51%; iou-wrk-1725647: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 29%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 21%
- **h2c-json-m64 / epoll** (13,772 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 65%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 35%; anole-bench: ev.backends.linux.epoll.checkCompletion;os.net.send -> finish_task_switch.isra.0 0%
- **h2c-json-m64 / uring** (19,174 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 47%; iou-wrk-1731043: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 27%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 26%
- **h2-static / epoll** (32,150 ms): anole-bench: [unknown];Thread.PosixThreadImpl.spawn__func_1513.Instance.entryFn -> __x64_sys_futex 55%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 28%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 13%
- **h2-static / uring** (24,546 ms): iou-wrk-1736557: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 40%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 37%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 23%
- **h3-json / epoll** (12,940 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 70%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 30%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h3-json / uring** (18,135 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 50%; iou-wrk-1741903: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 28%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 22%
- **h3-static / epoll** (29,156 ms): anole-bench: [unknown];Thread.PosixThreadImpl.spawn__func_1513.Instance.entryFn -> __x64_sys_futex 59%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 31%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 5%
- **h3-static / uring** (22,921 ms): iou-wrk-1747208: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 43%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 39%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 18%
- **h3-post / epoll** (12,769 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 71%; anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 29%; anole-bench: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **h3-post / uring** (17,875 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 50%; iou-wrk-1752518: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 29%; anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 21%
- **grpc-unary / epoll** (12,977 ms): grpc-interop-se: [unknown];[unknown] -> __x64_sys_poll 69%; grpc-interop-se: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 31%; grpc-interop-se: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 0%
- **grpc-unary / uring** (18,694 ms): grpc-interop-se: [unknown];[unknown] -> __x64_sys_poll 48%; iou-wrk-1757966: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 27%; grpc-interop-se: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 24%
- **sse-h1 / epoll** (8,016 ms): anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 50%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 50%
- **sse-h1 / uring** (8,026 ms): anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 50%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 50%
- **sse-h2c / epoll** (8,842 ms): anole-bench: ev.loop.Loop.poll;ev.backends.linux.epoll.poll -> __x64_sys_epoll_pwait2 55%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 45%
- **sse-h2c / uring** (8,875 ms): anole-bench: runtime.Executor.run;ev.loop.Loop.poll -> finish_task_switch.isra.0 55%; anole-bench: [unknown];[unknown] -> __x64_sys_poll 45%
- **net-tcp / epoll** (9,010 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 100%; anole-bench: group.Group.spawnInto__func_4679.Wrapper.start;[unknown] -> finish_task_switch.isra.0 0%; anole-bench: ev.backends.linux.epoll.checkCompletion;os.net.recv -> finish_task_switch.isra.0 0%
- **net-tcp / uring** (14,130 ms): anole-bench: [unknown];[unknown] -> __x64_sys_poll 64%; iou-wrk-1771323: __schedule;finish_task_switch.isra.0 -> finish_task_switch.isra.0 36%; anole-bench: group.Group.spawnInto__func_4679.Wrapper.start;[unknown] -> finish_task_switch.isra.0 0%

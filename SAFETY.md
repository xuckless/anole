# Memory, concurrency and unsafe-code rules

Anole is written in Zig, which doesn't check lifetimes, data races or lock order at compile time. These rules give us those guarantees by convention, and debug-build checks and a lint make the conventions stick. They apply to all new code from 2026-10-23. Existing code is brought in line by the retrofit audit before the 0.5.x performance pass.

Each rule has an ID. Cite it in reviews and in `// SAFETY:` comments.

## Background

All the lifetime bugs found in the 0.4.0 test round had the same shape: a task, callback or timer outlived the object it pointed at.

| Bug | What outlived what |
|---|---|
| Raw TCP driver | Its helper tasks ran on a freed connection |
| HTTP/2 and HTTP/3 detached replies | A parked response was released twice |
| S3 upload | Its part tasks used memory the upload had already freed |
| Kafka | A batch was released twice after an out-of-memory error |
| Rooms (earlier, H-6) | Members were held by raw pointers |

Each subsystem had its own lifetime scheme. They were five dialects of the same idea, each with its own edge cases. These rules replace them with one mechanism per lifetime class.

## The concurrency model these rules assume

- **Runtime:** zio, stackful coroutines, one pinned executor (one thread) per core, cooperative scheduling.
- **Placement:** a connection is accepted on one executor and never leaves it. Every task spawned for it is placed `.local` on the same executor.
- **Where code crosses executors or threads:**
  - the C ABI consumer threads (Node, Python), through per-executor rings and done lists;
  - the blocking pool;
  - the SQLite writer threads;
  - the console thread;
  - topic fan-out across executors;
  - the C libraries' sessions (nghttp2, ngtcp2/nghttp3, BoringSSL), shared by several tasks.

## 1. Memory: every object has exactly one owner

**M1. A single, named owner.** Every heap object has exactly one owner, named in its type's doc comment (`/// owner: Connection`). A transfer of ownership is explicit in the function name (`take…`, `give…`, `into…`). Shared ownership is the exception, and it is allowed only through M2's fourth class.

**M2. Four lifetime classes, one mechanism each.**

| Class | Examples | Mechanism |
|---|---|---|
| Process-wide | server, config, pools, SSL_CTX | Freed only after every executor has stopped and been joined |
| One request or batch | headers, bodies, rows, encode buffers | The request's or batch's arena, freed in one go at the end |
| Child of an owner | stream tasks of a connection, part tasks of an upload, connections of a driver | Structured concurrency (T1): the owner holds a task group and joins it before freeing itself |
| Shared, or detached from its owner | C ABI requests, parked responses, topic subscribers across executors | Generation-checked handles in a per-executor table (as the C ABI already does). A stale handle gives `error.Gone`, never a freed pointer. |

Every object belongs to exactly one class, and the class is named in its doc comment next to the owner.

**M3. No pointer across a suspension point** (the most important rule). A pointer may be held across an await, I/O call, yield, lock wait or anything else that can suspend the task only if what it points to is one of:
- owned by the current task;
- owned by an ancestor that is guaranteed to outlive the task (by T1);
- process-wide (M2);
- reached again through a handle after the suspension.

Anything else is re-fetched through its handle after the task resumes. This is Rust's "borrow across await" check done by hand, and every bug in the table above broke it.

**M4. Arena memory never escapes its arena.** Nothing that outlives the request or batch keeps a slice of its arena. Copy it into memory owned by the longer-lived object.

**M5. Teardown runs exactly once.** Objects with a teardown carry a state field (`alive → closing → dead`). `deinit` asserts `closing` and sets `dead`. A second teardown, or any use after `dead`, panics in debug builds. No `deinit` may be reachable from two paths without going through that state.

**M6. Pools hand out fresh objects.** A pooled object is reset completely when it is returned. In debug builds, returned memory is poisoned. A pooled object that others refer to (a connection, a stream) gets a generation number, and those references go through handles.

## 2. Tasks and coroutines: structured, never fire-and-forget

**T1. Every task belongs to a group with an owner.** Every spawn goes into a task group owned by an object, through `placement.concurrent` with a group argument. The owner's teardown order is fixed:
1. cancel the group;
2. join the group;
3. free the owner.

A spawn outside a group is banned, and so are fire-and-forget tasks. Work that must outlive its owner becomes a handle-referenced object (M2, fourth class), owned by a per-executor table with its own group.

**T2. Children never free upward or sideways.** A child task never frees its parent or a sibling. Results flow up as a return value, through a queue the parent reads, or by a handle the parent resolves.

**T3. One executor per object.** Every object with mutable state belongs to one executor. Debug builds assert it (`assertOwnerExecutor`). Other executors and threads reach it only by sending a message (a ring or queue) or through a handle, never by writing through a shared pointer.

**T4. Detached work goes through handles.** Parked connections, C ABI requests, detached HTTP/2 and HTTP/3 replies, timers and sweepers refer to their target only by handle. They resolve the handle each time they run.

## 3. Cancellation

**C1. Cancelling is a request, not a free.** Cancelling a task or group only asks it to stop. Ownership ends at the join, never earlier. Nothing is ever cancelled by freeing it.

**C2. Uninterruptible sections are explicit.** Code that must finish once started (teardown, flushing a final frame, bookkeeping) runs in an explicit uncancelable section.

**C3. Re-arm a caught cancel.** Code that catches `error.Canceled` from an Io call calls `io.recancel()` (net.Udp.send once swallowed it and hung shutdown).

## 4. Locks: avoid them

**L1. No lock when the state stays on one executor.** Coroutines on one executor never run at the same time, so state that stays on its executor (T3) needs no lock. A lock is allowed only for state that really is shared across threads: the C library sessions, the TLS state, the C ABI rings and done lists, the process-wide tables.

**L2. Never hold a lock across a suspension point.** Debug builds check this: a task that suspends while holding a lock panics.

**L3. Never call out while holding a lock.** That means no user handlers, no callbacks into other subsystems, no logging that may wait, and nothing that may allocate and wait. C library callbacks that run under a lock (nghttp2's under its session mutex, until the takeover) may only record and return.

**L4. One lock at a time, or a fixed order.** Code normally holds at most one lock. Where two are needed, they are taken in the documented global order below, which debug builds assert. That rules out deadlocks by construction.

Lock order (outer first), to be filled in by the retrofit audit:
1. process-wide tables (handle tables, topic registries)
2. per-connection protocol locks (HTTP/2 session, HTTP/3 connection)
3. per-connection TLS spin lock

**L5. Spin locks only for short, bounded sections.** A spin lock may guard only a short, fixed-length section that never allocates, waits or calls C code that may block.

**L6. Atomics through a few wrappers.** Atomics are used only through a few wrappers: counters, flags, generations, the SPSC ring. The existing lock-free structures (the C ABI rings, the HTTP/3 kick list) get dedicated multi-thread stress tests. No new lock-free structures without the user's approval.

## 5. Unsafe code and C

**U1. One wrapper module per C library.** C is called only from one wrapper module per library. The rest of Anole sees Zig types. Every C pointer's ownership (who frees it, and when) is written at the wrapper.

**U2. C callbacks only record.** C callbacks never wait, spawn tasks, take a second lock, or free the object whose callback is running. They record what happened and return. The owner acts on it after the C call returns.

**U3. Unsafe operations need a reason.** Pointer casts (`@ptrCast`, `@alignCast`, `@ptrFromInt`, `@intFromPtr`) and reads of uninitialized (`undefined`) memory are allowed only:
- in wrapper modules, or
- on a line commented `// SAFETY: <why this is valid>`.

The lint enforces this against an allowlist.

**U4. Everything is bounded.** Every queue, buffer and table has a cap, and reaching the cap gives an error or a back-pressure signal, never an unbounded wait inside a send.

## 6. Enforcement

**E1. Debug-build checks** (Debug and test builds only, no cost in ReleaseFast):
- executor ownership (T3);
- a lock held across a suspension point (L2), which needs a held-lock counter per task (a small zio hook, offered upstream);
- lock order (L4);
- the teardown state (M5);
- poisoned freed memory in tests: an allocator that poisons and never reuses freed memory, so a use-after-free crashes at once instead of only under CI load;
- the leak check (`std.testing.allocator`), as today.

**E2. Lint** (a CI step and `zig build lint`), a grep against an allowlist for:
- a spawn outside a task group (T1);
- an unsafe operation outside a wrapper module without a `// SAFETY:` comment (U3);
- C calls outside wrapper modules (U1);
- `error.Canceled` caught without `recancel` (C3).

**E3. Review.** Every change that adds a task, a lock, a shared object or a C call states which rules apply and how they hold. The checklist is the rule IDs in this file.

**Parked:** Valgrind or ASan runs of the Zig test binaries (user, 2026-10-23), and ThreadSanitizer (likely confused by zio's stack switching). Revisit after the retrofit.

## 7. Decisions (user, 2026-10-23)

- **Enforcement:** debug-build checks and lint. Valgrind is parked.
- **Timing:** the rules apply to new code now, including the 0.4.0 fixes. The retrofit audit comes after S1 and before S2, so the HTTP/2 takeover is designed under them.
- **New HTTP/2 engine:** single owner. One task owns the protocol state; stream tasks and the writer talk to it by message; there is no session mutex.
- **Fire-and-forget tasks:** banned. Detached work goes through handles.

## 8. Retrofit order

Ordered by bug history:
1. S3 uploads.
2. The raw TCP/UDP drivers.
3. HTTP/2 and HTTP/3 detached replies and parks.
4. The Kafka producer.
5. Rooms and topics (WebSocket, SSE, WebTransport).
6. The C ABI (rings, done lists, sweepers).
7. Jobs and webhooks.
8. The database pools.
9. Everything else.

Each step:
- maps its objects to M2's classes;
- replaces its own counters and flags with the shared mechanisms;
- adds the debug checks;
- adds a regression test for each bug class it closes.

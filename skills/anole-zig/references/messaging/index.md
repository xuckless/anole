# Messaging, jobs and webhooks

Brokers, background work, schedules and webhooks are built in; never hand-roll a NATS or Kafka protocol client, a job table with a polling loop, a cron parser, an HMAC webhook signer or a retry loop around deliveries.

Up: [SKILL.md](../../SKILL.md). Full docs: docs/messaging.md, docs/jobs.md, docs/cron.md, docs/webhooks.md. Examples: templates/full/src/main.zig (jobs and cron), src/webhooks/webhooks_test.zig, src/nats/anole_test.zig.

| Need | Use | File |
| --- | --- | --- |
| Publish, request/reply, subject handlers, queue groups, JetStream | `app.nats`, `anole.nats.Client` | [nats.md](nats.md) |
| Produce to topics, consume with consumer groups, dead-letter topic | `app.kafka`, `anole.kafka.Client` | [kafka.md](kafka.md) |
| Work outside the request: retried, delayed, unique, durable | `app.jobs`, `anole.jobs.Client` | [jobs.md](jobs.md) |
| Run something on a schedule, once per tick across instances | `jobs.cron`, `anole.cron.Schedule` | [cron.md](cron.md) |
| Send signed webhooks to customers; verify incoming ones (Stripe, GitHub, Slack) | `app.webhooks`, `app.webhookVerify` | [webhooks.md](webhooks.md) |

Every connector here has the database connectors' shape: a handle in App state, calls take the request (or a `*Msg` / `*Job` context) first, errors are `anole.db.Error` so a handler's `try` gives the right status, and `anole.db.lastError(c)` has the detail. See [databases](../databases/index.md).

Build flags: `-Dnats`, `-Dkafka` (needs `-Dcompression`), `-Djobs` (also gives `anole.cron`), `-Dwebhooks` (needs `-Djobs`). Which profile turns which on: [config-cli](../config-cli.md#feature-flags-and-profiles). With a flag off, `anole.<name>` is an empty struct and `app.<name>` is a compile error naming the flag (src/root.zig, src/server.zig).

Shared runtime rules: [never block an executor](../runtime.md#never-block-an-executor), [re-raise error.Canceled](../runtime.md#re-raise-errorcanceled), [writes return once buffered](../runtime.md#writes-return-once-buffered), [request arena and lifetimes](../runtime.md#request-arena-and-lifetimes).

Related areas: [storage, email and clients](../storage-email-clients/index.md) (S3, SMTP, outbound HTTP, resilience), [observability](../observability.md) (`anole_jobs_*`, `anole_kafka_*` metrics, messaging spans), [testing](../testing.md), [deployment](../deployment/index.md) (stop timeouts for the jobs drain).

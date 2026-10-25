# Object storage (S3)

`anole.s3` (`-Ds3`, on in the `web` and `full` profiles) is a client for S3-compatible object stores: AWS S3, Cloudflare R2, MinIO, Backblaze B2 and Supabase Storage. It is pure Zig on Anole's HTTP client (per-executor pools, BoringSSL, deadlines), with its own SigV4 signer. I built it rather than adopting a library: the candidates are on `std.http` (which hard-codes std's TLS), carry no presigning, or pull in a C++ SDK with its own event loop.

The shape is the one the database connectors have: a handle in your App state, every call takes the request first, errors are `anole.db.Error` (a handler's `try` gives the right status), `Options.errors` moves classes to other statuses, `anole.db.lastError(req)` has the detail.

```zig
const files = try app.s3(.{});    // AWS_* variables, S3_BUCKET

fn upload(state: *State, req: *anole.Request, res: *anole.Response) !void {
    const stored = try state.files.put(req, "avatars/1.png", .request, .{}); // the request body goes to S3
    res.status = .created;
    try res.json(.{ .etag = stored.etag });
}

fn avatar(state: *State, req: *anole.Request, res: *anole.Response) !void {
    _ = try state.files.serve(req, res, "avatars/1.png", .{}); // Range, ETag and 304 included
}
```

## Setup

`app.s3(.{})` reads what the AWS SDKs read, so every provider's setup page works unchanged:

| Variable | Used for |
| --- | --- |
| `AWS_ENDPOINT_URL_S3`, `AWS_ENDPOINT_URL` | the endpoint (none: AWS) |
| `AWS_REGION`, `AWS_DEFAULT_REGION` | the region (R2 uses `auto`, otherwise `us-east-1`) |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | keys |
| `AWS_PROFILE`, `AWS_SHARED_CREDENTIALS_FILE` | a profile of the shared credentials file |
| `S3_BUCKET` | the default bucket |

In development they can come from `.env` too.

| Provider | Endpoint | Region | Addressing |
| --- | --- | --- | --- |
| AWS | none, or `https://s3.<region>.amazonaws.com` | the bucket's | virtual host for DNS-safe bucket names, else path |
| Cloudflare R2 | `https://<account>.r2.cloudflarestorage.com` | `auto` | path |
| MinIO, Garage, Ceph | `http://host:9000` | any | path |
| Backblaze B2 | `https://s3.<region>.backblazeb2.com` | the bucket's | path |
| Supabase | `https://<ref>.supabase.co/storage/v1/s3` | the project's | path (the base path is kept in every URL) |

`Options.provider` and `Options.addressing` override what the endpoint's host implies.

### Credentials

Without keys in the options, the chain is: the environment, then the shared credentials file (static keys of `AWS_PROFILE` or `default`), then, for AWS endpoints only, web identity (`AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN` through STS), the container endpoint (ECS, EKS Pod Identity) and EC2's IMDSv2. Temporary credentials are renewed five minutes before they expire, by one task, and a failed renewal keeps the old ones until they expire. `.credentials = .anonymous` sends unsigned requests (public buckets). SSO, `credential_process` and assume-role chains in the config file are not supported.

A start that finds no credentials fails and names every source it tried:

    s3 "s3": no credentials (environment: AWS_ACCESS_KEY_ID not set; /home/app/.aws/credentials: no file; web identity: AWS_WEB_IDENTITY_TOKEN_FILE not set; container: not set; EC2 metadata: no answer in 1 s)

## Calls

| Call | What it does |
| --- | --- |
| `get(c, key, opts) !Object` | the whole object (at most `max_bytes`, default `max_object_bytes` 16 MiB) with its `Meta` |
| `optional(c, key, opts) !?Object` | the same, `null` for a missing key |
| `open(c, key, opts) !Download` | a stream: `reader()` or `pipe(w)`, then `deinit()` |
| `serve(req, res, key, opts) !Meta` | answers the request from the object (see below) |
| `head`, `exists` | metadata; whether the key exists |
| `put(c, key, body, opts) !Stored` | `body` is `.bytes`, `.reader`, `.file` or `.request` |
| `upload(c, key, opts) !*Upload` | a push upload (see below) |
| `delete`, `deleteMany` | one key; any number, 1000 per request |
| `list`, `iterate` | one page of ListObjectsV2; the pages on demand |
| `copy(c, from, to_key, opts)` | CopyObject (up to 5 GiB) |
| `presign(c, method, key, opts)` | a URL anyone can use for a while |
| `multipart()` | `create`, `complete`, `abort` for browsers uploading parts |
| `bucket(name)`, `with(.{ .timeout, .retry })` | the same calls on another bucket, or with call options |

Reads take `range`, `version_id`, `if_none_match`, `if_match` and `if_modified_since`; a `304` is an `Object` with `meta.not_modified`. Writes take `content_type` (from the key's extension by default), `cache_control`, `content_disposition`, `content_encoding`, `metadata` (`x-amz-meta-*`), `storage_class`, `if_absent` (create only: `If-None-Match: *`) and `if_match`.

Keys are 1 to 1024 bytes of UTF-8. They are encoded for the URL and the signature as SigV4 asks, so spaces, `+`, `&` and non-ASCII are fine.

### serve

`serve` forwards `Range`, `If-None-Match`, `If-Match` and `If-Modified-Since` from the request (an `If-Range` drops the `Range`: the whole object is sent, as RFC 9110 allows), passes 200, 206, 304, 412 and 416 through with `Content-Type`, `Content-Length`, `Content-Range`, `ETag`, `Last-Modified`, `Accept-Ranges`, `Cache-Control`, `Content-Disposition` and `Content-Encoding`, and streams the body without holding it. A `HEAD` request uses HeadObject. A missing key is `error.NotFound` before anything is sent, so the handler can answer with its own 404 page.

### Uploads

An upload never holds a whole object. Up to `multipart_threshold` (default `part_size`, 8 MiB) a body of known length is one PutObject; above it, or when the length is not known, it goes up as a multipart upload with `part_size` parts (raised to `ceil(length / 10000)` so 10,000 parts always suffice; all parts have the same size, which R2 requires), at most `concurrency` (default 2) in flight. One upload holds at most `(concurrency + 1) * part_size` in memory, and all of a client's uploads together at most `upload_memory` (256 MiB).

`put(c, key, .request, .{})` is the pull form: it reads the request's body at its own pace and sends it on (`limits.body_max` applies). `upload(c, key, opts)` is the push form for code that produces bytes: `write(c, bytes)` copies them into the part buffers and **returns at once**. It never waits for the network:

- `.ok`: taken, room for more;
- `.busy`: taken, but more than `concurrency * part_size` is buffered; wait with `waitWritable(c, timeout)` before writing more;
- `error.ServiceUnavailable` with `lastError` code `upload_full`: nothing taken (a part more is buffered, or `upload_memory` is used up).

`finish(c)` sends the rest and completes. `abort()` and `deinit()` before `finish` abort the multipart upload; when even that fails, the log says "incomplete multipart upload <id> of <key> left; a bucket lifecycle rule AbortIncompleteMultipartUpload removes it". Set that rule on every bucket you upload to.

### Presigned URLs

`presign` is pure and synchronous: GET, PUT, HEAD, DELETE, and UPLOAD_PART (an upload id and a part number) for browser multipart uploads. The default expiry is 15 minutes, the longest 7 days. A PUT URL can sign `content_type` and an exact `content_length`, so a browser can only upload that many bytes. POST policies are not supported (R2 has none).

## Timeouts, retries, breaker

`timeout` (30 s) bounds each call. A call that moves a body gets `timeout + bytes / min_throughput` (`min_throughput` 1 MiB/s), so a large part is not cut at 30 s on a slow link. A streamed download is bounded by `timeout` to its head and then by `timeout` per read: a connection that sends nothing for 30 s ends the read with `error.GatewayTimeout`, however large the object.

Retries are **on** by default (3 attempts, 100 ms to 2 s): every operation Anole sends is idempotent, and S3 asks clients to retry 500 and 503 SlowDown. Transport errors, 500, 502, 503, 504, `RequestTimeout`, `SlowDown` and `InternalError` are retried, and a `RequestTimeTooSkewed` answer corrects the client's clock from the response's `Date` and repeats the call once. `with(.{ .retry = false })` tries one call once. A circuit breaker (one per client) is on by default, as for the databases. Readiness is **off** by default (`Options.readiness`): a storage outage hits every instance at once, and pulling them all from the load balancer makes it worse.

## Errors

| S3 | Class | Status |
| --- | --- | --- |
| 404 `NoSuchKey`, `NoSuchBucket`, `NoSuchUpload`, `NoSuchVersion` | `not_found` | 404 |
| 412 `PreconditionFailed`, 409 `ConditionalRequestConflict` | `precondition` | 409 |
| 416 `InvalidRange`, `KeyTooLongError`, `InvalidArgument`, `EntityTooSmall`, `EntityTooLarge`, `InvalidPart`, `InvalidPartOrder`, `InvalidBucketName`, `MissingContentLength`; Anole's `invalid_key`, `object_too_large`, `too_many_parts`, `short_body` and the other checks of a call's arguments | `invalid` | 400 |
| transport errors, 500, 502, 503, 504, `SlowDown`, `ServiceUnavailable`, `InternalError`, `RequestTimeout` (a 400), `ThrottlingException`, `RequestLimitExceeded`, `Throttling` | `unavailable` | 503 |
| past the timeout | `timeout` | 504 |
| everything else (403 `AccessDenied`, `SignatureDoesNotMatch`, `InvalidAccessKeyId`, 301 `PermanentRedirect`...) | `other` | 500 |

A wrong region or a bad key is the server's misconfiguration, so it answers 500 with a clear log line; a `PermanentRedirect` names the bucket's region. `anole.db.lastError(req).?.code` is S3's `<Code>`, or Anole's own: among them `no_bucket`, `no_credentials`, `invalid_key`, `object_too_large`, `too_many_parts`, `short_body`, `body_too_big`, `file_not_found`, `invalid_expires`, `upload_full`, `upload_over`, `transport`, `bad_response`, `write_timeout`, `draining` and `circuit_open`. `Options.errors` moves any class to another status.

## Shutdown

Once the server drains, no upload starts (`ServiceUnavailable`, code `draining`); those in flight run to their end until the deadline, then abort.

## Testing

`anole.s3.testing.FakeServer` is an S3 in process, on Anole's HTTP server, for tests that need no Docker. It keeps objects in memory, **verifies every request's SigV4 signature** (header or presigned) with the same code the client uses, and models what S3 checks: ListObjectsV2, multipart (with the 5 MiB minimum part), conditional and range requests, `If-None-Match: *`. `addFault` scripts failures (a 503 twice, a clock-skew answer); `hold_parts` and `stall_gets` make back-pressure and the idle bound testable without timing.

```zig
var fake = try anole.s3.testing.FakeServer.start(gpa, io);
defer fake.stop();
const files = try anole.s3.Client.init(gpa, io, .{ .endpoint = fake.url(), .bucket = "b", .credentials = fake.credentials() });
```

It starts on a zio runtime (`dusty.Server` wants one). The live tests run against MinIO with `tests/s3/run.sh` (plain and TLS).

## The C ABI

Node and Python apps get the same client through the C ABI: `"storage"` in
the configuration, and `anole_s3_put`, `anole_s3_get`, `anole_s3_serve`,
`anole_s3_presign`, the streamed uploads and downloads, multipart, listing,
copying and deleting. `serve` and `put_body` move an object to and from a
request without it entering the language. See
[c-abi.md](c-abi.md#object-storage-s3).

## What v1 leaves out

Bucket administration, ACLs, tagging, object lock, SSE-C, UploadPartCopy (copies over 5 GiB), POST policies and S3 Express directory buckets. They are not needed for what an app does with its files; bucket setup belongs in infrastructure code.

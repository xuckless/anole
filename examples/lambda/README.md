# examples/lambda

The same app as a server and as an AWS Lambda function. `GET /` answers
JSON; SQS batches (or any event that is not an HTTP request) arrive on
`POST /_lambda/event`. See [docs/lambda.md](../../docs/lambda.md).

## Run it locally

```
zig build run-lambda
curl localhost:3000/
```

## Build the zips

In a project of your own, `addApp` builds them:

```zig
_ = @import("anole").addApp(b, .{
    .name = "api",
    .root_source_file = b.path("src/main.zig"),
    .lambda = .{},
});
```

`zig build lambda` writes `zig-out/lambda/api-arm64.zip` and
`zig-out/lambda/api-x86_64.zip`, each holding `bootstrap` built with
`deployment = lambda` as its default (`-Dlambda-arch=arm64` builds one).

## Deploy

```
aws lambda create-function --function-name api --runtime provided.al2023 --architectures arm64 \
  --handler bootstrap --zip-file fileb://zig-out/lambda/api-arm64.zip --role <role-arn>
aws lambda create-function-url-config --function-name api --auth-type NONE
curl https://<url-id>.lambda-url.<region>.on.aws/
```

To run the zip under the Runtime Interface Emulator instead (the image's
architecture must match the zip's):

```
mkdir -p lambda-task && unzip -o zig-out/lambda/api-arm64.zip -d lambda-task
docker run -p 9000:8080 -v $PWD/lambda-task:/var/task public.ecr.aws/lambda/provided:al2023 bootstrap
curl -d '{"version":"2.0","rawPath":"/","rawQueryString":"","headers":{},"requestContext":{"http":{"method":"GET","sourceIp":"127.0.0.1"},"domainName":"localhost"}}' \
  http://localhost:9000/2015-03-31/functions/function/invocations
```

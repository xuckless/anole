# Build from the repository root:
#   docker build -f bench/servers/gohttp/Dockerfile -t anole-bench/gohttp .
FROM golang:1.27.2-alpine3.24@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS build
WORKDIR /src
COPY bench/servers/gohttp/go.mod bench/servers/gohttp/go.sum ./
RUN go mod download
COPY bench/servers/gohttp/*.go ./
COPY bench/servers/gohttp/testpb ./testpb
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /server .

FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
COPY --from=build /server /server
ENTRYPOINT ["/server"]

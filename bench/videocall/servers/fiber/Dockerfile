# The video-call relay on Fiber v3 + webtransport-go. Build from the repository root:
#   docker build -f bench/videocall/servers/fiber/Dockerfile -t anole-bench/vc-fiber .
FROM golang:1.27.2-alpine3.24@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS build
WORKDIR /src
COPY bench/videocall/servers/fiber/go.mod bench/videocall/servers/fiber/go.sum ./
RUN go mod download
COPY bench/videocall/servers/fiber/*.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /server .

FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
COPY --from=build /server /server
ENTRYPOINT ["/server"]

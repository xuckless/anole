# The nginx front for the "behind nginx" variants (<framework>-nginx): a
# static nginx 1.30.1 (the baseline's version) and a small launcher, copied
# into each framework's own image so that nginx shares its CPU and memory
# budget. Built from the repository root:
#   docker build -f bench/servers/front/Dockerfile -t anole-bench/front .
FROM alpine:3.24 AS nginx
RUN apk add --no-cache build-base linux-headers perl \
      openssl-dev openssl-libs-static zlib-dev zlib-static
ARG NGINX=1.30.1
ARG NGINX_SHA256=99765000d974896b31ca5882d8c279ce3fe7ef6f5c6f9f0a967ed7fd3407f9cc
RUN wget -qO /tmp/nginx.tar.gz https://nginx.org/download/nginx-$NGINX.tar.gz \
 && echo "$NGINX_SHA256  /tmp/nginx.tar.gz" | sha256sum -c - \
 && mkdir /src && tar -xzf /tmp/nginx.tar.gz -C /src --strip-components=1
WORKDIR /src
RUN ./configure --prefix=/front --sbin-path=/front/nginx --conf-path=/tmp/front/nginx.conf \
      --pid-path=/tmp/front/nginx.pid --lock-path=/tmp/front/nginx.lock \
      --error-log-path=stderr --http-log-path=/dev/null \
      --http-client-body-temp-path=/tmp/front/body --http-proxy-temp-path=/tmp/front/proxy \
      --without-http_fastcgi_module --without-http_uwsgi_module --without-http_scgi_module --without-http_rewrite_module \
      --with-threads --with-http_ssl_module --with-http_v2_module --with-http_v3_module \
      --with-cc-opt='-O2 -static' --with-ld-opt='-static' \
 && make -j"$(nproc)" && mkdir -p /out/front && cp objs/nginx conf/mime.types /out/front/

FROM golang:1.27.2-alpine3.24@sha256:f92b6ef800e499660581efdabdf25d9d817a9d124eaf900924f0504e7e27e12d AS launch
WORKDIR /launch
COPY bench/servers/front/launch.go ./
RUN go mod init launch && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/front/launch .

FROM scratch
COPY --from=nginx /out/front/ /front/
COPY --from=launch /out/front/launch /front/launch
COPY bench/servers/front/nginx.conf.in /front/nginx.conf.in

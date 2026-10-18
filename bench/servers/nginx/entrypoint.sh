#!/bin/sh
# Writes nginx.conf for MODE and WORKERS, then runs nginx in the foreground.
set -eu
mode=${MODE:-h1}
case "$mode" in
h1) listen="listen ${HTTP_PORT:-8080} reuseport backlog=65535;" ;;
tls) listen="listen ${HTTPS_PORT:-8443} ssl reuseport backlog=65535; http2 on;" ;;
h3) listen="listen ${HTTPS_PORT:-8443} ssl reuseport backlog=65535; listen ${HTTPS_PORT:-8443} quic reuseport; http2 on; http3 on; add_header Alt-Svc 'h3=\":${HTTPS_PORT:-8443}\"; ma=86400' always;" ;;
*) echo "MODE=$mode is not supported by nginx" >&2; exit 3 ;;
esac
sed -e "s|@WORKERS@|${WORKERS:-1}|" -e "s|@LISTEN@|$listen|" -e "s|@MEDIA@|${MEDIA_DIR:-/media}|" \
    -e "s|@CERT@|${CERT_FILE:-/certs/cert.pem}|" -e "s|@KEY@|${KEY_FILE:-/certs/key.pem}|" \
    /etc/nginx/nginx.conf.in >/etc/nginx/nginx.conf
exec nginx -g 'daemon off;'

# nginx as the baseline: fixed responses for /plaintext and /json, and the
# media directory with sendfile, over HTTP/1.1, TLS (h2 + http/1.1) and
# HTTP/3. Built from the repository root:
#   docker build -f bench/servers/nginx/Dockerfile -t anole-bench/nginx .
FROM nginx:1.30.1
COPY bench/servers/nginx/nginx.conf.in /etc/nginx/nginx.conf.in
COPY bench/servers/nginx/entrypoint.sh /bench-entrypoint.sh
ENTRYPOINT ["/bench-entrypoint.sh"]

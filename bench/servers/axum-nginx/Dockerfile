# axum behind nginx in the same container (bench/servers/front): nginx on
# the bench ports, axum on 127.0.0.1:9080 over HTTP/1.1. Needs anole-bench/axum
# and anole-bench/front. Built from the repository root:
#   docker build -f bench/servers/axum-nginx/Dockerfile -t anole-bench/axum-nginx .
FROM anole-bench/front AS front
FROM anole-bench/axum
COPY --from=front /front/ /front/
ENTRYPOINT ["/front/launch", "/axum-bench"]

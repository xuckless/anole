# fastapi behind nginx in the same container (bench/servers/front): nginx on
# the bench ports, fastapi on 127.0.0.1:9080 over HTTP/1.1. Needs anole-bench/fastapi
# and anole-bench/front. Built from the repository root:
#   docker build -f bench/servers/fastapi-nginx/Dockerfile -t anole-bench/fastapi-nginx .
FROM anole-bench/front AS front
FROM anole-bench/fastapi
COPY --from=front /front/ /front/
ENTRYPOINT ["/front/launch", "/app/entrypoint.sh"]

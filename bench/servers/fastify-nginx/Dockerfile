# fastify behind nginx in the same container (bench/servers/front): nginx on
# the bench ports, fastify on 127.0.0.1:9080 over HTTP/1.1. Needs anole-bench/fastify
# and anole-bench/front. Built from the repository root:
#   docker build -f bench/servers/fastify-nginx/Dockerfile -t anole-bench/fastify-nginx .
FROM anole-bench/front AS front
FROM anole-bench/fastify
COPY --from=front /front/ /front/
ENTRYPOINT ["/front/launch", "node", "server.mjs"]

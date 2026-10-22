# express behind nginx in the same container (bench/servers/front): nginx on
# the bench ports, express on 127.0.0.1:9080 over HTTP/1.1. Needs anole-bench/express
# and anole-bench/front. Built from the repository root:
#   docker build -f bench/servers/express-nginx/Dockerfile -t anole-bench/express-nginx .
FROM anole-bench/front AS front
FROM anole-bench/express
COPY --from=front /front/ /front/
ENTRYPOINT ["/front/launch", "node", "server.mjs"]

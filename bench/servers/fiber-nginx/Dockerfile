# fiber behind nginx in the same container (bench/servers/front): nginx on
# the bench ports, fiber on 127.0.0.1:9080 over HTTP/1.1. Needs anole-bench/fiber
# and anole-bench/front. Built from the repository root:
#   docker build -f bench/servers/fiber-nginx/Dockerfile -t anole-bench/fiber-nginx .
FROM anole-bench/front AS front
FROM anole-bench/fiber
COPY --from=front /front/ /front/
ENTRYPOINT ["/front/launch", "/server"]

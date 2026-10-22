# anole behind nginx in the same container (bench/servers/front): nginx on
# the bench ports, anole on 127.0.0.1:9080 over HTTP/1.1. Needs anole-bench/anole
# and anole-bench/front. Built from the repository root:
#   docker build -f bench/servers/anole-nginx/Dockerfile -t anole-bench/anole-nginx .
FROM anole-bench/front AS front
FROM anole-bench/anole
COPY --from=front /front/ /front/
ENTRYPOINT ["/front/launch", "/entrypoint.sh"]

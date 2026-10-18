# Anole's WebTransport server as an interop runner endpoint.
# tests/interop/webtransport/run.sh builds the binary for Linux and this
# image around it.
FROM martenseemann/quic-network-simulator-endpoint:latest
COPY wt-interop-server /usr/local/bin/
COPY run_endpoint.sh /
RUN chmod +x /run_endpoint.sh
ENTRYPOINT [ "/run_endpoint.sh" ]

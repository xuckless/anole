# Anole's server as a QUIC interop runner endpoint. tests/interop/run.sh
# builds the binary for Linux and this image around it.
FROM martenseemann/quic-network-simulator-endpoint:latest
COPY h3-interop-server /usr/local/bin/
COPY run_endpoint.sh /
RUN chmod +x /run_endpoint.sh
ENTRYPOINT [ "/run_endpoint.sh" ]

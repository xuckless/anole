# grpc-dotnet's interop programs (v2.84.0) with QUIC, to test gRPC over
# HTTP/3 (gRFC G2) against Anole in both directions. Glibc, not Alpine:
# Grpc.Tools' bundled protoc is glibc-linked. run.sh builds the image when
# it is missing and tags it with this file's hash.
#
# Pin the base image by digest (`docker buildx imagetools inspect`) and
# libmsquic by version (`apt-cache policy libmsquic`) once a run is green;
# .NET 7+ needs libmsquic 2.2 or later.
FROM mcr.microsoft.com/dotnet/sdk:10.0-noble

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git openssl \
 && curl -fsSL -o /tmp/ms.deb https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb \
 && dpkg -i /tmp/ms.deb \
 && rm /tmp/ms.deb \
 && apt-get update \
 && apt-get install -y --no-install-recommends libmsquic \
 && rm -rf /var/lib/apt/lists/*

# Fails loudly when QUIC is missing.
RUN test -e /usr/lib/x86_64-linux-gnu/libmsquic.so.2 || test -e /usr/lib/aarch64-linux-gnu/libmsquic.so.2

RUN git clone --depth 1 --branch v2.84.0 https://github.com/grpc/grpc-dotnet /src \
 && dotnet publish /src/testassets/InteropTestsClient -c Release -f net10.0 -p:LatestFramework=true -o /opt/client \
 && dotnet publish /src/testassets/InteropTestsWebsite -c Release -f net10.0 -p:LatestFramework=true -o /opt/server

# Bun video-call server (bench/videocall/SPEC.md). Build from the repository root:
#   docker build -f bench/videocall/servers/bun/Dockerfile -t anole-bench/vc-bun .
# The slim image is Debian trixie (glibc 2.41); the QUICHE addon needs >= 2.38.
# Its install script (trustedDependencies) fetches the prebuilt linux-x64 addon.
FROM oven/bun:1.4.3-slim
ENV NODE_ENV=production
WORKDIR /app
COPY bench/videocall/servers/bun/package.json bench/videocall/servers/bun/bun.lock ./
RUN bun install --frozen-lockfile --production
COPY bench/videocall/servers/bun/server.ts bench/videocall/servers/bun/app.ts bench/videocall/servers/bun/webtransport.ts ./
ENTRYPOINT ["bun", "server.ts"]

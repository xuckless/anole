# Express 5 bench server. Build from the repository root:
#   docker build -f bench/servers/express/Dockerfile -t anole-bench/express .
FROM node:24.22.0-bookworm-slim
ENV NODE_ENV=production
WORKDIR /app
COPY bench/servers/express/package.json bench/servers/express/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY bench/servers/express/*.mjs ./
ENTRYPOINT ["node", "server.mjs"]

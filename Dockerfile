# Root-level Dockerfile so Render (and any other host that auto-detects
# ./Dockerfile) just works without per-service configuration.
#
# The actual server build lives in server/Dockerfile — this file is a
# thin wrapper that includes it. Build context = repo root.
#
#   docker build -t kartchain-server .
#   docker run -p 2567:2567 --env-file .env kartchain-server

FROM node:20-bookworm-slim AS deps
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY server/package.json ./server/package.json
RUN pnpm install --filter @kartchain/server... --frozen-lockfile

FROM deps AS build
WORKDIR /app
COPY server ./server
RUN pnpm --filter @kartchain/server run build

FROM node:20-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=2567
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate
COPY --from=build /app/package.json /app/pnpm-workspace.yaml /app/pnpm-lock.yaml ./
COPY --from=build /app/server/package.json ./server/package.json
COPY --from=build /app/server/dist ./server/dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/server/node_modules ./server/node_modules

EXPOSE 2567

CMD ["node", "server/dist/index.js"]

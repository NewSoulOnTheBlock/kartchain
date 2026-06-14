# Dockerfile for deploying the Kartchain Colyseus server to Render
# (or any other Docker-compatible host: Fly.io, Railway, Cloud Run, etc.)
#
# Build context: REPO ROOT (so we can copy the workspace files).
#   docker build -f server/Dockerfile -t kartchain-server .
#   docker run -p 2567:2567 --env-file .env kartchain-server
#
# All secrets come from env vars at runtime — see server/src/solana/wallets.ts
# for the names (TREASURY_KEYPAIR_JSON, ESCROW_KEYPAIR_JSON, etc.)

FROM node:20-bookworm-slim AS deps
WORKDIR /app

# Enable pnpm via corepack
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate

# Copy workspace files. We need root package.json + pnpm-workspace.yaml +
# the server package (web/ is not needed by the server build).
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY server/package.json ./server/package.json

# We tell pnpm to only install for the server filter to keep the image tight.
RUN pnpm install --filter @kartchain/server... --frozen-lockfile

# ── build stage ───────────────────────────────────────────────────────────
FROM deps AS build
WORKDIR /app
COPY server ./server
RUN pnpm --filter @kartchain/server run build

# ── runtime stage ─────────────────────────────────────────────────────────
FROM node:20-bookworm-slim AS runtime
WORKDIR /app
ENV NODE_ENV=production
ENV PORT=2567

RUN corepack enable && corepack prepare pnpm@9.12.0 --activate

# Bring just what we need to run.
COPY --from=build /app/package.json /app/pnpm-workspace.yaml /app/pnpm-lock.yaml ./
COPY --from=build /app/server/package.json ./server/package.json
COPY --from=build /app/server/dist ./server/dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/server/node_modules ./server/node_modules

EXPOSE 2567

CMD ["node", "server/dist/index.js"]

# Root-level Dockerfile so Render (and any other host that auto-detects
# ./Dockerfile) just works without per-service configuration.
#
# Mirrors server/Dockerfile — kept in sync so either path works. Build
# context = repo root.
#
#   docker build -t kartchain-server .
#   docker run -p 2567:2567 --env-file .env kartchain-server

# ── sim-builder stage (Rust → WASM) ───────────────────────────────────────
FROM rust:1-slim-bookworm AS sim-builder
WORKDIR /work
RUN rustup target add wasm32-unknown-unknown
COPY sim ./sim
RUN cd sim && cargo rustc --release --target wasm32-unknown-unknown --crate-type cdylib

# ── deps stage ────────────────────────────────────────────────────────────
FROM node:20-bookworm-slim AS deps
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@9.12.0 --activate
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY server/package.json ./server/package.json
RUN pnpm install --filter @kartchain/server... --frozen-lockfile

# ── build stage ───────────────────────────────────────────────────────────
FROM deps AS build
WORKDIR /app
COPY server ./server
RUN pnpm --filter @kartchain/server run build:ts

# ── runtime stage ─────────────────────────────────────────────────────────
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
COPY --from=sim-builder \
     /work/sim/target/wasm32-unknown-unknown/release/kart_sim.wasm \
     /app/sim/target/wasm32-unknown-unknown/release/kart_sim.wasm

EXPOSE 2567

CMD ["node", "server/dist/index.js"]

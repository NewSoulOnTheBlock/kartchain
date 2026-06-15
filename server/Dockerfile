# Dockerfile for deploying the Kartchain Colyseus server to Render
# (or any other Docker-compatible host: Fly.io, Railway, Cloud Run, etc.)
#
# Build context: REPO ROOT (so we can copy the workspace files + sim/).
#   docker build -f server/Dockerfile -t kartchain-server .
#   docker run -p 2567:2567 --env-file .env kartchain-server
#
# All secrets come from env vars at runtime — see server/src/solana/wallets.ts
# for the names (TREASURY_KEYPAIR_JSON, ESCROW_KEYPAIR_JSON, etc.)

# ── sim-builder stage ─────────────────────────────────────────────────────
# Rust → WASM compile for the deterministic kart physics module. Isolated
# in its own stage so the ~500 MB Rust toolchain never reaches the runtime
# image. The .wasm is copied out below.
FROM rust:1-slim-bookworm AS sim-builder
WORKDIR /work
RUN rustup target add wasm32-unknown-unknown
COPY sim ./sim
RUN cd sim && cargo rustc --release --target wasm32-unknown-unknown --crate-type cdylib

# ── deps stage ────────────────────────────────────────────────────────────
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
# Only the TypeScript compile runs here — `sim:build` (cargo) was already
# handled in the sim-builder stage above. Calling `build:ts` directly keeps
# this stage free of the Rust toolchain.
RUN pnpm --filter @kartchain/server run build:ts

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
# Pre-built deterministic kart_sim.wasm at the exact path the runtime
# loader expects (server/src/simulation/wasmSim.ts → defaultWasmPath).
COPY --from=sim-builder \
     /work/sim/target/wasm32-unknown-unknown/release/kart_sim.wasm \
     /app/sim/target/wasm32-unknown-unknown/release/kart_sim.wasm

EXPOSE 2567

CMD ["node", "server/dist/index.js"]

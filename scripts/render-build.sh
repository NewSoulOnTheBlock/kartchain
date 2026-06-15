#!/usr/bin/env bash
set -euo pipefail

# Build script for Render's Node-runtime deploys of @kartchain/server.
#
# Why this exists: server/scripts → `sim:build` shells out to
# `cargo rustc --target wasm32-unknown-unknown ...` to produce the
# deterministic kart_sim.wasm. Render's Node image doesn't ship Rust, so
# we bootstrap rustup + the wasm32 target before running pnpm.
#
# If the service is ever switched to Docker, this file is unused — the
# server/Dockerfile (and root Dockerfile) build the .wasm in a dedicated
# `sim-builder` Rust stage and never touch this script.
#
# Usage (Render dashboard → Settings → Build Command):
#   ./scripts/render-build.sh

if ! command -v cargo >/dev/null 2>&1; then
  echo "→ Installing Rust (rustup, minimal profile, stable + wasm32 target)"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
    sh -s -- -y --profile minimal --default-toolchain stable -t wasm32-unknown-unknown
fi

# Source cargo env so $PATH includes ~/.cargo/bin in this shell.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.cargo/env"
fi

# Idempotent: ensures the target exists even when cargo was pre-installed
# (e.g. from a cached Render disk where rustup survived the last build).
rustup target add wasm32-unknown-unknown

corepack enable
corepack prepare pnpm@9.12.0 --activate

pnpm install --frozen-lockfile
pnpm --filter @kartchain/server build

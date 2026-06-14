# Kartchain web host

Next.js 15 (App Router) app that:

1. Owns the Solana **wallet adapter** UI (Phantom, Solflare).
2. Embeds the exported **Godot game** in an iframe at `/race`.
3. Installs `window.kartchain` — the JS bridge the Godot WASM calls to
   read the wallet, sign entry-fee transfers, and stream Colyseus events.
4. Renders the **Garage** (NFT karts browser).

## Develop

```bash
pnpm install         # first time
pnpm dev             # http://localhost:3000
```

By default it expects the Colyseus server on `ws://localhost:2567`. Override
with `NEXT_PUBLIC_COLYSEUS_URL` / `NEXT_PUBLIC_SERVER_URL` in `.env.local`.

## Build the Godot client into here

```bash
# From repo root
pnpm build:client
# → writes index.html, index.wasm, index.pck, index.js, index.audio.worklet.js
#   into web/public/game/
```

These outputs are in `.gitignore`. The placeholder `index.html` shipped in
git just tells you to run the export.

## Cross-origin isolation

Godot's WebAssembly build uses SharedArrayBuffer, which requires:

```
Cross-Origin-Opener-Policy:   same-origin
Cross-Origin-Embedder-Policy: require-corp
```

These are sent for every route by `next.config.mjs`.

## Layout

| Path | Purpose |
|---|---|
| `app/layout.tsx` | Root layout + WalletProviders |
| `app/providers.tsx` | ConnectionProvider + WalletProvider + KartchainBridge |
| `app/page.tsx` | Landing page |
| `app/race/page.tsx` | Race page; renders `<GodotGame />` iframe |
| `app/garage/page.tsx` | NFT kart browser |
| `components/KartchainBridge.tsx` | Installs `window.kartchain` API for the game |
| `components/GodotGame.tsx` | Iframe wrapper around the Godot bundle |
| `components/WalletButton.tsx` | Wallet adapter modal trigger |
| `lib/karts.ts` | React hook for fetching owned karts |
| `lib/karts-fetch.ts` | Plain fetcher (stub — wire up Helius DAS) |

## `window.kartchain` API surface

See the JSDoc in `components/KartchainBridge.tsx`. Mirrored on the Godot
side in `client/scripts/SolanaBridge.gd` and `client/scripts/NetworkClient.gd`.

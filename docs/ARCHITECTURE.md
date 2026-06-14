# Architecture

## Process boundaries

```
┌──────────────────────────────────────────────────────────────┐
│ Browser tab                                                  │
│                                                              │
│  ┌──────────────────────┐    JS bridge   ┌────────────────┐ │
│  │ Next.js (React)      │ ◄────────────► │ Godot 4 WASM   │ │
│  │  - Wallet adapter    │  postMessage   │  - Render      │ │
│  │  - Garage / Lobby UI │                │  - Physics     │ │
│  │  - Tx confirm modal  │                │  - Input       │ │
│  └────────┬─────────────┘                │  - Net client  │ │
│           │                              └────────┬───────┘ │
└───────────┼───────────────────────────────────────┼─────────┘
            │ HTTPS                                 │ WSS
            ▼                                       ▼
   ┌──────────────────┐                  ┌─────────────────────┐
   │ Solana RPC       │                  │ Colyseus server     │
   │ (Helius/Triton)  │                  │ (Node 20)           │
   └────────┬─────────┘                  │  - LobbyRoom        │
            │                            │  - RaceRoom (8p)    │
            │                            │  - 30Hz auth tick   │
            │                            │  - Verifies txs     │
            │                            │  - Settles results  │
            │                            └─────────┬───────────┘
            │                                      │ Signs settle ix
            ▼                                      ▼
   ┌────────────────────────────────────────────────────────┐
   │ Anchor program: kart_race                              │
   │                                                        │
   │  init_race(race_pda, entry_fee, prize_split)           │
   │  enter_race(race_pda) -> transfers to escrow vault     │
   │  settle_race(race_pda, results[]) -> server signer     │
   │  claim_p2e(amount, attestation) -> mints P2E SPL       │
   │  mint_kart_nft(metadata_uri) -> Metaplex Core          │
   └────────────────────────────────────────────────────────┘
```

## Why these boundaries?

### Why Godot for the renderer?
- Excellent WebGL2 + WebGPU export (single command `godot --export-release Web`).
- VehicleBody3D gives us realistic kart physics out of the box.
- Smaller build size than Unity WebGL (~10 MB vs 30 MB initial).
- MIT license, no per-seat fees.

### Why Next.js wraps the canvas?
- The Solana wallet adapter ecosystem (`@solana/wallet-adapter-react`) is
  React-first. Wrapping the game canvas in React is much easier than
  rebuilding wallet-standard inside Godot.
- Server actions handle session creation, off-chain leaderboards, fiat
  onramp links cleanly.
- Easy host on Cloudflare Pages / Vercel.

### Why Colyseus?
- Authoritative server prevents cheating (clients can't fake race results).
- Built-in state synchronization with delta encoding.
- Schema validation, room lifecycle, and matchmaking are "free."
- TypeScript end-to-end — shared schema between client and server (we
  re-implement the schema in Godot, but the wire format is documented).

### Why custodial server-side wallets (no Anchor program)?
- MVP simplicity — no Rust, no on-chain deploy, no IDL plumbing.
- All Solana ops are plain `SystemProgram.transfer` / `mintTo` / Metaplex CPI
  signed by server-held keypairs.
- Trade-off: players trust the server operator. Acceptable for MVP, drop-in
  swappable for an Anchor program later (see `docs/SOLANA.md`).

## Trust model

| Action | Trusted by | Verified how |
|---|---|---|
| Wallet signature | Solana RPC | On-chain |
| Race entry | Colyseus server | Server fetches the entry tx and checks payer / amount-to-escrow / memo |
| Race results | Colyseus server | Server runs simulation; clients send inputs only |
| Prize payout | Server-held `escrow` wallet | Server-signed `SystemProgram.transfer`s, batched in one tx |
| P2E rewards | Server-held `p2eMint` wallet | Server-signed `mintTo` (mint authority on the SPL token) |
| NFT kart mints | Server-held `nftAuth` wallet | Server-signed Metaplex Core CPI |

**This design is fully custodial.** Players trust the server operator not to
steal entry fees or misreport race results. See `docs/SOLANA.md` for the
hot-wallet hygiene checklist and the migration path to an on-chain program
when trust becomes a bottleneck.

## Tick model

- **Server tick:** 30 Hz authoritative simulation. Clients send input deltas
  (steering, throttle, brake, item use) at 30 Hz. Server broadcasts state at
  30 Hz to all clients in the room.
- **Client tick:** Godot runs at refresh rate. Local kart uses client-side
  prediction; remote karts are interpolated.

See [`NETWORKING.md`](NETWORKING.md) for the wire protocol.

## File ownership

| Module | Owns |
|---|---|
| `client/` | Rendering, input, prediction, audio, UI text/menus |
| `server/` | Game rules, physics source-of-truth, matchmaking, **custodial hot wallets** (escrow / treasury / p2eMint / nftAuth), settlement + P2E mint signing |
| `web/` | Wallet adapter, Solana RPC calls (build + sign entry-fee transfers), off-chain user profile, garage UI |

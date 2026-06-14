# Kartchain Colyseus server

Authoritative game server for Kartchain. Hosts a `LobbyRoom` (always on) and
spawns `RaceRoom`s for 8-player races.

## Quick start

```bash
pnpm install
cd ..  # back to repo root
pnpm run keys:gen   # creates treasury/escrow/p2e-mint/nft-auth keypairs in server/
cd server
cp ../.env.example .env
pnpm dev
```

Server listens on `ws://localhost:2567`. Open
[`http://localhost:2567/colyseus`](http://localhost:2567/colyseus) for the
Colyseus monitor (dev only).

## Layout

| Path | Purpose |
|---|---|
| `src/index.ts` | Express + Colyseus bootstrap; REST endpoints (`/api/escrow-address`, admin mint) |
| `src/rooms/LobbyRoom.ts` | Always-on lobby browser; matchmaker bridge |
| `src/rooms/RaceRoom.ts` | 8-player race instance; authoritative sim + auto-settle |
| `src/schemas/RaceState.ts` | Colyseus schema for race state |
| `src/simulation/kartSim.ts` | Toy server-side kart physics |
| `src/solana/wallets.ts` | Loads custodial hot wallets (treasury / escrow / p2eMint / nftAuth) |
| `src/solana/rpc.ts` | Lazy `Connection` |
| `src/solana/verifyEntry.ts` | Verifies a player's entry-fee transfer before they join a paid lobby |
| `src/solana/settle.ts` | Signs prize-pool payouts (escrow → winners) |
| `src/solana/p2e.ts` | Mints P2E SPL tokens to finishers |
| `src/solana/kartNft.ts` | Mints Metaplex Core kart NFTs (stub) |

## Trust model

- Clients send **input deltas only** (throttle/brake/steer + `useItem`)
- Server runs the simulation and broadcasts state via Colyseus schema sync
- Paid lobbies require an `entryTxSignature` validated via `verifyEntryTx`
  (plain `SystemProgram.transfer` to our escrow keypair + memo with raceId)
- Race outcome is settled by the **`escrow` keypair signing transfers** to
  winners (no on-chain program — fully custodial). See `docs/SOLANA.md`.

## Tests

```bash
pnpm test
```

Vitest in single-worker mode (Windows compatibility).

## Production deployment

- Keep the four keypairs in a secret manager (AWS Secrets Manager / Doppler
  / Vault) — **never commit them**.
- Run behind a TLS-terminating proxy (Fly.io / Cloudflare Tunnel) so the
  WSS upgrade works.
- Limit escrow balance to live race totals; sweep idle SOL to treasury daily.
- Treasury should move to a Squads multisig once revenue is real.
- Use Redis driver (Colyseus `RedisPresence` + `RedisDriver`) if scaling
  horizontally; otherwise leave `REDIS_URL` empty for single-process.

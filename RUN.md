# Quickstart in one screen

```bash
git clone <your-fork>/kartchain.git
cd kartchain
pnpm install
pnpm run keys:gen        # creates 4 custodial keypairs in server/
cp .env.example .env
cp .env.example server/.env
cp web/.env.example web/.env.local

# Terminal 1 — server (Colyseus + custodial Solana wallets)
pnpm dev:server

# Terminal 2 — build the Godot WASM bundle (run once; rebuild after edits)
pnpm build:client

# Terminal 3 — web host (Next.js)
pnpm dev:web
```

Open http://localhost:3000 → Connect a wallet → /race → join a free lobby
→ race.

See `docs/QUICKSTART.md` for fuller instructions, devnet funding, and
P2E SPL token creation.

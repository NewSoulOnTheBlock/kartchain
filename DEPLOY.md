# Deploying Kartchain

Two pieces, two hosts:

| Component | Host | Why |
|---|---|---|
| **Next.js web + Godot bundle** | Vercel | Static + edge serving, free tier handles our 115 MB game bundle fine |
| **Colyseus WebSocket server** | Render | Holds long-lived WS connections (Vercel functions can't); Docker-friendly; free tier exists |

Total cost: **$0** on free tiers (Render sleeps after 15 min idle; first request after sleep takes ~30 s to wake).

---

## 0. One-time prep

Push the repo to GitHub (private is fine — both Render and Vercel see private repos with their GitHub integration).

```bash
cd C:\Users\roota\kartchain
git init
git add -A
git commit -m "Initial Kartchain MVP"
gh repo create kartchain --private --source=. --push    # or via github.com UI
```

Generate the 4 custodial Solana keypairs locally if you haven't already:

```bash
pnpm run keys:gen
```

This writes `server/treasury.json`, `server/escrow.json`, `server/p2e-mint.json`, `server/nft-auth.json` (in `.gitignore` — they should never be committed).

Get each keypair's public key + raw JSON contents — you'll paste them into Render as secrets:

```powershell
# pubkey (so you can airdrop to it)
node -e "const k=require('@solana/web3.js').Keypair.fromSecretKey(Uint8Array.from(require('./server/treasury.json')));console.log(k.publicKey.toBase58())"

# full JSON byte array (the secret to paste into env)
Get-Content server/treasury.json
```

Airdrop ~2 SOL each to **treasury** and **escrow** on devnet (use https://faucet.solana.com).

---

## 1. Deploy the server to Render

1. Visit https://dashboard.render.com → **New +** → **Blueprint**
2. Connect your GitHub account, select the `kartchain` repo
3. Render reads `render.yaml` at the repo root, finds `services: [kartchain-server]`, and provisions a new web service
4. After the initial build kicks off, go to the service → **Environment** tab and add these secrets:

   | Key | Value |
   |---|---|
   | `TREASURY_KEYPAIR_JSON` | full contents of `server/treasury.json` (e.g. `[34,52,...,123]`) |
   | `ESCROW_KEYPAIR_JSON` | full contents of `server/escrow.json` |
   | `P2E_MINT_AUTHORITY_KEYPAIR_JSON` | full contents of `server/p2e-mint.json` |
   | `KART_NFT_AUTHORITY_KEYPAIR_JSON` | full contents of `server/nft-auth.json` (optional) |
   | `ADMIN_TOKEN` | any random string — used to authorize the admin NFT-mint endpoint |
   | `ALLOWED_ORIGINS` | leave empty for now — set after Vercel deploy |

5. Click **Manual Deploy → Deploy latest commit** to pick up the new env vars
6. Once the service shows **Live**, note its public URL — it'll look like `https://kartchain-server-XXXX.onrender.com`
7. Test:
   ```
   curl https://kartchain-server-XXXX.onrender.com/health
   # {"ok":true,"ts":...}
   ```

---

## 2. Deploy the web to Vercel

1. Visit https://vercel.com/new → **Import Git Repository** → pick `kartchain`
2. In the import screen:
   - **Root Directory:** `web`
   - **Framework Preset:** Next.js (auto-detected)
   - **Build Command / Install Command / Output Directory:** leave the defaults (or use the ones from `web/vercel.json`)
3. Add these **Environment Variables**:

   | Key | Value |
   |---|---|
   | `NEXT_PUBLIC_COLYSEUS_URL` | `wss://kartchain-server-XXXX.onrender.com` (note **wss**, not https) |
   | `NEXT_PUBLIC_SERVER_URL` | `https://kartchain-server-XXXX.onrender.com` |
   | `NEXT_PUBLIC_SOLANA_CLUSTER` | `devnet` |
   | `NEXT_PUBLIC_SOLANA_RPC_URL` | `https://api.devnet.solana.com` (or your Helius/Triton URL) |
   | `NEXT_PUBLIC_P2E_TOKEN_MINT` | the SPL mint address you created with `spl-token create-token`, or leave blank |

4. Click **Deploy**. First build takes 1-3 minutes.
5. Once deployed, note the production URL — it'll be `https://kartchain.vercel.app` or similar.

### Wire the two together

Now that you have the Vercel URL, go back to **Render → kartchain-server → Environment** and set:

| Key | Value |
|---|---|
| `ALLOWED_ORIGINS` | `https://kartchain.vercel.app,https://your-preview-url.vercel.app` |

Save and click **Manual Deploy** so it picks up the new origin. The server will reject WebSocket origin headers from anything else.

---

## 3. Play together

Send your friend `https://kartchain.vercel.app/race`. Both of you:

1. Connect a Phantom wallet on **Devnet** (Phantom → Settings → Developer Settings → Change Network → Devnet)
2. Pick the same lobby (`free-lighthouse`, `wager-0.01-sol`, etc.)
3. Pick a kart
4. The server matches you into the same 8-player race room
5. Drive

The free Render dyno sleeps after 15 minutes of no traffic; the **first** request after sleep takes 20-40 s to wake. If you and your friend both hit the lobby at the same time after a long gap, expect a delay. Upgrade to the Starter plan ($7/mo) for an always-on server.

---

## 4. Optional: faster + production-grade

| Need | Action |
|---|---|
| Faster server cold-start / no sleep | Render Starter plan ($7/mo) |
| Less devnet RPC throttling | Sign up for [Helius](https://www.helius.dev/) free tier → use their RPC URL |
| Always-fresh game bundle on edits | Vercel auto-deploys on `git push` |
| Custom domain | Vercel: settings → Domains. Render: settings → Custom Domain (HTTPS auto-provisioned) |
| Keypair rotation | Render env var → paste new JSON → Manual Deploy. Old keypair never leaves your machine. |
| Multisig treasury | Move treasury funds to a [Squads](https://squads.so/) multisig; keep `TREASURY_KEYPAIR_JSON` as a recovery option only |

---

## 5. Troubleshooting

**Vercel build fails with "module not found":** Vercel's pnpm doesn't always handle monorepos cleanly. The included `web/vercel.json` works around this by running install + build from the repo root. If you still get errors, set **Build Command** in Vercel UI to: `cd .. && pnpm install --frozen-lockfile && pnpm --filter @kartchain/web build`

**Render shows "build failed: Cannot find module @colyseus/core":** make sure `pnpm-lock.yaml` is committed. The Dockerfile uses `pnpm install --frozen-lockfile`.

**Browser console: "WebSocket connection failed":** the WS URL must use `wss://` (TLS) — Render's public URL is HTTPS-only. If you accidentally set `ws://...onrender.com` you'll see this.

**Browser console: "CORS blocked":** make sure `ALLOWED_ORIGINS` on Render includes the exact Vercel URL (no trailing slash).

**Kart never spawns / room never joins:** check Render logs (`Logs` tab in the dashboard). Common cause: a keypair env var is malformed JSON.

**"Game not built yet" placeholder shows on Vercel:** the Godot WASM bundle (`web/public/game/index.*`) must be committed to git BEFORE you deploy. Vercel doesn't run Godot. Build locally with `pnpm build:client` and commit the output.

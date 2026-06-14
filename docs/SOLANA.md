# Solana integration (custodial / server-side)

Kartchain has **no on-chain program**. All Solana interaction goes through
hot wallets held by the server. This is simpler to ship; the trade-off is
that players must trust the operator to settle correctly.

## Server-held keypairs

| Keypair | Activity | Purpose | Production handling |
|---|---|---|---|
| `treasury` | low | Accumulates protocol fees; long-term reserves | Multisig (Squads) |
| `escrow` | high | Holds entry fees during races; pays out winners | Hot wallet (HSM) |
| `p2eMint` | medium | Mint authority for the P2E SPL token | Hot wallet (HSM) |
| `nftAuth` | low | Mint authority for kart NFTs (Metaplex Core) | Hot wallet (HSM) |

All four are loaded by `server/src/solana/wallets.ts` from JSON keypair
files at the paths in `.env`. Generate them with:

```bash
pnpm run keys:gen     # creates the four .json files in server/
```

## Flows

### 1. Free race
```
Player → Colyseus.joinRace(raceId)
       ← RaceRoom accepts (no payment check)
[race plays]
Server → mintP2eRewards(player, amount)   # if P2E_TOKEN_MINT set
```

### 2. Paid race (entry fee)
```
Player → GET /api/escrow-address               (server: returns escrow pubkey)
Player → builds: SystemProgram.transfer(player→escrow, fee)
                + memo {k:"enter_race", raceId}
Player → wallet.signAndSendTx → tx signature
Player → Colyseus.joinRace(raceId, { entryTxSignature })
Server → verifyEntryTx(...)                    (fetches tx, checks payer/amount/memo)
         ↓ ok
       ← RaceRoom accepts player

[race plays]

Server → settleRace(...)                       (single tx batches all transfers)
         - escrow → treasury (5% fee)
         - escrow → 1st place (70%)
         - escrow → 2nd place (20%)
         - escrow → 3rd place (5%)
         + memo {k:"settle_race", raceId, ...}
Server → mintP2eRewards(...) per finisher
```

### 3. NFT kart mint
```
Admin → POST /api/admin/mint-kart
        Headers: x-admin-token: <ADMIN_TOKEN>
        Body: { recipient, name, metadataUri, attributes }
Server → mintKartNft(...)                      (Metaplex Core CPI from server)
       ← { assetAddress, signature }
```

(Stub today — wire `@metaplex-foundation/mpl-core` into `kartNft.ts` to
make it real. See the TODO block in that file.)

## Verification rules

`verifyEntryTx` checks:
1. Tx exists and didn't error.
2. Payer == `expectedWallet`.
3. `escrow` pubkey is an account in the tx, and its balance went up by
   at least `expectedLamports`.
4. A `Memo` log line contains `expectedRaceId`.

If any check fails the player is rejected from the room.

## P2E reward formula

`p2eRewardForPosition()` in `server/src/solana/p2e.ts`:

| Position | Tokens |
|---|---|
| 1st | 100 |
| 2nd | 60 |
| 3rd | 40 |
| 4th+ | 20 (participation) |

(Decimals = 9 by default — same as native SOL.) Tune freely; consider
adding race-quality multipliers, daily caps, or a Sybil filter before
mainnet.

## Memo schema

Every server-signed tx includes a memo for off-chain indexers:

```json
// Entry (sent by player)
{ "k": "enter_race", "raceId": "wager-0.1-sol" }

// Settlement (sent by server)
{ "k": "settle_race", "raceId": "wager-0.1-sol",
  "pool": "800000000", "fee": "40000000",
  "winners": ["abc...", "def...", "ghi..."],
  "splitBps": [7000, 2000, 500], "ts": 1717000000000 }

// P2E mint (sent by server)
{ "k": "p2e_mint", "raceId": "...", "player": "...", "amount": "...", "ts": ... }

// NFT mint (sent by server)
// (set by Metaplex Core; no custom memo needed)
```

## Custody risks (read before mainnet)

- Compromise of `escrow.json` lets attacker drain all live race pools.
  Limit balance to "current open races' total entry fees" — sweep idle
  funds to treasury daily.
- Compromise of `p2eMint.json` lets attacker mint unlimited P2E tokens.
  Mitigate by: per-day mint cap enforced in code, alerting on volume spikes,
  or by handing mint authority to a small Anchor program later.
- `treasury.json` should be cold-stored or behind a multisig as soon as
  there's real volume.

## Future: move to on-chain escrow

When trust becomes a bottleneck, the same client and Colyseus code can
keep working with an Anchor program in place of `escrow`. The migration is:
1. Deploy program with `init_race` / `enter_race` / `settle_race` ix.
2. Change `verifyEntryTx` to check program invocation instead of plain
   transfer.
3. Change `settleRace` to call the program (server-signer is the sole
   authority for the settle ix).

No client / Godot changes required.

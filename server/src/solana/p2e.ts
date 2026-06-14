import {
  PublicKey,
  Transaction,
} from "@solana/web3.js";
import {
  getAssociatedTokenAddressSync,
  createAssociatedTokenAccountIdempotentInstruction,
  createMintToInstruction,
  TOKEN_PROGRAM_ID,
  ASSOCIATED_TOKEN_PROGRAM_ID,
} from "@solana/spl-token";
import { conn } from "./rpc.js";
import { loadWallets } from "./wallets.js";
import { memoIx } from "./settle.js";

const P2E_TOKEN_MINT_STR = process.env.P2E_TOKEN_MINT ?? "";

/**
 * Mint P2E SPL token rewards to a player.
 *
 * Server is the mint authority. We:
 *   - derive the player's ATA
 *   - create the ATA if missing (idempotent ix)
 *   - mint_to(amount) signed by the p2eMint keypair
 *   - memo for indexers
 */
export async function mintP2eRewards(opts: {
  raceId: string;
  player: string;       // base58 pubkey
  amount: bigint;       // smallest units (respects mint decimals)
}): Promise<string> {
  if (!P2E_TOKEN_MINT_STR) {
    throw new Error("P2E_TOKEN_MINT env var is not set");
  }
  const { p2eMint, treasury } = loadWallets();
  const mint = new PublicKey(P2E_TOKEN_MINT_STR);
  const player = new PublicKey(opts.player);

  // Treasury pays for ATA rent (~0.002 SOL); p2eMint signs the mint authority.
  const playerAta = getAssociatedTokenAddressSync(mint, player);

  const tx = new Transaction();
  tx.add(
    createAssociatedTokenAccountIdempotentInstruction(
      treasury.publicKey,  // payer (rent)
      playerAta,
      player,
      mint,
      TOKEN_PROGRAM_ID,
      ASSOCIATED_TOKEN_PROGRAM_ID
    )
  );
  tx.add(
    createMintToInstruction(
      mint,
      playerAta,
      p2eMint.publicKey,
      opts.amount,
      [],
      TOKEN_PROGRAM_ID
    )
  );
  tx.add(memoIx({
    k: "p2e_mint",
    raceId: opts.raceId,
    player: opts.player,
    amount: opts.amount.toString(),
    ts: Date.now(),
  }));

  tx.feePayer = treasury.publicKey;
  const { blockhash } = await conn().getLatestBlockhash();
  tx.recentBlockhash = blockhash;
  tx.sign(treasury, p2eMint);

  const sig = await conn().sendRawTransaction(tx.serialize(), { skipPreflight: false });
  await conn().confirmTransaction(sig, "confirmed");
  console.log(`[p2e] minted ${opts.amount} to ${opts.player} (race ${opts.raceId}) tx=${sig}`);
  return sig;
}

/**
 * Calculate how many P2E tokens a player earned in a race.
 * Trivial baseline: linear by inverse finish position.
 *   1st  -> 100 tokens
 *   2nd  -> 60
 *   3rd  -> 40
 *   4th+ -> 20 (participation)
 */
export function p2eRewardForPosition(position: number, decimals = 9): bigint {
  const base = position === 1 ? 100n
              : position === 2 ? 60n
              : position === 3 ? 40n
              : 20n;
  return base * (10n ** BigInt(decimals));
}

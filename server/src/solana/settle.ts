import {
  PublicKey,
  SystemProgram,
  Transaction,
  TransactionInstruction,
} from "@solana/web3.js";
import { conn } from "./rpc.js";
import { loadWallets } from "./wallets.js";

const MEMO_PROGRAM_ID = new PublicKey("MemoSq4gqABAXKb96qnH8TysNcWxMyWCqXgDLGmfcHr");

export type SettleArgs = {
  raceId: string;
  /** Winner wallets in finish order. Length determines split slots used. */
  results: string[];
  /** Total amount in lamports collected for this race (entryFee * players). */
  poolLamports: bigint;
  /** Basis points per finish position (e.g. [7000, 2000, 500]). */
  prizeSplitBps: number[];
  /** Protocol fee in bps (e.g. 500 = 5%). */
  feeBps: number;
};

/**
 * Pay out a race pool from the escrow wallet.
 *
 * Logic:
 *   - feeAmount = pool * feeBps / 10_000  → goes to treasury
 *   - winners[i] receives pool * prizeSplitBps[i] / 10_000
 *   - all instructions batched into a single tx so it's atomic
 *
 * Returns the tx signature.
 */
export async function settleRace(args: SettleArgs): Promise<string> {
  const { escrow, treasury } = loadWallets();
  if (args.results.length === 0) throw new Error("no finishers to settle");
  if (args.poolLamports === 0n) {
    // Nothing to distribute — still write a memo for accounting
    return await sendMemoOnly(args);
  }

  const totalBps = args.feeBps + args.prizeSplitBps.reduce((a, b) => a + b, 0);
  if (totalBps > 10_000) {
    throw new Error(`split + fee > 10_000 bps (got ${totalBps})`);
  }

  const tx = new Transaction();
  let distributed = 0n;

  // Protocol fee
  const feeAmount = (args.poolLamports * BigInt(args.feeBps)) / 10_000n;
  if (feeAmount > 0n) {
    tx.add(
      SystemProgram.transfer({
        fromPubkey: escrow.publicKey,
        toPubkey: treasury.publicKey,
        lamports: Number(feeAmount),
      })
    );
    distributed += feeAmount;
  }

  // Winner payouts
  for (let i = 0; i < args.results.length && i < args.prizeSplitBps.length; i++) {
    const bps = args.prizeSplitBps[i];
    if (!bps) continue;
    const amount = (args.poolLamports * BigInt(bps)) / 10_000n;
    if (amount === 0n) continue;
    let winner: PublicKey;
    try { winner = new PublicKey(args.results[i]); }
    catch { console.warn(`[settle] bad winner pubkey ${args.results[i]} — skipping`); continue; }
    tx.add(
      SystemProgram.transfer({
        fromPubkey: escrow.publicKey,
        toPubkey: winner,
        lamports: Number(amount),
      })
    );
    distributed += amount;
  }

  // Refund remainder (if any) back to treasury to avoid escrow drift
  const remainder = args.poolLamports - distributed;
  if (remainder > 0n) {
    tx.add(
      SystemProgram.transfer({
        fromPubkey: escrow.publicKey,
        toPubkey: treasury.publicKey,
        lamports: Number(remainder),
      })
    );
  }

  // Memo for off-chain accounting / indexers
  tx.add(memoIx({
    k: "settle_race",
    raceId: args.raceId,
    pool: args.poolLamports.toString(),
    fee: feeAmount.toString(),
    winners: args.results,
    splitBps: args.prizeSplitBps,
    ts: Date.now(),
  }));

  return await signAndSend(tx, escrow);
}

async function sendMemoOnly(args: SettleArgs): Promise<string> {
  const { escrow } = loadWallets();
  const tx = new Transaction().add(memoIx({
    k: "settle_race_empty",
    raceId: args.raceId,
    results: args.results,
    ts: Date.now(),
  }));
  return await signAndSend(tx, escrow);
}

export function memoIx(payload: unknown): TransactionInstruction {
  return new TransactionInstruction({
    keys: [],
    programId: MEMO_PROGRAM_ID,
    data: Buffer.from(JSON.stringify(payload), "utf-8"),
  });
}

async function signAndSend(tx: Transaction, signer: { publicKey: PublicKey; secretKey: Uint8Array }) {
  tx.feePayer = signer.publicKey;
  const { blockhash } = await conn().getLatestBlockhash();
  tx.recentBlockhash = blockhash;
  tx.sign(signer as any);
  const sig = await conn().sendRawTransaction(tx.serialize(), {
    skipPreflight: false,
    maxRetries: 3,
  });
  await conn().confirmTransaction(sig, "confirmed");
  console.log(`[settle] tx=${sig}`);
  return sig;
}

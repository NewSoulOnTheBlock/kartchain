import { PublicKey } from "@solana/web3.js";
import { conn } from "./rpc.js";
import { loadWallets } from "./wallets.js";

export type VerifyEntryArgs = {
  signature: string;          // base58 tx signature
  expectedWallet: string;     // base58 payer pubkey
  expectedRaceId: string;     // string id, must appear in tx memo
  expectedLamports: bigint;   // required entry fee
};

/**
 * Verify a player's entry payment.
 *
 * Custodial flow:
 *   1. Player builds a tx with two instructions:
 *        a) SystemProgram.transfer(player -> escrow, entryFeeLamports)
 *        b) Memo: JSON.stringify({k:"enter_race", raceId})
 *   2. Player signs + sends. Returns tx signature to our server.
 *   3. Server (this function) fetches the tx and verifies:
 *        - payer matches expectedWallet
 *        - destination is OUR escrow wallet
 *        - amount >= expectedLamports
 *        - memo references the raceId
 *
 * Without this gate, clients could lie about paying.
 */
export async function verifyEntryTx(args: VerifyEntryArgs): Promise<boolean> {
  const escrow = loadWallets().escrow.publicKey;
  try {
    const tx = await conn().getTransaction(args.signature, {
      maxSupportedTransactionVersion: 0,
      commitment: "confirmed",
    });
    if (!tx || tx.meta?.err) {
      console.warn("[verify] tx not found or errored:", args.signature, tx?.meta?.err);
      return false;
    }
    const message = tx.transaction.message;
    const accountKeys: PublicKey[] = "staticAccountKeys" in message
      ? message.staticAccountKeys
      : ((message as any).accountKeys);

    // 1. Payer matches expected
    const payer = accountKeys[0];
    if (!payer.equals(new PublicKey(args.expectedWallet))) {
      console.warn(`[verify] payer mismatch: ${payer.toBase58()} != ${args.expectedWallet}`);
      return false;
    }

    // 2. Escrow received at least expectedLamports
    const escrowIndex = accountKeys.findIndex((k) => k.equals(escrow));
    if (escrowIndex < 0) {
      console.warn("[verify] escrow account not present in tx");
      return false;
    }
    const pre = tx.meta?.preBalances?.[escrowIndex] ?? 0;
    const post = tx.meta?.postBalances?.[escrowIndex] ?? 0;
    const received = BigInt(post - pre);
    if (received < args.expectedLamports) {
      console.warn(`[verify] escrow received ${received} < ${args.expectedLamports}`);
      return false;
    }

    // 3. Memo references the race id
    const logs = tx.meta?.logMessages ?? [];
    const memoMatched = logs.some((l) =>
      l.includes("Memo") && l.includes(args.expectedRaceId)
    );
    if (!memoMatched) {
      console.warn(`[verify] no memo log mentions raceId ${args.expectedRaceId}`);
      if (process.env.NODE_ENV === "production") return false;
    }

    return true;
  } catch (err) {
    console.error("[verify] error:", err);
    return false;
  }
}

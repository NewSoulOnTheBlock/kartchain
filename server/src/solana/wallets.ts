import { Keypair } from "@solana/web3.js";
import { readFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";

/**
 * Kartchain's four custodial hot wallets, controlled by this server.
 *
 * Each wallet supports two loading paths, in priority order:
 *   1. `<NAME>_KEYPAIR_JSON` env var — full 64-byte JSON array as a string.
 *      Example: TREASURY_KEYPAIR_JSON='[34,52,...,123]'
 *      Use this on Render/Vercel/Fly/etc. where there's no persistent disk.
 *   2. `<NAME>_KEYPAIR_PATH` env var — path to a Solana CLI keypair file.
 *      Defaults to ./<name>.json relative to cwd.
 *
 * Local dev: generate with `pnpm run keys:gen` (writes JSON files in ./server).
 * Production:
 *   cat server/treasury.json   → set TREASURY_KEYPAIR_JSON
 *   cat server/escrow.json     → set ESCROW_KEYPAIR_JSON
 *   cat server/p2e-mint.json   → set P2E_MINT_AUTHORITY_KEYPAIR_JSON
 *   cat server/nft-auth.json   → set KART_NFT_AUTHORITY_KEYPAIR_JSON (optional)
 *
 * Treasury should move to a Squads multisig before mainnet has real volume.
 */

export type Wallets = {
  treasury: Keypair;
  escrow: Keypair;
  p2eMint: Keypair;
  nftAuth: Keypair | null;
};

let _cache: Wallets | null = null;

export function loadWallets(): Wallets {
  if (_cache) return _cache;
  const treasury = loadKeypair("TREASURY",            "./treasury.json", true);
  const escrow   = loadKeypair("ESCROW",              "./escrow.json",   true);
  const p2eMint  = loadKeypair("P2E_MINT_AUTHORITY",  "./p2e-mint.json", true);
  let nftAuth: Keypair | null = null;
  try {
    nftAuth = loadKeypair("KART_NFT_AUTHORITY", "./nft-auth.json", false);
  } catch (err) {
    console.warn("[wallets] nftAuth not loaded (NFT mint disabled):", String(err));
  }
  console.log(`[wallets] treasury=${treasury.publicKey.toBase58()}`);
  console.log(`[wallets] escrow  =${escrow.publicKey.toBase58()}`);
  console.log(`[wallets] p2eMint =${p2eMint.publicKey.toBase58()}`);
  if (nftAuth) console.log(`[wallets] nftAuth =${nftAuth.publicKey.toBase58()}`);
  _cache = { treasury, escrow, p2eMint, nftAuth };
  return _cache;
}

export function escrowPubkey(): string {
  return loadWallets().escrow.publicKey.toBase58();
}

function loadKeypair(name: string, defaultPath: string, required: boolean): Keypair {
  // 1. Full JSON-array env var (production)
  const jsonEnv = process.env[`${name}_KEYPAIR_JSON`];
  if (jsonEnv) {
    try {
      const bytes = JSON.parse(jsonEnv);
      if (!Array.isArray(bytes) || bytes.length !== 64) {
        throw new Error("expected 64-byte JSON array");
      }
      return Keypair.fromSecretKey(Uint8Array.from(bytes));
    } catch (err) {
      throw new Error(`Bad ${name}_KEYPAIR_JSON: ${err}`);
    }
  }
  // 2. File path (dev)
  const path = process.env[`${name}_KEYPAIR_PATH`] ?? defaultPath;
  const absolute = resolve(process.cwd(), path);
  if (!existsSync(absolute)) {
    if (!required) throw new Error(`no keypair at ${absolute}`);
    throw new Error(
      `Could not find ${name} keypair. Either set ${name}_KEYPAIR_JSON ` +
      `(the full 64-byte JSON array as a string) or place a keypair file at ${absolute}. ` +
      `Generate one with: pnpm run keys:gen`
    );
  }
  const raw = readFileSync(absolute, "utf-8");
  const bytes = JSON.parse(raw);
  if (!Array.isArray(bytes) || bytes.length !== 64) {
    throw new Error(`Bad keypair format at ${absolute}; expected 64-byte JSON array`);
  }
  return Keypair.fromSecretKey(Uint8Array.from(bytes));
}

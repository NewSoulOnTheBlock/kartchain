#!/usr/bin/env node
// Generate the four custodial keypairs the server expects.
// Run from repo root with: pnpm run keys:gen
// Or directly from server/: node scripts/gen-keys.mjs
//
// Writes Solana CLI JSON keypair files (64-byte arrays) into ./ (i.e. server/).
// Pure-Node implementation so no Solana CLI install is required.
import { writeFileSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { Keypair } from "@solana/web3.js";

const targets = [
  { name: "treasury",  path: "./treasury.json" },
  { name: "escrow",    path: "./escrow.json" },
  { name: "p2eMint",   path: "./p2e-mint.json" },
  { name: "nftAuth",   path: "./nft-auth.json" },
];

let createdAny = false;
for (const t of targets) {
  const abs = resolve(process.cwd(), t.path);
  if (existsSync(abs)) {
    console.log(`SKIP ${t.name.padEnd(8)} (exists)  ${abs}`);
    continue;
  }
  const kp = Keypair.generate();
  writeFileSync(abs, JSON.stringify(Array.from(kp.secretKey)));
  console.log(`NEW  ${t.name.padEnd(8)} ${kp.publicKey.toBase58()}  ->  ${abs}`);
  createdAny = true;
}

if (createdAny) {
  console.log(`\nFund 'treasury' and 'escrow' on devnet:`);
  console.log(`  solana airdrop 2 <pubkey> --url devnet`);
  console.log(`\nThen create the P2E SPL token (decimals 9) with p2e-mint as authority:`);
  console.log(`  spl-token create-token --decimals 9 --mint-authority $(solana-keygen pubkey ./p2e-mint.json) --url devnet`);
  console.log(`  # paste the resulting mint into P2E_TOKEN_MINT in .env`);
}

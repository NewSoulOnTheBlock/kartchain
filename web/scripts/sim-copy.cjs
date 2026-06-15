#!/usr/bin/env node
/**
 * sim:copy — stage the deterministic kart_sim.wasm so Next.js serves it.
 *
 * Three cases, in priority order:
 *
 *   1. Freshly-built artifact exists at ../sim/target/.../kart_sim.wasm
 *      (developer ran `npm run sim:build`, or CI has the Rust toolchain
 *      and built it). Copy it over the committed one.
 *
 *   2. No fresh build, but a copy is already at public/sim/kart_sim.wasm
 *      (committed to git). Use it as-is. Vercel hits this path — its
 *      build image has no Rust toolchain, but the .wasm is tiny enough
 *      that we vendor it in the repo.
 *
 *   3. Neither exists. Fail loudly so the site doesn't deploy with a
 *      broken sim.
 */

const fs = require("node:fs");
const path = require("node:path");

const src = path.resolve(
  __dirname,
  "..",
  "..",
  "sim",
  "target",
  "wasm32-unknown-unknown",
  "release",
  "kart_sim.wasm",
);
const dst = path.resolve(__dirname, "..", "public", "sim", "kart_sim.wasm");

if (fs.existsSync(src)) {
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(src, dst);
  const bytes = fs.statSync(dst).size;
  console.log(`[sim:copy] copied freshly-built ${src} -> ${dst} (${bytes} bytes)`);
  process.exit(0);
}

if (fs.existsSync(dst)) {
  const bytes = fs.statSync(dst).size;
  console.log(`[sim:copy] no fresh build; using committed ${dst} (${bytes} bytes)`);
  process.exit(0);
}

console.error(
  `[sim:copy] kart_sim.wasm missing at BOTH locations:\n` +
  `  source: ${src}\n` +
  `  staged: ${dst}\n` +
  `Run 'npm run sim:build' (requires Rust + wasm32-unknown-unknown target) or commit the artifact.`,
);
process.exit(1);

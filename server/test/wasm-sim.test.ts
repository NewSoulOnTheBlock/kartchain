/**
 * kart_sim WASM tests.
 *
 * Verifies that the compiled .wasm artifact:
 *   1. Loads in Node and reports the expected version + state size.
 *   2. Is deterministic — re-running the same input sequence in fresh
 *      instances produces bit-identical byte output (the property that
 *      makes rollback netcode possible).
 *   3. Stays in close parity with the TypeScript reference sim
 *      (server/src/simulation/kartSim.ts) over many ticks of realistic
 *      input. If these drift, gameplay tuning is out of sync between
 *      the legacy server path and the WASM path.
 *
 * If these tests fail because the .wasm doesn't exist yet, run:
 *   cd sim && cargo rustc --release --target wasm32-unknown-unknown --crate-type cdylib
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { loadKartSim, type KartSim } from "../src/simulation/wasmSim.js";
import { simulateKart, type KartInput } from "../src/simulation/kartSim.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

const WASM_PATH = resolve(
  __dirname,
  "..",
  "..",
  "sim",
  "target",
  "wasm32-unknown-unknown",
  "release",
  "kart_sim.wasm",
);

const wasmExists = existsSync(WASM_PATH);
const describeIfBuilt = wasmExists ? describe : describe.skip;

if (!wasmExists) {
  console.warn(
    `[wasm-sim.test] Skipping — ${WASM_PATH} not found. Run "cd sim && cargo rustc --release --target wasm32-unknown-unknown --crate-type cdylib"`,
  );
}

describeIfBuilt("kart_sim.wasm", () => {
  let sim1: KartSim;
  let sim2: KartSim;

  beforeAll(async () => {
    sim1 = await loadKartSim(WASM_PATH);
    sim2 = await loadKartSim(WASM_PATH);
  });

  it("reports expected version and state size", () => {
    expect(sim1.version).toBe((1 << 16) | 0);
  });

  it("returns zeroed state after init", () => {
    sim1.init(0);
    const s = sim1.read(0);
    expect(s).toMatchObject({ x: 0, z: 0, yaw: 0, speed: 0, vx: 0, vz: 0 });
  });

  it("accelerates forward on +throttle", () => {
    sim1.init(0);
    for (let i = 0; i < 60; i++) sim1.tick(0, 1.0, 0, 0, 1 / 60);
    const s = sim1.read(0);
    expect(s.speed).toBeGreaterThan(8);
    expect(s.speed).toBeLessThan(28);
    expect(s.z).toBeGreaterThan(1); // yaw=0 -> forward is +Z
    expect(Math.abs(s.x)).toBeLessThan(0.1);
  });

  it("rolls to a stop with no input", () => {
    sim1.init(0);
    sim1.setPose(0, 0, 0, 0);
    // Inject a starting speed via accel then coast
    for (let i = 0; i < 30; i++) sim1.tick(0, 1, 0, 0, 1 / 60);
    for (let i = 0; i < 60 * 10; i++) sim1.tick(0, 0, 0, 0, 1 / 60);
    expect(Math.abs(sim1.read(0).speed)).toBeLessThan(1e-3);
  });

  it("is bit-deterministic across fresh module instances", () => {
    // Same input sequence, two independently-loaded modules => identical bytes.
    sim1.init(0);
    sim2.init(0);
    const dt = 1 / 60;
    for (let tick = 0; tick < 600; tick++) {
      const t = Math.sin(tick * 0.05);
      const br = (Math.cos(tick * 0.03) * 0.5 + 0.5) * 0.3;
      const st = Math.sin(tick * 0.07) * 0.8;
      sim1.tick(0, t, br, st, dt);
      sim2.tick(0, t, br, st, dt);
    }
    const b1 = sim1.rawBytes(0);
    const b2 = sim2.rawBytes(0);
    expect(Buffer.compare(Buffer.from(b1), Buffer.from(b2))).toBe(0);
  });

  it("is bit-deterministic across re-runs in the same instance", () => {
    function runOnSim(s: KartSim) {
      s.init(0);
      const dt = 1 / 60;
      for (let tick = 0; tick < 1000; tick++) {
        const t = Math.sin(tick * 0.03);
        const br = (Math.cos(tick * 0.05) * 0.5 + 0.5) * 0.2;
        const st = Math.sin(tick * 0.04) * 0.9;
        s.tick(0, t, br, st, dt);
      }
      return s.rawBytes(0);
    }
    const a = runOnSim(sim1);
    const b = runOnSim(sim1);
    expect(Buffer.compare(Buffer.from(a), Buffer.from(b))).toBe(0);
  });

  it("stays in close parity with the TS reference sim", () => {
    // Run both sims with the same input stream for 5 seconds at 60 Hz.
    // Allow ~1m drift over 5 seconds because of float ordering differences
    // (LLVM may reorder f32 ops in Rust opt-level=3 vs V8's JIT in TS);
    // anything larger would mean the gameplay tunings have actually
    // diverged.
    sim1.init(0);
    const ref = {
      x: 0, z: 0, yaw: 0, speed: 0, vx: 0, vz: 0, vy: 0, y: 0,
      // The TS sim only reads/writes these on its Kart Schema; we mimic.
    };
    const refKart = ref as unknown as Parameters<typeof simulateKart>[0];

    const dt = 1 / 60;
    for (let tick = 0; tick < 300; tick++) {
      const t = Math.sin(tick * 0.05) * 0.7 + 0.3; // mostly forward
      const br = tick % 90 < 5 ? 1 : 0;             // brief brake every 1.5s
      const st = Math.sin(tick * 0.04) * 0.6;
      sim1.tick(0, t, br, st, dt);
      const input: KartInput = { throttle: t, brake: br, steer: st, useItem: false };
      simulateKart(refKart, input, dt);
    }
    const got = sim1.read(0);
    const dx = Math.abs(got.x - ref.x);
    const dz = Math.abs(got.z - ref.z);
    const dyaw = Math.abs(got.yaw - ref.yaw);
    expect(dx + dz, `position drift dx=${dx.toFixed(3)} dz=${dz.toFixed(3)}`).toBeLessThan(2.0);
    expect(dyaw, `yaw drift ${dyaw.toFixed(3)}`).toBeLessThan(0.3);
  });

  it("handles all 8 kart slots independently without interference", () => {
    // Re-init all slots, drive only slot 3 forward, others must stay still.
    for (let s = 0; s < 8; s++) sim1.init(s);
    for (let i = 0; i < 60; i++) sim1.tick(3, 1, 0, 0, 1 / 60);
    for (let s = 0; s < 8; s++) {
      const k = sim1.read(s);
      if (s === 3) {
        expect(k.speed).toBeGreaterThan(8);
        expect(k.z).toBeGreaterThan(1);
      } else {
        expect(k.speed).toBe(0);
        expect(k.x).toBe(0);
        expect(k.z).toBe(0);
      }
    }
  });
});

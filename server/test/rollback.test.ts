/**
 * Rollback algorithm tests.
 *
 * The PvP client-side prediction loop (see client/scripts/Kart.gd
 * apply_server_state) is:
 *
 *   1. Drop input-log entries with seq <= server.lastInputSeq.
 *   2. Reset WASM to server-reported pose.
 *   3. Replay every remaining log entry through WASM.
 *   4. Use the resulting WASM pose as the new "current".
 *
 * Because the .wasm is deterministic, these tests exercise the algorithm
 * using the SAME wasmSim loader the server uses. If they pass here, the
 * GDScript implementation (which calls into the same .wasm via the JS
 * bridge) is functionally equivalent — any divergence between client and
 * server would have to come from outside the sim.
 */

import { describe, it, expect, beforeAll } from "vitest";
import { existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { loadKartSim, type KartSim } from "../src/simulation/wasmSim.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const WASM_PATH = resolve(__dirname, "..", "..", "sim", "target", "wasm32-unknown-unknown", "release", "kart_sim.wasm");
const describeIfBuilt = existsSync(WASM_PATH) ? describe : describe.skip;

type InputLogEntry = {
  seq: number;
  throttle: number;
  brake: number;
  steer: number;
  dt: number;
};

/**
 * Mirrors Kart.gd apply_server_state — useful both as a reference impl
 * and to actually exercise the rollback algorithm via the same .wasm.
 */
function applyServerState(
  sim: KartSim,
  slot: number,
  log: InputLogEntry[],
  serverX: number,
  serverZ: number,
  serverYaw: number,
  serverSpeed: number,
  serverVx: number,
  serverVz: number,
  lastInputSeq: number,
): InputLogEntry[] {
  // 1. Drop acked entries.
  const remaining = log.filter((e) => e.seq > lastInputSeq);
  // 2. Reset WASM to server FULL state (pose + velocity).
  sim.setState(slot, serverX, serverZ, serverYaw, serverSpeed, serverVx, serverVz);
  // 3. Replay still-in-flight inputs.
  for (const e of remaining) {
    sim.tick(slot, e.throttle, e.brake, e.steer, e.dt);
  }
  return remaining;
}

describeIfBuilt("rollback algorithm", () => {
  let sim: KartSim;

  beforeAll(async () => {
    sim = await loadKartSim(WASM_PATH);
  });

  it("perfect-network case: reconciliation is a no-op", () => {
    // Client and server process the same inputs in lockstep. Reconciling
    // should leave the client exactly where it already was.
    sim.initSlot(0);  // client
    sim.initSlot(1);  // server (simulated by ticking in parallel)
    const log: InputLogEntry[] = [];
    const dt = 1 / 60;
    for (let i = 1; i <= 60; i++) {
      const throttle = 1, brake = 0, steer = Math.sin(i * 0.05) * 0.5;
      sim.tick(0, throttle, brake, steer, dt);
      sim.tick(1, throttle, brake, steer, dt);
      log.push({ seq: i, throttle, brake, steer, dt });
    }
    const clientBefore = sim.rawBytes(0);
    const server = sim.read(1);
    // Server has processed every input — lastInputSeq = 60.
    applyServerState(sim, 0, log, server.x, server.z, server.yaw, server.speed, server.vx, server.vz, 60);
    const clientAfter = sim.rawBytes(0);
    expect(Buffer.compare(Buffer.from(clientBefore), Buffer.from(clientAfter))).toBe(0);
  });

  it("trims acked entries and replays only in-flight ones", () => {
    // Client is 5 inputs ahead of server. Reconciling should leave the
    // client in the same pose as if no reconciliation happened (because
    // the sim is deterministic + same inputs).
    sim.initSlot(0);
    sim.initSlot(1);
    const log: InputLogEntry[] = [];
    const dt = 1 / 60;
    // Inputs 1..55 — both client and server processed
    for (let i = 1; i <= 55; i++) {
      const throttle = 1, brake = 0, steer = i % 30 < 15 ? 0.4 : -0.4;
      sim.tick(0, throttle, brake, steer, dt);
      sim.tick(1, throttle, brake, steer, dt);
      log.push({ seq: i, throttle, brake, steer, dt });
    }
    // Inputs 56..60 — only client processed (still in flight)
    for (let i = 56; i <= 60; i++) {
      const throttle = 1, brake = 0, steer = 0.6;
      sim.tick(0, throttle, brake, steer, dt);
      log.push({ seq: i, throttle, brake, steer, dt });
    }
    const before = sim.rawBytes(0);
    const server = sim.read(1);
    const remaining = applyServerState(sim, 0, log, server.x, server.z, server.yaw, server.speed, server.vx, server.vz, 55);
    const after = sim.rawBytes(0);
    expect(remaining.length).toBe(5);
    expect(remaining.map((e) => e.seq)).toEqual([56, 57, 58, 59, 60]);
    expect(Buffer.compare(Buffer.from(before), Buffer.from(after))).toBe(0);
  });

  it("packet-loss case: client diverges, reconciliation heals invisibly", () => {
    // Client thinks input 30 was processed; server actually dropped it.
    // Replaying log entries 31..40 over the server's (correct, no-30) pose
    // gives the client a different pose — which is the *right* answer.
    sim.initSlot(0); // client
    sim.initSlot(1); // server
    const log: InputLogEntry[] = [];
    const dt = 1 / 60;
    for (let i = 1; i <= 40; i++) {
      const throttle = 1, brake = 0, steer = i === 30 ? 1.0 : 0.0;
      sim.tick(0, throttle, brake, steer, dt);
      // Server "drops" input 30 entirely (didn't receive it, didn't process).
      if (i !== 30) {
        sim.tick(1, throttle, brake, steer, dt);
      }
      log.push({ seq: i, throttle, brake, steer, dt });
    }
    const server = sim.read(1);
    applyServerState(sim, 0, log, server.x, server.z, server.yaw, server.speed, server.vx, server.vz, 40);
    const after = sim.read(0);
    // The corrected pose should match a fresh sim that never received #30.
    sim.initSlot(2);
    for (let i = 1; i <= 40; i++) {
      if (i === 30) continue;
      const throttle = 1, brake = 0, steer = 0;
      sim.tick(2, throttle, brake, steer, dt);
    }
    const expected = sim.read(2);
    expect(after.x).toBeCloseTo(expected.x, 4);
    expect(after.z).toBeCloseTo(expected.z, 4);
    expect(after.yaw).toBeCloseTo(expected.yaw, 4);
  });

  it("empty input log: just resets to server pose", () => {
    sim.initSlot(0);
    sim.setPose(0, 99, 99, 0.5);
    const remaining = applyServerState(sim, 0, [], 42, -17, 1.2, 0, 0, 0, 0);
    const s = sim.read(0);
    expect(remaining.length).toBe(0);
    expect(s.x).toBeCloseTo(42, 4);
    expect(s.z).toBeCloseTo(-17, 4);
    expect(s.yaw).toBeCloseTo(1.2, 4);
  });

  it("reconciliation is idempotent under repeated calls", () => {
    // Calling apply_server_state twice with the same server pose +
    // lastInputSeq must produce the same final pose.
    sim.initSlot(0);
    sim.initSlot(1);
    const log: InputLogEntry[] = [];
    const dt = 1 / 60;
    for (let i = 1; i <= 30; i++) {
      const throttle = 0.8, brake = 0, steer = i % 10 < 5 ? 0.3 : -0.3;
      sim.tick(0, throttle, brake, steer, dt);
      if (i <= 25) sim.tick(1, throttle, brake, steer, dt);
      log.push({ seq: i, throttle, brake, steer, dt });
    }
    const server = sim.read(1);
    applyServerState(sim, 0, log, server.x, server.z, server.yaw, server.speed, server.vx, server.vz, 25);
    const after1 = sim.rawBytes(0);
    // Same log (minus the 25 acked ones), same server pose — should be
    // a no-op the second time.
    const log2 = log.filter((e) => e.seq > 25);
    applyServerState(sim, 0, log2, server.x, server.z, server.yaw, server.speed, server.vx, server.vz, 25);
    const after2 = sim.rawBytes(0);
    expect(Buffer.compare(Buffer.from(after1), Buffer.from(after2))).toBe(0);
  });
});

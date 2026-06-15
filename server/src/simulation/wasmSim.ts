/**
 * Loader for the kart_sim Rust→WASM module.
 *
 * The .wasm artifact (sim/target/wasm32-unknown-unknown/release/kart_sim.wasm)
 * is loaded with raw `WebAssembly.instantiate` — no wasm-bindgen, no glue,
 * no allocator. The module exports a small C-ABI surface:
 *
 *   kart_init(state_ptr: i32)                  -> void
 *   kart_set_pose(state_ptr: i32, x: f32, z: f32, yaw: f32) -> void
 *   kart_tick(state_ptr: i32, throttle: f32, brake: f32, steer: f32, dt: f32) -> void
 *   kart_state_size() -> i32   (returns 32)
 *   kart_sim_version() -> i32  (major<<16 | minor)
 *
 * Kart state in linear memory is a packed 8×f32 struct:
 *   offset 0:  x
 *   offset 4:  z
 *   offset 8:  yaw
 *   offset 12: speed
 *   offset 16: vx
 *   offset 20: vz
 *   offset 24: _r0 (reserved)
 *   offset 28: _r1 (reserved)
 *
 * We pool kart states starting at `KART_BASE_OFFSET` (a high address that
 * is safely past the WASM module's own static data — see comment below).
 */

import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

export const KART_STATE_SIZE = 32;

/**
 * We place kart states at offset 64KB. The kart_sim .wasm is ~6KB and uses
 * ~1 page (64KB) of linear memory total, with its static data living near
 * the bottom. 64KB is a safe upper bound (a full WASM page) past which the
 * module touches nothing. If `kart_sim.wasm` ever grows past ~50KB of static
 * data, bump this and the runtime assertion in `loadKartSim` will catch it.
 */
export const KART_BASE_OFFSET = 64 * 1024;

export const KART_SIM_EXPECTED_VERSION = (1 << 16) | 0;

export type KartView = {
  x: number; z: number; yaw: number; speed: number;
  vx: number; vz: number;
};

export interface KartSim {
  /** Reset kart `slot` to zeros. */
  init(slot: number): void;
  /** Set kart `slot` pose; velocities zeroed. */
  setPose(slot: number, x: number, z: number, yaw: number): void;
  /** Advance kart `slot` one tick. Inputs are clamped inside the sim. */
  tick(
    slot: number,
    throttle: number,
    brake: number,
    steer: number,
    dt: number,
  ): void;
  /** Read kart `slot` state as plain object. */
  read(slot: number): KartView;
  /** Raw 8×f32 bytes of kart `slot` — for bit-exact comparisons. */
  rawBytes(slot: number): Uint8Array;
  /** Module version reported by `kart_sim_version`. */
  version: number;
}

type WasmExports = {
  memory: WebAssembly.Memory;
  kart_init: (ptr: number) => void;
  kart_set_pose: (ptr: number, x: number, z: number, yaw: number) => void;
  kart_tick: (
    ptr: number, throttle: number, brake: number, steer: number, dt: number,
  ) => void;
  kart_state_size: () => number;
  kart_sim_version: () => number;
};

/**
 * Locate the .wasm file. In dev / from cargo build, the artifact lives at
 * `../../sim/target/wasm32-unknown-unknown/release/kart_sim.wasm`. CI/prod
 * should call `pnpm sim:build` (or `cargo rustc --target ...`) so the file
 * is in place before the server starts.
 *
 * Override with the `KART_SIM_WASM_PATH` env var if the artifact lives
 * somewhere else in your deployment (e.g. copied next to the JS bundle).
 */
function defaultWasmPath(): string {
  if (process.env.KART_SIM_WASM_PATH) {
    return process.env.KART_SIM_WASM_PATH;
  }
  return resolve(
    __dirname,
    "..",
    "..",
    "..",
    "sim",
    "target",
    "wasm32-unknown-unknown",
    "release",
    "kart_sim.wasm",
  );
}

/**
 * Compile the .wasm exactly once per Node process. Each call to
 * `loadKartSim` then instantiates a FRESH module (with its own linear
 * memory) from this cached compilation — fast (compile cost amortized)
 * and isolated (different rooms can't see each other's kart state).
 */
let cachedModule: Promise<WebAssembly.Module> | null = null;
async function getModule(path: string): Promise<WebAssembly.Module> {
  if (cachedModule) return cachedModule;
  cachedModule = (async () => {
    const bytes = await readFile(path);
    return WebAssembly.compile(bytes);
  })();
  return cachedModule;
}

export async function loadKartSim(wasmPath?: string): Promise<KartSim> {
  const path = wasmPath ?? defaultWasmPath();
  const mod = await getModule(path);
  const instance = await WebAssembly.instantiate(mod, {});
  const exp = instance.exports as unknown as WasmExports;

  const reported = exp.kart_state_size();
  if (reported !== KART_STATE_SIZE) {
    throw new Error(
      `kart_sim.wasm reports state size ${reported}, expected ${KART_STATE_SIZE}`,
    );
  }
  const version = exp.kart_sim_version();
  if (version !== KART_SIM_EXPECTED_VERSION) {
    throw new Error(
      `kart_sim.wasm version 0x${version.toString(16)} != expected 0x${KART_SIM_EXPECTED_VERSION.toString(16)}`,
    );
  }

  function ptr(slot: number): number {
    return KART_BASE_OFFSET + slot * KART_STATE_SIZE;
  }

  function viewF32(slot: number): Float32Array {
    return new Float32Array(exp.memory.buffer, ptr(slot), 8);
  }

  return {
    version,
    init(slot) { exp.kart_init(ptr(slot)); },
    setPose(slot, x, z, yaw) { exp.kart_set_pose(ptr(slot), x, z, yaw); },
    tick(slot, throttle, brake, steer, dt) {
      exp.kart_tick(ptr(slot), throttle, brake, steer, dt);
    },
    read(slot) {
      const f = viewF32(slot);
      return { x: f[0], z: f[1], yaw: f[2], speed: f[3], vx: f[4], vz: f[5] };
    },
    rawBytes(slot) {
      return new Uint8Array(
        exp.memory.buffer.slice(ptr(slot), ptr(slot) + KART_STATE_SIZE),
      );
    },
  };
}

/**
 * For tests: reset the module cache so `loadKartSim()` re-reads the .wasm
 * file from disk on next call. Useful when iterating on the Rust code
 * inside a single vitest watch session.
 */
export function _resetKartSimCache(): void {
  cachedModule = null;
}

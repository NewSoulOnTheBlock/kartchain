/**
 * sim-bridge — loads the deterministic kart_sim.wasm in the browser and
 * exposes a small TS API. Mounted on window.kartchain.sim by KartchainBridge
 * so Godot/GDScript can call it via JavaScriptBridge.
 *
 * The .wasm is built from the `sim/` Rust crate at the repo root and copied
 * to /public/sim/kart_sim.wasm by the build pipeline (see web/package.json
 * sim:copy script or root build).
 *
 * The same .wasm runs on the Node.js server (see server/src/simulation/
 * wasmSim.ts). Bit-exact f32 ops on both sides => deterministic prediction
 * + rollback netcode + input-log replay verification.
 */

const WASM_URL = "/sim/kart_sim.wasm";
export const KART_STATE_SIZE = 32;
export const KART_BASE_OFFSET = 64 * 1024;
export const KART_SIM_EXPECTED_VERSION = (1 << 16) | 0;

export type KartView = {
  x: number; z: number; yaw: number; speed: number;
  vx: number; vz: number;
};

export interface SimBridge {
  /** Fetch + compile + instantiate the .wasm. Idempotent. */
  init(): Promise<{ ready: true; version: number }>;
  /** True after init() resolves successfully. */
  isReady(): boolean;
  /** Reset kart slot to zeros. */
  initSlot(slot: number): void;
  /** Set kart slot pose (x, z, yaw); velocities zeroed. */
  setPose(slot: number, x: number, z: number, yaw: number): void;
  /** Advance kart slot one tick. Inputs are clamped inside the sim. */
  tick(
    slot: number,
    throttle: number, brake: number, steer: number,
    dt: number,
  ): KartView;
  /** Read kart slot state without ticking. */
  read(slot: number): KartView;
  /** Encode kart slot state as a 32-byte hex string (for input-log uploads). */
  readHex(slot: number): string;
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

let _initPromise: Promise<{ ready: true; version: number }> | null = null;
let _exports: WasmExports | null = null;

function ptr(slot: number): number {
  return KART_BASE_OFFSET + slot * KART_STATE_SIZE;
}

function viewF32(slot: number): Float32Array {
  if (!_exports) throw new Error("sim not initialized — call sim.init() first");
  return new Float32Array(_exports.memory.buffer, ptr(slot), 8);
}

async function compileAndInstantiate(): Promise<WasmExports> {
  // streaming when the browser/server cooperates; raw fetch as fallback for
  // dev setups whose Content-Type for .wasm is wrong.
  let instance: WebAssembly.Instance;
  try {
    const r = await WebAssembly.instantiateStreaming(fetch(WASM_URL), {});
    instance = r.instance;
  } catch {
    const resp = await fetch(WASM_URL);
    if (!resp.ok) throw new Error(`kart_sim.wasm fetch failed (${resp.status})`);
    const bytes = await resp.arrayBuffer();
    const r = await WebAssembly.instantiate(bytes, {});
    instance = r.instance;
  }
  const exp = instance.exports as unknown as WasmExports;
  const size = exp.kart_state_size();
  if (size !== KART_STATE_SIZE) {
    throw new Error(`kart_sim.wasm state size ${size} != expected ${KART_STATE_SIZE}`);
  }
  const ver = exp.kart_sim_version();
  if (ver !== KART_SIM_EXPECTED_VERSION) {
    throw new Error(`kart_sim.wasm version 0x${ver.toString(16)} != expected`);
  }
  return exp;
}

export function makeSimBridge(): SimBridge {
  return {
    async init() {
      if (_initPromise) return _initPromise;
      _initPromise = (async () => {
        _exports = await compileAndInstantiate();
        // eslint-disable-next-line no-console
        console.log(`[sim] kart_sim.wasm loaded (v0x${_exports.kart_sim_version().toString(16)})`);
        return { ready: true, version: _exports.kart_sim_version() } as const;
      })().catch((err) => {
        _initPromise = null;
        _exports = null;
        throw err;
      });
      return _initPromise;
    },
    isReady() {
      return _exports !== null;
    },
    initSlot(slot) {
      if (!_exports) return;
      _exports.kart_init(ptr(slot));
    },
    setPose(slot, x, z, yaw) {
      if (!_exports) return;
      _exports.kart_set_pose(ptr(slot), x, z, yaw);
    },
    tick(slot, throttle, brake, steer, dt) {
      if (!_exports) {
        // Defensive: GDScript may call before init resolved. Return zeros
        // so the caller doesn't crash; visual will just stay put for that
        // frame.
        return { x: 0, z: 0, yaw: 0, speed: 0, vx: 0, vz: 0 };
      }
      _exports.kart_tick(ptr(slot), throttle, brake, steer, dt);
      const f = viewF32(slot);
      return { x: f[0], z: f[1], yaw: f[2], speed: f[3], vx: f[4], vz: f[5] };
    },
    read(slot) {
      if (!_exports) return { x: 0, z: 0, yaw: 0, speed: 0, vx: 0, vz: 0 };
      const f = viewF32(slot);
      return { x: f[0], z: f[1], yaw: f[2], speed: f[3], vx: f[4], vz: f[5] };
    },
    readHex(slot) {
      if (!_exports) return "00".repeat(KART_STATE_SIZE);
      const u8 = new Uint8Array(
        _exports.memory.buffer.slice(ptr(slot), ptr(slot) + KART_STATE_SIZE),
      );
      let out = "";
      for (let i = 0; i < u8.length; i++) {
        out += u8[i].toString(16).padStart(2, "0");
      }
      return out;
    },
  };
}

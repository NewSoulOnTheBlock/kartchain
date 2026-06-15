//! kart_sim — deterministic kart physics shared between server and client.
//!
//! ## Wire ABI
//!
//! Every function exposed here uses `extern "C"` and primitive types only
//! (`f32`, `u32`, pointers) so callers can use raw `WebAssembly.instantiate`
//! with no JS glue, no wasm-bindgen, no allocator.
//!
//! Kart state is laid out as 8 packed `f32` (= 32 bytes), exposed to callers
//! through a pre-allocated buffer in WASM linear memory. The caller writes
//! the buffer once at spawn time, then calls `kart_tick` each frame; the
//! buffer is mutated in place.
//!
//! See `KartState` for the field layout.
//!
//! ## Determinism guarantees
//!
//! - All math uses `libm` (pure Rust) so there are no host-imported transcendentals.
//! - Every operation is IEEE-754 f32, which is deterministic in WebAssembly
//!   per the spec (https://webassembly.github.io/spec/core/exec/numerics.html).
//! - No global state, no allocator, no `std`. Each call is a pure function
//!   over the input buffer.
//! - Input clamping happens INSIDE the sim, so callers cannot induce
//!   divergence by passing out-of-range values.

#![cfg_attr(target_arch = "wasm32", no_std)]
#![allow(clippy::missing_safety_doc)]

// Panic handler only needed for the no_std WASM build. Native test builds
// use std and would conflict with this.
#[cfg(target_arch = "wasm32")]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}

mod math;

/// Layout of a single kart's state in WASM linear memory.
/// Total size: 32 bytes (8 × f32).
///
/// Field order is FIXED and must match server/client de/serialization.
#[repr(C)]
pub struct KartState {
    pub x: f32,
    pub z: f32,
    pub yaw: f32,
    pub speed: f32,
    pub vx: f32,
    pub vz: f32,
    /// Reserved for future use (e.g. boost charge); always zero today.
    pub _r0: f32,
    /// Reserved for future use; always zero today.
    pub _r1: f32,
}

// ─── Tuning constants ────────────────────────────────────────────────
// MUST MATCH server/src/simulation/kartSim.ts. Any change here that isn't
// mirrored there (and vice versa) breaks the parity test.
const MAX_SPEED: f32 = 42.0;
const ACCELERATION: f32 = 28.0;
const REVERSE_ACCELERATION: f32 = 10.0;
const BRAKE_DECEL: f32 = 40.0;
const FRICTION: f32 = 2.5;
const YAW_RATE_AT_SPEED: f32 = 2.4;
const STEER_SPEED_SCALE: f32 = 0.35;
const REVERSE_SPEED_CAP_FACTOR: f32 = 0.4;
const STEER_DEADZONE: f32 = 0.1;
const TAU: f32 = 2.0 * core::f32::consts::PI;

// ─── Public C-ABI ────────────────────────────────────────────────────

/// Initialize a freshly-allocated kart state buffer to all zeros.
/// Caller is responsible for the lifetime of `state`.
#[no_mangle]
pub unsafe extern "C" fn kart_init(state: *mut KartState) {
    if state.is_null() {
        return;
    }
    *state = KartState {
        x: 0.0, z: 0.0, yaw: 0.0, speed: 0.0,
        vx: 0.0, vz: 0.0, _r0: 0.0, _r1: 0.0,
    };
}

/// Set the kart's spawn pose. Velocities are zeroed.
#[no_mangle]
pub unsafe extern "C" fn kart_set_pose(
    state: *mut KartState,
    x: f32, z: f32, yaw: f32,
) {
    if state.is_null() {
        return;
    }
    (*state).x = x;
    (*state).z = z;
    (*state).yaw = wrap_pi(yaw);
    (*state).speed = 0.0;
    (*state).vx = 0.0;
    (*state).vz = 0.0;
}

/// Set the kart's full state — position + heading + velocity. Used by
/// PvP reconciliation to rewind the client's WASM to the server's
/// authoritative state including velocity (so replay of still-in-flight
/// inputs produces the correct trajectory).
#[no_mangle]
pub unsafe extern "C" fn kart_set_state(
    state: *mut KartState,
    x: f32, z: f32, yaw: f32,
    speed: f32, vx: f32, vz: f32,
) {
    if state.is_null() {
        return;
    }
    (*state).x = x;
    (*state).z = z;
    (*state).yaw = wrap_pi(yaw);
    (*state).speed = speed;
    (*state).vx = vx;
    (*state).vz = vz;
}

/// Advance the kart's physics by one tick.
///
/// Inputs are clamped to safe ranges inside this function — callers may
/// pass anything without inducing divergence.
///
/// `dt` is in seconds. Typical values: 1/60 = 0.01666… or 1/30 = 0.0333…
#[no_mangle]
pub unsafe extern "C" fn kart_tick(
    state: *mut KartState,
    throttle: f32, brake: f32, steer: f32,
    dt: f32,
) {
    if state.is_null() {
        return;
    }
    tick_impl(&mut *state, throttle, brake, steer, dt);
}

/// Pure-Rust version of the tick — used by `kart_tick` (which adds the
/// FFI safety wrapper) and by the internal test harness.
#[inline]
pub fn tick_impl(
    s: &mut KartState,
    throttle_raw: f32, brake_raw: f32, steer_raw: f32,
    dt: f32,
) {
    let throttle = math::clamp(throttle_raw, -1.0, 1.0);
    let brake = math::clamp(brake_raw, 0.0, 1.0);
    let steer = math::clamp(steer_raw, -1.0, 1.0);

    // Engine — forward acceleration is stronger than reverse, matches kartSim.ts.
    if throttle > 0.0 {
        s.speed += ACCELERATION * throttle * dt;
    } else if throttle < 0.0 {
        s.speed += REVERSE_ACCELERATION * throttle * dt;
    }

    // Brake — bleeds speed toward zero regardless of direction.
    if brake > 0.0 {
        if s.speed > 0.0 {
            s.speed = math::max(0.0, s.speed - BRAKE_DECEL * brake * dt);
        } else if s.speed < 0.0 {
            s.speed = math::min(0.0, s.speed + BRAKE_DECEL * brake * dt);
        }
    }

    // Passive rolling friction.
    if s.speed > 0.0 {
        s.speed = math::max(0.0, s.speed - FRICTION * dt);
    } else if s.speed < 0.0 {
        s.speed = math::min(0.0, s.speed + FRICTION * dt);
    }
    s.speed = math::clamp(s.speed, -MAX_SPEED * REVERSE_SPEED_CAP_FACTOR, MAX_SPEED);

    // Steering authority drops with speed.
    let speed_factor = 1.0 - (math::abs(s.speed) / MAX_SPEED) * STEER_SPEED_SCALE;
    let moving = if math::abs(s.speed) > STEER_DEADZONE { 1.0 } else { 0.0 };
    let yaw_delta = steer * YAW_RATE_AT_SPEED * speed_factor * moving * dt;
    s.yaw += yaw_delta * math::sign(s.speed);

    // Integrate position using current heading.
    let forward_x = math::sin(s.yaw);
    let forward_z = math::cos(s.yaw);
    s.vx = forward_x * s.speed;
    s.vz = forward_z * s.speed;
    s.x += s.vx * dt;
    s.z += s.vz * dt;

    s.yaw = wrap_pi(s.yaw);
}

#[inline]
fn wrap_pi(mut y: f32) -> f32 {
    while y > core::f32::consts::PI {
        y -= TAU;
    }
    while y < -core::f32::consts::PI {
        y += TAU;
    }
    y
}

// ─── Build-time self-check ───────────────────────────────────────────

/// Returns the size of `KartState` in bytes — used by callers to verify
/// their layout matches.
#[no_mangle]
pub extern "C" fn kart_state_size() -> u32 {
    core::mem::size_of::<KartState>() as u32
}

/// Major.minor version so callers can refuse to load mismatched .wasm files.
#[no_mangle]
pub extern "C" fn kart_sim_version() -> u32 {
    (1 << 16) | 0
}

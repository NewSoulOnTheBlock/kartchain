//! Determinism + parity tests for kart_sim.
//!
//! These are real `cargo test` integration tests that run NATIVELY on the
//! host (x86_64). They cover:
//!
//! - **Determinism on host**: same inputs => same f32 bytes, every time.
//!   A passing host test is necessary-but-not-sufficient for WASM
//!   determinism — the cross-engine bit-exactness test lives in
//!   `server/test/wasm-sim.test.ts` because it has to load the .wasm.
//! - **Stationary-kart invariants**: a kart with no input rolls to a stop
//!   and stays there.
//! - **Forward acceleration sanity**: holding throttle for 1s reaches a
//!   sensible mid-range speed.
//! - **Steering invariants**: steering at zero speed does nothing; steering
//!   at speed turns the kart.
//! - **Brake invariants**: brake decelerates from any direction.
//! - **Yaw wrap-around**: yaw stays in [-π, π].

use kart_sim::{tick_impl, KartState};

fn fresh() -> KartState {
    KartState { x: 0.0, z: 0.0, yaw: 0.0, speed: 0.0, vx: 0.0, vz: 0.0, _r0: 0.0, _r1: 0.0 }
}

fn run(s: &mut KartState, throttle: f32, brake: f32, steer: f32, dt: f32, n: u32) {
    for _ in 0..n {
        tick_impl(s, throttle, brake, steer, dt);
    }
}

fn bits(s: &KartState) -> [u32; 8] {
    [
        s.x.to_bits(), s.z.to_bits(), s.yaw.to_bits(), s.speed.to_bits(),
        s.vx.to_bits(), s.vz.to_bits(), s._r0.to_bits(), s._r1.to_bits(),
    ]
}

#[test]
fn same_inputs_produce_identical_bits() {
    let mut a = fresh();
    let mut b = fresh();
    let dt = 1.0 / 60.0;
    // Pseudo-random but reproducible input sequence.
    for tick in 0..600u32 {
        let t = libm::sinf(tick as f32 * 0.05);
        let br = (libm::cosf(tick as f32 * 0.03) * 0.5 + 0.5) * 0.3;
        let st = libm::sinf(tick as f32 * 0.07) * 0.8;
        tick_impl(&mut a, t, br, st, dt);
        tick_impl(&mut b, t, br, st, dt);
    }
    assert_eq!(bits(&a), bits(&b), "same inputs must produce identical bits");
}

#[test]
fn idle_kart_stops_and_stays_stopped() {
    let mut s = fresh();
    s.speed = 10.0;
    run(&mut s, 0.0, 0.0, 0.0, 1.0 / 60.0, 60 * 10);
    assert!(s.speed.abs() < 1e-3, "expected speed ~0, got {}", s.speed);
}

#[test]
fn throttle_for_one_second_reaches_midrange() {
    let mut s = fresh();
    run(&mut s, 1.0, 0.0, 0.0, 1.0 / 60.0, 60);
    assert!(
        s.speed > 8.0 && s.speed < 28.0,
        "1s of full throttle should land in (8,28) m/s, got {}",
        s.speed
    );
}

#[test]
fn brake_decelerates_from_either_direction() {
    let mut s = fresh();
    s.speed = 20.0;
    run(&mut s, 0.0, 1.0, 0.0, 1.0 / 60.0, 30);
    assert!(s.speed < 5.0, "0.5s brake from +20: got {}", s.speed);

    let mut s = fresh();
    s.speed = -10.0;
    run(&mut s, 0.0, 1.0, 0.0, 1.0 / 60.0, 30);
    assert!(s.speed > -5.0, "0.5s brake from -10: got {}", s.speed);
}

#[test]
fn steering_does_nothing_below_deadzone() {
    let mut s = fresh();
    s.speed = 0.05;
    let yaw0 = s.yaw;
    run(&mut s, 0.0, 0.0, 1.0, 1.0 / 60.0, 60);
    assert!((s.yaw - yaw0).abs() < 1e-6, "yaw must not change below deadzone");
}

#[test]
fn steering_turns_kart_at_speed() {
    let mut s = fresh();
    s.speed = 20.0;
    let yaw0 = s.yaw;
    run(&mut s, 0.0, 0.0, 1.0, 1.0 / 60.0, 60);
    assert!((s.yaw - yaw0).abs() > 0.5, "yaw should change a lot, got {}", s.yaw - yaw0);
}

#[test]
fn yaw_stays_in_pi_range() {
    let mut s = fresh();
    s.speed = 30.0;
    // 60 ticks × 60 frames = a lot of spinning.
    run(&mut s, 0.0, 0.0, 1.0, 1.0 / 60.0, 60 * 60);
    assert!(s.yaw >= -core::f32::consts::PI && s.yaw <= core::f32::consts::PI);
}

#[test]
fn kart_moves_in_facing_direction() {
    // yaw=0 → forward is +Z in our convention; throttle should push us +Z.
    let mut s = fresh();
    run(&mut s, 1.0, 0.0, 0.0, 1.0 / 60.0, 60);
    assert!(s.z > 1.0, "expected forward motion on +Z, got z={}", s.z);
    assert!(s.x.abs() < 0.1, "expected no lateral drift, got x={}", s.x);
}

#[test]
fn upper_clamp_input_matches_max_input() {
    // Out-of-range inputs must clamp to (1,1,1) and produce identical state.
    // This is how we keep cheaters from sending throttle=1000.
    let mut a = fresh();
    let mut b = fresh();
    run(&mut a, 1.0, 1.0, 1.0, 1.0 / 60.0, 60);
    run(&mut b, 9999.0, 9999.0, 9999.0, 1.0 / 60.0, 60);
    assert_eq!(bits(&a), bits(&b), "out-of-range inputs must clamp to (1,1,1) and produce identical state");
}

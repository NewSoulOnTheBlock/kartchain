import type { Kart } from "../schemas/RaceState.js";

/**
 * Toy kart physics for server-authoritative simulation.
 *
 * NOT a real vehicle model — just enough to give clients a consistent
 * source-of-truth position so cheating clients can be detected. Real
 * gameplay tuning lives in the Godot client's VehicleBody3D which then
 * receives small corrections from the server.
 *
 * Coordinates: +X right, +Y up, +Z forward (matches Godot default).
 */

export type KartInput = {
  throttle: number;   // -1..1 (forward/back)
  brake: number;      // 0..1
  steer: number;      // -1..1 (left/right)
  useItem: boolean;
};

const MAX_SPEED = 42;             // m/s (~150 km/h)
const ACCELERATION = 28;          // m/s^2 at full throttle
const REVERSE_ACCELERATION = 10;  // m/s^2 backwards
const BRAKE_DECEL = 40;           // m/s^2
const FRICTION = 2.5;             // m/s^2 passive
const YAW_RATE_AT_SPEED = 2.4;    // rad/s at max effective steer
const STEER_SPEED_SCALE = 0.35;   // reduced from 0.6 — keeps more steering at top speed

export function simulateKart(kart: Kart, input: KartInput, dt: number): void {
  const forward = { x: Math.sin(kart.yaw), z: Math.cos(kart.yaw) };

  if (input.throttle > 0) {
    kart.speed += ACCELERATION * input.throttle * dt;
  } else if (input.throttle < 0) {
    kart.speed += REVERSE_ACCELERATION * input.throttle * dt;
  }
  if (input.brake > 0) {
    if (kart.speed > 0) kart.speed = Math.max(0, kart.speed - BRAKE_DECEL * input.brake * dt);
    else if (kart.speed < 0) kart.speed = Math.min(0, kart.speed + BRAKE_DECEL * input.brake * dt);
  }
  if (kart.speed > 0) kart.speed = Math.max(0, kart.speed - FRICTION * dt);
  else if (kart.speed < 0) kart.speed = Math.min(0, kart.speed + FRICTION * dt);
  kart.speed = clamp(kart.speed, -MAX_SPEED * 0.4, MAX_SPEED);

  const speedFactor = 1 - (Math.abs(kart.speed) / MAX_SPEED) * STEER_SPEED_SCALE;
  const yawDelta = input.steer * YAW_RATE_AT_SPEED * speedFactor * (Math.abs(kart.speed) > 0.1 ? 1 : 0) * dt;
  kart.yaw += yawDelta * sign(kart.speed);

  kart.vx = forward.x * kart.speed;
  kart.vz = forward.z * kart.speed;
  kart.x += kart.vx * dt;
  kart.z += kart.vz * dt;

  if (kart.yaw > Math.PI) kart.yaw -= 2 * Math.PI;
  if (kart.yaw < -Math.PI) kart.yaw += 2 * Math.PI;
}

function clamp(v: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, v));
}
function sign(v: number): number { return v >= 0 ? 1 : -1; }

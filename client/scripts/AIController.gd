extends Node
class_name AIController
## Drives a Kart by following a racing-line Curve3D.
##
## Attach to a Kart node and assign `racing_line` (a `RacingLine.RacingLineData`).
## The Kart's `_read_local_input()` then sources throttle/brake/steer from
## this controller instead of the keyboard.
##
## Steering uses look-ahead: project the kart's current position onto the
## racing-line, sample a point `look_ahead_m` further along, and steer to
## chase it. Look-ahead distance scales with speed so high-speed corners
## are anticipated earlier (which is the real Mario Kart AI trick).
##
## Throttle is constant-on. Brake fires when the angle between the kart's
## heading and the racing-line tangent at the look-ahead point exceeds
## `brake_angle_rad` — i.e. when a sharp corner is coming.

const RacingLineScript = preload("res://scripts/RacingLine.gd")

# Tuning — overridden per-AI via `apply_skill()` so AI varies in difficulty.
@export var look_ahead_min_m: float = 6.0
@export var look_ahead_max_m: float = 16.0
@export var look_ahead_speed_scale: float = 0.35  # m of look-ahead per m/s of speed
@export var brake_angle_rad: float = 0.55          # ~31° from racing line → brake
@export var hard_brake_angle_rad: float = 0.95     # ~54° → brake hard
@export var steer_max: float = 1.0                 # passed through to Kart steer input
@export var throttle_cruise: float = 1.0
@export var throttle_recovering: float = 0.65      # eased throttle when fighting steering

var racing_line: RacingLineScript.RacingLineData = null

# Cached state so the Kart can read it each physics frame.
var input_throttle: float = 0.0
var input_brake: float = 0.0
var input_steer: float = 0.0

func setup(line: RacingLineScript.RacingLineData) -> void:
	racing_line = line

## Per-kart difficulty knob in [0, 1]. 0 = easy (short look-ahead, brakes
## early, throttles off in corners). 1 = hard (long look-ahead, brakes
## late, keeps the throttle on).
func apply_skill(skill: float) -> void:
	skill = clamp(skill, 0.0, 1.0)
	look_ahead_min_m = lerp(4.0, 8.0, skill)
	look_ahead_max_m = lerp(12.0, 22.0, skill)
	brake_angle_rad = lerp(0.40, 0.75, skill)
	hard_brake_angle_rad = lerp(0.85, 1.10, skill)
	throttle_recovering = lerp(0.50, 0.85, skill)

func _physics_process(_delta: float) -> void:
	var kart := get_parent() as VehicleBody3D
	if kart == null or racing_line == null:
		input_throttle = 0.0
		input_brake = 0.0
		input_steer = 0.0
		return
	_drive(kart)

func _drive(kart: VehicleBody3D) -> void:
	var speed: float = kart.linear_velocity.length()
	var look_ahead: float = clamp(
		look_ahead_min_m + speed * look_ahead_speed_scale,
		look_ahead_min_m,
		look_ahead_max_m,
	)
	var target: Vector3 = RacingLineScript.point_ahead(racing_line, kart.global_position, look_ahead)

	# Steering — project target into kart-local space; if it's to the LEFT
	# in local coords (negative X relative to kart's right), turn left
	# (positive steer in Godot's convention).
	var local_target: Vector3 = kart.global_transform.affine_inverse() * target
	# +X in local = kart's RIGHT (since basis.x is right). So a +X target
	# means we should turn right (negative steer for the player's frame —
	# matches Kart.gd's _read_local_input convention).
	var steer_raw: float = -clamp(local_target.x / max(1.0, look_ahead), -1.0, 1.0)

	# Throttle / brake — based on how sharply we're fighting the wheel.
	var abs_steer: float = abs(steer_raw)
	if abs_steer > hard_brake_angle_rad / steer_max:
		input_throttle = 0.0
		input_brake = 0.8
	elif abs_steer > brake_angle_rad / steer_max:
		input_throttle = throttle_recovering * 0.5
		input_brake = 0.4
	else:
		input_throttle = throttle_cruise
		input_brake = 0.0

	# Anti-stuck: if we're crawling forward, kill the brake.
	if speed < 1.5 and input_throttle > 0.1:
		input_brake = 0.0

	input_steer = steer_raw * steer_max

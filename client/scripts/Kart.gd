extends VehicleBody3D
## Kart controller. Drives via VehicleBody3D with 4 VehicleWheel3D children.
##
## Two modes:
##   - is_local: physics from local input; sends inputs to server.
##   - !is_local: position interpolated from server state.
##
## At spawn time, Race.gd may call set_kart_model(path) to swap the
## placeholder BoxMesh with a real STK glb (e.g. res://karts/tux/tux.glb).
##
## ─── Orientation convention ───────────────────────────────────────────
## STK kart .glb files (converted from .spm via convert_spm.py) export with
## their visual nose along Godot's **+Z** axis — NOT the standard Godot
## forward (-Z). All three of these pieces compensate so the player still
## feels W = "drive toward the visible nose":
##   1. `engine_force = -drive * max` in _apply_drive (negation).
##   2. `_extract_yaw` adds PI so recover() keeps the visual nose pointing
##      where the camera was facing, not 180° from it.
##   3. Race.gd's chase camera sits at `local_kart.basis.z * 6` (which is
##      Godot's "rear" but, with the +Z-nose convention, is BEHIND the
##      visual back of the kart — exactly what the player wants).
## If you ever fix the asset import to export nose along -Z, you must
## update all three sites simultaneously.

@export var is_local: bool = false
@export var player_id: String = ""

# When set, the kart sources its inputs from this controller instead of the
# keyboard. Used for AI opponents in solo races. Player karts leave this
# null and read Input actions directly.
var ai_controller: Node = null

# Tuning — overridden per NFT kart by `apply_stats(...)`
@export var engine_force_max: float = 340.0
@export var brake_force_max: float = 22.0
@export var steering_max: float = 0.65
@export var steering_speed: float = 7.0  # how fast wheels turn to target
# At top speed the kart steers a fraction of its low-speed max so it doesn't
# tip on a quick flick. 0.65 keeps a lot of steering authority at high speed.
@export var steering_high_speed_factor: float = 0.65
# Speed (m/s) at which steering reduction reaches full.
@export var steering_speed_cutoff: float = 40.0

var _input_throttle: float = 0.0
var _input_brake: float = 0.0
var _input_steer: float = 0.0
var _current_steer: float = 0.0

# ─── Boost ────────────────────────────────────────────────────────────
# Press SHIFT to unleash a forward boost: instant impulse + 3-second
# engine multiplier. Recharges from empty to full over 30 seconds.
# Race.gd reads boost_charge / is_boosting() each frame to drive the HUD.
const BOOST_CHARGE_TIME_SEC: float = 30.0
const BOOST_DURATION_SEC: float = 3.0
const BOOST_ENGINE_MULT: float = 2.4
const BOOST_LAUNCH_IMPULSE: float = 14.0
# Start full so players can immediately use it on lap 1, then 30s recharge.
var boost_charge: float = 1.0
var _boost_remaining_sec: float = 0.0
var _prev_shift_pressed: bool = false

signal boost_started
signal boost_ended

# Interpolation buffer for remote karts
var _net_target_pos: Vector3
var _net_target_yaw: float = 0.0
var _net_lerp_speed: float = 10.0

# Loaded STK model node — if present, hides the placeholder Body
var _stk_model: Node3D = null

# Auto-recovery: count seconds the kart has been severely tilted or upside down.
const TILT_OK_DOT: float = 0.55          # local-up vs world-up dot product threshold
const AUTO_RECOVER_AFTER_SEC: float = 1.5
var _tilted_for: float = 0.0
var _recover_cooldown: float = 0.0       # min spacing between recoveries

func apply_stats(top_speed_pct: float, accel_pct: float, handling_pct: float) -> void:
	engine_force_max = 240.0 + 180.0 * accel_pct
	steering_max = 0.45 + 0.35 * handling_pct

## Replace the placeholder BoxMesh body with a real STK kart glb.
## path is a res:// URI like "res://karts/tux/tux.glb".
##
## After loading, resizes the kart's BoxShape3D collision shape to the
## model's AABB so tiny karts (hexley) and tall karts (sara_the_wizard)
## don't share the same hitbox.
func set_kart_model(path: String) -> void:
	if path.is_empty():
		return
	if not ResourceLoader.exists(path):
		push_warning("[kart] model not found: " + path)
		return
	var scene: PackedScene = load(path)
	if scene == null:
		push_warning("[kart] failed to load: " + path)
		return
	if _stk_model and is_instance_valid(_stk_model):
		_stk_model.queue_free()
	var body := get_node_or_null("Body")
	if body:
		body.visible = false
	_stk_model = scene.instantiate()
	add_child(_stk_model)
	_stk_model.position.y = -0.35
	# See Orientation convention header. STK glbs are nose-along-+Z; the
	# rest of the kart code compensates so we don't rotate the model here.
	_fit_collision_to_model()

## Sums every MeshInstance3D AABB under the loaded STK model and resizes
## our BoxShape3D collision to match (clamped to sane bounds so wonky
## STK models don't produce a 10m hitbox). Cheap — runs once at spawn.
func _fit_collision_to_model() -> void:
	if _stk_model == null or not is_instance_valid(_stk_model):
		return
	var collision := get_node_or_null("Collision") as CollisionShape3D
	if collision == null or not (collision.shape is BoxShape3D):
		return
	var aabb := _aggregate_local_aabb(_stk_model, _stk_model)
	if aabb.size == Vector3.ZERO:
		return
	# Clamp each axis: min 0.8m so tiny karts still have body, max 3.0m so
	# any rogue authoring (e.g. an STK kart whose mesh includes a flag pole)
	# doesn't give it a tank-sized hitbox.
	var size := Vector3(
		clamp(aabb.size.x, 0.8, 3.0),
		clamp(aabb.size.y, 0.5, 2.0),
		clamp(aabb.size.z, 1.2, 3.0),
	)
	(collision.shape as BoxShape3D).size = size
	# Center the collision shape on the AABB center (plus the model's own
	# Y offset) so a kart whose mesh sits off-origin still gets a
	# correctly-placed hitbox.
	collision.position = aabb.get_center() + _stk_model.position

## Walk every MeshInstance3D under `node`, accumulating their AABBs into
## `root`'s local frame using each node's transform relative to `root`.
## Doesn't rely on global_transform (which isn't yet computed when called
## from within set_kart_model immediately after add_child).
func _aggregate_local_aabb(node: Node, root: Node3D) -> AABB:
	var out := AABB()
	var seeded := false
	for mi in _collect_mesh_instances(node):
		var local_xform := _transform_from(mi, root)
		var ab: AABB = local_xform * mi.get_aabb()
		if not seeded:
			out = ab
			seeded = true
		else:
			out = out.merge(ab)
	return out

func _transform_from(child: Node3D, root: Node3D) -> Transform3D:
	var xform := Transform3D.IDENTITY
	var cursor: Node = child
	while cursor != null and cursor != root:
		if cursor is Node3D:
			xform = (cursor as Node3D).transform * xform
		cursor = cursor.get_parent()
	return xform

func _collect_mesh_instances(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_mesh_instances(child))
	return out

func _ready() -> void:
	# Skid-mark trail behind wheels (Mario-Kart style). Self-contained;
	# spawns fading quads in world space when boosting or hard-cornering.
	# Adapted from gitlab.com/20-games-in-30-days/mario-kart (TireTrail.gd).
	var skid: TireSkid = TireSkid.new()
	skid.name = "TireSkid"
	add_child(skid)

func _physics_process(delta: float) -> void:
	if is_local:
		_read_local_input()
		# AI karts don't send network input or boost; keep their loop tight.
		if ai_controller == null:
			_tick_boost(delta)
		_apply_drive(delta)
		_check_auto_recover(delta)
		if ai_controller == null:
			_send_input_if_due()
	else:
		_interpolate_to_target(delta)

func is_boosting() -> bool:
	return _boost_remaining_sec > 0.0

# Edge-triggers boost on SHIFT press, ticks charge meter, counts down
# the active boost window. Called once per physics frame from local karts.
func _tick_boost(delta: float) -> void:
	if _boost_remaining_sec > 0.0:
		_boost_remaining_sec = max(0.0, _boost_remaining_sec - delta)
		if _boost_remaining_sec <= 0.0:
			boost_ended.emit()
		return
	# Recharge while not boosting.
	if boost_charge < 1.0:
		boost_charge = clamp(boost_charge + delta / BOOST_CHARGE_TIME_SEC, 0.0, 1.0)
	# Detect rising edge of SHIFT. Use raw key so we don't have to register
	# a "boost" input action — FreeCam.gd polls KEY_SHIFT the same way.
	var shift_now: bool = Input.is_physical_key_pressed(KEY_SHIFT)
	if shift_now and not _prev_shift_pressed and boost_charge >= 1.0:
		_activate_boost()
	_prev_shift_pressed = shift_now

func _activate_boost() -> void:
	_boost_remaining_sec = BOOST_DURATION_SEC
	boost_charge = 0.0
	# Instantaneous forward kick. The kart's visual front is along its
	# local -Z (see Orientation convention header & Race.gd chase cam).
	var fwd_world: Vector3 = -global_transform.basis.z
	linear_velocity += fwd_world * BOOST_LAUNCH_IMPULSE
	boost_started.emit()

func _read_local_input() -> void:
	# AI-driven kart: pull inputs from the attached controller and skip the
	# keyboard + item-use path entirely (AI doesn't fire items today).
	if ai_controller != null and is_instance_valid(ai_controller):
		_input_throttle = float(ai_controller.input_throttle)
		_input_brake = float(ai_controller.input_brake)
		_input_steer = float(ai_controller.input_steer)
		return
	_input_throttle = Input.get_action_strength("throttle")
	_input_brake = Input.get_action_strength("brake")
	# Godot's VehicleBody3D.steering is POSITIVE = left, NEGATIVE = right.
	# Our action names "steer_left" (A) and "steer_right" (D) are from the
	# player's perspective. Flip so D produces a negative value (= turn right
	# as the player expects).
	_input_steer = Input.get_action_strength("steer_left") - Input.get_action_strength("steer_right")
	if Input.is_action_just_pressed("use_item"):
		NetworkClient.use_item(1)

func _apply_drive(delta: float) -> void:
	# W (throttle) should drive the kart FORWARD; S (brake) backward.
	# Godot's VehicleBody3D + our default wheel orientation drives "forward"
	# in the opposite direction from what feels natural with our chase cam,
	# so we negate to put the kart's motion in the camera's forward direction.
	var drive = _input_throttle - _input_brake
	if _boost_remaining_sec > 0.0:
		# During boost, force max-forward engine regardless of input so SHIFT
		# alone really "shoots" the kart. BOOST_ENGINE_MULT amplifies past the
		# normal cap. Skips reverse so a player holding S during boost still
		# goes forward.
		engine_force = -1.0 * engine_force_max * BOOST_ENGINE_MULT
	else:
		engine_force = -drive * engine_force_max
	# No active brake — pressing S applies reverse engine force instead, which
	# both slows a forward-moving kart and lets you back up from a standstill.
	brake = 0.0
	# Speed-based steering authority: at high speed, reduce max steering angle
	# so a quick A/D flick can't roll the kart. At low speed full authority.
	var speed_ratio: float = clamp(linear_velocity.length() / steering_speed_cutoff, 0.0, 1.0)
	var effective_max: float = lerp(steering_max, steering_max * steering_high_speed_factor, speed_ratio)
	_current_steer = lerp(_current_steer, _input_steer * effective_max, clamp(steering_speed * delta, 0.0, 1.0))
	steering = _current_steer

## Recovery — call this when the kart is upside-down / stuck.
## Lifts the kart 1.5m, rotates to upright preserving current heading,
## zeroes velocities, and gives a small downward settle.
func recover() -> void:
	if _recover_cooldown > 0.0:
		return
	_recover_cooldown = 1.0
	_tilted_for = 0.0
	# Keep the current Y-axis heading (yaw) so the player keeps facing the
	# same way; reset pitch + roll to zero so the kart lands flat.
	var yaw := _extract_yaw()
	var upright := Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3(0, 1.5, 0))
	global_transform = upright
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	engine_force = 0.0
	steering = 0.0
	_current_steer = 0.0

func _extract_yaw() -> float:
	# Project current forward (-Z basis) onto the XZ plane then atan2.
	var fwd := -global_transform.basis.z
	return atan2(fwd.x, fwd.z) + PI    # +PI because our -Z forward is reversed at spawn

## Watch for prolonged upside-down state and auto-recover so players
## don't get stuck. Threshold: local-up dot world-up < TILT_OK_DOT.
func _check_auto_recover(delta: float) -> void:
	if _recover_cooldown > 0.0:
		_recover_cooldown = max(0.0, _recover_cooldown - delta)
	var uprightness: float = global_transform.basis.y.dot(Vector3.UP)
	if uprightness < TILT_OK_DOT:
		_tilted_for += delta
		if _tilted_for >= AUTO_RECOVER_AFTER_SEC:
			recover()
	else:
		_tilted_for = max(0.0, _tilted_for - delta * 2.0)

var _input_send_accumulator: float = 0.0
# Last sent throttle/brake/steer so we can skip identical packets.
# Always send at least every KEEPALIVE seconds so the server knows we're
# alive and stops moving the kart if we let go of the keys.
const _KEEPALIVE_SEC: float = 0.25
var _last_sent_throttle: float = INF
var _last_sent_brake: float = INF
var _last_sent_steer: float = INF
var _last_send_t: float = 0.0
func _send_input_if_due() -> void:
	_input_send_accumulator += get_physics_process_delta_time()
	if _input_send_accumulator < 1.0 / 30.0:
		return
	_input_send_accumulator = 0.0
	_last_send_t += 1.0 / 30.0
	var unchanged: bool = (
		is_equal_approx(_input_throttle, _last_sent_throttle)
		and is_equal_approx(_input_brake, _last_sent_brake)
		and is_equal_approx(_input_steer, _last_sent_steer)
	)
	if unchanged and _last_send_t < _KEEPALIVE_SEC:
		return
	_last_sent_throttle = _input_throttle
	_last_sent_brake = _input_brake
	_last_sent_steer = _input_steer
	_last_send_t = 0.0
	NetworkClient.send_input(_input_throttle, _input_brake, _input_steer, 0)

func _interpolate_to_target(delta: float) -> void:
	global_position = global_position.lerp(_net_target_pos, clamp(_net_lerp_speed * delta, 0.0, 1.0))
	var target_basis = Basis(Vector3.UP, _net_target_yaw)
	global_transform.basis = global_transform.basis.slerp(target_basis, clamp(_net_lerp_speed * delta, 0.0, 1.0))

func set_net_target(pos: Vector3, yaw: float) -> void:
	_net_target_pos = pos
	_net_target_yaw = yaw


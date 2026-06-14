extends VehicleBody3D
## Kart controller. Drives via VehicleBody3D with 4 VehicleWheel3D children.
##
## Two modes:
##   - is_local: physics from local input; sends inputs to server.
##   - !is_local: position interpolated from server state.
##
## At spawn time, Race.gd may call set_kart_model(path) to swap the
## placeholder BoxMesh with a real STK glb (e.g. res://karts/tux/tux.glb).

@export var is_local: bool = false
@export var player_id: String = ""

# Tuning — overridden per NFT kart by `apply_stats(...)`
@export var engine_force_max: float = 220.0
@export var brake_force_max: float = 22.0
@export var steering_max: float = 0.45
@export var steering_speed: float = 4.0  # how fast wheels turn to target

var _input_throttle: float = 0.0
var _input_brake: float = 0.0
var _input_steer: float = 0.0
var _current_steer: float = 0.0

# Interpolation buffer for remote karts
var _net_target_pos: Vector3
var _net_target_yaw: float = 0.0
var _net_lerp_speed: float = 10.0

# Loaded STK model node — if present, hides the placeholder Body
var _stk_model: Node3D = null

func apply_stats(top_speed_pct: float, accel_pct: float, handling_pct: float) -> void:
	engine_force_max = 160.0 + 120.0 * accel_pct
	steering_max = 0.30 + 0.25 * handling_pct

## Replace the placeholder BoxMesh body with a real STK kart glb.
## path is a res:// URI like "res://karts/tux/tux.glb".
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
	# STK kart models are exported with their nose pointing in Godot's
	# forward direction (-Z) — no rotation needed.

func _physics_process(delta: float) -> void:
	if is_local:
		_read_local_input()
		_apply_drive(delta)
		_send_input_if_due()
	else:
		_interpolate_to_target(delta)

func _read_local_input() -> void:
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
	engine_force = -drive * engine_force_max
	# No active brake — pressing S applies reverse engine force instead, which
	# both slows a forward-moving kart and lets you back up from a standstill.
	brake = 0.0
	_current_steer = lerp(_current_steer, _input_steer * steering_max, clamp(steering_speed * delta, 0.0, 1.0))
	steering = _current_steer

var _input_send_accumulator: float = 0.0
func _send_input_if_due() -> void:
	_input_send_accumulator += get_physics_process_delta_time()
	if _input_send_accumulator >= 1.0 / 30.0:
		_input_send_accumulator = 0.0
		NetworkClient.send_input(_input_throttle, _input_brake, _input_steer, 0)

func _interpolate_to_target(delta: float) -> void:
	global_position = global_position.lerp(_net_target_pos, clamp(_net_lerp_speed * delta, 0.0, 1.0))
	var target_basis = Basis(Vector3.UP, _net_target_yaw)
	global_transform.basis = global_transform.basis.slerp(target_basis, clamp(_net_lerp_speed * delta, 0.0, 1.0))

func set_net_target(pos: Vector3, yaw: float) -> void:
	_net_target_pos = pos
	_net_target_yaw = yaw

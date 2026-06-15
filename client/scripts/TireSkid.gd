extends Node3D
class_name TireSkid
## TireSkid — Mario-Kart-style skid marks behind a kart's wheels.
##
## Adapted from https://gitlab.com/20-games-in-30-days/mario-kart
## (Vehicle/TireTrail.gd). The original used a Path3D-per-wheel approach
## tied to a CSGPolygon3D in the vehicle scene; we replace that with a
## spawn-and-fade quad pool so it drops into any VehicleBody3D + 4
## VehicleWheel3D rig without scene changes.
##
## Rules:
##   - Skid only when a wheel is actually in contact with the ground
##     (Mario-Kart "no marks while airborne" feel).
##   - Skid when the kart is boosting (signature visual).
##   - Skid when the kart's lateral velocity exceeds SLIP_THRESHOLD
##     (i.e. drifting / hard cornering).
##
## Marks are added to the scene root (NOT the kart) so they stay glued
## to the ground while the kart drives away. They modulate to alpha 0
## over LIFETIME_SEC, then queue_free themselves.

const LIFETIME_SEC: float = 6.0
const MIN_DIST_BETWEEN_MARKS: float = 0.18
const SLIP_THRESHOLD_MPS: float = 4.5
const MARK_WIDTH_M: float = 0.30
const MARK_LENGTH_M: float = 0.55
const MARK_LIFT_M: float = 0.04
const MARK_COLOR: Color = Color(0.05, 0.05, 0.05, 0.78)
const MAX_LIVE_MARKS: int = 480

static var _mesh_cache: PlaneMesh = null
static var _material_cache: StandardMaterial3D = null
static var _live_marks: int = 0

var _kart: VehicleBody3D = null
var _wheels: Array[VehicleWheel3D] = []
var _last_pos_by_wheel: Dictionary = {}

func _ready() -> void:
	_kart = get_parent() as VehicleBody3D
	if _kart == null:
		push_warning("[tire-skid] parent is not a VehicleBody3D — disabling")
		set_physics_process(false)
		return
	for c in _kart.get_children():
		if c is VehicleWheel3D:
			_wheels.append(c)
	if _wheels.is_empty():
		push_warning("[tire-skid] no VehicleWheel3D children on kart — disabling")
		set_physics_process(false)

func _physics_process(_delta: float) -> void:
	if _kart == null or not is_instance_valid(_kart):
		set_physics_process(false)
		return
	var boosting: bool = _kart.has_method("is_boosting") and _kart.is_boosting()
	var lateral_speed: float = _lateral_speed_mps()
	var should_skid: bool = boosting or lateral_speed > SLIP_THRESHOLD_MPS
	if not should_skid:
		_last_pos_by_wheel.clear()
		return
	for w in _wheels:
		if not w.is_in_contact():
			continue
		var contact: Vector3 = w.get_collision_point()
		var key: int = w.get_instance_id()
		var last: Vector3 = _last_pos_by_wheel.get(key, Vector3.INF)
		if last != Vector3.INF and last.distance_to(contact) < MIN_DIST_BETWEEN_MARKS:
			continue
		_last_pos_by_wheel[key] = contact
		_spawn_mark(contact)

func _lateral_speed_mps() -> float:
	if _kart == null:
		return 0.0
	var v: Vector3 = _kart.linear_velocity
	var fwd: Vector3 = -_kart.global_transform.basis.z
	var lateral: Vector3 = v - fwd * v.dot(fwd)
	return lateral.length()

func _spawn_mark(world_pos: Vector3) -> void:
	var host: Node = get_tree().current_scene
	if host == null:
		host = _kart.get_parent()
	if host == null:
		return
	if _live_marks >= MAX_LIVE_MARKS:
		# Soft cap — newest mark replaces oldest by simply skipping spawn.
		# Cheap: avoids walking the scene to find/free oldest each frame.
		return
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = _shared_mesh()
	mi.material_override = _shared_material().duplicate()
	mi.cast_shadow = MeshInstance3D.SHADOW_CASTING_SETTING_OFF
	var up: Vector3 = _kart.global_transform.basis.y.normalized()
	mi.global_position = world_pos + up * MARK_LIFT_M
	# Yaw mark to match kart facing so the long edge runs along the
	# direction of travel (looks like a real skid streak).
	var fwd: Vector3 = -_kart.global_transform.basis.z
	mi.look_at(mi.global_position + fwd, up)
	mi.rotate_object_local(Vector3.RIGHT, deg_to_rad(90.0))
	host.add_child(mi)
	_live_marks += 1
	var tw: Tween = mi.create_tween()
	tw.tween_property(mi, "modulate:a", 0.0, LIFETIME_SEC)
	tw.tween_callback(func():
		_live_marks = max(0, _live_marks - 1)
		mi.queue_free()
	)

static func _shared_mesh() -> PlaneMesh:
	if _mesh_cache == null:
		_mesh_cache = PlaneMesh.new()
		_mesh_cache.size = Vector2(MARK_WIDTH_M, MARK_LENGTH_M)
	return _mesh_cache

static func _shared_material() -> StandardMaterial3D:
	if _material_cache == null:
		var m: StandardMaterial3D = StandardMaterial3D.new()
		m.albedo_color = MARK_COLOR
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		m.no_depth_test = false
		_material_cache = m
	return _material_cache

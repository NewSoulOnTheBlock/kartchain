extends Node3D
## Race scene root. Spawns karts from server state, owns the camera follow,
## and bridges UI events.

const KART_SCENE := preload("res://scenes/Kart.tscn")

@onready var karts_root: Node3D = $Karts
@onready var camera: Camera3D = $Camera
@onready var hud: CanvasLayer = $HUD
@onready var lap_label: Label = $HUD/Margin/VBox/Lap
@onready var pos_label: Label = $HUD/Margin/VBox/Position
@onready var countdown_label: Label = $HUD/CountdownLabel
@onready var status_overlay: Label = $HUD/StatusOverlay

var local_kart: VehicleBody3D = null
var karts_by_id: Dictionary = {}  # player_id -> Kart
var local_player_id: String = ""
var _race_state_received: bool = false
var _status_t: float = 0.0
var _has_net_error: bool = false

var _track_node: Node3D = null
var _loaded_track_id: String = ""

# Camera modes
var _free_cam_enabled: bool = false  # kart-follow by default; F1 toggles free-cam

# Override of TrackLoader.spawn_offset, captured at runtime via FreeCam Y key.
# Persisted in browser localStorage so it survives reloads.
var _spawn_override_world: Vector3 = Vector3.INF   # INF = no override

func _ready() -> void:
	NetworkClient.race_state.connect(_on_race_state)
	NetworkClient.race_self.connect(_on_race_self)
	NetworkClient.race_countdown.connect(_on_countdown)
	NetworkClient.race_lap.connect(_on_lap)
	NetworkClient.race_finish.connect(_on_finish)
	NetworkClient.race_settled.connect(_on_settled)
	NetworkClient.net_error.connect(_on_net_error)

	# local_player_id is set by race:self (Colyseus sessionId), NOT the wallet pubkey.
	local_player_id = ""
	countdown_label.text = ""
	status_overlay.text = "CONNECTING TO RACE…"
	status_overlay.visible = true
	hud.show()

	_apply_camera_mode()
	# Cross-link FreeCam → this scene (for Y-key spawn capture)
	if camera and "race_ref" in camera:
		camera.race_ref = self
	_show_debug_hint()

func _on_net_error(code: String, message: String) -> void:
	_has_net_error = true
	status_overlay.text = "RACE ERROR: %s\n%s\n\nPress ESC to leave" % [code, message]
	status_overlay.visible = true

func _on_race_self(session_id: String) -> void:
	local_player_id = session_id
	print("[race] local session id: ", session_id)
	# If our kart already arrived in state before race:self, claim it now.
	if karts_by_id.has(session_id):
		var k: VehicleBody3D = karts_by_id[session_id]
		k.is_local = true
		local_kart = k
		NetworkClient.send_ready()

func _show_debug_hint() -> void:
	var hint := Label.new()
	hint.name = "DebugHint"
	# Initial text matches current camera mode; _apply_camera_mode updates after.
	hint.text = ""
	hint.add_theme_font_size_override("font_size", 14)
	hint.position = Vector2(20, 100)
	hud.add_child(hint)
	_apply_camera_mode()

# Build the localStorage key for the currently loaded track's spawn override.
func _spawn_storage_key() -> String:
	return "kartchain.spawn." + _loaded_track_id

# Restore a spawn override that was previously saved (Y key) for this track.
func _load_persisted_spawn() -> void:
	if _loaded_track_id == "":
		return
	var raw := SolanaBridge.storage_get(_spawn_storage_key())
	if raw == "":
		return
	var parsed = JSON.parse_string(raw)
	if parsed is Dictionary and parsed.has("x"):
		_spawn_override_world = Vector3(
			float(parsed.x), float(parsed.y), float(parsed.z))
		print("[race] loaded persisted spawn for %s: %s" % [_loaded_track_id, _spawn_override_world])

# Called by FreeCam when the user presses Y while free-cam is on.
# `world_pos` is the camera's current global_position. We override the
# track's spawn offset so all karts (including remote ones) respawn there.
func set_spawn_at_world_position(world_pos: Vector3) -> void:
	_spawn_override_world = world_pos
	if _loaded_track_id != "":
		var payload = JSON.stringify({"x": world_pos.x, "y": world_pos.y, "z": world_pos.z})
		SolanaBridge.storage_set(_spawn_storage_key(), payload)
	NetworkClient.set_spawn(world_pos.x, world_pos.y, world_pos.z)
	print("[race] spawn point set + broadcast: ", world_pos)
	# Re-place every kart on the racing grid centered on the new spawn.
	var ids: Array = karts_by_id.keys()
	ids.sort()
	for i in ids.size():
		var pid = ids[i]
		var kart: VehicleBody3D = karts_by_id[pid]
		if not is_instance_valid(kart):
			continue
		var grid := TrackLoader.grid_slot(i)
		kart.linear_velocity = Vector3.ZERO
		kart.angular_velocity = Vector3.ZERO
		kart.global_position = world_pos + grid + Vector3(0, TrackLoader.GROUND_LIFT, 0)
	var hint = hud.get_node_or_null("DebugHint")
	if hint:
		hint.text = "Spawn saved (%.1f, %.1f, %.1f) — shared with all players\nF1: kart-follow   Y: re-set spawn here   R: recover" % [
			world_pos.x, world_pos.y, world_pos.z
		]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_F1:
			_free_cam_enabled = not _free_cam_enabled
			_apply_camera_mode()
		elif k.keycode == KEY_R:
			# Manual recover — flip upright + lift, preserve heading.
			if local_kart and is_instance_valid(local_kart) and local_kart.has_method("recover"):
				local_kart.recover()

func _apply_camera_mode() -> void:
	if camera.has_method("enable"):
		camera.enable(_free_cam_enabled)
	var hint = hud.get_node_or_null("DebugHint")
	if hint:
		hint.text = ("FREE-CAM ON (F1 to follow kart)\nRMB capture mouse  WASD move  Space up  Ctrl down  Shift boost\nT = teleport to kart    Y = set kart spawn    R = recover kart"
			if _free_cam_enabled else
			"KART-FOLLOW (F1 for free cam)\nWASD or arrow keys to drive  •  R = flip upright  •  Y = save spawn here")
	# When entering kart-follow, snap camera directly behind the kart based
	# on the kart's CURRENT facing yaw, not just a world-fixed offset.
	if not _free_cam_enabled and local_kart and is_instance_valid(local_kart):
		_snap_camera_behind_kart()
		# Make absolutely sure the mouse is free + the kart canvas has focus,
		# otherwise WASD events go elsewhere in the browser.
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

func _snap_camera_behind_kart() -> void:
	if local_kart == null or not is_instance_valid(local_kart):
		return
	# In Godot, transform.basis.z is the BACKWARD axis (forward is -Z).
	# Place the camera 6 units behind + 3 above, looking at the kart.
	var back := local_kart.global_transform.basis.z
	var up := local_kart.global_transform.basis.y
	camera.global_position = local_kart.global_position + back * 6.0 + up * 3.0
	camera.look_at(local_kart.global_position + up * 0.5, Vector3.UP)

func _process(_delta: float) -> void:
	# Tick the connecting-status animation + auto-hide once the local kart spawns.
	# When an error has been surfaced, leave that text alone — don't overwrite.
	if status_overlay.visible and not _has_net_error:
		_status_t += _delta
		var dots := int(_status_t * 2.0) % 4
		if not _race_state_received:
			status_overlay.text = "CONNECTING TO RACE" + ".".repeat(dots)
		elif local_kart == null:
			status_overlay.text = "JOINING LOBBY" + ".".repeat(dots)
		else:
			status_overlay.visible = false
	if camera and camera.has_method("enable"):
		camera.local_kart_ref = local_kart
	# Kart-follow chase cam — sits 6 units behind, 3 above, looking at the kart.
	if not _free_cam_enabled and local_kart and is_instance_valid(local_kart):
		var back = local_kart.global_transform.basis.z   # Godot: +Z is back
		var up = local_kart.global_transform.basis.y
		var target = local_kart.global_position + back * 6.0 + up * 3.0
		camera.global_position = camera.global_position.lerp(target, 0.25)
		camera.look_at(local_kart.global_position + Vector3(0, 0.8, 0), Vector3.UP)

func _on_race_state(state: Dictionary) -> void:
	_race_state_received = true
	if status_overlay and status_overlay.visible and local_kart != null:
		status_overlay.visible = false
	var track_id := String(state.get("trackId", ""))
	if track_id != "" and track_id != _loaded_track_id:
		var ok := _load_track(track_id)
		# Only remember the id if the track actually loaded — otherwise we
		# want to retry on the next state tick (e.g. resource loaded late).
		if ok:
			_loaded_track_id = track_id
			_load_persisted_spawn()

	if not state.has("karts"):
		return
	var karts = state["karts"]
	# Server-broadcast spawn override wins — every player sees the same start point.
	var server_has_override := bool(state.get("hasSpawnOverride", false))
	if server_has_override:
		_spawn_override_world = Vector3(
			float(state.get("spawnX", 0.0)),
			float(state.get("spawnY", 0.0)),
			float(state.get("spawnZ", 0.0)))
	var has_override := _spawn_override_world != Vector3.INF
	# Spawn anchor in world coords. With a broadcast override (player set it
	# from the ground), use it as-is. Without, fall back to track defaults
	# which assume a small Y lift.
	var anchor: Vector3 = Vector3.ZERO
	if has_override:
		anchor = _spawn_override_world
	elif _loaded_track_id != "":
		anchor = TrackLoader.spawn_offset(_loaded_track_id)
	# Sort karts by playerId so every client builds the same grid order.
	var ids: Array = karts.keys()
	ids.sort()
	for i in ids.size():
		var pid_var = ids[i]
		var pid := String(pid_var)
		var k_data: Dictionary = karts[pid_var]
		var node: VehicleBody3D = karts_by_id.get(pid, null)
		var spawning := node == null
		var grid := TrackLoader.grid_slot(i)
		# Slight upward lift so wheels aren't intersecting the ground
		var spawn_world: Vector3 = anchor + grid + Vector3(0, TrackLoader.GROUND_LIFT, 0)
		# Snap to whatever ground is actually under the spawn point (placeholder
		# plane OR loaded STK track mesh — both have collision). Prevents karts
		# spawning 2+ m in the air and free-falling onto the track.
		if node == null:
			var ground_y := _ground_y_at(spawn_world)
			if ground_y > -999.0:
				spawn_world.y = ground_y + TrackLoader.GROUND_LIFT
			node = _spawn_kart(pid, k_data)
			node.linear_velocity = Vector3.ZERO
			node.angular_velocity = Vector3.ZERO
			node.global_position = spawn_world
		var pos := Vector3(float(k_data.get("x", 0.0)), float(k_data.get("y", 0.0)), float(k_data.get("z", 0.0)))
		var yaw := float(k_data.get("yaw", 0.0))
		# Remote karts follow server pos + the same shared anchor + their grid slot
		var target_world := anchor + grid + Vector3(0, TrackLoader.GROUND_LIFT, 0) + Vector3(pos.x, 0, pos.z)
		if node == local_kart:
			var phase := String(state.get("phase", "waiting"))
			if phase == "racing":
				var drift := node.global_position.distance_to(target_world)
				if drift > 6.0:
					node.global_position = target_world
		else:
			node.set_net_target(target_world, yaw)
		if pid == local_player_id:
			lap_label.text = "Lap %d / %d" % [int(k_data.get("lap", 0)), int(state.get("totalLaps", 3))]
			pos_label.text = "P%d" % int(k_data.get("position", 0))

func _spawn_kart(pid: String, k_data: Dictionary) -> VehicleBody3D:
	var node: VehicleBody3D = KART_SCENE.instantiate()
	node.player_id = pid
	node.is_local = (pid == local_player_id)
	karts_root.add_child(node)
	karts_by_id[pid] = node
	if node.is_local:
		local_kart = node
		# Auto-ready so single-player practice starts the race immediately.
		# (LobbyRoom's countdown begins as soon as every player in the room
		# is ready.) Multi-player races still wait for everyone.
		NetworkClient.send_ready()
	var stats := _stats_for_kart(int(k_data.get("kartType", 0)))
	node.apply_stats(stats["top_speed"], stats["accel"], stats["handling"])
	var model_path := KartCatalog.kart_model_path(int(k_data.get("kartType", 0)))
	if not model_path.is_empty():
		node.set_kart_model(model_path)
	return node

## Returns the world Y of the first solid surface directly below `world_pos`.
## Used to snap spawning karts onto whatever ground is actually under them
## (placeholder plane OR a loaded STK track mesh — both have collision).
## Returns -1000.0 if no surface was found within the search range so the
## caller can fall back to the spawn anchor.
func _ground_y_at(world_pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	if space == null:
		return -1000.0
	var from := Vector3(world_pos.x, world_pos.y + 200.0, world_pos.z)
	var to   := Vector3(world_pos.x, world_pos.y - 500.0, world_pos.z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = space.intersect_ray(query)
	if hit.has("position"):
		return float(hit.position.y)
	return -1000.0

# Load and add the STK track scene. Hides the placeholder ground/sky on success.
# Returns true on success so the caller can retry on failure.
func _load_track(track_id: String) -> bool:
	var node: Node3D = TrackLoader.load_track(track_id)
	if node == null:
		print("[race] track %s not loaded — keeping placeholder ground visible" % track_id)
		return false
	if _track_node and is_instance_valid(_track_node):
		_track_node.queue_free()
	_track_node = node
	add_child(node)
	# Hide placeholder ground + light (we provide our own in TrackLoader)
	var placeholder_ground := get_node_or_null("Ground")
	if placeholder_ground:
		placeholder_ground.visible = false
	var placeholder_sun := get_node_or_null("DirectionalLight")
	if placeholder_sun:
		placeholder_sun.visible = false
	# Lift kart start positions above the loaded track surface
	# (server places them at y=0.5 in flat-world coords; track meshes are
	# centered around y=0 in the GLB so this is usually safe).
	print("[race] track loaded:", track_id)
	return true

func _stats_for_kart(kart_type: int) -> Dictionary:
	# kart_type 0 = starter; > 0 = NFT lookup (TODO: pull from GameState.owned_karts)
	if kart_type == 0:
		return {"top_speed": 0.5, "accel": 0.5, "handling": 0.5}
	for k in GameState.owned_karts:
		if int(k.get("kartType", -1)) == kart_type:
			return {
				"top_speed": float(k.get("topSpeed", 0.5)),
				"accel": float(k.get("accel", 0.5)),
				"handling": float(k.get("handling", 0.5)),
			}
	return {"top_speed": 0.5, "accel": 0.5, "handling": 0.5}

func _on_countdown(seconds: int) -> void:
	if seconds <= 0:
		countdown_label.text = "GO!"
		await get_tree().create_timer(1.0).timeout
		countdown_label.text = ""
	else:
		countdown_label.text = str(seconds)

func _on_lap(player_id: String, lap: int, lap_time: float) -> void:
	if player_id == local_player_id:
		print("Lap %d done in %.2fs" % [lap, lap_time])

func _on_finish(player_id: String, total_time: float, position: int) -> void:
	if player_id == local_player_id:
		hud.get_node("FinishPanel").show()
		hud.get_node("FinishPanel/VBox/Time").text = "Time: %.2fs" % total_time
		hud.get_node("FinishPanel/VBox/Pos").text = "Position: %d" % position

func _on_settled(tx_signature: String) -> void:
	print("Race settled onchain:", tx_signature)
	hud.get_node("FinishPanel/VBox/Tx").text = "Tx: " + tx_signature

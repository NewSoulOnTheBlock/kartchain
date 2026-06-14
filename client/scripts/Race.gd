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

var local_kart: VehicleBody3D = null
var karts_by_id: Dictionary = {}  # player_id -> Kart
var local_player_id: String = ""

var _track_node: Node3D = null
var _loaded_track_id: String = ""

# Camera modes
var _free_cam_enabled: bool = true   # default ON so we can debug

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

	# local_player_id is set by race:self (Colyseus sessionId), NOT the wallet pubkey.
	local_player_id = ""
	countdown_label.text = ""
	hud.show()

	_apply_camera_mode()
	# Cross-link FreeCam → this scene (for Y-key spawn capture)
	if camera and "race_ref" in camera:
		camera.race_ref = self
	_show_debug_hint()

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
	hint.text = "FREE-CAM ON (press F1 to follow kart)\nRMB capture mouse  WASD move  Space up  Ctrl down  Shift boost\nT = teleport to kart    Y = set kart spawn    R = recover kart"
	hint.add_theme_font_size_override("font_size", 14)
	hint.position = Vector2(20, 100)
	hud.add_child(hint)

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
	# Persist to localStorage so it survives reloads and respawns
	if _loaded_track_id != "":
		var payload = JSON.stringify({"x": world_pos.x, "y": world_pos.y, "z": world_pos.z})
		SolanaBridge.storage_set(_spawn_storage_key(), payload)
	print("[race] spawn point set: ", world_pos)
	for pid in karts_by_id.keys():
		var kart: VehicleBody3D = karts_by_id[pid]
		if not is_instance_valid(kart):
			continue
		var idx = karts_by_id.keys().find(pid)
		var col = idx % 4
		var row = idx / 4
		var grid_off = Vector3(col * 2.5 - 3.75, 0, -row * 3.0)
		kart.linear_velocity = Vector3.ZERO
		kart.angular_velocity = Vector3.ZERO
		kart.global_position = world_pos + grid_off
	var hint = hud.get_node_or_null("DebugHint")
	if hint:
		hint.text = "Spawn saved (%.1f, %.1f, %.1f)  [R = clear]\nF1: kart-follow   Y: re-set spawn here" % [
			world_pos.x, world_pos.y, world_pos.z
		]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_F1:
			_free_cam_enabled = not _free_cam_enabled
			_apply_camera_mode()

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
	var track_id := String(state.get("trackId", ""))
	if track_id != "" and track_id != _loaded_track_id:
		_load_track(track_id)
		_loaded_track_id = track_id
		# Load any persisted spawn override for this track
		_load_persisted_spawn()

	if not state.has("karts"):
		return
	var karts = state["karts"]
	# Compute the effective spawn anchor. If the user pressed Y in free-cam
	# we use that absolute world position; otherwise fall back to the
	# track's hand-coded default offset added to the server's flat-world
	# position.
	var has_override := _spawn_override_world != Vector3.INF
	var offset := Vector3.ZERO if has_override else (
		TrackLoader.spawn_offset(_loaded_track_id) if _loaded_track_id != "" else Vector3.ZERO)
	for pid_var in karts.keys():
		var pid := String(pid_var)
		var k_data: Dictionary = karts[pid_var]
		var node: VehicleBody3D = karts_by_id.get(pid, null)
		var spawning := node == null
		if node == null:
			node = _spawn_kart(pid, k_data)
			# Stagger initial position in a grid so karts don't pile up.
			var grid_idx = karts_by_id.size() - 1
			var col = grid_idx % 4
			var row = grid_idx / 4
			var grid_off = Vector3(col * 2.5 - 3.75, 0, -row * 3.0)
			if has_override:
				node.global_position = _spawn_override_world + grid_off
			else:
				node.global_position = Vector3(
					float(k_data.get("x", 0.0)),
					float(k_data.get("y", 0.5)),
					float(k_data.get("z", 0.0))) + offset
		var pos := Vector3(float(k_data.get("x", 0.0)), float(k_data.get("y", 0.0)), float(k_data.get("z", 0.0)))
		var yaw := float(k_data.get("yaw", 0.0))
		var target_world = (_spawn_override_world + pos) if has_override else (pos + offset)
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

# Load and add the STK track scene. Hides the placeholder ground/sky on success.
func _load_track(track_id: String) -> void:
	var node: Node3D = TrackLoader.load_track(track_id)
	if node == null:
		print("[race] track %s not loaded — using placeholder" % track_id)
		return
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

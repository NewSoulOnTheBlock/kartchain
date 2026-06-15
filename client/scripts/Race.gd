extends Node3D
## Race scene root. Spawns karts from server state, owns the camera follow,
## and bridges UI events.

const KART_SCENE := preload("res://scenes/Kart.tscn")
const RacingLineScript = preload("res://scripts/RacingLine.gd")
const AIControllerScript = preload("res://scripts/AIController.gd")

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
var _sent_ready: bool = false  # guard against duplicate sendReady (race_self + spawn)
var _last_phase: String = "waiting"
var _last_max_players: int = 1
var _last_waiting_until_ms: float = 0.0

var _track_node: Node3D = null
var _loaded_track_id: String = ""
var _racing_line: RacingLineScript.RacingLineData = null

# How many AI opponents to spawn when the room is solo or short of humans.
# Capped at the 8-slot grid (TrackLoader.grid_slot). Set 0 to disable AI.
const AI_FILL_TARGET: int = 4
var _ai_spawned: bool = false

# Camera modes
var _free_cam_enabled: bool = false  # kart-follow by default; F1 toggles free-cam

# Death-floor — if the local kart's Y drops below this it gets auto-recovered.
# Placeholder ground sits at y=-15 (~50 ft below origin) so karts land on the
# REAL track collision first. The death-floor sits well below that so a
# free-fall off the edge of the track still recovers without the placeholder
# silently catching you mid-air.
const DEATH_FLOOR_Y: float = -80.0

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

	# Kick off the deterministic kart-sim .wasm load early so it's ready
	# by the time the countdown ends. Safe to call before the bridge is up
	# (WasmSim.init_async retries internally).
	WasmSim.init_async()

	# local_player_id is set by race:self (Colyseus sessionId), NOT the wallet pubkey.
	local_player_id = ""
	countdown_label.text = ""
	status_overlay.text = "CONNECTING TO RACE…"
	status_overlay.visible = true
	hud.show()

	# Cross-link FreeCam → this scene (for Y-key spawn capture)
	if camera and "race_ref" in camera:
		camera.race_ref = self
	_show_debug_hint()  # also calls _apply_camera_mode internally

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
		_send_ready_once()

func _send_ready_once() -> void:
	if _sent_ready:
		return
	_sent_ready = true
	NetworkClient.send_ready()
	# Once we know our local kart and the track is loaded, fill the grid
	# with AI opponents. Deferred so the racing line (parsed during
	# _load_track) has had a chance to arrive even if state ticks raced.
	call_deferred("_maybe_spawn_ai_karts")

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

# Soft reconciliation between locally-predicted state and the server's
# authoritative state. Three bands so the local kart doesn't teleport
# under tiny network jitter and doesn't lerp forever under big divergence.
#
#   drift <  SOFT_DRIFT_M      -> ignore; client prediction wins
#   drift <  HARD_SNAP_M       -> lerp visually over RECONCILE_LERP_S
#   drift >= HARD_SNAP_M       -> hard snap (player teleported or cheated)
#
# In horizontal plane only (Y left to Godot's gravity + track collision).
#
# WHEN WASM-AUTHORITATIVE MODE IS ON for the local kart (PvP rollback path,
# browser only), this function is bypassed entirely — the kart itself does
# input-log replay reconciliation in apply_server_state(), which is
# mathematically exact (same .wasm both sides) instead of a visual lerp.
const SOFT_DRIFT_M:     float = 1.0
const HARD_SNAP_M:      float = 12.0
const RECONCILE_LERP_S: float = 0.30

# Per-frame reconciliation state for the local kart only.
var _reconcile_target: Vector3 = Vector3.ZERO
var _reconcile_yaw_target: float = 0.0
var _reconcile_t_remaining: float = 0.0

func _reconcile_local_kart(node: VehicleBody3D, target_world: Vector3, target_yaw: float, last_input_seq: int, server_speed: float, server_vx: float, server_vz: float) -> void:
	# Pure-WASM PvP path: the kart owns its own reconciliation via
	# input-log replay. Hand it the authoritative state + ack and bail.
	if "apply_server_state" in node and "_wasm_authoritative" in node and node._wasm_authoritative:
		node.apply_server_state(target_world.x, target_world.z, target_yaw,
				server_speed, server_vx, server_vz, last_input_seq)
		_reconcile_t_remaining = 0.0
		return

	# Compare only the horizontal plane — Y is owned by Godot physics
	# (gravity + STK track collision; the WASM sim is 2D today).
	var here := Vector2(node.global_position.x, node.global_position.z)
	var there := Vector2(target_world.x, target_world.z)
	var drift := here.distance_to(there)
	if drift < SOFT_DRIFT_M:
		# Client prediction matches the server within noise — no correction.
		_reconcile_t_remaining = 0.0
		return
	if drift >= HARD_SNAP_M:
		# Big divergence — snap rather than slingshot the visual through 12m.
		node.global_position = Vector3(target_world.x, node.global_position.y, target_world.z)
		_reconcile_t_remaining = 0.0
		return
	# Soft lerp toward the server's reported position over the next 300ms.
	_reconcile_target = Vector3(target_world.x, node.global_position.y, target_world.z)
	_reconcile_yaw_target = target_yaw
	_reconcile_t_remaining = RECONCILE_LERP_S

func _process(_delta: float) -> void:
	# Status overlay logic — surface what the race is doing right now:
	#   - error state: stick with the error message
	#   - not connected yet: "CONNECTING TO RACE..."
	#   - connected but waiting for players: "WAITING FOR PLAYERS X/N — auto-start in Ys"
	#   - countdown/racing: hide overlay, countdown label takes over
	_status_t += _delta
	if not _has_net_error:
		var dots := int(_status_t * 2.0) % 4
		var d := ".".repeat(dots)
		if not _race_state_received:
			status_overlay.text = "CONNECTING TO RACE" + d
			status_overlay.visible = true
		elif _last_phase == "waiting":
			var here: int = karts_by_id.size()
			var need: int = _last_max_players
			var line1: String
			if need > 1 and here < need:
				line1 = "WAITING FOR PLAYERS — %d / %d%s" % [here, need, d]
			else:
				line1 = "ALL PLAYERS IN — PREPARING%s" % d
			# Auto-start countdown line (in seconds remaining)
			var sec_left: int = 0
			if _last_waiting_until_ms > 0:
				sec_left = max(0, int(round((_last_waiting_until_ms - _now_ms()) / 1000.0)))
			if need > 1 and here < need and sec_left > 0:
				status_overlay.text = "%s\nAuto-start in %ds" % [line1, sec_left]
			else:
				status_overlay.text = line1
			status_overlay.visible = true
		else:
			# countdown / racing / finished — hide the overlay
			status_overlay.visible = false
	if camera and camera.has_method("enable"):
		camera.local_kart_ref = local_kart
	# Death-floor safety net — if the local kart has fallen way below the
	# track, recover them instead of letting them plummet forever.
	if local_kart and is_instance_valid(local_kart) and local_kart.global_position.y < DEATH_FLOOR_Y:
		if local_kart.has_method("recover"):
			local_kart.recover()
	# Soft drift correction toward the last server-reported position.
	# Runs after physics + before camera so the chase cam follows the
	# corrected pose, not the pre-correction one.
	_apply_reconcile_lerp(_delta)
	# Kart-follow chase cam — sits 6 units behind, 3 above, looking at the kart.
	if not _free_cam_enabled and local_kart and is_instance_valid(local_kart):
		var back = local_kart.global_transform.basis.z   # Godot: +Z is back
		var up = local_kart.global_transform.basis.y
		var target = local_kart.global_position + back * 6.0 + up * 3.0
		camera.global_position = camera.global_position.lerp(target, 0.25)
		camera.look_at(local_kart.global_position + Vector3(0, 0.8, 0), Vector3.UP)
	_update_boost_hud()

# Pulls the local kart toward _reconcile_target over RECONCILE_LERP_S
# seconds. Called from _process so the visual catches up smoothly between
# server state ticks; cleared automatically when the timer runs out or a
# new server state arrives with a different target.
func _apply_reconcile_lerp(_delta: float) -> void:
	if _reconcile_t_remaining <= 0.0:
		return
	if local_kart == null or not is_instance_valid(local_kart):
		_reconcile_t_remaining = 0.0
		return
	# Step toward target; faster when we have less time left so we always
	# converge within the window.
	var alpha: float = clamp(_delta / max(0.01, _reconcile_t_remaining), 0.0, 1.0)
	var p := local_kart.global_position
	var goal := Vector3(_reconcile_target.x, p.y, _reconcile_target.z)
	local_kart.global_position = p.lerp(goal, alpha)
	_reconcile_t_remaining = max(0.0, _reconcile_t_remaining - _delta)

# Reflects local_kart.boost_charge into the bottom-center bar. Tints
# the bar gold + relabels while the boost is actively firing.
const _BOOST_COLOR_READY   := Color(1.00, 0.78, 0.18, 1)
const _BOOST_COLOR_ACTIVE  := Color(1.00, 0.45, 0.10, 1)
const _BOOST_COLOR_CHARGING := Color(0.42, 0.62, 0.95, 1)
func _update_boost_hud() -> void:
	var bar := hud.get_node_or_null("BoostHUD/BoostBar") as ProgressBar
	var label := hud.get_node_or_null("BoostHUD/BoostLabel") as Label
	if bar == null or label == null:
		return
	if local_kart == null or not is_instance_valid(local_kart) or not ("boost_charge" in local_kart):
		bar.value = 0.0
		return
	var boosting: bool = local_kart.has_method("is_boosting") and local_kart.is_boosting()
	var charge_pct: float = 100.0 * clamp(local_kart.boost_charge, 0.0, 1.0)
	bar.value = 100.0 if boosting else charge_pct
	if boosting:
		label.text = "BOOSTING!"
		label.modulate = _BOOST_COLOR_ACTIVE
		bar.modulate = _BOOST_COLOR_ACTIVE
	elif charge_pct >= 100.0:
		label.text = "BOOST READY  [SHIFT]"
		label.modulate = _BOOST_COLOR_READY
		bar.modulate = _BOOST_COLOR_READY
	else:
		label.text = "BOOST CHARGING  %d%%" % int(round(charge_pct))
		label.modulate = _BOOST_COLOR_CHARGING
		bar.modulate = _BOOST_COLOR_CHARGING

func _now_ms() -> float:
	return float(Time.get_unix_time_from_system() * 1000.0)

func _on_race_state(state: Dictionary) -> void:
	_race_state_received = true
	_last_phase = String(state.get("phase", "waiting"))
	_last_max_players = max(1, int(state.get("maxPlayers", 1)))
	_last_waiting_until_ms = float(state.get("waitingUntilMs", 0.0))
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
				var last_seq := int(k_data.get("lastInputSeq", 0))
				var s_speed := float(k_data.get("speed", 0.0))
				var s_vx := float(k_data.get("vx", 0.0))
				var s_vz := float(k_data.get("vz", 0.0))
				_reconcile_local_kart(node, target_world, yaw, last_seq, s_speed, s_vx, s_vz)
		else:
			node.set_net_target(target_world, yaw)
		if pid == local_player_id:
			lap_label.text = "Lap %d / %d" % [int(k_data.get("lap", 0)), int(state.get("totalLaps", 3))]
			pos_label.text = "P%d" % int(k_data.get("position", 0))

	# If the local kart, the racing line, and the room size are all known,
	# fill empty grid slots with AI opponents. Idempotent: subsequent state
	# ticks are no-ops via the _ai_spawned guard inside.
	if local_kart != null and _racing_line != null and not _ai_spawned:
		_maybe_spawn_ai_karts()

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
		_send_ready_once()
	else:
		# Seed the remote kart's interp target to its spawn point so it
		# doesn't lerp toward Vector3.ZERO before the first state tick.
		node.set_net_target(node.global_position, 0.0)
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
	# Parse STK driveline (res://tracks/<id>/quads.xml) into a Curve3D so AI
	# karts have something to follow. Safe to call even when AI is disabled;
	# the curve is also useful for future minimap/HUD work.
	_racing_line = RacingLineScript.load_for_track(track_id)
	if _racing_line != null:
		print("[race] racing line: %d quads, length %.1fm" % [_racing_line.quad_count, _racing_line.length])
	else:
		print("[race] no racing line — AI opponents will be disabled for %s" % track_id)
	return true

# Fill empty grid slots with AI opponents. Called once the local kart has
# arrived and we know the room size. AI karts are 100% client-side fiction
# today — the server doesn't know about them. PvP work (tomorrow) will move
# AI policy to the server so all clients see identical AI behavior.
func _maybe_spawn_ai_karts() -> void:
	if _ai_spawned:
		return
	if _racing_line == null:
		return
	if local_kart == null or not is_instance_valid(local_kart):
		return
	var human_count: int = karts_by_id.size()
	# Only fill when the room is essentially solo (1 human present) so we
	# don't create a 12-kart grid in a 4-player race that's still waiting.
	if human_count > 1:
		return
	var max_grid: int = max(1, int(_last_max_players))
	var ai_count: int = min(AI_FILL_TARGET, max(0, 8 - human_count))
	if ai_count <= 0:
		return
	_ai_spawned = true
	print("[race] spawning %d AI opponents (max grid %d)" % [ai_count, max_grid])

	# Use the racing-line tangent at the player's spawn to orient AI karts
	# the same way the player faces, so the grid points down the track.
	var anchor: Vector3 = local_kart.global_position
	var fwd: Vector3 = RacingLineScript.tangent_at(_racing_line, anchor)
	if fwd.length_squared() < 1e-4:
		fwd = -local_kart.global_transform.basis.z

	for i in ai_count:
		# i+1 because grid slot 0 belongs to the local kart.
		var grid := TrackLoader.grid_slot(i + 1)
		_spawn_ai_kart(i, anchor, fwd, grid)

func _spawn_ai_kart(index: int, anchor: Vector3, fwd: Vector3, grid: Vector3) -> void:
	var node: VehicleBody3D = KART_SCENE.instantiate()
	var pid: String = "ai-%02d" % index
	node.player_id = pid
	# `is_local = true` keeps the kart on the local physics path (instead of
	# net-interpolation). The AIController feeds inputs in lieu of keyboard.
	node.is_local = true
	karts_root.add_child(node)
	karts_by_id[pid] = node

	# Visual + tuning variety so AI karts look distinct.
	var kart_type: int = ((index * 7) % max(1, KartCatalog.karts.size()))
	var stats := _stats_for_kart(kart_type)
	node.apply_stats(stats["top_speed"], stats["accel"], stats["handling"])
	var model_path := KartCatalog.kart_model_path(kart_type)
	if not model_path.is_empty():
		node.set_kart_model(model_path)

	# Place the AI on the grid behind the player, facing the racing-line tangent.
	var right: Vector3 = fwd.cross(Vector3.UP).normalized()
	var spawn_world: Vector3 = anchor + (right * grid.x) + (fwd * -abs(grid.z))
	spawn_world.y += TrackLoader.GROUND_LIFT
	node.global_position = spawn_world
	node.look_at(spawn_world + fwd, Vector3.UP)
	# Cancel the look_at's rotation around Y if our model is +Z-nose (per
	# Kart.gd's "Orientation convention" header): rotate 180° so the visible
	# nose points along `fwd`.
	node.rotate_object_local(Vector3.UP, PI)

	# Hook up the AI brain. Skill rises with index so AI 0 is easy, AI N hard.
	var ai: Node = AIControllerScript.new()
	ai.name = "AIController"
	ai.setup(_racing_line)
	var skill: float = clamp(0.25 + 0.20 * float(index), 0.0, 1.0)
	ai.apply_skill(skill)
	node.add_child(ai)
	node.ai_controller = ai
	print("[race] AI %s kart_type=%d skill=%.2f at %s" % [pid, kart_type, skill, str(spawn_world)])

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

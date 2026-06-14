extends Node
## NetworkClient (autoload)
## Thin WebSocket client that talks to the Colyseus host page bridge.
##
## The host Next.js page runs the official colyseus.js client and forwards
## JSON-ified state deltas + messages to us via JavaScriptBridge.
##
## Host bridge methods (window.kartchain.net):
##   joinLobby() -> Promise<void>
##   joinRace(raceId) -> Promise<void>
##   leaveRoom() -> Promise<void>
##   sendInput({seq, throttle, brake, steer, items}) -> void
##   sendReady() -> void
##   useItem(slot) -> void
##   subscribe(callback) -> void

signal lobby_state(lobbies: Array)
signal race_state(state: Dictionary)
signal race_self(session_id: String)
signal race_countdown(seconds: int)
signal race_lap(player_id: String, lap: int, lap_time: float)
signal race_finish(player_id: String, total_time: float, position: int)
signal race_settled(tx_signature: String)
signal net_error(code: String, message: String)
signal bridge_ready()

var _js_bridge  # JavaScriptObject for window.kartchain.net
var _cb         # JavaScriptBridge callback

var _input_seq: int = 0

# Queue of join requests issued before the bridge was ready.
# When the bridge becomes available we replay them in order.
var _pending: Array = []

func _ready() -> void:
	if OS.has_feature("web"):
		_try_init_bridge()
	else:
		print("[net] native build — running without web bridge")

# Polls window.kartchain.net until the parent React app has installed it,
# then wires up subscriptions. Safe to call repeatedly.
func _try_init_bridge() -> void:
	if _js_bridge != null:
		return
	var win = JavaScriptBridge.get_interface("window")
	if win == null:
		_retry_init()
		return
	var k = win.kartchain
	if k == null:
		# parent React app hasn't installed window.kartchain yet
		_retry_init()
		return
	var net = k.net
	if net == null:
		_retry_init()
		return
	_js_bridge = net
	_cb = JavaScriptBridge.create_callback(_on_net_event)
	_js_bridge.subscribe(_cb)
	print("[net] bridge ready — flushing %d queued request(s)" % _pending.size())
	emit_signal("bridge_ready")
	# Replay anything that was queued before the bridge was ready
	var queued: Array = _pending.duplicate()
	_pending.clear()
	for fn in queued:
		fn.call()

func _retry_init() -> void:
	# 100 ms backoff — fast enough that the lobby UI fills in quickly,
	# slow enough not to spin the engine.
	get_tree().create_timer(0.1).timeout.connect(_try_init_bridge, CONNECT_ONE_SHOT)

func _on_net_event(args: Array) -> void:
	if args.is_empty():
		return
	# Bridge sends JSON strings (NOT JS objects) — see KartchainBridge.tsx
	# `emitNet`. We parse to a real Dictionary so .get(...) works.
	var raw = String(args[0])
	var evt = JSON.parse_string(raw)
	if not (evt is Dictionary):
		push_warning("[net] non-dict event: " + raw.substr(0, 80))
		return
	match String(evt.get("type", "")):
		"lobby:state":
			emit_signal("lobby_state", evt.get("lobbies", []))
		"race:self":
			emit_signal("race_self", String(evt.get("sessionId", "")))
		"race:state":
			emit_signal("race_state", evt.get("state", {}))
		"race:countdown":
			emit_signal("race_countdown", int(evt.get("seconds", 0)))
		"race:lap":
			emit_signal("race_lap",
				String(evt.get("playerId", "")),
				int(evt.get("lapNumber", 0)),
				float(evt.get("lapTime", 0.0)))
		"race:finish":
			emit_signal("race_finish",
				String(evt.get("playerId", "")),
				float(evt.get("totalTime", 0.0)),
				int(evt.get("position", 0)))
		"race:settled":
			emit_signal("race_settled", String(evt.get("txSignature", "")))
		"error":
			emit_signal("net_error",
				String(evt.get("code", "")),
				String(evt.get("message", "")))
		_:
			push_warning("[net] unknown event type: " + String(evt.get("type", "")))

func join_lobby() -> void:
	if _js_bridge == null:
		_pending.append(func(): join_lobby())
		_try_init_bridge()
		return
	_js_bridge.joinLobby()

func join_race(race_id: String) -> void:
	if _js_bridge == null:
		_pending.append(func(): join_race(race_id))
		_try_init_bridge()
		return
	# IMPORTANT: pass kartType as a SEPARATE arg, not inside a dict — Godot's
	# GDScript→JavaScriptBridge dict conversion is unreliable across Godot
	# versions and the JS side may see {} or undefined props.
	var max_p: int = GameState.pending_max_players
	print("[net] join_race id=%s kartType=%d maxPlayers=%d" % [race_id, GameState.selected_kart_type, max_p])
	_js_bridge.joinRaceWithKart(race_id, GameState.selected_kart_type, max_p)

func leave_room() -> void:
	if _js_bridge:
		_js_bridge.leaveRoom()

func send_ready() -> void:
	if _js_bridge == null:
		_pending.append(func(): send_ready())
		return
	_js_bridge.sendReady()

func send_input(throttle: float, brake: float, steer: float, items: int) -> void:
	_input_seq += 1
	if _js_bridge == null:
		return
	# IMPORTANT: dict-passing across GDScript → JavaScriptBridge is unreliable
	# (often arrives as {} on the JS side). Use the plain-arg variant the
	# bridge exposes via sendInputArgs(seq, throttle, brake, steer, items).
	_js_bridge.sendInputArgs(_input_seq, throttle, brake, steer, items)

func use_item(slot: int) -> void:
	if _js_bridge:
		_js_bridge.useItem(slot)

# Broadcast a spawn-point override to every player in the room.
# The server stores it in race state and all clients use it on next state tick.
func set_spawn(x: float, y: float, z: float) -> void:
	if _js_bridge:
		_js_bridge.setSpawn(x, y, z)

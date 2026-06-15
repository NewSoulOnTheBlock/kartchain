extends Node
## WasmSim — GDScript wrapper around the kart_sim.wasm deterministic physics.
##
## Lives as an autoload so any node can call WasmSim.tick(...) without
## re-fetching the .wasm. Backed by `window.kartchain.sim` (see
## web/lib/sim-bridge.ts) when running in the browser; on native builds
## the sim is unavailable and every call no-ops.
##
## ## Why deterministic
##
## The same .wasm runs on the Colyseus server (server/src/simulation/wasmSim.ts).
## Bit-exact f32 ops on both sides => identical positions from identical inputs.
## That's what makes client-side prediction + server reconciliation work
## without visible snap corrections.
##
## ## Usage
##
##   WasmSim.init_async()                       # call once on race start
##   WasmSim.init_slot(slot)                    # zero a kart slot
##   WasmSim.set_pose(slot, x, z, yaw)          # seed spawn pose
##   var s = WasmSim.tick(slot, throttle, brake, steer, dt)
##   # s = { "x": float, "z": float, "yaw": float, "speed": float,
##   #       "vx": float, "vz": float }

signal ready_changed(ready: bool)

var _js_sim = null
var _ready: bool = false
var _init_started: bool = false
var _init_callback = null

func is_ready() -> bool:
	return _ready

## Fire-and-forget. Begins loading the .wasm via the JS bridge. Emits
## `ready_changed(true)` when complete; safe to call multiple times.
func init_async() -> void:
	if _ready or _init_started:
		return
	if not OS.has_feature("web"):
		# Native build — no JavaScriptBridge available. Stay un-ready;
		# every call below no-ops. PvP prediction is browser-only.
		print("[wasm-sim] native build — sim disabled (browser-only feature)")
		return
	_init_started = true
	var win = JavaScriptBridge.get_interface("window")
	if win == null:
		_retry_init()
		return
	var kc = win.kartchain
	if kc == null:
		_retry_init()
		return
	var sim = kc.sim
	if sim == null:
		_retry_init()
		return
	_js_sim = sim
	_init_callback = JavaScriptBridge.create_callback(_on_init_done)
	# sim.init() returns a Promise; we attach a .then() to flip _ready.
	# Errors are surfaced via console.error from the JS side.
	var promise = _js_sim.init()
	if promise != null and promise.then != null:
		promise.then(_init_callback)
	else:
		# Older bridge / synchronous return — assume ready.
		_ready = true
		emit_signal("ready_changed", true)
		print("[wasm-sim] ready (sync)")

func _retry_init() -> void:
	_init_started = false
	get_tree().create_timer(0.1).timeout.connect(init_async, CONNECT_ONE_SHOT)

func _on_init_done(_args: Array) -> void:
	_ready = true
	emit_signal("ready_changed", true)
	print("[wasm-sim] ready")

## Zero a kart slot's state.
func init_slot(slot: int) -> void:
	if not _ready or _js_sim == null:
		return
	_js_sim.initSlot(slot)

## Set kart slot pose; velocities zeroed.
func set_pose(slot: int, x: float, z: float, yaw: float) -> void:
	if not _ready or _js_sim == null:
		return
	_js_sim.setPose(slot, x, z, yaw)

## Advance kart slot one tick; return the new state as a Dictionary.
## Returns null when the sim isn't ready (caller should fall back).
func tick(slot: int, throttle: float, brake: float, steer: float, dt: float):
	if not _ready or _js_sim == null:
		return null
	var raw = _js_sim.tick(slot, throttle, brake, steer, dt)
	if raw == null:
		return null
	return {
		"x":     float(raw.x),
		"z":     float(raw.z),
		"yaw":   float(raw.yaw),
		"speed": float(raw.speed),
		"vx":    float(raw.vx),
		"vz":    float(raw.vz),
	}

## Read kart slot state without ticking.
func read(slot: int):
	if not _ready or _js_sim == null:
		return null
	var raw = _js_sim.read(slot)
	if raw == null:
		return null
	return {
		"x":     float(raw.x),
		"z":     float(raw.z),
		"yaw":   float(raw.yaw),
		"speed": float(raw.speed),
		"vx":    float(raw.vx),
		"vz":    float(raw.vz),
	}

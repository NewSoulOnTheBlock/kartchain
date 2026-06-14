extends Node
## SolanaBridge (autoload)
## Talks to the host Next.js page over JavaScriptBridge. The page wraps the
## game canvas, owns the @solana/wallet-adapter modal, and exposes a small
## RPC surface back to the game.
##
## Wire protocol (window.kartchain on the host):
##   getWallet() -> {pubkey: string} | null
##   connectWallet() -> Promise<{pubkey: string}>
##   signAndSendEnterRace({raceId, entryFeeLamports}) -> Promise<{tx: string}>
##   signAndSendClaimP2E({raceId, amount, attestation}) -> Promise<{tx: string}>
##   getOwnedKarts() -> Promise<Kart[]>
##
## In native (non-web) builds, this all falls back to stubs so the game still
## runs in the Godot editor.

signal wallet_connected(pubkey: String)
signal wallet_error(message: String)

var _js_window
var _bridge        # window.kartchain (cached, but always re-read via _ensure_bridge)
var _on_wallet_cb

func _ready() -> void:
	if OS.has_feature("web"):
		_js_window = JavaScriptBridge.get_interface("window")
		_on_wallet_cb = JavaScriptBridge.create_callback(_on_wallet_event)
		_try_init()
	else:
		print("[wallet] native build — wallet calls will stub")

# Browser localStorage helpers — used to persist spawn overrides + settings.
func storage_set(key: String, value: String) -> void:
	if not OS.has_feature("web"):
		return
	JavaScriptBridge.eval("localStorage.setItem(%s, %s)" % [JSON.stringify(key), JSON.stringify(value)], true)

func storage_get(key: String) -> String:
	if not OS.has_feature("web"):
		return ""
	var v = JavaScriptBridge.eval("localStorage.getItem(%s) || ''" % JSON.stringify(key), true)
	return String(v) if v != null else ""

func _try_init() -> void:
	var b = _ensure_bridge()
	if b == null:
		get_tree().create_timer(0.1).timeout.connect(_try_init, CONNECT_ONE_SHOT)
		return
	b.subscribe(_on_wallet_cb)
	# Use the JSON variant so we get back a string we can parse to Dictionary.
	var json_str = String(b.getWalletJson())
	var current = JSON.parse_string(json_str)
	if current is Dictionary and current.has("pubkey"):
		GameState.set_wallet(String(current["pubkey"]))

func _ensure_bridge():
	if _js_window == null:
		return null
	var k = _js_window.kartchain
	if k == null:
		return null
	_bridge = k
	return _bridge

func _on_wallet_event(args: Array) -> void:
	if args.is_empty():
		return
	var raw = String(args[0])
	var evt = JSON.parse_string(raw)
	if not (evt is Dictionary):
		push_warning("[wallet] non-dict event: " + raw.substr(0, 80))
		return
	match String(evt.get("type", "")):
		"wallet:changed":
			var pk = String(evt.get("pubkey", ""))
			GameState.set_wallet(pk)
			emit_signal("wallet_connected", pk)
		"wallet:error":
			emit_signal("wallet_error", String(evt.get("message", "unknown")))

func connect_wallet() -> void:
	var bridge = _ensure_bridge()
	if bridge == null:
		GameState.set_wallet("DevNetStub11111111111111111111111111111111")
		emit_signal("wallet_connected", GameState.wallet_pubkey)
		return
	bridge.connectWallet()

func sign_and_send_enter_race(race_id: String, entry_fee_lamports: int) -> void:
	var bridge = _ensure_bridge()
	if bridge == null:
		return
	bridge.signAndSendEnterRace({
		"raceId": race_id,
		"entryFeeLamports": entry_fee_lamports,
		"kartType": GameState.selected_kart_type,
	})

func sign_and_send_claim_p2e(race_id: String, amount: int, attestation_b64: String) -> void:
	var bridge = _ensure_bridge()
	if bridge == null:
		return
	bridge.signAndSendClaimP2E({"raceId": race_id, "amount": amount, "attestation": attestation_b64})

func refresh_owned_karts() -> void:
	var bridge = _ensure_bridge()
	if bridge == null:
		GameState.set_owned_karts([])
		return
	# Use JSON variant for the same reason as getWalletJson.
	var promise = bridge.getOwnedKartsJson()
	# The result of an async JS function is a Promise; we can't await it in
	# GDScript directly. For MVP we just attempt synchronous read which works
	# if the underlying fn returned a resolved value. Wire a callback later
	# if you need to handle true asynchrony.
	if promise == null:
		GameState.set_owned_karts([])
		return
	var as_str = str(promise)
	var parsed = JSON.parse_string(as_str)
	if parsed is Array:
		GameState.set_owned_karts(parsed)

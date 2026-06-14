extends Node
## GameState (autoload)
## Holds session-wide state: connected wallet, owned NFT karts, current race id.

signal wallet_changed(pubkey: String)
signal kart_loadout_changed(kart_type: int)

var wallet_pubkey: String = ""
var owned_karts: Array[Dictionary] = []  # [{mint, name, top_speed, accel, handling, uri}]
var selected_kart_type: int = 0  # 0 = first kart in KartCatalog
var current_race_id: String = ""

# Set by Main when the user clicks "Join Race" on a lobby entry; consumed by
# KartSelect after they pick a racer. Lets us route through the picker scene
# without losing context.
var pending_race_id: String = ""
var pending_entry_fee_lamports: int = 0

func set_wallet(pubkey: String) -> void:
	if wallet_pubkey == pubkey:
		return
	wallet_pubkey = pubkey
	emit_signal("wallet_changed", pubkey)

func set_owned_karts(karts: Array) -> void:
	owned_karts.clear()
	for k in karts:
		owned_karts.append(k)

func select_kart(kart_type: int) -> void:
	selected_kart_type = kart_type
	emit_signal("kart_loadout_changed", kart_type)

func clear() -> void:
	wallet_pubkey = ""
	owned_karts.clear()
	selected_kart_type = 0
	current_race_id = ""
	pending_race_id = ""
	pending_entry_fee_lamports = 0

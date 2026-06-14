extends Node
## GameState (autoload)
## Holds session-wide state: connected wallet, owned NFT karts, current race id,
## and player profile (name, bio, pfp choice).

signal wallet_changed(pubkey: String)
signal kart_loadout_changed(kart_type: int)
signal profile_changed

var wallet_pubkey: String = ""
var owned_karts: Array[Dictionary] = []
var selected_kart_type: int = 0
var current_race_id: String = ""

# Profile (persisted in browser localStorage via SolanaBridge.storage_*)
var profile_name: String = ""
var profile_bio: String = ""
var profile_pfp_index: int = 0   # index into KartCatalog.karts for icon

# Lobby join args (consumed by KartSelect)
var pending_race_id: String = ""
var pending_entry_fee_lamports: int = 0

const PROFILE_KEY := "kartchain.profile"

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

func has_profile() -> bool:
	return profile_name != ""

func set_profile(name: String, bio: String, pfp: int) -> void:
	profile_name = name
	profile_bio = bio
	profile_pfp_index = pfp
	# Default selected_kart_type to the PFP choice so the player races as their avatar.
	selected_kart_type = pfp
	_persist_profile()
	emit_signal("profile_changed")

func load_profile_from_storage() -> void:
	var raw = SolanaBridge.storage_get(PROFILE_KEY)
	if raw == "":
		return
	var parsed = JSON.parse_string(raw)
	if parsed is Dictionary:
		profile_name = String(parsed.get("name", ""))
		profile_bio = String(parsed.get("bio", ""))
		profile_pfp_index = int(parsed.get("pfp", 0))
		selected_kart_type = profile_pfp_index

func _persist_profile() -> void:
	var payload = JSON.stringify({
		"name": profile_name,
		"bio": profile_bio,
		"pfp": profile_pfp_index,
	})
	SolanaBridge.storage_set(PROFILE_KEY, payload)

func clear() -> void:
	wallet_pubkey = ""
	owned_karts.clear()
	selected_kart_type = 0
	current_race_id = ""
	pending_race_id = ""
	pending_entry_fee_lamports = 0
	profile_name = ""
	profile_bio = ""
	profile_pfp_index = 0

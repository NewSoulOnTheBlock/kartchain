extends Control
## Main menu — wallet connect button, race lobby browser, garage link.

@onready var status_label: Label = $Margin/VBox/Status
@onready var connect_button: Button = $Margin/VBox/ConnectButton
@onready var lobby_list: ItemList = $Margin/VBox/LobbyList
@onready var join_button: Button = $Margin/VBox/JoinButton

var _lobbies: Array = []

func _ready() -> void:
	SolanaBridge.wallet_connected.connect(_on_wallet_connected)
	SolanaBridge.wallet_error.connect(func(m): status_label.text = "Wallet error: " + m)
	GameState.wallet_changed.connect(_on_wallet_changed)
	NetworkClient.lobby_state.connect(_on_lobby_state)

	connect_button.pressed.connect(_on_connect_pressed)
	join_button.pressed.connect(_on_join_pressed)

	# Auto-join the lobby room on launch so we see open races
	NetworkClient.join_lobby()
	_refresh_wallet_ui(GameState.wallet_pubkey)

func _on_connect_pressed() -> void:
	SolanaBridge.connect_wallet()

func _on_wallet_connected(pubkey: String) -> void:
	status_label.text = "Connected: " + _short(pubkey)
	SolanaBridge.refresh_owned_karts()

func _on_wallet_changed(pubkey: String) -> void:
	_refresh_wallet_ui(pubkey)

func _refresh_wallet_ui(pubkey: String) -> void:
	if pubkey.is_empty():
		status_label.text = "Not connected"
		connect_button.text = "Connect Wallet"
	else:
		status_label.text = "Connected: " + _short(pubkey)
		connect_button.text = "Disconnect"

func _on_lobby_state(lobbies: Array) -> void:
	_lobbies = lobbies
	lobby_list.clear()
	for l in lobbies:
		var track_name = String(l.get("trackName", l.get("trackId", "?")))
		var fee_sol := float(l.get("entryFeeLamports", 0)) / 1_000_000_000.0
		var fee_str := "FREE" if fee_sol == 0.0 else "%.3f SOL" % fee_sol
		var entry := "%s  |  %d/%d  |  %s" % [
			track_name,
			int(l.get("players", 0)),
			int(l.get("maxPlayers", 8)),
			fee_str,
		]
		lobby_list.add_item(entry)

func _on_join_pressed() -> void:
	var sel := lobby_list.get_selected_items()
	if sel.is_empty():
		status_label.text = "Pick a lobby first."
		return
	var lobby = _lobbies[sel[0]]
	var race_id = String(lobby["id"])
	var fee = int(lobby.get("entryFeeLamports", 0))
	if fee > 0 and GameState.wallet_pubkey.is_empty():
		status_label.text = "Connect wallet to enter paid race."
		return
	# Stash lobby args and route through the kart picker before joining.
	GameState.pending_race_id = race_id
	GameState.pending_entry_fee_lamports = fee
	get_tree().change_scene_to_file("res://scenes/KartSelect.tscn")

func _to_race() -> void:
	get_tree().change_scene_to_file("res://scenes/Race.tscn")

func _short(pk: String) -> String:
	if pk.length() <= 10:
		return pk
	return pk.substr(0, 4) + ".." + pk.substr(pk.length() - 4, 4)

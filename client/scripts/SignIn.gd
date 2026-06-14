extends Control
## Sign-in screen — TrenchKart cover art + wallet-connect modal.
## On wallet connect AND name entry → EditProfile.tscn (first time)
##                                  → Home.tscn (returning player)

@onready var modal: Panel = $Modal
@onready var connect_btn: Button = $ConnectFloat/ConnectBtn
@onready var name_input: LineEdit = $Modal/VBox/NameInput
@onready var modal_status: Label = $Modal/VBox/Status
@onready var modal_confirm: Button = $Modal/VBox/Confirm

func _ready() -> void:
	modal.visible = false
	SolanaBridge.wallet_connected.connect(_on_wallet_connected)
	connect_btn.pressed.connect(_open_modal)
	modal_confirm.pressed.connect(_on_confirm)
	# Restore profile if returning user already has one
	GameState.load_profile_from_storage()
	if not GameState.wallet_pubkey.is_empty() and GameState.has_profile():
		_go_home()

func _open_modal() -> void:
	modal_status.text = "Connect a Phantom or Solflare wallet, then pick a racer name."
	name_input.text = GameState.profile_name
	modal.visible = true
	SolanaBridge.connect_wallet()

func _on_wallet_connected(pubkey: String) -> void:
	if pubkey.is_empty():
		modal_status.text = "Wallet did not connect — try again."
		return
	modal_status.text = "Wallet linked: %s..%s" % [pubkey.substr(0, 4), pubkey.substr(pubkey.length() - 4, 4)]

func _on_confirm() -> void:
	var nm := name_input.text.strip_edges()
	if nm.length() < 2:
		modal_status.text = "Pick a name with at least 2 characters."
		return
	if GameState.wallet_pubkey.is_empty():
		modal_status.text = "Connect a wallet first."
		return
	# First time? Go to EditProfile so they can pick a kart icon + bio.
	# Returning? Skip to Home.
	if not GameState.has_profile():
		GameState.set_profile(nm, "", 0)
		get_tree().change_scene_to_file("res://scenes/EditProfile.tscn")
	else:
		GameState.profile_name = nm
		GameState._persist_profile()
		_go_home()

func _go_home() -> void:
	get_tree().change_scene_to_file("res://scenes/Home.tscn")

extends Control
## ModeMenu — Single Player / Grand Prix / Quick Race (2P / 4P / 8P).
## Only Quick Race is wired up; the other two are placeholders.

@onready var single_btn: Button = $Margin/VBox/Modes/SinglePlayer
@onready var gp_btn: Button     = $Margin/VBox/Modes/GrandPrix
@onready var q2_btn: Button     = $Margin/VBox/Modes/QuickRow/Quick2P
@onready var q4_btn: Button     = $Margin/VBox/Modes/QuickRow/Quick4P
@onready var q8_btn: Button     = $Margin/VBox/Modes/QuickRow/Quick8P
@onready var profile_btn: Button = $Margin/VBox/Footer/EditProfile
@onready var sign_out_btn: Button = $Margin/VBox/Footer/SignOut
@onready var status_label: Label = $Margin/VBox/Status

func _ready() -> void:
	MusicPlayer.play_menu()
	# Disable the two modes we haven't built yet.
	single_btn.disabled = true
	single_btn.text = "SINGLE PLAYER  —  COMING SOON"
	gp_btn.disabled = true
	gp_btn.text = "GRAND PRIX  —  COMING SOON"

	q2_btn.pressed.connect(func(): _start_quick(2))
	q4_btn.pressed.connect(func(): _start_quick(4))
	q8_btn.pressed.connect(func(): _start_quick(8))
	profile_btn.pressed.connect(_on_edit_profile)
	sign_out_btn.pressed.connect(_on_sign_out)
	status_label.text = ""

# Start a quick-race matchmaking session. All players who pick the same size
# AND the same map end up in the same room (raceId carries both pieces of
# info, server's filterBy(['raceId']) groups them together).
func _start_quick(size: int) -> void:
	GameState.pending_max_players = size
	GameState.pending_race_id = ""           # MapSelect will set this
	GameState.pending_entry_fee_lamports = 0
	get_tree().change_scene_to_file("res://scenes/MapSelect.tscn")

func _on_edit_profile() -> void:
	get_tree().change_scene_to_file("res://scenes/EditProfile.tscn")

func _on_sign_out() -> void:
	GameState.clear()
	SolanaBridge.storage_set(GameState.PROFILE_KEY, "")
	get_tree().change_scene_to_file("res://scenes/SignIn.tscn")

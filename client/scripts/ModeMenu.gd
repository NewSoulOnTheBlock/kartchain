extends Control
## ModeMenu — Single Player / Grand Prix / Quick Race.
## Only Quick Race is wired up; the other two are placeholders.

@onready var single_btn: Button = $Margin/VBox/Modes/SinglePlayer
@onready var gp_btn: Button     = $Margin/VBox/Modes/GrandPrix
@onready var quick_btn: Button  = $Margin/VBox/Modes/QuickRace
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

	quick_btn.pressed.connect(_on_quick)
	profile_btn.pressed.connect(_on_edit_profile)
	sign_out_btn.pressed.connect(_on_sign_out)
	status_label.text = ""

func _on_quick() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_edit_profile() -> void:
	get_tree().change_scene_to_file("res://scenes/EditProfile.tscn")

func _on_sign_out() -> void:
	GameState.clear()
	SolanaBridge.storage_set(GameState.PROFILE_KEY, "")
	get_tree().change_scene_to_file("res://scenes/SignIn.tscn")

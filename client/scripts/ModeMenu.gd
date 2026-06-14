extends Control
## ModeMenu — Single Player / Grand Prix / Quick Race.
## All three currently route to the lobby (Main.tscn). Tweak the routes
## later to map each mode to its own room type.

@onready var single_btn: Button = $Margin/VBox/Modes/SinglePlayer
@onready var gp_btn: Button     = $Margin/VBox/Modes/GrandPrix
@onready var quick_btn: Button  = $Margin/VBox/Modes/QuickRace
@onready var profile_btn: Button = $Margin/VBox/Footer/EditProfile
@onready var sign_out_btn: Button = $Margin/VBox/Footer/SignOut

func _ready() -> void:
	single_btn.pressed.connect(_on_single)
	gp_btn.pressed.connect(_on_gp)
	quick_btn.pressed.connect(_on_quick)
	profile_btn.pressed.connect(_on_edit_profile)
	sign_out_btn.pressed.connect(_on_sign_out)

func _on_single() -> void:
	# TODO: dedicated single-player local mode. For MVP route to lobby.
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_gp() -> void:
	# TODO: Grand Prix (3-track championship). For MVP route to lobby.
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_quick() -> void:
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

func _on_edit_profile() -> void:
	get_tree().change_scene_to_file("res://scenes/EditProfile.tscn")

func _on_sign_out() -> void:
	GameState.clear()
	SolanaBridge.storage_set(GameState.PROFILE_KEY, "")
	get_tree().change_scene_to_file("res://scenes/SignIn.tscn")

extends Control
## Kart picker — grid of 18 STK racers with their icons.
## Triggered by Main.gd before joining a race room.
##
## Flow:
##   Main → "Join Race" → KartSelect (this) → "Confirm" → Race
##
## Reads from KartCatalog autoload; writes to GameState.selected_kart_type;
## then either calls SolanaBridge.sign_and_send_enter_race (paid) or
## NetworkClient.join_race (free) and changes scene to Race.tscn.

@onready var title_label: Label = $Margin/VBox/Title
@onready var grid: GridContainer = $Margin/VBox/Scroll/Grid
@onready var info_label: Label = $Margin/VBox/Info
@onready var confirm_button: Button = $Margin/VBox/Buttons/Confirm
@onready var back_button: Button = $Margin/VBox/Buttons/Back

# Pending lobby args, passed in via set_pending_lobby() before this scene shows.
var _pending_race_id: String = ""
var _pending_entry_fee_lamports: int = 0

# Currently highlighted kart index in KartCatalog.karts
var _selected_idx: int = 0
var _kart_buttons: Array[Button] = []

const ICON_BASE_SIZE := Vector2(140, 140)

func _ready() -> void:
	MusicPlayer.stop()
	confirm_button.pressed.connect(_on_confirm_pressed)
	back_button.pressed.connect(_on_back_pressed)

	_pending_race_id = GameState.pending_race_id
	_pending_entry_fee_lamports = GameState.pending_entry_fee_lamports

	if _pending_race_id.is_empty():
		# Shouldn't happen, but bounce back if we landed here directly.
		_on_back_pressed()
		return

	title_label.text = "PICK YOUR RACER"
	_populate_grid()
	_select(GameState.selected_kart_type)

func _populate_grid() -> void:
	# Clear any pre-existing children (re-entry safety)
	for c in grid.get_children():
		c.queue_free()
	_kart_buttons.clear()

	var karts := KartCatalog.karts
	if karts.is_empty():
		info_label.text = "No karts found — catalog missing."
		confirm_button.disabled = true
		return

	for i in karts.size():
		var k: Dictionary = karts[i]
		var btn := Button.new()
		btn.custom_minimum_size = ICON_BASE_SIZE
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.expand_icon = true
		btn.tooltip_text = String(k.get("name", "?"))
		# Vertical layout: icon on top, name below
		btn.text = String(k.get("name", "?"))
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		# Try to load the kart icon
		var icon_rel := String(k.get("icon", ""))
		if not icon_rel.is_empty():
			var icon_path := "res://" + icon_rel
			if ResourceLoader.exists(icon_path):
				var tex: Texture2D = load(icon_path)
				if tex:
					btn.icon = tex
		var idx := i
		btn.pressed.connect(func(): _select(idx))
		grid.add_child(btn)
		_kart_buttons.append(btn)

func _select(idx: int) -> void:
	if KartCatalog.karts.is_empty():
		return
	if idx < 0 or idx >= KartCatalog.karts.size():
		idx = 0
	_selected_idx = idx
	for i in _kart_buttons.size():
		_kart_buttons[i].button_pressed = (i == idx)
	var k: Dictionary = KartCatalog.karts[idx]
	var stats: Dictionary = k.get("stats", {})
	info_label.text = "%s   |   Type: %s   |   Speed %d  Acc %d  Hdl %d" % [
		String(k.get("name", "?")),
		String(k.get("type", "?")),
		int(round(float(stats.get("topSpeed", 0.5)) * 100)),
		int(round(float(stats.get("accel", 0.5)) * 100)),
		int(round(float(stats.get("handling", 0.5)) * 100)),
	]

func _on_confirm_pressed() -> void:
	GameState.select_kart(_selected_idx)
	if _pending_entry_fee_lamports > 0:
		if GameState.wallet_pubkey.is_empty():
			info_label.text = "Connect wallet first to enter a paid race."
			return
		SolanaBridge.sign_and_send_enter_race(_pending_race_id, _pending_entry_fee_lamports)
	else:
		NetworkClient.join_race(_pending_race_id)
	GameState.pending_race_id = ""
	GameState.pending_entry_fee_lamports = 0
	get_tree().change_scene_to_file("res://scenes/Race.tscn")

func _on_back_pressed() -> void:
	GameState.pending_race_id = ""
	GameState.pending_entry_fee_lamports = 0
	get_tree().change_scene_to_file("res://scenes/Main.tscn")

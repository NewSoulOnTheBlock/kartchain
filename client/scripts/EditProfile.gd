extends Control
## EditProfile — pick a kart icon as PFP, set name + bio.

@onready var name_input: LineEdit = $Margin/VBox/Form/NameInput
@onready var bio_input: TextEdit  = $Margin/VBox/Form/BioInput
@onready var pfp_grid: GridContainer = $Margin/VBox/PFP/Scroll/Grid
@onready var pfp_preview: TextureRect = $Margin/VBox/PFP/Preview
@onready var save_btn: Button = $Margin/VBox/Buttons/Save
@onready var skip_btn: Button = $Margin/VBox/Buttons/Skip

var _selected_pfp: int = 0
var _pfp_buttons: Array[Button] = []

func _ready() -> void:
	name_input.text = GameState.profile_name
	bio_input.text = GameState.profile_bio
	_selected_pfp = GameState.profile_pfp_index

	save_btn.pressed.connect(_on_save)
	skip_btn.pressed.connect(_on_save)  # Skip = save current values
	_populate_pfp_grid()
	_refresh_preview()

func _populate_pfp_grid() -> void:
	for c in pfp_grid.get_children():
		c.queue_free()
	_pfp_buttons.clear()
	for i in KartCatalog.karts.size():
		var k: Dictionary = KartCatalog.karts[i]
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(72, 72)
		btn.toggle_mode = true
		btn.focus_mode = Control.FOCUS_NONE
		btn.expand_icon = true
		btn.tooltip_text = String(k.get("name", "?"))
		var icon_rel := String(k.get("icon", ""))
		if not icon_rel.is_empty():
			var p := "res://" + icon_rel
			if ResourceLoader.exists(p):
				btn.icon = load(p)
		var idx := i
		btn.pressed.connect(func(): _select(idx))
		pfp_grid.add_child(btn)
		_pfp_buttons.append(btn)
	_select(_selected_pfp)

func _select(idx: int) -> void:
	if idx < 0 or idx >= _pfp_buttons.size():
		return
	_selected_pfp = idx
	for i in _pfp_buttons.size():
		_pfp_buttons[i].button_pressed = (i == idx)
	_refresh_preview()

func _refresh_preview() -> void:
	if KartCatalog.karts.is_empty():
		return
	var k: Dictionary = KartCatalog.karts[_selected_pfp]
	var icon_rel := String(k.get("icon", ""))
	if not icon_rel.is_empty():
		var p := "res://" + icon_rel
		if ResourceLoader.exists(p):
			pfp_preview.texture = load(p)

func _on_save() -> void:
	var nm := name_input.text.strip_edges()
	if nm.length() < 2:
		nm = GameState.profile_name
	GameState.set_profile(nm, bio_input.text.strip_edges(), _selected_pfp)
	get_tree().change_scene_to_file("res://scenes/Home.tscn")

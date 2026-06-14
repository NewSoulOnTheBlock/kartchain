extends Control
## Kart picker — grid of 18 STK racers with their icons + a live 3D preview.
## Triggered by Main.gd before joining a race room.
##
## Flow:
##   Main → "Join Race" → KartSelect (this) → "Confirm" → Race
##
## Reads from KartCatalog autoload; writes to GameState.selected_kart_type;
## then either calls SolanaBridge.sign_and_send_enter_race (paid) or
## NetworkClient.join_race (free) and changes scene to Race.tscn.

@onready var title_label: Label = $Margin/VBox/Title
@onready var grid: GridContainer = $Margin/VBox/MainRow/Scroll/Grid
@onready var info_label: Label = $Margin/VBox/Info
@onready var confirm_button: Button = $Margin/VBox/Buttons/Confirm
@onready var back_button: Button = $Margin/VBox/Buttons/Back
@onready var preview_label: Label = $Margin/VBox/MainRow/PreviewPanel/PreviewVBox/PreviewLabel
@onready var kart_pivot: Node3D = $Margin/VBox/MainRow/PreviewPanel/PreviewVBox/Viewport/SubViewport/KartPivot

# Pending lobby args, passed in via set_pending_lobby() before this scene shows.
var _pending_race_id: String = ""
var _pending_entry_fee_lamports: int = 0

# Currently highlighted kart index in KartCatalog.karts
var _selected_idx: int = -1
var _kart_buttons: Array[Button] = []
var _preview_model: Node3D = null

const ICON_BASE_SIZE := Vector2(140, 140)
# Yaw speed for the showcase spin (radians/sec). Tweak to taste.
const PREVIEW_SPIN_SPEED := 0.9

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

func _process(delta: float) -> void:
	# Slow turntable rotation on the preview kart.
	if kart_pivot:
		kart_pivot.rotate_y(PREVIEW_SPIN_SPEED * delta)

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
	# Skip work + preview reload if nothing changed (cheap re-clicks).
	var changed := idx != _selected_idx
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
	if changed:
		_show_preview(idx, k)

# Load the kart's .glb into the SubViewport, center + scale to fit the cam.
func _show_preview(idx: int, k: Dictionary) -> void:
	if kart_pivot == null:
		return
	preview_label.text = String(k.get("name", "?")).to_upper()
	# Wipe the previous model
	if _preview_model and is_instance_valid(_preview_model):
		_preview_model.queue_free()
		_preview_model = null
	# Reset pivot rotation so each new kart starts facing camera
	kart_pivot.rotation = Vector3.ZERO
	var path := KartCatalog.kart_model_path(idx)
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var scene: PackedScene = load(path)
	if scene == null:
		return
	_preview_model = scene.instantiate()
	kart_pivot.add_child(_preview_model)
	# Center + scale the model so it fills the preview viewport reliably.
	# STK kart .glbs come in at roughly real-world meter scale already, but
	# computing the AABB makes this work for any model — including future
	# custom karts that might be larger or smaller.
	var aabb := _compute_aabb(_preview_model)
	if aabb.size.length() > 0.001:
		var center := aabb.position + aabb.size * 0.5
		_preview_model.position = -center
		var max_dim: float = max(aabb.size.x, max(aabb.size.y, aabb.size.z))
		if max_dim > 0.001:
			# Target ~1.8 m max dimension; camera at (0, 1.5, 3.5) fov=38 fits this nicely.
			var scale_factor: float = 1.8 / max_dim
			_preview_model.scale = Vector3.ONE * scale_factor
			_preview_model.position *= scale_factor

# Recursively unions the AABB of every VisualInstance3D under `root`.
func _compute_aabb(root: Node3D) -> AABB:
	var combined: AABB = AABB()
	var first: bool = true
	var stack: Array = [root]
	while stack.size() > 0:
		var node = stack.pop_back()
		if node is VisualInstance3D:
			var v: VisualInstance3D = node
			var local_aabb := v.get_aabb()
			# Transform AABB into root's local space
			var world_aabb := v.global_transform * local_aabb
			var root_inv := root.global_transform.affine_inverse()
			var rel_aabb := root_inv * world_aabb
			if first:
				combined = rel_aabb
				first = false
			else:
				combined = combined.merge(rel_aabb)
		for c in node.get_children():
			if c is Node3D:
				stack.append(c)
	return combined

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
	# If we came from MapSelect (which only sets pending_max_players),
	# the user probably wants to re-pick the map, not bounce to Main.
	if GameState.pending_max_players > 0:
		get_tree().change_scene_to_file("res://scenes/MapSelect.tscn")
	else:
		get_tree().change_scene_to_file("res://scenes/Main.tscn")


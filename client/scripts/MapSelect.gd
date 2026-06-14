extends Control
## MapSelect — pick a bundled track for the chosen Quick Race room size.
##
## Enters this scene after ModeMenu sets:
##   GameState.pending_max_players  (2 / 4 / 8)
## Exits to KartSelect with:
##   GameState.pending_race_id      = "quick-Np-<trackId>"
##   GameState.pending_entry_fee_lamports = 0
##
## All players who pick the same (size, trackId) end up in the same room
## thanks to Colyseus's `filterBy(['raceId'])`.

@onready var cards_row: HBoxContainer = $Margin/VBox/Cards
@onready var title_label: Label       = $Margin/VBox/Title
@onready var status_label: Label      = $Margin/VBox/Footer/Status
@onready var back_btn: Button         = $Margin/VBox/Footer/Back

const CARD_MIN_SIZE := Vector2(360, 420)

func _ready() -> void:
	MusicPlayer.play_menu()
	back_btn.pressed.connect(_on_back)
	var size := GameState.pending_max_players
	if size <= 0:
		size = 2
		GameState.pending_max_players = 2
	title_label.text = "CHOOSE A MAP   (%dP RACE)" % size
	_populate()

func _populate() -> void:
	for c in cards_row.get_children():
		c.queue_free()
	# Only show tracks whose scene.xml is bundled in the current pck.
	var bundled: Array = []
	for t in KartCatalog.tracks:
		var id := String(t.get("id", ""))
		if id.is_empty():
			continue
		if t.get("isArena", false) or t.get("isSoccer", false) or t.get("isCutscene", false):
			continue
		if KartCatalog.has_bundled_track(id):
			bundled.append(t)
	if bundled.is_empty():
		status_label.text = "No bundled tracks found — check your Godot export."
		return
	for t in bundled:
		cards_row.add_child(_build_card(t))

func _build_card(t: Dictionary) -> Control:
	var id := String(t.get("id", ""))
	var name := String(t.get("name", id))
	var btn := Button.new()
	btn.custom_minimum_size = CARD_MIN_SIZE
	btn.focus_mode = Control.FOCUS_NONE
	btn.clip_contents = true
	btn.tooltip_text = name
	# Big vertical layout inside the button: screenshot on top, name below
	var v := VBoxContainer.new()
	v.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_theme_constant_override("separation", 0)
	var img := TextureRect.new()
	img.size_flags_vertical = Control.SIZE_EXPAND_FILL
	img.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shot_path := _resolve_screenshot(t)
	if shot_path != "" and ResourceLoader.exists(shot_path):
		var tex: Texture2D = load(shot_path)
		if tex != null:
			img.texture = tex
	v.add_child(img)
	var label := Label.new()
	label.text = name.to_upper()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 26)
	label.add_theme_color_override("font_color", Color(1, 0.95, 0.45, 1))
	label.custom_minimum_size = Vector2(0, 60)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(label)
	btn.add_child(v)
	var pid := id
	btn.pressed.connect(func(): _on_pick(pid))
	return btn

func _resolve_screenshot(t: Dictionary) -> String:
	var shot := String(t.get("screenshot", ""))
	if not shot.is_empty():
		var explicit := "res://" + shot
		if FileAccess.file_exists(explicit):
			return explicit
	# Fallbacks if the catalog entry is missing the field or points at a
	# file that wasn't bundled in this export.
	var id := String(t.get("id", ""))
	var base := "res://tracks/%s/" % id
	var candidates := [
		base + "screenshot.jpg",
		base + "screenshot.png",
		base + "test_track_postcard.jpg",
		base + "postcard.jpg",
		# STK's original convention is sshot-<name>.jpg, but <name> doesn't
		# always match the directory id (e.g. snowmountain uses sshot-mountain.jpg).
		base + "sshot-%s.jpg" % id,
	]
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	# Final fallback: any sshot-*.jpg in the track dir picks up the rest.
	return _find_sshot_in_dir(base)

func _find_sshot_in_dir(base: String) -> String:
	var dir := DirAccess.open(base)
	if dir == null:
		return ""
	dir.list_dir_begin()
	var found := ""
	while true:
		var fname := dir.get_next()
		if fname == "":
			break
		if dir.current_is_dir():
			continue
		var lower := fname.to_lower()
		if lower.begins_with("sshot-") and (lower.ends_with(".jpg") or lower.ends_with(".png")):
			found = base + fname
			break
	dir.list_dir_end()
	return found

func _on_pick(track_id: String) -> void:
	var size := max(2, GameState.pending_max_players)
	# Note: raceId encodes BOTH the room size AND the chosen map so that
	# Colyseus's filterBy(['raceId']) groups matching picks into the same room.
	GameState.pending_race_id = "quick-%dp-%s" % [size, track_id]
	GameState.pending_entry_fee_lamports = 0
	get_tree().change_scene_to_file("res://scenes/KartSelect.tscn")

func _on_back() -> void:
	get_tree().change_scene_to_file("res://scenes/ModeMenu.tscn")

extends Control
## Home screen — TrenchKart bg + flashing "PRESS START" like an N64 boot menu.
## Any key, mouse click, or gamepad button → ModeMenu.tscn

@onready var press_label: Label = $PressStart
@onready var name_label: Label = $Margin/VBox/NameRow/NameLabel

var _flash_t: float = 0.0

func _ready() -> void:
	name_label.text = "PLAYER: " + GameState.profile_name.to_upper()

func _process(delta: float) -> void:
	# Two-state flash like N64 menus — fully visible for 0.6s, hidden for 0.4s.
	_flash_t += delta
	if _flash_t > 1.0:
		_flash_t = 0.0
	press_label.visible = _flash_t < 0.6

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		_go()
	elif event is InputEventMouseButton and event.pressed:
		_go()
	elif event is InputEventJoypadButton and event.pressed:
		_go()

func _go() -> void:
	get_tree().change_scene_to_file("res://scenes/ModeMenu.tscn")

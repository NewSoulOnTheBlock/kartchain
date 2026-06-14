extends Camera3D
## FreeCam — debug spectator camera you can fly around with.
##
## Controls (while enabled):
##   Right-click (hold)  capture mouse for look
##   Mouse              look
##   WASD               horizontal move
##   Space              up
##   Ctrl               down
##   Shift              x4 boost
##   T                  teleport to local kart (if any)
##   Y                  set this position as kart spawn point (respawns local kart)
##
## Race.gd toggles this with F1.

@export var move_speed: float = 25.0
@export var boost_mult: float = 4.0
@export var look_sensitivity: float = 0.003

var enabled: bool = false
var local_kart_ref: Node3D = null    # set by Race.gd
var race_ref: Node = null            # set by Race.gd — used for "Y" spawn-set

var _yaw: float = 0.0
var _pitch: float = 0.0
var _looking: bool = false

func _ready() -> void:
	# Capture starting orientation
	_yaw = rotation.y
	_pitch = rotation.x

func enable(on: bool) -> void:
	enabled = on
	if not on:
		_release_mouse()

func _input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_capture_mouse()
			else:
				_release_mouse()
	elif event is InputEventMouseMotion and _looking:
		var mm := event as InputEventMouseMotion
		_yaw   -= mm.relative.x * look_sensitivity
		_pitch -= mm.relative.y * look_sensitivity
		_pitch = clamp(_pitch, -1.4, 1.4)
		rotation = Vector3(_pitch, _yaw, 0)
	elif event is InputEventKey and event.pressed and not event.echo:
		var k := event as InputEventKey
		if k.keycode == KEY_T:
			_teleport_to_kart()
		elif k.keycode == KEY_Y:
			_set_spawn_here()

func _process(delta: float) -> void:
	if not enabled:
		return
	var forward := -transform.basis.z
	var right   :=  transform.basis.x
	var up      := Vector3.UP
	var move := Vector3.ZERO
	if Input.is_key_pressed(KEY_W): move += forward
	if Input.is_key_pressed(KEY_S): move -= forward
	if Input.is_key_pressed(KEY_D): move += right
	if Input.is_key_pressed(KEY_A): move -= right
	if Input.is_key_pressed(KEY_SPACE):  move += up
	if Input.is_key_pressed(KEY_CTRL):   move -= up
	if move != Vector3.ZERO:
		move = move.normalized()
		var speed := move_speed * (boost_mult if Input.is_key_pressed(KEY_SHIFT) else 1.0)
		global_position += move * speed * delta

func _teleport_to_kart() -> void:
	if local_kart_ref and is_instance_valid(local_kart_ref):
		global_position = local_kart_ref.global_position + Vector3(0, 4, 8)
		# Look at the kart
		look_at(local_kart_ref.global_position, Vector3.UP)
		_yaw = rotation.y
		_pitch = rotation.x

# Y key — claim this camera position as the kart spawn point.
# Asks Race.gd to apply the offset and respawn the local kart there.
func _set_spawn_here() -> void:
	if race_ref and race_ref.has_method("set_spawn_at_world_position"):
		race_ref.set_spawn_at_world_position(global_position)

func _capture_mouse() -> void:
	_looking = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _release_mouse() -> void:
	_looking = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

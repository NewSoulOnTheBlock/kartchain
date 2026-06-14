extends Node
## Background music controller for menu screens.
##
## Autoload — persists across scene changes so navigating between
## SignIn → EditProfile → Home → ModeMenu does not restart the song.
## Call MusicPlayer.play_menu() in the _ready() of any menu scene
## and MusicPlayer.stop() when entering gameplay (Main lobby / KartSelect / Race).
##
## stop() fades out over FADE_SEC seconds rather than cutting hard, so the
## transition into the Race scene doesn't feel jarring.

const MENU_STREAM_PATH := "res://assets/menu_music.mp3"
const FADE_SEC: float = 0.5
const BASE_VOLUME_DB: float = -10.0

var _player: AudioStreamPlayer
var _stream: AudioStream
var _fade_tween: Tween

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	_player.volume_db = BASE_VOLUME_DB
	add_child(_player)

	if ResourceLoader.exists(MENU_STREAM_PATH):
		_stream = load(MENU_STREAM_PATH)
		# Make the MP3 loop forever so it doesn't end mid-menu.
		if _stream is AudioStreamMP3:
			(_stream as AudioStreamMP3).loop = true
		_player.stream = _stream
	else:
		push_warning("MusicPlayer: missing %s" % MENU_STREAM_PATH)

func play_menu() -> void:
	if _player == null or _stream == null:
		return
	_kill_fade()
	_player.volume_db = BASE_VOLUME_DB
	if _player.playing:
		return
	_player.play()

func stop() -> void:
	if _player == null or not _player.playing:
		return
	_kill_fade()
	_fade_tween = create_tween()
	_fade_tween.tween_property(_player, "volume_db", -40.0, FADE_SEC)
	_fade_tween.tween_callback(_player.stop)
	_fade_tween.tween_callback(func(): _player.volume_db = BASE_VOLUME_DB)

func _kill_fade() -> void:
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = null

func set_volume_db(db: float) -> void:
	if _player != null:
		_player.volume_db = db

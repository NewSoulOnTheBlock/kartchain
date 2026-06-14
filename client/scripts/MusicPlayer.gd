extends Node
## Background music controller for menu screens.
##
## Autoload — persists across scene changes so navigating between
## SignIn → EditProfile → Home → ModeMenu does not restart the song.
## Call MusicPlayer.play_menu() in the _ready() of any menu scene
## and MusicPlayer.stop() when entering gameplay (Main lobby / KartSelect / Race).

const MENU_STREAM_PATH := "res://assets/menu_music.mp3"

var _player: AudioStreamPlayer
var _stream: AudioStream

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	_player.volume_db = -10.0
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
	if _player.playing:
		return
	_player.play()

func stop() -> void:
	if _player == null:
		return
	if _player.playing:
		_player.stop()

func set_volume_db(db: float) -> void:
	if _player != null:
		_player.volume_db = db

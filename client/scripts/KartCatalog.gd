extends Node
## KartCatalog (autoload)
## Loads the STK kart + track catalog produced by
## assets-import/import-stk-catalog.mjs.
##
## Provides simple lookups for:
##   - kart model res:// path by kartType index
##   - track main mesh res:// path by track id
##
## Falls back to null / empty arrays if the catalog file is missing.

var karts: Array = []     # Array of Dictionary
var tracks: Array = []    # Array of Dictionary

func _ready() -> void:
	_load_karts()
	_load_tracks()
	print("[catalog] karts=%d tracks=%d" % [karts.size(), tracks.size()])

func _load_karts() -> void:
	var f = FileAccess.open("res://karts/_catalog.json", FileAccess.READ)
	if f == null:
		push_warning("[catalog] no karts/_catalog.json — run assets-import/import-stk-catalog.mjs")
		return
	var json = JSON.parse_string(f.get_as_text())
	if json is Dictionary and json.has("karts"):
		karts = json["karts"]

func _load_tracks() -> void:
	var f = FileAccess.open("res://tracks/_catalog.json", FileAccess.READ)
	if f == null:
		push_warning("[catalog] no tracks/_catalog.json")
		return
	var json = JSON.parse_string(f.get_as_text())
	if json is Dictionary and json.has("tracks"):
		tracks = json["tracks"]

## Returns the res:// path to a kart's .glb (converted from .spm),
## or empty string if not found. `kart_type` is an integer index into
## the catalog; 0 = first kart (alphabetical) = "adiumy" by default.
## Negative/oversized indices wrap.
func kart_model_path(kart_type: int) -> String:
	if karts.is_empty():
		return ""
	var idx = kart_type % karts.size()
	if idx < 0:
		idx += karts.size()
	var k = karts[idx]
	# .model in catalog is e.g. "karts/tux/tux.spm" — swap to .glb
	var spm_rel = String(k.get("model", ""))
	if spm_rel.is_empty():
		return ""
	var glb_rel = spm_rel.replace(".spm", ".glb")
	return "res://" + glb_rel

func kart_name(kart_type: int) -> String:
	if karts.is_empty():
		return ""
	var idx = kart_type % karts.size()
	if idx < 0:
		idx += karts.size()
	return String(karts[idx].get("name", "?"))

## Returns res:// path for the main mesh of a track id, or empty.
func track_model_path(track_id: String) -> String:
	for t in tracks:
		if String(t.get("id", "")) == track_id:
			var spm_rel = String(t.get("mainModel", ""))
			if spm_rel.is_empty():
				return ""
			return "res://" + spm_rel.replace(".spm", ".glb")
	return ""

## Returns true when this track's scene.xml is present in the running
## build. Used by the lobby UI to hide rows that the WASM bundle didn't
## ship — otherwise players join a "racing" room and see only the
## placeholder ground plane.
##
## NOTE: we use FileAccess.file_exists() rather than ResourceLoader.exists()
## because scene.xml is shipped as a raw file via the export preset's
## include_filter (*.xml,*.json) — it has no .import sidecar so the
## ResourceLoader doesn't know about it. TrackLoader.load_track() opens
## the same file with FileAccess, so this check matches what actually
## works at runtime.
func has_bundled_track(track_id: String) -> bool:
	if track_id.is_empty():
		return false
	return FileAccess.file_exists("res://tracks/%s/scene.xml" % track_id)

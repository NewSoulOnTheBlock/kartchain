extends PanelContainer
## Leaderboard — live sorted standings shown during a race.
##
## Adapted from https://github.com/mujtaba-io/race-game
## (Players/UI/PlayerUI.gd). The original sorted by elapsed timer and
## displayed all players; ours sorts by the server's `position` field
## (authoritative — the Colyseus race room computes it) with ties
## broken by lap count, and shows lap + kart name + a (YOU) marker.

const _ROW_FONT_SIZE: int = 16
const _TITLE_FONT_SIZE: int = 18
const _LOCAL_COLOR: Color = Color(1.00, 0.95, 0.45)
const _REMOTE_COLOR: Color = Color(1.00, 1.00, 1.00)
const _DIM_COLOR: Color = Color(0.65, 0.65, 0.70)

@onready var title: Label = $Margin/VBox/Title
@onready var rows: VBoxContainer = $Margin/VBox/Rows

func _ready() -> void:
	NetworkClient.race_state.connect(_on_race_state)
	title.text = "STANDINGS"
	rows.add_theme_constant_override("separation", 2)

func _on_race_state(state: Dictionary) -> void:
	var karts_raw = state.get("karts", {})
	if not (karts_raw is Dictionary):
		return
	var total_laps: int = int(state.get("totalLaps", 3))
	title.text = "STANDINGS  •  LAP %d" % total_laps
	var sorted_rows: Array = sort_rows(karts_raw)
	_render(sorted_rows)

## Pure helper — separated for unit tests. Returns an Array of Dictionaries
## sorted by server `position` ascending (1 = leader), with ties broken by
## higher `lap` first.
static func sort_rows(karts_raw: Dictionary) -> Array:
	var out: Array = []
	for pid_var in karts_raw.keys():
		var pid: String = String(pid_var)
		var k = karts_raw[pid_var]
		if not (k is Dictionary):
			continue
		out.append({
			"pid": pid,
			"position": int(k.get("position", 999)),
			"lap": int(k.get("lap", 0)),
			"kart_type": int(k.get("kartType", 0)),
		})
	out.sort_custom(func(a, b):
		if a["position"] != b["position"]:
			return a["position"] < b["position"]
		if a["lap"] != b["lap"]:
			return a["lap"] > b["lap"]
		return a["pid"] < b["pid"]
	)
	return out

func _render(sorted_rows: Array) -> void:
	_ensure_row_count(sorted_rows.size())
	var local_id: String = _local_player_id()
	for i in sorted_rows.size():
		var r: Dictionary = sorted_rows[i]
		var label: Label = rows.get_child(i) as Label
		var is_me: bool = r["pid"] == local_id and not local_id.is_empty()
		var name: String = KartCatalog.kart_name(int(r["kart_type"]))
		if name.is_empty():
			name = "Kart " + String(r["pid"]).substr(0, 6)
		var marker: String = "  (YOU)" if is_me else ""
		label.text = "%d.  %s%s   —   Lap %d" % [int(r["position"]), name, marker, int(r["lap"])]
		label.modulate = _LOCAL_COLOR if is_me else _REMOTE_COLOR

func _local_player_id() -> String:
	var scn: Node = get_tree().current_scene
	if scn and "local_player_id" in scn:
		return String(scn.local_player_id)
	return ""

func _ensure_row_count(n: int) -> void:
	while rows.get_child_count() < n:
		var label: Label = Label.new()
		label.add_theme_font_size_override("font_size", _ROW_FONT_SIZE)
		label.modulate = _REMOTE_COLOR
		rows.add_child(label)
	while rows.get_child_count() > n:
		var last: Node = rows.get_child(rows.get_child_count() - 1)
		rows.remove_child(last)
		last.queue_free()

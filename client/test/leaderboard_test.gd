extends GdUnitTestSuite
## Tests for Leaderboard.sort_rows — pure helper, no scene/runtime deps.

const Leaderboard = preload("res://scripts/Leaderboard.gd")

func test_sorts_by_server_position_ascending() -> void:
	var karts := {
		"p1": {"position": 3, "lap": 1, "kartType": 0},
		"p2": {"position": 1, "lap": 2, "kartType": 1},
		"p3": {"position": 2, "lap": 1, "kartType": 2},
	}
	var out: Array = Leaderboard.sort_rows(karts)
	assert_that(out.size()).is_equal(3)
	assert_that(out[0]["pid"]).is_equal("p2")
	assert_that(out[1]["pid"]).is_equal("p3")
	assert_that(out[2]["pid"]).is_equal("p1")

func test_breaks_position_ties_by_higher_lap_first() -> void:
	var karts := {
		"a": {"position": 1, "lap": 1, "kartType": 0},
		"b": {"position": 1, "lap": 3, "kartType": 0},
		"c": {"position": 1, "lap": 2, "kartType": 0},
	}
	var out: Array = Leaderboard.sort_rows(karts)
	assert_that(out[0]["pid"]).is_equal("b")
	assert_that(out[1]["pid"]).is_equal("c")
	assert_that(out[2]["pid"]).is_equal("a")

func test_skips_non_dict_entries() -> void:
	var karts := {
		"ok": {"position": 1, "lap": 0, "kartType": 0},
		"bad": "not a dict",
	}
	var out: Array = Leaderboard.sort_rows(karts)
	assert_that(out.size()).is_equal(1)
	assert_that(out[0]["pid"]).is_equal("ok")

func test_handles_missing_fields_with_defaults() -> void:
	var karts := { "x": {} }
	var out: Array = Leaderboard.sort_rows(karts)
	assert_that(out.size()).is_equal(1)
	assert_that(int(out[0]["position"])).is_equal(999)
	assert_that(int(out[0]["lap"])).is_equal(0)
	assert_that(int(out[0]["kart_type"])).is_equal(0)

func test_empty_input_returns_empty_array() -> void:
	var out: Array = Leaderboard.sort_rows({})
	assert_that(out.size()).is_equal(0)

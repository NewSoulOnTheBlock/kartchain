extends GdUnitTestSuite
## Pure-function tests for TrackLoader autoload.

func test_grid_slot_two_per_row() -> void:
	# Row 0: cols 0 and 1 → -0.75 / +0.75 X, z=0
	var s0 := TrackLoader.grid_slot(0)
	var s1 := TrackLoader.grid_slot(1)
	assert_that(s0).is_equal(Vector3(-0.75, 0.0, 0.0))
	assert_that(s1).is_equal(Vector3( 0.75, 0.0, 0.0))

func test_grid_slot_second_row() -> void:
	# Row 1: cols 0 and 1 → -0.75 / +0.75 X, z=3
	var s2 := TrackLoader.grid_slot(2)
	var s3 := TrackLoader.grid_slot(3)
	assert_that(s2).is_equal(Vector3(-0.75, 0.0, 3.0))
	assert_that(s3).is_equal(Vector3( 0.75, 0.0, 3.0))

func test_grid_slot_eighth_player() -> void:
	# 8 players = 4 rows. Slot 7 is row 3, col 1.
	var s7 := TrackLoader.grid_slot(7)
	assert_that(s7).is_equal(Vector3(0.75, 0.0, 9.0))

func test_spawn_offset_returns_default_for_any_track() -> void:
	# After the cleanup, all tracks share a single 2m lift default.
	assert_that(TrackLoader.spawn_offset("lighthouse")).is_equal(Vector3(0, 2, 0))
	assert_that(TrackLoader.spawn_offset("does_not_exist")).is_equal(Vector3(0, 2, 0))
	assert_that(TrackLoader.spawn_offset("")).is_equal(Vector3(0, 2, 0))

func test_ground_lift_constant() -> void:
	# Karts spawn slightly above the ground so wheels don't interpenetrate.
	assert_that(TrackLoader.GROUND_LIFT).is_greater(0.0)
	assert_that(TrackLoader.GROUND_LIFT).is_less(2.0)

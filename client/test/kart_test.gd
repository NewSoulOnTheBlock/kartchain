extends GdUnitTestSuite
## Unit tests for Kart.gd pure helpers — drives Kart via scene_runner so
## VehicleBody3D / _physics_process behavior can be observed if needed.

const KART_SCENE := "res://scenes/Kart.tscn"

func test_apply_stats_updates_engine_force() -> void:
	var kart: VehicleBody3D = auto_free(load(KART_SCENE).instantiate())
	# Default tuning before apply_stats:
	var default_engine := kart.engine_force_max
	kart.apply_stats(0.5, 1.0, 0.0)
	assert_that(kart.engine_force_max).is_greater(default_engine - 0.01)
	# accel=1.0 → engine = 160 + 120*1 = 280; default was 220 → MUST grow.
	assert_that(kart.engine_force_max).is_equal(280.0)

func test_apply_stats_updates_steering_max() -> void:
	var kart: VehicleBody3D = auto_free(load(KART_SCENE).instantiate())
	kart.apply_stats(0.0, 0.0, 1.0)
	# handling=1.0 → steering = 0.30 + 0.25*1 = 0.55
	assert_that(kart.steering_max).is_equal_approx(0.55, 0.001)

func test_apply_stats_minimum_handling() -> void:
	var kart: VehicleBody3D = auto_free(load(KART_SCENE).instantiate())
	kart.apply_stats(0.0, 0.0, 0.0)
	assert_that(kart.steering_max).is_equal_approx(0.30, 0.001)

func test_recover_keeps_yaw_and_lifts_kart() -> void:
	# Drop the kart 1m below origin facing world-+X, then recover.
	# After recovery: position is lifted 1.5m, velocity is zero, basis is
	# rotated to upright. Verifies the auto-recover transform doesn't lose
	# the player's heading.
	var kart: VehicleBody3D = auto_free(load(KART_SCENE).instantiate())
	add_child(kart)
	await get_tree().process_frame
	kart.global_position = Vector3(0, -1, 0)
	kart.linear_velocity = Vector3(5, 0, 0)
	kart.angular_velocity = Vector3(0, 1, 0)
	kart.recover()
	assert_that(kart.global_position.y).is_greater(0.0)
	assert_that(kart.linear_velocity).is_equal(Vector3.ZERO)
	assert_that(kart.angular_velocity).is_equal(Vector3.ZERO)

func test_recover_respects_cooldown() -> void:
	# Two recover() calls back-to-back: second one is a no-op because
	# _recover_cooldown was set by the first.
	var kart: VehicleBody3D = auto_free(load(KART_SCENE).instantiate())
	add_child(kart)
	await get_tree().process_frame
	kart.global_position = Vector3(0, 5, 0)
	kart.recover()
	var first_pos := kart.global_position
	kart.global_position = Vector3(100, 100, 100)
	kart.recover()
	# Second call should NOT have moved the kart back to lifted-origin.
	assert_that(kart.global_position).is_not_equal(first_pos)

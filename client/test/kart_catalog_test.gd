extends GdUnitTestSuite
## Tests for KartCatalog autoload.

func test_kart_model_path_for_first_kart() -> void:
	# adiumy is alphabetically first → kart_type 0.
	# Catalog `model` is e.g. "karts/adiumy/adiumy.spm", returned as
	# "res://karts/adiumy/adiumy.glb" after the .spm→.glb swap.
	if KartCatalog.karts.is_empty():
		return  # catalog not generated in this build — skip
	var path := KartCatalog.kart_model_path(0)
	assert_that(path).starts_with("res://karts/")
	assert_that(path).ends_with(".glb")

func test_kart_model_path_wraps_oversized_index() -> void:
	if KartCatalog.karts.is_empty():
		return
	var size := KartCatalog.karts.size()
	# Asking for index `size` should wrap to 0 — same model.
	assert_that(KartCatalog.kart_model_path(size)).is_equal(KartCatalog.kart_model_path(0))

func test_kart_model_path_negative_wraps() -> void:
	if KartCatalog.karts.is_empty():
		return
	# -1 should wrap to the last kart.
	var size := KartCatalog.karts.size()
	assert_that(KartCatalog.kart_model_path(-1)).is_equal(KartCatalog.kart_model_path(size - 1))

func test_has_bundled_track_for_lighthouse() -> void:
	# lighthouse is the always-bundled track per export_presets.cfg.
	assert_that(KartCatalog.has_bundled_track("lighthouse")).is_true()

func test_has_bundled_track_rejects_missing_track() -> void:
	assert_that(KartCatalog.has_bundled_track("not_a_real_track")).is_false()
	assert_that(KartCatalog.has_bundled_track("")).is_false()

extends GdUnitTestSuite
## Tests for RacingLine — STK quads.xml parser + helpers.

const RacingLine = preload("res://scripts/RacingLine.gd")

# Minimal synthetic quads.xml: a 4-quad straight-line driveline so the
# expected curve length and direction are easy to predict.
const SIMPLE_QUADS_XML := """<?xml version=\"1.0\"?>
<quads>
  <quad p0=\"0 0 0\" p1=\"2 0 0\" p2=\"2 0 4\" p3=\"0 0 4\"/>
  <quad p0=\"0:3\" p1=\"0:2\" p2=\"2 0 8\" p3=\"0 0 8\"/>
  <quad p0=\"1:3\" p1=\"1:2\" p2=\"2 0 12\" p3=\"0 0 12\"/>
  <quad p0=\"2:3\" p1=\"2:2\" p2=\"2 0 16\" p3=\"0 0 16\"/>
</quads>"""

func test_parses_four_quads_into_a_curve() -> void:
	var data = RacingLine.parse_xml(SIMPLE_QUADS_XML)
	assert_that(data).is_not_null()
	assert_that(data.quad_count).is_equal(4)
	# Curve has 1 point per quad + 1 close-loop point = 5.
	assert_that(data.curve.point_count).is_equal(5)

func test_quad_centers_match_geometry() -> void:
	var data = RacingLine.parse_xml(SIMPLE_QUADS_XML)
	# Quad 0 corners: (0,0,0)(2,0,0)(2,0,4)(0,0,4) -> center (1,0,2).
	# RacingLine lifts +0.4 on Y for ground clearance.
	var p0: Vector3 = data.curve.get_point_position(0)
	assert_that(p0.x).is_equal_approx(1.0, 0.01)
	assert_that(p0.z).is_equal_approx(2.0, 0.01)
	assert_that(p0.y).is_equal_approx(0.4, 0.01)
	# Quad 3 corners: (0,0,12)(2,0,12)(2,0,16)(0,0,16) -> center (1,0,14).
	var p3: Vector3 = data.curve.get_point_position(3)
	assert_that(p3.x).is_equal_approx(1.0, 0.01)
	assert_that(p3.z).is_equal_approx(14.0, 0.01)

func test_curve_length_is_sensible() -> void:
	var data = RacingLine.parse_xml(SIMPLE_QUADS_XML)
	# Centers at z=2, 6, 10, 14, then close back to (1,0.4,2) -> 4m gaps
	# along z + a 12m closing leg = 24m total.
	assert_that(data.length).is_greater(20.0)
	assert_that(data.length).is_less(40.0)

func test_point_ahead_walks_curve() -> void:
	var data = RacingLine.parse_xml(SIMPLE_QUADS_XML)
	var here := Vector3(1, 0.4, 2)  # at the first quad center
	var ahead := RacingLine.point_ahead(data, here, 4.0)
	# 4m ahead of (1,0.4,2) along +Z lands on the next quad center (1,0.4,6).
	assert_that(ahead.z).is_greater(4.5)
	assert_that(ahead.z).is_less(7.5)

func test_tangent_points_forward() -> void:
	var data = RacingLine.parse_xml(SIMPLE_QUADS_XML)
	var t := RacingLine.tangent_at(data, Vector3(1, 0.4, 2))
	# Driveline runs along +Z, so tangent should be ~(0,0,+1).
	assert_that(t.z).is_greater(0.8)
	assert_that(abs(t.x)).is_less(0.2)

func test_returns_null_on_empty_xml() -> void:
	var data = RacingLine.parse_xml("<?xml version=\"1.0\"?><quads></quads>")
	assert_that(data).is_null()

func test_resolves_chained_shorthand() -> void:
	# Quad 1 references quad 0; if shorthand resolution were broken, the
	# parser would produce a quad with zeros and the center would jump.
	var data = RacingLine.parse_xml(SIMPLE_QUADS_XML)
	var p0: Vector3 = data.curve.get_point_position(0)
	var p1: Vector3 = data.curve.get_point_position(1)
	# Quad 1's front edge IS quad 0's back edge — back-edge midpoint is
	# (1, 0, 4). Quad 1 spans z=4..8 so its center sits at z=6.
	assert_that(p1.z).is_equal_approx(6.0, 0.05)
	# And the two centers should be 4m apart (4m driveline spacing in z).
	assert_that(p0.distance_to(p1)).is_equal_approx(4.0, 0.05)

func test_load_for_track_returns_null_for_missing_track() -> void:
	var data = RacingLine.load_for_track("definitely_not_a_real_track_xyz")
	assert_that(data).is_null()

func test_load_for_track_works_on_gran_paradiso() -> void:
	# Smoke test against the actual bundled track. Skipped silently when the
	# project is run from a build that didn't include tracks/.
	if not FileAccess.file_exists("res://tracks/gran_paradiso_island/quads.xml"):
		return
	var data = RacingLine.load_for_track("gran_paradiso_island")
	assert_that(data).is_not_null()
	assert_that(data.quad_count).is_greater(100)  # full track has ~300 quads
	assert_that(data.length).is_greater(500.0)    # full lap is hundreds of meters

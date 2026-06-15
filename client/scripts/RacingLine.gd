class_name RacingLine
extends RefCounted
## STK driveline parser.
##
## Loads `res://tracks/<id>/quads.xml` and returns a Curve3D that runs along
## the center of every driveline quad in order. AI karts use this curve to
## chase a look-ahead target.
##
## STK quads.xml format (excerpt):
##   <quad p0="X Y Z" p1="X Y Z" p2="X Y Z" p3="X Y Z"/>
##   <quad p0="0:3" p1="0:2" p2="X Y Z" p3="X Y Z"/>
##
## The shorthand `p0="N:M"` means "reuse quad N's point M". This is how
## consecutive driveline quads share an edge to form a continuous strip.
## We resolve every shorthand against the already-parsed quad list.
##
## Convention (matches TrackLoader.gd):
##   STK xyz uses Y-up, matching Godot. Points are used directly as world
##   coords because TrackLoader instantiates tracks at the origin.

class RacingLineData:
	var curve: Curve3D
	var length: float
	var quad_count: int
	var lap_threshold_dist: float  # used by lap detection helpers later

static func load_for_track(track_id: String) -> RacingLineData:
	var path: String = "res://tracks/%s/quads.xml" % track_id
	if not FileAccess.file_exists(path):
		push_warning("[racing-line] quads.xml not found: %s" % path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_warning("[racing-line] could not open: %s" % path)
		return null
	var xml_text: String = f.get_as_text()
	return parse_xml(xml_text)

## Public for unit tests — parses an xml string directly.
static func parse_xml(xml_text: String) -> RacingLineData:
	var quads: Array = []  # Array of Arrays of 4 Vector3
	var p := XMLParser.new()
	if p.open_buffer(xml_text.to_utf8_buffer()) != OK:
		push_warning("[racing-line] XML parse failed")
		return null
	while p.read() == OK:
		if p.get_node_type() != XMLParser.NODE_ELEMENT:
			continue
		if p.get_node_name() != "quad":
			continue
		var corners: Array = _parse_quad(p, quads)
		if corners.size() == 4:
			quads.append(corners)
	if quads.is_empty():
		push_warning("[racing-line] no <quad> elements found")
		return null
	return _build(quads)

# ─── Internals ────────────────────────────────────────────────────────

static func _parse_quad(p: XMLParser, prior: Array) -> Array:
	var out: Array = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	for i in 4:
		var attr: String = p.get_named_attribute_value_safe("p%d" % i)
		if attr.is_empty():
			return []
		out[i] = _resolve_point(attr, prior)
	return out

# Parses "X Y Z" OR shorthand "N:M" referencing prior quad N's point M.
static func _resolve_point(s: String, prior: Array) -> Vector3:
	if s.find(":") >= 0:
		var parts: PackedStringArray = s.split(":")
		if parts.size() != 2:
			return Vector3.ZERO
		var quad_idx: int = int(parts[0])
		var point_idx: int = int(parts[1])
		if quad_idx < 0 or quad_idx >= prior.size():
			push_warning("[racing-line] shorthand refs missing quad %d" % quad_idx)
			return Vector3.ZERO
		if point_idx < 0 or point_idx > 3:
			return Vector3.ZERO
		return prior[quad_idx][point_idx]
	var pieces: PackedStringArray = s.split(" ", false)
	if pieces.size() < 3:
		return Vector3.ZERO
	return Vector3(float(pieces[0]), float(pieces[1]), float(pieces[2]))

static func _build(quads: Array) -> RacingLineData:
	var curve := Curve3D.new()
	# Slight upward lift so AI raycasts/projections don't start inside the road.
	const Y_LIFT: float = 0.4
	for q in quads:
		var c: Vector3 = (q[0] + q[1] + q[2] + q[3]) * 0.25
		c.y += Y_LIFT
		curve.add_point(c)
	# Close the loop so AI keeps following past the last quad.
	if curve.point_count >= 2:
		curve.add_point(curve.get_point_position(0))
	curve.bake_interval = 2.0  # 2m baked-resolution — plenty for steering
	var data := RacingLineData.new()
	data.curve = curve
	data.length = curve.get_baked_length()
	data.quad_count = quads.size()
	data.lap_threshold_dist = data.length * 0.88  # match Level.gd convention
	return data

## Returns the racing-line point a given world-distance ahead of a kart's
## current position. `look_ahead_m` is in meters along the curve.
static func point_ahead(data: RacingLineData, world_pos: Vector3, look_ahead_m: float) -> Vector3:
	if data == null or data.curve == null:
		return world_pos
	var offset: float = data.curve.get_closest_offset(world_pos)
	var ahead: float = fposmod(offset + look_ahead_m, data.length)
	return data.curve.sample_baked(ahead, true)

## Returns the curve tangent (forward direction) at the racing-line point
## closest to `world_pos`. Useful for orienting freshly-spawned AI karts.
static func tangent_at(data: RacingLineData, world_pos: Vector3) -> Vector3:
	if data == null or data.curve == null:
		return Vector3.FORWARD
	var offset: float = data.curve.get_closest_offset(world_pos)
	var a: Vector3 = data.curve.sample_baked(offset, true)
	var b: Vector3 = data.curve.sample_baked(fposmod(offset + 0.5, data.length), true)
	var t: Vector3 = (b - a)
	if t.length_squared() < 1e-6:
		return Vector3.FORWARD
	return t.normalized()

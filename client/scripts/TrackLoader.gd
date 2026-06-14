extends Node
## TrackLoader (autoload)
##
## Parses an STK track's `scene.xml` at runtime and instantiates a Godot
## Node3D hierarchy with every <static-object> and LOD group instance
## placed at its STK xyz/hpr/scale.
##
## STK coordinate quirks:
##   - STK XML positions are Y-up, matching glTF (because we exported the
##     .glb files from Blender with export_yup=True).
##   - hpr = "heading pitch roll" in degrees, applied as Y/X/Z euler.
##   - scale = "sx sy sz".
##
## Usage:
##   var node = TrackLoader.load_track("lighthouse")
##   if node: add_child(node)

## Reference to a model defined inside a <lod><group>...</group></lod> block.
## Multiple LOD meshes per group; for MVP we always pick the highest-detail
## one (smallest `lod_distance`).
class _LodGroup:
	var name: String
	var best_model: String = ""
	var best_distance: float = 99999.0

## Suggested spawn offset for a given STK track. Servers position karts at
## a flat grid around (0, 0.5, 0); we add this offset before placing them so
## they land on the actual start line and have a clear road ahead.
## Numbers are hand-calibrated by reading scene.xml roughly. Refine over time.
func spawn_offset(track_id: String) -> Vector3:
	match track_id:
		"lighthouse":      return Vector3(  0, 25, 0)
		"cocoa_temple":    return Vector3(  0, 30, 0)
		"volcano_island":  return Vector3(  0, 50, 0)
		"black_forest":    return Vector3(  0, 30, 0)
		"cornfield_crossing": return Vector3(0, 20, 0)
		"snowtuxpeak":     return Vector3(  0, 40, 0)
		"oasis":           return Vector3(  0, 20, 0)
		"pumpkin_park":    return Vector3(  0, 20, 0)
		_:                 return Vector3(  0, 20, 0)  # default: spawn above

func load_track(track_id: String) -> Node3D:
	var base := "res://tracks/%s/" % track_id
	var scene_path := base + "scene.xml"

	if not FileAccess.file_exists(scene_path):
		push_warning("[track] scene.xml not found: " + scene_path)
		return null

	var f := FileAccess.open(scene_path, FileAccess.READ)
	if f == null:
		push_warning("[track] could not open " + scene_path)
		return null
	var xml_text := f.get_as_text()

	var root := Node3D.new()
	root.name = "Track_" + track_id

	# First pass: collect LOD groups (only the highest-detail mesh per group)
	var lod_groups: Dictionary = {}   # name -> _LodGroup
	_collect_lod_groups(xml_text, lod_groups)

	# Second pass: walk <track> and <static-object> entries, instantiate models
	var placed := _place_objects(xml_text, base, lod_groups, root)
	print("[track] %s — placed %d objects" % [track_id, placed])

	# Add a generous floor in case the track mesh has holes, so karts don't
	# fall forever during testing.
	_add_safety_floor(root)

	# Add a strong directional light + ambient so the track is visible at all
	# (STK packs lighting info in scene.xml that we don't parse yet).
	_add_basic_lighting(root)

	return root

func _collect_lod_groups(xml_text: String, out: Dictionary) -> void:
	var p := XMLParser.new()
	if p.open_buffer(xml_text.to_utf8_buffer()) != OK:
		return
	var in_lod := false
	var current_group := ""
	while p.read() == OK:
		var t := p.get_node_type()
		var name := p.get_node_name()
		if t == XMLParser.NODE_ELEMENT:
			if name == "lod":
				in_lod = true
			elif name == "group" and in_lod:
				current_group = p.get_named_attribute_value_safe("name")
				if not out.has(current_group):
					var lg := _LodGroup.new()
					lg.name = current_group
					out[current_group] = lg
			elif name == "static-object" and in_lod and current_group != "":
				var lod_group := p.get_named_attribute_value_safe("lod_group")
				var model := p.get_named_attribute_value_safe("model")
				var dist_str := p.get_named_attribute_value_safe("lod_distance")
				var dist := 99999.0 if dist_str == "" else float(dist_str)
				if not out.has(lod_group):
					var lg2 := _LodGroup.new()
					lg2.name = lod_group
					out[lod_group] = lg2
				var existing: _LodGroup = out[lod_group]
				if dist < existing.best_distance and model != "":
					existing.best_distance = dist
					existing.best_model = model
		elif t == XMLParser.NODE_ELEMENT_END:
			if name == "lod":
				in_lod = false
			elif name == "group":
				current_group = ""

func _place_objects(xml_text: String, base_path: String,
		lod_groups: Dictionary, parent: Node3D) -> int:
	var p := XMLParser.new()
	if p.open_buffer(xml_text.to_utf8_buffer()) != OK:
		return 0
	var in_lod := false
	var in_track := false
	var count := 0

	while p.read() == OK:
		var t := p.get_node_type()
		var name := p.get_node_name()
		if t == XMLParser.NODE_ELEMENT:
			if name == "lod":
				in_lod = true
			elif name == "track":
				in_track = true
				# Place the main track mesh at origin
				var model := p.get_named_attribute_value_safe("model")
				if model != "":
					_instantiate_model(base_path, model, Vector3.ZERO, Vector3.ZERO,
						Vector3.ONE, parent, "track_main")
			elif name == "static-object" and not in_lod:
				# Only place static-objects OUTSIDE the <lod> definition block.
				# Inside <track>...</track> children are placements; inside
				# <lod><group>...</group></lod> they are LOD mesh definitions.
				count += _place_one_static(p, base_path, lod_groups, parent)
		elif t == XMLParser.NODE_ELEMENT_END:
			if name == "lod":
				in_lod = false
			elif name == "track":
				in_track = false

	return count

func _place_one_static(p: XMLParser, base_path: String,
		lod_groups: Dictionary, parent: Node3D) -> int:
	var xyz := _parse_vec3(p.get_named_attribute_value_safe("xyz"), Vector3.ZERO)
	var hpr := _parse_vec3(p.get_named_attribute_value_safe("hpr"), Vector3.ZERO)
	var scl := _parse_vec3(p.get_named_attribute_value_safe("scale"), Vector3.ONE)

	var model_name := ""
	if p.get_named_attribute_value_safe("lod_instance") == "true":
		var grp := p.get_named_attribute_value_safe("lod_group")
		if lod_groups.has(grp):
			model_name = (lod_groups[grp] as _LodGroup).best_model
	else:
		model_name = p.get_named_attribute_value_safe("model")

	if model_name == "":
		return 0
	if _instantiate_model(base_path, model_name, xyz, hpr, scl, parent, ""):
		return 1
	return 0

# Loads <base_path><model_name>.glb (converted from .spm) and adds it as a
# child of parent, placed at xyz/hpr/scale. Returns true on success.
var _model_cache: Dictionary = {}    # glb_path -> PackedScene
func _instantiate_model(base_path: String, model_name: String,
		xyz: Vector3, hpr: Vector3, scl: Vector3,
		parent: Node3D, override_name: String) -> bool:
	var stem := model_name.get_basename()
	var glb_path := base_path + stem + ".glb"
	var scene: PackedScene = _model_cache.get(glb_path, null)
	if scene == null:
		if not ResourceLoader.exists(glb_path):
			return false
		scene = load(glb_path)
		if scene == null:
			return false
		_model_cache[glb_path] = scene

	var inst := scene.instantiate()
	if not (inst is Node3D):
		return false
	var node3d: Node3D = inst
	node3d.position = xyz
	# STK hpr is degrees: heading=Y, pitch=X, roll=Z
	node3d.rotation = Vector3(
		deg_to_rad(hpr.y),  # pitch -> X
		deg_to_rad(hpr.x),  # heading -> Y
		deg_to_rad(hpr.z),  # roll -> Z
	)
	node3d.scale = scl
	if override_name != "":
		node3d.name = override_name
	parent.add_child(node3d)
	# Generate trimesh collision so karts can drive on every mesh.
	# Without this, the karts fall through and land on the safety floor.
	_add_trimesh_collision_recursive(node3d)
	return true

# Walks a glTF instance, calling create_trimesh_collision() on each
# MeshInstance3D. That helper adds a StaticBody3D + ConcavePolygonShape3D
# sibling so the world is solid.
func _add_trimesh_collision_recursive(node: Node) -> void:
	if node is MeshInstance3D and node.mesh != null:
		(node as MeshInstance3D).create_trimesh_collision()
	for child in node.get_children():
		_add_trimesh_collision_recursive(child)

func _parse_vec3(s: String, default: Vector3) -> Vector3:
	if s == "":
		return default
	var parts := s.split(" ", false)
	if parts.size() < 3:
		return default
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))

func _add_safety_floor(parent: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "SafetyFloor"
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(2000, 2, 2000)
	col.shape = shape
	col.position = Vector3(0, -50, 0)
	body.add_child(col)
	parent.add_child(body)

func _add_basic_lighting(parent: Node3D) -> void:
	# Directional sun
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.light_energy = 1.2
	sun.rotation_degrees = Vector3(-50, 35, 0)
	parent.add_child(sun)
	# Environment with sky+ambient so the world isn't pitch black
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var procedural := ProceduralSkyMaterial.new()
	procedural.sky_top_color = Color(0.27, 0.55, 0.85)
	procedural.sky_horizon_color = Color(0.78, 0.85, 0.95)
	procedural.ground_horizon_color = Color(0.40, 0.30, 0.25)
	procedural.ground_bottom_color = Color(0.10, 0.07, 0.05)
	sky.sky_material = procedural
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.name = "WorldEnv"
	we.environment = env
	parent.add_child(we)

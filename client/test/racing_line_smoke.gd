extends SceneTree
## One-shot smoke test for RacingLine.gd against real STK tracks.
## Run with:
##   Godot.exe --headless --path <client_dir> --script res://test/racing_line_smoke.gd

const RacingLine = preload("res://scripts/RacingLine.gd")

func _init() -> void:
	var passed: int = 0
	var failed: int = 0

	# Synthetic XML — same shape as the GdUnit test, runs without engine.
	var synth_xml: String = "<?xml version=\"1.0\"?><quads>"
	synth_xml += "<quad p0=\"0 0 0\" p1=\"2 0 0\" p2=\"2 0 4\" p3=\"0 0 4\"/>"
	synth_xml += "<quad p0=\"0:3\" p1=\"0:2\" p2=\"2 0 8\" p3=\"0 0 8\"/>"
	synth_xml += "<quad p0=\"1:3\" p1=\"1:2\" p2=\"2 0 12\" p3=\"0 0 12\"/>"
	synth_xml += "<quad p0=\"2:3\" p1=\"2:2\" p2=\"2 0 16\" p3=\"0 0 16\"/>"
	synth_xml += "</quads>"
	var sd = RacingLine.parse_xml(synth_xml)
	if sd != null and sd.quad_count == 4 and sd.curve.point_count == 5:
		print("[ok] synthetic XML parses (4 quads, 5 curve points)"); passed += 1
	else:
		print("[FAIL] synthetic XML"); failed += 1

	# Shorthand resolution: first center vs second center.
	var p0: Vector3 = sd.curve.get_point_position(0)
	var p1: Vector3 = sd.curve.get_point_position(1)
	if abs(p0.x - 1.0) < 0.01 and abs(p0.z - 2.0) < 0.01:
		print("[ok] quad 0 center is (1, ~0.4, 2)"); passed += 1
	else:
		print("[FAIL] quad 0 center is %s" % str(p0)); failed += 1
	if abs(p1.z - 6.0) < 0.05 and abs(p0.distance_to(p1) - 4.0) < 0.05:
		print("[ok] shorthand resolution chains quads (4m apart)"); passed += 1
	else:
		print("[FAIL] shorthand chain p1=%s dist=%.3f" % [str(p1), p0.distance_to(p1)]); failed += 1

	# point_ahead helper
	var here := Vector3(1, 0.4, 2)
	var ahead: Vector3 = RacingLine.point_ahead(sd, here, 4.0)
	if ahead.z > 4.5 and ahead.z < 7.5:
		print("[ok] point_ahead walks the curve forward"); passed += 1
	else:
		print("[FAIL] point_ahead z=%.3f" % ahead.z); failed += 1

	# tangent_at helper
	var t: Vector3 = RacingLine.tangent_at(sd, here)
	if t.z > 0.8 and abs(t.x) < 0.2:
		print("[ok] tangent points along +Z"); passed += 1
	else:
		print("[FAIL] tangent %s" % str(t)); failed += 1

	# Empty XML returns null
	if RacingLine.parse_xml("<?xml version=\"1.0\"?><quads></quads>") == null:
		print("[ok] empty XML returns null"); passed += 1
	else:
		print("[FAIL] empty XML did not return null"); failed += 1

	# Real Gran Paradiso quads.xml
	var gp = RacingLine.load_for_track("gran_paradiso_island")
	if gp != null and gp.quad_count > 100 and gp.length > 500.0:
		print("[ok] Gran Paradiso: %d quads, length %.1fm" % [gp.quad_count, gp.length]); passed += 1
	else:
		var qc: int = -1
		var ln: float = -1.0
		if gp != null:
			qc = gp.quad_count; ln = gp.length
		print("[FAIL] Gran Paradiso: quads=%d length=%.1f" % [qc, ln]); failed += 1

	# Real lighthouse
	if FileAccess.file_exists("res://tracks/lighthouse/quads.xml"):
		var lh = RacingLine.load_for_track("lighthouse")
		if lh != null and lh.quad_count > 50:
			print("[ok] Lighthouse: %d quads, length %.1fm" % [lh.quad_count, lh.length]); passed += 1
		else:
			print("[FAIL] Lighthouse"); failed += 1

	# Missing track
	if RacingLine.load_for_track("definitely_not_real") == null:
		print("[ok] missing track returns null"); passed += 1
	else:
		print("[FAIL] missing track did not return null"); failed += 1

	print("--- %d passed, %d failed ---" % [passed, failed])
	quit(failed)

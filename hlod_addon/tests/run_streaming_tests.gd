extends SceneTree
## godot --headless --path . -s res://tests/run_streaming_tests.gd

const Builder := preload("res://addons/world_streaming/world_cell_builder.gd")
const DIR := "user://streaming_test_cells"

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _make_world() -> Node3D:
	var world := Node3D.new()
	# A 4 x 4 block of 100 m cells with one building each.
	for x in 4:
		for z in 4:
			var mi := MeshInstance3D.new()
			mi.mesh = BoxMesh.new()
			mi.name = "B_%d_%d" % [x, z]
			mi.position = Vector3(x * 100.0 + 50.0, 0, z * 100.0 + 50.0)
			world.add_child(mi)
	return world


func _wait_idle(streamer: WorldStreamer, max_frames := 600) -> int:
	var frames := 0
	streamer.update_now()
	while frames < max_frames:
		await process_frame
		frames += 1
		if not streamer.is_busy():
			break
	return frames


func _init() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(DIR)
	print("split a scene into cells")
	var world := _make_world()
	var built := Builder.build(world, 100.0, DIR)
	_check(built["error"] == OK, "build OK")
	_check(built["cells"] == 16, "16 cells (%d)" % built["cells"])
	_check(FileAccess.file_exists(DIR + "/cell_2_3.tscn"), "cell file exists")
	var packed := load(DIR + "/cell_2_3.tscn") as PackedScene
	var inst := packed.instantiate()
	_check(inst.get_child_count() == 1 and inst.get_child(0).name == "B_2_3", "cell holds its building")
	_check(inst.get_child(0).position.is_equal_approx(Vector3(250, 0, 350)), "authored position kept")
	inst.free()
	world.free()

	print("streamer loads and frees by distance")
	var root3d := Node3D.new()
	root.add_child(root3d)
	var player := Node3D.new()
	player.name = "Player"
	root3d.add_child(player)
	player.position = Vector3(50, 0, 50)
	var streamer := WorldStreamer.new()
	streamer.cells_dir = DIR
	streamer.cell_size = 100.0
	streamer.load_radius = 160.0
	streamer.unload_radius = 220.0
	streamer.required_radius = 60.0
	streamer.target = NodePath("../Player")
	root3d.add_child(streamer)
	var loaded: Array[Vector2i] = []
	var unloaded: Array[Vector2i] = []
	streamer.cell_loaded.connect(func(c, _n): loaded.append(c))
	streamer.cell_unloaded.connect(func(c): unloaded.append(c))
	var ready_count := [0]
	streamer.required_area_ready.connect(func(): ready_count[0] += 1)

	await _wait_idle(streamer)
	var counts := streamer.get_loaded_counts()
	# Player in cell (0,0): centers within 160 m of (50, 50): (0,0), (1,0), (0,1), (1,1) at 100/141 m. (2,0) is 200 m.
	_check(counts["detail"] == 4, "4 cells near the origin (%s)" % counts)
	_check(streamer.get_cell(Vector2i(0, 0)) != null, "origin cell present")
	_check(streamer.get_cell(Vector2i(3, 3)) == null, "far cell absent")
	_check(streamer.is_position_loaded(Vector3(50, 0, 50)), "ground under the player is loaded")
	_check(not streamer.is_position_loaded(Vector3(350, 0, 350)), "far ground is not loaded")
	_check(ready_count[0] >= 1, "required_area_ready emitted")

	player.position = Vector3(350, 0, 350)
	streamer.update_now()
	_check(not streamer.is_position_loaded(Vector3(350, 0, 350)), "right after teleport the ground is not ready")
	await _wait_idle(streamer)
	counts = streamer.get_loaded_counts()
	_check(streamer.get_cell(Vector2i(3, 3)) != null, "destination cell loaded")
	_check(streamer.get_cell(Vector2i(0, 0)) == null, "origin cell freed")
	_check(unloaded.size() >= 4, "unloaded signals (%d)" % unloaded.size())
	_check(streamer.is_position_loaded(Vector3(350, 0, 350)), "ground ready at destination")

	print("hysteresis: a cell between load and unload radius stays")
	player.position = Vector3(350, 0, 350) + Vector3(-180, 0, 0)  # (170,350): cell (2,3) center is 100 m away
	await _wait_idle(streamer)
	var still := streamer.get_cell(Vector2i(3, 3))
	_check(still != null, "cell (3,3) stays loaded at ~%.0f m" % Vector2(170, 350).distance_to(Vector2(350, 350)))

	print("budget: cells are added a few per frame")
	player.position = Vector3(50, 0, 50)
	streamer.frame_budget_ms = 0.05
	streamer.update_now()
	var max_per_frame := 0
	var prev := loaded.size()
	for i in 600:
		await process_frame
		max_per_frame = maxi(max_per_frame, loaded.size() - prev)
		prev = loaded.size()
		if not streamer.is_busy():
			break
	_check(max_per_frame <= 2, "at most 2 cells in one frame with a tiny budget (%d)" % max_per_frame)
	_check(streamer.get_cell(Vector2i(0, 0)) != null, "still ends up loaded")

	print("shifting the streamer moves the cells with it")
	var before := streamer.get_cell(Vector2i(0, 0)).global_position
	root3d.position += Vector3(-1000, 0, 0)
	player.position += Vector3(0, 0, 0)
	_check(streamer.get_cell(Vector2i(0, 0)).global_position.is_equal_approx(before + Vector3(-1000, 0, 0)), "cells follow the parent")
	root3d.free()

	print("far cells and the swap between layers")
	var far_dir := "user://streaming_test_far"
	var world2 := _make_world()
	var options := Builder.Options.new()
	options.make_far = true
	var built2 := Builder.build(world2, 100.0, far_dir, options)
	_check(built2["far_cells"] == 16, "16 far cells (%d)" % built2["far_cells"])
	world2.free()
	var root2 := Node3D.new()
	root.add_child(root2)
	var player2 := Node3D.new()
	player2.name = "Player"
	root2.add_child(player2)
	player2.position = Vector3(50, 0, 50)
	var s2 := WorldStreamer.new()
	s2.cells_dir = far_dir
	s2.cell_size = 100.0
	s2.load_radius = 160.0
	s2.unload_radius = 220.0
	s2.far_load_radius = 500.0
	s2.far_unload_radius = 560.0
	s2.target = NodePath("../Player")
	root2.add_child(s2)
	await _wait_idle(s2)
	counts = s2.get_loaded_counts()
	_check(counts["detail"] == 4 and counts["far"] == 12, "4 detail + 12 far (%s)" % counts)
	_check(s2.get_cell(Vector2i(3, 3), WorldStreamer.Layer.FAR) != null, "far cell present")
	player2.position = Vector3(350, 0, 350)
	await _wait_idle(s2)
	counts = s2.get_loaded_counts()
	_check(s2.get_cell(Vector2i(3, 3)) != null, "destination is detail now")
	_check(s2.get_cell(Vector2i(3, 3), WorldStreamer.Layer.FAR) == null, "its far version is gone")
	_check(s2.get_cell(Vector2i(0, 0), WorldStreamer.Layer.FAR) != null, "origin cell became far")
	_check(s2.get_cell(Vector2i(0, 0)) == null, "and not detail")
	root2.free()

	print("prewarm path still ends with loaded cells")
	var root4 := Node3D.new()
	root.add_child(root4)
	var p4 := Node3D.new()
	p4.name = "Player"
	root4.add_child(p4)
	p4.position = Vector3(50, 0, 50)
	var s4 := WorldStreamer.new()
	s4.cells_dir = DIR
	s4.cell_size = 100.0
	s4.load_radius = 160.0
	s4.unload_radius = 220.0
	s4.prewarm = true
	s4.target = NodePath("../Player")
	root4.add_child(s4)
	await _wait_idle(s4)
	_check(s4.get_loaded_counts()["detail"] == 4, "4 cells after prewarm (%s)" % s4.get_loaded_counts())
	var any_cell := s4.get_cell(Vector2i(0, 0))
	_check(any_cell != null and any_cell.get_parent() == s4, "cell ends up under the streamer")
	root4.free()

	print("per-cell navigation")
	var nav_world := Node3D.new()
	for x in 2:
		var ground := MeshInstance3D.new()
		var plane := BoxMesh.new()
		plane.size = Vector3(100, 1, 100)
		ground.mesh = plane
		ground.position = Vector3(x * 100.0 + 50.0, -0.5, 50.0)
		nav_world.add_child(ground)
	var nav_opts := Builder.Options.new()
	nav_opts.bake_navigation = true
	var nav_dir := "user://streaming_test_nav"
	var built3 := Builder.build(nav_world, 100.0, nav_dir, nav_opts)
	_check(built3["cells"] == 2, "two nav cells")
	var nav_cell := (load(nav_dir + "/cell_0_0.tscn") as PackedScene).instantiate()
	var region := nav_cell.get_node_or_null("Navigation") as NavigationRegion3D
	_check(region != null and region.navigation_mesh.get_polygon_count() > 0, "cell has a baked navigation region")
	nav_cell.free()
	nav_world.free()

	print("ground gate")
	var root5 := Node3D.new()
	root.add_child(root5)
	var p5 := CharacterBody3D.new()
	p5.name = "Player"
	root5.add_child(p5)
	p5.position = Vector3(50, 0, 50)
	var s5 := WorldStreamer.new()
	s5.name = "Streamer"
	s5.cells_dir = DIR
	s5.cell_size = 100.0
	s5.load_radius = 160.0
	s5.unload_radius = 220.0
	s5.required_radius = 60.0
	s5.target = NodePath("../Player")
	root5.add_child(s5)
	var gate := WorldGroundGate.new()
	gate.streamer = NodePath("../Streamer")
	gate.body = NodePath("../Player")
	root5.add_child(gate)
	_check(gate.is_frozen() and p5.process_mode == Node.PROCESS_MODE_DISABLED, "frozen before the ground exists")
	await _wait_idle(s5)
	await process_frame
	_check(not gate.is_frozen() and p5.process_mode == Node.PROCESS_MODE_INHERIT, "released when ready")
	p5.position = Vector3(350, 0, 350)
	s5.update_now()
	await process_frame
	_check(gate.is_frozen(), "frozen again after a teleport")
	await _wait_idle(s5)
	await process_frame
	_check(not gate.is_frozen(), "released at the destination")
	root5.free()

	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

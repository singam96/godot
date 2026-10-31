extends SceneTree
## godot --headless --path . -s res://tests/run_streaming_threads_tests.gd

const Builder := preload("res://addons/world_streaming/world_cell_builder.gd")
const Probe := preload("res://tests/thread_probe.gd")
const DIR := "user://streaming_thread_cells"

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _make_dense_world(per_cell: int) -> Node3D:
	var world := Node3D.new()
	for x in 3:
		for z in 3:
			for i in per_cell:
				var node: Node3D = Probe.new() if i == 0 else Node3D.new()
				node.name = "Item_%d_%d_%d" % [x, z, i]
				node.position = Vector3(x * 100.0 + 5.0 + i, 0, z * 100.0 + 5.0)
				world.add_child(node)
	return world


func _idle(streamer: WorldStreamer, max_frames := 900) -> int:
	streamer.update_now()
	var frames := 0
	while frames < max_frames:
		await process_frame
		frames += 1
		if not streamer.is_busy():
			break
	return frames


func _setup(root3d: Node3D) -> WorldStreamer:
	var player := Node3D.new()
	player.name = "Player"
	player.position = Vector3(150, 0, 150)
	root3d.add_child(player)
	var streamer := WorldStreamer.new()
	streamer.cells_dir = DIR
	streamer.cell_size = 100.0
	streamer.load_radius = 200.0
	streamer.unload_radius = 260.0
	streamer.target = NodePath("../Player")
	root3d.add_child(streamer)
	return streamer


func _init() -> void:
	await process_frame
	DirAccess.make_dir_recursive_absolute(DIR)
	var source := _make_dense_world(60)
	Builder.build(source, 100.0, DIR)
	source.free()

	print("cells are built off the main thread")
	var root_a := Node3D.new()
	root.add_child(root_a)
	var s := _setup(root_a)
	Probe.created_on.clear()
	await _idle(s)
	var main_id := OS.get_main_thread_id()
	var off_main := 0
	for id in Probe.created_on:
		if id != main_id:
			off_main += 1
	_check(not Probe.created_on.is_empty(), "the probe scripts were created (%d)" % Probe.created_on.size())
	_check(off_main == Probe.created_on.size(), "all created on worker threads (%d of %d)" % [off_main, Probe.created_on.size()])
	_check(s.get_loaded_counts()["detail"] == 9, "all nine cells loaded (%s)" % s.get_loaded_counts())
	_check(s.get_cell(Vector2i(1, 1)).get_child_count() == 60, "complete cell (%d children)" % s.get_cell(Vector2i(1, 1)).get_child_count())

	print("main thread instantiation still works when switched off")
	root_a.free()
	var root_b := Node3D.new()
	root.add_child(root_b)
	var s2 := _setup(root_b)
	s2.threaded_instantiate = false
	Probe.created_on.clear()
	await _idle(s2)
	var on_main := 0
	for id in Probe.created_on:
		if id == main_id:
			on_main += 1
	_check(not Probe.created_on.is_empty() and on_main == Probe.created_on.size(), "created on the main thread")
	root_b.free()

	print("incremental children: a cell appears piece by piece")
	var root_c := Node3D.new()
	root.add_child(root_c)
	var s3 := _setup(root_c)
	s3.incremental_children = true
	s3.frame_budget_ms = 0.01
	var loaded_cells := [0]
	s3.cell_loaded.connect(func(_c, _n): loaded_cells[0] += 1)
	var max_children_step := 0
	var seen_partial := false
	s3.update_now()
	var prev_nodes := -1
	for i in 2000:
		await process_frame
		var total := 0
		for c in s3.get_children():
			if c is Node3D and c.has_meta("world_streaming_coord"):
				total += c.get_child_count()
		if prev_nodes >= 0:
			max_children_step = maxi(max_children_step, total - prev_nodes)
		prev_nodes = total
		if total > 0 and total < 9 * 60 and loaded_cells[0] < 9:
			seen_partial = true
		if not s3.is_busy():
			break
	_check(seen_partial, "cells were partially filled for a while")
	_check(max_children_step <= 20, "few children per frame with a tiny budget (%d)" % max_children_step)
	_check(s3.get_loaded_counts()["detail"] == 9 and loaded_cells[0] == 9, "all cells loaded, signal once each (%d)" % loaded_cells[0])
	_check(s3.get_cell(Vector2i(2, 2)).get_child_count() == 60, "every child arrived")

	print("incremental unload removes children a few at a time and signals at the end")
	var unloaded := [0]
	s3.cell_unloaded.connect(func(_c): unloaded[0] += 1)
	var player: Node3D = root_c.get_node("Player")
	player.position = Vector3(5000, 0, 5000)
	s3.update_now()
	var frames := 0
	while s3.is_busy() and frames < 3000:
		await process_frame
		frames += 1
	await process_frame
	_check(unloaded[0] == 9, "nine unload signals (%d)" % unloaded[0])
	_check(s3.get_loaded_counts()["detail"] == 0, "nothing left")
	_check(frames > 3, "it took several frames (%d)" % frames)

	print("dropping cells in the middle of loading leaks nothing")
	player.position = Vector3(150, 0, 150)
	s3.update_now()
	for i in 6:
		await process_frame
	player.position = Vector3(5000, 0, 5000)  # Leave while cells are instantiating or being filled.
	await _idle(s3)
	await process_frame
	await process_frame
	root_c.free()
	await process_frame
	await process_frame
	_check(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT) == 0, "no orphan nodes (%d)" % Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))

	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

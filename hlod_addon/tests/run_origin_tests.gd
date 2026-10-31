extends SceneTree
## godot --headless --path . -s res://tests/run_origin_tests.gd

const DIR := "user://origin_test_cells"

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _init() -> void:
	await process_frame
	var world := Node3D.new()
	world.name = "World"
	root.add_child(world)
	var player := CharacterBody3D.new()
	player.name = "Player"
	world.add_child(player)
	var tree_node := Node3D.new()
	tree_node.name = "Tree"
	tree_node.position = Vector3(2600, 0, 3100)
	world.add_child(tree_node)
	var rig := Node3D.new()  # Outside the world root.
	rig.name = "Rig"
	root.add_child(rig)

	var shifter := OriginShifter.new()
	shifter.target = NodePath("../World/Player")
	shifter.world_root = NodePath("../World")
	shifter.extra_nodes = [NodePath("../Rig")]
	shifter.threshold = 2000.0
	shifter.snap = 500.0
	root.add_child(shifter)

	print("no shift while close")
	player.position = Vector3(1500, 0, -1500)
	shifter.check()
	_check(player.position == Vector3(1500, 0, -1500), "unchanged")
	_check(shifter.offset_x == 0.0, "no offset")

	print("shift when far")
	var signaled := [Vector3.ZERO]
	shifter.origin_shifted.connect(func(s): signaled[0] = s)
	player.position = Vector3(2300, 5, 4100)
	var abs_before := shifter.get_absolute_position(player)
	var tree_abs_before := shifter.get_absolute_position(tree_node)
	shifter.check()
	_check(signaled[0] == Vector3(-2500, 0, -4000), "shift is a multiple of the snap (%s)" % signaled[0])
	_check(player.position == Vector3(-200, 5, 100), "player is near the origin %s" % player.position)
	_check(tree_node.position == Vector3(100, 0, -900), "other nodes moved by the same amount %s" % tree_node.position)
	_check(rig.position == Vector3(-2500, 0, -4000), "extra nodes moved")
	var abs_after := shifter.get_absolute_position(player)
	_check(abs_after[0] == abs_before[0] and abs_after[1] == abs_before[1] and abs_after[2] == abs_before[2], "absolute position unchanged")
	var tree_abs_after := shifter.get_absolute_position(tree_node)
	_check(tree_abs_after[0] == tree_abs_before[0] and tree_abs_after[2] == tree_abs_before[2], "tree absolute unchanged")
	_check(shifter.offset_x == 2500.0 and shifter.offset_z == 4000.0, "offset is kept (%f, %f)" % [shifter.offset_x, shifter.offset_z])

	print("absolute round trip, beyond float32 precision")
	shifter.offset_x = 123456789.0
	var a := PackedFloat64Array([123456790.25, 3.0, -50.0])
	var l := shifter.to_local_position(a)
	_check(is_equal_approx(l.x, 1.25), "converted to local with the offset (%f)" % l.x)
	var back := shifter.to_absolute(l)
	_check(is_equal_approx(back[0], 123456790.25), "and back")
	shifter.offset_x = 2500.0

	print("repeated travel keeps absolute coordinates")
	var start_abs := shifter.get_absolute_position(player)
	for i in 10:
		player.position += Vector3(900, 0, 0)
		shifter.check()
	var end_abs := shifter.get_absolute_position(player)
	_check(is_equal_approx(end_abs[0] - start_abs[0], 9000.0), "travelled 9000 m (%f)" % (end_abs[0] - start_abs[0]))
	_check(absf(player.position.x) <= 2000.0, "player stays within the threshold (%f)" % player.position.x)

	print("vertical shift is opt-in")
	player.position = Vector3(0, 5000, 0)
	shifter.check()
	_check(player.position.y == 5000.0, "no vertical shift by default")
	shifter.shift_vertical = true
	shifter.check()
	_check(player.position.y == 0.0, "vertical shift when enabled (%f)" % player.position.y)

	print("a WorldStreamer below the world root keeps its cells aligned")
	DirAccess.make_dir_recursive_absolute(DIR)
	var builder := preload("res://addons/world_streaming/world_cell_builder.gd")
	var source := Node3D.new()
	for x in range(0, 1000, 100):
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		mi.position = Vector3(x + 50.0, 0, 50.0)
		source.add_child(mi)
	builder.build(source, 100.0, DIR)
	source.free()
	player.position = Vector3(250, 0, 50)
	var streamer := WorldStreamer.new()
	streamer.name = "Streamer"
	streamer.cells_dir = DIR
	streamer.cell_size = 100.0
	streamer.load_radius = 120.0
	streamer.unload_radius = 160.0
	streamer.target = NodePath("../Player")
	world.add_child(streamer)
	for i in 120:
		await process_frame
		if not streamer.is_busy():
			break
	var cell := streamer.get_cell(Vector2i(2, 0))
	_check(cell != null, "cell under the player is loaded")
	var rel_before := player.global_position - cell.global_position
	shifter.shift_by(Vector3(-5000, 0, 0))
	var rel_after := player.global_position - cell.global_position
	_check(rel_before.is_equal_approx(rel_after), "player and cell moved together")
	streamer.update_now()
	await process_frame
	_check(streamer.get_cell(Vector2i(2, 0)) != null and streamer.get_loaded_counts()["detail"] == 3, "same cells stay loaded after the shift (%s)" % streamer.get_loaded_counts())

	world.free()
	rig.free()
	shifter.free()
	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

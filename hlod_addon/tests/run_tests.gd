extends SceneTree
## Headless test runner. Run with:
##   godot --headless --path <project> -s res://tests/run_tests.gd
## Exits with code 1 if any check fails.

const Cluster := preload("res://addons/hlod/hlod_cluster_3d.gd")
const Atlas := preload("res://addons/hlod/hlod_atlas.gd")

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _sphere(radius := 1.0, material: Material = null) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	mesh.material = material
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	return mi


func _triangle_count(mesh: Mesh) -> int:
	var total := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var indices = arrays[Mesh.ARRAY_INDEX]
		total += (indices.size() if indices != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	return total


func _make_cluster() -> Node3D:
	var c: Node3D = Cluster.new()
	c.remove_hidden_faces = false
	c.merge_materials = false
	c.simplify_ratio = 1.0
	return c


func test_merge_and_simplify() -> void:
	print("merge and simplify")
	var c := _make_cluster()
	for i in 3:
		var s := _sphere()
		s.position = Vector3(i * 3.0, 0, 0)
		c.add_child(s)
	_check(c.generate_proxy() == OK, "generate_proxy OK")
	var full := _triangle_count(c.proxy_mesh)
	_check(full == 3 * _triangle_count(_sphere().mesh), "merged count is the sum (%d)" % full)
	var aabb: AABB = c.proxy_mesh.get_aabb()
	_check(aabb.size.x > 7.5, "merged AABB spans the instances (%s)" % aabb)
	c.simplify_ratio = 0.25
	_check(c.generate_proxy() == OK, "generate with ratio")
	var simp := _triangle_count(c.proxy_mesh)
	_check(simp < full * 0.6, "simplified is smaller (%d < %d)" % [simp, full])
	c.free()


func test_empty() -> void:
	print("empty cluster")
	var c := _make_cluster()
	_check(c.generate_proxy() == ERR_DOES_NOT_EXIST, "empty returns ERR_DOES_NOT_EXIST")
	_check(c.finish_generation() == ERR_UNCONFIGURED, "finish without start")
	c.free()


func test_hidden_faces() -> void:
	print("hidden faces")
	var c := _make_cluster()
	c.remove_hidden_faces = true
	c.add_child(_sphere(2.0))
	var inner := _sphere(0.5)
	c.add_child(inner)
	_check(c.generate_proxy() == OK, "generate OK")
	var single := _make_cluster()
	single.remove_hidden_faces = true
	single.add_child(_sphere(2.0))
	single.generate_proxy()
	var with_hidden := _triangle_count(c.proxy_mesh)
	var alone := _triangle_count(single.proxy_mesh)
	_check(with_hidden == alone, "inner sphere removed (%d vs %d)" % [with_hidden, alone])
	c.free()
	single.free()


func test_atlas() -> void:
	print("atlas")
	var c := _make_cluster()
	c.merge_materials = true
	for col in [Color.RED, Color.GREEN, Color.BLUE]:
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		var s := _sphere(1.0, m)
		s.position.x = c.get_child_count() * 3.0
		c.add_child(s)
	_check(c.generate_proxy() == OK, "generate OK")
	_check(c.proxy_mesh.get_surface_count() == 1, "one surface (%d)" % c.proxy_mesh.get_surface_count())
	var mat := c.proxy_mesh.surface_get_material(0) as StandardMaterial3D
	_check(mat != null and mat.albedo_texture != null, "atlas texture present")
	if mat != null and mat.albedo_texture != null:
		var img := mat.albedo_texture.get_image()
		_check(img.get_width() >= 128, "atlas size %s" % img.get_size())
	# Non-eligible (transparent) stays separate
	var t := StandardMaterial3D.new()
	t.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var ts := _sphere(1.0, t)
	ts.position.x = 20
	c.add_child(ts)
	c.generate_proxy()
	_check(c.proxy_mesh.get_surface_count() == 2, "transparent kept separate (%d)" % c.proxy_mesh.get_surface_count())
	c.free()


func test_multimesh() -> void:
	print("multimesh")
	var c := _make_cluster()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _sphere().mesh
	mm.instance_count = 4
	for i in 4:
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(i * 4.0, 0, 0)))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	c.add_child(mmi)
	_check(c.generate_proxy() == OK, "generate OK")
	_check(_triangle_count(c.proxy_mesh) == 4 * _triangle_count(mm.mesh), "4 copies merged")
	c.free()


func test_async_and_cancel() -> void:
	print("async")
	var c := _make_cluster()
	c.remove_hidden_faces = true
	for i in 6:
		var s := _sphere()
		s.position = Vector3(i * 3.0, 0, 0)
		c.add_child(s)
	_check(c.generate_proxy_async() == OK, "async starts")
	_check(c.generate_proxy_async() == ERR_BUSY, "second start is busy")
	var guard := 0
	while c.is_generating() and guard < 2000:
		await process_frame
		guard += 1
	_check(c.finish_generation() == OK, "finish OK")
	_check(c.proxy_mesh != null, "mesh assigned")
	_check(c.get_generation_progress() == 0.0, "progress resets")

	c.generate_proxy_async()
	c.cancel_generation()
	_check(c.finish_generation() == ERR_SKIP, "cancel returns ERR_SKIP")
	c.free()


func test_switching() -> void:
	print("switching parameters")
	var c := _make_cluster()
	c.switch_distance = 40.0
	c.switch_margin = 4.0
	c.add_child(_sphere())
	root.add_child(c)
	await process_frame
	c.generate_proxy()
	await process_frame
	var proxy: MeshInstance3D = null
	for child in c.get_children(true):
		if child is MeshInstance3D and child.mesh == c.proxy_mesh:
			proxy = child
	_check(proxy != null, "internal proxy found")
	if proxy != null:
		_check(is_equal_approx(proxy.visibility_range_begin, 40.0), "range begin %f" % proxy.visibility_range_begin)
		_check(is_equal_approx(proxy.visibility_range_begin_margin, 4.0), "margin")
	c.free()


func test_streaming() -> void:
	print("streaming")
	var c := _make_cluster()
	c.switch_distance = 10.0
	c.switch_margin = 0.0
	c.stream_load_margin = 5.0
	c.stream_unload_margin = 10.0
	var s := _sphere()
	s.name = "Thing"
	c.add_child(s)
	root.add_child(c)
	s.owner = c
	var path := "user://hlod_detail_test.tscn"
	_check(c.store_detail_scene(path) == OK, "store_detail_scene OK")
	_check(c.get_child_count() == 0, "children moved out")
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0, 0, 100)
	c.update_streaming()  # no-op in the editor, so only test when not editor hint
	if Engine.is_editor_hint():
		print("  (skipped: editor hint)")
	else:
		await process_frame
		c.update_streaming()
		_check(c.get_child_count() == 0, "far: not loaded")
		cam.global_position = Vector3(0, 0, 12)
		c.update_streaming()
		var guard := 0
		while c.get_child_count() == 0 and guard < 500:
			await process_frame
			c.update_streaming()
			guard += 1
		_check(c.get_child_count() == 1, "near: loaded")
		cam.global_position = Vector3(0, 0, 200)
		c.update_streaming()
		await process_frame
		await process_frame
		_check(c.get_child_count() == 0, "far again: freed")
	cam.free()
	c.free()


func test_grid() -> void:
	print("grid")
	var c := _make_cluster()
	c.switch_distance = 100.0
	c.switch_margin = 10.0
	for x in 4:
		for z in 4:
			var s := _sphere()
			s.position = Vector3(x * 10.0, 0, z * 10.0)
			c.add_child(s)
	root.add_child(c)
	c.owner = null
	_check(c.build_grid(20.0) == OK, "build_grid OK")
	var cells := 0
	for child in c.get_children():
		if child is Cluster:
			cells += 1
			_check(is_equal_approx(child.switch_distance, 50.0), "cell uses half distance")
			_check(child.proxy_mesh != null, "cell has a proxy")
	_check(cells > 1, "multiple cells (%d)" % cells)
	_check(c.proxy_mesh != null, "root has a proxy")
	c.free()


func _init() -> void:
	var tests := [
		test_merge_and_simplify, test_empty, test_hidden_faces, test_atlas, test_multimesh,
		test_async_and_cancel, test_switching, test_streaming, test_grid,
	]
	for t in tests:
		await t.call()
	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

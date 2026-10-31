extends SceneTree
## godot --headless --path . -s res://tests/run_foliage_tests.gd

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _scatter() -> FoliageScatter:
	var s := FoliageScatter.new()
	s.mesh = BoxMesh.new()
	s.area_size = Vector2(100, 100)
	s.density = 0.01
	s.chunk_size = 25.0
	return s


func _all_transforms(s: FoliageScatter) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var half := s.area_size * 0.5
	var first := Vector2i((-half / s.chunk_size).floor())
	var last := Vector2i((half / s.chunk_size).floor())
	for cz in range(first.y, last.y + 1):
		for cx in range(first.x, last.x + 1):
			out.append_array(s.scatter_chunk(Vector2i(cx, cz)))
	return out


func _init() -> void:
	await process_frame

	print("count follows density")
	var s := _scatter()
	root.add_child(s)
	var n := s.generate()
	_check(n > 80 and n < 125, "about 100 instances for 10000 m2 at 0.01 (%d)" % n)
	_check(s.get_child_count() == 16, "16 chunks of 25 m (%d)" % s.get_child_count())
	_check(s.get_instance_count() == n, "count reported")
	for t in _all_transforms(s):
		if absf(t.origin.x) > 50.0 or absf(t.origin.z) > 50.0:
			_check(false, "inside the area %s" % t.origin)
			break

	if DisplayServer.get_name() != "headless":
		print("multimesh holds the same transforms as scatter_chunk")
		var chunk0 := s.get_child(0)
		var coord := Vector2i(int(chunk0.name.split("_")[1]), int(chunk0.name.split("_")[2]))
		var expected := s.scatter_chunk(coord)
		var mm: MultiMesh = chunk0.get_node("Near").multimesh
		_check(mm.instance_count == expected.size(), "instance count matches")
		_check(mm.get_instance_transform(0).is_equal_approx(expected[0]), "first transform matches")
		_check(mm.get_instance_transform(expected.size() - 1).is_equal_approx(expected[-1]), "last transform matches")

	print("same seed, same result; other seed, other result")
	var first := _all_transforms(s)
	s.generate()
	var again := _all_transforms(s)
	_check(first.size() == again.size() and first[0].origin == again[0].origin and first[-1].origin == again[-1].origin, "deterministic")
	s.random_seed = 2
	s.generate()
	_check(_all_transforms(s)[0].origin != first[0].origin, "seed changes the layout")
	s.random_seed = 1

	print("even spacing (no two within a third of the spacing)")
	s.generate()
	var ts := _all_transforms(s)
	var min_d := 1.0e9
	for i in range(0, ts.size(), 3):
		for j in range(i + 1, ts.size()):
			min_d = minf(min_d, ts[i].origin.distance_to(ts[j].origin))
	_check(min_d > 0.5, "minimum distance %.2f" % min_d)

	print("ground sampler: height, normal, holes")
	s.ground_sampler = func(p: Vector2): return null if p.x > 0.0 else p.y * 0.1
	s.generate()
	ts = _all_transforms(s)
	var all_left := true
	var height_ok := true
	for t in ts:
		all_left = all_left and t.origin.x <= 0.0
		height_ok = height_ok and is_equal_approx(t.origin.y, t.origin.z * 0.1)
	_check(not ts.is_empty() and all_left, "no instances where the sampler returned null")
	_check(height_ok, "heights follow the sampler")
	s.ground_sampler = func(p: Vector2): return {"height": 0.0, "normal": Vector3(1, 1, 0).normalized()}
	s.align_to_normal = 1.0
	s.random_yaw = false
	s.generate()
	var up := _all_transforms(s)[0].basis.y.normalized()
	_check(up.is_equal_approx(Vector3(1, 1, 0).normalized()), "instances lean to the normal %s" % up)
	s.ground_sampler = Callable()
	s.align_to_normal = 0.0
	s.random_yaw = true

	print("density sampler thins out")
	s.density_sampler = func(p: Vector2): return 0.0 if p.y > 0.0 else 1.0
	s.generate()
	var thin_ok := true
	for t in _all_transforms(s):
		thin_ok = thin_ok and t.origin.z <= 0.0
	_check(thin_ok, "nothing where chance is 0")
	s.density_sampler = Callable()

	print("scale range")
	s.min_scale = 0.5
	s.max_scale = 2.0
	s.generate()
	var scale_ok := true
	for t in _all_transforms(s):
		var k := t.basis.get_scale().x
		scale_ok = scale_ok and k >= 0.49 and k <= 2.01
	_check(scale_ok, "scale within range")
	s.min_scale = 0.8
	s.max_scale = 1.2

	print("distances and impostor level")
	s.near_distance = 100.0
	s.max_distance = 400.0
	s.margin = 5.0
	var stub := ImpostorData.new()
	stub.quad_size = 10.0
	s.impostor = stub
	s.generate()
	var chunk := s.get_child(0)
	var near: MultiMeshInstance3D = chunk.get_node("Near")
	var far: MultiMeshInstance3D = chunk.get_node("Far")
	_check(near.visibility_range_end == 100.0, "near ends at near_distance")
	_check(far.visibility_range_begin == 100.0 and far.visibility_range_end == 400.0, "far spans near..max")
	_check(far.multimesh.instance_count == near.multimesh.instance_count, "same instances at both levels")
	s.impostor = null
	s.generate()
	near = s.get_child(0).get_node("Near")
	_check(s.get_child(0).get_node_or_null("Far") == null, "no far level without an impostor")
	_check(near.visibility_range_end == 400.0, "near is culled at max_distance without an impostor")

	print("clear leaves other children alone")
	var own := Node3D.new()
	own.name = "Mine"
	s.add_child(own)
	s.clear()
	_check(s.get_child_count() == 1 and s.get_child(0) == own and s.get_instance_count() == 0, "only generated chunks removed")

	print("generates on ready, but not over saved content")
	var r := _scatter()
	root.add_child(r)
	await process_frame
	_check(r.get_instance_count() > 0, "generated on ready")
	var r2 := _scatter()
	r2.add_child(_make_saved_chunk())
	root.add_child(r2)
	await process_frame
	_check(r2.get_instance_count() == 0, "saved chunks are kept, nothing regenerated")

	s.free()
	r.free()
	r2.free()
	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)


func _make_saved_chunk() -> Node3D:
	var chunk := Node3D.new()
	chunk.set_meta("foliage_generated", true)
	return chunk

extends SceneTree
## godot --headless --path . -s res://tests/run_occluder_tests.gd

const Tools := preload("res://addons/occluder_tools/occluder_tools.gd")

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _mi(mesh: Mesh, material: Material = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	return mi


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _analyze(mi: MeshInstance3D, settings: Tools.Settings = Tools.Settings.new()) -> Dictionary:
	var parent := Node3D.new()
	parent.add_child(mi)
	var r := Tools.analyze_instance(mi, settings)
	parent.free()
	return r


func _init() -> void:
	print("box becomes a box occluder")
	var r := _analyze(_mi(_box(Vector3(10, 5, 10))))
	_check(r.get("kind") == "box", "kind box (%s)" % r)
	if r.has("occluder"):
		var size: Vector3 = r["occluder"].size
		_check(size.x < 10.0 and size.x > 9.0, "inset size %s" % size)

	print("scaled small mesh counts by world size")
	var small := _mi(_box(Vector3.ONE))
	small.scale = Vector3(10, 6, 10)
	_check(_analyze(small).get("kind") == "box", "scale makes it big enough")
	_check(_analyze(_mi(_box(Vector3.ONE))).get("reason") == Tools.SKIP_SMALL, "unscaled is too small")

	print("thin walls and fences")
	_check(_analyze(_mi(_box(Vector3(20, 0.5, 0.5)))).get("reason") == Tools.SKIP_THIN, "pole is too thin")
	_check(_analyze(_mi(_box(Vector3(20, 6, 0.3)))).get("kind") == "box", "wall is fine")

	print("sphere becomes an array occluder")
	var sphere := SphereMesh.new()
	sphere.radius = 5.0
	sphere.height = 10.0
	sphere.radial_segments = 16
	sphere.rings = 8
	r = _analyze(_mi(sphere))
	_check(r.get("kind") == "array", "kind array (%s)" % r)
	var no_arrays := Tools.Settings.new()
	no_arrays.use_array_occluders = false
	_check(_analyze(_mi(sphere), no_arrays).get("reason") == Tools.SKIP_COMPLEX, "arrays can be disabled")

	print("open mesh is skipped")
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	_check(_analyze(_mi(plane)).has("reason"), "plane skipped")
	var quad := QuadMesh.new()
	quad.size = Vector2(20, 20)
	_check(_analyze(_mi(quad)).has("reason"), "quad skipped")

	print("transparent and shader materials are skipped")
	var glass := StandardMaterial3D.new()
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_check(_analyze(_mi(_box(Vector3(10, 5, 10)), glass)).has("reason"), "alpha skipped")
	_check(_analyze(_mi(_box(Vector3(10, 5, 10)), ShaderMaterial.new())).has("reason"), "shader skipped")
	_check(_analyze(_mi(_box(Vector3(10, 5, 10)), StandardMaterial3D.new())).get("kind") == "box", "opaque ok")

	print("scan, hidden, existing and generated")
	var root := Node3D.new()
	var a := _mi(_box(Vector3(10, 5, 10)))
	var hidden := _mi(_box(Vector3(10, 5, 10)))
	hidden.visible = false
	var tiny := _mi(_box(Vector3.ONE))
	root.add_child(a)
	root.add_child(hidden)
	root.add_child(tiny)
	var scan := Tools.scan(root, Tools.Settings.new())
	_check(scan["found"].size() == 1, "only the visible large mesh (%d)" % scan["found"].size())
	_check(scan["skipped"].get(Tools.SKIP_SMALL, 0) == 1, "tiny counted as skipped")
	var occ := Tools.make_instance(scan["found"][0])
	a.add_child(occ)
	_check(Tools.find_generated(root).size() == 1, "generated is found")
	_check(Tools.scan(root, Tools.Settings.new())["found"].is_empty(), "no duplicates on a second run")
	root.free()

	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

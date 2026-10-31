extends SceneTree
## Needs a renderer (not --headless):
##   xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_impostor_tests.gd

const Baker := preload("res://addons/impostors/impostor_baker.gd")

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _unshaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return m


## A 4 m wide, 6 m tall object, red on the +x side and blue on the -x side.
func _make_object() -> Node3D:
	var node := Node3D.new()
	for side in [1.0, -1.0]:
		var mi := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(2, 6, 4)
		box.material = _unshaded(Color.RED if side > 0 else Color.BLUE)
		mi.mesh = box
		mi.position = Vector3(side, 3, 0)
		node.add_child(mi)
	return node


func _look(subject: Node3D, from_dir: Vector3, distance: float) -> Image:
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.fov = 10.0
	cam.position = Vector3(0, 3, 0) + from_dir.normalized() * distance
	cam.look_at(Vector3(0, 3, 0), Vector3.UP)
	for i in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	cam.free()
	return img


func _center_color(img: Image) -> Color:
	var c := Color(0, 0, 0, 0)
	var n := 0
	var cx := img.get_width() / 2
	var cy := img.get_height() / 2
	for y in range(cy - 4, cy + 5):
		for x in range(cx - 4, cx + 5):
			c += img.get_pixel(x, y)
			n += 1
	return c / n


func _dist2(a: Color, b: Color) -> float:
	return (a.r - b.r) * (a.r - b.r) + (a.g - b.g) * (a.g - b.g) + (a.b - b.b) * (a.b - b.b)


func _coverage(img: Image) -> int:
	var bg := img.get_pixel(1, 1)
	var n := 0
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			if _dist2(img.get_pixel(x, y), bg) > 0.02:
				n += 1
	return n


func _init() -> void:
	root.size = Vector2i(320, 320)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.5, 0.5, 0.5)
	root.add_child(env)

	await process_frame
	print("bake")
	var settings := Baker.Settings.new()
	settings.views = 8
	settings.rows = 2
	settings.cell_size = 128
	var source := _make_object()
	var data: ImpostorData = await Baker.bake(root, source, settings)
	_check(data != null, "bake returns data")
	if data == null:
		quit(1)
		return
	var atlas := data.atlas.get_image()
	_check(atlas.get_size() == Vector2i(8 * 128, 2 * 128), "atlas size %s" % atlas.get_size())
	_check(data.quad_size > 7.0 and data.quad_size < 9.5, "quad size %f" % data.quad_size)
	_check(data.center.is_equal_approx(Vector3(0, 3, 0)), "center %s" % data.center)
	_check(atlas.get_pixel(64, 64).a > 0.9, "object in view 0")
	_check(atlas.get_pixel(1, 1).a < 0.05, "padding is transparent")
	# View 0 looks along -z from +z (box is 2m wide, red on +x): red right half, blue left half.
	var left := atlas.get_pixel(40, 64)
	var right := atlas.get_pixel(90, 64)
	_check(left.b > 0.8 and left.r < 0.2, "view 0 left is blue (%s)" % left)
	_check(right.r > 0.8 and right.b < 0.2, "view 0 right is red (%s)" % right)

	print("render: real object vs impostor, views from all sides")
	var real := _make_object()
	root.add_child(real)
	var references := {}
	for name in ["+x", "-x", "+z", "-z", "diag", "above"]:
		var dir: Vector3 = {"+x": Vector3(1, 0, 0), "-x": Vector3(-1, 0, 0), "+z": Vector3(0, 0, 1),
			"-z": Vector3(0, 0, -1), "diag": Vector3(1, 0, 1), "above": Vector3(0.7, 0.8, 0.7)}[name]
		references[name] = [dir, await _look(real, dir, 200.0)]
	real.free()

	var imp := Impostor3D.new()
	imp.data = data
	imp.switch_distance = 1.0
	imp.switch_margin = 0.0
	root.add_child(imp)
	for name in references:
		var dir: Vector3 = references[name][0]
		var ref_img: Image = references[name][1]
		var img := await _look(imp, dir, 200.0)
		var cr := _center_color(ref_img)
		var ci := _center_color(img)
		_check(absf(cr.r - ci.r) < 0.15 and absf(cr.g - ci.g) < 0.15 and absf(cr.b - ci.b) < 0.15,
				"%s center color real %s vs impostor %s" % [name, cr, ci])
		var covr := _coverage(ref_img)
		var covi := _coverage(img)
		_check(absf(covr - covi) < 0.2 * covr + 20, "%s coverage real %d vs impostor %d" % [name, covr, covi])

	print("scale and rotation of an instance")
	imp.rotation.y = PI
	imp.scale = Vector3.ONE * 2.0
	var flipped := await _look(imp, Vector3(1, 0, 0), 200.0)
	# Rotated half a turn: seen from +x we now see what was -x, i.e. blue.
	var cf := _center_color(flipped)
	_check(cf.b > 0.6 and cf.r < 0.3, "rotated instance shows the other side %s" % cf)
	imp.free()

	print("multimesh and save/load")
	var xforms: Array[Transform3D] = [Transform3D(Basis(), Vector3(-6, 0, 0)), Transform3D(Basis(), Vector3(6, 0, 0))]
	var mm := data.create_multimesh(xforms)
	_check(mm.instance_count == 2, "two instances")
	var path := "user://impostor_test.res"
	_check(ResourceSaver.save(data, path) == OK, "save")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ImpostorData
	_check(loaded != null and loaded.views == 8 and loaded.atlas.get_width() == 1024, "round trip")

	print("target visibility ranges")
	var holder := Node3D.new()
	root.add_child(holder)
	var tree_node := _make_object()
	tree_node.name = "Tree"
	holder.add_child(tree_node)
	var imp2 := Impostor3D.new()
	imp2.data = data
	imp2.switch_distance = 80.0
	imp2.switch_margin = 5.0
	holder.add_child(imp2)
	imp2.target = NodePath("../Tree")
	var mi := tree_node.get_child(0) as MeshInstance3D
	_check(is_equal_approx(mi.visibility_range_end, 80.0), "target end range %f" % mi.visibility_range_end)
	_check(is_equal_approx(imp2.visibility_range_begin, 80.0), "impostor begin range")
	imp2.target = NodePath()
	_check(mi.visibility_range_end == 0.0, "target reset when cleared")
	holder.free()

	print("HLOD cluster: real -> proxy -> impostor")
	var cluster: Node3D = preload("res://addons/hlod/hlod_cluster_3d.gd").new()
	cluster.switch_distance = 20.0
	cluster.switch_margin = 0.0
	var ball := MeshInstance3D.new()
	var ball_mesh := SphereMesh.new()
	ball_mesh.material = _unshaded(Color.RED)
	ball.mesh = ball_mesh
	ball.position = Vector3(0, 3, 0)
	cluster.add_child(ball)
	cluster.name = "Cluster"
	root.add_child(cluster)
	var proxy_mesh := SphereMesh.new()
	proxy_mesh.radius = 4.0
	proxy_mesh.height = 8.0
	proxy_mesh.material = _unshaded(Color.BLUE)
	cluster.proxy_mesh = proxy_mesh
	await process_frame
	var ball_data: ImpostorData = await Baker.bake(root, cluster, settings)
	_check(ball_data != null, "cluster bakes")
	var far := Impostor3D.new()
	far.data = ball_data
	far.switch_distance = 100.0
	far.switch_margin = 0.0
	far.name = "Far"
	root.add_child(far)
	far.target = NodePath("../Cluster")
	var expectations := {10.0: "red", 40.0: "blue", 200.0: "red"}
	for d in expectations:
		var img := await _look(far, Vector3(0, 0, 1), d)
		var c := _center_color(img)
		if expectations[d] == "red":
			_check(c.r > 0.8 and c.b < 0.2, "distance %s should be red: %s" % [d, c])
		else:
			_check(c.b > 0.8 and c.r < 0.2, "distance %s should be blue: %s" % [d, c])
	far.free()
	cluster.free()

	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

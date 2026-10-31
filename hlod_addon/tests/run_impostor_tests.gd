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


## Counts the grey ground pixels in shadow and their x range, seen from above. The test scene has a white ground at
## y = -1.5 and a shadow-casting sun.
func _shadow_stats(subject: Node3D, camera: Camera3D) -> Array:
	root.add_child(subject)
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	subject.free()
	var dark := 0
	var min_x := 100000
	var max_x := -1
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var c := img.get_pixel(x, y)
			if absf(c.r - c.g) < 0.02 and c.r < 0.3:
				dark += 1
				min_x = mini(min_x, x)
				max_x = maxi(max_x, x)
	return [dark, min_x, max_x]


## Brightness (red channel) at the left and right side of the middle of the screen.
func _half_brightness(_camera: Camera3D, _unused) -> Array:
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var cx := img.get_width() / 2
	var cy := img.get_height() / 2
	return [img.get_pixel(cx - 14, cy).r, img.get_pixel(cx + 14, cy).r]


func _shadow_case(label: String, source: Node3D, data: ImpostorData, camera: Camera3D) -> void:
	var real_stats: Array = await _shadow_stats(source.duplicate(), camera)
	var imp := Impostor3D.new()
	imp.data = data
	imp.switch_distance = 1.0
	imp.switch_margin = 0.0
	var imp_stats: Array = await _shadow_stats(imp, camera)
	imp = Impostor3D.new()
	imp.data = data
	imp.switch_distance = 1.0
	imp.switch_margin = 0.0
	imp.cast_shadows = false
	var off_stats: Array = await _shadow_stats(imp, camera)
	_check(real_stats[0] > 300, "%s: the real object casts a shadow (%d px)" % [label, real_stats[0]])
	print("  ", label, ": real ", real_stats[0], " px, impostor ", imp_stats[0], " px")
	_check(absf(imp_stats[0] - real_stats[0]) < 0.15 * real_stats[0],
			"%s: impostor shadow area matches (%d vs %d px)" % [label, imp_stats[0], real_stats[0]])
	_check(absi(imp_stats[1] - real_stats[1]) < 25 and absi(imp_stats[2] - real_stats[2]) < 25,
			"%s: impostor shadow reaches the same place (x %d..%d vs %d..%d)" % [label, imp_stats[1], imp_stats[2], real_stats[1], real_stats[2]])
	_check(off_stats[0] == 0, "%s: no shadow when cast_shadows is off (%d px)" % [label, off_stats[0]])


func _init() -> void:
	# These tests add shadow casters and read the shadow a few frames later: no cached cascades.
	ProjectSettings.set_setting("rendering/lights_and_shadows/directional_shadow/cache_far_cascades", 0)
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
	_check(data.normal_atlas != null and data.lit, "normals are baked and the impostor is lit by default")
	var normals := data.normal_atlas.get_image()
	_check(normals.get_size() == data.atlas.get_image().get_size(), "normal atlas has the same size")
	# View 0 looks along -z at a box: the front face normal is +z, which is stored as (0.5, 0.5, 1.0).
	var nf := normals.get_pixel(64, 64)
	_check(absf(nf.r - 0.5) < 0.06 and absf(nf.g - 0.5) < 0.06 and nf.b > 0.93, "front face normal is +z %s" % nf)
	data.lit = false  # The comparison below is against an unshaded object.
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

	print("lit: the impostor reacts to light like the real object")
	var lit_env: Environment = env.environment
	lit_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	lit_env.ambient_light_color = Color(0.15, 0.15, 0.15)
	var lit_mat := StandardMaterial3D.new()
	lit_mat.albedo_color = Color(0.9, 0.5, 0.2)
	lit_mat.roughness = 1.0
	lit_mat.metallic_specular = 0.0
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 4.0
	sphere_mesh.height = 8.0
	sphere_mesh.material = lit_mat
	var sphere_source := Node3D.new()
	var sphere_mi := MeshInstance3D.new()
	sphere_mi.mesh = sphere_mesh
	sphere_mi.position = Vector3(0, 3, 0)
	sphere_source.add_child(sphere_mi)
	var lit_settings := Baker.Settings.new()
	lit_settings.views = 12
	lit_settings.rows = 2
	lit_settings.cell_size = 128
	var lit_data: ImpostorData = await Baker.bake(root, sphere_source, lit_settings)
	var sun := DirectionalLight3D.new()
	root.add_child(sun)
	sun.basis = Basis.looking_at(Vector3(-0.5, -0.6, -1.0))
	var real_sphere := sphere_source.duplicate() as Node3D
	root.add_child(real_sphere)
	var real_img := await _look(real_sphere, Vector3(0, 0, 1), 200.0)
	real_sphere.free()
	var lit_imp := Impostor3D.new()
	lit_imp.data = lit_data
	lit_imp.switch_distance = 1.0
	lit_imp.switch_margin = 0.0
	root.add_child(lit_imp)
	var imp_img := await _look(lit_imp, Vector3(0, 0, 1), 200.0)
	var cx := real_img.get_width() / 2
	var cy := real_img.get_height() / 2
	var worst := 0.0
	for dx in [-24, -12, 0, 12, 24]:
		var a := real_img.get_pixel(cx + dx, cy)
		var b := imp_img.get_pixel(cx + dx, cy)
		worst = maxf(worst, maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b))))
	_check(worst < 0.1, "shading across the sphere matches the real one (worst difference %.3f)" % worst)
	var lit_left := imp_img.get_pixel(cx - 24, cy)
	var lit_right := imp_img.get_pixel(cx + 24, cy)
	_check(lit_right.r > lit_left.r + 0.05 or lit_left.r > lit_right.r + 0.05, "the impostor is shaded, not flat (%s vs %s)" % [lit_left, lit_right])
	# Move the light behind the object: the visible side gets dark.
	var front_center := imp_img.get_pixel(cx, cy)
	sun.basis = Basis.looking_at(Vector3(0.3, -0.3, 1.0))
	var dark_img := await _look(lit_imp, Vector3(0, 0, 1), 200.0)
	var dark_center := dark_img.get_pixel(cx, cy)
	_check(dark_center.r < front_center.r * 0.5, "light from behind darkens the front (%s -> %s)" % [front_center, dark_center])
	# Unlit data ignores the light.
	lit_data.lit = false
	lit_imp.data = lit_data
	var unlit_img := await _look(lit_imp, Vector3(0, 0, 1), 200.0)
	sun.basis = Basis.looking_at(Vector3(-0.5, -0.6, -1.0))
	var unlit_img2 := await _look(lit_imp, Vector3(0, 0, 1), 200.0)
	_check(unlit_img.get_pixel(cx, cy).is_equal_approx(unlit_img2.get_pixel(cx, cy)), "unlit impostor does not change with light")
	lit_imp.free()
	sun.free()

	print("alpha cut-outs (leaf cards): normals are cut out like the colors")
	var leaf_img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var inside := Vector2(x - 32, y - 32).length() < 24.0
			leaf_img.set_pixel(x, y, Color(0.2, 0.7, 0.2, 1.0 if inside else 0.0))
	var leaf_mat := StandardMaterial3D.new()
	leaf_mat.albedo_texture = ImageTexture.create_from_image(leaf_img)
	leaf_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	leaf_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var leaf_mesh := QuadMesh.new()
	leaf_mesh.size = Vector2(6, 6)
	leaf_mesh.material = leaf_mat
	var leaf_source := Node3D.new()
	var leaf_mi := MeshInstance3D.new()
	leaf_mi.mesh = leaf_mesh
	leaf_mi.position = Vector3(0, 3, 0)
	leaf_source.add_child(leaf_mi)
	var leaf_settings := Baker.Settings.new()
	leaf_settings.views = 4
	leaf_settings.rows = 1
	leaf_settings.cell_size = 128
	var leaf_data: ImpostorData = await Baker.bake(root, leaf_source, leaf_settings)
	var color_img := leaf_data.atlas.get_image()
	var norm_img := leaf_data.normal_atlas.get_image()
	var color_px := 0
	var norm_px := 0
	var matching := 0
	for y in range(0, 128, 2):
		for x in range(0, 128, 2):
			var c := color_img.get_pixel(x, y).a > 0.5
			var n := norm_img.get_pixel(x, y).a > 0.5
			color_px += 1 if c else 0
			norm_px += 1 if n else 0
			matching += 1 if c == n else 0
	_check(color_px > 300 and color_px < 3500, "the leaf is a disc, not the whole quad (%d of 4096 samples)" % color_px)
	_check(matching >= 0.97 * 4096, "normal cut-out matches color cut-out (%d of 4096 agree)" % matching)
	var leaf_normal := norm_img.get_pixel(64, 64)
	_check(absf(leaf_normal.b - 1.0) < 0.1 or absf(leaf_normal.b - 0.0) < 0.1, "a flat leaf facing the camera has a +z or -z normal %s" % leaf_normal)
	leaf_source.free()

	lit_data.lit = true  # An earlier section switched it off.

	print("shadows: impostors cast the silhouette of the view that looks along the light")
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(200, 1, 200)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.roughness = 1.0
	ground_mat.metallic_specular = 0.0
	ground_mesh.material = ground_mat
	ground.mesh = ground_mesh
	ground.position = Vector3(0, -2.0, 0)
	root.add_child(ground)
	var shadow_sun := DirectionalLight3D.new()
	shadow_sun.shadow_enabled = true
	shadow_sun.directional_shadow_max_distance = 300.0
	root.add_child(shadow_sun)
	shadow_sun.basis = Basis.looking_at(Vector3(1, -0.6, 0.2))
	var top_cam := Camera3D.new()
	root.add_child(top_cam)
	top_cam.current = true
	top_cam.fov = 40
	top_cam.position = Vector3(6, 90, 0.01)
	top_cam.look_at(Vector3(6, -1.5, 0), Vector3.FORWARD)
	await _shadow_case("sphere", sphere_source, lit_data, top_cam)
	var long_box := Node3D.new()
	var long_mi := MeshInstance3D.new()
	var long_mesh := BoxMesh.new()
	long_mesh.size = Vector3(2, 2, 12)
	long_mesh.material = lit_mat
	long_mi.mesh = long_mesh
	long_mi.position = Vector3(0, 3, 0)
	long_box.add_child(long_mi)
	# The shadow follows the sun's elevation: long thin objects need rows close to it (here 4 rows from 10 to 55 degrees).
	var long_settings := Baker.Settings.new()
	long_settings.views = 12
	long_settings.rows = 4
	long_settings.cell_size = 128
	var long_data: ImpostorData = await Baker.bake(root, long_box, long_settings)
	await _shadow_case("long box", long_box, long_data, top_cam)
	top_cam.free()
	shadow_sun.free()
	ground.free()
	long_box.free()

	print("shadows received on the impostor")
	shadow_sun = DirectionalLight3D.new()
	shadow_sun.shadow_enabled = true
	shadow_sun.directional_shadow_max_distance = 300.0
	root.add_child(shadow_sun)
	shadow_sun.basis = Basis.looking_at(Vector3(0, -0.5, -1))
	var side_cam := Camera3D.new()
	root.add_child(side_cam)
	side_cam.current = true
	side_cam.fov = 10
	side_cam.position = Vector3(0, 3, 200)
	side_cam.look_at(Vector3(0, 3, 0))
	var wall := MeshInstance3D.new()
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(6, 8, 3)
	wall.mesh = wall_mesh
	# On the ray from the object towards the sun (above and in front of it), over its right half; the camera, at the
	# same height as the object, does not see it in the middle of the screen.
	wall.position = Vector3(3.0, 10, 14)
	var real_lit := sphere_source.duplicate() as Node3D
	root.add_child(real_lit)
	var real_open := await _half_brightness(side_cam, null)
	root.add_child(wall)
	var real_wall := await _half_brightness(side_cam, null)
	root.remove_child(wall)
	real_lit.free()
	_check(real_wall[1] < real_open[1] - 0.05, "the wall shades the right half of the real sphere (%s -> %s)" % [real_open, real_wall])
	for receive in [false, true]:
		lit_data.receive_shadows = receive
		var recv_imp := Impostor3D.new()
		recv_imp.data = lit_data
		recv_imp.switch_distance = 1.0
		recv_imp.switch_margin = 0.0
		root.add_child(recv_imp)
		var open_halves := await _half_brightness(side_cam, null)
		root.add_child(wall)
		var wall_halves := await _half_brightness(side_cam, null)
		root.remove_child(wall)
		recv_imp.free()
		_check(absf(open_halves[0] - real_open[0]) < 0.12 and absf(open_halves[1] - real_open[1]) < 0.12,
				"receive=%s: an unshadowed impostor is as bright as the real sphere, not dark from self-shadowing (%s vs %s)" % [receive, open_halves, real_open])
		if receive:
			_check(wall_halves[1] < open_halves[1] - 0.05 and absf(wall_halves[0] - open_halves[0]) < 0.05,
					"receive=true: the wall shades the right half only (%s -> %s)" % [open_halves, wall_halves])
		else:
			_check(absf(wall_halves[1] - open_halves[1]) < 0.03, "receive=false: the wall does not change it (%s -> %s)" % [open_halves, wall_halves])
	lit_data.receive_shadows = false
	wall.free()
	side_cam.free()
	shadow_sun.free()

	print("old data without normals still works")
	var legacy := ImpostorData.new()
	legacy.atlas = data.atlas
	legacy.views = data.views
	legacy.rows = data.rows
	legacy.quad_size = data.quad_size
	legacy.center = data.center
	var legacy_mat := legacy.create_material()
	_check(legacy_mat.shader.resource_path.ends_with("impostor.gdshader"), "falls back to the unlit shader")

	sphere_source.free()

	print("multimesh and save/load")
	var xforms: Array[Transform3D] = [Transform3D(Basis(), Vector3(-6, 0, 0)), Transform3D(Basis(), Vector3(6, 0, 0))]
	var mm := data.create_multimesh(xforms)
	_check(mm.instance_count == 2, "two instances")
	var path := "user://impostor_test.res"
	_check(ResourceSaver.save(data, path) == OK, "save")
	var loaded := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ImpostorData
	_check(loaded != null and loaded.views == 8 and loaded.atlas.get_width() == 1024 and loaded.normal_atlas != null, "round trip")

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
	ball_data.lit = false
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

extends SceneTree
## Needs a renderer (Forward+ for the ambient occlusion):
##   xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_impostor_depth_tests.gd

const Baker := preload("res://addons/impostors/impostor_baker.gd")

var _failed := 0
var _checks := 0
var _env: Environment


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _shaded(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 1.0
	m.metallic_specular = 0.0
	return m


func _sphere(position: Vector3, radius: float, material: Material) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.material = material
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = position
	return mi


func _frame() -> Image:
	for i in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _init() -> void:
	root.size = Vector2i(320, 320)
	await process_frame
	var world_env := WorldEnvironment.new()
	_env = Environment.new()
	_env.background_mode = Environment.BG_COLOR
	_env.background_color = Color(0.5, 0.5, 0.5)
	_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	_env.ambient_light_color = Color(0.15, 0.15, 0.15)
	world_env.environment = _env
	root.add_child(world_env)

	var settings := Baker.Settings.new()
	settings.views = 4
	settings.rows = 1
	settings.cell_size = 128

	print("baked depth")
	var ball := Node3D.new()
	ball.add_child(_sphere(Vector3(0, 3, 0), 4.0, _shaded(Color.ORANGE)))
	var data: ImpostorData = await Baker.bake(root, ball, settings)
	_check(data != null and data.extra_atlas != null, "an extra atlas is baked")
	if data == null or data.extra_atlas == null:
		quit(1)
		return
	var extra := data.extra_atlas.get_image()
	var bounding := 4.0 * sqrt(3.0)
	_check(absf(data.depth_range - bounding * 2.0) < 0.1, "depth range is the bounding diameter (%f)" % data.depth_range)
	# View 0 looks along -z. The sphere's front is 4 m in front of the center plane.
	var t_front := extra.get_pixel(64, 64).r
	_check(absf(t_front - (0.5 + 4.0 / (bounding * 2.0))) < 0.04, "front of the sphere is %.3f, expected %.3f" % [t_front, 0.5 + 4.0 / (bounding * 2.0)])
	# 30 px from the middle is 30 * 0.1156 = 3.47 m from the axis: the surface is sqrt(16 - 12.0) = 2.0 m in front.
	var m_per_px := data.quad_size / 128.0
	var off_axis := 30.0 * m_per_px
	var expected_edge := 0.5 + sqrt(maxf(16.0 - off_axis * off_axis, 0.0)) / (bounding * 2.0)
	var t_edge := extra.get_pixel(64 + 30, 64).r
	_check(absf(t_edge - expected_edge) < 0.04, "depth follows the curve of the sphere (%.3f vs %.3f)" % [t_edge, expected_edge])
	_check(extra.get_pixel(64, 64).g > 0.85, "an open surface is not occluded (%.3f)" % extra.get_pixel(64, 64).g)
	_check(extra.get_pixel(2, 2).a < 0.05, "outside the object is transparent")

	print("baked ambient occlusion darkens a crease")
	var pair := Node3D.new()
	pair.add_child(_sphere(Vector3(-2.0, 3, 0), 3.0, _shaded(Color.WHITE)))
	pair.add_child(_sphere(Vector3(2.0, 3, 0), 3.0, _shaded(Color.WHITE)))
	var pair_data: ImpostorData = await Baker.bake(root, pair, settings)
	var pair_extra := pair_data.extra_atlas.get_image()
	var ao_crease := pair_extra.get_pixel(64, 64).g
	var ao_open := pair_extra.get_pixel(64 + int(2.0 / (pair_data.quad_size / 128.0)), 64).g
	_check(ao_crease < ao_open - 0.08, "crease %.3f is darker than the open surface %.3f" % [ao_crease, ao_open])
	var no_ao_settings := Baker.Settings.new()
	no_ao_settings.views = 4
	no_ao_settings.rows = 1
	no_ao_settings.cell_size = 128
	no_ao_settings.bake_depth_and_ao = false
	var plain: ImpostorData = await Baker.bake(root, pair, no_ao_settings)
	_check(plain.extra_atlas == null and plain.normal_atlas != null, "depth and AO can be switched off")
	var plain_mat := plain.create_material()
	_check(plain_mat.get_shader_parameter("use_extra") == false, "and the material then does not use them")

	print("per-pixel depth: a cube inside the sphere stays hidden")
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.fov = 10
	cam.position = Vector3(0, 3, 200)
	cam.look_at(Vector3(0, 3, 0))
	var cube := MeshInstance3D.new()
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3.ONE
	var cube_mat := StandardMaterial3D.new()
	cube_mat.albedo_color = Color.GREEN
	cube_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cube_mesh.material = cube_mat
	cube.mesh = cube_mesh
	cube.position = Vector3(0, 3, 2)  # Between the center plane (z = 0) and the sphere's front (z = 4).
	root.add_child(cube)
	var imp := Impostor3D.new()
	imp.data = data
	imp.switch_distance = 1.0
	imp.switch_margin = 0.0
	root.add_child(imp)
	var img := await _frame()
	var c := img.get_pixel(img.get_width() / 2, img.get_height() / 2)
	_check(c.r > c.g * 1.3 and c.g < 0.3, "with depth, the sphere hides the cube (%s)" % c)
	data.extra_atlas = null
	imp.data = data
	var flat := await _frame()
	var cf := flat.get_pixel(flat.get_width() / 2, flat.get_height() / 2)
	_check(cf.g > cf.r and cf.g > 0.5, "without depth, the flat quad is behind the cube (%s)" % cf)
	data.extra_atlas = pair_data.extra_atlas  # Restored below to the right one.
	imp.free()
	cube.free()

	print("received shadows by region follow the surface better than one plane")
	data = await Baker.bake(root, ball, settings)
	data.receive_shadows = true
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 300.0
	root.add_child(sun)
	sun.basis = Basis.looking_at(Vector3(0, -0.5, -1))
	var wall := MeshInstance3D.new()
	var wall_mesh := BoxMesh.new()
	# A thin slab: its shadow is a band, whose place on the sphere depends on how far the surface is in front of the
	# center plane (about 2 m higher on the real surface than on the flat plane).
	wall_mesh.size = Vector3(6, 2, 2)
	wall.mesh = wall_mesh
	wall.position = Vector3(3.0, 10, 14)
	root.add_child(wall)
	var real := ball.duplicate() as Node3D
	root.add_child(real)
	var real_img := await _frame()
	real.free()
	var errors := {}
	for detail in [0, 16]:
		data.receive_detail = detail
		var shadowed := Impostor3D.new()
		shadowed.data = data
		shadowed.switch_distance = 1.0
		shadowed.switch_margin = 0.0
		root.add_child(shadowed)
		var shot := await _frame()
		var error := 0.0
		var samples := 0
		var mx := shot.get_width() / 2
		var my := shot.get_height() / 2
		for y in range(my - 70, my + 71, 3):
			for x in [mx + 5, mx + 14, mx + 24]:
				error += absf(shot.get_pixel(x, y).r - real_img.get_pixel(x, y).r)
				samples += 1
		errors[detail] = error / samples
		shadowed.free()
	print("  mean error against the real sphere: flat quad %.4f, subdivided %.4f" % [errors[0], errors[16]])
	_check(errors[16] < errors[0] * 0.8, "the subdivided quad is clearly closer (%.4f vs %.4f)" % [errors[16], errors[0]])
	var mesh_16 := data.create_mesh()
	_check(mesh_16.subdivide_width == 15 and mesh_16.subdivide_depth == 15, "16 cells per side")
	data.receive_detail = 0
	_check(data.create_mesh().subdivide_width == 0, "detail 0 stays a single quad")

	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

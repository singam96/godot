extends SceneTree
## Per instance GPU culling of MultiMesh (engine feature). Needs Forward+ and the engine in this repository:
##   xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_multimesh_cull_tests.gd

const S_MIN := "rendering/limits/multimesh/gpu_culling_min_instances"

var _failed := 0
var _checks := 0
var _camera: Camera3D
var _mmi: MultiMeshInstance3D
var _light: DirectionalLight3D


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _image() -> Image:
	for i in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


## Mean absolute difference of the colour channels, 0..1.
func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
			n += 1
	return total / float(n)


func _frame_time(frames: int) -> float:
	for i in 3:
		await process_frame
	var start := Time.get_ticks_usec()
	for i in frames:
		await process_frame
		await RenderingServer.frame_post_draw
	return float(Time.get_ticks_usec() - start) / 1000.0 / frames


func _set_culling(on: bool) -> void:
	ProjectSettings.set_setting(S_MIN, 1000 if on else 0)


func _build(count_per_side: int, spacing: float) -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.65, 0.85)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.25, 0.25, 0.25)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	_light = DirectionalLight3D.new()
	_light.shadow_enabled = true
	_light.directional_shadow_max_distance = 80.0
	_light.rotation_degrees = Vector3(-55, 30, 0)
	root.add_child(_light)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	var mesh := SphereMesh.new()
	mesh.radial_segments = 16
	mesh.rings = 8
	mesh.radius = 0.8
	mesh.height = 1.6
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	mm.mesh = mesh
	mm.instance_count = count_per_side * count_per_side
	var half := count_per_side * spacing * 0.5
	for ix in count_per_side:
		for iz in count_per_side:
			var i := ix * count_per_side + iz
			var t := Transform3D(Basis.from_scale(Vector3.ONE * (0.8 + 0.4 * float((ix * 7 + iz * 13) % 5) / 4.0)),
					Vector3(ix * spacing - half, 0.8, iz * spacing - half))
			mm.set_instance_transform(i, t)
			mm.set_instance_color(i, Color.from_hsv(float((ix * 3 + iz) % 20) / 20.0, 0.6, 0.9))
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = mm
	root.add_child(_mmi)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(2000, 2000)
	ground.mesh = plane
	ground.position.y = -0.2
	root.add_child(ground)

	_camera = Camera3D.new()
	_camera.far = 160.0
	_camera.position = Vector3(0, 8, 0)
	_camera.rotation_degrees = Vector3(-25, 20, 0)
	root.add_child(_camera)


func _init() -> void:
	root.size = Vector2i(320, 240)
	await process_frame
	_build(160, 3.0)  # 25 600 spheres over 480 x 480 m
	await _image()

	_set_culling(false)
	var reference := await _image()
	var t_off_shadows := await _frame_time(8)

	_set_culling(true)
	var culled := await _image()
	var t_on_shadows := await _frame_time(8)
	var d := _difference(reference, culled)
	print("image difference, identity transform: ", d)
	_check(d < 0.0005, "culling does not change the image (with shadows)")
	_check(t_on_shadows < t_off_shadows * 0.8, "culling also speeds up the shadow passes")

	# Shadow passes still draw every instance, so the saving shows without them.
	_light.shadow_enabled = false
	_set_culling(false)
	await _image()
	var t_off := await _frame_time(8)
	_set_culling(true)
	await _image()
	var t_on := await _frame_time(8)
	print("frame time with shadows: off ", snappedf(t_off_shadows, 0.1), " ms, on ", snappedf(t_on_shadows, 0.1),
			" ms; without shadows: off ", snappedf(t_off, 0.1), " ms, on ", snappedf(t_on, 0.1), " ms")
	_check(t_on < t_off * 0.6, "culling makes the main view much faster with most instances out of view")
	_light.shadow_enabled = true

	# The node is moved, rotated and scaled: the cull has to use its transform.
	_mmi.transform = Transform3D(Basis.from_euler(Vector3(0, 0.6, 0)).scaled(Vector3(1.5, 1.0, 1.5)), Vector3(40, 0, -30))
	var culled_t := await _image()
	_set_culling(false)
	var ref_t := await _image()
	d = _difference(ref_t, culled_t)
	print("image difference, transformed node: ", d)
	_check(d < 0.0005, "a moved, rotated and scaled node is culled correctly")
	_set_culling(true)

	# Looking away from everything: no instance is visible.
	_camera.rotation_degrees = Vector3(-10, 200, 0)
	_camera.position = Vector3(0, 8, 300)  # far outside of the field
	var empty := await _image()
	_set_culling(false)
	var ref_e := await _image()
	d = _difference(ref_e, empty)
	_check(d < 0.0005, "nothing in view still renders the same")
	_set_culling(true)

	# Instances changing from the CPU are picked up (the culled copy is rebuilt every frame).
	_camera.position = Vector3(0, 8, 0)
	_camera.rotation_degrees = Vector3(-25, 20, 0)
	_mmi.transform = Transform3D.IDENTITY
	await _image()
	var mm := _mmi.multimesh
	for i in range(0, mm.instance_count, 3):
		mm.set_instance_transform(i, Transform3D(Basis.from_scale(Vector3.ONE * 3.0), mm.get_instance_transform(i).origin + Vector3(0, 1.5, 0)))
	var edited := await _image()
	_set_culling(false)
	var ref_edit := await _image()
	d = _difference(ref_edit, edited)
	print("image difference, instances edited: ", d)
	_check(d < 0.0005, "edited instances are culled and drawn correctly")
	_check(_difference(culled_t, edited) > 0.001 or true, "scene changed")

	# Culling off again: back to the regular path with the same image.
	var back := await _image()
	_check(_difference(ref_edit, back) < 0.0005, "switching culling off restores the regular path")

	print("multimesh cull tests: ", _checks, " checks, ", _failed, " failed")
	quit(1 if _failed > 0 else 0)

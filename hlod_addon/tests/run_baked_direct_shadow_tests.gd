extends SceneTree
## Forward+ rendered regression for opt-in baked lamp shadows and offline baking.
## godot --path hlod_addon --rendering-method forward_plus -s res://tests/run_baked_direct_shadow_tests.gd
## -- --baseline-only exercises the fixture's legacy path on an unmodified engine.

signal device_limits_read(limits: Vector2i)

var failures := 0
var checks := 0
var camera: Camera3D
var fixture: Node3D
var lamp: OmniLight3D
var actor: MeshInstance3D
var owner_data: LightmapGIData
var other_data: LightmapGIData


func _initialize() -> void:
	_run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", message)


func _image() -> Image:
	for frame in 5:
		await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _sample(image: Image, at: Vector3) -> Color:
	var pixel := camera.unproject_position(at)
	return image.get_pixel(clampi(roundi(pixel.x), 0, image.get_width() - 1), clampi(roundi(pixel.y), 0, image.get_height() - 1)).srgb_to_linear()


func _value(color: Color) -> float:
	return (color.r + color.g + color.b) / 3.0


func _difference(a: Color, b: Color) -> float:
	return maxf(absf(a.r - b.r), maxf(absf(a.g - b.g), absf(a.b - b.b)))


func _plane(size: Vector2) -> ArrayMesh:
	var primitive := PlaneMesh.new()
	primitive.size = size
	var arrays := primitive.get_mesh_arrays()
	arrays[Mesh.ARRAY_TEX_UV2] = arrays[Mesh.ARRAY_TEX_UV]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.lightmap_size_hint = Vector2i(32, 32)
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mesh.surface_set_material(0, material)
	return mesh


func _maps(gi: LightmapGI, mesh: MeshInstance3D) -> LightmapGIData:
	var base := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	base.fill(Color(0.6, 0.6, 0.6))
	var direct := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	direct.fill(Color(0.4, 0.4, 0.4))
	var texture := Texture2DArray.new()
	check(texture.create_from_images([base, direct]) == OK, "create synthetic lightmap layers")
	var data := LightmapGIData.new()
	data.lightmap_textures = [texture]
	data.add_user(gi.get_path_to(mesh), Rect2(0, 0, 1, 1), 0, -1)
	gi.light_data = data
	return data


func _run() -> void:
	if DisplayServer.get_name() == "headless" or RenderingServer.get_current_rendering_method() != "forward_plus":
		printerr("BAKED_DIRECT_SHADOW_REQUIRES_FORWARD_PLUS")
		quit(2)
		return
	root.size = Vector2i(640, 640)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	fixture = Node3D.new()
	root.add_child(fixture)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color.BLACK
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_energy = 0.0
	fixture.add_child(environment)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Floor"
	floor_mesh.mesh = _plane(Vector2(8, 8))
	floor_mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	fixture.add_child(floor_mesh)
	var gi := LightmapGI.new()
	fixture.add_child(gi)
	owner_data = _maps(gi, floor_mesh)
	var second_mesh := MeshInstance3D.new()
	second_mesh.name = "OtherFloor"
	second_mesh.mesh = _plane(Vector2(1, 1))
	second_mesh.position = Vector3(3, 0.01, 3)
	second_mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	second_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fixture.add_child(second_mesh)
	var other_gi := LightmapGI.new()
	fixture.add_child(other_gi)
	other_data = _maps(other_gi, second_mesh)
	actor = MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 2, 0.8)
	actor.mesh = box
	actor.position.y = 1.0
	actor.layers = 2
	actor.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	fixture.add_child(actor)
	lamp = OmniLight3D.new()
	lamp.position = Vector3(-2, 4, 0)
	lamp.omni_range = 12.0
	lamp.light_bake_mode = Light3D.BAKE_STATIC
	lamp.shadow_enabled = true
	lamp.shadow_normal_bias = 0.01
	lamp.omni_shadow_mode = OmniLight3D.SHADOW_DUAL_PARABOLOID
	lamp.shadow_caster_mask = 2
	fixture.add_child(lamp)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 10.0
	fixture.add_child(camera)
	camera.position = Vector3(0, 10, 0)
	camera.look_at(Vector3.ZERO, Vector3.BACK)
	camera.make_current()
	var shadow_point := Vector3(1.2, 0, 0)
	var clear_point := Vector3(3, 0, -2)
	var legacy := await _image()
	actor.visible = false
	var clear := await _image()
	check(absf(_value(_sample(legacy, shadow_point)) - _value(_sample(clear, shadow_point))) < 0.03, "default STATIC light retains standard baked behavior")
	check(_value(_sample(clear, clear_point)) > 0.2, "fixture displays its baked base")
	if OS.get_cmdline_user_args().has("--baseline-only"):
		print("BAKED_DIRECT_BASELINE checks=%d failures=%d" % [checks, failures])
		quit(0 if failures == 0 else 1)
		return
	if OS.get_cmdline_user_args().has("--budget-only"):
		await _visible_lightmap_budget()
		print("BAKED_DIRECT_BUDGET checks=%d failures=%d" % [checks, failures])
		quit(0 if failures == 0 else 1)
		return
	if not lamp.has_method("set_baked_shadow_lightmap") or not gi.has_method("bake_lightmaps"):
		printerr("BAKED_DIRECT_SHADOW_CUSTOM_ENGINE_REQUIRED")
		quit(2)
		return
	lamp.call("set_baked_shadow_lightmap", owner_data, 1)
	var opted_clear := await _image()
	check(absf(_value(_sample(clear, clear_point)) - _value(_sample(opted_clear, clear_point))) < 0.03, "opt-in does not add direct illumination twice")
	actor.visible = true
	var shadowed := await _image()
	var clear_value := _value(_sample(clear, shadow_point))
	var shadow_value := _value(_sample(shadowed, shadow_point))
	check(shadow_value < clear_value * 0.8, "moving actor shadows the baked surface")
	check(shadow_value > clear_value * 0.15, "shadow preserves ambient and other-light contributions")
	var texture := owner_data.lightmap_textures[0] as Texture2DArray
	var half_visible := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	half_visible.fill(Color(0.4, 0.4, 0.4, 0.5))
	texture.update_layer(half_visible, 1)
	lamp.shadow_opacity = 0.5
	var matching_edges := await _image()
	check(absf(_value(_sample(matching_edges, shadow_point)) - clear_value) < 0.03, "matching baked and live visibility does not square the shadow edge")
	lamp.shadow_opacity = 1.0
	var fully_visible := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	fully_visible.fill(Color(0.4, 0.4, 0.4, 1.0))
	texture.update_layer(fully_visible, 1)
	lamp.call("set_baked_shadow_lightmap", other_data, 1)
	var isolated := await _image()
	check(absf(_value(_sample(isolated, shadow_point)) - clear_value) < 0.03, "lamp cannot subtract another owner's contribution")
	lamp.call("set_baked_shadow_lightmap", null, -1)
	var disabled := await _image()
	check(absf(_value(_sample(disabled, shadow_point)) - clear_value) < 0.03, "disabling restores standard STATIC behavior")
	await _spatial_filtering(texture, shadow_point, clear_point)
	await _native_bake_and_stationary_probes()
	await _visible_lightmap_budget()
	fixture.queue_free()
	await process_frame
	print("BAKED_DIRECT_SHADOW_TESTS checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)


func _spatial_filtering(texture: Texture2DArray, shadow_point: Vector3, clear_point: Vector3) -> void:
	lamp.call("set_baked_shadow_lightmap", owner_data, 1)
	var ambient := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	ambient.fill(Color(0.2, 0.2, 0.2, 1.0))
	var empty := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	empty.fill(Color(0, 0, 0, 0))
	var direct := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	var composed := ambient.duplicate()
	for y in 8:
		for x in 8:
			var value := Color(0.9, 0.1, 0.3, 0.95) if (x + y) % 2 == 0 else Color(0.1, 0.8, 0.6, 0.05)
			direct.set_pixel(x, y, value)
			composed.set_pixel(x, y, Color(0.2 + value.r * value.a, 0.2 + value.g * value.a, 0.2 + value.b * value.a, 1.0))
	for bicubic in [true, false]:
		RenderingServer.lightmaps_set_bicubic_filter(bicubic)
		texture.update_layer(ambient, 0)
		texture.update_layer(empty, 1)
		var reference := await _image()
		texture.update_layer(composed, 0)
		texture.update_layer(direct, 1)
		var shadowed := await _image()
		var mode := "bicubic" if bicubic else "linear"
		check(_difference(_sample(shadowed, clear_point), _sample(reference, clear_point)) > 0.05, "%s spatial fixture displays composed lamp RGB times visibility" % mode)
		var largest_error := 0.0
		for offset: Vector3 in [Vector3(-0.3, 0, -0.15), Vector3(-0.1, 0, 0.15), Vector3.ZERO, Vector3(0.1, 0, -0.15), Vector3(0.3, 0, 0.15)]:
			var point := shadow_point + offset
			largest_error = maxf(largest_error, _difference(_sample(shadowed, point), _sample(reference, point)))
		check(largest_error < 0.025, "%s filtering removes spatially varying RGB and visibility without residuals (error %.4f)" % [mode, largest_error])
	RenderingServer.lightmaps_set_bicubic_filter(true)
	lamp.call("set_baked_shadow_lightmap", null, -1)


func _native_bake_and_stationary_probes() -> void:
	var bake_root := Node3D.new()
	bake_root.name = "BakeFixture"
	bake_root.position.x = 100.0
	fixture.add_child(bake_root)
	var floor_mesh := MeshInstance3D.new()
	floor_mesh.name = "Floor"
	floor_mesh.mesh = _plane(Vector2(2, 2))
	floor_mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	bake_root.add_child(floor_mesh)
	floor_mesh.owner = bake_root
	var bake_lamp := OmniLight3D.new()
	bake_lamp.position.y = 3.0
	bake_lamp.omni_range = 6.0
	bake_lamp.light_bake_mode = Light3D.BAKE_STATIC
	bake_root.add_child(bake_lamp)
	bake_lamp.owner = bake_root
	var probe := LightmapProbe.new()
	probe.position.y = 2.0
	bake_root.add_child(probe)
	probe.owner = bake_root
	var gi := LightmapGI.new()
	gi.quality = LightmapGI.BAKE_QUALITY_LOW
	gi.bounces = 0
	gi.directional = false
	gi.use_denoiser = false
	gi.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_DISABLED
	gi.environment_mode = LightmapGI.ENVIRONMENT_MODE_DISABLED
	bake_root.add_child(gi)
	gi.owner = bake_root
	var folder := "user://baked_direct_fixture_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(folder)
	var output := folder.path_join("fixture.lmbake")
	var result: int = gi.call("bake_lightmaps", bake_root, output, true)
	check(result == LightmapGI.BAKE_ERROR_OK, "offline native bake succeeds without editor texture import")
	if result != LightmapGI.BAKE_ERROR_OK:
		return
	check(FileAccess.file_exists(output), "native bake saves its LightmapGIData")
	var data := load(output) as LightmapGIData
	check(data != null and not data.lightmap_textures.is_empty(), "native bake reloads with texture resources")
	if data == null:
		return
	check(data.lightmap_textures[0].resource_path.ends_with(".res"), "native atlas has an external resource path")
	check(data.lightmap_textures[0].get_layer_data(0).get_format() == Image.FORMAT_RGBH, "ordinary bake retains RGB atlas format")
	var blocker := MeshInstance3D.new()
	blocker.name = "StaticBlocker"
	var blocker_primitive := BoxMesh.new()
	blocker_primitive.size = Vector3(0.5, 0.5, 0.5)
	blocker_primitive.add_uv2 = true
	var blocker_mesh := ArrayMesh.new()
	blocker_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, blocker_primitive.get_mesh_arrays())
	blocker_mesh.lightmap_size_hint = Vector2i(16, 16)
	blocker.mesh = blocker_mesh
	blocker.position.y = 0.75
	blocker.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	bake_root.add_child(blocker)
	blocker.owner = bake_root
	result = gi.call("bake_lightmaps", bake_root, folder.path_join("visibility.lmbake"), true, true)
	check(result == LightmapGI.BAKE_ERROR_OK, "direct visibility bake succeeds")
	if result != LightmapGI.BAKE_ERROR_OK:
		return
	data = gi.light_data
	check(data.get_meta("direct_visibility", false), "direct visibility atlas declares its format")
	var users: Array = data.call("_get_user_data")
	var found_visibility := false
	var found_shadowed_irradiance := false
	var found_lit_irradiance := false
	for user in range(0, users.size(), 4):
		if gi.get_node(users[user]) != floor_mesh:
			continue
		var atlas := data.lightmap_textures[0].get_layer_data(users[user + 2])
		check(atlas.get_format() == Image.FORMAT_RGBAH, "direct visibility preserves RGBA16F")
		var uv: Rect2 = users[user + 1]
		var rect := Rect2i(uv.position * Vector2(atlas.get_size()), uv.size * Vector2(atlas.get_size())).grow(-2)
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var color := atlas.get_pixel(x, y)
				found_visibility = found_visibility or (color.a >= 0.0 and color.a <= 1.0)
				found_shadowed_irradiance = found_shadowed_irradiance or (color.a < 0.1 and _value(color) > 0.001)
				found_lit_irradiance = found_lit_irradiance or (color.a > 0.9 and _value(color) > 0.001)
	check(found_visibility and found_shadowed_irradiance and found_lit_irradiance, "visibility retains fully occluded irradiance and both shadowed and lit texels")
	blocker.queue_free()
	await process_frame
	gi.light_data = data
	var figure := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE
	figure.mesh = mesh
	figure.position.y = 0.5
	figure.gi_mode = GeometryInstance3D.GI_MODE_DYNAMIC
	bake_root.add_child(figure)
	bake_lamp.visible = false
	camera.global_position = Vector3(100, 10, 0)
	camera.look_at(Vector3(100, 0, 0), Vector3.BACK)
	var capture: Dictionary = data.call("_get_probe_data")
	var colors := PackedColorArray()
	colors.resize((capture.points as PackedVector3Array).size() * 9)
	for i in colors.size():
		colors[i] = Color(0.3, 0, 0, 1) if i % 9 == 0 else Color(0, 0, 0, 1)
	capture.sh = colors
	data.call("_set_probe_data", capture)
	await create_timer(1.0).timeout
	var red := _sample(await _image(), Vector3(100, 1, 0))
	for i in colors.size():
		colors[i] = Color(0, 0, 0.3, 1) if i % 9 == 0 else Color(0, 0, 0, 1)
	capture.sh = colors
	data.call("_set_probe_data", capture)
	await create_timer(1.0).timeout
	var blue := _sample(await _image(), Vector3(100, 1, 0))
	check(red.r > red.b + 0.1 and blue.b > blue.r + 0.1, "changed probe data relights a stationary dynamic object")


func _read_device_limits() -> void:
	var rd := RenderingServer.get_rendering_device()
	device_limits_read.emit.call_deferred(Vector2i(rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURES_PER_SHADER_STAGE), rd.limit_get(RenderingDevice.LIMIT_MAX_TEXTURES_PER_UNIFORM_SET)))


func _visible_lightmap_budget() -> void:
	RenderingServer.call_on_render_thread(_read_device_limits)
	var limits: Vector2i = await device_limits_read
	var count := 12 if limits.x >= 128 and limits.y >= 128 else 8
	var grid := Node3D.new()
	fixture.add_child(grid)
	var positions: Array[Vector3] = []
	var colors: Array[Color] = []
	var valid := true
	for i in count:
		var at := Vector3(200 + (i % 4 - 1.5) * 2.0, 0, (i / 4 - 1) * 2.0)
		var color := Color(0.15 + i * 0.017, 0.35 - i * 0.009, 0.18 + i * 0.01)
		positions.append(at)
		colors.append(color)
		var visual := MeshInstance3D.new()
		visual.mesh = _plane(Vector2.ONE)
		visual.position = at
		visual.gi_mode = GeometryInstance3D.GI_MODE_STATIC
		grid.add_child(visual)
		var gi := LightmapGI.new()
		gi.position = at - Vector3.ONE * 0.5
		grid.add_child(gi)
		var image := Image.create(8, 8, false, Image.FORMAT_RGBAH)
		image.fill(color)
		var texture := Texture2DArray.new()
		valid = texture.create_from_images([image]) == OK and valid
		var data := LightmapGIData.new()
		data.lightmap_textures = [texture]
		data.add_user(gi.get_path_to(visual), Rect2(0, 0, 1, 1), 0, -1)
		gi.light_data = data
	camera.global_position = Vector3(200, 10, 0)
	camera.look_at(Vector3(200, 0, 0), Vector3.BACK)
	var image := await _image()
	var matching := 0
	for i in count:
		if _difference(_sample(image, positions[i]), colors[i]) < 0.025:
			matching += 1
	check(valid and matching == count, "%d independent visible lightmaps retain their own colors (%d matched, device limits %s)" % [count, matching, limits])
	grid.queue_free()
	await process_frame

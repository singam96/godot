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
	camera.far = 30.0
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
	await _sun_shadow_layers(shadow_point, clear_point)
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


func _sun_shadow_layers(shadow_point: Vector3, clear_point: Vector3) -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -90, 0)
	sun.light_energy = 0.4
	sun.light_bake_mode = Light3D.BAKE_STATIC
	sun.shadow_enabled = true
	sun.shadow_normal_bias = 0.01
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 20.0
	fixture.add_child(sun)
	var moving_shadows := DirectionalLight3D.new()
	moving_shadows.rotation_degrees = sun.rotation_degrees
	moving_shadows.light_energy = 0.0
	moving_shadows.light_bake_mode = Light3D.BAKE_DYNAMIC
	moving_shadows.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	moving_shadows.shadow_enabled = true
	moving_shadows.shadow_caster_mask = 2
	moving_shadows.shadow_normal_bias = 0.01
	moving_shadows.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	moving_shadows.directional_shadow_max_distance = 20.0
	fixture.add_child(moving_shadows)
	var static_blocker := MeshInstance3D.new()
	var blocker_mesh := BoxMesh.new()
	blocker_mesh.size = Vector3(0.5, 1.0, 0.5)
	static_blocker.mesh = blocker_mesh
	static_blocker.position = Vector3(0.7, 0.5, -2)
	fixture.add_child(static_blocker)
	var a := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	a.fill(Color(0.3, 0.05, 0.1, 0.8))
	var b := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	b.fill(Color(0.05, 0.1, 0.3, 0.4))
	var base := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	base.fill(Color(0.46, 0.28, 0.4, 1))
	var texture := Texture2DArray.new()
	texture.create_from_images([base, a, b])
	owner_data.set_lightmap_textures([texture])
	actor.visible = true
	var standard := await _image()
	sun.visible = false
	var reference := await _image()
	var actor_unlit := _sample(reference, Vector3(0, 2, 0))
	owner_data.call("set_baked_sun_shadow_layers", moving_shadows, 1, 2)
	sun.visible = true
	actor.visible = false
	var unshadowed := await _image()
	check(_difference(_sample(unshadowed, clear_point), _sample(reference, clear_point)) < 0.03, "sampled sun does not add live direct light twice on its owner")
	actor.visible = true
	var shadowed := await _image()
	check(_difference(_sample(shadowed, shadow_point), Color(0.2, 0.2, 0.2)) < 0.03, "moving actor shadows both weighted sun samples while preserving ambient (observed %s)" % _sample(shadowed, shadow_point))
	check(_value(_sample(shadowed, Vector3(0, 2, 0))) > _value(actor_unlit) + 0.04, "sampled sun retains live direct illumination on dynamic actors")
	var static_shadow_point := Vector3(1.7, 0, -2)
	check(_difference(_sample(shadowed, static_shadow_point), _sample(reference, static_shadow_point)) < 0.03, "zero-energy moving-shadow sun excludes current-direction static shadows from interpolated lightmaps")
	var actor_blocker := MeshInstance3D.new()
	var actor_blocker_mesh := BoxMesh.new()
	actor_blocker_mesh.size = Vector3(0.8, 2, 0.8)
	actor_blocker.mesh = actor_blocker_mesh
	actor_blocker.position = Vector3(-1.3, 3.3, 0)
	fixture.add_child(actor_blocker)
	var statically_shadowed_actor := await _image()
	check(_value(_sample(statically_shadowed_actor, Vector3(0, 2, 0))) < _value(_sample(shadowed, Vector3(0, 2, 0))) - 0.04, "main sun retains static-caster shadows on dynamic actors")
	actor_blocker.queue_free()
	await process_frame
	await _zero_energy_sun_lighting(sun, moving_shadows, shadow_point)
	owner_data.call("set_baked_sun_shadow_layers", null, -1, -1)
	other_data.call("set_baked_sun_shadow_layers", moving_shadows, 1, 2)
	var isolated := await _image()
	check(_difference(_sample(isolated, shadow_point), _sample(standard, shadow_point)) < 0.03, "moving sun layer associations remain isolated to their owner and disabling restores the baked base")
	other_data.call("set_baked_sun_shadow_layers", null, -1, -1)
	sun.queue_free()
	moving_shadows.queue_free()
	static_blocker.queue_free()
	await process_frame


func _zero_energy_sun_lighting(sun: DirectionalLight3D, moving_shadows: DirectionalLight3D, shadow_point: Vector3) -> void:
	var panel := MeshInstance3D.new()
	panel.mesh = _plane(Vector2.ONE)
	panel.position = Vector3(-3, 0.02, 2)
	panel.layers = 4
	panel.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	panel.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var material := ShaderMaterial.new()
	material.shader = Shader.new()
	material.shader.code = "shader_type spatial; render_mode ambient_light_disabled, specular_disabled; void fragment() { ALBEDO = vec3(1.0); } void light() { DIFFUSE_LIGHT += vec3(0.125, 0.25, 0.5); }"
	panel.material_override = material
	var sun_mask := sun.light_cull_mask
	var lamp_mask := lamp.light_cull_mask
	sun.light_cull_mask &= ~4
	lamp.light_cull_mask &= ~4
	fixture.add_child(panel)
	moving_shadows.visible = false
	var hidden := await _image()
	var baseline := _sample(hidden, panel.position)
	check(_value(baseline) < 0.005, "unmapped custom-light fixture is dark without the shadow-only sun")
	moving_shadows.visible = true
	var zero := await _image()
	check(_difference(_sample(zero, panel.position), baseline) < 0.015, "zero-energy shadow-only sun does not invoke regular custom lighting on unmapped geometry")
	moving_shadows.light_energy = 1.0
	var positive := await _image()
	check(_value(_sample(positive, panel.position)) > _value(baseline) + 0.04, "positive-energy directional light still invokes custom lighting")
	moving_shadows.light_energy = 0.00000001
	var faint := await _image()
	check(_value(_sample(faint, panel.position)) > _value(baseline) + 0.04, "tiny positive directional energy is not suppressed by an epsilon guard")
	moving_shadows.light_energy = 1.0
	moving_shadows.light_negative = true
	var negative := await _image()
	check(_value(_sample(negative, panel.position)) > _value(baseline) + 0.04, "negative directional energy still invokes custom lighting")
	moving_shadows.light_negative = false
	moving_shadows.light_energy = 0.0
	var restored := await _image()
	check(_difference(_sample(restored, shadow_point), Color(0.2, 0.2, 0.2)) < 0.03, "zero-energy helper retains mapped moving-shadow subtraction after regular-light controls")
	sun.light_cull_mask = sun_mask
	lamp.light_cull_mask = lamp_mask
	panel.queue_free()
	await process_frame


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
	# Newly created materials need their render-thread uniform resources ready
	# before the synchronous UV2 draw; no editor frame runs inside the bake.
	await process_frame
	await RenderingServer.frame_post_draw
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
	var lamp_users: Array = data.call("_get_user_data")
	bake_lamp.light_bake_mode = Light3D.BAKE_DISABLED
	var bake_sun := DirectionalLight3D.new()
	bake_sun.rotation_degrees = Vector3(-45, -90, 0)
	bake_sun.light_bake_mode = Light3D.BAKE_STATIC
	bake_root.add_child(bake_sun)
	bake_sun.owner = bake_root
	result = gi.call("bake_lightmaps", bake_root, folder.path_join("sun_visibility.lmbake"), true, true)
	check(result == LightmapGI.BAKE_ERROR_OK, "directional sun direct visibility bake succeeds")
	if result != LightmapGI.BAKE_ERROR_OK:
		return
	data = gi.light_data
	check(data.call("_get_user_data") == lamp_users and data.get_meta("direct_visibility", false) and data.lightmap_textures[0].get_format() == Image.FORMAT_RGBAH, "sun direct bake preserves the atlas and RGBA visibility format")
	gi.light_data = null
	var remaining_users: Array = []
	for user in range(0, lamp_users.size(), 4):
		if gi.get_node(lamp_users[user]) == floor_mesh:
			remaining_users.append_array(lamp_users.slice(user, user + 4))
	data.call("_set_user_data", remaining_users)
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
	bake_sun.visible = false
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

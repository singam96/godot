extends SceneTree
## Procedural Forward+ acceptance. No game content or saves are used.

const API := "environment_set_baked_outdoor_lighting"
var checks := 0
var failures := 0
var camera: Camera3D
var environment: Environment
var sun: DirectionalLight3D
var parameters := PackedFloat32Array()
var textures: Array[RID] = []
var resources: Array[Resource] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", message)


func _depth(value: float) -> Image:
	var image := Image.create(8, 8, false, Image.FORMAT_RF)
	image.fill(Color(value, 0, 0))
	return image


func _array(images: Array[Image]) -> Texture2DArray:
	var texture := Texture2DArray.new()
	_check(texture.create_from_images(images) == OK, "create immutable test array")
	resources.append(texture)
	return texture


func _bind_cache_pages(pages: PackedInt32Array) -> void:
	RenderingServer.call(API, environment.get_rid(), sun.call("get_light_rid"), textures, parameters, pages, 16, 8)


func _image() -> Image:
	for frame in 6: await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


func _value(image: Image, point: Vector3) -> float:
	var at := Vector2i(camera.unproject_position(point))
	var color := image.get_pixelv(at).srgb_to_linear()
	return (color.r + color.g + color.b) / 3.0


func _plane(parent: Node, at: Vector3, layers: int) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(2, 2)
	instance.mesh = mesh
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	instance.material_override = material
	instance.position = at
	instance.layers = layers
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(instance)
	return instance


func _run() -> void:
	if OS.get_cmdline_user_args().has("--expect-unsupported"):
		_check(not RenderingServer.has_method(API), "comparison engine lacks the opt-in API")
		print("OUTDOOR_BAKED_NEGATIVE_CONTROL_OK" if failures == 0 else "OUTDOOR_BAKED_NEGATIVE_CONTROL_FAILED")
		quit(0 if failures == 0 else 1)
		return
	if not RenderingServer.has_method(API) or DisplayServer.get_name() == "headless":
		printerr("OUTDOOR_BAKED_REQUIRES_NATIVE_FORWARD_PLUS")
		quit(2)
		return
	root.size = Vector2i(640, 640)
	var fixture := Node3D.new()
	root.add_child(fixture)
	var world := WorldEnvironment.new()
	environment = Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color.BLACK
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.1
	world.environment = environment
	fixture.add_child(world)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 8
	fixture.add_child(camera)
	camera.position = Vector3(0, 7, 7)
	camera.look_at(Vector3.ZERO)
	camera.make_current()
	sun = DirectionalLight3D.new()
	sun.rotation_degrees.x = -90
	sun.light_energy = 0.4
	sun.shadow_enabled = true
	sun.shadow_caster_mask = 8
	sun.directional_shadow_max_distance = 30
	fixture.add_child(sun)
	_check((sun.call("get_light_rid") as RID).is_valid(), "native sun RID is exposed independently of VisualInstance base")
	var floor_mesh := _plane(fixture, Vector3.ZERO, 16)
	var actor := _plane(fixture, Vector3(2.2, 0, 0), 1 | 8)
	var maps := _array([_depth(0.0), _depth(0.8)])
	var fine := _array([_depth(0.8)])
	textures = [maps.get_rid(), fine.get_rid()]
	parameters.resize(80)
	var projection := Projection(Vector4(0.125, 0, 0, 0), Vector4(0, 0, 0.1, 0), Vector4(0, 0.125, 0, 0), Vector4(0.5, 0.5, 0.3, 1))
	for sample_index in 2:
		var columns := [projection.x, projection.y, projection.z, projection.w]
		for column in 4:
			for component in 4: parameters[sample_index * 16 + column * 4 + component] = columns[column][component]
		for component in 3:
			parameters[32 + sample_index * 4 + component] = 0.1
			parameters[40 + sample_index * 4 + component] = 0.4
		parameters[43 + sample_index * 4] = sample_index
		parameters[49 + sample_index * 4] = 1.0
	for index in range(60, 67): parameters[index] = 1.0
	for index in range(68, 72): parameters[index] = 1.0
	var initial_parameters := parameters.duplicate()
	var reference := await _image()
	var original := _value(reference, Vector3.ZERO)
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var open := await _image()
	_check(absf(_value(open, Vector3.ZERO) - original) < 0.025, "cached radiance replaces ordinary sun once")
	_check(absf(_value(open, actor.position) - _value(reference, actor.position)) < 0.025, "unmapped actor retains ordinary lighting")
	parameters[56] = 1.0
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var blocked := await _image()
	_check(_value(blocked, Vector3.ZERO) < original * 0.4, "static world shadow uses second baked sample")
	_check(_value(blocked, actor.position) < original * 0.4, "cached world occlusion reaches moving actors")
	parameters[56] = 0.5
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var half := await _image()
	var expected := (_value(open, Vector3.ZERO) + _value(blocked, Vector3.ZERO)) * 0.5
	_check(absf(_value(half, Vector3.ZERO) - expected) < 0.025, "visibility contributions crossfade after comparison")
	parameters[47] = 0
	parameters[52] = 1
	parameters[53] = 0
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var side_sun := await _image()
	_check(absf(_value(side_sun, Vector3.ZERO) - expected) < 0.025, "each sample applies its own cosine before interpolation")
	parameters[47] = 1
	parameters[52] = 0
	parameters[53] = 1
	parameters[56] = 0.0
	_bind_cache_pages(PackedInt32Array([0, -1]))
	var fine_blocked := await _image()
	_check(_value(fine_blocked, Vector3.ZERO) < original * 0.4, "resident fine depth overrides coarse")
	parameters[43] = 1
	_bind_cache_pages(PackedInt32Array([100, -1]))
	var fallback := await _image()
	_check(_value(fallback, Vector3.ZERO) < original * 0.4, "invalid fine page uses coarse rather than becoming lit")
	parameters[43] = 0
	parameters[56] = 0.5
	for component in 3: parameters[40 + component] = 0
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var sunrise := await _image()
	_check(_value(sunrise, actor.position) < original * 0.4, "zero-radiance night sample does not dilute actor shadows")
	for component in 3: parameters[40 + component] = 0.4
	parameters[56] = 0
	parameters[43] = 1
	sun.shadow_enabled = false
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var no_live := await _image()
	_check(_value(no_live, Vector3.ZERO) < original * 0.4, "static shadows survive disabling live shadow rendering")
	_check(_value(no_live, actor.position) < original * 0.4, "actor static occlusion survives disabled live shadows")
	var other_environment := environment.duplicate() as Environment
	camera.environment = other_environment
	var independent := await _image()
	_check(absf(_value(independent, Vector3.ZERO) - original) < 0.025, "another environment does not inherit cache state")
	camera.environment = null
	var owned := await _image()
	_check(_value(owned, Vector3.ZERO) < original * 0.4, "original environment retains its own cache")
	sun.shadow_enabled = true
	parameters[43] = 0
	var wrong_type := ImageTexture.create_from_image(_depth(0.8))
	resources.append(wrong_type)
	textures[1] = wrong_type.get_rid()
	_bind_cache_pages(PackedInt32Array([0, -1]))
	var unavailable_fine := await _image()
	_check(absf(_value(unavailable_fine, Vector3.ZERO) - original) < 0.025, "unready/wrong-dimension fine storage uses valid coarse depth")
	textures[0] = wrong_type.get_rid()
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var unavailable_coarse := await _image()
	_check(absf(_value(unavailable_coarse, Vector3.ZERO) - original) < 0.025, "wrong-dimension coarse storage cannot activate array descriptors")
	textures[0] = maps.get_rid()
	textures[1] = fine.get_rid()
	var ambient_image := Image.create(8, 8, false, Image.FORMAT_RGBAH)
	ambient_image.fill(Color(0, 0.25, 0.5, 1))
	var coarse_ambient := ImageTexture.create_from_image(ambient_image)
	resources.append(coarse_ambient)
	ambient_image = ambient_image.duplicate()
	ambient_image.fill(Color(0, 0.75, 0.75, 1))
	var fine_ambient := _array([ambient_image])
	textures.append(coarse_ambient.get_rid())
	textures.append(fine_ambient.get_rid())
	parameters[72] = -4
	parameters[73] = -4
	parameters[74] = 8
	parameters[75] = 8
	parameters[76] = 1
	parameters[77] = 1
	parameters[78] = 1
	for component in 3:
		parameters[40 + component] = 0
		parameters[44 + component] = 0
	sun.light_energy = 0
	_bind_cache_pages(PackedInt32Array([-1, -1, -1]))
	var sky_coarse := await _image()
	_check(absf(_value(sky_coarse, Vector3.ZERO) - 0.025) < 0.015, "static ambient uses baked spatial sky visibility")
	_check(absf(_value(sky_coarse, actor.position) - 0.025) < 0.015, "outdoor actor ambient uses sky field")
	_bind_cache_pages(PackedInt32Array([-1, -1, 0]))
	var sky_fine := await _image()
	_check(absf(_value(sky_fine, Vector3.ZERO) - 0.075) < 0.015, "resident fine sky field replaces coarse")
	textures[3] = coarse_ambient.get_rid()
	_bind_cache_pages(PackedInt32Array([-1, -1, 0]))
	var sky_fallback := await _image()
	_check(absf(_value(sky_fallback, Vector3.ZERO) - 0.025) < 0.015, "unready fine sky storage preserves valid coarse visibility")
	parameters = initial_parameters.duplicate()
	var slope_projection := Projection(Vector4(0.125, 0, 0, 0), Vector4(0, 0, 0.1, 0), Vector4(0, 0.125, 0.05, 0), Vector4(0.5, 0.5, 0.3, 1))
	for sample_index in 2:
		var columns := [slope_projection.x, slope_projection.y, slope_projection.z, slope_projection.w]
		for column in 4:
			for component in 4: parameters[sample_index * 16 + column * 4 + component] = columns[column][component]
	parameters[57] = 0.00001
	parameters[58] = 0.00001
	var slope_image := Image.create(32, 32, false, Image.FORMAT_RF)
	for row in 32:
		for column in 32: slope_image.set_pixel(column, row, Color(0.1 + 0.4 * (row + 0.5) / 32.0, 0, 0))
	var slope_maps := _array([slope_image])
	textures = [slope_maps.get_rid(), fine.get_rid()]
	sun.light_energy = 0.4
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var slope_receiver := await _image()
	_check(absf(_value(slope_receiver, Vector3.ZERO) - original) < 0.025, "receiver-plane filtering does not self-shadow an open sloped depth field")
	for row in 32:
		for column in 32: slope_image.set_pixel(column, row, Color(0.1 + 0.4 * ((row + 0.5) / 32.0 - 0.125) / 0.75, 0, 0))
	var fine_slope := _array([slope_image])
	textures[1] = fine_slope.get_rid()
	parameters[59] = 0.125
	_bind_cache_pages(PackedInt32Array([0, -1]))
	var fine_slope_receiver := await _image()
	_check(absf(_value(fine_slope_receiver, Vector3.ZERO) - original) < 0.025, "fine receiver-plane correction includes page gutters and coordinate scale")
	parameters = initial_parameters.duplicate()
	textures = [maps.get_rid(), fine.get_rid()]
	sun.light_energy = 0.4
	sun.shadow_enabled = true
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var moving := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.8, 1.0, 0.8)
	moving.mesh = box
	moving.position = Vector3(0, 2, 0)
	moving.layers = 8
	fixture.add_child(moving)
	var moving_shadow := await _image()
	_check(_value(moving_shadow, Vector3.ZERO) < original * 0.4, "moving-only live sun shadows cached static receivers")
	moving.position.x = 3.5
	var moved_away := await _image()
	_check(absf(_value(moved_away, Vector3.ZERO) - original) < 0.025, "moving shadow updates without rebaking the cache")
	moving.position.x = 0
	moving.layers = 16
	var fixed_mask := await _image()
	_check(absf(_value(fixed_mask, Vector3.ZERO) - original) < 0.025, "fixed receiver layer cannot enter moving-only sun passes")
	moving.queue_free()
	var surface := floor_mesh.material_override as StandardMaterial3D
	surface.emission_enabled = true
	surface.emission = Color(0.4, 0.3, 0.2)
	surface.emission_energy_multiplier = 0.1
	parameters[43] = 1
	_bind_cache_pages(PackedInt32Array([-1, -1]))
	var emitted_shadow := await _image()
	_check(_value(emitted_shadow, Vector3.ZERO) > _value(blocked, Vector3.ZERO) + 0.003 && _value(emitted_shadow, Vector3.ZERO) < original * 0.5, "cached diffuse shadows preserve authored material emission")
	surface.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS
	surface.albedo_color = Color(1, 1, 1, 0.8)
	var alpha_shadow := await _image()
	RenderingServer.call(API, environment.get_rid(), RID(), [], PackedFloat32Array(), PackedInt32Array(), 0, 0)
	var alpha_open := await _image()
	_check(_value(alpha_shadow, Vector3.ZERO) < _value(alpha_open, Vector3.ZERO) * 0.5, "alpha depth-prepass receivers use the environment cache in the transparent pass")
	surface.emission_enabled = false
	surface.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	surface.albedo_color = Color.WHITE
	RenderingServer.call(API, environment.get_rid(), RID(), [], PackedFloat32Array(), PackedInt32Array(), 0, 0)
	var restored := await _image()
	_check(absf(_value(restored, Vector3.ZERO) - original) < 0.025, "disabling restores the original path")
	floor_mesh.queue_free()
	fixture.queue_free()
	await process_frame
	resources.clear()
	print("OUTDOOR_BAKED_TESTS checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

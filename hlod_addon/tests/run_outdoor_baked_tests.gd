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
	RenderingServer.call(API, environment.get_rid(), sun.get_base(), textures, parameters, pages, 16, 8)


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
	RenderingServer.call(API, environment.get_rid(), RID(), [], PackedFloat32Array(), PackedInt32Array(), 0, 0)
	var restored := await _image()
	_check(absf(_value(restored, Vector3.ZERO) - original) < 0.025, "disabling restores the original path")
	floor_mesh.queue_free()
	fixture.queue_free()
	await process_frame
	resources.clear()
	print("OUTDOOR_BAKED_TESTS checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

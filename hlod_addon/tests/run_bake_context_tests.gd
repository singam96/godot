extends SceneTree
## Real native bake: context cutout holes, MultiMesh transforms, atlas/probe isolation.

var checks := 0
var failures := 0
var gi: LightmapGI
var floor_mesh: MeshInstance3D


func _initialize() -> void:
	_run.call_deferred()


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FAIL: ", message)


func _material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color.WHITE
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


func _receiver(size: Vector2, hint: Vector2i) -> ArrayMesh:
	var primitive := PlaneMesh.new()
	primitive.size = size
	var arrays := primitive.get_mesh_arrays()
	arrays[Mesh.ARRAY_TEX_UV2] = arrays[Mesh.ARRAY_TEX_UV]
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.lightmap_size_hint = hint
	mesh.surface_set_material(0, _material())
	return mesh


func _layout(data: LightmapGIData) -> Dictionary:
	var probes: Dictionary = data.call("_get_probe_data").duplicate(true)
	probes.erase("sh") # Irradiance must change when the context blocks a probe ray.
	var textures: Array = []
	for texture: TextureLayered in data.lightmap_textures:
		textures.append([texture.get_width(), texture.get_height(), texture.get_layers()])
	return {"users": data.call("_get_user_data").duplicate(true), "probes": probes, "textures": textures}


func _sample(data: LightmapGIData, at: Vector2) -> Color:
	var users: Array = data.call("_get_user_data")
	for i in range(0, users.size(), 4):
		if gi.get_node(users[i]) == floor_mesh:
			var image := data.lightmap_textures[0].get_layer_data(users[i + 2])
			var rect: Rect2 = users[i + 1]
			var uv := rect.position + (at / Vector2(12, 8) + Vector2(0.5, 0.5)) * rect.size
			var pixel := Vector2i(uv * Vector2(image.get_size()))
			return image.get_pixel(pixel.x, pixel.y)
	return Color(-1, -1, -1, -1)


func _run() -> void:
	var found_api := false
	for method: Dictionary in ClassDB.class_get_method_list("LightmapGI"):
		if method.name == "bake_lightmaps" and method.args.size() == 5:
			found_api = true
	if not found_api:
		printerr("BAKE_CONTEXT_REQUIRES_CUSTOM_EDITOR")
		quit(2)
		return
	if DisplayServer.get_name() == "headless":
		printerr("BAKE_CONTEXT_REQUIRES_REAL_RENDERER")
		quit(2)
		return
	var receivers := Node3D.new()
	receivers.name = "Receivers"
	receivers.position = Vector3(100, 2, 50)
	receivers.rotation.y = 0.4
	root.add_child(receivers)
	floor_mesh = MeshInstance3D.new()
	floor_mesh.name = "Floor"
	floor_mesh.mesh = _receiver(Vector2(12, 8), Vector2i(128, 96))
	floor_mesh.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	receivers.add_child(floor_mesh)
	floor_mesh.owner = receivers
	var second := MeshInstance3D.new()
	second.name = "SecondReceiver"
	second.mesh = _receiver(Vector2(1, 1), Vector2i(16, 16))
	second.position = Vector3(0, 0.1, 3)
	second.gi_mode = GeometryInstance3D.GI_MODE_STATIC
	receivers.add_child(second)
	second.owner = receivers
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees.x = -90
	sun.light_bake_mode = Light3D.BAKE_STATIC
	receivers.add_child(sun)
	sun.owner = receivers
	for at: Vector3 in [Vector3(-3, 1, -2), Vector3(3, 1, -2), Vector3(0, 2, 2)]:
		var probe := LightmapProbe.new()
		probe.position = at
		receivers.add_child(probe)
		probe.owner = receivers
	gi = LightmapGI.new()
	gi.quality = LightmapGI.BAKE_QUALITY_LOW
	gi.directional = false
	gi.bounces = 0
	gi.use_denoiser = false
	gi.denoiser_range = 2
	gi.environment_mode = LightmapGI.ENVIRONMENT_MODE_DISABLED
	gi.generate_probes_subdiv = LightmapGI.GENERATE_PROBES_DISABLED
	receivers.add_child(gi)
	gi.owner = receivers
	var context := Node3D.new()
	context.name = "Context"
	root.add_child(context)
	context.transform = receivers.transform
	# Ownerless, UV1-only foliage card. The 1 m central hole must transmit sun.
	var mask := Image.create(128, 128, false, Image.FORMAT_RGBA8)
	mask.fill(Color.WHITE)
	mask.fill_rect(Rect2i(48, 48, 32, 32), Color(1, 1, 1, 0))
	var cutout := _material()
	cutout.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	cutout.alpha_scissor_threshold = 0.4
	cutout.albedo_texture = ImageTexture.create_from_image(mask)
	var card := MeshInstance3D.new()
	var card_mesh := PlaneMesh.new()
	card_mesh.size = Vector2(4, 4)
	card.mesh = card_mesh
	card.material_override = cutout
	card.position = Vector3(-3, 3, 0)
	context.add_child(card)
	# An ownerless opaque mesh and a far-away, runtime-hidden MultiMesh both cast.
	var blocker := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1, 0.5, 1)
	blocker.mesh = box
	blocker.material_override = _material()
	blocker.position = Vector3(0, 2, 2)
	context.add_child(blocker)
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = box
	multi.instance_count = 1
	multi.set_instance_transform(0, Transform3D(Basis.from_scale(Vector3(2, 1, 2)), Vector3(3, 20, 0)))
	multi.visible_instance_count = 0
	var forest := MultiMeshInstance3D.new()
	forest.multimesh = multi
	forest.material_override = _material()
	context.add_child(forest)
	var folder := "user://bake_context_fixture_%d" % Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute(folder)
	await process_frame
	await RenderingServer.frame_post_draw
	var result: int = gi.call("bake_lightmaps", receivers, folder.path_join("baseline.lmbake"), true, true)
	check(result == LightmapGI.BAKE_ERROR_OK, "default direct bake succeeds")
	if result != LightmapGI.BAKE_ERROR_OK:
		_finish()
		return
	var baseline := _layout(gi.light_data)
	check((baseline.users as Array).size() == 8, "only two receiver meshes have atlas users")
	var lit := _sample(gi.light_data, Vector2(-4.3, 0))
	check(lit.a > 0.95 and lit.r > 0.01, "separate context is ignored by the default bake")
	result = gi.call("bake_lightmaps", receivers, folder.path_join("context.lmbake"), true, true, context)
	check(result == LightmapGI.BAKE_ERROR_OK, "context direct bake succeeds")
	if result != LightmapGI.BAKE_ERROR_OK:
		_finish()
		return
	check(_layout(gi.light_data) == baseline, "context leaves atlas users, rectangles, slices, dimensions and complete probe layout unchanged")
	var hole := _sample(gi.light_data, Vector2(-3, 0))
	var leaf := _sample(gi.light_data, Vector2(-4.3, 0))
	var far_tree := _sample(gi.light_data, Vector2(3, 0))
	var opaque := _sample(gi.light_data, Vector2(0, 2))
	print("BAKE_CONTEXT_SAMPLES hole=", hole, " leaf=", leaf, " far=", far_tree, " opaque=", opaque)
	check(hole.a > 0.95, "UV1 alpha-scissor hole transmits sunlight")
	check(leaf.a < 0.05 and leaf.r > 0.01, "opaque leaf texels retain unoccluded RGB with zero visibility")
	check(far_tree.a < 0.05, "MultiMesh instance beyond receiver/probe bounds casts despite runtime instance visibility")
	check(opaque.a < 0.05, "ownerless ordinary context mesh casts")
	check(absf(hole.r - hole.g) < 0.002 and absf(hole.g - hole.b) < 0.002, "white sun bake preserves neutral irradiance")
	# Match a real daylight pass (one bounce and denoising) against direct RGBA.
	gi.bounces = 1
	gi.use_denoiser = true
	ProjectSettings.set_setting("rendering/lightmapping/denoising/denoiser", 0)
	result = gi.call("bake_lightmaps", receivers, folder.path_join("daylight.lmbake"), true, false, context)
	check(result == LightmapGI.BAKE_ERROR_OK, "denoised one-bounce daylight accepts the same context")
	if result == LightmapGI.BAKE_ERROR_OK:
		check(_layout(gi.light_data) == baseline, "daylight denoising and direct visibility share receiver atlas and probe layout")
		var day_hole := _sample(gi.light_data, Vector2(-3, 0))
		var day_leaf := _sample(gi.light_data, Vector2(-4.3, 0))
		check(day_hole.r > day_leaf.r + 0.05, "ordinary daylight also traces the cutout rather than the full leaf rectangle")
	gi.light_data = null
	receivers.queue_free()
	context.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("BAKE_CONTEXT_TESTS checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

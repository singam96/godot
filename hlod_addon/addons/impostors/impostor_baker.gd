@tool
extends RefCounted
## Renders an object from several sides into an [ImpostorData]. This needs a running renderer, so it can't be used
## with --headless, and it is a coroutine: [code]var data = await Baker.bake(host, node, settings)[/code].

const NORMAL_SHADER := preload("normal_pass.gdshader")
const PADDING := 4  ## Transparent pixels around the object in every view, so mipmaps don't mix views.

class Settings:
	var views := 12
	var rows := 2
	var cell_size := 256
	var min_elevation := 10.0
	var max_elevation := 55.0
	## Strength of the ambient light the views are lit with; 1.0 shows the albedo as it is.
	var brightness := 1.0
	## Also bake normals, so the impostor can react to the scene's lights. Doubles the bake time and the size.
	var bake_normals := true
	## Called with a value from 0 to 1 and a text, after each view.
	var progress := Callable()


## [param host] must be inside the scene tree. [param source] is copied; it can be in the tree or not.
## Returns null if there is nothing to draw.
static func bake(host: Node, source: Node3D, settings: Settings) -> ImpostorData:
	var views := clampi(settings.views, 1, 64)
	var rows := clampi(settings.rows, 1, 8)
	var cell := clampi(settings.cell_size, 32, 1024)

	var viewport := SubViewport.new()
	viewport.size = Vector2i(cell, cell)
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	host.add_child(viewport)

	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color.WHITE
	env.ambient_light_energy = settings.brightness
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	viewport.add_child(world_env)

	var copy := source.duplicate() as Node3D
	copy.transform = Transform3D.IDENTITY
	viewport.add_child(copy)
	# The object may already be set up to hide itself in the distance (see Impostor3D); the bake must see it.
	_clear_end_ranges(copy)

	var aabb := _combined_aabb(copy)
	if aabb.size == Vector3.ZERO:
		viewport.queue_free()
		return null
	var center := aabb.get_center()
	var radius := aabb.size.length() * 0.5
	var quad_size := 2.0 * radius * float(cell) / float(cell - 2 * PADDING)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = quad_size
	camera.near = 0.05
	camera.far = radius * 4.0 + 2.0
	viewport.add_child(camera)
	camera.make_current()

	var passes := 2 if settings.bake_normals else 1
	var atlas := await _render_pass(viewport, camera, center, radius, views, rows, cell, settings, 0, passes)
	var normal_atlas: Image = null
	if settings.bake_normals:
		_use_normal_materials(copy)
		normal_atlas = await _render_pass(viewport, camera, center, radius, views, rows, cell, settings, 1, passes)
		# The image comes out sRGB-encoded; the values are data, not colors.
		normal_atlas.srgb_to_linear()
	viewport.queue_free()

	atlas.fix_alpha_edges()
	atlas.generate_mipmaps()
	if normal_atlas != null:
		normal_atlas.fix_alpha_edges()
		normal_atlas.generate_mipmaps()

	var data := ImpostorData.new()
	data.atlas = ImageTexture.create_from_image(atlas)
	if normal_atlas != null:
		data.normal_atlas = ImageTexture.create_from_image(normal_atlas)
	data.views = views
	data.rows = rows
	data.min_elevation = settings.min_elevation
	data.max_elevation = settings.max_elevation
	data.quad_size = quad_size
	data.center = center
	return data


static func _render_pass(viewport: SubViewport, camera: Camera3D, center: Vector3, radius: float, views: int, rows: int,
		cell: int, settings: Settings, pass_index: int, passes: int) -> Image:
	var atlas := Image.create(views * cell, rows * cell, false, Image.FORMAT_RGBA8)
	var total := views * rows * passes
	for j in rows:
		var elevation := deg_to_rad(settings.min_elevation)
		if rows > 1:
			elevation = deg_to_rad(lerpf(settings.min_elevation, settings.max_elevation, float(j) / float(rows - 1)))
		for i in views:
			var azimuth := TAU * float(i) / float(views)
			var dir := Vector3(sin(azimuth) * cos(elevation), sin(elevation), cos(azimuth) * cos(elevation))
			camera.position = center + dir * radius * 2.0
			camera.look_at(center, Vector3.UP)
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			await RenderingServer.frame_post_draw
			var image := viewport.get_texture().get_image()
			image.convert(Image.FORMAT_RGBA8)
			atlas.blit_rect(image, Rect2i(0, 0, cell, cell), Vector2i(i * cell, j * cell))
			if settings.progress.is_valid():
				var done := pass_index * views * rows + j * views + i + 1
				settings.progress.call(float(done) / float(total),
						"Rendering %s view %d of %d..." % ["normal" if pass_index == 1 else "color", done - pass_index * views * rows, views * rows])
	return atlas


## Swaps every material below [param root] for one that draws normals, keeping alpha cut-outs, textures and culling.
static func _use_normal_materials(root: Node) -> void:
	var shaders := {}
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back()
		var mi := node as MeshInstance3D
		var mmi := node as MultiMeshInstance3D
		if mi != null and mi.mesh != null:
			if mi.material_override != null:
				mi.material_override = _normal_material(mi.material_override, shaders)
			else:
				for s in mi.mesh.get_surface_count():
					mi.set_surface_override_material(s, _normal_material(mi.get_active_material(s), shaders))
		elif mmi != null and mmi.multimesh != null and mmi.multimesh.mesh != null:
			var source: Material = mmi.material_override
			if source == null and mmi.multimesh.mesh.get_surface_count() > 0:
				source = mmi.multimesh.mesh.surface_get_material(0)
			mmi.material_override = _normal_material(source, shaders)
		stack.append_array(node.get_children(true))


static func _normal_material(source: Material, shaders: Dictionary) -> ShaderMaterial:
	var base := source as BaseMaterial3D
	var cull := "cull_back"
	if base != null:
		match base.cull_mode:
			BaseMaterial3D.CULL_DISABLED:
				cull = "cull_disabled"
			BaseMaterial3D.CULL_FRONT:
				cull = "cull_front"
	elif source is ShaderMaterial:
		cull = "cull_disabled"  # Unknown: draw both sides.
	if not shaders.has(cull):
		var shader := Shader.new()
		shader.code = NORMAL_SHADER.code.replace("cull_back", cull)
		shaders[cull] = shader
	var material := ShaderMaterial.new()
	material.shader = shaders[cull]
	if base != null:
		material.set_shader_parameter("albedo_color", base.albedo_color)
		if base.albedo_texture != null:
			material.set_shader_parameter("albedo_tex", base.albedo_texture)
			material.set_shader_parameter("use_albedo_tex", true)
		if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
			material.set_shader_parameter("alpha_cut", base.alpha_scissor_threshold)
		elif base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			material.set_shader_parameter("alpha_cut", 0.5)
		material.set_shader_parameter("uv1_scale", base.uv1_scale)
		material.set_shader_parameter("uv1_offset", base.uv1_offset)
		if base.normal_enabled and base.normal_texture != null:
			material.set_shader_parameter("normal_tex", base.normal_texture)
			material.set_shader_parameter("use_normal_tex", true)
			material.set_shader_parameter("normal_scale", base.normal_scale)
	return material


static func _combined_aabb(root: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back()
		var visual := node as VisualInstance3D
		if visual != null and visual.is_visible_in_tree() and (visual is GeometryInstance3D):
			var box := visual.global_transform * visual.get_aabb()
			if first:
				result = box
				first = false
			else:
				result = result.merge(box)
		stack.append_array(node.get_children())
	return result


static func _clear_end_ranges(root: Node) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node := stack.pop_back()
		if node is GeometryInstance3D:
			node.visibility_range_end = 0.0
			node.visibility_range_end_margin = 0.0
		stack.append_array(node.get_children(true))

@tool
extends RefCounted
## Renders an object from several sides into an [ImpostorData]. This needs a running renderer, so it can't be used
## with --headless, and it is a coroutine: [code]var data = await Baker.bake(host, node, settings)[/code].

const PADDING := 4  ## Transparent pixels around the object in every view, so mipmaps don't mix views.

class Settings:
	var views := 12
	var rows := 2
	var cell_size := 256
	var min_elevation := 10.0
	var max_elevation := 55.0
	## Strength of the ambient light the views are lit with; 1.0 shows the albedo as it is.
	var brightness := 1.0
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

	var atlas := Image.create(views * cell, rows * cell, false, Image.FORMAT_RGBA8)
	var total := views * rows
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
				var done := j * views + i + 1
				settings.progress.call(float(done) / float(total), "Rendering view %d of %d..." % [done, total])
	viewport.queue_free()

	atlas.fix_alpha_edges()
	atlas.generate_mipmaps()

	var data := ImpostorData.new()
	data.atlas = ImageTexture.create_from_image(atlas)
	data.views = views
	data.rows = rows
	data.min_elevation = settings.min_elevation
	data.max_elevation = settings.max_elevation
	data.quad_size = quad_size
	data.center = center
	return data


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

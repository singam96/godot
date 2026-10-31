@tool
extends RefCounted
## Bakes groups of simple materials into one texture atlas.

## Texels of edge padding around every texture in the atlas, to limit bleeding between neighbors.
const PADDING := 2


## Returns whether the material only uses features that survive being baked into an atlas: an opaque
## StandardMaterial3D that has at most an albedo texture and an albedo color.
static func is_eligible(material: Material) -> bool:
	var m := material as StandardMaterial3D
	if m == null:
		return false
	if m.next_pass != null or m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or m.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
		return false
	for feature in BaseMaterial3D.FEATURE_MAX:
		if m.get_feature(feature):
			return false
	for slot in BaseMaterial3D.TEXTURE_MAX:
		if slot != BaseMaterial3D.TEXTURE_ALBEDO and m.get_texture(slot) != null:
			return false
	for flag in [BaseMaterial3D.FLAG_UV1_USE_TRIPLANAR, BaseMaterial3D.FLAG_UV1_USE_WORLD_TRIPLANAR, BaseMaterial3D.FLAG_USE_POINT_SIZE, BaseMaterial3D.FLAG_FIXED_SIZE, BaseMaterial3D.FLAG_USE_SHADOW_TO_OPACITY]:
		if m.get_flag(flag):
			return false
	return m.uv1_scale == Vector3.ONE and m.uv1_offset == Vector3.ZERO and not m.grow \
			and m.distance_fade_mode == BaseMaterial3D.DISTANCE_FADE_DISABLED and not m.proximity_fade_enabled


## Materials with the same key can share an atlas, because the rest of their settings are identical.
static func group_key(m: StandardMaterial3D) -> String:
	var key := "%d|%d|%d|%d|%d|%d|%d|%.4f|%.4f|%.4f" % [m.cull_mode, m.shading_mode, m.diffuse_mode, m.specular_mode, m.texture_filter, m.depth_draw_mode, m.render_priority, m.roughness, m.metallic, m.metallic_specular]
	for flag in BaseMaterial3D.FLAG_MAX:
		key += "1" if m.get_flag(flag) else "0"
	return key


## Prepares the albedo texture of a material for baking: a decompressed RGBA8 copy, or null if there is none.
## Returns false in [param ok] position 0 of the result if the texture could not be read.
static func read_albedo(m: StandardMaterial3D) -> Array:
	var texture := m.albedo_texture
	if texture == null:
		return [true, null]
	var image := texture.get_image()
	if image == null or image.is_empty():
		return [false, null]
	image = image.duplicate()
	if image.is_compressed() and image.decompress() != OK:
		return [false, null]
	image.convert(Image.FORMAT_RGBA8)
	return [true, image]


## Layout of [param count] cells: the cell size (reduced if the atlas would get too large), the number of columns
## and rows, and for every cell the rectangle (in 0..1 UV space) that the 0..1 UV range of its material maps to.
static func layout(count: int, cell_size: int) -> Dictionary:
	var columns := ceili(sqrt(float(count)))
	var rows := ceili(float(count) / columns)
	var cell := clampi(cell_size, 16, 2048)
	while cell > 16 and (columns * cell > 8192 or rows * cell > 8192):
		cell /= 2
	var size := Vector2(columns * cell, rows * cell)
	var inner := cell - 2 * PADDING
	var rects: Array[Rect2] = []
	for i in count:
		var origin := Vector2((i % columns) * cell + PADDING, (i / columns) * cell + PADDING)
		rects.append(Rect2(origin / size, Vector2(inner, inner) / size))
	return {"cell": cell, "columns": columns, "rows": rows, "rects": rects}


## Bakes the atlas image. [param images] holds the prepared albedo image of every material (null for materials
## without a texture). Only does CPU work, so it is safe to call from a thread.
static func bake(materials: Array, images: Array, atlas_layout: Dictionary) -> Image:
	var cell: int = atlas_layout.cell
	var columns: int = atlas_layout.columns
	var inner := cell - 2 * PADDING
	var atlas := Image.create(columns * cell, int(atlas_layout.rows) * cell, false, Image.FORMAT_RGBA8)
	for i in materials.size():
		var tint: Color = materials[i].albedo_color
		tint.a = 1.0
		var tile := Image.create(cell, cell, false, Image.FORMAT_RGBA8)
		var source: Image = images[i]
		if source == null:
			tile.fill(tint)
		else:
			source = source.duplicate()
			source.resize(inner, inner, Image.INTERPOLATE_BILINEAR)
			if tint != Color.WHITE:
				# The albedo color is multiplied in linear space in the shader.
				var linear_tint := tint.srgb_to_linear()
				for y in inner:
					for x in inner:
						var c := source.get_pixel(x, y)
						var lc := c.srgb_to_linear()
						source.set_pixel(x, y, Color(lc.r * linear_tint.r, lc.g * linear_tint.g, lc.b * linear_tint.b, 1.0).linear_to_srgb())
			tile.blit_rect(source, Rect2i(0, 0, inner, inner), Vector2i(PADDING, PADDING))
			# Replicate the border texels into the padding.
			for p in PADDING:
				tile.blit_rect(source, Rect2i(0, 0, 1, inner), Vector2i(p, PADDING))
				tile.blit_rect(source, Rect2i(inner - 1, 0, 1, inner), Vector2i(PADDING + inner + p, PADDING))
			var copy := tile.duplicate() as Image
			for p in PADDING:
				tile.blit_rect(copy, Rect2i(0, PADDING, cell, 1), Vector2i(0, p))
				tile.blit_rect(copy, Rect2i(0, PADDING + inner - 1, cell, 1), Vector2i(0, PADDING + inner + p))
		atlas.blit_rect(tile, Rect2i(0, 0, cell, cell), Vector2i((i % columns) * cell, (i / columns) * cell))
	atlas.generate_mipmaps()
	return atlas


## Creates the material that draws the atlas, based on the settings of [param template]. Uses the rendering server.
static func create_material(template: StandardMaterial3D, atlas: Image) -> StandardMaterial3D:
	var result := template.duplicate() as StandardMaterial3D
	result.albedo_color = Color.WHITE
	result.albedo_texture = ImageTexture.create_from_image(atlas)
	return result

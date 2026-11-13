extends SceneTree
## Regression tests for the problems found in the HLOD review. Run with:
##   godot --headless --path <project> -s res://tests/run_hlod_review_tests.gd
## Exits with code 1 if any check fails.

const Cluster := preload("res://addons/hlod/hlod_cluster_3d.gd")
const Atlas := preload("res://addons/hlod/hlod_atlas.gd")
const AtlasContext := preload("res://addons/hlod/hlod_atlas_context.gd")

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _box(position: Vector3, material: Material = null) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.material = material
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = position
	return mi


func _color(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	return m


func _cluster() -> Node3D:
	var c: Node3D = Cluster.new()
	c.remove_hidden_faces = false
	c.simplify_ratio = 1.0
	return c


func _internal_proxy(c: Node3D) -> MeshInstance3D:
	for child in c.get_children(true):
		if child is MeshInstance3D and child.mesh == c.proxy_mesh:
			return child
	return null


func test_only_meshes_are_collected() -> void:
	print("only meshes are collected")
	var c := _cluster()
	c.add_child(_box(Vector3.ZERO))
	c.add_child(Sprite3D.new())
	c.add_child(Label3D.new())
	var multi := MultiMeshInstance3D.new()
	c.add_child(multi)  # no multimesh assigned
	_check(c.collect_mergeable_geometry().size() == 2, "mesh and multimesh nodes only (%d)" % c.collect_mergeable_geometry().size())
	_check(c.generate_proxy() == OK, "generate with a sprite, a label and an empty multimesh next to a mesh")
	_check(c.proxy_mesh != null and c.proxy_mesh.get_surface_count() == 1, "proxy made from the mesh")
	var only_sprite := _cluster()
	only_sprite.add_child(Sprite3D.new())
	_check(only_sprite.generate_proxy() == ERR_DOES_NOT_EXIST, "a lone sprite leaves nothing to merge")
	c.free()
	only_sprite.free()


func test_grid_skips_empty_cells() -> void:
	print("grid skips empty cells")
	var c := _cluster()
	c.switch_distance = 100.0
	c.add_child(_box(Vector3(1, 0, 1)))
	var marker := Node3D.new()
	marker.name = "Marker"
	marker.position = Vector3(105, 2, 3)
	c.add_child(marker)
	var hidden_box := _box(Vector3(205, 0, 1))
	hidden_box.visible = false
	c.add_child(hidden_box)
	_check(c.build_grid(20.0) == OK, "build_grid OK although two cells have nothing to merge")
	var cells := 0
	for child in c.get_children():
		if child is Cluster:
			cells += 1
	_check(cells == 1, "only the cell with a mesh exists (%d)" % cells)
	_check(marker.get_parent() == c and marker.position.is_equal_approx(Vector3(105, 2, 3)), "marker stayed where it was")
	_check(hidden_box.get_parent() == c and hidden_box.position.is_equal_approx(Vector3(205, 0, 1)), "hidden mesh stayed where it was")
	_check(c.proxy_mesh != null, "root has a proxy")
	c.free()

	var none := _cluster()
	none.add_child(Node3D.new())
	_check(none.build_grid(10.0) == ERR_DOES_NOT_EXIST, "a grid without any mesh reports it")
	none.free()


func test_grid_twice() -> void:
	print("grid twice")
	var c := _cluster()
	var origins := {}
	for x in 3:
		for z in 3:
			var b := _box(Vector3(x * 15.0, 0, z * 15.0))
			b.name = "Box_%d_%d" % [x, z]
			origins[b.name] = b.position
			c.add_child(b)
	_check(c.build_grid(20.0) == OK, "first build_grid")
	_check(c.build_grid(20.0) == OK, "second build_grid")
	var nested := 0
	var found := 0
	for cell in c.get_children():
		if cell is Cluster:
			for inner in cell.get_children():
				if inner is Cluster:
					nested += 1
				elif origins.has(inner.name):
					found += 1
					var global_position: Vector3 = cell.position + inner.position
					_check(global_position.is_equal_approx(origins[inner.name]), "%s kept its place" % inner.name)
	_check(nested == 0, "cells are not nested (%d)" % nested)
	_check(found == 9, "all boxes are in cells (%d)" % found)
	c.free()


func test_grid_shares_atlas() -> void:
	print("grid shares one atlas")
	var c := _cluster()
	c.merge_materials = true
	var red := _color(Color.RED)
	var green := _color(Color.GREEN)
	var blue := _color(Color.BLUE)
	var materials := [red, green, blue]
	for cell in 4:
		for i in 3:
			c.add_child(_box(Vector3(cell * 30.0 + i, 0, 0), materials[(cell + i) % 3]))
	_check(c.build_grid(20.0) == OK, "build_grid OK")
	var textures := {}
	var proxies := 0
	var meshes: Array[Mesh] = [c.proxy_mesh]
	for cell in c.get_children():
		if cell is Cluster and cell.proxy_mesh != null:
			meshes.append(cell.proxy_mesh)
	for mesh in meshes:
		proxies += 1
		for s in mesh.get_surface_count():
			var m := mesh.surface_get_material(s) as StandardMaterial3D
			if m != null and m.albedo_texture != null:
				textures[m.albedo_texture] = true
	_check(proxies > 2, "several proxies (%d)" % proxies)
	_check(textures.size() == 1, "all proxies use the same atlas texture (%d textures)" % textures.size())
	c.free()


func test_padding_and_compression() -> void:
	print("padding and compression")
	_check(Atlas.padding_for(16) == 2, "small cells keep the minimum")
	_check(Atlas.padding_for(128) == 8, "128 px cells get 8 px (%d)" % Atlas.padding_for(128))
	_check(Atlas.padding_for(2048) == 16, "padding is capped")
	var layout := Atlas.layout(4, 128)
	var rect: Rect2 = layout.rects[0]
	var size := Vector2(layout.columns * layout.cell, layout.rows * layout.cell)
	_check(is_equal_approx(rect.size.x * size.x, 128.0 - 2 * layout.padding), "tile is the cell minus the padding")
	# A gradient texture: the padding must repeat the border, so a mip level can't pull in the neighbor.
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			image.set_pixel(x, y, Color(x / 31.0, y / 31.0, 0.0))
	var left := StandardMaterial3D.new()
	left.albedo_texture = ImageTexture.create_from_image(image)
	var right := _color(Color(0, 0, 1))
	var one := Atlas.layout(2, 128)
	var atlas := Atlas.bake([left, right], [image, null], one)
	var pad: int = one.padding
	var inner: int = 128 - 2 * pad
	# Texel 0 of the padding and the first texel of the tile have the same color (border replicated).
	var border := atlas.get_pixel(pad, pad + inner / 2)
	var padded := atlas.get_pixel(0, pad + inner / 2)
	_check(border.is_equal_approx(padded), "left padding repeats the border (%s vs %s)" % [border, padded])
	var last := atlas.get_pixel(pad + inner - 1, pad + inner / 2)
	var after := atlas.get_pixel(pad + inner + pad - 1, pad + inner / 2)
	_check(last.is_equal_approx(after), "right padding repeats the border")
	_check(Atlas.compress_image(atlas, -1) == atlas, "no compression mode returns the image")
	var compressed := Atlas.compress_image(atlas, Image.COMPRESS_S3TC)
	_check(compressed != null and compressed.get_size() == atlas.get_size(), "compressing keeps the size")
	# An unreadable texture is remembered instead of being read again and again.
	var context := AtlasContext.new()
	var broken := StandardMaterial3D.new()
	broken.albedo_texture = PlaceholderTexture2D.new()
	_check(context.register(broken) == "" and context.register(broken) == "", "unreadable texture is not registered")
	_check(context.groups.is_empty(), "no group was made for it")


func test_proxy_copies_shadows_and_layers() -> void:
	print("proxy copies shadows and layers")
	var c := _cluster()
	var a := _box(Vector3.ZERO)
	a.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	a.layers = 2
	var b := _box(Vector3(3, 0, 0))
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.layers = 4
	c.add_child(a)
	c.add_child(b)
	root.add_child(c)
	_check(c.generate_proxy() == OK, "generate OK")
	_check(c.proxy_cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "no source casts shadows, so the proxy does not")
	_check(c.proxy_layers == 6, "layers are the union (%d)" % c.proxy_layers)
	var proxy := _internal_proxy(c)
	_check(proxy != null and proxy.layers == 6 and proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "the proxy node uses them")
	b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	c.generate_proxy()
	_check(c.proxy_cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "one caster is enough")
	c.free()


func test_hidden_faces() -> void:
	print("hidden faces")
	var c := Cluster.new()
	c.simplify_ratio = 1.0
	c.merge_materials = false
	var plane := PlaneMesh.new()
	plane.size = Vector2(10, 10)
	var mi := MeshInstance3D.new()
	mi.mesh = plane
	c.add_child(mi)
	_check(c.generate_proxy() == OK, "a lone plane is generated")
	var full := _count(c.proxy_mesh)
	_check(full == 2, "a visible plane keeps both triangles (%d)" % full)
	c.free()

	var big := Cluster.new()
	big.simplify_ratio = 1.0
	big.merge_materials = false
	big.hidden_face_triangle_limit = 1000
	var sphere := SphereMesh.new()
	sphere.radial_segments = 64
	sphere.rings = 32
	var s := MeshInstance3D.new()
	s.mesh = sphere
	big.add_child(s)
	var inner := MeshInstance3D.new()
	var inner_sphere := SphereMesh.new()
	inner_sphere.radius = 0.25
	inner_sphere.height = 0.5
	inner.mesh = inner_sphere
	big.add_child(inner)
	var before := _count(sphere)
	_check(big.generate_proxy() == OK, "generate with a low limit")
	_check(_count(big.proxy_mesh) > before, "above the limit nothing is removed (%d)" % _count(big.proxy_mesh))
	big.hidden_face_triangle_limit = 1000000
	_check(big.generate_proxy() == OK, "generate with a high limit")
	_check(_count(big.proxy_mesh) <= before, "below the limit the sphere inside the sphere is removed (%d <= %d)" % [_count(big.proxy_mesh), before])
	big.free()


func _count(mesh: Mesh) -> int:
	var total := 0
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var indices = arrays[Mesh.ARRAY_INDEX]
		total += (indices.size() if indices != null else arrays[Mesh.ARRAY_VERTEX].size()) / 3
	return total


func test_many_instances() -> void:
	print("many instances")
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = BoxMesh.new()
	multimesh.instance_count = 3000
	for i in multimesh.instance_count:
		multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(i % 60, 0, i / 60)))
	var instance := MultiMeshInstance3D.new()
	instance.multimesh = multimesh
	var c := _cluster()
	c.merge_materials = true
	c.add_child(instance)
	var started := Time.get_ticks_msec()
	_check(c.generate_proxy() == OK, "generate 3000 instances")
	var elapsed := Time.get_ticks_msec() - started
	print("  3000 instances merged in %d ms" % elapsed)
	_check(elapsed < 60000, "merging stays fast (%d ms)" % elapsed)
	_check(_count(c.proxy_mesh) == 3000 * 12, "all triangles are there (%d)" % _count(c.proxy_mesh))
	c.free()


func test_streaming_gap_and_retry() -> void:
	print("streaming gap and retry")
	var c := _cluster()
	c.switch_distance = 10.0
	c.switch_margin = 2.0
	c.stream_load_margin = 5.0
	c.stream_unload_margin = 10.0
	var thing := _box(Vector3.ZERO)
	thing.name = "Thing"
	c.add_child(thing)
	root.add_child(c)
	thing.owner = c
	var path := "user://hlod_review_detail.tscn"
	_check(c.store_detail_scene(path) == OK, "store_detail_scene OK")
	await process_frame
	var proxy := _internal_proxy(c)
	_check(proxy != null and proxy.visibility_range_begin == 0.0, "the proxy covers every distance while the detail is not loaded (%s)" % [proxy.visibility_range_begin if proxy != null else -1.0])

	var cam := Camera3D.new()
	root.add_child(cam)
	cam.current = true
	cam.global_position = Vector3(0, 0, 3)
	var guard := 0
	while c.get_child_count() == 0 and guard < 500:
		await process_frame
		c.update_streaming()
		guard += 1
	_check(c.get_child_count() == 1, "detail loaded")
	_check(is_equal_approx(proxy.visibility_range_begin, 10.0), "once loaded, the proxy goes back to its range")
	cam.global_position = Vector3(0, 0, 500)
	c.update_streaming()
	_check(c.get_child_count() == 0, "detail freed at once")
	_check(proxy.visibility_range_begin == 0.0, "the proxy covers every distance again")
	c.free()

	# A detail scene that is missing at first is tried again later.
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://hlod_review_missing.tscn"))
	var missing := _cluster()
	missing.switch_distance = 10.0
	missing.detail_scene_path = "user://hlod_review_missing.tscn"
	root.add_child(missing)
	cam.global_position = Vector3(0, 0, 3)
	for i in 100:
		missing.update_streaming()
		await process_frame
		if missing._stream_state == Cluster.StreamState.FAILED:
			break
	_check(missing._stream_state == Cluster.StreamState.FAILED, "a missing scene is a failure")
	var source := Node3D.new()
	var packed := PackedScene.new()
	packed.pack(source)
	_check(ResourceSaver.save(packed, "user://hlod_review_missing.tscn") == OK, "the scene shows up")
	source.free()
	missing.update_streaming()
	_check(missing._stream_state == Cluster.StreamState.FAILED, "not tried again before the delay")
	missing._retry_at_msec = 0
	missing.update_streaming()
	guard = 0
	while missing.get_child_count() == 0 and guard < 500:
		await process_frame
		missing.update_streaming()
		guard += 1
	_check(missing.get_child_count() == 1, "after the delay it loads")
	cam.free()
	missing.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://hlod_review_missing.tscn"))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_store_detail_failure_restores_owners() -> void:
	print("store_detail_scene failure restores owners")
	var c := _cluster()
	var child := _box(Vector3.ZERO)
	child.name = "Child"
	c.add_child(child)
	child.owner = c
	var inner := Node3D.new()
	inner.name = "Inner"
	child.add_child(inner)
	inner.owner = c
	var err: Error = c.store_detail_scene("res://does_not_exist_dir/detail.tscn")
	_check(err != OK, "saving to a missing folder fails (%d)" % err)
	_check(child.get_parent() == c, "child is back")
	_check(child.owner == c and inner.owner == c, "owners are back to the root cluster")
	c.free()


func _init() -> void:
	var tests := [
		test_only_meshes_are_collected, test_grid_skips_empty_cells, test_grid_twice, test_grid_shares_atlas,
		test_padding_and_compression, test_proxy_copies_shadows_and_layers, test_hidden_faces, test_many_instances,
		test_streaming_gap_and_retry, test_store_detail_failure_restores_owners,
	]
	for t in tests:
		await t.call()
	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

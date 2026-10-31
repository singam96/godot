@tool
extends RefCounted
## Splits a scene into the cells a [WorldStreamer] loads. Works on a copy: the source nodes are left alone.

const HLOD_SCRIPT := "res://addons/hlod/hlod_cluster_3d.gd"


class Options:
	## Also make a "far_x_z.scn" per cell: one merged, simplified proxy (needs the HLOD add-on).
	var make_far := false
	var far_simplify_ratio := 0.15
	## Also add a baked NavigationRegion3D to every cell scene.
	var bake_navigation := false
	## Used for the navigation mesh; null uses the defaults.
	var navigation_mesh: NavigationMesh


## Sorts the direct [Node3D] children of [param root] into cells of [param cell_size] by their position relative to
## [param root], and saves one scene per cell into [param dir]. Returns {"cells": int, "paths": Array[String],
## "far_cells": int, "error": Error}. The root's own transform is ignored, like the streamer ignores it.
static func build(root: Node3D, cell_size: float, dir: String, options: Options = null) -> Dictionary:
	if options == null:
		options = Options.new()
	var result := {"cells": 0, "far_cells": 0, "paths": [] as Array[String], "error": OK}
	if cell_size <= 0.0:
		result["error"] = ERR_INVALID_PARAMETER
		return result
	DirAccess.make_dir_recursive_absolute(dir)

	var groups := {}  ## Vector2i -> Array[Node3D]
	for child in root.get_children():
		var node := child as Node3D
		if node == null:
			continue
		var local := node.position
		var coord := Vector2i((Vector2(local.x, local.z) / cell_size).floor())
		if not groups.has(coord):
			groups[coord] = []
		groups[coord].append(node)

	for coord in groups:
		var cell := Node3D.new()
		cell.name = "Cell_%d_%d" % [coord.x, coord.y]
		for node in groups[coord]:
			var copy: Node = node.duplicate()
			cell.add_child(copy)
			_set_owners(copy, cell)
		if options.bake_navigation:
			_add_navigation(cell, options.navigation_mesh)
		var packed := PackedScene.new()
		var err := packed.pack(cell)
		var path := "%s/cell_%d_%d.tscn" % [dir, coord.x, coord.y]
		if err == OK:
			err = ResourceSaver.save(packed, path)
		if err != OK:
			result["error"] = err
			cell.free()
			continue
		result["cells"] += 1
		result["paths"].append(path)

		if options.make_far and _make_far(cell, dir, coord, options):
			result["far_cells"] += 1
		cell.free()
	return result


static func _set_owners(node: Node, owner: Node) -> void:
	node.owner = owner
	# Do not flatten instanced scenes: their content belongs to them.
	if node.scene_file_path != "" and node != owner:
		return
	for child in node.get_children():
		_set_owners(child, owner)


static func _make_far(cell: Node3D, dir: String, coord: Vector2i, options: Options) -> bool:
	var script := load(HLOD_SCRIPT) as GDScript
	if script == null:
		push_warning("The HLOD add-on is needed for far cells; skipping.")
		return false
	var cluster: Node3D = script.new()
	cluster.switch_distance = 0.01  # Always show the proxy.
	cluster.simplify_ratio = options.far_simplify_ratio
	cluster.name = "Far_%d_%d" % [coord.x, coord.y]
	for child in cell.get_children():
		if child is OccluderInstance3D or child is NavigationRegion3D:
			continue
		cluster.add_child(child.duplicate())
	if cluster.generate_proxy() != OK:
		cluster.free()
		return false
	# Keep only the proxy mesh.
	for child in cluster.get_children():
		cluster.remove_child(child)
		child.free()
	var packed := PackedScene.new()
	var ok := packed.pack(cluster) == OK
	if ok:
		ok = ResourceSaver.save(packed, "%s/far_%d_%d.scn" % [dir, coord.x, coord.y]) == OK
	cluster.free()
	return ok


static func _add_navigation(cell: Node3D, template: NavigationMesh) -> void:
	var navmesh: NavigationMesh = template.duplicate() if template != null else NavigationMesh.new()
	var geometry := NavigationMeshSourceGeometryData3D.new()
	# The parser needs the nodes in a scene tree.
	var tree := Engine.get_main_loop() as SceneTree
	var was_in_tree := cell.is_inside_tree()
	if not was_in_tree:
		tree.root.add_child(cell)
	NavigationServer3D.parse_source_geometry_data(navmesh, geometry, cell)
	if not was_in_tree:
		tree.root.remove_child(cell)
	if not geometry.has_data():
		return
	NavigationServer3D.bake_from_source_geometry_data(navmesh, geometry)
	if navmesh.get_polygon_count() == 0:
		return
	var region := NavigationRegion3D.new()
	region.name = "Navigation"
	region.navigation_mesh = navmesh
	cell.add_child(region)
	region.owner = cell

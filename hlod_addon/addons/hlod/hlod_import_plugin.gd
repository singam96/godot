@tool
extends EditorScenePostImportPlugin
## Adds an "HLOD" section to the import options of 3D scenes. When enabled, all nodes of the imported scene are
## moved below an HLODCluster and a proxy mesh is generated during the import.

const HLODCluster := preload("hlod_cluster_3d.gd")
const HLODTools := preload("hlod_tools.gd")


func _get_import_options(_path: String) -> void:
	add_import_option_advanced(TYPE_BOOL, "hlod/enabled", false, PROPERTY_HINT_NONE, "", PROPERTY_USAGE_DEFAULT | PROPERTY_USAGE_UPDATE_ALL_IF_MODIFIED)
	add_import_option_advanced(TYPE_FLOAT, "hlod/switch_distance", 50.0, PROPERTY_HINT_RANGE, "0.01,4096,0.01,or_greater,suffix:m")
	add_import_option_advanced(TYPE_FLOAT, "hlod/simplify_ratio", 0.25, PROPERTY_HINT_RANGE, "0.01,1,0.01")
	add_import_option_advanced(TYPE_FLOAT, "hlod/grid_cell_size", 0.0, PROPERTY_HINT_RANGE, "0,4096,0.1,or_greater,suffix:m")
	add_import_option("hlod/merge_materials", true)
	add_import_option("hlod/remove_hidden_faces", true)


func _get_option_visibility(_path: String, _for_animation: bool, option: String) -> Variant:
	if option.begins_with("hlod/") and option != "hlod/enabled":
		return get_option_value("hlod/enabled")
	return null


func _post_process(scene: Node) -> void:
	if not get_option_value("hlod/enabled"):
		return

	# The root of an imported scene can't be replaced here, so the cluster becomes its only child.
	var cluster := HLODCluster.new()
	cluster.name = "HLOD"
	var children := scene.get_children()
	scene.add_child(cluster)
	cluster.owner = scene
	for child in children:
		HLODTools.move_node_keeping_owner(child, cluster)

	cluster.switch_distance = get_option_value("hlod/switch_distance")
	cluster.simplify_ratio = get_option_value("hlod/simplify_ratio")
	cluster.merge_materials = get_option_value("hlod/merge_materials")
	cluster.remove_hidden_faces = get_option_value("hlod/remove_hidden_faces")

	var grid_cell_size: float = get_option_value("hlod/grid_cell_size")
	var err: Error = cluster.build_grid(grid_cell_size) if grid_cell_size > 0.0 else cluster.generate_proxy()
	if err != OK:
		push_error("HLOD: could not generate the proxy mesh during import (error %d). Make sure the scene contains meshes." % err)

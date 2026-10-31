@tool
extends EditorPlugin
## Adds "Generate Foliage" and "Clear" buttons to the 3D editor toolbar when a FoliageScatter is selected.

var _box: HBoxContainer
var _report: AcceptDialog


func _enter_tree() -> void:
	_box = HBoxContainer.new()
	_box.visible = false
	var generate := Button.new()
	generate.text = "Generate Foliage"
	generate.pressed.connect(_generate)
	var clear := Button.new()
	clear.text = "Clear Foliage"
	clear.pressed.connect(_clear)
	_box.add_child(generate)
	_box.add_child(clear)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _box)
	_report = AcceptDialog.new()
	_report.title = "Foliage"
	EditorInterface.get_base_control().add_child(_report)
	EditorInterface.get_selection().selection_changed.connect(_update_visibility)


func _exit_tree() -> void:
	if EditorInterface.get_selection().selection_changed.is_connected(_update_visibility):
		EditorInterface.get_selection().selection_changed.disconnect(_update_visibility)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _box)
	_box.queue_free()
	_report.queue_free()


func _selected() -> FoliageScatter:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	return nodes[0] as FoliageScatter if nodes.size() == 1 else null


func _update_visibility() -> void:
	_box.visible = _selected() != null


func _generate() -> void:
	var scatter := _selected()
	if scatter == null:
		return
	var count := scatter.generate()
	_report.dialog_text = "Generated %d instance(s)." % count
	if scatter.mesh == null:
		_report.dialog_text = "Set a Mesh first."
	elif scatter.save_in_scene and count > 20000:
		_report.dialog_text += "\nThat is a lot to store in the scene file. Consider turning off 'Save In Scene' to generate at run time."
	_report.popup_centered()


func _clear() -> void:
	var scatter := _selected()
	if scatter != null:
		scatter.clear()

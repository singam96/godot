@tool
extends EditorPlugin
## Adds an "Occluders" menu to the 3D editor toolbar to add or remove occluders on the selected nodes.

const Tools := preload("occluder_tools.gd")
const SETTING := "rendering/occlusion_culling/use_occlusion_culling"
const ADD := 0
const REMOVE := 1

var _menu: MenuButton
var _dialog: ConfirmationDialog
var _min_size: SpinBox
var _arrays: CheckBox
var _report: AcceptDialog


func _enter_tree() -> void:
	_menu = MenuButton.new()
	_menu.text = "Occluders"
	_menu.visible = false
	_menu.get_popup().add_item("Add to selection...", ADD)
	_menu.get_popup().add_item("Remove generated from selection", REMOVE)
	_menu.get_popup().id_pressed.connect(_on_menu)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)

	_dialog = ConfirmationDialog.new()
	_dialog.title = "Add occluders"
	_dialog.confirmed.connect(_add_occluders)
	var box := VBoxContainer.new()
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Minimum size (m):"
	_min_size = SpinBox.new()
	_min_size.min_value = 0.5
	_min_size.max_value = 1000.0
	_min_size.step = 0.5
	_min_size.value = 4.0
	row.add_child(label)
	row.add_child(_min_size)
	box.add_child(row)
	_arrays = CheckBox.new()
	_arrays.text = "Also use exact occluders for simple non-box meshes"
	_arrays.button_pressed = true
	box.add_child(_arrays)
	_dialog.add_child(box)
	EditorInterface.get_base_control().add_child(_dialog)

	_report = AcceptDialog.new()
	_report.title = "Occluders"
	EditorInterface.get_base_control().add_child(_report)

	EditorInterface.get_selection().selection_changed.connect(_update_visibility)


func _exit_tree() -> void:
	if EditorInterface.get_selection().selection_changed.is_connected(_update_visibility):
		EditorInterface.get_selection().selection_changed.disconnect(_update_visibility)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _menu)
	_menu.queue_free()
	_dialog.queue_free()
	_report.queue_free()


func _update_visibility() -> void:
	var any := false
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is Node3D:
			any = true
	_menu.visible = any


func _on_menu(id: int) -> void:
	if id == ADD:
		_dialog.popup_centered()
	else:
		_remove_occluders()


func _selected_roots() -> Array[Node]:
	var roots: Array[Node] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node is Node3D:
			roots.append(node)
	return roots


func _add_occluders() -> void:
	var edited := EditorInterface.get_edited_scene_root()
	if edited == null:
		return
	var settings := Tools.Settings.new()
	settings.min_size = _min_size.value
	settings.use_array_occluders = _arrays.button_pressed

	var undo := get_undo_redo()
	undo.create_action("Add occluders")
	var added := 0
	var not_editable := 0
	var skipped := {}
	for root in _selected_roots():
		var scan := Tools.scan(root, settings)
		for reason in scan["skipped"]:
			skipped[reason] = skipped.get(reason, 0) + scan["skipped"][reason]
		for result in scan["found"]:
			var mi: MeshInstance3D = result["mesh_instance"]
			if mi != edited and mi.owner != edited:
				not_editable += 1  # Part of an instanced scene; its occluders belong in that scene.
				continue
			var occ := Tools.make_instance(result)
			undo.add_do_method(mi, "add_child", occ, true)
			undo.add_do_method(occ, "set_owner", edited)
			undo.add_do_reference(occ)
			undo.add_undo_method(mi, "remove_child", occ)
			added += 1
	undo.commit_action()

	var text := "Added %d occluder(s)." % added
	if not_editable > 0:
		text += "\n%d belong to instanced scenes and were left alone." % not_editable
	if not skipped.is_empty():
		text += "\nSkipped:"
		for reason in skipped:
			text += "\n  %d x %s" % [skipped[reason], reason]
	if not ProjectSettings.get_setting(SETTING, false):
		ProjectSettings.set_setting(SETTING, true)
		ProjectSettings.save()
		text += "\n\nOcclusion culling was off, so it was turned on in the project settings. Restart the editor for it to take effect."
	_report.dialog_text = text
	_report.popup_centered()


func _remove_occluders() -> void:
	var undo := get_undo_redo()
	undo.create_action("Remove generated occluders")
	var removed := 0
	for root in _selected_roots():
		for occ in Tools.find_generated(root):
			var parent := occ.get_parent()
			undo.add_do_method(parent, "remove_child", occ)
			undo.add_undo_method(parent, "add_child", occ, true)
			undo.add_undo_method(occ, "set_owner", EditorInterface.get_edited_scene_root())
			undo.add_undo_reference(occ)
			removed += 1
	undo.commit_action()
	_report.dialog_text = "Removed %d occluder(s)." % removed
	_report.popup_centered()

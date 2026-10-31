@tool
extends EditorPlugin
## Adds a "Bake Impostor" button to the 3D editor toolbar for the selected node.

const Baker := preload("impostor_baker.gd")
const SAVE_DIR := "res://impostors"

var _button: Button
var _dialog: ConfirmationDialog
var _views: SpinBox
var _rows: SpinBox
var _cell: OptionButton
var _distance: SpinBox
var _lit: CheckBox
var _depth: CheckBox
var _progress: AcceptDialog
var _progress_bar: ProgressBar
var _progress_label: Label
var _alert: AcceptDialog
var _baking := false


func _enter_tree() -> void:
	_button = Button.new()
	_button.text = "Bake Impostor"
	_button.visible = false
	_button.pressed.connect(_on_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)

	_dialog = ConfirmationDialog.new()
	_dialog.title = "Bake impostor"
	_dialog.confirmed.connect(_bake)
	var grid := GridContainer.new()
	grid.columns = 2
	_views = _add_spin(grid, "Views around:", 4, 32, 12)
	_rows = _add_spin(grid, "Elevation rows:", 1, 4, 2)
	var cell_label := Label.new()
	cell_label.text = "View size (px):"
	grid.add_child(cell_label)
	_cell = OptionButton.new()
	for size in [128, 256, 512]:
		_cell.add_item(str(size), size)
	_cell.select(1)
	grid.add_child(_cell)
	_distance = _add_spin(grid, "Switch distance (m):", 1, 4096, 150)
	_lit = CheckBox.new()
	_lit.text = "Lit (also bake normals)"
	_lit.button_pressed = true
	grid.add_child(_lit)
	grid.add_child(Control.new())
	_depth = CheckBox.new()
	_depth.text = "Depth and ambient occlusion (Forward+)"
	_depth.button_pressed = true
	grid.add_child(_depth)
	grid.add_child(Control.new())
	_dialog.add_child(grid)
	EditorInterface.get_base_control().add_child(_dialog)

	_progress = AcceptDialog.new()
	_progress.title = "Baking impostor"
	_progress.get_ok_button().visible = false
	_progress.exclusive = true
	var box := VBoxContainer.new()
	_progress_label = Label.new()
	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(320, 0)
	_progress_bar.max_value = 1.0
	box.add_child(_progress_label)
	box.add_child(_progress_bar)
	_progress.add_child(box)
	EditorInterface.get_base_control().add_child(_progress)

	_alert = AcceptDialog.new()
	_alert.title = "Impostor"
	EditorInterface.get_base_control().add_child(_alert)

	EditorInterface.get_selection().selection_changed.connect(_update_visibility)


func _exit_tree() -> void:
	if EditorInterface.get_selection().selection_changed.is_connected(_update_visibility):
		EditorInterface.get_selection().selection_changed.disconnect(_update_visibility)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)
	_button.queue_free()
	_dialog.queue_free()
	_progress.queue_free()
	_alert.queue_free()


func _add_spin(grid: GridContainer, text: String, min_value: float, max_value: float, value: float) -> SpinBox:
	var label := Label.new()
	label.text = text
	grid.add_child(label)
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.value = value
	grid.add_child(spin)
	return spin


func _selected() -> Node3D:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	return nodes[0] as Node3D if nodes.size() == 1 else null


func _update_visibility() -> void:
	_button.visible = _selected() != null


func _on_pressed() -> void:
	var node := _selected()
	if node == null or _baking:
		return
	if node == EditorInterface.get_edited_scene_root():
		_alert.dialog_text = "Select a node inside the scene, not the scene root. The impostor is added next to it."
		_alert.popup_centered()
		return
	_dialog.popup_centered()


func _on_progress(fraction: float, text: String) -> void:
	_progress_bar.value = fraction
	_progress_label.text = text


func _bake() -> void:
	var source := _selected()
	var edited := EditorInterface.get_edited_scene_root()
	if source == null or edited == null or _baking:
		return
	_baking = true
	var settings := Baker.Settings.new()
	settings.views = int(_views.value)
	settings.rows = int(_rows.value)
	settings.cell_size = _cell.get_selected_id()
	settings.bake_normals = _lit.button_pressed
	settings.bake_depth_and_ao = _depth.button_pressed
	settings.progress = _on_progress
	_progress_bar.value = 0.0
	_progress_label.text = "Preparing..."
	_progress.popup_centered()

	var data: ImpostorData = await Baker.bake(self, source, settings)
	_progress.hide()
	_baking = false
	if data == null:
		_alert.dialog_text = "Nothing to draw: the node has no visible meshes."
		_alert.popup_centered()
		return

	DirAccess.make_dir_recursive_absolute(SAVE_DIR)
	var scene_name := edited.scene_file_path.get_file().get_basename() if edited.scene_file_path != "" else "scene"
	var path := "%s/%s_%s.res" % [SAVE_DIR, scene_name, source.name]
	if ResourceSaver.save(data, path) != OK:
		_alert.dialog_text = "Could not save " + path
		_alert.popup_centered()
		return
	var saved := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE) as ImpostorData

	var impostor := Impostor3D.new()
	impostor.name = str(source.name) + "Impostor"
	impostor.data = saved
	impostor.switch_distance = _distance.value
	impostor.transform = source.transform
	var parent := source.get_parent()
	var undo := get_undo_redo()
	undo.create_action("Bake impostor")
	undo.add_do_method(parent, "add_child", impostor, true)
	undo.add_do_method(impostor, "set_owner", edited)
	undo.add_do_property(impostor, "target", NodePath("../" + str(source.name)))
	undo.add_do_reference(impostor)
	undo.add_undo_method(parent, "remove_child", impostor)
	undo.commit_action()
	EditorInterface.get_resource_filesystem().scan()

@tool
extends EditorPlugin
## Adds a "Split into Cells" button to the 3D editor toolbar for the selected Node3D.

const Builder := preload("world_cell_builder.gd")

var _button: Button
var _dialog: ConfirmationDialog
var _size: SpinBox
var _dir: LineEdit
var _far: CheckBox
var _nav: CheckBox
var _report: AcceptDialog


func _enter_tree() -> void:
	_button = Button.new()
	_button.text = "Split into Cells"
	_button.visible = false
	_button.pressed.connect(func(): _dialog.popup_centered())
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)

	_dialog = ConfirmationDialog.new()
	_dialog.title = "Split into cells"
	_dialog.confirmed.connect(_split)
	var grid := GridContainer.new()
	grid.columns = 2
	var l1 := Label.new()
	l1.text = "Cell size (m):"
	grid.add_child(l1)
	_size = SpinBox.new()
	_size.min_value = 10
	_size.max_value = 10000
	_size.value = 128
	grid.add_child(_size)
	var l2 := Label.new()
	l2.text = "Output folder:"
	grid.add_child(l2)
	_dir = LineEdit.new()
	_dir.text = "res://world/cells"
	_dir.custom_minimum_size = Vector2(260, 0)
	grid.add_child(_dir)
	_far = CheckBox.new()
	_far.text = "Far cells (needs the HLOD add-on)"
	grid.add_child(_far)
	grid.add_child(Control.new())
	_nav = CheckBox.new()
	_nav.text = "Bake navigation per cell"
	grid.add_child(_nav)
	_dialog.add_child(grid)
	EditorInterface.get_base_control().add_child(_dialog)

	_report = AcceptDialog.new()
	_report.title = "World cells"
	EditorInterface.get_base_control().add_child(_report)
	EditorInterface.get_selection().selection_changed.connect(_update_visibility)


func _exit_tree() -> void:
	if EditorInterface.get_selection().selection_changed.is_connected(_update_visibility):
		EditorInterface.get_selection().selection_changed.disconnect(_update_visibility)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)
	_button.queue_free()
	_dialog.queue_free()
	_report.queue_free()


func _selected() -> Node3D:
	var nodes := EditorInterface.get_selection().get_selected_nodes()
	return nodes[0] as Node3D if nodes.size() == 1 else null


func _update_visibility() -> void:
	_button.visible = _selected() != null


func _split() -> void:
	var root := _selected()
	if root == null:
		return
	var options := Builder.Options.new()
	options.make_far = _far.button_pressed
	options.bake_navigation = _nav.button_pressed
	var result := Builder.build(root, _size.value, _dir.text, options)
	_report.dialog_text = "Saved %d cell scene(s) and %d far scene(s) to %s.\n\nThe source nodes were left in place. Hide or delete them, add a WorldStreamer with the same cell size and folder, and set its target." \
			% [result["cells"], result["far_cells"], _dir.text]
	if result["error"] != OK:
		_report.dialog_text += "\n\nSome cells failed to save (error %d)." % result["error"]
	_report.popup_centered()
	EditorInterface.get_resource_filesystem().scan()

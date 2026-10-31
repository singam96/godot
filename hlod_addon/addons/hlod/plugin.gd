@tool
extends EditorPlugin
## Adds a "Generate HLOD" button to the 3D editor toolbar when an HLODCluster is selected, and HLOD options to the
## import settings of 3D scenes.

const HLODCluster := preload("hlod_cluster_3d.gd")
const HLODImportPlugin := preload("hlod_import_plugin.gd")

var _button: Button
var _selected: Node3D
var _running: Node3D
var _old_mesh: Mesh

var _progress_dialog: AcceptDialog
var _progress_label: Label
var _progress_bar: ProgressBar
var _alert: AcceptDialog
var _import_plugin: EditorScenePostImportPlugin


func _enter_tree() -> void:
	_button = Button.new()
	_button.text = "Generate HLOD"
	_button.flat = true
	_button.icon = EditorInterface.get_base_control().get_theme_icon("Bake", "EditorIcons")
	_button.hide()
	_button.pressed.connect(_on_generate_pressed)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)

	_progress_dialog = AcceptDialog.new()
	_progress_dialog.title = "Generating HLOD Proxy"
	_progress_dialog.get_ok_button().hide()
	_progress_dialog.add_cancel_button("Cancel")
	_progress_dialog.canceled.connect(_on_cancel_pressed)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(380, 0)
	_progress_label = Label.new()
	box.add_child(_progress_label)
	_progress_bar = ProgressBar.new()
	_progress_bar.max_value = 100
	box.add_child(_progress_bar)
	_progress_dialog.add_child(box)
	add_child(_progress_dialog)

	_alert = AcceptDialog.new()
	_alert.title = "HLOD"
	add_child(_alert)

	_import_plugin = HLODImportPlugin.new()
	add_scene_post_import_plugin(_import_plugin)
	set_process(false)


func _exit_tree() -> void:
	remove_scene_post_import_plugin(_import_plugin)
	remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, _button)
	_button.queue_free()
	_progress_dialog.queue_free()
	_alert.queue_free()


func _handles(object: Object) -> bool:
	return object is HLODCluster


func _edit(object: Object) -> void:
	_selected = object as Node3D


func _make_visible(visible: bool) -> void:
	_button.visible = visible


func _on_generate_pressed() -> void:
	if _selected == null or _running != null:
		return
	_old_mesh = _selected.proxy_mesh
	# The heavy work runs on a thread while the dialog keeps the editor responsive and lets the user cancel.
	var err: Error = _selected.generate_proxy_async()
	if err != OK:
		_report(err)
		return
	_running = _selected
	_progress_bar.value = 0
	_progress_dialog.popup_centered()
	set_process(true)


func _on_cancel_pressed() -> void:
	if _running != null:
		_running.cancel_generation()


func _process(_delta: float) -> void:
	if _running == null:
		set_process(false)
		return
	_progress_bar.value = _running.get_generation_progress() * 100.0
	_progress_label.text = _running.get_generation_status()
	if _running.is_generating():
		return

	var cluster := _running
	_running = null
	set_process(false)
	_progress_dialog.hide()
	var err: Error = cluster.finish_generation()
	if err == OK:
		var undo_redo := get_undo_redo()
		undo_redo.create_action("Generate HLOD Proxy")
		undo_redo.add_do_property(cluster, "proxy_mesh", cluster.proxy_mesh)
		undo_redo.add_undo_property(cluster, "proxy_mesh", _old_mesh)
		undo_redo.commit_action(false)  # The proxy was already assigned by finish_generation().
	else:
		_report(err)


func _report(err: Error) -> void:
	match err:
		ERR_SKIP:
			pass  # Cancelled by the user.
		ERR_DOES_NOT_EXIST:
			_alert.dialog_text = "No meshes to merge.\nMake sure the HLODCluster has at least one visible MeshInstance3D or MultiMeshInstance3D descendant."
			_alert.popup_centered()
		_:
			_alert.dialog_text = "Could not generate the HLOD proxy mesh (error %d)." % err
			_alert.popup_centered()

@tool
class_name HLODCluster
extends Node3D
## Replaces a group of 3D meshes with a single simplified proxy mesh when viewed from far away (hierarchical level of detail).
##
## All [MeshInstance3D] and [MultiMeshInstance3D] descendants are merged into one simplified [member proxy_mesh]. When
## the camera is farther than [member switch_distance] from the cluster, the proxy is drawn and the descendants are
## hidden. When it is closer, the proxy is hidden and the descendants are drawn.
##
## The switch uses the visibility ranges of [GeometryInstance3D] together with the visibility parent system, so
## the proxy and all descendants switch together based on the distance to the cluster's origin. Place the origin
## of the cluster near the center of the objects it groups.
##
## Clusters can be nested to build several levels of detail. The detailed geometry can be stored in a separate scene
## with [method store_detail_scene] and is then streamed in when the camera comes close.

const HLODBuilder := preload("hlod_builder.gd")
const HLODTools := preload("hlod_tools.gd")

enum StreamState { UNLOADED, LOADING, LOADED, FAILED }

@export_group("Switching")
## The distance from the camera, in meters, at which the proxy replaces the descendants.
@export_range(0.01, 4096.0, 0.01, "or_greater", "suffix:m") var switch_distance := 50.0:
	set(value):
		switch_distance = maxf(value, 0.01)
		_update_proxy()
## The margin around [member switch_distance], in meters. Without fading it acts as hysteresis, which prevents
## flickering when the camera hovers around the switch distance. With fading, it is the width of the transition.
@export_range(0.0, 4096.0, 0.01, "or_greater", "suffix:m") var switch_margin := 5.0:
	set(value):
		switch_margin = maxf(value, 0.0)
		_update_proxy()
## How the transition is faded (Forward+ only). [b]Dependencies[/b] cross-fades the proxy and the descendants, which is
## the right choice for a smooth transition. [b]Self[/b] only fades the proxy, which is usually hidden by the geometry
## it replaces, so the descendants still disappear abruptly.
@export_enum("Disabled", "Self", "Dependencies") var fade_mode := 0:
	set(value):
		fade_mode = value
		_update_proxy()

@export_group("Proxy")
## The fraction of the triangles that the proxy keeps. The simplifier works in steps that halve the triangle count,
## so the step that is closest to this ratio is used. [code]1.0[/code] merges the meshes without simplifying them.
@export_range(0.01, 1.0, 0.01) var simplify_ratio := 0.25
## Bake simple materials into a shared texture atlas, so that different materials can be merged into one surface.
@export var merge_materials := true
## The size in pixels of the square that every material gets in the texture atlas.
@export_range(16, 2048, 1, "suffix:px") var atlas_cell_size := 128
## Drop the triangles that cannot be seen from outside, such as the walls inside of a building.
@export var remove_hidden_faces := true
## The simplified mesh drawn at a distance, in the local space of this node. Assign it manually or create it with [method generate_proxy].
@export var proxy_mesh: Mesh:
	set(value):
		proxy_mesh = value
		_update_proxy()
		_link_children()
		update_configuration_warnings()

@export_group("Streaming")
## The path of the scene with the detailed geometry that is streamed in when the camera is close, see
## [method store_detail_scene]. If empty, the children of this cluster are always part of the scene.
@export_file("*.tscn", "*.scn") var detail_scene_path := "":
	set(value):
		detail_scene_path = value
		_stream_state = StreamState.UNLOADED
		if is_inside_tree():
			set_process_internal(not detail_scene_path.is_empty() and not Engine.is_editor_hint())
## How far outside of [member switch_distance] (in meters) the camera must be before the detail scene starts loading.
@export_range(0.0, 4096.0, 0.1, "or_greater", "suffix:m") var stream_load_margin := 25.0
## How far outside of [member switch_distance] (in meters) the camera must be before the loaded detail scene is freed.
@export_range(0.0, 4096.0, 0.1, "or_greater", "suffix:m") var stream_unload_margin := 50.0

var _proxy: MeshInstance3D
var _linked_ids: Array[int] = []
var _relink_queued := false

var _stream_state := StreamState.UNLOADED
var _detail_id := 0
var _stream_timer := 0.0

var _builder: RefCounted
var _thread: Thread


func _init() -> void:
	_proxy = MeshInstance3D.new()
	add_child(_proxy, false, Node.INTERNAL_MODE_BACK)
	_update_proxy()


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_ENTER_TREE:
			_link_children()
			set_process_internal(not detail_scene_path.is_empty() and not Engine.is_editor_hint())
		NOTIFICATION_EXIT_TREE:
			_unlink_children()
			set_process_internal(false)
		NOTIFICATION_CHILD_ORDER_CHANGED:
			_queue_relink()
		NOTIFICATION_INTERNAL_PROCESS:
			# Checking a few times per second is plenty, because the load margin gives the load time to finish.
			_stream_timer += get_process_delta_time()
			if _stream_timer >= 0.2:
				_stream_timer = 0.0
				update_streaming()
		NOTIFICATION_PREDELETE:
			_abort_generation()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if proxy_mesh == null:
		warnings.append("No proxy mesh has been generated, so this cluster has no effect. Select the node and use the Generate HLOD button, or call generate_proxy().")
	return warnings


# --- Switching ---------------------------------------------------------------------------------------------------

func _update_proxy() -> void:
	if _proxy == null:
		return
	_proxy.mesh = proxy_mesh
	_proxy.visibility_range_begin = switch_distance
	_proxy.visibility_range_begin_margin = switch_margin
	_proxy.visibility_range_fade_mode = fade_mode as GeometryInstance3D.VisibilityRangeFadeMode


## Gathers the geometry that belongs to this cluster. Nested clusters manage their own geometry: their proxies are
## added to [param nested_proxies] if given, and their geometry is only reported when [param descend_nested] is set.
func _collect_geometry(node: Node, geometry: Array, nested_proxies: Array, descend_nested: bool) -> void:
	for child in node.get_children():
		if child is HLODCluster:
			nested_proxies.append(child._proxy)
			if descend_nested:
				_collect_geometry(child, geometry, nested_proxies, descend_nested)
			continue
		if child is GeometryInstance3D:
			geometry.append(child)
		_collect_geometry(child, geometry, nested_proxies, descend_nested)


## Returns the [MeshInstance3D] and [MultiMeshInstance3D] nodes that are merged into the proxy, including those of nested clusters.
func collect_mergeable_geometry() -> Array:
	var geometry := []
	_collect_geometry(self, geometry, [], true)
	return geometry


func _link_children() -> void:
	_unlink_children()
	if proxy_mesh == null or not is_inside_tree():
		return
	var geometry := []
	var nested_proxies := []
	_collect_geometry(self, geometry, nested_proxies, false)
	# The proxies of nested clusters follow this cluster's proxy too, which builds the hierarchy of detail levels.
	geometry.append_array(nested_proxies)
	for instance: GeometryInstance3D in geometry:
		if not instance.visibility_parent.is_empty():
			# The author already chose a visibility parent for this node.
			continue
		RenderingServer.instance_set_visibility_parent(instance.get_instance(), _proxy.get_instance())
		_linked_ids.append(instance.get_instance_id())


func _unlink_children() -> void:
	for id in _linked_ids:
		var instance := instance_from_id(id) as GeometryInstance3D
		if instance != null:
			RenderingServer.instance_set_visibility_parent(instance.get_instance(), RID())
	_linked_ids.clear()


func _queue_relink() -> void:
	if _relink_queued or not is_inside_tree():
		return
	_relink_queued = true
	update_children.call_deferred()


## Re-links the descendants of this cluster to the proxy. This happens automatically when direct children are
## added or removed. Call it manually after reparenting nodes deeper in the hierarchy.
func update_children() -> void:
	_relink_queued = false
	_link_children()


## Removes the [member proxy_mesh].
func clear_proxy() -> void:
	proxy_mesh = null


# --- Proxy generation --------------------------------------------------------------------------------------------

## Merges the visible [MeshInstance3D] and [MultiMeshInstance3D] descendants into a new [member proxy_mesh].
## Returns OK on success and ERR_DOES_NOT_EXIST if there is nothing to merge. Works outside of the scene tree too.
func generate_proxy() -> Error:
	var err := _start_generation(false)
	if err != OK:
		return err
	return finish_generation()


## Starts [method generate_proxy] on a thread and returns immediately. The scene is read before this method returns.
## Poll [method is_generating], show [method get_generation_progress] and [method get_generation_status], and
## finish with [method finish_generation]. Returns ERR_BUSY if a generation is already running.
func generate_proxy_async() -> Error:
	return _start_generation(true)


func _start_generation(threaded: bool) -> Error:
	if _builder != null:
		return ERR_BUSY
	var builder := HLODBuilder.new()
	builder.simplify_ratio = simplify_ratio
	builder.merge_materials = merge_materials
	builder.remove_hidden_faces = remove_hidden_faces
	builder.atlas_cell_size = atlas_cell_size
	var err := builder.prepare(self)
	if err != OK:
		return err
	_builder = builder
	if threaded:
		_thread = Thread.new()
		_thread.start(builder.run)
	else:
		builder.run()
	return OK


## Returns true while the thread started with [method generate_proxy_async] is still busy.
func is_generating() -> bool:
	return _builder != null and not _builder.is_done()


## Returns how far the generation has come, from 0.0 to 1.0.
func get_generation_progress() -> float:
	return _builder.get_progress() if _builder != null else 0.0


## Returns a short description of the step that the generation is working on.
func get_generation_status() -> String:
	if _builder == null:
		return ""
	match _builder.get_stage():
		HLODBuilder.Stage.ATLAS:
			return "Baking the material atlas..."
		HLODBuilder.Stage.MERGE:
			return "Merging meshes..."
		HLODBuilder.Stage.HIDDEN_FACES:
			return "Removing hidden faces..."
		HLODBuilder.Stage.SIMPLIFY:
			return "Simplifying..."
		_:
			return "Finishing..."


## Asks a running generation to stop. [method finish_generation] then returns ERR_SKIP.
func cancel_generation() -> void:
	if _builder != null:
		_builder.cancel()


## Waits until the generation is done and assigns the result to [member proxy_mesh]. Returns OK on success,
## ERR_SKIP if it was cancelled, ERR_DOES_NOT_EXIST if nothing was left to merge and ERR_UNCONFIGURED if no
## generation was started.
func finish_generation() -> Error:
	if _builder == null:
		return ERR_UNCONFIGURED
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	var builder := _builder
	_builder = null
	if builder.error != OK:
		return builder.error
	proxy_mesh = builder.build_mesh()
	return OK


func _abort_generation() -> void:
	if _builder != null:
		_builder.cancel()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null
	_builder = null


# --- Grids and streaming -----------------------------------------------------------------------------------------

## Builds a hierarchy of detail levels for a large number of objects. The direct [Node3D] children are sorted into a
## grid with cells of [param cell_size] meters and moved into one nested [HLODCluster] per occupied cell, keeping
## their place. Each cell uses half of this cluster's [member switch_distance] and [member switch_margin] and the
## same settings. A proxy is then generated for every cell and for this cluster. This changes the node tree and
## can't be undone with the editor's undo history. Choose a [param cell_size] smaller than [member switch_distance].
func build_grid(cell_size: float) -> Error:
	if cell_size <= 0.0:
		return ERR_INVALID_PARAMETER
	var cells := {}
	var cell_order: Array[Vector3i] = []
	for child in get_children():
		var child_3d := child as Node3D
		if child_3d == null:
			continue
		var cell := Vector3i((child_3d.position / cell_size).floor())
		if not cells.has(cell):
			cells[cell] = []
			cell_order.append(cell)
		cells[cell].append(child_3d)
	if cells.is_empty():
		return ERR_DOES_NOT_EXIST

	# A cluster that is the root of its own scene (e.g. while importing) owns the nodes below it.
	var scene_owner := owner
	if scene_owner == null and (get_parent() == null or (is_inside_tree() and get_tree().edited_scene_root == self)):
		scene_owner = self

	for cell in cell_order:
		var center := (Vector3(cell) + Vector3(0.5, 0.5, 0.5)) * cell_size
		var cell_cluster := HLODCluster.new()
		cell_cluster.name = "Cell_%d_%d_%d" % [cell.x, cell.y, cell.z]
		cell_cluster.switch_distance = switch_distance * 0.5
		cell_cluster.switch_margin = switch_margin * 0.5
		cell_cluster.fade_mode = fade_mode
		cell_cluster.simplify_ratio = simplify_ratio
		cell_cluster.merge_materials = merge_materials
		cell_cluster.atlas_cell_size = atlas_cell_size
		cell_cluster.remove_hidden_faces = remove_hidden_faces
		cell_cluster.position = center
		add_child(cell_cluster, true)
		if scene_owner != null:
			cell_cluster.owner = scene_owner

		# The cell is a pure translation, so the objects keep their place by subtracting its offset.
		for child_3d: Node3D in cells[cell]:
			var position := child_3d.position
			HLODTools.move_node_keeping_owner(child_3d, cell_cluster)
			child_3d.position = position - center

		var err := cell_cluster.generate_proxy()
		if err != OK:
			return err
	return generate_proxy()


## Moves the children of this cluster into a new scene saved at [param path] and sets [member detail_scene_path]
## to it. If there is no [member proxy_mesh] yet, one is generated first, so the cluster keeps rendering something
## while the detail scene is not loaded. The stored scene has a [Node3D] root named "Detail", which is instantiated as
## a child of this cluster when it is streamed in. To edit the detailed geometry later, open the stored scene.
func store_detail_scene(path: String) -> Error:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	if proxy_mesh == null:
		var generated := generate_proxy()
		if generated != OK:
			return generated

	var scene_owner := owner if owner != null else self
	var holder := Node3D.new()
	holder.name = "Detail"
	var moved: Array[Dictionary] = []
	for child in get_children():
		var owned: Array[Node] = []
		var to_visit: Array[Node] = [child]
		while not to_visit.is_empty():
			var current: Node = to_visit.pop_back()
			if current == child or current.owner == scene_owner or current.owner == null:
				owned.append(current)
			for grandchild in current.get_children():
				to_visit.append(grandchild)
		remove_child(child)
		holder.add_child(child)
		for node in owned:
			node.owner = holder
		moved.append({"node": child, "owned": owned})

	var packed := PackedScene.new()
	var err := packed.pack(holder)
	if err == OK:
		err = ResourceSaver.save(packed, path)
	if err != OK:
		# Put everything back where it was.
		for entry in moved:
			holder.remove_child(entry.node)
			add_child(entry.node)
			for node: Node in entry.owned:
				node.owner = null if scene_owner == self else scene_owner
		holder.free()
		return err

	holder.free()
	detail_scene_path = path
	return OK


## Checks the distance of the current [Camera3D] and starts loading or frees the detail scene if needed. This is
## called automatically several times per second while [member detail_scene_path] is set, and does nothing in the editor.
func update_streaming() -> void:
	if detail_scene_path.is_empty() or not is_inside_tree() or Engine.is_editor_hint():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var distance := camera.global_position.distance_to(global_position)
	var detail_distance := switch_distance + switch_margin

	match _stream_state:
		StreamState.UNLOADED:
			if distance < detail_distance + stream_load_margin:
				if ResourceLoader.load_threaded_request(detail_scene_path, "PackedScene") == OK:
					_stream_state = StreamState.LOADING
				else:
					push_error("HLODCluster could not start loading the detail scene '%s'." % detail_scene_path)
					_stream_state = StreamState.FAILED
		StreamState.LOADING:
			var status := ResourceLoader.load_threaded_get_status(detail_scene_path)
			if status == ResourceLoader.THREAD_LOAD_LOADED:
				var packed := ResourceLoader.load_threaded_get(detail_scene_path) as PackedScene
				var detail := packed.instantiate() if packed != null else null
				if detail != null:
					add_child(detail)
					_detail_id = detail.get_instance_id()
					_stream_state = StreamState.LOADED
				else:
					push_error("HLODCluster could not instantiate the detail scene '%s'." % detail_scene_path)
					_stream_state = StreamState.FAILED
			elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
				push_error("HLODCluster failed to load the detail scene '%s'." % detail_scene_path)
				_stream_state = StreamState.FAILED
		StreamState.LOADED:
			if distance > detail_distance + stream_unload_margin:
				var detail := instance_from_id(_detail_id) as Node
				if detail != null:
					detail.queue_free()
				_detail_id = 0
				_stream_state = StreamState.UNLOADED

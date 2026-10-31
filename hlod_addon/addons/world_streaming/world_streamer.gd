@tool
class_name WorldStreamer
extends Node3D
## Streams a world that is split into square cells (see world_cell_builder.gd). Cells are scenes named
## "cell_<x>_<z>.tscn" (the detail version) and "far_<x>_<z>.tscn" or ".scn" (an optional cheap version, for example
## an HLOD proxy only) in [member cells_dir]. They are authored in world coordinates relative to this node, loaded in
## threads when the [member target] comes near, added within a per-frame time budget, and freed again when it leaves.
##
## Put this node at the origin of your world (below the root that an origin shifter moves, if you use one): the
## distances are measured from this node's own space, so the streamer follows when the world is shifted.

signal cell_loaded(coord: Vector2i, cell: Node3D)
signal cell_unloaded(coord: Vector2i)
## Emitted when every cell within [member required_radius] of the target is in place. Use it to release a player that
## waits on the ground, or to hide a loading screen.
signal required_area_ready
## Emitted when the target moves to cells that are not loaded yet inside [member required_radius].
signal required_area_lost

enum Layer { DETAIL, FAR }
enum State { LOADING, PREWARM, LOADED }

## The node whose position streams the world. If empty, the current camera is used.
@export var target: NodePath
@export_dir var cells_dir := "res://world/cells"
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:m") var cell_size := 128.0
@export_group("Distances")
## Detail cells are loaded when the target is closer than this to the cell center.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var load_radius := 400.0
## And freed when it is farther than this. Keep it larger than the load radius, so cells don't flicker at the edge.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var unload_radius := 500.0
## Far cells (optional) are loaded beyond the detail radius up to this distance. 0 disables them.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var far_load_radius := 0.0
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var far_unload_radius := 0.0
## Cells within this distance count for [signal required_area_ready] and [method is_position_loaded].
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var required_radius := 128.0
@export_group("Budget")
## Time spent per frame on adding and freeing cells. A cell that takes longer on its own still goes through in one
## piece, so keep cells small.
@export_range(0.1, 50.0, 0.1, "suffix:ms") var frame_budget_ms := 2.0
@export_range(1, 16) var max_parallel_requests := 4
@export_range(0.02, 5.0, 0.01, "suffix:s") var update_interval := 0.25
## Renders every new cell once, tiny and off-screen, before it is shown. This lets the renderer compile what the cell
## needs ahead of time and avoids a hitch the first time it is drawn.
@export var prewarm := false

var _cells := {}  ## "layer:x:z" -> {coord, layer, path, state, node}
var _exists := {}  ## path -> bool
var _timer := 0.0
var _last_cell := Vector2i(2147483647, 2147483647)
var _ready_state := false
var _prewarm_viewport: SubViewport
var _prewarm_camera: Camera3D
var _pending_free: Array[Node] = []
var _replan := false  ## A cell arrived; check at once whether it replaces another layer.
var _abandoned: Array[String] = []  ## Finished requests nobody wants any more.


func _ready() -> void:
	_timer = update_interval  # Update on the first frame.


func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_timer += delta
	if _timer >= update_interval:
		_timer = 0.0
		update_now()
	_pump()
	if _replan:
		_replan = false
		update_now()
	var pos = _target_position()
	if pos != null:
		_update_ready(pos)


## Re-evaluates which cells should be loaded. Called automatically every [member update_interval]; call it yourself
## after teleporting the target.
func update_now() -> void:
	var pos = _target_position()
	if pos == null:
		return
	_plan(pos)
	_update_ready(pos)


func _target_position() -> Variant:
	var node: Node3D = null
	if not target.is_empty():
		node = get_node_or_null(target) as Node3D
	elif is_inside_tree():
		node = get_viewport().get_camera_3d()
	if node == null or not is_inside_tree() or not node.is_inside_tree():
		return null
	return to_local(node.global_position)


func _cell_center(coord: Vector2i) -> Vector2:
	return (Vector2(coord) + Vector2(0.5, 0.5)) * cell_size


static func _key(layer: int, coord: Vector2i) -> String:
	return "%d:%d:%d" % [layer, coord.x, coord.y]


func _cell_path(layer: int, coord: Vector2i) -> String:
	var prefix := "cell" if layer == Layer.DETAIL else "far"
	var base := "%s/%s_%d_%d" % [cells_dir, prefix, coord.x, coord.y]
	for ext in [".tscn", ".scn"]:
		var path: String = base + ext
		if not _exists.has(path):
			_exists[path] = ResourceLoader.exists(path)
		if _exists[path]:
			return path
	return ""


func _plan(pos: Vector3) -> void:
	var p := Vector2(pos.x, pos.z)
	var outer := maxf(maxf(unload_radius, far_unload_radius), maxf(load_radius, far_load_radius))
	var span := int(ceil(outer / cell_size)) + 1
	var base := Vector2i((p / cell_size).floor())
	var wanted_requests: Array = []

	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var coord := base + Vector2i(dx, dz)
			var dist := p.distance_to(_cell_center(coord))
			var has_detail := _cells.has(_key(Layer.DETAIL, coord))
			var has_far := _cells.has(_key(Layer.FAR, coord))
			var layer := -1
			if dist < load_radius or (has_detail and dist < unload_radius):
				layer = Layer.DETAIL
			elif far_load_radius > 0.0 and (dist < far_load_radius or (has_far and dist < far_unload_radius)):
				layer = Layer.FAR
			if layer == -1:
				continue
			var key := _key(layer, coord)
			if _cells.has(key):
				continue
			var path := _cell_path(layer, coord)
			if path != "":
				wanted_requests.append({"key": key, "coord": coord, "layer": layer, "path": path, "dist": dist})

	# Closest first.
	wanted_requests.sort_custom(func(a, b): return a["dist"] < b["dist"])
	for request in wanted_requests:
		_cells[request["key"]] = {"coord": request["coord"], "layer": request["layer"], "path": request["path"],
				"state": -1, "node": null}  # -1: wanted, not requested yet

	# Free cells that are out of range, or whose other layer has taken over.
	for key in _cells.keys():
		var cell: Dictionary = _cells[key]
		var coord: Vector2i = cell["coord"]
		var dist := p.distance_to(_cell_center(coord))
		var keep := true
		if cell["layer"] == Layer.DETAIL:
			keep = dist < unload_radius
		else:
			keep = far_load_radius > 0.0 and dist < far_unload_radius
			# The detail version replaces the far one once it is in place.
			var detail: Dictionary = _cells.get(_key(Layer.DETAIL, coord), {})
			if not detail.is_empty() and detail["state"] == State.LOADED and dist < unload_radius:
				keep = false
		if cell["layer"] == Layer.DETAIL and not keep and far_load_radius > 0.0 and dist < far_load_radius:
			# Going far: keep the detail version until the far one is in place, so there is no gap.
			var far: Dictionary = _cells.get(_key(Layer.FAR, coord), {})
			if _cell_path(Layer.FAR, coord) != "" and (far.is_empty() or far["state"] != State.LOADED):
				keep = true
		if not keep:
			_drop(key)


func _drop(key: String) -> void:
	var cell: Dictionary = _cells[key]
	_cells.erase(key)
	if cell["state"] == State.LOADING:
		# A running request can't be cancelled; its result is collected and thrown away.
		var path: String = cell["path"]
		if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_LOADED:
			ResourceLoader.load_threaded_get(path)
		else:
			_abandoned.append(path)
	elif cell["node"] != null and is_instance_valid(cell["node"]):
		_pending_free.append(cell["node"])


func _pump() -> void:
	var start := Time.get_ticks_usec()
	var budget := int(frame_budget_ms * 1000.0)

	# Collect results nobody wants any more.
	for i in range(_abandoned.size() - 1, -1, -1):
		var status := ResourceLoader.load_threaded_get_status(_abandoned[i])
		if status != ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			if status == ResourceLoader.THREAD_LOAD_LOADED:
				ResourceLoader.load_threaded_get(_abandoned[i])
			_abandoned.remove_at(i)

	# Free, within budget.
	while not _pending_free.is_empty() and Time.get_ticks_usec() - start < budget:
		var node: Node = _pending_free.pop_back()
		if is_instance_valid(node):
			var coord: Vector2i = node.get_meta("world_streaming_coord", Vector2i.ZERO)
			node.queue_free()
			cell_unloaded.emit(coord)

	# Prewarm finishing and loading results, closest cell first.
	var loading: Array = []
	var requested := 0
	var queued: Array = []
	var p = _target_position()
	for key in _cells:
		var cell: Dictionary = _cells[key]
		match cell["state"]:
			-1:
				queued.append(cell)
			State.LOADING:
				requested += 1
				loading.append(cell)
			State.PREWARM:
				if Engine.get_process_frames() - cell["frame"] >= 2:
					loading.append(cell)

	for cell in loading:
		if Time.get_ticks_usec() - start >= budget:
			break
		if cell["state"] == State.PREWARM:
			_finish_prewarm(cell)
			continue
		var status := ResourceLoader.load_threaded_get_status(cell["path"])
		if status == ResourceLoader.THREAD_LOAD_LOADED:
			var packed := ResourceLoader.load_threaded_get(cell["path"]) as PackedScene
			var node := packed.instantiate() as Node3D if packed != null else null
			if node == null:
				push_error("WorldStreamer could not instantiate '%s'." % cell["path"])
				cell["state"] = State.LOADED
				continue
			node.set_meta("world_streaming_coord", cell["coord"])
			if prewarm:
				_start_prewarm(cell, node)
			else:
				_place(cell, node)
		elif status == ResourceLoader.THREAD_LOAD_FAILED or status == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("WorldStreamer failed to load '%s'." % cell["path"])
			cell["state"] = State.LOADED

	# Start new requests, closest first.
	if p != null:
		var origin := Vector2(p.x, p.z)
		queued.sort_custom(func(a, b):
			return origin.distance_squared_to(_cell_center(a["coord"])) < origin.distance_squared_to(_cell_center(b["coord"])))
	for cell in queued:
		if requested >= max_parallel_requests:
			break
		if ResourceLoader.load_threaded_request(cell["path"], "PackedScene") == OK:
			cell["state"] = State.LOADING
			requested += 1
		else:
			push_error("WorldStreamer could not request '%s'." % cell["path"])
			cell["state"] = State.LOADED


func _place(cell: Dictionary, node: Node3D) -> void:
	cell["node"] = node
	cell["state"] = State.LOADED
	add_child(node)
	_replan = true
	cell_loaded.emit(cell["coord"], node)


func _start_prewarm(cell: Dictionary, node: Node3D) -> void:
	if _prewarm_viewport == null:
		_prewarm_viewport = SubViewport.new()
		_prewarm_viewport.size = Vector2i(4, 4)
		_prewarm_viewport.own_world_3d = true
		_prewarm_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(_prewarm_viewport, false, Node.INTERNAL_MODE_BACK)
		_prewarm_camera = Camera3D.new()
		_prewarm_camera.fov = 170.0
		_prewarm_camera.far = 1.0e7
		_prewarm_viewport.add_child(_prewarm_camera)
	cell["node"] = node
	cell["state"] = State.PREWARM
	cell["frame"] = Engine.get_process_frames()
	_prewarm_viewport.add_child(node)
	var center := Vector3(_cell_center(cell["coord"]).x, 0.0, _cell_center(cell["coord"]).y)
	_prewarm_camera.position = center + Vector3(0, cell_size, 0)
	_prewarm_camera.look_at(center, Vector3.FORWARD)


func _finish_prewarm(cell: Dictionary) -> void:
	var node: Node3D = cell["node"]
	if is_instance_valid(node):
		node.get_parent().remove_child(node)
		_place(cell, node)
	else:
		cell["state"] = State.LOADED


func _update_ready(pos: Vector3) -> void:
	var now := are_required_cells_loaded()
	if now and not _ready_state:
		_ready_state = true
		required_area_ready.emit()
	elif not now and _ready_state:
		_ready_state = false
		required_area_lost.emit()


## True if the cell around [param position] (in this node's space) has its detail version loaded, or has none.
func is_position_loaded(position: Vector3) -> bool:
	var coord := Vector2i((Vector2(position.x, position.z) / cell_size).floor())
	if _cell_path(Layer.DETAIL, coord) == "":
		return true
	var cell: Dictionary = _cells.get(_key(Layer.DETAIL, coord), {})
	return not cell.is_empty() and cell["state"] == State.LOADED


## True if all cells within [member required_radius] of the target are loaded.
func are_required_cells_loaded() -> bool:
	var pos = _target_position()
	if pos == null:
		return false
	var p := Vector2(pos.x, pos.z)
	var span := int(ceil(required_radius / cell_size)) + 1
	var base := Vector2i((p / cell_size).floor())
	for dz in range(-span, span + 1):
		for dx in range(-span, span + 1):
			var coord := base + Vector2i(dx, dz)
			# A cell counts if the required circle reaches into it.
			if p.distance_to(_cell_center(coord)) >= required_radius + cell_size * 0.5:
				continue
			if _cell_path(Layer.DETAIL, coord) == "":
				continue
			var cell: Dictionary = _cells.get(_key(Layer.DETAIL, coord), {})
			if cell.is_empty() or cell["state"] != State.LOADED:
				return false
	return true


## Number of cells that are loaded, per layer: {"detail": n, "far": n}.
func get_loaded_counts() -> Dictionary:
	var counts := {"detail": 0, "far": 0}
	for key in _cells:
		var cell: Dictionary = _cells[key]
		if cell["state"] == State.LOADED and cell["node"] != null:
			counts["detail" if cell["layer"] == Layer.DETAIL else "far"] += 1
	return counts


## Returns the loaded cell node at [param coord] for the given layer, or null.
func get_cell(coord: Vector2i, layer := Layer.DETAIL) -> Node3D:
	var cell: Dictionary = _cells.get(_key(layer, coord), {})
	if cell.is_empty() or cell["state"] != State.LOADED:
		return null
	return cell["node"]


## True while any cell is still being requested, instantiated or freed.
func is_busy() -> bool:
	if not _pending_free.is_empty():
		return true
	for key in _cells:
		if _cells[key]["state"] != State.LOADED:
			return true
	return false

@tool
class_name WorldGroundGate
extends Node
## Keeps a body from falling through ground that has not been streamed in yet. While the [WorldStreamer] says the
## area around its target isn't ready, the [member body] is frozen; it is released when the area is ready.
## A CharacterBody3D is paused (its process modes are disabled), a RigidBody3D is frozen.

@export var streamer: NodePath
@export var body: NodePath
## Start frozen, until the streamer reports the area ready for the first time.
@export var start_frozen := true

var _streamer: WorldStreamer
var _body: Node
var _frozen := false


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_streamer = get_node_or_null(streamer) as WorldStreamer
	_body = get_node_or_null(body)
	if _streamer == null or _body == null:
		push_warning("WorldGroundGate needs a streamer and a body.")
		return
	_streamer.required_area_ready.connect(func(): _set_frozen(false))
	_streamer.required_area_lost.connect(func(): _set_frozen(true))
	if start_frozen and not _streamer.are_required_cells_loaded():
		_set_frozen(true)


func is_frozen() -> bool:
	return _frozen


func _set_frozen(value: bool) -> void:
	if _frozen == value or _body == null:
		return
	_frozen = value
	if _body is RigidBody3D:
		_body.freeze = value
	else:
		_body.process_mode = Node.PROCESS_MODE_DISABLED if value else Node.PROCESS_MODE_INHERIT

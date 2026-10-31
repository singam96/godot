@tool
class_name OriginShifter
extends Node
## Floating point numbers lose precision far from zero: a few kilometers out, meshes jitter, physics gets noisy and
## shadows crawl. This node moves the whole world back whenever the [member target] gets too far from the origin, and
## remembers by how much, so you can still ask for the true ("absolute") position of anything.
##
## Put your world below one [Node3D] ([member world_root]); the player may be below it as well, or listed in
## [member extra_nodes]. Anything that is a direct child of the world root is moved; everything below those moves along.
## A WorldStreamer below the world root keeps working untouched, because its cells move with it.

## Emitted after the world was moved by [param shift] (the vector every node was moved by).
signal origin_shifted(shift: Vector3)

@export var target: NodePath
@export var world_root: NodePath
## Nodes outside the world root that should be moved as well (a camera rig, for example).
@export var extra_nodes: Array[NodePath] = []
## Shift when the target is farther than this from the origin on the X/Z plane.
@export_range(10.0, 100000.0, 1.0, "or_greater", "suffix:m") var threshold := 2000.0
## Shifts are multiples of this, so repeating textures and patterns that depend on world position don't jump.
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:m") var snap := 500.0
## Also shift on the Y axis (for worlds that are tall as well as wide).
@export var shift_vertical := false

## How far the origin has moved from the true origin, as 64-bit floats.
var offset_x := 0.0
var offset_y := 0.0
var offset_z := 0.0

var _target: Node3D
var _world: Node3D


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not _resolve():
		push_warning("OriginShifter needs a target and a world root.")


func _resolve() -> bool:
	if _target == null or not is_instance_valid(_target):
		_target = get_node_or_null(target) as Node3D
	if _world == null or not is_instance_valid(_world):
		_world = get_node_or_null(world_root) as Node3D
	return _target != null and _world != null


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	check()


## Shifts the world if the target is out of range. Called every physics frame; call it yourself after a teleport.
func check() -> void:
	if not _resolve() or not _target.is_inside_tree():
		return
	var p := _target.global_position
	var limit := threshold
	if absf(p.x) <= limit and absf(p.z) <= limit and (not shift_vertical or absf(p.y) <= limit):
		return
	var shift := Vector3(-roundf(p.x / snap) * snap, 0.0, -roundf(p.z / snap) * snap)
	if shift_vertical:
		shift.y = -roundf(p.y / snap) * snap
	shift_by(shift)


## Moves the world by [param shift] (all nodes by the same vector) and updates the absolute offset.
func shift_by(shift: Vector3) -> void:
	if shift == Vector3.ZERO or not _resolve():
		return
	for child in _world.get_children():
		_move(child, shift)
	for path in extra_nodes:
		var node := get_node_or_null(path)
		if node != null and node.get_parent() != _world:
			_move(node, shift)
	# The world moved by `shift`, so the true origin is now at `-shift` relative to the local origin.
	offset_x -= shift.x
	offset_y -= shift.y
	offset_z -= shift.z
	origin_shifted.emit(shift)


func _move(node: Node, shift: Vector3) -> void:
	var node3d := node as Node3D
	if node3d == null:
		return
	node3d.global_position += shift
	if node3d is RigidBody3D or node3d is CharacterBody3D:
		node3d.reset_physics_interpolation()


## The true position of [param local] (a position in the current, shifted world) as [x, y, z] doubles.
func to_absolute(local: Vector3) -> PackedFloat64Array:
	return PackedFloat64Array([local.x + offset_x, local.y + offset_y, local.z + offset_z])


## The position in the current world of an absolute position given as [x, y, z].
func to_local_position(absolute: PackedFloat64Array) -> Vector3:
	return Vector3(absolute[0] - offset_x, absolute[1] - offset_y, absolute[2] - offset_z)


## The true position of a node, as [x, y, z] doubles.
func get_absolute_position(node: Node3D) -> PackedFloat64Array:
	return to_absolute(node.global_position)

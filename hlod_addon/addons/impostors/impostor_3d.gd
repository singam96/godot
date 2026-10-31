@tool
class_name Impostor3D
extends MeshInstance3D
## Draws an [ImpostorData] as a camera-facing quad beyond [member switch_distance]. Give it a [member target] and the
## real object is hidden beyond the same distance, so exactly one of them is drawn.

@export var data: ImpostorData:
	set(value):
		data = value
		_update()

@export_group("Switching")
## Beyond this distance the impostor is shown instead of the target.
@export_range(0.01, 4096.0, 0.01, "or_greater", "suffix:m") var switch_distance := 150.0:
	set(value):
		switch_distance = value
		_update()
## Hysteresis around the switch distance. With a fade mode it is the distance over which the two cross-fade.
@export_range(0.0, 4096.0, 0.01, "or_greater", "suffix:m") var switch_margin := 10.0:
	set(value):
		switch_margin = value
		_update()
@export_enum("Disabled", "Self", "Dependencies") var fade_mode := 0:
	set(value):
		fade_mode = value
		_update()
## The real object (any node with meshes below it, such as an HLODCluster) that this impostor replaces in the distance.
@export var target: NodePath:
	set(value):
		_reset_target()
		target = value
		_update()


func _init() -> void:
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _enter_tree() -> void:
	_update()


func _exit_tree() -> void:
	_reset_target()


func _update() -> void:
	if data == null:
		mesh = null
		return
	mesh = data.create_mesh()
	visibility_range_begin = switch_distance
	visibility_range_begin_margin = switch_margin
	visibility_range_fade_mode = fade_mode as GeometryInstance3D.VisibilityRangeFadeMode
	_apply_to_target()


func _target_geometry() -> Array[GeometryInstance3D]:
	var out: Array[GeometryInstance3D] = []
	if not is_inside_tree() or target.is_empty():
		return out
	var node := get_node_or_null(target)
	if node == null or node == self:
		return out
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var n := stack.pop_back()
		if n is GeometryInstance3D and n != self and not (n is Impostor3D):
			out.append(n)
		# Include internal children: an HLODCluster keeps its proxy there.
		stack.append_array(n.get_children(true))
	return out


func _apply_to_target() -> void:
	for g in _target_geometry():
		g.visibility_range_end = switch_distance
		g.visibility_range_end_margin = switch_margin
		g.visibility_range_fade_mode = fade_mode as GeometryInstance3D.VisibilityRangeFadeMode


func _reset_target() -> void:
	for g in _target_geometry():
		g.visibility_range_end = 0.0
		g.visibility_range_end_margin = 0.0

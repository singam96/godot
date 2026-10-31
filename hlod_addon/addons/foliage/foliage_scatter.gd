@tool
class_name FoliageScatter
extends Node3D
## Scatters copies of a mesh over a rectangle, in chunks. Every chunk has a MultiMesh with the real mesh that is shown
## up to [member near_distance], and (optionally) a MultiMesh with the [ImpostorData] shown from there to
## [member max_distance]. Chunks outside the view are culled, so the cost follows what you see.
##
## Placement is a jittered grid, seeded per chunk: even spacing, no clumps, and the same result every time.
## Where the ground is comes from [member ground_sampler] (or physics, see [member use_physics_ground]).

const META_KEY := "foliage_generated"

@export var mesh: Mesh
## Optional. Used for [member near_distance] to [member max_distance].
@export var impostor: ImpostorData
@export_group("Area")
## Rectangle on the node's X/Z plane, centered on the node.
@export var area_size := Vector2(200.0, 200.0)
## Instances per square meter.
@export_range(0.0001, 10.0, 0.0001, "or_greater") var density := 0.02
@export var random_seed := 1
@export_range(5.0, 1000.0, 1.0, "or_greater", "suffix:m") var chunk_size := 50.0
@export_group("Instances")
@export var min_scale := 0.8
@export var max_scale := 1.2
@export var random_yaw := true
## How much instances lean towards the ground's normal: 0 stands straight, 1 follows the slope.
@export_range(0.0, 1.0) var align_to_normal := 0.0
@export_group("Distances")
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:m") var near_distance := 120.0
## Instances are culled beyond this. 0 never culls them.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var max_distance := 600.0
@export_range(0.0, 1000.0, 0.5, "or_greater", "suffix:m") var margin := 8.0
@export_enum("Disabled", "Self", "Dependencies") var fade_mode := 0
@export var cast_shadows := true
@export_group("Ground")
## Place instances on the first physics body found below. If off, [member ground_sampler] is used, or y = 0.
@export var use_physics_ground := false
@export_flags_3d_physics var ground_mask := 1
@export_group("Generation")
## Generate when the game starts, if nothing was generated and saved into the scene before.
@export var generate_on_ready := true
## When generating in the editor, keep the result in the scene file. Turn it off to generate at run time only.
@export var save_in_scene := true

## Optional. Called with the local position Vector2(x, z). Return null to leave the spot empty, a float for the
## ground height, or a Dictionary {"height": float, "normal": Vector3}.
var ground_sampler := Callable()
## Optional. Called with Vector2(x, z), returns 0.0 to 1.0: the chance that a spot gets an instance.
var density_sampler := Callable()

var _count := 0


func _ready() -> void:
	if Engine.is_editor_hint() or not generate_on_ready:
		return
	if not _has_generated():
		generate()


func _has_generated() -> bool:
	for child in get_children():
		if child.has_meta(META_KEY):
			return true
	return false


## Number of instances created by the last [method generate].
func get_instance_count() -> int:
	return _count


## Removes everything that [method generate] made.
func clear() -> void:
	for child in get_children():
		if child.has_meta(META_KEY):
			remove_child(child)
			child.free()
	_count = 0


## Builds the chunks. Returns the number of instances.
func generate() -> int:
	clear()
	if mesh == null or density <= 0.0 or area_size.x <= 0.0 or area_size.y <= 0.0:
		return 0
	var half := area_size * 0.5
	var first := Vector2i((Vector2(-half.x, -half.y) / chunk_size).floor())
	var last := Vector2i((Vector2(half.x, half.y) / chunk_size).floor())
	var owner_node: Node = null
	if Engine.is_editor_hint() and save_in_scene and is_inside_tree():
		owner_node = get_tree().edited_scene_root

	for cz in range(first.y, last.y + 1):
		for cx in range(first.x, last.x + 1):
			var transforms := scatter_chunk(Vector2i(cx, cz))
			if transforms.is_empty():
				continue
			var chunk := Node3D.new()
			chunk.name = "Chunk_%d_%d" % [cx, cz]
			chunk.set_meta(META_KEY, true)
			add_child(chunk)
			chunk.add_child(_make_near(transforms))
			if impostor != null:
				chunk.add_child(_make_far(transforms))
			if owner_node != null:
				chunk.owner = owner_node
				for part in chunk.get_children():
					part.owner = owner_node
			_count += transforms.size()
	return _count


## Returns the transforms of the instances in one chunk, in the node's space, without creating any nodes.
func scatter_chunk(chunk: Vector2i) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var half := area_size * 0.5
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(random_seed, chunk.x, chunk.y))
	var spacing := 1.0 / sqrt(density)
	var origin := Vector2(chunk) * chunk_size
	var steps := int(ceil(chunk_size / spacing))
	for iz in steps:
		for ix in steps:
			# Jitter inside the grid cell; the random numbers are always drawn, so skipped spots don't shift others.
			var jx := rng.randf()
			var jz := rng.randf()
			var yaw := rng.randf() * TAU
			var scale_roll := rng.randf()
			var chance := rng.randf()
			var p := origin + Vector2((ix + jx) * spacing, (iz + jz) * spacing)
			if p.x >= origin.x + chunk_size or p.y >= origin.y + chunk_size:
				continue
			if absf(p.x) > half.x or absf(p.y) > half.y:
				continue
			if density_sampler.is_valid() and chance > float(density_sampler.call(p)):
				continue
			var ground = _ground_at(p)
			if ground == null:
				continue
			var normal: Vector3 = ground["normal"]
			var basis := Basis()
			if align_to_normal > 0.0:
				var tilt_axis := Vector3.UP.cross(normal)
				if tilt_axis.length_squared() > 0.000001:
					basis = Basis(tilt_axis.normalized(), Vector3.UP.angle_to(normal) * align_to_normal)
			if random_yaw:
				basis = basis * Basis(Vector3.UP, yaw)
			var s := lerpf(min_scale, max_scale, scale_roll)
			basis = basis.scaled(Vector3.ONE * s)
			out.append(Transform3D(basis, Vector3(p.x, ground["height"], p.y)))
	return out


## Returns {"height", "normal"} or null.
func _ground_at(p: Vector2) -> Variant:
	if ground_sampler.is_valid():
		var result = ground_sampler.call(p)
		if result == null:
			return null
		if result is Dictionary:
			return {"height": float(result["height"]), "normal": result.get("normal", Vector3.UP)}
		return {"height": float(result), "normal": Vector3.UP}
	if use_physics_ground and is_inside_tree():
		var space := get_world_3d().direct_space_state
		var from := to_global(Vector3(p.x, 10000.0, p.y))
		var to := to_global(Vector3(p.x, -10000.0, p.y))
		var query := PhysicsRayQueryParameters3D.create(from, to, ground_mask)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return null
		return {"height": to_local(hit["position"]).y, "normal": hit["normal"]}
	return {"height": 0.0, "normal": Vector3.UP}


func _make_multimesh(m: Mesh, transforms: Array[Transform3D]) -> MultiMesh:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = m
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	return multimesh


func _make_near(transforms: Array[Transform3D]) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	node.name = "Near"
	node.multimesh = _make_multimesh(mesh, transforms)
	node.set_meta(META_KEY, true)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows \
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if impostor != null and near_distance > 0.0:
		node.visibility_range_end = near_distance
		node.visibility_range_end_margin = margin
		node.visibility_range_fade_mode = fade_mode as GeometryInstance3D.VisibilityRangeFadeMode
	elif max_distance > 0.0:
		node.visibility_range_end = max_distance
		node.visibility_range_end_margin = margin
	return node


func _make_far(transforms: Array[Transform3D]) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	node.name = "Far"
	node.multimesh = impostor.create_multimesh(transforms)
	node.set_meta(META_KEY, true)
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_begin = near_distance
	node.visibility_range_begin_margin = margin
	node.visibility_range_fade_mode = fade_mode as GeometryInstance3D.VisibilityRangeFadeMode
	if max_distance > 0.0:
		node.visibility_range_end = max_distance
		node.visibility_range_end_margin = margin
	return node

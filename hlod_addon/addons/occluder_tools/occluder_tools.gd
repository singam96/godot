@tool
extends RefCounted
## Finds large, solid meshes and builds occluders for them. Everything here works outside of the editor, so it can be
## tested headless. Occluders are only made where they can't hide anything that is actually visible: the mesh has to
## be closed (watertight), opaque, and either nearly fill its bounding box (-> BoxOccluder3D, slightly inset) or be
## simple enough to be used as it is (-> ArrayOccluder3D).

const META_KEY := "occluder_tools_generated"
const NODE_NAME := "Occluder"
## A box is used when the mesh fills at least this much of its bounding box.
const BOX_FILL := 0.9
## Fraction by which a box occluder is shrunk on every side, so that it never pokes out of rounded edges.
const BOX_INSET := 0.02
const MAX_ARRAY_TRIANGLES := 2000

const SKIP_NO_MESH := "not a solid opaque mesh"
const SKIP_SMALL := "too small"
const SKIP_OPEN := "mesh is not closed"
const SKIP_COMPLEX := "too many triangles for an array occluder"
const SKIP_THIN := "too thin to hide much"


class Settings:
	var min_size := 4.0
	## Meshes that don't fill their bounding box get an exact array occluder when they are simple enough.
	var use_array_occluders := true


## Returns the occluders that [param root] and its descendants would get, as an Array of
## {"mesh_instance", "occluder", "position", "kind"}, and a Dictionary of skipped reasons -> count.
static func scan(root: Node, settings: Settings) -> Dictionary:
	var found: Array = []
	var skipped := {}
	_scan_node(root, settings, found, skipped)
	return {"found": found, "skipped": skipped}


static func _scan_node(node: Node, settings: Settings, found: Array, skipped: Dictionary) -> void:
	var mi := node as MeshInstance3D
	if mi != null and mi.is_visible() and not _has_generated_child(mi):
		var result := analyze_instance(mi, settings)
		if result.has("occluder"):
			found.append(result)
		else:
			skipped[result["reason"]] = skipped.get(result["reason"], 0) + 1
	for child in node.get_children():
		_scan_node(child, settings, found, skipped)


static func _has_generated_child(mi: Node) -> bool:
	for child in mi.get_children():
		if child is OccluderInstance3D:
			return true
	return false


## Decides whether [param mi] makes a good occluder and builds it. Returns {"reason"} when not, or
## {"mesh_instance", "occluder", "position", "kind"} when yes. [code]position[/code] is local to the mesh instance.
static func analyze_instance(mi: MeshInstance3D, settings: Settings) -> Dictionary:
	var mesh := mi.mesh
	if mesh == null or mi.skin != null:
		return {"reason": SKIP_NO_MESH}
	if not _is_opaque(mi):
		return {"reason": SKIP_NO_MESH}

	var aabb := mesh.get_aabb()
	var scale := _world_scale(mi)
	var dims := [aabb.size.x * scale.x, aabb.size.y * scale.y, aabb.size.z * scale.z]
	dims.sort()
	if dims[2] < settings.min_size:
		return {"reason": SKIP_SMALL}
	if dims[1] < settings.min_size * 0.5:
		return {"reason": SKIP_THIN}

	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	for s in mesh.get_surface_count():
		if mesh is ArrayMesh and mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			return {"reason": SKIP_NO_MESH}
		var arrays := mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx = arrays[Mesh.ARRAY_INDEX]
		var base := vertices.size()
		vertices.append_array(v)
		if idx == null or idx.size() == 0:
			for i in v.size():
				indices.append(base + i)
		else:
			for i in idx.size():
				indices.append(base + idx[i])

	var info := _measure(vertices, indices, aabb)
	if not info["closed"]:
		return {"reason": SKIP_OPEN}

	if info["fill"] >= BOX_FILL:
		var shrink := aabb.size * BOX_INSET
		var box := BoxOccluder3D.new()
		box.size = (aabb.size - shrink * 2.0).max(Vector3(0.01, 0.01, 0.01))
		return {"mesh_instance": mi, "occluder": box, "position": aabb.get_center(), "kind": "box"}

	if not settings.use_array_occluders or indices.size() / 3 > MAX_ARRAY_TRIANGLES:
		return {"reason": SKIP_COMPLEX}
	var occluder := ArrayOccluder3D.new()
	occluder.set_arrays(vertices, indices)
	return {"mesh_instance": mi, "occluder": occluder, "position": Vector3.ZERO, "kind": "array"}


static func _is_opaque(mi: MeshInstance3D) -> bool:
	var surfaces := mi.mesh.get_surface_count()
	if surfaces == 0:
		return false
	for s in surfaces:
		var material: Material = mi.material_override
		if material == null:
			material = mi.get_active_material(s)
		if material == null:
			continue  # Default material: opaque.
		var base := material as BaseMaterial3D
		if base == null:
			return false  # Shader materials may discard pixels.
		if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return false
	return true


static func _world_scale(node: Node3D) -> Vector3:
	var basis := Basis()
	var n: Node = node
	var chain: Array[Node3D] = []
	while n is Node3D:
		chain.append(n)
		if n.top_level:
			break
		n = n.get_parent()
	chain.reverse()
	for c in chain:
		basis = basis * c.transform.basis
	return basis.get_scale().abs()


## Returns {"closed": bool, "fill": float}. Closed means every edge is shared by exactly two triangles once vertices
## at the same position are welded. Fill is the enclosed volume divided by the volume of the bounding box.
static func _measure(vertices: PackedVector3Array, indices: PackedInt32Array, aabb: AABB) -> Dictionary:
	var weld := {}
	var ids := PackedInt32Array()
	ids.resize(vertices.size())
	var step := maxf(aabb.get_longest_axis_size(), 0.001) * 1e-4
	for i in vertices.size():
		var v := vertices[i]
		var key := Vector3i((v / step).round())
		if not weld.has(key):
			weld[key] = weld.size()
		ids[i] = weld[key]

	var edges := {}
	var volume := 0.0
	for t in range(0, indices.size() - 2, 3):
		var ia := indices[t]
		var ib := indices[t + 1]
		var ic := indices[t + 2]
		volume += vertices[ia].dot(vertices[ib].cross(vertices[ic])) / 6.0
		var a := ids[ia]
		var b := ids[ib]
		var c := ids[ic]
		if a == b or b == c or a == c:
			continue  # Degenerate triangle (sphere poles).
		for e in [[a, b], [b, c], [c, a]]:
			# Directed edges: a closed, consistently wound mesh has each edge once forward and once backward.
			var forward := Vector2i(e[0], e[1])
			var backward := Vector2i(e[1], e[0])
			if edges.has(backward) and edges[backward] > 0:
				edges[backward] -= 1
			else:
				edges[forward] = edges.get(forward, 0) + 1
	var closed := true
	for k in edges:
		if edges[k] != 0:
			closed = false
			break

	var box_volume := aabb.size.x * aabb.size.y * aabb.size.z
	var fill := absf(volume) / box_volume if box_volume > 1e-9 else 0.0
	return {"closed": closed, "fill": fill}


## Creates the OccluderInstance3D for one scan result. Not added to the tree.
static func make_instance(result: Dictionary) -> OccluderInstance3D:
	var occ := OccluderInstance3D.new()
	occ.name = NODE_NAME
	occ.occluder = result["occluder"]
	occ.position = result["position"]
	occ.set_meta(META_KEY, true)
	return occ


## Returns the OccluderInstance3Ds below [param root] that this add-on made.
static func find_generated(root: Node) -> Array[OccluderInstance3D]:
	var out: Array[OccluderInstance3D] = []
	_find_generated(root, out)
	return out


static func _find_generated(node: Node, out: Array[OccluderInstance3D]) -> void:
	if node is OccluderInstance3D and node.has_meta(META_KEY):
		out.append(node)
	for child in node.get_children():
		_find_generated(child, out)

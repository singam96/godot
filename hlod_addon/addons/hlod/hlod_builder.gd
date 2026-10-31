@tool
extends RefCounted
## Builds the proxy mesh of an HLODCluster.
##
## Generating a proxy is split in three parts: [method prepare] reads the scene and the rendering server on the
## calling thread, [method run] only works on the gathered data and can run on a thread of its own, and
## [method build_mesh] creates the mesh, textures and materials again on the calling thread. The thread must not
## call into the scene or the rendering server, because with the default threading model such calls block until
## the main thread flushes the server.

const HLODTools := preload("hlod_tools.gd")
const HLODAtlas := preload("hlod_atlas.gd")

enum Stage { ATLAS, MERGE, HIDDEN_FACES, SIMPLIFY, MESH, DONE }
## Where every stage starts in the progress (per mille).
const STAGE_START := [0, 150, 300, 700, 900, 1000]
## Number of triangles that are tested together by one worker task.
const CULL_CHUNK := 32

var simplify_ratio := 0.25
var merge_materials := true
var remove_hidden_faces := true
var atlas_cell_size := 128

## The outcome of [method run]: OK, ERR_SKIP if it was cancelled or ERR_DOES_NOT_EXIST if there was nothing to merge.
var error := OK

var _mutex := Mutex.new()
var _stage := 0
var _progress := 0
var _cancel := false
var _done := false

var _sources: Array[Dictionary] = []  # {mesh, surface, arrays}
var _entries: Array[Dictionary] = []  # {source, xform, material, group, slot}
var _albedo_images := {}  # Material -> Image (or null)
var _groups: Array[Dictionary] = []  # {key, materials, images, layout, atlas_image}
var _batches: Array[Dictionary] = []  # {material, group, arrays}
var _results: Array[Dictionary] = []  # {arrays, material, group}

# State of the hidden face test.
var _tri_mesh: TriangleMesh
var _faces := PackedVector3Array()
var _directions: Array[Vector3] = []
var _cull_distance := 0.0
var _cull_overshoot := 0.0
var _chunk_results: Array = []
var _chunks_done := 0
var _chunk_count := 1


func get_progress() -> float:
	_mutex.lock()
	var value := _progress / 1000.0
	_mutex.unlock()
	return value


func get_stage() -> int:
	_mutex.lock()
	var value := _stage
	_mutex.unlock()
	return value


func is_done() -> bool:
	_mutex.lock()
	var value := _done
	_mutex.unlock()
	return value


func cancel() -> void:
	_mutex.lock()
	_cancel = true
	_mutex.unlock()


func _is_cancelled() -> bool:
	_mutex.lock()
	var value := _cancel
	_mutex.unlock()
	return value


func _set_progress(stage: Stage, fraction := 0.0) -> void:
	_mutex.lock()
	_stage = stage
	_progress = int(STAGE_START[stage] + (STAGE_START[stage + 1] - STAGE_START[stage]) * clampf(fraction, 0.0, 1.0))
	_mutex.unlock()


func _finish(result: Error) -> void:
	error = result
	_mutex.lock()
	_done = true
	_mutex.unlock()


## Reads everything that is needed from the cluster, the scene and the rendering server, and merges the meshes.
func prepare(cluster: Node3D) -> Error:
	var source_lookup := {}
	for instance: GeometryInstance3D in cluster.collect_mergeable_geometry():
		var base: Variant = HLODTools.relative_transform(instance, cluster)
		if base == null:
			continue

		var mesh: Mesh
		var xforms: Array[Transform3D] = []
		var mesh_instance := instance as MeshInstance3D
		if mesh_instance != null:
			mesh = mesh_instance.mesh
			xforms.append(base)
		else:
			# Every instance of a MultiMesh (e.g. foliage) is merged in as its own copy of the mesh.
			var multimesh: MultiMesh = (instance as MultiMeshInstance3D).multimesh
			if multimesh == null or multimesh.transform_format != MultiMesh.TRANSFORM_3D:
				continue
			mesh = multimesh.mesh
			var count := multimesh.instance_count
			if multimesh.visible_instance_count >= 0:
				count = mini(count, multimesh.visible_instance_count)
			for i in count:
				xforms.append(base * multimesh.get_instance_transform(i))
		if mesh == null:
			continue

		for surface in mesh.get_surface_count():
			# Primitive meshes (box, sphere, ...) are always triangles; only ArrayMesh can hold other types.
			if mesh is ArrayMesh and mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var material: Material = instance.material_override
			if material == null:
				material = mesh_instance.get_active_material(surface) if mesh_instance != null else mesh.surface_get_material(surface)

			var key := "%d:%d" % [mesh.get_instance_id(), surface]
			if not source_lookup.has(key):
				source_lookup[key] = _sources.size()
				_sources.append({"mesh": mesh, "surface": surface, "arrays": mesh.surface_get_arrays(surface)})
			for xform in xforms:
				_entries.append({"source": source_lookup[key], "xform": xform, "material": material, "group": -1, "slot": -1})
	if _entries.is_empty():
		return ERR_DOES_NOT_EXIST

	if merge_materials:
		_plan_atlases()
	_merge()
	return OK


## Decides which materials are baked into which atlas, and where the UVs of every surface have to move to.
func _plan_atlases() -> void:
	var group_lookup := {}
	var uv_in_range := {}
	for entry in _entries:
		var material: StandardMaterial3D = entry.material as StandardMaterial3D
		if not HLODAtlas.is_eligible(material):
			continue
		# Atlas UVs only work for surfaces whose UVs stay inside the 0..1 range.
		var source_index: int = entry.source
		if not uv_in_range.has(source_index):
			uv_in_range[source_index] = _uvs_in_range(_sources[source_index].arrays[Mesh.ARRAY_TEX_UV])
		var has_uvs: bool = _sources[source_index].arrays[Mesh.ARRAY_TEX_UV] != null
		if not uv_in_range[source_index] or (material.albedo_texture != null and not has_uvs):
			continue
		if not _albedo_images.has(material):
			var albedo := HLODAtlas.read_albedo(material)
			if not albedo[0]:
				continue
			_albedo_images[material] = albedo[1]

		var key := HLODAtlas.group_key(material)
		if not group_lookup.has(key):
			group_lookup[key] = _groups.size()
			_groups.append({"key": key, "materials": [], "images": [], "layout": {}, "atlas_image": null})
		var group: Dictionary = _groups[group_lookup[key]]
		var slot: int = group.materials.find(material)
		if slot < 0:
			group.materials.append(material)
			group.images.append(_albedo_images[material])
			slot = group.materials.size() - 1
		entry.group = group_lookup[key]
		entry.slot = slot

	# A single material gains nothing from an atlas.
	for entry in _entries:
		if entry.group >= 0 and _groups[entry.group].materials.size() < 2:
			entry.group = -1
			entry.slot = -1
	for group in _groups:
		if group.materials.size() > 1:
			group.layout = HLODAtlas.layout(group.materials.size(), atlas_cell_size)


func _uvs_in_range(uvs: Variant) -> bool:
	if uvs == null:
		return true
	for uv: Vector2 in uvs:
		if uv.x < -0.001 or uv.x > 1.001 or uv.y < -0.001 or uv.y > 1.001:
			return false
	return true


## Surfaces are merged per material (or per atlas) to keep the draw call count of the proxy low.
func _merge() -> void:
	var tools: Array[SurfaceTool] = []
	var remapped := {}
	for entry in _entries:
		var batch_index := -1
		for i in _batches.size():
			var batch: Dictionary = _batches[i]
			if (entry.group >= 0 and batch.group == entry.group) or (entry.group < 0 and batch.group < 0 and batch.material == entry.material):
				batch_index = i
				break
		if batch_index < 0:
			batch_index = _batches.size()
			_batches.append({"material": entry.material, "group": entry.group, "arrays": []})
			var new_tool := SurfaceTool.new()
			new_tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			tools.append(new_tool)

		var source: Dictionary = _sources[entry.source]
		if entry.group >= 0:
			# The UVs of the surface move into the rectangle of its material. Without UVs (a solid color), the center is used.
			var key := "%d:%d" % [entry.source, entry.slot]
			if not remapped.has(key):
				var rect: Rect2 = _groups[entry.group].layout.rects[entry.slot]
				var arrays: Array = source.arrays.duplicate()
				var uvs: Variant = arrays[Mesh.ARRAY_TEX_UV]
				if uvs == null:
					var center := PackedVector2Array()
					center.resize((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size())
					center.fill(rect.get_center())
					arrays[Mesh.ARRAY_TEX_UV] = center
				else:
					arrays[Mesh.ARRAY_TEX_UV] = Transform2D(Vector2(rect.size.x, 0), Vector2(0, rect.size.y), rect.position) * (uvs as PackedVector2Array)
				var temporary := ArrayMesh.new()
				temporary.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				remapped[key] = temporary
			tools[batch_index].append_from(remapped[key], 0, entry.xform)
		else:
			tools[batch_index].append_from(source.mesh, source.surface, entry.xform)

	for i in _batches.size():
		tools[i].index()
		_batches[i].arrays = tools[i].commit_to_arrays()
	_sources.clear()
	_entries.clear()


## Does the heavy work on the gathered data. Safe to run on a thread.
func run() -> void:
	_set_progress(Stage.ATLAS)
	for i in _groups.size():
		var group: Dictionary = _groups[i]
		if group.materials.size() > 1:
			_set_progress(Stage.ATLAS, float(i) / _groups.size())
			group.atlas_image = HLODAtlas.bake(group.materials, group.images, group.layout)
		if _is_cancelled():
			return _finish(ERR_SKIP)

	var arrays_list: Array = []
	var occluders: Array[bool] = []
	for batch in _batches:
		arrays_list.append(batch.arrays)
		# Opaque surfaces hide what is behind them. Other shader types are unknown, so they are not assumed to be opaque.
		var material: Material = batch.material
		if batch.group >= 0:
			material = _groups[batch.group].materials[0]
		var base_material := material as BaseMaterial3D
		occluders.append(material == null or (base_material != null and base_material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED))

	if remove_hidden_faces:
		_set_progress(Stage.HIDDEN_FACES)
		_cull_hidden_faces(arrays_list, occluders)
		if _is_cancelled():
			return _finish(ERR_SKIP)

	for i in arrays_list.size():
		_set_progress(Stage.SIMPLIFY, float(i) / arrays_list.size())
		if _is_cancelled():
			return _finish(ERR_SKIP)
		var arrays: Array = arrays_list[i]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if indices.is_empty():
			# Every triangle of this surface was hidden.
			continue
		if simplify_ratio < 1.0:
			_simplify(arrays)
		_results.append({"arrays": arrays, "material": _batches[i].material, "group": _batches[i].group})

	_set_progress(Stage.MESH)
	_finish(OK if not _results.is_empty() else ERR_DOES_NOT_EXIST)


## Creates the mesh, the atlas textures and their materials. Uses the rendering server.
func build_mesh() -> ArrayMesh:
	var atlas_materials := {}
	for i in _groups.size():
		if _groups[i].atlas_image != null:
			atlas_materials[i] = HLODAtlas.create_material(_groups[i].materials[0], _groups[i].atlas_image)
	var mesh := ArrayMesh.new()
	for result in _results:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, result.arrays)
		var material: Material = atlas_materials[result.group] if atlas_materials.has(result.group) else result.material
		mesh.surface_set_material(mesh.get_surface_count() - 1, material)
	return mesh


# --- Simplification ---------------------------------------------------------------------------------------------

## Replaces the triangles of a surface with a simplified version. This uses the level of detail generation of
## ImporterMesh, which preserves normals and UVs. It produces levels that keep about half of the triangles of the
## previous one, so the level closest to the requested ratio is used.
func _simplify(arrays: Array) -> void:
	var base_indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var importer_mesh := ImporterMesh.new()
	importer_mesh.add_surface(Mesh.PRIMITIVE_TRIANGLES, arrays)
	importer_mesh.generate_lods(60.0, 25.0, [])
	var target := base_indices.size() * simplify_ratio
	var best_distance := absf(log(float(base_indices.size()) / target))
	var best: PackedInt32Array
	for lod in importer_mesh.get_surface_lod_count(0):
		var indices := importer_mesh.get_surface_lod_indices(0, lod)
		if indices.is_empty():
			continue
		var distance := absf(log(float(indices.size()) / target))
		if distance < best_distance:
			best_distance = distance
			best = indices
	if not best.is_empty():
		replace_indices(arrays, best)


## Replaces the index array of a surface and drops the vertices that are no longer referenced.
static func replace_indices(arrays: Array, new_indices: PackedInt32Array) -> void:
	var vertex_count: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var remap := PackedInt32Array()
	remap.resize(vertex_count)
	remap.fill(-1)
	var order := PackedInt32Array()
	var result := PackedInt32Array()
	result.resize(new_indices.size())
	var next := 0
	for i in new_indices.size():
		var v := new_indices[i]
		var mapped := remap[v]
		if mapped < 0:
			mapped = next
			remap[v] = mapped
			order.append(v)
			next += 1
		result[i] = mapped
	for a in Mesh.ARRAY_MAX:
		if a == Mesh.ARRAY_INDEX or arrays[a] == null:
			continue
		arrays[a] = _gather(arrays[a], order, vertex_count)
	arrays[Mesh.ARRAY_INDEX] = result


## Picks the entries of a per-vertex array that are listed in [param order]. Arrays can hold several values per vertex.
static func _gather(data: Variant, order: PackedInt32Array, vertex_count: int) -> Variant:
	@warning_ignore("integer_division")
	var stride: int = data.size() / vertex_count
	var result: Variant = data.slice(0, 0)
	result.resize(order.size() * stride)
	if stride == 1:
		for i in order.size():
			result[i] = data[order[i]]
	else:
		for i in order.size():
			for k in stride:
				result[i * stride + k] = data[order[i] * stride + k]
	return result


# --- Hidden faces -----------------------------------------------------------------------------------------------

## Drops the triangles that cannot be seen from outside. Only opaque triangles are tested and used as occluders;
## transparent surfaces are always kept. A triangle is visible if, from any direction, the first thing a ray finds
## on its way to one of its sample points is the triangle itself.
func _cull_hidden_faces(arrays_list: Array, occluders: Array[bool]) -> void:
	_faces = PackedVector3Array()
	var face_batch := PackedInt32Array()
	var face_triangle := PackedInt32Array()
	var bounds := AABB()
	var has_bounds := false
	for b in arrays_list.size():
		if not occluders[b]:
			continue
		var vertices: PackedVector3Array = arrays_list[b][Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays_list[b][Mesh.ARRAY_INDEX]
		for t in range(0, indices.size() - 2, 3):
			for k in 3:
				var v := vertices[indices[t + k]]
				_faces.append(v)
				if has_bounds:
					bounds = bounds.expand(v)
				else:
					bounds = AABB(v, Vector3.ZERO)
					has_bounds = true
			face_batch.append(b)
			face_triangle.append(t / 3)
	if face_batch.is_empty():
		return

	_tri_mesh = TriangleMesh.new()
	if not _tri_mesh.create_from_faces(_faces):
		return
	_directions.clear()
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				if x != 0 or y != 0 or z != 0:
					_directions.append(Vector3(x, y, z).normalized())
	_cull_distance = bounds.size.length() * 1.5 + 1.0
	_cull_overshoot = maxf(bounds.size.length() * 1e-3, 1e-4)

	# The rays of the triangles are independent, so they are spread over the worker threads.
	_chunk_count = ceili(float(face_batch.size()) / CULL_CHUNK)
	_chunk_results = []
	_chunk_results.resize(_chunk_count)
	_chunks_done = 0
	var group := WorkerThreadPool.add_group_task(_cull_chunk, _chunk_count, -1, false, "HLOD hidden face removal")
	WorkerThreadPool.wait_for_group_task_completion(group)
	if _is_cancelled():
		return

	var kept: Array[PackedInt32Array] = []
	kept.resize(arrays_list.size())
	for b in kept.size():
		kept[b] = PackedInt32Array()
	for f in face_batch.size():
		if _chunk_results[f / CULL_CHUNK][f % CULL_CHUNK] == 0:
			continue
		var indices: PackedInt32Array = arrays_list[face_batch[f]][Mesh.ARRAY_INDEX]
		var t := face_triangle[f] * 3
		kept[face_batch[f]].append_array(indices.slice(t, t + 3))
	for b in arrays_list.size():
		if occluders[b]:
			replace_indices(arrays_list[b], kept[b])
	_tri_mesh = null
	_faces = PackedVector3Array()


func _cull_chunk(chunk: int) -> void:
	if _is_cancelled():
		return
	var from := chunk * CULL_CHUNK
	var to := mini(from + CULL_CHUNK, _faces.size() / 3)
	var result := PackedByteArray()
	result.resize(to - from)
	for f in range(from, to):
		result[f - from] = 1 if _is_face_visible(f) else 0
	_chunk_results[chunk] = result
	_mutex.lock()
	_chunks_done += 1
	_progress = int(STAGE_START[Stage.HIDDEN_FACES] + (STAGE_START[Stage.SIMPLIFY] - STAGE_START[Stage.HIDDEN_FACES]) * float(_chunks_done) / _chunk_count)
	_mutex.unlock()


func _is_reached(sample: Vector3, direction: Vector3, face: int) -> bool:
	var hit := _tri_mesh.intersect_segment(sample + direction * _cull_distance, sample - direction * _cull_overshoot)
	return not hit.is_empty() and hit.face_index == face


func _is_face_visible(face: int) -> bool:
	var v0 := _faces[face * 3]
	var v1 := _faces[face * 3 + 1]
	var v2 := _faces[face * 3 + 2]
	var normal := (v1 - v0).cross(v2 - v0).normalized()
	if normal.is_zero_approx():
		# A triangle without area can't be seen.
		return false
	var center := (v0 + v1 + v2) / 3.0
	# Most triangles are found from the direction of their normal, so it is tried first. The center is tested from
	# every direction, while the other sample points only catch triangles that are mostly hidden, so a few
	# directions are enough for them.
	if _is_reached(center, normal, face) or _is_reached(center, -normal, face):
		return true
	for direction in _directions:
		if _is_reached(center, direction, face):
			return true
	var corners := [
		v0 * (2.0 / 3.0) + v1 * (1.0 / 6.0) + v2 * (1.0 / 6.0),
		v1 * (2.0 / 3.0) + v2 * (1.0 / 6.0) + v0 * (1.0 / 6.0),
		v2 * (2.0 / 3.0) + v0 * (1.0 / 6.0) + v1 * (1.0 / 6.0),
	]
	for corner: Vector3 in corners:
		if _is_reached(corner, normal, face) or _is_reached(corner, -normal, face):
			return true
		for axis in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
			if _is_reached(corner, axis, face):
				return true
	return false

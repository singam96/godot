/**************************************************************************/
/*  hlod_cluster_3d.cpp                                                   */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "hlod_cluster_3d.h"

#include "core/config/engine.h"
#include "core/io/resource_loader.h"
#include "core/io/resource_saver.h"
#include "core/object/callable_mp.h"
#include "core/object/class_db.h"
#include "scene/3d/camera_3d.h"
#include "scene/3d/hlod_material_atlas.h"
#include "scene/main/scene_tree.h"
#include "scene/main/viewport.h"
#include "scene/resources/packed_scene.h"
#include "scene/resources/surface_tool.h"
#include "servers/rendering/rendering_server.h"

namespace {

// Packs the per-vertex data of `p_src` down to the vertices listed in `p_order`.
// Every vertex array in a mesh surface has a fixed number of elements per vertex, so the stride is derived from the sizes.
template <typename T>
T _compact_array(const T &p_src, const LocalVector<uint32_t> &p_order, uint32_t p_vertex_count) {
	const uint32_t stride = p_src.size() / p_vertex_count;
	T dst;
	dst.resize(p_order.size() * stride);
	const auto *src = p_src.ptr();
	auto *write = dst.ptrw();
	for (uint32_t i = 0; i < p_order.size(); i++) {
		for (uint32_t k = 0; k < stride; k++) {
			write[i * stride + k] = src[p_order[i] * stride + k];
		}
	}
	return dst;
}

void _simplify_surface_arrays(Array &r_arrays, float p_ratio, float p_error) {
	const PackedVector3Array vertices = r_arrays[Mesh::ARRAY_VERTEX];
	const PackedInt32Array indices = r_arrays[Mesh::ARRAY_INDEX];
	const uint32_t vertex_count = vertices.size();
	const uint32_t index_count = indices.size();
	if (vertex_count == 0 || index_count < 3 || index_count % 3 != 0) {
		return;
	}

	const size_t target_index_count = MAX((size_t)3, (size_t)(index_count * p_ratio) / 3 * 3);
	if (target_index_count >= index_count) {
		return;
	}

	LocalVector<float> positions;
	positions.resize(vertex_count * 3);
	for (uint32_t i = 0; i < vertex_count; i++) {
		positions[i * 3 + 0] = vertices[i].x;
		positions[i * 3 + 1] = vertices[i].y;
		positions[i * 3 + 2] = vertices[i].z;
	}

	LocalVector<uint32_t> simplified;
	simplified.resize(index_count);
	float result_error = 0.0f;
	const size_t new_index_count = SurfaceTool::simplify_func(simplified.ptr(), (const unsigned int *)indices.ptr(), index_count, positions.ptr(), vertex_count, sizeof(float) * 3, target_index_count, p_error, SurfaceTool::SIMPLIFY_PRUNE, &result_error);
	if (new_index_count == 0) {
		return;
	}

	// Drop the vertices that are no longer referenced.
	LocalVector<int32_t> remap;
	remap.resize(vertex_count);
	for (uint32_t i = 0; i < vertex_count; i++) {
		remap[i] = -1;
	}
	LocalVector<uint32_t> order;
	PackedInt32Array new_indices;
	new_indices.resize(new_index_count);
	for (size_t i = 0; i < new_index_count; i++) {
		const uint32_t v = simplified[i];
		if (remap[v] < 0) {
			remap[v] = order.size();
			order.push_back(v);
		}
		new_indices.write[i] = remap[v];
	}

	for (int a = 0; a < Mesh::ARRAY_MAX; a++) {
		if (a == Mesh::ARRAY_INDEX) {
			continue;
		}
		Variant &data = r_arrays[a];
		switch (data.get_type()) {
			case Variant::PACKED_VECTOR3_ARRAY: {
				data = _compact_array<PackedVector3Array>(data, order, vertex_count);
			} break;
			case Variant::PACKED_VECTOR2_ARRAY: {
				data = _compact_array<PackedVector2Array>(data, order, vertex_count);
			} break;
			case Variant::PACKED_COLOR_ARRAY: {
				data = _compact_array<PackedColorArray>(data, order, vertex_count);
			} break;
			case Variant::PACKED_FLOAT32_ARRAY: {
				data = _compact_array<PackedFloat32Array>(data, order, vertex_count);
			} break;
			case Variant::PACKED_INT32_ARRAY: {
				data = _compact_array<PackedInt32Array>(data, order, vertex_count);
			} break;
			case Variant::PACKED_BYTE_ARRAY: {
				data = _compact_array<PackedByteArray>(data, order, vertex_count);
			} break;
			default: {
			} break;
		}
	}
	r_arrays[Mesh::ARRAY_INDEX] = new_indices;
}

} // namespace

void HLODCluster3D::_collect_geometry(Node *p_node, LocalVector<GeometryInstance3D *> &r_geometry, LocalVector<GeometryInstance3D *> *r_nested_proxies, bool p_descend_nested) const {
	for (int i = 0; i < p_node->get_child_count(false); i++) {
		Node *child = p_node->get_child(i, false);
		HLODCluster3D *nested = Object::cast_to<HLODCluster3D>(child);
		if (nested) {
			if (r_nested_proxies) {
				r_nested_proxies->push_back(nested->proxy);
			}
			if (p_descend_nested) {
				_collect_geometry(nested, r_geometry, r_nested_proxies, p_descend_nested);
			}
			continue;
		}
		GeometryInstance3D *geometry = Object::cast_to<GeometryInstance3D>(child);
		if (geometry) {
			r_geometry.push_back(geometry);
		}
		_collect_geometry(child, r_geometry, r_nested_proxies, p_descend_nested);
	}
}

void HLODCluster3D::_collect_meshes(LocalVector<MeshInstance3D *> &r_meshes) const {
	LocalVector<GeometryInstance3D *> geometry;
	_collect_geometry(const_cast<HLODCluster3D *>(this), geometry, nullptr, true);
	for (GeometryInstance3D *instance : geometry) {
		MeshInstance3D *mesh_instance = Object::cast_to<MeshInstance3D>(instance);
		if (mesh_instance) {
			r_meshes.push_back(mesh_instance);
		}
	}
}

bool HLODCluster3D::_get_relative_transform(Node3D *p_node, Transform3D &r_xform) const {
	// Computed from the local transforms so that it also works for scenes that are not inside the tree (e.g. while importing).
	Transform3D xform;
	Node *node = p_node;
	while (node && node != this) {
		Node3D *node_3d = Object::cast_to<Node3D>(node);
		if (node_3d) {
			if (!node_3d->is_visible() || node_3d->is_set_as_top_level()) {
				return false;
			}
			xform = node_3d->get_transform() * xform;
		}
		node = node->get_parent();
	}
	r_xform = xform;
	return node == this;
}

void HLODCluster3D::_update_proxy() {
	proxy->set_mesh(proxy_mesh);
	proxy->set_visibility_range_begin(switch_distance);
	proxy->set_visibility_range_begin_margin(switch_margin);
	proxy->set_visibility_range_fade_mode(fade_mode);
}

void HLODCluster3D::_unlink_children() {
	for (const ObjectID &id : linked_ids) {
		GeometryInstance3D *geometry = Object::cast_to<GeometryInstance3D>(ObjectDB::get_instance(id));
		if (geometry) {
			RS::get_singleton()->instance_set_visibility_parent(geometry->get_instance(), RID());
		}
	}
	linked_ids.clear();
}

void HLODCluster3D::_link_children() {
	_unlink_children();
	if (proxy_mesh.is_null() || !is_inside_tree()) {
		return;
	}

	LocalVector<GeometryInstance3D *> geometry;
	// The proxies of nested clusters follow this cluster's proxy too, which builds the hierarchy of detail levels.
	_collect_geometry(this, geometry, &geometry, false);
	for (GeometryInstance3D *instance : geometry) {
		if (!instance->get_visibility_parent().is_empty()) {
			// The author already chose a visibility parent for this node.
			continue;
		}
		RS::get_singleton()->instance_set_visibility_parent(instance->get_instance(), proxy->get_instance());
		linked_ids.push_back(instance->get_instance_id());
	}
}

void HLODCluster3D::_queue_relink() {
	if (relink_queued || !is_inside_tree()) {
		return;
	}
	relink_queued = true;
	callable_mp(this, &HLODCluster3D::update_children).call_deferred();
}

void HLODCluster3D::_notification(int p_what) {
	switch (p_what) {
		case NOTIFICATION_ENTER_TREE: {
			_link_children();
			set_process_internal(!detail_scene_path.is_empty() && !Engine::get_singleton()->is_editor_hint());
		} break;

		case NOTIFICATION_EXIT_TREE: {
			_unlink_children();
			set_process_internal(false);
		} break;

		case NOTIFICATION_INTERNAL_PROCESS: {
			// Checking a few times per second is plenty, because the load margin gives the load time to finish.
			stream_timer += get_process_delta_time();
			if (stream_timer >= 0.2f) {
				stream_timer = 0.0f;
				update_streaming();
			}
		} break;

		case NOTIFICATION_CHILD_ORDER_CHANGED: {
			_queue_relink();
		} break;
	}
}

void HLODCluster3D::set_switch_distance(float p_distance) {
	// A distance of zero would keep the proxy visible forever and hide the original geometry.
	switch_distance = MAX(p_distance, 0.01f);
	_update_proxy();
}

float HLODCluster3D::get_switch_distance() const {
	return switch_distance;
}

void HLODCluster3D::set_switch_margin(float p_margin) {
	switch_margin = MAX(p_margin, 0.0f);
	_update_proxy();
}

float HLODCluster3D::get_switch_margin() const {
	return switch_margin;
}

void HLODCluster3D::set_fade_mode(FadeMode p_mode) {
	fade_mode = p_mode;
	_update_proxy();
}

HLODCluster3D::FadeMode HLODCluster3D::get_fade_mode() const {
	return fade_mode;
}

void HLODCluster3D::set_simplify_ratio(float p_ratio) {
	simplify_ratio = CLAMP(p_ratio, 0.01f, 1.0f);
}

float HLODCluster3D::get_simplify_ratio() const {
	return simplify_ratio;
}

void HLODCluster3D::set_simplify_error(float p_error) {
	simplify_error = CLAMP(p_error, 0.0f, 1.0f);
}

float HLODCluster3D::get_simplify_error() const {
	return simplify_error;
}

void HLODCluster3D::set_merge_materials(bool p_enabled) {
	merge_materials = p_enabled;
}

bool HLODCluster3D::get_merge_materials() const {
	return merge_materials;
}

void HLODCluster3D::set_atlas_cell_size(int p_size) {
	atlas_cell_size = CLAMP(p_size, 16, 2048);
}

int HLODCluster3D::get_atlas_cell_size() const {
	return atlas_cell_size;
}

void HLODCluster3D::set_detail_scene_path(const String &p_path) {
	detail_scene_path = p_path;
	stream_state = STREAM_UNLOADED;
	if (is_inside_tree()) {
		set_process_internal(!detail_scene_path.is_empty() && !Engine::get_singleton()->is_editor_hint());
	}
}

String HLODCluster3D::get_detail_scene_path() const {
	return detail_scene_path;
}

void HLODCluster3D::set_stream_load_margin(float p_margin) {
	stream_load_margin = MAX(p_margin, 0.0f);
}

float HLODCluster3D::get_stream_load_margin() const {
	return stream_load_margin;
}

void HLODCluster3D::set_stream_unload_margin(float p_margin) {
	stream_unload_margin = MAX(p_margin, 0.0f);
}

float HLODCluster3D::get_stream_unload_margin() const {
	return stream_unload_margin;
}

void HLODCluster3D::set_proxy_mesh(const Ref<Mesh> &p_mesh) {
	proxy_mesh = p_mesh;
	_update_proxy();
	_link_children();
	update_configuration_warnings();
}

Ref<Mesh> HLODCluster3D::get_proxy_mesh() const {
	return proxy_mesh;
}

Error HLODCluster3D::generate_proxy() {
	const bool simplify = simplify_ratio < 1.0f;
	ERR_FAIL_COND_V_MSG(simplify && SurfaceTool::simplify_func == nullptr, ERR_UNAVAILABLE, "Generating an HLOD proxy with simplify_ratio below 1.0 requires the meshoptimizer module.");

	LocalVector<MeshInstance3D *> meshes;
	_collect_meshes(meshes);

	// Gather the surfaces to merge together with the material they are drawn with.
	struct SourceSurface {
		Ref<Mesh> mesh;
		int surface = 0;
		Transform3D xform;
		Ref<Material> material;
		bool uvs_in_range = true;
	};
	LocalVector<SourceSurface> surfaces;
	for (MeshInstance3D *mesh_instance : meshes) {
		Ref<Mesh> mesh = mesh_instance->get_mesh();
		Transform3D xform;
		if (mesh.is_null() || !_get_relative_transform(mesh_instance, xform)) {
			continue;
		}
		for (int surface = 0; surface < mesh->get_surface_count(); surface++) {
			if (mesh->surface_get_primitive_type(surface) != Mesh::PRIMITIVE_TRIANGLES) {
				continue;
			}
			SourceSurface source;
			source.mesh = mesh;
			source.surface = surface;
			source.xform = xform;
			source.material = mesh_instance->get_material_override();
			if (source.material.is_null()) {
				source.material = mesh_instance->get_active_material(surface);
			}
			surfaces.push_back(source);
		}
	}
	ERR_FAIL_COND_V_MSG(surfaces.is_empty(), ERR_DOES_NOT_EXIST, "HLODCluster3D has no visible MeshInstance3D descendants with triangle surfaces to merge.");

	// Bake groups of simple materials into texture atlases.
	struct AtlasGroup {
		String key;
		Vector<Ref<StandardMaterial3D>> materials;
		Ref<StandardMaterial3D> atlas_material;
		Vector<Rect2> rects;
	};
	LocalVector<AtlasGroup> groups;
	// For every surface, the atlas group (or -1) and the index of its material in that group.
	LocalVector<Pair<int, int>> atlas_slots;
	atlas_slots.resize(surfaces.size());
	for (Pair<int, int> &slot : atlas_slots) {
		slot = Pair<int, int>(-1, -1);
	}
	if (merge_materials) {
		for (uint32_t i = 0; i < surfaces.size(); i++) {
			const Ref<StandardMaterial3D> material = surfaces[i].material;
			if (!HLODMaterialAtlas::is_eligible(material)) {
				continue;
			}
			// Atlas UVs only work for surfaces whose UVs stay inside the 0..1 range.
			const Array arrays = surfaces[i].mesh->surface_get_arrays(surfaces[i].surface);
			const PackedVector2Array uvs = arrays[Mesh::ARRAY_TEX_UV];
			bool in_range = true;
			for (const Vector2 &uv : uvs) {
				if (uv.x < -0.001f || uv.x > 1.001f || uv.y < -0.001f || uv.y > 1.001f) {
					in_range = false;
					break;
				}
			}
			if (!in_range || (uvs.is_empty() && material->get_texture(BaseMaterial3D::TEXTURE_ALBEDO).is_valid())) {
				continue;
			}

			const String key = HLODMaterialAtlas::get_group_key(material);
			int group_index = -1;
			for (uint32_t g = 0; g < groups.size(); g++) {
				if (groups[g].key == key) {
					group_index = g;
					break;
				}
			}
			if (group_index < 0) {
				AtlasGroup group;
				group.key = key;
				groups.push_back(group);
				group_index = groups.size() - 1;
			}
			AtlasGroup &group = groups[group_index];
			int material_index = group.materials.find(material);
			if (material_index < 0) {
				group.materials.push_back(material);
				material_index = group.materials.size() - 1;
			}
			atlas_slots[i] = Pair<int, int>(group_index, material_index);
		}
		for (AtlasGroup &group : groups) {
			// A single material gains nothing from an atlas.
			if (group.materials.size() > 1) {
				group.atlas_material = HLODMaterialAtlas::build(group.materials, atlas_cell_size, group.rects);
			}
		}
	}

	// Surfaces are merged per material (or per atlas) to keep the draw call count of the proxy low.
	struct Batch {
		Ref<Material> material;
		int atlas_group = -1;
		Ref<SurfaceTool> tool;
	};
	LocalVector<Batch> batches;
	for (uint32_t i = 0; i < surfaces.size(); i++) {
		const SourceSurface &source = surfaces[i];
		const int group_index = atlas_slots[i].first;
		const bool atlased = group_index >= 0 && groups[group_index].atlas_material.is_valid();

		Batch *batch = nullptr;
		for (Batch &candidate : batches) {
			if (atlased ? candidate.atlas_group == group_index : (candidate.atlas_group < 0 && candidate.material == source.material)) {
				batch = &candidate;
				break;
			}
		}
		if (!batch) {
			batches.push_back(Batch());
			batch = &batches[batches.size() - 1];
			batch->atlas_group = atlased ? group_index : -1;
			batch->material = atlased ? Ref<Material>(groups[group_index].atlas_material) : source.material;
			batch->tool.instantiate();
			batch->tool->begin(Mesh::PRIMITIVE_TRIANGLES);
		}

		const uint32_t first_vertex = batch->tool->get_vertex_array().size();
		batch->tool->append_from(source.mesh, source.surface, source.xform);
		if (atlased) {
			const Rect2 rect = groups[group_index].rects[atlas_slots[i].second];
			// Make sure the UV attribute exists even when the source surface has none (solid color materials).
			batch->tool->set_uv(Vector2());
			LocalVector<SurfaceTool::Vertex> &vertices = batch->tool->get_vertex_array();
			const bool has_uvs = (uint64_t)source.mesh->surface_get_format(source.surface) & Mesh::ARRAY_FORMAT_TEX_UV;
			for (uint32_t v = first_vertex; v < vertices.size(); v++) {
				vertices[v].uv = rect.position + (has_uvs ? vertices[v].uv * rect.size : rect.size * 0.5f);
			}
		}
	}

	Ref<ArrayMesh> result;
	result.instantiate();
	for (Batch &batch : batches) {
		batch.tool->index();
		Array arrays = batch.tool->commit_to_arrays();
		if (simplify) {
			_simplify_surface_arrays(arrays, simplify_ratio, simplify_error);
		}
		result->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, arrays);
		result->surface_set_material(result->get_surface_count() - 1, batch.material);
	}

	set_proxy_mesh(result);
	return OK;
}

Error HLODCluster3D::build_grid(float p_cell_size) {
	ERR_FAIL_COND_V_MSG(p_cell_size <= 0.0f, ERR_INVALID_PARAMETER, "The grid cell size must be greater than zero.");

	// Sort the direct 3D children into grid cells by their position.
	HashMap<Vector3i, LocalVector<Node3D *>> cells;
	LocalVector<Vector3i> cell_order;
	for (int i = 0; i < get_child_count(false); i++) {
		Node3D *child = Object::cast_to<Node3D>(get_child(i, false));
		if (!child) {
			continue;
		}
		const Vector3 position = child->get_position() / p_cell_size;
		const Vector3i cell(Math::floor(position.x), Math::floor(position.y), Math::floor(position.z));
		if (!cells.has(cell)) {
			cell_order.push_back(cell);
		}
		cells[cell].push_back(child);
	}
	ERR_FAIL_COND_V_MSG(cells.is_empty(), ERR_DOES_NOT_EXIST, "HLODCluster3D has no 3D children to group into a grid.");

	for (const Vector3i &cell : cell_order) {
		const Vector3 center = (Vector3(cell) + Vector3(0.5f, 0.5f, 0.5f)) * p_cell_size;

		HLODCluster3D *cell_cluster = memnew(HLODCluster3D);
		cell_cluster->set_name(vformat("Cell_%d_%d_%d", cell.x, cell.y, cell.z));
		cell_cluster->set_switch_distance(switch_distance * 0.5f);
		cell_cluster->set_switch_margin(switch_margin * 0.5f);
		cell_cluster->set_fade_mode(fade_mode);
		cell_cluster->set_simplify_ratio(simplify_ratio);
		cell_cluster->set_simplify_error(simplify_error);
		cell_cluster->set_merge_materials(merge_materials);
		cell_cluster->set_atlas_cell_size(atlas_cell_size);
		cell_cluster->set_position(center);
		add_child(cell_cluster, true);
		Node *scene_owner = get_owner();
		if (!scene_owner && is_inside_tree() && get_tree()->get_edited_scene_root() == this) {
			scene_owner = this;
		}
		if (scene_owner) {
			cell_cluster->set_owner(scene_owner);
		}

		// The cell is a pure translation, so the objects keep their place by subtracting its offset.
		for (Node3D *child : cells[cell]) {
			const Vector3 position = child->get_position();
			child->reparent(cell_cluster, false);
			child->set_position(position - center);
		}

		const Error err = cell_cluster->generate_proxy();
		if (err != OK) {
			return err;
		}
	}

	return generate_proxy();
}

Error HLODCluster3D::store_detail_scene(const String &p_path) {
	ERR_FAIL_COND_V_MSG(p_path.is_empty(), ERR_INVALID_PARAMETER, "The detail scene path must not be empty.");
	if (proxy_mesh.is_null()) {
		const Error err = generate_proxy();
		if (err != OK) {
			return err;
		}
	}

	Node *scene_owner = get_owner() ? get_owner() : this;

	// Move the content below this node into a holder that becomes the root of the stored scene.
	Node3D *holder = memnew(Node3D);
	holder->set_name("Detail");
	struct Moved {
		Node *node = nullptr;
		LocalVector<Node *> owned;
	};
	LocalVector<Moved> moved;
	while (get_child_count(false) > 0) {
		Moved entry;
		entry.node = get_child(0, false);
		LocalVector<Node *> to_visit;
		to_visit.push_back(entry.node);
		while (!to_visit.is_empty()) {
			Node *node = to_visit[to_visit.size() - 1];
			to_visit.resize(to_visit.size() - 1);
			if (node == entry.node || node->get_owner() == scene_owner || !node->get_owner()) {
				entry.owned.push_back(node);
			}
			for (int i = 0; i < node->get_child_count(false); i++) {
				to_visit.push_back(node->get_child(i, false));
			}
		}
		remove_child(entry.node);
		holder->add_child(entry.node);
		for (Node *node : entry.owned) {
			node->set_owner(holder);
		}
		moved.push_back(entry);
	}

	Ref<PackedScene> packed;
	packed.instantiate();
	Error err = packed->pack(holder);
	if (err == OK) {
		err = ResourceSaver::save(packed, p_path);
	}

	if (err != OK) {
		// Put everything back where it was.
		for (Moved &entry : moved) {
			holder->remove_child(entry.node);
			add_child(entry.node);
			for (Node *node : entry.owned) {
				node->set_owner(scene_owner == this ? nullptr : scene_owner);
			}
		}
		memdelete(holder);
		return err;
	}

	memdelete(holder);
	set_detail_scene_path(p_path);
	return OK;
}

void HLODCluster3D::update_streaming() {
	if (detail_scene_path.is_empty() || !is_inside_tree() || Engine::get_singleton()->is_editor_hint()) {
		return;
	}
	Viewport *viewport = get_viewport();
	Camera3D *camera = viewport ? viewport->get_camera_3d() : nullptr;
	if (!camera) {
		return;
	}
	const float distance = camera->get_global_position().distance_to(get_global_position());
	const float detail_distance = switch_distance + switch_margin;

	switch (stream_state) {
		case STREAM_UNLOADED: {
			if (distance < detail_distance + stream_load_margin) {
				if (ResourceLoader::load_threaded_request(detail_scene_path, "PackedScene") == OK) {
					stream_state = STREAM_LOADING;
				} else {
					ERR_PRINT(vformat("HLODCluster3D could not start loading the detail scene '%s'.", detail_scene_path));
					stream_state = STREAM_FAILED;
				}
			}
		} break;
		case STREAM_LOADING: {
			const ResourceLoader::ThreadLoadStatus status = ResourceLoader::load_threaded_get_status(detail_scene_path);
			if (status == ResourceLoader::THREAD_LOAD_LOADED) {
				Ref<PackedScene> packed = ResourceLoader::load_threaded_get(detail_scene_path);
				Node *detail = packed.is_valid() ? packed->instantiate() : nullptr;
				if (detail) {
					add_child(detail);
					detail_id = detail->get_instance_id();
					stream_state = STREAM_LOADED;
				} else {
					ERR_PRINT(vformat("HLODCluster3D could not instantiate the detail scene '%s'.", detail_scene_path));
					stream_state = STREAM_FAILED;
				}
			} else if (status == ResourceLoader::THREAD_LOAD_FAILED || status == ResourceLoader::THREAD_LOAD_INVALID_RESOURCE) {
				ERR_PRINT(vformat("HLODCluster3D failed to load the detail scene '%s'.", detail_scene_path));
				stream_state = STREAM_FAILED;
			}
		} break;
		case STREAM_LOADED: {
			if (distance > detail_distance + stream_unload_margin) {
				Node *detail = Object::cast_to<Node>(ObjectDB::get_instance(detail_id));
				if (detail) {
					detail->queue_free();
				}
				detail_id = ObjectID();
				stream_state = STREAM_UNLOADED;
			}
		} break;
		case STREAM_FAILED: {
		} break;
	}
}

void HLODCluster3D::clear_proxy() {
	set_proxy_mesh(Ref<Mesh>());
}

void HLODCluster3D::update_children() {
	relink_queued = false;
	_link_children();
}

PackedStringArray HLODCluster3D::get_configuration_warnings() const {
	PackedStringArray warnings = Node3D::get_configuration_warnings();

	if (proxy_mesh.is_null()) {
		warnings.push_back(RTR("No proxy mesh has been generated, so this cluster has no effect. Call generate_proxy() to create one."));
	}

	return warnings;
}

void HLODCluster3D::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_switch_distance", "distance"), &HLODCluster3D::set_switch_distance);
	ClassDB::bind_method(D_METHOD("get_switch_distance"), &HLODCluster3D::get_switch_distance);
	ClassDB::bind_method(D_METHOD("set_switch_margin", "margin"), &HLODCluster3D::set_switch_margin);
	ClassDB::bind_method(D_METHOD("get_switch_margin"), &HLODCluster3D::get_switch_margin);
	ClassDB::bind_method(D_METHOD("set_fade_mode", "mode"), &HLODCluster3D::set_fade_mode);
	ClassDB::bind_method(D_METHOD("get_fade_mode"), &HLODCluster3D::get_fade_mode);
	ClassDB::bind_method(D_METHOD("set_simplify_ratio", "ratio"), &HLODCluster3D::set_simplify_ratio);
	ClassDB::bind_method(D_METHOD("get_simplify_ratio"), &HLODCluster3D::get_simplify_ratio);
	ClassDB::bind_method(D_METHOD("set_simplify_error", "error"), &HLODCluster3D::set_simplify_error);
	ClassDB::bind_method(D_METHOD("get_simplify_error"), &HLODCluster3D::get_simplify_error);
	ClassDB::bind_method(D_METHOD("set_merge_materials", "enabled"), &HLODCluster3D::set_merge_materials);
	ClassDB::bind_method(D_METHOD("get_merge_materials"), &HLODCluster3D::get_merge_materials);
	ClassDB::bind_method(D_METHOD("set_atlas_cell_size", "size"), &HLODCluster3D::set_atlas_cell_size);
	ClassDB::bind_method(D_METHOD("get_atlas_cell_size"), &HLODCluster3D::get_atlas_cell_size);
	ClassDB::bind_method(D_METHOD("set_detail_scene_path", "path"), &HLODCluster3D::set_detail_scene_path);
	ClassDB::bind_method(D_METHOD("get_detail_scene_path"), &HLODCluster3D::get_detail_scene_path);
	ClassDB::bind_method(D_METHOD("set_stream_load_margin", "margin"), &HLODCluster3D::set_stream_load_margin);
	ClassDB::bind_method(D_METHOD("get_stream_load_margin"), &HLODCluster3D::get_stream_load_margin);
	ClassDB::bind_method(D_METHOD("set_stream_unload_margin", "margin"), &HLODCluster3D::set_stream_unload_margin);
	ClassDB::bind_method(D_METHOD("get_stream_unload_margin"), &HLODCluster3D::get_stream_unload_margin);
	ClassDB::bind_method(D_METHOD("set_proxy_mesh", "mesh"), &HLODCluster3D::set_proxy_mesh);
	ClassDB::bind_method(D_METHOD("get_proxy_mesh"), &HLODCluster3D::get_proxy_mesh);

	ClassDB::bind_method(D_METHOD("generate_proxy"), &HLODCluster3D::generate_proxy);
	ClassDB::bind_method(D_METHOD("build_grid", "cell_size"), &HLODCluster3D::build_grid);
	ClassDB::bind_method(D_METHOD("store_detail_scene", "path"), &HLODCluster3D::store_detail_scene);
	ClassDB::bind_method(D_METHOD("update_streaming"), &HLODCluster3D::update_streaming);
	ClassDB::bind_method(D_METHOD("clear_proxy"), &HLODCluster3D::clear_proxy);
	ClassDB::bind_method(D_METHOD("update_children"), &HLODCluster3D::update_children);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "switch_distance", PROPERTY_HINT_RANGE, "0.01,4096,0.01,or_greater,suffix:m"), "set_switch_distance", "get_switch_distance");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "switch_margin", PROPERTY_HINT_RANGE, "0,4096,0.01,or_greater,suffix:m"), "set_switch_margin", "get_switch_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "fade_mode", PROPERTY_HINT_ENUM, "Disabled,Self,Dependencies"), "set_fade_mode", "get_fade_mode");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "simplify_ratio", PROPERTY_HINT_RANGE, "0.01,1,0.01"), "set_simplify_ratio", "get_simplify_ratio");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "simplify_error", PROPERTY_HINT_RANGE, "0,1,0.001"), "set_simplify_error", "get_simplify_error");
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "merge_materials"), "set_merge_materials", "get_merge_materials");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "atlas_cell_size", PROPERTY_HINT_RANGE, "16,2048,1,suffix:px"), "set_atlas_cell_size", "get_atlas_cell_size");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "proxy_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"), "set_proxy_mesh", "get_proxy_mesh");

	ADD_GROUP("Streaming", "");
	ADD_PROPERTY(PropertyInfo(Variant::STRING, "detail_scene_path", PROPERTY_HINT_FILE, "*.tscn,*.scn"), "set_detail_scene_path", "get_detail_scene_path");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stream_load_margin", PROPERTY_HINT_RANGE, "0,4096,0.1,or_greater,suffix:m"), "set_stream_load_margin", "get_stream_load_margin");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "stream_unload_margin", PROPERTY_HINT_RANGE, "0,4096,0.1,or_greater,suffix:m"), "set_stream_unload_margin", "get_stream_unload_margin");
}

HLODCluster3D::HLODCluster3D() {
	proxy = memnew(MeshInstance3D);
	add_child(proxy, false, INTERNAL_MODE_BACK);
	_update_proxy();
}

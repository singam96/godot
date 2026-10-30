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

#include "core/object/callable_mp.h"
#include "core/object/class_db.h"
#include "scene/main/scene_tree.h"
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
		} break;

		case NOTIFICATION_EXIT_TREE: {
			_unlink_children();
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
	ERR_FAIL_COND_V_MSG(!is_inside_tree(), ERR_UNCONFIGURED, "HLODCluster3D must be inside the scene tree to generate its proxy mesh.");
	const bool simplify = simplify_ratio < 1.0f;
	ERR_FAIL_COND_V_MSG(simplify && SurfaceTool::simplify_func == nullptr, ERR_UNAVAILABLE, "Generating an HLOD proxy with simplify_ratio below 1.0 requires the meshoptimizer module.");

	LocalVector<MeshInstance3D *> meshes;
	_collect_meshes(meshes);

	// Surfaces are merged per material to keep the draw call count of the proxy low.
	struct Batch {
		Ref<Material> material;
		Ref<SurfaceTool> tool;
	};
	LocalVector<Batch> batches;

	const Transform3D to_local = get_global_transform().affine_inverse();
	for (MeshInstance3D *mesh_instance : meshes) {
		Ref<Mesh> mesh = mesh_instance->get_mesh();
		if (mesh.is_null() || !mesh_instance->is_visible_in_tree()) {
			continue;
		}
		const Transform3D xform = to_local * mesh_instance->get_global_transform();
		for (int surface = 0; surface < mesh->get_surface_count(); surface++) {
			if (mesh->surface_get_primitive_type(surface) != Mesh::PRIMITIVE_TRIANGLES) {
				continue;
			}
			Ref<Material> material = mesh_instance->get_material_override();
			if (material.is_null()) {
				material = mesh_instance->get_active_material(surface);
			}

			Batch *batch = nullptr;
			for (Batch &candidate : batches) {
				if (candidate.material == material) {
					batch = &candidate;
					break;
				}
			}
			if (!batch) {
				batches.push_back(Batch());
				batch = &batches[batches.size() - 1];
				batch->material = material;
				batch->tool.instantiate();
			}
			batch->tool->append_from(mesh, surface, xform);
		}
	}
	ERR_FAIL_COND_V_MSG(batches.is_empty(), ERR_DOES_NOT_EXIST, "HLODCluster3D has no visible MeshInstance3D descendants with triangle surfaces to merge.");

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
	ERR_FAIL_COND_V_MSG(!is_inside_tree(), ERR_UNCONFIGURED, "HLODCluster3D must be inside the scene tree to build a grid.");

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
		HLODCluster3D *cell_cluster = memnew(HLODCluster3D);
		cell_cluster->set_name(vformat("Cell_%d_%d_%d", cell.x, cell.y, cell.z));
		cell_cluster->set_switch_distance(switch_distance * 0.5f);
		cell_cluster->set_switch_margin(switch_margin * 0.5f);
		cell_cluster->set_fade_mode(fade_mode);
		cell_cluster->set_simplify_ratio(simplify_ratio);
		cell_cluster->set_simplify_error(simplify_error);
		add_child(cell_cluster, true);
		if (get_owner()) {
			cell_cluster->set_owner(get_owner());
		} else if (is_inside_tree() && get_tree()->get_edited_scene_root() == this) {
			cell_cluster->set_owner(this);
		}
		cell_cluster->set_global_position(to_global((Vector3(cell) + Vector3(0.5f, 0.5f, 0.5f)) * p_cell_size));

		for (Node3D *child : cells[cell]) {
			child->reparent(cell_cluster, true);
		}

		const Error err = cell_cluster->generate_proxy();
		if (err != OK) {
			return err;
		}
	}

	return generate_proxy();
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
	ClassDB::bind_method(D_METHOD("set_proxy_mesh", "mesh"), &HLODCluster3D::set_proxy_mesh);
	ClassDB::bind_method(D_METHOD("get_proxy_mesh"), &HLODCluster3D::get_proxy_mesh);

	ClassDB::bind_method(D_METHOD("generate_proxy"), &HLODCluster3D::generate_proxy);
	ClassDB::bind_method(D_METHOD("build_grid", "cell_size"), &HLODCluster3D::build_grid);
	ClassDB::bind_method(D_METHOD("clear_proxy"), &HLODCluster3D::clear_proxy);
	ClassDB::bind_method(D_METHOD("update_children"), &HLODCluster3D::update_children);

	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "switch_distance", PROPERTY_HINT_RANGE, "0.01,4096,0.01,or_greater,suffix:m"), "set_switch_distance", "get_switch_distance");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "switch_margin", PROPERTY_HINT_RANGE, "0,4096,0.01,or_greater,suffix:m"), "set_switch_margin", "get_switch_margin");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "fade_mode", PROPERTY_HINT_ENUM, "Disabled,Self,Dependencies"), "set_fade_mode", "get_fade_mode");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "simplify_ratio", PROPERTY_HINT_RANGE, "0.01,1,0.01"), "set_simplify_ratio", "get_simplify_ratio");
	ADD_PROPERTY(PropertyInfo(Variant::FLOAT, "simplify_error", PROPERTY_HINT_RANGE, "0,1,0.001"), "set_simplify_error", "get_simplify_error");
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "proxy_mesh", PROPERTY_HINT_RESOURCE_TYPE, "Mesh"), "set_proxy_mesh", "get_proxy_mesh");
}

HLODCluster3D::HLODCluster3D() {
	proxy = memnew(MeshInstance3D);
	add_child(proxy, false, INTERNAL_MODE_BACK);
	_update_proxy();
}

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
#include "core/math/triangle_mesh.h"
#include "core/object/callable_mp.h"
#include "core/object/class_db.h"
#include "core/object/worker_thread_pool.h"
#include "core/os/os.h"
#include "core/os/thread.h"
#include "scene/3d/camera_3d.h"
#include "scene/3d/hlod_material_atlas.h"
#include "scene/3d/multimesh_instance_3d.h"
#include "scene/main/scene_tree.h"
#include "scene/main/viewport.h"
#include "scene/resources/multimesh.h"
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

// Moves a node below a new parent while keeping the nodes that belong to the same scene owner. Unsetting the owner
// during the move avoids the warning about temporarily inconsistent ownership that Node::reparent() causes.
void _move_node_keeping_owner(Node *p_node, Node *p_new_parent) {
	Node *owner = p_node->get_owner();
	LocalVector<Node *> owned;
	if (owner) {
		LocalVector<Node *> to_visit;
		to_visit.push_back(p_node);
		while (!to_visit.is_empty()) {
			Node *node = to_visit[to_visit.size() - 1];
			to_visit.resize(to_visit.size() - 1);
			if (node->get_owner() == owner) {
				owned.push_back(node);
			}
			for (int i = 0; i < node->get_child_count(false); i++) {
				to_visit.push_back(node->get_child(i, false));
			}
		}
		for (Node *node : owned) {
			node->set_owner(nullptr);
		}
	}
	p_node->get_parent()->remove_child(p_node);
	p_new_parent->add_child(p_node);
	for (Node *node : owned) {
		node->set_owner(owner);
	}
}

// Replaces the triangles of a surface with `p_indices` and drops the vertices that are no longer referenced.
void _replace_surface_indices(Array &r_arrays, const LocalVector<uint32_t> &p_indices, uint32_t p_index_count) {
	const PackedVector3Array vertices = r_arrays[Mesh::ARRAY_VERTEX];
	const uint32_t vertex_count = vertices.size();

	LocalVector<int32_t> remap;
	remap.resize(vertex_count);
	for (uint32_t i = 0; i < vertex_count; i++) {
		remap[i] = -1;
	}
	LocalVector<uint32_t> order;
	PackedInt32Array new_indices;
	new_indices.resize(p_index_count);
	for (uint32_t i = 0; i < p_index_count; i++) {
		const uint32_t v = p_indices[i];
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
	_replace_surface_indices(r_arrays, simplified, new_index_count);
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

void HLODCluster3D::set_remove_hidden_faces(bool p_enabled) {
	remove_hidden_faces = p_enabled;
}

bool HLODCluster3D::get_remove_hidden_faces() const {
	return remove_hidden_faces;
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

struct HLODCluster3D::BuildJob {
	// Everything that the worker needs is read from the scene and the rendering server beforehand, because the worker must not call into either.
	struct SourceSurface {
		int arrays_index = 0; // Index in `source_arrays`.
		Transform3D xform;
		Ref<Material> material;
	};
	LocalVector<SourceSurface> surfaces;
	LocalVector<Array> source_arrays;
	HashMap<Material *, Ref<Image>> albedo_images;

	bool simplify = false;
	bool merge_materials = true;
	bool remove_hidden_faces = true;
	float simplify_ratio = 1.0f;
	float simplify_error = 0.1f;
	int atlas_cell_size = 128;

	// The result: surface arrays with their material, or the atlas (an index in `atlases`) that the material is replaced by.
	struct ResultSurface {
		Array arrays;
		Ref<Material> material;
		int atlas = -1;
	};
	struct Atlas {
		Ref<Image> image;
		Ref<StandardMaterial3D> material_template;
	};
	LocalVector<ResultSurface> result_surfaces;
	LocalVector<Atlas> atlases;
	Error error_code = OK;

	// Progress is reported in per mille through stages, so that another thread can show it.
	enum Stage {
		STAGE_ATLAS,
		STAGE_MERGE,
		STAGE_HIDDEN_FACES,
		STAGE_SIMPLIFY,
		STAGE_MESH,
		STAGE_DONE,
	};
	SafeNumeric<int> stage;
	SafeNumeric<int> progress;
	SafeFlag cancel;
	SafeFlag done;
	// The job runs on a thread of its own, so that it can in turn spread its work over the worker thread pool.
	Thread thread;

	void set_progress(Stage p_stage, float p_fraction = 0.0f) {
		static const int starts[] = { 0, 150, 300, 700, 900, 1000 };
		stage.set(p_stage);
		progress.set(starts[p_stage] + int((starts[p_stage + 1] - starts[p_stage]) * CLAMP(p_fraction, 0.0f, 1.0f)));
	}
};

void HLODCluster3D::_cull_hidden_faces(BuildJob *p_job, LocalVector<Array> &r_arrays, const LocalVector<bool> &p_occluders) {
	// Only opaque triangles are tested and used as occluders. Transparent surfaces are always kept.
	Vector<Vector3> faces;
	LocalVector<Pair<uint32_t, uint32_t>> face_source;
	AABB bounds;
	bool has_bounds = false;
	for (uint32_t b = 0; b < r_arrays.size(); b++) {
		if (!p_occluders[b]) {
			continue;
		}
		const PackedVector3Array vertices = r_arrays[b][Mesh::ARRAY_VERTEX];
		const PackedInt32Array indices = r_arrays[b][Mesh::ARRAY_INDEX];
		for (int t = 0; t + 2 < indices.size(); t += 3) {
			const Vector3 &v0 = vertices[indices[t]];
			const Vector3 &v1 = vertices[indices[t + 1]];
			const Vector3 &v2 = vertices[indices[t + 2]];
			faces.push_back(v0);
			faces.push_back(v1);
			faces.push_back(v2);
			face_source.push_back(Pair<uint32_t, uint32_t>(b, t / 3));
			for (const Vector3 &v : { v0, v1, v2 }) {
				if (has_bounds) {
					bounds.expand_to(v);
				} else {
					bounds = AABB(v, Vector3());
					has_bounds = true;
				}
			}
		}
	}
	if (face_source.is_empty()) {
		return;
	}

	Ref<TriangleMesh> occluder_mesh;
	occluder_mesh.instantiate();
	occluder_mesh->create(faces);
	if (!occluder_mesh->is_valid()) {
		return;
	}

	// A triangle is visible if, from any direction, the first thing a ray finds on its way to one of its sample points is the triangle itself.
	LocalVector<Vector3> directions;
	for (int x = -1; x <= 1; x++) {
		for (int y = -1; y <= 1; y++) {
			for (int z = -1; z <= 1; z++) {
				if (x != 0 || y != 0 || z != 0) {
					directions.push_back(Vector3(x, y, z).normalized());
				}
			}
		}
	}

	// The rays of the triangles are independent, so they are spread over the worker threads.
	struct CullContext {
		BuildJob *job = nullptr;
		const TriangleMesh *mesh = nullptr;
		const Vector<Vector3> *faces = nullptr;
		const LocalVector<Vector3> *directions = nullptr;
		float distance = 0.0f;
		float overshoot = 0.0f;
		LocalVector<uint8_t> *visible = nullptr;
		SafeNumeric<uint32_t> tested;

		bool is_reached(const Vector3 &p_sample, const Vector3 &p_direction, int32_t p_face) const {
			Vector3 point;
			Vector3 hit_normal;
			int32_t face_index = -1;
			return mesh->intersect_segment(p_sample + p_direction * distance, p_sample - p_direction * overshoot, point, hit_normal, nullptr, &face_index) && face_index == p_face;
		}

		uint32_t total = 1;

		void test_face(uint32_t p_face, void *p_unused) {
			const uint32_t count = tested.increment();
			if ((count & 63) == 0) {
				job->set_progress(BuildJob::STAGE_HIDDEN_FACES, float(count) / total);
			}
			if (job->cancel.is_set()) {
				return;
			}
			const Vector3 &v0 = (*faces)[p_face * 3];
			const Vector3 &v1 = (*faces)[p_face * 3 + 1];
			const Vector3 &v2 = (*faces)[p_face * 3 + 2];
			const Vector3 normal = (v1 - v0).cross(v2 - v0).normalized();
			const Vector3 center = (v0 + v1 + v2) / 3.0f;
			const Vector3 corner_samples[3] = {
				v0 * (2.0f / 3.0f) + v1 * (1.0f / 6.0f) + v2 * (1.0f / 6.0f),
				v1 * (2.0f / 3.0f) + v2 * (1.0f / 6.0f) + v0 * (1.0f / 6.0f),
				v2 * (2.0f / 3.0f) + v0 * (1.0f / 6.0f) + v1 * (1.0f / 6.0f),
			};

			(*visible)[p_face] = false;
			if (normal.is_zero_approx()) {
				// A triangle without area can't be seen.
				return;
			}
			// Most triangles are found from the direction of their normal, so it is tried first. The center is tested from
			// every direction, while the other sample points only catch triangles that are mostly hidden, so a few directions are enough for them.
			if (is_reached(center, normal, p_face) || is_reached(center, -normal, p_face)) {
				(*visible)[p_face] = true;
				return;
			}
			for (const Vector3 &direction : *directions) {
				if (is_reached(center, direction, p_face)) {
					(*visible)[p_face] = true;
					return;
				}
			}
			static const Vector3 axes[6] = { Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0), Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1) };
			for (const Vector3 &sample : corner_samples) {
				if (is_reached(sample, normal, p_face) || is_reached(sample, -normal, p_face)) {
					(*visible)[p_face] = true;
					return;
				}
				for (const Vector3 &axis : axes) {
					if (is_reached(sample, axis, p_face)) {
						(*visible)[p_face] = true;
						return;
					}
				}
			}
		}
	};

	LocalVector<uint8_t> visible;
	visible.resize(face_source.size());
	CullContext context;
	context.job = p_job;
	context.mesh = occluder_mesh.ptr();
	context.faces = &faces;
	context.directions = &directions;
	context.distance = bounds.size.length() * 1.5f + 1.0f;
	context.overshoot = MAX(bounds.size.length() * 1e-3f, 1e-4f);
	context.visible = &visible;
	context.total = face_source.size();

	const WorkerThreadPool::GroupID group = WorkerThreadPool::get_singleton()->add_template_group_task(&context, &CullContext::test_face, (void *)nullptr, face_source.size(), -1, false, "HLODCluster3D hidden face removal");
	// Waiting lets this thread help with the work, which also keeps this safe when it is itself a worker.
	WorkerThreadPool::get_singleton()->wait_for_group_task_completion(group);
	if (p_job->cancel.is_set()) {
		return;
	}

	// Rebuild the index arrays of the surfaces that were tested.
	LocalVector<LocalVector<uint32_t>> kept;
	kept.resize(r_arrays.size());
	for (uint32_t f = 0; f < face_source.size(); f++) {
		if (!visible[f]) {
			continue;
		}
		const PackedInt32Array indices = r_arrays[face_source[f].first][Mesh::ARRAY_INDEX];
		for (int k = 0; k < 3; k++) {
			kept[face_source[f].first].push_back(indices[face_source[f].second * 3 + k]);
		}
	}
	for (uint32_t b = 0; b < r_arrays.size(); b++) {
		if (p_occluders[b]) {
			_replace_surface_indices(r_arrays[b], kept[b], kept[b].size());
		}
	}
}

namespace {

// Surface data that is merged from several source surfaces.
struct MergedSurface {
	PackedVector3Array vertices;
	PackedVector3Array normals;
	PackedFloat32Array tangents;
	PackedColorArray colors;
	PackedVector2Array uvs;
	PackedVector2Array uv2s;
	PackedInt32Array indices;
	bool has_normals = false;
	bool has_tangents = false;
	bool has_colors = false;
	bool has_uvs = false;
	bool has_uv2s = false;

	// Appends an attribute of a source surface. Surfaces that lack the attribute get default values, and attributes that
	// only later surfaces have are filled in for the earlier ones.
	template <typename T, typename D, typename C>
	static void append_attribute(T &r_dst, bool &r_has, const Variant &p_src, int p_previous_count, int p_count, int p_stride, D p_default, C p_convert) {
		const bool src_has = p_src.get_type() != Variant::NIL;
		if (!src_has && !r_has) {
			return;
		}
		if (!r_has) {
			r_has = true;
			r_dst.resize(p_previous_count * p_stride);
			for (int i = 0; i < p_previous_count * p_stride; i++) {
				r_dst.write[i] = p_default();
			}
		}
		const int old_size = r_dst.size();
		r_dst.resize(old_size + p_count * p_stride);
		if (src_has) {
			const T src = p_src;
			for (int i = 0; i < p_count * p_stride; i++) {
				r_dst.write[old_size + i] = p_convert(src, i);
			}
		} else {
			for (int i = 0; i < p_count * p_stride; i++) {
				r_dst.write[old_size + i] = p_default();
			}
		}
	}

	void append(const Array &p_src, const Transform3D &p_xform, const Rect2 *p_atlas_rect) {
		const PackedVector3Array src_vertices = p_src[Mesh::ARRAY_VERTEX];
		const int count = src_vertices.size();
		const int previous_count = vertices.size();
		const Basis normal_basis = p_xform.basis.inverse().transposed();
		const float tangent_flip = p_xform.basis.determinant() < 0 ? -1.0f : 1.0f;

		vertices.resize(previous_count + count);
		for (int i = 0; i < count; i++) {
			vertices.write[previous_count + i] = p_xform.xform(src_vertices[i]);
		}

		append_attribute<PackedVector3Array>(
				normals, has_normals, p_src[Mesh::ARRAY_NORMAL], previous_count, count, 1, []() { return Vector3(0, 1, 0); },
				[&](const PackedVector3Array &p_array, int p_index) { return normal_basis.xform(p_array[p_index]).normalized(); });
		append_attribute<PackedFloat32Array>(
				tangents, has_tangents, p_src[Mesh::ARRAY_TANGENT], previous_count, count, 4, []() { return 0.0f; },
				[&](const PackedFloat32Array &p_array, int p_index) {
					const int base = p_index - (p_index % 4);
					if (p_index % 4 == 3) {
						return p_array[p_index] * tangent_flip;
					}
					const Vector3 tangent = p_xform.basis.xform(Vector3(p_array[base], p_array[base + 1], p_array[base + 2])).normalized();
					return tangent[p_index % 4];
				});
		append_attribute<PackedColorArray>(
				colors, has_colors, p_src[Mesh::ARRAY_COLOR], previous_count, count, 1, []() { return Color(1, 1, 1, 1); },
				[](const PackedColorArray &p_array, int p_index) { return p_array[p_index]; });

		if (p_atlas_rect) {
			// The surface is drawn with the atlas: its UVs move into the rectangle of its material. Without UVs (a solid color), the center is used.
			const Rect2 rect = *p_atlas_rect;
			const Variant src_uvs = p_src[Mesh::ARRAY_TEX_UV];
			append_attribute<PackedVector2Array>(
					uvs, has_uvs, Variant(PackedVector2Array()), previous_count, 0, 1, []() { return Vector2(); },
					[](const PackedVector2Array &p_array, int p_index) { return p_array[p_index]; });
			has_uvs = true;
			uvs.resize(previous_count + count);
			const PackedVector2Array source = src_uvs.get_type() == Variant::NIL ? PackedVector2Array() : PackedVector2Array(src_uvs);
			for (int i = 0; i < count; i++) {
				uvs.write[previous_count + i] = rect.position + (source.is_empty() ? rect.size * 0.5f : source[i] * rect.size);
			}
		} else {
			append_attribute<PackedVector2Array>(
					uvs, has_uvs, p_src[Mesh::ARRAY_TEX_UV], previous_count, count, 1, []() { return Vector2(); },
					[](const PackedVector2Array &p_array, int p_index) { return p_array[p_index]; });
		}
		append_attribute<PackedVector2Array>(
				uv2s, has_uv2s, p_src[Mesh::ARRAY_TEX_UV2], previous_count, count, 1, []() { return Vector2(); },
				[](const PackedVector2Array &p_array, int p_index) { return p_array[p_index]; });

		const PackedInt32Array src_indices = p_src[Mesh::ARRAY_INDEX];
		const int index_count = src_indices.is_empty() ? count : src_indices.size();
		const int old_index_count = indices.size();
		indices.resize(old_index_count + index_count);
		for (int i = 0; i < index_count; i++) {
			indices.write[old_index_count + i] = previous_count + (src_indices.is_empty() ? i : src_indices[i]);
		}
	}

	Array to_arrays() const {
		Array arrays;
		arrays.resize(Mesh::ARRAY_MAX);
		arrays[Mesh::ARRAY_VERTEX] = vertices;
		if (has_normals) {
			arrays[Mesh::ARRAY_NORMAL] = normals;
		}
		if (has_tangents) {
			arrays[Mesh::ARRAY_TANGENT] = tangents;
		}
		if (has_colors) {
			arrays[Mesh::ARRAY_COLOR] = colors;
		}
		if (has_uvs) {
			arrays[Mesh::ARRAY_TEX_UV] = uvs;
		}
		if (has_uv2s) {
			arrays[Mesh::ARRAY_TEX_UV2] = uv2s;
		}
		arrays[Mesh::ARRAY_INDEX] = indices;
		return arrays;
	}
};

} // namespace

void HLODCluster3D::_run_job(void *p_job) {
	BuildJob *job = static_cast<BuildJob *>(p_job);
	job->set_progress(BuildJob::STAGE_ATLAS);

	// Bake groups of simple materials into texture atlases.
	struct AtlasGroup {
		String key;
		Vector<Ref<StandardMaterial3D>> materials;
		Vector<Ref<Image>> images;
		Ref<Image> atlas_image;
		int atlas_index = -1;
		Vector<Rect2> rects;
	};
	LocalVector<AtlasGroup> groups;
	// For every surface, the atlas group (or -1) and the index of its material in that group.
	LocalVector<Pair<int, int>> atlas_slots;
	atlas_slots.resize(job->surfaces.size());
	for (Pair<int, int> &slot : atlas_slots) {
		slot = Pair<int, int>(-1, -1);
	}

	auto cancelled = [&]() {
		if (job->cancel.is_set()) {
			job->error_code = ERR_SKIP;
			job->done.set();
			return true;
		}
		return false;
	};

	if (job->merge_materials) {
		for (uint32_t i = 0; i < job->surfaces.size(); i++) {
			const BuildJob::SourceSurface &source = job->surfaces[i];
			const Ref<StandardMaterial3D> material = source.material;
			if (!HLODMaterialAtlas::is_eligible(material)) {
				continue;
			}
			// Atlas UVs only work for surfaces whose UVs stay inside the 0..1 range.
			const PackedVector2Array uvs = job->source_arrays[source.arrays_index][Mesh::ARRAY_TEX_UV];
			bool in_range = true;
			for (const Vector2 &uv : uvs) {
				if (uv.x < -0.001f || uv.x > 1.001f || uv.y < -0.001f || uv.y > 1.001f) {
					in_range = false;
					break;
				}
			}
			const bool textured = material->get_texture(BaseMaterial3D::TEXTURE_ALBEDO).is_valid();
			if (!in_range || (textured && (uvs.is_empty() || !job->albedo_images.has(material.ptr())))) {
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
				group.images.push_back(textured ? job->albedo_images[material.ptr()] : Ref<Image>());
				material_index = group.materials.size() - 1;
			}
			atlas_slots[i] = Pair<int, int>(group_index, material_index);
		}
		if (cancelled()) {
			return;
		}
		for (uint32_t g = 0; g < groups.size(); g++) {
			job->set_progress(BuildJob::STAGE_ATLAS, float(g) / groups.size());
			// A single material gains nothing from an atlas.
			if (groups[g].materials.size() > 1) {
				groups[g].atlas_image = HLODMaterialAtlas::build(groups[g].materials, groups[g].images, job->atlas_cell_size, groups[g].rects);
				if (groups[g].atlas_image.is_valid()) {
					groups[g].atlas_index = job->atlases.size();
					BuildJob::Atlas atlas;
					atlas.image = groups[g].atlas_image;
					atlas.material_template = groups[g].materials[0];
					job->atlases.push_back(atlas);
				}
			}
			if (cancelled()) {
				return;
			}
		}
	}

	// Surfaces are merged per material (or per atlas) to keep the draw call count of the proxy low.
	struct Batch {
		Ref<Material> material;
		int atlas_group = -1;
		MergedSurface surface;
	};
	LocalVector<Batch> batches;
	for (uint32_t i = 0; i < job->surfaces.size(); i++) {
		if ((i & 15) == 0) {
			job->set_progress(BuildJob::STAGE_MERGE, float(i) / job->surfaces.size());
			if (cancelled()) {
				return;
			}
		}
		const BuildJob::SourceSurface &source = job->surfaces[i];
		const int group_index = atlas_slots[i].first;
		const bool atlased = group_index >= 0 && groups[group_index].atlas_index >= 0;

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
			batch->material = source.material;
		}

		if (atlased) {
			const Rect2 rect = groups[group_index].rects[atlas_slots[i].second];
			batch->surface.append(job->source_arrays[source.arrays_index], source.xform, &rect);
		} else {
			batch->surface.append(job->source_arrays[source.arrays_index], source.xform, nullptr);
		}
	}

	LocalVector<Array> arrays;
	LocalVector<bool> occluders;
	for (Batch &batch : batches) {
		arrays.push_back(batch.surface.to_arrays());
		// Opaque surfaces hide what is behind them. Other shader types are unknown, so they are not assumed to be opaque.
		Ref<Material> material = batch.material;
		if (batch.atlas_group >= 0) {
			material = groups[batch.atlas_group].materials[0];
		}
		const Ref<BaseMaterial3D> base_material = material;
		occluders.push_back(material.is_null() || (base_material.is_valid() && base_material->get_transparency() == BaseMaterial3D::TRANSPARENCY_DISABLED));
	}

	if (job->remove_hidden_faces) {
		job->set_progress(BuildJob::STAGE_HIDDEN_FACES);
		_cull_hidden_faces(job, arrays, occluders);
		if (cancelled()) {
			return;
		}
	}

	for (uint32_t i = 0; i < arrays.size(); i++) {
		job->set_progress(BuildJob::STAGE_SIMPLIFY, float(i) / arrays.size());
		if (cancelled()) {
			return;
		}
		const PackedInt32Array indices = arrays[i][Mesh::ARRAY_INDEX];
		if (indices.is_empty()) {
			// Every triangle of this surface was hidden.
			continue;
		}
		if (job->simplify) {
			_simplify_surface_arrays(arrays[i], job->simplify_ratio, job->simplify_error);
		}
		BuildJob::ResultSurface result;
		result.arrays = arrays[i];
		result.material = batches[i].material;
		result.atlas = batches[i].atlas_group >= 0 ? groups[batches[i].atlas_group].atlas_index : -1;
		job->result_surfaces.push_back(result);
	}

	job->error_code = job->result_surfaces.is_empty() ? ERR_DOES_NOT_EXIST : OK;
	job->set_progress(BuildJob::STAGE_DONE);
	job->done.set();
}

Error HLODCluster3D::_start_job(bool p_threaded) {
	ERR_FAIL_COND_V_MSG(job != nullptr, ERR_BUSY, "The HLOD proxy is already being generated.");
	const bool simplify = simplify_ratio < 1.0f;
	ERR_FAIL_COND_V_MSG(simplify && SurfaceTool::simplify_func == nullptr, ERR_UNAVAILABLE, "Generating an HLOD proxy with simplify_ratio below 1.0 requires the meshoptimizer module.");

	// Read everything that is needed from the scene and the rendering server first, so that the worker does not touch them.
	LocalVector<GeometryInstance3D *> geometry;
	_collect_geometry(this, geometry, nullptr, true);

	BuildJob *new_job = memnew(BuildJob);
	new_job->simplify = simplify;
	new_job->merge_materials = merge_materials;
	new_job->remove_hidden_faces = remove_hidden_faces;
	new_job->simplify_ratio = simplify_ratio;
	new_job->simplify_error = simplify_error;
	new_job->atlas_cell_size = atlas_cell_size;

	HashMap<Mesh *, HashMap<int, int>> arrays_cache;
	for (GeometryInstance3D *instance : geometry) {
		Transform3D base_xform;
		MeshInstance3D *mesh_instance = Object::cast_to<MeshInstance3D>(instance);
		MultiMeshInstance3D *multimesh_instance = Object::cast_to<MultiMeshInstance3D>(instance);
		if (!mesh_instance && !multimesh_instance) {
			continue;
		}
		if (!_get_relative_transform(instance, base_xform)) {
			continue;
		}

		Ref<Mesh> mesh;
		LocalVector<Transform3D> xforms;
		if (mesh_instance) {
			mesh = mesh_instance->get_mesh();
			xforms.push_back(base_xform);
		} else {
			// Every instance of a MultiMesh (e.g. foliage) is merged in as its own copy of the mesh.
			const Ref<MultiMesh> multimesh = multimesh_instance->get_multimesh();
			if (multimesh.is_null() || multimesh->get_transform_format() != MultiMesh::TRANSFORM_3D) {
				continue;
			}
			mesh = multimesh->get_mesh();
			int count = multimesh->get_instance_count();
			if (multimesh->get_visible_instance_count() >= 0) {
				count = MIN(count, multimesh->get_visible_instance_count());
			}
			for (int i = 0; i < count; i++) {
				xforms.push_back(base_xform * multimesh->get_instance_transform(i));
			}
		}
		if (mesh.is_null()) {
			continue;
		}

		for (int surface = 0; surface < mesh->get_surface_count(); surface++) {
			if (mesh->surface_get_primitive_type(surface) != Mesh::PRIMITIVE_TRIANGLES) {
				continue;
			}
			Ref<Material> material = instance->get_material_override();
			if (material.is_null()) {
				material = mesh_instance ? mesh_instance->get_active_material(surface) : mesh->surface_get_material(surface);
			}

			HashMap<int, int> &mesh_cache = arrays_cache[mesh.ptr()];
			if (!mesh_cache.has(surface)) {
				mesh_cache[surface] = new_job->source_arrays.size();
				new_job->source_arrays.push_back(mesh->surface_get_arrays(surface));
			}
			const int arrays_index = mesh_cache[surface];

			// The images of the albedo textures are needed for the atlas.
			const Ref<StandardMaterial3D> standard_material = material;
			if (merge_materials && standard_material.is_valid() && !new_job->albedo_images.has(standard_material.ptr()) && HLODMaterialAtlas::is_eligible(standard_material)) {
				const Ref<Texture2D> texture = standard_material->get_texture(BaseMaterial3D::TEXTURE_ALBEDO);
				if (texture.is_valid()) {
					const Ref<Image> image = texture->get_image();
					if (image.is_valid()) {
						new_job->albedo_images[standard_material.ptr()] = image;
					}
				}
			}

			for (const Transform3D &xform : xforms) {
				BuildJob::SourceSurface source;
				source.arrays_index = arrays_index;
				source.xform = xform;
				source.material = material;
				new_job->surfaces.push_back(source);
			}
		}
	}
	if (new_job->surfaces.is_empty()) {
		memdelete(new_job);
		return ERR_DOES_NOT_EXIST;
	}

	job = new_job;
	if (p_threaded) {
		job->thread.start(&HLODCluster3D::_run_job, job);
	} else {
		_run_job(job);
	}
	return OK;
}

Error HLODCluster3D::generate_proxy() {
	const Error err = _start_job(false);
	if (err != OK) {
		return err;
	}
	return finish_generation();
}

Error HLODCluster3D::generate_proxy_async() {
	return _start_job(true);
}

bool HLODCluster3D::is_generating() const {
	return job != nullptr && !job->done.is_set();
}

float HLODCluster3D::get_generation_progress() const {
	if (!job) {
		return 0.0f;
	}
	return job->progress.get() / 1000.0f;
}

String HLODCluster3D::get_generation_status() const {
	if (!job) {
		return String();
	}
	switch (job->stage.get()) {
		case BuildJob::STAGE_ATLAS:
			return RTR("Baking the material atlas...");
		case BuildJob::STAGE_MERGE:
			return RTR("Merging meshes...");
		case BuildJob::STAGE_HIDDEN_FACES:
			return RTR("Removing hidden faces...");
		case BuildJob::STAGE_SIMPLIFY:
			return RTR("Simplifying...");
		default:
			return RTR("Finishing...");
	}
}

void HLODCluster3D::cancel_generation() {
	if (job) {
		job->cancel.set();
	}
}

Error HLODCluster3D::finish_generation() {
	ERR_FAIL_NULL_V_MSG(job, ERR_UNCONFIGURED, "The HLOD proxy generation was not started.");
	if (job->thread.is_started()) {
		job->thread.wait_to_finish();
	}
	const Error err = job->error_code;

	// The meshes, textures and materials are created here, because they need the rendering server.
	Ref<ArrayMesh> result;
	if (err == OK) {
		LocalVector<Ref<StandardMaterial3D>> atlas_materials;
		for (const BuildJob::Atlas &atlas : job->atlases) {
			atlas_materials.push_back(HLODMaterialAtlas::create_material(atlas.material_template, atlas.image));
		}
		result.instantiate();
		for (const BuildJob::ResultSurface &surface : job->result_surfaces) {
			result->add_surface_from_arrays(Mesh::PRIMITIVE_TRIANGLES, surface.arrays);
			result->surface_set_material(result->get_surface_count() - 1, surface.atlas >= 0 ? Ref<Material>(atlas_materials[surface.atlas]) : surface.material);
		}
	}

	memdelete(job);
	job = nullptr;

	if (err == OK) {
		set_proxy_mesh(result);
	}
	return err;
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
		// A cluster that is the root of its own scene (e.g. while importing) owns the nodes below it.
		Node *scene_owner = get_owner();
		if (!scene_owner && (!get_parent() || (is_inside_tree() && get_tree()->get_edited_scene_root() == this))) {
			scene_owner = this;
		}
		if (scene_owner) {
			cell_cluster->set_owner(scene_owner);
		}

		// The cell is a pure translation, so the objects keep their place by subtracting its offset.
		for (Node3D *child : cells[cell]) {
			const Vector3 position = child->get_position();
			_move_node_keeping_owner(child, cell_cluster);
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
	ClassDB::bind_method(D_METHOD("set_remove_hidden_faces", "enabled"), &HLODCluster3D::set_remove_hidden_faces);
	ClassDB::bind_method(D_METHOD("get_remove_hidden_faces"), &HLODCluster3D::get_remove_hidden_faces);
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
	ClassDB::bind_method(D_METHOD("generate_proxy_async"), &HLODCluster3D::generate_proxy_async);
	ClassDB::bind_method(D_METHOD("is_generating"), &HLODCluster3D::is_generating);
	ClassDB::bind_method(D_METHOD("get_generation_progress"), &HLODCluster3D::get_generation_progress);
	ClassDB::bind_method(D_METHOD("get_generation_status"), &HLODCluster3D::get_generation_status);
	ClassDB::bind_method(D_METHOD("cancel_generation"), &HLODCluster3D::cancel_generation);
	ClassDB::bind_method(D_METHOD("finish_generation"), &HLODCluster3D::finish_generation);
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
	ADD_PROPERTY(PropertyInfo(Variant::BOOL, "remove_hidden_faces"), "set_remove_hidden_faces", "get_remove_hidden_faces");
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

HLODCluster3D::~HLODCluster3D() {
	if (job) {
		job->cancel.set();
		if (job->thread.is_started()) {
			job->thread.wait_to_finish();
		}
		memdelete(job);
	}
}

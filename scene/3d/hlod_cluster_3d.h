/**************************************************************************/
/*  hlod_cluster_3d.h                                                     */
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

#pragma once

#include "scene/3d/mesh_instance_3d.h"
#include "scene/3d/node_3d.h"

class HLODCluster3D : public Node3D {
	GDCLASS(HLODCluster3D, Node3D);

public:
	// Mirrors GeometryInstance3D::VisibilityRangeFadeMode so the enum is shared with the existing visibility range API.
	using FadeMode = GeometryInstance3D::VisibilityRangeFadeMode;

private:
	float switch_distance = 50.0f;
	float switch_margin = 5.0f;
	FadeMode fade_mode = GeometryInstance3D::VISIBILITY_RANGE_FADE_DISABLED;
	float simplify_ratio = 0.25f;
	float simplify_error = 0.1f;
	bool merge_materials = true;
	bool remove_hidden_faces = true;
	int atlas_cell_size = 128;
	Ref<Mesh> proxy_mesh;

	String detail_scene_path;
	float stream_load_margin = 25.0f;
	float stream_unload_margin = 50.0f;
	enum StreamState {
		STREAM_UNLOADED,
		STREAM_LOADING,
		STREAM_LOADED,
		STREAM_FAILED,
	};
	StreamState stream_state = STREAM_UNLOADED;
	ObjectID detail_id;
	float stream_timer = 0.0f;

	MeshInstance3D *proxy = nullptr;
	LocalVector<ObjectID> linked_ids;
	bool relink_queued = false;

	// Gathers the geometry that belongs to this cluster. Nested clusters manage their own geometry: their proxies are
	// reported in `r_nested_proxies`, and their geometry is only reported when `p_descend_nested` is set (used for merging).
	void _collect_geometry(Node *p_node, LocalVector<GeometryInstance3D *> &r_geometry, LocalVector<GeometryInstance3D *> *r_nested_proxies, bool p_descend_nested) const;
	void _update_proxy();
	void _link_children();
	void _unlink_children();
	void _queue_relink();
	bool _get_relative_transform(Node3D *p_node, Transform3D &r_xform) const;

	// Generating a proxy is split in a part that reads the scene (on the calling thread) and a part that
	// only works on the gathered data, which can run on a worker thread.
	struct BuildJob;
	BuildJob *job = nullptr;
	Error _start_job(bool p_threaded);
	static void _run_job(void *p_job);
	static void _cull_hidden_faces(BuildJob *p_job, LocalVector<Array> &r_arrays, const LocalVector<bool> &p_occluders);

protected:
	void _notification(int p_what);
	static void _bind_methods();

public:
	void set_switch_distance(float p_distance);
	float get_switch_distance() const;

	void set_switch_margin(float p_margin);
	float get_switch_margin() const;

	void set_fade_mode(FadeMode p_mode);
	FadeMode get_fade_mode() const;

	void set_simplify_ratio(float p_ratio);
	float get_simplify_ratio() const;

	void set_simplify_error(float p_error);
	float get_simplify_error() const;

	void set_merge_materials(bool p_enabled);
	bool get_merge_materials() const;

	void set_atlas_cell_size(int p_size);
	int get_atlas_cell_size() const;

	void set_detail_scene_path(const String &p_path);
	String get_detail_scene_path() const;

	void set_stream_load_margin(float p_margin);
	float get_stream_load_margin() const;

	void set_stream_unload_margin(float p_margin);
	float get_stream_unload_margin() const;

	void set_remove_hidden_faces(bool p_enabled);
	bool get_remove_hidden_faces() const;

	void set_proxy_mesh(const Ref<Mesh> &p_mesh);
	Ref<Mesh> get_proxy_mesh() const;

	Error generate_proxy();
	Error generate_proxy_async();
	bool is_generating() const;
	float get_generation_progress() const;
	String get_generation_status() const;
	void cancel_generation();
	Error finish_generation();
	Error build_grid(float p_cell_size);
	Error store_detail_scene(const String &p_path);
	void update_streaming();
	void clear_proxy();
	void update_children();

	PackedStringArray get_configuration_warnings() const override;

	HLODCluster3D();
	~HLODCluster3D();
};

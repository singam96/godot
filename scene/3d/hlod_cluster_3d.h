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
	Ref<Mesh> proxy_mesh;

	MeshInstance3D *proxy = nullptr;
	LocalVector<ObjectID> linked_ids;
	bool relink_queued = false;

	// Gathers the geometry that belongs to this cluster. Nested clusters manage their own geometry: their proxies are
	// reported in `r_nested_proxies`, and their geometry is only reported when `p_descend_nested` is set (used for merging).
	void _collect_geometry(Node *p_node, LocalVector<GeometryInstance3D *> &r_geometry, LocalVector<GeometryInstance3D *> *r_nested_proxies, bool p_descend_nested) const;
	void _collect_meshes(LocalVector<MeshInstance3D *> &r_meshes) const;
	void _update_proxy();
	void _link_children();
	void _unlink_children();
	void _queue_relink();

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

	void set_proxy_mesh(const Ref<Mesh> &p_mesh);
	Ref<Mesh> get_proxy_mesh() const;

	Error generate_proxy();
	void clear_proxy();
	void update_children();

	PackedStringArray get_configuration_warnings() const override;

	HLODCluster3D();
};

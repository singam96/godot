/**************************************************************************/
/*  test_hlod_cluster_3d.cpp                                              */
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

#include "tests/test_macros.h"

TEST_FORCE_LINK(test_hlod_cluster_3d)

#ifndef _3D_DISABLED

#include "scene/3d/hlod_cluster_3d.h"
#include "scene/3d/mesh_instance_3d.h"
#include "scene/main/scene_tree.h"
#include "scene/main/window.h"
#include "scene/resources/3d/primitive_meshes.h"
#include "scene/resources/material.h"
#include "scene/resources/surface_tool.h"

namespace TestHLODCluster3D {

static int _index_count(const Ref<Mesh> &p_mesh) {
	int count = 0;
	for (int i = 0; i < p_mesh->get_surface_count(); i++) {
		PackedInt32Array indices = p_mesh->surface_get_arrays(i)[Mesh::ARRAY_INDEX];
		count += indices.size();
	}
	return count;
}

static MeshInstance3D *_add_sphere(HLODCluster3D *p_cluster, const Vector3 &p_position, const Ref<Material> &p_material = Ref<Material>()) {
	Ref<SphereMesh> sphere;
	sphere.instantiate();
	sphere->set_radial_segments(32);
	sphere->set_rings(16);
	MeshInstance3D *instance = memnew(MeshInstance3D);
	instance->set_mesh(sphere);
	instance->set_material_override(p_material);
	instance->set_position(p_position);
	p_cluster->add_child(instance);
	return instance;
}

TEST_CASE("[SceneTree][HLODCluster3D] Property clamping") {
	HLODCluster3D *cluster = memnew(HLODCluster3D);

	cluster->set_switch_distance(0.0f);
	CHECK(cluster->get_switch_distance() > 0.0f);
	cluster->set_switch_margin(-3.0f);
	CHECK(cluster->get_switch_margin() == 0.0f);
	cluster->set_simplify_ratio(5.0f);
	CHECK(cluster->get_simplify_ratio() == 1.0f);
	cluster->set_simplify_ratio(0.0f);
	CHECK(cluster->get_simplify_ratio() > 0.0f);

	memdelete(cluster);
}

TEST_CASE("[SceneTree][HLODCluster3D] Generating the proxy mesh") {
	HLODCluster3D *cluster = memnew(HLODCluster3D);
	_add_sphere(cluster, Vector3(0, 0, 0));
	_add_sphere(cluster, Vector3(3, 0, 0));
	_add_sphere(cluster, Vector3(0, 0, 3));
	SceneTree::get_singleton()->get_root()->add_child(cluster);

	Ref<SphereMesh> reference;
	reference.instantiate();
	reference->set_radial_segments(32);
	reference->set_rings(16);
	const int source_index_count = _index_count(reference) * 3;

	SUBCASE("Without simplification all source geometry is merged") {
		cluster->set_simplify_ratio(1.0f);
		CHECK(cluster->generate_proxy() == OK);
		REQUIRE(cluster->get_proxy_mesh().is_valid());
		CHECK(cluster->get_proxy_mesh()->get_surface_count() == 1);
		CHECK(_index_count(cluster->get_proxy_mesh()) == source_index_count);
	}

	SUBCASE("Simplification reduces the triangle count") {
		REQUIRE(SurfaceTool::simplify_func != nullptr);
		cluster->set_simplify_ratio(0.25f);
		CHECK(cluster->generate_proxy() == OK);
		REQUIRE(cluster->get_proxy_mesh().is_valid());
		const int proxy_index_count = _index_count(cluster->get_proxy_mesh());
		CHECK(proxy_index_count > 0);
		CHECK(proxy_index_count % 3 == 0);
		CHECK(proxy_index_count < source_index_count);
	}

	SUBCASE("Clearing the proxy removes the mesh") {
		cluster->set_simplify_ratio(1.0f);
		REQUIRE(cluster->generate_proxy() == OK);
		cluster->clear_proxy();
		CHECK(cluster->get_proxy_mesh().is_null());
	}

	SceneTree::get_singleton()->get_root()->remove_child(cluster);
	memdelete(cluster);
}

TEST_CASE("[SceneTree][HLODCluster3D] Surfaces are batched per material") {
	Ref<StandardMaterial3D> red;
	red.instantiate();
	red->set_albedo(Color(1, 0, 0));
	Ref<StandardMaterial3D> blue;
	blue.instantiate();
	blue->set_albedo(Color(0, 0, 1));

	HLODCluster3D *cluster = memnew(HLODCluster3D);
	_add_sphere(cluster, Vector3(0, 0, 0), red);
	_add_sphere(cluster, Vector3(3, 0, 0), red);
	_add_sphere(cluster, Vector3(0, 0, 3), blue);
	SceneTree::get_singleton()->get_root()->add_child(cluster);

	cluster->set_simplify_ratio(1.0f);
	REQUIRE(cluster->generate_proxy() == OK);
	Ref<Mesh> proxy = cluster->get_proxy_mesh();
	REQUIRE(proxy.is_valid());
	CHECK(proxy->get_surface_count() == 2);
	CHECK(proxy->surface_get_material(0) == red);
	CHECK(proxy->surface_get_material(1) == blue);

	SceneTree::get_singleton()->get_root()->remove_child(cluster);
	memdelete(cluster);
}

TEST_CASE("[SceneTree][HLODCluster3D] Nested clusters") {
	HLODCluster3D *outer = memnew(HLODCluster3D);
	HLODCluster3D *inner = memnew(HLODCluster3D);
	outer->add_child(inner);
	_add_sphere(outer, Vector3(0, 0, 0));
	_add_sphere(inner, Vector3(3, 0, 0));
	_add_sphere(inner, Vector3(0, 0, 3));
	SceneTree::get_singleton()->get_root()->add_child(outer);

	Ref<SphereMesh> reference;
	reference.instantiate();
	reference->set_radial_segments(32);
	reference->set_rings(16);

	SUBCASE("The outer proxy merges the geometry of nested clusters") {
		outer->set_simplify_ratio(1.0f);
		REQUIRE(outer->generate_proxy() == OK);
		CHECK(_index_count(outer->get_proxy_mesh()) == _index_count(reference) * 3);
	}

	SUBCASE("The inner proxy only merges its own geometry") {
		inner->set_simplify_ratio(1.0f);
		REQUIRE(inner->generate_proxy() == OK);
		CHECK(_index_count(inner->get_proxy_mesh()) == _index_count(reference) * 2);
		CHECK(outer->get_proxy_mesh().is_null());
	}

	SceneTree::get_singleton()->get_root()->remove_child(outer);
	memdelete(outer);
}

TEST_CASE("[SceneTree][HLODCluster3D] Building a grid") {
	HLODCluster3D *cluster = memnew(HLODCluster3D);
	cluster->set_simplify_ratio(1.0f);
	cluster->set_switch_distance(80.0f);
	_add_sphere(cluster, Vector3(1, 0, 1));
	_add_sphere(cluster, Vector3(2, 0, 2));
	_add_sphere(cluster, Vector3(25, 0, 1));
	_add_sphere(cluster, Vector3(26, 0, 2));
	_add_sphere(cluster, Vector3(60, 0, 1));
	SceneTree::get_singleton()->get_root()->add_child(cluster);

	Ref<SphereMesh> reference;
	reference.instantiate();
	reference->set_radial_segments(32);
	reference->set_rings(16);

	ERR_PRINT_OFF;
	CHECK(cluster->build_grid(0.0f) == ERR_INVALID_PARAMETER);
	ERR_PRINT_ON;

	REQUIRE(cluster->build_grid(20.0f) == OK);

	// Three occupied cells: x in [0, 20), [20, 40) and [60, 80).
	CHECK(cluster->get_child_count(false) == 3);
	int total = 0;
	for (int i = 0; i < cluster->get_child_count(false); i++) {
		HLODCluster3D *cell = Object::cast_to<HLODCluster3D>(cluster->get_child(i, false));
		REQUIRE(cell != nullptr);
		CHECK(cell->get_switch_distance() == doctest::Approx(40.0f));
		REQUIRE(cell->get_proxy_mesh().is_valid());
		total += cell->get_child_count(false);
	}
	CHECK(total == 5);
	REQUIRE(cluster->get_proxy_mesh().is_valid());
	CHECK(_index_count(cluster->get_proxy_mesh()) == _index_count(reference) * 5);

	// Reparenting keeps the global transform of the objects.
	MeshInstance3D *moved = nullptr;
	for (int i = 0; i < cluster->get_child_count(false) && !moved; i++) {
		Node *cell = cluster->get_child(i, false);
		for (int j = 0; j < cell->get_child_count(false); j++) {
			MeshInstance3D *candidate = Object::cast_to<MeshInstance3D>(cell->get_child(j, false));
			if (candidate && Math::is_equal_approx(candidate->get_global_position().x, 60.0f)) {
				moved = candidate;
				break;
			}
		}
	}
	CHECK(moved != nullptr);

	SceneTree::get_singleton()->get_root()->remove_child(cluster);
	memdelete(cluster);
}

TEST_CASE("[SceneTree][HLODCluster3D] Generating without geometry fails") {
	HLODCluster3D *cluster = memnew(HLODCluster3D);
	SceneTree::get_singleton()->get_root()->add_child(cluster);

	ERR_PRINT_OFF;
	CHECK(cluster->generate_proxy() == ERR_DOES_NOT_EXIST);
	ERR_PRINT_ON;
	CHECK(cluster->get_proxy_mesh().is_null());

	SceneTree::get_singleton()->get_root()->remove_child(cluster);
	memdelete(cluster);
}

} // namespace TestHLODCluster3D

#endif // _3D_DISABLED

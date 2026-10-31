/**************************************************************************/
/*  multimesh_cull.cpp                                                    */
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

#include "multimesh_cull.h"

#include "core/config/project_settings.h"
#include "servers/rendering/renderer_rd/uniform_set_cache_rd.h"

using namespace RendererRD;

MultiMeshCull::MultiMeshCull() {
	Vector<String> modes;
	modes.push_back("\n#define MODE_CULL\n");
	modes.push_back("\n#define MODE_FINALIZE\n");
	shader.initialize(modes);
	shader_version = shader.version_create();
	for (int i = 0; i < MODE_MAX; i++) {
		pipelines[i] = RD::get_singleton()->compute_pipeline_create(shader.version_get_shader(shader_version, i));
	}
}

MultiMeshCull::~MultiMeshCull() {
	for (KeyValue<uint64_t, Slot> &E : slots) {
		_free_slot(E.value);
	}
	shader.version_free(shader_version);
}

void MultiMeshCull::_free_slot(Slot &p_slot) {
	RD *rd = RD::get_singleton();
	for (RID *rid : { &p_slot.buffer, &p_slot.state, &p_slot.commands, &p_slot.params }) {
		if (rid->is_valid()) {
			rd->free_rid(*rid);
			*rid = RID();
		}
	}
}

void MultiMeshCull::sweep(uint64_t p_frame) {
	Vector<uint64_t> stale;
	for (KeyValue<uint64_t, Slot> &E : slots) {
		if (p_frame - E.value.last_used > 120) {
			stale.push_back(E.key);
		}
	}
	for (const uint64_t &key : stale) {
		_free_slot(slots[key]);
		slots.erase(key);
	}
}

bool MultiMeshCull::cull(uint32_t p_slot, RID p_multimesh, RID p_source_buffer, uint32_t p_stride_floats, uint32_t p_instance_count, const Vector<uint32_t> &p_index_counts, const Transform3D &p_owner_transform, const Vector3 &p_sphere_center, float p_sphere_radius, const Plane *p_frustum_planes, uint64_t p_frame, Result &r_result) {
	ERR_FAIL_COND_V(p_instance_count == 0 || p_index_counts.is_empty(), false);
	RD *rd = RD::get_singleton();
	const uint32_t surface_count = p_index_counts.size();
	const uint32_t stride_vec4 = p_stride_floats / 4;
	const uint64_t data_size = uint64_t(p_instance_count) * p_stride_floats * sizeof(float);

	Slot &slot = slots[(p_multimesh.get_id() << 2) | uint64_t(p_slot & 3)];
	slot.last_used = p_frame;

	// The compacted buffer must be able to hold every instance of the source.
	const bool rebuild = slot.source != p_source_buffer || slot.instance_capacity < p_instance_count || slot.stride_floats != p_stride_floats || slot.index_counts.size() != int(surface_count);
	if (rebuild) {
		_free_slot(slot);
		slot.source = p_source_buffer;
		slot.instance_capacity = p_instance_count;
		slot.stride_floats = p_stride_floats;

		Vector<uint8_t> zeros;
		zeros.resize_initialized(data_size);
		slot.buffer = rd->storage_buffer_create(data_size, zeros);

		Vector<uint8_t> state_data;
		state_data.resize_initialized(sizeof(uint32_t));
		slot.state = rd->storage_buffer_create(sizeof(uint32_t), state_data);

		slot.index_counts.clear();
		slot.index_counts.resize(surface_count);
		Vector<uint8_t> commands;
		commands.resize_initialized(surface_count * 5 * sizeof(uint32_t));
		slot.commands = rd->storage_buffer_create(commands.size(), commands, RD::STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT);
		for (uint32_t i = 0; i < surface_count; i++) {
			slot.index_counts.write[i] = 0;
		}

		slot.params = rd->uniform_buffer_create(sizeof(Params));
	}

	// Index counts of the surfaces (they can change when the mesh does).
	for (uint32_t i = 0; i < surface_count; i++) {
		if (slot.index_counts[i] != p_index_counts[i]) {
			slot.index_counts.write[i] = p_index_counts[i];
			uint32_t command[5] = { p_index_counts[i], 0, 0, 0, 0 };
			rd->buffer_update(slot.commands, i * sizeof(command), sizeof(uint32_t), command);
		}
	}

	Params params = {};
	for (int i = 0; i < 6; i++) {
		params.planes[i][0] = p_frustum_planes[i].normal.x;
		params.planes[i][1] = p_frustum_planes[i].normal.y;
		params.planes[i][2] = p_frustum_planes[i].normal.z;
		params.planes[i][3] = p_frustum_planes[i].d;
	}
	for (int row = 0; row < 3; row++) {
		params.owner_rows[row][0] = p_owner_transform.basis.rows[row][0];
		params.owner_rows[row][1] = p_owner_transform.basis.rows[row][1];
		params.owner_rows[row][2] = p_owner_transform.basis.rows[row][2];
		params.owner_rows[row][3] = p_owner_transform.origin[row];
	}
	params.sphere[0] = p_sphere_center.x;
	params.sphere[1] = p_sphere_center.y;
	params.sphere[2] = p_sphere_center.z;
	params.sphere[3] = p_sphere_radius;
	params.instance_count = p_instance_count;
	params.stride_vec4 = stride_vec4;
	params.surface_count = surface_count;
	rd->buffer_update(slot.params, 0, sizeof(Params), &params);
	rd->buffer_clear(slot.state, 0, sizeof(uint32_t));

	RD::Uniform u_source(RD::UNIFORM_TYPE_STORAGE_BUFFER, 0, slot.source);
	RD::Uniform u_dest(RD::UNIFORM_TYPE_STORAGE_BUFFER, 1, slot.buffer);
	RD::Uniform u_state(RD::UNIFORM_TYPE_STORAGE_BUFFER, 2, slot.state);
	RD::Uniform u_commands(RD::UNIFORM_TYPE_STORAGE_BUFFER, 3, slot.commands);
	RD::Uniform u_params(RD::UNIFORM_TYPE_UNIFORM_BUFFER, 4, slot.params);

	{
		RID set = UniformSetCacheRD::get_singleton()->get_cache(shader.version_get_shader(shader_version, MODE_CULL), 0, u_source, u_dest, u_state, u_commands, u_params);
		RD::ComputeListID cl = rd->compute_list_begin();
		rd->compute_list_bind_compute_pipeline(cl, pipelines[MODE_CULL]);
		rd->compute_list_bind_uniform_set(cl, set, 0);
		rd->compute_list_dispatch_threads(cl, p_instance_count, 1, 1);
		rd->compute_list_end();
	}
	{
		RID set = UniformSetCacheRD::get_singleton()->get_cache(shader.version_get_shader(shader_version, MODE_FINALIZE), 0, u_source, u_dest, u_state, u_commands, u_params);
		RD::ComputeListID cl = rd->compute_list_begin();
		rd->compute_list_bind_compute_pipeline(cl, pipelines[MODE_FINALIZE]);
		rd->compute_list_bind_uniform_set(cl, set, 0);
		rd->compute_list_dispatch_threads(cl, surface_count, 1, 1);
		rd->compute_list_end();
	}

	r_result.buffer = slot.buffer;
	r_result.command_buffer = slot.commands;
	return true;
}

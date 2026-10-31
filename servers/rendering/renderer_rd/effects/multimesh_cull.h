/**************************************************************************/
/*  multimesh_cull.h                                                      */
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

#include "core/math/plane.h"
#include "core/math/transform_3d.h"
#include "core/templates/hash_map.h"
#include "servers/rendering/renderer_rd/shaders/effects/multimesh_cull.glsl.gen.h"

namespace RendererRD {

// Per instance frustum culling of a MultiMesh on the GPU. The visible instances are copied to a second buffer
// with the same layout as the MultiMesh's own, and the number of them is written into indirect draw commands.
// The draw then needs no shader change: it binds the second buffer where the first one would have been.
class MultiMeshCull {
public:
	struct Result {
		RID buffer; // Compacted instance data.
		RID command_buffer; // One indirect draw command per surface of the mesh.
	};

private:
	enum Mode {
		MODE_CULL,
		MODE_FINALIZE,
		MODE_MAX
	};

	struct Params {
		float planes[6][4];
		float owner_rows[3][4];
		float sphere[4];
		uint32_t instance_count;
		uint32_t stride_vec4;
		uint32_t surface_count;
		uint32_t pad;
	};

	struct Slot {
		RID source;
		RID buffer;
		RID state;
		RID commands;
		RID params;
		uint32_t instance_capacity = 0;
		uint32_t stride_floats = 0;
		Vector<uint32_t> index_counts;
		uint64_t last_used = 0;
	};

	MultimeshCullShaderRD shader;
	RID shader_version;
	RID pipelines[MODE_MAX];
	HashMap<uint64_t, Slot> slots;

	void _free_slot(Slot &p_slot);

public:
	MultiMeshCull();
	~MultiMeshCull();

	// Frees the data of MultiMeshes that have not been culled for a while.
	void sweep(uint64_t p_frame);

	// Queues the culling of one MultiMesh. p_index_counts has one entry per surface.
	// p_slot separates the copies that are alive at the same time (main view, shadow passes).
	bool cull(uint32_t p_slot, RID p_multimesh, RID p_source_buffer, uint32_t p_stride_floats, uint32_t p_instance_count, const Vector<uint32_t> &p_index_counts, const Transform3D &p_owner_transform, const Vector3 &p_sphere_center, float p_sphere_radius, const Plane *p_frustum_planes, uint64_t p_frame, Result &r_result);
};

} // namespace RendererRD

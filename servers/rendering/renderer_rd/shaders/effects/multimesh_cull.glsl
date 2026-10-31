#[compute]

#version 450

#VERSION_DEFINES

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Source {
	vec4 data[];
}
source;

layout(set = 0, binding = 1, std430) restrict writeonly buffer Dest {
	vec4 data[];
}
dest;

layout(set = 0, binding = 2, std430) restrict buffer State {
	uint count;
}
state;

// One VkDrawIndexedIndirectCommand per mesh surface: indexCount, instanceCount, firstIndex, vertexOffset, firstInstance.
layout(set = 0, binding = 3, std430) restrict buffer Commands {
	uint data[];
}
commands;

layout(set = 0, binding = 4, std140) uniform Params {
	vec4 planes[6]; // Frustum, normal and distance, outside is positive.
	vec4 owner_row0; // Transform of the MultiMesh node, rows of a 3x4 matrix.
	vec4 owner_row1;
	vec4 owner_row2;
	vec4 sphere; // Bounding sphere of one instance of the mesh, centre and radius.
	uint instance_count;
	uint stride_vec4; // Size of an instance in the buffer, in vec4.
	uint surface_count;
	uint pad;
}
params;

void main() {
#ifdef MODE_FINALIZE
	if (gl_GlobalInvocationID.x < params.surface_count) {
		commands.data[gl_GlobalInvocationID.x * 5u + 1u] = state.count;
	}
#endif

#ifdef MODE_CULL
	uint index = gl_GlobalInvocationID.x;
	if (index >= params.instance_count) {
		return;
	}

	uint base = index * params.stride_vec4;
	vec4 r0 = source.data[base + 0u];
	vec4 r1 = source.data[base + 1u];
	vec4 r2 = source.data[base + 2u];

	// Centre of the instance's bounding sphere in the MultiMesh's space, then in world space.
	vec3 c = params.sphere.xyz;
	vec3 local_center = vec3(dot(r0.xyz, c) + r0.w, dot(r1.xyz, c) + r1.w, dot(r2.xyz, c) + r2.w);
	vec3 o0 = params.owner_row0.xyz;
	vec3 o1 = params.owner_row1.xyz;
	vec3 o2 = params.owner_row2.xyz;
	vec3 world_center = vec3(dot(o0, local_center) + params.owner_row0.w, dot(o1, local_center) + params.owner_row1.w, dot(o2, local_center) + params.owner_row2.w);

	// Largest scale of the combined transform.
	vec3 col0 = vec3(r0.x, r1.x, r2.x);
	vec3 col1 = vec3(r0.y, r1.y, r2.y);
	vec3 col2 = vec3(r0.z, r1.z, r2.z);
	float s0 = length(vec3(dot(o0, col0), dot(o1, col0), dot(o2, col0)));
	float s1 = length(vec3(dot(o0, col1), dot(o1, col1), dot(o2, col1)));
	float s2 = length(vec3(dot(o0, col2), dot(o1, col2), dot(o2, col2)));
	float radius = params.sphere.w * max(s0, max(s1, s2)) * 1.02 + 0.01;

	for (int i = 0; i < 6; i++) {
		if (dot(params.planes[i].xyz, world_center) - params.planes[i].w > radius) {
			return;
		}
	}

	uint slot = atomicAdd(state.count, 1u);
	uint dst = slot * params.stride_vec4;
	for (uint k = 0u; k < params.stride_vec4; k++) {
		dest.data[dst + k] = source.data[base + k];
	}
#endif
}

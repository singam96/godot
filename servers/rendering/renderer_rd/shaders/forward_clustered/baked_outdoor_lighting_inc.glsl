// Immutable directional visibility plus spatial sky-visibility fields. Only the
// page table, bracket and weather gains change at runtime; no shadows are baked.
layout(set = 1, binding = 39) uniform texture2DArray outdoor_coarse_depth;
layout(set = 1, binding = 40) uniform texture2DArray outdoor_fine_depth;
layout(set = 1, binding = 41) uniform texture2D outdoor_coarse_ambient;
layout(set = 1, binding = 42) uniform texture2DArray outdoor_fine_ambient;
layout(set = 1, binding = 43, std430) restrict readonly buffer OutdoorLighting {
	uvec4 info; // enabled, directional index, static receiver mask, moving mask
	vec4 parameters[20];
	int pages[];
}
outdoor_lighting;

bool baked_outdoor_receiver(uint instance_idx) {
	return outdoor_lighting.info.x != 0u &&
			(instances.data[instance_idx].layer_mask & outdoor_lighting.info.z) != 0u &&
			(instances.data[instance_idx].layer_mask & outdoor_lighting.info.w) == 0u &&
			(instances.data[instance_idx].flags & INSTANCE_FLAGS_USE_LIGHTMAP) == 0u;
}

bool baked_outdoor_sun(uint light_idx) {
	return outdoor_lighting.info.x != 0u && outdoor_lighting.info.y == light_idx;
}

bool baked_outdoor_ambient_receiver(uint instance_idx) {
#if defined(CUSTOM_IRRADIANCE_USED) || defined(AMBIENT_LIGHT_DISABLED)
	return false;
#else
	uint gi_flags = INSTANCE_FLAGS_USE_LIGHTMAP | INSTANCE_FLAGS_USE_LIGHTMAP_CAPTURE | INSTANCE_FLAGS_USE_VOXEL_GI | INSTANCE_FLAGS_USE_SDFGI | INSTANCE_FLAGS_USE_GI_BUFFERS;
	return outdoor_lighting.info.x != 0u &&
			(instances.data[instance_idx].layer_mask & (outdoor_lighting.info.z | outdoor_lighting.info.w)) != 0u &&
			(instances.data[instance_idx].flags & gi_flags) == 0u;
#endif
}

float baked_outdoor_depth_compare(texture2DArray depth, vec2 uv, int layer, float reference, vec2 receiver_gradient) {
	ivec3 size = textureSize(sampler2DArray(depth, SAMPLER_NEAREST_CLAMP), 0);
	if (layer < 0 || layer >= size.z) {
		return 1.0;
	}
	vec2 position = uv * vec2(size.xy) - 0.5;
	ivec2 first = ivec2(floor(position));
	vec2 weight = fract(position);
	vec4 visibility;
	for (int tap = 0; tap < 4; tap++) {
		ivec2 at = clamp(first + ivec2(tap & 1, tap >> 1), ivec2(0), size.xy - 1);
		float stored = texelFetch(sampler2DArray(depth, SAMPLER_NEAREST_CLAMP), ivec3(at, layer), 0).r;
		vec2 tap_uv = (vec2(at) + 0.5) / vec2(size.xy);
		float receiver_depth = reference + dot(tap_uv - uv, receiver_gradient);
		visibility[tap] = receiver_depth >= stored ? 1.0 : 0.0;
	}
	return mix(mix(visibility.x, visibility.y, weight.x), mix(visibility.z, visibility.w, weight.x), weight.y);
}

float baked_outdoor_visibility(int sample_idx, vec3 world_position, vec3 world_normal) {
	int matrix_offset = sample_idx * 4;
	mat4 to_map = mat4(outdoor_lighting.parameters[matrix_offset], outdoor_lighting.parameters[matrix_offset + 1], outdoor_lighting.parameters[matrix_offset + 2], outdoor_lighting.parameters[matrix_offset + 3]);
	// Compare each tap at the receiver plane, rather than shifting an entire
	// surface far from its contact shadow to hide sloped-depth self-occlusion.
	vec3 plane_normal = transpose(inverse(mat3(to_map))) * world_normal;
	vec2 receiver_gradient = abs(plane_normal.z) > 0.00001 ? -plane_normal.xy / plane_normal.z : vec2(0.0);
	vec3 biased = world_position + world_normal * outdoor_lighting.parameters[12 + sample_idx].w;
	vec3 point = (to_map * vec4(biased, 1.0)).xyz;
	if (any(lessThan(point, vec3(0.0))) || any(greaterThanEqual(point, vec3(1.0)))) {
		return 1.0;
	}
	ivec2 grid = sample_idx == 0 ? ivec2(outdoor_lighting.parameters[15].xy) : ivec2(outdoor_lighting.parameters[15].zw);
	int offset = sample_idx == 0 ? 0 : int(outdoor_lighting.parameters[15].x * outdoor_lighting.parameters[15].y);
	vec2 tile_position = point.xy * vec2(grid);
	ivec2 tile = ivec2(floor(tile_position));
	int entry = offset + tile.y * grid.x + tile.x;
	int page = entry >= 0 && entry < 3072 ? outdoor_lighting.pages[entry] : -1;
	float reference = point.z + outdoor_lighting.parameters[14][sample_idx + 1];
	if (page >= 0 && page < textureSize(sampler2DArray(outdoor_fine_depth, SAMPLER_NEAREST_CLAMP), 0).z) {
		float border = outdoor_lighting.parameters[14].w;
		vec2 uv = fract(tile_position) * (1.0 - 2.0 * border) + border;
		return baked_outdoor_depth_compare(outdoor_fine_depth, uv, page, reference, receiver_gradient / (vec2(grid) * (1.0 - 2.0 * border)));
	}
	return baked_outdoor_depth_compare(outdoor_coarse_depth, point.xy, int(outdoor_lighting.parameters[10 + sample_idx].w), reference, receiver_gradient);
}

float baked_outdoor_actor_visibility(vec3 world_position, vec3 world_normal) {
	float blend = clamp(outdoor_lighting.parameters[14].x, 0.0, 1.0);
	vec3 gain = outdoor_lighting.parameters[16].rgb;
	float a = (1.0 - blend) * dot(max(outdoor_lighting.parameters[10].rgb * gain, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
	float b = blend * dot(max(outdoor_lighting.parameters[11].rgb * gain, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
	if (a + b < 0.000001) {
		return 1.0;
	}
	return (a * baked_outdoor_visibility(0, world_position, world_normal) + b * baked_outdoor_visibility(1, world_position, world_normal)) / (a + b);
}

vec3 baked_outdoor_solar_irradiance(vec3 world_position, vec3 world_normal, vec3 world_geo_normal, float moving_visibility, float opacity) {
	float blend = clamp(outdoor_lighting.parameters[14].x, 0.0, 1.0);
	vec3 total = vec3(0.0);
	for (int sample_idx = 0; sample_idx < 2; sample_idx++) {
		float weight = sample_idx == 0 ? 1.0 - blend : blend;
		vec3 radiance = outdoor_lighting.parameters[10 + sample_idx].rgb;
		float incidence = max(dot(world_normal, outdoor_lighting.parameters[12 + sample_idx].xyz), 0.0);
		float static_visibility = baked_outdoor_visibility(sample_idx, world_position, world_geo_normal);
		float visibility = 1.0;
#ifndef SHADOWS_DISABLED
		visibility = min(mix(1.0, static_visibility, clamp(outdoor_lighting.parameters[17].w, 0.0, 1.0)), mix(1.0, moving_visibility, opacity));
#endif
		total += weight * radiance * incidence * visibility;
	}
	return total * outdoor_lighting.parameters[16].rgb;
}

float baked_outdoor_sky_visibility(vec3 world_position) {
	if (outdoor_lighting.parameters[19].z < 0.5) {
		return 1.0;
	}
	vec2 uv = (world_position.xz - outdoor_lighting.parameters[18].xy) / outdoor_lighting.parameters[18].zw;
	if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) {
		return 1.0;
	}
	vec4 field = textureLod(sampler2D(outdoor_coarse_ambient, SAMPLER_LINEAR_CLAMP), uv, 0.0);
	ivec2 grid = ivec2(outdoor_lighting.parameters[19].xy);
	vec2 tile_position = uv * vec2(grid);
	ivec2 tile = ivec2(floor(tile_position));
	vec4 sun_grid = outdoor_lighting.parameters[15];
	int offset = int(sun_grid.x * sun_grid.y + sun_grid.z * sun_grid.w);
	int entry = offset + tile.y * grid.x + tile.x;
	int page = entry >= 0 && entry < 3072 ? outdoor_lighting.pages[entry] : -1;
	if (page >= 0 && page < textureSize(sampler2DArray(outdoor_fine_ambient, SAMPLER_LINEAR_CLAMP), 0).z) {
		float border = outdoor_lighting.parameters[19].w;
		vec2 local_uv = fract(tile_position) * (1.0 - 2.0 * border) + border;
		field = textureLod(sampler2DArray(outdoor_fine_ambient, SAMPLER_LINEAR_CLAMP), vec3(local_uv, float(page)), 0.0);
	}
	float height = world_position.y - field.r;
	if (height <= 0.5) {
		return clamp(field.g, 0.0, 1.0);
	} else if (height < 8.0) {
		return clamp(mix(field.g, field.b, (height - 0.5) / 7.5), 0.0, 1.0);
	} else if (height < 24.0) {
		return clamp(mix(field.b, field.a, (height - 8.0) / 16.0), 0.0, 1.0);
	}
	return clamp(mix(field.a, 1.0, clamp((height - 24.0) / 16.0, 0.0, 1.0)), 0.0, 1.0);
}

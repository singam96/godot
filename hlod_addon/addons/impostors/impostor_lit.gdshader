shader_type spatial;
render_mode cull_disabled, depth_draw_opaque, specular_disabled;

// Like impostor.gdshader, but lit: the baked object-space normals are turned into the instance's world space and fed
// to the engine's own lighting, so directional/omni/spot lights, shadows received from other objects, ambient light,
// global illumination and fog all apply. Diffuse only.

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_atlas : filter_linear_mipmap, repeat_disable;
uniform int views = 12;
uniform int rows = 2;
uniform float min_elevation = 0.17;
uniform float max_elevation = 0.96;
uniform vec3 center = vec3(0.0);
uniform vec4 tint : source_color = vec4(1.0);
uniform sampler2D extra_atlas : filter_linear_mipmap, repeat_disable;  // red: depth, green: ambient occlusion
uniform bool use_extra = false;
uniform bool vertex_depth = false;  // Push the (subdivided) quad's vertices to the baked surface.
uniform float depth_range = 1.0;
uniform float ao_strength = 1.0;
uniform float ao_light_affect = 0.4;

varying flat vec4 v_cell;
varying flat vec2 v_weight;
varying float v_push;  // How far the vertex was moved towards the camera, in world meters.

void vertex() {
	mat4 m = MODEL_MATRIX;
	float s = length(m[0].xyz);
	vec3 world_center = (m * vec4(center, 1.0)).xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world_pos = world_center + (right * VERTEX.x + up * VERTEX.y) * s;

	vec3 cam_local = (inverse(m) * vec4(INV_VIEW_MATRIX[3].xyz, 1.0)).xyz;
	vec3 d = cam_local - center;
	float n_views = float(views);
	float f = atan(d.x, d.z) / TAU * n_views;
	if (f < 0.0) {
		f += n_views;
	}
	float i0 = floor(f);
	float t = f - i0;
	float i1 = mod(i0 + 1.0, n_views);
	i0 = mod(i0, n_views);

	float j0 = 0.0;
	float j1 = 0.0;
	float u = 0.0;
	if (rows > 1) {
		float el = asin(clamp(d.y / max(length(d), 0.0001), -1.0, 1.0));
		float fe = clamp((el - min_elevation) / max(max_elevation - min_elevation, 0.0001), 0.0, 1.0) * float(rows - 1);
		j0 = min(floor(fe), float(rows - 2));
		j1 = j0 + 1.0;
		u = fe - j0;
	}
	v_cell = vec4(i0, i1, j0, j1);
	v_weight = vec2(t, u);

	v_push = 0.0;
	if (use_extra && vertex_depth) {
		// Where the surface really is at this vertex, for shadow lookups: the baked depth, blended like the colors.
		vec2 cells = vec2(float(views), float(rows));
		vec4 e00 = textureLod(extra_atlas, (vec2(i0, j0) + UV) / cells, 0.0);
		vec4 e10 = textureLod(extra_atlas, (vec2(i1, j0) + UV) / cells, 0.0);
		vec4 e01 = textureLod(extra_atlas, (vec2(i0, j1) + UV) / cells, 0.0);
		vec4 e11 = textureLod(extra_atlas, (vec2(i1, j1) + UV) / cells, 0.0);
		float cover00 = textureLod(atlas, (vec2(i0, j0) + UV) / cells, 0.0).a * (1.0 - t) * (1.0 - u);
		float cover10 = textureLod(atlas, (vec2(i1, j0) + UV) / cells, 0.0).a * t * (1.0 - u);
		float cover01 = textureLod(atlas, (vec2(i0, j1) + UV) / cells, 0.0).a * (1.0 - t) * u;
		float cover11 = textureLod(atlas, (vec2(i1, j1) + UV) / cells, 0.0).a * t * u;
		float cover = cover00 + cover10 + cover01 + cover11;
		if (cover > 0.5) {
			float depth = (e00.r * cover00 + e10.r * cover10 + e01.r * cover01 + e11.r * cover11) / cover;
			v_push = (depth - 0.5) * depth_range * s;
			vec3 to_camera = normalize(INV_VIEW_MATRIX[3].xyz - world_pos);
			world_pos += to_camera * v_push;
		}
	}
	// Lighting and shadows use VERTEX, so put the billboarded corner there (in model space; the engine transforms it).
	VERTEX = (inverse(m) * vec4(world_pos, 1.0)).xyz;
}

void fragment() {
	vec2 cells = vec2(float(views), float(rows));
	vec2 uv00 = (vec2(v_cell.x, v_cell.z) + UV) / cells;
	vec2 uv10 = (vec2(v_cell.y, v_cell.z) + UV) / cells;
	vec2 uv01 = (vec2(v_cell.x, v_cell.w) + UV) / cells;
	vec2 uv11 = (vec2(v_cell.y, v_cell.w) + UV) / cells;
	vec4 c00 = texture(atlas, uv00);
	vec4 c10 = texture(atlas, uv10);
	vec4 c01 = texture(atlas, uv01);
	vec4 c11 = texture(atlas, uv11);
	float t = v_weight.x;
	float u = v_weight.y;
	float w00 = (1.0 - t) * (1.0 - u) * c00.a;
	float w10 = t * (1.0 - u) * c10.a;
	float w01 = (1.0 - t) * u * c01.a;
	float w11 = t * u * c11.a;
	float a = w00 + w10 + w01 + w11;
	float inv = 1.0 / max(a, 0.0001);
	vec3 rgb = (c00.rgb * w00 + c10.rgb * w10 + c01.rgb * w01 + c11.rgb * w11) * inv;

	vec3 n = (texture(normal_atlas, uv00).xyz * w00 + texture(normal_atlas, uv10).xyz * w10
			+ texture(normal_atlas, uv01).xyz * w01 + texture(normal_atlas, uv11).xyz * w11) * inv;
	n = normalize(n * 2.0 - 1.0);
	vec3 world_n = normalize(mat3(MODEL_MATRIX) * n);

	ALBEDO = rgb * tint.rgb;
	ALPHA = a * tint.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
	if (use_extra) {
		vec4 x = (texture(extra_atlas, uv00) * w00 + texture(extra_atlas, uv10) * w10
				+ texture(extra_atlas, uv01) * w01 + texture(extra_atlas, uv11) * w11) * inv;
		float scale = length(MODEL_MATRIX[0].xyz);
		// The real depth buffer value of the surface this pixel shows, so that the impostor intersects other
		// geometry and other impostors correctly instead of being a flat plane.
		vec3 dir = normalize(VERTEX);
		vec3 exact = VERTEX + dir * v_push - dir * (x.r - 0.5) * depth_range * scale;
		vec4 clip = PROJECTION_MATRIX * vec4(exact, 1.0);
		DEPTH = clip.z / clip.w;
		AO = mix(1.0, x.g, ao_strength);
		AO_LIGHT_AFFECT = ao_light_affect;
	} else {
		DEPTH = FRAGCOORD.z;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(world_n, 0.0)).xyz);
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}

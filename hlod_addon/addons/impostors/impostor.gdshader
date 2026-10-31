shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Camera-facing impostor. The atlas holds `views` azimuth columns and `rows` elevation rows of the object, each
// rendered from outside; the two nearest views of each axis are blended. Instance scale is honored and the
// instance rotation picks the view, so one mesh and material serve a whole MultiMesh.

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform int views = 12;
uniform int rows = 2;
uniform float min_elevation = 0.17;
uniform float max_elevation = 0.96;
uniform vec3 center = vec3(0.0);
uniform vec4 tint : source_color = vec4(1.0);

varying flat vec4 v_cell;
varying flat vec2 v_weight;

void vertex() {
	mat4 m = MODEL_MATRIX;
	float s = length(m[0].xyz);
	vec3 world_center = (m * vec4(center, 1.0)).xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world_pos = world_center + (right * VERTEX.x + up * VERTEX.y) * s;
	// Lighting and shadows use VERTEX, so put the billboarded corner there (in model space; the engine transforms it).
	VERTEX = (inverse(m) * vec4(world_pos, 1.0)).xyz;

	// Direction from the object's center to the camera, in the object's own space.
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
}

void fragment() {
	vec2 cells = vec2(float(views), float(rows));
	vec4 c00 = texture(atlas, (vec2(v_cell.x, v_cell.z) + UV) / cells);
	vec4 c10 = texture(atlas, (vec2(v_cell.y, v_cell.z) + UV) / cells);
	vec4 c01 = texture(atlas, (vec2(v_cell.x, v_cell.w) + UV) / cells);
	vec4 c11 = texture(atlas, (vec2(v_cell.y, v_cell.w) + UV) / cells);
	float t = v_weight.x;
	float u = v_weight.y;
	float w00 = (1.0 - t) * (1.0 - u) * c00.a;
	float w10 = t * (1.0 - u) * c10.a;
	float w01 = (1.0 - t) * u * c01.a;
	float w11 = t * u * c11.a;
	float a = w00 + w10 + w01 + w11;
	vec3 rgb = (c00.rgb * w00 + c10.rgb * w10 + c01.rgb * w01 + c11.rgb * w11) / max(a, 0.0001);
	ALBEDO = rgb * tint.rgb;
	ALPHA = a * tint.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}

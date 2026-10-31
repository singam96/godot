shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

// Only drawn into shadow maps (the instance is "shadows only"), so INV_VIEW_MATRIX is the light's view here.
// The quad faces the light and shows the baked view that looks along it. If the impostor also receives shadows, it is
// moved back along the light ray (`shift`), behind the object's center, so that the impostor drawn for the camera (a
// flat quad through the center, facing the camera) doesn't land inside its own shadow. That also moves the shadow's
// lower part under the ground for objects that stand on it, which is why receiving shadows is optional.

uniform sampler2D atlas : source_color, filter_linear_mipmap, repeat_disable;
uniform int views = 12;
uniform int rows = 2;
uniform float min_elevation = 0.17;
uniform float max_elevation = 0.96;
uniform vec3 center = vec3(0.0);
uniform float quad_size = 1.0;
uniform float shift = 0.0;  // How far to move back along the ray, in quads. 0 unless the impostor receives shadows.

varying flat vec4 v_cell;
varying flat vec2 v_weight;

void vertex() {
	mat4 m = MODEL_MATRIX;
	float s = length(m[0].xyz);
	vec3 world_center = (m * vec4(center, 1.0)).xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 toward_light = INV_VIEW_MATRIX[2].xyz;
	vec3 world_pos = world_center + (right * VERTEX.x + up * VERTEX.y) * s - toward_light * quad_size * shift * s;
	// Lighting and shadows use VERTEX, so put the billboarded corner there (in model space; the engine transforms it).
	VERTEX = (inverse(m) * vec4(world_pos, 1.0)).xyz;

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
	float a00 = texture(atlas, (vec2(v_cell.x, v_cell.z) + UV) / cells).a;
	float a10 = texture(atlas, (vec2(v_cell.y, v_cell.z) + UV) / cells).a;
	float a01 = texture(atlas, (vec2(v_cell.x, v_cell.w) + UV) / cells).a;
	float a11 = texture(atlas, (vec2(v_cell.y, v_cell.w) + UV) / cells).a;
	float t = v_weight.x;
	float u = v_weight.y;
	ALBEDO = vec3(0.0);
	ALPHA = (1.0 - t) * (1.0 - u) * a00 + t * (1.0 - u) * a10 + (1.0 - t) * u * a01 + t * u * a11;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}

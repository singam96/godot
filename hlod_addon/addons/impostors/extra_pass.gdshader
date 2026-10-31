shader_type spatial;
render_mode cull_back, specular_disabled;

// Used only while baking. Draws, per pixel: red = depth of the surface relative to the object's center plane, green =
// ambient occlusion. The bake world has no lights, only white ambient light with SSAO on, so a green albedo makes the
// occluded ambient light appear in the green channel, and the depth goes into the red channel as emission.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_albedo_tex = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float alpha_cut = -1.0;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
uniform float center_distance = 1.0;  // Distance from the camera to the object's center plane.
uniform float depth_range = 1.0;      // Total depth that fits in 0..1 (2 x the bounding radius).

void fragment() {
	vec2 uv = UV * uv1_scale.xy + uv1_offset.xy;
	float a = albedo_color.a;
	if (use_albedo_tex) {
		a *= texture(albedo_tex, uv).a;
	}
	if (alpha_cut >= 0.0 && a < alpha_cut) {
		discard;
	}
	float offset = center_distance + VERTEX.z;  // VERTEX.z is negative in front of the camera.
	float t = clamp(offset / depth_range + 0.5, 0.0, 1.0);
	ALBEDO = vec3(0.0, 1.0, 0.0);
	EMISSION = vec3(t, 0.0, 0.0);
	ROUGHNESS = 1.0;
}

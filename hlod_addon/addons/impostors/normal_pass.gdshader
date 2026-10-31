shader_type spatial;
render_mode unshaded, cull_back;

// Used only while baking: draws the object's world-space normals as colors (n * 0.5 + 0.5), cutting out the same
// pixels as the original material does, so the normal atlas matches the color atlas.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_albedo_tex = false;
uniform vec4 albedo_color : source_color = vec4(1.0);
uniform float alpha_cut = -1.0;
uniform vec3 uv1_scale = vec3(1.0);
uniform vec3 uv1_offset = vec3(0.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_normal_tex = false;
uniform float normal_scale = 1.0;

void fragment() {
	vec2 uv = UV * uv1_scale.xy + uv1_offset.xy;
	float a = albedo_color.a;
	if (use_albedo_tex) {
		a *= texture(albedo_tex, uv).a;
	}
	if (alpha_cut >= 0.0 && a < alpha_cut) {
		discard;
	}
	vec3 n = NORMAL;
	if (use_normal_tex && length(TANGENT) > 0.1) {
		vec3 nm = texture(normal_tex, uv).xyz * 2.0 - 1.0;
		nm.xy *= normal_scale;
		n = normalize(mat3(TANGENT, BINORMAL, NORMAL) * nm);
	}
	vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(n, 0.0)).xyz);
	ALBEDO = world_n * 0.5 + 0.5;
}

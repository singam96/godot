extends SceneTree
## Compiles the actual native helper and both actual call sites before a rebuild.
## Run with --path hlod_addon --rendering-method forward_plus -s res://tests/run_directional_shadow_shader_tests.gd


func _initialize() -> void:
	var base := ProjectSettings.globalize_path("res://").path_join("../servers/rendering/renderer_rd/shaders").simplify_path()
	var scene := FileAccess.get_file_as_string(base.path_join("forward_clustered/scene_forward_clustered.glsl"))
	var types := FileAccess.get_file_as_string(base.path_join("light_data_inc.glsl"))
	if not scene.contains("float light_get_directional_shadow") or not types.contains("struct DirectionalLightData"):
		printerr("DIRECTIONAL_SHADOW_SOURCE_NOT_FOUND")
		quit(2)
		return
	var helper := "float light_get_directional_shadow" + scene.split("float light_get_directional_shadow", true, 1)[1].split("\n}\n", true, 1)[0] + "\n}\n"
	var directional_type := "struct DirectionalLightData" + types.split("struct DirectionalLightData", true, 1)[1].split("\n};", true, 1)[0] + "\n};\n"
	var pattern := RegEx.new()
	pattern.compile("float shadow = light_get_directional_shadow\\([\\s\\S]*?\\);")
	var calls := pattern.search_all(scene)
	if calls.size() != 2:
		printerr("DIRECTIONAL_SHADOW_EXPECTED_TWO_CALL_SITES count=", calls.size())
		quit(1)
		return
	# Keep native field and argument types. Sampling stubs isolate shader interface
	# compilation; the rendered baked-direct fixture checks the complete pipeline.
	var declarations := """
#define ViewIndex 0
#define LIGHTMAP_SHADOWMASK_MODE_NONE 0
#define LIGHTMAP_SHADOWMASK_MODE_REPLACE 1
#define LIGHTMAP_SHADOWMASK_MODE_OVERLAY 2
#define SCREEN_SPACE_EFFECTS_FLAGS_USE_SSCS 1
layout(set=0,binding=0,std140) uniform DirectionalLights {DirectionalLightData data[8];} directional_lights;
layout(set=0,binding=1) uniform texture2D directional_shadow_atlas;
layout(set=0,binding=2) uniform sampler SAMPLER_LINEAR_CLAMP;
layout(set=0,binding=3) uniform texture2DArray sscs_buffer;
layout(set=0,binding=4,std140) uniform Implementation {uint ss_effects_flags;} implementation_data;
bool sc_use_directional_soft_shadows(){return false;}
float sample_directional_soft_shadow(texture2D tex,vec3 coord,vec2 scale,float taa){return 1.0;}
float sample_directional_pcf_shadow(texture2D tex,vec2 scale,vec4 coord,float taa){return 1.0;}
struct SceneData {float taa_frame_count; vec2 directional_shadow_pixel_size;};
layout(location=0) out vec4 output_color;
"""
	var main := """
void main(){
 SceneData scene_data=SceneData(0.0,vec2(1.0/1024.0));
 vec3 vertex=vec3(0,0,-10); vec3 geo_normal=vec3(0,1,0); vec2 screen_uv=vec2(0.5);
 uint i=0u; int sun_index=0; float shadowmask=1.0; uint shadowmask_mode=0u;
 float vertex_shadow=1.0; float unused_vertex_shadow=1.0; output_color=vec4(0);
"""
	for call: RegExMatch in calls:
		main += "\n{\n" + call.get_string() + "\noutput_color+=vec4(shadow);\n}\n"
	main += "\n}\n"
	var negative := OS.get_cmdline_user_args().has("--negative-control")
	if negative:
		var original := main
		main = main.replace("scene_data.taa_frame_count, scene_data.directional_shadow_pixel_size, vertex_shadow", "vertex_shadow")
		if main == original:
			printerr("DIRECTIONAL_SHADOW_NEGATIVE_CONTROL_NOT_APPLIED")
			quit(1)
			return
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		printerr("DIRECTIONAL_SHADOW_REQUIRES_RENDERING_DEVICE")
		quit(2)
		return
	var failed := false
	for definitions: String in ["#define USE_LIGHTMAP\n", "#define USE_LIGHTMAP\n#define USE_MULTIVIEW\n", "", "#define SHADOWS_DISABLED\n"]:
		var source := RDShaderSource.new()
		source.source_fragment = "#version 450\n" + definitions + directional_type + declarations + helper + main
		var spirv := rd.shader_compile_spirv_from_source(source)
		var error_text := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_FRAGMENT)
		if not error_text.is_empty():
			if not negative:
				printerr(error_text)
			failed = true
	rd.free()
	if negative:
		print("DIRECTIONAL_SHADOW_NEGATIVE_CONTROL_OK rejected_signature" if failed else "DIRECTIONAL_SHADOW_NEGATIVE_CONTROL_FAILED")
		quit(0 if failed else 1)
		return
	print("DIRECTIONAL_SHADOW_CALLS_OK variants=4 calls=2" if not failed else "DIRECTIONAL_SHADOW_CALLS_FAILED")
	quit(1 if failed else 0)

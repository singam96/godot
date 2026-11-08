extends SceneTree
## Compile the actual outdoor sampler/reconstruction code before rebuilding.


func _initialize() -> void:
	var path := ProjectSettings.globalize_path("res://../servers/rendering/renderer_rd/shaders/forward_clustered/baked_outdoor_lighting_inc.glsl")
	var helper := FileAccess.get_file_as_string(path)
	if helper.is_empty():
		printerr("OUTDOOR_SHADER_SOURCE_NOT_FOUND")
		quit(2)
		return
	var negative := OS.get_cmdline_user_args().has("--negative-control")
	if negative: helper = helper.replace("vec4 parameters[20]", "vec4 removed_parameters[20]")
	var declarations := """
#define INSTANCE_FLAGS_USE_LIGHTMAP 1u
layout(set=0,binding=0) uniform sampler shared_sampler;
#define SAMPLER_NEAREST_CLAMP shared_sampler
#define SAMPLER_LINEAR_CLAMP shared_sampler
struct TestInstance {uint flags; uint layer_mask;};
layout(set=0,binding=1,std430) readonly buffer Instances {TestInstance data[];} instances;
"""
	var expression := """
vec3 p=vec3(0.25,1.0,0.5); vec3 n=vec3(0,1,0);
vec3 value=baked_outdoor_solar_irradiance(p,n,n,1.0,1.0);
value+=vec3(baked_outdoor_actor_visibility(p,n)+baked_outdoor_sky_visibility(p));
value+=vec3(baked_outdoor_receiver(0u) && baked_outdoor_sun(0u) ? 1.0 : 0.0);
"""
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		printerr("OUTDOOR_SHADER_REQUIRES_RENDERING_DEVICE")
		quit(2)
		return
	var failures := 0
	for stage in [RenderingDevice.SHADER_STAGE_VERTEX, RenderingDevice.SHADER_STAGE_FRAGMENT, RenderingDevice.SHADER_STAGE_COMPUTE]:
		var source := RDShaderSource.new()
		var body := "#version 450\n" + declarations + helper
		if stage == RenderingDevice.SHADER_STAGE_VERTEX:
			source.source_vertex = body + "\nvoid main(){" + expression + "gl_Position=vec4(value,1);}\n"
		elif stage == RenderingDevice.SHADER_STAGE_FRAGMENT:
			source.source_fragment = body + "\nlayout(location=0) out vec4 result; void main(){" + expression + "result=vec4(value,1);}\n"
		else:
			source.source_compute = body + "\nlayout(local_size_x=1) in; layout(set=0,binding=2,std430) buffer Result {vec4 value;} result; void main(){" + expression + "result.value=vec4(value,1);}\n"
		var spirv := rd.shader_compile_spirv_from_source(source)
		var error_text := spirv.get_stage_compile_error(stage)
		if not error_text.is_empty():
			failures += 1
			if not negative: printerr(error_text)
	rd.free()
	if negative:
		print("OUTDOOR_SHADER_NEGATIVE_CONTROL_OK" if failures == 3 else "OUTDOOR_SHADER_NEGATIVE_CONTROL_FAILED")
		quit(0 if failures == 3 else 1)
	else:
		print("OUTDOOR_SHADER_OK variants=3" if failures == 0 else "OUTDOOR_SHADER_FAILED")
		quit(0 if failures == 0 else 1)

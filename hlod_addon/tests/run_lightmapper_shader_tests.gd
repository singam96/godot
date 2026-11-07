extends SceneTree
## Compiles the complete native lightmapper compute source, including cutout traversal.


func _initialize() -> void:
	var folder := ProjectSettings.globalize_path("res://../modules/lightmapper_rd")
	var text := FileAccess.get_file_as_string(folder.path_join("lm_compute.glsl"))
	if not text.contains("#[compute]"):
		printerr("LIGHTMAPPER_SHADER_SOURCE_NOT_FOUND")
		quit(2)
		return
	text = text.split("#[compute]", true, 1)[1]
	for include: String in ["lm_area_lights_inc.glsl", "lm_common_inc.glsl"]:
		text = text.replace('#include "%s"' % include, FileAccess.get_file_as_string(folder.path_join(include)))
	var negative := OS.get_cmdline_user_args().has("--negative-control")
	if negative:
		text = text.replace("uint context_tag;", "uint pad1;")
	var rd := RenderingServer.create_local_rendering_device()
	if rd == null:
		printerr("LIGHTMAPPER_SHADER_REQUIRES_RENDERING_DEVICE")
		quit(2)
		return
	var failures := 0
	var checks := 0
	for mode: String in ["DIRECT_LIGHT", "BOUNCE_LIGHT", "DILATE", "UNOCCLUDE", "LIGHT_PROBES", "DENOISE", "PACK_L1_COEFFS"]:
		for options: String in ["", "#define USE_SH_LIGHTMAPS\n", "#define USE_LIGHT_TEXTURE_FOR_BOUNCES\n", "#define USE_SHADOWMASK\n", "#define STORE_DIRECT_VISIBILITY\n", "#define USE_SH_LIGHTMAPS\n#define USE_LIGHT_TEXTURE_FOR_BOUNCES\n#define USE_SHADOWMASK\n"]:
			var source := RDShaderSource.new()
			source.source_compute = text.replace("#VERSION_DEFINES", "#define CLUSTER_SIZE 16\n#define MODE_%s\n%s" % [mode, options])
			var spirv := rd.shader_compile_spirv_from_source(source)
			var error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
			checks += 1
			if not error.is_empty():
				failures += 1
				if not negative:
					printerr(mode, " ", options, "\n", error)
	rd.free()
	if negative:
		print("LIGHTMAPPER_SHADER_NEGATIVE_CONTROL_OK" if failures == checks else "LIGHTMAPPER_SHADER_NEGATIVE_CONTROL_FAILED")
		quit(0 if failures == checks else 1)
		return
	print("LIGHTMAPPER_SHADER_TESTS checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

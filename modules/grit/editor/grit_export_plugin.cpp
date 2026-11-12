/**************************************************************************/
/*  grit_export_plugin.cpp                                                */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

#include "grit_export_plugin.h"

#include "grit_project_compiler.h"

#include "core/config/project_settings.h"
#include "core/io/dir_access.h"
#include "core/io/file_access.h"
#include "core/io/resource.h"
#include "core/os/os.h"
#include "editor/export/editor_export_platform.h"
#include "editor/export/editor_export_preset.h"

#include "modules/gdscript/gdscript.h"
#include "modules/gdscript/gdscript_tokenizer_buffer.h"
#include "modules/grit/runtime/grit_registry.h"

void GritExportPlugin::_get_export_options(const Ref<EditorExportPlatform> &p_export_platform, List<EditorExportPlatform::ExportOption> *r_options) const {
	r_options->push_back(EditorExportPlatform::ExportOption(PropertyInfo(Variant::BOOL, OPTION_STRIP_SCRIPTS), false));
}

void GritExportPlugin::_export_begin(const HashSet<String> &p_features, bool p_debug, const String &p_path, int p_flags) {
	stripped_sources.clear();
	if (!bool(GLOBAL_GET(SETTING_ENABLED))) {
		return;
	}

	const Ref<EditorExportPreset> preset = get_export_preset();
	script_mode = preset.is_valid() ? preset->get_script_export_mode() : EditorExportPreset::MODE_SCRIPT_BINARY_TOKENS_COMPRESSED;
	const bool strip_requested = bool(get_option(OPTION_STRIP_SCRIPTS));
	const bool strip = strip_requested && !p_debug;
	if (strip_requested && p_debug) {
		print_line("Grit: scripts are only stripped in release exports, this debug export keeps them.");
	}

	const String output_directory = ProjectSettings::get_singleton()->globalize_path(GLOBAL_GET(SETTING_GENERATED_DIRECTORY));
	GritProjectCompiler compiler;
	GritProjectCompiler::Report report;
	const Error error = compiler.compile(output_directory, strip, report);
	if (error != OK) {
		ERR_PRINT("Grit: native code generation failed, the exported project will use the GDScript VM.");
		return;
	}

	stripped_sources = report.stripped_sources;
	customization_hash = GritRegistry::make_pack_fingerprint(report.fingerprint, strip).hash64();
	add_file(GritRegistry::get_fingerprint_path(), GritRegistry::make_pack_fingerprint(report.fingerprint, strip).to_utf8_buffer(), false);
	print_line(vformat("Grit: generated C++ written to \"%s\".", output_directory));
}

String GritExportPlugin::provide_native_template(const Ref<EditorExportPreset> &p_preset, bool p_debug, bool p_check_only) {
	if (!bool(GLOBAL_GET(SETTING_ENABLED)) || !bool(GLOBAL_GET(SETTING_BUILD_TEMPLATE)) || p_preset.is_null() || p_preset->get_platform().is_null()) {
		return String();
	}

	// Which scons platform builds the template for this export, from this host.
	const String target_os = p_preset->get_platform()->get_os_name();
	const String host_os = OS::get_singleton()->get_name();
	String scons_platform;
	String extension;
	Vector<String> platform_arguments;
	if (target_os == "Linux" && host_os == "Linux") {
		scons_platform = "linuxbsd";
	} else if (target_os == "Windows" && host_os == "Windows") {
		scons_platform = "windows";
		extension = ".exe";
	} else if (target_os == "Windows" && host_os == "Linux") {
		scons_platform = "windows";
		extension = ".exe";
		platform_arguments.push_back("use_mingw=yes");
	} else {
		if (!p_check_only) {
			WARN_PRINT(vformat("Grit: automatic template building does not support %s exports from %s. This export runs the scripts in the GDScript VM.", target_os, host_os));
		}
		return String();
	}

	String source = String(GLOBAL_GET(SETTING_ENGINE_SOURCE_DIRECTORY)).strip_edges();
	if (source.is_empty()) {
		const String executable_directory = OS::get_singleton()->get_executable_path().get_base_dir();
		for (const String &candidate : { executable_directory.get_base_dir(), executable_directory }) {
			if (FileAccess::exists(candidate.path_join("SConstruct")) && FileAccess::exists(candidate.path_join("modules/grit/SCsub"))) {
				source = candidate;
				break;
			}
		}
	}
	if (source.is_empty() || !FileAccess::exists(source.path_join("SConstruct"))) {
		if (!p_check_only) {
			WARN_PRINT("Grit: the engine source was not found, so no native template was built. Set grit/export/engine_source_directory. This export runs the scripts in the GDScript VM.");
		}
		return String();
	}
	if (p_check_only) {
		return "grit";
	}

	// Generate the C++ for this project.
	const bool strip = bool(p_preset->get(OPTION_STRIP_SCRIPTS)) && !p_debug;
	const String generated_directory = ProjectSettings::get_singleton()->globalize_path(GLOBAL_GET(SETTING_GENERATED_DIRECTORY));
	GritProjectCompiler compiler;
	GritProjectCompiler::Report report;
	if (compiler.compile(generated_directory, strip, report) != OK) {
		WARN_PRINT("Grit: native code generation failed, so no native template was built. This export runs the scripts in the GDScript VM.");
		return String();
	}

	const String target = p_debug ? "template_debug" : "template_release";
	Vector<String> command_parts = String(GLOBAL_GET(SETTING_SCONS_COMMAND)).strip_edges().split(" ", false);
	if (command_parts.is_empty()) {
		WARN_PRINT("Grit: grit/export/scons_command is empty. This export runs the scripts in the GDScript VM.");
		return String();
	}
	const String program = command_parts[0];
	List<String> arguments;
	for (int i = 1; i < command_parts.size(); i++) {
		arguments.push_back(command_parts[i]);
	}
	arguments.push_back("--directory=" + source);
	arguments.push_back("platform=" + scons_platform);
	arguments.push_back("target=" + target);
	const String architecture = p_preset->get("binary_format/architecture");
	if (!architecture.is_empty()) {
		arguments.push_back("arch=" + architecture);
	}
#ifdef REAL_T_IS_DOUBLE
	arguments.push_back("precision=double");
#endif
	for (const String &argument : platform_arguments) {
		arguments.push_back(argument);
	}
	arguments.push_back("extra_suffix=grit");
	arguments.push_back("grit_generated=" + generated_directory);
	for (const String &argument : String(GLOBAL_GET(SETTING_SCONS_ARGUMENTS)).split(" ", false)) {
		arguments.push_back(argument);
	}

	print_line(vformat("Grit: building the native %s for %s in \"%s\". The first build compiles the whole engine and can take a long time.", target, target_os, source));
	String output;
	int exit_code = -1;
	const Error error = OS::get_singleton()->execute(program, arguments, &output, &exit_code, true);
	if (error != OK || exit_code != 0) {
		const Vector<String> lines = output.strip_edges().split("\n");
		String tail;
		for (int i = MAX(0, lines.size() - 15); i < lines.size(); i++) {
			tail += lines[i] + "\n";
		}
		WARN_PRINT(vformat("Grit: building the native template failed (exit code %d), so this export runs the scripts in the GDScript VM.\n%s", exit_code, tail));
		return String();
	}

	const String bin_directory = source.path_join("bin");
	const String prefix = "godot." + scons_platform + "." + target + ".";
	Ref<DirAccess> directory = DirAccess::open(bin_directory);
	String best;
	uint64_t best_time = 0;
	if (directory.is_valid()) {
		for (const String &file : directory->get_files()) {
			if (!file.begins_with(prefix) || !file.ends_with(".grit" + extension) || file.contains(".console.")) {
				continue;
			}
			const uint64_t modified = FileAccess::get_modified_time(bin_directory.path_join(file));
			if (best.is_empty() || modified > best_time) {
				best = file;
				best_time = modified;
			}
		}
	}
	if (best.is_empty()) {
		WARN_PRINT(vformat("Grit: the template was built but no \"%s*.grit%s\" binary was found in \"%s\". This export runs the scripts in the GDScript VM.", prefix, extension, bin_directory));
		return String();
	}
	print_line(vformat("Grit: using the native template \"%s\".", best));
	return bin_directory.path_join(best);
}

void GritExportPlugin::_export_file(const String &p_path, const String &p_type, const HashSet<String> &p_features) {
	const String *source = stripped_sources.getptr(p_path);
	if (!source) {
		return;
	}
	if (script_mode == EditorExportPreset::MODE_SCRIPT_TEXT) {
		add_file(p_path, source->to_utf8_buffer(), false);
		skip();
		return;
	}
	const GDScriptTokenizerBuffer::CompressMode compress_mode = script_mode == EditorExportPreset::MODE_SCRIPT_BINARY_TOKENS_COMPRESSED ? GDScriptTokenizerBuffer::COMPRESS_ZSTD : GDScriptTokenizerBuffer::COMPRESS_NONE;
	const Vector<uint8_t> tokens = GDScriptTokenizerBuffer::parse_code_string(*source, compress_mode);
	ERR_FAIL_COND_MSG(tokens.is_empty(), vformat("Grit: could not tokenize the stripped \"%s\".", p_path));
	add_file(p_path.get_basename() + ".gdc", tokens, true);
}

bool GritExportPlugin::_begin_customize_resources(const Ref<EditorExportPlatform> &p_platform, const Vector<String> &p_features) {
	for (const KeyValue<String, String> &entry : stripped_sources) {
		if (entry.key.contains("::")) {
			return true;
		}
	}
	return false;
}

Ref<Resource> GritExportPlugin::_customize_resource(const Ref<Resource> &p_resource, const String &p_path) {
	const Ref<GDScript> script = p_resource;
	if (script.is_null() || !script->is_built_in()) {
		return Ref<Resource>();
	}
	const String *source = stripped_sources.getptr(script->get_path());
	if (!source || ResourceCache::get_ref(script->get_path()).ptr() == script.ptr()) {
		return Ref<Resource>();
	}
	script->set_source_code(*source);
	return script;
}

uint64_t GritExportPlugin::_get_customization_configuration_hash() const {
	return customization_hash;
}

void GritExportPlugin::_export_end() {
	stripped_sources.clear();
}

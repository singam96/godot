/**************************************************************************/
/*  grit_project_compiler.h                                               */
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

#pragma once

#include "core/object/ref_counted.h"
#include "core/string/ustring.h"
#include "core/templates/hash_map.h"
#include "core/templates/hash_set.h"
#include "core/templates/vector.h"

#include "modules/grit/compiler/grit_ir.h"

class GDScript;
class Resource;

class GritProjectCompiler {
public:
	struct Report {
		String fingerprint;
		int script_count = 0;
		int function_count = 0;
		int native_function_count = 0;
		int stripped_function_count = 0;
		HashMap<String, String> stripped_sources;
	};

private:
	struct ScriptSource {
		String path;
		String code;
		Ref<GDScript> script;

		bool operator<(const ScriptSource &p_other) const { return path < p_other.path; }
	};

	static void collect_files(const String &p_directory, Vector<String> &r_scripts, Vector<String> &r_resources);
	static bool may_contain_builtin_scripts(const String &p_path);
	static void collect_builtin_scripts(const Variant &p_value, const String &p_owner_path, HashSet<const Object *> &r_visited, Vector<ScriptSource> &r_sources);
	static String compute_fingerprint(const Vector<ScriptSource> &p_sources, bool p_strip);
	static HashSet<String> strippable_functions(const LocalVector<GritFunction> &p_functions);
	static Error compile_script(const ScriptSource &p_source, LocalVector<GritFunction> &r_functions);

public:
	Error compile(const String &p_output_directory, bool p_strip, Report &r_report);
};

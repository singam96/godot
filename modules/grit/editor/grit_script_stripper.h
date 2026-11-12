/**************************************************************************/
/*  grit_script_stripper.h                                                */
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

#include "core/string/ustring.h"
#include "core/templates/hash_set.h"

#include "modules/gdscript/gdscript_parser.h"

class GritScriptStripper {
	const HashSet<String> *strippable = nullptr;
	Vector<String> lines;
	HashSet<String> stripped;

	void strip_class(const GDScriptParser::ClassNode *p_class, const String &p_class_path);
	void strip_function(const GDScriptParser::FunctionNode *p_function, const String &p_id, const String &p_stub);
	void strip_accessor(const GDScriptParser::FunctionNode *p_accessor, const String &p_class_path, const String &p_stub);
	String node_text(const GDScriptParser::Node *p_node) const;
	String stub(const GDScriptParser::DataType &p_type, const GDScriptParser::Node *p_type_node) const;
	void set_line(int p_line, const String &p_text);

public:
	static String function_id(const String &p_class_path, const StringName &p_name);

	Error strip(const String &p_path, const String &p_source, const HashSet<String> &p_strippable, String &r_stripped);
	const HashSet<String> &get_stripped() const { return stripped; }
};

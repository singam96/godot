/**************************************************************************/
/*  grit_signature.cpp                                                    */
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

#include "grit_signature.h"

#include "modules/gdscript/gdscript.h"

String GritFunctionSignature::describe() const {
	PackedStringArray parameters;
	for (const GDScriptDataType &parameter_type : parameter_types) {
		parameters.push_back(describe_type(parameter_type));
	}

	String description = is_static ? "static " : "";
	description += "(" + String(", ").join(parameters) + ") -> " + describe_type(return_type);
	if (optional_parameter_count > 0) {
		description += vformat(" optional %d", optional_parameter_count);
	}
	return description;
}

String GritFunctionSignature::describe_type(const GDScriptDataType &p_type) {
	switch (p_type.kind) {
		case GDScriptDataType::VARIANT:
			return "Variant";
		case GDScriptDataType::BUILTIN: {
			String name = Variant::get_type_name(p_type.builtin_type);
			if (p_type.has_container_element_types()) {
				PackedStringArray elements;
				for (const GDScriptDataType &element_type : p_type.container_element_types) {
					elements.push_back(describe_type(element_type));
				}
				name += "[" + String(", ").join(elements) + "]";
			}
			return name;
		}
		case GDScriptDataType::NATIVE:
			return p_type.native_type;
		case GDScriptDataType::SCRIPT:
		case GDScriptDataType::GDSCRIPT: {
			const GDScript *gdscript = Object::cast_to<GDScript>(p_type.script_type);
			if (gdscript) {
				return "Script(" + gdscript->get_fully_qualified_name() + ")";
			}
			return "Script(" + (p_type.script_type ? p_type.script_type->get_path() : String()) + ")";
		}
	}
	return "Unknown";
}

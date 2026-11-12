/**************************************************************************/
/*  grit_ir.cpp                                                           */
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

#include "grit_ir.h"

#include "modules/gdscript/gdscript.h"
#include "modules/grit/runtime/grit_registry.h"

GritType GritType::from(const GDScriptDataType &p_type) {
	GritType type;
	switch (p_type.kind) {
		case GDScriptDataType::VARIANT:
			type.kind = Kind::VARIANT;
			break;
		case GDScriptDataType::BUILTIN:
			type.kind = Kind::BUILTIN;
			break;
		case GDScriptDataType::NATIVE:
			type.kind = Kind::NATIVE;
			break;
		case GDScriptDataType::SCRIPT:
		case GDScriptDataType::GDSCRIPT:
			type.kind = Kind::SCRIPT;
			break;
	}
	type.builtin_type = p_type.builtin_type;
	type.native_type = p_type.native_type;
	if (p_type.script_type) {
		type.script = script_reference(p_type.script_type);
	}
	for (const GDScriptDataType &element : p_type.container_element_types) {
		type.elements.push_back(from(element));
	}
	return type;
}

String GritType::script_reference(const Script *p_script) {
	const GDScript *gdscript = Object::cast_to<GDScript>(p_script);
	if (!gdscript) {
		return p_script->get_path();
	}
	return GritRegistry::make_class_path(gdscript);
}

bool GritType::is_referencable() const {
	if (kind == Kind::SCRIPT && script.is_empty()) {
		return false;
	}
	for (const GritType &element_type : elements) {
		if (!element_type.is_referencable()) {
			return false;
		}
	}
	return true;
}

GritType GritType::element(int p_index) const {
	if (p_index < 0 || p_index >= int(elements.size())) {
		return GritType();
	}
	return elements[p_index];
}

bool GritType::can_contain_object() const {
	if (kind != Kind::BUILTIN) {
		return true;
	}
	switch (builtin_type) {
		case Variant::ARRAY:
			return elements.is_empty() || elements[0].can_contain_object();
		case Variant::DICTIONARY:
			return elements.is_empty() || element(0).can_contain_object() || element(1).can_contain_object();
		case Variant::NIL:
		case Variant::OBJECT:
			return true;
		default:
			return false;
	}
}

bool GritType::operator==(const GritType &p_other) const {
	if (kind != p_other.kind || builtin_type != p_other.builtin_type || native_type != p_other.native_type || script != p_other.script || elements.size() != p_other.elements.size()) {
		return false;
	}
	for (uint32_t i = 0; i < elements.size(); i++) {
		if (!(elements[i] == p_other.elements[i])) {
			return false;
		}
	}
	return true;
}

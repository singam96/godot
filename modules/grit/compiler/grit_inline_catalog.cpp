/**************************************************************************/
/*  grit_inline_catalog.cpp                                               */
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

#include "grit_inline_catalog.h"

#include "core/variant/variant_construct.h"
#include "core/variant/variant_op.h"
#include "core/variant/variant_setget.h"

namespace {

struct OperatorEntry {
	Variant::PTROperatorEvaluator evaluator;
	const char *name;
};

struct MemberEntry {
	Variant::PTRGetter getter;
	Variant::PTRSetter setter;
	const char *name;
};

struct ConstructorEntry {
	Variant::PTRConstructor constructor;
	const char *name;
};

#include "grit_inline_catalog.gen.inc"

} //namespace

String GritInlineCatalog::operator_evaluator(Variant::PTROperatorEvaluator p_evaluator) {
	if (!p_evaluator) {
		return String();
	}
	for (const OperatorEntry &entry : operator_entries) {
		if (entry.evaluator == p_evaluator) {
			return entry.name;
		}
	}
	return String();
}

String GritInlineCatalog::member_accessor(Variant::PTRGetter p_getter, Variant::PTRSetter p_setter) {
	if (!p_getter && !p_setter) {
		return String();
	}
	for (const MemberEntry &entry : member_entries) {
		if ((!p_getter || entry.getter == p_getter) && (!p_setter || entry.setter == p_setter)) {
			return entry.name;
		}
	}
	return String();
}

String GritInlineCatalog::constructor(Variant::PTRConstructor p_constructor) {
	if (!p_constructor) {
		return String();
	}
	for (const ConstructorEntry &entry : constructor_entries) {
		if (entry.constructor == p_constructor) {
			return entry.name;
		}
	}
	return String();
}

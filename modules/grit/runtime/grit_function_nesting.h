/**************************************************************************/
/*  grit_function_nesting.h                                               */
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

#include "grit_registry.h"

#include "core/templates/hash_map.h"
#include "core/templates/local_vector.h"

template <typename Payload>
class GritFunctionNesting {
	struct Entry {
		StringName name;
		int line = 0;
		bool debug_only = false;
		Payload payload;
	};

	static inline thread_local GritFunctionNesting *current = nullptr;

	GritFunctionNesting *parent = nullptr;
	GritFunctionNesting *root = this;
	LocalVector<Entry> entries;
	uint32_t debug_mark = 0;

public:
	bool is_nested() const { return parent != nullptr; }

	void add(const StringName &p_name, int p_line, Payload &&p_payload) {
		Entry entry;
		entry.name = p_name;
		entry.line = p_line;
		entry.payload = std::move(p_payload);
		root->entries.push_back(std::move(entry));
	}

	void mark_newline() {
		debug_mark = root->entries.size();
	}

	void mark_assert() {
		for (uint32_t i = debug_mark; i < root->entries.size(); i++) {
			root->entries[i].debug_only = true;
		}
	}

	template <typename Callback>
	void resolve(const String &p_root_key, Callback p_callback) {
		HashMap<String, int> ordinals;
		for (Entry &entry : entries) {
			if (entry.debug_only) {
				continue;
			}
			const String local_key = vformat("%s:%d", entry.name, entry.line);
			int *ordinal = ordinals.getptr(local_key);
			if (!ordinal) {
				ordinal = &ordinals.insert(local_key, 0)->value;
			}
			p_callback(GritRegistry::make_lambda_key(p_root_key, entry.name, entry.line, *ordinal), entry.payload);
			(*ordinal)++;
		}
		entries.clear();
	}

	GritFunctionNesting() {
		parent = current;
		if (parent) {
			root = parent->root;
		}
		current = this;
	}

	~GritFunctionNesting() {
		current = parent;
	}

	GritFunctionNesting(const GritFunctionNesting &) = delete;
	GritFunctionNesting &operator=(const GritFunctionNesting &) = delete;
};

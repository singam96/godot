/**************************************************************************/
/*  hlod_cluster_3d_editor_plugin.cpp                                     */
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

#include "hlod_cluster_3d_editor_plugin.h"

#include "core/object/callable_mp.h"
#include "core/os/os.h"
#include "editor/editor_node.h"
#include "editor/editor_string_names.h"
#include "editor/editor_undo_redo_manager.h"
#include "scene/3d/hlod_cluster_3d.h"
#include "scene/gui/button.h"

void HLODCluster3DEditorPlugin::_generate() {
	ERR_FAIL_NULL(cluster);

	const Ref<Mesh> old_mesh = cluster->get_proxy_mesh();

	// The heavy work runs on a worker thread while a progress dialog keeps the editor responsive and lets the user cancel.
	Error err = cluster->generate_proxy_async();
	if (err == OK) {
		EditorProgress progress("hlod_generate", TTR("Generating HLOD Proxy"), 1000, true);
		while (cluster->is_generating()) {
			if (progress.step(cluster->get_generation_status(), int(cluster->get_generation_progress() * 1000), true)) {
				cluster->cancel_generation();
				break;
			}
			OS::get_singleton()->delay_usec(10000);
		}
		err = cluster->finish_generation();
	}

	switch (err) {
		case OK: {
			EditorUndoRedoManager *ur = EditorUndoRedoManager::get_singleton();
			ur->create_action(TTR("Generate HLOD Proxy"));
			ur->add_do_property(cluster, "proxy_mesh", cluster->get_proxy_mesh());
			ur->add_undo_property(cluster, "proxy_mesh", old_mesh);
			ur->commit_action(false); // The proxy was already assigned by generate_proxy().
		} break;
		case ERR_SKIP: {
			// Cancelled by the user.
		} break;
		case ERR_DOES_NOT_EXIST: {
			EditorNode::get_singleton()->show_warning(TTR("No meshes to merge.\nMake sure the HLODCluster3D has at least one visible MeshInstance3D descendant."));
		} break;
		case ERR_UNAVAILABLE: {
			EditorNode::get_singleton()->show_warning(TTR("Mesh simplification is unavailable because the meshoptimizer module is disabled.\nSet Simplify Ratio to 1.0 to merge the meshes without simplifying them."));
		} break;
		default: {
			EditorNode::get_singleton()->show_warning(TTR("Could not generate the HLOD proxy mesh."));
		} break;
	}
}

void HLODCluster3DEditorPlugin::edit(Object *p_object) {
	cluster = Object::cast_to<HLODCluster3D>(p_object);
}

bool HLODCluster3DEditorPlugin::handles(Object *p_object) const {
	return p_object->is_class("HLODCluster3D");
}

void HLODCluster3DEditorPlugin::make_visible(bool p_visible) {
	generate->set_visible(p_visible);
}

HLODCluster3DEditorPlugin::HLODCluster3DEditorPlugin() {
	generate = memnew(Button);
	generate->set_theme_type_variation(SceneStringName(FlatButton));
	generate->set_button_icon(EditorNode::get_singleton()->get_editor_theme()->get_icon(SNAME("Bake"), EditorStringName(EditorIcons)));
	generate->set_text(TTR("Generate HLOD"));
	generate->hide();
	generate->connect(SceneStringName(pressed), callable_mp(this, &HLODCluster3DEditorPlugin::_generate));
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, generate);
}

/**************************************************************************/
/*  hlod_material_atlas.h                                                 */
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

#include "core/io/image.h"
#include "core/object/ref_counted.h"
#include "core/templates/vector.h"

class Image;
class Material;
class StandardMaterial3D;

// Helpers used by HLODCluster3D to bake several simple materials into one texture atlas.
class HLODMaterialAtlas {
public:
	// Number of texels of edge padding kept around every texture in the atlas, to limit bleeding between neighbors.
	static constexpr int PADDING = 2;

	// Returns whether the material only uses features that survive being baked into an atlas: an opaque
	// StandardMaterial3D that has at most an albedo texture and an albedo color.
	static bool is_eligible(const Ref<Material> &p_material);

	// Materials with the same key can share an atlas, because the rest of their settings are identical.
	static String get_group_key(const Ref<StandardMaterial3D> &p_material);

	// Bakes the albedo of every material into a single atlas image. `p_images` holds the albedo texture image of
	// every material (null for materials without a texture). `r_rects` receives, for each material, the rectangle
	// (in 0..1 UV space) that the 0..1 UV range of that material must be remapped to. This only does CPU work and
	// is safe to call from a worker thread. Returns a null reference if the atlas can't be built.
	static Ref<Image> build(const Vector<Ref<StandardMaterial3D>> &p_materials, const Vector<Ref<Image>> &p_images, int p_cell_size, Vector<Rect2> &r_rects);

	// Creates the material that draws the atlas, based on the settings of `p_template`. Uses the rendering server.
	static Ref<StandardMaterial3D> create_material(const Ref<StandardMaterial3D> &p_template, const Ref<Image> &p_atlas);
};

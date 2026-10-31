/**************************************************************************/
/*  hlod_material_atlas.cpp                                               */
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

#include "hlod_material_atlas.h"

#include "scene/resources/image_texture.h"
#include "scene/resources/material.h"

bool HLODMaterialAtlas::is_eligible(const Ref<Material> &p_material) {
	const Ref<StandardMaterial3D> material = p_material;
	if (material.is_null()) {
		return false;
	}
	if (material->get_next_pass().is_valid() || material->get_transparency() != BaseMaterial3D::TRANSPARENCY_DISABLED || material->get_billboard_mode() != BaseMaterial3D::BILLBOARD_DISABLED) {
		return false;
	}
	for (int i = 0; i < BaseMaterial3D::FEATURE_MAX; i++) {
		if (material->get_feature((BaseMaterial3D::Feature)i)) {
			return false;
		}
	}
	for (int i = 0; i < BaseMaterial3D::TEXTURE_MAX; i++) {
		if (i != BaseMaterial3D::TEXTURE_ALBEDO && material->get_texture((BaseMaterial3D::TextureParam)i).is_valid()) {
			return false;
		}
	}
	for (BaseMaterial3D::Flags flag : { BaseMaterial3D::FLAG_UV1_USE_TRIPLANAR, BaseMaterial3D::FLAG_UV1_USE_WORLD_TRIPLANAR, BaseMaterial3D::FLAG_USE_POINT_SIZE, BaseMaterial3D::FLAG_FIXED_SIZE, BaseMaterial3D::FLAG_USE_SHADOW_TO_OPACITY, BaseMaterial3D::FLAG_PARTICLE_TRAILS_MODE }) {
		if (material->get_flag(flag)) {
			return false;
		}
	}
	return material->get_uv1_scale() == Vector3(1, 1, 1) && material->get_uv1_offset() == Vector3() && !material->is_grow_enabled() && material->get_distance_fade() == BaseMaterial3D::DISTANCE_FADE_DISABLED && !material->is_proximity_fade_enabled();
}

String HLODMaterialAtlas::get_group_key(const Ref<StandardMaterial3D> &p_material) {
	String key = vformat("%d|%d|%d|%d|%d|%d|%d|%.4f|%.4f|%.4f", p_material->get_cull_mode(), p_material->get_shading_mode(), p_material->get_diffuse_mode(), p_material->get_specular_mode(), p_material->get_texture_filter(), p_material->get_depth_draw_mode(), p_material->get_render_priority(), p_material->get_roughness(), p_material->get_metallic(), p_material->get_specular());
	for (int i = 0; i < BaseMaterial3D::FLAG_MAX; i++) {
		// Whether the albedo texture is an sRGB texture is irrelevant here, because only albedo textures are baked.
		key += p_material->get_flag((BaseMaterial3D::Flags)i) ? "1" : "0";
	}
	return key;
}

Ref<Image> HLODMaterialAtlas::build(const Vector<Ref<StandardMaterial3D>> &p_materials, const Vector<Ref<Image>> &p_images, int p_cell_size, Vector<Rect2> &r_rects) {
	r_rects.clear();
	ERR_FAIL_COND_V(p_materials.is_empty() || p_materials.size() != p_images.size(), Ref<Image>());

	const int count = p_materials.size();
	const int columns = Math::ceil(Math::sqrt((double)count));
	const int rows = (count + columns - 1) / columns;

	// Shrink the cells until the atlas fits in the maximum texture size.
	int cell = CLAMP(p_cell_size, 16, 2048);
	while (cell > 16 && (columns * cell > 8192 || rows * cell > 8192)) {
		cell /= 2;
	}
	ERR_FAIL_COND_V_MSG(columns * cell > Image::MAX_WIDTH || rows * cell > Image::MAX_HEIGHT, Ref<Image>(), "Too many materials to bake into a texture atlas.");

	const int inner = cell - 2 * PADDING;
	Ref<Image> atlas = Image::create_empty(columns * cell, rows * cell, false, Image::FORMAT_RGBA8);

	for (int m = 0; m < count; m++) {
		const Color tint = p_materials[m]->get_albedo();

		Ref<Image> source;
		if (p_materials[m]->get_texture(BaseMaterial3D::TEXTURE_ALBEDO).is_valid()) {
			source = p_images[m];
			if (source.is_null() || source->is_empty()) {
				return Ref<Image>();
			}
			source = source->duplicate();
			if (source->is_compressed() && source->decompress() != OK) {
				return Ref<Image>();
			}
			source->convert(Image::FORMAT_RGBA8);
			source->resize(inner, inner, Image::INTERPOLATE_BILINEAR);
		}

		const int origin_x = (m % columns) * cell;
		const int origin_y = (m / columns) * cell;
		const bool tinted = tint != Color(1, 1, 1, 1);
		for (int y = 0; y < cell; y++) {
			for (int x = 0; x < cell; x++) {
				Color color = tint;
				if (source.is_valid()) {
					// Clamping to the inner area replicates the border texels into the padding.
					color = source->get_pixel(CLAMP(x - PADDING, 0, inner - 1), CLAMP(y - PADDING, 0, inner - 1));
					if (tinted) {
						// The albedo color is multiplied in linear space in the shader.
						color = (color.srgb_to_linear() * tint.srgb_to_linear()).linear_to_srgb();
					}
				}
				color.a = 1.0f;
				atlas->set_pixel(origin_x + x, origin_y + y, color);
			}
		}

		const Vector2 atlas_size = Vector2(atlas->get_width(), atlas->get_height());
		r_rects.push_back(Rect2(Vector2(origin_x + PADDING, origin_y + PADDING) / atlas_size, Vector2(inner, inner) / atlas_size));
	}

	atlas->generate_mipmaps();
	return atlas;
}

Ref<StandardMaterial3D> HLODMaterialAtlas::create_material(const Ref<StandardMaterial3D> &p_template, const Ref<Image> &p_atlas) {
	Ref<StandardMaterial3D> result = p_template->duplicate();
	result->set_albedo(Color(1, 1, 1, 1));
	result->set_texture(BaseMaterial3D::TEXTURE_ALBEDO, ImageTexture::create_from_image(p_atlas));
	return result;
}

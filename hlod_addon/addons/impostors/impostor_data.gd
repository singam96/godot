@tool
class_name ImpostorData
extends Resource
## A baked impostor: an atlas with several views of an object, and what is needed to draw it as a camera-facing quad.

const SHADER := preload("impostor.gdshader")
const LIT_SHADER := preload("impostor_lit.gdshader")
const SHADOW_SHADER := preload("impostor_shadow.gdshader")

## Columns are views around the object (azimuth), rows are views from higher up (elevation).
@export var atlas: Texture2D
## Object-space normals for the same views, so that the impostor can be lit. Without it the impostor is unlit.
@export var normal_atlas: Texture2D
## Per-pixel depth (red) and ambient occlusion (green) of the same views, for lit impostors.
@export var extra_atlas: Texture2D
## Depth that the red channel of [member extra_atlas] spans, in meters at the baked scale.
@export var depth_range := 1.0
## How strongly the baked ambient occlusion darkens the ambient light (0 = not at all).
@export_range(0.0, 1.0) var ao_strength := 1.0
## How much of the baked occlusion also darkens direct light (0..1). This stands in for self-shadowing inside the
## object: leaves deep in a canopy get less sun even though no shadow of the sun is baked.
@export_range(0.0, 1.0) var ao_light_affect := 0.4
## Light the impostor with the scene's lights (needs [member normal_atlas]).
@export var lit := true
## Let shadows of other objects fall on the impostor (needs [member lit]). Off by default: a flat camera-facing quad
## would otherwise sit inside its own shadow, which is avoided by moving its shadow back along the light ray, and that
## cuts the lower part off the shadow it casts on the ground. With this off, the shadow it casts is exact.
@export var receive_shadows := false
## Subdivides the quad into this many cells per side and pushes its vertices to the baked surface, so shadows are looked
## up by region instead of across one flat plane (0 = a single flat quad). Needs [member receive_shadows] and
## [member extra_atlas]. The cost is 2 x n x n triangles per impostor: use it for a few important impostors
## (buildings, large trees), not for thousands of instances.
@export_range(0, 64) var receive_detail := 0
@export_range(1, 64) var views := 12
@export_range(1, 8) var rows := 2
@export_range(0.0, 90.0, 0.1, "degrees") var min_elevation := 10.0
@export_range(0.0, 90.0, 0.1, "degrees") var max_elevation := 55.0
## Side of the (square) quad in meters, at the scale the impostor was baked at.
@export var quad_size := 1.0
## Center of the baked object, in the object's own space.
@export var center := Vector3.ZERO


func create_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	var use_light := lit and normal_atlas != null
	if use_light:
		material.shader = LIT_SHADER if receive_shadows else _lit_shader_without_shadows()
	else:
		material.shader = SHADER
	material.set_shader_parameter("atlas", atlas)
	material.set_shader_parameter("views", views)
	material.set_shader_parameter("rows", rows)
	material.set_shader_parameter("min_elevation", deg_to_rad(min_elevation))
	material.set_shader_parameter("max_elevation", deg_to_rad(max_elevation))
	material.set_shader_parameter("center", center)
	if use_light:
		material.set_shader_parameter("normal_atlas", normal_atlas)
		var has_extra := extra_atlas != null
		material.set_shader_parameter("use_extra", has_extra)
		if has_extra:
			material.set_shader_parameter("extra_atlas", extra_atlas)
			material.set_shader_parameter("depth_range", depth_range)
			material.set_shader_parameter("ao_strength", ao_strength)
			material.set_shader_parameter("ao_light_affect", ao_light_affect)
			material.set_shader_parameter("vertex_depth", receive_shadows and receive_detail > 0)
	return material


static var _lit_without_shadows: Shader


static func _lit_shader_without_shadows() -> Shader:
	if _lit_without_shadows == null:
		_lit_without_shadows = Shader.new()
		_lit_without_shadows.code = LIT_SHADER.code.replace("specular_disabled;", "specular_disabled, shadows_disabled;")
	return _lit_without_shadows


## The material for the shadows-only copy of the impostor (see [Impostor3D]). It is not meant for the camera.
func create_shadow_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = SHADOW_SHADER
	material.set_shader_parameter("atlas", atlas)
	material.set_shader_parameter("views", views)
	material.set_shader_parameter("rows", rows)
	material.set_shader_parameter("min_elevation", deg_to_rad(min_elevation))
	material.set_shader_parameter("max_elevation", deg_to_rad(max_elevation))
	material.set_shader_parameter("center", center)
	material.set_shader_parameter("quad_size", quad_size)
	material.set_shader_parameter("shift", 0.6 if (lit and normal_atlas != null and receive_shadows) else 0.0)
	return material


## A quad of [member quad_size]. The shader moves it to [member center] and turns it to the camera.
func create_mesh() -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(quad_size, quad_size)
	if receive_shadows and receive_detail > 0 and lit and extra_atlas != null:
		mesh.subdivide_width = receive_detail - 1
		mesh.subdivide_depth = receive_detail - 1
	# The quad is moved in the shader, so tell the renderer where it really ends up.
	mesh.custom_aabb = AABB(center - Vector3.ONE * quad_size, Vector3.ONE * quad_size * 2.0)
	mesh.material = create_material()
	return mesh


## Builds a MultiMesh drawing one impostor per transform; give it to a MultiMeshInstance3D.
## Instance scale and Y rotation are honoured, like for the real object.
func create_multimesh(transforms: Array[Transform3D]) -> MultiMesh:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = create_mesh()
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
	return multimesh

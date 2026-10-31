@tool
class_name ImpostorData
extends Resource
## A baked impostor: an atlas with several views of an object, and what is needed to draw it as a camera-facing quad.

const SHADER := preload("impostor.gdshader")
const LIT_SHADER := preload("impostor_lit.gdshader")

## Columns are views around the object (azimuth), rows are views from higher up (elevation).
@export var atlas: Texture2D
## Object-space normals for the same views, so that the impostor can be lit. Without it the impostor is unlit.
@export var normal_atlas: Texture2D
## Light the impostor with the scene's lights (needs [member normal_atlas]).
@export var lit := true
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
	material.shader = LIT_SHADER if use_light else SHADER
	material.set_shader_parameter("atlas", atlas)
	if use_light:
		material.set_shader_parameter("normal_atlas", normal_atlas)
	material.set_shader_parameter("views", views)
	material.set_shader_parameter("rows", rows)
	material.set_shader_parameter("min_elevation", deg_to_rad(min_elevation))
	material.set_shader_parameter("max_elevation", deg_to_rad(max_elevation))
	material.set_shader_parameter("center", center)
	return material


## A quad of [member quad_size]. The shader moves it to [member center] and turns it to the camera.
func create_mesh() -> QuadMesh:
	var mesh := QuadMesh.new()
	mesh.size = Vector2(quad_size, quad_size)
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

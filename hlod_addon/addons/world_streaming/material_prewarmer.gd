@tool
class_name MaterialPrewarmer
extends Node
## Makes the renderer prepare materials, meshes and scenes before the player can see them. The first time something is
## drawn, the GPU pipeline for it may have to be built, which can cause a hitch. This node draws the things once, tiny
## and off-screen (with lights and shadows on, so those variants are built too), at a time of your choosing, such as a
## loading screen.
##
## [codeblock]
## await prewarmer.prewarm([preload("res://tree.tscn"), preload("res://rock_material.tres"), some_mesh])
## [/codeblock]

## Frames to keep the things on screen. Pipelines are built asynchronously in recent versions, so give them a little time.
@export_range(1, 30) var frames := 3


## Accepts PackedScene (3D), Mesh and Material items. Returns the number of items drawn. This is a coroutine.
func prewarm(items: Array) -> int:
	if not is_inside_tree():
		return 0
	var viewport := SubViewport.new()
	viewport.size = Vector2i(8, 8)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)

	var camera := Camera3D.new()
	camera.fov = 170.0
	camera.far = 1.0e6
	viewport.add_child(camera)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	viewport.add_child(sun)
	var lamp := OmniLight3D.new()
	lamp.shadow_enabled = true
	lamp.position = Vector3(0, 1, -2)
	viewport.add_child(lamp)

	var count := 0
	for item in items:
		var node: Node3D = null
		if item is PackedScene:
			node = item.instantiate() as Node3D
		elif item is Mesh:
			var mi := MeshInstance3D.new()
			mi.mesh = item
			node = mi
		elif item is Material:
			var mi := MeshInstance3D.new()
			mi.mesh = SphereMesh.new()
			mi.material_override = item
			node = mi
		if node == null:
			continue
		node.position = Vector3(0, 0, -3)
		viewport.add_child(node)
		count += 1

	for i in frames:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	viewport.queue_free()
	return count

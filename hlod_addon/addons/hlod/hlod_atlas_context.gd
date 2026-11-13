@tool
extends RefCounted
## The texture atlases of one or more proxies. A single proxy has a context of its own; the proxies of a grid
## share one, so that a material is baked into an atlas once for the whole grid instead of once per cell.
##
## The order is: [method register] every material while the meshes are gathered, [method plan] once all of them are
## known, [method bake] (CPU only, may run on a thread), then [method get_material] to create the materials.

const HLODAtlas := preload("hlod_atlas.gd")

## The size in pixels of the square that every material gets.
var cell_size := 128
## Compress the baked atlases if the renderer supports a compressed format.
var compress := false
## One entry per kind of material: {key, materials, slots, images, layout, atlas_image}.
var groups: Array[Dictionary] = []

var _lookup := {}  # group key -> index into groups
var _images := {}  # Material -> Image (or null for a material without a texture)
var _failed := {}  # Material -> true, for materials whose texture could not be read
var _planned := false
var _baked := false
var _compress_mode := -1
var _materials := {}  # group index -> StandardMaterial3D
var _mutex := Mutex.new()


## Adds an eligible material and returns the key of its group, or an empty string if it can't be baked, for example
## because its texture can't be read. Call this from the main thread.
func register(material: StandardMaterial3D) -> String:
	if _failed.has(material):
		return ""
	if not _images.has(material):
		var albedo := HLODAtlas.read_albedo(material)
		if not albedo[0]:
			_failed[material] = true
			return ""
		_images[material] = albedo[1]
	var key := HLODAtlas.group_key(material)
	if not _lookup.has(key):
		_lookup[key] = groups.size()
		groups.append({"key": key, "materials": [], "slots": {}, "images": [], "layout": {}, "atlas_image": null})
	var group: Dictionary = groups[_lookup[key]]
	if not group.slots.has(material):
		group.slots[material] = group.materials.size()
		group.materials.append(material)
		group.images.append(_images[material])
	return key


func group_of(key: String) -> int:
	return _lookup[key]


## A group with a single material gains nothing from an atlas, so it keeps drawing with the material itself.
func is_atlased(group: int) -> bool:
	return groups[group].materials.size() > 1


func slot_of(group: int, material: Material) -> int:
	return groups[group].slots[material]


## Decides the layout of every atlas. Call it once, after all materials are registered, from the main thread.
func plan() -> void:
	if _planned:
		return
	_planned = true
	for group in groups:
		if group.materials.size() > 1:
			group.layout = HLODAtlas.layout(group.materials.size(), cell_size)
	if compress:
		_compress_mode = HLODAtlas.pick_compression()


## Bakes all atlases once, whoever asks first. Returns false if [param is_cancelled] reported a cancellation.
## [param on_progress] gets the fraction that is done. Only does CPU work, so it is safe to call from a thread.
func bake(on_progress: Callable, is_cancelled: Callable) -> bool:
	_mutex.lock()
	var finished := true
	if not _baked:
		for i in groups.size():
			var group: Dictionary = groups[i]
			if group.materials.size() > 1:
				on_progress.call(float(i) / groups.size())
				group.atlas_image = HLODAtlas.compress_image(HLODAtlas.bake(group.materials, group.images, group.layout), _compress_mode)
			if is_cancelled.call():
				finished = false
				break
		_baked = finished
	_mutex.unlock()
	return finished


## The material that draws the atlas of [param group]. It is created once and shared by every proxy of the context.
## Uses the rendering server, so call it from the main thread.
func get_material(group: int) -> StandardMaterial3D:
	if not _materials.has(group):
		var data: Dictionary = groups[group]
		_materials[group] = HLODAtlas.create_material(data.materials[0], data.atlas_image)
	return _materials[group]

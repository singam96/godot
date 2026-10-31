extends SceneTree
## Directional shadow cascade caching (engine feature). Needs Forward+ and the engine in this repository:
##   xvfb-run -a godot --path . --rendering-method forward_plus -s res://tests/run_shadow_cache_tests.gd

const S_FAR := "rendering/lights_and_shadows/directional_shadow/cache_far_cascades"
const S_MARGIN := "rendering/lights_and_shadows/directional_shadow/cache_margin"
const S_AGE := "rendering/lights_and_shadows/directional_shadow/cache_max_age_frames"

var _failed := 0
var _checks := 0
var _camera: Camera3D
var _light: DirectionalLight3D
var _mover: MeshInstance3D  # a caster in the far cascades that moves in some tests


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _shadow_calls() -> int:
	return RenderingServer.viewport_get_render_info(root.get_viewport_rid(),
			RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
			RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME)


## Renders one frame and returns the shadow draw calls it needed.
func _step() -> int:
	await process_frame
	await RenderingServer.frame_post_draw
	return _shadow_calls()


func _calls(frames: int) -> Array[int]:
	var out: Array[int] = []
	for i in frames:
		out.append(await _step())
	return out


func _sum(a: Array[int]) -> int:
	var t := 0
	for v in a:
		t += v
	return t


func _image() -> Image:
	await process_frame
	await RenderingServer.frame_post_draw
	return root.get_texture().get_image()


## Mean absolute difference of the red channel, 0..1.
func _difference(a: Image, b: Image) -> float:
	var total := 0.0
	var n := 0
	for y in range(0, a.get_height(), 2):
		for x in range(0, a.get_width(), 2):
			total += absf(a.get_pixel(x, y).r - b.get_pixel(x, y).r)
			n += 1
	return total / float(n)


func _cache(far: int, age: int = 8, margin: float = 0.25) -> void:
	ProjectSettings.set_setting(S_FAR, far)
	ProjectSettings.set_setting(S_AGE, age)
	ProjectSettings.set_setting(S_MARGIN, margin)


func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.6, 0.7, 0.9)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.2, 0.2, 0.2)
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	_light = DirectionalLight3D.new()
	_light.shadow_enabled = true
	_light.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_light.directional_shadow_max_distance = 120.0
	_light.rotation_degrees = Vector3(-50, 35, 0)
	root.add_child(_light)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400, 400)
	ground.mesh = plane
	root.add_child(ground)

	var box := BoxMesh.new()
	box.size = Vector3(2, 4, 2)
	for ix in range(-6, 7):
		for iz in range(1, 14):
			var mi := MeshInstance3D.new()
			mi.mesh = box
			mi.position = Vector3(ix * 9.0, 2.0, -iz * 9.0)
			root.add_child(mi)

	_mover = MeshInstance3D.new()
	_mover.mesh = box
	_mover.position = Vector3(3, 2, -100)
	root.add_child(_mover)

	_camera = Camera3D.new()
	_camera.far = 300.0
	_camera.position = Vector3(0, 6, 8)
	_camera.rotation_degrees = Vector3(-12, 0, 0)
	root.add_child(_camera)


func _init() -> void:
	root.size = Vector2i(320, 240)
	await process_frame
	_build_scene()
	for i in 4:
		await process_frame

	# Baseline: no caching, every cascade is rendered every frame.
	_cache(0)
	var base := await _calls(16)
	var base_image := await _image()
	print("baseline shadow draw calls per frame: ", base[-1])
	_check(base[-1] > 0, "shadows render at all")
	_check(base.min() == base.max(), "without caching every frame renders the same")

	# Static camera: far cascades should mostly be reused.
	_cache(2, 8)
	await _calls(3)
	var cached := await _calls(32)
	print("cached, static camera: min ", cached.min(), " max ", cached.max(), " avg ", float(_sum(cached)) / cached.size(), " (baseline ", base[-1], ")")
	_check(cached.min() < base[-1], "cached frames draw fewer shadow casters")
	_check(_sum(cached) < _sum(base) * 2 * 0.8, "at least 20%% fewer shadow draw calls over 32 frames")
	_check(cached.max() <= base[-1], "a cached frame never needs more than the baseline")
	var cached_image := await _image()
	var d_static := _difference(base_image, cached_image)
	print("static image difference vs baseline: ", d_static)
	_check(d_static < 0.002, "static camera image matches the baseline")

	# Slow movement stays inside the margin: still mostly reused, image still right.
	var moved := await _calls(1)
	var move_calls: Array[int] = []
	for i in 12:
		_camera.position.z -= 0.05
		move_calls.append(await _step())
	print("slow movement: min ", move_calls.min(), " max ", move_calls.max())
	_check(move_calls.min() < base[-1], "slow camera movement still reuses far cascades")
	var cached_moved := await _image()
	_cache(0)
	await _calls(3)
	var base_moved := await _image()
	_check(_difference(base_moved, cached_moved) < 0.004, "image after slow movement matches the baseline")

	# A large move leaves the margin: the far cascades must be rendered again, not reused.
	_cache(2, 8)
	await _calls(40)
	var steady := await _calls(4)
	_camera.position.z -= 60.0
	var jump := await _calls(3)
	print("after a 60m jump: ", jump, " (steady ", steady, ")")
	_check(jump.max() > steady.max(), "leaving the margin renders the far cascades again")
	await _calls(4)
	var cached_jump := await _image()
	_cache(0)
	await _calls(3)
	var base_jump := await _image()
	_check(_difference(base_jump, cached_jump) < 0.004, "image after a large move matches the baseline")

	# The light turns: every cached cascade is invalid, shadows must follow immediately.
	_cache(2, 8)
	await _calls(40)
	_light.rotation_degrees = Vector3(-35, -60, 0)
	await _calls(2)
	var cached_light := await _image()
	_cache(0)
	await _calls(3)
	var base_light := await _image()
	_check(_difference(base_light, cached_light) < 0.004, "light rotation updates cached shadows")

	# A caster in a cached cascade moves: its shadow is stale for at most max_age frames, then refreshed.
	_light.rotation_degrees = Vector3(-50, 35, 0)
	_cache(2, 6)
	await _calls(40)
	var steady_calls := await _calls(4)
	_mover.position.x += 14.0
	var refresh_calls := await _calls(6 + 3)
	print("caster moved: shadow draw calls ", refresh_calls, " (steady ", steady_calls, ")")
	_check(refresh_calls.max() > refresh_calls.min(), "a cached cascade is rendered again within its maximum age")
	var cached_caster := await _image()
	_cache(0)
	await _calls(3)
	var base_caster := await _image()
	_check(_difference(base_caster, cached_caster) < 0.004, "refreshed shadow matches the baseline")

	# Turning caching off goes back to rendering everything every frame.
	var off := await _calls(6)
	_check(off.min() == off.max() and off[-1] >= refresh_calls.max(), "caching off renders all cascades again")

	print("shadow cache tests: ", _checks, " checks, ", _failed, " failed")
	quit(1 if _failed > 0 else 0)

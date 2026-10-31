extends SceneTree
## Texture streaming upload rate (engine feature). Needs Forward+ and the engine in this repository:
##   godot --import --headless --path tests/texture_streaming_project   # once
##   xvfb-run -a godot --path tests/texture_streaming_project --rendering-method forward_plus -s res://run_streaming_texture_tests.gd

const S_RATE := "rendering/textures/streaming/max_upload_mb_per_second"

var _failed := 0
var _checks := 0
var _sprite: Sprite3D


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _used() -> int:
	return TextureStreaming.get_memory_budget_bytes_used()


## Shows the texture full screen and returns [seconds until the resident size stopped growing, final bytes].
func _run(rate_mb: int) -> Array:
	ProjectSettings.set_setting(S_RATE, rate_mb)
	ProjectSettings.settings_changed.emit()  # setting_set does not announce itself
	for i in 4:
		await process_frame
	var tex: Texture2D = ResourceLoader.load("res://noise.png", "", ResourceLoader.CACHE_MODE_IGNORE)
	_sprite = Sprite3D.new()
	_sprite.texture = tex
	_sprite.shaded = false
	_sprite.pixel_size = 0.001
	_sprite.position = Vector3(0, 0, -1.0)
	root.add_child(_sprite)
	var start := Time.get_ticks_msec()
	var last := -1
	var last_change := start
	while Time.get_ticks_msec() - start < 25000:
		await process_frame
		await RenderingServer.frame_post_draw
		var used := _used()
		if used != last:
			last = used
			last_change = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - last_change > 1500 and last > 0:
			break
	var seconds := float(last_change - start) / 1000.0
	_sprite.queue_free()
	_sprite = null
	await process_frame
	return [seconds, last]


func _init() -> void:
	root.size = Vector2i(1280, 720)
	await process_frame
	var cam := Camera3D.new()
	cam.fov = 60.0
	root.add_child(cam)
	var big := Sprite3D.new()
	big.queue_free()

	var unlimited := await _run(0)
	print("unlimited: reached ", unlimited[1], " bytes after ", unlimited[0], " s")
	_check(unlimited[1] > 0, "streaming reports resident texture memory")

	var limited := await _run(1)
	print("1 MB/s:    reached ", limited[1], " bytes after ", limited[0], " s")
	_check(limited[1] == unlimited[1], "the limited run ends at the same resolution")
	# Each step uploads the whole new texture and the next one waits for it, so reaching the last step costs
	# the steps before it: about a quarter of the final size plus the smaller ones.
	var before_last := float(unlimited[1]) / 4.0 / (1024.0 * 1024.0)
	_check(limited[0] > before_last * 0.8, "the upload rate limit slows loading down (%.2f s, steps before the last are %.2f MB)" % [limited[0], before_last])
	_check(limited[0] > unlimited[0], "limited loading is slower than unlimited")

	print("texture streaming tests: ", _checks, " checks, ", _failed, " failed")
	quit(1 if _failed > 0 else 0)

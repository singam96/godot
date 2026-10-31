extends SceneTree
## godot --headless --path . -s res://tests/run_overlay_tests.gd

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _init() -> void:
	await process_frame
	var overlay := PerfBudgetOverlay.new()
	overlay.frame_ms = 10.0
	overlay.draw_calls = 1000
	overlay.primitives = 1000000
	overlay.objects = 500
	root.add_child(overlay)
	await process_frame

	print("snapshot")
	var snap := overlay.snapshot()
	for key in ["fps", "frame_ms", "process_ms", "physics_ms", "draw_calls", "primitives", "objects", "nodes", "texture_mb", "buffer_mb", "hitches"]:
		_check(snap.has(key), "snapshot has " + key)
	_check(not snap.has("cells_detail"), "no streaming numbers without a streamer")

	print("budget status")
	var fake := {"frame_ms": 5.0, "draw_calls": 900, "primitives": 1200000, "objects": 100}
	var status := overlay.evaluate(fake)
	_check(status["frame_ms"] == "ok", "5 of 10 ms is ok")
	_check(status["draw_calls"] == "warn", "900 of 1000 is a warning")
	_check(status["primitives"] == "over", "1.2M of 1M is over")
	_check(status["objects"] == "ok", "100 of 500 is ok")

	print("hitch counting")
	overlay.set_process(false)  # Only the frames fed below count.
	overlay._hitch_times.clear()
	overlay.feed_frame(8.0)
	overlay.feed_frame(12.0)  # over budget but not a hitch (2 x 10 ms = 20 ms)
	_check(overlay.get_recent_hitches() == 0, "slow is not a hitch")
	overlay.feed_frame(35.0)
	overlay.feed_frame(21.0)
	_check(overlay.get_recent_hitches() == 2, "two hitches (%d)" % overlay.get_recent_hitches())
	for i in 1100:
		overlay.feed_frame(10.0)  # 11 s pass
	_check(overlay.get_recent_hitches() == 0, "old hitches expire")

	print("toggle")
	_check(not overlay.visible, "hidden by default")
	var key := InputEventKey.new()
	key.keycode = KEY_F3
	key.pressed = true
	overlay._unhandled_input(key)
	_check(overlay.visible, "F3 shows it")
	overlay._unhandled_input(key)
	_check(not overlay.visible, "F3 hides it")
	overlay.set_process(true)
	overlay.visible = true
	await create_timer(0.4).timeout
	_check(overlay._label.text.contains("draw calls"), "label is filled in while visible")
	_check(overlay._label.text.contains("budget"), "label shows the budget")

	print("streamer numbers")
	var holder := Node3D.new()
	holder.name = "Holder"
	root.add_child(holder)
	var streamer := WorldStreamer.new()
	streamer.name = "Streamer"
	streamer.cells_dir = "user://no_such_cells"
	holder.add_child(streamer)
	overlay.streamer = overlay.get_path_to(streamer)
	snap = overlay.snapshot()
	_check(snap.get("cells_detail", -1) == 0 and snap.get("streaming_busy", true) == false, "streamer reported %s" % [snap])

	holder.free()
	overlay.free()
	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

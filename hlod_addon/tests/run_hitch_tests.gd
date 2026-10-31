extends SceneTree
## godot --headless --path . -s res://tests/run_hitch_tests.gd   (the prewarm part runs only with a renderer)

var _failed := 0
var _checks := 0


func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failed += 1
		printerr("  FAIL: ", msg)


func _burn(ms: float) -> void:
	var end := Time.get_ticks_usec() + int(ms * 1000.0)
	while Time.get_ticks_usec() < end:
		pass


func _init() -> void:
	await process_frame
	var queue := FrameWorkQueue.new()
	root.add_child(queue)

	print("budget limits the jobs per frame")
	queue.set_process(false)
	queue.budget_ms = 3.0
	var ran := [0]
	for i in 20:
		queue.enqueue(func(): _burn(1.0); ran[0] += 1)
	queue.run_budget()
	_check(ran[0] >= 1 and ran[0] <= 5, "3 ms budget runs a few 1 ms jobs (%d)" % ran[0])
	queue.budget_ms = 0.001
	var before: int = ran[0]
	queue.run_budget()
	_check(ran[0] == before + 1, "at least one job always runs")
	while queue.get_pending_count() > 0:
		queue.run_budget()
	_check(ran[0] == 20, "everything runs eventually")

	print("priority and order")
	var order: Array[String] = []
	queue.budget_ms = 100.0
	queue.enqueue(func(): order.append("low-1"), 0)
	queue.enqueue(func(): order.append("high"), 5)
	queue.enqueue(func(): order.append("low-2"), 0)
	queue.enqueue(func(): order.append("mid"), 2)
	queue.run_budget()
	_check(order == ["high", "mid", "low-1", "low-2"], "order %s" % [order])

	print("jobs that return true continue before others of the same priority")
	order.clear()
	var slices := [3]
	queue.enqueue(func():
		order.append("slice")
		slices[0] -= 1
		return slices[0] > 0)
	queue.enqueue(func(): order.append("other"))
	queue.run_budget()
	_check(order == ["slice", "slice", "slice", "other"], "sliced job finishes first %s" % [order])

	print("slices spread over frames with a small budget")
	order.clear()
	queue.budget_ms = 0.001
	slices[0] = 4
	queue.enqueue(func():
		order.append("s")
		_burn(0.2)
		slices[0] -= 1
		return slices[0] > 0)
	var frames_needed := 0
	while queue.get_pending_count() > 0:
		queue.run_budget()
		frames_needed += 1
	_check(frames_needed == 4, "one slice per run (%d)" % frames_needed)

	print("cancel, clear and drained")
	queue.budget_ms = 100.0
	var cancelled := [false]
	var id := queue.enqueue(func(): cancelled[0] = true)
	_check(queue.cancel(id), "cancel finds the job")
	_check(not queue.cancel(id), "cancel twice finds nothing")
	var drained_count := [0]
	queue.drained.connect(func(): drained_count[0] += 1)
	queue.enqueue(func(): pass)
	queue.run_budget()
	_check(not cancelled[0] and drained_count[0] == 1, "cancelled job did not run, drained once")
	queue.enqueue(func(): cancelled[0] = true)
	queue.clear()
	queue.run_budget()
	_check(not cancelled[0] and queue.get_pending_count() == 0, "clear drops jobs")
	queue.free()

	if DisplayServer.get_name() != "headless":
		print("prewarm")
		var prewarmer := MaterialPrewarmer.new()
		prewarmer.frames = 2
		root.add_child(prewarmer)
		var scene := PackedScene.new()
		var holder := Node3D.new()
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		holder.add_child(mi)
		mi.owner = holder
		scene.pack(holder)
		holder.free()
		var material := StandardMaterial3D.new()
		material.normal_enabled = false
		var n: int = await prewarmer.prewarm([scene, material, BoxMesh.new(), 5])
		_check(n == 3, "three drawable items (%d)" % n)
		await process_frame
		_check(prewarmer.get_child_count() == 0 or prewarmer.get_child(0).is_queued_for_deletion(), "viewport cleaned up")
		prewarmer.free()
	else:
		print("(prewarm skipped: needs a renderer)")

	print("%d checks, %d failed" % [_checks, _failed])
	quit(1 if _failed > 0 else 0)

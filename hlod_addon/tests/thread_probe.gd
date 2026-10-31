extends Node3D
## Records which thread created it. Used by run_streaming_threads_tests.gd.

static var created_on: Array[int] = []


func _init() -> void:
	created_on.append(OS.get_thread_caller_id())

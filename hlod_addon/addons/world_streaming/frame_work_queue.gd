@tool
class_name FrameWorkQueue
extends Node
## Runs queued jobs within a time budget per frame, so that spawning a crowd, building a navigation mesh or placing
## props spreads over several frames instead of freezing one. At least one job runs per frame, so progress never stalls.
##
## A job is a Callable. If it returns [code]true[/code] it has more to do and is run again (before other jobs of the same
## priority), which lets you split one big loop into slices:
## [codeblock]
## queue.enqueue(func():
##     for i in 20:  # one slice
##         if todo.is_empty(): return false
##         spawn(todo.pop_back())
##     return true)
## [/codeblock]

## Emitted when the last job finished.
signal drained

@export_range(0.1, 50.0, 0.1, "suffix:ms") var budget_ms := 2.0

var _jobs: Array[Dictionary] = []  ## {"id", "priority", "callable"}
var _next_id := 1


## Adds a job. Higher [param priority] runs first; equal priorities run in the order they were added.
## Returns an id for [method cancel].
func enqueue(job: Callable, priority := 0) -> int:
	var id := _next_id
	_next_id += 1
	var entry := {"id": id, "priority": priority, "callable": job}
	# Insert after the last job with a priority >= ours.
	var index := _jobs.size()
	for i in _jobs.size():
		if _jobs[i]["priority"] < priority:
			index = i
			break
	_jobs.insert(index, entry)
	return id


## Removes a job that has not finished. Returns false if it was not found.
func cancel(id: int) -> bool:
	for i in _jobs.size():
		if _jobs[i]["id"] == id:
			_jobs.remove_at(i)
			return true
	return false


func get_pending_count() -> int:
	return _jobs.size()


## Drops all jobs without running them.
func clear() -> void:
	_jobs.clear()


func _process(_delta: float) -> void:
	run_budget()


## Runs jobs until the budget is used up. Called every frame; public so you can drive it from your own loop.
func run_budget() -> void:
	if _jobs.is_empty():
		return
	var start := Time.get_ticks_usec()
	var budget := int(budget_ms * 1000.0)
	var ran := 0
	while not _jobs.is_empty():
		if ran > 0 and Time.get_ticks_usec() - start >= budget:
			break
		var entry: Dictionary = _jobs[0]
		_jobs.remove_at(0)
		var more = entry["callable"].call()
		ran += 1
		if more is bool and more:
			# Continue next, ahead of equal priorities.
			var index := 0
			for i in _jobs.size():
				if _jobs[i]["priority"] <= entry["priority"]:
					index = i
					break
				index = i + 1
			_jobs.insert(index, entry)
	if _jobs.is_empty():
		drained.emit()

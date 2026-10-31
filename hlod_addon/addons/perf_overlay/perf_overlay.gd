class_name PerfBudgetOverlay
extends CanvasLayer
## Shows what a frame costs and how that compares with your budgets: frame time, draw calls, triangles and objects, plus
## a frame-time graph with the budget line, a count of hitches and, if you set one, the state of a WorldStreamer.
## Green is within 80% of the budget, yellow within 100%, red over it.
##
## Enabled as an autoload by the plugin. Press F3 (or call [method toggle]) in a running game.

const GRAPH_SAMPLES := 180

@export var toggle_key := KEY_F3
@export_group("Budgets")
@export_range(1.0, 100.0, 0.1, "suffix:ms") var frame_ms := 16.6
@export var draw_calls := 2500
@export var primitives := 3000000
@export var objects := 6000
## A frame longer than this many times the frame budget counts as a hitch.
@export_range(1.5, 20.0, 0.5) var hitch_factor := 2.0
@export_group("Streaming")
## A WorldStreamer to report on (optional).
@export var streamer: NodePath
@export var start_visible := false

var _label: Label
var _graph: Control
var _samples := PackedFloat32Array()
var _hitch_times: Array[float] = []  ## Time stamps (s) of recent hitches.
var _timer := 0.0
var _clock := 0.0
var _last: Dictionary = {}


func _ready() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS
	_samples.resize(GRAPH_SAMPLES)
	_samples.fill(0.0)

	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	var box := VBoxContainer.new()
	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	box.add_child(_label)
	_graph = Control.new()
	_graph.custom_minimum_size = Vector2(GRAPH_SAMPLES, 56)
	_graph.draw.connect(_draw_graph)
	box.add_child(_graph)
	panel.add_child(box)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	visible = start_visible


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.keycode == toggle_key:
		toggle()


func toggle() -> void:
	visible = not visible


func _process(delta: float) -> void:
	feed_frame(delta * 1000.0)
	_timer += delta
	if visible and _timer >= 0.25:
		_timer = 0.0
		_last = snapshot()
		_label.text = _format(_last)
		_graph.queue_redraw()


## Records one frame of [param ms] milliseconds. Called every frame by the overlay; public for tests.
func feed_frame(ms: float) -> void:
	_clock += ms / 1000.0
	for i in GRAPH_SAMPLES - 1:
		_samples[i] = _samples[i + 1]
	_samples[GRAPH_SAMPLES - 1] = ms
	if ms > frame_ms * hitch_factor:
		_hitch_times.append(_clock)
	while not _hitch_times.is_empty() and _clock - _hitch_times[0] > 10.0:
		_hitch_times.remove_at(0)


## Number of hitches in the last 10 seconds.
func get_recent_hitches() -> int:
	return _hitch_times.size()


## The current numbers: fps, frame_ms, process_ms, physics_ms, draw_calls, primitives, objects, nodes, texture_mb,
## buffer_mb, hitches, and for a streamer: cells_detail, cells_far, streaming_busy.
func snapshot() -> Dictionary:
	var rs := RenderingServer
	var data := {
		"fps": Engine.get_frames_per_second(),
		"frame_ms": _samples[GRAPH_SAMPLES - 1],
		"process_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		"physics_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		"draw_calls": rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"primitives": rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"objects": rs.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"texture_mb": rs.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0,
		"buffer_mb": rs.get_rendering_info(RenderingServer.RENDERING_INFO_BUFFER_MEM_USED) / 1048576.0,
		"hitches": get_recent_hitches(),
	}
	var node := get_node_or_null(streamer)
	if node != null and node.has_method("get_loaded_counts"):
		var counts: Dictionary = node.get_loaded_counts()
		data["cells_detail"] = counts["detail"]
		data["cells_far"] = counts["far"]
		data["streaming_busy"] = node.is_busy()
	return data


## Returns for frame_ms, draw_calls, primitives and objects: "ok", "warn" (above 80% of the budget) or "over".
func evaluate(data: Dictionary) -> Dictionary:
	return {
		"frame_ms": _status(data["frame_ms"], frame_ms),
		"draw_calls": _status(data["draw_calls"], draw_calls),
		"primitives": _status(data["primitives"], primitives),
		"objects": _status(data["objects"], objects),
	}


static func _status(value: float, budget: float) -> String:
	if budget <= 0.0:
		return "ok"
	var ratio := value / budget
	if ratio > 1.0:
		return "over"
	if ratio > 0.8:
		return "warn"
	return "ok"


static func _mark(status: String) -> String:
	match status:
		"over":
			return "  !! OVER"
		"warn":
			return "  ! close"
		_:
			return ""


func _format(data: Dictionary) -> String:
	var s := evaluate(data)
	var lines := PackedStringArray()
	lines.append("%d fps   frame %.1f ms (budget %.1f)%s" % [data["fps"], data["frame_ms"], frame_ms, _mark(s["frame_ms"])])
	lines.append("script %.1f ms   physics %.1f ms" % [data["process_ms"], data["physics_ms"]])
	lines.append("draw calls %d / %d%s" % [data["draw_calls"], draw_calls, _mark(s["draw_calls"])])
	lines.append("triangles %s / %s%s" % [_short(data["primitives"]), _short(primitives), _mark(s["primitives"])])
	lines.append("objects %d / %d%s" % [data["objects"], objects, _mark(s["objects"])])
	lines.append("nodes %d   VRAM tex %.0f MB, buf %.0f MB" % [data["nodes"], data["texture_mb"], data["buffer_mb"]])
	lines.append("hitches (10 s): %d" % data["hitches"])
	if data.has("cells_detail"):
		lines.append("cells: %d detail, %d far%s" % [data["cells_detail"], data["cells_far"], "  (loading)" if data["streaming_busy"] else ""])
	return "\n".join(lines)


static func _short(n: float) -> String:
	if n >= 1.0e6:
		return "%.1fM" % (n / 1.0e6)
	if n >= 1.0e3:
		return "%.0fk" % (n / 1.0e3)
	return str(int(n))


func _draw_graph() -> void:
	var size := _graph.size
	_graph.draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35))
	var top := frame_ms * 3.0
	var line_y := size.y - size.y * clampf(frame_ms / top, 0.0, 1.0)
	for i in GRAPH_SAMPLES:
		var ms := _samples[i]
		var h := size.y * clampf(ms / top, 0.0, 1.0)
		var color := Color(0.4, 0.9, 0.4)
		if ms > frame_ms * hitch_factor:
			color = Color(1.0, 0.3, 0.3)
		elif ms > frame_ms:
			color = Color(1.0, 0.85, 0.3)
		var x := size.x * float(i) / float(GRAPH_SAMPLES)
		_graph.draw_line(Vector2(x, size.y), Vector2(x, size.y - h), color)
	_graph.draw_line(Vector2(0, line_y), Vector2(size.x, line_y), Color(1, 1, 1, 0.6))

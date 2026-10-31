@tool
extends EditorPlugin
## Registers the overlay as an autoload called "PerfOverlay" (toggle it with F3 in a running game).

const AUTOLOAD := "PerfOverlay"


func _enter_tree() -> void:
	add_autoload_singleton(AUTOLOAD, "res://addons/perf_overlay/perf_overlay.gd")


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD)

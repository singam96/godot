extends SceneTree
func _init() -> void:
	var img := Image.create(2048, 2048, false, Image.FORMAT_RGB8)
	for y in 2048:
		for x in 2048:
			img.set_pixel(x, y, Color(float(x % 256) / 255.0, float(y % 256) / 255.0, float((x / 256 + y / 256) % 2), 1.0))
	img.save_png("res://noise.png")
	quit()

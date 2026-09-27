extends SceneTree
func _init() -> void:
	call_deferred("_run")
func _run() -> void:
	var d := DirAccess.open("res://refs/staff")
	for f in d.get_files():
		if not f.ends_with(".png"):
			continue
		var img: Image = load("res://refs/staff/" + f)
		if img == null:
			print("STAFF %s LOAD FAIL" % f)
			continue
		print("STAFF %s %dx%d fmt=%d" % [f, img.get_width(), img.get_height(), img.get_format()])
	quit(0)

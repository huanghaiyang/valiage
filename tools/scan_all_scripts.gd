extends SceneTree
func _initialize() -> void:
	var dirs := ["res://scripts", "res://tools", "res://addons"]
	var files: Array = []
	for d in dirs:
		var st: Array = [d]
		while not st.is_empty():
			var cur: String = st.pop_back()
			var da := DirAccess.open(cur)
			if da == null: continue
			da.list_dir_begin()
			while true:
				var n := da.get_next()
				if n == "": break
				if n.begins_with("."): continue
				var p := cur.path_join(n)
				if da.current_is_dir(): st.append(p)
				elif n.ends_with(".gd"): files.append(p)
			da.list_dir_end()
	print("扫描 %d 个 .gd……" % files.size())
	var bad := 0
	for f in files:
		var sc: Variant = load(String(f))
		if sc == null:
			bad += 1
			print("  ✗ %s" % f)
	print("==== 失败 %d / %d ====" % [bad, files.size()])
	quit()
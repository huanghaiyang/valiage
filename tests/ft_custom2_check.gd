extends SceneTree
## 检查转换器产物的 CUSTOM2（宿主枝条）是否齐全：
##   godot --headless --path . --script res://tests/ft_custom2_check.gd -- --dir=res://_ft_tmp/wind

func _initialize() -> void:
	var dir := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--dir="):
			dir = String(a).substr(6)
	if dir == "":
		print("用法：--dir=res://.../wind")
		quit(1)
		return
	var d := DirAccess.open(dir)
	if d == null:
		print("FAIL 目录不存在：%s" % dir)
		quit(1)
		return
	var ok := 0
	var bad := 0
	for f in d.get_files():
		if not f.ends_with(".res"):
			continue
		var am: ArrayMesh = load(dir.path_join(f))
		if am == null:
			print("FAIL 加载 %s" % f)
			bad += 1
			continue
		var a: Array = am.surface_get_arrays(0)
		var n: int = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var c2: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM2] if a.size() > Mesh.ARRAY_CUSTOM2 else PackedFloat32Array()
		var tagged := 0
		for i in n:
			if c2.size() == n * 4 and c2[i * 4 + 3] > 0.5:
				tagged += 1
		var leaf := f.contains("Leaves") or f.contains("Flowers")
		var good := c2.size() == n * 4 and (not leaf or tagged == n)
		print("%s %-18s verts=%6d CUSTOM2=%s%s" % ["✓" if good else "✗", f, n,
				("yes" if c2.size() == n * 4 else "NO"), (" tagged=%d" % tagged) if leaf else ""])
		if good:
			ok += 1
		else:
			bad += 1
	print("RESULT: %s (ok=%d bad=%d)" % ["PASS" if bad == 0 else "FAIL", ok, bad])
	quit(0 if bad == 0 else 1)

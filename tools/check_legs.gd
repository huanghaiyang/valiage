extends SceneTree

## 量"劈叉"：rest 下大腿/小腿的横向张角、两脚横向距离、脚的高度
## godot --headless --path <项目> --script res://tools/check_legs.gd -- <模型1> [模型2] ...

const RAD2DEG := 57.29577951308232


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _seg(sk: Skeleton3D, idx: int) -> Vector3:
	var o := sk.get_bone_global_rest(idx).origin
	var best := Vector3.ZERO
	for c in sk.get_bone_count():
		if sk.get_bone_parent(c) == idx:
			var d := sk.get_bone_global_rest(c).origin - o
			if d.length() > best.length():
				best = d
	return best.normalized()


func _report(p: String) -> void:
	var ps: PackedScene = load(p)
	if ps == null:
		print("✗ 载入失败 " + p)
		return
	var m := ps.instantiate()
	var sk := _find(m, "Skeleton3D") as Skeleton3D
	if sk == null:
		print("✗ 无骨架 " + p)
		m.free()
		return
	print("\n== %s ==" % p.get_file())
	var tl := sk.find_bone("thigh_stretch.l")
	var tr := sk.find_bone("thigh_stretch.r")
	var ll := sk.find_bone("leg_stretch.l")
	var lr := sk.find_bone("leg_stretch.r")
	var fl := sk.find_bone("foot.l")
	var fr := sk.find_bone("foot.r")
	var hips := sk.find_bone("root.x")
	if tl < 0 or tr < 0:
		print("  找不到 thigh_stretch.l/.r，列出腿脚骨：")
		for i in sk.get_bone_count():
			var n := sk.get_bone_name(i).to_lower()
			if n.contains("thigh") or n.contains("leg") or n.contains("foot") or n.contains("toe") or n.contains("hip") or n.contains("pelvis"):
				print("    %s(%d)" % [sk.get_bone_name(i), i])
		m.free()
		return
	var dtl := _seg(sk, tl)
	var dtr := _seg(sk, tr)
	# 横向张角：骨方向与"竖直向下"在**额状面（左右+上下）**内的夹角
	var side_avg := Vector3(dtl.x + dtr.x, dtl.y + dtr.y, 0.0)
	if side_avg.length() > 0.01:
		side_avg = side_avg.normalized()
	for pair in [["大腿", dtl, "左"], ["大腿", dtr, "右"]]:
		var d: Vector3 = pair[1]
		var flat := Vector3(d.x, d.y, 0.0)
		if flat.length() < 0.01:
			continue
		var ang := rad_to_deg(flat.normalized().signed_angle_to(Vector3.DOWN, Vector3.FORWARD))
		print("  %s%s：与竖直向下（额状面内）夹角 %+.1f°%s" % [
			pair[2], pair[0], ang, "   ← 向外张开（劈叉）✗" if absf(ang) > 8.0 else " ✓"])
	if hips >= 0:
		var ho := sk.get_bone_global_rest(hips).origin
		print("  髋高 %.3f" % ho.y)
		for pair in [["左脚", fl], ["右脚", fr], ["左膝", ll], ["右膝", lr]]:
			var bi := int(pair[1])
			if bi < 0:
				continue
			var o := sk.get_bone_global_rest(bi).origin
			print("    %s：x %+.3f  y %.3f（相对髋 x 偏差 %+.3f）" % [pair[0], o.x, o.y, o.x - ho.x])
		if fl >= 0 and fr >= 0:
			var d := absf(sk.get_bone_global_rest(fl).origin.x - sk.get_bone_global_rest(fr).origin.x)
			print("    → 两脚横向间距 %.3f（髋高 %.3f，比值 %.2f）" % [d, ho.y, d / maxf(0.001, ho.y)])
	m.free()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		args = ["res://assets/models/characters/主角.glb"]
	for a in args:
		_report(String(a))
	quit()

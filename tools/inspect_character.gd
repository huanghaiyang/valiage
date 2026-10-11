extends SceneTree

## 体检任意角色模型：godot --headless --path <项目> --script res://tools/inspect_character.gd -- <模型路径>
## 输出：骨骼数/命名族、手骨、身高（世界包围盒）、rest 下两脚外八角、是否自带 AnimationPlayer

const RAD2DEG := 57.29577951308232


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _mesh_aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is VisualInstance3D and cur is Node3D and not (cur is Light3D):
			var b := (cur as VisualInstance3D).get_aabb()
			var xf := (cur as Node3D).global_transform
			var o := AABB(xf * b.position, Vector3.ZERO)
			for i in 8:
				o = o.expand(xf * (b.position + Vector3(
					b.size.x if (i & 1) else 0.0,
					b.size.y if (i & 2) else 0.0,
					b.size.z if (i & 4) else 0.0)))
			out = o if first else out.merge(o)
			first = false
		for c in cur.get_children():
			stack.append(c)
	return out


func _horiz_dir(sk: Skeleton3D, idx: int) -> Vector3:
	var o := sk.get_bone_global_rest(idx).origin
	var best := Vector3.ZERO
	for c in sk.get_bone_count():
		if sk.get_bone_parent(c) == idx:
			var d := sk.get_bone_global_rest(c).origin - o
			if d.length() > best.length():
				best = d
	if best.length() < 0.0001:
		best = sk.get_bone_global_rest(idx).basis.y
	best.y = 0.0
	return best.normalized() if best.length() > 0.0001 else Vector3.FORWARD


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		print("用法：-- <模型路径>")
		quit()
		return
	var p := args[0]
	var ps: PackedScene = load(p)
	if ps == null:
		print("✗ 载入失败（常见原因：外置贴图缺失）→ " + p)
		quit()
		return
	var model := ps.instantiate()
	get_root().add_child(model)
	print("== %s ==" % p.get_file())
	print("① 根 %s（%s），子节点 %d 个" % [model.name, model.get_class(), model.get_child_count()])
	var skel := _find(model, "Skeleton3D") as Skeleton3D
	var ap := _find(model, "AnimationPlayer") as AnimationPlayer
	print("② 骨架 %s｜骨骼 %d｜自带动画 %s" % [
		"有 ✓" if skel != null else "无 ✗",
		skel.get_bone_count() if skel != null else -1,
		"有（%d 条）" % ap.get_animation_list().size() if ap != null else "无"])
	if skel != null:
		var hands := PackedStringArray()
		for i in skel.get_bone_count():
			var n := skel.get_bone_name(i)
			if n.to_lower().contains("hand"):
				hands.append("%s(%d)" % [n, i])
		print("   手骨：%s" % (", ".join(hands) if not hands.is_empty() else "无 ✗"))
		var n0 := PackedStringArray()
		for i in mini(skel.get_bone_count(), 12):
			n0.append(skel.get_bone_name(i))
		print("   前 12 骨骼：%s" % ", ".join(n0))
		# rest 外八
		var fl := skel.find_bone("foot.l")
		var fr := skel.find_bone("foot.r")
		if fl >= 0 and fr >= 0:
			var dl := _horiz_dir(skel, fl)
			var dr := _horiz_dir(skel, fr)
			var avg: Vector3 = dl + dr
			avg.y = 0.0
			avg = avg.normalized() if avg.length() > 0.01 else Vector3.FORWARD
			print("   rest 外八：左脚 %+.1f°｜右脚 %+.1f°%s" % [
				rad_to_deg(dl.signed_angle_to(avg, Vector3.UP)),
				rad_to_deg(dr.signed_angle_to(avg, Vector3.UP)),
				"   ← 会被烘焙期的 fix_foot_splay 自动转正 ✓" if absf(rad_to_deg(dl.signed_angle_to(avg, Vector3.UP))) > 8.0 else " ✓"])
	var box := _mesh_aabb(model)
	print("③ 网格世界包围盒：高 %.3f m｜尺寸 %s" % [
		box.size.y, str(box.size.snapped(Vector3(0.001, 0.001, 0.001)))])
	print("   → 缩到 1.5 m 需要：× %.5f" % (1.5 / maxf(0.001, box.size.y)))
	quit()

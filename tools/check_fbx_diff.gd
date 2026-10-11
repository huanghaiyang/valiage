extends SceneTree

## 对比两个 FBX：找出"调整过的那个为什么展示异常"
## 关键检查：骨架数量 / 骨骼命名 / 动画轨道路径能否解析 / 网格（尤其道具）的父节点与局部变换

const A := "res://assets/mixamo/Standing Torch Idle 01.fbx"
const B := "res://assets/mixamo/Standing Torch Idle 01 - stuff.fbx"
const MAX_DEPTH := 4
const RAD2DEG := 57.29577951308232


func _load_scene(p: String) -> Node:
	var ps: PackedScene = load(p)
	if ps == null:
		return null
	return ps.instantiate()


func _count(n: Node, cls: String) -> int:
	var c := 1 if n.is_class(cls) else 0
	for ch in n.get_children():
		c += _count(ch, cls)
	return c


func _find_all(n: Node, cls: String, out: Array) -> void:
	if n.is_class(cls):
		out.append(n)
	for ch in n.get_children():
		_find_all(ch, cls, out)


func _tree(n: Node, depth: int, tag: String) -> void:
	if depth > MAX_DEPTH:
		return
	var extra := ""
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var bb := mi.mesh.get_aabb() if mi.mesh != null else AABB()
		var sc := mi.transform.basis.get_scale()
		extra = "  [网格 顶点%s AABB %s 缩放 %s]" % [
			str(mi.mesh.get_surface_count()) if mi.mesh != null else "-",
			str(bb.size.snapped(Vector3(0.001, 0.001, 0.001))),
			str(sc.snapped(Vector3(0.0001, 0.0001, 0.0001)))]
	elif n is Skeleton3D:
		extra = "  [骨骼 %d]" % (n as Skeleton3D).get_bone_count()
	elif n is AnimationPlayer:
		extra = "  [动画 %d 条]" % (n as AnimationPlayer).get_animation_list().size()
	elif n is Node3D:
		var s := (n as Node3D).transform.basis.get_scale()
		if s.distance_to(Vector3.ONE) > 0.001:
			extra = "  [缩放 %s]" % str(s.snapped(Vector3(0.0001, 0.0001, 0.0001)))
	print("%s%s%s  <<%s>>%s" % [tag, "  ".repeat(depth), n.name, n.get_class(), extra])
	for ch in n.get_children():
		_tree(ch, depth + 1, tag)


func _report(p: String, tag: String) -> void:
	print("\n================= %s  %s =================" % [tag, p.get_file()])
	var root := _load_scene(p)
	if root == null:
		print("  ✗ 载入失败")
		return
	_tree(root, 0, tag)

	var skels: Array = []
	_find_all(root, "Skeleton3D", skels)
	print("--- 骨架数 = %d ---" % skels.size())
	for s in skels:
		var sk := s as Skeleton3D
		var names := PackedStringArray()
		for i in mini(sk.get_bone_count(), 10):
			names.append(sk.get_bone_name(i))
		var hips := sk.find_bone("mixamorig_Hips")
		if hips < 0:
			hips = sk.find_bone("Hips")
		var hips_y := sk.get_bone_rest(hips).origin.y if hips >= 0 else -1.0
		print("   骨架 %s：%d 骨骼｜前 10 = %s｜Hips 高度 %.4f" % [
			sk.name, sk.get_bone_count(), ", ".join(names), hips_y])

	var aps: Array = []
	_find_all(root, "AnimationPlayer", aps)
	for apn in aps:
		var ap := apn as AnimationPlayer
		for an in ap.get_animation_list():
			var a: Animation = ap.get_animation(an)
			var bad := 0
			var samples := PackedStringArray()
			for ti in a.get_track_count():
				var pth := a.track_get_path(ti)
				var node := ap.get_node_or_null(pth)
				if node == null:
					bad += 1
					if samples.size() < 3:
						samples.append(str(pth))
			print("   [%s] %s：轨道 %d｜**解析失败 %d**%s" % [
				ap.name, String(an), a.get_track_count(), bad,
				"  例：" + ", ".join(samples) if bad > 0 else " ✓ 全部命中"])
			var p0 := 0
			var p1 := 0
			for ti in a.get_track_count():
				if a.track_get_type(ti) == Animation.TYPE_POSITION_3D:
					p0 += 1
				else:
					p1 += 1
			print("        位置轨道 %d / 旋转轨道 %d｜时长 %.3fs" % [p0, p1, a.get_length()])
	root.free()


func _initialize() -> void:
	_report(A, "原版")
	_report(B, "调整版")
	quit()

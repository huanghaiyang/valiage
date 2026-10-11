extends SceneTree

## 查 FBX 里有没有"左手插槽"：① 名字像 slot/prop/weapon 的**骨骼** ② 挂在手骨上的**道具节点**（BoneAttachment3D 等）
## godot --headless --path <项目> --script res://tools/check_hand_slot.gd

const FILES := [
	"res://assets/mixamo/Standing Torch Idle 01.fbx",
	"res://assets/mixamo/Standing Torch Idle 01-stuff.fbx",
]


func _walk(n: Node, depth: int, tag: String) -> void:
	if depth > 6:
		return
	var extra := ""
	if n is BoneAttachment3D:
		extra = "   ★ BoneAttachment bone=%s" % (n as BoneAttachment3D).bone_name
	elif n is Skeleton3D:
		extra = "   [骨骼 %d]" % (n as Skeleton3D).get_bone_count()
	elif n is MeshInstance3D:
		extra = "   [网格]"
	elif n is Node3D:
		var t := (n as Node3D).transform
		var s := t.basis.get_scale()
		if t.origin.length() > 0.0001 or s.distance_to(Vector3.ONE) > 0.001:
			extra = "   变换 位置%s 缩放%s" % [
				str(t.origin.snapped(Vector3(0.001, 0.001, 0.001))),
				str(s.snapped(Vector3(0.001, 0.001, 0.001)))]
	print("%s%s%s  <<%s>>%s" % [tag, "  ".repeat(depth), n.name, n.get_class(), extra])
	for c in n.get_children():
		_walk(c, depth + 1, tag)


func _initialize() -> void:
	for p in FILES:
		print("\n================= %s =================" % p.get_file())
		var ps: PackedScene = load(p)
		if ps == null:
			print("  ✗ 载入失败（可能未导入）")
			continue
		var root := ps.instantiate()
		# 1) 整棵树（含非骨骼节点）
		_walk(root, 0, "")
		# 2) 名字像插槽的骨骼
		var sk: Skeleton3D = null
		var stack: Array[Node] = [root]
		while not stack.is_empty():
			var cur: Node = stack.pop_back()
			if cur is Skeleton3D and sk == null:
				sk = cur as Skeleton3D
			for c in cur.get_children():
				stack.append(c)
		if sk != null:
			var hits := PackedStringArray()
			for i in sk.get_bone_count():
				var bn := sk.get_bone_name(i).to_lower()
				if bn.contains("slot") or bn.contains("prop") or bn.contains("weapon") \
						or bn.contains("item") or bn.contains("attach") or bn.contains("torch") or bn.contains("staff"):
					hits.append("%s(%d)" % [sk.get_bone_name(i), i])
			print("  骨骼里像插槽/道具的：%s" % (", ".join(hits) if not hits.is_empty() else "无 ✗"))
		# 3) 挂在手附近的节点（含 BoneAttachment3D 与"父节点是手骨相关"的节点）
		print("  非骨骼节点（除 MeshInstance3D/AnimationPlayer）：")
		var found := 0
		var stack2: Array[Node] = [root]
		while not stack2.is_empty():
			var cur: Node = stack2.pop_back()
			var cls := cur.get_class()
			if cls != "MeshInstance3D" and cls != "AnimationPlayer" and cls != "Skeleton3D" \
					and cur != root and not (cur is Skeleton3D):
				print("     %s <<%s>>｜位置 %s" % [cur.name, cls,
					str((cur as Node3D).transform.origin.snapped(Vector3(0.001, 0.001, 0.001))) if cur is Node3D else "-"])
				found += 1
			for c in cur.get_children():
				stack2.append(c)
		if found == 0:
			print("     （没有）")
		root.free()
	quit()

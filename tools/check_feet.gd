extends SceneTree

## 诊断"外八"：量角色 rest（绑定）姿势下脚/腿各段的水平朝向，相对"两脚平均值"（= 正前方）的夹角

const CHARS := [
	["森林男", "res://assets/models/characters/主角.glb"],
	["法师", "res://assets/models/characters/主角.glb"],
]
const RAD2DEG := 57.29577951308232
const KEYWORDS := ["foot", "toe", "ankle", "ball", "leg", "thigh", "calf", "knee", "shin"]


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


## 用"骨骼自身 rest 的全局方向"判断骨链朝向：取骨骼原点 → 第一个子骨原点
func _seg_dir(sk: Skeleton3D, idx: int) -> Vector3:
	var o := sk.get_bone_global_rest(idx).origin
	for c in sk.get_bone_count():
		if sk.get_bone_parent(c) == idx:
			return (sk.get_bone_global_rest(c).origin - o).normalized()
	return Vector3.ZERO


func _report(label: String, path: String) -> void:
	var ps: PackedScene = load(path)
	if ps == null:
		print("✗ %s 载入失败" % label)
		return
	var m := ps.instantiate()
	var sk := _find(m, "Skeleton3D") as Skeleton3D
	if sk == null:
		print("✗ %s 无骨架" % label)
		m.free()
		return
	print("\n=========== %s（%d 骨骼）===========" % [label, sk.get_bone_count()])
	# 列出相关骨骼
	var hits := PackedStringArray()
	for i in sk.get_bone_count():
		var n := sk.get_bone_name(i).to_lower()
		for k in KEYWORDS:
			if n.contains(k):
				hits.append("%s(%d)" % [sk.get_bone_name(i), i])
				break
	print("腿/脚相关骨骼：%s" % ", ".join(hits))

	# 找左右脚骨（名字含 foot 或 toe 的末端段）
	var feet := {}
	for i in sk.get_bone_count():
		var n := sk.get_bone_name(i).to_lower()
		if n.contains("foot") or n.contains("toe"):
			var side := "l" if (n.contains(".l") or n.ends_with("l") or n.contains("left")) else ("r" if (n.contains(".r") or n.ends_with("r") or n.contains("right")) else "?")
			if side != "?" and (not feet.has(side) or n.contains("toe")):
				feet[side] = i
	var dl := _seg_dir(sk, int(feet["l"])) if feet.has("l") else Vector3.ZERO
	var dr := _seg_dir(sk, int(feet["r"])) if feet.has("r") else Vector3.ZERO
	var avg := Vector3.ZERO
	if dl.length() > 0.1 and dr.length() > 0.1:
		avg = Vector3(dl.x + dr.x, 0, dl.z + dr.z).normalized()
	if avg.length() < 0.1:
		avg = Vector3.FORWARD
	print("脚骨：l=%s r=%s" % [
		sk.get_bone_name(int(feet["l"])) if feet.has("l") else "无",
		sk.get_bone_name(int(feet["r"])) if feet.has("r") else "无"])
	print("脚掌水平方向：左 %s｜右 %s" % [
		str(Vector3(dl.x, 0, dl.z).normalized().snapped(Vector3(0.01, 0.01, 0.01))),
		str(Vector3(dr.x, 0, dr.z).normalized().snapped(Vector3(0.01, 0.01, 0.01)))])
	print("两脚平均方向（当作正前方）：%s" % str(avg.snapped(Vector3(0.01, 0.01, 0.01))))
	for pair in [["左", dl], ["右", dr]]:
		var d: Vector3 = pair[1]
		if d.length() < 0.1:
			continue
		var h := Vector3(d.x, 0, d.z).normalized()
		var ang := rad_to_deg(Vector3(d.x, 0, d.z).normalized().signed_angle_to(avg, Vector3.UP))
		print("  %s脚：相对正前方 **%+.1f°**%s" % [
			pair[0], ang, "   ← 外八 ✗" if absf(ang) > 8.0 else " ✓ 基本朝前"])
	# 顺带看大腿/小腿
	for bn in ["thigh.l", "thigh.r", "leg.l", "leg.r", "shin.l", "shin.r", "foot.l", "foot.r", "toe.l", "toe.r"]:
		var bi := sk.find_bone(bn)
		if bi < 0:
			continue
		var d := _seg_dir(sk, bi)
		if d.length() < 0.1:
			continue
		var h := Vector3(d.x, 0, d.z).normalized()
		print("     %-10s 水平朝向 %s（y 分量 %.2f）" % [
			bn, str(h.snapped(Vector3(0.01, 0.01, 0.01))), d.y])
	m.free()


func _initialize() -> void:
	for c in CHARS:
		_report(String(c[0]), String(c[1]))
	quit()

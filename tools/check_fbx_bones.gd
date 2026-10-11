extends SceneTree

## 骨骼级对比：原版 vs 调整版（找出新增/改名骨骼 + rest 姿势差异）

const A := "res://assets/mixamo/Standing Torch Idle 01.fbx"
const B := "res://assets/mixamo/Standing Torch Idle 01 - stuff.fbx"
const KEY := ["mixamorig_Hips", "mixamorig_Spine2", "mixamorig_LeftShoulder",
	"mixamorig_LeftArm", "mixamorig_LeftForeArm", "mixamorig_LeftHand",
	"mixamorig_RightHand", "mixamorig_LeftHandIndex1"]


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _bones(p: String) -> Skeleton3D:
	var ps: PackedScene = load(p)
	if ps == null:
		return null
	var root := ps.instantiate()
	var sk := _find(root, "Skeleton3D") as Skeleton3D
	if sk != null:
		sk.set_meta("_root", root)
	return sk


func _initialize() -> void:
	var sa := _bones(A)
	var sb := _bones(B)
	if sa == null or sb == null:
		print("✗ 载入失败")
		quit()
		return
	var na := {}
	var nb := {}
	for i in sa.get_bone_count():
		na[sa.get_bone_name(i)] = i
	for i in sb.get_bone_count():
		nb[sb.get_bone_name(i)] = i

	var only_a: Array = []
	for k in na.keys():
		if not nb.has(k):
			only_a.append(k)
	var only_b: Array = []
	for k in nb.keys():
		if not na.has(k):
			only_b.append(k)
	print("① 只有原版有的骨骼 %d 个：%s" % [only_a.size(), ", ".join(only_a)])
	print("② 只有调整版有的骨骼 %d 个：%s" % [only_b.size(), ", ".join(only_b)])

	print("③ 关键骨骼的 rest（位置 / 四元数，骨架空间）对比：")
	for k in KEY:
		if not na.has(k) or not nb.has(k):
			print("   %-28s 两边不同时存在（原版 %s / 调整版 %s）" % [k, na.has(k), nb.has(k)])
			continue
		var ra := sa.get_bone_rest(na[k])
		var rb := sb.get_bone_rest(nb[k])
		var dq := rad_to_deg(absf(ra.basis.get_rotation_quaternion().angle_to(rb.basis.get_rotation_quaternion())))
		var dp := ra.origin.distance_to(rb.origin)
		print("   %-28s 位置差 %.4f｜旋转差 %.2f°%s" % [
			k, dp, dq, "   ← 变了 ✗" if (dp > 0.001 or dq > 0.5) else " ✓ 一致"])

	print("④ 层级：左臂链父级（原版 → 调整版）")
	for k in ["mixamorig_LeftShoulder", "mixamorig_LeftArm", "mixamorig_LeftForeArm", "mixamorig_LeftHand"]:
		var pa := sa.get_bone_parent(na[k]) if na.has(k) else -1
		var pb := sb.get_bone_parent(nb[k]) if nb.has(k) else -1
		print("   %-28s %s → %s" % [k,
			sa.get_bone_name(pa) if pa >= 0 else "-",
			sb.get_bone_name(pb) if pb >= 0 else "-"])
	quit()

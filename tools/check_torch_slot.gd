extends SceneTree

## 查 Mixamo torch 动作里：有没有额外的"插槽骨骼"？道具（火把）挂在哪、带什么角度？

const F := "res://assets/mixamo/Standing Torch Idle 01.fbx"
const PI_D := 57.29577951308232


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _initialize() -> void:
	var ps: PackedScene = load(F)
	if ps == null:
		print("✗ 载入失败")
		quit()
		return
	var root := ps.instantiate()
	var skel := _find(root, "Skeleton3D") as Skeleton3D
	print("① 骨骼数 = %d（标准 Mixamo 人形是 65）" % (skel.get_bone_count() if skel != null else -1))
	var bones := PackedStringArray()
	if skel != null:
		for i in skel.get_bone_count():
			var n := skel.get_bone_name(i)
			if n.to_lower().contains("torch") or n.to_lower().contains("slot") or n.to_lower().contains("prop") \
					or n.to_lower().contains("weapon") or n.to_lower().contains("attach") or n.to_lower().contains("item"):
				bones.append(n)
	print("② 名字像'插槽/道具'的骨骼：%s" % ("无 ✗（说明没有专门插槽骨骼）" if bones.is_empty() else ", ".join(bones)))
	print("③ 场景里的网格节点及其父节点（道具就挂在这里）：")
	for c in root.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		var p := mi.get_parent()
		var pn := String(p.name) if p != null else "-"
		var pc := p.get_class() if p != null else "-"
		var bn := ""
		if p is BoneAttachment3D:
			bn = " bone_name=%s" % (p as BoneAttachment3D).bone_name
		var tf := mi.transform
		var e := tf.basis.get_euler() * PI_D
		print("   %-34s 父=%-18s(%s)%s" % [String(root.get_path_to(mi)), pn, pc, bn])
		print("        局部位置 %s｜局部欧拉角(度) (%.1f, %.1f, %.1f)｜缩放 %s" % [
			str(tf.origin.snapped(Vector3(0.001, 0.001, 0.001))),
			e.x, e.y, e.z, str(tf.basis.get_scale().snapped(Vector3(0.001, 0.001, 0.001)))])
	quit()

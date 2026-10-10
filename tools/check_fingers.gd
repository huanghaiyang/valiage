extends SceneTree

## 排查手指骨骼：目标角色（森林男）与源动画（Mixamo）各自的手指骨骼名

const TGT := "res://assets/models/characters/森林男.glb"
const SRC := "res://assets/mixamo/Standard Walk.fbx"


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _dump(skel: Skeleton3D, tag: String) -> void:
	print("=== %s（共 %d 骨骼）里的手指骨骼 ===" % [tag, skel.get_bone_count()])
	var hits := PackedStringArray()
	var other := PackedStringArray()
	for i in skel.get_bone_count():
		var n := skel.get_bone_name(i)
		if n.to_lower().contains("index") or n.to_lower().contains("thumb") \
				or n.to_lower().contains("middle") or n.to_lower().contains("ring") \
				or n.to_lower().contains("pinky") or n.to_lower().contains("finger") \
				or n.to_lower().contains("hand"):
			hits.append("%s(%d)" % [n, i])
		elif not n.contains(".") and not n.contains("_"):
			other.append(n)
	print("  手指/手相关 %d 个：" % hits.size())
	for i in range(0, hits.size(), 6):
		print("    " + ", ".join(hits.slice(i, mini(i + 6, hits.size()))))


func _initialize() -> void:
	var tp: PackedScene = load(TGT)
	if tp != null:
		var t := tp.instantiate()
		var ts := _find(t, "Skeleton3D") as Skeleton3D
		if ts != null:
			_dump(ts, "目标 森林男")
		t.free()
	var sp: PackedScene = load(SRC)
	if sp != null:
		var s := sp.instantiate()
		var ss := _find(s, "Skeleton3D") as Skeleton3D
		if ss != null:
			_dump(ss, "源 Mixamo")
		s.free()
	quit()

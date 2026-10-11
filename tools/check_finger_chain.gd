extends SceneTree

## 量两边手指骨链的"语义"：每节骨的起点、长度、子骨数
## 用来判断：Mixamo 的 Index4 是"末节指骨"还是"超出模型的末端骨"；ARP 的 index1_base 是掌骨还是近节
## godot --headless --path <项目> --script res://tools/check_finger_chain.gd

const TGT := "res://assets/models/characters/主角.glb"
const SRC := "res://assets/mixamo/Standard Walk.fbx"


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _dump(sk: Skeleton3D, hand: String, names: Array, tag: String) -> void:
	var hi := sk.find_bone(hand)
	if hi < 0:
		print("✗ %s 找不到 %s" % [tag, hand])
		return
	var ho := sk.get_bone_global_rest(hi).origin
	print("\n=== %s（手骨 %s 起点 %s）===" % [tag, hand, str(ho.snapped(Vector3(0.001, 0.001, 0.001)))])
	var prev := ho
	for n in names:
		var i := sk.find_bone(String(n))
		if i < 0:
			print("   %-26s 不存在" % n)
			continue
		var o := sk.get_bone_global_rest(i).origin
		var kids := 0
		for c in sk.get_bone_count():
			if sk.get_bone_parent(c) == i:
				kids += 1
		print("   %-26s 距手 %6.3f｜距上一节 %6.3f｜子骨 %d" % [
			n, o.distance_to(ho), o.distance_to(prev), kids])
		prev = o


func _initialize() -> void:
	var tp: PackedScene = load(TGT)
	if tp != null:
		var t := tp.instantiate()
		var ts := _find(t, "Skeleton3D") as Skeleton3D
		if ts != null:
			_dump(ts, "hand.l", ["index1_base.l", "index1.l", "index2.l", "index3.l",
				"middle1_base.l", "middle1.l", "middle2.l", "middle3.l",
				"thumb1.l", "thumb2.l", "thumb3.l"], "目标 主角（ARP）")
		t.free()
	var sp: PackedScene = load(SRC)
	if sp != null:
		var s := sp.instantiate()
		var ss := _find(s, "Skeleton3D") as Skeleton3D
		if ss != null:
			_dump(ss, "mixamorig_LeftHand", ["mixamorig_LeftHandIndex1", "mixamorig_LeftHandIndex2",
				"mixamorig_LeftHandIndex3", "mixamorig_LeftHandIndex4", "mixamorig_LeftHandIndex4_end",
				"mixamorig_LeftHandMiddle1", "mixamorig_LeftHandMiddle2", "mixamorig_LeftHandMiddle3",
				"mixamorig_LeftHandMiddle4", "mixamorig_LeftHandThumb1", "mixamorig_LeftHandThumb2",
				"mixamorig_LeftHandThumb3", "mixamorig_LeftHandThumb4"], "源 Mixamo")
		s.free()
	quit()

extends SceneTree

## 打印手指骨的映射对：源骨 → 目标骨（验证是否按语义对齐）
## godot --headless --path <项目> --script res://tools/check_finger_map.gd

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const TGT := "res://assets/models/characters/主角.glb"
const SRC := "res://assets/mixamo/Standard Walk.fbx"


func _initialize() -> void:
	var sroot := Core.instantiate_scene(SRC)
	var troot := Core.instantiate_scene(TGT)
	if sroot == null or troot == null:
		print("✗ 载入失败")
		quit()
		return
	var ss := Core.find_first(sroot, "Skeleton3D") as Skeleton3D
	var ts := Core.find_first(troot, "Skeleton3D") as Skeleton3D
	var map := Core.build_mapping(ss, ts)
	print("映射 %d 对。手指部分（源 → 目标）：" % map.size())
	var n := 0
	for si in map.keys():
		var sn := ss.get_bone_name(int(si))
		var tn := ts.get_bone_name(int(map[si]))
		var sl := sn.to_lower()
		if sl.contains("index") or sl.contains("middle") or sl.contains("thumb") \
				or sl.contains("ring") or sl.contains("pinky"):
			print("   %-30s → %s" % [sn, tn])
			n += 1
			if n >= 30:
				break
	print("（共 %d 根手指骨参与映射；目标*_base 掌骨应保持未映射）" % n)
	# 反查：目标末节 index3.l 由谁驱动
	for si in map.keys():
		if ts.get_bone_name(int(map[si])) == "index3.l":
			print("★ 目标末节 index3.l ← 源 %s" % ss.get_bone_name(int(si)))
	quit()

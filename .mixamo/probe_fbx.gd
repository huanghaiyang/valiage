extends SceneTree

## 检查导入后的 Mixamo FBX：骨骼、动画条数/名字/时长、轨道路径

const DIR := "res://assets/models/mixamo"

func _ff(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _ff(c, cls)
		if r != null:
			return r
	return null


func _count(n: Node) -> int:
	var c := 0
	if n is MeshInstance3D:
		c += 1
	for ch in n.get_children():
		c += _count(ch)
	return c


func _initialize() -> void:
	var d := DirAccess.open(DIR)
	if d == null:
		print("打不开目录：", DIR)
		quit()
		return
	var files: PackedStringArray = d.get_files()
	var total_anims := 0
	for f in files:
		if not String(f).to_lower().ends_with(".fbx"):
			continue
		var path := DIR + "/" + String(f)
		var ps: PackedScene = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		if ps == null:
			print("✗ 加载失败：", path)
			continue
		var root := ps.instantiate()
		var skel := _ff(root, "Skeleton3D") as Skeleton3D
		var ap := _ff(root, "AnimationPlayer") as AnimationPlayer
		print("=== %s" % String(f))
		print("   网格节点=%d  骨架=%s" % [_count(root), "有" if skel != null else "无"])
		if skel != null:
			var names := PackedStringArray()
			for i in mini(6, skel.get_bone_count()):
				names.append(skel.get_bone_name(i))
			print("   骨骼 %d 根；前 6：%s" % [skel.get_bone_count(), ", ".join(names)])
			print("   有 mixamorig: 前缀 = %s ｜ 含 Hips=%s 含 mixamorig:Hips=%s" % [
				skel.find_bone("mixamorig:Hips") >= 0 or String(skel.get_bone_name(0)).begins_with("mixamorig:"),
				skel.find_bone("Hips") >= 0, skel.find_bone("mixamorig:Hips") >= 0])
		if ap == null:
			print("   ✗ 没有 AnimationPlayer（没有动画）")
		else:
			for lname in ap.get_animation_library_list():
				var lib: AnimationLibrary = ap.get_animation_library(lname)
				var list := lib.get_animation_list()
				total_anims += list.size()
				print("   动画库 '%s'：%d 条" % [String(lname), list.size()])
				for an in list:
					var a: Animation = lib.get_animation(an)
					var sample := ""
					for ti in mini(2, a.get_track_count()):
						sample += String(a.track_get_path(ti)) + "  "
					print("      • %-28s %.2fs  %d 轨道   轨道示例: %s" % [
						String(an), a.get_length(), a.get_track_count(), sample])
		root.free()
	print("=== 合计动画条数 = %d ===" % total_anims)
	quit()

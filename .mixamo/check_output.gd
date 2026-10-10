extends SceneTree

## 产物自检：森林男_mixamo.tres 的动画/轨道能否在 森林男.glb 里解析

const TGT := "res://assets/models/characters/森林男.glb"
const LIB := "res://assets/animations/森林男_mixamo.tres"
const SCENE := "res://assets/animations/森林男_mixamo_scene.tscn"

func _ff(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _ff(c, cls)
		if r != null:
			return r
	return null


func _initialize() -> void:
	var root := (ResourceLoader.load(TGT) as PackedScene).instantiate()
	var skel := _ff(root, "Skeleton3D") as Skeleton3D
	var lib: AnimationLibrary = load(LIB)
	print("库：%s（%.1f MB）" % [LIB.get_file(), FileAccess.get_file_as_bytes(LIB).size() / 1048576.0])
	var anims := lib.get_animation_list()
	print("动画 %d 条：" % anims.size())
	var total_tracks := 0
	var bad := 0
	var bad_paths := {}
	for an in anims:
		var a: Animation = lib.get_animation(an)
		total_tracks += a.get_track_count()
		var bad_here := 0
		for ti in a.get_track_count():
			var np := a.track_get_path(ti)
			var node := root.get_node_or_null(NodePath(String(np.get_concatenated_names())))
			if node == null or not (node is Skeleton3D):
				bad += 1
				bad_here += 1
				bad_paths[String(np.get_concatenated_names())] = true
				continue
			if (node as Skeleton3D).find_bone(String(np.get_concatenated_subnames())) < 0:
				bad += 1
				bad_here += 1
				bad_paths[String(np.get_concatenated_subnames())] = true
		print("   • %-22s %.2fs  %d 轨道  失效 %d" % [String(an), a.get_length(), a.get_track_count(), bad_here])
	print("轨道合计 %d，失效 %d %s" % [total_tracks, bad, "" if bad == 0 else ("失效路径/骨骼：" + ", ".join(bad_paths.keys()))])
	print("场景文件：%s 存在=%s" % [SCENE.get_file(), FileAccess.file_exists(SCENE)])
	root.free()
	quit()

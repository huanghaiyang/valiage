extends SceneTree
## TEMP: 诊断烘焙 key 值 + 用 AnimationPlayer 播放采样 global pose

func _init() -> void:
	# 1) 检查烘焙库 Wave 的 upperarm.l 旋转 key 值是否变化
	var lib: AnimationLibrary = load("res://assets/animations/kaykit_library.tres")
	var w: Animation = lib.get_animation("Wave")
	print("== Wave tracks ==")
	for t in w.get_track_count():
		var p := str(w.track_get_path(t))
		if p.contains("upperarm.l") or p.contains("hips"):
			var vals := ""
			for k in w.track_get_key_count(t):
				vals += " " + str(w.track_get_key_value(t, k))
			print("  %s type=%d keys=%d val=%s" % [p, w.track_get_type(t), w.track_get_key_count(t), vals])

	# 2) 用 AnimationPlayer play + seek 采样 global pose
	var mage_scene: PackedScene = load("res://assets/models/characters/Mage.glb")
	var mage := mage_scene.instantiate()
	root.add_child(mage)
	var ap := _find_anim_player(mage)
	var sk := _find_skeleton(mage)
	ap.add_animation_library("kaykit", lib)
	var rest := sk.get_bone_global_pose(sk.find_bone("upperarm.l")).origin
	for an in ["Wave", "Hop", "Roll"]:
		ap.play("kaykit/" + an)
		for frac in [0.3, 0.7]:
			ap.seek(ap.current_animation_length * frac, true)
			sk.force_update_all_bone_transforms()
			var h := sk.get_bone_global_pose(sk.find_bone("hips"))
			var a := sk.get_bone_global_pose(sk.find_bone("upperarm.l"))
			var hd := sk.get_bone_global_pose(sk.find_bone("head"))
			print("  %s@%.2f hip=%s arm=%s head=%s" % [an, frac, h.origin.round(), a.origin.round(), hd.origin.round()])
	ap.stop()
	root.remove_child(mage)
	mage.free()
	quit()

func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null

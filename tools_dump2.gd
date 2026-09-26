extends SceneTree
## TEMP: dump Mage 全部骨骼名 + KayKit 源动画轨道路径（确认重定向映射）

func _init() -> void:
	var mage_scene: PackedScene = load("res://assets/models/characters/Mage.glb")
	var mage := mage_scene.instantiate()
	root.add_child(mage)
	var ms := _find_skeleton(mage)
	if ms != null:
		print("MAGE BONES (%d):" % ms.get_bone_count())
		var names := PackedStringArray()
		for i in ms.get_bone_count():
			names.append(ms.get_bone_name(i))
		print("  ", ", ".join(names))
		# rest pose 关键骨局部旋转（确认姿态）
		for bn in ["hips", "chest", "upperarm.l", "upperarm.r", "head", "hand.l", "hand.r"]:
			var bi := ms.find_bone(bn)
			if bi >= 0:
				print("  REST %s: origin=%s rot=%s" % [bn, ms.get_bone_rest(bi).origin, ms.get_bone_rest(bi).basis.get_euler()])
	root.remove_child(mage)
	mage.free()

	var kk_scene: PackedScene = load("res://assets/models/kaykit_anim/Animations/gltf/KayKit_AnimatedCharacter_v1.2.glb")
	var kk := kk_scene.instantiate()
	root.add_child(kk)
	var kk_sk := _find_skeleton(kk)
	if kk_sk != null:
		for i in kk_sk.get_bone_count():
			var bn := kk_sk.get_bone_name(i)
			print("KAYKIT REST %s: origin=%s rot=%s" % [bn, kk_sk.get_bone_rest(i).origin, kk_sk.get_bone_rest(i).basis.get_euler()])
	var kk_ap := _find_anim_player(kk)
	if kk_ap != null:
		for an in ["Wave", "Dance", "Climbing", "Roll", "DashFront", "Defeat", "HeavyAttack", "Hop", "LayingDownIdle"]:
			if kk_ap.has_animation(an):
				var anim: Animation = kk_ap.get_animation(an)
				print("KAYKIT ANIM %s tracks=%d len=%.2f" % [an, anim.get_track_count(), anim.length])
				for t in anim.get_track_count():
					if t < 40:
						print("    ", anim.track_get_path(t))
	root.remove_child(kk)
	kk.free()
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

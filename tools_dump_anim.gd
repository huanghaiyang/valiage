extends SceneTree
## TEMP: dump KayKit 动画包 vs Mage 的骨骼/动画，验证动画可否复用

func _init() -> void:
	var paths := [
		"res://assets/models/characters/Mage.glb",
		"res://assets/models/kaykit_anim/Animations/gltf/KayKit_AnimatedCharacter_v1.2.glb",
	]
	for p in paths:
		print("======== ", p)
		var ps: PackedScene = load(p)
		if ps == null:
			print("  LOAD FAIL")
			continue
		var inst := ps.instantiate()
		if inst == null:
			print("  INSTANTIATE FAIL")
			continue
		root.add_child(inst)
		# 动画
		var ap := _find_anim_player(inst)
		if ap != null:
			var names: PackedStringArray = ap.get_animation_list()
			print("  ANIMATIONS (%d):" % names.size())
			for nm in names:
				print("    ", nm)
		else:
			print("  NO AnimationPlayer")
		# 骨骼
		var sk := _find_skeleton(inst)
		if sk != null:
			print("  SKELETON bones=%d" % sk.get_bone_count())
			var first: Array[String] = []
			for i in mini(8, sk.get_bone_count()):
				first.append(sk.get_bone_name(i))
			print("  FIRST BONES: ", first)
		else:
			print("  NO Skeleton")
		root.remove_child(inst)
		inst.free()
	quit()

func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null

func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

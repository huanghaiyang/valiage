extends SceneTree
## TEMP: 验证烘焙库在 Mage 骨架上播放的动作幅度（global pose 采样）

func _init() -> void:
	var mage_scene: PackedScene = load("res://assets/models/characters/Mage.glb")
	var mage := mage_scene.instantiate()
	root.add_child(mage)
	var ap := _find_anim_player(mage)
	var sk := _find_skeleton(mage)
	if ap == null or sk == null:
		push_error("no anim/skeleton")
		quit(1)
		return
	var lib: AnimationLibrary = load("res://assets/animations/kaykit_library.tres")
	if lib == null:
		push_error("no lib")
		quit(1)
		return
	ap.add_animation_library("kaykit", lib)
	print("added library, has Wave: ", ap.has_animation("kaykit/Wave"))

	# 基准（rest/Idle 时各骨 global）
	var rest_hips := _global(sk, "hips")
	var rest_arm := _global(sk, "upperarm.l")
	var rest_head := _global(sk, "head")

	for an in ["Wave", "Dance", "Climbing", "Roll", "DashFront", "Defeat", "HeavyAttack", "Hop", "LayingDownIdle"]:
		var anim: Animation = lib.get_animation(an)
		# 采样动画中段和 90% 处
		for frac in [0.3, 0.7, 0.95]:
			# 手动应用动画到骨骼：逐轨道设置局部 pose，再算 global
			sk.reset_bone_poses()
			_apply_anim(sk, anim, anim.length * frac)
			var hp := _global(sk, "hips")
			var ap_ := _global(sk, "upperarm.l")
			var hd := _global(sk, "head")
			var d_hip := hp.origin - rest_hips.origin
			var d_arm := ap_.origin - rest_arm.origin
			var d_head := hd.origin - rest_head.origin
			var arm_angle := rad_to_deg(ap_.basis.get_euler().x - rest_arm.basis.get_euler().x)
			print("  %s@%.2f: hipΔ=%s armΔ=%s headΔ=%s armAngleX=%.1f°" % [an, frac, d_hip.round(), d_arm.round(), d_head.round(), arm_angle])
	root.remove_child(mage)
	mage.free()
	quit()

func _apply_anim(sk: Skeleton3D, anim: Animation, time: float) -> void:
	for t in anim.get_track_count():
		var p := str(anim.track_get_path(t))
		var parts := p.split(":")
		if parts.size() < 2:
			continue
		var bone := parts[parts.size() - 1]
		var bi := sk.find_bone(bone)
		if bi < 0:
			continue
		var typ := anim.track_get_type(t)
		var n := anim.track_get_key_count(t)
		if n == 0:
			continue
		# 取采样值（线性近似）
		var val: Variant
		if n == 1:
			val = anim.track_get_key_value(t, 0)
		else:
			var k0 := 0
			var k1 := n - 1
			for k in range(n - 1):
				if anim.track_get_key_time(t, k) <= time and time <= anim.track_get_key_time(t, k + 1):
					k0 = k
					k1 = k + 1
					break
			var t0 := anim.track_get_key_time(t, k0)
			var t1 := anim.track_get_key_time(t, k1)
			var w := 0.0
			if t1 > t0:
				w = clampf((time - t0) / (t1 - t0), 0.0, 1.0)
			if typ == Animation.TYPE_ROTATION_3D:
				val = (anim.track_get_key_value(t, k0) as Quaternion).slerp(anim.track_get_key_value(t, k1) as Quaternion, w)
			else:
				val = (anim.track_get_key_value(t, k0) as Vector3).lerp(anim.track_get_key_value(t, k1) as Vector3, w)
		match typ:
			Animation.TYPE_ROTATION_3D:
				sk.set_bone_pose_rotation(bi, val)
			Animation.TYPE_POSITION_3D:
				sk.set_bone_pose_position(bi, val)
			Animation.TYPE_SCALE_3D:
				sk.set_bone_pose_scale(bi, val)

func _global(sk: Skeleton3D, bone: String) -> Transform3D:
	return sk.get_bone_global_pose(sk.find_bone(bone))

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

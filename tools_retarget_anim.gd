extends SceneTree
## TEMP: KayKit 动画重定向烘焙 → Mage 骨骼（Rig_Medium）
## 6 骨(Body/Head/armLeft/armRight/handSlotL/handSlotR) → 41 骨对应
## 公式（局部变换增量重定向）：
##   旋转 q(t) = src_q(t) * src_rest_q.inverse() * dst_rest_q
##   位置 p(t) = dst_rest_p + (src_p(t) - src_rest_p)
## 输出 AnimationLibrary → res://assets/animations/kaykit_library.tres

const SRC_GLB := "res://assets/models/kaykit_anim/Animations/gltf/KayKit_AnimatedCharacter_v1.2.glb"
const DST_GLB := "res://assets/models/characters/Mage.glb"
const OUT_PATH := "res://assets/animations/kaykit_library.tres"

# 要烘焙的 KayKit 动画（Mage 缺失/值得新增的）
const ANIMS := ["Wave", "Dance", "Climbing", "Roll", "DashFront", "DashBack", "DashLeft", "DashRight", "Defeat", "HeavyAttack", "Hop", "LayingDownIdle"]

# KayKit 骨 -> Mage 骨
const BONE_MAP := {
	"Body": "hips",
	"Head": "head",
	"armLeft": "upperarm.l",
	"armRight": "upperarm.r",
	"handSlotLeft": "hand.l",
	"handSlotRight": "hand.r",
}

var _src_rest: Dictionary = {}   # bone -> Transform3D
var _dst_rest: Dictionary = {}   # bone -> Transform3D

func _init() -> void:
	# ---- 源骨架（KayKit）----
	var kk_scene: PackedScene = load(SRC_GLB)
	var kk := kk_scene.instantiate()
	root.add_child(kk)
	var kk_sk := _find_skeleton(kk)
	if kk_sk == null:
		push_error("KayKit skeleton not found")
		quit(1)
		return
	for bn in BONE_MAP:
		var bi := kk_sk.find_bone(bn)
		if bi < 0:
			push_error("source bone missing: " + bn)
			quit(1)
			return
		_src_rest[bn] = kk_sk.get_bone_rest(bi)
	var kk_ap := _find_anim_player(kk)
	if kk_ap == null:
		push_error("KayKit anim player not found")
		quit(1)
		return

	# ---- 目标骨架（Mage）----
	var mage_scene: PackedScene = load(DST_GLB)
	var mage := mage_scene.instantiate()
	root.add_child(mage)
	var dst_sk := _find_skeleton(mage)
	if dst_sk == null:
		push_error("Mage skeleton not found")
		quit(1)
		return
	for src_bn in BONE_MAP:
		var dst_bn: String = BONE_MAP[src_bn]
		var bi := dst_sk.find_bone(dst_bn)
		if bi < 0:
			push_error("target bone missing: " + dst_bn)
			quit(1)
			return
		_dst_rest[dst_bn] = dst_sk.get_bone_rest(bi)
	root.remove_child(mage)
	mage.free()

	# ---- 烘焙 ----
	var lib := AnimationLibrary.new()
	var ok := 0
	for an in ANIMS:
		if not kk_ap.has_animation(an):
			print("  SKIP (missing): ", an)
			continue
		var src: Animation = kk_ap.get_animation(an)
		var dst := _retarget(src, kk_sk)
		if dst == null:
			print("  FAIL: ", an)
			continue
		lib.add_animation(an, dst)
		ok += 1
		print("  BAKED: %s (%.2fs, tracks=%d)" % [an, dst.length, dst.get_track_count()])

	root.remove_child(kk)
	kk.free()

	if ok == 0:
		push_error("nothing baked")
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(OUT_PATH.get_base_dir())
	var err := ResourceSaver.save(lib, OUT_PATH)
	print("SAVE err=", err, " path=", OUT_PATH, " animations=", ok)
	quit(0 if err == OK else 1)

## 把源动画重定向为目标骨动画
func _retarget(src: Animation, kk_sk: Skeleton3D) -> Animation:
	var dst := Animation.new()
	dst.length = src.length
	dst.loop_mode = src.loop_mode
	# 按目标骨 x 轨道类型组织源轨道索引
	var src_tracks := {}   # "srcbone|TYPE" -> track idx
	for t in src.get_track_count():
		var p := str(src.track_get_path(t))
		var parts := p.split(":")
		var bone := parts[parts.size() - 1]
		if not BONE_MAP.has(bone):
			continue
		src_tracks["%s|%d" % [bone, src.track_get_type(t)]] = t

	# 对每个映射骨，写 rotation/position/scale 三轨
	for src_bn in BONE_MAP:
		var dst_bn: String = BONE_MAP[src_bn]
		var sr: Transform3D = _src_rest[src_bn]
		var dr: Transform3D = _dst_rest[dst_bn]
		var src_q := sr.basis.get_rotation_quaternion()
		var src_p := sr.origin
		var dst_q := dr.basis.get_rotation_quaternion()
		var dst_p := dr.origin

		# 旋转轨道
		var st: int = src_tracks.get("%s|%d" % [src_bn, Animation.TYPE_ROTATION_3D], -1)
		if st >= 0:
			var track := dst.add_track(Animation.TYPE_ROTATION_3D)
			dst.track_set_path(track, NodePath("Rig/Skeleton3D:%s" % dst_bn))
			for k in src.track_get_key_count(st):
				var tm := src.track_get_key_time(st, k)
				var q: Quaternion = _sample_q(src, st, tm)
				var out_q := q * src_q.inverse() * dst_q
				dst.track_insert_key(track, tm, out_q)
		# 位置轨道
		var pt: int = src_tracks.get("%s|%d" % [src_bn, Animation.TYPE_POSITION_3D], -1)
		if pt >= 0:
			var track := dst.add_track(Animation.TYPE_POSITION_3D)
			dst.track_set_path(track, NodePath("Rig/Skeleton3D:%s" % dst_bn))
			for k in src.track_get_key_count(pt):
				var tm := src.track_get_key_time(pt, k)
				var p: Vector3 = _sample_v(src, pt, tm)
				dst.track_insert_key(track, tm, dst_p + (p - src_p))
		# 缩放轨道（KayKit 一般不缩放，直接复制）
		var cst: int = src_tracks.get("%s|%d" % [src_bn, Animation.TYPE_SCALE_3D], -1)
		if cst >= 0:
			var track := dst.add_track(Animation.TYPE_SCALE_3D)
			dst.track_set_path(track, NodePath("Rig/Skeleton3D:%s" % dst_bn))
			for k in src.track_get_key_count(cst):
				var tm := src.track_get_key_time(cst, k)
				dst.track_insert_key(track, tm, _sample_v(src, cst, tm))
	return dst

## 采样旋转（NEAREST 步进 / LINEAR 插值 / CUBIC 回退线性）
func _sample_q(a: Animation, t: int, time: float) -> Quaternion:
	var n := a.track_get_key_count(t)
	if n == 1:
		return a.track_get_key_value(t, 0) as Quaternion
	var interp := a.track_get_interpolation_type(t)
	if interp == Animation.INTERPOLATION_NEAREST:
		for k in n:
			if a.track_get_key_time(t, k) >= time:
				return a.track_get_key_value(t, k) as Quaternion
		return a.track_get_key_value(t, n - 1) as Quaternion
	for k in range(n - 1):
		var t0 := a.track_get_key_time(t, k)
		var t1 := a.track_get_key_time(t, k + 1)
		if time >= t0 and time <= t1:
			var w := 0.0
			if t1 > t0:
				w = clampf((time - t0) / (t1 - t0), 0.0, 1.0)
			var q0: Quaternion = a.track_get_key_value(t, k) as Quaternion
			var q1: Quaternion = a.track_get_key_value(t, k + 1) as Quaternion
			return q0.slerp(q1, w)
	return a.track_get_key_value(t, n - 1) as Quaternion

func _sample_v(a: Animation, t: int, time: float) -> Vector3:
	var n := a.track_get_key_count(t)
	if n == 1:
		return a.track_get_key_value(t, 0) as Vector3
	var interp := a.track_get_interpolation_type(t)
	if interp == Animation.INTERPOLATION_NEAREST:
		for k in n:
			if a.track_get_key_time(t, k) >= time:
				return a.track_get_key_value(t, k) as Vector3
		return a.track_get_key_value(t, n - 1) as Vector3
	for k in range(n - 1):
		var t0 := a.track_get_key_time(t, k)
		var t1 := a.track_get_key_time(t, k + 1)
		if time >= t0 and time <= t1:
			var w := 0.0
			if t1 > t0:
				w = clampf((time - t0) / (t1 - t0), 0.0, 1.0)
			var v0: Vector3 = a.track_get_key_value(t, k) as Vector3
			var v1: Vector3 = a.track_get_key_value(t, k + 1) as Vector3
			return v0.lerp(v1, w)
	return a.track_get_key_value(t, n - 1) as Vector3

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

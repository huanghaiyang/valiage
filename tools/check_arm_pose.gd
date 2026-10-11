extends SceneTree

## 对比两条 Idle 剪辑的左臂姿态：相对 rest 的抬臂角度 + 剪辑内的变化量
## godot --headless --path <项目> --script res://tools/check_arm_pose.gd

const TGT := "res://assets/models/characters/主角.glb"
const LIB := "res://assets/animations/zhujue.tres"
const CLIPS := ["Standing Torch Idle 01", "Standing Torch Idle 01-stuff"]
const BONES := ["shoulder.l", "arm_stretch.l", "forearm_stretch.l", "hand.l"]


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _rot(a: Animation, bone: String) -> int:
	for ti in a.get_track_count():
		if a.track_get_type(ti) != Animation.TYPE_ROTATION_3D:
			continue
		if String(a.track_get_path(ti).get_concatenated_subnames()) == bone:
			return ti
	return -1


func _initialize() -> void:
	var ps: PackedScene = load(TGT)
	var m := ps.instantiate()
	var sk := _find(m, "Skeleton3D") as Skeleton3D
	var lib: AnimationLibrary = ResourceLoader.load(LIB, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	print("目标 rest（相对自身）的抬臂情况 —— 作为参照")
	for b in BONES:
		var bi := sk.find_bone(b)
		if bi < 0:
			continue
		print("   rest %-20s 存在 ✓" % b)
	print("")
	for clip in CLIPS:
		var a: Animation = lib.get_animation(StringName(clip))
		if a == null:
			print("✗ 库中缺剪辑 " + clip)
			continue
		print("== %s（时长 %.3f s）==" % [clip, a.get_length()])
		for b in BONES:
			var ti := _rot(a, b)
			var bi := sk.find_bone(b)
			if ti < 0 or bi < 0:
				print("   %-20s 无轨道 ✗" % b)
				continue
			var rest_q := sk.get_bone_rest(bi).basis.get_rotation_quaternion()
			var kc := a.track_get_key_count(ti)
			var q_first: Quaternion = a.rotation_track_interpolate(ti, a.track_get_key_time(ti, 0))
			var q_mid: Quaternion = a.rotation_track_interpolate(ti, a.get_length() * 0.5)
			var mn := 999.0
			var mx := 0.0
			for k in kc:
				var q: Quaternion = a.rotation_track_interpolate(ti, a.track_get_key_time(ti, k))
				var d := rad_to_deg(absf(rest_q.angle_to(q)))
				mn = minf(mn, d)
				mx = maxf(mx, d)
			print("   %-20s 相对 rest：首帧 %6.1f°｜中帧 %6.1f°｜范围 %.1f°~%.1f°（变化 %.1f°）" % [
				b, rad_to_deg(absf(rest_q.angle_to(q_first))), rad_to_deg(absf(rest_q.angle_to(q_mid))), mn, mx, mx - mn])
	quit()

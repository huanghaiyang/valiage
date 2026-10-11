extends SceneTree

## 量"跳跃动作自带的竖直位移"：髋部 Y 轨道的范围 / 首末是否有落差
## godot --headless --path <项目> --script res://tools/check_jump.gd

const LIB := "res://assets/animations/zhujue.tres"
const CHARS := [
	["主角库", "root.x"],
]
const SRC_FBX := "res://assets/mixamo/Standing Torch Jump.fbx"
const CLIPS := ["Standing Torch Jump", "Standing Torch Idle 01", "Standing Torch Run Forward"]


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _pos_track(a: Animation, bone: String) -> int:
	for ti in a.get_track_count():
		if a.track_get_type(ti) != Animation.TYPE_POSITION_3D:
			continue
		if String(a.track_get_path(ti).get_concatenated_subnames()) == bone:
			return ti
	return -1


func _dump(a: Animation, bone: String, tag: String) -> void:
	var ti := _pos_track(a, bone)
	print("\n-- %s｜髋骨位置轨道（%s）--" % [tag, bone])
	print("   时长 %.3f s｜循环模式 %d（0=NONE）｜轨道存在=%s" % [
		a.get_length(), a.loop_mode, ti >= 0])
	if ti < 0:
		return
	var kc := a.track_get_key_count(ti)
	var mn := INF
	var mx := -INF
	for k in kc:
		var v: Vector3 = a.position_track_interpolate(ti, a.track_get_key_time(ti, k))
		mn = minf(mn, v.y)
		mx = maxf(mx, v.y)
	var v0: Vector3 = a.position_track_interpolate(ti, a.track_get_key_time(ti, 0))
	var v1: Vector3 = a.position_track_interpolate(ti, a.get_length())
	print("   键数 %d｜Y %.3f ~ %.3f（幅度 %.3f）" % [kc, mn, mx, mx - mn])
	print("   首帧 Y %.3f｜末帧 Y %.3f（落差 %+.3f）｜水平 X %.3f Z %.3f" % [
		v0.y, v1.y, v1.y - v0.y, v1.x, v1.z])


func _initialize() -> void:
	var lib: AnimationLibrary = ResourceLoader.load(LIB, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	if lib != null:
		print("===== 烘焙库（目标=主角，单位=主角骨架单位；主角整体缩放 0.01534）=====")
		for c in CLIPS:
			var a: Animation = lib.get_animation(StringName(c))
			if a == null:
				print("\n-- 缺剪辑 %s" % c)
				continue
			_dump(a, "root.x", String(c))
	var ps: PackedScene = load(SRC_FBX)
	if ps != null:
		var m := ps.instantiate()
		var ap := _find(m, "AnimationPlayer") as AnimationPlayer
		if ap != null:
			print("\n\n===== 源 FBX（Mixamo 原始单位）=====")
			for an in ap.get_animation_list():
				var a: Animation = ap.get_animation(an)
				_dump(a, "mixamorig_Hips", "%s / %s" % [SRC_FBX.get_file(), String(an)])
		m.free()
	quit()

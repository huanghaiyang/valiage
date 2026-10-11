extends SceneTree

## 合成骨链，量"上臂在世界空间的朝向"（不依赖引擎逐帧播放）
## godot --headless --path <项目> --script res://tools/check_arm_world.gd

const TGT := "res://assets/models/characters/主角.glb"
const LIB := "res://assets/animations/zhujue.tres"
const CLIPS := ["Standing Torch Idle 01", "Standing Torch Idle 01-stuff"]


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


## 按剪辑在时间 t 的旋转 + 骨骼 rest 位置，合成到目标骨（返回骨架空间的 Transform3D）
func _compose(sk: Skeleton3D, a: Animation, bone: String, t: float) -> Transform3D:
	var idx := sk.find_bone(bone)
	if idx < 0:
		return Transform3D()
	var chain: Array[int] = []
	var i := idx
	while i >= 0:
		chain.append(i)
		i = sk.get_bone_parent(i)
	chain.reverse()
	var xf := Transform3D()
	for ci in chain:
		var local := sk.get_bone_rest(ci)
		var bn := sk.get_bone_name(ci)
		var ti := _rot(a, bn)
		if ti >= 0:
			local = Transform3D(Basis(a.rotation_track_interpolate(ti, t)), local.origin)
		xf = xf * local
	return xf


func _initialize() -> void:
	var ps: PackedScene = load(TGT)
	var m := ps.instantiate()
	var sk := _find(m, "Skeleton3D") as Skeleton3D
	var lib: AnimationLibrary = ResourceLoader.load(LIB, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	print("链：arm_stretch.l(上臂) → forearm_stretch.l(肘) ｜ 身体轴：spine_03.x → root.x")
	for clip in CLIPS:
		var a: Animation = lib.get_animation(StringName(clip))
		if a == null:
			print("✗ 缺 " + clip)
			continue
		var t := a.get_length() * 0.25
		var sh := _compose(sk, a, "arm_stretch.l", t).origin
		var el := _compose(sk, a, "forearm_stretch.l", t).origin
		var ha := _compose(sk, a, "hand.l", t).origin
		var chest := _compose(sk, a, "spine_03.x", t).origin
		var hip := _compose(sk, a, "root.x", t).origin
		var d_arm := (el - sh).normalized()          # 上臂方向
		var d_body := (hip - chest).normalized()     # 身体向下
		var d_fore := (ha - el).normalized()         # 小臂方向
		var ang := rad_to_deg(d_arm.angle_to(d_body))
		# 侧向分量：上臂在"左右方向"上的投影（正=往身体外侧张）
		var side := d_arm.dot((hip - chest).cross(Vector3.FORWARD).normalized())
		print("\n== %s（t=%.2f）==" % [clip, t])
		print("   上臂方向 %s｜与'身体向下'夹角 %5.1f° → %s" % [
			str(d_arm.snapped(Vector3(0.01, 0.01, 0.01))), ang,
			"贴着身体（夹臂）✗" if ang < 25.0 else ("向外张开 ✓" if ang < 110.0 else "举过头顶 ✓")])
		print("   小臂方向 %s｜肘部相对肩：水平 %+.3f 竖直 %+.3f" % [
			str(d_fore.snapped(Vector3(0.01, 0.01, 0.01))), (el - sh).x, (el - sh).y])
	quit()

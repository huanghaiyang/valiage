extends SceneTree

## 解"握持角"：在 Standing Torch Idle 01 的手骨姿势下，让法杖的杖身（模型 +Y）
## 对准世界竖直所需要的**本地角度**（相对手骨）。解出来就能写进角色档案当默认值。

const TGT := "res://assets/models/characters/森林男.glb"
const LIB := "res://assets/animations/mixamo.tres"
const CLIP := "Standing Torch Idle 01"
const BONE := "hand.l"
const RAD2DEG := 57.29577951308232

var _skel: Skeleton3D
var _ap: AnimationPlayer
var _k := 0
var _idx := -1
var _model: Node3D


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _initialize() -> void:
	var ps: PackedScene = load(TGT)
	_model = ps.instantiate()
	root.add_child(_model)
	_ap = _find(_model, "AnimationPlayer") as AnimationPlayer
	if _ap == null:
		_ap = AnimationPlayer.new()
		_model.add_child(_ap)
	var lib: AnimationLibrary = load(LIB)
	if lib != null:
		_ap.add_animation_library("", lib)
	_skel = _find(_model, "Skeleton3D") as Skeleton3D
	_idx = _skel.find_bone(BONE)
	print("骨骼 %s 索引 = %d｜动画库 %d 条｜播放 %s" % [BONE, _idx, _ap.get_animation_list().size(), CLIP])
	_ap.play(CLIP)


func _process(_d: float) -> bool:
	_k += 1
	if _k < 8:
		return false
	var hb := (_skel.global_transform.basis * _skel.get_bone_global_pose(_idx).basis).orthonormalized()
	# 让法杖 +Y（杖身方向）指向世界竖直：local = 手骨世界基的转置 × 单位基
	var local := hb.inverse() * Basis()
	var e := local.get_euler() * RAD2DEG
	print("① 手骨世界基：" + str(hb))
	print("② 手骨 +Y 世界方向 %s" % str((hb * Vector3.UP).snapped(Vector3(0.001, 0.001, 0.001))))
	print("③ 解出本地握持角（度）：X %.1f  Y %.1f  Z %.1f" % [e.x, e.y, e.z])
	print("   → 写进档案：\"staff_hold_rot_deg\": Vector3(%.1f, %.1f, %.1f)" % [e.x, e.y, e.z])
	# 校验：按这个角度摆，杖身方向应该正好竖直
	var check := (hb * local * Vector3.UP)
	print("④ 校验：杖身世界方向 %s → %s" % [
		str(check.snapped(Vector3(0.001, 0.001, 0.001))),
		"竖直 ✓" if check.distance_to(Vector3.UP) < 0.01 else "不竖直 ✗"])
	quit()
	return true

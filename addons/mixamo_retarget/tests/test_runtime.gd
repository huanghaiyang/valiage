extends SceneTree

## 运行时重定向验证（硬上限 25 帧，必然退出）

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const RT := preload("res://addons/mixamo_retarget/runtime/mix_retarget_node.gd")
const TGT := "res://assets/models/characters/森林男.glb"
const SRC := "res://assets/mixamo"
const CLIP := "Standard Walk"

var _node: Node3D
var _tgt_skel: Skeleton3D
var _k := 0
var _worst := 0.0
var _src_max := 0.0
var _played := false
var _done := false


func _initialize() -> void:
	var tgt := Core.instantiate_scene(TGT)
	root.add_child(tgt)
	_tgt_skel = Core.find_first(tgt, "Skeleton3D") as Skeleton3D
	_node = RT.new()
	tgt.add_child(_node)
	_node.set("source_dir", SRC)


func _process(_d: float) -> bool:
	if _done:
		return true
	_k += 1
	if _k == 2 and not _played:
		_played = true
		var ok: bool = _node.call("play", CLIP)
		print("【运行时】play(\"%s\") = %s｜映射 %d 对｜位移缩放 ×%.4f｜动作=%s" % [
			CLIP, ok, (_node.get("_pairs") as Array).size(), float(_node.get("_pos_scale")),
			String(_node.get("current_clip"))])
		return false
	if not _played or _k < 6:
		return false
	var pairs: Array = _node.get("_pairs")
	var src_skel: Skeleton3D = _node.get("_src_skel")
	if src_skel == null or pairs.is_empty():
		print("【运行时】✗ 源骨架/映射为空")
		_done = true
		return true
	var auto := _node.get("_yaw_b") as Basis
	for p in pairs:
		var si: int = p[0]
		var ti: int = p[1]
		var ds: Basis = src_skel.get_bone_global_pose(si).basis * src_skel.get_bone_global_rest(si).basis.inverse()
		var dt: Basis = _tgt_skel.get_bone_global_pose(ti).basis * _tgt_skel.get_bone_global_rest(ti).basis.inverse()
		_src_max = maxf(_src_max, rad_to_deg(ds.get_rotation_quaternion().get_angle()))
		_worst = maxf(_worst, rad_to_deg(((auto * ds).inverse() * dt).get_rotation_quaternion().get_angle()))
	if _k >= 25:
		var ok2 := _worst < 1.0 and _src_max > 5.0
		print("【运行时】姿态误差 最大 %.3f°（源最大形变 %.1f°）→ %s" % [
			_worst, _src_max, "OK ✓" if ok2 else "有问题 ✗"])
		_done = true
		return true
	return false

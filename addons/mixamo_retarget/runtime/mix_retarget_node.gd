class_name MixRetargetNode
extends Node3D

## 运行时重定向组件：把 Mixamo（或任意人形）动画搬到当前角色的骨架上，**不需要预先烘焙**。
##
## 用法：
##   var n := MixRetargetNode.new() 或直接放在场景里
##   n.source_dir = "res://assets/mixamo"     # 目录里的 fbx/glb 都成为可播放动作
##   n.target_path = ^"../root/Skeleton3D"     # 角色骨架（留空则自动找父节点下的 Skeleton3D）
##   n.play("Standard Walk")                     # 名字 = 源文件基名（多条动画时是 基名/动画名）
##
## 特点：
##   * 同一份 Mixamo 动画可给所有角色用 —— 换角色只改 target，不用重新生成任何库；
##   * 自动按髋高比缩放位移、自动对齐朝向（跟烘焙版同一套算法）；
##   * 只在播放时实例化需要的那个源骨架，切换动作时替换，不常驻 18 套骨架。

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")

@export var source_dir: String = ""                       ## 源目录（fbx/glb）；与 source_scene 二选一
@export var source_scene: PackedScene                     ## 单个源文件（可选）
@export var target_path: NodePath                         ## 目标 Skeleton3D；留空自动找
@export var auto_yaw: bool = true
@export var yaw_offset_deg: float = 0.0
@export var pos_scale_mode: String = "auto"               ## auto（髋高比）/ none
@export var speed_scale: float = 1.0
@export var autoplay_first: bool = false                   ## 就绪后自动播第一条

var target: Skeleton3D
var current_clip: String = ""
var source_file: String = ""

var _src_root: Node
var _src_skel: Skeleton3D
var _src_ap: AnimationPlayer
var _pairs: Array = []            ## [[src_idx, tgt_idx], ...]
var _src_rest_inv: Array = []
var _tgt_rest: Array = []
var _yaw_b := Basis()
var _pos_scale := 1.0
var _active := false


func _ready() -> void:
	process_priority = 100        # 保证在源 AnimationPlayer 更新姿态之后再取样
	if not _ensure_target():
		return
	if source_scene != null:
		_load_source_scene(source_scene)
	if autoplay_first:
		var list := clip_names()
		if list.size() > 0:
			play(String(list[0]))


## 解析目标骨架（可在 _ready 之外调用；别人在自己 _ready 里就 play() 也不会踩空）
func _ensure_target() -> bool:
	if target != null and is_instance_valid(target):
		return true
	target = get_node_or_null(target_path) as Skeleton3D
	if target == null:
		var host := get_parent()
		if host != null:
			target = Core.find_first(host, "Skeleton3D") as Skeleton3D
	if target == null:
		push_warning("[MixRetarget] 找不到目标 Skeleton3D")
		return false
	if _src_skel != null:
		_build_pairs()
	return true


# ------------------------------------------------------------------ 对外 API

## 目录里可播放的动作名（= 源文件基名；一个文件多条动画时是 基名/动画名）
func clip_names() -> PackedStringArray:
	var out := PackedStringArray()
	if source_dir == "":
		if _src_ap != null:
			for an in _src_ap.get_animation_list():
				out.append(String(an))
		return out
	var scan := Core.scan_sources(source_dir)
	for path in scan["files"]:
		var base := String(path).get_file().get_basename()
		var ps := _load_scene(String(path))
		if ps == null:
			continue
		var probe := ps.instantiate()
		var ap := Core.find_first(probe, "AnimationPlayer") as AnimationPlayer
		if ap != null:
			var usable := _usable_clips(ap)
			if usable.size() <= 1:
				out.append(base)
			else:
				for cn in usable:
					out.append("%s/%s" % [base, cn])
		probe.free()
	return out


## 播放：name 用 clip_names() 里的名字
func play(name: String) -> bool:
	if not _ensure_target():
		return false
	var base := name
	var want := ""
	var parts := name.split("/")
	if parts.size() > 1:
		base = parts[0]
		want = name.substr(base.length() + 1)
	if source_dir != "" and (source_file == "" or source_file.get_basename() != base):
		var scan := Core.scan_sources(source_dir)
		var found := ""
		for path in scan["files"]:
			if String(path).get_file().get_basename() == base:
				found = String(path)
				break
		if found == "":
			push_warning("[MixRetarget] 源目录里找不到：" + base)
			return false
		var ps := _load_scene(found)
		if ps == null:
			return false
		if not _load_source_scene(ps):
			return false
		source_file = found
	if _src_ap == null:
		return false
	var pick := want
	if pick == "" or not _src_ap.has_animation(pick):
		var usable := _usable_clips(_src_ap)
		if usable.is_empty():
			return false
		pick = usable[0]
	_src_ap.play(pick)
	_src_ap.speed_scale = speed_scale
	current_clip = name
	_active = true
	return true


func stop() -> void:
	_active = false
	if _src_ap != null:
		_src_ap.stop()
	if target != null:
		target.clear_bones_global_pose_override()


func is_playing() -> bool:
	return _active and _src_ap != null and _src_ap.is_playing()


# ------------------------------------------------------------------ 内部

func _load_scene(path: String) -> PackedScene:
	return ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE) as PackedScene


## 可用的动作名（跳过静止 take，比如 Mixamo 的 "Take 001"）
func _usable_clips(ap: AnimationPlayer) -> PackedStringArray:
	var out := PackedStringArray()
	for lib_name in ap.get_animation_library_list():
		var lib: AnimationLibrary = ap.get_animation_library(lib_name)
		for an in lib.get_animation_list():
			var a: Animation = lib.get_animation(an)
			if Core.motion_score(a) < 0.5:
				continue
			out.append(String(an))
	return out


func _load_source_scene(ps: PackedScene) -> bool:
	_clear_source()
	_src_root = ps.instantiate()
	add_child(_src_root)
	_hide_visuals(_src_root)
	_src_skel = Core.find_first(_src_root, "Skeleton3D") as Skeleton3D
	_src_ap = Core.find_first(_src_root, "AnimationPlayer") as AnimationPlayer
	if _src_skel == null or _src_ap == null:
		push_warning("[MixRetarget] 源里缺少骨架或动画")
		_clear_source()
		return false
	if target == null:
		return false
	_build_pairs()
	return not _pairs.is_empty()


func _clear_source() -> void:
	if _src_root != null:
		_src_root.queue_free()
	_src_root = null
	_src_skel = null
	_src_ap = null


func _hide_visuals(n: Node) -> void:
	if n is VisualInstance3D:
		(n as VisualInstance3D).visible = false
	for c in n.get_children():
		_hide_visuals(c)


func _build_pairs() -> void:
	_pairs.clear()
	_src_rest_inv.clear()
	_tgt_rest.clear()
	var mapping := Core.build_mapping(_src_skel, target)
	for si in mapping.keys():
		var ti: int = int(mapping[si])
		_pairs.append([int(si), ti])
		_src_rest_inv.append(_src_skel.get_bone_global_rest(int(si)).affine_inverse())
		_tgt_rest.append(target.get_bone_global_rest(ti))
	# 位移缩放（髋高比）
	_pos_scale = 1.0
	if pos_scale_mode == "auto":
		var sy := Core.bone_y(_src_skel, PackedStringArray(["mixamorig_Hips", "Hips"]))
		var ty := Core.bone_y(target, PackedStringArray(["root.x", "hips", "Hips"]))
		if absf(sy) > 0.0001:
			_pos_scale = ty / sy
	# 朝向
	var yaw := 0.0
	if auto_yaw:
		var sf := Core.forward_avg(_src_skel,
			PackedStringArray(["mixamorig_LeftFoot", "mixamorig_RightFoot", "LeftFoot", "RightFoot"]),
			PackedStringArray(["mixamorig_LeftToeBase", "mixamorig_RightToeBase", "LeftToeBase", "RightToeBase"]))
		var tf := Core.forward_avg(target, PackedStringArray(["foot.l", "foot.r"]),
			PackedStringArray(["toes.l", "toes.r"]))
		if sf.length() > 0.5 and tf.length() > 0.5:
			yaw = sf.signed_angle_to(tf, Vector3.UP)
	_yaw_b = Basis(Vector3.UP, yaw + deg_to_rad(yaw_offset_deg))


func _process(_delta: float) -> void:
	if not _active or target == null or _src_skel == null:
		return
	for i in _pairs.size():
		var si: int = _pairs[i][0]
		var ti: int = _pairs[i][1]
		var src_pose: Transform3D = _src_skel.get_bone_global_pose(si)
		var d: Transform3D = src_pose * _src_rest_inv[i]
		var want := Transform3D(_yaw_b * d.basis * _tgt_rest[i].basis, Vector3.ZERO)
		var src_delta: Vector3 = src_pose.origin - _src_skel.get_bone_global_rest(si).origin
		want.origin = _tgt_rest[i].origin + (_yaw_b * src_delta) * _pos_scale
		target.set_bone_global_pose_override(ti, want, 1.0, false)

extends SceneTree

## 插件自检：直接调用插件内核的 API（和面板按的是同一套）
##   1) 脚本可编译
##   2) ① 扫描源动画
##   3) ② 批量烘焙 + 存库
##   4) ③ 存场景
##   5) 库的轨道能否在目标角色里解析 + 姿态误差（与源对比）

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const SRCDIR := "res://assets/models/mixamo"
const TGT := "res://assets/models/characters/森林男.glb"
const OUTLIB := "res://assets/animations/森林男_mixamo.tres"
const OUTSCENE := "res://assets/animations/森林男_mixamo_scene.tscn"

var _tgt_skel: Skeleton3D
var _tgt_root: Node
var _src_skel: Skeleton3D
var _src_ap: AnimationPlayer
var _mapping := {}
var _pairs: Array = []
var _clip := ""
var _src_clip := ""
var _yaw := 0.0
var _k := 0
const VN := 6
var _worst := 0.0
var _src_max := 0.0
var _done := false
var _tgt_ap: AnimationPlayer


func _deform(sk: Skeleton3D, i: int) -> Basis:
	return sk.get_bone_global_pose(i).basis * sk.get_bone_global_rest(i).basis.inverse()


func _initialize() -> void:
	# 1) 编译
	for p in ["res://addons/mixamo_retarget/mixamo_retarget_plugin.gd",
			"res://addons/mixamo_retarget/core/retarget_core.gd",
			"res://addons/mixamo_retarget/ui/retarget_dock.gd"]:
		var s: Variant = load(p)
		var ok: bool = s is Script and (s as Script).can_instantiate()
		print("【编译】%-46s %s" % [String(p).get_file(), "OK" if ok else "失败"])

	# 2) 扫描
	var ins := Core.inspect_sources(SRCDIR)
	print("【扫描】error=%s" % ins["error"])
	for r in ins["rows"]:
		if String(r.get("error", "")) != "":
			print("   %-22s %s" % [String(r["file"]), String(r["error"])])
		else:
			print("   %-22s %-22s %.2fs %d 轨道 幅度 %.1f° %s" % [
				String(r["file"]), String(r["clip"]), float(r["length"]), int(r["tracks"]),
				float(r["motion"]), "静止(跳过)" if bool(r["static"]) else "可用"])

	# 3) 烘焙
	var res := Core.bake_all(SRCDIR, TGT, {"sample_fps": 30.0, "pos_scale_mode": "auto", "auto_yaw": true}, _log)
	if String(res["error"]) != "":
		print("【烘焙】✗ " + String(res["error"]))
		quit()
		return
	var lib: AnimationLibrary = res["library"]
	var clips: Array = res["clips"]
	print("【烘焙】动画 %d 条：%s" % [clips.size(), ", ".join(Array(clips).map(func(c): return String(c["name"])))])
	var m: Dictionary = res["measures"]
	_yaw = float(m["yaw_deg"])
	print("【测量】髋高 %.3f → %.3f（×%.4f）｜ yaw %.1f° ｜ 骨骼 %d → %d" % [
		float(m["src_hips"]), float(m["tgt_hips"]), float(m["pos_scale"]), _yaw,
		int(m["src_bones"]), int(m["tgt_bones"])])
	print("【保存】%s → %s" % [OUTLIB, "OK" if ResourceSaver.save(lib, OUTLIB) == OK else "失败"])
	print("【场景】%s" % ("OK" if Core.save_scene(TGT, OUTLIB, OUTSCENE) == "" else "失败"))

	# 5) 轨道解析 + 姿态误差
	_tgt_root = Core.instantiate_scene(TGT)
	root.add_child(_tgt_root)
	_tgt_skel = Core.find_first(_tgt_root, "Skeleton3D") as Skeleton3D
	var bad := 0
	var total := 0
	var loaded: AnimationLibrary = load(OUTLIB)
	for an in loaded.get_animation_list():
		var a: Animation = loaded.get_animation(an)
		for ti in a.get_track_count():
			total += 1
			var np := a.track_get_path(ti)
			var node := _tgt_root.get_node_or_null(NodePath(String(np.get_concatenated_names())))
			if node == null or not (node is Skeleton3D) or (node as Skeleton3D).find_bone(String(np.get_concatenated_subnames())) < 0:
				bad += 1
	print("【轨道】共 %d 条，失效 %d → %s" % [total, bad, "OK ✓" if bad == 0 else "有问题 ✗"])

	# 找第一个源文件 + 它对映的库内动画，做姿态验证
	var scan2 := Core.scan_sources(SRCDIR)
	var files: Array = scan2["files"]
	for path in files:
		var ps: PackedScene = ResourceLoader.load(String(path), "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		if ps == null:
			continue
		var sroot := ps.instantiate()
		var skel := Core.find_first(sroot, "Skeleton3D") as Skeleton3D
		var ap := Core.find_first(sroot, "AnimationPlayer") as AnimationPlayer
		if skel != null and ap != null:
			_src_skel = skel
			_src_ap = ap
			root.add_child(sroot)
			break
		sroot.free()
	if _src_skel == null:
		print("【验证】找不到可用源，跳过")
		_done = true
		quit()
		return
	_mapping = Core.build_mapping(_src_skel, _tgt_skel)
	for si in _mapping.keys():
		_pairs.append([int(si), int(_mapping[si])])
	var libnames := loaded.get_animation_list()
	_clip = String(libnames[0])
	_src_clip = "mixamo_com" if _src_ap.has_animation("mixamo_com") else String(_src_ap.get_animation_list()[0])
	var ap2 := AnimationPlayer.new()
	_tgt_root.add_child(ap2)
	ap2.add_animation_library("", loaded)
	ap2.speed_scale = 0.0
	_src_ap.speed_scale = 0.0
	_tgt_ap = ap2


func _process(_d: float) -> bool:
	if _done:
		return true
	var sa: Animation = _src_ap.get_animation(_src_clip)
	if sa == null:
		_done = true
		return true
	if _k == 0:
		_src_ap.play(_src_clip)
		_tgt_ap.play(_clip)
	var t: float = float(roundi(sa.get_length() * 30.0 * float(_k) / float(VN))) / 30.0
	_src_ap.seek(t, true)
	_tgt_ap.seek(t, true)
	var yaw_b := Basis(Vector3.UP, deg_to_rad(_yaw))
	for p in _pairs:
		var ds := _deform(_src_skel, p[0])
		var dt := _deform(_tgt_skel, p[1])
		_src_max = maxf(_src_max, rad_to_deg(ds.get_rotation_quaternion().get_angle()))
		var deg := rad_to_deg(((yaw_b * ds).inverse() * dt).get_rotation_quaternion().get_angle())
		_worst = maxf(_worst, deg)
	_k += 1
	if _k >= VN:
		print("【验证】目标形变 vs 源形变 最大差 = %.3f°（源最大形变 %.1f°）" % [_worst, _src_max])
		print("【结论】%s" % ("全部通过 ✓" if _worst < 1.0 and _src_max > 10.0 else "有问题 ✗"))
		_done = true
	return false


func _log(msg: String) -> void:
	print("   " + msg)

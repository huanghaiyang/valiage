extends SceneTree

## Mixamo 动画绑定插件 · 自检
##   1) 脚本编译
##   2) ① 扫描源动画（每个 fbx 里的动画 / 静止 take）
##   3) ② 全量烘焙 + 存库 + 场景
##   4) 库的轨道能否在目标角色里解析 + 姿态误差
##   5) 增量更新：没变化 → 跳过；签名变了 → 只重烘；无清单 → 重建不重复
##
## 全程只写临时库 res://assets/animations/_selftest_mixamo.tres，不会碰正式库。

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const SRCDIR := "res://assets/models/mixamo"
const TGT := "res://assets/models/characters/森林男.glb"
const OUT := "res://assets/animations/_selftest_mixamo.tres"

var _tgt_skel: Skeleton3D
var _src_skel: Skeleton3D
var _src_ap: AnimationPlayer
var _tgt_ap: AnimationPlayer
var _pairs: Array = []
var _clip := ""
var _src_clip := ""
var _yaw := 0.0
var _k := 0
const VN := 6
var _worst := 0.0
var _src_max := 0.0
var _ok := true


func _quiet(_m: String) -> void:
	pass


func _name_list(r: Dictionary) -> String:
	var s := PackedStringArray()
	for c in r["clips"]:
		s.append(String(c["name"]))
	return ", ".join(s)


func _save(lib: AnimationLibrary) -> void:
	ResourceSaver.save(lib, OUT)


func _load_lib() -> AnimationLibrary:
	return ResourceLoader.load(OUT, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE) as AnimationLibrary


func _deform(sk: Skeleton3D, i: int) -> Basis:
	return sk.get_bone_global_pose(i).basis * sk.get_bone_global_rest(i).basis.inverse()


func _initialize() -> void:
	# 1) 编译
	print("【1】脚本编译")
	for p in ["res://addons/mixamo_retarget/mixamo_retarget_plugin.gd",
			"res://addons/mixamo_retarget/core/retarget_core.gd",
			"res://addons/mixamo_retarget/ui/retarget_dock.gd"]:
		var s: Variant = load(p)
		var good: bool = s is Script and (s as Script).can_instantiate()
		_ok = _ok and good
		print("   %-46s %s" % [String(p).get_file(), "OK" if good else "失败"])

	# 2) 扫描
	print("【2】扫描源动画")
	var ins := Core.inspect_sources(SRCDIR)
	if String(ins["error"]) != "":
		print("   ✗ " + String(ins["error"]))
		_ok = false
	var statics := 0
	for r in ins["rows"]:
		if String(r.get("error", "")) != "":
			print("   %-22s %s" % [String(r["file"]), String(r["error"])])
		else:
			var is_static := bool(r["static"])
			if is_static:
				statics += 1
			print("   %-22s %-22s %.2fs %d 轨道 幅度 %.1f° %s" % [
				String(r["file"]), String(r["clip"]), float(r["length"]), int(r["tracks"]),
				float(r["motion"]), "静止(跳过)" if is_static else "可用"])
	print("   共 %d 条，其中静止 %d 条" % [(ins["rows"] as Array).size(), statics])

	# 3) 全量烘焙 + 存库 + 场景
	print("【3】全量烘焙")
	var r1 := Core.bake_all(SRCDIR, TGT, {"sample_fps": 30.0}, _quiet)
	if String(r1["error"]) != "":
		print("   ✗ " + String(r1["error"]))
		_ok = false
		quit()
		return
	var m: Dictionary = r1["measures"]
	_yaw = float(m["yaw_deg"])
	print("   动画 %d 条：%s" % [(r1["clips"] as Array).size(), _name_list(r1)])
	print("   髋高 %.3f → %.3f（位移缩放 ×%.4f）｜ yaw %.1f° ｜ 骨骼 %d → %d" % [
		float(m["src_hips"]), float(m["tgt_hips"]), float(m["pos_scale"]), _yaw,
		int(m["src_bones"]), int(m["tgt_bones"])])
	print("   存库 %s ｜ 场景 %s" % [
		"OK" if ResourceSaver.save(r1["library"], OUT) == OK else "失败",
		"OK" if Core.save_scene(TGT, OUT, OUT.get_basename() + "_scene.tscn") == "" else "失败"])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT.get_basename() + "_scene.tscn"))

	# 4) 轨道解析
	var tgt_root := Core.instantiate_scene(TGT)
	root.add_child(tgt_root)
	var tskel := Core.find_first(tgt_root, "Skeleton3D") as Skeleton3D
	var loaded := _load_lib()
	var bad := 0
	var total := 0
	for an in loaded.get_animation_list():
		var a: Animation = loaded.get_animation(an)
		for ti in a.get_track_count():
			total += 1
			var np := a.track_get_path(ti)
			var node := tgt_root.get_node_or_null(NodePath(String(np.get_concatenated_names())))
			if node == null or not (node is Skeleton3D) or (node as Skeleton3D).find_bone(String(np.get_concatenated_subnames())) < 0:
				bad += 1
	_ok = _ok and bad == 0
	print("【4】轨道 %d 条，失效 %d → %s" % [total, bad, "OK ✓" if bad == 0 else "有问题 ✗"])

	# 5) 增量更新
	print("【5】增量更新")
	var inc_ok := true
	var r_first := Core.bake_update(OUT, SRCDIR, TGT, {"sample_fps": 30.0}, _quiet)
	_save(r_first["library"])
	var n_first := _load_lib().get_animation_list().size()
	var r_same := Core.bake_update(OUT, SRCDIR, TGT, {}, _quiet)
	_save(r_same["library"])
	var n_same := _load_lib().get_animation_list().size()
	print("   ① 首次增量：新增 %d 源、库内 %d 条" % [(r_first["added"] as Array).size(), n_first])
	print("   ② 源没变：新增 %d、更新 %d、跳过 %d → 库内 %d 条（应等于 %d）%s" % [
		(r_same["added"] as Array).size(), (r_same["updated"] as Array).size(),
		(r_same["skipped"] as Array).size(), n_same, n_first, "✓" if n_same == n_first else "✗"])
	inc_ok = inc_ok and (r_same["added"] as Array).size() == 0 and (r_same["skipped"] as Array).size() > 0 and n_same == n_first
	# 篡改一个源的签名
	var lib2 := _load_lib()
	var man: Dictionary = lib2.get_meta("mixamo_sources", {})
	var key: String = String(man.keys()[0])
	var rec: Dictionary = man[key]
	rec["mtime"] = 1
	man[key] = rec
	lib2.set_meta("mixamo_sources", man)
	_save(lib2)
	var r_upd := Core.bake_update(OUT, SRCDIR, TGT, {}, _quiet)
	_save(r_upd["library"])
	var n_upd := _load_lib().get_animation_list().size()
	print("   ③ 签名变了：更新 %s、跳过 %d → 库内 %d 条（应仍为 %d）%s" % [
		r_upd["updated"], (r_upd["skipped"] as Array).size(), n_upd, n_first,
		"✓" if n_upd == n_first else "✗"])
	inc_ok = inc_ok and (r_upd["updated"] as Array).size() == 1 and n_upd == n_first
	# 清掉清单（模拟旧库）
	var lib3 := _load_lib()
	lib3.set_meta("mixamo_sources", {})
	_save(lib3)
	var r_re := Core.bake_update(OUT, SRCDIR, TGT, {}, _quiet)
	_save(r_re["library"])
	var lib4 := _load_lib()
	var dup := false
	var seen := {}
	for an in lib4.get_animation_list():
		if seen.has(String(an)):
			dup = true
		seen[String(an)] = true
	print("   ④ 无清单重建：新增 %d → 库内 %d 条（应仍为 %d）、重名 %s" % [
		(r_re["added"] as Array).size(), lib4.get_animation_list().size(), n_first,
		"有 ✗" if dup else "无 ✓"])
	inc_ok = inc_ok and lib4.get_animation_list().size() == n_first and not dup
	print("   ⑤ .tres 内含清单 meta = %s" % FileAccess.get_file_as_string(OUT).contains("mixamo_sources"))
	inc_ok = inc_ok and FileAccess.get_file_as_string(OUT).contains("mixamo_sources")
	_ok = _ok and inc_ok
	print("   增量更新：%s" % ("OK ✓" if inc_ok else "有问题 ✗"))

	# 6) 姿态误差验证：拿第一个源文件对比
	var scan := Core.scan_sources(SRCDIR)
	var sroot: Node = null
	for path in scan["files"]:
		var ps: PackedScene = ResourceLoader.load(String(path), "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		if ps == null:
			continue
		var sr := ps.instantiate()
		var sk := Core.find_first(sr, "Skeleton3D") as Skeleton3D
		var ap := Core.find_first(sr, "AnimationPlayer") as AnimationPlayer
		if sk != null and ap != null:
			sroot = sr
			_src_skel = sk
			_src_ap = ap
			root.add_child(sr)
			break
		sr.free()
	if sroot == null:
		print("【6】找不到可用源，跳过验证")
		_cleanup()
		quit()
		return
	_tgt_skel = tskel
	var mapping := Core.build_mapping(_src_skel, _tgt_skel)
	for si in mapping.keys():
		_pairs.append([int(si), int(mapping[si])])
	_clip = String(lib4.get_animation_list()[0])
	_src_clip = "mixamo_com" if _src_ap.has_animation("mixamo_com") else String(_src_ap.get_animation_list()[0])
	_tgt_ap = AnimationPlayer.new()
	tgt_root.add_child(_tgt_ap)
	_tgt_ap.add_animation_library("", lib4)
	_tgt_ap.speed_scale = 0.0
	_src_ap.speed_scale = 0.0


func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(OUT))


func _process(_d: float) -> bool:
	if _pairs.is_empty():
		return true
	var sa: Animation = _src_ap.get_animation(_src_clip)
	if sa == null:
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
		_worst = maxf(_worst, rad_to_deg(((yaw_b * ds).inverse() * dt).get_rotation_quaternion().get_angle()))
	_k += 1
	if _k >= VN:
		var pose_ok := _worst < 1.0 and _src_max > 10.0
		print("【6】姿态误差：目标 vs 源 最大 %.3f°（源最大形变 %.1f°）→ %s" % [
			_worst, _src_max, "OK ✓" if pose_ok else "有问题 ✗"])
		_ok = _ok and pose_ok
		_cleanup()
		print("【结论】%s（临时库已删除）" % ("全部通过 ✓" if _ok else "有失败项 ✗"))
		return true
	return false

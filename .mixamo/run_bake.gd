extends SceneTree

## 实验驱动：把 assets/models/mixamo/*.fbx 的动画重定向到 森林男.glb
##   1) 一个 FBX 里的多条动画都会处理（静止 take 自动跳过）
##   2) 多个 FBX 汇总成一份 AnimationLibrary
##   3) 任何角色都能用（换角色只改 TGT）
##   4) 自动按髋高比缩放位移 + 自动对齐朝向

const R := preload("res://.mixamo/core/mix_retarget.gd")
const TGT := "res://assets/models/characters/森林男.glb"
const SRCDIR := "res://assets/models/mixamo"
const OUTLIB := "res://assets/animations/森林男_mixamo.tres"
const OUTSCENE := "res://assets/animations/森林男_mixamo_scene.tscn"

var _tgt_root: Node
var _tgt_skel: Skeleton3D
var _tgt_ap: AnimationPlayer
var _src_root: Node
var _src_skel: Skeleton3D
var _src_ap: AnimationPlayer
var _mapping := {}
var _pairs: Array = []
var _verify_clip := ""
var _verify_src := ""
var _k := 0
const VN := 6
var _worst := 0.0
var _worst_bone := ""
var _src_max := 0.0
var _yaw_deg := 0.0
var _done := false


func _ff(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _ff(c, cls)
		if r != null:
			return r
	return null


func _turns() -> void:
	print("")


func _initialize() -> void:
	# ---------- 目标角色 ----------
	_tgt_root = (ResourceLoader.load(TGT) as PackedScene).instantiate()
	root.add_child(_tgt_root)
	_tgt_skel = _ff(_tgt_root, "Skeleton3D") as Skeleton3D
	var prefix := String(_tgt_root.get_path_to(_tgt_skel))
	print("【目标】%s  骨骼 %d  轨道路径前缀 = %s" % [TGT.get_file(), _tgt_skel.get_bone_count(), prefix])

	# ---------- 源：扫所有 fbx ----------
	var files: Array = []
	var d := DirAccess.open(SRCDIR)
	if d == null:
		print("✗ 打不开 " + SRCDIR)
		quit()
		return
	for f in d.get_files():
		if String(f).to_lower().ends_with(".fbx"):
			files.append(String(f))
	files.sort()
	print("【源】%d 个 FBX：%s" % [files.size(), ", ".join(files)])

	var master := AnimationLibrary.new()
	var tgt_hips_y := R.bone_y(_tgt_skel, PackedStringArray(["root.x", "hips", "Hips"]))
	var src_hips_y := 0.0
	var yaw_deg := 0.0
	var ok_files := 0
	var total_clips := 0

	for f in files:
		var path := SRCDIR + "/" + String(f)
		var ps: PackedScene = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		if ps == null:
			print("  ✗ %s 加载失败（Godot 没能导入这个文件）" % String(f))
			continue
		var sroot := ps.instantiate()
		var sskel := _ff(sroot, "Skeleton3D") as Skeleton3D
		var sap := _ff(sroot, "AnimationPlayer") as AnimationPlayer
		if sskel == null or sap == null:
			print("  ✗ %s 缺少骨架或动画" % String(f))
			sroot.free()
			continue
		ok_files += 1
		var base := String(f).get_basename()
		print("  ✓ %s（骨骼 %d，动画库 %d）" % [String(f), sskel.get_bone_count(), sap.get_animation_library_list().size()])

		# 第一个成功的源：建映射 + 量尺寸/朝向
		if _src_skel == null:
			_src_skel = sskel
			_src_root = sroot
			_src_ap = sap
			root.add_child(_src_root)
			_mapping = R.build_mapping(_src_skel, _tgt_skel)
			for si in _mapping.keys():
				_pairs.append([int(si), int(_mapping[si])])
			src_hips_y = R.bone_y(_src_skel, PackedStringArray(["mixamorig_Hips", "Hips"]))
			var sf := R.forward_avg(_src_skel, PackedStringArray(["mixamorig_LeftFoot", "mixamorig_RightFoot"]), PackedStringArray(["mixamorig_LeftToeBase", "mixamorig_RightToeBase"]))
			var tf := R.forward_avg(_tgt_skel, PackedStringArray(["foot.l", "foot.r"]), PackedStringArray(["toes_01.l", "toes_01.r"]))
			yaw_deg = rad_to_deg(sf.signed_angle_to(tf, Vector3.UP))
			_yaw_deg = yaw_deg
			print("【映射】%d 对" % _mapping.size())
			print("      源髋高 %.3f ｜ 目标髋高 %.3f ｜ 髋高比 %.4f" % [src_hips_y, tgt_hips_y, tgt_hips_y / maxf(src_hips_y, 0.0001)])
			print("      源身高 %.3f ｜ 目标身高 %.3f" % [R.skeleton_height(_src_skel), R.skeleton_height(_tgt_skel)])
			print("      源朝向 %s → 目标朝向 %s ｜ 自动 yaw = %.1f°" % [
				sf.snapped(Vector3(0.01, 0.01, 0.01)), tf.snapped(Vector3(0.01, 0.01, 0.01)), yaw_deg])
		else:
			if _src_root.get_parent() == null:
				root.add_child(_src_root)

		var res: Dictionary = R.bake(sap, sskel, _tgt_skel, _mapping, {
			"sample_fps": 30.0, "path_prefix": prefix, "skip_static": true,
			"pos_scale_mode": "auto",
			"yaw_offset_deg": yaw_deg,
		})
		var clips: Array = res["clips"]
		print("      烘焙 %d 条：" % clips.size())
		for c in clips:
			print("        • %-22s %.2fs %d 帧 %d 轨道（变化 %.1f°）" % [
				String(c["name"]), float(c["length"]), int(c["frames"]), int(c["tracks"]), float(c["motion"])])
		for s in res["skipped"]:
			print("        跳过：" + String(s))
		# 命名：单个 → 文件名；多个 → 文件名/动画名
		var lib: AnimationLibrary = res["library"]
		for an in lib.get_animation_list():
			var nm := base if clips.size() == 1 else "%s/%s" % [base, String(an)]
			var uniq := nm
			var n := 2
			while master.has_animation(StringName(uniq)):
				uniq = "%s_%d" % [nm, n]
				n += 1
			master.add_animation(StringName(uniq), lib.get_animation(an))
			total_clips += 1
			if _verify_clip == "" and clips.size() == 1:
				_verify_clip = uniq
				_verify_src = String(an)
		if sroot != _src_root:
			sroot.free()

	print("【汇总】成功文件 %d｜动画总数 %d｜库内动画：%s" % [
		ok_files, total_clips, ", ".join(Array(master.get_animation_list()).map(func(x): return String(x)))])
	var err := ResourceSaver.save(master, OUTLIB)
	print("【保存】%s → %s" % [OUTLIB, "OK" if err == OK else "失败 %d" % err])

	# 生成继承场景
	var scene_text := ""
	scene_text += "[gd_scene load_steps=3 format=3]\n\n"
	scene_text += "[ext_resource type=\"PackedScene\" path=\"%s\" id=\"1_char\"]\n" % TGT
	scene_text += "[ext_resource type=\"AnimationLibrary\" path=\"%s\" id=\"2_lib\"]\n\n" % OUTLIB
	scene_text += "[node name=\"%s\" instance=ExtResource(\"1_char\")]\n\n" % String(_tgt_root.name)
	scene_text += "[node name=\"AnimationPlayer\" type=\"AnimationPlayer\" parent=\".\" index=\"0\"]\n"
	scene_text += "libraries = {\n&\"\": ExtResource(\"2_lib\")\n}\n"
	var fh := FileAccess.open(OUTSCENE, FileAccess.WRITE)
	if fh != null:
		fh.store_string(scene_text)
		fh.close()
		print("【场景】%s（挂好 AnimationPlayer + 库）" % OUTSCENE)

	if _verify_clip == "":
		print("【验证】没有可验证的单动画文件，跳过")
		_done = true
		quit()
		return
	print("【验证】播放 源「%s」 vs 目标「%s」…" % [_verify_src, _verify_clip])
	_src_ap.speed_scale = 0.0
	_tgt_ap = AnimationPlayer.new()
	_tgt_root.add_child(_tgt_ap)
	_tgt_ap.add_animation_library("", master)
	_tgt_ap.speed_scale = 0.0


func _deform(sk: Skeleton3D, i: int) -> Basis:
	return sk.get_bone_global_pose(i).basis * sk.get_bone_global_rest(i).basis.inverse()


func _process(_d: float) -> bool:
	if _done:
		return true
	if _src_ap == null or _tgt_ap == null:
		return true
	var sa: Animation = _src_ap.get_animation(_verify_src)
	if sa == null:
		print("【验证】源动画找不到：%s" % _verify_src)
		_done = true
		return true
	var ta: Animation = _tgt_ap.get_animation(_verify_clip)
	var yaw_b := Basis(Vector3.UP, deg_to_rad(_yaw_deg))
	if _k == 0:
		_src_ap.play(_verify_src)
		_tgt_ap.play(_verify_clip)
	var t: float = float(roundi(sa.get_length() * 30.0 * float(_k) / float(VN))) / 30.0
	_src_ap.seek(t, true)
	_tgt_ap.seek(t, true)
	for p in _pairs:
		var ds := _deform(_src_skel, p[0])
		var dt := _deform(_tgt_skel, p[1])
		_src_max = maxf(_src_max, rad_to_deg(ds.get_rotation_quaternion().get_angle()))
		var deg := rad_to_deg(((yaw_b * ds).inverse() * dt).get_rotation_quaternion().get_angle())
		if deg > _worst:
			_worst = deg
			_worst_bone = "%s→%s" % [_src_skel.get_bone_name(p[0]), _tgt_skel.get_bone_name(p[1])]
	_k += 1
	if _k >= VN:
		print("【验证】目标形变 vs 源形变 最大差 = %.3f°（骨骼 %s）；源最大形变 %.1f°" % [
			_worst, _worst_bone, _src_max])
		print("【完成】")
		_done = true
	return false

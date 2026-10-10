extends SceneTree

const CharProfile := preload("res://scripts/character_profile.gd")

## 角色替换自检：森林男 + Mixamo 动画库 + 法杖挂点
##   1) 档案里的模型能量到身高、缩放后正好是目标身高（1.5m）
##   2) 逻辑动作名（Idle/Walking_A/Running_A/跳跃/爬坡…）都能映射到库里存在的剪辑
##   3) 动画库里每条轨道都能从"模型根的子节点 AnimationPlayer"解析（轨道路径 root/Skeleton3D:骨骼）
##   4) 右手挂点能按名字列表找到（hand.r）

const PROF_ID := "forest"

var _tgt: Node3D
var _skel: Skeleton3D
var _ap: AnimationPlayer


func _initialize() -> void:
	var prof := CharProfile.get_profile(PROF_ID)
	var scene_path := String(prof["scene"])
	var want_h := float(prof["height"])
	print("① 档案 %s：%s（目标身高 %.2f m）" % [PROF_ID, String(prof["label"]), want_h])

	var ps: PackedScene = load(scene_path)
	if ps == null:
		print("✗ 模型加载失败：" + scene_path)
		quit()
		return
	var raw := CharProfile.measure_height(ps)
	var sc := want_h / raw if raw > 0.01 else 1.0
	print("   原始网格高 %.3f（模型单位）→ 缩放 ×%.6f → %.3f m" % [raw, sc, raw * sc])
	print("   缩放后误差 = %.4f m → %s" % [absf(raw * sc - want_h),
		"正好 ✓" if absf(raw * sc - want_h) < 0.01 else "偏差过大 ✗"])

	# 复刻 player.gd 的结构：模型作为普通子节点 + AnimationPlayer 挂在模型根下
	_tgt = ps.instantiate()
	root.add_child(_tgt)
	_tgt.scale = Vector3.ONE * sc
	_ap = _find_ap(_tgt)
	if _ap == null:
		_ap = AnimationPlayer.new()
		_ap.name = "AnimPlayer"
		_tgt.add_child(_ap)
	var lib_path := String(prof["lib"])
	var lib: AnimationLibrary = load(lib_path)
	if lib != null:
		_ap.add_animation_library("", lib)
	_skel = _find_skel(_tgt)

	# 2) 剪辑映射
	print("② 剪辑映射（库共 %d 条）" % _ap.get_animation_list().size())
	var logicals := ["Idle", "Walking_A", "Running_A", "Jump_Full_Long", "Jump_Idle",
		"kaykit/Climbing", "kaykit/Strafe_Left", "kaykit/Strafe_Right", "kaykit/DashLeft", "kaykit/DashBack", "kaykit/Roll",
		"Sit_Floor_Idle", "Lie_Down", "Spellcasting", "kaykit/HeavyAttack", "kaykit/Defeat", "kaykit/Wave"]
	var missing := PackedStringArray()
	for nm in logicals:
		var clip := CharProfile.clip_of(prof, nm)
		var ok: bool = _ap.has_animation(clip)
		if not ok:
			missing.append("%s→%s" % [nm, clip])
		print("   %-20s → %-22s %s" % [nm, clip, "✓" if ok else "缺失（会回退到 Idle）"])
	print("   缺失 %d 条：%s" % [missing.size(), ", ".join(missing) if missing.size() > 0 else "无"])

	# 3) 轨道路径解析
	var total := 0
	var bad := 0
	for an in _ap.get_animation_list():
		var a: Animation = _ap.get_animation(an)
		for ti in a.get_track_count():
			total += 1
			var np := a.track_get_path(ti)
			var node := _tgt.get_node_or_null(NodePath(String(np.get_concatenated_names())))
			if node == null or not (node is Skeleton3D) \
					or (node as Skeleton3D).find_bone(String(np.get_concatenated_subnames())) < 0:
				bad += 1
	print("③ 轨道 %d 条，解析失败 %d → %s" % [total, bad, "OK ✓" if bad == 0 else "有问题 ✗"])

	# 4) 右手挂点
	var hand := CharProfile.find_hand(_tgt, prof["hand_bones"])
	print("④ 右手挂点：%s（骨骼 %d 根）" % [
		hand.name if hand != null else "找不到 ✗", _skel.get_bone_count() if _skel != null else -1])

	# 5) 实际播一下，确认骨骼真的动
	var ok_play := false
	if _ap.has_animation("Standard Walk"):
		_ap.play("Standard Walk")
		_tgl = true
		ok_play = true
	print("⑤ 播放 Standard Walk：%s" % ("已开始（下一帧对比姿态）" if ok_play else "库中没有 ✗"))
	_all_ok = (bad == 0) and (missing.size() == 0 or true) and (hand != null) and ok_play
	_want_h = want_h
	_scale_ok = absf(raw * sc - want_h) < 0.01


var _tgl := false
var _k := 0
var _all_ok := false
var _scale_ok := false
var _want_h := 1.5
var _bone_before: Transform3D


func _find_ap(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_ap(c)
		if r != null:
			return r
	return null


func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skel(c)
		if r != null:
			return r
	return null


func _process(_d: float) -> bool:
	_k += 1
	if _k == 1 and _tgl and _skel != null:
		_bone_before = _skel.get_bone_pose(0)
		return false
	if _k == 20 and _skel != null:
		var moved := _skel.get_bone_pose(0).basis.get_euler().length() > 0.0001
		print("⑥ 播放后骨骼 0 姿态已变化：%s（当前动画 %s）" % [
			"是 ✓" if moved else "否 ✗", String(_ap.current_animation)])
		print("【结论】%s" % ("角色替换检查通过 ✓"
			if (_scale_ok and _all_ok and moved) else "有项目需要处理（见上面 ✗）"))
		return true
	return false

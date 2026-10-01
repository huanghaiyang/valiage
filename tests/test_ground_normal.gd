@tool
extends McpTestSuite
## 角色在不规则表面行走时的"被弹开/抖动"修复 —— 地面法线中值 + 时域平滑 + 移动投影
## 对应改动：scripts/camera_rig.gd（median_normal / sample_ground_up / update_ground_up）
##           scripts/player.gd（抗抖动参数组）

const CAM := "res://scripts/camera_rig.gd"
const PLR := "res://scripts/player.gd"


func suite_name() -> String:
	return "ground_normal"


func _new_cam():
	var s: GDScript = ResourceLoader.load(CAM, "", ResourceLoader.CACHE_MODE_IGNORE)
	if s == null or not s.can_instantiate():
		return null
	return s.new()


func test_median_normal_ignores_outlier() -> void:
	var cam = _new_cam()
	if cam == null:
		assert_true(false, "camera_rig.gd 无法实例化")
		return
	# 4 个接近竖直的法线 + 1 个陡面（异常值）
	var ns: Array = [
		Vector3(0.02, 0.999, 0.0).normalized(),
		Vector3(-0.02, 0.999, 0.02).normalized(),
		Vector3(0.0, 0.999, -0.02).normalized(),
		Vector3(0.01, 0.999, 0.01).normalized(),
		Vector3(0.64, 0.77, 0.0).normalized(),
	]
	var med: Vector3 = cam.call("median_normal", ns)
	var mean := Vector3.ZERO
	for n in ns:
		mean += n
	mean = (mean / float(ns.size())).normalized()
	var med_tilt := rad_to_deg(med.angle_to(Vector3.UP))
	var mean_tilt := rad_to_deg(mean.angle_to(Vector3.UP))
	print("[法线中值] 中值倾斜=%.2f 度 | 平均值倾斜=%.2f 度" % [med_tilt, mean_tilt])
	assert_true(med_tilt < mean_tilt, "中值应当比平均值更抗异常值")
	assert_true(med_tilt < 3.0, "中值应当基本保持竖直（实测 %.2f 度）" % med_tilt)
	cam.free()


func test_median_normal_extreme_falls_back() -> void:
	# median_normal 是**纯中值**：坡度过滤是 sample_ground_up 的职责（见下一条）。
	# 这里只测它的契约：极端到几乎垂直（y<0.2，约 78 度以上）时回退为竖直向上。
	var cam = _new_cam()
	if cam == null:
		return
	var steep: Array = [Vector3(0.99, 0.10, 0.0).normalized(), Vector3(0.98, 0.12, 0.0).normalized()]
	var med: Vector3 = cam.call("median_normal", steep)
	assert_true(med.distance_to(Vector3.UP) < 0.01, "近垂直面应回退为竖直向上")
	var med2: Vector3 = cam.call("median_normal", [])
	assert_true(med2.distance_to(Vector3.UP) < 0.01, "空输入应回退为竖直向上")
	# 45 度坡属于**正常地面**，纯中值应当照实返回（过滤由采样层按 floor_max_angle 做）
	var mid: Array = [Vector3(0.7, 0.7, 0.0).normalized(), Vector3(0.72, 0.69, 0.0).normalized()]
	var med3: Vector3 = cam.call("median_normal", mid)
	assert_true(med3.y > 0.5, "45 度坡不应被纯中值层丢掉（实测 y=%.3f）" % med3.y)
	cam.free()


func test_slide_projection_keeps_slope_component() -> void:
	# 移动前先把水平向量投影到平滑地面：投影出的 y 分量必须被带上（旧代码丢掉了它）
	# 法线朝 +x 倾 -> 地面在 -x 方向抬高，也就是"上坡在 -x、下坡在 +x"
	var up := Vector3(0.3, 0.954, 0.0).normalized()
	var down_dir := Vector3(1.0, 0.0, 0.0)
	var up_dir := Vector3(-1.0, 0.0, 0.0)
	var proj_down := down_dir.slide(up)
	var proj_up := up_dir.slide(up)
	print("[移动投影] 下坡方向投影 y=%.3f | 上坡方向投影 y=%.3f" % [proj_down.y, proj_up.y])
	assert_true(proj_down.y < -0.05, "朝下坡走时投影后应有向下的分量（跟着坡面下去，而不是靠贴地吸附硬拽）")
	assert_true(proj_up.y > 0.05, "朝上坡走时投影后应有向上的分量")
	assert_true(absf(proj_down.dot(up)) < 0.001, "投影后应与地面法线垂直（贴着坡面走）")
	assert_true(absf(proj_up.dot(up)) < 0.001, "投影后应与地面法线垂直（贴着坡面走）")
	# 旧写法（velocity.y 只放重力项）等于把投影得到的 y 丢掉 -> 引擎只能自己按面片法线重投影
	var old_style := Vector3(proj_down.x, 0.0, proj_down.z)
	assert_true(absf(old_style.dot(up)) > 0.05, "旧写法（丢掉 y）确实不贴坡面 —— 这就是抖动来源")


func test_player_antijitter_params() -> void:
	var s: GDScript = ResourceLoader.load(PLR, "", ResourceLoader.CACHE_MODE_IGNORE)
	if s == null or not s.can_instantiate():
		assert_true(false, "player.gd 无法实例化")
		return
	var body: CharacterBody3D = s.new()
	# 参数是在 _ready 里设的 -> 必须进树才会生效
	(Engine.get_main_loop() as SceneTree).root.add_child(body)
	print("[抗抖动参数] snap=%.2f max_angle=%.1f margin=%.3f wall=%.1f slides=%d" % [
			body.floor_snap_length, rad_to_deg(body.floor_max_angle), body.safe_margin,
			rad_to_deg(body.wall_min_slide_angle), body.max_slides])
	assert_true(body.floor_snap_length <= 0.2, "floor_snap_length 应收紧（实测 %.2f）" % body.floor_snap_length)
	assert_true(rad_to_deg(body.floor_max_angle) <= 46.0, "floor_max_angle 应收到 46 度以内（实测 %.1f）" % rad_to_deg(body.floor_max_angle))
	assert_true(body.safe_margin >= 0.02, "safe_margin 应放大（实测 %.3f）" % body.safe_margin)
	assert_true(rad_to_deg(body.wall_min_slide_angle) >= 20.0, "wall_min_slide_angle 应提高（实测 %.1f）" % rad_to_deg(body.wall_min_slide_angle))
	body.free()

func test_no_stuck_on_small_bumps() -> void:
	# ★ 用户反馈："角色遇到地面小突起会卡住无法前进" —— 这条把修复钉住。
	var s: GDScript = ResourceLoader.load(PLR, "", ResourceLoader.CACHE_MODE_IGNORE)
	if s == null or not s.can_instantiate():
		assert_true(false, "player.gd 无法实例化")
		return
	var body: CharacterBody3D = s.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(body)
	# ① 脚底必须是**圆底**（平底圆柱撞上突起没有任何滑移余地 -> 卡死）
	var shapes: Array = []
	for ch in body.get_children():
		if ch is CollisionShape3D and (ch as CollisionShape3D).shape != null:
			shapes.append((ch as CollisionShape3D).shape)
	body.free()
	var has_capsule := false
	var has_cylinder := false
	for sh in shapes:
		if sh is CapsuleShape3D:
			has_capsule = true
		if sh is CylinderShape3D:
			has_cylinder = true
	print("[突起] 碰撞体形状数=%d 含胶囊=%s 含圆柱=%s" % [shapes.size(), str(has_capsule), str(has_cylinder)])
	assert_true(has_capsule, "必须有胶囊碰撞体")
	assert_true(not has_cylinder, "不允许平底圆柱（它是卡在小突起上的经典成因）")

	# ② 参数必须保通过性（抗抖动交给法线平滑，不该靠这些牺牲通过性）
	var s2: GDScript = ResourceLoader.load(PLR, "", ResourceLoader.CACHE_MODE_IGNORE)
	var b2: CharacterBody3D = s2.new()
	print("[突起] wall_min_slide=%.1f 度 ｜ floor_max_angle=%.1f 度 ｜ safe_margin=%.3f" % [
			rad_to_deg(b2.wall_min_slide_angle), rad_to_deg(b2.floor_max_angle), b2.safe_margin])
	assert_true(rad_to_deg(b2.wall_min_slide_angle) <= 15.0,
			"wall_min_slide_angle 必须够小，否则突起侧面会被判成'不许滑的墙'（实测 %.1f 度）" % rad_to_deg(b2.wall_min_slide_angle))
	assert_true(rad_to_deg(b2.floor_max_angle) >= 50.0,
			"floor_max_angle 必须够大，突起斜面才能算地面走上去（实测 %.1f 度）" % rad_to_deg(b2.floor_max_angle))
	assert_true(b2.safe_margin <= 0.015,
			"safe_margin 不能太大，否则会提前撞上小突起（实测 %.3f）" % b2.safe_margin)
	b2.free()

	# ③ 抬步不能在"被挡住"时被门槛锁死（源码断言，沿用项目既有风格）
	var fh := FileAccess.open(ProjectSettings.globalize_path(PLR), FileAccess.READ)
	assert_true(fh != null, "读不到 player.gd")
	if fh != null:
		var src := fh.get_as_text()
		fh.close()
		assert_true(src.contains("get_slide_collision_count() == 0"),
				"try_step_up 仍只在 is_on_floor 时触发 -> 顶住突起时抬步不会触发")
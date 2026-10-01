@tool
extends McpTestSuite
## 坡度速度规则自检。
## 需求：上坡按角度**减速**、下坡按角度**加速**，并且有**最大/最小速度限制**；
##       限制是"相对当前基础速度"的比例 —— 基础速度已含 Shift 跑步，所以走路和跑步各自同比例受限。
## 说明（已读源码确认）：抬步 `try_step_up` 是 global_position 直接 teleport、且不碰速度（已读源码确认），
##       所以"上坡被弹飞"的来源是高速冲坡 + move_and_slide，而不是抬步。

const CAMERA_RIG := "res://scripts/camera_rig.gd"
const WALK := 5.0
const RUN := 9.0


func suite_name() -> String:
	return "player_slope"


func _load() -> GDScript:
	return ResourceLoader.load(CAMERA_RIG, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _f(inst: Object, normal: Vector3, dir: Vector3, on_floor := true) -> float:
	return float(inst.call("slope_speed_factor", normal, dir, on_floor))


func _slope(deg: float) -> Vector3:
	return Vector3(0.0, cos(deg_to_rad(deg)), sin(deg_to_rad(deg))).normalized()


func test_slope_factor_rules() -> void:
	var s := _load()
	assert_true(s != null, "camera_rig.gd 加载失败")
	if s == null:
		return
	var inst: Object = s.new()
	if inst == null:
		return
	var uphill := Vector3(0, 0, -1)      # 法线朝 +z → 朝 -z 走是上坡
	var downhill := Vector3(0, 0, 1)
	var sideways := Vector3(1, 0, 0)

	# ① 不影响现有手感的情况
	assert_true(absf(_f(inst, Vector3.UP, uphill) - 1.0) < 0.0001, "平地不该变")
	assert_true(absf(_f(inst, _slope(30), uphill, false) - 1.0) < 0.0001, "空中不该变")
	assert_true(absf(_f(inst, _slope(30), Vector3.ZERO) - 1.0) < 0.0001, "没输入不该变")
	assert_true(absf(_f(inst, _slope(30), sideways) - 1.0) < 0.0001, "沿坡横移不该变")

	# ② 上坡减速且单调
	var u30 := _f(inst, _slope(30), uphill)
	var u50 := _f(inst, _slope(50), uphill)
	print("[坡度速度] 上坡 30° = %.3f ｜ 50° = %.3f ｜ 平地 = 1.000" % [u30, u50])
	assert_true(u30 < 1.0, "上坡该减速，实际 %.3f" % u30)
	assert_true(u50 < u30, "越陡越慢：50° %.3f 应小于 30° %.3f" % [u50, u30])

	# ③ 下坡加速且单调，且有上限
	var d30 := _f(inst, _slope(30), downhill)
	var d50 := _f(inst, _slope(50), downhill)
	var cap := float(inst.get("slope_speed_max_ratio"))
	print("[坡度速度] 下坡 30° = %.3f ｜ 50° = %.3f ｜ 上限 = %.3f" % [d30, d50, cap])
	assert_true(d30 > 1.0, "下坡该加速，实际 %.3f" % d30)
	assert_true(d50 > d30, "越陡越快：50° %.3f 应大于 30° %.3f" % [d50, d30])
	assert_true(d50 <= cap + 0.0001, "下坡不得超过上限 %.3f，实际 %.3f" % [cap, d50])

	# ④ 最大/最小限制：走路与跑步都必须落在各自的比例区间内（Shift 已被基础速度涵盖）
	var lo := float(inst.get("slope_speed_min_ratio"))
	var hi := float(inst.get("slope_speed_max_ratio"))
	for base: float in [WALK, RUN]:
		var v_up := base * _f(inst, _slope(60), uphill)
		var v_down := base * _f(inst, _slope(60), downhill)
		print("[坡度速度] 基础 %.1f → 最陡上坡 %.2f（下限 %.2f）｜ 最陡下坡 %.2f（上限 %.2f）" % [
				base, v_up, base * lo, v_down, base * hi])
		assert_true(v_up >= base * lo - 0.0001, "基础 %.1f 上坡低于下限：%.2f" % [base, v_up])
		assert_true(v_down <= base * hi + 0.0001, "基础 %.1f 下坡超过上限：%.2f" % [base, v_down])

	# ⑤ 斜着上坡：按分量过渡（介于 1.0 与正上坡之间）
	var diag := Vector3(0.7071, 0, -0.7071)
	var u_diag := _f(inst, _slope(40), diag)
	print("[坡度速度] 40° 斜上坡 = %.3f（正上坡 %.3f）" % [u_diag, _f(inst, _slope(40), uphill)])
	assert_true(u_diag < 1.0 and u_diag > _f(inst, _slope(40), uphill),
			"斜上坡应介于平地与正上坡之间：%.3f" % u_diag)

	# ⑥ 参数生效 / 可关闭
	inst.set("slope_speed_angle", 0.0)
	assert_true(absf(_f(inst, _slope(50), uphill) - 1.0) < 0.0001, "角度设 0 应关闭整条规则")
	inst.set("slope_speed_angle", 20.0)
	inst.set("slope_speed_min_ratio", 0.2)
	inst.set("slope_speed_max_ratio", 1.6)
	print("[坡度速度] 改参数后：60° 上坡 = %.3f（应 0.2）｜ 60° 下坡 = %.3f（应 1.6）" % [
			_f(inst, _slope(60), uphill), _f(inst, _slope(60), downhill)])
	assert_true(absf(_f(inst, _slope(60), uphill) - 0.2) < 0.001, "最小比例参数没生效")
	assert_true(absf(_f(inst, _slope(60), downhill) - 1.6) < 0.001, "最大比例参数没生效")
	inst.free()


func test_slope_factor_is_wired_into_movement() -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(CAMERA_RIG), FileAccess.READ)
	assert_true(f != null, "读不到 camera_rig.gd")
	if f == null:
		return
	var src := f.get_as_text()
	f.close()
	# 抗抖动改造后：速度系数改用**平滑后的**地面法线（_ground_up），
	# 所以这里放宽为"必须把 slope_speed_factor 接进移动、且用的是平滑法线"，
	# 并顺手把新增的两处接线也守住（按平滑地面投影 + 每帧更新法线）。
	assert_true(src.contains("slope_speed_factor(_ground_up") or src.contains("slope_speed_factor(player.get_floor_normal()"),
			"移动里没接入坡度速度规则")
	assert_true(src.contains("move_xz.slide(_ground_up)"), "移动没有按平滑地面投影")
	assert_true(src.contains("update_ground_up(delta)"), "没有每帧更新平滑地面法线")
	assert_true(src.contains("move_xz = face * base_speed * factor"), "速度计算没乘上坡度系数")
	assert_true(src.contains("slope_speed_min_ratio") and src.contains("slope_speed_max_ratio"),
			"缺少最大/最小速度比例参数")
	# 基础速度必须仍然区分走路/跑步（Shift）
	assert_true(src.contains("base_speed := run_speed if running else move_speed"),
			"基础速度没区分走路与 Shift 跑步")


func test_crack_guard_rules() -> void:
	# 用户反馈：角色走到蓝色裂缝处会"瞬间弹走" —— 那是扎进地形后 move_and_slide 去穿插的猛弹。
	# 守卫的职责：在缝边就拦住；但对"悬崖"要放行（该掉就掉），也不能影响小坑洼。
	var s := _load()
	if s == null:
		return
	var inst: Object = s.new()
	if inst == null:
		return
	var feet := 10.0

	# ① 前方平地上：不拦
	assert_true(not bool(inst.call("crack_verdict", feet, true, 9.9, true, 9.9)), "平地不该被拦")
	# ② 小坑洼（下沉 0.2m）：不拦
	assert_true(not bool(inst.call("crack_verdict", feet, true, 9.8, true, 9.8)), "小坑洼不该被拦")
	# ③ 窄缝：前方下沉 1.5m，对面 1.0m 外回到脚面 → 拦
	assert_true(bool(inst.call("crack_verdict", feet, true, 8.5, true, 9.9)), "窄缝必须拦住")
	# ④ 悬崖：前方下沉，对面没有地 → 放行
	assert_true(not bool(inst.call("crack_verdict", feet, true, 8.5, false, 0.0)), "悬崖不该被拦")
	# ⑤ 前方是空的、对面有地 → 缝，拦
	assert_true(bool(inst.call("crack_verdict", feet, false, 0.0, true, 9.9)), "前方是缝且对面有地，应拦住")
	# ⑥ 关掉守卫就一律放行
	inst.set("crack_guard", false)
	assert_true(not bool(inst.call("crack_verdict", feet, true, 8.5, true, 9.9)), "关掉守卫后不该再拦")
	inst.set("crack_guard", true)
	inst.set("crack_max_drop", 1.0)
	assert_true(not bool(inst.call("crack_verdict", feet, true, 9.5, true, 9.9)),
			"放宽 crack_max_drop 后 0.5m 下沉不算缝")
	inst.free()


func test_crack_guard_is_wired_into_movement() -> void:
	var f := FileAccess.open(ProjectSettings.globalize_path(CAMERA_RIG), FileAccess.READ)
	if f == null:
		return
	var src := f.get_as_text()
	f.close()
	assert_true(src.contains("crack_ahead(get_world_3d().direct_space_state"), "移动里没接入裂缝守卫")
	assert_true(src.contains("move_xz = Vector3.ZERO"), "守卫命中时没有停下")
	assert_true(src.contains("crack_guard") and src.contains("crack_max_width"), "缺少守卫参数")
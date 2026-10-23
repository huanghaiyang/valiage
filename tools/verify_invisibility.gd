extends SceneTree
## 隐身 自检：注册 / 数值表 / 首次施放扣蓝 / 半透明覆盖角色与法杖 /
## 生效期间刷新（剩余清零重新计时）/ 法力不足不刷新 / 中途换法杖也变透明 /
## 到点还原 / 切法术（代理被释放）后效果仍按 60s 收尾。
##
## 跑法：
##   Godot_v4.7.2-stable_win64_console.exe --headless --path D:\sgames\CozyVale \
##       --script res://tools/verify_invisibility.gd --quit

var _done := false
var _pass := 0
var _fail := 0
const DT := 1.0 / 60.0
const ALPHA := 0.55                       # invisibility_effect.BODY_TRANSPARENCY


func _ck(label: String, ok: bool, extra: String = "") -> void:
	if ok:
		_pass += 1
		print("  ✓ %s%s" % [label, ("  " + extra) if extra != "" else ""])
	else:
		_fail += 1
		print("  ✗ %s%s" % [label, ("  " + extra) if extra != "" else ""])


func _pump(node: Node, seconds: float) -> void:
	for i in int(seconds / DT):
		node.call("_process", DT)


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	print("=========== 隐身 自检 ===========")

	# ---- 1. 注册与数值表 ----
	var spells: Dictionary = load("res://scripts/spells/spell_caster.gd").get_script_constant_map()["SPELLS"]
	_ck("已在 spell_caster.SPELLS 注册", spells.has("invisibility"))
	var names: Dictionary = load("res://scripts/spells/spell_wheel.gd").get_script_constant_map()["SPELL_NAMES"]
	_ck("术法名 = 隐身", String(names.get("invisibility", "")) == "隐身",
			"实际 '%s'" % String(names.get("invisibility", "")))
	var assigned: Dictionary = load("res://scripts/spells/spell_wheel.gd").get_script_constant_map()["ASSIGNED"]
	_ck("已占轮盘槽位 1002（第 2 圈第 3 格）",
			String(assigned.get(1002, "")) == "invisibility",
			"槽位1002 = '%s'" % String(assigned.get(1002, "")))
	var sheet = load("res://scripts/spells/spell_sheet.gd")
	_ck("数值表：单次耗蓝 = 10", is_equal_approx(sheet.f("invisibility", "mana_cost", -1.0), 10.0),
			"%.1f" % sheet.f("invisibility", "mana_cost", -1.0))
	_ck("数值表：持续 = 60s", is_equal_approx(sheet.f("invisibility", "duration", -1.0), 60.0),
			"%.1f" % sheet.f("invisibility", "duration", -1.0))
	_ck("数值表：时间加和自洽", sheet.validate("invisibility").is_empty(),
			str(sheet.validate("invisibility")))

	# ---- 2. 假角色（本体网格 + 法杖网格）----
	var player := Node3D.new()
	player.name = "TestPlayer"
	get_root().add_child(player)
	var body := MeshInstance3D.new()
	body.name = "BodyMesh"
	body.mesh = BoxMesh.new()
	player.add_child(body)
	var staff := Node3D.new()
	staff.name = "TestStaff"
	player.add_child(staff)
	var staff_mesh := MeshInstance3D.new()
	staff_mesh.name = "StaffMesh"
	staff_mesh.mesh = BoxMesh.new()
	staff.add_child(staff_mesh)

	var mana = get_root().get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
	var mana0 := float(mana.get("current")) if mana != null else 0.0

	var spell: Node3D = (load("res://scripts/spells/invisibility.gd") as GDScript).new()
	spell.name = "InvisibilityJet"
	get_root().add_child(spell)
	spell.call("setup", player, staff)
	_ck("初始未生效", not bool(spell.call("is_casting")))

	# ---- 3. 第一次施放：扣 10 蓝 + 角色/法杖半透明 + 关闭投影 ----
	spell.call("start_cast")
	var eff := player.get_node_or_null("InvisibilityEffect") as Node3D
	_ck("效果宿主已挂在角色下", eff != null)
	_ck("开始生效（is_casting = true）", bool(spell.call("is_casting")))
	_ck("剩余 ≈ 60s", eff != null and absf(float(eff.call("remaining")) - 60.0) < 0.2,
			("remaining=%.1f" % float(eff.call("remaining"))) if eff != null else "无")
	if mana != null:
		_ck("扣蓝 10 点", absf(mana0 - float(mana.get("current")) - 10.0) < 0.01,
				"%.1f -> %.1f" % [mana0, float(mana.get("current"))])
	# 淡入过渡：施放瞬间位于过渡起点（0），FADE_IN_S 之后才到 BODY_TRANSPARENCY
	_ck("施放瞬间位于过渡起点（透明度 ≈0）", body.transparency < 0.05,
			"transparency=%.3f" % body.transparency)
	_ck("过渡起点同样作用于随身法杖", staff_mesh.transparency < 0.05,
			"transparency=%.3f" % staff_mesh.transparency)
	_pump(eff, 0.2)
	_ck("过渡中途透明度介于起点与半透明之间",
			body.transparency > 0.05 and body.transparency < ALPHA,
			"transparency=%.3f" % body.transparency)
	_pump(eff, 0.3)
	_ck("过渡结束（0.4s）后角色本体半透明", is_equal_approx(body.transparency, ALPHA),
			"transparency=%.3f" % body.transparency)
	_ck("随身法杖半透明", is_equal_approx(staff_mesh.transparency, ALPHA),
			"transparency=%.3f" % staff_mesh.transparency)
	_ck("半透明期间关闭投影", body.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			and staff_mesh.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	var ledger: Dictionary = eff.get("_ledger") if eff != null else {}
	var snap_ok := true
	for id in ledger:
		var e: Dictionary = ledger[id]
		if not is_equal_approx(float(e.get("prev_trans", -1.0)), 0.0):
			snap_ok = false
	_ck("快照记录的是施法前的透明度（0）", snap_ok and ledger.size() >= 2,
			"ledger=%d" % ledger.size())

	# ---- 4. 生效 10s 后再次按下：剩余清零、重新计时（再扣 10 蓝）----
	_pump(eff, 9.5)                        # 前面淡入过渡已消耗 0.5s
	var before := float(eff.call("remaining"))
	_ck("10s 后剩余 ≈ 50s", absf(before - 50.0) < 0.3, "remaining=%.1f" % before)
	var mana1 := float(mana.get("current")) if mana != null else 0.0
	# 按住期间 caster 每帧都会调 start_cast：同一轮按住里**只能算一次**
	for i in 5:
		spell.call("start_cast")
	_ck("按住期间不会重复施放（沿检测）",
			absf(float(eff.call("remaining")) - before) < 0.01
			and (mana == null or absf(float(mana.get("current")) - mana1) < 0.01),
			"remaining=%.1f" % float(eff.call("remaining")))
	# 松手 -> 再按 = 新的一次施放
	spell.call("stop_cast")
	spell.call("start_cast")
	_ck("再次施放后剩余回到 60s（旧的 50s 已清零）",
			absf(float(eff.call("remaining")) - 60.0) < 0.2,
			"remaining=%.1f" % float(eff.call("remaining")))
	if mana != null:
		_ck("刷新同样扣 10 蓝", absf(mana1 - float(mana.get("current")) - 10.0) < 0.01,
				"%.1f -> %.1f" % [mana1, float(mana.get("current"))])
	_ck("已处于隐身状态时刷新不重播过渡（透明度保持半透明）",
			is_equal_approx(body.transparency, ALPHA),
			"transparency=%.3f" % body.transparency)
	var snap2: Dictionary = eff.get("_ledger")
	var snap_body: Dictionary = snap2.get(body.get_instance_id(), {})
	_ck("刷新不覆盖快照（仍是施法前的 0）",
			is_equal_approx(float(snap_body.get("prev_trans", -1.0)), 0.0),
			"prev_trans=%s" % str(snap_body.get("prev_trans", "无")))

	# ---- 5. 法力不足：不刷新、不改变剩余时间 ----
	_pump(eff, 5.0)
	var left := float(eff.call("remaining"))
	if mana != null:
		mana.call("set", "current", 3.0)
	spell.call("stop_cast")
	spell.call("start_cast")
	_ck("法力不足时剩余时间保持不变（≈55s）",
			absf(float(eff.call("remaining")) - left) < 0.01, "remaining=%.1f" % float(eff.call("remaining")))
	if mana != null:
		_ck("法力不足时不扣蓝（余额仍是 3）", is_equal_approx(float(mana.get("current")), 3.0),
				"%.1f" % float(mana.get("current")))
	_ck("法力不足时已有半透明不受影响", is_equal_approx(body.transparency, ALPHA))

	# ---- 6. 中途换法杖：新网格在重扫后也变透明 ----
	staff.remove_child(staff_mesh)
	staff_mesh.queue_free()
	var staff2 := MeshInstance3D.new()
	staff2.name = "StaffMesh2"
	staff2.mesh = BoxMesh.new()
	staff.add_child(staff2)
	_ck("新法杖网格一开始不透明（还没重扫）", is_equal_approx(staff2.transparency, 0.0))
	_pump(eff, 0.6)
	_ck("重扫后新法杖网格也半透明", is_equal_approx(staff2.transparency, ALPHA),
			"transparency=%.3f" % staff2.transparency)

	# ---- 7. 尾声明灭：最后 5 秒透明度按正弦往复，且范围受限 ----
	_pump(eff, maxf(0.0, float(eff.call("remaining")) - 4.1))
	var vmin := 2.0
	var vmax := -1.0
	for i in 30:
		eff.call("_process", DT)
		var t := body.transparency
		vmin = minf(vmin, t)
		vmax = maxf(vmax, t)
	_ck("尾声进入明灭（透明度在往复变化）", vmax - vmin > 0.4,
			"%.3f ~ %.3f" % [vmin, vmax])
	_ck("闪烁范围限制在 0.18~0.88", vmin >= 0.17 and vmax <= 0.89,
			"%.3f ~ %.3f" % [vmin, vmax])
	_ck("闪烁同时作用到随身法杖", absf(staff2.transparency - body.transparency) < 0.001,
			"body=%.3f staff=%.3f" % [body.transparency, staff2.transparency])

	# ---- 8. 到点还原（透明度与投影都回到施法前）----
	_pump(eff, float(eff.call("remaining")) + 0.2)
	_ck("计时结束 -> 不再生效", not bool(eff.call("is_active")))
	_ck("角色本体恢复不透明", is_equal_approx(body.transparency, 0.0),
			"transparency=%.3f" % body.transparency)
	_ck("法杖恢复不透明", is_equal_approx(staff2.transparency, 0.0),
			"transparency=%.3f" % staff2.transparency)
	_ck("投影开关已还原", body.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			and staff2.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON)
	_ck("效果宿主复用一个节点（不重复创建）",
			_count_effects(player) == 1, "count=%d" % _count_effects(player))

	# ---- 9. 切法术（代理被释放）后效果仍按自己的计时收尾 ----
	if mana != null:
		mana.call("refill")
	spell.call("stop_cast")
	spell.call("start_cast")
	_ck("再次施放后重新生效", bool(eff.call("is_active")))
	_ck("从非隐身重新进入隐身：过渡重播（透明度回到起点）", body.transparency < 0.05,
			"transparency=%.3f" % body.transparency)
	_pump(eff, 0.5)
	_ck("过渡结束后再次半透明", is_equal_approx(body.transparency, ALPHA),
			"transparency=%.3f" % body.transparency)
	spell.queue_free()                     # 模拟"从轮盘改选别的术法"
	_ck("代理释放后效果宿主仍在生效", is_instance_valid(eff) and bool(eff.call("is_active")))
	_pump(eff, float(eff.call("remaining")) + 0.2)
	_ck("代理释放后依然能正常收尾并还原",
			not bool(eff.call("is_active")) and is_equal_approx(body.transparency, 0.0),
			"transparency=%.3f" % body.transparency)

	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true


## 数一下角色下有几个效果宿主（应当始终是 1 个复用的节点）。
func _count_effects(player: Node3D) -> int:
	var n := 0
	for c in player.get_children():
		if String(c.name) == "InvisibilityEffect":
			n += 1
	return n

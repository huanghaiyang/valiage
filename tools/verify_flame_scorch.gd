extends SceneTree
## 火焰灼烧 自检（新版：一次性范围法术）
## 覆盖：配置表数值 / 选点接口 / 圈内生火 / 单次扣蓝 / 8 秒灼烧扣血 10每秒 / 余烬不扣血

var _done := false
var _pass := 0
var _fail := 0
const DT := 1.0 / 60.0


class DummyEnemy extends Node3D:
	var hp := 10000
	func take_damage(n: int) -> void:
		hp -= n


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
	print("=========== 火焰灼烧 自检（一次性范围）===========")

	# ---- 1. 配置表 ----
	var sheet := load("res://scripts/spells/spell_sheet.gd")
	_ck("配置表读取正常", sheet.has("flame_scorch"))
	_ck("改成了**一次性**法术", sheet.b("flame_scorch", "one_shot", false))
	_ck("单次耗蓝 = 30", absf(sheet.f("flame_scorch", "mana_cost", -1.0) - 30.0) < 0.001,
			"%.2f" % sheet.f("flame_scorch", "mana_cost", -1.0))
	_ck("灼烧持续 = 8.0s", absf(sheet.f("flame_scorch", "duration", -1.0) - 8.0) < 0.001,
			"%.2f" % sheet.f("flame_scorch", "duration", -1.0))
	_ck("余烬淡出 = 1.2s", absf(sheet.f("flame_scorch", "fade_time", -1.0) - 1.2) < 0.001)
	var tg: Dictionary = sheet.get_spell("flame_scorch").get("targeting", {})
	_ck("选点器已启用", bool(tg.get("enabled", false)))
	_ck("直径范围 5~10 米", absf(float(tg.get("diameter_min", 0)) - 5.0) < 0.001
			and absf(float(tg.get("diameter_max", 0)) - 10.0) < 0.001,
			"%.1f ~ %.1f" % [float(tg.get("diameter_min", 0)), float(tg.get("diameter_max", 0))])
	_ck("施法距离 1~12 米", absf(float(tg.get("range_min", 0)) - 1.0) < 0.001
			and absf(float(tg.get("range_max", 0)) - 12.0) < 0.001,
			"%.1f ~ %.1f" % [float(tg.get("range_min", 0)), float(tg.get("range_max", 0))])
	_ck("每秒扣血 = 10", absf(float(tg.get("damage_per_sec", 0)) - 10.0) < 0.001)
	_ck("选点纹理指向 circle_02.png", String(tg.get("texture", "")).ends_with("circle_02.png"),
			String(tg.get("texture", "")))
	_ck("数值表自洽", (sheet.call("validate", "flame_scorch") as Array).is_empty(),
			"%s" % str(sheet.call("validate", "flame_scorch")))

	# ---- 2. 法术装配 ----
	var player := Node3D.new()
	get_root().add_child(player)
	player.global_position = Vector3(0, 0, 0)
	var player_body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 1.8, 0.4)
	player_body.mesh = bm
	player_body.position = Vector3(0, 0.9, 0)
	player.add_child(player_body)

	var spell: Node3D = (load("res://scripts/spells/flame_scorch.gd") as GDScript).new()
	get_root().add_child(spell)
	spell.call("setup", player, null)
	_ck("声明了 has_targeting()（施法器会据此挂选点器）", bool(spell.call("has_targeting")))
	_ck("targeting_config() 能取到表里的选点段",
			not (spell.call("targeting_config") as Dictionary).is_empty())

	# ---- 3. 圈内施法 ----
	var mana = get_root().get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
	var before := float(mana.get("current")) if mana != null else 0.0
	var center := Vector3(6.0, 0.0, 0.0)
	var radius := 3.0
	spell.call("cast_at", center, radius)
	var m1 := float(mana.get("current")) if mana != null else 0.0
	_ck("单次扣蓝 30（一次性，不逐秒扣）", absf((before - m1) - 30.0) < 1.5,
			"%.1f -> %.1f" % [before, m1])
	_ck("进入点燃阶段", int(spell.get("_state")) == 1, "state=%d" % int(spell.get("_state")))
	var patches: Array = spell.get("_patches")
	var used := int(spell.get("_used"))
	_ck("圈内生成了火焰簇", used >= 6 and patches.size() >= used, "簇数 %d" % used)
	var inside := 0
	var visible_cnt := 0
	for i in range(used):
		var f := patches[i] as Node3D
		var p := f.global_position
		if Vector2(p.x - center.x, p.z - center.z).length() <= radius + 0.01:
			inside += 1
		if f.visible:
			visible_cnt += 1
	_ck("所有火焰簇都落在**圈定范围内**", inside == used, "%d / %d" % [inside, used])
	# ★ 回归：火焰**自身占地**也不能溢出圈外（用户实测：火生成超出了圈）
	var over := 0
	var fp := float(spell.get("patch_footprint")) * (patches[0] as Node3D).scale.x
	for i in range(used):
		var p2 := (patches[i] as Node3D).global_position
		var dist := Vector2(p2.x - center.x, p2.z - center.z).length()
		if dist + fp > radius + 0.02:
			over += 1
	_ck("火焰连自身占地也不溢出圈外", over == 0,
			"溢出 %d 簇（火半径 %.2f，圈半径 %.2f）" % [over, fp, radius])
	_ck("火焰簇可见", visible_cnt == used, "%d / %d" % [visible_cnt, used])
	# ★ 回归：焰卡不能有"上下抖动"（曾经每张卡 ±5cm 随机相位摆动 -> 整片火在抖）
	var fx := patches[0] as Node3D
	var items: Array = fx.get("_items")
	var drift := 0.0
	if items.size() > 0:
		for t in range(30):
			fx.call("_process", DT)
			for it in items:
				var n := it["node"] as Node3D
				drift = maxf(drift, absf(n.position.y - float((it["base_pos"] as Vector3).y)))
	_ck("焰卡没有上下抖动（位置固定在 base_pos）", items.size() > 0 and drift < 0.0005,
			"最大偏移 %.5f 米（有旧代码时会到 0.05）" % drift)
	# ★ 回归：每张卡的**贴图流速**必须不同，否则整片火按同一节奏窜（"过于有节奏感"）
	var speeds := []
	for it3 in items:
		var mm3 := it3["mat"] as ShaderMaterial
		if mm3 != null:
			speeds.append(float(mm3.get_shader_parameter("scroll_scale")))
	var smin := 99.0
	var smax := -99.0
	for s in speeds:
		smin = minf(smin, s)
		smax = maxf(smax, s)
	_ck("每张焰卡的贴图流速各不相同（打破整齐节奏）",
			speeds.size() > 4 and (smax - smin) > 0.25,
			"%d 张卡，流速 %.2f ~ %.2f（差值 %.2f）" % [speeds.size(), smin, smax, smax - smin])

	# ---- 4. 灼烧阶段扣血 ----
	_pump(spell, 0.4)
	_ck("点燃结束 -> 进入灼烧", int(spell.get("_state")) == 2, "state=%d" % int(spell.get("_state")))
	var enemy := DummyEnemy.new()
	enemy.add_to_group("enemies")
	get_root().add_child(enemy)
	enemy.global_position = center
	var hp0: int = enemy.hp
	_pump(spell, 1.0)
	var dealt: int = hp0 - enemy.hp
	_ck("圈内敌人每秒扣血约 10", absf(float(dealt) - 10.0) <= 2.0, "1 秒扣了 %d" % dealt)
	enemy.global_position = center + Vector3(radius + 3.0, 0.0, 0.0)
	var hp1: int = enemy.hp
	_pump(spell, 1.0)
	_ck("圈外敌人不扣血", enemy.hp == hp1, "%d -> %d" % [hp1, enemy.hp])

	# ---- 5. 8 秒后进入余烬，且**余烬不扣血** ----
	enemy.global_position = center
	# 注意：前面扣血测试已经烧了约 2.1 秒，这里只能再推 6.2 秒
	# （推到 8s 是"进入余烬"，推到 9.2s 之后就熄灭了 —— 别推过头）
	_pump(spell, 6.2)
	_ck("灼烧 8 秒后进入余烬阶段", int(spell.get("_state")) == 3,
			"state=%d" % int(spell.get("_state")))
	var hp2: int = enemy.hp
	_pump(spell, 0.6)
	_ck("★ 余烬（消失）阶段**不扣血**", enemy.hp == hp2, "%d -> %d" % [hp2, enemy.hp])
	_pump(spell, 1.0)
	_ck("余烬结束 -> 熄灭", int(spell.get("_state")) == 0, "state=%d" % int(spell.get("_state")))
	var still_visible := 0
	for i in range(used):
		if (patches[i] as Node3D).visible:
			still_visible += 1
	_ck("熄灭后火焰全部隐藏", still_visible == 0, "仍可见 %d" % still_visible)

	# ---- 6. 松手不中断（一次性） ----
	if mana != null:
		mana.call("refill")
	spell.call("cast_at", center, 2.5)
	_pump(spell, 0.5)
	spell.call("stop_cast")
	_pump(spell, 0.3)
	_ck("一次性：松手不中断（仍在灼烧）", int(spell.get("_state")) == 2,
			"state=%d" % int(spell.get("_state")))

	# ---- 7. 选点圈：不规则表面必须被平滑（喂人造尖刺给纯函数验证）----
	var tg2: Node3D = (load("res://scripts/spells/spell_targeting.gd") as GDScript).new()
	get_root().add_child(tg2)
	var rows: Array = []
	var SEG := int(tg2.get("SEGMENTS")) if false else 64
	for ring in range(7):
		var row := PackedFloat32Array()
		row.resize(SEG)
		for s in range(SEG):
			row[s] = 0.0
		rows.append(row)
	# 在中间某处造一根 +3 米、-3 米的尖刺（等价于打到墙顶 / 掉进深沟）
	# ★ PackedFloat32Array 是**值类型**：改副本不会影响数组里那份，必须写回
	var spike: PackedFloat32Array = rows[3]
	spike[10] = 3.0
	spike[11] = -3.0
	rows[3] = spike
	var smoothed: Array = tg2.call("_smooth_heights", rows, 0.0)
	var max_step := 0.0
	var max_dev := 0.0
	for ring in range(7):
		var row2: PackedFloat32Array = smoothed[ring]
		for s in range(SEG):
			max_dev = maxf(max_dev, absf(row2[s]))
			max_step = maxf(max_step, absf(row2[s] - row2[(s + 1) % SEG]))
	_ck("尖刺被限幅（不会爬到墙顶/掉进深沟）", max_dev <= 0.55,
			"最大偏离圆心高度 %.3f 米（限幅 0.45 + 平滑余量）" % max_dev)
	_ck("相邻顶点落差被抹平（不再拉出尖刺布帘）", max_step <= 0.30,
			"相邻顶点最大落差 %.3f 米（原始输入是 3.0）" % max_step)
	# ★ 同时必须**保住坡形**：喂一片缓坡，平滑后落差不能被抹掉
	#   （只做限幅+重平均会把缓坡也压平 -> 就不"适配地形"了）
	var ramp: Array = []
	for ring in range(7):
		var row3 := PackedFloat32Array()
		row3.resize(SEG)
		for s in range(SEG):
			row3[s] = float(s) / float(SEG) * 0.25     # 一圈内缓缓升高 0.25 米（小于限幅 0.35，避免限幅干扰判定）
		ramp.append(row3)
	var ramped: Array = tg2.call("_smooth_heights", ramp, 0.0)
	var rmin := 99.0
	var rmax := -99.0
	for ring in range(1, 7):
		var rr: PackedFloat32Array = ramped[ring]
		for s in range(SEG):
			rmin = minf(rmin, rr[s])
			rmax = maxf(rmax, rr[s])
	_ck("缓坡被保住（没有把地形抹平）", (rmax - rmin) > 0.20,
			"平滑后落差 %.3f 米（输入 0.25，限幅 0.35 不干扰）" % (rmax - rmin))
	# ---- 8. 选点圈：只认"能站的地面"，不顺着物体立面爬 ----
	_ck("平地算地面（法线朝上）", bool(tg2.call("_is_ground", {"normal": Vector3(0.1, 0.98, 0.05)})))
	_ck("垂直面不算地面（墙/栏杆/树干，不会铺上去）",
			not bool(tg2.call("_is_ground", {"normal": Vector3(1.0, 0.02, 0.0)})),
			"竖直墙法线被拒绝")
	_ck("陡坡（约 60 度）不算地面",
			not bool(tg2.call("_is_ground", {"normal": Vector3(0.0, 0.5, 0.87)})),
			"normal.y=0.5 < 阈值 0.6")
	_ck("缓坡算地面（约 30 度）", bool(tg2.call("_is_ground", {"normal": Vector3(0.0, 0.87, 0.5)})))
	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

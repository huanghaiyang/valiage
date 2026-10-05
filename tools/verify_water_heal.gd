extends SceneTree
## 流水治疗 自检：注册 / 水膜贴装(非球体) / 三阶段 / 实时角色点 / 法力不足也淡出。

var _done := false
var _pass := 0
var _fail := 0
const DT := 1.0 / 60.0


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


## 顶点密集的圆柱（半径 r、高 h、nh 段高 × na 段方位）：真实曲面 = 圆
func _make_test_cylinder(r: float, h: float, nh: int, na: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring := func(i: int, s: int) -> Vector3:
		var a := float(s) / float(na) * TAU
		return Vector3(cos(a) * r, -h * 0.5 + float(i) / float(nh) * h, sin(a) * r)
	for i in range(nh):
		for s in range(na):
			var p00: Vector3 = ring.call(i, s)
			var p01: Vector3 = ring.call(i, s + 1)
			var p10: Vector3 = ring.call(i + 1, s)
			var p11: Vector3 = ring.call(i + 1, s + 1)
			st.add_vertex(p00)
			st.add_vertex(p10)
			st.add_vertex(p11)
			st.add_vertex(p00)
			st.add_vertex(p11)
			st.add_vertex(p01)
	st.generate_normals()
	return st.commit()


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	print("=========== 流水治疗 自检 ===========")

	# ---- 1. 注册 ----
	var spells: Dictionary = load("res://scripts/spells/spell_caster.gd").get_script_constant_map()["SPELLS"]
	_ck("已在 spell_caster.SPELLS 注册", spells.has("water_heal"))
	var names: Dictionary = load("res://scripts/spells/spell_wheel.gd").get_script_constant_map()["SPELL_NAMES"]
	_ck("术法名 = 流水治疗", String(names.get("water_heal", "")) == "流水治疗",
			"实际 '%s'" % String(names.get("water_heal", "")))
	var assigned: Dictionary = load("res://scripts/spells/spell_wheel.gd").get_script_constant_map()["ASSIGNED"]
	_ck("已占**第二圈**第 1 格（键 1000）", String(assigned.get(1000, "")) == "water_heal",
			"键1000 = '%s'" % String(assigned.get(1000, "")))
	# ★ 结构断言：每个术法的格号必须落在该圈的格子数之内，否则轮盘永远选不到它
	#   （第一圈只有 6 格，之前把新法术放在键 6 上就踩了这个坑）
	# ---- 1b. 数值表（data/spell_sheet.json）----
	var sheet := load("res://scripts/spells/spell_sheet.gd")
	_ck("数值表可读取且含 water_heal", sheet.has("water_heal"))
	_ck("流水治疗：单次耗蓝 = 20", absf(sheet.f("water_heal", "mana_cost", -1.0) - 20.0) < 0.001,
			"%.2f" % sheet.f("water_heal", "mana_cost", -1.0))
	_ck("流水治疗：施法时间(成型) = 1.70s", absf(sheet.f("water_heal", "cast_time", -1.0) - 1.7) < 0.001,
			"缠绕 %.2f + 成膜 %.2f" % [sheet.f("water_heal", "cast_climb", 0.0),
					sheet.f("water_heal", "cast_veil", 0.0)])
	_ck("流水治疗：薄膜覆盖 = 7.0s", absf(sheet.f("water_heal", "duration", -1.0) - 7.0) < 0.001,
			"%.2f" % sheet.f("water_heal", "duration", -1.0))
	_ck("流水治疗：整体效果时间 = 9.40s", absf(sheet.f("water_heal", "total_time", -1.0) - 9.4) < 0.001,
			"%.2f" % sheet.f("water_heal", "total_time", -1.0))
	_ck("数值表内部自洽（分段之和 = 合计）", (sheet.call("validate", "water_heal") as Array).is_empty(),
			"%s" % str(sheet.call("validate", "water_heal")))
	var all_rows := true
	for k in spells.keys():
		if not sheet.has(String(k)):
			all_rows = false
	_ck("每个已注册法术都在表里预留了行", all_rows, "已注册 %d 个" % spells.size())
	var counts: Array = load("res://scripts/spells/spell_wheel.gd").get_script_constant_map()["RING_COUNTS"]
	var bad := []
	for k in assigned.keys():
		var ring: int = int(k) / 1000
		var cell: int = int(k) % 1000
		if ring >= counts.size() or cell >= int(counts[ring]):
			bad.append("%d(%s)" % [int(k), String(assigned[k])])
	_ck("每个术法的格号都在所属圈的格子数内（否则轮盘选不到）", bad.is_empty(),
			"越界的: %s" % str(bad) if not bad.is_empty() else "全部合法")

	# ---- 2. 假角色：一个 1.8 米高的方块，放在 y=2 的平台上（验证脚底/身高是实时算的）----
	# 用**顶点密集的真实圆柱**当测试角色：真实曲面是半径 0.3 的圆，
	# 而 AABB 包络在 45° 方向会给 0.3*sqrt(2)≈0.424 —— 两者能明确区分开。
	# （注意不能用内置 CylinderMesh：它只在上下两个圈上有顶点，表填不满。）
	var player := Node3D.new()
	get_root().add_child(player)
	var body := MeshInstance3D.new()
	body.mesh = _make_test_cylinder(0.3, 1.8, 24, 24)
	body.position = Vector3(0, 0.9, 0)
	player.add_child(body)
	player.global_position = Vector3(3, 2, -4)

	var spell: Node3D = (load("res://scripts/spells/water_heal.gd") as GDScript).new()
	get_root().add_child(spell)
	spell.call("setup", player, null)
	spell.call("_warmup")                  # 测试里没有 idle 帧，手动触发预热
	_ck("进入游戏（选中法术）时曲面已算好，无需等到施法",
			int(spell.get("_surface_verts")) > 0
			and (spell.get("_warm_helix") as Array).size() == 2,
			"采样顶点 %d，预热网格 %d 条" % [int(spell.get("_surface_verts")),
					(spell.get("_warm_helix") as Array).size()])


	# ---- 3. 施法：水膜铺在角色网格上（不是球体）----
	var mana = get_root().get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
	spell.call("start_cast")
	# 施法动作：成型期间必须要求保持动作（一次性法术否则会被松手切断）
	_ck("成型期间要求保持施法动作（wants_cast_anim）", bool(spell.call("wants_cast_anim")),
			"state=%d" % int(spell.get("_state")))
	var mat = spell.get("_mat")
	_ck("水膜材质已创建", mat != null)
	_ck("水膜铺在**角色自己的网格**上（不是另造的球体）",
			body.material_overlay == mat, "overlay=%s" % str(body.material_overlay))
	# ★ 实体水带：两条，且**所有顶点都在身体包围盒之外**（这就是"不穿模"的硬证据）
	var streams: Array = spell.get("_streams")
	_ck("两条实体螺旋水带已生成", streams.size() == 2
			and (streams[0] as MeshInstance3D).mesh != null
			and (streams[0] as MeshInstance3D).mesh.get_surface_count() > 0,
			"数量 %d" % streams.size())
	var vs: PackedVector3Array = (streams[0] as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var inside := 0
	var ylo := 1e9
	var yhi := -1e9
	var dmin := 1e9
	var dmax := 0.0
	for v in vs:
		ylo = minf(ylo, v.y)
		yhi = maxf(yhi, v.y)
		var d := Vector2(v.x, v.z).length()
		if d > 0.01:
			dmin = minf(dmin, d)
			dmax = maxf(dmax, d)
		# 圆柱半径 0.3 -> 水平距离小于 0.29 就算穿进身体
		if d < 0.29 and v.y > -0.05 and v.y < 1.85:
			inside += 1
	_ck("水带没有穿进身体（顶点全部落在真实曲面之外）", inside == 0,
			"穿入 %d / %d 个顶点" % [inside, vs.size()])
	_ck("水带覆盖脚底到头顶", ylo < 0.15 and yhi > 1.6, "y 范围 %.2f ~ %.2f" % [ylo, yhi])
	# ★ 真实曲面断言：与 AABB 方案的**预期值**比。
	#   圆柱半径 0.3、管半径 0.05 -> 管心 = 体表 + 0.0625，顶点再向外最多 +0.078
	#     · 真实曲面（圆）：最远 ≈ 0.30+0.0625+0.078 ≈ 0.44
	#     · AABB 包络（方）：45° 方向 0.3*sqrt(2)=0.424 -> 最远 ≈ 0.57
	#   所以"最远 < 0.48"就能区分两者。（比值不能用来判断：管壁厚度本身就有 ±0.08 散布。）
	_ck("水带贴合真实曲面（比 AABB 方包络明显更紧）", dmax < 0.48,
			"最远 %.3f 米（AABB 方案会到 ≈0.57）" % dmax)
	_ck("曲面表确实由顶点算出", int(spell.get("_surface_verts")) > 0,
			"采样顶点 %d 个" % int(spell.get("_surface_verts")))

	# ---- 4. 实时角色点 ----
	spell.call("_process", DT)
	var cx: Vector3 = mat.get_shader_parameter("center_xz")
	var fy: float = mat.get_shader_parameter("feet_y")
	var bh: float = mat.get_shader_parameter("body_h")
	_ck("实时算出脚底高度（跟随角色所在位置 y=2）", absf(fy - 2.0) < 0.15, "feet_y=%.3f" % fy)
	_ck("实时算出身高（方块 1.8 米）", absf(bh - 1.8) < 0.15, "body_h=%.3f" % bh)
	_ck("实时算出中心 xz", absf(cx.x - 3.0) < 0.2 and absf(cx.z + 4.0) < 0.2,
			"center=(%.2f, %.2f)" % [cx.x, cx.z])

	# ---- 5. 阶段：上升 -> 成膜 ----
	_ck("开始时处于上升阶段且 climb≈0", int(spell.get("_state")) == 1
			and absf(float(mat.get_shader_parameter("climb"))) < 0.05,
			"climb=%.3f" % float(mat.get_shader_parameter("climb")))
	_pump(spell, 1.3)
	var cl := float(mat.get_shader_parameter("climb"))
	_ck("流水爬到头顶（climb→1）", cl >= 0.99, "climb=%.2f" % cl)
	_ck("上升结束 -> 进入成膜阶段", int(spell.get("_state")) == 2,
			"state=%d" % int(spell.get("_state")))
	_pump(spell, 0.7)
	_ck("整身成膜（veil→1）", absf(float(mat.get_shader_parameter("veil")) - 1.0) < 0.01,
			"veil=%.2f" % float(mat.get_shader_parameter("veil")))
	_ck("流水带已淡出（stream_fade→0）",
			absf(float(mat.get_shader_parameter("stream_fade"))) < 0.01)

	var m0 := float(mana.get("current")) if mana != null else 0.0
	_pump(spell, 1.0)
	var m1 := float(mana.get("current")) if mana != null else 0.0
	_ck("一次性：成型期间**不再逐秒扣蓝**", absf(m1 - m0) < 0.001, "%.1f -> %.1f" % [m0, m1])

	# ---- 6. 停手 -> 淡出 -> 还原 ----
	# ★ 一次性法术：松手**不中断**
	spell.call("stop_cast")
	_pump(spell, 0.3)
	_ck("一次性：松手不中断（仍在成膜/覆盖阶段）", int(spell.get("_state")) == 2,
			"state=%d" % int(spell.get("_state")))
	spell.set("hold_time", 0.1)           # 把覆盖时间调小，快速走完
	_pump(spell, 0.3)
	_ck("覆盖时间到点 -> 自动进入淡出", int(spell.get("_state")) == 3,
			"state=%d" % int(spell.get("_state")))
	# ★ 回归断言：成膜后水带已经淡到 0，进入淡出时**不能跳回亮**（否则会"隐藏后又冒一下"）
	var tf: float = float(spell.get("_stream_mat").get_shader_parameter("fade"))
	_ck("淡出时水带不会重新冒出来（从上一次的实际值继续降）", tf < 0.2,
			"淡出刚开始 fade=%.3f（有 bug 时会跳到 ≈0.86）" % tf)
	_pump(spell, 0.8)
	_ck("淡出结束回到关闭态", int(spell.get("_state")) == 0)
	_ck("角色材质已还原（不留永久水膜）", body.material_overlay == null,
			"overlay=%s" % str(body.material_overlay))

	# ---- 7. 一次性：蓝不够就放不出来 ----
	if mana != null:
		mana.call("refill")
		mana.call("set", "current", 5.0)   # 不够 20
	var before5 := float(mana.get("current")) if mana != null else 0.0
	spell.call("start_cast")
	_ck("蓝不够时放不出来（不进入效果）", int(spell.get("_state")) == 0,
			"state=%d" % int(spell.get("_state")))
	# 注意：Mana 有自然回蓝，所以用"没有被扣掉 20"判断，而不是分毫不差
	_ck("蓝不够时不扣蓝（没有被扣掉 20）",
			(float(mana.get("current")) if mana != null else 0.0) > before5 - 5.0,
			"%.2f -> %.2f" % [before5, (float(mana.get("current")) if mana != null else 0.0)])
	_ck("ran_out_of_mana 置位", bool(spell.call("ran_out_of_mana")))

		# ---- 8. 只算一次 + 跟随角色（独立新实例，放在最后：会挪动角色）----
	var s2: Node3D = (load("res://scripts/spells/water_heal.gd") as GDScript).new()
	get_root().add_child(s2)
	if mana != null:
		mana.call("refill")
	s2.call("setup", player, null)
	s2.call("start_cast")
	var mark := int(s2.get("_surface_builds"))
	_pump(s2, 2.5)
	_ck("曲面**只在发动时算一次**（运行期间不重算）",
			int(s2.get("_surface_builds")) == mark,
			"发动后 %d 次 -> 跑 2.5s 后 %d 次" % [mark, int(s2.get("_surface_builds"))])
	var st2: Array = s2.get("_streams")
	_ck("水带挂成**角色的子节点**", st2.size() == 2
			and (st2[0] as MeshInstance3D).get_parent() == player,
			"父节点 %s" % str((st2[0] as MeshInstance3D).get_parent()))
	var before_pos: Vector3 = (st2[0] as MeshInstance3D).global_position
	player.global_position += Vector3(5.0, 1.5, -2.0)     # 模拟位移 + 弹跳
	player.rotate_y(0.9)                                  # 模拟转身
	var after_pos: Vector3 = (st2[0] as MeshInstance3D).global_position
	_ck("角色位移 + 弹跳 + 转身后，水带跟着一起动",
			before_pos.distance_to(after_pos) > 1.0,
			"移动了 %.2f 米" % before_pos.distance_to(after_pos))
	# ---- 9. 水汽 + 水珠（自带一次全新施法；前面几段已经把状态跑乱了）----
	if mana != null:
		mana.call("refill")
	spell.set("climb_time", 0.2)           # 快速进入成膜阶段
	spell.call("start_cast")
	var guard := 0
	while int(spell.get("_state")) == 1 and guard < 300:
		spell.call("_process", DT)         # 刚跨进成膜那一帧，水珠才生成
		guard += 1
	spell.call("_process", DT)             # 再走一帧：成膜分支才会生成水珠、开水汽
	for f in range(30):                    # 再放 0.5s：开局是错开的，等一部分水珠先出来
		spell.call("_process", DT)
	_ck("成膜阶段水汽已开启", spell.get("_mist") != null
			and bool((spell.get("_mist") as GPUParticles3D).emitting))
	var dn = spell.get("_drops_node")
	_ck("水珠已装配（MultiMesh）", dn != null
			and (dn as MultiMeshInstance3D).multimesh.instance_count == 48,
			"实例数 %s" % str((dn as MultiMeshInstance3D).multimesh.instance_count if dn != null else "无"))
	# ★ 水珠生成点必须在**体表外 drop_gap(1cm)**：用曲面表核对
	var pmat = spell.get("_mat")
	var bad_gap := 0
	var near_top := 0
	var live := 0
	var vels_all: PackedVector3Array = spell.get("_drop_vel")
	var feet_y: float = float(pmat.get_shader_parameter("feet_y"))
	var body_h: float = float(pmat.get_shader_parameter("body_h"))
	var drops: PackedVector3Array = spell.get("_drop_pos")
	var alive: PackedByteArray = spell.get("_drop_alive")
	for i in range(48):
		if alive[i] == 0:                  # 只统计真正存活的（默认位置是 (0,0,0)，别拿它当存活）
			continue
		var lp: Vector3 = drops[i]
		live += 1
		var world := player.global_transform * lp
		var hh := world.y - feet_y
		var off := Vector3(world.x - player.global_position.x, 0.0,
				world.z - player.global_position.z)
		if off.length() < 0.001:
			continue
		# 只看"刚开始下落"的水珠：重力只改 y，水平偏移还是生成时的值；
		# 下落越少，用当前高度查到的体表距离就越接近生成时的值。
		var vel: Vector3 = vels_all[i]
		# 只看"刚生成、几乎还没落下"的水珠：它的当前高度才≈生成高度
		# （最早生成的水珠这会儿可能已经掉了一米多，不能拿它判断"从哪开始"）
		if vel.y > -1.0:
			if hh > body_h * 0.6:
				near_top += 1
		# 排除顶端退化区（帽尖附近曲面半径变化极快，用"当前高度"查表会明显偏）
		if vel.y > -1.0 and hh < body_h * 0.9:
			var expect: float = float(spell.call("_surface_dist", hh, off.normalized())) + 0.01
			if absf(off.length() - expect) > 0.06:
				bad_gap += 1
			pass
	_ck("水珠生成点在**体表外约 1cm**（用真实曲面表核对）", live > 0 and bad_gap == 0,
			"存活 %d，偏差超限 %d 个" % [live, bad_gap])
	# ★ 改成**确定性判据**：原来按"当前高度"判断，而水珠开局是随机错开的，
	#   抽查时刻不同就会翻（弗拉基断言）。直接看发射高度带的下沿：开局应贴着头顶。
	var sweep: float = float(spell.get("_drop_sweep"))
	# 检查前已经推进了 0.5s（drop_sweep_time=1.6 -> sweep≈0.31），所以下沿≈0.69 是**正常值**；
	# 判据是"仍在身体上半段"，而不是"必须等于 1.0"
	_ck("水珠**从头顶开始**往下（发射高度带仍在上半身）", (1.0 - sweep) >= 0.6,
			"高度带下沿 = %.2f（1.0=头顶；检查时已推进 0.5s，理论值 ≈0.69）" % (1.0 - sweep))
	# 盯同一颗存活水珠（重生会换高度，不能拿索引 0 前后比）
	var vels: PackedVector3Array = spell.get("_drop_vel")
	var idx := -1
	for i in range(48):
		if alive[i] == 1 and vels_all[i].y < 0.0:
			idx = i
			break
	_ck("水珠受重力作用（竖直速度朝下）", idx >= 0 and vels_all[idx].y < 0.0,
			"vy=%.3f" % (vels_all[idx].y if idx >= 0 else 0.0))
	var y0: float = drops[idx].y
	_pump(spell, 0.05)
	var y1: float = (spell.get("_drop_pos") as PackedVector3Array)[idx].y
	var still: int = (spell.get("_drop_alive") as PackedByteArray)[idx]
	_ck("水珠在往地面掉落", still == 0 or y1 < y0,
			"%.3f -> %.3f（still=%d）" % [y0, y1, still])
	# ---- 10. 回归：水珠不能"整批整齐下落" ----
	# 同步的判定：统计每帧"落地"的水珠数。整批同步时会有一帧几十颗一起落地；
	# 错开之后应当分摊到多帧，单帧最多只落地少数几颗。
	var peak := 0
	var landed_total := 0
	var prev: PackedByteArray = (spell.get("_drop_alive") as PackedByteArray).duplicate()
	for f in range(120):                   # 2 秒窗口
		spell.call("_process", DT)
		var now: PackedByteArray = spell.get("_drop_alive")
		var n := 0
		for i in range(48):
			if prev[i] == 1 and now[i] == 0:
				n += 1
		if n > peak:
			peak = n
		landed_total += n
		prev = now.duplicate()
	_ck("水珠不是整批整齐下落（单帧落地数被错开）", peak <= 12 and landed_total > 0,
			"2 秒内落地 %d 颗，单帧最多 %d 颗（整批同步时会接近 48）" % [landed_total, peak])
	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

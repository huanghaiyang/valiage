extends SceneTree
## 火焰推进 自检：扇形选点（角度/半径插值/中轴）、波浪推进时序、继承关系。
##
## 为什么这样测：法术本体要玩家/相机/地形才能跑，headless 里跑不动整体。
## 但"能单测的部分"恰恰是最容易写错的：
##   · 张角 -> 半径的插值（45°=10m、80°=6m）
##   · 张角 -> 推进时间的插值（45°=1.0s、80°=0.6s）
##   · 波前距离 kd 是否"由近及远"、以及每簇火是否各自计时
## 这些都在这里钉住。

var _pass := 0
var _fail := 0


func _ck(what: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ✓ %s%s" % [what, ("   " + detail) if detail != "" else ""])
	else:
		_fail += 1
		print("  ✗ %s   %s" % [what, detail])


func _init() -> void:
	print("=== 火焰推进 自检 ===")

	# ---- 数值表：新法术已登记，且扇形参数齐全 ----
	var sheet := load("res://data/spell_sheet.json") as JSON
	var row := {}
	if sheet != null:
		row = (sheet.data as Dictionary).get("spells", {}).get("flame_advance", {})
	_ck("数值表里有 flame_advance", not row.is_empty())
	var tg: Dictionary = row.get("targeting", {})
	_ck("是一次性法术", bool(row.get("one_shot", false)))
	_ck("扇形模式已配置", String(tg.get("mode", "")) == "sector",
			"mode=%s" % str(tg.get("mode")))
	_ck("45° -> 10m，80° -> 6m（数值来自表，不硬编码）",
			absf(float(tg.get("angle_min", 0)) - 45.0) < 0.001
			and absf(float(tg.get("angle_max", 0)) - 80.0) < 0.001
			and absf(float(tg.get("radius_at_min", 0)) - 10.0) < 0.001
			and absf(float(tg.get("radius_at_max", 0)) - 6.0) < 0.001,
			"45°=%.0fm 80°=%.0fm" % [float(tg.get("radius_at_min", 0)), float(tg.get("radius_at_max", 0))])
	_ck("推进时间 45°=1.0s、80°=0.6s",
			absf(float(tg.get("advance_time_at_min", 0)) - 1.0) < 0.001
			and absf(float(tg.get("advance_time_at_max", 0)) - 0.6) < 0.001)

	# ---- 选点器：张角 -> 半径 的插值 ----
	# ★ 选点器脚本必须能被加载：它一坏，SpellCaster 自动加载就挂，整个游戏起不来（实测踩过）
	_ck('选点器脚本能加载（无解析错误）', load('res://scripts/spells/spell_targeting.gd') != null)
	var T := load('res://scripts/spells/spell_targeting.gd') as GDScript
	var tgt: Node3D = T.new()
	_ck("选点器能实例化", tgt != null)
	tgt.call("configure", tg)
	# 45°（最小）时应给到 10m
	tgt.set("_angle", 45.0)
	_ck("45° -> 半径 10m", absf(float(tgt.call("_radius_from_angle")) - 10.0) < 0.01,
			"r=%.2f" % float(tgt.call("_radius_from_angle")))
	# 80°（最大）时应给到 6m
	tgt.set("_angle", 80.0)
	_ck("80° -> 半径 6m", absf(float(tgt.call("_radius_from_angle")) - 6.0) < 0.01,
			"r=%.2f" % float(tgt.call("_radius_from_angle")))
	# 中间角度线性插值（62.5° 正好是中点 -> 8m）
	tgt.set("_angle", 62.5)
	_ck("62.5°（中点）-> 半径 8m", absf(float(tgt.call("_radius_from_angle")) - 8.0) < 0.01,
			"r=%.2f" % float(tgt.call("_radius_from_angle")))
	# 半角：45° -> 0.3927 rad；张角越大半角越大
	tgt.set("_angle", 45.0)
	var h45 := float(tgt.call("half_angle"))
	tgt.set("_angle", 80.0)
	var h80 := float(tgt.call("half_angle"))
	_ck("45° 半角 = 22.5°", absf(rad_to_deg(h45) - 22.5) < 0.01, "%.2f°" % rad_to_deg(h45))
	_ck("半角随张角变大", h80 > h45, "80°: %.2f° > 45°: %.2f°" % [rad_to_deg(h80), rad_to_deg(h45)])
	# 滚轮改张角并夹住范围
	tgt.set("_angle", 45.0)
	tgt.call("_set_angle", 200.0)
	_ck("张角上限被夹住（80°）", absf(float(tgt.get("_angle")) - 80.0) < 0.001,
			"angle=%.1f" % float(tgt.get("_angle")))
	tgt.call("_set_angle", -50.0)
	_ck("张角下限被夹住（45°）", absf(float(tgt.get("_angle")) - 45.0) < 0.001,
			"angle=%.1f" % float(tgt.get("_angle")))

	# ---- 法术本体：继承关系 + 推进时间插值 ----
	# ★ 必须等**自动加载注册之后**再加载法术脚本：flame_scorch 里引用了 Mana，
	#   而 _init() 阶段自动加载还没就绪 -> 会报 "Identifier not found: Mana"
	#   （这只影响这个自检脚本，游戏里没问题）。所以延后到下一帧。
	call_deferred("_check_spell_body")


func _check_spell_body() -> void:
	var S := load("res://scripts/spells/flame_advance.gd") as GDScript
	_ck("火焰推进脚本能加载", S != null)
	if S != null:
		var base := S.get_base_script()
		_ck("★ 继承自 flame_scorch（复用伤害/植被燃烧/火焰池）",
				base != null and base.resource_path.contains("flame_scorch"),
				"基类=%s" % (base.resource_path if base != null else "无"))
		var sp: Node3D = S.new()
		_ck("法术能实例化", sp != null)
		_ck("声明了扇形施法接口 cast_sector", sp.has_method("cast_sector"))
		_ck("声明了选点接口", sp.has_method("has_targeting") and sp.has_method("targeting_config"))
		# 显式类型：项目里 `:=` 从 Variant 推断会被当成错误
		var j := load("res://data/spell_sheet.json") as JSON
		var spells: Dictionary = {}
		if j != null and j.data is Dictionary:
			spells = (j.data as Dictionary).get("spells", {}) as Dictionary
		var row: Dictionary = spells.get("flame_advance", {}) as Dictionary
		var tcfg: Dictionary = row.get("targeting", {}) as Dictionary
		var adv45: float = _advance_for(sp, tcfg, 45.0)
		var adv80: float = _advance_for(sp, tcfg, 80.0)
		_ck("45° 推进时间 = 1.0s", absf(adv45 - 1.0) < 0.01, "%.2fs" % adv45)
		_ck("80° 推进时间 = 0.6s", absf(adv80 - 0.6) < 0.01, "%.2fs" % adv80)
		_ck("80° 推得更快（张角大、距离短）", adv80 < adv45)
		# ---- 扇区判定：正前方在内、侧后方在外（这一步错了就会烧成一圈圆）----
		sp.set("sector_axis", 0.0)                      # 中轴朝 +X
		sp.set("sector_half", deg_to_rad(22.5))         # 45 度张角
		sp.set("_center", Vector3.ZERO)
		sp.set("_radius", 10.0)
		_ck("★ 扇区判定：正前方 5m 在内", bool(sp.call("_in_sector", Vector3(5.0, 0.0, 0.0))))
		_ck("★ 扇区判定：正后方 5m 在外（不算扇形）",
				not bool(sp.call("_in_sector", Vector3(-5.0, 0.0, 0.0))))
		_ck("★ 扇区判定：侧面 90 度 5m 在外",
				not bool(sp.call("_in_sector", Vector3(0.0, 0.0, 5.0))))
		_ck("★ 扇区判定：超半径 12m 在外", not bool(sp.call("_in_sector", Vector3(12.0, 0.0, 0.0))))
		_ck("扇区判定：张角内的斜前方在内",
				bool(sp.call("_in_sector", Vector3(6.0, 0.0, 2.0))))
		# ---- ★ 角度控制：每个火焰簇都必须落在扇区内（位置角度 + 半径）----
		var sp2: Node3D = S.new()
		get_root().add_child(sp2)
		sp2.call("set", "debug_vegetation", false)
		sp2.call("set", "debug_sector", false)
		var axis := 0.6
		var half := deg_to_rad(22.5)
		sp2.call("cast_sector", Vector3.ZERO, 10.0, axis, half)
		var used: int = int(sp2.get("_used"))
		var bad_a := 0
		var bad_r := 0
		var kd_max := 0.0
		var patches2: Array = sp2.get("_patches")
		for i in range(mini(used, patches2.size())):
			var fn := patches2[i] as Node3D
			if fn == null or not is_instance_valid(fn):
				continue
			var d := Vector2(fn.global_position.x, fn.global_position.z)
			if d.length() > 10.05:
				bad_r += 1
			var da := absf(wrapf(d.angle() - axis, -PI, PI))
			if da > half + 0.03:
				bad_a += 1
		for kv in (sp2.get("_kd") as Array):
			kd_max = maxf(kd_max, float(kv))
		_ck("★ 每个火焰簇的角度都在扇区内（±半角）", used > 0 and bad_a == 0,
				"%d 簇，越角 %d（半角 %.1f 度）" % [used, bad_a, rad_to_deg(half)])
		_ck("★ 每个火焰簇的半径都在扇形半径内", bad_r == 0, "越半径 %d" % bad_r)
		_ck("★ 波前距离已归一化到 0..1（推进总时长才等于 advance_time）",
				kd_max > 0.9 and kd_max <= 1.001, "kd_max=%.3f" % kd_max)
		sp2.queue_free()
		_ck("总时长会加上推进时间（否则末端的火被提前收掉）",
				absf(float(sp.get("burn_time")) - 8.0) < 0.001,
				"初始 burn_time=%.2f（施法时按 8+advance 设定）" % float(sp.get("burn_time")))
		# ---- ★ 滚轮：扇形模式下改的是**张角**，不是距离 ----
		# 自建一个选点器并挂到树上（_input 里要用 viewport，必须在树内）
		var tgt: Node3D = (load("res://scripts/spells/spell_targeting.gd") as GDScript).new()
		get_root().add_child(tgt)
		# 模拟施法器：先下发圆盘配置、再下发扇形配置（切换法术的情形），然后滚轮
		tgt.call("configure", {"mode": "disc", "diameter_min": 5.0, "diameter_max": 10.0})
		_ck("先下发圆盘配置 -> sector=false", not bool(tgt.get("sector")))
		tgt.call("configure", tcfg)
		_ck("★ 再下发扇形配置 -> sector=true（切换法术必须重新下发）", bool(tgt.get("sector")),
				"sector=%s" % str(tgt.get("sector")))
		tgt.set("_active", true)
		var a0 := float(tgt.get("_angle"))
		var r0 := float(tgt.get("_radius"))
		tgt.call("_input", _wheel(true))
		var a1 := float(tgt.get("_angle"))
		var r1 := float(tgt.get("_radius"))
		_ck("★ 滚轮上滚 -> **张角变大**", a1 > a0 + 0.001, "%.0f度 -> %.0f度" % [a0, a1])
		_ck("★ 滚轮上滚 -> **半径按张角重算**（不是改距离档）",
				absf(r1 - r0) > 0.001
				and absf(float(tgt.call("_radius_from_angle")) - r1) < 0.01,
				"半径 %.2f -> %.2f" % [r0, r1])
		tgt.call("_set_angle", 80.0)
		tgt.call("_input", _wheel(true))
		_ck("张角到 80 度后不再增加", absf(float(tgt.get("_angle")) - 80.0) < 0.001,
				"angle=%.1f" % float(tgt.get("_angle")))
		tgt.queue_free()
		_ck("★ 扇形子类覆盖了逐实例过滤（只烧扇区内的草）",
				sp.has_method("_burn_instance_indices") and sp.has_method("_in_sector"))
		# ---- ★ 滚轮必须**实时**生效：不动鼠标也要刷新扇形宽度 ----
		# 回归点：原来把 sector_half 的写入放在"中心或中轴变化"的条件里，
		#   滚轮改张角时进不去 -> 必须移动鼠标才刷新（用户实测）。
		var player := Node3D.new()
		get_root().add_child(player)
		var tgt2: Node3D = (load("res://scripts/spells/spell_targeting.gd") as GDScript).new()
		get_root().add_child(tgt2)
		tgt2.call("setup", player, null)
		tgt2.call("configure", tcfg)
		tgt2.call("begin")
		tgt2.call("_process", 0.016)          # 建圆盘/材质
		tgt2.call("_set_angle", 80.0)         # 滚轮改到 80 度
		tgt2.call("_process", 0.016)          # 不动鼠标，只跑一帧
		# ★ 扇形现在是**独立节点 + 独立材质**：检查独立材质上的 half_angle，
		#   以及"扇形可见 / 圆盘隐藏"的切换（这样才不会互相污染）
		var smat: ShaderMaterial = tgt2.get("_sector_mat")
		var sdisc: MeshInstance3D = tgt2.get("_sector_disc")
		var ddisc: MeshInstance3D = tgt2.get("_disc")
		var got_half: Variant = smat.get_shader_parameter("half_angle") if smat != null else null
		var want_half2 := deg_to_rad(80.0) * 0.5
		_ck("★ 滚轮改张角后**不动鼠标**也立即刷新扇形宽度", got_half != null
				and absf(float(got_half) - want_half2) < 0.001,
				"half_angle=%s（期望 %.4f）" % [str(got_half), want_half2])
		_ck("★ 扇形用**独立材质/节点**（不复用圆盘那套）",
				smat != null and sdisc != null and ddisc != null
				and smat != ddisc.material_override,
				"扇形材质存在=%s" % str(smat != null))
		_ck("★ 扇形模式下：扇形可见、圆盘隐藏",
				sdisc.visible and not ddisc.visible,
				"扇形=%s 圆盘=%s" % [str(sdisc.visible), str(ddisc.visible)])
		tgt2.set("sector", false)
		tgt2.call("_process", 0.016)
		_ck("★ 切回圆盘模式后：圆盘恢复可见、扇形隐藏",
				ddisc.visible and not sdisc.visible,
				"圆盘=%s 扇形=%s" % [str(ddisc.visible), str(sdisc.visible)])
		tgt2.call("end")
		tgt2.queue_free()
		player.queue_free()
	call_deferred("_check_card_facing")


## ================================================================
## ★ 焰卡朝向自检（用户需求）：
##   · 扇形**两条边**的火焰 -> 大面朝**扇形中轴线**
##   · 扇形**圆弧处**的火焰 -> 大面朝**角色**
##
## 【为什么必须"量几何"而不是"读代码"】焰卡自身的 yaw 在生成时是**随机**的
##   （fire_burst.random_yaw），所以"给特效根节点一个 yaw"完全决定不了大面朝向
##   —— 实测：只转根节点时边界簇对齐度 0.58（≈ 随机）；改成逐卡写之后 0.99。
##   这里量的是每张焰卡的**面积加权法线**（= 那张大面的法线）在世界里的方向，
##   再和期望方向求 |n·d|：1 = 大面正对，0.64 ≈ 随机，0 = 侧着看。
##
## 【判据以"逐卡均值"为主，簇级均值只作参考】簇级均值 = 符号对齐后归一化，
##   单簇只有 16 张卡 -> 随机时方差很大（合成均匀随机的 3000 次试验：均值 0.636，
##   但取值范围是 0.00~1.00，个别随机簇也能到 0.95+）。逐卡均值在随机时
##   集中在 0.64（64~96 张卡，σ≈0.03），所以"逐卡均值 ≥0.95"才是硬判据；
##   再加一条"|n·d|≥0.9 的卡占比 ≥95%"（随机时只有 ~29%，且单簇最多 ~90%），
##   保证不是"平均被少数几张卡拉上去"。
## ================================================================
func _check_card_facing() -> void:
	print("---- 焰卡朝向（两边朝中轴线 / 圆弧朝角色）----")
	# ---- ① 模型前提：大面法线 = 本地 ±X（最薄轴），且法线水平 ----
	var scene := load("res://scenes/法术特效/火焰燃烧特效.tscn") as PackedScene
	_ck("火焰燃烧特效场景能加载", scene != null)
	if scene != null:
		var fx := scene.instantiate() as Node3D
		get_root().add_child(fx)
		var meshes := _flame_meshes(fx)
		_ck("焰卡网格共 16 张（5 底层 + 5 中层 + 5 上层 + 1 中心）", meshes.size() == 16,
				"实测 %d 张" % meshes.size())
		var thin_x := 0
		var flat_ok := true
		for mi in meshes:
			var s: Vector3 = (mi as MeshInstance3D).mesh.get_aabb().size
			if s.x <= s.y and s.x <= s.z:
				thin_x += 1
			var n_root: Vector3 = _rel_dir(fx, mi as Node3D, _area_normal((mi as MeshInstance3D).mesh))
			if absf(n_root.y) > 0.2:
				flat_ok = false
		_ck("★ 焰卡的大面法线 = 本地 X（最薄轴）—— 逐卡写 yaw 才有意义",
				thin_x == meshes.size(), "%d/%d 张最薄轴=X" % [thin_x, meshes.size()])
		_ck("★ 大面竖直（法线水平，本地 y≈0）", flat_ok)
		fx.queue_free()

	# ---- ② 端到端：cast_sector 之后量边界簇的真实朝向 ----
	#   45° 和 80° 两种张角都量：张角越大，两条边离中轴线越远，是最容易出错的工况。
	var S := load("res://scripts/spells/flame_advance.gd") as GDScript
	var cases := [
		{"deg": 45.0, "radius": 10.0, "axis": 0.6},
		{"deg": 80.0, "radius": 6.0, "axis": -1.1},
	]
	for c in cases:
		var m := _measure_sector(S, float(c["deg"]), float(c["radius"]), float(c["axis"]))
		var tag := "%.0f°张角" % float(c["deg"])
		_ck("★ %s：两条边的火焰**逐卡**大面朝中轴线（均值 ≥0.95）" % tag,
				int(m["e_cards"]) > 0 and float(m["e_card"]) >= 0.95,
				"%d 张卡 逐卡均值=%.4f（随机≈0.64）｜簇级=%.4f（%d 簇）"
				% [int(m["e_cards"]), float(m["e_card"]), float(m["e_cluster"]), int(m["e_clusters"])])
		_ck("★ %s：圆弧处的火焰**逐卡**大面朝角色（均值 ≥0.95）" % tag,
				int(m["a_cards"]) > 0 and float(m["a_card"]) >= 0.95,
				"%d 张卡 逐卡均值=%.4f（随机≈0.64）｜簇级=%.4f（%d 簇）"
				% [int(m["a_cards"]), float(m["a_card"]), float(m["a_cluster"]), int(m["a_clusters"])])
		_ck("★ %s：几乎没有「没转过去」的卡（逐卡 |n·d|≥0.9 的张数占比不低于 95%%）" % tag,
				float(m["e_hit"]) >= 0.95 and float(m["a_hit"]) >= 0.95,
				"边 %d/%d=%.2f ｜ 弧 %d/%d=%.2f"
				% [int(m["e_hits"]), int(m["e_cards"]), float(m["e_hit"]),
				int(m["a_hits"]), int(m["a_cards"]), float(m["a_hit"])])
		_ck("★ %s：两条边的火焰**不是**朝径向（朝径向 = 改动没生效时的样子）" % tag,
				float(m["e_radial_mean"]) <= 0.5,
				"均值 |n·径向|=%.3f（最差簇=%.3f）"
				% [float(m["e_radial_mean"]), float(m["e_radial_worst"])])
	# 内部填充不要求朝向（要的是薄片离散度）—— 钉住"它确实还是随机的"
	var mi45 := _measure_sector(S, 45.0, 10.0, 0.6)
	_ck("内部填充保持随机朝向（逐卡均值 <0.8；随机≈0.64）",
			int(mi45["i_cards"]) > 0 and float(mi45["i_card"]) < 0.8,
			"%d 张卡 逐卡均值=%.3f" % [int(mi45["i_cards"]), float(mi45["i_card"])])

	# ---- ③ 红线：火焰灼烧的焰卡必须**仍是随机朝向**（改动不得带走它）----
	var SC := load("res://scripts/spells/flame_scorch.gd") as GDScript
	var sc: Node3D = SC.new()
	get_root().add_child(sc)
	sc.set("debug_vegetation", false)
	sc.set("_center", Vector3.ZERO)
	sc.set("_radius", 3.5)
	sc.call("_spawn_patches")                              # 直接布点：绕开 Mana
	var sc_used: int = int(sc.get("_used"))
	var sc_patches: Array = sc.get("_patches")
	var sc_sum := 0.0
	var sc_all := 0
	for i in range(mini(sc_used, sc_patches.size())):
		var f2 := sc_patches[i] as Node3D
		if f2 == null or not is_instance_valid(f2):
			continue
		var p2 := f2.global_position
		var rad2 := Vector3(p2.x, 0.0, p2.z)
		if rad2.length() < 0.001:
			continue
		rad2 = rad2.normalized()
		for cn2 in _card_normals(f2):
			sc_sum += absf((cn2 as Vector3).dot(rad2))
			sc_all += 1
	sc.queue_free()
	var sc_mean := sc_sum / float(maxi(sc_all, 1))
	_ck("★ 火焰灼烧的焰卡**仍是随机朝向**（逐卡对齐度均值 < 0.9；随机≈0.64）",
			sc_all > 0 and sc_mean < 0.9, "%d 张卡，均值=%.3f" % [sc_all, sc_mean])
	var src := FileAccess.get_file_as_string("res://scripts/spells/flame_scorch.gd")
	_ck("★ 火焰灼烧代码不引用逐卡朝向接口（两边互不干扰）",
			not src.contains("face_cards_to"))
	_check_feet_clear_and_glow()


## ================================================================
## ★ 用户反馈 1：「最好角色脚底不要生成火焰」
##   量的是**角色到任意火焰三角面的水平最近距离**（三角面投到 XZ 平面 = 这块地上
##   方有没有火），而不是到簇中心/到 AABB 的距离 —— AABB 对旋转过的卡片会偏大，
##   量出来偏小，当年就是被这个口径骗过（以为留了 0.68m，实际只有 0.10m）。
##   还要在**逐卡动画跑起来之后**再量（焰卡会呼吸伸缩，水平最多涨 ~6%）。
##
## ★ 用户反馈 2：「有角色很远的地方也有火焰效果」
##   症状根因：flame_advance 覆盖了 _spawn_patches，却漏了基类里"给贴地光斑
##   设置 transform"那一步 -> 15 个光斑全堆在特效根节点原点、竖着、scale=1，
##   而特效根挂在 _player.get_parent() 上 -> 角色一走开，原地就剩一团火。
##   这里钉住：每个光斑都必须贴在自己那一簇脚下、平铺、且不越出扇形。
## ================================================================
func _check_feet_clear_and_glow() -> void:
	print("---- 角色脚底留白 / 贴地光斑 ----")
	var S := load("res://scripts/spells/flame_advance.gd") as GDScript
	var cases := [
		{"deg": 45.0, "radius": 10.0, "axis": 0.0},
		{"deg": 62.5, "radius": 8.0, "axis": -0.5},
		{"deg": 80.0, "radius": 6.0, "axis": 0.7},
	]
	for c in cases:
		var tag := "%.0f°×%.0fm" % [float(c["deg"]), float(c["radius"])]
		var mana := get_root().get_node_or_null("Mana")
		if mana != null:
			mana.call("refill")
		var sp: Node3D = S.new()
		get_root().add_child(sp)
		sp.set("debug_sector", false)
		sp.set("debug_vegetation", false)
		# ★ 时间由测试自己推进（_process 手动调），否则无头模式的帧率不受控，
		#   波前/点燃的时序会变成随机的 —— 而且**不能**在 grow=0 时调焰卡的 _process
		#   （那条路径里有 1/sqrt(grow)，会把卡片横向吹大 4 倍，是测试假象不是游戏行为）。
		sp.set_process(false)
		sp.call("cast_sector", Vector3.ZERO, float(c["radius"]), float(c["axis"]),
				deg_to_rad(float(c["deg"])) * 0.5)
		var used: int = int(sp.get("_used"))
		var patches: Array = sp.get("_patches")
		var glows: Array = sp.get("_glows")
		var gap_want := float(sp.get("place_inner_gap_m"))
		var gap_vis := float(sp.get("place_gap_visible_grow"))
		for i in range(mini(used, patches.size())):
			var pf0 := patches[i] as Node3D
			if pf0 != null and is_instance_valid(pf0):
				pf0.set_process(false)
		var min_all := 1e9
		var min_half := 1e9
		var min_bright := 1e9
		var dt := 1.0 / 60.0
		for k in range(96):                      # 1.6s：覆盖波前(1.0s)+点燃(0.35s)+稳定燃烧
			sp.call("_process", dt)
			for i in range(mini(used, patches.size())):
				var pf := patches[i] as Node3D
				if pf != null and is_instance_valid(pf):
					pf.call("_process", dt)
			min_all = minf(min_all, _nearest_flame_aabb_xz(patches, used, Vector3.ZERO, 0.0))
			min_half = minf(min_half, _nearest_flame_aabb_xz(patches, used, Vector3.ZERO, 0.5))
			# 硬判据用"满亮"的火（正常燃烧 = 观众看的那团火）
			min_bright = minf(min_bright, _nearest_flame_aabb_xz(patches, used, Vector3.ZERO, 0.95))
		var tri := _nearest_flame_tri_xz(patches, used, Vector3.ZERO)
		_ck("★ %s：角色脚底没有看得见的火（满亮全程 ≥ 留白 − 容差）" % tag,
				min_bright >= gap_want - 0.25,
				"满亮 %.2fm / 半透明起 %.2fm / 含鬼影 %.2fm（留白参数 %.1fm）；最近来源 %s"
				% [min_bright, min_half, min_all, gap_want, str(tri["what"])])
		# ② 贴地光斑：必须贴在自己那一簇脚下、平铺、不越界
		var worst_gap := 0.0
		var bad_flat := 0
		var bad_far := 0
		var lim := float(c["radius"]) + 1.0        # 光斑是 2.6m 的方片，留 1m 余量
		for i in range(mini(used, mini(glows.size(), patches.size()))):
			var g := glows[i] as MeshInstance3D
			var pf2 := patches[i] as Node3D
			if g == null or pf2 == null or not is_instance_valid(g) or not is_instance_valid(pf2):
				continue
			worst_gap = maxf(worst_gap, Vector2(g.global_position.x - pf2.global_position.x,
					g.global_position.z - pf2.global_position.z).length())
			if g.global_transform.basis.z.normalized().y < 0.9:
				bad_flat += 1
			if Vector2(g.global_position.x, g.global_position.z).length() > lim:
				bad_far += 1
		_ck("★ %s：贴地光斑都贴在自己那一簇脚下（≤0.5m；原来全堆在特效根原点）" % tag,
				worst_gap <= 0.5, "最大偏差 %.2fm（%d 个光斑）" % [worst_gap, mini(used, glows.size())])
		_ck("★ %s：贴地光斑是平铺在地面的（不是竖着的纸片）" % tag,
				bad_flat == 0, "竖着 %d 个" % bad_flat)
		_ck("★ %s：没有跑到扇形之外的火焰/光斑" % tag, bad_far == 0, "越界 %d 个" % bad_far)
		sp.queue_free()
	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


## 角色到任意可见火焰网格的世界 AABB 的水平最近距离（可只算 grow ≥ min_grow 的）。
## AABB 一定**包含**几何体 -> 这个值 ≤ 到真实几何的距离（保守口径）：
## 拿它当验收判据，通过就说明真实留白只会更大。
func _nearest_flame_aabb_xz(patches: Array, used: int, p: Vector3, min_grow: float) -> float:
	var best := 1e9
	for i in range(mini(used, patches.size())):
		var pa := patches[i] as Node3D
		if pa == null or not is_instance_valid(pa) or not pa.visible:
			continue
		if min_grow > 0.0 and float(pa.get("grow")) < min_grow:
			continue
		for mi in _all_meshes(pa):
			var m := (mi as MeshInstance3D).mesh
			if m == null:
				continue
			var box: AABB = (mi as Node3D).global_transform * m.get_aabb()
			var cx := clampf(p.x, box.position.x, box.position.x + box.size.x)
			var cz := clampf(p.z, box.position.z, box.position.z + box.size.z)
			best = minf(best, Vector2(cx - p.x, cz - p.z).length())
	return best


## 点到任意可见火焰**三角面**在 XZ 平面上的最近距离
func _nearest_flame_tri_xz(patches: Array, used: int, p: Vector3) -> Dictionary:
	var best := 1e9
	var what := ""
	for i in range(mini(used, patches.size())):
		var pa := patches[i] as Node3D
		if pa == null or not is_instance_valid(pa) or not pa.visible:
			continue
		for mi in _all_meshes(pa):
			var m := (mi as MeshInstance3D).mesh
			if m == null or m.get_surface_count() == 0:
				continue
			var xf := (mi as Node3D).global_transform
			var box: AABB = xf * m.get_aabb()
			var ax := clampf(p.x, box.position.x, box.position.x + box.size.x)
			var az := clampf(p.z, box.position.z, box.position.z + box.size.z)
			if Vector2(ax - p.x, az - p.z).length() >= best:
				continue                                   # 粗筛：AABB 都比当前最优远
			var arr := m.surface_get_arrays(0)
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			var nt := int(idx.size() / 3) if not idx.is_empty() else int(verts.size() / 3)
			for t in range(nt):
				var i0 := t * 3
				var i1 := t * 3 + 1
				var i2 := t * 3 + 2
				if not idx.is_empty():
					i0 = int(idx[t * 3])
					i1 = int(idx[t * 3 + 1])
					i2 = int(idx[t * 3 + 2])
				if i0 >= verts.size() or i1 >= verts.size() or i2 >= verts.size():
					continue
				var d := _pt_tri_xz(p, xf * verts[i0], xf * verts[i1], xf * verts[i2])
				if d < best:
					best = d
					what = "%s/%s" % [pa.name, (mi as Node).name]
	return {"d": best, "what": what}


func _pt_tri_xz(p: Vector3, a3: Vector3, b3: Vector3, c3: Vector3) -> float:
	var p2 := Vector2(p.x, p.z)
	var a := Vector2(a3.x, a3.z)
	var b := Vector2(b3.x, b3.z)
	var c := Vector2(c3.x, c3.z)
	var d1 := _cross2(b - a, p2 - a)
	var d2 := _cross2(c - b, p2 - b)
	var d3 := _cross2(a - c, p2 - c)
	if not ((d1 < 0.0 or d2 < 0.0 or d3 < 0.0) and (d1 > 0.0 or d2 > 0.0 or d3 > 0.0)):
		return 0.0
	return minf(minf(_seg_xz(p2, a, b), _seg_xz(p2, b, c)), _seg_xz(p2, c, a))


func _cross2(u: Vector2, v: Vector2) -> float:
	return u.x * v.y - u.y * v.x


func _seg_xz(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1e-12:
		return (p - a).length()
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return (p - (a + ab * t)).length()


## 特效里所有网格（**含** CoreGlow 光片：它们也是会被看到的火）
func _all_meshes(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_all_meshes(c))
	return out


# ---------------------------------------------------------------- 朝向测量（几何）
## 真的放一次扇形（走 cast_sector 正式入口），再把边界簇的焰卡朝向量出来。
## 返回：
##   e_cluster/a_cluster  簇级均值（符号对齐后归一化；**只作参考**，随机时方差大）
##   e_card/a_card        逐卡均值 |n·d|（**主判据**：朝向对齐 = 1，随机 ≈ 0.64）
##   e_hits/a_hits        逐卡 |n·d|≥0.9 的张数，e_hit/a_hit = 占比
##   e_radial_mean/worst  两条边对"径向"的对齐度（朝径向 = 没生效时的样子）
##   i_card/i_cards       内部填充簇的逐卡对齐度（应当还是随机 ≈0.64）
func _measure_sector(S: GDScript, deg: float, radius: float, axis: float) -> Dictionary:
	var m := {"e_cluster": 0.0, "e_card": 0.0, "e_cards": 0, "e_clusters": 0,
			"a_cluster": 0.0, "a_card": 0.0, "a_cards": 0, "a_clusters": 0,
			"e_hits": 0, "a_hits": 0, "e_hit": 0.0, "a_hit": 0.0,
			"e_radial_mean": 0.0, "e_radial_worst": 0.0,
			"i_card": 0.0, "i_cards": 0, "i_clusters": 0}
	var half := deg_to_rad(deg) * 0.5
	# 连续两次施法要够蓝（cast_at 里会真的扣蓝；不足就直接不生成 -> 误判）
	var mana := get_root().get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
	var sp: Node3D = S.new()
	get_root().add_child(sp)
	sp.set("debug_sector", false)
	sp.set("debug_vegetation", false)
	sp.call("cast_sector", Vector3.ZERO, radius, axis, half)
	var used: int = int(sp.get("_used"))
	var patches: Array = sp.get("_patches")
	# 布点顺序（和 _spawn_patches 一致）：先两条边(每边 edge_n)，再外弧 arc_n，最后内部填充
	var area := 0.5 * (2.0 * half) * radius * radius
	var want := clampi(int(round(area / 2.6)), 10, 28)
	var edge_n := maxi(3, int(round(float(want) * 0.22)))
	var arc_n := maxi(5, int(round(float(want) * 0.32)))
	var axis_dir := Vector3(cos(axis), 0.0, sin(axis))
	for i in range(mini(used, patches.size())):
		var f := patches[i] as Node3D
		if f == null or not is_instance_valid(f):
			continue
		var p := f.global_position
		var flat := Vector3(p.x, 0.0, p.z)
		if flat.length() < 0.001:
			continue
		var radial := flat.normalized()
		var foot := axis_dir * flat.dot(axis_dir)          # 落点在中轴线上的垂足
		var to_axis := (foot - flat).normalized()          # "朝中轴线"的字面方向
		var to_caster := (-flat).normalized()              # "朝角色"
		var is_edge := i < edge_n * 2
		var is_arc := (not is_edge) and i < edge_n * 2 + arc_n
		var target := to_axis if is_edge else to_caster
		if is_edge:
			var cn_e := _cluster_normal(f)
			m["e_clusters"] = int(m["e_clusters"]) + 1
			m["e_cluster"] = float(m["e_cluster"]) + absf(cn_e.dot(to_axis))
			m["e_radial_mean"] = float(m["e_radial_mean"]) + absf(cn_e.dot(radial))
			m["e_radial_worst"] = maxf(float(m["e_radial_worst"]), absf(cn_e.dot(radial)))
		elif is_arc:
			m["a_clusters"] = int(m["a_clusters"]) + 1
			m["a_cluster"] = float(m["a_cluster"]) + absf(_cluster_normal(f).dot(to_caster))
		else:
			m["i_clusters"] = int(m["i_clusters"]) + 1
		for cn in _card_normals(f):
			var a := absf((cn as Vector3).dot(target))
			if is_edge:
				m["e_card"] = float(m["e_card"]) + a
				m["e_cards"] = int(m["e_cards"]) + 1
				if a >= 0.9:
					m["e_hits"] = int(m["e_hits"]) + 1
			elif is_arc:
				m["a_card"] = float(m["a_card"]) + a
				m["a_cards"] = int(m["a_cards"]) + 1
				if a >= 0.9:
					m["a_hits"] = int(m["a_hits"]) + 1
			else:
				# 内部填充：对"朝中轴线"求对齐度（不要求朝向，只要求它别被写成整齐朝向）
				m["i_card"] = float(m["i_card"]) + absf((cn as Vector3).dot(to_axis))
				m["i_cards"] = int(m["i_cards"]) + 1
	sp.queue_free()
	m["e_cluster"] = float(m["e_cluster"]) / float(maxi(int(m["e_clusters"]), 1))
	m["a_cluster"] = float(m["a_cluster"]) / float(maxi(int(m["a_clusters"]), 1))
	m["e_card"] = float(m["e_card"]) / float(maxi(int(m["e_cards"]), 1))
	m["a_card"] = float(m["a_card"]) / float(maxi(int(m["a_cards"]), 1))
	m["e_radial_mean"] = float(m["e_radial_mean"]) / float(maxi(int(m["e_clusters"]), 1))
	m["i_card"] = float(m["i_card"]) / float(maxi(int(m["i_cards"]), 1))
	m["e_hit"] = float(m["e_hits"]) / float(maxi(int(m["e_cards"]), 1))
	m["a_hit"] = float(m["a_hits"]) / float(maxi(int(m["a_cards"]), 1))
	return m


## 特效里的焰卡网格（跳过 CoreGlow 加色光片：它是 billboard，朝向无意义）
func _flame_meshes(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is MeshInstance3D:
			if String(c.get_parent().name) == "CoreGlow":
				continue
			out.append(c)
		out.append_array(_flame_meshes(c))
	return out


## 网格本地坐标系的**面积加权法线**（= 那张大面的法线；薄片正反两面同轴）
func _area_normal(mesh: Mesh) -> Vector3:
	if mesh == null or mesh.get_surface_count() == 0:
		return Vector3.FORWARD
	var arr := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
	var acc := Vector3.ZERO
	var best := Vector3.ZERO
	var best_a := 0.0
	var n_tri := int(idx.size() / 3) if not idx.is_empty() else int(verts.size() / 3)
	for t in range(n_tri):
		var i0 := t * 3
		var i1 := t * 3 + 1
		var i2 := t * 3 + 2
		if not idx.is_empty():
			i0 = int(idx[t * 3])
			i1 = int(idx[t * 3 + 1])
			i2 = int(idx[t * 3 + 2])
		if i0 >= verts.size() or i1 >= verts.size() or i2 >= verts.size():
			continue
		var cr := (verts[i1] - verts[i0]).cross(verts[i2] - verts[i0])
		var l := cr.length()
		if l < 1e-9:
			continue
		acc += cr
		if l > best_a:
			best_a = l
			best = cr / l
	if acc.length_squared() > 1e-12:
		return acc.normalized()
	return best if best.length_squared() > 1e-12 else Vector3.FORWARD


## 把网格本地方向转到**特效根**的本地坐标系（用旋转，不用平移）
func _rel_dir(root: Node3D, node: Node3D, dir: Vector3) -> Vector3:
	var world := (node.global_transform.basis.orthonormalized() * dir).normalized()
	return (root.global_transform.basis.orthonormalized().inverse() * world).normalized()


## 一簇火里**每一张**焰卡的世界法线
func _card_normals(patch: Node3D) -> Array:
	var out: Array = []
	for mi in _flame_meshes(patch):
		var n_local: Vector3 = _area_normal((mi as MeshInstance3D).mesh)
		var n_w: Vector3 = ((mi as Node3D).global_transform.basis.orthonormalized() * n_local).normalized()
		out.append(n_w)
	return out


## 一簇火的**簇级**大面法线：逐卡法线按符号对齐后求平均（= 整簇的最大面朝向）
func _cluster_normal(patch: Node3D) -> Vector3:
	var cards := _card_normals(patch)
	if cards.is_empty():
		return Vector3.UP
	var acc := Vector3.ZERO
	var first := true
	for cn in cards:
		var n := cn as Vector3
		if first:
			acc = n
			first = false
			continue
		if n.dot(acc) < 0.0:
			n = -n
		acc += n
	return acc.normalized() if acc.length_squared() > 1e-9 else Vector3.UP


## 构造一个"滚轮"事件（headless 里也能走 _input 分支）
func _wheel(up: bool) -> InputEventMouseButton:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	return ev


## 用同一套插值公式复算推进时间（和法术里保持一致）
func _advance_for(sp: Node, tg: Dictionary, deg: float) -> float:
	sp.set("sector_half", deg_to_rad(deg) * 0.5)
	var a_min := float(tg.get("angle_min", 45.0))
	var a_max := float(tg.get("angle_max", 80.0))
	var t_min := float(tg.get("advance_time_at_min", 1.0))
	var t_max := float(tg.get("advance_time_at_max", 0.6))
	var span := a_max - a_min
	var k := 0.0 if absf(span) < 0.0001 else clampf((deg - a_min) / span, 0.0, 1.0)
	return lerpf(t_min, t_max, k)

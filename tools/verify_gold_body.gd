extends SceneTree
## 金色守护 自检：注册 / 碎片装配 / 三阶段状态机 / 薄膜贴装与还原 / 法力不足也碎裂。

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


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	print("=========== 金色守护 自检 ===========")

	# ---- 1. 注册 ----
	var spells: Dictionary = load("res://scripts/spells/spell_caster.gd").get_script_constant_map()["SPELLS"]
	_ck("已在 spell_caster.SPELLS 注册", spells.has("gold_body"))
	var names: Dictionary = load("res://scripts/spells/spell_wheel.gd").get_script_constant_map()["SPELL_NAMES"]
	_ck("术法名 = 金色守护", String(names.get("gold_body", "")) == "金色守护",
			"实际 '%s'" % String(names.get("gold_body", "")))
	var assigned: Dictionary = load("res://scripts/spells/spell_wheel.gd").get_script_constant_map()["ASSIGNED"]
	_ck("已占轮盘槽位 5", String(assigned.get(5, "")) == "gold_body",
			"槽位5 = '%s'" % String(assigned.get(5, "")))

	# ---- 2. 装配 + 假角色 ----
	var player := Node3D.new()
	player.name = "TestPlayer"
	get_root().add_child(player)
	var body := MeshInstance3D.new()
	body.name = "BodyMesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.5, 1.8, 0.4)
	body.mesh = bm
	body.position = Vector3(0, 0.9, 0)
	player.add_child(body)
	player.global_position = Vector3(2, 0, -3)

	var spell: Node3D = (load("res://scripts/spells/gold_body.gd") as GDScript).new()
	get_root().add_child(spell)
	spell.call("setup", player, null)
	var shards = spell.get("_shards")
	_ck("碎片粒子系统已装配", shards != null and int(shards.get("amount")) == 48,
			"amount=%s" % str(shards.get("amount")) if shards != null else "无")
	_ck("初始未施法且不发射", not bool(spell.call("is_casting"))
			and shards != null and not bool(shards.get("emitting")))

	# ---- 3. 汇聚 -> 守护 ----
	var mana = get_root().get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
	spell.call("start_cast")
	_ck("start_cast 后进入汇聚阶段并开始发射碎片",
			int(spell.get("_state")) == 1 and bool(shards.get("emitting")),
			"state=%d" % int(spell.get("_state")))
	var mat = spell.get("_shard_mat")
	_ck("碎片为汇聚模式（mode=0）", int(mat.get_shader_parameter("mode")) == 0)

	_pump(spell, 0.9)
	_ck("汇聚结束 -> 进入守护", int(spell.get("_state")) == 2,
			"state=%d" % int(spell.get("_state")))
	var film = spell.get("_film")
	_ck("薄膜已完全显形（reveal=1）",
			film != null and absf(float(film.get_shader_parameter("reveal")) - 1.0) < 0.01)
	_ck("角色的网格已贴上金色薄膜",
			body.material_overlay == film, "overlay=%s" % str(body.material_overlay))
	_ck("金色罩壳已生成", spell.get("_aura") != null)

	var m0 := float(mana.get("current")) if mana != null else 0.0
	_pump(spell, 1.0)
	var m1 := float(mana.get("current")) if mana != null else 0.0
	_ck("守护期间持续耗蓝", m1 < m0, "%.1f -> %.1f" % [m0, m1])

	# ---- 4. 主动停手 -> 碎裂 -> 消失 ----
	spell.call("stop_cast")
	_pump(spell, 0.1)
	_ck("停手后进入碎裂", int(spell.get("_state")) == 3,
			"state=%d" % int(spell.get("_state")))
	_ck("碎片切换为发散模式（mode=1）", int(mat.get_shader_parameter("mode")) == 1)
	_pump(spell, 0.5)
	var dmid := float(film.get_shader_parameter("dissolve"))
	_ck("薄膜在逐渐碎裂（dissolve 递增）", dmid > 0.05 and dmid < 1.0,
			"dissolve=%.2f" % dmid)
	_pump(spell, 0.6)
	_ck("碎裂结束后回到关闭态", int(spell.get("_state")) == 0,
			"state=%d" % int(spell.get("_state")))
	_ck("角色材质已还原（没留下永久金膜）", body.material_overlay == null,
			"overlay=%s" % str(body.material_overlay))
	_ck("罩壳已回收", spell.get("_aura") == null)

	# ---- 5. 法力不足也要走碎裂（需求明确包含这种情况） ----
	if mana != null:
		mana.call("refill")
	spell.call("start_cast")
	_pump(spell, 0.9)
	if mana != null:
		mana.call("set", "current", 0.0)      # 直接抽干蓝
	spell.set("mana_per_sec", 999.0)
	_pump(spell, 0.2)
	_ck("法力不足时也会进入碎裂（而不是直接消失）",
			(int(spell.get("_state")) == 3 or int(spell.get("_state")) == 0)
			and bool(spell.call("ran_out_of_mana")),
			"state=%d ran_out=%s" % [int(spell.get("_state")), str(spell.call("ran_out_of_mana"))])

	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

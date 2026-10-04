extends SceneTree
## 火焰灼烧 自检：注册 / 特效装配 / 三阶段状态机 / 耗蓝。用完可保留。

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
	var n := int(seconds / DT)
	for i in n:
		node.call("_process", DT)


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	print("=========== 火焰灼烧 自检 ===========")

	# ---- 1. 注册 ----
	var caster_script: GDScript = load("res://scripts/spells/spell_caster.gd")
	var wheel_script: GDScript = load("res://scripts/spells/spell_wheel.gd")
	var spells: Dictionary = caster_script.get_script_constant_map()["SPELLS"]
	_ck("已在 spell_caster.SPELLS 注册", spells.has("flame_scorch"))
	var names: Dictionary = wheel_script.get_script_constant_map()["SPELL_NAMES"]
	_ck("术法名 = 火焰灼烧", String(names.get("flame_scorch", "")) == "火焰灼烧",
			"实际 '%s'" % String(names.get("flame_scorch", "")))
	var assigned: Dictionary = wheel_script.get_script_constant_map()["ASSIGNED"]
	_ck("已占轮盘槽位 4", String(assigned.get(4, "")) == "flame_scorch",
			"槽位4 = '%s'" % String(assigned.get(4, "")))

	# ---- 2. 装配 ----
	var spell: Node3D = (load("res://scripts/spells/flame_scorch.gd") as GDScript).new()
	_ck("法术脚本能实例化", spell != null)
	if spell == null:
		quit(1)
		return true
	var player := Node3D.new()
	player.name = "TestPlayer"
	get_root().add_child(player)
	spell.name = "FlameScorch"
	get_root().add_child(spell)          # add_child 触发 _ready
	var staff := Node3D.new()
	get_root().add_child(staff)
	spell.call("setup", player, staff)

	var fire = spell.get("_fire")
	var meshes: Array = []
	if fire != null:
		_gather(fire, meshes)
	_ck("火焰特效已装配（16 张焰卡）", meshes.size() == 16, "实际 %d" % meshes.size())
	_ck("默认不可见", fire != null and not (fire as Node3D).visible)
	_ck("初始未施法", not bool(spell.call("is_casting")))

	# ---- 3. 状态机：点燃 -> 燃烧 ----
	var mana = get_root().get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
	spell.call("start_cast")
	_ck("start_cast 后立刻可见", fire != null and (fire as Node3D).visible)
	_pump(spell, 0.5)
	_ck("点燃完成 -> 进入燃烧", int(spell.get("_state")) == 2,
			"state=%d grow=%.2f" % [int(spell.get("_state")), float(fire.get("grow"))])
	_ck("燃烧阶段火焰接近满尺寸", float(fire.get("grow")) > 0.9,
			"grow=%.2f" % float(fire.get("grow")))
	_ck("特效根节点缩放固定为 1（熄灭时不缩放根，避免向中心靠拢）",
			absf((fire as Node3D).scale.x - 1.0) < 0.001,
			"root.scale=%.3f" % (fire as Node3D).scale.x)
	_ck("施法中", bool(spell.call("is_casting")))

	var m0 := float(mana.get("current")) if mana != null else 0.0
	_pump(spell, 1.0)
	var m1 := float(mana.get("current")) if mana != null else 0.0
	_ck("燃烧期间持续耗蓝", m1 < m0, "%.1f -> %.1f" % [m0, m1])

	# ---- 4. 停手 -> 余烬 -> 熄灭 ----
	spell.call("stop_cast")
	_pump(spell, 0.1)
	_ck("停手后进入余烬（不是立刻消失）", int(spell.get("_state")) == 3,
			"state=%d" % int(spell.get("_state")))
	_pump(spell, 0.6)
	var mid := float(fire.get("grow"))
	_pump(spell, 1.2)
	_ck("余烬期间逐渐缩灭", mid < 0.9 and int(spell.get("_state")) == 0,
			"中途 grow=%.2f -> state=%d" % [mid, int(spell.get("_state"))])
	_ck("熄灭后不可见", fire != null and not (fire as Node3D).visible)

	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true


func _gather(n: Node, out: Array) -> void:
	for c in n.get_children():
		if c.name == "CoreGlow":      # 核心辉光不是焰卡
			continue
		if c is MeshInstance3D:
			out.append(c)
		else:
			_gather(c, out)

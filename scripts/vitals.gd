extends Node
## 角色状态数值：血量 / 精力值 / 舒适度（自动加载为 Vitals）。
##
## 为什么单独做：**魔法值已经有了**（scripts/spells/mana.gd -> Mana），这三项在项目里不存在。
## 接口刻意跟 Mana 对齐，这样 UI 可以用同一套写法绑定：
##     只读   current(stat) / maximum(stat) / ratio(stat) / is_empty(stat)
##     改值   add() / damage() / heal() / spend_stamina() / refill()
##     信号   changed(stat, cur, max) / emptied(stat) / refilled(stat)
## 和 Mana 的差异：Mana 是单值所以用 current/max_mana 两个属性；这里是四选一，
## 所以统一走 stat 参数（枚举 Stat），避免写四套几乎一样的属性。
##
## 驱动来源（**尽量挂到已有系统上，不自己造一套**）：
##   · 精力值 <- 玩家奔跑：player.gd::set_running()（camera_rig 每帧告知"是否按着加速键"）
##              再结合 velocity 判断"是不是真的在跑"，站着按 Shift 不掉精力。
##   · 舒适度 <- 天气：Weather 自动加载里已有的 rain / wind / fog（没有天气时自动回满）。
##   · 血量   <- 目前**只有对外接口**，项目里还没有任何伤害源。
##              以后接摔落/受击/怪物时调 damage() 即可，UI 不用改。
##
## 注意：process_mode 设为 ALWAYS，和 Mana 一致（暂停时也继续跑恢复逻辑）。

signal changed(stat: int, current: float, maximum: float)
signal emptied(stat: int)
signal refilled(stat: int)

enum Stat { HP, STAMINA, COMFORT }

const NAMES := {
	Stat.HP: "血量",
	Stat.STAMINA: "精力",
	Stat.COMFORT: "舒适度",
}

@export_group("上限")
@export var max_hp := 100.0
@export var max_stamina := 100.0
@export var max_comfort := 100.0

@export_group("精力")
@export var sprint_cost_per_sec := 22.0     ## 奔跑时每秒消耗
@export var stamina_regen_per_sec := 16.0   ## 停止消耗后每秒恢复
@export var stamina_regen_delay := 0.8      ## 停止消耗后多久开始恢复（秒）
@export var sprint_speed_threshold := 1.5   ## 水平速度低于此值不算"在跑"（站着按 Shift 不掉）

@export_group("舒适度")
@export var comfort_track_speed := 0.35     ## 每秒向"天气目标值"靠拢的比例（1 = 立刻到位）

var _cur := {
	Stat.HP: 100.0,
	Stat.STAMINA: 100.0,
	Stat.COMFORT: 100.0,
}
## 距上次消耗过去了多久（用来做"停了才恢复"的延迟）
var _since_spend := {
	Stat.STAMINA: 999.0,
	Stat.COMFORT: 999.0,
}
var _player: Node3D = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_cur[Stat.HP] = max_hp
	_cur[Stat.STAMINA] = max_stamina
	_cur[Stat.COMFORT] = max_comfort


# ---------------------------------------------------------------- 只读
func maximum(stat: int) -> float:
	match stat:
		Stat.HP: return max_hp
		Stat.STAMINA: return max_stamina
		Stat.COMFORT: return max_comfort
	return 0.0


func current(stat: int) -> float:
	return float(_cur.get(stat, 0.0))


func ratio(stat: int) -> float:
	var m := maximum(stat)
	return 0.0 if m <= 0.0 else clampf(current(stat) / m, 0.0, 1.0)


func is_empty(stat: int) -> bool:
	return current(stat) <= 0.0


func name_of(stat: int) -> String:
	return String(NAMES.get(stat, "?"))


# ---------------------------------------------------------------- 改值
## 唯一写入口：夹紧范围 + 发信号（跟 Mana 一样，UI 只认信号不轮询）
func set_value(stat: int, v: float) -> void:
	var m := maximum(stat)
	var old := current(stat)
	var nv := clampf(v, 0.0, m)
	if is_equal_approx(nv, old):
		return
	_cur[stat] = nv
	changed.emit(stat, nv, m)
	if nv <= 0.0 and old > 0.0:
		emptied.emit(stat)
	elif nv > 0.0 and old <= 0.0:
		refilled.emit(stat)


func add(stat: int, amount: float) -> void:
	if amount == 0.0:
		return
	set_value(stat, current(stat) + amount)


## 扣值；够就扣掉返回 true，不够返回 false（不扣成负数）
func try_spend(stat: int, amount: float) -> bool:
	if amount <= 0.0:
		return true
	if current(stat) < amount:
		set_value(stat, 0.0)
		return false
	set_value(stat, current(stat) - amount)
	return true


## 按"每秒消耗 × delta"扣（和 Mana.spend_rate 同款用法）
func spend_rate(stat: int, delta: float, per_sec: float) -> bool:
	var ok := try_spend(stat, per_sec * delta)
	if ok and _since_spend.has(stat) and per_sec > 0.0:
		_since_spend[stat] = 0.0
	return ok


func refill(stat: int = -1) -> void:
	if stat < 0:
		for s in [Stat.HP, Stat.STAMINA, Stat.COMFORT]:
			set_value(s, maximum(s))
		return
	set_value(stat, maximum(stat))


# ---------------------------------------------------------------- 血量对外接口
## 以后接伤害源（摔落/受击/怪物）时调这两个即可，UI 不用动
func damage(amount: float) -> void:
	# ★★ 金色守护：**100% 抵挡**（用户需求 ✓）
	#   判据：本节点自身或其**父节点**（玩家）带 meta `gold_guard` ✓
	#   meta 由 `scripts/spells/gold_body.gd` 施放时设置 ✓、效果结束时清除 ✓
	#   → 护盾期间任何伤害**直接返回** ✓（不扣血、不触发受击表现 ✓）
	if get_meta("gold_guard", false) or (get_parent() != null and get_parent().has_meta("gold_guard")):
		return
	add(Stat.HP, -absf(amount))


func heal(amount: float) -> void:
	add(Stat.HP, absf(amount))


func is_dead() -> bool:
	return is_empty(Stat.HP)


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	_tick_stamina(delta)
	_tick_comfort(delta)


func _tick_stamina(delta: float) -> void:
	var p := _find_player()
	var sprinting := false
	if p != null:
		var running := p.has_method("is_running") and bool(p.call("is_running"))
		var v: Variant = p.get("velocity")
		var speed := 0.0
		if v is Vector3:
			speed = Vector2((v as Vector3).x, (v as Vector3).z).length()
		sprinting = running and speed > sprint_speed_threshold

	if sprinting:
		try_spend(Stat.STAMINA, sprint_cost_per_sec * delta)
		_since_spend[Stat.STAMINA] = 0.0
		return

	_since_spend[Stat.STAMINA] += delta
	if _since_spend[Stat.STAMINA] < stamina_regen_delay:
		return
	if current(Stat.STAMINA) < max_stamina:
		set_value(Stat.STAMINA, current(Stat.STAMINA) + stamina_regen_per_sec * delta)


func _tick_comfort(delta: float) -> void:
	var target := comfort_target()
	var cur := current(Stat.COMFORT)
	if is_equal_approx(cur, target):
		return
	set_value(Stat.COMFORT, lerpf(cur, target, clampf(comfort_track_speed * delta, 0.0, 1.0)))


## 舒适度目标值：由**已有**的天气系统给出（下雨/大风/雾 -> 降低）
func comfort_target() -> float:
	var w := get_node_or_null("/root/Weather")
	if w == null:
		return max_comfort
	var rain := float(w.get("rain"))
	var wind := float(w.get("wind"))
	var fog := float(w.get("fog"))
	var penalty := rain * 0.55 + maxf(0.0, wind - 0.35) * 0.45 + fog * 0.25
	return max_comfort * clampf(1.0 - penalty, 0.15, 1.0)


# ---------------------------------------------------------------- 找玩家
## 优先 group（player.gd 在 _ready 里进组），兜底按名字递归找（和 spell_caster 同款策略）
func _find_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	if get_tree() == null:
		return null
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		_player = g as Node3D
		return _player
	var root := get_tree().current_scene
	if root == null:
		return null
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and String(n.name).to_lower().contains("player"):
			_player = n as Node3D
			return _player
		for c in n.get_children():
			stack.append(c)
	return null

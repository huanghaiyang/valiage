extends Node
## ============================================================================
## combat_text.gd —— 伤害 / 恢复的漂浮数字（自动加载单例 CombatText）
## ----------------------------------------------------------------------------
## 【用途】命中时在目标头顶弹出数字：伤害为红色 "-12"，恢复为绿色 "+8"。
##   数字带"先放大再回弹"的跳动 + 上浮 + 淡出，符合动作游戏的手感。
##
## 【两个伤害来源，各自怎么接】
##   1. 敌人：谁挨打谁调用本单例的 damage_at(位置, 数值, 聚合键)。
##      项目里目前只有 scenes/combat_test.tscn 的 damage_dummy.gd 会调
##      （take_damage() 里一行），将来接真敌人时照抄那一行即可。
##   2. 玩家：**不改 vitals.gd**，这里连 Vitals 的 changed(stat, cur, max)，
##      只认 Stat.HP（枚举值 0），用前后差值判断"掉血还是回血"。
##      因此任何未来调用 Vitals.damage() / heal() 的地方都会自动有飘字；
##      金色守护挡掉伤害时 Vitals 不发 changed，所以护盾期间也不会弹数字（正确）。
##
## 【为什么要"聚合"】
##   火焰/龙卷等法术按小数累积、攒够 1 点就调一次 take_damage：一个靶子可能每秒
##   收到十几二十次调用。逐次生成 Label3D 会糊满屏幕，所以同一来源（聚合键）在
##   AGGREGATE_WINDOW 秒内再次受伤只把数字累加进已有那条飘字，而不是新开一条。
##
## 【"跳动"是怎么做的】
##   生成时 scale=0.35 → Tween(TRANS_BACK, EASE_OUT) 弹到 1.0（会轻微过冲）；
##   同时用一条并行 Tween 把 global_position 上抬 RISE 米、另一条在后半段淡出，
##   结束后 queue_free。文字本身用 Label3D + billboard，永远面向相机。
##
## 【生命周期与场景】
##   · 飘字挂在名为 CombatTextRoot 的 Node3D 下，父节点是 current_scene（没有就挂 /root）；
##     切换场景时容器会随旧场景一起释放，下次生成自动重建。
##   · 本单例只做表现，不发任何游戏性信号、不改血量。
## ============================================================================

## 血量的 Stat 枚举值（vitals.gd 的 `enum Stat { HP, STAMINA, COMFORT }`，HP == 0）。
## 这里写常量而不是引用类型：本文件保持对 Vitals 的零编译依赖（只走 get_node + call）。
const HP_STAT := 0

## 一条飘字从出现到消失的总时长（秒）与上浮高度（米）。
const LIFE := 0.85
const RISE := 0.95
## 同一聚合键在这个窗口内再次受伤 -> 累加到已有飘字（避免高频伤害刷屏）。
const AGGREGATE_WINDOW := 0.35
## 伤害 / 恢复的配色（恢复用偏亮的草绿，和项目整体的暖色调区分开）。
const DAMAGE_COLOR := Color(1.00, 0.40, 0.28)
const HEAL_COLOR := Color(0.45, 1.00, 0.55)

## 飘字容器（延迟创建；current_scene 变化后会自动重建，旧引用失效由 is_instance_valid 兜底）。
var _root: Node3D = null
## 玩家血量的上一次值（用于 changed 里算差值）。-1 = 还没同步过（此时不弹字）。
var _last_hp := -1.0
## 聚合记录：聚合键 -> {label: Label3D, amount: int, t: float（生成时刻，秒）, healing: bool}。
var _active: Dictionary = {}
## 玩家节点缓存（顶字位置用）。
var _player: Node3D = null


func _ready() -> void:
	# 暂停菜单里也允许飘字继续播完，否则打开菜单时数字会僵在半空（和 Mana/Vitals 同款）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 连玩家血量信号：Vitals 是自动加载单例，正常启动顺序下这里必然已经就绪。
	var v := get_node_or_null("/root/Vitals")
	if v != null:
		_last_hp = float(v.call("current", HP_STAT))
		v.connect("changed", _on_vitals_changed)


# ==================== 对外接口 ====================
## 在指定世界坐标弹一条**伤害**数字（红色 "-N"）。
##
## 参数 pos：世界坐标（通常传目标头顶，而不是脚底）。
## 参数 amount：正整数；<= 0 直接忽略（法术累积不足 1 点时不要调用，这里是最后一道保险）。
## 参数 key（可选）：聚合键，一般传目标节点本身；同一个键在 AGGREGATE_WINDOW 内
##   的多次调用会合并成一条数字。传 null = 每次都新开一条（玩家血量变化走这条）。
## 副作用：创建 Label3D + Tween，写 _active；不改变任何游戏状态。
func damage_at(pos: Vector3, amount: int, key: Variant = null) -> void:
	_show(pos, amount, false, key)


## 在指定世界坐标弹一条**恢复**数字（绿色 "+N"）。参数含义同 damage_at()。
func heal_at(pos: Vector3, amount: int, key: Variant = null) -> void:
	_show(pos, amount, true, key)


# ==================== 玩家血量 -> 飘字 ====================
## Vitals.changed 的接收槽：只处理 HP，用新旧差值决定伤害 / 恢复。
##
## 参数 stat：Stat 枚举（只认 HP_STAT）；cur：变化后的血量；_max：上限（未使用）。
## 副作用：更新 _last_hp、在玩家头顶生成飘字（玩家找不到时静默跳过）。
## 注意：Vitals 用 is_equal_approx 判"没变不发信号"，所以这里不需要再过滤微小抖动；
##   但回血/掉血可能是小数，展示时按四舍五入取整（0.4 点的变化不弹"0"）。
func _on_vitals_changed(stat: int, cur: float, _max: float) -> void:
	if stat != HP_STAT:
		return
	var prev := _last_hp
	_last_hp = cur
	if prev < 0.0:
		return
	var delta := cur - prev
	var whole := int(round(absf(delta)))
	if whole <= 0:
		return
	var p := _player_node()
	if p == null:
		return
	var pos := p.global_position + Vector3(0.0, 2.2, 0.0)
	if delta < 0.0:
		damage_at(pos, whole, p)
	else:
		heal_at(pos, whole, p)


# ==================== 生成与动画 ====================
## 内部统一入口：按"是否恢复"决定文字/配色，并可复用聚合记录。
##
## 参数 pos：世界坐标；amount：正整数；healing：true = 绿字加号；key：聚合键或 null。
## 副作用：可能改写已有 Label3D 的 text/scale，或新建 Label3D + 两条 Tween。
func _show(pos: Vector3, amount: int, healing: bool, key: Variant) -> void:
	if amount <= 0:
		return
	var now := _now()
	if key != null:
		var rec: Dictionary = _active.get(key, {})
		if not rec.is_empty():
			var old = rec.get("label")
			# 同键 + 同类型 + 窗口内 才合并：玩家"先掉血再回血"在 0.35 s 内发生时，
			# 两者必须分开显示，否则 +10 会被加进 "-10" 变成 "-20"。
			if is_instance_valid(old) and bool(rec.get("healing", healing)) == healing \
					and now - float(rec.get("t", 0.0)) < AGGREGATE_WINDOW:
				var total := int(rec.get("amount", 0)) + amount
				rec["amount"] = total
				_active[key] = rec
				old.text = _format(total, healing)
				# 累加时也"跳一下"，让玩家看出又叠了一层伤害。
				old.scale = Vector3.ONE * 1.18
				var pop := create_tween()
				pop.tween_property(old, "scale", Vector3.ONE, 0.12)
				return
			_active.erase(key)
	# 清理已销毁的聚合记录：飘字播完 queue_free 后，字典里的旧引用会一直留着。
	for k in _active.keys():
		var stale = _active[k].get("label")
		if not is_instance_valid(stale):
			_active.erase(k)
	var label := Label3D.new()
	label.text = _format(amount, healing)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# 数字永远压在场景之上：低角度俯视时不容易被草/石头挡住。
	label.no_depth_test = true
	label.pixel_size = 0.008
	label.font_size = 64
	label.outline_size = 12
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
	label.modulate = HEAL_COLOR if healing else DAMAGE_COLOR
	label.render_priority = 20
	label.double_sided = true
	_root_node().add_child(label)

	# 左右随机错开一点，连续命中时数字不会完全重叠在一条竖线上。
	var start := pos + Vector3(randf_range(-0.30, 0.30), 0.0, randf_range(-0.20, 0.20))
	label.global_position = start
	label.scale = Vector3.ONE * 0.35

	if key != null:
		_active[key] = {"label": label, "amount": amount, "t": now, "healing": healing}

	# 上浮（整段 LIFE）+ 弹出（前 0.22 秒）并行；TRANS_BACK/EASE_OUT 自带一点过冲，看起来"蹦"出来。
	var mover := create_tween().set_parallel(true)
	mover.tween_property(label, "global_position", start + Vector3(0.0, RISE, 0.0), LIFE) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	mover.tween_property(label, "scale", Vector3.ONE, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	# 淡出放在后半段，前 45% 保持清晰。
	var fader := create_tween()
	fader.tween_interval(LIFE * 0.45)
	fader.tween_property(label, "modulate:a", 0.0, LIFE * 0.55)
	fader.tween_callback(label.queue_free)


## 文本格式：伤害 "-N"、恢复 "+N"。参数见 _show()。
func _format(amount: int, healing: bool) -> String:
	return ("+%d" % amount) if healing else ("-%d" % amount)


## 取（或重建）飘字容器。
##
## 返回：Node3D，保证已挂进当前场景；没有 current_scene（单元测试/特殊启动）时挂到 /root。
## 副作用：首次调用或检测到旧容器失效时新建 Node3D 并 add_child。
func _root_node() -> Node3D:
	if _root != null and is_instance_valid(_root):
		return _root
	var scene := get_tree().current_scene
	var parent: Node = scene if scene != null else get_tree().root
	_root = Node3D.new()
	_root.name = "CombatTextRoot"
	parent.add_child(_root)
	return _root


## 取玩家节点（顶字位置用）：优先分组 "player"（player.gd 在 _ready 里注册）。
## 返回 null 表示当前场景没有玩家（例如在战斗测试场景里被打的是靶子）。
func _player_node() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	if not is_inside_tree():
		return null
	_player = get_tree().get_first_node_in_group(&"player") as Node3D
	return _player


## 当前时刻（秒）。只用于聚合窗口的比较，不需要高精度。
func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

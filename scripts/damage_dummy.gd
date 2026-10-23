extends StaticBody3D
## ============================================================================
## damage_dummy.gd —— 攻击数值测试用的"人物靶子"
## ----------------------------------------------------------------------------
## 【用途】在测试场景 scenes/combat_test.tscn 里充当可被打的敌人模型，把
##   每一次命中（伤害点数 / 累计伤害 / 命中次数 / 平均 DPS）打在头顶 Label3D 上，
##   同时 print 到控制台，便于核对各术法的实际输出。
##
## 【敌人约定】（与 scripts/spells/flame_scorch.gd、blue_tornado.gd、flame_advance.gd 一致）
##   · 本节点在组 "enemies" 里（场景里已标，_ready 再兜底加一次，重复添加无副作用）；
##   · 必须实现 take_damage(int)：那些法术会按组遍历并**直接 call("take_damage", 整数)**
##     （没有 has_method 检查），缺这个方法会报"方法不存在"。
##   · 圈选类法术用本节点的 global_position 判"是否在圈内"（水平距离，忽略 y）。
##
## 【本文件不做的事】
##   · 不改血量上限、不播受击动画、不死亡；这是"数值探针"，不是敌人系统。
##   · 不每帧刷新 UI：只在命中 / 清零时刷新一次，静止时零开销。
##
## 【操作】R 键清零本轮统计（只在未被 UI 吃掉事件时生效）。
## ============================================================================

## 靶子显示名（Label3D 第一行）。
@export var dummy_name := "人物靶子"

## 本轮累计伤害（点）。take_damage 只加不减；按 R 清零。
var total_damage := 0
## 本轮命中次数（每次 take_damage 调一次算一次，与伤害点数无关）。
var hit_count := 0
## 最近一次的伤害点数（便于看出单次法术的每帧/每跳伤害）。
var last_damage := 0

## 本轮统计的起点（秒）。用 Time.get_ticks_msec() 换算，只用于算平均 DPS。
var _t0 := 0.0
## 头顶统计面板（场景里的 TargetDummy/DamageLabel）。缺失时只 print，不报错。
@onready var _label: Label3D = get_node_or_null("DamageLabel") as Label3D


func _ready() -> void:
	add_to_group("enemies")
	_reset_stats()


## 伤害入口：flame_scorch / flame_advance / blue_tornado 会直接调用它。
## 参数 amount：本次伤害点数（整数，>0）。<=0 直接忽略。
func take_damage(amount: int) -> void:
	if amount <= 0:
		return
	total_damage += amount
	hit_count += 1
	last_damage = amount
	var elapsed := maxf(0.001, _now() - _t0)
	print("[靶子] +%d ｜ 累计 %d ｜ 第 %d 次命中 ｜ 平均 DPS %.1f" % [
			amount, total_damage, hit_count, float(total_damage) / elapsed])
	_refresh_label(elapsed)


## R 键清零本轮统计（重新开始计时）。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_R:
		_reset_stats()


func _reset_stats() -> void:
	total_damage = 0
	hit_count = 0
	last_damage = 0
	_t0 = _now()
	_refresh_label(0.0)


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


## 刷新头顶面板。elapsed <= 0 时 DPS 显示 0（还没开始计时）。
func _refresh_label(elapsed: float) -> void:
	if _label == null:
		return
	var dps := float(total_damage) / elapsed if elapsed > 0.0 else 0.0
	_label.text = "%s\n累计伤害：%d\n命中次数：%d\n最近一次：%d\n平均 DPS：%.1f\n（按 R 清零）" % [
			dummy_name, total_damage, hit_count, last_damage, dps]

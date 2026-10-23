extends Node3D
# ==============================================================================
# invisibility.gd —— 【隐身】施法代理（spell_wheel id: invisibility）
# ==============================================================================
# 【在系统里的位置】
#   · spell_caster.SPELLS["invisibility"] 指向本文件；轮盘槽位 1002（第 2 圈第 3 格）。
#   · 本文件是 spell_caster 的**共享 jet**：玩家在轮盘里选中隐身后创建，
#     按住左键期间 start_cast() 每帧被调用一次，松手时 stop_cast() 每帧被调用。
#
# 【为什么本文件不自己计时 / 不改透明度】
#   共享 jet 会在"玩家从轮盘改选别的术法"时被 spell_caster 直接 queue_free()。
#   隐身效果要持续 60s、还要负责把角色恢复成不透明，绝不能依赖它存活 ——
#   真正的效果状态在 invisibility_effect.gd（挂在角色节点下的持久节点）里。
#   本文件只做三件事：把新的一次"按下"翻译成一次 refresh()、上报是否还在生效、
#   忽略松手（效果由自己的 60s 计时结束）。
#
# 【"按下"的沿检测】
#   caster 在按住期间每帧都会调 start_cast()，所以这里用 _armed 把一次按住
#   收敛成**一次施放**：start_cast 里置 false，stop_cast（松手）里复位 true。
#   于是"生效期间再按一次"-> 新的一次 refresh() -> 剩余时间清零、重新计时（需求）。
# ==============================================================================

const EFFECT := preload("res://scripts/spells/invisibility_effect.gd")
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
const SHEET_ID := "invisibility"

## 效果宿主的节点名（挂在角色下，跨法术切换存活）。
const EFFECT_NAME := "InvisibilityEffect"

## 角色根节点（setup 注入）。
var _player: Node3D = null
## 手持法杖（setup 注入；效果宿主会在重扫时把它一并变透明）。
var _staff: Node3D = null
## 这一轮按住是否还没施放过（见文件头"按下"的沿检测）。
var _armed := true
## 效果宿主引用（可能为 null；只用来上报 is_casting()）。
var _effect: Node3D = null


## spell_caster 建好节点后调用：缓存角色 / 法杖，并打印一次数值表读数。
func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	_staff = staff
	var row := SHEET.get_spell(SHEET_ID)
	if not row.is_empty():
		print("[隐身] 数值表 ✓ 耗蓝=%.0f ｜ 持续=%.0fs ｜ 可叠加刷新" % [
				SHEET.f(SHEET_ID, "mana_cost", 10.0),
				SHEET.f(SHEET_ID, "duration", 60.0)])


## 按住施法键时每帧被 caster 调用；只在"新的一次按下"时真正生效。
func start_cast() -> void:
	if not _armed:
		return
	_armed = false
	var eff := _ensure_effect()
	if eff != null:
		# 每次都重新注入：中途换过法杖时，效果宿主下一帧重扫就会拿到新法杖
		eff.call("setup", _player, _staff)
		eff.call("refresh")


## 松手回调：只复位"按下"闩锁，**不结束效果**（效果由入口的 60s 计时收尾）。
func stop_cast() -> void:
	_armed = true


## 效果是否还在生效期。供 caster / 调试查询（共享 jet 不会被 _sweep_instances 回收）。
func is_casting() -> bool:
	return _effect != null and is_instance_valid(_effect) and bool(_effect.call("is_active"))


## 隐身不需要"施法动作演完才收势"，松手即可切回普通动作。
func wants_cast_anim() -> bool:
	return false


## 一次性扣蓝，不存在"持续耗蓝中断"的状态。
func ran_out_of_mana() -> bool:
	return false


## 取（必要时懒创建）角色下的效果宿主。
func _ensure_effect() -> Node3D:
	if _player == null or not is_instance_valid(_player):
		return null
	var n := _player.get_node_or_null(EFFECT_NAME)
	if n == null:
		n = EFFECT.new()
		n.name = EFFECT_NAME
		_player.add_child(n)
	_effect = n as Node3D
	return _effect

extends Node3D
# ==============================================================================
# invisibility_effect.gd —— 【隐身】效果的持久宿主（角色身上那层半透明）
# ==============================================================================
# 【为什么单独一个节点】
#   施法视觉（invisibility.gd）是 spell_caster 的**共享 jet**：一旦玩家从轮盘
#   选了别的术法，spell_caster._ensure_jet() 就会 stop_cast + queue_free 它。
#   若把 60s 计时与"恢复不透明"写在那上面，切一次法术就会把隐身效果连同
#   还原逻辑一起丢掉（角色永久半透明）。所以效果状态必须挂在**独立的持久节点**上：
#   它由第一次施法懒创建、挂在角色节点下，随角色一起生灭，与当前选中的术法无关。
#
# 【职责】
#   · refresh()：扣蓝（单次 10）+ 开始/刷新 60s 计时
#   · 进入隐身的过渡：淡入 FADE_IN_S 秒（0 -> 半透明）；已在隐身中刷新则**不重播**
#   · 生效期间：把角色子树（含随身法杖）里所有可见 MeshInstance3D 的
#     GeometryInstance3D.transparency 设为 BODY_TRANSPARENCY，并临时关闭投影
#   · 最后 BLINK_WINDOW_S 秒：透明度按 BLINK_HZ 正弦在 BLINK_MIN~BLINK_MAX 往复（明灭闪烁）
#   · 每 RESCAN_INTERVAL 秒重扫一次 → 中途换法杖 / 新挂网格也会一起变透明
#   · 计时到点 / 节点被释放：把每个网格的 transparency 与 cast_shadow 还原成
#     **施法前的快照**（不是写死 0，避免抹掉别的系统设的透明度）
#
# 【不变量】
#   · 账本只增不减（生效期间）；网格被释放时还原阶段用 is_instance_valid 跳过
#   · 同一网格重复 refresh 不会覆盖快照（快照永远代表"施法之前"）
#   · 本节点不生成任何几何 / 材质 / 粒子；关闭时 set_process(false)，零开销
# ==============================================================================

## 半透明程度：0 = 完全不透明，1 = 完全不可见。0.55 ≈ 45% 不透明度。
## 实测：GeometryInstance3D.transparency 对**不透明材质**同样有效（会强制走透明管线）。
const BODY_TRANSPARENCY := 0.55
## 重扫网格的间隔（秒）。换法杖是低频操作，0.5s 足够，又不至于每帧遍历子树。
const RESCAN_INTERVAL := 0.5
## 进入隐身的过渡（淡入）时长（秒）：透明度 0 -> BODY_TRANSPARENCY。
## 只在"从非隐身进入隐身"时播放；**已处于隐身状态时刷新不会重播**（需求）。
const FADE_IN_S := 0.4
# ---- 尾声"明灭"闪烁（效果快结束时提示玩家要现形了）----
## 最后这么多秒进入闪烁（0 = 关闭闪烁，全程恒定半透明）。
const BLINK_WINDOW_S := 5.0
## 闪烁频率（Hz）：每秒亮暗次数。3 Hz 既醒目又不会闪到眼花。
const BLINK_HZ := 3.0
## 闪烁时最"实"的一端（透明度更小 = 更看得见）。
const BLINK_MIN := 0.18
## 闪烁时最"虚"的一端（透明度更大 = 近乎消失）。
const BLINK_MAX := 0.88

const SHEET := preload("res://scripts/spells/spell_sheet.gd")
const SHEET_ID := "invisibility"
const OVERLAY := preload("res://scripts/spells/surface_overlay.gd")

## 效果目标角色（setup 注入）。本节点本身也挂在它下面，所以角色释放时随之释放。
var _player: Node3D = null
## 手持法杖节点（可能为 null）。角色子树已覆盖它，这里只用于"法杖不在角色下"的兜底。
var _staff: Node3D = null
## 是否处在生效期（= 有剩余时间）。对外经 is_active() 暴露。
var _active := false
## 剩余秒数。refresh() 重置为 duration，_process 每帧递减。
var _remain := 0.0
## 距上次重扫已过的秒数（见 RESCAN_INTERVAL）。
var _rescan_t := 0.0
## 淡入过渡已进行的秒数（>= FADE_IN_S 表示过渡已结束）。
## 初值就是 FADE_IN_S：未生效时 _target_transparency() 直接给恒定半透明值。
var _fade_t := FADE_IN_S
## 还原账本：网格实例 id -> {mi, prev_trans, prev_shadow}
var _ledger: Dictionary = {}


## 进树时先把每帧处理关掉：只有生效期才需要 _process。
func _ready() -> void:
	set_process(false)


## 注入角色 / 法杖（可重复调用；每次施法代理都会重新注入一遍，保证法杖是最新的）。
func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	_staff = staff


## 施放或刷新隐身（由 invisibility.gd 在"新的一次按下"时调用）。
## 参数：无（耗蓝 / 时长读数值表，缺行时用下面的兜底值）。
## 返回值：true = 已生效或已刷新；false = 法力不足 / 角色无效（此时**不改**计时）。
## 副作用：扣蓝；_remain 重置为 duration；首次生效时开 _process 并让角色半透明。
func refresh() -> bool:
	if _player == null or not is_instance_valid(_player):
		return false
	var cost := SHEET.f(SHEET_ID, "mana_cost", 10.0)
	var duration := SHEET.f(SHEET_ID, "duration", 60.0)
	if cost > 0.0:
		# 先判余额：Mana.try_spend() 在不足时会把蓝扣到 0 再返回 false（见 mana.gd 坑 1）
		if float(Mana.get("current")) < cost:
			print("[隐身] ✗ 法力不足（需要 %.0f，当前 %.0f）→ 本次不生效" % [
					cost, float(Mana.get("current"))])
			return false
		if not Mana.try_spend(cost):
			print("[隐身] ✗ 扣蓝失败 → 本次不生效")
			return false
	var was := _active
	var old := _remain
	# 生效中再次施放 = 刷新：上一次的剩余时间直接清零，重新从头计时（需求）
	_remain = maxf(0.1, duration)
	# ★ 过渡只在"从非隐身进入隐身"时播放；已处于隐身状态时**不处理**
	#   （不重置 _fade_t，角色保持当前透明度，不会突然变实再淡回去）
	if not was:
		_fade_t = 0.0
	_active = true
	set_process(true)
	_sync_meshes()
	if was:
		print("[隐身] 刷新 ✓ 原剩余 %.1fs 清零 → 重新计时 %.0fs（耗蓝 %.0f，不重播过渡）" % [
				old, _remain, cost])
	else:
		print("[隐身] 生效 ✓ %.0fs（耗蓝 %.0f）｜角色与随身物品半透明（淡入 %.2fs）" % [
				_remain, cost, FADE_IN_S])
	return true


## 效果是否仍在生效期（供施法代理的 is_casting() 查询）。
func is_active() -> bool:
	return _active


## 剩余秒数（调试 / 自检用）。
func remaining() -> float:
	return _remain


## 每帧：递减计时、淡入过渡、尾声明灭闪烁、周期性重扫网格、到点还原。
func _process(delta: float) -> void:
	if not _active:
		set_process(false)
		return
	_remain -= delta
	_fade_t = minf(_fade_t + delta, FADE_IN_S)
	_rescan_t += delta
	if _rescan_t >= RESCAN_INTERVAL:
		_rescan_t = 0.0
		_sync_meshes()
	# 过渡期每帧写一次（0 -> 半透明）；
	# 最后 BLINK_WINDOW_S 秒：透明度按正弦在 BLINK_MIN~BLINK_MAX 之间往复（"明灭"）。
	# 刷新（refresh）会把 _remain 拉回 60s，于是自然退出闪烁、回到恒定半透明。
	if _fade_t < FADE_IN_S or _remain <= BLINK_WINDOW_S:
		_apply_transparency(_target_transparency())
	if _remain <= 0.0:
		_finish()


## 当前这一帧应该用多大的透明度：
##   过渡期 = smoothstep(0 -> BODY_TRANSPARENCY)；正常期 = BODY_TRANSPARENCY；
##   尾声 = 3 Hz 正弦闪烁。
func _target_transparency() -> float:
	if _fade_t < FADE_IN_S:
		var k := clampf(_fade_t / FADE_IN_S, 0.0, 1.0)
		var eased := k * k * (3.0 - 2.0 * k)      # smoothstep：两端缓、中间快
		return BODY_TRANSPARENCY * eased
	if _remain > BLINK_WINDOW_S or BLINK_WINDOW_S <= 0.0:
		return BODY_TRANSPARENCY
	var elapsed := BLINK_WINDOW_S - maxf(_remain, 0.0)
	var wave := 0.5 - 0.5 * cos(TAU * BLINK_HZ * elapsed)   # 0 -> 1 -> 0 的平滑往复
	return lerpf(BLINK_MIN, BLINK_MAX, wave)


## 把当前透明度写到账本里的所有网格（书签式：只动权威值，不碰快照）。
func _apply_transparency(t: float) -> void:
	for id in _ledger.keys():
		var e: Dictionary = _ledger[id]
		var mi := e.get("mi") as MeshInstance3D
		if mi != null and is_instance_valid(mi):
			mi.transparency = t


## 把"角色 + 随身物品"里的可见网格全部设为半透明（已在账本里的只更新值，不覆盖快照）。
func _sync_meshes() -> void:
	var t := _target_transparency()
	for m in _targets():
		var mi := m as MeshInstance3D
		if mi == null:
			continue
		var id := mi.get_instance_id()
		if not _ledger.has(id):
			_ledger[id] = {
				"mi": mi,
				"prev_trans": mi.transparency,
				"prev_shadow": mi.cast_shadow,
			}
		mi.transparency = t
		# 半透明角色还投一条实心影子会非常出戏；还原阶段会写回原值
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## 收集要变透明的网格：角色子树 + 法杖子树（按实例 id 去重，法杖通常已在角色下）。
func _targets() -> Array:
	var out: Array = []
	var seen := {}
	for root in [_player, _staff]:
		if root == null or not is_instance_valid(root):
			continue
		for m in OVERLAY.visible_meshes(root):
			var mi := m as MeshInstance3D
			if mi == null:
				continue
			var id := mi.get_instance_id()
			if seen.has(id):
				continue
			seen[id] = true
			out.append(mi)
	return out


## 计时到点：还原所有网格，停掉 _process（节点保留复用，避免反复 new）。
func _finish() -> void:
	_active = false
	_remain = 0.0
	set_process(false)
	_restore()
	print("[隐身] 结束 ✓ 已恢复不透明（角色与随身物品）")


## 把账本里每个网格的 transparency / cast_shadow 写回施法前的快照。
## 节点已被释放的条目直接跳过（场景切换 / 换法杖时的常态）。
func _restore() -> void:
	for id in _ledger.keys():
		var e: Dictionary = _ledger[id]
		var mi := e.get("mi") as MeshInstance3D
		if mi != null and is_instance_valid(mi):
			mi.transparency = float(e.get("prev_trans", 0.0))
			mi.cast_shadow = int(e.get("prev_shadow", GeometryInstance3D.SHADOW_CASTING_SETTING_ON))
	_ledger.clear()


## 被直接释放（换角色 / 场景退出）时也要还原，否则角色会永久半透明。
func _exit_tree() -> void:
	_restore()

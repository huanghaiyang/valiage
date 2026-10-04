extends Node
## 法术施放控制器（自动加载为 SpellCaster）。
##
## 为什么做成自动加载：这样**完全不用改你的场景** —— 它自己在运行时找到玩家和手里的法杖，
## 挂上当前选中的术法视觉，并弹出法术圆盘。
##
## 操作：
##   Q          -> 唤出 / 收起 法术圆盘（InputMap 动作 spell_wheel；没有该动作才退回读 E）
##   E          -> 交给 main.gd 做场景交互（_try_interact），**法术这边不再占用 E**
##   左键点圆盘 -> 选中术法 -> 圆盘关闭
##   按住左键   -> 持续施放（火焰喷射朝前方喷、火焰编织在身前竖起火柱），魔法值耗尽自动停
##
## 术法在下面的 SPELLS 里注册；换术法时旧视觉会被停掉并释放。

const SpellWheel := preload("res://scripts/spells/spell_wheel.gd")
## 术法注册表：id -> 视觉脚本。视觉脚本只要实现
##   setup(player, staff) / start_cast() / stop_cast()
## 这三件事即可；瞄准方向与起始位置由 scripts/spells/spell_aim.gd 共用。
## 想换回着色器版火焰喷射：把 "flame_jet" 的值改成 preload(".../flame_visual.gd")。
const SPELLS := {
	"flame_jet": preload("res://scripts/spells/flame_jet_particles.gd"),
	"fire_tornado": preload("res://scripts/spells/fire_tornado_particles.gd"),
	"blue_tornado": preload("res://scripts/spells/blue_tornado.gd"),
	"detect_pulse": preload("res://scripts/spells/detect_pulse.gd"),
	"flame_scorch": preload("res://scripts/spells/flame_scorch.gd"),
	"gold_body": preload("res://scripts/spells/gold_body.gd"),
	"water_heal": preload("res://scripts/spells/water_heal.gd"),
}


@export var enabled := true
@export var wheel_action := "spell_wheel"     ## 输入动作名（没有就退回直接读 E）
@export var cast_action := "spell_cast"       ## 没有就退回直接读鼠标左键
@export var auto_find_interval := 0.5


var wheel: CanvasLayer = null
var jet: Node3D = null            ## 当前术法的视觉节点
var selected := ""
var _jet_spell := ""              ## jet 是哪个术法的视觉（换术法时据此重建）

var _player: Node3D = null
var _staff: Node3D = null
var _timer := 0.0
var _holding := false
## 施法许可：这一轮"按住"是否允许施法（规则见 _process 里的施法段）
var _cast_armed := true
var _cast_down_prev := false      ## 上一帧的按键状态：用来自己检测"按下"那一瞬
## 这一次"按下"是否落在 UI 上。**必须在事件阶段判定**（见 _input），
## 不能在 _process 里判：点圆盘选法术时圆盘会在同一帧内 close()，等到 _process
## 跑起来鼠标下已经没有 Control 了，会被误判成"在世界区按下"从而当帧施法。
var _cast_press_blocked := false
## 施法动作是否已经打开（对应 player 侧的施法动画状态）。只在开关切换时通知 player，
## 避免每帧重复 play() 把施法剪辑重置回第一帧。
var _cast_anim_on := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)        # 施法"按下"要在事件阶段判定是否落在 UI 上，见 _input
	wheel = SpellWheel.new()
	wheel.name = "SpellWheel"
	get_tree().root.add_child.call_deferred(wheel)
	wheel.spell_chosen.connect(_on_spell_chosen)


func _process(delta: float) -> void:
	if not enabled:
		# 控制器被关掉时不能把角色留在施法姿势上
		_update_cast_anim(false)
		return
	_timer += delta
	if _timer >= auto_find_interval or _player == null or _staff == null:
		_timer = 0.0
		_find_nodes()
	# 圆盘开关
	if _just_pressed_wheel():
		if wheel != null:
			wheel.call("toggle")
	# 施法（按住左键）
	# 规则两条，**全部轮询判定**，不依赖事件是否被 UI 消费：
	#   1. 鼠标下压着 UI 时不施法（面板 / 圆盘 / 小地图 / 量表，见 _ui_blocks_cast）；
	#   2. "按下"那一瞬若落在 UI 上，这一整轮按住作废 —— 直到真正抬起才重新上膛。
	#      这条专治"点轮盘选法术 / 点法杖列表，法术当场放出去"。
	# 为什么不用 _unhandled_input 收施法：main.gd / camera_rig.gd 也在 _unhandled_input
	# 里处理鼠标，谁先 set_input_as_handled() 谁就把事件吃掉，用事件接收会时灵时不灵
	# （settings_menu.gd 里有同款坑的注记）。Input.is_mouse_button_pressed() 是全局
	# 按键状态、不受消费影响，所以这里自己逐帧检测"按下"那一瞬，再配一次 UI 命中测试。
	var down := _cast_held()
	if down and not _cast_down_prev:
		_cast_armed = not _cast_press_blocked     # 按下那一瞬是否在 UI 上（_input 里已判定）
	elif not down:
		_cast_armed = true                       # 真正抬起 -> 重新上膛
	_cast_down_prev = down
	_holding = down and _cast_armed and not _ui_blocks_cast()
	_ensure_jet()          # 选中变化 -> 换视觉
	# 是否真的在施法：选了法术 + 按住 + 没被 UI 挡住 + 视觉节点有效。
	# ★ 刻意**不看蓝量**：蓝耗尽时视觉自己会停（各视觉的 ran_out_of_mana），
	#   但动画若跟着蓝量一起抖，会在回蓝阈值上来回闪。手上保持"我在施法"的
	#   姿势更稳，观感也更像在硬撑。
	var casting := _holding and not selected.is_empty() \
			and jet != null and is_instance_valid(jet)
	# ★ 施法动作：按住施放时跟着按住；**一次性法术**则由法术自己要求保持 ——
	#   否则松手那一瞬 stop_spell_cast() 就把动作切断了
	#   （症状：一次性法术的施法动作没完整执行一次）。
	var anim_on := casting
	if not anim_on and jet != null and is_instance_valid(jet) \
			and jet.has_method("wants_cast_anim"):
		anim_on = bool(jet.call("wants_cast_anim"))
	_update_cast_anim(anim_on)
	if jet != null and is_instance_valid(jet):
		if casting:
			jet.call("start_cast")
		else:
			jet.call("stop_cast")


# ---------------------------------------------------------------- 输入（动作优先，缺失就退回读键）
func _just_pressed_wheel() -> bool:
	if InputMap.has_action(wheel_action):
		return Input.is_action_just_pressed(wheel_action)
	# ★ _e_prev 必须**每帧都更新**，所以不能用 `... and not _e_was_down_prev()` 那种写法：
	#   更新 _e_prev 的代码一旦放到 and 右边，GDScript 的短路求值会在"E 没按下"时整段跳过，
	#   于是松开 E 后 _e_prev 永远停在 true -> E 一局只能生效一次
	#   （症状：选完法术再按 E 唤不出轮盘）。
	var now := Input.is_key_pressed(KEY_E)
	var just := now and not _e_prev
	_e_prev = now
	return just

var _e_prev := false


## 施法键是否处于"按下"（只读全局按键状态；**不**代表允许施法，许可见 _cast_armed）
func _cast_held() -> bool:
	if InputMap.has_action(cast_action):
		return Input.is_action_pressed(cast_action)
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


## 事件阶段记录"这一次按下是否落在 UI 上"。
## 为什么必须在这里判：Godot 的事件顺序是
##     Node._input  ->  GUI(Control._gui_input)  ->  Node._unhandled_input
## 而 _process 在这三者之后才跑。点圆盘选法术时，圆盘会在 GUI 阶段就 close()
## （visible = false），等 _process 再判"鼠标下有没有 Control"时已经什么都没有了，
## 于是被当成"在世界区按下"-> 当帧施法（实测症状：选完法术立刻被释放）。
## 在 _input 里判，看到的还是"点击前"的 UI 状态（圆盘还开着），判定才准。
func _input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_cast_press_blocked = mb.pressed and _ui_blocks_cast()
	elif InputMap.has_action(cast_action) and ev.is_action(cast_action):
		_cast_press_blocked = ev.is_pressed() and _ui_blocks_cast()


## 鼠标下是否压着 UI（面板 / 圆盘 / 小地图 / 量表…）——**操作 UI 时不施法**。
## 全屏 Control 只在打开时才 visible（轮盘关闭时 CanvasLayer.visible = false；
## 大地图 big_root.visible = false），所以它们不会常年把鼠标挡成"UI 区域"。
func _ui_blocks_cast() -> bool:
	# 圆盘铺满全屏，但鼠标未必已经移到它上面，所以单独判"是否打开"
	if wheel != null and is_instance_valid(wheel) and bool(wheel.call("is_open")):
		return true
	var vp := get_viewport()
	if vp == null:
		return false
	return vp.gui_get_hovered_control() != null


# ---------------------------------------------------------------- 找玩家与法杖
func _find_nodes() -> void:
	if get_tree() == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
	if _player != null and (_staff == null or not is_instance_valid(_staff)):
		_staff = _find_staff(_player)


func _find_player() -> Node3D:
	if get_tree().current_scene == null:
		return null
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		return g
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and String(n.name).to_lower().contains("player"):
			return n as Node3D
		for c in n.get_children():
			stack.append(c)
	return null


## 手里的法杖：优先找挂了 held_staff.gd 的节点；否则找名字像 staff 的 Node3D
func _find_staff(root: Node) -> Node3D:
	var fallback: Node3D = null
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var s := String(n.get_script().resource_path) if n.get_script() != null else ""
		if s.contains("held_staff"):
			return n as Node3D
		if fallback == null and n is Node3D and String(n.name).to_lower().contains("staff"):
			fallback = n as Node3D
		for c in n.get_children():
			stack.append(c)
	return fallback


func _ensure_jet() -> void:
	if selected.is_empty() or _player == null or _staff == null:
		return
	# 已经是这个术法的视觉：什么都不用做
	if jet != null and is_instance_valid(jet) and _jet_spell == selected:
		return
	var script: GDScript = SPELLS.get(selected, null)
	if script == null:
		push_warning("[SpellCaster] 未注册的术法: " + selected)
		return
	# 换术法：停掉并释放上一个
	if jet != null and is_instance_valid(jet):
		jet.call("stop_cast")
		jet.queue_free()
		jet = null
	var j: Node3D = script.new()
	j.name = "Spell_" + selected
	_player.get_parent().add_child(j)
	j.call("setup", _player, _staff)
	jet = j
	_jet_spell = selected


## 施法动作：驱动玩家角色的施法动画（player.gd::start_spell_cast / stop_spell_cast）。
##
## start 每帧都调 —— player 侧是**幂等**的（只在当前剪辑不是施法动画时才 play），
## 所以这里不必自己判断"是否已开始"；好处是起跳、被别的动作顶掉之后，
## 下一帧就能自动把施法姿势找回来。
## stop 只在"由开到关"那一次调，避免多余的动画切换。
##
## 用 has_method 而不是直接调 player.start_spell_cast()：player 是**运行时按 group
## 找到的**，可能被换成别的角色脚本（见 _find_player 的兜底搜索），
## 硬调会在换角色时直接报错。
func _update_cast_anim(casting: bool) -> void:
	var p := _player
	var ok := p != null and is_instance_valid(p)
	if casting:
		_cast_anim_on = true
		if ok and p.has_method("start_spell_cast"):
			p.call("start_spell_cast")
		return
	if not _cast_anim_on:
		return
	_cast_anim_on = false
	if ok and p.has_method("stop_spell_cast"):
		p.call("stop_spell_cast")


func _on_spell_chosen(id: String) -> void:
	select_spell(id)
	print("[SpellCaster] 选中术法：", id, "（松开左键后，再按住左键施法）")


# ---------------------------------------------------------------- 对外
func select_spell(id: String) -> void:
	selected = id
	# 选中的这一下不算施法：先上锁，等左键抬起后由 _process 解锁（见 _cast_armed）
	_cast_armed = false

func stop_spell() -> void:
	selected = ""
	if jet != null and is_instance_valid(jet):
		jet.call("stop_cast")
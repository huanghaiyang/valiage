extends Node
## 法术施放控制器（自动加载为 SpellCaster）。
##
## 为什么做成自动加载：这样**完全不用改你的场景** —— 它自己在运行时找到玩家和手里的法杖，
## 挂上当前选中的术法视觉，并弹出法术圆盘。
##
## 操作：
##   E          -> 唤出 / 收起 法术圆盘
##   左键点圆盘 -> 选中术法 -> 圆盘关闭
##   按住左键   -> 持续施放（火焰喷射朝前方喷、火龙卷在身前竖起火柱），魔法值耗尽自动停
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


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	wheel = SpellWheel.new()
	wheel.name = "SpellWheel"
	get_tree().root.add_child.call_deferred(wheel)
	wheel.spell_chosen.connect(_on_spell_chosen)


func _process(delta: float) -> void:
	if not enabled:
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
	_holding = _cast_held()
	_ensure_jet()          # 选中变化 -> 换视觉
	if jet != null and is_instance_valid(jet):
		if selected.is_empty() or not _holding:
			jet.call("stop_cast")
		else:
			jet.call("start_cast")


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


func _cast_held() -> bool:
	if InputMap.has_action(cast_action):
		return Input.is_action_pressed(cast_action)
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


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


func _on_spell_chosen(id: String) -> void:
	selected = id
	print("[SpellCaster] 选中术法：", id, "（按住左键喷射）")


# ---------------------------------------------------------------- 对外
func select_spell(id: String) -> void:
	selected = id

func stop_spell() -> void:
	selected = ""
	if jet != null and is_instance_valid(jet):
		jet.call("stop_cast")
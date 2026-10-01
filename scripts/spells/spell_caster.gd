extends Node
## 法术施放控制器（自动加载为 SpellCaster）。
##
## 为什么做成自动加载：这样**完全不用改你的场景** —— 它自己在运行时找到玩家和手里的法杖，
## 挂上火焰喷射，并弹出法术圆盘。
##
## 操作：
##   E          -> 唤出 / 收起 法术圆盘
##   左键点圆盘 -> 选中术法（火焰喷射）-> 圆盘关闭
##   按住左键   -> 朝角色正前方持续喷射（从法杖顶端喷出），魔法值耗尽自动停

const SpellWheel := preload("res://scripts/spells/spell_wheel.gd")
const FlameJet := preload("res://scripts/spells/flame_jet.gd")

@export var enabled := true
@export var wheel_action := "spell_wheel"     ## 输入动作名（没有就退回直接读 E）
@export var cast_action := "spell_cast"       ## 没有就退回直接读鼠标左键
@export var auto_find_interval := 0.5

var wheel: CanvasLayer = null
var jet: Node3D = null
var selected := ""

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
	if jet != null and is_instance_valid(jet):
		if selected.is_empty() or not _holding:
			jet.call("stop_cast")
		else:
			jet.call("start_cast")


# ---------------------------------------------------------------- 输入（动作优先，缺失就退回读键）
func _just_pressed_wheel() -> bool:
	if InputMap.has_action(wheel_action):
		return Input.is_action_just_pressed(wheel_action)
	return Input.is_key_pressed(KEY_E) and not _e_was_down_prev()
	
var _e_prev := false
func _e_was_down_prev() -> bool:
	var now := Input.is_key_pressed(KEY_E)
	var was := _e_prev
	_e_prev = now
	return was


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
		if _staff != null:
			_ensure_jet()


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
	if jet != null and is_instance_valid(jet):
		return
	if _player == null or _staff == null:
		return
	var j: Node3D = FlameJet.new()
	j.name = "FlameJet"
	_player.get_parent().add_child(j)
	j.call("setup", _player, _staff)
	jet = j


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
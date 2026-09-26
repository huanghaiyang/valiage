class_name Player
extends CharacterBody3D
## 玩家角色：第三方模型（KayKit Adventurers - Mage，CC0）
## CharacterBody3D + 胶囊碰撞体，由 CameraRig 用 move_and_slide 驱动（走物理碰撞）
## 动作系统：ACTION_LIB 动作注册表 + 一次性/循环动作播放 + 移动状态联动（走/跑/跳）

var body: Node3D
var anim_player: AnimationPlayer
var _moving := false
var _running := false
var _action_active := false      # 正在播放非移动动作
var _action_loop := false        # 当前动作是否循环播放
var _jump_air := false           # 跳跃滞空（保持跳跃动画直到落地）

const CHARACTER_SCENE := "res://assets/models/characters/Mage.glb"
# Mage 模型身体（头顶）原始约 2.94m，缩到 0.368 → 角色约 1.08m（门 1.7m 的约 64%）
const CHARACTER_SCALE := 0.368

# 碰撞体尺寸（胶囊，底部对齐脚底；高度匹配身体 1.08m，随缩放等比缩小）
const COLLIDER_RADIUS := 0.28
const COLLIDER_HEIGHT := 1.08
const COLLIDER_OFFSET_Y := 0.54

# 移动动画
const ANIM_IDLE := "Idle"
const ANIM_WALK := "Walking_A"
const ANIM_RUN := "Running_A"

## 动作注册表：[显示名, 动画名, 模式]
## 模式: "one"=一次性动作（播完回移动/Idle）；"loop"=循环动作（保持直到打断/再次移动）；"move"=移动类（交给移动状态机）
## 动画名优先 Mage.glb 自带；下载 KayKit Character Animations 包后升级精确动画
const ACTION_LIB: Array = [
	["走路", "Walking_A", "loop"],
	["跑步", "Running_A", "loop"],
	["跳跃", "Jump_Full_Long", "one"],
	["挥动手臂", "Cheer", "one"],
	["劈砍", "1H_Melee_Attack_Chop", "one"],
	["挥舞法杖", "Spellcasting", "loop"],
	["睡觉", "Lie_Down", "one"],
	["平砍", "1H_Melee_Attack_Slice_Horizontal", "one"],
	["挖掘", "2H_Melee_Attack_Chop", "one"],
	["踢腿", "Unarmed_Melee_Attack_Kick", "one"],
	["飞踢", "Jump_Full_Long", "one"],
	["翻阅", "Spellcasting", "loop"],
	["推", "1H_Melee_Attack_Stab", "one"],
	["拉", "2H_Melee_Attack_Stab", "one"],
	["拿起", "PickUp", "one"],
	["跨步", "Walking_C", "loop"],
	["翻越", "Jump_Full_Short", "one"],
	["仰头", "Spellcast_Raise", "one"],
	["俯视", "Spellcast_Shoot", "one"],
	["挥手", "Cheer", "one"],
	["拒绝", "Dodge_Backward", "one"],
	["晃动", "Hit_A", "one"],
	["下蹲", "Sit_Floor_Down", "one"],
	["转向", "2H_Melee_Attack_Spin", "one"],
	["互动", "Interact", "one"],
	["拾取", "PickUp", "one"],
	["丢掷", "Throw", "one"],
	["格挡", "Blocking", "loop"],
	["闪避", "Dodge_Forward", "one"],
	["坐地", "Sit_Floor_Idle", "loop"],
]

func _ready() -> void:
	body = _instantiate_character()
	if body == null:
		body = Node3D.new()
		body.name = "Visual"
		add_child(body)
	body.scale = Vector3.ONE * CHARACTER_SCALE

	# 角色碰撞体（胶囊，底部对齐脚底 origin）
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = COLLIDER_RADIUS
	cap.height = COLLIDER_HEIGHT
	col.shape = cap
	col.position = Vector3(0, COLLIDER_OFFSET_Y, 0)
	add_child(col)

	# 碰撞：层1=玩家；mask 与地形(2)/建筑(4)/植被(8)碰撞
	collision_layer = 1
	collision_mask = 2 | 4 | 8
	floor_snap_length = 0.3
	floor_max_angle = deg_to_rad(50.0)

func _physics_process(delta: float) -> void:
	# 非循环动作：播放结束后自动回到移动/Idle
	if _action_active and not _action_loop and anim_player != null:
		if not anim_player.is_playing():
			_action_active = false
			if not _jump_air:
				_update_move_anim()

func _instantiate_character() -> Node3D:
	var scene: PackedScene = load(CHARACTER_SCENE)
	if scene == null:
		return null
	var inst := scene.instantiate()
	inst.name = "Visual"
	add_child(inst)
	anim_player = _find_animation_player(inst)
	if anim_player != null:
		_play_anim(ANIM_IDLE)
	return inst

func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var r := _find_animation_player(c)
		if r != null:
			return r
	return null

func _play_anim(name: String) -> void:
	if anim_player != null and anim_player.has_animation(name):
		anim_player.play(name)

## 第一人称隐藏角色模型（避免相机卡进头部内部），第三人称显示
func set_body_visible(v: bool) -> void:
	if body != null:
		body.visible = v

## 角色面向水平移动方向（Mage 模型 +Z 为面部前方）
func face_direction(face: Vector3) -> void:
	if body != null:
		body.rotation.y = atan2(face.x, face.z)

# ---------- 移动状态联动 ----------

func set_moving(m: bool) -> void:
	_moving = m
	# 玩家实际移动时打断当前测试动作，恢复正常移动动画（动作菜单为测试用途）
	if m and _action_active:
		_action_active = false
		_action_loop = false
	if _action_active or _jump_air:
		return
	_update_move_anim()

func set_running(r: bool) -> void:
	_running = r
	if _action_active or _jump_air:
		return
	_update_move_anim()

func _update_move_anim() -> void:
	if _moving:
		_play_anim(ANIM_RUN if _running else ANIM_WALK)
	else:
		_play_anim(ANIM_IDLE)

## 起跳：播放跳跃动画，滞空期间保持
func on_jump() -> void:
	if anim_player == null:
		return
	_jump_air = true
	_action_active = false
	_play_anim("Jump_Full_Long")

## 落地：恢复移动/Idle
func on_land() -> void:
	_jump_air = false
	if _action_active:
		return
	_update_move_anim()

# ---------- 动作播放（动作菜单/快捷键触发） ----------

## 获取动作注册表
func get_action_lib() -> Array:
	return ACTION_LIB

## 按索引播放动作；返回实际动画名（不可用时返回空串）
func play_action(index: int) -> String:
	if anim_player == null or index < 0 or index >= ACTION_LIB.size():
		return ""
	var entry: Array = ACTION_LIB[index]
	var anim: String = entry[1]
	var mode: String = entry[2]
	if not anim_player.has_animation(anim):
		return ""
	_action_active = true
	_action_loop = (mode == "loop")
	_jump_air = false
	anim_player.play(anim)
	return anim

## 停止当前动作并回到移动/Idle（供菜单关闭/玩家操作打断）
func stop_action() -> void:
	if anim_player == null:
		return
	_action_active = false
	_action_loop = false
	if not _jump_air:
		_update_move_anim()

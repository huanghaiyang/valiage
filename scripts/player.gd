class_name Player
extends CharacterBody3D
## 玩家角色：第三方模型（KayKit Adventurers - Mage，CC0）
## CharacterBody3D + 胶囊碰撞（凸形状，兼容场景三角碰撞地形），由 CameraRig 用 move_and_slide 驱动（走物理碰撞）
## 动作系统：ACTION_LIB 动作注册表 + 一次性/循环动作播放 + 移动状态联动（走/跑/跳）

var body: Node3D
var anim_player: AnimationPlayer
var _moving := false
var _running := false
var _action_active := false      # 正在播放非移动动作
var _action_loop := false        # 当前动作是否循环播放
var _jump_air := false           # 跳跃滞空（保持跳跃动画直到落地）
var _cast_timer := 0.0            # 放置施法手势剩余时间（到时恢复移动/Idle）
var _interact := ""                 # "", "sit", "sleep", "climb"（家具互动）
var _interact_top_y := 0.0        # 爬梯目标顶 y

const CHARACTER_SCENE := "res://assets/models/characters/Mage.glb"
# Mage 模型身体（头顶）原始约 2.94m，缩到 0.368 → 角色约 1.08m（门 1.7m 的约 64%）
const CHARACTER_SCALE := 0.368
# KayKit Character Animations 重定向动作库（KayKit 6 骨 → Mage 41 骨烘焙，路径前缀与 Mage.glb 一致）
const KAYKIT_LIB_PATH := "res://assets/animations/kaykit_library.tres"

# 碰撞体尺寸（主体胶囊：凸形状才能与场景 trimesh 地形正常碰撞；凹形 ConcavePolygonShape3D 在 Godot 物理中不支持 CharacterBody 会穿模）
const COLLIDER_RADIUS := 0.28
const COLLIDER_HEIGHT := 1.08
const COLLIDER_OFFSET_Y := 0.54
# 脚底平底薄圆柱：只垫平球面最低点（站突起/石头/树干时脚部不下陷）；
# 必须很薄——太高会在坡面/物体边缘把角色垫起造成浮空
const COLLIDER_FOOT_HEIGHT := 0.05

# ---- 自动抬步（上楼梯/上台沿）----
## 可自动跨上的最大台阶高度（米）。楼梯单级踏面约 0.2~0.25m，留出余量。
const MAX_STEP_HEIGHT := 0.45
## 探针水平前探距离：站在本级踏面上时下一级踏面约在 0.85~0.9m 处，
## 取 0.45m 正好落在下一级踏面中段（起点已抬高 MAX_STEP_HEIGHT，斜向前下方找面）。
const STEP_PROBE_AHEAD := 0.45
## 探针向下探测长度；起点高度为 MAX_STEP_HEIGHT + 该值
const STEP_DROP := 0.9
## 台阶顶面之上需要的净空（米）：角色站立高度 + 余量
const STEP_HEADROOM := 1.25
## 抬步后短暂忽略重力，避免上台阶瞬间被拉回
const STEP_GRACE_TIME := 0.1

## 上一次成功抬步的时间点（毫秒），供相机控制器抑制瞬间重力
var last_step_msec := 0
## 统计信息（测试/调试用）
var step_count := 0
var step_debug := false

# 移动动画
const ANIM_IDLE := "Idle"
const ANIM_WALK := "Walking_A"
const ANIM_RUN := "Running_A"
# 放置物体时施法手势时长（挥舞法杖 loop 动画限时播放）
const CAST_DURATION := 0.9
const CLIMB_SPEED := 1.3          # 爬梯上升速度（米/秒）

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
	["挥手", "kaykit/Wave", "one"],
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
	# KayKit Character Animations 重定向动作（KayKit 6 骨 → Mage 41 骨烘焙）
	["跳舞", "kaykit/Dance", "loop"],
	["攀爬", "kaykit/Climbing", "loop"],
	["翻滚", "kaykit/Roll", "one"],
	["重击", "kaykit/HeavyAttack", "one"],
	["冲刺前", "kaykit/DashFront", "one"],
	["冲刺后", "kaykit/DashBack", "one"],
	["冲刺左", "kaykit/DashLeft", "one"],
	["冲刺右", "kaykit/DashRight", "one"],
	["受击", "kaykit/Defeat", "one"],
	["单跳", "kaykit/Hop", "one"],
	["躺卧", "kaykit/LayingDownIdle", "loop"],
]

func _ready() -> void:
	body = _instantiate_character()
	if body == null:
		body = Node3D.new()
		body.name = "Visual"
		add_child(body)
	body.scale = Vector3.ONE * CHARACTER_SCALE

	# 加载 KayKit 动作库（骨骼重定向烘焙到 Mage 骨架）
	var kk_lib: AnimationLibrary = load(KAYKIT_LIB_PATH)
	if kk_lib != null and anim_player != null:
		anim_player.add_animation_library("kaykit", kk_lib)

	# 角色碰撞体：主体胶囊 + 底部平底圆柱（凸形状组合，底部对齐脚底）
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = COLLIDER_RADIUS
	capsule.height = COLLIDER_HEIGHT
	col.shape = capsule
	col.position = Vector3(0.0, COLLIDER_OFFSET_Y, 0.0)
	add_child(col)

	# 脚底平底薄圆柱：垫平球面最低点，站突起/石头/树干上脚部贴合
	var col2 := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = COLLIDER_RADIUS
	cyl.height = COLLIDER_FOOT_HEIGHT
	col2.shape = cyl
	col2.position = Vector3(0.0, COLLIDER_FOOT_HEIGHT * 0.5, 0.0)
	add_child(col2)

	# 碰撞：层1=玩家；mask 与地形(2)/建筑(4)/植被(8)碰撞
	collision_layer = 1
	collision_mask = 2 | 4 | 8
	# 贴地长度给足：走缓坡与刚跨上台阶时都保持贴地，不被小幅落差抛起
	floor_snap_length = 0.5
	floor_max_angle = deg_to_rad(52.0)

func _physics_process(delta: float) -> void:
	# 施法手势计时：到时自动停止并恢复移动/Idle
	if _cast_timer > 0.0:
		_cast_timer -= delta
		if _cast_timer <= 0.0:
			_action_active = false
			if not _jump_air:
				_update_move_anim()
	# 非循环动作：播放结束后自动回到移动/Idle
	if _action_active and not _action_loop and anim_player != null:
		if not anim_player.is_playing():
			_action_active = false
			if not _jump_air:
				_update_move_anim()
	# 爬梯上升：直到梯顶后结束互动
	if _interact == "climb":
		var ny := minf(global_position.y + CLIMB_SPEED * delta, _interact_top_y)
		global_position.y = ny
		if ny >= _interact_top_y:
			stop_interact()

# ---------- 自动抬步（上楼梯） ----------

## 尝试跨上正前方的低台阶：在移动后调用。
## force=true 供无物理步进的环境（headless 脚本测试）驱动：跳过贴地判定。
## move_dir 为本帧期望的水平移动方向。
## 返回 true 表示成功抬步（调用方应据此抑制重力/重置贴地）。
func try_step_up(move_dir: Vector3, force: bool = false) -> bool:
	if move_dir.length_squared() < 0.0001:
		return false
	if not force and not is_on_floor():
		return false
	var dir := Vector3(move_dir.x, 0.0, move_dir.z).normalized()
	var space := get_world_3d().direct_space_state
	var origin := global_position

	# 单个"前下方"探针，从垫脚高度斜着向前找落脚面：
	# 起点抬高到 MAX_STEP_HEIGHT，向下打 STEP_DROP，水平前探 0.45m。
	# 这样"站在本级踏面上找下一级"与"地面找第一级"是同一种几何，判定一致。
	var probe_from := origin + Vector3.UP * MAX_STEP_HEIGHT + dir * STEP_PROBE_AHEAD
	var down := _cast(space, probe_from, Vector3.DOWN, MAX_STEP_HEIGHT + STEP_DROP)
	if down.is_empty():
		return false
	var step_top: Vector3 = down.position
	var step_normal: Vector3 = down.normal
	var rise := step_top.y - origin.y
	if rise <= 0.02 or rise > MAX_STEP_HEIGHT:
		return false
	if step_normal.angle_to(Vector3.UP) > floor_max_angle:
		return false
	# 净空：踏面之上要有角色身高的空间，否则是头顶被挡的缝隙
	var up := _cast(space, step_top + Vector3.UP * 0.12, Vector3.UP, STEP_HEADROOM)
	if not up.is_empty():
		return false

	# 抬上去：先升后前移，move_and_slide 的贴地会把角色吸回踏面
	global_position = Vector3(
			origin.x + dir.x * 0.22,
			step_top.y + 0.02,
			origin.z + dir.z * 0.22)
	last_step_msec = Time.get_ticks_msec()
	step_count += 1
	return true

## 抬步后的短暂窗口内抑制重力（避免刚上台阶就被拉回）
func in_step_grace() -> bool:
	return Time.get_ticks_msec() - last_step_msec < int(STEP_GRACE_TIME * 1000.0)


func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3,
		length: float = STEP_PROBE_AHEAD) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length)
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return space.intersect_ray(q)


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

## 放置物体时的施法手势：挥舞法杖动画限时播放，到时自动恢复移动/Idle
func play_cast_gesture() -> void:
	if anim_player == null or not anim_player.has_animation("Spellcasting"):
		return
	_action_active = true
	_action_loop = false
	_jump_air = false
	_cast_timer = CAST_DURATION
	anim_player.play("Spellcasting")

## ---------- 家具互动（坐/睡/爬梯） ----------

## 开始家具互动；target 为家具底部中心世界坐标，stand_h 为椅面/床面/梯高
func start_interact(kind: String, target: Vector3, yaw: float, stand_h: float) -> void:
	_cast_timer = 0.0
	_jump_air = false
	_interact = kind
	global_position.x = target.x
	global_position.z = target.z
	body.rotation.y = yaw
	_action_active = true
	_action_loop = true
	match kind:
		"sit":
			global_position.y = target.y + stand_h * 0.55
			anim_player.play("Sit_Floor_Idle")
		"sleep":
			global_position.y = target.y + stand_h * 0.5
			anim_player.play("Lie_Down")
		"climb":
			global_position.y = target.y
			_interact_top_y = target.y + stand_h
			anim_player.play("kaykit/Climbing")

## 退出家具互动（移动键/E 触发），恢复移动/Idle
func stop_interact() -> void:
	if _interact == "":
		return
	_interact = ""
	_action_active = false
	_action_loop = false
	_update_move_anim()

## 是否正在家具互动
func is_interacting() -> bool:
	return _interact != ""

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

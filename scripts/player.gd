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
## 抬步的视觉平滑时长：根部在 smoothstep 曲线上升完这段距离所需时间。
## 20cm 台阶约 0.30s，越大台阶越慢。
const STEP_RISE_PER_METER := 1.5
const STEP_MIN_TIME := 0.24
const STEP_MAX_TIME := 0.55
## 一次抬步的前移量（米）。必须明显小于台阶进深，否则每帧都能探到下一级、
## 接连瞬移，观感就是"飞"上楼梯（旧值 0.22 偏大）。
const STEP_ADVANCE := 0.10
## 两次抬步之间的最小间隔（秒）。0.26s/级 ≈ 0.96m/s 的爬升速度，接近步行。
const STEP_COOLDOWN := 0.26

## 距离上一次成功抬步的时间（秒）
var _step_cooldown := 0.0
## 滞空计时（秒）。落地检测万一漏掉（例如卡在斜坡/物体边缘 is_on_floor 一直为假），
## _jump_air 会永远为真，动画与移动状态机就彻底卡死（"跑一段就推不动了"）。
## 超过这个时长无条件复位。
const AIR_TIMEOUT := 1.4
var _air_time := 0.0

## 抬步平滑：根部已抬到台阶顶，模型的"额外下移量"（米），按缓动曲线收回 0
var _step_visual_offset := 0.0
## 本次抬步平滑的进度（秒）与总时长
var _step_smooth_t := 0.0
var _step_smooth_dur := 0.0
var _step_smooth_start := 0.0
## 本帧抬升的高度（供相机/动画参考）
var last_step_rise := 0.0

## 上一次成功抬步的时间点（毫秒），供相机控制器抑制瞬间重力
var last_step_msec := 0
## 统计信息（测试/调试用）
var step_count := 0
var step_debug := false

# ---- 转向过渡状态 ----
## 本帧水平速度中相对朝向的侧向分量（>0 向右）
var _lateral := 0.0
## 当前侧倾角（弧度），正=向右压弯
var _lean := 0.0
## 转向动画剩余时间
var _turn_timer := 0.0
## 转向动画方向（+1 右 / -1 左）
var _turn_dir := 1.0
## 当前播放的移动动画名（避免每帧重播）
var _move_anim := ""

# 移动动画
const ANIM_IDLE := "Idle"
const ANIM_WALK := "Walking_A"
const ANIM_RUN := "Running_A"
# 转向/侧移过渡动画（KayKit 库：Strafe_Left/Strafe_Right/DashLeft/DashRight）
const ANIM_STRAFE_L := "kaykit/Strafe_Left"
const ANIM_STRAFE_R := "kaykit/Strafe_Right"
const ANIM_TURN_L := "kaykit/DashLeft"
const ANIM_TURN_R := "kaykit/DashRight"
## 侧向速度超过该值改用侧移动画（米/秒）
const LATERAL_ANIM_THRESHOLD := 0.6
## 朝向变化超过该角度（弧度）触发转向动画；越小越敏感
const TURN_ANIM_ANGLE := deg_to_rad(45.0)
## 转向动画/倾斜持续时长（秒）
const TURN_ANIM_TIME := 0.25
## 转向时的最大侧倾角（弧度）——压弯手感
const TURN_LEAN_MAX := deg_to_rad(14.0)
## 侧倾回正速度（弧度/秒）
const TURN_LEAN_RECOVER := 6.0
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
	if _step_cooldown > 0.0:
		_step_cooldown = maxf(0.0, _step_cooldown - delta)
	# 滞空兜底：长时间处于跳跃状态说明落地事件漏了，强制复位状态机
	if _jump_air:
		_air_time += delta
		if _air_time > AIR_TIMEOUT:
			_jump_air = false
			_air_time = 0.0
			_update_move_anim()
	else:
		_air_time = 0.0
	# 抬步视觉平滑：根部已经站上台阶，模型按 smoothstep 缓动追上去。
	# 缓动而非线性衰减：起步慢、中间快、收尾慢 —— 上台阶不再"闪"。
	if _step_smooth_dur > 0.0:
		_step_smooth_t = minf(_step_smooth_t + delta, _step_smooth_dur)
		var st := _step_smooth_t / _step_smooth_dur
		_step_visual_offset = _step_smooth_start * (1.0 - smoothstep(0.0, 1.0, st))
		if _step_smooth_t >= _step_smooth_dur:
			_step_smooth_dur = 0.0
			_step_visual_offset = 0.0
	if body != null:
		body.position.y = -_step_visual_offset
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
	# 节流：连级台阶一次只上一级，否则探针每帧都能探到下一级、一路瞬移上去
	if _step_cooldown > 0.0:
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

	# 落点净空检查：抬步是直接 teleport 的，如果落点被夹在两块碰撞体之间
	# （楔形缝隙），角色会被永久卡死 —— 试玩里实测过。落点不干净就放弃这次抬步。
	var land := Vector3(
			origin.x + dir.x * STEP_ADVANCE,
			step_top.y + 0.02,
			origin.z + dir.z * STEP_ADVANCE)
	if not _landing_clear(space, land):
		return false
	# 抬上去：物理立即上台（保证碰撞正确），模型用视觉偏移"滑"上去
	global_position = land
	last_step_rise = rise
	_step_cooldown = STEP_COOLDOWN
	# 根部立即落到台阶顶保证碰撞正确；模型压低 rise，再按缓动曲线收回。
	# 平滑时长按抬升高度换算（越高越慢），上限避免大台阶拖得太久。
	_step_visual_offset = rise
	_step_smooth_t = 0.0
	_step_smooth_start = rise
	_step_smooth_dur = clampf(rise * STEP_RISE_PER_METER, STEP_MIN_TIME, STEP_MAX_TIME)
	last_step_msec = Time.get_ticks_msec()
	step_count += 1
	if step_debug:
		print("[step] rise=%.3f smooth=%.2fs" % [rise, _step_smooth_dur])
	return true

## 抬步后的短暂窗口内抑制重力（避免刚上台阶就被拉回）
func in_step_grace() -> bool:
	return Time.get_ticks_msec() - last_step_msec < int(STEP_GRACE_TIME * 1000.0)

## 视觉上模型所在的世界高度。
## 抬步是把根部瞬移到台阶顶、再把模型压下去缓动追上来，所以模型真正的
## 高度是 global_position.y + body.position.y（body.position.y 为负）。
## 相机必须跟这个值，否则上台阶时镜头会先猛跳一下再被模型追平。
func visual_height() -> float:
	var off := 0.0
	if body != null:
		off = body.position.y
	return global_position.y + off

## 是否正在抬步缓动中（供相机/动画判断）
func is_step_smoothing() -> bool:
	return _step_smooth_dur > 0.0


## 抬步落点是否干净：用一个略瘦的胶囊做形状查询，碰到墙就不算干净。
func _landing_clear(space: PhysicsDirectSpaceState3D, land: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	shape.radius = COLLIDER_RADIUS * 0.85
	shape.height = maxf(shape.radius * 2.0 + 0.05, COLLIDER_HEIGHT * 0.85)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	q.transform = Transform3D(Basis.IDENTITY, land + Vector3(0.0, shape.height * 0.5, 0.0))
	return space.intersect_shape(q, 1).is_empty()


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

# ---------- 转向过渡 ----------

## 由相机控制器每帧告知：相对朝向的侧向速度（右为正）与朝向变化量（弧度，右为正）
func set_lateral(lateral: float) -> void:
	_lateral = lateral


## 朝向发生明显变化时调用（由相机控制器在转身时触发）
func notify_facing_change(angle_delta: float) -> void:
	if absf(angle_delta) < TURN_ANIM_ANGLE:
		return
	_turn_dir = signf(angle_delta)
	_turn_timer = TURN_ANIM_TIME
	# 转向瞬间给一个侧倾冲量，随后回正
	_lean = clampf(_lean - _turn_dir * TURN_LEAN_MAX, -TURN_LEAN_MAX, TURN_LEAN_MAX)
	# 移动中才播转向动作，站立转向只靠侧倾
	if _moving and not _action_active and not _jump_air:
		_play_move_anim(ANIM_TURN_L if _turn_dir > 0.0 else ANIM_TURN_R)


## 每帧推进转向状态：计时衰减 + 侧倾回正 + 应用到模型
func update_turn(delta: float, moving: bool, running: bool) -> void:
	if _turn_timer > 0.0:
		_turn_timer -= delta
	# 侧倾回正
	_lean = move_toward(_lean, 0.0, TURN_LEAN_RECOVER * delta)
	if body != null:
		body.rotation.z = _lean
	# 转向动画结束后回到正常移动动画
	if _turn_timer <= 0.0 and moving and not _action_active and not _jump_air:
		var want := ANIM_RUN if running else ANIM_WALK
		if absf(_lateral) > LATERAL_ANIM_THRESHOLD:
			want = ANIM_STRAFE_R if _lateral > 0.0 else ANIM_STRAFE_L
		_play_move_anim(want)


## 播放移动类动画（同名前不重播，避免动画抖动）
## 缺失的剪辑回退到 Idle，绝不能"什么都不播" —— 否则角色会定格成滑行。
func _play_move_anim(name: String) -> void:
	if _move_anim == name:
		return
	if anim_player != null and not anim_player.has_animation(name):
		if anim_player.has_animation(ANIM_WALK):
			name = ANIM_WALK
		elif anim_player.has_animation(ANIM_IDLE):
			name = ANIM_IDLE
		else:
			return
	_move_anim = name
	_play_anim(name)


## 当前侧倾角（供测试/调试）
func get_lean() -> float:
	return _lean


## 当前模型朝向 yaw（供相机控制器检测转身）
func get_facing_yaw() -> float:
	return body.rotation.y if body != null else rotation.y

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
		if absf(_lateral) > LATERAL_ANIM_THRESHOLD and _turn_timer <= 0.0:
			_play_move_anim(ANIM_STRAFE_R if _lateral > 0.0 else ANIM_STRAFE_L)
		else:
			_play_move_anim(ANIM_RUN if _running else ANIM_WALK)
	else:
		_move_anim = ANIM_IDLE
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

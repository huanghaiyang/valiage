class_name Player
extends CharacterBody3D
## 玩家角色：第三方模型（KayKit Adventurers - Mage，CC0）
## CharacterBody3D + 胶囊碰撞（凸形状，兼容场景三角碰撞地形），由 CameraRig 用 move_and_slide 驱动（走物理碰撞）
## 动作系统：ACTION_LIB 动作注册表 + 一次性/循环动作播放 + 移动状态联动（走/跑/跳）

var body: Node3D
var anim_player: AnimationPlayer = null
## 手持法杖（挂在右手 handslot_r 骨骼上，负责悬浮/自转/元素粒子）
## 手持法杖（挂在右手 handslot_r 下，见 _attach_held_staff）
var held_staff: Node = null
## 角色自带的手持道具节点（自带法杖/魔杖/法书，装自定义法杖时要藏起来）
var _native_props: Array[Node3D] = []
var _moving := false
var _running := false
var _action_active := false      # 正在播放非移动动作
var _action_loop := false        # 当前动作是否循环播放
var _jump_air := false           # 跳跃滞空（保持跳跃动画直到落地）
var _cast_timer := 0.0            # 放置施法手势剩余时间（到时恢复移动/Idle）
## 持续施法中（法术系统驱动，见 start_spell_cast / stop_spell_cast）。
## 与 _cast_timer 的区别：那是**一次性**放置手势（0.9s 自动恢复）；
## 这是**按住施法键期间持续**的状态——法术本身是按住持续施放的，动画必须同寿。
var _spell_casting := false
var _interact := ""                 # "", "sit", "sleep", "climb"（家具互动）
var _interact_top_y := 0.0        # 爬梯目标顶 y

const CHARACTER_SCENE := "res://assets/models/characters/Mage.glb"
# Mage 模型身体（头顶）原始约 2.94m，缩到 0.368 → 角色约 1.08m（门 1.7m 的约 64%）
const CHARACTER_SCALE := 0.368

# ---- 跑动脚底灰尘：实现已抽到独立文件 scripts/run_dust.gd（尺寸/颜色等参数都在那边）----
const DUST_SPEED_MIN := 0.8      # 低于这个水平速度不扬尘（camera_rig 用它换算强度）
var _dust: Node3D = null            # 灰尘容器（内部左右脚各一个 GPUParticles3D）
# KayKit Character Animations 重定向动作库（KayKit 6 骨 → Mage 41 骨烘焙，路径前缀与 Mage.glb 一致）
const KAYKIT_LIB_PATH := "res://assets/animations/kaykit_library.tres"

# 碰撞体尺寸（主体胶囊：凸形状才能与场景 trimesh 地形正常碰撞；凹形 ConcavePolygonShape3D 在 Godot 物理中不支持 CharacterBody 会穿模）
const STEP_MAX_ANGLE := 0.907571    # 抬步上限 52 度（与抗抖动的 floor_max_angle 解耦）
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
## 动画看门狗计时（见 _watch_move_anim）
var _anim_watch := 0.0

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
## 施法动画名。必须是 Mage.glb 自带、且已列入 LOOP_CLIPS 的剪辑 ——
## 不在 LOOP_CLIPS 里的话 loop_mode 仍是 LOOP_NONE，循环播放会定格在末帧。
const CAST_ANIM := "Spellcasting"
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

## 物理参数在 _init 里设：与模型/动画是否加载成功**无关**（放 _ready 里会因为前半段
## 加载失败而整段跳过 -> 角色退化成引擎默认参数，行走抖动/被弹开就会复现）。
func _init() -> void:
	# ★ 抗抖动参数组（三角网地形 + 逐面法线场景下调优）
	# floor_snap_length：0.5 太大 —— 边缘/台阶附近会被猛拽，还会和坡面法线互相拉扯
	floor_snap_length = 0.15
	# floor_max_angle：52° 太陡 —— 三角网上那些斜面会被当成"地面"，角色被斜法线推开（被弹开）
	floor_max_angle = deg_to_rad(50.0)
	# safe_margin：默认 0.001 太紧，三角网容易互相穿插 -> move_and_slide 去穿插时"瞬间弹走"
	safe_margin = 0.01
	# wall_min_slide_angle：这是"小突起卡住"的**主因** —— 25 度太大时，突起侧面（通常 >25 度）
	# 会被判成"墙且不许滑"，角色直接顶死。抗抖动已由平滑法线负责，这里回到 10 度保通过性。
	wall_min_slide_angle = deg_to_rad(10.0)
	max_slides = 6
	slide_on_ceiling = false
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED


## ------------------------------------------------------------------ 跑动脚底灰尘
## 实现已抽到独立文件 scripts/run_dust.gd（它本身就是那个粒子节点）。
## 这里只负责：按需创建 + 把强度转发过去。
const RunDustScript := preload("res://scripts/run_dust.gd")


func _setup_dust() -> void:
	# ★ 放在 _ready 最前：与角色模型加载解耦（模型没加载出来也有灰尘）
	# ★ headless 下创建粒子进树会把进程卡住（见 run_dust.gd 的说明）-> 直接跳过
	if not RunDustScript.is_supported():
		return
	_dust = RunDustScript.new()
	_dust.name = "RunDust"
	add_child(_dust)


## 由 camera_rig 每物理帧调用。ratio = 0~1 的扬尘强度（按**实际水平速度**算好传进来）
func update_dust(ratio: float) -> void:
	if _dust == null:
		return
	if _dust.has_method("set_intensity"):
		_dust.call("set_intensity", ratio)

func _ready() -> void:
	# 进 group 后 spell_caster / Vitals 这类"找玩家"的代码可以走快路径，不必再按名字递归搜
	add_to_group("player")
	_setup_dust()                 # ★ 放在最前：与角色模型加载**解耦**（加载失败也照样有灰尘，方便自检）
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
	_ensure_loop_anims()

	# ★ 碰撞体与物理参数**不依赖动画节点**，必须无条件建立（原来放在 _ensure_loop_anims 的
	#   早退之后：anim_player 为空时角色连碰撞体都没有、参数全落回默认 —— 结构性隐患）
	# 角色碰撞体：主体胶囊 + 底部平底圆柱（凸形状组合，底部对齐脚底）
	var col := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = COLLIDER_RADIUS
	capsule.height = COLLIDER_HEIGHT
	col.shape = capsule
	col.position = Vector3(0.0, COLLIDER_OFFSET_Y, 0.0)
	add_child(col)

	# ★ 脚底：**圆底短胶囊**（原来是平底 CylinderShape3D）
	#   平底撞到地面小突起时没有任何滑移余地 -> 直接卡住（用户报的"遇小突起无法前进"）。
	#   圆底能自然滑过几厘米的突起；因为角色不旋转，圆底也不会"滚动"，站石头上照样稳。
	#   底端与原来的圆柱对齐（底端 = 0），高度 = 圆柱高度 + 两个半球。
	var col2 := CollisionShape3D.new()
	var foot := CapsuleShape3D.new()
	foot.radius = COLLIDER_RADIUS
	foot.height = COLLIDER_RADIUS * 2.0 + COLLIDER_FOOT_HEIGHT
	col2.shape = foot
	col2.position = Vector3(0.0, foot.height * 0.5, 0.0)
	add_child(col2)

	# 碰撞：层1=玩家；mask 与地形(2)/建筑(4)/植被(8)碰撞
	collision_layer = 1
	collision_mask = 2 | 4 | 8



## 把"本来就该循环"的剪辑设成循环播放。
##
## **这是"跑一段后动画静止"的真因。** Mage.glb 导入进来的 76 个动画、
## 以及 kaykit_library.tres 里那 12 个，`loop_mode` **全部是 0（LOOP_NONE）**：
##
##     Idle       len=1.067 loop=0
##     Walking_A  len=1.067 loop=0
##     Running_A  len=0.800 loop=0     <- 跑 0.8 秒播完就停住
##
## 于是跑动 0.8 秒后剪辑走到末尾、AnimationPlayer 停下，角色定格在最后一帧 ——
## 表现就是"跑一段就静止"，而且时长和剪辑长度完全对得上。
## 站着不动 1.067 秒后也会同样定格。
##
## 为什么不在导入设置里改：该循环的只有十来个剪辑，剩下几十个（攻击/受击/坐下/死亡）
## 本来就该播一次停住；逐个导入设置反而容易漏。这里用白名单，一眼能看出意图。
const LOOP_CLIPS := [
	"Idle", "Unarmed_Idle", "2H_Melee_Idle", "Blocking",
	"Walking_A", "Walking_B", "Walking_C", "Walking_Backwards",
	"Running_A", "Running_B", "Running_Strafe_Left", "Running_Strafe_Right",
	"Jump_Idle", "Sit_Chair_Idle", "Sit_Floor_Idle", "Lie_Idle", "Spellcasting",
	"kaykit/DashLeft", "kaykit/DashRight", "kaykit/LayingDownIdle",
]


func _ensure_loop_anims() -> void:
	if anim_player == null:
		return
	var fixed := 0
	for n in LOOP_CLIPS:
		if not anim_player.has_animation(n):
			continue
		var a := anim_player.get_animation(n)
		if a != null and a.loop_mode != Animation.LOOP_LINEAR:
			a.loop_mode = Animation.LOOP_LINEAR
			fixed += 1
	print("[player] 循环动画已修正 %d 个（原本全是 LOOP_NONE）" % fixed)



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
	# 动画看门狗：兜底，真因见 _ensure_loop_anims
	_watch_move_anim(delta)
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
	# ★ 被小突起顶住时 is_on_floor 往往已经为假 -> 老写法会让抬步彻底不触发（卡死）。
	#   改成"在地面上 **或** 正贴着什么东西"都允许尝试抬步。
	if not force and not is_on_floor() and get_slide_collision_count() == 0:
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
	# 抬步用**自己的**上限（STEP_MAX_ANGLE）：抗抖动把 floor_max_angle 收到 45 度后，
	# 若继续借用它，原本能跨的陡台阶就跨不上去了（副作用隔离）
	if step_normal.angle_to(Vector3.UP) > STEP_MAX_ANGLE:
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
	_attach_held_staff(inst)
	return inst


## 把可替换的法杖挂到右手骨骼上。Mage 模型自带 1H_Wand / 2H_Staff / Spellbook，
## 装上自定义法杖时先把它们藏起来，免得两根杖叠在一起。
func _attach_held_staff(inst: Node) -> void:
	_native_props.clear()
	for nm in ["1H_Wand", "2H_Staff", "Spellbook", "Spellbook_open"]:
		var p := inst.find_child(nm, true, false)
		if p is Node3D:
			_native_props.append(p as Node3D)
	var slot := inst.find_child("handslot_r", true, false)
	if slot == null:
		push_warning("[staff] 角色没有 handslot_r 骨骼，法杖无法挂载")
		return
	held_staff = load("res://scripts/held_staff.gd").new()
	held_staff.name = "HeldStaff"
	# 位置与朝向都归零：尺寸/握点/前倾角全由 HeldStaff 自己按目标长度与世界方向算
	held_staff.position = Vector3.ZERO
	held_staff.rotation_degrees = Vector3.ZERO
	slot.add_child(held_staff)
	var sys := _staff_system()
	if sys != null:
		_apply_staff(str(sys.get("equipped")), int(sys.get("equipped_element")))
		sys.connect("staff_equipped", _on_staff_equipped)


## 切换手持法杖（id 为空表示收起）
func _apply_staff(id: String, elem: int) -> void:
	if held_staff == null:
		return
	held_staff.set_staff(id, elem)
	# 有自定义法杖时藏掉模型自带的手持道具
	var hide_native := id != ""
	for p in _native_props:
		if is_instance_valid(p):
			p.visible = not hide_native


## 运行期取法杖系统。**不要直接写 autoload 标识符 StaffSystem**：那样 player.gd 在
## autoload 未注册的编译上下文里（--script 探针、依赖链编译）会直接编译失败。
func _staff_system() -> Node:
	return get_node_or_null("/root/StaffSystem")


func _on_staff_equipped(id: String) -> void:
	var sys := _staff_system()
	_apply_staff(id, int(sys.get("equipped_element")) if sys != null else 0)


## 供外部（技能/长老仪式）触发杖头闪光
func flash_staff(strength: float = 1.6) -> void:
	if held_staff != null:
		held_staff.flash(strength)


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

## 转向平滑：转场景时移动方向（相对屏幕）会变，角色若**瞬间**赋值朝向，
## 就是"一帧甩到新方向"——法杖挂在手上、以手为轴扫过去，看着像在绕圈
## （用户："玩家移动时，旋转场景，怎么法杖也跟着转圈"）。
## 打开后按 turn_speed_deg 逐帧转过去，观感是"转身"而不是"甩"。
@export var smooth_turn := true
@export var turn_speed_deg := 900.0

## 角色面向水平移动方向（Mage 模型 +Z 为面部前方）
func face_direction(face: Vector3) -> void:
	if body == null:
		return
	var target := atan2(face.x, face.z)
	if not smooth_turn:
		body.rotation.y = target
		return
	var rate := deg_to_rad(turn_speed_deg) * get_process_delta_time()
	body.rotation.y = rotate_toward(body.rotation.y, target, rate)

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


## 播放移动类动画（同一个剪辑且**确实还在播**才跳过，避免动画抖动）
## 缺失的剪辑回退到 Idle，绝不能"什么都不播" —— 否则角色会定格成滑行。
##
## 注意判据**不能只看名字**：`_move_anim == name` 就早退的话，
## "动作/跳跃动画播完后要恢复跑步"这条恢复路径会被自己挡住 ——
## 名字没变、但 AnimationPlayer 已经停了，于是角色永远定格。
## 必须再确认"当前正在播的剪辑就是它"。
func _play_move_anim(name: String) -> void:
	if _move_anim == name and anim_player != null \
			and anim_player.is_playing() and anim_player.current_animation == name:
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


## 动画看门狗：兜底用。
##
## 真因已经修掉了（剪辑不循环，见 _ensure_loop_anims），但"角色定格不动"
## 这种表现很难一眼看出原因、排查成本又高，所以再加一道保险：
## **在移动、没在播动作、没滞空，动画却没在播（或播的不是当前该播的剪辑）**
## → 强制重播，并打一条 warning 方便以后顺藤摸瓜。
func _watch_move_anim(delta: float) -> void:
	if anim_player == null:
		return
	_anim_watch += delta
	if _anim_watch < 0.2:
		return
	_anim_watch = 0.0
	if _action_active or _jump_air or not _moving or _move_anim == "":
		return
	if anim_player.is_playing() and anim_player.current_animation == _move_anim:
		return
	push_warning("[player] 移动动画停了（应为 %s，当前 %s）—— 看门狗强制重播"
			% [_move_anim, str(anim_player.current_animation)])
	anim_player.play(_move_anim)


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
	# ★ 持续施法例外：法术在移动途中照样喷（spell_caster 不会因移动停手），
	#   动画若被走路顶掉，就成了"火在喷、人却在走"的错位。
	if m and _action_active and not _spell_casting:
		_action_active = false
		_action_loop = false
	if _action_active or _jump_air:
		return
	_update_move_anim()

## 当前是否处于"加速"状态（camera_rig 每帧告知 = 按住 Shift）。
## 精力值系统读它；注意它只代表"按着加速键"，是否真在跑还要结合 velocity 判断。
func is_running() -> bool:
	return _running


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
	# 持续施法期间不让放置手势抢动画状态：_cast_timer 一旦跑起来，它会到点把
	# _action_active 清零（见 _physics_process 的"施法手势计时"段），正在循环的
	# 施法动画会被当场打断 —— 而法术其实还在喷。
	if _spell_casting:
		return
	if anim_player == null or not anim_player.has_animation(CAST_ANIM):
		return
	_action_active = true
	_action_loop = false
	_jump_air = false
	_cast_timer = CAST_DURATION
	anim_player.play(CAST_ANIM)

# ---------- 持续施法（法术系统驱动，见 scripts/spells/spell_caster.gd） ----------

## 开始/维持持续施法。法术系统每帧调用，**内部做了幂等**：
## 只有当前剪辑不是施法动画时才 play() —— 直接每帧 play() 会把剪辑重置回第一帧，
## 看起来就是"卡在起手式抖动"。幂等还有第二个好处：起跳等打断之后能自动把姿势找回来。
func start_spell_cast() -> void:
	if anim_player == null or not anim_player.has_animation(CAST_ANIM):
		return
	if not _spell_casting:
		_spell_casting = true
		# 清掉放置手势计时，否则它到点会把 _action_active 清零、打断这次的循环施法
		_cast_timer = 0.0
	# 滞空期间不抢跳跃动画，落地后下一帧自然会恢复施法姿势
	if _jump_air:
		return
	_action_active = true
	_action_loop = true
	if anim_player.current_animation != CAST_ANIM or not anim_player.is_playing():
		anim_player.play(CAST_ANIM)

## 结束持续施法（松手 / 换法术 / 取消选中）。恢复移动 / Idle。
func stop_spell_cast() -> void:
	if not _spell_casting:
		return
	_spell_casting = false
	_action_active = false
	_action_loop = false
	# 坐在家具上时不要抢回移动动画，交给家具互动状态机
	if not _jump_air and _interact == "":
		_update_move_anim()

## 是否正在持续施法
func is_spell_casting() -> bool:
	return _spell_casting

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

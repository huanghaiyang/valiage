# ============================================================================
# scripts/player.gd —— 玩家角色控制器（CharacterBody3D）
# ----------------------------------------------------------------------------
# 【职责】本文件是"玩家"这个实体的**装配中心 + 表现层状态机**，共五块：
#   1) 角色装配：按 character_id 读档案 → 实例化模型 → 按目标身高自动缩放
#      → 计算并建立胶囊碰撞体 → 把"本来就该循环"的动画剪辑设为循环；
#   2) 移动/转向表现：走/跑/侧移/转身压弯 对应的动画状态机
#      （**注意：本文件不负责位移计算**，位移由 camera_rig 调 move_and_slide 驱动）；
#   3) 自动抬步 try_step_up()：正前方 ≤MAX_STEP_HEIGHT 的低台阶直接抬上去；
#   4) 手持法杖的挂载与握点决策（手调 staff_grip_local / 自动拳心 / 骨骼回退）；
#   5) 握点调试可视化与一次性自检日志（默认全部关闭，见各 debug_* 开关）。
#
# 【所属系统 / 上下游】
#   玩家侧：scripts/player.gd（本文件）
#           ＋ scripts/run_dust.gd（脚底灰尘，已抽成独立文件，本文件只转发强度）
#           ＋ scripts/held_staff.gd（法杖节点：摆放/悬浮/朝向稳定/光效）
#           ＋ scripts/character_profile.gd（角色档案：模型路径/身高/动画库/挂点/握持角）
#   驱动方：scripts/camera_rig.gd —— 每个物理帧调用
#           set_moving() / set_running() / face_direction() / set_lateral() /
#           notify_facing_change() / update_turn() / update_dust()，
#           跳跃时调 on_jump()/on_land()，贴地移动后调 try_step_up()；
#           并读取 visual_height() / is_step_smoothing() / in_step_grace() /
#           get_facing_yaw() / get_lean() / is_running()。
#   法术侧：scripts/spells/spell_caster.gd —— 调 start_spell_cast()/stop_spell_cast()，
#           读 is_spell_casting()。
#   装备侧：autoload StaffSystem（换杖信号 staff_equipped → _on_staff_equipped）。
#
# 【关键依赖】
#   * autoload：/root/StaffSystem。**只能**用 get_node_or_null 取（见 _staff_system()
#     的说明）：直接写标识符 StaffSystem 会让 player.gd 在 autoload 未注册的编译
#     上下文（--script 无头探针 / 依赖链编译）里直接编译失败。
#   * 场景组：_ready() 里 add_to_group("player")，供 spell_caster / Vitals 这类
#     "找玩家"的代码走快路径（否则要按名字递归搜场景树）。
#   * preload：res://scripts/character_profile.gd、res://scripts/run_dust.gd、
#     res://scripts/held_staff.gd（法杖节点在 _attach_held_staff 里 load 后 new）。
#   * 资源路径：档案里的 scene（角色 .glb）与 lib（动画库 .tres）；
#     旧角色回退库 res://assets/animations/kaykit_library.tres。
#   * 信号：StaffSystem.staff_equipped(String) → _on_staff_equipped()。
#   * 文档：握点/朝向/坐标系的历史坑与不变量见
#     docs/法杖握持与朝向系统-技术文档.md（本文件相关章节：握点优先级、单位换算、
#     偏移承载位置、调试可视化、回归指标）。
#
# 【主要对外接口】（其它脚本可调用的公开方法）
#   移动/朝向：set_moving / set_running / is_running / face_direction /
#              set_lateral / notify_facing_change / update_turn /
#              get_lean / get_facing_yaw
#   跳跃/抬步：on_jump / on_land / try_step_up / in_step_grace /
#              visual_height / is_step_smoothing
#   表现杂项：update_dust / set_body_visible / flash_staff
#   动作菜单：get_action_lib / play_action / stop_action / play_cast_gesture
#   持续施法：start_spell_cast / stop_spell_cast / is_spell_casting
#   家具互动：start_interact / stop_interact / is_interacting
#
# 【已知的坑与注意事项】
#   * 物理参数必须写在 _init()，**不能**放 _ready()：_ready() 前半段（模型/动画加载）
#     一旦失败会整段跳过，物理参数就落回引擎默认值 → 行走抖动 / 被弹开复发。
#   * 碰撞体与物理参数**不依赖 anim_player**，必须无条件建立（历史上放在
#     _ensure_loop_anims 的早退之后，anim_player 为空时角色连碰撞体都没有）。
#   * 本文件是 GDScript，**缩进敏感**：补注释不要落在多行表达式的中间，
#     否则会把表达式截断成语法错误。
#   * 法杖握点的"唯一真相"是 @export var staff_grip_local（**手骨本地坐标**，
#     Vector3.ZERO = 改用自动算法）；偏移由 HeldStaff.position 承载，
#     绝不能再加到 _model.position 上（双重偏移/方向被杖的朝向带歪）。
#   * 多种状态共享 _action_active / _action_loop / _jump_air / _cast_timer /
#     _spell_casting，改动其中之一前先看清它们之间的互斥关系（注释里逐条标了）。
# ============================================================================
class_name Player
extends CharacterBody3D
## 角色档案模块（用 preload 常量而不是全局类名：--script/无头环境不会重建全局类表，class_name 会找不到）
const CharProfile := preload("res://scripts/character_profile.gd")
## 玩家角色：第三方模型（KayKit Adventurers - Mage，CC0）
## CharacterBody3D + 胶囊碰撞（凸形状，兼容场景三角碰撞地形），由 CameraRig 用 move_and_slide 驱动（走物理碰撞）
## 动作系统：ACTION_LIB 动作注册表 + 一次性/循环动作播放 + 移动状态联动（走/跑/跳）

# ==================== 成员：节点引用与运行时状态 ====================
## 角色可视模型根节点（_instantiate_character() 产出的 "Visual" 实例；模型加载失败时
## 退化成空 Node3D 以免后续判空满天飞）。
## 两个约定：① 缩放是"把模型缩到档案目标身高"用的，别再把它当 1；
## ② 抬步平滑会让它在**根节点**已站上台阶后额外下移，下移量恒 ≤0 且写在 body.position.y，
## 所以"视觉高度"必须用 visual_height()（= global_position.y + body.position.y）取。
var body: Node3D
## 角色动画播放器：模型自带优先（_find_animation_player 递归找），没有就新建一个挂在
## 模型根下（见 _instantiate_character）。**允许为 null**（模型加载失败时），
## 因此所有动画相关分支都要先判空；null 时角色应仍能移动/碰撞（这是刻意保留的降级路径）。
var anim_player: AnimationPlayer = null
## 手持法杖（挂在右手 handslot_r 骨骼上，负责悬浮/自转/元素粒子）
## 手持法杖（挂在右手 handslot_r 下，见 _attach_held_staff）
var held_staff: Node = null
## 角色自带的手持道具节点（自带法杖/魔杖/法书，装自定义法杖时要藏起来）
var _native_props: Array[Node3D] = []
## 本帧是否在水平移动（由 camera_rig 每帧通过 set_moving() 告知）。
## 只代表"有移动"，**不代表动画正在播** —— 动作/施法/家具互动会暂时压制移动动画。
var _moving := false
## 是否处于"加速"状态（由 camera_rig 每帧通过 set_running() 告知 = 按住 Shift）。
## 默认 false：进游戏站着不动时应当是 Idle。改 true 会让初始就播跑步动画。
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

## 角色档案 id（见 scripts/character_profile.gd）：换模型只改这里，或加一份档案
## "zhujue" = 主角（唯一；旧的 KayKit "mage" 档案也在，便于回退对比）
@export var character_id := "zhujue"
## 本角色解析后的档案字典（由 _ready 用 CharProfile.get_profile(character_id) 取得）。
## 键：scene / height / lib / label / hand_bones / staff_hold_rot_deg（缺键时各处都有默认值）。
## 载体是 Dictionary 而不是自定义类：档案模块是纯静态表，运行时只读，不需要实例。
var _profile: Dictionary = {}
## 本次角色的目标身高（米）
var target_height := 1.5
## 自动算出的模型缩放（把模型缩到目标身高）
var _auto_scale := 1.0
## 动画库前缀（库不是加在默认库上时才非空）
var _lib_prefix := ""
## 当前动画库里所有剪辑名（映射值写成数组时用来挑"库里存在的那个"）
var _clip_names := PackedStringArray()
## 调试：在右手挂点上渲染一个红球（判断挂点有没有真的跟着手骨）。
## 排查"法杖脱离手臂"时打开过，现在关掉；需要再开就设成 true
@export var debug_hand_socket := false
## 调试：在握点渲染"与杖同粗、同朝向"的半透明圆柱（穿透显示），
## 用来目视核对 ①握点位置 ②杖轴朝向 ③半径补偿。测试用，默认开，改完可关。
@export var debug_grip_cylinder := false
## 法杖在手里上下翻转 180°。**本项目的法杖：false = 杖头向上** ✓（你实测确认）
## 换别的法杖模型如果杖头朝下，把它改成 true
@export var staff_flip_in_hand := false
## 握点比例（从杖底往上）：0.32 = 下三分之一处；翻转时自动取反
@export var staff_grip_frac := 0.6
## 杖身半径外移（米）：手掌握杖时杖"轴"应在掌心外侧约一个半径处，否则杖身插进手里。
## 0 = 不偏移；正负号不合就传负值。法杖越粗这个值越大（实测杖径见日志）。
@export var staff_grip_out := 0.0
## ★ 握点（**手骨本地坐标**，骨内单位）—— 这是唯一的握点来源：
##   运行时会在这个位置渲染一个**透明小球**，法杖的杖身轴线就穿过去（法杖跟着小球走）。
##   调法：运行游戏 → 检查器里改这个 Vector3 → 小球与法杖**实时一起移动** → 满意后记下数值。
##   Vector3.ZERO = 改用自动算法（网格掌心中心 → 骨骼算法回退）。
@export var staff_grip_local := Vector3.ZERO
## 握点小球半径（米）：只在下面两个调试开关打开时才画 ✓
@export var staff_grip_marker_r := 0.035
## 调试①：青色小球 = 法杖轴线穿过的握点（`staff_grip_local`）—— **默认关闭** ✓
@export var debug_grip_marker := false
## 调试②：橙色玻璃球 = 包住整个拳头的实时拳心（半径按骨点最大距离算）—— **默认关闭** ✓
@export var debug_fist_sphere := false
## 调试③：**握点相关的诊断日志总开关**（默认关闭 ✓ 需要排查时打开 ✓）
## 收进去的：`[staff] 握点/掌心偏移`、`[握持对照]`、`[拳心] 自动标定`、`[握点核对]`、
##           `[法杖自检]`、`[外八自检]`、`[站姿自检]`、`HeldStaff | 握点比例/悬浮基准`
@export var debug_verbose := false
## 法杖「松握」程度：1 = 朝向世界稳定（跑动时杖不再跟着手臂前后甩 ✓），0 = 旧的刚性跟随 ✗
@export var staff_world_stable := 1.0
## 稳定时杖的前后倾角（度）：正值 = 杖头朝前 / 杖尾向后（沿角色朝向 ✓）
@export var staff_world_lean_deg := 0.0
## ★ 跑动时额外的杖身倾角（度，按速度 0→1 渐变）：正 = 杖头朝前、**杖尾向后拖** ✓（更自然 ✓）
@export var staff_run_lean_deg := 12.0
## 沿手指方向的握点系数（仅当 staff_grip_local == ZERO 时用于自动算法）
@export var staff_grip_along := 1.0
const CHARACTER_SCENE := "res://assets/models/characters/Mage.glb"   # 旧默认，仅作回退参考
# Mage 模型身体（头顶）原始约 2.94m，缩到 0.368 → 角色约 1.08m（门 1.7m 的约 64%）
const CHARACTER_SCALE := 0.368

# ---- 跑动脚底灰尘：实现已抽到独立文件 scripts/run_dust.gd（尺寸/颜色等参数都在那边）----
const DUST_SPEED_MIN := 0.8      # 低于这个水平速度不扬尘（camera_rig 用它换算强度）
var _dust: Node3D = null            # 灰尘容器（内部左右脚各一个 GPUParticles3D）
# KayKit Character Animations 重定向动作库（KayKit 6 骨 → Mage 41 骨烘焙，路径前缀与 Mage.glb 一致）
const KAYKIT_LIB_PATH := "res://assets/animations/kaykit_library.tres"

# 碰撞体尺寸（主体胶囊：凸形状才能与场景 trimesh 地形正常碰撞；凹形 ConcavePolygonShape3D 在 Godot 物理中不支持 CharacterBody 会穿模）
const STEP_MAX_ANGLE := 0.907571    # 抬步上限 52 度（与抗抖动的 floor_max_angle 解耦）
## 碰撞体尺寸（主体胶囊；运行时按 target_height 重算，见 _ready）
## 半径（米）：_ready 里 = clampf(身高×0.20, 0.20, 0.34)。这些默认值只在 _ready 之前/失败时有效。
var COLLIDER_RADIUS := 0.30
## 胶囊**总高**（米，含两端半球）：_ready 里 = 角色身高。调小会让角色"矮一截"，头能穿进矮洞。
var COLLIDER_HEIGHT := 1.50
## 胶囊中心相对脚底的高度（米）：_ready 里 = 身高 × 0.5，让胶囊底端正好落在 y=0（脚底）。
## 它不是"眼睛高度"，改它只会让整个胶囊上下平移（底端离开地面就会浮空/陷地）。
var COLLIDER_OFFSET_Y := 0.75
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
## 台阶顶面之上需要的净空（米）：角色站立高度 + 余量（运行时按身高重算）
var STEP_HEADROOM := 1.72
## 抬步后短暂忽略重力，避免上台阶瞬间被拉回
const STEP_GRACE_TIME := 0.1
## 抬步的视觉平滑时长：根部在 smoothstep 曲线上升完这段距离所需时间。
## 20cm 台阶约 0.30s，越大台阶越慢。
const STEP_RISE_PER_METER := 1.5
## 抬步平滑时长的下限（秒）：很小的台阶也要有一点过渡，否则仍有"瞬移感"
const STEP_MIN_TIME := 0.24
## 抬步平滑时长的上限（秒）：避免大台阶把模型拖在半空太久（像在飘）
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
## 本次滞空已持续的时长（秒）：只在 _jump_air 为真时累加，一落地立刻清零。
## 它是 AIR_TIMEOUT 那个"兜底复位"的计时器本体；手动复位状态机时也要记得把它清零。
var _air_time := 0.0

## 抬步平滑：根部已抬到台阶顶，模型的"额外下移量"（米），按缓动曲线收回 0
var _step_visual_offset := 0.0
## 本次抬步平滑的进度（秒）与总时长
var _step_smooth_t := 0.0
## 本次抬步平滑的**总时长**（秒）：由抬升高度换算并夹在 [STEP_MIN_TIME, STEP_MAX_TIME]，
## 为 0 表示当前没有抬步平滑在进行（is_step_smoothing() 就是看它）。
var _step_smooth_dur := 0.0
## 本次抬步平滑的**起始偏移量**（米，= 这次抬升的高度 rise）：
## 缓动按 _step_visual_offset = _step_smooth_start × (1 - smoothstep(...)) 衰减到 0。
var _step_smooth_start := 0.0
## 本帧抬升的高度（供相机/动画参考）
var last_step_rise := 0.0

## 上一次成功抬步的时间点（毫秒），供相机控制器抑制瞬间重力
var last_step_msec := 0
## 统计信息（测试/调试用）
var step_count := 0
## 是否打印每次抬步的详情（默认关；打开会每上一级台阶打一行 [step]，爬长楼梯时很吵）
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
## 逻辑动画名（不是实际剪辑名！实际名要经 _clip() 做库前缀 + 档案映射）。
## 逻辑名是"我们想要什么动作"，映射层负责"这个档案里对应哪个剪辑"——换模型时不用改这里。
const ANIM_IDLE := "Idle"
## 走路（循环）。绝大多数动作/施法结束后都回到它或 Idle；它也是"剪辑缺失时的第一回退"
const ANIM_WALK := "Walking_A"
## 跑步（循环）：与走路共用同一条剪辑，靠 RUN_ANIM_SPEED 加速播放来区分（见 _play_move_anim）
const ANIM_RUN := "Running_A"
## 快跑：走和跑共用同一条持剑动作，跑用 1.4× 播放速度（用户规格）
const RUN_ANIM_SPEED := 1.4
# 转向/侧移过渡动画（KayKit 库：Strafe_Left/Strafe_Right/DashLeft/DashRight）
const ANIM_STRAFE_L := "kaykit/Strafe_Left"
## 侧移动画（右）。注意 kaykit_library.tres 里**没有** Strafe_Left/Right，
## 实际会静默回退成 Walking_A（见 turn_anim_enabled 的说明），保留它只是为了将来补库。
const ANIM_STRAFE_R := "kaykit/Strafe_Right"
## 转向动作（左）：实际是"冲刺"剪辑，并非专门的转身动作（默认 turn_anim_enabled = false 不播）
const ANIM_TURN_L := "kaykit/DashLeft"
## 转向动作（右）：同上，是冲刺剪辑
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

# ==================== 初始化：物理参数（_init） ====================
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


# ==================== 跑动脚底灰尘（转发层） ====================
## ------------------------------------------------------------------ 跑动脚底灰尘
## 实现已抽到独立文件 scripts/run_dust.gd（它本身就是那个粒子节点）。
## 这里只负责：按需创建 + 把强度转发过去。
## 尺寸/颜色/落脚步幅等所有可调参数都在 run_dust.gd 顶部，本文件不再重复定义。
const RunDustScript := preload("res://scripts/run_dust.gd")


## 创建灰尘子系统（RunDust 节点 / GPUParticles3D 容器）。由 _ready() 调用。
## 参数：无。返回：无（结果写进成员 _dust）。
## 副作用：headless（无渲染设备）下**什么都不做** —— run_dust.gd 里实测"GPUParticles3D
##   进场景树会把无头进程卡死"，故用 is_supported() 提前退出（_dust 保持 null，
##   于是 update_dust() 也会直接返回）。
## 注意：本函数**没有**"已创建就跳过"的保护，调用两次会在场景里留下两个灰尘节点；
##   _ready() 里恰好调用了两次（见那两处的注释），属于历史遗留，未改动代码。
func _setup_dust() -> void:
	# ★ 放在 _ready 最前：与角色模型加载解耦（模型没加载出来也有灰尘）
	# ★ headless 下创建粒子进树会把进程卡住（见 run_dust.gd 的说明）-> 直接跳过
	if not RunDustScript.is_supported():
		return
	_dust = RunDustScript.new()
	_dust.name = "RunDust"
	add_child(_dust)


## 参数：ratio —— 扬尘强度，0~1（**调用方按实际水平速度换算好**；0 = 不扬尘、粒子不发射）。
## 返回值：无。副作用：转调 _dust.set_intensity(ratio)，影响落脚粒子的数量与缩放。
## 注意：_dust 为 null 时直接返回 —— headless 下 _setup_dust() 不会创建它；另外这里用
##   has_method() 做鸭子类型加固，允许灰尘节点换成别的实现而不报错。
## 由 camera_rig 每物理帧调用。ratio = 0~1 的扬尘强度（按**实际水平速度**算好传进来）
func update_dust(ratio: float) -> void:
	if _dust == null:
		return
	if _dust.has_method("set_intensity"):
		_dust.call("set_intensity", ratio)

# ==================== 初始化：角色装配（_ready） ====================
## Godot 生命周期回调：节点进入场景树、子节点就绪后由引擎调用一次。
## 作用：把"玩家"这个实体装配完整（档案 → 身高/碰撞 → 模型/动画 → 法杖 → 灰尘）。
## 参数：无。返回值：无。调用时机：_init() 之后自动调用，**只调一次**。
## 副作用（按执行顺序）：
##   1) 加入 "player" 组；创建脚底灰尘节点；
##   2) 读角色档案 → 得到 target_height，并据此重算胶囊尺寸与抬步净空
##      （因此换角色/改档案身高后碰撞体会自动跟着变，不用改场景文件）；
##   3) 实例化模型（失败则退化成空 Node3D + CHARACTER_SCALE 兜底缩放）、
##      按档案补挂动画库、修正"本该循环"的剪辑；
##   4) **无条件**建立两个碰撞形状（主体胶囊 + 圆底短胶囊）并设置碰撞层/掩码；
##   5) 把可替换法杖挂到右手挂点，并接上 StaffSystem 的换杖信号。
## 注意事项：
##   * 步骤 4 必须无条件执行，不能放到"动画相关"的早退分支之后（历史隐患，见下方注释）。
##   * 档案用 Dictionary 承载，取键时都写了默认值，键缺失也不会崩。
##   * 本函数不做位移/输入读取：移动输入与 move_and_slide 都在 camera_rig 里。
func _ready() -> void:
	# 进 group 后 spell_caster / Vitals 这类"找玩家"的代码可以走快路径，不必再按名字递归搜
	add_to_group("player")
	_setup_dust()                 # ★ 放在最前：与角色模型加载**解耦**（加载失败也照样有灰尘，方便自检）
	# ---- 角色档案：模型 / 目标身高 / 动画库 / 动作映射（换模型只改 character_id）----
	_profile = CharProfile.get_profile(character_id)
	target_height = float(_profile.get("height", 1.5))
	# 碰撞尺寸按身高等比推：半径 ≈ 身高×0.20（约等于肩宽的一半），再夹到 0.20~0.34 m，
	# 防止极端档案给出不可用的胶囊；胶囊总高 = 身高，偏移取半高使底端正好落在 y=0（脚底）。
	# 注意：这三个变量**不是** const（运行时按 target_height 重算），改档案身高即可生效。
	COLLIDER_RADIUS = clampf(target_height * 0.20, 0.20, 0.34)
	COLLIDER_HEIGHT = target_height
	COLLIDER_OFFSET_Y = target_height * 0.5
	# 抬步净空 = 身高 ×1.15（多留 15% 给头顶动画/头发）。调小会让头顶被挡的缝隙也被判成可抬步，
	# 角色一头钻进矮洞；调大则一些本来能上的台阶会被拒绝。
	STEP_HEADROOM = target_height * 1.15

	# ★ 这是 _setup_dust() 的**第二次**调用（第一次在本函数开头）：
	#   _setup_dust 内部没有"已创建就跳过"的保护 → 实际会创建两个灰尘节点。
	#   （推测是历史上把灰尘提前到最前、又忘了删旧调用留下的；未改动代码，仅在此记录。）
	_setup_dust()                 # ★ 放在最前：与角色模型加载**解耦**（加载失败也照样有灰尘，方便自检）
	# 模型加载失败时退化成空 Node3D：宁可"看不见人"，也要保住物理、碰撞与输入
	# （无头 CI / 缺资源时仍能跑逻辑，后续代码也不必到处判空）。
	body = _instantiate_character()
	if body == null:
		body = Node3D.new()
		body.name = "Visual"
		add_child(body)
		body.scale = Vector3.ONE * CHARACTER_SCALE
	else:
		# _auto_scale 由 _instantiate_character() 量出模型原始高后算出（= 目标身高 / 原始高），
		# 这里只是把它应用到模型根；改档案身高会连带改变这个缩放（模型越大，缩放越小）。
		body.scale = Vector3.ONE * _auto_scale      # 按档案目标身高自动缩放

	# KayKit 库只给"档案没指定动画库"的旧角色挂（森林男用 mixamo.tres）
	# 档案自带 lib（主角 zhujue.tres）时**跳过**：自带库已够用，不必再加载一份 KayKit 重定向库
	# （推测：这样既省加载，也避免同一个 AnimationPlayer 上挂两套来源不同的重定向剪辑）。
	if String(_profile.get("lib", "")) == "":
		var kk_lib: AnimationLibrary = load(KAYKIT_LIB_PATH)
		if kk_lib != null and anim_player != null:
			anim_player.add_animation_library("kaykit", kk_lib)
	# 动画库挂好之后再修正循环模式：_ensure_loop_anims 内部会先用 _clip() 把逻辑名映射成
	# 本档案的实际剪辑名（森林男那套 Mixamo 名字与 KayKit 不同），映射必须已经生效。
	_ensure_loop_anims()

	# ★ 碰撞体与物理参数**不依赖动画节点**，必须无条件建立（原来放在 _ensure_loop_anims 的
	#   早退之后：anim_player 为空时角色连碰撞体都没有、参数全落回默认 —— 结构性隐患）
	# 角色碰撞体：主体胶囊 + 底部平底圆柱（凸形状组合，底部对齐脚底）
	# CapsuleShape3D.height 是"含两个半球的总高"，与角色视觉身高一致；position 取半高
	# 使胶囊底端正好落在脚底平面（y = 0）。改 COLLIDER_* 时三者的关系不能破坏。
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
	# 注意 mask 会被 _cast()/_landing_clear() 复用（射线与形状查询只看这几层），
	# 新增可踩/可撞的层时要同步改这里，否则抬步探针探不到新地形。
	collision_layer = 1
	collision_mask = 2 | 4 | 8



# ==================== 动画循环修正：白名单 LOOP_CLIPS ====================
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


## 遍历白名单 LOOP_CLIPS，把其中**本档案确实存在**且还不是循环的剪辑改成 LOOP_LINEAR。
## 参数：无。返回值：无。调用时机：_ready() 挂完动画库之后调用一次。
## 副作用：
##   * `anim_player.get_animation(clip)` 返回的是**共享的动画资源对象**，改它的
##     loop_mode 会立刻影响正在播放的实例（本次运行内有效，不落盘）；
##   * 打一行 `[player] 循环动画已修正 %d 个`：为 0 说明导入设置本来就对，
##     不为 0 说明正在靠这个运行时兜底（真因与完整解释见上面 LOOP_CLIPS 的注释）。
## 注意事项：
##   * 判据必须用**映射后的剪辑名** `_clip(n)`：森林男的动作库是 Mixamo 重定向来的，
##     逻辑名 Idle/Walking_A 在库里实际叫 Unarmed Idle/Standard Walk；
##   * anim_player 为 null（模型加载失败）时静默返回，不影响碰撞与移动。
func _ensure_loop_anims() -> void:
	if anim_player == null:
		return
	var fixed := 0
	for n in LOOP_CLIPS:
		# ★ 必须用映射后的剪辑名判断：森林男的动作库是 Mixamo 重定向来的，
		#   逻辑名（Idle/Walking_A/Running_A）在库里叫 Unarmed Idle/Standard Walk/Running
		var clip := _clip(n)
		if not anim_player.has_animation(clip):
			continue
		var a := anim_player.get_animation(clip)
		if a != null and a.loop_mode != Animation.LOOP_LINEAR:
			a.loop_mode = Animation.LOOP_LINEAR
			fixed += 1
	print("[player] 循环动画已修正 %d 个（原本全是 LOOP_NONE）" % fixed)



# ==================== 每物理帧主循环（_physics_process） ====================
## Godot 物理帧回调（默认 60Hz，与渲染帧率无关）。本函数只推进**表现层计时器与状态机**：
## 不读输入、不做位移（位移由 camera_rig 在它自己的物理帧里 move_and_slide 驱动）。
## 参数：
##   delta —— 本物理帧时长（秒，60Hz 时约 0.0167）。所有计时器都按它递减，
##            因此改物理帧率不会改变"秒"意义上的时长（比累加 get_process_delta_time 稳）。
## 返回值：无。调用时机：引擎每个物理帧自动调用。
## 副作用（按顺序，顺序本身有意义）：
##   1) 握点相关的调试钩子：_debug_geom_check / _sync_grip_target / _auto_fist_calib /
##      _update_fist_marker（内部各自按开关早退，默认几乎零开销）；
##   2) 递减抬步冷却；推进滞空计时（超过 AIR_TIMEOUT 强制复位状态机）；
##   3) 抬步视觉平滑：把 body.position.y 从负偏移按 smoothstep 收回到 0；
##   4) 放置手势 _cast_timer 到期 → 清 _action_active 并回移动/Idle；
##   5) 非循环动作播完 → 回移动/Idle；再跑一次动画看门狗兜底；
##   6) 爬梯：按 CLIMB_SPEED 抬升，到顶后 stop_interact()。
## 注意事项：
##   * _sync_grip_target 必须排在"任何使用握点/小球"的逻辑之前（本帧改的值本帧生效）。
##   * 第 4/5 步都可能"抢回移动动画"，所以每处都判了 _jump_air / _interact；
##     新增状态时务必同样判断，否则会出现"走路动画顶掉施法/坐姿"的错位。
func _physics_process(delta: float) -> void:
	# ★ 这四个是"每帧都调、内部按调试开关早退"的钩子：默认全关时只有几次函数调用与
	#   bool 判断的开销；只有打开 debug_verbose / debug_fist_sphere 才会真正采样骨骼。
	_debug_geom_check()
	_sync_grip_target()
	_auto_fist_calib()
	_update_fist_marker(delta)
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

# ==================== 自动抬步（上楼梯 / 上台沿） ====================
# 思路一句话：站定后用一根"前下方"探针找落脚面，够低够平、头顶有净空、落点不夹人，
# 就把根节点瞬移上去、模型用平滑偏移追上去（碰撞立刻正确 + 视觉不闪）。
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
	# 物理空间状态每帧现取：它只在**当前物理帧内**有效，缓存到下一帧会失效
	# （这类查询必须在物理帧内做，_physics_process / camera_rig 的物理帧里调用都安全）。
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

## 参数：无。返回值：true = 距上一次成功抬步还不到 STEP_GRACE_TIME（0.1 s）。
## 调用方（camera_rig）在这一窗口内**抑制重力**，避免刚抬上台阶就被重力拉回原台阶。
## 副作用：无。注意判据用的是 Time.get_ticks_msec()（真实毫秒）而不是逐帧累加，
##   所以同一物理帧内被调用多次也不会互相干扰。
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

## 参数：无。返回值：true = 抬步的视觉平滑仍在进行（_step_smooth_dur > 0）。
## 副作用：无。用途：相机跟随要用 visual_height() 而不是根节点坐标，此时两者不相等。
## 是否正在抬步缓动中（供相机/动画判断）
func is_step_smoothing() -> bool:
	return _step_smooth_dur > 0.0


## 参数：space —— 世界物理空间状态（仅当前物理帧有效）；land —— 拟落点世界坐标（米）。
## 返回值：true = 落点干净（与掩码内任何物体都不重叠）；false = 被夹住，调用方应放弃这次抬步。
## 副作用：无（只做一次 intersect_shape 查询，max_results = 1，开销很小）。
## 注意：查询体比角色本体瘦小（0.85×），且必须 exclude 自己 —— 不排除的话自身胶囊
##   一定会重叠，判定将恒为"不干净"，台阶永远上不去。
## 抬步落点是否干净：用一个略瘦的胶囊做形状查询，碰到墙就不算干净。
func _landing_clear(space: PhysicsDirectSpaceState3D, land: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	# 查询体刻意比角色本体"瘦一圈、矮一截"（0.85×）：这里真正要排除的是**人被两块
	# 碰撞体夹住**；若用等身胶囊，贴墙/贴地的毫米级重叠就会误判成"不干净"，
	# 结果是台阶永远上不去。宁可漏判（挤一点）也不能误判。
	shape.radius = COLLIDER_RADIUS * 0.85
	shape.height = maxf(shape.radius * 2.0 + 0.05, COLLIDER_HEIGHT * 0.85)
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	q.transform = Transform3D(Basis.IDENTITY, land + Vector3(0.0, shape.height * 0.5, 0.0))
	return space.intersect_shape(q, 1).is_empty()


## 抬步内部用的射线查询（薄封装）。
## 参数：
##   space  —— 世界 3D 物理空间状态（由调用方用 get_world_3d().direct_space_state 取；
##             它只在**当前物理帧内**有效，不能缓存到下一帧用）；
##   from   —— 射线起点（世界坐标，米）；
##   dir    —— 单位方向向量（本文件只传 Vector3.DOWN / Vector3.UP）；
##   length —— 射线长度（米），默认 STEP_PROBE_AHEAD（0.45）。
## 返回值：intersect_ray 的字典；**打不中就是空字典 {}**，所以调用方一律用 is_empty() 判断
##   （不要用 == null，字典永远不为 null，这是最常写错的一处）。
## 副作用：无（只读查询）。掩码与排除项都沿用玩家自己的 collision_mask / RID。
func _cast(space: PhysicsDirectSpaceState3D, from: Vector3, dir: Vector3,
		length: float = STEP_PROBE_AHEAD) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * length)
	q.collision_mask = collision_mask
	q.exclude = [get_rid()]
	return space.intersect_ray(q)


# ==================== 角色实例化（模型 / 动画库 / 自动缩放） ====================
## 按角色档案实例化模型，并把它整理成"可播放动画的 Visual 节点"。
## 参数：无（读成员 _profile；为空时按 character_id 现查一次档案作为兜底）。
## 返回值：模型根节点（已 add_child 到本节点、已改名 "Visual"、**缩放尚未设置**，
##   由 _ready 用 _auto_scale / CHARACTER_SCALE 施加）；模型加载失败时返回 null，
##   调用方 _ready 有降级路径（空 Node3D），所以**不要**在这里中断流程。
## 副作用：
##   * add_child(模型) —— 会触发模型自身的 _ready/_enter_tree；
##   * 写成员 anim_player（模型自带就复用，没有则新建挂在**模型根**下）、
##     _auto_scale（= 目标身高 / 模型原始高）、_lib_prefix、_clip_names；
##   * 库里存在 Idle 时立刻播放，保证进游戏第一帧不是 rest 姿势；
##   * 调用 _attach_held_staff() 挂载法杖；
##   * 打一行概要日志：角色名｜原始高→缩放→实际身高｜动画库与剪辑数｜挂点骨骼。
## 注意事项：
##   * AnimationPlayer 必须是**模型根的子节点**：动画库轨道路径写成
##     "root/Skeleton3D:<骨骼>"，挂错父节点会让所有轨道找不到目标而静默失效。
##   * 缩放刻意不在这里写：_ready 里分 fallback / 正常两条路径写 body.scale。
func _instantiate_character() -> Node3D:
	var prof := _profile if not _profile.is_empty() else CharProfile.get_profile(character_id)
	var scene: PackedScene = load(String(prof.get("scene", CHARACTER_SCENE)))
	if scene == null:
		push_warning("[player] 角色模型加载失败：%s" % String(prof.get("scene", "")))
		return null
	var inst := scene.instantiate()
	inst.name = "Visual"
	# 身高：量模型网格包围盒 → 缩放到档案里的目标身高（换任何模型都自动适配）
	# 量的是**网格包围盒**（不含骨骼）：换任何模型都能自动算出身高 → 自动缩放
	var raw_h := CharProfile.measure_height(scene)
	var want_h := float(prof.get("height", 1.5))
	_auto_scale = (want_h / raw_h) if raw_h > 0.01 else 1.0
	add_child(inst)

	# 动画：模型自带 AnimationPlayer 就用它；没有（如森林男）就建一个并挂上烘焙好的动画库。
	# ★ AnimationPlayer 必须是模型根的子节点：库里轨道路径是 root/Skeleton3D:<骨骼>
	anim_player = _find_animation_player(inst)
	if anim_player == null:
		anim_player = AnimationPlayer.new()
		anim_player.name = "AnimPlayer"
		inst.add_child(anim_player)
	var lib_path := String(prof.get("lib", ""))
	_lib_prefix = ""
	if lib_path != "" and ResourceLoader.exists(lib_path):
		var lib: AnimationLibrary = load(lib_path)
		if lib != null:
			# 默认库（名称为空串 ""）已被模型自带动画占用，不能覆盖 → 另挂到 "mix" 名下。
			# _lib_prefix 记下此前缀，之后 _clip() 会给所有逻辑动画名自动加上它
			# —— 这就是成员 _lib_prefix "库不是加在默认库上时才非空" 的来源。
			var lname := "" if not anim_player.has_animation_library("") else "mix"
			anim_player.add_animation_library(lname, lib)
			_lib_prefix = lname + ("/" if lname != "" else "")
	# 立刻播 Idle：否则模型会以 rest 姿势（T-pose 或建模姿势）停在第一帧，看起来像加载失败
	if anim_player.has_animation(_clip(ANIM_IDLE)):
		_play_anim(ANIM_IDLE)
	# 缓存剪辑名列表（_clip() 在"映射值是数组"时用它挑出库里真正存在的那个）。
	# 必须在**挂库之后**取，否则拿不到新库里的剪辑名。
	_clip_names = anim_player.get_animation_list()
	# 这一行是 debug_verbose=false 时也保留的关键日志：核对"原始高 → 缩放 → 实际身高"
	# 与挂点骨骼名是否正确（换模型时几乎每次都要看它）。
	print("[player] 角色=%s｜原始高 %.1f → 缩放 %.5f → %.2f m｜动画 %s（%d 条）｜挂点骨骼 %s" % [
		String(prof.get("label", character_id)), raw_h, _auto_scale, raw_h * _auto_scale,
		(lib_path.get_file() if lib_path != "" else "模型自带"),
		anim_player.get_animation_list().size(),
		str(prof.get("hand_bones", []).slice(0, 2))])
	_attach_held_staff(inst)
	return inst


# ==================== 手持法杖：挂载与握点决策 ====================
## 参数：
##   inst —— 已实例化的角色模型根节点（_instantiate_character() 里刚 add_child 的那个）。
## 返回值：无。
## 副作用：
##   * 写成员 held_staff（新建 HeldStaff 节点并 add_child 到挂点下）与 _native_props；
##   * 把 @export 的握点/朝向参数逐个拷进 held_staff（本项目所有"可调旋钮"都在玩家节点上，
##     法杖节点只负责执行，方便在检查器/远程调试里实时改）；
##   * 若 /root/StaffSystem 存在：读出当前已装备法杖并立即应用，同时连接 staff_equipped 信号。
## 调用时机：_instantiate_character() 末尾 —— 此时模型已在场景树内，骨架与挂点可用。
## 注意事项：
##   * 找不到手部挂点时只 push_warning 后返回：角色仍可正常移动，只是没有法杖。
##   * **加载阶段不要用 global_transform 换算"腕→握点"的实际距离**：父链全局变换尚未就绪，
##     会打印出 715 cm 之类的假数据；可信的那一行在 ~2 秒后的自检日志里。
##   * 握点优先级（决定法杖穿过手的哪一点）：
##     ① 手调 staff_grip_local（非零，推荐，可运行时实时调）
##     ② 网格"掌心/指根"中心 _palm_center_local()（自动）
##     ③ 骨骼算法 CharacterProfile.hand_grip_offset()（回退）
##   * 偏移由 **HeldStaff.position** 承载（父节点就是手骨 → 坐标系天然正确）；
##     不要再把它加到 _model.position 上（会被杖的朝向带歪，见技术文档 §11.8）。
## 把可替换的法杖挂到手部挂点上（Torch 系列是左手持物 → 现在挂左手）。Mage 模型自带 1H_Wand / 2H_Staff / Spellbook，
## 装上自定义法杖时先把它们藏起来，免得两根杖叠在一起。
func _attach_held_staff(inst: Node) -> void:
	_native_props.clear()
	# 这四个名字是 KayKit Mage 自带的手持道具节点名（写死在这里）：装上自定义法杖时
	# 要整组藏掉。换模型后若自带道具叫别的名字，这里要补/改，否则会出现"两根杖叠在一起"。
	for nm in ["1H_Wand", "2H_Staff", "Spellbook", "Spellbook_open"]:
		var p := inst.find_child(nm, true, false)
		if p is Node3D:
			_native_props.append(p as Node3D)
	# 右手挂点：按档案的名字列表找（森林男 hand.r，KayKit Mage handslot_r，Mixamo mixamorig_RightHand…）
	# find_hand 的查找顺序：① 场景里现成的同名挂点节点 → ② 骨骼名精确匹配 →
	# ③ 退一步找名字里含 "hand" 的骨骼（**优先左手**，因为 Torch 系列是左手持物）。
	# 注意：命中骨骼时会由 character_profile 自动创建一个 BoneAttachment3D（名 HandSocket）
	# 挂在骨架下 —— 所以下面必须用 `slot is BoneAttachment3D` 区分"腕关节挂点 vs 作者挂点"。
	var slot := CharProfile.find_hand(inst, _profile.get("hand_bones", []))
	if slot == null:
		push_warning("[staff] 角色 %s 上找不到右手骨骼 %s，法杖无法挂载" % [
			String(_profile.get("label", character_id)), str(_profile.get("hand_bones", []))])
		return
	if debug_verbose: print("[staff] 手部挂点 = %s" % slot.name)
	held_staff = load("res://scripts/held_staff.gd").new()
	held_staff.name = "HeldStaff"
	# 位置与朝向都归零：尺寸/握点/前倾角全由 HeldStaff 自己按目标长度与世界方向算
	held_staff.position = Vector3.ZERO
	held_staff.rotation_degrees = Vector3.ZERO
	# 法杖长度随身高等比缩放（原按 1.7m 角色定 1.45m；1.5m 角色 → 约 1.28m）
	held_staff.len_scale = target_height / 1.7
	# 杖头朝向 / 握点高低：做成可调开关（检查器里直接改，不用动代码）
	held_staff.flip_in_hand = staff_flip_in_hand
	held_staff.grip_frac = staff_grip_frac
	held_staff.grip_out = staff_grip_out
	# 握持角：档案里从参考动作（Torch Idle）解出来的固定角；为 ZERO 时回退到旧的 rest 标定
	held_staff.hold_rot_deg = _profile.get("staff_hold_rot_deg", Vector3.ZERO)
	held_staff.debug_grip_cylinder = debug_grip_cylinder
	held_staff.debug_verbose = debug_verbose
	# 「松握」：朝向世界稳定（0=刚性跟手 ✗ / 1=完全稳定 ✓）—— 修"跑动时杖尾前倾" ✗
	held_staff.world_stable = staff_world_stable
	held_staff.world_lean_deg = staff_world_lean_deg
	held_staff.world_run_lean_deg = staff_run_lean_deg
	# 手骨是腕关节时，把法杖挪进掌心（BoneAttachment3D 自己的 position 每帧会被骨骼姿态覆盖，只能交给模型）
	# 只有"自动创建的骨骼挂点"（BoneAttachment3D，原点在**腕关节**）才需要把法杖挪进掌心；
	# 若命中模型作者手放的挂点（普通 Node3D，如 KayKit handslot_r），那个位置本来就在握点上，
	# 再叠加偏移反而会把杖推出手 —— 这就是这里要分支判断的原因。
	if slot is BoneAttachment3D:
		var att := slot as BoneAttachment3D
		var off := CharProfile.hand_grip_offset(att.get_skeleton(), att.bone_name, staff_grip_along)
		var sk_inst := inst.find_child("Skeleton3D", true, false) as Skeleton3D
		# ★ 握点优先级：① 检查器里手调的 staff_grip_local（推荐，可实时调）
		#               ② 网格掌心中心（自动）
		#               ③ 骨骼算法（回退）
		if staff_grip_local.length() > 0.0001:
			off = staff_grip_local
			if debug_verbose: print("[staff] 握点 = 手调 staff_grip_local %s（%.1f cm）—— 运行时改它会实时跟着动 ✓" % [
				str(staff_grip_local.snapped(Vector3(0.001, 0.001, 0.001))),
				staff_grip_local.length() * _auto_scale * 100.0])
		else:
			var pc := _palm_center_local(att, sk_inst)
			if pc.length() > 0.0001:
				off = pc * staff_grip_along
				if debug_verbose: print("[staff] 握点 = 网格掌心中心 %s × along %.2f → %.1f cm" % [
					str(pc.snapped(Vector3(0.001, 0.001, 0.001))), staff_grip_along,
					off.length() * _auto_scale * 100.0])
		held_staff.grip_offset = off
		# ★ 真正的握点偏移放在 HeldStaff **自身 position** 上：父节点就是挂点（手骨），
		#   坐标系天然正确 ✓。若放在 _model.position，会被 HeldStaff 的"杖的朝向"带歪 ✗
		#   （症状：球与杖轴对不上、杖轴偏出掌心几厘米）
		held_staff.position = off
		# 注意：这里**不要**换算"腕→握点"的世界距离 —— 加载时 global_transform 还没就绪 ✗
		#       （会打出 700+ cm 的假数）；可信的那一行在自检里（约 2 秒后）✓

		if debug_verbose: print("[staff] 掌心偏移 %s（骨内单位，约 %.1f cm 世界）" % [
			str(off.snapped(Vector3(0.001, 0.001, 0.001))), off.length() * _auto_scale * 100.0])
		# 透明小球（青色）= 握点目标标记：**只在调试开关打开时创建** ✓
		if debug_grip_marker:
			_add_grip_marker(att, off)
		# 恒假分支：把"橙色细圆柱（网格掌心中心参照物）"留在代码里但默认不创建。
		# 需要拿它和法杖实际握点做目视对照时，把 false 改成 true 即可（不影响其它逻辑）。
		if false:
			_add_marker_at_local(att, off, sk_inst)
		# 半径补偿方向：掌心外法线（杖有粗细，握点在拳心时杆面会压进手掌）
		# ★ 半径补偿：**已按用户要求关闭** ✗
		#   原因：把杖沿掌法线推出去一个半径，会让"杖轴"偏离设定的握点 ——
		#   用户要的是「杖轴正好穿过握点」（手包住杖），而不是「掌心贴住杆面」。
		#   需要时可在检查器里用 staff_grip_out 手动补一点点（米，可为负）。
		# held_staff.out_dir = nrm            # ← 想要"杆面贴掌心"时再打开这一行
		held_staff.out_dir = Vector3.ZERO
	slot.add_child(held_staff)
	if debug_hand_socket:
		_add_hand_debug_marker(slot)
	var sys := _staff_system()
	if sys != null:
		_apply_staff(str(sys.get("equipped")), int(sys.get("equipped_element")))
		sys.connect("staff_equipped", _on_staff_equipped)


## 参数：id —— 法杖 id 字符串，空串 "" 表示收起法杖；elem —— 元素序号（int，由 StaffSystem 管）。
## 返回值：无。
## 副作用：转调 held_staff.set_staff(id, elem)（换模型/换元素材质）；
##   并按 id 是否为空**切换模型自带手持道具的可见性**（有自定义杖时藏起自带杖，免得两根叠一起）。
## 注意：held_staff 为 null（未挂上 / 加载失败）时静默返回；_native_props 里的节点可能已被释放，
##   所以逐个走 is_instance_valid 判断后再改 visible。
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


# ==================== 握点调试可视化（青球 / 橙色玻璃球） ====================
# 注：下面这两段 ## 文档（"运行期取法杖系统…"与"调试：在右手挂点上放一个红色小球…"）
# 实际描述的是文件下方的 _staff_system() 与 _add_hand_debug_marker()，位置错位在这里，
# 属历史遗留；按"只增不改"的约定未移动它们，函数处另补了文档。
## 运行期取法杖系统。**不要直接写 autoload 标识符 StaffSystem**：那样 player.gd 在
## autoload 未注册的编译上下文里（--script 探针、依赖链编译）会直接编译失败。
## 调试：在右手挂点上放一个红色小球（3.5cm，穿透显示）。
## 用途：如果球跟着手走 → 挂点是对的（问题在法杖自身的朝向/握点）；
##       如果球不跟手 → 挂点没绑上骨骼（要查 BoneAttachment3D / 骨骼名）。
## 独立参照物（橙色细圆柱）：在给定的**手骨本地偏移**处放一个标记圆柱。
## 与绿色圆柱（法杖实际握点）对比：重合 = 握点算法正确 ✓
## 青色小球（握点标记）节点引用；**只有 debug_grip_marker 打开时**才非 null。
## 它的位置 = 挂点本地坐标 + 握点偏移，法杖的杖身轴线必须正好穿过它。
var _grip_marker: Node3D = null
## 橙色玻璃球（实时拳心 + 拳头包围半径）节点引用；只有 debug_fist_sphere 打开时才非 null。
var _fist_marker: Node3D = null
## 拳心诊断日志的打印节流计时（秒）：累计满 1 秒才打一行，避免每帧刷屏
var _fist_log_t := 0.0


## 参数：att —— 挂点（这里只用作"球的父节点"，保证球随手动；为 null 时直接返回）。
## 返回值：无。副作用：创建一个 MeshInstance3D（名 FistCenterMarker）挂到 att 下并打印一行日志。
## 幂等：_fist_marker 已存在且有效时直接返回，不会重复建球。
## 橙色小球：**实时拳心**（当前姿势下四指 12 个关节的平均点）。
## 与青色球（法杖轴线穿过的固定握点）对比 → 距离即"固定握点 vs 真实拳心"的偏差（厘米）。
func _ensure_fist_marker(att: Node3D) -> void:
	if att == null or (_fist_marker != null and is_instance_valid(_fist_marker)):
		return
	var mi := MeshInstance3D.new()
	mi.name = "FistCenterMarker"
	var sph := SphereMesh.new()
	var r := maxf(0.008, staff_grip_marker_r) / maxf(0.0001, _auto_scale)
	sph.radius = r
	sph.height = r * 2.0
	sph.radial_segments = 20
	sph.rings = 12
	mi.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.5, 0.05, 0.18)          # 橙色玻璃球 = 整个拳头
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mi.material_override = mat
	att.add_child(mi)
	_fist_marker = mi
	print("[拳心球] 橙色球已创建（半径 %.1f cm）→ 每帧标出实时拳心 ✓" % (
		maxf(0.008, staff_grip_marker_r) * 100.0))


## 参数：att —— 手部挂点（要它的 bone_name，且从中判断左右手是 l 还是 r）；
##       sk —— 角色的 Skeleton3D；center_local —— 拳心（**手骨本地坐标**，用来量距离）。
## 返回值：包围半径（**手骨本地单位**，不是米；×1.15 是留一点余量）；
##   取不到骨骼/骨架为空时返回 **0.0**（调用方 _update_fist_marker 会判 <= 0.0001 而跳过）。
## 副作用：无（只读骨骼姿势）。
## 拳头的"包围半径"（手骨本地）：采样骨点到拳心的**最大距离** ×1.15
## → 用来画一个**包住整个拳头**的玻璃球 ✓
func _fist_radius_local(att: BoneAttachment3D, sk: Skeleton3D, center_local: Vector3) -> float:
	if att == null or sk == null:
		return 0.0
	var hi := sk.find_bone(att.bone_name)
	if hi < 0:
		return 0.0
	var side := "l"
	var low := att.bone_name.to_lower()
	if low.contains("right") or low.ends_with("r"):
		side = "r"
	var hxf := sk.global_transform * sk.get_bone_global_pose(hi)
	var r := 0.0
	for f in ["index", "middle", "ring", "pinky"]:
		for seg in ["1_base", "1", "2", "3"]:
			var bi := sk.find_bone("%s%s.%s" % [f, seg, side])
			if bi < 0:
				continue
			var p := hxf.basis.inverse() * ((sk.global_transform * sk.get_bone_global_pose(bi).origin) - hxf.origin)
			r = maxf(r, center_local.distance_to(p))
	return r * 1.15


## 参数：delta —— 物理帧时长（秒），只用于给"每秒一条日志"的节流计时累加。
## 返回值：无。
## 副作用：写 _fist_marker.position（拳心）与它的 SphereMesh.radius/height（包围半径）、
##   累加 _fist_log_t，满 1 秒打印一条 `[拳头球]` 日志（含与法杖握点的偏差，<0.3 cm 判"重合"）。
## 调用时机：每物理帧由 _physics_process 调用；开关关闭时第一行就返回（零开销）。
## 注意：_fist_marker 的 Mesh 是 _ensure_fist_marker 里 SphereMesh.new() 出来的**独立资源**；
##   这里只在半径确实变了（is_equal_approx 为假）时才写，避免每帧无谓地改动资源属性。
## 每帧把橙色球放到实时拳心（半径=整个拳头的包围半径），并报告与"固定握点"的距离。
## 仅在 debug_fist_sphere 打开时工作 ✓（关掉时也省掉每帧 16 次骨点采样 ✓）
func _update_fist_marker(delta: float) -> void:
	if not debug_fist_sphere:
		return
	if held_staff == null or body == null:
		return
	var att := held_staff.get_parent() as BoneAttachment3D
	var sk := body.find_child("Skeleton3D", true, false) as Skeleton3D
	if att == null or sk == null:
		return
	_ensure_fist_marker(att)
	if _fist_marker == null or not is_instance_valid(_fist_marker):
		return
	var fc := _fist_center_local(att, sk)
	if fc.length() < 0.0001:
		return
	_fist_marker.position = fc
	# ★ 半径 = 包住整个拳头的包围半径（玻璃球），并降低不透明度便于透视
	var fr := _fist_radius_local(att, sk, fc)
	if fr > 0.0001:
		var sm2: SphereMesh = (_fist_marker as MeshInstance3D).mesh as SphereMesh
		if sm2 != null and not is_equal_approx(sm2.radius, fr):
			sm2.radius = fr
			sm2.height = fr * 2.0
	_fist_log_t += delta
	if _fist_log_t >= 1.0:
		_fist_log_t = 0.0
		var d: float = (fc - held_staff.grip_offset).length() * _auto_scale * 100.0
		print("[拳头球] 实时拳心 %s｜球半径(整个拳头) %.2f cm｜杖轴握点 %s｜差 %.2f cm %s" % [
			str(fc.snapped(Vector3(0.001, 0.001, 0.001))), fr * _auto_scale * 100.0,
			str(held_staff.grip_offset.snapped(Vector3(0.001, 0.001, 0.001))),
			d, "✓ 重合" if d < 0.3 else "✗ 有偏差"])


## 参数：att —— 手部挂点（球的父节点，保证球随手动）；local —— 握点的**手骨本地坐标**
##   （骨内单位，直接当球的 position 用）。
## 返回值：无。
## 副作用：先 queue_free 掉旧的青球（避免热重载/重复调用堆出多个球），
##   再创建一个青色半透明、穿透显示（no_depth_test）的 MeshInstance3D 并打印握点日志
##   （含手骨三轴的世界朝向，方便照着推 staff_grip_local 的数值）。
## 调用时机：仅当 @export debug_grip_marker = true 时，由 _attach_held_staff 调用一次。
## 透明小球：**握点目标标记**（法杖的杖身轴线就穿过它）。
## 运行中在检查器改 staff_grip_local，小球与法杖会实时一起移动。
func _add_grip_marker(att: Node3D, local: Vector3) -> void:
	if att == null:
		return
	if _grip_marker != null and is_instance_valid(_grip_marker):
		_grip_marker.queue_free()
		_grip_marker = null
	var mi := MeshInstance3D.new()
	mi.name = "GripMarker"
	var sph := SphereMesh.new()
	sph.radius = staff_grip_marker_r / maxf(0.0001, _auto_scale)
	sph.height = sph.radius * 2.0
	sph.radial_segments = 20
	sph.rings = 12
	mi.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.1, 0.95, 1.0, 0.75)         # 青色（更不透明、更显眼）
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true                                # 隔着手指也能看到
	mi.material_override = mat
	mi.position = local
	att.add_child(mi)
	_grip_marker = mi
	print("[握点小球] 已放在 %s（半径 %.1f cm）→ 法杖轴线会穿过它 ✓" % [
		str(local.snapped(Vector3(0.001, 0.001, 0.001))), staff_grip_marker_r * 100.0])
	# 手骨本地轴的世界朝向：调 staff_grip_local 时照这个推（+Y 通常沿手骨指向指尖）
	var b := att.global_transform.basis.orthonormalized()
	print("[握点小球] 手骨本地轴的世界朝向：+X %s｜+Y %s｜+Z %s" % [
		str(b.x.snapped(Vector3(0.01, 0.01, 0.01))),
		str(b.y.snapped(Vector3(0.01, 0.01, 0.01))),
		str(b.z.snapped(Vector3(0.01, 0.01, 0.01)))])


## 参数：无。返回值：无。调用时机：每物理帧由 _physics_process 调用（默认几乎零开销）。
## 副作用：当发现 staff_grip_local 与法杖当前握点不一致时 → 同步 held_staff.grip_offset 与
##   held_staff.position、调 held_staff.request_place() 重新摆放法杖、把青球移到新位置并打日志；
##   另外把青球半径同步成 staff_grip_marker_r（改半径也能实时生效）。
## 用途：在**远程调试器**里实时改 staff_grip_local → 小球与法杖一起实时移动（调握点的主要手段）。
## 注意：只处理"非零"的 staff_grip_local；为零表示"用自动规则"，此时不覆盖自动标定的结果。
## 运行中同步握点：检查器里改 staff_grip_local / 小球半径 → 小球与法杖实时跟着动
func _sync_grip_target() -> void:
	if held_staff == null:
		return
	if staff_grip_local.length() > 0.0001 and held_staff.grip_offset != staff_grip_local:
		held_staff.grip_offset = staff_grip_local
		held_staff.position = staff_grip_local
		held_staff.request_place()
		if _grip_marker != null and is_instance_valid(_grip_marker):
			_grip_marker.position = staff_grip_local
		print("[握点小球] 更新 → %s（离腕 %.1f cm）" % [
			str(staff_grip_local.snapped(Vector3(0.001, 0.001, 0.001))),
			staff_grip_local.length() * _auto_scale * 100.0])
	if _grip_marker != null and is_instance_valid(_grip_marker):
		var mr := staff_grip_marker_r / maxf(0.0001, _auto_scale)
		var sm: SphereMesh = (_grip_marker as MeshInstance3D).mesh as SphereMesh
		if sm != null and not is_equal_approx(sm.radius, mr):
			sm.radius = mr
			sm.height = mr * 2.0


## ★ 拳心（手骨本地偏移）：用**当前姿势**下"四指各节关节（*1/*2/*3）"的平均位置。
## 手指卷起来时这些点正好围在杖轴周围 → 平均值 ≈ 杖轴位置 = **拳心** ✓
## （比"掌心网格体积中心"准：后者会被掌肉/前臂顶点带偏 ✗）
func _fist_center_local(att: BoneAttachment3D, sk: Skeleton3D) -> Vector3:
	if att == null or sk == null:
		return Vector3.ZERO
	var hi := sk.find_bone(att.bone_name)
	if hi < 0:
		return Vector3.ZERO
	var side := "l"
	var low := att.bone_name.to_lower()
	if low.contains("right") or low.ends_with("r"):
		side = "r"
	var hg := sk.get_bone_global_pose(hi)
	var hxf := sk.global_transform * hg                     # 当前姿势（不是 rest ✓）
	var sum := Vector3.ZERO
	var n := 0
	for f in ["index", "middle", "ring", "pinky"]:
		# ★ 必须把"掌骨基 *1_base"也算进来：手指各节关节都在**卷曲外侧** ✗，
		#   只用它们的平均值会落在通道外（实测球偏外约 3cm ✗）；
		#   加上掌骨基 → 把中心拉回掌心一侧 = 手指真正围出来的"通道中心" ✓
		for seg in ["1_base", "1", "2", "3"]:
			var bi := sk.find_bone("%s%s.%s" % [f, seg, side])
			if bi < 0:
				continue
			sum += sk.global_transform * sk.get_bone_global_pose(bi).origin
			n += 1
	if n == 0:
		return Vector3.ZERO
	var c := sum / float(n)
	var local := hxf.basis.inverse() * (c - hxf.origin)
	return local


## 一次性"拳心自动标定"：等动画跑起来（约 0.5 s，姿势已就位）后，
## 用当前姿势的四指关节均值定出手骨本地"拳心"偏移，并应用到法杖与小球的握点。
## 为什么不在加载时算：那时骨架还没被动画摆出姿势（是 rest）→ 手指是伸直的 ✗
func _auto_fist_calib() -> void:
	if _fist_calib_done or held_staff == null:
		return
	_fist_frames += 1
	if _fist_frames < 30:
		return
	var att := held_staff.get_parent() as BoneAttachment3D
	var sk := body.find_child("Skeleton3D", true, false) as Skeleton3D if body != null else null
	if att == null or sk == null:
		return
	_fist_calib_done = true
	# ★ 只在"用户没有指定握点"（staff_grip_local == 0）时才自动标定。
	#   否则会把你手调的值覆盖掉 ✗（症状：怎么改都在同一个位置 ✗）
	if staff_grip_local.length() > 0.0001:
		if debug_verbose: print("[拳心] 你已指定 staff_grip_local = %s → 不做自动标定（不会被覆盖 ✓）" % [
			str(staff_grip_local.snapped(Vector3(0.001, 0.001, 0.001)))])
		return
	var fc := _fist_center_local(att, sk)
	if fc.length() < 0.0001:
		return
	staff_grip_local = fc
	held_staff.grip_offset = fc
	held_staff.position = fc
	held_staff.request_place()
	if _grip_marker != null and is_instance_valid(_grip_marker):
		_grip_marker.position = fc
	if debug_verbose: print("[拳心] 自动标定完成 → staff_grip_local = %s（离腕 %.2f cm）｜法杖已重新摆放 ✓" % [
		str(fc.snapped(Vector3(0.001, 0.001, 0.001))), fc.length() * _auto_scale * 100.0])


## 自动拳心标定是否已完成（**一局只标定一次**；无论成功、跳过还是失败都会置 true，
## 避免每帧重复尝试）。置 true 后 staff_grip_local 就固定下来，不会再被自动值改写。
var _fist_calib_done := false
## 自加载以来经过的物理帧数：累计到 30 帧（≈0.5 s）才做自动标定 —— 那时动画已把手指
## 摆成"握拳"姿势，算出的拳心才在掌心；在 rest 姿势下算会落到指尖外。
var _fist_frames := 0


## 在给定的**手骨本地偏移**处放一根橙色半透明细圆柱（独立参照物）。
## 参数：
##   att   —— 手部挂点（BoneAttachment3D）；
##   local —— 手骨本地坐标偏移，单位是**骨内单位而不是米**（1 cm ≈ 1/_auto_scale 骨内单位）；
##   _sk   —— 未使用的 Skeleton3D 形参（下划线前缀 = 故意不用，仅为保留调用签名）。
## 返回值：无。
## 副作用：往 att 下 add_child 一个 MeshInstance3D（名 HandCenterMarker），
##   尺寸按 _auto_scale 换算，对应世界约 0.4 cm 粗、16 cm 长；并打印一行对照日志。
## 调用时机：**当前被 `if false:` 挡住**（见 _attach_held_staff 里那一行的说明），
##   仅作为"网格掌心中心"的人工对照物备用。
## 注意：圆柱长度按早期参考模型写死，换模型后长度不一定合适，只作目视对比用。
func _add_marker_at_local(att: BoneAttachment3D, local: Vector3, _sk: Skeleton3D) -> void:
	var mi2 := MeshInstance3D.new()
	mi2.name = "HandCenterMarker"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.004 / maxf(0.0001, _auto_scale)
	cyl.bottom_radius = cyl.top_radius
	cyl.height = 0.16 / maxf(0.0001, _auto_scale)
	cyl.radial_segments = 20
	mi2.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.1, 0.85)         # 橙色
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mi2.material_override = mat
	mi2.position = local
	att.add_child(mi2)
	if debug_verbose: print("[握持对照] 橙色圆柱（网格掌心中心）已放在 %s ✓｜与绿色圆柱重合 = 握点正确 ✓" % [
		str(local.snapped(Vector3(0.001, 0.001, 0.001)))])


## 网格"握点中心"（**手骨本地偏移**）：只用手部网格顶点，不依赖任何骨骼/握持算法。
## ★ 取样中心改用"**四指指根（近节 *1）的均值**"、半径 3.5 cm：
##   旧做法以**腕**为中心取 12 cm 内的顶点 → 把**前臂**顶点也算进来，中心被拉向腕侧 ✗
##   （实测小球落在指节外侧 ✗）。现在只取"手指卷起来夹住杖的那块体积" → 就是握点中心 ✓
func _palm_center_local(att: BoneAttachment3D, sk: Skeleton3D) -> Vector3:
	if att == null or sk == null:
		return Vector3.ZERO
	var hi := sk.find_bone(att.bone_name)
	if hi < 0:
		return Vector3.ZERO
	var side := "l"
	var low := att.bone_name.to_lower()
	if low.contains("right") or low.ends_with("r"):
		side = "r"
	var anchor := Vector3.ZERO
	var an := 0
	for f in ["index", "middle", "ring", "pinky"]:
		var ki := sk.find_bone("%s1.%s" % [f, side])
		if ki < 0:
			ki = sk.find_bone("%s1_base.%s" % [f, side])
		if ki >= 0:
			anchor += sk.get_bone_global_rest(ki).origin
			an += 1
	var rest := sk.get_bone_global_rest(hi)
	anchor = rest.origin if an == 0 else anchor / float(an)
	var r_skel := 0.035 / maxf(0.0001, _auto_scale)        # 世界 3.5 cm → 骨架单位
	var sum := Vector3.ZERO
	var n := 0
	var to_skel := sk.global_transform.affine_inverse()
	for mi in _all_meshes(att):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		var xf := to_skel * (mi as Node3D).global_transform
		for s in mesh.get_surface_count():
			var arr: Array = mesh.surface_get_arrays(s)
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for v in verts:
				var p: Vector3 = xf * v
				if p.distance_to(anchor) <= r_skel:
					sum += p
					n += 1
	if n < 50:
		if debug_verbose: print("[握持对照] 取样顶点太少（%d）→ 回退骨骼算法" % n)
		return Vector3.ZERO
	var c := sum / float(n)
	var local := rest.basis.inverse() * (c - rest.origin)
	if debug_verbose: print("[握持对照] 握点中心：取样中心=四指指根｜半径3.5cm｜顶点 %d｜骨内偏移 %s｜距腕 %.2f cm" % [
		n, str(local.snapped(Vector3(0.001, 0.001, 0.001))), local.length() * _auto_scale * 100.0])
	return local


## 收集 from 所在**整棵场景树**里的所有 MeshInstance3D（含未在树内的分支）。
## 参数：from —— 任意节点（本文件里传手部挂点）。
## 返回值：MeshInstance3D 数组，可能为空。
## 为什么先爬到场景根再重新向下遍历：手部网格常常**不在挂点子树里** —— 挂点在骨架分支下，
##   而蒙皮网格挂在模型根的另一条分支上；只搜 from 的子树会一个网格都找不到。
## 副作用：无（只读遍历）。
## 注意：**每次调用都是全树遍历**，只应在加载/一次性标定时调用，不要放进每帧路径。
func _all_meshes(from: Node) -> Array:
	var out: Array = []
	var root2: Node = from
	while root2.get_parent() != null:
		root2 = root2.get_parent()
	var stack: Array[Node] = [root2]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D:
			out.append(cur)
		for c in cur.get_children():
			stack.append(c)
	return out


## 在挂点上放一个红色小球（穿透显示），用来确认"挂点有没有真的跟着手骨走"。
## 参数：slot —— 手部挂点（Node3D）。
## 返回值：无。
## 副作用：往 slot 下 add_child 一个 MeshInstance3D（名 HandSocketDebug）并打印一行日志。
## 调用时机：仅当 @export debug_hand_socket = true（默认 false）时，由 _attach_held_staff()
##   调用一次。
## 判读方法：球跟着手走 → 挂点是对的（问题在法杖自身的朝向/握点）；
##   球不跟手 → 挂点没绑上骨骼（去查 BoneAttachment3D 的 bone_name / 骨骼名）。
func _add_hand_debug_marker(slot: Node3D) -> void:
	var mi := MeshInstance3D.new()
	mi.name = "HandSocketDebug"
	var sph := SphereMesh.new()
	# 挂点在模型内部（父级有 0.015 这类缩放），半径要按父级缩放换算成世界 3.5cm
	var ps := maxf(0.0001, slot.global_transform.basis.get_scale().x)
	sph.radius = 0.035 / ps
	sph.height = 0.07 / ps
	mi.mesh = sph
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.15, 0.15)
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	mi.material_override = mat
	slot.add_child(mi)
	print("[staff] 调试红球已放在挂点 %s（世界半径 3.5cm）" % slot.name)


## 一次性自检（约 2 秒后打一次）：挂点 / 手骨 / 法杖网格 的世界位置，
## 用来确认"法杖真的绑在手上"（挂点跟手骨重合 + 挂点落在法杖包围盒内）。
## 一次性自检是否已经执行过（置 true 后本局不再打印自检）
var _geom_checked := false
## 自检延时计帧：累计约 120 帧（≈2 s）后才真正执行 —— 那时全局变换与"动画摆出的姿势"才就绪
var _geom_frames := 0


# ==================== 一次性自检日志（debug_verbose 专用） ====================
## 几何自检：约 2 秒后打印一次"法杖到底有没有握在手里 / 握点坐标系对不对"的诊断日志。
## 参数：无。返回值：无（不改任何状态，只打印）。
## 副作用：采样骨骼全局姿势与网格 AABB（有一定开销），因此用 _geom_frames 延时 + 
##   _geom_checked 保证**一局只跑一次**，且整体被 debug_verbose 挡在门外。
## 为什么延到 ~2 秒：加载瞬间父链 global_transform 尚未就绪、骨架也还停在 rest 姿势，
##   那时算出的"腕→握点距离"会是 715 cm 之类的假数（历史事故，见技术文档 §11.17）。
## 输出与判读（详见技术文档 §9 / §12）：
##   [法杖自检]    挂点骨名/索引、挂点与手骨距离（<2 cm = 跟手 ✓）、杖的包围盒高、
##                 挂点是否落在杖身上、杖身与竖直夹角（站立应 ~0~1° = 朝向稳定生效）
##   [握点一致性]  法杖握点 vs 青球（<0.3 cm = 坐标系正确 ✓）—— 决定性判据（需开青球）
##   [握点核对]    腕→握点世界距离、本地偏移、"1 cm ≈ 多少骨内单位"的换算基准
##   [握持自检]    腕→掌骨 / 腕→近节均值，并给出 staff_grip_along 的建议值
##   [外八自检] / [站姿自检]  脚掌偏航与站姿宽度（核对烘焙进来的腿/脚修正是否还在）
## 注意：下面用 hand.l / foot.l / root.x 等骨骼名硬编码探测，换成非 ARP/Mixamo 骨架时
##   对应那几段日志会整段缺失（不是报错，属预期降级）。
func _debug_geom_check() -> void:
	# 全部自检日志（[法杖自检]/[外八自检]/[站姿自检]/[握点核对]/[握点一致性]）
	# 都收在 debug_verbose 里 → 默认不打 ✓（需要排查时在检查器里打开 ✓）
	if not debug_verbose:
		return
	if _geom_checked or held_staff == null or body == null:
		return
	_geom_frames += 1
	if _geom_frames < 120:
		return
	_geom_checked = true
	var skel := body.find_child("Skeleton3D", true, false) as Skeleton3D
	var slot := held_staff.get_parent() as Node3D
	if skel == null or slot == null:
		print("[法杖自检] 找不到骨架或挂点 ✗")
		return
	var bone_name := "-"
	if slot is BoneAttachment3D:
		bone_name = (slot as BoneAttachment3D).bone_name
	var bi := skel.find_bone(bone_name)
	var hand_pos := Vector3.ZERO
	if bi >= 0:
		hand_pos = skel.global_transform * skel.get_bone_global_pose(bi).origin
	var d_hand := hand_pos.distance_to(slot.global_position)
	# 用"杖的世界 AABB（外扩 3 cm）是否包含挂点"来判断手是不是真的握着杖：
	# 只比位置会被"杖在手里但没对齐"骗过，AABB 能同时兜住尺寸/缩放错乱的情况。
	var box := _mesh_aabb_world(held_staff)
	var on_staff := box.size != Vector3.ZERO and box.grow(0.03).has_point(slot.global_position)
	print("[法杖自检] 挂点骨=%s（索引 %d）｜挂点 %s｜手骨 %s｜距离 %.4f m → %s" % [
		bone_name, bi,
		str(slot.global_position.snapped(Vector3(0.001, 0.001, 0.001))),
		str(hand_pos.snapped(Vector3(0.001, 0.001, 0.001))), d_hand,
		"跟手 ✓" if d_hand < 0.02 else "没跟手 ✗"])
	print("[法杖自检] 法杖世界包围盒 高 %.3f m｜挂点是否落在杖身上 = %s" % [
		box.size.y, "是 ✓（手握着杖）" if on_staff else "否 ✗（杖没在手里）"])
	# 握点一致性核对（决定性 ✓，只在青色小球打开时有意义）：
	#   法杖的握点 = HeldStaff 的全局原点（模型被摆成"握点落在原点"✓）
	#   青球 = 挂点 + grip_offset（直接挂在挂点上 ✓）
	#   → 两者必须重合；不重合就说明坐标系用错了 ✗
	if debug_grip_marker and held_staff != null and _grip_marker != null and is_instance_valid(_grip_marker):
		var a := (held_staff as Node3D).global_position
		var b := (_grip_marker as Node3D).global_position
		print("[握点一致性] 法杖握点 %s｜青球 %s｜差 %.2f cm %s" % [
			str(a.snapped(Vector3(0.001, 0.001, 0.001))),
			str(b.snapped(Vector3(0.001, 0.001, 0.001))),
			a.distance_to(b) * 100.0,
			"✓ 重合（坐标系正确）" if a.distance_to(b) < 0.003 else "✗ 不重合（坐标系错了）"])
	# 握点核对（自检时刻变换已就绪，数值才可信）：
	# 腕 → 握点 的世界距离；以及"1 cm 等于多少本地单位"（换算基准）
	if held_staff != null and slot is Node3D:
		var sxf2 := (slot as Node3D).global_transform
		var gpt: Vector3 = sxf2 * held_staff.grip_offset
		print("[握点核对] 腕→握点 世界距离 %.2f cm｜本地偏移 %s｜1 cm ≈ %.2f 本地单位（_auto_scale %.5f）" % [
			(gpt - sxf2.origin).length() * 100.0,
			str(held_staff.grip_offset.snapped(Vector3(0.001, 0.001, 0.001))),
			1.0 / maxf(0.00001, _auto_scale), _auto_scale])
	# 杖身方向（HeldStaff 的 +Y 就是杖身）与竖直的夹角：站立时应接近 0°
	var axis := (held_staff as Node3D).global_transform.basis.y.normalized()
	var ang := rad_to_deg(axis.angle_to(Vector3.UP))
	print("[法杖自检] 杖身方向 %s｜与竖直夹角 %.1f° → %s" % [
		str(axis.snapped(Vector3(0.001, 0.001, 0.001))), ang,
		"竖直 ✓" if ang < 15.0 else "偏斜"])
	# 握持自检：量"腕 → 掌骨(*1_base) → 近节(*1)"的距离，
	# 用来决定法杖轴线该落在手掌哪里（staff_grip_along=1.0 表示落在掌骨起点）
	var sk2 := body.find_child("Skeleton3D", true, false) as Skeleton3D
	if sk2 != null:
		var hb := sk2.find_bone("hand.l")
		if hb >= 0:
			var wo := sk2.global_transform * sk2.get_bone_global_pose(hb).origin
			var base_sum := 0.0
			var base_n := 0
			var knuck_sum := 0.0
			var knuck_n := 0
			for fi in ["index", "middle", "ring", "pinky"]:
				var bi2 := sk2.find_bone(fi + "1_base.l")
				if bi2 >= 0:
					base_sum += wo.distance_to(sk2.global_transform * sk2.get_bone_global_pose(bi2).origin)
					base_n += 1
				var ki := sk2.find_bone(fi + "1.l")
				if ki >= 0:
					knuck_sum += wo.distance_to(sk2.global_transform * sk2.get_bone_global_pose(ki).origin)
					knuck_n += 1
			if base_n > 0 and knuck_n > 0:
				var d_base := base_sum / float(base_n)
				var d_knuck := knuck_sum / float(knuck_n)
				print("[握持自检] 腕→掌骨均值 %.3f m｜腕→近节(指根)均值 %.3f m｜当前 along=%.2f out=%.3f｜along 建议 ≈ %.2f" % [
					d_base, d_knuck, staff_grip_along, staff_grip_out,
					(d_knuck / maxf(0.0001, d_base)) * 0.75])
	if sk2 != null:
		var fl := sk2.find_bone("foot.l")
		var fr := sk2.find_bone("foot.r")
		if fl >= 0 and fr >= 0:
			var dl := _bone_horiz_dir(sk2, fl)
			var dr := _bone_horiz_dir(sk2, fr)
			var avg := dl + dr
			avg.y = 0.0
			avg = avg.normalized() if avg.length() > 0.01 else Vector3.FORWARD
			var al := rad_to_deg(dl.signed_angle_to(avg, Vector3.UP))
			var ar := rad_to_deg(dr.signed_angle_to(avg, Vector3.UP))
			print("[外八自检] 左脚 %+.1f°｜右脚 %+.1f° → %s" % [
				al, ar, "基本朝前 ✓" if (absf(al) < 8.0 and absf(ar) < 8.0) else "仍外八 ✗"])
			# 站姿宽度（劈叉程度）：两脚间距投影到**角色自身的左右轴**上，再除以髋高
			var hip := sk2.find_bone("root.x")
			if hip < 0:
				hip = sk2.find_bone("Hips")
			if hip >= 0:
				var a1 := sk2.global_transform * sk2.get_bone_global_pose(fl).origin
				var a2 := sk2.global_transform * sk2.get_bone_global_pose(fr).origin
				var ho := (sk2.global_transform * sk2.get_bone_global_pose(hip).origin).y
				var lateral := (body as Node3D).global_transform.basis.x.normalized()
				var w := absf((a1 - a2).dot(lateral))
				print("[站姿自检] 两脚间距 %.3f m｜髋高 %.3f m｜比值 %.2f → %s" % [
					w, ho, w / maxf(0.001, ho),
					"正常 ✓" if (w / maxf(0.001, ho)) < 0.35 else "偏宽（劈叉感）✗"])


## 参数：sk —— 角色的 Skeleton3D；idx —— 目标骨骼索引（应传索引而不是名字）。
## 返回值：该骨骼朝向的**水平分量**（已归一化，世界空间）；退化情况返回 Vector3.FORWARD。
## 副作用：无（只读姿势）。取法是"骨原点 → 最长的子骨"——子骨最长的那根通常就是骨头的
##   实际指向（如脚骨 → 脚趾），比直接信任骨骼自身轴更贴合蒙皮姿态。
## 注意：叶骨骼（没有子骨）拿不到子骨方向，会退化成骨骼自身 +Y 轴再投影；纯竖直骨投影后
##   长度接近 0，此时返回 FORWARD 兜底，调用方不必再判零。
## 骨骼"自身朝向"的水平分量（当前动画姿势下：骨原点 → 最长的子骨方向，世界空间）
func _bone_horiz_dir(sk: Skeleton3D, idx: int) -> Vector3:
	var o := sk.global_transform * sk.get_bone_global_pose(idx).origin
	var best := Vector3.ZERO
	for c in sk.get_bone_count():
		if sk.get_bone_parent(c) == idx:
			var d := (sk.global_transform * sk.get_bone_global_pose(c).origin) - o
			if d.length() > best.length():
				best = d
	# 叶骨骼（没有子骨）拿不到"骨原点→子骨"方向 → 退化成骨骼自身的 +Y 轴再投到水平面
	if best.length() < 0.0001:
		best = (sk.global_transform.basis * sk.get_bone_global_pose(idx).basis).y
	best.y = 0.0
	return best.normalized() if best.length() > 0.0001 else Vector3.FORWARD


# ==================== 网格 / 骨骼辅助算法 ====================
## 计算节点 n 及其全部子孙里所有可视实体在**世界空间**的合并 AABB。
## 参数：n —— 任意节点（本文件里传 HeldStaff 法杖节点）。
## 返回值：世界空间 AABB；一个可视实体都没有时返回**空 AABB**（size == Vector3.ZERO）——
##   调用方 _debug_geom_check 正是用 size != Vector3.ZERO 判断"有没有量到东西"。
## 副作用：无（只读）。遍历用显式栈（迭代）而非递归，避免深层节点爆栈。
## 为什么手动展开 8 个角点：VisualInstance3D.get_aabb() 给的是**局部空间**包围盒，
##   直接把 global_transform 套在 position/size 上，遇到带旋转/缩放的节点会算错；
##   必须把 8 个角点各自变换到世界再合并（`i & 1/2/4` 就是按位取角点坐标的组合）。
## 注意：Light3D 也继承自 VisualInstance3D，但它的 AABB 没有意义，故显式排除。
func _mesh_aabb_world(n: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is VisualInstance3D and cur is Node3D and not (cur is Light3D):
			var b := (cur as VisualInstance3D).get_aabb()
			var xf := (cur as Node3D).global_transform
			var o := AABB(xf * b.position, Vector3.ZERO)
			for i in 8:
				o = o.expand(xf * (b.position + Vector3(
					b.size.x if (i & 1) else 0.0,
					b.size.y if (i & 2) else 0.0,
					b.size.z if (i & 4) else 0.0)))
			out = o if first else out.merge(o)
			first = false
		for c in cur.get_children():
			stack.append(c)
	return out


# ==================== 法杖/装备系统对接与对外接口 ====================
## 取法杖系统 autoload 节点（/root/StaffSystem）。
## 参数：无。返回值：Node；**该 autoload 不存在时返回 null**。
## 副作用：无。
## 为什么用 get_node_or_null 而不是直接写标识符 StaffSystem：直接引用 autoload 标识符会让
##   本脚本在"autoload 尚未注册"的编译上下文（--script 无头探针、依赖链编译）里编译失败；
##   走节点路径则任何上下文都能通过编译（详见上面那段错位的 ## 文档）。
## 注意：所有调用方都必须判空（_attach_held_staff / _on_staff_equipped 都已判）。
func _staff_system() -> Node:
	return get_node_or_null("/root/StaffSystem")


## StaffSystem.staff_equipped 信号回调：装备的法杖变了 → 立刻重挂。
## 参数：id —— 新装备的法杖 id 字符串；**空串表示收起法杖**（_apply_staff 会同时把模型
##   自带的手持道具恢复显示）。
## 返回值：无。
## 副作用：转调 _apply_staff()：改写 held_staff 的模型/元素，并切换自带道具可见性。
## 注意：元素序号**不在信号参数里**，所以这里要再查一次 StaffSystem.equipped_element；
##   StaffSystem 为 null（autoload 缺失）时按 0（无元素）处理，避免崩溃。
func _on_staff_equipped(id: String) -> void:
	var sys := _staff_system()
	_apply_staff(id, int(sys.get("equipped_element")) if sys != null else 0)


## 供外部（技能/长老仪式）触发杖头闪光
## 参数：strength —— 闪光强度倍率（默认 1.6）；HeldStaff.flash 里实际写入的
##   light_energy = strength × 4.0，是一次性尖峰，随后由法杖自己的光脉冲把亮度呼吸回常态。
## 返回值：无。副作用：转调 held_staff.flash()。
## 注意：held_staff 为 null（没挂法杖 / 加载失败）时静默忽略，不报错。
## 供外部（技能/长老仪式）触发杖头闪光
func flash_staff(strength: float = 1.6) -> void:
	if held_staff != null:
		held_staff.flash(strength)


# ==================== 动画工具（查找 / 播放 / 名称映射） ====================
## 深度优先递归查找第一个 AnimationPlayer。
## 参数：node —— 搜索起点（本文件传模型根实例）。
## 返回值：找到的 AnimationPlayer；整棵子树都没有时返回 **null**（调用方会新建一个挂在模型根下）。
## 副作用：无（只读遍历）。
## 注意：递归写法，模型骨架层级很深也能找到；模型里若有多个 AnimationPlayer 只返回第一个。
func _find_animation_player(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for c in node.get_children():
		var r := _find_animation_player(c)
		if r != null:
			return r
	return null

## 播放一个**逻辑名**动画（内部做库前缀 + 档案映射），是全文件唯一的"真正 play()"入口。
## 参数：name —— 逻辑动画名（ANIM_* 常量 / ACTION_LIB 里那种名字），**不是实际剪辑名**。
## 返回值：无。
## 副作用：anim_player.play()；并可能改写 anim_player.speed_scale。
## 调用时机：所有"直接播某个剪辑"的地方（Idle、动作菜单、施法、家具互动、跳跃……）。
## 注意：
##   * 映射后的剪辑**不存在时静默不播**（画面停在上一动作）—— 需要"绝不静止"的场景
##     请走 _play_move_anim()，它会把缺失剪辑回退成 Walking/Idle。
##   * 播非跑步动画时会把 speed_scale 复位为 1.0：否则上一次跑步留下的 1.4× 会带到
##     下一个动作（走/攻击/施法全部加速）上。
func _play_anim(name: String) -> void:
	var n := _clip(name)
	if anim_player != null and anim_player.has_animation(n):
		anim_player.play(n)
		# 动作/跳跃/施法都恢复 1.0×；跑步的 1.4× 由 _play_move_anim 在播完后设置
		if name != ANIM_RUN and anim_player.speed_scale != 1.0:
			anim_player.speed_scale = 1.0


## 参数：name —— 逻辑动作名（如 "Idle" / "Walking_A" / ACTION_LIB 里的第二列）。
## 返回值：本档案里实际使用的剪辑名（= _lib_prefix + 档案映射结果）；**找不到映射时
##   原样返回逻辑名**（拿它去 has_animation 查就会查不到，于是调用方的回退逻辑生效）。
## 副作用：无（纯函数，不播动画）。
## 说明：映射值可以写成数组 —— clip_of 会挑"本档案库里真正存在的第一个"候选；
##   若所有候选都不存在，它返回**第一候选**而不是空串（保证调用方拿到非空名字，
##   再由 has_animation() 判定失败 → 走 Idle 回退）。这让同一逻辑名在不同角色档案下
##   落到不同剪辑（森林男那套 Mixamo 名），也支持"新动作优先、旧动作兜底"。
## 逻辑动作名 → 本档案的实际剪辑名（含库前缀）。映射值可能是数组（取库里存在的第一个）
func _clip(name: String) -> String:
	return _lib_prefix + CharProfile.clip_of(_profile, name, _clip_names)

## 参数：v —— true 显示角色模型，false 隐藏（第一人称用）。
## 返回值：无。
## 副作用：只改 body.visible（**碰撞体不受影响**，隐藏后依然会碰撞/被碰撞）。
## 注意：body 为 null（模型加载失败）时静默忽略。
## 第一人称隐藏角色模型（避免相机卡进头部内部），第三人称显示
func set_body_visible(v: bool) -> void:
	if body != null:
		body.visible = v

# ==================== 转向平滑（转身过渡） ====================
## 转向平滑：转场景时移动方向（相对屏幕）会变，角色若**瞬间**赋值朝向，
## 就是"一帧甩到新方向"——法杖挂在手上、以手为轴扫过去，看着像在绕圈
## （用户："玩家移动时，旋转场景，怎么法杖也跟着转圈"）。
## 打开后按 turn_speed_deg 逐帧转过去，观感是"转身"而不是"甩"。
@export var smooth_turn := true
## 角速度**上限**（度/秒）：不论差多少角度，转得再快也不超过它
@export var turn_speed_deg := 900.0
## 转向响应系数（1/秒）：本帧角速度 = 该系数 × 剩余角度，再夹到
## [TURN_MIN_RATE, turn_speed_deg] 之间。**这就是"过渡"的来源**——
## 剩余角度大时转得快、接近目标时自动减速收势，起势与收势都是连续的。
@export var turn_response := 12.0
## 转向时是否播放"转向动作"（kaykit/DashLeft/Right）。
## 默认**关闭**：这两个剪辑是**冲刺**动作，并不是专门的转身动作；而
## kaykit_library.tres 里根本没有 Strafe_Left/Strafe_Right（所以 ANIM_STRAFE_L/R
## 一直在静默回退成 Walking_A）。循环播冲刺动作会像"边走边反复侧冲"，
## 先用**压弯**做过渡更稳；想试动作把这个开关打开即可。
@export var turn_anim_enabled := false

## 角速度下限（弧度/秒）：只剩几度时也得有个最小速度，
## 否则指数式收敛会在最后一点角度上拖出长长的尾巴。
const TURN_MIN_RATE := deg_to_rad(180.0)

## 角色面向水平移动方向（Mage 模型 +Z 为面部前方）
##
## delta 必须由调用方传入：本函数是在 camera_rig 的 **_physics_process** 里调的，
## 而 get_process_delta_time() 返回的是**空闲帧**时长 —— 两者在"物理 60Hz /
## 渲染 144Hz"这类配置下并不相等，用错了转向速度会随机器刷新率漂移。
func face_direction(face: Vector3, delta: float = -1.0) -> void:
	if body == null:
		return
	var target := atan2(face.x, face.z)
	if not smooth_turn:
		body.rotation.y = target
		return
	var dt := delta if delta > 0.0 else get_physics_process_delta_time()
	# 剩余角度（带符号、走最短弧）。
	# 为什么不用 rotate_toward：那是**匀速**旋转 —— 起步瞬间满速、到位瞬间急停，
	# 观感很硬。改成让角速度正比于剩余角度，天然就是"快起慢收"的过渡曲线；
	# step 再夹一个"不超过剩余角度"，保证不会转过头来回摆。
	var remain := angle_difference(body.rotation.y, target)
	var rate := clampf(turn_response * absf(remain), TURN_MIN_RATE, deg_to_rad(turn_speed_deg))
	var step := minf(rate * dt, absf(remain))
	body.rotation.y += signf(remain) * step

# ==================== 转向过渡：侧倾压弯与转向动作 ====================
# ---------- 转向过渡 ----------

## 参数：lateral —— 水平速度在"角色自身左右轴"上的分量（**米/秒，右为正**）。
##   取值范围与阈值比较：|lateral| > LATERAL_ANIM_THRESHOLD(0.6) 时会改用侧移动画。
## 返回值：无。副作用：只写成员 _lateral（不立即切动画，切换发生在下一次 _update_move_anim/
##   update_turn 里，这样能避免每帧反复切剪辑造成抖动）。
## 调用时机：camera_rig 每物理帧告知一次。侧倾压弯与侧移动画都读这个值。
## 由相机控制器每帧告知：相对朝向的侧向速度（右为正）与朝向变化量（弧度，右为正）
func set_lateral(lateral: float) -> void:
	_lateral = lateral


## 朝向发生明显变化时调用（由相机控制器在转身时触发）
##
## ★ angle_delta 必须是**本次想转的总角度**（当前朝向 → 目标朝向），
## 不能传"本帧实际转过的角度"：平滑转向下每帧最多转 turn_speed_deg × dt
## （900°/s @60fps = 15°），永远够不到 45° 的阈值 —— 那样这套压弯/转向过渡
## 就整个是死代码（本函数历史上正是被这样调的，所以压弯从来没出现过）。
func notify_facing_change(angle_delta: float) -> void:
	if absf(angle_delta) < TURN_ANIM_ANGLE:
		return
	_turn_dir = signf(angle_delta)
	_turn_timer = TURN_ANIM_TIME
	# 转向期间持续给侧倾一个同向冲量（会被夹在上限内），转完自然回正
	_lean = clampf(_lean - _turn_dir * TURN_LEAN_MAX, -TURN_LEAN_MAX, TURN_LEAN_MAX)
	# 移动中才播转向动作，站立转向只靠侧倾。默认关闭，原因见 turn_anim_enabled
	if turn_anim_enabled and _moving and not _action_active and not _jump_air:
		_play_move_anim(ANIM_TURN_L if _turn_dir > 0.0 else ANIM_TURN_R)


## 参数：
##   delta   —— 本帧时长（秒），由调用方传（camera_rig 的物理帧 delta，别用空闲帧 delta）；
##   moving  —— 本帧是否在移动（决定转向动作结束后要不要恢复移动动画、以及选跑还是走）；
##   running —— 本帧是否在跑（与 moving 一起决定恢复 Running_A 还是 Walking_A）。
## 返回值：无。
## 副作用：递减 _turn_timer、把 _lean 朝 0 收（TURN_LEAN_RECOVER 弧度/秒）、
##   把 _lean 写到 body.rotation.z（这就是"压弯"的落地方式），
##   并在转向动作结束后按 _lateral 选择侧移/走/跑动画。
## 调用时机：camera_rig 每物理帧调用一次（与 face_direction 配合）。
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
	var n := _clip(name)
	if _move_anim == name and anim_player != null \
			and anim_player.is_playing() and anim_player.current_animation == n:
		return
	if anim_player != null and not anim_player.has_animation(n):
		if anim_player.has_animation(_clip(ANIM_WALK)):
			name = ANIM_WALK
		elif anim_player.has_animation(_clip(ANIM_IDLE)):
			name = ANIM_IDLE
		else:
			return
		n = _clip(name)
	_move_anim = name          # 存"逻辑名"，其它地方照旧比较
	_play_anim(n)
	# 用户规格：走和跑共用同一条持剑动作，跑步靠 1.4× 播放速度区分（快跑）
	anim_player.speed_scale = RUN_ANIM_SPEED if name == ANIM_RUN else 1.0


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


## 参数：无。返回值：当前侧倾角（**弧度**，正 = 向右压弯，已写到 body.rotation.z）。
## 副作用：无。供测试脚本/调试读取；正常表现为转向时短暂偏离 0、随后回正到 0。
## 当前侧倾角（供测试/调试）
func get_lean() -> float:
	return _lean


## 参数：无。返回值：模型当前的 yaw（弧度，范围与 atan2 一致：-π ~ +π）。
## 副作用：无。调用方（camera_rig）用它算"本次想转的总角度"，再传给 notify_facing_change()。
## 注意：body 为 null（模型加载失败）时回退成**自身** rotation.y；本节点自己并不被旋转
##   （朝向都写在 body 上），所以那种情况下返回值近似常量（推测）：转身检测会失效，但不会崩。
## 当前模型朝向 yaw（供相机控制器检测转身）
func get_facing_yaw() -> float:
	return body.rotation.y if body != null else rotation.y

# ==================== 移动状态联动（走 / 跑 / 侧移 / Idle） ====================
# ---------- 移动状态联动 ----------

## 告知"这一帧玩家有没有在水平移动"，并在必要时切换移动动画。
## 参数：m —— true = 正在移动，false = 停下（停下的分支由 _update_move_anim 播 Idle）。
## 返回值：无。调用时机：camera_rig 每物理帧调用（**每帧都调**，内部做了"同值无害"处理）。
## 副作用：
##   * 写 _moving；
##   * 移动且当前有测试动作 → 打断动作（置 _action_active/_action_loop = false），
##     使移动能立刻接管动画；
##   * 若既不在动作态也不在滞空 → 调 _update_move_anim() 立即更新动画；
##     处于动作/滞空时**不动动画**（保持动作/跳跃姿势，由各自的结束路径恢复）。
## 注意：持续施法（_spell_casting）是唯一例外，移动**不会**打断它 ——
##   spell_caster 不会因为移动就停止喷法术，动画若被走路顶掉就成了"火在喷、人却在走"。
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

## 参数：无。返回值：true = 加速键被按住（**不代表真的在跑**，还要结合当前速度）。
## 副作用：无。用途：精力值（Vitals/耐力）系统按它决定是否消耗；移动动画也由 set_running 驱动。
## 当前是否处于"加速"状态（camera_rig 每帧告知 = 按住 Shift）。
## 精力值系统读它；注意它只代表"按着加速键"，是否真在跑还要结合 velocity 判断。
func is_running() -> bool:
	return _running


## 告知"加速键（Shift）这一帧是否按下"，据此决定走还是跑。
## 参数：r —— true = 加速（跑），false = 普通走。
## 返回值：无。调用时机：camera_rig 每物理帧调用。
## 副作用：写 _running；不在动作态/滞空时立刻 _update_move_anim()。
## 说明：真正的跑步动画 = 与走路**同一条剪辑** + RUN_ANIM_SPEED(1.4×) 播放速度（见 _play_move_anim）。
## 注意：本状态只代表"按着加速键"，是否真的在跑还要结合速度判断（精力值系统读 is_running()）。
func set_running(r: bool) -> void:
	_running = r
	if _action_active or _jump_air:
		return
	_update_move_anim()

## 按当前 _moving / _running / _lateral 决定并播放移动动画（内部核心分发，_physics_process 以外
## 的多条"恢复路径"也都汇到这里）。
## 参数：无。返回值：无。
## 副作用：调 _play_move_anim()（可能 play + 改 speed_scale）或直接 _play_anim(Idle)。
## 优先级：移动中先看侧向速度 —— |_lateral| 超过 LATERAL_ANIM_THRESHOLD 且不在转向动作里，
##   用侧移动画（Strafe_Left/Right）；否则按 _running 选 Running_A / Walking_A。
## 注意：停下走的是 `_move_anim = ANIM_IDLE` + **直接** `_play_anim(ANIM_IDLE)`，
##   而不是 _play_move_anim()：即跳过"同一剪辑且仍在播就跳过"那层判断，
##   保证从跑步停下时一定会重新 play，并借 _play_anim 把 speed_scale 复位回 1.0
##   （否则会以跑步的 1.4× 播放待机）。
func _update_move_anim() -> void:
	if _moving:
		if absf(_lateral) > LATERAL_ANIM_THRESHOLD and _turn_timer <= 0.0:
			_play_move_anim(ANIM_STRAFE_R if _lateral > 0.0 else ANIM_STRAFE_L)
		else:
			_play_move_anim(ANIM_RUN if _running else ANIM_WALK)
	else:
		_move_anim = ANIM_IDLE
		_play_anim(ANIM_IDLE)

# ==================== 跳跃（动画与物理对齐） ====================
## 起跳：播放跳跃动画，滞空期间保持。
## ★ 动画与物理对齐（保持原 speed/gravity 手感，改动画一侧）：
##   源动作 Standing Torch Jump 是三段式：0~0.51 下蹲蓄力｜0.51~0.935 腾空（0.425s）｜0.935~1.7 落地缓冲。
##   1) 起跳直接 seek 到 0.51（否则空中播的是"下蹲"）；
##   2) 腾空段按"物理滞空 / 0.425"反向缩放播放速度 → 腾空结束时正好落地；
##   3) 落地后由 _update_move_anim/on_land 恢复 1.0× 播落地缓冲。
## 跳跃剪辑里"腾空段"的起点时间（秒）：起跳后直接 seek 到这里，避免空中播"下蹲蓄力"
const JUMP_AIR_START := 0.51
## 腾空段本身的时长（秒，= 0.935 - 0.51）。它是 speed_scale 的换算基准：
## 物理滞空 air_time 越长，播放速度就被压得越慢，使腾空段正好在落地时播完。
const JUMP_AIR_SECONDS := 0.425


## 参数：air_time —— 本次跳跃的**物理滞空时长**（秒）。默认 0.722，与 camera_rig 的跳跃参数
##   配套；函数内用 maxf(0.05, air_time) 兜底，所以传 0 也不会除零。
##   调大 → 腾空动画放得更慢（speed_scale 更小），两者一起变。
## 返回值：无。
## 副作用：置 _jump_air = true、清 _action_active、播放 Jump_Full_Long、seek 到腾空段起点、
##   改写 anim_player.speed_scale，并打印一行 [跳跃] 日志。
## 调用时机：camera_rig 在起跳瞬间调用一次；收尾在 on_land()。
## 注意：_jump_air 为真期间，set_moving / set_running 都**不会**切换动画
##   （保证空中一直播跳跃姿势，不会被走路顶掉）。
func on_jump(air_time := 0.722) -> void:
	if anim_player == null:
		return
	_jump_air = true
	_action_active = false
	_play_anim("Jump_Full_Long")
	if anim_player.current_animation != "":
		anim_player.seek(JUMP_AIR_START, true)
		anim_player.speed_scale = JUMP_AIR_SECONDS / maxf(0.05, air_time)
		print("[跳跃] 滞空 %.3f s → 腾空段 %.3f s，播放速度 ×%.2f" % [
			air_time, JUMP_AIR_SECONDS, anim_player.speed_scale])

## 落地：恢复移动/Idle
## 参数：无。返回值：无。调用时机：camera_rig 检测到落地后调用一次。
## 副作用：清 _jump_air；把 anim_player.speed_scale 恢复成 1.0（腾空的慢放只用于空中，
##   落地要立刻按正常速度播落地缓冲）；若没有动作在播则恢复移动/Idle 动画。
## 注意：若这一帧有动作（_action_active）在播，则**不抢**动画，交给动作自己的结束路径。
func on_land() -> void:
	_jump_air = false
	# 腾空段的慢放只用于空中：落地立刻恢复 1.0× 播落地缓冲、并回到移动/Idle
	if anim_player != null:
		anim_player.speed_scale = 1.0
	if _action_active:
		return
	_update_move_anim()

# ==================== 动作播放（动作菜单 / 快捷键触发） ====================
# ---------- 动作播放（动作菜单/快捷键触发） ----------

## 获取动作注册表
## 参数：无。返回值：ACTION_LIB 常量数组本身（**不是副本**：调用方只读，不要就地改写）。
## 每项结构：[显示名, 动画名, 模式]，模式取值 "one"/"loop"/"move"（含义见 ACTION_LIB 上方注释）。
func get_action_lib() -> Array:
	return ACTION_LIB

## 参数：无。返回值：无。
## 副作用：置 _action_active = true、_action_loop = false、清 _jump_air、设 _cast_timer =
##   CAST_DURATION(0.9 s)，然后播放 CAST_ANIM("Spellcasting"，挥舞法杖的循环剪辑**限时**播一次)。
## 调用时机：放置物体/施放一次性法术时由法术系统调用。
## 注意：
##   * 持续施法期间（_spell_casting）直接返回 —— 否则 _cast_timer 到点会清掉 _action_active，
##     把正在循环的施法动画当场打断，而法术其实还在喷；
##   * anim_player 为 null 或**没有 CAST_ANIM 这个剪辑**时直接返回（不进入动作态）；
##   * CAST_ANIM 必须在 LOOP_CLIPS 白名单里，否则循环播放会定格在末帧。
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

# ==================== 持续施法（法术系统驱动） ====================
# ---------- 持续施法（法术系统驱动，见 scripts/spells/spell_caster.gd） ----------

## 开始/维持持续施法。法术系统每帧调用，**内部做了幂等**：
## 只有当前剪辑不是施法动画时才 play() —— 直接每帧 play() 会把剪辑重置回第一帧，
## 看起来就是"卡在起手式抖动"。幂等还有第二个好处：起跳等打断之后能自动把姿势找回来。
func start_spell_cast() -> void:
	var ca := _clip(CAST_ANIM)
	if anim_player == null or not anim_player.has_animation(ca):
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
	if anim_player.current_animation != ca or not anim_player.is_playing():
		anim_player.play(ca)

## 参数：无。返回值：无。副作用：清 _spell_casting / _action_active / _action_loop；
##   若不在滞空、也不在家具互动中，则恢复移动 / Idle 动画。
## 调用时机：松手 / 换法术 / 取消选中时由 spell_caster 调用（可安全重复调用：本函数幂等）。
## 注意：_interact 非空（坐在家具上）时**不抢**动画，交给家具互动状态机。
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

## 参数：无。返回值：true = 正在持续施法（按住施法键期间）。
## 副作用：无。用途：让其它系统判断"现在能不能被移动动画打断"（见 set_moving 的例外）。
## 注意：与一次性放置手势 _cast_timer 不同 —— 后者是 0.9 s 后自动结束的短暂动作。
## 是否正在持续施法
func is_spell_casting() -> bool:
	return _spell_casting

# ==================== 家具互动（坐 / 睡 / 爬梯） ====================
## ---------- 家具互动（坐/睡/爬梯） ----------

## 参数：
##   kind    —— 互动类型："sit"（坐）/ "sleep"（躺）/ "climb"（爬梯）。其它值会被 match 忽略
##              （但仍会进入互动态并播当前动画），所以调用方必须传这三种之一。
##   target  —— 家具**底部中心**的世界坐标（米）；XZ 两轴直接对齐到这里。
##   yaw     —— 坐下后的模型朝向（弧度）。直接写 body.rotation.y，**不走平滑转向**，
##              所以互动是瞬间对准的（家具场景下这是想要的观感）。
##   stand_h —— 家具"可用高度"：sit / sleep 是椅面 / 床面高；climb 是**梯子总高**（决定爬到哪）。
## 返回值：无。
## 副作用：清 _cast_timer 与 _jump_air、置 _interact、**直接瞬移** global_position.x/z、
##   写 body.rotation.y、置 _action_active / _action_loop = true，按 kind 抬高 y 并播对应动画。
## 调用时机：家具交互（E 键）在玩家靠近家具时调用一次；退出走 stop_interact()。
## 注意：爬梯的持续上升不在这里，而是在 _physics_process 里按 CLIMB_SPEED 推进
##   （本函数只负责设置起点与 _interact_top_y）。
## 开始家具互动；target 为家具底部中心世界坐标，stand_h 为椅面/床面/梯高
func start_interact(kind: String, target: Vector3, yaw: float, stand_h: float) -> void:
	_cast_timer = 0.0
	_jump_air = false
	_interact = kind
	# 直接写坐标而非走物理：互动语义就是"吸附到家具"，允许与家具发生几何重叠
	# （家具不在 collision_mask 里，物理本来也不会拦）；退出后由 stop_interact 交还控制。
	global_position.x = target.x
	global_position.z = target.z
	body.rotation.y = yaw
	_action_active = true
	_action_loop = true
	# 抬高的比例是"人坐在家具面上"的经验值（推测：坐姿重心约在椅面高的 0.55、
	# 躺姿约 0.5）。换家具高度或换角色模型后可能需要微调这两个系数。
	match kind:
		"sit":
			global_position.y = target.y + stand_h * 0.55
			_play_anim("Sit_Floor_Idle")
		"sleep":
			global_position.y = target.y + stand_h * 0.5
			_play_anim("Lie_Down")
		"climb":
			global_position.y = target.y
			# 爬梯：起点在家具底部 y，目标顶 = 底部 y + 梯高；_physics_process 每帧朝它收，
			# 到达即自动 stop_interact()（所以这里不需要额外的"到顶回调"）。
			_interact_top_y = target.y + stand_h
			_play_anim("kaykit/Climbing")

## 参数：无。返回值：无。
## 副作用：清 _interact 与动作态（_action_active/_action_loop），并恢复移动/Idle 动画。
## 调用时机：移动键 / E 键触发；**爬梯到顶时也由 _physics_process 自动调用**（当作"到达"）。
## 注意：_interact 为空时直接返回（幂等），可以放心重复调用。
## 退出家具互动（移动键/E 触发），恢复移动/Idle
func stop_interact() -> void:
	if _interact == "":
		return
	_interact = ""
	_action_active = false
	_action_loop = false
	_update_move_anim()

## 参数：无。返回值：true = 处于家具互动中（坐 / 睡 / 爬梯，判据是 _interact != ""）。
## 副作用：无。用途：让移动/施法等系统知道"现在动画归家具互动管，别抢"。
## 是否正在家具互动
func is_interacting() -> bool:
	return _interact != ""

## 参数：index —— ACTION_LIB 的下标（0 起，合法范围 0 ~ ACTION_LIB.size()-1）。
## 返回值：**实际播放的剪辑名**（含库前缀，已做档案映射）；越界 / 剪辑不存在时返回 ""。
## 副作用：置动作态（_action_active = true、_action_loop 由注册表模式决定）、清 _jump_air，
##   然后 play()。**不设 speed_scale**（沿用上一状态留下的值）。
## 注意：这里只区分 "loop" 与其它 —— 注册表里的 "move"（移动类）在本函数里会被当成
##   一次性动作；真正的移动类交给移动状态机处理，不要靠本函数播。
## 按索引播放动作；返回实际动画名（不可用时返回空串）
func play_action(index: int) -> String:
	if anim_player == null or index < 0 or index >= ACTION_LIB.size():
		return ""
	var entry: Array = ACTION_LIB[index]
	var anim: String = _clip(String(entry[1]))
	var mode: String = entry[2]
	if not anim_player.has_animation(anim):
		return ""
	_action_active = true
	_action_loop = (mode == "loop")
	_jump_air = false
	anim_player.play(anim)
	return anim

## 参数：无。返回值：无。
## 副作用：清动作态（_action_active/_action_loop）；**不在滞空时**才恢复移动/Idle 动画
##   （空中被打断仍要保持跳跃姿势直到落地）。
## 调用时机：动作菜单关闭 / 玩家操作打断；与 play_action() 配对使用。
## 停止当前动作并回到移动/Idle（供菜单关闭/玩家操作打断）
func stop_action() -> void:
	if anim_player == null:
		return
	_action_active = false
	_action_loop = false
	if not _jump_air:
		_update_move_anim()

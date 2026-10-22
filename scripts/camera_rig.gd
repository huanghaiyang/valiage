## ============================================================================
## camera_rig.gd —— 第一人称 / 第三人称 / 斜俯视（等距）相机控制器
## ============================================================================
##
## 【本文件职责】
##   1) 读键鼠输入并**驱动角色物理**：水平移动、重力、跳跃都由本文件算完写进
##      player.velocity，再调用 player.move_and_slide()。
##      ⚠ 分工：player.gd 的 _physics_process() **不做移动**（只跑动画/抬步平滑/爬梯），
##      角色位置的实际推进者只有本文件。
##   2) 每物理帧摆放相机：第一人称（隐藏身体）/ 第三人称跟随 / iso_locked 斜俯视锁定。
##   3) 地面法线采样与平滑（修三角网逐面法线跳变导致的抖动/被弹开）、坡度速度规则、
##      裂缝守卫（防走进窄缝被 move_and_slide 的去穿插瞬间弹飞）。
##   4) 屏幕空间"遮挡挖洞"：挡在相机→角色之间的树/房子，只在角色屏幕位置抠一个洞淡化。
##   5) 对外提供准星 / 鼠标射线的地面落点查询（放置类工具用）。
##
## 【所属系统】角色控制 + 相机（场景里挂在 main.tscn 的 CameraRig 节点上）
##
## 【关键依赖】
##   · autoload：本文件**不直接引用**任何 autoload（只用引擎内建 Input / RenderingServer /
##     Time / PhysicsDirectSpaceState3D 等）。项目里的 Game / Settings / Weather / Vitals
##     等由 main.gd、player.gd 侧使用。
##   · 注入引用（**不要假设 _ready() 时已就绪**）：
##       camera: Camera3D      ← main.gd::_wire_camera_rig()
##       player: Player        ← main.gd::_wire_camera_rig()
##       terrain: TerrainSystem← world_builder.gd::build()
##       _current_yaw/_current_pitch ← world_builder.gd::place_spawn() 出生时直接写入
##   · 着色器：res://scripts/shaders/occlusion_hole.gdshader（见 const OCCLUSION_SHADER），
##     依赖 project.godot 的 [shader_globals] 中注册的 occ_player_uv / occ_radius /
##     occ_softness / occ_hole_alpha 四个全局 uniform，缺一个就会在写 uniform 时报错。
##   · 反向依赖（别随意改签名 / 语义）：
##       main.gd    —— zoom_by()（滚轮缩放）、get_ground_point_mouse()（放置落点）、
##                     interact_freeze（家具互动）、is_mouse_captured()、
##                     iso_yaw_deg（右键拖动旋转场景，main 会直接写这个 @export）
##       minimap.gd —— iso_yaw_deg（小地图朝向随场景旋转）
##       tests/test_player_slope.gd   —— 反射调用 crack_verdict() / slope_speed_factor()
##       tests/test_ground_normal.gd  —— 反射调用 median_normal() / sample_ground_up() /
##                                       update_ground_up()
##
## 【主要对外接口】
##   aim_from_player()                出生/装配阶段：让角色面向镜头前方（背对相机）
##   zoom_by(dir) -> bool             滚轮缩放（dir=+1 拉远，-1 拉近；返回是否真的变了）
##   set_ui_capture(bool)             UI 请求释放/恢复鼠标捕获
##   is_mouse_captured() -> bool      查询鼠标是否被捕获
##   get_center_ray() -> Array        屏幕中心射线 [origin, dir]（准星拾取）
##   get_ground_point_mouse(terrain)  鼠标位置的地面落点（俯视角放置用，可能返回 null）
##   get_ground_point_center(terrain) 屏幕中心的地面落点（可能返回 null）
##   测试钩子：test_move_override     （非零时替代键盘输入，headless 测试用）
##
## 【坐标与朝向约定（与 world/features/spawn_point.gd 共用，务必别改）】
##   · _current_yaw 用弧度。由角色指向**相机**的水平方向 = (sin(yaw), 0, cos(yaw))
##     （第三人称相机就摆在这个方向的后方），因此**角色朝向** = (-sin(yaw), 0, -cos(yaw))，
##     即角色永远背对第三人称相机。绕 Y 旋转 yaw 的节点其 -Z 轴恰好也是这个向量。
##   · pitch 约定：负 = 相机低于注视点/向上看；正 = 相机抬高并俯视。
##   · 与 spells/spell_aim.gd 的区别：法术方向**不要**照抄本文件的 (-sin, 0, -cos)，
##     那是"相机的 -Z 约定"，不是施法方向（spell_aim.gd 里有专门注记）。
##
## 【已知的坑 / 注意事项】
##   1. 本文件是角色位置的唯一驱动者：任何"直接改 player.global_position"的写法都必须
##      避开 Terrain3D 模式（见 _physics_process 末尾的刷地同步分支），否则会与物理打架。
##   2. interact_freeze = true（坐/睡/爬梯）时本文件只摆相机、不碰物理，位置由 player.gd
##      的互动逻辑接管；忘记复位会让角色永久定住（main.gd 每物理帧写这个标志）。
##      注意 main.gd 还会**借用**这个标志做调试截图（--aerial/--cam 时置 true，见其注释），
##      所以"交互冻结"不是它唯一的用途。
##   3. ESC / T / F2 在 _unhandled_input 里被直接消费，会和 game_ui / settings_menu 抢键；
##      改键位前先搜这两处（项目里有相关历史注记）。
##   4. 遮挡挖洞是**性能热点**：_rescan_occluders() 曾经是物理帧 59ms 的主因，
##      现在靠"位移门槛早退"+ occlusion_max_hits 降层数压下来，调参前先读那几处注释。
##   5. 注释语言中文、标识符英文；查不到实现依据的推断会在注释里标"（推测）"。
##
class_name CameraRig
extends Node3D
## 第一/第三人称相机控制器（默认第三人称）
## WASD 移动 · 鼠标旋转视角 · Shift 加速跑 · Space 跳跃 · T 切换视角 · Esc 释放/捕获鼠标

# ==================== 依赖注入（main.gd / world_builder.gd 赋值） ====================
## 输出相机（场景里是 CameraRig/Camera3D 子节点）。**可能为空**：
## main.gd::_wire_camera_rig() 在 _ready() 之后才注入，所以本文件各处都先判空。
## 缺它时：摆位、射线查询全部不可用（_update_occlusion_fade 会走清洞分支）。
@export var camera: Camera3D
## 受控角色（Player = CharacterBody3D + 胶囊）。本文件负责写它的 velocity 并调用
## move_and_slide()，所以它才是"被驱动的那个 body"；为空时 _ready() 只接管鼠标。
@export var player: Player
## 地形系统（TerrainSystem）。用途：get_height_at() 取地表高度（穿透兜底 / 放置点贴地）、
## using_terrain3d() 判断是否跳过老的"刷地同步"、以及读取 _last_brush_* 刷地记录。
## 由 world_builder.gd::build() 注入，为空会在 _physics_process 末尾取高度处崩。
@export var terrain: TerrainSystem

# ==================== 移动 / 跳跃参数 ====================
## 平常走路速度（米/秒）。默认 5.0（快走量级）。跑步由 run_speed 单独给，
## 加速度本身不做惯性平滑（速度瞬时切换，靠动画与抬步遮掩）。
@export var move_speed := 5.0
## 按住 Shift 的跑步速度（米/秒）。默认 9.0 = move_speed 的 1.8 倍；
## 动画侧用 player.RUN_ANIM_SPEED（1.4× 播放速度）来匹配，改本值不影响动画快慢。
## "是否在跑"每帧通过 player.set_running(running) 告知（精力值 Vitals 也读它）。
@export var run_speed := 9.0
# ==================== 跳跃与重力 ====================
## 跳跃：保持原手感（初速 6.5 / 重力 18 → 滞空 2v/g = 0.722 s、峰值 1.17 m）。
## 动画侧由 player.on_jump(滞空秒数) 自动把"腾空段"拉伸到这个时长，保证两者匹配。
## 起跳初速（米/秒）。默认 6.5：配 gravity=18 → 峰值 v²/2g = 1.17m、滞空 0.722s。
## 调大 = 跳得更高更久（动画腾空段会自动跟着拉长，见上一行注释）。
## 注意滞空时长是 2*jump_speed/gravity 传给 player.on_jump() 的，改任一项动画都会重算。
@export var jump_speed := 6.5
## 重力加速度（米/秒²）。默认 18.0 ≈ 现实 9.8 的 1.8 倍，手感更"干脆"、下坠更快。
## 只用于本文件 _velocity_y 的积分（player 自己不做重力）；调大 = 跳跃变矮、落地更快。
@export var gravity := 18.0
# ==================== 坡度速度规则 ====================
## 坡度速度规则（只影响"平常走路/跑步"的水平速度）：
##   上坡减速、下坡加速，两者都按坡度角线性过渡，并被下面两个比例**钳住**。
## 两个限制都是"相对当前基础速度"的比例 —— 基础速度已经含 Shift 跑步，
## 所以走路(5)与跑步(9)各自按同一比例受限，不需要为跑步再写一套。
## slope_speed_angle 设为 0 或负数 = 关闭整条规则。
@export var slope_speed_angle := 40.0
@export var slope_speed_min_ratio := 0.45   ## 上坡最低速度比例（走路 5→2.25，跑步 9→4.05）
@export var slope_speed_max_ratio := 1.25   ## 下坡最高速度比例（走路 5→6.25，跑步 9→11.25）
# ==================== 裂缝 / 窄坑守卫 ====================
## 裂缝/窄坑守卫：角色走进窄缝会扎进地形，move_and_slide 去穿插时会把它"瞬间弹走"。
## 所以在缝边就拦住：向前探一步，若前方地面下沉、而对面在 crack_max_width 内又回到脚面高度，
## 判定为"缝"（不是悬崖），本帧不允许朝这个方向移动。
@export var crack_guard := true
@export var crack_probe_ahead := 0.55      ## 向前探多远（约半个身位）
@export var crack_max_drop := 0.45         ## 下沉超过这个深度才算"前方是坑"
@export var crack_max_width := 1.6         ## 对面在这么远内重新升高 → 是缝而非悬崖
# ==================== 视角 / 鼠标 / 视距参数 ====================
## 鼠标灵敏度（弧度/像素）：本帧 yaw 变化量 = 鼠标 relative.x × 本值。
## 默认 0.0028 ≈ 横移 560px 转一圈（2π）。调大 = 更灵敏（易晕），调小 = 更稳。
## 只影响"鼠标被捕获且未锁定俯视角"时的转视角；iso_locked 下完全不生效。
@export var mouse_sensitivity := 0.0028
## 垂直视角是否反转。默认关：鼠标上移 = 抬头。
## 不同玩家习惯差别很大，运行时按 F2 切换，也可以在检查器里改。
@export var invert_y := false
## 抬头下限（弧度）。默认 -1.45 ≈ -83°：几乎能仰到正上方。
## 运行时还会被"仰视角动态限制"再夹一次（前方地形越高允许抬头越少），见 _physics_process 末尾。
@export var min_pitch := -1.45
@export var max_pitch := 0.4     # 限制俯视最大角度，避免镜头看到地面以下
## 第一人称"眼睛"高度（米，相对角色根节点）。默认 1.28 ≈ 1.5m 身高的眼部。
## 只用于第一人称分支：相机位置 = 角色根 + (0, visual_height() + eye_height, 0)。
## 调小 = 视线更矮；调大可能看不见脚下（第一人称已隐藏 body，不会穿自己）。
@export var eye_height := 1.28
## 交互/放置射线的"近距探测距离"（米）。默认 18.0。
## get_ground_point_*() 先按这个长度打地形层(层2)；没命中才用 GROUND_RAY_MAX 再补一次。
## 调小 = 只能点近处；调大 = 更容易命中远处地面（放置点还会被 PLACE_MAX_DIST 拉回）。
@export var interact_range := 18.0

# ==================== 第三人称跟随相机距离 ====================
# 第三人称相机参数
## 第三人称机位：**整个偏移向量**（水平距离 + 高度）都按 0.5 缩了一档（用户要求"拉近 50%"）。
## 注意只改 tps_distance 是不对的：相机位置是
##   eye + yaw*(cos(pitch)*D) + up*(tps_height + sin(pitch)*D)
## 高度里那项 tps_height 是**常数**偏移，只把 D 减半会让相机相对角色抬高、
## 变成俯视头顶；两个一起缩才是"沿同一条视线拉近"。
# 再拉远 25%：2.4/1.0 -> 3.0/1.25（同样是整个偏移向量一起缩，
# 只改距离会让相机相对角色抬高、变成俯视头顶）
@export var tps_distance := 3.0
## 第三人称相机的**高度**偏移（米），叠加在视线高度上：相机 y = eye + tps_height + sin(pitch)·D。
## 默认 1.25（原来是 1.0，随 tps_distance 一起按比例缩放，见上面两段注释）。
## 它是**常数**偏移：只改 tps_distance 而不同步改本值，相机会相对角色抬高、变成俯视头顶。
@export var tps_height := 1.25

# ==================== 斜俯视（等距）锁定模式参数 ====================
## ---- 俯视角（暗黑破坏神 4 那种斜俯视）----
## 锁定后：鼠标不再转相机、朝向与俯角固定、相机跟着角色跑，
## 但 WASD 仍然是"按相机朝向"移动（这条别改，否则锁定后手感全乱）。
@export var iso_locked := true
@export var iso_yaw_deg := 45.0      # 斜 45 度是经典等距视角
## 相机俯角。**52° 太陡**：那个角度基本在俯视头顶，角色的侧身/轮廓看不见
## （用户反馈"只能看到角色头部"）。42° 保留斜俯视观感，同时能看到身体侧面。
@export var iso_pitch_deg := 42.0
## 到角色的距离。14m 时角色只占屏幕高度约 10%（720p 下实测 ~74px），
## 那个尺寸下只能辨认出头顶的帽子。12m 放大 17%；再把俯角从 52° 降到 42°
## （角色竖直方向的投影系数 cos42°/cos52° ≈ 1.21），屏幕上高度约 74px → 104px。
## 滚轮仍可在 75%~200% 之间缩放（0.75 时约 9m）。
@export var iso_distance := 12.0
## 滚轮缩放：只是 iso_distance 的倍率。0.75 = 最近（当前距离的 75%），2.0 = 最远
@export var iso_zoom := 1.0
## 滚轮缩放下限倍率：0.75 = 最近（iso_distance 的 75%，默认 12m → 9m）。
## 再近角色会占满屏幕、地形细节穿帮，所以设了下限。
const ISO_ZOOM_MIN := 0.75
## 滚轮缩放上限倍率：2.0 = 最远（默认 12m → 24m）。
const ISO_ZOOM_MAX := 2.0
## 每一格滚轮改变的倍率。0.12 时从最远拉到最近约 11 格（手感偏"细"，
## 想要更快就调大；改变它不影响 MIN/MAX 的钳制范围）。
const ISO_ZOOM_STEP := 0.12
@export var iso_look_height := 1.15  # 注视点抬高 -> 角色落在画面偏下
@export var iso_fov := 45.0          # 小 FOV 减少透视畸变，更像 D4

# ==================== 遮挡穿透（挖洞）开关与参数 ====================
# ---- 遮挡穿透（相机被挡住时把挡路物体淡化）----
@export var occlusion_fade := true       # 总开关
## 洞的半径 = 角色在屏幕上的高度 * 这个系数（越大抠得越多）
## ★ 角色的挖洞范围：**整体缩小一半** ✓（用户要求）
##   原来 1.05 → 现在 0.525 ✓（radius = max(hole_min_radius, 角色像素高/屏高 × 本值) ✓）
@export var hole_radius_scale := 0.525
## 最小半径**同步减半** ✓（原来 0.06 → 0.03 ✓）—— 否则贴很近时会被这个下限顶住、
## 看起来像"没缩小" ✗。想只改倍率就把本行改回 0.06 ✓。
@export var hole_min_radius := 0.03
@export var hole_softness := 0.035       # 洞边缘过渡宽度（UV）
@export var hole_alpha := 0.08           # 洞内保留的不透明度（0=全透，1=不淡）
@export var occlusion_probe_interval := 0.08   # 采样间隔（秒）
## 候选物体名单的重建间隔（秒）。树/房子会被笔刷不断增删，定期重扫一遍最简单。
@export var occlusion_candidate_interval := 1.0
## 只考虑离角色这么近的候选（米）。更远的树不可能挡住近在眼前的角色。
@export var occlusion_candidate_range := 40.0
## 挡路判定用**物理射线打真实碰撞体**，而不是包围盒。
## 包围盒分不清"树干在旁边"和"树叶真的挡在前面"：树冠的盒子有 4.6×10.7×4.3m，
## 角色一走进盒子范围（离树 2~3m）线段就已经穿过盒子，于是被判成"被挡住"
## （用户反馈："人物一靠近物体，物体就会被挖洞"）。
## 只有这一层上的碰撞体算遮挡物。本项目：地形=2，**建筑/树=4**，植被=8。
@export_flags_3d_physics var occlusion_layer_mask := 4
## 单条采样线最多穿透几层遮挡物（密林里相机到角色之间可能叠着好几棵）。
## ★ 性能（实测）：8 层 × 采样线数 是重扫 50ms 的主因；实测叠 3 层以上已属罕见，
##   降到 3 可少 60% 以上射线；"看得到角色"的观感基本不变（想更稳就调回 5）。
@export var occlusion_max_hits := 3
## 放进这个组的节点（含子树）永不挖洞，给"不想被透视"的物件留后门。
const OCCLUSION_IGNORE_GROUP := &"occlusion_ignore"
## 挖洞着色器（只影响被遮挡的那一块，不是整棵变透明）
const OCCLUSION_SHADER := preload("res://scripts/shaders/occlusion_hole.gdshader")

# ==================== 运行时状态（每帧被改写，非导出） ====================
## 第三人称开关。true = 相机跟随在角色身后（默认）；false = 第一人称（隐藏 body、镜头在眼高）。
## 只在 iso_locked = false 时才会走到这条分支；T 键在锁定模式里改的是 iso_locked 本身。
## 改这个值不会自动改相机 fov（第三人称默认 75，俯视角用 iso_fov）。
var third_person := true
## 当前水平朝向（弧度）。相机方向 = (sin, 0, cos)，角色朝向 = (-sin, 0, -cos)（背对相机）。
## 写入者：_unhandled_input（鼠标）、_physics_process（iso 锁定强制写回 / 未捕获时 lerp 到移动方向）、
## world_builder.gd::place_spawn()（出生时直接赋值）。
var _current_yaw := 0.0
## 当前俯仰（弧度）。负 = 相机低于注视点（抬头），正 = 相机抬高（俯视）。
## 第三人称里它同时决定相机高度（sin(pitch)×tps_distance）与 look_at 的俯角，
## 每帧被 [min_pitch_dyn, max_pitch] 夹紧（iso_locked 时被强制写回 -iso_pitch_deg）。
var _current_pitch := 0.0
## 鼠标是否被引擎捕获（光标隐藏并锁定）。**本项目默认 false**（俯视角要点鼠标），
## 只影响 _unhandled_input 是否用鼠标移动转视角，以及未捕获时朝向是否跟移动方向。
var _mouse_captured := true
var _velocity_y := 0.0       # 垂直速度（跳跃/重力）
# ★ 平滑后的地面法线（"法线中值"）：修掉三角网逐面法线跳变导致的抖动/被弹开
var _ground_up := Vector3.UP
## 是否已经有可采信的地面法线。false 时调用方退回 player.get_floor_normal()（引擎逐面法线），
## true 之后才按 _ground_up 做速度与投影计算；第一次站地后置 true，之后即使离地也保持 true
## （离地时用慢速率把法线拉回世界竖直）。
var _ground_ready := false
const GROUND_SMOOTH_RATE := 14.0    # 时域平滑速率（越大跟得越快）
var _space_prev := false     # 上一帧空格状态（防按住连跳）
## 冻结开关：true 时 _physics_process() 只走 _update_camera_only()，**完全不驱动物理**。
## 写入者：main.gd 每物理帧写 player.is_interacting()（家具互动：坐/睡/爬梯），
## 另外 main.gd 的调试截图路径（--aerial / --cam）也会借用它来"抢走相机控制权"。
## 副作用（本文件侧）：跳过移动/重力/抬步/地形同步等整段逻辑。
var interact_freeze := false    # 家具互动期间冻结角色物理驱动（位置由 player 管理）

# ==================== 遮挡挖洞：运行时缓存与计时器 ====================
## 遮挡挖洞：MeshInstance3D -> 是否已装洞材质
var _occ_holes := {}
## 本轮采样中"判定为遮挡"的网格集合（每轮 _rescan_occluders() 开头清空）。
## 采样结束后的差集 = 上一轮挖了洞、这一轮不再挡路的网格 → 卸洞恢复原材质。
var _occ_seen := {}
## MeshInstance3D -> 烘好的挖洞材质（按 surface 下标）。
## 挖洞是"命中就装、离开就卸"，树一多会每 0.08s 反复 new/丢 ShaderMaterial；
## 缓存下来只切换 override，省掉分配与材质重建的抖动。
var _occ_mat_cache := {}
## 可能挡住角色的网格（场景里的 MeshInstance3D，排除角色自身），定期重建
var _occ_candidates: Array = []
## 上面这些网格里哪些**有碰撞体**（MeshInstance3D -> true）。
## 有碰撞体的走物理射线精确判定；没有的（编辑器里手摆的模型）才退回包围盒兜底。
var _occ_backed := {}
## 候选名单重建倒计时（秒）：<= 0 或名单为空时重扫一遍场景里的 MeshInstance3D。
## 周期 = occlusion_candidate_interval；重扫只是遍历节点树，比重扫射线便宜得多。
var _occ_cand_timer := 0.0
## 射线采样倒计时（秒）：<= 0 时跑一轮 _rescan_occluders()。周期 = occlusion_probe_interval。
## 与 _occ_cand_timer 分开计时：两者的代价与"该多久做一次"完全不同。
var _occ_timer := 0.0
## ★ 性能（实测）：`_rescan_occluders()` 是**物理帧最大开销**——关掉它物理帧从 59ms 掉到 1.1ms。
##   这两个成员用于"位移门槛早退"：角色/相机几乎没动时，遮挡物集合不会变，直接跳过本轮重扫。
var _occ_last_player := Vector3.ZERO
## 上一轮重扫时的相机世界位置。与 _occ_last_player 一起做"位移门槛早退"：
## 两者都几乎没动 → 遮挡物集合不会变 → 整轮 _rescan_occluders() 直接跳过。
var _occ_last_camera := Vector3.ZERO
## 是否**至少**完成过一轮重扫。false 时不做早退判断（第一轮必须跑，否则永远不挖洞）。
var _occ_ever_scanned := false
## 挖孔全局量是否已复位成"不挖"（避免 _clear_occ_globals() 每帧重复写）
var _occ_globals_cleared := false
## 位移阈值（米）：小于它就认为"没动，不必重扫"。想更灵敏就调小（如 0.02）。
@export var occlusion_move_epsilon := 0.05
var ui_override := false     # UI（动作菜单等）占用时让出鼠标/键盘控制

# ==================== 生命周期：初始化 ====================
## 节点就绪回调。Godot 的 _ready() 自下而上执行，所以 main.gd（父节点）的 _ready()
## **晚于**本函数：这里别指望 camera/player/terrain 已注入，它们由
## main.gd::_wire_camera_rig() 与 world_builder.gd::build() 在装配阶段赋值。
## 副作用：
##   ① 把鼠标设为"可见不捕获"（俯视角要点鼠标，捕获光标反而没法瞄准/放置）；
##   ② player 非空时调用 aim_from_player()，让角色出生就面向镜头前方（呈现背影）。
## 注意：本函数对 player 判了空 —— 注入顺序变了最多少一次朝向初始化，不会崩。
func _ready() -> void:
	# 玩家引用可能尚未注入（父节点 _ready() 晚于子节点）：先接管鼠标，
	# 角色朝向与出生点由 main.gd 在装配阶段调用 aim_from_player() 完成。
	# **鼠标默认不锁定**（俯视角不需要它转相机）：锁定时鼠标转视角已经关掉了，
	# 再捕获光标只会让人没法用鼠标瞄准。放置改成"以鼠标位置为准"，见 get_ground_point_mouse()。
	_set_mouse_captured(false)
	if player != null:
		aim_from_player()

## 依据当前 yaw/pitch 让角色面向镜头前方（出生时呈现背影）
## 参数/返回值：无。副作用：调用 player.face_direction()，改角色模型的 rotation.y（朝向）。
## 取 fwd = (-sin(_current_yaw), 0, -cos(_current_yaw))（本项目"角色朝向"约定），
## 并以 delta=10.0 调用 → 平滑转向会**一步转到位**（见函数内注释）。
## 调用时机：_ready()（player 已注入时）、world_builder.gd::place_spawn() 设好
## _current_yaw/_current_pitch 之后。player 为空时静默返回。
func aim_from_player() -> void:
	if player == null:
		return
	var fwd := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
	# ★ 传一个足够大的 delta 让它**一步到位**：face_direction 的单帧步长会被夹到
	#   "剩余角度"，所以这一下必定转满。出生点朝向必须一次定死 ——
	#   平滑转向下每帧只转 ~15°，而本函数只在装配阶段被调一次（world_builder.gd），
	#   只转一步的话角色出生时是歪的。
	player.face_direction(fwd, 10.0)

## 唯一写 Input.mouse_mode 的地方（例外：main.gd 右键拖动旋转场景时会自己临时捕获光标）。
## 参数：captured = true → MOUSE_MODE_CAPTURED（隐藏+锁定，鼠标移动事件连续可用于转视角）；
##       false → MOUSE_MODE_VISIBLE（默认，俯视角/点选 UI 用）。
## 副作用：改 Input.mouse_mode，并把状态记进 _mouse_captured（供 is_mouse_captured() 查询、
##         _unhandled_input 与"未捕获时朝向跟移动方向"逻辑读取）。
## 调用时机：_ready()（固定传 false）、ESC 切换、set_ui_capture()（UI 打开/关闭面板）。
func _set_mouse_captured(captured: bool) -> void:
	_mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

## UI（动作菜单等）请求释放/恢复鼠标捕获
## 参数：captured = true 捕获（隐藏锁定光标），false 恢复可见。
## 副作用：直接转调 _set_mouse_captured()（即写 Input.mouse_mode 与 _mouse_captured）。
## 调用者：ui/game_ui.gd 等面板开关时。注意与 ESC 键的处理存在竞争，
## 面板关闭时若把光标重新捕获，玩家就没法用鼠标点击放置（历史坑，见 game_ui.gd 注记）。
func set_ui_capture(captured: bool) -> void:
	_set_mouse_captured(captured)

# ==================== 输入处理 ====================
## 未被 UI 消费的输入回调（被 Control 吃掉的事件不会到这里）。
## 处理三类：① 鼠标移动 → 转视角（仅 _mouse_captured 且 **非** iso_locked 时）；
##          ② ESC → 切换鼠标捕获；③ T → 在"斜俯视锁定 / 第三人称"间切换；F2 → 垂直反转。
## 副作用：改 _current_yaw / _current_pitch / iso_locked / third_person / camera.fov /
##         invert_y，并 print 中文提示（调试用，控制台可见）。
## ui_override = true 时**整段早退**（UI 占用键鼠期间不抢输入）。
## 注意：三个键位是硬编码的，且没有 accept_event()；game_ui / settings_menu 也处理 ESC，
##       靠 _unhandled_input 的传播顺序决定谁生效（项目里有相关历史注记）。
func _unhandled_input(event: InputEvent) -> void:
	if ui_override:
		return
	if event is InputEventMouseMotion and _mouse_captured and not iso_locked:
		# 俯视角锁定：鼠标不再转相机（D4 也是完全不能转视角）
		# 这里是**减法**：鼠标右移（relative.x > 0）→ yaw 减小 → 相机方向 (sin,cos) 顺时针转，
		# 角色朝向 (-sin,-cos) 同步跟着转。别改成加法，否则左右会反过来。
		_current_yaw -= event.relative.x * mouse_sensitivity
		# 鼠标上移→抬头（pitch 减小），下移→低头（pitch 增大），并夹紧到上下限。
		# invert_y 打开时整体反号（F2 切换）。
		var dy: float = event.relative.y * mouse_sensitivity
		if invert_y:
			dy = -dy
		_current_pitch = clampf(_current_pitch + dy, min_pitch, max_pitch)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_set_mouse_captured(not _mouse_captured)
		elif event.keycode == KEY_T:
			# 锁定俯视角时，第三人称分支永远走不到 -> T 改成切换"锁定"本身
			if iso_locked:
				iso_locked = false
				third_person = true
				camera.fov = 75.0
				print("[camera] 俯视角锁定 = 关（回到第三人称）")
			else:
				iso_locked = true
				print("[camera] 俯视角锁定 = 开（暗黑破坏神式斜俯视）")
		elif event.keycode == KEY_F2:
			invert_y = not invert_y
			print("[camera] 垂直视角反转 = %s" % str(invert_y))

# ==================== 遮挡穿透（屏幕空间挖洞） ====================
## ---------------- 遮挡穿透（屏幕空间挖洞） ----------------
##
## 只把"盖住角色"的那块抠掉，模型其余部分照旧不透明 ——
## 这样既能看到角色，又不会整棵树糊成一片半透明。

## 每帧：更新角色的屏幕位置/半径（写全局 uniform）+ 定期重新采样遮挡物。
func _update_occlusion_fade(delta: float) -> void:
	if not occlusion_fade or camera == null or player == null:
		_clear_all_holes()
		# ★ 关掉遮挡（或相机/角色还没绑定/已解绑）时，必须把**全局量**也复位成"不挖"。
		#   只清 override 材质是不够的：树的洞是着色器自己按全局量画的，
		#   不复位就会"洞停在最后一次的屏幕位置"（换场景/换绑相机后尤其明显）。
		_clear_occ_globals()
		return
	_occ_globals_cleared = false
	# --- 角色在屏幕上的位置与半径 ---
	var vp := get_viewport().get_visible_rect().size
	if vp.y < 1.0:
		return
	var base: Vector3 = player.global_position
	var p_top := camera.unproject_position(base + Vector3(0.0, 1.75, 0.0))
	var p_bot := camera.unproject_position(base)
	var h_px: float = (p_top - p_bot).length()
	var uv := Vector2(0.5, 0.5)
	# 洞中心取在**离地 0.9m（胸口）**而不是脚底：挖洞是为了露出角色躯干，
	# 抠在脚下会把角色脚下的地面也一起淡化（看起来像地面破了个洞）。
	var pr := camera.unproject_position(base + Vector3(0.0, 0.9, 0.0))
	if vp.x > 1.0 and vp.y > 1.0:
		uv = Vector2(pr.x / vp.x, pr.y / vp.y)
	var radius: float = maxf(hole_min_radius, (h_px / vp.y) * hole_radius_scale)
	# 这三个全局 uniform 必须先在 project.godot 的 [shader_globals] 里注册
	# （编辑器扫描着色器时会自动写进去；命令行跑就得手动加，否则这里会报
	#  "!global_shader_uniforms.variables.has(p_name)"）
	RenderingServer.global_shader_parameter_set("occ_player_uv", uv)
	RenderingServer.global_shader_parameter_set("occ_radius", radius)
	RenderingServer.global_shader_parameter_set("occ_softness", hole_softness)
	RenderingServer.global_shader_parameter_set("occ_hole_alpha", hole_alpha)

	# --- 定期重建候选名单 + 重新采样 ---
	_occ_cand_timer -= delta
	if _occ_cand_timer <= 0.0 or _occ_candidates.is_empty():
		_occ_cand_timer = occlusion_candidate_interval
		_collect_occlusion_candidates()
	_occ_timer -= delta
	if _occ_timer <= 0.0:
		_occ_timer = occlusion_probe_interval
		# ★ 性能（实测）：整轮重扫 ≈ 50ms 的顿挫（8 条采样线 × 最多 8 次链式射线），
		#   而 `occlusion_probe_interval` 只有 0.08s -> 每 80ms 卡一次。
		#   这里加"位移门槛早退"：角色与相机几乎没动时，遮挡物集合不会变，直接跳过本轮。
		if player == null:
			_rescan_occluders()          # 未就绪时保持原行为（它内部自己判空）
		else:
			var pos_now := player.global_position
			var cam_now := camera.global_position if camera != null else pos_now
			if not _occ_ever_scanned \
					or _occ_last_player.distance_to(pos_now) > occlusion_move_epsilon \
					or _occ_last_camera.distance_to(cam_now) > occlusion_move_epsilon:
				_occ_last_player = pos_now
				_occ_last_camera = cam_now
				_occ_ever_scanned = true
				_rescan_occluders()


# ==================== 遮挡挖洞：候选名单 ====================
## 重建"可能挡住角色"的候选网格名单。
##
## **为什么不再用物理射线找遮挡物**：射线只能回答"这条线上最近的是谁"。
## 实测：屏幕上包围盒盖住角色的树有 19 棵，射线方案只挖到 4 棵 —— 就是反馈的
## "遮挡角色的树木过多，还是看不到角色"。屏幕空间判定问的是"这块网格在屏幕上
## 盖不盖住角色"，几十棵叠在一起也能一次全挖掉。
## 附带好处：不再要求物体有碰撞体、也不用管碰撞层，编辑器里手摆的模型照样生效。
func _collect_occlusion_candidates() -> void:
	_occ_candidates.clear()
	_occ_backed.clear()
	var scene := get_tree().current_scene
	if scene == null:
		return
	# player 可能还是 null（注入顺序）：传 null 时下面的 `c == player_node` 自然不成立，
	# 不会误跳过任何节点 —— 只是这一轮把角色自己也算进候选（首轮常见，下一轮就好了）。
	_collect_candidates_under(scene, player as Node)


## 递归遍历子树，收集"可能挡住角色"的候选网格。
## 参数：n = 当前遍历到的节点（首次调用传 current_scene）；player_node = 角色节点。
## 跳过规则：① c == player_node 整棵子树跳过（给角色自己挖洞就成透明的了）；
##           ② c.is_in_group(OCCLUSION_IGNORE_GROUP) 整棵子树跳过（留后门）。
## 副作用：往 _occ_candidates 追加 MeshInstance3D；往 _occ_backed 记录该网格有无碰撞体。
## 注意：递归深度 = 场景树深度（树/房子是叶子，实际不深）；
##       `c is MeshInstance3D` 会连同它的子树一起继续递归（合并后的物体子件也要收）。
func _collect_candidates_under(n: Node, player_node: Node) -> void:
	for c in n.get_children():
		if c == player_node:
			continue                       # 角色自己的模型：挖自己的洞就成透明的了
		if c.is_in_group(OCCLUSION_IGNORE_GROUP):
			continue                       # 留后门：这棵子树永不挖洞
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			if mi.mesh != null:
				_occ_candidates.append(mi)
				_occ_backed[mi] = _mesh_has_collider(mi)
		_collect_candidates_under(c, player_node)


## 网格是否"有碰撞体"：自己、子孙、或往上 3 层内出现 CollisionObject3D。
## 有碰撞体的走物理射线（贴着模型，精确）；没有的才退回包围盒兜底。
func _mesh_has_collider(mi: MeshInstance3D) -> bool:
	var cur: Node = mi
	var depth := 0
	while cur != null and depth < 3:
		if cur is CollisionObject3D:
			return true
		for c in cur.get_children():
			if c is CollisionObject3D:
				return true
		cur = cur.get_parent()
		depth += 1
	return false


## 角色身上用于"是否被挡"判定的采样点（世界空间）：头 / 胸 / 胯 + 左右肩。
## 用多个点是为了覆盖轮廓：只打中线的话，从侧后方斜着盖住半个身子的树冠会被漏掉
## （那是"树木过多还是看不到角色"的老问题）。
func _char_sample_points() -> Array:
	var base: Vector3 = player.global_position
	var right: Vector3 = camera.global_transform.basis.x
	var chest := base + Vector3(0.0, 1.0, 0.0)
	return [base + Vector3(0.0, 1.7, 0.0),
			chest,
			base + Vector3(0.0, 0.25, 0.0),
			chest + right * 0.35,
			chest - right * 0.35]


## 每轮：找出真正挡在"相机 → 角色"之间的物体，给它们的网格挖洞。
##
## **判定用物理射线打真实碰撞体**，不用包围盒。包围盒分不清"树干在旁边"和
## "树叶真的挡在前面"：树冠的盒子有 4.6×10.7×4.3m，角色只要走进盒子范围
## （离树 2~3m），"相机→角色"的线段就已经从盒子空着的上半部分穿过去了，
## 于是被判成"被挡住" —— 表现就是"人物一靠近物体，物体就被挖洞"（用户反馈）。
## 碰撞体是贴着模型的（秋树笔刷场景用的就是模型的三角网），射线打上去才知道真假。
##
## 每条采样线**一路打穿**：`intersect_ray` 只返回最近的一个碰撞体，密林里
## 相机到角色之间叠着好几棵，只挖最近那棵的话，透过洞看到的还是第二棵完整的树
## （老反馈："树木过多还是看不到角色"）。
func _rescan_occluders() -> void:
	_occ_seen.clear()
	if camera == null or player == null:
		return
	var base: Vector3 = player.global_position
	var cam_pos: Vector3 = camera.global_position
	var samples := _char_sample_points()
	var space := get_world_3d().direct_space_state
	# 角色自己的碰撞体永远排除：否则射线停在角色身上，后面的树一棵都查不到
	var player_rid := RID()
	# 取 player.gd 内部的可视根节点 body（var body: Node3D），拿它的 RID 用于射线排除。
	var body: Variant = player.get("body")
	if body is CollisionObject3D:
		player_rid = (body as CollisionObject3D).get_rid()
	# ---- ① 物理射线（贴着真实模型，精确）----
	for sp in samples:
		var to: Vector3 = sp
		var from: Vector3 = cam_pos
		var dir: Vector3 = to - from
		if dir.length_squared() < 0.0001:
			continue
		dir = dir.normalized()
		var exclude: Array[RID] = []
		if player_rid.is_valid():
			exclude.append(player_rid)
		for _i in occlusion_max_hits:
			var params := PhysicsRayQueryParameters3D.create(from, to)
			params.exclude = exclude
			params.collide_with_areas = false
			params.collision_mask = occlusion_layer_mask
			var hit := space.intersect_ray(params)
			if hit.is_empty():
				break
			var col: Object = hit.get("collider")
			if col is CollisionObject3D:
				# 已命中的物体排除掉，否则下一轮打到的还是它
				exclude.append((col as CollisionObject3D).get_rid())
			# 沿射线方向推进 5cm 再打下一发：不退让就会**重复命中同一个碰撞体**，
			# 链式射线立刻原地打转、挖不到后面的第二棵树。
			from = (hit.get("position", from) as Vector3) + dir * 0.05
			if from.distance_squared_to(to) < 0.01:
				break                      # 已经贴到采样点，别再往回打
			if col == null or not (col is Node):
				continue
			var root := _occluder_root(col as Node)
			if root == null:
				continue
			for gi in _geometry_instances(root):
				if gi is MeshInstance3D:
					_occ_seen[gi] = true
					if not _occ_holes.has(gi):
						_install_hole(gi as MeshInstance3D)
	# ---- ② 没有碰撞体的物件（编辑器里手摆的模型）：才退回包围盒兜底 ----
	# **但要求角色在它包围盒之外** —— 否则"人走进树冠盒子就挖洞"的误判又回来了。
	# 宁可漏挖这类物件，也不要一靠近就乱挖。
	var range_sq := occlusion_candidate_range * occlusion_candidate_range
	for c in _occ_candidates:
		# 先判存活再转换：候选可能已被释放（例如卡位监测的标记会自行回收），
		# 对已释放对象做 as 转换会报 "Trying to cast a freed object"。
		if not is_instance_valid(c):
			continue
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		if _occ_backed.has(mi):
			continue                       # 有碰撞体：上面射线已经处理过
		if not is_instance_valid(mi) or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		if mi.global_position.distance_squared_to(base) > range_sq:
			continue
		var ab_world: AABB = mi.global_transform * mi.mesh.get_aabb()
		if ab_world.has_point(base):
			continue                       # 角色就在盒子里，分不清 -> 不挖
		var blocks := false
		for sp in samples:
			var pt: Vector3 = sp
			# 4.7 的 intersects_segment 返回交点 Vector3 或 null（不是 bool），按类型判断
			var hit: Variant = ab_world.intersects_segment(cam_pos, pt)
			if typeof(hit) == TYPE_VECTOR3 or (typeof(hit) == TYPE_BOOL and bool(hit)):
				blocks = true
				break
		if not blocks:
			continue
		_occ_seen[mi] = true
		if not _occ_holes.has(mi):
			_install_hole(mi)
	# 不再挡路的：恢复
	for gi in _occ_holes.keys():
		if not is_instance_valid(gi):
			_occ_holes.erase(gi)
			_occ_mat_cache.erase(gi)
			continue
		if not _occ_seen.has(gi):
			_remove_hole(gi as MeshInstance3D)


## 射线打到的是碰撞体（通常挂在模型实例下面），往上找到"那一个被放置的物体"。
## **先看自己有没有几何体、再看父节点**：上一版先判 `父 == 场景根` 就 return，
## 结果"直接挂在场景根下的手摆物体"永远找不到（早期 Bug）。
func _occluder_root(n: Node) -> Node3D:
	var cur: Node = n
	var depth := 0
	var scene := get_tree().current_scene
	while cur != null and depth < 6:
		if cur == scene:
			return null                   # 兜底：别把整个场景当成一个物体
		if cur is Node3D and _has_geometry(cur):
			return cur as Node3D
		cur = cur.get_parent()
		depth += 1
	return null


## 判断节点自身、直接子节点（只看一层）里有没有 GeometryInstance3D。
## 参数：n = 待检查节点。返回：true = 这个节点就是（或直接包着）可视几何体。
## 用途：_occluder_root() 靠它决定"往上找到哪一层算一个被放置的物体"。
## 副作用：无（纯查询）。
func _has_geometry(n: Node) -> bool:
	if n is GeometryInstance3D:
		return true
	for c in n.get_children():
		if c is GeometryInstance3D:
			return true
	return false


## 收集以 root 为根的**整棵子树**里的所有 GeometryInstance3D（含 root 自身）。
## 参数：root = 起点节点（通常是 _occluder_root() 找出的"被放置的物体"）。
## 返回：Array，元素是 GeometryInstance3D（可能不是 MeshInstance3D，调用方要自己判）。
## 实现：显式栈的迭代式深度优先（栈比递归更适合这棵会被笔刷不断改动的树，
##       也不用担心偶发深层的节点树）。pop_back 决定顺序为"后进先出"。
## 副作用：无（只读场景树）。
func _geometry_instances(root: Node3D) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


# ==================== 遮挡挖洞：材质安装 / 卸载 ====================
## 装洞：优先复用缓存材质，只切 override（树木多时别再每轮重新 new 一遍）
func _install_hole(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	var n := mi.mesh.get_surface_count()
	var mats: Array = _occ_mat_cache.get(mi, [])
	# 表面数对不上 = 这个网格被换过（缓存失效），必须重烘；
	# 对得上就直接复用缓存材质，只切 override（见 _occ_mat_cache 的说明）。
	if mats.size() != n:
		mats = _build_hole_materials(mi, n)
		_occ_mat_cache[mi] = mats
	for i in n:
		if mats[i] != null:
			mi.set_surface_override_material(i, mats[i])
	_occ_holes[mi] = true


## 按原材质烘出每个 surface 的挖洞材质；拿不到原材质的 surface 记 null（保持原样）
func _build_hole_materials(mi: MeshInstance3D, n: int) -> Array:
	var out: Array = []
	out.resize(n)
	for i in n:
		var src := mi.get_active_material(i)
		if not (src is StandardMaterial3D):
			# 自定义着色器材质：拿不到它的贴图，退回原材质不动（别把模型弄白）
			out[i] = null
			continue
		var std := src as StandardMaterial3D
		var m := ShaderMaterial.new()
		m.shader = OCCLUSION_SHADER
		if std.albedo_texture != null:
			m.set_shader_parameter("albedo_tex", std.albedo_texture)
		m.set_shader_parameter("roughness", std.roughness)
		m.set_shader_parameter("metallic", std.metallic)
		# 这三样以前漏了，才导致"被挖洞的物体贴图变了"
		m.set_shader_parameter("uv_scale_offset",
				Vector4(std.uv1_scale.x, std.uv1_scale.y,
						std.uv1_offset.x, std.uv1_offset.y))
		m.set_shader_parameter("use_vertex_color", std.vertex_color_use_as_albedo)
		if std.normal_enabled and std.normal_texture != null:
			m.set_shader_parameter("normal_tex", std.normal_texture)
			m.set_shader_parameter("normal_strength", std.normal_scale)
			m.set_shader_parameter("use_normal_map", true)
		m.set_shader_parameter("tint", std.albedo_color)
		out[i] = m
	return out


## 卸洞：把该网格所有 surface 的 override 材质清回 null，恢复原材质。
## 参数：mi = 要恢复的网格。副作用：改渲染状态 + 从 _occ_holes 移除记录；
## **不动** _occ_mat_cache —— 材质留着下次复用（树多时反复 new/丢 ShaderMaterial 会抖）。
## 注意：网格已被释放或 mesh 为空时，也会顺手清掉 _occ_holes 里的记录，避免留下野引用。
func _remove_hole(mi: MeshInstance3D) -> void:
	if not is_instance_valid(mi) or mi.mesh == null:
		_occ_holes.erase(mi)
		return
	for i in mi.mesh.get_surface_count():
		mi.set_surface_override_material(i, null)
	_occ_holes.erase(mi)


## 一次性卸掉**所有**洞并清空三个缓存（_occ_holes / _occ_seen / _occ_mat_cache）。
## 调用时机：_update_occlusion_fade() 开头 —— 总开关关掉、或 camera/player 引用缺失时。
## 副作用：把每个网格的 override 材质清回 null（恢复原材质），并丢弃全部缓存；
##         下次重新开启遮挡淡化会重新烘材质（可接受，因为这是"配置/装配"级事件）。
## 把"挖孔全局量"复位成**不挖**（occ_hole_alpha = 1.0、半径 0）。
## 调用时机：_update_occlusion_fade() 的"关掉遮挡 / 相机或角色缺失"分支。
## 为什么需要：全局量是渲染器级的；只卸 override 材质（_clear_all_holes）不复位全局量的话，
##   关掉遮挡或换绑相机后，树着色器里的洞会**固定在最后一次的屏幕位置**。
## 只写一次（_occ_globals_cleared 守护），重新开启遮挡时该标志会被清掉。
func _clear_occ_globals() -> void:
	if _occ_globals_cleared:
		return
	_occ_globals_cleared = true
	RenderingServer.global_shader_parameter_set("occ_radius", 0.0)
	RenderingServer.global_shader_parameter_set("occ_hole_alpha", 1.0)


func _clear_all_holes() -> void:
	for gi in _occ_holes.keys():
		if is_instance_valid(gi):
			_remove_hole(gi as MeshInstance3D)
		else:
			_occ_mat_cache.erase(gi)
	_occ_holes.clear()
	_occ_seen.clear()
	_occ_mat_cache.clear()


# ==================== 主循环：物理帧（角色驱动 + 相机摆放） ====================
## 每物理帧（默认 60Hz）的总调度。执行顺序是有意的，别随意调换：
##   ① _update_occlusion_fade(delta)：遮挡挖洞（用上一帧的位置，代价可忽略）
##   ② iso_locked 时**强制写回**固定 yaw/pitch（下面有两处逻辑会改它们）
##   ③ interact_freeze 时只摆相机就 return（位置交给 player.gd 的互动逻辑）
##   ④ WASD → 坡度速度系数 → 裂缝守卫 → 让角色 face_direction() 转向移动方向
##   ⑤ 重力/跳跃积分 → 按平滑地面法线投影 → 写 player.velocity → player.move_and_slide()
##   ⑥ 采样并平滑地面法线 → 扬尘 → 自动抬步 → 侧移/转身过渡 → 落地/离地回调
##   ⑦ 地形高度同步与穿透兜底（**Terrain3D 模式整段跳过**，否则会与物理打架）
##   ⑧ 仰视角动态限制 → 按 iso/第三人称/第一人称摆相机 → 设置 body 显隐
## 参数：delta = **物理帧**时长（秒）。内部绝不要用 get_process_delta_time()（那是渲染帧长，
##       在"物理 60Hz / 渲染 144Hz"下不相等，会让转向速度随刷新率漂移）。
## 副作用：写 player.velocity / player.global_position.y / 角色朝向 / 相机变换 / 洞材质，
##         并调用 player 的 on_jump/on_land/update_dust/try_step_up 等。
## 注意：本函数是**角色位置唯一的推进者**，player.gd::_physics_process() 不做移动。
func _physics_process(delta: float) -> void:
	_update_occlusion_fade(delta)
	if iso_locked:
		# 每帧强制写回固定朝向与俯角：下面还有"爬坡时动态夹紧俯角"
		# 和"鼠标没捕获时朝向跟移动方向"两段逻辑，都会把这个值改掉。
		_current_yaw = deg_to_rad(iso_yaw_deg)
		_current_pitch = -deg_to_rad(iso_pitch_deg)
	# 家具互动（坐/睡/爬梯）期间：冻结移动/重力驱动，位置由 player 管理，相机仍跟随
	if interact_freeze:
		_update_camera_only()
		return
	# WASD 水平移动：始终响应键盘（不依赖鼠标捕获）
	var moved := false
	var dir := _get_move_input()
	var move_xz := Vector3.ZERO
	var running := Input.is_key_pressed(KEY_SHIFT)
	var yaw_before: float = player.get_facing_yaw()
	## 本次**想转到的**朝向。要传它而不是"本帧实际转过的角度"给 notify_facing_change，
	## 才反映得出"转身幅度"——平滑转向下每帧最多转 15°，永远够不到 45° 阈值
	## （见 player.gd::notify_facing_change 的注记）。
	var turn_want_yaw := yaw_before
	player.set_running(running)
	if dir.x != 0.0 or dir.y != 0.0:
		moved = true
		var forward := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
		var right := Vector3(cos(_current_yaw), 0.0, -sin(_current_yaw))
		var face := forward * dir.y + right * dir.x
		var base_speed := run_speed if running else move_speed
		# 上坡减速、下坡加速、限制在 min/max 比例内。地形和物体模型的坡面走的是同一套
		# floor_normal，所以"在物体上移动"自动同样生效。
		# ★ 用**平滑后**的地面法线（逐面法线会跳变 -> 速度因子每帧抖）
		var factor := slope_speed_factor(_ground_up if _ground_ready else player.get_floor_normal(), face.normalized(), player.is_on_floor())
		move_xz = face * base_speed * factor
		# 裂缝守卫：前方是窄缝时本帧停下（否则会扎进地形、被去穿插弹飞）
		if player.is_on_floor() and face.length_squared() > 0.001:
			if crack_ahead(get_world_3d().direct_space_state, player.global_position, face.normalized()):
				move_xz = Vector3.ZERO
		# 角色面向水平移动方向
		if face.length_squared() > 0.001:
			turn_want_yaw = atan2(face.x, face.z)
			player.face_direction(face.normalized(), delta)
		# 鼠标释放时旋转视线短暂面向移动方向，便于无鼠标浏览
		if not _mouse_captured:
			_current_yaw = lerp_angle(_current_yaw, atan2(-face.x, -face.z), 8.0 * delta)

	# 重力 + 跳跃：用物理引擎 is_on_floor 判断地面
	# 注意：on_floor 为真时必须把垂直速度归零。旧写法保留上一帧的负值，
	# 会和贴地吸附互相拉扯，导致上坡/上台阶被"拽住"。
	if not player.is_on_floor():
		_velocity_y -= gravity * delta
	else:
		_velocity_y = 0.0

	var space_now := Input.is_key_pressed(KEY_SPACE)
	if space_now and not _space_prev and player.is_on_floor():
		_velocity_y = jump_speed
		player.on_jump(2.0 * jump_speed / gravity)   # 把本次滞空时长交给动画，用于拉伸腾空段
	_space_prev = space_now

	# ★ 先把水平移动按**平滑地面**投影一次，并把投影得到的 y 分量带上：
	#   旧写法 velocity.y 只放 _velocity_y，等于"水平向量是平的"，
	#   引擎只能每帧拿逐三角法线去重新投影 -> 三角网地形上必然抖动/被弹开。
	if player.is_on_floor() and _ground_ready:
		var before_proj := move_xz
		move_xz = move_xz.slide(_ground_up)
		if move_xz.length_squared() < 0.0001:
			move_xz = before_proj            # 兜底：别把移动整帧吃掉
	# 用 move_and_slide 走物理碰撞（地面/建筑/树的碰撞体生效，禁止穿入）
	var was_air := not player.is_on_floor()
	player.velocity = Vector3(move_xz.x, move_xz.y + _velocity_y, move_xz.z)
	player.move_and_slide()
	# ★ 采样并平滑地面法线（要在 move_and_slide 之后，is_on_floor 才是本帧结果）
	update_ground_up(delta)

	# ★ 脚底灰尘：用 move_and_slide **之后**的真实水平速度驱动
	#   （撞墙/上坡/被挡时真实速度会掉下来 -> 灰尘自然变小，不用额外判断）
	var hv := Vector2(player.velocity.x, player.velocity.z).length()
	var dust_ratio := 0.0
	if player.is_on_floor() and hv > player.DUST_SPEED_MIN:
		dust_ratio = clampf((hv - player.DUST_SPEED_MIN) / maxf(0.001, run_speed - player.DUST_SPEED_MIN), 0.0, 1.0)
		dust_ratio = pow(dust_ratio, 1.3)     # 起步轻、跑起来明显
	player.update_dust(dust_ratio)

	# 自动抬步：被低台阶/小突起挡住时跨上去（楼梯无需按 E；E 只留给梯子）
	# ★ 门槛放宽：原来只在 is_on_floor 时尝试，而顶在小突起上时 is_on_floor 往往已为假
	#   -> 抬步根本不触发 -> 卡死。现在"被挡住且不在上升"也允许尝试。
	var blocked_now := player.get_slide_collision_count() > 0
	if moved and move_xz.length_squared() > 0.001 and (player.is_on_floor() or (blocked_now and _velocity_y <= 0.0)):
		if player.try_step_up(move_xz):
			_velocity_y = 0.0

	# 转向过渡：侧向速度 → 侧移动画；朝向突变 → 转向动画 + 压弯
	# ★ 传"想转的角度"而不是"本帧实际转过的角度"（见 turn_want_yaw 的注释）
	var yaw_after: float = player.get_facing_yaw()
	player.notify_facing_change(angle_difference(yaw_before, turn_want_yaw))
	player.set_lateral(_lateral_speed(move_xz, yaw_after))
	player.update_turn(delta, moved, running)

	if player.is_on_floor():
		_velocity_y = 0.0
		if was_air:
			player.on_land()
	elif player.in_step_grace():
		# 抬步后短暂无接触帧：抑制重力，避免刚上踏面就被拉回
		_velocity_y = 0.0

	# 地形高度同步与防穿透
	# 1) 刷地同步：仅在刷地后短暂窗口内（0.5s），且角色位于刷地影响范围且接近地面时，
	#    高度直接跟随地形高度（网格 0.1s 先更新、碰撞 0.35s 后更新，此间隙内角色不再悬空/被埋/卡住）。
	#    窗口结束后恢复正常物理，角色可在已下陷/抬升的地形上正常跳跃。
	# **Terrain3D 接管时整段跳过**：地形碰撞由 Terrain3D 自己提供，
	# 再用 get_height_at() 去"吸回地表"会和 move_and_slide 打架 ——
	# 高度图值与碰撞面在坡地上有出入，于是"瞬移上去 -> 物理落回"反复发生，
	# 表现就是角色在非平坦地面上**上下抖动**（用户报的 bug）。
	# 老的刷地同步也只对已删除的程序化地形有意义，这里一并停用。
	var th := terrain.get_height_at(player.global_position.x, player.global_position.z)
	if not terrain.using_terrain3d():
		var bc := terrain._last_brush_center
		var br := terrain._last_brush_radius
		var in_brush := false
		if bc != Vector3.ZERO and br > 0.0:
			var bdx := player.global_position.x - bc.x
			var bdz := player.global_position.z - bc.z
			in_brush = bdx * bdx + bdz * bdz < (br + 1.2) * (br + 1.2)
		if in_brush and Time.get_ticks_msec() - terrain._last_brush_time < 500 and absf(player.global_position.y - th) < 1.5:
			player.global_position.y = th + 0.05
			_velocity_y = 0.0
		elif player.global_position.y < th - 0.5:
			# 2) 深度穿透兜底：任何原因掉到地面以下都吸回地表
			player.global_position.y = th + 0.1
			_velocity_y = 0.0
	# Terrain3D 模式下的兜底：极端情况（掉出世界）才拉回来，平时绝不干预物理
	elif player.global_position.y < -50.0:
		player.global_position.y = th + 1.0
		_velocity_y = 0.0

	# 每帧都要告知（哪怕没输入）：player 用它决定走/跑/待机动画，并在玩家真正移动时
	# 打断"动作菜单"里播着的测试动作。
	player.set_moving(moved)

	# 仰视角动态限制：角色前方地形越高，允许抬头越少（避免低处看高山时镜头看到山体内部/穿模）
	var fwd2 := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
	var ahead := player.global_position + fwd2 * 8.0
	var ahead_h := terrain.get_height_at(ahead.x, ahead.z)
	var foot_h := terrain.get_height_at(player.global_position.x, player.global_position.z)
	var rise := ahead_h - foot_h
	var min_pitch_dyn := min_pitch
	if rise > 1.0:
		min_pitch_dyn = lerpf(min_pitch, -0.08, clampf((rise - 1.0) / 6.0, 0.0, 1.0))
	if not iso_locked:
		_current_pitch = clampf(_current_pitch, min_pitch_dyn, max_pitch)

	# 相机定位 + 角色模型显隐（第一人称隐藏身体，避免相机卡进头部）
	# 相机跟 visual_height()：抬步时根部瞬间上到台阶顶、模型缓动追上去，
	# 若跟根节点，上台阶瞬间镜头会先猛跳一下再被模型追平。
	var eye_y := player.visual_height()
	var focus := Vector3(player.global_position.x, eye_y, player.global_position.z)
	if iso_locked:
		player.set_body_visible(true)
		_place_iso_camera(focus)
	elif third_person:
		player.set_body_visible(true)
		var yaw_vec := Vector3(sin(_current_yaw), 0.0, cos(_current_yaw))
		var dist_h := cos(_current_pitch) * tps_distance
		var dist_v := sin(_current_pitch) * tps_distance
		var cam_pos := Vector3(player.global_position.x, eye_y, player.global_position.z) + yaw_vec * dist_h + Vector3(0.0, tps_height + dist_v, 0.0)
		camera.global_position = cam_pos
		camera.look_at(Vector3(player.global_position.x, eye_y + 1.05, player.global_position.z), Vector3.UP)
	else:
		player.set_body_visible(false)
		var rot := Basis.from_euler(Vector3(_current_pitch, _current_yaw, 0.0))
		camera.global_transform = Transform3D(rot, Vector3(player.global_position.x, eye_y + eye_height, player.global_position.z))

# ==================== 相机摆放 / 缩放（俯视角 · 第三人称 · 第一人称） ====================
## 俯视角机位：从 focus 正上方偏后按固定角度摆相机（暗黑破坏神 4 那种）。
## 与第三人称的区别是"完全不吃鼠标输入"，朝向/俯角/距离都是常量。
## 参数：focus = 注视点（调用方传"角色 x/z + visual_height()"，即胸口附近）。
## 返回/副作用：无返回值；写 camera.global_position、调用 camera.look_at()，
##              并在 fov 不同时把 camera.fov 设为 iso_fov（45°）。
## 几何：距离 d = iso_distance × iso_zoom；水平后退 d·cos(pitch)、抬高 d·sin(pitch)，
##       方位角用 iso_yaw_deg（main.gd 右键拖动会改它，所以不是绝对常量）。
func _place_iso_camera(focus: Vector3) -> void:
	var y := deg_to_rad(iso_yaw_deg)
	var p := deg_to_rad(iso_pitch_deg)
	var d := iso_distance * iso_zoom
	var horiz := d * cos(p)                 # 水平后退距离
	var vert := d * sin(p)                  # 抬高量
	camera.global_position = focus + Vector3(sin(y) * horiz, vert, cos(y) * horiz)
	camera.look_at(focus + Vector3(0.0, iso_look_height, 0.0), Vector3.UP)
	# 只在数值真的变了才写：给 camera.fov 重复赋同一个值也会触发投影矩阵重建，
	# 而这个函数每物理帧都会被调到（属避免无谓开销的写法）。
	if not is_equal_approx(camera.fov, iso_fov):
		camera.fov = iso_fov


## 滚轮缩放（未选任何放置工具时）：dir=+1 拉远、-1 拉近。
## 返回 true 表示这次滚轮被缩放吃掉了。
## 参数：dir = 步进方向（±1）；实际变化量 = dir × ISO_ZOOM_STEP，结果被
##       [ISO_ZOOM_MIN, ISO_ZOOM_MAX] 钳在 0.75~2.0 倍。
## 生效方式：只改 iso_zoom 这个**倍率**，真正摆位在 _place_iso_camera()（每帧读它）。
## 副作用：改 @export iso_zoom；返回 false 表示已到边界（调用方可据此不弹提示）。
## 注意方向**不是**由本函数决定的：main.gd 把滚轮上映射成 -1（拉近），调用前已取反。
func zoom_by(dir: int) -> bool:
	var before := iso_zoom
	iso_zoom = clampf(iso_zoom + dir * ISO_ZOOM_STEP, ISO_ZOOM_MIN, ISO_ZOOM_MAX)
	return not is_equal_approx(before, iso_zoom)


## 只返回水平移动方向（x=左右，y=前后）。跳跃在 _physics_process 单独处理。
## 互动冻结期间仅更新相机（跟随玩家位置/朝向）
# 注：上面两行 ## 是历史遗留的**错位文档**（实际描述的是 _get_move_input()，被放在了这里），
#     按"只新增注释、不改动已有行"的原则原样保留；下面几行才是 _update_camera_only() 的文档。
## 作用：家具互动（坐/睡/爬梯）期间的精简更新 —— 只按当前模式摆相机 + 设置 body 显隐，
## **完全不碰** player 的 velocity / 位置（那由 player.gd 的互动逻辑接管）。
## 参数/返回值：无。副作用：写 camera 的变换，并改 player.body.visible。
## 调用时机：_physics_process() 里 interact_freeze == true 时（main.gd 每帧从
##           player.is_interacting() 同步这个标志）。
## 注意：进入本函数前，_physics_process 已经处理过 iso_locked 的 yaw/pitch 强制写回，
##       所以这里可以直接按 iso_locked / third_person 分支。
func _update_camera_only() -> void:
	if iso_locked:
		player.set_body_visible(true)
		_place_iso_camera(Vector3(player.global_position.x, player.visual_height(),
				player.global_position.z))
		return
	if third_person:
		player.set_body_visible(true)
		var yaw_vec := Vector3(sin(_current_yaw), 0.0, cos(_current_yaw))
		var dist_h := cos(_current_pitch) * tps_distance
		var dist_v := sin(_current_pitch) * tps_distance
		var cam_pos := player.global_position + yaw_vec * dist_h + Vector3(0.0, tps_height + dist_v, 0.0)
		camera.global_position = cam_pos
		camera.look_at(player.global_position + Vector3(0.0, 1.05, 0.0), Vector3.UP)
	else:
		player.set_body_visible(false)
		var rot := Basis.from_euler(Vector3(_current_pitch, _current_yaw, 0.0))
		camera.global_transform = Transform3D(rot, player.global_position + Vector3(0.0, eye_height, 0.0))

# ==================== 坡度 / 裂缝守卫判定 ====================
## 朝向坐标系下的侧向速度分量（右为正）：用于选择侧移动画与压弯方向
## 坡度速度系数：只影响水平移动速度。
##   平地 / 空中 / 没输入 → 1.0（完全不影响现有手感）
##   上坡 → 1.0 向 slope_speed_min_ratio 过渡（越陡越慢）
##   下坡 → 1.0 向 slope_speed_max_ratio 过渡（越陡越快，但有上限）
##   斜着走 → 按"顺着坡走的分量"过渡，所以沿坡横移不会被误减速/误加速
## 返回前统一用 [min_ratio, max_ratio] 钳住，这就是最大/最小速度限制。
# 注：上面这几行 ## 是历史遗留的**错位文档**（实际描述的是 _lateral_speed() 与
#     slope_speed_factor()，本应写在那两个函数处）；按"只新增不改动已有行"的原则保留，
#     下面几行才是 crack_verdict() 的文档。
## 裂缝守卫**纯判定**（不碰物理，方便单测；物理探针见 crack_ahead）。
## 参数：feet_y = 角色脚底高度（世界 y）；has_ahead/ahead_y = 前方 crack_probe_ahead 处的地面
##       （has_ahead = false 表示那里打不到地面）；has_far/far_y = 更远处
##       （crack_probe_ahead + crack_max_width）的地面。
## 返回：true = 判定为"能卡住人的缝"，调用方应把本帧朝该方向的移动清零。
## 规则：① crack_guard 关 → false；② 前方无地但对面有地 → 缝；
##       ③ 前方下沉量 <= crack_max_drop → 不是缝（小坑洼，照常走）；
##       ④ 对面也没地 → 悬崖/深渊，放行（该掉就掉，不拦）；
##       ⑤ 对面回到脚面附近（far_y > feet_y - crack_max_drop）→ 缝。
## 副作用：无（纯函数；tests/test_player_slope.gd 直接反射调用它验证这些分支）。
## 纯判定：脚下高度 feet_y，前方地面 ahead_y（可能没有），对面 far_y（可能没有）。
## 前方下沉、且对面在 crack_max_width 内回到脚面高度 → 是"缝"，返回 true（要拦住）。
func crack_verdict(feet_y: float, has_ahead: bool, ahead_y: float,
		has_far: bool, far_y: float) -> bool:
	if not crack_guard:
		return false
	if not has_ahead:
		return has_far                       # 前方是空的，对面有地 → 缝
	if feet_y - ahead_y <= crack_max_drop:
		return false                         # 前方地面没怎么下沉（小坑洼），照常走
	if not has_far:
		return false                         # 对面也没有地 → 悬崖/深渊，允许过去（该掉就掉）
	return far_y > feet_y - crack_max_drop   # 对面回到脚面附近 → 是缝


## 物理探针：沿 dir 向前探，判断前方是不是"能卡住人的缝"
## 参数：space = 物理空间状态；feet = 角色脚底位置（世界坐标）；dir = 期望移动方向
##       （水平分量会被取用并归一化，y 分量忽略）。
## 返回：true = 前方是缝，本帧应拦下朝这个方向的移动。crack_guard 关或 direction 为 0 时 false。
## 做法：从脚面上方 0.4m 处、向前 crack_probe_ahead 与 crack_probe_ahead+crack_max_width
##       各向下打一条 4m 的射线，把两个高度交给 crack_verdict() 判定。
## 副作用：无（纯物理查询；_ray_down 会排除玩家自身碰撞体）。
func crack_ahead(space: PhysicsDirectSpaceState3D, feet: Vector3, dir: Vector3) -> bool:
	if not crack_guard or space == null:
		return false
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 0.0001:
		return false
	d = d.normalized()
	# 探针起点抬到脚面上方 0.4m：射线自上而下，才能量出"前方地面比脚下低多少"；
	# 起点贴脚面会因为地形起伏/台阶边缘而打不到地面（误判成悬崖）。
	var from := feet + Vector3.UP * 0.4
	var ahead_from := from + d * crack_probe_ahead
	var far_from := from + d * (crack_probe_ahead + crack_max_width)
	var a := _ray_down(space, ahead_from, 4.0)
	var b := _ray_down(space, far_from, 4.0)
	var has_a := not a.is_empty()
	var has_b := not b.is_empty()
	var ay: float = (a.get("position", Vector3.ZERO) as Vector3).y
	var by: float = (b.get("position", Vector3.ZERO) as Vector3).y
	return crack_verdict(feet.y, has_a, ay, has_b, by)


## 通用"向下打一条射线"工具（裂缝探针与地面法线采样共用）。
## 参数：space = 物理空间状态（调用方取 get_world_3d().direct_space_state）；
##       from = 起点（世界坐标）；dist = 向下探测长度（米）。
## 返回：intersect_ray 的字典（命中时含 position、normal；**未命中返回空字典**，
##       调用方用 is_empty() 判断，别用真值判断 —— 见 4.7 的类型坑注记）。
## 副作用：无（纯查询）。注意：collide_with_areas = false（Area3D 不算地面），
##       并排除玩家自身碰撞体（否则每个采样点都会打到自己、法线全变成胶囊侧面）。
func _ray_down(space: PhysicsDirectSpaceState3D, from: Vector3, dist: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.new()
	q.from = from
	q.to = from + Vector3.DOWN * dist
	q.collide_with_areas = false
	# 必须排除玩家自己的碰撞体：不然每个采样点都先打到自己（法线全是胶囊侧面），
	# 后面的地形根本打不到。
	if player != null:
		q.exclude = [player.get_rid()]
	return space.intersect_ray(q)


# ==================== 地面法线采样与平滑（抗三角网抖动） ====================
## 逐轴取**中值**（抗异常值）：三角网上某条射线可能正好打到一块陡面，
## 用平均会被它拽偏，中值不会 —— 这就是"法线中值"的核心。
func median_normal(normals: Array) -> Vector3:
	if normals.is_empty():
		return Vector3.UP
	var xs: Array = []
	var ys: Array = []
	var zs: Array = []
	for v in normals:
		var n: Vector3 = v
		xs.append(n.x)
		ys.append(n.y)
		zs.append(n.z)
	xs.sort()
	ys.sort()
	zs.sort()
	# 三个轴各自排序后取同一位置（size()/2，整数除法）：这是"逐轴中值"，
	# 不是"离平均法线最近的那一个"；偶数个时取偏上的那个，够用且不引入平均。
	var mid: int = xs.size() / 2
	var med := Vector3(xs[mid], ys[mid], zs[mid])
	if med.length_squared() < 0.000001:
		return Vector3.UP
	med = med.normalized()
	# 中值偏得太离谱（几乎不是地面）-> 不采信
	if med.y < 0.2:
		return Vector3.UP
	return med


## 在脚下采 5 个点（中心 + 四周）的地面法线，滤掉陡面，再取中值
func sample_ground_up(space: PhysicsDirectSpaceState3D) -> Vector3:
	var feet := player.global_position
	var r := 0.28                      # 采样半径（和胶囊半径同量级）
	# 向下探 1.4m：远大于 player.MAX_STEP_HEIGHT(0.45)，站在台阶/坡面上也能探到脚下地面。
	var probe := 1.4                   # 向下探的距离
	var offs := [
		Vector3.ZERO,
		Vector3(r, 0.0, 0.0), Vector3(-r, 0.0, 0.0),
		Vector3(0.0, 0.0, r), Vector3(0.0, 0.0, -r),
	]
	var got: Array = []
	for off in offs:
		# 起点抬高 0.5m 再往下打：避免起点落在脚底/地面以下（下陷、台阶边缘、坡面内侧）
		# 导致射线从地下往上打、采不到这块地面的法线。
		var hit := _ray_down(space, feet + Vector3(0.0, 0.5, 0.0) + off, probe)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		# 法线太斜 -> 那是墙/侧面，不是地面，丢掉（避免被它推走）
		if n.angle_to(Vector3.UP) > player.floor_max_angle:
			continue
		got.append(n.normalized())
	return median_normal(got)


## 每帧更新平滑地面法线（接地时快速跟随，离地时缓慢回正）
func update_ground_up(delta: float) -> void:
	if player.is_on_floor():
		var med := sample_ground_up(get_world_3d().direct_space_state)
		# 1-exp(-rate*dt) 是**与帧率无关**的指数平滑系数：物理帧率变化时收敛速度不变。
		# 别图省事写成 lerp(a, b, rate*delta) —— 大 delta 下会过冲、帧率一抖法线就跳。
		var k := 1.0 - exp(-GROUND_SMOOTH_RATE * delta)
		_ground_up = _ground_up.lerp(med, k)
		if _ground_up.length_squared() > 0.000001:
			_ground_up = _ground_up.normalized()
		_ground_ready = true
	elif _ground_ready:
		# 离地后**更慢**地回正（固定速率 4.0，也写成帧率无关形式）：跳跃/抬步期间
		# 地面法线本来就不可信，慢慢回正才不会让速度方向在半空里抖。
		var k2 := 1.0 - exp(-4.0 * delta)
		_ground_up = _ground_up.lerp(Vector3.UP, k2).normalized()


# ==================== 坡度速度系数 · 侧向速度 ====================
## 计算坡度对**水平移动速度**的乘性系数（只影响速度，不改方向、不改重力）。
## 参数：normal = 地面法线（调用方传**平滑后**的 _ground_up，逐面法线会每帧抖动）；
##       move_dir = 本帧期望的水平移动方向（会被 normalized）；
##       on_floor = 是否站地（空中恒返回 1.0，跳跃时速度不受坡度影响）。
## 返回：倍率 ∈ [slope_speed_min_ratio, slope_speed_max_ratio]。
##       1.0 = 平地/关闭规则/无输入；上坡向 min_ratio 过渡（减速），下坡向 max_ratio 过渡（加速）。
## 规则细节：过渡量 t = clamp(坡度角 / slope_speed_angle, 0, 1)，再乘"顺着坡走的投影分量"
##           along（+1 正上坡 / -1 正下坡）—— 所以**沿坡横移不会被误加速/误减速**。
## 副作用：无（纯函数，tests/test_player_slope.gd 直接反射调用验证）。
## 关闭方式：slope_speed_angle <= 0。
func slope_speed_factor(normal: Vector3, move_dir: Vector3, on_floor: bool) -> float:
	if not on_floor or move_dir.length_squared() < 0.000001:
		return 1.0
	if slope_speed_angle <= 0.0:
		return 1.0
	var n := normal.normalized()
	var angle := n.angle_to(Vector3.UP)
	if angle < 0.01:
		return 1.0                                  # 平地
	# 法线的水平投影指向"下坡方向"；移动方向与它相反 = 上坡
	var downhill := Vector3(n.x, 0.0, n.z)
	if downhill.length_squared() < 0.000001:
		return 1.0                                  # 坡面几乎垂直，交给物理挡
	var along := move_dir.normalized().dot(-downhill.normalized())   # +1 正上坡，-1 正下坡
	var t := clampf(angle / deg_to_rad(slope_speed_angle), 0.0, 1.0)
	var factor := 1.0
	if along > 0.0:
		factor = lerpf(1.0, slope_speed_min_ratio, t * along)        # 上坡：减速
	elif along < 0.0:
		factor = lerpf(1.0, slope_speed_max_ratio, t * -along)       # 下坡：加速
	return clampf(factor, slope_speed_min_ratio, slope_speed_max_ratio)


## 求"角色朝向坐标系下的侧向速度"（右为正，左为负；单位米/秒）。
## 参数：move_xz = 本帧实际的水平移动向量；facing_yaw = player.get_facing_yaw()（弧度）。
## 返回：move_xz 在"朝向右手方向"上的投影；无移动时返回 0.0。
## 用途：player.set_lateral() 用它选侧移动画（阈值 LATERAL_ANIM_THRESHOLD）与压弯方向。
## 副作用：无（纯函数）。
func _lateral_speed(move_xz: Vector3, facing_yaw: float) -> float:
	if move_xz.length_squared() < 0.0001:
		return 0.0
	var right := Vector3(cos(facing_yaw), 0.0, -sin(facing_yaw))
	return move_xz.dot(right)


# ==================== 键鼠输入读取 · 测试钩子 ====================
## 自动化测试用：非零时替代键盘输入（headless 探测无法模拟按键）
var test_move_override := Vector2.ZERO


## 读 WASD 得到**水平**移动输入（归一化，避免斜着走更快）。
## 返回：Vector2，x = 右为正（D 正 / A 负），y = 前为正（W 正 / S 负）；无输入返回 (0,0)。
## 副作用：无（`test_move_override` 非零时优先返回它的归一化值，供 headless 测试注入输入）。
## 注意：跳跃不在这里读（Space 在 _physics_process 里与 _space_prev 一起判"刚按下"）。
## 注意：用的是 Input.is_key_pressed（**物理键盘**），不走 InputMap/Action，改键位要动这里。
func _get_move_input() -> Vector2:
	if test_move_override != Vector2.ZERO:
		return test_move_override.normalized()
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_S):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	return dir.normalized()

# ==================== 对外查询接口（鼠标状态 · 准星 · 地面落点） ====================
## 是否正在捕获鼠标（第一人称操作中）
## 返回 _mouse_captured 当前值：true = 光标被锁定隐藏，false = 可见（本项目默认）。
## 参数：无。副作用：无（纯查询）。main.gd 的调试信息条每帧读它。
func is_mouse_captured() -> bool:
	return _mouse_captured

## 获取屏幕中心射线（准星拾取）
## 返回：Array，元素 0 = 射线起点（世界坐标，近裁剪面上的点），元素 1 = 单位方向向量；
##       camera 为空时返回 [Vector3.ZERO, Vector3.UP]（退化值，调用方需自行判空）。
## 副作用：无。注意它**不排除任何碰撞体**，是"从相机出发"的射线（含角色自己）。
func get_center_ray() -> Array:
	if camera == null:
		return [Vector3.ZERO, Vector3.UP]
	var center := get_viewport().get_visible_rect().size * 0.5
	var from := camera.project_ray_origin(center)
	var dir := camera.project_ray_normal(center)
	return [from, dir]

## 鼠标位置的地面落点（俯视角下用它代替"屏幕中心准星"）。
## 与 get_ground_point_center 同一套逻辑，只是射线从鼠标位置发出。
## 参数：terrain = 地形系统（用于 _clamp_place_point 里的 get_height_at 贴地，可为 null）。
## 返回：Vector3 世界落点；打不到地形（含 camera 为空）时返回 **null**（Variant！调用方判 null）。
## 先按 interact_range 探一次，没命中再用 GROUND_RAY_MAX 补一次，最后交给 _clamp_place_point
## 把过远的点拉回角色附近（PLACE_MAX_DIST）。
## 副作用：无（纯查询）。调用者：main.gd::_ground_point() 等放置类工具。
func get_ground_point_mouse(terrain: TerrainSystem) -> Variant:
	if camera == null:
		return null
	var mpos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mpos)
	var dir := camera.project_ray_normal(mpos)
	var near := _cast_ground(from, dir, interact_range)
	if not near.is_empty():
		return _clamp_place_point(near.position, terrain)
	var far := _cast_ground(from, dir, GROUND_RAY_MAX)
	if not far.is_empty():
		return _clamp_place_point(far.position, terrain)
	return null


# ==================== 放置点射线常量与贴地工具 ====================
## 准星落地射线的探测距离上限。
## 第三人称相机在角色后上方（+2.0m 高、-9.4 度俯角），准星射线每前进 1m 只下降 0.036m，
## 要落回地面需要走约 45m —— 而交互距离只有 18m，于是默认视角下准星**永远打不到地面**，
## 树木/花草/家具/山体这些需要地面点的工具全部放不下去（试玩实测：点左键毫无反应）。
## 所以先按交互距离探测，没命中再用这个上限补一次。
const GROUND_RAY_MAX := 260.0
## 放置点离角色的最大水平距离。第三人称相机加缓俯角会让射线落到 25m 外，
## 那个距离放东西等于往天边扔，所以超出就沿射线拉回来重新贴回地面。
const PLACE_MAX_DIST := 9.0


## 用准星射线求地面交点（返回 null 表示没命中地形）
## 参数：terrain = 地形系统（传给 _clamp_place_point 做贴地修正）。
## 返回：Vector3 世界落点，或 **null**（Variant 类型，调用方必须判 null 而不是判 false）。
## 流程：get_center_ray() → 按 interact_range 打地形层 → 没中再按 GROUND_RAY_MAX 打一次
##       → _clamp_place_point() 把过远的点沿射线方向拉回角色附近并重新贴回地表。
## 副作用：无（纯查询）。
## 物理射线直接打地形碰撞体（层2），在深坑/陡坡等复杂地形上也能精确命中目标点，
## 不再用 y=0 平面交点 + 迭代修正（深坑里会漂移导致刷错位置，如下陷处无法抬升）
func get_ground_point_center(terrain: TerrainSystem) -> Variant:
	var r := get_center_ray()
	var from: Vector3 = r[0]
	var dir: Vector3 = r[1]
	var near := _cast_ground(from, dir, interact_range)
	if not near.is_empty():
		return _clamp_place_point(near.position, terrain)
	var far := _cast_ground(from, dir, GROUND_RAY_MAX)
	if not far.is_empty():
		return _clamp_place_point(far.position, terrain)
	return null


## 把过远的放置点沿 角色到目标 方向拉近到 PLACE_MAX_DIST，并重新贴回地表
## 参数：target = 射线命中的世界落点；terrain = 地形系统（为空则原样返回 target）。
## 返回：修正后的世界落点（水平距离 > PLACE_MAX_DIST 时才动手；y 用 get_height_at 重算）。
## 副作用：无。**只做水平拉近**：高度一律以地形高度为准（避免点在半空/地下的物体上）。
## 注意：距离很小时（< 0.001）直接返回，防止除法抖动。
func _clamp_place_point(target: Vector3, terrain: TerrainSystem) -> Vector3:
	if player == null or terrain == null:
		return target
	var base := player.global_position
	var flat := Vector3(target.x - base.x, 0.0, target.z - base.z)
	var dist := flat.length()
	if dist <= PLACE_MAX_DIST or dist < 0.001:
		return target
	var pulled := base + flat / dist * PLACE_MAX_DIST
	return Vector3(pulled.x, terrain.get_height_at(pulled.x, pulled.z), pulled.z)


## 低层工具：从 from 沿 dir 打一条 length 米的地形射线。
## 参数：from = 起点（世界坐标，通常是相机 project_ray_origin 得到的位置）；
##       dir = 单位方向；length = 距离上限（interact_range 或 GROUND_RAY_MAX）。
## 返回：intersect_ray 的字典；**未命中返回空字典**（调用方用 is_empty() 判断）。
## 副作用：无。**只打物理层 2（地形）**：所以建筑/树/角色都不会挡住放置点，
##       在深坑/陡坡上也能精确命中目标点（不再用 y=0 平面 + 迭代修正的老做法）。
func _cast_ground(from: Vector3, dir: Vector3, length: float) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * length)
	query.collision_mask = 2   # 只检测地形层
	return space.intersect_ray(query)

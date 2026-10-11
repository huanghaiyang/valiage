# =============================================================================
# main.gd —— Cozy Vale 主场景总控脚本
# -----------------------------------------------------------------------------
# 【本文件职责】
#   1) 场景装配：_ready() 按固定顺序把「画质分级 → 世界生成 → 剔除/合批 → 预览 →
#      UI → 输入映射 → 天气/设置注入」串起来，是整局游戏唯一的装配点。
#   2) 玩家交互：工具选择、拖拽建墙、单点放置（塔/屋/树/花/家具/山）、地形笔刷、家具互动。
#   3) 命令行调试入口：--capture / --verify / --coltest / --plantdemo / --probe 等开关
#      （开关全部从 OS.get_cmdline_user_args() 读取，即命令行里 `--` 之后的参数）。
# 【所属系统】顶层主场景（res://scenes/main.tscn 的根节点 Node3D），不隶属任何子系统。
# 【关键依赖】
#   * autoload（见 project.godot [autoload]）：Game（工具枚举/资源余额/Game.world）、
#     Settings（画质档位与环境引用）、Weather（天气/风）、StaffSystem（法杖；本文件只用
#     字符串形式的 call 调用，见 _show_staff_hint）、Quality、Wind、Mana、SpellCaster、
#     Vitals、VitalsHud。
#   * 场景内节点（结构在 scenes/main.tscn 中声明，本脚本只按路径取引用）：Terrain /
#     Vegetation / Buildings / Roads / Player / CameraRig(含 CameraRig/Camera3D) /
#     Sun / WorldEnvironment / UI / Minimap / PreviewWall / PreviewRoof / PreviewPlace。
#   * 运行时 new 出来的独立辅助脚本（不依赖场景，都是 Node 子类，add_child 即生效）：
#     scripts/quality/prop_texture_quality.gd、scripts/quality/shadow_quality.gd、
#     scripts/quality/grass_quality.gd、scripts/world/prop_visibility.gd、
#     scripts/world/prop_merge.gd；世界生成走 scripts/world/world_builder.gd::build()。
#   * 资源路径：res://assets/materials/preview_*.tres（预览材质）；截图输出到
#     user://screenshot_check.png（可用 --out=xxx.png 改名）。
# 【主要对外接口】
#   set_tool(tool:int)      —— UI 工具栏点击（会写 Game.current_tool，进而触发 tool_changed）
#   undo()                  —— UI 撤销按钮（转发给 BuildingManager.undo()）
#   _show_staff_hint(id:String) —— 装备面板用 `main.call("_show_staff_hint", id)` 字符串调用
#   _try_interact()         —— E 键路径复用；另外 Game.world = self 让全局能拿到主场景
# 【已知的坑与注意事项】
#   * 装配顺序敏感：预览与相机依赖 terrain/buildings/player，必须排在世界生成之后；
#     画质分级必须排在首帧渲染之前（原因见 _ready() 内注释）。
#   * 本文件历史上出过两类事故：① 删函数时连带删掉夹在函数之间的 const（见 INTERACT_RADIUS）；
#     ② 把输入分支按错误缩进插进鼠标分支，被其中的 return 截断导致"完全无法放置"。
#     因此改动务必"只增不改"，不要整文件覆盖重写。
#   * 法杖/植物系统被整体移除过一轮，残留了字符串形式的跨脚本调用（静态扫描抓不到），
#     删任何函数前先全局搜 `"函数名"` 字符串。
#   * 本文件直接读写了 buildings / vegetation 的若干私有成员（buildings._tower_base、
#     vegetation._blocks / _collision_anchor 等），那两个脚本改内部结构时要回来看这里。
# =============================================================================
extends Node3D
## 主场景：整合地形、植被、建筑、相机与输入交互

# ==================== 一、场景节点引用 ====================
# 全部用 @onready + 固定路径 $Xxx 获取：节点在 scenes/main.tscn 里声明，脚本只做装配与行为。
# 注意：@onready 变量在 _ready() 之前完成赋值，但**子节点的 _ready() 先于父节点执行**，
# 所以其他脚本（如 camera_rig.gd）不要指望在这里拿到的引用（见 _wire_camera_rig 的补充注入）。
# 类型标注（TerrainSystem / VegetationSystem / …）让我们能直接点出成员；一旦类型对不上，
# 引擎会在启动时报错而不是静默失败 —— 这是有意保留的"早期报警"。
# 场景节点引用（节点结构在 scenes/main.tscn 中声明，脚本只做装配与行为）
@onready var terrain: TerrainSystem = $Terrain
@onready var vegetation: VegetationSystem = $Vegetation
@onready var buildings: BuildingManager = $Buildings
@onready var roads: RoadNetwork = $Roads
@onready var player: Player = $Player
@onready var camera_rig: CameraRig = $CameraRig
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var env: WorldEnvironment = $WorldEnvironment
@onready var ui: CanvasLayer = $UI
# ==================== 二、交互半径参数 ====================
## 家具互动距离（米）：以**玩家的水平位置**为圆心，VegetationSystem.find_nearest_interactable()
## 在这个半径内找最近的可互动家具（坐 / 睡 / 爬梯）。
## 2.6m 的取值理由：略大于"角色身体贴近家具"的视觉距离 ——
##   调大 → 隔着一堵墙、隔着一张桌子也能弹出互动提示（误触发）；
##   调小 → 必须几乎踩进家具里才出提示（用户会以为互动坏了）。
## 只比较水平距离（dx/dz），玩家比家具高一点、低一点都不影响判定。
# 家具互动距离（原来被误删过：删函数时把夹在两个函数之间的这段常量一起吃掉了）
const INTERACT_RADIUS := 2.6

# ==================== 三、UI 引用与提示节流 ====================
# 小地图是独立 CanvasLayer（scenes/main.tscn 中带 minimap.gd 脚本），_setup_ui() 里注入主场景引用。
# 它随相机 yaw 旋转、大地图不转（见 minimap.gd / --mapcheck 验收）。
@onready var _minimap: CanvasLayer = $Minimap
# 家具互动提示的节流计时器（秒）：归零才重新查询一次最近家具并刷新提示文本。
# 默认 0.0 → 进游戏第一帧就会刷一次；之后每 0.15s 一次（见 _process），
# 避免每帧都做一次 find_nearest_interactable 的距离遍历、也避免提示闪烁。
var _hint_timer := 0.0            # 家具互动提示节流
# ==================== 四、命令行调试开关（截图 / 自检 / 功能测试） ====================
# 下面这一整组都是"默认全 false"的调试开关：正常游玩时它们不产生任何行为，只在 _ready()
# 里按命令行参数置位，或在 _process() 里被读取。全部来自 `--` 之后的用户参数。
# 置位位置一览（便于排查"为什么没生效"）：
#   --capture/--aerial/--cam/--look/--staff/--staffseq/--capframes/--seqstep/--no-ui → _ready()
#   --verify / --plantdemo / --plant3d / --sheet / --staffpanel / --staffdemo / --staffrun /
#   --no-veg / --coltest                                                              → _ready()
#   --houses / --newmodels / --treepaint / --mapcheck / --occl / --probe / --out        → 只在用到处判断
# 注意：--no-ui 是独立的（写在最后，别缩进到别的 if 里，否则会跟着一起被跳过）。
var _capture_aerial := false      # 调试截图：俯视全景
var _capture_free := false        # 调试截图：--cam=x,y,z --look=x,y,z 自由机位
var _capture_cam := Vector3.ZERO
var _capture_look := Vector3.ZERO
# 截图时序约定（改这里之前先读懂，否则很容易"等不到画面"）：
#   _capture_frames 从 _capture_start（默认 90）开始每帧递减，减到 0 时存 PNG 并 quit；
#   而"摆道具/换法杖"这类操作固定在 **_capture_frames == 88** 这一帧做 ——
#   88 = 默认 90 - 2：提前两帧执行，留出至少一帧让新建/换模型后节点树与渲染稳定下来。
#   用 --capframes=N 改起点时，这个 88 不会跟着变，所以自定义帧数下这些"演示摆件"不会触发。
#   连拍模式下 _capture_start 与 _capture_frames 共同决定 elapsed（见 _run_capture_sequence）。
var _capture_staff := ""              # 调试截图：--staff=<id> 先装备指定法杖
var _capture_seq: PackedStringArray = []   # 调试截图：--staffseq=a,b,c 一次运行连拍
var _seq_idx := -1
# 连拍参数说明：_seq_idx 记录"当前正在拍第几根杖"，-1 表示还没开始；
# _seq_step 取 18 帧是折中（推测取值为实测调出来的）：太短则换杖后模型/姿态/悬浮还没稳定，
# 太长则一轮 20 根杖要多等好几百帧。--seqstep=N 会被 maxi(2, ...) 钳到最小 2，防止除零。
# _capture_start 既当"截图起始帧数"，也被 _run_capture_sequence 用来反推已流逝帧数。
var _seq_step := 18                   # 连拍时每根法杖占用的帧数（--seqstep=N 可改）
var _capture_start := 90              # 本次截图模式的起始帧数（--capframes=N 可改）
var _verify := false                  # --verify：无人值守自检（见 _run_verify()）
var _verify_frame := 0                # 自检等待的帧数（等世界与各系统装配完）
var _plant_demo := false              # --plantdemo：截图时把归入树木/花草的植物按分类摆一片
var _plant3d_demo := false            # --plant3d：只有几何体植物的近景（验收造型用）
var _plant_sheet := ""                 # --sheet=N：--plant3d 只摆第 N 张参考表的植株
var _staff_panel_demo := false         # --staffpanel：截图时打开装备（法杖）面板
var _staff_demo := false               # --staffdemo：截图时连按 3 次 Q，验收换杖提示与手持模型
var _staff_run_demo := false           # --staffrun：截图时让角色全速跑（验收法杖前挥姿态）
var _coltest := false                 # --coltest：远距离碰撞流式加载的功能测试
var _coltest_frame := 0

# ==================== 五、放置预览节点与预览材质 ====================
# preview_wall / preview_roof：拖拽建墙、拖拽盖屋顶时的过程预览（网格每帧重建）。
#   可见性由 _update_preview() / _end_tool() / set_tool() 控制。
# preview_place：单点放置工具（塔/屋/树/花/家具/山体）的目标点半透明幽灵，
#   子节点为真实模型的 MeshInstance3D（在 _setup_previews() 里运行时创建），
#   每次只显示当前工具对应的那一个子节点，材质用下面的 OK / BLOCKED 两套切换。
# 四个材质都是 preload 的**共享资源**（`material_override` 会把同一个实例挂到很多网格上）：
# 这是有意的 —— 预览阶段只改颜色语义、不追求逐物体独立；也因此**绝不能**在这里改材质的
# 属性（会同时改掉所有预览），需要区分就用下面 OK/BLOCKED 两个常量整体替换。
# 预览节点（结构在场景中，材质为可复用资源）
@onready var preview_wall: MeshInstance3D = $PreviewWall
@onready var preview_roof: MeshInstance3D = $PreviewRoof
@onready var preview_place: Node3D = $PreviewPlace
# 四个预览材质的用途与语义（tres 内都是半透明 StandardMaterial3D，改色/改透明度直接改资源）：
#   PREVIEW_WALL_MAT        拖拽建墙过程预览的材质
#   PREVIEW_ROOF_MAT        拖拽盖屋顶过程预览的材质
#   PREVIEW_PLACE_OK        单点放置幽灵"可放置"（绿）
#   PREVIEW_PLACE_BLOCKED   单点放置幽灵"被建筑占位 / 离角色太近"（红）
# 用 preload 而非 load：这几个资源整个会话都要用，提前在解析期加载可避免第一次放置时卡一下；
# 代价是常驻内存（体积很小）。
const PREVIEW_WALL_MAT := preload("res://assets/materials/preview_wall.tres")
const PREVIEW_ROOF_MAT := preload("res://assets/materials/preview_roof.tres")
const PREVIEW_PLACE_OK := preload("res://assets/materials/preview_place_ok.tres")
const PREVIEW_PLACE_BLOCKED := preload("res://assets/materials/preview_place_blocked.tres")

# 这个数组同时是一个"语义开关"，被三处依赖：
#   1) _process()：右键按住时只有当前工具在其中，才做"按住右键连续旋转放置朝向"；
#   2) _unhandled_input() 滚轮分支：在其中 → 切模型变体；不在其中 → 缩放视野；
#   3) _update_place_preview()：不在其中直接隐藏幽灵。
# 注意 Game.Tool 里还有 WALL / TERRAIN_* / PATH / ERASE，它们**不属于**单点放置：
# 墙壁是拖拽、地形是笔刷、PATH 与 ERASE 当前没有实现（不具备单点放置逻辑）。
# 单点放置工具（塔/屋/树/花/家具/山体：视野中心目标点的半透明模型，绿=可放置，红=占位）
var _place_tools := [Game.Tool.TOWER, Game.Tool.ROOF, Game.Tool.TREE, Game.Tool.FLOWER, Game.Tool.DECOR, Game.Tool.MOUNTAIN]

# ==================== 六、树木笔刷参数（@export，检查器可调） ====================
# 四个参数都在按钮按下时被读取（每次种一棵都实时取值），所以运行时在检查器里改会立刻生效。
# 取值刻度与影响：
#   tree_brush_spacing（米，默认 4.0）：笔迹上"再种下一棵"的最小距离。
#     调大 → 树更稀、三角面更少、刷得更快；调小 → 成片更密，容易互相穿插且拖一次就爆量。
#   tree_brush_radius（米，默认 1.6）：每棵相对鼠标落点的随机偏移半径。
#     代码里用 sqrt(randf()) * radius 取值 → 圆面内**面积均匀**（不取 sqrt 会往圆心堆）。
#     调大 → 一片更松散自然；调大过头 → 树会明显偏离鼠标位置。
#   tree_brush_scale_jitter（比例，默认 0.12 = ±12%）：尺寸抖动，避免一片树一模一样。
#     最终缩放 = 1.0 + randf_range(-jitter, jitter)；调到 0 则整片同尺寸（很假）。
#   tree_brush_max_per_stroke（棵，默认 80）：单次笔画上限，防止按住鼠标拖太久无限种树
#     （三角面/节点数爆炸 + 卡顿）。达到上限后只是本笔画不再增加，松手后归零。
## ---- 树木笔刷（红枫树）----
## 按住左键拖动 -> 沿笔迹成片种树；单击仍然是种一棵。
@export var tree_brush_spacing := 4.0      ## 相邻两棵的最小间距（米）
@export var tree_brush_radius := 1.6       ## 每棵在放置点周围的随机偏移半径（米）
@export var tree_brush_scale_jitter := 0.12 ## 尺寸抖动幅度（±比例）
@export var tree_brush_max_per_stroke := 80 ## 一次笔画最多刷几棵
# 笔刷运行时状态（全部在 _begin_tool/_end_tool 里成对进出，不要单独改其中一个）：
#   _tree_brush_active：是否处于"拖动继续种"的笔画中；_end_tool() 无论是否拖动过都要清掉。
#   _tree_brush_count：本笔画已种棵数，用于和 tree_brush_max_per_stroke 比、并在收笔时打日志。
#   _last_tree_pos：上一棵的**鼠标落点**（不是抖动后的实际位置）—— 用 INF 当"还没有上一棵"的
#     哨兵值：任何点到 INF 的距离都是 INF，必然 ≥ spacing，于是"第一棵"不需要额外分支判断。
var _tree_brush_active := false
var _tree_brush_count := 0
var _last_tree_pos := Vector3.INF
## 各分类当前选中的模型变体（滚轮切换）：{"tree": 0, "flower": 2, ...}
## 按分类而非按工具保存，切回同类工具时保留上次的选择；场景重载后自动归零。
var _variant_sel: Dictionary = {}
## 变体提示的剩余显示时间（秒），避免被互动提示立刻覆盖
var _variant_hint_time := 0.0
# 放置朝向：**弧度**，用于预览节点的 rotation 以及传给 buildings/vegetation 各 add_* 的 yaw。
# 两个入口：① 选中单点放置工具时单击右键 +10°；② 按住右键每 100ms 再 +10°（见 _process）。
# 它不做 fposmod 归一化、会一直累加（几十万弧度只会让精度略降，不影响表现，属于有意的懒处理）；
# set_tool() 会把它归零，避免"换了个工具还带着上一个工具的朝向"。
var _place_yaw := 0.0  # 放置朝向（右键旋转）
## 未选工具时按住右键拖动 = 旋转场景（俯视角的 yaw/pitch）
# _rotating 只表示"右键是否按住"，真正的旋转量在 InputEventMouseMotion 里按 relative.x 施加
# （且只在当前工具不属于 _place_tools 时才转，否则右键是"旋转放置朝向"）。
# 拖动期间会把鼠标模式切成 CAPTURED，松开立刻回到 VISIBLE —— 否则鼠标一划就出窗口、旋转中断。
# _place_rot_accum 是按住右键时的累积秒数：_process 里 while 循环每满 0.1s 就 +10°，
# 用"累积 + 消费"而不是"每帧固定角度"，所以旋转速度与帧率无关。
var _rotating := false
var _place_rot_accum := 0.0  # 按住右键旋转的累积时间（每 100ms +10°）
# 放置判定相关的四个常量（全部以"米"为单位，作用于 _is_occupied() / _recycle_vegetation()）：
#   PLACE_OCCUPY_RADIUS  占位查询圆柱的半径。查询只查 collision_mask = 4（第 3 层＝建筑层），
#     也就是只认玩家造的墙/塔/屋；小植被（树/石/草/花/蘑菇/灌木）不占位，会被自动回收。
#     调大 → 建筑旁边到处判红、放不下东西（变相强制留出通行间隙）；
#     调小 → 建筑可以紧贴甚至互相穿插。
#   PLACE_OCCUPY_HEIGHT  占位查询圆柱的高度，见下方长注释：只查贴地那一圈，不看立体体积。
#     调大（回到旧行为）→ 屋檐/树冠这些悬空几何又开始算占位；调小 → 几乎只剩地面一圈。
#   PLACE_PLAYER_CLEAR   放置点与角色的最小**水平**间距。调大 → 只能在离身更远处放；
#     调小 → 可能把家具/山体直接糊在角色身上（视觉上插进身体）。
#   PLACE_RECYCLE_RADIUS 放置/刷地形后回收周围植被的半径（会折算成生物质/石材）。
#     注意它只在部分工具里显式传入，地形笔刷走 _recycle_vegetation(p) 的默认值
#     （= terrain.brush_radius + 0.8，见函数内）。
const PLACE_OCCUPY_RADIUS := 0.9    # 占位检测半径（建筑层）
## 占位检测的高度：**只查贴地那一圈**。
## 原来是一个球体（把屋檐、树冠这些悬在上方的几何也算进来），于是"墙根下、大树下"
## 都放不了花草 —— 用户明确要求改成不按立体体积检测。
const PLACE_OCCUPY_HEIGHT := 0.55
## 与角色的最小间距：放置点离角色太近（会插进身体）时不允许放置
const PLACE_PLAYER_CLEAR := 0.95
const PLACE_RECYCLE_RADIUS := 2.0   # 放置时回收植被范围

# ==================== 七、拖拽状态与画笔尺寸 ====================
# 拖拽流程状态（左键按下 → 移动刷新预览 → 松开落地）：
#   _drag_start   拖拽起点命中的地面点（世界坐标）；建墙时作为墙的起点
#   _is_dragging  是否处于拖拽中：_process / _physics_process / _update_preview / _end_tool
#                 都靠它分支，set_tool() 会把它强制清掉（换工具时取消未完成的拖拽）
#   _pending_wall 早期"墙待建队列"的遗留标志：全项目搜不到任何读取处
#                 （推测是重构后的残留），保留只是为了不动已声明的变量，别据此推断逻辑
# 拖拽状态
var _drag_start: Vector3 = Vector3.ZERO
var _is_dragging := false
var _pending_wall := false

# 画笔尺寸（单位：米）。这几个是普通 var、没有 @export，所以只能在脚本里改（或将来接 UI）。
# 改动效果与"哪里真的用到"：
#   wall_height / wall_thickness：拖拽建墙的高度与厚度。过程预览（_update_preview）和最终
#     落地（_end_tool → buildings.add_wall）用的是同一对值，改一个不会出现"预览和实物不一致"。
#   tower_radius / tower_height：塔的半径与高度。⚠ tower_height **当前不生效**：
#     BuildingManager.add_tower() 的高度形参签名是 `_height`（被忽略），塔高由模型自身决定；
#     tower_radius 则真的参与缩放（见 _setup_previews 里 maxf(0.35, radius*2/_tower_base)）。
#   roof_width / roof_ridge / roof_eave：**只作用于"拖拽盖屋顶"的过程预览**
#     （ProceduralMesh.build_gable_roof）。单点 ROOF 工具放的是预制小屋，走
#     building_manager 的房屋变体表，跟这三个值没有任何关系。
# 画笔
var wall_height := 3.0
var wall_thickness := 0.6
var tower_radius := 1.4
var tower_height := 5.0
var roof_width := 5.0
var roof_ridge := 2.6
var roof_eave := 1.0

# ==================== 八、帧计数与计时器 ====================
# _probe_t：--probe 模式下打印"角色贴地状态"的累加秒数，满 0.5s 打一条（见 _process）。
#   只在 --probe 时递增，正常游玩恒为 0。
# _capture_frames：截图模式的倒计时（帧）。> 0 表示"截图模式进行中"，== 0 时保存 PNG 并 quit；
#   它同时也是"--capture 下渲染是否稳定"的度量，所以不要拿它去做别的逻辑判断。
# 调试截图帧计数（--capture 参数触发，渲染稳定后保存截图并退出）
var _probe_t := 0.0
var _capture_frames := 0

# ==================== 九、启动埋点：材质快照（诊断"游戏内发白/镂空"） ====================
## 参数：
##   wait_s（秒，默认 2.0）—— 延迟多少秒后再扫描。_ready() 里用 2.0 与 8.0 各扫一次，
##     两次对比就能判断"是不是 2~8 秒之间有系统动了材质"。
##   tag（字符串）—— 只用于日志前缀，区分第几次快照。
## 返回值：无（void）。
## 副作用：**只读**。遍历场景树读材质、必要时 instantiate 场景，不改节点/材质，不写文件。
## 注意：函数体内有 await，调用时是协程 —— _ready() 里两行调用**不会阻塞**后续装配，
##   所以日志出现的时间点晚于 _ready() 结束，且不会拖慢启动。
## ★ 启动埋点（用户要求 ✓）：等各系统（分级/植被/风/燃烧控制器）装配完，再打一遍材质快照 ✓
##   只看**树**相关（名字含 tree ✓）以免刷屏；要看全量就把过滤那段删掉 ✓
##   关键：它会打印"材质来源 / 类型 / 资源路径 / albedo 是否为空" ✓
##   → "编辑器正常 ✓ 游戏内发白"这类问题，哪一步换掉了材质一看就知道 ✓
func _dump_materials_deferred(wait_s: float = 2.0, tag: String = "") -> void:
	await get_tree().create_timer(wait_s).timeout
	print("[材质埋点] ===== %s（+%.1fs）=====" % [tag, wait_s])
	var n_shader := 0
	var n_std := 0
	var n_bad := 0
	# ★★ 修正（用户反馈 ✓）：原来看名字过滤 ✗ → **可能漏掉真正的白树** ✓
	#   现在**不过滤** ✓：凡是 MeshInstance3D（含 glTF 的 ImporterMeshInstance3D ✓ 它是子类 ✓）
	#   就全部打印 ✓ —— "发白 + 镂空"的那个节点一定会出现 ✓
	for n in find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		# ★ 只打"可疑"的 ✓（用户反馈日志爆量 ✗）：name_hit = false → 只有命中 mat_hit 才打印 ✓
		#   （打印交给下面命中后的那行 ✓ 它带节点名 ✓ → 全部日志只剩十几行 ✓）
		var name_hit := false
		var mat_hit := false
		for s0 in range(mi.mesh.get_surface_count()):
			var m0: Material = mi.get_surface_override_material(s0)
			if m0 == null:
				m0 = mi.mesh.surface_get_material(s0)
			if m0 == null:
				mat_hit = true
				break
			if m0 is BaseMaterial3D and (m0 as BaseMaterial3D).albedo_texture == null:
				mat_hit = true
				break
			if m0 is ShaderMaterial:
				var tv0: Variant = (m0 as ShaderMaterial).get_shader_parameter("albedo_tex")
				if not (tv0 is Texture2D):
					mat_hit = true
					break
		if not (name_hit or mat_hit):
			continue
		for s in range(mi.mesh.get_surface_count()):
			var m: Material = mi.get_surface_override_material(s)
			var src := "surface_override"
			if m == null:
				m = mi.mesh.surface_get_material(s)
				src = "网格自带"
			if m == null:
				n_bad += 1
				print("[材质埋点] %s surface=%d ｜ 材质=**无 ✗**" % [mi.name, s])
				continue
			var info := ""
			if m is ShaderMaterial:
				n_shader += 1
				var sm := m as ShaderMaterial
				var atv: Variant = sm.get_shader_parameter("albedo_tex")
				var ats := "**无 ✗**"
				if atv is Texture2D:
					ats = (atv as Texture2D).resource_path
				else:
					n_bad += 1
				info = "shader=%s ｜ use_albedo=%s ｜ albedo_tex=%s ｜ base_color=%s" % [
						sm.shader.resource_path.get_file() if sm.shader != null else "**无 ✗**",
						str(sm.get_shader_parameter("use_albedo")), ats,
						str(sm.get_shader_parameter("base_color"))]
			elif m is BaseMaterial3D:
				n_std += 1
				var b := m as BaseMaterial3D
				if b.albedo_texture == null:
					n_bad += 1
				info = "albedo_texture=%s" % [
						b.albedo_texture.resource_path if b.albedo_texture != null else "**无 ✗**"]
			print("[材质埋点] %s surface=%d ｜ 来源=%s ｜ 类型=%s ｜ 资源=%s ｜ %s" % [
					mi.name, s, src, m.get_class(),
					String(m.resource_path) if not String(m.resource_path).is_empty() else "（内存实例）",
					info])
	print("[材质埋点] 汇总 ✓ ShaderMaterial=%d ｜ BaseMaterial3D=%d ｜ 可疑(无贴图)=%d" % [
			n_shader, n_std, n_bad])


# ==================== 十、生命周期回调（_ready / _process / _physics_process） ====================
## 主场景装配入口：把"世界 + 预览 + UI + 输入 + 天气/设置"按依赖顺序接起来。
##
## 调用时机：进入场景树时由引擎调用一次；而**子节点的 _ready() 已经在它之前跑完**，
##   所以这里读到的 @onready 引用一定非空，但 WorldBuilder 生成的世界内容此时还不存在。
##
## 装配顺序（顺序本身是契约，改顺序会引入 bug）：
##   1. 挂两次材质埋点（异步，2s / 8s 后各打一次快照，见 _dump_materials_deferred）；
##   2. 画质分级三件套提前实例化（prop_texture_quality / shadow_quality / grass_quality）
##      —— 必须在**任何绘制之前**完成贴图替换，理由见下方长注释；
##   3. _wire_camera_rig() 补注入相机/角色引用（子节点 _ready 时还拿不到）；
##   4. WorldBuilder.build(...) 生成地形/平台/聚落/道路/植被/出生点，返回统计 report；
##   5. 世界级优化：道具可见距离、道具贴图分级、阴影距离、墓园合批（默认关）、草贴图分级；
##   6. _setup_previews() / _setup_ui() / _setup_input_actions()（依赖 terrain/buildings/player）；
##   7. 绑定天气与全局引用：vegetation.set_camera → Weather.bind_world → Game.world →
##      Settings.world_environment / vegetation_root → Settings.apply_quality()；
##   8. 解析命令行：天气、截图、自检、演示与隔离开关。
##
## 副作用：向自身 add_child 若干辅助节点；调用 WorldBuilder 生成大量节点与碰撞体；
##   写 Game.world / Settings.* 两个全局；可能直接改 Weather 状态、隐藏 ui/_minimap。
## 返回值：无。
## 注意：正文里对 OS.get_cmdline_user_args() 的多次调用是刻意的（各分支各自解析、互不影响），
##   不要"优化"成解析一次存字典 —— 那样任何一处 return 早退都会影响后面的开关。
func _ready() -> void:
	# ★★ 启动埋点（用户要求 ✓）：**打两次**快照 ✓
	#   第 1 次 2 秒（各系统刚装配完 ✓）／第 2 次 8 秒（世界重建/分级/植被/流式都跑过之后 ✓）
	#   目的：如果"一进游戏就白" ✓ 而 2 秒快照又是正常的 ✓
	#     → 说明是**2~8 秒之间**有系统动了材质 ✓ 两次对比就能抓到它 ✓
	_dump_materials_deferred(2.0, "第一次(2s)")
	_dump_materials_deferred(8.0, "第二次(8s)")

	# 节点树 / 环境光照 / 世界布局（出生点·平台·聚落·道路·植被）全部声明在 scenes/main.tscn。
	# 装配顺序：先接引用 → 生成世界（地形/平台/聚落/道路/植被/出生点）→ 再做依赖世界的
	# 预览、UI、输入动作。预览与相机都依赖 terrain/buildings/player，必须排在世界之后。
	# ★①② 画质分级：**提到最前面**（在任何绘制之前换掉材质里的贴图引用 ✓）
	#   ① `_ready()` 发生在**首帧渲染之前** ✓ → 4K 大概率**从未被上传到显存** ✓
	#      （只在加载瞬间存在于内存/解码 ✓ —— 这是"不改文件(B)"能达到的下限 ✓）
	#   ② `_base` 只存**路径字符串**、绝不持有 Texture 引用 ✓ → 换掉后原图失去最后一个
	#      外部引用，由引用计数自然释放 ✓（Godot 没有"强制卸载资源缓存"的 API ✗，只能不留引用 ✓）
	#   ③ 项目**没有加载画面** ✗ —— 但因①，这段换引用本就发生在屏幕看不到的时机 ✓
	#   ★ 下面原来那一段同名创建仍保留 ✓ → 会各实例化一次；两次 apply 是**幂等**的 ✓
	#     （第二次看到的是已换过的贴图 → 找不到变体 → 空操作 ✓），代价只是多几个节点与一行日志 ✓
	# ★ 已恢复（排查结束 ✓ 与分级无关 ✓）
	var pq0 := preload("res://scripts/quality/prop_texture_quality.gd").new()
	pq0.name = "PropTextureQualityEarly"
	add_child(pq0)
	var sq0 := preload("res://scripts/quality/shadow_quality.gd").new()
	sq0.name = "ShadowQualityEarly"
	add_child(sq0)
	var gq0 := preload("res://scripts/quality/grass_quality.gd").new()
	gq0.name = "GrassQualityEarly"
	add_child(gq0)
	# 先补注入相机/角色引用，再生成世界：WorldBuilder 生成的出生点/贴地逻辑要用到 camera_rig，
	# 而 CameraRig._ready() 早于本函数执行，那里读到的导出引用只可能来自 .tscn 的绑定。
	_wire_camera_rig()
	var report := WorldBuilder.build(self, terrain, vegetation, buildings, roads, player, camera_rig)
	# ★ 性能：给墓园/遗迹这类"远处小件聚集区"设可见距离（离开视野后不再绘制；
	#   引擎级剔除、零每帧脚本开销）。参数在 prop_visibility.gd 顶部，保守默认 80m/20m。
	preload("res://scripts/world/prop_visibility.gd").apply(self)
	# ★ 画质分级：把墓园/道具的**贴图**按当前档位换成对应分辨率的版本，
	#   与地表贴图分级（terrain_quality.gd）同一套 QualityTiers 规则：
	#   换不到自动回退到存在的最高档、内嵌贴图自动跳过（日志会报数量）。
	var pq := preload("res://scripts/quality/prop_texture_quality.gd").new()
	pq.name = "PropTextureQuality"
	add_child(pq)
	# ★ 画质分级：**阴影绘制距离**（把 QualityTiers 里原本没人用的 shadow_quality 接上 ✓）
	#   低/中/高/极高 → 40/70/110/160m，参数在 shadow_quality.gd 顶部 ✓
	var sq := preload("res://scripts/quality/shadow_quality.gd").new()
	sq.name = "ShadowQuality"
	add_child(sq)
	# ★ 性能（可选）：**墓园合批** —— 把一堆小件按材质合并成少数网格，降低 draw call。
	#   默认关闭 ✓（ENABLED = false）：合并会改变节点结构（相机挖洞遮挡/逐件交互受影响 ✗），
	#   要启用就把 prop_merge.gd 顶部的 ENABLED 改成 true ✓（不改 .tscn/.res ✓ 可随时关掉 ✓）
	preload("res://scripts/world/prop_merge.gd").apply(self)
	# ★ 画质分级：**草贴图**（素材本来就有 1k/2k/4k ✓，缺的是接线 ✗）
	#   覆盖共用材质 `scenes/草/_blend_mat_grass_bermuda_01.tres` + SGT 节点的四个贴图槽 ✓
	var gq := preload("res://scripts/quality/grass_quality.gd").new()
	gq.name = "GrassQuality"
	add_child(gq)
	_setup_previews()
	_setup_ui()
	_setup_input_actions()
	# 植被的"碰撞流式加载"以**相机位置**为锚点（vegetation._collision_anchor() 取的就是它），
	# 所以必须在世界生成完、开始建碰撞之前把相机交进去，否则远处实例的碰撞体不会被建出来。
	vegetation.set_camera(camera_rig.camera)
	# 天气系统：绑定太阳/环境/雨，并订阅相机跟随
	# 顺序要求：放在植被之后 —— wind_materials() 返回的是已生成植被材质的引用集合，
	# 植被还没建就调，会把空数组写进风摇 uniform。
	Weather.bind_world(sun, env, self, vegetation.wind_materials())
	# 把主场景暴露到全局：UI、法杖、法术等通过 Game.world 反向拿主场景（避免长参数链）。
	Game.world = self
	# Settings 拿到环境与植被根节点后才知道"画质档位要作用在谁身上"，
	# 因此 apply_quality() 必须排在最后 —— 提前调用只会空跑一次。
	Settings.world_environment = env
	Settings.vegetation_root = vegetation
	# 到这里环境/植被引用都齐了，再让画质档位落地一次（重启后 Load 的档位、UI 改档都走这条）。
	Settings.apply_quality()
	print("World | 场景组装 平台=%d 建筑=%d 道路=%d 清场=%d 出生点=%s 地形=%dms"
			% [report["platforms"], report["buildings"], report["roads"],
			report["clear_zones"], str(report["spawn"]), report["generated_ms"]])
	# 命令行指定初始天气：--weather=0..5（配合 --capture 做截图验证）
	# 0..5 对应 Weather.Kind：0 晴朗 / 1 多云 / 2 阴天 / 3 小雨 / 4 雷雨 / 5 大风；
	# 越界的值**静默忽略**（不报错），这样脚本传错参数也只是看到默认天气。
	# 必须同时关掉 auto_change：否则过几十秒自动天气会把指定状态换走，截图就不可复现了。
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--weather="):
			var k := int(a.split("=")[1])
			if k >= 0 and k < Weather.KIND_NAMES.size():
				Weather.auto_change = false
				Weather.set_weather(k, true)
				print("Weather | 启动指定 -> %s (wind=%.2f)" % [Weather.weather_name(), Weather.wind])
	# 调试截图模式：渲染稳定后保存画面并退出
	# 90 帧（60fps 下约 1.5s）是在"等世界/植被/天气过渡稳定"与"别白等"之间的折中；
	# _capture_frames 与 _capture_start 一起写同一个值：前者负责倒计时，后者留作连拍反推 elapsed
	# 的起点（见 _run_capture_sequence）。--capframes=N 会把两者一起改掉。
	if "--capture" in OS.get_cmdline_user_args():
		_capture_frames = 90
		_capture_start = 90
		_capture_aerial = "--aerial" in OS.get_cmdline_user_args()
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--cam="):
				_capture_free = true
				_capture_cam = _parse_vec3(a.split("=")[1])
			if a.begins_with("--look="):
				_capture_look = _parse_vec3(a.split("=")[1])
			if a.begins_with("--staff="):
				# 这里只记 id；真正 unlock+equip 在 _process() 的"第 88 帧"分支里做
				# （那时世界已稳定，换杖后的手持模型/姿势才拍得到）。
				_capture_staff = a.split("=")[1]
			if a.begins_with("--staffseq="):
				# 一次启动连拍多根法杖（每根 18 帧），省掉反复启动 Godot 的
				# 地形生成开销（单次约 6s，一轮 20 根要跑 20 次太慢）
				_capture_seq = a.split("=")[1].split(",")
			if a.begins_with("--capframes="):
				_capture_frames = maxi(1, int(a.split("=")[1]))
				_capture_start = _capture_frames
			if a.begins_with("--seqstep="):
				_seq_step = maxi(2, int(a.split("=")[1]))
	# 下面这组开关只负责"置位"，真正的行为分散在 _process()：
	#   --verify   → 第 40 / 70 / 150 帧分三段跑自检后 quit
	#   --coltest  → 第 60 帧瞬移、第 300 帧出报告后 quit
	#   --plantdemo/--plant3d/--sheet/--staffpanel/--staffdemo/--staffrun → 截图/演示用，配合 --capture
	# 之所以拆成"这里置位 + _process 执行"：这些动作都需要世界已经装配完并渲染若干帧。
	if "--verify" in OS.get_cmdline_user_args():
		_verify = true
	if "--plantdemo" in OS.get_cmdline_user_args():
		_plant_demo = true
	if "--plant3d" in OS.get_cmdline_user_args():
		_plant3d_demo = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--sheet="):
			_plant_sheet = a.split("=")[1]
	if "--staffpanel" in OS.get_cmdline_user_args():
		_staff_panel_demo = true
	if "--staffdemo" in OS.get_cmdline_user_args():
		_staff_demo = true
	if "--staffrun" in OS.get_cmdline_user_args():
		_staff_run_demo = true
	if "--no-veg" in OS.get_cmdline_user_args():
		# 注意：渲染用的 MultiMesh 挂在 Vegetation/Chunk_x_y 下，**不是** Spawned
		# （Spawned 只是烘焙的位置数据）。第一版藏了 Spawned，前后三角面只差 2%，
		# 等于没隔离 —— 要藏的是 Chunk_* 这批块节点。
		var hid := 0
		for c in vegetation.get_children():
			if str(c.name).begins_with("Chunk_"):
				(c as Node3D).visible = false
				hid += 1
		print("Capture | [no-veg] 隐藏了 %d 个植被块（隔离植被开销）" % hid)
	if "--coltest" in OS.get_cmdline_user_args():
		_coltest = true
	# --no-ui 是独立的截图开关，别缩进到上面任何一个 if 里面去
	if "--capture" in OS.get_cmdline_user_args() \
			and "--no-ui" in OS.get_cmdline_user_args():
		ui.visible = false
		_minimap.visible = false

## 每帧主循环：刷新放置预览、推进各类倒计时，并驱动命令行调试模式。
##
## 参数：delta —— 距上一帧的秒数（60fps 约 0.0167，30fps 约 0.033）。**可能为 0**
##   （例如主循环被暂停/编辑器步进），所以下面算节流用的 dt 做了 >0 兜底；本函数自身
##   仍直接用原始 delta（_hint_timer 允许变负，下一帧就会触发一次提示，无害）。
##
## 调用时机：渲染帧的 process 阶段，每帧一次，早于 _physics_process 的可变次数调用。
##
## 副作用（改状态 / 改相机 / 写文件 / 退进程）：
##   * 累加 _place_rot_accum、修改 _place_yaw（右键按住旋转放置朝向）；
##   * 递减 _variant_hint_time / _hint_timer / _capture_frames / _probe_t，递增 _verify_frame、
##     _coltest_frame；
##   * 调用 Weather.follow_camera() 让雨盒跟随相机；
##   * 触发 UI 提示文本刷新（_update_interact_hint）；
##   * 调试模式下会调用 _save_capture() 写 PNG 并 get_tree().quit() 退出进程。
##
## 注意：_verify 与 _coltest 都排在截图逻辑**之前**：截图分支会递减 _capture_frames，
##   若让自检/功能测试混进同一段流程，两者就会互相吃掉对方的帧计数（见函数内注释）。
##   另外 --verify 在 >=150 帧时会 quit() 并 return，本帧不再走截图分支。
func _process(delta: float) -> void:
	# 拖拽预览跟随准星持续更新（第一人称下相机在移动）
	if _is_dragging:
		_update_preview()
	# 单点放置工具的目标点半透明预览（绿/红）
	# 用 Input.is_mouse_button_pressed（轮询）而不是事件，是为了"按住不放就持续旋转"；
	# 内部 while 每消费 0.1s 累积才 +10°，于是旋转速度与帧率无关（掉帧时会一帧补多步）。
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) and Game.current_tool in _place_tools:
		_place_rot_accum += delta
		while _place_rot_accum >= 0.1:
			_place_rot_accum -= 0.1
			_place_yaw += deg_to_rad(10.0)
	_update_place_preview()
	# delta 在极少数情况下会是 0（主循环暂停/编辑器步进/窗口失焦的某些后端）：
	# 直接拿它做倒计时，计时器会永远卡在同一个值上（提示不消失、节流不恢复）。
	# 兜底成 1/60 秒：只影响"提示还能显示多久"这类纯体验计时，不会影响物理。
	var dt := delta if delta > 0.0 else 0.016
	if _variant_hint_time > 0.0:
		_variant_hint_time -= dt
	# 这里用的是原始 delta（不是上面的 dt）：就算因为它为 0 而卡住，也只是"这一次提示刷得晚点"，
	# 而且 _hint_timer <= 0 用"变负也算过期"的写法，掉帧后能自然补上一次刷新。
	# 0.15s 的节流 ≈ 每秒 6.7 次：既跟得上玩家走动，又不用每帧查一次最近家具并重建提示字符串。
	_hint_timer -= delta
	if _hint_timer <= 0.0:
		_hint_timer = 0.15
		if _variant_hint_time > 0.0:
			pass    # 模型切换提示优先显示，短暂保留
		else:
			_update_interact_hint()
	# 雨盒跟随相机
	# follow_camera 每帧把雨体积的中心对齐相机（只动变换、不重建粒子），
	# 目的是让玩家视野内永远有雨；漏掉这行会看到"雨只下在出生点附近"。
	Weather.follow_camera(camera_rig.camera)
	# 自检模式：等世界和各系统装配完，把关键状态打出来再退出。
	# 放在截图逻辑之前：截图会把 _capture_frames 递减，两者共用一个计数器容易打架。
	if _verify:
		_verify_frame += 1
		# 分两段：装备格互斥的验证里会**换杖**，而 _fx 要等下一帧的 _place_head()
		# 才建出来。同一帧里装备完立刻查 _fx 必然查到 null（第一版就这么误报过 FAIL）。
		if _verify_frame == 40:
			_run_verify()
		elif _verify_frame == 70:
			_run_verify_late()
		elif _verify_frame >= 150:
			# 第 150 帧（约 2.5 秒，远超 0.8 秒的跑步剪辑）再查动画还在不在播
			_verify_anim_loop()
			get_tree().quit()
			return
	# 碰撞流式加载的功能测试（与截图无关，独立跑）
	if _coltest:
		_coltest_frame += 1
		if _coltest_frame == 60:
			_run_coltest_teleport()
		elif _coltest_frame == 300:
			_run_coltest_report()
			get_tree().quit()
			return
	# 连拍模式优先：一次运行内依次装备多根法杖，每根稳定 16 帧后存图
	# （注：上面这句"16 帧"是历史值，当前默认 _seq_step = 18，存图发生在
	#   elapsed % _seq_step == _seq_step - 2 那一帧；改成 18 是为了留一帧给换杖后的模型稳定。）
	# 这里**不 return**：连拍与下面"第 88 帧"的单张演示分支并存，只是各自条件通常不满足。
	if _capture_frames > 0 and not _capture_seq.is_empty():
		_run_capture_sequence()
	# 88 = 默认起始 90 - 2：提前两帧换杖，让手持模型的挂点/姿势至少有一帧时间落位再拍。
	# 用 get_node_or_null + call() 的字符串 API 而不是硬类型引用：法杖系统被整体移除过一轮，
	# 字符串调用可以在"没有 StaffSystem"时安全跳过，也不会在解析期报未知方法。
	if _capture_frames == 88 and _capture_staff != "":
		var sys := get_node_or_null("/root/StaffSystem")
		if sys != null:
			sys.call("unlock", _capture_staff)
			sys.call("equip", _capture_staff)
			print("Capture | 已装备法杖 %s" % _capture_staff)
			_dump_staff_state()
	# 临时演示：把两套房屋并排放出来对照（--houses），验收用
	if "--houses" in OS.get_cmdline_user_args() and _capture_frames == 88:
		var base := player.global_position + Vector3(0.0, 0.0, -11.0)
		for i in buildings.house_variant_count():
			var pos := base + Vector3(i * 9.0 - 4.5, 0.0, 0.0)
			buildings.add_house(pos, 1.0, 0.0, i)
		print("Capture | [houses] 已放置 %d 套房屋：%s"
				% [buildings.house_variant_count(), buildings.house_variant_name(0)
				   + " / " + buildings.house_variant_name(1)])
	if "--newmodels" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 验收：把 Tripo 的树各放一棵（走正式放置入口）
		for ti in mini(4, buildings.tree_variant_count()):
			var tp2 := player.global_position + Vector3(-11.0 + ti * 7.5, 0.0, -5.0)
			tp2.y = terrain.get_height_at(tp2.x, tp2.z)
			buildings.add_tree(tp2, 1.0, 0.5, ti)
		print("Capture | [newmodels] 已放置 %d 棵树（变体 %s ...）"
				% [buildings.tree_variant_count(), buildings.tree_variant_name(0)])
	if "--treepaint" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 验收：以程序方式"画"一条树枝笔画（走的是和鼠标拖动同一条函数）
		Game.current_tool = Game.Tool.TREE
		if terrain != null:
			var t3d: Node = terrain._find_terrain3d()
			if t3d != null and t3d.has_method("set_collision_enabled"):
				pass
		_tree_brush_active = true
		_tree_brush_count = 0
		_last_tree_pos = Vector3.INF
		for i in 30:
			var bp := player.global_position + Vector3(-14.0 + i * 1.0, 0.0, -6.0)
			bp.y = terrain.get_height_at(bp.x, bp.z)
			# 模拟"鼠标走到这里"：直接调用笔刷的内部放置逻辑
			if _last_tree_pos == Vector3.INF or bp.distance_to(_last_tree_pos) >= tree_brush_spacing:
				var ang := randf() * TAU
				var rad := sqrt(randf()) * tree_brush_radius
				var q := bp + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
				q.y = terrain.get_height_at(q.x, q.z)
				if not _is_occupied(q):
					buildings.add_tree(q, 1.0 + randf_range(-tree_brush_scale_jitter, tree_brush_scale_jitter),
							randf() * 360.0, _current_variant("tree"))
					_last_tree_pos = bp
					_tree_brush_count += 1
		buildings.flush_all()
		print("TreeBrush | [treepaint] 程序化笔画种了 %d 棵" % _tree_brush_count)
		_tree_brush_active = false
	if "--mapcheck" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 验收小地图朝向：把 yaw 设成 45°，在"镜头正前方"种一棵树。
		# 正确的话，它应该出现在小地图的**上方**（玩家箭头之上）。
		camera_rig.iso_yaw_deg = 45.0
		var mp := player.global_position + Vector3(9.0, 0.0, 9.0)   # yaw45 时镜头朝 (-0.707,0,-0.707)，正前方是 -X-Z
		var fwd := Vector3(-sin(deg_to_rad(45.0)), 0.0, -cos(deg_to_rad(45.0)))
		var tp3 := player.global_position + fwd * 9.0
		tp3.y = terrain.get_height_at(tp3.x, tp3.z)
		buildings.add_tree(tp3, 1.0, 0.0, 0)
		buildings.flush_all()
		print("MapCheck | 已把树种在镜头正前方 %s（小地图上应出现在玩家**上方**）" % str(tp3))
	if "--occl" in OS.get_cmdline_user_args() and _capture_frames == 88:
		# 遮挡穿透验收：在**相机与角色之间**放一棵树（相机在角色的 +X +Z 方向）
		var op := player.global_position + Vector3(3.4, 0.0, 3.4)
		op.y = terrain.get_height_at(op.x, op.z)
		buildings.add_tree(op, 1.0, 0.5, 0)
		print("Capture | [occl] 已在相机与角色之间放一棵树（应被淡化）")
	# --probe：每 0.5s 打印角色贴地状态（诊断"掉地底/抖动"用）
	if "--probe" in OS.get_cmdline_user_args():
		_probe_t += delta
		if _probe_t >= 0.5:
			_probe_t = 0.0
			var py := player.global_position
			print("PROBE | y=%.3f on_floor=%s vy=%.2f th=%.3f mask=%d" % [
					py.y, str(player.is_on_floor()), player.velocity.y,
					terrain.get_height_at(py.x, py.z), player.collision_mask])
			var t3 := terrain._find_terrain3d()
			if t3 != null:
				terrain._configure_terrain3d(t3)

			if t3 != null:
				print("PROBE3D | collision=%s layer=%d mask=%d mode=%s regions=%s" % [
						str(t3.get("collision")), int(t3.get("collision_layer")),
						int(t3.get("collision_mask")), str(t3.get("collision_mode")),
						str(t3.call("get_region_count") if t3.has_method("get_region_count") else -1)])
	# 截图倒计时收尾：_apply_capture_view() 每帧都会硬写相机位姿（会压过 camera_rig 的跟随），
	# 递减到 0 时存 PNG 并请求退出。
	# 注意 _save_capture 里的 get_image() 读的是渲染目标中**已经提交**的内容（本帧尚未提交），
	# 所以实际拍到的约等于上一帧（推测，具体与渲染后端有关）—— 这也是"提前两帧摆道具"的由来。
	if _capture_frames > 0:
		_apply_capture_view()
		_capture_frames -= 1
		if _capture_frames == 0:
			_save_capture("user://screenshot_check.png")
			get_tree().quit()


# ==================== 十一、命令行诊断与截图工具函数 ====================
# 本段函数全部只在命令行开关打开时被调用，正常游玩不会进入；它们的存在意义是让 CI /
## 无焦点窗口也能出结果（只依赖 stdout 与写 PNG）。
## 作用：连拍辅助 —— 在**一次**进程里按 _seq_step 帧的节奏轮换法杖，每根存一张图。
##   （一次启动要花约 6s 生成地形，逐根杖重启太慢，所以做成"一次运行连拍"。）
## 参数：无（全部读成员：_capture_seq 杖 id 列表、_seq_step 每根占几帧、
##   _capture_start 起始帧数、_capture_frames 当前剩余帧数、_seq_idx 上次拍的是第几根）。
## 返回值：无。
## 副作用：① 经 StaffSystem.unlock()/equip() 改全局法杖状态；② 通过 _save_capture() 写 PNG，
##   文件名规则同 --out=（默认 user://screenshot_check_<杖id>.png）。
## 调用时机：_process() 中 _capture_frames > 0 且 _capture_seq 非空时，每帧一次。
## 注意：idx 走的是**整数除法**（elapsed / _seq_step），所以两个操作数都必须是 int；
##   idx 超出序列长度后本函数直接返回，"多出来的帧"由 _process 尾部的截图逻辑消耗完。
## 连拍：--staffseq=a,b,c  每根法杖占 SEQ_STEP 帧
func _run_capture_sequence() -> void:
	var elapsed := _capture_start - _capture_frames
	var idx := elapsed / _seq_step
	if idx >= _capture_seq.size():
		return
	if idx != _seq_idx:
		_seq_idx = idx
		var sys := get_node_or_null("/root/StaffSystem")
		if sys != null:
			sys.call("unlock", _capture_seq[idx])
			sys.call("equip", _capture_seq[idx])
			print("Capture | 已装备法杖 %s" % _capture_seq[idx])
	if elapsed % _seq_step == _seq_step - 2:
		var path := "user://screenshot_check.png"
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--out="):
				path = "user://%s" % a.split("=")[1]
		var dot := path.rfind(".")
		var out := ("%s_%s%s" % [path.substr(0, dot), _capture_seq[idx],
				path.substr(dot)]) if dot > 0 else "%s_%s" % [path, _capture_seq[idx]]
		_save_capture(out)


## 返回值：无（只打印到 stdout）。副作用：只读，不改任何状态。
## 注意：这里用 player.get("held_staff") + hs.call("debug_info") 这种动态接口，
##   是因为法杖相关类型在"整体移除法杖系统"那轮已从项目中删除，写硬类型会直接编译失败；
##   因此 held_staff 为空时不能直接报错，只能打印一行提示。
## 诊断：手持法杖到底挂在什么尺寸/朝向上（截图/排查用）
func _dump_staff_state() -> void:
	var hs = player.get("held_staff")
	if hs == null:
		print("StaffDump | held_staff 为空（没挂上）")
		return
	var d: Dictionary = hs.call("debug_info")
	print("StaffDump | %s" % JSON.stringify(d))

## 把当前视口内容存成 PNG，并顺带打印输入状态与渲染统计（三角面 / draw call / 物件数 / FPS）。
##
## 参数：out_path —— Godot 路径字符串，实际调用给的是 user:// 开头（磁盘位置为
##   %APPDATA%\Godot\app_userdata\<项目名>\...）；也接受 res:// 等其它可写路径。
## 返回值：无。取帧失败（img == null）时只打印一行"取帧失败"并 return，**不报错、不退出**。
## 副作用：写文件；打印三行日志；不修改任何游戏状态。
## 调用时机：只在 --capture / --staffseq 流程里、渲染若干帧之后调用。
## 注意：headless / 无渲染设备时视口纹理可能取不到（推测），所以失败分支必须容错；
##   另外"三角面/draw call"这两项是**读渲染服务器当帧统计**，只能在这里（帧内）读才有意义。
func _save_capture(out_path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		print("Capture | 取帧失败 %s" % out_path)
		return
	var err := img.save_png(out_path)
	print("Capture | 已保存 %s err=%d abs=%s"
			% [out_path, err, ProjectSettings.globalize_path(out_path)])
	# 植被换成自制模型之后，"一帧画多少三角面"必须能直接读出来 ——
	# 密度（PLANT_KEEP）就是照这个数调的，靠目测帧率太不稳。
	print("Input | mouse_mode=%d（0=可见 2=捕获）captured=%s 工具=%s 放置点=%s"
			% [Input.mouse_mode, str(camera_rig.is_mouse_captured()),
			   str(Game.current_tool), str(_get_ground_pos())])
	print("Perf | 三角面=%d 绘制调用=%d 渲染物件=%d FPS=%.1f"
			% [RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			   RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			   RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
			   Performance.get_monitor(Performance.TIME_FPS)])

## 参数/返回值：无。副作用：只向 stdout 打印（退出由 _process() 在第 150 帧负责）。
## 现状：法杖/植物建模已整体移除，相关断言在那一轮被摘掉，函数体现在只剩两行提示 ——
##   保留这个"空壳"是刻意的：--verify 这条启动路径与 _process() 第 40 帧的调用点都要继续有效。
## --verify：无人值守自检。
##
## 把法杖系统 / 装备格 / 手持模型 / 长老系统的关键状态打到 stdout。
## 存在的理由：MCP 的 game_eval 需要游戏窗口**有焦点**才能推进主循环，
## 而后台跑 CI / 截图时窗口一定是失焦的（实测反复 AppActivate 也不稳）。
## 这条路径只依赖 stdout，headless 也能跑：
##     godot --headless --path . -- --verify
func _run_verify() -> void:
	print("Verify | ==== Cozy Vale 自检 ====")
	print("Verify | 法杖/植物建模已整体移除，这部分自检项不再适用")


## 参数/返回值：无。副作用：只打印。
## 为什么自检要拆成两段（第 40 帧 / 第 70 帧）：有些验证会**换杖**，而 _fx 之类的节点
##   要等下一帧的 _place_head() 才创建出来；在同一帧里查必然拿到 null（第一版就这么误报过 FAIL）。
## 自检的第二段
func _run_verify_late() -> void:
	print("Verify | ==== 自检结束 ====")












## 参数：
##   sys —— 提供 base_element（登记基准值）与 get_def(id) 的系统节点（原为法杖系统）。
##   ids —— 要还原的元素 id 列表（Array；元素会被 str() 规范化成字典 key）。
## 返回值：无。
## 副作用：**原地修改** sys 内部 defs 字典里的 element 字段（把测试期间改过的内存态抹回基准），
##   不落盘、不发信号 —— 只适合自检这种"用完即弃"的场景。
## 注意：当前全项目已经**没有任何调用处**（原法杖自检专用），保留是因为删函数需要同步清理调用方，
##   而它的调用方早被删掉；下次大扫除可以安全移除（推测）。
## 把 defs 里的元素全部还原成登记时的基准值（自检里抹内存态用）
func _reset_def_elements(sys: Node, ids: Array) -> void:
	var base: Dictionary = sys.get("base_element")
	for i in ids:
		var d: Dictionary = sys.call("get_def", str(i))
		d["element"] = int(base.get(str(i), 0))














## 返回值：无；副作用：只**读** player.anim_player 与 player.LOOP_CLIPS，不切剪辑、不改 loop_mode，
##   仅向 stdout 打印每项检查结果与最后的 [OK]/[FAIL]。
## 调用时机：--verify 模式下由 _process() 在**第 150 帧**（约 2.5s）调用，随后 quit。
## 「跑一段后动画静止」的回归测试。
##
## 真因：Mage.glb 导进来的 76 个动画 + kaykit 库那 12 个，`loop_mode` **全是
## LOOP_NONE**。Running_A 只有 0.8 秒，播完 AnimationPlayer 就停住，角色定格在
## 最后一帧 —— 表现就是"跑一段就静止"，时长和剪辑长度完全对得上。
## 修法是 player._ensure_loop_anims() 把该循环的剪辑设成 LOOP_LINEAR。
##
## 这里做两个断言：(1) 白名单里的剪辑都得是循环；(2) 启动约 2.5 秒后动画仍在播。
func _verify_anim_loop() -> void:
	var ap: AnimationPlayer = player.anim_player
	if ap == null:
		print("Verify | [FAIL] 角色没有 AnimationPlayer")
		return
	var bad := PackedStringArray()
	for n in player.LOOP_CLIPS:
		if not ap.has_animation(n):
			continue
		if ap.get_animation(n).loop_mode != Animation.LOOP_LINEAR:
			bad.append(n)
	print("Verify | 应循环的剪辑 %d 个，仍不是循环的：%s"
			% [player.LOOP_CLIPS.size(),
			   ("无" if bad.is_empty() else ", ".join(bad))])
	var cur := str(ap.current_animation)
	var playing := ap.is_playing()
	print("Verify | 启动约 2.5 秒后：当前剪辑=%s 播放中=%s 位置=%.3f"
			% [cur, str(playing), ap.current_animation_position])
	var ok := bad.is_empty() and playing
	print("Verify | %s 移动/待机剪辑会一直循环（不再播完就定格）"
			% ["[OK]" if ok else "[FAIL]"])


## 元素 id → 显示名（转发给全局 StaffSystem.element_name()）。
##
## 参数：e —— 元素枚举值（int，0 起；越界时由 StaffSystem 决定返回什么，本函数不做校验）。
## 返回值：String —— 显示名；**取不到 /root/StaffSystem 时返回 "?"**（不抛异常）。
## 副作用：无（纯查询，不改状态）。用 call() 而不是直接引用，理由同 _dump_staff_state。
## 注意：当前全项目搜不到调用处（原自检/提示用），这行函数是那轮删减后留下的孤儿（推测），
##   但保留成本极低，删除前请先确认没有字符串形式的调用方。
func sys_elem_name(e: int) -> String:
	var sys := get_node_or_null("/root/StaffSystem")
	if sys == null:
		return "?"
	return str(sys.call("element_name", e))











## 为什么用瞬移而不是"走过去"：走几十米要好几十秒、还会被地形/植被碰撞绊住甚至掉出地图，
##   瞬移能干净地验证"锚点换到远处后，新半径内的碰撞体有没有被补建出来"。
## 参数：无；返回值：无。副作用：**直接写 player.global_position**（会触发物理/相机的下一帧跟随），
##   并且用 terrain.get_height_at() 把落点抬到地表，避免瞬移进地里。
## 注意：目标点 (252, 0, 64) 是**硬编码**的村庄坐标；若世界布局/地形改了，这里可能落到别处
##   甚至空中（推测），届时改这个常量即可。
## --coltest：把玩家瞬移到世界另一端，等若干帧后统计"碰撞半径内还有多少实例没建碰撞体"。
## 这是"远处物体碰撞失效"的直接判据 —— 不用走过去，也不靠肉眼看。
func _run_coltest_teleport() -> void:
	var target := Vector3(252.0, 0.0, 64.0)     # 村庄（远离出生点）
	if terrain != null and terrain.has_method("get_height_at"):
		target.y = terrain.get_height_at(target.x, target.z)
	player.global_position = target
	print("ColTest | 瞬移到 (%.0f, %.1f, %.0f)" % [target.x, target.y, target.z])


## --coltest 的第二步：统计"碰撞半径内有多少实例还没建碰撞体"，并把结论打成 [OK]/[FAIL]。
##
## 参数：无。读取 vegetation 的内部状态（都是动态访问，因为它们是私有成员）：
##   _collision_anchor()  当前碰撞锚点（= 相机位置，见 vegetation.gd）
##   collision_radius     建碰撞的水平半径（默认 60.0m）
##   _blocks              块数组，每块含 "col_queue"（待建位置，Dictionary 里取 "pos"）
##                        与 "col_bodies"（已建的 StaticBody3D）
##   _pending_blocks      还没轮到处理的块下标
## 返回值：无（结论只打到 stdout）。
## 副作用：**只读**。这一点是刻意的 —— 本函数不去补建缺失的碰撞体，
##   否则"缺多少"这个测量值会被自己改掉，测试就失去意义了。
## 判定规则：距离锚点 <= collision_radius 的实例"应该"已有碰撞体（缺了就 FAIL）；
##   半径之外没有碰撞体属于正常（流式加载就是靠这个省开销），单独计数不判错。
## 调用时机：--coltest 模式下 _process() 的第 300 帧，随后 quit。
func _run_coltest_report() -> void:
	var anchor: Vector3 = vegetation.call("_collision_anchor")
	var rad := float(vegetation.get("collision_radius"))
	var r2 := rad * rad
	var blocks: Array = vegetation.get("_blocks")
	var need := 0
	var have := 0
	var missing_near := 0
	var missing_far := 0
	var pend: Array = vegetation.get("_pending_blocks")
	for b in blocks:
		var q: Array = b["col_queue"]
		var bodies: Array = b["col_bodies"]
		for i in q.size():
			var pos: Vector3 = (q[i] as Dictionary)["pos"]
			var dx := pos.x - anchor.x
			var dz := pos.z - anchor.z
			var near := (dx * dx + dz * dz) <= r2
			var has := i < bodies.size() and is_instance_valid(bodies[i])
			if near:
				need += 1
				if has:
					have += 1
				else:
					missing_near += 1
			elif not has:
				missing_far += 1
	print("ColTest | 锚点=(%.0f, %.0f) 半径=%.0f 待办块=%d" % [anchor.x, anchor.z, rad, pend.size()])
	print("ColTest | 半径内应建 %d，已建 %d，**缺 %d**；半径外未建 %d（正常）"
			% [need, have, missing_near, missing_far])
	print("ColTest | %s 半径内实例碰撞齐全" % ["[OK]" if missing_near == 0 else "[FAIL]"])




## 参数：t —— "x,y,z" 形式的字符串（不带键名）。
## 返回值：Vector3；字段数不足 3 时返回 Vector3.ZERO（调用方据此判断"没给/给错了"，
##   所以 _apply_capture_view 里把 ZERO 当作"自动对准角色"的哨兵）。
## 副作用：无。注意：非数字字段会被 Godot 的 float() 静默转成 0.0，不会报错（推测），
##   所以参数写错的表现通常是"相机跑到原点"，而不是启动失败。
## 解析 --cam=x,y,z / --look=x,y,z
func _parse_vec3(t: String) -> Vector3:
	var p: PackedStringArray = t.split(",")
	if p.size() < 3:
		return Vector3.ZERO
	return Vector3(float(p[0]), float(p[1]), float(p[2]))


## 参数：无（读成员 _capture_aerial / _capture_free / _capture_cam / _capture_look）。
## 返回值：无。副作用：直接写 camera.global_position（+俯视时写 camera.fov）、
##   并把 camera_rig.interact_freeze 置 true。
## 注意：两个开关都没开时函数**立刻 return**，所以正常游玩时它什么都不做。
##   `interact_freeze = true` 在这里是被**借用**的：它原本表示"家具互动期间冻结角色物理驱动"，
##   截图时借用同一分支让 CameraRig 不再改写相机位姿（推测这是当时的意图）。
## 调试截图：俯视全景（--aerial）或自由机位（--cam/--look）
func _apply_capture_view() -> void:
	if not _capture_aerial and not _capture_free:
		return
	camera_rig.interact_freeze = true
	if _capture_aerial:
		camera.global_position = Vector3(0.0, 430.0, 480.0)
		camera.look_at(Vector3(0.0, 0.0, 40.0), Vector3.UP)
		camera.fov = 58.0
	else:
		camera.global_position = _capture_cam
		# 不给 --look 就**自动对准角色**：角色的落地高度是物理结算出来的，
		# 手填的注视点十有八九对不上（实测差 1.8m，整根杖跑到画面外）。
		var tgt := _capture_look
		if _capture_look == Vector3.ZERO or _capture_look == _capture_cam:
			tgt = player.global_position + Vector3(0.0, 0.95, 0.0)
		camera.look_at(tgt, Vector3.UP)


# ==================== 十二、世界装配辅助（UI / 相机 / 预览 / 输入映射） ====================
## 把主场景引用注入 UI 层与小地图（两者的脚本已在 main.tscn 里挂好，这里只做注入/一次性配置）。
##
## 参数：无（用 @onready 的 ui / _minimap 引用）。返回值：无。
## 副作用：调用 ui.setup(self) 与 _minimap.setup(self)，让它们持有主场景引用（后续回调靠它）。
## 调用时机：_ready() 装配阶段第 6 步，**早于 `Game.world = self`** ——
##   所以 UI 的 setup() 里不要读 Game.world（此刻还是 null），要用传进去的 main 参数。
func _setup_ui() -> void:
	# UI 层在场景中声明（含脚本），这里只注入主场景引用
	ui.setup(self)
	_minimap.setup(self)

## 参数：无；返回值：无。副作用：写 camera_rig.camera / camera_rig.player 两个引用。
## 为什么 terrain 不在这里接：WorldBuilder 生成地形后才把 terrain 交进 CameraRig
##   （相机贴地/地面拾取都依赖它），本函数执行时地形还不存在。
## 相机与角色引用由场景声明，运行时把 @export 引用接上
## 注意：子节点的 _ready() 在父节点 _ready() 之前执行，所以 CameraRig._ready()
## 里读到的 camera/player 只能来自场景绑定的导出引用（scenes/main.tscn），
## 这里再补一次，保证任何注入路径下都一致。
func _wire_camera_rig() -> void:
	camera_rig.camera = camera
	camera_rig.player = player
	# terrain 由 WorldBuilder 在地形生成后接入（相机贴地/地面拾取要用）

## 参数：无。返回值：无。
## 副作用：① 给 preview_wall/preview_roof 挂材质；② **运行时创建**真实模型的 MeshInstance3D
##   （TowerPreview / HousePreview / FlowerPreview / FurniturePreview / TreePreview /
##   MountainPreview）并 add_child 到 preview_place；③ 递归给 preview_place 子树套半透明材质。
## 为什么预览要"用真实模型 + 半透明"：放置时看到的就是最终模型，尺寸/朝向/底面高度都能提前对齐，
##   避免"放下去才发现变大变小"。
## ⚠ 缩放必须与放置逻辑手工保持一致，否则幽灵和实物会差一截：
##   塔 = maxf(0.35, tower_radius*2 / buildings._tower_base)（_tower_base 是 building_manager 的
##   **私有成员**，表示模型实际底宽）；房屋 = buildings.house_base_scale()；
##   树 = buildings.tree_base_scale()；家具 = 1.0；花 = 1.1；山体 = 4.0
##   （对应 _begin_tool 里 add_mountain(p, 4.0, ...)）。
## 预览节点结构在场景中；这里只装配预览材质与真实模型网格（模型为运行时提取）
func _setup_previews() -> void:
	preview_wall.material_override = PREVIEW_WALL_MAT
	preview_roof.material_override = PREVIEW_ROOF_MAT
	# 塔预览：真实塔楼模型半透明（scale 与放置时一致）
	# 注意：这些预览子节点都是**运行时 new 出来的**（main.tscn 里没有），
	# 所以它们的尺寸/材质完全由本函数决定，不会随场景文件变化。
	var tower_mi := MeshInstance3D.new()
	tower_mi.name = "TowerPreview"
	tower_mi.mesh = _extract_mesh(buildings.tower_scene)
	tower_mi.scale = Vector3.ONE * maxf(0.35, tower_radius * 2.0 / buildings._tower_base)
	preview_place.add_child(tower_mi)
	# 屋预览：真实小屋模型半透明（scale 与放置默认一致）
	var house_mi := MeshInstance3D.new()
	house_mi.name = "HousePreview"
	# 房屋有多套（红顶小屋 / 茅草屋），各自自带基准缩放，见 building_manager.HOUSE_MODELS
	house_mi.mesh = _extract_mesh_merged(buildings.house_scene_at())
	house_mi.scale = Vector3.ONE * buildings.house_base_scale()
	preview_place.add_child(house_mi)
	# 树/花预览：花草树木的整体移除后分类表是空的，`category_model_path()` 会返回 ""，
	# 直接 `load("")` 会在启动时报 `Resource file not found: res://`（实测两条）。
	# 所以这里按"有模型才建预览"处理，新模型做好后自动恢复。
	# 树木预览：由 buildings.tree_scene_at() 提供（图表当前为空 -> tsc==null -> 不建预览）。
	# 接入 Tripo 模型后这里自动生效，不用改。

	# 花草预览走通用分支（分类表为空则不建）；⚠ 这里的 1.1 与 _preview_base_scale_for("flower")
	# 的返回值是**两处手抄的同一个数**，改一处必须改另一处，否则滚轮换模型后尺寸会跳。
	_add_plant_preview(preview_place, "FlowerPreview", "flower", 1.1)
	# 家具预览：真实家具模型半透明（scale 与放置一致）
	# ⚠ 这里是直接 load(FURNITURE_MODELS[0])、**没有判空**：一旦分类表被清空或第 0 个
	# 路径失效，就会在启动时报 `Resource file not found: res://`（与 _add_plant_preview()
	# 里"有模型才建"的防护不同）。同理见下面的 MOUNTAIN_MODELS[0]。
	var furniture_mi := MeshInstance3D.new()
	furniture_mi.name = "FurniturePreview"
	furniture_mi.mesh = _extract_mesh(load(VegetationSystem.FURNITURE_MODELS[0]))
	# 参天大树预览：用 building_manager 的树场景（多材质，和实际放置同一个模型）
	var tree_mi := MeshInstance3D.new()
	tree_mi.name = "TreePreview"
	var tsc := buildings.tree_scene_at()
	if tsc != null:
		var mmesh := _extract_mesh_merged(tsc)
		if mmesh != null:
			# ★★ 修复（用户实测 ✓）：合并出的网格**没有材质** ✗ → Godot 用内置**默认白材质**渲染 ✓
			#   → 运行时会出现一棵"参天白树" ✓（编辑器里看不到 ✓ 因为幽灵是运行时创建的 ✓）
			#   这里按 surface 顺序，把源场景的材质抄回来 ✓
			#   ★ 先 duplicate()：合并函数可能返回**共享网格** ✗，直接改会污染所有使用它的实例 ✓
			mmesh = mmesh.duplicate()
			# ★ 正确做法（上一版写错了 ✗）：PackedScene **不是 Node** ✗
			#   → 必须先 instantiate() 拿到节点树，才能 find_children ✓
			#   → 用完 free()（未入树 ✓ 立即释放 ✓；free 比 queue_free 更干净 ✓）
			var src_mats: Array = []
			var src_root: Node = tsc.instantiate()
			if src_root != null:
				for c in src_root.find_children("*", "MeshInstance3D", true, false):
					var cmi := c as MeshInstance3D
					if cmi == null or cmi.mesh == null:
						continue
					for s2 in range(cmi.mesh.get_surface_count()):
						src_mats.append(cmi.mesh.surface_get_material(s2))
				src_root.free()
			var n_copy := mini(src_mats.size(), mmesh.get_surface_count())
			for i2 in range(n_copy):
				var mm: Material = src_mats[i2]
				if mm != null:
					mmesh.surface_set_material(i2, mm)
			if n_copy == 0:
				print("[预览埋点] TreePreview 源场景没有可抄的材质 ✗（tsc=%s）" % tsc.resource_path)
			else:
				print("[预览埋点] TreePreview 已抄入材质 %d/%d ✓（源=%s）" % [
						n_copy, mmesh.get_surface_count(), tsc.resource_path])
		tree_mi.mesh = mmesh
		tree_mi.scale = Vector3.ONE * buildings.tree_base_scale()
	preview_place.add_child(tree_mi)
	furniture_mi.scale = Vector3.ONE
	preview_place.add_child(furniture_mi)
	# 山体预览：真实 cliff 模型半透明（scale 与放置一致，用山体中值）
	var mountain_mi := MeshInstance3D.new()
	mountain_mi.name = "MountainPreview"
	mountain_mi.mesh = _extract_mesh(load(VegetationSystem.MOUNTAIN_MODELS[0]))
	# 4.0 这个"山体中值缩放"在三处手抄：这里、_begin_tool 的 add_mountain(p, 4.0, ...)、
	# _preview_base_scale_for("mountain")。任何一处改了，其余两处要同步，否则预览与实物不等大。
	mountain_mi.scale = Vector3.ONE * 4.0
	preview_place.add_child(mountain_mi)
	# 装配阶段即挂上半透明材质：即使当前没瞄到地面（落点更新会提前 return），
	# 换模型后的预览也一定是"半透明真实模型"。
	_apply_place_material(preview_place, PREVIEW_PLACE_OK)
	# 预览偏移与放置一致（每个工具按各自分类应用一次）
	# 每个工具各套一次偏移（而不是等第一次瞄准地面）：切到某个工具时预览位置就已经正确，
	# 不会出现"刚选中工具那一瞬间模型在错误位置闪一下"。
	for tool in _place_tools:
		var cat := _tool_category(tool)
		if cat.is_empty():
			continue
		var node := _preview_for_tool(tool)
		if node != null:
			_apply_preview_offset(node, cat)

## 注册运行时需要的 InputMap 动作（目前只有 Ctrl+Z 撤销）。
##
## 参数：无。返回值：无。
## 副作用：**修改全局 InputMap**（新增事件到 "ui_undo" 动作）。
## 调用时机：_ready() 装配阶段一次。
## 注意：
##   * 本脚本自己的撤销走的是 _unhandled_input() 里 `KEY_Z + ctrl_pressed` 的直接判断，
##     这里注册的 ui_undo 是给其它脚本/UI 用动作名调用用的（当前全项目还没有消费者，推测）。
##   * InputMap 是**全局**的：按 R 重载场景会再执行一次本函数，事件会往同一个动作里叠加。
##     重复事件不会造成错误行为（第一个匹配即触发），但列表会随重载变长。
func _setup_input_actions() -> void:
	# 快捷键：撤销
	var action := InputEventKey.new()
	action.physical_keycode = KEY_Z
	action.ctrl_pressed = true
	InputMap.action_add_event("ui_undo", action)

## 物理帧回调：维护"拖拽预览"与"家具互动"两条状态。
##
## 参数：_delta —— 物理帧间隔；**有意不使用**（下划线前缀），因为这里只做状态同步/轮询，
##   不按时间积分。物理帧率由项目设置决定（默认 60Hz），一次渲染帧可能对应 0~N 次本调用。
##
## 调用时机：物理帧（早于 _process 还是晚于不一定，两者不要互相依赖执行顺序）。
##
## 副作用：① 可能调用 player.stop_interact()（玩家在互动中按了移动/跳跃键）；
##   ② 每物理帧写 camera_rig.interact_freeze = player.is_interacting()（冻结角色物理驱动，
##   位置改由 player 管理，防止坐/睡高度被重力拉回）；③ 刷新拖拽预览网格。
##
## 注意：拖拽预览在 _process 与这里各更新一次，属历史叠加；重复执行是幂等的
##   （只多算一次 ArrayMesh），别为了"去重"删掉其中一个 —— 两处的时机覆盖不同步进。
func _physics_process(_delta: float) -> void:
	# 拖拽预览跟随准星持续更新（第一人称下相机在移动）
	if _is_dragging:
		_update_preview()
	# 家具互动中：按移动键/跳跃立即退出
	# 这里用"轮询按键状态"而不是 InputMap 动作：互动期间角色的输入被冻结/由 player 自己消费，
	# 走动作事件可能收不到；"任意一键打断"用轮询最直接（KEY_C 也一并算了进来）。
	if player.is_interacting():
		if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_C):
			player.stop_interact()
	# 家具互动期间冻结角色物理驱动（位置由 player 管理，防坐/睡高度被重力拉回）
	camera_rig.interact_freeze = player.is_interacting()

## 未被 UI 消费的输入统一入口（键盘 / 鼠标按键 / 鼠标移动）。
##
## 参数：event —— 引擎分发的输入事件；本函数只处理 InputEventKey、InputEventMouseButton、
##   InputEventMouseMotion 三类，其余类型直接落到函数末尾（什么都不做）。
## 返回值：无（这是回调，不是查询函数）。
## 调用时机：输入分发阶段，**在 Control/UI 处理之后** —— 所以点在 UI 面板上的操作会被 UI 吃掉，
##   不会误触发放置（这也是这里敢用"点在哪就放哪"的前提）。
## 副作用（都不小，改代码时留意）：
##   * 键盘：Ctrl+Z 撤销（buildings.undo）、R 重载当前场景、1~0 切工具（经 set_tool，
##     会发 Game.tool_changed 并重置预览）、E 互动、V 切换天气；
##   * 滚轮：无工具时缩放视野（camera_rig.zoom_by）、有单点工具时切模型变体；
##   * 右键：单点工具下旋转放置朝向；无工具时按住拖动旋转场景（并临时捕获鼠标）；
##   * 左键：_begin_tool() / _end_tool()（放置、拖拽建墙、树木笔刷起笔/收笔）；
##   * 鼠标移动：树木笔刷刷点、无工具时按 relative.x 旋转相机 yaw。
## ⚠ 输入分支的隔离完全靠这些 `return`：历史上曾把一个带 return 的鼠标移动块按错误缩进插进
##   鼠标按钮分支，导致左键放置分支被截断成死代码（用户实测"完全无法放置"）。
##   往本函数里加分支时，务必确认 return 的归属层级。
func _unhandled_input(event: InputEvent) -> void:
	# 键盘：撤销 / 重生成 / 数字键切工具
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_Z and event.ctrl_pressed:
			buildings.undo()
			return
		# R = 重载当前场景（调试用）：会重新走一遍 _ready() 的全部装配，
		# 地形重新生成约 6s；同时意味着"未保存的放置内容全部丢失"，正式流程不要依赖它。
		if event.keycode == KEY_R:
			get_tree().reload_current_scene()
			return
		# 数字键 → 工具的映射表：注意它**没有** PATH(小径) 与 ERASE(橡皮擦)，
		# 这两个工具当前没有实现，按不到对应键（Game.Tool 里有枚举但没有行为）。
		# 用 keycode（语义键名）而不是 physical_keycode：这里按的是"数字键"本身，
		# 换了键盘布局仍能按上排数字键。表里没有的键落到下面的 has() 判断被跳过。
		var tool_by_key := {
			KEY_1: Game.Tool.WALL,
			KEY_2: Game.Tool.TOWER,
			KEY_3: Game.Tool.ROOF,
			KEY_4: Game.Tool.TERRAIN_RAISE,
			KEY_5: Game.Tool.TERRAIN_LOWER,
			KEY_6: Game.Tool.TERRAIN_FLATTEN,
			KEY_7: Game.Tool.TREE,
			KEY_8: Game.Tool.FLOWER,
			KEY_9: Game.Tool.DECOR,
			KEY_0: Game.Tool.MOUNTAIN,
		}
		if tool_by_key.has(event.keycode):
			set_tool(tool_by_key[event.keycode])
			return
		if event.keycode == KEY_E:
			_try_interact()
			return
		if event.keycode == KEY_V:
			_cycle_weather()
			return

	# 鼠标现在默认可见（俯视角不捕获光标），所以不再用"是否捕获"当作放入口开关；
	# 点在哪就放在哪。UI 上的点击会被 Control 消费掉，不会走到 _unhandled_input。
	if event is InputEventMouseButton:
		# 滚轮：**没选任何放置工具时用来缩放场景**（用户要求 75%~200%）；
		# 选了工具才是切模型变体。
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
				and not (Game.current_tool in _place_tools):
			# 方向：**滚轮上 = 拉近（视野变小 / 百分比变小）**，滚轮下 = 拉远。
			# 上一版写反了（上=拉远），用户实测反馈"滚轮缩放视角弄反了"。
			# 注意 zoom_by 的语义是 dir=+1 拉远，所以这里要取反。
			var dz := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			if camera_rig.zoom_by(dz):
				ui.show_interact_hint("视野 %.0f%%（滚轮缩放，75%%~200%%）"
						% (camera_rig.iso_zoom * 100.0))
				_variant_hint_time = 1.2
			return
		# 滚轮：切换当前放置工具的模型变体（分类下有多个模型时）
		if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] \
				and Game.current_tool in _place_tools:
			_cycle_variant(-1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 1)
			return
		# 单击右键 = 放置朝向 +10°；**按住**则由 _process() 每 0.1s 再 +10°。
		# 两个入口各管一半（这里是单击那一下，_process 管持续按住），不要以为对方会兜底。
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and Game.current_tool in _place_tools:
			_place_yaw += deg_to_rad(10.0)
			return
		# 未选任何工具时：**右键按住拖动旋转场景**（俯视角的 yaw/pitch 都是常量，
		# 所以旋转就是改那两个常量）。小地图跟着转、大地图不转，见 minimap.gd。
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_rotating = event.pressed
			# 拖动旋转期间**隐藏并锁住光标**：否则鼠标一划就移出窗口，
			# 旋转会突然中断、指针也跑到别的窗口上去（用户实测）。
			# 松开立刻恢复可见 —— 俯视角平时就是要点鼠标的。
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if _rotating \
					else Input.MOUSE_MODE_VISIBLE
			return
		# 左键：开始/结束放置。
		# **这两行必须留在"鼠标按钮"分支里面**：上一版我把右键旋转的
		# `if event is InputEventMouseMotion` 块按 1 层缩进插到了这里，
		# 它带着一个 `return` 把整个鼠标按钮分支截断，于是左键放置变成了
		# 运动事件分支里的死代码 —— 表现就是"完全无法放置物品"（用户实测）。
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			_begin_tool()
		elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			_end_tool()
		return
	# 树木笔刷：按住左键拖动时，每走够 spacing 就再种一棵
	# 分支顺序要紧：笔刷与下面的"旋转场景"都吃 InputEventMouseMotion，笔刷这条带 return，
	# 必须排在前面，否则拖动种树时会被旋转分支先截走。
	if event is InputEventMouseMotion and _tree_brush_active:
		_paint_tree_stroke()
		return
	# 两个条件缺一不可：_rotating（右键正按住）且当前**不是**单点放置工具 ——
	# 后者的右键语义是"旋转放置朝向"，不能同时把整个场景转掉。
	if event is InputEventMouseMotion and _rotating and not (Game.current_tool in _place_tools):
		# 右键拖动**只做水平旋转**（绕 Y 轴），俯仰角锁定不动。
		# 用户要求："按住鼠标右键只可以旋转场景，但锁定y"。
		# 俯角仍由 camera_rig.iso_pitch_deg 决定（默认 52°），不再被鼠标改。
		# 0.28 ≈ 每像素多少度（灵敏度，手调出来的）；fposmod 把结果归一到 0..360，
		# 这样对外读数（UI/小地图/日志）始终在一个规范区间里，不会出现 -720° 这种值。
		camera_rig.iso_yaw_deg = fposmod(camera_rig.iso_yaw_deg
				- event.relative.x * 0.28, 360.0)

# ==================== 十三、工具与游玩交互（换杖提示 / 天气 / 家具互动） ====================
# 注：紧接着的这两行"V 键/天气"的 ## 说明描述的其实是本段更靠后的 _cycle_weather()，
# 它被插在了 _show_staff_hint() 文档块的前面（历史遗留的错位），按文档归类读时别被顺序误导。
## 参数：无。返回值：无。
## 副作用：改 Weather.target（经 set_weather(next, true) 强化制立即生效、打断过渡），
##   写 UI 提示 + _variant_hint_time，并打一行日志。
## 注意：本函数只"手动切一次"，且**不改 auto_change** —— 所以切完之后自动天气仍可能继续变化；
##   _ready() 里的 --weather=N 是另一条入口，那条会先关掉 auto_change（为了截图可复现）。
## V 键：按顺序切换天气（晴朗 → 多云 → 阴天 → 小雨 → 雷雨 → 大风）
## 切换立即生效（force），并暂停自动天气一段时间，方便观察风摇效果。
## 参数：id —— 法杖 id 字符串；**传空串 "" 表示"空手 / 收起法杖"**。
## 返回值：无。副作用：写 UI 互动提示文本，并把 _variant_hint_time 设成 1.6 秒
##   （让换杖提示在一小段时间内不被每 0.15s 刷新的家具互动提示覆盖）。
## 注意：ui 为空时立刻返回（场景重载的中间态可能为空）；StaffSystem 用 get_node_or_null 取，
##   取不到时就退回显示 id 原文与元素名 "-"，保证面板点哪一行都不会中断游戏。
## 换杖 / 收杖时的屏幕提示。
##
## `game_ui._on_staff_picked()` 是用 `main.call("_show_staff_hint", id)` 调的 ——
## 这个函数在第 38 轮"整体移除法杖系统"时被删掉了，但那种**字符串形式**的调用
## 没被当时的检查脚本扫出来（它只扫 `xxx.method(` 的直接调用），
## 于是点装备面板里任何一行（包括"空手（收起法杖）"）都会抛
## `Invalid call. Nonexistent function '_show_staff_hint'` 并把游戏中断（用户实测）。
func _show_staff_hint(id: String) -> void:
	if ui == null:
		return
	var sys := get_node_or_null("/root/StaffSystem")
	if id == "":
		ui.show_interact_hint("法杖已收起")
	else:
		var nm := id
		var el := 0
		var el_name := "-"
		if sys != null:
			nm = str(sys.call("display_name", id))
			el = int(sys.call("element_of", id))
			el_name = str(sys.call("element_name", el))
		ui.show_interact_hint("%s · %s（Q / Shift+滚轮 换杖）" % [nm, el_name])
	_variant_hint_time = 1.6


## V 键的落点：把天气切到"下一个"并给出一条提示。
## 参数/返回值：无。副作用：Weather.set_weather(next, true)（强制生效）、写 UI 提示与
##   _variant_hint_time，最后打一行日志便于截图/日志核对。
## 顺序取自 Weather.KIND_NAMES 的键序（晴朗→多云→阴天→小雨→雷雨→大风），
## 用取模回绕，所以从"大风"再按 V 会回到"晴朗"。
## 注意：本函数不动 Weather.auto_change；自动天气之后仍可能继续变化。
func _cycle_weather() -> void:
	var n := Weather.KIND_NAMES.size()
	var next: int = (Weather.target + 1) % n
	Weather.set_weather(next, true)
	ui.show_interact_hint("天气：%s · 风力 %.2f · 风向 %s"
		% [Weather.weather_name(), Weather.wind, str(Weather.wind_dir)])
	_variant_hint_time = 1.6
	print("Weather | 手动切换 -> %s (wind=%.2f)" % [Weather.weather_name(), Weather.wind])





## 参数：无；返回值：无。
## 副作用：① 已在互动中 → 调用 player.stop_interact() 退出；
##   ② 否则在 INTERACT_RADIUS 内找最近可互动家具，找到就 player.start_interact(kind, pos, yaw, height)
##   —— 位置/朝向/坐高都由 vegetation 的家具登记数据提供（player 只是执行动画与定位）。
## 注意：附近没有可互动家具时**什么都不做**（不提示、不报错、不打断别的状态），
##   这是刻意的：E 键同时是"退出互动"键，空点一下不应该产生副作用。
## 调用时机：_unhandled_input() 的 E 键分支。
## 交互/退出交互：交互中按 E 退出；否则触发附近家具互动
func _try_interact() -> void:
	if player.is_interacting():
		player.stop_interact()
		return
	var it := vegetation.find_nearest_interactable(player.global_position, INTERACT_RADIUS)
	if not it.is_empty():
		player.start_interact(it.kind, it.pos, it.yaw, it.height)

## 参数：无；返回值：无。副作用：只写/清 UI 的互动提示文本（不改变互动状态本身）。
## 调用时机：_process() 里由 _hint_timer 节流调用（每 0.15s 一次），并且
##   在 _variant_hint_time > 0（正显示换杖/变体提示）时会被跳过，避免两行提示互相刷掉。
## 映射规则：kind == "sit" → 坐下、"sleep" → 睡觉、"climb" → 上梯子，
##   其余/未知 kind 一律显示"互动"（家具表新增种类时要在这里补动词，否则提示会很泛）。
## 更新家具互动提示（节流调用）
func _update_interact_hint() -> void:
	if player.is_interacting():
		ui.show_interact_hint("按 E 退出 · 移动/跳跃退出")
		return
	var it := vegetation.find_nearest_interactable(player.global_position, INTERACT_RADIUS)
	if it.is_empty():
		ui.clear_interact_hint()
		return
	var action := "互动"
	match it.kind:
		"sit":
			action = "坐下"
		"sleep":
			action = "睡觉"
		"climb":
			action = "上梯子"
	ui.show_interact_hint("按 E %s" % action)

# ==================== 十四、放置流程（取值 / 按下 / 笔刷 / 抬起 / 预览） ====================
## 参数：无；返回值：Variant —— 命中地面时是 Vector3（世界坐标），未命中/超出距离时是 **null**。
##   返回类型故意写成 Variant 而不是 Vector3：null 表示"这一帧没有有效落点"，
##   比用 Vector3.ZERO（原点本身是合法地面点）更不容易被误当成有效值。
## 副作用：无（只做一次射线查询，不改任何状态）。
## 注意：**所有调用点都必须先判 null**（_begin_tool / _paint_tree_stroke / _update_preview /
##   _update_place_preview 都判了），漏判会把物体放到世界原点或空指针崩溃。
## 用准星射线求地面放置点（返回 null 表示未命中或超出交互距离）
func _get_ground_pos() -> Variant:
	# **以鼠标为中心**（原来是屏幕正中准星）：俯视角 + 自由鼠标下，准星在屏幕中间
	# 根本指不到想放的地方。
	return camera_rig.get_ground_point_mouse(terrain)

## 左键按下：按当前工具分派"开始一次放置/操作"。
##
## 参数：无（读 Game.current_tool，落点来自 _get_ground_pos()）。返回值：无。
##
## 各分支副作用：
##   WALL            → 只记录起点并置 _is_dragging（真正的建墙在 _end_tool 松开时）；
##   TOWER/ROOF/TREE/FLOWER/DECOR/MOUNTAIN → 判占位 → 回收周围植被 → buildings/vegetation
##                     的 add_* 放置 → buildings.flush_all() → player.play_cast_gesture()；
##   TREE            额外进入笔刷状态（_tree_brush_active = true，之后拖动继续种）；
##   TERRAIN_RAISE/LOWER/FLATTEN → terrain.apply_brush(...) 并回收植被。
##
## 调用时机：_unhandled_input() 的鼠标左键按下分支。
##
## 注意（改这里前必看）：
##   * `_is_occupied(p)` 就是"幽灵变红"时对应的拦截：占位/离角色太近 → 整支 return，什么都不做；
##   * TREE 分支额外判 `buildings.tree_variant_count() == 0`：模型表为空时直接 return，
##     **不回收植被**（否则会出现"点一下树工具，草被吃掉了但没树"）；
##   * 各 add_* 之后必须 flush_all()，否则新模型要等下一次批量刷新才出现（体感"点了没反应"）；
##   * play_cast_gesture() 是统一的"操作成功"反馈，只有真正放置/刷地成功才调；
##   * TERRAIN_FLATTEN 用 `-brush_strength * 0.3`：平整比抬升/下陷温柔，是刻意的配比；
##   * 三个地形工具都是"点一次刷一次"，不进入 _is_dragging，所以按住拖动不会连刷。
func _begin_tool() -> void:
	var p: Variant = _get_ground_pos()
	if p == null:
		return
	match Game.current_tool:
		Game.Tool.WALL:
			_drag_start = p
			_is_dragging = true
		Game.Tool.TOWER:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			buildings.add_tower(p, tower_radius, tower_height, true, _place_yaw)
			buildings.flush_all()
			player.play_cast_gesture()
		Game.Tool.ROOF:
			# 屋顶工具：点击放置预制小屋模型
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			buildings.add_house(p, 1.0, _place_yaw, buildings.house_variant)
			buildings.flush_all()
			player.play_cast_gesture()
		Game.Tool.TREE:
			# TREE_MODELS 为空（等 Tripo 模型）时什么都不做，也不会误回收植被
			if buildings.tree_variant_count() == 0:
				return
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			# 传入滚轮选中的变体；Placement 与半透明预览保证是同一个模型
			# 不再额外抬高：重定位偏移已保证模型底面落在放置点上
			# 3.4：KayKit 树原生约 1.2~1.7m，乘完约 4~6m，与"树是角色 2.5~5 倍高"一致
			buildings.add_tree(p, 1.0, _place_yaw, _current_variant("tree"))
			# 进入"笔刷"状态：接下来拖动鼠标会沿笔迹继续种
			_tree_brush_active = true
			_tree_brush_count = 1
			_last_tree_pos = p
			player.play_cast_gesture()
		Game.Tool.FLOWER:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			# add_flower/add_furniture/add_mountain 返回的是**实际使用的变体下标**
			# （越界/未指定时由 vegetation 内部夹取，可能与请求的不同），所以要用返回值回写
			# _variant_sel：这样"预览里看到的模型"和"实际放下去的模型"永远一致。
			_set_used_variant("flower", vegetation.add_flower(p, 1.1, _place_yaw, _current_variant("flower")))
			player.play_cast_gesture()
		Game.Tool.DECOR:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			var cat := _tool_category(Game.current_tool)
			var vi := _current_variant(cat)
			# 楼梯同样生成模型碰撞（可走上去由自动抬步处理）
			_set_used_variant(cat, vegetation.add_furniture(p, 1.0, _place_yaw, true, vi))
			player.play_cast_gesture()
		Game.Tool.MOUNTAIN:
			if _is_occupied(p):
				return
			_recycle_vegetation(p, PLACE_RECYCLE_RADIUS)
			_set_used_variant("mountain", vegetation.add_mountain(p, 4.0, _place_yaw, _current_variant("mountain")))
			player.play_cast_gesture()
		Game.Tool.TERRAIN_RAISE:
			terrain.apply_brush(p, terrain.brush_radius, terrain.brush_strength)
			_recycle_vegetation(p)
		Game.Tool.TERRAIN_LOWER:
			terrain.apply_brush(p, terrain.brush_radius, -terrain.brush_strength)
			_recycle_vegetation(p)
		Game.Tool.TERRAIN_FLATTEN:
			terrain.apply_brush(p, terrain.brush_radius, -terrain.brush_strength * 0.3)
			_recycle_vegetation(p)

## 参数：
##   p —— 回收中心（世界坐标 Vector3）。
##   radius —— 回收半径（米）。**不传或传负数**表示"跟随地形笔刷"：
##     实际使用 terrain.brush_radius + 0.8（+0.8 是为了让笔刷边缘的植被也被清掉，不留一圈残株）。
## 返回值：无。
## 副作用：修改 Game.biomass 与 Game.stone 两个全局（它们带 setter，会自动 emit
##   biomass_changed / stone_changed → UI 余额即时刷新）。
## 注意：植被与石头是**分开记账**的（vegetation.recycle_around 返回 {"biomass","stone"}），
##   石头不会混进生物质；写 0 也要判断一次（> 0.0）避免发无意义的 UI 更新。
## 刷地/放置后回收范围内的植被：植被→生物质，石头→石材（UI 自动更新）
func _recycle_vegetation(p: Vector3, radius: float = -1.0) -> void:
	var r := terrain.brush_radius + 0.8 if radius < 0.0 else radius
	var got := vegetation.recycle_around(p, r)
	if got["biomass"] > 0.0:
		Game.biomass += got["biomass"]
	if got["stone"] > 0.0:
		Game.stone += got["stone"]


## 参数：无（落点从 _get_ground_pos() 取）；返回值：无。
## 副作用：向 buildings 添加一棵树、改 _last_tree_pos / _tree_brush_count，
##   并可能在"工具被切走 / 模型表为空"时把 _tree_brush_active 置 false（自动收笔）。
## 调用时机：_unhandled_input() 的鼠标移动分支，且 _tree_brush_active 为 true。
## 检查顺序（顺序有讲究，别随意调整）：
##   1) 不在笔刷中 → 走开；
##   2) 当前工具不是树、或树模型表为空 → **收笔退出**（这样切工具不会留下"半截笔画"）；
##   3) 已达 tree_brush_max_per_stroke → 本次不种（松手后计数才归零）；
##   4) 落点为空或距上一棵 < tree_brush_spacing → 继续等鼠标走；
##   5) 随机偏移点若被占位 → return，且**不推进** _last_tree_pos（鼠标挪个位置还能接着刷）。
## 随机偏移用 sqrt(randf()) * radius：保证落点在圆面内**面积均匀**（直接 randf() 会往圆心堆）。
## 树木笔刷：在鼠标当前位置种一棵（若离上一棵够远），带随机偏移/朝向/尺寸。
func _paint_tree_stroke() -> void:
	if not _tree_brush_active:
		return
	if Game.current_tool != Game.Tool.TREE or buildings.tree_variant_count() == 0:
		_tree_brush_active = false
		return
	if _tree_brush_count >= tree_brush_max_per_stroke:
		return
	var p: Variant = _get_ground_pos()
	if p == null:
		return
	var pp := p as Vector3
	if _last_tree_pos != Vector3.INF and pp.distance_to(_last_tree_pos) < tree_brush_spacing:
		return                      # 还没走够间距，等鼠标再走一点
	# 在放置点周围抖一下，避免排成一条直线
	var ang := randf() * TAU
	var rad := sqrt(randf()) * tree_brush_radius
	var q := pp + Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
	q.y = terrain.get_height_at(q.x, q.z)
	if _is_occupied(q):
		return
	_recycle_vegetation(q, PLACE_RECYCLE_RADIUS)
	var sc := 1.0 + randf_range(-tree_brush_scale_jitter, tree_brush_scale_jitter)
	var yaw := randf() * 360.0
	buildings.add_tree(q, sc, yaw, _current_variant("tree"))
	_last_tree_pos = pp
	_tree_brush_count += 1

## 左键松开：先收树木笔刷，再结束拖拽并按工具"落地"。
##
## 参数：无。返回值：无。
##
## 副作用：
##   * 收笔：清 _tree_brush_active、_last_tree_pos，buildings.flush_all()，打印本次笔画棵数并清零；
##   * 清 _is_dragging 并隐藏 preview_wall / preview_roof；
##   * 若工具是 WALL 且起终点距离 > 0.5m：buildings.add_wall(起点, 终点, wall_height,
##     wall_thickness, false) → flush_all() → play_cast_gesture() → 在起点和终点各回收一次植被。
##
## 调用时机：_unhandled_input() 的鼠标左键松开分支。
##
## 注意：
##   * **收笔与拖拽是两件独立的事**，必须像现在这样"先无条件收笔，再判断 _is_dragging"：
##     种树走的是单点 + 笔刷，_is_dragging 一直是 false，反过来写就永远收不了笔。
##   * 0.5m 的距离下限是防"手抖点一下就冒出一堵墙"（也顺带挡掉零长度墙）。
##   * ROOF 在下面的 match 里没有分支（`_:` 直接 pass）：拖拽屋顶只做预览，不落地；
##     真正放房子走的是 ROOF 的单点放置分支（见 _begin_tool）。
func _end_tool() -> void:
	# 收笔：无论是否拖动过，都要退出笔刷状态
	if _tree_brush_active:
		_tree_brush_active = false
		_last_tree_pos = Vector3.INF
		buildings.flush_all()
		print("TreeBrush | 本次笔画种了 %d 棵树" % _tree_brush_count)
		_tree_brush_count = 0
	if not _is_dragging:
		return
	_is_dragging = false
	preview_wall.visible = false
	preview_roof.visible = false
	var end: Variant = _get_ground_pos()
	if end == null:
		return
	match Game.current_tool:
		Game.Tool.WALL:
			if _drag_start.distance_to(end) > 0.5:
				buildings.add_wall(_drag_start, end, wall_height, wall_thickness, false)
				buildings.flush_all()
				player.play_cast_gesture()
				_recycle_vegetation(_drag_start, PLACE_RECYCLE_RADIUS)
				_recycle_vegetation(end, PLACE_RECYCLE_RADIUS)
		_:
			pass

## 拖拽过程中重建过程预览网格（鼠标移动时每帧/每物理帧调一次）。
##
## 参数：无（起点用 _drag_start，终点用 _get_ground_pos()）。返回值：无。
## 副作用：写 preview_wall.mesh / preview_roof.mesh 与两者的 visible；
##   **每帧 new 一个 ArrayMesh**（只在拖拽期间发生，属于可接受的开销）。
## 时机：_process 与 _physics_process 里各有一处调用（幂等，重复算一次而已）。
## 注意：
##   * 落点为空（拖出地图/超出交互距离）时把两个预览都隐藏并返回；
##   * WALL 与 ROOF 两个分支都会把"另一个"预览关掉 —— 它们同一时刻只应有一个可见；
##   * 若 ProceduralMesh 返回空几何（例如起终点几乎重合），本函数**不会**显式隐藏对应预览，
##     于是会保留上一帧的网格（推测：观感上就是"没变化"，不是 bug）。
func _update_preview() -> void:
	if not _is_dragging:
		return
	var p: Variant = _get_ground_pos()
	if p == null:
		preview_wall.visible = false
		preview_roof.visible = false
		return
	match Game.current_tool:
		Game.Tool.WALL:
			var geom := ProceduralMesh.build_wall(_drag_start, p, wall_height, wall_thickness, 0.0)
			if not geom.is_empty():
				var arrays := ProceduralMesh.arrays_to_surface(geom)
				if not arrays.is_empty():
					var mesh := ArrayMesh.new()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
					preview_wall.mesh = mesh
					preview_wall.visible = true
			preview_roof.visible = false
		Game.Tool.ROOF:
			var geom := ProceduralMesh.build_gable_roof(_drag_start, p, roof_width, roof_ridge, roof_eave)
			if not geom.is_empty():
				var arrays := ProceduralMesh.arrays_to_surface(geom)
				if not arrays.is_empty():
					var mesh := ArrayMesh.new()
					mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
					preview_roof.mesh = mesh
					preview_roof.visible = true
			preview_wall.visible = false

## 参数：无（落点=_get_ground_pos()，占位判定=_is_occupied()）。返回值：无。
## 副作用：写 preview_place 的 visible/global_position/rotation，并逐个改子节点的
##   visible 与 material_override（**不改**任何世界数据）。
## 时机：_process() 每帧一次（选中单点放置工具时）。
## 注意：
##   * _is_occupied() 每帧都会 new 一个 CylinderShape3D 并做一次 physics shape 查询 ——
##     这是"每帧一次物理查询"的固定开销，只有选中单点工具时才付，别挪到无条件路径上。
##   * 子节点可见性按名字匹配 _place_node_name()（当前工具只显示对应那一个），
##     所以新增预览模型时必须同步更新 _place_node_name()，否则永远不显示。
##   * 首行 `not Game.current_tool in _place_tools` 依赖 GDScript 里 `in` 优先级高于 `not`，
##     等价于 `not (current_tool in _place_tools)`；改写时别把语义弄反。
## 单点放置工具的目标点半透明预览：每帧跟随准星，绿=可放置，红=建筑占位
func _update_place_preview() -> void:
	if not Game.current_tool in _place_tools:
		preview_place.visible = false
		return
	var p: Variant = _get_ground_pos()
	if p == null:
		preview_place.visible = false
		return
	preview_place.visible = true
	preview_place.global_position = Vector3(p.x, p.y, p.z)
	preview_place.rotation = Vector3(0, _place_yaw, 0)
	var mat := PREVIEW_PLACE_BLOCKED if _is_occupied(p) else PREVIEW_PLACE_OK
	var want := _place_node_name(Game.current_tool)
	for child in preview_place.get_children():
		child.visible = (str(child.name) == want)
		_apply_place_material(child, mat)

# ==================== 十五、工具 ↔ 分类 ↔ 模型变体 ====================
## 参数：tool —— Game.Tool 枚举值（int）。返回值：分类名字符串，**空串 "" = 该工具没有多变体**。
## 映射：TREE→"tree"、FLOWER→"flower"、DECOR→"furniture"、MOUNTAIN→"mountain"，
##   其余（WALL/TOWER/ROOF/TERRAIN_*/PATH/ERASE/NONE）→ ""。
## 副作用：无（纯函数）。
## 注意：
##   * 家具的分类名是 "furniture"、而工具名是 DECOR —— 两者不同名，字符串写错会静默退化成
##     "该工具只有一种模型"（不报错），排查时先核对这里的字符串。
##   * ROOF（房屋）**不在**这张表里：房屋走 building_manager 自己的房屋变体表
##     （见 _cycle_variant 开头的特殊分支），与 vegetation 的分类无关。
## 工具 → 植被分类（无多模型可切换的工具返回空串）
func _tool_category(tool: int) -> String:
	match tool:
		Game.Tool.TREE:
			return "tree"
		Game.Tool.FLOWER:
			return "flower"
		Game.Tool.DECOR:
			return "furniture"
		Game.Tool.MOUNTAIN:
			return "mountain"
	return ""


## 参数：cat —— 分类名（同 _tool_category 的返回值）。返回值：
##   -1  → 该分类没有多变体（category_variant_count(cat) <= 1）。**-1 会被原样传给 add_*，
##         在 vegetation 里表示"不指定变体、随机选一个"**（见 _add_instance 的 force_variant 判断），
##         所以一片植被看起来是自然混杂的，而不是全都同一个模型。
##   0..n-1 → 当前选中的合法下标（滚轮切换的结果）。
## 副作用：下标越界（例如模型表被改短了）时把它夹回 0 并写回 _variant_sel。
## 注意：这里查的是**分类**级状态（_variant_sel 以分类为 key），不是"每个工具一份"——
##   所以"树木"与"花草"各记一份选择，切回同类工具时会保留上次选的模型。
## 当前选中的变体下标（越界自动夹回；无多模型时返回 -1）
func _current_variant(cat: String) -> int:
	var n := vegetation.category_variant_count(cat)
	if n <= 1:
		return -1
	var vi := int(_variant_sel.get(cat, 0))
	if vi < 0 or vi >= n:
		vi = 0
		_variant_sel[cat] = vi
	return vi


## 参数：cat —— 分类名；used —— add_* 返回的**实际**变体下标。
## 返回值：无。副作用：写 _variant_sel[cat]（**前提是 used >= 0**）。
## 为什么要这一步：滚轮选中的变体与 vegetation 内部最终采用的可能不同
##   （传入 -1 表示"随机选一个"、传入越界下标会被内部夹取），
##   用返回值对齐后，预览里显示的模型就是下一次会放下去的那个模型。
## 注意：used < 0（放置失败）时**不覆盖**原选择，避免把玩家的选择清成无效值。
## 放置成功后把实际使用的变体记为当前选择（理论上与预览一致，这里兜底对齐）
func _set_used_variant(cat: String, used: int) -> void:
	if used >= 0:
		_variant_sel[cat] = used


## 参数：dir —— +1 = 下一个模型，-1 = 上一个（**不要传 0**：posmod(x+0, n) 会原地不动还闪提示）。
## 返回值：无。
## 副作用：写 _variant_sel[cat]（经 _current_variant/_set_place_preview_mesh 间接）、
##   可能改 buildings 的房屋变体选择、刷新预览网格、写 UI 提示与 _variant_hint_time。
## 分支：ROOF 走 building_manager 的房屋表（含换预览与"房屋 i/n"，与植被分类无关）；
##   其余分类走 vegetation 的分类变体表；没有多变体时只给一句提示、不改任何状态。
## 注意：`posmod(_current_variant(cat) + dir, n)` 必须用 posmod 而不是 `%` ——
##   GDScript 的 % 对负数返回负数，dir=-1 且当前为 0 时会得到 -1 这种非法下标。
## 滚轮切换：dir=+1 下一个模型，-1 上一个；只有一个模型时给出提示
func _cycle_variant(dir: int) -> void:
	# 房屋工具用的是 building_manager 自己的房屋表，不归植被分类管
	if Game.current_tool == Game.Tool.ROOF:
		var hi := buildings.cycle_house_variant(dir)
		_update_house_preview()
		ui.show_interact_hint("房屋 %d/%d · %s" % [hi + 1,
				buildings.house_variant_count(), buildings.house_variant_name()])
		_variant_hint_time = 1.6
		return
	var cat := _tool_category(Game.current_tool)
	if cat.is_empty():
		ui.show_interact_hint("该工具只有一种模型")
		_variant_hint_time = 1.2
		return
	var n := vegetation.category_variant_count(cat)
	if n <= 1:
		ui.show_interact_hint("该工具只有一种模型")
		_variant_hint_time = 1.2
		return
	var vi := posmod(_current_variant(cat) + dir, n)
	_variant_sel[cat] = vi
	_set_place_preview_mesh(cat)
	ui.show_interact_hint("模型 %d/%d · %s" % [vi + 1, n, _model_basename(cat, vi)])
	_variant_hint_time = 1.6


# ==================== 十六、预览网格装配与模型提取工具 ====================
## 参数：parent —— 挂载父节点（这里是 preview_place）；node_name —— 新建 MeshInstance3D 的名字
##   （必须与 _place_node_name() 返回的名字一致，否则永远不会显示）；
##   cat —— 植被分类名；scale —— 模型基准缩放（倍，非米）。
## 返回值：无。副作用：向 parent add_child 一个 MeshInstance3D。
## 注意：只取分类的**第 0 个**模型当预览（花只有一个变体，够用）；路径为空时**直接 return**，
##   这个判空是必须的 —— 分类表为空时会拼出 load("")，启动期会报 `Resource file not found: res://`。
## 建一个"真实模型半透明"的放置预览。分类表为空（植物已移除）时**不建**，
## 免得 `load("")` 报 res:// 找不到。
func _add_plant_preview(parent: Node3D, node_name: String, cat: String, scale: float) -> void:
	var path := vegetation.category_model_path(cat, 0)
	if path.is_empty():
		return
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = _extract_mesh(load(path))
	mi.scale = Vector3.ONE * scale
	parent.add_child(mi)

## 参数：cat —— 分类名；variant —— 变体下标（0 起，越界由 vegetation 用 posmod 环绕）。
## 返回值：String —— 去掉目录与扩展名的模型文件名（用于"模型 2/4 · Tree_03"这类提示）。
## 副作用：无。
## 注意：底层 category_model_path() 用的是 `posmod(variant, size)`，因此**传 -1 会得到最后一个
##   模型**（posmod(-1,n) == n-1），不要把 -1 理解成"第一个"。
## 按分类取模型文件名（不含扩展名），用于提示
func _model_basename(cat: String, variant: int) -> String:
	return vegetation.category_model_path(cat, variant).get_file().get_basename()


## 参数：无（读 buildings.house_scene_at() 与 buildings.house_base_scale()）。返回值：无。
## 副作用：改 preview_place 下 "HousePreview" 节点的 mesh / scale / material_override。
## 注意：`house_scene_at()` 返回 null（房屋变体表为空）时**直接 return**，保留旧网格 ——
##   这样点滚轮不会把预览清成空网格（观感上像"预览突然消失"）。
## 把预览网格换成当前变体的真实模型（保留场景里那套半透明材质）
## 换房屋变体后立刻换预览网格（半透明材质与缩放都要跟着换）
func _update_house_preview() -> void:
	var node := preview_place.get_node_or_null("HousePreview") as MeshInstance3D
	if node == null:
		return
	var sc := buildings.house_scene_at()
	if sc == null:
		return
	var mesh := _extract_mesh_merged(sc)
	if mesh != null:
		node.mesh = mesh
	node.scale = Vector3.ONE * buildings.house_base_scale()
	_apply_place_material(node, PREVIEW_PLACE_OK)


## 滚轮换模型后，把当前工具的预览网格换成新变体的真实模型，并恢复材质/偏移/基准缩放。
##
## 参数：cat —— 分类名（由 _tool_category 得到，房屋不走这里）。返回值：无。
## 副作用：写预览节点的 mesh / scale / material_override，并经 _apply_preview_offset 改 position。
## 注意：
##   * 预览节点按名字取（_preview_for_tool → _place_node_name），名字对不上就直接 return（静默）；
##   * `mesh == null`（分类表为空）时**不清空**旧网格，保持上一帧的样子；
##   * `base <= 0.0`（未知分类）时**不动** scale，避免把预览缩成 0；
##   * 这里既直接赋 material_override 又调用 _apply_place_material()，看起来冗余 ——
##     前者保证本节点立刻是半透明，后者递归覆盖子树（树预览将来若改成容器节点就靠它）（推测）。
func _set_place_preview_mesh(cat: String) -> void:
	var node := _preview_for_tool(Game.current_tool)
	if node == null:
		return
	_apply_preview_offset(node, cat)
	var mesh: Mesh = vegetation.category_model_mesh(cat, _current_variant(cat))
	if mesh != null:
		node.mesh = mesh
	var base := _preview_base_scale_for(cat)
	if base > 0.0:
		node.scale = Vector3.ONE * base
	# 换模型后立刻把半透明材质挂回去，不等下一帧的落点更新
	node.material_override = PREVIEW_PLACE_OK
	_apply_place_material(node, PREVIEW_PLACE_OK)


## 参数：cat —— 分类名。返回值：该分类模型的基准缩放（倍）；
##   **-1.0 表示"未知分类"** —— 调用方 _set_place_preview_mesh 拿它当"不要动 scale"的哨兵，
##   所以这里不能返回 0.0（0 会把预览缩成看不见）。
## 副作用：无（纯查表，不读节点）。
## 预览缩放：分类基准缩放。
##
## 原来这里有一句 `if vegetation.is_plant_extra(...): return 1.0` —— 植物系统整体移除时
## 那个函数被删了，但这句调用漏了。后果：**任何放置工具滚轮换模型时都会抛
## "Invalid call. Nonexistent function 'is_plant_extra'"**，在编辑器里直接中断游戏
## （用户反馈的"放置家具时程序中断"）。植物以后要重做的话，这条分支应该加回来，
## 但判据要换成"这个模型是不是按真实尺寸建的"（可以查分类表的 base_scale），
## 不要再依赖植物专属接口。
func _preview_base_scale_for(cat: String) -> float:
	match cat:
		"tree": return 1.0
		"flower": return 1.1
		"furniture": return 1.0
		"mountain": return 4.0
	return -1.0


## 参数：node —— 预览用的 MeshInstance3D；cat —— 分类名（空串直接返回）。
## 返回值：无。副作用：**写 node.position**（只改位置，不动 scale / 材质 / 层级）。
## 注意：
##   * variants <= 0 或模型路径为空时直接返回，保持默认偏移（0）；
##   * `_current_variant(cat)` 在"没有多变体"时返回 -1，而 vegetation.category_model_path()
##     内部是 posmod(-1, n) → 取到**最后一个**模型；即单变体分类下这里查的是末位模型的偏移
##     （推测：这些模型的偏移相同或差异可忽略，所以一直没暴露成问题）。
## 预览也要用与放置相同的重定位偏移，否则点下去模型会"跳"（ghost 与实物不一致）
## offset 在模型局部空间；预览父节点已按 _place_yaw 旋转，故无需再转。
func _apply_preview_offset(node: MeshInstance3D, cat: String) -> void:
	if cat.is_empty():
		return
	var variants := _tool_variant_count(cat)
	if variants <= 0:
		return
	var path := vegetation.category_model_path(cat, _current_variant(cat))
	if path.is_empty():
		return
	# 与放置完全同一个偏移（含底面抬升），否则模型底边会与预览差一点
	node.position = vegetation.model_preview_offset(path)


## 参数：cat —— 分类名。返回值：该分类可用的模型数量（0 = 没有变体）。
## 副作用：无。它只是 vegetation.category_variant_count() 的一层薄包装
##   （推测：留一层间接，便于以后在这里加"按画质档位过滤模型"之类的逻辑）。
## 某分类的模型数量（无多变体时为 0）
func _tool_variant_count(cat: String) -> int:
	return vegetation.category_variant_count(cat)


## 参数：tool —— Game.Tool 值。返回值：对应的 MeshInstance3D，**取不到时返回 null**。
## 副作用：无（只查节点）。
## 注意：用 get_node_or_null 而不是 get_node：工具与预览节点不同步（新增了工具却没建预览节点、
##   或名字写错）时只会返回 null 让调用方提前返回，而不是抛错中断游戏。
## 取某工具对应的预览 MeshInstance3D（预览节点结构在场景中）
func _preview_for_tool(tool: int) -> MeshInstance3D:
	return preview_place.get_node_or_null(_place_node_name(tool)) as MeshInstance3D


## 工具 → preview_place 子节点名字 的映射（纯查表）。
##
## 参数：tool —— Game.Tool 值。返回值：节点名（"TowerPreview" / "HousePreview" / "TreePreview" /
##   "FlowerPreview" / "FurniturePreview" / "MountainPreview"）；**未列出的工具返回空串 ""**，
##   于是 get_node_or_null("") 取不到节点 → 调用方安全跳过（不报错）。
##
## 副作用：无。
## ⚠ 这些名字必须与 _setup_previews() 里 `xxx_mi.name = "..."` 完全一致：
##   改一处而没改另一处时，表现是"预览静默消失"（没有任何报错），排查成本很高。
func _place_node_name(tool: int) -> String:
	match tool:
		Game.Tool.TOWER:
			return "TowerPreview"
		Game.Tool.ROOF:
			return "HousePreview"
		Game.Tool.TREE:
			return "TreePreview"
		Game.Tool.FLOWER:
			return "FlowerPreview"
		Game.Tool.DECOR:
			return "FurniturePreview"
		Game.Tool.MOUNTAIN:
			return "MountainPreview"
	return ""

## 参数：node —— 任意 Node（**不要求是 MeshInstance3D**，非网格节点会被跳过但子节点仍递归）；
##   mat —— 材质，形参类型是 **StandardMaterial3D**（四个预览材质都符合；传其它类型会类型不匹配）。
## 返回值：无。副作用：递归写所有 MeshInstance3D 的 material_override（覆盖原有材质）。
## 注意：递归没有深度上限，但预览子树很浅（一级子节点），开销可忽略；
##   由于只写 material_override，材质资源本身没有被修改，所以四个共享材质是安全的。
## 递归设置预览材质（树预览是 MeshInstance3D 或 Node3D 容器）
func _apply_place_material(node: Node, mat: StandardMaterial3D) -> void:
	if node is MeshInstance3D:
		node.material_override = mat
	for c in node.get_children():
		_apply_place_material(c, mat)

## 从场景提取第一个 MeshInstance3D 的 Mesh（用于真实模型半透明预览）
## 参数：scene —— 源 PackedScene（传 null 直接返回 null）。
## 返回值：把整棵子树的网格烘焙到同一坐标系后合并成的 Mesh；**一个网格都没有时返回 null**。
## 副作用：instantiate() 一次场景，结束时 inst.free()（未入树、立即释放）；并把结果写进缓存。
## 注意：
##   * 缓存 key 是 scene.resource_path —— 运行时构造/内嵌场景的 resource_path 是空串，
##     此时**故意不缓存**，否则所有"无名场景"会共用同一份网格。
##   * 合并走 SurfaceTool.append_from：顶点/UV/法线保留，但**材质不保留** ——
##     需要材质的地方必须自己补（见 _setup_previews 里 TreePreview 的"白树"修复）。
## 把整棵子树的网格合并成一个（**预览用**）。
##
## `_extract_mesh()` 只取**第一个**子网格：KayKit 的房子整栋就是一个网格，所以一直没问题；
## 自制茅草屋有 205 个部件，只取第一个的话预览里就显示成一个木桶（用户实测反馈"预览怎么是个桶"）。
## 合并结果缓存：key = PackedScene 的 resource_path。
## 茅草屋有 213 个部件、GLB 31MB，滚轮切换时每次都重新合并会明显卡一下（用户实测）。
var _merged_mesh_cache := {}


## 参数：scene —— 源 PackedScene。返回值：合并后的 Mesh（无网格时为 null）。副作用：见上方说明
##   （实例化一次并 free；结果写入 _merged_mesh_cache）。
func _extract_mesh_merged(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var key := scene.resource_path
	if not key.is_empty() and _merged_mesh_cache.has(key):
		return _merged_mesh_cache[key]
	var inst := scene.instantiate()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := _transform_relative_to(mi, inst)
		for s in mi.mesh.get_surface_count():
			st.append_from(mi.mesh, s, xf)
			any = true
	inst.free()
	var merged: Mesh = st.commit() if any else null
	if not key.is_empty():
		_merged_mesh_cache[key] = merged
	return merged


## 参数：node —— 起点 Node3D；root —— 参照根节点（父链走到 root 即停）。
## 返回值：node 相对 root 的累积 Transform3D（root 不在父链上时会一直乘到树顶）。
## 副作用：无（纯计算，不写节点）。
## 为什么不直接用 global_transform：这些场景是 instantiate() 出来、**还没入树**的，
##   global_transform 在这种状态下是惰性/不可靠的（历史坑：加载时读它得到假数据）；
##   手工沿父链累乘才是确定性的。注意乘法顺序是 `父变换 * 累积`，反过来会得到错误的旋转。
## node 相对 root 的局部累积变换（不用 global_transform：那是惰性求值的）
func _transform_relative_to(node: Node3D, root: Node) -> Transform3D:
	var xf := Transform3D()
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


## 参数：scene —— 源 PackedScene（null 直接返回 null）。返回值：第一个 MeshInstance3D 的 Mesh；
##   整棵树里没有网格时返回 **null**（调用方把它赋给 mesh 只是不渲染，不会报错）。
## 副作用：instantiate() 一个临时场景并立刻 free()（未入树，安全）。
## 注意："只取第一个网格"对 KayKit 那种单网格模型够用，但对多部件模型会只显示一个部件
##   （历史上茅草屋 205 个部件 → 预览里只出现一个木桶），那种情况必须改用 _extract_mesh_merged()。
func _extract_mesh(scene: PackedScene) -> Mesh:
	if scene == null:
		return null
	var inst := scene.instantiate()
	var m := _find_first_mesh(inst)
	inst.free()
	return m

## 深度优先找子树里第一个 MeshInstance3D 的 Mesh。
##
## 参数：node —— 起点节点（可以是任意 Node）。返回值：第一个 Mesh；找不到返回 null。
## 副作用：无。注意：**只返回 Mesh 引用，不返回节点本身**，所以调用方拿不到那个节点的
##   变换/材质 —— 需要它们时要用 _extract_mesh_merged() 或自己遍历。
func _find_first_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return node.mesh
	for c in node.get_children():
		var m := _find_first_mesh(c)
		if m != null:
			return m
	return null

## 参数：p —— 待放置点（世界坐标）。返回值：true = **不允许放置**（建筑占位 或 离角色太近）。
## 副作用：做一次只读的物理 shape 查询（不改世界、不建节点）。
## 注意：
##   * `collision_mask = 4` 是第 3 位（1<<2）＝建筑层：玩家造的墙/塔/屋在这一层，
##     角色/植被不在，所以"离角色太近"要靠后面那段水平距离检查单独兜底。
##   * 圆柱中心要抬高半个高度（`p + Vector3(0, PLACE_OCCUPY_HEIGHT * 0.5, 0)`）——
##     CylinderShape3D 以**中心**为原点，不抬这半高的话检测体一半埋在地下，
##     贴地的矮几何（台阶、地基）就查不到；这是"看起来多余但必需"的一行。
## 占位检测：目标点半径内是否有建筑（玩家创建的墙/塔/屋，层4）。
## 小植被（树/石/草/花/蘑菇/灌木）不占位，放置时自动回收为生物质/石材。
func _is_occupied(p: Vector3) -> bool:
	# 只查"贴地那一圈"的**矮圆柱**。原实现是球体，屋檐 / 树冠这些**悬在上方**的
	# 几何也会被算成占位 -> 墙根下、大树下都放不了花草（用户实测就是这个）。
	var space := get_world_3d().direct_space_state
	var params := PhysicsShapeQueryParameters3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = PLACE_OCCUPY_RADIUS
	shape.height = PLACE_OCCUPY_HEIGHT
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY,
			p + Vector3(0, PLACE_OCCUPY_HEIGHT * 0.5, 0))
	params.collision_mask = 4
	var hits := space.intersect_shape(params, 8)
	if not hits.is_empty():
		return true
	# 与角色自身碰撞：会插进身体的不允许放置
	if player != null:
		var d := Vector2(p.x - player.global_position.x,
				p.z - player.global_position.z).length()
		if d < PLACE_PLAYER_CLEAR:
			return true
	return false

# ==================== 十七、对外 UI 回调（工具栏 / 撤销） ====================
## 参数：tool —— Game.Tool 枚举值（由 game_ui 的工具栏点击传入）。返回值：无。
## 副作用：
##   ① 写 Game.current_tool —— 它的 setter 会 emit tool_changed，其它系统/UI 据此同步；
##   ② 清理"上一次操作的中间态"：_is_dragging = false（取消未完成的拖拽）、_place_yaw = 0、
##      隐藏 preview_wall / preview_roof / preview_place（未放置的半透明幽灵立刻消失）；
##   ③ 不碰 Game.biomass / stone，也不动建筑数据。
## 注意：结尾连着写了三次 preview_place.visible = false（其中一次在 not in _place_tools 分支里），
##   属于冗余但无害；真实语义是"换工具先一律藏起来，显示由 _update_place_preview 下一帧决定"。
## UI 回调：切换工具
func set_tool(tool: int) -> void:
	Game.current_tool = tool
	# 关掉创建菜单回滚工具时，半透明预览也要立刻消失（"销毁还没放置的物品"）
	if not (tool in _place_tools):
		preview_place.visible = false
	_is_dragging = false
	_place_yaw = 0.0
	preview_wall.visible = false
	preview_roof.visible = false
	preview_place.visible = false

## 参数：无。返回值：无。副作用：转发给 BuildingManager.undo()（真正做的是回滚最后一批放置物，
##   由 buildings 维护历史栈）；本函数不判断成败、不弹提示、不回收资源。
## 注意：键盘路径（Ctrl+Z）在 _unhandled_input() 里**直接调** buildings.undo()，不经过本函数；
##   本函数是给 UI 按钮/其它脚本用的入口，两条路最终落到同一个实现。
## UI 回调：撤销
func undo() -> void:
	buildings.undo()

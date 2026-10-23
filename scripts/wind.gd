class_name WindSystem
extends Node
## 草的风 + 交互桥（**场景内实例化节点**：scenes/main.tscn 的 "Main" 下挂着一个名为 "WindSystem" 的
## Node，脚本 = res://scripts/wind.gd；**不再是 autoload**）。
##
## 统一管理三种草：
##   1) 本插件导出的草      -> blend_alpha.gdshader    （uniform: wind_* / player_*）
##   2) SimpleGrassTextured -> grass.gdshaderinc       （uniform: sgt_wind_* / sgt_player_*）
##   3) 植被（树/灌木）      -> 由 Weather 自己驱动，本脚本不碰
##
## ★★ 为什么全部走「逐材质 uniform」，而不用全局着色器参数 ★★
##   scripts/world/weather.gd L191-194 与 assets/shaders/vegetation_wind.gdshader L14 已实测写明：
##   Godot 4.7 运行时下 RenderingServer.global_shader_parameter_* 是坏的 ——
##   get_list() 恒为空、set() 被静默忽略、顶点阶段永远拿 project.godot 的默认值。
##
## ★★ 为什么本脚本自己写风参数，而不是只挂给 Weather ★★
##   Weather.bind_world() 里有 _wind_materials.clear()（weather.gd L100），
##   而 main.gd 是「世界搭好之后」才调 bind_world 的 —— 早先注册进去的草材质会被清掉，
##   表现就是「按 V 换天气，草一点反应都没有」。所以这里每帧自己写，不依赖那个列表。
##
## ★★ 2026-10-08 修复：SGT 草不受风 ✗ ★★
##   材质收集原来只判 `n is MeshInstance3D` ✓
##   但 **MultiMeshInstance3D 不是 MeshInstance3D 的子类** ✗（Godot 4 两条独立继承链）
##   → SimpleGrassTextured 的整片草从来没被收进 _mats_sgt ✓
##   → _write_sgt() 里 `if _mats_sgt.is_empty(): return` 每帧直接返回 ✗
##   → 表现：「simplegrass 的草不受风力影响」✓
##   现在补了 `elif n is MultiMeshInstance3D` → _take_from_multimesh() ✓
##   注意该分支**不能**用 MeshInstance3D 的 API ✗（MultiMeshInstance3D 没有
##   `mesh` 属性 ✓ 网格在 `multimesh.mesh`；也没有 `get_surface_override_material()` ✓）
##
## ★★ 倒伏只由「移动」驱动 ★★
##   站着不动时 player_move = 0 -> 草自动回弹，不会出现「出生点周围一圈草一直倒着」。
##
## ★★ 系统归属与运行形态 ★★
##   · 宿主：**场景内实例化节点** —— scenes/main.tscn 的 "Main"（Node3D）下有一个
##     名为 "WindSystem" 的 Node（脚本 = 本文件）。project.godot 的 [autoload] 里**没有** Wind。
##     -> 后果（也是这次改造的目的）：@export 参数在 Inspector 里**看得见、改得动**。
##   · 取用口：静态 `WindSystem.get_instance()`；_ready() 里 add_to_group("wind_system") 登记，
##     _exit_tree() 里注销。别的脚本取风的推荐顺序见 get_instance() 上方的注释。
##   · 所属系统：世界表现层（风 / 草 / 植被 / 角色与草的交互），与 scripts/world/weather.gd 配套。
##   · 天气来源：优先读**当前场景**里名为 "Weather" 的节点
##     （main.tscn 的 Main/Weather；wind / wind_gust / wind_turbulence / wind_speed / wind_dir），
##     其次 /root/Weather（旧 autoload 兼容）与分组 weather_system；
##     都读不到就用自己的 fallback_* 兜底（见 _apply_from_weather / _apply_fallback）。
##
## ★★ 关键依赖（下面这些是硬编码的路径 / 节点名 / 分组名，改名会静默失效）★★
##   · res://scripts/world/weather.gd                       —— 风参数来源，场景节点名必须叫 "Weather"
##   · res://scripts/foot_ring.gd                           —— 按需 new() 出实体脚底圈，节点名 "FootRing"
##   · res://assets/shaders/grass_wind.gdshader（旧名 blend_alpha.gdshader）—— 自研草着色器
##   · res://addons/simplegrasstextured/shaders/grass.gdshaderinc          —— SGT 草着色器
##   · res://assets/shaders/tree_leaves_burn*.gdshader / tree_burn_keep*.gdshader —— 燃烧后的树叶 / 木（见 _register）
##   · 节点 "/root/SimpleGrass"                             —— 可选，读它的 player_position
##   · 分组 "player"                                        —— 玩家查找的权威依据（见 _find_player）
##   · 分组 "wind_system"                                   —— 本节点的取用登记（见 get_instance / _ready）
##
## ★★ 主要对外接口（别的脚本 / VFX 会用到）★★
##   · cur_dir / cur_strength / cur_gust / cur_turbulence / cur_speed
##       每次写材质前更新的「当前风」，火焰等 VFX 直接读，不必再去翻材质
##   · snap_player_to_nearest_grass() -> bool
##       调试用：把玩家水平挪到最近一株 SGT 草上（只改 x/z，不动 y）
##   · _on_viewport_size_changed()
##       Viewport.size_changed 的槽：窗口一变就立刻重算屏幕量并重写**全部** SGT 材质
##   · 内部主要环节：_scan（收集材质）/ _write_ours / _write_sgt / _apply_sgt_occlusion / _update_height_gate
##
## ★★ 已知的坑（改这个文件之前请先扫一眼）★★
##   · 不要改成「写全局着色器参数」：Godot 4.7 下 global_shader_parameter_* 是坏的（见上）
##   · 不要依赖 Weather._wind_materials：bind_world() 里有 clear()，早注册的材质会丢（见上）
##   · MultiMeshInstance3D **不是** MeshInstance3D 的子类，两条分支的 API 不能混用（见 _scan）
##   · get_instance() 只在节点**在树里**时有效：_exit_tree 会清空静态引用，别缓存过时的指针
##   · 屏幕坐标有**两套尺寸**（视口逻辑 vs 帧缓冲真实像素），只存一套轮廓就会画到错误位置
##   · _scan() 每 scan_interval 秒重跑一次，任何跨帧缓存都必须先 clear()，否则会重复累积
##   · 高度闸门的目标值只有 0/1，必须平滑之后才能写材质，否则起跳 / 落地会「啪」地弹（见 _update_height_gate）
##   · 所有 uniform 名都是硬编码字符串：写错的 uniform 是**无害但静默**的（不会报错，也不会有任何效果）
##
## ★ 渲染阶段的性能约定：逐材质写 uniform 只在 _process 里做一次 / 帧；
##   _apply_sgt_occlusion() 例外（resize 时要能立刻重写全部材质）。

# ==================== 单例取用口（场景实例版） ====================

## 当前场景里的 WindSystem 实例：_ready() 登记、_exit_tree() 注销。
## ⚠ 只在节点**在树里**时非空；跨场景切换后旧引用会被清掉，不要把它缓存进别的脚本的成员变量。
static var _instance: WindSystem


## 取当前场景的 WindSystem；场景里没有（例如纯特效预览场景）时返回 null，调用方必须判空。
## 其它脚本读风参数时建议按这个顺序找（**任何一步失败都静默跳过，不许报错**）：
##   1) WindSystem.get_instance()
##   2) get_tree().get_first_node_in_group("wind_system")
##   3) 旧路径 get_node_or_null("/root/Wind")（去 autoload 之前的兼容回退）
static func get_instance() -> WindSystem:
	if _instance != null and is_instance_valid(_instance):
		return _instance
	return null


# ==================== 配置参数（@export，选中 WindSystem 节点即可在 Inspector 里调） ====================

## 总开关：false 时 _process 第一行就 return —— 既不扫场景也不写任何材质。
## ⚠ 副作用：cur_* 会**冻结**在最后一帧的值，读它们的 VFX（火焰等）会拿到不变的风。
@export var enabled := true
## 玩家节点。留空会自动找（分组 "player" -> 按名字含 player 的节点）
@export var player_path: NodePath
@export var player_radius := 0.75      ## 踩踏影响半径
@export var player_bend := 0.55        ## 下压强度
@export var player_spread := 0.30      ## 左右分开力度
## ★ 角色头顶高度（米）：**低于头顶**的树 L5 枝条/树叶/花朵会被角色顶开。
##   写到材质的 player_head_y = 脚底 y + 这个值 —— 跳跃时脚底抬高，头顶自动跟着变高，
##   所以不需要再单独传"正在跳跃"的标志。
##   角色节点带 target_height（player.gd 有）时优先用它，这里只是兜底。
@export var player_head_height := 1.75
@export var move_ref_speed := 3.0      ## 多少米/秒算全速（超过按满算）
## ★ 站着不动时也**持续保持**的一个分开量：身体把草撑开着，不会完全回弹
@export var stand_bend := 0.35
## ★ 站着时把影响半径缩小到多少（只影响紧贴身体那一圈，走路时恢复全半径）
@export var stand_radius_scale := 0.60
@export var move_smooth := 8.0         ## 移动量的平滑速度（越大越跟手）
## 找不到 Weather 时的兜底风
@export var fallback_wind := 0.18
## 阵风叠加量：写进 SGT 草的实际强度是 strength * (1.0 + gust)（见 _write_sgt 的 wind_now）。
## 调大 -> 风「一阵一阵」的感觉更明显；0 = 完全恒定的风。
@export var fallback_gust := 0.15
## 湍流（无序抖动）强度：越大草摆动越「毛躁」，0 = 整片草整齐同向摆。
@export var fallback_turbulence := 0.30
## 风速（米/秒量级）：既决定风的相位推进快慢，也决定 _movement 的累积速度。
## 调大 -> 摆动更快更急；调小 -> 慢悠悠。只在兜底路径用，正常有 Weather 时以它为准。
@export var fallback_speed := 1.4
## 兜底风向：水平面 (x, z)，代码里会 normalized() 后再用。
## ⚠ 只有这两个分量有意义：_write_sgt 里是 Vector3(dir2.x, 0.0, dir2.y)（y 分量被丢弃）。
## ⚠ 若填 (0, 0)，normalized() 得到零向量 -> 风向失效（草只抖动不流动）。
@export var fallback_direction := Vector2(1.0, 0.0)
## 重新扫描场景树的间隔（秒）：运行中动态增删草 / 树时，靠它把新材质补收进来。
## 调小 -> 新出现的草更快受风，但每轮是**一次全场景遍历**，成本随之上升；
## 调成 0 会变成每帧全树遍历（不推荐）。0.5 是成本与及时性的折中。
@export var scan_interval := 0.5
## ★ SGT 草的人物倒伏/分开强度（想调手感直接改这里）
##   半径：以玩家为圆心多大范围内动草（米）
##   radial：径向"分开"位移（米，叶尖量级）
##   bend：沿移动方向"倒伏"位移（米，叶尖量级）
##   debug_sgt_player：每 0.5 秒把这条链的数值打到日志（确认有没有生效）
## ★ SGT 草的人物倒伏/分开强度
##   ⚠ 这些参数**只**以本节点（scenes/main.tscn 的 "WindSystem"）上的 @export 为准：
##     选中该节点 → Inspector → 改完立即生效（运行中改也立刻生效，下一帧 _write_sgt 就用新值）。
##     （不再走项目设置 —— 那是去掉 autoload 之前的历史机制，已整套删除）
@export var sgt_player_bend_radius := 1.4        ## 影响半径（米）
@export var sgt_player_radial := 1.20            ## 径向"分开"位移（米级手柄）
@export var sgt_player_bend := 1.00              ## 沿移动方向"倒伏"位移（米级手柄）
@export var sgt_player_gain := 0.10              ## 位移总增益（收敛量级）
## ★★ 进阶：高度闸门 —— 角色脚底**高于附近草顶**时，不该有倒伏/分开（例如起跳、站高处俯看草）
##   height_margin：留一点余量（米），脚底高于"草顶 + 余量"才算悬空
@export var sgt_height_gate := true
@export var sgt_height_margin := 0.05
## ★ 闸门平滑时间（秒）：起跳离草 / 落地入草时，倒伏不能"啪"地弹回或压下
##   越大越软（约 0.2 秒是"有感觉但不拖沓"）；0 = 瞬时（不推荐）
@export var sgt_height_gate_smooth := 0.2
@export var debug_sgt_player := true             ## 移动时每秒打一条日志（确认链路用）
## ★★ 本项目改动：角色被草遮挡时的轮廓（脚底小圈，白色）
##   enable：总开关 ｜ px：轮廓宽度（像素）｜ height：角色高度（米，用于估算屏幕半径）
@export var sgt_occlusion_outline := false       ## 草着色器里的屏幕圈：已由 foot_ring 实体圈代替，默认关
## ★ 角色脚底圈（贴合地形的实体环带，scripts/foot_ring.gd）
@export var sgt_foot_ring := true
@export var sgt_occlusion_px := 1.0              ## 轮廓宽度（像素）
@export var sgt_occlusion_height := 1.75         ## 角色高度（米）
@export var sgt_occlusion_foot_radius := 0.20    ## 轮廓半径（米）：以角色脚底为圆心的小圈
@export var sgt_occlusion_color := Color(1.0, 1.0, 1.0, 0.55)   ## 半透明白（a = 不透明度）
## ★ 调试开关（默认关）：启动 2 秒后把玩家送到最近一株 SGT 草上，便于查看轮廓
@export var debug_snap_to_grass := false

# ★★★ fast-tree 风摆移植 · 树风参数（这根节点在场景里 → Inspector 直接可调）
##   算法出处：D:\sgames\fast-tree\src\core\materials.js L29-135（逐行移植到
##   assets/shaders/fast_tree_wind.gdshaderinc），量级约定见 docs/wind-port-spec.md。
##   树梢顺风偏移 = tree_force_min + clamp(weather.wind, 0, 1) × tree_force_per_wind（米）。
##   这是 fast-tree autoWind 的档位：strength = 0.03 + k × 0.30（k = 风强度 0..1）。
##   fast-tree 的默认档位只有十几厘米（"树叶在动、树干基本不动"），
##   想要更夸张的狂风就把这个值调大（它只影响树，不影响草）。
@export_group("树风（fast-tree 移植）")
@export var tree_wind_enabled := true
## weather.wind（截到 0..1）→ 每 1.0 换算成多少**米**的树梢顺风偏移
##   fast-tree autoWind：strength = 0.03 + k × 0.30 × rand(0.75..1.25)（k = 风强度 0..1）
##   所以这里默认 0.30，再叠加下面的 tree_force_min，档位与源实现一致
@export var tree_force_per_wind := 0.30
## 静风基线（米）：fast-tree 的 0.03。给 0 就是"完全无风时纹丝不动"
@export var tree_force_min := 0.03
## 次波频率倍率（fast-tree uWindFrequency）
@export var tree_frequency := 1.0
## 阵风脉动速度（fast-tree uGustSpeed）
@export var tree_gust_speed := 0.16
## 世界 xz 相位错开（fast-tree uSpatialScale）：越大，同一次风在树冠不同位置的时间差越明显
@export var tree_spatial_scale := 0.22
## 顺风静态偏置（fast-tree uWindBias）：只抬高摆动低谷，风"只推不拉"
@export var tree_bias := 0.30
## flex 指数（fast-tree uFlexFalloff）：越大，树干越硬、越只有枝梢在动
@export var tree_flex_falloff := 1.5
## 每棵树的随机种子（fast-tree uSeed）；0 = 不偏移
@export var tree_seed := 0.0
## ★ 每元素"去同步化"（0 = 完全等于 fast-tree 源实现，>0 = 每片叶/每朵花有自己的节奏）
##   源实现里所有元素共用一个抖动频率、只靠相位错开 —— 几千片叶/花落在同一棵树上时
##   会呈现"整片同频振动"，观感机械。这里按烘焙相位给每个元素一个稳定的频率/幅度微差。
##   0.4~0.6 是比较自然的档位；调到 0 就是严格的源实现（便于回归对比）。
@export_range(0.0, 1.0) var tree_variation := 0.45
## 刚性主波"次级项"的频率微差（影响枝条/果实的快慢差异）。
##   ⚠ 主项保持全局同频，所以不会让叶片相对枝条缓慢漂移；但给太大（>0.5）
##     仍可能出现"叶片与枝梢轻微错位"，建议 0.1~0.25。
@export_range(0.0, 1.0) var tree_sway_variation := 0.15
@export_group("")
# ==================== 运行时状态（帧缓存 / 材质缓存） ====================

## 每帧算好的角色屏幕量（供 _write_sgt 写入材质）
var _occl_on := 0.0
var _occl_screen := Vector2(-100000.0, -100000.0)
var _occl_radius := 0.0
var _occl_depth := 0.0
## ★ 两套尺寸都要：逻辑视口（unproject 坐标系）与帧缓冲像素（FRAGCOORD 坐标系）
var _occl_vp_logical := Vector2(1280.0, 720.0)
var _occl_vp_pixel := Vector2(1280.0, 720.0)
## ★ 高度闸门状态
##   _sgt_grass_nodes：SGT 草节点（MultiMeshInstance3D）
##   _sgt_grass_pts  ：每株草的"世界坐标 + 顶部高度" [Vector4(x, y(地面), z, 顶部世界高度)]
##   _sgt_gate       ：1 = 正常倒伏/分开，0 = 角色悬空（脚底高于草顶）不作用
var _sgt_grass_nodes: Array = []
var _sgt_grass_pts: Array = []
## gate 是**目标值**（0/1），_sgt_gate_s 是**实际写入材质的平滑值**
var _sgt_gate := 1.0
var _sgt_gate_s := 1.0
var _sgt_gate_pts := 0


## ★ 当前风（供火焰/其他 VFX 读取，不必去翻材质）。每次写材质前同步更新。
var cur_dir := Vector2(1.0, 0.0)
var cur_strength := 0.18
var cur_gust := 0.15
var cur_turbulence := 0.30
var cur_speed := 1.4

## ★ 材质缓存与扫描状态
##   _registered：累计登记过多少材质（只增不减，仅用于日志）
##   _scan_timer：距下一次 _scan() 还有多少秒（累加 delta，到 scan_interval 清零重扫）
##   _mats_ours / _mats_sgt：两类受风材质的强引用列表（每帧遍历写 uniform）
##   _seen：instance_id 集合，防止同一材质被反复登记（跨 _scan 的持久去重表）
var _registered := 0
var _scan_timer := 0.0
var _mats_ours: Array[ShaderMaterial] = []
## ★ fast-tree 风摆移植：树（树干/枝条/果实 + 树叶/花朵）单独一份列表。
##   树的风场用**米级** wind_force，草用**相对** wind_strength，两者语义不同 → 必须分开写。
var _mats_tree: Array[ShaderMaterial] = []
var _mats_sgt: Array[ShaderMaterial] = []
var _seen := {}
## ★ 玩家相关缓存
##   _movement：累积的风「流动相位」（Vector3，近似米），写进 SGT 的 sgt_wind_movement，
##              让草叶随时间推移流动而不是原地摆动；只做加法、不回绕（float 精度足够）
##   _player / _player_prev / _player_fwd：玩家节点、上一帧世界坐标、平滑后的水平朝向（单位向量）
var _movement := Vector3.ZERO
var _player: Node3D = null
var _player_prev := Vector3.ZERO
var _player_fwd := Vector3(0.0, 0.0, -1.0)
## 平滑后的移动量 0..1（站着不动 -> 0 -> 草回弹）
var _move_amt := 0.0
## ★ 给 SGT 草用的玩家世界坐标 + 这一帧的水平位移（逐材质写）
##   优先用 SimpleGrass.player_position（项目里若按插件文档更新过就用它），
##   没有（本项目的实际情况）就直接取 "player" 组节点的位置。
var _sgt_player_pos := Vector3(1.0e9, 1.0e9, 1.0e9)
var _sgt_player_step := Vector3.ZERO
## ★ SGT 玩家倒伏的调试 / 告警状态
##   _sgt_player_warned：只提示一次「改用 player 组节点位置」，避免每帧刷日志
##   _dbg_player_t：诊断日志节流计时（秒），累计到 1 秒才允许再打一条
##   _dbg_snap_t：debug_snap_to_grass 的 2 秒倒计时；触发后置 -1.0e9 -> 永不再触发
var _sgt_player_warned := false
var _dbg_player_t := 0.0
var _dbg_snap_t := 0.0
## ★ 角色脚底圈（贴合地形的实体环带，见 scripts/foot_ring.gd）
var _foot_ring: Node = null


# ==================== 生命周期回调 ====================

## 初始化（场景实例进入场景树时调用一次，此时通常已有 current_scene）。
## 依次做 5 件事，顺序有依赖：
##   1) 登记单例取用口：_instance = self + add_to_group("wind_system")
##      （**必须放最前面**：同场景里别的节点的 _ready 可能紧接着就来取风）
##   2) process_mode = ALWAYS —— 暂停 / 时间缩放时仍继续写材质，
##      否则暂停后草会「卡」在上一帧的风里不动（想要暂停时也静止就改成 INHERIT）
##   3) 连接 Viewport.size_changed -> _on_viewport_size_changed
##      必须在这里连（而不是 _process 里）：轮廓半径依赖视口尺寸，窗口一变就要立刻重写材质
##   4) _setup_foot_ring() —— 在自身下 new 出 FootRing 子节点（受 sgt_foot_ring 开关控制）
##   5) _scan() —— 先收一次材质，否则开头 scan_interval 秒内草完全没风
## 返回值：无。副作用：写静态引用 / 加分组、改 process_mode、建子节点、连信号、写材质缓存。
## 注意：没有 current_scene 时 _scan() 会安全返回，之后靠 _process 的定时扫描补上。
func _ready() -> void:
	_instance = self
	add_to_group("wind_system")
	process_mode = Node.PROCESS_MODE_ALWAYS
	# ★ 窗口/视口尺寸一变就重算角色屏幕量并立刻写进草材质（否则轮廓会一直按旧尺寸画）
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_size_changed):
		vp.size_changed.connect(_on_viewport_size_changed)
	_setup_foot_ring()
	_scan()


## 离开场景树时注销静态取用口，免得别的脚本拿到一个已释放的节点。
## 只有「当前实例就是自己」才清空：防止同帧新旧两个实例交替时，旧的 _exit_tree 抹掉新实例的引用。
func _exit_tree() -> void:
	if _instance == self:
		_instance = null


# ==================== 脚底圈（实体环带） ====================

## ★★ 建立"角色脚底圈"：贴合地形的实体环带（照搬火焰圈选的地形贴合思路）。
##   圈本身是 3D 网格，不再画在草的着色器里 —— 这样才能贴合坡地/台阶。
## ⚠ add_child 必须 **deferred**：本脚本现在是场景内节点，_ready() 会在主场景
##   "正在装配子节点"的过程中执行，此时立刻 add_child 会报
##   "Parent node is busy setting up children, add_child() failed" ——
##   连带 foot_ring 自己的 _ready（里面要把圈网格挂到 current_scene）一起失败，圈就永远不出现。
##   延后一帧执行则可以等主场景装配完成。
func _setup_foot_ring() -> void:
	if not sgt_foot_ring:
		return
	var scr: Script = load("res://scripts/foot_ring.gd")
	if scr == null:
		push_warning("[Wind] foot_ring.gd 缺失，脚底圈不可用")
		return
	var r: Node = scr.new()
	r.name = "FootRing"
	_foot_ring = r
	add_child.call_deferred(r)


## 读脚底圈的参数（半径 / 颜色 / 宽度），让草的屏幕圈与实体圈用同一组数值，
## 避免"两个圈不一致"；圈不存在时退回脚本里的默认值。
## 参数 prop：foot_ring.gd 上的属性名（本项目用 "radius"）；fallback：取不到时的返回值。
## 返回值：float；只有值确实是 float/int 时才采信，其余（含 null）一律退回 fallback。
## 注意：走的是 Object.get() 动态取属性，属性名拼错不会报错、只会静默走 fallback（推测）。
func _ring_num(prop: String, fallback: float) -> float:
	if _foot_ring == null or not is_instance_valid(_foot_ring):
		return fallback
	var v: Variant = _foot_ring.get(prop)
	if v is float or v is int:
		return float(v)
	return fallback


## 读脚底圈的颜色（foot_ring.gd 的 color 属性），读不到就用传入值兜底。
## 参数 fallback：圈不存在 / 属性不是 Color 时的返回值（调用方传的是 sgt_occlusion_color）。
## 返回值：保 **alpha 通道**的颜色 —— 着色器用它做轮廓的不透明度（半透明白）。不要在这里丢掉 a。
func _ring_color(fallback: Color) -> Color:
	if _foot_ring == null or not is_instance_valid(_foot_ring):
		return fallback
	var v: Variant = _foot_ring.get("color")
	if v is Color:
		return v as Color
	return fallback


## 每帧主循环：算玩家移动量 -> 更新 SGT 人物倒伏与高度闸门 -> 把风参数写进材质。
## 参数 delta：距上一帧的秒数（用于「米/秒」换算与所有指数平滑）。
## 执行流程（顺序有依赖，别随意调换）：
##   1) enabled 为 false -> 立刻返回（不写任何材质）
##   2) debug_snap_to_grass 为 true -> 启动约 2 秒后传送一次玩家（默认关，纯调试）
##   3) _scan_timer 累计到 scan_interval -> _scan() 补收新出现的材质
##   4) 求玩家世界坐标 ppos 与这一帧的水平位移 pmov，并更新 _move_amt（0..1）与 _player_fwd
##   5) _update_sgt_player() —— 算 SGT 玩家位置/位移、高度闸门目标与屏幕量
##   6) 根节点下有 "Weather" -> _apply_from_weather()，否则 -> _apply_fallback()
## 副作用：写材质 uniform、刷新 cur_* 与 _movement、可能 print 日志。
## 注意：
##   · 玩家找不到（p == null）时 _move_amt 会平滑归零，草自动回弹，不会留下永久倒伏
##   · 本函数不增删场景节点（FootRing 只在 _ready 里建一次）
##   · pmov 已被 limit_length(1.0) 截断，写进材质的是「米级位移手柄」而非常规速度
func _process(delta: float) -> void:
	if not enabled:
		return
	# ★ 调试：启动 2 秒后把玩家送到最近一株 SGT 草（默认关）
	if debug_snap_to_grass:
		_dbg_snap_t += delta
		if _dbg_snap_t >= 2.0:
			# 置成 -1.0e9 而不是 0：这个分支只允许触发一次，用负值保证计时器永远追不上 2.0
			_dbg_snap_t = -1.0e9
			print("[Wind] 调试传送: %s ｜ 脚底圈半径=%.1f px（视口逻辑）" % [
					str(snap_player_to_nearest_grass()), _occl_radius])
	_scan_timer += delta
	if _scan_timer >= scan_interval:
		_scan_timer = 0.0
		_scan()
	var p := _find_player()
	# ★ 哨兵约定：找不到玩家时给一个「很远很低」的坐标，它会原样写进 player_pos，
	#   着色器算距离权重时永远为 0 -> 不会莫名其妙在原点附近留一圈倒伏的草
	var ppos := Vector3(0.0, -100000.0, 0.0)
	var pmov := Vector3.ZERO
	if p != null:
		ppos = p.global_position
		var step := ppos - _player_prev
		step.y = 0.0
		if delta > 0.0001:
			var spd := step.length() / delta
			var target := clampf(spd / maxf(0.01, move_ref_speed), 0.0, 1.0)
			# 指数平滑：起步和停下都有过渡，不会"啪"地弹开/回正
			_move_amt = lerpf(_move_amt, target, clampf(delta * move_smooth, 0.0, 1.0))
		else:
			_move_amt = 0.0
		if not step.is_zero_approx():
			# 朝向优先用**速度方向**（更符合"往前走时草往两边分开"）
			var vf := step.normalized()
			# ★ 朝向做**平滑**而不是直接赋值：速度方向逐帧都在抖，直接赋值会让草的倒伏方向一起抖。
			#   8.0 是经验收敛系数（约 0.1 秒到位），与 move_smooth 无关，别混用。
			_player_fwd = _player_fwd.lerp(vf, clampf(delta * 8.0, 0.0, 1.0)).normalized()
		pmov = step.limit_length(1.0)
		_player_prev = ppos
	else:
		_move_amt = lerpf(_move_amt, 0.0, clampf(delta * move_smooth, 0.0, 1.0))
	# ★ SGT 草的人物倒伏：位置 + 这一帧的水平位移（逐材质写，见 _write_sgt）
	_update_sgt_player(delta, p, ppos)
	# 天气
	var w: Node = _find_weather_node()
	if w != null:
		_apply_from_weather(w, delta, ppos, pmov)
	else:
		_apply_fallback(ppos, pmov)


## 找天气节点。顺序：当前场景根下的 "Weather"（正式形态：main.tscn 的 Main/Weather）
## -> /root/Weather（旧 autoload 兼容）-> 分组 weather_system（改名/换父节点时的兜底）。
## ★ 必须**先查当前场景**：只查 /root 会漏掉场景里的节点，于是永远走 _apply_fallback，
##   表现就是"按 V 换天气，草一点反应都没有"（本次回归的根因）。
## 返回：天气节点或 null（null 时走 fallback_* 常量，草仍有风）。
func _find_weather_node() -> Node:
	var t := get_tree()
	if t == null:
		return null
	var cs := t.current_scene
	if cs != null:
		var direct := cs.get_node_or_null("Weather")
		if direct != null:
			return direct
	var legacy := t.root.get_node_or_null("Weather")
	if legacy != null:
		return legacy
	return t.get_first_node_in_group(&"weather_system")


# ==================== 材质收集（扫描场景树） ====================
# ---------------------------------------------------------------- 材质收集

## 遍历当前场景（深度优先，显式栈），把所有受风 / 受踩踏的 ShaderMaterial 收进 _mats_ours / _mats_sgt。
## 参数：无（数据从 get_tree().current_scene 拿）。
## 返回值：无，结果全部写在成员变量里（_mats_* / _seen / _registered / _sgt_grass_nodes）。
## 调用时机：_ready() 一次，之后每 scan_interval 秒由 _process 再调一次。
## 副作用：
##   · 清空并重建 _sgt_grass_nodes，并调用 _cache_grass_tops() 重建 _sgt_grass_pts
##   · 视情况 print 诊断日志（缓存了多少株 / 新增了多少材质）
## 注意：
##   · 每轮开头必须 clear()，否则节点会一轮轮累积（见函数内行内注释）
##   · 同一材质靠 _seen（instance_id 字典）去重，重扫不会重复追加、也不会重复计数
##   · 用显式栈而不是递归：场景层级深、节点多时不会爆栈
##   · 只认 MeshInstance3D 与 MultiMeshInstance3D 两种节点（其它节点其子节点仍会被继续遍历）
func _scan() -> void:
	if get_tree() == null:
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var found := 0
	# ⚠ 每次扫描都要清空草节点列表：_scan() 每 scan_interval 秒重跑一次，
	#   不清空会不断累积重复节点 -> 缓存被重复追加、白白吃内存
	_sgt_grass_nodes.clear()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		# ★★ 修复：MultiMeshInstance3D **不是** MeshInstance3D 的子类 ✗
		#   SimpleGrassTextured 的草用的是 MultiMeshInstance3D ✓
		#   → 之前只判 `is MeshInstance3D` ✓ → SGT 草永远不被收集 ✗
		#   → `_write_sgt()` 里 `if _mats_sgt.is_empty(): return` 每帧直接返回 ✗
		#   → 表现就是「simplegrass 的草不受风力影响」✓✓
		if n is MeshInstance3D:
			found += _take_from_mesh(n as MeshInstance3D)
		elif n is MultiMeshInstance3D:
			if n.has_meta(&"SimpleGrassTextured"):
				_sgt_grass_nodes.append(n)      # ★ 记下 SGT 草节点，供高度闸门用
			found += _take_from_multimesh(n as MultiMeshInstance3D)
		for c in n.get_children():
			stack.append(c)
	_cache_grass_tops()                        # ★ 缓存每株草的位置与顶部高度
	if _sgt_grass_pts.size() > 0:
		print("[Wind] 高度闸门：缓存 %d 株 SGT 草（%d 个草节点）" % [
				_sgt_grass_pts.size(), _sgt_grass_nodes.size()])
	if found > 0:
		print("[Wind] 新增 %d 个受风材质（累计 %d ｜ 树 %d ｜ SGT %d）" % [found, _registered, _mats_tree.size(), _mats_sgt.size()])


## ★★ 高度闸门：缓存每株 SGT 草的"位置 + 顶部世界高度"。
##   每株草矮而多，但**只缓存一次**（草位置是静态的），闸门计算就只遍历缓存数组。
##   ⚠ MultiMesh 的节点 AABB 是**局部空间**的，不含各实例的缩放；
##     而且实例数据在 headless 下读不出真实值 —— 所以这里取保守做法：
##     草顶 = 该实例的地面高度 + 网格局部高度（不做实例缩放），够用且稳。
func _cache_grass_tops() -> void:
	_sgt_grass_pts.clear()
	# ★ 单个草节点最多缓存 6000 株：SGT 草动辄上万实例，全缓存会让每帧的闸门遍历变慢。
	#   只取前 6000 株来判断「附近有没有草」对闸门语义足够 —— 多算不漏判，
	#   宁可判成「在草里」（正常倒伏）也不要误判成悬空（草整片不动）。
	var limit := 6000
	for node in _sgt_grass_nodes:
		var mmi := node as MultiMeshInstance3D
		if mmi == null or not is_instance_valid(mmi) or mmi.multimesh == null:
			continue
		var local_h := mmi.get_aabb().size.y
		if local_h <= 0.0001:
			local_h = 1.0
		var xf := mmi.global_transform
		var cnt := mini(mmi.multimesh.instance_count, limit)
		for i in range(cnt):
			var t := mmi.multimesh.get_instance_transform(i)
			var w: Vector3 = xf * t.origin
			# 顶部高度：地面 + 网格高度 × 实例缩放（y）
			var sy := t.basis.get_scale().y
			_sgt_grass_pts.append(Vector4(w.x, w.y, w.z, w.y + local_h * absf(sy)))


## ★★ 高度闸门：角色脚底是否**高于附近所有草的顶部**。
##   是 → 目标值 0（悬空：草不该被压/不该分开）
##   否 → 目标值 1（在草里：正常倒伏/分开）
##   ⚠ 目标值只是 0/1，直接写进材质会让草"瞬时弹回/瞬时压下" —— 必须**平滑**。
##     这里按 sgt_height_gate_smooth（秒）做指数趋近，起跳与落地都有过渡。
## 返回值：无。
## 参数 delta：帧间隔（秒）；ppos：玩家脚底世界坐标（从 _update_sgt_player 传进来，可能是哨兵值）。
## 副作用：写 _sgt_gate_pts / _sgt_gate（目标 0 或 1）与 _sgt_gate_s（平滑后的实际值）。
## 注意：闸门关掉（或没有缓存到草）时目标恒为 1.0 = 正常倒伏，属于「宁可多倒也不要不倒」的取向。
## 平滑：指数趋近，系数 delta / smooth（smooth 兜 0.001 防除零）；足够接近 0.01 就吸附到端点，
##       否则指数曲线永远差一点点，草会残留肉眼可见的倒伏。
func _update_height_gate(delta: float, ppos: Vector3) -> void:
	_sgt_gate_pts = 0
	if not sgt_height_gate or _sgt_grass_pts.is_empty():
		_sgt_gate = 1.0
	else:
		_sgt_gate = _gate_target(ppos)
	# ★ 平滑：指数趋近（与 _move_amt 同一套手感），0.35 秒基本到位
	var sm := maxf(0.001, sgt_height_gate_smooth)
	_sgt_gate_s = lerpf(_sgt_gate_s, _sgt_gate, clampf(delta / sm, 0.0, 1.0))
	# 指数趋近永远到不了端点，足够接近就吸附（免得留一丝倒伏）
	if absf(_sgt_gate_s - _sgt_gate) < 0.01:
		_sgt_gate_s = _sgt_gate


## 闸门目标值：1 = 脚底没高出附近草顶；0 = 悬空在草顶之上
## 参数 ppos：玩家**脚底**的世界坐标。
## 返回值：只有 0.0 或 1.0 两个离散值 —— 所以**必须**先经 _update_height_gate 平滑才能写材质。
## 判定规则：只遍历水平距离在 bend_radius 内的那几株草；只要有一株满足
##   「顶部世界高度 + sgt_height_margin > 脚底 y」就认为角色还在草里，立刻返回 1.0；
##   一株都没命中（附近没草，或附近的草全都明显低于脚底）返回 0.0。
## 副作用：把**已检查**的草株数累加进 _sgt_gate_pts（一旦判定在草里就立刻返回，后面没查的不计；
##   该计数只用于日志，不影响逻辑）。
## 注意：半径用 maxf(0.2, 设置值) 兜底 —— 半径为 0 会让"任何地方都算悬空"，草全都不倒。
func _gate_target(ppos: Vector3) -> float:
	var r := maxf(0.2, sgt_player_bend_radius)
	var r2 := r * r
	var foot_y := ppos.y
	var margin := sgt_height_margin
	for v in _sgt_grass_pts:
		var p4: Vector4 = v          # Array 元素是 Variant，必须显式标注类型
		var dx := p4.x - ppos.x
		var dz := p4.z - ppos.z
		if dx * dx + dz * dz > r2:
			continue
		_sgt_gate_pts += 1
		if p4.w + margin > foot_y:
			# 附近有草的顶部高过脚底 -> 角色在草里 / 站在草的同一高度
			return 1.0
	# 附近完全没有草，或附近所有草都明显低于脚底 -> 悬空
	return 0.0


## ★ 收集 MultiMeshInstance3D（SimpleGrassTextured 的整片草）的受风材质。
##   ★ MultiMeshInstance3D 与 MeshInstance3D 不是同一条继承链 ✗ 可用 API 也不同：
##     - 没有 `mesh` 属性 ✓ 网格在 `multimesh.mesh` ✓
##     - 没有 `get_surface_override_material()` ✓（那是 MeshInstance3D 的 ✓）
##     所以这里只用「节点 material_override + multimesh.mesh 自带 surface 材质」✓
func _take_from_multimesh(mmi: MultiMeshInstance3D) -> int:
	var got := 0
	var target_mesh: Mesh = null
	if mmi.multimesh != null:
		target_mesh = mmi.multimesh.mesh
	var mh: float = 0.0
	if target_mesh != null and target_mesh.get_surface_count() > 0:
		mh = mmi.get_aabb().size.y
	if mmi.material_override is ShaderMaterial:
		got += _register_h(mmi.material_override as ShaderMaterial, mh)
	if target_mesh != null:
		for s in range(target_mesh.get_surface_count()):
			var sm: Material = target_mesh.surface_get_material(s)
			if sm is ShaderMaterial:
				got += _register_h(sm as ShaderMaterial, mh)
	return got


## 收集单个 MeshInstance3D 上的受风材质（自研草 / 树 / 树上的叶子等）。
## 参数 mi：待检查的网格实例（调用方已保证非 null 且类型正确）。
## 返回值：本次**新登记**的材质个数（已登记过的不计，见 _register 的 _seen 去重）。
## 检查 3 处（都可能有材质）：
##   · 节点自身 mi.material_override
##   · 每个 surface 的 get_surface_override_material(s)
##   · 每个 surface 的网格自带材质 mi.mesh.surface_get_material(s)
## 副作用：登记成功的材质会被写入 wind_height_ref（该网格的实际渲染高度，见 _register_h）。
## 注意：高度取 get_aabb().size.y —— 世界空间、已含节点自身缩放，但不含父级骨骼/动画再加的那一层。
func _take_from_mesh(mi: MeshInstance3D) -> int:
	var got := 0
	# ★★★ 模型**实际渲染高度**（用户要求 ✓）
	#   `get_aabb()` 给的是**世界空间**包围盒 ✓（已含节点缩放 ✓ 不含父级动画的另一层 ✗）
	#   → size.y 就是它在画面里占据的真实高度（米 ✓）
	#   → 注册成功时写进 `wind_height_ref` ✓
	#     让 shader 的高度权重用**真实高度**，而不是我在材质里手填的常数 ✓
	var mh: float = 0.0
	# ★★★ 分块树冠（scripts/world/canopy_chunk_cull.gd）专用 ✓
	#   树冠被切成多块后，每块 `get_aabb()` 只是**自己那一小块**的高度 ✗
	#   → 直接拿来当 `wind_height_ref` 会让风摆的高度权重整体变掉 ✗
	#   → 分块脚本会把**整片树冠**的高度写进节点 meta ✓ 这里优先用它 ✓
	#   （没有这个 meta 的普通网格走原逻辑 ✓ 行为不变 ✓）
	if mi.has_meta("wind_height_ref"):
		mh = float(mi.get_meta("wind_height_ref"))
	elif mi.mesh != null:
		mh = mi.get_aabb().size.y
	if mi.material_override is ShaderMaterial:
		got += _register_h(mi.material_override as ShaderMaterial, mh)
	if mi.mesh != null:
		for s in range(mi.mesh.get_surface_count()):
			var ov: Material = mi.get_surface_override_material(s)
			if ov is ShaderMaterial:
				got += _register_h(ov as ShaderMaterial, mh)
			var sm: Material = mi.mesh.surface_get_material(s)
			if sm is ShaderMaterial:
				got += _register_h(sm as ShaderMaterial, mh)
	return got


## ★★★ 注册 + 写入**该网格的实际渲染高度**（用户要求 ✓）
##   草 / 叶 / 木三个 shader 的高度 uniform 都叫 `wind_height_ref` ✓
##   （写到不存在的 uniform 上是无害的 ✓ → 对 SGT 等其它 shader 也安全 ✓）
func _register_h(m: ShaderMaterial, h: float) -> int:
	var got := _register(m)
	if got > 0 and m != null and h > 0.0001:
		m.set_shader_parameter("wind_height_ref", h)
		var nm := "?"
		if m.shader != null:
			nm = String(m.shader.resource_path.get_file())
		print("[Wind] 实际高度 ✓ %s ｜ %.3f 米 → wind_height_ref" % [nm, h])
	return got


## 材质的「白名单 + 去重」登记：只认自研草/树 shader 与 SimpleGrassTextured 的 shader。
## 参数 m：候选材质；m 为 null 或 m.shader 为 null 时直接返回 0（不会崩）。
## 返回值：1 = 本次新登记；0 = 不相关或早就登记过。
## 判定依据是 **shader 资源路径的子串**（不是 uniform 名、也不是节点名）：
##   grass_wind / blend_alpha（旧名）/ tree_leaves_burn / tree_burn_keep -> _mats_ours
##   simplegrasstextured                                                -> _mats_sgt
## 副作用：_seen[id] = true；_mats_* 追加一条；_registered += 1。
## 注意：
##   · 燃烧后的树叶材质路径里没有 grass_wind，早先因此漏收 -> 叶子一烧完就不受风，故显式纳入
##   · 靠路径匹配意味着「给 shader 改文件名 / 换目录」会静默失去风效果，改名前先搜这里
##   · 去重键是 instance_id，材质被释放后实例 id 可能被复用（本项目生命周期内可忽略）
func _register(m: ShaderMaterial) -> int:
	if m == null or m.shader == null:
		return 0
	var path := String(m.shader.resource_path)
	# 我们的草：shader 现在住在 assets/shaders/grass_wind.gdshader（blend_alpha 是旧名，兼容保留）
	# ★★ 追加（用户反馈 ✓）：**燃烧后的树叶** 用的是 `tree_leaves_burn*.gdshader` ✗
	#   它的路径不含 `grass_wind` ✗ → 之前**不被注册** → 叶子换成燃烧材质后就**不受风** ✓✓
	#   （`tree_burn_keep*` 是木质 ✓ sway_amt=0 ✓ 注册也无位移 ✓ 一并纳入便于统一管理 ✓）
	# ★ fast-tree 风摆移植：树独立成 _mats_tree（米级风场），草留在 _mats_ours（相对风场）
	var is_grass := path.contains("grass_wind") or path.contains("blend_alpha")
	var is_tree := path.contains("tree_leaves_burn") or path.contains("tree_burn_keep")
	var is_sgt := path.contains("simplegrasstextured")
	if not (is_grass or is_tree or is_sgt):
		return 0
	var id := m.get_instance_id()
	if _seen.has(id):
		return 0
	_seen[id] = true
	if is_sgt:
		_mats_sgt.append(m)
	elif is_tree:
		_mats_tree.append(m)
	else:
		_mats_ours.append(m)
	_registered += 1
	return 1


# ==================== 玩家查找 ====================
# ---------------------------------------------------------------- 玩家

## 找玩家节点，结果缓存进 _player（一旦命中就不再重找，除非该节点已失效 / 被释放）。
## 参数：无。
## 查找顺序（从明确到兜底，命中即返回）：
##   1) @export player_path（为空则跳过这一步）
##   2) 分组 "player" 的第一个节点
##   3) 全场景遍历：名字里含 "player"（忽略大小写）的 Node3D
## 返回值：找到的 Node3D；三条路都没找到则返回 null（**调用方必须判空**）。
## 副作用（每次「首次命中」某条分支时都会执行这套初始化）：
##   · _player 缓存、_player_prev = 玩家当前世界坐标
##   · _player_fwd = -basis.z 去掉 y 后归一化
##     ⚠ _player_prev 的初始化很关键：不填的话第一帧 step 会是「从原点飞到玩家」的巨大位移，
##        _move_amt 直接被顶满 -> 开场整片草猛地倒一下
## 调用时机：每帧由 _process 调（命中缓存时开销只是两次 is_instance_valid 级别）。
func _find_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	if get_tree() == null:
		return null
	if not player_path.is_empty():
		var n := get_node_or_null(player_path)
		if n is Node3D:
			_player = n
			_player_prev = _player.global_position
			_player_fwd = -_player.global_transform.basis.z
			_player_fwd.y = 0.0
			_player_fwd = _player_fwd.normalized()
			return _player
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		_player = g
		_player_prev = _player.global_position
		_player_fwd = -_player.global_transform.basis.z
		_player_fwd.y = 0.0
		_player_fwd = _player_fwd.normalized()
		return _player
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n2: Node = stack.pop_back()
		if n2 == null:
			continue
		if n2 is Node3D and String(n2.name).to_lower().contains("player"):
			_player = n2 as Node3D
			_player_prev = _player.global_position
			_player_fwd = -_player.global_transform.basis.z
			_player_fwd.y = 0.0
			_player_fwd = _player_fwd.normalized()
			return _player
		for c in n2.get_children():
			stack.append(c)
	return null


# ==================== SGT 人物倒伏（位置 / 位移 / 高度闸门） ====================
# ---------------------------------------------------------------- SGT 人物倒伏




## ★ SGT 草的人物倒伏参数：玩家世界坐标 + 每帧水平位移
##   位置优先取 SimpleGrass.player_position（插件文档推荐项目每帧调 set_player_position），
##   但本项目 game/player 脚本并没有调它 -> 兜底直接读 "player" 组节点的 global_position。
##   位移用位置差分得到；大于 1.5 米视为传送/初始化，不给推力（避免一瞬间把草吹平）。
##
## 参数：delta —— 帧间隔（秒，转交给高度闸门的平滑）；p —— 玩家节点（可能为 null）；
##       ppos —— _process 已经算好的玩家世界坐标。
## 返回值：无（结果写在成员上，供 _write_sgt 逐材质读取）。
## 副作用：更新 _sgt_player_pos / _sgt_player_step；调用 _update_height_gate()（写 _sgt_gate*）；
##         调用 _update_screen_metrics()（写 _occl_*）；首次走兜底时会 print 一条提示（只一次）。
## 注意：
##   · SimpleGrass.player_position 只有**长度 > 1.0** 才被当作有效值（刚启动时是 0 向量）
##   · 找不到玩家时会把 _sgt_player_pos 顶回 1e9 哨兵，避免整片草朝一个假点倒（见函数末尾）
##   · _sgt_player_warned 保证那条提示只打一次，不要去掉，否则每帧刷日志
func _update_sgt_player(delta: float, p: Node3D, ppos: Vector3) -> void:
	var pos := Vector3(1.0e9, 1.0e9, 1.0e9)
	var sg: Node = null
	if get_tree() != null:
		sg = get_tree().root.get_node_or_null("SimpleGrass")
	if sg != null:
		var v: Variant = sg.get("player_position")
		if v is Vector3 and (v as Vector3).length() > 1.0:
			pos = v as Vector3
	var using_group := false
	# ★ 哨兵判定：1.0e9 表示「还没拿到玩家位置」（SimpleGrass.player_position 没被更新过）。
	#   正常世界坐标不可能到 1e8，所以只看 x 分量就够，不必比较整个向量。
	if pos.x > 1.0e8 and p != null:
		pos = ppos
		using_group = true
		if not _sgt_player_warned:
			_sgt_player_warned = true
			print("[Wind] SGT 草人物倒伏：改用 \"player\" 组节点的位置（项目未调用 SimpleGrass.set_player_position）")
	var step := pos - _sgt_player_pos
	step.y = 0.0
	# ★ 单帧水平位移 > 1.5 米视为「传送 / 首帧初始化」而不是走路：
	#   直接丢弃这次推力，否则一瞬间的巨量 step 会把整片草一次吹平（而且回弹要好几秒）。
	if step.length() > 1.5:
		step = Vector3.ZERO    # 跳变
	_sgt_player_pos = pos
	_sgt_player_step = step
	if using_group and p == null:
		# 连玩家都找不到：把影响半径清零，别让草整片朝一个假点倒
		_sgt_player_pos = Vector3(1.0e9, 1.0e9, 1.0e9)
	# ★★ 高度闸门：脚底高于附近草顶（起跳 / 站高处俯看草）-> 倒伏与分开都不作用，
	#   已经在倒伏的草会平滑恢复（平滑由 _move_amt 与着色器自身过渡完成）。
	_update_height_gate(delta, pos)
	# ★ 顺带算"角色在屏幕上的位置/半径/视深度"，供草着色器画遮挡轮廓
	_update_screen_metrics(p)

# ==================== 角色屏幕量 / 脚底轮廓 ====================

## ★★ 本项目改动：算出角色在屏幕上的位置、半径与视空间深度。
##   草着色器用它们判断"这一像素是否属于被草挡住角色"的那一圈，从而描出 1px 褐色轮廓。
##   ⚠ 这套量**全都依赖视口尺寸**（半径是"比例"，脚本按视口像素换算），
##     所以窗口一改尺寸就必须重算并**立刻**写进材质 —— 见 _on_viewport_size_changed()。
##   每帧无条件计算（不做开关早退），关闭开关时由调用方把 _occl_on 归零。
##
## 参数 p：玩家节点（null / 已释放 / 没有相机 / 没有视口时直接 return，不写任何量）。
## 返回值：无。
## 副作用：写 _occl_screen / _occl_radius / _occl_depth / _occl_vp_logical / _occl_vp_pixel / _occl_on。
## 注意：半径小于 0.5 像素时**提前 return**（角色贴到相机背后或极远），此时 _occl_on 保持上一帧的旧值，
##       所以调用方在不需要轮廓时应显式把 _occl_on 归零，不要指望这里清。
func _update_screen_metrics(p: Node3D) -> void:
	if p == null or not is_instance_valid(p) or get_tree() == null:
		return
	var cam := get_tree().root.get_camera_3d()
	if cam == null:
		return
	var vp := cam.get_viewport()
	if vp == null:
		return
	# ★★ 两套尺寸都要，缺一不可（这是"轮廓完全看不到 / 不跟随"的根本原因）：
	#   · unproject_position() 返回的是**视口逻辑坐标**（本机 1280x720）
	#   · 着色器 FRAGCOORD 是**帧缓冲真实像素**（本机 3824x1982，比例约 2.99）
	#   只存一套，圆就会被画到错误的屏幕位置。
	var px_size := _framebuffer_pixel_size()
	var logical := Vector2(vp.get_visible_rect().size)
	if logical.x < 1.0 or logical.y < 1.0:
		logical = px_size
	if px_size.x < 1.0 or px_size.y < 1.0:
		px_size = logical
	var base := p.global_position
	var h := maxf(0.2, sgt_occlusion_height)
	# ★ 轮廓是"角色脚底的一个小圈"：圆心 = 脚底屏幕位置。
	#   半径用**相机参数解析计算**，不要用"投影一个世界方向上的点再量长度"：
	#   后者会随角色朝向/坡度/相机偏航而给出不同长度（世界 +X 方向在俯视+偏航下
	#   投影长度本来就不等于圆圈的屏幕半径）-> 表现就是"圈时大时小"。
	#   解析式：在角色所处深度上，1 米对应多少**视口逻辑像素**。
	var p_bot := cam.unproject_position(base)
	var r_world := maxf(0.05, _ring_num("radius", 0.30))
	var r_px := r_world * _pixels_per_meter(cam, base, logical)
	if r_px < 0.5:
		return    # 角色几乎在相机背后 / 极远：不画
	_occl_screen = p_bot                              # 视口逻辑坐标（与 unproject 一致）
	# ★ 半径上限压到视口逻辑高度的 0.9 倍：角色贴脸时 r_px 会算得极大，
	#   不钳制的话着色器里那圈比较会横扫整个屏幕，看起来像整屏发白。
	_occl_radius = clampf(r_px, 0.5, 0.9 * logical.y)
	# ★ 深度取的是**角色半身高处**（脚底 + h/2）而不是脚底：草叶是从下往上长的，
	#   用胸口附近的深度去比"谁在前谁在后"更接近视觉真实；取负号把视空间的 -z 变成正数深度。
	_occl_depth = -(cam.global_transform.affine_inverse() * (base + Vector3(0.0, h * 0.5, 0.0))).z
	_occl_vp_logical = logical
	_occl_vp_pixel = px_size
	_occl_on = 1.0


# ==================== 视口 / 像素换算工具 ====================

## ★ 帧缓冲真实像素尺寸（与着色器 FRAGCOORD 同坐标系）。
##   ⚠ Window 没有 get_render_target_size()（那是 Viewport 的方法，调用会直接崩到断点）。
func _framebuffer_pixel_size() -> Vector2:
	var s := Vector2(DisplayServer.window_get_size())
	if s.x < 1.0 or s.y < 1.0:
		s = Vector2(1280.0, 720.0)
	return s


## ★ 在 `at` 所处深度上，**1 米对应多少视口逻辑像素**（解析式，不含方向依赖）。
##   透视：该深度的可见世界高度 = 2 * 距离 * tan(fov/2)，再按视口逻辑高度换算。
##   ⚠ 不要用"投影一个世界方向上的点再量长度"来估 —— 那会随朝向/坡度/相机偏航
##     给出不同值，表现就是圈的屏幕大小时大时小。
func _pixels_per_meter(cam: Camera3D, at: Vector3, logical: Vector2) -> float:
	var vh := maxf(1.0, logical.y)
	if cam.projection == Camera3D.PROJECTION_ORTHOGONAL:
		return vh / maxf(0.01, cam.size)
	var cam_inv := cam.global_transform.affine_inverse()
	var dist := -(cam_inv * at).z          # 视空间深度（正数，越远越大）
	if dist < 0.01:
		return 0.0
	var world_h := 2.0 * dist * tan(deg_to_rad(cam.fov) * 0.5)
	if world_h < 0.0001:
		return 0.0
	return vh / world_h


## ★★ 窗口/视口尺寸变化：立即重算屏幕量并写进材质。
##   不这样做的话，轮廓会一直用**旧视口尺寸**换算（半径、像素宽度全部错位），
##   而且要等到下一次风参数写入才可能纠正 —— 草材质列表为空时更是永远不纠正。
func _on_viewport_size_changed() -> void:
	var p := _find_player()
	if p == null:
		return
	_update_screen_metrics(p)
	_apply_sgt_occlusion()
	if debug_sgt_player:
		print("[Wind] 视口尺寸变化 -> 已刷新轮廓：逻辑=%s 像素=%s 屏幕半径=%.2f 视深度=%.2f" % [
				str(_occl_vp_logical), str(_occl_vp_pixel), _occl_radius, _occl_depth])


## ★ 把"角色屏幕量 + 轮廓参数"写进所有 SGT 草材质。
##   ★ 必须**每次遍历全部材质**（不像风参数那样一帧只写一次也无所谓）：
##     resize 时会立刻调这里，不能只更新第一个材质。
##
## 参数：无（屏幕量取 _occl_* 成员，开关/宽度取本节点的 @export）。
## 返回值：无。
## 副作用：往 _mats_sgt 每个材质写 8 个 uniform：
##   sgt_player_screen / sgt_player_screen_r / sgt_player_depth /
##   sgt_occl_vp_logical / sgt_occl_vp_pixel / sgt_occl_on / sgt_occl_px / sgt_occl_color
## 注意：
##   · 开关关掉时不是「不写」，而是把 sgt_occl_on 写成 0（靠 uniform 关闭，避免材质残留旧圈）
##   · 颜色**保留 alpha**：着色器用 a 做轮廓不透明度，若在这里丢掉 a 轮廓会变成全不透明
##   · 已失效的材质用 is_instance_valid 跳过，防止访问已释放对象
func _apply_sgt_occlusion() -> void:
	var on := _occl_on
	if not sgt_occlusion_outline:
		on = 0.0
	var px := sgt_occlusion_px
	var oc := _ring_color(sgt_occlusion_color)
	# ★ 保留 alpha：着色器用它做轮廓的不透明度（半透明白）
	var col := Color(oc.r, oc.g, oc.b, oc.a)
	for m in _mats_sgt:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("sgt_player_screen", _occl_screen)
		m.set_shader_parameter("sgt_player_screen_r", _occl_radius)
		m.set_shader_parameter("sgt_player_depth", _occl_depth)
		m.set_shader_parameter("sgt_occl_vp_logical", _occl_vp_logical)
		m.set_shader_parameter("sgt_occl_vp_pixel", _occl_vp_pixel)
		m.set_shader_parameter("sgt_occl_on", on)
		m.set_shader_parameter("sgt_occl_px", px)
		m.set_shader_parameter("sgt_occl_color", col)


## ★ 调试用：把玩家送到**最近的一株 SGT 草**上（脚下有草，便于查看轮廓；不影响正常玩法）
##
## 参数：无（从 _find_player() 拿玩家，从 current_scene 拿草）。
## 返回值：true = 已传送；false = 没找到玩家 / 没找到任何 SGT 草（此时不改动任何状态）。
## 副作用：直接写 p.global_position —— **只改 x/z，保留原 y**，
##   否则会把角色塞进地里或悬在半空（地形高度这里不查）。
## 调用时机：debug_snap_to_grass 打开时由 _process 在启动约 2 秒后自动调一次；
##   也可以在控制台 / 测试脚本里手动调（本文件少见的公开方法之一）。
## 注意：每个草节点最多看 4000 个实例（与 _cache_grass_tops 的 6000 是两套独立上限），
##   超大草地上取到的是"前 4000 株里最近的一株"，调试够用。
func snap_player_to_nearest_grass() -> bool:
	var p := _find_player()
	if p == null or get_tree() == null:
		return false
	var root := get_tree().current_scene
	if root == null:
		return false
	var best := 1.0e12
	var best_pos := Vector3.ZERO
	var found := false
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MultiMeshInstance3D and n.has_meta(&"SimpleGrassTextured"):
			var mmi := n as MultiMeshInstance3D
			if mmi.multimesh != null:
				for i in range(mini(mmi.multimesh.instance_count, 4000)):
					var w: Vector3 = mmi.global_transform * mmi.multimesh.get_instance_transform(i).origin
					var d := w.distance_squared_to(p.global_position)
					if d < best:
						best = d
						best_pos = w
						found = true
		for c in n.get_children():
			stack.append(c)
	if not found:
		return false
	p.global_position = Vector3(best_pos.x, p.global_position.y, best_pos.z)
	return true


# ==================== 风参数写入（逐材质 uniform） ====================
# ---------------------------------------------------------------- 参数写入

## 正常路径：从 "Weather" 节点（_find_weather_node 的结果）取风参数，然后写进两套材质。
## 参数：
##   w    —— "Weather" 节点（约定它暴露 wind / wind_gust / wind_turbulence / wind_speed / wind_dir）
##   delta—— 帧间隔（秒），只用于推进 _movement
##   ppos —— 玩家世界坐标，原样作为 player_pos / sgt_player_pos 的参照写进材质
##   pmov —— 这一帧玩家的水平位移（已被 limit_length(1.0) 截到 1 米内）
## 读取都做了类型保护：wind_dir 不是 Vector2 时退回 (1.0, 0.0)；其余走 float() 转换。
## 副作用：刷新 cur_* 五个对外量；按 delta 累积 _movement；调用 _write_ours() 与 _write_sgt()。
## 注意：属性名写错（或 Weather 上没这些属性）不会抛错，只会静默变成 0 风
##       （推测：float(null/无效值) 走默认 0，所以「风突然没了」先来查这里的属性名）。
func _apply_from_weather(w: Node, delta: float, ppos: Vector3, pmov: Vector3) -> void:
	var v: Variant = w.get("wind_dir")
	var dir2: Vector2 = v if v is Vector2 else Vector2(1.0, 0.0)
	var strength := float(w.get("wind"))
	var gust := float(w.get("wind_gust"))
	var turb := float(w.get("wind_turbulence"))
	var speed := float(w.get("wind_speed"))
	cur_dir = dir2
	cur_strength = strength
	cur_gust = gust
	cur_turbulence = turb
	cur_speed = speed
	# ★ 流动相位累积：x/z 用「风向 × 风速 × 时间」推进（1.2 是经验倍率，调大 -> 草流动更快），
	#   y 只按速度自身累积（0.6 倍，代表竖向的相位），三个分量最终一起进 shader 的 sgt_wind_movement。
	_movement.x += dir2.x * speed * delta * 1.2
	_movement.z += dir2.y * speed * delta * 1.2
	_movement.y += delta * speed * 0.6
	_write_ours(dir2, strength, gust, turb, speed, ppos)
	_write_sgt(dir2, strength, gust, turb, ppos, pmov)


## 兜底路径：场景里没有 "Weather" 节点时，用 @export fallback_* 顶上（保证草一直有风）。
## 参数 ppos / pmov 的含义与 _apply_from_weather 完全一致。
## 副作用：刷新 cur_*（取 fallback_* 的值）；推进 _movement；写两套材质。
## 注意：这里的 _movement 推进量是**每帧固定**的（`* 0.02`，不乘 delta），
##       所以帧率越高、风的相位走得越快 —— 这是历史写法，观感上可接受，
##       要「帧率无关」就得像 Weather 路径那样乘 delta（改动前先确认没人依赖旧速度）。
func _apply_fallback(ppos: Vector3, pmov: Vector3) -> void:
	var d := fallback_direction.normalized()
	cur_dir = d
	cur_strength = fallback_wind
	cur_gust = fallback_gust
	cur_turbulence = fallback_turbulence
	cur_speed = fallback_speed
	_movement.x += d.x * fallback_speed * 0.02
	_movement.z += d.y * fallback_speed * 0.02
	_write_ours(d, fallback_wind, fallback_gust, fallback_turbulence, fallback_speed, ppos)
	_write_sgt(d, fallback_wind, fallback_gust, fallback_turbulence, ppos, pmov)


## 写"我们的草 + 树"的逐材质 uniform。
## 参数：
##   dir2     —— 风向（水平 Vector2）
##   strength —— 风强度（相对量 0..1.5；树侧换算成米级 wind_force = 0.03 + k×0.30）
##   gust / turb / speed —— 阵风 / 湍流 / 风速
##   ppos     —— 玩家世界坐标（写进 player_pos）
## 副作用：写 _mats_ours（草与其它旧受风材质）与 _mats_tree（树）两组材质。
## 注意：
##   · 草用相对风场（wind_strength），树用米级风场（wind_force）—— 语义不同，别混写
##   · 树还会拿到 fast-tree 移植的 8 个参数（frequency/gust_speed/spatial_scale/bias/
##     flex_falloff/seed/force + 回退路径用的 wind_strength）
func _write_ours(dir2: Vector2, strength: float, gust: float, turb: float, speed: float, ppos: Vector3) -> void:
	_write_mats(_mats_ours, dir2, strength, gust, turb, speed, ppos, false)
	_write_mats(_mats_tree, dir2, strength, gust, turb, speed, ppos, true)


## 真正的逐材质写入。is_tree = true 时追加 fast-tree 风场参数。
func _write_mats(list: Array[ShaderMaterial], dir2: Vector2, strength: float, gust: float,
		turb: float, speed: float, ppos: Vector3, is_tree: bool) -> void:
	if list.is_empty():
		return
	# ★ 站着也保持分开：取「站立基础量」和「移动量」的较大者
	var bend_amt := maxf(stand_bend, _move_amt)
	# 站着时半径收小（只撑开贴身那一圈），走起来恢复全半径
	var radius_now := player_radius * lerpf(stand_radius_scale, 1.0, _move_amt)
	# ★ 树：把相对风力换算成"树梢顺风偏移（米）"
	#   公式照 fast-tree autoWind：strength = 0.03 + k×0.30（k 截到 0..1）
	#   —— 用"基线 + 比例"而不是纯比例，静风（weather.wind=0.18）时树冠仍有轻微呼吸，
	#      与源实现的档位一致；想要更夸张的狂风就调大 tree_force_per_wind
	var tree_force: float = tree_force_min + clampf(strength, 0.0, 1.0) * tree_force_per_wind
	if not tree_wind_enabled:
		tree_force = 0.0
	# ★ 角色头顶的**世界高度**：脚底 + 身高（跳跃时脚底抬高 -> 头顶自动变高）
	#   只在树的材质上写（草用的是自己的高度闸门，见 _sgt_gate_s）
	var head_y := ppos.y + _player_head_height()
	for m in list:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("wind_direction", dir2)
		m.set_shader_parameter("wind_strength", strength)
		m.set_shader_parameter("wind_gust", gust)
		m.set_shader_parameter("wind_speed", speed)
		m.set_shader_parameter("wind_turbulence", turb)
		m.set_shader_parameter("player_pos", ppos)
		m.set_shader_parameter("player_forward", _player_fwd)
		m.set_shader_parameter("player_radius", radius_now)
		m.set_shader_parameter("player_bend", player_bend)
		m.set_shader_parameter("player_spread", player_spread)
		m.set_shader_parameter("player_move", bend_amt)
		if is_tree:
			# ★ 头顶高度（世界 y）：着色器用它判断"这个枝叶是否低于头顶、能被角色顶到"
			m.set_shader_parameter("player_head_y", head_y)
			# ★ fast-tree 移植参数（assets/shaders/fast_tree_wind.gdshaderinc）
			m.set_shader_parameter("wind_force", tree_force)
			m.set_shader_parameter("wind_freq_scale", tree_frequency)
			m.set_shader_parameter("wind_variation", tree_variation)
			m.set_shader_parameter("wind_sway_variation", tree_sway_variation)
			m.set_shader_parameter("wind_gust_speed", tree_gust_speed)
			m.set_shader_parameter("wind_spatial_scale", tree_spatial_scale)
			m.set_shader_parameter("wind_bias", tree_bias)
			m.set_shader_parameter("wind_flex_falloff", tree_flex_falloff)
			m.set_shader_parameter("wind_seed", tree_seed)


## ★ 角色身高（米）：优先读玩家节点的 target_height（player.gd 会按角色档案自动缩放），
##   读不到 / 不是数值 / 节点已释放时，用 @export player_head_height 兜底。
## 返回：头顶相对脚底的高度（> 0）。
func _player_head_height() -> float:
	if _player != null and is_instance_valid(_player):
		var v: Variant = _player.get("target_height")
		if (v is float or v is int) and float(v) > 0.1:
			return float(v)
	return player_head_height


func _write_sgt(dir2: Vector2, strength: float, gust: float, turb: float,
		_ppos: Vector3, _pmov: Vector3) -> void:
	if _mats_sgt.is_empty():
		return
	var dir3 := Vector3(dir2.x, 0.0, dir2.y).normalized()
	# ★ 性能：@export 参数读取提到**循环外**（原来每个材质每帧读 4 次）
	var p_radius := sgt_player_bend_radius
	var p_radial := sgt_player_radial
	var p_bend := sgt_player_bend
	var p_gain := sgt_player_gain
	# ★★ 高度闸门：角色脚底高于附近草顶时，倒伏与分开都归零（草平滑回正）
	var g := _sgt_gate_s
	# ★ 阵风是「倍数叠加」而不是加法：强度 = 基础风 × (1 + 阵风量)，所以 gust=0 时等于纯基础风
	var wind_now := strength * (1.0 + gust)
	# ★ 站着只保留 25% 倒伏、走起来才全量；最后乘高度闸门 g（悬空时整项归零 -> 草回正）
	var bend_now := p_bend * lerpf(0.25, 1.0, _move_amt) * g
	for m in _mats_sgt:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("sgt_wind_direction", dir3)
		m.set_shader_parameter("sgt_wind_strength", wind_now)
		m.set_shader_parameter("sgt_wind_turbulence", turb)
		m.set_shader_parameter("sgt_wind_movement", _movement)
		# 玩家（倒伏 + 分开）：位置 + 这一帧的水平位移
		m.set_shader_parameter("sgt_player_pos", _sgt_player_pos)
		m.set_shader_parameter("sgt_player_mov", _sgt_player_step)
		# 走着时倒伏明显、站着时基本回弹（避免出生点一圈草永远是倒的）
		m.set_shader_parameter("sgt_player_bend", bend_now)
		m.set_shader_parameter("sgt_player_radial", p_radial * g)
		m.set_shader_parameter("sgt_player_bend_radius", p_radius)
		m.set_shader_parameter("sgt_player_gain", p_gain)
	# ★ 角色被草遮挡时的 1px 褐色轮廓（屏幕量在 _update_screen_metrics 里算好）
	#   写成独立函数：窗口尺寸变化时要能"立刻"重写全部材质，而不是等下一次风参数更新
	_apply_sgt_occlusion()
	# ★ 诊断台账（打印调试日志 打开时）：只在"确实在动"且每秒最多一次时打出来
	if not debug_sgt_player:
		return
	_dbg_player_t += get_process_delta_time()
	if _dbg_player_t > 1.0:
		_dbg_player_t = 0.0
		var step_len := _sgt_player_step.length()
		if step_len > 0.002:
			print("[Wind] SGT 人物倒伏: 材质 %d 个 ｜ 玩家 %s ｜ 位移 %.3f ｜ radius=%.2f radial=%.2f bend=%.2f ｜ 高度闸门=%.1f(附近 %d 株)" % [
					_mats_sgt.size(), str(_sgt_player_pos), step_len,
					sgt_player_bend_radius,
					sgt_player_radial,
					sgt_player_bend
					* lerpf(0.25, 1.0, _move_amt),
					_sgt_gate, _sgt_gate_pts])

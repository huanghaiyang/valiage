extends Node3D
## 植被燃烧控制器 —— 把「burn_foliage」材质贴到一株花草树木上，并跑完整段燃烧：
##   ① 斑点扩大（burn 0->1）② 焦黑停留 ③ 灰化消失（ash 0->1，然后隐藏）
##
## ★ 火星为什么从**表面**出来：火星的起点是从这株模型的**真实顶点**里采样出来的
##   （不是用一个包围盒随机撒点）。所以火只在枝叶表面上生出来，不会凭空飘在空处。
##
## ★ 摆动靠材质里的 vertex()（按高度加权的双频横向位移，每株 phase 不同），
##   所以必须用 material_override 接管外观 —— 用 overlay 的话几何体不会动。
##
## 用法：
##   var b := load("res://scripts/vfx/foliage_burn.gd").new()
##   get_parent().add_child(b)      # 放到场景里
##   b.burn_node(plant_node)        # 点着它

##
## ── 所属系统 ────────────────────────────────────────────────
##   VFX / 法术特效层（scripts/vfx/）。由法术脚本命中植被时**动态 new** 出来，
##   不是场景里预先摆好的节点；没有 @tool，只在运行时工作。
##
## ── 关键依赖 ────────────────────────────────────────────────
##   · 着色器：res://assets/shaders/burn_foliage.gdshader（叠加层/接管材质）
##   · 噪声：res://assets/textures/法术特效/Noise1_tiled.png（燃烧斑点）
##   · 外部材质：addons/simplegrasstextured 的草（MultiMeshInstance3D + 自定义 shader）、
##     assets/shaders/vegetation_wind.gdshader、tree_burn_keep* 等自带 burn 的着色器
##   · 风系统：scripts/wind.gd —— 它每帧只更新**它自己收集**的材质；
##     本文件复制出来的材质不在名单里，所以要用 _copy_wind_params 每帧抄参数
##   · 调用方：法术脚本先算好 burn_center / burn_radius / preset_mm / preset_indices，
##     再调用 burn_node()
##
## ── 主要对外接口 ────────────────────────────────────────────
##   · burn_node(node, delay) -> bool   点着一株植被（唯一入口）
##   · is_done() -> bool                本次燃烧是否收尾（供法术轮询回收）
##   · 供法术在点燃前赋值的变量：burn_center / burn_radius /
##     preset_mm / preset_indices / preset_delays
##   · 常量 WIND_PARAMS：需要从原材质抄到副本上的风参数名单
##
## ── 已知的坑 ────────────────────────────────────────────────
##   · 同一株重复点燃会互相覆盖 burn/ash → **闪烁**；现用节点 meta("burning")
##     与 _busy_instances 实例级占用表做防重入（见 burn_node / _claim_instances）。
##   · MultiMesh 的 use_custom_data 必须在**创建时**打开，运行时改会被引擎忽略。
##   · 逐实例燃烧只烧圈内实例，MultiMesh 节点**永远不能被隐藏**（否则成片草消失）。
##   · 材质副本必须每帧抄风参数，否则烧起来的草会立刻停止摆动。
##   · 状态记在节点 meta 上，场景重载即重置，不做持久化。
# ==================== 常量与导出参数 ====================
## 燃烧叠加层着色器：burn/ash 进度、斑点噪声、遮罩、以及 vertex() 摆动都在它里面。
const SHADER := "res://assets/shaders/burn_foliage.gdshader"
## 燃烧斑点的平铺噪声贴图；noise_scale 决定它在世界空间里的尺度（越大斑点越碎）。
const NOISE := "res://assets/textures/法术特效/Noise1_tiled.png"

@export var burn_time := 7.0          ## 斑点扩大所需时间（草/花用 ✓ 用户要求：草可以快 ✓）
@export var burn_time_tree := 18.0    ## ★ 树的燃烧全程（用户定稿 ✓）：**18 秒**
									  ##   （此前 26→52 太慢 ✓ 导致"树干还没烧到中间，树叶都烧完了"✗）
									  ##   判据：材质带 `burn_mode == "wood"`（插件写的 ✓）
									  ##   或 shader 是 tree_burn_keep* ✓ → 走这个时长 ✓
@export var ash_time_tree := 8.0      ## ★ 树烧完后的消失时长（同样更慢 ✓）
## ★★★ 崩毁（用户需求 ✓）：树木**烧透 + 焦黑停留**之后，用这段时间崩解消失 ✓
##   0 = 不崩（旧行为：焦黑树架永久留下）；> 0 = 枝条从上到下脱落 + 翻滚落地躺平
##   只对木质目标（tree_burn_keep*）生效；草/灌木仍走 ash 淡出 ✓
@export var collapse_time := 4.0
## ★ 枝条脱落窗口占 collapse_time 的比例（0.7 = 前 70% 时间内 L5→L1 依次脱落）
@export var branch_fall_window := 0.7
## 枝条（含碎枝）掉落重力（米/秒²）
@export var branch_gravity := 12.0
## 枝条落地后**缓慢缩小消失**所需时间（秒）
@export var branch_shrink_time := 1.5
## ★ 枝条落定（着地后静置一会再缩）所用时间（秒）
@export var branch_rest_time := 0.25
## 枝条下落时的翻滚时长（秒）：从竖直翻到 ≈90°（横躺）用这么久
@export var branch_rotate_time := 0.45
## ★ 树木本体消失后，枝条继续落地/缩小的收尾时长（秒）
##   没有这段的话，"崩毁到顶"的同帧会把还在半空的枝条一起藏掉 → 突然消失 ✗
@export var debris_linger := 2.5
@export var char_hold := 0.7          ## 全焦黑后停留
@export var ash_time := 3.3           ## 缩到消失所需时间（用户要求：原来 1.1 秒 ×3）
## ★ 烧透之后多久长回来（秒）。0 = 永久烧毁（不再恢复）。
##   消失与长回都走**缩放**（scale），过程中保持焦黑。
##   ★ 必须**大于火焰本身的时长**：单株草约 6.4 秒烧完（burn 2.4 + 保持 0.7 + 消失 3.3），
##     而「火焰灼烧」整体约 9.55 秒。原来设 8 秒 -> 火还在烧、草就开始长回来
##     （实测：火里长草）。所以默认给 18 秒，等火灭了再慢慢恢复。
@export var regrow_time := 18.0       ## 烧毁后"缓缓长回来"的时长（见 _process 里的 regrow 逻辑 ✓）
## 火星数量，同时也是火星池的大小（MultiMesh.instance_count）。
## 调大 → 同一时刻的火花更多，但每帧要写的实例变换也更多；调小 → 稀稀拉拉、远处看不见。
@export var spark_count := 18         ## 火星数量
## 单个火星的基准寿命（秒）。实际寿命 = 本值 × 每次随机 0.6~1.2。
## 调大 → 火星飞得更高更久，但池子固定，可见火花的密度会下降。
@export var spark_lifetime := 1.1
## 单颗火星的边长（米，QuadMesh 的正方形尺寸）。
## 调大 → 远处也看得见，但会糊成一片发光斑；0.03 在正常视距下约几个像素。
@export var spark_size := 0.03
## 摆动幅度（米，逐株再随机一次）——"类似不规则风动"
@export var sway_amt := 0.075
## 摆动频率（逐株 phase 不同，两频叠加）
@export var sway_freq := 1.8
## 燃烧斑点噪声的世界尺度（越大斑点越碎）
@export var noise_scale := 1.4
## ★ 是否接管原生材质。**默认 false（用 material_overlay）**：
##   接管会丢掉草的自定义着色器/透明裁剪，草片会变成不透明方块（观感=模型变大）。
##   需要"几何体真的摆动"时才开；开启后外观由本着色器决定。
@export var use_override := false
## 逐目标打印"材质透明度 / 是否拿到贴图 / 最终决定"——用来排查"某个物体烧得不对"
@export var debug_burn := true
## ★ 是否允许烧 MultiMesh（addon 的**整片**草）。
##   默认 **false**：MultiMesh 是一个节点覆盖一大片/全图，材质是整节点共享的，
##   整体烧会把**整张地图的草**一起涂黑（实测截图：全图草地全黑 + 红边）。
##   正确做法是"逐实例燃烧"（INSTANCE_CUSTOM），尚未实现 -> 先关掉。
@export var burn_multimesh := true

# ==================== 运行时状态 ====================
## 本次燃烧的目标根节点（burn_node 的第一个参数）。网格/MultiMesh/材质都从它递归收集；
## 目标被释放时 _process 会提前退出，不会因此崩溃。
var _target: Node3D = null
## 目标子树里收集到的所有 MeshInstance3D（树干/树叶等普通网格体，深度优先顺序）。
var _meshes: Array[MeshInstance3D] = []
var _multimeshes: Array[MultiMeshInstance3D] = []   ## addon 的草丛是 MultiMesh 节点
## 接管/叠加前的材质快照：[{n=节点, m=原 material_override, o=原 material_overlay}...]。
## 只有"非保留型"目标收尾时才用它还原（见 _finish）；保留型树木刻意不还原。
var _prev_override: Array = []
## 本株的燃烧叠加层/接管材质（由 burn_foliage.gdshader 现场创建）。
## 只有"叠加层/接管"路线会创建它；逐实例路线与材质内建 burn 路线下它保持 null。
var _mat: ShaderMaterial = null
## "材质内建 burn"路线上，为每个网格面复制出来的材质副本（逐株独立，不污染共享 .tres）。
## 与 _shader_src 一一对应；逐帧只写这些副本的 burn/ash，并抄风参数。
var _shader_mats: Array[ShaderMaterial] = []
## ★ 逐实例燃烧：要烧的 MultiMesh 实例列表 [{mmi, i, phase, delay, done}]
## ★ 风系统每帧只写**它自己收集的材质**（scripts/wind.gd 的 _mats_ours/_mats_sgt）；
##   我们为燃烧**复制**出来的材质不在名单里 -> 烧起来的草会停止摆动。
##   所以每帧把风参数从**原材质**抄到副本上（原材质一直由风系统更新，抄过来就是实时的）。
const WIND_PARAMS := [
	"wind_direction", "wind_strength", "wind_gust", "wind_speed", "wind_turbulence",
	"player_pos", "player_forward", "player_radius", "player_bend", "player_spread",
	"player_move",
	"sgt_wind_direction", "sgt_wind_strength", "sgt_wind_turbulence", "sgt_wind_movement",
	"sgt_player_position", "sgt_player_mov",
	# ★ 2026-10-08：SGT 草的人物倒伏/分开也是逐材质 uniform（改见 grass.gdshaderinc）
	"sgt_player_pos", "sgt_player_mov", "sgt_player_bend", "sgt_player_radial", "sgt_player_bend_radius",
]
## 与 _shader_mats 一一对应的"原材质"（风参数的来源）
var _shader_src: Array[ShaderMaterial] = []

## 逐实例待烧清单：[{mmi, i, phase, delay, done(, done_t)}]（三项含义见 _start_multimesh_burn）。
## done_t 是"进入长回阶段"的时刻，惰性写入；清单非空即代表本次走逐实例路线。
var _mm_burn: Array = []
var _reported := false            ## 1 秒的状态汇报只打一次
## ★ 本控制器正在烧的实例集合：{MultiMeshInstance3D 的 instance_id -> {实例下标: true}}
##   用途（修复"第二次施法点不着 SGT 草"）：SGT 的整片草是**一个节点**，
##   而 `burning` meta 是**节点级**的 —— 第二发火焰哪怕打在草地上完全不同的位置，
##   也会被"该目标已在燃烧中"挡掉。改成按**实例**判断：只有真正重叠的实例才算重复。
##   （树这类 MeshInstance3D 仍按节点判断，行为不变。）
var _mm_owner: Dictionary = {}
## 被我们打开 use_custom_data 的 MultiMesh（收尾时还原，避免改动 addon 的内存布局）
var _mm_custom_on: Array = []
## 由法术在点燃前设置：只烧这个圆内的实例（0 半径 = 不筛）
var burn_center := Vector3.ZERO
var burn_radius := 0.0
## ★ 法术已经用"先按块、再查块内"算好的实例表（省掉控制器再全量扫一遍）
var preset_mm: MultiMeshInstance3D = null
var preset_indices: Array = []
## ★ 每实例的**点燃延迟**（秒，与 preset_indices 一一对应）。空 = 用随机错开。
##   火焰推进靠它让草按"离角色的距离"依次烧起来（波前），而不是整片一起黑。
var preset_delays: Array = []
## 内部计时（秒）。注意 delay > 0 时它会被设成**负值**，_process 先空转、到 0 才开始烧。
## 收尾标记：_finish 置 true，is_done() 直接返回它；置真后 _process 不再推进。
## 本株的随机相位（0~TAU）：让每株的斑点扩散与摆动互不同步，同批点燃也不会整齐划一。
var _t := 0.0
var _done := false
var _phase := 0.0

# 火星（MultiMesh + 自己驱动：数量少、需要精确落在表面上）
var _sparks: MultiMeshInstance3D = null
var _sp := PackedVector3Array()       ## 位置（本节点局部坐标）
var _sv := PackedVector3Array()       ## 速度
var _sl := PackedFloat32Array()       ## 剩余寿命
var _surface := PackedVector3Array()  ## 表面点池（取自真实顶点）
## ★ 本目标是不是"木质保留型"（树）——决定走崩毁时间轴还是原 ash 淡出（见 _process）
var _is_tree := false
## ★★ 崩毁枝条（用户要求 ✓：L5→L1 从上到下掉落，**不使用小方块**）
##   直接拿树本身的 Bark_Branch_L* 网格做"脱落替身"，掉下来的是真实枝条 ✓
##   ★ 每层（Bark_Branch_Ln）在场景里只有**一个**网格 → 整层是一个刚体，
##     不拆的话同层所有枝条会"同时"掉 ✗（用户实测反馈）→ 构建期按**连通分量**
##     拆成一根一根，每根有自己的随机脱落时刻/翻滚/落地 ✓
##   全部状态在**控制器局部坐标**里算（控制器被摆到目标位置）。
var _sec_src: Array[MeshInstance3D] = []      ## 所属原始层节点（崩毁开始时整层隐藏）
var _sec_layer := PackedInt32Array()          ## 所属层号（5=L5 ... 1=L1，决定先后优先级）
var _sec_part_mesh: Array[Mesh] = []          ## 拆出来的一根枝条网格（构建期生成）
var _sec_part_mat: Array[Material] = []       ## 该层共用的材质副本（wind 关掉、crumble 恒 0）
var _sec_dups: Array[MeshInstance3D] = []     ## 脱落后的替身（挂在控制器下）
var _sec_mats: Dictionary = {}                ## 枝条的燃烧材质副本（命中 = 属于脱落段，crumble 恒为 0）
var _sec_t := PackedFloat32Array()            ## 计划脱落时刻（相对崩毁开始，秒）
var _sec_state := PackedByteArray()           ## 0=待脱落 1=下落 2=落定 3=缩小消失 4=结束
var _sec_rest := PackedFloat32Array()         ## 落定/缩小阶段已用时间
var _sec_vel := PackedFloat32Array()          ## 下落速度（向下为正，米/秒）
var _sec_drop := PackedFloat32Array()         ## 已下落距离（米）
## ★ 这根枝条要落多远才碰地（米）＝ 它在原始姿态下**最低顶点离地高度**（已含树缩放）。
##   小于 0（本来就有枝梢埋在地面下）按 0 处理 → 原地翻倒，不会再往下沉 ✗
var _sec_floor := PackedFloat32Array()
var _sec_basis: Array[Basis] = []             ## 枝条的局部 basis（含主场景树的缩放）
var _sec_origin := PackedVector3Array()       ## 枝条原始局部原点
var _sec_pivot := PackedVector3Array()        ## 旋转支点（控制器局部 = m0 * 包围盒下沿中心）
## ★ 支点在**网格局部**的坐标。绕支点旋转必须用「世界支点 - nb * 局部支点」，
##   否则 angle=0 时 origin 不等于原始位置 → 崩毁第一帧会突然跳一下（用户实测 ✗）
var _sec_pivot_local := PackedVector3Array()
## ★★ 下落旋转（用户要求 ✓：掉落过程中带旋转，最终横躺在地面上）
var _sec_axis: Array[Vector3] = []            ## 随机水平旋转轴（单位向量）
var _sec_angle := PackedFloat32Array()        ## 已转过的角度（弧度）
var _sec_spin := PackedFloat32Array()         ## 角速度（弧度/秒）
var _sec_target := PackedFloat32Array()       ## 目标转角（≈90° → 树冠枝条摊平成横躺）
var _sec_pts: Array[PackedVector3Array] = []  ## 该根枝条的顶点（**网格局部**；判落地/算缩小支点）
var _sec_land_b: Array[Basis] = []            ## 着地后的最终 basis
var _sec_land_o := PackedVector3Array()       ## 着地后的最终 origin
var _sec_shrink_pivot := PackedVector3Array() ## 缩小支点（落地后地面上的水平中心）
## ★ 崩毁开始时（烧透 + 焦黑停留结束）才真正生成 462 根枝条替身：
##   提前生成会让枝条在整个燃烧期都不跟风摆 ✗；延迟生成则只在崩毁瞬间花一帧 ✓
var _sec_spawned := false
## ★ 崩毁到顶后的枝条收尾阶段：树木本体已隐藏，等枝条落定/缩小完再真正 _finish
var _collapse_tail := false
var _tail_time := 0.0
## 本控制器专用的随机源（_ready 里 randomize）。
## 斑点相位、摆动幅度、火星散布、兜底点燃延迟都取它；每控制器一份，互不干扰。
var _rng := RandomNumberGenerator.new()


# ==================== 生命周期 ====================
## 引擎回调：随机化内部随机源，并把 _process **默认关掉**——没点燃的控制器不该每帧跑。
## 参数：无。返回：无。副作用：只改自身状态（不动场景树、不发信号、不读文件）。
## 真正打开 _process 的是 burn_node() 成功之后；_process 自己会在烧完时再关回去。
func _ready() -> void:
	set_process(false)
	_rng.randomize()


## 本控制器将要烧的实例下标（按 MultiMeshInstance3D 分组；没有逐实例目标时返回空）
func _planned_mm_indices() -> Dictionary:
	var out: Dictionary = {}
	if _target is MultiMeshInstance3D:
		# SGT 草：t 本身就是那片草 -> 用预设表（法术算好的圈内实例）
		var mmi := _target as MultiMeshInstance3D
		if preset_mm == mmi and not preset_indices.is_empty():
			var s: Dictionary = {}
			for k in preset_indices:
				s[int(k)] = true
			out[mmi.get_instance_id()] = s
			return out
		# 没有预设表：按圆心/半径现算（与 _start_multimesh_burn 的兜底一致）
		if mmi.multimesh != null:
			var s2: Dictionary = {}
			for i in range(mmi.multimesh.instance_count):
				var w: Vector3 = mmi.global_transform * mmi.multimesh.get_instance_transform(i).origin
				if burn_radius <= 0.0 or Vector2(w.x - burn_center.x, w.z - burn_center.z).length() <= burn_radius:
					s2[i] = true
			out[mmi.get_instance_id()] = s2
		return out
	# 目标内部含 MultiMesh（例如火焰烧的是父节点）
	if _target != null:
		for mmi in _multimeshes:
			if mmi.multimesh == null:
				continue
			var s3: Dictionary = {}
			for i in range(mmi.multimesh.instance_count):
				var w2: Vector3 = mmi.global_transform * mmi.multimesh.get_instance_transform(i).origin
				if burn_radius <= 0.0 or Vector2(w2.x - burn_center.x, w2.z - burn_center.z).length() <= burn_radius:
					s3[i] = true
			out[mmi.get_instance_id()] = s3
	return out


# ==================== 跨控制器实例占用（实例级防重入） ====================
## 这些实例里是否有别的控制器正在烧（跨控制器共享，静态表）
static var _busy_instances: Dictionary = {}

## 检查 planned 里的实例是否**已经被别的控制器占用**（实例级防重入的查询步骤）。
## 参数 planned：{MultiMeshInstance3D 的 instance_id: {实例下标: true}}，由 _planned_mm_indices 生成。
## 返回：true = 无重叠、可以烧；false = 有实例正在烧，调用方应当放弃本次点燃。
## 副作用：**只读**共享表 _busy_instances，不改任何状态（登记在 _register_instances）。
## 注意：只要**任一**实例重叠就整体放弃（同一片草允许第二发点燃它自己那块地）。
func _claim_instances(planned: Dictionary) -> bool:
	for mid in planned:
		var busy: Dictionary = _busy_instances.get(mid, {})
		for i in (planned[mid] as Dictionary):
			if busy.get(i, false):
				return false      # 有重叠 -> 视为重复点燃
	return true


## 登记本次**真正要烧**的实例：写进跨控制器共享的 _busy_instances，同时记进本控制器的
## 账本 _mm_owner（_release_instances 靠它归还）。
## 参数 planned：同 _claim_instances。返回：无。
## 副作用：修改 static 共享表；_mm_owner 按 MultiMesh 分桶记录实例下标。
## 注意：必须"先 _claim_instances 成功、再 _register_instances"，否则会抢占别人的草。
func _register_instances(planned: Dictionary) -> void:
	for mid in planned:
		var busy: Dictionary = _busy_instances.get(mid, {})
		for i in (planned[mid] as Dictionary):
			busy[i] = true
		_busy_instances[mid] = busy
	for e in _mm_burn:
		var mmi := e["mmi"] as MultiMeshInstance3D
		if mmi == null:
			continue
		var mid2 := mmi.get_instance_id()
		if not _mm_owner.has(mid2):
			_mm_owner[mid2] = {}
		(_mm_owner[mid2] as Dictionary)[int(e["i"])] = true


## 归还本控制器占用的全部实例（收尾时由 _finish 调用，与 _register_instances 配平）。
## 参数：无。返回：无。
## 副作用：从共享表 _busy_instances 删除对应下标（桶空了就删桶），清空 _mm_owner；
##   节点已失效时跳过（不会报错）。
## 注意：漏掉这一步会造成**占用泄漏**——同一片草以后再也点不着，且没人报错。
func _release_instances() -> void:
	for e in _mm_burn:
		var mmi := e["mmi"] as MultiMeshInstance3D
		if mmi == null or not is_instance_valid(mmi):
			continue
		var mid := mmi.get_instance_id()
		var busy: Dictionary = _busy_instances.get(mid, {})
		busy.erase(int(e["i"]))
		if busy.is_empty():
			_busy_instances.erase(mid)
		else:
			_busy_instances[mid] = busy
	_mm_owner.clear()


# ==================== 点燃入口 ====================
## 点着一株植被 —— 本文件唯一的公开入口。
## 参数 n：目标根节点。可以是单个 MeshInstance3D，也可以含多个网格的父节点；
##   传 MultiMeshInstance3D（addon 的整片草）时走**逐实例燃烧**分支。
## 参数 delay：点燃延迟（秒）。>0 时把内部计时 _t 设成 -delay，使这株比同伴晚烧起来
##   （法术用 preset_delays 做"火焰波前"）。默认 0.0（立即烧）。
## 返回：true = 已接管并开始燃烧；false = 跳过。跳过原因：找不到网格 /
##   该节点已在燃烧 / 已烧毁 / burn_multimesh 关闭 / 圈内实例与别处重叠 /
##   草材质不支持 INSTANCE_CUSTOM / burn_foliage.gdshader 加载失败。
## 副作用（成功时）：递归收集网格、改材质（material_overlay 或 material_override）、
##   创建火星子节点 "BurnSparks"、登记实例占用、可选地写实例 custom data、开启 _process。
## 注意：**失败也可能已经写了副作用**——节点级目标的 meta("burning") 在几何体检查之前
##   就设好了（见函数中段），所以调用方不要假设返回 false 就等于什么都没改。
## 点着一株植被。返回是否成功（找不到网格就失败）
func burn_node(n: Node3D, delay: float = 0.0) -> bool:
	# ★★ 按目标分档燃烧时长（用户要求 ✓）：**草可以快 ✓ 树要慢慢慢 ✓**
	#   判据复用 `_target_is_keep()` ✓：材质带 `burn_mode == "wood"` ✓（插件写的 ✓）
	#   或 shader 是 `tree_burn_keep*` ✓ → 走 burn_time_tree / ash_time_tree ✓
	#   （草是 MultiMesh ✓ 判据返回 false ✓ → 保持 burn_time 快节奏 ✓）
	_target = n
	# ★★ 防重入（修复"树枝闪烁"✗）：同一目标**已有燃烧在跑**时直接跳过 ✓
	#   重复施法会在同一棵树上叠加多个燃烧器 ✓ → 每帧互相覆盖 burn/ash → **闪烁** ✓✓
	#   ★★ 修复"第二次施法点不着 SGT 草"：SGT 的整片草是**一个节点**，而 `burning`
	#     meta 是**节点级**的 —— 第二发火焰哪怕打在完全不同的草地上也会被挡掉。
	#     所以对 MultiMesh 目标改用**实例级**判定（见 _claim_instances）：
	#     整片草允许第二发点燃它自己那块地，只有**实例真的重叠**才算重复。
	var mm_target: bool = n is MultiMeshInstance3D
	if n != null and not mm_target and n.has_meta("burning"):
		print("[燃烧] 该目标已在燃烧中 ✓ 跳过重复点燃：%s" % n.name)
		return false
	# ★★★ 已烧毁（用户要求 ✓）：**直接跳过** ✗ 不再播一遍燃烧 ✓
	#   为什么要跳 ✗：第二次施法会**从网格原始材质重新复制一份** ✓（burn=0 ✓）
	#   → 看上去"树叶树枝树干又还原了" ✓✓（用户实测 ✓）
	#   跳过之后，节点上仍挂着第一次冻结好的焦黑材质 ✓ → **保持焦黑** ✓✓
	#   状态记在节点 meta 上 ✓（本次运行内有效 ✓ 场景重载会重置 ✓ 需要持久化再说 ✓）
	#   ★ MultiMesh（草）不适用：它是逐实例燃烧、还会长回来，不该被"已烧毁"永久锁死。
	if n != null and not mm_target and n.has_meta("burned_out"):
		print("[燃烧] 该目标**已烧毁** ✓ 不再燃烧（保持焦黑）：%s" % n.name)
		return false
	if n != null and not mm_target:
		n.set_meta("burning", true)
	if _target_is_keep():
		_is_tree = true
		burn_time = burn_time_tree
		ash_time = ash_time_tree
		print("[燃烧] 树/木质 ✓ 时长 = %.1fs（烧）+ %.1fs（消失）｜ %s" % [
				burn_time, ash_time, n.name])
	if n == null or not is_instance_valid(n):
		return false
	_target = n
	_meshes.clear()
	_multimeshes.clear()
	var st := [n]
	while st.size() > 0:
		var cur: Node = st.pop_back()
		if cur is MeshInstance3D:
			_meshes.append(cur)
		elif cur is MultiMeshInstance3D:
			# ★ addons/simplegrasstextured 的 grass.gd 就是 MultiMeshInstance3D：
			#   整片草丛是一个节点，材质也是整体接管（摆动按实例作用）。
			_multimeshes.append(cur)
		for c in cur.get_children():
			st.append(c)
	if _meshes.is_empty() and _multimeshes.is_empty():
		return false
	if not _multimeshes.is_empty() and _meshes.is_empty():
		if not burn_multimesh:
			if debug_burn:
				print("[植被燃烧] %s 跳过：burn_multimesh 关闭" % n.name)
			return false
		# ★ 逐实例燃烧：整片草是一个节点，但**每个实例单独一份进度**（INSTANCE_CUSTOM），
		#   所以只有圈内的那几簇会烧，不会把全图草一起涂黑。
		#   ★ 实例级防重入：本次要烧的实例若与**别的控制器**正在烧的重叠 -> 跳过
		#     （整片草允许第二发点燃它自己那块地，只有真的重叠才算重复）。
		var planned := _planned_mm_indices()
		if not _claim_instances(planned):
			if debug_burn:
				print("[植被燃烧] %s 跳过：要烧的实例与另一处燃烧重叠" % n.name)
			return false
		_meshes.clear()
		global_position = Vector3.ZERO
		if not _start_multimesh_burn():
			if debug_burn:
				print("[植被燃烧] %s 跳过：找不到支持 INSTANCE_CUSTOM 的草材质" % n.name)
			return false
		# ★ 登记这次真正要烧的实例（同一份 planned），供其他控制器判重叠
		_register_instances(planned)
		_collect_surface_points()
		_build_sparks()
		set_process(true)
		if debug_burn:
			print("[植被燃烧] %s | 走**逐实例燃烧**（INSTANCE_CUSTOM）：%d 个实例在圈内"
					% [n.name, _mm_burn.size()])
		return true
	_phase = _rng.randf() * TAU
	# 量一下这株的高度/范围：给摆动做高度加权、给火星找表面
	var lo := 1e9
	var hi := -1e9
	for mi in _meshes:
		if mi.mesh == null:
			continue
		var aabb := mi.mesh.get_aabb()
		var xf := mi.global_transform
		# 取 AABB 的 8 个角点：i 的三个二进制位分别代表 x/y/z 方向是否加 size，
		# 遍历完只留下**世界 Y 的最低/最高**（给摆动做高度加权用，别的分量不关心）。
		for i in range(8):
			var c2 := aabb.position + Vector3(
					aabb.size.x if (i & 1) != 0 else 0.0,
					aabb.size.y if (i & 2) != 0 else 0.0,
					aabb.size.z if (i & 4) != 0 else 0.0)
			var w := xf * c2
			lo = minf(lo, w.y)
			hi = maxf(hi, w.y)
	for mmi in _multimeshes:
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		# 整片草：用基础网格高度做摆动加权即可（逐实例高度加权意义不大）
		var ma := mmi.multimesh.mesh.get_aabb()
		var mx := mmi.global_transform
		lo = minf(lo, (mx * Vector3(ma.position.x, ma.position.y, ma.position.z)).y)
		hi = maxf(hi, (mx * (ma.position + ma.size)).y)
	if hi < lo:
		lo = 0.0
		hi = 1.0
	var height := maxf(hi - lo, 0.2)
	# ★ 若目标材质用的着色器**自带 burn**（如 assets/shaders/vegetation_wind.gdshader），
	#   就走"改材质内建 burn"这条路 —— 对**不透明植被**天然正确：
	#   不需要遮罩/轮廓/透明度处理，未烧部分保持原样，烧过部分在它自己的光照里变焦。
	if _first_burn_material() != null:
		global_position = n.global_position
		_apply_in_shader_burn()
		_build_collapse_sections()    # ★ 树木：登记 L5→L1 枝条，供崩毁时依次脱落
		_collect_surface_points()      # ★ 不能漏：否则 _surface 为空 -> 火星取模崩溃
		_build_sparks()
		set_process(true)
		if debug_burn:
			print("[植被燃烧] %s | 走**材质内建 burn**（复制材质，逐株独立）" % _target.name)
		return true
	# 材质
	_mat = ShaderMaterial.new()
	var sh := load(SHADER) as Shader
	if sh == null:
		return false
	_mat.shader = sh
	var nt := load(NOISE) as Texture2D
	if nt != null:
		_mat.set_shader_parameter("noise_tex", nt)
	_mat.set_shader_parameter("phase", _phase)
	_mat.set_shader_parameter("height_ref", height)
	# ★ 显式写入摆动参数：不写的话 get_shader_parameter 取回 null（外部核对/调参都读不到）
	_mat.set_shader_parameter("sway_amt", sway_amt * _rng.randf_range(0.8, 1.3))
	_mat.set_shader_parameter("sway_freq", sway_freq)
	_mat.set_shader_parameter("noise_scale", noise_scale)
	_mat.set_shader_parameter("burn", 0.0)
	_mat.set_shader_parameter("ash", 0.0)
	# ★ 叠加模式：只在烧过的地方变黑，未烧处透明 -> 原外观（含透明裁剪）不受影响
	_mat.set_shader_parameter("overlay_mode", not use_override)
	# 尽量沿用原本的贴图（StandardMaterial3D 有 albedo_texture 就传进来）
	var albedo := _find_albedo()
	if albedo != null:
		_mat.set_shader_parameter("albedo_tex", albedo)
		_mat.set_shader_parameter("use_albedo", true)
		# ★ 轮廓遮罩：**优先用专门的透明度贴图**（alpha_tex），它才是草的轮廓；
		#   albedo 常常是 JPG（没有 alpha），拿它当遮罩等于没遮。
		var fmask := _first_material()
		var alpha_tex := _alpha_texture_from_material(fmask)
		var mask: Texture2D = alpha_tex if alpha_tex != null else albedo
		_mat.set_shader_parameter("mask_tex", mask)
		# ★ 通道必须跟原着色器一致（bermuda 草用 .r，不是 .a）
		var mc := _mask_channel_of(fmask, _alpha_uniform_of(fmask))
		_mat.set_shader_parameter("mask_channel", mc)
	# ★ 透明度配置按**原材质**来（不透明就不遮罩；Alpha 混合就不硬裁；裁剪材质用它的阈值）
	var fmat := _first_material()
	var tr := _transparency_from_material(fmat)
	# ★ 安全阀：卡片型（透明）材质**但拿不到贴图**时，**不画**叠加层。
	#   硬画的结果就是"整张卡片被涂成半透明色块"（用户实测：大块半透明红矩形）。
	var is_transparent := _is_transparent_material(fmat)
	var has_alpha_tex := _alpha_texture_from_material(_first_material()) != null
	var skip_overlay := is_transparent and albedo == null and not has_alpha_tex
	_mat.set_shader_parameter("use_mask", bool(tr["use_mask"]) and albedo != null)
	_mat.set_shader_parameter("force_opaque", bool(tr["force_opaque"]))
	_mat.set_shader_parameter("scissor_enabled", bool(tr["scissor_enabled"]))
	_mat.set_shader_parameter("scissor", float(tr["scissor"]))
	if debug_burn:
		print("[植被燃烧] %s | 材质=%s | 透明=%s | 贴图=%s | 遮罩=%s | 裁剪=%s(%.2f) | %s" % [
				_target.name, fmat.get_class() if fmat != null else "无",
				str(is_transparent), str(albedo != null), str(tr["use_mask"]),
				str(tr["scissor_enabled"]), float(tr["scissor"]),
				"跳过叠加（拿不到轮廓）" if skip_overlay else "正常"])
	if skip_overlay:
		# 只保留火星，不画形体叠加
		set_process.call_deferred(false)
		_build_sparks_only()
		return true
	# 接管外观（摆动需要几何体真的动）
	_prev_override.clear()
	if use_override:
		# 接管：几何体会真的被摆动改写，但外观由本着色器决定
		for mi in _meshes:
			_prev_override.append({"n": mi, "m": mi.material_override, "o": mi.material_overlay})
			mi.material_override = _mat
		for mmi in _multimeshes:
			_prev_override.append({"n": mmi, "m": mmi.material_override, "o": mmi.material_overlay})
			mmi.material_override = _mat
	else:
		# 叠加：保留原生材质（草的透明裁剪/自定义着色器都在），只叠一层焦黑与余烬
		for mi in _meshes:
			_prev_override.append({"n": mi, "m": mi.material_override, "o": mi.material_overlay})
			mi.material_overlay = _mat
		for mmi in _multimeshes:
			_prev_override.append({"n": mmi, "m": mmi.material_override, "o": mmi.material_overlay})
			mmi.material_overlay = _mat
	# ★ 顺序很重要：**先把控制器摆到目标位置**，再采样表面点。
	#   反过来写的话，采样时用的是"原点的逆变换"（世界坐标），之后控制器又被移走，
	#   火星会被目标位置二次偏移 -> 飘到别处、看不见（用户实测："火星没有"）。
	global_position = n.global_position
	# 表面点 + 火星
	_collect_surface_points()
	_build_sparks()
	set_process(true)
	if delay > 0.0:
		_t = -delay
	return true


# ==================== 材质解析工具（贴图 / 透明度 / 遮罩通道） ====================
## 找"原贴图"当遮罩：用它的 alpha 裁出植被真实轮廓（否则烧出来是方块斑块）。
## ★ 草的材质是**自定义 ShaderMaterial**（.tres），没有 albedo_texture 这种固定名字，
##   所以要枚举它的参数、挑出贴图参数 —— 这样"取不到贴图"的问题就解决了。
func _find_albedo() -> Texture2D:
	for mi in _meshes:
		var m: Material = mi.material_override
		if m == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			m = mi.mesh.surface_get_material(0)
		var t := _texture_from_material(m)
		if t != null:
			return t
	for mmi in _multimeshes:
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		for s in range(mmi.multimesh.mesh.get_surface_count()):
			var t2 := _texture_from_material(mmi.multimesh.mesh.surface_get_material(s))
			if t2 != null:
				return t2
	return null


## ★ 读取原材质的**透明度配置** —— 燃烧叠加层必须和它一致，否则：
##   · 不透明材质（树干）被错误遮罩 -> 该烧的地方没烧
##   · Alpha 混合的软边被硬切（discard）-> 叶子/草的边缘像被剪刀剪掉
##   · 裁剪材质的真实阈值被我的写死值(0.35)覆盖 -> 形状对不上
func _transparency_from_material(m: Material) -> Dictionary:
	# 默认：当裁剪处理（最保守，能挡住"整张卡片变黑斑"）
	var out := {"scissor_enabled": true, "scissor": 0.35, "force_opaque": false, "use_mask": true}
	if m == null:
		return out
	if m is StandardMaterial3D:
		var sm := m as StandardMaterial3D
		out["force_opaque"] = _get_bool(sm, "albedo_texture_force_opaque")
		out["scissor"] = sm.alpha_scissor_threshold
		match sm.transparency:
			BaseMaterial3D.TRANSPARENCY_DISABLED:
				# 完全不透明（树干/石头）：整块网格就是轮廓，不需要贴图遮罩
				out["use_mask"] = false
				out["scissor_enabled"] = false
			BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				out["use_mask"] = true
				out["scissor_enabled"] = true
				out["scissor"] = maxf(sm.alpha_scissor_threshold, 0.01)
			BaseMaterial3D.TRANSPARENCY_ALPHA:
				# Alpha 混合：**不能裁剪**，否则软边被硬切；只按 alpha 淡出
				out["use_mask"] = true
				out["scissor_enabled"] = false
			_:
				pass
		return out
	if m is ShaderMaterial:
		var shm := m as ShaderMaterial
		if shm.shader != null:
			# 自定义着色器读不到 transparency 枚举，但通常有 scissor/cutoff/threshold 这类 uniform
			for u in shm.shader.get_shader_uniform_list():
				var un := String(u.get("name", "")).to_lower()
				if un.contains("scissor") or un.contains("cutoff") \
						or un.contains("alpha_cut") or un.contains("threshold"):
					var v: Variant = shm.get_shader_parameter(String(u.get("name", "")))
					if v is float or v is int:
						out["scissor_enabled"] = true
						out["scissor"] = clampf(float(v), 0.01, 0.99)
						return out
	return out


## 取第一个可用材质（透明度配置以它为准）
## ★★★ 专供"走哪条燃烧路线"判定用：找第一个**真的带 burn 参数**的材质 ✓
##   为什么要单独一个（不能直接用 _first_material ✗）：
##   `_first_material()` 只保证"第一个非空材质"✗ —— 而目标子树里常常混着
##   **不带 burn 的装饰网格**（实测：Wind 自动加载的 `FootRing` 会把脚底圈挂到
##   当前场景下 ✓ 它的 material_override 是一个没有 burn 的叠加着色器 ✓）
##   → `_first_material()` 返回它 ✗ → `_shader_has_burn` 判 false ✗
##   → 整棵树**误走"叠加层"路线** ✓（明明自己的 shader 有 burn ✓ 却不走内置路线 ✓）
##   → 逐面 burn 副本一份都不建 ✓ 烧起来只能靠一层叠加，叶子/枝干的分类冻结也失效 ✓
##   本函数逐个 surface 找 ✓ 找到带 burn 的就返回 ✓ 找不到返回 null ✓
func _first_burn_material() -> Material:
	for mi in _meshes:
		if mi == null or not is_instance_valid(mi):
			continue
		if _shader_has_burn(mi.material_override):
			return mi.material_override
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var ov: Material = mi.get_surface_override_material(s)
			if _shader_has_burn(ov):
				return ov
			var sm2: Material = mi.mesh.surface_get_material(s)
			if _shader_has_burn(sm2):
				return sm2
	for mmi in _multimeshes:
		if mmi == null or not is_instance_valid(mmi):
			continue
		if _shader_has_burn(mmi.material_override):
			return mmi.material_override
		if mmi.multimesh != null and mmi.multimesh.mesh != null:
			for s in range(mmi.multimesh.mesh.get_surface_count()):
				var m3: Material = mmi.multimesh.mesh.surface_get_material(s)
				if _shader_has_burn(m3):
					return m3
	return null


func _first_material() -> Material:
	for mi in _meshes:
		var m: Material = mi.material_override
		if m == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			m = mi.mesh.surface_get_material(0)
		if m != null:
			return m
	for mmi in _multimeshes:
		# ★ 节点的 material_override 别忘了（漏了就会报"材质=无"，安全阀也跟着失效）
		if mmi.material_override != null:
			return mmi.material_override
		if mmi.multimesh != null and mmi.multimesh.mesh != null \
				and mmi.multimesh.mesh.get_surface_count() > 0:
			var m2 := mmi.multimesh.mesh.surface_get_material(0)
			if m2 != null:
				return m2
	return null


## 这个材质用的着色器是否自带 burn 参数（本项目给 vegetation_wind.gdshader 加过）
func _shader_has_burn(m: Material) -> bool:
	if m == null or not (m is ShaderMaterial):
		return false
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return false
	for u in sm.shader.get_shader_uniform_list():
		if String(u.get("name", "")) == "burn":
			return true
	return false


## 该材质用的着色器是否支持"逐实例燃烧"（读 INSTANCE_CUSTOM）
func _shader_supports_instance_burn(m: Material) -> bool:
	if m == null or not (m is ShaderMaterial):
		return false
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return false
	# ★ 不能只看 shader.code：addon 的 grass 变体把代码放在 **include** 里，
	#   变体自身源码里没有 INSTANCE_CUSTOM（实测会永远判定失败 = 逐实例燃烧不触发）。
	#   正确做法是看 uniform 表 —— include 里的 uniform 会合并进 shader 的 uniform 列表。
	for u in sm.shader.get_shader_uniform_list():
		var un := String(u.get("name", ""))
		if un == "burn_char_color" or un == "burn_ember_gain":
			return true
	return sm.shader.code.contains("INSTANCE_CUSTOM")


# ==================== 逐实例燃烧（SGT 整片草 / INSTANCE_CUSTOM） ====================
## 启动逐实例燃烧：只挑**圈内**的实例，各自带随机相位与错开延迟
func _start_multimesh_burn() -> bool:
	_mm_burn.clear()
	for mmi in _multimeshes:
		if mmi.multimesh == null:
			continue
		var mat := mmi.material_override
		if mat == null and mmi.multimesh.mesh != null and mmi.multimesh.mesh.get_surface_count() > 0:
			mat = mmi.multimesh.mesh.surface_get_material(0)
		if not _shader_supports_instance_burn(mat):
			continue

		# ★★ INSTANCE_CUSTOM 要生效，MultiMesh 必须在**创建时**就打开 use_custom_data；
		#    运行时改会被 Godot 拒绝（multimesh.cpp:348 报错并忽略），
		#    后果就是"日志说成功、画面毫无反应"。已经在 addons/.../grass.gd 里
		#    统一构造时打开；这里只做检查，没开就**明确跳过**（不静默失败）。
		if not mmi.multimesh.use_custom_data:
			if debug_burn:
				print("[植被燃烧] %s 跳过：MultiMesh 没打开 use_custom_data（需在创建时打开）"
						% mmi.name)
			continue
		# ★ 优先用法术算好的"块内实例表"（先按块、再查块内；整次施法只扫一次）
		var use_preset: bool = preset_mm == mmi and not preset_indices.is_empty()
		if use_preset:
			for k in range(preset_indices.size()):
				var i: int = int(preset_indices[k])
				# ★ 有 preset_delays 就按它（火焰推进：按离角色的距离 -> 波前）；
				#   没有就用随机错开（火焰灼烧原本的行为）。
				var dl: float = float(preset_delays[k]) if k < preset_delays.size() \
						else _rng.randf() * 0.6
				_mm_burn.append({"mmi": mmi, "i": i, "phase": _rng.randf() * TAU,
						"delay": dl, "done": false})
			continue
		# 兜底：没传表时才自己遍历（没有块索引，属于退化路径）
		var cnt := mmi.multimesh.instance_count
		for i in range(cnt):
			var w: Vector3 = mmi.global_transform * mmi.multimesh.get_instance_transform(i).origin
			if burn_radius > 0.0 \
					and Vector2(w.x - burn_center.x, w.z - burn_center.z).length() > burn_radius:
				continue
			_mm_burn.append({"mmi": mmi, "i": i, "phase": _rng.randf() * TAU,
					"delay": _rng.randf() * 0.6, "done": false})
	return not _mm_burn.is_empty()


## 每帧推进每个实例的进度（写进 MultiMesh 的 custom data）
## 返回 true 表示全部结束（调用方去做收尾）
func _drive_multimesh_burn(bt: float, hold: float, at: float) -> bool:
	var all_done := true
	for e in _mm_burn:
		var mmi := e["mmi"] as MultiMeshInstance3D
		if mmi == null or not is_instance_valid(mmi) or mmi.multimesh == null:
			continue
		var lt: float = _t - float(e["delay"])
		var b := 0.0
		var a := 0.0
		if lt > 0.0:
			b = clampf(lt / maxf(bt, 0.01), 0.0, 1.0)
			if lt > bt + hold:
				a = clampf((lt - bt - hold) / maxf(at, 0.01), 0.0, 1.0)
		if a >= 1.0:
			# ★ 烧透之后怎么办 —— 三种取舍得说清：
			#   · 清零           -> 草"瞬间又冒出来"（用户反馈过：消失又出现）
			#   · 永久保持烧毁   -> 同一位置第二次烧就"没草可烧"，看着像没效果
			#     （用户反馈过：连变黑都没有了 —— 多半就是上一轮烧掉的还没恢复）
			#   所以默认：先保持烧毁状态，再**缓缓长回来**（regrow_time 秒）。
			if regrow_time <= 0.0:
				mmi.multimesh.set_instance_custom_data(int(e["i"]),
						Color(1.0, 1.0, float(e["phase"]), 0.0))     # 永久烧毁
				e["done"] = true
			else:
				if not e.has("done_t"):
					e["done_t"] = _t
				var rt: float = _t - float(e["done_t"])
				if rt >= regrow_time:
					mmi.multimesh.set_instance_custom_data(int(e["i"]),
							Color(0.0, 0.0, float(e["phase"]), 0.0))  # 完全长回
					e["done"] = true
				else:
					var k := rt / regrow_time
					# ★ 长回阶段 **burn 固定为 0**：草是"正常的绿草在长大"，
					#   不能还带着焦黑和火光（用户明确要求）。只用 ash 驱动缩放。
					mmi.multimesh.set_instance_custom_data(int(e["i"]),
							Color(0.0, 1.0 - k, float(e["phase"]), 0.0))
					all_done = false
		else:
			mmi.multimesh.set_instance_custom_data(int(e["i"]),
					Color(b, a, float(e["phase"]), 0.0))
			all_done = false
	return all_done


## 把原材质的**风参数**抄到第 i 个副本上（见 WIND_PARAMS 的说明）。
## 参数没设过时 get 返回 null，跳过即可。
func _copy_wind_params(i: int) -> void:
	if i < 0 or i >= _shader_mats.size() or i >= _shader_src.size():
		return
	var src: ShaderMaterial = _shader_src[i]
	var dst: ShaderMaterial = _shader_mats[i]
	if src == null or dst == null or src == dst:
		return
	for p in WIND_PARAMS:
		var v: Variant = src.get_shader_parameter(p)
		if v != null:
			dst.set_shader_parameter(p, v)


# ==================== 材质内建 burn 路线（复制材质，逐株独立） ====================
## 走"改材质内建 burn"：给每个网格复制一份材质（共享 .tres 不能直接改，
## 否则所有同类植被会一起烧），之后逐帧只写这些副本的 burn / ash。
func _apply_in_shader_burn() -> void:
	_shader_mats.clear()
	for mi in _meshes:
		if mi.mesh == null:
			continue
		# ★★★ 关键：Godot 里 **material_override 的优先级高于逐面 override** ✗
		#   （实测：两份材质都设了，画面上生效的是 material_override ✓）
		#   → 用「材质覆盖」装配的模型（aux_scene 这种把 3 份 .tres 盖在 GLB 上的）
		#     即使逐面塞了燃烧副本，**渲染仍然用 material_override** ✓
		#     → 逐面 burn 写进去也没人看 ✓ → 树"烧了但一点不变色"✓✓
		#   → 所以下面装完逐面副本后要**把 material_override 清掉** ✓
		#     并把原值记进 _prev_override ✓（非保留型目标收尾时能还原 ✓）
		var had_override: Material = mi.material_override
		var made := 0
		for s in range(mi.mesh.get_surface_count()):
			# ★★★ 修复（material_override 路线 ✓）：原来**先**取网格自带材质 ✗
			#   → 用「材质覆盖」装配的模型（GLB 的每个 Mesh 都还带着导入器生成的
			#     StandardMaterial3D ✓ 而实际渲染的是节点的 material_override ✓）会拿到
			#     StandardMaterial3D → `duplicate() as ShaderMaterial` 得到 null → `continue` ✗
			#   → **_shader_mats 为空 → 一点烧蚀都没有** ✓✓（只剩火星 ✓ 树不变色 ✓）
			#   正确口径 = 「**实际在渲染的那个材质**」：逐面 override > 节点 override > 网格自带 ✓
			#   ⚠ 老目标（tree_small_02 这种三面共用网格自带材质的）三处全空 → 落到
			#     网格自带材质 ✓ → 判定与改动前**完全一致** ✓
			var base: Material = mi.get_surface_override_material(s)
			if base == null:
				base = mi.material_override
			if base == null:
				base = mi.mesh.surface_get_material(s)
			if base == null:
				continue
			var dup := base.duplicate() as ShaderMaterial
			if dup == null:
				continue
			# ★★ 保险：把**外观参数**从原材质显式抄一遍 ✓
			#   否则 shader 材质（如树的 tree_burn_keep / tree_leaves_burn ✓）在被接管后
			#   会掉成"白模" ✓ —— 症状正是"编辑器里正常 ✓ 游戏内发白" ✓（用户实测 ✓）
			var src_sm := base as ShaderMaterial
			if src_sm != null:
				for pn in ["albedo_tex", "alpha_tex", "alpha_channel", "normal_up_blend", "ambient_fill", "base_color", "use_albedo", "use_mask",
						"mask_channel", "scissor", "scissor_enabled", "force_opaque", "use_uv",
						"has_normal", "normal_tex", "normal_strength", "radial_normal", "has_rough", "rough_tex", "rough_channel", "overlay_mode"]:
					var pv: Variant = src_sm.get_shader_parameter(pn)
					if pv != null:
						dup.set_shader_parameter(pn, pv)
			# ★★★ 自动量树高（用户要求 ✓）：用该网格**局部 AABB 的顶部**当 height_ref ✓
			#   为什么必须自动 ✓：shader 的 `v_hgt` 就是**模型空间**的 y ✓
			#     → height_ref 必须是**这个网格自己坐标系里的高度** ✓
			#   手填的风险 ✓：材质写着 8.2 ✗ 而树实际只有 **4.56 米** ✗
			#     → 前沿 `burn × 8.2 × 1.15` 在 burn≈0.43 就**越过树顶** ✗
			#     → 火焰只用前 43% 时间扫完 ✓ 看着"飞快/闪烁"✓ 之后整棵**瞬间全黑**✓（用户实测 ✓）
			# ★★★ 分块树冠（scripts/world/canopy_chunk_cull.gd）专用 ✓
			#   树冠被切成多块后，每块 `mesh.get_aabb()` 只是**自己那一小块** ✗
			#   → 各块会得到**不同的燃烧前沿** ✗ → 烧痕在块边界处错位/断成一片片 ✗
			#   → 分块脚本会把**整片树冠**的顶部高度写进节点 meta ✓ 这里优先用它 ✓
			var top := 0.0
			if mi.has_meta("burn_height_ref"):
				top = float(mi.get_meta("burn_height_ref"))
			elif mi.mesh != null:
				var ab: AABB = mi.mesh.get_aabb()
				top = ab.position.y + ab.size.y
			if top > 0.05:
				dup.set_shader_parameter("height_ref", top)
				print("[燃烧] 自动量高 ✓ height_ref = %.2f 米（%s）" % [top, mi.name])
			dup.set_shader_parameter("burn", 0.0)
			dup.set_shader_parameter("ash", 0.0)
			dup.set_shader_parameter("burn_phase", _phase)
			mi.set_surface_override_material(s, dup)
			_shader_mats.append(dup)
			_shader_src.append(base as ShaderMaterial)
			_copy_wind_params(_shader_src.size() - 1)
			made += 1
		# ★ material_override 优先级更高 ✓ → 装好逐面副本后必须清掉它，
		#   否则逐面副本**根本参与不到渲染** ✓（见本函数开头说明 ✓）
		#   只在真的做成了至少一份副本时才清 ✓（全失败就保持原样，别把模型弄没材质 ✓）
		if made > 0 and had_override != null:
			_prev_override.append({"n": mi, "m": had_override, "o": mi.material_overlay})
			mi.material_override = null


## 材质是否"卡片型"（透明/裁剪/哈希）—— 这类必须靠贴图 alpha 才是真实轮廓
func _is_transparent_material(m: Material) -> bool:
	if m is StandardMaterial3D:
		var t := (m as StandardMaterial3D).transparency
		return t != BaseMaterial3D.TRANSPARENCY_DISABLED
	if m is ShaderMaterial:
		# 自定义着色器无从判断，按"是卡片"处理（保守 -> 拿不到贴图就不画）
		return true
	return false


## 只放火星、不画形体叠加（安全阀分支用）
func _build_sparks_only() -> void:
	_collect_surface_points()
	_build_sparks()


## 防御式读布尔属性：不同 Godot 版本/基类里属性名不一定存在，
## 直接点属性会 "Invalid access to property" 并让整个函数中断（实测踩过）。
func _get_bool(o: Object, prop: String, def: bool = false) -> bool:
	if o == null or not o.has_method("get"):
		return def
	var v: Variant = o.get(prop)
	if v == null:
		return def
	return bool(v)


## ★ 找**透明度贴图**。植被的轮廓常常不在 albedo 的 alpha 里：
##   实测 scenes/草 的材质是 albedo_tex=JPG（**没有 alpha**）+ alpha_tex=PNG（单独的透明贴图），
##   拿 albedo 的 alpha 当遮罩恒为 1 -> 等于没遮 -> 整张卡片被涂黑（用户反复反馈的问题）。
func _alpha_texture_from_material(m: Material) -> Texture2D:
	if m == null or not (m is ShaderMaterial):
		return null
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return null
	for u in sm.shader.get_shader_uniform_list():
		var un := String(u.get("name", "")).to_lower()
		var is_alpha := false
		for hint in ["alpha", "opacity", "opac", "transp", "cutout", "mask", "blend_tex"]:
			if un.contains(hint):
				is_alpha = true
				break
		if not is_alpha:
			continue
		var v: Variant = sm.get_shader_parameter(String(u.get("name", "")))
		if v is Texture2D:
			return v
	return null


## 找出遮罩贴图对应的 uniform 名（用来解析它用的是哪个通道）
func _alpha_uniform_of(m: Material) -> String:
	if m == null or not (m is ShaderMaterial):
		return ""
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return ""
	for u in sm.shader.get_shader_uniform_list():
		var un := String(u.get("name", ""))
		var ln := un.to_lower()
		for hint in ["alpha", "opacity", "opac", "transp", "cutout", "mask"]:
			if ln.contains(hint) and sm.get_shader_parameter(un) is Texture2D:
				return un
	return ""


## ★ 原着色器用**哪个通道**表示形状？从它的源码里解析出来（不硬编码）。
##   例：grass_wind.gdshader 写的是 `ALPHA = texture(alpha_tex, UV).r` -> 红通道。
##   取错通道的后果：那张 PNG 的 a 恒为 1 -> 遮罩失效 -> 透明区域也变黑（实测踩过）。
##   返回 0=r 1=g 2=b 3=a（解析不出来时按 a）。
func _mask_channel_of(m: Material, tex_uniform: String) -> int:
	if m == null or not (m is ShaderMaterial) or tex_uniform == "":
		return 3
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return 3
	var code := sm.shader.code
	var re := RegEx.new()
	if re.compile("texture\\s*\\(\\s*" + tex_uniform + "\\s*,[^)]*\\)\\s*\\.([rgba])") != OK:
		return 3
	var r := re.search(code)
	if r == null:
		return 3
	match r.get_string(1):
		"r":
			return 0
		"g":
			return 1
		"b":
			return 2
	return 3


## 从材质里挑一张"最像 albedo"的贴图，作为燃烧叠加层的颜色与遮罩来源。
## 参数 m：任意 Material（StandardMaterial3D 直接取 albedo_texture）。
## 返回：挑中的 Texture2D；确实没有贴图时 null（调用方据此走"跳过叠加"安全阀）。
## 说明：自定义 ShaderMaterial 没有固定参数名，所以枚举 shader 的 uniform 表，
##   先用关键字白名单（albedo/color/base/grass…）命中，并用黑名单
##   （noise/normal/height/mask/rough…）排除干扰贴图，都不命中时用第一张纹理兜底。
## 副作用：无（纯查询）。
func _texture_from_material(m: Material) -> Texture2D:
	if m == null:
		return null
	if m is StandardMaterial3D:
		return (m as StandardMaterial3D).albedo_texture
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		if sm.shader == null:
			return null
		var fallback: Texture2D = null
		# ★ ShaderMaterial **没有** get_shader_parameter_list()（调用会报
		#   "Nonexistent function"，而且会让整个 burn_node 中断 -> 材质贴不上、燃烧失效）。
		#   参数表在 **Shader** 上：get_shader_uniform_list()。
		for u in sm.shader.get_shader_uniform_list():
			var uname := String(u.get("name", ""))
			if uname == "":
				continue
			var v: Variant = sm.get_shader_parameter(uname)
			if not (v is Texture2D):
				continue
			# ★ 优先"确定是 albedo"的名字；并**排除**明显不是的（noise/normal/height/...）。
			#   之前 hints 太松（含 "tex"/"map"），会把 noise_tex 当成 albedo -> 遮罩失效
			#   -> 叠加层盖满整张卡片 = 大黑斑（用户实测反馈）。
			var pn := uname.to_lower()
			var excluded := false
			for bad in ["noise", "normal", "height", "mask", "rough", "metal", "ao",
					"dist", "wind", "detail", "dissolve"]:
				if pn.contains(bad):
					excluded = true
					break
			if excluded:
				continue
			for hint in ["albedo", "color", "colour", "diffuse", "base", "blade", "grass"]:
				if pn.contains(hint):
					return v
			if fallback == null:
				fallback = v
		return fallback
	return null


# ==================== 表面点采样与火星 ====================
## 从真实顶点采样"表面点"：火星从这里生出来
func _collect_surface_points() -> void:
	_surface.clear()
	var want := maxi(spark_count * 6, 24)
	for mi in _meshes:
		if mi.mesh == null:
			continue
		var xf := mi.global_transform
		for s in range(mi.mesh.get_surface_count()):
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts == null or verts.is_empty():
				continue
			var stride := maxi(1, int(float(verts.size()) / float(maxi(want, 1))))
			var i := 0
			while i < verts.size() and _surface.size() < want:
				var w := xf * verts[i]
				i += stride
				# 转成"本节点局部坐标"（火星挂在控制器下）
				_surface.append(global_transform.affine_inverse() * w)
	# ★ MultiMesh（addon 的整片草丛）：必须按 **(实例变换 × 顶点)** 采样，
	#   否则火星会全挤在节点原点那一株草上，而不是撒在整片草丛的表面。
	for mmi in _multimeshes:
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		var mesh := mmi.multimesh.mesh
		var count := mmi.multimesh.visible_instance_count
		if count <= 0:
			count = mmi.multimesh.instance_count
		if count <= 0:
			continue
		for s in range(mesh.get_surface_count()):
			var arrays2 := mesh.surface_get_arrays(s)
			if arrays2.is_empty():
				continue
			var verts2: PackedVector3Array = arrays2[Mesh.ARRAY_VERTEX]
			if verts2 == null or verts2.is_empty():
				continue
			var tries := 0
			while _surface.size() < want and tries < want * 4:
				tries += 1
				# ★ 必须用 posmod：randi() 返回 uint32，直接 % count 可能是负数下标，
				#   结果 get_instance_transform 取不到实例 -> 火星全挤在一株草上
				#   （实测：横向跨度只有 0.06 米 = 一片草的宽度）。
				var ii := posmod(_rng.randi(), count)
				var vv := verts2[posmod(_rng.randi(), verts2.size())]
				var w2: Vector3 = mmi.global_transform \
						* (mmi.multimesh.get_instance_transform(ii) * vv)
				_surface.append(global_transform.affine_inverse() * w2)
	if _surface.is_empty():
		_surface.append(Vector3.ZERO)


## 创建火星节点（MultiMeshInstance3D，节点名 "BurnSparks"）并初始化状态数组。
## 外观：unshaded + 加法混合 + billboard 的橙色小方片 —— 不吃光照、不投影，
##   所以在夜里/焦黑模型上也看得见。
## 池大小固定为 spark_count；_sl 全填 -1 表示"全部空闲"，等 _update_sparks 第一帧才重生。
## 副作用：若已有旧火星节点会先 queue_free 再重建；add_child 到本控制器下（局部坐标即本节点坐标）。
## 注意：重复调用会丢掉正在飞的火星（_resize 复位），所以正常只在 burn_node 里调一次。
func _build_sparks() -> void:
	if _sparks != null and is_instance_valid(_sparks):
		_sparks.queue_free()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(1.0, 0.62, 0.18, 0.95)
	m.disable_receive_shadows = true
	var q := QuadMesh.new()
	q.size = Vector2(spark_size, spark_size)
	q.surface_set_material(0, m)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = spark_count
	mm.mesh = q
	var node := MultiMeshInstance3D.new()
	node.name = "BurnSparks"
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_sparks = node
	_sp.resize(spark_count)
	_sv.resize(spark_count)
	_sl.resize(spark_count)
	for i in range(spark_count):
		_sl[i] = -1.0


## 每帧驱动：累加时间 → 第 1 秒上报一次诊断 → 算 burn/ash → 写材质或实例 custom data → 更新火星。
## 参数 delta：帧间隔（秒），由引擎传入。
## 返回：无。
## 副作用：改材质参数 / MultiMesh 的实例 custom data / 火星实例变换；
##   收到尾时会调用 _finish()（内部 set_process(false) 停掉自己）。
## 提前退出条件：已 _done、目标已被释放、或 delay 未到（_t < 0，只累加时间不干活）。
## 注意：三条渲染路线（逐实例 / 材质内建 burn / 叠加层）在下面用 if-elif-elif 分支，
##   互斥，不会互相覆盖；逐实例与材质内建路线各自 return，只有叠加层路线走到末尾的收尾判断。
# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _done or _target == null or not is_instance_valid(_target):
		return
	_t += delta
	if _t < 0.0:
		return
	# ★ 1 秒时汇报一次：路径 / 着色器 / **实际写进去的 burn 值**。
	#   用来区分"驱动没生效"和"着色器没表现"，不再靠猜。
	if debug_burn and not _reported and _t >= 1.0:
		_reported = true
		if not _mm_burn.is_empty():
			var cd := "（读不回）"
			var e0 := _mm_burn[0] as Dictionary
			var mmi0 := e0["mmi"] as MultiMeshInstance3D
			if mmi0 != null and mmi0.multimesh != null:
				cd = str(mmi0.multimesh.get_instance_custom_data(int(e0["i"])))
			print("[植被燃烧·1s] %s | 逐实例 | 实例数 %d | 首实例 custom=%s | t=%.2f"
					% [_target.name, _mm_burn.size(), cd, _t])
		elif not _shader_mats.is_empty():
			var b1: Variant = _shader_mats[0].get_shader_parameter("burn")
			var sp := "无"
			if _shader_mats[0].shader != null:
				sp = _shader_mats[0].shader.resource_path
			print("[植被燃烧·1s] %s | 材质内建 burn | 材质副本 %d | burn=%s | 着色器=%s | t=%.2f"
					% [_target.name, _shader_mats.size(), str(b1), sp, _t])
		elif _mat != null:
			print("[植被燃烧·1s] %s | 叠加层 | burn=%s | t=%.2f"
					% [_target.name, str(_mat.get_shader_parameter("burn")), _t])
		else:
			print("[植被燃烧·1s] %s | **什么都没挂上**（无逐实例/无材质副本/无叠加层）"
					% _target.name)
	# 时间轴（单株，秒）：[0, burn_time] 斑点扩散 → 再用 char_hold 秒全焦黑停留
	# → 最后用 ash_time 秒灰化消失。三段首尾相接、互不重叠，所以停留期内 ash 恒为 0。
	var burn := clampf(_t / maxf(burn_time, 0.01), 0.0, 1.0)
	var ash := 0.0
	var crumble := 0.0
	# ★★ 树（保留型）走**崩毁**时间轴（用户需求 ✓）：停留期结束后 collapse_time 秒内
	#   **L5→L1 枝条从上到下依次脱落**，落地的枝条完全着地后再缓慢缩小消失 ✓
	#   叶片用 ash 提前散尽（crumble×2.2 → 崩到约 45% 时叶子已全没了 ✓）
	#   collapse_time = 0 时退回旧行为（ash_time_tree 灰化，焦黑树架保留）
	var collapsing := _is_tree and collapse_time > 0.0
	if collapsing:
		if _t > burn_time + char_hold:
			crumble = clampf((_t - burn_time - char_hold) / collapse_time, 0.0, 1.0)
			ash = clampf(crumble * 2.2, 0.0, 1.0)
	elif _t > burn_time + char_hold:
		# 停留期结束才开始灰化：保证"先烧透、再停留、最后消失"的观感顺序。
		ash = clampf((_t - burn_time - char_hold) / maxf(ash_time, 0.01), 0.0, 1.0)
	if not _mm_burn.is_empty():
		# ★ 逐实例路线：进度写在 MultiMesh 的 custom data 上
		_update_sparks(delta, burn)
		if _drive_multimesh_burn(burn_time, char_hold, ash_time):
			_finish()
		return
	if not _shader_mats.is_empty():
		# 内建 burn 路线：只写材质副本（每株独立）
		for si in range(_shader_mats.size()):
			var sm2: ShaderMaterial = _shader_mats[si]
			if sm2 != null:
				sm2.set_shader_parameter("burn", burn)
				sm2.set_shader_parameter("ash", ash)
				# ★ 崩毁进度只写给带 crumble 的树着色器（草/灌木的 shader 没有这个 uniform）
				#   ★ 脱落枝条**恒为 0**：它们靠落地后缩放消失，不能被 shader 提前抠掉
				if _is_tree and sm2.shader != null:
					var sp2 := String(sm2.shader.resource_path)
					if sp2.contains("tree_burn_keep") or sp2.contains("tree_leaves_burn"):
						sm2.set_shader_parameter("crumble", 0.0 if _sec_mats.has(sm2) else crumble)
				# ★ 每帧同步天气风：副本不在风系统的材质名单里，不抄就会"一烧就不摆"
				_copy_wind_params(si)
	elif _mat != null:
		_mat.set_shader_parameter("burn", burn)
		_mat.set_shader_parameter("ash", ash)
	# ★ 崩毁枝条：L5→L1 依次脱落 → 边下落边翻滚 → 落地压平躺好 → 缓慢缩小消失
	if collapsing:
		_update_collapse_sections(delta, _t - burn_time - char_hold)
	_update_sparks(delta, burn)
	# 只有"叠加层/材质内建 burn"两条路线会走到这里收尾；逐实例路线已在上面 return。
	# ★ 树看 crumble 到顶（而非 ash）—— ash 只是叶片提前散尽的伴随量
	if collapsing:
		if crumble >= 1.0:
			# ★★ 时间轴（用户要求 ✓）：树体先消失，但枝条还要继续落地/缩小 ✓
			#    没有这段的话，"崩毁到顶"的同帧会把半空中的枝条一起藏掉 → 突兀 ✓
			if not _collapse_tail:
				_collapse_tail = true
				_tail_time = debris_linger
				_hide_collapsed_target()
			_tail_time -= delta
			if _tail_time <= 0.0 or _sections_all_done():
				_finish()
	elif ash >= 1.0:
		_finish()


## 每帧推进火星：空闲的按概率在**真实表面点**上重生，存活的做减速上升运动并随寿命缩小。
## 参数 delta：帧间隔（秒）；burn：当前燃烧进度 0~1（>=1 时不再重生新火星）。
## 返回：无。
## 副作用：写火星 MultiMesh 的实例变换（死亡/空闲的实例被丢到 y=-999 藏起来）。
## 注意：_surface 为空时必须跳过重生，否则 posmod 取模会崩；_collect_surface_points
##   末尾有"至少塞一个原点"的兜底，专门防这种情况。
func _update_sparks(delta: float, burn: float) -> void:
	if _sparks == null or not is_instance_valid(_sparks):
		return
	var mm := _sparks.multimesh
	for i in range(spark_count):
		if _sl[i] <= 0.0:
			# 只在"还在烧"且**确实采到表面点**时重生（空表要跳过，否则取模崩溃）
			if burn < 1.0 and _rng.randf() < 0.35 and _surface.size() > 0:
				var surf: Vector3 = _surface[posmod(_rng.randi(), _surface.size())]
				_sp[i] = surf
				_sv[i] = Vector3(_rng.randf_range(-0.12, 0.12), _rng.randf_range(0.25, 0.7),
						_rng.randf_range(-0.12, 0.12))
				_sl[i] = spark_lifetime * _rng.randf_range(0.6, 1.2)
			else:
				mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0, -999, 0)))
				continue
		_sl[i] -= delta
		_sp[i] += _sv[i] * delta
		_sv[i].y = maxf(_sv[i].y - 0.25 * delta, 0.05)      # 火星上升变慢
		var k := clampf(_sl[i] / maxf(spark_lifetime, 0.01), 0.0, 1.0)
		var b := Basis().scaled(Vector3.ONE * clampf(k, 0.25, 1.0))
		mm.set_instance_transform(i, Transform3D(b, _sp[i]))


# ==================== 崩毁枝条（树干烧透后 L5→L1 依次脱落） ====================
## ★ 用户需求：**不要小方块** ✓ 直接用树本身的 Bark_Branch_L* 当碎块 —
##   掉下来的就是真实枝条；**完全落地后缓慢缩小消失** ✓
##   顺序：L5（最高）→ L1（最低）从上到下 ✓，同一层内每根枝条再各自随机时刻 ✓
## 段状态（_sec_state 里存这些值）
const SEC_WAIT := 0
const SEC_FALL := 1
const SEC_REST := 2
const SEC_SHRINK := 3
const SEC_DEAD := 4


## 从节点名里取枝条层号（Bark_Branch_L5 → 5）；取不到返回 0。
## 崩毁优先级用它排序：L5 最先脱落，L1 最后。
func _branch_level(n: String) -> int:
	var idx := n.rfind("L")
	if idx < 0:
		return 0
	return int(n.substr(idx + 1))


## 登记要脱落的枝条（名字以 Bark_Branch_L 开头）：按 L5→L1 分层，每层再按**连通分量**
## 拆成一根一根，并为每根排好"层内随机"的脱落时刻。
## ★ 为什么必须拆：Bark_Branch_L5 这种一层在场景里只有**一个**网格 → 整层是一个刚体，
##   不拆的话同层所有枝条会同时掉、同时崩（用户实测反馈"L5 是同时掉落崩毁的，不合理"）。
## 只在"树木 + 开启崩毁"时有意义；其它目标一律留空 → 崩毁仍走原来的高度序。
func _build_collapse_sections() -> void:
	_sec_src.clear()
	_sec_layer.resize(0)
	_sec_part_mesh.clear()
	_sec_part_mat.clear()
	_sec_dups.clear()
	_sec_mats.clear()
	_sec_t.resize(0)
	_sec_state.resize(0)
	_sec_rest.resize(0)
	_sec_vel.resize(0)
	_sec_drop.resize(0)
	_sec_floor.resize(0)
	_sec_basis.clear()
	_sec_origin.resize(0)
	_sec_pivot.resize(0)
	_sec_pivot_local.resize(0)
	_sec_axis.clear()
	_sec_angle.resize(0)
	_sec_spin.resize(0)
	_sec_target.resize(0)
	_sec_pts.clear()
	_sec_land_b.clear()
	_sec_land_o.resize(0)
	_sec_shrink_pivot.resize(0)
	_sec_spawned = false
	if not _is_tree or collapse_time <= 0.0:
		return
	var layers: Array[MeshInstance3D] = []
	for mi in _meshes:
		if mi == null or not is_instance_valid(mi):
			continue
		if String(mi.name).begins_with("Bark_Branch_L"):
			layers.append(mi)
	# ★ 优先脱落顺序固定为 L5 → L4 → L3 → L2 → L1（按名字里的层号降序）
	layers.sort_custom(func(a: MeshInstance3D, b: MeshInstance3D) -> bool:
		return _branch_level(String(a.name)) > _branch_level(String(b.name)))
	for mi in layers:
		_collect_layer_parts(mi)
	var n := _sec_state.size()
	if n == 0:
		return
	# ★ 脱落窗口：collapse_time 的前 branch_fall_window 比例内全部脱完。
	#   **按层分窗**（每层窗宽 ∝ 该层枝条数）→ 保证 L5 的所有枝条都比 L4 早，
	#   层的先后优先级不被随机破坏 ✓；层内每根再各取随机时刻 → 不再"整层同时掉"✓
	var window := maxf(collapse_time * clampf(branch_fall_window, 0.05, 1.0), 0.01)
	var acc := 0.0
	var i := 0
	while i < n:
		var lv := _sec_layer[i]
		var j := i
		while j < n and _sec_layer[j] == lv:
			j += 1
		var span := window * float(j - i) / float(n)
		for k in range(i, j):
			_sec_t[k] = acc + _rng.randf_range(0.0, span * 0.98)
		acc += span
		i = j


## 把一整层枝条网格（如 Bark_Branch_L5）按**连通分量**拆成一根一根，逐根登记到崩毁清单。
## 参数 mi：该层 MeshInstance3D。返回：无。
## 注意：枝条网格是单 surface、顶点属性含 CUSTOM0~2（风摆权重）→ 拆分时原样搬运。
func _collect_layer_parts(mi: MeshInstance3D) -> void:
	if mi.mesh == null or mi.mesh.get_surface_count() <= 0:
		return
	var arrays := mi.mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	if verts.is_empty():
		return
	var tris: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if tris.is_empty():
		# 无索引网格：按 0,1,2 / 3,4,5 ... 当三角形
		tris.resize(verts.size())
		for i in range(verts.size()):
			tris[i] = i
	# 并查集：共享顶点的三角形属于同一根枝条
	# ★ 用 Array[int]（引用类型）而不是 PackedInt32Array：后者在函数参数里的
	#   写回语义不可靠 → union 结果会丢，拆出来变成几千个退化小面 ✗
	var parent: Array[int] = []
	parent.resize(verts.size())
	for i in range(verts.size()):
		parent[i] = i
	for t in range(0, tris.size() - 2, 3):
		_uf_union(parent, tris[t], tris[t + 1])
		_uf_union(parent, tris[t], tris[t + 2])
	# 三角形按"根"分组（每根枝条一个三角形表）
	var groups := {}
	for t in range(0, tris.size() - 2, 3):
		var r := _uf_find(parent, tris[t])
		if not groups.has(r):
			groups[r] = PackedInt32Array()
		var tl: PackedInt32Array = groups[r]
		tl.append(tris[t])
		tl.append(tris[t + 1])
		tl.append(tris[t + 2])
		groups[r] = tl                    # Packed*Array 是值类型 → 取出来改完必须写回
	var lv := _branch_level(String(mi.name))
	var m0 := global_transform.affine_inverse() * mi.global_transform
	var mat := _make_part_material(mi)
	for key in groups.keys():
		var part_arrays := _compact_arrays(arrays, groups[key])
		if part_arrays.is_empty():
			continue
		var part := ArrayMesh.new()
		# ★ fast-tree 风摆移植：CUSTOM0~2 是每顶点 4 个 float，必须显式声明 RGBA_FLOAT，
		#   否则 add_surface_from_arrays 按默认 RGBA8 去要 PackedByteArray → surface 建不出来
		var custom_flags := 0
		if arrays[Mesh.ARRAY_CUSTOM0] != null:
			custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT)
		if arrays[Mesh.ARRAY_CUSTOM1] != null:
			custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
		if arrays[Mesh.ARRAY_CUSTOM2] != null:
			custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)
		if arrays[Mesh.ARRAY_CUSTOM3] != null:
			custom_flags |= (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
		part.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, part_arrays, [], {}, custom_flags)
		if part.get_surface_count() == 0:
			continue
		var pv: PackedVector3Array = part_arrays[Mesh.ARRAY_VERTEX]
		var ab := _aabb_of(pv)
		# ★ 该根枝条要落多远才碰地 = 原始姿态下最低顶点离地高度（地面 = 控制器局部 y 0）
		#   本来就有枝梢在地面以下 → 按 0 处理（原地翻倒，不再往下沉）✓
		var low := INF
		for v in pv:
			low = minf(low, (m0 * v).y)
		# ★ 旋转支点放在该根枝条的**下沿中心**：绕下沿翻倒 = 从被支撑处砸下来 ✓
		#   绕中心转会有一半枝条往上甩 → 看起来像"突然往上一弹"✗（用户实测反馈）
		var piv := Vector3(ab.get_center().x, ab.position.y, ab.get_center().z)
		_sec_src.append(mi)
		_sec_layer.append(lv)
		_sec_part_mesh.append(part)
		_sec_part_mat.append(mat)
		_sec_dups.append(null)
		_sec_state.append(SEC_WAIT)
		_sec_t.append(0.0)
		_sec_rest.append(0.0)
		_sec_vel.append(0.0)
		_sec_drop.append(0.0)
		_sec_floor.append(maxf(low, 0.0))
		_sec_basis.append(m0.basis)
		_sec_origin.append(m0.origin)
		_sec_pivot_local.append(piv)
		_sec_pivot.append(m0 * piv)
		_sec_pts.append(pv)
		_sec_land_b.append(m0.basis)
		_sec_land_o.append(m0.origin)
		_sec_shrink_pivot.append(m0.origin)
		# ★ 翻滚：随机水平轴 + 约 90°（树干上的枝条翻倒后正好横躺在地面上）✓
		var axis_ang := _rng.randf_range(0.0, TAU)
		_sec_axis.append(Vector3(cos(axis_ang), 0.0, sin(axis_ang)))
		_sec_angle.append(0.0)
		var tgt := _rng.randf_range(1.42, 1.56)          # 81°~89°
		_sec_target.append(tgt)
		_sec_spin.append(tgt / maxf(branch_rotate_time * _rng.randf_range(0.85, 1.15), 0.05))


## 给一整层枝条做一份材质副本：**关掉风摆** + crumble 恒 0（靠缩放消失，不能被 shader 抠掉）。
## 同时登记进 _shader_mats/_shader_src → _process 会继续把 burn / ash 写给它。
func _make_part_material(mi: MeshInstance3D) -> Material:
	var base: Material = mi.get_surface_override_material(0)
	if base == null:
		base = mi.material_override
	if base == null and mi.mesh != null:
		base = mi.mesh.surface_get_material(0)
	if base == null:
		return null
	var dup := base.duplicate() as Material
	if dup == null:
		return null
	var sm := dup as ShaderMaterial
	if sm != null:
		sm.set_shader_parameter("wind_enabled", false)
		sm.set_shader_parameter("crumble", 0.0)
		_sec_mats[sm] = true
		_shader_mats.append(sm)
		_shader_src.append(sm)            # 源 = 自己 → _copy_wind_params 直接跳过 ✓
	return dup


## 并查集查根。
func _uf_find(parent: Array[int], x: int) -> int:
	var r := x
	while parent[r] != r:
		r = parent[r]
	return r


## 并查集合并。
func _uf_union(parent: Array[int], a: int, b: int) -> void:
	var ra := _uf_find(parent, a)
	var rb := _uf_find(parent, b)
	if ra != rb:
		parent[rb] = ra


## 顶点集合的包围盒。
func _aabb_of(verts: PackedVector3Array) -> AABB:
	if verts.is_empty():
		return AABB()
	var lo := verts[0]
	var hi := verts[0]
	for v in verts:
		lo = Vector3(minf(lo.x, v.x), minf(lo.y, v.y), minf(lo.z, v.z))
		hi = Vector3(maxf(hi.x, v.x), maxf(hi.y, v.y), maxf(hi.z, v.z))
	return AABB(lo, hi - lo)


## 只保留 tri_idx 用到的顶点，重建一份紧凑的顶点属性数组（重复顶点合并到同一新下标）。
## 写法参考 scripts/world/canopy_chunk_cull.gd（那边已踩过 TANGENT/CUSTOM 的 stride 坑）。
func _compact_arrays(arrays: Array, tri_idx: PackedInt32Array) -> Array:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var remap := PackedInt32Array()
	remap.resize(verts.size())
	remap.fill(-1)
	var new_index := PackedInt32Array()
	new_index.resize(tri_idx.size())
	var used := 0
	for i in range(tri_idx.size()):
		var old := tri_idx[i]
		var to := remap[old]
		if to < 0:
			to = used
			used += 1
			remap[old] = to
		new_index[i] = to
	var out: Array = []
	out.resize(Mesh.ARRAY_MAX)
	for a in range(Mesh.ARRAY_MAX):
		var v: Variant = arrays[a]
		if v == null:
			continue
		if a == Mesh.ARRAY_INDEX:
			out[a] = new_index
			continue
		var built: Variant = _remap_attr(v, remap, used, verts.size())
		if built == null:
			return []
		out[a] = built
	return out


## 把一种顶点属性数组按 remap 重排成 used 个元素。
## ★ 注意 stride：TANGENT / WEIGHTS / CUSTOM0..3 是**每顶点 4 个 float**，
##   BONES 是每顶点 4 个 int，其余是 1:1（按 1:1 处理会长度不匹配）。
## 参数 vcount：原网格顶点数（用来反推 stride）。
func _remap_attr(v: Variant, remap: PackedInt32Array, used: int, vcount: int) -> Variant:
	if v is PackedVector3Array:
		var src := v as PackedVector3Array
		if src.size() != vcount:
			return null
		var dst := PackedVector3Array()
		dst.resize(used)
		for old in range(remap.size()):
			var n := remap[old]
			if n >= 0:
				dst[n] = src[old]
		return dst
	if v is PackedVector2Array:
		var src2 := v as PackedVector2Array
		if src2.size() != vcount:
			return null
		var dst2 := PackedVector2Array()
		dst2.resize(used)
		for old in range(remap.size()):
			var n2 := remap[old]
			if n2 >= 0:
				dst2[n2] = src2[old]
		return dst2
	if v is PackedColorArray:
		var src3 := v as PackedColorArray
		if src3.size() != vcount:
			return null
		var dst3 := PackedColorArray()
		dst3.resize(used)
		for old in range(remap.size()):
			var n3 := remap[old]
			if n3 >= 0:
				dst3[n3] = src3[old]
		return dst3
	if v is PackedFloat32Array:
		var src4 := v as PackedFloat32Array
		if vcount <= 0 or src4.size() % vcount != 0:
			return null
		var stride := src4.size() / vcount
		var dst4 := PackedFloat32Array()
		dst4.resize(used * stride)
		for old in range(remap.size()):
			var n4 := remap[old]
			if n4 >= 0:
				for k in range(stride):
					dst4[n4 * stride + k] = src4[old * stride + k]
		return dst4
	if v is PackedInt32Array:
		var src5 := v as PackedInt32Array
		if vcount <= 0 or src5.size() % vcount != 0:
			return null
		var stride5 := src5.size() / vcount
		var dst5 := PackedInt32Array()
		dst5.resize(used * stride5)
		for old in range(remap.size()):
			var n5 := remap[old]
			if n5 >= 0:
				for k in range(stride5):
					dst5[n5 * stride5 + k] = src5[old * stride5 + k]
		return dst5
	return null


## 崩毁开始的那一帧：把所有枝条替身摆到原位，然后整层隐藏原网格。
## ★ 为什么放到崩毁开始才生成（而不是点燃时）：替身材质要关掉风摆，
##   提前生成会让整棵树的枝条在**燃烧期**就不摆动了 ✗；放这里只在崩毁瞬间花一帧 ✓
func _spawn_branch_parts() -> void:
	if _sec_spawned:
		return
	_sec_spawned = true
	for i in range(_sec_state.size()):
		var part: Mesh = _sec_part_mesh[i]
		if part == null:
			_sec_state[i] = SEC_DEAD
			continue
		var src: MeshInstance3D = _sec_src[i]
		var dup := MeshInstance3D.new()
		dup.name = "Fallen_L%d_%d" % [_sec_layer[i], i]
		dup.mesh = part
		if _sec_part_mat[i] != null:
			dup.set_surface_override_material(0, _sec_part_mat[i])
		if src != null and is_instance_valid(src):
			dup.cast_shadow = src.cast_shadow
			dup.layers = src.layers
		dup.transform = Transform3D(_sec_basis[i], _sec_origin[i])
		add_child(dup)
		_sec_dups[i] = dup
	# ★ 原层网格整层隐藏：替身已经在完全相同的位置接管 → 看不出切换
	for src in _sec_src:
		if src != null and is_instance_valid(src):
			src.visible = false


## 每帧推进崩毁枝条：待脱落 →（到点）脱离 → 边下落边翻滚 → 落地躺平 → 缓慢缩小消失。
## 参数 delta：帧间隔（秒）；elapsed：距崩毁开始的秒数。返回：无。
## 注意：所有运动都在**控制器局部坐标**里算（控制器就在树根处、无旋转缩放）。
func _update_collapse_sections(delta: float, elapsed: float) -> void:
	# ★ 崩毁第一帧：把 462 根枝条替身一次性摆到原位（同一帧里原层网格整层隐藏）
	if not _sec_spawned:
		_spawn_branch_parts()
	for i in range(_sec_state.size()):
		var st := int(_sec_state[i])
		if st == SEC_DEAD:
			continue
		if st == SEC_WAIT:
			if elapsed < _sec_t[i]:
				continue
			# 到点：开始下落（方向/翻滚参数在构建期已随机好）
			_sec_vel[i] = 0.0
			_sec_drop[i] = 0.0
			_sec_angle[i] = 0.0
			st = SEC_FALL
			_sec_state[i] = SEC_FALL
		var dup: MeshInstance3D = _sec_dups[i]
		if dup == null or not is_instance_valid(dup):
			_sec_state[i] = SEC_DEAD
			continue
		if st == SEC_FALL:
			# ★ 物理下落：重力加速下降 + 绕**水平轴**翻滚（像从树干上翻倒下来）
			_sec_vel[i] += branch_gravity * delta
			_sec_drop[i] = minf(_sec_drop[i] + _sec_vel[i] * delta, _sec_floor[i])
			_sec_angle[i] = minf(_sec_angle[i] + _sec_spin[i] * delta, _sec_target[i])
			var nb := Basis(_sec_axis[i], _sec_angle[i]) * _sec_basis[i]
			# ★ 绕支点旋转：世界支点 - nb * **网格局部**支点
			#   （angle=0 时 origin 正好等于原始位置，不会第一帧跳一下 ✗）
			var origin := _sec_pivot[i] - nb * _sec_pivot_local[i] - Vector3(0.0, _sec_drop[i], 0.0)
			dup.transform = Transform3D(nb, origin)
			# ★ 着地两个条件：① 已经翻到接近"横躺" ② 该落的高度已经落满
			#   ★ 不做"抬起来贴地"✗：抬 = 用户看到的"突然向上弹一下"（实测反馈）
			if _sec_drop[i] >= _sec_floor[i] - 0.001 \
					and _sec_angle[i] >= _sec_target[i] - 0.002:
				_sec_land_b[i] = nb
				_sec_land_o[i] = origin
				_sec_rest[i] = 0.0
				_sec_state[i] = SEC_REST
			continue
		if st == SEC_REST:
			# ★ 着地后**原地静置** branch_rest_time 秒：不移动、不压扁（压扁/贴地都会造成弹跳 ✗）
			_sec_rest[i] += delta
			if _sec_rest[i] >= maxf(branch_rest_time, 0.01):
				_sec_rest[i] = 0.0
				_sec_shrink_pivot[i] = _ground_center(
						_sec_land_b[i], _sec_land_o[i], _sec_pts[i])
				_sec_state[i] = SEC_SHRINK
			continue
		# SEC_SHRINK：已经**横躺在地面上**之后再缓慢缩小消失
		_sec_rest[i] += delta
		var p := clampf(_sec_rest[i] / maxf(branch_shrink_time, 0.01), 0.0, 1.0)
		var s := 1.0 - p
		if s <= 0.002:
			dup.visible = false
			_sec_state[i] = SEC_DEAD
			continue
		# 绕地面支点缩放（支点 y = 0）→ 整体始终压在地面上，不会悬空/陷地
		var land_b := _sec_land_b[i]
		var land_o := _sec_land_o[i]
		var piv2 := _sec_shrink_pivot[i]
		dup.transform = Transform3D(land_b.scaled(Vector3.ONE * s),
				piv2 + (land_o - piv2) * s)


## 落地后枝条在**地面上**的水平中心（缩小支点；y 固定为 0）。
func _ground_center(basis: Basis, origin: Vector3, pts: PackedVector3Array) -> Vector3:
	if pts.is_empty():
		return Vector3(origin.x, 0.0, origin.z)
	var sx := 0.0
	var sz := 0.0
	for p in pts:
		var w := basis * p + origin
		sx += w.x
		sz += w.z
	return Vector3(sx / pts.size(), 0.0, sz / pts.size())


## 所有崩毁枝条都结束了吗？（收尾判断用；没有枝条时视为已结束）
func _sections_all_done() -> bool:
	for i in range(_sec_state.size()):
		if int(_sec_state[i]) != SEC_DEAD:
			return false
	return true


# ==================== 目标分类与收尾 ====================
## 这份材质是不是「木质型（烧完保留焦黑）」的？
## 判据（任一 ✓）：① shader 是 tree_burn_keep* ✓ ② 资源 meta burn_mode == "wood" ✓
## 参数 m：任意 Material，可为 null。返回：bool，null 一律 false（不崩）。
## 抽成独立函数的原因：判定要**在三个材质来源上分别做**（见 _target_is_keep ✓），
##   三处写三遍容易漏一处 ✓（这次就是漏了「逐面 override」那一处 ✓）。
func _mat_is_wood(m: Material) -> bool:
	if m == null:
		return false
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		# ★ 修正（方案 A ✓）：原来用 `ends_with("tree_burn_keep.gdshader")` ✗
		#   而材质实际引用的是 `tree_burn_keep_ds.gdshader` ✗ → 这条判断**一直是失效的** ✓
		#   → 之前只靠材质的 `burn_mode == "wood"` meta 生效 ✓
		#   改用 contains ✓：任何变体（_ds / 无后缀 / 以后改名）都能认出来 ✓
		if sm.shader != null and String(sm.shader.resource_path).contains("tree_burn_keep"):
			return true
	if String(m.get_meta("burn_mode", "")) == "wood":
		return true
	return false


## 本控制器**实际装上的燃烧副本**里，有没有木质材质？
## 用途：_finish() 的"要不要隐藏目标"与"冻结成焦黑"两处判定都拿它做保险 ✓
##   —— 副本是我们自己装的 ✓ 最可靠 ✓（不受材质来源 / 节点层级影响 ✓）
func _has_wood_mats() -> bool:
	for m in _shader_mats:
		if m != null and is_instance_valid(m) and _mat_is_wood(m):
			return true
	return false


## ★★ 目标是否"保留型"（木质：烧完**留下焦黑** ✓ 不消失 ✓）
##   用户要求：叶子靠**材质 alpha 淡出**到透明 ✓ → 同一节点上的枝干必须**不被隐藏** ✓
##   判定依据见 _mat_is_wood ✓（shader 是 tree_burn_keep* / meta burn_mode=="wood"）
## ★★★ 三个材质来源都要查、且要**递归整棵子树** ✓（这两处都是踩过的坑 ✓）：
##   ① 网格自带材质   —— tree_small_02 这类「blender 导出、三面各带一份材质」的走这里 ✓
##   ② 逐面 override  —— 燃烧中/烧完之后走这里（_apply_in_shader_burn 把副本装在这里 ✓）
##   ③ 节点 override  —— 用「材质覆盖」装配的（sakura_tree / aux_scene 那种）走这里 ✓
##   ⚠ 不能再"只看第一个直接子 MeshInstance3D"✗：
##     · _apply_in_shader_burn 装完副本后会把 ③ 清成 null ✓（否则逐面副本不参与渲染 ✓）
##       → 只剩 ② 可查 ✓；只看 ① 就会判成"普通植被" ✓
##     · 组 "burnable" 可能挂在**场景根**而不是树节点上 ✓（用户自己新建场景时常见 ✓）
##       → 第一层子节点是 Node3D 而不是 MeshInstance3D ✗ → 原来直接返回 false ✗
##     → 后果不是"少烧一会" ✗ 而是 **收尾时 _target.visible=false 把整棵树藏掉** ✓✓
func _target_is_keep() -> bool:
	if _target == null or not is_instance_valid(_target):
		return false
	# ① 先看自己装上的燃烧副本（最准 ✓）
	if _has_wood_mats():
		return true
	# ② 再递归整棵子树，三个材质来源逐个查
	var stack: Array = [_target]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n == null:
			continue
		var mi := n as MeshInstance3D
		if mi != null and mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				if _mat_is_wood(mi.mesh.surface_get_material(s)):
					return true
				if _mat_is_wood(mi.get_surface_override_material(s)):
					return true
			if _mat_is_wood(mi.material_override):
				return true
		for c in n.get_children():
			stack.append(c)
	return false


## ★ 崩毁到顶：立刻隐藏整棵树（碎块仍留在场上继续落/淡出），并标记 burned_out。
## 与 _finish 分开的原因：_finish 会顺手把碎块一起藏掉；这里只处理"树体消失"这一步。
func _hide_collapsed_target() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	_target.visible = false
	_target.set_meta("burned_out", true)
	if _target.has_meta("burning"):
		_target.remove_meta("burning")


## 收尾：标记完成、关掉 _process、归还实例占用、熄灭火星，再按目标类型**冻结或还原**外观。
## 参数：无。返回：无。
## 副作用：清 _mm_custom_on；移除 meta("burning")；**可能**隐藏目标节点；
##   保留型树木会写 meta("burned_out") 并把材质副本定在终态；
##   普通植被则还原 material_override / material_overlay（避免被对象池复用时还带着焦黑）。
## 注意：逐实例路线刻意**不清零** custom data、不隐藏 MultiMesh、不还原 use_custom_data ——
##   清零等于"草又冒出来"，还原等于抹掉每个实例的数据。
## 注意：没有防重入保护，正常只被 _process 调用一次（_done 会在下一次 _process 开头拦住）。
func _finish() -> void:
	_done = true
	set_process(false)
	# ★ 逐实例燃烧**不清零**：烧掉的草要留在烧毁状态（清零会让它"又冒出来"）。
	#   也**不还原 use_custom_data** —— 一还原就等于把每个实例的数据抹掉。
	#   （同一片草再被烧时，_start_multimesh_burn 会重新写入它需要的实例。）
	_mm_custom_on.clear()
	# ★ 归还"本控制器占用的实例"（实例级防重入的配平；见 _claim_instances）
	_release_instances()
	if _sparks != null and is_instance_valid(_sparks):
		_sparks.visible = false
	for d in _sec_dups:
		if d != null and is_instance_valid(d):
			d.visible = false
	# ★ MultiMesh（addon 的一整片草）**绝不能隐藏**：那是一片/整张地图的草，
	#   隐藏 = "整个地图的草都烧没了"（用户实测）。它只做视觉燃烧、不消失。
	if _target != null and is_instance_valid(_target):
		# ★ 清掉"燃烧中"标记 ✓（配合 burn_node 的防重入 ✓）
		if _target.has_meta("burning"):
			_target.remove_meta("burning")
		if _multimeshes.is_empty():
			# ★ 普通植被（草等）：烧尽 -> 消失 ✓
			# ★★ 树：崩毁结束时**整棵消失** ✓（用户需求 ✓）
			#   collapse_time = 0（关闭崩毁）时保持旧行为：焦黑树架留下 ✓
			if collapse_time > 0.0 or not (_target_is_keep() or _has_wood_mats()):
				_target.visible = false
		elif _mat != null:
			_mat.set_shader_parameter("burn", 0.0)
			_mat.set_shader_parameter("ash", 0.0)
	# ★★ 保留型（树干/枝/整棵树 ✓）：**不还原材质** ✗→✓，而是**定在全焦黑** ✓
	#   原因（用户实测 ✓）：还原 = 烧过的树**恢复原样、变绿** ✗✓
	#   需求：烧过的树要保持焦黑（崩毁关闭时）/ 崩毁结束后节点已被隐藏 ✓
	if _target_is_keep() or _has_wood_mats():
		# ★★★ 记下"已烧毁"终态（用户要求 ✓）：第二次施法**直接跳过** ✗（见 burn_node 的检查 ✓）
		#   否则第二次会从原始材质重新复制 → 看起来"又还原了" ✓✓（用户实测 ✓）
		_target.set_meta("burned_out", true)
		# ★★ 分类冻结（修复"烧完又长回来"✗）：
		#   之前一律设 `ash = 0` ✗ → 连**叶片**的 ash 也被清零 ✓
		#   → 已经淡出消失的叶子**又变回原样** ✓✓（用户实测"烧完有长回来了"✓）
		#   现在：木质 → 焦黑留存（burn=1 / ash=0 ✓）
		#         叶片等 → 保持"烧尽"（burn=1 / **ash=1** ✓ 淡出到底 ✓ 不再长回来 ✓）
		for m in _shader_mats:
			if m == null or not is_instance_valid(m):
				continue
			var sm := m as ShaderMaterial
			if sm == null:
				continue
			var is_wood := sm.shader != null \
					and String(sm.shader.resource_path).contains("tree_burn_keep")
			sm.set_shader_parameter("burn", 1.0)
			if is_wood:
				sm.set_shader_parameter("ash", 0.0)
			else:
				sm.set_shader_parameter("ash", 1.0)
		print("[燃烧] 保留型 ✓ 已收尾（崩毁=隐藏消失 / 关闭崩毁=焦黑留存）：%s" % [
				_target.name if _target != null else "?"])
		return
	# 还原材质，避免这株被复用（对象池/重生）时还带着焦黑
	for d in _prev_override:
		var nd = d["n"]
		if nd != null and is_instance_valid(nd):
			nd.material_override = d["m"]
			nd.material_overlay = d["o"]


## 本次燃烧是否已经收尾（法术/管理器可轮询它来决定何时回收本控制器节点）。
## 参数：无。返回：_done（true = 已烧完，或已被放弃）。
## 副作用：无。
## 注意：只表示"收尾动作跑过了"，**不代表目标已经看不见**——关闭崩毁（collapse_time = 0）
##   的保留型树木会一直以焦黑可见；默认开着崩毁时目标会被隐藏。
func is_done() -> bool:
	return _done

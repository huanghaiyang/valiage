# ============================================================================
# 【文件头】road_path.gd —— 道路"路径声明"组件（纯数据收集，不生成任何几何体）
# ============================================================================
# 所属系统：世界组装层（scripts/world/），与 world_builder.gd / road_network.gd 同一条链路。
#
# 【职责】（一句话）把"这条路经过哪些点"从场景里收集成**有序的世界坐标数组**，
#   交给 RoadNetwork 去铺砂石路。本文件自己不建网格、不碰地形、不写文件。
#
# 【它在这条链路上的位置】
#   scenes/main.tscn 布局（Main/Roads/RoadPath*，控制点写成子 Marker3D）
#     → WorldBuilder.build()（scripts/world/world_builder.gd，本文件唯一的运行时调用方）
#     → WorldBuilder._build_roads()：遍历 Main/Roads 的子节点，筛出 RoadPath，
#        调 collect_points() 拿点，再调 roads.build_path(pts, path.width)
#     → RoadNetwork.build_path()（挂在 Main/Roads 上的脚本）：真正生成条带网格
#   本文件在编辑器里**不会**自动做任何事（没有 _ready/_process），只是被 @tool 标记，
#   使节点在编辑器内也具备类型与导出属性。
#
# 【关键依赖】
#   · RoadNetwork（class_name RoadNetwork，挂在 Main/Roads）：唯一消费者，接口为
#       build_path(points: Array, width: float = ROAD_WIDTH)。
#       它内部自己做 points.size() < 2 的守卫，并用 TerrainSystem.get_height_at() 取样高度。
#   · TerrainSystem：本文件**不直接引用**（只经由 RoadNetwork 间接使用）。
#   · autoload：无。信号：无（本文件不发也不连任何信号）。文件读写：无。
#   · 反查用：scenes/main.tscn 的 Roads 节点下当前没有 RoadPath 子节点（道路已从场景移除，
#       见 .runtime/main_before_road_removal.tscn 里的历史用法：RoadMain / RoadToOutpostA/B）。
#
# 【主要对外接口】
#   · collect_points() -> Array   唯一公开方法：返回 Vector3 世界坐标列表（顺序即铺路顺序）。
#   · 全部成员变量都是 @export，供检查器 / .tscn 配置，见下面各段说明。
#
# 【已知的坑与注意事项】（改前先读）
#   1. y 分量完全没用 ✓：RoadNetwork 只用点的 x/z 去采样地形高度，所以 Marker3D 摆多高、
#      start_point 的 y 填多少，都不影响路面高度 ✗ —— 别想靠调 y 把路"垫高"。
#   2. 两套坐标来源不一致 ⚠：子 Marker3D 取的是 global_position ✓（跟着父节点走），
#      而 start_point / extra_points 是**原样直接入列的世界坐标** ✓，
#      不乘本节点的 global_transform ✗ —— 把 RoadPath 节点整体搬家时，子 Marker 会跟着走，
#      这两个导出量不会 ✗，混用会造成控制点对不上位置的怪现象。
#   3. 子节点判定是 `c is Node3D`，**不是** Marker3D ⚠：任何 3D 子节点（MeshInstance3D、
#      嵌套的 RoadPath、装饰模型…）都会被当成控制点 ✓ —— 别在 RoadPath 下挂无关 3D 节点 ✗。
#   4. 顺序 = get_children() 的场景树顺序（.tscn 里的书写顺序）✓，不按节点名排序 ✗：
#      P02 一定排在 P10 前面，但"P10 排在 P9 后面"要靠手写顺序保证 ✓。
#   5. 控制点少于 2 个时**静默跳过** ⚠：过滤发生在调用方
#      （WorldBuilder._build_roads 里 `if pts.size() < 2: continue`），本文件不报错 ✗。
#      排查"路没铺出来"时先确认点数 ✗。
#   6. preview_in_editor 目前没有任何代码读取它（本文件无 _ready/_process，
#      road_network.gd 也没有"清理旧路面"的接口）✓ —— （推测）它是尚未接线的预留开关 ✗，
#      与 terrain_platform.gd 的同名导出（真的会在编辑器里生效）不是一回事 ✗。
# ============================================================================
@tool
class_name RoadPath
extends Node3D
## 道路：沿本节点的子 Marker3D（或 point_0..N 导出数组）铺一条砂石路。
## 在场景里添加/移动子 Marker3D 即可改路线，高度自动贴合地形。

# ==================== 导出参数（检查器可配） ====================
# 下面这些 @export 只影响两件事：①收哪些点（控制点来源）②路的视觉宽度。
# 没有隐藏副作用：不触发铺路、不改地形、不发信号 —— 改完参数后要重新走一遍
# WorldBuilder.build()（或重启游戏）才会看到效果。


## 路面宽度，单位：米。collect_points() 不管它，由调用方 WorldBuilder._build_roads
## 原样透传给 RoadNetwork.build_path(pts, path.width)。
## 默认 3.5：与 RoadNetwork.ROAD_WIDTH 的默认值保持一致（3.5m ≈ 一条砂石车道的观感宽度），
##   这样"RoadPath 不填 width"与"RoadNetwork 用默认宽度"两者结果相同，不会出现神秘差异。
## 调大 → 路面更宽（更适合主干道）；调小 → 更窄（适合小径）。
## 边界：RoadNetwork 内部用它当 BoxMesh 的 z 尺寸与接缝圆盘直径（width * 0.5 为半径），
##   给 0 或负数会生成退化/翻转的网格，别这么做；路面本身没有碰撞体，宽窄只影响外观。
## 路宽（米）
@export var width := 3.5

## 额外控制点（世界坐标）；与子 Marker3D 按顺序合并
##
## 取值语义（重要）：
##   · 逐项原样入列，**不做任何坐标变换** —— 所以填的是世界坐标 ✓，不是相对本节点的偏移 ✗；
##   · 追加位置：排在 start_point 与**全部**子 Marker3D 之后（见 collect_points），
##     适合用来给最后一段"续尾巴"，而不是插进路线中间；
##   · 每项的 y 会被地形高度覆盖（RoadNetwork 只用 x/z 采样），填 0 即可，填别的也没用；
##   · 想要"中途插点"只能靠给子节点排序 / 挪节点的位置。
## 默认值：空数组 —— 表示这条路完全由子 Marker3D 决定（场景里的既有用法就是这种）。
## 与 use_child_markers 的关系：两者相互独立，可以同时用，也可以只留一个。
@export var extra_points: PackedVector3Array = PackedVector3Array()

## 是否使用子 Marker3D 作为控制点
##
## true（默认）→ 遍历 get_children()，凡是 `is Node3D` 的子节点都取其 global_position 入列。
##   默认 true 是因为"在场景里拖 Marker3D 画路线"是本组件的主要用法，开箱即用最省事。
## false → 完全忽略子节点，只用 start_point / extra_points（纯数据驱动，适合脚本生成路线）。
##
## 注意（坑）：判定条件是 Node3D 而非 Marker3D —— MeshInstance3D、另一个 RoadPath、
##   任何 3D 装饰节点都会被当作控制点算进路线，所以别在本节点下挂无关的 3D 子节点。
## 顺序注意：get_children() 返回的是场景树顺序（.tscn 里的书写顺序），不按名字排序。
@export var use_child_markers := true

## 起点额外控制点
##
## 语义：一个**世界坐标**（同样不做节点变换），只有 include_start = true 时才会入列，
##   且排在所有点的最前面（整条路的起点）。
## 默认 (0, 0, 0) 的含义是"世界原点"，**不是**"本节点所在位置" —— 这是最常被误解的一项。
## 因为默认值在世界原点，若本节点不在原点附近，开启 include_start 会给这条路
##   额外拖出一条从原点出发的长路；场景里既有的 RoadPath 因此都把它关掉。
## 若确实要用：请显式把 x/z 填成想要的地面位置（y 随便填，会被地形覆盖）。
@export var start_point := Vector3(0.0, 0.0, 0.0)

## 是否包含 start_point（关掉则仅用子 Marker3D）
##
## true（默认）→ collect_points() 第一件事就是 append(start_point)。
##   （推测）默认给 true 是为了配合默认的 (0,0,0) 提供一个"什么都不配也有起点"的兜底。
## false → 跳过 start_point，路线完全由子 Marker3D（+ extra_points）决定。
##   历史 .tscn 里所有 RoadPath 都显式写了 include_start = false，
##   正是因为不想让 (0,0,0) 变成一条从世界原点拉出来的长路。
## 想彻底"只看子节点"时，通常要同时关掉它并保证 extra_points 为空。
@export var include_start := true

## 编辑器内实时预览铺路（需要 RoadNetwork 支持清理旧路面）
##
## 设计意图：勾上后希望在编辑器里就能重铺一遍路，边拖 Marker3D 边看效果。
## 现实状态（已核对）：
##   · 本文件没有任何 _ready / _process / _editor_preview 读取这个变量，
##     road_network.gd 也没有"清理旧路面"的接口 —— 勾选它不会有任何可见变化；
##   · 所以它当前是个**未接线的预留开关**（推测，留待后续实现）。
## 对照：terrain_platform.gd 里同名导出是真在用的（_ready → _editor_preview → apply）。
## 默认 false：即便将来实现，也避免编辑器里反复重建道路网格（每次重铺都会新建一堆
##   MeshInstance3D 且没有回收路径）。
@export var preview_in_editor := false

# ==================== 对外接口：控制点收集 ====================
# 全文件唯一有逻辑的地方。这里只做"取点 + 排序"，不做任何校验、不去重、
# 不采样地形、不生成网格 —— 那些都是 RoadNetwork 的职责。


## 按顺序收集控制点 —— 本文件唯一的公开方法（读取型，无副作用）
##
## 作用：把本节点能提供的全部控制点，按固定顺序汇总成一个**世界坐标**列表，
##   交给 RoadNetwork 沿点铺砂石路。
##
## 参数：无（数据全部来自成员变量与场景树）。
##   数据来源与顺序（1 → 2 → 3，也就是最终的铺路顺序）：
##     1) include_start = true 时，先放 start_point；
##     2) use_child_markers = true 时，按 get_children() 的场景树顺序，放各个
##        "is Node3D" 的子节点（含 Marker3D）的 global_position；
##     3) 最后按 extra_points 数组自身的顺序追加。
##   三者可任意组合；全部关掉且 extra_points 为空时返回空数组。
##
## 返回：Array，元素为 Vector3，全部是**世界坐标**。
##   返回类型故意写成无类型的 Array：消费方 RoadNetwork.build_path(points: Array, ...)
##   收的就是 Array，用 PackedVector3Array 反而要多一次转换。
##   · 可能返回 0 个点（所有来源都关掉）或只有 1 个点（只开一个来源且只有一个子节点）；
##   · 本函数**不校验点数** ✗：size() < 2 的过滤由调用方
##     WorldBuilder._build_roads 完成（`if pts.size() < 2: continue`），后果是那条路
##     静默不铺、也不报错 —— 排查"路没出来"时先数控制点。
##
## 返回值与内部状态：返回的是**新建数组** ✓（不是成员变量引用），调用方随便改都不会
##   影响本节点；元素是 Vector3 值类型，也不存在别名/引用共享问题 ✓。
##
## 副作用：无 ✓ —— 不改自身或子节点的 transform，不增删节点，不发信号，不写文件，
##   不读地形。因此可安全重复调用（幂等），也可在编辑器工具脚本里随意调用。
##
## 调用时机：运行时由 WorldBuilder.build() 第 4 步（地形生成 + 平台整平之后、
##   植被与地形网格重建之前）同步调用一次，每条 RoadPath 调一次。
##   顺序上必须在地形整平之后 —— 真正的贴地高度是 RoadNetwork 采样地形得到的，
##   本函数自己不读地形，但整条链路依赖"先整平、后铺路"。
##
## 注意事项：
##   · 返回值的 y 对铺路**没有意义**（RoadNetwork 会按 x/z 重新采样地形高度），
##     只有 x/z 参与定位 —— 所以别指望用 y 抬路；
##   · 子节点顺序 = 场景树顺序：在 .tscn 里往中间插一个 Marker3D，
##     就等于往路线中间插了一个控制点（改名不会改变顺序）；
##   · 子节点取 global_position（会随父节点整体移动 ✓），而 start_point / extra_points
##     是原样入列的世界坐标（**不随父节点移动** ✗）—— 两者混用时要特别小心；
##   · 本函数不会为控制点去重：重复位置会产生退化的短路段（RoadNetwork 里
##     分段长度 < 0.5m 的段会被跳过）。
## 按顺序收集控制点
func collect_points() -> Array:
	# 用无类型 Array 而非 PackedVector3Array：直接对接 RoadNetwork.build_path(points: Array)
	var pts: Array = []
	# 起点开关：默认开；场景里既有的 RoadPath 都关掉了它，以免从 (0,0,0) 拉出多余的长路
	if include_start:
		pts.append(start_point)
	# 子节点模式：遍历顺序 = 场景树顺序 = 铺路顺序（不按名字排序）
	if use_child_markers:
		for c in get_children():
			# 判定是 Node3D 而不是 Marker3D：任何 3D 子节点都会成为控制点
			if c is Node3D:
				# 取 global_position：RoadPath 整体平移时路线跟着走；
				# y 之后会被地形采样覆盖，所以 Marker3D 的 y 摆多少都无所谓
				pts.append((c as Node3D).global_position)
	# extra_points 最后追加，排在全部子节点之后（用于给末段续尾巴）
	for p in extra_points:
		pts.append(p)
	# 直接返回：点数是否够 2 个由调用方过滤，本函数不做校验、不报错
	return pts

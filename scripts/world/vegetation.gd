# ============================================================================
# vegetation.gd —— 全图植被 / 家具 / 山体系统（class_name VegetationSystem）
#
# 【职责】
#   把"铺满 900×900m 全图"的植被、家具、山体用 MultiMesh 实例化出来，并管理它们的
#   整个生命周期：按块视野剔除、碰撞体流式加载、地形高度贴合、区域清场/回收
#   （生物质与石材分开记账）、玩家放置与撤销（每类别一条历史栈）。
#
# 【所属系统】
#   world 层。挂在 main.tscn 的 Main/Vegetation 节点上（main.gd 里
#   `@onready var vegetation: VegetationSystem = $Vegetation`）。子结构：
#     Vegetation/Chunk_<bx>_<bz>   运行时 MultiMesh 渲染块（_create_block 创建）
#     Vegetation/Chunk_<bx>_<bz>/TreeCollisions  该块的碰撞体容器
#     Vegetation/Spawned/<cat>/…   场景烘焙好的撒点节点（只存变换 + metadata，不含模型）
#
# 【关键依赖】
#   · TerrainSystem（_terrain）：读 HALF（地块半边长）、get_height_at()、is_in_river()；
#     由 WorldBuilder.build() 或 populate_auto() 注入。
#   · Settings（autoload）：质量档位写 view_radius、调 set_grass_visible()。
#   · Weather（autoload）：通过 wind_materials() 取走各分类的风摇材质，每帧写入风参数。
#   · Camera3D：由 set_camera() 注入；它既是视野剔除的锚点，也是碰撞流式化的锚点。
#   · building_manager.gd 的 TREE_MODELS：顺序必须与 _category_models["tree"] 完全一致。
#   · 资源：assets/materials/vegetation_wind.tres、assets/shaders/vegetation_wind.gdshader、
#     assets/models/{furniture,dungeon,mountain,plants}/*.glb。
#
# 【主要对外接口】
#   · 放置：add_tree / add_bush / add_flower / add_grass / add_rock / add_mushroom /
#           add_stump / add_furniture / add_mountain（返回实际使用的变体下标，-1 表示失败）
#   · 撤销：remove_last_tree / remove_last_bush / … / remove_last_mountain
#   · 区域：clear_around(center, radius) 清场（不计收益）；
#           recycle_around(center, radius) 回收，返回 {"biomass": float, "stone": float}
#   · 世界构建：build_from_scene() 按 Spawned 节点铺底；sync_heights() 地形改动后重新贴地；
#               populate_auto() / plan_layout() 自动撒点与烘焙导出落点
#   · 查询：category_variant_count / category_model_path / category_model_mesh /
#           category_base_count / model_preview_offset / model_footprint_center /
#           find_nearest_interactable
#   · 相机与画质：set_camera / set_grass_visible / wind_materials / view_radius
#
# 【已知的坑与不变量（动这个文件之前务必读）】
#   1. 每块碰撞队列 col_queue 里"已建好的碰撞体"永远是它的**前缀**，col_built_n 是
#      前缀长度，col_bodies[i] 与 col_queue[i] 一一对应。任何裁剪/删除/插队都要维持它。
#   2. 碰撞体按**实例到锚点的距离**流式创建，绝不按块中心：块边长 150m、块心间距 225m，
#      按块心判断会让玩家身边的实例永远建不到碰撞（历史 bug）。
#   3. collision_radius（默认 60m）必须远小于 view_radius（默认 220m，Settings 会改）。
#   4. 分类模型表允许为空（当前 flower/grass/mushroom/rock/stump 就是空的）：空分类在
#      build_from_scene() 里整支跳过，不要改成"逐个尝试放置再失败"。
#   5. layout_mode = true 时只往 plan_items 记落点，不建任何碰撞体（烘焙用）。
#   6. 树表与 building_manager.TREE_MODELS 错位 → "滚轮显示 A、种下 B"。
#   7. sync_heights() 删除实例用的是 O(1) 交换删除，循环里**不能** i -= 1（会越界）。
# ============================================================================
class_name VegetationSystem
extends Node3D
## 植被系统：Kenney Nature Kit 第三方模型（CC0）
## 特点：
## 1. 全图铺满：按 150m 分块，每块按类别/模型变体使用 MultiMesh 实例化，密度覆盖 900×900m 全图
## 2. 视野剔除：仅激活相机 view_radius 范围内的块，远处块整块隐藏（含树碰撞禁用），大幅优化渲染与物理
## 3. 多样化：树/灌木/花/草/石/蘑菇/树桩 7 大类，每类多种模型；花/草/蘑菇/树桩叠加实例随机配色与随机旋转

# ==================== 常量与类别配置 ====================

# ---- 分块 ----
# CHUNK_SIZE 是渲染/剔除的基本粒度，也是所有"世界坐标 → 块下标"换算的分母
# （floor((pos + _terrain_half) / CHUNK_SIZE)）。调大：块数变少、每块 MultiMesh
# 容量变大、剔除粒度变粗（近处一块里既有很多可见物也有很多不可见物，剔除收益下降）；
# 调小：块数按平方增长（36 个子节点 → 更多 draw call 与容器），且每块容量 cap_per 变小，
# 容易出现"某块某变体放满"而失败。150m 是当前地图 900m 与块数（6×6）的折中。
const CHUNK_SIZE := 150.0          # 每块边长（米），900m 地图 → 6×6 块

# ============================================================
# 花草树木：**当前为空表**。
#
# 这里先后放过两版自制模型（第三方 KayKit/Kenney 自然包 -> 自建几何体），
# 两版都按用户要求移除了（自建那版是"面数过低、无法使用"）。
# 分类表留空 = 世界暂时只长岩石 / 树桩 / 家具 / 山体这些非植物件，
# 等新的建模参考图到了再填回来。
#
# 关键：**不需要动烘焙好的 59220 个场景节点**。那些节点只存 `cat` + 变换
# （metadata/cat、px/py/pz、scale、yaw、variant），具体模型是运行时从
# `_category_models[cat]` 取的 —— 所以填回这张表就等于把整张地图的植被种回来。
# 撒点布局是烘焙出来的、带地形/道路/村庄的相对关系，**特意保留**，
# 空分类在 build_from_scene() 里直接跳过（不会逐个尝试放置再失败）。
# ============================================================

# ---- 类别模型（多样化） ----




## ROCK_MODELS：已清空 —— 用户要用第三方工具做地形/植被，先留白。
## 要恢复就把模型路径填回来。
const ROCK_MODELS := []

## STUMP_MODELS：已清空 —— 用户要用第三方工具做地形/植被，先留白。
## 要恢复就把模型路径填回来。
const STUMP_MODELS := []

# ---- 家具/梯子（Kenney Furniture Kit + KayKit Dungeon，CC0，低多边形卡通风） ----
## FURNITURE_MODELS：家具/梯子模型路径表（顺序即"变体下标"，对外是稳定协议）。
## 下标会被主程序保存（_set_used_variant / category_model_path）并原样回传给
## add_furniture(..., variant)，所以只能**追加**，不能在中途插入或删除，否则存档里的
## 家具变体会错位。另外家具的可交互类型与坐高是**按文件名推导**的
## （见 _furniture_kind / _furniture_stand_height），改文件名会同时改掉行为。
## 数量变化会让每块每变体的容量 cap_per 重算，与 _category_max["furniture"] 联动。
const FURNITURE_MODELS := [
	"res://assets/models/furniture/bench.glb",
	"res://assets/models/furniture/chair.glb",
	"res://assets/models/furniture/chairRounded.glb",
	"res://assets/models/furniture/loungeChair.glb",
	"res://assets/models/furniture/table.glb",
	"res://assets/models/furniture/tableRound.glb",
	"res://assets/models/furniture/tableCoffee.glb",
	"res://assets/models/furniture/desk.glb",
	"res://assets/models/furniture/sideTable.glb",
	"res://assets/models/furniture/stoolBar.glb",
	"res://assets/models/furniture/bookcaseOpen.glb",
	"res://assets/models/furniture/bookcaseClosed.glb",
	"res://assets/models/furniture/bedSingle.glb",
	"res://assets/models/furniture/bedDouble.glb",
	"res://assets/models/furniture/pillow.glb",
	"res://assets/models/furniture/lampRoundFloor.glb",
	"res://assets/models/furniture/lampRoundTable.glb",
	"res://assets/models/furniture/lampWall.glb",
	"res://assets/models/furniture/pottedPlant.glb",
	"res://assets/models/furniture/rugRound.glb",
	"res://assets/models/furniture/stairs.glb",
	"res://assets/models/furniture/stairsOpen.glb",
	"res://assets/models/furniture/stairsCorner.glb",
	"res://assets/models/dungeon/stairs_wood.glb",
	"res://assets/models/dungeon/stairs_wide.glb",
	"res://assets/models/dungeon/wall_scaffold.glb",
	"res://assets/models/dungeon/barrel_large.glb",
	"res://assets/models/dungeon/barrel_small.glb",
	"res://assets/models/dungeon/chest.glb",
	"res://assets/models/dungeon/candle.glb",
	"res://assets/models/dungeon/torch_mounted.glb",
	"res://assets/models/dungeon/table_medium.glb",
	"res://assets/models/dungeon/shelf_large.glb",
	"res://assets/models/dungeon/bed_decorated.glb",
]

# ---- 山体（Kenney Nature Kit cliff 悬崖/岩壁，CC0，风格统一） ----
## MOUNTAIN_MODELS：山体（悬崖/岩壁）模型路径表，下标同为对外变体协议，只可追加。
## 山体走 COLLISION_LAYER 的模型三角网碰撞，scale 通常传 4.0（见 main.gd），
## 所以碰撞形状必须共用 _shape_for() 的缓存，否则每座山都会复制一份三角网。
const MOUNTAIN_MODELS := [
	"res://assets/models/mountain/cliff_block_rock.glb",
	"res://assets/models/mountain/cliff_large_rock.glb",
	"res://assets/models/mountain/cliff_steps_rock.glb",
	"res://assets/models/mountain/cliff_corner_rock.glb",
	"res://assets/models/mountain/cliff_diagonal_rock.glb",
	"res://assets/models/mountain/cliff_half_rock.glb",
	"res://assets/models/mountain/cliff_halfCorner_rock.glb",
	"res://assets/models/mountain/cliff_cornerLarge_rock.glb",
	"res://assets/models/mountain/cliff_rock.glb",
	"res://assets/models/mountain/cliff_top_rock.glb",
	"res://assets/models/mountain/cliff_cave_rock.glb",
	"res://assets/models/mountain/cliff_waterfall_rock.glb",
]

# ---- 每类全图上限（已大幅放宽，玩家种植不再受感知限制；满员时自动顶掉最近一棵兜底） ----
## MAX_*：每类的**全图总实例上限**（不是每块上限；每块上限是 _create_block 里按
## 类上限 / 块数 / 变体数摊出来的 cap_per）。达到上限时 add_* 会先顶掉该类最近放置的
## 一个实例（remove_last_*）再放新的，所以"种不下去"几乎不会发生，代价是**最老/最近
## 放的那一株会被悄悄替换**。改大的效果：内存与 MultiMesh 容量线性上升；改小则频繁
## 触发顶替。草类上限最大（20 万）是因为草单价最便宜、数量级本来就高。
const MAX_TREES := 20000
const MAX_BUSHES := 20000
const MAX_FLOWERS := 80000
const MAX_GRASS := 200000
const MAX_ROCKS := 9000
const MAX_MUSHROOMS := 6000
const MAX_STUMPS := 4000
const MAX_FURNITURE := 4000
const MAX_MOUNTAIN := 2000

# ---- 每类生物质量（操作地形/放置建筑时植被自动回收） ----
## 生物质：植被类回收为生物质
const BIOMASS := {
	"tree": 10.0,
	"bush": 4.0,
	"flower": 1.5,
	"grass": 0.5,
	"mushroom": 2.5,
	"stump": 5.0,
}
## 石材：石头单独回收为石材（不混入生物质）
const STONE_VALUE := {
	"rock": 8.0,
}

## 使用实例随机配色的类别：这些类别的 MultiMesh 打开 use_colors，具体颜色在
## _add_instance 里用 set_instance_color 写入（见 _random_plant_color）。
## 注意区分两种颜色来源：**每实例**的染色走实例色；**模型本身**的基色是
## _bake_surface_colors() 烘进顶点色的（material_override 会顶掉原材质）。
## 只给"确实需要花色/草色差异"的低矮植被开启 —— 多一路顶点色属性要占带宽。
# 使用实例随机配色的类别
const COLORED_CATEGORIES := ["flower", "grass", "mushroom", "stump"]
## 开启阴影投射的类别。其余类别在 _create_block 里设成
## SHADOW_CASTING_SETTING_OFF：低矮植被/杂物的投影几乎看不出来，但省下的是整个
## 阴影 pass 的绘制。往表里加类别 = 更立体但更贵，移出 = 更省。
# 开启阴影的类别（低矮植被/杂物关闭阴影，明显提升阴影 pass 性能）
const SHADOW_CATEGORIES := ["tree", "bush", "furniture", "mountain"]

# ==================== 运行时状态 ====================

## 本系统唯一的随机源。除撒点外，实例的随机朝向、随机缩放、随机配色也都走它。
## _ready() 里先 randomize()（每次运行都不同），而 populate_auto / plan_layout
## 会在撒点前把 seed 设成 scene_seed，让"烘焙出来的布局"与运行时重跑一致。
var _rng := RandomNumberGenerator.new()
## 场景播种种子：固定后自动撒点布局可复现（烘焙与运行时一致）
## <= 0 表示不固定种子（保持 _ready 里的 randomize 结果，每次运行都变）。
var scene_seed := 20260927
## 布局模式：只记录落点、不建碰撞体（供烘焙导出布局）
## 打开期间主程序不应把实例当"真实存在"（不建碰撞、不吃撤销栈以外的语义）。
var layout_mode := false
## 布局模式下收集的落点
## 每项：{cat, pos, scale, yaw, variant, color, bx, bz}，由 plan_layout 打包导出。
var plan_items: Array = []

# 块数据：_blocks 为一维数组，index = bz * _block_n + bx
# 每个元素 Dictionary：
#   "node"       : Node3D（块容器，visible 控制整块显隐）
#   "mmis"       : {cat: Array[MultiMeshInstance3D]}（每模型一个）
#   "counts"     : {cat: Array[int]}
#   "collisions" : Node3D（树碰撞容器）
var _blocks: Array = []
## 每块边长方向上的块数（总块数 = _block_n²）。默认 0 表示尚未初始化，
## 由 _ensure_blocks() 用 maxi(1, ceili(_terrain_half * 2 / CHUNK_SIZE)) 算出来。
## 它同时是"块下标 ↔ 一维索引"换算（bi = bz * _block_n + bx）的系数，不要在中途改。
var _block_n := 0
## 地块半边长（米）：世界坐标范围是 [-_terrain_half, +_terrain_half]。
## 默认 450.0 = TerrainSystem.HALF（900m 地图的默认值）；地形重建换成别的尺寸时
## 必须由调用方（WorldBuilder / populate_auto / plan_layout）重新赋上真实 HALF，
## 否则所有 pos → 块下标、中心坐标换算都会整体偏移。
var _terrain_half := 450.0
## 地形系统引用（可空）：仅用于查询高度与"是否在河道里"。
## 为 null 时 sync_heights() 直接返回 0、_random_in_block 会崩，所以撒点前必须先注入。
var _terrain: TerrainSystem = null

# 可见性（由 Settings 质量等级驱动）
## 视野剔除半径（米）：只有块中心落在 view_radius + CHUNK_SIZE*0.5 内的块才可见。
## 默认 220.0；Settings 按质量档位覆盖（130/170/220/280）。调大 = 看得更远也更贵，
## 调小 = 省性能但远处会整块消失。★ 它**不影响**碰撞半径（collision_radius 独立）。
## setter 里立刻跑一次完整 _update_visibility()，所以赋值是"重活"，不要每帧写。
var view_radius := 220.0:
	set(v):
		view_radius = v
		_update_visibility()
## 剔除与碰撞流式化共用的锚点相机；由 set_camera() 注入。为 null 时不做剔除、
## 不建碰撞（保持默认可见性），避免在世界生成完成前误判。
var _camera: Camera3D = null
## 距下次跑 _update_visibility() 的剩余时间（秒），由 VIS_UPDATE_INTERVAL 重置。
var _vis_timer := 0.0
## 剔除更新间隔（秒）：0.2s ≈ 5Hz。剔除要遍历全部块（36 个）+ 写入可见性，
## 没必要每帧跑；调小会更灵敏但更耗，调大会看到"块成片地跳出来"。
const VIS_UPDATE_INTERVAL := 0.2
## 草丛是否可见（低画质档位由 Settings.set_grass_visible 关掉）。
## 只切换块的 grass MultiMeshInstance3D.visible，不移除实例，所以随时能切回来。
var _grass_visible := true

# 撤销历史（每项 [bx, bz, variant]）
# ★ 补充：现在每条记录实际是 Dictionary（见 _add_instance 末尾的 hist.append）：
#   {bx, bz, vi, pos, scale, yaw, color, cat}。上面那行"每项 [bx, bz, variant]"是旧格式，
#   _remove_last() 仍兼容数组格式，所以两种都别直接删。每类别一条独立栈，
#   remove_last_* 就是弹这条栈（满员顶替走的也是同一条路径）。
var _tree_hist: Array = []
var _bush_hist: Array = []
var _flower_hist: Array = []
var _grass_hist: Array = []
var _rock_hist: Array = []
var _mushroom_hist: Array = []
var _stump_hist: Array = []
var _furniture_hist: Array = []
var _mountain_hist: Array = []
## 各类别的碰撞参数：形状缓存 + 按类别登记的碰撞体
## 除花草外的所有类别都有模型三角网碰撞（与房屋一致：贴合视觉模型的多面体）
## COLLISION_CATEGORIES：需要**模型三角网碰撞体**的类别。
## flower / grass 不在其中：它们又多又矮，建碰撞体得不偿失（人本就能穿草）。
## 注意"由谁登记"分两路，合起来保证每个实例只登记一次：
##   · bush / mushroom / stump —— 在 _add_instance 内部登记（immediate=true）；
##   · tree / rock / furniture / mountain —— 由各自的 add_* 包装函数登记，
##     或由 place_scene_item() 为场景烘焙节点登记。
const COLLISION_CATEGORIES := ["tree", "bush", "rock", "mushroom", "stump", "furniture", "mountain"]
## 植被/家具静态体所在的物理层掩码值（项目约定：1=角色、2=地形、4=建筑、8=植被/家具，
## 见 player.gd / terrain.gd / building_manager.gd 里的同类硬编码）。
## 静态体自己的 collision_mask 被设成 0（只当障碍物，不去检测别人），
## 所以改这一层会影响角色的碰撞掩码是否还能撞到植被。
const COLLISION_LAYER := 8              # collision_mask 2|4|8 中的第 3 层（建筑/植被层）

## 形状缓存：{cat: {model_path: ConcavePolygonShape3D}}
var _shape_cache: Dictionary = {}
## 模型局部 AABB 与放置偏移缓存（每模型一份，视觉与碰撞共用同一偏移）
var _model_aabb_cache: Dictionary = {}
var _model_offset_cache: Dictionary = {}
## 已放置碰撞体：{cat: Array[StaticBody3D]}，与实例一一对应（顺序按类别）
var _collision_nodes: Dictionary = {}

## ---- 碰撞流式化：只给视野内的块建碰撞体 ----
## 每块待建碰撞的实例描述（懒加载队列），碰撞体随块进出视野创建/释放
## 待补建碰撞的块下标列表。_stream_collisions() 每帧重建它（只留下没建完的块），
## _update_visibility() / _requeue_collision_blocks() 往里追加并用 has() 去重。
## 同一时刻在册的一般只有碰撞半径附近的少数几块，所以不必换成字典。
var _pending_blocks: Array = []          # 需要补建碰撞的块下标
## 重新排队的节流计数（帧）。_requeue_collision_blocks() 每次调用先自减，
## 归零才真正干活并把值重置为 6 —— 即约每 6 帧（60fps 下 ≈0.1s）检查一次
## "玩家是否走远到需要让队列排序失效"。调小更及时但更耗。
var _requeue_timer := 0                  # 重新排队的节流计数（帧）
## 上次给队列排序时用的参考位置；玩家离它超过阈值就让排序失效并重排
var _sort_anchor := Vector3.INF
## 每帧用于"建碰撞体"的时间预算（毫秒）。建一个 StaticBody3D（含入树与物理服务器
## BVH 插入）实测要好几毫秒，所以必须严格分摊，否则一帧内建十来个直接掉帧。
## 调试/权衡：调大 = 碰撞追得更快但帧率抖动；调小 = 帧率稳但树到跟前可能还没碰撞。
## 3.0ms 是当前折中（注释里记录了曾经 12ms / "每 16 个才查一次"的历史事故）。
var _stream_budget_ms := 3.0             # 每帧用于建碰撞的时间预算（分摊，避免卡顿）
## 单个实例建碰撞（StaticBody3D + 入树 + 物理服务器 BVH 插入）实测要好几毫秒，
## 所以预算必须**每个实例都查一次**：以前是每 16 个才查，一次突发能冲到 150ms+
## （实测：走路时 p95 = 169ms，把预算降到 0.2ms 后 p95 = 48ms）。
## 12ms 的预算也太大：整帧才 30ms 上下，建碰撞最多只该占一小块。
## 重排触发：锚点移动超过这个距离 / 距上次重排至少这么久（毫秒）。
## 原来只有 1 米且无时间下限 —— 走路时几乎每帧都重排，是卡顿尖峰的源头。
const RESORT_DISTANCE := 8.0
const RESORT_INTERVAL_MS := 800
## 建体循环遇到"超出半径"的项时，最多往后扫描/挪动多少项（代替直接 break）。
const BUILD_SCAN_WINDOW := 64
# 上面三个常量的调参效果（从那段历史事故里总结）：
#   RESORT_DISTANCE 调小 → 走路时重排频繁，帧时间尖峰回来；调大 → 排序更陈旧，
#     半径边缘的实例更容易被漏建（靠 BUILD_SCAN_WINDOW 兜底）。
#   RESORT_INTERVAL_MS 与距离条件是**"与"**关系：两者都满足才重排，调小等于放宽。
#   BUILD_SCAN_WINDOW 调大 → 一次能容忍更多"排序过期"的项，代价是单块建体耗时上限更高；
#     调小 → 排序一过期就提前收手，剩下的留到下一帧或下次重排再建。
## 碰撞体只在这个半径内建。必须**远小于** view_radius：视野 220m 内的块有几十个，
## 按 12ms/帧的预算根本追不上玩家前进速度 —— 于是"视野外走进来"的树到了跟前
## 还没建好碰撞，表现就是穿模。60m 内通常 2~3 个块，一两帧就建完。
var collision_radius := 60.0
## 可交互家具注册表，由 _rebuild_interactables() 遍历全部家具实例重建：
## 每项 {kind, pos, yaw, height}。find_nearest_interactable() 就在这张表上找最近的。
## ★ 家具增删后（add_furniture / remove_last_furniture / clear_around / recycle_around）
## 必须重建，否则玩家会坐到/睡到已经消失的家具上。
var _interactables: Array = []          # 可交互家具注册表（kind/pos/yaw/height）
## 家具模型路径 → 站立面/爬升高度（米）。同一条路径只推算一次；模型文件换了要重启才生效。
var _furniture_height_cache: Dictionary = {}  # 家具模型路径 -> 站立面/爬升高度缓存

# 类别元数据：分类名 → 模型路径数组。数组**下标就是变体下标**（对外稳定协议，
# 只能往后追加，不能插入/删除/换序），空数组表示该类当前不可用。
# 键集合（9 类）必须与 _category_max / _category_total 一致，否则查表直接报错。
# 类别元数据
## 自制参天大树（参考图"魔法山谷"系列）。真实尺寸建模，约 19.6m 高
## = 角色 1.7m 的 11.5 倍；树干/树枝/板根是真几何，树叶是带 alpha 的叶片卡片，
## 树皮 2048² / 叶簇 1024² 各有 BaseColor + Normal（树皮另有 ORM）。
var _category_models := {
	# 树：**顺序必须与 building_manager.TREE_MODELS 完全一致**。
	# 游戏内树工具的滚轮切换读的是这里的数量/下标（_current_variant），而实际放置是
	# buildings.add_tree(variant) 去查那张表 —— 两张表错位就会"滚轮显示 A、种下 B"。
	# 另外：全图撒点入口（populate_auto / plan_layout / _run_scatter）目前**没有任何调用方**，
	# 场景里也没有烘焙的撒点节点（metadata/cat = 0），所以填这张表只是"让模型可选"。
	"tree": [
		"res://assets/models/plants/autumn_tree_1.glb",
		"res://assets/models/plants/craystal_red_tree.glb",
	],
	# 花/草/蘑菇仍留空。
	"bush": [],
	"flower": [],
	"grass": [],
	"rock": ROCK_MODELS,
	"mushroom": [],
	"stump": STUMP_MODELS,
	"furniture": FURNITURE_MODELS,
	"mountain": MOUNTAIN_MODELS,
}
## 每类的实例上限表（由 MAX_* 常量拷贝而来）。_add_instance 开头的满员判断读的是它，
## add_* 里的"先顶掉最近一个"也按它比较。做成 var 而不是直接用常量，是为了允许运行时
## 覆盖上限；键必须与 _category_models / _category_total 完全一致，缺键会直接报错。
var _category_max := {
	"tree": MAX_TREES,
	"bush": MAX_BUSHES,
	"flower": MAX_FLOWERS,
	"grass": MAX_GRASS,
	"rock": MAX_ROCKS,
	"mushroom": MAX_MUSHROOMS,
	"stump": MAX_STUMPS,
	"furniture": MAX_FURNITURE,
	"mountain": MAX_MOUNTAIN,
}
## 每类当前已放置的实例总数（跨全部块，不含场景烘焙节点本身）。放置时 +1、
## _remove_last() 时 -1、recycle_around() 时减去实际移除数，_reset_totals() 清零。
## world_builder 会打印它作为"本局铺了多少植被"的报表。
var _category_total := {
	"tree": 0,
	"bush": 0,
	"flower": 0,
	"grass": 0,
	"rock": 0,
	"mushroom": 0,
	"stump": 0,
	"furniture": 0,
	"mountain": 0,
}
## 每类的随机缩放区间 [min, max]（无量纲倍数）。_run_scatter() 撒点时在区间内取 s，
## 再传给 add_*；玩家放置则用主程序写死的缩放（例如树 1.0、山体 4.0、花 1.1）。
## 调大 → 个体更大、更容易穿模或顶到建筑；调小 → 更密更小但看不清形态。
## furniture / mountain 固定 1.0：家具按真实尺寸，山体靠调用方显式传 4.0。
## 这个区间必须与 models 的**自带真实尺寸**配套：如果哪天换了小尺寸模型却没改这里，
## 场景里就会出现"巨大树"或"盆景树"。
var _scale_ranges := {
	# 花草树木**已经换成自制模型**，它们是按参考图的真实尺寸建的（catalog3d.json 的
	# height_m），所以这里的倍数只做"个体差异"，不再需要补偿小模型 ——
	# 旧范围里的 2.6~5.2 是给第三方 1.15~1.71m 的小树配的，套到自制树上会长成 25m 巨树。
	# 参考表 4 做完后树用的是真正的大树模型（catalog 里 3.4~5.1m），
	# 所以这里只要个体差异，不再是"用倍数把小树撑大"。
	"tree": [0.85, 1.25],
	"bush": [0.85, 1.45],
	"flower": [0.80, 1.25],
	"grass": [0.85, 1.40],
	"rock": [0.6, 1.6],
	"mushroom": [0.60, 1.00],
	"stump": [0.8, 1.6],
	"furniture": [1.0, 1.0],
	"mountain": [1.0, 1.0],
}

## 共享的风摇材质：所有植被实例共用同一份材质资源。
## 风向/风力由 Weather 每帧写进这份材质的 uniform（不能用全局着色器参数 —— 见
## assets/shaders/vegetation_wind.gdshader 顶部说明）。
const WIND_MATERIAL := preload("res://assets/materials/vegetation_wind.tres")

## 各分类的摆幅系数（每米高度的水平位移量），按实测标定：
##   0.35 → 6m 高物体在大风下横向摆 3~5px（12m 外看约 0.5m 幅度，明显但不夸张）
##   0.20 → 同样条件下只有 3px，远看几乎看不出（旧默认 0.06 完全不可见）
## 越低矮越贴地的越不该乱晃：草只是轻轻抖，树冠要明显摆。
const SWAY_BY_CATEGORY := {
	"tree": 0.35,
	"bush": 0.26,
	"flower": 0.24,
	"grass": 0.20,
	"mushroom": 0.08,
	"stump": 0.04,
	"rock": 0.0,
	"furniture": 0.0,
	"mountain": 0.0,
}
## 运行时生成的风摇材质（每分类一份，只改 sway_scale）。
## 必须保留引用，否则材质会被回收；天气系统要同时更新所有分类。
var _wind_materials: Array[ShaderMaterial] = []

# ==================== 生命周期 ====================

## 初始化本系统的随机源。**不做任何世界构建** —— 地形引用、撒点、相机都等
## main.gd 走 WorldBuilder / set_camera 之后再注入（那时 _terrain / _terrain_half
## 才有真实值）。唯一副作用是 _rng.randomize()，让每次运行的朝向/缩放/配色都不同。
## 注意：_ensure_blocks() / build_from_scene() / _update_visibility() 都不在这里调用，
## 所以世界生成前本节点是"空壳"；_blocks 为空时所有遍历都会安全跳过。
func _ready() -> void:
	_rng.randomize()
	# 花草树木（含图鉴里那 222 株）已按用户要求整体移除，分类表**留空**：
	# 世界暂时只长岩石/树桩/家具/山体这些非植物件，等新参考图重做后再填回来。
	# 注意 main.tscn 里烘焙好的 59220 个撒点节点**保留**（那是布局数据，不是模型），
	# 空分类会在 build_from_scene() 里直接跳过，不再逐个尝试放置。






# ==================== 风摇材质接口 ====================

## 取某分类的风摇材质；首次访问时复制一份并把 sway_scale 设成该分类的值
##
## 参数：cat —— 分类名（不在 SWAY_BY_CATEGORY 里时回退 0.10）。取值范围即分类键。
## 返回：ShaderMaterial；WIND_MATERIAL 资源缺失时返回 null（调用方必须判空）。
## 副作用：首次访问会 duplicate() 材质、写入 meta("cat") 并追加进 _wind_materials
##   （该数组是强引用，用来防止 duplicate 出来的资源被回收）。
## 调用时机：_create_block() 为每个分类建 MultiMesh 时取一次；之后命中缓存。
## 为什么每分类一份而不是共用：摆幅要按类别标定（树 0.35、草 0.20…），而一个
##   MultiMeshInstance3D 的 material_override 只能挂一份材质，只能按分类各来一份。
## 注意：缓存键是材质上的 meta("cat")，所以**不要**在别处改动这些材质的 meta。
func _wind_material_for(cat: String) -> ShaderMaterial:
	if WIND_MATERIAL == null:
		return null
	for m in _wind_materials:
		if str(m.get_meta("cat", "")) == cat:
			return m
	var m: ShaderMaterial = WIND_MATERIAL.duplicate() as ShaderMaterial
	m.set_meta("cat", cat)
	m.set_shader_parameter("sway_scale", float(SWAY_BY_CATEGORY.get(cat, 0.10)))
	_wind_materials.append(m)
	return m


## 供天气系统接管风参数：返回所有分类的风摇材质（风参数相同，sway_scale 各异）
##
## 参数：无。
## 返回：Array[ShaderMaterial] 的**浅拷贝**（.duplicate()）。天气系统改动这个数组
##   不会影响本系统内部状态；但元素是同一批材质对象引用，改它们的 uniform 会立刻生效。
## 副作用：无（不主动创建材质 —— 只有 _create_block 见过的分类才会在里面）。
## 调用时机：main.gd 在世界生成之后调 Weather.bind_world(..., vegetation.wind_materials())，
##   **必须晚于植被建成**，否则数组为空、天气的风参数没地方写。
## 注意：Weather.bind_world() 内部会先清空它自己那份列表，所以每次重建世界都要重传。
func wind_materials() -> Array[ShaderMaterial]:
	return _wind_materials.duplicate()


# ============================================================ 几何体植物
# 这一节是"一丛几十片叶子"的自制几何体植被专用的**网格合并**工具。
# 现状：自制植被按需求整体移除后，_extract_mesh_merged / _collect_merged 在本文件里
# 已经没有调用方（main.gd 里那个同名函数是它自己的另一份实现），保留是为了将来重新启用。
# 别以为可以顺手删：一旦分类表里填回"多子网格"的 GLB，_extract_mesh() 只会取第一个
# 子网格，整丛植物会退化成一片叶子（历史症状见下面 _extract_mesh_merged 的注释）。









## 把 GLB 里的**所有**子网格合并成一张单面网格（应用各自的节点变换）。
##
## 为什么必须合并：这些几何体植物是"一丛几十片叶子"，每片叶子在 Blender 里是独立
## 对象、各有自己的 loc/rot/scale。GLB 导入后是几十个 MeshInstance3D 子节点，
## 而 `_extract_mesh()` 只取**第一个** —— 结果整丛植物只剩一片叶子。
## 实测症状：草丛在游戏里是一根细条、白铃花只剩一个白点、穗草只剩一根穗
## （AABB 量出来 0.219 x 0.379 x 0.0039，几乎是一张纸）。
## 合并成单面网格后每株只占 1 个节点，也顺便省掉几十次 draw call。
func _extract_mesh_merged(path: String) -> Mesh:
	var scene: PackedScene = load(path)
	if scene == null:
		return null
	var inst := scene.instantiate()
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var idx := PackedInt32Array()
	_collect_merged(inst, Transform3D.IDENTITY, verts, norms, cols, idx)
	inst.free()
	if verts.is_empty():
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


## 递归收集网格：把 n 及其所有后代的网格顶点/法线/顶点色/索引，按节点变换拼进
## 调用方给的四个 Packed 数组（**原地追加**，不返回任何东西）。
##
## 参数：
##   n    —— 当前节点（任意 Node；只有 Node3D/MeshInstance3D 会参与变换与取网格）。
##   xf   —— 父级累计变换；本函数会乘上 n 自己的 transform 再往下传。
##   verts/norms/cols/idx —— 输出缓冲，四者由调用方保证长度一致（位置一一对应）。
## 返回：无（void）。
## 副作用：只写输出数组；不修改场景树、不释放节点（释放由调用方做）。
## 注意事项：
##   · 法线用**逆转置**矩阵变换（t.basis.inverse().transposed()），否则非等比缩放
##     会把法线拉歪（缩放来自 Blender 里各叶片的 scale）。
##   · 缺法线的顶点补 Vector3.UP、缺顶点色的补 Color.WHITE —— 保证出参长度对齐，
##     add_surface_from_arrays 不会因为数组长度不一致而报错。
##   · 没带索引的 surface 退化成顺序索引（三角扇/非索引网格也要能合进来）。
## 仅被 _extract_mesh_merged() 调用。
func _collect_merged(n: Node, xf: Transform3D, verts: PackedVector3Array,
		norms: PackedVector3Array, cols: PackedColorArray,
		idx: PackedInt32Array) -> void:
	var t := xf
	if n is Node3D:
		t = xf * (n as Node3D).transform
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.mesh != null:
			var nb := t.basis.inverse().transposed()   # 法线要用逆转置
			for s in mi.mesh.get_surface_count():
				var a: Array = mi.mesh.surface_get_arrays(s)
				if a.size() == 0 or a[Mesh.ARRAY_VERTEX] == null:
					continue
				var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
				var nn: Variant = a[Mesh.ARRAY_NORMAL]
				var cc: Variant = a[Mesh.ARRAY_COLOR]
				var ind: Variant = a[Mesh.ARRAY_INDEX]
				var base := verts.size()
				for i in v.size():
					verts.append(t * v[i])
					if nn != null and i < (nn as PackedVector3Array).size():
						norms.append((nb * (nn as PackedVector3Array)[i]).normalized())
					else:
						norms.append(Vector3.UP)
					if cc != null and i < (cc as PackedColorArray).size():
						cols.append((cc as PackedColorArray)[i])
					else:
						cols.append(Color.WHITE)
				if ind != null:
					for i in (ind as PackedInt32Array):
						idx.append(base + i)
				else:
					for i in v.size():
						idx.append(base + i)
	for c in n.get_children():
		_collect_merged(c, t, verts, norms, cols, idx)

















## 统一取"某分类某变体"要画的网格
##
## 参数：cat —— 分类名；variant —— 变体下标（越界时由 category_model_path 用 posmod 环绕）。
## 返回：Mesh；分类表为空或该路径取不到网格时返回 null（调用方必须判空）。
## 副作用：无（只 load 资源；_extract_mesh 实例化出的临时节点会自己 free）。
## 调用时机：main.gd 的 UI 预览给鼠标挂模型时调用（main.gd L1828）。
## 注意：取的是**第一个有网格的 MeshInstance3D** 的 mesh —— 多子网格模型只会显示主体，
##   但它与 _model_local_aabb() 用的是同一个"视觉体"，所以预览偏移能和实际放置对上。
func category_model_mesh(cat: String, variant: int) -> Mesh:
	var path := category_model_path(cat, variant)
	if path.is_empty():
		return null
	return _extract_mesh(path)


# ============================================================ 植物卡片
# 注意：这一段现在只承担"给 MultiMesh 装载网格"的职责 —— _load_glb_mesh() 与
# _bake_surface_colors() 都在 _create_block() 里被调用（**在用**，别当死代码删）。
# 中间那一片连续空行是（推测）早期卡片式植被（billboard）相关代码被移除后留下的位置，
# 当前没有对应实现；要改渲染/风摇请看 _create_block() 与 vegetation_wind.gdshader。


















## 从 glb 场景中提取第一个 MeshInstance3D 的 Mesh（提取后释放临时实例，Mesh 为共享资源）
##
## 关键：KayKit 的自然模型**没有贴图**，颜色全靠每个 surface 的 albedo_color。
## 植被为了风摇用了 material_override，而 material_override 会把原材质整个换掉 ——
## 于是所有模型都变成白模。解决办法是把每个 surface 的 albedo 颜色烘进顶点色
## （Mesh.ARRAY_COLOR），风摇着色器用 albedo_color * COLOR 取样，颜色就回来了。
##
## 参数：path —— 模型资源路径（.glb / .tres 等，交给 load()）。
## 返回：Mesh；加载失败或场景里没有 MeshInstance3D 时返回 null（_create_block 允许它
##   为 null：MultiMesh 会退化成不可见实例，不会崩）。
## 副作用：实例化再 free 一个临时 PackedScene 实例（不留在场景树里）。
## 调用时机：_create_block() 为每个分类的每个变体建 MultiMesh 时调用一次。
## 注意事项：
##   · 只用**第一个** MeshInstance3D 的网格 → 多子网格模型会丢细节（需要全部子网格时
##     用 _extract_mesh_merged()）。
##   · 返回的 ArrayMesh 是新烘的，各变体各一份，不会被 MultiMesh 共享引用计数搞坏。
##   · 顶点色只能在没自带顶点色时补（见 _bake_surface_colors 的提前 return）。
func _load_glb_mesh(path: String) -> Mesh:
	var scene: PackedScene = load(path)
	if scene == null:
		return null
	var inst := scene.instantiate()
	var m := _find_mesh(inst)
	inst.free()
	if m is ArrayMesh:
		m = _bake_surface_colors(m as ArrayMesh)
	return m


## 把每个 surface 的材质基色写进该 surface 的顶点色，返回新的 ArrayMesh。
## 已带顶点色的模型原样返回（避免重复烘）。
##
## 参数：src —— 源 ArrayMesh（由 _load_glb_mesh 传进来）。
## 返回：新的 ArrayMesh（**总是**新建：逐 surface 复制 arrays 并保留原材质引用），
##   所以改它的结果不会污染磁盘上的资源。
## 副作用：无（不改 src）；每个 surface 会通过 surface_set_material 沿用原材质。
## 注意事项：
##   · 只认 StandardMaterial3D 的 albedo_color，其它材质类型一律退化成白色 ——
##     换材质类型就"变白模"，这是排查颜色问题时要先看的地方。
##   · 已带 ARRAY_FORMAT_COLOR 的 surface 原样拷过去，不覆盖模型自带的顶点色。
func _bake_surface_colors(src: ArrayMesh) -> ArrayMesh:
	var out := ArrayMesh.new()
	for si in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(si)
		var fmt: int = src.surface_get_format(si)
		var base := Color(1, 1, 1, 1)
		var mat := src.surface_get_material(si)
		if mat is StandardMaterial3D:
			base = (mat as StandardMaterial3D).albedo_color
		if (fmt & Mesh.ARRAY_FORMAT_COLOR) != 0:
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			out.surface_set_material(out.get_surface_count() - 1, mat)
			continue
		var vcount: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var cols := PackedColorArray()
		cols.resize(vcount)
		for i in vcount:
			cols[i] = base
		arrays[Mesh.ARRAY_COLOR] = cols
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, mat)
	return out

# ==================== 模型包围盒与放置偏移 ====================

## 供预览使用：与放置完全一致的偏移（水平居中 + 底面抬升）
##
## 参数：model_path —— 模型资源路径。返回：Vector3，未乘缩放的**局部空间**偏移。
## 副作用：无（内部走 _model_local_aabb 的缓存）。它是 main.gd 挂预览节点时的
##   `node.position`，必须与真实放置用的 _model_place_offset() 用同一套算法，
##   否则"预览在哪、种下去就在哪"的直觉会失效。
## 注意：它和 _model_place_offset() 是**两份等价实现**，改一处要同时改另一处。
func model_preview_offset(model_path: String) -> Vector3:
	var box := _model_local_aabb(model_path)
	return Vector3(-(box.position.x + box.size.x * 0.5),
			maxf(0.0, -box.position.y),
			-(box.position.z + box.size.z * 0.5))


## 供预览使用：模型足迹中心（局部空间 AABB 中心，水平分量）
##
## 参数：model_path —— 模型资源路径。返回：Vector3，y 恒为 0（只关心水平足迹）。
## 副作用：无。调用时机：（当前仓库里没有调用方 —— 保留给"占用/足迹"类判断使用。）
## 注意：它是**中心**而不是 offset；要"把中心对齐到放置点"的偏移请用
##   model_preview_offset()（两者正好是相反数关系，仅水平分量）。
func model_footprint_center(model_path: String) -> Vector3:
	var box := _model_local_aabb(model_path)
	return Vector3(box.position.x + box.size.x * 0.5, 0.0, box.position.z + box.size.z * 0.5)


## 模型的"视觉体"局部包围盒：取第一个有网格的 MeshInstance3D 的 AABB。
## 这是画面上真正看到的体积（预览与实例都只画这一个网格），因此作为
## 视觉/预览/放置偏移的唯一基准。注意不要用"全部面集合"的 AABB：
## 多网格模型的细节子网格可能超出主体（例如 stairsOpen 的 Group 子网格
## 比主体更低），那会让偏移与看到的模型不一致。
##
## 参数：model_path —— 可以是 Mesh（.tres/.obj 直接当网格用）或 PackedScene（.glb）。
## 返回：AABB（局部空间）；路径无效时返回**空 AABB**（AABB()，size 全 0）——
##   调用方通常靠 size 全 0 判断"模型没加载出来"。
## 副作用：无（结果写进 _model_aabb_cache，进程内只算一次；换模型文件要重启才生效）。
## 调用时机：model_preview_offset / model_footprint_center / _model_place_offset 都走它。
## 注意：缓存以**路径字符串**为键，同一路径在别处改了导入设置不会刷新缓存。
func _model_local_aabb(model_path: String) -> AABB:
	if _model_aabb_cache.has(model_path):
		return _model_aabb_cache[model_path]
	var out := AABB()
	var m: Variant = load(model_path)
	if m is Mesh:
		out = (m as Mesh).get_aabb()
	elif m is PackedScene:
		var inst := (m as PackedScene).instantiate()
		var mi := _find_first_mesh_node(inst)
		if mi != null and mi.mesh != null:
			out = mi.mesh.get_aabb()
		inst.free()
	_model_aabb_cache[model_path] = out
	return out


## 第一个含网格的 MeshInstance3D（其 AABB 即视觉体）
##
## 参数：node —— 任意节点（通常是刚实例化的模型根）。返回：MeshInstance3D 或 null。
## 副作用：无（不实例化、不释放）。
## 与 _find_mesh() 的区别（很容易搞混，别合并）：
##   · 本函数要求节点**自己**有非 null 的 mesh，返回的是节点（为了拿它的局部 AABB，
##     不含它自己的 transform —— 判断"底面是否低于原点"必须用局部 AABB）；
##   · _find_mesh() 只要遇到 MeshInstance3D 就返回它的 mesh（可能为 null）。
func _find_first_mesh_node(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node
	for c in node.get_children():
		var r := _find_first_mesh_node(c)
		if r != null:
			return r
	return null


## 放置偏移：把模型"摆正"到放置点
##  - 水平：模型 AABB 中心 → 放置点（准星点即模型中心）
##  - 垂直：仅当模型底面低于原点时上抬，使模型底面正好落在放置高度上
## 返回 (dx, dy, dz)；未缩放前调用方需乘实例缩放（线性）。视觉与碰撞共用同一值。
##
## 参数：model_path —— 模型资源路径。返回：Vector3 局部空间偏移（模型无效时为 ZERO）。
## 副作用：写 _model_offset_cache（进程内每路径算一次）。
## 调用时机：_add_instance() 每放一个实例算一次位置；sync_heights() 用它**反推**原始
##   放置点（origin - offset 旋转缩放后），所以它必须与放置时用的是同一个偏移。
## 注意事项：
##   · 偏移在**模型局部空间**，用法固定为 `pos += offset.rotated(Vector3.UP, yaw) * scale`
##     —— 顺序不能反（先旋转再缩放，最后加世界坐标）。
##   · 水平方向是"无条件居中"，垂直方向只在底面低于原点时上抬：对本来就站在原点上的
##     模型不额外抬高，避免悬空。
func _model_place_offset(model_path: String) -> Vector3:
	if _model_offset_cache.has(model_path):
		return _model_offset_cache[model_path]
	var box := _model_local_aabb(model_path)
	var offset := Vector3.ZERO
	if box.size.x > 0.0 or box.size.z > 0.0 or box.size.y > 0.0:
		offset.x = -(box.position.x + box.size.x * 0.5)
		offset.z = -(box.position.z + box.size.z * 0.5)
		# 底面低于原点才上抬（不上抬本来就在原点之上的模型，避免悬空）
		offset.y = maxf(0.0, -box.position.y)
	_model_offset_cache[model_path] = offset
	return offset


## 深度优先找第一个 mesh 资源（只要节点是 MeshInstance3D 就返回它的 mesh，可能为 null）
##
## 参数：node —— 任意节点。返回：Mesh 或 null。
## 副作用：无（不释放、不实例化）。
## 调用时机：只被 _load_glb_mesh() 调用（给 MultiMesh 取网格）。
## 注意：与 _find_first_mesh_node() 是两个不同层次的工具，别互相替换：
##   本函数返回 **mesh 资源**（多用于取值），后者返回**节点**（多用于取局部 AABB）。
func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D:
		return node.mesh
	for c in node.get_children():
		var m := _find_mesh(c)
		if m != null:
			return m
	return null

## 懒初始化分块网格（首次撒点前建立；terrain 传入后按真实 HALF 建块）
##
## 参数：无（读 _terrain_half）。返回：无。
## 副作用：把 _block_n² 个块容器节点加进本节点（**改场景树**），并填满 _blocks。
## 调用时机：build_from_scene / _add_instance / sync_heights / populate_auto /
##   plan_layout 一进来就调，所以调用方不必关心它有没有跑过。
## 注意事项：
##   · 幂等：_blocks 非空就直接 return，可放心反复调用。
##   · **必须先注入 _terrain_half**（WorldBuilder 里做），否则会按默认 450 建块，
##     地图尺寸一变就会整体错位 —— 事后改 _terrain_half 不会重建块。
func _ensure_blocks() -> void:
	# 幂等早退：_blocks 非空 ⇔ _block_n 已算好，重复调用不会重建/泄漏节点。
	if not _blocks.is_empty():
		return
	# maxi(1, …)：_terrain_half 还没注入（=0）时也要保证至少 1×1 块，否则 _blocks 为空，
	# 后续所有按 bi 索引的代码都会越界；ceili 而不是 floor：宁可多一块，
	# 也不要把地图边界那一小条排除在世界之外。
	_block_n = maxi(1, ceili((_terrain_half * 2.0) / CHUNK_SIZE))
	for bz in _block_n:
		for bx in _block_n:
			_blocks.append(_create_block(bx, bz))

## 建一个渲染块：容器节点 + 碰撞容器 + 每分类每变体一个 MultiMeshInstance3D。
##
## 参数：bx / bz —— 块下标（0 .. _block_n-1），仅用于命名与坐标换算。
## 返回：块数据 Dictionary，键：
##   node        : Node3D，块容器（_update_visibility 用它的 visible 整块显隐）
##   mmis        : {cat: Array[MultiMeshInstance3D]}（每个模型变体一个）
##   counts      : {cat: Array[int]}，与 mmis 同序，记录该变体已用实例数
##   collisions  : Node3D，该块所有植被碰撞 StaticBody3D 的父节点
##   col_queue / col_bodies / col_built_n / col_order_dirty / col_built : 碰撞流式化状态
## 副作用：**改场景树**（把块容器与全部 MultiMeshInstance3D 挂到本节点下）；
##   调用 _wind_material_for()（可能新建风摇材质）；调用 _load_glb_mesh()（load 模型）。
## 调用时机：只由 _ensure_blocks() 调用，每块一次。
## 注意事项：
##   · 空分类表（当前 flower/grass/…）在这里就退化成空 mmis/counts，不建任何 MultiMesh，
##     所以放置流程要能容忍 mmis[cat] 为空数组。
##   · 容量按"全图上限 ÷ 块数 ÷ 变体数"平摊（cap_per），所以改 MAX_* 或加变体都会
##     改变每块容量；容量不足时 _add_instance 会挑下一个还有空位的变体。
##   · 材质只在有分类材质时挂 material_override（风摇就靠它）。
func _create_block(bx: int, bz: int) -> Dictionary:
	var node := Node3D.new()
	node.name = "Chunk_%d_%d" % [bx, bz]
	add_child(node)
	var collisions := Node3D.new()
	collisions.name = "TreeCollisions"
	node.add_child(collisions)
	var block := {
		"node": node,
		"mmis": {},
		"counts": {},
		"collisions": collisions,
		# 该块待建/已建的碰撞体：queue 是描述（懒加载），bodies 是已创建实例
		"col_queue": [],
		"col_bodies": [],
		# 已建项永远是 col_queue 的前缀，col_built_n 是前缀长度
		"col_built_n": 0,
		# 队列需要按到相机的距离重排（玩家放置会插入队首，导致顺序失效）
		"col_order_dirty": false,
		"col_built": false,
	}
	for cat in _category_models:
		var models: Array = _category_models[cat]
		if models.is_empty():
			# 自制模型没载入（缺 catalog3d.json）时不能除零
			block["mmis"][cat] = []
			block["counts"][cat] = []
			continue
		# 每分类一份材质，只为让 sway_scale 不同（树摆得多、草摆得少）
		var cat_mat: ShaderMaterial = _wind_material_for(cat)
		# 每块每变体的实例容量：把该类全图上限平摊到 (块数 × 变体数)。
		# 用 ceili 保证"平摊后每块都够用"，否则总量会被容量卡住、达不到 MAX_*。
		# 这是**容量上限**而不是限制：实际用了几个看 visible_instance_count。
		var cap_per := ceili(_category_max[cat] / float(_block_n * _block_n * models.size()))
		var use_color: bool = cat in COLORED_CATEGORIES
		var use_shadow: bool = cat in SHADOW_CATEGORIES
		var mmis: Array = []
		var counts: Array = []
		for p in models:
			var mmi := MultiMeshInstance3D.new()
			mmi.multimesh = MultiMesh.new()
			mmi.multimesh.transform_format = MultiMesh.TRANSFORM_3D
			mmi.multimesh.mesh = _load_glb_mesh(p)
			if use_color:
				# Godot 4.5：实例颜色通过 use_colors + set_instance_color 启用
				mmi.multimesh.use_colors = true
			# 风摇材质：顶点随风摆动由 Weather 每帧写入材质 uniform 驱动
			# （不能用全局着色器参数，见 assets/shaders/vegetation_wind.gdshader）
			if cat_mat != null:
				mmi.material_override = cat_mat
			if not use_shadow:
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# instance_count 一次性分配满容量（之后不再改，避免重分配与缓冲搬迁）；
			# visible_instance_count = 0 表示"先一个都不显示"，放置时逐个 +1 ——
			# 否则未使用的空实例会在原点叠出一堆重影。
			mmi.multimesh.instance_count = cap_per
			mmi.multimesh.visible_instance_count = 0
			node.add_child(mmi)
			mmis.append(mmi)
			counts.append(0)
		block["mmis"][cat] = mmis
		block["counts"][cat] = counts
	return block

# ==================== 碰撞体流式化 ====================

## 登记一处需要模型碰撞的实例。
##
## 碰撞体是**按实例距离**流式建的，不按块。原因：
## 渲染块 CHUNK_SIZE = 150m，6×6 = 36 块覆盖 900m 地图，于是"块中心"之间隔 225m。
## 按块中心判断是否在碰撞半径内时，**玩家附近根本没有块中心** —— 全图 9044 条碰撞
## 队列里只有 1020 条被建出来（相差 8024 条），表现就是"远处的物体走过去没有碰撞"。
## 现在每条队列项带自己的位置，按到相机的距离排序，只在 collision_radius 内的建体。
##
## 参数：
##   cat / model_path —— 碰撞体型用的类别与模型（决定 _shape_for 的形状缓存键）。
##   pos —— 世界坐标（必须是**已应用放置偏移后**的实际实例位置，见 _add_instance 的回传值）。
##   scale / yaw —— 实例缩放与朝向（yaw 弧度）；碰撞体要与视觉完全一致。
##   immediate —— true = 玩家放置路径，立刻建体（插到已建前缀的下一位）；
##     false（默认）= 只登记描述，等块进入半径由 _stream_collisions() 补建。
## 返回：无。
## 副作用：往该块的 col_queue 追加一项、把 col_order_dirty/col_built 置脏，
##   需要时把块下标加进 _pending_blocks；immediate 时还会**立刻创建 StaticBody3D**。
## 注意事项：
##   · 只有"待在半径里"的项才会被建体，队列会长期保存远处项 —— 所以清场/回收必须
##     同步裁队列，否则会留下永远建不出来的幽灵项（见 _drop_queued_in_area）。
##   · 块的归属由 pos 反推（clampi 夹进地图内），pos 传世界坐标、别传局部坐标。
func _queue_collision(cat: String, model_path: String, pos: Vector3, scale: float, yaw: float,
		immediate := false) -> void:
	if _blocks.is_empty():
		return
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bi := bz * _block_n + bx
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	queue.append({
		"cat": cat, "path": model_path, "pos": pos, "scale": scale, "yaw": yaw,
	})
	block["col_order_dirty"] = true
	block["col_built"] = false
	if immediate:
		# 玩家放置：立刻建体。插到"已建前缀"的下一位，保证已建项永远是队列前缀。
		var idx := int(block["col_built_n"])
		queue.insert(idx, queue[queue.size() - 1])
		queue.remove_at(queue.size() - 1)
		block["col_order_dirty"] = true
		_build_collision_at(bi, idx)
		return
	if not _pending_blocks.has(bi):
		_pending_blocks.append(bi)


## 为某块的队列中指定下标的一项建体（玩家放置用，立即生效）。
## 已建项必须是队列的**前缀**（_build_prefix 从 0 顺序建），所以这里只能建下一位。
##
## 参数：bi —— 块一维下标；queue_index —— 目标项在 col_queue 里的下标。
## 返回：无。越界（bi 或 queue_index 不合法）时直接 return，不报错。
## 副作用：创建 StaticBody3D（入树、写物理服务器）、写回 block["col_built_n"]。
## 调用时机：只由 _queue_collision(immediate = true) 调用（玩家手动放置/种树）。
## 注意事项：
##   · 循环是 `while bodies.size() <= queue_index`：它会把前缀里**缺失的部分一起补齐**
##     （而不是只建目标那一项），否则 bodies 与 queue 的下标对应关系会断。
##   · 别把它当"随便建一项"用：它的语义就是"把前缀延长到 queue_index"。
func _build_collision_at(bi: int, queue_index: int) -> void:
	if bi < 0 or bi >= _blocks.size():
		return
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var bodies: Array = block["col_bodies"]
	if queue_index < 0 or queue_index >= queue.size():
		return
	while bodies.size() <= queue_index:
		var idx := bodies.size()
		var d: Dictionary = queue[idx]
		var sb := _make_instance_collision(str(d["cat"]), str(d["path"]),
				d["pos"] as Vector3, float(d["scale"]), float(d["yaw"]))
		sb.set_meta("veg_block", bi)
		bodies.append(sb)
	block["col_built_n"] = bodies.size()


## 供"已建前缀"重建：把队列按到相机的位置排序，已建的保持在前。
## 排序键是到相机的水平距离 —— 先建最近的，玩家往哪走都能优先拿到碰撞。
func _resort_block_queue(bi: int) -> void:
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var built := int(block["col_built_n"])
	if queue.size() <= 1:
		block["col_order_dirty"] = false
		return
	var p := _collision_anchor()
	# 只对未建部分排序：已建的是前缀，打乱它们会破坏 bodies 与 queue 的对应关系
	var head: Array = queue.slice(0, built)
	var tail: Array = queue.slice(built)
	tail.sort_custom(func(a, b):
		var pa: Vector3 = a["pos"]
		var pb: Vector3 = b["pos"]
		var da := (pa.x - p.x) * (pa.x - p.x) + (pa.z - p.z) * (pa.z - p.z)
		var db := (pb.x - p.x) * (pb.x - p.x) + (pb.z - p.z) * (pb.z - p.z)
		return da < db)
	block["col_queue"] = head + tail
	block["col_order_dirty"] = false
	block["sort_ms"] = Time.get_ticks_usec()
	# 记住这次排序用的锚点：建体循环"遇到第一条超出半径的就停"，只有排序是最新的，
	# 边界才准；锚点一动排序就过期，边缘处的实例会被误判成更远而永远建不到。
	block["sort_anchor"] = p


## 碰撞判断用的参考点：优先相机，其次玩家
## ★ 注意：实现上**没有**"其次玩家"这一步 —— _camera 为 null 时直接返回 Vector3.ZERO。
##   也就是相机未注入（set_camera 之前）时，流式化会以世界原点为锚点；
##   正常启动流程里 set_camera 早于玩家开始移动，所以实际影响很小。
## 参数：无。返回：世界坐标 Vector3。副作用：无（纯读取）。
func _collision_anchor() -> Vector3:
	if _camera != null:
		return _camera.global_position
	return Vector3.ZERO


## 兼容旧调用：这个块现在需不需要（继续）建碰撞体
##
## 参数：bi —— 块一维下标。返回：bool。副作用：无（一行转发）。
## 注意：当前仓库里**没有调用方**（保留给旧调用），真实判断在 _block_needs_collision()。
func _is_block_active(bi: int) -> bool:
	return _block_needs_collision(bi)


## 该块里有没有"还没建且进入半径"的项（决定要不要排队建体）
func _block_needs_collision(bi: int) -> bool:
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var built := int(block["col_built_n"])
	if built >= queue.size():
		return false
	if _camera == null:
		return true
	var pos: Vector3 = (queue[built] as Dictionary)["pos"]
	var p := _collision_anchor()
	var dx := pos.x - p.x
	var dz := pos.z - p.z
	return dx * dx + dz * dz <= collision_radius * collision_radius


## 在时间预算内补建碰撞体。
##
## 队列按到相机的水平距离排序，"已建"永远是队列的前缀（col_built_n = 前缀长度），
## 于是 bodies 与 queue 的下标天然一一对应，不需要额外的映射表。
## 建到第一条超出 collision_radius 的项就停 —— 后面只会更远；
## 这时**不能**把块标记为"建完"，否则玩家走近时它不会再入队，那些项就永远没有碰撞。
func _stream_collisions() -> void:
	if _camera == null or _pending_blocks.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var p := _collision_anchor()
	var r2 := collision_radius * collision_radius
	var remaining: Array = []
	for bi_v in _pending_blocks:
		var bi := int(bi_v)
		if (Time.get_ticks_usec() - t0) / 1000.0 >= _stream_budget_ms:
			remaining.append(bi)
			continue
		var block: Dictionary = _blocks[bi]
		# 重排很贵（对整条队列做 GDScript 闭包排序，上千项时实测几十毫秒），
		# 所以**不能"锚点一动就重排"**：1 米的阈值在走路时几乎每帧都成立，
		# 实测这正是走路卡顿的尖峰来源。排序不够新鲜带来的"半径边缘漏建"，
		# 由下面的扫描窗口兜底：遇到超出半径的项不再直接 break，而是挪到队尾继续往后看。
		var last_anchor: Vector3 = block.get("sort_anchor", Vector3.INF)
		var since_sort_ms := Time.get_ticks_usec() - int(block.get("sort_ms", 0))
		if bool(block["col_order_dirty"]) or last_anchor == Vector3.INF \
				or (last_anchor.distance_to(p) > RESORT_DISTANCE \
						and since_sort_ms > RESORT_INTERVAL_MS):
			_resort_block_queue(bi)
		var queue: Array = block["col_queue"]
		var bodies: Array = block["col_bodies"]
		var far_run := 0
		while bodies.size() < queue.size():
			# 预算**每个实例都查**（原来 `% 16 == 0` 才查，突发能冲 150ms+）
			if (Time.get_ticks_usec() - t0) / 1000.0 >= _stream_budget_ms:
				break
			var idx := bodies.size()
			var d: Dictionary = queue[idx]
			var pos: Vector3 = d["pos"]
			var dx := pos.x - p.x
			var dz := pos.z - p.z
			if dx * dx + dz * dz > r2:
				# 超出碰撞半径：挪到队尾（已建前缀 [0, built) 不受影响）再看下一项。
				# 这样"排序过期"只会让个别项**晚**建，不会把它后面那些其实在
				# 半径内的项永远堵住（原来是 break，正是漏建的真因）。
				far_run += 1
				if far_run > BUILD_SCAN_WINDOW:
					break
				var last_idx := queue.size() - 1
				queue[idx] = queue[last_idx]
				queue[last_idx] = d
				continue
			far_run = 0
			var sb := _make_instance_collision(str(d["cat"]), str(d["path"]),
					pos, float(d["scale"]), float(d["yaw"]))
			sb.set_meta("veg_block", bi)
			bodies.append(sb)
		block["col_built_n"] = bodies.size()
		# 只有整条队列都建完才算完成；否则留在待办里等玩家靠近
		block["col_built"] = bodies.size() >= queue.size()
		if not block["col_built"]:
			remaining.append(bi)
	_pending_blocks = remaining


## 玩家移动后重排队列并补建。
##
## 队列的排序是相对某个位置算的（到相机距离升序），而"已建项"永远是队列前缀。
## 玩家走远之后这个顺序就失效了：原本排在很后面的近处实例仍在队尾，而建体循环
## 遇到第一条超出半径的项就停 —— 于是它们永远建不到。实测玩家身边 11.8m 的实例
## 都没有碰撞体，正是这个原因（远处物体碰撞失效的真因）。
## 所以一旦玩家移动超过阈值就让所有排序失效，并给队首仍在半径内的块重新排队。
##
## 参数：无。返回：无。副作用：可能把多个块下标重新加进 _pending_blocks，
##   并把未建完的块的 col_order_dirty 置 true（真正的排序发生在 _stream_collisions）。
## 调用时机：由 _process() 每帧调用，但内部用 _requeue_timer 节流（约每 6 帧一次）。
## 注意事项：
##   · 这里是"标记脏 + 入队"，**不直接排序**：排序很贵，放到预算内的 _stream_collisions
##     里按需做，避免和建体抢帧时间。
##   · 12.0 这个阈值与 RESORT_DISTANCE(8.0) 不是一回事：前者决定"要不要整批标脏"，
##     后者是单块排序的触发距离；两者配合才既不抖也不漏。
func _requeue_collision_blocks() -> void:
	_requeue_timer -= 1
	if _requeue_timer > 0:
		return
	_requeue_timer = 6
	if _blocks.is_empty():
		return
	var p := _collision_anchor()
	# 玩家已经离上次排序锚点很远：整批未建完的块都标脏（下次建体前会重排）。
	if _sort_anchor == Vector3.INF or p.distance_to(_sort_anchor) > 12.0:
		_sort_anchor = p
		for bi in _blocks.size():
			var b0: Dictionary = _blocks[bi]
			if (b0["col_bodies"] as Array).size() < (b0["col_queue"] as Array).size():
				b0["col_order_dirty"] = true
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var queue: Array = block["col_queue"]
		if (block["col_bodies"] as Array).size() >= queue.size():
			continue
		if bool(block["col_order_dirty"]) or _block_needs_collision(bi):
			if not _pending_blocks.has(bi):
				_pending_blocks.append(bi)


## 释放已经离开碰撞半径的已建体（从右往左，保持"已建是前缀"的不变式）
##
## 参数：bi —— 块一维下标。返回：无（bodies 为空时直接 return）。
## 副作用：queue_free() 掉队尾那些已经超出 collision_radius 的 StaticBody3D
##   （并借助 _erase_body_from_block 把它们从本块 col_bodies 与 _collision_nodes 里摘掉），
##   最后同步 col_built_n / col_built。
## 调用时机：_update_visibility() 发现该块"已经没有需要建的项"但还有已建体时调用。
## 注意事项：
##   · **必须从右往左**：已建项是队列前缀，只有队尾才是"离得最远、可释放"的那些；
##     从中间挖会把 bodies 与 queue 的下标对应关系彻底打乱。
##   · 只裁尾、不整块释放，这样玩家在半径边缘来回走时不会反复建/拆同一批碰撞体。
func _trim_block_collisions(bi: int) -> void:
	var block: Dictionary = _blocks[bi]
	var queue: Array = block["col_queue"]
	var bodies: Array = block["col_bodies"]
	if bodies.is_empty():
		return
	var p := _collision_anchor()
	var r2 := collision_radius * collision_radius
	var n := bodies.size()
	while not bodies.is_empty():
		n = bodies.size()
		var pos: Vector3 = (queue[n - 1] as Dictionary)["pos"]
		var dx := pos.x - p.x
		var dz := pos.z - p.z
		if dx * dx + dz * dz <= r2:
			break
		var sb: Node = bodies[n - 1]
		if is_instance_valid(sb):
			# _erase_body_from_block 会把 sb 从本块的 col_bodies 里 erase 掉，而
			# bodies 正是那个数组的别名 —— 这一句已经删掉了末尾元素。所以它删过之后
			# 不能再用 n-1 去 remove_at：数组已经短了一格，index == size 直接越界。
			_erase_body_from_block(sb)
			sb.queue_free()
		if bodies.size() == n:
			bodies.remove_at(n - 1)
	block["col_built_n"] = bodies.size()
	block["col_built"] = bodies.size() >= queue.size()


## 释放某块的全部碰撞体（离开视野）
##
## 参数：bi —— 块一维下标（越界直接 return）。返回：无。
## 副作用：把每个 StaticBody3D 从 _collision_nodes[cat] 里摘掉并 queue_free()，
##   清空 col_bodies、把 col_built 置回 false（**不动 col_queue**，队列描述仍保留，
##   所以之后重新靠近还能按原样补建）。
## 注意事项：
##   · 当前仓库里没有调用方（保留作"整块释放"路径）：现在离开碰撞半径只做
##     _trim_block_collisions() 的**剪尾**，不再整块释放，避免来回建/拆的开销。
##   · bodies 为空时要顺手把 col_built_n 归零，否则前缀长度会和空数组不一致。
func _despawn_block_collisions(bi: int) -> void:
	if bi < 0 or bi >= _blocks.size():
		return
	var block: Dictionary = _blocks[bi]
	var bodies: Array = block["col_bodies"]
	if bodies.is_empty():
		block["col_built_n"] = 0
		return
	for sb in bodies:
		if not is_instance_valid(sb):
			continue
		# 从按类别登记的数组里摘掉，避免悬空引用
		for cat in _collision_nodes.keys():
			(_collision_nodes[cat] as Array).erase(sb)
		sb.queue_free()
	bodies.clear()
	block["col_built"] = false


## 共享的模型三角网碰撞形状（每模型一份，与 building_manager 同样思路）
##
## 参数：cat —— 分类（只是缓存的第一级键，形状本身只用 model_path 区分）；
##   model_path —— 模型资源路径。
## 返回：ConcavePolygonShape3D（**共享引用**：同一 cat+path 的实例共用同一个 shape，
##   所以绝对不能对返回值做 per-instance 修改）。
## 副作用：首次调用会 load 模型、可能实例化并释放一个临时节点，然后写入 _shape_cache。
## 调用时机：_make_instance_collision() 建体时调用。
## 注意事项：
##   · 几何完全取自模型三角网（ConcavePolygonShape3D），这样"踩在石头/家具上"的支撑面
##     与视觉一致，不会浮空也不会陷入 —— 代价是三角面数多，所以必须共享。
##   · faces 为空时塞三个极小三角片兜底：空 shape 会让物理服务器直接报错。
##   · 缩放/朝向**不在这里**：形状是局部空间的，缩放与 yaw 由 body/CollisionShape3D 承担。
func _shape_for(cat: String, model_path: String) -> ConcavePolygonShape3D:
	if not _shape_cache.has(cat):
		_shape_cache[cat] = {}
	var cache: Dictionary = _shape_cache[cat]
	if cache.has(model_path):
		return cache[model_path]
	var shape := ConcavePolygonShape3D.new()
	var faces := PackedVector3Array()
	var m: Variant = load(model_path)
	if m is Mesh:
		faces = (m as Mesh).get_faces()
	elif m is PackedScene:
		var inst := (m as PackedScene).instantiate()
		if inst is Node3D:
			_collect_mesh_faces(inst as Node3D, Transform3D.IDENTITY, faces)
			inst.free()
	if faces.is_empty():
		# 兜底：极小三角片，避免空形状导致物理报错
		faces.append(Vector3(-0.25, 0.0, -0.25))
		faces.append(Vector3(0.25, 0.0, -0.25))
		faces.append(Vector3(0.0, 0.05, 0.0))
	shape.set_faces(faces)
	cache[model_path] = shape
	return shape


## 为一个已放置实例建立模型碰撞：形状共享、朝向在 CollisionShape3D、位置与缩放在 body 上。
## 返回该 body（已在树内），调用方可移动到别的父节点。
##
## 参数：cat / model_path —— 决定共用哪个三角网形状；pos —— **世界坐标**（已含放置偏移）；
##   scale —— 统一缩放（只支持等比：代码写的是 Vector3.ONE * scale）；yaw —— 弧度。
## 返回：StaticBody3D（已 add_child 到所属块的 TreeCollisions 下、已登记进 _collision_nodes）。
## 副作用：创建 3 个节点（body + shape）、改场景树、写物理服务器、追加 _collision_nodes。
## 调用时机：_stream_collisions()（流式补建）与 _build_collision_at()（玩家放置立即建）。
## 注意事项：
##   · **必须先入树再设 global_position**（代码注释也写了）：节点不在树里时 global_position
##     不生效，碰撞体会全部堆在原点。
##   · collision_mask = 0（只当障碍物，不主动检测），collision_layer = COLLISION_LAYER。
##   · 朝向 yaw 写在 CollisionShape3D 上、位置与缩放写在 body 上，是这套代码的分工约定；
##     因为缩放是等比的（Vector3.ONE * scale），两者合成的最终变换与顺序无关。
func _make_instance_collision(cat: String, model_path: String, pos: Vector3,
		scale: float, yaw: float) -> StaticBody3D:
	var block_x := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block_z := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block: Dictionary = _blocks[block_z * _block_n + block_x]
	var holder := block["collisions"] as Node3D
	var sb := StaticBody3D.new()
	sb.collision_layer = COLLISION_LAYER
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = _shape_for(cat, model_path)
	col.rotation.y = yaw
	sb.add_child(col)
	holder.add_child(sb)
	# 必须先入树再设 global_position，否则全局变换无效
	sb.global_position = pos
	sb.scale = Vector3.ONE * scale
	if not _collision_nodes.has(cat):
		_collision_nodes[cat] = []
	(_collision_nodes[cat] as Array).append(sb)
	return sb


## 取某类别**最后一次**放置记录里的变体下标（给 add_mushroom/add_stump 这类
## "不返回 _add_instance 结果"的接口补一个变体回传）。
##
## 参数：cat —— 类别名。返回：变体下标；历史为空时返回 0（注意不是 -1）。
## 副作用：无。注意事项：
##   · _add_instance 失败（没入栈）时会返回**上一株**的变体（近似值），调用方按需自行判空。
##   · 返回 0 表示"历史为空"，与"失败"（-1）不是同一件事。
func _last_variant(cat: String) -> int:
	var hist := _hist_for(cat)
	if hist.is_empty():
		return 0
	return int(hist[hist.size() - 1].get("vi", 0))


## 类别名 → 该类别的放置历史栈（**返回的是内部数组本身，不是拷贝**）。
##
## 参数：cat —— 类别名。返回：Array（未知类别返回一个**新建的空数组**，写它不会报错
##   但也不会有任何效果 —— 这是刻意的静默行为，避免调用方到处判空）。
## 副作用：无（读引用）。
## 调用时机：_add_instance 入栈、_remove_last 弹栈、_remove_last_with_collision 定位、
##   _rebuild_all_hist 清空/重建、_last_variant 读末项都会用。
## 注意：因为返回的是引用，`_hist_for(cat).clear()` 这类写法会真的清空历史。
func _hist_for(cat: String) -> Array:
	match cat:
		"tree": return _tree_hist
		"bush": return _bush_hist
		"flower": return _flower_hist
		"grass": return _grass_hist
		"rock": return _rock_hist
		"mushroom": return _mushroom_hist
		"stump": return _stump_hist
		"furniture": return _furniture_hist
		"mountain": return _mountain_hist
	return []

# ==================== 通用实例添加与场景重建 ====================

## 通用添加：定位所在块 → 随机模型变体 → 指定/随机旋转 → 随机缩放 → 可选实例色
## yaw >= 0 使用指定朝向（玩家放置旋转），-1 随机朝向。
## 返回 {ok, vi, pos}：pos 是**已应用重定位偏移**的实际实例位置（Vector3 是值类型，
## 调用方必须用回传值去建碰撞，否则碰撞会落在未偏移的准星点上）。
##
## 参数：
##   cat —— 分类名（必须存在于 _category_models / _category_max / _category_total）。
##   pos —— 世界坐标放置点（通常是准星点，未含模型偏移）。
##   scale —— 等比缩放（> 0；典型 0.85~1.6，家具/山体 1.0）。
##   hist —— 该类别的历史栈（用 _hist_for(cat) 取，成功后本函数会往里 push 一条）。
##   yaw —— >= 0 用指定朝向（弧度），< 0 表示随机朝向。
##   force_variant —— >= 0 且 < 变体数时强制该变体（场景烘焙用）；否则随机起点往后找。
## 返回：{ok: bool, vi: int, pos: Vector3}。失败时 ok=false、vi=-1、pos 原样回传；
##   成功时 vi 是实际使用的变体下标，pos 是**已加放置偏移**的真实实例位置。
## 副作用：
##   · 写 MultiMesh（set_instance_transform / set_instance_color、visible_instance_count++）
##   · _category_total[cat]++、hist 追加一条、layout_mode 时往 plan_items 追加
##   · 可能调 _queue_collision(immediate = true) 立即建碰撞体（bush/mushroom/stump）
## 注意事项：
##   · 满员（≥ _category_max[cat]）**直接失败返回**，不做顶替 —— 顶替逻辑在 add_* 包装里。
##   · 空分类表（mmis 为空）也直接失败，所以"没填模型"只是放不下去，不会崩。
##   · 变体不是严格按 force_variant 用：若它已满就顺着往后找第一个还有空位的变体
##     （所以调用方要用返回的 vi，不能假设等于传入值）。
func _add_instance(cat: String, pos: Vector3, scale: float, hist: Array, yaw: float = -1.0, force_variant: int = -1) -> Dictionary:
	var max_total: int = _category_max[cat]
	if _category_total[cat] >= max_total:
		return {"ok": false, "vi": -1, "pos": pos}
	_ensure_blocks()
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var block: Dictionary = _blocks[bz * _block_n + bx]
	var mmis: Array = block["mmis"][cat]
	var counts: Array = block["counts"][cat]
	if mmis.is_empty():
		return {"ok": false, "vi": -1, "pos": pos}
	# 容量取 mmis[0] 即可：同一分类的所有变体都用同一套平摊公式算出 cap_per，
	# 所以各变体容量相同（见 _create_block）。别在这里改成按变体分别读。
	var cap: int = mmis[0].multimesh.instance_count
	# 指定变体（场景烘焙）优先，否则随机起始变体
	var start: int = force_variant if force_variant >= 0 and force_variant < mmis.size() else _rng.randi_range(0, mmis.size() - 1)
	var vi := -1
	for k in mmis.size():
		var cand := (start + k) % mmis.size()
		if counts[cand] < cap:
			vi = cand
			break
	if vi == -1:
		return {"ok": false, "vi": -1, "pos": pos}
	var mm: MultiMesh = mmis[vi].multimesh
	# 实例下标就用"已用数量"：实例永远紧凑排布在下标 [0, counts[vi]) 这个前缀里，
	# 配合 visible_instance_count 就能只画前 counts[vi] 个，不产生空洞。
	var idx: int = counts[vi]
	# yaw < 0（-1）是约定俗成的"随机朝向"哨兵值：绝不代表 -1 弧度。
	var rot := _rng.randf_range(0.0, TAU) if yaw < 0.0 else yaw
	# 先旋转再等比缩放（等比缩放下顺序无所谓），保证与下面给 pos 加偏移的方式一致。
	var basis := Basis.IDENTITY.rotated(Vector3.UP, rot).scaled(Vector3.ONE * scale)
	# 把模型 AABB 的水平中心对到放置点：偏移在模型局部空间，
	# 必须先用实例 yaw 旋转，再按缩放放大，最后加到世界放置点。
	var model_path := str((_category_models[cat] as Array)[vi])
	var offset := _model_place_offset(model_path)
	if offset != Vector3.ZERO:
		pos += offset.rotated(Vector3.UP, rot) * scale
	mm.set_instance_transform(idx, Transform3D(basis, pos))
	var tint := Color.WHITE
	if cat in COLORED_CATEGORIES:
		tint = _random_plant_color(cat)
		mm.set_instance_color(idx, tint)
	# counts 与 visible_instance_count 必须同步：前者是本系统记账（决定下一个空位、
	# 也是 remove_last 回退的基准），后者才是真正让实例显示出来的开关。
	counts[vi] += 1
	mm.visible_instance_count = counts[vi]
	_category_total[cat] += 1
	# 历史项携带复原所需全部数据（块坐标/变体/位置/缩放/朝向/配色），
	# 使场景烘焙出的布局与玩家放置都能按原样重建。
	hist.append({
		"bx": bx, "bz": bz, "vi": vi, "pos": pos,
		"scale": scale, "yaw": rot, "color": tint, "cat": cat,
	})
	# 除花草外，所有类别都要模型碰撞（灌木/蘑菇/树桩也按模型面贴合）
	# 这里只登记描述，碰撞体随块进入视野时再建（流式化）
	# ★ 排除 tree/rock/mountain/furniture 是**故意的**：这四类由各自的 add_* 包装函数
	#   （或 place_scene_item 给场景烘焙节点）负责登记，留在这里会重复登记两份碰撞体。
	#   所以这里登记的是 bush/mushroom/stump 三类，两处合起来刚好覆盖 COLLISION_CATEGORIES。
	if not layout_mode and cat in COLLISION_CATEGORIES \
			and cat not in ["tree", "rock", "mountain", "furniture"]:
		_queue_collision(cat, model_path, pos, scale, rot, true)
	if layout_mode:
		plan_items.append({
			"cat": cat, "pos": pos, "scale": scale, "yaw": rot,
			"variant": vi, "color": tint, "bx": bx, "bz": bz,
		})
	return {"ok": true, "vi": vi, "pos": pos}

## 随机植被配色（让花/草/蘑菇/树桩观感更丰富）
##
## 参数：cat —— 分类名（只对 COLORED_CATEGORIES 里的分类有意义）。
## 返回：Color（**恒定返回带 alpha 的 Color**，不是"乘算系数"）。未匹配的类别返回
##   Color.WHITE（= 不改变模型本来的颜色）。
## 副作用：消耗 _rng 的随机数（会影响后续随机结果的可复现性 —— 这也是为什么
##   撒点必须固定 scene_seed 才能复现布局）。
## 注意事项：
##   · flower 是从 6 色固定调色板里挑，所以花色差异明显、不会出现脏色；
##   · grass / mushroom / stump 是在基色上叠加小范围随机（公式里的 + 是逐通道偏移），
##     这些数值按"看起来自然"标定，改大容易出现荧光绿/脏黄。
##   · 颜色最终是乘到模型顶点色上的（着色器 albedo_color * COLOR），所以偏暗的取值
##     会把模型压暗，不是"替换颜色"。
func _random_plant_color(cat: String) -> Color:
	match cat:
		"flower":
			var palettes := [
				Color(0.95, 0.30, 0.42),
				Color(0.96, 0.76, 0.18),
				Color(0.72, 0.42, 0.92),
				Color(0.95, 0.52, 0.78),
				Color(0.94, 0.94, 0.97),
				Color(0.42, 0.68, 0.96),
			]
			return palettes[_rng.randi_range(0, palettes.size() - 1)]
		"grass":
			return Color(
				0.24 + _rng.randf_range(0.0, 0.20),
				0.52 + _rng.randf_range(0.0, 0.22),
				0.14 + _rng.randf_range(0.0, 0.14))
		"mushroom":
			return Color(
				0.82 + _rng.randf_range(0.0, 0.14),
				0.72 + _rng.randf_range(0.0, 0.18),
				0.55 + _rng.randf_range(0.0, 0.20))
		"stump":
			return Color(
				0.42 + _rng.randf_range(0.0, 0.14),
				0.30 + _rng.randf_range(0.0, 0.10),
				0.16 + _rng.randf_range(0.0, 0.08))
	return Color.WHITE

## 按场景节点重建一株植被（不写入玩家历史，只铺底）
##
## 参数：node —— Spawned/<cat>/ 下的一个撒点节点，位置/缩放/朝向/变体全部来自它的
##   metadata（px/py/pz、scale、yaw、variant），**缺失时回退到节点自身的 position**；
##   cat —— 分类名（由调用方从父节点名得到，不用节点自己的 metadata/cat）。
## 返回：bool（true = 放置成功；false = 满员 / 分类表为空 / 变体容量已满）。
## 副作用：与 _add_instance 相同（写 MultiMesh、写 hist、_category_total++），
##   另外为 tree / rock / furniture / mountain 补登碰撞队列。
## 调用时机：只由 build_from_scene() 遍历 Spawned 时调用。
## 注意事项：
##   · "不写入玩家历史"其实指的是它**不单独记账**：它写的还是同一份 _hist_for(cat)，
##     所以 remove_last_* 弹掉的可能是场景烘焙的那一株（两者共用一条栈）。
##   · 登记碰撞用的是 placed["pos"]（已含模型偏移），别改用参数 p，否则碰撞会错位。
func place_scene_item(node: Node3D, cat: String) -> bool:
	var p := Vector3(node.get_meta("px", node.position.x),
			node.get_meta("py", node.position.y),
			node.get_meta("pz", node.position.z))
	var s := float(node.get_meta("scale", 1.0))
	var yaw := float(node.get_meta("yaw", 0.0))
	var vi := int(node.get_meta("variant", 0))
	var placed: Dictionary = _add_instance(cat, p, s, _hist_for(cat), yaw, vi)
	if not placed["ok"]:
		return false
	# 场景烘焙的物件同样要进碰撞队列（树/石/家具/山体不走通用路径）
	if cat in COLLISION_CATEGORIES and cat not in ["bush", "mushroom", "stump"]:
		var model_path := str((_category_models[cat] as Array)[int(placed["vi"])])
		_queue_collision(cat, model_path, placed["pos"] as Vector3, s, yaw)
	return true


## 从场景节点重建全部植被（Vegetation/Spawned/<cat> 下的子节点）
## 位置在烘焙时已固化；地形被刷改后由 sync_heights() 重新贴合。
##
## 参数：无（读本节点下的 "Spawned" 子节点，以及 _category_models 的分类表）。
## 返回：无（结束后 print 一行统计：成功 / 抽稀跳过 / 失败）。
## 副作用：建块、往 MultiMesh 里铺满实例、写各类历史栈、重建可交互家具表、print。
## 调用时机：WorldBuilder.build() 的第 4 步（在 clear_zones 之前，清场会再拿掉一批）。
## 注意事项：
##   · Spawned 不存在时**静默返回**（不算错误，方便没有烘焙节点的场景）。
##   · 分类表为空的类别整支跳过并计入 thinned（跳过条数 = 该 holder 的子节点数）：
##     这是刻意的 —— 否则 59220 个撒点会逐个尝试、逐个失败，白刷一屏日志。
##   · 非 Node3D 的子节点（可能的 Marker 之类）计入 failed，不中断流程。
##   · 这里不做地形贴合：py 是烘焙时的地形高度，地形改过要另行调用 sync_heights()。
func build_from_scene() -> void:
	var spawned := get_node_or_null("Spawned")
	if spawned == null:
		return
	_ensure_blocks()
	var placed := 0
	var failed := 0
	var thinned := 0
	for cat in _category_models.keys():
		var holder := spawned.get_node_or_null(str(cat))
		if holder == null:
			continue
		# 分类表为空（植物已移除）：整支跳过。否则这 59220 个撒点会逐个
		# 尝试放置再失败，白白刷一屏失败数。
		if (_category_models[cat] as Array).is_empty():
			thinned += holder.get_child_count()
			continue
		for c in holder.get_children():
			if not (c is Node3D):
				failed += 1
				continue
			if place_scene_item(c, str(cat)):
				placed += 1
			else:
				failed += 1
	_rebuild_interactables()
	print("Vegetation | 从场景重建 %d 株（抽稀跳过 %d，失败 %d）" % [placed, thinned, failed])


## 地形高度改变后，把所有已放置实例重新贴合到新地表。
##
## 场景烘焙的 py 是当时的地形高度，地形起伏被重做（或玩家用刷子推土）之后
## 这些 y 就全部作废 —— 山坡长高会把植被埋进地里，山坡挖低会让植被浮空。
## 这里按每个实例的模型偏移反推原始放置点，再用当前地形高度重新贴回地表。
##
## 参数：无（必须有 _terrain，否则直接返回 0）。
## 返回：int —— 实际改动过 y 的实例数（不含被河道剔除的那些）。
## 副作用：改写 MultiMesh 的实例变换；把河道里的实例**交换删除**并同步
##   counts / visible_instance_count（这会改变实例在 MultiMesh 里的下标！）。
## 调用时机：WorldBuilder.build() 在地形生成/清场之后调用一次；也可在玩家推土后调用。
## 注意事项：
##   · 因为"交换删除"会重排实例下标，历史栈里的 pos 与 MultiMesh 下标不再严格对应 ——
##     本函数之后如果需要精确撤销，得靠 _rebuild_all_hist() 重建（用零位置占位）。
##   · 循环变量 i 是**手写自增**的：删除分支 continue 时绝对不能再 i -= 1（会越界，
##     下面那段注释记录了实测 22 条越界的历史）。
##   · 高度差小于 0.005 视为"已贴合"跳过，避免浮点误差导致的每帧抖动与无意义回写。
func sync_heights() -> int:
	if _terrain == null:
		return 0
	_ensure_blocks()
	var moved := 0
	var off_cache := {}
	for block in _blocks:
		var mmis_by_cat: Dictionary = block["mmis"]
		var counts_by_cat: Dictionary = block["counts"]
		for cat in mmis_by_cat.keys():
			var mmis: Array = mmis_by_cat[cat]
			var counts: Array = counts_by_cat[cat]
			var models: Array = _category_models[cat]
			for vi in mmis.size():
				var n: int = counts[vi]
				if n <= 0:
					continue
				var model_path := str(models[vi])
				var off: Vector3 = off_cache.get(model_path, Vector3.INF)
				if off == Vector3.INF:
					off = _model_place_offset(model_path)
					off_cache[model_path] = off
				var mm: MultiMesh = mmis[vi].multimesh
				# 用 while 而不是 for：河道剔除会在循环里做 O(1) 交换删除
				var i := 0
				while i < n:
					var xf := mm.get_instance_transform(i)
					var origin := xf.origin
					# 反推原始放置点（抵消缩放后的模型偏移）
					var sc := xf.basis.get_scale().x
					var yaw := xf.basis.get_euler().y
					var raw := origin - off.rotated(Vector3.UP, yaw) * sc
					var h := _terrain.get_height_at(raw.x, raw.z)
					# 河道里的植被要清掉：地形被挖下去以后，原本长在这里的草树会半淹在水里
					if _terrain.has_method("is_in_river") and _terrain.is_in_river(raw.x, raw.z):
						# 与末尾元素交换后缩短可见数量（不保留顺序，O(1) 删除）
						var last := n - 1
						if i != last:
							var lxf := mm.get_instance_transform(last)
							mm.set_instance_transform(i, lxf)
						n -= 1
						# **这里绝对不能 `i -= 1`。**
						# 这是 while 循环、自增是手写的（见下面两个分支的 i += 1），
						# continue 不会自增，再减一就等于回退到上一项；i == 0 时更会变成
						# -1，下一轮 get_instance_transform(-1) 直接越界报错，整个块的地形
						# 贴合和 counts/visible_instance_count 写回全部作废。
						# 交换进来的新元素正好落在 i 上，下一轮自然会处理它，不用动 i。
						# （实测：窗口模式每次运行报 22 条越界，headless 0 条 —— 因为
						#   headless 下随机撒点的顺序碰巧没让河道实例落在下标 0 上。）
						continue
					if absf(h - raw.y) < 0.005:
						i += 1          # while 循环必须手动推进，否则原地死循环
						continue
					xf.origin = Vector3(raw.x, h, raw.z) + off.rotated(Vector3.UP, yaw) * sc
					mm.set_instance_transform(i, xf)
					moved += 1
					i += 1
				if n < counts[vi]:
					counts[vi] = n
					mm.visible_instance_count = n
			pass
	return moved


## 场景自动撒点（铺满全图：每块均匀分配，保证远处也有植被）
##
## 参数：terrain —— 地形（会写进 _terrain 并取 HALF 当 _terrain_half）；
##   其余 7 个 count_* 是**全图目标株数**（不是每块数），单位：个。
##   默认值（树 3200 / 花 12000 / 草 32000 / 灌木 3200 / 石 1400 / 蘑菇 1000 / 树桩 600）
##   是"整张 900m 地图看起来够密"的量级，调大会线性增加建块与实例化耗时。
## 返回：无。副作用：建块、撒点、写 MultiMesh 与历史栈。
## 调用时机：调试/烘焙用（当前仓库里没有生产调用方 —— 正式世界走 build_from_scene()）。
## 注意事项：
##   · 会按 scene_seed 重置 _rng 种子，所以同样的参数总能撒出同样的布局；
##     与 plan_layout() 共用 _run_scatter 就是为了"烘焙与运行时结果一致"。
##   · 分类表为空的类别撒点会全部失败（_add_instance 返回 ok=false），
##     所以现在调它基本只会得到岩石/树桩/家具这类结果。
func populate_auto(terrain: TerrainSystem, count_trees: int = 3200, count_flowers: int = 12000, count_grass: int = 32000, count_bushes: int = 3200, count_rocks: int = 1400, count_mushrooms: int = 1000, count_stumps: int = 600) -> void:
	_terrain = terrain
	_terrain_half = terrain.HALF
	if scene_seed > 0:
		_rng.seed = scene_seed
	_ensure_blocks()
	var plan := {
		"tree": count_trees,
		"bush": count_bushes,
		"flower": count_flowers,
		"grass": count_grass,
		"rock": count_rocks,
		"mushroom": count_mushrooms,
		"stump": count_stumps,
	}
	_run_scatter(terrain, plan)


## 按计划撒点（populate_auto 与 plan_layout 共用同一条路径，保证结果一致）
##
## 参数：terrain —— 地形；plan —— {分类名: 全图目标株数}（键必须能在 _scale_ranges 里找到）。
## 返回：无。
## 副作用：调用 add_tree / add_rock / _add_instance 撒点（写 MultiMesh、历史栈；
##   layout_mode 为真时只往 plan_items 记录，不建碰撞体）。
## 注意事项：
##   · 每块撒 per_block = ceili(目标数 / 块数) 个，所以实际总量会略多于目标数
##     （ceili 向上取整），且分布是"每块等量"而不是按面积密度 —— 这是刻意的：
##     单块失败（落点在地图外/河道外被拒）不会让远处的块整体缺植被。
##   · _random_in_block 返回 Vector3.INF 表示本次落点被高度过滤拒绝，直接跳过
##     （不重试到满，所以实际数量通常少于理论值）。
##   · 树/石走带碰撞登记的专用入口，其余走通用 _add_instance（见 _add_instance 里
##     对 tree/rock/mountain/furniture 的排除）。
func _run_scatter(terrain: TerrainSystem, plan: Dictionary) -> void:
	for cat in plan:
		# 每块均摊 + 向上取整：宁可总量略多，也不要因为某块失败而让远处的块缺植被。
		var per_block := ceili(plan[cat] / float(_block_n * _block_n))
		var sr: Array = _scale_ranges[cat]
		for bi in _block_n * _block_n:
			var bx := bi % _block_n
			# 整数除法（故意的）：bi = bz * _block_n + bx，所以整除结果就是 bz。
			# GDScript 会对此报 INTEGER_DIVISION 警告，这里保持与建块顺序一致，不要改。
			var bz := bi / _block_n
			for _i in per_block:
				var p := _random_in_block(terrain, bx, bz)
				if p == Vector3.INF:
					continue
				var s := _rng.randf_range(sr[0], sr[1])
				match cat:
					"tree":
						add_tree(p, s)   # 带树干胶囊碰撞
					"rock":
						add_rock(p, s)   # 带石头盒碰撞
					_:
						_add_instance(cat, p, s, _hist_for(cat))


## 烘焙用：跑一次撒点并把落点导出为纯数据（不建碰撞体，可由场景节点取代）
##
## 参数：terrain —— 地形；counts —— {分类名: 目标株数}（与 _run_scatter 的 plan 同格式）。
## 返回：{"counts": 入参回显, "items": 落点数组, "seed": scene_seed, "placed": 各类实际数量}。
##   每个 item 形如 {cat, pos, scale, yaw, variant, color, bx, bz}，就是
##   main.tscn 里 Spawned/<cat>/* 节点 metadata 的来源。
## 副作用：打开 layout_mode 跑一遍撒点（只改 plan_items / _category_total，不建碰撞体、
##   不写玩家的可玩状态），结束后复位 layout_mode = false、plan_items = []。
## 调用时机：离线烘焙工具（当前仓库里没有生产调用方）。
## 注意事项：
##   · 导出后 plan_items 就被清空，返回的 out["items"] 是**同一个数组的引用**，
##     调用方必须马上序列化，不能指望之后再读 plan_items。
##   · 会先 _reset_totals()，所以它不影响先前世界的 _category_total 记账准确性 ——
##     但会把计数清零，别在世界已经铺好之后调它。
func plan_layout(terrain: TerrainSystem, counts: Dictionary) -> Dictionary:
	_terrain = terrain
	_terrain_half = terrain.HALF
	layout_mode = true
	plan_items = []
	_reset_totals()
	if scene_seed > 0:
		_rng.seed = scene_seed
	_ensure_blocks()
	_run_scatter(terrain, counts)
	var out := {"counts": counts, "items": plan_items, "seed": scene_seed,
			"placed": _category_total.duplicate()}
	layout_mode = false
	plan_items = []
	return out


## 清空各类计数（烘焙前复位）
##
## 参数：无。返回：无。副作用：_category_total 各类归零（**不改** MultiMesh 实例、
##   不清历史栈、不动碰撞体）。
## 调用时机：plan_layout() 开头（保证烘焙导出的 placed 数量只反映本次撒点）。
## 注意：它是一个"纯记账"复位，误用会让满员判断失效（上限看起来又空出来了），
##   世界已经铺好之后不要调。
func _reset_totals() -> void:
	for cat in _category_total.keys():
		_category_total[cat] = 0

## 在指定块内随机取一个可用的落点（撒点专用）
##
## 参数：terrain —— 地形（用来查高度）；bx / bz —— 块下标（0 .. _block_n-1）。
## 返回：Vector3(x, 地形高度, z)；8 次尝试都被高度过滤拒绝时返回 **Vector3.INF** 表示
##   "本块这次没落点"（调用方必须判 INF 再跳过，不能直接当地点用）。
## 副作用：消耗 _rng 随机数。
## 注意事项：
##   · margin(4m) 是给块边留的余量：不让落点贴着块缝，避免相邻块的物体挤在一起，
##     也减少"跨界"物体的视觉重复。
##   · 高度过滤放宽到 (-0.5, 4.0)：低洼草地与整平平台（约 0.4 高）也要能长东西，
##     否则地图上大片区域会空着。改窄会明显减少植被总量。
##   · 只做 8 次尝试（不是 while true）：宁可少放几株也不要在陡坡/河道附近长时间重试。
func _random_in_block(terrain: TerrainSystem, bx: int, bz: int) -> Vector3:
	var margin := 4.0
	var x0 := -_terrain_half + bx * CHUNK_SIZE + margin
	var z0 := -_terrain_half + bz * CHUNK_SIZE + margin
	for _try in 8:
		var x := x0 + _rng.randf_range(0.0, CHUNK_SIZE - margin * 2.0)
		var z := z0 + _rng.randf_range(0.0, CHUNK_SIZE - margin * 2.0)
		var h := terrain.get_height_at(x, z)
		# 放宽高度过滤：低洼草地与整平平台（0.4）也长草/花/树，保证全图铺满
		if h > -0.5 and h < 4.0:
			return Vector3(x, h, z)
	return Vector3.INF

# ==================== 对外添加接口（放/收/查） ====================

## 添加一棵树（随机变体 + 模型 trimesh 碰撞体；yaw>=0 指定朝向；满员时顶掉最近一棵保证可种）
## variant >= 0 时指定模型变体（滚轮选中的那一个），否则随机；返回实际使用的变体下标
## variant 落在额外变体区间（即归到树木下的植物）时走植物放置：不建碰撞、不吃 3.4 倍缩放。
##
## 参数：pos —— 世界坐标放置点；scale —— 等比缩放（默认 1.0）；
##   yaw —— >= 0 指定朝向（弧度），< 0 随机；variant —— >= 0 指定变体下标，< 0 随机。
## 返回：int 实际使用的变体下标；失败（分类表空/容量满）返回 -1。
## 副作用：满员时先 remove_last_tree() 顶掉最近一株（连带其碰撞体）；
##   成功则写 MultiMesh/历史栈，并在非 layout_mode 下登记碰撞（immediate = true）。
## 调用时机：**只在本文件内被 _run_scatter() 调用**。注意游戏里的树木放置工具走的是
##   building_manager.add_tree()（另一套独立实现，见 building_manager.gd），
##   不要以为滚轮切换变体会走到这里。
## 注意事项：
##   · 上面"额外变体区间/植物放置/3.4 倍缩放"的描述是**植物系统移除前**的历史行为，
##     现在 add_tree 里已经没有这些分支；实际碰撞是模型三角网（不是胶囊/盒）。
##   · layout_mode 下直接返回变体下标、**不登记碰撞**（烘焙只导出落点）。
func add_tree(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if _category_total["tree"] >= MAX_TREES:
		remove_last_tree()
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("tree", pos, scale, _tree_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	_queue_collision("tree", str((_category_models["tree"] as Array)[vi]),
			placed["pos"] as Vector3, scale, yaw, true)
	return vi

## 添加一丛灌木（无返回值；朝向恒为随机、不建碰撞体）
##
## 参数：pos —— 世界坐标；scale —— 等比缩放。
## 返回：无（注意与 add_tree 不同：拿不到变体下标；成功与否也无法从这里判断）。
## 副作用：写 MultiMesh/历史栈；成功时在 _add_instance 内部登记碰撞
##   （bush 属于 COLLISION_CATEGORIES，走"随视野流式建"的路径）。
## 调用时机：当前仓库里**没有调用方**（bush 模型表也是空的），属于保留接口。
func add_bush(pos: Vector3, scale := 1.0) -> void:
	_add_instance("bush", pos, scale, _bush_hist)

## variant >= 0 时指定模型变体；返回实际使用的变体下标
## variant 落在额外变体区间（即归到花草下的植物）时走植物放置。
##
## 参数：pos —— 世界坐标；scale —— 等比缩放；yaw —— >= 0 指定朝向，< 0 随机；
##   variant —— >= 0 指定变体下标。
## 返回：int 实际变体下标；失败时返回 -1（_add_instance 失败会把 vi 置为 -1，
##   这里**没有**单独判 ok，所以 -1 就是失败信号）。
## 副作用：满员时先 remove_last_flower()（只弹历史，不涉及碰撞体 —— 花没有碰撞）；
##   成功则写 MultiMesh/历史栈并可能写实例色（flower 在 COLORED_CATEGORIES 里）。
## 调用时机：main.gd 的花卉放置工具。
## 第二行注释里的"额外变体区间/植物放置"是植物系统移除前的历史行为，现在代码里没有。
func add_flower(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if _category_total["flower"] >= MAX_FLOWERS:
		remove_last_flower()
	var placed: Dictionary = _add_instance("flower", pos, scale, _flower_hist, yaw, variant)
	return int(placed["vi"])

## 添加一棵草（无返回值；朝向恒为随机、不建碰撞体）
##
## 参数：pos —— 世界坐标；scale —— 等比缩放。
## 返回：无。副作用：写 MultiMesh/历史栈；满员时**不顶替**（_add_instance 直接失败），
##   因为 grass 上限最高（MAX_GRASS）且数量巨大，顶替没有意义。
## 调用时机：当前仓库里**没有调用方**（grass 模型表为空），属于保留接口。
## 注意：grass 是唯一被 set_grass_visible() 整体隐显的类别（见 _update_visibility）。
func add_grass(pos: Vector3, scale := 1.0) -> void:
	_add_instance("grass", pos, scale, _grass_hist)

## 添加一块石头（模型 trimesh 碰撞；yaw>=0 指定朝向；满员时顶掉最近一块）
## variant >= 0 时指定模型变体；返回实际使用的变体下标
##
## 参数：pos —— 世界坐标；scale —— 等比缩放（通常 0.6~1.6）；yaw —— < 0 随机；
##   variant —— >= 0 指定变体下标。
## 返回：int 实际变体下标；失败（ROCK_MODELS 为空 / 容量满）返回 -1。
## 副作用：满员时先 remove_last_rock()；成功则登记碰撞（immediate = true，立刻建体）。
## 调用时机：本文件内被 _run_scatter() 调用；玩家放置石头由 main.gd 的石头工具负责。
## 注意事项：这里用 ROCK_MODELS[vi] 直接取路径（而不是 _category_models["rock"][vi]）——
##   两者指向同一个数组，但如果你改动 _category_models["rock"] 的绑定，这里会跟着出错。
##   另外回收时石头单独算"石材"（STONE_VALUE），不混进生物质。
func add_rock(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("rock", pos, scale, _rock_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	_queue_collision("rock", ROCK_MODELS[vi], placed["pos"] as Vector3, scale, yaw, true)
	return vi

## 植被碰撞体：直接使用对应视觉模型的三角网格（共享 shape 资源），碰撞顶面与模型表面完全一致，避免踩上去浮空
## 收集场景内所有 MeshInstance3D 的 faces，并按节点变换到根空间，保证与视觉完全贴合
##
## 参数：n —— 场景根节点；xform —— 父级累计变换（调用方传 Transform3D.IDENTITY）；
##   out —— 输出顶点数组（**原地追加**，每 3 个连续顶点构成一个三角面）。
## 返回：无。副作用：只写 out（不实例化、不释放节点 —— 临时实例的释放由调用方负责）。
## 调用时机：只被 _shape_for() 调用，用来喂 ConcavePolygonShape3D.set_faces()。
## 注意事项：
##   · 与 _collect_merged() 的区别：本函数**只收面**，不做逐顶点法线/顶点色/索引，
##     也不处理非 Node3D 的子树 —— 两者不能互相替换。
##   · 递归**不判断可见性**：被隐藏的细节子网格也会进碰撞形状（这是"贴合视觉"的取舍）。
##   · 根节点自身的 transform 会被乘上（调用方传 IDENTITY 就是这个意思）。
func _collect_mesh_faces(n: Node3D, xform: Transform3D, out: PackedVector3Array) -> void:
	var t: Transform3D = xform * n.transform
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mf := (n as MeshInstance3D).mesh.get_faces()
		for v in mf:
			out.append(t * v)
	for c in n.get_children():
		if c is Node3D:
			_collect_mesh_faces(c as Node3D, t, out)

## 从任意模型资源里取"第一个"网格（Mesh 直接用；PackedScene 就实例化后取第一个）
##
## 参数：model_path —— 资源路径（.glb / .tres 等）。返回：Mesh 或 null。
## 副作用：**PackedScene 分支没有 free 临时实例**（与 _load_glb_mesh 的写法不一致）——
##   实例未入树，靠引用计数回收；这是既有实现，改动前先确认不会留下悬空引用。
## 调用时机：category_model_mesh()（UI 预览）、_furniture_stand_height()（估坐高）。
## 注意事项：只取第一个网格 → 多子网格模型会丢细节；需要全部子网格请看
##   _extract_mesh_merged()（合并）或 _collect_mesh_faces()（收碰撞面）。
func _extract_mesh(model_path: String) -> Mesh:
	var m: Variant = load(model_path)
	if m is Mesh:
		return m
	if m is PackedScene:
		var inst := (m as PackedScene).instantiate()
		var mi := _find_first_mesh(inst)
		if mi != null and mi.mesh != null:
			return mi.mesh
	return null

## 深度优先找第一个 MeshInstance3D 节点（**不要求 mesh 非 null**，返回节点本身）
##
## 参数：n —— 任意节点。返回：MeshInstance3D 或 null。
## 副作用：无（不释放临时实例 —— 调用方负责）。
## 调用时机：只被 _extract_mesh() 调用。
## 注意：看清楚这个"不判 mesh 是否为 null"的差别：
##   · _find_first_mesh_node()（上文）要求 mesh != null，用于取局部 AABB；
##   · _find_mesh()（上文）直接返回 mesh 资源。
##   三者名字很像但契约不同，替换任意一个都会引出难查的空引用/零 AABB 问题。
func _find_first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var r := _find_first_mesh(c)
		if r != null:
			return r
	return null

## 添加一朵蘑菇（无返回值判空；朝向随机或指定；不顶替，满员即失败）
##
## 参数：pos —— 世界坐标；scale —— 等比缩放（默认区间 0.60~1.00）；yaw —— < 0 随机；
##   variant —— >= 0 指定变体下标。
## 返回：int —— **实际是 _last_variant("mushroom") 的结果**，不是 _add_instance 的返回：
##   放置失败时它返回的是"上一朵的变体"或 0（无法区分失败）。
## 副作用：写 MultiMesh/历史栈；成功时在 _add_instance 内部登记碰撞（mushroom 在
##   COLLISION_CATEGORIES 里，随视野流式建体）。
## 调用时机：当前仓库里**没有调用方**（mushroom 模型表为空），属于保留接口。
func add_mushroom(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	_add_instance("mushroom", pos, scale, _mushroom_hist, yaw, variant)
	return _last_variant("mushroom")

## 添加一个树桩（朝向随机或指定；不顶替，满员即失败）
##
## 参数：pos —— 世界坐标；scale —— 等比缩放；yaw —— < 0 随机；variant —— >= 0 指定。
## 返回：int —— 同 add_mushroom，实际是 _last_variant("stump")，失败时无法区分。
## 副作用：写 MultiMesh/历史栈 + 实例色（stump 在 COLORED_CATEGORIES 里）；
##   成功时登记碰撞（stump 在 COLLISION_CATEGORIES 里）。
## 调用时机：当前仓库里**没有调用方**（stump 模型表 STUMP_MODELS 为空），属于保留接口。
func add_stump(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	_add_instance("stump", pos, scale, _stump_hist, yaw, variant)
	return _last_variant("stump")

## 添加一件家具/梯子（随机变体 + 模型 trimesh 碰撞；yaw>=0 指定朝向；满员顶掉最近一件）
## variant >= 0 时指定模型变体；返回实际使用的变体下标
##
## 参数：pos —— 世界坐标；scale —— 等比缩放（家具按真实尺寸，通常 1.0）；
##   yaw —— >= 0 指定朝向（弧度），< 0 随机；with_collision —— 是否生成碰撞体；
##   variant —— >= 0 指定变体下标（滚轮选中的下标经 main.gd 回传）。
## 返回：int 实际使用的变体下标；失败返回 -1。
## 副作用：满员先 remove_last_furniture()；成功则写 MultiMesh/历史栈，
##   with_collision 为真时登记碰撞（immediate = true，立刻建体）；
##   最后**无条件** _rebuild_interactables() 重建交互表（坐/睡/爬梯表）。
## 调用时机：main.gd 的家具放置工具。
## 注意事项：
##   · with_collision = false 是给"可走上去的家具"用的（见下面的注释）：
##     楼梯不建碰撞，靠角色的自动抬步走上去，否则踏面会被当成墙卡住人。
##   · 不管 with_collision 是真是假都会重建交互表 —— 新增家具必须立刻可交互。
func add_furniture(pos: Vector3, scale := 1.0, yaw := -1.0, with_collision := true, variant := -1) -> int:
	if _category_total["furniture"] >= MAX_FURNITURE:
		remove_last_furniture()
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("furniture", pos, scale, _furniture_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	if with_collision:
		_queue_collision("furniture", FURNITURE_MODELS[vi], placed["pos"] as Vector3, scale, yaw, true)
	# 楼梯等可走上去的家具不生成碰撞：避免踏面被判成墙而卡住，台阶交给自动抬步
	_rebuild_interactables()
	return vi

## 某分类原来（分块 MultiMesh 那套）的模型数量
##
## 参数：cat —— 分类名。返回：int（未知分类或值不是数组时返回 0，不报错）。
## 副作用：无。注意名字里的"原来"：它就是普通变体数量，现在没有"额外变体区间"了。
func category_base_count(cat: String) -> int:
	var models: Variant = _category_models.get(cat, null)
	return (models as Array).size() if models is Array else 0


## 某分类的模型变体数量（供 UI 滚轮切换用）
##
## 参数：cat —— 分类名。返回：int（0 表示该分类当前没有可选模型，UI 应只给提示）。
## 副作用：无。注意：它只是 category_base_count() 的薄包装，两者等价 ——
##   主程序里两个名字都在用（历史遗留），改行为要一起改。
func category_variant_count(cat: String) -> int:
	return category_base_count(cat)

## 某分类某个变体对应的模型路径（供预览加载真实模型）
##
## 参数：cat —— 分类名；variant —— 变体下标（**负数与越界都安全**）。
## 返回：String 模型路径；分类不存在或表为空时返回 ""（调用方必须判空字符串）。
## 副作用：无。
## 注意事项：
##   · 用 posmod 环绕：variant = -1 会取到**最后一个**变体 —— 主程序里"_current_variant
##     返回 -1 表示随机"的语义并不会在这里体现，这里的 -1 是"最后一个"，两者别混淆。
##   · 顺序与 category_base_count() 的下标一致，是 UI 滚轮与实际放置的共同协议。
func category_model_path(cat: String, variant: int) -> String:
	var models: Variant = _category_models.get(cat, null)
	if not (models is Array) or (models as Array).is_empty():
		return ""
	var list: Array = models
	return str(list[posmod(variant, list.size())])

# ==================== 家具互动（坐/睡/爬梯） ====================

## ---------- 家具互动（坐/睡/爬梯） ----------

## 家具交互类型：sit 坐 / sleep 睡 / climb 爬梯；"" 表示不可交互
##
## 参数：path —— 模型资源路径。返回："sit" / "sleep" / "climb" / ""（空串 = 不可交互）。
## 副作用：无。
## 注意事项：判定只依赖**文件基名**（如 chair.glb 的首段、bed*、ladder*），
##   所以改文件名就会改行为；新家具想可交互，文件名必须能落进下面几条判断里。
##   climb 目前没有 FURNITURE_MODELS 里的实际模型（梯子模型不在表里），属于预留分支。
func _furniture_kind(path: String) -> String:
	var n := path.get_file().get_basename()
	if n.begins_with("chair") or n == "bench" or n == "loungeChair" or n == "stoolBar":
		return "sit"
	if n.begins_with("bed"):
		return "sleep"
	if n.begins_with("ladder"):
		return "climb"
	return ""

## 家具站立面/爬升高度估算（由模型包围盒高度推导，带缓存）
##
## 参数：path —— 模型资源路径。返回：float，单位**米**（角色坐标里的"坐面上表面/爬升高度"）。
## 副作用：写 _furniture_height_cache（进程内每路径一次）。
## 调用时机：_rebuild_interactables() 为每件交互家具算一次。
## 取值范围：sit ∈ [0.3, 0.8]、sleep ∈ [0.3, 0.8]、climb ≥ 0.5；模型取不到时兜底 0.5。
## 注意事项：
##   · 系数 0.42 / 0.5 是经验值（推测是从"整件家具高度"反推座面高度：椅背占了上半部分）；
##     换一套尺寸完全不同的家具模型时，坐姿高度可能需要重新标定。
##   · climb 直接用模型高度 maxf(s, 0.5)：梯子要爬到顶，所以不能乘系数。
##   · 缓存键是路径字符串，改模型文件不会刷新，要重启。
func _furniture_stand_height(path: String) -> float:
	if _furniture_height_cache.has(path):
		return _furniture_height_cache[path]
	var mesh := _extract_mesh(path)
	var h := 0.5
	if mesh != null:
		var s: float = mesh.get_aabb().size.y
		match _furniture_kind(path):
			"sit":
				h = clampf(s * 0.42, 0.3, 0.8)
			"sleep":
				h = clampf(s * 0.5, 0.3, 0.8)
			"climb":
				h = maxf(s, 0.5)
	_furniture_height_cache[path] = h
	return h

## 重建可交互家具注册表（家具增删/回收后调用，遍历全部家具实例）
##
## 参数：无。返回：无。
## 副作用：先 _interactables.clear()，再重建为 [{kind, pos, yaw, height}]（**顺序不保证稳定**，
##   查询方只应按距离取最近，不要依赖下标）。
## 调用时机：add_furniture / remove_last_furniture / build_from_scene / clear_around /
##   recycle_around。**家具数量或位置一变就必须调**，否则注册表会指向已消失的家具。
## 注意事项：
##   · 它是 O(全部家具实例)（逐块逐变体逐实例读 MultiMesh 变换），所以只在增删时调用，
##     别放进 _process。
##   · 只登记 _furniture_kind 非空的家具（桌子之类不参与坐/睡/爬）。
##   · 遍历依赖 mmis["furniture"] 与 counts["furniture"]，两者必须同序（见 _create_block）。
func _rebuild_interactables() -> void:
	_interactables.clear()
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var mmis: Array = block["mmis"]["furniture"]
		var counts: Array = block["counts"]["furniture"]
		for vi in mmis.size():
			var kind := _furniture_kind(FURNITURE_MODELS[vi])
			if kind == "":
				continue
			var mm: MultiMesh = (mmis[vi] as MultiMeshInstance3D).multimesh
			var cnt: int = counts[vi]
			var stand_h := _furniture_stand_height(FURNITURE_MODELS[vi])
			for i in cnt:
				var t: Transform3D = mm.get_instance_transform(i)
				_interactables.append({
					"kind": kind,
					"pos": t.origin,
					"yaw": t.basis.get_euler().y,
					"height": stand_h,
				})

## 查询玩家附近最近的可交互家具；返回 {} 或 {kind,pos,yaw,height,distance}
##
## 参数：pos —— 查询中心（main.gd 传玩家位置）；radius —— 搜索半径（米），
##   超出半径的家具不会被选中（用平方距离比较，省一次开方）。
## 返回：Dictionary。找到时是注册表项的**浅拷贝**并补上 "distance"（米，水平距离）；
##   一个都没找到时返回空的 {}（调用方必须判 is_empty，不能直接取键）。
## 副作用：无（不修改 _interactables —— 返回的是 duplicate() 出来的副本）。
## 调用时机：main.gd 的交互提示/坐睡爬流程（每帧或按键时）。
## 注意事项：
##   · 只比较**水平**距离（x/z），完全忽略高度差 —— 上下楼层的家具理论上可能被误选
##     （当前场景多为平层，影响有限）。
##   · 线性扫描整张表；家具数量大时这里是热点，但可交互家具通常远少于普通装饰。
func find_nearest_interactable(pos: Vector3, radius: float) -> Dictionary:
	var best := {}
	var best_d2 := radius * radius
	for it in _interactables:
		var dx: float = (it.pos as Vector3).x - pos.x
		var dz: float = (it.pos as Vector3).z - pos.z
		var d2 := dx * dx + dz * dz
		if d2 < best_d2:
			best_d2 = d2
			best = it
	if best.is_empty():
		return {}
	var res := best.duplicate()
	res["distance"] = sqrt(best_d2)
	return res

## 添加一座山体（悬崖/岩壁随机变体 + 模型 trimesh 碰撞；yaw>=0 指定朝向；满员顶掉最近一座）
## variant >= 0 时指定模型变体；返回实际使用的变体下标
##
## 参数：pos —— 世界坐标；scale —— 等比缩放（main.gd 传 4.0，墙/崖才够大）；
##   yaw —— >= 0 指定朝向（弧度），< 0 随机；variant —— >= 0 指定变体下标。
## 返回：int 实际变体下标；失败返回 -1。
## 副作用：满员先 remove_last_mountain()；成功则登记碰撞（MOUNTAIN_MODELS[vi]，immediate）。
## 调用时机：main.gd 的山体放置工具。
## 注意事项：山体是**静态障碍**，碰撞层走 COLLISION_LAYER，缩放 4 倍后三角网体量很大，
##   所以 _shape_for 的共享缓存对山体尤其重要（否则每座山一份三角网）。
func add_mountain(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> int:
	if _category_total["mountain"] >= MAX_MOUNTAIN:
		remove_last_mountain()
	if yaw < 0.0:
		yaw = _rng.randf_range(0.0, TAU)
	var placed: Dictionary = _add_instance("mountain", pos, scale, _mountain_hist, yaw, variant)
	if not placed["ok"]:
		return -1
	var vi: int = int(placed["vi"])
	if layout_mode:
		return vi
	_queue_collision("mountain", MOUNTAIN_MODELS[vi], placed["pos"] as Vector3, scale, yaw, true)
	return vi

## 顶掉某类别最后放置的一个实例（含其模型碰撞体）
##
## 参数：cat —— 类别名；hist —— 该类历史栈（必须是 _hist_for(cat) 的同一份引用）。
## 返回：无（hist 为空直接 return）。
## 副作用：弹栈 + 回退 MultiMesh 计数；删掉该块 col_queue 里最后一条同类别描述；
##   从 _collision_nodes[cat] pop_back 一个碰撞体并 queue_free（顺带摘登记）。
## 注意：历史项若是**旧数组格式**（非 Dictionary），pos 会取 Vector3.ZERO →
##   bi 落在中心块，队列那一侧可能删错块（旧格式兼容路径的已知近似）。
##   它只处理一个块；跨块残留要由 clear_around / recycle_around 兜底。
func _remove_last_with_collision(cat: String, hist: Array) -> void:
	if hist.is_empty():
		return
	var raw: Variant = hist[hist.size() - 1]
	var pos: Vector3 = raw.get("pos", Vector3.ZERO) if raw is Dictionary else Vector3.ZERO
	var bx := clampi(int(floor((pos.x + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bz := clampi(int(floor((pos.z + _terrain_half) / CHUNK_SIZE)), 0, _block_n - 1)
	var bi := bz * _block_n + bx
	_remove_last(cat, hist)
	# 队列描述与已建实例都要去掉最后一个该类别项
	if bi >= 0 and bi < _blocks.size():
		var block: Dictionary = _blocks[bi]
		var queue: Array = block["col_queue"]
		for i in range(queue.size() - 1, -1, -1):
			if str((queue[i] as Dictionary).get("cat", "")) == cat:
				queue.remove_at(i)
				break
	if _collision_nodes.has(cat) and not (_collision_nodes[cat] as Array).is_empty():
		var sb: StaticBody3D = (_collision_nodes[cat] as Array).pop_back()
		if is_instance_valid(sb):
			_erase_body_from_block(sb)
			sb.queue_free()

# ==================== 移除与回收 ====================

## 撤销：顶掉"最后种下的一棵树"（连带它的碰撞体与队列描述）。
## 参数：无。返回：无。副作用：弹 _tree_hist、回退 MultiMesh 计数、删碰撞体。
## 注意：它也走历史上限顶替那条路径（add_tree 满员时调它），所以"撤销一棵"和
##   "为腾位置而顶掉一棵"是同一个动作。
func remove_last_tree() -> void:
	_remove_last_with_collision("tree", _tree_hist)

## 撤销：顶掉最后放的一丛灌木（灌木有碰撞体，所以走带碰撞体的路径）。
## 参数：无。返回：无。当前库内没有调用方（bush 表为空）。
func remove_last_bush() -> void:
	_remove_last_with_collision("bush", _bush_hist)

## 撤销：顶掉最后一朵花。参数：无。返回：无。
## 注意：花**没有碰撞体**，所以走轻量的 _remove_last（不碰队列与碰撞体登记）。
func remove_last_flower() -> void:
	_remove_last("flower", _flower_hist)

## 撤销：顶掉最后一株草。参数：无。返回：无。与花同理，草也没有碰撞体。
func remove_last_grass() -> void:
	_remove_last("grass", _grass_hist)

## 撤销：顶掉最后一块石头（带碰撞体）。参数：无。返回：无。
## 注意：撤销**不退**已获得的石材（recycle_around 的收益记账与撤销是两套流程）。
func remove_last_rock() -> void:
	_remove_last_with_collision("rock", _rock_hist)

## 撤销：顶掉最后一朵蘑菇（带碰撞体）。参数：无。返回：无。
func remove_last_mushroom() -> void:
	_remove_last_with_collision("mushroom", _mushroom_hist)

## 撤销：顶掉最后一件家具（带碰撞体），并**重建交互注册表**。
## 参数：无。返回：无。
## 注意：_rebuild_interactables() 不能省 —— 否则玩家会坐到已经被顶掉的椅子上。
func remove_last_furniture() -> void:
	_remove_last_with_collision("furniture", _furniture_hist)
	_rebuild_interactables()

## 撤销：顶掉最后一座山体（带碰撞体）。参数：无。返回：无。
func remove_last_mountain() -> void:
	_remove_last_with_collision("mountain", _mountain_hist)

## 撤销：顶掉最后一个树桩（带碰撞体）。参数：无。返回：无。
func remove_last_stump() -> void:
	_remove_last_with_collision("stump", _stump_hist)

## 从历史栈里弹掉最后一株并回退计数（**不处理碰撞体** —— 那是 _remove_last_with_collision 的职责）。
##
## 参数：cat —— 类别名；hist —— 该类历史栈（引用）。返回：无（空栈直接 return）。
## 副作用：hist.pop_back()；block["counts"][cat][vi] -= 1 并同步
##   MultiMesh.visible_instance_count；_category_total[cat] -= 1（下限 0）。
## 注意事项：
##   · 兼容两种历史格式：Dictionary（当前）与旧的 [bx, bz, vi] 数组。
##   · 它只是把 visible_instance_count 减 1：那个实例的数据仍在 MultiMesh 缓冲里，
##     只是不再显示，下次放置会覆盖同一槽位（所以不能靠读 MultiMesh 反查实例数量）。
##   · _blocks 直接按 bz * _block_n + bx 索引、没有防护 —— 所以调用前必须已经
##     _ensure_blocks()，且历史项里的 bx/bz 必须来自同一个已建块的世界。
func _remove_last(cat: String, hist: Array) -> void:
	if hist.is_empty():
		return
	var raw: Variant = hist.pop_back()
	var bx: int = int(raw.get("bx", 0)) if raw is Dictionary else int(raw[0])
	var bz: int = int(raw.get("bz", 0)) if raw is Dictionary else int(raw[1])
	var vi: int = int(raw.get("vi", -1)) if raw is Dictionary else int(raw[2])
	var block: Dictionary = _blocks[bz * _block_n + bx]
	var counts: Array = block["counts"][cat]
	if vi >= 0 and vi < counts.size() and counts[vi] > 0:
		counts[vi] -= 1
		var mm: MultiMesh = (block["mmis"][cat] as Array)[vi].multimesh
		mm.visible_instance_count = counts[vi]
	_category_total[cat] = maxi(0, _category_total[cat] - 1)

## 丢弃某块中落在圆形范围内的碰撞队列描述（清场/回收后不再补建）。
##
## 注意：队列被裁短时必须同步重建 col_bodies / col_built_n。
## 裁剪率通常很高（清一个 52m 的村庄会砍掉几百条），而且被裁掉的项里
## 可能已经有建好的碰撞体 —— 不同步的话下次 _resort_block_queue 会按
## 残留的 col_built_n 去索引已经变短的队列，直接越界报错。
func _drop_queued_in_area(center: Vector3, radius: float) -> void:
	if _blocks.is_empty():
		return
	var r2 := radius * radius
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var queue: Array = block["col_queue"]
		if queue.is_empty():
			continue
		# 快照：_erase_body_from_block 改的就是 block["col_bodies"] 这个数组本身，
		# 直接在活数组上按 i 索引会越走越偏（会漏释放 / 误保留）。
		var bodies: Array = (block["col_bodies"] as Array).duplicate()
		var kept: Array = []
		var new_bodies: Array = []
		var i := 0
		var changed := false
		for d in queue:
			var p: Vector3 = (d as Dictionary).get("pos", Vector3.ZERO)
			var dx := p.x - center.x
			var dz := p.z - center.z
			if dx * dx + dz * dz >= r2:
				kept.append(d)
				# 这一项之前建过体就一并保留（保持 bodies 与 queue 前缀一一对应）
				if i < bodies.size():
					new_bodies.append(bodies[i])
			else:
				changed = true
				# 这一项被丢掉：它若已建体，必须先释放掉
				if i < bodies.size():
					var sb: Node = bodies[i]
					if is_instance_valid(sb):
						_erase_body_from_block(sb)
						sb.queue_free()
			i += 1
		if changed or kept.size() != queue.size():
			block["col_queue"] = kept
			block["col_bodies"] = new_bodies
			block["col_built_n"] = new_bodies.size()
			block["col_built"] = new_bodies.size() >= kept.size()


## 把碰撞体从它所属块的登记数组里摘掉
##
## 参数：sb —— 目标 StaticBody3D（必须是本系统建出来的、带 meta("veg_block") 的那种）。
## 返回：无（没有 meta 或块下标越界时静默返回）。
## 副作用：从 _blocks[bi]["col_bodies"] 里 erase(sb)。**不动 col_built_n**。
## 调用时机：_trim_block_collisions / _drop_queued_in_area / _remove_last_with_collision
##   在 queue_free 碰撞体之前都会调它，避免 _collision_nodes / col_bodies 里留悬空引用。
## 注意事项：
##   · 它依赖 body 上的 meta("veg_block")（建体时写入），所以**必须**经
##     _make_instance_collision 创建，手工 new 出来的 body 调它没有效果。
##   · 它会缩短 col_bodies，和调用方手里的别名数组是同一个对象 —— 删完不能再按旧下标
##     remove_at（_trim_block_collisions 里那段注释讲的就是这个坑）。
##   · 摘掉之后调用方要自行把 col_built_n 同步成新的 bodies.size()。
func _erase_body_from_block(sb: StaticBody3D) -> void:
	if not sb.has_meta("veg_block"):
		return
	var bi := int(sb.get_meta("veg_block"))
	if bi >= 0 and bi < _blocks.size():
		(_blocks[bi] as Dictionary)["col_bodies"].erase(sb)


## 清空指定中心周围半径内的植被（出生点清场、建造区清理）
##
## 参数：center —— 世界坐标圆心；radius —— 半径（米，只比较水平距离 x/z）。
## 返回：无。**不计收益**（要收益请用 recycle_around）。
## 副作用：把圆内实例用"与末尾交换"的 O(1) 删除法从每个 MultiMesh 里去掉并回写
##   counts / visible_instance_count；删掉圆内碰撞体；裁碰撞队列描述；
##   **重建全部历史栈**（_rebuild_all_hist）与家具交互表。
## 调用时机：WorldBuilder._clear_zones()（出生点/村庄等 clear_zone 节点）。
## 注意事项：
##   · 交换删除会**打乱 MultiMesh 实例顺序**，所以必须重建历史栈；重建后的历史项
##     pos 是 Vector3.ZERO（只有 bx/bz/vi 是准的），因此清场之后再 remove_last_* 撤销时，
##     碰撞体那一侧可能定位到错误的块（见 _remove_last_with_collision 的说明）。
##   · 圆内碰撞体的删除走 `collisions.remove_child(c)` + queue_free，但**没有**摘掉
##     _collision_nodes 里的登记 —— 那里可能留下已释放的引用，靠 is_instance_valid 兜底。
##   · 别在 _process 里调：它要遍历全部块的每个 MultiMesh 实例。
func clear_around(center: Vector3, radius: float) -> void:
	if _blocks.is_empty():
		return
	var r2 := radius * radius
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		for cat in block["mmis"]:
			var mmis: Array = block["mmis"][cat]
			var counts: Array = block["counts"][cat]
			for mi in mmis.size():
				var mm: MultiMesh = mmis[mi].multimesh
				var count: int = counts[mi]
				var i := 0
				while i < count:
					var origin: Vector3 = mm.get_instance_transform(i).origin
					var dx := origin.x - center.x
					var dz := origin.z - center.z
					if dx * dx + dz * dz < r2:
						var last_t: Transform3D = mm.get_instance_transform(count - 1)
						mm.set_instance_transform(i, last_t)
						count -= 1
						mm.visible_instance_count = count
					else:
						i += 1
				counts[mi] = count
	# 同步清理树的碰撞体，避免残留隐形障碍
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var collisions := block["collisions"] as Node3D
		for c in collisions.get_children():
			var sb := c as StaticBody3D
			var dx: float = sb.global_position.x - center.x
			var dz: float = sb.global_position.z - center.z
			if dx * dx + dz * dz < r2:
				collisions.remove_child(c)
				c.queue_free()
	_drop_queued_in_area(center, radius)
	_rebuild_all_hist()
	_rebuild_interactables()

## 回收指定中心周围半径内的植被：移除实例（含树/石碰撞体）
## 返回 {"biomass": 植被生物质, "stone": 石头石材}——石头不混入生物质
##
## 参数：center —— 世界坐标圆心；radius —— 半径（米，只比较水平距离）。
## 返回：Dictionary {"biomass": float, "stone": float}（**累加值**，单位是"点数"不是个数：
##   每株按 BIOMASS[cat] / STONE_VALUE[cat] 折算，例如一棵树 = 10 生物质、一块石头 = 8 石材）。
## 副作用：与 clear_around 相同的删除与计数回退，外加累计收益；
##   有收益时才裁碰撞队列并重建历史栈（无收益则省掉这两步）。
## 调用时机：main.gd 的放置/地形笔刷流程（_recycle_vegetation），
##   以及一切"要动这块地就先清植被"的操作。
## 注意事项：
##   · **植被与石头分开记账**：树/灌木/花/草/蘑菇/树桩算生物质，石头算石材（见 BIOMASS /
##     STONE_VALUE），调用方不要把两者混成一个数字。
##   · 家具体系**不在** BIOMASS 表里，所以回收家具的收益是 0（但仍会被移除）。
##   · 和 clear_around 一样会重建历史栈（pos 归零），撤销的精度会下降。
func recycle_around(center: Vector3, radius: float) -> Dictionary:
	var result := {"biomass": 0.0, "stone": 0.0}
	if _blocks.is_empty():
		return result
	var r2 := radius * radius
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		for cat in block["mmis"]:
			var mmis: Array = block["mmis"][cat]
			var counts: Array = block["counts"][cat]
			var bm: float = BIOMASS.get(cat, 0.0)
			var sv: float = STONE_VALUE.get(cat, 0.0)
			var removed := 0
			for mi in mmis.size():
				var mm: MultiMesh = mmis[mi].multimesh
				var count: int = counts[mi]
				var i := 0
				while i < count:
					var origin: Vector3 = mm.get_instance_transform(i).origin
					var dx := origin.x - center.x
					var dz := origin.z - center.z
					if dx * dx + dz * dz < r2:
						var last_t: Transform3D = mm.get_instance_transform(count - 1)
						mm.set_instance_transform(i, last_t)
						count -= 1
						mm.visible_instance_count = count
						result["biomass"] += bm
						result["stone"] += sv
						removed += 1
					else:
						i += 1
				counts[mi] = count
			_category_total[cat] = maxi(0, _category_total[cat] - removed)
	# 同步清理树/石碰撞体，避免残留隐形障碍
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var collisions := block["collisions"] as Node3D
		for c in collisions.get_children():
			var sb := c as StaticBody3D
			var dx: float = sb.global_position.x - center.x
			var dz: float = sb.global_position.z - center.z
			if dx * dx + dz * dz < r2:
				collisions.remove_child(c)
				c.queue_free()
	if result["biomass"] > 0.0 or result["stone"] > 0.0:
		_drop_queued_in_area(center, radius)
		_rebuild_all_hist()
	_rebuild_interactables()
	return result

## 重建全部类别的历史栈：先清空，再按每个 MultiMesh 当前的 counts 补回等量的"占位历史项"。
##
## 参数：无。返回：无。
## 副作用：_hist_for(cat).clear() 后重新 append；**清空所有类别的撤销历史**。
## 调用时机：clear_around() / recycle_around()（交换删除打乱了实例顺序，旧历史失效）。
## 注意事项：
##   · 补出来的历史项只有 bx/bz/vi 是准的：pos = Vector3.ZERO、scale = 1.0、yaw = 0.0、
##     color = Color.WHITE 全是占位值 —— 目的是让 remove_last_* 的"数量回退"仍然正确
##     （_remove_last 只用 bx/bz/vi），但基于 pos 的碰撞体清理会失准。
##   · 外层用 `bi % _block_n` / `bi / _block_n` 反解块下标（整数除法），必须与
##     _ensure_blocks 的建块顺序保持一致。
##   · 它是 O(全部实例)，别放在高频路径上。
func _rebuild_all_hist() -> void:
	for cat in _category_models:
		_hist_for(cat).clear()
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var bx := bi % _block_n
		var bz := bi / _block_n
		for cat in block["counts"]:
			var counts: Array = block["counts"][cat]
			var hist: Array = _hist_for(cat)
			for vi in counts.size():
				for _j in counts[vi]:
					hist.append({"bx": bx, "bz": bz, "vi": vi, "pos": Vector3.ZERO,
							"scale": 1.0, "yaw": 0.0, "color": Color.WHITE, "cat": cat})

## 绑定相机（由 main 注入），立即做一次视野剔除
##
## 参数：cam —— 场景里的 Camera3D（main.gd 传 camera_rig.camera）。
## 返回：无。副作用：写 _camera，并**立刻**跑一次 _update_visibility()（会遍历所有块、
##   可能触发碰撞体补建入队）。
## 调用时机：main.gd 世界生成流程里，**早于**玩家开始移动；也是碰撞流式化的前置条件
##   （_camera 为 null 时 _stream_collisions 直接返回，碰撞体一个都不会建）。
## 注意：重复绑定（换相机、重建世界）是安全的，但每次都会立刻做一次全量剔除。
func set_camera(cam: Camera3D) -> void:
	_camera = cam
	_update_visibility()

## 设置草丛显隐（低画质关闭）
##
## 参数：v —— true 显示草丛、false 整体隐藏。返回：无。
## 副作用：写 _grass_visible 并**立刻**再跑一次 _update_visibility()。
## 调用时机：Settings.apply_quality()（按档位的 show_grass，最低档一般关掉）。
## 注意事项：
##   · 只切 MultiMeshInstance3D.visible（仅 grass 分类），**不移除实例、不改 counts** ——
##     来回切换不会丢草，也不额外占内存。
##   · 只影响"当前可见的块"；被剔除的块等再进视野时会用最新的 _grass_visible 重设
##     （见 _update_visibility 里的 active 分支）。
func set_grass_visible(v: bool) -> void:
	_grass_visible = v
	_update_visibility()

# ==================== 每帧更新与视野剔除 ====================

## 每帧主循环：驱动视野剔除（节流）、碰撞体流式补建、以及走远后的队列重排。
##
## 参数：delta —— 帧间隔（秒），只用于推进 _vis_timer。
## 返回：无。
## 副作用：按到达的间隔调用 _update_visibility()；每帧调 _stream_collisions() 与
##   _requeue_collision_blocks()（两者内部各自受预算/节流限制）。
## 调用时机：引擎每帧；_camera 为 null 或 _blocks 为空时立刻 return。
## 注意事项：
##   · 三个子任务的频率是**刻意解耦**的：剔除 5Hz（便宜但没必要每帧）、建体每帧但受
##     3ms 预算限制、重排每 6 帧检查一次 —— 合起来才把帧时间尖峰压住（历史事故见
##     _stream_collisions / _requeue_collision_blocks 的注释）。
##   · 别在这个函数里加全表遍历：它是每帧都在跑的路径。
func _process(delta: float) -> void:
	if _camera == null or _blocks.is_empty():
		return
	_vis_timer -= delta
	if _vis_timer <= 0.0:
		_vis_timer = VIS_UPDATE_INTERVAL
		_update_visibility()
	# 每帧分摊补建视野内块的碰撞体（与剔除频率解耦，避免一次性卡顿）
	_stream_collisions()
	# 玩家走远后，把最近的未建项又进入半径的块重新排队
	_requeue_collision_blocks()

## 视野剔除：按块中心到相机的距离，激活 view_radius 内的块。
## 同时驱动碰撞流式化：块进入视野补建碰撞体，离开视野释放。
##
## 参数：无（读 _camera.global_position 与 view_radius / _grass_visible）。
## 返回：无。
## 副作用：写每个块容器的 visible（整块显隐）；active 时按 _grass_visible 写 grass 的
##   MultiMeshInstance3D.visible；把需要建碰撞的块加进 _pending_blocks；
##   对"已有碰撞体但已不需要建"的块调 _trim_block_collisions() 剪尾。
## 调用时机：set_camera / set_grass_visible / view_radius 的 setter，以及 _process 里
##   每 VIS_UPDATE_INTERVAL 秒一次。
## 注意事项：
##   · 可见半径用 `view_radius + CHUNK_SIZE * 0.5`：块是按**块心**判距的，加半个块长
##     才能保证玩家所在块与紧贴的块不被误剔除（否则脚下那块可能刚好被判到范围外）。
##   · 剔除粒度是**整块**：view_radius 小于 CHUNK_SIZE 时会出现"什么都看不到"的极端情况。
##   · 碰撞那一段**不看块心**（历史 bug：按块心判断会让玩家身边的实例永远建不到碰撞），
##     而是走 _block_needs_collision() 按实例距离判断。
func _update_visibility() -> void:
	if _blocks.is_empty():
		return
	# 相机未接入前不做剔除：可见性保持默认（碰撞体此时也尚未建立）
	if _camera == null:
		return
	var p := _camera.global_position
	var active_r := view_radius + CHUNK_SIZE * 0.5
	var active_r2 := active_r * active_r
	for bi in _blocks.size():
		var block: Dictionary = _blocks[bi]
		var bx := bi % _block_n
		var bz := bi / _block_n
		var cx := -_terrain_half + (bx + 0.5) * CHUNK_SIZE
		var cz := -_terrain_half + (bz + 0.5) * CHUNK_SIZE
		var dx := cx - p.x
		var dz := cz - p.z
		var active := dx * dx + dz * dz <= active_r2
		(block["node"] as Node3D).visible = active
		if active:
			var grass_mmis: Array = block["mmis"]["grass"]
			for gmmi in grass_mmis:
				(gmmi as MultiMeshInstance3D).visible = _grass_visible
		# 碰撞流式化：**按实例距离**判断，不按块中心。
		# 块是 150m 见方，块中心之间隔 225m —— 按块中心判断的话玩家附近根本没有
		# "活跃块"，全图 9044 条碰撞队列只会建出 1020 条（远处物体没碰撞的真因）。
		if _block_needs_collision(bi):
			if not _pending_blocks.has(bi):
				_pending_blocks.append(bi)
		elif not (block["col_bodies"] as Array).is_empty():
			# 已建项全部离开碰撞半径：只裁掉远端那些，别整块释放
			_trim_block_collisions(bi)

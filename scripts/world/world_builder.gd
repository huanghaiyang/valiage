# =====================================================================
# world_builder.gd —— 世界组装器（World 系统 / 装配层）
# =====================================================================
#
# 【本文件职责】
#   把 scenes/main.tscn 里用节点"声明"出来的世界布局（出生点 / 地形平台 / 聚落建筑 /
#   道路 / 植被 / 清场区），按**唯一正确的顺序**翻译成一串对运行时系统的调用，
#   并把各步骤的统计数字汇总成一个 report 字典交回给调用方。
#   它自己**不生产任何世界内容**：不建网格、不撒植被、不摆建筑、不铺路 —— 所有实体都由
#   被它调用的系统（TerrainSystem / BuildingManager / RoadNetwork / VegetationSystem）创建；
#   本文件只负责"**顺序 + 汇总 + 日志**"。
#   全部函数都是 static、类从未被实例化（extends RefCounted、没有 new() 的地方），
#   因此**没有任何成员状态**：构建过程中各步骤之间只通过参数与返回值通信。
#
# 【属于哪个系统 / 调用链】
#   scripts/main.gd :: _ready() → WorldBuilder.build(...)（唯一调用方）
#     → 地形 generate → 平台整平 → 聚落建筑 → 道路 → 植被铺底 + 清场 + 贴地修正
#     → 地形网格/碰撞重建 → 注入相机地形 + 摆放出生点
#   调用方拿到 report 后只打印一行汇总日志，然后继续做预览 / UI / 输入 / 天气装配。
#
# 【场景中作为"事实来源"的节点（名字写死在下面的 get_node_or_null 里，改名 = 静默失效）】
#   Main/SpawnPoint                    出生点（SpawnPoint 节点，可选；缺失则退回 Player 的摆放位置）
#   Main/Terrain/Platform*             TerrainPlatform 平台整平件（半径 / 高度 / 采样方式）
#   Main/Roads/RoadPath*               RoadPath 道路（子 Marker3D 作为控制点）
#   Main/Buildings/Layout/*            建筑布局件（meta: kind = wall / house / tower）
#   Main/Settlements/ClearZone*        聚落清场区（meta: clear_radius = 半径，单位米）
#   Main/Vegetation/Spawned/<cat>/*    植被撒点（烘焙实例，由 VegetationSystem 读）
#   注意：Main/Terrain 自己挂着 TerrainSystem 脚本，平台件是它的**子节点**；
#         Main/Roads 自己挂着 RoadNetwork 脚本，RoadPath 是它的子节点。
#
# 【关键依赖】
#   · 七个参数全部由 main.gd 传入：六个 @onready 引用（terrain / vegetation / buildings /
#     roads / player / camera_rig）+ 主场景自身 self；本文件不自己查找任何系统节点。
#   · 无 autoload 依赖、不连信号、不读写文件、不加载资源（全文件没有 preload / load / FileAccess）。
#   · 有**两处**直接访问别的对象的私有（下划线）成员，两处都是设计内的耦合、不是笔误：
#     vegetation._terrain / _terrain_half / _category_total（build() 第 5 步与 5/6 那条日志），
#     以及 camera_rig._current_yaw / _current_pitch（place_spawn()；camera_rig 的文件头
#     明确把"出生时由 world_builder 直接写入"写成了约定）。
#
# 【主要对外接口】
#   build(main, terrain, vegetation, buildings, roads, player, camera_rig) -> Dictionary
#       唯一入口，返回统计 report（各键含义见 build() 的文档注释）。
#   place_spawn(main, terrain, player, camera_rig) -> bool
#       单独的出生点摆放步骤（build() 最后一步调它），返回"场景里是否真的存在 SpawnPoint 节点"。
#   其余 _apply_platforms / _build_roads / _clear_zones 是 build() 的私有子步骤。
#
# 【已知的坑与注意事项】
#   1. **顺序就是契约**：平台整平必须在地形生成之后、一切"取样地形高度"的动作之前，
#      否则道路 / 植被 / 出生点全部按旧高度贴地。改顺序前先通读 build()。
#   2. 每一步都是"**安全失败**"：找不到对应节点就静默返回 0，不报错、不中断后续步骤。
#      所以日志里"N 处 / N 条"为 0 时，第一嫌疑是**场景里没放那个节点**，不是代码坏了。
#   3. report["vegetation"] 初始化为 -1 且**本文件从不写入**（植被数量在植被系统内部统计，
#      build() 是直接把 vegetation._category_total 塞进日志的）。main.gd 也不读这个键 ——
#      它留在字典里（推测）是为了不破坏早期调用方已经写好的键名。
#   4. 平台整平的计数是"apply() 返回 true 的个数"，**不代表地形真的被整平了**：
#      TerrainSystem.flatten_region() 目前是空实现（Terrain3D 接管后脚本写不了高度），
#      方法存在它照样返回 true。日志"平台整平 4 处"只表示 4 个平台件提交了请求。
#   5. 进度日志编号是 1/6 ~ 6/6，但实际有 7 个阶段（第 7 步"相机与角色"没有编号日志），
#      中间还插了一条 "5b/6 植被贴地修正"。对日志时别按编号去数步骤。
#   6. VegetationSystem 的 _terrain / _terrain_half 是"下划线私有"成员，这里跨文件直接赋值；
#      这是历史遗留的**必要**耦合（sync_heights() 在 _terrain 为 null 时直接返回 0，
#      而 _ensure_blocks() 依赖 _terrain_half 换算分块下标）。改植被系统时要一起看这里。
#   7. 本文件没有编辑器预览路径（没有 @tool）：所有动作都由 main.gd 的 _ready() 在运行时驱动，
#      构建是**同步阻塞主线程**的，是首帧耗时的主要来源。
#   8. 注释语言中文、标识符英文；没有实现依据的推断一律标"（推测）"。
# =====================================================================

class_name WorldBuilder
extends RefCounted
## 世界组装器：把场景中声明的布局（出生点 / 地形平台 / 聚落 / 道路 / 植被）
## 按正确顺序应用到运行时系统上。
##
## 场景是结构的唯一事实来源：
##   Main/SpawnPoint                出生点（位置/朝向）
##   Main/Terrain/Platform*         整平平台（半径/高度）
##   Main/Roads/RoadPath*           道路（子 Marker3D 为控制点）
##   Main/Buildings/Layout/*        建筑布局件（meta: kind=wall/house/tower）
##   Main/Settlements/ClearZone*    聚落清场区（半径）
##   Main/Vegetation/Spawned/<cat>/* 植被撒点
##
## 运行时生成的顺序约束：
##   1) 地形生成 → 2) 平台整平（必须在生成之后、取样高度之前）
##   → 3) 聚落建筑 → 4) 道路 → 5) 植被铺底 + 清场 → 6) 网格/碰撞重建
##
## 实现约定补充：
##   · 全部方法为 static，类从未实例化 —— 没有任何实例状态，构建过程只靠局部变量与返回值传递。
##   · 所有"找节点"都用 get_node_or_null("写死的名字")，因此**节点改名 = 静默跳过**（计 0，不报错）。
##   · 步骤顺序即契约：平台整平必须早于一切"取地形高度"的动作，否则贴地全部按旧高度算。
##   · 场景是唯一事实来源：不要在代码里写死世界坐标（历史上兜底出生点就写死过坐标，
##     结果改出生点还得回来改代码，后来改成读场景里 Player 节点的摆放位置）。
##
## 更完整的职责 / 依赖 / 坑的清单见本文件最顶部的 `#` 横幅注释。

# ==================== 常量与标识 ====================

## 日志 / 调试用的系统标签（字符串 "WorldBuilder"）。
## 用途：（推测）早期版本用它做统一前缀，便于在控制台按标签过滤本系统的输出。
## 现状：本文件里**没有任何地方引用它** —— 下面所有 print 都是写死的字面量 "WorldBuilder | %d/6 ..."。
## 因此改这个常量**不会**改变日志前缀；要改日志请直接改那些 print 的格式串。
## 保留它（推测）是因为可能有外部脚本按 WorldBuilder.TAG 取标签（本仓库内检索不到调用点）。
const TAG := "WorldBuilder"


# ==================== 世界组装主流程 ====================

## 世界组装的唯一入口：按固定顺序把"场景声明"翻译成对运行时系统的一系列调用，并汇总统计。
##
## 参数（七个依赖全部由 main.gd 传入，本函数不做 null 校验）：
##   main        主场景根节点（main.gd 里是 self）。只用它 get_node_or_null 找 SpawnPoint /
##               Terrain / Roads / Settlements 这几个**装配挂点**；找不到就跳过对应步骤。
##   terrain     Main/Terrain 上的 TerrainSystem。提供 generate / get_height_at / rebuild / HALF。
##   vegetation  Main/Vegetation 上的 VegetationSystem。提供 build_from_scene / clear_around /
##               sync_heights；另外它的 _terrain / _terrain_half 会被本函数**直接写入**。
##   buildings   Main/Buildings 上的 BuildingManager。提供 build_from_scene / flush_all / get_undo_count。
##   roads       Main/Roads 上的 RoadNetwork。提供 setup / build_path。
##   player      角色（Player）。只在**缺失 SpawnPoint 时**被读取 global_position 当兜底锚点，
##               另外会被写入 global_position 与 rotation（见 place_spawn）。
##   camera_rig  CameraRig。写入 _current_yaw / _current_pitch，并调 aim_from_player() 让角色面向镜头前方。
##
## 返回：Dictionary —— 统计结果。键与含义（**调用方 main.gd 只读其中 6 个**）：
##   "spawn"        : bool  是否真的找到并使用了 Main/SpawnPoint 节点（false = 走了兜底路径）
##   "platforms"    : int   apply() 返回 true 的平台件数量（≠ 地形真被整平的处数，见文件头坑 4）
##   "buildings"    : int   BuildingManager 的历史栈条数（**一条 ≠ 一个建筑**，见下方注释）
##   "roads"        : int   收集到 ≥2 个控制点并已提交 build_path() 的道路条数
##   "clear_zones"  : int   生效的清场区数量（是 Node3D、有 clear_radius 且 > 0 的子节点数）
##   "vegetation"   : int   恒为初始值 -1 —— 本函数从不写它（见文件头坑 3）
##   "generated_ms" : int   **仅第 1 步** terrain.generate() 的耗时（毫秒），不含后续任何步骤
##
## 副作用（整条装配链里最重的一环）：
##   · 大量增改场景树：建筑实例、道路网格、植被 MultiMesh 与碰撞体（均由各子系统创建）。
##   · 直接改 VegetationSystem 的私有成员 _terrain / _terrain_half。
##   · 移动 player（global_position / rotation），并改 camera_rig 的 _current_yaw / _current_pitch。
##   · 打印 7 条日志（`1/6` … `6/6`，中间还加了一条 `5b/6`），控制台可见。
##   · 不写文件、不发信号、不加 autoload 状态。
##
## 调用时机：main.gd::_ready() 中、_wire_camera_rig() 之后、预览 / UI / 天气装配之前，
##   **全程同步执行一次**（阻塞主线程，是首帧耗时的主要来源）。
##   注意 generated_ms 只统计地形那一段，别把它当成整个 build() 的耗时。
##
## 注意事项：
##   1. 每一步都假设前一步已经完成，**顺序不可交换**（尤其平台整平必须先于所有贴地动作）。
##   2. 任何子系统缺少对应节点（或内部早退）都只是计 0，不会抛错、不会中断后续步骤。
##   3. 传入 null 参数会在第一次使用处崩溃（本函数不做防御），这是调用方的责任。
##   4. 重复调用会**叠加**效果（建筑重建会清空旧实例，但道路网格与植被会再铺一遍），
##      正常流程里只会从 main.gd 调一次。
static func build(main: Node3D, terrain: TerrainSystem, vegetation: VegetationSystem,
		buildings: BuildingManager, roads: RoadNetwork, player: Player,
		camera_rig: CameraRig) -> Dictionary:
	# 统计字典：键在下面逐步填写，初值就是"什么都没找到 / 没生效"的默认值。
	# "vegetation" 的 -1 是刻意的哨兵，表示"不统计" —— 植被数量在 VegetationSystem 内部
	# 按类别汇总，本函数只把它读进日志；注意这个键**后续不会再被赋值**，返回时仍是 -1。
	var report := {
		"spawn": false, "platforms": 0, "buildings": 0,
		"roads": 0, "clear_zones": 0, "vegetation": -1, "generated_ms": 0,
	}

	# ---- 1. 地形高度场 ----
	# 计时只包住 terrain.generate() 一行：它衡量的是"地形初始化"这一段，
	# 后面的整平 / 建筑 / 道路 / 植被都不计入，所以这个数字**不是**世界生成总耗时。
	var t0 := Time.get_ticks_msec()
	# generate() 现在很轻（Terrain3D 接管后不再程序化造地形，最多配置一次碰撞层并打印一行），
	# 但位置必须留在最前：后面所有贴地动作都假设它在先。重复调用是幂等的（内部双重去重）。
	terrain.generate()
	report["generated_ms"] = Time.get_ticks_msec() - t0

	print("WorldBuilder | 1/6 地形生成 %dms" % report["generated_ms"])
	# ---- 2. 地形平台（聚落操场等），必须在取样高度之前整平 ----
	# 计数语义：apply() 返回 true 只代表"平台件把整平请求提交给了地形系统"，
	# **不代表地形高度真的变了**（TerrainSystem.flatten_region() 目前是空实现）。
	report["platforms"] = _apply_platforms(main, terrain)

	print("WorldBuilder | 2/6 平台整平 %d 处" % report["platforms"])
	# ---- 3. 聚落建筑（场景布局件 → 构建实例） ----
	# 读 Buildings/Layout 下每个子节点的 meta（kind = wall / house / tower）写进历史栈，
	# 再全量重建成实例挂到 Buildings/Placed；布局节点本身只是"描述"，始终留在场景里。
	buildings.build_from_scene()
	# flush_all() 是**空实现**（放置本来就是即时 add_child、立刻可见），保留这次调用只是为了
	# 给"批量提交"留一个统一挂点，并让调用方不必因将来改成延迟构建而改动；
	# 别误以为"不调它建筑就不会出现"。
	buildings.flush_all()
	# 取的是历史栈条数：**一条 ≠ 一个建筑** —— 一次 add_wall 可能生成十几段墙却只算 1 条，
	# 所以日志里的"聚落建筑 N 件"实际含义是"N 次构建操作"。
	report["buildings"] = buildings.get_undo_count()
	print("WorldBuilder | 3/6 聚落建筑 %d 件" % report["buildings"])
	# ---- 4. 道路（贴合当前地形） ----
	# 先注入地形再铺路：RoadNetwork.build_path() 在 _terrain 为 null 时会整体静默跳过
	# （安全失败：不报错也不铺路），所以 setup() 必须排在 _build_roads() 之前。
	roads.setup(terrain)
	report["roads"] = _build_roads(main, roads)
	print("WorldBuilder | 4/6 道路 %d 条" % report["roads"])
	# ---- 5. 植被：先铺场景布局，再按清场区回收 ----
	# —— 直接写 VegetationSystem 的私有成员是**必要**的（不是笔误），这两个字段都没有公开 setter：
	#   · _terrain：sync_heights() 在它为 null 时第一行就 return 0，植被永远不会贴回地表；
	#   · _terrain_half：_ensure_blocks() 用它把世界坐标换算成"块下标"，必须在 build_from_scene()
	#     （内部会调 _ensure_blocks）**之前**设好，否则所有实例会被分到错误的块里 ——
	#     这类错误不会抛异常，只会让类别数量统计、可见性与碰撞流式全部悄悄对不上。
	# 这里取的 terrain.HALF 就是 TerrainSystem 的世界半径（900m 地图 → 450m）。
	vegetation._terrain = terrain
	vegetation._terrain_half = terrain.HALF
	# 把场景烘焙的植被撒点（Vegetation/Spawned/<cat>/*）铺成 MultiMesh 实例。
	# 依赖上面刚注入的 _terrain_half，所以这几行的顺序不能换。
	vegetation.build_from_scene()
	# 顺序：**先铺后清** —— 必须先有植被实例，清场区才有东西可回收；反过来等于白清一场。
	report["clear_zones"] = _clear_zones(main, vegetation)

	print("WorldBuilder | 5/6 清场 %d 处，植被 %s" % [report["clear_zones"], str(vegetation._category_total)])
	# 地形起伏重做后，把烘焙进场景的植被重新贴回新地表（否则山坡长高会埋住植被）
	# 返回被挪动的实例数；为 0 说明地形没变过，或者 _terrain 注入失败（后者会让 sync_heights 直接早退）。
	var resynced := vegetation.sync_heights()
	print("WorldBuilder | 5b/6 植被贴地修正 %d 株" % resynced)
	# ---- 6. 地形网格/碰撞重建，保证与高度数据一致 ----
	# 当前实现里 rebuild() 是空实现（Terrain3D 自己维护网格与碰撞，脚本不再重建），保留它是为了
	# 在"高度数据的生产者"与"网格的消费者"之间留一个显式的提交点：将来换回自家地形时只改实现，
	# 不必再调整这里的调用顺序。
	terrain.rebuild()

	print("WorldBuilder | 6/6 地形网格/碰撞重建完成")
	# ---- 7. 相机与角色 ----
	# 把地形交给相机：CameraRig._ready() 执行时 terrain 还是 null（世界尚未生成），而相机的贴地
	# 与地面拾取都要用这个引用，所以必须在世界生成完之后补注入。
	# 放在摆出生点之前只是顺序上的自然选择（aim_from_player() 用的是 player 而不是 terrain）（推测）。
	camera_rig.terrain = terrain
	# 摆角色与镜头。返回值只表示"场景里有没有 SpawnPoint 节点"：两种情况下角色都会被放好，
	# 区别只是坐标来自 SpawnPoint 还是来自 Player 在场景里的摆放位置。
	report["spawn"] = place_spawn(main, terrain, player, camera_rig)
	# 交回 main.gd：那边只用它打一行汇总日志（platforms / buildings / roads / clear_zones /
	# spawn / generated_ms），"vegetation" 这个键没有任何调用方。
	return report


# ==================== 出生点装配（相机 + 角色落位） ====================

## 出生点：读 Main/SpawnPoint（缺失则退回场景里 Player 节点摆放的坐标）
## SpawnPoint 给出的是角色朝向；相机 yaw 由 aim_from_player() 反推，保持镜头在角色身后。
##
## 作用：把出生点数据源（SpawnPoint）里的位置与朝向落到 player / camera_rig 上；
##   没有 SpawnPoint 时用一套写死的兜底参数，保证"删了出生点也能正常进游戏"。
##
## 参数：
##   main        主场景根节点，仅用于 get_node_or_null("SpawnPoint")。
##   terrain     地形系统，仅用于**兜底路径**里取 anchor 处的地面高度 get_height_at(x, z)。
##   player      被写入的角色：global_position = 出生点，rotation 置零。
##   camera_rig  被写入的相机：_current_yaw / _current_pitch = 出生朝向 / 俯仰，然后 aim_from_player()。
##
## 返回：true  = 场景里存在 SpawnPoint 节点，位置与朝向都取自它；
##       false = 没找到节点，走了兜底路径（build() 把返回值原样放进 report["spawn"]，
##               main.gd 只把它打进日志，**不据此分支**）。
##
## 副作用：
##   · 移动 player：写 global_position；把 player.rotation 置零 —— 本项目的角色朝向由相机 yaw
##     驱动（face_direction），节点自身 rotation 不再承载朝向，所以清零是**刻意**的。
##   · 改 camera_rig 的 _current_yaw / _current_pitch（"下划线私有"，但 camera_rig 的文件头就把
##     "由 world_builder 出生时直接写入"写成了约定）。
##   · 调 camera_rig.aim_from_player()：按新 yaw 让角色面向镜头前方（一次转到位），
##     使出生瞬间呈现背影；player 为 null 时那边会静默返回。
##   · 不新建节点、不发信号、不写文件。
##
## 调用时机：build() 的最后一步（地形 generate / 整平 / rebuild 之后）——
##   必须等高度数据就绪，否则兜底路径按旧高度算 y，角色可能落进地里。
##
## 注意事项：
##   1. 兜底锚点 anchor 是**读取那一刻**的 player.global_position（即场景里 Player 节点的摆放
##      位置，scenes/main.tscn 里约为 -51.94 / 0 / 19.79），紧接着同一个 player 就被写入覆盖，
##      所以"先读 anchor、后写 player"的顺序不能倒（倒了 anchor 就是上一次的出生点）。
##   2. 兜底写死的 hover = 2.0 与 SpawnPoint.hover_height 的默认值 2.0 一致（两条路径手感相同）；
##      兜底 pitch = -0.16 rad（约 -9.17°）与 SpawnPoint.pitch_degrees 默认 -9.4°（≈ -0.164 rad）
##      数值接近，但**来源不同**：改 SpawnPoint 的默认值不会同步改这里（推测两者是各自维护的）。
##      兜底 yaw = 0.0 表示面朝 -Z（本项目的默认朝向）。
##   3. 有 SpawnPoint 时三个值会**整体覆盖**兜底值（不是部分合并）：pos = sp.resolve_position(terrain)
##      （节点自身 x/z + 地形高度 + hover_height），yaw / pitch 分别来自 resolve_yaw() / resolve_pitch()；
##      优先级（face_target > 节点旋转 > yaw_degrees）与取值范围见 scripts/world/features/spawn_point.gd。
##   4. 出生朝向只在"出生这一瞬间"生效，之后完全由输入 / 相机接管。
static func place_spawn(main: Node3D, terrain: TerrainSystem, player: Player,
		camera_rig: CameraRig) -> bool:
	# 按写死的节点名查找：改名不会报错，只会静默走下面的兜底分支。
	# `as SpawnPoint` 兼容"节点存在但没挂脚本"的情况——那时也会退化为 null。
	var sp := main.get_node_or_null("SpawnPoint") as SpawnPoint
	# 兜底别再写死坐标：用场景里 Player 节点被摆放的位置
	# （原来写死 (6.0, 11.0)，改出生点还得回来改代码）
	var anchor: Vector3 = player.global_position
	# 悬空 2.0m：略高于地面，出生后靠重力自然落位（与 SpawnPoint.hover_height 默认值一致）
	var hover := 2.0
	# 兜底位置：只把 y 换成"当前地面高度 + hover"，x/z 沿用 anchor，避免角色漂到地形原点附近
	var pos := Vector3(anchor.x, terrain.get_height_at(anchor.x, anchor.z) + hover, anchor.z)
	# 兜底朝向（仅在没有 SpawnPoint 时使用）：yaw = 0 表示面朝 -Z；pitch 略微俯视（相机 pitch 约定）
	var yaw := 0.0
	var pitch := -0.16
	if sp != null:
		# 有 SpawnPoint 时三个值**整体覆盖**上面的兜底值（不做部分合并），位置与朝向同源、不会打架
		pos = sp.resolve_position(terrain)
		yaw = sp.resolve_yaw()
		pitch = sp.resolve_pitch()
	# 直接落位、不做插值：出生位置要在任何物理 / 相机逻辑跑起来之前就定死
	# （推测：平滑落位会把角色留在半路，出生瞬间的位置就不确定了）
	player.global_position = pos
	# 朝向完全由相机 yaw 驱动（face_direction），节点自身 rotation 不再承载朝向；
	# 清零是为了不把场景里可能残留的摆放角度带进游戏（推测这层"清残留"是它存在的理由）
	player.rotation = Vector3.ZERO
	# 写相机的"私有"当前角：camera_rig 文件头明确约定这两个字段由 world_builder 在出生时直写，
	# 属于设计内耦合；若改成走 setter，要同步改 camera_rig 那边的文档说明。
	camera_rig._current_yaw = yaw
	camera_rig._current_pitch = pitch
	# 必须显式调一次：上面改的只是缓存的 yaw / pitch，真正让角色转向（出生瞬间背对镜头、呈背影）的是
	# 这个函数；它只转角色模型，相机自身的位置由 CameraRig 的每帧逻辑摆位
	camera_rig.aim_from_player()
	# 返回值 = "有没有 SpawnPoint 节点"，不是"角色是否摆放成功"（两种情况都会摆好）
	return sp != null


# ==================== 子装配：地形平台整平 ====================

## 作用：遍历 Main/Terrain 下所有 TerrainPlatform 平台件，逐个把"整平请求"提交给地形系统。
##
## 参数：
##   main    主场景根节点；在它下面 get_node_or_null("Terrain") 找平台挂点。
##   terrain 原样传给 TerrainPlatform.apply() 的地形系统（整平的半径 / 目标高度由平台件自己决定）。
##
## 返回：int —— apply() 返回 true 的平台件个数；0 表示"没有 Terrain 节点"或"没有生效的平台"。
##   **这个数字不代表地形真的被整平了**：TerrainSystem.flatten_region() 目前是空实现
##   （Terrain3D 接管后脚本写不了高度），只要方法存在，apply() 就会返回 true。
##
## 副作用：可能修改地形高度数据（由地形系统内部决定），进而需要它自己重建网格与碰撞；
##   本函数自身不改场景树、不增删节点、不发信号、不写文件。
##
## 调用时机：build() 的第 2 步 —— **必须在地形 generate() 之后、任何 get_height_at() 采样之前**：
##   平台把地面整平之后，后面铺路 / 撒植被 / 摆出生点才会按整平后的高度贴地。
##
## 注意事项：
##   1. 遍历的是 Terrain 的**子节点**（场景里是 PlatformSpawn / PlatformVillage / PlatformOutpostA/B）：
##      Main/Terrain 自己挂的是 TerrainSystem 脚本，平台件只是被挂到它下面。
##   2. 计数用 `if c is TerrainPlatform and c.apply(terrain)` —— 短路求值，非平台件连 apply() 都不会调。
##   3. Terrain 节点不存在时直接返回 0（安全失败），不报错、也不去别处另找一个地形。
##   4. 这里不做任何"半径 / 高度是否合法"的校验（平台件只在编辑器里有配置警告），
##      传进去的配置错了就是整平结果不对，不会在运行时提示。
static func _apply_platforms(main: Node3D, terrain: TerrainSystem) -> int:
	# 按写死的节点名找挂点。注意 Main/Terrain（TerrainSystem 脚本）与场景里真正的 Terrain3D 是两个节点
	var holder := main.get_node_or_null("Terrain")
	if holder == null:
		return 0
	var n := 0
	# 直接遍历全部子节点、不做缓存：平台件数量很少（主场景 4 个），这里不需要索引或类型分组
	for c in holder.get_children():
		# 先判类型再调 apply()（靠 and 短路）：顺序反过来就是对着普通 Node3D 调不存在的方法，会直接报错
		if c is TerrainPlatform and (c as TerrainPlatform).apply(terrain):
			n += 1
	return n


# ==================== 子装配：道路铺设 ====================

## 作用：把 Main/Roads 下每个 RoadPath 节点的控制点交给 RoadNetwork，铺成贴合地形的砂石路。
##
## 参数：
##   main   主场景根节点；在它下面 get_node_or_null("Roads") 找道路挂点（该节点自带 RoadNetwork 脚本）。
##   roads  上述 RoadNetwork。本函数只调它的 build_path()，**前提是调用方已先调过 roads.setup(terrain)**，
##          否则 build_path() 会因为 _terrain 为 null 而静默什么都不铺（build() 里紧邻的一行就是 setup）。
##
## 返回：int —— 成功提交铺设的道路条数（控制点数 ≥ 2 才算一条）。
##   注意它统计的是"提交了几条路"，**不校验路是否真的铺出来了**（退化段会在 RoadNetwork 里被跳过）。
##
## 副作用：roads.build_path() 会在 Roads 节点下新增若干 MeshInstance3D（每段 1 个 + 每个控制点 1 个圆盘）；
##   本函数自身只读场景、不改 player / camera、不发信号、不写文件。
##
## 调用时机：build() 的第 4 步，**平台整平之后** —— 铺路要按整平后的地形高度贴地，
##   否则路面会与聚落平台穿模。
##
## 注意事项：
##   1. 控制点来自 RoadPath.collect_points()（世界坐标，Array[Vector3]）；
##      点的来源与顺序规则（子 Marker3D / start_point / extra_points）见 scripts/world/features/road_path.gd。
##   2. `pts.size() < 2` 时**静默 continue**：那条路不铺、也不报错（"路没出来"时先数控制点）。
##   3. 宽度取 RoadPath.width（单位米），作为 build_path 的第二个参数；本函数不校验它是否 > 0。
##   4. Roads 节点不存在时返回 0（安全失败）。
##   5. （场景现状）当前 scenes/main.tscn 的 Main/Roads 下没有任何 RoadPath 子节点，
##      所以日志里"道路 0 条"是预期结果，不代表流程断了。
static func _build_roads(main: Node3D, roads: RoadNetwork) -> int:
	# 与平台一样按写死的节点名找挂点；Main/Roads 是 RoadNetwork 自身所在的节点
	var holder := main.get_node_or_null("Roads")
	if holder == null:
		return 0
	var n := 0
	for c in holder.get_children():
		# 用"不是就跳过"的写法而不是"是才处理"：保持循环体只有一层缩进，便于下面继续早退
		if not (c is RoadPath):
			continue
		var path := c as RoadPath
		# collect_points() 可能返回 0 或 1 个点（取决于 RoadPath 的开关配置），本函数负责过滤
		var pts := path.collect_points()
		# 少于 2 个点连不成线段：静默跳过（RoadNetwork.build_path 里也有同样的早退，这里是双保险）
		if pts.size() < 2:
			continue
		# 宽度只在这里从 RoadPath 传进去；高度由 RoadNetwork 自己按 x/z 重新采样地形
		roads.build_path(pts, path.width)
		n += 1
	return n


# ==================== 子装配：聚落清场区（回收植被） ====================

## 作用：按 Main/Settlements 下各清场区声明的半径，把范围内的植被实例回收掉，
##   给聚落 / 出生点腾出空地 —— 否则建筑、道路会与树木草丛互相穿插。
##
## 参数：
##   main        主场景根节点；在它下面 get_node_or_null("Settlements") 找清场区挂点。
##   vegetation  执行清除的植被系统 clear_around(center, radius)：按**水平距离平方**比较来剔除实例。
##
## 返回：int —— 真正执行了清除的清场区数量（是 Node3D、带 clear_radius 且值 > 0 的子节点数）。
##   0 表示"没有 Settlements 节点"或"没有配置任何清场区"。
##
## 副作用：修改 vegetation 内部各分块 MultiMesh 的可见实例数（实例被移除且**不可恢复** ——
##   想恢复只能重建植被或重开场景）；本函数自身不改场景树、不发信号、不写文件。
##
## 调用时机：build() 的第 5 步，**紧跟在 vegetation.build_from_scene() 之后**：
##   必须先有铺好的植被实例，清场区才有东西可回收；先清后铺等于白清一场。
##
## 注意事项：
##   1. 半径来自节点 meta "clear_radius"（场景里写作 metadata/clear_radius = ...），单位米。
##      用 has_meta 判断存在性，**没有该 meta 的节点直接跳过且不报错** ——
##      "清了没反应"时第一件事是检查子节点是不是漏了这条 meta。
##   2. 中心用节点的 global_position（**含父节点变换**），把清场区挂到别的父节点下也不会偏。
##   3. radius <= 0 的配置被显式跳过：clear_around 拿到 0 / 负半径时行为没有意义（0 会清掉正下方的实例）。
##   4. 同时要求节点是 Node3D —— Settlements 下的空 Node / 脚本节点 / 分组文件夹不会被当成清场区。
##   5. 与 TerrainPlatform（整平地形）是两套独立机制：一个改高度、一个清植被，两者的位置 / 半径
##      需要人工对齐，否则会出现"地整平了但树还长在里面"或"树清了但地面还是斜的"。
static func _clear_zones(main: Node3D, vegetation: VegetationSystem) -> int:
	# 第三个写死的挂点名字：Settlements（场景里是 Node3D，子节点 ClearVillage / ClearOutpostA/B / ClearSpawn）
	var holder := main.get_node_or_null("Settlements")
	if holder == null:
		return 0
	var n := 0
	for c in holder.get_children():
		# 类型与 meta 必须**同时**满足；不满足就跳过（不用 `is Node3D` 的强转，避免对 Node 取 global_position 报错）
		if not (c is Node3D) or not c.has_meta("clear_radius"):
			continue
		# meta 是 Variant，统一按 float 读；场景里写的是浮点字面量（如 52.0 / 3.5）
		var radius := float(c.get_meta("clear_radius"))
		# 非正半径直接忽略：宁可少清一块，也不要用无意义的半径去动植被数据
		if radius <= 0.0:
			continue
		# 中心用 global_position（世界坐标），与场景里给该节点摆的位置一致
		vegetation.clear_around((c as Node3D).global_position, radius)
		n += 1
	return n

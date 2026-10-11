@tool
class_name TerrainQuality
extends Node
## 地表贴图分级（范例）
##
## 作用：按当前画质档位，把 Terrain3D 贴图资产里的 albedo / normal
## 换成对应分辨率的版本，并同步地形的 LOD 参数。
##
## 用法：
##   1. 在场景里加一个空 Node3D（或任意 Node），挂上本脚本
##   2. terrain_path 指到 Terrain3D（留空则自动在场景里找）
##   3. 每档贴图按 "…_diff_4k.jpg / _diff_2k.jpg / _diff_1k.jpg" 命名放好
##      （只有一套 4K 也能跑：找不到就逐级回退，最后回退到原图，绝不会变白）
##
## 切档：QualityManager.instance.set_tier(QualityTiers.Tier.LOW)
##
## ---------------------------------------------------------------------------
## 【所属系统】画质分级（scripts/quality/），与 quality_tiers.gd（档位数据）、
##   quality_manager.gd（档位管理器）以及 shadow_quality.gd / grass_quality.gd /
##   prop_texture_quality.gd 同族。本文件只负责其中「地表贴图分级 + 地形网格 LOD」。
##
## 【关键依赖】
##   · QualityManager（autoload 名 "Quality"，见 project.godot 的 [autoload]；
##     quality_manager.gd 在 _ready 里给静态变量 instance 赋值，并发出
##     tier_changed(tier:int) 信号）—— 切档事件的唯一来源。
##   · QualityTiers（纯数据 + 纯函数的 RefCounted，可单测）：
##       - PRESETS[tier] 中的 terrain_texture_suffix（"1k"/"2k"/"4k"）、
##         terrain_lod0_range、terrain_mesh_size 由本文件消费；
##       - get_preset(t) / tier_name(t) / texture_for_tier(path,t) /
##         resolve_existing(path,t) 是本文件的核心工具函数。
##   · Terrain3D 插件类型：Terrain3D、Terrain3DAssets、Terrain3DTextureAsset、
##     Terrain3DMeshAsset。工程若没启用 Terrain3D 插件，本脚本会解析失败 ✗。
##   · 资源命名约定：同一张贴图按分辨率拆成多份，靠文件名后缀区分，例如
##       brown_mud_leaves_01_diff_4k.jpg / _diff_2k.jpg / _diff_1k.jpg
##       rock_nor_gl_4k.png / _nor_gl_2k.png
##     也兼容 _1024 / _2048 / _4096 / _8192 的写法；原本没有后缀的会被补上一个
##     （具体规则见 QualityTiers.swap_resolution_suffix）。
##
## 【主要对外接口】
##   · apply_current() -> Dictionary                    按"当前档位"应用一次（最常用）
##   · apply_tier(t:int) -> Dictionary                  按指定档位应用一次并打印日志
##   · get_terrain() -> Terrain3D                       取得目标 Terrain3D（可能为 null）
##   · current_tier() -> int                            解析当前真正生效的档位
##   · static apply_on_assets(assets,t) -> Dictionary   纯逻辑核心，可脱离场景单测
##
## 【已知的坑 / 注意事项】
##   1. 编辑器里默认不动手（apply_in_editor = false）：切档会改写资源引用，在编辑器里
##      保存场景会把"当前档位的贴图路径"烤进场景文件 ✗（详见 apply_in_editor 的注释）。
##   2. 绝不碰 resource_path 为空的内嵌贴图 —— 这类贴图的大块图像数据会随场景/资源
##      一起保存，曾把 main.tscn 撑到 102 MB ✗（见 apply_on_assets 里的 inner 计数）。
##   3. 只做了一套 4K 贴图也能跑：本档没有就 resolve_existing 逐级回退，最后回退到
##      原路径，永远不会出现"贴图丢失 / 地表变白" ✓。
##   4. terrain_path 留空时会在 current_scene 里**深度优先**找第一个 Terrain3D；
##      场景里有多个 Terrain3D 时只会命中其中一个，要精确控制就显式填 terrain_path。
##   5. 本文件只替换 texture_list 里各资产的 albedo_texture / normal_texture 两路，
##      不碰 heightmap、control map、颜色权重等其他通道。
##   6. 本文件缩进必须是 Tab（GDScript 缩进敏感）；补注释时不要插进多行表达式的中间。
## ---------------------------------------------------------------------------

# ==================== 段一：配置（导出参数） ====================
## 目标 Terrain3D 节点的路径（NodePath）。
## 默认空（NodePath()）＝"不指定"，改由 get_terrain() 在场景里自动寻找
##   （从 get_tree().current_scene 起深度优先）。
## 填法：**相对挂本脚本的这个节点**的路径，如 "../Terrain3D"；
##   ⚠ 不是相对场景根 —— 挂错层级会找不到。
## 取值影响：填了但写错 → get_node_or_null 返回 null → apply_tier 直接返回 ok=false
##   （不会崩，但地表贴图与网格保持原样，且控制台没有任何提示，容易误以为脚本没生效）。
## 建议：场景里只有一棵 Terrain3D 时留空即可；有多棵时务必显式指定，避免命中错的那棵。
@export var terrain_path: NodePath
## 是否跟随全局画质管理器（QualityManager，autoload 名 "Quality"）的档位。
## true（默认）且 QualityManager.instance != null 时：_ready 里订阅 tier_changed 信号，
##   current_tier() 直接返回管理器当前档位 —— 这是游戏内的正常模式：
##   玩家在设置里切档，地表贴图自动跟着变 ✓。
## false：忽略全局档位，永远使用下面 tier 导出的值（适合单场景调试 / 画质对比截图）。
## 注意：管理器不存在时（autoload 没配、或单独跑某个场景被裁掉），本项即使是 true
##   也不会订阅信号，current_tier() 会退回读本地 tier ✓（不会变成"永远 HIGH"而报错）。
@export var follow_quality := true
## 本地档位。取值是 QualityTiers.Tier 枚举：LOW=0 / MEDIUM=1 / HIGH=2 / ULTRA=3。
## 只在 follow_quality == false（或 QualityManager.instance == null）时才真正生效，
##   即"自己说了算"的兜底档位。
## 默认 HIGH(2) 的理由：与 QualityTiers.PRESETS 中"高"档一致（4k 贴图、mesh_size 48、
##   lod0_range 128），是画质与性能的折中值，适合当作默认预览档。
## 调大（→ ULTRA=3）：4k 贴图 + mesh_size 64 + lod0_range 192 —— 更清晰，更吃显存/GPU。
## 调小（→ LOW=0）：1k 贴图 + mesh_size 32 + lod0_range 64 —— 省资源，远景地表更"糊"。
## 越界（如填 99）不会崩：get_preset() 取不到就回退 MEDIUM 预设，但贴图后缀会走默认 "4k"。
@export var tier: int = QualityTiers.Tier.HIGH
## 是否同时应用地形网格 / LOD 参数（terrain.mesh_size 与各 MeshAsset 的 lod0_range）。
## true（默认）：apply_tier 除了换贴图，还会按档位改 Terrain3D.mesh_size，并遍历
##   terrain.assets.mesh_list 设置每个 MeshAsset 的 lod0_range ✓。
## false：只换贴图，完全不动网格参数 —— 想单独观察"贴图分级"的效果、
##   或担心动 LOD 引起地形接缝/闪烁、把资产标脏时用这个。
## 副作用提醒：这两处分别写在 Terrain3D 节点和 Terrain3DMeshAsset 资源上，
##   在编辑器里（apply_in_editor = true）会被标脏，注意别顺手保存场景 ✗。
@export var apply_lod := true
## 编辑器里是否也自动应用。
## 默认 false —— 否则在编辑器里切档会把"当前档位的贴图路径"烤进场景文件 ✗。
## 想预览某档效果时再临时勾上 ✓。
@export var apply_in_editor := false


# ==================== 段二：生命周期（初始化 / 档位信号） ====================

## Godot 回调：节点进入场景树时（在其子节点 _ready 之前）执行一次。
## 作用，按顺序：
##   1. 编辑器守卫：在编辑器里且 apply_in_editor == false → 直接 return，什么都不做；
##   2. follow_quality 为真且画质管理器已就绪时，订阅其 tier_changed 信号；
##   3. 立即按当前档位应用一次，保证场景启动时地表就是对的，而不必等玩家切档。
## 参数：无。
## 返回值：无。
## 副作用：连接信号；可能改写 Terrain3D 与贴图资产的属性；会 print 一行日志。
## 调用时机：节点每次进入场景树时（重复入树会重复触发，见下面的注意）。
## 注意：
##   · 这里**没有** is_connected 去重（同族的 shadow_quality.gd 是有的）。若本节点被
##     反复 remove_child / add_child 重新入树，_ready 会重复执行并重复连接，
##     一次切档就会触发多次 apply_tier（推测：只浪费性能，不会产生错误状态）。
##   · 依赖 QualityManager.instance 已被赋值：autoload "Quality" 的 _ready 早于普通
##     场景节点，正常启动时序没问题；但手工 new 出来的 TerrainQuality 若先于管理器
##     _ready，当时连不上信号，之后也不会补连（会一直用本地 tier）。
##   · apply_in_editor == false 时，在编辑器里切档看不到任何变化，这是故意的 ✓。
func _ready() -> void:
	# 编辑器里默认不动手：切档若改到场景里的贴图引用，保存后档位就被"烤"进场景了 ✗
	if Engine.is_editor_hint() and not apply_in_editor:
		return
	# 只有在"跟随全局档位"且管理器实例已就绪时才订阅；两者缺一就只按本地 tier 应用一次，
	# 所以"没配 autoload 也能看到效果"，不会静默失效 ✓
	if follow_quality and QualityManager.instance != null:
		QualityManager.instance.tier_changed.connect(_on_tier_changed)
	# 启动即对齐一次：否则玩家没切过档时，地表会一直停在场景里烤死的旧贴图 ✗
	apply_current()


## 信号回调：QualityManager.tier_changed 的接收端。
## 参数 t：新档位（QualityTiers.Tier 枚举，0~3；管理器 set_tier 里已 clampi，可视为合法值）。
## 返回值：无（信号回调不返回值）。
## 副作用：等价于调用 apply_tier(t) —— 换贴图、按 apply_lod 改 LOD、打印日志。
## 调用时机：仅当 follow_quality == true 且管理器存在（即 _ready 里订阅成功）时，玩家/代码切档后。
## 注意：此处**不**再判断 follow_quality —— 因为信号本身就只在 follow_quality 为真时才被连上；
##   另外 _ready 未做去重（见 _ready 注释），理论上可能被连多次而重复执行（幂等，无状态错误）。
func _on_tier_changed(t: int) -> void:
	apply_tier(t)


# ==================== 段三：查找目标 Terrain3D ====================

## 取得本次操作要作用的 Terrain3D 节点。
## 参数：无。
## 返回：Terrain3D；找不到时返回 null（调用方必须判空，apply_tier 就是这么做的）。
## 查找顺序：
##   1. terrain_path 非空 → 只按该路径查找（get_node_or_null），找不到就返回 null，
##      **不做**自动兜底 —— 即"显式指定了就严格按指定来"，避免静默作用到别的 Terrain3D ✗；
##   2. terrain_path 为空 → 从 get_tree().current_scene 起深度优先找第一个 Terrain3D；
##   3. 连 current_scene 都拿不到（节点还没进树 / get_tree() 为 null）→ 从 self 起找。
## 副作用：无（只读场景树；且**不缓存**结果，每次调用都重新查找，运行期增删节点也能拿到最新的）。
## 注意：`NodePath()` 就是空路径，用 `!= NodePath()` 判断"有没有填"而不是判断 null；
##   @export 的 NodePath 默认值正是这个空 NodePath ✓。
func get_terrain() -> Terrain3D:
	# 显式填了路径就只认它：用 `as` 强转，节点存在但类型不对时静默变 null（交给调用方判空），
	# 对"配置写错也尽量别崩"的工具脚本更合适（推测设计意图）
	if terrain_path != NodePath():
		return get_node_or_null(terrain_path) as Terrain3D
	# 自动查找的起点：优先用 current_scene，保证"从整棵场景树里找"；
	# 但 headless 工具脚本 / 节点还没入树时 current_scene 可能为 null，此时退化成"从自己往下找" ✓
	var root: Node = null
	if get_tree() != null:
		root = get_tree().current_scene
	if root == null:
		root = self
	return _find_terrain_in(root)


## 递归（深度优先、前序遍历）在子树里找第一个 Terrain3D。
## 参数 n：从哪个节点开始找（**包含 n 自己**）。
## 返回：找到的 Terrain3D；整棵子树都没有就返回 null（不会抛错）。
## 副作用：无（纯遍历，不改场景树）。
## 调用时机：仅由 get_terrain() 在"未显式指定 terrain_path"时调用。
## 注意：
##   · 返回的是**第一个被访问到**的 Terrain3D：先看自己，再按子节点顺序走整棵子树 ——
##     所以场景里有多棵时，命中的是"先序最左"那棵，与"离玩家最近/最大那棵"没有任何关系；
##   · 不筛节点类型也不筛碰撞层，Terrain3D 藏在 UI 或其它 Node 下面同样能被找到；
##   · 场景树是无环树，不会无限递归；大场景每次调用都要遍历一遍，但本文件只在启动/切档时
##     调用（且 get_terrain 不缓存），开销可忽略。
func _find_terrain_in(n: Node) -> Terrain3D:
	# 先判断自己（前序）：保证父节点优先于子节点被命中
	if n is Terrain3D:
		return n as Terrain3D
	for c in n.get_children():
		var r := _find_terrain_in(c)
		# 第一个非空结果就是最终答案，立即剪枝返回：找到就停，不做无用的后续遍历 ✓
		if r != null:
			return r
	return null


# ==================== 段四：档位查询与对外应用接口 ====================

## 解析"当前真正生效"的档位。
## 参数：无。
## 返回：int（QualityTiers.Tier 语义）。跟随全局时为 QualityManager.instance.tier
##   （管理器 set_tier/load_tier 都做过 clampi，必在 0~3）；否则为本地导出 tier
##   （可能被手填成越界值，此时 get_preset 回退 MEDIUM，不会崩）。
## 副作用：无（纯读，不改任何状态）。
## 优先级：follow_quality == true 且 instance != null → 全局档位；其余情况 → 本地 tier。
## 注意：返回的是"当前值"而非"上次已应用的值"。若中途有别的代码改了管理器档位而本节点
##   没收到信号（例如订阅失败），反复调用 apply_current() 会来回跳档；正常有信号时不会出现。
func current_tier() -> int:
	if follow_quality and QualityManager.instance != null:
		return QualityManager.instance.tier
	return tier


## 按"当前生效档位"（current_tier()）应用一次地表贴图与地形 LOD。
## 参数：无。
## 返回：apply_tier() 的统计字典（字段含义见 apply_tier / apply_on_assets 的说明）。
## 副作用：同 apply_tier —— 改写贴图资产与（apply_lod 为真时的）地形 LOD 参数，并打印日志。
## 调用时机：_ready 启动对齐、手动调参、单元测试入口；"跟随全局档位"的常规用法都用它。
## 与 apply_tier(t) 的区别：本函数自己解析档位，适合懒得多想"现在到底是哪一档"的场合。
## 应用当前档位，返回统计结果（便于日志/测试）
func apply_current() -> Dictionary:
	return apply_tier(current_tier())


## 按指定档位应用一次：换贴图（委托 apply_on_assets）+ 同步地形 LOD 参数。
## 参数 t：档位枚举值（QualityTiers.Tier，期望 0~3）。越界不会崩：
##   get_preset 取不到会回退 MEDIUM 预设，但贴图后缀会走 texture_for_tier 里的默认 "4k"。
## 返回：统计字典。
##   · 找不到 Terrain3D → {"ok": false, "message": "没找到 Terrain3D 节点"}（此路径不打印日志）；
##   · 正常 → apply_on_assets 的结果（见其文档）+ 追加 "tier_name" 字段（中文档位名）。
## 副作用：
##   · 改写 texture_list 中每个贴图资产的 albedo_texture / normal_texture 引用（内存中的资源对象）；
##   · apply_lod 为真时改写 terrain.mesh_size 以及每个 MeshAsset 的 lod0_range；
##   · 成功路径一定会 print 一行 "[画质] 地表贴图已按「…」应用：{…}"。
## 调用时机：_on_tier_changed（玩家/代码切档）与 apply_current（启动对齐）。
## 注意：
##   · terrain.assets 可能为 null（Terrain3D 还没配资产）：apply_on_assets 已判空并返回 ok=false，
##     本函数随后仍会走 LOD 分支，但 mesh_list 用 [] 兜底，所以不会空引用崩溃 ✓；
##   · 先换贴图、后改 LOD 的顺序不影响最终结果；失败原因靠返回字典的 ok/message 判断；
##   · print 是给日志排查用的（@tool 脚本在编辑器里也会打印），正式发布若嫌吵可自行去掉。
func apply_tier(t: int) -> Dictionary:
	var terrain := get_terrain()
	if terrain == null:
		# 提前返回而不是 push_error：没有地表的场景（纯 UI 测试、菜单场景）属正常情况，
		# 不该往控制台刷红字；调用方靠返回字典的 ok=false 自行判断 ✓
		return {"ok": false, "message": "没找到 Terrain3D 节点"}
	# 预设表是"档位 → 一组参数"的唯一真源（quality_tiers.gd）；这里只读、不写回，
	# 所以"改档位数值"只需要动 QualityTiers，本文件无需跟着改 ✓
	var preset := QualityTiers.get_preset(t)
	# 贴图替换逻辑全部交给这个纯逻辑静态函数：可以脱离场景/节点直接单测 ✓
	var res := apply_on_assets(terrain.assets, t)
	# LOD 与贴图分开开关（apply_lod）：想单独观察"贴图分级"的收益时把它关掉做对照 ✓
	if apply_lod:
		# Terrain3D.mesh_size：地形网格的单元尺寸（世界单位，默认 48）。
		# 调大 → 顶点更稀、绘制更省 GPU，但地形起伏变粗糙；调小 → 更精细、更吃性能。
		terrain.mesh_size = int(preset.get("terrain_mesh_size", 48))
		# assets 可能为 null：显式兜成空数组，避免下面直接取 .mesh_list 时空引用报错（GDScript 无 try）
		var mesh_list = terrain.assets.mesh_list if terrain.assets != null else []
		for m in mesh_list:
			var ma := m as Terrain3DMeshAsset
			# mesh_list 里可能混入非 Terrain3DMeshAsset（或空槽）：as 转换失败得 null，
			# 必须跳过，否则后面写 lod0_range 会报错 ✗
			if ma != null:
				# lod0_range：该 MeshAsset 使用最精细网格(LOD0)的距离阈值（米）。
				# 在此距离内用 LOD0，超出后逐级降 LOD；调大 → 远处也更精细、更耗性能。
				ma.lod0_range = float(preset.get("terrain_lod0_range", 128.0))
	# 统计结果里补一个可读的中文档位名，方便日志/测试断言
	res["tier_name"] = QualityTiers.tier_name(t)
	# 打印完整统计（changed/fallback/missing/inner…）：切档后一眼能看出这次到底动了几张图 ✓
	print("[画质] 地表贴图已按「%s」应用：%s" % [res["tier_name"], res])
	return res


# ==================== 段五：纯逻辑核心（逐资产替换贴图，可单测） ====================

## 【文档补充】参数 / 返回值 / 副作用 / 调用时机
## 参数 assets：Terrain3DAssets，通常来自 terrain.assets；为 null 时直接返回 ok=false，不抛错。
## 参数 t：档位枚举值（QualityTiers.Tier，0~3）。
## 返回：统计字典
##   · ok      ：false 表示 assets 为空（唯一失败原因）
##   · tier    ：放进来的 t 原样回传，便于日志/断言
##   · changed ：真正替换成功（load 到 Texture2D 并 set 上去）的通道数
##   · fallback：本档贴图不存在、但退到了更低档可用路径的次数
##   · missing ：本档及所有更低档都不存在、最终只能沿用原路径的次数
##   · inner   ：resource_path 为空或非 res:// 的**内嵌/外部**贴图，被主动跳过的通道数
##   · skipped ：保留字段，当前恒为 0（代码里从未赋值，改动时勿误以为它在统计"被跳过"）
##   · message ：仅 assets 为空时出现
## 副作用：直接改写 Terrain3DTextureAsset 的 albedo_texture / normal_texture 属性（内存中的资源）。
##   本函数自身不做任何磁盘写入；但在编辑器里（apply_in_editor = true）这些资源会被标脏，
##   注意别顺手保存场景，否则当前档位的贴图路径就被"烤"进文件了 ✗（见文件头与 apply_in_editor）。
## 调用时机：apply_tier() 内部调用；因为是 static，也可由单元测试直接构造 assets 调用 ✓。
## 性能注意：load() 是**同步**加载，第一次换档会一次性把本档贴图读进内存，可能卡一下；
##   之后再切回来走 ResourceLoader 缓存，通常就快了。
##
## ★ 纯逻辑（可单测）：把 Terrain3DAssets 里每个贴图资产的 albedo/normal 换成本档分辨率。
## 统计：changed=替换了几个 ｜ fallback=回退到更低档几个 ｜ missing=完全没有几个 ｜ skipped=跳过几个
##
## 特意做的一条防护：**resource_path 为空的内嵌贴图直接跳过** ——
## 碰它只会把大块图像数据留在场景里（曾把 main.tscn 撑到 102 MB）。
static func apply_on_assets(assets: Terrain3DAssets, t: int) -> Dictionary:
	var out := {"ok": true, "tier": t, "changed": 0, "fallback": 0, "missing": 0, "skipped": 0, "inner": 0}
	if assets == null:
		out["ok"] = false
		out["message"] = "assets 为空"
		return out
	# texture_list 里可能混入 null / 非贴图资产项：逐个 as 转换后判空跳过
	for a in assets.texture_list:
		var ta := a as Terrain3DTextureAsset
		# 转换失败得 null 就跳过这一项，不继续往下走（顺带覆盖 a 本身为 null 的情况）
		if ta == null:
			continue
		# 两个通道共用同一段逻辑，所以用数组循环而不是复制两份代码 —— 以后加通道只改这一行 ✓
		for prop in ["albedo_texture", "normal_texture"]:
			# 用反射式 get(prop) 读属性：两个通道共用一份代码；cur 是 Variant，必须显式判类型
			var cur = ta.get(prop)
			# 槽位是空的或类型不对（不是 Texture2D）时跳过：避免后面取 resource_path 出错 ✗
			if not (cur is Texture2D):
				continue
			# 只能靠磁盘上的资源路径判断"当前用的是哪一档"：图像数据本身无法回溯档位，
			# 所以 _1k / _2k / _4k 的命名规范是这套分级方案成立的前提（推测设计前提）
			var src := (cur as Texture2D).resource_path
			# 内嵌贴图（resource_path 为空）或路径不在 res:// 下：一律不碰 ——
			# 替换它等于把大块图像数据写进场景/资源文件，曾把 main.tscn 撑到 102 MB ✗
			if src == "" or not src.begins_with("res://"):
				out["inner"] = int(out["inner"]) + 1     # 内嵌贴图：不碰 ✓
				continue
			# want：本档"应该用"的路径；use：逐级回退后"实际能用"的路径（可能等于 src）
			var want := QualityTiers.texture_for_tier(src, t)
			var use := QualityTiers.resolve_existing(src, t)
			# 先用 exists 探路而不是直接 load：文件不存在时 load 会返回 null 并报错刷屏 ✓
			if not ResourceLoader.exists(want):
				if use == src:
					out["missing"] = int(out["missing"]) + 1
				else:
					out["fallback"] = int(out["fallback"]) + 1
			# 注意统计口径：missing/fallback 只在"本档路径不存在"时计数，
			# 且 missing 判定为 use 仍等于 src（即连更低档都没有，只能沿用原图）
			# use == src 有两种情况：①原图命名正好就是本档后缀（无需替换，天然幂等）；
			# ②本档与所有更低档都没有，只能沿用原路径。两种都不该再白 load 一次 ✓
			if use == src:
				continue
			# 同步 load：切档发生在信号回调里，需要立刻见效，所以这里不能 await ✓
			var tex := load(use)
			# 加载失败（文件损坏 / 没有导入产物）时拿到的不是 Texture2D：此时不写入，
			# 让资产保持原贴图，而不是被改成 null ✗
			if tex is Texture2D:
				ta.set(prop, tex)
				out["changed"] = int(out["changed"]) + 1
	return out
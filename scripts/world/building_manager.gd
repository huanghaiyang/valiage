## ============================================================================
## BuildingManager —— 建造系统（墙 / 塔 / 房屋 / 参天大树）的唯一入口
## ============================================================================
##
## 【职责】
##   把"几何参数"翻译成具体的 3D 建筑实例，并承包四件事：
##     1. 预制模型的加载与缓存（KayKit 城堡包、自制茅草屋、Tripo 树）
##     2. 尺寸校准：从模型 AABB 反推墙长 / 墙的长轴 / 塔底宽 / 房屋底宽
##     3. 碰撞体生成：正常模型用三角网，超高面数模型退回"包围盒圆柱"
##     4. 撤销历史栈与整体重建
##
## 【所属系统 / 场景挂载】
##   世界建造层。脚本挂在 scenes/main.tscn 的 Main/Buildings 节点上（class_name 使外部
##   可以直接当类型用）。它下面有两个约定子节点：
##     · Placed —— 所有运行时生成实例的父节点（成员 container）
##     · Layout —— 场景里手工摆的"布局描述件"，本身不出模型，只提供 meta 数据
##
## 【关键依赖】
##   · 上游调用：scripts/world/world_builder.gd 第 3 步 build_from_scene()（启动时重建聚落）；
##               scripts/main.gd（玩家放置工具、滚轮换变体、Ctrl+Z 撤销、半透明预览）
##   · 资源：res://assets/models/buildings/buildings/neutral/wall_straight.gltf
##           res://assets/models/buildings/buildings/red/building_tower_A_red.gltf
##           res://assets/models/buildings/buildings/red/building_home_A_red.gltf
##           res://assets/models/buildings/cottage/cottage.glb
##           res://assets/models/plants/autumn_tree_1.glb
##           res://assets/models/plants/craystal_red_tree.glb
##   · 物理层：本文件生成的静态体固定 collision_layer = 4（项目里约定为"建筑层"）、
##     collision_mask = 0。玩家 player.gd 的 collision_mask = 2 | 4 | 8（地形 | 建筑 | 植被），
##     main.gd 的占位查询也用 mask = 4。改层号前先顺着这条链检查。
##   · 不依赖任何 autoload，也不定义自定义信号：本脚本只被动被调用，不主动通知别人。
##
## 【主要对外接口】
##   放置：add_wall / add_tower / add_house / add_tree / add_gable_roof（旧接口，内部转 add_house）
##   变体：house_variant_count/name/id/base_scale/scene_at、cycle_house_variant、set_house_variant
##         tree_variant_count/name/base_scale/scene_at、cycle_tree_variant、set_tree_variant
##   历史：undo / clear_all / get_undo_count / build_from_scene / flush_all
##
## 【已知的坑与注意事项】
##   1. 历史栈只记"参数"，不记实例：撤销 = 清空 Placed 后按参数全量重放。任何新增的放置
##      类型都必须同步补进 _rebuild_from_history 的 match 分支，否则那类物件会被静默丢掉。
##   2. _rebuild_from_history 里实例必须先挂进**已入树**的临时容器再设 global_position，
##      否则 Godot 会报 !is_inside_tree()，所有墙段会被放到原点。
##   3. flush_all() 是空实现（no-op），保留只为兼容调用方（main.gd 每次 add_* 后都会调）。
##   4. 历史里的 yaw 若为 -1（未指定朝向），重建时会重新随机，所以撤销重放后朝向可能变化；
##      而 variant 在下游 add_* 里已被解析成确定下标，重放是稳定的。
##   5. _shape_cache / _house_cache / _tree_cache 都是进程内缓存，**不随场景切换失效**。
##   6. MAX_TRIMESH_VERTICES 是防卡死的硬闸门，别为提高碰撞精度随手调大（见该常量处注释）。
##   7. 变体表下标是对外协议：vegetation.gd 的树表顺序必须与 TREE_MODELS 完全一致，
##      否则会出现"滚轮显示 A、种下 B"。
class_name BuildingManager
extends Node3D
## 搭建管理器：KayKit Medieval Hexagon Pack 预制模型（CC0）
## 墙 → wall_straight 模型沿路径拼接；塔 → building_tower_A；屋顶工具 → 放置房屋模型
## 支持撤销（历史重建）；所有建筑带静态碰撞体（层4），阻止玩家穿入

# ==================== 成员变量：模型场景引用与内部状态 ====================
## 所有生成实例的父节点。_ready 时解析场景里的 "Placed" 子节点；缺失则兜底新建一个
## 同名 Node3D（保证后续 add_* 不会空引用）。
## 注意：撤销/重建会清空它下面的全部子节点（见 _clear_all），外部不要长期持有这些实例引用。
var container: Node3D
## 城墙段模型（wall_straight.gltf）。_place_wall 会沿路径反复实例化它。
## 路径写死在 _ready 里；文件缺失时 load() 返回 null，此时所有 add_wall 都会安全地提前
## return（不崩，但也静默没有任何墙），排查"点了墙没反应"时先看这里是否为 null。
var wall_scene: PackedScene
## 塔模型（building_tower_A_red.gltf）。塔的**高度由模型自身决定**，
## add_tower 传入的 height 参数是被忽略的占位形参（见 add_tower 的 _height）。
var tower_scene: PackedScene
## "当前"房屋场景，_ready 里同步为 house_scene_at(0)，只服务 _calibrate_sizes 与旧引用。
## 它**不会**跟着滚轮变化（cycle_house_variant 只改 house_variant）。要按变体取场景请用
## house_scene_at()。main.gd 的预览走的就是 house_scene_at()。（推测：本字段是"早期只有
## 一套房屋"时期的遗留引用。）
var house_scene: PackedScene

# ==================== 内部状态：撤销历史 / 形状缓存 / 随机源 ====================
## 建造历史栈：每个元素是一次放置操作的**参数快照**。
## 键名约定（必须与 _rebuild_from_history 的 match 分支严格对应）：
##   wall  → {"type","a":Vector3,"b":Vector3}
##   tower → {"type","c":Vector3,"r":float,"y":float}
##   house → {"type","p":Vector3,"s":float,"y":float,"v":int}
##   tree  → {"type","p":Vector3,"s":float,"y":float,"v":int}
## 只增不减（undo 是 pop_back 后全量重建）；build_from_scene() 会先 clear() 再写入场景件。
var _undo_stack: Array[Dictionary] = []
## 碰撞形状缓存（键 = 场景 resource_path）。同类模型只算一次形状，之后每个实例都复用同一个
## Shape3D 资源——本项目最大的模型（水晶树 99 万顶点）重算一次就是几十秒，不缓存没法用。
## 注意：缓存里的 Shape3D 是**多个 StaticBody3D 共享**的，只读共享安全，但别在别处改它。
var _shape_cache: Dictionary = {}   # 场景路径 -> {shape, pos}（同类模型共享；见 _make_collision_shape）
## 随机朝向专用随机源：只在 yaw < 0（调用方未指定朝向）时用 randf_range(0.0, TAU) 取值，
## 被 add_tower / add_tree / add_house 共用。用独立实例而不是全局 randf()，是为了让
## "随机朝向"的消耗不影响别处使用全局随机序列的代码。
var _rng := RandomNumberGenerator.new()

# ==================== 模型尺寸校准（运行时从 AABB 读取） ====================
# 模型尺寸校准（运行时从 AABB 读取）
## 墙段模型沿其"长边"方向的长度（米），由 _calibrate_sizes 从 AABB 读出后覆盖初值。
## 用途：_place_wall 用 round(seg / _wall_len) 算出"一段墙要摆几个模型"：
## 它偏小 → 墙段互相重叠；偏大 → 墙段之间留缝。初值 3.0 只是模型缺失时的兜底。
var _wall_len := 3.0
## 模型长边沿哪个轴（"x" 或 "z"），由 _calibrate_sizes 按 AABB 里 x/z 谁长来决定。
## 唯一用途是给 _place_wall 选 yaw 公式（两套资源里长边的朝向不同），所以**不要手工改**，
## 改了会出现"墙横着摆"。它与 _wall_len 都只在本文件内使用，main.gd 不读它们。
var _wall_axis := "z"      # 模型长边沿哪个轴（x 或 z）
## 塔模型的底部宽度（米，= AABB 的 max(x, z)），由 _calibrate_sizes 量得。
## add_tower 用它反算缩放：scale = max(0.35, radius * 2 / _tower_base)，
## 即"让塔底直径≈外界给的 2*radius"。main.gd 的预览与占位判定也读这个值，
## 所以改它必须同步看 main.gd（那里直接访问了这个私有成员）。
var _tower_base := 2.2     # 塔底部宽度（模型实际尺度）
## 当前房屋模型的占地长边（米，= AABB 的 max(x, z)），由 _calibrate_sizes（_ready 时）
## 与 _recalibrate_house（换变体时）覆盖。
## 唯一消费者是旧接口 add_gable_roof（用它把"想要的宽度"换算成 scale），新代码请用
## house_base_scale()，别依赖这个会被校准覆盖的值。
var _house_base := 3.6     # 房屋底部长边

# ==================== 缩放常量：把预制模型补到与角色匹配的尺度 ====================
# 预制模型原始尺寸偏小（房子 ~0.93m 高、墙 ~1.1m 高），需放大到与 1.35m 角色匹配的尺度
## 房屋的**默认**基准放大倍数（KayKit 玩具尺寸那套；按真实米数建的茅草屋在表里用 1.0）。
## 这个值是"模型尺寸 → 游戏尺寸"的乘数，不是最终 scale：最终 = max(0.4, 传入 scale) × 本倍数。
## 调大 → 房子更高更占地（也会把玩家挡得更死）；调小 → 变成一栋矮棚。
## 注意：它同时是 house_base_scale() 越界时的兜底返回值。
const HOUSE_BASE_SCALE := 3.5   # 房子放大到 ~3.2m 高（约 2.4 倍角色高）
## 墙段的 Y 轴拉伸倍数：墙模型原生约 1.1m 高，×1.8 ≈ 2m，比角色（1.35m）略高。
## **只拉 Y，不拉 X/Z**：水平长度由 _wall_len 与拼接段数决定，动 X/Z 会让墙段之间出现缝或重叠。
## 副作用提醒：CollisionShape 挂在实例下，会跟着这个非等比缩放一起变形，所以碰撞与外观一致。
## 调大 → 墙变高（跳跃翻墙更难）；调小 → 矮到可以直接跨过去。
const WALL_HEIGHT_SCALE := 1.8  # 墙放大到 ~2m 高

# ==================== 生命周期 ====================
## _ready：初始化随机源 → 解析/兜底放置容器 → 加载三个内置模型 → 尺寸校准。
##
## 参数：无。返回值：无。
## 副作用：可能 add_child（新建 Placed 容器）；load() 三个资源；写 container / wall_scene /
##         tower_scene / house_scene / _wall_len / _wall_axis / _tower_base / _house_base；
##         校准阶段会临时 instantiate() 每个模型只为量 AABB，量完立即 free()（不进场景树）。
## 调用时机：进入场景树时由引擎调用，**早于** world_builder.build()，
##           因此 build_from_scene() 执行时 container 一定已经就绪。
## 注意：依赖场景结构 Main/Buildings/Placed；缺失时会兜底新建（保证后续 add_* 不空引用），
##       但那种情况下容器节点不属于场景，外部按名字 get_node 找不到它。
func _ready() -> void:
	_rng.randomize()
	# Placed 容器由场景声明（Main/Buildings/Placed）；缺失时兜底新建
	container = get_node_or_null("Placed")
	if container == null:
		container = Node3D.new()
		container.name = "Placed"
		add_child(container)
	wall_scene = load("res://assets/models/buildings/buildings/neutral/wall_straight.gltf")
	tower_scene = load("res://assets/models/buildings/buildings/red/building_tower_A_red.gltf")
	# 只把"第 0 套"存进这个旧字段：滚轮换变体不会更新它，所以它**不代表当前选择**；
	# 真正的按变体取场景一律走 house_scene_at()（main.gd 的预览就是这么做的）。
	house_scene = house_scene_at(0)      # 兼容旧引用（预览等处），默认第一套
	_calibrate_sizes()
	_recalibrate_house()

# ==================== 房屋变体：模型表 + 查询/切换接口 ====================
## 可以放的房屋（滚轮在"房屋"工具里切换）。
##
## `base` 是**模型自身尺寸 -> 游戏尺寸**的倍数，两套模型差别很大，所以必须逐项给：
##   * KayKit 那套是按玩具尺寸做的，要放大 3.5 倍（HOUSE_BASE_SCALE）
##   * 自制的茅草屋是**按真实米数建的**（占地 4.2x3.0m、脊高 3.45m），倍数只能是 1.0，
##     否则套上 3.5 会变成一栋十几米的房子
const HOUSE_MODELS := [
	{"id": "red_home", "name": "红顶小屋", "base": HOUSE_BASE_SCALE,
	 "path": "res://assets/models/buildings/buildings/red/building_home_A_red.gltf"},
	{"id": "cottage", "name": "茅草屋", "base": 1.0,
	 "path": "res://assets/models/buildings/cottage/cottage.glb"},
]
## 当前选中的房屋（对应 HOUSE_MODELS 下标）
var house_variant := 0
## 房屋场景缓存：path -> PackedScene（或 null 表示"文件缺失，已告警过"）。
## 用它避免每次放置都 load() 一遍；缺失也照样缓存 null，免得每次都去查文件系统 + 刷警告。
var _house_cache := {}


## 房屋变体数量。
## 参数：无。返回值：HOUSE_MODELS.size()（当前 2），表为空时为 0。
## 副作用：无。调用时机：UI 显示 "i/n"、滚轮越界判断、main.gd 批量摆放展示房。
func house_variant_count() -> int:
	return HOUSE_MODELS.size()


## 取某号房屋的显示名（中文，直接给 UI 用）。
## 参数 i：变体下标；**i < 0 表示"当前选中的变体"**（house_variant）——本文件里所有
##         house_*/tree_* 查询函数都遵循这个约定，方便"不传参就是当前那个"。
## 返回值：名字字符串；下标越界、或表项缺 name 键时返回 ""（不报错、不崩）。
## 副作用：无。
func house_variant_name(i: int = -1) -> String:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return ""
	return str((HOUSE_MODELS[idx] as Dictionary).get("name", ""))


## 取某号房屋的稳定 id（英文，适合当存档/配置/测试的键——别用中文 name 当键，改文案就废）。
## 参数 i：变体下标，< 0 表示当前选中。
## 返回值：id 字符串；越界或表项缺 id 时返回 ""。副作用：无。
func house_variant_id(i: int = -1) -> String:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return ""
	return str((HOUSE_MODELS[idx] as Dictionary).get("id", ""))


## 取某号房屋的"模型尺寸 → 游戏尺寸"基准倍数（HOUSE_MODELS[i].base）。
## 参数 i：变体下标，< 0 表示当前选中。
## 返回值：红顶小屋 3.5 / 茅草屋 1.0；**越界时兜底返回 HOUSE_BASE_SCALE（3.5）**，
##         注意不是 1.0——（推测）为了让越界的旧代码至少还能放出一个可见尺寸的房子。
## 副作用：无。调用时机：放置与预览换算 scale（main.gd 也直接调）。
func house_base_scale(i: int = -1) -> float:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return HOUSE_BASE_SCALE
	return float((HOUSE_MODELS[idx] as Dictionary).get("base", 1.0))


## 额外说明：**首次调用会 load() 并缓存**；文件不存在时缓存 null 并 push_warning 一次
##（不会反复刷告警）。path 为空（表项没写 path）时直接返回 null 且不缓存。
## 参数 i：变体下标，< 0 表示当前选中。
## 返回值：PackedScene；不可用时 null——调用方必须判空（_place_house 就是这么做的）。
## 副作用：读文件系统 + 写 _house_cache + 可能 push_warning。
## 取某号房屋的场景（带缓存）。返回 null 表示文件缺失。
func house_scene_at(i: int = -1) -> PackedScene:
	var idx := house_variant if i < 0 else i
	if idx < 0 or idx >= HOUSE_MODELS.size():
		return null
	var path := str((HOUSE_MODELS[idx] as Dictionary).get("path", ""))
	if path.is_empty():
		return null
	if not _house_cache.has(path):
		_house_cache[path] = load(path) if ResourceLoader.exists(path) else null
		if _house_cache[path] == null:
			push_warning("BuildingManager: 房屋模型缺失 %s" % path)
	return _house_cache[path] as PackedScene


## 参数 dir：步进，+1 下一套 / -1 上一套；可传任意整数，内部用 posmod 环绕，不会越界。
## 返回值：切换后的下标（= house_variant）。表为空（n == 0）时不做任何事并原样返回。
## 副作用：写 house_variant；调用 _recalibrate_house()（会实例化模型量 AABB，有少量开销，
##         但只在滚轮切换时发生，不在每帧路径上）。
## 调用时机：main.gd 的房屋工具滚轮分支。注意它**只改选择**，不会重摆已有房屋。
## 切换房屋变体（滚轮）；返回切换后的下标
func cycle_house_variant(dir: int) -> int:
	var n := house_variant_count()
	if n > 0:
		house_variant = posmod(house_variant + dir, n)
		_recalibrate_house()
	return house_variant


## 直接指定房屋变体（给 UI 选中项/读档恢复用）。
## 参数 i：目标下标；越界（< 0 或 >= 数量）时**静默忽略**——不报错、不环绕、也不改现状。
## 返回值：无。副作用：写 house_variant + _recalibrate_house()。
## 注意：与 cycle_house_variant 的差别就在"不环绕"，调用前自己保证下标合法。
func set_house_variant(i: int) -> void:
	if i >= 0 and i < house_variant_count():
		house_variant = i
		_recalibrate_house()


## 参数：无（内部按当前变体调 house_scene_at()）。返回值：无。
## 副作用：写 _house_base；会临时 instantiate() 一份当前房屋模型，只读 AABB 的
##         max(x, z) 当占地长边，然后立刻 free()（**不留在场景里、也不加碰撞**）。
## 调用时机：_ready 末尾、cycle_house_variant、set_house_variant。
## 注意：模型缺失（scene == null）时直接 return；模型在但找不到网格时也只是跳过赋值
##       （临时实例仍会被 free）。两种情况 _house_base 都保留旧值，
##       此时旧接口 add_gable_roof 的宽度换算会按旧尺寸偏掉。
## 当前房屋的占地尺寸（供旧的 add_gable_roof 用）
func _recalibrate_house() -> void:
	var sc := house_scene_at()
	if sc == null:
		return
	var inst := sc.instantiate()
	var mi := _find_mesh_instance(inst)
	if mi != null and mi.mesh != null:
		var sz: Vector3 = mi.mesh.get_aabb().size
		_house_base = maxf(sz.x, sz.z)
	inst.free()


# ==================== 尺寸校准与实例化工具 ====================
## 从模型 AABB 反推物理尺寸：墙长与墙的长轴方向、塔底宽、房屋底宽。
## 参数：无。返回值：无。
## 副作用：写 _wall_len / _wall_axis / _tower_base / _house_base；每个模型都会
##         instantiate() 一份仅用于量尺寸，量完 free()（不进场景树、不加碰撞）。
## 调用时机：_ready 里，紧随模型加载之后（此时三个 scene 变量已就绪）。
## 为什么要在运行时量而不是写死数字：资源一旦换皮/重新导出，尺寸就变了；写死会让
## 墙段之间出现缝或重叠。在这里量一次，换模型能自动跟上。
## 注意：每个模型只量**深度优先遇到的第一个 MeshInstance3D**（见 _find_mesh_instance），
##       多网格模型（例如塔含锥顶）量到的是哪一个取决于子节点顺序，属已知近似。
func _calibrate_sizes() -> void:
	if wall_scene != null:
		var wall_inst := wall_scene.instantiate()
		var wmi := _find_mesh_instance(wall_inst)
		if wmi != null and wmi.mesh != null:
			var ws: Vector3 = wmi.mesh.get_aabb().size
			if ws.x >= ws.z:
				_wall_len = ws.x
				_wall_axis = "x"
			else:
				_wall_len = ws.z
				_wall_axis = "z"
		wall_inst.free()
	if tower_scene != null:
		var t_inst := tower_scene.instantiate()
		var tmi := _find_mesh_instance(t_inst)
		if tmi != null and tmi.mesh != null:
			_tower_base = maxf(tmi.mesh.get_aabb().size.x, tmi.mesh.get_aabb().size.z)
		t_inst.free()
	if house_scene != null:
		var h_inst := house_scene.instantiate()
		var hmi := _find_mesh_instance(h_inst)
		if hmi != null and hmi.mesh != null:
			_house_base = maxf(hmi.mesh.get_aabb().size.x, hmi.mesh.get_aabb().size.z)
		h_inst.free()

## 深度优先找出子树里第一个 MeshInstance3D（顺序 = get_children() 的自然顺序）。
## 参数 node：任意 Node（是 MeshInstance3D 自身时直接返回它）。
## 返回值：找到的 MeshInstance3D；整棵子树都没有则 null。
## 副作用：无（纯递归查找）。注意它**不缓存**，别放到每帧路径上反复调用。
func _find_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var r := _find_mesh_instance(c)
		if r != null:
			return r
	return null

## 实例化一个场景并挂到目标父节点下。
## 参数 scene：要实例化的 PackedScene，为 null 时返回 null（调用方必须判空）；
##       target：父节点，null = 挂到默认容器 container（Main/Buildings/Placed）；
##               重建流程会传临时容器，好让实例在树里算完坐标再整体搬家。
## 返回值：新实例（Node3D）。副作用：改场景树（add_child）。
## 注意：add_child 之后实例的 global_position / global_transform 才有意义，
##       所以本函数只负责"挂上去"，位置/缩放/朝向由调用方随后设置。
func _instantiate(scene: PackedScene, target: Node3D = null) -> Node3D:
	if scene == null:
		return null
	var inst := scene.instantiate()
	(target if target != null else container).add_child(inst)
	return inst

# ==================== 碰撞体生成（正常三角网 / 高模退回圆柱） ====================
## 超过这个顶点数就不做三角网碰撞，改用"包围盒圆柱"。
## 调大 → 更多高模会走耗时的 get_faces() 路径（可能卡主线程几十秒 + 上百 MB 临时内存）；
## 调小 → 一些中等模型也退化成圆柱（碰撞变粗糙，但绝不会卡）。普通石墙/房屋远低于此值。
## 例：新加的水晶树是 **1.8M 面 / 99 万顶点** —— `get_faces()` 要吐出 547 万个 Vector3，
## 再在 GDScript 里逐点 append，实测会把主线程卡几十秒、吃掉上百 MB；而且这个 shape
## 是同类模型**共享**的，物理里还要按它建 BVH。退回圆柱够挡住角色，代价几乎为零。
const MAX_TRIMESH_VERTICES := 30000

## 参数 inst：已挂进场景树、且 transform 已经设好的建筑实例（本函数要用它的子节点算形状）；
##       scene：它的源 PackedScene——**只用作 _shape_cache 的键**，不会重新实例化。
## 返回值：无。失败（scene/inst 为空，或算不出形状）时静默返回，实例就没有碰撞体。
## 副作用：改场景树（给 inst 加一个 StaticBody3D + CollisionShape3D）、写 _shape_cache。
## 调用时机：每次放置墙段 / 塔 / 房屋 / 树之后（_place_* 内部调用）。
## 注意：
##   · shape 与 pos 都在**模型本地空间**：CollisionShape3D 挂在 inst 下，inst 的
##     position/scale/rotation 会自动作用到它身上，所以墙的非等比 Y 拉伸也如实反映到碰撞。
##   · 同类模型共享同一个 Shape3D 资源（可能被多个 StaticBody3D 引用）——只读共享是安全的。
##   · collision_mask = 0：这些静态体只被别人"撞到"，自己不去检测任何东西。
## 给建筑实例加碰撞体。
## 正常模型：三角网（ConcavePolygonShape3D，贴合外形，多部件全覆盖）。
## 超高面数模型：退回"包围盒圆柱"（见 MAX_TRIMESH_VERTICES）。
## shape 顶点在模型本地空间，随 inst 的 scale/rotation 一起变换；同类场景共享同一份。
func _add_mesh_collision(inst: Node3D, scene: PackedScene) -> void:
	if scene == null or inst == null:
		return
	var entry: Dictionary = _shape_cache.get(scene.resource_path, {})
	if entry.is_empty():
		entry = _make_collision_shape(inst)
		if entry.is_empty():
			return
		_shape_cache[scene.resource_path] = entry
	# 层 4 = 项目约定的"建筑层"：玩家 collision_mask = 2|4|8 里含 4，所以墙/塔/屋能挡住角色；
	# mask = 0 表示这些静态体不主动检测任何东西（省物理开销）
	var sb := StaticBody3D.new()
	sb.collision_layer = 4
	sb.collision_mask = 0
	var col := CollisionShape3D.new()
	col.shape = entry["shape"]
	col.position = entry["pos"]
	sb.add_child(col)
	inst.add_child(sb)


## 参数 inst：模型实例（必须在树里、transform 已定，但本函数只读它的网格数据与子节点变换）。
## 返回值：高模 → {"shape": CylinderShape3D, "pos": 包围盒中心}；
##         普通模型 → {"shape": ConcavePolygonShape3D, "pos": Vector3.ZERO}；
##         一个网格都没收集到 → {} （调用方会据此放弃加碰撞体）。
## 副作用：无（纯计算；缓存与挂载由 _add_mesh_collision 负责）。
## 注意：判定用**顶点数**而不是面数——surface_get_array_len() 是 O(1)，不需要展开索引，
##       所以对高模做这个检查本身是毫秒级的，真正致命的是后面的 get_faces()。
## 决定一个模型实例用哪种碰撞形状。返回 {"shape": Shape3D, "pos": Vector3}；
## 顶点太多 → 圆柱（pos = 包围盒中心，否则圆柱会一半埋进地里）；否则三角网（pos = 原点）。
func _make_collision_shape(inst: Node3D) -> Dictionary:
	if _count_mesh_vertices(inst) > MAX_TRIMESH_VERTICES:
		var ab := _mesh_local_aabb(inst)
		var cyl := CylinderShape3D.new()
		# 半径取水平短边的一半：树/水晶这类竖高的模型只要挡住中轴就够
		cyl.radius = maxf(0.05, minf(ab.size.x, ab.size.z) * 0.5)
		cyl.height = maxf(0.1, ab.size.y)
		return {"shape": cyl, "pos": ab.get_center()}
	var faces := PackedVector3Array()
	# 从 inst 收集但不乘 inst 自身 transform（shape 挂 inst 下，inst 的 scale/rotation 会整体作用）
	_collect_mesh_faces(inst, Transform3D.IDENTITY, faces, false)
	if faces.is_empty():
		return {}
	# 三角网凹凸形：贴合外形（塔身、屋顶斜面都能站上去），代价是顶点多时物理内存/建 BVH 更贵
	var tri := ConcavePolygonShape3D.new()
	tri.set_faces(faces)
	return {"shape": tri, "pos": Vector3.ZERO}


## 参数 n：任意节点，会递归它**所有**子节点（不限 Node3D）。
## 返回值：顶点总数（各 surface 的 surface_get_array_len 之和）。
## 副作用：无。调用时机：_make_collision_shape 的第一道闸门，必须先于 get_faces() 执行。
## 统计实例内所有 MeshInstance 的顶点数。
## 只读 surface_get_array_len，**不**调用 get_faces()，所以对高模也是毫秒级。
func _count_mesh_vertices(n: Node) -> int:
	var total := 0
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var m := (n as MeshInstance3D).mesh
		for i in m.get_surface_count():
			total += m.surface_get_array_len(i)
	for c in n.get_children():
		total += _count_mesh_vertices(c)
	return total


## 参数 root：模型实例的根节点。返回值：合并后的 AABB；子树里没有网格时返回 AABB()（size 全 0）。
## 副作用：无。调用时机：_make_collision_shape 判定为高模后，用它算圆柱的半径/高度/中心。
## 实例内所有网格的本地 AABB 并集（不乘根节点自身 transform，与 _collect_mesh_faces 一致）
func _mesh_local_aabb(root: Node3D) -> AABB:
	var boxes: Array[AABB] = []
	_collect_mesh_aabbs(root, Transform3D.IDENTITY, false, boxes)
	if boxes.is_empty():
		return AABB()
	var out := boxes[0]
	for i in range(1, boxes.size()):
		out = out.merge(boxes[i])
	return out


## 递归收集子树里每个 MeshInstance3D 的 AABB，并按累积变换转到 root 的本地空间。
## 参数 n：当前节点；xform：父级累积变换；
##       include_self：是否把 n 自身的 transform 计入——根节点传 false，
##                     因为结果要在 root 本地空间里被使用（root 的变换由挂载方施加）；
##       out：结果数组（**追加**，调用方先清空/新建）。
## 返回值：无（结果写在 out）。副作用：无。
## 注意：只递归 Node3D 子节点（非 3D 节点没有可用 transform）；必须传 Node3D，
##       与本文件另一处 _collect_mesh_faces 的分支保持一致。
func _collect_mesh_aabbs(n: Node3D, xform: Transform3D, include_self: bool, out: Array[AABB]) -> void:
	var t: Transform3D = xform * (n.transform if include_self else Transform3D.IDENTITY)
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		out.append(t * (n as MeshInstance3D).mesh.get_aabb())
	for c in n.get_children():
		if c is Node3D:
			_collect_mesh_aabbs(c as Node3D, t, true, out)

## 参数 n：当前节点；xform：父级累积变换；out：输出顶点数组（按三角形连续排列，每 3 个一组）；
##       include_self：同 _collect_mesh_aabbs，根节点传 false，避免把根自身缩放重复计入。
## 返回值：无。副作用：无，但**高模下极慢且极耗内存**——只允许在
##       _make_collision_shape 通过 MAX_TRIMESH_VERTICES 顶点数检查之后调用。
## 递归收集场景内所有 MeshInstance3D 的三角面顶点，按节点 transform 链式变换到根空间
## include_self 为 false 时跳过根节点自身 transform（shape 挂根节点下随根 transform 整体变换）
func _collect_mesh_faces(n: Node3D, xform: Transform3D, out: PackedVector3Array, include_self: bool = true) -> void:
	var t: Transform3D = xform * (n.transform if include_self else Transform3D.IDENTITY)
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mf := (n as MeshInstance3D).mesh.get_faces()
		for v in mf:
			out.append(t * v)
	for c in n.get_children():
		if c is Node3D:
			_collect_mesh_faces(c as Node3D, t, out, true)

# ==================== 建造入口：墙 / 塔 ====================
## 参数 a / b：墙的两个端点（世界空间；通常来自地面射线落点，y 就是地面高度）；
##       _height / _thickness：**保持调用方签名兼容的占位参数，当前实现完全忽略**
##                             （下划线前缀即"有意不用"的约定）；
##       _crenellated：城垛开关，同样没有实现（占位）。
## 返回值：无。
## 副作用：在 container 下生成若干墙段实例（每个都带静态碰撞体）；_undo_stack 追加 1 条记录。
## 调用时机：main.gd 的 WALL 工具松开左键时（_end_tool），且那里已先判过两端距离 > 0.5m。
## 注意：
##   · 历史记录里只有 a / b，**没有 yaw**——重建时朝向由 a→b 方向与 _wall_axis 重新算出，
##     所以墙的重放是确定性的（不像塔/房屋那样可能重新随机）；
##   · 一条历史可能对应十几个墙段实例（见 _place_wall 的段数），撤销是整条一起消失。
## 添加一段墙：沿 a→b 路径按模型长度拼接多个墙段
func add_wall(a: Vector3, b: Vector3, _height: float, _thickness: float, _crenellated := false) -> void:
	_place_wall(a, b)
	_undo_stack.append({"type": "wall", "a": a, "b": b})

## 真正建墙的内部实现（**不写历史**，供 add_wall 与重建流程共用）。
## 参数 a / b：端点；target：父节点，null = container（重建时传临时容器，好让坐标计算在树内进行）。
## 返回值：无。副作用：改场景树（每段都 add_child + 加静态碰撞体）。
## 注意：本函数内**不消耗 _rng**，因此重建得到的墙与原始完全一致。
func _place_wall(a: Vector3, b: Vector3, target: Node3D = null) -> void:
	var seg := a.distance_to(b)
	# 距离不足半个单位就直接放弃：硬拼出来的"墙"会叠成一坨，比不建更难看
	if seg < 0.5:
		return
	var dir := (b - a) / seg
	var yaw := 0.0
	# 两套资源的"长边"分别沿 x / z，朝向公式必须跟着换：atan2 的两个参数顺序互换，
	# 否则墙就会整体横过来（这正是 _wall_axis 存在的唯一理由）
	if _wall_axis == "x":
		yaw = atan2(-dir.z, dir.x)
	else:
		yaw = atan2(dir.x, dir.z)
	# 段数 = 路径长 / 模型长，四舍五入且至少 1 段：这样每段的实际步长最接近模型自身长度，
# 段间误差（轻微重叠或细缝）最小；如果改用 floor/ceil，长短笔画会有一端对不齐
	var n := maxi(1, int(round(seg / _wall_len)))
	for i in n:
		# 第 i 段位置按比例插值（而不是按模型长度累加）：保证首尾段一定落在 a 与 b 上，
		# 误差被均匀摊到段与段之间，不会在远端累积
		var p := a + dir * (seg * float(i) / float(n))
		var inst := _instantiate(wall_scene, target)
		if inst == null:
			return
		inst.global_position = Vector3(p.x, p.y, p.z)
		# 只在 Y 轴上拉伸：X/Z 保持 1.0，让水平长度仍由模型本身与拼接段数决定
		# （水平方向一拉，相邻墙段就会互相插进对方或露出缝）
		inst.scale = Vector3(1.0, WALL_HEIGHT_SCALE, 1.0)
		inst.rotation = Vector3(0, yaw, 0)
		_add_mesh_collision(inst, wall_scene)

## 参数 center：塔底中心（世界空间）；
##       radius：**期望的塔底半径**（不是缩放倍数），用来反算 scale；
##       _height：占位参数（被忽略，塔高由模型自身决定——这是刻意保留的签名兼容）；
##       _with_roof：占位参数（当前塔模型自带锥顶，无需额外加顶）；
##       yaw：朝向（弧度）；**< 0 表示随机**（_rng.randf_range(0.0, TAU)）。
## 返回值：无。
## 副作用：生成 1 个塔实例（带三角网碰撞）+ _undo_stack 追加 1 条 {"c","r","y"}。
## 注意：
##   · scale = max(0.35, radius*2 / _tower_base)，0.35 是下限：radius 传 0 或负数时塔
##     不会缩成一个不可见的点（约 0.385 以下的 radius 都不再变小）；
##   · radius 是"塔底宽度的一半"，与 main.gd 里 tower_radius 的含义一致；
##   · yaw 的合法范围是 [0, TAU)，传负值一律被解释成"随机"，不能拿 -0.0001 表示"略微左转"。
## 添加一座塔（yaw>=0 指定朝向，-1 随机）
func add_tower(center: Vector3, radius: float, _height: float, _with_roof := true, yaw := -1.0) -> void:
	_place_tower(center, radius, yaw)
	_undo_stack.append({"type": "tower", "c": center, "r": radius, "y": yaw})

## 真正放塔的内部实现（**不写历史**，供 add_tower 与重建流程共用）。
## 参数 center / radius / yaw 含义同 add_tower；target：父节点，null = container。
## 返回值：无。副作用：改场景树；**当 yaw < 0 时会消耗一次 _rng**（随机朝向）。
## 注意：因为随机在这条路径上发生，"撤销后重放"的塔朝向可能与原来不同（历史里只存了 -1）。
func _place_tower(center: Vector3, radius: float, yaw: float, target: Node3D = null) -> void:
	var inst := _instantiate(tower_scene, target)
	if inst == null:
		return
	# 用"期望直径 / 模型底宽"反算缩放，使塔底直径≈2*radius；0.35 是下限，
	# 防止调用方传 radius=0 时把塔缩成一个看不见的点（此时碰撞体也同样几乎为零）
	var s := maxf(0.35, radius * 2.0 / _tower_base)
	inst.global_position = Vector3(center.x, center.y, center.z)
	inst.scale = Vector3.ONE * s
	inst.rotation = Vector3(0, yaw if yaw >= 0.0 else _rng.randf_range(0.0, TAU), 0)
	# 塔碰撞：模型三角网格多面体（含锥顶/塔身，角色可沿塔身形状交互）
	_add_mesh_collision(inst, tower_scene)

## 放置一栋房屋（对应原"屋顶"工具，改用预制小屋模型；yaw>=0 指定朝向，-1 随机）
# 注：紧邻上面那行 `## 放置一栋房屋…` 是**历史遗留的错位文档**——它描述的是
# add_house / _place_house，位置却落到了树木段落之前。按"只增不改"的约束没有搬动它；
# 下面这段才是参天大树的内容（add_house 处另有一份完整文档）。
# ==================== 参天大树（自制高模）：模型表与变体接口 ====================
## ---------------- 参天大树（自制） ----------------
##
## **为什么走这里而不是植被系统**：植被用 MultiMesh 摆，而 MultiMesh 一个实例
## 只渲染一个 surface —— 参天大树是"树皮 + 叶片(带 alpha)"两个材质的高精度模型，
## 放进 MultiMesh 必然串材质（实测：叶子先变成无贴图白片、再变成棕色木片）。
## 房屋那条路用真实节点摆放，多材质天然支持，所以树照抄房屋这条路。
## 参天大树模型表。Tripo3D 出的模型已用 `.runtime/trim_tripo_models.py`
## 切成"四份里的第一份"、脚底归零、缩放到真实米数（9.0m），所以 base = 1.0。
## 树木表：Tripo 出的"并排多份"已用 `.runtime/cut_tripo_parts.py` **逐份切成独立 glb**
## （秋树 4 份、水晶树 8 份），各自脚底归零、缩放到真实米数，所以 base 都是 1.0。
## 滚轮可以在这些变体之间切换。
const TREE_MODELS := [
	{"id": "red_maple", "name": "红枫树", "base": 1.0,
	 "path": "res://assets/models/plants/autumn_tree_1.glb"},
	# 红色水晶树（Tripo）：模型只有 0.98m 高，base 是"补到真实米数"的倍率 ——
	# 6.0 → 约 5.9m。要改大小就改这个数。
	# **注意它是 1.8M 面 / 99 万顶点的高模**：精度靠引擎的自动 LOD（游玩时按
	# Settings.mesh_lod_threshold 切换），碰撞由 _make_collision_shape 自动退回圆柱。
	{"id": "crystal_red", "name": "红色水晶树", "base": 6.0,
	 "path": "res://assets/models/plants/craystal_red_tree.glb"},]

## 当前选中的树变体下标（对应 TREE_MODELS）。由 cycle_tree_variant / set_tree_variant 改写，
## add_tree 在 variant < 0 时会读它。它**不参与**任何尺寸校准（树不需要量底宽）。
var tree_variant := 0
## 树的场景缓存：path -> PackedScene / null。与 _house_cache 同构，但**不 push_warning**
##（树模型缺失是静默的），所以"树工具点了没反应"时要自己来这里确认是不是 null。
var _tree_cache := {}


## 参天大树变体数量。
## 参数：无。返回值：TREE_MODELS.size()。副作用：无。
## 调用时机：main.gd 的 TREE 工具会先判它是否为 0——表空时整个树工具直接不生效
##（连周围植被都不回收，避免"草没了树也没种上"）。
func tree_variant_count() -> int:
	return TREE_MODELS.size()


## 取某号树的显示名（中文，给 UI 用）。
## 参数 i：变体下标，< 0 表示当前选中的 tree_variant。
## 返回值：名字；越界或表项缺 name 时返回 ""。副作用：无。
func tree_variant_name(i: int = -1) -> String:
	var idx := tree_variant if i < 0 else i
	if idx < 0 or idx >= TREE_MODELS.size():
		return ""
	return str((TREE_MODELS[idx] as Dictionary).get("name", ""))


## 取某号树的"模型尺寸 → 游戏尺寸"基准倍数（TREE_MODELS[i].base）。
## 参数 i：变体下标，< 0 表示当前选中。
## 返回值：倍数；**越界兜底返回 1.0**（与房屋版兜底 3.5 不同——树模型都已按真实米数导出，
##         1.0 才是"不缩放"的安全默认值）。
## 副作用：无。调用时机：add_tree / _place_tree 算最终 scale；main.gd 的树木预览也直接用。
func tree_base_scale(i: int = -1) -> float:
	var idx := tree_variant if i < 0 else i
	if idx < 0 or idx >= TREE_MODELS.size():
		return 1.0
	return float((TREE_MODELS[idx] as Dictionary).get("base", 1.0))


## 参数 i：变体下标，< 0 表示当前选中的 tree_variant。
## 返回值：PackedScene；下标越界 / path 为空 / 文件不存在时返回 null（调用方必须判空）。
## 副作用：首次调用会 load() 并写 _tree_cache；缺失时**静默**缓存 null（不 push_warning）。
## 取某号树的场景（带缓存）
func tree_scene_at(i: int = -1) -> PackedScene:
	var idx := tree_variant if i < 0 else i
	if idx < 0 or idx >= TREE_MODELS.size():
		return null
	var path := str((TREE_MODELS[idx] as Dictionary).get("path", ""))
	if path.is_empty():
		return null
	if not _tree_cache.has(path):
		_tree_cache[path] = load(path) if ResourceLoader.exists(path) else null
	return _tree_cache[path] as PackedScene


## 切换当前树的变体（鼠标滚轮）。
## 参数 dir：步进，默认 1（+1 / -1 都可，内部 posmod 环绕，不会越界）。
## 返回值：**无**（注意与 cycle_house_variant 不同——那个会返回新下标；这里要读 tree_variant）。
## 副作用：只写 tree_variant，不做任何尺寸校准、不重摆已有树。表为空时直接 return。
func cycle_tree_variant(dir: int = 1) -> void:
	if TREE_MODELS.is_empty():
		return
	tree_variant = posmod(tree_variant + dir, TREE_MODELS.size())


## 直接指定树的变体（给 UI 选中项/读档恢复用）。
## 参数 i：目标下标；越界时**静默忽略**（不环绕、不报错）。返回值：无。副作用：写 tree_variant。
func set_tree_variant(i: int) -> void:
	if i >= 0 and i < TREE_MODELS.size():
		tree_variant = i


# ==================== 放置实现：树 / 房屋（写历史 + 落场景） ====================
## 种一棵参天大树，并写入撤销历史。
## 参数 pos：树根位置（世界空间；模型脚底已归零，所以这里直接给地面高度即可）；
##       scale：额外倍率，默认 1.0，最终 scale = max(0.05, scale) × tree_base_scale(variant)
##              —— 笔刷种树时 main.gd 会在这里叠一点随机抖动；
##       yaw：朝向（弧度），**< 0 表示随机**；
##       variant：模型下标，**< 0 表示"用当前选中的 tree_variant"**。
## 返回值：无。
## 副作用：生成 1 个树实例（带碰撞）+ _undo_stack 追加 1 条；variant 会被解析成确定值再入栈。
## 注意：历史里存的是"解析后的变体号"，所以之后滚轮换变体不会改变已经种下的树；
##       而 yaw 若为 -1 则重建时会重新随机（朝向可能变）。
func add_tree(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> void:
	_place_tree(pos, scale, yaw, null, variant)
	_undo_stack.append({"type": "tree", "p": pos, "s": scale, "y": yaw,
			"v": tree_variant if variant < 0 else variant})


## 真正种树的内部实现（**不写历史**，供 add_tree 与重建流程共用）。
## 参数 pos / scale / yaw / variant 含义同 add_tree；target：父节点，null = container。
## 返回值：无。副作用：改场景树、加碰撞体；**yaw < 0 时消耗一次 _rng**（随机朝向）。
## 注意：scale 下限 0.05 是防"矩阵退化"——传 0 或负数会让模型缩放成零，渲染与物理都异常。
func _place_tree(pos: Vector3, scale: float, yaw: float, target: Node3D = null,
		variant: int = -1) -> void:
	var sc := tree_scene_at(variant)
	if sc == null:
		return
	var inst := _instantiate(sc, target)
	if inst == null:
		return
	inst.global_position = Vector3(pos.x, pos.y, pos.z)
	# 最终缩放 = 调用方倍率 × 该模型的基准倍数；0.05 下限防止矩阵退化（缩放为 0）
	inst.scale = Vector3.ONE * (maxf(0.05, scale) * tree_base_scale(variant))
	inst.rotation = Vector3(0, yaw if yaw >= 0.0 else _rng.randf_range(0.0, TAU), 0)
	# 树干碰撞：三角网格（树叶卡片也在里面，但角色撞上去就是"树"的感觉，
	# 而且可以顺着树干站上枝桠）
	_add_mesh_collision(inst, sc)


## 放置一栋房屋，并写入撤销历史（对应的就是 UI 上的 ROOF/"屋顶"工具）。
## 参数 pos：放置点（世界空间；模型底面已归零，所以给地面高度即可）；
##       scale：额外倍率，默认 1.0，最终 scale = max(0.4, scale) × house_base_scale(variant)
##              —— 注意下限是 0.4（比树的 0.05 大得多，因为房屋是主体建筑，缩成点没有意义）；
##       yaw：朝向（弧度），**< 0 表示随机**；
##       variant：模型下标，**< 0 表示"用当前选中的 house_variant"**。
## 返回值：无。
## 副作用：生成 1 个房屋实例（三角网碰撞，玩家可以跳上屋顶）+ _undo_stack 追加 1 条。
func add_house(pos: Vector3, scale := 1.0, yaw := -1.0, variant := -1) -> void:
	_place_house(pos, scale, yaw, null, variant)
	_undo_stack.append({"type": "house", "p": pos, "s": scale, "y": yaw,
			"v": house_variant if variant < 0 else variant})

## 真正放房屋的内部实现（**不写历史**，供 add_house / add_gable_roof / 重建流程共用）。
## 参数 pos / scale / yaw / variant 含义同 add_house；target：父节点，null = container。
## 返回值：无。副作用：改场景树、加碰撞体；yaw < 0 时消耗一次 _rng（随机朝向）。
## 注意：末尾的 `× house_base_scale(variant)` **不能省**——两套模型的"原生尺度"差 3.5 倍，
##       漏乘会得到一只玩具房或一栋十几米的巨屋。
func _place_house(pos: Vector3, scale: float, yaw: float, target: Node3D = null,
		variant: int = -1) -> void:
	var sc := house_scene_at(variant)
	if sc == null:
		return
	var inst := _instantiate(sc, target)
	if inst == null:
		return
	inst.global_position = Vector3(pos.x, pos.y, pos.z)
	# 每套模型自带基准缩放（玩具尺寸那套 3.5，按真实米数建的茅草屋 1.0）
	# 房屋：先按调用方倍率，再乘该变体自带的基准缩放（两套模型原生尺度差 3.5 倍），
	# 0.4 下限防止房屋被缩成一个点
	inst.scale = Vector3.ONE * (maxf(0.4, scale) * house_base_scale(variant))
	inst.rotation = Vector3(0, yaw if yaw >= 0.0 else _rng.randf_range(0.0, TAU), 0)
	# 房屋碰撞：模型三角网格多面体（含屋顶斜面，角色可跳到屋顶上）
	_add_mesh_collision(inst, sc)

# ==================== 旧接口兼容 / 刷新 / 撤销 ====================
## 参数 a / b：旧接口里屋顶的两个端点——当前实现只取**中点**当房屋位置，忽略方向；
##       width：期望宽度，用来反算 scale（max(0.8, width / _house_base)，0.8 是下限）；
##       _ridge_h / _eave_h：占位参数，被忽略（旧签名遗留）。
## 返回值：无。副作用：等同在 ab 中点调用 add_house(center, scale)（含历史入栈、随机朝向）。
## 注意：这是**旧接口**。它先用 _house_base 反算一次 scale，而 add_house 内部还会再乘一次
##       house_base_scale(variant)，两套换算叠加，所以得到的尺寸只保证"看着像房子"，
##       不要指望 width 精确等于实际占地宽度。新代码请直接用 add_house。
## 兼容旧接口（已改为放置房屋模型）
func add_gable_roof(a: Vector3, b: Vector3, width: float, _ridge_h: float, _eave_h: float) -> void:
	var center := (a + b) * 0.5
	var scale := maxf(0.8, width / _house_base)
	add_house(center, scale)

## 刷新接口（历史遗留）：**空实现（pass）**。
## 参数 / 返回值 / 副作用：全部没有。
## 调用时机：main.gd 每次 add_* 之后都会调，world_builder.build() 也调一次，
##           语义是"让刚放下的东西立刻生效"。
## 为什么可以空着：放置走的是即时 add_child，本来就立刻可见，不需要批量提交。
## 保留它是为了不改动所有调用方，同时给将来"延迟/批量构建"留一个统一挂点。
## 注意：别以为调了它才会出现——没调也一样会立刻出现（排查显示 Bug 时别被这行误导）。
func flush_all() -> void:
	pass

## 参数：无。返回值：true = 撤销成功；false = 栈本来就空（调用方据此决定要不要给 UI 反馈）。
## 副作用：pop_back() 掉最后一条历史，然后**全量重建** container 下的所有实例。
## 调用时机：Ctrl+Z（main.gd 的输入处理直连）与 UI 撤销按钮（main.gd 转发）。
## 注意：撤销粒度是"整条操作"而不是"一个实例"：
##   · 一次 add_wall 建的十几个墙段会一起消失；
##   · 重建意味着**全部建筑被销毁重造**，外部持有的旧实例引用立刻失效，大场景会有卡顿。
## 撤销最后一个操作
func undo() -> bool:
	if _undo_stack.is_empty():
		return false
	_undo_stack.pop_back()
	_rebuild_from_history()
	return true

## 清空全部建筑与历史（相当于把世界里的建造物全拆掉）。
## 参数：无。返回值：无。
## 副作用：_undo_stack.clear() + 全量重建（结果就是空容器），container 下所有实例被销毁。
## 注意：**连 build_from_scene() 从场景布局写进来的那些也会一起清掉**——
##       它们和玩家后续放置共用同一份历史栈，不分"场景件"与"玩家件"。
func clear_all() -> void:
	_undo_stack.clear()
	_rebuild_from_history()

## 当前历史记录条数。
## 参数：无。返回值：_undo_stack.size()。副作用：无。
## 注意：**一条 ≠ 一个物体**——一次 add_wall 可能生成十几个墙段，但只算 1 条；
##       所以这个数字适合报"做了几次操作"，不适合报"场景里有多少建筑"。
## 调用时机：world_builder 打印"聚落建筑 N 件"、调试面板。
func get_undo_count() -> int:
	return _undo_stack.size()

## 按 _undo_stack 全量重建：清空现有实例 → 在临时容器里逐条重放 → 把实例搬进正式容器。
## 参数：无。返回值：无。
## 副作用：销毁 container 下所有子节点并重新生成；临时节点 PlacedRebuild 入场/出场；
##         用副本覆盖 _undo_stack。
## 调用时机：undo() / clear_all() / build_from_scene() 末尾。
## 注意（改这里前必看）：
##   · 重放调的是 _place_* 私有函数，而它们**不写历史**，所以不会递归污染栈；
##   · 遍历的是 duplicate(true) 出来的 history 副本而不是 _undo_stack 本身，
##     避免"边遍历边被追加"导致遍历长度变化；
##   · 实例必须先挂进**已在树里**的 cache 节点，再设 global_position —— 否则 Godot 会报
##     !is_inside_tree()，并且所有墙段会被放到世界原点（这是踩过的坑）；
##   · match 只覆盖 wall / tower / house / tree 四种：新增放置类型必须同步补分支，
##     否则那种物件在撤销重放时会**静默消失**；
##   · 历史键用 op.get(key, 默认值) 读，是为了兼容早期版本写入的、缺键的旧记录。
func _rebuild_from_history() -> void:
	# 重建到临时容器后整体替换 Placed；历史里已包含场景件（build_from_scene 写入）。
	# 注意：cache 必须挂进树里——实例的 global_position/global_transform 只在树内有效，
	# 否则 Godot 会报 "!is_inside_tree()" 并把所有墙段放在原点。
	var cache := Node3D.new()
	cache.name = "PlacedRebuild"
	add_child(cache)
	var history: Array[Dictionary] = []
	for op in _undo_stack:
		history.append(op.duplicate(true))
	_clear_all()
	for op in history:
		match op.type:
			"wall":
				_place_wall(op.a, op.b, cache)
			"tower":
				_place_tower(op.c, op.r, op.get("y", -1.0), cache)
			"house":
				_place_house(op.p, op.s, op.get("y", -1.0), cache,
						int(op.get("v", -1)))
			"tree":
				_place_tree(op.p, op.s, op.get("y", -1.0), cache,
						int(op.get("v", -1)))
	# 重放走的是 _place_* 私有函数（不写历史），这里显式把栈指向本次重建用的副本，
	# 使栈内容与刚重建出的实例严格同源
	_undo_stack = history
	# 手写"重父化"：先 remove_child 再 add_child，避免 Godot 报
	# "node already has a parent" 并保证搬移顺序可控（顺序会影响同级渲染/物理排序）
	for c in cache.get_children():
		cache.remove_child(c)
		container.add_child(c)
	# 临时容器用完即拆：先离树再 free()（cache 只是这次重建的搬运工，没必要用 queue_free 拖到帧末）
	remove_child(cache)
	cache.free()

## 清空 container 下的所有实例（纯内部工具，不碰历史栈）。
## 参数：无。返回值：无。
## 副作用：对每个子节点先 remove_child 再 queue_free()（延迟到帧末真正释放）。
## 注意：因为用的是 queue_free，同一帧内旧节点可能还没被释放——但已经 remove_child 离树，
##       所以不会和新实例混在一起，也不会参与物理/渲染。
func _clear_all() -> void:
	for c in container.get_children():
		container.remove_child(c)
		c.queue_free()


# ==================== 场景布局重建（启动流程入口） ====================
## 参数：无——数据来源是场景节点 Main/Buildings/Layout 的子节点 meta。
## 返回值：无。副作用：清空并重写 _undo_stack、调 _rebuild_from_history() 重建全部实例、
##         最后 print 一行统计。
## meta 约定（在场景编辑器里手工写在 Layout 的子节点上）：
##   · kind：必填，"wall" / "house" / "tower" 三种（其它值会被 match 静默忽略）；
##   · yaw：可选，< 0（含缺省 -1.0）表示随机朝向；
##   · wall ：a / b（Vector3，缺省用节点自身 position）；
##   · house：scale（缺省 1.0）；
##   · tower：radius（缺省 1.4，与 main.gd 的默认塔半径一致）。
## 调用时机：world_builder.build() 第 3 步——在地形与平台整平之后、道路/植被之前。
## 注意：
##   · 非 Node3D 的子节点、以及没有 kind 的子节点一律跳过，所以 Layout 里可以随便放空节点/
##     参考物当书签；
##   · 记入历史的是 node.position（**相对 Layout 的本地坐标**），而 _place_* 是按
##     global_position 使用它——因此 Layout 必须是单位变换（当前 main.tscn 满足），
##     否则构建件会整体偏移；
##   · house 记录里没有写 "v"，重建时会退化成 op.get("v", -1) → 用**当前**的 house_variant
##     （推测：这是刻意让场景件跟随玩家的当前选择）；
##   · Layout 节点本身始终留在场景里（它只是"描述"），所有实例都在 Placed 下。
## 从场景布局节点重建全部建筑：Buildings/Layout 下每个子节点用 meta 描述一个构建件
## （kind=wall/house/tower，配合 a/b 或 scale/radius/yaw 等参数）。
## 布局节点始终保留在场景中，构建实例进 Buildings/Placed；
## 写回历史栈后，撤销/重建都能原样复现场景件与玩家后续放置。
func build_from_scene() -> void:
	_undo_stack.clear()
	var layout := get_node_or_null("Layout")
	if layout != null:
		for c in layout.get_children():
			# 非 3D 节点直接跳过：meta 只有挂在 Node3D 上才能取到有意义的 position，
			# 这样 Layout 里放空 Node/脚本节点/文件夹当注释也不会出错
			if not (c is Node3D):
				continue
			var node := c as Node3D
			# 没有 kind 的一律忽略（而不是报错）：Layout 里允许存在纯参考用的空节点
			if not node.has_meta("kind"):
				continue
			var kind := str(node.get_meta("kind"))
			var yaw := float(node.get_meta("yaw", -1.0))
			match kind:
				"wall":
					# a / b 缺省回退到节点自身位置：这时 seg == 0，_place_wall 会因 seg < 0.5 直接丢弃，
					# 属于"配错了不崩，只是不出墙"的容错设计
					var a := node.get_meta("a", node.position) as Vector3
					var b := node.get_meta("b", node.position) as Vector3
					_undo_stack.append({"type": "wall", "a": a, "b": b})
				"house":
					_undo_stack.append({"type": "house", "p": node.position,
							"s": float(node.get_meta("scale", 1.0)), "y": yaw})
				"tower":
					_undo_stack.append({"type": "tower", "c": node.position,
							"r": float(node.get_meta("radius", 1.4)), "y": yaw})
	print("Buildings | 从场景重建 %d 个构建件" % _undo_stack.size())
	_rebuild_from_history()
# =============================================================================
# 文件：scripts/world/features/terrain_platform.gd —— 地形整平平台（TerrainPlatform）
# =============================================================================
# 【本文件职责】
#   一个"声明式"的地形整形标记：节点摆在场景中的某个世界坐标即可，不用自己写逻辑；
#   运行时/编辑器内把它周围 radius 米的地形整体压到同一个高度，给聚落/基地/哨站的操场当地基。
#   本文件**自己不碰网格、不碰碰撞、不碰地形资源**，只做两件事：
#     1) 算出"要压到多少高度"（resolve_height）
#     2) 把这件事转交给地形系统（apply → terrain.flatten_region）
#
# 【所属系统】
#   世界组装（scripts/world/）。装配顺序由 WorldBuilder.build() 规定：
#     1) TerrainSystem.generate() 生成地形
#     2) WorldBuilder._apply_platforms() 遍历 Main/Terrain/Platform* 逐个调用 apply() ← 本文件
#     3) 聚落建筑 → 道路 → 植被铺底 + 清场 → 网格/碰撞重建
#   顺序是关键：平台必须在"取地形高度去铺路/摆房子"之前整平，否则建筑与路面会按旧高度落位。
#
# 【场景中的实例】（见 scenes/main.tscn，平台都是 Terrain 节点的子节点）
#   Main/Terrain/PlatformSpawn      radius=18.0  height=0.4（默认）  sample_from_terrain=false
#   Main/Terrain/PlatformVillage    radius=45.0  height=0.25        sample_from_terrain=false
#   Main/Terrain/PlatformOutpostA   radius=16.0（默认） height=0.25  sample_from_terrain=false
#   Main/Terrain/PlatformOutpostB   同 PlatformOutpostA
#   因为挂在 Terrain 之下，平台的世界坐标 = Terrain 的世界变换 × 自身 transform。
#
# 【关键依赖】
#   * 地形节点（scripts/world/terrain.gd，class_name TerrainSystem）：
#       - get_height_at(x: float, z: float) -> float                       世界 XZ → 高度（米）
#       - flatten_region(center: Vector3, radius: float, target_h: float)  整平一块区域
#     两者都用 has_method() 做鸭子类型探测，因此任何"长得像地形"的节点都能接手；
#     好处是解耦，代价是类型不匹配时只会静默 false/null，没有编译期报错来提醒。
#   * autoload / 单例：无，本文件不引用任何 autoload。
#   * 信号：无（既不发也不连），对外全是同步方法调用。
#   * 资源路径：无硬编码路径，一切通过场景装配与导出属性传入。
#
# 【主要对外接口】
#   resolve_height(terrain: Node) -> float   只算高度，不改地形（纯查询，可被外部单独使用）
#   apply(terrain: Node) -> bool             算高度 + 调 flatten_region，真正提交整平
#   radius / height / sample_from_terrain / round_step / preview_in_editor   导出参数
#
# 【已知的坑与注意事项】
#   1) ⚠ 目前 terrain.gd 里的 flatten_region() 是**空实现**（改用 Terrain3D 后留下的兼容壳，
#      见 terrain.gd "兼容空实现" 一节）。也就是说 apply() 现在会返回 true，但地形**并不会被压平**；
#      而 WorldBuilder._apply_platforms() 是按返回值计数的，日志"N/6 平台整平"不代表真的生效了。
#      要让整平真正起作用，得先在 TerrainSystem / Terrain3D 侧实现 flatten_region。
#   2) ⚠ 文件顶部那句"移动本节点或改半径，编辑器内即会重新整平"只在**场景重新加载**时才成立：
#      本文件没有 _enter_tree / 属性 setter / _process 监听，_editor_preview() 只在 _ready 里
#      call_deferred 触发一次。编辑器里拖位置或改半径不会自动重跑，需要重载场景（或手动调 apply）。
#   3) ⚠ @tool 意味着编辑器里也会执行 _ready → _editor_preview → apply → terrain.flatten_region。
#      如果 flatten_region 将来变成真实实现，编辑器中一打开场景就会**改地形数据**；
#      preview_in_editor 默认 false 正是为了默认不动手，只有显式打开才会预览。
#   4) 坐标系：采样用 global_position.x/z，而整平中心同样传 global_position，两者一致；
#      但若 Terrain（Terrain3D 数据）与平台不在同一世界原点下（比如搬动/旋转了 Terrain 节点），
#      采样高度与整平落点可能对不上（推测，未实测；本场景里 Terrain 与 Terrain3D 都在原点）。
#   5) _find_terrain() 靠**节点名字符串 "Terrain"** 向上查找，改名就会返回 null，
#      于是编辑器预览静默失效；运行时不受影响（由 WorldBuilder 直接把 terrain 传进来）。
#   6) 本文件不要求 terrain 是 TerrainSystem 类型，只要方法签名对得上即可（鸭子类型）。
#   7) GDScript 缩进敏感：本文件函数体都是**一个制表符**的单层块，补注释时不要插进多行表达式中间。
# =============================================================================
@tool
class_name TerrainPlatform
extends Node3D
## 地形平台：把本节点周围 radius 米整平到目标高度（聚落/基地/哨站的操场）
## 场景里移动本节点或改半径，编辑器内即会重新整平对应区域。
#
# ⚠ 上一条"改半径/移动节点就会重新整平"与当前代码不符，实际只在**场景重新加载**时触发一次
#   （_editor_preview 只有 _ready 里的一个 call_deferred 调用点，且 preview_in_editor 默认 false）。
#   详见本文件头部【已知的坑与注意事项】第 2、3 条。

# ==================== 一、导出参数（场景 / 编辑器配置） ====================
# 这些属性是"唯一的事实来源"：场景里直接改数值即可，不需要动代码。
# 改完记得重载场景（见坑 2）或由运行时 WorldBuilder 重新装配才会生效。

# 整平半径（世界米）。默认 16.0 的由来（推测）：约等于"一栋小屋 + 院子"的尺度，
# 够放下聚落最小地块，又不至于一刀切铲掉太多地形。
# 调大：整平面积变大（PlatformVillage 用 45.0 = 整个村子操场），但一次性改动的地形数据更多，
#       开销上升，也更容易把旁边想保留的坡地/河岸一起推平。
# 调小：只修脚下一小块，平台边缘会出现明显台阶（落差 = 原地形高差），得靠建筑/装饰遮住。
# 注意：半径按**世界米**解释，代码不乘节点 scale（只读 global_position，radius 原样透传）。
## 整平半径（米）
@export var radius := 16.0

# 目标高度（世界 Y，米）。sample_from_terrain = true 时**被忽略**（resolve_height 直接走采样分支）。
# 默认 0.4：稍微高于 y = 0 一点点；具体为何取 0.4 属推测 —— 可能是为了避开与 y=0 兜底碰撞面
#   /水面齐平导致的 z-fighting 与角色贴地抖动。
# 场景实例用的是 0.25（正好是 round_step 的整数倍，便于和道路/建筑对齐）；只有 PlatformSpawn 用默认 0.4。
# 调大：平台整体抬高，与周围未整平地形的边缘会出现陡坎，角色要跳/走台阶才能上下。
# 调小或负值：平台会切进地里；注意别低于兜底平面与水面高度，否则角色可能踩不到地面。
## 目标高度；勾选 sample_from_terrain 时忽略本项
@export var height := 0.4

# 是否以"本节点所在地形的高度"作为平台高度，而不是用 height 常量。
# 默认 true 是原逻辑行为（自适应地形，聚落既不悬空也不埋进山体）；
# 但本场景四个实例都显式设成了 false —— 项目实际走的是"写死 height"路线，读代码时别被默认值误导。
# 采样值还会被 round_step 向下取整，所以开启后得到的高度也是台阶化的。
# 效果差异：true → 高度随地形变化（地形一改，平台高度就变）；false → 高度稳定可复现，方便对齐建筑。
## 从地形采样中心高度（取整到 0.25m）作为平台高度——原逻辑行为
@export var sample_from_terrain := true

# 采样高度的取整步长（米）。只作用于 sample_from_terrain = true 的采样路径，对 height 常量无效。
# 默认 0.25 = 1/4 米：细到肉眼看不出台阶，又能让相邻平台/道路拿到**相同**的高度值，
# 避免浮点误差让本该等高的两块地面差几毫米（接缝处会闪烁/漏光）。
# 必须 > 0：resolve_height 里有 `if round_step > 0.0` 保护，等于 0 或负数时**跳过取整**（不报错也不除零）。
# 调大：台阶感明显但更容易对齐；调小：更贴合地形，却更容易出现相邻区域的微小高差。
## 采样取整步长（米）
@export var round_step := 0.25

# 编辑器内是否真的执行整平（_editor_preview 的第一道判断，与 _editor_running 取"与"）。
# 默认 false 是**安全默认**：@tool 脚本在编辑器里是活代码，默认开启就会"打开场景即改地形数据"。
# 改成 true：编辑器里加载/重载场景时会调用一次 apply（同样要场景重载才会再触发，见文件头坑 2）。
# 运行时（非编辑器）该开关完全不参与判断：_ready 在非编辑器环境直接 return。
## 在编辑器中实时预览整平效果
@export var preview_in_editor := false

# ==================== 二、内部状态 ====================
# 本文件刻意只保留一个可变状态，其余全是无状态纯函数 —— 这样重复调用是安全的，
# 在编辑器里跑也不会因为累积状态产生副作用（唯一的外部副作用就是 terrain.flatten_region）。

# 是否已在**编辑器**里跑过 _ready（只有 Engine.is_editor_hint() 为真时才会置 true）。
# 作用：_editor_preview() 的准入标志 —— 运行时 _ready 提前 return，_preview 根本不会被排队，
#   这里等于加一道双重保险，让它不必再判一次编辑器环境。
# 注意：它只被置 true、**从不复位**；所以一旦为 true，之后每次调用 _editor_preview() 都会继续放行。
#   名字里暗示的"避免场景加载时重复执行"，实际上靠的是 call_deferred 只排一次队，
#   而不是这个标志本身（推测：它来自更早"每次 _ready 都整平、导致重复执行"的版本）。
## 编辑器脚本运行中（避免场景加载时重复执行）
var _editor_running := false

# ==================== 三、高度解析（纯计算，不改地形） ====================
## 作用：算出"这个平台最终要压到哪个高度"，**不产生任何副作用**（不调 flatten_region、不改状态）。
## 参数 terrain：地形节点（Node，鸭子类型）。需要它提供 get_height_at(x, z) -> float；
##   传 null 或不具备该方法时，安全降级为直接返回 height 导出值（不崩溃、不报错）。
## 返回值：目标高度（米，世界 Y）。
## 副作用：无。
## 调用时机：apply() 内部调用；也可由外部单独查询（例如放建筑前先问一句地面高度）。
## 注意事项：
##   * 采样点用的是 **global_position.x / .z**（世界坐标），不是局部坐标。
##   * 取整用 floorf（向下取整）而非 roundf：结果 ≤ 真实地形高度，宁可让平台略微下沉，
##     也不让它悬空（悬空会露出地基缝隙，下沉只需用土石掩盖）—— 设计意图（推测）。
##   * 取整只作用于采样值：sample_from_terrain = false 时 height 原样返回、不做取整，
##     所以场景里手写的 height 要自己保持步长一致（三个实例写 0.25，PlatformSpawn 沿用默认 0.4）。
##   * 两个提前 return 的顺序是"先看开关、再看能力"：即使地形缺失也不会因采样失败而中断。
## 解析目标高度：采样模式取地形中心高度并取整
func resolve_height(terrain: Node) -> float:
	if not sample_from_terrain:
		return height
	if terrain == null or not terrain.has_method("get_height_at"):
		return height
	var h: float = terrain.get_height_at(global_position.x, global_position.z)
	# 步长必须 > 0：等于 0 或负数时跳过取整，既避免除零，也让"关闭取整"有个现成写法。
	if round_step > 0.0:
		# 向下取整到步长网格：让相邻平台/道路算出**同一个**浮点值，避免接缝处的毫米级高差。
		h = floorf(h / round_step) * round_step
	return h

# ==================== 四、应用整平（唯一的对外副作用入口） ====================
## 作用：把本平台的整平请求提交给地形系统 —— 本文件唯一会改变外部世界的函数。
## 参数 terrain：同 resolve_height，但需要的方法换成 flatten_region(center, radius, target_h) -> void。
## 返回值：true = 已向地形系统提交（**不代表地形真的被改动**，见文件头坑 1：目前是空实现）；
##   false = terrain 为 null 或没有 flatten_region，此时什么都没做（调用方据此计数/告警）。
## 副作用：调用 terrain.flatten_region → 可能修改地形高度数据，进而需要重建网格与碰撞（由地形侧负责）；
##   本函数自身不改场景树、不发信号、不写文件。
## 调用时机：
##   * 运行时：WorldBuilder._apply_platforms() 在"地形生成之后、取高度铺路建房之前"遍历所有平台调用；
##   * 编辑器：_editor_preview() 在 preview_in_editor = true 且脚本已在编辑器里运行过 _ready 时调用。
## 注意：能力探测是分两步的 —— 先要求 flatten_region 存在，之后再在实参里调 resolve_height，
##   而 resolve_height 内部还会探测 get_height_at；所以"只能整平、不能采样"的地形同样可用（退化为用 height）。
## 应用整平
func apply(terrain: Node) -> bool:
	# 探测失败返回 false 而不是断言/报错：让没有地形的场景（预览、单元场景）也能照常加载。
	if terrain == null or not terrain.has_method("flatten_region"):
		return false
	# 中心点直接用自身世界坐标，与 resolve_height 的采样点保持一致；半径、高度都由本节点导出属性决定。
	terrain.flatten_region(global_position, radius, resolve_height(terrain))
	return true

# ==================== 五、编辑器预览（@tool 专用） ====================
## 作用：@tool 回调。只在**编辑器**里干活：置好内部标志，并延迟一帧触发一次预览整平。
## 参数：无。返回值：无。
## 副作用：_editor_running = true；通过 call_deferred 排入一次 _editor_preview 调用。
## 调用时机：脚本（及其所在场景）在编辑器里被加载 / 重新加载时；游戏运行时也会进入本函数，但立即 return。
## 注意：
##   * 运行时的整平**不靠这里**，而是 WorldBuilder 显式调用 apply()；_ready 只服务编辑器预览。
##   * call_deferred 是必要的：_ready 阶段 Terrain3D 的地形数据与相邻节点可能还没就绪，
##     此刻采样会拿到 0 或旧高度，所以推迟到本帧末尾（实际是下一帧）再执行。
func _ready() -> void:
	# 非编辑器直接退出：整平属于"世界装配"的显式步骤，不能靠场景加载顺序碰运气。
	if not Engine.is_editor_hint():
		return
	_editor_running = true
	# 编辑器内：等一帧让地形节点就绪后再预览
	call_deferred("_editor_preview")

## 作用：编辑器预览的执行体。两个开关都通过时，找地形并整平一次。
## 参数 / 返回值：无。
## 副作用：若 preview_in_editor = true，会经 apply() 修改地形数据（**在编辑器里**发生）。
## 调用时机：仅由 _ready 里那一次 call_deferred 触发，全文件没有第二个调用点，
##   所以改半径、挪位置都不会重新触发（见文件头坑 2）；想重跑就重载场景。
## 注意：条件里两个变量是"与"关系 ——
##   preview_in_editor 表示用户意图，_editor_running 确保确实是编辑器脚本在跑，任一为假都直接 return；
##   _find_terrain() 找不到地形时静默跳过（不打印、不报错），避免刷爆控制台。
func _editor_preview() -> void:
	# 先判开关再干活：即使将来改成属性变更即触发，也能保证不做多余的地形查询。
	if not preview_in_editor or not _editor_running:
		return
	var terrain := _find_terrain()
	if terrain != null:
		apply(terrain)

# ==================== 六、地形节点查找 ====================
## 作用：从本节点**向上**逐层查找名为 "Terrain" 的子节点，供编辑器预览定位地形系统。
## 参数：无。返回值：找到的 Node（鸭子类型，**不** cast 成 TerrainSystem）；找不到返回 null。
## 副作用：无（只读场景树）。
## 调用时机：仅 _editor_preview() 调用；运行时由 WorldBuilder 直接把 terrain 传进 apply()，不走这里。
## 算法说明（为什么写成向上搜索）：
##   * 起点是 get_parent() 而不是自己，避开"自己可能恰好也叫 Terrain"的歧义；
##   * 每一轮都是"先在当前节点**自己的子节点**里找 Terrain，再上移一层"，于是在本项目结构
##     Main/Terrain/PlatformX 下：先查 parent(Terrain) 的子节点（里面没有叫 Terrain 的），
##     上移到 Main 后命中 Main/Terrain —— 也就是平台自己的父节点，即 TerrainSystem 实例。
##   * 用节点名字符串定位是脆的：Terrain 一旦改名就返回 null，编辑器预览静默失效；
##     换来的是不依赖固定层级（平台放在任意深度都能找到）—— 推测这是当初写成向上搜索的原因。
func _find_terrain() -> Node:
	var n: Node = get_parent()
	while n != null:
		# 每层都按名字找：与场景里 Main/Terrain 的命名约定绑定（见 terrain.gd 的 class_name）。
		var t := n.get_node_or_null("Terrain")
		if t != null:
			return t
		n = n.get_parent()
	return null

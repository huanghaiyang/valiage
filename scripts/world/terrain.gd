@tool
class_name TerrainSystem
extends Node3D
## 地形服务（精简版）
##
## 原来这里有 ~970 行**程序化地形**：噪声高度图、河流中心线与雕刻、11x11 分块网格、
## HeightMapShape3D 碰撞、顶点着色、笔刷雕刻。用户改用 Terrain3D 之后，这些**全部删除**。
##
## 本节点现在只做两件事：
##   1. 对外提供 `get_height_at()` —— Terrain3D 在就查它，否则查外接高度图，再否则返回 0
##   2. Terrain3D 还没雕数据时，放一块 y=0 的**兜底平面碰撞**，免得角色掉进虚空
##
## 对外接口保持不变（外部实际用到的）：generate / get_height_at / apply_brush /
## rebuild / is_in_river / HALF / brush_radius / brush_strength。
## apply_brush / flatten_region / rebuild* 保留为**空实现**，避免别的脚本调用时报错。

##
## ── 本文件属于哪个系统 ───────────────────────────────────────────
## 世界组装链（scripts/world/world_builder.gd::build）第 1 步调用 generate()，
## 第 2 步起用 get_height_at() 给平台 / 道路 / 植被 / 出生点贴地，第 6 步调用 rebuild()（现为空实现）。
## 场景挂载点：scenes/main.tscn 的 `Main/Terrain` 节点（class_name TerrainSystem）。
## 同一场景里另有 `Main/Terrain3D` 节点（addons/terrain_3d 插件），真正提供地形网格与碰撞。
##
## ── 关键依赖 ───────────────────────────────────────────────────
## · 节点：Terrain3D（可选）。可由 @export terrain3d_path 指定，或在当前场景里遍历查找
##   （判定用 is_class("Terrain3D")）。
## · 外部调用方（都在按下面的接口调用，签名不可随意改）：
##     scripts/world/world_builder.gd                 generate / get_height_at / rebuild / HALF
##     scripts/world/vegetation.gd                    get_height_at / is_in_river / HALF
##     scripts/world/road_network.gd                  get_height_at
##     scripts/world/features/spawn_point.gd          get_height_at（鸭子类型）
##     scripts/spells/spell_targeting.gd              get_height_at（鸭子类型）
##     scripts/camera_rig.gd                          get_height_at / using_terrain3d / _last_brush_*
##     scripts/main.gd                                get_height_at / apply_brush / brush_radius / brush_strength
##     scripts/world/features/terrain_platform.gd     get_height_at / flatten_region
## · 无 autoload 依赖；不发信号；不读写文件；运行期不加载资源（heightmap_import 由编辑器/场景指定）。
##
## ── 主要对外接口 ───────────────────────────────────────────────
##   generate(seed = -1) -> void        一次性初始化（幂等，可重复调用）
##   get_height_at(x, z) -> float       世界 XZ → 地面高度（米）
##   using_terrain3d() -> bool          Terrain3D 是否接管（**有副作用**：首次调用会配置它）
##   is_in_river(x, z) -> bool          恒为 false（河流已随程序化地形一起删除）
##   apply_brush / flatten_region / rebuild*()   空实现，仅保留方法名
##   const HALF                         世界半径（米）= SIZE / 2 = 450
##
## ── 已知的坑与注意事项 ─────────────────────────────────────────
## 1. flat_fallback_collider 与 Terrain3D 同时生效会出现两层碰撞面，角色**上下抖动**，
##    所以默认 false；只有"Terrain3D 还没雕数据"的过渡期才临时打开。
## 2. Terrain3D 未雕区域 data.get_height() 返回 NaN → get_height_at() 退化为 0.0。
##    这**不意味着那里真有 y=0 的地面**，只是为了不把 NaN 传染给贴地/物理计算。
## 3. 本脚本不负责给 Terrain3D 写高度数据：Terrain3D 接管后"刷地 / 整平"一律无效
##    （apply_brush / flatten_region 都是 pass）。
## 4. @tool 只表示"脚本在编辑器里也执行"；本文件 _ready 是空实现，所以编辑器里打开场景没有副作用。
##    Terrain3D 的配置只在有人调用 using_terrain3d() / get_height_at() 时才发生。
## 5. RESOLUTION / GRID / CELL 是程序化地形时代的遗留常量，文件内外都已无实际用途，改它们没有任何效果。

# ==================== 世界尺寸与网格常量 ====================
## 世界（地形）正方形范围的边长，单位：米。900 → 世界为 ±450m。
## 与 scripts/ui/minimap.gd 的小地图取景一致（那边按 ±450m 铺图）。
## 改大：可玩范围变大，但植被/道路等按这个范围撒点的系统不会自动跟着扩（推测：需同步改各系统的撒点范围）。
## 改小：世界边缘内容会被裁掉，撒点可能落到地形之外而悬空。
const SIZE := 900.0
## 世界半径，单位：米 = SIZE * 0.5 = 450。
## 用途：植被撒点 / 场景组装用 "randf() * 2 - 1 再乘 HALF" 之类的写法把 [0,1) 随机数映射到世界坐标。
const HALF := SIZE * 0.5
## 旧程序化地形的高度图分辨率（每边顶点数）。**现在本文件内已无人使用**，
## 只是历史遗留（+ 万一有外部按名字引用）；改它没有任何效果。
const RESOLUTION := 1024
## 旧高度图的格子数 = 顶点数 - 1 = 1023。同样已无实际用途，仅保留名字。
const GRID := RESOLUTION - 1
## 旧高度图每格边长，单位：米（SIZE / GRID ≈ 0.8797）。同样已无实际用途，仅保留名字。
const CELL := SIZE / float(GRID)

# ==================== 可配置项（Terrain3D / 高度图兜底） ====================
## 总开关：true = 优先用场景里的 Terrain3D 提供高度与碰撞（项目当前的实际配置）。
## false = 完全不用 Terrain3D，改走下面的 heightmap_import 兜底路径（没设图就是平地 y=0）。
## 注意：关掉它并不能让地形消失 —— 那样角色的地面会变成"高度图/0 平面"，而 Terrain3D 的
## 视觉网格与碰撞仍然存在（scene 里是独立节点），两层容易打架。
@export var use_terrain3d := true
## 是否在 y=0 生成一块兜底碰撞平面（节点名 Terrain3DFallback）。
## 默认 false：Terrain3D 已经有地形时必须保持 false，否则两层碰撞面打架 → 角色上下抖动。
## 只有在"Terrain3D 节点在、但还没雕任何高度数据"的过渡期才临时设 true，免得角色掉进虚空。
## 副作用：true 且尚未生成时，会在本节点下新增一个 StaticBody3D 子节点（layer 2 / mask 0 / 顶面 y=0）。
@export var flat_fallback_collider := false   # Terrain3D 有地形时必须 false，否则两层碰撞面打架 -> 上下抖动
## Terrain3D 节点路径（相对本节点解析，用 get_node_or_null）。留空 = 自动在场景树里找第一个 Terrain3D。
## scenes/main.tscn 里这项为空（未使用），实际走自动查找。
## 场景里存在多个 Terrain3D 时建议显式指定，否则命中的是遍历顺序里先遇到的那个（见 _find_terrain3d）。
## 路径写错不会报错，只会静默退回自动查找 —— 排查"高度不对"时要先确认这里是否指到了预期的节点。
@export var terrain3d_path: NodePath

## 兜底高度图开关：只在 use_terrain3d 为 false（或场景里找不到 Terrain3D）时才生效。
## 默认 false → 没有 Terrain3D 时 get_height_at() 恒返回 0.0（平地）。
@export var use_import_map := false
## 兜底高度图：取**红通道**当高度（0..1），世界 XZ 线性映射到图像 UV，最近邻取样（无双线性插值）。
## 每次采样都会调 get_image()（见 _height_from_map），没有缓存；图像小于 2x2 视为无效 → 返回 0。
@export var heightmap_import: Texture2D
## 高度图红通道值 1.0 对应的世界高度，单位：米。默认 60.0 → 最高 60m 的山。
## 调大 = 同样的图变成更陡的山（可行走性变差）；调小 = 更平缓。
## 只在 use_import_map 生效时才有意义。
@export var import_height_scale := 60.0
## 是否反转高度图（t = 1.0 - t）。默认 false。
## 图里"亮 = 高"（常见高度图）用 false；图里"暗/近 = 高"（深度图、某些导出工具）用 true。
@export var import_invert := false

# ==================== 笔刷兼容字段（项目已无真实笔刷） ====================
## 笔刷半径，单位：米。项目已无真实笔刷，这个值只被外部**读取**：
##   · scripts/main.gd 调 apply_brush() 时把它当实参传（函数体是 pass，不产生任何效果）；
##   · scripts/main.gd 还用它算"刷地后清植被半径 = brush_radius + 0.8"。
## 调大 → 只是"清植被"的范围变大（而且因为笔刷本身是空操作，这套流程实际不会因为刷地而触发）；
## 不会改变地形高度。
var brush_radius := 4.0
## 笔刷强度（原程序化地形的语义：每次调用抬高/降低的高度，米）。
## 现在只作为 apply_brush()（空实现）的实参来源，改它没有任何可见效果。
var brush_strength := 1.2

# ==================== 刷地记录（仅供相机/UI 读取，本文件不再写入） ====================
## 兼容：UI/相机在读这三个值画笔刷圈。地形归 Terrain3D 后不再有笔刷，
## 保持"很久以前"的状态 -> 圈不会画出来，但类型明确，外部代码不会推断失败。
var _last_brush_center := Vector3.ZERO
var _last_brush_radius := 0.0
## 时间戳格式为 Time.get_ticks_msec()；-1000.0 表示"很久以前"（保证任何时间窗口判断都不成立）。
var _last_brush_time := -1000.0
# 注意：本文件已不再写这三个值（没有笔刷逻辑了），所以 _last_brush_radius 恒为 0.0。
# scripts/camera_rig.gd 的"刷地同步"分支要求 br > 0.0 才生效 → 那条分支永远进不去（死代码），
# 且它只在 using_terrain3d() == false 时才被求值。字段保留纯粹是为了外部 `terrain._last_brush_*` 取值不报错。

# ==================== 内部缓存与一次性标志 ====================
## Terrain3D 节点缓存：首次找到后记住，避免每帧调用 using_terrain3d() 都遍历场景树。
## 用 is_instance_valid 校验（不是 null 判断）：节点被 free 后引用还在，会变成无效对象，必须重新查找。
var _t3d: Node = null
## generate() 里那条"地形由 Terrain3D 提供"的日志是否已经打印过。
## 只打印一次：场景重载 / 多次调用 generate() 时不刷屏。
var _hinted := false
## 是否已对 Terrain3D 做过一次碰撞配置（_configure_terrain3d 的前置守卫），保证整个运行期只配置一次。
## 配置动作会改 Terrain3D 的属性并打日志，重复执行没有必要（而且可能覆盖用户在编辑器里的手动设置）。
var _t3d_configured := false


# ==================== 生命周期 ====================
## 作用：节点进入场景树的回调，这里**刻意留空**。
## 为什么不在这里做初始化：真正的地形初始化由 WorldBuilder.build() 显式调用 generate()，
## 以保证"地形就绪 → 平台整平 → 各系统贴地取样"的顺序；节点自身的 _ready 时机不满足这个顺序约束，
## 在这里初始化会让贴地取样拿到还没准备好的地形。
## 副作用：无。@tool 之下编辑器打开场景也不会因此改动任何东西。
func _ready() -> void:
	pass


# ==================== 对外接口：生成与高度采样 ====================
## 作用：地形"生成"入口（历史遗留的方法名）。现在只做两件事：
##   1) Terrain3D 接管 → 首次打印一条提示，并尝试放 y=0 兜底碰撞面；
##   2) 否则只打印一行"高度来自 heightmap_import"。
## 参数 _seed_value：随机种子。**已完全不使用**（程序化地形删除后没有任何随机内容）；
##   下划线前缀就是"参数刻意不使用、但必须保留签名"的约定。调用方 WorldBuilder 传默认值 -1，
##   取值任意都不影响行为。
## 返回值：无。
## 副作用：可能 print；可能在本节点下新增 Terrain3DFallback 子节点（见 _build_flat_fallback）。
## 调用时机：WorldBuilder.build() 的第 1 步，早于所有贴地取样与平台整平。
## 幂等性：可安全重复调用（_hinted 与 has_node("Terrain3DFallback") 双重去重）。
func generate(_seed_value: int = -1) -> void:
	if using_terrain3d():
		# 先置位、再打印：即便 print 之后有重入调用，也不会重复刷这条日志
		if not _hinted:
			_hinted = true
			print("Terrain | 地形由 Terrain3D 提供（自有地形/河流代码已删除）")
		# 是否真的造出兜底平面由 flat_fallback_collider 决定（默认 false → 这次调用什么都不做）
		_build_flat_fallback()
		return
	print("Terrain | 未启用 Terrain3D：高度来自 heightmap_import（没设图则为平地 y=0）")


## 作用：把世界平面坐标 XZ 映射成地面高度 Y（单位：米）。这是本项目**最主要的地形查询接口**。
## 参数 x, z：世界坐标（米）。理论范围 [-HALF, +HALF] = [-450, 450]，但**本函数不做范围校验**：
##   Terrain3D 模式下越界坐标交给 Terrain3D 自己按区域规则处理；高度图兜底模式下会被 clampf 夹到边缘像素。
## 返回值：地面高度（米），**永不返回 NaN**。分支优先级：
##   ① Terrain3D 生效且该处已雕数据 → Terrain3D 的高度；
##   ② Terrain3D 生效但该处未雕数据（get_height 返回 NaN）→ 退化返回 0.0；
##   ③ 未启用 Terrain3D → 交给 _height_from_map()（没设图则 0.0）。
## 副作用：内部会调 using_terrain3d()，所以**首次调用可能顺带配置 Terrain3D 的碰撞模式/层并 print**。
## 调用时机：每帧被 scripts/camera_rig.gd 调用；场景组装期的贴地、植被撒点、法术瞄准等也都会调它。
## 注意事项：
##   · 返回的是**视觉高度**，坡地上与 Terrain3D 的物理碰撞面可能有细微出入；
##     camera_rig 因此明确规定"Terrain3D 模式下不用它把角色吸回地表"，否则会上下抖动。
##   · 0.0 同时代表"平地"和"未雕数据的兜底值"，调用方无法从返回值区分，不要据此判断地形是否存在。
func get_height_at(x: float, z: float) -> float:
	if using_terrain3d():
		# 用 get()/has_method() 鸭子类型访问 Terrain3D，而不是把类型写死：
		# terrain_3d 是 addon，直接引用它的类会在插件缺失/版本变动时解析失败。
		var d: Variant = _t3d.get("data")
		if d != null and d.has_method("get_height"):
			var h: float = float(d.call("get_height", Vector3(x, 0.0, z)))
			# Terrain3D 未雕过的区域 get_height() 返回 NaN。必须在这里挡住：
			# NaN 一旦流进贴地/物理计算会污染整条链路（物体消失、物理炸裂），
			# 所以退化成 0.0 —— 这**只保证"不是 NaN"**，不代表该处真有 y=0 的地面。
			if not is_nan(h):
				return h
		return 0.0
	return _height_from_map(x, z)


## 作用：未启用 Terrain3D 时的兜底高度采样 —— 从 heightmap_import 的**红通道**取高度。
## 参数 wx, wz：世界坐标（米）。
## 返回值：0.0（没开 use_import_map / 没设图 / 图小于 2x2），否则 = 红通道值(0..1) × import_height_scale。
## 映射规则：u = clampf((wx + HALF) / SIZE, 0, 0.999999)，v = clampf((wz + HALF) / SIZE, 0, 0.999999)，
##   像素下标 = (int(u * w), int(v * h)) —— **最近邻、无双线性插值、也没有 Y 翻转**。
## 副作用：每次调用都执行 heightmap_import.get_image()（要取一份图像数据，比较贵）且**没有缓存**；
##   如果这条路径将来变成热路径，第一步应该是缓存 Image（当前默认不走它，所以没做）。
## 注意：v 方向不做翻转（推测：与美术导出高度图的方向约定有关）。若发现地形南北方向反了，
##   优先怀疑这里，而不是 Terrain3D。
## 调用时机：仅由 get_height_at() 在"Terrain3D 不可用"时调用。
func _height_from_map(wx: float, wz: float) -> float:
	if not use_import_map or heightmap_import == null:
		return 0.0
	var img := heightmap_import.get_image()
	var w := img.get_width()
	var h := img.get_height()
	if w < 2 or h < 2:
		return 0.0
	# 夹到 0.999999 而不是 1.0：u == 1.0 时 int(u * w) == w 会越界，
	# Image.get_pixel 越界在调试构建下会直接报错失败。
	var u := clampf((wx + HALF) / SIZE, 0.0, 0.999999)
	var v := clampf((wz + HALF) / SIZE, 0.0, 0.999999)
	# 只取红通道（高度图约定用 R 存高度，G/B/A 忽略），最近邻取样 → 放大后是硬边阶梯
	# （推测：可以接受，因为这条兜底路径默认不用）。
	var t := img.get_pixel(int(u * float(w)), int(v * float(h))).r
	if import_invert:
		t = 1.0 - t
	return t * import_height_scale


# ==================== Terrain3D 查找 / 配置 / 探测 ====================
## 作用：找到场景里的 Terrain3D 节点，并缓存到 _t3d。
## 参数：无。
## 返回值：Terrain3D 节点；找不到返回 null。查找优先级：
##   ① 已缓存的 _t3d（用 is_instance_valid 校验，节点被释放则重新查找）；
##   ② @export terrain3d_path 指定的节点（相对本节点，get_node_or_null）；
##   ③ 从 get_tree().current_scene 起用显式栈遍历整棵场景树，返回第一个 is_class("Terrain3D") 的节点。
## 副作用：命中 ②/③ 时写入 _t3d 缓存。**不修改** Terrain3D 自身的属性（配置在 _configure_terrain3d）。
## 注意事项：
##   · 不在场景树里、或没有得到 current_scene 时直接返回 null
##     （推测：编辑器 / 子场景预览等场合 current_scene 可能为空）。
##   · 用字符串判定 is_class("Terrain3D") 而不是 `node is Terrain3D`：前者是运行期判断，
##     于是本脚本不依赖 terrain_3d 插件类在**解析期**存在（插件缺失时本文件仍能编译）。
##   · 遍历用 stack.pop_back()（后进先出），命中顺序不保证等于场景里的书写顺序；
##     场景里有多个 Terrain3D 时请用 terrain3d_path 明确指定。
func _find_terrain3d() -> Node:
	if _t3d != null and is_instance_valid(_t3d):
		return _t3d
	if terrain3d_path != NodePath():
		var n := get_node_or_null(terrain3d_path)
		if n != null:
			_t3d = n
			return _t3d
	if not is_inside_tree():
		return null
	var root := get_tree().current_scene
	if root == null:
		return null
	# 显式栈 + 循环，而不是递归：场景树可能很深，递归写法在深树上不必要地占用调用栈
	# （推测：这是当初选显式栈的原因；对结果而言两者等价，只是命中顺序是"后进先出"）。
	var stack: Array = [root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur.is_class("Terrain3D"):
			_t3d = cur
			return _t3d
		for c in cur.get_children():
			stack.append(c)
	return null


## 把 Terrain3D 对齐本项目的碰撞层约定：**地形 = layer 2**
## （角色 collision_mask = 2|4|8；Terrain3D 默认在 layer 1，不改的话角色会直接穿过地面）
## 作用：把 Terrain3D 对齐本项目的碰撞约定 —— 碰撞模式统一成 Game 档、地形放在 layer 2。整个运行期只做一次。
## 参数 t：Terrain3D 节点。为 null、或已经配置过（_t3d_configured）时直接返回，不报错。
## 返回值：无。
## 副作用：**写 Terrain3D 的属性** —— collision_mode 以及其 collision 子对象（Terrain3DCollision）的
##   layer / mask，最后 print 一行诊断；并把 _t3d_configured 置为 true。
## 调用时机：由 using_terrain3d() 在首次探测成功时调用（间接来自 generate / get_height_at / camera_rig）。
## 注意事项：
##   · collision_mode 只在 0 / 2 / 4（Disabled 与两个 Editor 档）时改写为 1（Game）；已经是 1 / 3 就不动。
##     项目场景里保存的是 4（Full/Editor），所以每次运行都会在这里被纠正并打印。
##   · 层级与掩码**不在 Terrain3D 自己身上**，而在 t.collision（Terrain3DCollision 对象）上；
##     Terrain3D.collision **不是 bool**，用错属性会拿到 null 并静默失效。
##   · mask 被设为 0：静态地形不需要主动检测任何东西，只靠 layer = 2 被角色（mask = 2|4|8）检测到。
##   · 函数内部 set 之后又 get 了一遍才打印，是为了打印"真正生效的值"而不是"想设置的值"。
func _configure_terrain3d(t: Node) -> void:
	if t == null or _t3d_configured:
		return
	_t3d_configured = true
	# 开碰撞：collision_mode 0=Disabled 1=Dynamic/Game 2=Dynamic/Editor 3=Full/Game 4=Full/Editor
	# ★ 修正：以前只在 0 时才改成 1，于是项目一直停在 **4 = Full/Editor**
	#   （Terrain3D 自己在启动时警告 "Change collision mode to a non-editor mode for releases"）。
	#   编辑器模式在发布/运行时会带来额外的构建与更新开销 —— 这里统一改成 **Game 模式**。
	var mode := int(t.get("collision_mode"))
	if mode == 0 or mode == 2 or mode == 4:
		t.set("collision_mode", 1)
		mode = 1
	# 层/掩码在 **Terrain3DCollision 子对象** 上（Terrain3D.collision 不是 bool！）
	var col: Object = t.get("collision")
	var lay := -1
	var msk := -1
	if col != null:
		lay = int(col.get("layer"))
		msk = int(col.get("mask"))
		if lay != 2:
			col.set("layer", 2)
		if msk != 0:
			col.set("mask", 0)
		lay = int(col.get("layer"))
		msk = int(col.get("mask"))
	print("Terrain | Terrain3D 碰撞: mode=%d layer=%d mask=%d（角色 mask=%d，地形须为 layer 2）" % [
			mode, lay, msk, 2 | 4 | 8])

## 作用：判断"Terrain3D 是否接管了地形"，并保证接管方已经被配置好。
## 参数：无。
## 返回值：true = use_terrain3d 为 true **且**找到了 Terrain3D 节点；否则 false。
## 副作用：**有**。返回 true 之前会调用 _configure_terrain3d()（一次性：改碰撞模式 / 层 / 掩码，并 print）。
##   也就是说这个看起来像"纯查询"的函数，第一次调用时会改动 Terrain3D 的状态；
##   不要在期待只读语义的场合调用它（例如纯粹想知道"当前是谁在提供地形"）。
## 调用时机：generate() 与 get_height_at() 每次都会调；scripts/camera_rig.gd 每帧也调它来决定
##   是否跳过老的"刷地同步"逻辑（所以要保证它足够便宜）。
## 注意：每帧调用是安全的 —— _find_terrain3d() 命中 _t3d 缓存，_t3d_configured 保证只配置一次。
func using_terrain3d() -> bool:
	if not use_terrain3d:
		return false
	var t := _find_terrain3d()
	if t == null:
		return false
	_configure_terrain3d(t)
	return true


# ==================== 兜底平面碰撞 ====================
## 作用：在本节点下生成一块覆盖整个世界的 y=0 兜底碰撞平面，防止 Terrain3D 还没雕数据时角色掉进虚空。
## 参数：无（行为由 @export flat_fallback_collider 控制）。
## 返回值：无。
## 副作用：**修改场景树** —— 新增 StaticBody3D（名 Terrain3DFallback）+ CollisionShape3D(BoxShape3D) 子节点，并 print。
## 几何：Box 尺寸 (SIZE, 1.0, SIZE)，位置 y = -0.5 → 顶面正好落在 y = 0，角色站在 y ≈ 0 上。
## 碰撞：collision_layer = 2（与 Terrain3D 的约定一致，角色 mask = 2|4|8 才踩得到）；
##   collision_mask = 0（自己是被动静态体，不需要主动检测任何东西）。
## 幂等性：flat_fallback_collider 为 false、或本节点已有同名子节点（has_node 判断）时直接返回，不会重复生成。
## 注意：Terrain3D 已经有地形后必须把 flat_fallback_collider 关掉，否则两层碰撞面打架 → 角色上下抖动。
func _build_flat_fallback() -> void:
	if not flat_fallback_collider or has_node("Terrain3DFallback"):
		return
	var body := StaticBody3D.new()
	body.name = "Terrain3DFallback"
	body.collision_layer = 2
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(SIZE, 1.0, SIZE)
	cs.shape = box
	# 盒子厚 1.0、中心下沉 0.5 → 顶面正好在 y = 0；兜底平面的语义就是"地面在 0"，不能偏移
	cs.position = Vector3(0.0, -0.5, 0.0)
	body.add_child(cs)
	add_child(body)
	print("Terrain | 已放置 y=0 兜底平面（雕好 Terrain3D 地形后关掉 flat_fallback_collider）")


# ==================== 兼容空实现（签名保留，调用无效果） ====================
# ---- 兼容空实现：地形归 Terrain3D 管，这些入口只保留名字 ----

## 作用：兼容空实现 —— 原地形笔刷的"抬高 / 降低 / 整平"入口。
## 参数 _world_pos：笔刷中心世界坐标。_radius：笔刷半径（米，调用方一般传 brush_radius）。
##   _delta：高度增量（米，正 = 抬高，负 = 降低；调用方一般传 ±brush_strength）。
##   三个下划线前缀表示"刻意不使用的参数"，只为保住签名不变。
## 返回值：无。
## 副作用：**无**（函数体是 pass）。也就是说调用它**不会改变地形高度**；
##   Terrain3D 的地形只能用 Terrain3D 自己的编辑器工具去改。
## 调用时机：scripts/main.gd 的 TERRAIN_RAISE / LOWER / FLATTEN 工具按下时会调用（目前点了没有视觉效果）。
## 为什么保留：main.gd 等外部仍按老接口调用，删掉或改名会让那些调用点直接报错。
func apply_brush(_world_pos: Vector3, _radius: float, _delta: float) -> void:
	pass


## 作用：兼容空实现 —— 原地形"把一块区域整平到 target_h"入口。
## 参数 _center：区域中心世界坐标（含 y）。_radius：半径（米）。_target_h：目标高度（米）。
## 返回值：无。副作用：**无**（pass）→ 地形**不会**被压平。
## 调用时机：scripts/world/features/terrain_platform.gd::apply() 会调它，并且因为"方法存在"就返回 true 计入平台数；
##   也就是说平台统计数字会好看，但地形实际没变（那个文件的头部注释也明确写了这一点）。
## 注意：不要因为调用方返回了 true 就认为整平成功。
func flatten_region(_center: Vector3, _radius: float, _target_h: float) -> void:
	pass


## 作用：兼容空实现 —— 曾经是"高度数据变了以后重建地形网格与碰撞"的总入口。
## 参数：无。返回值：无。副作用：无（pass）。
## 调用时机：WorldBuilder.build() 的第 6 步仍会调用它（历史上这里是最后一道同步），
##   但 Terrain3D 自己管理网格与碰撞，不需要外部重建。
func rebuild() -> void:
	pass


## 作用：兼容空实现 —— 语义同 rebuild()，只是粒度更细的"重建网格"入口。参数：无。副作用：无。
func rebuild_mesh() -> void:
	pass


## 作用：兼容空实现 —— 曾经用于"只重建中心点周围半径内的那片地形网格"（局部刷新，避免整块重建）。
## 参数 _center：世界坐标中心。_radius：半径（米）。返回值：无。副作用：无。
func rebuild_mesh_around(_center: Vector3, _radius: float) -> void:
	pass


## 作用：兼容空实现 —— 曾经用于重建 HeightMapShape3D 地形碰撞。参数：无。返回值：无。副作用：无。
## 注意：现在"新增兜底碰撞面"的职责在 _build_flat_fallback()，与这个函数无关。
func rebuild_collision() -> void:
	pass


## 作用：兼容空实现 —— 曾经的"河流水面网格重建"入口（河流雕刻已随程序化地形一起删除）。
## 参数：无。返回值：无。副作用：无。
func rebuild_river_mesh() -> void:
	pass


## 作用：兼容接口 —— 判断世界坐标是否落在"河流"里。
## 参数 _wx, _wz：世界坐标（米）。下划线前缀表示**刻意不使用**（已无从判断河流位置）。
## 返回值：**恒为 false**（河流信息随程序化地形一起删除）。
## 副作用：无。
## 调用时机：scripts/world/vegetation.gd 撒点时会先 has_method("is_in_river") 再调用，
##   用来剔除河道里的植被；因为恒为 false，那条剔除**永远不会触发** ——
##   所以 Terrain3D 上如果雕了河谷，植被依然会照常长在河谷里。
## 注意：外部用的是鸭子类型（has_method）；改签名或删函数会让植被侧的剔除逻辑**静默**失效。
func is_in_river(_wx: float, _wz: float) -> bool:
	return false
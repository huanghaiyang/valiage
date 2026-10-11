# ============================================================================
# 文件：scripts/world/road_network.gd
# 职责：砂石路网的**唯一网格生成器**。把一串世界坐标控制点连成"浅灰细线道路"
#       （参考复古战棋大地图的观感），并让路面**贴合地形起伏**：
#         · 每两个控制点之间按 ~SEG_LEN(10m) 细分，逐段采样地形高度；
#         · 每段用 BoxMesh 做一条薄条带（长度/厚度/宽度 = 段长/ROAD_THICK/width）；
#         · 每个控制点（含起终点与转折点）盖一个圆盘，遮住相邻条带之间的接缝。
#       本文件是"点 → 网格"的纯消费端：**不决定路线、不改地形、不写文件、不存盘**。
#
# 所属系统：世界组装（scripts/world/）。
#   调用链：RoadPath.collect_points()（编辑器里手摆的 Marker3D 路线）
#           → WorldBuilder._build_roads()（遍历 Main/Roads 下的 RoadPath 子节点）
#           → RoadNetwork.build_path(points, width)（本文件，真正生成网格）
#   挂载点：Main 场景下的 "Roads" 节点（main.gd: @onready var roads := $Roads），
#           生成的 MeshInstance3D 全部 add_child 到这个节点下，
#           所以"生成的网格"与"作为路线源的 RoadPath"是**同一父节点下的兄弟节点**。
#
# 关键依赖：
#   · TerrainSystem（scripts/world/terrain.gd，class_name TerrainSystem）：
#       唯一用到的外部接口是 get_height_at(x: float, z: float) -> float（世界坐标 → 地面 y）。
#       必须由外部在调用 build_path 之前通过 setup() 注入；未注入则 build_path 直接返回（安全跳过）。
#       Terrain3D 未启用时该函数会退化（无高度图即恒返回 0.0），此时道路会铺在平地 y=ROAD_LIFT 上。
#   · 无 autoload 依赖、无自定义 signal、不加载任何外部资源路径（材质在运行时 new 出来）。
#   · 若 RoadPath 尚未采集到 ≥2 个点，WorldBuilder 会先跳过，根本不会调到这里。
#
# 主要对外接口：
#   · setup(terrain: TerrainSystem) -> void     注入地形系统（必须先于 build_path）
#   · build_path(points: Array, width := ROAD_WIDTH) -> void   铺一整条路（可多次调用，见下）
#
# 已知的坑与注意事项：
#   1. **本类不清理旧网格**：build_path 只 add_child，不 delete 已有子节点。
#      因此重复调用（例如未来的编辑器实时预览、热重载重建世界）会让路面网格不断叠加 →
#      视觉上变厚、draw call 增长。当前唯一的运行时调用方 WorldBuilder 只在
#      世界生成阶段调用一次，所以暂时不触发；road_path.gd 里那句
#      "需要 RoadNetwork 支持清理旧路面"的注释就是在说这件事。
#   2. **控制点只取 x/z**：点的 y 分量完全被忽略 —— 高度一律由地形采样决定。
#      给控制点填任意 y 都不会改变路面高度，但填 0 最省心。
#   3. **不做去重**：重复/极近的控制点会产生退化段；靠 < 0.5m 的跳过阈值兜底，
#      但相邻控制点各自的"圆盘接缝片"仍会重复生成。
#   4. **必须在地形整平（TerrainPlatform.apply）之后调用**，否则采样到的是整平前的高度，
#      路面会与聚落平台穿模；WorldBuilder 的步骤顺序已经保证了这一点。
#   5. 分段是"每段一条独立 BoxMesh"，不是一条连续 mesh：
#      直路也只有节点级剔除，段数 ≈ 路线总长 / 10m，长路会明显增加节点数。
# ============================================================================

class_name RoadNetwork
extends Node3D
## 砂石路网：浅灰条带沿路径铺设（参考复古战棋大地图的浅灰细线道路）
## 分段贴合地形起伏铺路（每 ~10m 一段，采样两端地形高度），条带垂直抬升 ROAD_LIFT 米
## 避免与草地 Z-fighting（render_priority=1）；不改地形，与聚落平台零冲突

# ==================== 常量：路面的尺寸与分层参数 ====================
# 默认路面宽度（米）。3.5 ≈ 一条砂石车道的观感宽度；RoadPath.width 的默认值也是 3.5，
# 两边保持一致 -> "RoadPath 不填宽度"与"这里用默认宽度"结果相同，不会出现神秘差异。
# 调大：道路更宽更显眼，但转弯/接缝圆盘也同步变大，窄巷或聚落门口容易摊到草地与墙根上；
# 调小：路面偏窄像田埂，视距远时可能被草叶遮没。
const ROAD_WIDTH := 3.5    # 道路宽度（米）
# 条带厚度（米），即 BoxMesh 的 Y 尺寸。仅 0.1m：路面是"贴在地上的一层皮"，
# 靠厚度给出侧面的实体感，不需要真实体积。
# 调大：路面像一块厚板/马路牙子，坡地边缘会露出明显的侧壁；
# 调小（趋近 0）：坡地上条带容易被地形"穿"出来，出现断续的破面。
const ROAD_THICK := 0.10   # 条带厚度（米）
# 条带高于地形表面的分层偏移（米）。用"抬起来"而不是"改地形"来避免路与草地共面导致的
# Z-fighting（闪烁）；0.18m 足够压过地形表面的三角化误差与草皮起伏，又不至于让路"浮空"。
# 注意：材质上还有 render_priority = 1 作为第二道保险，两者叠加使用。
# 调大：上坡处路面会与草地脱开、露出缝隙（下坡处则埋进土里）；
# 调小：坡地/草地区域重新出现 Z-fighting 闪烁。
const ROAD_LIFT := 0.18    # 条带高于地形的高度（分层偏移，避免 Z-fighting）
# 单段条带的目标长度（米）：细分粒度的核心参数，决定"贴地"的精细程度。
# 每段都是一条**直的** BoxMesh，段越短，折线越接近地形曲面 -> 起伏贴合越好，但节点数越多。
# 10m 是观感与开销的折中（对 CozyVale 这种缓坡地形，10m 一段的落差用两端高度取中点即可接受）。
# 调大：长距离仍是一条直板，山丘/沟壑处路面会悬空或切入地形；
# 调小：贴地更准，但段数 = 路线总长 / SEG_LEN，节点数与 draw call 成比例上升。
const SEG_LEN := 10.0      # 分段长度（米），贴合地形起伏

# ==================== 内部状态（由 setup / _ensure_material 惰性填充） ====================
# 地形系统引用：**唯一**的外部依赖，只在 build_path 里被调 get_height_at()。
# 类型就是 TerrainSystem（不是 Node/泛型），所以脚本编译期就要求 terrain.gd 存在。
# 为 null 时 build_path 会安全早退（见 build_path 首行的空值检查）。
var _terrain: TerrainSystem
# 全路网共用的材质，**只创建一次**（_ensure_material 里惰性 new），之后所有条带/圆盘都引用同一个实例：
# 这样它们进入同一个合批，材质参数也只在一处生效。任何地方改它都会影响整张路网。
# 初始为 null（尚未创建），注意别在 setup 之前就当作已初始化去读。
var _mat: StandardMaterial3D

# ==================== 外部接口：注入依赖 ====================
## 注入地形系统。**必须在调用 build_path 之前**执行，否则 build_path 会因 _terrain == null 而整体跳过
## （安全失败：不报错、不铺路，只是静默什么都不生成）。
## 参数 terrain：TerrainSystem 实例，即 Main/Terrain 上挂的脚本节点（main.gd 里传给 WorldBuilder 的那个）。
##   传 null 也合法，效果等同于"不铺路"。
## 返回值：无。
## 副作用：写入成员变量 _terrain（覆盖旧值）。不会立刻生成任何网格 —— 真正的建网格发生在 build_path。
## 调用时机：世界生成阶段、地形整平之后、铺路之前（WorldBuilder 负责顺序）。
## 注意：本函数不校验引用是否有效（不查 terrain 是否已 _ready / 是否启用了 Terrain3D），
##   采样高度时若地形尚未就绪，get_height_at 可能退化返回 0.0，路面就全铺在平地高度上。
func setup(terrain: TerrainSystem) -> void:
	_terrain = terrain

# ==================== 核心：沿路径铺设砂石条带 ====================
## 沿多段路径铺路（points: Array，至少 2 个 Vector3 世界坐标点）
## 每段按 SEG_LEN 细分，采样两端地形高度铺贴地条带；端点/转折点用圆盘盖住接缝
## 参数 points：Array，元素需可赋给 Vector3（PackedVector3Array/Array[Vector3] 也兼容，
##   因为参数是弱类型的 Array 以便直接对接 RoadPath.collect_points()）。
##   **只使用每个点的 x/z**：y 完全被忽略，高度一律由 _terrain.get_height_at() 决定。
##   顺序即路线顺序；少于 2 个点直接返回。
## 参数 width：路面宽度（米），同时决定条带的 Z 尺寸与接缝圆盘的直径（半径 = width * 0.5）。
##   默认 ROAD_WIDTH(3.5)。取值应当 > 0；传 0 或负数会生成零宽/异常网格（不做参数校验）。
## 返回值：无（不返回生成的网格数量，调用方无法据此判断"是否真的铺出来了"）。
## 副作用：
##   · 场景树变化：生成本类节点（Roads）的**直接子节点**若干 MeshInstance3D（每段 1 个 + 每控制点 1 个圆盘）。
##   · 成员状态：首次调用会创建 _mat（惰性）。
##   · **不修改地形、不发信号、不写文件**；也不清理上一次调用留下的网格（重复调用会叠加，见文件头坑 1）。
## 调用时机：世界生成阶段，地形整平之后（否则采样到整平前高度，路面与聚落平台穿模）。
## 注意：段数与节点数约为"路线总长 / SEG_LEN + 控制点数"，长路线请评估节点开销。
func build_path(points: Array, width: float = ROAD_WIDTH) -> void:
	# 双保险早退：地形没注入（setup 没调 / 传了 null）或点不够连成一条线时静默跳过。
	# 故意不 push_error / 不打印 —— 这是"配置缺失"而非"运行错误"，由 WorldBuilder 决定是否铺路。
	if _terrain == null or points.size() < 2:
		return
	# 惰性建材质：放在早退之后，避免"被跳过的调用"也白白造一个 StandardMaterial3D。
	_ensure_material()
	# GDScript 的 for i in N 等价于 for i in range(N)，即 0..N-1；这里 N = size()-1，
	# 正好只枚举到倒数第二个点，保证下面 points[i+1] 不越界。
	for i in points.size() - 1:
		var a: Vector3 = points[i]
		var b: Vector3 = points[i + 1]
		var seg := a.distance_to(b)
		# 退化段（两点几乎重合，例如 RoadPath 里被重复摆放的 Marker3D）：
		# 继续算下去会得到 dir = (b-a)/seg → 除零，产生 NaN 使整条网格消失/变形，所以直接跳过。
		if seg < 0.5:
			continue
		# 单位方向向量。因为已排除 seg < 0.5，这里的除法不会除零。
		var dir := (b - a) / seg
		# 段数取"段长 / SEG_LEN"四舍五入并夹到至少 1：
		# maxi(1, ...) 保证短段（< 5m）也能生成 1 段，不会出现整段丢失。
		# 结果是每段实际长度 ≈ seg / n，而非严格等于 SEG_LEN —— 让细分均匀铺满整段、不留残料。
		var n := maxi(1, int(round(seg / SEG_LEN)))
		for k in n:
			# 用参数 t 插值而不是按固定步长累加位置：避免浮点误差累积导致末段对不上端点 b。
			var t0 := float(k) / float(n)
			var t1 := float(k + 1) / float(n)
			var p0 := a.lerp(b, t0)
			var p1 := a.lerp(b, t1)
			var mid := (p0 + p1) * 0.5
			# 贴地关键：**分别**把子段两端采样地形高度并各自抬升 ROAD_LIFT，
			# 而不是只取中点高度 —— 这样每段条带自身的水平中心线就落在坡面上，坡地不会一半悬空一半埋土。
			# 注意本实现只采样两端、不采样中段地形：段内的起伏被忽略（这正是 SEG_LEN 要取小的原因）。
			var h0 := _terrain.get_height_at(p0.x, p0.z) + ROAD_LIFT
			var h1 := _terrain.get_height_at(p1.x, p1.z) + ROAD_LIFT
			# 条带是一块**水平**的盒子（见下面 rotation 只绕 Y），所以 Y 取两端高度的平均：
			# 段内高差被"各摊一半"，坡上呈现轻微台阶感而非斜板 —— 这是与 BoxMesh 方案绑定的取舍。
			var hmid := (h0 + h1) * 0.5
			var seg_len := p0.distance_to(p1)
			var mi := MeshInstance3D.new()
			var box := BoxMesh.new()
			# BoxMesh 本地坐标：X = 长、Y = 厚、Z = 宽；X 用 seg_len（不是全局 SEG_LEN，
			# 因为末段/短段实际长度更短，用 seg_len 才能严丝合缝地首尾相接）。
			# 这里宽度落在 Z 上、长度落在 X 上，和下面 rotation.y = atan2(-dir.z, dir.x) 的朝向约定必须成对理解。
			box.size = Vector3(seg_len, ROAD_THICK, width)
			mi.mesh = box
			# 用 material_override 而不是给 BoxMesh.material 赋值：
			# 覆盖材质优先级更高，且所有条带共享同一个 _mat 实例（省内存、便于统一调参）。
			mi.material_override = _mat
			# 厚度只有 0.1m 的小薄片，投影阴影只会得到毫无意义的脏影，直接关掉更省性能也更干净。
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.position = Vector3(mid.x, hmid, mid.z)
			# y 轴朝向：把本地 +X 轴（长度方向）旋到 dir 方向。必须带负号 ——
			# Godot 绕 +Y 正向旋转 θ 时，+X 轴会指向 (cosθ, 0, -sinθ)，即 z 分量带负号，
			# 所以解出 θ = atan2(-dir.z, dir.x)。若漏掉负号（写成 atan2(dir.z, dir.x)），
			# 角度符号会反：只有沿 ±X 轴的路看着正常，沿 ±Z 轴的路会**横过来**（差 90°）。
			mi.rotation.y = atan2(-dir.z, dir.x)
			# 生成的网格直接挂在 Roads 节点下（与本类同级子节点），成为场景树的一部分 —— 这是本函数唯一的外部副作用。
			add_child(mi)
		# 转折点是否盖圆盘：现在盖。原因是相邻两段的条带在转角处只在内侧相碰、外侧必然留出楔形缺口。
		# 每个控制点各采样一次地形高度（可能与上面某段的端点采样值重复，但重复采样最省心、无副作用）。
		var ja := _terrain.get_height_at(a.x, a.z) + ROAD_LIFT
		var jb := _terrain.get_height_at(b.x, b.z) + ROAD_LIFT
		# 起终点与每个转折点都盖：一条折线的每个"顶点"都会被相邻两段各请求一次，
		# 所以中间点实际上会生成 2 个重叠圆盘（轻微浪费，但保证不会漏盖接缝）。
		_add_joint(a, ja, width)
		_add_joint(b, jb, width)

# ==================== 接缝处理：控制点圆盘 ====================
## 端点/转折点圆盘：盖住条带接缝（视觉上道路连续）
## 参数 p：控制点的**世界坐标**（只用 p.x / p.z；p.y 被忽略，高度一律由形参 y 决定）。
## 参数 y：圆盘中心的世界 Y（调用方已经算好"地形高度 + ROAD_LIFT"）。
##   这里**不**再次采样地形 —— 保证圆盘与紧邻条带处于同一分层高度，不会一高一低产生新接缝。
## 参数 width：路面宽度（米），圆盘直径 = width，即半径 = width * 0.5，与条带的 Z 尺寸一致。
## 返回值：无。
## 副作用：新建 1 个 MeshInstance3D 并 add_child 到本节点（Roads）下；不改 _terrain、不改 _mat。
## 调用时机：仅由 build_path 内部调用（每个控制点一次；中间转折点因左右两段各调一次而重复生成）。
## 注意：CylinderMesh 默认轴向是 Y（顶/底两个圆面朝上/下），所以**不需要**设 rotation ——
##   圆盘天然平躺，正好补上水平条带在转角外侧留下的楔形缺口；给它加旋转反而会插进地形里。
func _add_joint(p: Vector3, y: float, width: float) -> void:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	# 上下半径取同一个值 -> 正圆柱（而非圆台/圆锥）。半径 = width * 0.5 是为了让圆盘外缘
	# 刚好与条带的侧边对齐（条带 Z 尺寸就是 width），既盖住接缝又不会比路更宽。
	cyl.top_radius = width * 0.5
	cyl.bottom_radius = width * 0.5
	# 圆盘厚度与条带厚度一致：两者同一高度、同一顶面，接缝处不会看出"厚薄不一"的台阶。
	cyl.height = ROAD_THICK
	mi.mesh = cyl
	# 与条带共享同一个 _mat：颜色/粗糙度/优先级完全一致，圆盘与条带之间不会出现色差接缝。
	mi.material_override = _mat
	# 同上：0.1m 的薄片阴影无意义，关掉。
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 位置用 p 的 x/z + 传入的 y：y 由调用方给定，本函数不碰地形采样（这是刻意的，见函数文档）。
	mi.position = Vector3(p.x, y, p.z)
	add_child(mi)

# ==================== 材质：惰性创建 + 只建一次 ====================
## 保证 _mat 存在，语义等价于"get_or_create"：已存在则什么都不做。
## 参数：无。返回值：无。
## 副作用：首次调用时创建 StandardMaterial3D 并写入 _mat（此后永不重建，参数改动全局生效）。
## 调用时机：build_path 内部、早退检查之后调用一次；外部**不需要也不应该**主动调用。
## 注意：本函数只做存在性判断，不做参数校验；_mat 一旦建好，运行期改它的属性会影响整张路网的所有条带/圆盘。
func _ensure_material() -> void:
	if _mat != null:
		return
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.72, 0.69, 0.60)   # 浅灰砂石
	# roughness = 1.0（完全粗糙）：砂石/土路没有任何镜面高光，避免出现塑料感反光；
	# 同时省掉镜面 BRDF 的开销。注意这里没有设 metallic —— 保持默认 0.0（非金属）。
	_mat.roughness = 1.0
	# 关掉背面剔除：条带是没有"厚度方向意义"的薄片，相机偶尔会从下方/侧面看到背面，
	# 剔除后那片区域会直接消失（出现空洞），所以干脆双面渲染换取"永远不会露洞"。
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	# render_priority = 1：与 ROAD_LIFT 配合的**第二道**防 Z-fighting 保险 ——
	# 让路面材质在同一像素深度竞争时后画、压过草地/地形材质。
	# 这不是真正的深度偏移（不会改变几何），只是绘制顺序，所以不能替代 ROAD_LIFT。
	_mat.render_priority = 1

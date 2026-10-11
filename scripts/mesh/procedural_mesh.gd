# ==================== 文件头：职责 / 契约 / 坑 ====================
# 【文件】scripts/mesh/procedural_mesh.gd（class_name ProceduralMesh，extends RefCounted）
# 【所属系统】程序化搭建（Tiny Glade 风格）的"基础几何库"：只产出顶点数据，不碰场景树。
# 【职责】用纯手写 顶点 / 法线 / UV / 索引 的方式生成搭建件的基础几何体：长方体墙、
#         带城垛的墙、圆柱塔楼、锥形圆顶、双坡（山墙）屋顶，并提供转 ArrayMesh surface arrays 的出口。
# 【对外接口（全部是 static 纯函数，按 ProceduralMesh.xxx(...) 调用，无需实例化）】
#   build_wall(a, b, height, thickness, base_y=0.0)                      -> Array
#   build_crenellated_wall(a, b, height, thickness, base_y=0.0)          -> Array
#   build_tower(center, radius, height, base_y=0.0, segments=16)         -> Array
#   build_conical_roof(center, radius, height, base_y=0.0, segments=16)  -> Array
#   build_gable_roof(a, b, width, ridge_height, eave_height, base_y=0.0) -> Array
#   arrays_to_surface(geom)                                              -> Array（喂给 ArrayMesh.add_surface_from_arrays）
#   内部另有 _add_quad / _add_quad_simple / _add_tri 三个"往数组里追加面"的辅助函数。
# 【返回契约（隐式约定，改顺序会连带炸调用方）】build_* 一律返回 Array：
#   [0] PackedVector3Array 顶点   [1] PackedVector3Array 法线
#   [2] PackedVector2Array UV     [3] PackedInt32Array 三角形索引（每 3 个一组）
#   输入退化（例如两端点水平距离 < 0.01）时返回空数组 []，调用方必须先判空。
# 【关键依赖】无 autoload、无信号、无外部资源路径、不读写文件；只依赖 Godot 内置类型
#   （Vector2 / Vector3 / PackedXxxArray / Mesh / TAU / 数学函数），可直接在场景或测试脚本里调用。
# 【当前调用方】scripts/main.gd 的 _update_preview()：拖拽建墙/建屋顶时用本文件生成
#   ArrayMesh 预览网格（Game.Tool.WALL -> build_wall，Game.Tool.ROOF -> build_gable_roof）。
#   注意：build_crenellated_wall / build_tower / build_conical_roof 目前全项目没有调用方
#   （推测是预留接口或历史遗留）；真正落地建造走的是 scripts/world/building_manager.gd 的
#   .tscn 实例拼接路径，不经过本文件。
# 【已知的坑 / 注意事项】
#   1) 全部是平面着色：每个面只写一个法线、顶点不做共享去重，所以低段数塔楼/锥顶是硬边（低多边形）效果。
#   2) UV 有两套策略：build_wall / build_crenellated_wall 用"以米为单位"的尺度映射（墙长、高度直接当 UV 数值，
#      贴图密度与尺寸无关）；而屋顶/塔楼走 _add_quad_simple / _add_tri，UV 写死在 0..1，尺寸变大时贴图会被拉伸。
#   3) base_y 语义不统一：build_wall / build_crenellated_wall / build_gable_roof 里 base_y 是
#      绝对 y；而 build_tower / build_conical_roof 里实际高度是 center.y + base_y，是相对 center.y 的偏移。
#   4) 普遍不做封口：墙没有底面、塔楼没有底面、锥顶没有底盖，从下方或地形有落差处看会穿帮。
#   5) 不写 ARRAY_TANGENT / ARRAY_COLOR，需要法线贴图或顶点色的材质要调用方自己想办法（推测会缺切线）。
#   6) build_gable_roof 的屋脊实际退化成一个点，得到的是帐篷/四坡顶而非水平屋脊（详见该函数注释）。
# ==================== 文件头结束 ====================
class_name ProceduralMesh
extends RefCounted
## 程序化网格生成工具库
## 负责构建墙体、塔楼、屋顶等搭建件的基础几何体

## 世界坐标系正上方（Y 轴）单位向量。
## 本文件所有"竖起高度"的方向都基于它；用作常量是为了避免到处手写 Vector3(0, 1, 0)，
## 同时它也是 build_* 中 cross(UP) 求水平右向量、"顶面法线 = UP" 的唯一来源。
## 注意：假设游戏世界是 Y-up、没有倾斜地形基底；若将来引入斜坡地基，这里的竖直假设会失效。
const UP := Vector3.UP

# ==================== 第 1 段：内部几何辅助（往数组里追加面） ====================
# ------------------------------------------------------------
# 内部辅助：向几何数组追加四边形 / 三角形
# 传入的 verts/normals/uvs/indices 会被就地修改，vi 为当前顶点偏移
# ------------------------------------------------------------
## 追加一个"四顶点四边形"（拆成 2 个三角形，索引 0-1-2 与 0-2-3）。
## 参数：verts/normals/uvs/indices —— 就地写出目标的四个几何数组（调用方负责创建与最终打包）；
##       vi —— 该四边形第一个顶点在数组中的下标（顶点偏移），由上一个调用点的返回值接力传递；
##       pa..pd —— 四个角点，必须按 Godot 的正面绕序约定给出（观察方向为"从该面外侧看"，决定正面朝向/背面剔除）；
##       n —— 整个四边形共用的法线（本文件一律平面着色，一个面一个法线，不做平滑）；
##       u0..u3 —— 与 pa..pd 一一对应的 UV。
## 返回：本面写完后"下一个可用顶点下标"（即 vi + 4），用于连续追加多个面。
## 副作用：只写传入的四个 Packed 数组；不发信号、不碰场景树。
## 注意：法线是显式传入的、不是由顶点绕序算出来的 —— 顶点顺序写错时面会"亮错方向"，
##       而背面剔除仍按绕序生效，两者要一起检查。
static func _add_quad(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vi: int,
		pa: Vector3, pb: Vector3, pc: Vector3, pd: Vector3, n: Vector3,
		u0: Vector2, u1: Vector2, u2: Vector2, u3: Vector2) -> int:
	# 顶点不共享、按面复制：4 个角就是 4 个独立顶点，换来的是每个面独立法线（低多边形硬边风格）
	verts.append(pa); verts.append(pb); verts.append(pc); verts.append(pd)
	# 紧凑写法：一个面只有一个法线，循环 4 次等价于写 4 行 append；循环变量 i 只用来数次数
	for i in 4:
		normals.append(n)
	# UV 必须严格按 pa/pb/pc/pd 的顺序写入，否则贴图会错位
	uvs.append(u0); uvs.append(u1); uvs.append(u2); uvs.append(u3)
	# 四边形的两个三角形：(0,1,2) 和 (0,2,3)；顶点绕序决定背面剔除，法线只影响光照
	indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
	indices.append(vi); indices.append(vi + 2); indices.append(vi + 3)
	return vi + 4

## 追加一个"UV 写死"的四边形：与 _add_quad 同构，只是 UV 固定为
## Vector2.ZERO / Vector2.ONE / Vector2(1,0) / Vector2(0,1)，不再接收 u0..u3 参数。
## 用途：塔楼侧面、坡面这类"调用方懒得算 UV"的面（build_tower / build_gable_roof 在用）。
## 参数：同 _add_quad，但没有 u0..u3；pa..pd 仍须按"从面外侧看"的正面绕序给，n 为该面法线。
## 返回：下一个可用顶点下标（vi + 4）。
## 副作用：只写传入的四个 Packed 数组。
## 坑：这组 UV 是"交叉"的 —— pa=(0,0) 与 pb=(1,1) 正好在对角线上，画花纹贴图会出现镜像/斜切，
##     纯色或噪声类贴图看不出来（推测作者只是随手给个占位 UV，够用就没改）。
static func _add_quad_simple(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vi: int,
		pa: Vector3, pb: Vector3, pc: Vector3, pd: Vector3, n: Vector3) -> int:
	verts.append(pa); verts.append(pb); verts.append(pc); verts.append(pd)
	for i in 4:
		normals.append(n)
	# 写死的占位 UV（见函数文档里的"交叉 UV"说明）；顺序仍与 pa..pd 一一对应
	uvs.append(Vector2.ZERO); uvs.append(Vector2.ONE); uvs.append(Vector2(1, 0)); uvs.append(Vector2(0, 1))
	indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
	indices.append(vi); indices.append(vi + 2); indices.append(vi + 3)
	return vi + 4

## 追加一个三角形（1 个面、3 个顶点），用于山墙端面。
## 参数：verts/normals/uvs/indices —— 就地写出目标的四个数组；vi —— 本三角形首顶点下标；
##       pa/pb/pc —— 三个角点（从面外侧看的正面绕序）；n —— 整个三角形共用的法线。
## UV：固定为 (0,0) / (1,0) / (0.5,1)，即把三角形摊平在 UV 空间的下半张图上。
## 返回：下一个可用顶点下标（vi + 3）。
## 副作用：只写传入的四个 Packed 数组。
## 注意：UV 同样是写死的，build_gable_roof 的端面三角形没有做"按实际坡度缩放"，
##       所以端面贴图密度和坡面不一致（视觉上通常可接受，改材质/贴图时要知道这点）。
static func _add_tri(verts: PackedVector3Array, normals: PackedVector3Array, uvs: PackedVector2Array, indices: PackedInt32Array, vi: int,
		pa: Vector3, pb: Vector3, pc: Vector3, n: Vector3) -> int:
	verts.append(pa); verts.append(pb); verts.append(pc)
	for i in 3:
		normals.append(n)
	# 三角形摊在 UV 下半张：底边两点在 v=0，顶点在中上 v=1
	uvs.append(Vector2(0, 0)); uvs.append(Vector2(1, 0)); uvs.append(Vector2(0.5, 1))
	indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
	return vi + 3

# ==================== 第 2 段：基础墙体（长方体 / 带城垛） ====================
## 构建一段长方体墙
## a/b：地面上的两个端点；height：墙高；thickness：墙厚；base_y：底部高度
## 面数：5 个面 —— 前后面（长边）+ 左右端面 + 顶面；**没有底面**（埋在地面下看不见，省 2 个三角形）。
## 参数：
##   a / b：地面上的两个端点，定义墙的"中轴线"；两点的 y 分量被忽略（只取水平方向），
##          所以端点带高度差不会生成斜墙，竖直位置统一由 base_y 决定；
##   height：墙高（米），正值；0 或负数会让顶面四角与底面四角重合，侧面退化成零面积面甚至翻面（调用方应只传正数）；
##   thickness：墙厚（米），沿水平右向量向中轴线两侧各展开 thickness * 0.5，总厚 = thickness；
##   base_y：墙底面的**绝对世界 y**（默认 0.0 = 地面）。地形有起伏时可传采样到的高度把墙埋进坡里。
## 返回：[verts, normals, uvs, indices]；当两端点水平距离 < 0.01 时返回 []（退化输入保护，
##       调用方必须先判 empty，否则取下标会出错）。
## 副作用：无。纯计算，不创建节点、不发信号、不写文件（返回数组交给调用方转成 ArrayMesh）。
## 调用时机：可每帧调用（scripts/main.gd::_update_preview 在拖拽时每帧重建预览墙）。
## UV：以米为尺度 —— 长边 UV 宽 = 实际墙长 wall_len、高 = height；端面 UV 宽 = thickness、高 = height。
##     因此墙变长时贴图自动重复而不是被拉长；换贴图要注意 1 单位 UV = 1 米这个约定。
## 注意：法线是显式传入的（dir / -dir / right / -right / UP），不依赖绕序推算。
## 注意：交换 a 与 b 在几何上等价（dir 与 right 同时反向、法线也一起反向）（推测：可用于任意方向建墙）。
## 注意：两段墙首尾相接时，相接处两个端面会完全重叠共面，推测会出现轻微 z-fighting/闪烁。
static func build_wall(a: Vector3, b: Vector3, height: float, thickness: float, base_y: float = 0.0) -> Array:
	# 只取水平方向：端点之间的 y 差被丢掉，墙的竖直位置完全由 base_y + height 决定（不生成斜墙）
	var dir := (b - a)
	dir.y = 0.0
	# length 必须在 normalized() 之前取：它就是真实墙长（米），后面 UV 直接拿它当 UV 宽度
	var length := dir.length()
	# 退化保护：两端点几乎重合时不生成几何，避免 normalized() 产生 NaN / 零面积面
	if length < 0.01:
		return []
	# 归一化后 dir 只代表水平方向，长度信息已经存在 length 里
	dir = dir.normalized()
	# dir × UP 得到水平"右向量"（与 Godot 的 前向×上=右 约定一致）；墙厚沿它向两侧摊开
	var right := dir.cross(UP).normalized()
	# 以中轴线为中心对称加厚，所以取半厚
	var half_t := thickness * 0.5

	# p0..p3：墙底面四角（a 端在 +right 侧、b 端在 -right 侧，这个顺序同时决定各面的绕序）
	var p0 := a + right * half_t
	var p1 := a - right * half_t
	var p2 := b - right * half_t
	var p3 := b + right * half_t
	# 四角统一压到 base_y —— 这是墙体唯一的竖直定位点（a/b 自带的 y 已被忽略）
	p0.y = base_y; p1.y = base_y; p2.y = base_y; p3.y = base_y
	# q0..q3：顶面四角，与 p0..p3 同序整体抬高 height，便于一一对应写面
	var q0 := p0 + UP * height
	var q1 := p1 + UP * height
	var q2 := p2 + UP * height
	var q3 := p3 + UP * height

	# 本函数自己创建数组、用 _add_* 就地追加，最后按固定顺序打包成 [verts, normals, uvs, indices]
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0

	# 再兜一次长度下限（上面已挡掉 <0.01），避免出现 0 宽度 UV 导致贴图除零/拉伸（推测：防御性写法）
	var wall_len := maxf(length, 0.001)
	# 前后面（长边）
	# UV 依次对应 (0,0) → (wall_len,0) → (wall_len,height) → (0,height)：左下/右下/右上/左上，正好铺满一面且不翻转
	vi = _add_quad(verts, normals, uvs, indices, vi, p0, p3, q3, q0, dir, Vector2(0, 0), Vector2(wall_len, 0), Vector2(wall_len, height), Vector2(0, height))
	# 背面法线取 -dir，并把 b 端的角点排到前面，让这一面从背面观察时仍是正面朝向（绕序与法线要一起对）
	vi = _add_quad(verts, normals, uvs, indices, vi, p2, p1, q1, q2, -dir, Vector2(0, 0), Vector2(wall_len, 0), Vector2(wall_len, height), Vector2(0, height))
	# 左右端面
	# 端面同理：法线取 ±right，UV 宽度换成 thickness（贴图密度和长边一致，仍是 1 UV = 1 米）
	vi = _add_quad(verts, normals, uvs, indices, vi, p1, p0, q0, q1, -right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, height), Vector2(0, height))
	vi = _add_quad(verts, normals, uvs, indices, vi, p3, p2, q2, q3, right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, height), Vector2(0, height))
	# 顶面
	# 顶面的绕序按 q0→q3→q2→q1 走（沿用本文件统一的正面绕序约定），法线另外固定写 UP 以保证顶面朝上受光
	vi = _add_quad(verts, normals, uvs, indices, vi, q0, q3, q2, q1, UP, Vector2(0, 0), Vector2(wall_len, 0), Vector2(wall_len, thickness), Vector2(0, thickness))

	# 固定四元组顺序：[顶点, 法线, UV, 索引]；arrays_to_surface 依赖这个下标约定
	return [verts, normals, uvs, indices]

## 构建带城垛的墙体（Tiny Glade 风格城堡墙）
## 做法：先用 build_wall 生成 80% 高度的基础墙，再沿墙顶等距摆一排垛块（merlon），
##       所有面直接追加进同一组数组 —— 最终只有一个 surface（一次 draw call）。
## 参数：含义与 build_wall 完全相同（a/b 水平端点、height 参考总高、thickness 墙厚、base_y 绝对底部 y）。
## 返回：[verts, normals, uvs, indices]；两端点水平距离 < 0.01 时返回 []（此处自己先判了一次，
##       不会把退化输入传给 build_wall，所以 base 一定非空）。
## 副作用：无。base[0..3] 取出的是 Godot 的写时复制 Packed 数组，这里直接在它们上面 append
##       （相当于原地扩容，不会多拷贝一份），base 变量随后丢弃，所以安全。
## 几何细节 / 坑：
##   - 基础墙高 0.8 * height，垛块高 0.35 * height，所以垛顶在 base_y + 1.15 * height，
##     **最终总高比参数 height 还高 15%**（推测：height 在这里是"墙身参考高"而不是总高）。
##   - 垛块只有 4 个侧面 + 顶面，**没有底面**：它是坐在基础墙顶面上的，缺底面既省面，
##     也避免与墙顶面完全共面造成 z-fighting（推测）。
##   - 垛块数量 = maxi(1, int(length / 1.2))，即约每 1.2 米一个，且至少 1 个（防后面除零）。
##   - 垛块宽度 = 间距 * 0.55，剩下 45% 就是垛口空隙；想调疏密/宽窄就改 1.2 与 0.55 这两个常数。
## 调用时机：目前全项目没有调用方（预留接口）；正式城堡墙走 building_manager 的 .tscn 拼接。
static func build_crenellated_wall(a: Vector3, b: Vector3, height: float, thickness: float, base_y: float = 0.0) -> Array:
	# 与 build_wall 开头重复的一段：这里也要 dir / right / half_t 来摆垛块，
	# 作者选择重算一遍而不是抽公共函数（三段式：判长 → 归一化 → 求右向量）
	var dir := (b - a)
	dir.y = 0.0
	var length := dir.length()
	if length < 0.01:
		return []
	dir = dir.normalized()
	var right := dir.cross(UP).normalized()
	var half_t := thickness * 0.5

	# 基础墙只做 80% 高度：墙头留出一截用来摆垛块（垛块自身高 0.35 * height，垛顶会超出 height 约 15%）
	var base := build_wall(a, b, height * 0.8, thickness, base_y)

	# 城垛沿墙顶排列
	# 下面这几个数决定垛口的疏密与宽窄
	var merlon_count := maxi(1, int(length / 1.2))
	var merlon_w := length / float(merlon_count) * 0.55
	var merlon_h := height * 0.35
	var gap := length / float(merlon_count)
	# 从 a 端开始，朝 b 方向按 gap 步进排垛块
	var start := a

	# 直接复用 build_wall 返回的四个数组并接着往后写（下标契约：[0]顶点 [1]法线 [2]UV [3]索引）
	var verts: PackedVector3Array = base[0]
	var normals: PackedVector3Array = base[1]
	var uvs: PackedVector2Array = base[2]
	var indices: PackedInt32Array = base[3]
	# 关键：vi 必须接在已有顶点数之后，否则垛块的索引会指回墙体的顶点，画出乱七八糟的三角形
	var vi := verts.size()

	# 垛块底面的 y = 基础墙顶面 y；这个 0.8 必须与上面 build_wall(height * 0.8) 保持一致（改一处要改两处）
	var y0 := base_y + height * 0.8
	for i in merlon_count:
		# t0/t1 是当前垛块在墙中轴线上的起止点；再沿 ±right 各加厚 half_t 得到四角
		var t0 := start + dir * (float(i) * gap)
		var t1 := t0 + dir * merlon_w
		var p0 := t0 + right * half_t; p0.y = y0
		var p1 := t0 - right * half_t; p1.y = y0
		var p2 := t1 - right * half_t; p2.y = y0
		var p3 := t1 + right * half_t; p3.y = y0
		var q0 := p0 + UP * merlon_h
		var q1 := p1 + UP * merlon_h
		var q2 := p2 + UP * merlon_h
		var q3 := p3 + UP * merlon_h
		# 每个垛块 5 个面（4 侧面 + 顶面），没有底面 —— 底面正好贴在基础墙顶面上，共面且朝下，做出来也看不见
		# 前后面
		vi = _add_quad(verts, normals, uvs, indices, vi, p0, p3, q3, q0, dir, Vector2(0, 0), Vector2(merlon_w, 0), Vector2(merlon_w, merlon_h), Vector2(0, merlon_h))
		vi = _add_quad(verts, normals, uvs, indices, vi, p2, p1, q1, q2, -dir, Vector2(0, 0), Vector2(merlon_w, 0), Vector2(merlon_w, merlon_h), Vector2(0, merlon_h))
		# 端面
		vi = _add_quad(verts, normals, uvs, indices, vi, p1, p0, q0, q1, -right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, merlon_h), Vector2(0, merlon_h))
		vi = _add_quad(verts, normals, uvs, indices, vi, p3, p2, q2, q3, right, Vector2(0, 0), Vector2(thickness, 0), Vector2(thickness, merlon_h), Vector2(0, merlon_h))
		# 顶面
		vi = _add_quad(verts, normals, uvs, indices, vi, q0, q3, q2, q1, UP, Vector2(0, 0), Vector2(merlon_w, 0), Vector2(merlon_w, thickness), Vector2(0, thickness))

	return [verts, normals, uvs, indices]

# ==================== 第 3 段：塔楼与圆顶（圆柱 / 圆锥） ====================
## 构建圆柱塔楼
## center：中心点；radius：半径；height：高度；segments：圆周分段
## 几何构成：侧面圆筒 + 顶部圆盘封盖；没有底面。
## 参数：
##   center：圆柱的水平中心 —— x/z 直接用，y 参与竖直定位（见 base_y）；
##   radius：半径（米），应传正数；<= 0 会得到退化/翻面的几何；
##   height：筒高（米），正数；
##   base_y：**相对 center.y 的垂直偏移**，实际筒底 y = center.y + base_y（默认 0.0 即贴在 center 高度上）；
##           注意这与 build_wall / build_gable_roof 里 base_y 表示"绝对世界 y"的语义不同，
##           是本文件最容易踩的坑（推测是历史遗留的不一致）；
##   segments：圆周分段数（默认 16）。越大越圆，但顶点/三角形线性增长（每段：侧面 4 顶点 + 顶盖 3 顶点）；
##             1~2 段会退化成近似平板/三角柱，正常不要低于 6。
## 返回：[verts, normals, uvs, indices]，顶点数 = segments * 7。没有退化输入保护，永远不会返回空数组。
## 副作用：无（纯计算）。
## UV：侧面用 _add_quad_simple 的写死 UV；顶盖用"半径 0.5 的圆盘映射"把整圆塞进 0..1 UV 区间。
## 注意：侧面法线取"每段中点角度"，且每段顶点独立不共享，所以段与段之间是硬边（低多边形观感）；
##       要平滑圆柱得共享顶点 + 径向法线，当前实现刻意不做（推测是为了低模风格）。
## 调用时机：目前全项目没有调用方（预留接口）。
static func build_tower(center: Vector3, radius: float, height: float, base_y: float = 0.0, segments: int = 16) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0

	# 侧面
	# 整圈拆成 segments 个竖条四边形；i+1 在最后一段会绕回 TAU，所以圆环自动闭合无缺口
	for i in segments:
		# a0/a1 是本段圆弧两端的角度（弧度，0..TAU）；用引擎常数 TAU 而不是手写 6.28…
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, base_y, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, base_y, sin(a1) * radius)
		var q0 := p0 + UP * height
		var q1 := p1 + UP * height
		# 法线取该段中点角度的水平径向量；每段一个法线 → 得到棱面（hard edge）而不是光滑圆柱（推测是低模风格需要）
		var n := Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5)).normalized()
		vi = _add_quad_simple(verts, normals, uvs, indices, vi, p0, p1, q1, q0, n)

	# 顶盖（扇形）
	# 顶盖做成三角扇：扇心在塔顶中心，法线统一 UP（顶面朝天），段数与侧面一致所以边界能对齐
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, base_y + height, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, base_y + height, sin(a1) * radius)
		# 扇心每段重算一次（纯表达式，开销可忽略，换来的是不用在循环外多开一个变量）
		var top_center := center + UP * (base_y + height)
		# 这里不用 _add_tri：顶盖需要圆盘状 UV（三个顶点 UV 各不相同），_add_tri 的 UV 是写死的
		verts.append(top_center); verts.append(p1); verts.append(p0)
		for j in 3:
			normals.append(UP)
		# 半径 0.5 的圆盘 UV 映射：圆心 (0.5,0.5)，外圈按 cos/sin 缩到 0..1 —— 贴圆形纹理不会溢出
		uvs.append(Vector2(0.5, 0.5)); uvs.append(Vector2(0.5 + cos(a1) * 0.5, 0.5 + sin(a1) * 0.5)); uvs.append(Vector2(0.5 + cos(a0) * 0.5, 0.5 + sin(a0) * 0.5))
		indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
		# 手写索引推进：三角扇每段恰好 3 个顶点，所以直接 += 3（没有走 _add_* 的返回值接力）
		vi += 3

	# 没有底面（同 build_wall 的取舍）；四元组顺序与其它 build_* 保持一致
	return [verts, normals, uvs, indices]

## 构建锥形屋顶（圆塔顶）
## 圆锥几何，通常盖在圆塔楼顶上。
## 参数：与 build_tower 同形 —— center 的水平位置就是锥底圆心；base_y 同样是**相对 center.y** 的偏移；
##       radius 为锥底半径（米）；height 为锥体高（米，锥尖在 center.y + base_y + height）；
##       segments 为圆周分段（默认 16，段数越大锥面越圆滑）。
## 返回：[verts, normals, uvs, indices]，顶点数 = segments * 3；没有退化输入保护，不会返回空数组。
## 副作用：无（纯计算）。
## 几何：只有侧面，**没有底盖**（锥底是空的）；每段一个三角形。
## 坑：法线写成 (cosMid, 0.4, sinMid).normalized()，那个 0.4 是**经验性的法线抬升量，不是该面的真实法线**
##     （真实法线应由锥面倾角决定）—— 推测是为了让细长锥体在低角度光照下侧面不发黑。
##     换 PBR 材质 / 法线贴图 / 高光材质时，这个近似会明显露馅。
## UV：锥尖 (0.5, 1)，底边两点按半径 0.5 的圆盘映射（同 build_tower 顶盖），整锥摊在一张方形贴图上。
## 调用时机：目前全项目没有调用方（预留接口）。
static func build_conical_roof(center: Vector3, radius: float, height: float, base_y: float = 0.0, segments: int = 16) -> Array:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0
	# 锥尖只算一次，所有三角面共用同一个锥尖顶点位置（虽然每个面都会重新 append 一份）
	var apex := center + UP * (base_y + height)
	# 每段一个三角面：底边两端点落在圆周上，第三点是锥尖
	for i in segments:
		var a0 := float(i) / float(segments) * TAU
		var a1 := float(i + 1) / float(segments) * TAU
		var p0 := center + Vector3(cos(a0) * radius, base_y, sin(a0) * radius)
		var p1 := center + Vector3(cos(a1) * radius, base_y, sin(a1) * radius)
		# y 分量故意抬高到 0.4（不是真实锥面法线），见函数文档的"坑"
		var n := (Vector3(cos((a0 + a1) * 0.5), 0.4, sin((a0 + a1) * 0.5))).normalized()
		# 顶点顺序 (锥尖, p1, p0)：与本文件其它面的绕序约定保持一致，改动顺序会导致锥面翻面/被剔除
		verts.append(apex); verts.append(p1); verts.append(p0)
		for j in 3:
			normals.append(n)
		# 锥尖 UV = 贴图顶部中点，底边两点按 0.5 半径圆盘映射（和塔顶盖同一套映射，方便共用贴图）
		uvs.append(Vector2(0.5, 1)); uvs.append(Vector2(0.5 + cos(a1) * 0.5, 0.5 + sin(a1) * 0.5)); uvs.append(Vector2(0.5 + cos(a0) * 0.5, 0.5 + sin(a0) * 0.5))
		indices.append(vi); indices.append(vi + 1); indices.append(vi + 2)
		vi += 3
	return [verts, normals, uvs, indices]

# ==================== 第 4 段：屋顶 ====================
## 构建双坡屋顶（山墙屋顶）
## a/b：沿屋脊方向的两个端点；width：屋顶覆盖宽度；ridge_height：屋脊高度；eave_height：檐口高度；base_y
## ⚠ 注意：屋脊实际退化成一个点，详见下面【重要的坑】。
## 参数：
##   a / b：定义屋顶纵向的两个端点（y 被忽略），dir = 从 a 指向 b 的水平方向；
##   width：屋顶横向覆盖宽度（米，沿 right 方向），左右各外伸 width * 0.5；
##   ridge_height：屋脊/最高点相对 base_y 的高度（米）；
##   eave_height：檐口相对 base_y 的高度（米）；一般 ridge_height > eave_height，否则屋顶是平的或倒扣；
##   base_y：檐口的**绝对世界 y**（0.0 = 地面）。檐口线 y0 = base_y + eave_height，脊顶 yr = base_y + ridge_height。
## 返回：[verts, normals, uvs, indices]；两端点水平距离 < 0.01 时返回 []（退化保护）。
## 面数：2 个坡面（四边形，_add_quad_simple）+ 2 个三角端面（_add_tri）。
## 副作用：无（纯计算）。
## UV：坡面和端面都用 _add_quad_simple / _add_tri 的写死 UV，**没有做"1 UV = 1 米"的尺度映射** ——
##     所以屋顶变大时贴图会被拉伸（与 build_wall 的 UV 策略不同，换贴图时要注意）。
## 调用时机：scripts/main.gd::_update_preview() 在 ROOF 工具拖拽预览里每帧调用。
## 【重要的坑】ra 与 rb 其实是同一个点：ra = a + dir*(length*0.5)，而 rb = b - dir*(length*0.5)
##   = a + dir*length - dir*(length*0.5) = a + dir*(length*0.5)，两者 y 又都被设成 yr，于是 ra == rb。
##   后果：
##     1) "屋脊"收缩成中点的一个尖顶 —— 生成的是帐篷顶/四坡尖顶，而不是沿 dir 延伸的水平屋脊；
##        ridge_height 只在 a、b 的中间点生效，a/b 两端没有水平脊线。
##     2) 两个坡面四边形（p0,p3,rb,ra 与 p2,p1,ra,rb）的第 3、4 个顶点都重合，各自的第二个
##        三角形（vi, vi+2, vi+3）面积为 0，无害但白占三角形。
##   （推测：原意可能是 ra = a、rb = b 再把 y 抬到 yr，这里属于未完成/历史遗留；
##     要做真正的双坡屋顶，需要改这两行的水平偏移。）
static func build_gable_roof(a: Vector3, b: Vector3, width: float, ridge_height: float, eave_height: float, base_y: float = 0.0) -> Array:
	# 与 build_wall 相同的三步：抹掉 y → 先量长度 → 再归一化成方向；退化输入直接返回空数组
	var dir := (b - a)
	dir.y = 0.0
	var length := dir.length()
	if length < 0.01:
		return []
	dir = dir.normalized()
	var right := dir.cross(UP).normalized()
	var half_w := width * 0.5

	# y0 = 檐口线高度，yr = 脊顶高度；两者都是"绝对世界 y"，由 base_y 加各自高度得到
	var y0 := base_y + eave_height
	var yr := base_y + ridge_height

	# p0..p3：檐口四角（a 端 +right / a 端 -right / b 端 -right / b 端 +right），全部压到檐口线 y0
	var p0 := a + right * half_w; p0.y = y0
	var p1 := a - right * half_w; p1.y = y0
	var p2 := b - right * half_w; p2.y = y0
	var p3 := b + right * half_w; p3.y = y0
	# ⚠ ra 与 rb 是同一个点（都落在 a、b 中点，y 都是 yr）—— 见函数文档【重要的坑】
	var ra := a + dir * (length * 0.5); ra.y = yr
	var rb := b - dir * (length * 0.5); rb.y = yr

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var vi := 0

	# 两个坡面
	# slope_n 是"右 + 上方 0.6"的近似法线，不是按实际坡度算出来的（同 build_conical_roof 的做法）
	var slope_n := (right + UP * 0.6).normalized()
	vi = _add_quad_simple(verts, normals, uvs, indices, vi, p0, p3, rb, ra, slope_n)
	# 另一侧坡面：法线镜像成 -right + 0.6 * UP（顶点顺序也整体反过来）
	vi = _add_quad_simple(verts, normals, uvs, indices, vi, p2, p1, ra, rb, (-right + UP * 0.6).normalized())
	# 两端三角山墙
	# 端面法线取 ±dir：a 端朝 -dir、b 端朝 +dir；端面是三角形所以走 _add_tri（UV 写死）
	vi = _add_tri(verts, normals, uvs, indices, vi, p0, ra, p1, -dir)
	vi = _add_tri(verts, normals, uvs, indices, vi, p3, p2, rb, dir)

	# 四元组顺序与其它 build_* 一致，供 arrays_to_surface 按下标取用
	return [verts, normals, uvs, indices]

# ==================== 第 5 段：出口（转 ArrayMesh surface arrays） ====================
## 把几何数组转为 ArrayMesh surface arrays
## 输入是 build_* 返回的 [顶点, 法线, UV, 索引] 四元组。
## 参数 geom：**必须是本文件 build_* 的返回值**（隐式契约 —— 下标 0/1/2/3 依次是
##   PackedVector3Array / PackedVector3Array / PackedVector2Array / PackedInt32Array）。
## 返回：长度为 Mesh.ARRAY_MAX 的 Array，只有 VERTEX / NORMAL / TEX_UV / INDEX 四个槽位有值，
##   其余槽位为 null；当 geom 为空数组、或顶点数组为空时返回 []，调用方必须判空后再用。
## 副作用：无。不创建 ArrayMesh（创建与挂载留给调用方，见 scripts/main.gd::_update_preview）。
## 调用时机：每次要把程序化几何塞进 ArrayMesh 时调用一次（拖拽预览是每帧一次）。
## 坑 / 注意：
##   - 这里不写 ARRAY_TANGENT / ARRAY_COLOR：需要法线贴图的材质会缺切线
##     （推测会出现法线贴图失效或光照异常），想用顶点色的方案（如 vegetation 的顶点色烘焙）也不能走这个出口；
##   - 索引必须是 PackedInt32Array（Godot 4 对 ARRAY_INDEX 的类型要求），本文件 _add_* 产出的正是它；
##   - arrays.resize(Mesh.ARRAY_MAX) 不能省：add_surface_from_arrays 是按槽位下标读取的定长数组，
##     长度不够会越界报错。
## 典型用法：
##   var arrays := ProceduralMesh.arrays_to_surface(geom)
##   if not arrays.is_empty():
##       var mesh := ArrayMesh.new()
##       mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
static func arrays_to_surface(geom: Array) -> Array:
	# 双重判空：build_* 在退化输入下会返回 []，此时 geom[0] 会越界；顶点为空则建 surface 也没意义
	if geom.is_empty() or (geom[0] as PackedVector3Array).is_empty():
		return []
	# Godot 的 surface arrays 是"按槽位下标读取"的定长数组，必须 resize 到 ARRAY_MAX 才能安全赋值
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	# 槽位对应关系（顺序由 build_* 的返回契约保证，不能变）：顶点 / 法线 / UV / 三角形索引
	arrays[Mesh.ARRAY_VERTEX] = geom[0]
	arrays[Mesh.ARRAY_NORMAL] = geom[1]
	arrays[Mesh.ARRAY_TEX_UV] = geom[2]
	arrays[Mesh.ARRAY_INDEX] = geom[3]
	# 返回值直接喂给 ArrayMesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return arrays

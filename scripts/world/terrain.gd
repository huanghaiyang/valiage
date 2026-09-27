class_name TerrainSystem
extends Node3D
## 可编辑地形系统
## 使用高度图 + 程序化网格，支持抬升/下陷/平整刷子
## 面积较初版扩大 20 倍：边长 200m → 900m（面积 40000 → 810000 m²），分辨率同步提高保持细节

const SIZE := 900.0          # 地形总尺寸（米），面积约为原版 20 倍
const RESOLUTION := 1024     # 地形分辨率（1023² 顶点 ≈ 0.88m/格，poly 较 512 提升 4 倍）      # 网格分辨率（顶点数），保持约 1.76m/格的地形细节
const GRID := RESOLUTION - 1
const HALF := SIZE * 0.5
const CELL := SIZE / float(GRID)

var height_map: PackedFloat32Array
var color_map: PackedColorArray

var mesh_instance: MeshInstance3D
var collision_body: StaticBody3D

# 刷子参数
var brush_radius := 4.0
var brush_strength := 1.2

# 噪声生成
## 地形种子：固定值让高度场可复现（场景里烘焙的平台/建筑高度依赖它）
var terrain_seed := 20260927

var _noise: FastNoiseLite
## 大尺度山脊噪声（山脉/丘陵分布）
var _mountain_noise: FastNoiseLite
## 中尺度起伏（山体形状）
var _hill_noise: FastNoiseLite
## 细节噪声（草坡纹理，幅度很小）
var _detail_noise: FastNoiseLite
## 面片色彩变化噪声（低多边形手绘感；平滑变化，绝不能按网格坐标取，否则是棋盘格）
var _facet_noise: FastNoiseLite
## 河流中心线（world XZ 折线）。generate() 时按此开挖河道并生成水面。
var river_points: PackedVector2Array = PackedVector2Array()
## 每段的包围盒（minx, minz, maxx, maxz），用来快速跳过远离河流的格子。
## 没有这个缓存时光是 1024² 次折线距离计算就要 6 秒。
var _river_boxes: PackedVector4Array = PackedVector4Array()
## 河面高度（低于两岸、高于河床）
var river_level := 0.0
## 水面网格实例
var river_mesh: MeshInstance3D = null
## 河底碰撞体
var river_collision: StaticBody3D = null

## 河流参数：半宽（水面宽度的一半）、河床比水面低多少、两岸过渡带宽度
## 12m 宽的水面从地面看才有河的分量；先前 10.4m 且过渡带太窄，看着像水沟。
const RIVER_HALF_WIDTH := 6.0
## 河床比水面低多少。不能太深：旧值 1.8 时水下还有一层河底碰撞板，
## 角色一旦进去就会被夹在地形与这块板之间出不来（试玩实测卡死）。
## 现在把河道做成可以踚过去的浅滩：水深约 0.8m，角色站得住、走得动。
const RIVER_BED_DROP := 0.8
## 过渡带要够宽，河岸才会是缓坡而不是台阶
const RIVER_BANK := 10.0
## 河面高度：谷底 h=0.40，水面比谷底低 0.95 —— 河道是下沉的，
## 从岸上看得到水，但水不会漫到草地上。
const RIVER_LEVEL := -0.55

var _mesh_dirty := false
var _collision_dirty := false
var _mesh_timer := 0.0
var _collision_timer := 0.0
# 重建节流：连续刷地时合并重建，避免每次点击都全量重建网格+碰撞
const MESH_REBUILD_DELAY := 0.1
const COLLISION_REBUILD_DELAY := 0.35

# 地形网格分块：7×7=49 块（GRID=511=7×73），刷地只重建受影响块，避免全量重建
const CHUNKS := 11           # 网格分块（1023=11×93，121 块，刷地只重建受影响块）
const CHUNK_GRID := GRID / CHUNKS
var chunk_meshes: Array[MeshInstance3D] = []
var _last_brush_center := Vector3.ZERO
var _last_brush_radius := 0.0
var _last_brush_time := 0   # 最近一次刷地时间（毫秒），供角色仅在刷地后短暂窗口内贴地同步

func _init() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = terrain_seed
	# 地图放大后适当降低频率：山丘波长随地图一起放大，保持"同一个山谷"的开阔感
	_noise.frequency = 0.006
	_noise.fractal_octaves = 4
	_noise.fractal_gain = 0.5
	_noise.fractal_lacunarity = 2.0
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	# 山脉：极低频、多倍频，形成连片山脊而不是孤立土包
	_mountain_noise = FastNoiseLite.new()
	_mountain_noise.seed = terrain_seed + 101
	_mountain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_mountain_noise.frequency = 0.0026
	_mountain_noise.fractal_octaves = 5
	_mountain_noise.fractal_gain = 0.5
	_mountain_noise.fractal_lacunarity = 2.1
	# 丘陵：中频，决定近处草坡的起伏
	_hill_noise = FastNoiseLite.new()
	_hill_noise.seed = terrain_seed + 202
	_hill_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_hill_noise.frequency = 0.0042
	_hill_noise.fractal_octaves = 4
	_hill_noise.fractal_gain = 0.45
	# 细节：幅度压得很小，只做草坡表面的轻微起伏
	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = terrain_seed + 303
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.frequency = 0.02
	_detail_noise.fractal_octaves = 2
	# 面片明暗：中低频、单倍频，做柔和的手绘色块起伏
	_facet_noise = FastNoiseLite.new()
	_facet_noise.seed = terrain_seed + 404
	_facet_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_facet_noise.frequency = 0.05
	_facet_noise.fractal_octaves = 1

func _ready() -> void:
	mesh_instance = MeshInstance3D.new()
	add_child(mesh_instance)
	collision_body = StaticBody3D.new()
	collision_body.collision_layer = 2
	collision_body.collision_mask = 0
	# 碰撞采样 1.5m/点（HeightMapShape3D 本地采样间隔固定 1 单位，节点 XZ 放大 1.5 倍覆盖 900m），
	# 采样点数 601²=36 万，重建 ~85ms；比 2m 采样更贴合地形，陡坡处角色行走不再大台阶抖动
	collision_body.scale = Vector3(1.5, 1.0, 1.5)
	# HeightMapShape3D 网格以 CollisionShape3D origin 为中心，采样点间隔 1 单位
	# map_width=SIZE/STEP+1 覆盖 [-HALF, HALF]，直接对齐地形网格
	var _col_shape := CollisionShape3D.new()
	_col_shape.name = "TerrainCollision"
	collision_body.add_child(_col_shape)
	add_child(collision_body)
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# 地形材质：使用顶点色作为漫反射颜色（卡通分层配色）
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	# 地形高度图网格绕序可能与默认背面剔除方向相反，开双面渲染确保地面可见
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	# 中世纪低多边形：逐像素卡通分段光照。
	# 网格本身是 flat-shaded 面片（每面独立法线），逐像素卡通化后每个面片是一块
	# 干净色块，明暗界线清楚；之前用 PER_VERTEX 顶点光照会把面片感和层次一起糊掉。
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	mat.specular_mode = BaseMaterial3D.SPECULAR_TOON
	# 注意：Godot 3 的 diffuse_toon_size / diffuse_toon_softness 在 Godot 4
	# 已经不存在（会打 WARNING: SpatialMaterial remapped parameter not found），
	# 卡通分段由 DIFFUSE_TOON + SPECULAR_TOON 自动处理。
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	mat.metallic_specular = 0.0
	mesh_instance.material_override = mat
	# 分块网格实例（7×7 块，共享同一材质，刷地只重建受影响块）
	for ci in CHUNKS * CHUNKS:
		var mi := MeshInstance3D.new()
		mi.name = "TerrainChunk_%d" % ci
		mi.material_override = mat
		mesh_instance.add_child(mi)
		chunk_meshes.append(mi)

func generate(seed_value: int = -1) -> void:
	# 未显式指定时使用场景声明的 terrain_seed，保证每次生成同一片山谷
	_noise.seed = seed_value if seed_value >= 0 else terrain_seed
	height_map.resize(RESOLUTION * RESOLUTION)
	color_map.resize(RESOLUTION * RESOLUTION)
	for z in RESOLUTION:
		for x in RESOLUTION:
			var wx := -HALF + x * CELL
			var wz := -HALF + z * CELL
			var h := _sample_noise_height(wx, wz)
			height_map[z * RESOLUTION + x] = h
			color_map[z * RESOLUTION + x] = _color_for_height(h, wx, wz)
	_build_river_centerline()
	_carve_river()
	rebuild()
	rebuild_river_mesh()

## 河流中心线：一条从西侧入、东南侧出的蜿蜒河，特意绕开出生点与聚落。
## 出生点平台半径 18m、聚落清场半径 52m 都在原点附近，河道最近处约 32m。
func _build_river_centerline() -> void:
	# 明显的蜿蜒：每 ~90m 摆动 ±35m，才有河的样子而不是一条运河。
	# 最近处到原点约 34m，仍在聚落清场半径（52m）之外。
	river_points = PackedVector2Array([
		Vector2(-450.0, -96.0),
		Vector2(-372.0, -70.0),
		Vector2(-300.0, -22.0),
		Vector2(-232.0, -34.0),
		Vector2(-166.0, -78.0),
		Vector2(-104.0, -70.0),
		Vector2(-56.0, -34.0),
		Vector2(-6.0, -30.0),
		Vector2(40.0, -52.0),
		Vector2(86.0, -96.0),
		Vector2(136.0, -104.0),
		Vector2(190.0, -78.0),
		Vector2(246.0, -92.0),
		Vector2(304.0, -140.0),
		Vector2(368.0, -166.0),
		Vector2(450.0, -196.0),
	])
	river_level = RIVER_LEVEL
	# 预计算每段包围盒（含开挖外扩量）
	_river_boxes = PackedVector4Array()
	var pad := RIVER_HALF_WIDTH + RIVER_BANK + 1.0
	for i in range(river_points.size() - 1):
		var a := river_points[i]
		var b := river_points[i + 1]
		_river_boxes.append(Vector4(
			minf(a.x, b.x) - pad,
			minf(a.y, b.y) - pad,
			maxf(a.x, b.x) + pad,
			maxf(a.y, b.y) + pad))


## 点到河流中心线的最近距离（对折线逐段求投影）
func _river_distance(wx: float, wz: float) -> float:
	var best := 1.0e9
	for i in range(river_points.size() - 1):
		var a := river_points[i]
		var b := river_points[i + 1]
		var ab := b - a
		var len2 := ab.length_squared()
		var t := 0.0
		if len2 > 0.0001:
			t = clampf(((Vector2(wx, wz) - a).dot(ab)) / len2, 0.0, 1.0)
		var d := (Vector2(wx, wz) - (a + ab * t)).length()
		best = minf(best, d)
	return best


## 按中心线开挖河道：河床下沉、两岸平滑过渡，并把河床染成湿泥/卵石色。
## 必须在 height_map 生成完之后、rebuild() 之前调用。
func _carve_river() -> void:
	if height_map.is_empty() or river_points.is_empty():
		return
	var inner := RIVER_HALF_WIDTH
	var outer := RIVER_HALF_WIDTH + RIVER_BANK
	# 整条河的包围盒：整行/整列在盒外就直接跳过，避免 1024² 次距离计算
	var bmin_z := 1.0e9
	var bmax_z := -1.0e9
	for b in _river_boxes:
		bmin_z = minf(bmin_z, b.y)
		bmax_z = maxf(bmax_z, b.w)
	var z_lo := maxi(0, int(floor((bmin_z + HALF) / CELL)))
	var z_hi := mini(GRID, int(ceil((bmax_z + HALF) / CELL)))
	for z in range(z_lo, z_hi + 1):
		var wz := -HALF + z * CELL
		# 本行的河段 x 范围
		var x_lo := 1.0e9
		var x_hi := -1.0e9
		for b in _river_boxes:
			if wz < b.y or wz > b.w:
				continue
			x_lo = minf(x_lo, b.x)
			x_hi = maxf(x_hi, b.z)
		if x_lo > x_hi:
			continue
		var cx_lo := maxi(0, int(floor((x_lo + HALF) / CELL)))
		var cx_hi := mini(GRID, int(ceil((x_hi + HALF) / CELL)))
		for x in range(cx_lo, cx_hi + 1):
			var wx := -HALF + x * CELL
			var d := _river_distance(wx, wz)
			if d > outer:
				continue
			var idx := z * RESOLUTION + x
			# 0 = 河心，1 = 过渡带外缘
			var t := clampf((d - inner) / (outer - inner), 0.0, 1.0)
			var blend := t * t * (3.0 - 2.0 * t)   # smoothstep
			var bed := river_level - RIVER_BED_DROP
			# 河心压到河床，向外平滑回到原地形
			var h: float = height_map[idx]
			var target := lerpf(bed, h, blend)
			# 只下挖不抬升：避免河道在起伏地形上变成一道坝
			height_map[idx] = minf(h, target)
			color_map[idx] = _color_for_river(height_map[idx], d, wx, wz)


## 河床/河岸配色：水下湿泥 → 卵石滩 → 干草，与地形色带衔接
func _color_for_river(h: float, d: float, wx: float, wz: float) -> Color:
	var gravel := Color(0.478, 0.463, 0.412)
	var wet_mud := Color(0.333, 0.302, 0.239)
	var shallow := Color(0.416, 0.478, 0.365)
	var sand := Color(0.573, 0.533, 0.435)
	if h < river_level - 0.55:
		return wet_mud
	if h < river_level + 0.05:
		return wet_mud.lerp(shallow, clampf((h - (river_level - 0.55)) / 0.6, 0.0, 1.0))
	if h < river_level + 0.9:
		# 水线以上是一条明显的浅色卵石/沙岸，把水与草分开
			return shallow.lerp(sand, clampf((h - river_level) / 0.9, 0.0, 1.0))
	# 岸边：沙色 → 卵石 → 草地，过渡带给足宽度
	var t := clampf((d - RIVER_HALF_WIDTH) / maxf(1.0, RIVER_BANK * 0.55), 0.0, 1.0)
	var shore := sand.lerp(gravel, clampf(t * 1.6, 0.0, 1.0))
	var grass := _color_for_height(h, wx, wz)
	return shore.lerp(grass, clampf((t - 0.45) / 0.55, 0.0, 1.0))


## 地形高度：中世纪山谷
##
## 布局：中央是平坦的聚落谷地（h≈0.4m，与场景烘焙的建筑/平台高度一致），
## 向外过渡到起伏草坡，中环是森林丘陵，外环与地图边缘隆起为山脉屏障。
##
## 注意：出生点平台、全部建筑、道路都是按 h=0.4m 烘焙进 scenes/main.tscn 的，
## 所以半径 62m 内的谷底必须严格保持 0.4m；山体从 62m 外才开始抬升。
func _sample_noise_height(wx: float, wz: float) -> float:
	const PLAIN := 0.40
	# 到地图中心的径向距离（归一化到 0..1，1 = 地图边缘中点）
	var r := sqrt(wx * wx + wz * wz) / HALF
	# 谷底压平：62m 内完全平地，到 150m 平滑过渡到自然起伏
	var flat := smoothstep(62.0, 150.0, r * HALF)
	# 山脊权重：山噪声大于 0.04 的地方起山，越靠边越容易起山
	var m := _mountain_noise.get_noise_2d(wx, wz)
	m = m * lerpf(0.65, 1.45, clampf(r * 1.15, 0.0, 1.0))
	var ridge := smoothstep(0.04, 0.72, m)
	# 边缘抬升：接近地图边界时整体抬高，形成合围的山脉屏障
	var rim := smoothstep(240.0, 452.0, r * HALF)
	var hills := (_hill_noise.get_noise_2d(wx, wz) * 0.5 + 0.5) * 5.2
	var mountains := pow(ridge, 1.8) * 52.0 + rim * rim * 38.0
	var detail := _detail_noise.get_noise_2d(wx, wz) * 0.32
	return PLAIN + flat * (hills + mountains + detail)

## 中世纪低多边形配色：按海拔 + 坡度 + 斑块分层，色带干净不脏。
##
## 分带（对应 _sample_noise_height 的地貌）：
##   < 1.2   谷地草地   明亮草绿，聚落所在
##   1.2~6   缓坡草甸   偏黄绿的干草色
##   6~22    森林土坡   土棕 + 苔绿混合
##   22~42   裸岩高地   冷灰岩
##   > 42    山顶       积雪白，只在地图边缘山脉出现
func _color_for_height(h: float, wx: float, wz: float) -> Color:
	var c: Color
	if h < 1.2:
		c = Color(0.298, 0.478, 0.235)          # 谷地草地（饱和偏深的草绿）
	elif h < 7.0:
		c = Color(0.298, 0.478, 0.235).lerp(Color(0.427, 0.533, 0.259), smoothstep(1.2, 7.0, h))
	elif h < 24.0:
		c = Color(0.427, 0.533, 0.259).lerp(Color(0.310, 0.365, 0.212), smoothstep(7.0, 24.0, h))
	elif h < 52.0:
		c = Color(0.310, 0.365, 0.212).lerp(Color(0.451, 0.439, 0.404), smoothstep(24.0, 52.0, h))
	elif h < 68.0:
		c = Color(0.451, 0.439, 0.404).lerp(Color(0.573, 0.573, 0.573), smoothstep(52.0, 68.0, h))
	else:
		c = Color(0.573, 0.573, 0.573).lerp(Color(0.902, 0.925, 0.949), smoothstep(68.0, 88.0, h))
	# 草甸斑块：两层不同频率的噪声叠加，做出细碎的草色变化而不是大色块
	var p1 := _detail_noise.get_noise_2d(wx * 0.6 + 11.0, wz * 0.6 + 11.0)
	var p2 := _hill_noise.get_noise_2d(wx * 2.2 + 90.0, wz * 2.2 + 90.0)
	if h < 10.0:
		var pv := p1 * 0.55 + p2 * 0.45
		if pv > 0.2:
			c = c.lerp(Color(0.451, 0.596, 0.278), clampf((pv - 0.2) * 1.3, 0.0, 0.30))
		elif pv < -0.22:
			c = c.lerp(Color(0.235, 0.396, 0.243), clampf((-pv - 0.22) * 1.4, 0.0, 0.30))
	# 裸岩露头：陡坡/高处按噪声点缀岩石色
	var rock_n := _noise.get_noise_2d(wx * 0.9 + 7.0, wz * 0.9 + 7.0)
	if h > 12.0 and rock_n > 0.10:
		c = c.lerp(Color(0.478, 0.463, 0.435), clampf((rock_n - 0.10) * 1.9, 0.0, 0.85))
	return c

## 获取指定世界坐标的地形高度（含插值）
func get_height_at(wx: float, wz: float) -> float:
	if height_map.is_empty():
		return 0.0
	var fx := clampf((wx + HALF) / CELL, 0.0, float(GRID))
	var fz := clampf((wz + HALF) / CELL, 0.0, float(GRID))
	var x0 := int(fx); var z0 := int(fz)
	var x1 := mini(x0 + 1, GRID); var z1 := mini(z0 + 1, GRID)
	var tx := fx - x0; var tz := fz - z0
	var h00 := height_map[z0 * RESOLUTION + x0]
	var h10 := height_map[z0 * RESOLUTION + x1]
	var h01 := height_map[z1 * RESOLUTION + x0]
	var h11 := height_map[z1 * RESOLUTION + x1]
	var h0 := lerpf(h00, h10, tx)
	var h1 := lerpf(h01, h11, tx)
	return lerpf(h0, h1, tz)

## 将圆形区域地形整平到指定高度（用于出生点/基地平台，避免起伏遮挡视野）
func flatten_region(center: Vector3, radius: float, target_h: float) -> void:
	if height_map.is_empty():
		return
	var cx := center.x; var cz := center.z
	var r2 := radius * radius
	var start_x := maxi(0, int((cx - radius + HALF) / CELL))
	var end_x := mini(GRID, int((cx + radius + HALF) / CELL) + 1)
	var start_z := maxi(0, int((cz - radius + HALF) / CELL))
	var end_z := mini(GRID, int((cz + radius + HALF) / CELL) + 1)
	for z in range(start_z, end_z + 1):
		for x in range(start_x, end_x + 1):
			var wx := -HALF + x * CELL
			var wz := -HALF + z * CELL
			var dx := wx - cx; var dz := wz - cz
			var d2 := dx * dx + dz * dz
			if d2 > r2:
				continue
			var idx := z * RESOLUTION + x
			height_map[idx] = target_h
			color_map[idx] = _color_for_height(target_h, wx, wz)
	_last_brush_time = Time.get_ticks_msec()
	_mark_dirty(center, radius)

func apply_brush(world_pos: Vector3, radius: float, delta: float) -> void:
	if height_map.is_empty():
		return
	var cx := world_pos.x; var cz := world_pos.z
	var r2 := radius * radius
	var start_x := maxi(0, int((cx - radius + HALF) / CELL))
	var end_x := mini(GRID, int((cx + radius + HALF) / CELL) + 1)
	var start_z := maxi(0, int((cz - radius + HALF) / CELL))
	var end_z := mini(GRID, int((cz + radius + HALF) / CELL) + 1)
	for z in range(start_z, end_z + 1):
		for x in range(start_x, end_x + 1):
			var wx := -HALF + x * CELL
			var wz := -HALF + z * CELL
			var dx := wx - cx; var dz := wz - cz
			var d2 := dx * dx + dz * dz
			if d2 > r2:
				continue
			# 平滑衰减
			var falloff := 1.0 - smoothstep(0.0, radius, sqrt(d2))
			var idx := z * RESOLUTION + x
			var new_h := height_map[idx] + delta * falloff
			# 无限下陷：下限放宽到 -100m（上限 8m 防飞天），可挖出任意深坑
			height_map[idx] = clampf(new_h, -100.0, 60.0)
			color_map[idx] = _color_for_height(height_map[idx], wx, wz)
	# 轻量局部平滑：抹平抬升叠加产生的"山尖尖"，让地形变化圆润
	_smooth_region(start_x, end_x, start_z, end_z)
	_last_brush_time = Time.get_ticks_msec()
	_mark_dirty(world_pos, radius)

## 轻量局部平滑：对刷地区域做 alpha 混合邻域均值，抹平单格尖峰（山尖尖）
## 仅混合快照内数据，区域边缘 clamp 到区域边界，避免与区域外高度串扰
func _smooth_region(start_x: int, end_x: int, start_z: int, end_z: int) -> void:
	if end_x <= start_x or end_z <= start_z:
		return
	var w := end_x - start_x + 1
	var h := end_z - start_z + 1
	var snap := PackedFloat32Array()
	snap.resize(w * h)
	for z in range(start_z, end_z + 1):
		for x in range(start_x, end_x + 1):
			snap[(z - start_z) * w + (x - start_x)] = height_map[z * RESOLUTION + x]
	const ALPHA := 0.4
	const ITER := 1
	for _it in ITER:
		for z in range(start_z, end_z + 1):
			for x in range(start_x, end_x + 1):
				var acc := 0.0
				var cnt := 0
				for dz in range(-1, 2):
					for dx in range(-1, 2):
						var zz := clampi(z + dz, start_z, end_z)
						var xx := clampi(x + dx, start_x, end_x)
						acc += snap[(zz - start_z) * w + (xx - start_x)]
						cnt += 1
				var idx := z * RESOLUTION + x
				snap[(z - start_z) * w + (x - start_x)] = lerpf(snap[(z - start_z) * w + (x - start_x)], acc / float(cnt), ALPHA)
				height_map[idx] = snap[(z - start_z) * w + (x - start_x)]
				color_map[idx] = _color_for_height(height_map[idx], -HALF + x * CELL, -HALF + z * CELL)

## 标记需要重建（节流合并：网格 0.1s 内合并，碰撞 0.35s 内合并；记录刷地范围用于局部重建）
func _mark_dirty(center: Vector3 = Vector3.ZERO, radius: float = 0.0) -> void:
	_mesh_dirty = true
	_collision_dirty = true
	_mesh_timer = MESH_REBUILD_DELAY
	_collision_timer = COLLISION_REBUILD_DELAY
	_last_brush_center = center
	_last_brush_radius = radius

func _process(delta: float) -> void:
	_mesh_timer -= delta
	_collision_timer -= delta
	if _mesh_dirty and _mesh_timer <= 0.0:
		_mesh_dirty = false
		if _last_brush_radius > 0.0:
			rebuild_mesh_around(_last_brush_center, _last_brush_radius + CELL * 2.0)
		else:
			rebuild_mesh()
	if _collision_dirty and _collision_timer <= 0.0:
		_collision_dirty = false
		rebuild_collision()

## 重建地形（初始生成/多处刷平后全量重建网格+碰撞；同时清空节流标记，避免 _process 重复局部重建）
func rebuild() -> void:
	_mesh_dirty = false
	_collision_dirty = false
	rebuild_mesh()
	rebuild_collision()

## 重建全部地形网格块（初始生成时调用）
func rebuild_mesh() -> void:
	if height_map.is_empty() or chunk_meshes.is_empty():
		return
	for ci in chunk_meshes.size():
		_build_chunk(ci % CHUNKS, ci / CHUNKS)

## 只重建刷地范围覆盖的网格块（局部更新，避免全量重建）
func rebuild_mesh_around(center: Vector3, radius: float) -> void:
	if height_map.is_empty() or chunk_meshes.is_empty():
		return
	var gx := clampi(int((center.x + HALF) / CELL), 0, GRID)
	var gz := clampi(int((center.z + HALF) / CELL), 0, GRID)
	var gr := int(ceil(radius / CELL)) + 1
	var cbx0 := clampi((gx - gr) / CHUNK_GRID, 0, CHUNKS - 1)
	var cbx1 := clampi((gx + gr) / CHUNK_GRID, 0, CHUNKS - 1)
	var cbz0 := clampi((gz - gr) / CHUNK_GRID, 0, CHUNKS - 1)
	var cbz1 := clampi((gz + gr) / CHUNK_GRID, 0, CHUNKS - 1)
	for cbz in range(cbz0, cbz1 + 1):
		for cbx in range(cbx0, cbx1 + 1):
			_build_chunk(cbx, cbz)

## 构建单个网格块（批量数组构造 + 中心差分法线）
## 面片色彩微调：按世界坐标做**平滑**噪声采样。
##
## 曾经按网格下标 (x,z) 做 hash 取随机明度 —— 结果每格独立随机，
## 从天上/远处看就是一整片规则的**棋盘格**。改成噪声场后才是柔和的手绘色块。
## 幅度也必须小：±6% 明度 + ±3% 冷暖，只是打散大平面，不能变成花纹。
## x = 明度系数，y = 冷暖偏移(-0.5..0.5)
func _facet_variation(wx: float, wz: float) -> Vector2:
	var n := _facet_noise.get_noise_2d(wx, wz)
	var m := _facet_noise.get_noise_2d(wx + 137.0, wz - 91.0)
	return Vector2(1.0 + clampf(n, -1.0, 1.0) * 0.06, clampf(m, -1.0, 1.0) * 0.5)


## 按面片系数微调一个顶点色：明度缩放 + 极轻的冷暖偏移
func _facet_tint(c: Color, scale: float, warm: float) -> Color:
	return Color(
		clampf(c.r * scale * (1.0 + warm * 0.03), 0.0, 1.0),
		clampf(c.g * scale, 0.0, 1.0),
		clampf(c.b * scale * (1.0 - warm * 0.03), 0.0, 1.0),
		c.a)


func _build_chunk(cbx: int, cbz: int) -> void:

	var x_start := cbx * CHUNK_GRID
	var z_start := cbz * CHUNK_GRID
	var x_end := x_start + CHUNK_GRID
	var z_end := z_start + CHUNK_GRID
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var tri_count := CHUNK_GRID * CHUNK_GRID * 6
	verts.resize(tri_count)
	norms.resize(tri_count)
	cols.resize(tri_count)
	var vi := 0
	for z in range(z_start, z_end):
		for x in range(x_start, x_end):
			var i00 := z * RESOLUTION + x
			var i10 := z * RESOLUTION + x + 1
			var i01 := (z + 1) * RESOLUTION + x
			var i11 := (z + 1) * RESOLUTION + x + 1
			var p00 := Vector3(-HALF + x * CELL, height_map[i00], -HALF + z * CELL)
			var p10 := Vector3(-HALF + (x + 1) * CELL, height_map[i10], -HALF + z * CELL)
			var p01 := Vector3(-HALF + x * CELL, height_map[i01], -HALF + (z + 1) * CELL)
			var p11 := Vector3(-HALF + (x + 1) * CELL, height_map[i11], -HALF + (z + 1) * CELL)
			# 中心差分法线近似（每格 1 次，替代 2 次叉积）
			var dh_dx := (height_map[i10] - height_map[i00] + height_map[i11] - height_map[i01]) * 0.5 / CELL
			var dh_dz := (height_map[i01] - height_map[i00] + height_map[i11] - height_map[i10]) * 0.5 / CELL
			var n := Vector3(-dh_dx, 1.0, -dh_dz).normalized()
			var c00 := color_map[i00]; var c10 := color_map[i10]
			var c01 := color_map[i01]; var c11 := color_map[i11]
			# 低多边形手绘感：每个面片按网格坐标做一次确定性微调（明度 + 轻微冷暖偏移）。
			# 网格本身是 flat-shaded，整面同色，所以这点面片级差异就能把一大片死绿
			# 打散成手绘色块拼贴的观感 —— 这是 poly 风格最关键的廉价技巧。
			# 用 hash 而不是随机数：同一坐标每次重建得到同一颜色，刷地重建不会闪烁。
			# 每个顶点取自己位置上的噪声值：平滑过渡，又保留面片内的细微差异
			var f00 := _facet_variation(p00.x, p00.z)
			var f10 := _facet_variation(p10.x, p10.z)
			var f01 := _facet_variation(p01.x, p01.z)
			var f11 := _facet_variation(p11.x, p11.z)
			c00 = _facet_tint(c00, f00.x, f00.y); c10 = _facet_tint(c10, f10.x, f10.y)
			c01 = _facet_tint(c01, f01.x, f01.y); c11 = _facet_tint(c11, f11.x, f11.y)
			verts[vi] = p00; norms[vi] = n; cols[vi] = c00; vi += 1
			verts[vi] = p01; norms[vi] = n; cols[vi] = c01; vi += 1
			verts[vi] = p10; norms[vi] = n; cols[vi] = c10; vi += 1
			verts[vi] = p10; norms[vi] = n; cols[vi] = c10; vi += 1
			verts[vi] = p01; norms[vi] = n; cols[vi] = c01; vi += 1
			verts[vi] = p11; norms[vi] = n; cols[vi] = c11; vi += 1
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	chunk_meshes[cbz * CHUNKS + cbx].mesh = m

## 某个世界坐标是否落在河里（用于把植被从河道里清掉）
func is_in_river(wx: float, wz: float) -> bool:
	if river_points.is_empty():
		return false
	return _river_distance(wx, wz) < RIVER_HALF_WIDTH - 0.3


## 水面：沿中心线扫出的带状网格，顶面在 river_level。
## 单独一个 MeshInstance3D（不参与地形 chunk 重建），材质是流动的水着色器。
func rebuild_river_mesh() -> void:
	if river_points.size() < 2:
		return
	if river_mesh == null:
		river_mesh = MeshInstance3D.new()
		river_mesh.name = "River"
		add_child(river_mesh)

	# ---- 1. 把折线超采样成平滑曲线 ----
	# 直接拿控制点扫带状网格的话，转弯处采样太稀 —— 直边切过弯道，
	# 水面会露出硬邦邦的折线边界（试玩截图里非常明显）。
	var pts := _river_polyline(6)
	var n := pts.size()

	# ---- 2. 已开挖河道的真实半宽：由地形高度场反查，而不是假定等于 RIVER_HALF_WIDTH ----
	# 地形是按 smoothstep(d) 开挖的，d 处河床高度 = lerp(bed, 原高, blend)。
	# 这里取"地面刚好回到水面高度"的那个 d 作为水面半宽，水面就永远盖住河床。
	var w_sum := 0.0
	for i in n:
		w_sum += _river_bed_halfwidth_at(pts[i])
	var half_w := w_sum / float(maxi(1, n))

	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var run := 0.0
	var prev := Vector3.ZERO
	for i in n:
		var p: Vector2 = pts[i]
		var t0: Vector2 = pts[maxi(i - 1, 0)]
		var t1: Vector2 = pts[mini(i + 1, n - 1)]
		var tangent := (t1 - t0)
		if tangent.length_squared() < 0.000001:
			tangent = Vector2.RIGHT
		tangent = tangent.normalized()
		var side := Vector2(-tangent.y, tangent.x)
		var cur := Vector3(p.x, river_level, p.y)
		if i > 0:
			run += cur.distance_to(prev)
		prev = cur
		# 水面横向铺到 half_w，边缘再抬高一点点做出一层薄岸，遮住硬边
		for k in 3:
			var off: float
			var lift: float
			match k:
				0:
					off = -half_w
					lift = 0.0
				1:
					off = 0.0
					lift = 0.0
				_:
					off = half_w
					lift = 0.0
			var q := p + side * off
			verts.append(Vector3(q.x, river_level + lift, q.y))
			norms.append(Vector3.UP)
			uvs.append(Vector2(float(k) * 0.5, run * 0.05))
	for i in n - 1:
		var b := i * 3
		for k in 2:
			indices.append(b + k)
			indices.append(b + k + 1)
			indices.append(b + 3 + k)
			indices.append(b + k + 1)
			indices.append(b + 4 + k)
			indices.append(b + 3 + k)

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://assets/shaders/river_water.gdshader")
	mat.set_shader_parameter("water_color", Color(0.239, 0.475, 0.541))
	mat.set_shader_parameter("deep_color", Color(0.098, 0.278, 0.333))
	mat.set_shader_parameter("alpha", 0.68)
	m.surface_set_material(0, mat)
	river_mesh.mesh = m
	river_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 不再单独给河底做碰撞：河道是把地形高度图挖下去的，地形 HeightMapShape3D
	# 本身就提供了河床地面。之前额外铺的一层薄盒子会和地形碰撞重叠成夹层，
	# 角色一旦进去就卡在板下出不来。


## 把控制点折线按每段 subdiv 段做 Catmull-Rom 平滑，返回采样点。
func _river_polyline(subdiv: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	var m := river_points.size()
	if m < 2:
		return out
	for i in range(m - 1):
		var p0: Vector2 = river_points[maxi(i - 1, 0)]
		var p1: Vector2 = river_points[i]
		var p2: Vector2 = river_points[i + 1]
		var p3: Vector2 = river_points[mini(i + 2, m - 1)]
		for j in subdiv:
			var t := float(j) / float(subdiv)
			var t2 := t * t
			var t3 := t2 * t
			var q := 0.5 * ((2.0 * p1)
					+ (-p0 + p2) * t
					+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
					+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
			out.append(q)
	out.append(river_points[m - 1])
	return out


## 河道横断面：在离中心线 d 处，地形被挖到的深度。
## 与原地形高度无关的部分（开挖量）只取决于 d，所以这里用谷底基准估算，
## 再用它反推"地面重新高过水面"的那个 d，作为水面半宽。
func _river_bed_halfwidth_at(center: Vector2) -> float:
	var inner := RIVER_HALF_WIDTH
	var outer := RIVER_HALF_WIDTH + RIVER_BANK
	var bed := river_level - RIVER_BED_DROP
	var plain := 0.40
	# 逐步外扩找水面与河床的交叉点
	var lo := inner * 0.5
	var hi := outer
	for _k in 24:
		var mid := (lo + hi) * 0.5
		var t := clampf((mid - inner) / (outer - inner), 0.0, 1.0)
		var blend := t * t * (3.0 - 2.0 * t)
		var h := lerpf(bed, plain, blend)
		if h < river_level:
			lo = mid
		else:
			hi = mid
	# 加一点余量盖住 mesh 离散化误差
	return lo + 0.35


## 水底碰撞：每条河段一个薄长方体，避免玩家掉进河道后穿到地图下面。
func _rebuild_river_collision() -> void:
	if river_collision != null and is_instance_valid(river_collision):
		river_collision.queue_free()
	river_collision = StaticBody3D.new()
	river_collision.name = "RiverBed"
	river_collision.collision_layer = 2
	river_collision.collision_mask = 0
	add_child(river_collision)
	for i in range(river_points.size() - 1):
		var a := river_points[i]
		var b := river_points[i + 1]
		var len := a.distance_to(b)
		if len < 0.01:
			continue
		var mid := (a + b) * 0.5
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(RIVER_HALF_WIDTH * 2.0, 1.0, len + 1.0)
		cs.shape = box
		cs.position = Vector3(mid.x, river_level - 0.5, mid.y)
		var ang := atan2(b.x - a.x, b.y - a.y)
		cs.rotation = Vector3(0.0, ang, 0.0)
		river_collision.add_child(cs)


## 重建地形碰撞（内联双线性采样；采样间隔 2m，碰撞体 XZ 放大 2 倍覆盖 900m，Y 不变）
func rebuild_collision() -> void:
	if height_map.is_empty():
		return
	var col_shape := collision_body.get_node("TerrainCollision") as CollisionShape3D
	if col_shape == null:
		return
	const STEP := 1.5
	var S := int(SIZE / STEP) + 1
	var data := PackedFloat32Array()
	data.resize(S * S)
	for z in S:
		var wz := -HALF + float(z) * STEP
		var fz := clampf((wz + HALF) / CELL, 0.0, float(GRID))
		var z0 := int(fz); var z1 := mini(z0 + 1, GRID)
		var tz := fz - z0
		var row0 := z0 * RESOLUTION
		var row1 := z1 * RESOLUTION
		for x in S:
			var wx := -HALF + float(x) * STEP
			var fx := clampf((wx + HALF) / CELL, 0.0, float(GRID))
			var x0 := int(fx); var x1 := mini(x0 + 1, GRID)
			var tx := fx - x0
			var h00 := height_map[row0 + x0]
			var h10 := height_map[row0 + x1]
			var h01 := height_map[row1 + x0]
			var h11 := height_map[row1 + x1]
			var h0 := lerpf(h00, h10, tx)
			var h1 := lerpf(h01, h11, tx)
			data[z * S + x] = lerpf(h0, h1, tz)
	var hm := HeightMapShape3D.new()
	hm.map_width = S
	hm.map_depth = S
	hm.map_data = data
	# 新建 shape 实例替换以触发物理服务器更新（直接改 map_data 不生效）
	col_shape.shape = hm
	mesh_instance.position = Vector3.ZERO

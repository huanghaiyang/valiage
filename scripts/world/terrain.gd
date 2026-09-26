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
var _noise: FastNoiseLite

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
	_noise.seed = randi()
	# 地图放大后适当降低频率：山丘波长随地图一起放大，保持"同一个山谷"的开阔感
	_noise.frequency = 0.006
	_noise.fractal_octaves = 4
	_noise.fractal_gain = 0.5
	_noise.fractal_lacunarity = 2.0
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH

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
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	mesh_instance.material_override = mat
	# 分块网格实例（7×7 块，共享同一材质，刷地只重建受影响块）
	for ci in CHUNKS * CHUNKS:
		var mi := MeshInstance3D.new()
		mi.name = "TerrainChunk_%d" % ci
		mi.material_override = mat
		mesh_instance.add_child(mi)
		chunk_meshes.append(mi)

func generate(seed_value: int = -1) -> void:
	if seed_value >= 0:
		_noise.seed = seed_value
	height_map.resize(RESOLUTION * RESOLUTION)
	color_map.resize(RESOLUTION * RESOLUTION)
	for z in RESOLUTION:
		for x in RESOLUTION:
			var wx := -HALF + x * CELL
			var wz := -HALF + z * CELL
			var h := _sample_noise_height(wx, wz)
			height_map[z * RESOLUTION + x] = h
			color_map[z * RESOLUTION + x] = _color_for_height(h, wx, wz)
	rebuild()

func _sample_noise_height(wx: float, wz: float) -> float:
	# 大尺度区域噪声：划分开阔平原带与低矮丘陵带（参考复古战棋大地图的分层地形）
	var region := _noise.get_noise_2d(wx * 0.0022 + 31.7, wz * 0.0022 + 31.7)
	var hill_w := smoothstep(-0.55, 0.75, region)
	var h := _noise.get_noise_2d(wx, wz)
	# 平原带起伏平缓（开阔草地），丘陵带起伏明显（低矮丘陵），振幅随区域权重过渡
	var amp := lerpf(0.35, 1.25, hill_w)
	# 边缘压低，形成山谷盆地感；整体压低起伏，避免地形起伏掩盖建筑
	var edge := clampf(1.0 - (absf(wx) / HALF + absf(wz) / HALF) * 0.5, 0.0, 1.0)
	return h * amp * edge + 0.4

func _color_for_height(h: float, wx: float, wz: float) -> Color:
	# 黄绿混染做旧配色（复古战棋大地图）：低处深橄榄绿湿地，中部黄绿草地，高处橄榄黄丘陵
	var c := Color(0.48, 0.58, 0.14)
	if h < 0.35:
		c = Color(0.32, 0.42, 0.16)
	elif h < 0.9:
		c = Color(0.48, 0.58, 0.14)
	elif h < 1.5:
		c = Color(0.62, 0.62, 0.14)
	else:
		c = Color(0.64, 0.68, 0.22)
	# 岩石点缀：高海拔区域出现灰岩（暖灰，融入做旧色调）
	var rock_n := _noise.get_noise_2d(wx * 1.6 + 7.0, wz * 1.6 + 7.0)
	if h > 1.6 and rock_n > 0.28:
		c = c.lerp(Color(0.60, 0.60, 0.52), clampf((rock_n - 0.28) * 2.2, 0.0, 0.75))
	# 草地斑块：低频噪声产生亮黄绿草色变化（参考图草灌铺底的明暗斑驳）
	var patch := _noise.get_noise_2d(wx * 0.3 + 50.0, wz * 0.3 + 50.0)
	if patch > 0.35:
		c = c.lerp(Color(0.56, 0.66, 0.16), clampf((patch - 0.35) * 1.8, 0.0, 0.45))
	# 边缘暗化：接近地图边界时压暗（参考图边缘深灰云雾的未探索感）
	var edgef := clampf(1.0 - (absf(wx) / HALF + absf(wz) / HALF) * 0.5, 0.0, 1.0)
	if edgef < 0.8:
		c = c.lerp(Color(0.24, 0.30, 0.20), minf((0.8 - edgef) * 1.8, 0.85))
	# 轻微做旧噪声扰动（暖黄倾向），避免单调
	var jitter := _noise.get_noise_2d(wx * 2.0 + 100.0, wz * 2.0 + 100.0) * 0.03
	c.r += jitter; c.g += jitter * 0.8; c.b += jitter * 0.3
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
			height_map[idx] = clampf(new_h, -100.0, 8.0)
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

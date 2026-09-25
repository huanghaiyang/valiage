class_name TerrainSystem
extends Node3D
## 可编辑地形系统
## 使用高度图 + 程序化网格，支持抬升/下陷/平整刷子
## 面积较初版扩大 20 倍：边长 200m → 900m（面积 40000 → 810000 m²），分辨率同步提高保持细节

const SIZE := 900.0          # 地形总尺寸（米），面积约为原版 20 倍
const RESOLUTION := 512      # 网格分辨率（顶点数），保持约 1.76m/格的地形细节
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

var _dirty := true

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
	# HeightMapShape3D 网格以 CollisionShape3D origin 为中心，采样点间隔 1 单位
	# map_width=SIZE+1 覆盖 [-HALF, HALF]，直接对齐地形网格
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
	var h := _noise.get_noise_2d(wx, wz)
	# 边缘压低，形成山谷盆地感；整体压低起伏，避免地形起伏掩盖建筑
	var edge := clampf(1.0 - (absf(wx) / HALF + absf(wz) / HALF) * 0.5, 0.0, 1.0)
	return h * 1.0 * edge + 0.4

func _color_for_height(h: float, wx: float, wz: float) -> Color:
	# 卡通分层配色：低处深绿草地，高处浅绿（更饱和，避免与天空地平线混成一片）
	var c := Color(0.34, 0.60, 0.24)
	if h < 0.4:
		c = Color(0.28, 0.48, 0.30)
	elif h < 1.2:
		c = Color(0.37, 0.64, 0.26)
	else:
		c = Color(0.50, 0.70, 0.30)
	# 岩石点缀：高海拔区域出现灰岩
	var rock_n := _noise.get_noise_2d(wx * 1.6 + 7.0, wz * 1.6 + 7.0)
	if h > 1.8 and rock_n > 0.28:
		c = c.lerp(Color(0.56, 0.57, 0.53), clampf((rock_n - 0.28) * 2.2, 0.0, 0.75))
	# 草地斑块：低频噪声产生明暗草色变化
	var patch := _noise.get_noise_2d(wx * 0.3 + 50.0, wz * 0.3 + 50.0)
	if patch > 0.35:
		c = c.lerp(Color(0.46, 0.72, 0.26), clampf((patch - 0.35) * 1.8, 0.0, 0.45))
	# 轻微噪声扰动，避免单调
	var jitter := _noise.get_noise_2d(wx * 2.0 + 100.0, wz * 2.0 + 100.0) * 0.03
	c.r += jitter; c.g += jitter; c.b += jitter * 0.5
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
	_dirty = true

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
			height_map[idx] = clampf(new_h, -1.0, 8.0)
			color_map[idx] = _color_for_height(height_map[idx], wx, wz)
	_dirty = true

func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		rebuild()

## 重建地形网格
func rebuild() -> void:
	if height_map.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for z in GRID:
		for x in GRID:
			var i00 := z * RESOLUTION + x
			var i10 := z * RESOLUTION + x + 1
			var i01 := (z + 1) * RESOLUTION + x
			var i11 := (z + 1) * RESOLUTION + x + 1
			var p00 := Vector3(-HALF + x * CELL, height_map[i00], -HALF + z * CELL)
			var p10 := Vector3(-HALF + (x + 1) * CELL, height_map[i10], -HALF + z * CELL)
			var p01 := Vector3(-HALF + x * CELL, height_map[i01], -HALF + (z + 1) * CELL)
			var p11 := Vector3(-HALF + (x + 1) * CELL, height_map[i11], -HALF + (z + 1) * CELL)
			var n1 := (p01 - p00).cross(p10 - p00).normalized()
			var n2 := (p01 - p10).cross(p11 - p10).normalized()
			var c00 := color_map[i00]; var c10 := color_map[i10]
			var c01 := color_map[i01]; var c11 := color_map[i11]
			st.set_color(c00); st.set_normal(n1); st.add_vertex(p00)
			st.set_color(c01); st.set_normal(n1); st.add_vertex(p01)
			st.set_color(c10); st.set_normal(n1); st.add_vertex(p10)
			st.set_color(c10); st.set_normal(n2); st.add_vertex(p10)
			st.set_color(c01); st.set_normal(n2); st.add_vertex(p01)
			st.set_color(c11); st.set_normal(n2); st.add_vertex(p11)
	var mesh := st.commit()
	mesh_instance.mesh = mesh

	# 更新碰撞：新建 HeightMapShape3D 实例并替换 shape（触发物理服务器更新，避免直接改 map_data 不生效）
	# HeightMapShape3D 采样间隔固定 1 单位，覆盖 900m 需要 901×901 采样点
	var col_shape := collision_body.get_node("TerrainCollision") as CollisionShape3D
	if col_shape != null:
		var hm := HeightMapShape3D.new()
		var S := int(SIZE) + 1
		hm.map_width = S
		hm.map_depth = S
		var data := PackedFloat32Array()
		data.resize(S * S)
		for z in S:
			for x in S:
				data[z * S + x] = get_height_at(-HALF + float(x), -HALF + float(z))
		hm.map_data = data
		col_shape.shape = hm
	mesh_instance.position = Vector3.ZERO

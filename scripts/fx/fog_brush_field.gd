@tool
class_name FogBrushField
extends Resource
## ============================================================================
## fog_brush_field.gd —— **雾气笔刷的画笔数据**（一张可保存、可复现的浓度底图）
## ============================================================================
## 【职责】存"手刷出来的雾"：一张 grid_size.x × grid_size.y 的浓度网格（0..1）。
##   它不渲染、不知道世界坐标，只负责数据 + 纯函数笔刷运算 —— 于是：
##     · 插件（addons/fog_brush）在编辑器里刷它；
##     · FogField 在运行时把它当"雾的吸引子"喂给流体求解器（见 ns_advect_density.gdshader）；
##     · 测试可以直接 new() 出来验证笔刷数学，不需要编辑器也不需要 GPU。
##
## 【为什么画笔数据不是"直接一张贴图"】
##   画笔运算（高斯衰减、平滑、擦除、笔画插值）都在**浮点网格**上做，精度和边界行为明确；
##   想给美术看/想用外部工具改，再 `save_to_png()` 导出一张 PNG。
##   资源里默认只存 PNG **路径**（`image_path`），场景文件因此保持很小；
##   只有显式写了 `data` 时才会内联保存（调试/小网格时方便）。
##
## 【坐标系】网格 (i, j)：i 沿 +x（世界的 +X），j 沿 +y（世界的 +Z）。
##   域坐标 uv ∈ [0,1]²，单元中心 = (i+0.5)/n —— 与求解器/着色器同一套约定。
##
## 【对外接口】
##   · grid_size / data / image_path              （导出字段）
##   · ensure_data() / has_data() / clear() / fill(value)
##   · sample_uv(uv) -> float                     采样（双线性，越界钳边）
##   · to_image() / apply_image(img)              与 Image 互转
##   · save_to_png(path) / load_from_png(path)    PNG 落盘 / 读回
##   · to_texture() -> Texture2D                  给材质用的缓存纹理
##   · 静态纯函数：falloff / apply_stamp / apply_stroke / index_of
##
## 【已知的坑】
##   1. `data` 为空时**不能**当成"全 0 网格"以外的东西：空数组 + 非零 value 采样会报越界，
##      所以所有采样入口都先 ensure_data()。
##   2. grid_size 改小/改大后必须 ensure_data() 重建，否则旧数据长度与新尺寸不匹配
##      （症状：刷出来的图案整体错位、像被剪切过）。
##   3. 平滑模式需要一份原始数据的拷贝做邻域平均（就地读写会让结果依赖遍历顺序，
##      东边和西边刷出来不一样）—— apply_stamp 内部已处理。
## ============================================================================

## 是否把 PNG 读到内存后自动清空 data（默认 false：加载后 data 也可用）
const DEFAULT_GRID_SIZE := Vector2i(96, 96)

enum Mode {
	PAINT,    ## 加雾
	ERASE,    ## 擦雾
	SMOOTH,   ## 抹平（柔化边缘）
}

## 网格尺寸（宽=沿世界 X，高=沿世界 Z）
@export var grid_size: Vector2i = DEFAULT_GRID_SIZE
## 浓度数据（长度 = grid_size.x * grid_size.y，行优先）。为空表示"用 image_path 那张 PNG"。
@export var data: PackedFloat32Array = PackedFloat32Array()
## PNG 资产路径（res:// 或 user://）。画笔每次落笔结束会写这里，运行时从这里读。
@export var image_path: String = ""

var _texture: ImageTexture
var _texture_dirty := true


# =========================================================
# 数据管理
# =========================================================

## 保证 data 长度与 grid_size 一致（不一致就重建为全 0）。
func ensure_data() -> void:
	var expected := maxi(1, grid_size.x) * maxi(1, grid_size.y)
	if data.size() == expected:
		return
	data = PackedFloat32Array()
	data.resize(expected)
	data.fill(0.0)
	_texture_dirty = true


func has_data() -> bool:
	return data.size() == maxi(1, grid_size.x) * maxi(1, grid_size.y) and data.size() > 0


func clear() -> void:
	ensure_data()
	data.fill(0.0)
	_texture_dirty = true


func fill(value: float) -> void:
	ensure_data()
	data.fill(clampf(value, 0.0, 1.0))
	_texture_dirty = true


## 下标：i 沿 x、j 沿 y，行优先（与 Image 的行序一致，方便直接互转）。
func index_of(i: int, j: int) -> int:
	return j * maxi(1, grid_size.x) + i


## 单元中心采样的双线性取值（越界按 clamp-to-edge）。返回值 0..1。
func sample_uv(uv: Vector2) -> float:
	ensure_data()
	var width := maxi(1, grid_size.x)
	var height := maxi(1, grid_size.y)
	var cell := Vector2(uv.x * float(width) - 0.5, uv.y * float(height) - 0.5)
	var x := clampf(cell.x, 0.0, float(width - 1))
	var y := clampf(cell.y, 0.0, float(height - 1))
	var i0 := int(floor(x))
	var j0 := int(floor(y))
	var i1 := mini(i0 + 1, width - 1)
	var j1 := mini(j0 + 1, height - 1)
	var fx := x - float(i0)
	var fy := y - float(j0)
	var v00 := data[j0 * width + i0]
	var v10 := data[j0 * width + i1]
	var v01 := data[j1 * width + i0]
	var v11 := data[j1 * width + i1]
	return lerpf(lerpf(v00, v10, fx), lerpf(v01, v11, fx), fy)


## 总浓度（诊断/测试用）。
func total() -> float:
	ensure_data()
	var sum := 0.0
	for value in data:
		sum += value
	return sum


# =========================================================
# 笔刷运算（纯静态；插件与测试共用同一份定义）
# =========================================================

## 笔刷衰减：d=0 时 1，d>=radius 时 0。
## hardness 0..1：0 = 很软的羽化边（指数 4），1 = 接近硬边（指数 0.15）。
## 指数越大中心越"尖"、边缘越快衰减；取 pow 而不是 smoothstep 是为了让
## "半径内的总投入量"随 hardness 连续变化（美术调参时手感更一致）。
static func falloff(distance: float, radius: float, hardness: float) -> float:
	if radius <= 0.0:
		return 0.0
	if distance >= radius:
		return 0.0
	var exponent := maxf(0.15, 4.0 - 3.5 * clampf(hardness, 0.0, 1.0))
	return pow(1.0 - distance / radius, exponent)


## 在 (center_cell, radius_cells) 处打一个笔刷印。
## 返回被改动的单元数（0 表示这次落笔什么也没改，调用方可据此跳过撤销记录）。
## mode 取 Mode；strength 是"每个印的最大增量/减量"（0..1 量级）。
static func apply_stamp(field: FogBrushField, center_cell: Vector2, radius_cells: float,
		strength: float, hardness: float, mode: int) -> int:
	if field == null:
		return 0
	field.ensure_data()
	var width := maxi(1, field.grid_size.x)
	var height := maxi(1, field.grid_size.y)
	var radius := maxf(radius_cells, 0.5)
	var source := field.data
	if mode == Mode.SMOOTH:
		# 平滑必须基于**快照**做邻域平均：就地读写会让结果依赖遍历顺序
		source = field.data.duplicate()

	var i_min := maxi(0, int(floor(center_cell.x - radius)))
	var i_max := mini(width - 1, int(ceil(center_cell.x + radius)))
	var j_min := maxi(0, int(floor(center_cell.y - radius)))
	var j_max := mini(height - 1, int(ceil(center_cell.y + radius)))
	var changed := 0

	for j in range(j_min, j_max + 1):
		for i in range(i_min, i_max + 1):
			var distance := Vector2(float(i) - center_cell.x, float(j) - center_cell.y).length()
			var weight := falloff(distance, radius, hardness)
			if weight <= 0.0001:
				continue
			var index := j * width + i
			var value := field.data[index]
			var next := value
			match mode:
				Mode.PAINT:
					next = clampf(value + strength * weight, 0.0, 1.0)
				Mode.ERASE:
					next = clampf(value - strength * weight, 0.0, 1.0)
				Mode.SMOOTH:
					next = lerpf(value, _neighbor_average(source, width, height, i, j), clampf(strength * weight, 0.0, 1.0))
				_:
					next = value
			if absf(next - value) > 0.0005:
				field.data[index] = next
				changed += 1

	if changed > 0:
		field.mark_texture_dirty()
	return changed


## 3x3 邻域平均（越界按 clamp-to-edge）。
static func _neighbor_average(source: PackedFloat32Array, width: int, height: int,
		i: int, j: int) -> float:
	var sum := 0.0
	var count := 0
	for dj in range(-1, 2):
		for di in range(-1, 2):
			var ni := clampi(i + di, 0, width - 1)
			var nj := clampi(j + dj, 0, height - 1)
			sum += source[nj * width + ni]
			count += 1
	return sum / float(maxi(count, 1))


## 一条连续笔画：从 from_cell 到 to_cell 之间按 spacing 打多个印。
## 为什么要插值：鼠标事件是离散的，直接每次事件打一个印会在快速拖动时留下"断点"。
## 返回被改动的单元数。
static func apply_stroke(field: FogBrushField, from_cell: Vector2, to_cell: Vector2,
		radius_cells: float, strength: float, hardness: float, mode: int,
		spacing: float = 0.3) -> int:
	if field == null:
		return 0
	var step := maxf(radius_cells * spacing, 0.5)
	var delta := to_cell - from_cell
	var distance := delta.length()
	var stamps := maxi(1, int(ceil(distance / step)))
	var changed := 0
	for k in range(stamps + 1):
		var t := 1.0 if stamps == 0 else float(k) / float(stamps)
		changed += apply_stamp(field, from_cell + delta * t, radius_cells, strength, hardness, mode)
	return changed


# =========================================================
# 图像 / 纹理 / 落盘
# =========================================================

## 导出为灰度 Image（R=G=B=浓度，A=255）。格式用 RGBA8：兼容性最好，
## 而且 8 位对"手刷的雾"完全够（求解器内部仍是 16 位浮点）。
func to_image() -> Image:
	ensure_data()
	var width := maxi(1, grid_size.x)
	var height := maxi(1, grid_size.y)
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	for j in range(height):
		for i in range(width):
			var value := clampf(data[j * width + i], 0.0, 1.0)
			image.set_pixel(i, j, Color(value, value, value, 1.0))
	return image


## 从 Image 读入（灰度取 R 通道）。尺寸不一致时会自动调整 grid_size。
func apply_image(image: Image) -> void:
	if image == null:
		return
	var width := maxi(1, image.get_width())
	var height := maxi(1, image.get_height())
	grid_size = Vector2i(width, height)
	data = PackedFloat32Array()
	data.resize(width * height)
	for j in range(height):
		for i in range(width):
			data[j * width + i] = clampf(image.get_pixel(i, j).r, 0.0, 1.0)
	_texture_dirty = true


## 写 PNG（会先 make_dir_recursive）。返回 Error。
func save_to_png(path: String) -> Error:
	if path.is_empty():
		return ERR_INVALID_PARAMETER
	var absolute_dir := path.get_base_dir()
	if not absolute_dir.is_empty():
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(absolute_dir))
	var error := to_image().save_png(path)
	if error == OK:
		image_path = path
	return error


## 读 PNG（读不到就返回 false，不改动现有数据）。
## ★ 用 FileAccess.file_exists 而不是 ResourceLoader.exists：后者只认"被编辑器导入过的
##   res:// 资源"，对 user:// 下的 PNG（以及运行时才生成的图）一律返回 false ——
##   表现为"刚存出去的图立刻读不回来"（踩过）。
func load_from_png(path: String) -> bool:
	if path.is_empty() or not FileAccess.file_exists(path):
		return false
	var image := Image.load_from_file(ProjectSettings.globalize_path(path))
	if image == null:
		return false
	apply_image(image)
	image_path = path
	return true


## 给材质用的纹理（缓存；数据改动后由 mark_texture_dirty() 失效）。
func to_texture() -> Texture2D:
	if is_empty_source():
		# 没有内存数据但有 PNG：直接把 PNG 当纹理用（运行时零拷贝上 GPU）。
		if not image_path.is_empty() and ResourceLoader.exists(image_path):
			return load(image_path) as Texture2D
		return null
	ensure_data()
	if _texture == null or _texture_dirty:
		var image := to_image()
		if _texture == null:
			_texture = ImageTexture.create_from_image(image)
		else:
			_texture.update(image)
		_texture_dirty = false
	return _texture


## 是否"只有 PNG、没有内存网格"。
func is_empty_source() -> bool:
	return data.size() != maxi(1, grid_size.x) * maxi(1, grid_size.y) or data.is_empty()


func mark_texture_dirty() -> void:
	_texture_dirty = true


## 资源被保存/加载时清缓存，避免把编辑器的旧纹理带进运行时。
func _init() -> void:
	_texture_dirty = true

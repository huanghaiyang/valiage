extends MeshInstance3D
## ============================================================================
##  落叶 / 落花效果（移植自 fast-tree: D:\sgames\fast-tree\src\core\fallingLeaves.js）
## ============================================================================
##  做法与源实现一致：
##    · 每片叶/花 = 一张卡片（4 顶点 / 2 三角），每个来源只有 **1 个 draw call**
##    · POSITION 里存的是**出生点**（同一张卡片的 4 个顶点写同一个值），
##      卡片形状由 UV 在顶点着色器里展开（见 assets/shaders/falling_leaves.gdshader）
##    · 下落 / 翻滚 / 受风全部在顶点着色器里算，脚本侧**只在构建时写一次顶点数据**，
##      运行时零每帧开销（只有 0.25 秒一次的可见性校准）
##    · 风场 uniform 与树**完全共用**（scripts/wind.gd 每帧写同一份）
##      → 风向一变，落叶与树梢同步朝同一方向飘
##
##  ★ 有树叶就落树叶、有花朵就落花朵、两者都有就一起落：
##    每个来源单独一个 surface + 单独一份材质 + 一组独立参数（数量/贴图/尺寸/
##    下落速度/跟随风力），任意一个关掉或场景里没有该节点就只落另一个。
##    两个来源各自按**三角形面积加权**撒点 —— 花/叶密的地方落得也多。
##
##  用法：挂在树根 FastTree 下的一个 MeshInstance3D 上（脚本路径
##  res://scripts/vfx/falling_leaves.gd），不需要手填网格 —— 构建时自动生成。
##  参数全部在 Inspector 可调（选中该节点即可，树叶 / 花朵两组分开）。
##
##  与燃烧 / 重生的配合（见 _is_foliage_visible）：
##    · 该来源的材质 burn / ash > 0.05（正在烧 / 已烧成灰）→ 该来源隐藏
##    · 正在重生（growth_enabled = true 且 growth < 0.9）→ 隐藏
##    · 树本体被藏起来时（燃烧收尾 _target.visible = false）→ 本节点是它的子节点，自动跟着藏
## ============================================================================

@export_group("通用")
## 总开关
@export var enabled := true
## 自旋速度（弧度/秒量级）
@export var spin_speed := 1.2
## 空中打旋幅度（没有风也会飘一点）
@export var swirl := 1.0
## 打旋位移倍率
@export var stagger := 0.6
## 不透明度
@export_range(0.0, 1.0) var opacity := 1.0
## 贴图 alpha 裁形阈值（与树叶材质 alpha_scissor 保持一致的观感）
@export_range(0.0, 1.0) var alpha_test := 0.35

@export_group("树叶")
## 是否落树叶（场景里没有该节点 / 没有几何时自动跳过）
@export var leaves_enabled := true
## 树叶节点路径（相对本节点；被 CanopyCull 分块后依然能采样）
@export var leaves_path: NodePath = ^"../Leaves"
## 同时存在的落叶数量（源实现默认 80）
@export_range(0, 256) var leaves_count := 80
## 叶片贴图；留空则自动取树叶材质的 albedo_tex
@export var leaves_texture: Texture2D
## 卡片尺寸（模型空间单位；大树高约 27 单位 ≈ 8 米 → 0.9 单位 ≈ 0.26 米）
@export var leaves_size_scale := 0.9
## 下落速度倍率（1.0 ≈ 一片叶约 3 秒落地）
@export var leaves_fall_speed := 1.0
## 跟随风场的强度倍率（0 = 完全不受风）
@export var leaves_wind_follow := 1.0

@export_group("花朵")
## 是否落花朵（场景里没有该节点 / 没有几何时自动跳过）
@export var flowers_enabled := true
## 花朵节点路径（相对本节点）
@export var flowers_path: NodePath = ^"../Flowers"
## 同时存在的落花数量
@export_range(0, 256) var flowers_count := 60
## 花瓣贴图；留空则自动取花朵材质的 albedo_tex
@export var flowers_texture: Texture2D
## 卡片尺寸（模型空间单位）
@export var flowers_size_scale := 0.8
## 下落速度倍率（花瓣比树叶轻，默认稍慢）
@export var flowers_fall_speed := 0.85
## 跟随风场的强度倍率（花瓣更轻，默认飘得更远）
@export var flowers_wind_follow := 1.6

## 出生点采样种子（固定 = 每次进游戏落叶分布一致）
const RNG_SEED := 20261026
## 剔除包围盒的水平外扩（模型单位）：风漂移 + 打旋都写不进静态 AABB，必须留余量
const CULL_PAD := 40.0
## 可见性校准间隔（秒）
const CHECK_INTERVAL := 0.25

const SHADER := preload("res://assets/shaders/falling_leaves.gdshader")
## ★ CUSTOM0/CUSTOM1 是每顶点 4 个 float：必须显式声明 RGBA_FLOAT
##   否则 add_surface_from_arrays 会按默认 RGBA8_UNORM 去要 PackedByteArray → 报错
const CUSTOM_FLAGS := (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
## 卡片 4 个角的 UV（铺满贴图）
const CORNERS: Array[Vector2] = [
	Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(1.0, 1.0), Vector2(0.0, 1.0),
]

var _rng := RandomNumberGenerator.new()
## 每个 surface 一份材质 / 对应的来源节点 / 基础不透明度（隐藏时写 0）
var _mats: Array[ShaderMaterial] = []
var _nodes: Array[MeshInstance3D] = []
var _labels: Array[String] = []
var _base_opacity := PackedFloat32Array()
var _check_t := 0.0


func _ready() -> void:
	_rng.seed = RNG_SEED
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	if not enabled or not _build():
		visible = false
		return
	_check_t = CHECK_INTERVAL          # 首帧就校准一次可见性


## 构建落叶 / 落花网格 + 材质。成功返回 true。
func _build() -> bool:
	var am := ArrayMesh.new()
	var total := 0
	var desc: Array[String] = []
	for spec in _source_specs():
		var label := String(spec["label"])
		if not bool(spec["on"]) or int(spec["count"]) <= 0:
			desc.append("%s 关闭" % label)
			continue
		var node := get_node_or_null(spec["path"]) as MeshInstance3D
		if node == null:
			desc.append("%s 跳过（无该节点）" % label)
			continue
		var verts := PackedVector3Array()
		var idx := PackedInt32Array()
		_collect_geometry(node, verts, idx)
		if idx.is_empty():
			desc.append("%s 跳过（几何为空）" % label)
			continue
		var n := int(spec["count"])
		am.add_surface_from_arrays(
				Mesh.PRIMITIVE_TRIANGLES, _make_arrays(verts, idx, n), [], {}, CUSTOM_FLAGS)
		var mat := _make_material(node, spec["tex"], spec["size"], spec["fall"], spec["wind"])
		am.surface_set_material(am.get_surface_count() - 1, mat)
		_mats.append(mat)
		_nodes.append(node)
		_labels.append(label)
		_base_opacity.append(opacity)
		total += n
		desc.append("%s %d 片" % [label, n])

	if am.get_surface_count() == 0:
		push_warning("[落叶] 没有任何可采样来源（树叶 / 花朵都不可用），跳过")
		return false
	mesh = am
	# ★ 顶点位移引擎看不见 → 用自定义 AABB 兜住"落下 + 顺风漂移 + 打旋"的范围
	var box := am.get_aabb()
	box = box.merge(AABB(
			Vector3(box.position.x - CULL_PAD, 0.0, box.position.z - CULL_PAD),
			Vector3(box.size.x + CULL_PAD * 2.0, maxf(box.end.y, 1.0), box.size.z + CULL_PAD * 2.0)))
	custom_aabb = box
	visible = enabled
	print("[落叶] 构建完成：%d 片（%s）" % [total, " ｜ ".join(desc)])
	return true


## 两个来源的参数表（树叶 / 花朵完全独立配置）
func _source_specs() -> Array:
	return [
		{
			"label": "树叶", "on": leaves_enabled, "path": leaves_path,
			"count": leaves_count, "tex": leaves_texture,
			"size": leaves_size_scale, "fall": leaves_fall_speed, "wind": leaves_wind_follow,
		},
		{
			"label": "花朵", "on": flowers_enabled, "path": flowers_path,
			"count": flowers_count, "tex": flowers_texture,
			"size": flowers_size_scale, "fall": flowers_fall_speed, "wind": flowers_wind_follow,
		},
	]


## 把树叶（或花朵）网格的三角形汇总进 verts / idx。
## 若该节点已被子节点（canopy_chunk）接管（原节点 mesh = null），则遍历这些块 ——
## 块的顶点坐标仍是同一个局部空间，直接拼接即可。
func _collect_geometry(src: MeshInstance3D, verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	if src.mesh != null:
		_append_mesh(src.mesh, verts, idx)
		return
	for ch in src.get_children():
		var mi := ch as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		_append_mesh(mi.mesh, verts, idx)


func _append_mesh(src: Mesh, verts: PackedVector3Array, idx: PackedInt32Array) -> void:
	for s in range(src.get_surface_count()):
		if src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays: Array = src.surface_get_arrays(s)
		var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var si: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if sv.is_empty() or si.is_empty():
			continue
		var base := verts.size()
		verts.append_array(sv)
		for k in range(si.size()):
			idx.append(base + si[k])


## 按三角形面积加权撒 `count` 个出生点，返回一份可直接喂给 add_surface_from_arrays 的数组
func _make_arrays(verts: PackedVector3Array, idx: PackedInt32Array, count: int) -> Array:
	var tri_n := idx.size() / 3
	var cdf := PackedFloat32Array()
	cdf.resize(tri_n)
	var total := 0.0
	for t in range(tri_n):
		total += _tri_area(verts, idx, t)
		cdf[t] = total

	var vcount := count * 4
	var v := PackedVector3Array()
	var uv := PackedVector2Array()
	var c0 := PackedFloat32Array()    # phase, speedScale, sizeScale, spinDir
	var c1 := PackedFloat32Array()    # fallDist, 0, 0, 0
	var ind := PackedInt32Array()
	v.resize(vcount)
	uv.resize(vcount)
	c0.resize(vcount * 4)
	c1.resize(vcount * 4)
	ind.resize(count * 6)
	for i in range(count):
		var p := _sample_point(verts, idx, cdf, total)
		var phase := _rng.randf()
		var speed_scale := _rng.randf_range(0.65, 1.35)
		var card_size := _rng.randf_range(0.7, 1.3)
		var spin_dir := 1.0 if _rng.randf() < 0.5 else -1.0
		# 每张卡片自己的下落距离：出生点到地面（t = 1 时正好落地）
		# 源实现用整树高度，低处的会在地下走完大半生命 → 这里逐张取真实高度
		var fall_dist := maxf(3.0, p.y)
		var b := i * 4
		for k in range(4):
			var vi := b + k
			v[vi] = p
			uv[vi] = CORNERS[k]
			c0[vi * 4 + 0] = phase
			c0[vi * 4 + 1] = speed_scale
			c0[vi * 4 + 2] = card_size
			c0[vi * 4 + 3] = spin_dir
			c1[vi * 4 + 0] = fall_dist
		ind[i * 6 + 0] = b + 0
		ind[i * 6 + 1] = b + 1
		ind[i * 6 + 2] = b + 2
		ind[i * 6 + 3] = b + 0
		ind[i * 6 + 4] = b + 2
		ind[i * 6 + 5] = b + 3

	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = v
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_CUSTOM0] = c0
	arrays[Mesh.ARRAY_CUSTOM1] = c1
	arrays[Mesh.ARRAY_INDEX] = ind
	return arrays


## 按面积加权随机取一个点（重心采样）
func _sample_point(verts: PackedVector3Array, idx: PackedInt32Array,
		cdf: PackedFloat32Array, total: float) -> Vector3:
	var tri_n := cdf.size()
	if tri_n <= 0:
		return Vector3.ZERO
	if total <= 1e-6:
		return verts[idx[0]]
	var target := _rng.randf() * total
	# 二分找出第一个 cdf >= target 的三角形
	var lo := 0
	var hi := tri_n - 1
	while lo < hi:
		var mid := (lo + hi) >> 1
		if cdf[mid] < target:
			lo = mid + 1
		else:
			hi = mid
	var a := verts[idx[lo * 3 + 0]]
	var b := verts[idx[lo * 3 + 1]]
	var c := verts[idx[lo * 3 + 2]]
	# 重心坐标（sqrt 保证在三角形内均匀分布）
	var r1 := sqrt(_rng.randf())
	var r2 := _rng.randf()
	return a * (1.0 - r1) + b * (r1 * (1.0 - r2)) + c * (r1 * r2)


func _tri_area(verts: PackedVector3Array, idx: PackedInt32Array, t: int) -> float:
	var a := verts[idx[t * 3 + 0]]
	var b := verts[idx[t * 3 + 1]]
	var c := verts[idx[t * 3 + 2]]
	return 0.5 * (b - a).cross(c - a).length()


## 某个来源的材质：贴图/宽高比跟该来源的树材质走，其余参数读 Inspector。
## ★ 风场 uniform 不在这里写 —— scripts/wind.gd 每帧统一写（与树共用同一份）。
func _make_material(src: MeshInstance3D, tex_override: Texture2D, size_scale: float,
		fall_speed: float, wind_follow: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	var tex := tex_override
	if tex == null:
		var src_mat := _mat_of(src)
		if src_mat != null:
			var t: Variant = src_mat.get_shader_parameter("albedo_tex")
			if t is Texture2D:
				tex = t as Texture2D
	# 卡片半宽按贴图宽高比（与源实现 halfW = 0.5 × clamp(aspect, 0.35, 1.6) 一致）
	var half := Vector2(0.35, 0.5)
	if tex != null and tex.get_height() > 0:
		var aspect := float(tex.get_width()) / float(tex.get_height())
		half = Vector2(0.5 * clampf(aspect, 0.35, 1.6), 0.5)
	m.set_shader_parameter("leaf_tex", tex)
	m.set_shader_parameter("has_map", tex != null)
	m.set_shader_parameter("card_half", half)
	m.set_shader_parameter("fall_speed", fall_speed)
	m.set_shader_parameter("size_scale", size_scale)
	m.set_shader_parameter("spin_speed", spin_speed)
	m.set_shader_parameter("swirl", swirl)
	m.set_shader_parameter("stagger", stagger)
	m.set_shader_parameter("wind_follow", wind_follow)
	m.set_shader_parameter("opacity", opacity)
	m.set_shader_parameter("alpha_test", alpha_test)
	return m


## 某个来源当前在用的材质：优先 material_override，其次逐面覆盖材质 / 网格自带材质。
## ★ 必须**动态解析**：燃烧一开始 foliage_burn.gd 会把 material_override 清掉、改成
##   逐面材质副本（burn / ash / growth 都写在副本上），缓存旧引用会读到永远为 0 的 burn。
func _find_foliage_material(src: MeshInstance3D) -> ShaderMaterial:
	var m := _mat_of(src)
	if m != null:
		return m
	# 树冠被 CanopyCull 分块后，材质挂在块上
	for ch in src.get_children():
		var mi := ch as MeshInstance3D
		if mi == null:
			continue
		m = _mat_of(mi)
		if m != null:
			return m
	return null


func _mat_of(mi: MeshInstance3D) -> ShaderMaterial:
	if mi.material_override is ShaderMaterial:
		return mi.material_override as ShaderMaterial
	if mi.get_surface_override_material_count() > 0:
		var ov := mi.get_surface_override_material(0)
		if ov is ShaderMaterial:
			return ov as ShaderMaterial
	if mi.mesh != null and mi.mesh.get_surface_count() > 0:
		var sm := mi.mesh.surface_get_material(0)
		if sm is ShaderMaterial:
			return sm as ShaderMaterial
	return null


func _process(delta: float) -> void:
	if not enabled:
		return
	_check_t += delta
	if _check_t < CHECK_INTERVAL:
		return
	_check_t = 0.0
	# 逐来源判断：树叶烧完了只停落叶，花朵还在就继续落花（两者独立）
	for i in range(_mats.size()):
		var mat := _mats[i]
		if mat == null or not is_instance_valid(mat):
			continue
		var src := _nodes[i]
		var on := true
		if src != null and is_instance_valid(src):
			var cur := _find_foliage_material(src)
			if cur != null:
				on = _is_foliage_visible(cur)
		mat.set_shader_parameter("opacity", _base_opacity[i] if on else 0.0)


## 该来源的树叶/花朵还"在树上"时才该有飘落（燃烧中 / 已烧成灰 / 正在重生 时不飘）
func _is_foliage_visible(m: ShaderMaterial) -> bool:
	if _read_float(m, "burn") > 0.05:
		return false
	if _read_float(m, "ash") > 0.05:
		return false
	var ge: Variant = m.get_shader_parameter("growth_enabled")
	if ge is bool and ge and _read_float(m, "growth") < 0.9:
		return false
	return true


func _read_float(m: ShaderMaterial, uniform: String) -> float:
	var v: Variant = m.get_shader_parameter(uniform)
	if v is float or v is int:
		return float(v)
	return 0.0

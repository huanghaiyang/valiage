class_name FogNsSolver
extends Node
## ============================================================================
## fog_ns_solver.gd —— 不可压纳维-斯托克斯方程的 **GPU 实现**（雾气驱动场）
## ============================================================================
## 【职责】每帧在 GPU 上推进一个 2D 不可压速度场 + 一层被动标量（雾浓度），
##   并把两张纹理交出去：`velocity_texture()`（体积雾/粒子用）与
##   `density_texture()`（体积雾用）。它不做任何渲染，也没有可见节点。
##
## 【方程与离散格式】与 CPU 参考实现 scripts/fx/fog_ns_reference.gd **逐式一致**
##   （该文件是测试的真值来源，头注释里有完整的方程与单位说明）：
##     ∂u/∂t = -(u·∇)u - ∇p + f,  ∇·u = 0
##     ∂d/∂t = -(u·∇)d - σd + κ(base - d) + S
##   通道顺序（每个通道 = 一个 SubViewport 片元通道，见 assets/shaders/fog_ns/）：
##     A 速度自输运+加力 → B 涡量 → C 涡量约束 → D 散度
##     → E×N 压力迭代 → F 减梯度（投影完成）→ G 浓度输运 → H 合成
##   通道总数 = **7 + jacobi_passes**（4 + N + 3）。
##   ★ 边界是**周期**的（邻域下标环绕），不是固壁：见 ns_common.gdshaderinc 的说明 ——
##     闭盒 + 不可压会禁止净流动，风就没法搬运雾。
##
## 【★ 为什么是"环形通道链"而不是 ping-pong 缓冲】
##   链条的**末尾接回开头**：A 读 F（上一帧的最终速度）、G 读 H（上一帧的合成浓度）、
##   E 的第 1 趟读 E 的第 N 趟（上一帧的压力 = 跨帧热启动）。
##   好处有三：
##     ① 每个通道写自己的专用 SubViewport，**不存在"读自己正在写的纹理"**（未定义行为）；
##     ② 源纹理全帧固定，材质 uniform 只在 setup 时连一次，不需要每帧重指向；
##     ③ 通道按节点树顺序渲染，SubViewport 的渲染顺序 = 注册顺序，
##        所以"后一趟读到本帧前一趟的结果"是确定的（这一点由 tools/fog_field_verify 实测）。
##   代价：读的是"上一帧"的尾部纹理，也就是一帧的延迟（对雾气这种慢变量无感）。
##
## 【★ 为什么不用 RenderingDevice compute（本机实测结论）】
##   本地 RD 能跑 compute，但它的纹理交不进 Texture2DRD（引擎报 texture_is_valid 失败）；
##   主 RD 被引擎禁止手动 submit/sync（"Only local devices can submit and sync."）。
##   于是 compute 结果上屏必须每帧 CPU 回读+上传，对每帧跑的雾气不可接受。
##   SubViewport 的结果本身就是渲染器纹理，可被材质/粒子直接采样，零回读。
##
## 【对外接口】
##   · setup()/teardown()            建/拆通道链（改分辨率或 jacobi_passes 后调用）
##   · step(delta)                   推进一帧（只更新 uniform；渲染由 SubViewport 自己做）
##   · add_splat(uv, radius, force, density)  投一个高斯源（风/热源/笔刷落点）
##   · set_wind(velocity_domain)     设定风的目标速度（域单位/秒）
##   · set_base_density_image(image) 上传画笔底图
##   · clear_density()               清空模拟浓度（不含底图）
##   · velocity_texture()/density_texture()  -> Texture2D
##   · world_to_uv(world_position)   -> Vector2（世界坐标 -> 域坐标）
##   · enabled                       关闭时所有通道停止渲染（不花 GPU）
##
## 【已知的坑】
##   1. `use_hdr_2d = true` 是必须的：速度/压力/散度都有符号且量级远小于 1，
##      RGBA8 会被截断成 0（表现：雾完全不动、压力恒为 0 而散度永不清除）。
##   2. 源采样统一用 `filter_nearest`：平流通道要自己做双线性（能精确控制边界），
##      散度/雅可比/梯度则必须取到**精确的邻居纹素**，线性过滤会把它们糊掉。
##   3. 每个通道末尾必须写 `COLOR.a = 1.0`：canvas_item 默认混合绘制，alpha<1 会与
##      清屏色混合，污染数据（症状是数值莫名变小、雾越跑越淡）。
##   4. 通道数 = 8 + jacobi_passes。jacobi_passes 调大能改善投影质量但线性增加
##      GPU 通道开销；配合跨帧热启动，8 趟/帧已经足够雾气使用。
## ============================================================================

const SHADER_DIR := "res://assets/shaders/fog_ns/"
const MAX_SPLATS := 8
const PASS_SETTLE_UNIFORM := 1.0e-6

# ==================== 配置（改动后需要 setup() 重建） ====================
## 模拟网格边长（单元数）。96 是"格子感可接受 / 开销很低"的折中；
## 结合 H 通道的轻量平滑，画面上看不出 96 格。
var resolution: int = 96
## 每帧压力迭代趟数（通道数 = 8 + 本值）
var jacobi_passes: int = 8
## 域在世界里的水平尺寸（米）：u 方向对应世界 X，v 方向对应世界 Z
var domain_size := Vector2(80.0, 80.0)
## 域的底面高度（世界 Y，米）
var base_height: float = 0.0
## 雾层厚度（米）
var box_height: float = 14.0

# ==================== 物理参数 ====================
## 速度耗散（每秒比例）：风停后流场慢慢静下来
var velocity_dissipation: float = 0.35
## 浓度耗散（每秒比例）：雾自然消散的速度
var density_dissipation: float = 0.10
## 涡量约束强度：补回数值耗散抹掉的小涡（0 = 关闭）
var vorticity_strength: float = 2.5
## 向画笔底图松弛的速率（1/秒）：0 = 底图只做兜底不吸附
var base_relax: float = 0.6
## 底图增益：>1 让刷出来的雾更浓
var base_gain: float = 1.0
## 底图**地板**强度（0..1）：1 = 旧行为（合成时 `浓度 = max(模拟, 底图×增益)`）。
## 0 = 底图只当吸引子（base_relax），挖雾/涡流才压得下可见浓度。
## ★ 为什么要有它：底图被刷满时 `max` 会把可见浓度锁死在 1，扰动全部不可见。
## 细节见 ns_composite.gdshader 的 base_floor 注释。
var base_floor: float = 1.0
## 合成通道的平滑权重（压掉低分辨率的格子感）
var smooth_weight: float = 0.35

# ==================== 运行状态 ====================
## 是否启用（false 时所有通道停止渲染，不产生 GPU 开销）
var enabled: bool = true:
	set(value):
		enabled = value
		_apply_enabled()
## 风的目标速度（**域单位/秒**）。由 FogField 按天气换算后写入。
var wind_velocity := Vector2.ZERO
## 风松弛速率（1/秒）
var wind_strength: float = 1.2

var _passes: Array[Dictionary] = []
var _by_name: Dictionary = {}
var _base_texture: ImageTexture
var _splat_uv: Array[Vector2] = []
var _splat_radius: Array[float] = []
var _splat_velocity: Array[Vector2] = []
var _splat_velocity_rate: Array[float] = []
var _splat_radial: Array[float] = []
var _splat_swirl: Array[float] = []
var _splat_density: Array[float] = []
var _splat_vectors := PackedVector4Array()
var _splat_forces := PackedVector4Array()
## 每帧上传给 advect_velocity 的切向速度数组（长度必须恒为 MAX_SPLATS）
var _splat_swirl_values := PackedFloat32Array()
var _ready_done := false
var _frame_delta: float = 0.0
# 诊断计数：外部（自检脚本）可读，用于确认链真的在推进
var steps_done: int = 0


func _ready() -> void:
	_splat_vectors.resize(MAX_SPLATS)
	_splat_forces.resize(MAX_SPLATS)
	_splat_swirl_values.resize(MAX_SPLATS)
	# 默认自动建链：FogField 直接实例化它就能用；也允许先改参数再手动 setup()。
	if _passes.is_empty():
		setup()


func _exit_tree() -> void:
	teardown()


# =========================================================
# 通道链
# =========================================================

## 建立通道链。可重复调用（会先拆掉旧的）。
## 顺序即渲染顺序，见文件头"环形通道链"说明。
func setup() -> void:
	teardown()
	if resolution < 8:
		resolution = 8
	for pass_name in _chain_names():
		_make_pass(pass_name)
	_wire_chain()
	_ready_done = true
	_apply_enabled()
	_apply_static_uniforms()


## 通道名列表（顺序 = 链顺序）。jacobi 通道带序号，方便接线与诊断。
## ★ 序号从 1 开始（jacobi_1..jacobi_N）：_wire_chain() 里的"第 1 趟读最后一趟"和
##   "第 k 趟读第 k-1 趟"都按这个编号写。写成 range(N) 会得到 jacobi_0..jacobi_{N-1}，
##   于是接线时找不到 jacobi_N（踩过：报"通道 jacobi_1 的源 jacobi_6 不存在"，
##   而实际上压力链少了一头、热启动变成读空纹理）。
func _chain_names() -> Array[String]:
	var names: Array[String] = ["advect_velocity", "curl", "vorticity", "divergence"]
	for i in range(1, maxi(1, jacobi_passes) + 1):
		names.append("jacobi_%d" % i)
	names.append("gradient")
	names.append("advect_density")
	names.append("composite")
	return names


func _shader_for(pass_name: String) -> String:
	if pass_name.begins_with("jacobi_"):
		return SHADER_DIR + "ns_jacobi.gdshader"
	match pass_name:
		"advect_velocity":
			return SHADER_DIR + "ns_advect_velocity.gdshader"
		"curl":
			return SHADER_DIR + "ns_curl.gdshader"
		"vorticity":
			return SHADER_DIR + "ns_vorticity.gdshader"
		"divergence":
			return SHADER_DIR + "ns_divergence.gdshader"
		"gradient":
			return SHADER_DIR + "ns_gradient.gdshader"
		"advect_density":
			return SHADER_DIR + "ns_advect_density.gdshader"
		"composite":
			return SHADER_DIR + "ns_composite.gdshader"
	return ""


## 建一个通道：SubViewport(RGBA16F) + 铺满的 ColorRect + ShaderMaterial。
## ★ use_hdr_2d 必须为 true：速度/压力/散度都是有符号的小量，8 位会被吃掉。
## ★ 合成通道的纹理要给渲染用，所以它的采样过滤设成"线性"（其余通道保持 nearest）。
func _make_pass(pass_name: String) -> void:
	var shader_path := _shader_for(pass_name)
	if shader_path.is_empty() or not ResourceLoader.exists(shader_path):
		push_error("FogNsSolver: 通道 %s 找不到着色器 %s" % [pass_name, shader_path])
		return

	var viewport := SubViewport.new()
	viewport.name = "Ns_%s" % pass_name
	viewport.size = Vector2i(resolution, resolution)
	viewport.use_hdr_2d = true
	viewport.disable_3d = true
	viewport.transparent_bg = false
	viewport.msaa_2d = Viewport.MSAA_DISABLED
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS

	var rect := ColorRect.new()
	rect.name = "Surface"
	rect.position = Vector2.ZERO
	rect.size = Vector2(resolution, resolution)
	rect.color = Color(0.0, 0.0, 0.0, 1.0)

	var material := ShaderMaterial.new()
	material.shader = load(shader_path)
	rect.material = material

	viewport.add_child(rect)
	add_child(viewport)

	var entry := {
		"name": pass_name,
		"viewport": viewport,
		"material": material,
		"rect": rect,
	}
	_passes.append(entry)
	_by_name[pass_name] = entry


func _pass_texture(pass_name: String) -> Texture2D:
	var entry: Dictionary = _by_name.get(pass_name, {})
	if entry.is_empty():
		return null
	var viewport: SubViewport = entry["viewport"]
	return viewport.get_texture()


func _pass_material(pass_name: String) -> ShaderMaterial:
	var entry: Dictionary = _by_name.get(pass_name, {})
	return entry.get("material", null) as ShaderMaterial


## 接线：把每个通道的源纹理指向链上的前一个通道（以及环回的那两个）。
func _wire_chain() -> void:
	var last_jacobi := "jacobi_%d" % maxi(1, jacobi_passes)

	_set_source("advect_velocity", "velocity_tex", "gradient")        # 环回：上一帧最终速度
	_set_source("curl", "velocity_tex", "advect_velocity")
	_set_source("vorticity", "velocity_tex", "advect_velocity")
	_set_source("vorticity", "curl_tex", "curl")
	_set_source("divergence", "velocity_tex", "vorticity")
	for i in range(1, maxi(1, jacobi_passes) + 1):
		var name := "jacobi_%d" % i
		_set_source(name, "divergence_tex", "divergence")
		# 第 1 趟读"环回"的最后一趟（= 上一帧压力，跨帧热启动）；其余读上一趟。
		_set_source(name, "pressure_tex", last_jacobi if i == 1 else "jacobi_%d" % (i - 1))
	_set_source("gradient", "velocity_tex", "vorticity")
	_set_source("gradient", "pressure_tex", last_jacobi)
	_set_source("advect_density", "density_tex", "composite")          # 环回：上一帧浓度
	_set_source("advect_density", "velocity_tex", "gradient")
	_set_source("composite", "density_tex", "advect_density")


func _set_source(pass_name: String, uniform_name: String, source_pass: String) -> void:
	var material := _pass_material(pass_name)
	if material == null:
		return
	var texture := _pass_texture(source_pass)
	if texture == null:
		push_error("FogNsSolver: 通道 %s 的源 %s 不存在" % [pass_name, source_pass])
		return
	material.set_shader_parameter(uniform_name, texture)


## 与帧无关的 uniform（网格尺寸、底图、物理常量）——只在 setup/参数变化时写一次。
func _apply_static_uniforms() -> void:
	var grid := Vector2(resolution, resolution)
	var texel := Vector2(1.0 / float(resolution), 1.0 / float(resolution))
	for entry in _passes:
		var material: ShaderMaterial = entry["material"]
		material.set_shader_parameter("grid_size", grid)
		material.set_shader_parameter("texel_size", texel)

	var advect_velocity := _pass_material("advect_velocity")
	if advect_velocity != null:
		advect_velocity.set_shader_parameter("velocity_dissipation", velocity_dissipation)
	var vorticity := _pass_material("vorticity")
	if vorticity != null:
		vorticity.set_shader_parameter("vorticity_strength", vorticity_strength)
	var advect_density := _pass_material("advect_density")
	if advect_density != null:
		advect_density.set_shader_parameter("density_dissipation", density_dissipation)
		advect_density.set_shader_parameter("base_relax", base_relax)
		advect_density.set_shader_parameter("base_gain", base_gain)
	var composite := _pass_material("composite")
	if composite != null:
		composite.set_shader_parameter("smooth_weight", smooth_weight)
		composite.set_shader_parameter("base_gain", base_gain)
		composite.set_shader_parameter("base_floor", base_floor)
	_apply_base_texture()


## 拆掉通道链（分辨率变化/停机时调用）。
func teardown() -> void:
	for entry in _passes:
		var viewport: SubViewport = entry["viewport"]
		if is_instance_valid(viewport):
			viewport.queue_free()
	_passes.clear()
	_by_name.clear()
	_ready_done = false


func _apply_enabled() -> void:
	if not _ready_done:
		return
	# 关闭时把通道设成 UPDATE_DISABLED：不渲染就完全不花 GPU（比留着 ALWAYS 好得多）。
	var mode := SubViewport.UPDATE_ALWAYS if enabled else SubViewport.UPDATE_DISABLED
	for entry in _passes:
		var viewport: SubViewport = entry["viewport"]
		if is_instance_valid(viewport):
			viewport.render_target_update_mode = mode


# =========================================================
# 每帧推进
# =========================================================

## 推进一帧。只更新动态 uniform —— 通道的渲染由 SubViewport（UPDATE_ALWAYS）自己完成，
## 顺序由节点树顺序保证，所以这里**不能**也不需要手动派发。
func step(delta: float) -> void:
	if not _ready_done or not enabled:
		return
	_frame_delta = clampf(delta, 0.0, 0.05)
	steps_done += 1

	var advect_velocity := _pass_material("advect_velocity")
	if advect_velocity != null:
		advect_velocity.set_shader_parameter("dt", _frame_delta)
		advect_velocity.set_shader_parameter("wind_target", wind_velocity)
		advect_velocity.set_shader_parameter("wind_strength", wind_strength)

	var vorticity := _pass_material("vorticity")
	if vorticity != null:
		vorticity.set_shader_parameter("dt", _frame_delta)

	var advect_density := _pass_material("advect_density")
	if advect_density != null:
		advect_density.set_shader_parameter("dt", _frame_delta)

	_flush_splats()
	_apply_clear_frame()


## 把本帧累积的高斯源写进 uniform，然后清空队列（攒超过上限的会被丢弃，
## 因为雾气源本来就应该是稀疏的；丢弃比"排队到下一帧"更不容易产生时间错位）。
func _flush_splats() -> void:
	var count := mini(_splat_uv.size(), MAX_SPLATS)
	if count > 0:
		for i in range(MAX_SPLATS):
			if i < count:
				_splat_vectors[i] = Vector4(
					_splat_uv[i].x, _splat_uv[i].y, _splat_radius[i], _splat_density[i]
				)
				_splat_forces[i] = Vector4(
					_splat_velocity[i].x, _splat_velocity[i].y,
					_splat_velocity_rate[i], _splat_radial[i]
				)
				_splat_swirl_values[i] = _splat_swirl[i]
			else:
				_splat_vectors[i] = Vector4.ZERO
				_splat_forces[i] = Vector4.ZERO
				_splat_swirl_values[i] = 0.0

	var advect_velocity := _pass_material("advect_velocity")
	if advect_velocity != null:
		advect_velocity.set_shader_parameter("splat_count", count)
		advect_velocity.set_shader_parameter("splats", _splat_vectors)
		advect_velocity.set_shader_parameter("splat_force", _splat_forces)
		advect_velocity.set_shader_parameter("splat_swirl", _splat_swirl_values)

	var advect_density := _pass_material("advect_density")
	if advect_density != null:
		advect_density.set_shader_parameter("splat_count", count)
		advect_density.set_shader_parameter("splats", _splat_vectors)

	_splat_uv.clear()
	_splat_radius.clear()
	_splat_velocity.clear()
	_splat_velocity_rate.clear()
	_splat_radial.clear()
	_splat_swirl.clear()
	_splat_density.clear()


# =========================================================
# 对外注入接口
# =========================================================

## 投一个高斯源（雾气源/热源/角色带起的风）。
## uv                  域坐标（0..1），用 world_to_uv() 换算
## radius_uv           半径（域比例，0.05 ≈ 域宽的 5%）
## target_velocity     该处的**目标速度**（域单位/秒）；Vector2.ZERO = 只投浓度
## velocity_rate       速度松弛速率（1/秒）：越大越快把这片区域拉到目标速度
## radial_speed        径向排开速度（域单位/秒）：>0 时该区域的速度被推向"离开源中心"的方向
##                     （物体挤开介质）。等价于 FluidNinja 的 OutwardVelocityMult。
## density_rate        浓度变化速率（每秒）：0.5 = 半秒把一格灌满；0 = 只推速度
##                     ★ **允许负值**：负值就是"把雾推开/挖掉"（角色穿过雾时挖洞），
##                       浓度通道最后会 clamp 到 0..1，所以不会出现负浓度。
## swirl               绕心**切向**速度（域单位/秒）：>0 / <0 = 两个旋转方向，0 = 关闭
##                     （**0 时逐字等于旧行为**）。它给目标速度叠加一个绕源中心的切向量，
##                     浓度会被这个环流卷成螺旋 —— "角色跑过、雾绕着转"就靠它。
func add_splat(uv: Vector2, radius_uv: float, target_velocity: Vector2,
		velocity_rate: float, density_rate: float, radial_speed: float = 0.0,
		swirl: float = 0.0) -> void:
	if _splat_uv.size() >= MAX_SPLATS:
		return
	_splat_uv.append(Vector2(clampf(uv.x, 0.0, 1.0), clampf(uv.y, 0.0, 1.0)))
	_splat_radius.append(maxf(radius_uv, 0.01))
	_splat_velocity.append(target_velocity)
	_splat_velocity_rate.append(maxf(velocity_rate, 0.0))
	_splat_radial.append(maxf(radial_speed, 0.0))
	_splat_swirl.append(swirl)
	# 只夹到 [-1, 1]：负值用来"挖雾"，绝对值过大反而会让单帧变化过猛
	_splat_density.append(clampf(density_rate, -1.0, 1.0))


## 设定风的目标速度（域单位/秒）。FogField 会把天气的风向/风力换算成这个值。
## 设置画笔底图的**吸引增益**（对应 FogField.density_gain / 面板"浓度增益"）。
## ★ 必须**立即**重传材质参数：原先 base_gain 只在 _apply_static_uniforms()（建场/rebuild）
##   里写一次，于是运行中改这个值当场无效、要手动点"重建" —— 这正是用户实测的
##   "部分属性设置后在游戏中不生效"之一。
## 用 _pass_material(name) 而不是缓存材质引用：那两个材质在 _apply_static_uniforms 里
## 是**局部变量**，这里拿不到；_pass_material 是求解器自己的公开查询接口。
func set_base_gain(value: float) -> void:
	base_gain = maxf(value, 0.0)
	for pass_name in ["advect_density", "composite"]:
		var material := _pass_material(pass_name)
		if material != null:
			material.set_shader_parameter("base_gain", base_gain)


## 设定底图**地板**强度（0..1，1 = 旧行为）。同样**立即**重传（见 set_base_gain 的注记）：
## 运行中把它从 1 改成 0，下一帧起角色/法术的挖雾就能把可见浓度压下去。
func set_base_floor(value: float) -> void:
	base_floor = clampf(value, 0.0, 1.0)
	var composite := _pass_material("composite")
	if composite != null:
		composite.set_shader_parameter("base_floor", base_floor)


func set_wind(velocity_domain: Vector2) -> void:
	wind_velocity = velocity_domain


## 上传画笔底图（灰度图，R 通道即浓度）。传 null 表示清空底图。
func set_base_density_image(image: Image) -> void:
	if image == null:
		_base_texture = null
	else:
		if _base_texture == null or _base_texture.get_width() != image.get_width():
			_base_texture = ImageTexture.create_from_image(image)
		else:
			_base_texture.update(image)
	_apply_base_texture()


## 底图纹理（自检/调试用）。
func base_texture() -> Texture2D:
	return _base_texture


func _apply_base_texture() -> void:
	if not _ready_done:
		return
	# 没有底图时给一张全 0 的兜底纹理：uniform 为 null 会让着色器采样到未定义内容。
	var texture: Texture2D = _base_texture
	if texture == null:
		texture = _blank_texture()
	for pass_name in ["advect_density", "composite"]:
		var material := _pass_material(pass_name)
		if material != null:
			material.set_shader_parameter("base_tex", texture)


var _blank: ImageTexture


func _blank_texture() -> ImageTexture:
	if _blank == null:
		var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		image.fill(Color(0.0, 0.0, 0.0, 1.0))
		_blank = ImageTexture.create_from_image(image)
	return _blank


## 清空模拟浓度（**底图不受影响**：画笔刷出来的雾会在随后几帧慢慢长回来）。
## 实现：让合成通道连着两帧输出 0。为什么两帧：浓度是"上一帧合成结果"环回喂进来的，
## 清一帧能断掉环回，多清一帧是为了对通道调度留余量（有求于渲染顺序时不要卡在边界上）。
func clear_density() -> void:
	_clear_frames = 2


func _apply_clear_frame() -> void:
	var composite := _pass_material("composite")
	if composite == null:
		return
	var active := 1.0 if _clear_frames > 0 else 0.0
	composite.set_shader_parameter("clear_request", active)
	if _clear_frames > 0:
		_clear_frames -= 1


var _clear_frames := 0


## 运行时改过物理参数（耗散/涡量/平滑/底图增益）之后调用一次，把常量重新写进材质。
## 为什么需要它：这些值是 setup 时一次性写进 uniform 的（每帧重写纯属浪费），
## 改了属性不会自动生效 —— 忘记调用会表现为"参数调了画面没反应"。
func refresh_materials() -> void:
	_apply_static_uniforms()


# =========================================================
# 坐标换算与查询
# =========================================================

## 世界坐标 -> 域坐标（0..1；域外会被钳到边界）。v 方向对应世界 Z。
func world_to_uv(world_position: Vector3) -> Vector2:
	var center := _domain_center()
	var local := world_position - center
	return Vector2(
		clampf(local.x / maxf(domain_size.x, 0.001) + 0.5, 0.0, 1.0),
		clampf(local.z / maxf(domain_size.y, 0.001) + 0.5, 0.0, 1.0)
	)


## 域坐标 -> 世界坐标（y = 域底面高度）。
func uv_to_world(uv: Vector2) -> Vector3:
	var center := _domain_center()
	return Vector3(
		center.x + (uv.x - 0.5) * domain_size.x,
		center.y,
		center.z + (uv.y - 0.5) * domain_size.y
	)


## 域中心（世界坐标，y = 父节点高度 + base_height）。
## ★ base_height 是**相对父节点**的偏移：拖动 FogField 节点整个雾层会跟着走，
##   再抬 base_height 把雾层提离地面 —— 比用绝对世界高度直观得多。
func _domain_center() -> Vector3:
	var parent_3d := get_parent() as Node3D
	var origin := Vector3.ZERO
	if parent_3d != null:
		origin = parent_3d.global_position
	return origin + Vector3(0.0, base_height, 0.0)


## 域中心（世界坐标），供渲染节点对齐。
func domain_center() -> Vector3:
	return _domain_center()


## 最终速度场纹理（体积雾/粒子采样用）。
func velocity_texture() -> Texture2D:
	return _pass_texture("gradient")


## 合成后的雾浓度纹理（体积雾采样用）。
func density_texture() -> Texture2D:
	return _pass_texture("composite")


## 通道数量（自检用：应等于 8 + jacobi_passes）。
func pass_count() -> int:
	return _passes.size()


## 通道名列表（自检用，顺序即渲染顺序）。
func pass_names() -> Array:
	var names := []
	for entry in _passes:
		names.append(entry["name"])
	return names


## 回读任意通道的结果（自检/调试用）。
## ★ 会触发 GPU→CPU 同步，**严禁每帧调用**（每帧回读等于把 GPU 流水线掐停，
##   正是我们当初放弃 RenderingDevice compute 的原因）。仅在自检脚本里用。
func read_pass_image(pass_name: String) -> Image:
	var entry: Dictionary = _by_name.get(pass_name, {})
	if entry.is_empty():
		return null
	var viewport: SubViewport = entry["viewport"]
	if not is_instance_valid(viewport):
		return null
	var texture := viewport.get_texture()
	if texture == null:
		return null
	return texture.get_image()


## 回读最终雾浓度场（自检用）。
func read_density_image() -> Image:
	return read_pass_image("composite")


## 回读最终速度场（自检用）。
func read_velocity_image() -> Image:
	return read_pass_image("gradient")


## 回读"投影之前"的速度场（涡量约束通道的输出，自检用它做 A/B 对照）。
func read_pre_projection_velocity_image() -> Image:
	return read_pass_image("vorticity")


## 按 CPU 参考实现的同一套离散格式，从回读图像算最大散度（自检用）。
## margin = 跳过的边界带宽度（紧贴固壁那几圈的散度由边界条件决定，投影管不到）。
static func max_divergence_from_image(image: Image, margin: int = 2) -> float:
	if image == null:
		return -1.0
	var width := image.get_width()
	var height := image.get_height()
	if width < 4 or height < 4:
		return -1.0
	var h := 1.0 / float(width)
	var worst := 0.0
	for j in range(maxi(1, margin), height - maxi(1, margin)):
		for i in range(maxi(1, margin), width - maxi(1, margin)):
			var u_right := image.get_pixel(i + 1, j).r
			var u_left := image.get_pixel(i - 1, j).r
			var v_up := image.get_pixel(i, j + 1).g
			var v_down := image.get_pixel(i, j - 1).g
			var divergence := -0.5 * h * ((u_right - u_left) + (v_up - v_down))
			worst = maxf(worst, absf(divergence))
	return worst


## 从回读图像算最大速度模长（自检用来判断"场是不是真的在动"）。
static func max_speed_from_image(image: Image, margin: int = 2) -> float:
	if image == null:
		return -1.0
	var worst := 0.0
	for j in range(maxi(1, margin), image.get_height() - maxi(1, margin)):
		for i in range(maxi(1, margin), image.get_width() - maxi(1, margin)):
			var pixel := image.get_pixel(i, j)
			worst = maxf(worst, Vector2(pixel.r, pixel.g).length())
	return worst


## 从回读图像算平均速度模长（自检用来判断"场是均匀的还是有局部结构"）。
static func mean_speed_from_image(image: Image, margin: int = 2) -> float:
	if image == null:
		return -1.0
	var total := 0.0
	var count := 0
	for j in range(maxi(1, margin), image.get_height() - maxi(1, margin)):
		for i in range(maxi(1, margin), image.get_width() - maxi(1, margin)):
			var pixel := image.get_pixel(i, j)
			total += Vector2(pixel.r, pixel.g).length()
			count += 1
	return total / float(maxi(count, 1))


## 从回读图像算浓度的重心（域坐标 x；自检用来验证"风把雾吹走了"）。
static func density_centroid_x_from_image(image: Image) -> float:
	if image == null:
		return -1.0
	var total := 0.0
	var acc := 0.0
	for j in range(image.get_height()):
		for i in range(image.get_width()):
			var value := image.get_pixel(i, j).r
			if value <= 0.0:
				continue
			total += value
			acc += float(i) * value
	if total <= 0.0:
		return -1.0
	return acc / total / float(image.get_width())


## 从回读图像算平均浓度（自检用）。
static func mean_from_image(image: Image) -> float:
	if image == null:
		return -1.0
	var sum := 0.0
	for j in range(image.get_height()):
		for i in range(image.get_width()):
			sum += image.get_pixel(i, j).r
	return sum / float(image.get_width() * image.get_height())

extends Node3D
## 跑动脚底灰尘：**落脚时喷一次**，左右脚交替（两个 GPUParticles3D，one_shot 爆发）。
##
## 触发方式：按**走过的水平距离**判定落脚（每 STRIDE_LENGTH 米 = 一步）。
##   -> 跑得越快，落脚越频繁，灰尘自然越多越大；而且不依赖动画事件，侧移/后退也正常。
##   -> 只有"扬尘强度 > 0"（在地面且有速度）时才累计与触发。
##
## 用法：
##   const RunDustScript := preload("res://scripts/run_dust.gd")
##   if RunDustScript.is_supported():      # headless 下别加进场景树（见下）
##       _dust = RunDustScript.new()
##       add_child(_dust)
##   _dust.set_intensity(0.7)              # 0~1，由调用方按"实际水平速度"算好

# ==================== 可调参数（全在这里） ====================
const FOOT_SPREAD_X := 0.11      # 左右脚横向偏移（两团灰的距离）
const STRIDE_LENGTH := 0.45      # ★ 每走/跑这么远算"落一次脚"（按你的步幅调）
const BURST_AMOUNT := 14         # ★ 每次落脚喷多少颗（满额；实际 = BURST_AMOUNT × 强度）
const QUAD_SIZE := 0.12          # 尘片基准边长（有效大小 = QUAD_SIZE * scale）
const SCALE_MIN := 0.14          # 慢速缩放区间
const SCALE_MAX := 0.36
const SCALE_MIN_FAST := 0.26     # 全速缩放区间
const SCALE_MAX_FAST := 0.68
const LIFETIME := 0.85
const COLOR := Color(0.72, 0.66, 0.55, 0.55)   # 灰土色
const SPREAD := 35.0
const VEL_MIN := 0.15
const VEL_MAX := 0.90
const GRAVITY_Y := 0.35          # 轻微上浮（尘）
const DAMP_MIN := 0.8
const DAMP_MAX := 2.0
const EMIT_RADIUS := 0.05        # 每只脚内的小簇半径
const OFFSET_Y := 0.02           # 脚底高度
const EXPLOSIVENESS := 1.0       # 一次全喷出来（落脚是一瞬间）
const LOCAL_AABB := AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 3.0, 4.0))

var _left: GPUParticles3D = null
var _right: GPUParticles3D = null
var _mat: ParticleProcessMaterial = null
var _intensity := 0.0
var _dist := 0.0                 # 距离累计（走满 STRIDE_LENGTH 就落一次脚）
var _last_pos := Vector3.ZERO
var _next_foot := 0              # 0 = 下次左脚，1 = 下次右脚


## headless（无渲染设备）下 GPUParticles3D 一旦进入场景树会把进程卡死 —— 实测确认。
## 调用方在无头环境（自动化测试/CI）请**不要**创建或加入本节点。
static func is_supported() -> bool:
	return DisplayServer.get_name() != "headless"


func _ready() -> void:
	if not is_supported():
		return
	_setup()
	_last_pos = _here()


func _process(_delta: float) -> void:
	# 不扬尘时只跟位置，不累计
	var p := _here()
	if _intensity <= 0.02:
		_last_pos = p
		return
	_dist += Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
	_last_pos = p
	if _dist >= STRIDE_LENGTH:
		_dist = 0.0
		trigger_step()


## 当前位置：入树用世界坐标（角色旋转/位移都算得准）；未入树（自检）退化成局部坐标
func _here() -> Vector3:
	return global_position if is_inside_tree() else position


## ★ 触发一次落脚灰尘：左右脚交替，喷的量随强度
func trigger_step() -> void:
	var foot: GPUParticles3D = _left if _next_foot == 0 else _right
	_next_foot = 1 - _next_foot
	if foot == null:
		return
	foot.amount_ratio = _intensity     # 跑得越快 -> 这一脚喷得越多
	foot.restart()


## intensity: 0~1（0 = 不扬尘）。决定"每脚喷多少"和"尘团多大"
func set_intensity(intensity: float) -> void:
	var r := clampf(intensity, 0.0, 1.0)
	_intensity = r
	if _mat != null:
		_mat.scale_min = lerpf(SCALE_MIN, SCALE_MIN_FAST, r)
		_mat.scale_max = lerpf(SCALE_MAX, SCALE_MAX_FAST, r)


func get_intensity() -> float:
	return _intensity


## 程序化生成一张柔和圆斑（不依赖任何美术资源）
func _make_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.45, Color(1, 1, 1, 0.55))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.width = 64
	tex.height = 64
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex


func _make_quad() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(QUAD_SIZE, QUAD_SIZE)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true      # ★ 不开的话粒子颜色/淡出都不生效
	sm.albedo_texture = _make_texture()
	quad.material = sm
	return quad


## 造一只脚的发射器（两只脚共享同一个材质：省资源，缩放改一次就够）
func _make_foot(offset_x: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = BURST_AMOUNT
	p.lifetime = LIFETIME
	p.local_coords = false                    # ★ 灰尘留在世界里，不跟着角色跑
	p.one_shot = true                         # ★ 一次爆发（落脚是一瞬间）
	p.explosiveness = EXPLOSIVENESS
	p.draw_pass_1 = _make_quad()
	p.process_material = _mat
	p.position = Vector3(offset_x, OFFSET_Y, 0.0)   # ★ 左脚 / 右脚
	p.visibility_aabb = LOCAL_AABB
	p.emitting = false
	p.amount_ratio = 0.0
	return p


func _setup() -> void:
	# 颜色随时间淡出（与 color 相乘）
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	var rtex := GradientTexture1D.new()
	rtex.gradient = ramp

	_mat = ParticleProcessMaterial.new()
	_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_mat.emission_sphere_radius = EMIT_RADIUS
	_mat.direction = Vector3(0, 1, 0)
	_mat.spread = SPREAD
	_mat.initial_velocity_min = VEL_MIN
	_mat.initial_velocity_max = VEL_MAX
	_mat.gravity = Vector3(0, GRAVITY_Y, 0)
	_mat.damping_min = DAMP_MIN
	_mat.damping_max = DAMP_MAX
	_mat.scale_min = SCALE_MIN
	_mat.scale_max = SCALE_MAX
	_mat.color = COLOR
	_mat.color_ramp = rtex

	_left = _make_foot(-FOOT_SPREAD_X)
	_left.name = "DustLeft"
	_right = _make_foot(FOOT_SPREAD_X)
	_right.name = "DustRight"
	add_child(_left)
	add_child(_right)
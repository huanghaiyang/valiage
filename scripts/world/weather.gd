extends Node
## 天气系统（自动加载单例）
## 支持：晴 / 多云 / 阴 / 小雨 / 雷雨 / 大风，带平滑过渡与风的阵风脉动。
## 植被风摇通过全局着色器 uniform 驱动（见 assets/shaders/vegetation_wind.gdshader）。
## 参考《辐射 76》的天气思路：天气是一个"状态机 + 连续参数"，风是独立可调维度。

signal weather_changed(kind: int)

enum Kind { CLEAR, CLOUDY, OVERCAST, RAIN, STORM, WINDY }

const KIND_NAMES := {
	Kind.CLEAR: "晴朗",
	Kind.CLOUDY: "多云",
	Kind.OVERCAST: "阴天",
	Kind.RAIN: "小雨",
	Kind.STORM: "雷雨",
	Kind.WINDY: "大风",
}

## 每种天气的目标参数
## wind: 风力(0..1.5)  gust: 阵风(0..1)  turb: 湍流  cloud: 云量(0..1)
## rain: 雨量(0..1)  fog: 雾浓度(0..1)  light: 阳光强度系数
const PRESETS := {
	Kind.CLEAR:    {"wind": 0.18, "gust": 0.15, "turb": 0.30, "cloud": 0.035, "rain": 0.0, "fog": 0.0, "light": 1.00},
	Kind.CLOUDY:   {"wind": 0.35, "gust": 0.30, "turb": 0.40, "cloud": 0.55, "rain": 0.0, "fog": 0.05, "light": 0.85},
	Kind.OVERCAST: {"wind": 0.45, "gust": 0.35, "turb": 0.45, "cloud": 0.85, "rain": 0.0, "fog": 0.12, "light": 0.65},
	Kind.RAIN:     {"wind": 0.60, "gust": 0.50, "turb": 0.55, "cloud": 0.90, "rain": 0.45, "fog": 0.22, "light": 0.50},
	Kind.STORM:    {"wind": 1.10, "gust": 0.90, "turb": 0.80, "cloud": 1.00, "rain": 1.00, "fog": 0.35, "light": 0.32},
	Kind.WINDY:    {"wind": 0.95, "gust": 0.70, "turb": 0.65, "cloud": 0.35, "rain": 0.0, "fog": 0.05, "light": 0.90},
}

## 当前 / 目标天气
var current: int = Kind.CLEAR
var target: int = Kind.CLEAR
## 过渡进度（0..1）
var blend := 1.0
## 过渡时长（秒）
@export var transition_time := 8.0
## 是否自动变化天气（可关闭，交给脚本/UI 控制）
@export var auto_change := true
## 自动变化的最小/最大间隔（秒）
@export var auto_min_time := 90.0
@export var auto_max_time := 240.0

## 当前连续参数（对外可读，也是着色器 uniform 的来源）
var wind := 0.18
var wind_gust := 0.15
var wind_turbulence := 0.30
var wind_speed := 1.4
var cloud := 0.10
var rain := 0.0
var fog := 0.0
var light_scale := 1.0

## 风向（水平单位向量）
var wind_dir := Vector2(1.0, 0.0)
## 风向缓慢漂移的相位
## --- 风向：每隔一段时间随机挑一个新方向，再平滑转过去 ---
@export var wind_dir_interval_min := 18.0   ## 换风向最短间隔（秒）
@export var wind_dir_interval_max := 45.0   ## 最长间隔
@export var wind_dir_turn_time := 6.0       ## 转向耗时（秒，越大越平缓）
var _dir_phase := 0.0
var _dir_current := PI * 0.35               ## 当前风向角
var _dir_target := PI * 0.35                ## 目标风向角
var _dir_timer := 12.0                      ## 距离下次换向
var _rng := RandomNumberGenerator.new()
var _auto_timer := 0.0

## 场景引用（由 main 注入）
var _sun: DirectionalLight3D = null
var _env: WorldEnvironment = null
var _base_sun_energy := 1.28
var _base_ambient := 0.85
var _rain_particles: GPUParticles3D = null
## 云穹顶半径（米）。穹顶整体挂在相机上，用视线仰角决定 alpha，
## 这样地面相机抬头就能看到云（平面方案在几何上根本看不到，见 shader 注释）。
## 半径必须**小于相机远裁剪面**（main.tscn 的 Camera3D.far = 1200），
## 否则整个穹顶被裁掉、云完全不可见（这是第二版失效的原因）。
const CLOUD_DOME_RADIUS := 900.0
## 云层（跟随相机的程序化云平面）
var _clouds: MeshInstance3D = null
var _cloud_mat: ShaderMaterial = null
var _sky_mat: ProceduralSkyMaterial = null
## 植被风摇材质（由 main 注入）。每个植物分类一份，sway_scale 不同、风参数相同。
var _wind_materials: Array[ShaderMaterial] = []

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	_auto_timer = _rng.randf_range(auto_min_time, auto_max_time)
	_apply_shader_params()

## 运行期新增的风摇材质（玩家放置的植物是一株一份，放置时才建）也要吃到风。
## 单靠 bind_world 一次性注入不够：那时植物的材质还没创建。
func add_wind_material(m: ShaderMaterial) -> void:
	if m == null or _wind_materials.has(m):
		return
	_wind_materials.append(m)
	_apply_shader_params()


## 由 main 注入场景引用（太阳/环境），并创建雨粒子
func bind_world(sun: DirectionalLight3D, env: WorldEnvironment, rain_parent: Node3D,
		wind_materials: Array = []) -> void:
	_sun = sun
	_env = env
	_wind_materials.clear()
	for m in wind_materials:
		if m is ShaderMaterial:
			_wind_materials.append(m as ShaderMaterial)
	_ensure_clouds(rain_parent)
	if _env != null and _env.environment != null:
		var sk := _env.environment.sky
		if sk != null and sk.sky_material is ProceduralSkyMaterial:
			_sky_mat = sk.sky_material as ProceduralSkyMaterial
	_apply_shader_params()
	_apply_world()
	if sun != null:
		_base_sun_energy = sun.light_energy
	if env != null and env.environment != null:
		_base_ambient = env.environment.ambient_light_energy
	_ensure_rain(rain_parent)

## 设置天气（带过渡）；force=true 立即生效
func set_weather(kind: int, force := false) -> void:
	if kind < 0 or kind > Kind.WINDY:
		return
	target = kind
	blend = 1.0 if force else 0.0
	if force:
		current = kind
	weather_changed.emit(kind)

func weather_name() -> String:
	return KIND_NAMES.get(current, "未知")

func _process(delta: float) -> void:
	# 自动换天气
	if auto_change:
		_auto_timer -= delta
		if _auto_timer <= 0.0 and blend >= 1.0:
			_auto_timer = _rng.randf_range(auto_min_time, auto_max_time)
			var next: int = int(_pick_next_weather())
			set_weather(next)
	# 过渡
	if blend < 1.0 and transition_time > 0.0:
		blend = minf(1.0, blend + delta / transition_time)
		if blend >= 1.0:
			current = target
	_update_params(delta)
	_apply_world()
	_apply_shader_params()

func _pick_next_weather() -> int:
	# 简单权重：相邻天气更常见，避免突兀的暴风雨
	var options: Array = []
	match current:
		Kind.CLEAR: options = [Kind.CLOUDY, Kind.CLOUDY, Kind.WINDY]
		Kind.CLOUDY: options = [Kind.CLEAR, Kind.OVERCAST, Kind.WINDY]
		Kind.OVERCAST: options = [Kind.CLOUDY, Kind.RAIN]
		Kind.RAIN: options = [Kind.OVERCAST, Kind.STORM]
		Kind.STORM: options = [Kind.RAIN, Kind.OVERCAST]
		Kind.WINDY: options = [Kind.CLEAR, Kind.CLOUDY]
	return options[_rng.randi_range(0, options.size() - 1)]

## 在 from -> to 之间插值出当前连续参数
func _update_params(delta: float) -> void:
	var a: Dictionary = PRESETS.get(current, PRESETS[Kind.CLEAR])
	var b: Dictionary = PRESETS.get(target, a)
	var t: float = blend if current != target else 1.0
	# ★ 缓动：线性插值是「匀速直线变过去」，很生硬；
	# 用 smoothstep 做成「缓慢起步 -> 中段快 -> 缓慢收尾」，风/云/雨才有过渡感。
	t = t * t * (3.0 - 2.0 * t)
	var wdir := _wind_direction_now(delta)
	for key in ["wind", "gust", "turb", "cloud", "rain", "fog", "light"]:
		var va := float(a.get(key, 0.0))
		var vb := float(b.get(key, va))
		var v := lerpf(va, vb, t)
		match key:
			"wind": wind = v
			"gust": wind_gust = v
			"turb": wind_turbulence = v
			"cloud": cloud = v
			"rain": rain = v
			"fog": fog = v
			"light": light_scale = v
	# 摆动频率：太快会像抽搐，太慢看不出在动。0.8~3.6 覆盖微风到暴风。
	wind_speed = lerpf(0.8, 3.6, clampf(wind, 0.0, 1.5))
	wind_dir = wdir

## 风向：每隔 wind_dir_interval_* 秒随机挑一个新方向（和当前至少差 60 度，
## 免得「换了像没换」），再用 wind_dir_turn_time 平滑转过去 —— 不会突然跳变。
## 另外叠一点很慢的低频摆动，让风有呼吸感（幅度很小，不抢主导方向）。
func _wind_direction_now(delta: float) -> Vector2:
	_dir_timer -= delta
	if _dir_timer <= 0.0:
		_dir_timer = _rng.randf_range(wind_dir_interval_min, wind_dir_interval_max)
		_dir_target = wrapf(_dir_current + _rng.randf_range(1.05, TAU - 1.05), 0.0, TAU)
	var ft := clampf(delta / maxf(0.01, wind_dir_turn_time), 0.0, 1.0)
	ft = ft * ft * (3.0 - 2.0 * ft)                 # 转向也缓入缓出
	_dir_current = lerp_angle(_dir_current, _dir_target, ft)
	_dir_phase += delta * 0.35
	var ang := _dir_current + sin(_dir_phase) * 0.12
	return Vector2(cos(ang), sin(ang))

## 把当前风参数写进植被共享材质：所有植被按同一风向摆动。
##
## 不能用全局着色器参数（global uniform / RenderingServer.global_shader_parameter_*）：
## Godot 4.7 运行时下那套 API 是坏的 —— get_list() 恒为空、add()/set() 被静默忽略，
## set_override() 也只到片元阶段，顶点阶段永远拿 project.godot 的默认值，
## 表现就是代码全在、画面不动。直接写材质 uniform 才真正生效。
func _apply_shader_params() -> void:
	if _wind_materials.is_empty():
		return
	for m in _wind_materials:
		m.set_shader_parameter("wind_direction", wind_dir)
		m.set_shader_parameter("wind_strength", wind)
		m.set_shader_parameter("wind_gust", wind_gust)
		m.set_shader_parameter("wind_speed", wind_speed)
		m.set_shader_parameter("wind_turbulence", wind_turbulence)

## 应用到太阳/环境/雨
func _apply_world() -> void:
	if _sun != null:
		_sun.light_energy = _base_sun_energy * light_scale
	if _env != null and _env.environment != null:
		var e: Environment = _env.environment
		e.ambient_light_energy = _base_ambient * lerpf(1.0, 0.55, cloud)
		# 雾：晴朗/多云基本不起雾，只有阴天以后才有明显空气感。
		# 旧版 fog>0.01 就开雾 + 体积雾系数 0.02，晴朗天就把整个山谷洗成一层灰，
		# 低多边形配色全被糊掉 —— 所以阈值抬到 0.18 并大幅压低浓度。
		e.fog_enabled = fog > 0.18
		e.fog_density = maxf(0.0, fog - 0.18) * 0.004
		e.fog_light_color = Color(0.72, 0.76, 0.80)
		e.volumetric_fog_enabled = fog > 0.45
		e.volumetric_fog_density = maxf(0.0, fog - 0.45) * 0.006
	# 阴沉程度：驱动天色、云色、太阳盘的统一参数
	var dark := clampf(cloud, 0.0, 1.0)
	if _sky_mat != null:
		_sky_mat.sky_top_color = Color(0.22, 0.45, 0.82).lerp(Color(0.30, 0.33, 0.40), dark)
		_sky_mat.sky_horizon_color = Color(0.72, 0.85, 0.98).lerp(Color(0.52, 0.55, 0.60), dark)
		_sky_mat.sky_curve = lerpf(0.10, 0.28, dark)
		_sky_mat.ground_horizon_color = _sky_mat.sky_horizon_color
		_sky_mat.ground_bottom_color = Color(0.30, 0.34, 0.30).lerp(Color(0.20, 0.21, 0.22), dark)
		# 太阳盘：晴天明显，阴雨天被云盖住
		_sky_mat.sun_angle_max = lerpf(12.0, 100.0, dark)
		_sky_mat.sun_curve = lerpf(0.06, 0.5, dark)
	if _cloud_mat != null:
		# 云量：晴朗 0.10 只有几缕，雷雨 1.0 满天积雨云
		_cloud_mat.set_shader_parameter("coverage", clampf(cloud * 1.15, 0.0, 1.05))
		_cloud_mat.set_shader_parameter("density", lerpf(0.55, 0.97, clampf(cloud, 0.0, 1.0)))
		_cloud_mat.set_shader_parameter("wind_dir", wind_dir)
		_cloud_mat.set_shader_parameter("wind_speed", wind_speed)
		var lit := Color(1.0, 0.985, 0.95).lerp(Color(0.72, 0.75, 0.80), dark)
		var shad := Color(0.60, 0.645, 0.72).lerp(Color(0.32, 0.35, 0.41), dark)
		_cloud_mat.set_shader_parameter("cloud_lit", lit)
		_cloud_mat.set_shader_parameter("cloud_shadow", shad)
		_cloud_mat.set_shader_parameter("cloud_scale", 2.4)
		_cloud_mat.set_shader_parameter("horizon_start", 0.03)
		_cloud_mat.set_shader_parameter("horizon_end", 0.34)
	if _rain_particles != null:
		_rain_particles.emitting = rain > 0.02
		_rain_particles.amount_ratio = clampf(rain, 0.0, 1.0)

## 云层：一张 1800m 见方的平面，程序化云块 + 随风漂移，跟随相机水平位置。
## 用 alpha 在半径处淡出，所以平面边界看不见。
## 云穹顶：一个挂在相机上的半球，程序化云块 + 随风漂移，由视野仰角控制透明度。
## 必须挂在相机上（而不是放在世界某处）：穹顶跟着镜头走，云才像无限远。
func _ensure_clouds(parent: Node3D) -> void:
	if parent == null or _clouds != null:
		return
	var sphere := SphereMesh.new()
	sphere.radius = CLOUD_DOME_RADIUS
	sphere.height = CLOUD_DOME_RADIUS * 2.0
	sphere.radial_segments = 96
	sphere.rings = 32
	sphere.is_hemisphere = true
	_clouds = MeshInstance3D.new()
	_clouds.name = "WeatherClouds"
	_clouds.mesh = sphere
	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = load("res://assets/shaders/clouddome.gdshader")
	_cloud_mat.set_shader_parameter("coverage", 0.35)
	_cloud_mat.set_shader_parameter("density", 0.9)
	_clouds.material_override = _cloud_mat
	_clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 只画天空那一半；穹顶是摄像机子节点，局部坐标即视线方向
	_clouds.extra_cull_margin = CLOUD_DOME_RADIUS
	parent.add_child(_clouds)

func _ensure_rain(parent: Node3D) -> void:
	if parent == null or _rain_particles != null:
		return
	var p := GPUParticles3D.new()
	p.name = "WeatherRain"
	p.amount = 1400
	p.lifetime = 1.4
	p.visibility_aabb = AABB(Vector3(-60, -20, -60), Vector3(120, 60, 120))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(45, 1, 45)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 4.0
	pm.initial_velocity_min = 16.0
	pm.initial_velocity_max = 22.0
	pm.gravity = Vector3(0, -9.8, 0)
	# 风向影响雨滴落角
	pm.direction = Vector3(wind_dir.x * 0.25, -1.0, wind_dir.y * 0.25).normalized()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.02, 0.5, 0.02)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.72, 0.80, 0.92, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	p.process_material = pm
	p.draw_pass_1 = mesh
	p.emitting = false
	parent.add_child(p)
	_rain_particles = p

## 让雨盒 / 云层跟随相机（由 main 每帧调用）
func follow_camera(cam: Camera3D) -> void:
	if cam == null:
		return
	if _clouds != null:
		# 穹顶完全跟随相机（含高度与旋转），顶点局部坐标才等于视线方向
		_clouds.global_transform = cam.global_transform
	if _rain_particles == null:
		return
	_rain_particles.global_position = cam.global_position + Vector3(0, 14.0, 0)

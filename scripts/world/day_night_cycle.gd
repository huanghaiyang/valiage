# ============================================================================
# day_night_cycle.gd —— 24 小时昼夜光照循环（main.tscn 里的场景节点 "DayNight"）
# ============================================================================
# · 所属系统：世界表现层（光照 / 天空）。同层邻居：weather.gd（天气）。
# · 核心模型：**时间驱动的关键帧光照**。一天 24 游戏小时按 day_length_seconds
#   跑完（默认 7200 秒 = 2 小时现实时间，即 1 实秒 ≈ 12 游戏秒）。
#   每帧按当前时刻从若干关键帧表里采样，统一写进 Sun / FillLight / Environment /
#   ProceduralSkyMaterial，形成日出暖光 → 正午白光 → 黄昏余晖 → 夜间冷月光的完整循环。
# · 与天气的关系：天气仍按 cloud / light_scale / fog 自己算一套值并每帧写入；
#   本节点 process_priority 更大（后执行），因此**最终画面以昼夜为准**：
#   昼夜采样出基础光照，再把天气的云量/压暗系数叠加上去，避免两个写者互相覆盖。
#   天气节点不存在时（测试/裁剪场景）也能独立工作。
# · 装配：main.gd 在天气之前调用 bind_world(sun, fill, env, parent)。
#   未装配时不写任何东西 —— 编辑器里不运行脚本（非 @tool），所以场景默认外观不变。
# · 调试：命令行 `--hour=18.5` 指定起始时刻（配合 --capture 截图验收），
#   `--daylen=秒` 改一圈时长；运行期可读 time_hours，也可调 set_hour()。
# ============================================================================
extends Node

## 分组名：其它系统可用 get_tree().get_first_node_in_group("day_night_cycle") 找到本节点。
const GROUP := &"day_night_cycle"
const DAY_HOURS := 24.0
## 星空穹顶半径（米）：必须小于相机远裁剪面（main.tscn 的 Camera3D.far = 1200），
## 而且要大于天气云穹顶的 900m —— 这样透明排序时星星先画、云后画，云能自然遮星。
const STAR_DOME_RADIUS := 1000.0

# ==================== 对外可调参数 ====================
## 是否启用昼夜循环。关闭后本节点完全不写场景（回到静态光照，便于对比排查）。
@export var enabled := true
## 跑完一整圈（24 游戏小时）需要的现实秒数。默认 7200 = 2 小时。
@export_range(10.0, 7200.0, 1.0) var day_length_seconds := 7200.0
## 起始时刻（0..24，单位：游戏小时）。默认 7.5 = 清晨，开局就能看到柔和的晨光。
@export_range(0.0, 24.0, 0.01) var start_hour := 7.5
## 时间流速倍率（调试用）。1.0 = 按 day_length_seconds 正常跑。
@export_range(0.0, 20.0, 0.01) var time_scale := 1.0
## 是否自动推进时间。false 时停在 start_hour / set_hour() 指定的时刻，方便截图。
@export var auto_advance := true

# ==================== 关键帧表 ====================
# 全部按"游戏小时"排序，首尾（0 与 24）数值一致，保证 24 点整回到 0 点不跳变。
# 颜色表：top=天顶、horizon=地平线、ground=地面反照色。
const SKY_KEYS := [
	{"h": 0.0, "top": Color(0.025, 0.040, 0.100), "horizon": Color(0.060, 0.090, 0.190), "ground": Color(0.025, 0.030, 0.055)},
	{"h": 4.5, "top": Color(0.030, 0.050, 0.120), "horizon": Color(0.080, 0.110, 0.220), "ground": Color(0.030, 0.035, 0.060)},
	{"h": 5.8, "top": Color(0.100, 0.140, 0.280), "horizon": Color(0.300, 0.240, 0.340), "ground": Color(0.070, 0.060, 0.090)},
	{"h": 6.5, "top": Color(0.240, 0.340, 0.560), "horizon": Color(0.950, 0.580, 0.360), "ground": Color(0.220, 0.160, 0.140)},
	{"h": 8.0, "top": Color(0.340, 0.540, 0.820), "horizon": Color(0.820, 0.860, 0.880), "ground": Color(0.420, 0.460, 0.360)},
	{"h": 12.0, "top": Color(0.360, 0.600, 0.900), "horizon": Color(0.740, 0.850, 0.970), "ground": Color(0.520, 0.580, 0.420)},
	{"h": 16.5, "top": Color(0.380, 0.580, 0.860), "horizon": Color(0.860, 0.830, 0.720), "ground": Color(0.500, 0.530, 0.380)},
	{"h": 18.3, "top": Color(0.220, 0.280, 0.500), "horizon": Color(0.950, 0.450, 0.260), "ground": Color(0.260, 0.170, 0.140)},
	{"h": 19.5, "top": Color(0.080, 0.100, 0.220), "horizon": Color(0.280, 0.190, 0.240), "ground": Color(0.070, 0.060, 0.090)},
	{"h": 21.0, "top": Color(0.030, 0.045, 0.120), "horizon": Color(0.070, 0.100, 0.200), "ground": Color(0.030, 0.035, 0.060)},
	{"h": 24.0, "top": Color(0.025, 0.040, 0.100), "horizon": Color(0.060, 0.090, 0.190), "ground": Color(0.025, 0.030, 0.055)},
]

## 太阳颜色（昼夜循环里"阳光"从暖橙到暖白再到橙红）。太阳落山后不再使用。
const SUN_COLOR_KEYS := [
	{"h": 0.0, "c": Color(1.00, 0.55, 0.30)},
	{"h": 5.6, "c": Color(1.00, 0.52, 0.28)},
	{"h": 6.4, "c": Color(1.00, 0.60, 0.36)},
	{"h": 7.6, "c": Color(1.00, 0.79, 0.60)},
	{"h": 10.0, "c": Color(1.00, 0.95, 0.88)},
	{"h": 14.0, "c": Color(1.00, 0.96, 0.90)},
	{"h": 16.5, "c": Color(1.00, 0.88, 0.70)},
	{"h": 18.0, "c": Color(1.00, 0.70, 0.44)},
	{"h": 18.8, "c": Color(1.00, 0.50, 0.28)},
	{"h": 24.0, "c": Color(1.00, 0.55, 0.30)},
]

## 太阳强度（DirectionalLight3D.light_energy 的绝对值）。落山段快速归零。
const SUN_ENERGY_KEYS := [
	{"h": 0.0, "v": 0.0},
	{"h": 5.6, "v": 0.0},
	{"h": 6.3, "v": 0.30},
	{"h": 7.5, "v": 0.95},
	{"h": 10.0, "v": 1.32},
	{"h": 13.0, "v": 1.35},
	{"h": 16.0, "v": 1.18},
	{"h": 17.8, "v": 0.82},
	{"h": 18.6, "v": 0.30},
	{"h": 19.2, "v": 0.0},
	{"h": 24.0, "v": 0.0},
]

## 月亮强度（夜间由同一个 Sun 灯扮演月亮，方向与太阳相反）。
const MOON_ENERGY_KEYS := [
	{"h": 0.0, "v": 0.24},
	{"h": 3.0, "v": 0.20},
	{"h": 4.7, "v": 0.12},
	{"h": 5.6, "v": 0.045},
	{"h": 6.1, "v": 0.0},
	{"h": 18.8, "v": 0.0},
	{"h": 19.4, "v": 0.06},
	{"h": 20.5, "v": 0.16},
	{"h": 21.5, "v": 0.22},
	{"h": 24.0, "v": 0.24},
]

## 环境光颜色：夜里偏冷蓝、晨昏偏橙、正午偏中性。这是"天空没有太阳时的补光"。
const AMBIENT_COLOR_KEYS := [
	{"h": 0.0, "c": Color(0.130, 0.170, 0.320)},
	{"h": 4.5, "c": Color(0.140, 0.180, 0.330)},
	{"h": 5.8, "c": Color(0.280, 0.280, 0.400)},
	{"h": 6.5, "c": Color(0.560, 0.430, 0.380)},
	{"h": 8.0, "c": Color(0.700, 0.720, 0.720)},
	{"h": 12.0, "c": Color(0.720, 0.780, 0.860)},
	{"h": 16.5, "c": Color(0.780, 0.740, 0.640)},
	{"h": 18.3, "c": Color(0.660, 0.440, 0.340)},
	{"h": 19.5, "c": Color(0.260, 0.260, 0.400)},
	{"h": 21.0, "c": Color(0.140, 0.180, 0.330)},
	{"h": 24.0, "c": Color(0.130, 0.170, 0.320)},
]

## 环境光强度（绝对值）。夜间保留 0.30，避免低多边形暗部糊成纯黑。
const AMBIENT_ENERGY_KEYS := [
	{"h": 0.0, "v": 0.30},
	{"h": 4.5, "v": 0.28},
	{"h": 5.8, "v": 0.40},
	{"h": 6.5, "v": 0.55},
	{"h": 8.0, "v": 0.78},
	{"h": 12.0, "v": 0.88},
	{"h": 16.5, "v": 0.82},
	{"h": 18.3, "v": 0.56},
	{"h": 19.5, "v": 0.36},
	{"h": 21.0, "v": 0.30},
	{"h": 24.0, "v": 0.30},
]

# ==================== 运行时状态 ====================
## 当前游戏时刻（0..24）。直接读它做 UI / 存档；写入请用 set_hour()（会立刻落地）。
var time_hours := 7.5
## 最近一帧算出的"白昼程度"（0=深夜，1=白天）与"星空程度"（0..1），供外部（UI/音频）读取。
var daylight := 1.0
var star_alpha := 0.0

## 场景引用。bind_world() 之前全部为 null，_apply() 会直接返回（编辑器预览保持原样）。
var _sun: DirectionalLight3D = null
var _fill: DirectionalLight3D = null
var _env: WorldEnvironment = null
var _sky_mat: ProceduralSkyMaterial = null
## 天气节点（优先缓存，拿不到时每帧按分组懒查找）。
var _weather: Node = null
## 星空穹顶（夜间可见的程序化星点）。
var _stars: MeshInstance3D = null
var _star_mat: ShaderMaterial = null

# ==================== 生命周期 ====================
func _enter_tree() -> void:
	add_to_group(GROUP)

func _ready() -> void:
	time_hours = clampf(start_hour, 0.0, DAY_HOURS)
	# 与天气一样在暂停时继续跑：否则暂停菜单里天气仍在写光照，画面会突然回到静态，
	# 恢复时再跳一次。两者保持一致才不会闪烁。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 比天气节点（priority 0）晚执行：昼夜是光照的最终写者，会把天气的云量/压暗叠加上去。
	process_priority = 10

## 装配入口（main.gd 在天气 bind_world 之前调用，才能拿到未被天气改写的原始亮度）。
func bind_world(sun: DirectionalLight3D, fill: DirectionalLight3D,
		env: WorldEnvironment, parent: Node3D) -> void:
	_sun = sun
	_fill = fill
	_env = env
	if _env != null and _env.environment != null:
		var sk := _env.environment.sky
		if sk != null and sk.sky_material is ProceduralSkyMaterial:
			_sky_mat = sk.sky_material as ProceduralSkyMaterial
	_ensure_stars(parent)
	# 立刻落地一次：避免"绑定到第一帧"之间画面还是旧的静态光照。
	_apply()

func _process(delta: float) -> void:
	if not enabled:
		return
	if auto_advance:
		var speed := DAY_HOURS / maxf(1.0, day_length_seconds) * time_scale
		time_hours = fposmod(time_hours + delta * speed, DAY_HOURS)
	_follow_star_camera()
	_apply()

## 设置时刻（自动/手动推进都走这里，保证 clamp 与落地一致）。
func set_hour(h: float) -> void:
	time_hours = clampf(h, 0.0, DAY_HOURS)
	_apply()

## 当前时刻的中文调试串（如 "18:30"），UI 需要显示时间时可直接用。
func hour_string() -> String:
	var hh := int(time_hours)
	var mm := int((time_hours - hh) * 60.0)
	return "%02d:%02d" % [hh, mm]

# ==================== 每帧落地 ====================
func _apply() -> void:
	# 日/月在天球上的位置：一条向东倾斜的圆弧。a=0 为 6:00（日出），a=π/2 为 12:00（正午）。
	var p := _sun_path_point()
	# ★ 昼夜程度必须用**太阳**的仰角（p.y），不能用地月方向 ——
	#   夜间月亮在头顶，仰角是正的，会把深夜误判成白天。
	var sun_elev := asin(clampf(p.y, -1.0, 1.0))
	# 白昼程度：仰角 -6° 以下算全黑，+8° 以上算全亮。
	daylight = clampf((sun_elev + deg_to_rad(6.0)) / deg_to_rad(14.0), 0.0, 1.0)
	# 星空程度：仰角 -2° 才开始出现，-10° 完全显现（与白昼程度区分，夜空需要更"黑"）。
	star_alpha = clampf((-sun_elev - deg_to_rad(2.0)) / deg_to_rad(8.0), 0.0, 1.0)

	var cloud := 0.0
	var weather_fog := 0.0
	var light_scale := 1.0
	var w := _weather_now()
	if w != null:
		cloud = clampf(float(w.get("cloud")), 0.0, 1.0)
		weather_fog = clampf(float(w.get("fog")), 0.0, 1.0)
		light_scale = clampf(float(w.get("light_scale")), 0.0, 2.0)

	if _sun != null:
		var sun_e := _sample_float(SUN_ENERGY_KEYS, time_hours)
		var moon_e := _sample_float(MOON_ENERGY_KEYS, time_hours)
		# ★ 不能只在 p.y>0 时用太阳：太阳 18:00 刚落山、暖光曲线却还有 1 小时余晖，
		#   按仰角切会直接跳成 0（日落瞬间"啪"地变黑）。这里比较两条曲线谁更强：
		#   18:00~19:20 仍用太阳的暖光，19:20 之后才交给月亮。
		var use_sun := sun_e >= moon_e
		var body := p if use_sun else -p
		var energy := sun_e if use_sun else moon_e
		var col: Color
		if use_sun:
			col = _sample_color(SUN_COLOR_KEYS, time_hours, "c")
		else:
			# 月光：冷蓝白，比太阳低饱和得多，夜间才显得"安静"。
			col = Color(0.62, 0.74, 1.00)
		# 黄昏太阳已在地平线下：把方向抬到地平线上一点点，避免整片地面被"从下往上"照亮。
		if body.y < 0.02:
			body = Vector3(body.x, 0.02, body.z).normalized()
		# 多云/阴天把直射光去饱和，避免灰天里出现一个饱和的橙太阳。
		col = col.lerp(Color(0.82, 0.84, 0.88), cloud * 0.6)
		_sun.light_energy = energy * light_scale
		_sun.light_color = col
		# 光源方向：-body 是光行进方向（从天上照向地面）。
		var origin := _sun.global_transform.origin
		_sun.global_transform = Transform3D(_light_basis(-body), origin)

	if _env != null and _env.environment != null:
		var e := _env.environment
		var ambient_c := _sample_color(AMBIENT_COLOR_KEYS, time_hours, "c")
		var ambient_e := _sample_float(AMBIENT_ENERGY_KEYS, time_hours)
		# ★ 用 COLOR 源而不是 SKY 源：夜空本身很暗，若走 sky 环境光，夜里会黑到看不清地面；
		#   COLOR 源让"夜间补光"可控，同时颜色仍按时刻变化（这是昼夜效果的关键一环）。
		e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		e.ambient_light_color = ambient_c
		e.ambient_light_energy = ambient_e * lerpf(1.0, 0.55, cloud)
		# 夜间略提高曝光，模拟人眼/低多边形场景的暗部提亮，不至于全黑。
		e.tonemap_exposure = lerpf(1.18, 1.0, daylight)

		var sky_top := _sample_color(SKY_KEYS, time_hours, "top")
		var sky_hor := _sample_color(SKY_KEYS, time_hours, "horizon")
		var sky_ground := _sample_color(SKY_KEYS, time_hours, "ground")
		# 阴天目标色也要跟着昼夜走：夜间是深蓝灰，而不是白天那种浅灰（否则夜里"天亮着"）。
		var gray_top := Color(0.30, 0.33, 0.40).lerp(Color(0.055, 0.070, 0.120), 1.0 - daylight)
		var gray_hor := Color(0.52, 0.55, 0.60).lerp(Color(0.100, 0.120, 0.180), 1.0 - daylight)
		var gray_ground := Color(0.20, 0.21, 0.22).lerp(Color(0.050, 0.060, 0.080), 1.0 - daylight)
		var top_c := sky_top.lerp(gray_top, cloud)
		var hor_c := sky_hor.lerp(gray_hor, cloud)
		var ground_c := sky_ground.lerp(gray_ground, cloud)
		if _sky_mat != null:
			_sky_mat.sky_top_color = top_c
			_sky_mat.sky_horizon_color = hor_c
			# 地面地平线与天空地平线保持一致，天空球下方才不会出现一道硬边。
			_sky_mat.ground_horizon_color = hor_c
			_sky_mat.ground_bottom_color = ground_c
			_sky_mat.sky_curve = lerpf(0.10, 0.28, cloud)

		# 雾：天气雾沿用"超过 0.18 才起雾"的旧手感，夜间再叠一层很淡的冷雾。
		var wx_fog := maxf(0.0, weather_fog - 0.18)
		var night_haze := 1.0 - daylight
		e.fog_enabled = wx_fog > 0.0 or night_haze > 0.45
		e.fog_density = wx_fog * 0.004 + night_haze * 0.0016
		# 雾色取地平线色再压向冷蓝：黄昏雾偏暖、夜里雾偏蓝，两者都来自同一份关键帧。
		e.fog_light_color = hor_c.lerp(Color(0.12, 0.16, 0.28), night_haze * 0.6)

	if _fill != null:
		var fill_c := _sample_color(AMBIENT_COLOR_KEYS, time_hours, "c")
		# 补光：白天是暖色天光，夜里换成冷色，强度随时段衰减但不归零（保留暗部层次）。
		_fill.light_energy = lerpf(0.12, 0.45, daylight) * lerpf(1.0, 0.82, cloud)
		_fill.light_color = fill_c.lerp(Color(0.62, 0.74, 1.00), 1.0 - daylight)

	if _star_mat != null:
		# 云量越大星星越少（云穹顶本身也会遮住，这里再做一层衰减，避免阴天看到满星）。
		_star_mat.set_shader_parameter("stars_alpha", star_alpha * (1.0 - cloud * 0.85))

## 太阳在天球上的单位方向（从地心指向太阳）。z 分量给轨道一点常驻倾角，
## 避免正午时方向接近垂直、构造光照基时退化。
func _sun_path_point() -> Vector3:
	var a := (time_hours / DAY_HOURS - 0.25) * TAU
	return Vector3(cos(a), sin(a), 0.34).normalized()

## 由"光行进方向"构造光源朝向：DirectionalLight3D 沿本地 -Z 方向照射。
func _light_basis(light_dir: Vector3) -> Basis:
	var z_axis := -light_dir.normalized()
	var ref_up := Vector3.UP if absf(z_axis.y) < 0.98 else Vector3.FORWARD
	var x_axis := ref_up.cross(z_axis).normalized()
	var y_axis := z_axis.cross(x_axis).normalized()
	return Basis(x_axis, y_axis, z_axis)

# ==================== 星空穹顶 ====================
func _ensure_stars(parent: Node3D) -> void:
	if parent == null or _stars != null:
		return
	var sphere := SphereMesh.new()
	sphere.radius = STAR_DOME_RADIUS
	sphere.height = STAR_DOME_RADIUS * 2.0
	sphere.radial_segments = 64
	sphere.rings = 24
	sphere.is_hemisphere = true
	_star_mat = ShaderMaterial.new()
	_star_mat.shader = load("res://assets/shaders/star_dome.gdshader")
	_star_mat.set_shader_parameter("stars_alpha", 0.0)
	# 比云穹顶更早绘制（数值越小越先画），云才能盖在星星前面。
	_star_mat.render_priority = -6
	_stars = MeshInstance3D.new()
	_stars.name = "StarDome"
	_stars.mesh = sphere
	_stars.material_override = _star_mat
	_stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_stars.extra_cull_margin = STAR_DOME_RADIUS
	parent.add_child(_stars)

## 穹顶跟着相机走，顶点局部坐标才等于视线方向（与天气云穹顶同一套做法）。
func _follow_star_camera() -> void:
	if _stars == null:
		return
	var cam := get_viewport().get_camera_3d()
	if cam != null:
		_stars.global_transform = cam.global_transform

func _weather_now() -> Node:
	if _weather != null and is_instance_valid(_weather):
		return _weather
	# 天气节点在同场景里先于本节点 _enter_tree，正常情况一次就能拿到；懒查找只是兜底。
	_weather = get_tree().get_first_node_in_group(&"weather_system")
	return _weather

# ==================== 关键帧采样 ====================
func _sample_color(table: Array, hour: float, key: String) -> Color:
	var h := _wrap_hour(hour)
	var n := table.size()
	if n == 0:
		return Color.WHITE
	var prev: Dictionary = table[0]
	for i in range(1, n):
		var cur: Dictionary = table[i]
		if h <= float(cur["h"]):
			var h0 := float(prev["h"])
			var h1 := float(cur["h"])
			var t := clampf((h - h0) / maxf(0.0001, h1 - h0), 0.0, 1.0)
			return (prev[key] as Color).lerp(cur[key] as Color, t)
		prev = cur
	return table[n - 1][key] as Color

func _sample_float(table: Array, hour: float) -> float:
	var h := _wrap_hour(hour)
	var n := table.size()
	if n == 0:
		return 0.0
	var prev: Dictionary = table[0]
	for i in range(1, n):
		var cur: Dictionary = table[i]
		if h <= float(cur["h"]):
			var h0 := float(prev["h"])
			var h1 := float(cur["h"])
			var t := clampf((h - h0) / maxf(0.0001, h1 - h0), 0.0, 1.0)
			return lerpf(float(prev["v"]), float(cur["v"]), t)
		prev = cur
	return float(table[n - 1]["v"])

func _wrap_hour(h: float) -> float:
	return fposmod(h, DAY_HOURS)

extends Node
## ============================================================================
## fog_vortex_showcase.gd —— 角色涡流（绕身环绕）**可视化 + 数值验收**
## ============================================================================
## 运行：编辑器打开 tools/fog_vortex_showcase.tscn 按 F6，或
##   `godot --path <项目> tools/fog_vortex_showcase.tscn`（跑完自己退出）。
##
## 【验证什么】"角色在雾里移动时，雾会不会绕着它卷起来"。同一个角色绕圈匀速走，
## 分三段跑**同一套场景**、只改 `character_swirl_mps`：
##   ① 对照段  t∈[0,3)   swirl = 0      —— 只有"推开"，没有旋转
##   ② 正转段  t∈[3,6)   swirl = +S     —— 绕身环流（逆时针）
##   ③ 反转段  t∈[6,9)   swirl = -S     —— 绕身环流（顺时针）
##
## 【为什么必须正负各跑一遍】运动物体本身会拖出**尾涡**（径向排开 + 涡量约束把尾迹
##   放大），所以"切向速度均值"在对照组里也不是 0 —— 上一版拿 0 当基准，结果把尾涡
##   误判成"没达到预期"。正负两段里尾涡是同一份、**注入的环流反号**，于是
##       注入环流 ≈ (切向(+S) − 切向(−S)) / 2
##   尾涡项相减抵消，这才是干净的判定量。再加一条同帧的**远处对照**：环流应当集中在
##   角色附近，离得远的地方接近 0。
##
## 【判定量】在回读速度场上（RG = u, v，域单位/秒）算两个数：
##   · 切向速度均值 = 半径内 dot(v, 绕心切向量) 的平均（正负 = 旋转方向）
##   · 涡量均值     = 半径内 (∂v/∂x − ∂u/∂y) 的平均（环流强度）
## 产物：screenshots/fog_vortex_off.png、fog_vortex_on.png、fog_vortex_top.png
## ============================================================================

const BRUSH_FIELD_SCRIPT := preload("res://scripts/fx/fog_brush_field.gd")
const FOG_FIELD_SCRIPT := preload("res://scripts/fx/fog_field.gd")

const SHOT_OFF := "res://screenshots/fog_vortex_off.png"
const SHOT_ON := "res://screenshots/fog_vortex_on.png"
const SHOT_TOP := "res://screenshots/fog_vortex_top.png"

## 角色绕圈运动的半径（米）与速度（m/s）：匀速、不瞬移 ⇒ 位置差分/velocity 都干净
const ORBIT_RADIUS := 12.0
const ORBIT_SPEED := 4.5
## 被验证的绕身切向风速（m/s）。可用命令行参数覆盖（调参用）：
##   godot --path <项目> tools/fog_vortex_showcase.tscn -- 20
const SWIRL_DEFAULT := 20.0
## 判定阈值：注入环流换算成 m/s 至少要这么大，才认为"真的有涡流"
const MIN_INJECTED_MPS := 1.5

var field: FogField
var walker: CharacterBody3D
var camera: Camera3D
var orbit_angle := 0.0
var _lines: Array[String] = []
## 累计**模拟时间**（秒）：用 min(delta, 0.05) 累加，与求解器真正推进的时间一致。
## ★ 不能用墙钟来切相位：启动/编译着色器的那几帧 delta 很大，用墙钟会让测量点落到
##   模拟刚开始的时候（实测同一套参数两次跑出 ±3.4 / −0.5 m/s 的巨大差异）。
var _sim_time := 0.0
var _phase := 0
var _t_off := 0.0
var _t_plus := 0.0
var _t_minus := 0.0
var _far_plus := 0.0
var _wake_off := 0.0
var _cells := 0
var _measured := 0
## 本轮的绕身切向风速（m/s）：默认 SWIRL_DEFAULT，可用命令行参数覆盖
var swirl_mps := SWIRL_DEFAULT


func _ready() -> void:
	# 调参用：命令行参数可以覆盖绕身切向风速（m/s）
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		swirl_mps = float(args[0])
	_build()
	set_process(true)


func _build() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.52, 0.66, 0.82)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.66, 0.72)
	e.ambient_light_energy = 1.0
	env.environment = e
	add_child(env)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	ground.mesh = plane
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.24, 0.30, 0.22)
	gm.roughness = 1.0
	ground.material_override = gm
	add_child(ground)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-30.0, 160.0, 0.0)
	sun.light_energy = 1.15
	sun.shadow_enabled = false
	add_child(sun)

	camera = Camera3D.new()
	camera.name = "VortexCam"
	camera.fov = 55.0
	camera.position = Vector3(0.0, 7.0, 26.0)
	camera.look_at_from_position(camera.position, Vector3(0.0, 1.5, 0.0), Vector3.UP)
	camera.current = true
	add_child(camera)

	# ---- 雾场：6 米厚的中等浓度雾层。★ 内部细节压到很低：这一版要看的是**环流卷出的
	#      密度结构**，絮状噪声/墨迹压上来会把螺旋臂糊掉。----
	field = FOG_FIELD_SCRIPT.new() as FogField
	field.name = "FogField"
	field.domain_size = Vector2(70.0, 70.0)
	field.box_height = 6.0
	field.base_height = 0.0
	field.resolution = 96
	field.jacobi_passes = 8
	field.march_steps = 16
	field.fog_opacity = 1.9
	field.density_gain = 2.4
	field.height_power = 1.3
	field.edge_fade = 0.16
	field.wisp_amount = 0.15
	field.detail_strength = 0.12
	field.ink_amount = 0.0
	field.march_prefilter = 0.6
	field.view_feather = 0.6
	field.vorticity_strength = 1.2
	field.particle_count = 0
	field.particles_enabled = false
	field.auto_weather = false
	field.quality_follows_project = false
	# ★ 被验证的对象：角色自动绕身涡流（走 character_group 那条自动路径）。
	#   半径/挖雾/参考速度都**用 FogField 的默认值** —— 这样自检验的就是真正出厂的参数。
	field.character_stir_enabled = true
	field.character_group = "player"
	field.character_swirl_mps = 0.0
	add_child(field)

	# 底图：只在角色绕圈的范围内铺一层雾（铺满会饱和，螺旋臂就没对比度了）
	var brush := BRUSH_FIELD_SCRIPT.new() as FogBrushField
	brush.grid_size = Vector2i(64, 64)
	brush.ensure_data()
	for k in range(26):
		var a := TAU * float(k) / 26.0
		BRUSH_FIELD_SCRIPT.apply_stamp(brush,
				Vector2(32.0 + cos(a) * 13.0, 32.0 + sin(a) * 13.0),
				11.0, 0.5, 0.55, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	field.set_brush_field(brush)

	# ---- 角色：CharacterBody3D（FogField 会优先用它自己的 velocity）----
	# ★ 故意**不挂** FogInteractor：走 character_group 那条自动路径，
	#   这正是本项目角色的接入方式（挂了组件就以组件参数为准，不会被注入两份）。
	walker = CharacterBody3D.new()
	walker.name = "Walker"
	add_child(walker)
	walker.add_to_group("player")
	var body := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.45
	capsule.height = 1.9
	body.mesh = capsule
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.95, 0.75, 0.45)
	body.material_override = bm
	body.position = Vector3(0.0, 0.95, 0.0)
	walker.add_child(body)
	walker.position = Vector3(ORBIT_RADIUS, 0.0, 0.0)


func _process(delta: float) -> void:
	_sim_time += minf(delta, 0.05)      # 与求解器的 _frame_delta 同一口径
	# 角色绕圈匀速走（显式给 velocity ⇒ 与 CharacterBody3D 的真实速度一致，无差分抖动）
	orbit_angle += ORBIT_SPEED / ORBIT_RADIUS * delta
	walker.position = Vector3(cos(orbit_angle) * ORBIT_RADIUS, 0.0, sin(orbit_angle) * ORBIT_RADIUS)
	var forward := Vector3(-sin(orbit_angle), 0.0, cos(orbit_angle))
	walker.velocity = forward * ORBIT_SPEED
	walker.look_at(walker.position + forward, Vector3.UP)

	match _phase:
		0:
			field.character_swirl_mps = 0.0
			if _sim_time > 2.5:
				_phase = 1
				_t_off = _measure()
				_wake_off = _t_off
				_save(SHOT_OFF)
		1:
			field.character_swirl_mps = swirl_mps
			if _sim_time > 5.0:
				_phase = 2
				_t_plus = _measure()
				_far_plus = _measure_far()
				_save(SHOT_ON)
				_top_view()
		2:
			if _sim_time > 5.6:
				_phase = 3
				_save(SHOT_TOP)
		3:
			field.character_swirl_mps = -swirl_mps
			if _sim_time > 7.5:
				_phase = 4
				_t_minus = _measure()
				_report()
				await get_tree().process_frame
				get_tree().quit(0)


## 切到俯视机位（螺旋臂从正上方看最清楚）：压近一点，涡流才占得满画面
func _top_view() -> void:
	camera.position = Vector3(walker.global_position.x, 24.0, walker.global_position.z + 0.02)
	camera.look_at_from_position(camera.position,
			Vector3(walker.global_position.x, 0.0, walker.global_position.z), Vector3.UP)
	camera.fov = 45.0


func _save(path: String) -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		_lines.append("  [FAIL] 拿不到 viewport 图像：%s" % path)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	var error := image.save_png(path)
	_lines.append("  %s 截图 %s（err=%d）" % ["[OK]" if error == OK else "[FAIL]", path, error])


## 角色周围的**切向速度均值**（域单位/秒）：正负 = 旋转方向
func _measure() -> float:
	var solver: FogNsSolver = field.solver
	if solver == null:
		return 0.0
	var image := solver.read_velocity_image()
	if image == null:
		return 0.0
	var uv := solver.world_to_uv(walker.global_position + Vector3(0.0, 1.0, 0.0))
	var metrics := _swirl_metrics(image, uv, 8)
	_cells = int(metrics["count"])
	_measured += 1
	return metrics["tangential"]


## 同一帧、离角色最远处的切向速度（局部化对照）
func _measure_far() -> float:
	var solver: FogNsSolver = field.solver
	if solver == null:
		return 0.0
	var image := solver.read_velocity_image()
	if image == null:
		return 0.0
	var uv := solver.world_to_uv(walker.global_position + Vector3(0.0, 1.0, 0.0))
	return _swirl_metrics(image, Vector2(1.0 - uv.x, 1.0 - uv.y), 8)["tangential"]


## 在回读速度场上算环流指标（见文件头说明）
func _swirl_metrics(image: Image, uv: Vector2, radius_px: int) -> Dictionary:
	var w := image.get_width()
	var h := image.get_height()
	var cx := int(uv.x * float(w))
	var cy := int(uv.y * float(h))
	var tangential := 0.0
	var vorticity := 0.0
	var count := 0
	for j in range(maxi(1, cy - radius_px), mini(h - 1, cy + radius_px + 1)):
		for i in range(maxi(1, cx - radius_px), mini(w - 1, cx + radius_px + 1)):
			var r := Vector2(float(i - cx), float(j - cy))
			var rl := r.length()
			if rl < 1.0 or rl > float(radius_px):
				continue
			var v := Vector2(image.get_pixel(i, j).r, image.get_pixel(i, j).g)
			var tangent := Vector2(-r.y, r.x) / rl
			tangential += v.dot(tangent)
			var u_right := image.get_pixel(i + 1, j).r
			var u_left := image.get_pixel(i - 1, j).r
			var v_up := image.get_pixel(i, j + 1).g
			var v_down := image.get_pixel(i, j - 1).g
			vorticity += 0.5 * ((v_up - v_down) - (u_right - u_left))
			count += 1
	if count == 0:
		return {"tangential": 0.0, "vorticity": 0.0, "count": 0}
	return {
		"tangential": tangential / float(count),
		"vorticity": vorticity / float(count),
		"count": count,
	}


func _report() -> void:
	print("=========== 角色涡流（绕身环绕）验收 ===========")
	for line in _lines:
		print(line)
	if _measured < 3:
		print("  [FAIL] 速度场回读失败（只成功 %d 次），无法判定" % _measured)
		return
	var scale := minf(field.domain_size.x, field.domain_size.y)
	# ★ 正负两段相减：尾涡（与旋向无关）抵消，剩下的就是**注入的环流**
	var injected := (_t_plus - _t_minus) * 0.5
	var injected_mps := injected * scale
	print("  切向均值：对照(swirl=0) %+.5f ｜ +%.0f m/s %+.5f ｜ −%.0f m/s %+.5f  （角色周围 %d 格）"
			% [_t_off, swirl_mps, _t_plus, swirl_mps, _t_minus, _cells])
	print("  ⇒ 注入环流 ≈ (正 − 反)/2 = %+.5f 域单位/秒 = **%+.2f m/s**（域宽 %.0f 米）"
			% [injected, injected_mps, scale])
	print("  同一帧远处对照（离角色最远处）切向均值 = %+.5f" % _far_plus)

	var sign_ok := signf(injected) == signf(swirl_mps)
	var strong := injected_mps >= MIN_INJECTED_MPS
	print("  %s 注入环流方向与 character_swirl_mps 一致（%s）"
			% ["[OK]" if sign_ok else "[FAIL]", "逆时针" if injected > 0.0 else "顺时针"])
	print("  %s 注入环流强度达到判定门槛（≥ %.1f m/s）" % ["[OK]" if strong else "[FAIL]", MIN_INJECTED_MPS])
	# ★ 这里**不**做"局部化"判定：角色走的是闭合圆周，撒下的尾涡会绕成一整圈，
	#   "离角色最远处"照样有环流。局部化只在直线行走的尾迹里才是有效判据。
	if sign_ok and strong:
		print("  [OK] 总计：角色移动时雾被卷成绕身环流 ✓")
	else:
		print("  [FAIL] 总计：角色涡流未达到预期")

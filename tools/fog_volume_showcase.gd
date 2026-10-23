extends Node
## ============================================================================
## fog_volume_showcase.gd —— 体积雾 + 交互的**可视化验收场景**
## ============================================================================
## 运行：编辑器打开 tools/fog_volume_showcase.tscn 按 F6。
## 它搭一个"能看出体积感"的最小场景并落两张图，用于人工核对：
##   ① screenshots/fog_volume_before.png   物体还没进雾（看体积/光轴本身）
##   ② screenshots/fog_volume_after.png    物体穿过雾层（看交互：尾流与空洞）
##
## 【场景构成与理由】
##   · 太阳（DirectionalLight3D）放在**相机对面**：只有"逆光看雾"才会出现光轴与银边，
##     顺光时单次散射几乎不可见 —— 这是验收体积光照最容易搞错的一点。
##   · 相机低角度贴着雾层：低角度看体积雾最能看出"厚度"，俯视看像贴图。
##   · 雾层用一条斜向雾带 + 两团浓雾（画笔底图），保证有浓淡对比，光轴才有落点。
##   · 两个球体（FogInteractor + 可见网格）以不同速度横穿雾层，制造尾流与空洞。
##   · 地面用一块朴素的大平面：雾的明暗需要参照物才看得出层次。
##
## 【自检输出】打印实际写进体积雾材质的关键 uniform（detail_tex / sun_direction /
##   light_steps / scatter_strength），确认着色器真的拿到了这些值 ——
##   "节点在、参数没写进去"是这类效果最常见的假故障。
## ============================================================================

const BRUSH_FIELD_SCRIPT := preload("res://scripts/fx/fog_brush_field.gd")
const FOG_FIELD_SCRIPT := preload("res://scripts/fx/fog_field.gd")
const INTERACTOR_SCRIPT := preload("res://scripts/fx/fog_interactor.gd")

const SHOT_BEFORE := "res://screenshots/fog_volume_before.png"
const SHOT_AFTER := "res://screenshots/fog_volume_after.png"

var field: FogField
var interactor_a: Node3D
var interactor_b: Node3D
## 两个交互体的移动速度（m/s）。★ 存在本脚本里，不要 set 到节点上：
## FogInteractor 没有 speed 属性，`node.set("speed", ...)` 会静默失败，
## 再 `float(node.get("speed"))` 就会报 "Nonexistent 'float' constructor"（踩过）。
var speed_a := 11.0
var speed_b := 5.5
var _lines: Array[String] = []
var _elapsed := 0.0
var _shot_before_done := false
var _shot_after_done := false
var _frames := 0


func _ready() -> void:
	_build_scene()
	set_process(true)


func _build_scene() -> void:
	# ---- 地面 ----
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(300.0, 300.0)
	ground.mesh = plane
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.24, 0.30, 0.22)
	ground_material.roughness = 1.0
	ground.material_override = ground_material
	add_child(ground)

	# ---- 太阳：放在相机对面（逆光才有光轴）----
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-16.0, 180.0, 0.0)
	sun.light_energy = 1.35
	sun.light_color = Color(1.0, 0.94, 0.82)
	sun.shadow_enabled = false
	add_child(sun)

	# ---- 相机：低角度、朝太阳方向看 ----
	var camera := Camera3D.new()
	camera.name = "ShowcaseCamera"
	camera.position = Vector3(0.0, 11.0, 56.0)
	camera.look_at_from_position(camera.position, Vector3(0.0, 5.0, 0.0), Vector3.UP)
	camera.fov = 62.0
	camera.current = true
	add_child(camera)

	# ---- 雾气场 ----
	field = FOG_FIELD_SCRIPT.new() as FogField
	field.name = "FogField"
	field.domain_size = Vector2(90.0, 90.0)
	field.box_height = 16.0
	field.resolution = 96
	field.jacobi_passes = 8
	field.march_steps = 10          # 验收用高质量步进
	field.light_steps = 5
	field.scatter_strength = 2.0
	field.light_absorption = 2.8
	field.detail_strength = 0.5
	field.detail_scale = 0.03
	field.fog_opacity = 0.85
	field.density_gain = 1.7
	field.height_power = 2.4
	field.edge_fade = 0.22
	field.box_height = 12.0
	field.particle_count = 260
	field.auto_weather = false      # 独立场景里没有天气节点（分组 weather_system）
	field.quality_follows_project = false
	add_child(field)

	# ---- 画笔底图：一条斜雾带 + 两团浓雾 ----
	var brush := BRUSH_FIELD_SCRIPT.new() as FogBrushField
	brush.grid_size = Vector2i(64, 64)
	brush.ensure_data()
	for k in range(40):
		var t := float(k) / 39.0
		BRUSH_FIELD_SCRIPT.apply_stamp(brush,
				Vector2(8.0 + t * 48.0, 30.0 + sin(t * 5.0) * 10.0),
				4.5, 0.75, 0.5, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	BRUSH_FIELD_SCRIPT.apply_stamp(brush, Vector2(44.0, 40.0), 8.0, 0.95, 0.35, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	BRUSH_FIELD_SCRIPT.apply_stamp(brush, Vector2(20.0, 22.0), 7.0, 0.85, 0.4, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	field.set_brush_field(brush)

	# ---- 两个交互体：不同速度/高度横穿雾层 ----
	interactor_a = _make_interactor("WalkerA", Color(0.95, 0.75, 0.45), 10.0, -0.9)
	interactor_b = _make_interactor("WalkerB", Color(0.55, 0.85, 1.0), 5.0, -0.6)
	interactor_a.position = Vector3(-34.0, 4.0, 4.0)
	interactor_b.position = Vector3(34.0, 6.5, -6.0)

	# ---- 打印实际写进材质的 uniform（确认着色器真拿到值）----
	await get_tree().process_frame
	await get_tree().process_frame
	var material: ShaderMaterial = field.get("_volume_material") as ShaderMaterial
	var detail_tex: Texture3D = material.get_shader_parameter("detail_tex") as Texture3D
	var sun_dir: Vector3 = material.get_shader_parameter("sun_direction")
	_lines.append("  detail_tex = %s（3D 细节噪声）" % ("已绑定" if detail_tex != null else "**未绑定**"))
	_lines.append("  sun_direction = %s（逆光方向，应由平行光推出）" % str(sun_dir.snappedf(0.01)))
	_lines.append("  light_steps = %s  scatter_strength = %s  absorption = %s  detail_strength = %s"
			% [material.get_shader_parameter("light_steps"), material.get_shader_parameter("scatter_strength"),
			material.get_shader_parameter("absorption"), material.get_shader_parameter("detail_strength")])
	_lines.append("  交互体数量 = %d（组 %s）" % [get_tree().get_nodes_in_group("fog_interactor").size(),
			field.interactor_group])


func _make_interactor(node_name: String, color: Color, radius: float,
		carve: float) -> Node3D:
	var interactor := INTERACTOR_SCRIPT.new() as Node3D
	interactor.name = node_name
	interactor.set("radius_m", radius)
	interactor.set("carve", carve)
	interactor.set("velocity_scale", 1.0)
	interactor.set("show_radius_gizmo", false)
	var mesh := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.4
	sphere.height = 2.8
	mesh.mesh = sphere
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	mesh.material_override = material
	interactor.add_child(mesh)
	add_child(interactor)
	return interactor


func _process(delta: float) -> void:
	_elapsed += delta
	_frames += 1
	# 让两个球沿 ±X 往返穿过雾带（速度不同，尾流形态不同）
	interactor_a.position.x += speed_a * delta
	interactor_b.position.x -= speed_b * delta
	if interactor_a.position.x > 36.0:
		interactor_a.position.x = -36.0
	if interactor_b.position.x < -36.0:
		interactor_b.position.x = 36.0

	# 第 1 张：物体还离得远，先记录"纯体积 + 光轴"
	if not _shot_before_done and _elapsed > 0.6:
		_shot_before_done = true
		_save(SHOT_BEFORE)
	# 第 2 张：物体已经穿过雾带中部，记录交互留下的尾流/空洞
	if not _shot_after_done and _elapsed > 3.4:
		_shot_after_done = true
		_save(SHOT_AFTER)
		_report()
		await get_tree().process_frame
		get_tree().quit(0)


func _save(path: String) -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		_lines.append("  [FAIL] 拿不到 viewport 图像：%s" % path)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	var error := image.save_png(path)
	_lines.append("  %s 截图 %s（err=%d）" % ["[OK]" if error == OK else "[FAIL]", path, error])


func _report() -> void:
	# 等日志助手接上再输出（_ready 里立刻 print 会丢）
	print("=========== 体积雾 + 交互 验收 ===========")
	for line in _lines:
		print(line)

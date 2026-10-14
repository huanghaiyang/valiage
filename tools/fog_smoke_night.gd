extends Node
## ============================================================================
## fog_smoke_night.gd —— **暗场景烟雾**可视化验收（对齐参考画面）
## ============================================================================
## 参考画面的构成（本场景逐条对齐）：
##   ① 背景几乎全黑，烟是中灰、靠内部明暗显形      -> WorldEnvironment 纯黑 + 无环境光
##   ② 烟有洞、有丝状边缘，能透过薄处看到黑背景      -> cavity_threshold/softness
##   ③ 红橙光从**烟内部**渗出来（激光/火光）        -> fog_light 组里的红色 OmniLight3D
##   ④ 红色光束穿过烟时把沿途的烟点亮               -> 两个 FogBeam 交叉
##   ⑤ 零散火星                                    -> 粒子（小尺寸 + 高亮暖色）
##   ⑥ 相机在烟里，透视关系强                       -> 相机放在体积内部
##
## 落图：screenshots/fog_smoke_night.png
## ============================================================================

const BRUSH_FIELD_SCRIPT := preload("res://scripts/fx/fog_brush_field.gd")
const FOG_FIELD_SCRIPT := preload("res://scripts/fx/fog_field.gd")
const FOG_BEAM_SCRIPT := preload("res://scripts/fx/fog_beam.gd")

const SHOT := "res://screenshots/fog_smoke_night.png"

var field: FogField
var _lines: Array[String] = []
var _elapsed := 0.0
var _saved := false


func _ready() -> void:
	_build()
	set_process(true)


func _build() -> void:
	# ① 黑背景 + 零环境光：烟只能靠内部光源显形
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.015, 0.017, 0.022)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.05, 0.05, 0.06)
	environment.ambient_light_energy = 0.15
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	add_child(world_environment)

	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(400.0, 400.0)
	ground.mesh = plane
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.05, 0.05, 0.055)
	ground_material.roughness = 1.0
	ground.material_override = ground_material
	add_child(ground)

	var camera := Camera3D.new()
	# 相机在烟层**外侧偏上**：让烟有黑色背景做对比、有清晰的轮廓与剪影
	# （相机埋在烟层里 ⇒ 满屏都是烟，再好的着色也没有"暗底 + 灰烟"的对比，踩过）
	camera.position = Vector3(0.0, 15.0, 46.0)
	camera.look_at_from_position(camera.position, Vector3(0.0, 10.0, -8.0), Vector3.UP)
	camera.fov = 62.0
	camera.current = true
	add_child(camera)

	# ②③ 烟体：中灰、厚、有洞
	field = FOG_FIELD_SCRIPT.new() as FogField
	field.name = "FogField"
	field.domain_size = Vector2(70.0, 70.0)
	# ★ 雾层高度带：距地面 6 米起、整体厚 18 米（粒子出生与上升都被限制在这个带内）
	field.base_height = 6.0
	field.box_height = 18.0
	field.resolution = 96
	field.march_steps = 12
	field.light_steps = 0            # 暗场景没有太阳散射，省掉这几步采样
	field.scatter_strength = 0.0
	field.detail_strength = 0.85     # 强三维细节 => 丝状边缘
	field.detail_scale = 0.075
	field.cavity_threshold = 0.42
	field.cavity_softness = 0.5
	field.local_scatter_strength = 5.0
	field.particle_light_response = 0.55
	# 亮部强度：色温色带要压得住 —— 底色保持"暗处的烟是中灰"，亮部靠它出红斑
	field.particle_light_add = 1.10
	field.particle_ambient = 0.30
	field.fog_opacity = 1.6
	field.density_gain = 2.6
	field.height_power = 0.7        # 烟填满体积，而不是贴地
	field.edge_fade = 0.3
	# ★ 暗场景的烟必须是**深灰**：默认的 mist_color 是白天用的亮灰（0.86/0.89/0.94），
	#   在夜里会渲成一锅发光的白汤 —— 这是"观感不像参考"的最大单一原因。
	field.mist_color_lit = Color(0.33, 0.34, 0.38)
	field.mist_color_shadow = Color(0.09, 0.09, 0.11)
	field.wind_speed_mps = 0.8
	# ★ 关键：**关掉包围盒体积雾**，烟全部由粒子承担（用户要求"不要包围盒，要粒子"）
	field.volumetric_box = false
	field.particle_count = 1400
	field.particle_size = 15.0
	# ★ 单颗不透明度必须压住：2000 颗 × 0.5 会让整屏 alpha 饱和成一面灰墙（踩过）。
	#   要"浓"应该靠**层数**（尺寸/数量）而不是单颗 alpha，否则结构全被抹平。
	field.particle_strength = 0.30
	field.particle_lifetime = 13.0
	field.particle_erosion = 0.8
	field.particle_color = Color(0.5, 0.5, 0.55)
	field.auto_weather = false
	field.quality_follows_project = false
	add_child(field)

	var brush := BRUSH_FIELD_SCRIPT.new() as FogBrushField
	brush.grid_size = Vector2i(64, 64)
	brush.ensure_data()
	# 一大团主体 + 几条延伸的臂（模拟参考图里被吹歪的烟柱）
	BRUSH_FIELD_SCRIPT.apply_stamp(brush, Vector2(30.0, 30.0), 24.0, 0.95, 0.25, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	for k in range(30):
		var t := float(k) / 29.0
		BRUSH_FIELD_SCRIPT.apply_stamp(brush,
				Vector2(30.0 + t * 26.0, 30.0 - t * 22.0), 7.0, 0.7, 0.45, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	for k in range(24):
		var t := float(k) / 23.0
		BRUSH_FIELD_SCRIPT.apply_stamp(brush,
				Vector2(30.0 - t * 24.0, 30.0 + t * 14.0), 6.0, 0.6, 0.5, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	field.set_brush_field(brush)

	# ③ 红光：烟内部的发光体（放在烟团中心附近，让红晕向外渗）
	# ★ 标定说明：颜色模型拆分后，受光量直接进 BlackBody 色温。半径给太大/能量给太高，
	#   会让**所有**粒子都落到色温中段 ⇒ 整片糊成一个平色（踩过：20~30 米 + 能量 7 = 全屏粉红）。
	#   正确标定是"只有近处少数粒子进入亮色温区，远处保持烟底色"，才会出现参考图的光晕梯度。
	# ★ 标定：衰减指数 2.0（FogField.particle_light_falloff）后，光源要**少而近**，
	#   红光才会收拢成局部红斑。原来 3 盏 × 半径 20~30 米 = 整团均匀泛红（踩过）。
	_add_light(Vector3(8.0, 9.0, -6.0), Color(1.0, 0.10, 0.05), 10.0, 5.0, "EmberA")
	_add_light(Vector3(2.0, 5.0, -2.0), Color(1.0, 0.20, 0.07), 7.0, 3.0, "EmberB")
	# ⑤ 冷色 key light（"天光"）：粒子材质是 unshaded，**场景灯照不到粒子**，
	#    所以想提亮高光必须把它也放进 fog_light 组。大半径 + 低能量 ⇒ 烟的高光呈灰白，
	#    而红色仍然只出现在 ember 附近（暖光走色温带、冷光按光色提亮，见绘制着色器）。
	_add_light(Vector3(-6.0, 26.0, -4.0), Color(0.55, 0.68, 0.90), 60.0, 0.35, "KeyLight")

	# ④ 红色光束：两束交叉（对齐参考图里那两条红线）
	# ★ 半径必须够大：march 步长约 26/12 ≈ 2.2 米，半径 0.5 米的细光束会被**整段采漏**
	#   （表现为"光束完全看不见"）—— 参考图里的激光在烟里本来也是柔和光晕而非细线。
	_add_beam(Vector3(-16.0, 8.5, 4.0), Vector3(6.0, -4.0, 0.0), Color(1.0, 0.06, 0.03), 2.2, 4.5, "BeamA")
	_add_beam(Vector3(14.0, 12.0, -2.0), Vector3(-3.0, -12.0, 0.0), Color(1.0, 0.10, 0.04), 1.8, 5.0, "BeamB")


func _add_light(position: Vector3, color: Color, radius: float, energy: float,
		node_name: String) -> void:
	var light := OmniLight3D.new()
	light.name = node_name
	light.position = position
	light.light_color = color
	light.light_energy = energy
	light.omni_range = radius
	light.shadow_enabled = false
	light.add_to_group("fog_light")
	add_child(light)


func _add_beam(origin: Vector3, direction: Vector3, color: Color, radius: float,
		intensity: float, node_name: String) -> void:
	var beam := FOG_BEAM_SCRIPT.new() as Node3D
	beam.name = node_name
	beam.position = origin
	beam.set("length_m", 34.0)
	beam.set("radius_m", radius)
	beam.set("color", color)
	beam.set("intensity", intensity)
	beam.set("bidirectional", true)
	beam.set("show_preview", false)
	add_child(beam)
	beam.look_at(origin + direction)


func _process(delta: float) -> void:
	_elapsed += delta
	if not _saved and _elapsed > 1.6:
		_saved = true
		var image := get_viewport().get_texture().get_image()
		if image != null:
			DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
			var error := image.save_png(SHOT)
			_lines.append("  %s 截图 %s（err=%d）"
					% ["[OK]" if error == OK else "[FAIL]", SHOT, error])
		else:
			_lines.append("  [FAIL] 拿不到 viewport 图像")
		var material: ShaderMaterial = field.get("_volume_material") as ShaderMaterial
		var process_material := field.get("_particles").process_material as ShaderMaterial
		_lines.append("  局部光 count=%s  光束 count=%s  粒子受光 response=%s"
				% [process_material.get_shader_parameter("fog_light_count"),
				process_material.get_shader_parameter("beam_count"),
				process_material.get_shader_parameter("light_response")])
		# ★ 雾层高度带自检：参数是否真的落到了粒子节点与着色器上
		var particles := field.get("_particles") as GPUParticles3D
		_lines.append("  高度带：base_height=%.1f m  box_height=%.1f m" % [field.base_height, field.box_height])
		_lines.append("  粒子节点 y=%.1f（应等于 base_height）  着色器 box_height=%s  base_height=%s"
				% [particles.position.y,
				process_material.get_shader_parameter("box_height"),
				process_material.get_shader_parameter("base_height")])
		var aabb := particles.visibility_aabb
		_lines.append("  包围盒 y 范围=%.1f..%.1f（应覆盖 0..box_height）"
				% [aabb.position.y, aabb.position.y + aabb.size.y])
		_lines.append("  验证：粒子世界高度带 = %.1f..%.1f m"
				% [field.base_height, field.base_height + field.box_height])
		print("=========== 暗场景烟雾验收 ===========")
		for line in _lines:
			print(line)
		await get_tree().process_frame
		get_tree().quit(0)

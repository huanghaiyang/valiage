@tool
extends VBoxContainer
## ============================================================================
## fog_brush_dock.gd —— 雾气笔刷的停靠面板（纯 UI，不含任何笔刷算法）
## ============================================================================
## 【职责】只做两件事：① 把参数显示出来让用户调；② 通过信号把"用户想干什么"报给插件。
##   它不知道什么是 FogField、不知道网格怎么换算、也不碰撤销栈 —— 那些都在
##   fog_brush_plugin.gd 里。这样拆分的原因：**面板可以被单独实例化并断言**，
##   而 EditorPlugin 在编辑器进程之外拿不到编辑接口（仓库里 world_brush 的同一约定）。
##
## 【对外接口】
##   · 读参数：enabled / mode / radius_m / strength / hardness / grid_size /
##             show_preview / auto_refresh / paint_velocity
##   · 写状态：set_status(text)               底部状态栏（插件的反馈通道）
##             set_target_info(text)         目标节点信息
##             sync_from_field(field)        把现有 FogBrushField 的参数回填到 UI
##   · 信号：brush_enabled_changed(bool) / mode_changed(int) / params_changed()
##           clear_requested() / fill_requested() / export_requested() /
##           import_requested() / rebuild_requested() / refresh_requested()
##
## 【已知的坑】
##   1. 面板是 @tool 脚本，编辑器里**一定**要判空/判 is_inside_tree：属性面板重建、
##      场景切换时回调可能比节点进树更早触发。
##   2. 控件值变化会连锁触发多个信号（例如 SpinBox 的 value_changed 在 set_value 时
##      也会发）—— 插件侧必须幂等，不能把"信号"当成"用户真的点了"。
## ============================================================================

signal brush_enabled_changed(enabled: bool)
signal mode_changed(mode: int)
signal params_changed()
signal clear_requested()
signal fill_requested()
signal export_requested()
signal import_requested()
signal rebuild_requested()
signal refresh_requested()
## 雾气参数（作用于选中的 FogField）。param_name 与 FogField 的导出属性**同名**，
## 插件侧只需 target.set(param_name, value) —— 加参数时两边各改一行，不会漏接。
## 值用 Variant：既传 float（SpinBox），也传 Color（ColorPickerButton）——
## 参数名与 FogField 属性同名就是契约，插件侧只做 target.set(name, value)。
signal fog_param_changed(param_name: String, value: Variant)
signal fog_toggle_changed(param_name: String, value: bool)

## 笔刷模式（与 scripts/fx/fog_brush_field.gd 的 Mode 枚举数值一致）
const MODE_PAINT := 0
const MODE_ERASE := 1
const MODE_SMOOTH := 2

var enabled: bool = false
var mode: int = MODE_PAINT
## 笔刷半径（米）
var radius_m: float = 12.0
## 每次落笔的最大浓度增量（0..1）
var strength: float = 0.35
## 边缘硬度（0 = 很软的羽化边，1 = 接近硬边）
var hardness: float = 0.45
## 画笔网格分辨率（写进 FogBrushField.grid_size）
var grid_size: Vector2i = Vector2i(96, 96)
## 是否绘制落点预览
var show_preview: bool = true
## 参数变化后是否立刻把底图推给 FogField（关掉可省一点编辑器开销）
var auto_refresh: bool = true
## 落笔时是否顺带推动速度场（画笔变成"吹风"）
var paint_velocity: bool = false

var _enable_check: CheckBox
var _mode_option: OptionButton
var _radius_spin: SpinBox
var _strength_slider: HSlider
var _strength_label: Label
var _hardness_slider: HSlider
var _hardness_label: Label
var _resolution_spin: SpinBox
var _preview_check: CheckBox
var _auto_refresh_check: CheckBox
var _velocity_check: CheckBox
var _target_label: Label
var _status_label: Label
## 雾气参数控件表：{参数名: 控件}。同步与读值都靠这张表，加参数不必再写一遍列表。
var _fog_controls := {}


func _ready() -> void:
	_build_ui()


# =========================================================
# UI
# =========================================================

func _build_ui() -> void:
	if _enable_check != null:
		return                       # 已构建（_ready 可能被重复触发）
	add_theme_constant_override("separation", 6)

	_enable_check = CheckBox.new()
	_enable_check.text = "启用雾气笔刷（在 3D 视口里左键刷 / 右键擦）"
	_enable_check.toggled.connect(_on_enable_toggled)
	add_child(_enable_check)

	_target_label = Label.new()
	_target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_target_label.text = "目标：未找到 FogField"
	add_child(_target_label)

	# ==================== 雾气参数（作用于选中的 FogField）====================
	add_child(_make_separator())
	var fog_title := Label.new()
	fog_title.text = "── 雾气参数（作用于选中节点）──"
	add_child(fog_title)
	# 高度带：这两个就是"雾离地多高"和"雾有多厚"，也是最常调的两个。
	# ★ 最小值/步进都放到 0.1：之前是 0.5，导致想输入 0.1 会被吸附成 0.5（用户反馈）。
	_add_float_param("距地面高度", "base_height", -50.0, 200.0, 0.1, 0.0, "m")
	_add_float_param("整体高度", "box_height", 0.1, 200.0, 0.1, 14.0, "m")
	# 风：默认 0.4 —— 1.0 时烟会被吹得剧烈并抖动
	_add_float_param("风系数", "wind_scale", 0.0, 4.0, 0.05, 0.4, "")
	_add_float_param("粒子跟风", "particle_flow_follow", 0.05, 4.0, 0.05, 0.7, "")
	_add_float_param("噪声拖拽", "particle_flow_warp", 0.0, 1.0, 0.01, 0.05, "")
	# ★ 流场强度：0 = 粒子完全无视流体（风关到 0 还抖时的根治开关）
	_add_float_param("流场强度", "particle_flow_scale", 0.0, 4.0, 0.05, 1.0, "")
	# ★ 物理速度上限（米/秒）：0 = 不限。这是"雾跑得太快"的直接刹车
	_add_float_param("风速上限", "particle_flow_speed_cap", 0.0, 40.0, 0.05, 1.5, "m/s")
	# ★ 速度场为什么"关不掉"的两个能量来源：涡量约束（反耗散，会自发维持小尺度涡）
	#   与速度耗散（把它调大，速度场才会安静下来）
	_add_float_param("涡量约束", "vorticity_strength", 0.0, 20.0, 0.1, 2.5, "")
	_add_float_param("速度耗散", "velocity_dissipation", 0.0, 3.0, 0.05, 0.35, "")
	# ★ 浓度侧的两个"记忆"旋钮：它们的默认值会把角色/法术的扰动快速抹平 ——
	#   这是"扰动没效果"最容易被漏掉的一环，所以必须放在面板上（原先只能在检查器里改）。
	_add_float_param("浓度耗散", "density_dissipation", 0.0, 2.0, 0.01, 0.10, "")
	_add_float_param("底图吸附", "base_relax", 0.0, 4.0, 0.01, 0.6, "")
	_add_float_param("不透明度", "fog_opacity", 0.0, 4.0, 0.05, 1.1, "")
	_add_float_param("浓度增益", "density_gain", 0.0, 8.0, 0.05, 2.4, "")
	# ★ 底图地板：0 = 底图只当吸引子（角色才推得动可见的雾），1 = 旧行为
	_add_float_param("底图地板", "composite_base_floor", 0.0, 1.0, 0.01, 1.0, "")
	_add_float_param("竖向衰减", "height_power", 0.2, 6.0, 0.05, 1.6, "")
	_add_float_param("粒子数量", "particle_count", 0.0, 8000.0, 10.0, 900.0, "")
	_add_float_param("粒子尺寸", "particle_size", 0.1, 60.0, 0.1, 13.0, "m")
	_add_float_param("粒子浓度", "particle_strength", 0.0, 2.0, 0.01, 0.55, "")
	# ★ 颜色模型（拆分后）：烟底色 与 亮部受光叠加量，两个滑块分别控制"多黑"与"亮部多亮"
	_add_float_param("烟底色", "particle_ambient", 0.0, 1.0, 0.01, 0.34, "")
	_add_float_param("受光叠加", "particle_light_add", 0.0, 2.0, 0.01, 0.55, "")
	# ★ 衰减指数：1 = 均匀泛红（旧行为），2~3 = 红光收拢成局部红斑
	_add_float_param("受光衰减", "particle_light_falloff", 0.5, 4.0, 0.1, 2.0, "")
	# ★ 形态：顺风拉伸成丝（流动感）+ 边缘侵蚀（相邻粒子融成一片，治团块）
	_add_float_param("顺风拉伸", "particle_stretch", 0.05, 1.0, 0.01, 0.35, "")
	_add_float_param("边缘侵蚀", "particle_erosion", 0.0, 1.0, 0.01, 0.8, "")
	_add_float_param("光源散射", "local_scatter_strength", 0.0, 16.0, 0.05, 3.2, "")
	_add_float_param("粒子受光", "particle_light_response", 0.0, 4.0, 0.01, 0.32, "")
	# ==================== 体积雾（雾气本体）====================
	# 这几个原先只在检视面板里能改，笔刷面板上没有 —— 而它们正是"雾长什么样"的关键。
	add_child(_make_separator())
	var volume_title := Label.new()
	volume_title.text = "── 体积雾（雾气本体）──"
	add_child(volume_title)
	_add_float_param("步进步数", "march_steps", 1.0, 16.0, 1.0, 6.0, "")
	# ★ 抖动强度默认 0 = 完全旧行为；>0 才启用"蓝噪声抖动"（掩膜由 FogBlueNoise 生成）
	_add_float_param("抖动强度", "march_jitter_strength", 0.0, 1.0, 0.01, 0.0, "")
	# ★ 边缘融合三项（默认 0 = 旧行为）
	_add_float_param("软边宽度", "edge_soft_m", 0.0, 2.0, 0.01, 0.0, "m")
	_add_float_param("预滤波", "march_prefilter", 0.0, 1.0, 0.01, 0.0, "")
	_add_float_param("视角羽化", "view_feather", 0.0, 1.0, 0.01, 0.0, "")
	# ★ 墨迹式图案（随机撒墨滴；照抄墨迹图的生成方式）
	_add_float_param("墨迹强度", "ink_amount", 0.0, 1.0, 0.01, 0.0, "")
	_add_float_param("墨滴间距", "ink_spacing", 1.0, 40.0, 0.5, 7.0, "m")
	_add_float_param("墨滴覆盖", "ink_grow", 0.05, 0.8, 0.01, 0.35, "")
	_add_float_param("墨迹演化", "ink_rate", 0.0, 2.0, 0.01, 0.25, "")
	_add_float_param("折纸镜像", "ink_fold", 0.0, 1.0, 0.01, 1.0, "")
	_add_float_param("金字塔边缘", "pyramid_edge", 0.0, 1.0, 0.01, 0.0, "")
	_add_float_param("光照步数", "light_steps", 0.0, 12.0, 1.0, 3.0, "")
	_add_float_param("散射强度", "scatter_strength", 0.0, 8.0, 0.05, 2.2, "")
	_add_float_param("细节强度", "detail_strength", 0.0, 1.0, 0.01, 0.65, "")
	_add_float_param("吸收", "light_absorption", 0.0, 8.0, 0.05, 2.6, "")
	_add_float_param("挖洞阈值", "cavity_threshold", 0.0, 1.0, 0.01, 0.34, "")
	_add_color_param("雾亮部颜色", "mist_color_lit", Color(0.86, 0.89, 0.94))
	_add_color_param("雾暗部颜色", "mist_color_shadow", Color(0.62, 0.68, 0.78))
	var volume_check := CheckBox.new()
	volume_check.text = "额外启用体积盒（光轴用；运行时生效）"
	volume_check.tooltip_text = "默认关闭：烟由粒子承担。打开后会多一个光线步进的体积盒，用于整体空气感与光轴。"
	volume_check.toggled.connect(func(pressed: bool) -> void:
		fog_toggle_changed.emit("volumetric_box", pressed))
	add_child(volume_check)
	_fog_controls["volumetric_box"] = volume_check

	# ==================== 角色涡流（人跑过、雾绕着转）====================
	# ★ 这几项作用于**流体注入**，不是渲染：影响"起雾后怎么被搅动"。
	#   静止不动的角色不会注入（速度 < 0.05 m/s 直接跳过），所以关掉画质/站在原地的场景不受影响。
	add_child(_make_separator())
	var vortex_title := Label.new()
	vortex_title.text = "── 角色涡流（走动时绕身卷起）──"
	add_child(vortex_title)
	var stir_check := CheckBox.new()
	stir_check.text = "启用角色涡流（扫 player 组；移动才生效）"
	stir_check.tooltip_text = "打开后：character_group 里**正在移动**的节点周围会被注入绕身环流，雾绕着它卷并拖在身后。\n静止不动不注入（观感与旧版一致）。挂了 FogInteractor 组件的角色以组件参数为准，不会重复注入。"
	stir_check.toggled.connect(func(pressed: bool) -> void:
		if not _syncing:                     # 回填时不发信号（否则每次刷新都把场景标脏）
			fog_toggle_changed.emit("character_stir_enabled", pressed))
	add_child(stir_check)
	_fog_controls["character_stir_enabled"] = stir_check
	# ★ 单位是 m/s（不是"域单位/秒"）：域尺寸改了，同一个数在屏幕上表现一致
	_add_float_param("绕身切向风速", "character_swirl_mps", -40.0, 40.0, 0.1, 20.0, "m/s")
	_add_float_param("涡流半径", "character_swirl_radius_m", 0.5, 20.0, 0.1, 4.0, "m")
	_add_float_param("角色挖雾", "character_carve", -2.0, 2.0, 0.01, -0.4, "")
	_add_float_param("涡流参考速度", "character_swirl_ref_speed", 0.5, 12.0, 0.1, 3.0, "m/s")
	_add_text_param("角色组名", "character_group", "player")
	# ---- 涡流**可视化**层（独立着色器：螺旋条带的明暗变化）----
	# ★ 为什么要有它：浓雾里浓度早就饱和成白幕，搅浓度屏幕上什么都看不出来。
	#   这一层直接画螺旋条纹（暗带压暗白雾、亮带提亮地面），不依赖浓度场。
	var swirl_check := CheckBox.new()
	swirl_check.text = "涡流可视化（螺旋明暗条带）"
	swirl_check.tooltip_text = "在角色周身套一层螺旋条带：暗带把白雾压成灰蓝条纹、亮带在深色地面提亮 ⇒ 无论背景浓淡都能看见『绕着他卷的那股风』。角色静止时不显示。"
	swirl_check.toggled.connect(func(pressed: bool) -> void:
		if not _syncing:
			fog_toggle_changed.emit("vortex_visual_enabled", pressed))
	add_child(swirl_check)
	_fog_controls["vortex_visual_enabled"] = swirl_check
	_add_float_param("涡流可视强度", "vortex_visual_alpha", 0.0, 1.0, 0.01, 0.55, "")
	_add_float_param("涡流条带圈数", "vortex_visual_turns", 0.0, 8.0, 0.1, 1.6, "")
	_add_float_param("涡流旋转速度", "vortex_visual_spin_speed", 0.0, 6.0, 0.05, 1.4, "")
	_add_float_param("涡流层高度", "vortex_visual_height_m", 0.05, 40.0, 0.05, 2.6, "m")
	_add_float_param("涡流层半径", "vortex_visual_radius_m", 0.0, 40.0, 0.1, 1.5, "m")
	_add_float_param("涡流锐度", "vortex_visual_sharpness", 0.5, 8.0, 0.1, 1.7, "")
	_add_float_param("涡流抖动", "vortex_visual_wobble", 0.0, 1.0, 0.01, 0.28, "")
	_add_color_param("涡流暗带色", "vortex_visual_dark", Color(0.30, 0.36, 0.47))
	_add_color_param("涡流亮带色", "vortex_visual_light", Color(0.98, 0.99, 1.0))

	add_child(_make_separator())

	_mode_option = OptionButton.new()
	_mode_option.add_item("加雾", MODE_PAINT)
	_mode_option.add_item("擦雾", MODE_ERASE)
	_mode_option.add_item("抹平", MODE_SMOOTH)
	_mode_option.tooltip_text = BRUSH_HINTS["mode"]
	_mode_option.item_selected.connect(_on_mode_selected)
	add_child(_labeled("模式", _mode_option))

	_radius_spin = SpinBox.new()
	# ★ 允许 0.1 米（10 cm）的笔刷：原来最小 0.5、步进 0.5，输入 0.1 会被吸附到 0.5。
	_radius_spin.min_value = 0.1
	_radius_spin.max_value = 500.0
	_radius_spin.step = 0.1
	_radius_spin.suffix = "m"
	_radius_spin.value = radius_m
	_radius_spin.tooltip_text = BRUSH_HINTS["radius_m"]
	_radius_spin.value_changed.connect(_on_radius_changed)
	add_child(_labeled("半径", _radius_spin))

	var strength_row := HBoxContainer.new()
	_strength_slider = HSlider.new()
	_strength_slider.min_value = 0.01
	_strength_slider.max_value = 1.0
	_strength_slider.step = 0.01
	_strength_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_strength_slider.value = strength
	_strength_slider.tooltip_text = BRUSH_HINTS["strength"]
	_strength_slider.value_changed.connect(_on_strength_changed)
	_strength_label = Label.new()
	_strength_label.custom_minimum_size = Vector2(42, 0)
	_strength_label.text = "%.2f" % strength
	strength_row.tooltip_text = BRUSH_HINTS["strength"]
	strength_row.add_child(_strength_slider)
	strength_row.add_child(_strength_label)
	add_child(_labeled("强度", strength_row))

	var hardness_row := HBoxContainer.new()
	_hardness_slider = HSlider.new()
	_hardness_slider.min_value = 0.0
	_hardness_slider.max_value = 1.0
	_hardness_slider.step = 0.01
	_hardness_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hardness_slider.value = hardness
	_hardness_slider.tooltip_text = BRUSH_HINTS["hardness"]
	_hardness_slider.value_changed.connect(_on_hardness_changed)
	_hardness_label = Label.new()
	_hardness_label.custom_minimum_size = Vector2(42, 0)
	_hardness_label.text = "%.2f" % hardness
	hardness_row.tooltip_text = BRUSH_HINTS["hardness"]
	hardness_row.add_child(_hardness_slider)
	hardness_row.add_child(_hardness_label)
	add_child(_labeled("边缘硬度", hardness_row))

	_resolution_spin = SpinBox.new()
	_resolution_spin.min_value = 16
	_resolution_spin.max_value = 512
	_resolution_spin.step = 16
	_resolution_spin.value = grid_size.x
	_resolution_spin.tooltip_text = BRUSH_HINTS["grid_size"]
	_resolution_spin.value_changed.connect(_on_resolution_changed)
	add_child(_labeled("网格分辨率", _resolution_spin))

	add_child(_make_separator())

	_preview_check = CheckBox.new()
	_preview_check.text = "显示落点预览"
	_preview_check.button_pressed = show_preview
	_preview_check.toggled.connect(_on_preview_toggled)
	add_child(_preview_check)

	_velocity_check = CheckBox.new()
	_velocity_check.text = "落笔同时吹动风场"
	_velocity_check.button_pressed = paint_velocity
	_velocity_check.toggled.connect(_on_velocity_toggled)
	add_child(_velocity_check)

	_auto_refresh_check = CheckBox.new()
	_auto_refresh_check.text = "落笔后立刻刷新雾气"
	_auto_refresh_check.button_pressed = auto_refresh
	_auto_refresh_check.toggled.connect(_on_auto_refresh_toggled)
	add_child(_auto_refresh_check)

	add_child(_make_separator())

	var button_row := HBoxContainer.new()
	var clear_button := Button.new()
	clear_button.text = "清空"
	clear_button.tooltip_text = "把整张画笔底图清零（可撤销）"
	clear_button.pressed.connect(func() -> void: clear_requested.emit())
	button_row.add_child(clear_button)

	var fill_button := Button.new()
	fill_button.text = "铺满"
	fill_button.tooltip_text = "整张底图填成当前强度（可撤销）"
	fill_button.pressed.connect(func() -> void: fill_requested.emit())
	button_row.add_child(fill_button)
	add_child(button_row)

	var io_row := HBoxContainer.new()
	var export_button := Button.new()
	export_button.text = "导出 PNG…"
	export_button.tooltip_text = "把画笔数据存成一张灰度 PNG（便于美术手改/版本管理）"
	export_button.pressed.connect(func() -> void: export_requested.emit())
	io_row.add_child(export_button)

	var import_button := Button.new()
	import_button.text = "导入 PNG…"
	import_button.tooltip_text = "读取一张灰度 PNG 作为画笔底图"
	import_button.pressed.connect(func() -> void: import_requested.emit())
	io_row.add_child(import_button)
	add_child(io_row)

	var action_row := HBoxContainer.new()
	var rebuild_button := Button.new()
	rebuild_button.text = "应用到雾气场"
	rebuild_button.tooltip_text = "把当前底图推给 FogField（改了分辨率/参数后点一下）"
	rebuild_button.pressed.connect(func() -> void: rebuild_requested.emit())
	action_row.add_child(rebuild_button)

	var refresh_button := Button.new()
	refresh_button.text = "刷新"
	refresh_button.pressed.connect(func() -> void: refresh_requested.emit())
	action_row.add_child(refresh_button)
	add_child(action_row)

	add_child(_make_separator())

	_status_label = Label.new()
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.text = "就绪：选中一个 FogField，然后启用笔刷"
	add_child(_status_label)


## 把选中 FogField 的当前参数回填到面板（切换目标 / 刷新时调用）。
## ★ 用无类型的 Object + get()/set()：面板**不引用** FogField 类型（分层约定），
##   参数名就是两边的契约。回填期间用 _syncing 挡住信号，避免"同步"被当成"用户改了值"。
func sync_fog_params(field: Object) -> void:
	if field == null:
		return
	_syncing = true
	for param_name in _fog_controls.keys():
		var current = field.get(param_name)
		if current == null:
			continue
		var control: Control = _fog_controls[param_name]
		if control is SpinBox:
			(control as SpinBox).value = float(current)
		elif control is CheckBox:
			(control as CheckBox).button_pressed = bool(current)
		elif control is ColorPickerButton:
			(control as ColorPickerButton).color = current
		elif control is LineEdit:
			(control as LineEdit).text = str(current)
	_syncing = false
	# ★ 把"只在体积盒路径生效"的参数置灰并说明原因 —— 否则用户调了完全没反应，
	#   看起来就像"面板设置无效"（本项目最常见的困惑来源）。
	var box_on := true
	if field.get("volumetric_box") != null:
		box_on = bool(field.get("volumetric_box"))
	for key in ["height_power", "local_scatter_strength", "march_steps", "light_steps",
			"scatter_strength", "detail_strength", "light_absorption", "cavity_threshold",
			"mist_color_lit", "mist_color_shadow"]:
		var only_volume: Control = _fog_controls.get(key)
		if only_volume is SpinBox:
			(only_volume as SpinBox).editable = box_on
			only_volume.tooltip_text = "%s\n\n%s" % [_hint_for(key),
					"当前生效中" if box_on
					else "★ 仅体积雾路径生效；当前 volumetric_box = false（纯粒子模式）"]
		elif only_volume is ColorPickerButton:
			(only_volume as ColorPickerButton).disabled = not box_on
			only_volume.tooltip_text = "%s\n\n%s" % [_hint_for(key),
					"当前生效中" if box_on
					else "★ 仅体积雾路径生效；当前 volumetric_box = false（纯粒子模式）"]


## 每个参数的"人话说明"，鼠标悬停时显示。
## ★ 为什么不自动生成 tooltip 文案：参数名（vorticity_strength）对使用者毫无意义，
##   必须写清"调大/调小会发生什么、和谁联动、在哪条渲染路径生效"。
const PARAM_HINTS := {
	"base_height": "雾层底面距本节点（通常就是地面）的高度，米；整层一起抬升，厚度不变。",
	"box_height": "雾层整体厚度，米；粒子出生与上升都被限制在这个带内，飘出顶部就回到底部。",
	"wind_scale": "风系数：统一缩放「外部给的风」（求解器风场 + 噪声拖拽）。1.0 = 原始强度；默认 0.4，1.0 时烟会被吹得剧烈并抖动。",
	"particle_flow_follow": "粒子跟随流场的速率（1/秒）。越小越钝、越不抖；越大越贴着风走。",
	"particle_flow_warp": "噪声被流场拖拽的强度（flowmapping）。调大会闪烁——它吃瞬时速度场，会把网格尺度的噪声抖动放大；0.02~0.08 安全。",
	"particle_flow_scale": "粒子被速度场搬运的倍率。0 = 粒子完全无视流体（要彻底静止就设 0）。",
	"particle_flow_speed_cap": "粒子跟随速度的物理上限（米/秒），0 = 不限。速度场里除风还有喷源/交互体/涡量约束，乘域尺寸后可能到几米每秒，这是那道保险。",
	"vorticity_strength": "涡量约束强度。它是反耗散项：把被数值耗散抹掉的小尺度涡补回来。调 0 才能让速度场真正安静（「风关了还在抖」的头号原因）。",
	"velocity_dissipation": "速度场耗散（1/秒）。越大速度场死得越快越安静；越小记忆越长、越容易持续翻滚。",
	"density_dissipation": "浓度耗散（1/秒）：雾自然消散的速度。调小 = 雾留得更久、角色/法术留下的扰动轨迹更持久；0 = 几乎不散（整片雾会长期不消失）。",
	"base_relax": "把浓度往**画笔底图**拽的速率（1/秒）。★ 轨迹/涡流看不见的头号原因：默认 0.6 会在 1~2 秒内把角色挖开的洞、卷出的螺旋'愈合'回笔迹形状；想让扰动留痕就调到 0.1~0.2。0 = 不吸附（刷出来的雾会被彻底吹散，只剩流体）。",
	"fog_opacity": "整体不透明度。体积雾与粒子两条路径都吃它（粒子端是乘在单颗浓度上）。",
	"density_gain": "浓度增益：画笔底图对浓度的吸引强度（求解器的 base_gain）。越大，画过的地方雾越浓。",
	"composite_base_floor": "底图**地板**强度。1 = 旧行为：合成时 浓度 = max(模拟值, 底图×增益)，笔迹立刻可见；0 = 底图只当吸引子（靠 base_relax 把形状拽住），不再当地板。\n★ 什么时候调 0：底图被刷满（浓度 1）时 max 会把可见浓度**锁死在 1** —— 角色/法术的挖雾、涡流、风全都看不出来（表现为『雾气扰动没效果』）。调 0 后扰动才落得到画面上；代价是笔迹不再即时可见，而是 1~2 秒内长出来。",
	"height_power": "竖直衰减：越大雾越贴地（仅体积雾路径生效）。",
	"particle_count": "粒子数量，0 = 完全不发射。注意：运行时会被画质档位表 apply_quality 覆盖，改档位表才改得动游戏里的值。",
	"particle_size": "单颗粒子尺寸（米）。要更浓应优先加数量，而不是加大尺寸并提高单颗不透明度。",
	"particle_strength": "单颗粒子浓度（不透明度）。别调太高：粒子是上百颗叠加，单颗一大就累积饱和、整片糊成一块；0.2~0.4 是薄雾区间。",
	"particle_ambient": "粒子的环境底色亮度（没被光照到时多亮）。明亮场景里雾要比地面亮才像雾；太暗就成了地上的脏斑。",
	"particle_light_add": "受光叠加量：亮部（黑体色温带）的强度上限，只有被照亮的部分才加。",
	"particle_light_falloff": "点光衰减指数。1 = 旧的 1/(1+d²/r²)（20 米外仍有 23%，整团均匀泛红）；2~3 = 红光收拢成从烟里透出一片的局部红斑。",
	"particle_stretch": "顺风向拉伸：小于 1 = 顺风压扁，出现被吹出来的丝状结构；1.0 = 各向同性（看着就是一坨坨）。",
	"particle_erosion": "边缘侵蚀：用共享的世界噪声咬掉粒子边界，让相邻粒子融成一片。0 = 一堆软圆盘（团块感），0.7~0.9 = 连续流动的烟。",
	"local_scatter_strength": "体积雾里局部光源的散射强度（仅体积雾路径生效）。",
	"particle_light_response": "粒子受光系数（仅粒子路径）。与「光源散射」分开：后者是体积沿光路累积的量（数量级大），粒子是逐粒子取值，用同一个数会整片爆白。",
	"edge_soft_m": "深度软融合【第二版】：雾在距物体表面这么多**米**以内按 smoothstep 淡出，把'雾切在草/墓碑上的硬边'变成逐渐融入。★ 关键修正：软边宽度按'沿光线的米数'算（旧版用视空间 z 之差，屏幕中心厚、掠射角薄）。0 = 关闭（完全旧行为）。零噪声，建议 0.15~0.5 米。",
	"march_prefilter": "沿光线预滤波【第二版】：★ 旧版按'XZ 足迹'滤波打错了轴 —— 雾带只有 1 米厚、竖直方向才被采几步，**垂直欠采样才是折痕主因**。现在直接对高度剖面做**步内闭式平均**（(1−h)^p 的区间平均有解析解），零额外纹理采样。0 = 关闭（旧行为），1 = 完全按步内平均。确定性、零噪声。建议 0.6~1.0。",
	"pyramid_edge": "金字塔式边缘【治分层感】：0 = 关闭（旧行为）。原来水平边缘淡出宽度**与高度无关**，雾在任何高度都在同一处结束 ⇒ 侧看是一层平板，就有水平分层。>0 时改成**顶层透明度最高（最多再透 85%）、边缘羽化最宽（最多 ×4）**，逐级向下变实、变窄 ⇒ 轮廓成楔形/金字塔。建议 0.5~1.0；开太大雾顶会显得偏空。",
	"ink_amount": "墨迹式图案强度【随机撒墨滴】：0 = 关闭（完全旧行为）。>0 时雾内部不再是平铺噪声，而是**空间里随机分布的墨滴**，每颗墨滴各自对折（罗夏墨迹的成因）⇒ 不重复、无阈值硬边、无平铺接缝。建议 0.6~1.0。",
	"ink_spacing": "墨滴间距（米）：随机网格的格子边长，越小墨滴越密。建议 4~10 米（80 米域上大约 8~20 颗墨滴）。",
	"ink_grow": "墨滴覆盖率：半径 = 间距 × 本值。太大墨滴互相连成一片（失去墨迹感），太小则稀疏成点子。建议 0.3~0.45。",
	"ink_rate": "分布演化速度：0 = 完全静止；越大墨滴游走得越快（这就是'动态随机分布'）。建议 0.15~0.5（太快会像沸腾）。",
	"ink_fold": "折纸镜像：1 = 每颗墨滴以**自己的轴**镜像（罗夏式，纸对折的成因）；0 = 不对称。注意这是**局部**镜像，不是整个世界一个对称面。",
	"view_feather": "视角相关羽化：域边缘淡出宽度按 1/cos(视线与竖直夹角) 放大，治'掠射角下雾域边界很硬'。0 = 关闭（旧行为）；俯视正对时几乎不改变观感。零噪声，建议 0.6~1.0。",
	"march_jitter_strength": "光线步进的**抖动强度**：0 = 关闭（完全等于旧行为）。步进本质是黎曼和，误差沿步长边界周期性排列，看起来就是折痕/条纹；本项按像素（低差异掩膜）加逐帧黄金比偏移来采样相位，把这种相干误差变成帧间不相关的细噪声。建议 0.4~0.8；1.0 最散但噪点略多。",
	"volumetric_box": "是否创建体积雾（雾气本体）：光线步进的盒子，雾的连续层由它渲染。关掉就只剩粒子层。",
	"march_steps": "光线步进步数。越大雾的层次越细腻，代价是每像素采样次数线性增加。",
	"light_steps": "体积光照步数（光轴/丁达尔）。0 = 不算光照，暗场景可省。",
	"scatter_strength": "散射强度：雾被太阳/光源照亮的亮度。",
	"detail_strength": "三维噪声细节强度：决定雾内部有没有絮状层次，还是均匀一团。",
	"light_absorption": "吸收：沿光路的衰减，越大雾越厚、越不透光。",
	"cavity_threshold": "挖洞阈值：噪声低于它的地方完全没有雾，于是薄处能透出背景。",
	"mist_color_lit": "雾被照亮处的颜色（亮部）。",
	"mist_color_shadow": "雾背光处的颜色（暗部）。与亮部一起决定雾的立体感，两者差距越大越有体积。",
	"character_stir_enabled": "角色涡流总开关：打开后，角色组里**正在移动**的节点周围会被注入绕身环流（雾绕着它卷、拖在身后）。静止不注入。",
	"character_swirl_mps": "绕身**切向风速**（m/s）：正负 = 旋向（逆/顺时针），0 = 只把雾推开、不转（完全等于加涡流之前的行为）。\n★ 它是『注入的目标风速』，不是最终风速：实测（70 米域、默认求解器参数）20 m/s 时角色周围环流约 2.5~4.5 m/s。想要明显就 30~45。",
	"character_swirl_radius_m": "涡流半径（米）：3~4 = 贴着人绕；5~8 = 整个人带起一团。半径越小环流越集中但越容易被耗散掉。",
	"character_carve": "角色周围的挖雾速率（每秒）：负值在角色周围挖出比别处稀的洞（0 = 只搅动不挖）。\n★ 想在小地图/俯视里看见螺旋，把雾挖开比单纯调高切向速度更有效（−0.8~−1.5）。",
	"character_swirl_ref_speed": "涡流强度的参考速度（m/s）：实际切向速度 = 绕身切向风速 × clamp(角色速度/本值, 0.25, 1.6)。\n走路约 3 m/s ⇒ 本值保持 3 就是 1 倍；调小 = 慢走也有强涡，调大 = 要跑起来才起涡。",
	"character_group": "到哪个组里找角色（要等于代码里 add_to_group('...') 的那个名字）。本项目角色在 player.gd 里注册成 'player'，一般不用改。",
	"vortex_visual_enabled": "涡流**可视化**层总开关。★ 它跟上面那组『浓度扰动』是两件事：浓雾里浓度早已饱和成白幕，搅浓度屏幕上什么都看不出来；这一层**不看浓度**，直接画螺旋明暗条带（暗带压暗白雾、亮带提亮地面），所以无论背景浓淡都看得见。",
	"vortex_visual_alpha": "涡流条带的最大不透明度：最浓时能把底下的白雾压多暗。0.3~0.6 自然；>0.8 会像贴上去的塑料条纹。",
	"vortex_visual_turns": "螺旋圈数：1~2 像一股卷起来的风；>4 会碎成密集斑点。",
	"vortex_visual_spin_speed": "旋转速度（圈/秒）：0 = 静止的条纹，1~2 = 明显在转。",
	"vortex_visual_height_m": "涡流层有多高（米）：★ 取**任意值**都行，和半径没有任何关系（不按比例推导）。0.5 = 贴地一圈，2.6 = 裹住身体，5 = 卷得比人高。",
	"vortex_visual_radius_m": "涡流层围多大一圈（米）：这层只在角色周身一点点空间，0.8~2 米就够，别设大。★ 别低于 0.5 米 —— 0.4 米直径的壳会整个缩进角色身体里，画面上只是身上一块暗斑，不会绕身。0 = 自动取 character_swirl_radius_m 的 1/4（夹在 0.8~2 米）。与高度完全独立。",
	"vortex_visual_sharpness": "条纹锐度：越大越像细丝，越小越像一片雾。",
	"vortex_visual_wobble": "条纹抖动：打散规则螺旋的『塑料弹簧』感，0.2~0.4 比较自然。",
	"vortex_visual_dark": "暗带颜色：它负责在**浓白雾**上显形（把白雾压成灰蓝条纹）。",
	"vortex_visual_light": "亮带颜色：它负责在**深色草地/地面**上显形（像被光扫过的银边）。",
}


## 取某个参数的说明文案（鼠标悬停显示）。取不到就退回属性名，绝不显示空白 tooltip。
## default_text：建议默认值。★ 由调用方传入（_add_float_param 收到的 initial），
## 而不是写死在说明里 —— 否则改了属性默认值之后，tooltip 就会骗人。
func _hint_for(param_name: String, default_text: String = "") -> String:
	var hint: String = PARAM_HINTS.get(param_name, "")
	if hint.is_empty():
		hint = "对应 FogField.%s" % param_name
	var lines := PackedStringArray([hint])
	if not default_text.is_empty():
		lines.append("建议默认：%s" % default_text)
	lines.append("（对应属性：FogField.%s）" % param_name)
	return "\n".join(lines)


## 数值显示：整数不带小数点，避免 tooltip 里出现 "6.0" 这种噪音。
func _format_number(value: float, suffix: String) -> String:
	if is_equal_approx(value, roundf(value)):
		return "%d%s" % [int(round(value)), suffix]
	return "%s%s" % [str(value), suffix]


## 笔刷参数的说明。★ 与 PARAM_HINTS 分开：这几个作用于**画笔底图**，不是 FogField 的属性，
## 所以不能套用「对应属性：FogField.x」那句话。
const BRUSH_HINTS := {
	"mode": "画笔模式：加雾（涂浓）/ 擦雾（涂薄）/ 抹平（把浓淡差推平，用来做过渡带）。建议：先加雾定形状，再用抹平做过渡。",
	"radius_m": "笔刷半径（米）。这是世界尺寸，与网格分辨率无关：0.1 m = 10 厘米。建议：8~24 米（贴地雾带用大半径，局部加浓用小半径）。",
	"strength": "单次落笔的浓度强度。叠涂会累积——想要均匀的雾就调低强度、多涂几遍。建议：0.2~0.4。",
	"hardness": "边缘硬度。0 = 极软的羽化边（像喷雾），1 = 硬边（像圆刷子）。建议：0.3~0.6（雾要有软边）。",
	"grid_size": "笔刷底图网格数：把域切成 grid_size × grid_size 个格子来存你画的雾。96 在 80 米域上等于每格 0.83 米。建议：64~192（太小会看到方块状边缘，太大收益递减）。",
}


## 造一行"标签 + SpinBox"的浮点参数，值变化 -> fog_param_changed(参数名, 值)。
func _add_float_param(label_text: String, param_name: String, min_value: float,
		max_value: float, step: float, initial: float, suffix: String) -> void:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = initial
	spin.tooltip_text = _hint_for(param_name, _format_number(initial, suffix))
	if not suffix.is_empty():
		spin.suffix = suffix
	spin.value_changed.connect(func(value: float) -> void:
		if not _syncing:
			fog_param_changed.emit(param_name, value))
	add_child(_labeled(label_text, spin))
	_fog_controls[param_name] = spin


## 造一行"标签 + 颜色选择器"的参数（雾亮部/暗部颜色）。
## 值通过同一个 fog_param_changed 信号透传（Variant），所以插件侧不需要为颜色再写一段。
func _add_color_param(label_text: String, param_name: String, initial: Color) -> void:
	var picker := ColorPickerButton.new()
	picker.color = initial
	picker.edit_alpha = true
	picker.custom_minimum_size = Vector2(0.0, 22.0)
	picker.tooltip_text = _hint_for(param_name, "#" + initial.to_html(false))
	picker.color_changed.connect(func(value: Color) -> void:
		if not _syncing:
			fog_param_changed.emit(param_name, value))
	add_child(_labeled(label_text, picker))
	_fog_controls[param_name] = picker


## 造一行"标签 + 单行文本"的参数（目前只有组名这种字符串属性用）。
## ★ 只在**提交时**发信号（text_submitted / focus_exited），不是每次敲键：
##   否则删旧字、打新字的中间态会被当成"用户改了值"写进场景。
func _add_text_param(label_text: String, param_name: String, initial: String) -> void:
	var edit := LineEdit.new()
	edit.text = initial
	edit.tooltip_text = _hint_for(param_name, initial)
	var commit := func(_text: String = "") -> void:
		if not _syncing:
			fog_param_changed.emit(param_name, edit.text)
	edit.text_submitted.connect(commit)
	edit.focus_exited.connect(func() -> void: commit.call())
	add_child(_labeled(label_text, edit))
	_fog_controls[param_name] = edit


func _make_separator() -> HSeparator:
	return HSeparator.new()


## 造一行"标签 + 控件"（宽度统一，避免面板里控件错位）。
func _labeled(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(84, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


# =========================================================
# 状态回填 / 反馈
# =========================================================

func set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func set_target_info(text: String) -> void:
	if _target_label != null:
		_target_label.text = "目标：%s" % text


## 把已有画笔数据的参数回填到面板（切换目标时调用）。
## ★ 回填会触发控件的 value_changed / toggled，进而发出信号 —— 这里用 _syncing 挡住，
##   否则"切换目标"会被插件当成"用户改了参数"，可能触发多余的刷新甚至重建。
var _syncing := false


func sync_from_field(field: FogBrushField) -> void:
	if field == null:
		return
	_syncing = true
	grid_size = field.grid_size
	if _resolution_spin != null:
		_resolution_spin.value = grid_size.x
	_syncing = false


# =========================================================
# 控件回调
# =========================================================

func _on_enable_toggled(pressed: bool) -> void:
	enabled = pressed
	brush_enabled_changed.emit(pressed)


func _on_mode_selected(index: int) -> void:
	mode = _mode_option.get_item_id(index)
	mode_changed.emit(mode)


func _on_radius_changed(value: float) -> void:
	radius_m = value
	if not _syncing:
		params_changed.emit()


func _on_strength_changed(value: float) -> void:
	strength = value
	if _strength_label != null:
		_strength_label.text = "%.2f" % value
	if not _syncing:
		params_changed.emit()


func _on_hardness_changed(value: float) -> void:
	hardness = value
	if _hardness_label != null:
		_hardness_label.text = "%.2f" % value
	if not _syncing:
		params_changed.emit()


func _on_resolution_changed(value: float) -> void:
	grid_size = Vector2i(int(value), int(value))
	if not _syncing:
		params_changed.emit()


func _on_preview_toggled(pressed: bool) -> void:
	show_preview = pressed


func _on_velocity_toggled(pressed: bool) -> void:
	paint_velocity = pressed


func _on_auto_refresh_toggled(pressed: bool) -> void:
	auto_refresh = pressed

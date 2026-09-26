extends CanvasLayer
## 游戏 UI：顶部工具栏与提示

var main: Node3D
var tool_buttons: Dictionary = {}
var tool_button_map: Dictionary = {}  # button -> tool
var title_label: Label
var hint_label: Label
var undo_button: Button
var biomass_label: Label
var action_button: Button           # 动作菜单开关按钮
var action_panel: PanelContainer    # 动作列表面板
var _action_visible := false

const TOOL_BUTTONS := [
	["墙壁", Game.Tool.WALL],
	["塔楼", Game.Tool.TOWER],
	["房屋", Game.Tool.ROOF],
	["抬升", Game.Tool.TERRAIN_RAISE],
	["下陷", Game.Tool.TERRAIN_LOWER],
	["平整", Game.Tool.TERRAIN_FLATTEN],
	["树木", Game.Tool.TREE],
	["花草", Game.Tool.FLOWER],
	["家具", Game.Tool.DECOR],
	["山体", Game.Tool.MOUNTAIN],
]

func setup(main_node: Node3D) -> void:
	main = main_node
	_build_ui()
	Game.tool_changed.connect(_on_tool_changed)

func _build_ui() -> void:
	# 背景
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.14, 0.18, 0.55)
	bg.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bg.offset_bottom = 64.0
	add_child(bg)

	# 标题
	title_label = Label.new()
	title_label.text = "温馨山谷 · Cozy Vale"
	title_label.add_theme_font_size_override("font_size", 22)
	title_label.add_theme_color_override("font_color", Color.WHITE)
	title_label.position = Vector2(16, 10)
	add_child(title_label)

	# 工具按钮行
	var hbox := HBoxContainer.new()
	hbox.position = Vector2(200, 12)
	hbox.add_theme_constant_override("separation", 6)
	add_child(hbox)

	for btn_data in TOOL_BUTTONS:
		var btn := Button.new()
		btn.text = btn_data[0]
		btn.custom_minimum_size = Vector2(64, 34)
		btn.pressed.connect(_on_tool_button_pressed.bind(btn))
		hbox.add_child(btn)
		tool_buttons[btn_data[1]] = btn
		tool_button_map[btn] = btn_data[1]

	# 撤销按钮
	undo_button = Button.new()
	undo_button.text = "撤销 (Ctrl+Z)"
	undo_button.custom_minimum_size = Vector2(110, 34)
	undo_button.pressed.connect(_on_undo_pressed)
	hbox.add_child(undo_button)

	# 动作菜单按钮
	action_button = Button.new()
	action_button.text = "动作 (K)"
	action_button.custom_minimum_size = Vector2(90, 34)
	action_button.toggle_mode = true
	action_button.pressed.connect(_toggle_action_panel)
	hbox.add_child(action_button)

	# 动作列表面板（默认隐藏，K 或按钮呼出）
	_build_action_panel()

	# 生物质/石材余额（右上角，回收植被获得；石头单独计入石材）
	biomass_label = Label.new()
	biomass_label.text = "生物质 0\n石材 0"
	biomass_label.add_theme_font_size_override("font_size", 17)
	biomass_label.add_theme_color_override("font_color", Color(0.78, 0.95, 0.62))
	biomass_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	biomass_label.add_theme_constant_override("outline_size", 5)
	biomass_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	biomass_label.offset_left = -220
	biomass_label.offset_right = -16
	biomass_label.offset_top = 12
	biomass_label.offset_bottom = 66
	biomass_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(biomass_label)
	Game.biomass_changed.connect(_on_biomass_changed)
	Game.stone_changed.connect(_on_biomass_changed)

	# 底部提示
	hint_label = Label.new()
	hint_label.text = "左键搭建/涂抹 · WASD 移动 · 鼠标旋转视角 · Shift 加速 · Space/C 升降 · T 切换视角 · Esc 释放鼠标"
	hint_label.add_theme_font_size_override("font_size", 14)
	hint_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9, 0.9))
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.offset_top = -34
	hint_label.offset_bottom = -8
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint_label)

	# 屏幕中央准星（不拦截鼠标）
	var cross_container := CenterContainer.new()
	cross_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	cross_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var crosshair := Label.new()
	crosshair.text = "+"
	crosshair.add_theme_font_size_override("font_size", 30)
	crosshair.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	crosshair.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.65))
	crosshair.add_theme_constant_override("outline_size", 4)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cross_container.add_child(crosshair)
	add_child(cross_container)

	_on_tool_changed(Game.current_tool)

func _on_biomass_changed(_v: float) -> void:
	biomass_label.text = "生物质 %.1f\n石材 %.1f" % [Game.biomass, Game.stone]

func _on_tool_button_pressed(btn: Button) -> void:
	var tool: int = tool_button_map[btn]
	if main:
		main.set_tool(tool)

func _on_undo_pressed() -> void:
	if main and main.has_method("undo"):
		main.undo()

func _on_tool_changed(tool: int) -> void:
	for t in tool_buttons:
		var btn: Button = tool_buttons[t]
		btn.button_pressed = (t == tool)
	# 更新提示
	var tip := ""
	match tool:
		Game.Tool.WALL:
			tip = "拖拽画出墙壁"
		Game.Tool.TOWER:
			tip = "点击放置塔楼"
		Game.Tool.ROOF:
			tip = "点击放置小屋"
		Game.Tool.TERRAIN_RAISE, Game.Tool.TERRAIN_LOWER, Game.Tool.TERRAIN_FLATTEN:
			tip = "按住涂抹地形"
		Game.Tool.TREE:
			tip = "点击种树"
		Game.Tool.FLOWER:
			tip = "点击种花"
		Game.Tool.DECOR:
			tip = "点击放置家具（桌/椅/床/梯子等）"
		Game.Tool.MOUNTAIN:
			tip = "点击放置山体（悬崖岩块）"
	hint_label.text = "【%s】%s · WASD移动 · Shift加速 · Space/C升降 · T切换视角 · 数字键1-0切工具" % [Game.get_tool_name(), tip]

# ---------- 动作菜单（快捷键 K 呼出，游戏内测试动作） ----------

func _build_action_panel() -> void:
	action_panel = PanelContainer.new()
	action_panel.visible = false
	action_panel.position = Vector2(12, 74)
	action_panel.custom_minimum_size = Vector2(230, 0)
	action_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(action_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	action_panel.add_child(vbox)

	var cap := Label.new()
	cap.text = "动作测试（点击播放，再次移动/跳跃恢复）"
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	vbox.add_child(cap)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	var lib: Array = []
	if main != null and main.player != null:
		lib = main.player.get_action_lib()
	for i in lib.size():
		var entry: Array = lib[i]
		var b := Button.new()
		b.text = entry[0]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 30)
		b.pressed.connect(_on_action_pressed.bind(i))
		list.add_child(b)

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.13, 0.16, 0.88)
	sb.border_color = Color(0.45, 0.55, 0.5, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	return sb

func _toggle_action_panel() -> void:
	_action_visible = not _action_visible
	action_panel.visible = _action_visible
	action_button.button_pressed = _action_visible
	if main != null and main.camera_rig != null:
		var rig: CameraRig = main.camera_rig
		if _action_visible:
			rig.ui_override = true
			rig.set_ui_capture(false)
		else:
			rig.ui_override = false
			rig.set_ui_capture(true)

func _on_action_pressed(index: int) -> void:
	if main != null and main.player != null:
		main.player.play_action(index)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_K:
			_toggle_action_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _action_visible:
			_toggle_action_panel()
			get_viewport().set_input_as_handled()

extends CanvasLayer
## 游戏 UI：顶部工具栏与提示

var main: Node3D
var tool_buttons: Dictionary = {}
var tool_button_map: Dictionary = {}  # button -> tool
var title_label: Label
var hint_label: Label
var undo_button: Button

const TOOL_BUTTONS := [
	["墙壁", Game.Tool.WALL],
	["塔楼", Game.Tool.TOWER],
	["房屋", Game.Tool.ROOF],
	["抬升", Game.Tool.TERRAIN_RAISE],
	["下陷", Game.Tool.TERRAIN_LOWER],
	["平整", Game.Tool.TERRAIN_FLATTEN],
	["树木", Game.Tool.TREE],
	["花草", Game.Tool.FLOWER],
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
	hint_label.text = "【%s】%s · WASD移动 · Shift加速 · Space/C升降 · T切换视角 · 数字键1-8切工具" % [Game.get_tool_name(), tip]

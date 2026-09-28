extends CanvasLayer
## 游戏 UI：顶部工具栏与提示

var main: Node3D
## 创造列表（B 呼出）与帮助面板（H 呼出）
var create_panel: PanelContainer
var create_button: Button
var help_panel: PanelContainer
var help_button: Button
var help_label: Label
var _create_visible := false
## 打开创建菜单前的工具/变体选择（关闭时回滚）
var _tool_before_create: int = Game.Tool.NONE
var _variants_before_create: Dictionary = {}
var _help_visible := false

## 左侧功能键统一用小尺寸按钮（原来 84x48、字号默认太大）
func _make_key_button(label: String, tip: String) -> Button:
	var b := Button.new()
	b.text = label
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(36, 26)
	b.add_theme_font_size_override("font_size", 12)
	b.toggle_mode = true
	return b


const HELP_TEXT := """WASD 移动 · Shift 加速 · Space 跳跃 · C 下降
左键 建造/放置 · 右键 旋转视角（未选工具时按住拖动）
滚轮 缩放视野（未选工具时 75%~200%）/ 换模型（选了工具时）
E 交互（坐/睡/攀爬） · F 装备法杖 · Q 换杖 · V 换天气
M 大地图 · Ctrl+Z 撤销 · ESC 关闭面板 · B/K/H 本面板"""

var tool_buttons: Dictionary = {}
var tool_button_map: Dictionary = {}  # button -> tool
var undo_button: Button
var biomass_label: Label
var action_button: Button           # 动作菜单开关按钮
var action_panel: PanelContainer    # 动作列表面板
var _action_visible := false
# ---- 装备（法杖）面板：F 呼出，与动作面板同样式同位置、互斥 ----
var staff_button: Button            # 工具栏上的「装备 (F)」开关按钮
var staff_panel: PanelContainer     # 已拥有法杖的列表（146 根，可滚动 + 元素筛选）
var _staff_visible := false
var _staff_filter := -1             # 元素筛选：-1 = 全部
var _staff_filter_buttons: Dictionary = {}   # 元素 -> 筛选按钮（toggle 需手动互斥）
var _staff_list: VBoxContainer
var _staff_cap: Label
var interact_label: Label        # 家具互动提示浮层
var weather_label: Label         # 天气/风力信息（右上角）
var staff_slot: PanelContainer   # 法杖装备格（右下角，武器单占一格）
var staff_slot_label: Label
var staff_slot_icon: ColorRect
var _weather_accum := 0.0

const TOOL_BUTTONS := [
	# 不在这里放"选择"按钮（用户要求去掉）。取消选择的功能保留：
	#   * ESC：没打开面板时按一下 = 收起当前工具
	#   * 再点一次"当前已选中"的工具按钮 = 取消选择
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
	["雕像", Game.Tool.STATUE],
]

func setup(main_node: Node3D) -> void:
	main = main_node
	_build_ui()
	Game.tool_changed.connect(_on_tool_changed)
	# 开局同步一次按钮高亮：默认工具是"选择"(NONE)，而信号只在**变化**时发，
	# 不主动调一次的话开局没有任何按钮是按下态。
	_on_tool_changed(Game.current_tool)
	# 装备数据一变就刷新右下角格子与（打开着的）面板
	var sys := get_node_or_null("/root/StaffSystem")
	if sys != null and not sys.is_connected("equipment_changed", _on_equipment_changed):
		sys.connect("equipment_changed", _on_equipment_changed)
	update_staff_slot()

func _build_ui() -> void:
	# ============================================================
	# 布局：顶部**什么都不留**；底部一排 B / K / H 三个按钮；
	# 建造工具全部收进 B 呼出的"创造列表"里。
	# ============================================================

	# ---- 创造列表（默认隐藏，B 键 / B 按钮呼出，ESC 关闭）----
	create_panel = PanelContainer.new()
	create_panel.name = "CreatePanel"
	create_panel.add_theme_stylebox_override("panel", _panel_style())
	# 位置由 _layout_panels() 动态给，这里只定左上锚点
	create_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	create_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	create_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	create_panel.visible = false
	add_child(create_panel)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 10)
	create_panel.add_child(cv)

	# 资源/天气：原来在右上角（顶部 UI），按用户要求挪进创造列表
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 18)
	cv.add_child(top_row)
	var cap := Label.new()
	cap.text = "创 造"
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", Color.WHITE)
	top_row.add_child(cap)
	biomass_label = Label.new()
	biomass_label.text = "生物质 0 · 石材 0"
	biomass_label.add_theme_font_size_override("font_size", 11)
	biomass_label.add_theme_color_override("font_color", Color(0.78, 0.95, 0.62))
	top_row.add_child(biomass_label)
	Game.biomass_changed.connect(_on_biomass_changed)
	Game.stone_changed.connect(_on_biomass_changed)
	weather_label = Label.new()
	weather_label.text = "晴朗"
	weather_label.add_theme_font_size_override("font_size", 11)
	weather_label.add_theme_color_override("font_color", Color(0.82, 0.90, 1.0))
	top_row.add_child(weather_label)

	# 工具按钮：每行 5 个
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	cv.add_child(grid)
	for btn_data in TOOL_BUTTONS:
		var btn := Button.new()
		btn.text = btn_data[0]
		btn.add_theme_font_size_override("font_size", 11)
		btn.custom_minimum_size = Vector2(80, 24)
		btn.pressed.connect(_on_tool_button_pressed.bind(btn))
		grid.add_child(btn)
		tool_buttons[btn_data[1]] = btn
		tool_button_map[btn] = btn_data[1]

	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 10)
	cv.add_child(brow)
	# 撤销按钮已按用户要求从菜单里去掉；功能保留在 **Ctrl+Z**（main.gd 里处理）
	# 装备按钮已经挪到左侧键列（F），这里不再重复

	# ---- 帮助面板（H 呼出）：把原来常驻底部的操作提示挪进来按需查看 ----
	help_panel = PanelContainer.new()
	help_panel.name = "HelpPanel"
	help_panel.add_theme_stylebox_override("panel", _panel_style())
	help_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	help_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	help_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	help_panel.visible = false
	add_child(help_panel)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 6)
	help_panel.add_child(hv)
	var ht := Label.new()
	ht.text = "操作"
	ht.add_theme_font_size_override("font_size", 13)
	hv.add_child(ht)
	help_label = Label.new()
	help_label.text = HELP_TEXT
	help_label.add_theme_font_size_override("font_size", 11)
	hv.add_child(help_label)

	# ---- 快捷键：**屏幕正下方居中，横向 B / K / H / F** ----
	var bar := HBoxContainer.new()
	bar.name = "KeyBar"
	bar.add_theme_constant_override("separation", 8)
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_left = -88
	bar.offset_right = 88
	bar.offset_top = -42
	bar.offset_bottom = -14
	add_child(bar)
	create_button = _make_key_button("B", "创造列表")
	create_button.pressed.connect(_toggle_create_panel)
	bar.add_child(create_button)
	action_button = _make_key_button("K", "动作")
	action_button.pressed.connect(_toggle_action_panel)
	bar.add_child(action_button)
	help_button = _make_key_button("H", "操作说明")
	help_button.pressed.connect(_toggle_help_panel)
	bar.add_child(help_button)
	# F：装备面板 —— 用户要求"把 F 放出来"，所以从创造列表挪到左侧键列
	staff_button = _make_key_button("F", "装备法杖")
	staff_button.pressed.connect(_toggle_staff_panel)
	bar.add_child(staff_button)

	# ---- 待建面板（动作 / 装备）----
	_build_action_panel()
	_build_staff_panel()

	# ---- 法杖装备格（右下角，保留：它是装备 HUD 不是提示文字）----
	staff_slot = PanelContainer.new()
	staff_slot.add_theme_stylebox_override("panel", _panel_style())
	# 装备信息在**右下角**（用户要求）
	staff_slot.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	staff_slot.offset_left = -186
	staff_slot.offset_top = -66
	staff_slot.offset_right = -14
	staff_slot.offset_bottom = -14
	staff_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(staff_slot)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	staff_slot.add_child(srow)
	staff_slot_icon = ColorRect.new()
	staff_slot_icon.custom_minimum_size = Vector2(7, 32)
	staff_slot_icon.color = Color(0.5, 0.5, 0.5)
	srow.add_child(staff_slot_icon)
	staff_slot_label = Label.new()
	staff_slot_label.text = "法杖 · 空"
	staff_slot_label.add_theme_font_size_override("font_size", 11)
	staff_slot_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	srow.add_child(staff_slot_label)

	# ---- 家具互动提示（准星下方的浮层，按 E 交互时才出现）----
	# 这是**上下文提示**，不是常驻文字，保留；用户说要去掉的是常驻的那些。
	interact_label = Label.new()
	interact_label.text = ""
	interact_label.visible = false
	interact_label.set_anchors_preset(Control.PRESET_CENTER)
	interact_label.custom_minimum_size = Vector2(300, 34)
	interact_label.offset_left = -150
	interact_label.offset_right = 150
	interact_label.offset_top = 44
	interact_label.offset_bottom = 78
	interact_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	interact_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	interact_label.add_theme_font_size_override("font_size", 12)
	interact_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	interact_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	interact_label.add_theme_constant_override("outline_size", 4)
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0.08, 0.12, 0.10, 0.78)
	isb.border_color = Color(0.72, 0.6, 0.34, 0.95)
	isb.set_border_width_all(2)
	isb.set_corner_radius_all(10)
	interact_label.add_theme_stylebox_override("normal", isb)
	add_child(interact_label)

	_on_tool_changed(Game.current_tool)


func _on_biomass_changed(_v: float) -> void:
	biomass_label.text = "生物质 %.1f\n石材 %.1f" % [Game.biomass, Game.stone]

func _on_tool_button_pressed(btn: Button) -> void:
	var tool: int = tool_button_map[btn]
	if main == null:
		return
	# 再点一次当前已选中的工具 = 取消选择（替代原来的"选择"按钮）
	main.set_tool(Game.Tool.NONE if Game.current_tool == tool else tool)

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
		Game.Tool.NONE:
			tip = "不放置任何东西 —— 想建造先从左边点一个工具"
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
		Game.Tool.STATUE:
			tip = "点击放置雕像"
	# 常驻提示文字已按用户要求去掉；当前工具的说明挂在**创造列表**的提示上，
	# 按需查看（B 打开列表时会显示），不再在屏幕上常驻一行字。
	if create_panel != null:
		create_panel.tooltip_text = "%s：%s" % [Game.get_tool_name(), tip]

# ---------- 动作菜单（快捷键 K 呼出，游戏内测试动作） ----------

func _build_action_panel() -> void:
	action_panel = PanelContainer.new()
	action_panel.visible = false
	action_panel.position = Vector2(60, 14)
	action_panel.custom_minimum_size = Vector2(150, 0)
	action_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(action_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	action_panel.add_child(vbox)

	var cap := Label.new()
	cap.text = "动作测试（点击播放，再次移动/跳跃恢复）"
	cap.add_theme_font_size_override("font_size", 10)
	cap.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	vbox.add_child(cap)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
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
		b.custom_minimum_size = Vector2(0, 20)
		b.add_theme_font_size_override("font_size", 11)
		b.pressed.connect(_on_action_pressed.bind(i))
		list.add_child(b)

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.13, 0.16, 0.88)
	sb.border_color = Color(0.45, 0.55, 0.5, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

func _toggle_action_panel() -> void:
	_action_visible = not _action_visible
	action_panel.visible = _action_visible
	action_button.button_pressed = _action_visible
	_apply_ui_capture()
	_layout_panels()

func _on_action_pressed(index: int) -> void:
	if main != null and main.player != null:
		main.player.play_action(index)


# ---------- 装备（法杖）面板 ----------
#
# 法杖是武器、单占一格，但一共 146 根 —— 全用滚轮一根根翻不现实，
# 所以给一个「按元素分组的可滚动列表 + 元素筛选」。样式与动作面板完全一致，
# 位置也一样，两者互斥（同屏只有一个侧边面板）。

func _sys() -> Node:
	return get_node_or_null("/root/StaffSystem")


func _build_staff_panel() -> void:
	staff_panel = PanelContainer.new()
	staff_panel.visible = false
	staff_panel.position = Vector2(12, 74)
	staff_panel.custom_minimum_size = Vector2(420, 0)
	staff_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(staff_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	staff_panel.add_child(vbox)

	_staff_cap = Label.new()
	_staff_cap.add_theme_font_size_override("font_size", 13)
	_staff_cap.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	vbox.add_child(_staff_cap)

	# 元素筛选行（全部 + 7 种元素）：146 根一次铺开太长，先按元素收窄
	var sys := _sys()
	var frow := HBoxContainer.new()
	frow.add_theme_constant_override("separation", 3)
	vbox.add_child(frow)
	frow.add_child(_filter_button("全部", -1, sys))
	if sys != null:
		for e in sys.call("element_ids"):
			frow.add_child(_filter_button(str(sys.call("element_name", int(e))), int(e), sys))

	var scroll := ScrollContainer.new()
	scroll.name = "StaffScroll"
	scroll.custom_minimum_size = Vector2(0, 430)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_staff_list = VBoxContainer.new()
	_staff_list.name = "StaffList"
	_staff_list.add_theme_constant_override("separation", 2)
	scroll.add_child(_staff_list)


func _filter_button(text: String, element: int, sys: Node) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(36, 26)
	b.button_pressed = (element == _staff_filter)
	b.add_theme_font_size_override("font_size", 12)
	if element >= 0 and sys != null:
		b.add_theme_color_override("font_color", sys.call("element_color", element))
	b.pressed.connect(_on_staff_filter.bind(element))
	_staff_filter_buttons[element] = b
	return b


func _on_staff_filter(element: int) -> void:
	_staff_filter = element
	# toggle 按钮不会自己互斥，这里手动同步一遍选中态
	for e in _staff_filter_buttons.keys():
		var b: Button = _staff_filter_buttons[e]
		if is_instance_valid(b):
			b.button_pressed = (int(e) == element)
	_fill_staff_panel()


## 重建列表。只在打开时/装备数据变化时调用。
## 注意 `equip()` 是从列表按钮的 pressed 里发出来的，那个信号会经
## `equipment_changed` 绕回来把按钮自己 free 掉 —— 所以重建一律 deferred。
func _fill_staff_panel() -> void:
	if _staff_list == null:
		return
	for c in _staff_list.get_children():
		c.queue_free()
		_staff_list.remove_child(c)
	var sys := _sys()
	if sys == null:
		return
	var owned: Array = sys.call("owned_list", _staff_filter)
	var total: int = int(sys.call("owned_list").size())
	var all: int = int(sys.call("all_ids").size())
	var equipped := str(sys.get("equipped"))
	_staff_cap.text = "装备 · 法杖（点名字换上，世界内 Q / Shift+滚轮 切换）\n已拥有 %d/%d 根%s" % [
			total, all, "   ·   当前空手" if equipped == "" else
			"   ·   当前 %s" % str(sys.call("display_name", equipped))]
	# 「收起法杖」放在最前面：空手也是一种状态（长老祝福只作用于手上的杖）
	var un := Button.new()
	un.text = "空手（收起法杖）"
	un.alignment = HORIZONTAL_ALIGNMENT_LEFT
	un.custom_minimum_size = Vector2(0, 26)
	un.disabled = equipped == ""
	un.pressed.connect(_on_staff_picked.bind(""))
	_staff_list.add_child(un)
	# 每行 = [名字按钮（自动占满，左对齐）] + [元素 · 长老石 标签（自动靠右）]
	# 不用一整条字符串：中文长名字 + 元素 + 石数拼一起会顶到面板边缘被裁掉
	# （实测 "石0" 被切了一半），分成两列既不会裁，元素标签也能对齐成一列。
	for id in owned:
		var sid := str(id)
		var elem := int(sys.call("element_of", sid))
		var col: Color = sys.call("element_color", elem)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_staff_list.add_child(row)
		var b := Button.new()
		b.text = "%s%s%s" % ["▶ " if sid == equipped else "   ",
				str(sys.call("display_name", sid)),
				" *" if bool(sys.call("is_blessed", sid)) else ""]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 26)
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", Color(1, 1, 1) if sid == equipped else col)
		b.pressed.connect(_on_staff_picked.bind(sid))
		row.add_child(b)
		var tag := Label.new()
		tag.text = "%s · 石%d" % [str(sys.call("element_name", elem)),
				int(sys.call("stone_count", sid))]
		tag.add_theme_font_size_override("font_size", 12)
		tag.add_theme_color_override("font_color", col)
		tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(tag)


func _on_staff_picked(id: String) -> void:
	var sys := _sys()
	if sys == null or id == str(sys.get("equipped")):
		return
	sys.call("equip", id)
	if main != null:
		main.call("_show_staff_hint", id)


func _on_equipment_changed() -> void:
	update_staff_slot()
	if _staff_visible:
		_fill_staff_panel.call_deferred()


func _toggle_staff_panel() -> void:
	_set_staff_panel(not _staff_visible)


func _set_staff_panel(on: bool) -> void:
	_staff_visible = on
	if on:
		_fill_staff_panel()
	staff_panel.visible = on
	staff_button.button_pressed = on
	_apply_ui_capture()
	_layout_panels()


## 面板打开时把 rig 的输入让给 UI。
##
## **绝不再改鼠标捕获模式**：俯视角下相机不需要鼠标，光标本来就该一直可见。
## 原来这里在"面板全关"时调用 set_ui_capture(true) 把光标重新捕获隐藏 ——
## 于是按 K 做完动作、面板一关，鼠标就"丢了"（用户实测反馈）。
func _apply_ui_capture() -> void:
	if main == null or main.camera_rig == null:
		return
	var rig: CameraRig = main.camera_rig
	rig.ui_override = _staff_visible or _action_visible or _create_visible or _help_visible


## 动态排布所有打开的菜单：**一行横向排开，互不遮挡**（用户要求）。
##
## 以前是"打开一个就自动关掉另一个"来避免重叠，那样用户想同时看两个面板就不行。
## 现在按最小尺寸依次摆放，谁打开都不会压到别人。
func _layout_panels() -> void:
	# 等一帧：PanelContainer 的最小尺寸要经过一次布局才是准的
	call_deferred("_do_layout_panels")


func _do_layout_panels() -> void:
	const X0 := 12.0
	const Y0 := 12.0
	const GAP := 8.0
	var x := X0
	var panels: Array = []
	if _create_visible:
		panels.append(create_panel)
	if _help_visible:
		panels.append(help_panel)
	if _action_visible:
		panels.append(action_panel)
	if _staff_visible:
		panels.append(staff_panel)
	for p in panels:
		if p == null or not p.visible:
			continue
		(p as Control).reset_size()
		(p as Control).position = Vector2(x, Y0)
		x += (p as Control).size.x + GAP


## B：创造列表开关
func _toggle_create_panel() -> void:
	_set_create_panel(not _create_visible)


func _set_create_panel(on: bool) -> void:
	# 打开时记下当前工具与变体选择；关闭时回滚 ——
	# 用户要求"关闭创建菜单后，还没放置的物品要销毁、状态恢复到打开之前"。
	if on and not _create_visible:
		_tool_before_create = Game.current_tool
		_variants_before_create = _tool_variant_snapshot()
	_create_visible = on
	create_panel.visible = on
	create_button.button_pressed = on
	if not on and main != null:
		# 回滚：恢复工具 + 变体选择，并让 main 清掉半透明预览
		main.set_tool(_tool_before_create)
		_restore_tool_variants(_variants_before_create)
	_apply_ui_capture()
	_layout_panels()


## 记下"当前工具 -> 选中的模型变体"，关闭创建菜单时回滚用
func _tool_variant_snapshot() -> Dictionary:
	if main == null or not ("_variant_sel" in main):
		return {}
	return (main.get("_variant_sel") as Dictionary).duplicate()


func _restore_tool_variants(snap: Dictionary) -> void:
	if main == null or snap.is_empty() or not ("_variant_sel" in main):
		return
	var cur: Dictionary = main.get("_variant_sel")
	cur.clear()
	for k in snap:
		cur[k] = snap[k]


## H：操作说明开关
func _toggle_help_panel() -> void:
	_help_visible = not _help_visible
	help_panel.visible = _help_visible
	help_button.button_pressed = _help_visible
	_apply_ui_capture()
	_layout_panels()


## ESC：关掉当前打开的任意面板；返回 true 表示这次 ESC 被吃掉了
func close_any_panel() -> bool:
	if _create_visible:
		_set_create_panel(false)
		return true
	if _action_visible:
		_toggle_action_panel()
		return true
	if _help_visible:
		_toggle_help_panel()
		return true
	if _staff_visible:
		_set_staff_panel(false)
		return true
	# 没有面板打开时：ESC = 取消当前工具（"选择"按钮去掉后功能保留在这里）
	if main != null and Game.current_tool != Game.Tool.NONE:
		main.set_tool(Game.Tool.NONE)
		return true
	return false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			_toggle_create_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_K:
			_toggle_action_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_H:
			_toggle_help_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			_toggle_staff_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and close_any_panel():
			get_viewport().set_input_as_handled()

# ---------- 家具互动提示 ----------

func show_interact_hint(text: String) -> void:
	if interact_label == null:
		return
	interact_label.text = text
	interact_label.visible = true

func clear_interact_hint() -> void:
	if interact_label:
		interact_label.visible = false

# ---------- 法杖装备格 ----------

## 右下角显示当前装备的法杖：元素色条 + 名称 + 元素 + 长老石 + 第几根。
## 空手时色条压暗、文字提示怎么拿杖。
func update_staff_slot() -> void:
	if staff_slot_label == null:
		return
	var sys := _sys()
	if sys == null:
		return
	var id := str(sys.get("equipped"))
	var owned: int = int(sys.call("owned_list").size())
	if id == "":
		var tip := "按 F 装备" if owned > 0 else "（找长老领取）"
		staff_slot_label.text = "法杖 · 空\n%s" % tip
		staff_slot_icon.color = Color(0.32, 0.34, 0.36)
		return
	var elem := int(sys.get("equipped_element"))
	staff_slot_icon.color = sys.call("element_color", elem)
	var bless := "*" if bool(sys.call("is_blessed", id)) else ""
	staff_slot_label.text = "%s%s  %d/%d\n%s" % [
			str(sys.call("display_name", id)), bless,
			int(sys.call("owned_index", id)), owned,
			str(sys.call("element_name", elem))]


# ---------- 天气信息 ----------

## 右上角常驻显示当前天气与风力（风向用箭头表示）
func _update_weather_label() -> void:
	if weather_label == null:
		return
	var w: float = float(Weather.wind)
	var arrow := "→"
	var d: Vector2 = Weather.wind_dir
	if absf(d.x) > absf(d.y):
		arrow = "→" if d.x > 0.0 else "←"
	else:
		arrow = "↓" if d.y > 0.0 else "↑"
	var level := "微风"
	if w >= 0.85:
		level = "大风"
	elif w >= 0.5:
		level = "有风"
	elif w >= 0.3:
		level = "轻风"
	weather_label.text = "%s\n风力 %.2f %s %s" % [Weather.weather_name(), w, level, arrow]


func _process(delta: float) -> void:
	_weather_accum += delta
	if _weather_accum < 0.2:
		return
	_weather_accum = 0.0
	_update_weather_label()
	update_staff_slot()

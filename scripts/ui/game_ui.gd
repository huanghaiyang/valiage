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
	# 装备数据一变就刷新右下角格子与（打开着的）面板
	var sys := get_node_or_null("/root/StaffSystem")
	if sys != null and not sys.is_connected("equipment_changed", _on_equipment_changed):
		sys.connect("equipment_changed", _on_equipment_changed)
	update_staff_slot()

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

	# 装备按钮（法杖占 1 格，146 根靠滚轮一根根翻太慢，给个列表）
	staff_button = Button.new()
	staff_button.text = "装备 (F)"
	staff_button.custom_minimum_size = Vector2(90, 34)
	staff_button.toggle_mode = true
	staff_button.pressed.connect(_toggle_staff_panel)
	hbox.add_child(staff_button)

	# 动作列表面板（默认隐藏，K 或按钮呼出）
	_build_action_panel()
	_build_staff_panel()

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

	# 天气信息（右上角，生物质下方）
	weather_label = Label.new()
	weather_label.text = "晴朗"
	weather_label.add_theme_font_size_override("font_size", 16)
	weather_label.add_theme_color_override("font_color", Color(0.82, 0.90, 1.0))
	weather_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
	weather_label.add_theme_constant_override("outline_size", 5)
	weather_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	weather_label.offset_left = -260
	weather_label.offset_right = -16
	weather_label.offset_top = 70
	weather_label.offset_bottom = 116
	weather_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(weather_label)

	# 底部提示
	hint_label = Label.new()
	hint_label.text = "左键搭建/涂抹 · WASD 移动 · F 装备 · Q 换杖 · Shift 加速 · Space/C 升降 · T 切换视角 · V 切换天气 · Esc 释放鼠标"
	hint_label.add_theme_font_size_override("font_size", 14)
	hint_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9, 0.9))
	hint_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint_label.offset_top = -34
	hint_label.offset_bottom = -8
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(hint_label)

	# ---- 法杖装备格（右下角）----
	# 设计参考：武器单占一格，格子里显示元素色条 + 名称，空手时格子变暗。
	staff_slot = PanelContainer.new()
	staff_slot.add_theme_stylebox_override("panel", _panel_style())
	staff_slot.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	staff_slot.offset_left = -258
	staff_slot.offset_right = -16
	staff_slot.offset_top = -122
	staff_slot.offset_bottom = -44
	staff_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(staff_slot)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	staff_slot.add_child(srow)
	staff_slot_icon = ColorRect.new()
	staff_slot_icon.custom_minimum_size = Vector2(10, 46)
	staff_slot_icon.color = Color(0.5, 0.5, 0.5)
	srow.add_child(staff_slot_icon)
	staff_slot_label = Label.new()
	staff_slot_label.text = "法杖 · 空"
	staff_slot_label.add_theme_font_size_override("font_size", 15)
	staff_slot_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	srow.add_child(staff_slot_label)

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

	# 家具互动提示（准星下方，按 E 交互）
	interact_label = Label.new()
	interact_label.text = ""
	interact_label.visible = false
	interact_label.set_anchors_preset(Control.PRESET_CENTER)
	interact_label.custom_minimum_size = Vector2(420, 46)
	interact_label.offset_left = -210
	interact_label.offset_right = 210
	interact_label.offset_top = 96
	interact_label.offset_bottom = 142
	interact_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	interact_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	interact_label.add_theme_font_size_override("font_size", 18)
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
	hint_label.text = "【%s】%s · WASD移动 · Shift加速 · F装备 · Q换杖 · Space/C升降 · T切换视角 · 数字键1-0切工具" % [Game.get_tool_name(), tip]

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
	# 与装备面板位置重叠，互斥
	if _action_visible and _staff_visible:
		_set_staff_panel(false)
	_apply_ui_capture()

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
	if on and _action_visible:
		_toggle_action_panel()
	_apply_ui_capture()


## 任一侧边面板打开 -> 放开鼠标（好点列表）；都关了就收回视角控制
func _apply_ui_capture() -> void:
	if main == null or main.camera_rig == null:
		return
	var rig: CameraRig = main.camera_rig
	var any := _staff_visible or _action_visible
	if rig.ui_override == any:
		return
	rig.ui_override = any
	rig.set_ui_capture(not any)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_K:
			_toggle_action_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			_toggle_staff_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _action_visible:
			_toggle_action_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and _staff_visible:
			_set_staff_panel(false)
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
		var tip := "（F 打开装备）" if owned > 0 else "（找长老领取）"
		staff_slot_label.text = "法杖 · 空\n%s" % tip
		staff_slot_icon.color = Color(0.32, 0.34, 0.36)
		return
	var elem := int(sys.get("equipped_element"))
	staff_slot_icon.color = sys.call("element_color", elem)
	var bless := "*" if bool(sys.call("is_blessed", id)) else ""
	staff_slot_label.text = "%s%s  %d/%d\n%s · 长老石 %d · F 装备" % [
			str(sys.call("display_name", id)), bless,
			int(sys.call("owned_index", id)), owned,
			str(sys.call("element_name", elem)),
			int(sys.call("stone_count", id))]


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

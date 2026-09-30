@tool
class_name SettingsMenu
extends CanvasLayer
## 游戏内设置菜单（纯代码构建 ✓ 不依赖 .tscn ✓）
##
## 分类：画质 / 音频 / 语言 / 操作 / 游戏 / 辅助功能 / 关于
## 已能真生效的项即时生效 ✓；标了 todo 的项置灰并显示（待开发）✓
##
## ⚠️ CanvasLayer **没有** visible 属性 ✗ —— 显隐由内部子 Control 控制 ✓

signal menu_opened
signal menu_closed

@export var open_with_escape := true
@export var default_category := ""

var store: SettingsStore = null

var _root: Control = null
var _content: VBoxContainer = null
var _cat_box: VBoxContainer = null
var _status: Label = null
var _cat_buttons := {}
var _current_cat := ""
var _is_open := false
var _saved_pause := false
var _saved_mouse := Input.MOUSE_MODE_VISIBLE


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	if store == null:
		store = SettingsStore.new()
		store.load_from_disk()
	_build()
	_root.visible = false
	_show_category(default_category if default_category != "" else SettingsSchema.ORDER[0])


## 中文兜底：用**系统字体**，项目里没有 CJK 字体也不会显示成方块 ✓
static func make_cjk_theme() -> Theme:
	var th := Theme.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "SimSun",
		"Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC",
	])
	th.default_font = f
	th.default_font_size = 16
	return th


func _build() -> void:
	_root = Control.new()
	_root.name = "SettingsRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.theme = make_cjk_theme()
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var frame := PanelContainer.new()
	frame.set_anchors_preset(Control.PRESET_CENTER)
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -520
	frame.offset_top = -340
	frame.offset_right = 520
	frame.offset_bottom = 340
	_root.add_child(frame)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	frame.add_child(outer)

	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 22)
	outer.add_child(title)

	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 150
	outer.add_child(split)

	_cat_box = VBoxContainer.new()
	_cat_box.custom_minimum_size = Vector2(150, 0)
	_cat_box.add_theme_constant_override("separation", 4)
	split.add_child(_cat_box)
	for cat in SettingsSchema.ORDER:
		var b := Button.new()
		b.text = String(cat)
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.pressed.connect(_show_category.bind(String(cat)))
		_cat_box.add_child(b)
		_cat_buttons[String(cat)] = b

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_content)

	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	outer.add_child(foot)
	var b_reset := Button.new()
	b_reset.text = "恢复默认"
	b_reset.pressed.connect(_reset_defaults)
	foot.add_child(b_reset)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	foot.add_child(_status)
	var b_close := Button.new()
	b_close.text = "关闭"
	b_close.pressed.connect(close)
	foot.add_child(b_close)


func _show_category(cat: String) -> void:
	_current_cat = cat
	for k in _cat_buttons.keys():
		(_cat_buttons[k] as Button).button_pressed = (String(k) == cat)
	# 先 remove_child 再 queue_free ✓ —— 只 queue_free 的话，旧行会留到帧末 ✗，
	# 期间新旧行会叠在一起（而且旧行的闭包会短暂持有已释放的控件 ✗）
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	var table: Dictionary = SettingsSchema.items()
	var info := SettingsApply.about_info()
	for it in (table.get(cat, []) as Array):
		var d: Dictionary = it
		_content.add_child(_make_row(d, info))
	# 操作页：按键绑定是**运行时状态** ✓，不能写死在 schema 里 ✗ → 动态生成 ✓
	if cat == SettingsSchema.CAT_CONTROLS:
		_content.add_child(_make_keybindings_section())


func _make_row(item: Dictionary, info: Dictionary) -> Control:
	var key := String(item["key"])
	var kind := int(item["kind"])
	var todo := bool(item.get("todo", false))
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	row.add_child(line)

	var name_label := Label.new()
	name_label.text = String(item.get("label", key))
	name_label.custom_minimum_size = Vector2(170, 0)
	if todo:
		name_label.modulate = Color(1, 1, 1, 0.55)
	line.add_child(name_label)

	var ctl: Control = null
	match kind:
		SettingsSchema.Kind.TOGGLE:
			var cb := CheckBox.new()
			cb.button_pressed = bool(store.get_value(key))
			cb.disabled = todo
			cb.toggled.connect(func(v: bool): _commit(key, v))
			ctl = cb
		SettingsSchema.Kind.SLIDER:
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 8)
			var sl := HSlider.new()
			sl.min_value = float(item.get("min", 0.0))
			sl.max_value = float(item.get("max", 1.0))
			sl.step = float(item.get("step", 0.01))
			sl.custom_minimum_size = Vector2(260, 0)
			sl.value = float(store.get_value(key))
			# ★ HSlider **没有** disabled 属性 ✗（那是 BaseButton 才有的 ✓）→ 用 editable ✓
			#   曾经写成 sl.disabled = todo ✗ → 点开音频页当场运行时报错 ✗（被日志精确定位到本行 ✓）
			sl.editable = not todo
			if todo:
				sl.modulate = Color(1, 1, 1, 0.5)
			var vlab := Label.new()
			vlab.text = "%.0f%%" % (sl.value * 100.0)
			vlab.custom_minimum_size = Vector2(56, 0)
			sl.value_changed.connect(func(v: float):
				vlab.text = "%.0f%%" % (v * 100.0)
				_commit(key, snappedf(v, float(item.get("step", 0.01))))
			)
			box.add_child(sl)
			box.add_child(vlab)
			ctl = box
		SettingsSchema.Kind.CHOICE:
			var ob := OptionButton.new()
			for c in (item.get("choices", []) as Array):
				ob.add_item(String(c))
			ob.selected = SettingsSchema.value_to_index(key, store.get_value(key))
			ob.disabled = todo
			ob.item_selected.connect(func(i: int): _commit(key, SettingsSchema.choice_value(key, i)))
			ctl = ob
		SettingsSchema.Kind.INFO:
			var il := Label.new()
			var txt := String(item.get("value_text", ""))
			if info.has(key):
				txt = String(info[key])
			il.text = txt
			il.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			il.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			il.modulate = Color(0.85, 0.85, 0.9, 0.9)
			ctl = il
	if ctl != null:
		if kind != SettingsSchema.Kind.SLIDER:
			ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(ctl)
	if todo:
		var tag := Label.new()
		tag.text = "（待开发）"
		tag.modulate = Color(1, 0.85, 0.4, 0.75)
		line.add_child(tag)
	var hint := String(item.get("hint", ""))
	if hint != "":
		var hl := Label.new()
		hl.text = "    " + hint
		hl.add_theme_font_size_override("font_size", 12)
		hl.modulate = Color(1, 1, 1, 0.5)
		hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(hl)
	return row


## 一项改动：写进 store ✓ 立刻应用 ✓ 反馈状态 ✓
func _commit(key: String, value: Variant) -> void:
	store.set_value(key, value)
	var r := SettingsApply.apply_one(store, key)
	var word := "已应用"
	match r:
		"todo": word = "已保存（功能待开发）"
		"editor-skip": word = "已保存（编辑器内不改变窗口 ✓）"
		"failed": word = "保存成功，但应用失败 ✗"
		"queued": word = "已保存（画质系统稍后生效）"
	if _status != null:
		_status.text = "%s：%s —— %s" % [key, str(value), word]


func _reset_defaults() -> void:
	store.reset_all()
	store.save()
	for key in SettingsSchema.defaults().keys():
		SettingsApply.apply_one(store, String(key))
	_show_category(_current_cat)
	if _status != null:
		_status.text = "已恢复默认并应用 ✓"


## 实际建出来的分类按钮文字（供测试/外部确认 UI 真的构建成功 ✓）
func category_names() -> Array:
	var out: Array = []
	if _cat_box == null:
		return out
	for k in _cat_box.get_children():
		if k is Button:
			out.append((k as Button).text)
	return out


## ---- 按键绑定段 ✓ ----
var _capturing := ""

func _make_keybindings_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var head := Label.new()
	head.text = "按键绑定"
	head.add_theme_font_size_override("font_size", 18)
	box.add_child(head)
	var tip := Label.new()
	tip.text = "    点右侧按钮 → 按下新键即可改绑；按 ESC 取消。改动会立即保存 ✓"
	tip.add_theme_font_size_override("font_size", 12)
	tip.modulate = Color(1, 1, 1, 0.55)
	box.add_child(tip)
	for a in SettingsInput.game_actions():
		var action := String(a)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		var name_label := Label.new()
		name_label.text = action
		name_label.custom_minimum_size = Vector2(220, 0)
		row.add_child(name_label)
		var b := Button.new()
		b.text = SettingsInput.current_text(action)
		b.custom_minimum_size = Vector2(200, 0)
		b.pressed.connect(_start_capture.bind(action, b))
		row.add_child(b)
		var rb := Button.new()
		rb.text = "恢复默认"
		rb.pressed.connect(func():
			SettingsInput.reset_action(store, action)
			_show_category(SettingsSchema.CAT_CONTROLS)
		)
		row.add_child(rb)
		box.add_child(row)
	return box


func _start_capture(action: String, button: Button) -> void:
	_capturing = action
	if button != null:
		button.text = "请按键…（ESC 取消）"
	if _status != null:
		_status.text = "正在为 %s 改键…" % action


## 打开菜单的按键：ESC 是常规键 ✓，F10 是**不会被别的脚本抢走**的备用键 ✓✓
@export var open_keys := [KEY_ESCAPE, KEY_F10]

## 输入处理放在 _input（Node 能拿到的最早一站 ✓）而不是 _unhandled_input ✗ ——
## 项目里 camera_rig.gd:156 与 game_ui.gd:645 都**直接处理 ESC** ✗，
## 它们若先 set_input_as_handled()，_unhandled_input 就永远收不到 ✗。
## 而 GameSettings 是 autoload ✓ → 在场景树里排在主场景之前 ✓ → 这里能抢在它们前面 ✓。
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return
	var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode

	# ① 正在改键：优先吃掉所有按键 ✓
	if _capturing != "":
		if code == KEY_ESCAPE:
			_capturing = ""
			_show_category(SettingsSchema.CAT_CONTROLS)
			if _status != null:
				_status.text = "已取消改键 ✓"
		else:
			var act := _capturing
			_capturing = ""
			var r: Dictionary = SettingsInput.rebind(store, act, k)
			_show_category(SettingsSchema.CAT_CONTROLS)
			if _status != null:
				_status.text = ("%s → %s ✓" % [act, str(r.get("text", ""))]) if bool(r.get("ok", false)) else String(r.get("message", "改键失败"))
		get_viewport().set_input_as_handled()
		return

	# ② 菜单开着：ESC 关闭 ✓
	if _is_open:
		if code == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
		return

	# ③ 菜单关着：按 open_keys 打开 ✓
	if not open_keys.has(code):
		return
	if code == KEY_ESCAPE:
		if not open_with_escape:
			return
		# 只有"正在输入文字"时才让路 ✓。
		# 早期写成"只要有焦点就让路" ✗ —— 那会导致游戏里只要有个**残留焦点的 HUD 按钮** ✗，
		# ESC 就永久打不开 ✗（被单元测试逮住 ✓）。
		# 只有"**可见的**输入框"有焦点时才让路 ✓。
		# 加上可见性判断很重要 ✓：已经隐藏/待释放的输入框会**残留焦点** ✗，
		# 那种情况下再挡 ESC 就等于 ESC 无故失效 ✗（测试里就踩到了这个 ✓）。
		var fo := get_viewport().gui_get_focus_owner()
		if (fo is LineEdit or fo is TextEdit) and (fo as Control).is_visible_in_tree():
			return
	open()
	get_viewport().set_input_as_handled()


func is_open() -> bool:
	return _is_open


func open() -> void:
	if _is_open:
		return
	_is_open = true
	_root.visible = true
	if not Engine.is_editor_hint():
		_saved_pause = get_tree().paused
		_saved_mouse = Input.mouse_mode
		get_tree().paused = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_show_category(_current_cat)
	menu_opened.emit()


func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_root.visible = false
	if not Engine.is_editor_hint():
		get_tree().paused = _saved_pause
		Input.mouse_mode = _saved_mouse
	store.save()
	menu_closed.emit()


func toggle() -> void:
	if _is_open:
		close()
	else:
		open()


## 说明：这里**故意不再处理 ESC** ✗ —— 全部逻辑都在上面的 _input 里 ✓
## （原来用 _unhandled_input 会被 camera_rig / game_ui 的 ESC 处理抢掉 ✗）

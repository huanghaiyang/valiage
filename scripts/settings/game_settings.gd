@tool
extends Node
## 设置总控（自动加载为 GameSettings ✓）
##
## 职责：
##   · 启动时加载设置 → 还原按键绑定 → 应用全部设置 ✓
##   · 创建设置菜单 ✓（ESC 开关）
##   · 提供字幕显示接口 ✓
##
## 用法（任意脚本）：
##   GameSettings.open_menu() / close_menu() / toggle_menu()
##   GameSettings.show_subtitle("你好，旅行者。", 3.0)
##   GameSettings.store.get_value("audio/music")

var store: SettingsStore = null
var menu: SettingsMenu = null

var _sub_layer: CanvasLayer = null
var _sub_label: Label = null
var _sub_left := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	store = SettingsStore.new()
	var loaded := store.load_from_disk()
	# 按键绑定必须在应用设置之前还原 ✓
	var rebound := SettingsInput.load_bindings(store)
	var applied := SettingsApply.apply_all(store)
	var todos := 0
	for k in applied.keys():
		if String(applied[k]) == "todo":
			todos += 1
	print("[设置] 读入 %d 项 ｜ 还原按键 %d 个 ｜ 已应用 ✓（占位待开发 %d 项）" % [loaded, rebound, todos])

	menu = SettingsMenu.new()
	menu.name = "SettingsMenu"
	menu.store = store
	add_child(menu)


func open_menu() -> void:
	if menu != null:
		menu.open()


func close_menu() -> void:
	if menu != null:
		menu.close()


func toggle_menu() -> void:
	if menu != null:
		menu.toggle()


func is_menu_open() -> bool:
	return menu != null and menu.is_open()


## ---- 字幕系统 ✓ ----
## 受设置项 language/subtitle 控制 ✓（关掉后直接不显示 ✓）
func subtitles_enabled() -> bool:
	return store == null or bool(store.get_value("language/subtitle"))


func show_subtitle(text: String, seconds := 3.0) -> void:
	if not subtitles_enabled():
		return
	_ensure_subtitle_layer()
	if _sub_label == null:
		return
	_sub_label.text = text
	_sub_left = maxf(0.5, seconds)
	_sub_layer.visible = true


func hide_subtitle() -> void:
	_sub_left = 0.0
	if _sub_layer != null:
		_sub_layer.visible = false


func _ensure_subtitle_layer() -> void:
	if _sub_layer != null and is_instance_valid(_sub_layer):
		return
	_sub_layer = CanvasLayer.new()
	_sub_layer.name = "SubtitleLayer"
	_sub_layer.layer = 90
	add_child(_sub_layer)
	var box := MarginContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	box.offset_top = -140
	box.offset_bottom = -60
	box.add_theme_constant_override("margin_left", 60)
	box.add_theme_constant_override("margin_right", 60)
	box.theme = SettingsMenu.make_cjk_theme()      # 中文兜底 ✓
	_sub_layer.add_child(box)
	_sub_label = Label.new()
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_sub_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sub_label.add_theme_font_size_override("font_size", 22)
	_sub_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_sub_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_sub_label.add_theme_constant_override("outline_size", 6)
	box.add_child(_sub_label)
	_sub_layer.visible = false


func _process(delta: float) -> void:
	if _sub_left <= 0.0:
		return
	_sub_left -= delta
	if _sub_left <= 0.0 and _sub_layer != null:
		_sub_layer.visible = false
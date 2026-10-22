@tool
class_name ResInspectorDock
extends VBoxContainer
## .res / .tres / .tscn 文件查看器面板（放进编辑器底部面板，整宽）。
##
## 本文件只做「外壳 + 编排」：工具栏、五个分页、状态栏、报告复制/导出。
## 所有文件解析都委托给 ResFileFormat（懒加载，见 ui/fmt_util.gd）——
## 这个文件里没有任何 RSRC/文本格式的解析代码。
##
## 硬约束（无头冒烟测试会崩的坑）：
## * _ready() 里不碰 EditorInterface / EditorPlugin / EditorUndoRedoManager；
##   「在文件系统中定位」只在按钮按下时、且仅在编辑器里调用。
## * 解析模块不存在时界面照样能实例化，只是显示「解析模块未就绪」。

signal status_changed(text: String)

## 解析核心的约定路径（契约 CONTRACT.md 第 2 节）
const FORMAT_PATH := "res://addons/res_inspector/res_format.gd"

const UIKit := preload("res://addons/res_inspector/ui/ui_kit.gd")
const FmtUtil := preload("res://addons/res_inspector/ui/fmt_util.gd")
const SummaryPanel := preload("res://addons/res_inspector/ui/summary_panel.gd")
const StructurePanel := preload("res://addons/res_inspector/ui/structure_panel.gd")
const PropertyPanel := preload("res://addons/res_inspector/ui/property_panel.gd")
const PreviewPanel := preload("res://addons/res_inspector/ui/preview_panel.gd")
const RawPanel := preload("res://addons/res_inspector/ui/raw_panel.gd")

const TAB_TITLES := ["摘要", "结构", "属性", "预览", "原始"]

## 仅测试/调试用：把解析模块指向替身脚本。默认就是 FORMAT_PATH。
var format_script_path: String = FORMAT_PATH
## 是否调用 ResourceLoader 载入资源对象（工具栏「仅结构解析」= false）
var _load_resource := true

var _fmt = null
var _info: Dictionary = {}
var _current_path: String = ""
var _built := false

var _tabs: TabContainer = null
var _summary: Control = null
var _structure: Control = null
var _props: Control = null
var _preview: Control = null
var _raw: Control = null

var _status: Label = null
var _path_button: Button = null
var _open_button: Button = null
var _reload_button: Button = null
var _reveal_button: Button = null
var _copy_button: Button = null
var _export_button: Button = null
var _struct_only_toggle: CheckButton = null

var _open_dialog: FileDialog = null
var _save_dialog: FileDialog = null


func _ready() -> void:
	_ensure_built()


# ---------------------------------------------------------------------------
# 契约接口
# ---------------------------------------------------------------------------

## 唯一入口：加载并显示；path 可为 res:// 或绝对路径
func open_path(path: String) -> void:
	_ensure_built()
	var p := path.strip_edges()
	_current_path = p
	_ensure_format()

	if p == "":
		_info = {}
		_push_unavailable("路径为空：没有可打开的文件")
		_update_buttons()
		return

	if _fmt == null:
		_info = {}
		_push_unavailable("解析模块未就绪：未找到 %s" % format_script_path)
		_update_buttons()
		return

	var t0 := Time.get_ticks_msec()
	var info: Dictionary = FmtUtil.inspect(_fmt, p, _load_resource)
	var dt := int(Time.get_ticks_msec() - t0)
	if info.is_empty():
		_info = {}
		_push_unavailable("解析模块没有返回结果（可能内部出错）：%s" % p)
		_update_buttons()
		return

	_info = info
	_distribute()
	_update_buttons()
	_report_status(info, dt)


## 重新读取当前文件
func reload() -> void:
	if _current_path == "":
		_set_status("还没有打开文件，无法重载")
		return
	open_path(_current_path)


## 当前文件路径；无文件时返回 ""
func get_current_path() -> String:
	return _current_path


## 当前解析结果（供 plugin.gd / 测试读取）
func get_current_info() -> Dictionary:
	return _info


## 解析模块是否就绪
func has_format_module() -> bool:
	_ensure_format()
	return _fmt != null


# ---------------------------------------------------------------------------
# 构建界面（不碰任何编辑器单例）
# ---------------------------------------------------------------------------

func _ensure_built() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)
	_build_toolbar()
	_build_tabs()
	_ensure_format()
	if _fmt == null:
		_push_unavailable("解析模块未就绪：未找到 %s" % format_script_path)
	else:
		_push_unavailable("尚未打开文件（用工具栏「打开…」，或从 FileSystem 拖入 .res / .tres）")


func _build_toolbar() -> void:
	var bar := HBoxContainer.new()
	bar.name = "工具栏"
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)

	_open_button = _bar_button(bar, "打开…", _on_open_pressed, "选择一个 .res / .tres / .tscn 文件")
	_reload_button = _bar_button(bar, "重载", _on_reload_pressed, "重新读取当前文件")
	_reveal_button = _bar_button(bar, "在文件系统中定位", _on_reveal_pressed, "在编辑器 FileSystem 面板中定位当前文件")
	bar.add_child(VSeparator.new())

	_path_button = Button.new()
	_path_button.flat = true
	_path_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_path_button.clip_text = true
	_path_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_button.text = "（未选择文件）"
	_path_button.tooltip_text = "点击复制完整路径"
	_path_button.pressed.connect(_on_copy_path_pressed)
	bar.add_child(_path_button)
	bar.add_child(VSeparator.new())

	_copy_button = _bar_button(bar, "复制报告", _on_copy_report_pressed, "把纯文本报告复制到剪贴板")
	_export_button = _bar_button(bar, "导出报告…", _on_export_report_pressed, "把纯文本报告另存为 .txt")

	_struct_only_toggle = CheckButton.new()
	_struct_only_toggle.text = "仅结构解析"
	_struct_only_toggle.tooltip_text = "不调用 ResourceLoader：只解析头部/结构表，不载入资源对象（大文件更快，但属性/预览为空）"
	_struct_only_toggle.button_pressed = false
	_struct_only_toggle.toggled.connect(_on_struct_only_toggled)
	bar.add_child(_struct_only_toggle)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)

	_status = Label.new()
	_status.text = "就绪"
	_status.clip_text = true
	_status.custom_minimum_size = Vector2(260, 0)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.add_theme_color_override("font_color", UIKit.DIM)
	bar.add_child(_status)


func _build_tabs() -> void:
	_tabs = TabContainer.new()
	_tabs.name = "分页"
	_tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs.custom_minimum_size = Vector2(0, 340)
	add_child(_tabs)

	_summary = SummaryPanel.new()
	_summary.name = TAB_TITLES[0]
	_tabs.add_child(_summary)

	_structure = StructurePanel.new()
	_structure.name = TAB_TITLES[1]
	_tabs.add_child(_structure)

	_props = PropertyPanel.new()
	_props.name = TAB_TITLES[2]
	_tabs.add_child(_props)

	_preview = PreviewPanel.new()
	_preview.name = TAB_TITLES[3]
	_tabs.add_child(_preview)

	_raw = RawPanel.new()
	_raw.name = TAB_TITLES[4]
	_tabs.add_child(_raw)


## 文件对话框懒创建：_ready() 里不建，只在真正按按钮时建。
## 用普通 FileDialog（编辑器专属的 EditorFileDialog 在 --headless --script 下不保证可用）。
func _ensure_dialogs() -> void:
	if _open_dialog == null:
		_open_dialog = FileDialog.new()
		_open_dialog.title = "选择要查看的资源文件"
		_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_open_dialog.current_dir = ProjectSettings.globalize_path("res://")
		_open_dialog.filters = PackedStringArray([
			"*.res, *.tres, *.tscn, *.escn ; 资源文件",
			"*.* ; 所有文件",
		])
		_open_dialog.file_selected.connect(_on_open_file_selected)
		add_child(_open_dialog)

	if _save_dialog == null:
		_save_dialog = FileDialog.new()
		_save_dialog.title = "导出报告"
		_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_save_dialog.current_dir = ProjectSettings.globalize_path("res://")
		_save_dialog.filters = PackedStringArray(["*.txt ; 文本报告"])
		_save_dialog.file_selected.connect(_on_save_file_selected)
		add_child(_save_dialog)


func _bar_button(bar: HBoxContainer, text: String, cb: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(cb)
	bar.add_child(b)
	return b


# ---------------------------------------------------------------------------
# 数据分发
# ---------------------------------------------------------------------------

func _ensure_format() -> void:
	if _fmt != null:
		return
	_fmt = FmtUtil.load_format(format_script_path)


func _panels() -> Array:
	return [_summary, _structure, _props, _preview, _raw]


func _distribute() -> void:
	for p in _panels():
		if p != null:
			p.set_info(_info, _fmt)


func _push_unavailable(reason: String) -> void:
	for p in _panels():
		if p != null:
			p.set_unavailable(reason)
	_set_status(reason)


func _update_buttons() -> void:
	var no_file := _current_path == ""
	if _path_button != null:
		_path_button.text = _current_path if not no_file else "（未选择文件）"
		var abs_path := str(_info.get("abs_path", ""))
		_path_button.tooltip_text = "%s\n（点击复制完整路径）" % (abs_path if abs_path != "" else _current_path) if not no_file else "还没有打开文件"
	if _reload_button != null:
		_reload_button.disabled = no_file
	if _reveal_button != null:
		_reveal_button.disabled = no_file
	var no_report := _info.is_empty() or _fmt == null
	if _copy_button != null:
		_copy_button.disabled = no_report
	if _export_button != null:
		_export_button.disabled = no_report


func _report_status(info: Dictionary, measured_ms: int) -> void:
	if not bool(info.get("exists", false)):
		_set_status("文件不存在或不可读：%s" % _current_path)
		return
	var parts := PackedStringArray()
	if not bool(info.get("ok", false)):
		# RSCC（压缩资源）这类情况：结构没解析出来，但资源可能已经载入成功，
		# 所以只标「解析受限」，其余分页照常可用（不能把整页变成错误页）。
		parts.append("解析受限" if info.get("resource", null) != null else "解析失败")
	parts.append(_format_text(info))
	var cls := str(info.get("resource_class", ""))
	if cls != "":
		parts.append(cls)
	parts.append(FmtUtil.human_size(_fmt, int(info.get("size", 0))))
	var elapsed := int(info.get("elapsed_ms", 0))
	if elapsed <= 0:
		elapsed = measured_ms
	parts.append("%d ms" % elapsed)
	var warnings = info.get("warnings", PackedStringArray())
	if (warnings is PackedStringArray or warnings is Array) and warnings.size() > 0:
		parts.append("⚠ %d 条告警" % warnings.size())
	if str(info.get("load_error", "")) != "":
		parts.append("资源载入失败")
	_set_status(" · ".join(parts))


func _format_text(info: Dictionary) -> String:
	match str(info.get("format", "")):
		"binary":
			return "二进制 RSRC"
		"text":
			return "文本 .tres"
		_:
			return "格式未知"


func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text
		_status.tooltip_text = text
	status_changed.emit(text)


## plugin.gd 调用的公开状态入口（右键菜单/菜单项选中路径时给个提示）
func set_status(text: String) -> void:
	_set_status(text)


## 当前状态栏文字（自测/调试用）
func get_status_text() -> String:
	return _status.text if _status != null else ""


## 工具栏「仅结构解析」开关：切换后对当前文件重新解析
func _on_struct_only_toggled(pressed: bool) -> void:
	set_load_resource(not pressed)


## 设置是否载入资源对象（plugin.gd / 自测可调用）；会重载当前文件
func set_load_resource(enabled: bool) -> void:
	_load_resource = enabled
	if _struct_only_toggle != null:
		_struct_only_toggle.set_pressed_no_signal(not enabled)
	if _current_path != "":
		reload()
		_set_status("仅结构解析：已跳过 ResourceLoader（属性/预览为空）" if not enabled else "已恢复载入资源对象")
	else:
		_set_status("已切换为「仅结构解析」：下次打开文件生效" if not enabled else "已恢复载入资源对象")


func is_load_resource_enabled() -> bool:
	return _load_resource


# ---------------------------------------------------------------------------
# 按钮回调
# ---------------------------------------------------------------------------

func _on_open_pressed() -> void:
	_ensure_dialogs()
	if _open_dialog == null:
		return
	var dir := _current_abs_path().get_base_dir()
	if dir != "":
		_open_dialog.current_dir = dir
	_open_dialog.popup_centered_ratio(0.55)


## 当前文件的绝对路径（没有则返回空串）
func _current_abs_path() -> String:
	var abs_path := str(_info.get("abs_path", ""))
	if abs_path != "":
		return abs_path
	if _current_path.begins_with("res://") or _current_path.begins_with("user://"):
		return ProjectSettings.globalize_path(_current_path)
	return _current_path


func _on_open_file_selected(path: String) -> void:
	open_path(path)


func _on_reload_pressed() -> void:
	reload()


func _on_copy_path_pressed() -> void:
	if _current_path == "":
		_set_status("还没有打开文件")
		return
	var abs_path := str(_info.get("abs_path", ""))
	_copy_text(abs_path if abs_path != "" else _current_path)
	_set_status("路径已复制：%s" % (abs_path if abs_path != "" else _current_path))


func _on_reveal_pressed() -> void:
	if _current_path == "":
		_set_status("还没有打开文件，无法定位")
		return
	# 只有真的在编辑器里才碰 EditorInterface（无头测试不会走到这里）
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		var ei = Engine.get_singleton("EditorInterface")
		if ei != null and ei.has_method("get_file_system_dock"):
			var fs_dock = ei.call("get_file_system_dock")
			if fs_dock != null:
				for m in ["navigate_to_path", "select_file"]:
					if fs_dock.has_method(m):
						fs_dock.call(m, _current_path)
						_set_status("已在文件系统中定位：%s" % _current_path)
						return
		_copy_text(_current_path)
		_set_status("文件系统面板不支持定位，已改为复制路径")
		return
	var abs_path := str(_info.get("abs_path", ""))
	if abs_path == "":
		abs_path = _current_path
	_copy_text(abs_path)
	_set_status("当前环境没有文件系统面板，已复制路径：%s" % abs_path)


func _on_copy_report_pressed() -> void:
	if _fmt == null:
		_set_status("解析模块未就绪，无法生成报告")
		return
	if _info.is_empty():
		_set_status("还没有可复制的报告")
		return
	var txt: String = FmtUtil.format_report(_fmt, _info)
	if txt == "":
		_set_status("报告内容为空，未复制")
		return
	if _copy_text(txt):
		_set_status("报告已复制到剪贴板（%d 字符）" % txt.length())


func _on_export_report_pressed() -> void:
	if _fmt == null:
		_set_status("解析模块未就绪，无法导出报告")
		return
	if _info.is_empty():
		_set_status("还没有可导出的报告")
		return
	_ensure_dialogs()
	if _save_dialog == null:
		return
	_save_dialog.current_file = _default_report_name()
	_save_dialog.popup_centered_ratio(0.5)


func _default_report_name() -> String:
	var base := _current_path.get_file()
	if base == "":
		base = "res"
	return "%s_报告.txt" % base


func _on_save_file_selected(path: String) -> void:
	var txt: String = FmtUtil.format_report(_fmt, _info)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_set_status("导出失败：%s（错误码 %d）" % [path, FileAccess.get_open_error()])
		return
	f.store_string(txt)
	f.close()
	_set_status("报告已导出：%s（%d 字符）" % [path, txt.length()])


func _copy_text(text: String) -> bool:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_CLIPBOARD):
		_set_status("当前环境不支持剪贴板操作")
		return false
	DisplayServer.clipboard_set(text)
	return true


# ---------------------------------------------------------------------------
# 拖放：从 FileSystem 面板把资源拖进面板即可打开
# ---------------------------------------------------------------------------

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary):
		return false
	var d: Dictionary = data
	return d.has("files")


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var d: Dictionary = data
	var files = d.get("files", null)
	if files == null:
		return
	if (files is PackedStringArray or files is Array) and files.size() > 0:
		open_path(str(files[0]))


# ---------------------------------------------------------------------------
# 供 plugin.gd / 无头自测使用的便捷接口
# ---------------------------------------------------------------------------

## 切到第 index 个分页（0=摘要 … 4=原始）
func select_tab(index: int) -> void:
	if _tabs == null:
		return
	_tabs.current_tab = clampi(index, 0, maxi(0, _tabs.get_tab_count() - 1))


func get_tab_count() -> int:
	return _tabs.get_tab_count() if _tabs != null else 0


func get_tab_title(index: int) -> String:
	if _tabs == null or index < 0 or index >= _tabs.get_tab_count():
		return ""
	return _tabs.get_tab_title(index)


func get_panel(index: int) -> Control:
	var ps := _panels()
	if index < 0 or index >= ps.size():
		return null
	return ps[index]


## 把五个分页都切一遍（无头自测用：确保每个分页都能构建/显示而不报错）
func cycle_all_tabs() -> void:
	for i in get_tab_count():
		select_tab(i)

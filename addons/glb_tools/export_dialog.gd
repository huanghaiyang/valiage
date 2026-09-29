@tool
extends ConfirmationDialog
## 「导出选中节点为 GLB」窗口（从场景树里选中的节点导出）。

const GlbExport := preload("res://addons/glb_tools/glb_export.gd")

const DEFAULT_DIR := "res://assets/models/exported"

var _nodes: Array = []
var _path_edit: LineEdit
var _path_preview: Label
var _keep_world: CheckBox
var _split: CheckBox
var _info: Label
var _status: Label
var _picker: EditorFileDialog


func _init() -> void:
	title = "导出选中节点为 GLB"
	ok_button_text = "导出"
	dialog_hide_on_ok = false          # 属性名是 dialog_hide_on_ok（Godot 4；hide_on_ok 是 Godot 3 的，会解析失败）
	confirmed.connect(_on_confirmed)
	# 插件窗口不会自动继承编辑器主题，不设的话用的是 Godot 默认主题（配色偏蓝、文字看不清）
	var ed_theme := EditorInterface.get_editor_theme()
	if ed_theme != null:
		theme = ed_theme
	# 内容套一层 ScrollContainer：否则 autowrap 的 Label 在宽度未定时算出的最小高度会爆炸，
	# ConfirmationDialog 会按内容最小尺寸把自己撑到 1800+ px，确认按钮直接跑到屏幕外（实测过）
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(600, 280)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 8)
	scroll.add_child(vb)

	_info = Label.new()
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_info)

	var row := HBoxContainer.new()
	var lab := Label.new()
	lab.text = "输出到"
	row.add_child(lab)
	_path_edit = LineEdit.new()
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.text_changed.connect(func(_t: String) -> void: _update_path_preview())
	row.add_child(_path_edit)
	var browse := Button.new()
	browse.text = "浏览…"
	browse.pressed.connect(_on_browse)
	row.add_child(browse)
	vb.add_child(row)

	_path_preview = Label.new()
	_path_preview.add_theme_font_size_override("font_size", 11)
	_path_preview.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_path_preview)

	_keep_world = CheckBox.new()
	_keep_world.text = "保持世界变换（多选时按各自原本的位置摆好）"
	_keep_world.button_pressed = true
	vb.add_child(_keep_world)

	_split = CheckBox.new()
	_split.text = "每个节点单独一个文件（不勾选则合并成 1 个）"
	_split.button_pressed = false
	_split.tooltip_text = "勾上：N 个节点写出 N 个 glb（文件名 = 原文件名_节点名）"
	vb.add_child(_split)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_status)


func setup(nodes: Array) -> void:
	_nodes = []
	for n in nodes:
		if n is Node and is_instance_valid(n):
			_nodes.append(n)
	var names := PackedStringArray()
	for n in _nodes:
		names.append((n as Node).name)
	var shown := ", ".join(names.slice(0, mini(names.size(), 6)))
	if names.size() > 6:
		shown += " 等"
	_info.text = "将导出 %d 个节点（连同子树）：%s" % [_nodes.size(), shown]

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DEFAULT_DIR))
	if _nodes.is_empty():
		_path_edit.text = DEFAULT_DIR + "/exported.glb"
	else:
		var stem := String((_nodes[0] as Node).name)
		if _nodes.size() > 1:
			stem += "_等%d个" % _nodes.size()
		_path_edit.text = "%s/%s.glb" % [DEFAULT_DIR, stem]
	_update_path_preview()
	_path_edit.grab_focus()
	_path_edit.select_all()


## 明确告诉用户"到底会写到哪里"（res:// 会展开成磁盘绝对路径）
func _update_path_preview() -> void:
	var p := _path_edit.text.strip_edges()
	if p.is_empty():
		_path_preview.text = "（还没填输出路径）"
		return
	var abs := p
	if p.begins_with("res://") or p.begins_with("user://"):
		abs = ProjectSettings.globalize_path(p)
	_path_preview.text = "实际写入：%s" % abs


func _on_browse() -> void:
	if _picker == null:
		_picker = EditorFileDialog.new()
		_picker.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_picker.access = EditorFileDialog.ACCESS_RESOURCES
		_picker.add_filter("*.glb", "glTF 二进制")
		_picker.file_selected.connect(func(p: String) -> void: _path_edit.text = p)
		add_child(_picker)
	_picker.current_path = _path_edit.text
	_picker.popup_centered_ratio(0.6)


func _on_confirmed() -> void:
	if _nodes.is_empty():
		_status.text = "没有选中节点"
		return
	var path := _path_edit.text.strip_edges()
	if path.is_empty():
		_status.text = "请先填输出路径"
		return
	if not path.to_lower().ends_with(".glb"):
		path += ".glb"

	var keep: bool = _keep_world.button_pressed

	# 合并成 1 个文件
	if not _split.button_pressed:
		var res := GlbExport.export_nodes(_nodes, path, keep)
		if not res.get("ok", false):
			_status.text = "导出失败：" + str(res.get("message", "未知错误"))
			return
		var out := String(res["path"])
		_refresh(out)
		_status.text = str(res["message"])
		return

	# 每个节点单独一个文件
	var dir := path.get_base_dir()          # 注意是 get_base_dir()，没有 get_base_path()
	var stem := path.get_file().get_basename()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var done := 0
	var failed := 0
	var last := ""
	for n in _nodes:
		var one := "%s/%s_%s.glb" % [dir, stem, GlbExport.safe_name(String((n as Node).name))]
		var r := GlbExport.export_nodes([n], one, keep)
		if bool(r.get("ok", false)):
			done += 1
			last = one
			_refresh(one)
		else:
			failed += 1
	_status.text = ("拆分导出：成功 %d 个 / 失败 %d 个%s"
			% [done, failed, ("，例如 " + last) if not last.is_empty() else ""])


## 写到 res:// 下时刷新文件系统，让新文件立刻出现在面板/导入队列里
func _refresh(path: String) -> void:
	if not path.begins_with("res://"):
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(path)
		fs.scan()

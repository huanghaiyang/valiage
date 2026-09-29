@tool
extends ConfirmationDialog
## Blender 路径设置窗口。
##
## 尺寸经验（踩过两次）：
##   * 窗口要**宽而矮**：860×230，状态文字不换行（autowrap 的 Label 在宽度未确定时
##     算出的最小高度会爆炸，把窗口撑得老高，保存按钮都够不着）
##   * 窗口底色写死灰色、文字写死浅灰：插件窗口不继承编辑器主题，光靠主题盖不住那层蓝底
##   * 内容容器**不要** set_anchors_preset(PRESET_FULL_RECT)：那会让它顶满整个窗口

const Blender := preload("res://addons/blender_bridge/blender.gd")

const BG_GRAY := Color(0.157, 0.157, 0.165)
const TEXT_COLOR := Color(0.86, 0.86, 0.88)

var _edit: LineEdit
var _status: Label
var _picker: EditorFileDialog


func _init() -> void:
	title = "Blender 路径设置"
	ok_button_text = "保存"
	dialog_hide_on_ok = false             # 保存后留着，好看检测结果
	confirmed.connect(_on_save)
	size = Vector2i(860, 230)
	min_size = Vector2i(680, 190)
	var ed := EditorInterface.get_editor_theme()
	if ed != null:
		theme = ed

	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG_GRAY
	sb.set_corner_radius_all(3)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	var tip := Label.new()
	tip.text = "Blender 可执行文件（blender.exe）："
	vb.add_child(tip)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_edit = LineEdit.new()
	_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit.placeholder_text = "留空则自动探测"
	row.add_child(_edit)
	var browse := Button.new()
	browse.text = "浏览…"
	browse.pressed.connect(_on_browse)
	row.add_child(browse)
	var detect := Button.new()
	detect.text = "自动检测"
	detect.pressed.connect(_on_detect)
	row.add_child(detect)
	vb.add_child(row)

	_status = Label.new()
	_status.clip_text = true              # 不换行：靠"宽窗口"容纳长路径，而不是靠换行撑高
	vb.add_child(_status)

	_paint_text(panel)
	setup()


func setup() -> void:
	var saved := Blender.get_saved_path()
	var found := Blender.find_blender()
	_edit.text = saved if not saved.is_empty() else found
	if found.is_empty():
		_status.text = "没自动找到 Blender —— 请点「浏览…」手动指定 blender.exe"
	else:
		_status.text = "检测到：%s" % found


## 供外部（比如右键打开失败时）写入一句提示
func set_message(msg: String) -> void:
	if _status != null:
		_status.text = msg


func _on_detect() -> void:
	var found := Blender.find_blender()
	if found.is_empty():
		_status.text = "没找到。请手动指定 blender.exe（通常在 C:/Program Files/Blender Foundation/…）"
		return
	_edit.text = found
	_status.text = "检测到：%s" % found


func _on_browse() -> void:
	if _picker == null:
		_picker = EditorFileDialog.new()
		_picker.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_picker.access = EditorFileDialog.ACCESS_FILESYSTEM
		_picker.add_filter("*.exe", "blender.exe")
		_picker.file_selected.connect(func(p: String) -> void: _edit.text = p)
		add_child(_picker)
	_picker.popup_centered_ratio(0.6)


func _on_save() -> void:
	var p := _edit.text.strip_edges()
	Blender.save_path(p)
	if p.is_empty():
		_status.text = "已清空设置，之后会走自动探测"
		return
	if not FileAccess.file_exists(p):
		_status.text = "已保存，但这个文件不存在：%s" % p
		return
	_status.text = "已保存：%s" % p


## 递归把 Label 文字色写死，免得主题给深色字配灰底看不清
func _paint_text(node: Node) -> void:
	if node is Label:
		(node as Label).add_theme_color_override("font_color", TEXT_COLOR)
	for c in node.get_children():
		_paint_text(c)

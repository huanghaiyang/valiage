@tool
extends ConfirmationDialog
## EXR → PNG 的选项窗口。
## 尺寸经验：窗口要"宽而矮"，状态文字不换行（autowrap 的 Label 最小高度会爆炸，踩过）。

const ExrConvert := preload("res://addons/exr_tools/exr_convert.gd")

const BG_GRAY := Color(0.157, 0.157, 0.165)
const TEXT_COLOR := Color(0.86, 0.86, 0.88)

var _dir := ""
var _recursive: CheckBox
var _flip: CheckBox
var _del: CheckBox
var _status: Label
var _out_edit: LineEdit
var _out_dialog: EditorFileDialog = null
var _result_text := ""
var _pending_res := PackedStringArray()   ## 本次生成、待在编辑器里确认可加载的资源


func _init() -> void:
	title = "EXR 转 PNG"
	ok_button_text = "开始转换"
	dialog_hide_on_ok = false
	confirmed.connect(_run)
	size = Vector2i(760, 250)
	min_size = Vector2i(560, 210)
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

	_recursive = CheckBox.new()
	_recursive.text = "包含子目录"
	_recursive.button_pressed = true
	vb.add_child(_recursive)

	_flip = CheckBox.new()
	_flip.text = "翻转绿通道（DirectX -Y 转 OpenGL +Y）"
	vb.add_child(_flip)

	var ro := HBoxContainer.new()
	vb.add_child(ro)
	var lo := Label.new(); lo.text = "输出到"; lo.clip_text = true
	ro.add_child(lo)
	_out_edit = LineEdit.new()
	_out_edit.editable = false                    # 不让人手打路径
	_out_edit.placeholder_text = "（原目录旁边）"
	_out_edit.tooltip_text = "留空 = 转成 PNG 放在原 EXR 旁边；或点右边按钮指定目录"
	_out_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ro.add_child(_out_edit)
	var b_out := Button.new(); b_out.text = "选择输出目录…"
	b_out.pressed.connect(_pick_out_dir)
	ro.add_child(b_out)
	var b_clr := Button.new(); b_clr.text = "清除"
	b_clr.pressed.connect(func(): _out_edit.text = "")
	ro.add_child(b_clr)

	_del = CheckBox.new()
	_del.text = "成功后把原 EXR 移入回收站 .runtime（可还原，不是删除）"
	vb.add_child(_del)

	_status = Label.new()
	_status.clip_text = true
	vb.add_child(_status)

	_paint(panel)


func set_target(dir: String) -> void:
	_dir = dir
	if _status != null:
		_status.text = "目标目录：%s" % dir


func _paint(n: Node) -> void:
	if n is Label:
		(n as Label).add_theme_color_override("font_color", TEXT_COLOR)
	for c in n.get_children():
		_paint(c)


func _run() -> void:
	if _dir.is_empty():
		_status.text = "没有选中目录"
		return
	# **异步**：整个批量丢进后台线程（4K 图走 Blender 时每张约 6 秒，同步会卡住编辑器）。
	# 线程里只做纯转换；文件系统通知必须在主线程做，所以放到 _finish_batch。
	_progress = {"total": 0, "done": 0, "current": ""}
	_thread = Thread.new()
	_thread.start(_worker.bind(_dir, _options(), _progress))
	get_ok_button().disabled = true
	set_process(true)
	_status.text = "转换中…（后台线程，编辑器不会卡）"


## 本次转换的选项（输出位置 + 是否回收原 EXR）
func _options() -> Dictionary:
	return {
		"recursive": _recursive.button_pressed,
		"flip_green": _flip.button_pressed,
		"delete_source": false,
		"recycle_source": _del.button_pressed,
		"out_dir": _out_edit.text.strip_edges(),
	}

func _pick_out_dir() -> void:
	if _out_dialog == null or not is_instance_valid(_out_dialog):
		_out_dialog = EditorFileDialog.new()
		_out_dialog.title = "选择 PNG 输出目录"
		_out_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_out_dialog.access = FileDialog.ACCESS_RESOURCES
		_out_dialog.current_dir = "res://"
		_out_dialog.dir_selected.connect(func(d): _out_edit.text = d)
		add_child(_out_dialog)
	_out_dialog.popup_centered_ratio(0.6)


func _notify_editor(paths: Array) -> int:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null or not fs.has_method("update_file"):
		return 0
	var n := 0
	for p in paths:
		var abs := String(p)
		if not FileAccess.file_exists(abs):
			continue
		var res_path := abs
		if not abs.begins_with("res://"):
			res_path = ProjectSettings.localize_path(abs)
		if res_path.begins_with("res://"):
			fs.update_file(res_path)          # 标记该文件需要 (重新) 导入
			_pending_res.append(res_path)
			n += 1
	return n

## 通知之后必须**确认真的被导入了**：新文件的导入是异步的，立刻查会误判成"没通知成功"。
## 所以等一会儿再查；还没被识别就退回整树 scan（慢但可靠），最后如实汇报结果。
func _verify_imported() -> void:
	if _pending_res.is_empty():
		return
	# 关键：Godot 的导入是**异步**的 —— scan()/update_file() 只是"开始导入"，
	# 资源要若干帧之后才可用。所以必须**轮询等待**，不能查一次就下结论
	# （上一版就是查一次就汇报"已通知导入"，用户一用就发现其实没载入）。
	var deadline := 20.0
	var waited := 0.0
	var scanned := false
	while waited < deadline:
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if not scanned and waited >= 2.0:
			# 兜底：整树扫描。注意必须**单飞** ——
			# Godot 的 scan() 不会让 is_scanning() 变真，叠加多次扫描会互相打架
			# （godot_ai 插件里对此有专门注释与单飞处理）。
			var fs := EditorInterface.get_resource_filesystem()
			if not fs.is_scanning():
				fs.scan()
			scanned = true
		if _missing_resources().is_empty():
			var n := _pending_res.size()
			_pending_res = PackedStringArray()
			_status.text = "%s\n导入确认：%d 个全部可加载 ✓（等待 %.1f 秒）" % [_result_text, n, waited]
			return
	var left := _missing_resources()
	_pending_res = PackedStringArray()
	if left.is_empty():
		_status.text = "%s\n导入确认：全部可加载 ✓" % _result_text
	else:
		_status.text = "%s\n仍有 %d 个未识别：%s\n（可在文件系统面板右键「重新导入」）" % [
				_result_text, left.size(), ", ".join(left)]


## 还没被编辑器认出来的资源（可直接调用/断言）
func _missing_resources() -> PackedStringArray:
	var out := PackedStringArray()
	for p in _pending_res:
		if not ResourceLoader.exists(p):
			out.append(p)
	return out

# ------------------------------------------------------------------ 异步执行

var _thread: Thread = null
var _progress := {}


## 后台线程里跑的东西：**只允许纯转换**，绝不能碰编辑器 API（文件系统/场景树）
func _worker(dir: String, opts: Dictionary, progress: Dictionary) -> Dictionary:
	return ExrConvert.convert_dir(dir, opts, progress)


func _process(_delta: float) -> void:
	if _thread == null:
		set_process(false)
		return
	var total := int(_progress.get("total", 0))
	var done := int(_progress.get("done", 0))
	if total > 0:
		_status.text = "转换中… %d/%d ｜ 当前：%s" % [done, total, str(_progress.get("current", ""))]
	if _thread.is_alive():
		return
	var r: Dictionary = _thread.wait_to_finish()
	_thread = null
	set_process(false)
	get_ok_button().disabled = false
	_finish_batch(r)


## 线程结束后回到主线程收尾：通知编辑器导入 + 汇报结果
func _finish_batch(r: Dictionary) -> void:
	var failed: Array = r.get("failed", [])
	var created: Array = r.get("created", [])
	var notified := _notify_editor(created)
	var names := PackedStringArray()
	for c in created:
		names.append(String(c).get_file())
	_result_text = "共 %d 个 EXR ｜ 成功 %d ｜ 失败 %d ｜ 已登记 %d 个待导入" % [
			int(r.get("total", 0)), int(r.get("ok", 0)), failed.size(), notified]
	if not names.is_empty():
		_result_text += "\n已生成：%s" % ", ".join(names)
	_status.text = _result_text
	_verify_imported()                      # 异步确认导入结果（轮询，不阻塞）


## 关窗口时别把线程丢下（否则会报 "Thread must be disposed"）
func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null

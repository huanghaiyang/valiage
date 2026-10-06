@tool
extends ConfirmationDialog
## 图片转换选项 + 执行。
## 「一键生成 2K+1K」= 直接把 4K 贴图批量生成 _2k / _1k 两套，
## 命名与画质分级系统一致，生成后切档立刻生效。

const ImageConv := preload("res://addons/image_convert/image_convert.gd")

const BG_GRAY := Color(0.157, 0.157, 0.165)
const TEXT_COLOR := Color(0.86, 0.86, 0.88)

var _dir := ""
var _single := false
var _fmt: OptionButton
var _res: OptionButton
var _variants: CheckBox
var _strip: CheckBox
var _recursive: CheckBox
var _out_edit: LineEdit
var _out_dialog: EditorFileDialog = null
var _status: Label
var _thread: Thread = null
var _progress := {}
var _result_text := ""


func _init() -> void:
	title = "图片转换"
	ok_button_text = "开始转换"
	dialog_hide_on_ok = false
	confirmed.connect(_run)
	size = Vector2i(780, 380)
	min_size = Vector2i(620, 320)
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
		margin.add_theme_constant_override("margin_" + side, 12)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	margin.add_child(vb)

	var r1 := HBoxContainer.new(); vb.add_child(r1)
	var l1 := Label.new(); l1.text = "目标格式"; l1.clip_text = true; r1.add_child(l1)
	_fmt = OptionButton.new()
	for pair in [[ImageConv.FMT_KEEP, "保持原格式"], [ImageConv.FMT_PNG, "PNG"], [ImageConv.FMT_JPG, "JPG"], [ImageConv.FMT_WEBP, "WebP"]]:
		_fmt.add_item(String(pair[1]), int(pair[0]))
	r1.add_child(_fmt)
	var l2 := Label.new(); l2.text = "   分辨率"; l2.clip_text = true; r1.add_child(l2)
	_res = OptionButton.new()
	# ★「自动尺寸」= 不统一强制尺寸 ✓：
	#   · 普通转换：保持原尺寸（max_size = 0 ✓）
	#   · 勾了「一键生成 2K+1K」：每个变体用自己的目标尺寸（_2k→2048 ✓ / _1k→1024 ✓）
	for pair in [[0, "自动尺寸"], [4096, "4096"], [2048, "2048"], [1024, "1024"], [512, "512"]]:
		_res.add_item(String(pair[1]), int(pair[0]))
	r1.add_child(_res)

	var r2 := HBoxContainer.new(); vb.add_child(r2)
	_variants = CheckBox.new()
	_variants.text = "一键生成 2K + 1K 两套（4K 源 → _2k/_1k，配画质分级）"
	_variants.tooltip_text = "勾上后忽略上面两项，直接对每个图片生成 _2k 与 _1k 两份"
	r2.add_child(_variants)

	var r3 := HBoxContainer.new(); vb.add_child(r3)
	_strip = CheckBox.new()
	_strip.text = "移除 alpha（转成 RGB —— Terrain3D 多图层必须格式一致）"
	_strip.button_pressed = true
	r3.add_child(_strip)
	_recursive = CheckBox.new()
	_recursive.text = "含子目录"
	r3.add_child(_recursive)

	var r4 := HBoxContainer.new(); vb.add_child(r4)
	var l4 := Label.new(); l4.text = "输出到"; l4.clip_text = true; r4.add_child(l4)
	_out_edit = LineEdit.new()
	_out_edit.editable = false
	_out_edit.placeholder_text = "（同级目录）"
	_out_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r4.add_child(_out_edit)
	var b_out := Button.new(); b_out.text = "选择输出目录…"
	b_out.pressed.connect(_pick_out_dir)
	r4.add_child(b_out)
	var b_clr := Button.new(); b_clr.text = "清除"
	b_clr.pressed.connect(func(): _out_edit.text = "")
	r4.add_child(b_clr)

	_status = Label.new()
	_status.clip_text = true
	_status.text = "目标：（未选择）"
	vb.add_child(_status)
	_paint(panel)


## ★ 右键选中的具体文件（空 = 按目录模式 ✓）
var _files: PackedStringArray = PackedStringArray()


func set_target(dir_abs: String, single_file: bool, files: PackedStringArray = PackedStringArray()) -> void:
	_dir = dir_abs
	_single = single_file
	_files = files
	_recursive.button_pressed = not single_file and _files.is_empty()
	if not _files.is_empty():
		_status.text = "目标：选中的 %d 个文件" % _files.size()
	else:
		_status.text = "目标：%s（%s）" % [dir_abs, "单文件" if single_file else "整个目录"]


func _paint(n: Node) -> void:
	if n is Label:
		(n as Label).add_theme_color_override("font_color", TEXT_COLOR)
	for c in n.get_children():
		_paint(c)


func _pick_out_dir() -> void:
	if _out_dialog == null or not is_instance_valid(_out_dialog):
		_out_dialog = EditorFileDialog.new()
		_out_dialog.title = "选择输出目录"
		_out_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_out_dialog.access = FileDialog.ACCESS_RESOURCES
		_out_dialog.current_dir = "res://"
		_out_dialog.dir_selected.connect(func(d): _out_edit.text = d)
		add_child(_out_dialog)
	_out_dialog.popup_centered_ratio(0.6)


func _options() -> Dictionary:
	return {
		"fmt": _fmt.get_selected_id(),
		"max_size": int(_res.get_selected_id()),
		"strip_alpha": _strip.button_pressed,
		"recursive": _recursive.button_pressed,
		"out_dir": _out_edit.text.strip_edges(),
		"variants": _variants.button_pressed,
		# ★ 传给后台线程：有具体文件就只转这些 ✓（没有则按目录 ✓）
		"files": Array(_files),
	}


func _run() -> void:
	if _dir.is_empty():
		_status.text = "没有选中目录"
		return
	_progress = {"total": 0, "done": 0, "current": ""}
	_thread = Thread.new()
	_thread.start(_worker.bind(_dir, _options(), _progress))
	get_ok_button().disabled = true
	set_process(true)
	_status.text = "转换中…（后台线程）"


## 后台线程：只做纯转换，绝不能碰编辑器 API
func _worker(dir_abs: String, opts: Dictionary, progress: Dictionary) -> Dictionary:
	if bool(opts.get("variants", false)):
		return _worker_variants(dir_abs, opts, progress)
	return ImageConv.convert_dir(dir_abs, opts, progress)


## 「一键生成 2K+1K」：对每个图片生成 _2k / _1k 两份（命名与画质系统一致）
func _worker_variants(dir_abs: String, opts: Dictionary, progress: Dictionary) -> Dictionary:
	# ★ 需求①②：有"具体选中的文件"就只转这些 ✓（不扫整个目录 ✗）
	var files: Array = []
	if opts.has("files"):
		for f in (opts["files"] as Array):
			if ImageConv.is_image(String(f)):
				files.append(String(f))
	else:
		files = ImageConv.find_images(dir_abs, bool(opts.get("recursive", false)))
	var lines := PackedStringArray()
	var created: Array = []
	var ok := 0
	var failed: Array = []
	if not progress.is_empty():
		progress["total"] = files.size() * 2
		progress["done"] = 0
	for f in files:
		if not progress.is_empty():
			progress["current"] = String(f).get_file()
		# ★ 地面/地形贴图**也允许改尺寸** ✓（用户确认 ✓）
		#   注意：Terrain3D 的多图层要求**整套尺寸与格式一致** ✓
		#   → 对地表贴图请**同一批一起生成**（例如整目录一起出 2k/1k ✓），不要只做一半 ✓
		for plan in ImageConv.plan_variants(String(f), ["2k", "1k"], int(opts.get("fmt", ImageConv.FMT_KEEP))):
			var p: Dictionary = plan
			var o := opts.duplicate()
			o["fmt"] = int(opts.get("fmt", ImageConv.FMT_KEEP))
			# ★ 必须把**本变体的目标尺寸**传下去 ✗
			#   否则 convert_file() 会按 opts.max_size（对话框「保持原样」= 0 ✗）处理 → 完全没缩放 ✗
			#   表现就是 "_2k 与 _1k 体积一模一样（都等于原图分辨率）" ✓（实测 bug ✓）
			match String(p.get("suffix", "")):
				"4k":
					o["max_size"] = 4096
				"2k":
					o["max_size"] = 2048
				"1k":
					o["max_size"] = 1024
				"512":
					o["max_size"] = 512
				"256":
					o["max_size"] = 256
			var r := ImageConv.convert_file(String(p["src"]), String(p["dst"]), o)
			if bool(r.get("ok", false)):
				ok += 1
				created.append(p["dst"])
				lines.append("✓ %s" % String(p["dst"]).get_file())
			else:
				failed.append(p["dst"])
				lines.append("✗ %s ｜ %s" % [String(p["dst"]).get_file(), str(r.get("message", ""))])
			if not progress.is_empty():
				progress["done"] = int(progress.get("done", 0)) + 1
	return {"total": files.size() * 2, "ok": ok, "failed": failed, "lines": lines, "created": created}


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
	_finish(r)


func _finish(r: Dictionary) -> void:
	var created: Array = r.get("created", [])
	var failed: Array = r.get("failed", [])
	# 通知编辑器导入新图片（单文件刷新，比整树扫描快得多）
	var fs := EditorInterface.get_resource_filesystem()
	var notified := 0
	for c in created:
		var rel := ProjectSettings.localize_path(String(c))
		if fs != null and rel.begins_with("res://") and fs.has_method("update_file"):
			fs.call("update_file", rel)
			notified += 1
	_result_text = "共 %d ｜ 成功 %d ｜ 失败 %d ｜ 已登记导入 %d" % [
			int(r.get("total", 0)), int(r.get("ok", 0)), failed.size(), notified]
	_status.text = _result_text
	for line in (r.get("lines", []) as Array):
		print("[图片转换] %s" % str(line))


func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
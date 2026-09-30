@tool
extends VBoxContainer
## 图片清单面板：扫描 → 列出 → 手动/批量重新导入。
##
## 布局经验（踩过的坑）：
##   * 不用 autowrap 的 Label（最小高度会爆）→ 一律 clip_text
##   * Tree 的勾选列用 CELL_MODE_CHECK（会触发 item_edited）；
##     图标列（CELL_MODE_ICON）不会触发，别用错
##   * set_cell_mode 会清掉该列文本 → 先设 mode 再设 text
##   * connect() 的实参若是数组元素（Variant），必须显式 as Callable

const Scan := preload("res://addons/image_tools/image_scan.gd")

const COL_CHECK := 0
const COL_PATH := 1
const COL_SIZE := 2
const COL_MODE := 3
const COL_MIP := 4
const COL_STATE := 5

var _root_edit: LineEdit
var _recursive: CheckBox
var _ext_edit: LineEdit
var _dir_dialog: EditorFileDialog = null
var _only_bad: CheckBox
var _tree: Tree
var _stat: Label
var _status: Label
var _rows: Array = []          ## 本次扫描结果（与 Tree 顺序一致）


func _init() -> void:
	name = "图片清单"
	add_theme_constant_override("separation", 6)

	var r1 := HBoxContainer.new()
	add_child(r1)
	var l1 := Label.new(); l1.text = "根目录"; l1.clip_text = true
	r1.add_child(l1)
	_root_edit = LineEdit.new()
	_root_edit.text = "res://assets"
	_root_edit.editable = false              # 只做显示，不让人手打路径
	_root_edit.tooltip_text = "当前扫描的目录（用右边的按钮选）"
	_root_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r1.add_child(_root_edit)
	var pick_btn := Button.new()
	pick_btn.text = "选择目录…"
	pick_btn.tooltip_text = "用文件选择器挑目录，不用手打路径"
	pick_btn.pressed.connect(_pick_dir)
	r1.add_child(pick_btn)
	_recursive = CheckBox.new(); _recursive.text = "含子目录"; _recursive.button_pressed = true
	r1.add_child(_recursive)
	var scan_btn := Button.new(); scan_btn.text = "扫描"
	scan_btn.pressed.connect(_on_scan)
	r1.add_child(scan_btn)

	var rf := HBoxContainer.new()
	add_child(rf)
	var lf := Label.new(); lf.text = "格式过滤"; lf.clip_text = true
	rf.add_child(lf)
	_ext_edit = LineEdit.new()
	_ext_edit.text = ",".join(PackedStringArray(Scan.DEFAULT_EXT))      # 默认 png,jpg,jpeg,webp —— 不含 exr
	_ext_edit.tooltip_text = "只处理这里列出的扩展名（逗号分隔）。留空则用默认值。" \
			+ " 需要 exr 之类时手动加进来。"
	_ext_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rf.add_child(_ext_edit)

	var r2 := HBoxContainer.new()
	add_child(r2)
	# 注意：数组元素是 Variant，直接塞给 connect(Callable) 会解析报错 —— 必须显式 as Callable
	for spec: Array in [["全选", _on_select_all], ["全不选", _on_select_none], ["反选", _on_invert]]:
		var b := Button.new()
		b.text = String(spec[0])
		b.pressed.connect(spec[1] as Callable)
		r2.add_child(b)
	_only_bad = CheckBox.new()
	_only_bad.text = "只看待处理（非 VRAM 压缩 / 无 mipmaps / 未导入）"
	_only_bad.toggled.connect(func(_v): _populate())
	r2.add_child(_only_bad)
	_stat = Label.new(); _stat.clip_text = true
	r2.add_child(_stat)

	_tree = Tree.new()
	_tree.columns = 6
	_tree.column_titles_visible = true
	_tree.set_column_title(COL_CHECK, "选")
	_tree.set_column_title(COL_PATH, "路径")
	_tree.set_column_title(COL_SIZE, "大小")
	_tree.set_column_title(COL_MODE, "导入模式")
	_tree.set_column_title(COL_MIP, "Mipmaps")
	_tree.set_column_title(COL_STATE, "状态")
	_tree.set_column_custom_minimum_width(COL_CHECK, 40)
	_tree.set_column_expand(COL_CHECK, false)
	_tree.set_column_expand(COL_PATH, true)
	_tree.set_column_custom_minimum_width(COL_SIZE, 90)
	_tree.set_column_custom_minimum_width(COL_MODE, 130)
	_tree.set_column_custom_minimum_width(COL_MIP, 90)
	_tree.set_column_custom_minimum_width(COL_STATE, 90)
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_edited.connect(_on_item_edited)
	add_child(_tree)

	var r3 := HBoxContainer.new()
	add_child(r3)
	var b_sel := Button.new(); b_sel.text = "重新导入所选"
	b_sel.pressed.connect(func(): _do_reimport(_selected_paths()))
	r3.add_child(b_sel)
	var b_all := Button.new(); b_all.text = "重新导入全部"
	b_all.pressed.connect(func(): _do_reimport(_all_paths()))
	r3.add_child(b_all)
	var b_scan := Button.new(); b_scan.text = "强制扫描文件系统"
	b_scan.tooltip_text = "整树扫描（慢）；只在重新导入没生效时用"
	b_scan.pressed.connect(_on_force_scan)
	r3.add_child(b_scan)

	_status = Label.new()
	_status.clip_text = true
	_status.text = "点「扫描」列出 assets 下的图片"
	add_child(_status)


# ------------------------------------------------------------------ 扫描与填充

## 打开目录选择器（只在第一次创建，之后复用）
func _pick_dir() -> void:
	if _dir_dialog == null or not is_instance_valid(_dir_dialog):
		_dir_dialog = EditorFileDialog.new()
		_dir_dialog.title = "选择要扫描的目录"
		_dir_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_dir_dialog.access = FileDialog.ACCESS_RESOURCES      # 只让选 res:// 内的目录
		_dir_dialog.current_dir = _root_edit.text if _root_edit.text != "" else "res://"
		_dir_dialog.dir_selected.connect(_on_dir_picked)
		add_child(_dir_dialog)
	_dir_dialog.popup_centered_ratio(0.6)


func _on_dir_picked(dir: String) -> void:
	if dir.strip_edges() == "":
		return
	_root_edit.text = dir
	_on_scan()                                  # 选完立刻扫，少点一次


func _on_scan() -> void:
	var allow: Array = Scan.parse_filter(_ext_edit.text)
	if allow.is_empty():
		allow = Scan.DEFAULT_EXT
	_rows = Scan.scan(_root_edit.text.strip_edges(), _recursive.button_pressed, allow)
	_populate()
	_status.text = "扫描完成：共 %d 个文件 ｜ 格式 %s ｜ 根目录 %s" % [
			_rows.size(), ",".join(PackedStringArray(allow)), _root_edit.text]


func _populate() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var only_bad := _only_bad != null and _only_bad.button_pressed
	var shown := 0
	var bad := 0
	for row_v in _rows:
		var row: Dictionary = row_v
		var is_bad := int(row["mode"]) != 2 or not bool(row["mipmaps"]) or not bool(row["imported"])
		if is_bad:
			bad += 1
		if only_bad and not is_bad:
			continue
		var it := _tree.create_item(root)
		it.set_cell_mode(COL_CHECK, TreeItem.CELL_MODE_CHECK)
		it.set_editable(COL_CHECK, true)
		it.set_text(COL_CHECK, "")            # 必须在 set_cell_mode 之后
		it.set_checked(COL_CHECK, false)
		it.set_text(COL_PATH, String(row["path"]))
		it.set_text(COL_SIZE, Scan.human_size(int(row["size"])))
		it.set_text(COL_MODE, String(row["mode_name"]))
		it.set_text(COL_MIP, "有" if bool(row["mipmaps"]) else "无")
		it.set_text(COL_STATE, "已导入" if bool(row["imported"]) else "未导入")
		it.set_tooltip_text(COL_PATH, String(row["path"]))
		it.set_metadata(COL_PATH, String(row["path"]))
		shown += 1
	_stat.text = "显示 %d / 共 %d ｜ 待处理 %d" % [shown, _rows.size(), bad]


func _on_item_edited() -> void:
	var it := _tree.get_edited()
	if it != null and _tree.get_edited_column() == COL_CHECK:
		pass   # 勾选状态由 Tree 自己维护；这里只在需要时联动其它逻辑


# ------------------------------------------------------------------ 选择

func _selected_paths() -> PackedStringArray:
	var out := PackedStringArray()
	var it := _tree.get_root().get_first_child()
	while it != null:
		if it.is_checked(COL_CHECK):
			out.append(String(it.get_metadata(COL_PATH)))
		it = it.get_next()
	return out


func _all_paths() -> PackedStringArray:
	var out := PackedStringArray()
	var it := _tree.get_root().get_first_child()
	while it != null:
		out.append(String(it.get_metadata(COL_PATH)))
		it = it.get_next()
	return out


func _on_select_all() -> void:
	_set_all_checked(true)


func _on_select_none() -> void:
	_set_all_checked(false)


func _on_invert() -> void:
	var it := _tree.get_root().get_first_child()
	while it != null:
		it.set_checked(COL_CHECK, not it.is_checked(COL_CHECK))
		it = it.get_next()


func _set_all_checked(on: bool) -> void:
	var it := _tree.get_root().get_first_child()
	while it != null:
		it.set_checked(COL_CHECK, on)
		it = it.get_next()


# ------------------------------------------------------------------ 重新导入

## 触发重新导入。优先用 reimport_files（4.x 的正式 API），失败再退到 update_file。
func _do_reimport(paths: PackedStringArray) -> void:
	if paths.is_empty():
		_status.text = "没有选中任何文件"
		return
	var r := reimport(paths)
	_status.text = "已提交重新导入 %d 个（通道：%s）。导入是异步的，稍等再看文件系统。" % [
			int(r["queued"]), String(r["via"])]


static func reimport(paths: PackedStringArray) -> Dictionary:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return {"queued": 0, "via": "无文件系统"}
	if fs.has_method("reimport_files"):
		fs.call("reimport_files", paths)
		return {"queued": paths.size(), "via": "reimport_files"}
	var n := 0
	if fs.has_method("update_file"):
		for p in paths:
			fs.call("update_file", p)
			n += 1
	return {"queued": n, "via": "update_file"}


func _on_force_scan() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	# scan() 不会让 is_scanning() 变真 —— 必须单飞，叠加扫描会互相打架
	if fs.is_scanning():
		_status.text = "已有扫描在进行中，等它结束"
		return
	fs.scan()
	_status.text = "已触发整树扫描（会重建导入缓存，可能较慢）"
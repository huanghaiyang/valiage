@tool
extends VBoxContainer
## EXR 管理器
##   · 列出 .runtime/exr_recycle 里回收的 EXR（转换后被"扔进 .runtime"的那些）
##   · 支持 还原 / 彻底删除（真正删除前会二次确认）
##   · 支持把任意 EXR 转换到**指定目录**
##
## 为什么回收站放在 .runtime：点开头的目录 Godot 完全忽略，
## 所以回收进去的 EXR 不会被导入、也不会生成缩略图（顺带避免拖慢启动）。

const ExrConvert := preload("res://addons/exr_tools/exr_convert.gd")

const COL_NAME := 0
const COL_FROM := 1
const COL_SIZE := 2
const COL_TS := 3

var _tree: Tree
var _status: Label
var _rows: Array = []
var _confirm_purge: ConfirmationDialog
var _confirm_purge_all: ConfirmationDialog
var _open_dialog: EditorFileDialog = null
var _out_dialog: EditorFileDialog = null
var _picked_exr := ""
var _src_dialog: EditorFileDialog = null
var _batch_out_dialog: EditorFileDialog = null
var _confirm_batch: ConfirmationDialog
var _pending_src := ""


func _init() -> void:
	name = "EXR 管理器"
	add_theme_constant_override("separation", 6)

	var r1 := HBoxContainer.new()
	add_child(r1)
	var l1 := Label.new()
	l1.text = "回收站 .runtime/exr_recycle"
	l1.clip_text = true
	r1.add_child(l1)
	var b_refresh := Button.new(); b_refresh.text = "刷新"
	b_refresh.pressed.connect(refresh)
	r1.add_child(b_refresh)
	var b_open := Button.new(); b_open.text = "打开目录"
	b_open.pressed.connect(func(): OS.shell_open(ExrConvert.recycle_dir_abs()))
	r1.add_child(b_open)
	var b_conv := Button.new(); b_conv.text = "转换单个 EXR…"
	b_conv.tooltip_text = "挑一个 EXR（单选），再挑输出目录 → 只转这一个"
	b_conv.pressed.connect(_pick_exr)
	r1.add_child(b_conv)
	var b_batch := Button.new(); b_batch.text = "转换整个目录…"
	b_batch.tooltip_text = "挑一个源目录（含子目录），再挑输出目录 → 转换该目录下**全部** EXR（会先告诉你有几个）"
	b_batch.pressed.connect(_pick_src_dir)
	r1.add_child(b_batch)

	_tree = Tree.new()
	_tree.columns = 4
	_tree.column_titles_visible = true
	_tree.set_column_title(COL_NAME, "文件（回收站内）")
	_tree.set_column_title(COL_FROM, "原始位置")
	_tree.set_column_title(COL_SIZE, "大小")
	_tree.set_column_title(COL_TS, "回收时间")
	_tree.set_column_expand(COL_NAME, true)
	_tree.set_column_expand(COL_FROM, true)
	_tree.set_column_custom_minimum_width(COL_SIZE, 90)
	_tree.set_column_custom_minimum_width(COL_TS, 150)
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tree)

	var r2 := HBoxContainer.new()
	add_child(r2)
	var b_restore := Button.new(); b_restore.text = "还原所选"
	b_restore.tooltip_text = "把选中的 EXR 放回它原来的位置"
	b_restore.pressed.connect(_restore_selected)
	r2.add_child(b_restore)
	var b_restore_all := Button.new(); b_restore_all.text = "还原全部"
	b_restore_all.pressed.connect(_restore_all)
	r2.add_child(b_restore_all)
	var b_purge := Button.new(); b_purge.text = "彻底删除所选"
	b_purge.tooltip_text = "真正删除（不可恢复），会先确认"
	b_purge.pressed.connect(_ask_purge_selected)
	r2.add_child(b_purge)
	var b_purge_all := Button.new(); b_purge_all.text = "清空回收站"
	b_purge_all.pressed.connect(_ask_purge_all)
	r2.add_child(b_purge_all)

	_status = Label.new()
	_status.clip_text = true
	_status.text = "点「刷新」列出回收站里的 EXR"
	add_child(_status)

	_confirm_purge = ConfirmationDialog.new()
	_confirm_purge.title = "彻底删除"
	_confirm_purge.dialog_text = "删除后无法恢复，确定吗？"
	_confirm_purge.confirmed.connect(_purge_selected)
	add_child(_confirm_purge)

	_confirm_purge_all = ConfirmationDialog.new()
	_confirm_purge_all.title = "清空回收站"
	_confirm_purge_all.dialog_text = "将彻底删除回收站里的全部 EXR，无法恢复，确定吗？"
	_confirm_purge_all.confirmed.connect(_purge_all)
	add_child(_confirm_purge_all)

	_confirm_batch = ConfirmationDialog.new()
	_confirm_batch.title = "批量转换"
	_confirm_batch.ok_button_text = "选择输出目录…"
	_confirm_batch.confirmed.connect(_pick_batch_out)
	add_child(_confirm_batch)


# ------------------------------------------------------------------ 列表

func refresh() -> void:
	_rows = ExrConvert.list_recycled()
	_tree.clear()
	var root := _tree.create_item()
	for rv in _rows:
		var e: Dictionary = rv
		var it := _tree.create_item(root)
		it.set_text(COL_NAME, String(e.get("name", "")))
		it.set_text(COL_FROM, String(e.get("from", "")))
		it.set_text(COL_SIZE, ExrConvert.human_size(int(e.get("size", 0))))
		it.set_text(COL_TS, String(e.get("ts", "")))
		it.set_tooltip_text(COL_NAME, String(e.get("to", "")))
		it.set_metadata(COL_NAME, int(_rows.find(rv)))
	_status.text = "回收站共 %d 个 EXR ｜ 合计 %s" % [
			_rows.size(), ExrConvert.human_size(ExrConvert.recycle_usage())]


func _selected_indices() -> Array:
	var out: Array = []
	var it := _tree.get_root().get_first_child()
	while it != null:
		if it.is_selected(COL_NAME):
			out.append(int(it.get_metadata(COL_NAME)))
		it = it.get_next()
	return out


func _all_indices() -> Array:
	var out: Array = []
	for i in _rows.size():
		out.append(i)
	return out


# ------------------------------------------------------------------ 还原 / 删除

func _restore_selected() -> void:
	var idx := _selected_indices()
	if idx.is_empty():
		_status.text = "没选中任何条目"
		return
	var okn := 0
	for i in idx:
		var r: Dictionary = ExrConvert.restore(_rows[i])
		if bool(r.get("ok", false)):
			okn += 1
		else:
			_status.text = "还原失败：%s" % str(r.get("message", ""))
	refresh()
	_status.text = "已还原 %d 个" % okn


func _restore_all() -> void:
	var okn := 0
	for e in _rows:
		var r: Dictionary = ExrConvert.restore(e)
		if bool(r.get("ok", false)):
			okn += 1
	refresh()
	_status.text = "已还原 %d 个" % okn


func _ask_purge_selected() -> void:
	if _selected_indices().is_empty():
		_status.text = "没选中任何条目"
		return
	_confirm_purge.popup_centered()


func _ask_purge_all() -> void:
	if _rows.is_empty():
		_status.text = "回收站是空的"
		return
	_confirm_purge_all.popup_centered()


func _purge_selected() -> void:
	var idx := _selected_indices()
	var n := 0
	for i in idx:
		var r: Dictionary = ExrConvert.purge(_rows[i])
		if bool(r.get("ok", false)):
			n += 1
	refresh()
	_status.text = "已彻底删除 %d 个" % n


func _purge_all() -> void:
	var n := 0
	for e in _rows:
		var r: Dictionary = ExrConvert.purge(e)
		if bool(r.get("ok", false)):
			n += 1
	refresh()
	_status.text = "已清空，删除 %d 个" % n


# ------------------------------------------------------------------ 转换到指定目录

func _pick_exr() -> void:
	if _open_dialog == null or not is_instance_valid(_open_dialog):
		_open_dialog = EditorFileDialog.new()
		_open_dialog.title = "选择要转换的 EXR"
		_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_open_dialog.access = FileDialog.ACCESS_RESOURCES
		_open_dialog.add_filter("*.exr", "EXR 文件")
		_open_dialog.current_dir = "res://assets"
		_open_dialog.file_selected.connect(_on_exr_picked)
		add_child(_open_dialog)
	_open_dialog.popup_centered_ratio(0.6)


func _on_exr_picked(path: String) -> void:
	_picked_exr = path
	_pick_out_dir()


func _pick_out_dir() -> void:
	if _out_dialog == null or not is_instance_valid(_out_dialog):
		_out_dialog = EditorFileDialog.new()
		_out_dialog.title = "选择 PNG 输出目录"
		_out_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_out_dialog.access = FileDialog.ACCESS_RESOURCES
		_out_dialog.current_dir = "res://"
		_out_dialog.dir_selected.connect(_convert_to)
		add_child(_out_dialog)
	_out_dialog.popup_centered_ratio(0.6)


func _convert_to(dir: String) -> void:
	if _picked_exr == "":
		return
	var abs_out := ProjectSettings.globalize_path(dir)
	DirAccess.make_dir_recursive_absolute(abs_out)
	var dst := abs_out.path_join("%s.png" % _picked_exr.get_file().get_basename())
	var r: Dictionary = ExrConvert.convert_file(ProjectSettings.globalize_path(_picked_exr), dst, false)
	_status.text = ("转换成功：%s" % dst) if bool(r.get("ok", false)) else ("转换失败：%s" % str(r.get("message", "")))
	if bool(r.get("ok", false)):
		# 通知编辑器导入新图片（单文件刷新比整树扫描快）
		var fs := EditorInterface.get_resource_filesystem()
		var rel := ProjectSettings.localize_path(dst)
		if fs != null and rel.begins_with("res://") and fs.has_method("update_file"):
			fs.call("update_file", rel)

# ------------------------------------------------------------------ 整目录批量转换

## 选源目录（含子目录）→ 先数一遍有几个 EXR，再让用户确认
func _pick_src_dir() -> void:
	if _src_dialog == null or not is_instance_valid(_src_dialog):
		_src_dialog = EditorFileDialog.new()
		_src_dialog.title = "选择要转换的源目录（会转换其中全部 EXR）"
		_src_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_src_dialog.access = FileDialog.ACCESS_RESOURCES
		_src_dialog.current_dir = "res://assets"
		_src_dialog.dir_selected.connect(_ask_batch)
		add_child(_src_dialog)
	_src_dialog.popup_centered_ratio(0.6)


func _ask_batch(dir: String) -> void:
	var abs_dir := ProjectSettings.globalize_path(dir)
	var n: int = (ExrConvert.find_exr(abs_dir, true) as Array).size()
	if n == 0:
		_status.text = "该目录（含子目录）里没有 EXR：%s" % dir
		return
	_pending_src = dir
	_confirm_batch.dialog_text = "目录：%s\n\n共找到 %d 个 EXR（含子目录），全部转换到指定目录？" % [dir, n]
	_confirm_batch.popup_centered()


func _pick_batch_out() -> void:
	if _batch_out_dialog == null or not is_instance_valid(_batch_out_dialog):
		_batch_out_dialog = EditorFileDialog.new()
		_batch_out_dialog.title = "选择 PNG 输出目录"
		_batch_out_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
		_batch_out_dialog.access = FileDialog.ACCESS_RESOURCES
		_batch_out_dialog.current_dir = "res://"
		_batch_out_dialog.dir_selected.connect(_convert_batch)
		add_child(_batch_out_dialog)
	_batch_out_dialog.popup_centered_ratio(0.6)


func _convert_batch(out_dir: String) -> void:
	if _pending_src == "":
		return
	var src_abs := ProjectSettings.globalize_path(_pending_src)
	var out_abs := ProjectSettings.globalize_path(out_dir)
	_status.text = "批量转换中…（源 %s）" % _pending_src
	var r: Dictionary = ExrConvert.convert_dir(src_abs, {"recursive": true, "out_dir": out_abs})
	var created: Array = r.get("created", [])
	# 通知编辑器导入（逐个登记；批量一般几十个，够快）
	var fs := EditorInterface.get_resource_filesystem()
	var notified := 0
	for c in created:
		var rel := ProjectSettings.localize_path(String(c))
		if fs != null and rel.begins_with("res://") and fs.has_method("update_file"):
			fs.call("update_file", rel)
			notified += 1
	_status.text = "批量完成：共 %d ｜ 成功 %d ｜ 失败 %d ｜ 已登记导入 %d ｜ 输出到 %s" % [
			int(r.get("total", 0)), int(r.get("ok", 0)),
			(r.get("failed", []) as Array).size(), notified, out_dir]
	for line in (r.get("lines", []) as Array):
		print("[EXR 工具] %s" % str(line))
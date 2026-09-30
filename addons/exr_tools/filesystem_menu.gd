@tool
extends EditorContextMenuPlugin
## 文件系统右键菜单：「EXR 转 PNG…」
## 对着 .exr 右键（用它的目录）或对着文件夹右键（就用那个文件夹）都会出现这一项。

const ConvertDialog := preload("res://addons/exr_tools/convert_dialog.gd")
const ExrConvert := preload("res://addons/exr_tools/exr_convert.gd")

const ITEM_CONVERT := "EXR 转 PNG…"
const ITEM_RECYCLE := "EXR 移入回收站（可还原）"

var _last_paths := PackedStringArray()
var _added_at := 0
var _dlg: ConfirmationDialog = null
var _report: AcceptDialog = null


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if target_dir(paths).is_empty():
		return                               # 与 EXR/目录无关就不加这一项
	# Godot 有时会在同一次右键里多次调用 _popup_menu，节流防重复项
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item(ITEM_CONVERT, _on_convert)
	# **只在选中的是 .exr 文件时**才出现回收项（选文件夹不出现 ✓）
	if not exr_files(paths).is_empty():
		add_context_menu_item(ITEM_RECYCLE, _on_recycle)


## 回调参数用默认值：有的上下文带 paths、有的不带
func _on_convert(paths: Variant = null) -> void:
	var dir := target_dir(_to_paths(paths))
	if dir.is_empty():
		dir = target_dir(_last_paths)
	if dir.is_empty():
		return
	if _dlg == null or not is_instance_valid(_dlg):
		_dlg = ConvertDialog.new()
		EditorInterface.get_base_control().add_child(_dlg)
	_dlg.set_target(dir)
	_dlg.popup_centered()


## 选中 .exr → 用它的目录；选中文件夹 → 用那个文件夹；否则返回空
func target_dir(paths: PackedStringArray) -> String:
	for p in paths:
		var abs := ProjectSettings.globalize_path(p)
		if p.to_lower().ends_with(".exr"):
			return abs.get_base_dir()
		if DirAccess.dir_exists_absolute(abs):
			return abs
	return ""


func _to_paths(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is PackedStringArray:
		out = value
	elif value is Array:
		for p in value:
			out.append(str(p))
	elif value is String:
		out.append(value)
	return out

## 选中的 **.exr 文件**（只认文件本身；文件夹、其它扩展名、不存在的文件一律不算）
func exr_files(paths: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for p in paths:
		var s := String(p)
		if not s.to_lower().ends_with(".exr"):
			continue
		var abs := ProjectSettings.globalize_path(s)
		if FileAccess.file_exists(abs):
			out.append(abs)
	return out


## 右键「EXR 移入回收站」：把**选中的这些** EXR 移进 .runtime 回收站（可还原，不是删除）
func _on_recycle(paths: Variant = null) -> void:
	var files := exr_files(_to_paths(paths))
	if files.is_empty():
		files = exr_files(_last_paths)
	if files.is_empty():
		return
	var ok := 0
	var fails := PackedStringArray()
	for f in files:
		var r: Dictionary = ExrConvert.recycle(String(f))
		if bool(r.get("ok", false)):
			ok += 1
		else:
			fails.append("%s：%s" % [String(f).get_file(), str(r.get("message", ""))])
	if _report == null or not is_instance_valid(_report):
		_report = AcceptDialog.new()
		_report.title = "EXR 回收"
		# 注意：EditorContextMenuPlugin 是 RefCounted，**没有 add_child()** ——
		# 窗口必须挂到编辑器的主控件上才能弹出来。
		var base := EditorInterface.get_base_control()
		if base != null:
			base.add_child(_report)
	_report.dialog_text = "已把 %d 个 EXR 移入回收站：.runtime/exr_recycle" % ok \
			+ "\n（可在右侧「EXR 管理器」里查看与还原）"
	if not fails.is_empty():
		_report.dialog_text += "\n\n失败 %d 个：\n%s" % [fails.size(), "\n".join(fails)]
	_report.popup_centered()
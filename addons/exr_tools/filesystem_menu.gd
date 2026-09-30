@tool
extends EditorContextMenuPlugin
## 文件系统右键菜单：「EXR 转 PNG…」
## 对着 .exr 右键（用它的目录）或对着文件夹右键（就用那个文件夹）都会出现这一项。

const ConvertDialog := preload("res://addons/exr_tools/convert_dialog.gd")

var _last_paths := PackedStringArray()
var _added_at := 0
var _dlg: ConfirmationDialog = null


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if target_dir(paths).is_empty():
		return                               # 与 EXR/目录无关就不加这一项
	# Godot 有时会在同一次右键里多次调用 _popup_menu，节流防重复项
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item("EXR 转 PNG…", _on_convert)


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
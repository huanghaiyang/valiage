@tool
extends EditorContextMenuPlugin
## 文件系统右键：「图片转换…」
## 对着图片文件右键（单文件），或对着文件夹右键（批量）都会出现。

const ConvertDialog := preload("res://addons/image_convert/convert_dialog.gd")
const ImageConv := preload("res://addons/image_convert/image_convert.gd")

const ITEM := "图片转换…"

var _last_paths := PackedStringArray()
var _added_at := 0
var _dlg: ConfirmationDialog = null


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	var dir := target_dir(paths)
	if dir.is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item(ITEM, _on_open)


func _on_open(paths: Variant = null) -> void:
	var p := _to_paths(paths)
	if p.is_empty():
		p = _last_paths
	var dir := target_dir(p)
	if dir.is_empty():
		return
	if _dlg == null or not is_instance_valid(_dlg):
		_dlg = ConvertDialog.new()
		# 注意：EditorContextMenuPlugin 是 RefCounted，没有 add_child —— 必须挂到编辑器主控件
		EditorInterface.get_base_control().add_child(_dlg)
	_dlg.set_target(dir, ImageConv.is_image(String(p[0])) if p.size() > 0 else false)
	_dlg.popup_centered()


## 选中图片 → 用它的目录（单文件模式）；选中文件夹 → 那个文件夹（批量模式）
func target_dir(paths: PackedStringArray) -> String:
	for x in paths:
		var s := String(x)
		var abs := ProjectSettings.globalize_path(s)
		if ImageConv.is_image(s):
			return abs.get_base_dir()
		if DirAccess.dir_exists_absolute(abs):
			return abs
	return ""


func _to_paths(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is PackedStringArray:
		out = value
	elif value is Array:
		for x in value:
			out.append(str(x))
	elif value is String:
		out.append(value)
	return out
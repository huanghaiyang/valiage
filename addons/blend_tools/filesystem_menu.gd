@tool
extends EditorContextMenuPlugin
## 文件系统右键：「预览并导出 TSCN…」（只对 .blend 出现）

const Launcher := preload("res://addons/blend_tools/open_window.gd")

var _last_paths := PackedStringArray()
var _added_at := 0


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if _first_blend(paths).is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:      # 同一次右键会调多次，节流防重复项
		return
	_added_at = now
	add_context_menu_item("预览并导出 TSCN…", _on_open)


func _on_open(paths: Variant = null) -> void:
	var p := _first_blend(_to_paths(paths))
	if p.is_empty():
		p = _first_blend(_last_paths)
	if p.is_empty():
		return
	Launcher.open_preview(p)


func _to_paths(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is PackedStringArray:
		out = value
	elif value is Array:
		for v in value:
			out.append(str(v))
	elif value is String:
		out.append(value)
	return out


func _first_blend(paths: PackedStringArray) -> String:
	for p in paths:
		if p.to_lower().ends_with(".blend"):
			return p
	return ""
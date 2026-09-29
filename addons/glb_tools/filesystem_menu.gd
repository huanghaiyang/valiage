@tool
extends EditorContextMenuPlugin
## 文件系统右键菜单项：「预览并导出部分节点…」（插件唯一的入口）
##
## 对着 .glb 右键 → 打开 GLB 预览窗口（左边节点树勾选、右边 3D 预览）→ 勾几个导出成新 glb。
## Godot 内置的「高级导入设置」没有插件扩展点，所以用自带窗口。

const OpenDialog := preload("res://addons/glb_tools/open_dialog.gd")

var _last_paths := PackedStringArray()
var _added_at := 0


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if _first_glb(paths).is_empty():
		return                               # 不是 .glb 就不加这一项
	# Godot 有时会在同一次右键里多次调用 _popup_menu，节流防重复项
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item("预览并导出部分节点…", _on_open)


## 回调参数用默认值：有的上下文会带 paths、有的不带，两种都要能跑
func _on_open(paths: Variant = null) -> void:
	var glb := _first_glb(_to_paths(paths))
	if glb.is_empty():
		glb = _first_glb(_last_paths)
	if glb.is_empty():
		return
	OpenDialog.open_preview(glb)


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


func _first_glb(paths: PackedStringArray) -> String:
	for p in paths:
		if p.to_lower().ends_with(".glb"):
			return p
	return ""

@tool
extends EditorContextMenuPlugin
## 文件系统右键：「用 Blender 打开」（只对 .glb / .gltf 出现）

const Blender := preload("res://addons/blender_bridge/blender.gd")
const SettingsDialog := preload("res://addons/blender_bridge/settings_dialog.gd")

var _last_paths := PackedStringArray()
var _added_at := 0


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if _first_model(paths).is_empty():
		return
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:      # 同一次右键可能被调用多次，节流防重复项
		return
	_added_at = now
	add_context_menu_item("用 Blender 打开", _on_open)


## 回调参数给默认值：有的上下文会带 paths、有的不带
func _on_open(paths: Variant = null) -> void:
	var p := _first_model(_to_paths(paths))
	if p.is_empty():
		p = _first_model(_last_paths)
	if p.is_empty():
		return
	var res := Blender.open_in_blender(p)
	if bool(res.get("ok", false)):
		print("[Blender 桥] " + String(res.get("message", "")))
		return
	# 失败（多半是没找到 Blender）：直接弹设置窗口，别让用户面对"点了没反应"
	push_warning("[Blender 桥] " + String(res.get("message", "")))
	open_settings(String(res.get("message", "")))


static func open_settings(reason := "") -> void:
	var dlg: ConfirmationDialog = SettingsDialog.new()
	EditorInterface.get_base_control().add_child(dlg)
	dlg.popup_centered()
	dlg.close_requested.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	if not reason.is_empty():
		dlg.call("set_message", reason)


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


func _first_model(paths: PackedStringArray) -> String:
	for p in paths:
		var low := p.to_lower()
		if low.ends_with(".glb") or low.ends_with(".gltf"):
			return p
	return ""

@tool
extends EditorContextMenuPlugin
## 文件系统右键：GLB 切割工具...-> 请插件弹出窗口 [OK]

var plugin: EditorPlugin = null


func _popup_menu(paths: PackedStringArray) -> void:
	for p in paths:
		var s := String(p)
		if s.to_lower().ends_with(".glb") or s.to_lower().ends_with(".gltf"):
			add_context_menu_item("GLB 切割工具...", _on_open)
			return


func _on_open(paths: Variant = null) -> void:
	var target := ""
	if paths is PackedStringArray and (paths as PackedStringArray).size() > 0:
		target = String((paths as PackedStringArray)[0])
	elif paths is Array and (paths as Array).size() > 0:
		target = String((paths as Array)[0])
	if target != "" and not target.begins_with("res://"):
		target = "res://" + target.trim_prefix("/")
	if plugin != null and is_instance_valid(plugin) and plugin.has_method("open_window"):
		plugin.call("open_window", target)
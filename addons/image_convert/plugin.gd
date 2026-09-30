@tool
extends EditorPlugin
## 图片转换插件入口：把「图片转换…」挂到文件系统右键菜单。

const FileSystemMenu := preload("res://addons/image_convert/filesystem_menu.gd")
const MENU_META := &"image_convert_menu_plugins"

var _menu: EditorContextMenuPlugin = null


func _enter_tree() -> void:
	_remove_stale_menus()
	_menu = FileSystemMenu.new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _menu)
	var root := get_tree().root
	var list: Array = root.get_meta(MENU_META, [])
	list.append(_menu)
	root.set_meta(MENU_META, list)
	print("[图片转换] 已启用：文件系统右键 →「图片转换…」")


func _exit_tree() -> void:
	if _menu != null:
		remove_context_menu_plugin(_menu)
		var root := get_tree().root
		var list: Array = root.get_meta(MENU_META, [])
		list.erase(_menu)
		root.set_meta(MENU_META, list)
		_menu = null
	_remove_stale_menus()
	print("[图片转换] 已停用")


func _remove_stale_menus() -> void:
	var root := get_tree().root
	var list: Array = root.get_meta(MENU_META, [])
	for m in list:
		if m != null and is_instance_valid(m):
			var sc: Script = (m as Object).get_script()
			if sc != null and String(sc.resource_path).contains("image_convert"):
				remove_context_menu_plugin(m)
	root.set_meta(MENU_META, [])
@tool
extends EditorPlugin
## EXR 工具的插件入口：把「EXR 转 PNG…」挂到**文件系统右键菜单**上。

const FileSystemMenu := preload("res://addons/exr_tools/filesystem_menu.gd")
const ManagerPanel := preload("res://addons/exr_tools/exr_manager_panel.gd")
const MENU_MANAGER := "打开 EXR 管理器"
const MENU_META := &"exr_tools_menu_plugins"

var _menu: EditorContextMenuPlugin = null
var _manager: Control = null


func _enter_tree() -> void:
	_remove_stale_menus()
	_manager = ManagerPanel.new()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _manager)
	add_tool_menu_item(MENU_MANAGER, _open_manager)
	_menu = FileSystemMenu.new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _menu)
	var root := get_tree().root
	var list: Array = root.get_meta(MENU_META, [])
	list.append(_menu)
	root.set_meta(MENU_META, list)
	print("[EXR 工具] 已启用：文件系统右键 →「EXR 转 PNG…」")


func _exit_tree() -> void:
	if _menu != null:
		remove_context_menu_plugin(_menu)
		var root := get_tree().root
		var list: Array = root.get_meta(MENU_META, [])
		list.erase(_menu)
		root.set_meta(MENU_META, list)
		_menu = null
	_remove_stale_menus()
	remove_tool_menu_item(MENU_MANAGER)
	if _manager != null:
		remove_control_from_docks(_manager)
		_manager.queue_free()
		_manager = null
	print("[EXR 工具] 已停用")


func _open_manager() -> void:
	if _manager != null and _manager.has_method("refresh"):
		_manager.call("refresh")


## 热重载会留下旧实例（它们的菜单项不会自己消失），这里把属于本插件的旧实例摘干净
func _remove_stale_menus() -> void:
	var root := get_tree().root
	var list: Array = root.get_meta(MENU_META, [])
	for m in list:
		if m != null and is_instance_valid(m):
			var sc: Script = (m as Object).get_script()
			if sc != null and String(sc.resource_path).contains("exr_tools"):
				remove_context_menu_plugin(m)
	root.set_meta(MENU_META, [])
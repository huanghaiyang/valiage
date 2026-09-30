@tool
extends EditorPlugin
## GLB 切割插件入口（**弹窗形式** [OK]）
##
## 三个入口：
##   ① 文件系统里右键 .glb ->GLB 切割工具...-> 弹窗并自动选中该文件 [OK]（主用法 [OK]）
##   ② 顶部菜单 项目 -> 工具 ->GLB 切割工具...-> 直接弹窗 [OK]
##   ③ 面板里的选择...按钮 [OK]
##
## [!]️ preload 常量**绝不能**用原生类名 [X]（Panel / Menu / Core ... 都会解析失败 [OK]）
## 另：本插件从"左侧停靠面板"改成了"弹窗" [OK]（用户要求 [OK]），不再调用 add_control_to_dock [OK]

const SplitWindowScript := preload("res://addons/glb_split/split_window.gd")
const MenuScript := preload("res://addons/glb_split/filesystem_menu.gd")
const MENU_META := &"glb_split_menu_plugins"
const TOOL_ITEM := "GLB 切割工具..."

var _win: AcceptDialog = null
var _menu: EditorContextMenuPlugin = null


func _enter_tree() -> void:
	_remove_stale_menus()
	_menu = MenuScript.new()
	_menu.plugin = self
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _menu)
	# 项目 -> 工具 菜单项（有的版本可能没有这个 API [X] -> 守卫一下 [OK]）
	if has_method("add_tool_menu_item"):
		call("add_tool_menu_item", TOOL_ITEM, Callable(self, "open_window"))
	var root := get_tree().root
	var list: Array = root.get_meta(MENU_META, [])
	list.append(_menu)
	root.set_meta(MENU_META, list)
	print("[GLB 切割] 已启用（弹窗）[OK]：文件系统右键 glb ->%s，或 项目 -> 工具 ->%s" % [TOOL_ITEM, TOOL_ITEM])


func _exit_tree() -> void:
	if has_method("remove_tool_menu_item"):
		call("remove_tool_menu_item", TOOL_ITEM)
	if _menu != null:
		remove_context_menu_plugin(_menu)
		var root := get_tree().root
		var list: Array = root.get_meta(MENU_META, [])
		list.erase(_menu)
		root.set_meta(MENU_META, list)
		_menu = null
	if _win != null and is_instance_valid(_win):
		_win.queue_free()
		_win = null
	_remove_stale_menus()
	print("[GLB 切割] 已停用")


## 打开弹窗（右键菜单与工具菜单都走这里 [OK]）
func open_window(path: Variant = "") -> void:
	if _win == null or not is_instance_valid(_win):
		_win = SplitWindowScript.new()
		# Window 必须挂在某个长命节点下 [OK]（挂到编辑器主控件 [OK]）
		EditorInterface.get_base_control().add_child(_win)
	var target := ""
	if path is String:
		target = path
	elif path is PackedStringArray and (path as PackedStringArray).size() > 0:
		target = String((path as PackedStringArray)[0])
	elif path is Array and (path as Array).size() > 0:
		target = String((path as Array)[0])
	_win.call("open_with", target)


func _remove_stale_menus() -> void:
	var root := get_tree().root
	var list: Array = root.get_meta(MENU_META, [])
	for m in list:
		if m != null and is_instance_valid(m):
			var sc: Script = (m as Object).get_script()
			if sc != null and String(sc.resource_path).contains("glb_split"):
				remove_context_menu_plugin(m)
	root.set_meta(MENU_META, [])
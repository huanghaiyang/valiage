@tool
extends EditorPlugin

## 插件入口：
##   * 右侧停靠栏注册「Mixamo 动画绑定」面板
##   * FileSystem 右键菜单注册「删除动画…」（对 AnimationLibrary 的 .tres 生效）

const DockScript := preload("res://addons/mixamo_retarget/ui/retarget_dock.gd")
const ContextMenuScript := preload("res://addons/mixamo_retarget/ui/library_context_menu.gd")

var _dock: Control
var _context_menu: EditorContextMenuPlugin


func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.name = "Mixamo 动画绑定"
	_dock.custom_minimum_size = Vector2(360, 0)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)

	_context_menu = ContextMenuScript.new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _context_menu)


func _exit_tree() -> void:
	if _context_menu != null:
		remove_context_menu_plugin(_context_menu)
		_context_menu = null
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

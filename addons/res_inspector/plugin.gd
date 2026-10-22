@tool
extends EditorPlugin
## RES 查看器 · 编辑器入口。
##
## 提供三种打开方式：
##   · 底部面板「RES 查看器」——主界面，点工具栏「打开…」或拖入路径
##   · FileSystem 面板右键「用 RES 查看器打开」
##   · 菜单 Project > Tools / 命令面板（4.6+）里的「RES 查看器：…」
##
## 面板本体在 res_dock.gd（UI），解析核心在 res_format.gd（纯逻辑，可无头测试）。

const DOCK_SCRIPT := "res://addons/res_inspector/res_dock.gd"
const MENU_SCRIPT := "res://addons/res_inspector/res_context_menu.gd"

## 底部标签用的内置图标：为什么不放 svg —— 插件在编辑器「首次扫描」之前就被加载，
## 此时 res:// 下的 svg 还没 import，load() 会报 "Failed loading resource"。
## 直接取编辑器主题里的内置图标，零资源依赖。
const THEME_ICON := "Search"

const TOOL_SHOW := "RES 查看器：显示面板"
const TOOL_SELECTED := "RES 查看器：查看选中的资源"

## 允许查看的后缀（.scn/.tscn 同为资源文件，结构解析同样适用）。
const OPENABLE_EXTS := ["res", "tres", "scn", "tscn"]

var _dock: Control = null
var _context_menu: EditorContextMenuPlugin = null


func _enter_tree() -> void:
	var dock_script: Script = load(DOCK_SCRIPT)
	# load() 对「存在但编译失败」的脚本也会返回非 null，必须再查 can_instantiate()
	if dock_script == null or not dock_script.can_instantiate():
		push_error("[RES 查看器] 面板脚本无法实例化（编译失败？）：%s" % DOCK_SCRIPT)
		return

	_dock = dock_script.new() as Control
	if _dock == null:
		push_error("[RES 查看器] 面板脚本的基类不是 Control：%s" % DOCK_SCRIPT)
		return
	_dock.name = "ResInspectorDock"
	_dock.visible = true

	var tab_button := add_control_to_bottom_panel(_dock, "RES 查看器")
	if tab_button != null:
		var icon := _editor_icon()
		if icon != null:
			tab_button.icon = icon

	add_tool_menu_item(TOOL_SHOW, _show_panel)
	add_tool_menu_item(TOOL_SELECTED, _open_selected)

	_register_context_menu()
	_register_command_palette()
	print("[RES 查看器] 已启用：底部面板 / FileSystem 右键 / Tools 菜单")


func _exit_tree() -> void:
	remove_tool_menu_item(TOOL_SHOW)
	remove_tool_menu_item(TOOL_SELECTED)

	if _context_menu != null:
		remove_context_menu_plugin(_context_menu)
		_context_menu = null

	if _dock != null and is_instance_valid(_dock):
		remove_control_from_bottom_panel(_dock)
		_dock.queue_free()
	_dock = null


func _get_plugin_name() -> String:
	return "RES 查看器"


# ---------------------------------------------------------------- 入口

## 打开一个资源文件（res:// 或绝对路径均可）。
func open_path(path: String) -> void:
	if path.strip_edges() == "":
		return
	_show_panel()
	if _dock != null and _dock.has_method("open_path"):
		_dock.call("open_path", path)


## 显示底部面板。
func _show_panel() -> void:
	if _dock != null and is_instance_valid(_dock):
		make_bottom_panel_item_visible(_dock)


## 查看 FileSystem 面板里当前选中的资源。
func _open_selected() -> void:
	var picked := ""
	var paths := EditorInterface.get_selected_paths()
	for p in paths:
		if _is_openable(p):
			picked = p
			break
	_show_panel()
	if picked == "":
		_notify("请先在 FileSystem 面板选中一个 .res / .tres / .scn / .tscn 文件")
		return
	open_path(picked)


## 右键菜单里打开。
func _open_from_context(path: String) -> void:
	open_path(path)


func _is_openable(path: String) -> bool:
	return OPENABLE_EXTS.has(path.get_extension().to_lower())


## 往面板状态栏写一句话（面板没实现就退回 print）。
func _notify(text: String) -> void:
	if _dock != null and _dock.has_method("set_status"):
		_dock.call("set_status", text)
	else:
		print("[RES 查看器] %s" % text)


# ---------------------------------------------------------------- 集成点

## FileSystem 右键菜单。
func _register_context_menu() -> void:
	var menu_script: Script = load(MENU_SCRIPT)
	if menu_script == null or not menu_script.can_instantiate():
		return
	_context_menu = menu_script.new() as EditorContextMenuPlugin
	if _context_menu == null:
		return
	if _context_menu.has_method("setup"):
		_context_menu.call("setup", Callable(self, "_open_from_context"))
	# CONTEXT_SLOT_FILESYSTEM = 1
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _context_menu)


## 命令面板（Godot 4.6+ 才有，缺了就安静跳过）。
## 4.7.2 的实际签名是 4 个参数：
##   add_command(command_name: String, key_name: String, binded_callable: Callable, shortcut_text: String)
## （用动态 call() 引擎不会补默认值，必须传满且顺序正确）
func _register_command_palette() -> void:
	if not EditorInterface.has_method("get_command_palette"):
		return
	var palette: Variant = EditorInterface.get_command_palette()
	if palette == null or not palette.has_method("add_command"):
		return
	palette.call("add_command", "RES 查看器：显示面板", "res_inspector_show",
			Callable(self, "_show_panel"), "")
	palette.call("add_command", "RES 查看器：查看选中的资源", "res_inspector_open_selected",
			Callable(self, "_open_selected"), "")


## 取内置编辑器图标（拿不到就返回 null，不影响功能）。
func _editor_icon() -> Texture2D:
	if not EditorInterface.has_method("get_editor_theme"):
		return null
	var theme: Theme = EditorInterface.get_editor_theme()
	if theme == null or not theme.has_icon(THEME_ICON, "EditorIcons"):
		return null
	return theme.get_icon(THEME_ICON, "EditorIcons")

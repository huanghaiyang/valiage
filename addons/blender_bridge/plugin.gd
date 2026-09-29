@tool
extends EditorPlugin
## Blender 桥：把 .glb 直接交给 Blender 打开。
##
## 入口：
##   * 文件系统里右键 .glb / .gltf →「用 Blender 打开」
##   * 设置项放在菜单里（不再占 3D 工具栏）：
##       - 正规入口：项目 → 工具 →「Blender 设置…」（add_tool_menu_item）
##       - 另外 best-effort 往「帮助」菜单里也加一项：Godot **没有**给插件开放帮助菜单的
##         扩展点（EditorPlugin 的 76 个方法里没有相关 API），所以这里是在编辑器 UI 里
##         找到帮助菜单对象直接加项；万一以后 Godot 改了结构，找不到就静默跳过，不影响功能。

const FileSystemMenu := preload("res://addons/blender_bridge/filesystem_menu.gd")
const Blender := preload("res://addons/blender_bridge/blender.gd")

const MENU_ITEM := "Blender 设置…"
const HELP_ITEM_ID := 420731          # 自己挑一个不容易和编辑器内置项撞的 id

var _fs_menu: EditorContextMenuPlugin = null
var _help_menu: PopupMenu = null


func _enter_tree() -> void:
	_remove_legacy_buttons()      # 早先版本把设置按钮放在 3D 工具栏，重载后要清理掉
	_fs_menu = FileSystemMenu.new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _fs_menu)

	add_tool_menu_item(MENU_ITEM, _open_settings)
	_try_hook_help_menu()

	var found := Blender.find_blender()
	if found.is_empty():
		print("[Blender 桥] 已启用：项目→工具→「%s」里指定 blender.exe（或文件系统右键 .glb →用 Blender 打开）" % MENU_ITEM)
	else:
		print("[Blender 桥] 已启用，Blender = %s%s" % [found, "（已挂到帮助菜单）" if _help_menu != null else ""])


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)
	if _help_menu != null and is_instance_valid(_help_menu):
		var idx := _help_menu.get_item_index(HELP_ITEM_ID)
		if idx >= 0:
			_help_menu.remove_item(idx)
		if _help_menu.id_pressed.is_connected(_on_help_menu):
			_help_menu.id_pressed.disconnect(_on_help_menu)
		_help_menu = null
	if _fs_menu != null:
		remove_context_menu_plugin(_fs_menu)
		_fs_menu = null
	print("[Blender 桥] 已停用")


## best-effort 往编辑器的「帮助」菜单里加一项。
## 说明：Godot 没给插件开放帮助菜单的扩展点，所以这里是在编辑器 UI 里找菜单对象自己加。
## 找的时候**同时按节点名和显示文字**匹配（实测主菜单栏的 MenuButton 文字可能是空的，
## 只按文字找不到），也兼顾 PopupMenu 形式的菜单栏。找不到就静默跳过。
func _try_hook_help_menu() -> void:
	var base := EditorInterface.get_base_control()
	if base == null:
		return
	var stack: Array = [base]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var popup: PopupMenu = null
		var label := String(n.name)
		if n is MenuButton:
			popup = (n as MenuButton).get_popup()
			label += " " + String((n as MenuButton).text)
		elif n is PopupMenu:
			popup = n as PopupMenu
		label = label.to_lower()
		if popup != null and (label.contains("help") or label.contains("帮助")):
			# 只有"真正添加了这一项"的实例才去接回调；否则多个插件实例会让一次点击弹多个窗口
			if popup.get_item_index(HELP_ITEM_ID) < 0:
				popup.add_separator()
				popup.add_item(MENU_ITEM, HELP_ITEM_ID)
				if not popup.id_pressed.is_connected(_on_help_menu):
					popup.id_pressed.connect(_on_help_menu)
				print("[Blender 桥] 已把「%s」挂到帮助菜单：%s" % [MENU_ITEM, popup.name])
			_help_menu = popup
			return
		for c in n.get_children():
			stack.append(c)

func _on_help_menu(id: int) -> void:
	if id == HELP_ITEM_ID:
		_open_settings()


func _find_menu_buttons(n: Node) -> Array:
	var out: Array = []
	if n is MenuButton:
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_menu_buttons(c))
	return out


func _open_settings() -> void:
	FileSystemMenu.open_settings()


## 供测试/排查：帮助菜单有没有挂上
func is_help_menu_hooked() -> bool:
	return _help_menu != null and is_instance_valid(_help_menu)


## 早先版本把「Blender 设置」放在 3D 工具栏（用户要求挪进菜单）。
## 如果旧实例没能在 _exit_tree 里摘掉，这里扫一遍清掉，避免留下死按钮。
func _remove_legacy_buttons() -> void:
	var found := _find_buttons(EditorInterface.get_base_control(), ["Blender 设置"])
	for b in found:
		var p: Node = b.get_parent()
		if p != null:
			p.remove_child(b)
		b.queue_free()
	if not found.is_empty():
		print("[Blender 桥] 清掉了 %d 个旧版本遗留的工具栏按钮" % found.size())


func _find_buttons(n: Node, texts: Array) -> Array:
	var out: Array = []
	if n is Button and texts.has((n as Button).text):
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_buttons(c, texts))
	return out
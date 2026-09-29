@tool
extends EditorPlugin
## GLB 工具：把节点另存为新的 .glb。
##
## 两个用途、三处入口：
##   * 场景里选中的节点 → 新 .glb
##       - 场景树右键：「导出选中节点为 GLB…」
##       - 3D 工具栏：「导出 GLB」（只在选中带网格的 3D 节点时显示）
##   * 从一个 .glb 里挑部分节点 → 新 .glb
##       - 文件系统里右键 .glb：「预览并导出部分节点…」（带节点树勾选 + 3D 预览）

const SceneMenu := preload("res://addons/glb_tools/scene_menu.gd")
const FileSystemMenu := preload("res://addons/glb_tools/filesystem_menu.gd")
const OpenDialog := preload("res://addons/glb_tools/open_dialog.gd")
const GlbExport := preload("res://addons/glb_tools/glb_export.gd")

## 把本插件注册的右键菜单对象记在这里，供下一次重载时清理残留注册项
const META_KEY := &"glb_tools_menu_plugins"

var _scene_menu: EditorContextMenuPlugin = null
var _fs_menu: EditorContextMenuPlugin = null
var _button: Button = null


func _enter_tree() -> void:
	_remove_legacy_buttons()          # 必须在创建自己的按钮之前跑，否则会把自己的清掉
	_remove_stale_menus()             # 同上：先清上次残留的菜单注册项，再注册新的

	_scene_menu = SceneMenu.new()
	# 枚举定义在 EditorContextMenuPlugin 上（不在 EditorPlugin 上）
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_SCENE_TREE, _scene_menu)

	_fs_menu = FileSystemMenu.new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _fs_menu)

	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root != null:
		tree_root.set_meta(META_KEY, [_scene_menu, _fs_menu])

	_button = Button.new()
	_button.text = "导出 GLB"
	_button.tooltip_text = "把场景树里选中的一个或多个节点（含子树）另存为新的 .glb"
	_button.pressed.connect(_on_pressed)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _button)

	var sel := EditorInterface.get_selection()
	if sel != null and not sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.connect(_on_selection_changed)
	_on_selection_changed()
	print("[GLB 工具] 已启用：场景树右键 / 3D 工具栏「导出 GLB」/ 文件系统右键 .glb「预览并导出部分节点…」")


## 之前几轮插件实例如果在 _exit_tree 时因脚本报错没能注销菜单，注册项会残留在编辑器里，
## 于是右键菜单里出现"重复项"。这里把上一次记录下来的注册项注销掉。
func _remove_stale_menus() -> void:
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root == null or not tree_root.has_meta(META_KEY):
		return
	var stale: Array = tree_root.get_meta(META_KEY)
	var n := 0
	for p in stale:
		if p is EditorContextMenuPlugin and is_instance_valid(p):
			remove_context_menu_plugin(p)
			n += 1
	tree_root.remove_meta(META_KEY)
	if n > 0:
		print("[GLB 工具] 注销了 %d 个上次残留的右键菜单注册项（修菜单重复）" % n)


func _exit_tree() -> void:
	if _button != null:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _button)
		_button.queue_free()
		_button = null
	if _scene_menu != null:
		remove_context_menu_plugin(_scene_menu)
		_scene_menu = null
	if _fs_menu != null:
		remove_context_menu_plugin(_fs_menu)
		_fs_menu = null
	var sel := EditorInterface.get_selection()
	if sel != null and sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.disconnect(_on_selection_changed)
	print("[GLB 工具] 已停用")


func _selected_nodes() -> Array:
	var sel := EditorInterface.get_selection()
	return sel.get_selected_nodes() if sel != null else []


## 只有"选中了带网格的 3D 节点"时按钮才出现（否则没什么可导出的）
func _exportable_selection() -> Array:
	return GlbExport.exportable_only(_selected_nodes())


func _on_selection_changed() -> void:
	if _button != null:
		_button.visible = not _exportable_selection().is_empty()


func _on_pressed() -> void:
	OpenDialog.open_for(_exportable_selection())


## 早期版本往 3D 工具栏加过「导出 GLB」「GLB 预览」两个按钮。如果上一个插件实例的
## _exit_tree 没能摘掉它们（脚本重载失败时就会这样），工具栏上会留死按钮，所以启动时扫一遍。
## 注意：必须在创建自己的按钮**之前**跑（否则会把刚加上的那个一起清掉）。
func _remove_legacy_buttons() -> void:
	var stale := ["导出 GLB", "GLB 预览"]
	var found := _find_buttons(EditorInterface.get_base_control(), stale)
	for b in found:
		var p: Node = b.get_parent()
		if p != null:
			p.remove_child(b)
		b.queue_free()
	if not found.is_empty():
		print("[GLB 工具] 清掉了 %d 个旧版本遗留的工具栏按钮" % found.size())


func _find_buttons(n: Node, texts: Array) -> Array:
	var out: Array = []
	if n is Button and texts.has((n as Button).text):
		out.append(n)
	for c in n.get_children():
		out.append_array(_find_buttons(c, texts))
	return out

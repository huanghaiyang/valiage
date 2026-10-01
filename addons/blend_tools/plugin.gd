@tool
extends EditorPlugin
## Blender 预览导出：文件系统右键 .blend -> 「预览并导出 TSCN…」
##
## 入口只有一处（和 glb_tools 的做法一致）：文件系统右键。

const FileSystemMenu := preload("res://addons/blend_tools/filesystem_menu.gd")

## 记下本次注册的菜单对象，供下次重载时清理残留
const META_KEY := &"blend_tools_menu_plugins"

var _fs_menu: EditorContextMenuPlugin = null


func _enter_tree() -> void:
	_remove_stale_menus()
	_fs_menu = FileSystemMenu.new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _fs_menu)
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root != null:
		tree_root.set_meta(META_KEY, [_fs_menu])
	print("[Blender 预览导出] 已启用：文件系统右键 .blend ->「预览并导出 TSCN…」")


func _exit_tree() -> void:
	if _fs_menu != null:
		remove_context_menu_plugin(_fs_menu)
		_fs_menu = null
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root != null and tree_root.has_meta(META_KEY):
		tree_root.remove_meta(META_KEY)


## 上一次重载若因脚本报错没能注销，注册项会残留 -> 右键出现重复项
func _remove_stale_menus() -> void:
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root == null or not tree_root.has_meta(META_KEY):
		return
	var stale: Array = tree_root.get_meta(META_KEY)
	for m in stale:
		if m is EditorContextMenuPlugin:
			remove_context_menu_plugin(m)
	tree_root.remove_meta(META_KEY)
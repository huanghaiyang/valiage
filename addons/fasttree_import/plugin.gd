@tool
extends EditorPlugin
## fast-tree 一键烘烤：文件系统右键 .glb → 烘焙网格（CUSTOM0/1）/ 树着色器材质 / 预制场景。
##
## 入口只有一处：文件系统右键（和 addons/glb_tools、blend_tools 的做法一致）。
## 只对 .glb 生效：菜单项由 filesystem_menu.gd 在 _popup_menu 里按扩展名过滤。

const FileSystemMenu := preload("res://addons/fasttree_import/filesystem_menu.gd")

## 记下本次注册的菜单对象，供下次重载时清理残留（避免右键出现重复项）
const META_KEY := &"fasttree_import_menu_plugins"

var _fs_menu: EditorContextMenuPlugin = null


func _enter_tree() -> void:
	_remove_stale_menus()
	_fs_menu = FileSystemMenu.new()
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _fs_menu)
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root != null:
		tree_root.set_meta(META_KEY, [_fs_menu])
	print("[fast-tree 烘烤] 已启用：文件系统右键 .glb →「fast-tree 一键烘烤…」")


func _exit_tree() -> void:
	if _fs_menu != null:
		remove_context_menu_plugin(_fs_menu)
		_fs_menu = null
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root != null and tree_root.has_meta(META_KEY):
		tree_root.remove_meta(META_KEY)
	print("[fast-tree 烘烤] 已停用")


## 上一次重载若因脚本报错没能注销，注册项会残留 -> 右键出现重复项
func _remove_stale_menus() -> void:
	var tree_root: Window = (Engine.get_main_loop() as SceneTree).root
	if tree_root == null or not tree_root.has_meta(META_KEY):
		return
	for m in tree_root.get_meta(META_KEY):
		if m is EditorContextMenuPlugin and is_instance_valid(m):
			remove_context_menu_plugin(m)
	tree_root.remove_meta(META_KEY)

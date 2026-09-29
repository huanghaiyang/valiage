@tool
extends EditorPlugin
## 卡位监测插件。
##
## 它本身不做检测（检测要在**运行的游戏里**才准：编辑器的物理空间不跑模拟，
## intersect_shape / cast_motion 查不到静态体的碰撞）。所以插件的作用是
## **一键把监测节点插进当前场景**：项目 → 工具 →「插入卡位监测节点」。

const MONITOR_SCRIPT := "res://addons/stuck_monitor/stuck_monitor.gd"
const MENU_ITEM := "插入卡位监测节点"


func _enter_tree() -> void:
	add_tool_menu_item(MENU_ITEM, _on_insert)
	print("[卡位监测] 已启用：项目 → 工具 →「%s」（运行时才会扫）" % MENU_ITEM)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)
	print("[卡位监测] 已停用")


func _on_insert() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		push_warning("[卡位监测] 当前没有打开的场景")
		return
	var node := insert_into(root)
	if node == null:
		return
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	print("[卡位监测] 已插入 %s（运行游戏时开始扫描）" % node.name)


## 往 root 里插一个监测节点（已存在则直接返回它）。抽出来是为了能在测试里用合成场景验。
func insert_into(root: Node) -> Node3D:
	if root == null:
		return null
	for c in root.get_children():
		var s := c.get_script()
		if s != null and String((s as Script).resource_path) == MONITOR_SCRIPT:
			return c as Node3D                      # 已经插过了，不重复
	var script: GDScript = load(MONITOR_SCRIPT)
	if script == null:
		push_warning("[卡位监测] 监测脚本加载失败：%s" % MONITOR_SCRIPT)
		return null
	var node := Node3D.new()
	node.name = "StuckMonitor"
	node.set_script(script)
	if root.is_inside_tree():
		var ur := EditorInterface.get_editor_undo_redo()
		if ur != null:
			ur.create_action("插入卡位监测节点")
			ur.add_do_method(root, "add_child", node)
			ur.add_do_method(node, "set_owner", root)
			ur.add_do_reference(node)
			ur.add_undo_method(root, "remove_child", node)
			ur.commit_action()
			return node
	root.add_child(node)
	if root.is_inside_tree():
		node.owner = root
	return node

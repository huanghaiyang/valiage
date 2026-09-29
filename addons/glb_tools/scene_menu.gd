@tool
extends EditorContextMenuPlugin
## 场景树右键菜单项：「导出选中节点为 GLB…」
##
## 这条入口有两个"不确定"要防：
##   1. 回调参数 —— 有的上下文会把节点路径传进来，有的不传。所以形参给默认值，
##      并在 _popup_menu 里先把 paths 存下来兜底。
##   2. 路径形式 —— 可能是相对当前编辑场景根、可能带根节点名、可能是绝对的。
##      三种都试；都不行就退回"当前选中项"。
## 两条都失手时弹一个可见对话框，并把收到的原始路径写进 user://glb_tools_last_menu.txt。

const OpenDialog := preload("res://addons/glb_tools/open_dialog.gd")
const GlbExport := preload("res://addons/glb_tools/glb_export.gd")

var _last_paths := PackedStringArray()
var _added_at := 0


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if paths.is_empty():
		return
	# Godot 有时会在同一次右键里多次调用 _popup_menu，节流防重复项
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item("导出选中节点为 GLB…", _on_export)


## 回调参数用默认值：有的上下文会带 paths、有的不带，两种都要能跑
func _on_export(paths: Variant = null) -> void:
	var raw := _to_paths(paths)
	if raw.is_empty():
		raw = _last_paths
	var nodes := _resolve(raw)
	if nodes.is_empty() and EditorInterface.get_selection() != null:
		# 路径没解析出来（形式不匹配）：退回当前选中项，别让用户觉得"点了没反应"
		for n in EditorInterface.get_selection().get_selected_nodes():
			nodes.append(n)
	nodes = GlbExport.exportable_only(nodes)
	_log(raw, nodes)
	if nodes.is_empty():
		OpenDialog.warn_nothing(raw)
		return
	OpenDialog.open_for(nodes)


func _to_paths(value: Variant) -> PackedStringArray:
	var out := PackedStringArray()
	if value is PackedStringArray:
		out = value
	elif value is Array:
		for p in value:
			out.append(str(p))
	elif value is String:
		out.append(value)
	return out


func _resolve(paths: PackedStringArray) -> Array:
	var out: Array = []
	var root := EditorInterface.get_edited_scene_root()
	for p in paths:
		var n: Node = null
		# ① 相对当前编辑场景根
		if root != null:
			n = root.get_node_or_null(NodePath(p))
		# ② 形如 "RootName/Child"
		if n == null and root != null and p.contains("/"):
			var head := p.split("/")[0]
			if head == String(root.name):
				n = root.get_node_or_null(NodePath(p.substr(head.length() + 1)))
		# ③ 绝对路径
		if n == null and p.begins_with("/") and root != null:
			n = root.get_tree().root.get_node_or_null(NodePath(p))
		if n != null and not out.has(n):
			out.append(n)
	return out


## 把本次右键收到/解析到的内容写下来，出问题时有据可查
static func _log(raw: PackedStringArray, nodes: Array) -> void:
	var f := FileAccess.open("user://glb_tools_last_menu.txt", FileAccess.WRITE)
	if f == null:
		return
	f.store_string("右键收到的路径：%s\n解析出可导出节点：%d 个\n当前编辑场景：%s\n" % [
		", ".join(raw) if not raw.is_empty() else "<空>",
		nodes.size(),
		str(EditorInterface.get_edited_scene_root())])
	f.close()
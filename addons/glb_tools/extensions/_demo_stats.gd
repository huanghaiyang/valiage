@tool
extends "res://addons/glb_tools/preview_extension.gd"
## 示例扩展。文件名以 _ 开头 → **默认不加载**（去掉下划线即启用）。
## 它示范一个最小扩展：底部一个可勾选按钮 + 一块面板 + 记录最近选中的节点。

var _label: Label = null
var last_selected := ""


func ext_name() -> String:
	return "示例：选中信息"


func ext_description() -> String:
	return "示范扩展怎么写：显示最近选中的节点路径"


func build_panel(_host: Node) -> Control:
	var box := VBoxContainer.new()
	_label = Label.new()
	_label.text = "（还没选中节点）"
	box.add_child(_label)
	return box


func on_node_selected(node: Node) -> void:
	last_selected = "" if node == null else String(node.get_path())
	if _label != null:
		_label.text = "选中：%s" % last_selected
@tool
extends RefCounted
## GLB 预览窗口的扩展接口。
## 用法：在 addons/glb_tools/extensions/ 里放一个继承本类的 .gd 即可生效。
## 所有回调都是**可选**的：不实现就不会被调用（窗口用 has_method 判断）。
## 文件名以 _ 开头的扩展默认不加载（方便放示例或未完成的扩展）。


## 显示成窗口底部的一个可勾选按钮
func ext_name() -> String:
	return "未命名扩展"


func ext_description() -> String:
	return ""


## 返回一个 Control 就显示成面板（默认隐藏，按钮切换）；返回 null 表示没有界面
func build_panel(_host: Node) -> Control:
	return null


## 预览窗口里选中某个节点时被调用
func on_node_selected(_node: Node) -> void:
	pass


## 导出前被调用（可以看到将要导出的节点，做清理或记录）
func on_before_export(_nodes: Array) -> void:
	pass
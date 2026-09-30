@tool
extends EditorPlugin
## 「图片清单」插件：把面板挂到右侧 dock，并在 项目 → 工具 里加一个入口。

const ImagePanel := preload("res://addons/image_tools/image_list_panel.gd")
const MENU_ITEM := "打开图片清单"

var _panel: Control = null


func _enter_tree() -> void:
	_panel = ImagePanel.new()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, _panel)
	add_tool_menu_item(MENU_ITEM, _on_open)
	print("[图片清单] 已启用：右侧 dock「图片清单」，或 项目 → 工具 →「%s」" % MENU_ITEM)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_ITEM)
	if _panel != null:
		remove_control_from_docks(_panel)
		_panel.queue_free()
		_panel = null
	print("[图片清单] 已停用")


func _on_open() -> void:
	if _panel == null:
		return
	_panel.show()
	# dock 无法直接 grab_focus，靠重扫一遍把注意力带过去
	if _panel.has_method("_on_scan"):
		_panel.call("_on_scan")
@tool
extends EditorPlugin
## 【天气组合器】把 Weather Composer 停靠面板挂到编辑器左下区。
##
## 【它做什么 / 不做什么】
##   · 做：提供一个面板，用"基础 A + 基础 B 按比例混合"或"复制 A 再逐项微调"两种方式
##     造出新的天气，并把结果写进 res://data/weather/custom_weathers.json。
##   · 不做：不碰场景、不改材质、不改 project.godot。天气节点启动时自己读那个 JSON
##     （见 scripts/world/weather.gd 的 reload_definitions）。
##
## 【为什么挂在 addons/ 而不是 scripts/】
##   它是纯编辑器工具：@tool + EditorPlugin，导出游戏时不会被打包进玩法脚本目录。
##
## 【注意】
##   面板里保存后，**已经打开的**游戏/编辑器预览不会自动换表 —— weather.gd 不是 @tool，
##   编辑器里只是占位实例，无法调用 reload_definitions()。保存后请重载场景或重启游戏。

const DockScript := preload("res://addons/weather_composer/weather_dock.gd")

## 面板实例（_enter_tree 创建、_exit_tree 释放）
var _dock: Control = null


## 插件启用时调用：创建并挂上面板。
## 槽位 LEFT_BR（左下）：右上已被 SimpleGrassTextured 的实例列表占用，错开避免两套面板打架。
func _enter_tree() -> void:
	_dock = DockScript.new()
	_dock.name = "WeatherComposer"
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BR, _dock)


## 插件停用时调用：把面板从停靠区摘下来并释放。
## 顺序不能反：先 remove_control_from_docks 再 queue_free，
## 否则编辑器可能保留一个已释放控件的引用（切插件开关时偶发崩溃）。
func _exit_tree() -> void:
	if _dock != null:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null

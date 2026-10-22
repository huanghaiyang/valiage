@tool
extends EditorContextMenuPlugin
## FileSystem 面板右键菜单：给资源文件加一条「用 RES 查看器打开」。
##
## ⚠ 踩过的坑（踩了两次，写在这里防止再犯）：
## `add_context_menu_item(name, callback)` 里的 **callback 会被引擎带 1 个参数回调**
## （当前右键选中的路径）。所以：
##   · 不能写成无参函数 —— 引擎传 1 个参数进来直接报 arity 错；
##   · 更不能 `callback.bind(路径)` —— bind 的参数接在调用参数之后，最终变成 2 个参数：
##       ERROR: Method expected 1 argument(s), but called with 2.
## 现在的写法：回调只收 1 个带默认值的可选参数（0 参调用也能活），
## 参数认得出路径就用参数，认不出就回落到 `_popup_menu` 里算好的目标。

const Logic := preload("res://addons/res_inspector/menu_logic.gd")

var _on_open: Callable = Callable()
## 最近一次 _popup_menu 时算出来的目标路径（兜底用）
var _target: String = ""


## 由 plugin.gd 注入回调：func(path: String) -> void
func setup(on_open: Callable) -> void:
	_on_open = on_open


func _popup_menu(paths: PackedStringArray) -> void:
	_target = Logic.pick(paths)
	if _target == "":
		return
	add_context_menu_item("用 RES 查看器打开", _on_menu_item)


## 菜单项被点击。参数是引擎传进来的选中路径（可能是 PackedStringArray）；
## 这里必须允许 0 参调用，所以不能写成必填参数。
func _on_menu_item(arg: Variant = null) -> void:
	var target := Logic.pick_arg(arg)
	if target == "":
		target = _target
	if target == "" or not _on_open.is_valid():
		return
	_on_open.call(target)

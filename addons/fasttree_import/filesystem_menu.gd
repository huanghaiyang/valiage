@tool
extends EditorContextMenuPlugin
## 文件系统右键：「fast-tree 一键烘烤…」——**只对 .glb 出现**
##
## 选中一个或多个 .glb → 弹窗里选碰撞/覆盖/是否打开场景 → 逐个烘烤成
## 烘焙网格（CUSTOM0/1 风摆数据）+ 树着色器材质 + 可直接放场景的 .tscn。

const ImportDialog := preload("res://addons/fasttree_import/import_dialog.gd")

const MENU_TEXT := "fast-tree 一键烘烤（场景/材质/网格）…"

var _last_paths := PackedStringArray()
var _added_at := 0


func _popup_menu(paths: PackedStringArray) -> void:
	_last_paths = paths
	if _glbs(paths).is_empty():
		return                              # 选中里没有 .glb → 不加这一项（仅对 glb 生效）
	# 同一次右键 Godot 可能多次调用 _popup_menu，节流防重复项（与 glb_tools 一致）
	var now := Time.get_ticks_msec()
	if now - _added_at < 250:
		return
	_added_at = now
	add_context_menu_item(MENU_TEXT, _on_convert)


## 回调参数在不同上下文可能带 paths 也可能不带，两种都要能跑
func _on_convert(paths: Variant = null) -> void:
	var list := _glbs(_to_paths(paths))
	if list.is_empty():
		list = _glbs(_last_paths)
	if list.is_empty():
		return
	ImportDialog.open(list)


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


## 只保留 .glb（大小写不敏感）；其它文件/文件夹一律忽略
func _glbs(paths: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for p in paths:
		if p.to_lower().ends_with(".glb"):
			out.append(p)
	return out

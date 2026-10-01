@tool
extends RefCounted
## 往 World Brush 的**每个场景行**注入「随机变体」开关 + 「选变体…」按钮。
## 每个场景行 = 一个来源场景 = 一个笔刷，所以这就是"每个笔刷单独设置"。
##
## 不改 WB 源码：它的行是一个含 EditorResourcePicker 的 HBoxContainer（见
## world_brush_dock.gd 的 _add_scene_row L1491+），我们按这个特征找出来再挂控件。
## WB 的行是动态创建的，所以由 plugin 定时轮询，逐行注入（按节点名去重）。

const VariantSets := preload("res://addons/variant_tools/variant_sets.gd")
const PREFIX := "VtRow_"
const PICKER_NAME := "VtPickButton"
const TOGGLE_NAME := "VtToggle"


## 扫一遍编辑器界面，给每个 WB 场景行补上我们的控件；返回这次新注入的行数
static func inject_all(base: Control) -> int:
	if base == null:
		return 0
	var n := 0
	var stack: Array = [base]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for c in node.get_children():
			stack.append(c)
		if node is HBoxContainer and _row_source(node) != null:
			if _inject_row(node as HBoxContainer):
				n += 1
	return n


## 一个"WB 场景行"的特征：HBoxContainer 里有一个 EditorResourcePicker
static func _row_source(row: Node) -> EditorResourcePicker:
	for c in row.get_children():
		if c is EditorResourcePicker:
			return c as EditorResourcePicker
	return null


static func _inject_row(row: HBoxContainer) -> bool:
	for c in row.get_children():
		if String(c.name) == PICKER_NAME:
			_refresh(row)
			return false                  # 已经注入过
	var toggle := CheckButton.new()
	toggle.name = TOGGLE_NAME
	toggle.text = "随机变体"
	toggle.tooltip_text = "开启后：用这个笔刷放置时，按下面的变体表随机替换（在项目设置里保存）"
	toggle.toggled.connect(_on_toggled.bind(row))
	var pick := Button.new()
	pick.name = PICKER_NAME
	pick.tooltip_text = "选择这个笔刷可以随机出的 .tscn（可多选）"
	pick.pressed.connect(_on_pick.bind(row))
	row.add_child(toggle)
	row.add_child(pick)
	_refresh(row)
	print("[变体工具] 已给一个 World Brush 场景行注入「随机变体」控件")
	return true


static func _src_path(row: HBoxContainer) -> String:
	var picker := _row_source(row)
	if picker == null:
		return ""
	var res: Variant = picker.edited_resource
	if res is PackedScene:
		return String((res as PackedScene).resource_path)
	return ""


static func _refresh(row: HBoxContainer) -> void:
	var src := _src_path(row)
	var toggle := row.get_node_or_null(NodePath(TOGGLE_NAME)) as CheckButton
	var pick := row.get_node_or_null(NodePath(PICKER_NAME)) as Button
	if pick != null:
		if src.is_empty():
			pick.text = "选变体…"
			pick.disabled = true
		else:
			pick.disabled = false
			var vs: Array = VariantSets.variants_of(src)
			pick.text = "选变体…(%d)" % vs.size() if vs.size() > 0 else "选变体…"
	if toggle != null:
		toggle.disabled = src.is_empty()
		toggle.set_pressed_no_signal(not src.is_empty() and VariantSets.is_enabled(src))


static func _on_toggled(on: bool, row: HBoxContainer) -> void:
	var src := _src_path(row)
	if src.is_empty():
		return
	VariantSets.set_enabled(src, on)
	print("[变体工具] 笔刷 %s 的随机变体 = %s" % [src.get_file(), str(on)])


static func _on_pick(row: HBoxContainer) -> void:
	var src := _src_path(row)
	if src.is_empty():
		push_warning("[变体工具] 这个场景行还没选来源场景")
		return
	var dlg := EditorFileDialog.new()
	dlg.access = EditorFileDialog.ACCESS_RESOURCES
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	dlg.title = "选择「%s」可以随机出的变体（可多选）" % src.get_file()
	dlg.add_filter("*.tscn", "场景")
	dlg.current_dir = src.get_base_dir()
	if dlg.has_signal("files_selected"):
		dlg.files_selected.connect(_on_files.bind(row))
	else:
		dlg.file_selected.connect(_on_one_file.bind(row))
	var base := EditorInterface.get_base_control()
	if base == null:
		dlg.free()
		return
	base.add_child(dlg)
	dlg.popup_centered_ratio(0.6)


static func _on_files(files: PackedStringArray, row: HBoxContainer) -> void:
	var src := _src_path(row)
	var arr: Array = []
	for f in files:
		arr.append(String(f))
	VariantSets.set_set(src, arr.size() >= 2, arr)
	_refresh(row)
	print("[变体工具] 笔刷 %s 的变体表 = %d 个" % [src.get_file(), arr.size()])


static func _on_one_file(path: String, row: HBoxContainer) -> void:
	var src := _src_path(row)
	VariantSets.set_set(src, false, [path])
	_refresh(row)
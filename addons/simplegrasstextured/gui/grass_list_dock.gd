# grass_list_dock.gd
# This file is part of: SimpleGrassTextured
# Copyright (c) 2023 IcterusGames
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# ---------------------------------------------------------------------------
# [本项目的改动] 「草地实例」左侧停靠面板
#
# 面板内容（全部实时读取 MultiMesh 实例，不做任何烘焙）：
#   * 顶部     ：当前草地节点名、刷出的草总数
#   * 工具行   ：刷新 / 选择要查看的草地节点 / 过滤框
#   * 列表     ：每株草一行，显示 序号、世界坐标、缩放、旋转
#   * 左键单击 ：选中该株草 -> 定位（编辑器 3D 相机中心）+ 3D 视图高亮
#   * 右键单击 ：弹出菜单 -> 删除选中 / 仅删除该项 / 复制坐标 / 定位
#   * 删除     ：走 EditorPlugin.get_undo_redo()，进入编辑器撤销堆栈（Ctrl+Z 可还原）
#
# 数量可能上万，所以列表分帧构建（每帧预算内建若干行），过滤只切换已有行的可见性。
# ---------------------------------------------------------------------------

@tool
extends VBoxContainer

## 一次刷新最多铺多少行（防止极端场景把编辑器卡死）
const MAX_ROWS := 20000
## 每帧建行数量 / 时间预算
const BUILD_CHUNK := 400
const BUILD_BUDGET_MS := 6

enum MENU_ID {
	LOCATE = 1,
	DELETE_SELECTED = 2,
	DELETE_ONE = 3,
	COPY_POSITIONS = 4,
}

var _plugin: EditorPlugin = null
var _grass = null
var _total := 0
var _entries := {}                   # index -> {"item": TreeItem, "pos": Vector3}
var _row_indices: Array = []         # 已建行的实例索引（按顺序）
var _displayed := 0                  # 本次刷新计划显示的行数
var _pending: Array = []             # 待建行的实例索引（分帧消费）
var _pending_at := 0
var _menu_index := -1                # 右键点中的行
var _filter_text := ""
var _pos_cache: Array = []           # 最近一次读取的世界坐标
var _pos_signature := ""             # 坐标指纹（首/中/尾），用于跳过无变化的刷新
var _right_clicking := false         # 右键调整选中时抑制「定位」

var _lbl_header: Label = null
var _btn_grass: MenuButton = null
var _edit_filter: LineEdit = null
var _tree: Tree = null
var _lbl_status: Label = null
var _menu: PopupMenu = null
var _grow_timer: Timer = null


func _ready() -> void:
	set_process(false)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_build_ui()
	theme_changed.connect(_on_theme_changed)
	_on_theme_changed()


# --------------------------------------------------------------------- UI

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 4)
	add_child(margin)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	_lbl_header = Label.new()
	_lbl_header.text = "草地实例：未选择草地节点"
	_lbl_header.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_header.tooltip_text = "显示当前草地节点刷出的草：总数 / 每株世界坐标 / 缩放 / 旋转。\n请先在场景中选中 SimpleGrassTextured 节点，或用右侧下拉框切换。"
	box.add_child(_lbl_header)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 4)
	box.add_child(tools)

	var btn_refresh := Button.new()
	btn_refresh.text = "刷新"
	btn_refresh.tooltip_text = "重新读取 MultiMesh 实例列表（统计数量与坐标）"
	btn_refresh.pressed.connect(_on_refresh_pressed)
	tools.add_child(btn_refresh)

	_btn_grass = MenuButton.new()
	_btn_grass.text = "草地节点"
	_btn_grass.tooltip_text = "列出当前场景里所有 SimpleGrassTextured 节点并切换查看对象"
	_btn_grass.get_popup().about_to_popup.connect(_on_grass_menu_about_to_popup)
	_btn_grass.get_popup().id_pressed.connect(_on_grass_menu_pressed)
	tools.add_child(_btn_grass)

	_edit_filter = LineEdit.new()
	_edit_filter.placeholder_text = "过滤（序号 / 坐标）"
	_edit_filter.clear_button_enabled = true
	_edit_filter.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_edit_filter.custom_minimum_size.x = 90
	_edit_filter.tooltip_text = "按序号或坐标片段过滤行（只影响显示，不改场景数据）"
	_edit_filter.text_changed.connect(_on_filter_text_changed)
	tools.add_child(_edit_filter)

	_tree = Tree.new()
	_tree.columns = 4
	_tree.set_column_title(0, "序号")
	_tree.set_column_title(1, "位置 (X, Y, Z)")
	_tree.set_column_title(2, "缩放")
	_tree.set_column_title(3, "旋转°")
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_MULTI
	_tree.allow_reselect = true
	_tree.hide_folding = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(0, 120)
	_tree.tooltip_text = "左键单击：定位到该株草并高亮\n右键单击：删除 / 复制坐标\nCtrl / Shift 多选后可一次删除多个"
	_tree.gui_input.connect(_on_tree_gui_input)
	_tree.item_selected.connect(_after_selection_changed)
	_tree.item_activated.connect(_on_item_activated)
	_tree.multi_selected.connect(_on_multi_selected)
	_tree.nothing_selected.connect(_after_selection_changed)
	box.add_child(_tree)

	_menu = PopupMenu.new()
	_menu.add_item("定位到该株草", MENU_ID.LOCATE)
	_menu.add_separator()
	_menu.add_item("删除选中项", MENU_ID.DELETE_SELECTED)
	_menu.add_item("仅删除该项", MENU_ID.DELETE_ONE)
	_menu.add_separator()
	_menu.add_item("复制选中项坐标", MENU_ID.COPY_POSITIONS)
	_menu.id_pressed.connect(_on_menu_id_pressed)
	add_child(_menu)

	_lbl_status = Label.new()
	_lbl_status.text = "未选择"
	_lbl_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_lbl_status)

	# 兜底：场景里草的数量可能被笔刷 / 撤销改变，定时器负责发现并重建列表
	_grow_timer = Timer.new()
	_grow_timer.wait_time = 0.5
	_grow_timer.autostart = true
	_grow_timer.timeout.connect(_on_grow_timer_timeout)
	add_child(_grow_timer)


func set_plugin(plugin: EditorPlugin) -> void:
	_plugin = plugin


# ------------------------------------------------------------- 对外接口

## 编辑器当前编辑的草地节点变化时调用
func set_grass(grass) -> void:
	if grass == _grass:
		return
	_grass = grass
	_clear_highlights()
	refresh(true)


## 笔刷操作结束 / 面板重新可见时调用：立即刷新并补一次延迟刷新
func refresh_later() -> void:
	refresh(true)
	if is_inside_tree():
		var t := get_tree().create_timer(0.35)
		t.timeout.connect(_on_refresh_delayed)


## 重新读取实例数量与坐标；rebuild_rows=true 时强制重建列表
func refresh(rebuild_rows: bool) -> void:
	var count := 0
	if _is_grass_valid() and _grass.multimesh != null:
		count = _grass.multimesh.instance_count
	_total = count
	_update_header()

	if _grass == null:
		_clear_rows()
		_set_status("未选择草地节点")
		return

	if rebuild_rows or count != _row_indices.size():
		_start_rebuild()
	elif count > 0:
		_refresh_positions()
	else:
		_update_status()


func has_grass() -> bool:
	return _is_grass_valid()


# --------------------------------------------------------------- 内部实现

func _is_grass_valid() -> bool:
	return _grass != null and is_instance_valid(_grass) and _grass.has_method(&"get_instance_count")


func _update_header() -> void:
	if _lbl_header == null:
		return
	if _grass == null:
		_lbl_header.text = "草地实例：未选择草地节点"
	elif not is_instance_valid(_grass):
		_lbl_header.text = "草地实例：节点已删除"
	else:
		var node_name := String(_grass.name)
		if not _is_editor_selected():
			node_name += "（当前未选中）"
		_lbl_header.text = "草地节点：%s    刷出的草总数：%d" % [node_name, _total]


func _is_editor_selected() -> bool:
	if _grass == null or not is_instance_valid(_grass):
		return false
	var selection := EditorInterface.get_selection()
	if selection == null:
		return false
	for node in selection.get_selected_nodes():
		if node == _grass:
			return true
	return false


func _set_status(text: String) -> void:
	if _lbl_status != null:
		_lbl_status.text = text


func _clear_rows() -> void:
	_pending.clear()
	_pending_at = 0
	_pos_cache.clear()
	_pos_signature = ""
	_entries.clear()
	_row_indices.clear()
	_displayed = 0
	set_process(false)
	if _tree != null:
		_tree.clear()


func _start_rebuild() -> void:
	_clear_rows()
	# 旧行下标已经作废，残留的高亮环必须一起清掉（删除后圆环不消失的修复点）
	_show_highlights([])
	_update_status()
	if _grass == null or _total <= 0:
		return
	_pos_cache = _grass.call(&"get_instance_positions")
	_displayed = mini(mini(_total, MAX_ROWS), _pos_cache.size())
	if _displayed <= 0:
		return
	_pending.clear()
	for i in range(_displayed):
		_pending.append(i)
	_pending_at = 0
	_pos_signature = _position_signature(_pos_cache)
	_tree.create_item()
	set_process(true)
	_process(0.0)


## 分帧建行（每帧最多 BUILD_CHUNK 行 / BUILD_BUDGET_MS 毫秒）
func _process(_delta: float) -> void:
	if _pending_at >= _pending.size():
		set_process(false)
		return
	var root := _tree.get_root()
	if root == null:
		set_process(false)
		return
	var budget := Time.get_ticks_msec() + BUILD_BUDGET_MS
	var built := 0
	while _pending_at < _pending.size() and built < BUILD_CHUNK:
		_add_row(root, _pending[_pending_at])
		_pending_at += 1
		built += 1
		if Time.get_ticks_msec() >= budget:
			break
	if _pending_at >= _pending.size():
		set_process(false)
		_apply_filter()
		_update_status()


func _add_row(root: TreeItem, idx: int) -> void:
	if _tree == null or root == null:
		return
	var trans: Transform3D = _grass.call(&"get_instance_transform_safe", idx)
	# 注意：multimesh 的 transform 是**局部**坐标，_pos_cache 里存的是世界坐标（面板显示用）
	var pos: Vector3 = _pos_cache[idx] if idx < _pos_cache.size() else _grass.call(&"get_instance_position", idx)
	var scale := trans.basis.get_scale()
	var item := _tree.create_item(root)
	item.set_text(0, str(idx))
	item.set_text(1, "%.3f, %.3f, %.3f" % [pos.x, pos.y, pos.z])
	item.set_text(2, "%.3f, %.3f, %.3f" % [scale.x, scale.y, scale.z])
	item.set_text(3, "%.1f" % rad_to_deg(trans.basis.get_euler().y))
	item.set_tooltip_text(0, "第 %d 株草\n世界坐标：%.4f, %.4f, %.4f" % [idx, pos.x, pos.y, pos.z])
	item.set_metadata(0, idx)
	_entries[idx] = {"index": idx, "item": item, "pos": pos}
	_row_indices.append(idx)


## 数量没变时的轻量刷新：只在坐标真的变了时才重写行文本
func _refresh_positions(force: bool = false) -> void:
	if _grass == null or _tree == null:
		return
	var positions: Array = _grass.call(&"get_instance_positions")
	if positions.size() < _row_indices.size():
		_start_rebuild()
		return
	_pos_cache = positions
	if not force and _position_signature(positions) == _pos_signature:
		return
	_pos_signature = _position_signature(positions)
	for idx in _row_indices:
		var entry: Dictionary = _entries.get(idx, {})
		if entry.is_empty():
			continue
		var pos: Vector3 = positions[idx]
		entry["pos"] = pos
		var item: TreeItem = entry["item"]
		if item == null or not is_instance_valid(item):
			continue
		item.set_text(1, "%.3f, %.3f, %.3f" % [pos.x, pos.y, pos.z])
		item.set_tooltip_text(0, "第 %d 株草\n世界坐标：%.4f, %.4f, %.4f" % [idx, pos.x, pos.y, pos.z])
	_apply_filter()


## 抽首/中/尾三株做指纹：笔刷改动几乎必然命中，避免每 0.35s 全表重写
func _position_signature(positions: Array) -> String:
	if positions.is_empty():
		return "0"
	var last := positions.size() - 1
	var mid := last / 2
	return "%d|%s|%s|%s" % [positions.size(), str(positions[0]), str(positions[mid]), str(positions[last])]


func _update_status() -> void:
	if _grass == null:
		_set_status("未选择草地节点")
		return
	var line := "共 %d 株" % _total
	if _total > MAX_ROWS:
		line += "，仅列出前 %d 株（用过滤框定位）" % MAX_ROWS
	line += "  |  左键定位，右键删除"
	_set_status(line)


# ------------------------------------------------------------ 选择 / 右键

func _on_multi_selected(_item: TreeItem, _column: int, _selected: bool) -> void:
	_after_selection_changed()


func _on_item_activated() -> void:
	var entry := _selected_entry()
	if not entry.is_empty():
		_locate_entry(entry)


## 单击即「选中 + 定位」；多选（Ctrl/Shift）时不动相机，但每株都高亮
func _after_selection_changed() -> void:
	if _grass == null:
		return
	var entries := selected_entries()
	# 高亮环严格跟随当前选中：单选 1 个、多选 N 个、没选中就全部清掉。
	# 删除后列表重建、选中被清空时，这一步也会把残留的圆环收掉。
	_show_highlights(entries)
	if entries.is_empty():
		_update_status()
		return
	var entry: Dictionary = entries[0]
	if entries.size() == 1:
		if not _right_clicking:
			_locate_entry(entry)
		var pos: Vector3 = entry["pos"]
		_set_status("已选中第 %d 株：%.3f, %.3f, %.3f  |  右键 = 删除 / 复制坐标" % [int(entry["index"]), pos.x, pos.y, pos.z])
	else:
		_set_status("已选中 %d 株（Ctrl/Shift 可增减）  |  右键 = 批量删除 / 复制坐标" % entries.size())


## 把当前选中的每一株都高亮出来（entries 为空 = 清空）
func _show_highlights(entries: Array) -> void:
	if _plugin == null:
		return
	var positions := PackedVector3Array()
	for entry in entries:
		positions.append(entry["pos"])
	_plugin.call(&"set_selection_highlights", positions)


func _clear_highlights() -> void:
	if _plugin != null:
		_plugin.call(&"clear_selection_highlights")


## 供插件在切换/卸载时清掉高亮环
func clear_highlights() -> void:
	_clear_highlights()


func _selected_entry() -> Dictionary:
	var entries := selected_entries()
	if entries.is_empty():
		return {}
	return entries[0]


func selected_entries() -> Array:
	var out: Array = []
	if _tree == null:
		return out
	var item := _tree.get_next_selected(null)
	while item != null:
		var idx := int(item.get_metadata(0))
		if _entries.has(idx):
			out.append(_entries[idx])
		item = _tree.get_next_selected(item)
	return out


func selected_indices() -> PackedInt32Array:
	var indices := PackedInt32Array()
	for entry in selected_entries():
		indices.append(int(_row_index_of(entry)))
	return indices


func _row_index_of(entry: Dictionary) -> int:
	var item: TreeItem = entry.get("item", null)
	if item != null and is_instance_valid(item):
		return int(item.get_metadata(0))
	return -1


func _locate_entry(entry: Dictionary) -> void:
	if _plugin == null or entry.is_empty():
		return
	if _grass != null and is_instance_valid(_grass) and not _is_editor_selected():
		var selection := EditorInterface.get_selection()
		if selection != null:
			selection.add_node(_grass)
	_plugin.call(&"focus_grass_point", entry["pos"])


func _on_tree_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_RIGHT:
		return
	var item := _tree.get_item_at_position(mb.position)
	if item == null:
		return
	# 右键点在未选中的行上：先只选中该行（期间抑制定位，避免右键也移动相机）
	if not item.is_selected(0):
		_right_clicking = true
		_tree.deselect_all()
		item.select(0)
		_right_clicking = false
	_menu_index = int(item.get_metadata(0))
	var has_selection := not selected_entries().is_empty()
	_menu.set_item_disabled(_menu.get_item_index(MENU_ID.DELETE_SELECTED), not has_selection)
	_menu.set_item_disabled(_menu.get_item_index(MENU_ID.COPY_POSITIONS), not has_selection)
	_menu.set_item_disabled(_menu.get_item_index(MENU_ID.DELETE_ONE), _menu_index < 0)
	_menu.reset_size()
	_menu.position = Vector2i(mb.global_position)
	_menu.popup()


func _on_menu_id_pressed(id: int) -> void:
	match id:
		MENU_ID.LOCATE:
			var entry := _selected_entry()
			if not entry.is_empty():
				_locate_entry(entry)
		MENU_ID.DELETE_SELECTED:
			_delete_indices(selected_indices())
		MENU_ID.DELETE_ONE:
			if _menu_index >= 0:
				_delete_indices(PackedInt32Array([_menu_index]))
		MENU_ID.COPY_POSITIONS:
			_copy_positions(selected_entries())


func _delete_indices(indices: PackedInt32Array) -> void:
	if indices.is_empty() or _plugin == null:
		return
	if _grass == null or not is_instance_valid(_grass):
		return
	# 过滤掉无效下标（-1），避免误删
	var valid := PackedInt32Array()
	for index in indices:
		if index >= 0:
			valid.append(index)
	if valid.is_empty():
		return
	if _lbl_status != null:
		_lbl_status.text = "正在删除 %d 株草（可 Ctrl+Z 撤销）..." % valid.size()
	_plugin.call(&"delete_grass_instances", _grass, valid)
	refresh(true)
	# 列表已重建、选中已清空：立刻把高亮环和状态栏同步到「未选中」
	_after_selection_changed()


func _copy_positions(entries: Array) -> void:
	if entries.is_empty():
		return
	var lines := PackedStringArray()
	for entry in entries:
		var pos: Vector3 = entry["pos"]
		lines.append("%.4f, %.4f, %.4f" % [pos.x, pos.y, pos.z])
	DisplayServer.clipboard_set("\n".join(lines))
	_set_status("已复制 %d 行坐标到剪贴板" % entries.size())


# --------------------------------------------------------------- 过滤

func _on_filter_text_changed(text: String) -> void:
	_filter_text = text.strip_edges().to_lower()
	_apply_filter()


func _apply_filter() -> void:
	if _tree == null:
		return
	for idx in _row_indices:
		var entry: Dictionary = _entries.get(idx, {})
		if entry.is_empty():
			continue
		var item: TreeItem = entry["item"]
		if item == null or not is_instance_valid(item):
			continue
		if _filter_text.is_empty():
			item.visible = true
			continue
		var pos: Vector3 = entry["pos"]
		item.visible = ("%d %.3f %.3f %.3f" % [idx, pos.x, pos.y, pos.z]).contains(_filter_text)


# --------------------------------------------------------- 草地节点下拉框

func _on_grass_menu_about_to_popup() -> void:
	var popup := _btn_grass.get_popup()
	popup.clear()
	popup.add_item("刷新节点列表", -1)
	popup.add_separator()
	var nodes := _collect_grass_nodes()
	for i in range(nodes.size()):
		popup.add_item(_grass_label(nodes[i]), i)
		if nodes[i] == _grass:
			popup.set_item_checked(popup.get_item_index(i), true)


func _on_grass_menu_pressed(id: int) -> void:
	if id < 0:
		refresh(true)
		return
	var nodes := _collect_grass_nodes()
	if id >= nodes.size():
		return
	var node = nodes[id]
	set_grass(node)
	if node is Node and (node as Node).is_inside_tree():
		EditorInterface.get_selection().add_node(node)


func _grass_label(node) -> String:
	if node == null or not is_instance_valid(node):
		return "?"
	var path := String(node.name)
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null and scene_root != node and scene_root.is_ancestor_of(node):
		path = String(scene_root.get_path_to(node))
	var count := 0
	if node.multimesh != null:
		count = node.multimesh.instance_count
	return "%s  (%d)" % [path, count]


func _collect_grass_nodes() -> Array:
	var out: Array = []
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		_collect_grass_nodes_recursive(scene_root, out)
	return out


func _collect_grass_nodes_recursive(node: Node, out: Array) -> void:
	if node.has_meta(&"SimpleGrassTextured"):
		out.append(node)
	for child in node.get_children():
		_collect_grass_nodes_recursive(child, out)


# --------------------------------------------------------------- 杂项

func _on_refresh_pressed() -> void:
	refresh(true)


func _on_refresh_delayed() -> void:
	refresh(false)


func _on_grow_timer_timeout() -> void:
	if _grass == null:
		return
	if not is_instance_valid(_grass):
		refresh(true)
		return
	var count := 0
	if _grass.multimesh != null:
		count = _grass.multimesh.instance_count
	if count != _total:
		refresh(true)


func _on_theme_changed() -> void:
	if _btn_grass == null:
		return
	var icon := load("res://addons/simplegrasstextured/sgt_icon.svg")
	if icon != null:
		_btn_grass.icon = icon

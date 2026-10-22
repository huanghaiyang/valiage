@tool
extends VBoxContainer
## 属性页：过滤框 + 属性树 + 只读值详情。
##
## 关于「懒加载」的引擎事实（4.7.2 实测）：Godot 4 的 Tree **只有 item_collapsed
## 信号，没有 item_expanded**（那是 Godot 3 的 API），所以拿不到「展开」事件，
## 也就无法做「展开时才建子项」。
##
## 这里改用**限量建树**：每层最多 MAX_CHILDREN 项、最深 MAX_DEPTH 层、
## 整棵树最多 MAX_TOTAL_ITEMS 个节点；超出的部分挂一个「… 还有 N 项」哑节点。
## 并且在调用 child_entries() 之前先把超大集合截断，避免解析模块为几十万项
## 顶点数组一次性造几十万个字典。实测 6.3 MB 的 ArrayMesh 全树仅几百个节点。

## 用 preload 常量引用兄弟脚本（**不要**依赖 class_name 全局表：
## 无头 --script 与编辑器首次启用时全局类名表可能还没扫描出来）。
const UIKit := preload("res://addons/res_inspector/ui/ui_kit.gd")
const FmtUtil := preload("res://addons/res_inspector/ui/fmt_util.gd")

## 每个节点下最多列多少项
const MAX_CHILDREN := 200
## 最多展开到第几层（顶层属性 = 第 0 层）
const MAX_DEPTH := 4
## 整棵树最多多少个节点（硬上限，防止病态资源把界面拖死）
const MAX_TOTAL_ITEMS := 4000

var _built := false
var _fmt = null
var _info: Dictionary = {}
var _unavailable := ""

var _hint: Label = null
var _filter_edit: LineEdit = null
var _count_label: Label = null
var _tree: Tree = null
var _detail_title: Label = null
var _detail: TextEdit = null

## 行 → 属性条目（值详情用）
var _entries: Dictionary = {}
## 已建节点数（限量用）
var _item_count := 0


func _ready() -> void:
	_ensure_built()


func set_info(info: Dictionary, fmt) -> void:
	_fmt = fmt
	_info = info if info is Dictionary else {}
	_unavailable = ""
	_rebuild_top()


func set_unavailable(reason: String) -> void:
	_fmt = null
	_info = {}
	_unavailable = reason
	_rebuild_top()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)

	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	var lbl := Label.new()
	lbl.text = "过滤："
	top.add_child(lbl)
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "按属性名过滤（留空显示全部）"
	_filter_edit.clear_button_enabled = true
	_filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_filter_edit.text_changed.connect(_on_filter_changed)
	top.add_child(_filter_edit)
	_count_label = UIKit.hint("—", UIKit.DIM)
	_count_label.custom_minimum_size = Vector2(220, 0)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	top.add_child(_count_label)
	add_child(top)

	_hint = UIKit.hint("尚未打开文件。", UIKit.DIM)
	add_child(_hint)

	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 640
	add_child(split)

	_tree = Tree.new()
	_tree.columns = 3
	_tree.set_column_title(0, "属性")
	_tree.set_column_title(1, "类型")
	_tree.set_column_title(2, "值摘要")
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(420, 300)
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_expand(2, true)
	_tree.set_column_custom_minimum_width(1, 110)
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_activated.connect(_on_item_activated)
	split.add_child(_tree)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_title = UIKit.hint("属性详情", UIKit.DIM)
	right.add_child(_detail_title)
	_detail = UIKit.mono_text_edit(280)
	_detail.custom_minimum_size = Vector2(320, 280)
	right.add_child(_detail)
	split.add_child(right)


func _on_filter_changed(_new_text: String) -> void:
	_rebuild_top()


func _rebuild_top() -> void:
	_ensure_built()
	_tree.clear()
	_entries.clear()
	_item_count = 0
	if _detail != null:
		_detail.text = ""
	if _detail_title != null:
		_detail_title.text = "属性详情"

	if _info.is_empty():
		_set_hint(_unavailable if _unavailable != "" else "尚未打开文件。",
				UIKit.WARN if _unavailable != "" else UIKit.DIM)
		if _count_label != null:
			_count_label.text = "—"
		return

	var res: Resource = _info.get("resource", null)
	if res == null:
		var why := "没有可展开的资源对象"
		var err := str(_info.get("load_error", ""))
		if err == "":
			err = str(_info.get("error", ""))
		if err != "":
			why += "（" + err + "）"
		_set_hint(why, UIKit.WARN)
		if _count_label != null:
			_count_label.text = "0 项"
		return

	var filt := _filter_edit.text.strip_edges() if _filter_edit != null else ""
	var entries: Array = FmtUtil.property_entries(_fmt, res, filt)
	_set_hint(("没有匹配「%s」的属性" % filt) if filt != "" else "该资源没有可见属性", UIKit.DIM)
	if _hint != null:
		_hint.visible = entries.is_empty()
	if _count_label != null:
		_count_label.text = "%d 项属性%s" % [entries.size(), "（已过滤）" if filt != "" else ""]

	var root := _tree.create_item()
	for e in entries:
		if not (e is Dictionary):
			continue
		if _item_count >= MAX_TOTAL_ITEMS:
			_add_truncation_row(root, "… 属性过多，已达节点上限 %d" % MAX_TOTAL_ITEMS, 0)
			break
		_make_item(root, e, 0)


func _set_hint(text: String, col: Color) -> void:
	if _hint == null:
		return
	_hint.text = text
	_hint.add_theme_color_override("font_color", col)
	_hint.visible = true


## 建一行（含其子树）
func _make_item(parent: TreeItem, e: Dictionary, depth: int) -> void:
	if _tree == null or _item_count >= MAX_TOTAL_ITEMS:
		return
	var it := _tree.create_item(parent)
	_item_count += 1
	var name_text := str(e.get("name", "?"))
	it.set_text(0, name_text)
	it.set_text(1, str(e.get("type_name", "")))
	it.set_text(2, str(e.get("value_text", "")))
	var rp := str(e.get("resource_path", ""))
	if rp != "":
		it.set_tooltip_text(0, "资源：" + rp)
	if bool(e.get("read_only", false)):
		it.set_custom_color(0, UIKit.DIM)
	_entries[it] = e

	if not bool(e.get("expandable", false)):
		return
	var value = e.get("value", null)
	if depth >= MAX_DEPTH:
		_add_truncation_row(it, "… 已到最大展开层数（%d）" % MAX_DEPTH, depth)
		return
	var got := _children_of(value)
	var kids: Array = got["entries"]
	var total: int = int(got["total"])
	if kids.is_empty():
		return
	var shown := 0
	for k in kids:
		if not (k is Dictionary):
			continue
		if shown >= MAX_CHILDREN or _item_count >= MAX_TOTAL_ITEMS:
			break
		_make_item(it, k, depth + 1)
		shown += 1
	if total > shown:
		_add_truncation_row(it, "… 还有 %d 项未显示（共 %d 项）" % [total - shown, total], depth)


## 取子项：先按 MAX_CHILDREN 截断原值，再交给解析模块，
## 避免「几万项数组 → 几万个条目字典」的瞬时开销。
func _children_of(value) -> Dictionary:
	match typeof(value):
		TYPE_ARRAY:
			var arr: Array = value
			var total := arr.size()
			if total <= MAX_CHILDREN:
				return {"entries": FmtUtil.child_entries(_fmt, arr), "total": total}
			return {"entries": FmtUtil.child_entries(_fmt, arr.slice(0, MAX_CHILDREN)), "total": total}
		TYPE_DICTIONARY:
			var d: Dictionary = value
			var total_d := d.size()
			if total_d <= MAX_CHILDREN:
				return {"entries": FmtUtil.child_entries(_fmt, d), "total": total_d}
			var sub := {}
			var n := 0
			for k in d.keys():
				sub[k] = d[k]
				n += 1
				if n >= MAX_CHILDREN:
					break
			return {"entries": FmtUtil.child_entries(_fmt, sub), "total": total_d}
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, \
		TYPE_PACKED_VECTOR4_ARRAY:
			var total_p: int = int(value.size())
			if total_p <= MAX_CHILDREN:
				return {"entries": FmtUtil.child_entries(_fmt, value), "total": total_p}
			return {"entries": FmtUtil.child_entries(_fmt, value.slice(0, MAX_CHILDREN)), "total": total_p}
		TYPE_OBJECT:
			var ents: Array = FmtUtil.child_entries(_fmt, value)
			return {"entries": ents, "total": ents.size()}
		_:
			return {"entries": [], "total": 0}


func _add_truncation_row(parent: TreeItem, note: String, _depth: int) -> void:
	if _tree == null:
		return
	var it := _tree.create_item(parent)
	_item_count += 1
	it.set_text(0, "…")
	it.set_text(2, note)
	it.set_custom_color(0, UIKit.DIM)
	it.set_selectable(0, false)
	it.set_selectable(1, false)
	it.set_selectable(2, false)


func _on_item_activated() -> void:
	if _tree == null:
		return
	var it := _tree.get_selected()
	if it == null:
		return
	it.set_collapsed(false)


func _on_item_selected() -> void:
	if _tree == null:
		return
	var it := _tree.get_selected()
	if it == null:
		return
	_show_detail(it)


func _show_detail(item: TreeItem) -> void:
	if not _entries.has(item):
		if _detail_title != null:
			_detail_title.text = "属性详情"
		if _detail != null:
			_detail.text = "（该行没有属性条目，例如截断提示行）"
		return
	var e: Dictionary = _entries[item]
	var lines := PackedStringArray()
	lines.append("名称：" + str(e.get("name", "")))
	lines.append("类型：%s（Variant.Type = %d）" % [str(e.get("type_name", "")), int(e.get("type", 0))])
	lines.append("可展开：" + ("是" if bool(e.get("expandable", false)) else "否"))
	lines.append("只读：" + ("是" if bool(e.get("read_only", false)) else "否"))
	var rp := str(e.get("resource_path", ""))
	if rp != "":
		lines.append("资源路径：" + rp)
	lines.append("")
	lines.append("值：")
	lines.append(_safe_value_text(e.get("value", null)))
	if _detail != null:
		_detail.text = "\n".join(lines)
	if _detail_title != null:
		_detail_title.text = "属性详情 —— " + str(e.get("name", ""))


## 值详情：集合太大时不展开成文本（避免 str() 巨大数组时卡死界面）
func _safe_value_text(value) -> String:
	match typeof(value):
		TYPE_ARRAY:
			var arr: Array = value
			if arr.size() > 1000:
				return "（集合过大：%d 项，请在左侧树中逐级展开查看）" % arr.size()
		TYPE_DICTIONARY:
			var d: Dictionary = value
			if d.size() > 1000:
				return "（字典过大：%d 项，请在左侧树中逐级展开查看）" % d.size()
	return FmtUtil.value_text(_fmt, value, 8000)


# ---------------------------------------------------------------------------
# 供自测使用
# ---------------------------------------------------------------------------

func get_item_count() -> int:
	return _item_count


func get_entry_count() -> int:
	return _entries.size()


## 设置过滤词并立即重建（程序化设置 LineEdit.text 不会触发 text_changed，所以单独提供）
func set_filter(text: String) -> void:
	if _filter_edit == null:
		return
	_filter_edit.text = text
	_rebuild_top()


func get_filter() -> String:
	return _filter_edit.text if _filter_edit != null else ""


## 选中第一行并刷新值详情（自测用：验证详情面板这条路径不报错）
func select_first_item() -> void:
	if _tree == null:
		return
	var root := _tree.get_root()
	if root == null or root.get_child_count() == 0:
		return
	var first := root.get_child(0)
	first.select(0)
	_tree.scroll_to_item(first)
	_show_detail(first)


func get_detail_text() -> String:
	return _detail.text if _detail != null else ""

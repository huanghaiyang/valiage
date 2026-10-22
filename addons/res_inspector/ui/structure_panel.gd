@tool
extends VBoxContainer
## 结构页：头部字段 / 字符串表 / 外部依赖 / 内部子资源 / 属性键（Tree 三列）。
## 列表都有行数上限，避免超大文件把控件塞满。

const UIKit := preload("res://addons/res_inspector/ui/ui_kit.gd")
const FmtUtil := preload("res://addons/res_inspector/ui/fmt_util.gd")

const MAX_STRING_ROWS := 3000
const MAX_LIST_ROWS := 2000
const MAX_PROP_ROWS := 2000

var _built := false
var _fmt = null
var _info: Dictionary = {}
var _unavailable := ""

var _head_label: Label = null
var _tree: Tree = null


func _ready() -> void:
	_ensure_built()


func set_info(info: Dictionary, fmt) -> void:
	_fmt = fmt
	_info = info if info is Dictionary else {}
	_unavailable = ""
	_rebuild()


func set_unavailable(reason: String) -> void:
	_fmt = null
	_info = {}
	_unavailable = reason
	_rebuild()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)

	_head_label = UIKit.hint("尚未打开文件。", UIKit.DIM)
	add_child(_head_label)

	_tree = Tree.new()
	_tree.columns = 3
	_tree.set_column_title(0, "项")
	_tree.set_column_title(1, "值 / 路径")
	_tree.set_column_title(2, "附加信息")
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size = Vector2(0, 280)
	_tree.set_column_expand(0, false)
	_tree.set_column_expand(1, true)
	_tree.set_column_expand(2, true)
	_tree.set_column_custom_minimum_width(0, 260)
	_tree.set_column_custom_minimum_width(2, 220)
	add_child(_tree)


func _rebuild() -> void:
	_ensure_built()
	_tree.clear()
	var root := _tree.create_item()

	if _info.is_empty():
		_head_label.text = _unavailable if _unavailable != "" else "尚未打开文件。"
		_head_label.add_theme_color_override("font_color", UIKit.WARN if _unavailable != "" else UIKit.DIM)
		return

	var kind := str(_info.get("format", ""))
	var binary: Dictionary = _info.get("binary", {})
	var text: Dictionary = _info.get("text", {})
	var surface_count := 0
	var msg := ""
	if kind == "binary":
		surface_count = int(binary.get("strings", PackedStringArray()).size()) \
				+ int(binary.get("external", []).size()) + int(binary.get("internal", []).size())
		msg = "二进制 RSRC ｜ %s ｜ 字符串 %d 条 ｜ 外部依赖 %d 项 ｜ 内部子资源 %d 项" % [
				FmtUtil.human_size(_fmt, int(_info.get("size", 0))),
				int(binary.get("strings", PackedStringArray()).size()),
				int(binary.get("external", []).size()),
				int(binary.get("internal", []).size())]
	elif kind == "text":
		surface_count = int(text.get("external", []).size()) + int(text.get("sub_resources", []).size())
		msg = "文本格式 ｜ %s ｜ 外部依赖 %d 项 ｜ 子资源 %d 项 ｜ 行数 %d" % [
				FmtUtil.human_size(_fmt, int(_info.get("size", 0))),
				int(text.get("external", []).size()),
				int(text.get("sub_resources", []).size()),
				int(text.get("line_count", 0))]
	else:
		msg = "未能判定容器格式，只能列出资源属性键。"
	_head_label.text = msg
	_head_label.add_theme_color_override("font_color", UIKit.DIM)

	if kind == "binary":
		_add_binary_sections(root, binary)
	elif kind == "text":
		_add_text_sections(root, text)
	_add_property_section(root)

	# 默认把「头部字段」展开、其它段落折叠，一眼能看到关键信息
	for i in root.get_child_count():
		var it: TreeItem = root.get_child(i)
		it.set_collapsed(i != 0)


func _add_binary_sections(root: TreeItem, b: Dictionary) -> void:
	var head := _section(root, "头部字段", -1)
	var flags := int(b.get("flags_guess", -1))
	_row(head, "魔数", str(b.get("magic", "RSRC")), "")
	_row(head, "字节序", "大端" if bool(b.get("big_endian", false)) else "小端", "")
	_row(head, "实数精度", "real64" if bool(b.get("use_real64", false)) else "real32", "")
	_row(head, "格式版本", str(b.get("format_version", "—")), "")
	_row(head, "资源类型", str(b.get("type", "")), "")
	_row(head, "UID", str(b.get("uid", "无")), "")
	_row(head, "flags 推测", "0x%08X" % flags if flags >= 0 else "未能识别", "值 -1 表示未识别")
	_row(head, "未识别头部尾部", "%d 字节" % int(b.get("header_tail_offset", 0)),
			_hex_preview(b.get("header_tail", PackedByteArray())))
	_row(head, "字符串表偏移", str(int(b.get("string_table_offset", 0))), "")
	_row(head, "根属性数据偏移", str(int(b.get("data_offset", 0))), "")

	var strings = b.get("strings", PackedStringArray())
	var s_sec := _section(root, "字符串表", strings.size())
	var limit: int = mini(strings.size(), MAX_STRING_ROWS)
	for i in limit:
		_row(s_sec, "#%d" % i, str(strings[i]), "")
	_add_overflow_row(s_sec, strings.size(), limit, "条字符串")

	var ext = b.get("external", [])
	var e_sec := _section(root, "外部依赖", ext.size())
	var el: int = mini(ext.size(), MAX_LIST_ROWS)
	for i in el:
		if not (ext[i] is Dictionary):
			continue
		var e: Dictionary = ext[i]
		var uid := str(e.get("uid", ""))
		_row(e_sec, "#%d %s" % [int(e.get("index", i)), str(e.get("type", ""))],
				str(e.get("path", "")), "UID %s" % uid if uid != "" else "")
	_add_overflow_row(e_sec, ext.size(), el, "项外部依赖")

	var internal = b.get("internal", [])
	var i_sec := _section(root, "内部子资源", internal.size())
	var il: int = mini(internal.size(), MAX_LIST_ROWS)
	for i in il:
		if not (internal[i] is Dictionary):
			continue
		var ie: Dictionary = internal[i]
		_row(i_sec, "#%d" % int(ie.get("index", i)), str(ie.get("path", "")),
				"偏移 %d" % int(ie.get("offset", 0)))
	_add_overflow_row(i_sec, internal.size(), il, "项子资源")


func _add_text_sections(root: TreeItem, t: Dictionary) -> void:
	var head := _section(root, "头部字段", -1)
	_row(head, "头标签", str(t.get("header_tag", "")), "")
	_row(head, "声明类型", str(t.get("type", "")), "")
	_row(head, "脚本类", str(t.get("script_class", "")), "")
	_row(head, "UID", str(t.get("uid", "无")), "")
	_row(head, "load_steps", str(t.get("load_steps", 0)), "")
	_row(head, "format 版本", str(t.get("format", 0)), "")
	_row(head, "根属性数", str(t.get("root_properties", 0)), "")
	_row(head, "行数", str(t.get("line_count", 0)), "")

	var ext = t.get("external", [])
	var e_sec := _section(root, "外部依赖", ext.size())
	var el: int = mini(ext.size(), MAX_LIST_ROWS)
	for i in el:
		if not (ext[i] is Dictionary):
			continue
		var e: Dictionary = ext[i]
		var uid := str(e.get("uid", ""))
		_row(e_sec, str(e.get("id", "#%d" % i)), str(e.get("path", "")),
				"%s%s" % [str(e.get("type", "")), (" ｜ UID " + uid) if uid != "" else ""])
	_add_overflow_row(e_sec, ext.size(), el, "项外部依赖")

	var subs = t.get("sub_resources", [])
	var s_sec := _section(root, "子资源", subs.size())
	var sl: int = mini(subs.size(), MAX_LIST_ROWS)
	for i in sl:
		if not (subs[i] is Dictionary):
			continue
		var s: Dictionary = subs[i]
		_row(s_sec, str(s.get("id", "#%d" % i)), str(s.get("type", "")),
				"属性 %d 条" % int(s.get("properties", 0)))
	_add_overflow_row(s_sec, subs.size(), sl, "项子资源")


func _add_property_section(root: TreeItem) -> void:
	var res: Resource = _info.get("resource", null)
	var entries: Array = []
	if res != null:
		entries = FmtUtil.property_entries(_fmt, res, "")
	var sec := _section(root, "属性键", entries.size())
	if entries.is_empty():
		_row(sec, "（无）", "资源对象未载入或没有可见属性", "")
		return
	var limit: int = mini(entries.size(), MAX_PROP_ROWS)
	for i in limit:
		var e = entries[i]
		if not (e is Dictionary):
			continue
		# 值摘要直接用解析模块给出的单行文本，避免对大集合再算一次
		_row(sec, str(e.get("name", "?")), str(e.get("type_name", "")),
				str(e.get("value_text", "")))
	_add_overflow_row(sec, entries.size(), limit, "条属性")


# ---------------------------------------------------------------------------
# Tree 小工具
# ---------------------------------------------------------------------------

func _section(parent: TreeItem, title_text: String, count: int) -> TreeItem:
	var it := _tree.create_item(parent)
	it.set_text(0, title_text)
	it.set_text(1, "" if count < 0 else "%d 项" % count)
	it.set_custom_color(0, UIKit.ACCENT)
	for c in 3:
		it.set_selectable(c, false)
	return it


func _row(parent: TreeItem, a: String, b: String = "", c: String = "") -> void:
	var it := _tree.create_item(parent)
	it.set_text(0, a)
	it.set_text(1, b)
	it.set_text(2, c)
	it.set_tooltip_text(1, b)


func _add_overflow_row(parent: TreeItem, total: int, shown: int, unit: String) -> void:
	if total <= shown:
		return
	var it := _tree.create_item(parent)
	it.set_text(0, "…")
	it.set_text(1, "共 %d %s，仅显示前 %d" % [total, unit, shown])
	for c in 3:
		it.set_selectable(c, false)
	it.set_custom_color(0, UIKit.DIM)


static func _hex_preview(b) -> String:
	if not (b is PackedByteArray):
		return ""
	var arr: PackedByteArray = b
	if arr.is_empty():
		return ""
	var lim: int = mini(arr.size(), 16)
	var parts := PackedStringArray()
	for i in lim:
		parts.append("%02X" % arr[i])
	var s := " ".join(parts)
	if arr.size() > lim:
		s += " …"
	return s


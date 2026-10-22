@tool
extends VBoxContainer
## 原始页：分页十六进制视图（左）+ 可搜索 ASCII 串列表（右）。
##
## 大文件友好：只按偏移读当前页（默认 4 KB），ASCII 扫描也是分块读，
## 任何地方都不会把整包字节一次性灌进控件。

const UIKit := preload("res://addons/res_inspector/ui/ui_kit.gd")
const FmtUtil := preload("res://addons/res_inspector/ui/fmt_util.gd")

## 可选页大小（默认 4 KB，契约要求的最小值）
const PAGE_SIZES := [1024, 2048, 4096, 8192, 16384]
const DEFAULT_PAGE_INDEX := 2
const BYTES_PER_ROW := 16

## ASCII 串扫描：至少几个可打印字符才算一条
const MIN_STR_LEN := 5
## 最多收集多少条结果
const MAX_STR_RESULTS := 400
## 打开文件时先扫多少字节（不阻塞打开大文件），点「搜索」再扫全文
const INITIAL_SCAN_BYTES := 512 * 1024
## 全文扫描的字节上限（32 MB，足够覆盖 6.3 MB 的资源）
const MAX_SCAN_BYTES := 32 * 1024 * 1024
const CHUNK := 65536

var _built := false
var _fmt = null
var _info: Dictionary = {}
var _unavailable := ""

var _path := ""
var _total := 0
var _page_size := 4096
var _page := 0

var _hex: TextEdit = null
var _page_label: Label = null
var _offset_edit: LineEdit = null
var _size_option: OptionButton = null
var _prev_btn: Button = null
var _next_btn: Button = null
var _str_tree: Tree = null
var _search_edit: LineEdit = null
var _str_hint: Label = null


func _ready() -> void:
	_ensure_built()


func set_info(info: Dictionary, fmt) -> void:
	_ensure_built()
	_fmt = fmt
	_info = info if info is Dictionary else {}
	_unavailable = ""
	_path = str(_info.get("path", ""))
	if _path == "":
		_path = str(_info.get("abs_path", ""))
	_total = int(_info.get("size", 0))
	_page = 0
	_render_page()
	_scan_and_fill("")


func set_unavailable(reason: String) -> void:
	_ensure_built()
	_fmt = null
	_info = {}
	_unavailable = reason
	_path = ""
	_total = 0
	_page = 0
	_hex.text = reason
	_page_label.text = "—"
	_str_tree.clear()
	_str_hint.text = reason
	_str_hint.add_theme_color_override("font_color", UIKit.WARN)


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 4)

	# ---- 分页条 ----
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)
	var size_lbl := Label.new()
	size_lbl.text = "每页"
	bar.add_child(size_lbl)
	_size_option = OptionButton.new()
	for ps in PAGE_SIZES:
		_size_option.add_item("%d 字节" % int(ps))
	_size_option.selected = DEFAULT_PAGE_INDEX
	_page_size = int(PAGE_SIZES[DEFAULT_PAGE_INDEX])
	_size_option.item_selected.connect(_on_page_size_selected)
	bar.add_child(_size_option)
	_prev_btn = _bar_button(bar, "上一页", _on_prev_pressed, "查看上一页（Page Up 也可）")
	_next_btn = _bar_button(bar, "下一页", _on_next_pressed, "查看下一页（Page Down 也可）")
	_page_label = UIKit.hint("—", UIKit.DIM)
	_page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(_page_label)
	var jump_lbl := Label.new()
	jump_lbl.text = "跳转偏移"
	bar.add_child(jump_lbl)
	_offset_edit = LineEdit.new()
	_offset_edit.placeholder_text = "0x1F00 或 7936"
	_offset_edit.custom_minimum_size = Vector2(140, 0)
	_offset_edit.text_submitted.connect(_on_offset_submitted)
	bar.add_child(_offset_edit)
	_bar_button(bar, "跳转", _on_jump_pressed, "跳到指定字节偏移（支持 0x 前缀）")

	# ---- 左十六进制 / 右 ASCII 串 ----
	var split := HSplitContainer.new()
	split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 760
	add_child(split)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 2)
	split.add_child(left)
	left.add_child(UIKit.hint("十六进制视图（偏移 · 16 字节 · ASCII）", UIKit.DIM))
	_hex = UIKit.mono_text_edit(320)
	_hex.text = "尚未打开文件。"
	left.add_child(_hex)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 2)
	split.add_child(right)
	right.add_child(UIKit.hint("ASCII 串（≥%d 个连续可打印字符，双击跳到该偏移）" % MIN_STR_LEN, UIKit.DIM))
	var sbar := HBoxContainer.new()
	sbar.add_theme_constant_override("separation", 6)
	right.add_child(sbar)
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = "搜索串（留空 = 列出全部）"
	_search_edit.clear_button_enabled = true
	_search_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search_edit.text_submitted.connect(_on_search_submitted)
	sbar.add_child(_search_edit)
	_bar_button(sbar, "搜索", _on_search_pressed, "按关键词扫描字符串（会扫描全文）")
	_str_hint = UIKit.hint("—", UIKit.DIM)
	right.add_child(_str_hint)

	_str_tree = Tree.new()
	_str_tree.columns = 2
	_str_tree.set_column_title(0, "偏移")
	_str_tree.set_column_title(1, "字符串")
	_str_tree.column_titles_visible = true
	_str_tree.hide_root = true
	_str_tree.select_mode = Tree.SELECT_ROW
	_str_tree.custom_minimum_size = Vector2(280, 300)
	_str_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_str_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_str_tree.set_column_expand(0, false)
	_str_tree.set_column_custom_minimum_width(0, 96)
	_str_tree.item_activated.connect(_on_string_activated)
	right.add_child(_str_tree)


func _bar_button(bar: HBoxContainer, text: String, cb: Callable, tip: String = "") -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.pressed.connect(cb)
	bar.add_child(b)
	return b


# ---------------------------------------------------------------------------
# 分页
# ---------------------------------------------------------------------------

func _on_page_size_selected(index: int) -> void:
	if index < 0 or index >= PAGE_SIZES.size():
		return
	var start := _page * _page_size
	_page_size = int(PAGE_SIZES[index])
	_page = floori(float(start) / float(_page_size))
	_render_page()


func _on_prev_pressed() -> void:
	if _page > 0:
		_page -= 1
		_render_page()


func _on_next_pressed() -> void:
	var pages := _page_count()
	if _page + 1 < pages:
		_page += 1
		_render_page()


func _on_offset_submitted(text: String) -> void:
	_jump_to_text(text)


func _on_jump_pressed() -> void:
	_jump_to_text(_offset_edit.text)


func _page_count() -> int:
	if _total <= 0 or _page_size <= 0:
		return 0
	return int(ceil(float(_total) / float(_page_size)))


func _render_page() -> void:
	if _total <= 0:
		_hex.text = "（没有可显示的数据：文件为空或未打开）"
		_page_label.text = "—"
		return
	var pages := maxi(1, _page_count())
	_page = clampi(_page, 0, pages - 1)
	var start := _page * _page_size
	var length: int = mini(_page_size, _total - start)
	var data := FmtUtil.read_slice(_fmt, _path, start, length)
	if data.is_empty() and length > 0:
		_hex.text = "（读取失败：无法按偏移 %d 读取 %d 字节）" % [start, length]
		_page_label.text = "第 %d/%d 页 ｜ 读取失败" % [_page + 1, pages]
		return
	_hex.text = _format_hex(data, start)
	_hex.set_caret_line(0)
	_page_label.text = "第 %d/%d 页 ｜ 偏移 0x%X–0x%X ｜ %d 字节" % [
		_page + 1, pages, start, start + data.size(), data.size()]


func _jump_to_text(text: String) -> void:
	var off := _parse_offset(text)
	if off < 0:
		_page_label.text = "跳转失败：无法解析偏移「%s」" % text
		return
	if _total <= 0:
		return
	_goto_offset(clampi(off, 0, _total - 1))


func _goto_offset(offset: int) -> void:
	if offset < 0 or _total <= 0:
		return
	_offset_edit.text = "0x%X" % offset
	_page = floori(float(offset) / float(_page_size))
	_render_page()


static func _parse_offset(text: String) -> int:
	var s := text.strip_edges().replace(" ", "").replace("_", "")
	if s == "":
		return -1
	var neg := false
	if s.begins_with("-"):
		neg = true
		s = s.substr(1)
	if s.begins_with("0x") or s.begins_with("0X"):
		var hex_part := s.substr(2)
		if hex_part == "" or not hex_part.is_valid_hex_number():
			return -1
		return -hex_part.hex_to_int() if neg else hex_part.hex_to_int()
	if s.is_valid_int():
		var v := s.to_int()
		return -v if neg else v
	# 退让：当作纯十六进制（很多用户直接输入 1F00）
	if s.is_valid_hex_number():
		var hv := s.hex_to_int()
		return -hv if neg else hv
	return -1


## 一页字节 → 十六进制文本（偏移列 + 16 字节 + ASCII 列）
static func _format_hex(data: PackedByteArray, base: int) -> String:
	var n := data.size()
	if n <= 0:
		return ""
	var lines := PackedStringArray()
	var i := 0
	while i < n:
		var parts := PackedStringArray()
		parts.append("%08X" % (base + i))
		parts.append("  ")
		var j := 0
		while j < BYTES_PER_ROW:
			if i + j < n:
				parts.append("%02X" % data[i + j])
			else:
				parts.append("  ")
			parts.append(" ")
			if j == 7:
				parts.append(" ")
			j += 1
		parts.append(" |")
		var ascii := ""
		j = 0
		while j < BYTES_PER_ROW and i + j < n:
			var b: int = data[i + j]
			ascii += char(b) if (b >= 0x20 and b <= 0x7E) else "."
			j += 1
		parts.append(ascii + "|")
		lines.append("".join(parts))
		i += BYTES_PER_ROW
	return "\n".join(lines)


# ---------------------------------------------------------------------------
# ASCII 串扫描
# ---------------------------------------------------------------------------

func _on_search_pressed() -> void:
	_scan_and_fill(_search_edit.text)


func _on_search_submitted(text: String) -> void:
	_scan_and_fill(text)


func _scan_and_fill(query: String) -> void:
	_str_tree.clear()
	var root := _str_tree.create_item()
	_str_hint.add_theme_color_override("font_color", UIKit.DIM)
	if _path == "" or _total <= 0:
		_str_hint.text = _unavailable if _unavailable != "" else "没有可扫描的文件。"
		return
	var full := query.strip_edges() != ""
	var limit: int = MAX_SCAN_BYTES if full else mini(_total, INITIAL_SCAN_BYTES)
	var results: Array = []
	var scanned := _scan_runs(limit, query.strip_edges().to_lower(), results)
	_fill_string_tree(root, results)
	if scanned <= 0:
		_str_hint.text = "无法读取文件字节，ASCII 扫描已跳过。"
		_str_hint.add_theme_color_override("font_color", UIKit.WARN)
		return
	var hit_cap := results.size() >= MAX_STR_RESULTS
	var suffix := "（已达上限 %d 条，请用更具体的关键词）" % MAX_STR_RESULTS if hit_cap else ""
	if full:
		_str_hint.text = "全文扫描 %.2f MB，命中 %d 条%s" % [float(scanned) / 1048576.0, results.size(), suffix]
	else:
		_str_hint.text = "已扫描前 %.2f MB / 共 %.2f MB，命中 %d 条%s；点「搜索」可扫全文（最多 %d MB）" % [
			float(scanned) / 1048576.0, float(_total) / 1048576.0, results.size(), suffix, MAX_SCAN_BYTES / 1048576]


## 分块扫描可打印 ASCII 串；返回实际扫描字节数
func _scan_runs(limit_bytes: int, query_lower: String, results: Array) -> int:
	var f := FileAccess.open(_path, FileAccess.READ)
	if f == null:
		return 0
	var scanned := 0
	var run_start := -1
	var run_bytes := PackedByteArray()
	while scanned < limit_bytes and results.size() < MAX_STR_RESULTS:
		var chunk := f.get_buffer(CHUNK)
		if chunk.is_empty():
			break
		if scanned + chunk.size() > limit_bytes:
			chunk = chunk.slice(0, limit_bytes - scanned)
		var n := chunk.size()
		for i in n:
			var b: int = chunk[i]
			if b >= 0x20 and b <= 0x7E:
				if run_start < 0:
					run_start = scanned + i
				run_bytes.append(b)
			elif run_start >= 0:
				_consider_run(results, run_start, run_bytes, query_lower)
				run_start = -1
				run_bytes.clear()
		scanned += n
	if run_start >= 0:
		_consider_run(results, run_start, run_bytes, query_lower)
	f.close()
	return scanned


static func _consider_run(results: Array, start: int, bytes: PackedByteArray, query_lower: String) -> void:
	if bytes.size() < MIN_STR_LEN:
		return
	var s := bytes.get_string_from_ascii()
	if query_lower != "" and not s.to_lower().contains(query_lower):
		return
	results.append({"offset": start, "text": s})


func _fill_string_tree(root: TreeItem, results: Array) -> void:
	if results.is_empty():
		var it := _str_tree.create_item(root)
		it.set_text(0, "（无）")
		it.set_text(1, "没有找到符合条件的可打印串")
		it.set_custom_color(0, UIKit.DIM)
		return
	for r in results:
		if not (r is Dictionary):
			continue
		var off := int(r.get("offset", 0))
		var text := str(r.get("text", ""))
		var it := _str_tree.create_item(root)
		it.set_text(0, "0x%08X" % off)
		it.set_text(1, UIKit.shorten(text, 240))
		it.set_tooltip_text(1, text)
		it.set_metadata(0, off)


func _on_string_activated() -> void:
	var it := _str_tree.get_selected()
	if it == null:
		return
	var off = it.get_metadata(0)
	if typeof(off) == TYPE_INT:
		_goto_offset(int(off))


# ---------------------------------------------------------------------------
# 供自测/脚本使用的只读状态
# ---------------------------------------------------------------------------

func get_page_index() -> int:
	return _page


func get_page_count() -> int:
	return _page_count()


func get_page_size() -> int:
	return _page_size


func get_current_offset() -> int:
	return _page * _page_size


func get_hex_text() -> String:
	return _hex.text if _hex != null else ""


## 翻页操作（供自测/脚本驱动，等价于点「上一页 / 下一页」）
func prev_page() -> void:
	_on_prev_pressed()


func next_page() -> void:
	_on_next_pressed()


## 跳到某字节偏移（与「跳转」按钮一致，支持越界裁剪）
func jump_to_offset(offset: int) -> void:
	if offset < 0 or _total <= 0:
		return
	_goto_offset(clampi(offset, 0, _total - 1))


func get_string_result_count() -> int:
	var root := _str_tree.get_root()
	if root == null:
		return 0
	return root.get_child_count()

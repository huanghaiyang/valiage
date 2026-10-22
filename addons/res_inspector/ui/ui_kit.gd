@tool
extends RefCounted
## 面板通用小工具：配色、标题、键值行、等宽字体、清空子节点。
## 纯 UI 工具，不含任何资源解析逻辑。

## 次要文字（键名、单位、提示）
const DIM := Color(0.62, 0.66, 0.72)
## 强调色（小节标题、链接）
const ACCENT := Color(0.52, 0.78, 0.98)
## 警告色（可恢复的问题）
const WARN := Color(0.96, 0.72, 0.32)
## 错误色（解析失败、文件缺失）
const BAD := Color(0.94, 0.45, 0.42)
## 正常色（成功状态）
const GOOD := Color(0.52, 0.86, 0.58)

## 等宽字体候选（十六进制/ASCII 视图用；找不到时引擎自动回退）
const MONO_FONTS := ["Consolas", "Cascadia Mono", "DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"]

## 键名列的固定宽度：中文键名 + 少量英文也能排齐
const KEY_WIDTH := 132.0


## 小节标题（带强调色）
static func title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", ACCENT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


## 提示 / 说明文字（自动换行，可指定颜色）
static func hint(text: String, col: Color = Color(0.62, 0.66, 0.72)) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_color_override("font_color", col)
	return l


## 键名（固定宽度、次要色、顶端对齐，方便和折行的值对齐）
static func key_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(KEY_WIDTH, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	l.add_theme_color_override("font_color", DIM)
	return l


## 值（可折行、可选中提示、悬停看全文）
static func value_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.tooltip_text = text
	return l


## 两列键值网格（面板整宽，所以默认两列横向舒展）
static func grid(cols: int = 2) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_theme_constant_override("h_separation", 14)
	g.add_theme_constant_override("v_separation", 4)
	return g


## 往网格里加一行「键 = 值」
static func add_row(g: GridContainer, key: String, value: String, col: Color = Color(1, 1, 1)) -> void:
	if g == null:
		return
	g.add_child(key_label(key))
	var v := value_label(value)
	v.add_theme_color_override("font_color", col)
	g.add_child(v)


## 单个占满整行的提示（放在网格里时只占第一列，内容仍会折行）
static func add_hint_row(g: GridContainer, text: String, col: Color = Color(0.62, 0.66, 0.72)) -> void:
	if g == null:
		return
	g.add_child(key_label(""))
	g.add_child(hint(text, col))


static func separator() -> HSeparator:
	return HSeparator.new()


## 等宽字体（十六进制视图、报告预览）
static func mono_font() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(MONO_FONTS)
	return f


## 只读的等宽多行文本控件
static func mono_text_edit(min_height: float = 300.0) -> TextEdit:
	var t := TextEdit.new()
	t.editable = false
	t.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	t.custom_minimum_size = Vector2(0, min_height)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.size_flags_vertical = Control.SIZE_EXPAND_FILL
	t.add_theme_font_override("font", mono_font())
	t.add_theme_font_size_override("font_size", 12)
	return t


## 清空并释放子节点（重建面板内容时用）
static func clear_children(n: Node) -> void:
	if n == null:
		return
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


## 字节数 → 人类可读（解析模块缺失时的兜底；有 ResFileFormat 时优先用它的）
static func human_size_local(bytes: int) -> String:
	if bytes < 0:
		return "-"
	if bytes < 1024:
		return "%d B" % bytes
	var kb := float(bytes) / 1024.0
	if kb < 1024.0:
		return "%.1f KB" % kb
	var mb := kb / 1024.0
	if mb < 1024.0:
		return "%.2f MB" % mb
	return "%.2f GB" % (mb / 1024.0)


## 一行文本截断（超出补省略号）
static func shorten(text: String, max_len: int) -> String:
	if max_len <= 0:
		return ""
	if text.length() <= max_len:
		return text
	return text.substr(0, maxi(0, max_len - 1)) + "…"

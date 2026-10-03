extends CanvasLayer
## 左下角量表：血量 / 魔法值 / 精力值 / 舒适度，紧贴**小地图右侧**。
##
## 为什么做成自动加载 + 运行时建 UI：
##   小地图是 main.tscn 里的节点（main.gd: @onready var _minimap = $Minimap），
##   但那个场景很大，为一个 HUD 去改它不合适；本项目也已有先例——
##   SpellCaster（自动加载）就是在运行时自己建法术圆盘的。
##
## 位置**按小地图脚本里的常量算**，不是写死数字：
##   小地图矩形 = x:[MARGIN, MARGIN+MAP_SIZE]，高度 MAP_SIZE，左下角对齐
##   量表贴在它右边 GAP 处，上下与小地图齐平
## 以后小地图改尺寸/边距，量表自动跟着走。
##
## 数据来源全部是**已有系统**：
##   魔法值 -> Mana  (scripts/spells/mana.gd)
##   其余三项 -> Vitals (scripts/vitals.gd)
## 刷新走"信号置脏 + 50ms 节流"，避免每帧给中文 Label 重新 shaping（小地图那边也有同款考量）。

const MinimapScript := preload("res://scripts/ui/minimap.gd")

const GAP := 10.0        ## 与小地图的水平间距
const WIDTH := 150.0     ## 量表宽度
const REFRESH_INTERVAL := 0.05
const BAR_STEPS := 1000.0   ## 进度条量程（用整数刻度避免浮点抖动）

var margin: float = MinimapScript.MARGIN
var map_size: float = MinimapScript.MAP_SIZE

const COLORS := {
	"hp": Color(0.86, 0.28, 0.28),
	"mana": Color(0.32, 0.56, 0.95),
	"stamina": Color(0.38, 0.78, 0.44),
	"comfort": Color(0.93, 0.73, 0.33),
}

var _bars := {}
var _values := {}
var _dirty := true
var _timer := 0.0


func _ready() -> void:
	layer = 3                       # 小地图是 2，量表盖在它上面一层
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	_bind()
	_refresh()


# ---------------------------------------------------------------- 建 UI
func _stylebox(color: Color, radius: int, border := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	if border > 0:
		sb.border_color = Color(0.68, 0.58, 0.34, 0.95)
		sb.set_border_width_all(border)
	return sb


func _build() -> void:
	var panel := PanelContainer.new()
	panel.name = "VitalsPanel"
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	var left := margin + map_size + GAP
	panel.offset_left = left
	panel.offset_right = left + WIDTH
	panel.offset_top = -(map_size + margin)     # 与小地图上沿齐平
	panel.offset_bottom = -margin               # 与小地图下沿齐平
	# 配色沿用小地图（深墨绿 + 金边），看起来才像同一套 UI
	var sb := _stylebox(Color(0.09, 0.13, 0.11, 0.78), 8, 2)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	_row(vbox, "hp", "血量")
	_row(vbox, "mana", "魔法值")
	_row(vbox, "stamina", "精力值")
	_row(vbox, "comfort", "舒适度")


func _row(parent: Node, key: String, title: String) -> void:
	var color: Color = COLORS[key]

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)

	var head := HBoxContainer.new()
	var nm := Label.new()
	nm.text = title
	nm.add_theme_font_size_override("font_size", 11)
	nm.add_theme_color_override("font_color", Color(0.84, 0.87, 0.84))
	head.add_child(nm)

	var val := Label.new()
	val.text = "—"
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.add_theme_font_size_override("font_size", 11)
	val.add_theme_color_override("font_color", color)
	head.add_child(val)

	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.max_value = BAR_STEPS
	bar.custom_minimum_size = Vector2(0, 7)
	bar.add_theme_stylebox_override("background", _stylebox(Color(0.04, 0.06, 0.05, 0.9), 3))
	bar.add_theme_stylebox_override("fill", _stylebox(color, 3))

	row.add_child(head)
	row.add_child(bar)
	parent.add_child(row)
	_bars[key] = bar
	_values[key] = val


# ---------------------------------------------------------------- 绑数据
func _bind() -> void:
	# 数据源全是已有系统；用信号置脏，不轮询
	var vitals := get_node_or_null("/root/Vitals")
	if vitals != null:
		vitals.changed.connect(func(_s, _c, _m): _dirty = true)
		vitals.emptied.connect(func(_s): _dirty = true)
		vitals.refilled.connect(func(_s): _dirty = true)

	var mana := get_node_or_null("/root/Mana")
	if mana != null:
		mana.changed.connect(func(_c, _m): _dirty = true)
		mana.emptied.connect(func(): _dirty = true)
		mana.refilled.connect(func(): _dirty = true)


func _process(delta: float) -> void:
	_timer += delta
	if not _dirty or _timer < REFRESH_INTERVAL:
		return
	_timer = 0.0
	_dirty = false
	_refresh()


func _set_bar(key: String, cur: float, mx: float) -> void:
	var bar: ProgressBar = _bars.get(key)
	var lab: Label = _values.get(key)
	if bar == null or lab == null:
		return
	bar.value = (0.0 if mx <= 0.0 else clampf(cur / mx, 0.0, 1.0)) * BAR_STEPS
	lab.text = "%d / %d" % [roundi(cur), roundi(mx)]


func _refresh() -> void:
	var vitals := get_node_or_null("/root/Vitals")
	if vitals != null:
		_set_bar("hp", vitals.current(vitals.Stat.HP), vitals.maximum(vitals.Stat.HP))
		_set_bar("stamina", vitals.current(vitals.Stat.STAMINA), vitals.maximum(vitals.Stat.STAMINA))
		_set_bar("comfort", vitals.current(vitals.Stat.COMFORT), vitals.maximum(vitals.Stat.COMFORT))

	var mana := get_node_or_null("/root/Mana")
	if mana != null:
		_set_bar("mana", float(mana.get("current")), float(mana.get("max_mana")))

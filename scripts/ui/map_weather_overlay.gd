extends PanelContainer
## 地图上的「天气 / 风向」信息块 —— 小地图与大地图共用，**行列对齐**。
##
## 【布局】两列网格（GridContainer, columns=2），左列文字、右列图标：
##     天气 | [太阳/云/雨/雷/风]
##     风向 | [风向标]
##   用 GridContainer 而不是自绘，就是为了"行列对齐"：行高、列宽由容器算，
##   换字体/换尺寸都不会错位。图标统一尺寸，文字统一字号。
##
## 【风向的屏幕角度】
##   沿用 LandmarkOverlay 的"北向标记"约定（minimap.gd _place_north）：
##     screen = R(yaw) · (x, z)，  R(yaw) = [[cos, -sin], [sin, cos]]
##   验证：世界"北" = (0, -1) -> screen = (sin yaw, -cos yaw)，与北向标记逐字一致。
##
## 【尺寸】compact = 小地图用（图标 18 / 字号 10），否则大地图用（图标 28 / 字号 14）。
##   图标刻意做小：贴在地图角上是"信息"，不该抢地图的视觉。

## Weather.Kind：CLEAR, CLOUDY, OVERCAST, RAIN, STORM, WINDY
const KIND_CLEAR := 0
const KIND_CLOUDY := 1
const KIND_OVERCAST := 2
const KIND_RAIN := 3
const KIND_STORM := 4
const KIND_WINDY := 5

## 与 Weather.KIND_NAMES 一致（自带一份，不依赖自动加载也能画）
const KIND_NAMES := ["晴朗", "多云", "阴天", "下雨", "雷雨", "大风"]

const ICON_SMALL := 18
const ICON_BIG := 28
const FONT_SMALL := 10
const FONT_BIG := 14

var kind := KIND_CLEAR
var wind_dir := Vector2(1.0, 0.0)      ## 世界风向 (x, z)
var wind_power := 0.0                  ## 风力（Weather.wind）
var map_yaw := 0.0                     ## 地图旋转角（小地图传 cam_yaw；大地图传 0）
var compact := true

var _grid: GridContainer
var _lbl_kind: Label
var _lbl_vane: Label
var _icon: Control
var _vane: Control


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


func _build() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.12, 0.10, 0.72)
	sb.border_color = Color(0.72, 0.62, 0.38, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	add_theme_stylebox_override("panel", sb)

	_grid = GridContainer.new()
	_grid.name = "WeatherGrid"
	_grid.columns = 2                    # ★ 两列：左文字、右图标 -> 行列自然对齐
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 2)
	add_child(_grid)

	_lbl_kind = _make_label("天气")
	_grid.add_child(_lbl_kind)
	_icon = WeatherIcon.new(self)
	_grid.add_child(_icon)

	_lbl_vane = _make_label("风向")
	_grid.add_child(_lbl_vane)
	_vane = WindVane.new(self)
	_grid.add_child(_vane)

	apply_size()


func _make_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## compact 决定图标尺寸与字号（小地图紧凑、大地图放大）
func apply_size() -> void:
	var px := ICON_SMALL if compact else ICON_BIG
	var fs := FONT_SMALL if compact else FONT_BIG
	for l in [_lbl_kind, _lbl_vane]:
		l.add_theme_font_size_override("font_size", fs)
		l.add_theme_color_override("font_color", Color(0.96, 0.96, 0.94, 0.96))
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		l.add_theme_constant_override("outline_size", 2 + (0 if compact else 2))
	for c in [_icon, _vane]:
		c.custom_minimum_size = Vector2(px, px)
		c.size = Vector2(px, px)
		c.queue_redraw()
	_grid.add_theme_constant_override("h_separation", 4 if compact else 8)
	_grid.add_theme_constant_override("v_separation", 1 if compact else 3)


func update_weather(k: int, dir: Vector2, power: float, yaw: float) -> void:
	kind = clampi(k, 0, KIND_NAMES.size() - 1)
	wind_dir = dir if dir.length() > 0.0001 else Vector2(1.0, 0.0)
	wind_power = power
	map_yaw = yaw
	if _lbl_kind != null:
		_lbl_kind.text = weather_label()
	if _lbl_vane != null:
		_lbl_vane.text = "风向"
	if _icon != null:
		_icon.queue_redraw()
	if _vane != null:
		_vane.queue_redraw()


## 当前天气的中文名
func weather_label() -> String:
	return KIND_NAMES[kind] if kind >= 0 and kind < KIND_NAMES.size() else "未知"


## 风向在**屏幕**上的角度（弧度）：0 = 屏幕右，PI/2 = 屏幕下
func vane_angle() -> float:
	var c := cos(map_yaw)
	var s := sin(map_yaw)
	var sx := c * wind_dir.x - s * wind_dir.y
	var sy := s * wind_dir.x + c * wind_dir.y
	return atan2(sy, sx)


# ======================================================================
# 天气图标（自绘，不依赖贴图资源）
# ======================================================================
class WeatherIcon extends Control:
	var panel: PanelContainer

	func _init(p: PanelContainer) -> void:
		panel = p
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := minf(size.x, size.y)
		var c := size * 0.5
		var s := r * 0.26
		var sun := Color(1.0, 0.86, 0.35, 1.0)
		var cloud := Color(0.88, 0.92, 0.96, 1.0)
		var dark := Color(0.58, 0.63, 0.69, 1.0)
		var rain := Color(0.55, 0.75, 1.0, 1.0)
		match int(panel.kind):
			KIND_CLEAR:
				draw_circle(c, s, sun)
				for i in range(8):
					var a := TAU * float(i) / 8.0
					var d := Vector2(cos(a), sin(a))
					draw_line(c + d * s * 1.35, c + d * s * 1.75, sun, maxf(1.0, r * 0.06))
			KIND_CLOUDY:
				draw_circle(c + Vector2(-s * 0.65, -s * 0.6), s * 0.6, sun)
				_cloud(c + Vector2(s * 0.15, s * 0.15), s * 0.9, cloud, r)
			KIND_OVERCAST:
				_cloud(c + Vector2(0.0, -s * 0.15), s * 1.0, cloud, r)
				_cloud(c + Vector2(0.0, s * 0.55), s * 0.95, dark, r)
			KIND_RAIN:
				_cloud(c + Vector2(0.0, -s * 0.35), s, dark, r)
				for i in range(3):
					var x := c.x + (float(i) - 1.0) * s * 0.6
					draw_line(Vector2(x, c.y + s * 0.5), Vector2(x - s * 0.15, c.y + s * 1.1),
							rain, maxf(1.0, r * 0.055))
			KIND_STORM:
				_cloud(c + Vector2(0.0, -s * 0.4), s, dark, r)
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(s * 0.12, s * 0.42), c + Vector2(-s * 0.35, s * 0.42),
					c + Vector2(-s * 0.02, s * 0.80), c + Vector2(-s * 0.28, s * 0.80),
					c + Vector2(s * 0.30, s * 1.45), c + Vector2(s * 0.06, s * 0.86),
					c + Vector2(s * 0.34, s * 0.86),
				]), Color(1.0, 0.90, 0.40, 1.0))
			KIND_WINDY:
				for i in range(3):
					var y := c.y + (float(i) - 1.0) * s * 0.62
					var w := s * (0.85 + 0.22 * float(i))
					draw_line(Vector2(c.x - w, y), Vector2(c.x + w * 0.65, y),
							Color(0.86, 0.93, 1.0, 0.96), maxf(1.0, r * 0.055))
					draw_arc(Vector2(c.x + w * 0.65, y - s * 0.2), s * 0.2,
							PI * 0.5, PI * 1.5, 8, Color(0.86, 0.93, 1.0, 0.96),
							maxf(1.0, r * 0.055))
			_:
				draw_circle(c, s, sun)

	func _cloud(c: Vector2, s: float, col: Color, r: float) -> void:
		draw_circle(c + Vector2(-s * 0.5, s * 0.10), s * 0.40, col)
		draw_circle(c + Vector2(0.0, -s * 0.18), s * 0.52, col)
		draw_circle(c + Vector2(s * 0.5, s * 0.12), s * 0.38, col)
		draw_rect(Rect2(c + Vector2(-s * 0.88, s * 0.06), Vector2(s * 1.8, s * 0.40)), col, true)


# ======================================================================
# 风向标（自绘）：箭头指向"风**吹向**的方向"
# ======================================================================
class WindVane extends Control:
	var panel: PanelContainer

	func _init(p: PanelContainer) -> void:
		panel = p
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r := minf(size.x, size.y)
		var c := size * 0.5
		var vr := r * 0.36
		draw_arc(c, vr, 0.0, TAU, 20, Color(0.85, 0.85, 0.8, 0.5), maxf(1.0, r * 0.05))
		var ang := float(panel.call("vane_angle"))
		var d := Vector2(cos(ang), sin(ang))
		var col := Color(1.0, 0.92, 0.55, 0.98)
		draw_line(c - d * vr * 0.45, c + d * vr * 0.95, col, maxf(1.0, r * 0.11))
		var head := maxf(1.5, r * 0.22)
		draw_colored_polygon(PackedVector2Array([
			c + d * vr * 1.05,
			c + d * vr * 1.05 - Vector2(cos(ang - 0.55), sin(ang - 0.55)) * head,
			c + d * vr * 1.05 - Vector2(cos(ang + 0.55), sin(ang + 0.55)) * head,
		]), col)
		# 风力：非紧凑版加尾羽（越强越长）
		if not bool(panel.compact) and float(panel.wind_power) > 0.01:
			var p := clampf(float(panel.wind_power) / 0.6, 0.0, 1.0)
			var t0 := c - d * vr * (0.25 + 0.55 * p)
			var t1 := c - d * vr * (0.05 + 0.2 * p)
			draw_line(t0, t1, Color(0.75, 0.85, 1.0, 0.85), maxf(1.0, r * 0.07))

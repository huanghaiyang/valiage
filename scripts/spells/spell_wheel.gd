extends CanvasLayer
## 法术圆盘（按 E 唤出）。
##
## 结构（按需求）：4 层，第 1/2/3/4 层分别 6/9/12/15 个术法位。
##   第 1 层第 1 格 = 火焰喷射，其余暂空。
##   选中"有术法"的格子 -> 发信号 + 关闭圆盘；空格子 -> 不关，只提示"空"。
##
## 用 _draw() 画：圆盘天然就是环 + 扇区，比摆一堆 Button 更贴合，也更好命中。

signal spell_chosen(id: String)
signal closed()

const RING_COUNTS := [6, 9, 12, 15]      ## 4 层，每层格子数
const RING_INNER := 46.0                 ## 最内层半径
const RING_WIDTH := 54.0                 ## 每层厚度
const GAP := 3.0                         ## 层与层之间的缝
const SPELL_NAMES := { "flame_jet": "火焰喷射", "fire_tornado": "火焰编织", "blue_tornado": "蓝色龙卷风", "detect_pulse": "物体探测", "flame_scorch": "火焰灼烧" }
## 已实现的术法：key = 层*1000 + 格（层从 0 开始，格从正上方顺时针）
const ASSIGNED := {
	0: "flame_jet",
	1: "fire_tornado",
	2: "blue_tornado",
	3: "detect_pulse",
	4: "flame_scorch",
}

var _open := false
var _hover := -1
var _font: Font = null
var _t := 0.0


func _ready() -> void:
	layer = 90
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(false)
	var c := Control.new()
	c.name = "WheelArea"
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	c.draw.connect(_on_draw.bind(c))
	c.gui_input.connect(_on_gui_input)
	add_child(c)


func is_open() -> bool:
	return _open


func open() -> void:
	_open = true
	visible = true
	_hover = -1
	_t = 0.0
	set_process(true)


func close() -> void:
	if not _open:
		return
	_open = false
	visible = false
	_hover = -1
	set_process(false)
	closed.emit()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func _process(delta: float) -> void:
	_t += delta
	var c := get_child(0) as Control
	if c != null:
		c.queue_redraw()


# ---------------------------------------------------------------- 几何
func _center(c: Control) -> Vector2:
	return c.size * 0.5


func _ring_bounds(i: int) -> Vector2:
	var r0 := RING_INNER + float(i) * (RING_WIDTH + GAP)
	return Vector2(r0, r0 + RING_WIDTH)


## 返回 层*1000+格；-1 = 没命中
func slot_at(c: Control, pos: Vector2) -> int:
	var v := pos - _center(c)
	var r := v.length()
	for i in range(RING_COUNTS.size()):
		var b := _ring_bounds(i)
		if r >= b.x and r <= b.y:
			var n: int = RING_COUNTS[i]
			var step := TAU / float(n)
			# 第 0 格从正上方开始，顺时针
			var a := fposmod(v.angle() + PI * 0.5, TAU)
			# ★ 不要 +0.5：格子中心在 a0+step/2，再加 0.5 会整体错一格（实测症状=鼠标指向与选中不符）
			var idx := int(floor(a / step)) % n
			return i * 1000 + idx
	return -1


func slot_id_at(c: Control, pos: Vector2) -> int:
	return slot_at(c, pos)


# ---------------------------------------------------------------- 输入
func _on_gui_input(ev: InputEvent) -> void:
	var c := get_child(0) as Control
	if c == null:
		return
	if ev is InputEventMouseMotion:
		_hover = slot_at(c, (ev as InputEventMouseMotion).position)
		c.queue_redraw()
	elif ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			var id := slot_at(c, mb.position)
			if id >= 0:
				_choose(id)
			get_viewport().set_input_as_handled()


func _choose(id: int) -> void:
	var sid: String = String(ASSIGNED.get(id, ""))
	if sid.is_empty():
		return                      # 空格子：不关圆盘（按需求只有选中术法才关）
	close()
	spell_chosen.emit(sid)


# ---------------------------------------------------------------- 绘制
func _on_draw(c: Control) -> void:
	if not _open:
		return
	if _font == null:
		_font = ThemeDB.fallback_font
	var center := _center(c)
	# 背景遮罩
	c.draw_rect(Rect2(Vector2.ZERO, c.size), Color(0.02, 0.03, 0.05, 0.55))
	for i in range(RING_COUNTS.size()):
		var b := _ring_bounds(i)
		var n: int = RING_COUNTS[i]
		var step := TAU / float(n)
		for k in range(n):
			var id := i * 1000 + k
			var filled := ASSIGNED.has(id)
			var a0 := -PI * 0.5 + float(k) * step
			var pts := _sector(center, b.x, b.y, a0 + 0.012, a0 + step - 0.012)
			var col := Color(0.16, 0.18, 0.24, 0.82) if not filled else Color(0.75, 0.34, 0.10, 0.92)
			if id == _hover:
				col = col.lightened(0.28) if filled else col.lightened(0.12)
			c.draw_colored_polygon(pts, col)
			var lc := Color(0.62, 0.68, 0.78, 0.55)
			if filled:
				lc = Color(1.0, 0.9, 0.6, 0.95)
			c.draw_polyline(pts + PackedVector2Array([pts[0]]), lc, 1.5)
			# 文字（只给有术法的格子和最内层写，避免糊成一片）
			if filled:
				var mid := a0 + step * 0.5
				var rr := (b.x + b.y) * 0.5
				var p := center + Vector2(cos(mid), sin(mid)) * rr
				var txt: String = String(SPELL_NAMES.get(String(ASSIGNED[id]), String(ASSIGNED[id])))
				var sz := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
				c.draw_string(_font, p - Vector2(sz.x * 0.5, -sz.y * 0.25), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.98))
	# 中心与提示
	c.draw_circle(center, RING_INNER - 8.0, Color(0.08, 0.09, 0.13, 0.92))
	c.draw_arc(center, RING_INNER - 8.0, 0.0, TAU, 64, Color(0.5, 0.56, 0.66, 0.6), 1.5)
	var tip := "点击选择术法 ｜ 空格子暂未开放"
	if _hover >= 0:
		var sid2: String = String(ASSIGNED.get(_hover, ""))
		if not sid2.is_empty():
			tip = String(SPELL_NAMES.get(sid2, sid2))
		else:
			tip = "%d 层第 %d 格：空" % [_hover / 1000 + 1, _hover % 1000 + 1]
	elif _t < 3.0:
		tip = "第 1 层：火焰喷射 / 火焰编织 / 蓝色龙卷风 / 物体探测 / 火焰灼烧（其余暂空）"
	var ts := _font.get_string_size(tip, HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
	c.draw_string(_font, center - Vector2(ts.x * 0.5, -ts.y * 0.25), tip, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.9, 0.94, 1.0, 0.95))


func _sector(center: Vector2, r0: float, r1: float, a0: float, a1: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps := 22
	for k in range(steps + 1):
		var a := lerpf(a0, a1, float(k) / float(steps))
		pts.append(center + Vector2(cos(a), sin(a)) * r1)
	for k in range(steps + 1):
		var a2 := lerpf(a1, a0, float(k) / float(steps))
		pts.append(center + Vector2(cos(a2), sin(a2)) * r0)
	return pts
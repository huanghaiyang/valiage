@tool
extends Control
## 拖框时的橡皮筋矩形（Blender 框选就是这个观感：拖动时能看到一个矩形 ✓）
##
## 它是 SubViewportContainer 的子节点、画在最上层 ✓
## mouse_filter 必须是 IGNORE ✓ 否则会把预览的鼠标事件全吃掉 ✗

var band := Rect2()
var active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func show_band(from: Vector2, to: Vector2) -> void:
	active = true
	band = Rect2(from.min(to), (to - from).abs())
	queue_redraw()


func clear_band() -> void:
	active = false
	queue_redraw()


func _draw() -> void:
	if not active:
		return
	var r := band
	if r.size.x < 1.0 and r.size.y < 1.0:
		return
	var fill := Color(0.25, 0.85, 1.0, 0.10)
	var line := Color(0.35, 0.95, 1.0, 1.0)
	draw_rect(r, fill, true)
	draw_rect(r, line, false, 1.0)
	# 四角小方块（Blender 框选也有角标，便于看清边界）
	for corner in [r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)]:
		draw_rect(Rect2(corner - Vector2(3.0, 3.0), Vector2(6.0, 6.0)), line, true)

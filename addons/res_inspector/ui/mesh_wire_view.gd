@tool
extends Control
## 网格 2D 线框投影：把顶点按 X/Y 正交投影到控件矩形里画线段。
## 只取前若干个表面、前若干条边（都是常量上限），6 MB 级网格也不会卡住界面。
## 注意：这里只做「投影画图」，不读取文件字节，也不修改网格。

## 最多画多少条边（一条边 = 两个端点）
const MAX_EDGES := 3000
## 最多取多少个顶点做投影
const MAX_VERTICES := 80000
## 最多读取多少个表面的顶点
const MAX_SURFACES := 8

## 线框颜色
const LINE_COLOR := Color(0.52, 0.78, 0.98, 0.85)
## 边框/空状态颜色
const FRAME_COLOR := Color(0.4, 0.45, 0.52, 0.8)

var _verts: PackedVector3Array = PackedVector3Array()
var _edges: PackedInt32Array = PackedInt32Array()
var _aabb := AABB()
var _note := ""
var _edge_count := 0
var _truncated := false


func _ready() -> void:
	custom_minimum_size = Vector2(360, 260)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## 设置要预览的网格（null 表示清空）
func set_mesh(mesh: Mesh) -> void:
	_verts = PackedVector3Array()
	_edges = PackedInt32Array()
	_edge_count = 0
	_truncated = false
	_aabb = AABB()
	_note = ""

	if mesh == null:
		_note = "没有可预览的网格对象。"
		queue_redraw()
		return

	_aabb = mesh.get_aabb()
	var surface_total: int = mesh.get_surface_count()
	var surfaces: int = mini(surface_total, MAX_SURFACES)
	for s in surfaces:
		if _vertices_full():
			_truncated = true
			break
		_append_surface(mesh, s)
	if surface_total > surfaces:
		_truncated = true
	if _edge_count == 0:
		_note = "未能从网格中提取到可画的三角形边（可能是压缩表面或点/线图元）。"
	elif _truncated:
		_note = "线框为截断预览：最多 %d 条边 / %d 个顶点 / %d 个表面。" % [MAX_EDGES, MAX_VERTICES, MAX_SURFACES]
	queue_redraw()


func clear_view() -> void:
	set_mesh(null)


func get_edge_count() -> int:
	return _edge_count


func get_vertex_count() -> int:
	return _verts.size()


func get_note() -> String:
	return _note


func has_wireframe() -> bool:
	return _edge_count > 0


func _vertices_full() -> bool:
	return _verts.size() >= MAX_VERTICES or _edge_count >= MAX_EDGES


## 追加一个表面的顶点与三角形边（只取前 take 个顶点，索引越界的三角形跳过）
func _append_surface(mesh: Mesh, surface: int) -> void:
	var arrays: Array = mesh.surface_get_arrays(surface)
	if arrays.is_empty():
		return
	var raw = arrays[Mesh.ARRAY_VERTEX]
	if not (raw is PackedVector3Array):
		return
	var src: PackedVector3Array = raw
	if src.is_empty():
		return

	var base: int = _verts.size()
	var take: int = mini(src.size(), MAX_VERTICES - base)
	if take <= 0:
		_truncated = true
		return
	for i in take:
		_verts.append(src[i])

	var idx = arrays[Mesh.ARRAY_INDEX]
	if idx is PackedInt32Array and (idx as PackedInt32Array).size() >= 3:
		var ids: PackedInt32Array = idx
		var t := 0
		while t + 2 < ids.size() and _edge_count < MAX_EDGES:
			var a: int = ids[t]
			var b: int = ids[t + 1]
			var c: int = ids[t + 2]
			if a < take and b < take and c < take:
				_add_edge(base + a, base + b)
				_add_edge(base + b, base + c)
				_add_edge(base + c, base + a)
			t += 3
		if t + 2 < ids.size():
			_truncated = true
	else:
		var t2 := 0
		while t2 + 2 < take and _edge_count < MAX_EDGES:
			_add_edge(base + t2, base + t2 + 1)
			_add_edge(base + t2 + 1, base + t2 + 2)
			_add_edge(base + t2 + 2, base + t2)
			t2 += 3
		if t2 + 2 < take:
			_truncated = true


func _add_edge(a: int, b: int) -> void:
	if _edge_count >= MAX_EDGES:
		return
	if a < 0 or b < 0 or a >= _verts.size() or b >= _verts.size():
		return
	_edges.append(a)
	_edges.append(b)
	_edge_count += 1


func _draw() -> void:
	var w: float = maxf(size.x, 1.0)
	var h: float = maxf(size.y, 1.0)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, h)), FRAME_COLOR, false, 1.0)
	if _edge_count == 0:
		return

	var sz := _aabb.size
	var span_x: float = maxf(absf(sz.x), 0.0001)
	var span_y: float = maxf(absf(sz.y), 0.0001)
	var margin := 8.0
	# 取较小的缩放比：保证长宽比不变、整块网格都能落在控件里
	var k: float = minf((w - margin * 2.0) / span_x, (h - margin * 2.0) / span_y)
	if k <= 0.0:
		return
	var center3 := _aabb.position + sz * 0.5
	var center2 := Vector2(w * 0.5, h * 0.5)

	var i := 0
	while i + 1 < _edges.size():
		var pa3 := _verts[_edges[i]]
		var pb3 := _verts[_edges[i + 1]]
		var pa := center2 + Vector2((pa3.x - center3.x) * k, -(pa3.y - center3.y) * k)
		var pb := center2 + Vector2((pb3.x - center3.x) * k, -(pb3.y - center3.y) * k)
		draw_line(pa, pb, LINE_COLOR, 1.0, true)
		i += 2

extends CanvasLayer
## 左下角小地图（常驻，缩小版）：SubViewport 正交俯视渲染整张地图 + 玩家箭头 + 地标 + 坐标
## 快捷键 M 开启/关闭大地图（大地图居中大窗，小地图保持常驻）

const MAP_SIZE := 120          # 小地图尺寸（缩小一半）
const MAP_BIG_SIZE := 600      # 大地图尺寸
const WORLD_HALF := 450.0
const MARGIN := 14.0
const ARROW_RATIO := 0.08      # 玩家箭头半径相对地图尺寸比例（缩小）

const LANDMARKS: Array = [
	["家", Vector2(0.0, 0.0)],
	["村庄", Vector2(260.0, 60.0)],
	["哨站", Vector2(-160.0, 220.0)],
	["哨站", Vector2(60.0, -240.0)],
]

var main: Node3D
var viewport: SubViewport
var cam: Camera3D
var arrow: ArrowOverlay
var landmarks: LandmarkOverlay
var coord_label: Label

var big_root: Control
var big_view: Control
var big_viewport: SubViewport
var big_cam: Camera3D
var big_arrow: ArrowOverlay
var big_landmarks: LandmarkOverlay
var big_coord: Label

func setup(main_node: Node3D) -> void:
	main = main_node
	layer = 2
	_build_ui()
	_build_big_map()

func _build_ui() -> void:
	# ---- 渲染容器：圆形小地图 ----
	var svc := SubViewportContainer.new()
	svc.name = "MinimapView"
	svc.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	svc.offset_left = MARGIN
	svc.offset_top = -MAP_SIZE - MARGIN
	svc.offset_right = MARGIN + MAP_SIZE
	svc.offset_bottom = -MARGIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.13, 0.11, 0.78)
	sb.border_color = Color(0.68, 0.58, 0.34, 0.95)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(int(MAP_SIZE * 0.5))
	svc.add_theme_stylebox_override("panel", sb)
	svc.clip_contents = true
	add_child(svc)

	# ---- 俯视相机（正交，显示整张 900m 地图） ----
	viewport = SubViewport.new()
	viewport.name = "MinimapViewport"
	viewport.size = Vector2i(MAP_SIZE, MAP_SIZE)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	svc.add_child(viewport)

	cam = Camera3D.new()
	cam.name = "MinimapCamera"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = WORLD_HALF
	cam.position = Vector3(0.0, 350.0, 0.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.near = 1.0
	cam.far = 620.0
	# 环境覆盖：关闭体积雾（HIGH 画质默认开启，俯视远距离会积成白雾）
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	cam.environment = env
	viewport.add_child(cam)
	cam.make_current()

	# ---- 地标与北向叠加层（小图：点/字缩小） ----
	landmarks = LandmarkOverlay.new()
	landmarks.name = "Landmarks"
	landmarks.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	landmarks.offset_left = MARGIN
	landmarks.offset_top = -MAP_SIZE - MARGIN
	landmarks.offset_right = MARGIN + MAP_SIZE
	landmarks.offset_bottom = -MARGIN
	landmarks.dot_r1 = 3.0
	landmarks.dot_r2 = 1.8
	landmarks.font_size = 8
	landmarks.font_n = 9
	landmarks.lbl_w = 56.0
	landmarks.setup_marks(LANDMARKS, MAP_SIZE)
	add_child(landmarks)

	# ---- 玩家箭头叠加层（小图） ----
	arrow = ArrowOverlay.new()
	arrow.name = "PlayerArrow"
	arrow.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	arrow.offset_left = MARGIN
	arrow.offset_top = -MAP_SIZE - MARGIN
	arrow.offset_right = MARGIN + MAP_SIZE
	arrow.offset_bottom = -MARGIN
	add_child(arrow)

	# ---- 坐标显示（小地图上方） ----
	coord_label = Label.new()
	coord_label.name = "Coords"
	coord_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	coord_label.offset_left = MARGIN - 8
	coord_label.offset_right = MARGIN + MAP_SIZE + 8
	coord_label.offset_bottom = -MARGIN - MAP_SIZE - 4
	coord_label.offset_top = coord_label.offset_bottom - 22
	coord_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	coord_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	coord_label.text = "X 0 · Z 0 · 海拔 0.0"
	coord_label.add_theme_font_size_override("font_size", 10)
	coord_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	coord_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	coord_label.add_theme_constant_override("outline_size", 3)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.08, 0.12, 0.10, 0.62)
	csb.set_corner_radius_all(7)
	coord_label.add_theme_stylebox_override("normal", csb)
	add_child(coord_label)

func _build_big_map() -> void:
	# ---- 大地图根容器：居中大窗，默认隐藏，M 键开关（控制整体可见性） ----
	big_root = Control.new()
	big_root.name = "BigMapRoot"
	big_root.set_anchors_preset(Control.PRESET_CENTER)
	big_root.offset_left = -MAP_BIG_SIZE * 0.5
	big_root.offset_top = -MAP_BIG_SIZE * 0.5
	big_root.offset_right = MAP_BIG_SIZE * 0.5
	big_root.offset_bottom = MAP_BIG_SIZE * 0.5
	big_root.visible = false
	add_child(big_root)

	# ---- 大地图渲染容器（填满根容器） ----
	big_view = SubViewportContainer.new()
	big_view.name = "BigMapView"
	big_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.13, 0.11, 0.82)
	sb.border_color = Color(0.72, 0.62, 0.38, 0.98)
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(14)
	big_view.add_theme_stylebox_override("panel", sb)
	big_view.clip_contents = true
	big_root.add_child(big_view)

	# ---- 大地图俯视相机 ----
	big_viewport = SubViewport.new()
	big_viewport.name = "BigMapViewport"
	big_viewport.size = Vector2i(MAP_BIG_SIZE, MAP_BIG_SIZE)
	big_viewport.transparent_bg = true
	big_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	big_viewport.msaa_3d = Viewport.MSAA_DISABLED
	big_view.add_child(big_viewport)

	big_cam = Camera3D.new()
	big_cam.name = "BigMapCamera"
	big_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	big_cam.size = WORLD_HALF
	big_cam.position = Vector3(0.0, 350.0, 0.0)
	big_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	big_cam.near = 1.0
	big_cam.far = 620.0
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	big_cam.environment = env
	big_viewport.add_child(big_cam)
	big_cam.make_current()

	# ---- 大地图地标叠加层 ----
	big_landmarks = LandmarkOverlay.new()
	big_landmarks.name = "BigLandmarks"
	big_landmarks.set_anchors_preset(Control.PRESET_CENTER)
	big_landmarks.offset_left = -MAP_BIG_SIZE * 0.5
	big_landmarks.offset_top = -MAP_BIG_SIZE * 0.5
	big_landmarks.offset_right = MAP_BIG_SIZE * 0.5
	big_landmarks.offset_bottom = MAP_BIG_SIZE * 0.5
	big_landmarks.dot_r1 = 6.0
	big_landmarks.dot_r2 = 3.5
	big_landmarks.font_size = 13
	big_landmarks.font_n = 15
	big_landmarks.lbl_w = 130.0
	big_landmarks.setup_marks(LANDMARKS, MAP_BIG_SIZE)
	big_root.add_child(big_landmarks)

	# ---- 大地图玩家箭头 ----
	big_arrow = ArrowOverlay.new()
	big_arrow.name = "BigPlayerArrow"
	big_arrow.set_anchors_preset(Control.PRESET_CENTER)
	big_arrow.offset_left = -MAP_BIG_SIZE * 0.5
	big_arrow.offset_top = -MAP_BIG_SIZE * 0.5
	big_arrow.offset_right = MAP_BIG_SIZE * 0.5
	big_arrow.offset_bottom = MAP_BIG_SIZE * 0.5
	big_root.add_child(big_arrow)

	# ---- 大地图坐标（地图上方） ----
	big_coord = Label.new()
	big_coord.name = "BigCoords"
	big_coord.set_anchors_preset(Control.PRESET_CENTER)
	big_coord.offset_left = -MAP_BIG_SIZE * 0.5
	big_coord.offset_right = MAP_BIG_SIZE * 0.5
	big_coord.offset_bottom = -MAP_BIG_SIZE * 0.5 - 6
	big_coord.offset_top = big_coord.offset_bottom - 28
	big_coord.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big_coord.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	big_coord.text = "大地图 · X 0 · Z 0"
	big_coord.add_theme_font_size_override("font_size", 15)
	big_coord.add_theme_color_override("font_color", Color(1, 1, 1, 0.98))
	big_coord.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	big_coord.add_theme_constant_override("outline_size", 4)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.08, 0.12, 0.10, 0.72)
	csb.set_corner_radius_all(10)
	big_coord.add_theme_stylebox_override("normal", csb)
	big_root.add_child(big_coord)

func _process(_delta: float) -> void:
	if main == null or main.player == null:
		return
	var p: Vector3 = main.player.global_position
	var yaw := 0.0
	if main.player.body != null:
		yaw = main.player.body.rotation.y
	arrow.update_arrow(p.x, p.z, yaw)
	coord_label.text = "X %d · Z %d · 海拔 %.1f" % [int(p.x), int(p.z), p.y]
	if big_root.visible:
		big_arrow.update_arrow(p.x, p.z, yaw)
		big_coord.text = "大地图 · X %d · Z %d · 海拔 %.1f" % [int(p.x), int(p.z), p.y]

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			big_root.visible = not big_root.visible
			get_viewport().set_input_as_handled()

## 玩家方向箭头（自绘）：默认朝上，按玩家 yaw 旋转
class ArrowOverlay extends Control:
	var yaw := 0.0
	var world_x := 0.0
	var world_z := 0.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func update_arrow(wx: float, wz: float, y: float) -> void:
		world_x = wx
		world_z = wz
		yaw = y
		queue_redraw()

	func _draw() -> void:
		var half := size.x * 0.5
		var c := Vector2(half + world_x / WORLD_HALF * half, half + world_z / WORLD_HALF * half)
		var r := minf(size.x, size.y) * ARROW_RATIO
		draw_circle(c, r + r * 0.18, Color(0, 0, 0, 0.5))
		var rot := atan2(cos(yaw), sin(yaw)) + PI * 0.5
		draw_set_transform(c, rot, Vector2.ONE)
		var pts := PackedVector2Array([
			Vector2(0.0, -r),
			Vector2(r * 0.62, r * 0.8),
			Vector2(-r * 0.62, r * 0.8),
		])
		draw_colored_polygon(pts, Color(1.0, 0.88, 0.3, 1.0))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

## 地标叠加层：圆点标记 + 名称（Label）+ 北向
class LandmarkOverlay extends Control:
	var marks: Array = []
	var dot_r1 := 4.5
	var dot_r2 := 2.8
	var font_size := 11
	var font_n := 13
	var lbl_w := 90.0

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func setup_marks(list: Array, map_size: float) -> void:
		marks = list
		for m in marks:
			var wpos: Vector2 = m[1]
			var px := map_size * 0.5 + wpos.x / WORLD_HALF * (map_size * 0.5)
			var py := map_size * 0.5 + wpos.y / WORLD_HALF * (map_size * 0.5)
			var lbl := Label.new()
			lbl.text = m[0]
			lbl.custom_minimum_size = Vector2(lbl_w, 16)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.add_theme_font_size_override("font_size", font_size)
			lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
			lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
			lbl.add_theme_constant_override("outline_size", 2)
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			lbl.position = Vector2(px - lbl_w * 0.5, py - 20.0)
			add_child(lbl)
		# 北向标记（地图顶部固定指北）
		var n := Label.new()
		n.text = "N"
		n.custom_minimum_size = Vector2(24, 18)
		n.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		n.add_theme_font_size_override("font_size", font_n)
		n.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95, 0.95))
		n.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		n.add_theme_constant_override("outline_size", 2)
		n.mouse_filter = Control.MOUSE_FILTER_IGNORE
		n.position = Vector2(size.x * 0.5 - 12.0, 4.0)
		add_child(n)

	func _draw() -> void:
		var half := size.x * 0.5
		for m in marks:
			var wpos: Vector2 = m[1]
			var p := Vector2(half + wpos.x / WORLD_HALF * half, half + wpos.y / WORLD_HALF * half)
			draw_circle(p, dot_r1, Color(0.12, 0.08, 0.04, 0.8))
			draw_circle(p, dot_r2, Color(0.95, 0.78, 0.32, 0.98))

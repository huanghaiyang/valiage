extends Node3D
## 通用法术施法区域选择器（不绑定任何具体法术）
##
## 用法（法术侧只需两件事）：
##   1. 法术实现 has_targeting() -> true  和  cast_at(center, radius) -> void
##   2. 配置表里给出 targeting 段（直径上下限、施法距离上下限、纹理）
## 施法器（spell_caster）会负责显示/隐藏它，并在鼠标按下时把 (center, radius) 交给法术。
##
## 交互：
##   · 鼠标在地图上移动 -> 圆圈跟着走
##   · 滚轮             -> 缩放（直径 diameter_min ~ diameter_max）
##   · 与主角的水平距离钳制在 range_min ~ range_max
##   · 鼠标按下         -> 发出 confirmed(center, radius)
##
## 贴合地形：圆盘网格的每个顶点都**从上方朝下打射线**落在真实表面上
##   （地形、台阶、地形上的物体都能贴住）—— 思路与「物体探测」法术一致。
##   只有位置/半径变化时才重建网格（脏标记），不是每帧重打射线。

signal confirmed(center: Vector3, radius: float)
signal cancelled()

const TEX_DEFAULT := "res://assets/textures/法术特效/kenney/particle-pack/circle_02.png"
const AREA_SHADER := "res://assets/shaders/spell_area.gdshader"
const SEGMENTS := 64          ## 圆周分段
const RINGS := 6              ## 径向分段（越大贴合越细）

## ---- 以下全部可由配置表覆盖 ----
var diameter_min := 5.0
var diameter_max := 10.0
var range_min := 1.0
var range_max := 12.0
var wheel_step := 0.4
var texture_path := TEX_DEFAULT
## ★ 顶点相对"圆心所在高度"最多抬高多少米。
##   不限制的话，圈边打到石墙/高台时整张圆盘会变成"贴着墙往上爬的布"
##   （实测：外圈顶点落在 4.17 米高的墙顶）。限幅后仍能贴合缓坡与矮物体，
##   但不会爬高墙 —— 这是游戏里地面指示圈的通行做法。
var max_lift := 1.2

var _player: Node3D = null
var _cam: Camera3D = null
var _disc: MeshInstance3D = null
var _mat: ShaderMaterial = null
var _radius := 2.5
var _center := Vector3.ZERO
var _active := false
var _dirty := true
var _has_center := false


func _ready() -> void:
	set_process(false)
	set_process_input(false)
	_build_disc()
	visible = false


func setup(player: Node3D, camera: Camera3D = null) -> void:
	_player = player
	_cam = camera


## 按配置表初始化（法术把 targeting 段原样传进来即可，别的法术也能用）
func configure(cfg: Dictionary) -> void:
	if cfg.is_empty():
		return
	diameter_min = float(cfg.get("diameter_min", diameter_min))
	diameter_max = float(cfg.get("diameter_max", diameter_max))
	range_min = float(cfg.get("range_min", range_min))
	range_max = float(cfg.get("range_max", range_max))
	wheel_step = float(cfg.get("wheel_step", wheel_step))
	max_lift = float(cfg.get("max_lift", max_lift))
	texture_path = String(cfg.get("texture", texture_path))
	if _mat != null:
		var tex := load(texture_path) as Texture2D
		if tex != null:
			_mat.set_shader_parameter("area_tex", tex)
	_radius = clampf(_radius, diameter_min * 0.5, diameter_max * 0.5)


func begin() -> void:
	if _active:
		return
	_active = true
	visible = true
	# 默认圈在主角前方 range_min+2 米处，避免一开就是脚下
	if _player != null and is_instance_valid(_player) and not _has_center:
		var fwd := -(_player.global_transform.basis.z)
		fwd.y = 0.0
		_center = _player.global_position + fwd.normalized() * minf(range_min + 2.0, range_max)
		_has_center = true
	_dirty = true
	set_process(true)
	set_process_input(true)


func end() -> void:
	if not _active:
		return
	_active = false
	visible = false
	set_process(false)
	set_process_input(false)


func is_active() -> bool:
	return _active


func center() -> Vector3:
	return _center


func radius() -> float:
	return _radius


func diameter() -> float:
	return _radius * 2.0


## 鼠标按下时由施法器调用：返回是否真的确认了
func confirm() -> bool:
	if not _active:
		return false
	confirmed.emit(_center, _radius)
	return true


# ---------------------------------------------------------------- 输入
func _input(ev: InputEvent) -> void:
	if not _active:
		return
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_set_diameter(diameter() + wheel_step)
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_set_diameter(diameter() - wheel_step)
			get_viewport().set_input_as_handled()


func _set_diameter(d: float) -> void:
	d = clampf(d, diameter_min, diameter_max)
	var r := d * 0.5
	if absf(r - _radius) > 0.0001:
		_radius = r
		_dirty = true


# ---------------------------------------------------------------- 每帧
func _process(_delta: float) -> void:
	if not _active:
		return
	_update_center_from_mouse()
	if _dirty:
		_dirty = false
		_rebuild_mesh()


## 鼠标 -> 世界落点（打射线到地形/物体；打不到就落在一个水平面上）
func _update_center_from_mouse() -> void:
	var vp := get_viewport()
	if vp == null or _player == null or not is_instance_valid(_player):
		return
	if _cam == null or not is_instance_valid(_cam):
		_cam = vp.get_camera_3d()
	if _cam == null:
		return
	var mouse := vp.get_mouse_position()
	var from := _cam.project_ray_origin(mouse)
	var dir := _cam.project_ray_normal(mouse)
	var plane_y := _player.global_position.y
	var world := get_world_3d()
	var pos := Vector3.ZERO
	var ok := false
	if world != null:
		var far := from + dir * 400.0
		var q := PhysicsRayQueryParameters3D.create(from, far)
		q.collision_mask = 0xFFFFFFFF
		q.exclude = [_player.get_rid()] if _player is CollisionObject3D else []
		var hit := world.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			pos = hit["position"]
			ok = true
	if not ok:
		# 没打到地形：与"主角脚下的水平面"求交
		if absf(dir.y) < 0.0001:
			return
		var t := (plane_y - from.y) / dir.y
		if t <= 0.0:
			return
		pos = from + dir * t
	# ★ 施法距离钳制（距主角的水平距离）
	var p := _player.global_position
	var flat := Vector3(pos.x - p.x, 0.0, pos.z - p.z)
	var d := flat.length()
	if d > range_max:
		flat = flat.normalized() * range_max
	elif d < range_min:
		flat = (flat.normalized() if d > 0.0001 else Vector3.FORWARD) * range_min
	_center = Vector3(p.x + flat.x, pos.y, p.z + flat.z)
	_dirty = true


# ---------------------------------------------------------------- 网格
func _build_disc() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "AreaDisc"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	var sh := load(AREA_SHADER) as Shader
	if sh != null:
		_mat.shader = sh
		var tex := load(texture_path) as Texture2D
		if tex != null:
			_mat.set_shader_parameter("area_tex", tex)
	mi.material_override = _mat
	add_child(mi)
	_disc = mi


## 重建贴合地形的圆盘：逐顶点朝下打射线
func _rebuild_mesh() -> void:
	if _disc == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var world := get_world_3d()
	var verts: Array = []
	for ring in range(RINGS + 1):
		var rr := float(ring) / float(RINGS)
		var row: Array = []
		for s in range(SEGMENTS):
			var a := float(s) / float(SEGMENTS) * TAU
			var x := _center.x + cos(a) * _radius * rr
			var z := _center.z + sin(a) * _radius * rr
			var y := _center.y
			if world != null:
				var from := Vector3(x, _center.y + 12.0, z)
				var to := Vector3(x, _center.y - 60.0, z)
				var q := PhysicsRayQueryParameters3D.create(from, to)
				q.collision_mask = 0xFFFFFFFF
				var hit := world.direct_space_state.intersect_ray(q)
				if not hit.is_empty():
					y = (hit["position"] as Vector3).y
			# ★ 限幅：不打到高墙/高台上（那种地方会变成贴墙的布）
			y = clampf(y, _center.y - 3.0, _center.y + max_lift)
			# 抬高一点点，避免与地面 z-fighting
			row.append(Vector3(x, y + 0.02, z))
		verts.append(row)
	for ring in range(RINGS):
		var r0: Array = verts[ring]
		var r1: Array = verts[ring + 1]
		for s in range(SEGMENTS):
			var s2 := (s + 1) % SEGMENTS
			var uv = func(rr: float, ss: int) -> Vector2:
				var a := float(ss) / float(SEGMENTS) * TAU
				return Vector2(0.5 + cos(a) * 0.5 * rr, 0.5 + sin(a) * 0.5 * rr)
			var rr0 := float(ring) / float(RINGS)
			var rr1 := float(ring + 1) / float(RINGS)
			st.set_uv(uv.call(rr0, s))
			st.add_vertex(r0[s])
			st.set_uv(uv.call(rr1, s))
			st.add_vertex(r1[s])
			st.set_uv(uv.call(rr1, s2))
			st.add_vertex(r1[s2])
			st.set_uv(uv.call(rr0, s))
			st.add_vertex(r0[s])
			st.set_uv(uv.call(rr1, s2))
			st.add_vertex(r1[s2])
			st.set_uv(uv.call(rr0, s2))
			st.add_vertex(r0[s2])
	_disc.mesh = st.commit()

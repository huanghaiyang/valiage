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
## ★ 扇形**独立**一套（独立节点 + 独立材质 + 独立着色器）：
##   圆盘材质是全局复用一份的，之前把两种形状做进同一个着色器会互相污染状态
##   （切回圆盘时圆圈被扇形的角度裁掉 -> 圆圈看不见）。独立就没有这个问题。
const SECTOR_SHADER := "res://assets/shaders/spell_sector.gdshader"
const SEGMENTS := 64          ## 圆周分段
const RINGS := 6              ## 径向分段（越大贴合越细）

## ---- 以下全部可由配置表覆盖 ----
var diameter_min := 5.0
var diameter_max := 10.0
var range_min := 1.0
var range_max := 12.0
var wheel_step := 0.4
## ---- 扇形模式（火焰推进）----
## mode = "sector"：圆心**锁在主角**，中轴跟随鼠标，滚轮改**张角**而不是半径。
var sector := false
## 诊断：打印每次 configure 生效的模式、以及滚轮改的到底是什么
@export var debug_targeting := true
var angle_min := 45.0
var angle_max := 80.0
var wheel_step_deg := 5.0
var radius_at_min := 10.0      ## 最小张角时的半径（数值表给的）
var radius_at_max := 6.0       ## 最大张角时的半径
var _angle := 45.0
## ★ 扇形内圈半径（米）：角色前留出的空白，扇形从这里才开始画（用户要求 0.5m）
@export var sector_inner_m := 0.5
var _axis := 0.0               ## 中轴方向（弧度）
var _tex_path_loaded := ""     ## 已加载的贴图路径（configure 会反复调用，避免重复 load）
var texture_path := TEX_DEFAULT
## ★ 顶点相对"圆心所在高度"最多抬高多少米。
##   不限制的话，圈边打到石墙/高台时整张圆盘会变成"贴着墙往上爬的布"。
var max_lift := 1.2
## ★ 平滑参数：上下限幅收窄 + 对高度图做多轮三点平均。
##   只限幅不平滑是不够的：相邻顶点一个在地面、一个在墙顶，仍会拉出**尖刺布帘**
##   （用户实测反馈"不规则物体表面显示过于严重，要平滑些"）。
var smooth_lift := 0.35
var smooth_drop := 0.35
## ★ 只认"能站的地面"：射线命中面的法线朝上程度低于这个值，就当作**没有地面**
##   （墙基、栏杆、树干都是竖直面）。不这么滤的话，圆盘会**顺着物体的立面铺上去**，
##   观感就是"圈选从物体表面穿过"（用户实测反馈）。
##   滤掉之后圆盘保持在低位，被物体挡住的部分由**深度测试**自然切断 —— 这才是地面指示圈该有的样子。
var ground_normal_min := 0.6
## ★ 相邻顶点允许的最大落差（米）。坡形靠它保住，尖刺靠它削平。
var slope_step := 0.22
var slope_passes := 4

var _player: Node3D = null
var _cam: Camera3D = null
var _disc: MeshInstance3D = null
var _mat: ShaderMaterial = null
## ★ 扇形独立节点/材质（与圆盘互不影响，见 SECTOR_SHADER 注释）
var _sector_disc: MeshInstance3D = null
var _sector_mat: ShaderMaterial = null
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
	sector = String(cfg.get("mode", "")) == "sector"
	angle_min = float(cfg.get("angle_min", angle_min))
	angle_max = float(cfg.get("angle_max", angle_max))
	wheel_step_deg = float(cfg.get("wheel_step_deg", wheel_step_deg))
	if wheel_step_deg <= 0.001:
		wheel_step_deg = 5.0        # 保险：配置漏了/写成 0 时不能让滚轮失灵
	radius_at_min = float(cfg.get("radius_at_min", radius_at_min))
	radius_at_max = float(cfg.get("radius_at_max", radius_at_max))
	if sector:
		_angle = clampf(_angle, minf(angle_min, angle_max), maxf(angle_min, angle_max))
	diameter_min = float(cfg.get("diameter_min", diameter_min))
	diameter_max = float(cfg.get("diameter_max", diameter_max))
	range_min = float(cfg.get("range_min", range_min))
	range_max = float(cfg.get("range_max", range_max))
	wheel_step = float(cfg.get("wheel_step", wheel_step))
	max_lift = float(cfg.get("max_lift", max_lift))
	texture_path = String(cfg.get("texture", texture_path))
	if _mat != null:
		# 只在贴图路径变化时重新 load（configure 会被反复调用，避免每帧加载 4K 纹理）
		if texture_path != _tex_path_loaded:
			var tex := load(texture_path) as Texture2D
			if tex != null:
				_mat.set_shader_parameter("area_tex", tex)
				_tex_path_loaded = texture_path
	if debug_targeting:
		print("[选点器] configure: mode=%s -> sector=%s | 张角=%.0f度(%.0f~%.0f) | 步长=%.0f | 半径=%.1f | 距离档=%.1f~%.1f" % [
				String(cfg.get("mode", "(未给)")), str(sector), _angle,
				minf(angle_min, angle_max), maxf(angle_min, angle_max), wheel_step_deg,
				_radius, diameter_min, diameter_max])
	if sector:
		_radius = _radius_from_angle()      # 扇形：半径由张角决定
	else:
		_radius = clampf(_radius, diameter_min * 0.5, diameter_max * 0.5)


## 张角 -> 半径（线性插值；两端值都来自数值表，不硬编码）
func _radius_from_angle() -> float:
	var span := angle_max - angle_min
	var k := 0.0 if absf(span) < 0.0001 else clampf((_angle - angle_min) / span, 0.0, 1.0)
	return clampf(lerpf(radius_at_min, radius_at_max, k), 0.5, range_max)


## 扇形张角（度）
func angle() -> float:
	return _angle


## 扇形半角（弧度）—— 交给法术
func half_angle() -> float:
	return deg_to_rad(_angle) * 0.5


## 扇形中轴方向（弧度，XZ 平面 atan2(z, x)）
func axis() -> float:
	return _axis


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
			if sector:
				_set_angle(_angle + wheel_step_deg)
				if debug_targeting:
					print("[选点器] 滚轮↑ 张角 %.0f度（步长 %.0f，半径 %.1f）" % [_angle, wheel_step_deg, _radius])
			else:
				_set_diameter(diameter() + wheel_step)
				if debug_targeting:
					print("[选点器] 滚轮↑ 直径 %.1f（**圆盘模式**：扇形配置没生效）" % diameter())
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if sector:
				_set_angle(_angle - wheel_step_deg)
				if debug_targeting:
					print("[选点器] 滚轮↓ 张角 %.0f度（步长 %.0f，半径 %.1f，下限 %.0f度）" % [
							_angle, wheel_step_deg, _radius, angle_min])
			else:
				_set_diameter(diameter() - wheel_step)
			get_viewport().set_input_as_handled()


## 扇形模式：滚轮改**张角**，半径随之由数值表插值算出来
func _set_angle(a: float) -> void:
	a = clampf(a, minf(angle_min, angle_max), maxf(angle_min, angle_max))
	if absf(a - _angle) > 0.0001:
		_angle = a
		_radius = _radius_from_angle()
		_dirty = true


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
	if sector:
		_update_sector()
	else:
		# ★ 圆盘模式：只让圆盘可见（扇形节点隐藏）。
		#   扇形是独立材质 -> 不会再出现"圆圈被扇形的角度裁掉"那种污染（实测踩过）。
		if _disc != null:
			_disc.visible = true
		if _sector_disc != null:
			_sector_disc.visible = false
		_update_center_from_mouse()
	if _dirty:
		_dirty = false
		_rebuild_mesh()


## 扇形：**圆心锁在主角脚下**，中轴指向鼠标（水平方向），半径由张角插值算出
func _update_sector() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var vp := get_viewport()
	if _cam == null or not is_instance_valid(_cam):
		_cam = vp.get_camera_3d() if vp != null else null
	var p := _player.global_position
	var new_axis := _axis
	if _cam != null and vp != null:
		var mouse := vp.get_mouse_position()
		var from := _cam.project_ray_origin(mouse)
		var dirn := _cam.project_ray_normal(mouse)
		# 与"主角所在水平面"求交 -> 鼠标的地面落点 -> 中轴方向
		if absf(dirn.y) > 0.0001:
			var t := (p.y - from.y) / dirn.y
			if t > 0.0:
				var hit := from + dirn * t
				var flat := Vector3(hit.x - p.x, 0.0, hit.z - p.z)
				if flat.length() > 0.05:
					new_axis = atan2(flat.z, flat.x)
	# ★ 扇形参数写到**独立的扇形材质**上（圆盘材质完全不碰 -> 不会被污染）
	#   每帧都写：滚轮改张角时中心/中轴都没变，写在条件里就不会实时生效（实测）
	if _sector_disc != null:
		_sector_disc.visible = true
	if _disc != null:
		_disc.visible = false
	if _sector_mat != null:
		_sector_mat.set_shader_parameter("axis", new_axis)
		_sector_mat.set_shader_parameter("half_angle", half_angle())
		_sector_mat.set_shader_parameter("inner",
				clampf(sector_inner_m / maxf(_radius, 0.01), 0.0, 0.85))
		_sector_mat.set_shader_parameter("fill_strength", 0.55)
		_sector_mat.set_shader_parameter("edge_strength", 2.2)
	if p.distance_to(_center) > 0.01 or absf(new_axis - _axis) > 0.001:
		_center = p
		_axis = new_axis
		_dirty = true


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
	_build_sector()


## ★ 扇形：独立节点 + 独立材质（和圆盘互不影响）
func _build_sector() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "AreaSector"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sector_mat = ShaderMaterial.new()
	var sh := load(SECTOR_SHADER) as Shader
	if sh != null:
		_sector_mat.shader = sh
	mi.material_override = _sector_mat
	mi.visible = false
	add_child(mi)
	_sector_disc = mi


## 重建贴合地形的圆盘：采样高度 -> 限幅平滑 -> 建面
func _rebuild_mesh() -> void:
	if _disc == null:
		return
	var rows := _smooth_heights(_sample_heights(), _center.y)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var uv_of = func(rr: float, ss: int) -> Vector2:
		var a := float(ss) / float(SEGMENTS) * TAU
		return Vector2(0.5 + cos(a) * 0.5 * rr, 0.5 + sin(a) * 0.5 * rr)
	var pv = func(ring: int, s: int) -> Vector3:
		var rr := float(ring) / float(RINGS)
		var a := float(s % SEGMENTS) / float(SEGMENTS) * TAU
		var x := _center.x + cos(a) * _radius * rr
		var z := _center.z + sin(a) * _radius * rr
		# 抬高一点点，避免与地面 z-fighting
		return Vector3(x, (rows[ring] as PackedFloat32Array)[s % SEGMENTS] + 0.02, z)
	for ring in range(RINGS):
		var rr0 := float(ring) / float(RINGS)
		var rr1 := float(ring + 1) / float(RINGS)
		for s in range(SEGMENTS):
			var s2 := (s + 1) % SEGMENTS
			st.set_uv(uv_of.call(rr0, s))
			st.add_vertex(pv.call(ring, s))
			st.set_uv(uv_of.call(rr1, s))
			st.add_vertex(pv.call(ring + 1, s))
			st.set_uv(uv_of.call(rr1, s2))
			st.add_vertex(pv.call(ring + 1, s2))
			st.set_uv(uv_of.call(rr0, s))
			st.add_vertex(pv.call(ring, s))
			st.set_uv(uv_of.call(rr1, s2))
			st.add_vertex(pv.call(ring + 1, s2))
			st.set_uv(uv_of.call(rr0, s2))
			st.add_vertex(pv.call(ring, s2))
	_disc.mesh = st.commit()
	if _sector_disc != null:
		_sector_disc.mesh = _disc.mesh     # 同一份贴合地形的网格，两个节点各画各的材质


## 命中面算不算"能站的地面"（纯函数，便于自检）
##   法线朝上程度 >= ground_normal_min 才算地面；竖直面（墙/栏杆/树干）一律不算。
func _is_ground(hit: Dictionary) -> bool:
	if not hit.has("normal"):
		return true
	return (hit["normal"] as Vector3).normalized().y >= ground_normal_min


## 采样高度图：外层环逐顶点朝下打射线（内圈半径 0 = 圆心高度）
func _sample_heights() -> Array:
	var world := get_world_3d()
	var y0 := _center.y
	var rows: Array = []
	for ring in range(RINGS + 1):
		var rr := float(ring) / float(RINGS)
		var row := PackedFloat32Array()
		row.resize(SEGMENTS)
		for s in range(SEGMENTS):
			var y := y0
			if ring > 0 and world != null:
				var a := float(s) / float(SEGMENTS) * TAU
				var x := _center.x + cos(a) * _radius * rr
				var z := _center.z + sin(a) * _radius * rr
				var q := PhysicsRayQueryParameters3D.create(Vector3(x, y0 + 12.0, z),
						Vector3(x, y0 - 60.0, z))
				q.collision_mask = 0xFFFFFFFF
				var hit := world.direct_space_state.intersect_ray(q)
				if not hit.is_empty() and _is_ground(hit):
					y = (hit["position"] as Vector3).y
			row[s] = y
		rows.append(row)
	return rows


## 限幅 + 平滑（**纯函数**：只吃高度图，自检直接喂人造尖刺/斜坡验证）
##   ① 硬限幅：把"墙顶 / 深沟"这种大落差压进 smooth_lift / smooth_drop
##   ② **坡度限幅**：相邻顶点落差不超过 slope_step，迭代若干轮。
##      这一步才是关键：它**保住整体坡形**（缓坡每级差一点，始终合法），
##      只把"一级跳 3 米"的尖刺一级一级削下来 -> 不再拉出尖刺布帘。
##   ③ 一轮**轻量**三点平均：把削出来的棱角抹圆（幅度小，不会抹掉坡形）
##   ★ 不要用"多轮重度平均"来做平滑：实测 3 轮 4 点平均会把 3 米尖刺压成 0.000，
##     整张盘变成完全平坦 —— 那样就不"适配地形"了。
func _smooth_heights(rows: Array, y0: float) -> Array:
	var n := rows.size()
	# ① 硬限幅
	var cur: Array = []
	for ring in range(n):
		var src: PackedFloat32Array = rows[ring]
		var capped := PackedFloat32Array()
		capped.resize(SEGMENTS)
		for s in range(SEGMENTS):
			capped[s] = clampf(src[s], y0 - smooth_drop, y0 + smooth_lift)
		cur.append(capped)
	# ② 坡度限幅
	for pass_i in range(maxi(slope_passes, 0)):
		var nxt: Array = []
		for ring in range(n):
			var row: PackedFloat32Array = cur[ring]
			var out := PackedFloat32Array()
			out.resize(SEGMENTS)
			for s in range(SEGMENTS):
				if ring == 0:
					out[s] = y0                 # 圆心一圈钉住
					continue
				var l := row[(s - 1 + SEGMENTS) % SEGMENTS]
				var r := row[(s + 1) % SEGMENTS]
				var lo := minf(l, r) - slope_step
				var hi := maxf(l, r) + slope_step
				if ring < n - 1:
					var up: PackedFloat32Array = cur[ring - 1]
					var dn: PackedFloat32Array = cur[ring + 1]
					lo = maxf(lo, minf(up[s], dn[s]) - slope_step)
					hi = minf(hi, maxf(up[s], dn[s]) + slope_step)
				out[s] = clampf(row[s], lo, hi)
			nxt.append(out)
		cur = nxt
	# ③ 轻量抹圆（只沿圆周，一轮）
	var fin: Array = []
	for ring in range(n):
		var row2: PackedFloat32Array = cur[ring]
		var out2 := PackedFloat32Array()
		out2.resize(SEGMENTS)
		for s in range(SEGMENTS):
			if ring == 0:
				out2[s] = y0
				continue
			var l2 := row2[(s - 1 + SEGMENTS) % SEGMENTS]
			var r2 := row2[(s + 1) % SEGMENTS]
			out2[s] = (l2 + r2 + row2[s] * 2.0) / 4.0
		fin.append(out2)
	return fin

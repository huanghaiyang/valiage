extends Node
## ★★ 角色脚底圈（贴合地形 / 只在被草遮挡时显示 / 无抖动）
##
## 【为什么是"实体网格"而不是屏幕空间的圆】
##   屏幕空间的正圆无法表达坡地的高低起伏，坡上/台阶处必然穿模、浮空。
##   这里照搬【火焰灼烧】圈选器（scripts/spells/spell_targeting.gd）的地形贴合思路：
##   逐点向下打射线求地面高度 -> 用采样高度构建贴着地形的环带网格。
##   参考处已验证的关键经验（已照抄）：
##     · 起终点从 y0+12 打到 y0-60，保证台面/沟壑都能命中；
##     · 命中点抬高 lift 避免与地面 z-fighting；
##     · 法线太斜（墙面）的命中滤掉，否则圈会"爬上墙"；
##     · 高度要**限幅 + 坡度限幅 + 抹圆**，否则不规则地面上顶点会抖
##       （smooth_lift/drop、slope_step、slope_passes —— 与参考同口径）。
##
## 【4 个要求对应的实现】
##   ① 没被草遮住时不显示：整圈**可见性开关**，不是逐像素剔除。
##   ② 圈要完整：着色器只做纯色填充，**没有任何 discard**，且关掉引擎深度测试
##      （否则地形/草会把圈切掉一块）。
##   ③ 走动不抖：重建阈值放大（rebuild_move），大幅降低重建频率。
##   ④ 不规则表面平滑：每次重建做"坡度限幅 + 沿圆周抹圆"（同参考实现），
##      再对高度做一阶低通，抑制相邻两次重建之间的跳变。

## 角度分段（越大越圆；射线数 = 段数 × 2）
@export var segments := 64
## 圈半径 / 环带宽度（米）
@export var radius := 0.30
@export var width := 0.06
## 抬高（米）：避免与地面 z-fighting
@export var lift := 0.01
## ★ ③ 重建阈值（米）：角色移动超过这么多才重建网格。
##   调大 -> 重建更少 -> 更不抖（代价是圈跟随角色的延迟更明显）。
@export var rebuild_move := 0.05
## 允许的最大地面法线倾角（cos 值）：更斜就当没命中（别爬上墙）
@export var min_normal_up := 0.55
## 圈颜色（半透明白）
@export var color := Color(1.0, 1.0, 1.0, 0.03)
## ★ ① 只在"被草遮挡"时显示
@export var grass_occlusion_only := true
## 判定"被草遮挡"时最多检查多少株草
@export var grass_check_count := 400
## 显示/隐藏余量（米）：脚底要高出草顶这么多才认为"没被遮挡" -> 隐藏
@export var hide_margin := 0.12
## 切换滞回（米）：避免在阈值附近来回闪
@export var hysteresis := 0.06
## ★ ④ 平滑参数（与参考实现同口径）
@export var smooth_lift := 0.35
@export var smooth_drop := 0.35
@export var slope_step := 0.22
@export var slope_passes := 4
## 高度低通系数（0~1）：每次重建把新采样与上次结果混合，越小越稳
@export var height_lerp := 0.55

var _mesh: MeshInstance3D = null
var _mat: ShaderMaterial = null
var _player: Node3D = null
var _last_build_pos := Vector3(1.0e9, 1.0e9, 1.0e9)
var _has_mesh := false
## 上一次重建的内/外沿高度（时间低通用）
var _prev_inner: PackedFloat32Array = PackedFloat32Array()
var _prev_outer: PackedFloat32Array = PackedFloat32Array()
## ① 可见性滞回状态
var _shown := false
## SGT 草实例缓存（世界坐标 + 顶部高度）
var _grass_pts: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)
	_build_node()


func _build_node() -> void:
	_mesh = MeshInstance3D.new()
	_mesh.name = "FootRing"
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
// ⚠ render_priority 不能写在 spatial 里（会编译失败）
// ★ depth_test_disabled：圈在地面高度，地形/草在它前面；若让引擎做深度测试，
//   圈的像素会被**直接剔除** -> 圈被切成残缺的一块（用户要求"完整的圈"）。
//   关掉它，圈就是完整的一圈。
//   depth_draw_never：不写深度缓冲，避免影响后续绘制。
// ⚠ 本着色器**不做任何 discard**：可见性由脚本整体开关（要求①）。
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never,
		ambient_light_disabled, fog_disabled, blend_mix;

uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 0.55);

void fragment() {
	ALBEDO = ring_color.rgb;
	ALPHA = ring_color.a;
}
"""
	_mat.shader = sh
	_mat.set_shader_parameter("ring_color", color)
	_mesh.material_override = _mat
	_mesh.visible = false          # 由可见性判定决定何时显示
	# ★ 直接挂到主场景（先 add_child 到自身再搬会报 "already has a parent"）
	if get_tree() != null and get_tree().current_scene != null:
		get_tree().current_scene.add_child(_mesh)
	else:
		add_child(_mesh)


func _process(_delta: float) -> void:
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
		if _player == null:
			return
	var p := _player.global_position
	# ③ 大幅降低重建频率，减少顶点跳动
	if not _has_mesh or p.distance_to(_last_build_pos) >= rebuild_move:
		_last_build_pos = p
		_rebuild(p)
	# ① 只在被草遮挡时显示
	_update_visibility(p)


## ★ ① 可见性：角色脚底没被草挡住 -> 整圈隐藏。
##   判据：脚底是否明显高于附近草顶（高于 -> 草盖不到角色 -> 隐藏）。
##   用滞回避免在阈值附近来回闪。
func _update_visibility(p: Vector3) -> void:
	if _mesh == null:
		return
	if not grass_occlusion_only:
		_mesh.visible = true
		return
	# ⚠ 显式标注 Variant：函数返回 Variant（可能 null），用 := 会被判为类型不明确
	var top: Variant = _nearby_grass_top(p)
	if top == null:
		_mesh.visible = false          # 附近没有 SGT 草：没什么可遮挡的
		_shown = false
		return
	var t: float = top
	if _shown:
		if p.y > t + hide_margin:
			_shown = false
	else:
		if p.y <= t + hide_margin - hysteresis:
			_shown = true
	_mesh.visible = _shown


## 附近 SGT 草的**最高顶部**（没有草返回 null）
func _nearby_grass_top(p: Vector3) -> Variant:
	if _grass_pts.is_empty():
		_cache_grass()
	var r := maxf(0.6, radius + 0.6)
	var r2 := r * r
	var best: float = -1.0e9
	var n := 0
	for v in _grass_pts:
		var p4: Vector4 = v
		var dx := p4.x - p.x
		var dz := p4.z - p.z
		if dx * dx + dz * dz > r2:
			continue
		n += 1
		if p4.w > best:
			best = p4.w
		if n >= grass_check_count:
			break
	if best < -1.0e8:
		return null
	return best


## 缓存 SGT 草实例的世界坐标与顶部高度（草是静态的，缓存一次即可）
func _cache_grass() -> void:
	_grass_pts.clear()
	if get_tree() == null:
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is MultiMeshInstance3D and nd.has_meta(&"SimpleGrassTextured"):
			var mmi := nd as MultiMeshInstance3D
			if mmi.multimesh != null:
				var local_h := mmi.get_aabb().size.y
				if local_h <= 0.0001:
					local_h = 1.0
				var xf := mmi.global_transform
				for i in range(mini(mmi.multimesh.instance_count, 6000)):
					var t := mmi.multimesh.get_instance_transform(i)
					var w: Vector3 = xf * t.origin
					var sy := absf(t.basis.get_scale().y)
					_grass_pts.append(Vector4(w.x, w.y, w.z, w.y + local_h * sy))
		for c in nd.get_children():
			stack.append(c)


## ★ 逐点采地形高度并构建环带网格（地形贴合 + 平滑）
func _rebuild(p: Vector3) -> void:
	var vp := get_viewport()
	if vp == null or _mesh == null:
		return
	var world: World3D = vp.find_world_3d()
	if world == null:
		return
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return
	# 复用同一个查询对象（参考实现也是这么省分配的）
	var q := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.ZERO)
	q.collision_mask = 0xFFFFFFFF
	var exclude: Array = []
	if _player is CollisionObject3D:
		exclude = [(_player as CollisionObject3D).get_rid()]
	q.exclude = exclude

	var y0 := p.y
	var n := maxi(8, segments)
	var h_out := PackedFloat32Array()
	var h_in := PackedFloat32Array()
	h_out.resize(n)
	h_in.resize(n)
	var hit_any := false
	var r_out: float = radius
	var r_in: float = maxf(0.01, radius - width)
	for s in range(n):
		var a := float(s) / float(n) * TAU
		var dx := cos(a)
		var dz := sin(a)
		for which in range(2):
			var rr: float = r_out if which == 0 else r_in
			var x := p.x + dx * rr
			var z := p.z + dz * rr
			var y := y0
			q.from = Vector3(x, y0 + 12.0, z)
			q.to = Vector3(x, y0 - 60.0, z)
			var hit: Dictionary = space.intersect_ray(q)
			if not hit.is_empty():
				var ny: float = (hit.get("normal", Vector3.UP) as Vector3).normalized().y
				if ny >= min_normal_up:
					y = (hit["position"] as Vector3).y
					hit_any = true
			if which == 0:
				h_out[s] = y
			else:
				h_in[s] = y
	if not hit_any:
		_mesh.visible = false
		return
	# ★ ④ 平滑：限幅 -> 坡度限幅 -> 沿圆周抹圆 -> 时间低通（口径同参考实现）
	h_out = _smooth_ring(h_out, y0, n)
	h_in = _smooth_ring(h_in, y0, n)
	h_out = _temporal(h_out, _prev_outer, n)
	h_in = _temporal(h_in, _prev_inner, n)
	_prev_outer = h_out
	_prev_inner = h_in
	# 构建顶点
	var inner := PackedVector3Array()
	var outer := PackedVector3Array()
	inner.resize(n)
	outer.resize(n)
	for s in range(n):
		var a2 := float(s) / float(n) * TAU
		var cx := cos(a2)
		var cz := sin(a2)
		outer[s] = Vector3(p.x + cx * r_out, h_out[s] + lift, p.z + cz * r_out)
		inner[s] = Vector3(p.x + cx * r_in, h_in[s] + lift, p.z + cz * r_in)
	_mesh.mesh = _build_ring_mesh(inner, outer)
	_has_mesh = true


## ★ 单环平滑（照搬参考实现的 ①②③）：
##   ① 硬限幅：把"墙顶 / 深沟"的大落差压进 ±limit
##   ② 坡度限幅：相邻顶点落差不超过 slope_step，迭代 slope_passes 轮
##      —— 保住整体坡形，只把"一级跳几米"的尖刺削平
##   ③ 一轮三点平均抹圆（幅度小，不会抹掉坡形）
func _smooth_ring(h: PackedFloat32Array, y0: float, n: int) -> PackedFloat32Array:
	var cur := PackedFloat32Array()
	cur.resize(n)
	for s in range(n):
		cur[s] = clampf(h[s], y0 - smooth_drop, y0 + smooth_lift)
	var passes := maxi(slope_passes, 0)
	var st := maxf(slope_step, 0.0001)
	for _pass in range(passes):
		var nxt := PackedFloat32Array()
		nxt.resize(n)
		for s in range(n):
			var l := cur[(s - 1 + n) % n]
			var r := cur[(s + 1) % n]
			var lo := minf(l, r) - st
			var hi := maxf(l, r) + st
			nxt[s] = clampf(cur[s], lo, hi)
		cur = nxt
	var fin := PackedFloat32Array()
	fin.resize(n)
	for s in range(n):
		var l2 := cur[(s - 1 + n) % n]
		var r2 := cur[(s + 1) % n]
		fin[s] = (cur[s] * 2.0 + l2 + r2) * 0.25
	return fin


## ★ 时间低通：把本次采样与上次结果混合，抑制相邻两次重建之间的跳变
func _temporal(h: PackedFloat32Array, prev: PackedFloat32Array, n: int) -> PackedFloat32Array:
	if prev.size() != n:
		return h
	var k := clampf(height_lerp, 0.0, 1.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for s in range(n):
		out[s] = lerpf(prev[s], h[s], k)
	return out


## 由内外两圈顶点构建环带（每段 2 个三角形）
func _build_ring_mesh(inner: PackedVector3Array, outer: PackedVector3Array) -> ArrayMesh:
	var n := inner.size()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in range(n):
		var s2 := (s + 1) % n
		var i0 := inner[s]
		var i1 := inner[s2]
		var o0 := outer[s]
		var o1 := outer[s2]
		st.set_normal(Vector3.UP)
		st.add_vertex(i0); st.add_vertex(o0); st.add_vertex(o1)
		st.set_normal(Vector3.UP)
		st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(i1)
	return st.commit()


func _find_player() -> Node3D:
	if get_tree() == null:
		return null
	for n in get_tree().get_nodes_in_group("player"):
		if n is Node3D:
			return n as Node3D
	return null


func _exit_tree() -> void:
	if _mesh != null and is_instance_valid(_mesh):
		_mesh.queue_free()

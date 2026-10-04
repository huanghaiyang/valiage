extends Node3D
## 流水治疗 —— 两股流水从脚底生成、交错缠绕着爬到头顶，汇聚后在身上形成一层流水。
##
## 【包裹方式】水膜直接铺在**角色自己的网格**上（material_overlay），不是球体也不是圆柱：
##   形状 = 角色身形，且**零穿模**（几何上就贴在体表）。两股流水的"缠绕 + 从下往上爬"
##   也是在体表按世界坐标的螺旋相位算的（见 water_veil.gdshader），所以爬升同样不穿模。
##
## 【实时算角色点】每帧遍历角色的网格算世界包围盒，把
##   中心(xz) / 脚底高度 / 身高 喂给着色器 —— 所以角色换模型、缩放、站在坡上都能贴合。
##
## 三个阶段：
##   ① 缠绕上升 climb_time   两股流水从脚底交错爬到头顶（climb 0→1）
##   ② 汇聚成膜 veil_time    整身转成流动水膜（veil 0→1），流水带淡出
##   ③ 维持                  持续耗蓝；停手或**法力不足**后淡出
##
## 对外接口与其它术法一致：
##   setup / start_cast / stop_cast / is_casting / aim_dir / origin_global / ran_out_of_mana

const VEIL_SHADER := "res://assets/shaders/water_veil.gdshader"
const STREAM_SHADER := "res://assets/shaders/water_stream.gdshader"
const NOISE_TEX := "res://assets/textures/法术特效/T_VFX_Noise_9.PNG"

@export var mana_per_sec := 24.0
@export var climb_time := 1.15        ## 两股流水从脚底爬到头顶的时间
@export var veil_time := 0.55         ## 汇聚成膜的时间
@export var fade_time := 0.7          ## 停手后的淡出时间
@export var turns := 2.2              ## 缠绕圈数
@export var texture_scroll := 0.55    ## 流动速度

# ---- 实体螺旋水带（缠绕上升阶段的主体）----
## 水带管半径（米）。细一点才贴得紧：管心离皮肤的距离 = 这个值 × 1.25
@export var stream_radius := 0.028
## 绕行半径相对身体剖面的外扩比例（现在只用于 AABB 兜底）
@export var stream_margin := 0.10
@export var stream_segments := 120    ## 沿管的环数（44 太疏，螺旋会一段一段的 -> 折角）
@export var stream_sides := 8         ## 截面边数（5 边是五棱柱，看得出面片）

# ---- 真实曲面采样（替代 AABB 包络）----
## ★ 曲面只在**技能发动那一刻算一次**（不做定时重算）。
##   之前按 surface_refresh 定时重算是白做功：角色身体 7 个网格是蒙皮网格，
##   CPU 顶点是绑定姿势、不随动画变，重算结果一模一样；而且表在重算时出现的空洞
##   会让水带突然外弹（就是"闪一下"的来源之一）。算一次既省 CPU 也没有抖动。
@export var surface_h_bins := 48
@export var surface_a_bins := 48

# 0 = 关 / 1 = 上升 / 2 = 成膜与维持 / 3 = 淡出
const ST_OFF := 0
const ST_RISE := 1
const ST_VEIL := 2
const ST_FADE := 3

var casting := false

var _player: Node3D = null
var _mat: ShaderMaterial = null
var _mesh_prev: Array[Dictionary] = []     ## {mi, prev}
var _ran_out := false
var _state := ST_OFF
var _state_t := 0.0
var _last_box := AABB()

var _stream_mat: ShaderMaterial = null
var _streams: Array[MeshInstance3D] = []
var _profile: Array = []                    ## [y0, y1, 中心(xz), 半宽x, 半厚z]（AABB 兜底用）
var _surf: Array = []                       ## 真实曲面半径表 [高度分格][方位分格]
var _sh := 0
var _sa := 0
var _surface_verts := 0
var _surface_builds := 0                    ## 曲面表构建次数（自检：应为 1）
var _tube_fade0 := 0.0                      ## 进入淡出时水带的不透明度（淡出从这里往下降）
var _center_world := Vector3.ZERO
var _feet_world := 0.0
var _height_world := 1.8


func _ready() -> void:
	set_process(true)


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true
	if _state == ST_OFF or _state == ST_FADE:
		_apply_film()
		_state = ST_RISE
		_state_t = 0.0
		_setp("climb", 0.0)
		_setp("veil", 0.0)
		# ★ 体表那套螺旋亮带**全程关掉**：缠绕上升阶段由实体水带负责；
		#   两套同时画 = 同一股水画两遍，切换时一个淡出一个淡入就会闪。
		_setp("stream_fade", 0.0)


func stop_cast() -> void:
	casting = false


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


func aim_dir() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.FORWARD
	return -(_player as Node3D).global_transform.basis.z


func origin_global() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return global_position
	return (_player as Node3D).global_position


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _player != null and is_instance_valid(_player):
		global_position = _player.global_position
		_update_body_box()                     # 实时算角色点（中心/脚底/身高）+ AABB 兜底
		# 曲面表**不再定时重算**：发动时算一次即可（见 surface_h_bins 的说明）
	_state_t += delta
	match _state:
		ST_OFF:
			return
		ST_RISE:
			var k := clampf(_state_t / maxf(climb_time, 0.01), 0.0, 1.0)
			_setp("climb", k)                   # 两股流水交错往上爬
			# 水带网格**不重建**（发动时算一次的快照）；节点挂在玩家下，自动跟随
			if _stream_mat != null:
				_stream_mat.set_shader_parameter("climb", k)
				_stream_mat.set_shader_parameter("fade", 1.0)
			if k >= 1.0:
				_state = ST_VEIL
				_state_t = 0.0
		ST_VEIL:
			var k2 := clampf(_state_t / maxf(veil_time, 0.01), 0.0, 1.0)
			_setp("veil", k2)                   # 汇聚成膜（体表水膜淡入）
			_setp("stream_fade", 0.0)           # 体表亮带始终关（由实体水带负责上升段）
			if _stream_mat != null:
				_stream_mat.set_shader_parameter("climb", 1.0)
				# 实体水带与体表水膜做**匀速交叉淡出**，避免同时最亮造成闪
				_stream_mat.set_shader_parameter("fade", 1.0 - k2)
			if k2 >= 1.0:
				_setp("veil", 1.0)
				_setp("stream_fade", 0.0)
				if Mana.spend_rate(delta, mana_per_sec):
					_ran_out = false
				else:
					_ran_out = true
					_to_fade()
				if not casting:
					_to_fade()
		ST_FADE:
			var k3 := clampf(_state_t / maxf(fade_time, 0.01), 0.0, 1.0)
			_setp("veil", 1.0 - k3)
			_setp("stream_fade", 0.0)
			if _stream_mat != null:
				# 从进入淡出时的实际值继续降（成膜后 = 0，所以不会再冒出来）
				_stream_mat.set_shader_parameter("fade", _tube_fade0 * (1.0 - k3))
			if k3 >= 1.0:
				_cleanup()


# ---------------------------------------------------------------- 内部
func _to_fade() -> void:
	if _state == ST_RISE or _state == ST_VEIL:
		# ★ 记下淡出**开始时水带的实际不透明度**，淡出必须从这里继续往下降到 0。
		#   之前写成 fade = 1.0 - k3，等于从"全亮"重新开始 —— 成膜阶段水带已经淡到 0，
		#   一进淡出就跳回 1.0，表现为"水带完全隐藏后猛地又显示一下再消失"（实测症状）。
		if _stream_mat != null:
			_tube_fade0 = float(_stream_mat.get_shader_parameter("fade"))
		_state = ST_FADE
		_state_t = 0.0


## ★ 被直接释放（换法术/场景退出）时必须摘掉水膜，否则角色身上会永久粘一层水
func _exit_tree() -> void:
	_restore()


func _cleanup() -> void:
	_state = ST_OFF
	_restore()


func _restore() -> void:
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).material_overlay = d["prev"]
	_mesh_prev.clear()
	_free_streams()          # 实体水带也要一起回收


func _setp(param: String, v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter(param, v)


# ---------------------------------------------------------------- 装配
func _apply_film() -> void:
	if _mat == null:
		_mat = ShaderMaterial.new()
		var sh := load(VEIL_SHADER) as Shader
		if sh == null:
			push_warning("[WaterHeal] 缺少 water_veil.gdshader")
			return
		_mat.shader = sh
		var nt := load(NOISE_TEX) as Texture2D
		if nt != null:
			_mat.set_shader_parameter("noise_tex", nt)
		_mat.set_shader_parameter("turns", turns)
		_mat.set_shader_parameter("flow_speed", texture_scroll)
	if _player == null or not is_instance_valid(_player):
		return
	if _mesh_prev.is_empty():
		var meshes: Array[MeshInstance3D] = []
		_gather_meshes(_player, meshes)
		for mi in meshes:
			_mesh_prev.append({"mi": mi, "prev": mi.material_overlay})
			mi.material_overlay = _mat
	_update_body_box()
	# ★ 必须**先算真实曲面表、再建水带**：否则第一帧的水带会用 AABB 兜底（方方正正且偏大），
	#   要等到下一次定时刷新才贴到真实曲面上（实测踩过：水带一开始是方包络的样子）。
	_build_surface_profile()
	# 两条**实体**螺旋水带（错开半圈 -> 交错缠绕）
	if _stream_mat == null:
		_stream_mat = _make_stream_mat()
	if _streams.is_empty():
		for i in 2:
			var node := MeshInstance3D.new()
			node.name = "WaterStream%d" % i
			node.material_override = _stream_mat
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# ★ 挂到**角色节点下**：这样位移、弹跳、转身都自动跟随，
			#   不需要每帧重建（网格形状是发动瞬间的快照）。
			_player.add_child(node)
			_streams.append(node)
		_rebuild_streams()


## 实时算角色的世界包围盒 -> 中心(xz)/脚底/身高，喂给着色器
func _update_body_box() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var lo := 1e9
	var hi := -1e9
	var best_span := -1.0
	var bcx := 0.0
	var bcz := 0.0
	var sum_x := 0.0
	var sum_z := 0.0
	var n := 0
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi == null or not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null:
			continue
		var aabb := (mi as MeshInstance3D).mesh.get_aabb()
		var xf := (mi as MeshInstance3D).global_transform
		var mlo := 1e9
		var mhi := -1e9
		var mx := 0.0
		var mz := 0.0
		for i in range(8):
			var c := aabb.position + Vector3(
					aabb.size.x if (i & 1) != 0 else 0.0,
					aabb.size.y if (i & 2) != 0 else 0.0,
					aabb.size.z if (i & 4) != 0 else 0.0)
			var w := xf * c
			mlo = minf(mlo, w.y)
			mhi = maxf(mhi, w.y)
			mx += w.x
			mz += w.z
			n += 1
		lo = minf(lo, mlo)
		hi = maxf(hi, mhi)
		sum_x += mx
		sum_z += mz
		# ★ 中轴取**最高的那个网格**（躯干）的中心，而不是所有 AABB 角点的质心。
		#   质心会被法杖 / 伸出的手臂拉偏，后果是水带**一侧穿身、另一侧离得老远**
		#   （真实角色实测：离中轴 0.024 ~ 1.043 米）。对称的测试圆柱暴露不出这个问题。
		var span := mhi - mlo
		if span > best_span:
			best_span = span
			bcx = mx / 8.0
			bcz = mz / 8.0
	if n == 0 or lo > hi:
		return
	_center_world = Vector3(bcx if best_span > 0.0 else sum_x / n, 0.0,
			bcz if best_span > 0.0 else sum_z / n)
	_last_box = AABB(Vector3(_center_world.x, lo, _center_world.z),
			Vector3(0.1, hi - lo, 0.1))
	_feet_world = lo
	_height_world = maxf(hi - lo, 0.2)
	if _mat != null:
		_mat.set_shader_parameter("center_xz", _center_world)
		_mat.set_shader_parameter("feet_y", _feet_world)
		_mat.set_shader_parameter("body_h", _height_world)
	_build_profile()


func _gather_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		else:
			_gather_meshes(c, out)


# ---------------------------------------------------------------- 实体螺旋水带
## 高度剖面：每个角色网格 -> [y0, y1, AABB 中心(xz), 半宽x, 半厚z]（世界坐标）
## ★ 存的是**每个网格自己的** AABB，而不是"整体最大半径"。
##   整体最大半径会让水带绕成一个**圆形轨道悬在身外**；
##   逐网格 AABB 才能按方向取到体表距离 -> 水带**贴着身体轮廓**（腰细的地方贴进去、
##   肩/手臂的地方鼓出来）。
func _build_profile() -> void:
	_profile.clear()
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi == null or not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null:
			continue
		var aabb := (mi as MeshInstance3D).mesh.get_aabb()
		var xf := (mi as MeshInstance3D).global_transform
		var lo := 1e9
		var hi := -1e9
		var minx := 1e9
		var maxx := -1e9
		var minz := 1e9
		var maxz := -1e9
		for i in range(8):
			var c := aabb.position + Vector3(
					aabb.size.x if (i & 1) != 0 else 0.0,
					aabb.size.y if (i & 2) != 0 else 0.0,
					aabb.size.z if (i & 4) != 0 else 0.0)
			var w := xf * c
			lo = minf(lo, w.y)
			hi = maxf(hi, w.y)
			minx = minf(minx, w.x)
			maxx = maxf(maxx, w.x)
			minz = minf(minz, w.z)
			maxz = maxf(maxz, w.z)
		if lo <= hi:
			_profile.append([lo, hi, Vector3((minx + maxx) * 0.5, 0.0, (minz + maxz) * 0.5),
					(maxx - minx) * 0.5, (maxz - minz) * 0.5])


## 用"腿胯高度带"（身高的 15%~45%）的包围盒中点定中轴。返回 [是否量到, cx, cz]
func _measure_axis() -> Array:
	var minx := 1e9
	var maxx := -1e9
	var minz := 1e9
	var maxz := -1e9
	var got := false
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi == null or not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null:
			continue
		var mesh := (mi as MeshInstance3D).mesh
		var xf := (mi as MeshInstance3D).global_transform
		for s in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(s)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts == null or verts.is_empty():
				continue
			var stride := 1
			if verts.size() > 3000:
				stride = int(ceil(float(verts.size()) / 3000.0))
			var i := 0
			while i < verts.size():
				var w := xf * verts[i]
				i += stride
				var hh := (w.y - _feet_world) / maxf(_height_world, 0.001)
				if hh < 0.15 or hh > 0.45:
					continue
				minx = minf(minx, w.x)
				maxx = maxf(maxx, w.x)
				minz = minf(minz, w.z)
				maxz = maxf(maxz, w.z)
				got = true
	if not got or minx > maxx:
		return [false, 0.0, 0.0]
	return [true, (minx + maxx) * 0.5, (minz + maxz) * 0.5]


## 真实曲面：遍历角色**所有网格的顶点**，按 (高度分格 × 方位分格) 建一张体表半径表。
## 每格取**最大**半径 = 该格方向上的外轮廓 -> 水带贴着真实曲面（圆的贴圆、扁的贴扁），
## 而不是 AABB 那种方方正正、还偏大的包络。
##
## 代价：要遍历顶点，所以按 surface_refresh 秒的节奏刷新（不是每帧）。
func _build_surface_profile() -> void:
	# ★ 先用"腿胯高度带"重新定中轴，再建表。
	#   中轴偏一点点，水带就会**一侧穿进身体、另一侧离得老远**
	#   （真实角色实测：中轴取 AABB 质心时，离轴最小只有 0.024 米 = 明显穿身）。
	#   腿/胯左右对称，用这一段包围盒的中点当中轴最稳，不会被手臂或法杖带偏。
	var ax := _measure_axis()
	if ax[0]:
		_center_world = Vector3(ax[1], 0.0, ax[2])
	var nh := maxi(surface_h_bins, 4)
	var na := maxi(surface_a_bins, 4)
	_sh = nh
	_sa = na
	# ★ 保留上一轮的格子：动画中某些 (高度,方位) 格这一帧采不到顶点，
	#   若把它清零 -> _surface_dist 会退回 AABB -> 水带突然外弹一下（实测症状=闪烁/跳动）。
	var old: Array = _surf
	_surf = []
	_surf.resize(nh)
	for i in nh:
		var row := PackedFloat32Array()
		row.resize(na)
		if old.size() == nh and (old[i] as PackedFloat32Array).size() == na:
			row = (old[i] as PackedFloat32Array).duplicate()
		_surf[i] = row
	var total := 0
	_surface_builds += 1          # 自检用：应当只有 1 次（发动时算一次）
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi == null or not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null:
			continue
		var mesh := (mi as MeshInstance3D).mesh
		var xf := (mi as MeshInstance3D).global_transform
		for s in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(s)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts == null or verts.is_empty():
				continue
			# 顶点多的网格抽稀（只影响精度，不影响保守性：每格取最大）
			var stride := 1
			if verts.size() > 6000:
				stride = int(ceil(float(verts.size()) / 6000.0))
			var i := 0
			while i < verts.size():
				var w := xf * verts[i]
				i += stride
				total += 1
				var hh := (w.y - _feet_world) / maxf(_height_world, 0.001)
				if hh < 0.0 or hh > 1.0:
					continue
				var dx := w.x - _center_world.x
				var dz := w.z - _center_world.z
				var dist := sqrt(dx * dx + dz * dz)
				if dist < 1e-4:
					continue
				var hi := clampi(int(hh * float(nh - 1) + 0.5), 0, nh - 1)
				var ang := atan2(dz, dx)
				var ai := int((ang + PI) / TAU * float(na)) % na
				var row: PackedFloat32Array = _surf[hi]
				if dist > row[ai]:
					row[ai] = dist
	_surface_verts = total


## 真实曲面的兜底：AABB 在该方向上的支撑距离（恒 ≥ 真实表面 -> 保守不穿模）
func _aabb_dist(hh: float, dir: Vector3) -> float:
	var y := _feet_world + hh
	var best := 0.0
	var found := false
	for e in _profile:
		if y < float(e[0]) - 0.03 or y > float(e[1]) + 0.03:
			continue
		var c: Vector3 = e[2]
		var hx: float = e[3]
		var hz: float = e[4]
		var d: float = (c.x - _center_world.x) * dir.x + (c.z - _center_world.z) * dir.z \
				+ absf(dir.x) * hx + absf(dir.z) * hz
		best = maxf(best, d)
		found = true
	return best if found else 0.16


## 局部高度 hh、水平方向 dir 处的体表距离（顶点表插值；该格无数据则退回 AABB）
func _surface_dist(hh: float, dir: Vector3) -> float:
	if _surf.is_empty():
		return _aabb_dist(hh, dir)
	var hb := clampf(hh / maxf(_height_world, 0.001), 0.0, 1.0) * float(_sh - 1)
	var i0: int = int(floor(hb))
	var i1: int = mini(i0 + 1, _sh - 1)
	var ft: float = hb - float(i0)
	var ang := atan2(dir.z, dir.x)
	var ab: float = (ang + PI) / TAU * float(_sa)
	var a0: int = int(floor(ab)) % _sa
	var a1: int = (a0 + 1) % _sa
	var fa: float = ab - floor(ab)
	var r0: PackedFloat32Array = _surf[i0]
	var r1: PackedFloat32Array = _surf[i1]
	var v00 := r0[a0]
	var v01 := r0[a1]
	var v10 := r1[a0]
	var v11 := r1[a1]
	# ★ 插值：**只有两边都采到点时才插值**。
	#   空格子(=0)参与插值会把值拉到 0 -> 水带穿模（实测穿入 399 个顶点）；
	#   而完全不插值 -> 管心半径按分格一格一格跳 -> 水带全是折角（实测症状）。
	#   所以：两侧都有值就插，否则取有值的那侧，全空退回保守的 AABB。
	var d0 := v00
	if v00 > 0.0 and v01 > 0.0:
		d0 = lerpf(v00, v01, fa)
	elif v01 > 0.0:
		d0 = v01
	var d1 := v10
	if v10 > 0.0 and v11 > 0.0:
		d1 = lerpf(v10, v11, fa)
	elif v11 > 0.0:
		d1 = v11
	var d := d0
	if d0 > 0.0 and d1 > 0.0:
		d = lerpf(d0, d1, ft)
	elif d1 > 0.0:
		d = d1
	if d <= 0.0:
		return _aabb_dist(hh, dir)      # 这格没采到顶点 -> 退回保守的 AABB
	return d


func _make_stream_mat() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := load(STREAM_SHADER) as Shader
	if sh == null:
		push_warning("[WaterHeal] 缺少 water_stream.gdshader")
		return m
	m.shader = sh
	var nt := load(NOISE_TEX) as Texture2D
	if nt != null:
		m.set_shader_parameter("noise_tex", nt)
	m.set_shader_parameter("flow_speed", texture_scroll * 1.6)
	m.set_shader_parameter("climb", 0.0)
	m.set_shader_parameter("fade", 1.0)
	return m


## 生成一条螺旋水带的网格：沿高度布环，环心半径取自身体剖面
func _make_helix(phase: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# ★ 所有顶点放同一个平滑组：否则 generate_normals() 生成的是**逐面法线**，
	#   管身会有一片片的面片感（也是"折角多"的一部分）。
	st.set_smooth_group(0)
	var rings := maxi(stream_segments, 8)
	var sides := maxi(stream_sides, 3)
	var h_total := maxf(_height_world, 0.3)
	var prev: Array[Vector3] = []
	var prev_uv: Array[Vector2] = []
	for i in range(rings):
		var t := float(i) / float(rings - 1)
		var h := t * h_total
		var th := (phase + t * turns) * TAU
		var dir := Vector3(cos(th), 0.0, sin(th))
		# ★ 贴着身体：管心半径 = 该方向上的**体表距离** + 管半径（内壁正好贴在皮肤上）
		var surf := _surface_dist(h, dir)
		var r := surf + stream_radius * 1.25
		var c := dir * r + Vector3(0.0, h, 0.0)
		# 切向（用下一小步的位置差近似）
		var t2 := minf(t + 0.02, 1.0)
		var h2 := t2 * h_total
		var th2 := (phase + t2 * turns) * TAU
		var dir2 := Vector3(cos(th2), 0.0, sin(th2))
		var r2 := _surface_dist(h2, dir2) + stream_radius * 1.25
		var c2 := dir2 * r2 + Vector3(0.0, h2, 0.0)
		var tan := c2 - c
		if tan.length_squared() < 1e-8:
			tan = Vector3.UP
		tan = tan.normalized()
		var radial := dir
		var bin := tan.cross(radial)
		if bin.length_squared() < 1e-8:
			bin = Vector3.UP
		bin = bin.normalized()
		var ring: Array[Vector3] = []
		var uvs: Array[Vector2] = []
		for s in range(sides + 1):
			var a := float(s) / float(sides) * TAU
			# 截面略扁（飘带感），不是正圆管
			var off := radial * (cos(a) * stream_radius * 1.25) \
					+ bin * (sin(a) * stream_radius * 0.70)
			ring.append(c + off)
			uvs.append(Vector2(float(s) / float(sides), t))
		if prev.size() > 0:
			for s in range(sides):
				st.set_uv(prev_uv[s])
				st.add_vertex(prev[s])
				st.set_uv(uvs[s])
				st.add_vertex(ring[s])
				st.set_uv(uvs[s + 1])
				st.add_vertex(ring[s + 1])
				st.set_uv(prev_uv[s])
				st.add_vertex(prev[s])
				st.set_uv(uvs[s + 1])
				st.add_vertex(ring[s + 1])
				st.set_uv(prev_uv[s + 1])
				st.add_vertex(prev[s + 1])
		prev = ring
		prev_uv = uvs
	st.generate_normals()
	return st.commit()


## 生成两条水带（**只在发动时调用一次**）。节点挂在玩家下面，所以位置用玩家局部坐标：
## 位移 / 弹跳 / 转身都自动跟随，不需要重建。
func _rebuild_streams() -> void:
	if _streams.is_empty():
		return
	var target := Vector3(_center_world.x, _feet_world, _center_world.z)
	var local := target
	if _player != null and is_instance_valid(_player):
		local = _player.global_transform.affine_inverse() * target
	for i in _streams.size():
		var node := _streams[i]
		if node == null or not is_instance_valid(node):
			continue
		node.position = local
		node.mesh = _make_helix(0.0 if i == 0 else 0.5)   # 两股错开半圈 -> 交错缠绕


func _free_streams() -> void:
	for n in _streams:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_streams.clear()

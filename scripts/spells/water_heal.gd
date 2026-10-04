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
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
const SHEET_ID := "water_heal"

# ★ 数值全部来自 data/spell_sheet.json（改表即可，不用改代码）。
#   下面的默认值只是表缺失时的兜底。
@export var mana_cost := 20.0         ## 一次性单次耗蓝（表: mana_cost）
@export var hold_time := 7.0          ## 薄膜覆盖阶段的持续时间（表: duration）
@export var climb_time := 1.15        ## 水流缠绕上升（表: cast_climb）
@export var veil_time := 0.55         ## 汇聚成膜（表: cast_veil）
@export var fade_time := 0.7          ## 淡出（表: fade_time）
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

# ---- 水汽（成膜阶段身体周围飘散的雾气）----
@export var mist_amount := 28
@export var mist_lifetime := 2.2

# ---- 水珠（成膜阶段从头顶往下掉落）----
@export var drop_count := 48
## 水珠生成点距**身体表面**的距离（米）。需求：1cm
@export var drop_gap := 0.01
@export var drop_initial_speed := 0.4     ## 向下初速
@export var drop_gravity := 9.8
## 发射高度带从头顶扩展到全身所用的时间（"从头上开始往下"）
@export var drop_sweep_time := 1.6
## ★ 每颗水珠落地后随机等待多久才重生（关键：不给随机延迟的话，整批水珠会
##   **同一帧生成 -> 同一帧落地 -> 同一帧重生**，掉成一"帘"，就是"几次整齐下落"的来源）
@export var drop_respawn_spread := 0.55
## ★ 开局错开时间：第一滴出现后的这段时间内，48 颗陆续开始（避免开场一整帘同时落）
@export var drop_start_spread := 1.6

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

# 水汽 / 水珠
var _mist: GPUParticles3D = null
var _drops_node: MultiMeshInstance3D = null
var _drop_pos := PackedVector3Array()       ## 玩家局部坐标
var _drop_vel := PackedVector3Array()
var _drop_alive := PackedByteArray()
var _drop_delay := PackedFloat32Array()     ## 每颗的**独立随机**重生延迟（错开时间用）
var _drop_ground := 0.0                     ## 玩家局部的地面高度
var _drop_sweep := 0.0                      ## 0 = 只从头顶出，1 = 全身
var _drops_on := false
var _hold_t := 0.0                          ## 成型后已经覆盖了多久（对比 hold_time）
var _center_world := Vector3.ZERO
var _feet_world := 0.0
var _height_world := 1.8


func _ready() -> void:
	set_process(true)
	_load_sheet()


## 从数值表读取本术法的参数（表缺失则保留兜底默认值）
func _load_sheet() -> void:
	if not SHEET.has(SHEET_ID):
		push_warning("[WaterHeal] 数值表里没有 %s" % SHEET_ID)
		return
	mana_cost = SHEET.f(SHEET_ID, "mana_cost", mana_cost)
	climb_time = SHEET.f(SHEET_ID, "cast_climb", climb_time)
	veil_time = SHEET.f(SHEET_ID, "cast_veil", veil_time)
	hold_time = SHEET.f(SHEET_ID, "duration", hold_time)
	fade_time = SHEET.f(SHEET_ID, "fade_time", fade_time)


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player


# ---------------------------------------------------------------- 对外
## 一次性施法：按一次就放完（不用按住）。蓝在**发动瞬间**一次性扣。
func start_cast() -> void:
	if _state != ST_OFF and _state != ST_FADE:
		return
	_ran_out = false
	if mana_cost > 0.0:
		# ★ 必须先自己判断够不够：Mana.try_spend() 在余额不足时**会把蓝扣到 0** 再返回 false
		#   （实测 5 -> 0），等于"放不出来还把蓝清空"。
		if float(Mana.get("current")) < mana_cost:
			_ran_out = true
			return
		if not Mana.try_spend(mana_cost):
			_ran_out = true
			return
	casting = true
	_hold_t = 0.0
	_apply_film()
	_state = ST_RISE
	_state_t = 0.0
	_setp("climb", 0.0)
	_setp("veil", 0.0)
	# ★ 体表那套螺旋亮带**全程关掉**：缠绕上升阶段由实体水带负责；
	#   两套同时画 = 同一股水画两遍，切换时一个淡出一个淡入就会闪。
	_setp("stream_fade", 0.0)


## 一次性法术：松手**不停**，由自身时长控制（施法时间 + 覆盖时间 + 淡出）
func stop_cast() -> void:
	pass


func is_casting() -> bool:
	return _state != ST_OFF


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
			# ★ 水膜覆盖阶段：水汽 + 从头顶往下掉落的水珠
			_start_mist(true)
			_drops_on = true
			_update_drops(delta)
			# 成型完成后开始计算覆盖时间（一次性，不再扣蓝）；到点自动淡出
			if k2 >= 1.0:
				_hold_t += delta
				if _hold_t >= hold_time:
					_to_fade()
			if k2 >= 1.0:
				_setp("veil", 1.0)
				_setp("stream_fade", 0.0)
				# ★ 一次性法术：**没有**逐秒扣蓝，也**不因松手而中断**
				#   （蓝已在发动瞬间一次性扣完；时长由 表:duration 控制）
		ST_FADE:
			var k3 := clampf(_state_t / maxf(fade_time, 0.01), 0.0, 1.0)
			_setp("veil", 1.0 - k3)
			_setp("stream_fade", 0.0)
			if _stream_mat != null:
				# 从进入淡出时的实际值继续降（成膜后 = 0，所以不会再冒出来）
				_stream_mat.set_shader_parameter("fade", _tube_fade0 * (1.0 - k3))
			_start_mist(false)                # 水汽停
			_drops_on = false                 # 水珠不再重生，让空中的落完
			_update_drops(delta)
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
	if _mist != null and is_instance_valid(_mist):
		_mist.queue_free()
		_mist = null
	if _drops_node != null and is_instance_valid(_drops_node):
		_drops_node.queue_free()
		_drops_node = null
	_drops_on = false


func _setp(param: String, v: float) -> void:
	if _mat != null:
		_mat.set_shader_parameter(param, v)


## 水汽开关
func _start_mist(on: bool) -> void:
	if _mist != null and is_instance_valid(_mist):
		_mist.emitting = on


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
	_build_mist()
	_build_drops()
	_start_mist(false)
	_drops_on = false
	_drop_sweep = 0.0


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


# ---------------------------------------------------------------- 水汽 与 水珠
## 水汽：贴在身体周围缓慢上升的淡蓝雾气（成膜阶段）
func _build_mist() -> void:
	if _mist != null and is_instance_valid(_mist):
		return
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = maxf(_height_world * 0.5, 0.3)
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 40.0
	pm.initial_velocity_min = 0.06
	pm.initial_velocity_max = 0.26
	pm.gravity = Vector3(0, 0.20, 0)          # 水汽缓缓往上飘
	pm.scale_min = 0.35
	pm.scale_max = 0.95
	var grad := Gradient.new()
	grad.set_color(0, Color(0.70, 0.92, 1.0, 0.0))
	grad.set_color(1, Color(0.80, 0.95, 1.0, 0.0))
	grad.add_point(0.22, Color(0.72, 0.93, 1.0, 0.26))
	grad.add_point(0.70, Color(0.82, 0.96, 1.0, 0.16))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt

	var draw := StandardMaterial3D.new()
	draw.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	draw.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	draw.vertex_color_use_as_albedo = true
	draw.disable_receive_shadows = true
	var tex := load(NOISE_TEX) as Texture2D
	if tex != null:
		draw.albedo_texture = tex
	draw.albedo_color = Color(0.78, 0.93, 1.0, 0.55)
	var quad := QuadMesh.new()
	quad.size = Vector2(1.1, 1.1)
	quad.surface_set_material(0, draw)

	var p := GPUParticles3D.new()
	p.name = "WaterMist"
	p.amount = mist_amount
	p.lifetime = mist_lifetime
	p.local_coords = true                     # 跟着角色
	p.process_material = pm
	p.draw_pass_1 = quad
	p.material_override = draw
	p.visibility_aabb = AABB(Vector3(-3, -3, -3), Vector3(6, 6, 6))
	p.emitting = false
	_player.add_child(p)
	p.position = Vector3(0, _height_world * 0.45, 0)
	_mist = p


## 水珠：MultiMesh（数量少、要精确控制落点，所以用 GDScript 驱动而不是粒子着色器）
func _build_drops() -> void:
	if _drops_node != null and is_instance_valid(_drops_node):
		return
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(0.78, 0.95, 1.0, 0.9)
	mat.disable_receive_shadows = true
	var q := QuadMesh.new()
	q.size = Vector2(0.035, 0.055)
	q.surface_set_material(0, mat)

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = drop_count
	mm.mesh = q
	mm.visible_instance_count = drop_count

	var node := MultiMeshInstance3D.new()
	node.name = "WaterDrops"
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_player.add_child(node)                   # 挂在角色下 -> 位移/弹跳/转身自动跟随
	_drops_node = node

	_drop_pos.resize(drop_count)
	_drop_vel.resize(drop_count)
	_drop_alive.resize(drop_count)
	_drop_delay.resize(drop_count)
	for i in range(drop_count):
		_drop_alive[i] = 0
		# ★ 开局就错开：否则 48 颗同一帧出现、掉成一帘（"整齐下落"）
		_drop_delay[i] = randf() * drop_start_spread
	_drop_ground = _feet_world - _player.global_position.y


## 生成一颗水珠：位置 = 体表外 drop_gap（1cm）；高度按 sweep 从头顶往下铺开
func _spawn_drop(i: int) -> void:
	if _player == null or not is_instance_valid(_player):
		return
	# ★ "从头上开始往下"：发射高度带的下沿随 drop_sweep 从头顶(1.0)降到脚底(0.0)
	var lo := 1.0 - clampf(_drop_sweep, 0.0, 1.0)
	var hh := lerpf(lo, 1.0, randf()) * _height_world
	var a := randf() * TAU
	var dir := Vector3(cos(a), 0.0, sin(a))
	# ★ 体表外 1cm：直接查真实曲面表，再沿方向外推 drop_gap
	var r := _surface_dist(hh, dir) + drop_gap
	var world := Vector3(_center_world.x, _feet_world + hh, _center_world.z) + dir * r
	_drop_pos[i] = _player.global_transform.affine_inverse() * world
	_drop_vel[i] = Vector3(0.0, -drop_initial_speed, 0.0)
	_drop_alive[i] = 1


func _update_drops(delta: float) -> void:
	if _drops_node == null or not is_instance_valid(_drops_node):
		return
	var mm := _drops_node.multimesh
	if mm == null:
		return
	_drop_sweep = minf(_drop_sweep + delta / maxf(drop_sweep_time, 0.05), 1.0)
	_drop_ground = _feet_world - _player.global_position.y
	for i in range(drop_count):
		if _drop_alive[i] == 0:
			# 只在成膜阶段持续重生；淡出阶段就让剩在空中的落完。
			# ★ 必须等**各自的随机延迟**走完才重生 —— 这样水珠是零落滴下，
			#   而不是整批同一帧一起掉（那是"整齐下落"的根因）。
			if _drops_on:
				_drop_delay[i] -= delta
				if _drop_delay[i] <= 0.0:
					_spawn_drop(i)
			if _drop_alive[i] == 0:
				mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0, -999, 0)))
				continue
		var v := _drop_vel[i]
		v.y -= drop_gravity * delta
		_drop_vel[i] = v
		var p := _drop_pos[i] + v * delta
		_drop_pos[i] = p
		if p.y <= _drop_ground:
			_drop_alive[i] = 0                # 落到地面 -> 消失（等随机延迟后重生）
			_drop_delay[i] = randf() * drop_respawn_spread
			mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0, -999, 0)))
			continue
		# 下落越快，水滴拉得越长
		var stretch := clampf(1.0 + absf(v.y) * 0.06, 1.0, 2.2)
		var b := Basis().scaled(Vector3(1.0, stretch, 1.0))
		mm.set_instance_transform(i, Transform3D(b, p))

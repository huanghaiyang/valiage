class_name HeldStaff
extends Node3D
## 角色手里的法杖：负责**动态效果**。
##
## 动态效果分两层：
##   1. 待机动态 —— 法杖轻轻上下悬浮 + 缓慢自转，杖头有脉动的自发光光晕；
##   2. 元素动态 —— 按元素挂一套粒子（火苗上窜 / 冰晶飘落 / 奥术环绕 / 树叶打旋 /
##      圣光上升），颜色取自 StaffSystem.ELEMENT_COLORS。
##      每个元素有 3 种造型档位，**再用 staff_id 的散列抖动数量/速度/大小/扩散角**，
##      所以 146 根杖里同元素的几十根不会长得一样（见 _build_fx / _stable_hash）。
##
## 之所以不把这些烘进 GLB：法杖的元素会被"长老祝福"改写，效果必须能运行时切换。

const EL_FIRE := 1
const EL_ICE := 2
const EL_ARCANE := 3
const EL_NATURE := 4
const EL_HOLY := 5
const EL_EARTH := 6
const EL_STORM := 7

const HOVER_SPEED := 1.6
const PULSE_SPEED := 2.4

## 法杖在世界里的目标长度（米）。
## 角色约 1.7m 高，法杖必须**明显短于角色**才像"握在手里"，而不是杵在地上的一根旗杆。
## 之前净缩放 = 1（等于 Blender 里的真实尺寸 2.0~2.35m），比角色还高，
## 看起来就是站在旁边的一根大柱子。现在统一压到 1.25m。
const STAFF_WORLD_LEN := 1.25
## 握点位置：从杖底往上算的比例（0.32 = 握在下三分之一，正好是持杖的手位）
const GRIP_FRAC := 0.32

var staff_id := ""
var element: int = 0
var _spin := 0.25
var _hover := 0.03

var _pivot: Node3D = null          # 悬浮作用在这一层，不影响挂点
var _model: Node3D = null
var _fx_root: Node3D = null        # 杖头坐标系（挂在 _model 下，+Y 就是杖身方向）
var _glow: OmniLight3D = null
var _fx: Node3D = null
var _pulse := 0.0
var _base_y := 0.0
## 模型局部 +Y 在世界里朝上(+1)还是朝下(-1)
var _up := 1.0
## 挂点父级（角色 Visual）的世界缩放，用来把"世界长度"换算成模型局部缩放
var _parent_scale := 1.0
## 当前法杖在世界里的长度（米）
var _head_top := 1.25
## 需要实测一次杖头（装上新杖后置位）
var _need_measure := false
## 测量重试次数（装杖那一帧读到的 global_transform 可能是脏的）
var _measure_tries := 0

## 每根杖的动态效果参数。由 staff_id 的稳定散列推出，**同一元素的不同杖不会长得一样**；
## 也可以在 StaffSystem.reg() 的 extra 里用 fx_variant / fx_amount / fx_speed /
## fx_size / fx_spread 显式覆盖。
var _fx_variant := 0        # 造型档位 0/1/2
var _fx_amount := 1.0       # 粒子数量倍率
var _fx_speed := 1.0        # 初速倍率
var _fx_size := 1.0         # 粒子半径 / 发射球半径倍率
var _fx_spread := 1.0       # 扩散角倍率


func _ready() -> void:
	_pivot = Node3D.new()
	_pivot.name = "Pivot"
	add_child(_pivot)
	# Glow / FX 刻意**不在这里建**。
	#
	# 实测教训：pivot 的局部 Y 在世界空间里是水平的（挂点 handslot_r 的局部轴就是斜的），
	# 所以旧代码里 _glow.position = (0, 2.0, 0)、粒子放在 (0, 2.0, 0) 实际是把光晕和
	# 粒子甩到角色**旁边 2 米**的空中，而不是杖头上（截图里火杖的粒子飘在脚边就是这个原因）。
	# 正确的做法是把它们挂在 _model 下面 —— 模型局部 +Y 才是杖身长度方向。
	# 见 _place_head()。


## 装上某根法杖（id 为空则清空）
func set_staff(id: String, elem: int) -> void:
	staff_id = id
	element = elem
	# 必须**先摘出树再释放**：queue_free() 要到帧末才真正删除，期间旧节点仍叫
	# "Model"，新节点会被 Godot 自动改名成 @Model@2，于是 get_node("Pivot/Model")
	# 找不到 —— 实测 6 根里有 3 根因此"模型缺失"。remove_child 立刻断开父子关系。
	if _model != null:
		_pivot.remove_child(_model)
		_model.queue_free()
		_model = null
	# 光晕/粒子是旧模型的子节点，会跟着一起被删。这里立刻断开引用，
	# 免得 _clear_fx() 去碰"已进删除队列"的节点。
	_fx_root = null
	_glow = null
	_fx = null
	if id == "":
		if _glow != null:
			_glow.light_energy = 0.0
		return
	var d: Dictionary = _sys().call("get_def", id)
	var path := str(d.get("model", ""))
	if path == "" or not ResourceLoader.exists(path):
		push_warning("HeldStaff: 模型不存在 %s" % path)
		return
	_spin = float(d.get("idle_spin", 0.25))
	_hover = float(d.get("hover", 0.03))
	_fx_variant = 0
	_fx_amount = 1.0
	_fx_speed = 1.0
	_fx_size = 1.0
	_fx_spread = 1.0
	# 用 id 的稳定散列派生效果参数：146 根杖里同元素的几十根，粒子数量 / 速度 /
	# 大小 / 扩散角各不相同，近距离同时看两根也认得出不是同一根。
	var h := _stable_hash(id)
	_fx_variant = h % 3
	_fx_amount = 0.85 + 0.12 * float((h / 3) % 4)
	_fx_speed = 0.88 + 0.10 * float((h / 7) % 4)
	_fx_size = 0.85 + 0.15 * float((h / 11) % 4)
	_fx_spread = 0.85 + 0.20 * float((h / 13) % 3)
	# extra 里显式写了的以它为准（手调个别杖时用）
	if d.has("fx_variant"):
		_fx_variant = absi(int(d["fx_variant"])) % 3
	if d.has("fx_amount"):
		_fx_amount = maxf(0.1, float(d["fx_amount"]))
	if d.has("fx_speed"):
		_fx_speed = maxf(0.1, float(d["fx_speed"]))
	if d.has("fx_size"):
		_fx_size = maxf(0.1, float(d["fx_size"]))
	if d.has("fx_spread"):
		_fx_spread = maxf(0.1, float(d["fx_spread"]))
	# 角色 Visual 被整体缩到约 0.368（见 player.CHARACTER_SCALE / KayKit 比例），
	# 挂在它下面的法杖会跟着缩小。先记下父级世界缩放，真正的尺寸在 _place_head()
	# 里按"目标世界长度"反算（要等入树量完模型原始长度才知道该缩多少）。
	_parent_scale = 1.0
	var pn := get_parent()
	if pn is Node3D:
		_parent_scale = maxf(0.0001, (pn as Node3D).global_transform.basis.get_scale().x)
	var scene: PackedScene = load(path)
	_model = scene.instantiate() as Node3D
	_model.name = "Model"
	_model.scale = Vector3.ONE
	# 朝向：把法杖立起来。这个值不是推出来的，是**旁举扫描求解**出来的 ——
	# handslot_r 的局部轴是 X=世界下、Y/Z 水平，靠推理试了 -12 / -90 / (90,0,-90)
	# 都不对（一会儿横一会儿倒）。扫描 48 组旋转、每组等 3 帧避开自转相位，
	# 按"高矮比 + 主体在手上方"打分，(180,0,0) 以 2.25m 高 × 0.38m 宽胜出。
	_model.rotation_degrees = Vector3(135.0, 0.0, 90.0)
	_model.position = Vector3.ZERO
	_pivot.add_child(_model)
	# 尺寸与握点只能**入树后实测**：挂点 handslot_r 的局部轴与世界轴不是简单欧拉
	# 关系（对齐旋转是扫描试出来的），任何解析推算都是错的。见 _place_head()。
	_need_measure = true
	_measure_tries = 0


## 实测杖头，并把光晕 / 粒子挂到**杖头坐标系**上。
##
## 坐标系的选取是关键：_fx_root 挂在 _model 下面，于是它的局部 +Y 就是杖身长度方向，
## 单位与模型局部一致（外层 net scale = 1，所以 1 单位 = 1 世界米）。
## 之前把光晕/粒子挂在 pivot 下是错的 —— pivot 的局部 Y 在世界里是水平的。
func _place_head() -> void:
	if _model == null:
		_need_measure = false
		return
	# 关键：Godot 的 global_transform 是**延迟刷新**的。装杖那一帧直接读，
	# 拿到的是入树前的缓存值，inv 就是错的，量出来的包围盒整个是脏的
	# —— 冰杖报出 P=(-2.414, 0, -0.103)、长度 2.08（真值 1.61、居中），
	# 于是被当成"长度 0"跳过，尺寸/握点/特效全都没生效。
	# 两手准备：(a) 沿父链 force_update_transform 强制刷新；
	#          (b) 包围盒完全用**局部** transform 累乘求，绕开 global 缓存。
	var n: Node = _model
	while n is Node3D:
		(n as Node3D).force_update_transform()
		n = n.get_parent()
	var boxes := _mesh_aabbs(_model)
	var bb := _merge_aabbs(boxes)
	var m_up := (_model.global_transform.basis * Vector3.UP).normalized()
	# ---- 量出来的数据必须先"验货"，不合法就下一帧再量 ----
	# 判据：找得到网格、杖身竖直、长度合理。注意**不能**要求几何体居中 ——
	# GLB 里本来就带着逐根不同的排布偏移（见 _shaft_axis）。
	if boxes.is_empty() or bb.size.y < 0.3 or absf(m_up.dot(Vector3.UP)) < 0.85:
		_measure_tries += 1
		if _measure_tries > 120:
			push_warning("HeldStaff: %s 杖头测量失败，保持原尺寸" % staff_id)
			_need_measure = false
		return
	_need_measure = false
	# 模型局部 +Y 是杖身长度方向，朝上还是朝下由 m_up 定
	_up = 1.0 if m_up.dot(Vector3.UP) >= 0.0 else -1.0
	# 杖身原始长度（模型局部单位）
	var raw_len := (bb.position.y + bb.size.y) if _up > 0.0 else -bb.position.y
	if raw_len < 0.3:
		return
	# ---- 尺寸：统一压到目标世界长度 ----
	# 模型局部单位 → 世界米 = _model.scale × _parent_scale，所以
	# _model.scale = 目标长度 / (原始长度 × 父级缩放)
	var d: Dictionary = _sys().call("get_def", staff_id)
	var want := float(d.get("world_len", STAFF_WORLD_LEN))
	_model.scale = Vector3.ONE * (want / (raw_len * _parent_scale))
	_head_top = want
	# ---- 握点：把杖身上 32% 处（握把）对齐到挂点 ----
	# 握点在**模型局部**坐标里是 (轴心.x, grip_y, 轴心.y)，换算到世界要乘模型自己的
	# basis（里面含缩放）。之前直接用 世界握距 × 杖轴方向 去偏移是错的 ——
	# 局部单位与世界米不再是 1:1（缩放后 1 局部单位 = want/raw_len 米）。
	var axis := _shaft_axis(boxes)
	var grip_y: float
	if _up > 0.0:
		grip_y = bb.position.y + GRIP_FRAC * bb.size.y
	else:
		grip_y = bb.position.y + (1.0 - GRIP_FRAC) * bb.size.y
	var grip_local := Vector3(axis.x, grip_y, axis.y)
	var grip_world := _model.global_transform.basis * grip_local
	_model.global_position = global_position - grip_world
	# 重建杖头坐标系
	if _fx_root != null:
		_model.remove_child(_fx_root)
		_fx_root.queue_free()
		_fx_root = null
	_fx_root = Node3D.new()
	_fx_root.name = "FXRoot"
	# _fx_root 是 _model 的子节点，长度单位仍是模型局部单位（因此用 raw_len）
	_fx_root.position = Vector3(0.0, _up * raw_len, 0.0)
	_model.add_child(_fx_root)
	_glow = OmniLight3D.new()
	_glow.name = "Glow"
	_glow.omni_range = 2.0
	_glow.light_energy = 0.0
	_glow.shadow_enabled = false
	_glow.light_color = _elem_color(element)
	_glow.position = Vector3(0.0, -0.16 * _up, 0.0)
	_fx_root.add_child(_glow)
	_fx = Node3D.new()
	_fx.name = "FX"
	_fx_root.add_child(_fx)
	_build_fx(element, _up)


## 沿**局部** transform 把每个网格累乘到 node 下，返回每个网格在 node 局部空间的包围盒。
## 刻意不用 global_transform：它入树后要等一帧才刷新（见 _place_head 的说明）。
func _mesh_aabbs(node: Node3D) -> Array:
	var out: Array = []
	for c in node.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D()
		var n: Node = mi
		while n != null and n != node:
			if n is Node3D:
				xf = (n as Node3D).transform * xf
			n = n.get_parent()
		out.append(xf * mi.mesh.get_aabb())
	return out


func _merge_aabbs(list: Array) -> AABB:
	var first := true
	var bb := AABB()
	for g in list:
		bb = (g as AABB) if first else bb.merge(g as AABB)
		first = false
	return bb


## 杖身轴心（模型局部空间的 xz）。
##
## 为什么不能用整体包围盒中心：Blender 里为了出一张预览图，每根杖导出前都做过
## 横向排布偏移（ob.location.x += dx），这个偏移被烘进了 GLB —— 冰杖的几何体
## 整体偏在 x≈-2.4 处。偏移方向/大小逐根不同，所以"模型原点在杖底中心"根本不成立，
## 直接按原点摆，每根杖都会离手 0.4~2.3 米。
## 而整体中心也不可靠（弯月、锚爪会把中心拽偏），所以取**最下面那一段网格**的
## 水平中心 —— 那一定是杖身本体，正是应该握在手里的那根轴。
func _shaft_axis(list: Array) -> Vector2:
	var lo := 1e9
	for g in list:
		lo = minf(lo, (g as AABB).position.y)
	var acc := Vector2.ZERO
	var cnt := 0
	for g in list:
		var a := g as AABB
		if absf(a.position.y - lo) <= 0.002:
			acc += Vector2(a.get_center().x, a.get_center().z)
			cnt += 1
	return acc / float(maxi(1, cnt))


## 握点局部空间里"世界向上"的方向（pivot 的局部 Y 不是它）
func _local_up() -> Vector3:
	var b := global_transform.basis
	var v := b.inverse() * Vector3.UP
	return v.normalized() if v.length() > 0.0001 else Vector3.UP


func _clear_fx() -> void:
	if _fx == null:
		return
	for c in _fx.get_children():
		_fx.remove_child(c)
		c.queue_free()


## 按元素 + 造型档位建一套粒子。位置都以**杖头**为原点，u = +1/-1 表示杖身朝上/朝下。
##
## 每个元素有 3 种造型档位（0/1/2），具体用哪档由 staff_id 散列决定，
## 再叠上数量/速度/大小/扩散的连续抖动 —— 于是"火"不再是同一簇火，
## 而是细火柱 / 火柱加火星环 / 喷泉式三种，配合不同的疏密强弱。
func _build_fx(elem: int, u: float) -> void:
	var col := _elem_color(elem)
	var up := Vector3(0.0, u, 0.0)
	var down := Vector3(0.0, -u, 0.0)
	var v := _fx_variant
	match elem:
		EL_FIRE:
			if v == 0:
				_add_particles("Fire", col, Color(1.0, 0.85, 0.3, 0.0),
						Vector3(0, -0.06 * u, 0), up, 18.0, 30, 0.55, 0.55)
				_add_particles("Ember", col, Color(1.0, 0.5, 0.1, 0.0),
						Vector3(0, -0.22 * u, 0), up, 10.0, 18, 1.1, 0.9)
			elif v == 1:
				_add_particles("Fire", col, Color(1.0, 0.80, 0.25, 0.0),
						Vector3(0, -0.05 * u, 0), up, 15.0, 34, 0.6, 0.8)
				_add_orbit("EmberRing", Color(1.0, 0.62, 0.18), 0.02 * u, 0.26, 40)
			else:
				_add_particles("Fountain", col, Color(1.0, 0.90, 0.40, 0.0),
						Vector3(0, -0.02 * u, 0), up, 22.0, 26, 0.8, 1.5)
				_add_particles("Spark", Color(1.0, 0.95, 0.60),
						Color(1.0, 0.60, 0.20, 0.0),
						Vector3(0, 0.02 * u, 0), up, 26.0, 14, 0.45, 1.8)
		EL_ICE:
			if v == 0:
				_add_particles("Frost", col, Color(0.7, 0.9, 1.0, 0.0),
						Vector3(0, 0.16 * u, 0), down, 6.0, 26, 0.7, 1.2)
				_add_particles("Sparkle", col, Color(1, 1, 1, 0.0),
						Vector3(0, 0, 0), Vector3(0, 0.2 * u, 0), 3.0, 14, 1.0, 1.6)
			elif v == 1:
				_add_particles("Frost", col, Color(0.72, 0.92, 1.0, 0.0),
						Vector3(0, 0.18 * u, 0), down, 5.0, 22, 0.9, 1.0)
				_add_orbit("IceRing", Color(0.62, 0.86, 1.0), 0.04 * u, 0.30, 84)
			else:
				_add_particles("Shards", col, Color(0.80, 0.95, 1.0, 0.0),
						Vector3(0, -0.04 * u, 0), up, 9.0, 18, 0.9, 1.1)
				_add_particles("Motes", Color(0.90, 0.97, 1.0),
						Color(0.70, 0.90, 1.0, 0.0),
						Vector3(0, 0.02 * u, 0), up, 4.0, 12, 1.6, 2.0)
		EL_ARCANE:
			if v == 0:
				_add_orbit("Arcane", col, -0.06 * u, 0.30, 48)
			elif v == 1:
				_add_orbit("ArcaneA", col, -0.14 * u, 0.26, 40)
				_add_orbit("ArcaneB", Color(col.r, col.g * 0.8, 1.0), 0.06 * u, 0.34, 64)
			else:
				_add_orbit("Arcane", col, -0.06 * u, 0.30, 44)
				_add_particles("Rune", Color(0.86, 0.74, 1.0),
						Color(col.r, col.g, col.b, 0.0),
						Vector3(0, 0, 0), up, 5.0, 14, 1.5, 1.8)
		EL_NATURE:
			if v == 0:
				_add_particles("Leaf", col, Color(0.6, 0.9, 0.4, 0.0),
						Vector3(0, -0.10 * u, 0), up, 8.0, 18, 1.2, 1.6)
			elif v == 1:
				_add_orbit("LeafRing", col, 0.0, 0.28, 72)
				_add_particles("Leaf", Color(0.72, 0.92, 0.48),
						Color(0.6, 0.9, 0.4, 0.0),
						Vector3(0, -0.06 * u, 0), up, 5.0, 10, 1.4, 2.2)
			else:
				_add_particles("Pollen", Color(0.92, 0.95, 0.55),
						Color(0.6, 0.9, 0.4, 0.0),
						Vector3(0, -0.06 * u, 0), up, 7.0, 16, 1.3, 1.4)
				_add_particles("Fall", col, Color(0.5, 0.8, 0.35, 0.0),
						Vector3(0, 0.14 * u, 0), down, 5.0, 10, 1.6, 1.2)
		EL_HOLY:
			if v == 0:
				_add_particles("Light", col, Color(1.0, 0.98, 0.8, 0.0),
						Vector3(0, -0.08 * u, 0), up, 12.0, 30, 1.0, 1.3)
			elif v == 1:
				_add_particles("Light", col, Color(1.0, 0.97, 0.76, 0.0),
						Vector3(0, -0.06 * u, 0), up, 10.0, 24, 1.1, 1.1)
				_add_orbit("Halo", Color(1.0, 0.95, 0.70), 0.06 * u, 0.36, 56)
			else:
				_add_particles("Bless", Color(1.0, 0.96, 0.72),
						Color(1.0, 0.90, 0.55, 0.0),
						Vector3(0, 0.14 * u, 0), down, 8.0, 22, 1.2, 1.5)
				_add_particles("Motes", Color(1.0, 1.0, 0.90),
						Color(0.95, 0.92, 0.70, 0.0),
						Vector3(0, -0.02 * u, 0), up, 4.0, 12, 1.8, 1.6)
		EL_EARTH:
			if v == 0:
				_add_particles("Dust", col, Color(0.6, 0.5, 0.35, 0.0),
						Vector3(0, -0.14 * u, 0), up, 7.0, 16, 1.3, 1.5)
			elif v == 1:
				_add_particles("Grit", col, Color(0.50, 0.42, 0.30, 0.0),
						Vector3(0, 0.12 * u, 0), down, 9.0, 18, 1.1, 1.1)
			else:
				_add_orbit("Pebble", Color(0.66, 0.52, 0.32), -0.05 * u, 0.26, 60)
				_add_particles("Dust", col, Color(0.6, 0.5, 0.35, 0.0),
						Vector3(0, -0.10 * u, 0), up, 5.0, 10, 1.2, 1.8)
		EL_STORM:
			if v == 0:
				_add_orbit("Storm", col, -0.02 * u, 0.45, 60)
			elif v == 1:
				_add_orbit("StormA", col, -0.10 * u, 0.38, 44)
				_add_orbit("StormB", Color(0.78, 0.90, 1.0), 0.10 * u, 0.52, 76)
				_add_particles("Spark", Color(0.90, 0.96, 1.0),
						Color(col.r, col.g, col.b, 0.0),
						Vector3(0, 0.02 * u, 0), up, 12.0, 12, 0.4, 2.0)
			else:
				_add_particles("Sparks", col, Color(0.85, 0.93, 1.0, 0.0),
						Vector3(0, -0.02 * u, 0), up, 20.0, 20, 0.5, 1.6)
				_add_particles("Arc", Color(0.85, 0.92, 1.0),
						Color(col.r, col.g, col.b, 0.0),
						Vector3(0, 0.10 * u, 0), down, 8.0, 10, 0.9, 1.3)
		_:
			pass


func _add_particles(nm: String, a: Color, b: Color, pos: Vector3,
		dir: Vector3, vel: float, amount: int, life: float, spread: float) -> void:
	var p := GPUParticles3D.new()
	p.name = nm
	p.amount = maxi(4, int(round(float(amount) * _fx_amount)))
	p.lifetime = life
	p.position = pos
	p.visibility_aabb = AABB(Vector3(-1.5, -1.5, -1.5), Vector3(3, 3, 3))
	# local_coords = true：粒子跟着法杖走。设成 false 会变成世界空间发射，
	# 粒子会拖在角色身后一路洒出去（截图里看得很明显）。
	p.local_coords = true
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.09 * _fx_size
	pm.direction = dir
	pm.spread = clampf(spread * 45.0 * _fx_spread, 0.0, 180.0)
	pm.initial_velocity_min = vel * 0.5 * _fx_speed
	pm.initial_velocity_max = vel * _fx_speed
	pm.gravity = Vector3(0.0, 0.4 if dir.y > 0.0 else -0.4, 0.0)
	pm.scale_min = 0.5
	pm.scale_max = 1.0
	var grad := Gradient.new()
	grad.set_color(0, a)
	grad.set_color(1, b)
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	p.process_material = pm
	var mesh := SphereMesh.new()
	mesh.radius = 0.022 * _fx_size
	mesh.height = 0.044 * _fx_size
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = a
	mat.emission_enabled = true
	mat.emission = a
	mat.emission_energy_multiplier = 2.2
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.material = mat
	p.draw_pass_1 = mesh
	_fx.add_child(p)


## 环绕型效果：几个小球绕杖头转
func _add_orbit(nm: String, col: Color, y: float, radius: float, period_frames: int) -> void:
	var p := GPUParticles3D.new()
	p.name = nm
	p.amount = maxi(4, int(round(10.0 * _fx_amount)))
	p.lifetime = 2.4
	p.position = Vector3(0.0, y, 0.0)
	p.visibility_aabb = AABB(Vector3(-1.5, -1.5, -1.5), Vector3(3, 3, 3))
	# local_coords = true：粒子跟着法杖走。设成 false 会变成世界空间发射，
	# 粒子会拖在角色身后一路洒出去（截图里看得很明显）。
	p.local_coords = true
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.02 * _fx_size
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 0.0
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0
	pm.gravity = Vector3.ZERO
	# period_frames 之前是个没被用上的形参；现在真的用它决定转速：帧数越少转得越快。
	var spin := 24.0 / float(clampi(period_frames, 12, 120))
	pm.orbit_velocity_min = spin * 0.80 * _fx_speed
	pm.orbit_velocity_max = spin * 1.25 * _fx_speed
	var rr := radius * _fx_size
	pm.radial_accel_min = rr * 3.0
	pm.radial_accel_max = rr * 3.4
	pm.scale_min = 0.6
	pm.scale_max = 1.1
	var grad := Gradient.new()
	grad.set_color(0, col)
	grad.set_color(1, Color(col.r, col.g, col.b, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = grad
	pm.color_ramp = gt
	p.process_material = pm
	var mesh := SphereMesh.new()
	mesh.radius = 0.032 * _fx_size
	mesh.height = 0.064 * _fx_size
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	p.draw_pass_1 = mesh
	_fx.add_child(p)


## 运行期取法杖系统。
## 不直接写 autoload 标识符 StaffSystem：那样本脚本在 autoload 未注册的编译上下文里
## 会编译失败（--script 探针、依赖链编译），并连锁把 player.gd 拖死。
func _sys() -> Node:
	return get_node_or_null("/root/StaffSystem")


## 字符串的稳定散列（FNV-1a，取 31 位保证为正）。
## 用它从 staff_id 派生效果参数：同一根杖每次进游戏效果一致，
## 不同杖之间又各不相同 —— 比随机数好，随机会让同一根杖每次都不一样。
func _stable_hash(s: String) -> int:
	var h := 2166136261
	for i in s.length():
		h = (h ^ s.unicode_at(i)) * 16777619
		h = h & 0x7FFFFFFF
	return h


func _elem_color(e: int) -> Color:
	var sys := _sys()
	if sys == null:
		return Color.WHITE
	return sys.call("element_color", e)


func _process(delta: float) -> void:
	if staff_id == "" or _pivot == null:
		return
	# 装上新杖后的第一帧：实测杖头，把光晕和粒子挂到真正的杖头上
	if _need_measure and _model != null and _model.is_inside_tree():
		_place_head()
	# 悬浮：沿**世界竖直**方向，不是 pivot 的局部 Y（后者在世界里是水平的，
	# 照它摆等于让法杖左右平移而不是上下浮动）
	_base_y += delta * HOVER_SPEED
	_pivot.position = _local_up() * (sin(_base_y) * _hover)
	# pivot 与 model 的旋转都不许在每帧里改。
	#
	# 实测教训：对齐旋转本来能让法杖竖直，但只要每帧再叠加一个模型局部轴的摆动，
	# (高, 宽) 就从 (2.25, 0.38) 变成 (0.30, 1.9) —— 已经竖直的杖被摆动压平了
	# （对齐后模型局部轴与世界竖直轴关系特殊，在它上面转等于把杖推倒）。
	# 所以只保留悬浮，动感靠光晕脉动体现。
	_pivot.rotation = Vector3.ZERO
	# 光晕脉动
	if _glow != null:
		_pulse += delta * PULSE_SPEED
		_glow.light_energy = (1.15 + 0.45 * sin(_pulse)) * 0.9


## 施法瞬间：光晕爆一下（供技能/动作调用）
func flash(strength: float = 1.6) -> void:
	if _glow == null:
		return
	_glow.light_energy = strength * 4.0

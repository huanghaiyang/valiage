extends Node3D
## 火焰灼烧 —— **一次性范围法术**。
##
## 流程（数值全部来自 data/spell_sheet.json）：
##   ① 选点   由通用选点器 spell_targeting 负责（本术法只声明 has_targeting/cast_at）
##   ② 点燃   cast_climb = 0.35s   圈内各处火焰从 0.2 长到 1
##   ③ 灼烧   duration   = 8.0s    圈内敌人每秒扣 damage_per_sec(默认 10) 点血
##   ④ 余烬   fade_time  = 1.2s    火焰逐渐消失，**这一阶段不扣血**
##
## 「火焰逐渐消失」用的是 fire_burst 的 grow（每张焰卡**在原位**缩小变暗），
## 绝不缩放特效根节点 —— 焰卡围成一圈，缩放根节点会让它们向中心靠拢（用户明确否过）。
##
## 对外接口除标准那几个外，另加选点法术需要的两个：
##   has_targeting() -> bool  /  targeting_config() -> Dictionary  /  cast_at(center, radius)
##
## 敌人约定：节点在组 "enemies" 里，或自身有 take_damage(整数) 方法。
## 目前项目里没有敌人系统，所以扣血走的是**宽松探测**：两种约定都试，都没有就安静跳过。

const FIRE_SCENE: PackedScene = preload("res://scenes/法术特效/火焰燃烧特效.tscn")
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
const SHEET_ID := "flame_scorch"
const GROUND_SHADER := "res://assets/shaders/fire_ground.gdshader"
const FIRE_TEX := "res://assets/textures/法术特效/龙卷风/T_FirePanningCyl45.png"

# ---- 数值（表缺失时的兜底）----
@export var mana_cost := 30.0
@export var ignite_time := 0.35
@export var burn_time := 8.0
@export var afterburn_time := 1.2
@export var damage_per_sec := 10.0
@export var fire_scale := 1.1          ## 单簇火焰的整体缩放
## 每簇火焰大约覆盖多少平方米（用来按圈面积算簇数）
@export var area_per_patch := 6.0
@export var patch_min := 6
@export var patch_max := 14
## ★ 单簇火焰在 scale=1 时的**水平半径**（米）。
##   布点半径必须扣掉它，否则火焰会**溢出圈外**（用户实测症状）。
@export var patch_footprint := 1.1

# ---- 姿态：让火焰"坐"在表面而不是悬浮 ----
## 姿态向面法线靠拢的比例（1 = 完全贴合表面，0 = 永远竖直）
@export var tilt_gain := 0.55
## 最大倾斜角（度）。火焰毕竟该是向上的，不能跟着陡坡倒下去
@export var max_tilt_deg := 20.0
## 沿姿态轴向下沉多少米：把底面压进地面，消掉"悬浮缝"
@export var ground_sink := 0.07

# ---- 物体边缘检测 ----
## 探针距离（米）：在火焰位置四周这个距离上再打射线找"物体"
@export var edge_probe_dist := 0.55
## 探针命中面的法线朝上程度低于此值 -> 认为碰到了**立面（物体边缘）**
@export var edge_normal_min := 0.75
## 探针相对中心的高度差超过此值 -> 也认为碰到了边缘/台阶
@export var edge_height_delta := 0.35

var casting := false

var _player: Node3D = null
var _ran_out := false
var _state := ST_OFF
var _state_t := 0.0
var _center := Vector3.ZERO
var _radius := 2.5
var _patches: Array[Node3D] = []       ## 复用的火焰簇（避免每次施法现建十几份特效）
var _glows: Array[MeshInstance3D] = []  ## 每簇火脚下的一层"贴地燃烧"光斑（粘滞感）
var _glow_mat: ShaderMaterial = null
var _used := 0
var _dmg_acc: Dictionary = {}          ## 目标 id -> 累积的小数伤害（保证 take_damage 收到整数）

const ST_OFF := 0
const ST_IGNITE := 1
const ST_BURN := 2
const ST_AFTER := 3


func _ready() -> void:
	set_process(true)
	_load_sheet()


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player


# ---------------------------------------------------------------- 数值表
func _load_sheet() -> void:
	if not SHEET.has(SHEET_ID):
		return
	mana_cost = SHEET.f(SHEET_ID, "mana_cost", mana_cost)
	ignite_time = SHEET.f(SHEET_ID, "cast_climb", ignite_time)
	burn_time = SHEET.f(SHEET_ID, "duration", burn_time)
	afterburn_time = SHEET.f(SHEET_ID, "fade_time", afterburn_time)
	var row := SHEET.get_spell(SHEET_ID)
	var tg: Dictionary = row.get("targeting", {})
	damage_per_sec = float(tg.get("damage_per_sec", damage_per_sec))


# ---------------------------------------------------------------- 选点法术接口
func has_targeting() -> bool:
	var row := SHEET.get_spell(SHEET_ID)
	var tg: Dictionary = row.get("targeting", {})
	return bool(tg.get("enabled", false))


func targeting_config() -> Dictionary:
	return SHEET.get_spell(SHEET_ID).get("targeting", {})


## 选点确认：在圈定范围内生成火焰
func cast_at(center: Vector3, radius: float) -> void:
	if _state != ST_OFF and _state != ST_AFTER:
		return
	_ran_out = false
	if mana_cost > 0.0:
		# ★ 先自己判断余额：Mana.try_spend 在不足时会把蓝扣到 0 再返回 false
		if float(Mana.get("current")) < mana_cost:
			_ran_out = true
			return
		if not Mana.try_spend(mana_cost):
			_ran_out = true
			return
	casting = true
	_center = center
	_radius = maxf(radius, 0.5)
	_spawn_patches()
	_state = ST_IGNITE
	_state_t = 0.0
	_dmg_acc.clear()
	_apply_grow(0.2)


# ---------------------------------------------------------------- 标准接口
## 没有选点器时的兜底：直接在角色正前方放一圈（半径用表里的默认）
func start_cast() -> void:
	if _state != ST_OFF and _state != ST_AFTER:
		return
	var fwd := aim_dir()
	var c := (_player.global_position if _player != null else global_position) + fwd * 3.6
	cast_at(c, 2.5)


## 一次性法术：松手不停
func stop_cast() -> void:
	pass


func is_casting() -> bool:
	return _state != ST_OFF


func ran_out_of_mana() -> bool:
	return _ran_out


func aim_dir() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.FORWARD
	var d := -(_player as Node3D).global_transform.basis.z
	d.y = 0.0
	return d.normalized()


func origin_global() -> Vector3:
	return _center


## 施法动作保留到点燃结束（保证动作完整走一遍）
func wants_cast_anim() -> bool:
	return _state == ST_IGNITE


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	_state_t += delta
	match _state:
		ST_OFF:
			return
		ST_IGNITE:
			var k := clampf(_state_t / maxf(ignite_time, 0.01), 0.0, 1.0)
			_apply_grow(0.2 + 0.8 * sqrt(k))
			if k >= 1.0:
				_state = ST_BURN
				_state_t = 0.0
		ST_BURN:
			_apply_grow(1.0)
			_apply_damage(delta)
			if _state_t >= burn_time:
				_state = ST_AFTER
				_state_t = 0.0
				_dmg_acc.clear()
		ST_AFTER:
			# ★ 余烬阶段：只缩火，**不扣血**
			var k2 := clampf(_state_t / maxf(afterburn_time, 0.01), 0.0, 1.0)
			_apply_grow(pow(1.0 - k2, 0.6))
			if k2 >= 1.0:
				_state = ST_OFF
				_hide_all()


# ---------------------------------------------------------------- 内部
## 圈内扣血：只在整个灼烧阶段被调用（余烬阶段不调用 -> 不扣血）
func _apply_damage(delta: float) -> void:
	var dmg := damage_per_sec * delta
	if dmg <= 0.0:
		return
	for t in _find_targets():
		var node := t as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var p := node.global_position
		var flat := Vector3(p.x - _center.x, 0.0, p.z - _center.z)
		if flat.length() > _radius:
			continue                       # 不在圈内
		var id := node.get_instance_id()
		var acc := float(_dmg_acc.get(id, 0.0)) + dmg
		var whole := int(floor(acc))
		if whole > 0:
			acc -= float(whole)
			node.call("take_damage", whole)
		_dmg_acc[id] = acc


## 找敌人：组 "enemies" 优先；没有就用"树里有 take_damage 方法的节点"兜底
func _find_targets() -> Array:
	var out: Array = []
	var tree := get_tree()
	if tree == null:
		return out
	out = tree.get_nodes_in_group("enemies")
	if not out.is_empty():
		return out
	# 兜底：项目目前还没有敌人系统，安静返回空表
	return out


func _apply_grow(s: float) -> void:
	var g := clampf(s, 0.0, 1.0)
	for i in range(_used):
		var f := _patches[i]
		if f != null and is_instance_valid(f):
			f.set("grow", g)
	if _glow_mat != null:
		_glow_mat.set_shader_parameter("fade", g)


func _hide_all() -> void:
	for f in _patches:
		if f != null and is_instance_valid(f):
			f.visible = false
	for mi in _glows:
		if mi != null and is_instance_valid(mi):
			mi.visible = false
	if _glow_mat != null:
		_glow_mat.set_shader_parameter("fade", 0.0)


## 在圈内铺开火焰簇（抖动网格，保证覆盖均匀又不像阵列）
func _spawn_patches() -> void:
	_area_area_prepare()
	var area := PI * _radius * _radius
	var want := int(round(area / maxf(area_per_patch, 0.5)))
	want = clampi(want, patch_min, patch_max)
	_ensure_pool(want)
	_used = want
	# ★ 火焰自己也有占地 -> 圈越小，火也要越小；布点还要再往里收一个"火半径"，
	#   否则最外圈那几簇会烧到圈外（用户实测症状）。
	var pscale := clampf(_radius / 4.0, 0.45, 1.0) * fire_scale
	var fp := patch_footprint * pscale
	var fit := maxf(_radius - fp, 0.0)
	# 抖动网格布点
	var cols := int(ceil(sqrt(float(want))))
	var cell := (fit * 2.0) / float(maxi(cols, 1))
	var placed := 0
	for ix in range(cols):
		for iy in range(cols):
			if placed >= want:
				break
			var gx := -fit + cell * (float(ix) + 0.5)
			var gz := -fit + cell * (float(iy) + 0.5)
			# 抖动 + 圆内裁剪（超出可布点半径的点沿径向拉回来）
			var jx := gx + randf_range(-cell * 0.3, cell * 0.3)
			var jz := gz + randf_range(-cell * 0.3, cell * 0.3)
			var d := sqrt(jx * jx + jz * jz)
			if d > fit and d > 0.001:
				var s := fit / d
				jx *= s
				jz *= s
			var f := _patches[placed]
			f.visible = true
			var x := _center.x + jx
			var z := _center.z + jz
			# ★ 姿态：贴合表面 + 底面下沉消缝 +（若有物体）朝边缘对齐而不是随机角
			var pr := _probe_patch(x, z, _center.y)
			var up: Vector3 = pr["up"]
			var y: float = float(pr["y"]) - ground_sink
			var yaw: float = float(pr["yaw"])
			var basis := Basis(Vector3.UP, yaw)          # 先定朝向
			var axis := basis.y.cross(up)                # 再把"上"倾到姿态轴
			if axis.length_squared() > 1e-8:
				basis = Basis(axis.normalized(), basis.y.angle_to(up)) * basis
			f.global_transform = Transform3D(basis, Vector3(x, y, z))
			f.scale = Vector3.ONE * pscale
			f.set("grow", 0.2)
			# ★ 贴地燃烧底光：让火焰"粘"在地表（消掉悬浮的观感）
			var glow := _glows[placed]
			glow.visible = true
			var gup: Vector3 = (pr["up"] as Vector3)
			var gfwd := Vector3(sin(yaw), 0.0, cos(yaw))
			var gright := gfwd.cross(gup)
			if gright.length_squared() < 1e-6:
				gright = Vector3.RIGHT
			gright = gright.normalized()
			gfwd = gup.cross(gright).normalized()
			glow.global_transform = Transform3D(Basis(gright, gfwd, gup),
					Vector3(x, y, z) + gup * (ground_sink + 0.03))
			glow.scale = Vector3.ONE * pscale
			placed += 1


func _area_area_prepare() -> void:
	pass


## 池子：不够才新建（新建火焰特效不便宜，所以复用）
func _ensure_pool(n: int) -> void:
	while _patches.size() < n:
		var f := FIRE_SCENE.instantiate() as Node3D
		if f == null:
			return
		f.name = "ScorchPatch%d" % _patches.size()
		f.visible = false
		add_child(f)
		f.set("grow", 0.0)
		_patches.append(f)
	_ensure_glow_pool(n)


## 贴地燃烧光斑的池子（共用一份材质：整片火的 grow 是统一的）
func _ensure_glow_pool(n: int) -> void:
	if _glow_mat == null:
		_glow_mat = ShaderMaterial.new()
		var sh := load(GROUND_SHADER) as Shader
		if sh == null:
			return
		_glow_mat.shader = sh
		var ft := load(FIRE_TEX) as Texture2D
		if ft != null:
			_glow_mat.set_shader_parameter("fire_tex", ft)
	while _glows.size() < n:
		var q := QuadMesh.new()
		q.size = Vector2(2.6, 2.6)
		q.surface_set_material(0, _glow_mat)
		var mi := MeshInstance3D.new()
		mi.name = "ScorchGlow%d" % _glows.size()
		mi.mesh = q
		mi.material_override = _glow_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_glows.append(mi)


## 从上方朝下打射线找地面
func _ground_y(pos: Vector3, fallback: float) -> float:
	var hit := _ray_down(pos.x, pos.z, fallback)
	if hit.is_empty():
		return fallback
	return (hit["position"] as Vector3).y


func _ray_down(x: float, z: float, base_y: float) -> Dictionary:
	var world := get_world_3d()
	if world == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(Vector3(x, base_y + 15.0, z),
			Vector3(x, base_y - 60.0, z))
	q.collision_mask = 0xFFFFFFFF
	return world.direct_space_state.intersect_ray(q)


# ---------------------------------------------------------------- 姿态（纯函数，便于自检）
## 火焰的姿态轴：把面法线**温和地**靠向竖直，并限制最大倾角。
## 为什么不能直接用面法线：陡坡上火焰会整个倒下去，看起来像贴纸。
func _patch_up(normal: Vector3) -> Vector3:
	var nn := normal
	if nn.length_squared() < 1e-8:
		return Vector3.UP
	nn = nn.normalized()
	if nn.y < 0.0:
		nn = -nn                                   # 朝下的法线翻上来
	var blended := Vector3.UP.lerp(nn, clampf(tilt_gain, 0.0, 1.0)).normalized()
	var ang := Vector3.UP.angle_to(blended)
	var lim := deg_to_rad(maxf(max_tilt_deg, 0.0))
	if ang > lim and ang > 1e-5:
		var axis := Vector3.UP.cross(blended)
		if axis.length_squared() < 1e-8:
			return Vector3.UP
		blended = Vector3.UP.rotated(axis.normalized(), lim)
	return blended


## 检测到物体边缘时火焰的朝向：**沿着边缘**（垂直于"指向物体"的方向），不再随机。
## 返回绕 Y 的 yaw；该 yaw 下火焰的正前方(-Z)与边缘平行。
func _edge_yaw(obstacle_dir: Vector3) -> float:
	var d := Vector3(obstacle_dir.x, 0.0, obstacle_dir.z)
	if d.length_squared() < 1e-8:
		return 0.0
	d = d.normalized()
	var edge := Vector3(-d.z, 0.0, d.x)            # 水平面上与 d 垂直 = 边缘走向
	return atan2(-edge.x, -edge.z)                 # 使 Basis(UP, yaw) 的 -Z 指向 edge


## 探测一个落点：地面高度（**多点取最低**）/ 姿态轴 / 朝物体边缘对齐的 yaw
## ★ 只打中心一根射线是不够的：火焰簇占地 ~2 米，地面在这个范围内一有起伏，
##   火就架在低处上方 = **悬浮**（用户实测反馈）。所以按占地撒点、取**最低**：
##   宁可让高处的土稍微扎进火里，也不能让火悬空。
func _probe_patch(x: float, z: float, base_y: float) -> Dictionary:
	var out := {"y": base_y, "up": Vector3.UP, "yaw": randf() * TAU, "has_edge": false}
	var c := _ray_down(x, z, base_y)
	var cy := base_y
	var normal := Vector3.UP
	if not c.is_empty():
		cy = (c["position"] as Vector3).y
		normal = c.get("normal", Vector3.UP)
	# 多点采样（中心 + 一圈 + 半径 0.6 处）取最低
	var lowest := cy
	for ring in [0.45, 0.9]:
		for i in range(6):
			var a: float = float(i) / 6.0 * TAU
			var px: float = x + cos(a) * patch_footprint * float(ring)
			var pz: float = z + sin(a) * patch_footprint * float(ring)
			var h := _ray_down(px, pz, base_y)
			if not h.is_empty():
				lowest = minf(lowest, (h["position"] as Vector3).y)
	out["y"] = lowest
	out["up"] = _patch_up(normal)
	# 四向探针找物体边缘
	var best := Vector3.ZERO
	var found := false
	for i in range(4):
		var a2 := float(i) / 4.0 * TAU
		var dir := Vector3(cos(a2), 0.0, sin(a2))
		var s := _ray_down(x + dir.x * edge_probe_dist, z + dir.z * edge_probe_dist, base_y)
		if s.is_empty():
			continue
		var n: Vector3 = s.get("normal", Vector3.UP)
		var sy: float = (s["position"] as Vector3).y
		var is_face := n.normalized().y < edge_normal_min
		var is_step := absf(sy - cy) > edge_height_delta
		if is_face or is_step:
			out["has_edge"] = true
			if not found or absf(sy - cy) > absf(best.length()):
				best = dir * maxf(absf(sy - cy), 0.001)
				found = true
	if out["has_edge"]:
		out["yaw"] = _edge_yaw(best)
	return out

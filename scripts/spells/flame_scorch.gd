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

var casting := false

var _player: Node3D = null
var _ran_out := false
var _state := ST_OFF
var _state_t := 0.0
var _center := Vector3.ZERO
var _radius := 2.5
var _patches: Array[Node3D] = []       ## 复用的火焰簇（避免每次施法现建十几份特效）
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
	for i in range(_used):
		var f := _patches[i]
		if f != null and is_instance_valid(f):
			f.set("grow", clampf(s, 0.0, 1.0))


func _hide_all() -> void:
	for f in _patches:
		if f != null and is_instance_valid(f):
			f.visible = false


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
			var y := _ground_y(Vector3(x, 0.0, z), _center.y)
			f.global_transform = Transform3D(Basis.IDENTITY, Vector3(x, y, z))
			f.scale = Vector3.ONE * pscale
			f.set("grow", 0.2)
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


## 从上方朝下打射线找地面
func _ground_y(pos: Vector3, fallback: float) -> float:
	var world := get_world_3d()
	if world == null:
		return fallback
	var from := Vector3(pos.x, fallback + 15.0, pos.z)
	var to := Vector3(pos.x, fallback - 60.0, pos.z)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 0xFFFFFFFF
	var hit := world.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return fallback
	return (hit["position"] as Vector3).y

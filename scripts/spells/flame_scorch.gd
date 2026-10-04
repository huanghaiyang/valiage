extends Node3D
## 火焰灼烧 —— 在角色正前方点燃一大片火焰，持续灼烧目标区域。
##
## 与「蓝色龙卷风」同属一类实现：**实例化一个特效场景 + 显隐开关**
## （另外两个是 GPUParticles3D，靠 emitting 开关）。
## 火焰本身的动画在 assets/shaders/fire_flame.gdshader 与 scripts/vfx/fire_burst.gd 里。
##
## 三个阶段（这也是"灼烧"的手感来源）：
##   ① 点燃 0.35 秒  从 0.2 倍长到 1 倍（sqrt 曲线：一开始"腾"地起来）
##   ② 燃烧          持续耗蓝；火焰自己在动，位置跟着角色朝向走
##   ③ 余烬 1.2 秒   停手后**不是立刻消失**，而是缩着烧完 —— 灼烧的余韵
##
## 对外接口与其它术法完全一致：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()

const FIRE_SCENE: PackedScene = preload("res://scenes/法术特效/火焰燃烧特效.tscn")
## 方向 + 起始位置：与其它术法共用同一份实现
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

@export var mana_per_sec := 26.0      ## 每秒耗蓝（介于火焰喷射 22 与火焰编织 34 之间）
@export var spawn_distance := 3.6     ## 落点：角色正前方多少米
@export var fire_scale := 1.0         ## 整体缩放（特效本身总高约 4.1 米）
@export var ignite_time := 0.35       ## 点燃时长（秒）
@export var afterburn_time := 1.2     ## 停手后的余烬时长（秒）

var casting := false

var _aim := SpellAim.new()
var _player: Node3D = null
var _fire: Node3D = null
var _ran_out := false
var _base_scale := 1.0

# 0 = 熄灭 / 1 = 点燃 / 2 = 燃烧 / 3 = 余烬
const ST_OFF := 0
const ST_IGNITE := 1
const ST_BURN := 2
const ST_AFTER := 3
var _state := ST_OFF
var _state_t := 0.0


func _ready() -> void:
	set_process(true)
	_fire = FIRE_SCENE.instantiate() as Node3D
	if _fire == null:
		push_warning("[FlameScorch] 特效场景根节点不是 Node3D: " + FIRE_SCENE.resource_path)
		return
	_fire.name = "FlameScorchFx"
	_fire.visible = false
	add_child(_fire)
	_base_scale = fire_scale
	# 整体缩放**只在建好时设一次**，之后不再动它。
	# ★ 动画绝不能缩放这个根节点：焰卡围着中心摆成一圈，缩放根节点会让它们向中心靠拢
	#   （用户："火焰熄灭不要向中心靠拢"）。燃烧/熄灭由 fire_burst 的 grow 驱动，
	#   每张卡在原位缩小 + 变暗，位置一动不动。
	_fire.scale = Vector3.ONE * _base_scale
	if _fire.has_method("set"):
		_fire.set("grow", 0.2)
	_place()


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true
	if _fire == null:
		return
	if _state == ST_OFF or _state == ST_AFTER:
		_state = ST_IGNITE
		_state_t = 0.0
	_place()
	_fire.visible = true


## 停手：不立刻消失，进入余烬阶段烧完为止
func stop_cast() -> void:
	casting = false


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 方向（水平、世界空间）—— 实现在 spell_aim.gd，与其它术法共用
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 起点（世界坐标）—— 火焰是贴地的一团，所以高度取地形表面
func origin_global() -> Vector3:
	_aim.origin_at_staff = false
	_aim.front_height = 0.0
	_aim.front_offset = spawn_distance
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _fire == null:
		return
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
			_place()
			if Mana.spend_rate(delta, mana_per_sec):
				_ran_out = false
			else:
				_ran_out = true
				_to_afterburn()
			if not casting:
				_to_afterburn()
		ST_AFTER:
			var k2 := clampf(_state_t / maxf(afterburn_time, 0.01), 0.0, 1.0)
			_apply_grow(pow(1.0 - k2, 0.6))
			if k2 >= 1.0:
				_state = ST_OFF
				_fire.visible = false


# ---------------------------------------------------------------- 内部
func _to_afterburn() -> void:
	if _state == ST_BURN or _state == ST_IGNITE:
		_state = ST_AFTER
		_state_t = 0.0


## 生长/熄灭：交给 fire_burst 的 grow（每张焰卡**在原位**缩小 + 变暗）
## ★ 不要改成缩放 _fire 本身：焰卡围成一圈，缩放根节点会让它们向中心靠拢。
func _apply_grow(s: float) -> void:
	if _fire != null:
		_fire.set("grow", clampf(s, 0.0, 1.0))


## 摆到 origin_global()，并把高度落到**地形表面**（在坡地上也不会浮空/埋进土里）
func _place() -> void:
	if _fire == null:
		return
	var p := origin_global()
	var y := p.y
	var fallback := _player.global_position.y if (_player != null and is_instance_valid(_player)) else p.y
	y = _ground_y(p, fallback)
	global_transform = Transform3D(Basis.IDENTITY, Vector3(p.x, y, p.z))


## 从上方朝下打一条射线找地面；打不到就退回 fallback
func _ground_y(pos: Vector3, fallback: float) -> float:
	var world := get_world_3d()
	if world == null:
		return fallback
	var from := Vector3(pos.x, fallback + 10.0, pos.z)
	var to := Vector3(pos.x, fallback - 40.0, pos.z)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 0xFFFFFFFF
	var hit := world.direct_space_state.intersect_ray(q)
	if hit.is_empty():
		return fallback
	return (hit["position"] as Vector3).y

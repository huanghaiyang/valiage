extends Node3D
## 蓝色龙卷风 —— 把 scenes/法术特效/蓝色龙卷风.tscn 接进法术体系。
##
## 与另外两个法术的**实现方式不同**，这点很关键：
##   · 火焰喷射 / 火焰编织 = GPUParticles3D，靠 `emitting` 开关；
##   · 蓝色龙卷风        = **静态网格 + VisualShader**，动画由着色器里的 TIME 驱动，
##                        所以"施法/停法"就是显隐节点，没有 emitting 可切。
##
## 摆放参考上游原始工程（spells-design/scenes/map.tscn）：
##   那边是**竖直、贴地、缩放 0.7**（演示场景，网格 12 单位高）。
##   本作角色约 1.08m，所以默认缩到 0.3（≈3.6m 高），在角色正前方地面升起。
##
## 对外接口与另外两个法术完全一致：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()

const TORNADO_SCENE: PackedScene = preload("res://scenes/法术特效/蓝色龙卷风.tscn")
## 方向 + 起始位置：与另外两个法术共用同一份实现
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

@export var mana_per_sec := 30.0      ## 每秒耗蓝（比火焰喷射 22 贵，比火焰编织 34 便宜）
@export var tornado_scale := 0.3      ## 网格原始 12 单位高 -> 0.3 ≈ 3.6m
@export var spawn_distance := 2.2     ## 落点：角色正前方多少米

var casting := false

var _aim := SpellAim.new()
var _tornado: Node3D = null
var _ran_out := false


func _ready() -> void:
	set_process(true)
	_tornado = TORNADO_SCENE.instantiate() as Node3D
	if _tornado == null:
		push_warning("[BlueTornado] 场景根节点不是 Node3D: " + TORNADO_SCENE.resource_path)
		return
	_tornado.name = "BlueTornado"
	_tornado.scale = Vector3.ONE * tornado_scale
	_tornado.visible = false          # 没施法时不显示
	add_child(_tornado)


func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true
	_place()                          # 先摆好位置再显示，避免第一帧闪在旧位置
	_set_visible(true)


func stop_cast() -> void:
	casting = false
	_set_visible(false)


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 方向（水平、世界空间）—— 实现在 spell_aim.gd，与另外两个法术共用
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 起点（世界坐标）—— 竖直的龙卷风贴地升起，所以高度取 0
func origin_global() -> Vector3:
	_aim.origin_at_staff = false
	_aim.front_height = 0.0
	_aim.front_offset = spawn_distance
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _tornado == null or not casting:
		return

	_place()

	if Mana.spend_rate(delta, mana_per_sec):
		_ran_out = false
		_set_visible(true)
	else:
		_ran_out = true
		_set_visible(false)


# ---------------------------------------------------------------- 内部
## 起点摆到 origin_global()；基向量保持**世界对齐** -> 龙卷风永远竖直（不随瞄准倾斜）
func _place() -> void:
	global_transform = Transform3D(Basis.IDENTITY, origin_global())


func _set_visible(v: bool) -> void:
	if _tornado != null and _tornado.visible != v:
		_tornado.visible = v

extends Node3D
## 火焰编织 —— 粗大的**横向**螺旋火柱（粒子实现，场景：scenes/fire_tornado.tscn）。
##
## 与火焰喷射一样是朝瞄准方向喷出去的：柱轴（着色器里的本地 +Y）每帧对齐 aim_dir()，
## 起点也走同一套（角色身前 1.05 米高、前方 0.6 米）。
##
## 形状在 assets/shaders/fire_tornado.gdshader 里：沿轴推进 + 绕轴旋转 + 半径张开（漏斗），
## 并且每颗粒子会**沿自己的运动方向被拉长**成火舌（不是圆点）。
##   ★ 那个 billboard 是着色器用 cam_local_pos 自己算的（这样"朝向相机"和"沿运动拉长"
##     才能同时成立），所以场景里节点必须保持 transform_align = DISABLED，别打开。
##
## **分两层**（关键，不是为了堆数量）：
##   · outer 外层：大半径 = 龙卷外壳
##   · inner 内层：小半径 + 大 radius_jitter = 把柱心填满
## 单层只沿圆柱面转，斜着看过去中间是空的（像根管子）。
##
## 对外接口（与另外两个实现一致）：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()

const TORNADO_SCENE: PackedScene = preload("res://scenes/fire_tornado.tscn")
## 方向 + 起始位置：与火焰喷射的两个实现共用同一份
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

@export var mana_per_sec := 34.0     ## 大火柱，比火焰喷射（22）贵

var casting := false

var _aim := SpellAim.new()
var _tornado: Node3D = null
var _emitters: Array[GPUParticles3D] = []
var _materials: Array[ShaderMaterial] = []
var _ran_out := false


func _ready() -> void:
	set_process(true)
	_tornado = TORNADO_SCENE.instantiate() as Node3D
	if _tornado == null:
		push_warning("[FireTornado] 场景根节点不是 Node3D: " + TORNADO_SCENE.resource_path)
		return
	_tornado.name = "FireTornado"
	add_child(_tornado)
	_collect(_tornado)
	if _emitters.is_empty():
		push_warning("[FireTornado] " + TORNADO_SCENE.resource_path + " 里没找到 GPUParticles3D")
		return
	for p in _emitters:
		p.emitting = false        # 没施法不喷


func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true
	_place()            # 先摆好位置再开喷，避免第一帧从世界原点冒出来
	_set_emitting(true)


func stop_cast() -> void:
	casting = false
	_set_emitting(false)


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 喷射方向（水平、世界空间）—— 实现在 spell_aim.gd，与火焰喷射共用
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 起点（世界坐标）—— 实现在 spell_aim.gd，与火焰喷射共用
func origin_global() -> Vector3:
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _emitters.is_empty() or not casting:
		return

	_place()

	if Mana.spend_rate(delta, mana_per_sec):
		_ran_out = false
		_set_emitting(true)
	else:
		_ran_out = true
		_set_emitting(false)


# ---------------------------------------------------------------- 内部
## 柱轴（本地 +Y）对准瞄准方向 -> 横向喷射；起点与火焰喷射一致
func _place() -> void:
	var d := aim_dir()
	var ref := Vector3.UP
	if absf(d.dot(Vector3.UP)) >= 0.99:
		ref = Vector3.FORWARD
	var right := ref.cross(d).normalized()
	var fwd := right.cross(d).normalized()          # Z = X × Y，保持右手系
	global_transform = Transform3D(Basis(right, d, fwd), origin_global())
	_update_cam_uniform()


## 着色器要自己算 billboard，所以得让它知道相机在**节点本地空间**里的位置
func _update_cam_uniform() -> void:
	if _materials.is_empty() or not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := to_local(cam.global_position)
	for m in _materials:
		m.set_shader_parameter("cam_local_pos", p)


func _set_emitting(on: bool) -> void:
	for p in _emitters:
		if p.emitting != on:
			p.emitting = on


func _collect(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GPUParticles3D:
			var p := n as GPUParticles3D
			_emitters.append(p)
			var m := p.process_material
			if m is ShaderMaterial:
				_materials.append(m as ShaderMaterial)
		for c in n.get_children():
			stack.append(c)

extends Node3D
## 火焰喷射 —— **粒子实现**：视觉直接实例化 scenes/fire_jet.tscn（GPUParticles3D）。
##
## 与着色器版（flame_visual.gd）的差别只在"怎么画"；施法、耗蓝、**瞄准方向**、**喷射起点**
## 全部共用 spell_aim.gd —— 两个实现的弹道行为因此永远一致（不想再出现"同一段代码抄两份、
## 只修一处"的事故）。
##
## 对外接口（与 flame_visual.gd 一模一样）：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()
##
## 两个实现要点：
##   1) 喷射方向每帧写进 ParticleProcessMaterial.direction，**本节点不旋转**。
##      同时把全局基向量强制成世界对齐，避免父节点带旋转时把写进去的世界方向带歪。
##   2) fire_jet.tscn 里的 spark 带了一个约 1.1 米的摆位偏移（当初在别的场景里对位用的），
##      这里把 emitter 的局部位置归零，让喷口严格等于 origin_global()。
##      —— 故意不修改那个场景文件：它是未提交的新资产，且可能正开在编辑器里。

const JET_SCENE: PackedScene = preload("res://scenes/fire_jet.tscn")
## 瞄准方向 + 喷射起点：与着色器版共用同一份实现。
## 想改成"从法杖顶端喷"，改 spell_aim.gd 里的 origin_at_staff（两个实现同时生效）。
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

@export var mana_per_sec := 22.0        ## 每秒耗蓝（显式传给 Mana.spend_rate，不用 mana.gd 的默认值）
@export var speed_scale_mul := 1.0      ## 相对 fire_jet.tscn 自身 speed_scale 的倍率（1.0 = 沿用资产里的值）

var casting := false

var _aim := SpellAim.new()
var _jet: Node3D = null
var _emitters: Array[GPUParticles3D] = []
var _ran_out := false


func _ready() -> void:
	set_process(true)
	_jet = JET_SCENE.instantiate() as Node3D
	if _jet == null:
		push_warning("[FlameJet] 场景根节点不是 Node3D: " + JET_SCENE.resource_path)
		return
	_jet.name = "FireJet"
	add_child(_jet)
	_collect_emitters(_jet)
	if _emitters.is_empty():
		push_warning("[FlameJet] " + JET_SCENE.resource_path + " 里没找到 GPUParticles3D")
		return
	for p in _emitters:
		p.emitting = false            # 没施法时不喷
		p.local_coords = false        # 世界空间：喷出去的火留在原地，转身时自然拖尾
		p.position = Vector3.ZERO     # 抹掉场景里烘焙的摆位偏移，喷口 = 本节点原点
		p.speed_scale *= speed_scale_mul


func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true
	_place()            # 先摆好位置再开喷，避免第一帧从世界原点喷出一小撮
	_set_emitting(true)


func stop_cast() -> void:
	casting = false
	_set_emitting(false)


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 喷射方向（水平、世界空间）—— 实现在 spell_aim.gd，与着色器版共用
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 喷射起点（世界坐标）—— 实现在 spell_aim.gd，与着色器版共用
func origin_global() -> Vector3:
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _emitters.is_empty():
		return

	var d := aim_dir()
	# 方向直接写世界方向（节点不旋转），每帧更新 -> 人转身，新喷出的火立刻跟着转
	for p in _emitters:
		var pm := p.process_material
		if pm is ParticleProcessMaterial:
			(pm as ParticleProcessMaterial).direction = d

	if not casting:
		return

	_place()

	if Mana.spend_rate(delta, mana_per_sec):
		_ran_out = false
		_set_emitting(true)
	else:
		_ran_out = true
		_set_emitting(false)


# ---------------------------------------------------------------- 内部
## 把喷口摆到 origin_global()；基向量强制世界对齐，父节点带旋转/缩放也不会跑偏
func _place() -> void:
	global_transform = Transform3D(Basis.IDENTITY, origin_global())


func _set_emitting(on: bool) -> void:
	for p in _emitters:
		if p.emitting != on:
			p.emitting = on


func _collect_emitters(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GPUParticles3D:
			_emitters.append(n as GPUParticles3D)
		for c in n.get_children():
			stack.append(c)

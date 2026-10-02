extends Node3D
## 火焰喷射 —— 纯 VisualShader 实现（本项目特效统一用节点着色器制作）。
##
## 载体：4 片"圆柱公告板"四边形（法线转向相机、只错开 ±23 度），沿喷射方向铺开。
##   为什么这么做：固定角度的交叉片从俯视看会变成星形/花瓣；公告板才会叠成一束。
## 着色器：assets/shaders/flame_jet_visual.tres —— VisualShader 节点图，编辑器里可直接改。
##   节点图里是一个 Expression 节点（output0 -> Albedo / output1 -> Alpha / output2 -> Emission）。
##
## 瞄准方向 / 喷射起点不再自己实现，改用与粒子版共用的 spell_aim.gd —— 两个实现的弹道
## 行为因此永远一致（不想再出现"同一段代码抄两份、只修一处"的事故）。
##
## 对外接口（spell_caster 调用，与 flame_jet_particles.gd 完全一致）：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()

const SHADER_PATH := "res://assets/shaders/flame_jet_visual.tres"
## 瞄准方向 + 喷射起点：与粒子版共用同一份实现。
## 想改成"从法杖顶端喷"，改 spell_aim.gd 里的 origin_at_staff（两个实现同时生效）。
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

@export var mana_per_sec := 22.0
@export var jet_length := 3.2          ## 火柱长度（米）
@export var jet_width := 1.10          ## 火柱宽度（米）
@export var blade_count := 4           ## 交叉片数（圆柱公告板）

var casting := false
var _aim := SpellAim.new()
var _root: Node3D = null
var _blades: Array[MeshInstance3D] = []
var _ran_out := false


func _ready() -> void:
	set_process(true)
	var sh: Shader = load(SHADER_PATH)
	if sh == null:
		push_warning("[FlameJet] 着色器载入失败: " + SHADER_PATH)
		return
	var mat := ShaderMaterial.new()
	mat.shader = sh
	_root = Node3D.new()
	_root.visible = false
	add_child(_root)
	for i in range(maxi(1, blade_count)):
		var q := QuadMesh.new()
		# FACE_Y：平面躺在 XZ（本地 X=宽度、本地 Y=法线、本地 Z=长度）
		q.orientation = PlaneMesh.FACE_Y
		q.size = Vector2(jet_width, jet_length)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.material_override = mat
		mi.position = Vector3(0.0, 0.0, -jet_length * 0.5)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(mi)
		_blades.append(mi)


func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true
	if _root != null:
		_root.visible = true


func stop_cast() -> void:
	casting = false
	if _root != null:
		_root.visible = false


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 喷射方向（水平、世界空间）—— 实现在 spell_aim.gd，与粒子版共用
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 喷射起点（世界坐标）—— 实现在 spell_aim.gd，与粒子版共用
func origin_global() -> Vector3:
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if not casting or _root == null:
		return
	var d := aim_dir()
	global_position = origin_global()
	var up := Vector3.UP
	if absf(d.dot(up)) > 0.999:
		up = Vector3.FORWARD
	look_at(global_position + d, up)
	_orient_blades()
	if Mana.spend_rate(delta, mana_per_sec):
		_ran_out = false
		_root.visible = true
	else:
		_ran_out = true
		_root.visible = false


## 圆柱公告板：在 _root 的局部空间里摆每片（局部 -Z 就是喷射方向）
func _orient_blades() -> void:
	var ax := Vector3(0.0, 0.0, -1.0)
	var to_cam_w := Vector3.UP
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null and is_instance_valid(cam):
		to_cam_w = cam.global_position - global_position
	var inv := _root.global_transform.basis.inverse()
	var to_cam := inv * to_cam_w
	var perp := to_cam - ax * to_cam.dot(ax)
	if perp.length_squared() < 0.0001:
		perp = Vector3.UP - ax * Vector3.UP.dot(ax)
	if perp.length_squared() < 0.0001:
		perp = Vector3.RIGHT
	perp = perp.normalized()
	var n := maxi(1, _blades.size())
	for i in range(_blades.size()):
		# 只错开正负 23 度左右：既叠成一束、又有厚度
		var roll := deg_to_rad(46.0 * (float(i) / float(n) - 0.5))
		var nrm := (Basis(ax, roll) * perp).normalized()
		var wid := nrm.cross(ax).normalized()
		# 长度轴取 -ax：叶片几何在本地 z 的负半轴，所以"本地 -Z"要指向喷射方向
		_blades[i].basis = Basis(-wid, nrm, -ax)

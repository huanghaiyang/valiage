extends Node3D
## 手持法杖：把 assets/models/crafted 下的 GLB 挂到右手骨骼上。
##
## 这是**按新模型重写**的一版（旧的 569 行版本随低多边形法杖一起删掉了）。
## 新模型（make_staff_spectrum.py 导出）的特点让代码能简单很多：
##
##   * Blender 里是 Z 轴向上、模型底面正好落在原点、水平居中，
##     glTF 导出用 export_yup=True -> 到 Godot 里**模型局部 +Y 就是杖身方向、
##     原点在杖底中心**。所以不需要再做"扫描 48 组旋转去找对齐角"那种事
##     （旧 GLB 的轴向是各种歪的，才有那段旁举扫描）。
##   * 朝向直接写**世界 basis**：法杖挂在会旋转的手骨上，奔跑摆臂时手骨自己在转，
##     挂在它下面的杖会被杠杆放大（手往前摆、杖头往后甩）。在局部轴上加补偿修不好，
##     所以每帧算世界方向直接写 —— 挂点只决定"握在哪"，朝向由我们说了算。
##
## 握点：模型按"目标世界长度"缩放后，把**从杖底往上 32%** 处对到挂点原点。

## 法杖在世界里的目标长度（米）。角色约 1.7m，1.45m 的杖握在手里刚好。
const STAFF_WORLD_LEN := 1.45
## 握点：从杖底往上算的比例
const GRIP_FRAC := 0.32

# ---- 展示姿态 ----
## 默认从竖直朝角色正前方倒 60°（用户要求）
const FORWARD_TILT_DEG := 60.0
## 奔跑时再往前挥一档 + 一点正弦摆动
const RUN_TILT_DEG := 22.0
const RUN_SWING_DEG := 7.0
const RUN_SWING_HZ := 1.9
## 达到这个水平速度算全速（角色走 5.0 / 跑 9.0）
const RUN_FULL_SPEED := 9.0

const HOVER_SPEED := 1.5
const HOVER_AMOUNT := 0.020
const PULSE_SPEED := 2.2

var staff_id := ""
var element := 0
## 调试/自检用：>= 0 时直接当作角色速度（跑动姿态的数值验收）
var debug_speed := -1.0

var _model: Node3D = null
var _glow: OmniLight3D = null
var _fx: Node3D = null
var _model_h := 1.0          # 模型原始高度（模型局部单位）
var _run_phase := 0.0
var _hover_t := 0.0
var _pulse := 0.0
var _parent_scale := 1.0
## 握点偏移（模型局部单位，负值）。_place() 里量出来存下，_process 的悬浮基于它。
var _grip_y := 0.0
var _need_place := false
var _pending_glow: Dictionary = {}


func _ready() -> void:
	set_process(true)


# ============================================================ 装配

## 换杖（id 为空 = 收起）
func set_staff(id: String, elem: int) -> void:
	_local_ok = false      # 换杖 -> 重新标定局部朝向
	staff_id = id
	element = elem
	_clear()
	if id == "":
		return
	var sys := _staff_system()
	if sys == null:
		return
	var d: Dictionary = sys.call("get_def", id)
	if d.is_empty():
		push_warning("HeldStaff: 没有登记过的法杖 id=%s" % id)
		return
	var path := str(d.get("model", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("HeldStaff: 模型不存在 %s" % path)
		return
	var scene: PackedScene = load(path)
	_model = scene.instantiate() as Node3D
	if _model == null:
		return
	_model.name = "Model"
	_pivot_add(_model)
	# **不在这一帧量**：global 变换是惰性求值的，刚 add_child 完读父级 global 拿到的是
	# 入树前的值（父级 Visual 的 0.368 缩放会读成 1.0），于是杖只有目标的 0.368 倍高。
	# 实测：1.45m 的杖在游戏里只有 0.53m，截图里几乎看不见。交给下一帧的 _process。
	_need_place = true
	_pending_glow = d


func _pivot_add(n: Node) -> void:
	add_child(n)


## 量模型（**沿局部 transform 累乘**，不用 global_transform —— 它入树后要等一帧
## 才刷新，当帧读到的是脏值），然后定尺寸与握点。
func _place() -> void:
	# 自上而下刷新：自下而上调用 force_update_transform 时，下层用的是父级的旧值
	var chain: Array = []
	var n: Node = self
	while n != null:
		chain.append(n)
		n = n.get_parent()
	for i in range(chain.size() - 1, -1, -1):
		if chain[i] is Node3D:
			(chain[i] as Node3D).force_update_transform()
	var pn := get_parent()
	if pn is Node3D:
		_parent_scale = maxf(0.0001, (pn as Node3D).global_transform.basis.get_scale().x)
	var boxes := _mesh_aabbs(_model)
	var bb := _merge_aabbs(boxes)
	if boxes.is_empty() or bb.size.y < 0.05:
		push_warning("HeldStaff: 量不到模型包围盒，保持原始尺寸")
		return
	_model_h = bb.size.y
	# 模型局部单位 -> 世界米 = _model.scale * _parent_scale
	# 所以要让世界高度等于目标长度：scale = 目标 / (原始高 * 父级缩放)
	var want := float(_sys_def().get("world_len", STAFF_WORLD_LEN))
	var sc := want / (_model_h * _parent_scale)
	_model.scale = Vector3.ONE * sc
	# 水平居中 + 把"杖底往上 GRIP_FRAC 处"对到原点
	var cx := bb.position.x + bb.size.x * 0.5
	var cz := bb.position.z + bb.size.z * 0.5
	var gy := bb.position.y + GRIP_FRAC * bb.size.y
	_grip_y = -gy * sc                     # 存下来：悬浮是在这个基准上叠加
	_model.position = Vector3(-cx * sc, _grip_y, -cz * sc)


func _sys_def() -> Dictionary:
	var sys := _staff_system()
	return {} if sys == null else sys.call("get_def", staff_id)


func _staff_system() -> Node:
	return get_node_or_null("/root/StaffSystem")


func _clear() -> void:
	if _model != null:
		var m := _model
		_model = null
		_glow = null
		_fx = null
		remove_child(m)
		m.queue_free()


## 杖头位置（模型局部）：朝 +Y 走 88% 处
func _head_local() -> Vector3:
	return Vector3(0.0, 0.88 * _model_h, 0.0)


func _build_glow(d: Dictionary) -> void:
	if _model == null:
		return
	var col := _elem_color(element)
	# 杖头小灯：让杖在夜里也有存在感
	_glow = OmniLight3D.new()
	_glow.name = "Glow"
	_glow.light_color = col
	_glow.omni_range = 3.0
	_glow.light_energy = 1.1
	_glow.shadow_enabled = false
	var hs := _model.scale.x
	_glow.position = _head_local() * 0.92
	_glow.omni_range = 3.0 / maxf(0.05, hs * _parent_scale)
	_model.add_child(_glow)
	# 杖头光点：一个小小的自发光球，比纯灯光更像"宝石在发亮"
	var mi := MeshInstance3D.new()
	mi.name = "SparkCore"
	var sm := SphereMesh.new()
	var r := 0.030 / maxf(0.05, hs * _parent_scale)
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 3.0
	mi.material_override = mat
	mi.position = _head_local()
	_model.add_child(mi)


func _elem_color(e: int) -> Color:
	var sys := _staff_system()
	if sys != null:
		return sys.call("element_color", e)
	return Color(0.86, 0.74, 1.0)


# ============================================================ 每帧

func _process(delta: float) -> void:
	if _model == null or not _model.is_inside_tree():
		return
	if _need_place:
		# 入树后第一帧才量：这时父链的 global 变换已经刷新过了
		_need_place = false
		_place()
		_build_glow(_pending_glow)
		_pending_glow = {}
		return
	_apply_pose(delta)
	# 悬浮：沿世界竖直轻轻上下（不是模型局部轴 —— 那个已经被倾斜过了）
	_hover_t += delta * HOVER_SPEED
	_model.position.y = _grip_y + sin(_hover_t) * HOVER_AMOUNT / _world_to_local()
	if _glow != null:
		_pulse += delta * PULSE_SPEED
		_glow.light_energy = (1.0 + 0.35 * sin(_pulse)) * 1.1


func _world_to_local() -> float:
	# 1 模型局部单位 = 多少世界米
	var s := global_transform.basis.get_scale().x * _model.scale.x
	return maxf(0.0001, s)


## 法杖在手里上下翻转 180°（修「杖头朝下 / 反向握」）。检查器里一键切换。
@export var flip_in_hand := false

## 手骨局部朝向（标定一次）——「刚性固定在手上」就靠它
var _local_basis := Basis.IDENTITY
var _local_ok := false
var _spin := 0.0

## 每帧把法杖的**世界朝向**写成目标方向：默认前倾 60°，奔跑时再前挥一档。
## 见文件头说明：法杖挂在会旋转的手骨上，只有绕开局部轴才不会"手往前摆、杖往后甩"。
func _apply_pose(delta: float) -> void:
	var fwd := _facing()
	if fwd == Vector3.ZERO:
		return
	_run_phase += delta * TAU * RUN_SWING_HZ
	var run := clampf(_owner_speed() / RUN_FULL_SPEED, 0.0, 1.0)
	var deg := FORWARD_TILT_DEG + RUN_TILT_DEG * run \
			+ RUN_SWING_DEG * run * sin(_run_phase)
	var tilt := deg_to_rad(deg)
	# 杖身方向：从世界竖直朝角色正前方倒 tilt
	var ycol := (Vector3.UP * cos(tilt) + fwd * sin(tilt)).normalized()
	# 右手系：z = -fwd（Godot 的"前"是 -Z）正交化到 ycol 上，x = y x z
	var zcol := (-fwd - ycol * (-fwd).dot(ycol))
	if zcol.length() < 0.001:
		zcol = Vector3.BACK
	zcol = zcol.normalized()
	var xcol := ycol.cross(zcol).normalized()
	var want := Basis(xcol, ycol, zcol)
	# 模型自身方向修正：Tripo 出的法杖有的"头"在 -Y、有的在 +Y。
	# 打开就把法杖在手里**上下翻转 180°**（绕模型局部 X 轴），用来修"杖头朝下/反向握"。
	if flip_in_hand:
		want = want * Basis(Vector3.RIGHT, PI)
	# ---- 刚性固定在手上（用户要求）----
	# 原来这里每帧写 `global_transform`（世界朝向），而位置跟着手骨 ——
	# 两者打架：手一摆，法杖就以握点为轴自己转一圈（"按 WASD 就复现"）。
	# 现在只做**一次标定**：把"想要的世界朝向"换算成手骨的局部朝向存下来，
	# 之后只写局部 basis，位置完全交给手骨 —— 手怎么动法杖就怎么动，
	# 这才是"固定在角色手上"。
	var hand := get_parent() as Node3D
	if hand == null:
		return
	if not _local_ok:
		_local_basis = (hand.global_transform.basis.inverse() * want).orthonormalized()
		_local_ok = true
	var sc := basis.get_scale()          # 保留挂载时算好的缩放
	basis = _local_basis.scaled(sc)
	# 刚性固定：不再做任何自转（否则又变成'自己转圈'）


func _owner_body() -> Node3D:
	var n := get_parent()
	while n != null:
		if n is CharacterBody3D:
			return n as Node3D
		n = n.get_parent()
	return null


func _facing() -> Vector3:
	var b := _owner_body()
	if b == null:
		return Vector3.ZERO
	# 角色**面朝**方向 = 模型的 +Z。
	# player.gd::face_direction() 用 atan2(face.x, face.z) 设 rotation.y，
	# 即把 face 对齐到 +Z（文件里也写着「Mage 模型 +Z 为面部前方」）。
	# 原来取 -basis.z（= 背面），于是「前倾 60°」变成朝身后倒 ——
	# 用户：「杖头应该在身体前，而不是身体后」。
	var f := b.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.001 else Vector3.ZERO


func _owner_speed() -> float:
	if debug_speed >= 0.0:
		return debug_speed
	var b := _owner_body()
	if b == null:
		return 0.0
	return Vector2(b.velocity.x, b.velocity.z).length()


# ============================================================ 包围盒（局部累乘）

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
	if list.is_empty():
		return AABB()
	var bb: AABB = list[0]
	for i in range(1, list.size()):
		bb = bb.merge(list[i])
	return bb


func _body_pos() -> Vector3:
	var b := _owner_body()
	return Vector3.ZERO if b == null else b.global_position


func _cam_pos() -> Vector3:
	var vp := get_viewport()
	if vp == null:
		return Vector3.ZERO
	var c := vp.get_camera_3d()
	return Vector3.ZERO if c == null else c.global_position


## 把模型局部包围盒的 8 个角变换到世界，得到世界空间的包围盒
func _world_aabb(bb: AABB) -> AABB:
	var xf := _model.global_transform
	var out := AABB()
	var first := true
	for i in 8:
		var c := bb.position + Vector3(
				bb.size.x * float(i & 1),
				bb.size.y * float((i >> 1) & 1),
				bb.size.z * float((i >> 2) & 1))
		var w := xf * c
		if first:
			out = AABB(w, Vector3.ZERO)
			first = false
		else:
			out = out.expand(w)
	return out


## 诊断：把"到底挂成什么样"打成一行，不靠肉眼猜。
func debug_info() -> Dictionary:
	if _model == null:
		return {"ok": false}
	var boxes := _mesh_aabbs(_model)
	var bb := _merge_aabbs(boxes)
	var gs := _model.global_transform.basis.get_scale()
	var up := (_model.global_transform.basis * Vector3.UP).normalized()
	var facing := _facing()
	return {
		"ok": true,
		"model_h_local": _model_h,
		"model_scale": _model.scale.x,
		"world_h": _model_h * _model.scale.x * _parent_scale,
		"global_scale": gs.x,
		"up_dot_world_up": up.dot(Vector3.UP),
		"fwd_dot": up.dot(facing),
		"node_pos": global_position,
		"model_pos": _model.global_position,
		"grip_y": _grip_y,
		"aabb_local": bb,
		"world_aabb": _world_aabb(bb),
		"facing": facing,
		"body_pos": _body_pos(),
		"cam": _cam_pos(),
	}


## 施法瞬间：杖头闪一下（供技能/长老仪式调用）
func flash(strength: float = 1.6) -> void:
	if _glow != null:
		_glow.light_energy = strength * 4.0

extends Node3D
## 火焰喷射（法术圆盘第一层第一格）。
##
## ★ 发射位置：默认 = **角色正前方**（身前 front_offset 米、胸口高 front_height）。
##   也能切回「法杖顶端」模式（origin_mode = STAFF_TIP），两种都靠参数切换，不写死坐标。
##
## ★ 方向：角色正前方的水平投影。粒子用 local_coords = false（火焰留在世界里当尾迹），
##   这种情况下 ParticleProcessMaterial.direction 按**世界方向**解释 —— 转节点会被忽略，
##   所以这里节点保持单位朝向，每帧把世界方向写进 direction。
##
## ★★ 火焰形状：两级（这是"尾部翻滚"的关键）★★
##   第一级 FlameCore ：快、细、短命、白热 —— 从发射点喷出的火线
##   第二级 FlameCloud：**由核心粒子寿命结束时（SUB_EMITTER_AT_END）在原地生成** ——
##                      大、慢、寿命长、强湍流 —— 就是参考图里末端翻滚膨胀的火焰/烟云
##   （不是"粒子一直往前飞"，而是核心跑到哪，云就在哪翻滚膨胀）
##
## headless 下不把粒子节点挂进场景树（会挂住进程），但两级材质照常构造，逻辑可测。

const StaffTip := preload("res://scripts/spells/staff_tip.gd")

enum Origin { STAFF_TIP, PLAYER_FRONT }

@export var mana_per_sec := 22.0
@export var origin_mode := Origin.PLAYER_FRONT
@export var front_offset := 0.60      ## 发射点在身前多远
@export var front_height := 1.05      ## 发射点高度（胸口附近）
@export var headless_skip_particles := true

var casting := false
var _core_node: GPUParticles3D = null
var _cloud_node: GPUParticles3D = null
var _glow_core: MeshInstance3D = null
var _light: OmniLight3D = null
var _core_pm: ParticleProcessMaterial = null
var _cloud_pm: ParticleProcessMaterial = null
var _staff: Node3D = null
var _player: Node3D = null
var _last_dir := Vector3.FORWARD
var _cam: Camera3D = null
var _found_facing := false
var _ran_out := false
# 便于自检：headless 下也能拿到两级材质
var core_material: ParticleProcessMaterial = null
var cloud_material: ParticleProcessMaterial = null


func _ready() -> void:
	set_process(true)
	_core_pm = _build_core_material()
	_cloud_pm = _build_cloud_material()
	core_material = _core_pm
	cloud_material = _cloud_pm
	_build_nodes()


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	_staff = staff


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	casting = true

func stop_cast() -> void:
	casting = false
	if _core_node != null:
		_core_node.emitting = false
	if _cloud_node != null:
		_cloud_node.emitting = false
	if _glow_core != null:
		_glow_core.visible = false
	if _light != null:
		_light.visible = false


func is_casting() -> bool:
	return casting

func ran_out_of_mana() -> bool:
	return _ran_out


## 喷射方向（水平、世界空间）。
##
## ★★ 用「移动方向」，不是节点朝向 ★★
##   这个项目里玩家根节点是 CharacterBody3D，但**它自己永远不转**：
##   朝向写在 body 子节点（player.gd L540 face_direction -> body.rotation.y），
##   位置由 CameraRig 用 move_and_slide 驱动。
##   所以 -player.basis.z 恒等于世界 -Z，拿它当方向 = 火永远朝一个方向喷。
##   优先级：实际速度方向 -> 相机水平前向 -> player.get_facing_yaw() -> 上一次的方向
func aim_dir() -> Vector3:
	var d := Vector3.ZERO
	# 1) 真实移动方向（CharacterBody3D.velocity 由 camer_rig 的 move_and_slide 写入）
	if _player != null and is_instance_valid(_player) and "velocity" in _player:
		var v: Variant = _player.get("velocity")
		if v is Vector3:
			d = Vector3(v.x, 0.0, v.z)
	# 2) 相机水平前向：站着不动时"往前"就是镜头前方（等距/三人称都成立）
	if d.length_squared() < 0.0004:
		if _cam == null or not is_instance_valid(_cam):
			_cam = get_viewport().get_camera_3d()
		if _cam != null and is_instance_valid(_cam):
			var cf := -_cam.global_transform.basis.z
			d = Vector3(cf.x, 0.0, cf.z)
	# 3) 项目自己的朝向接口（朝向在 body 子节点上，别用根节点的 basis）
	if d.length_squared() < 0.0004 and _player != null and is_instance_valid(_player) and _player.has_method("get_facing_yaw"):
		var yaw := float(_player.call("get_facing_yaw"))
		d = Vector3(-sin(yaw), 0.0, -cos(yaw))
		_found_facing = true
	# 4) 都没有 -> 保持上一次（避免站着不动时方向乱跳）
	if d.length_squared() < 0.000001:
		return _last_dir
	d = d.normalized()
	_last_dir = d
	return d


## 喷射起点（世界坐标）
func origin_global() -> Vector3:
	if origin_mode == Origin.STAFF_TIP and _staff != null and is_instance_valid(_staff):
		return StaffTip.tip_global(_staff)
	if _player != null and is_instance_valid(_player):
		return _player.global_position + Vector3.UP * front_height + aim_dir() * front_offset
	return global_position


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _core_pm == null or _cloud_pm == null:
		return
	var d := aim_dir()
	# ★ 方向直接写世界方向（节点不旋转），每帧更新 -> 人转身火跟着转
	_core_pm.direction = d
	_cloud_pm.direction = d
	if not casting:
		return
	global_position = origin_global()
	if Mana.spend_rate(delta, mana_per_sec):
		_ran_out = false
		if _core_node != null:
			_core_node.emitting = true
		if _cloud_node != null:
			_cloud_node.emitting = true
		if _glow_core != null:
			_glow_core.visible = true
		if _light != null:
			_light.visible = true
	else:
		_ran_out = true
		if _core_node != null:
			_core_node.emitting = false
		if _cloud_node != null:
			_cloud_node.emitting = false
		if _glow_core != null:
			_glow_core.visible = false
		if _light != null:
			_light.visible = false


# ---------------------------------------------------------------- 第一级：核心火线
func _build_core_material() -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.05
	pm.direction = Vector3(0.0, 0.0, -1.0)
	pm.spread = 5.0
	pm.initial_velocity_min = 11.0
	pm.initial_velocity_max = 15.0
	pm.gravity = Vector3(0.0, 0.8, 0.0)
	# ★ 初速度很快、末端明显变慢：基础阻尼大 + damping_curve 从 0 升到 1
	pm.damping_min = 3.0
	pm.damping_max = 9.0
	pm.particle_flag_damping_as_friction = true
	var dc := Curve.new()
	dc.add_point(Vector2(0.0, 0.0))
	dc.add_point(Vector2(0.35, 0.45))
	dc.add_point(Vector2(1.0, 1.0))
	var dct := CurveTexture.new()
	dct.curve = dc
	pm.damping_curve = dct
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -3.0
	pm.angular_velocity_max = 3.0
	# 细 -> 稍粗
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.22))
	sc.add_point(Vector2(1.0, 0.65))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	pm.scale_min = 0.45
	pm.scale_max = 1.05
	# 一点湍流，让火线本身也抖
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.8
	pm.turbulence_noise_scale = 2.6
	pm.turbulence_noise_speed = Vector3(2.2, 1.2, 1.8)
	# 白热 -> 黄 -> 橙
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 1.0, 0.95, 1.0))
	g.add_point(0.25, Color(1.0, 0.95, 0.72, 1.0))
	g.add_point(0.55, Color(1.0, 0.72, 0.25, 0.95))
	g.set_color(g.get_point_count() - 1, Color(1.0, 0.45, 0.10, 0.8))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	# ★ 核心粒子寿命结束时 -> 原地生成云（这就是"尾部翻滚"的来源）
	pm.sub_emitter_mode = ParticleProcessMaterial.SUB_EMITTER_AT_END
	pm.sub_emitter_amount_at_end = 1
	pm.sub_emitter_keep_velocity = true
	return pm


# ---------------------------------------------------------------- 第二级：翻滚的云
func _build_cloud_material() -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.28          # 云从"一团"里冒出来
	pm.direction = Vector3(0.0, 0.0, -1.0)
	# ★ 尾部不要散太大：张角小、几乎不径向扩
	pm.spread = 16.0
	pm.initial_velocity_min = 1.0
	pm.initial_velocity_max = 2.4
	pm.radial_velocity_min = 0.0
	pm.radial_velocity_max = 0.25
	pm.gravity = Vector3(0.0, 1.2, 0.0)
	pm.damping_min = 4.0
	pm.damping_max = 10.0
	pm.particle_flag_damping_as_friction = true
	var dc2 := Curve.new()
	dc2.add_point(Vector2(0.0, 0.1))
	dc2.add_point(Vector2(1.0, 1.0))
	var dct2 := CurveTexture.new()
	dct2.curve = dc2
	pm.damping_curve = dct2
	pm.angle_min = -180.0
	pm.angle_max = 180.0
	pm.angular_velocity_min = -1.6
	pm.angular_velocity_max = 1.6
	# ★ 越长越大（末端膨胀）
	# 注意：Curve 的 Y 默认被钳在 0..1（min_value/max_value），超过 1 的点会被压平。
	# 所以曲线的形状用 0..1 表示「相对增长」，绝对大小交给 scale_min/max。
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.35))
	sc.add_point(Vector2(0.45, 0.72))
	sc.add_point(Vector2(1.0, 1.0))
	var sct := CurveTexture.new()
	sct.curve = sc
	pm.scale_curve = sct
	pm.scale_min = 0.95
	pm.scale_max = 2.40
	# ★ 强湍流 + 一出生就错位 -> 翻滚
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.5
	pm.turbulence_noise_scale = 1.9
	pm.turbulence_noise_speed = Vector3(1.0, 0.6, 0.8)
	pm.turbulence_noise_speed_random = 0.5
	pm.turbulence_initial_displacement_min = 0.04
	pm.turbulence_initial_displacement_max = 0.12
	var ti := Curve.new()
	ti.add_point(Vector2(0.0, 0.35))
	ti.add_point(Vector2(0.4, 0.80))
	ti.add_point(Vector2(1.0, 1.0))
	var tit := CurveTexture.new()
	tit.curve = ti
	pm.turbulence_influence_over_life = tit
	# 亮橙 -> 暗红 -> 灰烟 -> 透明（对应参考图：火焰末端转成翻滚的烟）
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.85, 0.45, 0.95))
	g.add_point(0.18, Color(1.0, 0.55, 0.12, 0.85))
	g.add_point(0.42, Color(0.80, 0.26, 0.06, 0.60))
	g.add_point(0.62, Color(0.42, 0.34, 0.32, 0.45))
	g.add_point(0.82, Color(0.30, 0.29, 0.29, 0.30))
	g.set_color(g.get_point_count() - 1, Color(0.22, 0.22, 0.22, 0.0))
	var gt := GradientTexture1D.new()
	gt.gradient = g
	pm.color_ramp = gt
	return pm


# ---------------------------------------------------------------- 节点
func _build_nodes() -> void:
	if headless_skip_particles and DisplayServer.get_name() == "headless":
		return
	_core_node = _make_particles("FlameCore", 520, 0.34, _core_pm, 0.55, 0.55, true)
	_cloud_node = _make_particles("FlameCloud", 900, 1.70, _cloud_pm, 1.10, 1.10, false)
	# ★ 把"核心寿命结束 -> 生成云"接起来
	_core_node.sub_emitter = _core_node.get_path_to(_cloud_node)
	# 起点核心亮点
	var core := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.07
	sm.height = 0.14
	core.mesh = sm
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	cm.albedo_color = Color(1.0, 0.92, 0.65, 0.95)
	core.material_override = cm
	core.visible = false
	add_child(core)
	_glow_core = core
	var lt := OmniLight3D.new()
	lt.light_color = Color(1.0, 0.60, 0.22)
	lt.light_energy = 4.5
	lt.omni_range = 8.0
	lt.visible = false
	add_child(lt)
	_light = lt


func _make_particles(pname: String, amount: int, life: float, pm: ParticleProcessMaterial, qsize: float, reach: float, add_blend: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = pname
	p.amount = amount
	p.lifetime = life
	p.one_shot = false
	p.explosiveness = 0.0
	p.local_coords = false
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	p.trail_enabled = true
	p.trail_lifetime = 0.18
	p.process_material = pm
	var qm := QuadMesh.new()
	qm.size = Vector2(qsize, qsize)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# 核心用加色（发光）；云用普通 alpha 混合（才能显出灰烟的体积感）
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if add_blend else BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.billboard_keep_scale = true
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = _make_glow_texture()
	mat.disable_receive_shadows = true
	qm.material = mat
	p.draw_pass_1 = qm
	var r := reach * 8.0
	p.visibility_aabb = AABB(Vector3.ONE * -r, Vector3.ONE * r * 2.0)
	add_child(p)
	return p


## 放射状软光斑（程序生成）
func _make_glow_texture() -> Texture2D:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var c := Vector2(size * 0.5, size * 0.5)
	for y in range(size):
		for x in range(size):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c) / (size * 0.5)
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	return ImageTexture.create_from_image(img)
extends Node
## 草的风 + 交互桥（自动加载为 Wind）。
##
## 统一管理三种草：
##   1) 本插件导出的草      -> blend_alpha.gdshader    （uniform: wind_* / player_*）
##   2) SimpleGrassTextured -> grass.gdshaderinc       （uniform: sgt_wind_* / sgt_player_*）
##   3) 植被（树/灌木）      -> 由 Weather 自己驱动，本脚本不碰
##
## ★★ 为什么全部走「逐材质 uniform」，而不用全局着色器参数 ★★
##   scripts/world/weather.gd L191-194 与 assets/shaders/vegetation_wind.gdshader L14 已实测写明：
##   Godot 4.7 运行时下 RenderingServer.global_shader_parameter_* 是坏的 ——
##   get_list() 恒为空、set() 被静默忽略、顶点阶段永远拿 project.godot 的默认值。
##
## ★★ 为什么本脚本自己写风参数，而不是只挂给 Weather ★★
##   Weather.bind_world() 里有 _wind_materials.clear()（weather.gd L100），
##   而 main.gd 是「世界搭好之后」才调 bind_world 的 —— 早先注册进去的草材质会被清掉，
##   表现就是「按 V 换天气，草一点反应都没有」。所以这里每帧自己写，不依赖那个列表。
##
## ★★ 倒伏只由「移动」驱动 ★★
##   站着不动时 player_move = 0 -> 草自动回弹，不会出现「出生点周围一圈草一直倒着」。

@export var enabled := true
## 玩家节点。留空会自动找（分组 "player" -> 按名字含 player 的节点）
@export var player_path: NodePath
@export var player_radius := 0.75      ## 踩踏影响半径
@export var player_bend := 0.55        ## 下压强度
@export var player_spread := 0.30      ## 左右分开力度
@export var move_ref_speed := 3.0      ## 多少米/秒算全速（超过按满算）
## ★ 站着不动时也**持续保持**的一个分开量：身体把草撑开着，不会完全回弹
@export var stand_bend := 0.35
## ★ 站着时把影响半径缩小到多少（只影响紧贴身体那一圈，走路时恢复全半径）
@export var stand_radius_scale := 0.60
@export var move_smooth := 8.0         ## 移动量的平滑速度（越大越跟手）
## 找不到 Weather 时的兜底风
@export var fallback_wind := 0.18
@export var fallback_gust := 0.15
@export var fallback_turbulence := 0.30
@export var fallback_speed := 1.4
@export var fallback_direction := Vector2(1.0, 0.0)
@export var scan_interval := 0.5

## ★ 当前风（供火焰/其他 VFX 读取，不必去翻材质）。每次写材质前同步更新。
var cur_dir := Vector2(1.0, 0.0)
var cur_strength := 0.18
var cur_gust := 0.15
var cur_turbulence := 0.30
var cur_speed := 1.4

var _registered := 0
var _scan_timer := 0.0
var _mats_ours: Array[ShaderMaterial] = []
var _mats_sgt: Array[ShaderMaterial] = []
var _seen := {}
var _movement := Vector3.ZERO
var _player: Node3D = null
var _player_prev := Vector3.ZERO
var _player_fwd := Vector3(0.0, 0.0, -1.0)
## 平滑后的移动量 0..1（站着不动 -> 0 -> 草回弹）
var _move_amt := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_scan()


func _process(delta: float) -> void:
	if not enabled:
		return
	_scan_timer += delta
	if _scan_timer >= scan_interval:
		_scan_timer = 0.0
		_scan()
	var p := _find_player()
	var ppos := Vector3(0.0, -100000.0, 0.0)
	var pmov := Vector3.ZERO
	if p != null:
		ppos = p.global_position
		var step := ppos - _player_prev
		step.y = 0.0
		if delta > 0.0001:
			var spd := step.length() / delta
			var target := clampf(spd / maxf(0.01, move_ref_speed), 0.0, 1.0)
			# 指数平滑：起步和停下都有过渡，不会"啪"地弹开/回正
			_move_amt = lerpf(_move_amt, target, clampf(delta * move_smooth, 0.0, 1.0))
		else:
			_move_amt = 0.0
		if not step.is_zero_approx():
			# 朝向优先用**速度方向**（更符合"往前走时草往两边分开"）
			var vf := step.normalized()
			_player_fwd = _player_fwd.lerp(vf, clampf(delta * 8.0, 0.0, 1.0)).normalized()
		pmov = step.limit_length(1.0)
		_player_prev = ppos
	else:
		_move_amt = lerpf(_move_amt, 0.0, clampf(delta * move_smooth, 0.0, 1.0))
	# 天气
	var w: Node = null
	if get_tree() != null:
		w = get_tree().root.get_node_or_null("Weather")
	if w != null:
		_apply_from_weather(w, delta, ppos, pmov)
	else:
		_apply_fallback(ppos, pmov)


# ---------------------------------------------------------------- 材质收集

func _scan() -> void:
	if get_tree() == null:
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var found := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			found += _take_from_mesh(n as MeshInstance3D)
		for c in n.get_children():
			stack.append(c)
	if found > 0:
		print("[Wind] 新增 %d 个受风材质（累计 %d ｜ SGT %d）" % [found, _registered, _mats_sgt.size()])


func _take_from_mesh(mi: MeshInstance3D) -> int:
	var got := 0
	if mi.material_override is ShaderMaterial:
		got += _register(mi.material_override as ShaderMaterial)
	if mi.mesh != null:
		for s in range(mi.mesh.get_surface_count()):
			var ov: Material = mi.get_surface_override_material(s)
			if ov is ShaderMaterial:
				got += _register(ov as ShaderMaterial)
			var sm: Material = mi.mesh.surface_get_material(s)
			if sm is ShaderMaterial:
				got += _register(sm as ShaderMaterial)
	return got


func _register(m: ShaderMaterial) -> int:
	if m == null or m.shader == null:
		return 0
	var path := String(m.shader.resource_path)
	# 我们的草：shader 现在住在 assets/shaders/grass_wind.gdshader（blend_alpha 是旧名，兼容保留）
	var is_ours := path.contains("grass_wind") or path.contains("blend_alpha")
	var is_sgt := path.contains("simplegrasstextured")
	if not (is_ours or is_sgt):
		return 0
	var id := m.get_instance_id()
	if _seen.has(id):
		return 0
	_seen[id] = true
	if is_sgt:
		_mats_sgt.append(m)
	else:
		_mats_ours.append(m)
	_registered += 1
	return 1


# ---------------------------------------------------------------- 玩家

func _find_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	if get_tree() == null:
		return null
	if not player_path.is_empty():
		var n := get_node_or_null(player_path)
		if n is Node3D:
			_player = n
			_player_prev = _player.global_position
			_player_fwd = -_player.global_transform.basis.z
			_player_fwd.y = 0.0
			_player_fwd = _player_fwd.normalized()
			return _player
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		_player = g
		_player_prev = _player.global_position
		_player_fwd = -_player.global_transform.basis.z
		_player_fwd.y = 0.0
		_player_fwd = _player_fwd.normalized()
		return _player
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n2: Node = stack.pop_back()
		if n2 == null:
			continue
		if n2 is Node3D and String(n2.name).to_lower().contains("player"):
			_player = n2 as Node3D
			_player_prev = _player.global_position
			_player_fwd = -_player.global_transform.basis.z
			_player_fwd.y = 0.0
			_player_fwd = _player_fwd.normalized()
			return _player
		for c in n2.get_children():
			stack.append(c)
	return null


# ---------------------------------------------------------------- 参数写入

func _apply_from_weather(w: Node, delta: float, ppos: Vector3, pmov: Vector3) -> void:
	var v: Variant = w.get("wind_dir")
	var dir2: Vector2 = v if v is Vector2 else Vector2(1.0, 0.0)
	var strength := float(w.get("wind"))
	var gust := float(w.get("wind_gust"))
	var turb := float(w.get("wind_turbulence"))
	var speed := float(w.get("wind_speed"))
	cur_dir = dir2
	cur_strength = strength
	cur_gust = gust
	cur_turbulence = turb
	cur_speed = speed
	_movement.x += dir2.x * speed * delta * 1.2
	_movement.z += dir2.y * speed * delta * 1.2
	_movement.y += delta * speed * 0.6
	_write_ours(dir2, strength, gust, turb, speed, ppos)
	_write_sgt(dir2, strength, gust, turb, ppos, pmov)


func _apply_fallback(ppos: Vector3, pmov: Vector3) -> void:
	var d := fallback_direction.normalized()
	cur_dir = d
	cur_strength = fallback_wind
	cur_gust = fallback_gust
	cur_turbulence = fallback_turbulence
	cur_speed = fallback_speed
	_movement.x += d.x * fallback_speed * 0.02
	_movement.z += d.y * fallback_speed * 0.02
	_write_ours(d, fallback_wind, fallback_gust, fallback_turbulence, fallback_speed, ppos)
	_write_sgt(d, fallback_wind, fallback_gust, fallback_turbulence, ppos, pmov)


## 我们导出的草：风参数 + 角色倒伏（自己写，不依赖 Weather 的材质列表）
func _write_ours(dir2: Vector2, strength: float, gust: float, turb: float, speed: float, ppos: Vector3) -> void:
	for m in _mats_ours:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("wind_direction", dir2)
		m.set_shader_parameter("wind_strength", strength)
		m.set_shader_parameter("wind_gust", gust)
		m.set_shader_parameter("wind_speed", speed)
		m.set_shader_parameter("wind_turbulence", turb)
		m.set_shader_parameter("player_pos", ppos)
		m.set_shader_parameter("player_forward", _player_fwd)
		m.set_shader_parameter("player_radius", player_radius)
		m.set_shader_parameter("player_bend", player_bend)
		m.set_shader_parameter("player_spread", player_spread)
		# ★ 站着也保持分开：取「站立基础量」和「移动量」的较大者
		var bend_amt := maxf(stand_bend, _move_amt)
		m.set_shader_parameter("player_move", bend_amt)
		# 站着时半径收小（只撑开贴身那一圈），走起来恢复全半径
		m.set_shader_parameter("player_radius", player_radius * lerpf(stand_radius_scale, 1.0, _move_amt))


## SimpleGrassTextured 的草：它自己的 singleton 写的是全局（运行时失效）-> 这里补上
func _write_sgt(dir2: Vector2, strength: float, gust: float, turb: float, ppos: Vector3, pmov: Vector3) -> void:
	if _mats_sgt.is_empty():
		return
	var dir3 := Vector3(dir2.x, 0.0, dir2.y).normalized()
	for m in _mats_sgt:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("sgt_wind_direction", dir3)
		m.set_shader_parameter("sgt_wind_strength", strength * (1.0 + gust))
		m.set_shader_parameter("sgt_wind_turbulence", turb)
		m.set_shader_parameter("sgt_wind_movement", _movement)
		m.set_shader_parameter("sgt_player_position", ppos)
		m.set_shader_parameter("sgt_player_mov", pmov)
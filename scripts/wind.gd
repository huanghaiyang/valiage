extends Node
## 草的风 + 交互桥（自动加载为 Wind）。
##
## 统一管理三种草：
##   1) 本插件导出的草      -> blend_alpha.gdshader   （uniform: wind_* / player_*）
##   2) SimpleGrassTextured -> grass.gdshaderinc      （uniform: sgt_wind_* / sgt_player_*）
##   3) 植被（树/灌木）      -> 由 Weather 自己驱动，本脚本不碰
##
## ★★ 为什么全部走"逐材质 uniform"，而不用全局着色器参数 ★★
##   scripts/world/weather.gd L191-194 与 assets/shaders/vegetation_wind.gdshader L14 已实测写明：
##   Godot 4.7 运行时下 RenderingServer.global_shader_parameter_* 是坏的 ——
##   get_list() 恒为空、set() 被静默忽略、顶点阶段永远拿 project.godot 的默认值。
##   SGT 自己的 singleton.gd 写的也是全局 -> 在运行时同样失效，所以这里全部改成写材质。
##
## 说明：SGT 的 sgt_normal_displacement / sgt_motion_texture 是它内部两个视口的纹理，
## 需要访问它的私有成员，且着色器给的是 hint_normal / hint_default_black 的安全默认值，
## 所以这里**不转发**这两个（视觉上只少一点点细节，不会出错）。

@export var enabled := true
## 玩家节点。留空会自动找（分组 "player" -> 按名字 "Player"）
@export var player_path: NodePath
@export var player_radius := 0.75      ## 踩踏影响半径
@export var player_bend := 0.55        ## 压弯强度（我们导出的草用）
## 找不到 Weather 时的兜底风
@export var fallback_wind := 0.18
@export var fallback_gust := 0.15
@export var fallback_turbulence := 0.30
@export var fallback_speed := 1.4
@export var fallback_direction := Vector2(1.0, 0.0)
@export var scan_interval := 0.5
@export var scan_max_tries := 40

var _registered := 0
var _tries := 0
var _scan_timer := 0.0
var _mats_ours: Array[ShaderMaterial] = []
var _mats_sgt: Array[ShaderMaterial] = []
var _seen := {}
var _movement := Vector3.ZERO
var _player: Node3D = null
var _player_prev := Vector3.ZERO


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_scan()


func _process(delta: float) -> void:
	if not enabled:
		return
	if _tries < scan_max_tries:
		_scan_timer += delta
		if _scan_timer >= scan_interval:
			_scan_timer = 0.0
			_scan()
	var p := _find_player()
	var ppos := Vector3(0.0, -100000.0, 0.0)
	var pmov := Vector3.ZERO
	if p != null:
		ppos = p.global_position
		pmov = (_player_prev - ppos).limit_length(1.0)
		_player_prev = ppos
	var w: Node = null
	if get_tree() != null:
		w = get_tree().root.get_node_or_null("Weather")
	if w != null:
		_apply_from_weather(w, delta, ppos, pmov)
	else:
		_apply_fallback(ppos, pmov)


# ---------------------------------------------------------------- 材质收集

func _scan() -> void:
	_tries += 1
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
		print("[Wind] 新增 %d 个受风材质（累计 %d ｜ 其中 SGT %d）" % [found, _registered, _mats_sgt.size()])


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
	var is_ours := path.contains("blend_alpha")
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
	# 我们导出的草：交给 Weather 写 wind_*（名字与 vegetation_wind.gdshader 一致）
	if is_ours and get_tree() != null:
		var w := get_tree().root.get_node_or_null("Weather")
		if w != null and w.has_method("add_wind_material"):
			w.call("add_wind_material", m)
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
			return _player
	# 分组
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		_player = g
		_player_prev = _player.global_position
		return _player
	# 兜底：按名字找
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n2: Node = stack.pop_back()
		if n2 == null:
			continue
		if n2 is Node3D and (String(n2.name).to_lower() == "player" or String(n2.name).to_lower().contains("player")):
			_player = n2 as Node3D
			_player_prev = _player.global_position
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
	# 风图案滚动：风越大滚得越快
	_movement.x += dir2.x * speed * delta * 1.2
	_movement.z += dir2.y * speed * delta * 1.2
	_movement.y += delta * speed * 0.6
	_write_sgt(dir2, strength, gust, turb, ppos, pmov)
	_write_ours(ppos)


func _apply_fallback(ppos: Vector3, pmov: Vector3) -> void:
	_movement.x += fallback_direction.x * fallback_speed * 0.02
	_movement.z += fallback_direction.y * fallback_speed * 0.02
	_write_sgt(fallback_direction, fallback_wind, fallback_gust, fallback_turbulence, ppos, pmov)
	_write_ours(ppos)


## SimpleGrassTextured 的那套名字（它自己的 singleton 写的是全局，运行时失效 -> 这里补上）
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
		# 玩家交互（SGT 的草被踩）
		m.set_shader_parameter("sgt_player_position", ppos)
		m.set_shader_parameter("sgt_player_mov", pmov)


## 我们导出的草：wind_* 由 Weather 写，这里只写踩踏交互
func _write_ours(ppos: Vector3) -> void:
	for m in _mats_ours:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("player_pos", ppos)
		m.set_shader_parameter("player_radius", player_radius)
		m.set_shader_parameter("player_bend", player_bend)
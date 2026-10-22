extends SceneTree
## Lead 用的视觉取证：把大樱花树放进一个空场景，固定风参数，在几个时间点截图。
## 用途：证明"树冠在动、树干底部基本不动"，并给最终报告留图。
## 运行（必须有真实渲染，不能 --headless）：
##   & 'D:\godot\Godot_v4.7.2-stable_win64_console.exe' --path . --script res://tests/lead_wind_visual.gd
## 产物：.runtime/wind_port/shots/t*.png + diff.json（像素差分统计）

const OUT_DIR := "res://.runtime/wind_port/shots/"
var TREE := "res://scenes/树/大樱花树/big_sakura_tree.tscn"
const SHOT_FRAMES := [30, 50, 70]

var _tree: Node3D
var _shoot_at := {}
var _frame := 0
var _busy := false
## --static：关掉风（用于"新旧着色器静态画面必须一致"的回归对照）
var _static := false
## 截图文件名前缀（--prefix=xxx）
var _prefix := ""
## 风力（米，fast-tree 的树梢顺风偏移量级）与相机位姿，可用命令行覆盖
var _force := 0.35
var _campos := Vector3(30.0, 16.0, 38.0)
var _lookat := Vector3(0.0, 12.0, 0.0)

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s == "--static":
			_static = true
		elif s.begins_with("--prefix="):
			_prefix = s.substr(9)
		elif s.begins_with("--force="):
			_force = s.substr(8).to_float()
		elif s.begins_with("--campos="):
			_campos = _vec3(s.substr(9))
		elif s.begins_with("--tree="):
			TREE = s.substr(7)
		elif s.begins_with("--lookat="):
			_lookat = _vec3(s.substr(9))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var root := Node3D.new()
	root.name = "ShotRoot"
	get_root().add_child(root)

	# 地形一样的深色底板，方便看树干底部
	var floor_mesh := PlaneMesh.new()
	floor_mesh.size = Vector2(120, 120)
	var floor := MeshInstance3D.new()
	floor.mesh = floor_mesh
	var fmat := StandardMaterial3D.new()
	fmat.albedo_color = Color(0.28, 0.34, 0.24)
	floor.material_override = fmat
	root.add_child(floor)

	var ps: PackedScene = load(TREE)
	_tree = ps.instantiate()
	_tree.name = "TestTree"
	root.add_child(_tree)

	var cam := Camera3D.new()
	cam.fov = 42.0
	cam.far = 400.0
	root.add_child(cam)
	cam.look_at_from_position(_campos, _lookat)
	cam.current = true

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, -35.0, 0.0)
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	root.add_child(sun)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.70, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.70, 0.80)
	env.ambient_light_energy = 1.0
	we.environment = env
	root.add_child(we)

	# 固定一份"看得清"的风，直接写材质（不依赖 WindSystem）
	if _static:
		_apply_wind_to_tree(0.0, Vector2(1.0, 0.0), 1.4, 0.0, 0.0)
		_set_wind_enabled(false)
	else:
		_apply_wind_to_tree(_force, Vector2(1.0, 0.0), 1.4, 0.15, 0.30)
	for f in SHOT_FRAMES:
		_shoot_at[f] = true
	print("[shot] ready, frames=", SHOT_FRAMES)

func _apply_wind_to_tree(force: float, dir2: Vector2, speed: float, gust: float, turb: float) -> void:
	var stack: Array = [_tree]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var mats: Array = []
			if mi.material_override is ShaderMaterial:
				mats.append(mi.material_override)
			if mi.mesh != null:
				for s in range(mi.mesh.get_surface_count()):
					var sm := mi.mesh.surface_get_material(s)
					if sm is ShaderMaterial and not mats.has(sm):
						mats.append(sm)
			for m in mats:
				var sh: ShaderMaterial = m
				sh.set_shader_parameter("wind_enabled", true)
				sh.set_shader_parameter("wind_force", force)
				sh.set_shader_parameter("wind_direction", dir2)
				sh.set_shader_parameter("wind_speed", speed)
				sh.set_shader_parameter("wind_gust", gust)
				sh.set_shader_parameter("wind_turbulence", turb)
				sh.set_shader_parameter("wind_frequency", 1.0)
				sh.set_shader_parameter("wind_gust_speed", 0.16)
				sh.set_shader_parameter("wind_spatial_scale", 0.22)
				sh.set_shader_parameter("wind_bias", 0.30)
				sh.set_shader_parameter("wind_flex_falloff", 1.5)
		for c in n.get_children():
			stack.append(c)

func _process(_delta: float) -> bool:
	_frame += 1
	if _shoot_at.has(_frame):
		_shoot_at.erase(_frame)
		var img := get_root().get_texture().get_image()
		var p := "%s%st_%03d.png" % [OUT_DIR, _prefix, _frame]
		var err := img.save_png(ProjectSettings.globalize_path(p))
		print("[shot] frame %d -> %s err=%d size=%s" % [_frame, p, err, str(img.get_size())])
	if _frame > 75:
		quit(0)
		return true
	return false


func _set_wind_enabled(on: bool) -> void:
	var stack: Array = [_tree]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var mats: Array = []
			if mi.material_override is ShaderMaterial:
				mats.append(mi.material_override)
			for m in mats:
				(m as ShaderMaterial).set_shader_parameter("wind_enabled", on)
		for c in n.get_children():
			stack.append(c)

func _vec3(s: String) -> Vector3:
	var p := s.split(",")
	if p.size() < 3:
		return Vector3.ZERO
	return Vector3(p[0].to_float(), p[1].to_float(), p[2].to_float())


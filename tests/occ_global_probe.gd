extends SceneTree
## 验证：Godot 4.7 运行时 RenderingServer.global_shader_parameter_set 到底生不生效
## （决定"把 occ_hole_alpha 默认值改成 1.0"会不会把游戏里的挖孔也弄没）。
##
## 跑法（windowed，真渲染）：
##   godot --path . --script res://tests/occ_global_probe.gd -- --prefix=base_
##   godot --path . --script res://tests/occ_global_probe.gd -- --prefix=alpha1_ --occ_alpha=1.0
##   godot --path . --script res://tests/occ_global_probe.gd -- --prefix=moved_ --occ_uv=0.25,0.30
## 产物：.runtime/wind_port/shots/<prefix>occ.png

const OUT_DIR := "res://.runtime/wind_port/shots/"
const TREE := "res://scenes/树/大樱花树/big_sakura_tree.tscn"

var _prefix := "probe_"
var _occ_alpha := -1.0
var _occ_uv := Vector2(-1, -1)
var _frame := 0
var _tree: Node3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--prefix="):
			_prefix = s.substr(9)
		elif s.begins_with("--occ_alpha="):
			_occ_alpha = s.substr(12).to_float()
		elif s.begins_with("--occ_uv="):
			var p := s.substr(9).split(",")
			if p.size() >= 2:
				_occ_uv = Vector2(p[0].to_float(), p[1].to_float())
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var root := Node3D.new()
	get_root().add_child(root)
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(120, 120)
	floor.mesh = pm
	root.add_child(floor)
	_tree = (load(TREE) as PackedScene).instantiate()
	root.add_child(_tree)
	var cam := Camera3D.new()
	cam.fov = 42.0
	root.add_child(cam)
	cam.look_at_from_position(Vector3(30, 16, 38), Vector3(0, 12, 0))
	cam.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_energy = 1.4
	root.add_child(sun)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.70, 0.86)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.70, 0.80)
	we.environment = env
	root.add_child(we)
	# 关掉风，只观察挖孔（避免帧间除了洞之外还有别的变化）
	_set_wind_enabled(false)
	print("[occ] prefix=%s occ_alpha=%s occ_uv=%s" % [_prefix, str(_occ_alpha), str(_occ_uv)])


func _process(_d: float) -> bool:
	_frame += 1
	# 每帧都写（模拟 camera_rig 的行为），验证 set() 是否真的生效
	if _occ_alpha >= 0.0:
		RenderingServer.global_shader_parameter_set("occ_hole_alpha", _occ_alpha)
	if _occ_uv.x >= 0.0:
		RenderingServer.global_shader_parameter_set("occ_player_uv", _occ_uv)
		RenderingServer.global_shader_parameter_set("occ_radius", 0.12)
	if _frame == 40:
		var img := get_root().get_texture().get_image()
		var p := "%s%socc.png" % [OUT_DIR, _prefix]
		img.save_png(ProjectSettings.globalize_path(p))
		print("[occ] shot -> %s" % p)
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

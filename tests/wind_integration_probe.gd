extends SceneTree
## 最终集成探针：加载真实 main.tscn，检查 WindSystem 把树风参数写进了那 3 个树材质，
## 并且数值随时间推进（证明"游戏里真的在摆"）。
## 用法：& godot --headless --path . --script res://tests/wind_integration_probe.gd

var _f := 0
var _rows: Array = []
var _leaf: ShaderMaterial
var _bark: ShaderMaterial
var _flower: ShaderMaterial
var _wind: Node

func _initialize() -> void:
	Engine.max_fps = 60
	var ps: PackedScene = load("res://scenes/main.tscn")
	var scene: Node = ps.instantiate()
	get_root().add_child(scene)
	current_scene = scene
	_leaf = load("res://scenes/树/大樱花树/_blend_mat_big_sakura_leaves.tres")
	_bark = load("res://scenes/树/大樱花树/_blend_mat_big_sakura_bark.tres")
	_flower = load("res://scenes/树/大樱花树/_blend_mat_big_sakura_flowers.tres")
	_wind = scene.get_node_or_null("WindSystem")

func _process(_d: float) -> bool:
	_f += 1
	if _f % 30 == 0 and _leaf != null:
		_rows.append([
			_s(_leaf.get_shader_parameter("wind_force")),
			_s(_bark.get_shader_parameter("wind_force")),
			_s(_flower.get_shader_parameter("wind_force")),
			_s(_leaf.get_shader_parameter("wind_strength")),
			_s(_leaf.get_shader_parameter("wind_speed")),
			str(_leaf.get_shader_parameter("wind_direction")),
			_s(_leaf.get_shader_parameter("wind_freq_scale")),
			_s(_leaf.get_shader_parameter("wind_variation")),
			_s(_leaf.get_shader_parameter("wind_sway_variation")),
		])
	if _f == 200:
		print("WIND node = %s ｜ tree_mats=%d" % [str(_wind), _wind._mats_tree.size() if _wind != null else -1])
		for i in range(_rows.size()):
			print("ROW %d leaf_f=%.4f bark_f=%.4f flower_f=%.4f strength=%.3f speed=%.2f dir=%s freq_scale=%.2f variation=%.2f sway_var=%.2f" % [
				i, _rows[i][0], _rows[i][1], _rows[i][2], _rows[i][3], _rows[i][4], _rows[i][5], _rows[i][6], _rows[i][7], _rows[i][8]])
		quit(0)
		return true
	return false

func _s(v: Variant) -> float:
	if v == null:
		return -1.0
	return float(v)


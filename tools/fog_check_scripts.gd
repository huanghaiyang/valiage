extends Node
## ============================================================================
## fog_check_scripts.gd —— 雾气相关文件"能不能加载"的最小自检
## ============================================================================
## 运行方式：编辑器里打开 tools/fog_check_scripts.tscn 按 F6（或 MCP project_run custom）。
##
## 为什么单独写一个：解析失败时 `load()` **仍然会返回一个 GDScript 对象**，
## 真正的判据是 `can_instantiate()`（本仓库 tools/check_parse.gd 头注释里也记着这条）。
## 而编辑器日志缓冲区经常只剩"陈旧错误"，看不出现在到底哪一行坏了。
##
## ★ 两条重要的运行经验（都踩过）：
##   1. **每帧只查一个文件、并且立刻打印结果**。原因：GDScript 解析错误会让当前进程
##      进入 debugger break（脚本就此停住），如果攒到最后统一打印，前面已经查好的结论
##      会一起丢掉，反而看不到"是哪个文件把进程打断的"。逐帧打印时，断点前的结果
##      全部已经写进日志，断在哪一条一目了然。
##   2. 前几帧不要输出：游戏的 stdout 日志助手要过一两帧才接上，在此之前打的字会丢。
##
## 覆盖：雾气脚本 / 测试套件 / 计算着色器 / 片元着色器。结束时打印汇总并 quit(0 / 1)。
## ============================================================================

## 待检查项：{kind, path}。kind: script | test | compute | fragment | dock
const SCRIPT_FILES := [
	"res://scripts/fx/fog_ns_reference.gd",
	"res://scripts/fx/fog_ns_gpu_probe.gd",
	"res://scripts/fx/fog_ns_solver.gd",
	"res://scripts/fx/fog_brush_field.gd",
	"res://scripts/fx/fog_field.gd",
	"res://tools/fog_field_verify.gd",
	"res://addons/fog_brush/fog_brush_plugin.gd",
]

## 面板脚本要**真的实例化并建一遍 UI**（编辑器里手搓控件的代码最容易写错 API，
## 而 EditorPlugin 本体在游戏进程里跑不起来，面板是唯一能在运行时验证的一半）。
const DOCK_FILES := [
	"res://addons/fog_brush/ui/fog_brush_dock.gd",
]

## 测试套件放在最后查：如果某个测试脚本把进程打断，前面的结果已经打出来了。
const TEST_FILES := [
	"res://tests/test_fog_ns_reference.gd",
	"res://tests/test_fog_brush_field.gd",
]

## ★ 检查器（Inspector）契约：这些属性必须**带 PROPERTY_USAGE_EDITOR** 出现在脚本的导出
##   属性表里 —— 否则美术在检查器里根本看不到它们。写属性时最容易犯的两个错就是
##   "漏了 @export"（普通 var 不进检查器）和"改了名字但忘了同步面板/文档"，
##   这条哨兵把第一个错变成红字。
const INSPECTOR_EXPECTED := {
	"res://scripts/fx/fog_field.gd": [
		"character_stir_enabled", "character_group", "character_swirl_mps",
		"character_swirl_radius_m", "character_carve", "character_swirl_ref_speed",
		"composite_base_floor", "base_relax", "density_dissipation",
		"vortex_visual_enabled", "vortex_visual_alpha", "vortex_visual_turns", "vortex_visual_spin_speed", "vortex_visual_height_m", "vortex_visual_radius_m", "vortex_visual_sharpness", "vortex_visual_wobble", "vortex_visual_dark", "vortex_visual_light",
	],
	"res://scripts/fx/fog_interactor.gd": ["vortex_spin_mps"],
}

## ★ 笔刷面板（addons/fog_brush 的坞面板）要跟检查器保持同一套旋钮：
##   面板控件与 FogField 属性**同名**是两边的契约（见 fog_brush_plugin.gd 的注释）。
const DOCK_EXPECTED_CONTROLS := [
	"character_stir_enabled", "character_swirl_mps", "character_swirl_radius_m",
	"character_carve", "character_swirl_ref_speed", "character_group",
		"composite_base_floor", "base_relax", "density_dissipation",
		"vortex_visual_enabled", "vortex_visual_alpha", "vortex_visual_turns", "vortex_visual_spin_speed", "vortex_visual_height_m", "vortex_visual_radius_m", "vortex_visual_sharpness", "vortex_visual_wobble", "vortex_visual_dark", "vortex_visual_light",
]

const COMPUTE_SHADERS := [
	"res://assets/shaders/fog_ns/probe_write.glsl",
]

const FRAGMENT_SHADERS := [
	"res://assets/shaders/fog_ns/ns_advect_velocity.gdshader",
	"res://assets/shaders/fog_ns/ns_curl.gdshader",
	"res://assets/shaders/fog_ns/ns_vorticity.gdshader",
	"res://assets/shaders/fog_ns/ns_divergence.gdshader",
	"res://assets/shaders/fog_ns/ns_jacobi.gdshader",
	"res://assets/shaders/fog_ns/ns_gradient.gdshader",
	"res://assets/shaders/fog_ns/ns_advect_density.gdshader",
	"res://assets/shaders/fog_ns/ns_composite.gdshader",
	"res://assets/shaders/fog_mist_volume.gdshader",
	"res://assets/shaders/fog_screen_volume.gdshader",
	"res://assets/shaders/fog_mist_particle_process.gdshader",
	"res://assets/shaders/fog_mist_particle_draw.gdshader",
]

## 开始逐项检查的帧号（等日志助手接上）。
const START_FRAME := 4

var _targets: Array = []
var _index := 0
var _frames := 0
var _pass := 0
var _fail := 0
var _skipped := 0
var _running := false


func _ready() -> void:
	_build_targets()


func _build_targets() -> void:
	for path in SCRIPT_FILES:
		_targets.append({"kind": "script", "path": path})
	for path in DOCK_FILES:
		_targets.append({"kind": "dock", "path": path})
	for path in INSPECTOR_EXPECTED.keys():
		_targets.append({"kind": "inspector", "path": path})
	for path in COMPUTE_SHADERS:
		_targets.append({"kind": "compute", "path": path})
	for path in FRAGMENT_SHADERS:
		_targets.append({"kind": "fragment", "path": path})
	for path in TEST_FILES:
		_targets.append({"kind": "test", "path": path})


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < START_FRAME:
		return
	if not _running:
		_running = true
		print("=========== 雾气文件加载自检 ===========")

	if _index >= _targets.size():
		print("通过 %d  |  失败 %d  |  跳过（尚未实现）%d" % [_pass, _fail, _skipped])
		get_tree().quit(0 if _fail == 0 else 1)
		return

	var target: Dictionary = _targets[_index]
	_index += 1
	var kind := str(target["kind"])
	var path := str(target["path"])
	match kind:
		"script":
			_check_script(path, false)
		"test":
			_check_script(path, true)
		"dock":
			_check_dock(path)
		"inspector":
			_check_inspector(path)
		"compute":
			_check_compute_shader(path)
		"fragment":
			_check_fragment_shader(path)


## 实例化面板并检查它真的把控件建出来了。
## 为什么值得单独做：编辑器插件的 UI 是手写代码堆出来的（Label/SpinBox/Slider +
## 信号连接），写错一个 API 在编辑器里表现为"插件加载失败/面板空白"，
## 而这种错误在游戏进程里实例化一次就能立刻暴露出来。
func _check_dock(path: String) -> void:
	if not ResourceLoader.exists(path):
		_skipped += 1
		print("  [SKIP] %s（尚未实现）" % path)
		return
	var script := load(path) as GDScript
	if script == null or not script.can_instantiate():
		_ck("%s 可实例化" % path, false, "脚本解析失败")
		return
	var dock: Control = script.new() as Control
	if dock == null:
		_ck("%s 是 Control 子类" % path, false, "实例化失败或类型不对")
		return
	add_child(dock)
	# 手动触发 _ready（本检查脚本没有等帧，直接调最稳）
	dock.call("_ready")

	var required := ["_enable_check", "_mode_option", "_radius_spin", "_strength_slider",
			"_hardness_slider", "_resolution_spin", "_status_label"]
	var missing: Array[String] = []
	for name in required:
		if dock.get(name) == null:
			missing.append(name)
	_ck("%s 面板控件全部建出来了" % path, missing.is_empty(),
			"缺少：%s" % str(missing) if not missing.is_empty() else "控件齐全")

	# 关键信号必须存在（插件靠它们通信）
	var signals := ["brush_enabled_changed", "mode_changed", "params_changed",
			"clear_requested", "fill_requested", "export_requested", "import_requested",
			"rebuild_requested", "refresh_requested", "fog_param_changed", "fog_toggle_changed"]
	var missing_signals: Array[String] = []
	for signal_name in signals:
		if not dock.has_signal(signal_name):
			missing_signals.append(signal_name)
	_ck("%s 面板信号齐全" % path, missing_signals.is_empty(),
			"缺少：%s" % str(missing_signals) if not missing_signals.is_empty() else "%d 个信号" % signals.size())

	# ★ 角色涡流那几个旋钮必须真的在面板上（否则"检查器里有、面板里没有"，
	#   而本项目的调参入口就是这块面板）。
	var controls = dock.get("_fog_controls")
	var missing_knobs: Array[String] = []
	for param_name in DOCK_EXPECTED_CONTROLS:
		if controls == null or not (controls as Dictionary).has(param_name):
			missing_knobs.append(param_name)
	_ck("%s 角色涡流旋钮都在面板上" % path, missing_knobs.is_empty(),
			"缺少：%s" % str(missing_knobs) if not missing_knobs.is_empty() else "%d 个旋钮" % DOCK_EXPECTED_CONTROLS.size())

	dock.queue_free()


## 检查器契约：脚本里必须存在这些**导出**属性（带 PROPERTY_USAGE_EDITOR）。
## ★ 为什么能这么查：`get_script_property_list()` 返回的正是编辑器用来填检查器的那张表，
##   `@export` 会给属性打上 PROPERTY_USAGE_EDITOR；写漏 @export 的普通 var 不会带这个标记。
func _check_inspector(path: String) -> void:
	if not ResourceLoader.exists(path):
		_skipped += 1
		print("  [SKIP] %s（尚未实现）" % path)
		return
	var script := load(path) as GDScript
	if script == null or not script.can_instantiate():
		_ck("%s 可实例化（检查器属性表来自脚本）" % path, false, "脚本解析失败")
		return
	var editable := {}
	for prop in script.get_script_property_list():
		if int(prop["usage"]) & PROPERTY_USAGE_EDITOR:
			editable[String(prop["name"])] = true
	var expected: Array = INSPECTOR_EXPECTED[path]
	var missing: Array[String] = []
	for prop_name in expected:
		if not editable.has(prop_name):
			missing.append(prop_name)
	_ck("%s 的新属性出现在检查器里" % path, missing.is_empty(),
			"缺少 @export：%s" % str(missing) if not missing.is_empty()
			else "%d 个属性可见（共 %d 个可编辑）" % [expected.size(), editable.size()])


func _ck(label: String, ok: bool, extra: String = "") -> void:
	print("%s%s%s" % ["  [OK]   " if ok else "  [FAIL] ", label,
			("  -> " + extra) if extra != "" else ""])
	if ok:
		_pass += 1
	else:
		_fail += 1


func _check_script(path: String, require_instantiable: bool) -> void:
	if not ResourceLoader.exists(path):
		_skipped += 1
		print("  [SKIP] %s（尚未实现）" % path)
		return
	var script := load(path) as GDScript
	if script == null:
		_ck("%s 能加载" % path, false, "load() 返回 null")
		return
	# ★ 解析失败也会返回非 null 对象，所以必须看 can_instantiate()。
	if require_instantiable:
		var ok := script.can_instantiate()
		_ck("%s 可实例化" % path, ok, "" if ok else "can_instantiate()=false（脚本解析失败）")
	else:
		_ck("%s 能加载" % path, true, "can_instantiate()=%s" % script.can_instantiate())


func _check_compute_shader(path: String) -> void:
	if not ResourceLoader.exists(path):
		_skipped += 1
		print("  [SKIP] %s（尚未实现）" % path)
		return
	var file := load(path) as RDShaderFile
	if file == null:
		_ck("%s 能加载为 RDShaderFile" % path, false, "load() 返回 null")
		return
	var spirv := file.get_spirv()
	var error := ""
	if spirv != null:
		error = str(spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE))
	_ck("%s 编译通过" % path, spirv != null and error == "", error if error != "" else "SPIR-V OK")


## 片元着色器的**编译是否通过**没有可靠的脚本 API 可查（Shader 上没有参数列表方法，
## ShaderMaterial.get_shader_uniform_list() 对失败编译也返回非空），所以这里做两件能自动判定的事：
##   ① 资源能加载；
##   ② 源码里每个 `#include "..."` 的目标都存在（include 找不到是失败率最高的一种改动）
## 真正的编译结果请看本次运行的日志：出现 `Shader compilation failed.` 就是失败
## （日志里会直接给出文件名 + 出错行）。
func _check_fragment_shader(path: String) -> void:
	if not ResourceLoader.exists(path):
		_skipped += 1
		print("  [SKIP] %s（尚未实现）" % path)
		return
	var shader := load(path) as Shader
	if shader == null:
		_ck("%s 能加载为 Shader" % path, false, "load() 返回 null")
		return

	var source := FileAccess.get_file_as_string(path)
	var missing: Array[String] = []
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("#include"):
			var target := trimmed.replace("#include", "").strip_edges().replace("\"", "")
			# ★ include 允许写成**相对路径**（本仓库 sky_3d 就是这么写的：`#include "Common.gdshaderinc"`）。
			#   相对路径要按"当前着色器所在目录"解析，否则会误报"include 目标不存在"。
			if not target.begins_with("res://") and not target.begins_with("user://"):
				target = path.get_base_dir().path_join(target)
			if not ResourceLoader.exists(target) and not FileAccess.file_exists(target):
				missing.append(target)
	_ck("%s include 目标都存在" % path, missing.is_empty(),
			"缺少：%s" % str(missing) if not missing.is_empty() else "载入 + include 检查通过")

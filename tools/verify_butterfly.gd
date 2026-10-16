extends SceneTree
## 蝴蝶插件无头自校验 —— 跑 tests/test_butterfly_swarm.gd 并打印逐条结果 + 退出码。
##
## 用法：
##   D:\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path D:\sgames\CozyVale ^
##       --script res://tools/verify_butterfly.gd
##
## 退出码：0 = 全绿（skipped 不算失败）；1 = 有失败 / 套件加载不了。
##
## ★ 为什么不复用 addons/godot_ai/testing/test_runner.gd
##   它依赖 McpConnection / McpLogBuffer 这类"只在编辑器进程里存在"的单例，
##   在 `--script` 起的纯 SceneTree 进程里实例化会失败。
##   这里只复刻对本套件有意义的那部分语义：
##     reset -> setup -> 调用 test_* -> teardown -> 释放 track 的对象
##     + 用 ScriptErrorCapture 把 SCRIPT ERROR 判为该测试失败（引擎级 ERROR 不算，
##       例如树外 look_at 会刷 "Node not inside tree"，那是环境噪音）
##     + "0 断言 = 失败"（防空跑，与 McpTestRunner 一致）
##
## 说明：仓库里 `user://logs` 打不开之类的 ERROR 与本任务无关（环境噪音），
##       结论只看 SCRIPT ERROR / 解析错误 / 断言。

const SUITE_PATH := "res://tests/test_butterfly_swarm.gd"
## 直接复用插件自带的 SCRIPT ERROR 捕获器（extends Logger，无 class_name）
const ScriptErrorCapture := preload("res://addons/godot_ai/testing/script_error_capture.gd")

var _pass := 0
var _fail := 0
var _skip := 0
var _assert_total := 0
var _rows: Array = []
var _failures: Array = []
var _capture = null
var _ran := false


## ★ 为什么测试跑在**首帧 _process** 而不是 _initialize()：
##   实测（.runtime/butterfly_probe7.gd）在 `--script` 起的 SceneTree 里，_initialize() 阶段
##   root 自己还没进场景树 —— 此时 root.add_child(x) 会让 x 的 is_inside_tree() 仍为 false、
##   get_tree() 返回 null。蝴蝶的 advance() 会因此每步刷两条
##   "Node not inside tree" ERROR（一次 600 步的实测刷了 6 万多行日志），
##   而且树内/树外的行为差异会让断言失真。等到首帧 _process，root 已进树，一切正常
##   （实测 60 步 0 条 ERROR，且 wind_now() 能读到 Wind 自动加载）。
func _initialize() -> void:
	print("==================== 蝴蝶插件无头自校验 ====================")
	print("Godot %s ｜ project=%s" % [Engine.get_version_info().get("string", "?"),
			ProjectSettings.globalize_path("res://")])


func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	var code := _run_all()
	print("EXIT=%d" % code)
	quit(code)
	return true


func _run_all() -> int:
	if not is_instance_valid(root):
		print("[FATAL] 首帧仍是空的 root，无法跑测试")
		return 1
	var script := load(SUITE_PATH) as GDScript
	if script == null:
		print("[FATAL] 无法加载 %s（解析错误？）" % SUITE_PATH)
		return 1
	var suite: McpTestSuite = script.new()
	if suite == null:
		print("[FATAL] 套件实例化失败：%s" % SUITE_PATH)
		return 1
	print("suite_name = %s ｜ 套件 %s" % [suite.suite_name(), SUITE_PATH])
	print("--------------------------------------------------------------")

	_capture = ScriptErrorCapture.new()
	OS.add_logger(_capture)

	var methods: Array = []
	for m in suite.get_method_list():
		var n := String(m.get("name", ""))
		if n.begins_with("test_"):
			methods.append(n)
	methods.sort()

	var t_all := Time.get_ticks_msec()
	for name in methods:
		_run_one(suite, String(name))
	var elapsed := Time.get_ticks_msec() - t_all

	OS.remove_logger(_capture)
	_capture = null
	_print_summary(elapsed)
	return 1 if _fail > 0 else 0


## 跑一条测试，语义与 addons/godot_ai/testing/test_runner.gd 的 _run_one_test 对齐。
func _run_one(suite: McpTestSuite, name: String) -> void:
	suite._reset()
	suite.setup()
	var t0 := Time.get_ticks_msec()
	_capture.begin_capture()
	suite.call(name)
	var script_errors: PackedStringArray = _capture.end_capture()
	var ms := Time.get_ticks_msec() - t0
	suite.teardown()
	suite._free_tracked()

	var status := "PASS"
	var detail := suite._message
	if not script_errors.is_empty():
		# SCRIPT ERROR 优先于断言结果：脚本崩了，断言没跑完也不算通过
		status = "FAIL"
		detail = "SCRIPT ERROR：%s" % "; ".join(script_errors)
		if suite._failed:
			detail += "  （断言先失败：%s）" % suite._message
	elif suite._failed:
		status = "FAIL"
	elif suite._skipped:
		status = "SKIP"
		detail = suite._skip_reason
	elif suite._assertion_count == 0:
		# 与 McpTestRunner 一致：0 断言的"通过"是假通过
		status = "FAIL"
		detail = "测试体一条断言都没执行（疑似空跑）"

	_assert_total += suite._assertion_count
	if status == "PASS":
		_pass += 1
	elif status == "SKIP":
		_skip += 1
	else:
		_fail += 1
		_failures.append("%s :: %s" % [name, detail])

	var row := "%-4s  %-52s 断言 %3d  %5d ms" % [status, name, suite._assertion_count, ms]
	_rows.append(row)
	print(row)
	if status == "FAIL":
		print("        └─ %s" % detail)


func _print_summary(elapsed_ms: int) -> void:
	print("--------------------------------------------------------------")
	print("逐条结果：")
	for r in _rows:
		print("  " + String(r))
	print("--------------------------------------------------------------")
	print("passed=%d  failed=%d  skipped=%d  total=%d  assertions=%d  duration_ms=%d"
			% [_pass, _fail, _skip, _rows.size(), _assert_total, elapsed_ms])
	if not _failures.is_empty():
		print("失败明细：")
		for f in _failures:
			print("  ✗ %s" % String(f))
	print("结论：%s" % ("全绿 ✔" if _fail == 0 else "有失败 ✘"))
	print("==============================================================")

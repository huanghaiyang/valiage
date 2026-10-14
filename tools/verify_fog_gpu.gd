extends SceneTree
## ============================================================================
## verify_fog_gpu.gd —— GPU 自检的**命令行入口**（给使用者 / CI 用）
## ============================================================================
## 运行方式（必须是普通窗口进程，不能用 --headless：无头模式下没有 Vulkan 设备）：
##   <Godot 可执行文件> --path <项目目录> --script res://tools/verify_fog_gpu.gd
## 退出码：0 = 全通过，1 = 有失败。
##
## 逻辑本体在 scripts/fx/fog_ns_gpu_probe.gd；本文件只是把结果打到 stdout 并
## 决定退出码。若你只想快速看结果，也可以在编辑器里跑 tools/fog_gpu_verify.tscn
## （那个版本额外验证 Texture2DRD 显示并截图）。
## ============================================================================

const PROBE := preload("res://scripts/fx/fog_ns_gpu_probe.gd")

var _done := false


func _initialize() -> void:
	print("=========== 雾气流体 GPU 自检（命令行版） ===========")
	var pass_count := 0
	var fail_count := 0

	var env := PROBE.check_environment()
	pass_count += int(env["pass"])
	fail_count += int(env["fail"])
	for line in env["lines"]:
		print(line)

	if bool(env["ok"]):
		var compute := PROBE.run_compute_probe(env["rd"])
		pass_count += int(compute["pass"])
		fail_count += int(compute["fail"])
		for line in compute["lines"]:
			print(line)

	print("通过 %d  |  失败 %d" % [pass_count, fail_count])
	_done = true
	quit(0 if fail_count == 0 else 1)


func _process(_delta: float) -> bool:
	return _done

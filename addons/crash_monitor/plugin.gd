@tool
extends EditorPlugin
## 崩溃记录器：持续写心跳状态 + 捕获全部日志，崩溃后下次启动生成报告。
## 报告位置 user://crash_monitor/（Windows: %APPDATA%\Godot\app_userdata\Cozy Vale\crash_monitor）——
## 这个路径命令行可以直接读，所以 agent 也能用。

const CrashLogger := preload("res://addons/crash_monitor/crash_logger.gd")
const CrashState := preload("res://addons/crash_monitor/crash_state.gd")

const HEARTBEAT_SEC := 5.0
const MENU_ITEM := "打开崩溃记录目录"

var _logger: Logger = null
var _state: RefCounted = null
var _timer: Timer = null
var _seq := 0


func _enter_tree() -> void:
	_state = CrashState.new()
	_logger = CrashLogger.new()
	if OS.has_method("add_logger"):
		OS.add_logger(_logger)

	# ① 先判定上次是否非正常退出
	var prev: Dictionary = _state.read_state()
	if CrashState.is_dirty(prev, OS.get_process_id()):
		var r: Dictionary = _state.write_report(prev, _logger)
		print("[崩溃记录器] ⚠ 上次会话未正常退出（疑似崩溃）")
		print("[崩溃记录器]   报告：%s" % str(r["txt"]))
		print("[崩溃记录器]   崩溃前：场景=%s ｜ 播放中=%s ｜ 正在扫描导入=%s ｜ 内存=%s MB" % [
				str(prev.get("scene", "?")), str(prev.get("playing", "?")),
				str(prev.get("scanning", "?")), str(prev.get("mem_mb", "?"))])
	else:
		print("[崩溃记录器] 上次会话正常退出 ✓")

	# ② 心跳（5 秒一次，崩溃时留下的就是最后一条）
	_timer = Timer.new()
	_timer.wait_time = HEARTBEAT_SEC
	_timer.autostart = true
	_timer.timeout.connect(_beat)
	add_child(_timer)
	_beat(false)
	add_tool_menu_item(MENU_ITEM, _open_dir)


func _exit_tree() -> void:
	# 走到这里 = 正常停用/退出 → 打上标记，下次启动就不会误报崩溃
	_beat(true)
	remove_tool_menu_item(MENU_ITEM)
	if _timer != null:
		_timer.queue_free()
		_timer = null
	if _logger != null and OS.has_method("remove_logger"):
		OS.remove_logger(_logger)
		_logger = null


func _notification(what: int) -> void:
	# 关窗口时也补一次"干净"标记（多一道保险）
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_beat(true)


## 注意：默认值必须给 —— 这个函数同时被 Timer.timeout 调用（**0 个参数**），
## 没有默认值时每次心跳都报 "Method expected 1 argument(s), but called with 0"，
## 而且心跳会**静默失效**（实测踩到）。
func _beat(clean := false) -> void:
	if _state == null:
		return
	_seq += 1
	var st: Dictionary = CrashState.collect({"seq": _seq, "clean_exit": clean})
	_state.write_state(st)


func _open_dir() -> void:
	OS.shell_open(ProjectSettings.globalize_path("user://crash_monitor"))
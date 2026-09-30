@tool
extends Logger
## 捕获引擎所有日志（含 push_error），带时间戳存进环形缓冲并落盘。
## 崩溃时进程直接死掉，来不及写任何东西 —— 所以必须**持续 flush**。

const MAX_RING := 400          ## 内存里保留最近多少条
const MAX_LOG_BYTES := 2 * 1024 * 1024   ## session.log 超过就轮转

var ring: Array = []           ## [{t, err, msg}]
var log_path := "user://crash_monitor/session.log"
var _f: FileAccess = null


func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://crash_monitor"))
	_open_log()


## 打开日志文件。
## 坑：FileAccess.open(path, READ_WRITE) 对**不存在的文件**会返回 null ——
## 于是日志一个字都写不进去，崩溃报告里也就没有日志尾巴（实测踩到）。
## 所以不存在时用 WRITE 新建，存在时才用 READ_WRITE 追加。
func _open_log() -> void:
	var abs := ProjectSettings.globalize_path(log_path)
	if FileAccess.file_exists(abs):
		_f = FileAccess.open(log_path, FileAccess.READ_WRITE)
		if _f != null:
			_f.seek_end()
	else:
		_f = FileAccess.open(log_path, FileAccess.WRITE)
	if _f == null:
		push_warning("[崩溃记录器] 无法打开日志文件：%s" % abs)


func _log_message(message: String, error: bool) -> void:
	var entry := {"t": Time.get_time_string_from_system(), "err": error, "msg": message}
	ring.append(entry)
	while ring.size() > MAX_RING:
		ring.pop_front()
	if _f != null:
		_f.store_line("[%s] %s%s" % [entry["t"], "ERR " if error else "", message])
		_f.flush()                       # 关键：崩溃前必须已落盘
		if _f.get_length() > MAX_LOG_BYTES:
			_rotate()


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	var msg := "%s (%s:%d) code=%s rationale=%s" % [function, file, line, code, rationale]
	_log_message(msg, true)
	for bt in script_backtraces:
		_log_message("    backtrace: %s" % str(bt), true)


func _rotate() -> void:
	var old := log_path + ".1"
	if FileAccess.file_exists(ProjectSettings.globalize_path(old)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(old))
	if _f != null:
		_f.close()
	_f = null
	DirAccess.rename_absolute(ProjectSettings.globalize_path(log_path), ProjectSettings.globalize_path(old))
	_open_log()


## 最近的日志文本（给报告用）
func tail(n: int) -> PackedStringArray:
	var out := PackedStringArray()
	var from := maxi(0, ring.size() - n)
	for i in range(from, ring.size()):
		var e: Dictionary = ring[i]
		out.append("[%s] %s%s" % [e["t"], "ERR " if e["err"] else "", e["msg"]])
	return out


func error_count() -> int:
	var n := 0
	for e in ring:
		if bool((e as Dictionary)["err"]):
			n += 1
	return n
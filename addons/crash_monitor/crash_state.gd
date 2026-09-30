@tool
extends RefCounted
## 状态采集 + 崩溃判定 + 报告生成。纯逻辑部分（判定/JSON/裁剪）可单测。

const DIR := "user://crash_monitor"
const STATE := DIR + "/last_state.json"
const MAX_REPORTS := 10

var dir_abs := ""


func _init() -> void:
	use_dir(DIR)


## 切换记录目录（测试用独立子目录，避免污染真实崩溃报告）
func use_dir(rel: String) -> void:
	dir_abs = ProjectSettings.globalize_path(rel)
	DirAccess.make_dir_recursive_absolute(dir_abs)


## 采集当前状态（心跳内容）
static func collect(extra: Dictionary = {}) -> Dictionary:
	var d := {
		"ts": Time.get_datetime_string_from_system(),
		"unix": int(Time.get_unix_time_from_system()),
		"pid": OS.get_process_id(),
		"engine": Engine.get_version_info().get("string", ""),
		"scene": "",
		"playing": false,
		"scanning": false,
		"mem_mb": int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"fps": int(Engine.get_frames_per_second()),
		"clean_exit": false,
		"seq": 0,
	}
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		d["scene"] = root.scene_file_path if root.scene_file_path != "" else root.name
	# 不同版本的 EditorInterface 播放状态方法名不同（4.7.2 实测没有 is_playing），
	# 所以用动态调用 + 逐个试探，避免版本升级直接把插件写死。
	d["playing"] = false
	for m in ["is_playing", "is_playing_scene", "is_scene_playing", "get_playing_scene"]:
		if EditorInterface.has_method(m):
			var v = EditorInterface.call(m)
			d["playing"] = (v != null and v != "") if m == "get_playing_scene" else bool(v)
			break
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		d["scanning"] = fs.is_scanning()
	for k in extra:
		d[k] = extra[k]
	return d


## 原子写：先写 .tmp 再改名，避免崩溃时留下半个文件
func write_state(state: Dictionary) -> void:
	var tmp := dir_abs.path_join("last_state.json.tmp")
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(state, "  "))
	f.flush()
	f.close()
	var dst := dir_abs.path_join("last_state.json")
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(dst)
	DirAccess.rename_absolute(tmp, dst)


func read_state() -> Dictionary:
	var p := dir_abs.path_join("last_state.json")
	if not FileAccess.file_exists(p):
		return {}
	var t := FileAccess.get_file_as_string(p)
	var v = JSON.parse_string(t)
	return v if v is Dictionary else {}


## 上次是否非正常退出（没打 clean_exit 标记）
## 上次是否非正常退出。
## 关键守卫：如果记录里的 pid 就是**当前进程**，说明那是本进程自己（例如测试）
## 写下的中间态，而不是上一个会话 —— 绝不能误报成崩溃。
static func is_dirty(prev: Dictionary, current_pid := -1) -> bool:
	if prev.is_empty():
		return false            # 没有记录 = 第一次跑，不算崩溃
	if current_pid > 0 and int(prev.get("pid", -1)) == current_pid:
		return false
	return not bool(prev.get("clean_exit", false))


## 生成崩溃报告：JSON（给程序读）+ TXT（给人看）+ 日志尾巴
func write_report(prev: Dictionary, logger, note := "上次会话未正常退出（疑似崩溃）") -> Dictionary:
	var stamp := Time.get_datetime_string_from_system().replace(":", "").replace("-", "").replace(" ", "_")
	var base := dir_abs.path_join("crash_%s" % stamp)
	# 关键：**不能只取内存里的环形缓冲** —— 进程崩溃时它随进程一起消失，
	# 下次启动时环是空的，报告就只剩状态没有日志（实测踩到）。
	# 所以优先读磁盘上的 session.log 尾巴（那是持续 flush 过的）。
	var tail_lines := read_log_tail(200)
	if tail_lines.is_empty() and logger != null:
		tail_lines = Array(logger.tail(200))
	var rep := {
		"note": note,
		"detected_at": Time.get_datetime_string_from_system(),
		"last_state": prev,
		"recent_errors_in_ring": logger.error_count() if logger != null else -1,
		"log_tail": tail_lines,
	}
	# JSON
	var jf := FileAccess.open(base + ".json", FileAccess.WRITE)
	if jf != null:
		jf.store_string(JSON.stringify(rep, "  "))
		jf.flush()
		jf.close()
	# 人类可读 txt
	var tf := FileAccess.open(base + ".txt", FileAccess.WRITE)
	if tf != null:
		tf.store_line("=== Godot 崩溃报告 ===")
		tf.store_line("检测时间: %s" % rep["detected_at"])
		tf.store_line("说明: %s" % note)
		tf.store_line("")
		tf.store_line("--- 崩溃前最后状态 ---")
		for k in prev:
			tf.store_line("  %s = %s" % [k, str(prev[k])])
		tf.store_line("")
		tf.store_line("--- 日志尾部（最近 200 条）---")
		for line in Array(rep["log_tail"]):
			tf.store_line(str(line))
		tf.flush()
		tf.close()
	# 复制日志文件
	var lf := dir_abs.path_join("session.log")
	if FileAccess.file_exists(lf):
		DirAccess.copy_absolute(lf, base + ".log")
	_trim()
	return {"json": base + ".json", "txt": base + ".txt", "state": prev}


## 只保留最近 MAX_REPORTS 份报告
func _trim() -> void:
	var d := DirAccess.open(dir_abs)
	if d == null:
		return
	var by_stamp := {}
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if n.begins_with("crash_") and n.ends_with(".json"):
			by_stamp[n.trim_suffix(".json")] = true
		n = d.get_next()
	d.list_dir_end()
	var keys := by_stamp.keys()
	keys.sort()
	if keys.size() <= MAX_REPORTS:
		return
	for i in range(0, keys.size() - MAX_REPORTS):
		var stem: String = keys[i]
		for ext in [".json", ".txt", ".log"]:
			var p := dir_abs.path_join(stem + ext)
			if FileAccess.file_exists(p):
				DirAccess.remove_absolute(p)

## 读磁盘上 session.log 的尾部（崩溃报告真正有用的部分在这里）
func read_log_tail(n: int) -> Array:
	var p := dir_abs.path_join("session.log")
	if not FileAccess.file_exists(p):
		return []
	var all := FileAccess.get_file_as_string(p).split("\n")
	var out: Array = []
	var from := maxi(0, all.size() - n)
	for i in range(from, all.size()):
		if String(all[i]).strip_edges() != "":
			out.append(all[i])
	return out
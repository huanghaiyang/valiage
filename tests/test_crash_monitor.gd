@tool
extends McpTestSuite
## 崩溃记录器自检：状态采集 / 脏判定 / 报告生成 / 日志环形缓冲。

const STATE := "res://addons/crash_monitor/crash_state.gd"
const LOGGER := "res://addons/crash_monitor/crash_logger.gd"


func suite_name() -> String:
	return "crash_monitor"


func _load(path: String) -> GDScript:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func test_collect_and_roundtrip() -> void:
	var ss := _load(STATE)
	assert_true(ss != null, "状态脚本加载失败")
	if ss == null:
		return
	var st: Dictionary = ss.call("collect", {"seq": 7, "clean_exit": false})
	for key in ["ts", "unix", "pid", "engine", "scene", "playing", "scanning", "mem_mb", "clean_exit", "seq"]:
		assert_true(st.has(key), "状态缺少字段 %s" % key)
	print("[崩溃记录器] 当前状态：场景=%s ｜ 播放=%s ｜ 扫描中=%s ｜ 内存=%d MB ｜ 对象=%d" % [
			str(st["scene"]), str(st["playing"]), str(st["scanning"]), int(st["mem_mb"]), int(st["objects"])])
	assert_eq(int(st["seq"]), 7, "extra 字段没写进去")
	var inst: RefCounted = ss.new()
	inst.call("use_dir", "user://crash_monitor/_test")     # 独立子目录，别污染真报告
	inst.call("write_state", st)
	var back: Dictionary = inst.call("read_state")
	assert_eq(int(back.get("seq", -1)), 7, "状态写盘后读回不一致")
	assert_true(back.has("scene"), "读回的状态缺字段")


func test_dirty_detection() -> void:
	var ss := _load(STATE)
	if ss == null:
		return
	assert_true(not bool(ss.call("is_dirty", {})), "没有记录时不该算崩溃（首次运行）")
	assert_true(bool(ss.call("is_dirty", {"clean_exit": false})), "没打干净标记应判为崩溃")
	assert_true(not bool(ss.call("is_dirty", {"clean_exit": true})), "打了干净标记不该判为崩溃")
	# pid 守卫：记录里的 pid 就是当前进程 → 是本进程自己写的，不算崩溃
	var me := OS.get_process_id()
	assert_true(not bool(ss.call("is_dirty", {"clean_exit": false, "pid": me}, me)),
			"同一进程写下的状态不该判为崩溃（否则测试会污染出假崩溃报告）")
	assert_true(bool(ss.call("is_dirty", {"clean_exit": false, "pid": me + 1}, me)),
			"不同 pid 的未干净退出应当判为崩溃")
	print("[崩溃记录器] pid 守卫：本进程 pid=%d" % me)


func test_report_generation() -> void:
	var ss := _load(STATE)
	var ls := _load(LOGGER)
	if ss == null or ls == null:
		return
	var tlog_dir := "user://crash_monitor/_test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(tlog_dir))
	var tlog := tlog_dir + "/session.log"
	if FileAccess.file_exists(ProjectSettings.globalize_path(tlog)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tlog))
	var logger: Logger = ls.new()
	logger.log_path = tlog              # 隔离文件 ✓
	logger.call("_open_log")
	logger.call("_log_message", "模拟日志 1", false)
	logger.call("_log_message", "模拟错误 2", true)
	assert_true(int(logger.call("error_count")) >= 1, "错误计数不对")
	var tail: PackedStringArray = logger.call("tail", 10)
	assert_true(tail.size() >= 2, "日志尾巴条数不对")
	var joined := "\n".join(tail)
	assert_true(joined.contains("模拟日志 1"), "日志尾巴内容不对")
	print("[崩溃记录器] 环形缓冲 %d 条，其中错误 %d 条" % [tail.size(), int(logger.call("error_count"))])

	var inst: RefCounted = ss.new()
	inst.call("use_dir", "user://crash_monitor/_test")
	var prev := {"ts": "2026-09-30 12:00:00", "scene": "res://scenes/main.tscn",
			"playing": false, "scanning": true, "mem_mb": 4096, "clean_exit": false, "seq": 12}
	var r: Dictionary = inst.call("write_report", prev, logger)
	assert_true(FileAccess.file_exists(String(r["json"]) + ""), "JSON 报告没生成")
	assert_true(FileAccess.file_exists(String(r["txt"]) + ""), "TXT 报告没生成")
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(String(r["json"])))
	assert_true(parsed is Dictionary, "报告 JSON 解析失败")
	if parsed is Dictionary:
		assert_true((parsed as Dictionary).has("last_state"), "报告里没有 last_state")
		assert_true((parsed as Dictionary).has("log_tail"), "报告里没有 log_tail")
		var ls2: Dictionary = (parsed as Dictionary)["last_state"]
		assert_eq(String(ls2.get("scene", "")), "res://scenes/main.tscn", "报告里的场景不对")
	print("[崩溃记录器] 报告已生成：%s" % str(r["txt"]))
	# 回归：内存环形缓冲清空后，报告仍要能带上磁盘日志（崩溃时环必丢）
	logger.call("_log_message", "磁盘上才有的这一行", false)
	var fresh: RefCounted = ss.new()
	fresh.call("use_dir", "user://crash_monitor/_test")
	var r2: Dictionary = fresh.call("write_report", prev, logger)
	var parsed2 = JSON.parse_string(FileAccess.get_file_as_string(String(r2["json"])))
	if parsed2 is Dictionary:
		var tail2: Array = (parsed2 as Dictionary).get("log_tail", [])
		var joined2 := "\n".join(PackedStringArray(tail2.map(func(x): return str(x))))
		print("[崩溃记录器] 报告日志条数 = %d" % tail2.size())
		assert_true(tail2.size() > 0, "报告没带上任何日志（崩溃时环形缓冲必丢，必须读磁盘）")
		assert_true(joined2.contains("磁盘上才有的这一行"), "报告日志里没有刚写下的那行")


func test_plugin_methods_callable_from_signals() -> void:
	# 回归：Timer.timeout 调用时带 **0 个参数**。
	# 之前 _beat(clean: bool) 没有默认值 → 每次心跳都报错且**静默失效**（实测踩到）。
	var ps := ResourceLoader.load("res://addons/crash_monitor/plugin.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(ps is GDScript, "plugin.gd 不是 GDScript")
	if not (ps is GDScript):
		return
	var probe = (ps as GDScript).new()
	assert_true(probe != null, "plugin.gd 无法实例化")
	if probe == null:
		return
	var found := false
	for m in probe.get_method_list():
		if String(m["name"]) == "_beat":
			found = true
			var args: Array = m["args"]
			var defaults: Array = m["default_args"]
			print("[崩溃记录器] _beat 参数 %d 个，其中带默认值 %d 个" % [args.size(), defaults.size()])
			assert_eq(args.size(), defaults.size(), "_beat 的参数必须全部有默认值，否则 timeout 调用会报错")
	if not found:
		assert_true(false, "找不到 _beat 方法")
	probe.free()


func test_registered() -> void:
	var t := FileAccess.get_file_as_string("res://project.godot")
	assert_true(t.contains("crash_monitor/plugin.cfg"), "插件没注册进 project.godot")

func test_logger_actually_writes_to_disk() -> void:
	# 回归：日志必须真的**落盘**。
	# 之前用 FileAccess.open(path, READ_WRITE) 打开不存在的文件 → 返回 null →
	# 一个字都没写进去，崩溃报告里永远没有日志尾巴（实测踩到）。
	var ls := _load(LOGGER)
	var ss := _load(STATE)
	if ls == null or ss == null:
		return
	var probe_dir := "user://crash_monitor/_test"
	var test_log := probe_dir + "/session.log"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(probe_dir))
	var lg: Logger = ls.new()
	lg.log_path = test_log              # 用隔离文件：真实的 session.log 被插件独占着 ✗
	lg.call("_open_log")
	lg.call("_log_message", "落盘回归探针", false)
	lg = null                           # ★ 必须先放手：独占打开时，自己也能把自己挡住 ✗
	var abs := ProjectSettings.globalize_path(test_log)
	assert_true(FileAccess.file_exists(abs), "session.log 没被创建（说明文件打开方式不对）")
	var txt := FileAccess.get_file_as_string(abs) if FileAccess.file_exists(abs) else ""
	assert_true(txt.contains("落盘回归探针"), "日志没写进文件")

	# 报告必须能从磁盘读到它（即使内存环形缓冲是空的）
	var inst: RefCounted = ss.new()
	inst.call("use_dir", probe_dir)
	var tail: Array = inst.call("read_log_tail", 50)
	print("[崩溃记录器] read_log_tail 从磁盘读到 %d 条" % tail.size())
	var joined := "\n".join(PackedStringArray(tail.map(func(x): return str(x))))
	assert_true(joined.contains("落盘回归探针"), "报告没能从磁盘读到日志尾巴")

func test_previous_tail_survives_exclusive_open() -> void:
	# 回归：崩溃报告的日志尾巴曾经永远为空 ✗。
	# 根因：Godot 的 FileAccess 在 Windows 上**独占打开** ✗，记录器握着日志文件时，
	# 另开句柄读它必然失败（get_file_as_string 还静默返回空串 ✗）。
	# 修法：记录器在**打开文件的那一刻**就用同一个句柄把旧日志尾巴读好 ✓。
	var ls := _load(LOGGER)
	if ls == null:
		return
	# 必须用**独立的日志文件**：插件此刻正独占着真实的 session.log ✗，
	# 测试里的 logger 根本打不开它（这正是"独占打开"那条坑 ✓）。
	var test_log := "user://crash_monitor/_test/session.log"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://crash_monitor/_test"))
	if FileAccess.file_exists(ProjectSettings.globalize_path(test_log)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_log))
	for i in range(3):
		var a: Logger = ls.new()
		a.log_path = test_log
		a.call("_open_log")           # 换了路径要重新开
		a.call("_log_message", "上一任写下的第 %d 行" % i, false)
		a = null                      # 释放 → 句柄关闭 → 下一任才能打开
	# 下一任（模拟"下次启动"）应当能读回上一任的尾巴
	var b: Logger = ls.new()
	b.log_path = test_log
	b.call("_open_log")
	var tail: Array = b.previous_tail
	print("[崩溃记录器] 下一任读到上一任尾巴 %d 条" % tail.size())
	var joined := "\n".join(PackedStringArray(tail.map(func(x): return str(x))))
	assert_true(tail.size() > 0, "读不回上一任的日志（说明仍在用另开句柄的错误做法 ✗）")
	assert_true(joined.contains("上一任写下的第"), "尾巴内容不对")
	print("[崩溃记录器] 尾巴末尾：%s" % joined.right(80))
	b = null
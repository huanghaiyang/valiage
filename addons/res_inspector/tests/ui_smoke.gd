@tool
extends SceneTree
## RES 查看器 · 面板 UI 无头冒烟测试
## 用法：godot --headless --path <工程> --script res://addons/res_inspector/tests/ui_smoke.gd
##
## 覆盖：面板实例化、接口齐备、逐个打开样本（二进制 / 文本 / 垃圾字节 / 不存在路径 / 6.3 MB 大样本）、
##       所有分页切换、结构树确实有内容、重载、耗时上限。
##
## 夹具由 tests/fixtures.gd 现造（产物在 __probe__/，已 gitignore）。

const DOCK_PATH := "res://addons/res_inspector/res_dock.gd"
const Fixtures := preload("res://addons/res_inspector/tests/fixtures.gd")

var _fail := 0
var _pass := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ %s" % msg)


func _run() -> void:
	print("===== RES 查看器 · UI 冒烟测试 =====")

	var script: Script = load(DOCK_PATH)
	if script == null or not script.can_instantiate():
		print("✗ 加载/编译失败：%s（面板脚本还不存在或语法错误？）" % DOCK_PATH)
		quit(1)
		return

	var dock: Control = script.new() as Control
	if dock == null:
		print("✗ res_dock.gd 的基类不是 Control")
		quit(1)
		return
	dock.name = "ResInspectorDock"
	root.add_child(dock)
	await process_frame
	await process_frame
	_check(dock.is_inside_tree(), "面板应能加入场景树")
	_check(dock.has_method("open_path"), "缺少 open_path()")
	_check(dock.has_method("reload"), "缺少 reload()")
	_check(dock.has_method("get_current_path"), "缺少 get_current_path()")

	# 用例：路径 + 是否应展示出内容
	var fx: Dictionary = Fixtures.ensure()
	var cases: Array = [
		[fx["gradient"], true],
		[fx["mesh"], true],
		[fx["text"], true],
		[fx["junk"], false],
		[fx["missing"], false],
	]
	var big := Fixtures.big_sample()
	if big != "":
		cases.insert(2, [big, true])

	for case in cases:
		var path: String = case[0]
		var need_content: bool = case[1]
		var t0 := Time.get_ticks_msec()
		dock.call("open_path", path)
		await process_frame
		await process_frame
		var cost := Time.get_ticks_msec() - t0
		var cur := str(dock.call("get_current_path")) if dock.has_method("get_current_path") else ""

		# 切遍所有分页
		var tabs: Array = []
		_collect(dock, "TabContainer", tabs)
		for tc in tabs:
			var container := tc as TabContainer
			for i in range(container.get_tab_count()):
				container.current_tab = i
				await process_frame

		# 结构树 / 属性树是否真的有东西
		var trees: Array = []
		_collect(dock, "Tree", trees)
		var items := 0
		for t in trees:
			var tree := t as Tree
			if tree.get_root() != null:
				items += _count_items(tree.get_root())

		print("  · %-24s %5d ms  当前=%-2s  Tree 条目=%d" % [
			path.get_file() if path.get_file() != "" else path, cost,
			("是" if cur != "" else "空"), items])

		_check(cost < 5000, "打开 %s 耗时 %d ms（应 < 5000）" % [path, cost])
		if need_content:
			_check(items > 0, "%s 应有可展示内容，实际 Tree 条目 %d" % [path, items])
		_check(cur != "" or not need_content, "%s 打开后 get_current_path() 不应为空" % path)

	# 打开过文件后分页应当齐全
	var tabs2: Array = []
	_collect(dock, "TabContainer", tabs2)
	var total_pages := 0
	for tc in tabs2:
		total_pages += (tc as TabContainer).get_tab_count()
	print("  打开文件后：TabContainer %d 个，总页数 %d" % [tabs2.size(), total_pages])
	_check(total_pages >= 3, "打开文件后总页数应 >= 3（实际 %d）" % total_pages)

	# 重载
	dock.call("open_path", fx["mesh"])
	await process_frame
	if dock.has_method("reload"):
		dock.call("reload")
		await process_frame
		_check(str(dock.call("get_current_path")) != "", "reload() 后仍应保持当前文件")

	# 可选接口
	if dock.has_method("set_status"):
		dock.call("set_status", "冒烟测试提示")
		await process_frame
		_check(true, "set_status 可调用")
	if dock.has_method("get_current_info"):
		var info: Dictionary = dock.call("get_current_info")
		_check(not info.is_empty(), "get_current_info 应返回解析结果")
		_check(bool(info.get("ok", false)), "mesh 夹具的解析结果应 ok")

	dock.queue_free()
	await process_frame

	print("\n===== 结果：通过 %d，失败 %d =====" % [_pass, _fail])
	if _fail > 0:
		print("❌ UI 冒烟未通过")
		quit(1)
	else:
		print("✅ UI 冒烟通过")
		quit(0)


## 递归收集某类的节点。
func _collect(node: Node, cls: String, out: Array) -> void:
	if node.is_class(cls):
		out.append(node)
	for c in node.get_children():
		_collect(c, cls, out)


## 统计 Tree 条目数（含折叠的子项）。
func _count_items(item: TreeItem) -> int:
	var n := 1
	var child := item.get_first_child()
	while child != null:
		n += _count_items(child)
		child = child.get_next()
	return n

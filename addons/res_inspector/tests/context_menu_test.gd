@tool
extends SceneTree
## RES 查看器 · FileSystem 右键菜单自检
## 用法：godot --headless --path <工程> --script res://addons/res_inspector/tests/context_menu_test.gd
##
## 针对线上出现过的错误：
##   ERROR: Failed to execute context menu callback: 'EditorContextMenuPlugin(res_context_menu.gd)::_trigger':
##          Method expected 1 argument(s), but called with 2.
## 根因：菜单项回调被引擎**带 1 个参数**调用，而旧实现又 `bind(路径)` 塞了 1 个 → 变成 2 个。
##
## 注意：`EditorContextMenuPlugin` 在非编辑器模式（--headless --script）下 `new()` 返回 null，
## 所以这里分两层验证：
##   ① 纯逻辑（menu_logic.gd）—— 直接单测；
##   ② 契约静态检查 —— 从脚本元数据/源码里确认「回调允许 0/1 参、且没有 bind 路径」。

const LOGIC_PATH := "res://addons/res_inspector/menu_logic.gd"
const MENU_PATH := "res://addons/res_inspector/res_context_menu.gd"

var _fail := 0
var _pass := 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("  ✗ %s" % msg)


func _initialize() -> void:
	print("===== RES 查看器 · 右键菜单自检 =====")

	# ---------- ① 纯逻辑 ----------
	var logic: Script = load(LOGIC_PATH)
	_check(logic != null and logic.can_instantiate(), "menu_logic.gd 应可实例化")
	if logic == null or not logic.can_instantiate():
		_done()
		return

	_check(str(logic.call("pick", PackedStringArray())) == "", "空选择应返回空串")
	_check(str(logic.call("pick", PackedStringArray(["res://a.txt"]))) == "", "非资源后缀应被过滤")
	_check(str(logic.call("pick", PackedStringArray(["res://a.gd"]))) == "", ".gd 不应被当成资源")
	_check(str(logic.call("pick", PackedStringArray(["res://a.res"]))) == "res://a.res", ".res 应被接受")
	_check(str(logic.call("pick", PackedStringArray(["res://x.txt", "res://b.tres"]))) == "res://b.tres",
			"多选时应挑第一个资源文件")
	_check(str(logic.call("pick", PackedStringArray(["res://c.SCN"]))) == "res://c.SCN", "后缀应忽略大小写")
	_check(bool(logic.call("is_openable", "a.tscn")), "is_openable(tscn) 应为 true")
	_check(not bool(logic.call("is_openable", "a.bin")), "is_openable(bin) 应为 false")

	# 回调参数解读：三种形态都要认，认不出返回空串
	_check(str(logic.call("pick_arg", PackedStringArray(["res://p/a.res"]))) == "res://p/a.res",
			"PackedStringArray 参数应被识别")
	_check(str(logic.call("pick_arg", ["res://p/b.tres"])) == "res://p/b.tres",
			"Array 参数应被识别")
	_check(str(logic.call("pick_arg", "res://p/c.tscn")) == "res://p/c.tscn",
			"String 参数应被识别")
	_check(str(logic.call("pick_arg", "res://p/d.txt")) == "", "非资源 String 不应被接受")
	_check(str(logic.call("pick_arg", 12345)) == "", "无法识别的参数应返回空串")
	_check(str(logic.call("pick_arg", null)) == "", "null 参数应返回空串")

	# ---------- ② 编辑器类：能实例化就整体跑一遍，不能就只查契约 ----------
	var menu_script: Script = load(MENU_PATH)
	_check(menu_script != null and menu_script.can_instantiate(), "res_context_menu.gd 应能编译")
	if menu_script == null or not menu_script.can_instantiate():
		_done()
		return

	var menu = menu_script.new()
	if menu != null:
		# 编辑器进程里能实例化：真实跑一遍回调（0 参 / 1 参）
		var opened: Array = []
		menu.call("setup", func(p: String) -> void: opened.append(p))
		menu.call("_on_menu_item")
		_check(opened.is_empty(), "没有目标时 0 参调用不应打开任何东西")
		menu.call("_on_menu_item", PackedStringArray(["res://probe/a.res"]))
		_check(opened.size() == 1 and str(opened[0]) == "res://probe/a.res",
				"1 参调用应打开第一个资源：%s" % str(opened))
		opened.clear()
		menu.set("_target", "res://probe/cache.res")
		menu.call("_on_menu_item", 12345)
		_check(opened.size() == 1 and str(opened[0]) == "res://probe/cache.res",
				"认不出参数时应回落到缓存的路径：%s" % str(opened))
	else:
		print("  · 非编辑器模式：EditorContextMenuPlugin 无法实例化，改查契约")

	# ---------- 契约静态检查（两种模式都做） ----------
	var methods: Array = menu_script.get_script_method_list()
	var found := {}
	for m in methods:
		found[str(m.get("name", ""))] = m
	_check(found.has("_popup_menu"), "缺少 _popup_menu(paths)")
	_check(found.has("_on_menu_item"), "缺少 _on_menu_item")
	if found.has("_on_menu_item"):
		var args: Array = (found["_on_menu_item"] as Dictionary).get("args", [])
		var defaults: Array = (found["_on_menu_item"] as Dictionary).get("default_args", [])
		_check(args.size() == 1, "_on_menu_item 应恰好 1 个参数（引擎会传 1 个），实际 %d 个" % args.size())
		_check(defaults.size() == 1, "_on_menu_item 的该参数应带默认值（兼容 0 参调用），实际默认值 %d 个" % defaults.size())

	# 源码检查：绝不能再对菜单回调 bind 路径（那正是 2 参数报错的来源）
	var src := FileAccess.get_file_as_string(MENU_PATH)
	_check(not src.contains("_on_menu_item.bind("), "不得对菜单回调 bind 参数（会导致 2 参数调用）")
	_check(src.contains("add_context_menu_item("), "应通过 add_context_menu_item 注册菜单项")

	_done()


func _done() -> void:
	print("\n===== 结果：通过 %d，失败 %d =====" % [_pass, _fail])
	if _fail > 0:
		print("❌ 右键菜单自检未通过")
		quit(1)
	else:
		print("✅ 右键菜单自检通过")
		quit(0)

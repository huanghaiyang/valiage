@tool
extends McpTestSuite
## Blender 桥插件自检。
## 注意：**绝不真的启动 Blender**（会弹 GUI）—— 命令行拼装、导入脚本内容、路径设置、
## 边界情况都单独抽出来测，启动那一步只验"参数怎么拼"。

const BLENDER_SCRIPT := "res://addons/blender_bridge/blender.gd"
const DIALOG_SCRIPT := "res://addons/blender_bridge/settings_dialog.gd"
const MENU_SCRIPT := "res://addons/blender_bridge/filesystem_menu.gd"
const SAMPLE_GLB := "res://assets/models/buildings/墓地遗迹.glb"


func suite_name() -> String:
	return "blender_bridge"


func _script(path: String) -> GDScript:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n as Button
	for c in n.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


func test_build_args() -> void:
	var s := _script(BLENDER_SCRIPT)
	assert_true(s != null, "blender.gd 加载失败")
	if s == null:
		return
	var args: PackedStringArray = s.call("build_args", "C:/tmp/import_glb.py")
	print("[Blender 桥] 命令行参数 = %s" % str(args))
	assert_eq(args.size(), 2, "应该是两个参数")
	assert_eq(String(args[0]), "--python", "第一个参数应该是 --python")
	assert_eq(String(args[1]), "C:/tmp/import_glb.py", "第二个参数应该是脚本路径")


func test_import_script_content() -> void:
	var s := _script(BLENDER_SCRIPT)
	if s == null:
		return
	var prep: Dictionary = s.call("prepare", SAMPLE_GLB)
	assert_true(bool(prep.get("ok", false)), "prepare 失败：" + str(prep.get("message", "")))
	if not bool(prep.get("ok", false)):
		return
	var script := String(prep["script"])
	var work := String(prep["work"])
	var src := ProjectSettings.globalize_path(SAMPLE_GLB).replace("\\", "/")
	print("[Blender 桥] 脚本 = %s" % script)
	print("[Blender 桥] 副本 = %s" % work)
	assert_true(FileAccess.file_exists(script), "脚本没写出来")
	assert_true(FileAccess.file_exists(work), "给 Blender 用的副本没生成")
	# 会话目录里应当只有当前这一份副本（否则每开一次就多留几十 MB）
	var session_dir := work.get_base_dir()
	print("[Blender 桥] 会话目录 %s 里有 %d 个文件" % [session_dir, DirAccess.get_files_at(session_dir).size()])
	assert_true(DirAccess.get_files_at(session_dir).size() <= 1, "会话目录里堆了多个副本")
	if not FileAccess.file_exists(script):
		return
	var text := FileAccess.open(script, FileAccess.READ).get_as_text()

	# ① 干掉默认方块：必须先读空场景
	assert_true(text.contains("read_homefile(use_empty=True)"), "脚本没清空默认场景（默认方块会留着）")
	# ② 导入的是副本，不是原始文件
	assert_true(text.contains("bpy.ops.import_scene.gltf(filepath=WORK)"),
			"导入的不是副本 —— 原始文件有被改的风险")
	assert_true(text.contains(work), "脚本里没有副本路径")
	# ③ 导出/另存为的默认路径被改成新文件
	assert_true(text.contains("export_scene.gltf"), "脚本没处理导出默认路径")
	assert_true(text.contains("EXPORT_DEFAULT"), "脚本缺少导出默认路径变量")
	assert_true(text.contains("save_as_mainfile"), "脚本没处理另存为默认路径")
	assert_true(text.contains("BLEND_DEFAULT"), "脚本缺少另存为默认路径变量")
	# ④ 路径统一正斜杠（Python 反斜杠转义坑）
	assert_false(text.contains("\\"), "脚本里出现了反斜杠")
	# ⑤ 原始路径只作参考出现
	assert_true(text.contains(src), "脚本里没有原始文件路径（应作为只读参考）")
	var exp := String(prep["export_default"])
	print("[Blender 桥] 导出默认落点 = %s" % exp)
	assert_true(exp.ends_with("_edited.glb"), "导出默认路径应该是新文件：%s" % exp)
	assert_false(exp == src, "导出默认路径不能等于原始文件！")


func test_source_file_untouched() -> void:
	# 用户要求"禁止修改原始文件"：prepare 之后原始 glb 的
	# 大小和修改时间都必须一模一样
	var s := _script(BLENDER_SCRIPT)
	if s == null:
		return
	var src := ProjectSettings.globalize_path(SAMPLE_GLB)
	var size_before := 0
	var f := FileAccess.open(src, FileAccess.READ)
	if f != null:
		size_before = f.get_length()
		f.close()
	var mtime_before := FileAccess.get_modified_time(src)

	var prep: Dictionary = s.call("prepare", SAMPLE_GLB)
	assert_true(bool(prep.get("ok", false)), "prepare 失败")
	var size_after := 0
	var f2 := FileAccess.open(src, FileAccess.READ)
	if f2 != null:
		size_after = f2.get_length()
		f2.close()
	var mtime_after := FileAccess.get_modified_time(src)
	print("[Blender 桥] 原始文件 大小 %d→%d，修改时间 %d→%d" % [size_before, size_after, mtime_before, mtime_after])
	assert_eq(size_after, size_before, "原始文件大小被改了！")
	assert_eq(mtime_after, mtime_before, "原始文件被写过了（修改时间变了）")

func test_path_settings_roundtrip() -> void:
	var s := _script(BLENDER_SCRIPT)
	if s == null:
		return
	var backup := String(s.call("get_saved_path"))
	s.call("save_path", "C:/fake/blender.exe")
	var got := String(s.call("get_saved_path"))
	print("[Blender 桥] 保存/读取：%s" % got)
	assert_eq(got, "C:/fake/blender.exe", "路径没存住")
	s.call("save_path", backup)                 # 还原，别污染真实配置
	assert_eq(String(s.call("get_saved_path")), backup, "还原失败")


func test_find_blender_never_returns_bogus() -> void:
	var s := _script(BLENDER_SCRIPT)
	if s == null:
		return
	var found := String(s.call("find_blender"))
	print("[Blender 桥] 探测到的 Blender = %s" % ("<空>" if found.is_empty() else found))
	# 不写成 if（否则找不到 Blender 时就是 0 断言、被判"跳过逻辑"）。
	# 要守的不变量：要么返回空，要么返回一个**真实存在**的可执行文件
	assert_true(found.is_empty() or FileAccess.file_exists(found),
			"find_blender 返回了不存在的路径：%s" % found)
	assert_true(found.is_empty() or found.to_lower().ends_with(".exe") or found.to_lower().ends_with("blender"),
			"返回的路径不像 blender 可执行文件：%s" % found)


func test_open_in_blender_guards() -> void:
	var s := _script(BLENDER_SCRIPT)
	if s == null:
		return
	# 空路径必须直接失败，绝不启动进程
	var res: Dictionary = s.call("open_in_blender", "")
	assert_false(bool(res.get("ok", false)), "空路径不该成功")
	print("[Blender 桥] 空路径结果：%s" % String(res.get("message", "")))
	assert_true(String(res.get("message", "")).length() > 0, "失败也该有说明文字")


func test_settings_dialog_loads() -> void:
	var s := _script(DIALOG_SCRIPT)
	assert_true(s != null, "settings_dialog.gd 加载失败（有解析错误？）")
	if s == null:
		return
	var dlg: ConfirmationDialog = s.new()
	assert_true(dlg != null, "设置窗口实例化失败")
	if dlg == null:
		return
	assert_true(dlg.theme != null, "设置窗口没继承编辑器主题")
	dlg.call("set_message", "测试消息")     # 外部写提示用的接口
	var has_edit := false
	var stack: Array = [dlg]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is LineEdit:
			has_edit = true
		for c in n.get_children():
			stack.append(c)
	assert_true(has_edit, "设置窗口里没有路径输入框")
	# 尺寸：要"宽而矮"（用户反馈太高）。同时守住 autowrap 撑高那类问题
	print("[Blender 桥] 设置窗口 size=%s 内容最小尺寸=%s" % [str(dlg.size), str(dlg.get_contents_minimum_size())])
	assert_true(dlg.size.x >= 700, "设置窗口该更宽一些，实际宽 %d" % dlg.size.x)
	assert_true(dlg.size.y <= 320, "设置窗口太高了，实际高 %d" % dlg.size.y)
	assert_true(dlg.get_contents_minimum_size().y <= 320.0,
			"内容最小高度太大（%.0f）—— autowrap 又把窗口撑高了" % dlg.get_contents_minimum_size().y)
	dlg.free()


func test_menu_recognizes_models() -> void:
	var s := _script(MENU_SCRIPT)
	assert_true(s != null, "filesystem_menu.gd 加载失败")
	if s == null:
		return
	var menu: EditorContextMenuPlugin = s.new()
	assert_eq(String(menu.call("_first_model", PackedStringArray(["a.png", "b.glb"]))), "b.glb",
			"应该认出 .glb")
	assert_eq(String(menu.call("_first_model", PackedStringArray(["a.gltf"]))), "a.gltf",
			"应该认出 .gltf")
	assert_eq(String(menu.call("_first_model", PackedStringArray(["a.png"]))), "",
			"图片不该被当成模型")


func test_settings_moved_into_menu() -> void:
	# 用户要求：设置别占 3D 工具栏，放到菜单里（项目→工具，另外 best-effort 挂到帮助菜单）
	var found := _find_button(EditorInterface.get_base_control(), "Blender 设置")
	assert_true(found == null, "「Blender 设置」不该再出现在 3D 工具栏里")
	# 设置窗口本身仍然可用
	var s := _script(MENU_SCRIPT)
	assert_true(s != null, "filesystem_menu.gd 加载失败")
	if s != null:
		s.call("open_settings", "自检：设置窗口可打开")
		var dlg: ConfirmationDialog = null
		for c in EditorInterface.get_base_control().get_children():
			if c is ConfirmationDialog and String((c as ConfirmationDialog).title) == "Blender 路径设置":
				dlg = c as ConfirmationDialog
		assert_true(dlg != null, "设置窗口没能打开")
		if dlg != null:
			dlg.hide()
			dlg.queue_free()


func test_help_menu_hook() -> void:
	# 用户要求：设置放「帮助」里。
	# Godot 没给插件开放帮助菜单的扩展点（EditorPlugin 76 个方法里没有），
	# 所以插件是在编辑器 UI 里找到名为 Help 的 PopupMenu 直接加项 —— 这条测试守住它。
	var ps := _script("res://addons/blender_bridge/plugin.gd")
	assert_true(ps != null, "plugin.gd 加载失败")
	if ps == null:
		return
	var inst: EditorPlugin = ps.new()
	inst.call("_try_hook_help_menu")
	var hooked := bool(inst.call("is_help_menu_hooked"))
	print("[Blender 桥] 帮助菜单已挂 = %s" % str(hooked))
	assert_true(hooked, "没能挂到帮助菜单（Godot 编辑器结构变了？）")

	var found := false
	var stack: Array = [EditorInterface.get_base_control()]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is PopupMenu and String(n.name) == "Help" \
				and (n as PopupMenu).get_item_index(420731) >= 0:
			found = true
		for c in n.get_children():
			stack.append(c)
	assert_true(found, "帮助菜单里没有「Blender 设置…」这一项")
	inst.free()
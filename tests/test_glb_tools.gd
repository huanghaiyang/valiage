@tool
extends McpTestSuite
## GLB 工具插件自检。覆盖两条链路：
##   ① 场景里选中节点 →「导出选中节点为 GLB」窗口（场景树右键 / 3D 工具栏「导出 GLB」）
##   ② 文件系统右键 .glb → 预览窗口（节点树勾选 + 3D 预览）→ 导出新 glb
## 另含两条"需求钉死"用例：窗口必须继承编辑器主题、窗口高度不能撑爆。

const EXPORT_SCRIPT := "res://addons/glb_tools/glb_export.gd"
const DIALOG_SCRIPT := "res://addons/glb_tools/export_dialog.gd"
const LAUNCHER_SCRIPT := "res://addons/glb_tools/open_dialog.gd"
const PREVIEW_SCRIPT := "res://addons/glb_tools/preview_window.gd"
const FS_MENU_SCRIPT := "res://addons/glb_tools/filesystem_menu.gd"
const SAMPLE_GLB := "res://assets/models/buildings/墓地场景3d模型.glb"
const OUT_DIR := "user://glb_tools_test"


func suite_name() -> String:
	return "glb_tools"


## 用 CACHE_MODE_IGNORE 读源码：preload 会命中资源缓存，改了脚本却跑旧代码（踩过）
func _script(path: String) -> GDScript:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _make_fixture() -> Array:
	var root := Node3D.new()
	root.name = "FixtureRoot"
	track(root)
	var made: Array = []
	for i in 3:
		var mi := MeshInstance3D.new()
		mi.name = "Part%d" % i
		mi.mesh = BoxMesh.new()
		mi.position = Vector3(i * 2.0, 0.0, 0.0)
		root.add_child(mi)
		made.append(mi)
	return [root, made]


## 注意：GLTFDocument.generate_scene() 生成的是 ImporterMeshInstance3D（导入中间态），
## 不是 MeshInstance3D —— 两种都要数，否则永远是 0（踩过）
func _is_mesh_node(n: Node) -> bool:
	if n is MeshInstance3D:
		return (n as MeshInstance3D).mesh != null
	return n.get_class() == "ImporterMeshInstance3D"


func _count_meshes(n: Node) -> int:
	var total := 0
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if _is_mesh_node(cur):
			total += 1
		for c in cur.get_children():
			stack.append(c)
	return total


func _collect_positions(n: Node, out: Array) -> void:
	if _is_mesh_node(n) and n is Node3D:
		out.append((n as Node3D).global_position)
	for c in n.get_children():
		_collect_positions(c, out)


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n as Button
	for c in n.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


## 按**类 + 精确标题**找窗口。
## 注意：不能用"标题含 GLB"这种模糊匹配 —— 预览窗口标题也含 GLB，会把两个搞混（踩过）
func _find_export_dialog() -> ConfirmationDialog:
	# 两种来源都要找：编辑器主面板下（场景树入口）和**预览窗口内部**（右键入口）
	for c in EditorInterface.get_base_control().get_children():
		if c is ConfirmationDialog and (c as ConfirmationDialog).visible \
				and String((c as ConfirmationDialog).title) == "导出选中节点为 GLB":
			return c as ConfirmationDialog
		if c is Window:
			for d in c.get_children():
				if d is ConfirmationDialog and (d as ConfirmationDialog).visible \
						and String((d as ConfirmationDialog).title) == "导出选中节点为 GLB":
					return d as ConfirmationDialog
	return null


func _find_preview_window() -> Window:
	for c in EditorInterface.get_base_control().get_children():
		if c is Window and not (c is ConfirmationDialog) and (c as Window).visible \
				and String((c as Window).title).begins_with("GLB 预览"):
			return c as Window
	return null


## 关掉插件可能遗留的窗口（之前失败的用例会留下没关的窗口，影响后面的用例）
func _close_plugin_windows() -> void:
	for c in EditorInterface.get_base_control().get_children():
		if c is Window and String((c as Window).title).contains("GLB"):
			(c as Window).hide()
			c.queue_free()


# ------------------------------------------------------------------ 导出核心

func test_export_roundtrip() -> void:
	var fx := _make_fixture()
	var parts: Array = fx[1]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := ProjectSettings.globalize_path(OUT_DIR).path_join("two_parts.glb")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

	var res: Dictionary = _script(EXPORT_SCRIPT).call("export_nodes", [parts[0], parts[2]], path, true)
	assert_true(bool(res.get("ok", false)), "导出失败：" + str(res.get("message", "")))
	if not bool(res.get("ok", false)):
		return
	print("[GLB 工具] ", res.get("message", ""))
	assert_true(FileAccess.file_exists(path), "没写出文件")

	var f := FileAccess.open(path, FileAccess.READ)
	var magic := f.get_buffer(4)
	f.close()
	assert_eq(magic.get_string_from_ascii(), "glTF", "文件头不是 glTF（不是二进制 GLB）")

	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_file(path, st)
	assert_eq(err, OK, "读回刚导出的 glb 失败（错误码 %d）" % err)
	if err != OK:
		return
	var scene: Node = doc.generate_scene(st)
	assert_true(scene != null, "generate_scene 返回空")
	if scene == null:
		return
	var mesh_count := _count_meshes(scene)
	print("[GLB 工具] 读回：网格 %d 个" % mesh_count)
	assert_eq(mesh_count, 2, "导出的网格数应为 2，实际 %d" % mesh_count)

	# 读回来的场景也是"孤儿树"，直接读 global_position 会得到 0，先临时挂进场景树
	var host: Window = (Engine.get_main_loop() as SceneTree).root
	host.add_child(scene)
	var got: Array = []
	_collect_positions(scene, got)
	host.remove_child(scene)
	var xs: Array = []
	for p in got:
		xs.append(snappedf((p as Vector3).x, 0.001))
	xs.sort()
	print("[GLB 工具] 读回的 X 坐标：", xs)
	assert_true(xs.has(0.0) and xs.has(4.0), "世界位置没保持：%s" % str(xs))
	scene.free()


func test_top_level_only() -> void:
	var fx := _make_fixture()
	var root: Node = fx[0]
	var parts: Array = fx[1]
	var s := _script(EXPORT_SCRIPT)
	var picked: Array = s.call("top_level_only", [root, parts[1]])
	assert_eq(picked.size(), 1, "父+子都选中时应该只保留父节点")
	assert_true(picked[0] == root, "保留下来的应该是父节点")
	var two: Array = s.call("top_level_only", [parts[0], parts[2]])
	assert_eq(two.size(), 2, "互不包含的两个节点都应保留")
	assert_true(bool(s.call("is_exportable", parts[0])), "带网格的 MeshInstance3D 应算可导出")
	var empty := Node3D.new()
	track(empty)
	assert_false(bool(s.call("is_exportable", empty)), "空 Node3D 不该算可导出")


# ------------------------------------------------------------------ ① 场景选中节点导出

func test_export_dialog_opens_and_fits() -> void:
	var s := _script(DIALOG_SCRIPT)
	assert_true(s != null, "export_dialog.gd 加载失败（有解析错误？看编辑器 Output）")
	if s == null:
		return
	var fx := _make_fixture()
	var launcher := _script(LAUNCHER_SCRIPT)
	assert_true(launcher != null, "open_dialog.gd 加载失败")
	if launcher == null:
		return
	_close_plugin_windows()
	launcher.call("open_for", [(fx[1] as Array)[0]])
	var dlg := _find_export_dialog()
	assert_true(dlg != null, "open_for() 之后没出现导出窗口（「点了没反应」就是这个症状）")
	if dlg == null:
		return
	assert_true(dlg.theme != null, "导出窗口没有继承编辑器主题（文字会看不清）")
	var content_h := dlg.get_contents_minimum_size().y
	print("[GLB 工具] 导出窗口 size=%s 内容最小高=%.0f theme=%s" % [str(dlg.size), content_h, dlg.theme != null])
	assert_true(content_h <= 700.0, "内容最小高太大（%.0f px）—— autowrap Label 又把窗口撑爆了" % content_h)
	assert_true(dlg.size.y <= 760, "窗口太高（%d px），确认按钮会跑到屏幕外" % dlg.size.y)
	dlg.hide()
	dlg.queue_free()


func test_expected_entries() -> void:
	var base := EditorInterface.get_base_control()
	assert_true(_find_button(base, "导出 GLB") != null, "3D 工具栏应该有「导出 GLB」按钮")
	assert_true(_find_button(base, "GLB 预览") == null, "「GLB 预览」工具栏按钮按需求已去掉")
	for f in ["plugin.gd", "scene_menu.gd", "export_dialog.gd", "open_dialog.gd",
			"filesystem_menu.gd", "preview_window.gd", "glb_export.gd"]:
		assert_true(FileAccess.file_exists(ProjectSettings.globalize_path("res://addons/glb_tools/" + f)),
				"%s 应存在" % f)


# ------------------------------------------------------------------ ② 文件系统右键 → 预览窗口

func test_preview_window_theme_and_nodes() -> void:
	var s := _script(PREVIEW_SCRIPT)
	assert_true(s != null, "preview_window.gd 加载失败")
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	# 主题：不设的话用的是 Godot 默认主题，配色偏蓝、文字看不清（用户反馈）
	assert_true(win.theme != null, "预览窗口没有继承编辑器主题（文字会看不清）")
	# 高度按屏幕比例判断：既允许 80% 的大窗口，又能抓住内容把窗口撑爆的情况
	var scr := DisplayServer.screen_get_size()
	assert_true(win.size.y <= int(scr.y * 0.85), "预览窗口太高（%d px / 屏幕 %d）" % [win.size.y, scr.y])

	assert_true(ResourceLoader.exists(SAMPLE_GLB), "找不到测试用的 glb")
	win.call("load_glb", SAMPLE_GLB)
	var tree: Tree = win.get("_tree")
	assert_true(tree != null and tree.get_root() != null, "节点树没建出来")
	if tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return
	var checkable := 0
	var item: TreeItem = tree.get_root()
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			checkable += 1
		item = item.get_next_in_tree()
	print("[GLB 工具] 预览窗口列出可勾选节点 %d 个" % checkable)
	assert_true(checkable >= 3, "应该列出多个可勾选节点，实际 %d" % checkable)
	assert_true(win.get("_camera") != null, "预览相机没建出来")
	win.hide()
	win.queue_free()


func test_preview_window_export_click() -> void:
	# 预览窗口里"勾选 → 点导出"这条也必须真跑一遍（之前只测了列表，没测导出按钮）
	var s := _script(PREVIEW_SCRIPT)
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	win.call("load_glb", SAMPLE_GLB)
	var tree: Tree = win.get("_tree")
	assert_true(tree != null and tree.get_root() != null, "节点树没建出来")
	if tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return

	var picked := 0
	var item: TreeItem = tree.get_root().get_next_in_tree()
	while item != null and picked < 2:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			item.set_checked(0, true)
			picked += 1
		item = item.get_next_in_tree()
	assert_eq(picked, 2, "没能在树里勾上 2 个节点")
	win.call("_on_check_tool", 0)                 # 全不选（v2 的方法名）
	assert_eq((win.call("_checked_nodes") as Array).size(), 0, "全不选之后不该还有勾选")
	item = tree.get_root().get_next_in_tree()
	picked = 0
	while item != null and picked < 2:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			item.set_checked(0, true)
			picked += 1
		item = item.get_next_in_tree()

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	var path := ProjectSettings.globalize_path(OUT_DIR).path_join("preview_export.glb")
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var edit: LineEdit = win.get("_path_edit")
	edit.text = path
	win.call("_on_export", false)                 # v2：参数是"是否拆分成多个文件"
	var status := String((win.get("_status") as Label).text)
	print("[GLB 工具] 预览窗口导出结果：", status)
	assert_true(FileAccess.file_exists(path), "预览窗口点导出没写出文件：" + status)
	if FileAccess.file_exists(path):
		# 贴图必须**内嵌**在 .glb 里（有 uri 就是外链，换台机器/挪个目录就丢贴图）
		var raw := FileAccess.open(path, FileAccess.READ)
		raw.seek(12)                                   # GLB 头 12 字节，然后是 JSON chunk 长度
		var json_len := raw.get_buffer(4).decode_u32(0)
		raw.seek(20)                                   # 跳过 chunk 头 8 字节
		var json_text := raw.get_buffer(json_len).get_string_from_utf8()
		raw.close()
		var parsed = JSON.parse_string(json_text)
		var images: Array = parsed.get("images", []) if parsed is Dictionary else []
		var external := 0
		for img in images:
			if img is Dictionary and (img as Dictionary).has("uri"):
				external += 1
		print("[GLB 工具] 预览窗口导出：贴图 %d 张，其中外链 %d 张" % [images.size(), external])
		assert_eq(external, 0, "有 %d 张贴图是外链（应该内嵌在 glb 里）" % external)

		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		assert_eq(doc.append_from_file(path, st), OK, "预览窗口导出的文件读不回来")
		var scene: Node = doc.generate_scene(st)
		assert_eq(_count_meshes(scene), 2, "应该正好导出勾选的 2 个网格")
		scene.free()
	win.hide()
	win.queue_free()


func test_preview_window_camera_and_filter() -> void:
	# 用户反馈"预览窗口太小"：默认尺寸不能小；"颜色不对"：必须有编辑器主题 + 底色跟编辑器视口
	var s := _script(PREVIEW_SCRIPT)
	assert_true(s != null, "preview_window.gd 加载失败")
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	assert_true(win.theme != null, "预览窗口没有编辑器主题（颜色会不对）")
	assert_true(win.size.x >= 1000 and win.size.y >= 700, "预览窗口默认太小：%s" % str(win.size))
	win.call("load_glb", SAMPLE_GLB)

	var cam: Camera3D = win.get("_camera")
	assert_true(cam != null, "预览相机没建出来")
	if cam == null:
		win.hide()
		win.queue_free()
		return

	# 走真实输入路径：按下左键 → 拖动 → 相机应该转
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	win.call("_on_view_input", press)
	var before := cam.position
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(60, 20)
	win.call("_on_view_input", motion)
	var after := cam.position
	print("[GLB 工具] 左键拖拽：%s → %s" % [str(before), str(after)])
	assert_true(before.distance_to(after) > 0.001, "左键拖拽没有旋转视角")

	# 滚轮缩放
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	var d_before := float(win.get("_distance"))
	win.call("_on_view_input", wheel)
	print("[GLB 工具] 滚轮缩放：%.3f → %.3f" % [d_before, float(win.get("_distance"))])
	assert_true(float(win.get("_distance")) < d_before, "滚轮没有缩放")

	# 搜索过滤
	win.call("_apply_filter", "part_29")
	var tree: Tree = win.get("_tree")
	var visible_items := 0
	var total_items := 0
	var matched := 0
	var sample := PackedStringArray()
	var item: TreeItem = tree.get_root().get_next_in_tree()
	while item != null:
		total_items += 1
		if sample.size() < 6:
			sample.append("%s(可见=%s)" % [item.get_text(1), str(item.visible)])
		if item.visible:
			visible_items += 1
			if String(item.get_text(1)).contains("part_29"):
				matched += 1
		item = item.get_next_in_tree()
	var dump := FileAccess.open("user://zz_filter.txt", FileAccess.WRITE)
	if dump != null:
		dump.store_string("过滤词=part_29\n总数=%d 可见=%d\n前几项：%s\n" % [total_items, visible_items, ", ".join(sample)])
		dump.close()
	print("[GLB 工具] 搜索 'part_29'：总 %d 项，可见 %d 项" % [total_items, visible_items])
	assert_true(total_items > 3, "树里节点太少（%d），没法验证过滤" % total_items)
	assert_true(visible_items < total_items, "过滤没起作用（可见 %d / 总 %d）" % [visible_items, total_items])
	assert_true(visible_items <= 4, "过滤后可见项还是太多（%d）" % visible_items)
	assert_true(matched >= 1, "过滤后应该还能看到 part_29（名字为空就会挂在这条）")
	win.call("_apply_filter", "")
	win.hide()
	win.queue_free()


func test_preview_window_split_export() -> void:
	# 新功能：每个勾选节点单独一个 .glb
	var s := _script(PREVIEW_SCRIPT)
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	win.call("load_glb", SAMPLE_GLB)
	var tree: Tree = win.get("_tree")
	if tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return

	var dir_path := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir_path)
	for f in DirAccess.get_files_at(dir_path):
		if String(f).begins_with("split_x_") and String(f).ends_with(".glb"):
			DirAccess.remove_absolute(dir_path.path_join(String(f)))

	var picked := 0
	var item: TreeItem = tree.get_root().get_next_in_tree()
	while item != null and picked < 2:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			item.set_checked(0, true)
			picked += 1
		item = item.get_next_in_tree()
	assert_eq(picked, 2, "没能在树里勾上 2 个节点")
	assert_eq((win.call("_checked_nodes") as Array).size(), 2, "勾选数不对")

	var edit: LineEdit = win.get("_path_edit")
	edit.text = "%s/split_x.glb" % dir_path
	win.call("_on_export", true)
	var status := String((win.get("_status") as Label).text)
	var made := 0
	for f in DirAccess.get_files_at(dir_path):
		if String(f).begins_with("split_x_") and String(f).ends_with(".glb"):
			made += 1
	print("[GLB 工具] 拆分导出：%s；生成 %d 个文件" % [status, made])
	assert_eq(made, 2, "勾了 2 个节点，应该拆出 2 个 glb")
	win.hide()
	win.queue_free()


func test_filesystem_menu_opens_preview() -> void:
	var s := _script(FS_MENU_SCRIPT)
	assert_true(s != null, "filesystem_menu.gd 加载失败")
	if s == null:
		return
	var menu: EditorContextMenuPlugin = s.new()
	assert_eq(String(menu.call("_first_glb", PackedStringArray(["a.png", "b.glb"]))), "b.glb",
			"应该认出路径里的 .glb")
	assert_eq(String(menu.call("_first_glb", PackedStringArray(["a.png"]))), "", "非 glb 不该被选中")

	menu.call("_on_open", PackedStringArray([SAMPLE_GLB]))
	var win := _find_preview_window()
	assert_true(win != null, "菜单回调之后没出现预览窗口")
	if win != null:
		print("[GLB 工具] 预览窗口 title=%s visible=%s" % [win.title, win.visible])
		win.hide()
		win.queue_free()


func test_preview_window_size_theme_pick() -> void:
	var s := _script(PREVIEW_SCRIPT)
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)

	# ① 尺寸：屏幕 80% 左右（用户要求参考原版对话框）
	var screen := DisplayServer.screen_get_size()
	print("[GLB 工具] 预览窗口 %s / 屏幕 %s" % [str(win.size), str(screen)])
	assert_true(win.size.x >= int(screen.x * 0.7), "窗口宽度应接近屏幕 80%%，实际 %d" % win.size.x)

	# ② 窗体底色：必须铺了 PanelContainer 盖住默认主题那层蓝色窗口底
	var panel: Node = win.get_child(0) if win.get_child_count() > 0 else null
	assert_true(panel is PanelContainer, "窗口第一层应该是 PanelContainer（用来盖掉默认主题的蓝底）")
	if panel is PanelContainer:
		assert_true((panel as PanelContainer).has_theme_stylebox_override("panel"),
				"PanelContainer 没覆盖样式，盖不住蓝底")
		# 底色必须是**写死的灰**（用户要求："要不你写死灰色吧"）：r≈g≈b
		var sb := (panel as PanelContainer).get_theme_stylebox("panel")
		if sb is StyleBoxFlat:
			var c := (sb as StyleBoxFlat).bg_color
			print("[GLB 工具] 窗口底色 = %s" % str(c))
			assert_true(absf(c.r - c.b) < 0.05 and absf(c.g - c.b) < 0.05,
					"窗口底色不是灰的（%s）" % str(c))

	win.call("load_glb", SAMPLE_GLB)
	# 默认输出目录必须固定是 res://assets/models/exported（不能因为"上次导出到别处"而变）
	var path_text := String((win.get("_path_edit") as LineEdit).text)
	print("[GLB 工具] 默认输出：", path_text)
	assert_true(path_text.begins_with("res://assets/models/exported/"),
			"默认输出目录应为 res://assets/models/exported/，实际 %s" % path_text)

	var cam: Camera3D = win.get("_camera")
	var tree: Tree = win.get("_tree")
	if cam == null or tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return

	# ③ 点树选节点：镜头**不许动**（用户明确要求"别跳来跳去"）
	var before := cam.global_position
	var item: TreeItem = tree.get_root().get_next_in_tree()
	var target_item: TreeItem = null
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			target_item = item
			break
		item = item.get_next_in_tree()
	assert_true(target_item != null, "树里没有可勾选节点")
	if target_item == null:
		win.hide()
		win.queue_free()
		return
	tree.set_selected(target_item, 0)
	win.call("_on_item_selected")
	print("[GLB 工具] 选节点前后镜头：%s → %s" % [str(before), str(cam.global_position)])
	assert_true(cam.global_position.distance_to(before) < 0.0001,
			"点树选节点时镜头动了（应保持不动）")
	var node: Node3D = target_item.get_metadata(0)
	# 用户要求（第二次澄清）：**点名字 → 对应模型高亮**，橙色线框
	var hboxes: Array = win.get("_highlight_boxes")
	print("[GLB 工具] 点名字后高亮框数 = %d" % hboxes.size())
	assert_eq(hboxes.size(), 1, "点名字后应该出现 1 个高亮框（就是被点的那个节点）")
	if hboxes.size() >= 1:
		var hh := hboxes[0] as Node3D
		var hm: StandardMaterial3D = null
		for ch in hh.get_children():
			if ch is MeshInstance3D:
				hm = (ch as MeshInstance3D).material_override as StandardMaterial3D
		assert_true(hm != null, "高亮框里没有网格/材质")
		if hm != null:
			print("[GLB 工具] 被点击节点的高亮色 = %s" % str(hm.albedo_color))
			assert_true(hm.albedo_color.r > hm.albedo_color.b, "被点击的节点应该用橙色线框")
	var detail := String((win.get("_details") as Label).text)
	assert_true(detail.contains(String(node.name)), "详情里没显示节点名：%s" % detail)

	# ④ 3D 点选：朝该节点中心打射线，应该选中它
	var center: Vector3 = node.global_transform * node.get_aabb().get_center()
	var dir := (center - cam.global_position).normalized()
	var hit: Node3D = win.call("_pick_node", cam.global_position, dir)
	print("[GLB 工具] 射线点选 -> %s（期望 %s）" % [str(hit), String(node.name)])
	assert_true(hit == node, "3D 射线点选没选中目标节点")
	win.call("_select_node_in_tree", node)
	var sel := tree.get_selected()
	assert_true(sel != null and sel.get_metadata(0) == node, "3D 点选后树里的选中项没同步")

	# ⑤ 多选勾选 → 每个被勾选的节点都要有蓝色线框（用户要求"节点多选也要同时高亮"）
	var picked := 0
	var it: TreeItem = tree.get_root().get_next_in_tree()
	while it != null and picked < 3:
		if it.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			it.set_checked(0, true)
			picked += 1
		it = it.get_next_in_tree()
	win.call("_on_item_edited")            # 模拟点勾选框触发的刷新
	var boxes: Array = win.get("_highlight_boxes")
	print("[GLB 工具] 勾选 %d 个 → 高亮框 %d 个" % [picked, boxes.size()])
	assert_eq(boxes.size(), picked, "勾选几个就该有几个高亮框")
	var blue := 0
	var orange := 0
	for bx2 in boxes:
		var h3 := bx2 as Node3D
		var m3: StandardMaterial3D = null
		for c4 in h3.get_children():
			if c4 is MeshInstance3D:
				m3 = (c4 as MeshInstance3D).material_override as StandardMaterial3D
				break
		if m3 == null:
			continue
		if m3.albedo_color.b > m3.albedo_color.r:
			blue += 1
		elif m3.albedo_color.r > m3.albedo_color.b:
			orange += 1
	print("[GLB 工具] 高亮配色：橙色(仅被点击) %d 个 / 蓝色(被勾选) %d 个" % [orange, blue])
	assert_true(blue >= 1, "被勾选的节点应该有蓝色线框")
	# 这里被点击的节点也在勾选集合里 → 用户要求"选中(勾选)效果优先"，所以不该有橙框
	assert_eq(orange, 0, "同时被点击和勾选时应该用蓝色（勾选优先）")
	# 全不选之后：勾选带来的高亮没了，但**被点中的那个节点**依旧高亮（新语义）
	win.call("_on_check_tool", 0)
	var left: Array = win.get("_highlight_boxes")
	print("[GLB 工具] 全不选后剩余高亮框 = %d（应为 1 = 当前点中的节点，且回到橙色）" % left.size())
	assert_eq(left.size(), 1, "全不选后应只剩「被点中节点」那一个高亮框")
	if left.size() == 1:
		var lo: StandardMaterial3D = null
		for c5 in (left[0] as Node3D).get_children():
			if c5 is MeshInstance3D:
				lo = (c5 as MeshInstance3D).material_override as StandardMaterial3D
		assert_true(lo != null and lo.albedo_color.r > lo.albedo_color.b,
				"不再被勾选后应回到橙色（点击色）")
	win.hide()
	win.queue_free()

func test_preview_window_props_panel() -> void:
	# 右侧只读属性面板（参考原版"高级导入设置"）
	var s := _script(PREVIEW_SCRIPT)
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	win.call("load_glb", SAMPLE_GLB)
	var tree: Tree = win.get("_tree")
	var props: Tree = win.get("_props")
	assert_true(props != null, "没有右侧属性面板")
	if props == null or tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return

	var item: TreeItem = tree.get_root().get_next_in_tree()
	var target: TreeItem = null
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			target = item
			break
		item = item.get_next_in_tree()
	assert_true(target != null, "没找到可勾选节点")
	if target == null:
		win.hide()
		win.queue_free()
		return
	tree.set_selected(target, 0)
	win.call("_on_item_selected")

	var root: TreeItem = props.get_root()
	assert_true(root != null and root.get_child_count() > 0, "属性面板是空的")
	var keys := PackedStringArray()
	var editable_cells := 0
	var it: TreeItem = root
	while it != null:
		keys.append(String(it.get_text(0)))
		if it.is_editable(0) or it.is_editable(1):
			editable_cells += 1
		it = it.get_next_in_tree()
	var dump := FileAccess.open("user://zz_props.txt", FileAccess.WRITE)
	if dump != null:
		dump.store_string("属性条目：%s\n" % ", ".join(keys))
		dump.close()
	print("[GLB 工具] 属性面板 %d 项：%s" % [keys.size(), ", ".join(keys)])
	assert_true(keys.has("名称"), "属性面板缺 名称")
	assert_true(keys.has("三角面"), "属性面板缺 三角面（网格信息）")
	assert_true(keys.has("材质 0"), "属性面板缺 材质 0（材质信息）")
	assert_true(keys.has("世界位置"), "属性面板缺 世界位置（变换信息）")
	assert_eq(editable_cells, 0, "属性面板必须只读（有 %d 个可编辑格）" % editable_cells)
	# 布局：按**结构**断言（测试里窗口没 popup，控件坐标不可靠，所以别看 global_position）
	var vbc := _find_viewport_container(win)
	assert_true(vbc != null, "找不到 3D 预览容器")
	if vbc != null:
		var split := vbc.get_parent()
		assert_true(split is SplitContainer, "预览不在分栏里")
		assert_true(props.get_parent() != null and props.get_parent().get_parent() == split,
				"属性面板应该和预览在同一层分栏里")
		assert_true(vbc.get_index() < props.get_parent().get_index(),
				"属性面板应该排在预览右边（分栏顺序）")
	win.hide()
	win.queue_free()

func _find_viewport_container(n: Node) -> SubViewportContainer:
	if n is SubViewportContainer:
		return n as SubViewportContainer
	for c in n.get_children():
		var r := _find_viewport_container(c)
		if r != null:
			return r
	return null

func test_preview_window_check_column_separate() -> void:
	# 用户要求：点勾选框才勾选，点名字只高亮。
	# 做法是拆列：第 0 列只放勾选框（窄且无文字），第 1 列才是名字且不可编辑，
	# 这样点名字不可能触发勾选（Godot 的 CHECK 单元格是整格可点的）。
	var s := _script(PREVIEW_SCRIPT)
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	win.call("load_glb", SAMPLE_GLB)
	var tree: Tree = win.get("_tree")
	assert_true(tree != null, "没有节点树")
	if tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return
	assert_eq(tree.columns, 3, "树应该是 3 列（勾选框 / 名称 / 信息）")

	var item: TreeItem = tree.get_root().get_next_in_tree()
	var found: TreeItem = null
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			found = item
			break
		item = item.get_next_in_tree()
	assert_true(found != null, "没找到可勾选节点")
	if found == null:
		win.hide()
		win.queue_free()
		return
	print("[GLB 工具] 勾选列 text='%s' 可编辑=%s ｜ 名字列 text='%s' 可编辑=%s" % [
			found.get_text(0), str(found.is_editable(0)), found.get_text(1), str(found.is_editable(1))])
	assert_eq(found.get_cell_mode(0), TreeItem.CELL_MODE_CHECK, "第 0 列应该是勾选框")
	assert_eq(String(found.get_text(0)), "", "勾选框那列不能有文字（否则点名字也会连带勾上）")
	assert_true(found.is_editable(0), "勾选框列要可编辑（能点勾）")
	assert_false(found.is_editable(1), "名字列不可编辑（点名字只应高亮，不该勾选）")
	assert_true(String(found.get_text(1)).length() > 0, "名字列应该有节点名")

	# 勾选与蓝色高亮联动
	found.set_checked(0, true)
	win.call("_on_item_edited")
	assert_eq((win.get("_highlight_boxes") as Array).size(), 1, "勾上 1 个应该正好 1 个高亮框")
	win.hide()
	win.queue_free()

func test_preview_window_highlight_visible() -> void:
	# 只断言"高亮对象存在"是不够的：早期用 1px 的 LINE 画线，对象存在但屏幕上根本看不见。
	# 所以这里真的渲染一帧，数橙色像素。
	var s := _script(PREVIEW_SCRIPT)
	if s == null:
		return
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	win.popup_centered()
	win.call("load_glb", SAMPLE_GLB)
	var tree: Tree = win.get("_tree")
	if tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return

	# 勾最后一个可勾选节点（通常是最小的零件，框也小，最能验证"贴不贴")
	var item: TreeItem = tree.get_root().get_next_in_tree()
	var target: TreeItem = null
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			target = item
		item = item.get_next_in_tree()
	assert_true(target != null, "没找到可勾选节点")
	if target == null:
		win.hide()
		win.queue_free()
		return
	target.set_checked(0, true)
	# 顺便把第一个可勾选节点（通常是地面那种大件）也勾上：它的框大，确保画面上一定有橙色
	var big: TreeItem = tree.get_root().get_next_in_tree()
	while big != null:
		if big.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			big.set_checked(0, true)
			break
		big = big.get_next_in_tree()
	win.call("_rebuild_highlights")
	var boxes: Array = win.get("_highlight_boxes")
	assert_true(boxes.size() >= 1, "应该有高亮框")

	# 线框尺寸要贴着节点，不能变成"整个模型大小"或"1×1×1 大方块"（两种都踩过）
	var node: Node3D = target.get_metadata(0)
	var want: Vector3 = ((node.global_transform * node.get_aabb()).size)
	# 勾了两个节点，所以有两个框；要求其中**有一个**贴合小节点的 AABB
	var want_len := want.length()
	var best := INF
	var sizes := PackedStringArray()
	for bx in boxes:
		var h2 := bx as Node3D
		var fb := AABB()
		var f2 := true
		for c3 in h2.get_children():
			if c3 is MeshInstance3D and (c3 as MeshInstance3D).mesh != null:
				var b3: AABB = (c3 as MeshInstance3D).mesh.get_aabb()
				if f2:
					fb = b3
					f2 = false
				else:
					fb = fb.merge(b3)
		if not f2:
			sizes.append(str(fb.size))
			best = minf(best, absf(fb.size.length() - want_len))
	print("[GLB 工具] 各高亮框 size=%s ｜ 小节点 AABB=%s ｜ 最小偏差=%.4f" % [
			" / ".join(sizes), str(want), best])
	# 线框本身的粗细会撑大 AABB，精确比对很脆；这里只守一条底线：不能出现"整模型大小"的框
	# （早期 bug：SurfaceTool 没吃变换，画成 1×1×1 的大方块）
	# 用 LINE 画棱后没有"粗细"撑大 AABB，可以收紧判定
	assert_true(best < maxf(want_len * 0.25, 0.02), "高亮框没有贴在节点上（最小偏差 %.3f）" % best)

	# 真渲染一帧，数橙色像素
	var vp: SubViewport = win.get("_viewport")
	if vp.get_parent() is SubViewportContainer:
		(vp.get_parent() as SubViewportContainer).size = Vector2i(640, 480)
	RenderingServer.force_draw(false)
	var img: Image = vp.get_texture().get_image()
	# 把高亮藏起来再画一帧，两帧必须不同 —— 比"数某种颜色的像素"更可靠（线很细也不会漏判）
	for bx3 in boxes:
		(bx3 as Node3D).visible = false
	RenderingServer.force_draw(false)
	var img2: Image = vp.get_texture().get_image()
	# 线宽恒定 1 像素，抽样会漏，所以逐像素比对（发现第一处差异就停，够快）
	var diff := 0
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y) != img2.get_pixel(x, y):
				diff += 1
				break
		if diff > 0:
			break
	print("[GLB 工具] 有高亮 vs 无高亮：%s" % ("画面确实不同（高亮渲染出来了）" if diff > 0 else "完全相同（高亮没渲染）"))
	assert_true(diff > 0, "开关高亮对画面没有影响 —— 说明高亮根本没渲染出来")
	win.hide()
	win.queue_free()

func test_preview_window_node_context_export() -> void:
	# 用户要求：在选中的节点上右键 → 能导出 → 弹出导出确认框
	var s := _script(PREVIEW_SCRIPT)
	if s == null:
		return
	_close_plugin_windows()
	var win: Window = s.new()
	EditorInterface.get_base_control().add_child(win)
	win.call("load_glb", SAMPLE_GLB)
	var tree: Tree = win.get("_tree")
	if tree == null or tree.get_root() == null:
		win.hide()
		win.queue_free()
		return
	var item: TreeItem = tree.get_root().get_next_in_tree()
	var target: TreeItem = null
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			target = item
			break
		item = item.get_next_in_tree()
	assert_true(target != null, "没找到可勾选节点")
	if target == null:
		win.hide()
		win.queue_free()
		return

	# ① 弹菜单
	win.call("_show_node_menu", target, Vector2(20, 20))
	var menu: PopupMenu = win.get("_node_menu")
	assert_true(menu != null, "没有右键菜单")
	var texts := PackedStringArray()
	if menu != null:
		for i in menu.item_count:
			texts.append(menu.get_item_text(i))
	print("[GLB 工具] 右键菜单：%s" % " / ".join(texts))
	assert_true(texts.size() >= 2, "右键菜单项太少")
	assert_true(String(texts[0]).contains("导出"), "第一项应该是导出此节点：%s" % String(texts[0]))
	if menu != null:
		# 位置应当以**屏幕坐标**为基准（用地局部坐标会飘）
		print("[GLB 工具] 菜单 position=%s 期望=%s" % [
				str(menu.position), str(Vector2i(tree.get_screen_position() + Vector2(20, 20)))])
		assert_eq(menu.position, Vector2i(tree.get_screen_position() + Vector2(20, 20)),
				"右键菜单位置没用屏幕坐标")
		menu.hide()

	# ② 选「导出此节点为 GLB…」→ 必须弹出导出确认框
	win.call("_on_node_menu", 0)
	var dlg := _find_export_dialog()
	assert_true(dlg != null, "右键导出没有弹出确认框")
	if dlg != null:
		print("[GLB 工具] 导出确认框 title=%s 父节点=%s" % [dlg.title, str(dlg.get_parent())])
		# 用户反馈：弹确认框时预览窗口被关掉了 → 确认框必须挂在预览窗口下，且预览窗口仍然可见
		assert_true(dlg.get_parent() == win, "确认框应该挂在预览窗口下（否则会把预览窗口顶掉）")
		assert_true(win.visible, "弹出确认框后预览窗口不该被关闭")
		# 确认框里必须有"合并 / 单独"的选择
		var split_box := _find_checkbox_containing(dlg, "单独")
		assert_true(split_box != null, "导出确认框缺少「每个节点单独一个文件」选项")
		if split_box != null:
			print("[GLB 工具] 确认框选项：%s" % split_box.text)
		dlg.hide()
		dlg.queue_free()

	# ③ 选「导出勾选的 N 个」→ 也要弹框，且默认目录是 resources 下的 exported
	target.set_checked(0, true)
	win.call("_on_node_menu", 1)
	var dlg2 := _find_export_dialog()
	assert_true(dlg2 != null, "导出勾选没有弹出确认框")
	if dlg2 != null:
		var path_edit := _find_line_edit_starting_with(dlg2, "res://assets/models/exported/")
		assert_true(path_edit != null, "确认框里的默认输出目录不是 res://assets/models/exported/")
		dlg2.hide()
		dlg2.queue_free()
	win.hide()
	win.queue_free()


func _find_line_edit_starting_with(root: Node, prefix: String) -> LineEdit:
	if root is LineEdit and String((root as LineEdit).text).begins_with(prefix):
		return root as LineEdit
	for c in root.get_children():
		var r := _find_line_edit_starting_with(c, prefix)
		if r != null:
			return r
	return null

func _find_checkbox_containing(root: Node, text: String) -> CheckBox:
	if root is CheckBox and String((root as CheckBox).text).contains(text):
		return root as CheckBox
	for c in root.get_children():
		var r := _find_checkbox_containing(c, text)
		if r != null:
			return r
	return null
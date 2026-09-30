@tool
extends McpTestSuite
## 「图片清单」插件自检：扫描 / 导入设置解析 / 面板构建 / 重新导入提交。

const SCAN := "res://addons/image_tools/image_scan.gd"
const PANEL := "res://addons/image_tools/image_list_panel.gd"


func suite_name() -> String:
	return "image_tools"


func _load(path: String) -> GDScript:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func test_scan_lists_images() -> void:
	var s := _load(SCAN)
	assert_true(s != null, "扫描核心加载失败")
	if s == null:
		return
	var rows: Array = s.call("scan", "res://assets", true)
	print("[图片清单] 扫描 res://assets 得到 %d 个图片文件" % rows.size())
	assert_true(rows.size() > 0, "没扫到任何图片")
	if rows.is_empty():
		return
	# 每项字段齐全
	var first: Dictionary = rows[0]
	for key in ["path", "size", "has_import", "mode", "mode_name", "mipmaps", "imported"]:
		assert_true(first.has(key), "结果项缺少字段 %s" % key)
	# 按路径有序
	var sorted_ok := true
	for i in range(1, rows.size()):
		if String((rows[i - 1] as Dictionary)["path"]) > String((rows[i] as Dictionary)["path"]):
			sorted_ok = false
			break
	assert_true(sorted_ok, "结果没有按路径排序")
	# 样本
	for i in range(mini(3, rows.size())):
		var r: Dictionary = rows[i]
		print("   %s ｜ %s ｜ %s ｜ mipmaps=%s ｜ %s" % [
				String(r["path"]), s.call("human_size", int(r["size"])),
				String(r["mode_name"]), str(r["mipmaps"]), String("已导入" if r["imported"] else "未导入")])


func test_import_mode_parsing() -> void:
	var s := _load(SCAN)
	if s == null:
		return
	var rows: Array = s.call("scan", "res://assets", true)
	var with_import := 0
	var vram := 0
	var mip := 0
	var no_import := 0
	for rv in rows:
		var r: Dictionary = rv
		if bool(r["has_import"]):
			with_import += 1
			if int(r["mode"]) == 2:
				vram += 1
			if bool(r["mipmaps"]):
				mip += 1
		else:
			no_import += 1
	print("[图片清单] 有导入设置 %d ｜ 其中 VRAM 压缩 %d ｜ 开 mipmaps %d ｜ 无导入设置 %d" % [
			with_import, vram, mip, no_import])
	assert_true(with_import > 0, "一个有导入设置的图片都没有，解析可能失败")
	assert_true(vram > 0, "没有解析出任何 VRAM 压缩（此前已批量设过，应该有）")
	# 抽查一个真实文件，核对 mode_name 的映射
	for rv in rows:
		var r: Dictionary = rv
		if bool(r["has_import"]) and int(r["mode"]) == 2:
			print("   抽查 %s → %s" % [String(r["path"]), String(r["mode_name"])])
			assert_true(String(r["mode_name"]).contains("VRAM"), "mode=2 应显示为 VRAM 压缩")
			break
	# 名称映射本身
	assert_true(String(s.MODE_NAMES[0]).contains("Lossless"), "mode=0 名称不对")
	assert_true(String(s.MODE_NAMES[2]).contains("VRAM"), "mode=2 名称不对")


func test_panel_builds_and_scans() -> void:
	var ps := _load(PANEL)
	assert_true(ps != null, "面板脚本加载失败")
	if ps == null:
		return
	var p: Control = ps.new()
	EditorInterface.get_base_control().add_child(p)
	# 找 Tree 并核对列
	var tree: Tree = null
	for c in p.get_children():
		if c is Tree:
			tree = c
	assert_true(tree != null, "面板里没有 Tree")
	if tree != null:
		assert_eq(tree.columns, 6, "Tree 列数应为 6")
		assert_true(tree.hide_root, "Tree 应隐藏根节点")
	# 扫描一个小目录（快），确认能填表
	p.set("_root_edit", p.get("_root_edit"))     # no-op，保持接口稳定
	var edit: LineEdit = p.get("_root_edit")
	if edit != null:
		edit.text = "res://assets/textures"
	p.call("_on_scan")
	var status: Label = p.get("_status")
	assert_true(status != null, "面板里没有状态标签")
	if status != null:
		print("[图片清单] 面板状态：" + status.text)
		assert_true(status.text.contains("扫描完成"), "面板没执行扫描：" + status.text)
	assert_true(tree != null and tree.get_root() != null, "Tree 里没有内容")
	p.queue_free()


func test_reimport_can_be_queued() -> void:
	var ps := _load(PANEL)
	var s := _load(SCAN)
	if ps == null or s == null:
		return
	var rows: Array = s.call("scan", "res://assets/textures", true)
	assert_true(rows.size() > 0, "没有可用于测试的图片")
	if rows.is_empty():
		return
	# 挑一个最小的文件来提交重新导入（避免拖慢测试）
	var pick: Dictionary = rows[0]
	for rv in rows:
		var r: Dictionary = rv
		if int(r["size"]) < int(pick["size"]):
			pick = r
	print("[图片清单] 提交重新导入：%s（%s）" % [String(pick["path"]), s.call("human_size", int(pick["size"]))])
	var r2: Dictionary = ps.call("reimport", PackedStringArray([String(pick["path"])]))
	print("   结果 = %s" % str(r2))
	assert_eq(int(r2["queued"]), 1, "应当提交 1 个重新导入")
	assert_true(String(r2["via"]).length() > 0, "没报告使用的通道")
	# 空列表应当安全
	var r3: Dictionary = ps.call("reimport", PackedStringArray())
	assert_eq(int(r3["queued"]), 0, "空列表不该提交任何东西")

func test_format_filter_excludes_exr() -> void:
	# 需求：插件只处理常规图片，**不要处理 exr 等其他文件**，并提供格式过滤器。
	var s := _load(SCAN)
	if s == null:
		return
	var def: Array = s.DEFAULT_EXT
	assert_true(def.has("png") and def.has("jpg"), "默认格式里应有 png/jpg")
	assert_true(not def.has("exr"), "默认格式里**不该**有 exr")
	assert_true(not def.has("dds") and not def.has("psd"), "默认格式里不该有 dds/psd 之类")

	# 用默认过滤扫真实目录（那里确实有 exr）
	var rows: Array = s.call("scan", "res://assets/textures", true, [])
	var exr := 0
	for rv in rows:
		if String((rv as Dictionary)["path"]).to_lower().ends_with(".exr"):
			exr += 1
	var only_exr: Array = s.call("scan", "res://assets/textures", true, ["exr"])
	print("[图片清单] 默认过滤扫到 %d 个（其中 exr %d 个）｜ 只筛 exr 得到 %d 个" % [
			rows.size(), exr, only_exr.size()])
	assert_eq(exr, 0, "默认过滤不该扫出 exr")
	# 不依赖"目录里恰好有 exr"（用户把 EXR 收进回收站后就会失效 ✗）——
	# 只断言**过滤语义**：筛 exr 时结果里绝不能混进非 exr ✓（0 个也算正确 ✓）
	var all_exr := true
	for rv in only_exr:
		if not String((rv as Dictionary)["path"]).to_lower().ends_with(".exr"):
			all_exr = false
	print("[图片清单] 只筛 exr → %d 个（为 0 也正常：EXR 已被收进 .runtime 回收站 ✓）" % only_exr.size())
	assert_true(all_exr, "筛 exr 的结果里混进了非 exr ✗")

	# 过滤器解析
	var p: Array = s.call("parse_filter", " PNG , jpg ,, JpEg ,.webp")
	print("[图片清单] parse_filter -> %s" % str(p))
	assert_eq(p.size(), 4, "应解析出 4 种格式")
	assert_true(p.has("png") and p.has("jpeg") and p.has("webp"), "解析结果不对")
	assert_true(not p.has(".webp"), "应去掉前导点")

func test_path_uses_picker_not_typing() -> void:
	# 需求：路径不要让人手填，要文件选择器。
	var ps := _load(PANEL)
	assert_true(ps != null, "面板脚本加载失败")
	if ps == null:
		return
	var p: Control = ps.new()
	EditorInterface.get_base_control().add_child(p)

	# ① 路径框必须不可编辑
	var edit: LineEdit = p.get("_root_edit")
	assert_true(edit != null, "找不到路径框")
	if edit != null:
		assert_true(not edit.editable, "路径框不该允许手打（应由选择器填写）")
		print("[图片清单] 路径框可编辑 = %s（应为 false）" % str(edit.editable))

	# ② 必须存在"选择目录"按钮，且点击会打开选择器（这里只验按钮在，不真的弹窗）
	var pick: Button = null
	for c in p.get_children():
		if c is HBoxContainer:
			for cc in (c as HBoxContainer).get_children():
				if cc is Button and String((cc as Button).text).contains("选择目录"):
					pick = cc as Button
	assert_true(pick != null, "没有找到「选择目录」按钮")
	assert_true(p.has_method("_pick_dir"), "没有 _pick_dir 方法")
	assert_true(p.has_method("_on_dir_picked"), "没有选择结果处理函数")

	# ③ 选择结果要写进路径框并立刻扫描（不弹窗，直接调回调）
	if edit != null:
		p.call("_on_dir_picked", "res://assets/textures")
		assert_eq(String(edit.text), "res://assets/textures", "选完目录没写进路径框")
		var status: Label = p.get("_status")
		assert_true(status != null and String(status.text).contains("扫描完成"),
				"选完目录应当立刻扫描：" + (String(status.text) if status != null else "?"))
		print("[图片清单] 选择目录后状态：" + (String(status.text) if status != null else "?"))
	p.queue_free()

func test_imported_status_detects_real_imports() -> void:
	# 回归：曾经扫 res://.godot/imported（点目录在资源层不可见 ✗）→ 前缀集合为空
	# → **所有图片都被误报成「未导入」**（用户截图里 48/48 全错 ✗）。
	# 之前我只断言了"有导入设置的图片数 > 0" ✗，**没断言 imported 为真** ✗ —— 所以漏了。
	var s := _load(SCAN)
	if s == null:
		return
	var rows: Array = s.call("scan", "res://assets/textures", true, [])
	var imported := 0
	var with_import := 0
	for rv in rows:
		var r: Dictionary = rv
		if bool(r["has_import"]):
			with_import += 1
			if bool(r["imported"]):
				imported += 1
	print("[图片清单] 有 .import 的 %d 个 ｜ 其中判定为已导入的 %d 个" % [with_import, imported])
	assert_true(with_import > 0, "样本目录里没有带 .import 的图片？")
	assert_true(imported > 0, "真实贴图居然全被判成未导入 —— 判定逻辑坏了 ✗")
	assert_true(imported == with_import, "有 .import 且产物齐备的，全部都应判为已导入（现在 %d/%d）" % [imported, with_import])
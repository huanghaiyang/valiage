@tool
extends McpTestSuite
## 图片转换插件自检（格式 / 分辨率 / 移除 alpha / 一键生成 2K+1K）。

const CONV := "res://addons/image_convert/image_convert.gd"
const TIERS := "res://scripts/quality/quality_tiers.gd"
const SAMPLE := "res://assets/textures/杂草泥土/brown_mud_leaves_01_nor_gl_1k.png"


func suite_name() -> String:
	return "image_convert"


func _load(p: String) -> GDScript:
	return ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _out(n: String) -> String:
	var d := ProjectSettings.globalize_path("user://image_convert_test")
	DirAccess.make_dir_recursive_absolute(d)
	return d.path_join(n)


func test_suffix_rule_matches_quality_system() -> void:
	# 命名规则必须和画质分级系统一致，否则切档找不到文件
	var c := _load(CONV)
	var q := _load(TIERS)
	assert_true(c != null and q != null, "脚本加载失败")
	if c == null or q == null:
		return
	for p in ["res://a/brown_mud_leaves_01_diff_4k.jpg", "res://a/forest_leaves_02_diffuse_4k.jpg", "res://a/x_nor_gl_2048.png"]:
		for s in ["2k", "1k"]:
			var a := String(c.call("swap_res_suffix", p, s))
			var b := String(q.call("swap_resolution_suffix", p, s))
			assert_eq(a, b, "同一路径两套规则算出来不一致：%s" % p)
			print("[图片转换] %s + %s → %s（与画质系统一致 ✓）" % [p.get_file(), s, a.get_file()])


func test_convert_format_size_and_strip_alpha() -> void:
	var c := _load(CONV)
	if c == null:
		return
	assert_true(ResourceLoader.exists(SAMPLE), "样本贴图不存在")
	var src := ProjectSettings.globalize_path(SAMPLE)
	var dst := _out("small_rgb.jpg")
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(dst)
	var r: Dictionary = c.call("convert_file", src, dst, {
		"fmt": 2, "max_size": 512, "strip_alpha": true, "jpg_quality": 90,
	})
	print("[图片转换] %s → %s：%s" % [SAMPLE.get_file(), dst.get_file(), str(r.get("message", ""))])
	assert_true(bool(r.get("ok", false)), "转换失败：" + str(r.get("message", "")))
	assert_true(FileAccess.file_exists(dst), "输出文件没生成")
	var img := Image.load_from_file(dst)
	assert_true(img != null, "读不回输出文件")
	if img != null:
		print("[图片转换] 输出 %s ｜ 格式=%d（应为 RGB8=%d）" % [str(img.get_size()), img.get_format(), Image.FORMAT_RGB8])
		assert_eq(img.get_width(), 512, "宽度应为 512")
		assert_eq(img.get_height(), 512, "高度应为 512")
		assert_eq(img.get_format(), Image.FORMAT_RGB8, "应当是 RGB8（已移除 alpha）")


func test_keep_format_dispatches_by_extension() -> void:
	# 回归：保持原格式时必须按**目标扩展名**分派，否则会把 PNG 数据写进 .jpg
	var c := _load(CONV)
	if c == null:
		return
	var src := ProjectSettings.globalize_path(SAMPLE)
	var dst := _out("keep.jpg")
	var r: Dictionary = c.call("convert_file", src, dst, {"fmt": 0, "max_size": 256, "strip_alpha": false})
	assert_true(bool(r.get("ok", false)), "保持原格式转换失败")
	# JPG 文件头必须是 FFD8（PNG 是 89504E47）
	var f := FileAccess.open(dst, FileAccess.READ)
	assert_true(f != null, "读不到输出")
	if f != null:
		var head := f.get_buffer(4)
		f.close()
		assert_true(head.size() >= 2, "输出文件太小，读不到文件头（说明转换没成功）")
		if head.size() >= 2:
			print("[图片转换] 保持原格式输出头：%02X %02X" % [head[0], head[1]])
			assert_eq(int(head[0]), 0xFF, "首字节应为 0xFF（JPEG 标志）")
			assert_eq(int(head[1]), 0xD8, "第二字节应为 0xD8（JPEG 标志）")


func test_plan_variants() -> void:
	var c := _load(CONV)
	if c == null:
		return
	var plan: Array = c.call("plan_variants", "res://a/brown_mud_leaves_01_diff_4k.jpg", ["2k", "1k"], 0)
	assert_eq(plan.size(), 2, "应生成 2 个计划")
	var names := PackedStringArray()
	for p in plan:
		names.append(String((p as Dictionary)["dst"]).get_file())
	print("[图片转换] 计划输出：%s" % ", ".join(names))
	assert_eq(names[0], "brown_mud_leaves_01_diff_2k.jpg", "2K 命名不对")
	assert_eq(names[1], "brown_mud_leaves_01_diff_1k.jpg", "1K 命名不对")


func test_dir_and_filter_helpers() -> void:
	var c := _load(CONV)
	if c == null:
		return
	assert_true(bool(c.call("is_image", "a/b.png")), "png 应被认作图片")
	assert_true(bool(c.call("is_image", "a/b.JPG")), "大写扩展名也应认")
	assert_true(not bool(c.call("is_image", "a/b.glb")), "glb 不该被认作图片")
	var work := ProjectSettings.globalize_path("user://image_convert_test/dir")
	DirAccess.make_dir_recursive_absolute(work)
	# 测试必须幂等：先清空，否则上次跑出来的 t.jpg 会留在里面 → 计数变 2
	for f in DirAccess.get_files_at(work):
		DirAccess.remove_absolute(work.path_join(String(f)))
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE), work.path_join("t.png"))
	FileAccess.open(work.path_join("skip.txt"), FileAccess.WRITE).store_string("x")
	var found: Array = c.call("find_images", work, true)
	print("[图片转换] 目录里找到 %d 个图片" % found.size())
	assert_eq(found.size(), 1, "应当只找到 1 个图片（.txt 不算）")
	var r: Dictionary = c.call("convert_dir", work, {"fmt": 2, "max_size": 256, "strip_alpha": true})
	print("[图片转换] 批量：共 %d 成功 %d" % [int(r["total"]), int(r["ok"])])
	assert_eq(int(r["total"]), 1, "批量总数不对")
	assert_eq(int(r["ok"]), 1, "批量应当成功 1 个")
	assert_true(FileAccess.file_exists(work.path_join("t.jpg")), "批量输出没生成")
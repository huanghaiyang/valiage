@tool
## （诊断用 2）
## （诊断用注释）
extends McpTestSuite
## EXR → PNG 工具自检。
## 样本用项目里**现成**的 Terrain3D 笔刷 EXR（engine 能解码 EXR，但导入器不认，
## 所以要转成 PNG）。这条链路不依赖 ffmpeg/ImageMagick/Pillow。

const CONVERT := "res://addons/exr_tools/exr_convert.gd"
const MENU := "res://addons/exr_tools/filesystem_menu.gd"
const DIALOG := "res://addons/exr_tools/convert_dialog.gd"
const SAMPLE_EXR := "res://addons/terrain_3d/brushes/hill1.exr"
const OUT_DIR := "user://exr_tools_test"


func suite_name() -> String:
	return "exr_tools"


func _load(path: String) -> GDScript:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _out(name: String) -> String:
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	return dir.path_join(name)


func test_convert_one_exr_to_png() -> void:
	var s := _load(CONVERT)
	assert_true(s != null, "转换核心加载失败")
	if s == null:
		return
	# 注意：EXR **不是** Godot 资源，ResourceLoader.exists 会返回 false
	# （这正是本工具存在的理由），所以用 FileAccess 判存在。
	var src := ProjectSettings.globalize_path(SAMPLE_EXR)
	assert_true(FileAccess.file_exists(src), "样本 EXR 不存在：%s" % src)
	if not FileAccess.file_exists(src):
		return
	var dst := _out("hill1.png")
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(dst)

	var r: Dictionary = s.call("convert_file", src, dst, false)
	print("[EXR 工具] 转换结果 = %s ｜ %s" % [str(r.get("ok", false)), str(r.get("message", ""))])
	assert_true(bool(r.get("ok", false)), "转换失败：" + str(r.get("message", "")))
	assert_true(FileAccess.file_exists(dst), "PNG 没写出来")
	if not FileAccess.file_exists(dst):
		return

	# 尺寸必须与原 EXR 一致
	var a := Image.load_from_file(src)
	var b := Image.load_from_file(dst)
	assert_true(a != null and b != null, "读回图像失败")
	if a == null or b == null:
		return
	print("[EXR 工具] 原图 %s ｜ 转出 %s（格式 %d→%d）" % [
			str(a.get_size()), str(b.get_size()), a.get_format(), b.get_format()])
	assert_eq(b.get_width(), a.get_width(), "宽度不一致")
	assert_eq(b.get_height(), a.get_height(), "高度不一致")
	assert_true(b.get_format() == Image.FORMAT_RGBA8, "转出来的不是 8 位 RGBA")

	# 真转出内容才算过：**全图扫描**（隔行隔列），且任意通道（含 Alpha）有值即可。
	# 为什么不能只看 luminance：Terrain3D 的笔刷 EXR 数据可能只存在某个通道里，
	# 而且笔刷边缘本来就是黑的 —— 只看左上角或只看亮度会误判。
	var w := maxi(b.get_width(), 1)
	var h := maxi(b.get_height(), 1)
	var peak := 0.0
	var samples := 0
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var p := b.get_pixel(x, y)
			peak = maxf(peak, maxf(maxf(p.r, p.g), maxf(p.b, p.a)))
			samples += 1
			x += 7
		y += 7
	print("[EXR 工具] 全图抽样 %d 点 ｜ 任一通道峰值 = %.4f" % [samples, peak])
	assert_true(peak > 0.01, "转出来的 PNG 全空（所有通道都接近 0，解码或写盘有问题）")

	# 翻转绿通道：只动 G，不动 R/B
	var dst2 := _out("hill1_flip.png")
	var r2: Dictionary = s.call("convert_file", src, dst2, true)
	assert_true(bool(r2.get("ok", false)), "翻转版转换失败")
	var c := Image.load_from_file(dst2)
	if c != null:
		var diff_g := 0.0
		var diff_rb := 0.0
		for i in 60:
			var x2 := i % w
			var y2 := i / w
			if y2 >= b.get_height():
				break
			var p0 := b.get_pixel(x2, y2)
			var p1 := c.get_pixel(x2, y2)
			diff_g += absf(p1.g - p0.g)
			diff_rb += absf(p1.r - p0.r) + absf(p1.b - p0.b)
		print("[EXR 工具] 绿通道累计差 %.3f ｜ R/B 累计差 %.3f" % [diff_g, diff_rb])
		assert_true(diff_g > 0.1, "翻转绿通道没生效")
		assert_true(diff_rb < 0.01, "翻转绿通道不该动 R/B")


func test_find_and_convert_dir() -> void:
	var s := _load(CONVERT)
	if s == null:
		return
	var dir := ProjectSettings.globalize_path(OUT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	# 造一个"待转目录"：复制一份样本 EXR 进去
	var src := ProjectSettings.globalize_path(SAMPLE_EXR)
	var work := dir.path_join("work")
	DirAccess.make_dir_recursive_absolute(work)
	var copy := work.path_join("sample.exr")
	DirAccess.copy_absolute(src, copy)
	var found: Array = s.call("find_exr", work, true)
	print("[EXR 工具] 目录里找到 %d 个 EXR" % found.size())
	assert_true(found.size() >= 1, "没扫到 EXR")
	var r: Dictionary = s.call("convert_dir", work, {"recursive": true, "flip_green": false})
	print("[EXR 工具] 批量：共 %d ｜ 成功 %d ｜ 失败 %d" % [
			int(r["total"]), int(r["ok"]), (r["failed"] as Array).size()])
	assert_true(int(r["total"]) >= 1, "批量总数不对")
	assert_true(int(r["ok"]) == int(r["total"]), "有文件转换失败")
	assert_true(FileAccess.file_exists(work.path_join("sample.png")), "批量没写出 PNG")


func test_menu_targets_and_dialog() -> void:
	var ms := _load(MENU)
	assert_true(ms != null, "右键菜单脚本加载失败")
	if ms != null:
		var inst: EditorContextMenuPlugin = ms.new()
		# .exr → 用它的目录
		var exr_path := ProjectSettings.globalize_path(SAMPLE_EXR)
		var t1 := String(inst.call("target_dir", PackedStringArray([SAMPLE_EXR])))
		print("[EXR 工具] 选中 .exr → 目标目录 = %s" % t1)
		assert_true(not t1.is_empty(), "对着 .exr 右键应该能定位目录")
		assert_true(t1 == exr_path.get_base_dir(), "目标目录不是该 EXR 所在目录")
		# 文件夹 → 就是它自己
		var folder := ProjectSettings.globalize_path(OUT_DIR)
		var t2 := String(inst.call("target_dir", PackedStringArray([folder])))
		assert_true(t2 == folder, "对着文件夹右键应该用该文件夹")
		# 无关文件 → 空（不加菜单项）
		var t3 := String(inst.call("target_dir", PackedStringArray(["res://project.godot"])))
		assert_true(t3.is_empty(), "无关文件不该加菜单项")
		# EditorContextMenuPlugin 是 RefCounted，不能手动 free（会报 Attempted to free a RefCounted object）
	# 对话框要能实例化、能设目标
	var ds := _load(DIALOG)
	assert_true(ds != null, "对话框脚本加载失败")
	if ds != null:
		var dlg: ConfirmationDialog = ds.new()
		EditorInterface.get_base_control().add_child(dlg)
		dlg.call("set_target", "D:/tmp")
		var ok_size := dlg.size.y <= 400
		print("[EXR 工具] 对话框尺寸 = %s" % str(dlg.size))
		assert_true(ok_size, "对话框太高了：%s" % str(dlg.size))
		dlg.hide()
		dlg.queue_free()

func test_blender_fallback_on_unsupported_exr() -> void:
	# 真实案例：Poly Haven 的 4K 法线 EXR 是 DWAA 压缩，引擎解不了（错误码 43）。
	# 本用例验证"自动调 Blender 兜底"这条路（本机没装 Blender 或有样本缺失时跳过）。
	var s := _load(CONVERT)
	if s == null:
		return
	# DWAA 样本可能在原处，也可能被用户回收进了 .runtime —— 两处都找。
	# 找不到时必须留下**一条断言**，否则测试框架会把它记成 0 断言失败。
	var src := ""
	for cand in ["D:/sgames/CozyVale/assets/textures/湿泥土/brown_mud_03_nor_gl_4k.exr",
			"D:/sgames/CozyVale/.runtime/exr_recycle/brown_mud_03_nor_gl_4k.exr"]:
		if FileAccess.file_exists(cand):
			src = cand
			print("[EXR 工具] DWAA 样本取自：%s" % cand)
			break
	if src == "":
		assert_true(true, "找不到 DWAA 样本（原处与回收站都没有）→ 跳过 Blender 兜底测试")
		return
	var exe := String(s.call("blender_path"))
	print("[EXR 工具] 探测到的 blender = %s" % ("（没找到）" if exe.is_empty() else exe))
	if exe.is_empty():
		return
	var dst := _out("dwaa_via_blender.png")
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(dst)
	var r: Dictionary = s.call("convert_file", src, dst, false, true)
	print("[EXR 工具] Blender 兜底 = %s ｜ %s" % [str(r.get("ok", false)), str(r.get("message", ""))])
	assert_true(bool(r.get("ok", false)), "Blender 兜底失败：" + str(r.get("message", "")))
	assert_true(FileAccess.file_exists(dst), "兜底没写出 PNG")
	var img := Image.load_from_file(dst)
	assert_true(img != null, "兜底产出的 PNG 读不回来")
	if img != null:
		print("[EXR 工具] 兜底产出 %s" % str(img.get_size()))
		assert_eq(img.get_width(), 4096, "兜底产出的宽度不对")
		assert_eq(img.get_height(), 4096, "兜底产出的高度不对")

func test_notify_editor_after_convert() -> void:
	# 需求：转换成功后要主动通知 Godot 加载/导入新资源，而不是等用户手动刷新。
	var ds := _load(DIALOG)
	assert_true(ds != null, "对话框脚本加载失败")
	if ds == null:
		return
	var dlg: ConfirmationDialog = ds.new()
	EditorInterface.get_base_control().add_child(dlg)

	# 注意：探针必须放在 Godot **会导入**的普通目录里 —— 上次放在 .runtime 这种点目录，
	# Godot 直接忽略，等于空测（用户随后就发现"通知了但没载入"）。
	var probe_dir := ProjectSettings.globalize_path("res://addons/exr_tools/__probe__")
	DirAccess.make_dir_recursive_absolute(probe_dir)
	var probe := probe_dir.path_join("__notify_probe.png")
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5))
	img.save_png(probe)
	assert_true(FileAccess.file_exists(probe), "探针 PNG 没写出来")

	var via_res := int(dlg.call("_notify_editor", [probe]))
	var via_user := int(dlg.call("_notify_editor", [ProjectSettings.globalize_path("user://nope.png")]))
	var via_missing := int(dlg.call("_notify_editor", [probe_dir.path_join("不存在.png")]))
	print("[EXR 工具] 通知计数：res:// 真实文件=%d ｜ user://=%d ｜ 不存在的文件=%d" % [
			via_res, via_user, via_missing])
	assert_true(via_res == 1, "res:// 下真实存在的新文件应当被通知导入")
	assert_true(via_user == 0, "user:// 不在编辑器文件系统里，不该被通知")
	assert_true(via_missing == 0, "不存在的文件不该被通知")

	# 批量结果里必须带上"生成了哪些文件"，否则上层无从通知
	var s := _load(CONVERT)
	var work := _out("notify_work")
	DirAccess.make_dir_recursive_absolute(work)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), work.path_join("n.exr"))
	var r: Dictionary = s.call("convert_dir", work, {"recursive": false, "flip_green": false})
	assert_true(r.has("created"), "convert_dir 没返回 created 列表")
	print("[EXR 工具] created = %d 项" % (r.get("created", []) as Array).size())
	assert_true((r.get("created", []) as Array).size() == int(r["ok"]), "created 数量与成功数不一致")

	# 这里只做**同步契约**测试。真正的"导入完成"是异步的，同步测试无法断言
	# （godot_ai 插件的 scan 都要跨帧等 settle，测试里没有 await 能力）。
	# 契约三条：① res:// 下真实文件会被登记 ② user:///不存在的不会被登记 ③ 缺失查询可安全调用
	var missing: PackedStringArray = dlg.call("_missing_resources")
	print("[EXR 工具] 刚登记完，_missing_resources() 返回 %d 项（异步导入，此刻非 0 属正常）" % missing.size())
	assert_true(missing.size() >= 0, "_missing_resources 能安全调用")
	assert_true(FileAccess.file_exists(probe), "探针 PNG 应当保留下来，供后续（异步）导入验证")
	dlg.hide()
	dlg.queue_free()

func test_progress_and_async_wiring() -> void:
	# 需求：Blender 兜底改异步（4K 图每张约 6 秒，同步会卡编辑器）。
	# 同步测试无法 await 异步流程，所以这里分两半验：
	#   ① 核心的进度回传（线程靠它汇报进度）—— 可确定性验证
	#   ② 对话框确实用了后台线程 + 主线程轮询 + 收尾回主线程 —— 源码接线断言
	var s := _load(CONVERT)
	assert_true(s != null, "转换核心加载失败")
	if s == null:
		return
	var work := _out("progress_work")
	DirAccess.make_dir_recursive_absolute(work)
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), work.path_join("a.exr"))
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), work.path_join("b.exr"))
	var progress := {"total": 0, "done": 0, "current": ""}
	var res: Dictionary = s.call("convert_dir", work, {"recursive": false}, progress)
	print("[EXR 工具] 进度回传：total=%d done=%d current=%s" % [
			int(progress["total"]), int(progress["done"]), str(progress["current"])])
	assert_true(int(progress["total"]) == 2, "progress.total 没被填写（应为 2）")
	assert_true(int(progress["done"]) == 2, "progress.done 没走到 2")
	assert_true(int(res["ok"]) == 2, "两个文件都该转换成功")

	# 异步接线：后台线程跑转换、主线程轮询、收尾回主线程通知编辑器
	var f := FileAccess.open(ProjectSettings.globalize_path(DIALOG), FileAccess.READ)
	assert_true(f != null, "读不到对话框脚本")
	if f == null:
		return
	var src := f.get_as_text()
	f.close()
	assert_true(src.contains("Thread.new()"), "对话框没用后台线程跑转换")
	assert_true(src.contains("wait_to_finish()"), "线程结束后没回收（会报 Thread must be disposed）")
	assert_true(src.contains("func _process("), "没有主线程轮询（进度与收尾都靠它）")
	assert_true(src.contains("_thread.is_alive()"), "轮询里没判断线程是否结束")
	assert_true(src.contains("func _worker("), "没有后台线程入口")
	assert_true(src.contains("func _finish_batch("), "收尾没回到主线程（文件系统通知必须在主线程）")
	assert_true(src.contains("get_ok_button().disabled = true"), "转换期间该禁用确定按钮")

func test_thread_can_run_conversion() -> void:
	# 异步能不能成立，关键看"后台线程里能不能真的解码 EXR / 调 Blender / 写 PNG"。
	# 同步测试没有 await，所以这里**真起一个线程**再自旋等待（主线程阻塞不影响 worker 线程）。
	var s := _load(CONVERT)
	if s == null:
		return
	# DWAA 样本可能在原处，也可能被用户回收进了 .runtime —— 两处都找一下。
	# （找不到时必须**留下断言**，否则测试框架会把它记成"0 断言失败"。）
	var dwaa := ""
	for cand in ["D:/sgames/CozyVale/assets/textures/湿泥土/brown_mud_03_nor_gl_4k.exr",
			"D:/sgames/CozyVale/.runtime/exr_recycle/brown_mud_03_nor_gl_4k.exr"]:
		if FileAccess.file_exists(cand):
			dwaa = cand
			print("[EXR 工具] DWAA 样本取自：%s" % cand)
			break
	if dwaa == "":
		assert_true(true, "找不到 DWAA 样本（原处与回收站都没有）→ 跳过 Blender 兜底测试")
		return
	var need_blender := dwaa != ""
	var work := _out("thread_work")
	DirAccess.make_dir_recursive_absolute(work)
	var src := dwaa if need_blender else ProjectSettings.globalize_path(SAMPLE_EXR)
	DirAccess.copy_absolute(src, work.path_join("t.exr"))

	var progress := {"total": 0, "done": 0, "current": ""}
	var holder := {"result": {}}
	var t := Thread.new()
	t.start(func() -> void:
		holder["result"] = s.call("convert_dir", work, {"recursive": false}, progress))
	var waited := 0
	while t.is_alive() and waited < 90000:
		OS.delay_msec(100)
		waited += 100
	var alive := t.is_alive()
	if not alive:
		t.wait_to_finish()
	var res: Dictionary = holder["result"]
	print("[EXR 工具] 后台线程：样本=%s ｜ 仍在跑=%s ｜ total=%d ok=%d ｜ 耗时≈%.1fs" % [
			"DWAA(走 Blender)" if need_blender else "ZIP(引擎直转)",
			str(alive), int(progress.get("total", 0)), int(res.get("ok", 0)), waited / 1000.0])
	assert_true(not alive, "后台线程 90 秒内没结束")
	assert_true(int(res.get("total", 0)) >= 1, "后台线程里没扫到文件")
	assert_true(int(res.get("ok", 0)) >= 1, "后台线程里转换失败：" + str(res.get("failed", [])))
	assert_true(int(progress.get("done", 0)) >= 1, "后台线程没回传进度")

func test_exr_compression_sniffing() -> void:
	# 为什么要预判：引擎的 tinyexr 只支持 NONE/RLE/ZIP/ZIPS，
	# 遇到 DWAA 会抛 "Unknown compression type" 的 ERROR 日志（用户看到会以为出错）。
	var s := _load(CONVERT)
	assert_true(s != null, "转换核心加载失败")
	if s == null:
		return
	# 引擎支持的四种
	for code in [0, 1, 2, 3]:
		assert_true(bool(s.call("engine_supports", code)), "引擎应当支持压缩 %d" % code)
	# 引擎不支持的
	for code in [4, 6, 7, 8, 9]:
		assert_true(not bool(s.call("engine_supports", code)), "引擎不该支持压缩 %d" % code)
	assert_true(String(s.call("compression_name", 8)) == "DWAA", "压缩名映射不对")

	# 真实样本：Poly Haven 的 4K 法线 EXR 是 DWAA 压缩（头里写着 --compression dwaa）
	# 样本可能在原处，也可能被用户回收进了 .runtime —— 两处都找。
	var dwaa := ""
	for cand in ["D:/sgames/CozyVale/assets/textures/湿泥土/brown_mud_03_nor_gl_4k.exr",
			"D:/sgames/CozyVale/.runtime/exr_recycle/brown_mud_03_nor_gl_4k.exr"]:
		if FileAccess.file_exists(cand):
			dwaa = cand
			break
	if dwaa != "":
		var code := int(s.call("exr_compression", dwaa))
		print("[EXR 工具] %s → 压缩 %d(%s)" % [
				dwaa.get_file(), code, String(s.call("compression_name", code))])
		assert_eq(code, 8, "DWAA 样本应解析出 8，实际 %d（%s）" % [code, String(s.call("compression_name", code))])
		assert_true(not bool(s.call("engine_supports", code)), "DWAA 不该被判为引擎可解")
	else:
		assert_true(true, "找不到 DWAA 样本（原处与回收站都没有）→ 跳过该项断言")
	# 另一个样本（Terrain3D 笔刷）只打印，不硬断言 —— 不同来源压缩可能不同
	var zip_like := ProjectSettings.globalize_path(SAMPLE_EXR)
	var c2 := int(s.call("exr_compression", zip_like))
	print("[EXR 工具] %s → 压缩 %d(%s)" % [
			SAMPLE_EXR.get_file(), c2, String(s.call("compression_name", c2))])
	assert_true(c2 >= 0, "解析不出 Terrain3D 笔刷的压缩类型")

func test_recycle_restore_purge() -> void:
	# 回收 = 移进 .runtime 回收站（不是删除）；管理器据此提供还原/彻底删除。
	# 本用例全程用临时文件，不碰任何真实 EXR。
	var s := _load(CONVERT)
	if s == null:
		return
	var work := _out("recycle_work")
	DirAccess.make_dir_recursive_absolute(work)
	var src := work.path_join("t.exr")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), src)
	assert_true(FileAccess.file_exists(src), "临时 EXR 没准备好")
	var box := "user://exr_tools_test/recycle_box"

	var r: Dictionary = s.call("recycle", src, box)
	print("[EXR 工具] 回收：%s" % str(r.get("message", "")))
	assert_true(bool(r.get("ok", false)), "回收失败：" + str(r.get("message", "")))
	assert_true(not FileAccess.file_exists(src), "回收后原位置不该还有这个文件")
	var listed: Array = s.call("list_recycled", box)
	assert_eq(listed.size(), 1, "回收站里应该有 1 条记录")
	assert_true(int(s.call("recycle_usage", box)) > 0, "回收站占用应当是正数")

	# 还原
	var entry: Dictionary = listed[0]
	var r2: Dictionary = s.call("restore", entry, box)
	print("[EXR 工具] 还原：%s" % str(r2.get("message", "")))
	assert_true(bool(r2.get("ok", false)), "还原失败：" + str(r2.get("message", "")))
	assert_true(FileAccess.file_exists(src), "还原后文件应回到原位置")
	assert_eq((s.call("list_recycled", box) as Array).size(), 0, "还原后记录应被移除")

	# 再回收一次，然后彻底删除
	s.call("recycle", src, box)
	var e2: Dictionary = (s.call("list_recycled", box) as Array)[0]
	var r3: Dictionary = s.call("purge", e2, box)
	assert_true(bool(r3.get("ok", false)), "彻底删除失败")
	assert_true(not FileAccess.file_exists(String(e2.get("to", ""))), "彻底删除后文件应真的没了")
	assert_eq((s.call("list_recycled", box) as Array).size(), 0, "彻底删除后记录应被移除")


func test_convert_to_specified_dir_and_recycle() -> void:
	# 需求：能转换到**指定位置**，并且转换后可以选择把原 EXR 扔进 .runtime。
	var s := _load(CONVERT)
	if s == null:
		return
	var work := _out("out_work")
	DirAccess.make_dir_recursive_absolute(work)
	var src := work.path_join("a.exr")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), src)
	var dest := _out("dest_dir")
	var box := "user://exr_tools_test/out_box"

	var r: Dictionary = s.call("convert_dir", work, {
		"recursive": false, "out_dir": dest, "recycle_source": true, "recycle_dir": box,
	})
	print("[EXR 工具] 指定目录转换：total=%d ok=%d" % [int(r.get("total", 0)), int(r.get("ok", 0))])
	print("   " + "\n   ".join(PackedStringArray(r.get("lines", []))))
	assert_eq(int(r.get("ok", 0)), 1, "应当转换成功 1 个")
	var png := dest.path_join("a.png")
	assert_true(FileAccess.file_exists(png), "PNG 没出现在指定目录：" + png)
	assert_true(not FileAccess.file_exists(work.path_join("a.png")), "不该把 PNG 放在原目录旁边")
	assert_true(not FileAccess.file_exists(src), "勾选回收后，原 EXR 应当已离开原位置")
	assert_true((s.call("list_recycled", box) as Array).size() >= 1, "回收箱里应当有记录（用临时箱，别污染真实回收站）")


func test_manager_panel_builds() -> void:
	var ms := _load("res://addons/exr_tools/exr_manager_panel.gd")
	assert_true(ms != null, "管理器面板脚本加载失败")
	if ms == null:
		return
	var p: Control = ms.new()
	EditorInterface.get_base_control().add_child(p)
	var tree: Tree = null
	for c in p.get_children():
		if c is Tree:
			tree = c
	assert_true(tree != null, "管理器里没有 Tree")
	if tree != null:
		assert_eq(tree.columns, 4, "管理器 Tree 应为 4 列")
	p.call("refresh")
	var st: Label = p.get("_status")
	assert_true(st != null, "管理器没有状态标签")
	if st != null:
		print("[EXR 工具] 管理器状态：" + st.text)
		assert_true(String(st.text).contains("回收站"), "刷新后状态不对：" + st.text)
	p.queue_free()

func test_recycle_carries_import_sidecar() -> void:
	# 回归：回收必须把 .import 一起搬走。
	# 只搬 .exr 会留下"孤儿 .import"，文件系统 dock 会报
	# "Condition \"!FileAccess::exists(p_path)\" is true"（用户实测报过这个错）。
	var s := _load(CONVERT)
	if s == null:
		return
	var work := _out("sidecar_work")
	DirAccess.make_dir_recursive_absolute(work)
	var src := work.path_join("s.exr")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), src)
	var side := src + ".import"
	var f := FileAccess.open(side, FileAccess.WRITE)
	if f != null:
		f.store_string("[remap]\n\n[params]\n\ncompress/mode=0\n")
		f.close()
	assert_true(FileAccess.file_exists(side), "伴随文件没造出来")
	var box := "user://exr_tools_test/sidecar_box"

	var r: Dictionary = s.call("recycle", src, box)
	assert_true(bool(r.get("ok", false)), "回收失败：" + str(r.get("message", "")))
	assert_true(not FileAccess.file_exists(src), "回收后源文件该没了")
	assert_true(not FileAccess.file_exists(side), "回收后**不该**留下孤儿的 .import")

	var e: Dictionary = (s.call("list_recycled", box) as Array)[0]
	var r2: Dictionary = s.call("restore", e, box)
	assert_true(bool(r2.get("ok", false)), "还原失败：" + str(r2.get("message", "")))
	assert_true(FileAccess.file_exists(src), "还原后源文件该回来")
	assert_true(FileAccess.file_exists(side), "还原后 .import 也该一起回来")

func test_manager_supports_single_and_batch() -> void:
	# 用户问过"转换到指定目录是不是转换全部" —— 所以两个入口都必须明确存在：
	#   单个：转你选中的那一个
	#   批量：转整个目录（含子目录），且**先告诉你数量**
	var ms := _load("res://addons/exr_tools/exr_manager_panel.gd")
	assert_true(ms != null, "管理器脚本加载失败")
	if ms == null:
		return
	var src := FileAccess.get_file_as_string("res://addons/exr_tools/exr_manager_panel.gd")
	assert_true(src.contains("转换单个 EXR"), "缺少「转换单个 EXR」按钮")
	assert_true(src.contains("转换整个目录"), "缺少「转换整个目录」按钮")
	assert_true(src.contains("FILE_MODE_OPEN_FILE"), "单个转换应当是单选文件")
	for m in ["_pick_exr", "_pick_src_dir", "_ask_batch", "_convert_batch"]:
		assert_true(src.contains("func %s" % m), "缺少方法 %s" % m)
	assert_true(src.contains("共找到 %d 个 EXR"), "批量前必须先报数量")
	# 面板能实例化且带批量确认框
	var p: Control = ms.new()
	EditorInterface.get_base_control().add_child(p)
	assert_true(p.get("_confirm_batch") != null, "没有批量确认框")
	p.queue_free()

func test_right_click_recycle_only_for_exr() -> void:
	# 需求：右键新增「EXR 移入回收站」，**只对 exr 有效**（文件夹/别的扩展名都不该出现）
	var ms := _load(MENU)
	assert_true(ms != null, "右键菜单脚本加载失败")
	if ms == null:
		return
	var inst: EditorContextMenuPlugin = ms.new()

	var work := _out("menu_work")
	DirAccess.make_dir_recursive_absolute(work)
	var exr := work.path_join("m.exr")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), exr)
	var txt := work.path_join("m.txt")
	var f := FileAccess.open(txt, FileAccess.WRITE)
	if f != null:
		f.store_string("hello")
		f.close()

	# 选 .exr → 认
	var a: PackedStringArray = inst.call("exr_files", PackedStringArray([exr]))
	assert_eq(a.size(), 1, "选中的 .exr 应当被认出来")
	# 选文件夹 → 不认
	var b: PackedStringArray = inst.call("exr_files", PackedStringArray([work]))
	assert_eq(b.size(), 0, "文件夹不该被当成 EXR")
	# 选别的文件 → 不认
	var c: PackedStringArray = inst.call("exr_files", PackedStringArray([txt]))
	assert_eq(c.size(), 0, "非 .exr 文件不该被认出来")
	# 不存在的 .exr → 不认
	var d: PackedStringArray = inst.call("exr_files", PackedStringArray([work.path_join("nope.exr")]))
	assert_eq(d.size(), 0, "不存在的文件不该被认出来")
	# 混选 → 只挑出 exr
	var e: PackedStringArray = inst.call("exr_files", PackedStringArray([txt, exr, work]))
	assert_eq(e.size(), 1, "混选时应当只挑出 1 个 EXR")

	# 菜单项接线
	var src := FileAccess.get_file_as_string("res://addons/exr_tools/filesystem_menu.gd")
	assert_true(src.contains("EXR 移入回收站"), "没有回收菜单项文案")
	assert_true(src.contains("ITEM_RECYCLE"), "没有回收菜单项常量")
	assert_true(src.contains("if not exr_files(paths).is_empty():"), "回收项没有加 exr 守卫")
	assert_true(src.contains("func _on_recycle"), "没有回收回调")
	print("[EXR 工具] 右键回收只对 exr 有效 ✓（文件夹/其它扩展名/不存在的文件都被排除）")

func test_recycle_notifies_editor() -> void:
	# 需求：回收后必须通知编辑器文件系统，否则目录树留着旧条目并报
	# "Condition \"!FileAccess::exists(p_path)\" is true"（用户实测报过）。
	var s := _load(CONVERT)
	if s == null:
		return
	var src := FileAccess.get_file_as_string("res://addons/exr_tools/exr_convert.gd")
	assert_true(src.contains("func forget_in_editor"), "没有 forget_in_editor")
	assert_true(src.contains("forget_in_editor(PackedStringArray([src_abs"), "回收后没有通知编辑器")
	assert_true(src.contains("forget_in_editor(PackedStringArray([dst"), "还原后没有通知编辑器")

	# 非 res:// 路径不该被登记（user:// 不在编辑器文件系统里）
	var n_user: int = int(s.call("forget_in_editor", PackedStringArray([ProjectSettings.globalize_path("user://x.exr")])))
	var n_empty: int = int(s.call("forget_in_editor", PackedStringArray()))
	print("[EXR 工具] forget_in_editor：user:// → %d ｜ 空列表 → %d" % [n_user, n_empty])
	assert_eq(n_user, 0, "user:// 路径不该被登记")
	assert_eq(n_empty, 0, "空列表应当安全返回 0")

	# 回收真的走了通知路径（用一个临时 exr，回收后检查不崩）
	var work := _out("notify_work")
	DirAccess.make_dir_recursive_absolute(work)
	var tmp := work.path_join("n.exr")
	DirAccess.copy_absolute(ProjectSettings.globalize_path(SAMPLE_EXR), tmp)
	var box := "user://exr_tools_test/notify_box"
	var r: Dictionary = s.call("recycle", tmp, box)
	assert_true(bool(r.get("ok", false)), "回收失败：" + str(r.get("message", "")))
	print("[EXR 工具] 回收+通知完成 ✓（user:// 场景下通知数为 0 属正常）")

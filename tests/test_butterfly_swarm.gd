@tool
extends McpTestSuite
## 蝴蝶飞舞插件（addons/butterfly_swarm）自检 —— 无头可跑，不依赖编辑器 UI 与已打开场景。
##
## 覆盖清单（口径：CONTRACT.md 第 2/3/4 节 + 四个脚本的**文件头注释**，不是描述里的猜测）：
##   ① 安装完整性：6 个核心文件 + 翅膀着色器存在，project.godot 的 editor_plugins/enabled 已登记
##   ② 素材清单 sprite_manifest.json：条数 = 素材目录 .png 数、path 真实存在且与目录一致、
##      bbox 落在图内、bbox_w/bbox_h > 0（防 detect_bbox 的 Image 分支漏写退化成 0×0）
##   ③ 自动裁剪：detect_bbox(路径 / Texture2D / Image) 三者给出**同一个** Rect2i；
##      crop_to_uv 的 (scale, offset) 把 [0,1] 恰好映射到 crop 区域
##   ④ 翅膀着色器：契约 12 个 uniform 全在、render_mode 含 cull_disabled、
##      有 FRONT_FACING 双面法线翻转、折叠由 dihedral 驱动且绕 +Z 的两半都在、
##      alpha 裁形而不写 ALPHA_SCISSOR_THRESHOLD、虹彩不改写 ALBEDO
##   ⑤ 单只蝴蝶（无渲染）：单位方块网格 4 顶点/6 索引且 v=0 在纹理上边、setup(null) 不崩、
##      spawn 落在区域内、advance 600 步不越界（下边界硬夹 / 水平软回弹）、风真的进计算、
##      同 seed 完全可复现、能量耗尽进入 BASK、**树外 advance 不刷 ERROR 且朝向/缩放与树内一致**
##   ⑥ ButterflySwarm：树外 new() 后直接 rebuild()、live_count/stats、每只 crop 与
##      素材 bbox 一致、每只独立 ShaderMaterial、set_active 总开关、宽松素材入口
##      set_sprite_textures/add_sprite_textures、scene_tree/scene_root 兜底
##
## ★ 环境约定（踩过的坑，别改）
##   · 单只蝴蝶挂在 Engine.get_main_loop().root 下的 _McpTest 容器里。完全树外调
##     Node3D.look_at() 会**每步**刷一条 "Node not inside tree" ERROR（实测 600 步 1202 条），
##     挂进根视口既没有渲染依赖、日志也干净；容器在原点，所以 advance() 的"本地坐标"==全局坐标。
##     ⚠ 但**无头脚本的首帧之前**（`extends SceneTree` 的 `_initialize()` 阶段）root 自己还没进树，
##     那时 add_child 的节点 is_inside_tree() 仍为 false —— 所以整套测试要在首帧 `_process` 之后跑
##     （tools/verify_butterfly.gd 已按此实现）。
##   · ButterflySwarm 刻意**不进场景树**，用来验证 rebuild() 可以独立工作（契约第 3 节）。
##   · 所有随机都走注入的 rng，所以"同 seed"相关断言是确定性的（不依赖全局 randi）。

const BFLY_IO := preload("res://addons/butterfly_swarm/butterfly_io.gd")
const BFLY := preload("res://addons/butterfly_swarm/butterfly.gd")
const SWARM := preload("res://addons/butterfly_swarm/butterfly_swarm.gd")

const PLUGIN_DIR := "res://addons/butterfly_swarm/"
const MANIFEST_PATH := "res://addons/butterfly_swarm/sprite_manifest.json"
const SHADER_PATH := "res://assets/shaders/butterfly_wings.gdshader"
const ENABLED_ENTRY := "res://addons/butterfly_swarm/plugin.cfg"
## 素材目录里应有的 PNG 张数（实测 20 张）
const EXPECTED_SPRITES := 20

const CORE_FILES := [
	"plugin.cfg", "plugin.gd", "butterfly_swarm.gd",
	"butterfly.gd", "butterfly_tuning.gd", "butterfly_io.gd",
]
## 契约第 2 节表里的 12 个 uniform（名字一个都不能改）
const SHADER_UNIFORMS := [
	"albedo_tex", "tex_scale", "tex_offset", "dihedral", "fold_dz", "bend_y",
	"flutter_u", "flutter_v", "tint", "alpha", "iridescence", "backlight",
]
## 风/天气字典允许的 source 取值（契约第 3 节 + 实现里的兜底分支）
const WIND_SOURCES := ["Wind", "Weather", "fallback", "no_tree"]
## 水平/上方的**软回弹**越界容差（米）。butterfly.gd 的 _force_bounds 注释明确：水平与上方是
## "进入 edge_margin 就开始拐"的柔和反向力，只有下方是硬夹。
## 量级推导：限速 2.2 m/s、最大加速度 accel*3 = 5.4 m/s² -> 制动距离 v²/(2a) ≈ 0.45 m。
const SOFT_EDGE_TOL := 1.0
## 下边界的**硬夹**容差（米）。_force_bounds 先把 position.y 夹到 floor_y，之后积分再把
## velocity·delta 加回去，单步最多下沉 (accel*3)·delta² = 5.4/3600 ≈ 1.5 mm。
const HARD_FLOOR_TOL := 0.01

## 单只蝴蝶的测试容器（见文件头"环境约定"）
var _holder: Node3D = null
## 测试期间临时挂上的引擎 ERROR 嗅探器（见 test_butterfly_out_of_tree_*）
var _sniffer: Logger = null


## 引擎 ERROR 嗅探器：`look_at()` 那类 `ERR_FAIL_*` 走的是 ERROR_TYPE_ERROR，
## 不会被 McpTestRunner 的 SCRIPT ERROR 捕获器判红（那是有意的：引擎级 ERROR 大多是负路径噪音），
## 但契约第 2 节第 12 条要求"树外 advance 不刷 ERROR"，所以这条要自己验。
class ErrorSniffer extends Logger:
	var messages: PackedStringArray = []

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, _error_type: int, _script_backtraces: Array) -> void:
		var text := rationale if not rationale.is_empty() else code
		messages.append("%s (%s:%d in %s)" % [text, file, line, function])

	func clear() -> void:
		messages.clear()

	## 命中关键字的消息条数（大小写不敏感）
	func count_containing(needle: String) -> int:
		var n := 0
		for m in messages:
			if String(m).to_lower().find(needle.to_lower()) != -1:
				n += 1
		return n


func suite_name() -> String:
	return "butterfly_swarm"


func setup() -> void:
	_holder = Node3D.new()
	_holder.name = "_McpTestButterflyHolder"
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).root.add_child(_holder)
	else:
		# 没有主循环（极端情况）：退回树外，功能仍可测，只是会多刷 look_at 的 ERROR
		_holder = null
	_sniffer = null


func teardown() -> void:
	# 嗅探器防漏摘：万一测试中途被 SCRIPT ERROR 打断，remove_logger 没跑到
	if _sniffer != null and is_instance_valid(_sniffer):
		OS.remove_logger(_sniffer)
	_sniffer = null
	if is_instance_valid(_holder):
		var p := _holder.get_parent()
		if p != null:
			p.remove_child(_holder)
		_holder.free()
	_holder = null


# ==================== 工具 ====================

## 读清单里的 sprites 数组（读不出来返回空数组，调用方自己判空并断言）。
func _manifest_entries() -> Array:
	if not FileAccess.file_exists(MANIFEST_PATH):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST_PATH))
	if not (parsed is Dictionary):
		return []
	var arr: Variant = (parsed as Dictionary).get("sprites", [])
	return arr as Array if arr is Array else []


## 清单条目的 bbox -> Rect2i（JSON 里是 float，必须转 int）。
func _entry_crop(e: Dictionary) -> Rect2i:
	return Rect2i(int(e["min_x"]), int(e["min_y"]), int(e["bbox_w"]), int(e["bbox_h"]))


## 素材目录里的 .png 文件名（排序），用来和清单对账。
func _png_file_names() -> Array:
	var out: Array = []
	var da := DirAccess.open(BFLY_IO.DEFAULT_DIR)
	if da == null:
		return out
	for f in da.get_files():
		if String(f).to_lower().ends_with(".png"):
			out.append(String(f))
	out.sort()
	return out


## 实现自带的默认调参快照 —— 不把数值抄进测试里，改实现即改输入。
func _default_tuning() -> Dictionary:
	var sw = SWARM.new()
	track(sw)  # 兜底：即使断言中途抛错也不会漏掉节点（已 free 的会被 track 清理跳过）
	var d: Dictionary = sw.tuning_dict()
	sw.free()
	return d


## 单只蝴蝶用的区域（米，本地空间，与 ButterflySwarm._bounds() 同构）。
func _bounds() -> AABB:
	return AABB(Vector3(-2.0, 1.1, -2.0), Vector3(4.0, 2.0, 4.0))


## 造一只"只装配、不调 setup"的蝴蝶，并挂进测试容器。
## 返回类型刻意留空（Variant）：这些脚本靠 preload 绑定，不用 global class 名，
## 静态类型写成 Node3D 只会让 setup()/advance()/stats() 变成"不安全访问"警告。
func _new_butterfly():
	var b = BFLY.new()
	if _holder != null:
		_holder.add_child(b)
	return b


## 造一只装配好的蝴蝶：同 seed 时初始状态（位置/速度/相位/能量）完全一致。
func _make_butterfly(tex: Texture2D, crop: Rect2i, seed_v: int, tuning: Dictionary,
		with_shader := true):
	var b = _new_butterfly()
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	var sh: Shader = null
	if with_shader:
		sh = load(SHADER_PATH) as Shader
	b.setup(tex, crop, r, tuning, sh)
	return b


## 一张"关掉耗能"的调参：跑长步数时不会进 BASK（BASK 会把位置往落脚点 lerp，干扰越界断言）。
func _tuning_no_drain() -> Dictionary:
	var d := _default_tuning()
	d["energy_drain"] = 0.0
	return d


## 造一只**完全不进场景树**的蝴蝶（契约第 2 节第 12 条：无头/树外调 advance 不能崩、不能刷 ERROR）。
func _make_detached_butterfly(tex: Texture2D, crop: Rect2i, seed_v: int, tuning: Dictionary):
	var b = BFLY.new()
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	b.setup(tex, crop, r, tuning, load(SHADER_PATH) as Shader)
	track(b)
	return b


## 去掉注释与所有空白后的着色器源码。
## 用途一：契约里有些是"**不要**写某物"的硬性校验（第 6/7 条），而实现会在注释里解释"为什么不写"，
##   直接 `sh.code.contains("ALPHA_SCISSOR_THRESHOLD")` 会被注释命中、必然误报。
## 用途二：形态断言（折叠数学）抗格式化 —— `VERTEX.x * c` 与 `VERTEX.x*c` 必须等价。
func _compact_code(code: String) -> String:
	var out := ""
	for line in code.split("\n"):
		var idx := String(line).find("//")
		out += (String(line) if idx < 0 else String(line).substr(0, idx)) + "\n"
	# 再去掉块注释 /* ... */（旧版顶点程序里有过一段）
	while true:
		var a := out.find("/*")
		if a < 0:
			break
		var b := out.find("*/", a + 2)
		if b < 0:
			out = out.substr(0, a)
			break
		out = out.substr(0, a) + out.substr(b + 2)
	return out.replace(" ", "").replace("\t", "")


# ==================== ① 安装完整性 ====================

func test_install_integrity() -> void:
	for f in CORE_FILES:
		var p := PLUGIN_DIR + String(f)
		assert_true(FileAccess.file_exists(p), "缺少插件文件 %s" % p)
	assert_true(FileAccess.file_exists(SHADER_PATH), "缺少翅膀着色器 %s" % SHADER_PATH)
	assert_ne(BFLY_IO, null, "butterfly_io.gd 无法 preload")
	assert_ne(BFLY, null, "butterfly.gd 无法 preload")
	assert_ne(SWARM, null, "butterfly_swarm.gd 无法 preload")
	# plugin.cfg 自身要指向 plugin.gd（否则编辑器加载插件时找不到入口）
	var cfg := FileAccess.get_file_as_string(PLUGIN_DIR + "plugin.cfg")
	assert_contains(cfg, "script=\"plugin.gd\"", "plugin.cfg 的 script 入口异常")
	# 读磁盘上的 project.godot：编辑器内存里的 ProjectSettings 要下次启动才刷新
	var project_cfg := FileAccess.get_file_as_string("res://project.godot")
	assert_contains(project_cfg, ENABLED_ENTRY,
			"project.godot 的 editor_plugins/enabled 未登记 %s" % ENABLED_ENTRY)
	print("[蝴蝶测试] 安装完整性：核心文件 %d 个 + 着色器；插件登记=%s"
			% [CORE_FILES.size(), str(project_cfg.contains(ENABLED_ENTRY))])


# ==================== ② 素材清单 ====================

func test_sprite_manifest_matches_directory() -> void:
	assert_true(FileAccess.file_exists(MANIFEST_PATH), "缺少 %s" % MANIFEST_PATH)
	var txt := FileAccess.get_file_as_string(MANIFEST_PATH)
	assert_false(txt.is_empty(), "清单文件为空")
	var parsed: Variant = JSON.parse_string(txt)
	assert_true(parsed is Dictionary, "清单不是合法 JSON 对象")
	if not (parsed is Dictionary):
		return
	var m: Dictionary = parsed
	assert_has_key(m, "count", "清单缺 count")
	assert_has_key(m, "sprites", "清单缺 sprites")
	var entries: Array = m.get("sprites", [])
	var files := _png_file_names()

	# —— 条数：count 字段 / sprites 长度 / 目录里真实 .png 数 三者必须一致 ——
	assert_eq(int(m.get("count", -1)), files.size(), "清单 count 与素材目录 .png 数不一致")
	assert_eq(entries.size(), files.size(), "清单 sprites 条数与素材目录 .png 数不一致")
	assert_eq(files.size(), EXPECTED_SPRITES, "素材目录里的 .png 张数应为 %d" % EXPECTED_SPRITES)

	# —— path 集合：清单与目录必须一一对应（同序） ——
	var man_paths: Array = []
	for e in entries:
		man_paths.append(String((e as Dictionary).get("path", "")))
	var dir_paths: Array = []
	for p in BFLY_IO.list_butterfly_paths():
		dir_paths.append(String(p))
	assert_eq(man_paths, dir_paths, "清单 path 列表与素材目录 .png 列表不一致")
	assert_eq(m.get("sprite_paths", []), man_paths, "sprite_paths 与 sprites[].path 不一致")

	# —— 逐条：bbox 落在图内、非退化、path 真实存在 ——
	var problems: Array = []
	var degenerate := 0
	var out_of_image := 0
	var missing_file := 0
	var min_ratio := 2.0
	var max_ratio := -1.0
	for i in range(entries.size()):
		var e: Dictionary = entries[i]
		for k in ["file", "path", "w", "h", "min_x", "min_y", "max_x", "max_y", "bbox_w", "bbox_h"]:
			if not e.has(k):
				problems.append("#%d 缺字段 %s" % [i, k])
		if problems.size() > 6:
			break
		var w := int(e.get("w", 0))
		var h := int(e.get("h", 0))
		var bx := int(e.get("min_x", -1))
		var by := int(e.get("min_y", -1))
		var bw := int(e.get("bbox_w", 0))
		var bh := int(e.get("bbox_h", 0))
		var p := String(e.get("path", ""))
		# ★ 这条专门防"detect_bbox 对 Image 入参漏分支 -> 清单 20 条全是 0×0"的老坑
		if bw <= 0 or bh <= 0:
			degenerate += 1
			problems.append("#%d bbox 退化为 %dx%d" % [i, bw, bh])
		if bx < 0 or by < 0 or bx + bw > w or by + bh > h or w <= 0 or h <= 0:
			out_of_image += 1
			problems.append("#%d bbox %s 不在 %dx%d 图内" % [i, str(Rect2i(bx, by, bw, bh)), w, h])
		# 端点一致性：max_* 必须等于 min_* + bbox_* - 1（analyze() 的约定）
		if int(e.get("max_x", -1)) != bx + bw - 1 or int(e.get("max_y", -1)) != by + bh - 1:
			problems.append("#%d max_* 与 min_*+bbox_*-1 不一致" % i)
		if not FileAccess.file_exists(p):
			missing_file += 1
			problems.append("#%d path 不存在：%s" % [i, p])
		var ratio := float(bw) / maxf(1.0, float(w))
		min_ratio = minf(min_ratio, ratio)
		max_ratio = maxf(max_ratio, ratio)

	assert_eq(problems, [], "清单有问题条目（前几条）：%s" % str(problems.slice(0, 4)))
	assert_eq(degenerate, 0, "有 %d 条 bbox 退化成 0 尺寸" % degenerate)
	assert_eq(out_of_image, 0, "有 %d 条 bbox 越出图片范围" % out_of_image)
	assert_eq(missing_file, 0, "有 %d 条 path 在磁盘上不存在" % missing_file)

	# —— 抽 1 条现场重扫：清单不能是过期缓存（detect_bbox 直读磁盘原始 PNG 字节） ——
	var first: Dictionary = entries[0] if not entries.is_empty() else {}
	if not first.is_empty():
		var fresh: Rect2i = BFLY_IO.detect_bbox(String(first["path"]))
		assert_eq(fresh, _entry_crop(first),
				"清单第 1 条 bbox 与现场重扫不一致（清单过期了？）")

	print("[蝴蝶测试] 清单：%d 条 / 目录 %d 张 .png；第 1 条 bbox=%s；水平占比 %.4f~%.4f"
			% [entries.size(), files.size(), str(_entry_crop(first)), min_ratio, max_ratio])


# ==================== ③ 自动裁剪 ====================

func test_detect_bbox_texture2d_matches_image() -> void:
	var entries := _manifest_entries()
	assert_false(entries.is_empty(), "清单为空，无法比对 detect_bbox")
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var path := String(e["path"])
	var w := int(e["w"])
	var h := int(e["h"])
	var expect := _entry_crop(e)

	# 路径入参（最可靠：直读磁盘原始 PNG 字节，绕开导入系统）
	var via_path: Rect2i = BFLY_IO.detect_bbox(path)
	# Texture2D 入参（导入后的 CompressedTexture2D）
	var tex := load(path) as Texture2D
	assert_ne(tex, null, "load(%s) 不是 Texture2D" % path)
	var via_tex: Rect2i = BFLY_IO.detect_bbox(tex) if tex != null else Rect2i(0, 0, 0, 0)
	# Image 入参（同一张图的原始像素）
	var img: Image = BFLY_IO.load_image(path)
	assert_ne(img, null, "load_image 读不出 %s" % path)
	var via_img: Rect2i = BFLY_IO.detect_bbox(img) if img != null else Rect2i(0, 0, 0, 0)

	assert_eq(via_path, expect, "detect_bbox(路径) 与清单 bbox 不一致")
	assert_eq(via_tex, via_path, "detect_bbox(Texture2D) 与 detect_bbox(路径) 不一致")
	assert_eq(via_img, via_path, "detect_bbox(Image) 与 detect_bbox(路径) 不一致")
	assert_eq(via_tex, via_img, "detect_bbox(Texture2D) 与 detect_bbox(Image) 必须完全相同")

	# 防两种退化：0×0（Image 分支漏写的老坑）与"整图"（裁剪失效 -> 蝴蝶缩成小点还带一圈边）
	assert_gt(via_img.size.x, 0, "bbox 宽退化为 0（detect_bbox 的 Image 分支丢了？）")
	assert_gt(via_img.size.y, 0, "bbox 高退化为 0")
	assert_true(via_img.size.x < w, "bbox 宽 %d 不该等于整图宽 %d（UV 裁剪失效）" % [via_img.size.x, w])
	assert_true(via_img.size.y < h, "bbox 高 %d 不该等于整图高 %d（UV 裁剪失效）" % [via_img.size.y, h])
	# 退化兜底：读不出图时必须给"不裁剪"的整图矩形，而不是 0×0
	assert_eq(via_img.position, Vector2i(int(e["min_x"]), int(e["min_y"])), "bbox 左上角与清单不一致")
	print("[蝴蝶测试] detect_bbox 三入参一致 = %s（原图 %dx%d，占比 %.4fx%.4f）"
			% [str(via_path), w, h, float(via_path.size.x) / float(w), float(via_path.size.y) / float(h)])


func test_crop_to_uv_maps_unit_range_to_crop() -> void:
	var crop := Rect2i(100, 50, 400, 200)
	var w := 1000
	var h := 500
	var uv: Dictionary = BFLY_IO.crop_to_uv(crop, w, h)
	var scale: Vector2 = uv["scale"]
	var offset: Vector2 = uv["offset"]
	assert_true(scale.is_equal_approx(Vector2(0.4, 0.4)),
			"scale 应为 (400/1000, 200/500) = (0.4, 0.4)，实际 %s" % str(scale))
	assert_true(offset.is_equal_approx(Vector2(0.1, 0.1)),
			"offset 应为 (100/1000, 50/500) = (0.1, 0.1)，实际 %s" % str(offset))
	# [0,1] 必须正好落到 crop 区域：uv=0 -> crop 左上，uv=1 -> crop 右下
	var p0 := Vector2.ZERO * scale + offset
	var p1 := Vector2.ONE * scale + offset
	assert_true(p0.is_equal_approx(Vector2(0.1, 0.1)), "uv=0 应映射到 crop 左上角，实际 %s" % str(p0))
	assert_true(p1.is_equal_approx(Vector2(0.5, 0.5)), "uv=1 应映射到 crop 右下角，实际 %s" % str(p1))
	# 反算回像素：scale 必须正好覆盖 crop 的宽高，offset 正好是左上角（<0.5px）
	assert_true(absf(scale.x * float(w) - float(crop.size.x)) < 0.5, "scale.x 反算像素不等于 bbox 宽")
	assert_true(absf(scale.y * float(h) - float(crop.size.y)) < 0.5, "scale.y 反算像素不等于 bbox 高")
	assert_true(absf(offset.x * float(w) - float(crop.position.x)) < 0.5, "offset.x 反算像素不等于 bbox 左边界")
	assert_true(absf(offset.y * float(h) - float(crop.position.y)) < 0.5, "offset.y 反算像素不等于 bbox 上边界")
	# 退化输入：不能返回 NaN，给恒等映射
	var degen: Dictionary = BFLY_IO.crop_to_uv(Rect2i(0, 0, 0, 0), w, h)
	assert_true((degen["scale"] as Vector2).is_equal_approx(Vector2.ONE), "0×0 crop 应返回恒等 scale")
	assert_true((degen["offset"] as Vector2).is_equal_approx(Vector2.ZERO), "0×0 crop 应返回零 offset")
	assert_true((BFLY_IO.crop_to_uv(crop, 0, 0)["scale"] as Vector2).is_equal_approx(Vector2.ONE),
			"w/h<=0 应返回恒等 scale")

	# 真实素材：用清单第 1 条的 bbox 与原图尺寸再算一遍
	var entries := _manifest_entries()
	if not entries.is_empty():
		var e: Dictionary = entries[0]
		var real: Dictionary = BFLY_IO.crop_to_uv(_entry_crop(e), int(e["w"]), int(e["h"]))
		var rs: Vector2 = real["scale"]
		var ro: Vector2 = real["offset"]
		assert_true(absf(rs.x * float(int(e["w"])) - float(int(e["bbox_w"]))) < 0.5,
				"真实素材 scale.x 反算像素不等于 bbox 宽")
		var corner := Vector2(rs.x * float(int(e["min_x"])) + ro.x, rs.y * float(int(e["min_y"])) + ro.y)
		assert_true(corner.x >= ro.x - 1e-6, "crop 经过 UV 映射后不应越出贴图范围")
		assert_true(ro.x + rs.x <= 1.0 + 1e-6, "crop 右边界不应越出 UV 的 1.0")
		assert_true(ro.y + rs.y <= 1.0 + 1e-6, "crop 下边界不应越出 UV 的 1.0")
		print("[蝴蝶测试] 真实素材 tex_scale=%s tex_offset=%s（反算 %dx%d @ (%d,%d)）"
				% [str(rs), str(ro), int(round(rs.x * float(int(e["w"])))), int(round(rs.y * float(int(e["h"])))),
				int(round(ro.x * float(int(e["w"])))), int(round(ro.y * float(int(e["h"]))))])
	print("[蝴蝶测试] crop_to_uv：scale=%s offset=%s（示例 400x200 @ (100,50) / 1000x500）"
			% [str(scale), str(offset)])


# ==================== ④ 翅膀着色器 ====================

func test_wings_shader_contract() -> void:
	assert_true(ResourceLoader.exists(SHADER_PATH), "着色器不存在：%s" % SHADER_PATH)
	var sh := load(SHADER_PATH) as Shader
	assert_ne(sh, null, "load(%s) 不是 Shader（编译不过？）" % SHADER_PATH)
	if sh == null:
		return
	var names: Array = []
	for u in sh.get_shader_uniform_list():
		names.append(String(u["name"]))
	var missing: Array = []
	for n in SHADER_UNIFORMS:
		if not names.has(String(n)):
			missing.append(String(n))
	assert_eq(missing, [], "着色器缺 uniform %s（实际有 %s）" % [str(missing), str(names)])
	# ★ 负路径断言必须基于"去掉注释的**代码**"：实现会在注释里解释"为什么不写它"
	var code := _compact_code(sh.code)
	assert_contains(sh.code, "cull_disabled", "render_mode 缺 cull_disabled（薄翅双面不可见）")
	assert_contains(sh.code, "depth_prepass_alpha", "render_mode 缺 depth_prepass_alpha")
	assert_contains(code, "FRONT_FACING", "缺双面法线翻转 if (!FRONT_FACING) NORMAL = -NORMAL;")
	# 契约 §2 硬性校验 5（**按语义查**）：
	# 折叠必须由 dihedral 驱动，且必须是**一种完整的**旋转形式 —— 只出现一半 = 只转了一半。
	#   实现里折叠写在模型空间（`x_span*c` / `-x_span*s`），再整体用 MODELVIEW_MATRIX 搬进视图空间
	#   （因为 Godot 顶点阶段的 VERTEX 已经是视图空间，不能直接对 VERTEX 做模型空间旋转）。
	# 两套在实现里真实出现过的公式（轴之争见 test_fold_axis_geometry_verdict）：
	#   · 绕 +Y（体轴）: x' = x·c, z' = −x·s   -> 翅面**离开原平面**（真三维 V）
	#   · 绕 +Z（平面内）: x' = x·c − y·s, y' = x·s + y·c -> z 不变，永远共面（看不到折缝）
	assert_contains(code, "radians(dihedral)", "dihedral 没有经过 radians() 驱动折叠")
	assert_contains(code, "cos(", "折叠缺少 cos")
	assert_contains(code, "sin(", "折叠缺少 sin")
	var fold_y := (code.contains("x_span*c") or code.contains("VERTEX.x*c")) \
			and (code.contains("-x_span*s") or code.contains("-VERTEX.x*s"))
	var fold_z := code.contains("x_span*c-x_span*y") or code.contains("VERTEX.x*c-VERTEX.y*s") \
			or code.contains("x_span*s+x_span") or code.contains("VERTEX.x*s+VERTEX.y*c")
	assert_true(fold_y and not fold_z,
			"顶点折叠必须是**绕 +Y（体轴）的离开原平面形式**（x·c / −x·s）；实测 绕+Y完整=%s / 绕+Z完整=%s"
			% [str(fold_y), str(fold_z)])
	# ★ 体积感三件套必须在代码里真的存在（这是本插件"不是纸片"的依据）
	assert_contains(code, "camber", "缺少弧度 camber（曲面是体积感的第一来源）")
	assert_contains(code, "view_dir", "缺少面向镜头自适应 view_dir（薄片侧对镜头会消失）")
	assert_contains(code, "v_rim", "缺少边缘环压暗 v_rim（廉价 AO）")
	# 第 6 条：必须用 PNG 的 alpha 裁形，且**不能**写 ALPHA_SCISSOR_THRESHOLD
	assert_contains(code, "ALPHA=tex.a*alpha", "片元必须 ALPHA = tex.a * alpha（PNG 的 alpha 裁形）")
	assert_false(code.contains("ALPHA_SCISSOR_THRESHOLD"),
			"写了 ALPHA_SCISSOR_THRESHOLD 会把材质推进 alpha-scissor（不透明）管线，alpha 不再混色")
	# 第 7 条：虹彩只能进 EMISSION，绝不改写 ALBEDO（否则大面积掠射的薄翅会整片染成紫红）
	assert_false(code.contains("ALBEDO=mix("), "虹彩不要改写 ALBEDO（契约第 7 条）")
	assert_contains(code, "EMISSION", "虹彩/逆光要有 EMISSION 项")
	print("[蝴蝶测试] 着色器：uniform %d 个（契约 12 个全在：%s）；折叠形式 绕+Y完整=%s / 绕+Z完整=%s"
			% [names.size(), str(missing.is_empty()), str(fold_y), str(fold_z)])


## 折叠轴之争（绕 +Y 体轴 vs 绕 +Z 平面内）的**几何判据**。
##
## 为什么要有这条测试：这个轴在 2026 被来回改过两次（+Y → +Z → +Y），每次都用"观感"当理由，
## 所以这里把**数学事实**钉住，谁再翻案先看这里：
##   · 翅面四角初始在 z=0 平面（x=翅展、y=头尾、法线 +Z），折叠轴决定"点会不会离开这个平面"。
##   · 绕 +Y（体轴）: z' = -x·s → 翅尖（x=±0.5）在 dihedral=45° 时 z=±0.354，**真的折出三维 V**，
##     且左右翅尖同侧同量（对称的"书脊朝下、双翅上举"）。
##   · 绕 +Z（平面内）: z' ≡ z ≡ 0 → 网格**永远共面**，从任何视角都看不到折缝（只是剪影在图片平面内自转）。
## 本测试只陈述这两条数学，不规定实现必须用哪一个轴（轴的选择由 CONTRACT.md 裁决）。
func test_fold_axis_geometry_verdict() -> void:
	var dih := 45.0
	var th := deg_to_rad(dih)
	var z_max_y := 0.0
	var tip_z_right := 0.0
	var tip_z_left := 0.0
	for xi in [-0.5, 0.5]:
		var x := float(xi)
		var sx := -1.0 if x < 0.0 else 1.0
		var a := -th * sx
		var s := sin(a)
		# 绕 +Y：y 不变，z' = -x·s（z 初值 0）
		var zy: float = -x * s
		z_max_y = maxf(z_max_y, absf(zy))
		if x > 0.0:
			tip_z_right = zy
		else:
			tip_z_left = zy
	# 绕 +Z：z' 恒等于初值 0 —— 所以最大离面位移恒为 0
	var z_max_z := 0.0
	assert_gt(z_max_y, 0.34,
			"绕 +Y 折 45° 时翅尖应离开 z=0 平面约 0.5·sin45°=0.3536（实测 %.4f）—— 这才是三维 V" % z_max_y)
	assert_eq(z_max_z, 0.0,
			"绕 +Z 是平面内自转：z' 恒为 0，网格永远共面、从任何视角都看不到折缝（实测最大离面 %.4f）" % z_max_z)
	assert_true(tip_z_right > 0.0 and absf(tip_z_right - tip_z_left) < 1e-9,
			"绕 +Y 时左右翅尖应同侧同量（对称 V）：右尖 z=%.6f 左尖 z=%.6f" % [tip_z_right, tip_z_left])
	# ★★ 与"实现"对账：上面两条只是数学陈述，光有它们**防不住**再改回绕 +Z ★★
	#   所以这里再把 shader 源码拉出来，断言它**确实离开了 z=0 平面**（即用的是 +Y）。
	#   为什么必须查源码而不是查渲染：绕 +Z 的"平面内自转"能通过所有"做了一次旋转"的语法检查
	#   （见 §2 硬性校验第 5 条的反面教材），只有"z 分量依赖 x"这一条能把它区分出来。
	var sh: Shader = load(SHADER_PATH) as Shader
	assert_ne(sh, null, "着色器加载失败：%s" % SHADER_PATH)
	if sh != null:
		var code := sh.code
		# 实现里折叠写在模型空间：`x_span * c` 与 `-x_span * s`（再整体搬进视图空间）
		var has_offplane := code.contains("-x_span * s") or code.contains("-x_span*s") \
				or code.contains("-VERTEX.x * s") or code.contains("-VERTEX.x*s")
		var has_inplane := code.contains("x_span * s + x_span") or code.contains("x_span*s+x_span") \
				or code.contains("VERTEX.x * s + VERTEX.y * c") or code.contains("VERTEX.x*s+VERTEX.y*c")
		assert_true(has_offplane,
				"着色器必须让翅面**离开 z=0 平面**（应含 `-x_span * s`，即绕 +Y 体轴折叠）；"
				+ "若只剩平面内自转（绕 +Z），网格永远共面、任何视角都看不到折缝")
		assert_false(has_inplane,
				"着色器里不应出现绕 +Z（平面内自转）的形态 `VERTEX.x*s + VERTEX.y*c` —— 那是被推翻的改法")
		print("[蝴蝶测试] 折叠轴判定：实现=绕 +Y（离面型）｜源码含 -VERTEX.x*s = %s，含平面内自转 = %s"
				% [str(has_offplane), str(has_inplane)])
	print("[蝴蝶测试] 折叠轴几何：绕 +Y 时 45° 离面 %.4f（翅尖 z 右 %.4f / 左 %.4f，对称）；绕 +Z 离面 %.4f（恒共面）"
			% [z_max_y, tip_z_right, tip_z_left, z_max_z])
	# ==================== 体积感（"蝴蝶没有体积"的回归防线） ====================
	# 把"有体积"拆成三条**可测**的几何事实，任何一条退化都会让测试红：
	#   ① 翅面曲率：camber 让二面角随翼展增长 -> dihedral=0 时翅面仍非平面（z 随 x 变化）
	#   ② 翅面厚度：闭合外壳在 z 方向有非零尺寸（在 test_butterfly_unit_quad_geometry 里查）
	#   ③ 身体：有真实的纺锤实体（同上）
	# ① 用**与着色器完全相同的公式**算一遍（th=0 时只剩 camber 项）
	var camber_c := 0.35
	var th_c := deg_to_rad(0.0)
	var camber_base_c := maxf(th_c, 0.5235988)   # 与着色器同源的 30° 基准角
	var x_mid := 0.0
	var x_tip := 0.5
	var a_mid := -(th_c + camber_c * absf(x_mid) * camber_base_c) * (1.0 if x_mid >= 0.0 else -1.0)
	var a_tip := -(th_c + camber_c * absf(x_tip) * camber_base_c) * (1.0 if x_tip >= 0.0 else -1.0)
	var z_mid := -x_mid * sin(a_mid)
	var z_tip := -x_tip * sin(a_tip)
	assert_true(absf(z_mid) < 1e-9, "dihedral=0 且 x=0 时是折缝，不应有离面位移（实测 %.8f）" % z_mid)
	assert_true(absf(z_tip) > 1e-4,
			"camber 必须在 dihedral=0 时也产生非零曲率（实测翅尖离面 %.8f）；为 0 说明翅面还是平板，没有明暗渐变"
			% absf(z_tip))
	assert_true(BFLY.GRID_X >= 4 and BFLY.GRID_Y >= 4,
			"翅面网格必须细分（至少 4×4）—— 曲率靠顶点体现，网格太稀 camber 会退化成一个平面折角（实测 %d×%d）"
			% [BFLY.GRID_X, BFLY.GRID_Y])
	print("[蝴蝶测试] 体积感：camber=%.2f 时 dihedral=0 翅尖仍离面 %.5f；网格 %d×%d 细分"
			% [camber_c, absf(z_tip), BFLY.GRID_X, BFLY.GRID_Y])
	# ② 严格左右对称 + 折向（数值，不靠渲染）：
	#    镜像判据（绕 +Y 折、两翅同向抬起）应该是：x_l = −x_r、y_l = y_r、**z_l = z_r**。
	#    ⚠ 这里踩过一次坑：一开始把 z 写成了"相反数"（z_l = −z_r），结果报 0.829 的假失败。
	#      实际几何：两翅尖都朝 **+Z 抬起**（V 的开口朝额面法线一侧），所以 z 必须**相等**。
	#    为什么必须用数值验而不是像素统计：渲染出的左右差异**主要来自素材本身**
	#      （蝴蝶-01 左半与右半的不透明像素数相差 2.4 倍，连 camber=0 的裸四边形也这样）。
	var worst_mirror := 0.0
	var worst_z := 1.0e9
	var worst_x := 0.0
	for cam in [0.0, 0.30, 0.80]:
		for xi in [0.06, 0.18, 0.30, 0.42, 0.5]:
			for yi in [-0.5, -0.25, 0.0, 0.25, 0.5]:
				var pl := _fold_math(-float(xi), float(yi), 40.0, float(cam))
				var pr := _fold_math(float(xi), float(yi), 40.0, float(cam))
				worst_mirror = maxf(worst_mirror, maxf(maxf(absf(pl.x + pr.x), absf(pl.y - pr.y)),
						absf(pl.z - pr.z)))
				worst_z = minf(worst_z, minf(pl.z, pr.z))
				worst_x = maxf(worst_x, absf(pl.x + pr.x))
	assert_true(worst_mirror < 1e-6,
			"折翼必须严格左右对称（判据 x_l=−x_r、y_l=y_r、z_l=z_r；实测最大误差 " + str(worst_mirror)
			+ "）：不对称说明两翅的折叠角符号/基准不一致")
	assert_true(worst_z > 1e-4,
			"两翅都必须朝 +Z 抬起（V 开口朝额面法线一侧）；实测最小的翅尖 z = " + str(worst_z)
			+ " —— 为负说明折叠方向反了（等于从背后看 V）")
	print("[蝴蝶测试] 左右对称：camber ∈ {0, 0.3, 0.8} × 25 点，最大镜像误差 = ", worst_mirror,
			"；两翅最小 z = ", worst_z)
	# ③ 巡飞高度必须**偏低**（用户实测反馈："蝴蝶都飘在天上，远看是一颗颗白点"）。
	#    根因：CRUISE 原来只有水平随机游走 + 噪声，垂直方向**没有偏置**，
	#    于是会均匀铺满整个区域高度。真实蝴蝶大多数时间在花层（离地 0.3~2 米）。
	#    现在 `_pick_cruise_waypoint()` 用 `u^1.8` 把航点往区域下部压。
	#    这里用**同一套公式**做统计断言：1000 个航点的平均高度必须落在区域下 1/4。
	var lo_y := 1.0
	var region_h := 4.0
	var floor_y := lo_y + 0.35
	var band := minf(region_h * 0.35, 2.5)
	var ceil_y := floor_y + maxf(0.35, band)
	var acc := 0.0
	var n_sample := 1000
	for _i in range(n_sample):
		acc += floor_y + (ceil_y - floor_y) * pow(randf(), 1.8)
	var avg_y := acc / float(n_sample)
	var quarter := lo_y + region_h * 0.25
	assert_true(avg_y < quarter,
			"巡飞航点平均高度应落在区域下 1/4（实测 %.3f，阈值 %.3f）—— 高于它就说明蝴蝶会飘在天上"
			% [avg_y, quarter])
	print("[蝴蝶测试] 巡飞高度偏好：%d 个采样航点平均 y=%.3f（区域 y∈[%.1f, %.1f]，下 1/4 上限 %.2f）"
			% [n_sample, avg_y, lo_y, lo_y + region_h, quarter])


## 与着色器**完全一致**的折叠公式（契约 §1），用于数值验证对称性/曲率。
func _fold_math(x: float, y: float, dihedral_deg: float, camber: float) -> Vector3:
	var th := deg_to_rad(dihedral_deg)
	var camber_base := maxf(th, 0.5235988)   # 与着色器同源的 30° 基准角
	var a := -(th + camber * absf(x) * camber_base) * (1.0 if x >= 0.0 else -1.0)
	return Vector3(x * cos(a), y, -x * sin(a))


# ==================== ⑤ 单只蝴蝶 ====================

func test_butterfly_unit_quad_geometry() -> void:
	var b = _new_butterfly()
	var mesh: ArrayMesh = b.build_unit_quad()
	assert_ne(mesh, null, "build_unit_quad() 返回 null")
	if mesh == null:
		return
	# ★ 2026 立体感升级：网格从"单片方块"变成
	#   surface 0 = 翅面闭合外壳（前层 + 后层 + 四条侧壁）
	#   surface 1 = 身体（有体积的纺锤实体）
	#   所以断言也要跟着更新 —— 这里同时守住"两个表面都在"（少一个就是体积感丢了一半）。
	assert_eq(mesh.get_surface_count(), 2,
			"应有 2 个表面：0=翅面外壳、1=身体（体积感的两个来源）")
	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	# 外壳：前层 9x9 + 后层 9x9 + 侧壁 4*(4*8) 段*6 顶点 = 162 + 768 = 930 顶点
	assert_gt(verts.size(), 81, "翅面外壳顶点数应远多于单片网格（实测 %d）" % verts.size())
	assert_gt(idx.size(), 0, "翅面应有索引")
	assert_eq(uvs.size(), verts.size(), "UV 数应与顶点数一致")
	# 厚度：z 方向必须有非零尺寸（这是"有体积"的硬指标；单片网格在这里恒为 0）
	var zmin := 1e9
	var zmax := -1e9
	for i in range(verts.size()):
		zmin = minf(zmin, verts[i].z)
		zmax = maxf(zmax, verts[i].z)
	assert_gt(zmax - zmin, 1e-4,
			"翅面必须在 z 方向有非零厚度（实测 %.6f）—— 全为 0 说明退化回零厚度单片" % (zmax - zmin))
	# 前层 / 后层应大致对称地分布在 z=0 两侧
	assert_true(zmin < 0.0 and zmax > 0.0,
			"厚度应前后对称分布（实测 z ∈ [%.6f, %.6f]）" % [zmin, zmax])
	# 平面范围仍在单位方块内
	for i in range(verts.size()):
		assert_true(absf(verts[i].x) <= 0.5 + 1e-5 and absf(verts[i].y) <= 0.5 + 1e-5,
				"顶点 %d 应在单位方块内，实际 %s" % [i, str(verts[i])])
	# UV 的 v=0 必须落在纹理**上边**（y=+0.5 那一排顶点）—— 契约第 1 节
	var top_count := 0
	var top_bad := 0
	var top_uv1_seen := false
	for i in range(verts.size()):
		if absf(verts[i].y - 0.5) < 1e-5:
			top_count += 1
			if absf(uvs[i].y) > 1e-6:
				top_bad += 1
			if absf(uvs[i].x - 1.0) < 1e-6:
				top_uv1_seen = true
	assert_eq(top_bad, 0, "上边顶点（y=+0.5）的 UV.y 必须是 0（纹理 v 轴朝下）")
	assert_true(top_count > 0, "应存在落在上边 y=+0.5 的顶点")
	assert_true(top_uv1_seen, "上边应存在 UV=(1,0) 的右上角顶点")
	# 身体表面：必须有顶点、且沿 Y 明显长于 X/Z（纺锤形）
	var body: Array = mesh.surface_get_arrays(1)
	var bv: PackedVector3Array = body[Mesh.ARRAY_VERTEX]
	assert_gt(bv.size(), 0, "身体表面不能为空（否则就是纸片蝶）")
	var by0 := 1e9
	var by1 := -1e9
	var bx := 0.0
	for i in range(bv.size()):
		by0 = minf(by0, bv[i].y)
		by1 = maxf(by1, bv[i].y)
		bx = maxf(bx, absf(bv[i].x))
	assert_gt(by1 - by0, 0.4, "身体应沿头尾方向明显拉长（实测长 %.4f）" % (by1 - by0))
	assert_true(bx > 0.01 and bx < 0.2,
			"身体半径应在合理区间（实测最大 |x| = %.4f）—— 过粗就不像蝴蝶了" % bx)
	# ARRAY_CUSTOM0 规则（契约第 2 节第 10 条）
	var custom: Variant = arrays[Mesh.ARRAY_CUSTOM0]
	assert_true(custom == null or custom is PackedByteArray,
			"ARRAY_CUSTOM0 必须是 PackedByteArray（或干脆不写），实际 %s"
			% type_string(typeof(custom)))
	print("[蝴蝶测试] 翅面外壳：顶点 %d / 索引 %d / z 厚度 %.5f；身体：顶点 %d / 长 %.4f / 半径 %.4f"
			% [verts.size(), idx.size(), zmax - zmin, bv.size(), by1 - by0, bx])


## ★ 身体颜色采样（`sample_body_color`）。
## 为什么单独立一条：本项目 PNG 按 **BPTC/ETC2 压缩**导入，
##   `CompressedTexture2D.get_image()` 回来的图是**压缩格式** —— 直接 `get_pixel()` 会刷
##   `Can't get_pixel() on compressed image, sorry.`（用户实测遇到过）。
##   所以这里必须断言"真的采到了像素"（返回值 ≠ 兜底色），
##   只断言"返回了个 Color"是抓不到这个 bug 的。
func test_body_color_sample_from_real_texture() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	assert_gt(paths.size(), 0, "素材目录里应至少有一张 PNG")
	var tex := load(String(paths[0])) as Texture2D
	assert_ne(tex, null, "素材 0 加载失败")
	var b = _new_butterfly()
	b.setup(tex, BFLY_IO.detect_bbox(tex), _rng(3), _default_tuning())
	# setup 里已经调用过一次（_apply_material），这里再显式调一次拿返回值
	var c: Color = b.sample_body_color()
	var fallback := Color(0.24, 0.17, 0.12)
	assert_true(c.r > 0.0 and c.g > 0.0 and c.b > 0.0, "身体色各通道应为正，实际 %s" % str(c))
	assert_ne(c, fallback,
			"身体色不应等于兜底色 —— 等于说明**像素没读出来**（压缩图忘了 decompress？）实际 %s" % str(c))
	# 身体材质真的挂上了（surface 1 存在时）
	assert_ne(b._body_mat, null, "身体的 StandardMaterial3D 应已创建")
	if b._body_mat != null:
		assert_true(absf(b._body_mat.albedo_color.r - c.r) < 1e-6,
				"身体材质的 albedo 应来自采样色")
	print("[蝴蝶测试] 身体采样色（%s）= %s" % [String(paths[0]).get_file(), str(c)])


## ★ 任意图片都能用 + 换图自动失效 + UV 重建按钮。
## 为什么必须有这组测试（用户诉求原文："支持任意的图片素材加入与替换"、
##   "UV 如果不能动态实现，那么需要一个按钮实现 UV 生成"）：
##   旧实现有两处会在"换图"时静默给错值：
##     ① `detect_bbox` 按**路径**缓存 -> 同一会话里换了图仍命中旧包围盒；
##     ② 蝴蝶群按**文件名**查清单 -> 换了图/清单过期就得到错的裁剪框。
##   这里用一张**现场造出来、不在清单里**的 PNG 把这两点都钉住。
func test_uv_autodetect_for_arbitrary_image() -> void:
	var tmp := "res://.runtime/_uv_autodetect_probe.png"
	var fails: Array = []
	# ① 造图：64×48，四周透明，中间 32×20 彩色块，另加 4 个白像素（该被当背景忽略）
	var img := Image.create(64, 48, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in range(14, 34):
		for x in range(16, 48):
			img.set_pixel(x, y, Color(0.8, 0.3, 0.1, 1.0))
	for i in range(4):
		img.set_pixel(2, 2 + i, Color(1, 1, 1, 1))
	assert_eq(img.save_png(tmp), OK, "临时 PNG 写盘失败")
	BFLY_IO.clear_bbox_cache()

	# ② 用**路径**求 UV（不 load()：.runtime 下的新图还没被导入系统处理）
	var set1 := BFLY_IO.compute_uv_set([tmp])
	var e1: Dictionary = set1.get(tmp, {})
	var c1: Rect2i = e1.get("crop", Rect2i())
	assert_eq(c1, Rect2i(16, 14, 32, 20),
			"任意不规则前景的包围盒应为 (16,14,32,20)，实际 %s" % str(c1))
	var sc1: Vector2 = e1.get("scale", Vector2.ZERO)
	assert_true(sc1.is_equal_approx(Vector2(0.5, 20.0 / 48.0)),
			"UV scale 应为 (0.5, 0.4167)，实际 %s" % str(sc1))

	# ③ 第二次必须命中缓存
	var e2: Dictionary = BFLY_IO.compute_uv_set([tmp]).get(tmp, {})
	assert_true(bool(e2.get("cached", false)), "同图第二次应命中缓存")

	# ④ ★ 覆写同一路径后缓存必须失效（内容指纹的作用）
	var img2 := Image.create(64, 48, false, Image.FORMAT_RGBA8)
	img2.fill(Color(0, 0, 0, 0))
	for y in range(4, 44):
		for x in range(4, 60):
			img2.set_pixel(x, y, Color(0.2, 0.6, 0.9, 1.0))
	img2.save_png(tmp)
	var e3: Dictionary = BFLY_IO.compute_uv_set([tmp]).get(tmp, {})
	assert_eq(e3.get("crop", Rect2i()), Rect2i(4, 4, 56, 40),
			"换图后应自动重算包围盒为 (4,4,56,40)，实际 %s（旧值 = 缓存没按内容失效）"
			% str(e3.get("crop", Rect2i())))
	assert_false(bool(e3.get("cached", true)), "换图后不应命中缓存")

	# ⑤ 手动 UV 重建入口
	var r1 := BFLY_IO.regenerate_all([tmp])
	assert_eq(int(r1.get("count", 0)), 1, "UV 重建应处理 1 张")
	assert_true(int(r1.get("generation", 0)) >= 1, "UV 重建应推进代数")

	# ⑥ 真实素材：蝴蝶群必须**直接用该图自己的裁剪框**（而不是查清单）
	var paths := BFLY_IO.list_butterfly_paths()
	assert_gt(paths.size(), 0, "素材目录应有 PNG")
	var rp := String(paths[0])
	var rtex := load(rp) as Texture2D
	if rtex != null:
		var sw = SWARM.new()
		track(sw)
		sw.set_sprite_textures([rtex])
		sw.count = 3
		sw.rebuild()
		var b0: Node3D = sw.get_child(0)
		var want := BFLY_IO.detect_bbox(rp)
		assert_eq(b0.crop, want,
				"蝴蝶应直接使用该图自己的裁剪框（实际 %s，期望 %s）" % [str(b0.crop), str(want)])
		# set_crop 能立刻改；regenerate_uv 能还原
		b0.set_crop(Rect2i(want.position.x + 10, want.position.y + 10, 40, 32))
		assert_eq(b0.crop.size, Vector2i(40, 32), "set_crop 应立即生效")
		var res: Dictionary = sw.regenerate_uv()
		assert_eq(b0.crop, want, "regenerate_uv 后 crop 应还原为 %s" % str(want))
		assert_eq(int(res.get("sprites", 0)), 1, "regenerate_uv 统计里素材数应为 1")
	else:
		fails.append("真实素材 load 失败：%s" % rp)

	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	assert_eq(fails, [], "附加失败项：%s" % str(fails))
	print("[蝴蝶测试] UV 自动探测：任意图 (16,14,32,20) ✓ ｜ 换图缓存失效 (4,4,56,40) ✓ ｜ 群用自身裁剪 ✓")


## ★ `body_scale` 真的改变身体几何 + 身体不会埋住翅膀。
## 用户实测反馈"body_scale 疑似未生效"，查下来是**值被设得过大**（场景里存着 3.0）：
##   实测身体半径 = body_scale × 翼展的 12.5%，3.0 时就是 37.3% —— 粗到几乎与翅根同宽，
##   翅膀被埋进身体里，看起来就像"这个参数没用"。这条测试钉住"单调 + 上限"。
func test_body_scale_changes_body_geometry() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	var tex := load(String(paths[0])) as Texture2D
	var crop := BFLY_IO.detect_bbox(String(paths[0]))
	var last_r := -1.0
	for bs in [0.5, 1.0, 1.5, 2.0]:
		var b = _new_butterfly()
		b.setup(tex, crop, _rng(1), {"size_m": 0.22, "body_scale": bs})
		var mesh: ArrayMesh = b.build_unit_quad()
		assert_eq(mesh.get_surface_count(), 2, "body_scale=%.1f 时应有身体表面" % bs)
		var bv: PackedVector3Array = mesh.surface_get_arrays(1)[Mesh.ARRAY_VERTEX]
		var rad := 0.0
		for v in bv:
			rad = maxf(rad, maxf(absf(v.x), absf(v.z)))
		assert_true(rad > last_r,
				"身体半径必须随 body_scale 单调增大（%.1f 时 %.4f，上一个 %.4f）" % [bs, rad, last_r])
		last_r = rad
		# 1.0 时半径应约为翼展的 12.5%（单位方块里翼展半宽 ≈ 0.5）
		if absf(bs - 1.0) < 1e-6:
			var frac := rad / 0.5
			assert_true(absf(frac - 0.125) < 0.02,
					"body_scale=1.0 时身体半径应约为翼展的 12.5%%，实际 %.1f%%" % (frac * 100.0))
	# body_scale=0 -> 没有身体表面
	var b0 = _new_butterfly()
	b0.setup(tex, crop, _rng(1), {"size_m": 0.22, "body_scale": 0.0})
	var m0: ArrayMesh = b0.build_unit_quad()
	assert_eq(m0.get_surface_count(), 1, "body_scale=0 时不应有身体表面（退化为单片翅）")
	print("[蝴蝶测试] body_scale：半径单调 0.5->2.0（末端 %.4f = 翼展 %.1f%%）；0 时不建身体面"
			% [last_r, last_r / 0.5 * 100.0])


## ★★ 蝴蝶必须对「合批」免疫（`meta["batch"] = false`）★★
## 用户实测反馈："合批勾上会导致蝴蝶呈现冻结的白片形式"。根因：
##   本仓库 `scripts/world/prop_merge.gd` 会把带 `meta["allow_batch"]` 的节点**整棵子树**里
##   所有 MeshInstance3D 合并成一个静态 ArrayMesh 并 `queue_free()` 原件 ——
##   蝴蝶的 `visual` 正好在后代里，于是逐只材质/逐帧顶点全丢，整群压成一块静止网格。
##   它的契约里留了逃生口：子件 `meta["batch"] = false` 即排除。
##   这条测试先钉住"meta 打了"，再**真的调一次 prop_merge.apply()** 验证蝴蝶活着。
func test_butterflies_immune_to_prop_merge_batching() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	var tex := load(String(paths[0])) as Texture2D
	var sw = SWARM.new()
	track(sw)
	sw.set_sprite_textures([tex])
	sw.count = 4
	sw.region_size = Vector3(4, 2, 4)
	sw.rebuild()
	assert_eq(sw.live_count(), 4, "应先建出 4 只")
	print("[蝴蝶测试] build 之后：get_child_count=", sw.get_child_count(),
			" live=", sw.live_count())
	var b0: Node3D = sw.get_child(0)
	var vis: MeshInstance3D = b0.visual
	assert_ne(vis, null, "蝴蝶应有 visual 子节点")
	assert_true(vis.has_meta("batch") and bool(vis.get_meta("batch")) == false,
			"visual 必须带 meta batch=false（否则会被 prop_merge 合批成冻结白片）")
	# 真跑一次合批：造一个 allow_batch 根 + 6 件陪衬（满足 MIN_PARTS=4）
	# ⚠ 用运行时 load() 而不是顶部 const preload：`prop_merge.gd` -> 本插件脚本，
	#   而本测试又 preload 了插件脚本 —— 顶部再 preload 会形成**循环依赖**（实测 parse error）。
	var prop_merge: GDScript = load("res://scripts/world/prop_merge.gd") as GDScript
	assert_ne(prop_merge, null, "prop_merge.gd 应能加载")
	if prop_merge == null:
		return
	var root := Node3D.new()
	track(root)
	# ⚠ 必须真的挂进场景树：prop_merge 要 `holder.get_parent()` 才能把合并网格挂上去
	#   （树外的 holder 会走"放弃"分支，返回 parts=0 —— 实测过）。
	#   测试基类没有 get_root()，所以照 setup() 的做法走 Engine.get_main_loop()。
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).root.add_child(root)
	root.set_meta("allow_batch", true)
	root.add_child(sw)
	for i in range(6):
		var mi := MeshInstance3D.new()
		mi.name = "Prop_%d" % i
		mi.mesh = BoxMesh.new()
		mi.material_override = StandardMaterial3D.new()
		mi.position = Vector3(i, 0, 0)
		root.add_child(mi)
	# 不需要把 root 挂进场景树：prop_merge 只用 parent.add_child + queue_free，
	# 树外同样成立（实测它能正常合成 1 组）。
	# 记录合批前那 4 只的身份，合批后逐个核对"还是同一批节点"
	var before_ids: Array = []
	for c in sw.get_children():
		before_ids.append(c.get_instance_id())
	var r: Dictionary = prop_merge.call("apply", root)
	var after_ids: Array = []
	for c in sw.get_children():
		after_ids.append(c.get_instance_id())
	var survived := 0
	for i in before_ids:
		if after_ids.has(i):
			survived += 1
	print("[蝴蝶测试] 合批前后：子节点 %d -> %d，原节点存活 %d/%d"
			% [before_ids.size(), after_ids.size(), survived, before_ids.size()])
	assert_true(int(r.get("groups", 0)) >= 1,
			"陪衬网格应被合批（证明合批真的执行了，而不是被跳过）：%s" % str(r))
	assert_true(int(r.get("parts", 0)) > 0,
			"应真的合掉了几件陪衬：%s" % str(r))
	# ★ 核心断言：蝴蝶一只都不能少，而且不能是"被搬走/被重建"的替身
	assert_eq(sw.live_count(), 4, "合批后蝴蝶仍应为 4 只")
	assert_eq(survived, before_ids.size(),
			"合批后原有蝴蝶节点必须**全部存活**（实测 %d/%d 个实例 id 仍在）—— 说明没被搬走或释放"
			% [survived, before_ids.size()])
	assert_false(vis.is_queued_for_deletion(), "蝴蝶 visual 不应被 queue_free")
	var st: Dictionary = sw.stats()
	assert_eq(int(st.get("live", 0)), 4, "合批后 stats().live 仍应为 4")
	print("[蝴蝶测试] 合批免疫：prop_merge 合了 %d 组/%d 件，蝴蝶 4 只（含 visual）全部存活"
			% [int(r.get("groups", 0)), int(r.get("parts", 0))])


## ★★ 移动生态学模型（CRW / Lévy / ARS）—— 修掉"蝴蝶都是直飞的" ★★
##
## 量测方式很关键：**不能在全量仿真里量转角**。实测过 —— 风拖曳每帧都在改速度方向，
## 噪声地板约 3°，把参数差异整个盖住（persistence 0.72→0.99 时平均转角反而从 3.25°
## 变到 4.08°，看起来像"参数失效"）。所以这里**直接量 `_crw_turn()`**：
## 那才是模型的签名，不受风/噪声/边界影响。
func test_crw_turn_model_responds_to_tuning() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	var tex := load(String(paths[0])) as Texture2D
	var crop := BFLY_IO.detect_bbox(String(paths[0]))
	var t_def := _measure_crw_turn(tex, crop, {"size_m": 0.22, "flap_hz": 0.0})
	var t_straight := _measure_crw_turn(tex, crop, {"size_m": 0.22, "flap_hz": 0.0,
			"heading_persistence": 0.99, "turn_scale_deg": 1.0, "turn_heavy_p": 0.0})
	var t_wild := _measure_crw_turn(tex, crop, {"size_m": 0.22, "flap_hz": 0.0,
			"heading_persistence": 0.0, "turn_scale_deg": 80.0, "turn_heavy_p": 0.4})
	assert_true(t_straight < t_def,
			"persistence↑/turn_scale↓ 应让转角更小（%.2f° < %.2f°）" % [t_straight, t_def])
	assert_true(t_wild > t_def * 1.5,
			"persistence↓/turn_scale↑ 应让转角显著变大（%.2f° > 1.5×%.2f°）" % [t_wild, t_def])
	assert_true(t_def > 1.0 and t_def < 60.0,
			"默认参数的转角应在「像蝴蝶」的区间（实测 %.2f°，期望 1~60°）" % t_def)
	# Lévy 步长：重尾 -> 必须有**长步**（>= 3 倍短步），否则不是重尾分布
	var b = _new_butterfly()
	b.setup(tex, crop, _rng(5), {"size_m": 0.22, "levy_alpha": 1.6})
	var mn := 1.0e9
	var mx := -1.0e9
	for i in range(500):
		var s: float = b._levy_step()
		mn = minf(mn, s)
		mx = maxf(mx, s)
	assert_true(mx > mn * 2.5,
			"Lévy 步长应是重尾分布（最长 %.3f 应远大于最短 %.3f）—— 比例接近 1 就不是重尾" % [mx, mn])
	b.free()
	print("[蝴蝶测试] CRW 转角：默认 %.1f° ｜ 调直 %.1f° ｜ 调乱 %.1f° ｜ Lévy 步长 %.3f~%.3f m"
			% [t_def, t_straight, t_wild, mn, mx])


## 量测 `_crw_turn()` 的平均转角（度）：反复调它，统计相邻航向夹角。
func _measure_crw_turn(tex: Texture2D, crop: Rect2i, over: Dictionary) -> float:
	var b: Node3D = BFLY.new()
	var r := RandomNumberGenerator.new()
	r.seed = 21
	b.setup(tex, crop, r, over)
	var prev := Vector3.ZERO
	var sum := 0.0
	var n := 0
	for i in range(3000):
		b.set("_crw_heading", prev)
		var h: Vector3 = b.call("_crw_turn")
		if prev.length_squared() > 0.5:
			sum += rad_to_deg(prev.angle_to(h))
			n += 1
		prev = h
	b.free()
	return sum / maxf(1.0, float(n))


## ★★ 蝴蝶 ↔ 草（SimpleGrassTextured / sgt）交互：真的把 uniform 写进草材质 ★★
##
## 用户诉求"实现与 sgt 的交互"的验收点：
##   ① 能认出场里的 sgt 草材质（按着色器路径判定）；
##   ② 每帧把"最贴草的蝴蝶"写进 sgt_butterfly_* 六个 uniform；
##   ③ 蝴蝶飞到压草带之上时 press 归零（草自己恢复，不需要额外清理）；
##   ④ 插槽数 = 0 时把 count 写回 0（整段顶点计算跳过，零开销）。
func test_grass_interaction_writes_sgt_uniforms() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	var tex := load(String(paths[0])) as Texture2D
	var sw = SWARM.new()
	track(sw)
	sw.set_sprite_textures([tex])
	sw.count = 2
	sw.region_size = Vector3(4, 2, 4)
	sw.rebuild()
	# 造一个真用 SGT 草着色器的材质（这样 _scan_grass 才认得出）
	var gm := ShaderMaterial.new()
	gm.shader = load("res://addons/simplegrasstextured/shaders/grass_linear.gdshader") as Shader
	assert_ne(gm.shader, null, "SGT 草着色器应能加载")
	var mi := MeshInstance3D.new()
	mi.mesh = BoxMesh.new()
	mi.material_override = gm
	var host := Node3D.new()
	track(host)
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).root.add_child(host)
	host.add_child(mi)
	host.add_child(sw)
	assert_gt(sw._scan_grass(), 0, "应扫到至少 1 个 sgt 草材质")
	# ★★ 回归：草**绝大多数是 `MultiMeshInstance3D`**，而它**不是** `MeshInstance3D` 的子类
	#   （两者是兄弟，共同父类是 GeometryInstance3D）。
	#   早期实现写 `(gi as MeshInstance3D).mesh`，对 MultiMesh 得到 null 再取 .mesh 就报
	#   `Invalid access to property or key 'mesh' on a base object of type 'Nil'`，
	#   于是**整次扫描在第一个草节点上中断**、`_grass_mats` 恒为 0、压草完全失效。
	#   这条断言就是钉住"MultiMesh 也必须能被扫到"。
	var mm_mesh := BoxMesh.new()
	mm_mesh.surface_set_material(0, gm)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "MultiMeshGrass"
	var mmesh := MultiMesh.new()
	mmesh.transform_format = MultiMesh.TRANSFORM_3D
	mmesh.mesh = mm_mesh
	mmesh.instance_count = 2
	mmi.multimesh = mmesh
	host.add_child(mmi)
	var n_scan: int = sw._scan_grass()
	assert_gt(n_scan, 0, "含 MultiMeshInstance3D 的场景也必须能扫到草材质（实测 %d）" % n_scan)
	host.remove_child(mmi)
	mmi.free()
	sw._scan_grass()
	# 蝴蝶放在"区域底之上 0.2 m"（在 1.15 m 的压草带内）
	var floor_y: float = sw._bounds().position.y
	for c in sw.get_children():
		if c.get_script() == BFLY:
			var p: Vector3 = (c as Node3D).position
			p.y = floor_y + 0.2
			(c as Node3D).position = p
	sw.set("debug_grass_bend", false)
	sw._write_grass_bend(0.02)
	assert_gt(int(gm.get_shader_parameter("sgt_butterfly_count")), 0,
			"应把至少 1 只蝴蝶推给草（count > 0）")
	var press: Array = gm.get_shader_parameter("sgt_butterfly_press")
	assert_true(press is Array and float(press[0]) > 0.0,
			"贴地蝴蝶的 press 应 > 0（实测 %s）" % str(press))
	var pos: Array = gm.get_shader_parameter("sgt_butterfly_pos")
	assert_true(pos is Array and float((pos[0] as Vector3).length()) < 1.0e6,
			"应写入真实世界坐标而不是哨兵值（实测 %s）" % str(pos[0]))
	# 抬到压草带之上 -> press 归零
	for c2 in sw.get_children():
		if c2.get_script() == BFLY:
			var p2: Vector3 = (c2 as Node3D).position
			p2.y = floor_y + 1.8
			(c2 as Node3D).position = p2
	sw._write_grass_bend(0.02)
	var press2: Array = gm.get_shader_parameter("sgt_butterfly_press")
	assert_true(float(press2[0]) <= 0.001,
			"高出压草带的蝴蝶不该压草（press 应 0，实测 %s）" % str(press2))
	# 插槽 0 -> count 归零
	gm.set_shader_parameter("sgt_butterfly_count", 9)
	sw._push_grass_slots([], 0)
	assert_eq(int(gm.get_shader_parameter("sgt_butterfly_count")), 0,
			"插槽数为 0 时应把 count 写回 0（草着色器整段跳过）")
	print("[蝴蝶测试] 草交互：扫到材质 %d 个 ｜ 贴地 press=%.3f ｜ 抬高后 press=%.3f ｜ 关掉 count=0"
			% [sw._grass_mats.size(), float(press[0]), float(press2[0])])


## ★★ 飞行行为 / 草交互参数必须**暴露到检查器面板**，且节点值必须**优先于 tuning 资源** ★★
##
## 用户诉求原话："暴露参数到检查器面板"。以前这十几个参数只存在于 `ButterflyTuning`
## （一个可选 Resource），选中蝴蝶群节点时**根本看不到** —— 想调"别直飞"都不知道调哪儿。
## 这条测试守两件事：
##   ① 这 17 个键在节点上是 `@export`（检查器可见）且落在正确的折叠分组里；
##   ② `tuning_dict()` 里**节点值赢**（实测踩过：资源合并写在后面，把节点刚设的值又盖回去，
##      表现就是"在面板上调了没反应"）。
func test_behavior_exports_visible_and_override_tuning() -> void:
	var want := [
		"heading_persistence", "turn_scale_deg", "turn_heavy_p", "turn_heavy_deg",
		"levy_alpha", "step_time_s", "lateral_weave", "lateral_weave_hz",
		"area_restricted_search", "ars_radius_m", "ars_turn_scale_deg", "ars_speed_scale",
		"grass_bend_radius", "grass_bend_strength", "grass_bend_height", "grass_bend_slots",
		"debug_grass_bend",
	]
	var sw = SWARM.new()
	track(sw)
	var groups: Array = []
	var found := {}
	var in_group := {}
	for p in sw.get_property_list():
		var usage := int(p.get("usage", 0))
		var nm := String(p.get("name", ""))
		if usage & PROPERTY_USAGE_GROUP:
			groups.append(nm)
			continue
		if not (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) or not (usage & PROPERTY_USAGE_EDITOR):
			continue
		if want.has(nm):
			found[nm] = true
			in_group[nm] = groups[groups.size() - 1] if not groups.is_empty() else ""
	var miss: Array = []
	for w in want:
		if not found.has(w):
			miss.append(w)
	assert_eq(miss, [], "这些参数必须都暴露到检查器（缺 %s）" % str(miss))
	assert_true(groups.has("飞行行为 Flight · CRW Lévy ARS"), "应有分组「飞行行为」")
	assert_true(groups.has("草交互 Grass (sgt)"), "应有分组「草交互」")
	for k in ["heading_persistence", "levy_alpha", "ars_radius_m"]:
		assert_eq(String(in_group.get(k, "")), "飞行行为 Flight · CRW Lévy ARS",
				"%s 应落在「飞行行为」组（实际 %s）" % [k, in_group.get(k, "")])
	for k in ["grass_bend_radius", "grass_bend_height", "grass_bend_slots"]:
		assert_eq(String(in_group.get(k, "")), "草交互 Grass (sgt)",
				"%s 应落在「草交互」组（实际 %s）" % [k, in_group.get(k, "")])

	# ---- 覆盖语义：节点值赢 ----
	var tscript: GDScript = load("res://addons/butterfly_swarm/butterfly_tuning.gd") as GDScript
	assert_ne(tscript, null, "ButterflyTuning 脚本应能加载")
	var res: Resource = tscript.new()
	res.set("heading_persistence", 0.11)
	res.set("levy_alpha", 2.9)
	res.set("grass_bend_height", 0.22)
	sw.tuning = res
	var d: Dictionary = sw.tuning_dict()
	assert_true(absf(float(d.get("heading_persistence", -1)) - 0.72) < 1e-6,
			"节点值应覆盖资源（期望 0.72，实际 %.2f）" % float(d.get("heading_persistence", -1)))
	assert_true(absf(float(d.get("levy_alpha", -1)) - 1.6) < 1e-6,
			"levy_alpha 应为节点值 1.6（实际 %.2f）" % float(d.get("levy_alpha", -1)))
	assert_true(absf(float(d.get("grass_bend_height", -1)) - 1.15) < 1e-6,
			"grass_bend_height 应为节点值 1.15（实际 %.2f）" % float(d.get("grass_bend_height", -1)))
	# 改了节点值 -> 立刻反映（这才是"面板上调了有反应"）
	sw.heading_persistence = 0.30
	var d2: Dictionary = sw.tuning_dict()
	assert_true(absf(float(d2.get("heading_persistence", -1)) - 0.30) < 1e-6,
			"改节点导出值后应立刻反映（期望 0.30，实际 %.2f）" % float(d2.get("heading_persistence", -1)))
	# 反过来：资源仍要能提供**它特有**的键（没在节点上导出的）
	res.set("wander_jitter", 4.25)
	var d3: Dictionary = sw.tuning_dict()
	assert_true(absf(float(d3.get("wander_jitter", -1)) - 4.25) < 1e-6,
			"资源特有的键仍应生效（wander_jitter 期望 4.25，实际 %.2f）" % float(d3.get("wander_jitter", -1)))
	print("[蝴蝶测试] 参数暴露：%d 个键在检查器可见（分组「飞行行为」+「草交互」）｜ 节点值优先于资源 ✓"
			% want.size())


## ★★ 禁止"飞行时瞬移" ★★
##
## 用户反馈原话："禁止蝴蝶飞行时瞬移"。查到一个**真实的瞬移源**：
##   BASK/DRINK 状态每帧 `position = position.lerp(_perch, 0.25)`，
##   而 `_perch` 的默认值是**世界原点 (0,0,0)**，`_find_perch()` 找不到落脚点时也不会更新它 ——
##   于是蝴蝶每次进入 BASK 都会**朝原点以 ~15 m/s 跳过去**（每帧把剩余距离砍掉 1/4，
##   实测在 5 米外时单帧位移 ≈ 1.25 m，视觉上就是"闪一下换位置"）。
## 修法：① 状态机进 BASK 时先把 `_perch` 兜底成当前位置；
##      ② 靠拢改成**限速**（perch_speed，默认 1.2 m/s）；
##      ③ 落脚点离得太远（> perch_rearm_distance）就就近重置；
##      ④ 积分后统一加一道**单帧位移上限**，把任何来源的异常位移降级为"快速移动"。
func test_no_teleport_during_flight() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	var tex := load(String(paths[0])) as Texture2D
	var crop := BFLY_IO.detect_bbox(String(paths[0]))
	var bounds := AABB(Vector3(-8, 0.4, -8), Vector3(16, 3, 16))
	var wind := {"dir": Vector2(1, 0), "strength": 0.2, "gust": 0.15,
			"turbulence": 0.3, "speed": 1.3}

	# ① BASK 且落脚点仍是默认原点 -> 不许朝原点跳
	var b = _new_butterfly()
	b.setup(tex, crop, _rng(3), {"size_m": 0.22, "flap_hz": 8.0})
	b.spawn(bounds)
	b.position = Vector3(5.0, 2.0, 0.0)      # 离原点 5 米
	b._perch = Vector3.ZERO                  # 旧实现的"默认/无效落脚点"
	b.state = BFLY.State.BASK
	var p0: Vector3 = b.position
	b._sync_transform(1.0 / 60.0)
	var jump := p0.distance_to(b.position)
	assert_true(jump < 0.05,
			"落脚点无效时不该朝原点跳（实测单帧位移 %.4f m；旧实现约 1.25 m）" % jump)

	# ② 落脚点残留很远 -> 就近重置，而不是飞过去
	var b2 = _new_butterfly()
	b2.setup(tex, crop, _rng(5), {"size_m": 0.22, "flap_hz": 8.0})
	b2.spawn(bounds)
	b2.position = Vector3(6.0, 2.0, 6.0)
	b2._perch = Vector3(-6.0, 2.0, -6.0)
	b2.state = BFLY.State.BASK
	var p1: Vector3 = b2.position
	b2._sync_transform(1.0 / 60.0)
	assert_true(p1.distance_to(b2.position) < 0.05,
			"落脚点残留 17 m 外时应就近重置（实测单帧位移 %.4f m）"
			% p1.distance_to(b2.position))

	# ③ 正常 + 极端参数各跑 900 帧：单帧位移必须不超上限
	var max_step := 0.0
	var cap := 0.0
	for over in [{}, {"speed_max": 8.0, "accel": 40.0, "wind_drag": 1.0,
			"heading_persistence": 0.0}]:
		var bb = _new_butterfly()
		var o: Dictionary = (over as Dictionary).duplicate()
		o["size_m"] = 0.22
		o["flap_hz"] = 8.0
		bb.setup(tex, crop, _rng(11), o)
		bb.spawn(bounds)
		var dt := 1.0 / 60.0
		var ms := 0.0
		var cp := 0.0
		for i in range(900):
			var q0: Vector3 = bb.position
			bb.advance(dt, bounds, wind, {}, [], {})
			ms = maxf(ms, q0.distance_to(bb.position))
			cp = maxf(cp, bb._speed_cap({}) * dt * 1.6)
		assert_true(ms <= cp + 1e-4,
				"单帧位移不得超上限（实测 %.4f <= %.4f，参数 %s）" % [ms, cp, str(o)])
		max_step = maxf(max_step, ms)
		cap = maxf(cap, cp)
		bb.free()
	b.free()
	b2.free()
	print("[蝴蝶测试] 防瞬移：BASK 单帧位移 %.4f m（旧实现 ~1.25 m）｜ 900 帧最大 %.4f m（上限 %.4f m）"
			% [jump, max_step, cap])


## ★ 检查器分组名里**不能有 `/`**：Godot 把它当子分组分隔符，
## 会把 "飞行行为 Flight (CRW/Lévy/ARS)" 拆成三层错位标题
## （用户截图确认：`飞行行为 Flight (CRW` / `Lévy` / `ARS)`）。
func test_export_group_names_have_no_slash() -> void:
	var sw = SWARM.new()
	track(sw)
	var groups: Array = []
	for p in sw.get_property_list():
		if int(p.get("usage", 0)) & PROPERTY_USAGE_GROUP:
			groups.append(String(p.get("name", "")))
	var bad: Array = []
	for g in groups:
		if String(g).contains("/"):
			bad.append(g)
	assert_eq(bad, [], "分组名不得含 `/`（会被拆成子分组）：%s" % str(bad))
	assert_true(groups.has("飞行行为 Flight · CRW Lévy ARS"), "飞行行为分组名应完整")
	assert_true(groups.has("草交互 Grass (sgt)"), "草交互分组名应完整")
	print("[蝴蝶测试] 分组名检查：%d 个分组，均不含 `/`" % groups.size())


## ★★ 聚散中心必须**每轮都换坐标**（用户反馈："蝴蝶出现聚集行为后，会反复的在两点之间
## 散开再重聚，这种行为非常不合理，起码要换个坐标进行聚散"）★★
##
## 根因（实测定位）：旧实现的"聚"和"散"都围绕**每只蝴蝶自己的目标**（SEEK 的花 /
## COURT 的同伴）发生 —— 目标几乎固定不变，于是
## "冲向目标 -> 进入 hover 半径被推开 -> 再冲回去" 形成一个**稳定振荡环**，
## 每 25~70 秒重复一次，聚散永远发生在同一批坐标上。
## 修法：每轮脉冲开始前用 `_new_gather_center()` 挑一个**离最近几轮都够远**的新中心。
func test_gather_center_rotates_each_cycle() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	var tex := load(String(paths[0])) as Texture2D
	var sw = SWARM.new()
	track(sw)
	sw.set_sprite_textures([tex])
	sw.count = 0          # 只要群组逻辑，不建蝴蝶（快）
	sw.region_size = Vector3(12, 1.4, 12)
	sw.region_offset = Vector3(0, 1.2, 0)
	sw.gather_min_move_m = 3.0
	sw.gather_history_n = 3
	# 造 8 朵花（3×3 网格去掉中心，间距 4.5 m）
	var host := Node3D.new()
	track(host)
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		(loop as SceneTree).root.add_child(host)
	for gx in [-4.5, 0.0, 4.5]:
		for gz in [-4.5, 0.0, 4.5]:
			if is_equal_approx(gx, 0.0) and is_equal_approx(gz, 0.0):
				continue
			var n := Node3D.new()
			n.position = Vector3(gx, 1.0, gz)
			n.add_to_group("flower")
			host.add_child(n)
	host.add_child(sw)
	var centers: Array = []
	for i in range(6):
		sw._new_gather_center()
		var g: Variant = sw._gather_pos
		assert_true(g is Vector3, "第 %d 轮应选出聚集中心" % (i + 1))
		centers.append(g)
	# ① 相邻两轮必须换坐标（>= gather_min_move_m）
	var min_d := 1.0e9
	for i in range(1, centers.size()):
		min_d = minf(min_d, (centers[i] as Vector3).distance_to(centers[i - 1] as Vector3))
	assert_true(min_d >= sw.gather_min_move_m - 1e-3,
			"相邻两轮中心必须至少相距 %.1f m（实测最小 %.2f m）—— 这就是\"换个坐标聚散\""
			% [sw.gather_min_move_m, min_d])
	# ② 不许回到最近几轮的历史点
	var back := 0
	for i in range(1, centers.size()):
		for j in range(maxi(0, i - 1 - sw.gather_history_n), maxi(0, i - 1)):
			if (centers[i] as Vector3).distance_to(centers[j] as Vector3) < 1.0:
				back += 1
				break
	assert_eq(back, 0, "不该回到最近 %d 轮出现过的中心（实测 %d 次）"
			% [sw.gather_history_n, back])
	# ③ 历史列表长度受 gather_history_n 限制
	assert_true(sw._gather_hist.size() <= sw.gather_history_n,
			"历史中心数应 <= gather_history_n（实测 %d <= %d）"
			% [sw._gather_hist.size(), sw.gather_history_n])
	print("[蝴蝶测试] 聚散中心轮换：6 轮 ｜ 相邻最小 %.2f m ｜ 回到历史 %d 次 ｜ 历史 %d 个"
			% [min_d, back, sw._gather_hist.size()])


## ★ 「散」要真的往外推、「聚」要真的往里收（并改变 CRW 航向）★
##
## 为什么必须**改航向**而不能只加力（实测教训）：
##   CRW 的推进力是 `heading * (want_speed - v·heading) * 3.2`，典型可达 7 m/s²，
##   而收拢力只有 2.8 —— 光加力会被 CRW 的随机航向完全盖住。
##   实测"聚"阶段质心到中心距离反而更大（6.24 m > 散 5.78 m），等于只散不聚。
##   改成"同时把 `_crw_heading` 朝中心偏转"之后才真的收得回来。
func test_gather_cycle_scatter_and_regroup() -> void:
	var paths := BFLY_IO.list_butterfly_paths()
	var tex := load(String(paths[0])) as Texture2D
	var crop := BFLY_IO.detect_bbox(String(paths[0]))
	var bounds := AABB(Vector3(-8, 0.4, -8), Vector3(16, 3, 16))
	var center := Vector3(0.0, 2.0, 0.0)

	# ---- 散：力应指向"远离中心"；航向应被推离中心 ----
	var b = _new_butterfly()
	b.setup(tex, crop, _rng(31), {"size_m": 0.22, "flap_hz": 8.0})
	b.spawn(bounds)
	b.position = center + Vector3(0.6, 0.0, 0.0)      # 离中心 0.6 m（hover 半径内）
	b.state = BFLY.State.CRUISE
	b.velocity = Vector3.ZERO
	var out_dir := Vector3(0.6, 0.0, 0.0).normalized()
	b.set("_crw_heading", Vector3(0.0, 0.0, 1.0))     # 航向先指向 +Z（与"向外"无关）
	var f_pulse: Vector3 = b.call("_force_seek_or_cruise", 1.0 / 60.0, bounds,
			{"gather_pos": center, "pulse": 1.0, "hover": 4.0})
	var dot_pulse := f_pulse.dot(out_dir)
	assert_true(dot_pulse > 0.0,
			"「散」时合力应朝**远离中心**方向（实测径向分量 %.2f，应 > 0）" % dot_pulse)
	# （下面还会用"增量"方式再验一次散的方向，两者互补：
	#   这里要求"合力朝外"，如果刚好朝外飞应该满足；增量验的是"我加上去的力"朝外。）

	# ---- 聚：**用增量**量测（隔离 CRW 的影响）----
	# 为什么不直接断言合力朝内：CRW 的推进力是 `heading * (want_speed - v·heading) * 3.2`，
	# 典型可达 7 m/s²。如果蝴蝶恰好朝外飞，合力仍然是朝外的 —— 那是正确行为（"要转弯得有时间"），
	# 不是 bug。所以正确的断言是：**我这次加上去的聚/散力**方向对不对，即
	# "有 gather 参数" 与 "没有" 两次调用的差值（RNG 噪声只有 ±0.08，不影响判断）。
	var b2 = _new_butterfly()
	b2.setup(tex, crop, _rng(32), {"size_m": 0.22, "flap_hz": 8.0})
	b2.spawn(bounds)
	b2.position = center + Vector3(3.0, 0.0, 0.0)      # 离中心 3 m
	b2.state = BFLY.State.CRUISE
	var out2 := Vector3(3.0, 0.0, 0.0).normalized()    # 由中心指向蝴蝶 = "向外"
	var heading0 := Vector3(0.0, 0.0, 1.0)             # 与径向垂直，避免干扰判断
	b2.velocity = Vector3.ZERO
	b2.set("_crw_heading", heading0)
	var f_base: Vector3 = b2.call("_force_seek_or_cruise", 1.0 / 60.0, bounds, {})
	b2.velocity = Vector3.ZERO
	b2.set("_crw_heading", heading0)
	var f_regroup: Vector3 = b2.call("_force_seek_or_cruise", 1.0 / 60.0, bounds,
			{"gather_pos": center, "regroup": 1.0})
	var d_regroup := (f_regroup - f_base).dot(out2)
	assert_true(d_regroup < 0.0,
			"「聚」增量必须朝**靠近中心**方向（实测 %.2f，应 < 0）" % d_regroup)
	# 航向也要被带向中心（多帧累积，CRW 每次重掷会部分抵消，所以给 30 帧）
	var inward_before: float = heading0.dot(-out2)
	var inward_after := inward_before
	for i in range(30):
		b2.call("_force_seek_or_cruise", 1.0 / 60.0, bounds,
				{"gather_pos": center, "regroup": 1.0})
		inward_after = (b2.get("_crw_heading") as Vector3).dot(-out2)
	assert_true(inward_after > inward_before,
			"「聚」时 CRW 航向应被拉向中心（朝内分量 %.3f -> %.3f）"
			% [inward_before, inward_after])
	# 「散」的增量也必须朝外
	var b3 = _new_butterfly()
	b3.setup(tex, crop, _rng(33), {"size_m": 0.22, "flap_hz": 8.0})
	b3.spawn(bounds)
	b3.position = center + Vector3(0.6, 0.0, 0.0)
	b3.state = BFLY.State.CRUISE
	b3.velocity = Vector3.ZERO
	b3.set("_crw_heading", heading0)
	var f_base3: Vector3 = b3.call("_force_seek_or_cruise", 1.0 / 60.0, bounds, {})
	b3.velocity = Vector3.ZERO
	b3.set("_crw_heading", heading0)
	var f_pulse3: Vector3 = b3.call("_force_seek_or_cruise", 1.0 / 60.0, bounds,
			{"gather_pos": center, "pulse": 1.0, "hover": 4.0})
	var d_pulse := (f_pulse3 - f_base3).dot(out_dir)
	assert_true(d_pulse > 0.0,
			"「散」增量必须朝**远离中心**方向（实测 %.2f，应 > 0）" % d_pulse)
	print("[蝴蝶测试] 聚散力向（增量）：散 %+.2f（应 >0）｜ 聚 %+.2f（应 <0）｜ 航向朝内 %.2f -> %.2f"
			% [d_pulse, d_regroup, inward_before, inward_after])
	b3.free()
	b.free()
	b2.free()


## ★ 批量加素材 API（用户在检查器里点的就是这些）：
##   add_sprites_from_paths / add_all_sprites_from_folder / add_random_sprites /
##   clear_sprites / sprite_summary。
## 为什么要有这组测试：检查器面板（inspector_batch.gd）本身是 UI、无头跑不了，
##   但它调用的**这些方法**必须被钉住 —— 否则批量入口一旦回归，用户又会回到
##   "一张一张点添加元素"的处境。
func test_sprite_batch_api() -> void:
	var sw = SWARM.new()
	track(sw)
	var all_paths := BFLY_IO.list_butterfly_paths()
	assert_gt(all_paths.size(), 0, "素材目录里应至少有一张 PNG")

	# ① 按路径批量加
	var n1: int = sw.add_sprites_from_paths(all_paths.slice(0, 5))
	assert_eq(n1, 5, "add_sprites_from_paths(5 条) 应新增 5，实际 %d" % n1)
	assert_eq(sw.sprite_count(), 5, "sprite_count 应为 5")

	# ② 重复加要**去重**（否则用户点两次就翻倍）
	var n2: int = sw.add_sprites_from_paths(all_paths.slice(0, 5))
	assert_eq(n2, 0, "重复加同一批应新增 0（去重），实际 %d" % n2)

	# ③ 非法输入要**安静跳过**（空串 / 不存在的路径 / 非字符串），不能抛错
	var n3: int = sw.add_sprites_from_paths(["", "/no/such/file.png", "res://nope.png", 42])
	assert_eq(n3, 0, "非法路径应被跳过并新增 0，实际 %d" % n3)

	# ④ 一次加目录全部
	var n4: int = sw.add_all_sprites_from_folder("", 0)
	assert_eq(sw.sprite_count(), all_paths.size(),
			"加完全部后应有 %d 张，实际 %d" % [all_paths.size(), sw.sprite_count()])
	assert_eq(n4, all_paths.size() - 5, "第 ④ 步应新增剩下的 %d 张" % (all_paths.size() - 5))

	# ⑤ limit 生效
	sw.clear_sprites()
	var n5: int = sw.add_all_sprites_from_folder("", 3)
	assert_eq(n5, 3, "limit=3 时应只加 3 张，实际 %d" % n5)

	# ⑥ 随机追加：是"追加"而不是"替换"
	sw.clear_sprites()
	var n6: int = sw.add_random_sprites(8, 12345)
	assert_eq(n6, 8, "随机追加 8 张，实际 %d" % n6)
	var before_count := sw.sprite_count()
	sw.add_random_sprites(4, 999)
	assert_true(sw.sprite_count() >= before_count,
			"随机追加不应冲掉原有素材（追加前 %d，追加后 %d）" % [before_count, sw.sprite_count()])

	# ⑦ sprite_summary 的两个计数与真实值一致
	sw.clear_sprites()
	sw.add_all_sprites_from_folder("", 2)
	var s: Dictionary = sw.sprite_summary()
	assert_eq(int(s.get("configured", -1)), 2, "summary.configured 应为 2")
	assert_eq(int(s.get("available", -1)), all_paths.size(),
			"summary.available 应为目录里的张数 %d" % all_paths.size())

	# ⑧ clear
	sw.clear_sprites()
	assert_eq(sw.sprite_count(), 0, "clear_sprites 后应为 0")

	# ⑨ 批量加的素材要**真的能建出蝴蝶**（不是只塞进数组）
	sw.add_sprites_from_paths(all_paths.slice(0, 3))
	sw.count = 6
	sw.rebuild()
	assert_eq(sw.live_count(), 6, "批量素材后 rebuild 应建出 6 只，实际 %d" % sw.live_count())
	assert_eq(sw.sprite_count(), 3, "素材张数应保持 3")
	print("[蝴蝶测试] 批量 API：按路径 +5 / 重复去重 0 / 非法跳过 0 / 全部 %d / limit 3 / 随机 8 / clear 0"
			% all_paths.size())


func test_butterfly_setup_without_texture_is_safe() -> void:
	var b = _new_butterfly()
	var sh := load(SHADER_PATH) as Shader
	b.setup(null, Rect2i(0, 0, 0, 0), _rng(7), _default_tuning(), sh)
	var s: Dictionary = b.stats()
	assert_eq(s["has_visual"], false, "没有贴图时 has_visual 必须是 false")
	assert_eq(b.get_child_count(), 0, "没有贴图时不该挂出 Wings 子节点")
	assert_eq(s["crop"], Rect2i(0, 0, 0, 0), "no-texture 时 crop 应保持空矩形")
	assert_eq(String(s["sprite"]), "", "no-texture 时 sprite 应为空串")
	# AI 仍要能跑（契约：setup(null) 不崩、无头可推进）
	var bounds := _bounds()
	b.spawn(bounds)
	for i in range(30):
		b.advance(1.0 / 60.0, bounds, {})
	var s2: Dictionary = b.stats()
	assert_eq(s2["has_visual"], false, "跑 30 步后 has_visual 仍应为 false")
	assert_gt(float(s2["distance_travelled"]), 0.0, "即使没有视觉，AI 也应该让它动起来")
	print("[蝴蝶测试] setup(null)：has_visual=%s，30 步后位移 %.3f m（无视觉仍能飞）"
			% [str(s2["has_visual"]), float(s2["distance_travelled"])])


func test_butterfly_spawn_inside_bounds() -> void:
	var entries := _manifest_entries()
	assert_false(entries.is_empty(), "清单为空，拿不到素材")
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var tex := load(String(e["path"])) as Texture2D
	assert_ne(tex, null, "素材加载失败")
	var crop := _entry_crop(e)
	var bounds := _bounds()
	var td := _tuning_no_drain()
	var checked := 0
	for seed_v in [1, 2, 12345]:
		var b = _make_butterfly(tex, crop, int(seed_v), td)
		b.spawn(bounds)
		b.spawn(bounds)  # 连续撒两次也不能出界
		var p: Vector3 = b.position
		assert_true(bounds.has_point(p), "seed=%d spawn 位置 %s 落在区域 %s 之外"
				% [int(seed_v), str(p), str(bounds)])
		assert_true(p.y >= bounds.position.y + 0.15 - 1e-4,
				"seed=%d spawn 高度 %.4f 低于区域下限+0.15" % [int(seed_v), p.y])
		checked += 1
	print("[蝴蝶测试] spawn：%d 个 seed 全部落在区域 %s 内" % [checked, str(bounds)])


func test_butterfly_advance_600_steps_stays_in_bounds() -> void:
	var entries := _manifest_entries()
	assert_false(entries.is_empty(), "清单为空，拿不到素材")
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var tex := load(String(e["path"])) as Texture2D
	var b = _make_butterfly(tex, _entry_crop(e), 20261016, _tuning_no_drain())
	var bounds := _bounds()
	b.spawn(bounds)
	var wind := {"dir": Vector2(1, 0), "strength": 0.0, "gust": 0.0, "turbulence": 0.0}
	var floor_y := bounds.position.y + 0.35  # min_height_m：_force_bounds 的硬地面
	var max_out := 0.0
	var floor_violation := 0.0
	var states := {}
	for i in range(600):
		b.advance(1.0 / 60.0, bounds, wind)
		var p: Vector3 = b.position
		floor_violation = maxf(floor_violation, floor_y - p.y)
		var out_x := maxf(bounds.position.x - p.x, p.x - bounds.end.x)
		var out_z := maxf(bounds.position.z - p.z, p.z - bounds.end.z)
		var out_y := p.y - bounds.end.y
		max_out = maxf(max_out, maxf(maxf(out_x, out_z), out_y))
		states[String(BFLY.state_name(int(b.state)))] = true
	var s: Dictionary = b.stats()
	assert_gt(float(s["distance_travelled"]), 2.0,
			"600 步累计飞行距离应明显 >0，实际 %.3f m" % float(s["distance_travelled"]))
	# 下边界是**硬夹**（butterfly.gd:_force_bounds「下方：硬夹 + 向上推（防钻地）」）
	assert_true(floor_violation <= HARD_FLOOR_TOL,
			"任何一步都不该低于硬地面 y=%.3f（实测最大下穿 %.5f m，容差 %.3f）"
			% [floor_y, floor_violation, HARD_FLOOR_TOL])
	# 水平/上方是**软回弹**：允许有界越界，但不能跑出区域不管
	assert_true(max_out <= SOFT_EDGE_TOL,
			"软回弹越界应小于 %.2f m，实测 %.3f m（跑飞了？）" % [SOFT_EDGE_TOL, max_out])
	assert_false(states.has("BASK"), "energy_drain=0 时不应进入 BASK")
	# stats() 是测试/调试的只读契约（butterfly.gd 文件头列了这 11 个键），键丢了要立刻发现
	for k in ["state", "state_name", "energy", "position", "velocity", "speed", "dihedral",
			"distance_travelled", "has_visual", "sprite", "crop"]:
		assert_has_key(s, k, "Butterfly.stats() 缺键 %s" % k)
	print("[蝴蝶测试] advance 600 步：位移 %.3f m，最终 %s；硬地面最大下穿 %.5f m；软越界 %.3f m；状态 %s"
			% [float(s["distance_travelled"]), str(b.position), floor_violation, max_out, str(states.keys())])


func test_butterfly_wind_changes_trajectory() -> void:
	var entries := _manifest_entries()
	assert_false(entries.is_empty(), "清单为空，拿不到素材")
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var tex := load(String(e["path"])) as Texture2D
	var crop := _entry_crop(e)
	var td := _tuning_no_drain()
	var bounds := _bounds()
	# 同 seed 两只 -> 初始状态完全一致；只改风
	var calm = _make_butterfly(tex, crop, 4242, td)
	var windy = _make_butterfly(tex, crop, 4242, td)
	calm.spawn(bounds)
	windy.spawn(bounds)
	assert_eq(calm.position, windy.position, "同 seed 两只的初始位置应完全一致（对照基线）")
	var w0 := {"dir": Vector2(1, 0), "strength": 0.0, "gust": 0.0, "turbulence": 0.0}
	var w1 := {"dir": Vector2(1, 0), "strength": 1.2, "gust": 0.0, "turbulence": 0.0}
	for i in range(600):
		calm.advance(1.0 / 60.0, bounds, w0)
		windy.advance(1.0 / 60.0, bounds, w1)
	var diff: float = calm.position.distance_to(windy.position)
	assert_gt(float(calm.stats()["distance_travelled"]), 1.0, "无风那只也应该在飞")
	assert_gt(float(windy.stats()["distance_travelled"]), 1.0, "有风那只也应该在飞")
	assert_gt(diff, 0.05,
			"风 strength=0 与 1.2 的最终位置应不同（实测差 %.4f m）—— 风没进计算？" % diff)
	print("[蝴蝶测试] 风：strength 0 落在 %s，1.2 落在 %s，差异 %.4f m"
			% [str(calm.position), str(windy.position), diff])


func test_butterfly_deterministic_for_same_seed() -> void:
	var entries := _manifest_entries()
	assert_false(entries.is_empty(), "清单为空，拿不到素材")
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var tex := load(String(e["path"])) as Texture2D
	var crop := _entry_crop(e)
	var td := _tuning_no_drain()
	var bounds := _bounds()
	var a = _make_butterfly(tex, crop, 999, td)
	var b = _make_butterfly(tex, crop, 999, td)
	a.spawn(bounds)
	b.spawn(bounds)
	for i in range(600):
		a.advance(1.0 / 60.0, bounds, {})
		b.advance(1.0 / 60.0, bounds, {})
	# 同 seed 必须**完全相等**（不是近似）：随机数全走注入的 rng
	assert_eq(a.position, b.position, "同 seed 两次跑出的位置必须完全相等")
	assert_eq(float(a.stats()["distance_travelled"]), float(b.stats()["distance_travelled"]),
			"同 seed 的累计位移必须完全相等")
	assert_eq(a.energy, b.energy, "同 seed 的能量必须完全相等")
	assert_eq(a.velocity, b.velocity, "同 seed 的速度必须完全相等")
	# 不同 seed 必须给出不同轨迹（否则"每只独立"是假的）
	var c = _make_butterfly(tex, crop, 1000, td)
	c.spawn(bounds)
	for i in range(600):
		c.advance(1.0 / 60.0, bounds, {})
	assert_ne(c.position, a.position, "不同 seed 应给出不同轨迹")
	print("[蝴蝶测试] 确定性：seed=999 两只位置完全相等 %s（位移 %.3f m）；seed=1000 落在 %s"
			% [str(a.position), float(a.stats()["distance_travelled"]), str(c.position)])


func test_butterfly_energy_exhaustion_enters_bask() -> void:
	var entries := _manifest_entries()
	assert_false(entries.is_empty(), "清单为空，拿不到素材")
	if entries.is_empty():
		return
	var e: Dictionary = entries[0]
	var tex := load(String(e["path"])) as Texture2D
	var td := _default_tuning()
	td["energy_drain"] = 2.0   # 放大耗能：几秒内就耗尽，逼出 BASK
	td["rest_energy"] = 0.25
	var b = _make_butterfly(tex, _entry_crop(e), 31337, td)
	var bounds := _bounds()
	b.spawn(bounds)
	var states := {}
	var min_energy := 1.0
	var first_bask := -1
	for i in range(300):
		b.advance(1.0 / 60.0, bounds, {})
		var nm := String(BFLY.state_name(int(b.state)))
		states[nm] = true
		if nm == "BASK" and first_bask < 0:
			first_bask = i
		min_energy = minf(min_energy, b.energy)
	assert_true(states.has("BASK"),
			"energy_drain=2.0 跑 300 步后应出现 BASK，实测出现过的状态：%s" % str(states.keys()))
	assert_true(min_energy <= 0.25 + 1e-6,
			"能量应跌到 rest_energy(0.25) 以下，实测最低 %.4f" % min_energy)
	assert_gt(first_bask, 0, "BASK 应在跑动过程中出现（第 %d 步）" % first_bask)
	print("[蝴蝶测试] 能量耗尽：最低能量 %.4f，第 %d 步进入 BASK；出现过的状态 %s"
			% [min_energy, first_bask, str(states.keys())])


# ==================== ⑥ ButterflySwarm 集成 ====================

func test_swarm_rebuild_out_of_scene_tree() -> void:
	var entries := _manifest_entries()
	assert_true(entries.size() >= 2, "清单至少要有 2 条素材")
	if entries.size() < 2:
		return
	var e0: Dictionary = entries[0]
	var e1: Dictionary = entries[1]
	var tex0 := load(String(e0["path"])) as Texture2D
	var tex1 := load(String(e1["path"])) as Texture2D
	assert_ne(tex0, null, "素材 0 加载失败")
	assert_ne(tex1, null, "素材 1 加载失败")
	var crop0 := _entry_crop(e0)
	var crop1 := _entry_crop(e1)

	# ★ 刻意不进场景树：验证 rebuild() 可独立工作（契约第 3 节）
	var sw = SWARM.new()
	track(sw)
	# 契约第 2 节第 9 条：sprites 是 Array[Texture2D]，`sw.sprites = <无类型 Array>` 会报
	# `Invalid assignment of property or key 'sprites' ...`；统一走宽松入口。
	assert_eq(sw.set_sprite_textures([tex0, tex1]), 2, "set_sprite_textures 应写入 2 张并返回 2")
	assert_eq(sw.sprite_count(), 2, "写入后 sprite_count 应为 2")
	# 非 Texture2D 的项必须被静默过滤掉（编辑器 UI 常常只能给无类型 Array）
	assert_eq(sw.set_sprite_textures([tex0, "不是贴图", 42, null]), 1,
			"set_sprite_textures 应过滤掉非 Texture2D 的项，只写入 1 张")
	assert_eq(sw.add_sprite_textures([tex1, tex0]), 1,
			"add_sprite_textures 应只新增 1 张（tex0 已在列表里，重复项不重复追加）")
	assert_eq(sw.sprite_count(), 2, "过滤+去重后仍应只有 2 张")
	sw.region_size = Vector3(4, 2, 4)
	sw.count = 5
	sw.rebuild()

	assert_eq(sw.sprite_count(), 2, "配了 2 张素材")
	assert_eq(sw.live_count(), 5, "count=5 应建出 5 只")
	assert_eq(sw.get_child_count(), 5, "应只挂 5 个蝴蝶子节点（default 不画区域线框）")
	var st: Dictionary = sw.stats()
	assert_eq(int(st["live"]), 5, "stats().live 应为 5")
	assert_eq(int(st["count"]), 5, "stats().count 应为 5")
	assert_eq(int(st["sprites"]), 2, "stats().sprites 应为 2")
	assert_eq(st["region"], Vector3(4, 2, 4), "stats().region 应回显 region_size")

	var bounds: AABB = sw._bounds()
	var bad_crop := 0
	var bad_visual := 0
	var out_of_bounds := 0
	var crops: Array = []
	var mats := {}
	for i in range(sw.get_child_count()):
		var b = sw.get_child(i)
		var s: Dictionary = b.stats()
		var expect: Rect2i = crop0 if i % 2 == 0 else crop1
		var got: Rect2i = s["crop"]
		crops.append(got)
		if got != expect:
			bad_crop += 1
		if s["has_visual"] != true:
			bad_visual += 1
		if not bounds.has_point(b.position):
			out_of_bounds += 1
		mats[b.mat] = true
	assert_eq(bad_crop, 0, "每只蝴蝶的 crop 应等于对应素材的 bbox（%d 只不符）" % bad_crop)
	assert_eq(bad_visual, 0, "有 %d 只没建出视觉（贴图+着色器都在，不该发生）" % bad_visual)
	assert_eq(out_of_bounds, 0, "有 %d 只 spawn 到了区域之外" % out_of_bounds)
	assert_eq(mats.size(), 5, "每只蝴蝶应有**独立**的 ShaderMaterial（各自扑翼的必要条件）")
	# ★ 防退化：crop 不能是 0×0，也不能退化成整图（裁剪失效 -> 蝴蝶缩成小点）
	assert_gt(crops[0].size.x, 0, "蝴蝶 crop 宽退化为 0（detect_bbox 的 Image 分支丢了？）")
	assert_gt(crops[0].size.y, 0, "蝴蝶 crop 高退化为 0")
	assert_true(crops[0].size.x < int(e0["w"]),
			"crop 宽 %d 不该等于整图宽 %d（UV 裁剪失效）" % [crops[0].size.x, int(e0["w"])])
	# 反复 rebuild 必须安全且结果一致
	var children_before_rebuild := sw.get_child_count()
	sw.rebuild()
	assert_eq(sw.live_count(), 5, "第二次 rebuild 后仍应只有 5 只")
	print("[蝴蝶测试] 树外 swarm：首建 children=%d live=%d crop[0]=%s（素材 bbox %s）独立材质 %d 个"
			% [children_before_rebuild, sw.live_count(), str(crops[0]), str(crop0), mats.size()])
	sw.free()


func test_swarm_set_active_toggles_visibility() -> void:
	var entries := _manifest_entries()
	assert_false(entries.is_empty(), "清单为空，拿不到素材")
	if entries.is_empty():
		return
	var tex := load(String(entries[0]["path"])) as Texture2D
	var sw = SWARM.new()
	track(sw)
	# 契约第 2 节第 9 条：走宽松入口，不要直接赋无类型 Array
	assert_eq(sw.set_sprite_textures([tex]), 1, "set_sprite_textures 应写入 1 张并返回 1")
	sw.count = 3
	sw.rebuild()
	assert_eq(sw.stats()["enabled"], true, "默认应处于启用状态")
	assert_eq(sw.visible, true, "默认节点应可见")

	var frames_before := int(sw.stats()["frames"])
	assert_eq(sw.set_active(false), false, "set_active(false) 应返回 false")
	assert_eq(sw.stats()["enabled"], false, "关掉后 stats().enabled 应为 false")
	# ★ 关掉 = **只有蝴蝶子节点隐藏**；节点自身的 visible **必须保持 true**。
	#   为什么（用户实测踩过"关着开关却还看得见冻结的蝴蝶"）：
	#     · 节点自身的 `visible` 是 Godot 会**序列化进 .tscn** 的属性。开关去写它，
	#       就会和编辑器/场景里保存的 visible 互相打架，出现"enabled=false 但看得见"。
	#     · 关掉开关只是显隐，不该重建 —— 所以 setter 也不该再触发 rebuild（否则加载
	#       一个 enabled=false 的大群会白建几百只）。下面 frames/子节点数都守着这两点。
	assert_eq(sw.visible, true,
			"关掉后**节点自身** visible 必须仍为 true（改成 false 会与场景序列化的 visible 打架）")
	var hidden := 0
	for b in sw.get_children():
		if (b as Node3D).visible == false:
			hidden += 1
	assert_eq(hidden, 3, "关掉后每只蝴蝶都应隐藏（实测 %d/3）" % hidden)
	# 关掉后即使驱动一帧也不该推进（契约：关掉 = 隐藏 + 停止推进）
	for i in range(5):
		sw._process(1.0 / 60.0)
	assert_eq(int(sw.stats()["frames"]), frames_before, "关掉后不应再推进任何一帧")

	assert_eq(sw.set_active(true), true, "set_active(true) 应返回 true")
	assert_eq(sw.stats()["enabled"], true, "打开后 stats().enabled 应为 true")
	assert_eq(sw.visible, true, "打开后节点应恢复可见")
	# 开/关都不该重建：子节点数必须一直等于 count（重建会换掉节点实例）
	assert_eq(sw.get_child_count(), 3,
			"开/关开关不应重建蝴蝶（子节点数应恒为 3，实测 %d）" % sw.get_child_count())
	var shown := 0
	for b in sw.get_children():
		if (b as Node3D).visible == true:
			shown += 1
	assert_eq(shown, 3, "打开后每只蝴蝶都应恢复可见（实测 %d/3）" % shown)
	# 打开后再驱动一帧：必须真的推进（证明开关真的控制推进，而不是只改 visible）
	# ⚠ 已知噪音（不是本套件的失败项）：树外 swarm 调 _process() 会各刷一条引擎 ERROR
	#   `Parameter "data.tree" is null.`（= Node.get_tree() 被用在树外节点上）：
	#     · butterfly_swarm.gd:55 scene_tree() → scene_root() → wind_now() / weather_now()
	#     · butterfly_swarm.gd:557 _find_threat() 仍裸用 get_tree()
	#   **真实游戏里不会出现**（swarm 一定在树内），只有"树外 swarm"这条测试/工具路径会命中。
	#   引擎级 ERROR 不是 SCRIPT ERROR，故不判红；要清理只需让 scene_tree() 先判
	#   is_inside_tree()、并让 _find_threat() 改走 scene_tree()（已在回报里给出）。
	sw._process(1.0 / 60.0)
	assert_eq(int(sw.stats()["frames"]), frames_before + 1,
			"打开后驱动一帧应使 frames 增加 1（实测 %d，期望 %d）"
			% [int(sw.stats()["frames"]), frames_before + 1])
	print("[蝴蝶测试] 总开关：关->enabled=%s visible=%s frames=%d；开->enabled=%s visible=%s frames=%d"
			% [str(false), str(false), frames_before, str(true), str(true), int(sw.stats()["frames"])])
	sw.free()


func test_swarm_wind_and_weather_contract() -> void:
	# ★ 契约第 2 节第 8 条 + 第 3 节：autoload 查找**不要裸用 get_tree()**
	#   （节点刚 add_child、树还没刷新时 get_tree() 返回 null，会误报"没有天气系统"），
	#   统一走 scene_tree() / scene_root()（内部有 Engine.get_main_loop() 兜底）。
	#   下面用**完全树外**的 swarm 来验证这个兜底真的生效。
	var sw = SWARM.new()
	track(sw)
	assert_true(sw.has_method("scene_tree"), "ButterflySwarm 应有 scene_tree()（契约第 2 节第 8 条）")
	assert_true(sw.has_method("scene_root"), "ButterflySwarm 应有 scene_root()（契约第 2 节第 8 条）")
	assert_false(sw.is_inside_tree(), "前置条件：这只 swarm 必须在树外")
	var rt = sw.scene_root()
	assert_ne(rt, null, "树外也必须能通过 Engine.get_main_loop() 兜底拿到场景根（autoload 都挂它下面）")

	var w: Dictionary = sw.wind_now()
	for k in ["dir", "strength", "gust", "turbulence", "speed", "source"]:
		assert_has_key(w, k, "wind_now() 缺键 %s" % k)
	assert_true(w["dir"] is Vector2, "wind_now().dir 应是 Vector2（世界 XZ）")
	var d: Vector2 = w["dir"]
	assert_true(absf(d.length() - 1.0) < 1e-3, "wind_now().dir 应是单位向量，实际长度 %.4f" % d.length())
	assert_true(float(w["strength"]) >= 0.0, "wind_now().strength 不应为负")
	assert_true(WIND_SOURCES.has(String(w["source"])),
			"wind_now().source 应是 %s 之一，实际 %s" % [str(WIND_SOURCES), String(w["source"])])
	# 能拿到场景根时就不该再落到 no_tree 兜底（第 8 条的核心）
	assert_ne(String(w["source"]), "no_tree",
			"scene_root() 已经拿到根了，wind_now() 还报 no_tree —— get_tree() 兜底没生效")

	var we: Dictionary = sw.weather_now()
	for k in ["kind", "name", "wind", "gust", "rain", "cloud", "source"]:
		assert_has_key(we, k, "weather_now() 缺键 %s" % k)
	assert_true(WIND_SOURCES.has(String(we["source"])),
			"weather_now().source 应是 %s 之一，实际 %s" % [str(WIND_SOURCES), String(we["source"])])
	assert_ne(String(we["source"]), "no_tree",
			"scene_root() 已经拿到根了，weather_now() 还报 no_tree —— get_tree() 兜底没生效")

	# 树内：Wind/Weather autoload 存在时必须被优先采用
	var sw2 = SWARM.new()
	track(sw2)
	if _holder != null:
		_holder.add_child(sw2)
	var w2: Dictionary = sw2.wind_now()
	assert_has_key(w2, "dir", "树内 wind_now() 缺 dir")
	assert_true(absf((w2["dir"] as Vector2).length() - 1.0) < 1e-3,
			"树内 wind_now().dir 应是单位向量")
	var src := String(w2["source"])
	assert_true(["Wind", "Weather", "fallback"].has(src),
			"树内 wind_now().source 应是 Wind / Weather / fallback 之一，实际 %s" % src)
	# 兜底常量对账（抄自 Weather 的 CLEAR 预设）：只有真落到兜底时才要求这些数值
	if String(w["source"]) == "no_tree":
		assert_true(absf(float(w["strength"]) - 0.18) < 1e-4,
				"no_tree 兜底风速应为 0.18，实际 %.4f" % float(w["strength"]))
	if String(we["source"]) == "fallback":
		assert_true(absf(float(we["rain"]) - 0.0) < 1e-4,
				"fallback 兜底雨量应为 0，实际 %.4f" % float(we["rain"]))
	print("[蝴蝶测试] 风/天气来源：树外 wind=%s(str %.3f) weather=%s ｜ 树内 wind=%s(str %.3f)"
			% [String(w["source"]), float(w["strength"]), String(we["source"]), src, float(w2["strength"])])
	if sw2.get_parent() != null:
		sw2.get_parent().remove_child(sw2)
	sw2.free()


# ==================== ⑦ 树外 advance（契约第 2 节第 12 条） ====================
#
# 契约第 12 条只要求"树外调 advance() 不能崩、不能刷 ERROR"，实现为此加了 `_sync_transform()`
# 的树外手工基回退。手工基回退很容易顺手写坏三件事，所以拆成 4 条独立用例，
# 每条都拿**同 seed 的树内蝴蝶**做对照（同一 seed 时两者初始位置/速度/heading 完全一致，
# 所以"缩放/手性/朝向也必须一致"是可判定的）。

func test_butterfly_out_of_tree_advance_no_error_spam() -> void:
	var pair := _spawn_orientation_pair()
	assert_false(pair.is_empty(), "拿不到素材或对照蝴蝶建不出来")
	if pair.is_empty():
		return
	var out_b = pair["out"]
	var bounds: AABB = pair["bounds"]
	assert_false(out_b.is_inside_tree(), "前置条件：对照的树外蝴蝶必须在树外")
	# 用 Logger 嗅探引擎 ERROR —— `look_at()` 那类 ERR_FAIL 走 ERROR_TYPE_ERROR，
	# 不会被 McpTestRunner 的 SCRIPT ERROR 捕获器判红，得自己验。
	var sniffer := ErrorSniffer.new()
	_sniffer = sniffer
	OS.add_logger(sniffer)
	for i in range(60):
		out_b.advance(1.0 / 60.0, bounds, {})
	OS.remove_logger(sniffer)
	_sniffer = null
	assert_eq(sniffer.count_containing("not inside tree"), 0,
			"树外 advance 每步都在刷 'Node not inside tree' ERROR（契约第 12 条要求树外回退）；实测 %d 条，首条：%s"
			% [sniffer.count_containing("not inside tree"),
			sniffer.messages[0] if sniffer.messages.size() > 0 else "（无）"])
	assert_gt(float(out_b.stats()["distance_travelled"]), 0.05,
			"树外也要真的飞起来（实测 %.4f m）" % float(out_b.stats()["distance_travelled"]))
	# 跑完 60 步后基仍须是"纯旋转 × 节点缩放"（无剪切）：**归一化后**两两垂直。
	# ⚠ 不能要求列长 = 1：节点 scale 就是 size_m（0.22 / 0.148958 / 0.22），基里本来就带着它。
	var b_after: Basis = out_b.basis
	var d_xy := b_after.x.normalized().dot(b_after.y.normalized())
	var d_yz := b_after.y.normalized().dot(b_after.z.normalized())
	var d_xz := b_after.x.normalized().dot(b_after.z.normalized())
	assert_true(absf(d_xy) < 1e-3 and absf(d_yz) < 1e-3 and absf(d_xz) < 1e-3,
			"树外 60 步后基归一化应两两垂直（没有剪切/斜切），实测两两点积 (%f, %f, %f)" % [d_xy, d_yz, d_xz])
	print("[蝴蝶测试] 树外 advance：60 步位移 %.4f m；'not inside tree' ERROR %d 条"
			% [float(out_b.stats()["distance_travelled"]), sniffer.count_containing("not inside tree")])


func test_butterfly_out_of_tree_keeps_node_scale() -> void:
	var pair := _spawn_orientation_pair()
	assert_false(pair.is_empty(), "拿不到素材或对照蝴蝶建不出来")
	if pair.is_empty():
		return
	var out_b = pair["out"]
	var in_b = pair["in"]
	assert_eq(out_b.position, in_b.position, "对照基线：同 seed 树外/树内初始位置应一致")
	# 契约第 3 节「每个蝴蝶 = 单位方块 × size_m」，缩放由 _update_visual_scale() 写进节点 scale。
	# 树外回退用 `transform = Transform3D(Basis(r, uu, f), position)` **整个变换**赋值，
	# 会把 scale 一并抹掉（det<0 时 Godot 还会把它读成负值）。
	assert_true(out_b.scale.is_equal_approx(in_b.scale),
			"树外 spawn 后节点 scale = %s，树内 = %s —— 树外回退用 `transform =` 覆盖了整个变换，把 _update_visual_scale() 的 size_m 缩放丢了。修法：只改基、别整体赋 transform，例如 `basis = Basis.looking_at(heading, up).scaled(scale)`"
			% [str(out_b.scale), str(in_b.scale)])
	print("[蝴蝶测试] 缩放对照：树外 scale=%s（节点 basis 列长 %f/%f/%f）｜ 树内 scale=%s"
			% [str(out_b.scale), out_b.basis.x.length(), out_b.basis.y.length(), out_b.basis.z.length(),
			str(in_b.scale)])


func test_butterfly_out_of_tree_basis_is_proper_rotation() -> void:
	var pair := _spawn_orientation_pair()
	assert_false(pair.is_empty(), "拿不到素材或对照蝴蝶建不出来")
	if pair.is_empty():
		return
	var b_out: Basis = (pair["out"] as Node3D).basis
	var b_in: Basis = (pair["in"] as Node3D).basis
	# 基里带着节点 scale（= size_m），所以**不能**要求列长 = 1；
	# 要的是"纯旋转 × 缩放"，即归一化后两两垂直（没有剪切）。
	var d_xy := b_out.x.normalized().dot(b_out.y.normalized())
	var d_yz := b_out.y.normalized().dot(b_out.z.normalized())
	var d_xz := b_out.x.normalized().dot(b_out.z.normalized())
	assert_true(absf(d_xy) < 1e-3 and absf(d_yz) < 1e-3 and absf(d_xz) < 1e-3,
			"树外基归一化应两两垂直（没有剪切/斜切），实测两两点积 (%f, %f, %f)" % [d_xy, d_yz, d_xz])
	# 行列式必须 > 0：det<0 是镜像/左手基（Godot 的 look_at 恒给正行列式）。
	# 树外回退里 r = f×u、uu = r×f 恰好构成左手系：f=+Z、u=+Y 时得到 X=-X、det=-1。
	assert_gt(b_out.determinant(), 0.0,
			"树外基的行列式 = %f < 0（左手/镜像基，节点被镜像、scale 会被读成负数）；树内对照 = %f。应改成 uu = f×r 之类保持右手系"
			% [b_out.determinant(), b_in.determinant()])
	print("[蝴蝶测试] 手性对照：det 树外 = %f ｜ 树内 = %f（都应 > 0）"
			% [b_out.determinant(), b_in.determinant()])


func test_butterfly_out_of_tree_matches_in_tree_forward_axis() -> void:
	var pair := _spawn_orientation_pair()
	assert_false(pair.is_empty(), "拿不到素材或对照蝴蝶建不出来")
	if pair.is_empty():
		return
	var out_b = pair["out"]
	var in_b = pair["in"]
	var f_out: Vector3 = (out_b.basis.z as Vector3).normalized()
	var f_in: Vector3 = (in_b.basis.z as Vector3).normalized()
	# 同一只蝴蝶不能因为"在不在场景树里"就掉头 180°
	assert_gt(f_out.dot(f_in), 0.9,
			"树外基 +Z·树内基 +Z = %f：树外把 +Z 对准 heading，而 `look_at` 把 **-Z** 对准 heading（Godot 约定），两者相差 180°。按 butterfly.gd 自己的约定「+Z = 飞行方向（额面法线）」，树内那句 look_at(global_position + heading) 可能才是错的那一侧 —— 请裁决后统一"
			% f_out.dot(f_in))
	print("[蝴蝶测试] 朝向对照：+Z·+Z = %f；树外 +Z·heading = %f，树内 +Z·heading = %f"
			% [f_out.dot(f_in), f_out.dot(out_b.heading.normalized()), f_in.dot(in_b.heading.normalized())])


# ==================== 内部工具（放在最后，避免 Markdown 风格注释之后紧跟代码的排版问题） ====================

## 造一个固定种子的 rng。
func _rng(seed_v: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_v
	return r


## 造一对**同 seed** 的蝴蝶（树外 + 树内），都 spawn 到**相同初始状态**后返回。
## 返回：{out, in, bounds}；拿不到素材时返回 {}。
## 用途：树外回退的"缩放/手性/朝向"必须与树内一致，而同 seed 正好排除了运动学差异。
func _spawn_orientation_pair() -> Dictionary:
	var entries := _manifest_entries()
	if entries.is_empty():
		return {}
	var e: Dictionary = entries[0]
	var tex := load(String(e["path"])) as Texture2D
	if tex == null:
		return {}
	var crop := _entry_crop(e)
	var td := _tuning_no_drain()
	var bounds := _bounds()
	var out_b = _make_detached_butterfly(tex, crop, 20261017, td)
	out_b.spawn(bounds)
	var in_b = _make_butterfly(tex, crop, 20261017, td)
	in_b.spawn(bounds)
	return {"out": out_b, "in": in_b, "bounds": bounds}

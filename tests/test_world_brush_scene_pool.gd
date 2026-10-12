@tool
extends McpTestSuite
## World Brush「多选 + 随机摆放」（场景池）自检（addons/world_brush/world_brush_scene_pool.gd）。
##
## 背景：原来"每笔随机换变体"是独立插件 addons/variant_tools 干的（监听 node_added 整节点替换），
## 要跟编辑器撤销系统抢时序、bug 多，已删除。现在内建在 World Brush：每个场景行挂一组额外
## .tscn，落点从「主场景 + 这组」里随机挑一个。
##
## ★ 通用性要求：本套件最后一条用例专门盯着"插件里不许出现任何与具体模型/命名相关的规则"
##   （老实现按 small/medium/dead 这类文件名关键字给权重，已删除；权重现在完全是用者的数据）。
##
## 覆盖：
##   · 路径规范化（去空/去重/保序）
##   · 有效池（主场景永远第一；只给主场景 = 不随机）
##   · 权重换算（缺省全 1；表里有就按表；非法值纠正为 1）
##   · 加权挑选（无权重 = 均匀；有权重 = 按比重；同种子可复现；参数不合法时不会失败/偏向第 0 个）
##   · 通用性哨兵 + 插件/面板接线

const POOL_PATH := "res://addons/world_brush/world_brush_scene_pool.gd"
const PLUGIN_PATH := "res://addons/world_brush/world_brush_plugin.gd"
const DOCK_PATH := "res://addons/world_brush/ui/world_brush_dock.gd"

## 通用性哨兵 A：明显属于"某个模型/项目专属"的词，插件里出现即失败。
## 只收不会与通用英文/引擎术语撞车的词 —— 像 medium / single / dead / tree 这类既是旧权重表
## 关键字、又是通用词或引擎标识符（SceneTree、LOD 的 Medium 层…）的，用文本匹配会误伤，
## 所以它们交给哨兵 B（结构性断言）处理。
const MODEL_SPECIFIC_KEYWORDS := [
	"bermuda", "grass", "seedling", "flattened",
]


func suite_name() -> String:
	return "world_brush_scene_pool"


func _pool() -> GDScript:
	return ResourceLoader.load(POOL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


# =========================================================
# ① 路径规范化 / 有效池
# =========================================================

func test_normalize_paths() -> void:
	var pool := _pool()
	assert_ne(pool, null, "%s 无法加载" % POOL_PATH)

	var out: Array = pool.normalize_paths([
		"res://a.tscn",
		"",
		"res://b.tscn",
		"res://a.tscn",       # 重复
		"  res://c.tscn  ",   # 前后空白
	])

	assert_eq(out.size(), 3, "应只剩 3 个不同路径，实际 %d 个" % out.size())
	assert_eq(String(out[0]), "res://a.tscn", "顺序应保持首次出现")
	assert_eq(String(out[1]), "res://b.tscn", "顺序应保持首次出现")
	assert_eq(String(out[2]), "res://c.tscn", "应去掉前后空白")


func test_pool_paths_keeps_primary_first() -> void:
	var pool := _pool()
	var out: Array = pool.pool_paths(
		"res://main.tscn",
		["res://v1.tscn", "res://main.tscn", "res://v1.tscn", "res://v2.tscn"]
	)

	assert_eq(out.size(), 3, "主场景 + 2 个不同变体，实际 %d 个" % out.size())
	assert_eq(String(out[0]), "res://main.tscn", "主场景必须排第一")
	assert_eq(String(out[1]), "res://v1.tscn", "变体顺序应保持")
	assert_eq(String(out[2]), "res://v2.tscn", "变体顺序应保持")

	var single: Array = pool.pool_paths("res://main.tscn", [])
	assert_eq(single.size(), 1, "没有变体时池里只应有主场景（= 不随机）")


# =========================================================
# ② 权重换算（权重是使用者的数据）
# =========================================================

func test_default_weights_are_all_one() -> void:
	var pool := _pool()
	var paths: Array = ["res://a.tscn", "res://b.tscn", "res://c.tscn"]

	var weights: Array = pool.default_weights(paths)
	assert_eq(weights.size(), paths.size(), "权重数组长度必须与池对齐")

	for value in weights:
		assert_eq(int(value), 1, "缺省权重必须全是 1（= 均匀随机）")


func test_weights_for_reads_user_data_and_sanitizes() -> void:
	var pool := _pool()
	var paths: Array = ["res://a.tscn", "res://b.tscn", "res://c.tscn"]
	var user_weights := {
		"res://a.tscn": 5,
		"res://b.tscn": 0,          # 非法（<=0）→ 1
		"res://c.tscn": "not a number",  # 非法类型 → 1
		"res://missing.tscn": 99,   # 不在池里 → 忽略
	}

	var weights: Array = pool.weights_for(paths, user_weights)

	assert_eq(weights.size(), 3, "权重数组长度必须与池对齐")
	assert_eq(int(weights[0]), 5, "表里的值应被采用")
	assert_eq(int(weights[1]), 1, "<=0 应纠正为 1")
	assert_eq(int(weights[2]), 1, "非法类型应纠正为 1")

	# 空表 / 空权重参数都不能出错
	var empty: Array = pool.weights_for(paths, {})
	assert_eq(int(empty[0]), 1, "空权重表 = 全 1")
	assert_eq(int(pool.weight_at({}, "res://whatever.tscn")), 1, "缺省取值为 1")


# =========================================================
# ③ 加权挑选
# =========================================================

func test_pick_without_weights_is_uniform() -> void:
	var pool := _pool()
	var paths: Array = ["res://a.tscn", "res://b.tscn", "res://c.tscn", "res://d.tscn"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 777

	var hits := [0, 0, 0, 0]
	var rounds := 4000
	var invalid := 0

	for _i in range(rounds):
		var index := int(pool.pick_index(rng, paths))   # 不传权重
		if index < 0 or index >= paths.size():
			invalid += 1
			continue
		hits[index] += 1

	# 均匀：每个大致 1000/4000；给足容差
	assert_eq(invalid, 0, "挑选结果必须全部落在池内（越界 %d 次）" % invalid)
	for i in range(hits.size()):
		assert_gt(hits[i], int(rounds * 0.15), "下标 %d 出现太少（%d/%d）" % [i, hits[i], rounds])
		assert_false(hits[i] > int(rounds * 0.35), "下标 %d 出现太多（%d/%d）" % [i, hits[i], rounds])


func test_pick_respects_user_weights() -> void:
	var pool := _pool()
	var paths: Array = ["res://a.tscn", "res://b.tscn"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026

	# 9 : 1
	var hits_a := 0
	var rounds := 3000

	for _i in range(rounds):
		if int(pool.pick_index(rng, paths, [9, 1])) == 0:
			hits_a += 1

	assert_gt(hits_a, int(rounds * 0.8), "权重 9:1 应明显偏向第一个（实际 %d/%d）" % [hits_a, rounds])
	assert_gt(rounds - hits_a, 0, "权重低的也必须有机会出现")


func test_pick_is_reproducible_and_never_fails() -> void:
	var pool := _pool()
	var paths: Array = ["res://a.tscn", "res://b.tscn", "res://c.tscn"]

	var rng_a := RandomNumberGenerator.new()
	rng_a.seed = 20261011
	var rng_b := RandomNumberGenerator.new()
	rng_b.seed = 20261011

	for _i in range(30):
		assert_eq(
			int(pool.pick_index(rng_a, paths, [1, 2, 3])),
			int(pool.pick_index(rng_b, paths, [1, 2, 3])),
			"同种子 + 同权重必须挑出同一个下标"
		)

	# 参数不合法：不能报错、不能永远返回第 0 个
	var rng_c := RandomNumberGenerator.new()
	rng_c.seed = 5
	var seen := {}
	for _i in range(60):
		var index := int(pool.pick_index(rng_c, paths, [7]))   # 长度与池不一致
		assert_true(index >= 0 and index < paths.size(), "非法权重长度时下标仍须合法")
		seen[index] = true
	assert_gt(seen.size(), 1, "非法权重应退化成均匀随机，而不是固定第 0 个")

	assert_eq(int(pool.pick_index(rng_c, [])), -1, "空池应返回 -1")
	assert_eq(int(pool.pick_index(null, paths)), -1, "空 rng 应返回 -1")


# =========================================================
# ④ 通用性哨兵 + 接线
# =========================================================

## ★ 本轮的硬要求：插件里不许有任何"专为某几个模型/某种命名"的规则。
## 哨兵 A（文本）：不收模型/项目专属词；哨兵 B（结构）：权重不能来自文件名、不能有硬编码表。
func test_pool_module_has_no_model_specific_rules() -> void:
	var source := FileAccess.get_file_as_string(POOL_PATH)
	assert_false(source.is_empty(), "读不到 %s" % POOL_PATH)

	var lower := source.to_lower()

	# 哨兵 A：模型/项目专属词
	for keyword in MODEL_SPECIFIC_KEYWORDS:
		assert_false(
			lower.contains(String(keyword).to_lower()),
			"场景池模块里出现了模型/项目专属词 '%s'" % keyword
		)

	# 哨兵 B：权重只能由外部传进来
	assert_false(
		lower.contains("weight_rules"),
		"不应再存在硬编码权重表（旧实现按文件名关键字给权重）"
	)
	assert_false(
		source.contains("func weight_for("),
		"不应再存在'按文件名给权重'的函数"
	)
	assert_false(
		source.contains("get_file("),
		"场景池模块不该看文件名 —— 权重必须只来自使用者数据"
	)
	assert_contains(source, "weights_for(", "应提供'把使用者权重换算成数组'的入口")
	assert_contains(source, "weight_at(", "应提供'按路径取权重'的入口")

	# 插件主体同理（它自己也不该有按名字推断的逻辑）
	var plugin_lower := FileAccess.get_file_as_string(PLUGIN_PATH).to_lower()
	for keyword in MODEL_SPECIFIC_KEYWORDS:
		assert_false(
			plugin_lower.contains(String(keyword).to_lower()),
			"插件主体里出现了模型/项目专属词 '%s'" % keyword
		)
	assert_false(
		plugin_lower.contains("weight_rules"),
		"插件主体里不应有硬编码权重表"
	)


func test_plugin_and_dock_are_wired() -> void:
	var plugin_source := FileAccess.get_file_as_string(PLUGIN_PATH)
	assert_false(plugin_source.is_empty(), "读不到 %s" % PLUGIN_PATH)

	assert_contains(plugin_source, "world_brush_scene_pool.gd", "插件没有预加载场景池模块")
	assert_contains(plugin_source, "SCENE_POOL_SCRIPT.pick_index(", "落点没有用场景池挑选")
	assert_contains(plugin_source, "SCENE_POOL_SCRIPT.weights_for(", "落点没有按使用者权重挑选")
	assert_contains(plugin_source, "scene_variants_changed", "插件没有接收变体池信号")
	assert_contains(plugin_source, "scene_weights_changed", "插件没有接收权重信号")

	var dock_source := FileAccess.get_file_as_string(DOCK_PATH)
	assert_false(dock_source.is_empty(), "读不到 %s" % DOCK_PATH)
	assert_contains(dock_source, "FILE_MODE_OPEN_FILES", "变体入口必须支持多选")
	assert_contains(dock_source, 'CONFIG_RANDOM_VARIANTS := "random_variants"', "变体池必须持久化")
	assert_contains(
		dock_source,
		'CONFIG_RANDOM_VARIANT_WEIGHTS := "random_variant_weights"',
		"权重必须持久化"
	)
	assert_contains(dock_source, "SpinBox.new()", "权重必须能在面板里调整")

	# 已删除的旧变体工具不应再被启用
	var project_cfg := FileAccess.get_file_as_string("res://project.godot")
	assert_false(
		project_cfg.contains("addons/variant_tools/plugin.cfg"),
		"project.godot 仍在启用已删除的 variant_tools 插件"
	)

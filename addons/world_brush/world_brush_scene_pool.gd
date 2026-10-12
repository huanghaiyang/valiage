@tool
extends RefCounted
##
## ============================ 本文件职责 ============================
## 【World Brush · 场景池】"一个笔刷 = 一组 .tscn，落点随机挑一个"的全部纯逻辑：
##   · 路径去重 / 规范化
##   · 有效池 = 主场景 + 额外变体（主场景永远在第一位）
##   · 权重换算（缺省全 1）与加权随机挑选
##
## ============================ 设计约束：不含任何非通用规则 ============================
## 本文件**不得**出现任何与具体模型、文件名、项目内容相关的规则（例如"按文件名里的某个
## 关键字给权重"）。权重是**使用者的数据**：
##   · 不传权重 → 全部为 1 → 池内均匀随机；
##   · 传了权重（{场景路径: 正整数}）→ 按它加权，缺失的按 1 处理，非法值纠正为 1。
## 所以本文件里不读文件名、没有关键字表、没有硬编码权重，插件对任何项目、任何资源命名都成立。
##
## ============================ 为什么单独一个文件 ============================
## 插件主体 world_brush_plugin.gd 继承 EditorPlugin —— 编辑器之外**实例化不了**
## （"Class 'EditorPlugin' can only be instantiated by editor"），逻辑留在插件里就没法被
## tests/test_world_brush_scene_pool.gd 直接覆盖。这里全静态、无状态，headless 可测。


## 去掉空路径与重复项，保持首次出现的顺序。
static func normalize_paths(paths: Array) -> Array[String]:
	var out: Array[String] = []

	for value in paths:
		var path := String(value).strip_edges()

		if path.is_empty() or out.has(path):
			continue

		out.append(path)

	return out


## 有效池 = 主场景 + 额外变体（去重；主场景永远排第一）。
## 只返回 1 个元素时，调用方就该退化成"普通单场景笔刷"（不随机）。
static func pool_paths(
	primary_path: String,
	extras: Array
) -> Array[String]:
	var out: Array[String] = []
	var primary := primary_path.strip_edges()

	if not primary.is_empty():
		out.append(primary)

	for path in normalize_paths(extras):
		if not out.has(path):
			out.append(path)

	return out


## 全部为 1 的权重数组（= 均匀随机）。长度与 paths 对齐。
static func default_weights(paths: Array) -> Array[int]:
	var out: Array[int] = []

	for _path in paths:
		out.append(1)

	return out


## 把 {场景路径: 权重} 换算成与 paths 对齐的权重数组：
##   · 表里没有该路径 → 1
##   · 值不是数字 / <= 0 / 非有限 → 1（非法输入不能把挑选搞崩）
static func weights_for(
	paths: Array,
	weight_map: Dictionary
) -> Array[int]:
	var out: Array[int] = []

	for path in paths:
		out.append(weight_at(weight_map, String(path)))

	return out


## 单个路径的权重（见 weights_for 的规则）。
static func weight_at(
	weight_map: Dictionary,
	path: String
) -> int:
	if weight_map == null or not weight_map.has(path):
		return 1

	var raw: Variant = weight_map[path]

	if not (raw is int or raw is float):
		return 1

	var value := int(raw)

	if value < 1:
		return 1

	return value


## 按权重挑一个下标；paths 为空 / rng 为空返回 -1。
##   · weights 长度与 paths 不一致、或总和 <= 0 → 退化成**均匀随机**（不会失败，也不会偏向第 0 个）；
##   · 均匀随机也只用 rng，方便播种复现。
static func pick_index(
	rng: RandomNumberGenerator,
	paths: Array,
	weights: Array = []
) -> int:
	if rng == null or paths.is_empty():
		return -1

	var usable_weights := weights

	if usable_weights.size() != paths.size() or _total_weight(usable_weights) <= 0:
		usable_weights = default_weights(paths)

	var total := _total_weight(usable_weights)

	if total <= 0:
		return rng.randi_range(0, paths.size() - 1)

	var roll := rng.randi_range(1, total)
	var accumulated := 0

	for index in range(paths.size()):
		accumulated += int(usable_weights[index])

		if roll <= accumulated:
			return index

	return paths.size() - 1


static func _total_weight(weights: Array) -> int:
	var total := 0

	for value in weights:
		if value is int or value is float:
			var as_int := int(value)

			if as_int > 0:
				total += as_int

	return total

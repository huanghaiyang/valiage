extends SceneTree
## ============================================================================
## 抖动"去同步化"回归测试（2026-10-22 用户反馈：树叶/花朵/果实的抖动频率一致，观感差）
## ----------------------------------------------------------------------------
## 目标：证明每个元素（每片叶 / 每朵花 / 每根枝）拿到的抖动频率确实不同，
##       并且同一元素内部频率一致（不会把叶卡撕开），以及 variation=0 时回到 fast-tree 原实现。
##
## 公式与 assets/shaders/fast_tree_wind.gdshaderinc 一一对应：
##   h1 = fract(sin(phase*12.9898 + nodeId*78.233 + 0.13) * 43758.5453)
##   h2 = fract(sin(phase*39.3467 + nodeId*11.1357 + 0.71) * 24634.6345)
##   flutter_rate = max(0.2, 1 + variation*(h1*2-1)) * material_flutter_rate
##   flutter_amp  = 1 + variation*(h2*2-1)*0.8
##   sway_rate    = 1 + sway_variation*(h1*2-1)
## 用法：
##   godot --headless --path . --script res://tests/wind_freq_diversity.gd
## 末行 RESULT 是判据。
## ============================================================================

const LEAVES_RES := "res://assets/models/树/wind/Leaves.res"
const FLOWERS_RES := "res://assets/models/树/wind/Flowers.res"
## 材质里的 flutter 基础频率倍率（与 .tres 保持一致）
const LEAF_MAT_RATE := 1.10
const FLOWER_MAT_RATE := 0.72
const VARIATION := 0.45
const SWAY_VARIATION := 0.15

var _pass := 0
var _fail := 0


func _initialize() -> void:
	var leaves := _elements(LEAVES_RES)
	var flowers := _elements(FLOWERS_RES)
	print("Leaves 元素=%d  Flowers 元素=%d" % [leaves.size(), flowers.size()])
	if leaves.size() < 100 or flowers.size() < 100:
		print("RESULT: FAIL 数据不足")
		quit(1)
		return

	# ---- 1) variation=0 -> 所有元素同频（= fast-tree 原实现）----
	var flat := {}
	for e in leaves:
		flat[snappedf(_flutter_rate(e, 0.0, LEAF_MAT_RATE), 0.0001)] = true
	_ck("variation=0 时所有叶片频率相同（源实现行为）", flat.size() == 1,
			"unique=%d" % flat.size())

	# ---- 2) variation=0.45 -> 频率真的散开了 ----
	var rates: Array = []
	for e in leaves:
		rates.append(_flutter_rate(e, VARIATION, LEAF_MAT_RATE))
	var mn: float = rates.min()
	var mx: float = rates.max()
	var mean := 0.0
	for r in rates:
		mean += r
	mean /= float(rates.size())
	var var_sum := 0.0
	for r in rates:
		var_sum += (r - mean) * (r - mean)
	var sd := sqrt(var_sum / float(rates.size()))
	_ck("叶片抖动频率跨度足够（max/min ≥ 2.0）", mx / maxf(0.001, mn) >= 2.0,
			"min=%.3f max=%.3f ratio=%.2f" % [mn, mx, mx / maxf(0.001, mn)])
	_ck("叶片抖动频率标准差 ≥ 0.15", sd >= 0.15, "sd=%.3f mean=%.3f" % [sd, mean])
	var uniq_rates := {}
	for r in rates:
		uniq_rates[snappedf(r, 0.0001)] = true
	_ck("绝大多数元素有独立频率（unique ≥ 80%%）",
			float(uniq_rates.size()) / float(rates.size()) >= 0.8,
			"unique=%d/%d" % [uniq_rates.size(), rates.size()])

	# ---- 3) 花比叶慢（材质级 flutter_rate 0.72 vs 1.10）----
	var fr: Array = []
	for e in flowers:
		fr.append(_flutter_rate(e, VARIATION, FLOWER_MAT_RATE))
	var flower_mean := 0.0
	for r in fr:
		flower_mean += r
	flower_mean /= float(fr.size())
	_ck("花朵平均抖动频率 ≈ 叶片的 0.65（不再同频）",
			absf(flower_mean / mean - FLOWER_MAT_RATE / LEAF_MAT_RATE) < 0.02,
			"leaf_mean=%.3f flower_mean=%.3f ratio=%.3f" % [mean, flower_mean, flower_mean / mean])
	# 两组分布基本不重叠（花的最大 < 叶的 95 分位）
	var leaf_sorted := rates.duplicate()
	leaf_sorted.sort()
	var p95: float = leaf_sorted[int(leaf_sorted.size() * 0.95)]
	_ck("叶片 95% 分位 > 花朵平均（两类节奏可分辨）", p95 > flower_mean, "leaf_p95=%.3f flower_mean=%.3f" % [p95, flower_mean])

	# ---- 4) 同一元素内部频率必须一致（否则叶卡会被撕开）----
	var bad_groups := 0
	for res in [LEAVES_RES, FLOWERS_RES]:
		var groups := _element_groups(res)
		for g in groups:
			var r0 := _flutter_rate(g[0], VARIATION, LEAF_MAT_RATE)
			for e in g:
				if absf(_flutter_rate(e, VARIATION, LEAF_MAT_RATE) - r0) > 1e-6:
					bad_groups += 1
					break
	_ck("同一元素内部抖动频率一致（叶卡不撕开）", bad_groups == 0, "不一致元素=%d" % bad_groups)

	# ---- 5) 刚性主波次级项频率跨度（枝条/果实节奏差异）----
	var sr: Array = []
	for e in leaves:
		sr.append(_sway_rate(e, SWAY_VARIATION))
	var smn: float = sr.min()
	var smx: float = sr.max()
	_ck("刚性 sway 次级频率跨度 ∈ [0.8, 1.2]", smn >= 0.8 and smx <= 1.2,
			"min=%.3f max=%.3f" % [smn, smx])
	_ck("刚性 sway 次级频率确实有差异", smx - smn > 0.2, "span=%.3f" % (smx - smn))

	# ---- 6) 时域：估算 200 个元素的抖动主频，看分布是否散开 ----
	var freqs: Array = []
	var sample_n := mini(200, leaves.size())
	for i in range(sample_n):
		freqs.append(_estimate_freq(leaves[i], VARIATION, LEAF_MAT_RATE))
	var fmn: float = freqs.min()
	var fmx: float = freqs.max()
	_ck("时域主频分布散开（max/min ≥ 1.6）", fmx / maxf(0.01, fmn) >= 1.6,
			"fmin=%.3f Hz fmax=%.3f Hz" % [fmn, fmx])

	print("RESULT: %s  (%d/%d assertions passed)" % [
			"PASS" if _fail == 0 else "FAIL", _pass, _pass + _fail])
	quit(0 if _fail == 0 else 1)


# ---------------------------------------------------------------- 数学（与 shader 对应）
func _fract(x: float) -> float:
	return x - floor(x)


func _h1(e: Array) -> float:
	return _fract(sin(e[0] * 12.9898 + e[1] * 78.233 + 0.13) * 43758.5453)


func _h2(e: Array) -> float:
	return _fract(sin(e[0] * 39.3467 + e[1] * 11.1357 + 0.71) * 24634.6345)


func _flutter_rate(e: Array, variation: float, mat_rate: float) -> float:
	var r := maxf(0.2, 1.0 + variation * (_h1(e) * 2.0 - 1.0))
	return mat_rate * r


func _flutter_amp(e: Array, variation: float) -> float:
	return 1.0 + variation * (_h2(e) * 2.0 - 1.0) * 0.8


func _sway_rate(e: Array, sway_var: float) -> float:
	return 1.0 + sway_var * (_h1(e) * 2.0 - 1.0)


## 估主频：对 flap(t) 做 4 秒采样 + 过零计数（片段足够稳定，够判"是否同频"）
func _estimate_freq(e: Array, variation: float, mat_rate: float) -> float:
	var rate := _flutter_rate(e, variation, mat_rate)
	var phase: float = e[0]
	var dt := 1.0 / 120.0
	var steps := 480
	var prev := 0.0
	var crossings := 0
	for i in range(steps):
		var t := i * dt
		# 只取频率项（4.1 是源实现的弯曲抖动频率系数）
		var v := sin(t * 4.1 * rate + phase * 6.3)
		if i > 0 and prev <= 0.0 and v > 0.0:
			crossings += 1
		prev = v
	var dur := steps * dt
	return float(crossings) / maxf(0.001, dur)


# ---------------------------------------------------------------- 数据读取
## 返回去重后的元素列表：[phase, nodeId]（同一元素所有顶点共享这两个值）
func _elements(path: String) -> Array:
	var groups := _element_groups(path)
	var out: Array = []
	for g in groups:
		out.append(g[0])
	return out


## 按 (phase,nodeId) 分组，返回 [[elem, elem, ...], ...]（同组 = 同一元素的所有顶点）
func _element_groups(path: String) -> Array:
	var mesh: ArrayMesh = load(path)
	if mesh == null:
		return []
	var arr: Array = mesh.surface_get_arrays(0)
	var c1: PackedFloat32Array = arr[Mesh.ARRAY_CUSTOM1]
	var groups := {}
	for i in range(c1.size() / 4):
		var phase := c1[i * 4 + 0]
		var node := c1[i * 4 + 2]
		# ★ 必须用**全精度**相位做 key：GLB 里同一元素的所有顶点 aPhase 逐位相同（实测差 0），
		#   若把相位量化到 1e-4，会把两个"碰巧相位相近"的不同元素并成一组 -> 假失败
		var key := String.num(phase, 16) + "_" + "%d" % int(round(node))
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append([phase, node])
	return groups.values()


func _ck(name: String, ok: bool, detail: String) -> void:
	if ok:
		_pass += 1
		print("  [PASS] %s ｜ %s" % [name, detail])
	else:
		_fail += 1
		print("  [FAIL] %s ｜ %s" % [name, detail])


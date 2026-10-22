extends SceneTree
## 验证「树枝 ↔ 树叶/花朵 同步」。
##
## 设计：叶片的**刚性摆动**改用宿主枝条的 (phase, aWind, nodeId)（烘焙进 CUSTOM2），
## 局部抖动仍用叶子自己的相位。本测试不纠结"宿主到底是哪一根枝"（叶生点离树皮
## 0.1~0.2m、邻近多根枝，必然有并列），而是验证：
##   A. 每个顶点都带宿主
##   B. 宿主相位 == 0.35m 内某根树皮枝的相位（确实绑在邻近枝条上）
##   C. 宿主柔度与该枝柔度接近
##   D. 叶子自身相位仍不同（局部抖动多样性保留）
##   E. 宿主相位有分组（不是全用同一个）
##   F. 相位一致的那些配对：叶片与枝条的刚性位移逐时刻几乎相等（这就是"同步"）
##
## 跑法：godot --headless --path . --script res://tests/wind_leaf_branch_sync.gd

const BARK := ["res://assets/models/树/wind/Bark_Trunk.res",
		"res://assets/models/树/wind/Bark_Branch_L1.res",
		"res://assets/models/树/wind/Bark_Branch_L2.res",
		"res://assets/models/树/wind/Bark_Branch_L3.res",
		"res://assets/models/树/wind/Bark_Branch_L4.res",
		"res://assets/models/树/wind/Bark_Branch_L5.res"]
const LEAF_FILES := ["res://assets/models/树/wind/Leaves.res",
		"res://assets/models/树/wind/Flowers.res"]
const CELL := 0.5
const NEAR := 0.35
const N_SAMPLE := 600
const FALL := 1.5
const FORCE := 0.084
const SWAY := 0.8
const TS := [1.0, 2.3, 5.7, 11.0]

var _fails := 0
var _checks := 0


func _initialize() -> void:
	var bark := _collect_bark()
	print("树皮顶点 %d 个，唯一相位 %d 个" % [bark["count"], bark["phases"].size()])
	for path in LEAF_FILES:
		_check_file(path, bark["cells"])
	print("RESULT: %s (%d/%d)" % ["PASS" if _fails == 0 else "FAIL", _checks - _fails, _checks])
	quit(0 if _fails == 0 else 1)


func _ok(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  ✓ " + msg)
	else:
		_fails += 1
		print("  ✗ " + msg)


func _collect_bark() -> Dictionary:
	var cells := {}
	var phases := {}
	var count := 0
	for p in BARK:
		var am: ArrayMesh = load(p)
		var a: Array = am.surface_get_arrays(0)
		var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var c0: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM0]
		var c1: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM1]
		for i in verts.size():
			var key := _key(verts[i])
			if not cells.has(key):
				cells[key] = []
			(cells[key] as Array).append([verts[i], c1[i * 4 + 0], c0[i * 4 + 3], c1[i * 4 + 2]])
			phases[String.num(c1[i * 4 + 0], 6)] = true
			count += 1
	return {"cells": cells, "phases": phases, "count": count}


static func _key(p: Vector3) -> String:
	return "%d_%d_%d" % [int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL))]


func _near(cells: Dictionary, p: Vector3) -> Array:
	var out: Array = []
	var cx := int(floor(p.x / CELL))
	var cy := int(floor(p.y / CELL))
	var cz := int(floor(p.z / CELL))
	for dx in [-2, -1, 0, 1, 2]:
		for dy in [-2, -1, 0, 1, 2]:
			for dz in [-2, -1, 0, 1, 2]:
				var k := "%d_%d_%d" % [cx + dx, cy + dy, cz + dz]
				if not cells.has(k):
					continue
				for rec in cells[k]:
					if p.distance_to(rec[0]) <= NEAR:
						out.append(rec)
	return out


func _check_file(path: String, cells: Dictionary) -> void:
	print("--- %s" % path.get_file())
	var am: ArrayMesh = load(path)
	var a: Array = am.surface_get_arrays(0)
	var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var c0: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM0]
	var c1: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM1]
	var c2: PackedFloat32Array = a[Mesh.ARRAY_CUSTOM2]
	if c2 == null or c2.size() != verts.size() * 4:
		_ok(false, "CUSTOM2 缺失")
		return
	var tagged := 0
	for i in verts.size():
		if c2[i * 4 + 3] > 0.5:
			tagged += 1
	_ok(tagged == verts.size(), "A. 全部顶点带宿主标记（%d/%d）" % [tagged, verts.size()])

	var step := maxi(1, verts.size() / N_SAMPLE)
	var tested := 0
	var no_branch := 0
	var on_branch := 0
	var near_wind_sum := 0.0
	var max_near_wind := 0.0
	var own_diff := 0
	var groups := {}
	var matched := 0
	var max_sync := 0.0
	for i in range(0, verts.size(), step):
		tested += 1
		var o := Vector3(c0[i * 4 + 0], c0[i * 4 + 1], c0[i * 4 + 2])
		var hp: float = c2[i * 4 + 0]
		var hw: float = c2[i * 4 + 1]
		var hn: float = c2[i * 4 + 2]
		groups[String.num(hp, 6)] = true
		if absf(c1[i * 4 + 0] - hp) > 1e-5:
			own_diff += 1
		var cands := _near(cells, o)
		if cands.is_empty():
			no_branch += 1
			continue
		var same_phase: Array = []
		for rec in cands:
			if absf(float(rec[1]) - hp) < 1e-4:
				same_phase.append(rec)
		if same_phase.is_empty():
			continue
		on_branch += 1
		var best: Array = same_phase[0]
		var best_d := INF
		for rec in same_phase:
			var d: float = o.distance_to(rec[0])
			if d < best_d:
				best_d = d
				best = rec
		var dw := absf(hw - float(best[2]))
		near_wind_sum += dw
		max_near_wind = maxf(max_near_wind, dw)
		var bd := _rigid(float(best[1]), float(best[2]), float(best[3]), TS)
		var ld := _rigid(hp, hw, hn, TS)
		var dmax := 0.0
		for k in TS.size():
			dmax = maxf(dmax, (bd[k] - ld[k]).length())
		matched += 1
		max_sync = maxf(max_sync, dmax)
	# 分母排除"0.35m 内根本没有树皮几何"的样本（细枝/树冠内部，没有可见枝条可同步）
	var ok_b := float(on_branch) / float(maxi(1, tested - no_branch))
	var fallback := float(no_branch) / float(maxi(1, tested))
	var ok_d := float(own_diff) / float(maxi(1, tested))
	_ok(ok_b >= 0.92, "B. 附近有枝的样本里，宿主相位 = 该枝相位：%.1f%%（无枝可同步的回退占比 %.1f%%）" % [ok_b * 100.0, fallback * 100.0])
	_ok(near_wind_sum / maxf(1.0, matched) <= 0.04, "C. 宿主柔度与该枝柔度接近：平均差=%.3f 最大=%.3f" % [near_wind_sum / maxf(1.0, matched), max_near_wind])
	_ok(ok_d >= 0.8, "D. 叶子自身相位仍不同（局部抖动多样性保留）：%.1f%%" % [ok_d * 100.0])
	_ok(groups.size() >= 20, "E. 宿主相位分组数=%d" % groups.size())
	_ok(max_sync < 0.06, "F. 同相位配对：刚性位移最大差=%.4f m（%d 对）" % [max_sync, matched])


func _rigid(phase: float, wind_val: float, node: float, ts: Array) -> Array:
	var h1r := fposmod(sin(phase * 12.9898 + node * 78.233 + 0.13) * 43758.5453, 1.0)
	var sway_rate := 1.0 + 0.15 * (h1r * 2.0 - 1.0)
	var flex := pow(clampf(wind_val, 0.0, 1.0), FALL)
	var out: Array = []
	for t in ts:
		var tw: float = float(t)
		var wave := sin(tw + phase) * 0.72 + sin(tw * 2.17 * sway_rate + phase * 1.7) * 0.28
		var osc := wave * 0.5 + 0.5
		var g := 1.0 - 0.35 * 0.6 * (1.0 - (sin(tw * 0.16 + phase * 0.21) * 0.5 + 0.5))
		var along := osc * g + 0.3 * 0.35
		var tb := sin(tw * 3.1 + phase * 4.3)
		out.append(Vector2(along, tb * 0.3) * (FORCE * SWAY * flex))
	return out





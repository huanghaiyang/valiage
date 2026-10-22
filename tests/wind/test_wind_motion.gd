extends SceneTree
## ============================================================================
## fast-tree 风摆 · 轨迹自检（headless 可跑）
## ============================================================================
## 用**移植后的参照 GLSL 公式**（wind_model_ref.gd::sample_leaf_at）+ 真实烘焙属性
## 采样叶尖轨迹，跑 windModel.js 的轨迹指标，断言：
##   1) azimuthDeg 与 wind_direction 一致（≤ 3°，azimuth 按 180° 模比较）
##   2) thinness ≤ 0.45（横向/顺风 RMS 比：不能像在绕圈）
##   3) spanAlong 随 wind_force 单调增（0.05 / 0.15 / 0.3）
##   4) 关掉铰链俯仰（leaf_twist=0）后轨迹指标明显改变 → 俯仰确实起作用
##   5) flex 单调性：同一叶片 aWind 越大位移越大（取平均）
##
## 数据来源：
##   · 优先 res://assets/models/树/wind/Leaves.res（Lead 的烘焙产物，CUSTOM0/1）
##   · 未就绪时用**合成属性**（固定种子；几何量级照抄 fast-tree：叶柄距 0.08..0.35 m）
##   两种模式跑的是同一套断言，日志里会明确写 MODE。
##
## 用法：
##   & 'D:\godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path . \
##       --quit-after 600 --script res://tests/wind/test_wind_motion.gd
## 产物：.runtime/wind_port/motion_results.json
## ============================================================================
const R := preload("res://tests/wind/wind_model_ref.gd")

const BAKED_LEAVES := "res://assets/models/树/wind/Leaves.res"
const TIPS := 120
const STEPS := 2400
const DT := 1.0 / 60.0
const SEED := 20261022

## 固定风场（量级取自 materials.js createSharedUniforms + docs/wind-port-spec.md §2.2）
const WIND := {
	"direction": 45.0,
	"speed": 0.8,
	"frequency": 1.0,
	"gust": 0.35,
	"gust_speed": 0.16,
	"turbulence": 0.12,
	"bias": 0.3,
	"force": 0.15,
	"spatial_scale": 0.22,
	"flex_falloff": 1.5,
	"seed": 0.0,
	"sway": 1.0,
	"enabled": true,
	"leaf_flutter": 0.6,
	"leaf_twist": 0.5,
}

var _rows: Array = []      ## [{name, expect, actual, pass}]
var _details: Array = []   ## 逐项细节（写报告用）
var _mode := "synthetic"
var _tips: Array = []      ## [{pos: Vector3, c0: Vector4, c1: Vector4}]


func _initialize() -> void:
	print("=".repeat(78))
	print("fast-tree 风摆 · 轨迹自检 test_wind_motion")
	print("=".repeat(78))
	_load_tips()
	var cw := R.compile_wind(WIND)

	# ---------------------------------------------------------------- 1 + 2
	var az: Array = []
	var thin: Array = []
	var horiz: Array = []
	var span_along: Array = []
	for tip in _tips:
		var pts := R.sample_track(cw, tip["c0"], tip["c1"], tip["pos"], STEPS, DT)
		var m := R.metrics_from_points(pts, cw["windDir"], cw["windPerp"])
		az.append(_axis_diff(float(m["azimuthDeg"]), float(WIND["direction"])))
		thin.append(float(m["thinness"]))
		horiz.append(float(m["horizontalShare"]))
		span_along.append(float(m["spanAlong"]))
	var az_max := _maxf(az)
	var az_mean := _meanf(az)
	var thin_max := _maxf(thin)
	var thin_mean := _meanf(thin)
	_add_row("azimuth_consistency", "max |az - wind.dir| <= 3.0 deg",
			"max=%.2f deg  mean=%.2f  (n=%d, dir=%.0f)" % [az_max, az_mean, az.size(), WIND["direction"]],
			az_max <= 3.0)
	_add_row("thinness", "max thinness <= 0.45",
			"max=%.3f  mean=%.3f  (n=%d)" % [thin_max, thin_mean, thin.size()],
			thin_max <= 0.45)
	_add_row("horizontal_share", "mean >= 0.70 (方向看得见)",
			"mean=%.3f  min=%.3f" % [_meanf(horiz), _minf(horiz)], _meanf(horiz) >= 0.70)
	_details.append({"test": "base", "az_max_deg": az_max, "az_mean_deg": az_mean,
			"thin_mean": thin_mean, "thin_max": thin_max,
			"span_along_mean": _meanf(span_along), "n": az.size()})

	# ---------------------------------------------------------------- 1b
	# 多方向 azimu	th：证明"主轴 == wind_direction"不是 45° 的巧合（azimuth 按 180° 模）
	var sweep_dirs := [0.0, 30.0, 90.0, 135.0, 200.0, 315.0]
	var sweep_tips := mini(40, _tips.size())
	var azs: Array = []
	var sweep_rows: Array = []
	for dd in sweep_dirs:
		var wd_wind := WIND.duplicate()
		wd_wind["direction"] = dd
		var cwd := R.compile_wind(wd_wind)
		var errs: Array = []
		for i in sweep_tips:
			var tip: Dictionary = _tips[i]
			var pts := R.sample_track(cwd, tip["c0"], tip["c1"], tip["pos"], STEPS, DT)
			var m := R.metrics_from_points(pts, cwd["windDir"], cwd["windPerp"])
			errs.append(_axis_diff(float(m["azimuthDeg"]), dd))
		sweep_rows.append({"dir": dd, "max_err": _maxf(errs), "mean_err": _meanf(errs)})
		azs.append(_maxf(errs))
	var sweep_max := _maxf(azs)
	_add_row("azimuth_sweep", "6 个风向 max |az - dir| <= 3.0 deg",
			"max=%.2f deg  逐方向: %s" % [sweep_max,
					", ".join(sweep_rows.map(func(r): return "%.0f°:%.2f" % [r["dir"], r["max_err"]]))],
			sweep_max <= 3.0)
	_details.append({"test": "azimuth_sweep", "rows": sweep_rows, "tips": sweep_tips})

	# ---------------------------------------------------------------- 3
	var forces := [0.05, 0.15, 0.3]
	var spans: Array = []
	for f in forces:
		var w := WIND.duplicate()
		w["force"] = f
		var cwf := R.compile_wind(w)
		var s: Array = []
		for tip in _tips:
			var pts := R.sample_track(cwf, tip["c0"], tip["c1"], tip["pos"], STEPS, DT)
			var m := R.metrics_from_points(pts, cwf["windDir"], cwf["windPerp"])
			s.append(float(m["spanAlong"]))
		spans.append(_meanf(s))
	var s0 := float(spans[0])
	var s1 := float(spans[1])
	var s2 := float(spans[2])
	var mono: bool = s0 < s1 and s1 < s2
	var margin_ok: bool = s1 > s0 * 1.02 and s2 > s1 * 1.02
	_add_row("force_monotonic", "spanAlong strictly increases with wind_force",
			"f=0.05:%.4f  f=0.15:%.4f  f=0.30:%.4f m" % [spans[0], spans[1], spans[2]],
			mono and margin_ok)
	_details.append({"test": "force_sweep", "forces": forces, "span_along": spans})

	# ---------------------------------------------------------------- 4
	var w_off := WIND.duplicate()
	w_off["leaf_twist"] = 0.0
	var cw_off := R.compile_wind(w_off)
	var on: Array = []
	var off: Array = []
	for tip in _tips:
		var pts_on := R.sample_track(cw, tip["c0"], tip["c1"], tip["pos"], STEPS, DT)
		var pts_off := R.sample_track(cw_off, tip["c0"], tip["c1"], tip["pos"], STEPS, DT)
		on.append(R.metrics_from_points(pts_on, cw["windDir"], cw["windPerp"]))
		off.append(R.metrics_from_points(pts_off, cw_off["windDir"], cw_off["windPerp"]))
	var keys := ["rmsVert", "spanPerp", "rmsPerp", "spanAlong"]
	var chg := {}
	for k in keys:
		var a := _meanf(_pluck(on, k))
		var b := _meanf(_pluck(off, k))
		chg[k] = {"with_pitch": a, "no_pitch": b,
				"rel_change": absf(a - b) / maxf(1e-9, absf(b))}
	# 俯仰主要通过"竖直方向的翻转"起作用：rmsVert 必须明显变大
	var pitch_ok: bool = chg["rmsVert"]["rel_change"] >= 0.10
	var other_ok := false
	for k in ["spanPerp", "rmsPerp", "spanAlong"]:
		if chg[k]["rel_change"] >= 0.02:
			other_ok = true
	_add_row("pitch_active", "leaf_twist=0 changes rmsVert by >=10%",
			"rmsVert %.4f -> %.4f (d=%.1f%%)  spanPerp d=%.1f%%  rmsPerp d=%.1f%%  spanAlong d=%.1f%%" % [
				chg["rmsVert"]["with_pitch"], chg["rmsVert"]["no_pitch"],
				chg["rmsVert"]["rel_change"] * 100.0,
				chg["spanPerp"]["rel_change"] * 100.0,
				chg["rmsPerp"]["rel_change"] * 100.0,
				chg["spanAlong"]["rel_change"] * 100.0],
			pitch_ok and other_ok)
	_details.append({"test": "pitch_off", "metrics": chg})

	# ---------------------------------------------------------------- 5
	var awinds := [0.1, 0.3, 0.5, 0.7, 0.9, 1.0]
	var disp: Array = []
	for aw in awinds:
		var d: Array = []
		for tip in _tips:
			var c0: Vector4 = tip["c0"]
			c0.w = aw
			var pts := R.sample_track(cw, c0, tip["c1"], tip["pos"], STEPS, DT)
			# 位移幅度 = 轨迹相对自身均值的 RMS 位移。
			# （不能直接用 |tip-origin|：它被固定的叶柄长度稀释，aWind=0.1→1.0 只有 ~1.14 倍，
			#   测不出 flex 的作用；去掉常数项后才反映"摆动幅度"本身。）
			var mean := Vector3.ZERO
			for p in pts:
				mean += p
			mean /= float(pts.size())
			var acc := 0.0
			for p in pts:
				acc += (p as Vector3).distance_squared_to(mean)
			d.append(sqrt(acc / float(pts.size())))
		disp.append(_meanf(d))
	var flex_mono := true
	for i in range(1, disp.size()):
		if disp[i] <= disp[i - 1]:
			flex_mono = false
	var ratio: float = disp[disp.size() - 1] / maxf(1e-9, disp[0])
	_add_row("flex_monotonic", "mean RMS displacement strictly increases with aWind; ratio>1.2",
			"disp@aWind=%s  ratio(1.0/0.1)=%.2f" % [str(_fmt_arr(disp)), ratio],
			flex_mono and ratio > 1.2)
	_details.append({"test": "flex_sweep", "aWind": awinds, "disp": disp, "ratio": ratio})

	# ---------------------------------------------------------------- 输出
	print("")
	print("MODE=%s  tips=%d  steps=%d  dt=%.4f  (leaf source: %s)" % [
			_mode, _tips.size(), STEPS, DT,
			BAKED_LEAVES if _mode == "baked" else "合成属性（烘焙产物未就绪）"])
	_dump_table()
	_write_json()
	var failed := 0
	for r in _rows:
		if not r["pass"]:
			failed += 1
	print("")
	print("RESULT: %s  (%d/%d assertions passed)" % [
			"PASS" if failed == 0 else "FAIL", _rows.size() - failed, _rows.size()])
	quit(0 if failed == 0 else 1)


# ============================================================================
# 数据来源
# ============================================================================

func _load_tips() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	if FileAccess.file_exists(BAKED_LEAVES):
		var mesh: Mesh = load(BAKED_LEAVES)
		if mesh is ArrayMesh:
			_tips = _tips_from_mesh(mesh as ArrayMesh, rng)
			if _tips.size() >= TIPS:
				_mode = "baked"
				return
			push_warning("[motion] %s 只抽到 %d 个叶尖（< %d），回退合成属性" % [
					BAKED_LEAVES, _tips.size(), TIPS])
	_mode = "synthetic"
	_tips.clear()
	for i in TIPS:
		var origin := Vector3(rng.randf_range(-2.0, 2.0), rng.randf_range(0.3, 4.0), rng.randf_range(-2.0, 2.0))
		var dir := Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.4, 0.6), rng.randf_range(-1.0, 1.0))
		if dir.length() < 1e-4:
			dir = Vector3.RIGHT
		var stem := rng.randf_range(0.08, 0.35)
		var tip := origin + dir.normalized() * stem
		var c0 := Vector4(origin.x, origin.y, origin.z, rng.randf_range(0.05, 1.0))
		var c1 := Vector4(rng.randf_range(0.0, TAU), 1.0, float(i), 1.0)
		_tips.append({"pos": tip, "c0": c0, "c1": c1})


func _tips_from_mesh(mesh: ArrayMesh, rng: RandomNumberGenerator) -> Array:
	var all: Array = []
	for s in mesh.get_surface_count():
		var arr: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var c0s = arr[Mesh.ARRAY_CUSTOM0]
		var c1s = arr[Mesh.ARRAY_CUSTOM1]
		if c0s == null or c1s == null:
			push_warning("[motion] surface %d 没有 CUSTOM0/CUSTOM1" % s)
			continue
		var nc0: PackedFloat32Array = c0s
		var nc1: PackedFloat32Array = c1s
		if nc0.size() < verts.size() * 4 or nc1.size() < verts.size() * 4:
			push_warning("[motion] surface %d CUSTOM 长度不对 (%d/%d vs %d)" % [
					s, nc0.size(), nc1.size(), verts.size() * 4])
			continue
		for i in verts.size():
			var c1 := Vector4(nc1[i * 4], nc1[i * 4 + 1], nc1[i * 4 + 2], nc1[i * 4 + 3])
			if c1.w <= 0.5 or c1.y <= 0.5:
				continue  # 未烘焙 / 非叶片
			var c0 := Vector4(nc0[i * 4], nc0[i * 4 + 1], nc0[i * 4 + 2], nc0[i * 4 + 3])
			all.append({"pos": verts[i], "c0": c0, "c1": c1})
	if all.size() <= TIPS:
		return all
	# Fisher-Yates 洗牌后取前 TIPS 个（确定性）
	for i in range(all.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = all[i]
		all[i] = all[j]
		all[j] = tmp
	return all.slice(0, TIPS)


# ============================================================================
# 小工具
# ============================================================================

## 主轴夹角（180° 模：0° 与 180° 是同一条水平主轴）
func _axis_diff(a: float, b: float) -> float:
	var d := absf(fmod(a - b, 180.0))
	return minf(d, 180.0 - d)


func _pluck(arr: Array, key: String) -> Array:
	var out: Array = []
	for m in arr:
		out.append(float((m as Dictionary)[key]))
	return out


func _add_row(name: String, expect: String, actual: String, ok: bool) -> void:
	_rows.append({"name": name, "expect": expect, "actual": actual, "pass": ok})
	print("[%s] %-20s %s" % ["PASS" if ok else "FAIL", name, actual])
	if not ok:
		print("       expect: %s" % expect)


func _dump_table() -> void:
	print("")
	print("%-20s %-46s %-58s %s" % ["ASSERTION", "EXPECTED", "ACTUAL", "RESULT"])
	print("-".repeat(150))
	for r in _rows:
		print("%-20s %-46s %-58s %s" % [r["name"], r["expect"], r["actual"],
				"PASS" if r["pass"] else "FAIL"])
	print("-".repeat(150))


func _write_json() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.runtime/wind_port/"))
	var data := {
		"mode": _mode,
		"tips": _tips.size(),
		"steps": STEPS,
		"dt": DT,
		"wind": WIND,
		"rows": _rows,
		"details": _details,
	}
	var f := FileAccess.open("res://.runtime/wind_port/motion_results.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()
		print("[motion] wrote res://.runtime/wind_port/motion_results.json")


func _fmt_arr(a: Array) -> String:
	var parts: PackedStringArray = []
	for v in a:
		parts.append("%.4f" % float(v))
	return ",".join(parts)


func _meanf(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / float(a.size())


func _maxf(a: Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, float(v))
	return m


func _minf(a: Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, float(v))
	return m

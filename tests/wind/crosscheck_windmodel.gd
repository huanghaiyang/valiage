extends SceneTree
## ============================================================================
## fast-tree 风摆 · JS ↔ GDScript 逐行等价交叉验证（GDScript 侧）
## ============================================================================
## 输入与 tests/wind/crosscheck_windmodel.mjs **完全一致**（同样的表、同样的下标算式），
## 输出 .runtime/wind_port/gd_ref.json；由 tests/wind/compare_ref.py 逐值比较。
##
## 用法：
##   godot --headless --path . --quit-after 600 \
##       --script res://tests/wind/crosscheck_windmodel.gd
## ============================================================================
const R := preload("res://tests/wind/wind_model_ref.gd")

const D3 := [0.05, 0.12, 0.3]
const SPEEDS := [0.45, 0.8, 3.6]
const FREQS := [0.05, 1.0, 3.0]
const GUSTS := [0.0, 0.35, 1.0]
const GUST_SPEEDS := [0.06, 0.16, 0.4]
const TURBS := [0.0, 0.12, 1.0]
const BIASES := [0.0, 0.3, 0.9]
const FLUTTERS := [0.25, 0.6, 1.2]
const TWISTS := [0.15, 0.5, 1.1]
const AWINDS := [0.0, 0.5, 1.0]
const STEMS := [0.05, 0.35, 0.9]
const PHASES := [0.0, 1.234, 5.5]


func _initialize() -> void:
	var cases: Array = []
	var env_cases: Array = []
	for i in 60:
		var wind := {
			"direction": float((i * 37) % 360),
			"strength": D3[i % 3],
			"speed": SPEEDS[(i * 2) % 3],
			"frequency": FREQS[(i * 5) % 3],
			"gust": GUSTS[i % 3],
			"gustSpeed": GUST_SPEEDS[(i * 7) % 3],
			"turbulence": TURBS[(i * 11) % 3],
			"bias": BIASES[(i * 13) % 3],
			"leafFlutter": FLUTTERS[(i * 17) % 3],
			"leafTwist": TWISTS[(i * 19) % 3],
		}
		var opts := {
			"aWind": AWINDS[(i * 3) % 3],
			"stemDist": STEMS[(i * 23) % 3],
			"phase": PHASES[(i * 29) % 3],
			"dt": 1.0 / 60.0,
			"steps": 600,
		}
		cases.append({"wind": wind, "opts": opts, "metrics": R.motion_metrics(wind, "current", opts)})
	for i in 12:
		var wind := {
			"direction": float((i * 53) % 360),
			"strength": [0.05, 0.15, 0.3][i % 3],
			"speed": SPEEDS[(i * 2) % 3],
			"frequency": FREQS[(i * 5) % 3],
			"gust": GUSTS[(i * 7) % 3],
			"gustSpeed": GUST_SPEEDS[(i * 11) % 3],
			"turbulence": TURBS[(i * 13) % 3],
			"bias": BIASES[(i * 17) % 3],
		}
		var opts := {
			"dt": 1.0 / 60.0,
			"steps": 2400,
			"phase": [0.7, 2.5, 0.0][i % 3],
			"flex": [1.0, 0.4, 0.0][(i * 19) % 3],
		}
		env_cases.append({"wind": wind, "opts": opts, "env": R.sway_envelope(wind, opts)})

	# 原始点集（未取整）
	var c0: Dictionary = cases[0]
	var traj := R.leaf_trajectory(c0["wind"], "current", c0["opts"])
	# 原始点集（未取整）：JSON 只能装原生数组，这里把 Vector2/3 摊成 [x,y]/[x,y,z]
	var raw_pts: Array = []
	for p in traj["pts"]:
		var v: Vector3 = p
		raw_pts.append([v.x, v.y, v.z])
	var wd: Vector2 = traj["windDir"]
	var wp: Vector2 = traj["windPerp"]
	var out := {
		"cases": cases,
		"env_cases": env_cases,
		"raw": {
			"wind": c0["wind"],
			"opts": c0["opts"],
			"windDir": [wd.x, wd.y],
			"windPerp": [wp.x, wp.y],
			"pts": raw_pts,
		},
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.runtime/wind_port/"))
	var f := FileAccess.open("res://.runtime/wind_port/gd_ref.json", FileAccess.WRITE)
	if f == null:
		push_error("[gd] 无法写入 gd_ref.json err=%d" % FileAccess.get_open_error())
		quit(1)
		return
	f.store_string(JSON.stringify(out))
	f.close()
	print("[gd] wrote res://.runtime/wind_port/gd_ref.json  cases=%d env=%d raw_pts=%d" % [
			cases.size(), env_cases.size(), (traj["pts"] as Array).size()])
	quit(0)

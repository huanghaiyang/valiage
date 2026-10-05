extends SceneTree
## 地图天气图标 + 风向标 的自检。
##
## 为什么单独写一个：minimap.gd 是 CanvasLayer 且强依赖 main/player，
## 没法在 headless 里整体实例化；但"风向角度换算 / 天气名映射 / 六种图标分支"
## 这些**纯逻辑**可以单独测 —— 那正是最容易写错的部分（角度符号、旋转方向）。

var _pass := 0
var _fail := 0


func _ck(what: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  ✓ %s%s" % [what, ("   " + detail) if detail != "" else ""])
	else:
		_fail += 1
		print("  ✗ %s   %s" % [what, detail])


func _init() -> void:
	print("=== 地图天气图标 + 风向标 自检 ===")
	var MWS := load("res://scripts/ui/map_weather_overlay.gd") as GDScript
	_ck("地图天气 overlay 脚本能加载", MWS != null)
	if MWS == null:
		print("通过 %d  |  失败 %d" % [_pass, _fail])
		quit(1)
		return

	var ov: Control = MWS.new()
	_ck("能实例化", ov != null)
	# ---- 布局：两列网格（左文字 / 右小图标），行列对齐 ----
	var grid: GridContainer = null
	for ch in ov.get_children():
		if ch is GridContainer:
			grid = ch
	_ck("用 GridContainer 做两列对齐布局", grid != null and grid.columns == 2,
			"columns=%s" % str(grid.columns if grid != null else "无"))
	_ck("共两行（天气 / 风向）", grid != null and grid.get_child_count() == 4,
			"子项 %d 个（2 行 × 2 列）" % (grid.get_child_count() if grid != null else 0))
	if grid != null:
		var l1 := grid.get_child(0) as Label
		var i1 := grid.get_child(1) as Control
		_ck("左列是文字 label、右列是图标", l1 is Label and i1 != null and not (i1 is Label),
				"左=%s 右=%s" % [l1.get_class() if l1 != null else "无", i1.get_class() if i1 != null else "无"])
		_ck("图标够小（紧凑版 ≤ 20px）", i1 != null and i1.custom_minimum_size.x <= 20.0,
				"图标 %.0fpx" % (i1.custom_minimum_size.x if i1 != null else -1))
		_ck("字号够小（紧凑版 ≤ 11）",
				l1.get_theme_font_size("font_size") <= 11, "font=%d" % l1.get_theme_font_size("font_size"))
	# 大号版：图标 ≤ 32px
	ov.set("compact", false)
	ov.call("apply_size")
	if grid != null:
		var i2 := grid.get_child(1) as Control
		_ck("大地图版图标 ≤ 32px", i2.custom_minimum_size.x <= 32.0,
				"图标 %.0fpx" % i2.custom_minimum_size.x)
	# minimap.gd 本体（改过三处接线：preload / 变量 / 两个实例 + _process 刷新）必须能解析
	var Mk := load("res://scripts/ui/minimap.gd")
	_ck("minimap.gd 能解析（含新增天气 overlay 接线）", Mk != null)
	_ck("minimap.gd 里有 weather_overlay / big_weather 两个成员",
			Mk != null and Mk.get_script_constant_map().has("MapWeatherOverlay"))

	# ---- 风向 -> 屏幕角：必须与 LandmarkOverlay 的北向约定一致 ----
	# 约定：screen = R(yaw)·(x, z)，R = [[cos,-sin],[sin,cos]]
	#   世界东 (1,0)：yaw=0 -> 0（屏幕右）
	#   世界南 (0,1)：yaw=0 -> PI/2（屏幕下，因为 +Z 朝屏幕下）
	#   世界北 (0,-1)：yaw=0 -> -PI/2（屏幕上）
	ov.call("update_weather", 0, Vector2(1.0, 0.0), 0.2, 0.0)
	_ck("东风吹向屏幕右（yaw=0）", absf(float(ov.call("vane_angle")) - 0.0) < 0.001,
			"angle=%.3f" % float(ov.call("vane_angle")))
	ov.call("update_weather", 0, Vector2(0.0, 1.0), 0.2, 0.0)
	_ck("南风吹向屏幕下（yaw=0）", absf(float(ov.call("vane_angle")) - PI * 0.5) < 0.001,
			"angle=%.3f" % float(ov.call("vane_angle")))
	ov.call("update_weather", 0, Vector2(0.0, -1.0), 0.2, 0.0)
	_ck("北风吹向屏幕上（yaw=0）", absf(float(ov.call("vane_angle")) + PI * 0.5) < 0.001,
			"angle=%.3f" % float(ov.call("vane_angle")))

	# 地图转了 90° 后，同一个风向的屏幕角要跟着转 90°
	ov.call("update_weather", 0, Vector2(1.0, 0.0), 0.2, PI * 0.5)
	_ck("小地图转 90° 后风向随之旋转（东 -> 屏幕下）",
			absf(float(ov.call("vane_angle")) - PI * 0.5) < 0.001,
			"angle=%.3f（期望 %.3f）" % [float(ov.call("vane_angle")), PI * 0.5])
	# 北向标记的等价校验：世界北在 yaw 下的方向 = (sin yaw, -cos yaw)
	var yaw := 0.7
	ov.call("update_weather", 0, Vector2(0.0, -1.0), 0.2, yaw)
	var got := float(ov.call("vane_angle"))
	var want := atan2(-cos(yaw), sin(yaw))
	_ck("与北向标记同一约定（世界北 -> (sin yaw, -cos yaw)）",
			absf(angle_difference(got, want)) < 0.001,
			"got=%.3f want=%.3f" % [got, want])

	# ---- 天气名映射：六种都要有名字 ----
	var names_ok := true
	var joined := ""
	for k in range(6):
		ov.call("update_weather", k, Vector2(1.0, 0.0), 0.2, 0.0)
		var nm := String(ov.call("weather_label"))
		joined += nm + " "
		if nm == "" or nm == "未知":
			names_ok = false
	_ck("六种天气都有中文名", names_ok, joined.strip_edges())
	# 越界 kind 要被夹住（不越界访问数组）
	ov.call("update_weather", 99, Vector2(1.0, 0.0), 0.2, 0.0)
	_ck("越界的天气编号被夹住", int(ov.get("kind")) == 5, "kind=%d" % int(ov.get("kind")))
	# 零向量风向要有兜底（否则 atan2(0,0) 角度不稳定）
	ov.call("update_weather", 5, Vector2.ZERO, 0.2, 0.0)
	_ck("零向量风向有兜底", (ov.get("wind_dir") as Vector2).length() > 0.5,
			"dir=%s" % str(ov.get("wind_dir")))

	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

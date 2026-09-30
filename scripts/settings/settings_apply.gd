@tool
class_name SettingsApply
extends RefCounted
## 把设置真的应用到引擎。
##
## ★ 画质档位是**一个数字驱动两套系统** ✓（这是与项目原有 Settings 单例的合并方式）：
##     · 项目原有 scripts/settings.gd（autoload 名 Settings）→ MSAA / 模型 LOD / 草丛 / 植被距离 / 体积雾
##     · 本项目新增的 Quality 系统                        → 地表贴图分辨率 / 地形 LOD
##   这样两侧永远不会各说各话 ✓，也不会删掉任何一方已有的调参逻辑 ✓
##
## ⚠️ 编辑器里**绝不碰显示相关**（窗口/垂直同步/帧率/缩放）✗ —— 那会改掉编辑器自己的窗口 ✗

const BUS_OF := {
	"audio/master": "Master",
	"audio/music": "Music",
	"audio/sfx": "SFX",
	"audio/ui": "UI",
	"audio/voice": "Voice",
}

## 阴影质量档 → RenderSettings 用的整数值（避免直接引用可能不存在的枚举常量 ✗）
## 0=硬阴影 1=软·低 2=软·中 3=软·高 4=软·极高
const SHADOW_QUALITY_VALUES := [1, 2, 3, 4]
const SHADOW_ATLAS_SIZES := [1024, 2048, 4096, 8192]


static func apply_all(store) -> Dictionary:
	var result := {}
	ensure_buses()
	for key in SettingsSchema.defaults().keys():
		result[key] = apply_one(store, String(key))
	return result


static func apply_one(store, key: String) -> String:
	var d := SettingsSchema.find(key)
	if d.is_empty():
		return "unknown"
	if bool(d.get("todo", false)):
		return "todo"
	if BUS_OF.has(key):
		return "ok" if apply_bus(store, key) else "failed"
	match key:
		"graphics/tier":
			return apply_tier(int(store.get_value(key)))
		"graphics/aa":
			if Engine.is_editor_hint():
				return "editor-skip"
			return apply_aa(int(store.get_value(key)))
		"graphics/shadow":
			if Engine.is_editor_hint():
				return "editor-skip"
			return apply_shadow(int(store.get_value(key)))
		"graphics/window_mode", "graphics/vsync", "graphics/fps_limit":
			if Engine.is_editor_hint():
				return "editor-skip"
			apply_display(store)
			return "ok"
		"access/ui_scale":
			if Engine.is_editor_hint():
				return "editor-skip"
			apply_ui_scale(float(store.get_value(key)))
			return "ok"
		"language/subtitle":
			return "ok"          # 字幕由 GameSettings.show_subtitle() 的开关读取 ✓
	return "todo"


## ★ 一个档位 → 两套系统（合并点 ✓）
static func apply_tier(tier: int) -> String:
	var t := clampi(tier, 0, 3)
	var project_settings := _autoload("Settings")
	var touched := 0
	if project_settings != null and "quality" in project_settings:
		project_settings.set("quality", t)          # 你的渲染质量档（MSAA/LOD/草丛/雾）✓
		touched += 1
	# 运行时是 autoload（QualityManager.instance ✓）；编辑器里 autoload 不加载 ✗ → 用节点名兜底 ✓
	var q = QualityManager.instance
	if q == null:
		q = _autoload("Quality")
	if q != null:
		q.set_tier(t)                               # 地表贴图 / 地形 LOD ✓
		touched += 1
	if touched == 0:
		return "queued"
	return "ok"


## 读出项目原有 Settings 的档位（菜单打开时同步用 ✓）
static func read_project_tier() -> int:
	var project_settings := _autoload("Settings")
	if project_settings != null and "quality" in project_settings:
		return int(project_settings.get("quality"))
	return -1


static func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null(NodePath(node_name))
	return null


## 抗锯齿：0=关 1=FXAA 2=MSAA2x 3=MSAA4x（项目原本就是 MSAA4x，所以默认取 3 ✓）
static func apply_aa(index: int) -> String:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return "failed"
	var vp := (loop as SceneTree).root
	if vp == null:
		return "failed"
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if index == 1 else Viewport.SCREEN_SPACE_AA_DISABLED
	match index:
		2:
			vp.msaa_3d = Viewport.MSAA_2X
		3:
			vp.msaa_3d = Viewport.MSAA_4X
		_:
			vp.msaa_3d = Viewport.MSAA_DISABLED
	return "ok"


## 阴影质量：走 RenderingServer 的全局方向光阴影设置 ✓
## 用整数值而不是枚举常量：某些版本没有 SHADOW_QUALITY_* 常量，
## 直接写常量名会导致**解析失败** ✗ → 改用整数 + has_method 守卫 ✓
static func apply_shadow(index: int) -> String:
	var i := clampi(index, 0, 3)
	var ok := false
	if RenderingServer.has_method("directional_soft_shadow_filter_set_quality"):
		RenderingServer.call("directional_soft_shadow_filter_set_quality", int(SHADOW_QUALITY_VALUES[i]))
		ok = true
	if RenderingServer.has_method("directional_shadow_atlas_set_size"):
		RenderingServer.call("directional_shadow_atlas_set_size", int(SHADOW_ATLAS_SIZES[i]), true)
		ok = true
	return "ok" if ok else "failed"


static func ensure_buses() -> Array:
	var created: Array = []
	for key in BUS_OF.keys():
		var bus := String(BUS_OF[key])
		if AudioServer.get_bus_index(bus) != -1:
			continue
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus)
		if bus != "Master":
			AudioServer.set_bus_send(idx, "Master")
		created.append(bus)
	return created


static func apply_bus(store, key: String) -> bool:
	var bus := String(BUS_OF.get(key, ""))
	if bus == "":
		return false
	var idx := AudioServer.get_bus_index(bus)
	if idx == -1:
		ensure_buses()
		idx = AudioServer.get_bus_index(bus)
	if idx == -1:
		return false
	var v := clampf(float(store.get_value(key)), 0.0, 1.0)
	# linear_to_db(0) 是负无穷 ✗ → 夹一个极小值；真静音用 mute ✓
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))
	AudioServer.set_bus_mute(idx, v <= 0.001)
	return true


static func apply_display(store) -> void:
	match int(store.get_value("graphics/window_mode")):
		1:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	if bool(store.get_value("graphics/vsync")):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var idx := SettingsSchema.value_to_index("graphics/fps_limit", store.get_value("graphics/fps_limit"))
	var vals: Array = SettingsSchema.find("graphics/fps_limit").get("values", [])
	Engine.max_fps = int(vals[idx]) if idx < vals.size() else 0


static func apply_ui_scale(scale: float) -> void:
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null and loop.root != null:
		loop.root.content_scale_factor = clampf(scale, 0.5, 3.0)


static func about_info() -> Dictionary:
	var v := Engine.get_version_info()
	var adapter := RenderingServer.get_video_adapter_name()
	# 项目里 application/config/version 可能是空串 ✗（默认值只在键不存在时生效 ✗）
	var ver := String(ProjectSettings.get_setting("application/config/version", ""))
	if ver.strip_edges() == "":
		ver = "0.1.0"
	var renderer := "Forward+"
	match String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus")):
		"mobile":
			renderer = "Mobile"
		"gl_compatibility":
			renderer = "Compatibility"
	return {
		"about/version": ver,
		"about/engine": "Godot %d.%d.%d" % [int(v["major"]), int(v["minor"]), int(v["patch"])],
		"about/renderer": "%s ｜ %s" % [renderer, adapter],
		"about/memory": "%.0f MB" % (OS.get_static_memory_usage() / 1048576.0),
		"about/save_dir": ProjectSettings.globalize_path("user://"),
		"about/crash_dir": ProjectSettings.globalize_path("user://crash_monitor"),
	}
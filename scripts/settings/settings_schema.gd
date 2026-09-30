@tool
class_name SettingsSchema
extends RefCounted
## 设置项定义表（纯数据 ✓ 便于单测）
##
## 说明：
##   · 分类与条目覆盖常规游戏的设置菜单（画质/音频/语言/操作/游戏/辅助/关于）
##   · todo=true 表示"**功能还没做，先占位**" —— 界面上照常显示，但控件置灰并标注（待开发）
##   · 已经能真生效的：画质档位（接 Quality 系统 ✓）、音量（真实音频总线 ✓）、
##     窗口模式 / 垂直同步 / 帧率上限 / 界面缩放 ✓

enum Kind { TOGGLE, SLIDER, CHOICE, INFO }

const CAT_GRAPHICS := "画质"
const CAT_AUDIO := "音频"
const CAT_LANGUAGE := "语言"
const CAT_CONTROLS := "操作"
const CAT_GAMEPLAY := "游戏"
const CAT_ACCESS := "辅助功能"
const CAT_ABOUT := "关于"

const ORDER := [CAT_GRAPHICS, CAT_AUDIO, CAT_LANGUAGE, CAT_CONTROLS, CAT_GAMEPLAY, CAT_ACCESS, CAT_ABOUT]


static func items() -> Dictionary:
	return {
		CAT_GRAPHICS: [
			{"key": "graphics/tier", "label": "画质档位", "kind": Kind.CHOICE, "default": 2,
				"choices": ["低", "中", "高", "极高"],
				"hint": "同时控制地表贴图分辨率与地形 LOD ✓（已接画质分级系统）"},
			{"key": "graphics/window_mode", "label": "窗口模式", "kind": Kind.CHOICE, "default": 0,
				"choices": ["窗口", "无边框全屏", "独占全屏"]},
			{"key": "graphics/vsync", "label": "垂直同步", "kind": Kind.TOGGLE, "default": true},
			{"key": "graphics/fps_limit", "label": "帧率上限", "kind": Kind.CHOICE, "default": 2,
				"choices": ["不限制", "30", "60", "120", "144"], "values": [0, 30, 60, 120, 144]},
			{"key": "graphics/aa", "label": "抗锯齿", "kind": Kind.CHOICE, "default": 3,
				"choices": ["关", "FXAA", "MSAA 2x", "MSAA 4x"],
				"hint": "默认与项目现状一致（MSAA 4x ✓）；「画质档位」也会联动这一项 ✓"},
			{"key": "graphics/shadow", "label": "阴影质量", "kind": Kind.CHOICE, "default": 2,
				"choices": ["低", "中", "高", "极高"], "hint": "全局方向光阴影精度与图集大小 ✓"},
			{"key": "graphics/texture", "label": "贴图质量", "kind": Kind.CHOICE, "default": 2,
				"choices": ["低", "中", "高", "极高"], "todo": true,
				"hint": "已由上面的「画质档位」统一控制 ✓"},
		],
		CAT_AUDIO: [
			{"key": "audio/master", "label": "主音量", "kind": Kind.SLIDER, "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01},
			{"key": "audio/music", "label": "音乐", "kind": Kind.SLIDER, "default": 0.8, "min": 0.0, "max": 1.0, "step": 0.01},
			{"key": "audio/sfx", "label": "音效", "kind": Kind.SLIDER, "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01},
			{"key": "audio/ui", "label": "界面音效", "kind": Kind.SLIDER, "default": 0.8, "min": 0.0, "max": 1.0, "step": 0.01},
			{"key": "audio/voice", "label": "对话音量", "kind": Kind.SLIDER, "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01, "todo": true},
		],
		CAT_LANGUAGE: [
			{"key": "language/locale", "label": "界面语言", "kind": Kind.CHOICE, "default": 0,
				"choices": ["简体中文"], "todo": true, "hint": "尚未添加其它语言的翻译文件 ✓"},
			{"key": "language/subtitle", "label": "显示字幕", "kind": Kind.TOGGLE, "default": true, "hint": "已接字幕系统 ✓：GameSettings.show_subtitle(文本, 秒数)"},
		],
		CAT_CONTROLS: [

			{"key": "controls/sensitivity", "label": "鼠标灵敏度", "kind": Kind.SLIDER, "default": 1.0,
				"min": 0.2, "max": 3.0, "step": 0.05, "todo": true},
			{"key": "controls/invert_y", "label": "反转纵向视角", "kind": Kind.TOGGLE, "default": false, "todo": true},
		],
		CAT_GAMEPLAY: [
			{"key": "gameplay/difficulty", "label": "难度", "kind": Kind.CHOICE, "default": 1,
				"choices": ["轻松", "标准", "硬核"], "todo": true},
			{"key": "gameplay/autosave", "label": "自动存档间隔", "kind": Kind.CHOICE, "default": 1,
				"choices": ["关闭", "5 分钟", "10 分钟", "15 分钟"], "todo": true},
			{"key": "gameplay/show_fps", "label": "显示帧率", "kind": Kind.TOGGLE, "default": false, "todo": true},
			{"key": "gameplay/tutorial", "label": "显示新手提示", "kind": Kind.TOGGLE, "default": true, "todo": true},
		],
		CAT_ACCESS: [
			{"key": "access/ui_scale", "label": "界面缩放", "kind": Kind.SLIDER, "default": 1.0,
				"min": 0.8, "max": 1.4, "step": 0.05, "hint": "影响所有 HUD 与菜单大小 ✓"},
			{"key": "access/colorblind", "label": "色盲模式", "kind": Kind.CHOICE, "default": 0,
				"choices": ["关", "红绿色弱", "蓝黄色弱"], "todo": true},
			{"key": "access/subtitle_size", "label": "字幕大小", "kind": Kind.CHOICE, "default": 1,
				"choices": ["小", "中", "大"], "todo": true},
			{"key": "access/reduce_motion", "label": "减少动态效果", "kind": Kind.TOGGLE, "default": false, "todo": true},
		],
		CAT_ABOUT: [
			{"key": "about/version", "label": "游戏版本", "kind": Kind.INFO, "value_text": "0.1.0"},
			{"key": "about/engine", "label": "引擎版本", "kind": Kind.INFO, "value_text": ""},
			{"key": "about/renderer", "label": "渲染设备", "kind": Kind.INFO, "value_text": ""},
			{"key": "about/memory", "label": "内存占用", "kind": Kind.INFO, "value_text": ""},
			{"key": "about/save_dir", "label": "存档目录", "kind": Kind.INFO, "value_text": ""},
			{"key": "about/crash_dir", "label": "崩溃日志目录", "kind": Kind.INFO, "value_text": ""},
		],
	}


static func all_items() -> Array:
	var out: Array = []
	for cat in ORDER:
		var table: Dictionary = items()
		for it in (table.get(cat, []) as Array):
			var d: Dictionary = (it as Dictionary).duplicate()
			d["category"] = cat
			out.append(d)
	return out


static func find(key: String) -> Dictionary:
	for it in all_items():
		var d: Dictionary = it
		if String(d.get("key", "")) == key:
			return d
	return {}


static func is_todo(key: String) -> bool:
	return bool(find(key).get("todo", false))


static func defaults() -> Dictionary:
	var out := {}
	for it in all_items():
		var d: Dictionary = it
		out[String(d["key"])] = d.get("default", null)
	return out


static func kind_name(k: int) -> String:
	match k:
		Kind.TOGGLE: return "开关"
		Kind.SLIDER: return "滑条"
		Kind.CHOICE: return "下拉"
		Kind.INFO: return "信息"
	return "?"


## 下拉项 → 索引对应的真实值（没有 values 就用索引本身）
static func choice_value(key: String, index: int) -> Variant:
	var d := find(key)
	var values: Array = d.get("values", [])
	if index >= 0 and index < values.size():
		return values[index]
	return index


## 真实值 → 下拉索引
static func value_to_index(key: String, value: Variant) -> int:
	var d := find(key)
	var values: Array = d.get("values", [])
	if values.is_empty():
		return int(value)
	for i in range(values.size()):
		if values[i] == value:
			return i
	return 0
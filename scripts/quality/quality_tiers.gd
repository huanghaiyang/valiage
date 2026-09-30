@tool
class_name QualityTiers
extends RefCounted
## 画质档位定义（纯数据 + 纯函数，便于单元测试）。
##
## 本次范例用**地表贴图**：每档给出"用哪一套分辨率的贴图"
## （靠文件名后缀区分，如 brown_mud_leaves_01_diff_4k.jpg / _2k.jpg / _1k.jpg），
## 以及地形 LOD 参数、阴影、视距。

enum Tier { LOW, MEDIUM, HIGH, ULTRA }

const NAMES := {
	Tier.LOW: "低",
	Tier.MEDIUM: "中",
	Tier.HIGH: "高",
	Tier.ULTRA: "极高",
}

## 档位参数表
const PRESETS := {
	Tier.LOW: {
		"terrain_texture_suffix": "1k",
		"terrain_lod0_range": 64.0,
		"terrain_mesh_size": 32,
		"shadow_quality": 0,
		"view_distance": 80.0,
	},
	Tier.MEDIUM: {
		"terrain_texture_suffix": "2k",
		"terrain_lod0_range": 96.0,
		"terrain_mesh_size": 48,
		"shadow_quality": 1,
		"view_distance": 120.0,
	},
	Tier.HIGH: {
		"terrain_texture_suffix": "4k",
		"terrain_lod0_range": 128.0,
		"terrain_mesh_size": 48,
		"shadow_quality": 2,
		"view_distance": 180.0,
	},
	Tier.ULTRA: {
		"terrain_texture_suffix": "4k",
		"terrain_lod0_range": 192.0,
		"terrain_mesh_size": 64,
		"shadow_quality": 3,
		"view_distance": 260.0,
	},
}


static func all_tiers() -> Array:
	return [Tier.LOW, Tier.MEDIUM, Tier.HIGH, Tier.ULTRA]


static func get_preset(tier: int) -> Dictionary:
	return PRESETS.get(tier, PRESETS[Tier.MEDIUM])


static func tier_name(tier: int) -> String:
	return String(NAMES.get(tier, "未知"))


## 把路径结尾的分辨率后缀换成指定值：
## "…_diff_4k.jpg" + "2k" → "…_diff_2k.jpg"
## "…_nor_gl_4k.png" + "1k" → "…_nor_gl_1k.png"
## 没有后缀的会补一个："rock.png" + "2k" → "rock_2k.png"
static func swap_resolution_suffix(path: String, suffix: String) -> String:
	if path == "":
		return ""
	var base := path.get_basename()
	var ext := path.get_extension()
	var re := RegEx.new()
	re.compile("(?i)^(.*?)[_-]?(\\d+k|1024|2048|4096|8192)$")   # 同时认 _4k 与 _2048 两种命名
	var m := re.search(base)
	if m != null:
		var head := m.get_string(1)
		if head == "":
			head = base
		return "%s_%s.%s" % [head, suffix, ext]
	return "%s_%s.%s" % [base, suffix, ext]


## 该档位应该用的贴图路径
static func texture_for_tier(path: String, tier: int) -> String:
	return swap_resolution_suffix(path, String(get_preset(tier).get("terrain_texture_suffix", "4k")))


## 逐级回退：本档没有就退到更低档，最后回退到原路径。
## 这样即使只做了 4K 一套贴图，也永远不会出现"贴图丢失/变白"。
static func resolve_existing(path: String, tier: int) -> String:
	if path == "":
		return ""
	var t := tier
	while t >= Tier.LOW:
		var p := texture_for_tier(path, t)
		if ResourceLoader.exists(p):
			return p
		t -= 1
	return path
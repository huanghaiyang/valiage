extends RefCounted
## 法术数值表读取器 —— 单一数据源：res://data/spell_sheet.json
##
## 用法：
##   const SHEET := preload("res://scripts/spells/spell_sheet.gd")
##   var cost := SHEET.f("water_heal", "mana_cost", 0.0)
##   var row  := SHEET.get_spell("water_heal")
##
## 这样所有数值都集中在一个 JSON 里，改数值不用翻代码。

const PATH := "res://data/spell_sheet.json"

static var _cache: Dictionary = {}


static func _load() -> Dictionary:
	if not _cache.is_empty():
		return _cache
	if not FileAccess.file_exists(PATH):
		push_warning("[SpellSheet] 找不到配置表: %s" % PATH)
		return {}
	var txt := FileAccess.get_file_as_string(PATH)
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[SpellSheet] 配置表解析失败: %s" % PATH)
		return {}
	_cache = (parsed as Dictionary).get("spells", {})
	return _cache


## 整行（找不到返回空字典）
static func get_spell(id: String) -> Dictionary:
	return _load().get(id, {})


static func has(id: String) -> bool:
	return _load().has(id)


## 取浮点数值（找不到用 def）
static func f(id: String, key: String, def: float) -> float:
	var row := get_spell(id)
	if row.is_empty() or not row.has(key):
		return def
	return float(row[key])


## 取布尔值
static func b(id: String, key: String, def: bool) -> bool:
	var row := get_spell(id)
	if row.is_empty() or not row.has(key):
		return def
	return bool(row[key])


## 取文本
static func s(id: String, key: String, def: String = "") -> String:
	var row := get_spell(id)
	if row.is_empty() or not row.has(key):
		return def
	return String(row[key])


## 校验：cast_time 是否等于两段之和、total_time 是否等于三段之和（自检用）
static func validate(id: String) -> Array:
	var errs: Array = []
	var row := get_spell(id)
	if row.is_empty():
		return ["配置表里没有这个法术: %s" % id]
	var cast := f(id, "cast_climb", 0.0) + f(id, "cast_veil", 0.0)
	var cast_sheet := f(id, "cast_time", -1.0)
	if cast_sheet >= 0.0 and absf(cast - cast_sheet) > 0.001:
		errs.append("cast_time 对不上: 表里 %.3f, 两段之和 %.3f" % [cast_sheet, cast])
	var total := cast + f(id, "duration", 0.0) + f(id, "fade_time", 0.0)
	var total_sheet := f(id, "total_time", -1.0)
	if total_sheet >= 0.0 and absf(total - total_sheet) > 0.001:
		errs.append("total_time 对不上: 表里 %.3f, 计算 %.3f" % [total_sheet, total])
	return errs

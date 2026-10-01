@tool
extends RefCounted
## 每个"来源场景"对应的随机变体表，存进项目设置（variant_tools/sets）。
## 结构：{ "res://源场景.tscn": { "on": true, "variants": ["res://a.tscn", ...] } }
##
## 存项目设置而不是存在节点上：World Brush 的场景行会被重建，存在节点上会丢。

const KEY := "variant_tools/sets"


static func all() -> Dictionary:
	if not ProjectSettings.has_setting(KEY):
		return {}
	var v: Variant = ProjectSettings.get_setting(KEY)
	return v if v is Dictionary else {}


static func get_set(src_path: String) -> Dictionary:
	var d := all()
	if d.has(src_path):
		var one: Variant = d[src_path]
		if one is Dictionary:
			return one
	return {}


static func set_set(src_path: String, on: bool, variants: Array) -> void:
	var d := all()
	d[src_path] = {"on": on, "variants": variants}
	ProjectSettings.set_setting(KEY, d)
	ProjectSettings.save()


static func set_enabled(src_path: String, on: bool) -> void:
	var one := get_set(src_path)
	var variants: Array = one.get("variants", [])
	set_set(src_path, on, variants)


static func is_enabled(src_path: String) -> bool:
	return bool(get_set(src_path).get("on", false))


static func variants_of(src_path: String) -> Array:
	return get_set(src_path).get("variants", [])
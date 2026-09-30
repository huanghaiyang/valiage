@tool
extends RefCounted
## 扫描并加载 GLB 预览窗口的扩展。

const DIR := "res://addons/glb_tools/extensions"
const BASE := "res://addons/glb_tools/preview_extension.gd"


## 返回 [{file, instance}]（按文件名排序）。
## include_hidden=true 时连 _ 开头的示例也加载 —— 测试用它来验证机制。
static func scan(include_hidden := false) -> Array:
	var out: Array = []
	if not DirAccess.dir_exists_absolute(DIR):
		return out
	var names := DirAccess.get_files_at(DIR)
	if names.is_empty():
		return out
	var sorted := Array(names)
	sorted.sort()
	for f in sorted:
		var file := String(f)
		if not file.ends_with(".gd"):
			continue
		if file.begins_with("_") and not include_hidden:
			continue
		var script: GDScript = load(DIR.path_join(file))
		if script == null:
			push_warning("[GLB 扩展] 加载失败（有解析错误？）：%s" % file)
			continue
		var inst = script.new()
		if inst == null or not inst.has_method("ext_name"):
			push_warning("[GLB 扩展] 不是合法扩展（缺 ext_name / 没继承基类）：%s" % file)
			continue
		out.append({"file": file, "instance": inst})
	return out
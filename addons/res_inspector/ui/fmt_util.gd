@tool
extends RefCounted
## ResFileFormat 调用适配层。
##
## 三件事：
## 1. 懒加载解析模块（路径可被测试脚本改指向替身脚本）；
## 2. 每次调用前先 `has_method`，模块缺方法时不会刷 SCRIPT ERROR；
## 3. 校验返回值类型，不合预期就退回本地兜底（例如直接读文件切字节）。
##
## 注意：这里**不做任何 .res 格式解析** —— 解析一律由 res_format.gd 负责。
## 下面的反射兜底只在解析模块暂时缺少某个方法时启用，属于优雅降级。

## 解析核心的约定路径（契约文件 CONTRACT.md 第 2 节）
const FORMAT_PATH := "res://addons/res_inspector/res_format.gd"


## 懒加载解析模块；文件不存在/加载失败都返回 null（UI 显示「解析模块未就绪」）
static func load_format(path: String = FORMAT_PATH):
	var p := path.strip_edges()
	if p == "":
		return null
	if not FileAccess.file_exists(p) and not ResourceLoader.exists(p):
		return null
	var s = load(p)
	if s == null:
		return null
	if not (s is Script):
		return null
	return s


## 解析模块是否提供某个静态方法
static func has(fmt, method: String) -> bool:
	if fmt == null:
		return false
	if not (fmt is Script):
		return false
	return (fmt as Script).has_method(method)


## 安全调用：没有该方法 / 返回 null 时给兜底值
static func safe_call(fmt, method: String, args: Array, fallback):
	if not has(fmt, method):
		return fallback
	var r = fmt.callv(method, args)
	if r == null:
		return fallback
	return r


## 调 inspect()；返回字典一定可用（失败返回空字典）
## load_resource=false 对应「仅结构解析」（大文件时跳过 ResourceLoader）
static func inspect(fmt, path: String, load_resource: bool = true) -> Dictionary:
	var r = safe_call(fmt, "inspect", [path, load_resource], null)
	if r is Dictionary:
		var d: Dictionary = r
		if not d.has("path"):
			d["path"] = path
		return d
	return {}


## 读一段原始字节：优先解析模块的 read_slice()，失败则自己按偏移读（不解码）
static func read_slice(fmt, path: String, offset: int, length: int) -> PackedByteArray:
	if length <= 0 or offset < 0:
		return PackedByteArray()
	var r = safe_call(fmt, "read_slice", [path, offset, length], null)
	if r is PackedByteArray:
		var b: PackedByteArray = r
		if b.size() > 0 and b.size() <= length:
			return b
	return read_slice_direct(path, offset, length)


## 直接按偏移读文件（不解析内容）
static func read_slice_direct(path: String, offset: int, length: int) -> PackedByteArray:
	if path == "" or offset < 0 or length <= 0:
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	if f.get_length() <= offset:
		f.close()
		return PackedByteArray()
	f.seek(offset)
	var out := f.get_buffer(length)
	f.close()
	return out


## 顶层可见属性（契约形状：name/type/type_name/value_text/expandable/value/resource_path/read_only）
static func property_entries(fmt, obj: Object, filter: String = "") -> Array:
	if obj == null:
		return []
	var r = safe_call(fmt, "property_entries", [obj, filter], null)
	if r is Array:
		return r
	return _reflect_property_entries(obj, filter)


## 懒展开子项（契约形状同 property_entries）
static func child_entries(fmt, value) -> Array:
	var r = safe_call(fmt, "child_entries", [value], null)
	if r is Array:
		return r
	return _reflect_child_entries(value)


## 字节数格式化：优先解析模块实现
static func human_size(fmt, bytes: int) -> String:
	var r = safe_call(fmt, "human_size", [bytes], null)
	if r is String and String(r) != "":
		return String(r)
	return _human_size_local(bytes)


## 类型名：优先解析模块实现，兜底用引擎自带的 type_string()
static func type_label(fmt, variant_type: int) -> String:
	var r = safe_call(fmt, "type_label", [variant_type], null)
	if r is String and String(r) != "":
		return String(r)
	return type_string(variant_type)


## 单行值摘要：优先解析模块实现
static func value_text(fmt, value, max_len: int = 120) -> String:
	var r = safe_call(fmt, "value_text", [value, max_len], null)
	if r is String:
		return String(r)
	return _value_text_local(value, max_len)


## 纯文本报告：优先解析模块实现；缺失时给一份最小可用报告
static func format_report(fmt, info: Dictionary) -> String:
	var r = safe_call(fmt, "format_report", [info], null)
	if r is String and String(r) != "":
		return String(r)
	return _report_local(info)


# ---------------------------------------------------------------------------
# 以下为兜底实现（解析模块正常时不会走到）
# ---------------------------------------------------------------------------

static func _human_size_local(bytes: int) -> String:
	if bytes < 0:
		return "-"
	if bytes < 1024:
		return "%d B" % bytes
	var kb := float(bytes) / 1024.0
	if kb < 1024.0:
		return "%.1f KB" % kb
	var mb := kb / 1024.0
	if mb < 1024.0:
		return "%.2f MB" % mb
	return "%.2f GB" % (mb / 1024.0)


static func _value_text_local(value, max_len: int) -> String:
	var s := ""
	match typeof(value):
		TYPE_NIL:
			s = "null"
		TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH:
			s = "\"%s\"" % str(value)
		_:
			s = str(value)
	s = s.replace("\r", " ").replace("\n", " ").replace("\t", " ")
	if max_len > 0 and s.length() > max_len:
		s = s.substr(0, maxi(0, max_len - 1)) + "…"
	return s


static func _is_expandable(value) -> bool:
	match typeof(value):
		TYPE_ARRAY, TYPE_DICTIONARY, TYPE_OBJECT:
			return true
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			return true
		_:
			return false


static func _make_entry(name: String, value) -> Dictionary:
	var t: int = typeof(value)
	var rp := ""
	if value is Resource:
		rp = (value as Resource).resource_path
	return {
		"name": name,
		"type": t,
		"type_name": type_string(t),
		"value_text": _value_text_local(value, 120),
		"expandable": _is_expandable(value),
		"value": value,
		"resource_path": rp,
		"read_only": false,
	}


## 反射兜底：按 Object.get_property_list() 拼条目（跳过 STORAGE 之外与 script）
static func _reflect_property_entries(obj: Object, filter: String) -> Array:
	var out: Array = []
	if obj == null:
		return out
	var fl := filter.strip_edges().to_lower()
	for p in obj.get_property_list():
		var usage: int = int(p.get("usage", 0))
		if (usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var nm := str(p.get("name", ""))
		if nm == "" or nm == "script":
			continue
		if fl != "" and not nm.to_lower().contains(fl):
			continue
		var v = obj.get(nm)
		out.append(_make_entry(nm, v))
	return out


## 反射兜底：展开 Array / Dictionary / Packed*Array / Object
static func _reflect_child_entries(value) -> Array:
	var out: Array = []
	match typeof(value):
		TYPE_ARRAY:
			var arr: Array = value
			for i in arr.size():
				out.append(_make_entry("[%d]" % i, arr[i]))
		TYPE_DICTIONARY:
			var d: Dictionary = value
			for k in d:
				out.append(_make_entry(str(k), d[k]))
		TYPE_OBJECT:
			if value != null:
				return _reflect_property_entries(value, "")
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var n: int = int(value.size())
			for i in n:
				out.append(_make_entry("[%d]" % i, value[i]))
	return out


static func _report_local(info: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("=== 资源检查报告（简化版）===")
	lines.append("路径: %s" % str(info.get("path", "")))
	lines.append("绝对路径: %s" % str(info.get("abs_path", "")))
	lines.append("大小: %s（%d 字节）" % [_human_size_local(int(info.get("size", 0))), int(info.get("size", 0))])
	lines.append("格式: %s" % str(info.get("format", "")))
	lines.append("置信度: %s" % str(info.get("confidence", "")))
	lines.append("解析成功: %s" % str(info.get("ok", false)))
	var err := str(info.get("error", ""))
	if err != "":
		lines.append("错误: %s" % err)
	var le := str(info.get("load_error", ""))
	if le != "":
		lines.append("载入错误: %s" % le)
	lines.append("资源类: %s" % str(info.get("resource_class", "")))
	var warnings: PackedStringArray = info.get("warnings", PackedStringArray())
	for w in warnings:
		lines.append("告警: %s" % str(w))
	return "\n".join(lines)

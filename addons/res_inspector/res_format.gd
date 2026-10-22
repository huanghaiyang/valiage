@tool
class_name ResFileFormat
extends RefCounted
## RES 文件解析核心（纯逻辑，无编辑器依赖，可无头运行）。
##
## 支持：
##   · Godot 二进制资源 `RSRC`（含 .res / 二进制 .scn）——头部字段、字符串表、外部依赖表、内部子资源表
##   · 文本资源 `.tres` / `.tscn`（`[gd_resource]` / `[gd_scene]` / `[ext_resource]` / `[sub_resource]`）
##   · 压缩资源 `RSCC`（工程导入产物）——只能给出魔数/大小，结构解析不支持，但会尝试 ResourceLoader 载入
##
## 二进制格式说明（在 Godot 4.7.2 实测得出，跨版本可能不同）：
##   "RSRC" | u32 大端 | u32 real64 | u32 版本主 | u32 版本次 | u32 版本补丁
##   | u32 类型名长度(含结尾 0) | 类型名 | u32 A | u32 B | u32 flags | u64 uid
##   | pascal 字符串 script_class（长度 0 表示无）| 40 字节保留区（4.7.2）
##   | u32 字符串表数 n | n × pascal 字符串
##   | u32 外部依赖数 e | e × (pascal 类型, pascal 路径, u64 uid)
##   | u32 内部子资源数 m | m × (pascal 路径, u64 数据偏移)
##   | 各资源的数据块 …
##
##   pascal 字符串 = u32 字节长度(含结尾 0) + UTF-8 字节（**无对齐填充**）。
##   关键不变量（用来判断解析是否可信）：内部子资源表第一项的偏移 == 表结束位置。

## 4.7.2 实测的头部保留区长度；不一致时只降低置信度，不影响解析。
const RESERVED_HEADER_HINT := 40
## 单次扫描字符串表的最大回溯窗口（应对 script_class 等变长字段）。
const TABLE_SCAN_WINDOW := 4096
## 展开子项 / 字符串表的最大条目数，防止异常文件撑爆界面。
const MAX_ENTRIES := 200000

## Variant 类型名表（下标即 TYPE_*）。
const TYPE_NAMES := [
	"Nil", "bool", "int", "float", "String", "Vector2", "Vector2i", "Rect2", "Rect2i",
	"Vector3", "Vector3i", "Transform2D", "Vector4", "Vector4i", "Plane", "Quaternion",
	"AABB", "Basis", "Transform3D", "Projection", "Color", "StringName", "NodePath", "RID",
	"Object", "Callable", "Signal", "Dictionary", "Array", "PackedByteArray",
	"PackedInt32Array", "PackedInt64Array", "PackedFloat32Array", "PackedFloat64Array",
	"PackedStringArray", "PackedVector2Array", "PackedVector3Array", "PackedColorArray",
	"PackedVector4Array",
]

# ---------------------------------------------------------------- 对外 API

## 解析一个资源文件，返回结构化字典（键名见 CONTRACT.md）。
## load_resource=false 时跳过 ResourceLoader（只看结构，不执行/不建资源）。
static func inspect(path: String, load_resource: bool = true) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var info := {
		"ok": false,
		"path": path,
		"abs_path": "",
		"in_project": false,
		"exists": false,
		"size": 0,
		"mtime": 0,
		"format": "unknown",
		"error": "",
		"warnings": PackedStringArray(),
		"confidence": "partial",
		"elapsed_ms": 0,
		"binary": {},
		"text": {},
		"resource": null,
		"resource_class": "",
		"resource_script": "",
		"load_error": "",
	}

	var abs_path := to_abs(path)
	info["abs_path"] = abs_path
	info["in_project"] = is_in_project(abs_path)

	if not FileAccess.file_exists(path) and not FileAccess.file_exists(abs_path):
		info["error"] = "文件不存在：%s" % path
		info["elapsed_ms"] = Time.get_ticks_msec() - t0
		return info

	info["exists"] = true
	info["size"] = _file_size(abs_path)
	info["mtime"] = FileAccess.get_modified_time(abs_path)

	var bytes: PackedByteArray = FileAccess.get_file_as_bytes(abs_path)
	if bytes.is_empty() and info["size"] > 0:
		info["error"] = "读取失败（文件为空或权限不足）"
		info["elapsed_ms"] = Time.get_ticks_msec() - t0
		return info

	# ---- 判定格式 ----
	var magic := ""
	if bytes.size() >= 4:
		magic = bytes.slice(0, 4).get_string_from_ascii()

	if magic == "RSRC":
		info["format"] = "binary"
		_parse_binary(info, bytes)
	elif magic == "RSCC":
		info["format"] = "binary"
		info["binary"] = {
			"magic": "RSCC",
			"header_tail_offset": 4,
			"header_tail": bytes.slice(0, mini(48, bytes.size())),
			"header_unknown_len": 0,
			"flags_guess": -1,
			"uid": "无",
			"string_table_offset": -1,
			"strings": PackedStringArray(),
			"external": [],
			"internal": [],
			"data_offset": -1,
			"type": "",
			"format_version": "",
			"big_endian": false,
			"use_real64": false,
		}
		info["error"] = "压缩二进制资源（RSCC，工程导入产物）：结构表不支持解析，可看属性与预览"
		_warn(info, "RSCC 头部：%s" % _hex_preview(bytes.slice(4, mini(20, bytes.size()))))
	elif _looks_like_text(bytes):
		info["format"] = "text"
		_parse_text(info, bytes)
	else:
		info["format"] = "unknown"
		info["error"] = "无法识别的格式（魔数：%s）" % (magic if magic != "" else "空")

	# ---- 载入资源（属性树 / 预览要用）----
	if load_resource:
		_load_resource(info, abs_path)
	else:
		info["load_error"] = "已跳过载入（仅结构解析）"

	info["elapsed_ms"] = Time.get_ticks_msec() - t0
	return info


## 读取文件任意区段字节（十六进制视图分页用）。越界自动裁剪，失败返回空数组。
static func read_slice(path: String, offset: int, length: int) -> PackedByteArray:
	var abs_path := to_abs(path)
	if offset < 0 or length <= 0:
		return PackedByteArray()
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	f.seek(maxi(offset, 0))
	var out := f.get_buffer(length)
	f.close()
	return out


## 枚举对象的可见属性（属性树顶层）。
static func property_entries(obj: Object, filter: String = "") -> Array:
	var out: Array = []
	if obj == null or not is_instance_valid(obj):
		return out
	var skip := PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP
	var want := filter.strip_edges().to_lower()
	for p in obj.get_property_list():
		var usage := int(p.get("usage", 0))
		if (usage & skip) != 0:
			continue
		if (usage & (PROPERTY_USAGE_STORAGE | PROPERTY_USAGE_EDITOR)) == 0:
			continue
		var nm := String(p.get("name", ""))
		if nm == "":
			continue
		if want != "" and not nm.to_lower().contains(want):
			continue
		var t := int(p.get("type", TYPE_NIL))
		# 只读属性/内部属性也可能抛错，但 Object.get 本身是安全的
		var v: Variant = obj.get(nm)
		out.append(entry_of(nm, t, v))
		if out.size() >= MAX_ENTRIES:
			break
	return out


## 枚举某个值的子项（属性树懒展开 / 预览用）。
static func child_entries(value: Variant) -> Array:
	var out: Array = []
	match typeof(value):
		TYPE_ARRAY:
			var arr: Array = value
			for i in range(mini(arr.size(), MAX_ENTRIES)):
				out.append(entry_of("[%d]" % i, typeof(arr[i]), arr[i]))
		TYPE_DICTIONARY:
			var dict: Dictionary = value
			var n := 0
			for k in dict.keys():
				out.append(entry_of(str(k), typeof(dict[k]), dict[k]))
				n += 1
				if n >= MAX_ENTRIES:
					break
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, \
		TYPE_PACKED_VECTOR4_ARRAY:
			var pv: Variant = value
			var count: int = pv.size()
			for i in range(mini(count, MAX_ENTRIES)):
				out.append(entry_of("[%d]" % i, typeof(pv[i]), pv[i]))
		TYPE_OBJECT:
			if value is Object and is_instance_valid(value):
				return property_entries(value)
	return out


## 生成一个属性条目字典。
static func entry_of(name: String, type: int, value: Variant) -> Dictionary:
	var path := ""
	if value is Resource:
		path = String(value.resource_path)
	return {
		"name": name,
		"type": type,
		"type_name": type_label(type),
		"value_text": value_text(value),
		"expandable": is_expandable(value),
		"value": value,
		"resource_path": path,
		"read_only": false,
	}


static func is_expandable(value: Variant) -> bool:
	match typeof(value):
		TYPE_ARRAY, TYPE_DICTIONARY, TYPE_OBJECT:
			return true
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, \
		TYPE_PACKED_VECTOR4_ARRAY:
			return value.size() > 0
	return false


## 生成纯文本报告（复制/导出用）。
static func format_report(info: Dictionary) -> String:
	var lines: PackedStringArray = []
	lines.append("=== RES 文件报告 ===")
	lines.append("路径      : %s" % str(info.get("path", "")))
	if info.get("abs_path", "") != info.get("path", ""):
		lines.append("绝对路径  : %s" % str(info.get("abs_path", "")))
	lines.append("大小      : %s（%d 字节）" % [human_size(int(info.get("size", 0))), int(info.get("size", 0))])
	var mt := int(info.get("mtime", 0))
	lines.append("修改时间  : %s" % (Time.get_datetime_string_from_unix_time(mt, true) if mt > 0 else "未知"))
	lines.append("格式      : %s" % _format_label(str(info.get("format", "unknown"))))
	lines.append("解析结果  : %s（置信度 %s，耗时 %d ms）" % [
		("成功" if info.get("ok", false) else "失败"), str(info.get("confidence", "")), int(info.get("elapsed_ms", 0))])

	var err := str(info.get("error", ""))
	if err != "":
		lines.append("错误      : %s" % err)

	var binfo: Dictionary = info.get("binary", {})
	if not binfo.is_empty():
		lines.append("")
		lines.append("--- 二进制头部 ---")
		lines.append("魔数      : %s" % str(binfo.get("magic", "")))
		lines.append("资源类型  : %s" % str(binfo.get("type", "")))
		lines.append("格式版本  : %s" % str(binfo.get("format_version", "")))
		lines.append("字节序    : %s" % ("大端" if binfo.get("big_endian", false) else "小端"))
		lines.append("real64    : %s" % ("是" if binfo.get("use_real64", false) else "否"))
		lines.append("flags     : %s" % _flags_text(int(binfo.get("flags_guess", -1))))
		lines.append("UID       : %s" % str(binfo.get("uid", "无")))
		var sc := str(binfo.get("script_class", ""))
		if sc != "":
			lines.append("脚本类名  : %s" % sc)
		var tail_len := int(binfo.get("header_unknown_len", 0))
		if tail_len > 0:
			lines.append("保留区    : %d 字节（%s）" % [tail_len, _hex_preview(binfo.get("header_tail", PackedByteArray()))])
		var strings: PackedStringArray = binfo.get("strings", PackedStringArray())
		lines.append("字符串表  : %d 项" % strings.size())
		var exts: Array = binfo.get("external", [])
		lines.append("外部依赖  : %d 项" % exts.size())
		for e in exts:
			lines.append("    · [%s] %s" % [str(e.get("type", "")), str(e.get("path", ""))])
		var ints: Array = binfo.get("internal", [])
		lines.append("内部子资源: %d 项" % ints.size())
		for e in ints:
			lines.append("    · %s @ %d" % [str(e.get("path", "")), int(e.get("offset", -1))])
		if int(binfo.get("data_offset", -1)) >= 0:
			lines.append("数据起点  : %d" % int(binfo.get("data_offset", -1)))

	var tinfo: Dictionary = info.get("text", {})
	if not tinfo.is_empty():
		lines.append("")
		lines.append("--- 文本头部 ---")
		lines.append("标签      : %s" % str(tinfo.get("header_tag", "")))
		lines.append("资源类型  : %s" % str(tinfo.get("type", "")))
		lines.append("脚本类名  : %s" % str(tinfo.get("script_class", "")))
		lines.append("UID       : %s" % str(tinfo.get("uid", "")))
		lines.append("load_steps: %d" % int(tinfo.get("load_steps", 0)))
		lines.append("format    : %d" % int(tinfo.get("format", 0)))
		lines.append("行数      : %d" % int(tinfo.get("line_count", 0)))
		var tex: Array = tinfo.get("external", [])
		lines.append("外部依赖  : %d 项" % tex.size())
		for e in tex:
			lines.append("    · [%s] %s (id=%s)" % [str(e.get("type", "")), str(e.get("path", "")), str(e.get("id", ""))])
		var subs: Array = tinfo.get("sub_resources", [])
		lines.append("子资源    : %d 项" % subs.size())
		for s in subs:
			lines.append("    · %s (%s，%d 个属性)" % [str(s.get("id", "")), str(s.get("type", "")), int(s.get("properties", 0))])
		lines.append("根属性    : %d 项" % int(tinfo.get("root_properties", 0)))

	lines.append("")
	lines.append("--- 载入结果 ---")
	if info.get("resource", null) != null:
		lines.append("资源类    : %s" % str(info.get("resource_class", "")))
		var rp := str(info.get("resource_script", ""))
		lines.append("脚本      : %s" % (rp if rp != "" else "无"))
		lines.append("资源路径  : %s" % str(info["resource"].resource_path))
		lines.append("资源名    : %s" % str(info["resource"].resource_name))
	else:
		lines.append("载入失败  : %s" % str(info.get("load_error", "未知原因")))

	var warns: PackedStringArray = info.get("warnings", PackedStringArray())
	if warns.size() > 0:
		lines.append("")
		lines.append("--- 警告 ---")
		for w in warns:
			lines.append("    ! %s" % w)
	return "\n".join(lines)


## 字节数转可读文本。
static func human_size(bytes: int) -> String:
	var n := float(bytes)
	if bytes < 1024:
		return "%d B" % bytes
	if n < 1024.0 * 1024.0:
		return "%.1f KB" % (n / 1024.0)
	if n < 1024.0 * 1024.0 * 1024.0:
		return "%.1f MB" % (n / 1048576.0)
	return "%.2f GB" % (n / 1073741824.0)


## Variant 类型名（TYPE_* → 名称）。
static func type_label(type: int) -> String:
	if type >= 0 and type < TYPE_NAMES.size():
		return TYPE_NAMES[type]
	return "Type(%d)" % type


## 值的单行摘要。
static func value_text(value: Variant, max_len: int = 120) -> String:
	var s := ""
	match typeof(value):
		TYPE_NIL:
			return "null"
		TYPE_STRING, TYPE_STRING_NAME:
			s = "\"%s\"" % str(value).c_escape()
		TYPE_OBJECT:
			if value is Resource:
				var res := value as Resource
				var cls := res.get_class()
				var rp := String(res.resource_path)
				s = "<%s> %s" % [cls, rp if rp != "" else "(内嵌资源)"]
			elif value is Object:
				s = "<%s#%d>" % [value.get_class(), value.get_instance_id()]
			else:
				s = "null"
		TYPE_ARRAY:
			s = "[%d 项]" % (value as Array).size()
		TYPE_DICTIONARY:
			s = "{%d 键}" % (value as Dictionary).size()
		TYPE_CALLABLE, TYPE_SIGNAL:
			s = str(value)
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, \
		TYPE_PACKED_VECTOR4_ARRAY:
			s = "%s（%d 项）" % [type_label(typeof(value)), (value as Variant).size()]
		TYPE_COLOR:
			s = "#" + (value as Color).to_html(true)
		TYPE_BOOL:
			s = "true" if value else "false"
		_:
			s = str(value)
	if s.length() > max_len:
		s = s.substr(0, max_len) + "…"
	return s


# ---------------------------------------------------------------- 路径工具

## 任意路径 → 绝对路径。
static func to_abs(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


## 绝对路径是否落在工程目录内。
static func is_in_project(abs_path: String) -> bool:
	var root := ProjectSettings.globalize_path("res://")
	if root.ends_with("/") or root.ends_with("\\"):
		root = root.substr(0, root.length() - 1)
	return abs_path.to_lower().begins_with(root.to_lower())


## 绝对路径 → res:// 路径（工程外返回空串）。
static func to_res_path(abs_path: String) -> String:
	if is_in_project(abs_path):
		return ProjectSettings.localize_path(abs_path)
	return ""


# ---------------------------------------------------------------- 二进制解析

static func _parse_binary(info: Dictionary, b: PackedByteArray) -> void:
	var out := {
		"magic": "RSRC",
		"big_endian": false,
		"use_real64": false,
		"format_version": "",
		"type": "",
		"header_tail_offset": 0,
		"header_tail": PackedByteArray(),
		"header_unknown_len": 0,
		"flags_guess": -1,
		"uid": "无",
		"script_class": "",
		"string_table_offset": -1,
		"strings": PackedStringArray(),
		"external": [],
		"internal": [],
		"data_offset": -1,
	}
	info["binary"] = out

	if b.size() < 32:
		info["error"] = "文件过短（%d 字节），不是完整的 RSRC 资源" % b.size()
		return

	var be := _rd32(b, 4, false) != 0
	out["big_endian"] = be
	out["use_real64"] = _rd32(b, 8, be) != 0
	out["format_version"] = "%d.%d.%d" % [_rd32(b, 12, be), _rd32(b, 16, be), _rd32(b, 20, be)]

	var type_len := _rd32(b, 24, be)
	if type_len <= 0 or 28 + type_len > b.size():
		info["error"] = "类型名长度非法（%d）" % type_len
		return
	out["type"] = b.slice(28, 28 + type_len - 1).get_string_from_utf8()

	var pos := 28 + type_len
	if pos + 20 > b.size():
		info["error"] = "头部截断（需要 20 字节，剩余 %d）" % (b.size() - pos)
		return

	var h_a := _rd32(b, pos, be)
	var h_b := _rd32(b, pos + 4, be)
	var flags := _rd32(b, pos + 8, be)
	var uid := _rd64(b, pos + 12, be)
	out["flags_guess"] = flags
	out["uid"] = "无" if uid == -1 else "0x%016X" % uid
	# h_a / h_b 在 4.7.2 恒为 0，含义未确认，仅在有值时报出来
	if h_a != 0 or h_b != 0:
		_warn(info, "头部字段 A=%d B=%d（含义未确认）" % [h_a, h_b])

	pos += 20
	var pr := _pstr(b, pos, be)
	if pr[0] < 0:
		info["error"] = "script_class 字符串解析失败（偏移 %d）" % pos
		return
	out["script_class"] = pr[1]
	pos = pr[0]

	# ---- 定位资源表：带不变量校验的扫描 ----
	var limit := mini(b.size() - 16, pos + TABLE_SCAN_WINDOW)
	var tables := {}
	var table_off := -1
	for cand in range(pos, limit):
		var r := _try_tables(b, cand, be)
		if not r.is_empty():
			tables = r
			table_off = cand
			break

	if table_off < 0:
		info["error"] = "找不到资源表（字符串表 / 依赖表 / 子资源表），可能不是引擎写出的标准 RSRC"
		out["header_tail_offset"] = pos
		out["header_tail"] = b.slice(pos, mini(pos + 48, b.size()))
		out["header_unknown_len"] = 48
		return

	out["string_table_offset"] = table_off
	out["header_tail_offset"] = pos
	var tail_len := table_off - pos
	out["header_unknown_len"] = tail_len
	out["header_tail"] = b.slice(pos, mini(pos + 48, b.size()))
	out["strings"] = tables["strings"]
	out["external"] = tables["external"]
	out["internal"] = tables["internal"]
	out["data_offset"] = tables["data_offset"]

	if tail_len != RESERVED_HEADER_HINT:
		info["confidence"] = "partial"
		_warn(info, "头部保留区为 %d 字节（4.7.2 预期 %d），可能来自其它引擎版本" % [tail_len, RESERVED_HEADER_HINT])
	else:
		info["confidence"] = "exact"

	info["ok"] = true
	# 依赖 / 子资源做一次轻量健康检查
	if int(out["data_offset"]) > b.size():
		_warn(info, "数据起点 %d 超出文件大小 %d" % [int(out["data_offset"]), b.size()])


## 尝试在 cand 处解析 字符串表 + 外部依赖表 + 内部子资源表；失败返回 {}。
## 校验：所有字符串可解码；内部表第一项偏移必须等于表结束位置（引擎写出时成立）。
static func _try_tables(b: PackedByteArray, cand: int, be: bool) -> Dictionary:
	var n := _rd32(b, cand, be)
	if n <= 0 or n > MAX_ENTRIES:
		return {}
	var pos := cand + 4
	var strings := PackedStringArray()
	for _i in range(n):
		var pr := _pstr(b, pos, be)
		if pr[0] < 0:
			return {}
		strings.append(pr[1])
		pos = pr[0]

	if pos + 4 > b.size():
		return {}
	var ec := _rd32(b, pos, be)
	if ec < 0 or ec > MAX_ENTRIES:
		return {}
	pos += 4
	var ext: Array = []
	for _i in range(ec):
		var t := _pstr(b, pos, be)
		if t[0] < 0:
			return {}
		pos = t[0]
		var p := _pstr(b, pos, be)
		if p[0] < 0:
			return {}
		pos = p[0]
		if pos + 8 > b.size():
			return {}
		var u := _rd64(b, pos, be)
		pos += 8
		ext.append({
			"index": ext.size(),
			"type": t[1],
			"path": p[1],
			"uid": "无" if u == -1 else "0x%016X" % u,
		})

	if pos + 4 > b.size():
		return {}
	var ic := _rd32(b, pos, be)
	if ic < 0 or ic > MAX_ENTRIES:
		return {}
	pos += 4
	var ints: Array = []
	for _i in range(ic):
		var p := _pstr(b, pos, be)
		if p[0] < 0:
			return {}
		pos = p[0]
		if pos + 8 > b.size():
			return {}
		var off := _rd64(b, pos, be)
		pos += 8
		if off < 0 or off > b.size():
			return {}
		ints.append({"index": ints.size(), "path": p[1], "offset": off})

	if pos > b.size():
		return {}
	# 关键不变量：第一项内部资源的数据偏移 == 表结束位置
	if ints.size() > 0 and int(ints[0]["offset"]) != pos:
		return {}

	return {
		"strings": strings,
		"external": ext,
		"internal": ints,
		"data_offset": pos,
	}


# ---------------------------------------------------------------- 文本解析

static func _looks_like_text(b: PackedByteArray) -> bool:
	var head := b.slice(0, mini(256, b.size())).get_string_from_utf8()
	if head.begins_with("\ufeff"):
		head = head.substr(1)
	var stripped := head.lstrip(" \t\r\n")
	return stripped.begins_with("[gd_resource") or stripped.begins_with("[gd_scene")


static func _parse_text(info: Dictionary, b: PackedByteArray) -> void:
	var out := {
		"header_tag": "",
		"type": "",
		"script_class": "",
		"uid": "",
		"load_steps": 0,
		"format": 0,
		"external": [],
		"sub_resources": [],
		"root_properties": 0,
		"line_count": 0,
	}
	info["text"] = out
	info["ok"] = true
	info["confidence"] = "exact"

	var text := b.get_string_from_utf8()
	if text.begins_with("\ufeff"):
		text = text.substr(1)
	var lines := text.split("\n")
	out["line_count"] = lines.size()

	var in_root := false
	var cur_sub: Dictionary = {}
	for raw_line in lines:
		var s := raw_line.strip_edges()
		if s == "" or s.begins_with(";"):
			continue
		if s.begins_with("[gd_resource") or s.begins_with("[gd_scene"):
			out["header_tag"] = "gd_resource" if s.begins_with("[gd_resource") else "gd_scene"
			out["type"] = _attr(s, "type")
			out["script_class"] = _attr(s, "script_class")
			out["uid"] = _attr(s, "uid")
			out["load_steps"] = int(_attr(s, "load_steps"))
			out["format"] = int(_attr(s, "format"))
			in_root = true
			cur_sub = {}
			continue
		if s.begins_with("[ext_resource"):
			out["external"].append({
				"id": _attr(s, "id"),
				"type": _attr(s, "type"),
				"path": _attr(s, "path"),
				"uid": _attr(s, "uid"),
			})
			continue
		if s.begins_with("[sub_resource"):
			cur_sub = {"id": _attr(s, "id"), "type": _attr(s, "type"), "properties": 0}
			out["sub_resources"].append(cur_sub)
			in_root = false
			continue
		# `[resource]` 是**根资源自己的属性区**（.tres 一定有），不是「未知段」
		if s == "[resource]" or s.begins_with("[resource "):
			in_root = true
			cur_sub = {}
			continue
		if s.begins_with("["):
			# .tscn 的 [node ...] / 其它未知段：不计入根属性
			cur_sub = {}
			in_root = false
			continue
		if s.contains("="):
			if not cur_sub.is_empty():
				cur_sub["properties"] = int(cur_sub["properties"]) + 1
			elif in_root:
				out["root_properties"] = int(out["root_properties"]) + 1


## 从 `[xxx key="value" ...]` / `[xxx key=3 ...]` 里取属性值（兼容带引号与不带引号）。
static func _attr(line: String, key: String) -> String:
	var needle := key + "="
	var from := 0
	while true:
		var i := line.find(needle, from)
		if i < 0:
			return ""
		var before := line[i - 1] if i > 0 else "["
		if before == " " or before == "\t" or before == "[":
			var start := i + needle.length()
			if start >= line.length():
				return ""
			if line[start] == "\"":
				var endq := line.find("\"", start + 1)
				if endq < 0:
					return ""
				return line.substr(start + 1, endq - start - 1)
			var stop := start
			while stop < line.length() and line[stop] != " " and line[stop] != "]":
				stop += 1
			return line.substr(start, stop - start)
		from = i + 1
	return ""


# ---------------------------------------------------------------- 载入

static func _load_resource(info: Dictionary, abs_path: String) -> void:
	if not bool(info.get("in_project", false)):
		info["load_error"] = "工程外文件：不会调用 ResourceLoader（仅结构解析）"
		return
	var res_path := to_res_path(abs_path)
	if res_path == "":
		info["load_error"] = "无法转换为 res:// 路径"
		return
	# 先问 exists()：直接 load 未知后缀会让引擎往控制台打 "No loader found for resource"
	if not ResourceLoader.exists(res_path):
		info["load_error"] = "ResourceLoader 不认识该路径（不是资源文件，或类型无对应加载器）"
		return
	var res: Resource = ResourceLoader.load(res_path, "", ResourceLoader.CACHE_MODE_REUSE)
	if res == null:
		info["load_error"] = "载入返回空（文件损坏、脚本缺失或资源类型未注册）"
		return
	info["resource"] = res
	info["resource_class"] = res.get_class()
	var scr := res.get_script()
	if scr is Script:
		info["resource_script"] = String((scr as Script).resource_path)
	if not bool(info.get("ok", false)) and str(info.get("error", "")) == "":
		info["ok"] = true


## 追加一条警告（PackedStringArray 是值类型，必须取出→追加→写回）。
static func _warn(info: Dictionary, msg: String) -> void:
	var w: PackedStringArray = info.get("warnings", PackedStringArray())
	w.append(msg)
	info["warnings"] = w


# ---------------------------------------------------------------- 字节工具

## 读 u32；be=true 时按大端解释。
static func _rd32(b: PackedByteArray, offset: int, be: bool) -> int:
	if offset < 0 or offset + 4 > b.size():
		return 0
	var v := b.decode_u32(offset)
	if not be:
		return v
	return ((v & 0xFF) << 24) | ((v & 0xFF00) << 8) | ((v >> 8) & 0xFF00) | ((v >> 24) & 0xFF)


## 读 u64（用两个 u32 拼，避免依赖不存在的 decode_u64）。
static func _rd64(b: PackedByteArray, offset: int, be: bool) -> int:
	if be:
		var hi := _rd32(b, offset, true)
		var lo := _rd32(b, offset + 4, true)
		return (hi << 32) | (lo & 0xFFFFFFFF)
	var lo2 := _rd32(b, offset, false)
	var hi2 := _rd32(b, offset + 4, false)
	return (hi2 << 32) | (lo2 & 0xFFFFFFFF)


## 读 pascal 字符串：返回 [下一个偏移, 字符串]；失败返回 [-1, ""]。
static func _pstr(b: PackedByteArray, offset: int, be: bool) -> Array:
	if offset < 0 or offset + 4 > b.size():
		return [-1, ""]
	var ln := _rd32(b, offset, be)
	if ln == 0:
		return [offset + 4, ""]
	if ln < 0 or ln > 65536 or offset + 4 + ln > b.size():
		return [-1, ""]
	var raw := b.slice(offset + 4, offset + 4 + ln)
	if raw[raw.size() - 1] != 0:
		return [-1, ""]
	var body := raw.slice(0, raw.size() - 1)
	for c in body:
		if c < 9:
			return [-1, ""]
	var s := body.get_string_from_utf8()
	if s == "" and body.size() > 0:
		return [-1, ""]
	return [offset + 4 + ln, s]


static func _hex_preview(b: PackedByteArray) -> String:
	var parts: PackedStringArray = []
	for i in range(mini(b.size(), 16)):
		parts.append("%02X" % b[i])
	return " ".join(parts)


static func _file_size(abs_path: String) -> int:
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)


static func _format_label(fmt: String) -> String:
	match fmt:
		"binary":
			return "二进制（RSRC）"
		"text":
			return "文本（.tres/.tscn）"
		_:
			return "未知"


static func _flags_text(flags: int) -> String:
	if flags < 0:
		return "未知"
	var bits: PackedStringArray = []
	for i in range(16):
		if (flags & (1 << i)) != 0:
			bits.append("bit%d" % i)
	return "%d（0b%s，%s）" % [flags, _bin(flags), ", ".join(bits) if bits.size() > 0 else "无置位"]


static func _bin(v: int) -> String:
	if v == 0:
		return "0"
	var s := ""
	var n := v
	while n > 0:
		s = str(n & 1) + s
		n = n >> 1
	return s

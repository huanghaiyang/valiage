@tool
extends VBoxContainer
## 摘要页：文件信息 / 头部格式 / 载入状态 / 类型专属规格 / 告警。
## 布局为两列 GridContainer（底部面板整宽，横向舒展）。

const UIKit := preload("res://addons/res_inspector/ui/ui_kit.gd")
const FmtUtil := preload("res://addons/res_inspector/ui/fmt_util.gd")
const ResStats := preload("res://addons/res_inspector/ui/res_stats.gd")

var _built := false
var _fmt = null
var _info: Dictionary = {}
var _unavailable := ""

var _body: VBoxContainer = null
var _file_grid: GridContainer = null
var _head_grid: GridContainer = null
var _load_grid: GridContainer = null
var _spec_title: Label = null
var _spec_grid: GridContainer = null
var _warn_box: VBoxContainer = null


func _ready() -> void:
	_ensure_built()


## 外部（ResInspectorDock）入口：传解析结果 + 解析模块引用
func set_info(info: Dictionary, fmt) -> void:
	_fmt = fmt
	_info = info if info is Dictionary else {}
	_unavailable = ""
	_rebuild()


## 解析模块不存在时：界面停留在可用状态，只显示原因
func set_unavailable(reason: String) -> void:
	_fmt = null
	_info = {}
	_unavailable = reason
	_rebuild()


func _ensure_built() -> void:
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 关掉横向滚动：这样值标签才能按面板宽度正确折行
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 6)
	scroll.add_child(_body)

	_body.add_child(UIKit.title("文件信息"))
	_file_grid = UIKit.grid(2)
	_body.add_child(_file_grid)
	_body.add_child(UIKit.separator())

	_body.add_child(UIKit.title("头部 / 格式"))
	_head_grid = UIKit.grid(2)
	_body.add_child(_head_grid)
	_body.add_child(UIKit.separator())

	_body.add_child(UIKit.title("载入状态"))
	_load_grid = UIKit.grid(2)
	_body.add_child(_load_grid)
	_body.add_child(UIKit.separator())

	_spec_title = UIKit.title("类型规格")
	_body.add_child(_spec_title)
	_spec_grid = UIKit.grid(2)
	_body.add_child(_spec_grid)
	_body.add_child(UIKit.separator())

	_body.add_child(UIKit.title("提示与告警"))
	_warn_box = VBoxContainer.new()
	_warn_box.add_theme_constant_override("separation", 2)
	_body.add_child(_warn_box)


func _rebuild() -> void:
	_ensure_built()
	UIKit.clear_children(_file_grid)
	UIKit.clear_children(_head_grid)
	UIKit.clear_children(_load_grid)
	UIKit.clear_children(_spec_grid)
	UIKit.clear_children(_warn_box)

	if _info.is_empty():
		var why := _unavailable if _unavailable != "" else "尚未打开文件（用工具栏「打开…」，或从 FileSystem 拖入 .res / .tres）"
		UIKit.add_row(_file_grid, "状态", why, UIKit.DIM if _unavailable == "" else UIKit.WARN)
		UIKit.add_hint_row(_head_grid, "—")
		UIKit.add_hint_row(_load_grid, "—")
		UIKit.add_hint_row(_spec_grid, "—")
		_warn_box.add_child(UIKit.hint("—"))
		return

	_fill_file_rows()
	_fill_head_rows()
	_fill_load_rows()
	_fill_spec_rows()
	_fill_warnings()


func _fill_file_rows() -> void:
	var exists := bool(_info.get("exists", false))
	var path_text := str(_info.get("path", ""))
	var abs_text := str(_info.get("abs_path", ""))
	UIKit.add_row(_file_grid, "路径", path_text if path_text != "" else "（空）")
	UIKit.add_row(_file_grid, "绝对路径", abs_text if abs_text != "" else "—")
	UIKit.add_row(_file_grid, "项目内资源", "是" if bool(_info.get("in_project", false)) else "否")
	UIKit.add_row(_file_grid, "文件存在", "是" if exists else "否（文件不存在或不可读）",
			UIKit.GOOD if exists else UIKit.BAD)
	UIKit.add_row(_file_grid, "大小", "%s（%d 字节）" % [
			FmtUtil.human_size(_fmt, int(_info.get("size", 0))), int(_info.get("size", 0))])
	UIKit.add_row(_file_grid, "修改时间", _time_text(int(_info.get("mtime", 0))))
	UIKit.add_row(_file_grid, "容器格式", _format_text())
	UIKit.add_row(_file_grid, "判定置信度", str(_info.get("confidence", "")) if str(_info.get("confidence", "")) != "" else "—")
	if int(_info.get("elapsed_ms", 0)) > 0:
		UIKit.add_row(_file_grid, "解析耗时", "%d ms" % int(_info.get("elapsed_ms", 0)))


func _fill_head_rows() -> void:
	var fmt := str(_info.get("format", ""))
	if fmt == "binary":
		var b: Dictionary = _info.get("binary", {})
		if b.is_empty():
			UIKit.add_hint_row(_head_grid, "二进制头部信息缺失", UIKit.WARN)
			return
		UIKit.add_row(_head_grid, "魔数", str(b.get("magic", "RSRC")))
		UIKit.add_row(_head_grid, "字节序", "大端" if bool(b.get("big_endian", false)) else "小端")
		UIKit.add_row(_head_grid, "实数精度", "real64（64 位浮点）" if bool(b.get("use_real64", false)) else "real32（32 位浮点）")
		UIKit.add_row(_head_grid, "格式版本", str(b.get("format_version", "—")))
		UIKit.add_row(_head_grid, "资源类型", str(b.get("type", "")) if str(b.get("type", "")) != "" else "（未识别）")
		UIKit.add_row(_head_grid, "UID", str(b.get("uid", "无")))
		var flags := int(b.get("flags_guess", -1))
		UIKit.add_row(_head_grid, "flags 推测", "0x%08X" % flags if flags >= 0 else "未能识别（-1）",
				Color(1, 1, 1) if flags >= 0 else UIKit.WARN)
		var tail: PackedByteArray = b.get("header_tail", PackedByteArray())
		UIKit.add_row(_head_grid, "未识别头部尾部", "偏移 %d ｜ %s" % [
				int(b.get("header_tail_offset", 0)), _hex_preview(tail)])
		UIKit.add_row(_head_grid, "字符串表", "偏移 %d ｜ %d 条" % [
				int(b.get("string_table_offset", 0)), int(b.get("strings", PackedStringArray()).size())])
		UIKit.add_row(_head_grid, "外部依赖", "%d 项" % int(b.get("external", []).size()))
		UIKit.add_row(_head_grid, "内部子资源", "%d 项" % int(b.get("internal", []).size()))
		UIKit.add_row(_head_grid, "根属性数据偏移", "%d" % int(b.get("data_offset", 0)))
	elif fmt == "text":
		var t: Dictionary = _info.get("text", {})
		if t.is_empty():
			UIKit.add_hint_row(_head_grid, "文本头部信息缺失", UIKit.WARN)
			return
		UIKit.add_row(_head_grid, "头标签", str(t.get("header_tag", "")))
		UIKit.add_row(_head_grid, "声明类型", str(t.get("type", "")))
		UIKit.add_row(_head_grid, "脚本类", str(t.get("script_class", "")) if str(t.get("script_class", "")) != "" else "—")
		UIKit.add_row(_head_grid, "UID", str(t.get("uid", "无")))
		UIKit.add_row(_head_grid, "load_steps", str(t.get("load_steps", 0)))
		UIKit.add_row(_head_grid, "format 版本", str(t.get("format", 0)))
		UIKit.add_row(_head_grid, "外部依赖", "%d 项" % int(t.get("external", []).size()))
		UIKit.add_row(_head_grid, "子资源", "%d 项" % int(t.get("sub_resources", []).size()))
		UIKit.add_row(_head_grid, "根属性数", str(t.get("root_properties", 0)))
		UIKit.add_row(_head_grid, "行数", str(t.get("line_count", 0)))
	else:
		UIKit.add_hint_row(_head_grid, "未能判定容器格式（既不是 RSRC 二进制，也不是 gd_resource 文本）", UIKit.WARN)


func _fill_load_rows() -> void:
	var res: Resource = _info.get("resource", null)
	var cls := str(_info.get("resource_class", ""))
	var script := str(_info.get("resource_script", ""))
	var load_error := str(_info.get("load_error", ""))
	if res != null:
		UIKit.add_row(_load_grid, "资源对象", "已载入", UIKit.GOOD)
		UIKit.add_row(_load_grid, "引擎类", res.get_class())
	elif load_error != "":
		UIKit.add_row(_load_grid, "资源对象", "载入失败", UIKit.BAD)
		UIKit.add_row(_load_grid, "引擎类", cls if cls != "" else "—")
	else:
		UIKit.add_row(_load_grid, "资源对象", "未载入", UIKit.DIM)
		UIKit.add_row(_load_grid, "引擎类", cls if cls != "" else "—")
	UIKit.add_row(_load_grid, "资源类（解析结果）", cls if cls != "" else "—")
	UIKit.add_row(_load_grid, "附加脚本", script if script != "" else "无")
	if res != null:
		var rp := res.resource_path
		UIKit.add_row(_load_grid, "resource_path", rp if rp != "" else "（内嵌资源，无路径）")
		var rn := res.resource_name
		UIKit.add_row(_load_grid, "resource_name", rn if rn != "" else "（空）")
	if load_error != "":
		UIKit.add_row(_load_grid, "载入错误", load_error, UIKit.BAD)
	var err := str(_info.get("error", ""))
	if err != "":
		UIKit.add_row(_load_grid, "解析错误", err, UIKit.BAD)


func _fill_spec_rows() -> void:
	UIKit.clear_children(_spec_grid)
	var res: Resource = _info.get("resource", null)
	if res == null:
		_spec_title.text = "类型规格"
		var why := "资源对象未载入，无法给出类型规格"
		var load_error := str(_info.get("load_error", ""))
		if load_error != "":
			why += "（" + load_error + "）"
		UIKit.add_hint_row(_spec_grid, why, UIKit.DIM)
		return

	_spec_title.text = "类型规格 —— %s" % res.get_class()

	if res is Mesh:
		var st: Dictionary = ResStats.mesh_stats(res)
		var aabb: AABB = st["aabb"]
		UIKit.add_row(_spec_grid, "表面数", str(int(st["surfaces"])))
		UIKit.add_row(_spec_grid, "顶点数", _num(int(st["vertices"])))
		UIKit.add_row(_spec_grid, "三角形数", _num(int(st["triangles"])))
		UIKit.add_row(_spec_grid, "图元类型", str(st["primitive"]) if str(st["primitive"]) != "" else "—")
		UIKit.add_row(_spec_grid, "混合形状", str(int(st["blend_shapes"])))
		UIKit.add_row(_spec_grid, "AABB 位置", _vec3(aabb.position))
		UIKit.add_row(_spec_grid, "AABB 尺寸", _vec3(aabb.size))
		# ArrayMesh 可见的表面数组键，便于判断顶点数据是否还在
		if res is ArrayMesh:
			var keys := _surface_array_keys(res as ArrayMesh)
			if keys != "":
				UIKit.add_row(_spec_grid, "表面数组键", keys)
		return

	if res is Texture2D:
		var ts: Dictionary = ResStats.texture_stats(res)
		UIKit.add_row(_spec_grid, "尺寸", "%d × %d" % [int(ts["width"]), int(ts["height"])])
		UIKit.add_row(_spec_grid, "Mipmap", "有" if bool(ts["mipmaps"]) else "无")
		UIKit.add_row(_spec_grid, "显存估算", "≈ %s（按 RGBA8 粗算）" % FmtUtil.human_size(_fmt, int(ts["vram_bytes"])))
		if res is ImageTexture:
			var img: Image = (res as ImageTexture).get_image()
			if img != null:
				UIKit.add_row(_spec_grid, "图像格式", ResStats.image_format_name(img.get_format()))
		UIKit.add_row(_spec_grid, "资源尺寸上限", "可预览")
		return

	if res is Image:
		var is_: Dictionary = ResStats.image_stats(res)
		UIKit.add_row(_spec_grid, "尺寸", "%d × %d" % [int(is_["width"]), int(is_["height"])])
		UIKit.add_row(_spec_grid, "图像格式", str(is_["format"]))
		UIKit.add_row(_spec_grid, "Mipmap", "有" if bool(is_["mipmaps"]) else "无")
		UIKit.add_row(_spec_grid, "显存估算", "≈ %s（按 RGBA8 粗算）" % FmtUtil.human_size(_fmt, int(is_["vram_bytes"])))
		return

	if res is Gradient:
		var gs: Dictionary = ResStats.gradient_stats(res)
		UIKit.add_row(_spec_grid, "颜色数", str(int(gs["colors"])))
		UIKit.add_row(_spec_grid, "插值模式", str(gs["interpolation"]))
		var preview: Array = gs["preview"]
		if not preview.is_empty():
			UIKit.add_row(_spec_grid, "颜色预览", " ".join(PackedStringArray(preview)))
		return

	if res is Animation:
		var as_: Dictionary = ResStats.animation_stats(res)
		UIKit.add_row(_spec_grid, "时长", "%.3f 秒" % float(as_["length"]))
		UIKit.add_row(_spec_grid, "循环模式", str(as_["loop"]))
		UIKit.add_row(_spec_grid, "轨道数", _num(int(as_["tracks"])))
		return

	if res is AudioStream:
		var aus: Dictionary = ResStats.audio_stats(res)
		UIKit.add_row(_spec_grid, "时长", "%.3f 秒" % float(aus["length"]))
		if int(aus["mix_rate"]) > 0:
			UIKit.add_row(_spec_grid, "采样率", "%d Hz" % int(aus["mix_rate"]))
		if int(aus["channels"]) > 0:
			UIKit.add_row(_spec_grid, "声道", "%d（%s）" % [int(aus["channels"]), "立体声" if int(aus["channels"]) == 2 else "单声道"])
		UIKit.add_row(_spec_grid, "编码", str(aus["format"]) if str(aus["format"]) != "" else "—")
		return

	if res is Curve:
		var curve: Curve = res
		UIKit.add_row(_spec_grid, "控制点数", str(curve.point_count))
		UIKit.add_row(_spec_grid, "取值范围", "%.3f ~ %.3f" % [curve.min_value, curve.max_value])
		return

	if res is Shader:
		var code: String = (res as Shader).code
		var lines := code.split("\n").size()
		UIKit.add_row(_spec_grid, "着色器类型", "—")
		UIKit.add_row(_spec_grid, "代码长度", "%d 字符 ｜ %d 行" % [code.length(), lines])
		return

	# 其它类型：给出类型说明即可
	UIKit.add_hint_row(_spec_grid, "该类型（%s）没有专属规格卡片；可在「属性」页查看全部属性。" % res.get_class(), UIKit.DIM)


func _fill_warnings() -> void:
	var warnings: PackedStringArray = _info.get("warnings", PackedStringArray())
	if warnings == null or warnings.is_empty():
		_warn_box.add_child(UIKit.hint("无告警。", UIKit.DIM))
		return
	for w in warnings:
		_warn_box.add_child(UIKit.hint("• " + str(w), UIKit.WARN))


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

func _format_text() -> String:
	match str(_info.get("format", "")):
		"binary":
			return "二进制 RSRC"
		"text":
			return "文本格式（.tres / .tscn）"
		_:
			return "未知"


static func _time_text(unix: int) -> String:
	if unix <= 0:
		return "—"
	return Time.get_datetime_string_from_unix_time(unix, true)


static func _hex_preview(b: PackedByteArray) -> String:
	if b == null or b.is_empty():
		return "（无）"
	var lim: int = mini(b.size(), 24)
	var parts := PackedStringArray()
	for i in lim:
		parts.append("%02X" % b[i])
	var s := " ".join(parts)
	if b.size() > lim:
		s += " …（共 %d 字节）" % b.size()
	return s


static func _num(n: int) -> String:
	# 大数字加千分位，6 MB 网格的顶点数才看得清
	var s := str(absi(n))
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" if n < 0 else "") + out


static func _vec3(v: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]


## 取第一个表面的数组键（只读 ArrayMesh 已载入数据，不看字节）
static func _surface_array_keys(mesh: ArrayMesh) -> String:
	if mesh.get_surface_count() <= 0:
		return ""
	var arrays: Array = mesh.surface_get_arrays(0)
	if arrays.is_empty():
		return ""
	var names := {
		Mesh.ARRAY_VERTEX: "顶点", Mesh.ARRAY_NORMAL: "法线", Mesh.ARRAY_TANGENT: "切线",
		Mesh.ARRAY_COLOR: "颜色", Mesh.ARRAY_TEX_UV: "UV", Mesh.ARRAY_TEX_UV2: "UV2",
		Mesh.ARRAY_CUSTOM0: "自定义0", Mesh.ARRAY_CUSTOM1: "自定义1",
		Mesh.ARRAY_CUSTOM2: "自定义2", Mesh.ARRAY_CUSTOM3: "自定义3",
		Mesh.ARRAY_BONES: "骨骼", Mesh.ARRAY_WEIGHTS: "权重", Mesh.ARRAY_INDEX: "索引",
	}
	var parts := PackedStringArray()
	for i in arrays.size():
		if arrays[i] == null:
			continue
		parts.append(str(names.get(i, "槽%d" % i)))
	return "、".join(parts)

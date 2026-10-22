@tool
extends VBoxContainer
## 预览页：按资源类型给卡片。
## 纹理 → 缩略图 + 尺寸/格式/显存估算；网格 → 表面/顶点/三角形/AABB + 2D 线框；
## 动画 → 时长/循环/轨道表；音频 → 时长/采样率/声道；其余类型给类型说明卡片。

const UIKit := preload("res://addons/res_inspector/ui/ui_kit.gd")
const FmtUtil := preload("res://addons/res_inspector/ui/fmt_util.gd")
const ResStats := preload("res://addons/res_inspector/ui/res_stats.gd")
const MeshWireView := preload("res://addons/res_inspector/ui/mesh_wire_view.gd")

## 超过这个像素数的图像不生成缩略图（避免一次性解码巨大纹理）
const MAX_THUMB_PIXELS := 4096 * 4096
## 动画轨道表最多列多少行
const MAX_TRACK_ROWS := 400

var _built := false
var _fmt = null
var _info: Dictionary = {}
var _unavailable := ""
var _body: VBoxContainer = null
var _wire: Control = null


func _ready() -> void:
	_ensure_built()


func set_info(info: Dictionary, fmt) -> void:
	_fmt = fmt
	_info = info if info is Dictionary else {}
	_unavailable = ""
	_rebuild()


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
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	scroll.add_child(_body)


func _rebuild() -> void:
	_ensure_built()
	UIKit.clear_children(_body)
	_wire = null

	if _info.is_empty():
		var card := _add_card("预览")
		var why := _unavailable if _unavailable != "" else "尚未打开文件。"
		card.add_child(UIKit.hint(why, UIKit.WARN if _unavailable != "" else UIKit.DIM))
		return

	var res: Resource = _info.get("resource", null)
	if res == null:
		var card := _add_card("无法预览")
		var reason := str(_info.get("load_error", ""))
		if reason == "":
			reason = str(_info.get("error", ""))
		if reason == "":
			reason = "资源对象未载入（可能是二进制头部无法识别，或资源依赖缺失）。"
		card.add_child(UIKit.hint(reason, UIKit.BAD))
		card.add_child(UIKit.hint("「摘要」「结构」「原始」页仍然可用。", UIKit.DIM))
		return

	if res is Texture2D:
		_build_texture(res as Texture2D)
	elif res is Image:
		_build_image(res as Image)
	elif res is Mesh:
		_build_mesh(res as Mesh)
	elif res is Animation:
		_build_animation(res as Animation)
	elif res is AudioStream:
		_build_audio(res as AudioStream)
	elif res is Gradient:
		_build_gradient(res as Gradient)
	else:
		_build_generic(res)


## 卡片：带标题的面板容器，返回里面可放内容的 VBox
func _add_card(title_text: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 6)
	margin.add_child(body)
	body.add_child(UIKit.title(title_text))
	_body.add_child(panel)
	return body


func _build_texture(tex: Texture2D) -> void:
	var body := _add_card("纹理预览")
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 12)
	body.add_child(hbox)

	var tr := TextureRect.new()
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = Vector2(320, 220)
	tr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tr.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(tr)

	var grid := UIKit.grid(2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var st: Dictionary = ResStats.texture_stats(tex)
	UIKit.add_row(grid, "纹理类", tex.get_class())
	UIKit.add_row(grid, "尺寸", "%d × %d 像素" % [int(st["width"]), int(st["height"])])
	UIKit.add_row(grid, "Mipmap", "有" if bool(st["mipmaps"]) else "无")
	UIKit.add_row(grid, "显存估算", "≈ %s" % FmtUtil.human_size(_fmt, int(st["vram_bytes"])))
	if tex is ImageTexture:
		var img: Image = (tex as ImageTexture).get_image()
		if img != null:
			UIKit.add_row(grid, "图像格式", ResStats.image_format_name(img.get_format()))
	hbox.add_child(grid)


func _build_image(img: Image) -> void:
	var body := _add_card("图像预览")
	var st: Dictionary = ResStats.image_stats(img)
	var pixels: int = int(st["width"]) * int(st["height"])

	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 12)
	body.add_child(hbox)

	if pixels > 0 and pixels <= MAX_THUMB_PIXELS:
		var tr := TextureRect.new()
		tr.texture = ImageTexture.create_from_image(img)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.custom_minimum_size = Vector2(320, 220)
		tr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tr.size_flags_vertical = Control.SIZE_EXPAND_FILL
		hbox.add_child(tr)
	else:
		body.add_child(UIKit.hint("图像过大（%d 像素），不生成缩略图。" % pixels, UIKit.WARN))

	var grid := UIKit.grid(2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIKit.add_row(grid, "尺寸", "%d × %d 像素" % [int(st["width"]), int(st["height"])])
	UIKit.add_row(grid, "图像格式", str(st["format"]))
	UIKit.add_row(grid, "Mipmap", "有" if bool(st["mipmaps"]) else "无")
	UIKit.add_row(grid, "显存估算", "≈ %s" % FmtUtil.human_size(_fmt, int(st["vram_bytes"])))
	hbox.add_child(grid)


func _build_mesh(mesh: Mesh) -> void:
	var body := _add_card("网格预览（X/Y 正交线框）")
	var st: Dictionary = ResStats.mesh_stats(mesh)
	var aabb: AABB = st["aabb"]

	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 12)
	body.add_child(hbox)

	var wire := MeshWireView.new()
	wire.custom_minimum_size = Vector2(380, 300)
	wire.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wire.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.add_child(wire)
	wire.set_mesh(mesh)
	_wire = wire

	var grid := UIKit.grid(2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIKit.add_row(grid, "网格类", mesh.get_class())
	UIKit.add_row(grid, "表面数", str(int(st["surfaces"])))
	UIKit.add_row(grid, "顶点数", _num(int(st["vertices"])))
	UIKit.add_row(grid, "三角形数", _num(int(st["triangles"])))
	UIKit.add_row(grid, "图元类型", str(st["primitive"]) if str(st["primitive"]) != "" else "—")
	UIKit.add_row(grid, "AABB 位置", _vec3(aabb.position))
	UIKit.add_row(grid, "AABB 尺寸", _vec3(aabb.size))
	UIKit.add_row(grid, "线框边数", _num(int(wire.get_edge_count())))
	hbox.add_child(grid)

	var note: String = wire.get_note()
	if note != "":
		body.add_child(UIKit.hint(note, UIKit.WARN))


func _build_animation(anim: Animation) -> void:
	var body := _add_card("动画预览")
	var st: Dictionary = ResStats.animation_stats(anim)
	var grid := UIKit.grid(2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIKit.add_row(grid, "时长", "%.3f 秒" % float(st["length"]))
	UIKit.add_row(grid, "循环模式", str(st["loop"]))
	UIKit.add_row(grid, "轨道数", _num(int(st["tracks"])))
	body.add_child(grid)

	var tree := Tree.new()
	tree.columns = 3
	tree.set_column_title(0, "轨道")
	tree.set_column_title(1, "类型")
	tree.set_column_title(2, "关键帧")
	tree.column_titles_visible = true
	tree.hide_root = true
	tree.select_mode = Tree.SELECT_ROW
	tree.custom_minimum_size = Vector2(0, 240)
	tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(tree)

	var root := tree.create_item()
	var rows: Array = st["track_rows"]
	for r in rows:
		if not (r is Dictionary):
			continue
		var it := tree.create_item(root)
		it.set_text(0, "#%d %s" % [int(r.get("index", 0)), str(r.get("path", ""))])
		it.set_text(1, str(r.get("type", "")))
		it.set_text(2, str(int(r.get("keys", 0))))
	if int(st["tracks"]) > rows.size():
		var more := tree.create_item(root)
		more.set_text(0, "…")
		more.set_text(2, "共 %d 条轨道，仅显示前 %d 条" % [int(st["tracks"]), rows.size()])
		more.set_custom_color(0, UIKit.DIM)


func _build_audio(stream: AudioStream) -> void:
	var body := _add_card("音频预览")
	var st: Dictionary = ResStats.audio_stats(stream)
	var grid := UIKit.grid(2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIKit.add_row(grid, "音频类", stream.get_class())
	UIKit.add_row(grid, "时长", "%.3f 秒" % float(st["length"]))
	if int(st["mix_rate"]) > 0:
		UIKit.add_row(grid, "采样率", "%d Hz" % int(st["mix_rate"]))
	if int(st["channels"]) > 0:
		UIKit.add_row(grid, "声道", "%d（%s）" % [int(st["channels"]), "立体声" if int(st["channels"]) == 2 else "单声道"])
	UIKit.add_row(grid, "编码", str(st["format"]) if str(st["format"]) != "" else "—")
	body.add_child(grid)
	body.add_child(UIKit.hint("（不提供试听；时长与采样率来自已载入的音频流对象。）", UIKit.DIM))


func _build_gradient(g: Gradient) -> void:
	var body := _add_card("渐变预览")
	var st: Dictionary = ResStats.gradient_stats(g)
	var grid := UIKit.grid(2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIKit.add_row(grid, "颜色数", str(int(st["colors"])))
	UIKit.add_row(grid, "插值模式", str(st["interpolation"]))
	body.add_child(grid)

	var preview: Array = st["preview"]
	if preview.is_empty():
		body.add_child(UIKit.hint("该渐变没有颜色。", UIKit.DIM))
		return
	var strip := HBoxContainer.new()
	strip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	strip.custom_minimum_size = Vector2(0, 44)
	strip.add_theme_constant_override("separation", 0)
	body.add_child(strip)
	for hex in preview:
		var c := Color.from_string(str(hex), Color.WHITE)
		var cr := ColorRect.new()
		cr.color = c
		cr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cr.custom_minimum_size = Vector2(4, 40)
		cr.tooltip_text = str(hex)
		strip.add_child(cr)


func _build_generic(res: Resource) -> void:
	var body := _add_card("类型说明")
	var grid := UIKit.grid(2)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIKit.add_row(grid, "引擎类", res.get_class())
	var rp := res.resource_path
	UIKit.add_row(grid, "资源路径", rp if rp != "" else "（内嵌资源，无路径）")
	var entries: Array = FmtUtil.property_entries(_fmt, res, "")
	UIKit.add_row(grid, "可见属性", "%d 项" % entries.size())
	body.add_child(grid)
	body.add_child(UIKit.hint("该类型暂无图形预览；属性值与结构可在「属性」「结构」页查看。", UIKit.DIM))


# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------

static func _num(n: int) -> String:
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

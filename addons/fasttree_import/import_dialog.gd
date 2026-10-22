@tool
extends ConfirmationDialog
## fast-tree 一键烘烤 · 选项弹窗
##
## 由 filesystem_menu.gd 调 `ImportDialog.open(glbs)` 创建；关闭即销毁（改插件代码后重开生效）。
## 真正的转换逻辑在 addons/fasttree_import/convert.gd（与命令行共用）。

const Convert := preload("res://addons/fasttree_import/convert.gd")

const SCRIPT_PATH := "res://addons/fasttree_import/import_dialog.gd"

var _glbs := PackedStringArray()
var _running := false

var _name_edit: LineEdit = null
var _collision: OptionButton = null
var _overwrite: CheckBox = null
var _open_scene: CheckBox = null
var _target: Label = null
var _status: Label = null


static func open(glbs: PackedStringArray) -> void:
	if glbs.is_empty():
		return
	# 每次从磁盘重读脚本（CACHE_MODE_IGNORE）：改完插件代码关掉重开就生效，不必重启编辑器
	var script: GDScript = ResourceLoader.load(SCRIPT_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null or not script.can_instantiate():
		push_error("[fast-tree 烘烤] 无法加载 %s" % SCRIPT_PATH)
		return
	var base := EditorInterface.get_base_control()
	if base == null:
		push_error("[fast-tree 烘烤] 拿不到编辑器根控件")
		return
	var dlg: ConfirmationDialog = script.new()
	base.add_child(dlg)
	dlg._setup(glbs)
	dlg.popup_centered()


func _setup(glbs: PackedStringArray) -> void:
	_glbs = glbs
	title = "fast-tree 一键烘烤（%d 个 GLB）" % glbs.size()
	ok_button_text = "开始烘烤"
	cancel_button_text = "取消"
	min_size = Vector2i(580, 360)
	confirmed.connect(_on_confirmed)
	close_requested.connect(_on_closed)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 8)
	add_child(vb)

	var intro := Label.new()
	intro.text = "会把选中的 .glb 烘烤成：\n" \
			+ "  · 烘焙网格（含 CUSTOM0/1 风摆数据）→ assets/models/树/<名字>/wind/\n" \
			+ "  · 树着色器材质（bark / leaves / flowers）→ scenes/树/<名字>/\n" \
			+ "  · 可直接拖进场景的 .tscn（含树冠分块剔除）→ scenes/树/<名字>/"
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(intro)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 6)
	vb.add_child(grid)

	grid.add_child(_mk_label("资产名"))
	_name_edit = LineEdit.new()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if glbs.size() == 1:
		_name_edit.text = glbs[0].get_file().get_basename()
		_name_edit.tooltip_text = "默认 = GLB 文件名；决定目录名与场景根节点名"
		_name_edit.text_changed.connect(_refresh_target)
	else:
		_name_edit.placeholder_text = "多个 GLB：各自用文件名"
		_name_edit.editable = false
	grid.add_child(_name_edit)

	grid.add_child(_mk_label("碰撞"))
	_collision = OptionButton.new()
	_collision.add_item("不生成（推荐，进场景后自己配）", 0)
	_collision.add_item("凸包（每个树皮网格一个，轻量）", 1)
	_collision.add_item("三角网（精确但面数大）", 2)
	_collision.select(0)
	grid.add_child(_collision)

	grid.add_child(_mk_label(""))
	_overwrite = CheckBox.new()
	_overwrite.text = "覆盖已存在的场景/材质（重烤时勾选）"
	_overwrite.button_pressed = false
	grid.add_child(_overwrite)

	grid.add_child(_mk_label(""))
	_open_scene = CheckBox.new()
	_open_scene.text = "完成后打开生成的场景"
	_open_scene.button_pressed = true
	grid.add_child(_open_scene)

	_target = Label.new()
	_target.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_target.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	vb.add_child(_target)

	_status = Label.new()
	_status.text = "就绪。"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(0.85, 0.85, 0.6))
	vb.add_child(_status)

	_refresh_target()


func _mk_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


func _collision_id() -> String:
	match _collision.selected:
		1: return "convex"
		2: return "trimesh"
	return "none"


func _name_of(glb: String) -> String:
	if _glbs.size() == 1:
		var n := _name_edit.text.strip_edges()
		if n != "":
			return n
	return glb.get_file().get_basename()


func _refresh_target() -> void:
	if _target == null:
		return
	if _glbs.size() == 1:
		var n := _name_of(_glbs[0])
		_target.text = "输出：res://assets/models/树/%s/wind/  ｜  res://scenes/树/%s/" % [n, n]
	else:
		_target.text = "输出：每个 GLB 各一套（目录名 = 各自文件名）"


func _on_closed() -> void:
	# 中途关窗时把忙碌光标复位（否则编辑器光标会一直是"忙"）
	var base := EditorInterface.get_base_control()
	if base != null:
		base.mouse_default_cursor_shape = Control.CURSOR_ARROW
	queue_free()


func _on_confirmed() -> void:
	if _running:
		return
	_running = true
	get_ok_button().disabled = true
	get_cancel_button().disabled = true
	var base := EditorInterface.get_base_control()
	if base != null:
		base.mouse_default_cursor_shape = Control.CURSOR_BUSY
	var results: Array = []
	var total := _glbs.size()
	for i in range(total):
		var glb: String = _glbs[i]
		_status.text = "正在烘烤 %d/%d：%s …" % [i + 1, total, glb.get_file()]
		# 让状态先画出来，再进主线程的长时间烘焙
		await get_tree().process_frame
		await get_tree().process_frame
		if not is_inside_tree():
			# 用户在烘烤排队期间点了关闭：直接放弃，别对已释放的窗口操作
			return
		var opts := {
			"collision": _collision_id(),
			"force": _overwrite.button_pressed,
		}
		if total == 1:
			var nm := _name_edit.text.strip_edges()
			if nm != "":
				opts["name"] = nm
		var res: Dictionary = Convert.new().run(glb, opts)
		results.append({"glb": glb, "res": res})
	if not is_inside_tree():
		return
	if base != null:
		base.mouse_default_cursor_shape = Control.CURSOR_ARROW
	# 让新文件出现在文件系统面板
	EditorInterface.get_resource_filesystem().scan()
	_show_summary(results)
	# 完成后自动打开第一个成功生成的场景（可选）
	if _open_scene.button_pressed:
		for item in results:
			var r: Dictionary = item["res"]
			if bool(r.get("ok", false)) and String(r.get("scene", "")) != "":
				EditorInterface.open_scene_from_path(String(r["scene"]))
				break
	queue_free()


func _show_summary(results: Array) -> void:
	var ok_count := 0
	var lines: Array = []
	for item in results:
		var r: Dictionary = item["res"]
		var glb_name := String(item["glb"]).get_file()
		if bool(r.get("ok", false)):
			ok_count += 1
			lines.append("✓ %s → %s" % [glb_name, String(r.get("scene", ""))])
		else:
			lines.append("✗ %s：%s" % [glb_name, String(r.get("message", "未知错误"))])
	var dlg := AcceptDialog.new()
	dlg.title = "fast-tree 烘烤结果（%d/%d 成功）" % [ok_count, results.size()]
	dlg.dialog_text = "\n".join(lines)
	dlg.min_size = Vector2i(620, 220)
	dlg.confirmed.connect(dlg.queue_free)
	dlg.canceled.connect(dlg.queue_free)
	dlg.close_requested.connect(dlg.queue_free)
	var base := EditorInterface.get_base_control()
	if base != null:
		base.add_child(dlg)
	dlg.popup_centered()




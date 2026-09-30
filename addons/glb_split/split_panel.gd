@tool
extends VBoxContainer
## GLB split tool panel.
##
## Hard rules (never break these):
##   1. The source .glb is READ ONLY.
##   2. No scene is ever touched by this tool.
##
## Layout: left = split list (empty until separate) | middle = 3D preview | right = detect result
##
## All punctuation in code is ASCII on purpose. Decorative marks were removed:
## they caused real file corruption twice and they are not worth the risk.
##
## No lambdas anywhere: a multi-line lambda used as a call argument produced three
## different parse errors in this file, and the script cache hid it for a long time.

const SplitCoreScript := preload("res://addons/glb_split/split_core.gd")

const C_NAME := 0
const C_TRIS := 1
const C_SIZE := 2
const C_CENTER := 3
const BOX_SHADER_PATH := "res://addons/glb_split/cut_box.gdshader"

var source_path := ""

var _parts: Array = []
var _sel := {}
var _vp: SubViewport = null
var _cam: Camera3D = null
var _holder: Node3D = null
var _vp_box: SubViewportContainer = null
var _preview_nodes: Array = []
var _hl: StandardMaterial3D = null
var _tree_left: Tree = null
var _tree_right: Tree = null
var _status: Label = null
var _info: Label = null
var _btn_sel: Button = null
var _tex_chk: CheckBox = null
var _gltf_chk: CheckBox = null
var _res_chk: CheckBox = null
var _thread: Thread = null          # ★ 导出用的后台线程
var _export_job := {}
var _export_result := {}
var _ok_btn: Button = null
var _box_records: Array = []
var _cut_recs: Array = []
var _cut_dir := ""
var _dir_dlg: FileDialog = null
var _pending_export := {}
var _hl_boxes_mi: MeshInstance3D = null
var _hl_boxes: Array = []
var _edit_idx := -1
var _box_hist: Array = []
var _box_redo: Array = []
var _undo_btn: Button = null
var _redo_btn: Button = null
var _straight_btn: Button = null
var _cancel_btn: Button = null
var _new_btn: Button = null
var _left_menu: PopupMenu = null
var _menu_row := -1
var _loading: Label = null
var _busy := false
var _box_mi: MeshInstance3D = null
var _fill_mi: MeshInstance3D = null
var _ring_mi: MeshInstance3D = null
var _ring_drag := {}
var _box_mat: StandardMaterial3D = null
var _draw_mode := false
var _box_before_separate := {}
var _cut_box := {}
var _edges: Array = []
var _box_mats: Array = []
var _handles: Array = []
var _handle_drag := {}
var _overlay: Control = null
var _orbiting := false
var _box_data := {}
var _cam_dist := 4.0
var _pan := Vector3.ZERO
var _model_node: Node = null       # ★ 原始模型节点（用于"切完仍显示原模型"）
var _model_aabb := AABB()          # ★ 模型自身的 AABB（加载时算一次并缓存）
var _has_model_aabb := false
var _orbit := Vector2(0.35, -0.45)
var _drag_from := Vector2.ZERO
var _dragging := false


func _ready() -> void:
	name = "GLB 切割"
	add_theme_constant_override("separation", 6)

	_info = Label.new()
	_info.text = "当前模型：（请在文件系统里右键一个 .glb）"
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_info)

	# ★ 用 HFlowContainer（会自动换行）：按钮多了以后，HBoxContainer 在窄窗口里
	#   会把后面的控件**直接裁掉**（用户反馈：Godot 场景(.tscn) 在 UI 上看不到入口）
	var row := HFlowContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	var b_go := Button.new()
	b_go.text = "自动分离"
	b_go.tooltip_text = "把检测到的分块在预览里散开显示（不改原始文件，不改场景）"
	b_go.pressed.connect(auto_separate)
	row.add_child(b_go)

	var b_back := Button.new()
	b_back.text = "还原"
	b_back.tooltip_text = "回到上一次的框选状态，并重新显示整个模型"
	b_back.pressed.connect(revert_all)
	row.add_child(b_back)

	_new_btn = Button.new()
	_new_btn.text = "创建新的框选"
	_new_btn.tooltip_text = "进入框选编辑：在预览里按住左键拖出一个新框。已有框在编辑时不可用。"
	_new_btn.pressed.connect(create_new_box)
	row.add_child(_new_btn)

	_cancel_btn = Button.new()
	_cancel_btn.text = "取消框选"
	_cancel_btn.tooltip_text = "隐藏选择框，让画面干净。没有框时不可用。"
	_cancel_btn.pressed.connect(cancel_box)
	row.add_child(_cancel_btn)

	_ok_btn = Button.new()
	_ok_btn.text = "确定框选"
	_ok_btn.tooltip_text = "记录当前框选范围（新增一条框选记录）"
	_ok_btn.pressed.connect(confirm_box)
	row.add_child(_ok_btn)


	_tex_chk = CheckBox.new()
	_tex_chk.text = "带贴图"
	_tex_chk.tooltip_text = "勾上：每个分块的 glb 内嵌一份完整贴图（文件很大、导出很慢）；不勾：只保留颜色（文件小、快得多）"
	_tex_chk.button_pressed = false
	row.add_child(_tex_chk)

	_gltf_chk = CheckBox.new()
	_gltf_chk.text = "外部贴图(.gltf)"
	_gltf_chk.tooltip_text = "勾上：导出 .gltf + 共享的 textures/ 目录（贴图**只存一份**，9 个分块共用 -> 体积最小、最快）。不勾：导出单个 .glb（自带或不带贴图，看左边那个开关）"
	_gltf_chk.button_pressed = false
	row.add_child(_gltf_chk)

	_res_chk = CheckBox.new()
	_res_chk.text = "Godot 场景(.tscn)"
	_res_chk.tooltip_text = "勾上：导出 .res 网格 + .tscn 场景，材质**直接引用项目里已有的贴图** -> 拖进场景就是带贴图的，零手动指定、零额外体积（只在项目内用）。优先级高于右边两个开关。"
	_res_chk.button_pressed = false
	row.add_child(_res_chk)

	_btn_sel = Button.new()
	_btn_sel.text = "导出选中(0)"
	_btn_sel.pressed.connect(export_selected)
	row.add_child(_btn_sel)

	_straight_btn = Button.new()
	_straight_btn.text = "摆正框选"
	_straight_btn.tooltip_text = "把框的朝向恢复成世界 X/Y/Z 轴对齐。没有独立的框时置灰。"
	_straight_btn.pressed.connect(straighten_box)
	row.add_child(_straight_btn)

	_undo_btn = Button.new()
	_undo_btn.text = "撤销框操作"
	_undo_btn.tooltip_text = "撤销上一步框操作（改尺寸/旋转/平移/摆正）。快捷键 Ctrl+Z。框一出现，操作栈就是新的。"
	_undo_btn.pressed.connect(undo_box_op)
	row.add_child(_undo_btn)

	_redo_btn = Button.new()
	_redo_btn.text = "重做框操作"
	_redo_btn.tooltip_text = "重做刚撤销掉的框操作。快捷键 Ctrl+Shift+Z 或 Ctrl+Y。没有独立的框时置灰。"
	_redo_btn.pressed.connect(redo_box_op)
	row.add_child(_redo_btn)




	var cols := HSplitContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	cols.split_offset = 200
	add_child(cols)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(180, 0)
	cols.add_child(left)
	var ll := Label.new()
	ll.text = "框选记录（点行恢复；勾选=按此切割导出）"
	left.add_child(ll)
	_tree_left = Tree.new()
	_tree_left.columns = 4
	_tree_left.set_column_title(0, "选")
	_tree_left.set_column_title(1, "框选记录")
	_tree_left.set_column_title(2, "尺寸")
	_tree_left.set_column_title(3, "中心")
	_tree_left.hide_root = true
	_tree_left.column_titles_visible = true          # ★ 显示表头（用户要求）
	_tree_left.select_mode = Tree.SELECT_MULTI
	_tree_left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree_left.item_selected.connect(_on_left_selection_changed)
	_tree_left.multi_selected.connect(_on_left_multi_selected)
	_tree_left.item_mouse_selected.connect(_on_left_tree_mouse)
	_tree_left.item_edited.connect(_on_left_item_edited)
	# 列表行不要 hover/选中 的视觉反馈（用户要求）：点击只唤起框操作，不留高亮背景
	_plain_tree(_tree_left)
	_left_menu = PopupMenu.new()
	_left_menu.add_item("删除该框选记录", 0)
	_left_menu.id_pressed.connect(_on_left_menu_pressed)
	add_child(_left_menu)
	left.add_child(_tree_left)

	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(mid)
	_vp_box = SubViewportContainer.new()
	_vp_box.stretch = true
	_vp_box.custom_minimum_size = Vector2(0, 240)
	_vp_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_box.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_box.gui_input.connect(_on_preview_input)
	mid.add_child(_vp_box)

	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.msaa_3d = Viewport.MSAA_4X
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp_box.add_child(_vp)

	# 拖框时的橡皮筋矩形（Blender 框选就是这个观感）。
	# 放在 viewport 之后 -> 画在最上层；mouse_filter=IGNORE -> 不吃鼠标事件
	_overlay = Control.new()
	_overlay.set_script(load("res://addons/glb_split/box_overlay.gd"))
	_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_vp_box.add_child(_overlay)

	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.17, 0.19)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.76, 0.78, 0.82)
	env.ambient_light_energy = 1.1
	we.environment = env
	_vp.add_child(we)

	var dl := DirectionalLight3D.new()
	dl.rotation_degrees = Vector3(-48.0, -38.0, 0.0)
	dl.light_energy = 1.2
	_vp.add_child(dl)

	_holder = Node3D.new()
	_vp.add_child(_holder)

	_cam = Camera3D.new()
	_cam.fov = 45.0
	_vp.add_child(_cam)

	_hl = StandardMaterial3D.new()
	_hl.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hl.albedo_color = Color(1.0, 0.85, 0.2, 0.45)
	_hl.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hl.cull_mode = BaseMaterial3D.CULL_DISABLED

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(200, 0)
	cols.add_child(right)
	var rl := Label.new()
	rl.text = "切割块（点一下高亮；勾选=导出）"
	right.add_child(rl)

	_loading = Label.new()
	_loading.text = "处理中...请稍候"
	_loading.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_loading.visible = false
	right.add_child(_loading)

	_tree_right = Tree.new()
	_tree_right.columns = 3
	_tree_right.set_column_title(0, "选")
	_tree_right.set_column_title(1, "切割块")
	_tree_right.set_column_title(2, "三角")
	_tree_right.hide_root = true
	_tree_right.column_titles_visible = true         # ★ 显示表头（用户要求）
	_tree_right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree_right.item_selected.connect(_on_right_selected)
	_plain_tree(_tree_right)
	right.add_child(_tree_right)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "就绪"
	add_child(_status)

	set_process(false)          # _process 只在导出线程运行期间打开
	_update_btn()
	if source_path != "":
		apply_source()


func set_source(path: String) -> void:
	source_path = path
	if _info == null or _status == null:
		return
	apply_source()


func apply_source() -> void:
	_info.text = "当前模型：%s" % source_path.get_file()
	_status.text = "预览加载中..."
	revert_all()


func _clear_preview() -> void:
	if _holder == null:
		return
	for c in _holder.get_children():
		_holder.remove_child(c)
		c.queue_free()
	_preview_nodes.clear()
	_box_mi = null
	_model_node = null
	_edges.clear()
	_box_data = {}
	_clear_box_shader()
	_handles.clear()
	_handle_drag = {}
	_hl_boxes_mi = null
	_hl_boxes.clear()


## Load a .glb. Try load() first, else read the file directly with GLTFDocument
## (load() often returns nothing for glb files - same approach as the older glb_tools tool).
func _load_glb(path: String) -> Node:
	var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if packed is PackedScene:
		return (packed as PackedScene).instantiate()
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		_status.text = "预览加载失败：GLTFDocument append_from_file"
		return null
	return doc.generate_scene(st)


func _holder_aabb() -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [_holder]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D and (nd as MeshInstance3D).mesh != null:
			var mi := nd as MeshInstance3D
			if not _is_helper_node(mi.name):
				var a := mi.get_aabb()
				for i in range(8):
					var c: Vector3 = mi.global_transform * a.get_endpoint(i)
					if first:
						out = AABB(c, Vector3.ZERO)
						first = false
					else:
						out = out.expand(c)
		for ch in nd.get_children():
			stack.append(ch)
	return out


func _frame_preview() -> void:
	var aabb := _holder_aabb()
	if aabb.size.length() < 0.00001:
		aabb = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	var radius: float = maxf(aabb.size.length() * 0.5, 0.05)
	_cam_dist = radius / tan(deg_to_rad(_cam.fov * 0.5)) * 1.6
	_pan = Vector3.ZERO          # 重新取景时把视角平移归零
	_apply_orbit()


func _apply_orbit() -> void:
	if _cam == null:
		return
	var center := _holder_aabb().get_center() + _pan
	var dir := Vector3(
		cos(_orbit.y) * sin(_orbit.x),
		-sin(_orbit.y),
		cos(_orbit.y) * cos(_orbit.x))
	_cam.global_position = center + dir * _cam_dist
	_cam.look_at(center, Vector3.UP)
	# 手柄大小是按相机距离算的（屏幕 6px 恒定）-> 转视角/缩放/平移后必须重算
	# 上一版这里多加了 not _edges.is_empty() 条件，而 _edges 永远是空的
	#   -> 条件恒假 -> 缩放后手柄从不更新 -> 表现为"圆点随视野变大变小"
	if _box_data.has("origin"):
		_sync_handle_size_only()


## 还原：只显示整个模型，不跑检测（不点检测就不会卡）
func revert_all() -> void:
	_sel.clear()
	_parts = []
	if _tree_left != null:
		_tree_left.clear()
	_update_btn()
	if source_path == "":
		return
	_clear_preview()
	var node := _load_glb(source_path)
	if node == null:
		return
	_holder.add_child(node)
	_model_node = node
	_frame_preview()
	# ★ 关键：此刻 holder 里**只有模型**（线框/手柄/散开的分块都还没进来）
	#   -> 在这里把模型 AABB 算一次并缓存，之后默认框永远用它
	#   （否则自动分离之后再算，算到的是"散开范围"，框就变了 —— 用户问的正是这个）
	_model_aabb = _holder_aabb()
	_has_model_aabb = _model_aabb.size.length() > 0.00001
	# 还原到"上一次框选的状态"；没有记录过就退回默认的模型等大框
	if _box_before_separate.has("origin"):
		_box_data = _box_before_separate.duplicate(true)
		_sync_box_visuals()
		_status.text = "已还原到上一次的框选状态。"
	else:
		_default_box_from_model()
		_status.text = "已显示模型，并自动建好一个贴合模型的选择框。拖圆点改尺寸、拖彩环旋转、拖橙点平移。"
	_update_btn()          # ★ 框建好之后必须再同步一次，否则「确定框选」会一直置灰


func auto_separate() -> void:
	if source_path == "":
		_status.text = "还没有模型：请在文件系统里右键一个 .glb"
		return
	if _busy:
		return
	# ★ 记住当前框并**隐藏它**（用户要求：点自动分离就隐藏框选）
	if _box_data.has("origin"):
		_box_before_separate = _box_data.duplicate(true)
		_cut_box = _box_data.duplicate(true)
		_box_data = {}
		_hide_box()
	# 已经检测过、也没设框 -> 直接复用检测结果，秒开
	if not _box_data.has("origin") and not _parts.is_empty():
		_show_parts(_parts)
		_fill_right(_parts)
		_sel.clear()
		_apply_hl()
		_update_btn()
		_status.text = "已按检测结果散开（%d 块）。点选分块后可导出。" % _parts.size()
		return
	# 需要真切割（有框选，或还没检测过）-> 先出 loading，再动手
	_begin_busy("切割中...（约十几秒，界面会卡住）")
	_defer(Callable(self, "_run_separate"))


func _run_separate() -> void:
	if source_path == "":
		_end_busy()
		return
	var opts := {}
	if _cut_box.has("origin"):
		opts["box"] = _cut_box
	_cut_box = {}
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = SplitCoreScript.split(source_path, opts)
	_end_busy()
	if not bool(r.get("ok", false)):
		_status.text = "切割失败：%s" % str(r.get("message", ""))
		return
	_parts = r["parts"]
	_sel.clear()
	_show_parts(_parts)
	_fill_right(_parts)
	_apply_hl()
	_update_btn()
	_status.text = "%s，耗时 %d ms" % [str(r.get("message", "")), Time.get_ticks_msec() - t0]


## loading 状态：先设置好并让界面画出来，再跑会阻塞的切割。
func _begin_busy(msg: String) -> void:
	_busy = true
	if _loading != null:
		_loading.visible = true
		_loading.text = msg
	_status.text = msg


func _end_busy() -> void:
	_busy = false
	if _loading != null:
		_loading.visible = false


## 延迟一个短定时器再执行 Callable。不用 lambda：那个写法在本文件里会解析失败。
func _defer(cb: Callable) -> void:
	var base := EditorInterface.get_base_control()
	if base == null:
		cb.call()
		return
	base.get_tree().create_timer(0.2).timeout.connect(cb, CONNECT_ONE_SHOT)


func _show_parts(parts: Array) -> void:
	_clear_preview()
	if parts.is_empty():
		return
	var g := Vector3.ZERO
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	for p in parts:
		var c: Vector3 = (p as Dictionary)["center"]
		g += c
		mn = mn.min(c)
		mx = mx.max(c)
	g /= maxf(1.0, float(parts.size()))
	var spread: float = maxf((mx - mn).length() * 0.8, 0.3)
	for i in range(parts.size()):
		var d: Dictionary = parts[i]
		var mi := MeshInstance3D.new()
		mi.name = String(d.get("name", "part"))
		mi.mesh = d["mesh"]
		var c2: Vector3 = d["center"]
		var dir := c2 - g
		if dir.length() < 0.0001:
			dir = Vector3(1, 0, 0).rotated(Vector3.UP, TAU * i / maxf(1.0, float(parts.size())))
		mi.position = c2 + dir.normalized() * spread * (1.0 + 0.1 * i)
		_holder.add_child(mi)
		_preview_nodes.append(mi)
	_frame_preview()
	_restore_box()


func _pick_at(local: Vector2) -> int:
	var best := -1
	var bd := 42.0
	for i in range(_preview_nodes.size()):
		var mi: MeshInstance3D = _preview_nodes[i]
		var sp: Vector2 = _cam.unproject_position(mi.global_position)
		var d: float = sp.distance_to(local)
		if d < bd:
			bd = d
			best = i
	return best


func _toggle_sel(idx: int, additive: bool) -> void:
	if idx < 0:
		if not additive:
			_sel.clear()
	else:
		if additive:
			if bool(_sel.get(idx, false)):
				_sel.erase(idx)
			else:
				_sel[idx] = true
		else:
			if _sel.size() == 1 and bool(_sel.get(idx, false)):
				_sel.clear()
			else:
				_sel.clear()
				_sel[idx] = true
	_apply_hl()
	_update_btn()


func _apply_hl() -> void:
	for i in range(_preview_nodes.size()):
		var mi: MeshInstance3D = _preview_nodes[i]
		mi.material_overlay = _hl if bool(_sel.get(i, false)) else null


func _update_btn() -> void:
	if _btn_sel != null:
		# ★ 数字要反映"点下去会导出多少"，而不是只看预览里点选的分块
		#   （上一版用 _sel.size() ✗ -> 勾了框选记录却一直显示 0 ✗）
		_btn_sel.text = "导出选中(%d)" % _export_count()
	var has_box := _box_data.has("origin")
	if _ok_btn != null:
		# 没有框选范围时「确定框选」置灰不可用（用户要求）
		_ok_btn.disabled = not has_box
	# 没有**独立的框** -> 撤销/重做框操作都置灰（用户要求）；另外栈空也置灰
	if _undo_btn != null:
		_undo_btn.disabled = not has_box or _box_hist.is_empty()
	if _redo_btn != null:
		_redo_btn.disabled = not has_box or _box_redo.is_empty()
	# 摆正：只有存在**独立的框**时才可用（用户要求）
	if _straight_btn != null:
		_straight_btn.disabled = not has_box
	# 取消框选：没有框时置灰（用户要求）
	if _cancel_btn != null:
		_cancel_btn.disabled = not has_box
	# 创建新的框选：**已经有框在编辑时**置灰（用户要求）
	if _new_btn != null:
		_new_btn.disabled = has_box


## WASD **移动视角**（平移观察点），Shift 加速 4 倍；Q/E 升降；滚轮管远近。
## 只在**鼠标位于预览区域内**时响应 —— 否则会抢走编辑器里打字的 WASD 输入。
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed:
		return
	if _vp_box == null or _cam == null or not _vp_box.is_visible_in_tree():
		return
	# 生效条件：鼠标在预览里 **或** 本工具窗口有焦点
	#   （不加限制会抢走编辑器自己的 Ctrl+Z / WASD）
	var over_preview := _vp_box.get_global_rect().has_point(_vp_box.get_global_mouse_position())
	var win_focused := false
	var win := get_window()
	if win != null:
		win_focused = win.has_focus()
	if not (over_preview or win_focused):
		return
	# ★ 框操作撤销/重做快捷键：Ctrl+Z ｜ Ctrl+Shift+Z ｜ Ctrl+Y
	if k.ctrl_pressed and not k.alt_pressed:
		if k.keycode == KEY_Z and not k.shift_pressed:
			undo_box_op()
			get_viewport().set_input_as_handled()
			return
		if (k.keycode == KEY_Z and k.shift_pressed) or k.keycode == KEY_Y:
			redo_box_op()
			get_viewport().set_input_as_handled()
			return
	var dir := Vector3.ZERO
	match k.keycode:
		KEY_W:
			dir = -_cam.global_transform.basis.z
		KEY_S:
			dir = _cam.global_transform.basis.z
		KEY_A:
			dir = -_cam.global_transform.basis.x
		KEY_D:
			dir = _cam.global_transform.basis.x
		KEY_Q:
			dir = Vector3.UP
		KEY_E:
			dir = Vector3.DOWN
		_:
			return
	# 步长按模型尺度取（大模型小模型都好用），Shift 加速 4 倍
	var step: float = maxf(_holder_aabb().size.length() * 0.02, 0.0005)
	if k.shift_pressed:
		step *= 4.0
	_pan += dir.normalized() * step
	_apply_orbit()
	_status.text = "视角平移中（WASD 移动 / Q E 升降%s）" % ("，Shift 加速 4 倍" if k.shift_pressed else "")
	get_viewport().set_input_as_handled()


func _on_preview_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_cam_dist = maxf(_cam_dist * 0.88, 0.01)
			_apply_orbit()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_cam_dist = minf(_cam_dist * 1.14, 100000.0)
			_apply_orbit()
			return
		# 右键/中键拖动 = 旋转（Blender 用中键）——
		# 这样即使勾着框选模式，也还能转视角，不用来回切换
		if mb.button_index == MOUSE_BUTTON_RIGHT or mb.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = mb.pressed
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				# 先看有没有点在**旋转环**上（绕该轴旋转线框）
				var ra := _pick_ring(mb.position)
				if ra >= 0:
					_push_box_hist()
					var bs := Basis(_box_data["bx"], _box_data["by"], _box_data["bz"])
					var rc: Vector3 = _box_data["origin"]
					_ring_drag = {
						"axis": ra,
						"center": rc,
						"start_basis": bs,
						"angle0": _ring_angle(ra, bs, rc, mb.position),
					}
					_dragging = false
					return
				# 再看有没有点在缩放手柄上（像 Blender 那样拖面/边/角改尺寸）
				var hit := _pick_handle(mb.position)
				if not hit.is_empty():
					_push_box_hist()
					# ★ 稳定点：把**深度**和**起始盒子**在按下瞬间冻结
					#   （每帧用实时值算会形成反馈循环 -> 框体抖动）
					var hmi: MeshInstance3D = hit["node"]
					hit["depth"] = _cam.global_position.distance_to(hmi.global_position)
					hit["start"] = _box_data.duplicate(true)
					hit["press_at"] = mb.position
					_handle_drag = hit
					_dragging = false
					return
				_handle_drag = {}
				_drag_from = mb.position
				_dragging = true
				if _draw_mode and _overlay != null:
					_overlay.call("show_band", _drag_from, mb.position)
			else:
				if not _ring_drag.is_empty():
					_ring_drag = {}
					_status.text = "已旋转切割框。点「自动分离」按新范围切。"
					return
				if not _handle_drag.is_empty():
					_handle_drag = {}
					_status.text = "已调整切割框。点「自动分离」按新范围切。"
					return
				_dragging = false
				if _overlay != null:
					_overlay.call("clear_band")
				if _draw_mode:
					_make_box(_drag_from, mb.position)
				else:
					_toggle_sel(_pick_at(mb.position), mb.ctrl_pressed or mb.shift_pressed)
			return
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		if not _ring_drag.is_empty():
			_drag_ring(int(_ring_drag["axis"]), _ring_drag, mm.position)
			return
		if not _handle_drag.is_empty():
			_drag_handle(_handle_drag, mm.position)
			return
		if _orbiting:
			_orbit.x -= mm.relative.x * 0.01
			_orbit.y = clampf(_orbit.y - mm.relative.y * 0.01, -1.35, 1.35)
			_apply_orbit()
			return
		if not _dragging:
			return
		if _draw_mode:
			if _overlay != null:
				_overlay.call("show_band", _drag_from, mm.position)
			_preview_box(_drag_from, mm.position)
		elif (mm.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
			_orbit.x -= mm.relative.x * 0.01
			_orbit.y = clampf(_orbit.y - mm.relative.y * 0.01, -1.35, 1.35)
			_apply_orbit()


func _screen_rect(a: Vector2, b: Vector2) -> Rect2:
	return Rect2(a.min(b), (b - a).abs())


func _box_from_rect(rect: Rect2) -> Dictionary:
	var center := _holder_aabb().get_center()
	var depth := _cam.global_position.distance_to(center)
	var c2 := rect.get_center()
	var p0 := _cam.project_position(c2, depth)
	var px := _cam.project_position(c2 + Vector2(rect.size.x * 0.5, 0.0), depth)
	var py := _cam.project_position(c2 + Vector2(0.0, rect.size.y * 0.5), depth)
	var bx := _cam.global_transform.basis.x.normalized()
	var by := _cam.global_transform.basis.y.normalized()
	var bz := -_cam.global_transform.basis.z.normalized()
	var hx: float = maxf(absf((px - p0).dot(bx)), 0.001)
	var hy: float = maxf(absf((py - p0).dot(by)), 0.001)
	var hz: float = maxf(_holder_aabb().size.length() * 0.5, 0.01)
	return {"origin": p0, "bx": bx, "by": by, "bz": bz, "half": Vector3(hx, hy, hz)}


func _make_box(a: Vector2, b: Vector2) -> void:
	if (b - a).length() < 6.0:
		_status.text = "拖得太小：请按住左键拖出一个框"
		return
	_box_data = _box_from_rect(_screen_rect(a, b))
	_sync_box_visuals()
	_status.text = "已按拖出的范围设定切割范围。点自动分离只切框内；再拖一次可重设。"


func _preview_box(a: Vector2, b: Vector2) -> void:
	_ensure_box()
	if _box_mi == null:
		return
	var d := _box_from_rect(_screen_rect(a, b))
	_box_data = d
	_sync_box_visuals()


func _ensure_box() -> void:
	if _box_mi != null and is_instance_valid(_box_mi):
		return
	_box_mi = MeshInstance3D.new()
	_box_mi.name = "CutBoxPreview"
	# 注意：这里**不用实心 BoxMesh**（实心块会把模型整个盖住，就是之前那一大片青色）
	# 改成 12 条边的线框（ImmediateMesh 的 PRIMITIVE_LINES），这才是 Blender 那种选择框
	_rebuild_box_mesh(Vector3.ONE * 0.5)
	_holder.add_child(_box_mi)


## 屏幕 1 像素等于多少世界单位（当前相机距离下）—— 线宽 1px / 圆点 4px 都靠它换算
func _world_per_pixel() -> float:
	var vh := 720.0
	if _vp != null and _vp.size.y > 1:
		vh = float(_vp.size.y)
	if _cam == null:
		return 0.001
	return 2.0 * maxf(_cam_dist, 0.001) * tan(deg_to_rad(_cam.fov * 0.5)) / vh


## 半透明填充（图二那种浅蓝体积感）。
## 用 CULL_BACK：相机进到框里时背面被剔除 -> 不会糊一屏
func _ensure_fill() -> void:
	if _fill_mi != null and is_instance_valid(_fill_mi):
		return
	if _box_mi == null:
		return
	_fill_mi = MeshInstance3D.new()
	_fill_mi.name = "CutFill"
	var bm := BoxMesh.new()
	bm.size = Vector3.ONE
	_fill_mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = Color(0.45, 0.80, 1.0, 0.10)
	m.cull_mode = BaseMaterial3D.CULL_BACK
	_fill_mi.material_override = m
	_box_mi.add_child(_fill_mi)


## ★ 用户要求：**线宽 1px** ✓✓
##   所以不用"细长方体"那套（还得算粗细）✗ ——
##   ImmediateMesh 的 PRIMITIVE_LINES 画出来**就是 1 像素** ✓ 最简单也最准 ✓
func _rebuild_box_mesh(half: Vector3) -> void:
	if _box_mi == null or not is_instance_valid(_box_mi):
		return
	if _box_mat == null:
		_box_mat = StandardMaterial3D.new()
		_box_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_box_mat.albedo_color = Color(0.60, 0.88, 1.0, 1.0)
	_ensure_fill()
	var h := half
	if _fill_mi != null and is_instance_valid(_fill_mi):
		var fm := _fill_mi.mesh as BoxMesh
		if fm != null:
			fm.size = h * 2.0
	var pts: Array = [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	var edges: Array = [
		[0, 1], [1, 2], [2, 3], [3, 0],
		[4, 5], [5, 6], [6, 7], [7, 4],
		[0, 4], [1, 5], [2, 6], [3, 7],
	]
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, _box_mat)
	for e in edges:
		im.surface_add_vertex(pts[int(e[0])])
		im.surface_add_vertex(pts[int(e[1])])
	im.surface_end()
	_box_mi.mesh = im
	_rebuild_rings(h.length())


## 三个旋转环（R/G/B 对应绕 X/Y/Z 轴旋转），半径 = 盒子外接半径
func _rebuild_rings(radius: float) -> void:
	if _ring_mi == null or not is_instance_valid(_ring_mi):
		if _box_mi == null:
			return
		_ring_mi = MeshInstance3D.new()
		_ring_mi.name = "CutRings"
		_box_mi.add_child(_ring_mi)
	var im := ImmediateMesh.new()
	for a in range(3):
		var col := Color(1.0, 0.32, 0.32)
		if a == 1:
			col = Color(0.40, 1.0, 0.45)
		elif a == 2:
			col = Color(0.45, 0.60, 1.0)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = col
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, mat)
		var seg := 64
		for i in range(seg + 1):
			im.surface_add_vertex(_ring_point(a, TAU * float(i) / float(seg), radius))
		im.surface_end()
	_ring_mi.mesh = im


## 手柄参考 Godot 的 BoxShape3D 编辑器手柄：
##   6 个面手柄按轴着色（**X 红 / Y 绿 / Z 蓝**）+ 8 个角（白）+ 1 个中心（橙，整体移动）
##   拖面手柄 = 对称改该轴边长（和 Godot 的碰撞盒一致，中心不动）
func _ensure_handles() -> void:
	if not _handles.is_empty() or _holder == null:
		return
	var specs: Array = []
	for a in range(3):
		for s in [-1.0, 1.0]:
			var v := Vector3.ZERO
			v[a] = s
			specs.append({"kind": "face", "axis": a, "dir": v})
	for dx in [-1.0, 1.0]:
		for dy in [-1.0, 1.0]:
			for dz in [-1.0, 1.0]:
				specs.append({"kind": "corner", "axis": -1, "dir": Vector3(dx, dy, dz)})
	specs.append({"kind": "center", "axis": -1, "dir": Vector3.ZERO})
	for sp in specs:
		var kind := String(sp["kind"])
		var axis := int(sp["axis"])
		var mi := MeshInstance3D.new()
		mi.name = "CutHandle"
		# 图二那种小圆点：用小球（任何角度看都是圆点，不用 billboard 也不会翻面）
		var ball := SphereMesh.new()
		ball.radius = 0.5
		ball.height = 1.0
		ball.radial_segments = 16
		ball.rings = 8
		mi.mesh = ball
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		if kind == "face":
			if axis == 0:
				mat.albedo_color = Color(1.0, 0.28, 0.28)      # X = 红
			elif axis == 1:
				mat.albedo_color = Color(0.35, 1.0, 0.40)      # Y = 绿
			else:
				mat.albedo_color = Color(0.40, 0.55, 1.0)      # Z = 蓝
		elif kind == "corner":
			mat.albedo_color = Color(1.0, 1.0, 1.0)            # 角 = 白
		else:
			mat.albedo_color = Color(1.0, 0.62, 0.16)          # 中心 = 橙（整体移动）
		mi.material_override = mat
		_holder.add_child(mi)
		_handles.append({"kind": kind, "axis": axis, "dir": sp["dir"], "node": mi})


## 把盒子、手柄、shader 统一同步一次（改盒子后只调这一个函数）
func _sync_box_visuals() -> void:
	if _holder == null:
		return
	if not _box_data.has("origin"):
		_clear_box_shader()
		_update_btn()          # ★ 没有框 -> 「确定框选」置灰
		return
	if _box_mats.is_empty():
		_apply_box_shader()
	_ensure_box()
	_ensure_handles()
	var o: Vector3 = _box_data["origin"]
	var bx: Vector3 = _box_data["bx"]
	var by: Vector3 = _box_data["by"]
	var bz: Vector3 = _box_data["bz"]
	var h: Vector3 = _box_data["half"]
	var bs := Basis(bx, by, bz)
	if _box_mi != null and is_instance_valid(_box_mi):
		_box_mi.transform = Transform3D(bs, o)
		_rebuild_box_mesh(h)
	# ★ 圆句柄 6px，**恒大**（按屏幕像素换算：世界尺寸随相机距离变，屏幕上永远 6px）
	var sc: float = maxf(_world_per_pixel() * 6.0, 0.0001)
	for e in _handles:
		var d: Vector3 = e["dir"]
		var mi: MeshInstance3D = e["node"]
		mi.visible = true
		var local := Vector3(d.x * h.x, d.y * h.y, d.z * h.z)
		mi.transform = Transform3D(Basis().scaled(Vector3.ONE * sc), o + bs * local)
	_sync_box_uniforms()
	# ★ 单选记录时：框的改动**实时写回那条记录**（不需要再点确定）
	if _edit_idx >= 0 and _edit_idx < _box_records.size():
		_box_records[_edit_idx] = _box_data.duplicate(true)
		_refresh_left_row(_edit_idx)
	_update_btn()


## 只重算手柄的大小/位置（转视角/缩放后调用，避免整份 _sync_box_visuals 的开销）
func _sync_handle_size_only() -> void:
	if _holder == null or not _box_data.has("origin"):
		return
	var o: Vector3 = _box_data["origin"]
	var bs := Basis(_box_data["bx"], _box_data["by"], _box_data["bz"])
	var h: Vector3 = _box_data["half"]
	var sc: float = maxf(_world_per_pixel() * 6.0, 0.0001)   # 圆句柄 6px
	for e in _handles:
		var d: Vector3 = e["dir"]
		var mi: MeshInstance3D = e["node"]
		var local := Vector3(d.x * h.x, d.y * h.y, d.z * h.z)
		mi.transform = Transform3D(Basis().scaled(Vector3.ONE * sc), o + bs * local)


## 创建新的框选：**默认回到"模型等大的 AABB 框"**，并进入框选编辑（左键拖 = 拉新框）
func create_new_box() -> void:
	_default_box_from_model()
	_show_box()
	_draw_mode = true
	_update_btn()
	_status.text = "框选编辑中（默认是模型等大的框）：按住左键拖出一个新框；拖完点「确定框选」结束。"


## 取消框选：**完全隐藏选择框**（线框/填充/旋转环/手柄全收起，模型恢复原材质），画面干净。
## 框不保留；要重新框选就点「创建新的框选」（会回到模型等大的 AABB 框）。
func cancel_box() -> void:
	_draw_mode = false
	_dragging = false
	if _overlay != null:
		_overlay.call("clear_band")
	_box_data = {}
	_hide_box()
	_uncheck_all_left()
	_update_btn()
	_status.text = "已取消框选，画面已清干净。要重新框选就点「创建新的框选」。"


## 确定框选：结束编辑，并**新增一条框选记录**（显示在左侧列表）
## 它只负责记录；「自动分离」是独立功能，两者互不依赖（用户要求）
func confirm_box() -> void:
	if not _box_data.has("origin"):
		_status.text = "当前没有框选范围，无法确定。"
		return
	_draw_mode = false
	_dragging = false
	if _overlay != null:
		_overlay.call("clear_band")
	if _edit_idx >= 0 and _edit_idx < _box_records.size():
		# ★ 二次编辑中 -> **更新原记录**，不新增（用户反馈）
		_box_records[_edit_idx] = _box_data.duplicate(true)
		var n := _edit_idx + 1
		_edit_idx = -1
		_box_data = {}
		_hide_box()
		_uncheck_all_left()
		_fill_left_records()
		_update_btn()
		_status.text = "已更新「模型 %d」的范围（没有新增记录）。" % n
		return
	_box_records.append(_box_data.duplicate(true))
	# ★ 确定之后**框消失**（用户要求）：记录已存进左侧列表，预览恢复干净
	_edit_idx = -1
	_box_data = {}
	_hide_box()
	_uncheck_all_left()
	_fill_left_records()
	_update_btn()
	_status.text = "已记录第 %d 条框选，框已隐藏。点左侧该记录可恢复该范围；勾选记录后「导出选中」按它切割并导出。" % _box_records.size()


## 让预览回到"只有原始模型"：删掉散开的分块，模型节点还在就直接用，不在就重新加载。
## 保留框（线框/手柄/环）与两个列表的状态 —— 切割导出后调用。
func _show_model_only() -> void:
	if _holder == null:
		return
	# 先清掉散开的分块（这一步和有没有路径无关）
	for mi in _preview_nodes:
		if is_instance_valid(mi):
			mi.queue_free()
	_preview_nodes.clear()
	if _model_node != null and is_instance_valid(_model_node):
		_model_node.visible = true
		_frame_preview()
		return
	if source_path == "":
		return
	# 模型节点在一次 _clear_preview 里被清掉了 -> 重新加载一份
	var node := _load_glb(source_path)
	if node != null:
		_holder.add_child(node)
		_model_node = node
		_frame_preview()


## 隐藏选择框（点自动分离时调用）。框本身会被记住，供「还原」恢复。
func _hide_box() -> void:
	if _box_mi != null and is_instance_valid(_box_mi):
		_box_mi.visible = false
	for e in _handles:
		var mi: MeshInstance3D = e["node"]
		if is_instance_valid(mi):
			mi.visible = false
	if _ring_mi != null and is_instance_valid(_ring_mi):
		_ring_mi.visible = false
	_clear_box_shader()
	_box_hist.clear()          # ★ 框消失 -> 操作栈清除
	_box_redo.clear()
	_clear_hl_boxes()
	_update_btn()


## 重新显示选择框
func _show_box() -> void:
	if _box_mi != null and is_instance_valid(_box_mi):
		_box_mi.visible = true
	if _ring_mi != null and is_instance_valid(_ring_mi):
		_ring_mi.visible = true
	_sync_box_visuals()


## 默认框：**跟模型一样大**（贴合模型 AABB），不需要你先拖一个出来
func _default_box_from_model() -> void:
	# ★ 用**缓存的模型 AABB**，不用当前 holder 的（holder 里可能正放着散开的分块）
	var aabb := _model_aabb if _has_model_aabb else _holder_aabb()
	if aabb.size.length() < 0.00001:
		return
	var c := aabb.get_center()
	var h := aabb.size * 0.5
	# ★ 默认框比模型 AABB **大一圈**（用户要求）：模型完整在内 ✓、边缘也更好抓 ✓
	#   留白 = 对角线 3%（并保证至少 2 毫米，细长轴也能长出来）
	var pad: float = maxf(aabb.size.length() * 0.03, 0.002)
	h += Vector3(pad, pad, pad)
	_box_data = {
		"origin": c,
		"bx": Vector3(1.0, 0.0, 0.0),
		"by": Vector3(0.0, 1.0, 0.0),
		"bz": Vector3(0.0, 0.0, 1.0),
		"half": Vector3(maxf(h.x, 0.002), maxf(h.y, 0.002), maxf(h.z, 0.002)),
	}
	_box_hist.clear()          # ★ 框重新出现 -> 操作栈是新的
	_box_redo.clear()
	_sync_box_visuals()


## 旋转环上的点（a: 0=绕X 1=绕Y 2=绕Z）
func _ring_point(a: int, t: float, radius: float) -> Vector3:
	if a == 0:
		return Vector3(0.0, cos(t) * radius, sin(t) * radius)
	if a == 1:
		return Vector3(cos(t) * radius, 0.0, sin(t) * radius)
	return Vector3(cos(t) * radius, sin(t) * radius, 0.0)


## 环的旋转轴（局部）
func _ring_axis(a: int) -> Vector3:
	if a == 0:
		return Vector3(1.0, 0.0, 0.0)
	if a == 1:
		return Vector3(0.0, 1.0, 0.0)
	return Vector3(0.0, 0.0, 1.0)


## 环平面内的两个基准向量（局部）
func _ring_u(a: int) -> Vector3:
	if a == 0:
		return Vector3(0.0, 1.0, 0.0)
	return Vector3(1.0, 0.0, 0.0)


func _ring_v(a: int) -> Vector3:
	if a == 2:
		return Vector3(0.0, 1.0, 0.0)
	return Vector3(0.0, 0.0, 1.0)


func _seg_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.000001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## 命中哪个旋转环（把环投到屏幕，算鼠标到线段的距离）
func _pick_ring(at: Vector2) -> int:
	if _box_mi == null or not is_instance_valid(_box_mi) or not _box_data.has("origin"):
		return -1
	var radius: float = Vector3(_box_data["half"]).length()
	var best := -1
	var bd := 9.0
	for a in range(3):
		var seg := 48
		for i in range(seg):
			var p0: Vector3 = _box_mi.global_transform * _ring_point(a, TAU * float(i) / float(seg), radius)
			var p1: Vector3 = _box_mi.global_transform * _ring_point(a, TAU * float(i + 1) / float(seg), radius)
			var dd: float = _seg_dist(at, _cam.unproject_position(p0), _cam.unproject_position(p1))
			if dd < bd:
				bd = dd
				best = a
	return best


## 鼠标射线与环平面求交 -> 得到绕该轴的当前角度
func _ring_angle(a: int, basis: Basis, center: Vector3, at: Vector2) -> float:
	var o: Vector3 = _cam.project_ray_origin(at)
	var n: Vector3 = _cam.project_ray_normal(at)
	var normal: Vector3 = (basis * _ring_axis(a)).normalized()
	var den: float = n.dot(normal)
	if absf(den) < 0.0001:
		return 0.0
	var t: float = (center - o).dot(normal) / den
	var hit: Vector3 = o + n * t
	var rel := hit - center
	var u: Vector3 = (basis * _ring_u(a)).normalized()
	var v: Vector3 = (basis * _ring_v(a)).normalized()
	return atan2(rel.dot(v), rel.dot(u))


## 拖旋转环：绕该轴旋转线框。基准在按下瞬间冻结 -> 不抖、不漂移
func _drag_ring(a: int, e: Dictionary, at: Vector2) -> void:
	var base: Basis = e["start_basis"]
	var c: Vector3 = e["center"]
	var ang0: float = float(e["angle0"])
	# 绕**局部轴**旋转（后乘 = 在自身坐标系里转）
	var nb: Basis = base * Basis(_ring_axis(a), _ring_angle(a, base, c, at) - ang0)
	_box_data["bx"] = nb.x.normalized()
	_box_data["by"] = nb.y.normalized()
	_box_data["bz"] = nb.z.normalized()
	_sync_box_visuals()


func _pick_handle(at: Vector2) -> Dictionary:
	var best := {}
	var bd := 20.0
	for e in _handles:
		var mi: MeshInstance3D = e["node"]
		if not mi.visible:
			continue
		var sp: Vector2 = _cam.unproject_position(mi.global_position)
		var dd: float = sp.distance_to(at)
		if dd < bd:
			bd = dd
			best = e
	return best


## 拖手柄：参考 Godot 的 BoxShape3D 手柄 ——
##   面手柄：**对称**改该轴边长（中心不动，和 Godot 一致）
##   角手柄：对称改三个轴
##   中心手柄：整体平移盒子（对应 Godot 里移动 CollisionShape3D 的位置）
## 稳定点：全程用按下瞬间冻结的 depth / press_at / start 重算（不抖、不漂移）
func _drag_handle(e: Dictionary, at: Vector2) -> void:
	if not e.has("start"):
		return
	var depth: float = float(e["depth"])
	var start: Dictionary = e["start"]
	var kind := String(e.get("kind", "corner"))
	var w: Vector3 = _cam.project_position(at, depth)
	var o: Vector3 = start["origin"]
	var bx: Vector3 = start["bx"]
	var by: Vector3 = start["by"]
	var bz: Vector3 = start["bz"]
	var h: Vector3 = start["half"]
	if kind == "center":
		var p0: Vector3 = _cam.project_position(e["press_at"], depth)
		_box_data["origin"] = o + (w - p0)
		_sync_box_visuals()
		return
	var rel := w - o
	var l := Vector3(rel.dot(bx), rel.dot(by), rel.dot(bz))
	# ★ 对边不动（用户要求，和 BoxShape3D 改边一致）：
	#   被拖的那一侧动，**对面保持原位** -> 盒子的中心坐标也跟着变（即"xyz 轴改框坐标"）
	var d: Vector3 = e["dir"]
	var axes: Array = [bx, by, bz]
	var dh := Vector3(d.x, d.y, d.z)
	var nh := h
	var shift := Vector3.ZERO
	for i in range(3):
		if absf(dh[i]) < 0.5:
			continue
		var fixed: float = -dh[i] * h[i]          # 对面：不动
		var moving: float = l[i]
		nh[i] = maxf(absf(moving - fixed) * 0.5, 0.001)
		shift += axes[i] * ((moving + fixed) * 0.5)
	_box_data["half"] = nh
	_box_data["origin"] = o + shift
	_sync_box_visuals()


# ================= 框内高亮 / 框外变暗 =================

func _clear_box_shader() -> void:
	_box_mats.clear()
	if _holder == null:
		return
	var stack: Array = [_holder]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D:
			var mi := nd as MeshInstance3D
			if mi.mesh != null and not _is_helper_node(mi.name):
				for s in range(mi.mesh.get_surface_count()):
					mi.set_surface_override_material(s, null)
		for c in nd.get_children():
			stack.append(c)


func _is_helper_node(n: StringName) -> bool:
	var s := String(n)
	# 线框 / 填充 / 旋转环 / 手柄都不算进模型包围盒（否则框会越算越大）
	return s == "CutBoxPreview" or s == "CutFill" or s == "CutRings" or s == "CutHlBoxes" or s.begins_with("CutHandle")


func _apply_box_shader() -> void:
	_box_mats.clear()
	var sh: Shader = load(BOX_SHADER_PATH)
	if sh == null or _holder == null:
		return
	var stack: Array = [_holder]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		if nd is MeshInstance3D:
			_apply_shader_mesh(nd as MeshInstance3D, sh)
		for c in nd.get_children():
			stack.append(c)
	_sync_box_uniforms()


func _apply_shader_mesh(mi: MeshInstance3D, sh: Shader) -> void:
	var m := mi.mesh
	if m == null or _is_helper_node(mi.name):
		return
	for s in range(m.get_surface_count()):
		var src := mi.get_active_material(s)
		var sm := ShaderMaterial.new()
		sm.shader = sh
		if src is StandardMaterial3D:
			var st := src as StandardMaterial3D
			sm.set_shader_parameter("base_color", st.albedo_color)
			if st.albedo_texture != null:
				sm.set_shader_parameter("base_tex", st.albedo_texture)
				sm.set_shader_parameter("use_tex", true)
		else:
			sm.set_shader_parameter("base_color", Color(0.78, 0.78, 0.78, 1.0))
		mi.set_surface_override_material(s, sm)
		_box_mats.append(sm)


func _sync_box_uniforms() -> void:
	var on: bool = _box_data.has("origin")
	for m in _box_mats:
		if m is ShaderMaterial:
			var sm := m as ShaderMaterial
			sm.set_shader_parameter("box_on", on)
			if on:
				sm.set_shader_parameter("box_origin", _box_data["origin"])
				sm.set_shader_parameter("box_bx", _box_data["bx"])
				sm.set_shader_parameter("box_by", _box_data["by"])
				sm.set_shader_parameter("box_bz", _box_data["bz"])
				sm.set_shader_parameter("box_half", _box_data["half"])


func _restore_box() -> void:
	if not _box_data.has("origin"):
		return
	_sync_box_visuals()


func _fill_right(parts: Array) -> void:
	if _tree_right == null:
		return
	_tree_right.clear()
	var root := _tree_right.create_item()
	for i in range(parts.size()):
		var d: Dictionary = parts[i]
		var it := _tree_right.create_item(root)
		it.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)      # 勾选框（用户要求）
		it.set_editable(0, true)
		it.set_checked(0, false)
		it.set_text(1, String(d.get("name", "part")))
		it.set_text(2, str(int(d["tris"])))
		it.set_metadata(0, i)


## 左侧 = 框选记录（每次「确定框选」新增一条）。
## 点行 = 恢复该范围；勾选 = 「导出选中」时按这条记录切割并导出。
func _fill_left_records() -> void:
	if _tree_left == null:
		return
	_tree_left.clear()
	var root := _tree_left.create_item()
	for i in range(_box_records.size()):
		var d: Dictionary = _box_records[i]
		var it := _tree_left.create_item(root)
		it.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		it.set_editable(0, true)
		it.set_checked(0, false)
		it.set_text(1, "模型 %d" % (i + 1))
		var h: Vector3 = d["half"]
		it.set_text(2, "%.3f x %.3f x %.3f" % [h.x * 2.0, h.y * 2.0, h.z * 2.0])
		var c: Vector3 = d["origin"]
		it.set_text(3, "%.3f, %.3f, %.3f" % [c.x, c.y, c.z])
		it.set_metadata(0, i)


func _on_right_selected() -> void:
	if _tree_right == null:
		return
	var it := _tree_right.get_selected()
	if it == null:
		return
	var i := int(it.get_metadata(0))
	if i < 0 or i >= _parts.size():
		return
	if _preview_nodes.size() != _parts.size():
		_show_parts(_parts)
	_sel.clear()
	_sel[i] = true
	_apply_hl()
	_update_btn()
	var d: Dictionary = _parts[i]
	var s: Vector3 = d["size"]
	_status.text = "第 %d 块已高亮：三角 %d，尺寸 %.3f x %.3f x %.3f" % [
			i + 1, int(d["tris"]), s.x, s.y, s.z]


# ============ 左侧「模型N」：单选=实时编辑 / 多选=只读高亮 ============

func _on_left_selection_changed() -> void:
	_left_selection_apply()


## Tree.multi_selected 的签名是 (item: TreeItem, column: int, selected: bool)
##   —— 第一个参数写成 int 会一直报 "Cannot convert argument 1 from Object to int"
func _on_left_multi_selected(_item: TreeItem, _col: int, _sel: bool) -> void:
	_left_selection_apply()


func _selected_left_rows() -> Array:
	var out: Array = []
	if _tree_left == null:
		return out
	var root := _tree_left.get_root()
	if root == null:
		return out
	var it := root.get_first_child()
	while it != null:
		if it.is_selected(0):
			out.append(int(it.get_metadata(0)))
		it = it.get_next()
	return out


func _left_selection_apply() -> void:
	# ★ 规则：**勾选框是唯一状态来源**（列表行已无视觉反馈）
	#   点击某一行 = 把它勾上；已有多个勾选时点击无反应（用户要求）
	if _checked_records().size() > 1:
		return
	var sel := _selected_left_rows()
	if sel.is_empty():
		return
	var i := int(sel[0])
	if not _checked_records().has(i):
		_set_left_checked(i, true)
	_apply_checked_state()


## 把左列表第 i 行的勾选框设为 on
## 静默清掉左列表全部勾选（不触发 item_edited，避免回灌状态机）
func _uncheck_all_left() -> void:
	if _tree_left == null:
		return
	var root := _tree_left.get_root()
	if root == null:
		return
	var it := root.get_first_child()
	while it != null:
		it.set_checked(0, false)
		it = it.get_next()

func _set_left_checked(i: int, on: bool) -> void:
	if _tree_left == null:
		return
	var root := _tree_left.get_root()
	if root == null:
		return
	var it := root.get_first_child()
	var k := 0
	while it != null:
		if k == i:
			it.set_checked(0, on)
			return
		it = it.get_next()
		k += 1


## 按"勾选框"的状态统一决定：单条=可编辑 / 多条=只读高亮 / 零条=收起框
func _apply_checked_state() -> void:
	var checked := _checked_records()
	if checked.size() == 1:
		_enter_edit(int(checked[0]))
		return
	if checked.is_empty():
		_leave_edit()
		_status.text = "当前没有勾选记录，框已收起。"
		return
	_leave_edit()
	_refresh_highlights()
	_status.text = "已高亮 %d 个框选记录（全部只读，不可编辑）。" % checked.size()


## 收起"正在编辑的框"并清掉编辑态（_hide_box 里会刷新按钮状态）
func _leave_edit() -> void:
	_edit_idx = -1
	_box_data = {}
	_hide_box()
	_update_btn()


## 窗口关闭时清掉历史状态（用户要求：关闭窗口 -> 清除历史状态）
func reset_state() -> void:
	source_path = ""
	_parts = []
	_sel.clear()
	_box_records = []
	_box_data = {}
	_box_hist = []
	_box_redo = []
	_box_before_separate = {}
	_cut_recs = []
	_edit_idx = -1
	_menu_row = -1
	_draw_mode = false
	_dragging = false
	_orbiting = false
	_handle_drag = {}
	_ring_drag = {}
	_orbit = Vector2(0.35, -0.45)
	_pan = Vector3.ZERO
	_has_model_aabb = false
	_cam_dist = 4.0
	if _tree_left != null:
		_tree_left.clear()
	if _tree_right != null:
		_tree_right.clear()
	_clear_preview()
	_clear_box_shader()
	_hl_boxes_mi = null
	_hl_boxes.clear()
	_handles.clear()
	if _overlay != null:
		_overlay.call("clear_band")
	if _info != null:
		_info.text = "当前模型：（请在文件系统里右键一个 .glb）"
	if _status != null:
		_status.text = "就绪"
	_update_btn()


func _notification(what: int) -> void:
	# 本节点被销毁而导出线程还在跑 -> 必须先 join，否则会崩
	if what == NOTIFICATION_PREDELETE:
		if _thread != null:
			if _thread.is_started():
				_thread.wait_to_finish()
			_thread = null
		return
	# 窗口被关掉（变为不可见）-> 清历史状态，下次打开是干净的
	if what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree():
		if _tree_left != null or _tree_right != null:
			reset_state()


## 进入某条记录的"实时编辑"：框恢复、手柄/彩环可用，改动立刻写回该记录
func _enter_edit(i: int) -> void:
	if i < 0 or i >= _box_records.size():
		return
	_edit_idx = i
	_box_data = (_box_records[_edit_idx] as Dictionary).duplicate(true)
	_box_hist.clear()               # 框出现 -> 操作栈是新的
	_box_redo.clear()
	_show_box()
	_refresh_highlights()
	_update_btn()
	_status.text = "正在编辑「模型 %d」：拖圆点/彩环/中心点直接改，实时生效（无需再点确定）。" % (_edit_idx + 1)


## 勾选框变化（item_edited）：**勾选框是唯一状态来源**
##   单条 -> 可编辑；多条 -> 只读高亮；零条 -> 收起框
##   （不再参考"行选中"状态：列表没有行选中视觉，行选中还可能残留 ✗
##     上一版并集判据导致"只取消勾选、但行还选中"时框留着不收 ✗ —— 用户反馈的正是这个）
func _on_left_item_edited() -> void:
	_apply_checked_state()


## 高亮框 = 当前选中的行 ∪ 已勾选的行（点行和勾选都会让高亮框出现）
func _refresh_highlights() -> void:
	var rows := _selected_left_rows()
	for i in _checked_records():
		if not rows.has(i):
			rows.append(i)
	rows.erase(_edit_idx)          # 正在编辑的那条不画黄框（它自己就是可见的编辑框）
	if rows.is_empty():
		_clear_hl_boxes()
		return
	_hl_boxes = rows
	_build_hl_boxes()


## 把 Tree 的 hover / 选中反馈去掉（保留点击事件本身）
func _plain_tree(tr: Tree) -> void:
	if tr == null:
		return
	var empty := StyleBoxEmpty.new()
	tr.add_theme_stylebox_override("hovered", empty)
	tr.add_theme_stylebox_override("selected", empty)
	tr.add_theme_stylebox_override("selected_focus", empty)
	tr.add_theme_stylebox_override("cursor", empty)
	tr.add_theme_stylebox_override("cursor_unfocused", empty)
	var fcol: Color = tr.get_theme_color("font_color")
	tr.add_theme_color_override("font_selected_color", fcol)
	tr.add_theme_color_override("font_hovered_color", fcol)


## 只刷某一行的文字（避免整表重建把选择弄丢）
func _refresh_left_row(i: int) -> void:
	if _tree_left == null or i < 0 or i >= _box_records.size():
		return
	var root := _tree_left.get_root()
	if root == null:
		return
	var it := root.get_first_child()
	var k := 0
	while it != null:
		if k == i:
			var d: Dictionary = _box_records[i]
			var h: Vector3 = d["half"]
			it.set_text(2, "%.3f x %.3f x %.3f" % [h.x * 2.0, h.y * 2.0, h.z * 2.0])
			var c: Vector3 = d["origin"]
			it.set_text(3, "%.3f, %.3f, %.3f" % [c.x, c.y, c.z])
			return
		it = it.get_next()
		k += 1


## 多选时：把选中的记录都画成黄色 1px 线框（只读）
func _build_hl_boxes() -> void:
	if _holder == null:
		return
	if _hl_boxes_mi == null or not is_instance_valid(_hl_boxes_mi):
		_hl_boxes_mi = MeshInstance3D.new()
		_hl_boxes_mi.name = "CutHlBoxes"
		_holder.add_child(_hl_boxes_mi)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.82, 0.25, 1.0)
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for idx in _hl_boxes:
		var i := int(idx)
		if i < 0 or i >= _box_records.size():
			continue
		var d: Dictionary = _box_records[i]
		var o: Vector3 = d["origin"]
		var bs := Basis(d["bx"], d["by"], d["bz"])
		var h: Vector3 = d["half"]
		var pts: Array = [
			Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
			Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
			Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
			Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
		]
		var edges: Array = [
			[0, 1], [1, 2], [2, 3], [3, 0],
			[4, 5], [5, 6], [6, 7], [7, 4],
			[0, 4], [1, 5], [2, 6], [3, 7],
		]
		for e in edges:
			im.surface_add_vertex(o + bs * (pts[int(e[0])] as Vector3))
			im.surface_add_vertex(o + bs * (pts[int(e[1])] as Vector3))
	im.surface_end()
	_hl_boxes_mi.mesh = im
	_hl_boxes_mi.visible = true


func _clear_hl_boxes() -> void:
	_hl_boxes.clear()
	if _hl_boxes_mi != null and is_instance_valid(_hl_boxes_mi):
		_hl_boxes_mi.visible = false


## 左列表右键 -> 删除该框选记录
func _on_left_tree_mouse(at: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_RIGHT or _tree_left == null or _left_menu == null:
		return
	var it := _tree_left.get_item_at_position(at)
	if it == null:
		return
	_menu_row = int(it.get_metadata(0))
	_left_menu.popup(Rect2i(Vector2i(_tree_left.get_screen_position() + at), Vector2i.ZERO))


func _on_left_menu_pressed(id: int) -> void:
	if id != 0 or _menu_row < 0 or _menu_row >= _box_records.size():
		return
	_box_records.remove_at(_menu_row)
	_edit_idx = -1
	_box_data = {}
	_hide_box()
	_clear_hl_boxes()
	_fill_left_records()
	_update_btn()
	_status.text = "已删除一条框选记录（剩 %d 条）。" % _box_records.size()


# ============ 摆正 / 框操作栈 ============

## 把框的朝向恢复成世界 X/Y/Z 轴对齐（旋转后很难对准正交轴时用）
func straighten_box() -> void:
	if not _box_data.has("origin"):
		_status.text = "当前没有框，无法摆正。"
		return
	_push_box_hist()
	_box_data["bx"] = Vector3(1.0, 0.0, 0.0)
	_box_data["by"] = Vector3(0.0, 1.0, 0.0)
	_box_data["bz"] = Vector3(0.0, 0.0, 1.0)
	_sync_box_visuals()
	_status.text = "已摆正：框的朝向恢复成世界 X/Y/Z 轴对齐。"


## 压一步框操作（栈随框出现而重置；只给"框操作"加，不给所有操作加）
func _push_box_hist() -> void:
	if not _box_data.has("origin"):
		return
	_box_hist.append(_box_data.duplicate(true))
	if _box_hist.size() > 32:
		_box_hist.pop_front()
	_box_redo.clear()          # 有了新操作 -> 重做链作废（标准行为）


func undo_box_op() -> void:
	if not _box_data.has("origin"):
		_status.text = "当前没有独立的框，无法撤销框操作。"
		return
	if _box_hist.is_empty():
		_status.text = "没有可撤销的框操作（框一出现，操作栈就是新的）。"
		return
	_box_redo.append(_box_data.duplicate(true))     # 当前状态进重做链
	_box_data = _box_hist.pop_back()
	_sync_box_visuals()
	_status.text = "已撤销一步框操作。"


## 重做框操作（与撤销对称）
func redo_box_op() -> void:
	if not _box_data.has("origin"):
		_status.text = "当前没有独立的框，无法重做框操作。"
		return
	if _box_redo.is_empty():
		_status.text = "没有可重做的框操作。"
		return
	_box_hist.append(_box_data.duplicate(true))
	_box_data = _box_redo.pop_back()
	_sync_box_visuals()
	_status.text = "已重做一步框操作。"


## 导出选中：左侧（框选记录）与右侧（切割块）**只能选一侧**
## 两侧都有勾选 -> 明确提示"无法导出，请重新选择"（用户要求）
func export_selected() -> void:
	var recs := _checked_records()
	var parts_sel := _checked_parts()
	if not recs.is_empty() and not parts_sel.is_empty():
		_status.text = "左右两侧都有勾选，无法导出 ── 请只保留一侧的勾选再试。"
		return
	if not recs.is_empty():
		_ask_export_dir("records", recs)
		return
	if not parts_sel.is_empty():
		_ask_export_dir("parts", parts_sel)
		return
	if _sel.is_empty():
		_status.text = "还没选中：在预览里点一下分块，或勾选左侧记录 / 右侧切割块。"
		return
	var idxs: Array = []
	for k in _sel.keys():
		idxs.append(int(k))
	idxs.sort()
	_ask_export_dir("parts", idxs)


## 弹出"选择导出文件夹"对话框（用户要求）
func _ask_export_dir(kind: String, idxs: Array) -> void:
	_pending_export = {"kind": kind, "idxs": idxs}
	_ensure_dir_dialog()
	if _dir_dlg == null or not is_instance_valid(_dir_dlg):
		return
	_dir_dlg.popup_centered_ratio(0.6)
	_status.text = "请选择导出到的文件夹…（选好后自动开始）"


func _ensure_dir_dialog() -> void:
	if _dir_dlg != null and is_instance_valid(_dir_dlg):
		return
	_dir_dlg = FileDialog.new()
	_dir_dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR     # 选文件夹
	_dir_dlg.access = FileDialog.ACCESS_RESOURCES          # 限定在项目内（导出后可被编辑器收录）
	_dir_dlg.title = "选择导出到的文件夹"
	_dir_dlg.use_native_dialog = false
	_dir_dlg.current_dir = "res://"
	_dir_dlg.dir_selected.connect(_on_dir_selected)
	add_child(_dir_dlg)


func _on_dir_selected(dir: String) -> void:
	var pe := _pending_export
	_pending_export = {}
	if pe.is_empty() or dir == "":
		return
	var kind := String(pe["kind"])
	var idxs: Array = pe["idxs"]
	if kind == "records":
		_cut_records_and_export(idxs, dir)
	else:
		_do_export_to(_parts, idxs, "选中", dir)


## 点【导出选中】时"会被导出"的条数（给按钮显示用）
func _export_count() -> int:
	var recs := _checked_records()
	var prts := _checked_parts()
	if not recs.is_empty() and not prts.is_empty():
		return 0                     # 两侧都勾 -> 无法导出（提示用户重选）
	if not recs.is_empty():
		return recs.size()           # 左侧：按记录条数
	if not prts.is_empty():
		return prts.size()           # 右侧：按切割块数
	return _sel.size()               # 都没勾 -> 退回"预览里点选的分块"


## 左侧勾选的框选记录序号
func _checked_records() -> Array:
	var out: Array = []
	if _tree_left == null:
		return out
	var root := _tree_left.get_root()
	if root == null:
		return out
	var it := root.get_first_child()
	while it != null:
		if it.is_checked(0):
			out.append(int(it.get_metadata(0)))
		it = it.get_next()
	return out


## 右侧勾选的切割块序号
func _checked_parts() -> Array:
	var out: Array = []
	if _tree_right == null:
		return out
	var root := _tree_right.get_root()
	if root == null:
		return out
	var it := root.get_first_child()
	while it != null:
		if it.is_checked(0):
			out.append(int(it.get_metadata(0)))
		it = it.get_next()
	return out


## 按框选记录逐条切割并导出（左侧勾选时走这条路；每条都要十几秒）
func _cut_records_and_export(recs: Array, dir: String) -> void:
	if source_path == "":
		_status.text = "还没有模型。"
		return
	_begin_busy("按框选记录切割中...（共 %d 条，每条约十几秒）" % recs.size())
	_cut_recs = recs
	_cut_dir = dir
	_defer(Callable(self, "_run_cut_records"))


func _run_cut_records() -> void:
	var all: Array = []
	# ★ 已经有切割好的分块 -> 直接"筛"（毫秒级），不再重跑完整切割
	#   （用户反馈：以前每条记录都要重新加载 66MB + 焊接百万顶点 + 算连通块，9.4 秒/次）
	var fast := not _parts.is_empty()
	for i in _cut_recs:
		if int(i) < 0 or int(i) >= _box_records.size():
			continue
		if fast:
			all.append_array(SplitCoreScript.slice_parts(_parts, _box_records[int(i)]))
		else:
			var r: Dictionary = SplitCoreScript.split(source_path, {"box": _box_records[int(i)]})
			if bool(r.get("ok", false)):
				all.append_array(r["parts"])
	_cut_recs = []
	_end_busy()
	if all.is_empty():
		_status.text = "按框选记录切割失败：没有产生任何分块。"
		return
	# ★ 用户要求：导出完成后**保持原样，不做任何多余操作**
	#   —— 不动预览、不动列表、不选中、不写回 _parts，只把文件写出去
	var idxs: Array = []
	for i in range(all.size()):
		idxs.append(i)
	var target := _cut_dir
	_cut_dir = ""
	_do_export_to(all, idxs, "框选记录", target)



## 把网格上的材质换成"引用项目里已有贴图"的新材质
##   —— 这样保存 .res/.tscn 时**不会内嵌贴图副本**，而且拖进场景就是带贴图的
func _relink_material_textures(mesh: ArrayMesh, src_dir: String) -> void:
	if mesh == null:
		return
	var albedo := _find_texture_like(src_dir, ["basecolor", "albedo", "diffuse"])
	var normal := _find_texture_like(src_dir, ["normal"])
	var orm := _find_texture_like(src_dir, ["_rm", "rough", "metal"])
	for s in range(mesh.get_surface_count()):
		var old := mesh.surface_get_material(s)
		var m := StandardMaterial3D.new()
		m.roughness = 1.0
		m.metallic = 0.0
		if old is StandardMaterial3D:
			var so := old as StandardMaterial3D
			m.albedo_color = so.albedo_color
			m.roughness = so.roughness
			m.metallic = so.metallic
			m.cull_mode = so.cull_mode
		if albedo != "":
			m.albedo_texture = load(albedo)
		if normal != "":
			m.normal_enabled = true
			m.normal_texture = load(normal)
		if orm != "":
			var tx: Texture2D = load(orm)
			m.roughness_texture = tx
			m.metallic_texture = tx
			m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
			m.metallic_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_BLUE
		mesh.surface_set_material(s, m)


## 在目录里按关键字**优先级**找一张贴图（跳过 .import 边车文件）
func _find_texture_like(dir_path: String, keys: Array) -> String:
	var files: Array = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return ""
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and not f.ends_with(".import"):
			files.append(f)
		f = d.get_next()
	d.list_dir_end()
	for k in keys:
		var key := String(k).to_lower()
		for nm in files:
			if String(nm).to_lower().find(key) >= 0:
				return dir_path.path_join(String(nm))
	return ""


## 把 root 的所有后代节点的 owner 重新指向 root
## （glTF 导出器靠 owner 链判断"属于同一场景"，不重挂会导出成空文件）
func _own_all(root: Node) -> void:
	for c in root.get_children():
		_stamp_owner(c, root)


func _stamp_owner(n: Node, owner_node: Node) -> void:
	n.owner = owner_node
	for c in n.get_children():
		_stamp_owner(c, owner_node)


## .gltf 模式下：把 images 的 uri 从 Godot 生成的 textures/xxx.png
## **改指回项目里原有的那张贴图**（同名、任意扩展名，通常在源 glb 同目录）。
## 返回改指成功的数量；只要有一处改不了就返回 -1（这样调用方就不会去删副本目录）。
func _relink_gltf_textures(gltf_path: String, out_dir: String, src_dir: String) -> int:
	if not FileAccess.file_exists(gltf_path):
		return -1
	var fa := FileAccess.open(gltf_path, FileAccess.READ)
	if fa == null:
		return -1
	var txt := fa.get_as_text()
	fa.close()
	var fixed := 0
	var pos := 0
	var all_ok := true
	while true:
		var i1 := txt.find("textures%2F", pos)
		var i2 := txt.find("textures/", pos)
		var at := -1
		var skip := 0
		if i1 >= 0 and (i2 < 0 or i1 <= i2):
			at = i1
			skip = 11
		elif i2 >= 0:
			at = i2
			skip = 9
		if at < 0:
			break
		var endq := txt.find("\"", at)
		if endq < 0:
			break
		var raw := txt.substr(at + skip, endq - at - skip)
		var fname := raw.uri_decode()
		var base_name := fname.get_basename()
		var found := _find_texture_in(src_dir, base_name)
		var rel := ""
		if found != "":
			rel = _rel_path_from(out_dir, found)
		if rel == "":
			all_ok = false
			pos = endq
			continue
		var enc := rel.uri_encode()
		txt = txt.substr(0, at) + enc + txt.substr(endq)
		pos = at + enc.length()
		fixed += 1
	var fw := FileAccess.open(gltf_path, FileAccess.WRITE)
	if fw != null:
		fw.store_string(txt)
		fw.close()
	return fixed if all_ok else -1


## 在目录里按"基础名"找一张图（任意扩展名；跳过我们自己导出的 gltf/bin）
func _find_texture_in(dir_path: String, base_name: String) -> String:
	var d := DirAccess.open(dir_path)
	if d == null:
		return ""
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir() and f.get_basename() == base_name:
			if not f.ends_with(".gltf") and not f.ends_with(".bin") and not f.ends_with(".glb"):
				return dir_path.path_join(f)
		f = d.get_next()
	return ""


## 从 out_dir 指向 target 的相对路径（同一目录时就是文件名）；无法相对化时返回空串
func _rel_path_from(out_dir: String, target: String) -> String:
	var abs_out := ProjectSettings.globalize_path(out_dir).replace("\\", "/").trim_suffix("/")
	var abs_t := ProjectSettings.globalize_path(target).replace("\\", "/")
	var prefix := abs_out + "/"
	if abs_t.begins_with(prefix):
		return abs_t.substr(prefix.length())
	# 尝试往上走（同盘不同级）
	var up := ""
	var cur := abs_out
	while cur.length() > 3 and not abs_t.begins_with(cur + "/"):
		cur = cur.get_base_dir()
		up += "../"
	if abs_t.begins_with(cur + "/"):
		return up + abs_t.substr(cur.length() + 1)
	return ""


## 把 src 目录里的**文件**全部移动到 dst（同名先删；跨盘时退化为复制+删除）
func _move_out(src_dir: String, dst_dir: String) -> void:
	# ★ 必须先**列完名单再操作** ✗ —— 一边 get_next() 一边 rename/remove 会打乱目录枚举，
	#   get_next() 可能永远返回不了 ""，就是死循环（实测：导出线程挂死就是这个原因）
	var names: Array = []
	var d := DirAccess.open(src_dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if not d.current_is_dir():
			names.append(f)
		f = d.get_next()
	d.list_dir_end()
	for nm in names:
		var s := ProjectSettings.globalize_path(src_dir.path_join(String(nm)))
		var t2 := ProjectSettings.globalize_path(dst_dir.path_join(String(nm)))
		if FileAccess.file_exists(t2):
			DirAccess.remove_absolute(t2)
		var err := DirAccess.rename_absolute(s, t2)
		if err != OK:
			DirAccess.copy_absolute(s, t2)
			DirAccess.remove_absolute(s)


## 清空一个目录（不存在就什么都不做）
func _wipe_dir(abs_path: String) -> void:
	if DirAccess.dir_exists_absolute(abs_path):
		_delete_dir(abs_path)


## 递归删除目录（清理 Godot 生成的贴图副本用）
func _delete_dir(abs_path: String) -> void:
	# ★ 同上：先列名单再删（一边遍历一边删同样会死循环）
	var files: Array = []
	var dirs: Array = []
	var d := DirAccess.open(abs_path)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f != "." and f != "..":
			if d.current_is_dir():
				dirs.append(f)
			else:
				files.append(f)
		f = d.get_next()
	d.list_dir_end()
	for nm in files:
		DirAccess.remove_absolute(abs_path.path_join(String(nm)))
	for nm in dirs:
		_delete_dir(abs_path.path_join(String(nm)))
	DirAccess.remove_absolute(abs_path)


## 不带贴图时用的材质：只保留原 albedo 颜色（丢掉贴图 -> 文件小、导出快）
func _plain_material(src: Material) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.roughness = 1.0
	m.metallic = 0.0
	if src is StandardMaterial3D:
		var st := src as StandardMaterial3D
		m.albedo_color = st.albedo_color
		m.transparency = st.transparency
		m.cull_mode = st.cull_mode
	return m


## 真正的导出：写进**用户选好的文件夹**（不再固定写到 xxx_parts）
## 导出入口（**主线程**）：只收集数据 + 起线程，立刻返回 -> 界面不卡
func _do_export_to(parts: Array, idxs: Array, tag: String, base_dir: String) -> void:
	if source_path == "" or idxs.is_empty() or base_dir == "":
		return
	if _thread != null:
		_status.text = "上一次导出还在进行中，请稍候…"
		return
	var use_gltf: bool = _gltf_chk != null and _gltf_chk.button_pressed
	var tex_on: bool = _tex_chk != null and _tex_chk.button_pressed
	var base := source_path.get_file().get_basename()
	var items: Array = []
	for n in idxs:
		if int(n) < 0 or int(n) >= parts.size():
			continue
		var d: Dictionary = parts[int(n)]
		items.append({
			"mesh": d["mesh"],
			"center": d["center"],
			"name": "%s_%02d" % [base, int(n) + 1],
		})
	if items.is_empty():
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base_dir))
	_export_job = {
		"items": items,
		"base_dir": base_dir,
		"tag": tag,
		"use_gltf": use_gltf,
		"plain": (not use_gltf) and (not tex_on),
		"src_dir": source_path.get_base_dir(),
		"use_res": _res_chk != null and _res_chk.button_pressed,
	}
	_export_result = {}
	_begin_busy("导出中…（后台线程，界面可以继续用）")
	_thread = Thread.new()
	var err := _thread.start(Callable(self, "_export_worker"))
	if err != OK:
		_thread = null
		_end_busy()
		_status.text = "启动导出线程失败（错误码 %d）" % err
		return
	set_process(true)


## 【子线程】真正干活：**离树**建节点 + 挂 owner 链 + 写文件 + 改指贴图 + 搬文件 + 清理
## 规矩：这里绝不碰场景树、绝不碰 UI 成员（只读 _export_job，只写 _export_result）
## 依据：实测离树（不进场景树）+ 手动 owner 也能导出成功 -> 可以安全地放子线程
func _export_worker() -> void:
	var job := _export_job
	var items: Array = job["items"]
	var base_dir := String(job["base_dir"])
	var use_gltf := bool(job["use_gltf"])
	var plain := bool(job["plain"])
	var src_dir := String(job["src_dir"])
	var use_res := bool(job.get("use_res", false))
	var ext: String = ".gltf" if use_gltf else ".glb"
	var tmp_dir := "res://.glb_split_tmp"
	var write_dir := base_dir
	if use_gltf and not use_res:
		_wipe_dir(ProjectSettings.globalize_path(tmp_dir))
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(tmp_dir))
		write_dir = tmp_dir
	var ok := 0
	var res_ok := 0
	for it in items:
		var d: Dictionary = it
		var nm := String(d["name"])
		var mi := MeshInstance3D.new()
		mi.name = nm
		mi.mesh = d["mesh"]
		# ★ 节点留在**原点**：分块网格顶点本来就按自身 AABB 中心归零了 ✓，
		#   再设 position = center 会让独立件的原点偏离模型中心（用户反馈"模型中心位置不对"）。
		#   现在导出结果 = 模型中心对正原点，摆进场景就是正的 ✓
		if use_res:
			# ★ Godot 资源模式：不写 glTF，直接存 .res 网格 + .tscn 场景
			#   材质改用"指向项目原有贴图"的新材质 -> .res 里不会内嵌贴图副本，拖进场景即带贴图
			var m2 := (d["mesh"] as ArrayMesh)
			if m2 == null:
				continue
			var mesh2: ArrayMesh = m2.duplicate() as ArrayMesh
			if mesh2 == null:
				continue
			_relink_material_textures(mesh2, src_dir)
			var rp := base_dir.path_join(nm + ".res")
			if ResourceSaver.save(mesh2, rp) == OK:
				mesh2.take_over_path(rp)
				ok += 1
			var root := Node3D.new()
			root.name = nm
			var mi3 := MeshInstance3D.new()
			mi3.name = nm
			mi3.mesh = mesh2
			root.add_child(mi3)
			mi3.owner = root
			var ps := PackedScene.new()
			if ps.pack(root) == OK:
				if ResourceSaver.save(ps, base_dir.path_join(nm + ".tscn")) == OK:
					res_ok += 1
			root.free()
			continue
		if plain:
			var mm := d["mesh"] as Mesh
			if mm != null:
				for si in range(mm.get_surface_count()):
					mi.set_surface_override_material(si, _plain_material(mm.surface_get_material(si)))
		var holder := Node3D.new()
		holder.name = nm + "_export_root"
		holder.add_child(mi)
		# 关键一步（和 addons/glb_tools/glb_export.gd 那条注释同一个坑）：
		#   glTF 导出器靠 owner 链判断"属于同一个场景"，不挂 owner 会导出成空文件
		_own_all(holder)
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		doc.append_from_scene(holder, st)
		if doc.write_to_filesystem(st, write_dir.path_join(nm + ext)) == OK:
			ok += 1
			if use_gltf:
				_relink_gltf_textures(write_dir.path_join(nm + ext), base_dir, src_dir)
		elif ResourceSaver.save(d["mesh"], base_dir.path_join(nm + ".res")) == OK:
			res_ok += 1
		holder.free()
	if use_gltf:
		_move_out(write_dir, base_dir)
		_wipe_dir(ProjectSettings.globalize_path(tmp_dir))
	_export_result = {"ok": ok, "res_ok": res_ok, "use_gltf": use_gltf,
			"base_dir": base_dir, "tag": String(job["tag"])}


## 【主线程】轮询：线程还在跑就返回；跑完 join 并刷新界面（由 _process 驱动）
func _poll_export() -> void:
	if _thread == null:
		set_process(false)
		return
	if _thread.is_alive():
		return
	_thread.wait_to_finish()
	_thread = null
	set_process(false)
	_end_busy()
	var r := _export_result
	_export_result = {}
	if r.is_empty():
		_status.text = "导出线程没有返回结果。"
		return
	var fs := EditorInterface.get_resource_filesystem() if Engine.is_editor_hint() else null
	if fs != null:
		fs.scan()
	var use_gltf := bool(r["use_gltf"])
	var tex_on: bool = _tex_chk != null and _tex_chk.button_pressed
	var mode := "gltf + 复用项目原贴图（零新增贴图）" if use_gltf else ("glb + 内嵌贴图（大、慢）" if tex_on else "glb + 纯色（小、快）")
	_status.text = "导出%s完成：%d 个文件，res 兜底 %d 个 ｜ 模式：%s -> %s" % [
			String(r["tag"]), int(r["ok"]), int(r["res_ok"]), mode, String(r["base_dir"])]


func _process(_delta: float) -> void:
	if _thread != null:
		_poll_export()

@tool
extends Window
## GLB 预览 / 选择性导出窗口 v3
##
## 尺寸：屏幕的 80%（跟 Godot 原版对话框一致）
## 布局：左树（勾选/搜索/详情） | 右 3D 预览（可轨道操作、可点选节点）
## 交互：左键拖拽=旋转，右键/中键拖拽=平移，滚轮=缩放，**单击=点选节点（不高亮不移动镜头之外什么都不做）**
## 导出：合并成 1 个文件 / 每个节点单独一个文件

const GlbExport := preload("res://addons/glb_tools/glb_export.gd")
const Decimate := preload("res://addons/glb_tools/decimate.gd")

const DEFAULT_DIR := "res://assets/models/exported"
const SCREEN_RATIO := 0.8
## 导出确认框的启动器。**运行时 load**，不用 preload：open_dialog.gd 已经 preload 了本脚本，
## 反向再 preload 会形成循环引用
const LAUNCHER := "res://addons/glb_tools/open_dialog.gd"

var _path := ""
var _preview_root: Node3D = null
var _tree: Tree
var _viewport: SubViewport
var _camera: Camera3D
var _path_edit: LineEdit
var _path_preview: Label
var _keep_world: CheckBox
var _status: Label
var _details: Label
var _path_label: Label
var _search: LineEdit
var _props: Tree                          # 右侧只读属性面板
var _node_menu: PopupMenu                 # 节点树右键菜单
var _wire_check: CheckButton              # 显示三角网格（线框）
var _weld_check: CheckButton              # 导出后 weld 压顶点
var _plain_export := false                # 本次导出是否跳过 weld（精确模式自己已经压过）
var _last_reduction := 1.0                # 上一次精确降模的实际比例（用来如实校验）
var _ratio_timer: Timer = null            # 滑块节流用
var _pending_ratio := -1.0                # 待应用的（节流期间只记最新值）
var _apply_count := 0                     # 实际应用了几次（下拉测试用）
var _ratio_slider: HSlider                # 降模比例 1~100
var _ratio_spin: SpinBox
var _ratio_label: Label
var _lod_cache := {}                      # 节点 -> LOD 阶梯（缓存，拖动时不用重算）
var _originals := {}                      # 节点 -> 原始网格（还原用）
var _decim_thread: Thread = null
var _decim_result := {}
var _pending_node: Node = null            # 右键点到的那个节点
var _highlight_boxes: Array = []          # 被勾选节点的蓝色线框（可多个同时高亮）
var _picker_in: EditorFileDialog
var _picker_out: EditorFileDialog

# 写死的配色：不跟随主题，免得在某些主题下发蓝、字看不清
const BG_GRAY := Color(0.157, 0.157, 0.165)     # 窗口底色（深灰）
const PREVIEW_BG := Color(0.196, 0.196, 0.208)  # 预览区底色（稍浅的灰）
const TEXT_COLOR := Color(0.86, 0.86, 0.88)     # 文字色（浅灰）
const CHECK_BLUE := Color(0.25, 0.62, 1.0)      # 被**勾选**的节点：蓝色线框（这些会被导出）
const CLICK_ORANGE := Color(1.0, 0.55, 0.1)     # 被**点击**的节点：橙色线框（当前看的这个）

# 轨道相机状态
var _yaw := 0.75
var _pitch := 0.45
var _distance := 4.0
var _target := Vector3.ZERO
var _dragging := false
var _drag_button := MOUSE_BUTTON_LEFT
var _drag_moved := false
var _press_at := Vector2.ZERO


func _init() -> void:
	title = "GLB 预览 / 导出部分节点"
	# 尺寸取当前屏幕的 80%（之前写死 1280×820，用户反馈太小）
	var screen := DisplayServer.screen_get_size()
	size = Vector2i(int(screen.x * SCREEN_RATIO), int(screen.y * SCREEN_RATIO))
	min_size = Vector2i(900, 600)
	close_requested.connect(queue_free)

	# 窗口底色：**写死灰色**，不跟随主题（用户反馈主题色在某些情况下仍发蓝）
	var ed_theme := EditorInterface.get_editor_theme()
	if ed_theme != null:
		theme = ed_theme
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	if ed_theme != null:
		panel.theme = ed_theme        # 控件上再设一次：Window 层的主题传播不一定生效
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG_GRAY
	sb.set_corner_radius_all(3)
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	margin.add_child(vb)

	# ---- 顶栏 ----
	var top := HBoxContainer.new()
	var lab := Label.new()
	lab.text = "文件"
	top.add_child(lab)
	_path_label = Label.new()
	_path_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_label.clip_text = true
	top.add_child(_path_label)
	var open_btn := Button.new()
	open_btn.text = "打开 .glb…"
	open_btn.pressed.connect(_on_pick_glb)
	top.add_child(open_btn)
	var big_btn := Button.new()
	big_btn.text = "放大 / 还原"
	big_btn.tooltip_text = "在屏幕 80% 和 95% 之间切换"
	big_btn.pressed.connect(_toggle_big)
	top.add_child(big_btn)
	vb.add_child(top)

	# ---- 中间 ----
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.split_offset = 420
	vb.add_child(split)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(320, 0)
	left.add_theme_constant_override("separation", 4)
	split.add_child(left)

	_search = LineEdit.new()
	_search.placeholder_text = "搜索节点名…"
	_search.clear_button_enabled = true
	_search.text_changed.connect(_apply_filter)
	left.add_child(_search)

	var tools := HBoxContainer.new()
	for spec in [["全选", 1], ["全不选", 0], ["反选", 2]]:
		var b := Button.new()
		b.text = String(spec[0])
		b.pressed.connect(_on_check_tool.bind(int(spec[1])))
		tools.add_child(b)
	left.add_child(tools)

	_tree = Tree.new()
	# 三列：第 0 列只放勾选框（窄、无文字），第 1 列才是节点名 —— 这样"点名字"只选中/高亮，
	# 不会像以前那样连带把勾选也切了（Godot 的 CHECK 单元格整格可点，只能靠拆列分开）
	_tree.columns = 3
	_tree.set_column_title(0, "")
	_tree.set_column_title(1, "节点")
	_tree.set_column_title(2, "信息")
	_tree.column_titles_visible = true
	_tree.set_column_expand(0, false)
	_tree.set_column_custom_minimum_width(0, 36)
	_tree.set_column_expand(1, true)
	_tree.set_column_expand(2, false)
	_tree.set_column_custom_minimum_width(2, 150)
	_tree.select_mode = Tree.SELECT_ROW
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_edited.connect(_on_item_edited)   # 勾选框被点也要刷新高亮
	_tree.gui_input.connect(_on_tree_input)      # 右键 → 导出菜单
	left.add_child(_tree)

	_node_menu = PopupMenu.new()
	_node_menu.add_item("导出此节点为 GLB…", 0)
	_node_menu.add_item("导出勾选的节点…", 1)
	_node_menu.add_separator()
	_node_menu.add_item("聚焦此节点", 2)
	_node_menu.id_pressed.connect(_on_node_menu)
	add_child(_node_menu)

	_details = Label.new()
	_details.clip_text = true
	_details.add_theme_font_size_override("font_size", 11)
	left.add_child(_details)

	# 右侧再拆一层：左=3D 预览，右=只读属性面板（参考原版"高级导入设置"的布局）
	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_split.split_offset = 560
	split.add_child(right_split)

	var vbc := SubViewportContainer.new()
	vbc.stretch = true
	vbc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbc.mouse_filter = Control.MOUSE_FILTER_STOP
	vbc.gui_input.connect(_on_view_input)
	right_split.add_child(vbc)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	_viewport.gui_disable_input = true
	_viewport.size = Vector2i(900, 700)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vbc.add_child(_viewport)

	var prop_box := VBoxContainer.new()
	prop_box.custom_minimum_size = Vector2(300, 0)
	prop_box.add_theme_constant_override("separation", 4)
	right_split.add_child(prop_box)
	var prop_title := Label.new()
	prop_title.text = "节点属性（只读）"
	prop_box.add_child(prop_title)
	_props = Tree.new()
	_props.columns = 2
	_props.set_column_title(0, "属性")
	_props.set_column_title(1, "值")
	_props.column_titles_visible = true
	_props.select_mode = Tree.SELECT_ROW
	_props.hide_root = true
	_props.size_flags_vertical = Control.SIZE_EXPAND_FILL
	prop_box.add_child(_props)

	# ---- 底部 ----
	# ---- 降模 ----
	var drow := HBoxContainer.new()
	drow.add_theme_constant_override("separation", 6)
	var dlab := Label.new()
	dlab.text = "降模比例"
	drow.add_child(dlab)
	_ratio_slider = HSlider.new()
	_ratio_slider.min_value = 1
	_ratio_slider.max_value = 100
	_ratio_slider.step = 1
	_ratio_slider.value = 100
	_ratio_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ratio_slider.custom_minimum_size = Vector2(240, 0)
	_ratio_slider.tooltip_text = "拖动即时预览（用 Godot 内置 LOD 阶梯，毫秒级）；要精确比例点右边按钮"
	_ratio_slider.value_changed.connect(_on_ratio_changed)
	drow.add_child(_ratio_slider)
	_ratio_spin = SpinBox.new()
	_ratio_spin.min_value = 1
	_ratio_spin.max_value = 100
	_ratio_spin.step = 1
	_ratio_spin.value = 100
	_ratio_spin.suffix = "%"
	_ratio_spin.value_changed.connect(func(v: float) -> void:
		if not is_equal_approx(_ratio_slider.value, v):
			_ratio_slider.value = v)
	drow.add_child(_ratio_spin)
	var back_btn := Button.new()
	back_btn.text = "还原 100%"
	back_btn.pressed.connect(func() -> void: _ratio_slider.value = 100)
	drow.add_child(back_btn)
	var exact_btn := Button.new()
	exact_btn.text = "精确降模（较慢）"
	exact_btn.tooltip_text = "任意 1~100% 精确比例，保留 UV/法线/材质；走后台线程，几秒钟"
	exact_btn.pressed.connect(_on_exact_decimate)
	drow.add_child(exact_btn)
	vb.add_child(drow)

	_ratio_label = Label.new()
	_ratio_label.clip_text = true
	_ratio_label.add_theme_font_size_override("font_size", 11)
	vb.add_child(_ratio_label)

	var row := HBoxContainer.new()
	var olab := Label.new()
	olab.text = "输出到"
	row.add_child(olab)
	_path_edit = LineEdit.new()
	_path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_path_edit.text_changed.connect(func(_t: String) -> void: _update_path_preview())
	row.add_child(_path_edit)
	var browse := Button.new()
	browse.text = "浏览…"
	browse.pressed.connect(_on_browse_out)
	row.add_child(browse)
	vb.add_child(row)

	_path_preview = Label.new()
	_path_preview.add_theme_font_size_override("font_size", 11)
	_path_preview.clip_text = true
	vb.add_child(_path_preview)

	var row2 := HBoxContainer.new()
	_keep_world = CheckBox.new()
	_keep_world.text = "保持世界变换"
	_keep_world.button_pressed = true
	row2.add_child(_keep_world)
	var export_btn := Button.new()
	export_btn.text = "导出勾选（合并成 1 个文件）"
	export_btn.pressed.connect(_on_export.bind(false))
	row2.add_child(export_btn)
	_weld_check = CheckButton.new()
	_weld_check.text = "导出后 weld 压顶点"
	_weld_check.button_pressed = true
	_weld_check.tooltip_text = "Godot 的 LOD 只换索引表、不动顶点表，导出的 glb 体积降不下来；勾上就再过一遍 weld 把重复/未引用顶点删掉（约 2~4 秒）"
	row2.add_child(_weld_check)
	var split_btn := Button.new()
	split_btn.text = "每个节点单独一个文件"
	split_btn.pressed.connect(_on_export.bind(true))
	row2.add_child(split_btn)
	var focus_btn := Button.new()
	focus_btn.text = "聚焦选中节点"
	focus_btn.tooltip_text = "只有点这个（或复位视角）才会移动镜头；点树/点模型只更新信息，不跳视角"
	focus_btn.pressed.connect(func() -> void:
		var n := _selected_node()
		if n != null and n is Node3D:
			_refit(n))
	row2.add_child(focus_btn)
	var reset_btn := Button.new()
	reset_btn.text = "复位视角"
	reset_btn.pressed.connect(func() -> void: _refit(_preview_root))
	row2.add_child(reset_btn)
	# 显示三角网格：用 Viewport 自带的线框调试绘制（一行开关，不用给每个网格换材质）
	_wire_check = CheckButton.new()
	_wire_check.text = "显示三角网格"
	_wire_check.tooltip_text = "切换线框显示，方便看三角面密度（降模时对着看很直观）"
	_wire_check.toggled.connect(_on_wireframe_toggled)
	row2.add_child(_wire_check)
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	row2.add_child(_status)
	vb.add_child(row2)

	# 文字颜色写死浅灰，主题再怎么变都看得清
	# 滑块节流：拖动时不要每动一格就重算。首次要构建整模型的 LOD 阶梯（可能几秒），
	# 重算太频繁会卡；但也不能纯延迟否则手感发木 —— 所以"立刻应用一次 + 之后限频"。
	_ratio_timer = Timer.new()
	_ratio_timer.one_shot = true
	_ratio_timer.wait_time = 0.12
	_ratio_timer.timeout.connect(_apply_pending_ratio)
	add_child(_ratio_timer)

	_paint_text(panel)

# ------------------------------------------------------------------ 加载

func load_glb(path: String) -> void:
	_path = path
	_path_label.text = path
	_clear_preview()
	if path.is_empty() or not ResourceLoader.exists(path):
		_status.text = "打不开：%s" % path
		return
	var ps: PackedScene = load(path)
	if ps == null:
		_status.text = "加载失败（不是场景类资源？）：%s" % path
		return
	_preview_root = Node3D.new()
	_preview_root.name = "Preview"
	_viewport.add_child(_preview_root)
	_preview_root.add_child(ps.instantiate())
	_add_lights()
	_add_camera()
	_rebuild_tree()
	_refit(_preview_root)
	_rebuild_highlights()

	# 默认固定输出到 res://assets/models/exported（用户要求不要变）
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DEFAULT_DIR))
	_path_edit.text = "%s/%s_部分.glb" % [DEFAULT_DIR, path.get_file().get_basename()]
	_update_path_preview()
	_status.text = "左键拖拽旋转 / 右键拖拽平移 / 滚轮缩放；单击模型可选中节点（不跳视角）"


func _clear_preview() -> void:
	if _preview_root != null and is_instance_valid(_preview_root):
		_viewport.remove_child(_preview_root)
		_preview_root.free()
	_preview_root = null
	_camera = null
	for h in _highlight_boxes:
		if h != null and is_instance_valid(h):
			h.queue_free()
	_highlight_boxes.clear()
	_tree.clear()
	_details.text = ""
	if _props != null:
		_props.clear()
	for c in _viewport.get_children():
		_viewport.remove_child(c)
		c.free()


func _add_lights() -> void:
	# 预览区底色也写死灰色（之前读编辑器 3D 视口清屏色，用户主题下仍偏蓝）
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = PREVIEW_BG
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.5
	# 用 LINEAR，不用 Filmic：Filmic 会把过亮的地方推向蓝紫，模型看着发蓝（实测截图确认过）
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.tonemap_white = 1.0
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42, 38, 0)
	key.light_energy = 0.9
	key.light_specular = 0.0          # 关掉高光：模型带法线贴图时，强高光会泛蓝紫
	key.shadow_enabled = true
	_viewport.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-16, -125, 0)
	fill.light_energy = 0.35
	fill.light_specular = 0.0
	_viewport.add_child(fill)


func _add_camera() -> void:
	_camera = Camera3D.new()
	_camera.fov = 42.0
	_viewport.add_child(_camera)
	_camera.make_current()


# ------------------------------------------------------------------ 节点树

func _rebuild_tree() -> void:
	_tree.clear()
	if _preview_root == null:
		return
	var root_item: TreeItem = _tree.create_item()
	root_item.set_text(1, _path.get_file())   # 根行是文件名，放名字列
	root_item.set_metadata(0, _preview_root)
	for c in _preview_root.get_children():
		_fill(root_item, c)
	if _search != null:
		_apply_filter(_search.text)


func _fill(parent_item: TreeItem, n: Node) -> void:
	var info := n.get_class()
	var checkable := false
	if n is MeshInstance3D:
		var m: Mesh = (n as MeshInstance3D).mesh
		if m != null:
			info = "MeshInstance3D  %d 面" % _tri_count(m)
			checkable = true
	elif n is Node3D:
		info = "Node3D"
	# TreeItem 加子项用 create_child()；create_item() 是 Tree 上的方法
	var item: TreeItem = parent_item.create_child()
	item.set_metadata(0, n)
	if checkable:
		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)   # 勾选框独占第 0 列
		item.set_editable(0, true)
		item.set_checked(0, false)
	# 名字放第 1 列：点它不会触发勾选（第 0 列那种整格可点的副作用）
	item.set_text(1, n.name)
	item.set_text(2, info)
	for c in n.get_children():
		_fill(item, c)


func _tri_count(m: Mesh) -> int:
	var tris := 0
	for i in m.get_surface_count():
		var idx_len := 0
		var vtx_len := 0
		if m is ArrayMesh:
			var am := m as ArrayMesh
			idx_len = am.surface_get_array_index_len(i)
			vtx_len = am.surface_get_array_len(i)
		tris += (idx_len / 3) if idx_len > 0 else (vtx_len / 3)
	return tris


func _on_check_tool(mode: int) -> void:
	var item: TreeItem = _tree.get_root()
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			if mode == 2 and item.visible:
				item.set_checked(0, not item.is_checked(0))
			elif mode != 2:
				item.set_checked(0, mode == 1)
		item = item.get_next_in_tree()
	_status.text = ["已全部取消", "已全部勾选", "已反选（仅当前可见项）"][mode]
	_rebuild_highlights()


func _checked_nodes() -> Array:
	var out: Array = []
	var item: TreeItem = _tree.get_root()
	while item != null:
		if item.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK and item.is_checked(0):
			var n = item.get_metadata(0)
			if n is Node and is_instance_valid(n):
				out.append(n)
		item = item.get_next_in_tree()
	return out


func _selected_node() -> Node:
	var item := _tree.get_selected()
	if item == null:
		return null
	var n = item.get_metadata(0)
	return n if n is Node else null


func _apply_filter(text: String) -> void:
	var root: TreeItem = _tree.get_root()
	if root == null:
		return
	var needle := text.strip_edges().to_lower()
	for c in root.get_children():
		_filter_item(c, needle)


func _filter_item(item: TreeItem, needle: String) -> bool:
	var self_match := needle.is_empty() or String(item.get_text(1)).to_lower().contains(needle)
	var child_match := false
	for c in item.get_children():
		if _filter_item(c, needle):
			child_match = true
	item.set_visible(self_match or child_match)
	return self_match or child_match


## 点树：只更新详情 + 高亮，**不动镜头**（用户明确要求别跳来跳去）
func _on_item_selected() -> void:
	var n := _selected_node()
	if n == null:
		return
	_details.text = _describe(n)
	_update_props(n)
	_rebuild_highlights()      # 点名字 → 对应模型高亮（橙色）。注意：不动镜头


func _describe(n: Node) -> String:
	var parts := PackedStringArray([String(n.name), n.get_class()])
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var mi := n as MeshInstance3D
		var m: Mesh = mi.mesh
		var verts := 0
		var mats := 0
		for i in m.get_surface_count():
			if m is ArrayMesh:
				verts += (m as ArrayMesh).surface_get_array_len(i)
			if mi.get_active_material(i) != null:
				mats += 1
		parts.append("%d 面 / %d 顶点 / %d 材质" % [_tri_count(m), verts, mats])
	if n is VisualInstance3D:
		var b: AABB = (n as VisualInstance3D).get_aabb()
		parts.append("尺寸 %.2f×%.2f×%.2f" % [b.size.x, b.size.y, b.size.z])
	return " · ".join(parts)


## 把树里的选中项切到某个节点（3D 里点选时用），并展开它的父级
func _select_node_in_tree(n: Node) -> void:
	var item: TreeItem = _tree.get_root()
	while item != null:
		if item.get_metadata(0) == n:
			var p := item.get_parent()
			while p != null:
				p.set_collapsed(false)
				p = p.get_parent()
			_tree.set_selected(item, 1)     # 选中光标落在名字列
			_tree.ensure_cursor_is_visible()
			_on_item_selected()
			return
		item = item.get_next_in_tree()


# ------------------------------------------------------------------ 高亮

func _on_item_edited() -> void:
	# 勾选框被点：立刻重画高亮
	_rebuild_highlights()


## 高亮分两种颜色：
##   被**勾选**的节点 → 蓝色线框（表示"这些会被导出"）
##   被**点击**的节点 → 橙色线框（表示"当前看的这个"）
## 一个节点同时被勾选又被点击时：**勾选（蓝色）优先**（用户要求）。
func _rebuild_highlights() -> void:
	for h in _highlight_boxes:
		if h != null and is_instance_valid(h):
			h.queue_free()
	_highlight_boxes.clear()
	if _preview_root == null:
		return
	var done := {}
	# 先画勾选的（蓝色）：同时被点击时以它为准
	for n in _checked_nodes():
		if n is VisualInstance3D:
			var hb := _make_highlight(n, CHECK_BLUE)
			if hb != null:
				_highlight_boxes.append(hb)
				done[n] = true
	var sel := _selected_node()
	if sel != null and sel is VisualInstance3D and not done.has(sel):
		var hs := _make_highlight(sel, CLICK_ORANGE)
		if hs != null:
			_highlight_boxes.append(hs)


## 一个高亮 = 包围盒的 12 条棱，用 PRIMITIVE_LINES 画。
## 用 LINE 而不是实心细条，是为了**恒定 1 像素线宽**：Godot 画线不随缩放改变粗细，
## 用户明确要求"无论什么缩放恒定 1px"。之前用实心细条（想调粗细）反而做不到恒定。
func _make_highlight(n: Node, color: Color) -> Node3D:
	if not (n is VisualInstance3D):
		return null
	var vi := n as VisualInstance3D
	var box: AABB = vi.global_transform * vi.get_aabb()
	box = box.grow(0.002)                     # 稍微放大，免得和模型面 z-fighting 闪
	var p := box.position
	var q := box.position + box.size
	var corner := [
		Vector3(p.x, p.y, p.z), Vector3(q.x, p.y, p.z), Vector3(q.x, q.y, p.z), Vector3(p.x, q.y, p.z),
		Vector3(p.x, p.y, q.z), Vector3(q.x, p.y, q.z), Vector3(q.x, q.y, q.z), Vector3(p.x, q.y, q.z)]
	var pts := PackedVector3Array()
	for edge in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		pts.append(corner[edge[0]])
		pts.append(corner[edge[1]])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.no_depth_test = true                  # 被模型挡住也能看见
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var mi := MeshInstance3D.new()
	mi.mesh = am
	mi.material_override = mat
	var holder := Node3D.new()
	holder.name = "Highlight"
	holder.add_child(mi)
	_viewport.add_child(holder)
	return holder

## 递归把 Label 的文字色写死（主题可能给深色字，配深灰底看不清）
func _paint_text(node: Node) -> void:
	if node is Label:
		(node as Label).add_theme_color_override("font_color", TEXT_COLOR)
	for c in node.get_children():
		_paint_text(c)


# ------------------------------------------------------------------ 点选

## 从相机往鼠标位置打一条射线，找出最近的网格节点
func _pick_node(origin: Vector3, dir: Vector3) -> Node3D:
	var best: Node3D = null
	var best_t := INF
	var stack: Array = [_preview_root]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D and (cur as MeshInstance3D).mesh != null:
			var mi := cur as MeshInstance3D
			var box: AABB = mi.global_transform * mi.get_aabb()
			# AABB.intersects_ray 返回 Vector3 或 null，不是 bool
			var hit = box.intersects_ray(origin, dir)
			if typeof(hit) == TYPE_VECTOR3 or (typeof(hit) == TYPE_BOOL and bool(hit)):
				var t := _ray_mesh_hit(mi, origin, dir)
				if t > 0.0 and t < best_t:
					best_t = t
					best = mi
		for c in cur.get_children():
			stack.append(c)
	return best


## 与网格三角形精确求交（Möller–Trumbore），返回距离；无交返回 -1
func _ray_mesh_hit(mi: MeshInstance3D, origin: Vector3, dir: Vector3) -> float:
	var mesh: Mesh = mi.mesh
	if mesh == null:
		return -1.0
	var inv := mi.global_transform.affine_inverse()
	var o := inv * origin
	var d := (inv.basis * dir).normalized()
	var best := INF
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var tris := (idx.size() / 3) if idx.size() > 0 else (verts.size() / 3)
		for t in tris:
			var a: Vector3
			var b: Vector3
			var c: Vector3
			if idx.size() > 0:
				a = verts[idx[t * 3]]
				b = verts[idx[t * 3 + 1]]
				c = verts[idx[t * 3 + 2]]
			else:
				a = verts[t * 3]
				b = verts[t * 3 + 1]
				c = verts[t * 3 + 2]
			var tt := _ray_tri(o, d, a, b, c)
			if tt > 0.0 and tt < best:
				best = tt
	return best if best < INF else -1.0


func _ray_tri(o: Vector3, d: Vector3, a: Vector3, b: Vector3, c: Vector3) -> float:
	var e1 := b - a
	var e2 := c - a
	var pv := d.cross(e2)
	var det := e1.dot(pv)
	if absf(det) < 1e-12:
		return -1.0
	var inv_det := 1.0 / det
	var tv := o - a
	var u := tv.dot(pv) * inv_det
	if u < 0.0 or u > 1.0:
		return -1.0
	var qv := tv.cross(e1)
	var v := d.dot(qv) * inv_det
	if v < 0.0 or u + v > 1.0:
		return -1.0
	var tt := e2.dot(qv) * inv_det
	return tt if tt > 1e-6 else -1.0


func _click_pick(at: Vector2) -> void:
	if not is_instance_valid(_camera) or _preview_root == null:
		return
	var from := _camera.project_ray_origin(at)
	var dir := _camera.project_ray_normal(at)
	var hit := _pick_node(from, dir)
	if hit == null:
		_status.text = "这里没有模型（点模型上任意位置）"
		return
	_select_node_in_tree(hit)
	_rebuild_highlights()
	_status.text = "已选中：%s（橙色线框就是它；勾选看左边的小方框）" % hit.name


# ------------------------------------------------------------------ 相机

func _refit(target: Node) -> void:
	if not is_instance_valid(_camera):
		return
	var box := _subtree_aabb(target)
	if box.size.length() < 0.001:
		box = AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
	_target = box.get_center()
	_distance = maxf(box.size.length() * 1.4, 0.8)
	_update_camera()


func _update_camera() -> void:
	if not is_instance_valid(_camera):
		return
	_pitch = clampf(_pitch, -1.5, 1.5)
	var dir := Vector3(cos(_pitch) * sin(_yaw), sin(_pitch), cos(_pitch) * cos(_yaw))
	_camera.position = _target + dir * _distance
	_camera.look_at(_target, Vector3.UP)
	_camera.near = maxf(_distance * 0.005, 0.01)
	_camera.far = maxf(_distance * 60.0, 100.0)


func _toggle_big() -> void:
	var screen := DisplayServer.screen_get_size()
	var ratio := 0.95 if size.x < int(screen.x * 0.88) else SCREEN_RATIO
	size = Vector2i(int(screen.x * ratio), int(screen.y * ratio))
	position = (screen - size) / 2


func _on_view_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if mb.pressed:
					_distance = maxf(_distance * 0.9, 0.05)
					_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if mb.pressed:
					_distance = minf(_distance * 1.1, 100000.0)
					_update_camera()
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE, MOUSE_BUTTON_RIGHT:
				if mb.pressed:
					_dragging = true
					_drag_button = mb.button_index
					_drag_moved = false
					_press_at = mb.position
				else:
					var was_click := _dragging and not _drag_moved and mb.button_index == MOUSE_BUTTON_LEFT
					_dragging = false
					if was_click:
						_click_pick(mb.position)       # 单击（没拖动）才点选
	elif ev is InputEventMouseMotion and _dragging:
		var mm := ev as InputEventMouseMotion
		if mm.relative.length() > 2.0:
			_drag_moved = true
		if _drag_button == MOUSE_BUTTON_LEFT:
			_yaw -= mm.relative.x * 0.01
			_pitch += mm.relative.y * 0.01
		elif is_instance_valid(_camera):
			var basis := _camera.global_transform.basis
			var k := _distance * 0.0015
			_target -= basis.x * mm.relative.x * k
			_target += basis.y * mm.relative.y * k
		_update_camera()


func _subtree_aabb(n: Node) -> AABB:
	var box := AABB()
	var first := true
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is VisualInstance3D:
			var vi := cur as VisualInstance3D
			var b: AABB = vi.global_transform * vi.get_aabb()
			if first:
				box = b
				first = false
			else:
				box = box.merge(b)
		for c in cur.get_children():
			stack.append(c)
	return box


# ------------------------------------------------------------------ 导出


func _update_path_preview() -> void:
	var p := _path_edit.text.strip_edges()
	if p.is_empty():
		_path_preview.text = "（还没填输出路径）"
		return
	var abs := p
	if p.begins_with("res://") or p.begins_with("user://"):
		abs = ProjectSettings.globalize_path(p)
	_path_preview.text = "实际写入：%s" % abs


func _sanitize(s: String) -> String:
	var out := ""
	for ch in s:
		out += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch == "-" or ch == "_") else "_"
	return out if not out.is_empty() else "node"


func _on_pick_glb() -> void:
	if _picker_in == null:
		_picker_in = EditorFileDialog.new()
		_picker_in.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
		_picker_in.access = EditorFileDialog.ACCESS_RESOURCES
		_picker_in.add_filter("*.glb", "glTF 二进制")
		_picker_in.file_selected.connect(func(p: String) -> void: load_glb(p))
		add_child(_picker_in)
	_picker_in.current_path = _path
	_picker_in.popup_centered_ratio(0.6)


func _on_browse_out() -> void:
	if _picker_out == null:
		_picker_out = EditorFileDialog.new()
		_picker_out.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
		_picker_out.access = EditorFileDialog.ACCESS_RESOURCES
		_picker_out.add_filter("*.glb", "glTF 二进制")
		_picker_out.file_selected.connect(func(p: String) -> void: _path_edit.text = p)
		add_child(_picker_out)
	_picker_out.current_path = _path_edit.text
	_picker_out.popup_centered_ratio(0.6)


func _refresh_fs(path: String) -> void:
	if not path.begins_with("res://"):
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null:
		fs.update_file(path)
		fs.scan()


func _on_export(split: bool) -> void:
	var picked := _checked_nodes()
	if picked.is_empty():
		_status.text = "先在左边勾选要导出的节点"
		return
	var path := _path_edit.text.strip_edges()
	if path.is_empty():
		_status.text = "先填输出路径"
		return
	if not path.to_lower().ends_with(".glb"):
		path += ".glb"
	var keep := _keep_world.button_pressed
	var dir := path.get_base_dir()          # 注意是 get_base_dir()，没有 get_base_path() 这个方法

	if not split:
		var res: Dictionary = GlbExport.export_nodes(picked, path, keep)
		_status.text = str(res.get("message", res))
		if bool(res.get("ok", false)):
			_refresh_fs(path)
			# Godot 的 LOD 只换索引表、不动顶点表：导出后再 weld 一遍，体积才真的变小
			if _weld_check != null and _weld_check.button_pressed and not _plain_export \
					and _ratio_slider != null and _ratio_slider.value < 99.5:
				_start_weld(path)
		return

	var stem := path.get_file().get_basename()
	var done := 0
	var failed := 0
	var last := ""
	for n in picked:
		var one := "%s/%s_%s.glb" % [dir, stem, _sanitize(String((n as Node).name))]
		var res: Dictionary = GlbExport.export_nodes([n], one, keep)
		if bool(res.get("ok", false)):
			done += 1
			last = one
			_refresh_fs(one)
		else:
			failed += 1
	_status.text = ("拆分导出：成功 %d 个 / 失败 %d 个%s"
			% [done, failed, ("，例如 " + last) if not last.is_empty() else ""])


# ------------------------------------------------------------------ 右侧属性面板（只读）

func _update_props(n: Node) -> void:
	if _props == null:
		return
	_props.clear()
	if n == null or not is_instance_valid(n):
		return
	var root: TreeItem = _props.create_item()
	_props_row(root, "名称", String(n.name))
	_props_row(root, "类型", n.get_class())
	if _preview_root != null and n.is_inside_tree():
		_props_row(root, "层级路径", String(_preview_root.get_path_to(n)))
	_props_row(root, "子节点数", str(n.get_child_count()))
	_props_row(root, "所属场景", n.scene_file_path if not n.scene_file_path.is_empty() else "（当前场景内）")

	if n is Node3D:
		var t3 := n as Node3D
		var gt := _props_group(root, "变换")
		_props_row(gt, "位置", _v3(t3.position))
		_props_row(gt, "旋转(度)", _v3(t3.rotation_degrees))
		_props_row(gt, "缩放", _v3(t3.scale))
		_props_row(gt, "世界位置", _v3(t3.global_position))

	if n is VisualInstance3D:
		var vi := n as VisualInstance3D
		var gv := _props_group(root, "可见性")
		_props_row(gv, "可见", str(vi.visible))
		_props_row(gv, "层(layers)", str(vi.layers))
		_props_row(gv, "投射阴影", str(vi.cast_shadow))
		_props_row(gv, "全局光照模式", str(vi.gi_mode))
		var box: AABB = vi.get_aabb()
		_props_row(gv, "包围盒尺寸", _v3(box.size))
		_props_row(gv, "包围盒中心", _v3(box.get_center()))

	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		var m: Mesh = mi.mesh
		var gm := _props_group(root, "网格")
		if m == null:
			_props_row(gm, "网格", "（空）")
		else:
			_props_row(gm, "资源名", m.resource_name if not m.resource_name.is_empty() else "（未命名）")
			_props_row(gm, "类型", m.get_class())
			_props_row(gm, "表面数", str(m.get_surface_count()))
			_props_row(gm, "三角面", str(_tri_count(m)))
			_props_row(gm, "顶点", str(_vert_count(m)))
			_props_row(gm, "形态键", str(m.get_blend_shape_count()))
			# get_lod_count() 只有 ImporterMesh 有，ArrayMesh 没有 —— 用 has_method 防御
			if m.has_method("get_lod_count"):
				_props_row(gm, "LOD 数", str(m.call("get_lod_count")))
			# 注意：MeshInstance3D.skeleton 是 NodePath，不是节点
			_props_row(gm, "蒙皮骨骼", String(mi.skeleton) if not mi.skeleton.is_empty() else "（无）")
			for i in m.get_surface_count():
				_props_material(root, mi, i)

	# 只读：把所有格子都设成不可编辑
	var it: TreeItem = _props.get_root()
	while it != null:
		it.set_editable(0, false)
		it.set_editable(1, false)
		it = it.get_next_in_tree()


func _props_material(root: TreeItem, mi: MeshInstance3D, surface: int) -> void:
	var g := _props_group(root, "材质 %d" % surface)
	var mat := mi.get_active_material(surface)
	if mat == null:
		_props_row(g, "材质", "（无，用网格默认）")
		return
	_props_row(g, "资源名", mat.resource_name if not mat.resource_name.is_empty() else "（未命名）")
	_props_row(g, "类型", mat.get_class())
	_props_row(g, "资源路径", mat.resource_path if not mat.resource_path.is_empty() else "（内嵌）")
	if mat is BaseMaterial3D:
		var bm := mat as BaseMaterial3D
		_props_row(g, "反照率", str(bm.albedo_color))
		_props_row(g, "金属度", "%.3f" % bm.metallic)
		_props_row(g, "粗糙度", "%.3f" % bm.roughness)
		_props_row(g, "透明模式", str(bm.transparency))
		_props_row(g, "剔除模式", str(bm.cull_mode))
		_props_row(g, "无光照", str(bm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED))
		for tp in [["反照率贴图", bm.albedo_texture], ["法线贴图", bm.normal_texture],
				["ORM 贴图", bm.orm_texture], ["自发光贴图", bm.emission_texture]]:
			var tex: Texture2D = tp[1]
			var label := "（有）" if tex != null else "（无）"
			if tex != null and not tex.resource_path.is_empty():
				label = tex.resource_path.get_file()
			_props_row(g, String(tp[0]), label)
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		_props_row(g, "着色器", sm.shader.resource_path if sm.shader != null else "（无）")
		for k in sm.get_shader_parameter_list():
			_props_row(g, "参数 " + String(k), str(sm.get_shader_parameter(k)))


func _props_group(parent: TreeItem, text: String) -> TreeItem:
	var it: TreeItem = parent.create_child()
	it.set_text(0, text)
	it.set_custom_color(0, Color(0.98, 0.78, 0.35))
	it.set_selectable(0, false)
	it.set_selectable(1, false)
	it.set_collapsed(false)
	return it


func _props_row(parent: TreeItem, key: String, value: String) -> TreeItem:
	var it: TreeItem = parent.create_child()
	it.set_text(0, key)
	it.set_text(1, value)
	it.set_selectable(0, false)
	it.set_selectable(1, false)
	return it


func _vert_count(m: Mesh) -> int:
	var verts := 0
	for i in m.get_surface_count():
		if m is ArrayMesh:
			verts += (m as ArrayMesh).surface_get_array_len(i)
	return verts


func _v3(v: Vector3) -> String:
	return "%.3f, %.3f, %.3f" % [v.x, v.y, v.z]

# ------------------------------------------------------------------ 节点右键菜单

func _on_tree_input(ev: InputEvent) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if mb.button_index != MOUSE_BUTTON_RIGHT or not mb.pressed:
		return
	var item: TreeItem = _tree.get_item_at_position(mb.position)
	if item == null:
		return
	_tree.set_selected(item, 1)
	_on_item_selected()
	_show_node_menu(item, mb.position)


## 在节点上弹右键菜单（测试会直接调这个，绕开"控件还没排版"导致的取不到行）
func _show_node_menu(item: TreeItem, at: Vector2) -> void:
	var n = item.get_metadata(0)
	if not (n is Node):
		return
	_pending_node = n
	var checked := _checked_nodes()
	_node_menu.set_item_text(1, "导出勾选的 %d 个节点…" % checked.size())
	_node_menu.set_item_disabled(1, checked.is_empty())
	# PopupMenu 是 Window：坐标要用**屏幕坐标**，给控件局部坐标会飘到别处（用户反馈过）
	_node_menu.popup(Rect2i(Vector2i(_tree.get_screen_position() + at), Vector2i.ZERO))


func _on_node_menu(id: int) -> void:
	match id:
		0:
			if _pending_node != null:
				_open_export_dialog([_pending_node])
		1:
				_open_export_dialog(_checked_nodes())
		2:
			if _pending_node is Node3D:
				_refit(_pending_node)


## 打开"导出确认框"（和场景里选中节点导出用的是同一个窗口）
func _open_export_dialog(nodes: Array) -> void:
	if nodes.is_empty():
		_status.text = "没有可导出的节点"
		return
	var s: GDScript = load(LAUNCHER)
	if s == null:
		_status.text = "导出确认框加载失败"
		return
	# 把预览窗口自己作为父节点传进去：确认框挂在预览窗口下，预览窗口不会被顶掉/关掉
	s.call("open_for", nodes, self)
	_status.text = "已弹出导出确认框（%d 个节点）" % nodes.size()

# ------------------------------------------------------------------ 降模

## 拖动滑块：即时预览（走 Godot 内置 LOD 阶梯，毫秒级），并把实际达到的比例如实显示
func _on_ratio_changed(v: float) -> void:
	if _ratio_spin != null and not is_equal_approx(_ratio_spin.value, v):
		_ratio_spin.value = v
	_plain_export = false          # 用户又动了滑块，导出时该重新 weld
	_pending_ratio = v / 100.0
	if _ratio_timer == null:
		_apply_decimation(_pending_ratio)
		_pending_ratio = -1.0
		return
	if not _ratio_timer.is_stopped():
		return                     # 计时器还在跑：只记住最新值，到点统一应用（节流）
	_apply_pending_ratio()          # 第一下立刻出效果，保证手感
	_ratio_timer.start()


## 应用"待处理"的比例（计时器到点 / 手动调用）。带尾值保证：松手后的最终值一定会被应用。
func _apply_pending_ratio() -> void:
	if _pending_ratio < 0.0:
		return
	var target := _pending_ratio
	_pending_ratio = -1.0
	_apply_decimation(target)


## 后台任务（精确降模 / 导出后 weld）期间**冻结滑块**，免得用户拖了滑块、画面却在算别的
func _set_ratio_enabled(on: bool) -> void:
	if _ratio_slider != null:
		_ratio_slider.editable = on
	if _ratio_spin != null:
		_ratio_spin.editable = on
	if not on and _ratio_label != null and not _ratio_label.text.begins_with("（计算中"):
		_ratio_label.text = "（计算中，滑块已冻结）" + _ratio_label.text


func _preview_meshes() -> Array:
	var out: Array = []
	if _preview_root == null:
		return out
	var stack: Array = [_preview_root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _apply_decimation(target: float) -> void:
	_apply_count += 1
	var meshes := _preview_meshes()
	if meshes.is_empty():
		return

	if target >= 0.999:
		_restore_meshes()
		if _ratio_label != null:
			_ratio_label.text = "当前：原始 100%%（%d 个网格）" % meshes.size()
		return

	var total_before := 0
	var total_after := 0
	var levels_used := {}
	for mi in meshes:
		var node := mi as MeshInstance3D
		if not _originals.has(node):
			_originals[node] = node.mesh
		var base: Mesh = _originals[node]
		total_before += Decimate.tri_count(base)
		if not _lod_cache.has(node):
			_lod_cache[node] = Decimate.build_lods(base)       # 只算一次，拖动时不重算
		var picked: Dictionary = Decimate.pick(_lod_cache[node], target)
		if picked.is_empty():
			continue
		node.mesh = picked["mesh"]
		total_after += Decimate.tri_count(picked["mesh"])
		levels_used[snappedf(float(picked["ratio"]), 0.001)] = true

	var actual := float(total_after) / float(total_before) if total_before > 0 else 1.0
	if _ratio_label != null:
		_ratio_label.text = ("目标 %d%% → 实际 %.1f%%（%d → %d 面，%d 级 LOD 覆盖 %d 个比例台阶）"
				% [roundi(target * 100.0), actual * 100.0, total_before, total_after,
					levels_used.size(), levels_used.size()])


func _restore_meshes() -> void:
	for node in _originals.keys():
		if node != null and is_instance_valid(node):
			node.mesh = _originals[node]


## 精确降模：先把"原始网格"导成临时 glb，再交给 Python 工具按精确比例降，
## 结果写到导出目录，并在状态里报告（工具实测 30% → 实际 29.965%，精度足够）
func _on_exact_decimate() -> void:
	if _decim_thread != null and _decim_thread.is_started():
		_status.text = "上一次精确降模还在算…"
		return
	var picked := _checked_nodes()
	if picked.is_empty():
		_status.text = "先勾选要降模的节点"
		return
	var ratio := _ratio_slider.value / 100.0
	if ratio >= 0.995:
		_status.text = "当前比例是 100%，等于不降模 —— 先把滑块拖到你要的比例再点这个"
		return
	_restore_meshes()                       # 必须用原始网格，否则会叠加降模

	var dir := ProjectSettings.globalize_path("user://glb_tools/decimate")
	DirAccess.make_dir_recursive_absolute(dir)
	var src := dir.path_join("decimate_in.glb")
	var dst := dir.path_join("decimate_out.glb")
	var report := dir.path_join("decimate_report.txt")
	if FileAccess.file_exists(dst):
		DirAccess.remove_absolute(dst)
	var res: Dictionary = GlbExport.export_nodes(picked, src, true)
	if not bool(res.get("ok", false)):
		_status.text = "准备输入失败：" + str(res.get("message", ""))
		return
	var args := Decimate.exact_args(src, dst, ratio,
			ProjectSettings.globalize_path("res://"), report)
	_decim_result = {"kind": "exact", "dst": dst, "ratio": ratio, "report": report, "src": src}
	_plain_export = true              # 精确模式的产物已经压过顶点，跳过导出后的 weld
	_decim_thread = Thread.new()
	_decim_thread.start(_decim_worker.bind(args))
	_set_ratio_enabled(false)          # 冻结滑块
	set_process(true)
	_status.text = "精确降模中（目标 %.0f%%）…几秒钟" % (ratio * 100.0)


func _decim_worker(args: Array) -> void:
	var out: Array = []
	var err := ""
	for cmd in ["python", "python3", "py"]:
		out.clear()
		if OS.execute(cmd, args, out, true) == 0:
			err = ""
			break
		err = " ".join(out)
	if not err.is_empty():
		_decim_result["error"] = err


func _process(_delta: float) -> void:
	if _decim_thread == null or not _decim_thread.is_started():
		set_process(false)
		return
	if _decim_thread.is_alive():
		return
	_decim_thread.wait_to_finish()
	_decim_thread = null
	set_process(false)
	_set_ratio_enabled(true)          # 解冻滑块
	if String(_decim_result.get("kind", "")) == "weld":
		_finish_weld()
		return
	var dst := String(_decim_result.get("dst", ""))
	if _decim_result.has("error"):
		_status.text = "精确降模失败：" + String(_decim_result["error"])
		return
	var text := Decimate.read_report(String(_decim_result.get("report", "")))
	if text.is_empty():
		text = "完成"
	# **不自动往项目里写文件**（用户问过"你怎么直接导出了？"）：
	# 精确结果只留在 user:// 的临时目录里并套用到预览；要保存就用下面的「导出勾选」按钮。
	var before_tris := 0
	for mi in _preview_meshes():
		before_tris += Decimate.tri_count((mi as MeshInstance3D).mesh)
	var applied := _apply_glb_to_preview(dst)
	var after_tris := 0
	for mi in _preview_meshes():
		after_tris += Decimate.tri_count((mi as MeshInstance3D).mesh)
	_last_reduction = (float(after_tris) / float(before_tris)) if before_tris > 0 else 1.0
	print("[降模] 精确模式实际降幅：%d -> %d 面（%.1f%%）" % [before_tris, after_tris, _last_reduction * 100.0])
	_ratio_label.text = ("精确结果已套用到预览：目标 %d%% ｜ %d 个网格 ｜ %s"
			% [roundi(_ratio_slider.value), applied, text])

	# 如实校验降幅：工具可能因为网格不可简化而几乎没降，这时候必须说出来
	var ratio_got := _last_reduction
	if ratio_got >= 0.95:
		_status.text = "注意：实际几乎没降（%.1f%%）—— %s。网格可能不可简化，换个节点或比例再试" % [
				ratio_got * 100.0, text]
	else:
		_status.text = "%s ｜ 结果已套用到预览（要保存请用「导出勾选」按钮）" % text


## 把某个 glb 文件直接读进预览（用运行时 glTF 读取器：刚写出的文件还没被 Godot 导入，
## load() 拿不到）。返回塞进预览的网格数。
func _apply_glb_to_preview(path: String) -> int:
	if _preview_root == null or not FileAccess.file_exists(path):
		return 0
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(path, st) != OK:
		return 0
	var scene: Node = doc.generate_scene(st)
	if scene == null:
		return 0

	# 清掉旧的预览网格（连同高亮）
	_restore_meshes()
	_originals.clear()
	_lod_cache.clear()
	for h in _highlight_boxes:
		if h != null and is_instance_valid(h):
			h.queue_free()
	_highlight_boxes.clear()
	for c in _preview_root.get_children():
		_preview_root.remove_child(c)
		c.queue_free()

	# ImporterMeshInstance3D 是导入中间态，渲染要用 MeshInstance3D + ArrayMesh
	var count := 0
	var stack: Array = [scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n.get_class() == "ImporterMeshInstance3D":
			var imesh = n.get("mesh")
			if imesh is ImporterMesh:
				var mi := MeshInstance3D.new()
				mi.name = String(n.name)
				mi.mesh = (imesh as ImporterMesh).get_mesh()
				var src_xf: Transform3D = (n as Node3D).global_transform
				mi.transform = _preview_root.global_transform.affine_inverse() * src_xf
				var mat = n.get("material_override")
				if mat is Material:
					mi.material_override = mat
				_preview_root.add_child(mi)
				count += 1
		for c in n.get_children():
			stack.append(c)
	scene.free()
	_rebuild_tree()
	_refit(_preview_root)
	return count

# ------------------------------------------------------------------ 线框显示

## 切换"显示三角网格"（线框）。用 Viewport.debug_draw —— Godot 的材质没有线框开关，
## 这是最省事也最稳的路子；状态会被 load_glb 保留（它不碰 viewport 的这个属性）。
func _on_wireframe_toggled(on: bool) -> void:
	if _viewport == null:
		return
	_viewport.debug_draw = Viewport.DEBUG_DRAW_WIREFRAME if on else Viewport.DEBUG_DRAW_DISABLED
	_status.text = "线框显示：%s" % ("开（显示三角网格）" if on else "关（正常着色）")

# ------------------------------------------------------------------ 导出后 weld

## 导出后压顶点（后台线程）。滑块在算期间冻结，见 _set_ratio_enabled。
func _start_weld(path: String) -> void:
	if _decim_thread != null and _decim_thread.is_started():
		return
	var report := ProjectSettings.globalize_path("user://glb_tools/decimate/weld_report.txt")
	DirAccess.make_dir_recursive_absolute(report.get_base_dir())
	var args := Decimate.weld_args(path, ProjectSettings.globalize_path("res://"), report)
	_decim_result = {"kind": "weld", "path": path, "report": report}
	_decim_thread = Thread.new()
	_decim_thread.start(_decim_worker.bind(args))
	_set_ratio_enabled(false)
	set_process(true)
	_status.text = "正在 weld 压顶点（约 2~4 秒）…"


func _finish_weld() -> void:
	var path := String(_decim_result.get("path", ""))
	if _decim_result.has("error"):
		_status.text = "weld 失败：" + String(_decim_result["error"])
		return
	var text := Decimate.read_report(String(_decim_result.get("report", "")))
	var size := 0
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size = f.get_length()
			f.close()
	_refresh_fs(path)
	_status.text = "%s ｜ %s（%d 字节）" % [text, path.get_file(), size]
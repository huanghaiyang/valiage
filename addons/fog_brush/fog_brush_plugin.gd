@tool
extends EditorPlugin
## ============================================================================
## fog_brush_plugin.gd —— **雾气笔刷**编辑器插件（在 3D 视口里直接刷雾）
## ============================================================================
## 【这个插件做什么】把"手刷的雾"画进一个 FogField 的画笔底图（FogBrushField），
##   运行时的流体求解器再把这张底图当成**吸引子**：风把雾吹变形、耗散让它变淡，
##   但底图会把它慢慢拉回刷出来的形状 —— 所以刷出来的雾是"活的"，不是一张贴图。
##
## 【操作】
##   · 选中场景里的 FogField（没有就点面板的"应用到雾气场"会自动建一个）
##   · 勾选"启用雾气笔刷"，在 3D 视口里：
##       左键拖动 = 按当前模式刷（加雾/擦雾/抹平）
##       右键拖动 = 临时切到"擦雾"
##       Shift/Alt/Ctrl = 让位给编辑器（旋转/平移视图，不会误刷）
##       [ / ]   = 缩小 / 放大笔刷半径
##   · 每次落笔结束会写一张 PNG 资产（res://assets/fog/<场景名>_fog.png）并存进撤销栈
##
## 【架构】三层，各自只管一件事（这样每一层都能被单独验证）：
##   fog_brush_field.gd   笔刷数据 + 纯函数笔刷数学（无编辑器依赖，测试直接覆盖）
##   fog_brush_dock.gd    面板 UI（只发信号，不知道 FogField 存在）
##   本文件               编辑器粘合：拾取落点、笔画推进、撤销/重做、落盘、刷新雾气
##
## 【已知的坑（都是编辑器插件的老问题，注释里对应位置也写了）】
##   1. `_forward_3d_gui_input` 返回 AFTER_GUI_INPUT_STOP 才能吃掉这次鼠标事件；
##      返回 PASS 时编辑器会同时旋转视角 —— 表现为"一刷就转镜头"。
##   2. 必须在 _enter_tree 里 `set_input_event_forwarding_always_enabled()`，
##      否则视口里的 GUI 输入根本不会转发给插件。
##   3. 撤销栈里存的是**整张网格的拷贝**（96² 浮点 = 384KB），一次笔画一份。
##      连续刷几百笔会吃内存，所以每次落笔（按下-抬起）只记一个动作，
##      不是每个鼠标移动事件都记。
##   4. 写 PNG 只在落笔结束时做（不是每帧）：每帧落盘会把编辑器卡住。
##   5. 编辑器里拿不到 /root/Weather 之类的运行期 autoload，所有运行期副作用
##      （刷新求解器底图）都通过 FogField 自己的方法走，不在这里碰引擎状态。
## ============================================================================

const DOCK_SCRIPT := preload("res://addons/fog_brush/ui/fog_brush_dock.gd")
const BRUSH_FIELD_SCRIPT := preload("res://scripts/fx/fog_brush_field.gd")
const FOG_FIELD_SCRIPT := preload("res://scripts/fx/fog_field.gd")

const RAY_LENGTH := 100000.0
## 笔刷预览圆的段数（够圆且够省）
const PREVIEW_SEGMENTS := 48
## 预览圆的颜色
const PREVIEW_COLOR := Color(0.55, 0.85, 1.0, 0.9)
const ERASE_PREVIEW_COLOR := Color(1.0, 0.45, 0.35, 0.9)
## 笔画插值间距（相对半径）：0.3 = 每 0.3 个半径打一个印
const STROKE_SPACING := 0.3
## 默认 PNG 资产目录
const DEFAULT_IMAGE_DIR := "res://assets/fog"

var dock: EditorDock
var dock_content: Control

## 当前操作的 FogField（未选中时自动在场景里找一个）
var target: FogField
var painting := false
var erase_override := false
var last_cell := Vector2.ZERO
var has_last_cell := false

var preview_mesh: MeshInstance3D
var preview_material: StandardMaterial3D
var undo_snapshot: PackedFloat32Array = PackedFloat32Array()
## 编辑器选区对象（EditorSelection）。用无类型声明 + 动态 connect：
## ★ EditorPlugin **没有** selection_changed 信号（只有 scene_changed 等），
##   选区变化要从 EditorInterface.get_selection() 拿到的对象上连。
##   直接写 `selection_changed.connect(...)` 会在解析期报 "Identifier not declared"。
var editor_selection: Object


# =========================================================
# 生命周期
# =========================================================

func _enter_tree() -> void:
	set_process(true)
	set_input_event_forwarding_always_enabled()

	dock_content = DOCK_SCRIPT.new()
	dock_content.name = "FogBrushDockContent"
	_create_dock()
	_connect_dock_signals()
	if not scene_changed.is_connected(_on_scene_changed):
		scene_changed.connect(_on_scene_changed)
	editor_selection = get_editor_interface().get_selection()
	if editor_selection != null and not editor_selection.is_connected("selection_changed", _on_selection_changed):
		editor_selection.connect("selection_changed", _on_selection_changed)

	call_deferred("_show_dock")
	call_deferred("_refresh_target")
	print("Fog Brush: 插件已启用（选中 FogField 后勾选'启用雾气笔刷'）")


func _exit_tree() -> void:
	_end_stroke()
	if scene_changed.is_connected(_on_scene_changed):
		scene_changed.disconnect(_on_scene_changed)
	if editor_selection != null and editor_selection.is_connected("selection_changed", _on_selection_changed):
		editor_selection.disconnect("selection_changed", _on_selection_changed)
	editor_selection = null
	set_process(false)
	_remove_preview()
	if is_instance_valid(dock):
		remove_dock(dock)
		dock.queue_free()
	dock = null
	dock_content = null
	target = null
	print("Fog Brush: 插件已停用")


func _create_dock() -> void:
	dock = EditorDock.new()
	dock.name = "FogBrushEditorDock"
	dock.title = "Fog Brush"
	dock.layout_key = "fog_brush_editor_dock"
	dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	dock.global = true
	# ★ 面板内容会越来越长（雾气参数 + 体积雾参数 + 笔刷参数），停靠面板高度有限，
	#   所以外面套一层 ScrollContainer：内容超高就能滚动，不会把下面的行挤出可视区。
	#   放在这里而不是改面板脚本：面板内部所有 add_child 的目标不用动，
	#   而且水平方向禁滚（否则 SpinBox 会被挤成一条缝）。
	var scroll := ScrollContainer.new()
	scroll.name = "FogBrushScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(dock_content)
	dock.add_child(scroll)
	add_dock(dock)


func _show_dock() -> void:
	if is_instance_valid(dock):
		dock.open()
		dock.make_visible()


func _connect_dock_signals() -> void:
	if dock_content == null:
		return
	var wiring := {
		"brush_enabled_changed": _on_brush_enabled_changed,
		"mode_changed": _on_mode_changed,
		"params_changed": _on_params_changed,
		"clear_requested": _on_clear_requested,
		"fill_requested": _on_fill_requested,
		"export_requested": _on_export_requested,
		"import_requested": _on_import_requested,
		"rebuild_requested": _on_rebuild_requested,
		"refresh_requested": _on_refresh_requested,
		"fog_param_changed": _on_fog_param_changed,
		"fog_toggle_changed": _on_fog_toggle_changed,
	}
	for signal_name in wiring:
		if not dock_content.has_signal(signal_name):
			push_error("Fog Brush: 面板缺少信号 %s" % signal_name)
			continue
		dock_content.connect(signal_name, wiring[signal_name])


# =========================================================
# 目标解析
# =========================================================

func _on_scene_changed(_root: Node) -> void:
	_end_stroke()
	_remove_preview()
	call_deferred("_refresh_target")


func _on_selection_changed() -> void:
	call_deferred("_refresh_target")


## 解析当前要刷的 FogField：优先"选中的那个"，否则场景里第一个。
func _refresh_target() -> void:
	var previous := target
	target = _resolve_target()
	if target != previous:
		_end_stroke()
		_remove_preview()

	if target == null:
		_set_dock_target("未找到 FogField（点'应用到雾气场'可自动创建）")
		return

	_ensure_brush_field()
	_set_dock_target(target.name)
	if dock_content != null and target.brush_field != null:
		dock_content.call("sync_from_field", target.brush_field)
	# 面板上的雾气参数也跟着选中的目标回填（否则调完另一个节点，面板显示的还是旧值）
	if dock_content != null and dock_content.has_method("sync_fog_params"):
		dock_content.call("sync_fog_params", target)


## 面板上的雾气参数变化 -> 直接写回选中的 FogField。
## ★ 用"参数名"透传，而不是给每个参数写一段 if：面板控件与 FogField 属性同名就是契约，
##   以后加参数两边各改一行即可。
##   height 类的参数（base_height / box_height）在 FogField 里**自带 setter**，
##   赋值即重建高度带（粒子节点、包围盒、体积盒、交互体抬升），所以这里不需要额外处理。
func _on_fog_param_changed(param_name: String, value: Variant) -> void:
	if target == null:
		_set_status("先选中一个 FogField（或点'应用到雾气场'）")
		return
	var current = target.get(param_name)
	if current is int:
		# INT 属性（如 particle_count）必须传整数，否则 Godot 会拒绝赋值
		target.set(param_name, int(round(value)))
	else:
		target.set(param_name, value)
	_mark_scene_unsaved()
	_set_status("已应用 %s = %s" % [param_name, str(target.get(param_name))])


func _on_fog_toggle_changed(param_name: String, value: bool) -> void:
	if target == null:
		_set_status("先选中一个 FogField（或点'应用到雾气场'）")
		return
	target.set(param_name, value)
	_mark_scene_unsaved()
	_set_status("%s = %s（体积盒的有无在下次运行场景时生效）" % [param_name, str(value)])


## ★ 必须**显式**标记"场景已修改"：面板直接 `set()` 属性不会触发编辑器的脏标记，
##   结果是"面板里值变了、场景却没被保存" —— 一运行游戏读到的还是旧值。
##   这正是"部分属性设置后无法保存 / 游戏中不生效"的头号原因。
func _mark_scene_unsaved() -> void:
	var editor := get_editor_interface()
	if editor != null and editor.has_method("mark_scene_as_unsaved"):
		editor.call("mark_scene_as_unsaved")


func _resolve_target() -> FogField:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return null

	# 选中的节点（含其自身）优先
	var selection := get_editor_interface().get_selection()
	if selection != null:
		for node in selection.get_selected_nodes():
			var found := _find_field_on(node)
			if found != null:
				return found

	# 否则在场景里找第一个
	return _find_field_in(scene_root)


func _find_field_on(node: Node) -> FogField:
	var current := node
	while current != null:
		if _is_fog_field(current):
			return current as FogField
		current = current.get_parent()
	return null


func _find_field_in(root: Node) -> FogField:
	if _is_fog_field(root):
		return root as FogField
	for child in root.get_children():
		var found := _find_field_in(child)
		if found != null:
			return found
	return null


## ★ 用"脚本资源相等"判断类型，而不是 `is FogField`：插件是 @tool 脚本，
##   在编辑器里依赖全局 class_name 表有时会失败（本仓库的测试也踩过同一类问题），
##   直接比脚本资源最稳。
func _is_fog_field(node: Node) -> bool:
	if node == null or node.get_script() == null:
		return false
	return node.get_script() == FOG_FIELD_SCRIPT


func _set_dock_target(text: String) -> void:
	if dock_content != null and dock_content.has_method("set_target_info"):
		dock_content.call("set_target_info", text)


func _set_status(text: String) -> void:
	if dock_content != null and dock_content.has_method("set_status"):
		dock_content.call("set_status", text)


## 确保目标有一个 FogBrushField（没有就建一个并挂 PNG 路径）。
## ★ 一律通过 `target.set_brush_field()` 赋值，而不是直接写 `target.brush_field`：
##   前者会顺带把底图接到体积雾上（编辑器里就是"刷完立刻看见"的那条链）。
func _ensure_brush_field() -> FogBrushField:
	if target == null:
		return null
	var field: FogBrushField = target.brush_field
	if field == null:
		field = BRUSH_FIELD_SCRIPT.new() as FogBrushField
		field.grid_size = _dock_grid_size()
		field.image_path = _default_image_path()
		field.ensure_data()
		target.set_brush_field(field)
	elif field.data.is_empty() and not field.image_path.is_empty():
		# 只有 PNG、没有内存网格：读进来（否则第一次落笔会从全 0 开始覆盖掉已有资产）
		field.load_from_png(field.image_path)
		field.ensure_data()
	else:
		field.ensure_data()
	return field


func _dock_grid_size() -> Vector2i:
	if dock_content != null:
		return dock_content.get("grid_size")
	return Vector2i(96, 96)


## 默认 PNG 资产路径：res://assets/fog/<场景名>_fog.png
func _default_image_path() -> String:
	var scene_root := get_editor_interface().get_edited_scene_root()
	var scene_name := "scene"
	if scene_root != null and not scene_root.scene_file_path.is_empty():
		scene_name = scene_root.scene_file_path.get_file().get_basename()
	return "%s/%s_fog.png" % [DEFAULT_IMAGE_DIR, scene_name]


# =========================================================
# 视口输入
# =========================================================

func _handles(object: Object) -> bool:
	if object == null:
		return get_editor_interface().get_edited_scene_root() is Node3D
	return object is Node3D


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if event is InputEventKey:
		_handle_key(event as InputEventKey)
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if not _brush_active():
		_end_stroke()
		_remove_preview()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:
		return _handle_motion(camera, event as InputEventMouseMotion)
	if event is InputEventMouseButton:
		return _handle_button(camera, event as InputEventMouseButton)
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _brush_active() -> bool:
	return target != null and dock_content != null and bool(dock_content.get("enabled"))


func _handle_key(key_event: InputEventKey) -> void:
	if not key_event.pressed or key_event.echo or dock_content == null:
		return
	var radius: float = dock_content.get("radius_m")
	# [ / ] 调半径：与视口操作冲突很小（编辑器默认不占用这两个键）
	if key_event.keycode == KEY_BRACKETLEFT:
		dock_content.set("radius_m", maxf(1.0, radius / 1.15))
		_set_status("半径 = %.1f m" % dock_content.get("radius_m"))
	elif key_event.keycode == KEY_BRACKETRIGHT:
		dock_content.set("radius_m", minf(500.0, radius * 1.15))
		_set_status("半径 = %.1f m" % dock_content.get("radius_m"))


func _handle_motion(camera: Camera3D, motion: InputEventMouseMotion) -> int:
	# 带修饰键时让位给编辑器（旋转/平移/缩放视图），绝不能在那些时候落笔
	if _has_modifier(motion):
		_end_stroke()
		_remove_preview()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var hit := _plane_hit(camera, motion.position)
	_update_preview(hit)

	if not painting:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if not hit.has("point"):
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	_continue_stroke(hit)
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _handle_button(camera: Camera3D, button: InputEventMouseButton) -> int:
	var is_left := button.button_index == MOUSE_BUTTON_LEFT
	var is_right := button.button_index == MOUSE_BUTTON_RIGHT
	if not is_left and not is_right:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if _has_modifier(button):
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var hit := _plane_hit(camera, button.position)
	_update_preview(hit)

	if button.pressed:
		if not hit.has("point"):
			_set_status("落点不在雾气层的水平范围内")
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		erase_override = is_right
		_begin_stroke(hit)
	else:
		_end_stroke()
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _has_modifier(event: InputEventWithModifiers) -> bool:
	return event.alt_pressed or event.ctrl_pressed or event.shift_pressed or event.meta_pressed


## 射线与"雾气层水平面"（y = FogField 域底面）求交。
## 返回 {point: Vector3, cell: Vector2}；不合法时返回空字典。
func _plane_hit(camera: Camera3D, mouse_position: Vector2) -> Dictionary:
	if target == null or camera == null:
		return {}
	var origin := camera.project_ray_origin(mouse_position)
	var direction := camera.project_ray_normal(mouse_position).normalized()
	if absf(direction.y) < 1.0e-5:
		return {}                        # 视线与平面平行：无交点
	var plane_y := target.global_position.y + target.base_height
	var distance := (plane_y - origin.y) / direction.y
	if distance <= 0.0 or distance > RAY_LENGTH:
		return {}
	var point := origin + direction * distance

	var local := point - target.global_position
	var domain := target.domain_size
	var uv := Vector2(local.x / maxf(domain.x, 0.001) + 0.5, local.z / maxf(domain.y, 0.001) + 0.5)
	if uv.x < -0.05 or uv.x > 1.05 or uv.y < -0.05 or uv.y > 1.05:
		return {}                        # 落在雾气域之外
	var field := target.brush_field
	if field == null:
		return {}
	var grid := field.grid_size
	var cell := Vector2(uv.x * float(grid.x) - 0.5, uv.y * float(grid.y) - 0.5)
	return {"point": point, "cell": cell, "uv": uv}


# =========================================================
# 笔画
# =========================================================

func _begin_stroke(hit: Dictionary) -> void:
	var field := _ensure_brush_field()
	if field == null:
		return
	undo_snapshot = field.data.duplicate()
	painting = true
	has_last_cell = false
	last_cell = hit["cell"]
	has_last_cell = true
	_apply_stamp_at(hit["cell"], true)
	_set_status("落笔：%s" % _mode_name())


func _continue_stroke(hit: Dictionary) -> void:
	var field: FogBrushField = target.brush_field if target != null else null
	if field == null:
		return
	var cell: Vector2 = hit["cell"]
	var previous_cell := last_cell
	var radius_cells := _radius_in_cells(field)
	var changed := 0
	if has_last_cell:
		changed = BRUSH_FIELD_SCRIPT.apply_stroke(
			field, last_cell, cell, radius_cells,
			_dock_strength(), _dock_hardness(), _effective_mode(), STROKE_SPACING
		)
	else:
		changed = BRUSH_FIELD_SCRIPT.apply_stamp(
			field, cell, radius_cells, _dock_strength(), _dock_hardness(), _effective_mode()
		)
	last_cell = cell
	has_last_cell = true
	if changed > 0:
		_push_brush_to_field(false)
		if _dock_paint_velocity():
			# 用"本段的起点与终点"算吹风方向（此时 last_cell 已经被更新，所以显式传入）
			_push_velocity_source(hit, previous_cell)


func _apply_stamp_at(cell: Vector2, force: bool) -> void:
	var field: FogBrushField = target.brush_field if target != null else null
	if field == null:
		return
	var changed := BRUSH_FIELD_SCRIPT.apply_stamp(
		field, cell, _radius_in_cells(field), _dock_strength(), _dock_hardness(), _effective_mode()
	)
	if changed > 0 or force:
		_push_brush_to_field(false)


func _radius_in_cells(field: FogBrushField) -> float:
	if target == null:
		return 4.0
	# 米 -> 域比例 -> 单元：取 x/z 两个方向的较小者，保证非正方形域上也是"圆"的笔刷
	var domain := target.domain_size
	var radius_uv := _dock_radius() / maxf(minf(domain.x, domain.y), 0.001)
	return maxf(radius_uv * float(field.grid_size.x), 0.75)


func _end_stroke() -> void:
	if not painting:
		return
	painting = false
	has_last_cell = false
	erase_override = false
	var field: FogBrushField = target.brush_field if target != null else null
	if field == null:
		return
	# 落笔结束：写 PNG + 记一个撤销动作（一次笔画一个，不是每个鼠标事件一个）
	var after := field.data.duplicate()
	field.save_to_png(field.image_path)
	_push_undo(undo_snapshot, after)
	_push_brush_to_field(true)
	_set_status("落笔完成：%s（共 %d 格有雾）" % [_mode_name(), _painted_cell_count(field)])


func _push_undo(before: PackedFloat32Array, after: PackedFloat32Array) -> void:
	var field: FogBrushField = target.brush_field if target != null else null
	if field == null or before.size() != after.size() or before.size() == 0:
		return
	if before == after:
		return                              # 什么都没变：不污染撤销栈
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Fog Brush: %s" % _mode_name())
	undo_redo.add_do_method(self, &"_restore_brush_data", field, after)
	undo_redo.add_undo_method(self, &"_restore_brush_data", field, before)
	undo_redo.commit_action(false)


func _restore_brush_data(field: FogBrushField, data: PackedFloat32Array) -> void:
	if field == null:
		return
	field.data = data.duplicate()
	field.mark_texture_dirty()
	if not field.image_path.is_empty():
		field.save_to_png(field.image_path)
	if target != null and target.brush_field == field:
		_push_brush_to_field(true)


func _painted_cell_count(field: FogBrushField) -> int:
	var count := 0
	for value in field.data:
		if value > 0.01:
			count += 1
	return count


func _push_brush_to_field(force: bool) -> void:
	if target == null:
		return
	var auto := true
	if dock_content != null:
		auto = bool(dock_content.get("auto_refresh"))
	if not auto and not force:
		return
	target.refresh_brush_texture()


## "落笔同时吹动风场"：把笔刷落点当成一个速度源推给求解器。
## ★ 走 FogField 的公开方法而不是 `target.solver.add_splat(...)`：编辑器里根本没有
##   求解器（@tool 只建体积雾预览），直接摸 solver 会报
##   "Invalid access to property 'solver' on a base object of type 'Node3D (FogField)'"。
##   由 FogField 自己决定"有求解器就推、没有就静默跳过"，插件不需要知道运行时状态。
## from_cell 由调用方传入"本段笔画的起点"，因为 last_cell 此时已经被更新成终点。
func _push_velocity_source(hit: Dictionary, from_cell: Vector2) -> void:
	if target == null:
		return
	var radius_m := _dock_radius()
	# 沿"笔刷移动方向"吹风；没有移动方向时给一个固定斜向，保证总有可见效果
	var cell: Vector2 = hit["cell"]
	var movement := cell - from_cell
	var direction := Vector3.ZERO
	if movement.length() > 0.001:
		direction = Vector3(movement.x, 0.0, movement.y).normalized()
	else:
		direction = Vector3(1.0, 0.0, 0.2).normalized()
	direction *= 4.0
	var uv: Vector2 = hit["uv"]
	var radius_uv := radius_m / maxf(minf(target.domain_size.x, target.domain_size.y), 0.001)
	target.add_brush_velocity(uv, radius_uv, Vector2(
		direction.x / target.domain_size.x, direction.z / target.domain_size.y))


func _effective_mode() -> int:
	if erase_override:
		return BRUSH_FIELD_SCRIPT.Mode.ERASE
	return int(dock_content.get("mode")) if dock_content != null else BRUSH_FIELD_SCRIPT.Mode.PAINT


func _mode_name() -> String:
	match _effective_mode():
		BRUSH_FIELD_SCRIPT.Mode.ERASE:
			return "擦雾"
		BRUSH_FIELD_SCRIPT.Mode.SMOOTH:
			return "抹平"
		_:
			return "加雾"


func _dock_radius() -> float:
	return float(dock_content.get("radius_m")) if dock_content != null else 12.0


func _dock_strength() -> float:
	return float(dock_content.get("strength")) if dock_content != null else 0.35


func _dock_hardness() -> float:
	return float(dock_content.get("hardness")) if dock_content != null else 0.45


func _dock_paint_velocity() -> bool:
	return bool(dock_content.get("paint_velocity")) if dock_content != null else false


# =========================================================
# 预览
# =========================================================

func _update_preview(hit: Dictionary) -> void:
	if dock_content == null or not bool(dock_content.get("show_preview")) or hit.is_empty():
		_remove_preview()
		return
	if preview_mesh == null:
		_create_preview()
	if preview_mesh == null:
		return
	preview_mesh.global_position = hit["point"] + Vector3(0.0, 0.05, 0.0)
	preview_mesh.global_rotation = Vector3.ZERO
	# ★ 用 scale 而不是 global_scale：Godot 4 的 Node3D.global_scale 对脚本是**只读**的
	#   （赋值会报 "Cannot assign a new value to a constant"）。预览节点挂在未缩放的
	#   场景根下，局部 scale 与全局 scale 等价。
	preview_mesh.scale = Vector3(_dock_radius(), 1.0, _dock_radius())
	if preview_material != null:
		preview_material.albedo_color = ERASE_PREVIEW_COLOR if erase_override else PREVIEW_COLOR
	preview_mesh.visible = true


func _create_preview() -> void:
	var immediate := ImmediateMesh.new()
	var ring_points := PackedVector3Array()
	for i in range(PREVIEW_SEGMENTS + 1):
		var angle := TAU * float(i) / float(PREVIEW_SEGMENTS)
		ring_points.append(Vector3(cos(angle), 0.0, sin(angle)))
	immediate.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for point in ring_points:
		immediate.surface_add_vertex(point)
	immediate.surface_end()

	preview_material = StandardMaterial3D.new()
	preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	preview_material.albedo_color = PREVIEW_COLOR
	preview_material.no_depth_test = false

	preview_mesh = MeshInstance3D.new()
	preview_mesh.name = "FogBrushPreview"
	preview_mesh.mesh = immediate
	preview_mesh.material_override = preview_material
	preview_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	preview_mesh.visible = false

	var scene_root := get_editor_interface().get_edited_scene_root()
	var parent: Node = scene_root if scene_root != null else get_tree().root
	parent.add_child(preview_mesh)


## 预览节点**不进场景树的所有权**（owner 保持 null），所以不会被存进场景文件。
func _remove_preview() -> void:
	if is_instance_valid(preview_mesh):
		preview_mesh.queue_free()
	preview_mesh = null
	preview_material = null


# =========================================================
# 面板信号处理
# =========================================================

func _on_brush_enabled_changed(enabled: bool) -> void:
	if enabled:
		if target == null:
			_set_status("没找到 FogField：先点'应用到雾气场'")
			return
		_ensure_brush_field()
		_set_status("笔刷已启用：左键刷、右键擦、Shift/Alt/Ctrl 让位给视图操作")
	else:
		_end_stroke()
		_remove_preview()
		_set_status("笔刷已关闭")


func _on_mode_changed(mode: int) -> void:
	var names := ["加雾", "擦雾", "抹平"]
	var index := clampi(mode, 0, names.size() - 1)
	_set_status("模式：%s" % names[index])


func _on_params_changed() -> void:
	# 改半径后立刻刷新预览，视觉反馈更直接（同样用 scale，见 _update_preview 的说明）
	if preview_mesh != null and preview_mesh.visible and target != null:
		preview_mesh.scale = Vector3(_dock_radius(), 1.0, _dock_radius())


func _on_clear_requested() -> void:
	var field := _ensure_brush_field()
	if field == null:
		return
	var before := field.data.duplicate()
	field.clear()
	_after_bulk_edit(field, before, "Fog Brush: 清空")


func _on_fill_requested() -> void:
	var field := _ensure_brush_field()
	if field == null:
		return
	var before := field.data.duplicate()
	field.fill(_dock_strength())
	_after_bulk_edit(field, before, "Fog Brush: 铺满")


func _after_bulk_edit(field: FogBrushField, before: PackedFloat32Array, action: String) -> void:
	var after := field.data.duplicate()
	field.save_to_png(field.image_path)
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action)
	undo_redo.add_do_method(self, &"_restore_brush_data", field, after)
	undo_redo.add_undo_method(self, &"_restore_brush_data", field, before)
	undo_redo.commit_action(false)
	_push_brush_to_field(true)
	_set_status("%s（%d 格有雾）" % [action, _painted_cell_count(field)])


func _on_export_requested() -> void:
	var field := _ensure_brush_field()
	if field == null:
		return
	if field.image_path.is_empty():
		field.image_path = _default_image_path()
	var error := field.save_to_png(field.image_path)
	if error == OK:
		get_editor_interface().get_resource_filesystem().scan()
		_set_status("已导出：%s" % field.image_path)
	else:
		_set_status("导出失败（err=%d）" % error)


func _on_import_requested() -> void:
	var field := _ensure_brush_field()
	if field == null:
		return
	var dialog := EditorFileDialog.new()
	dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	dialog.access = EditorFileDialog.ACCESS_RESOURCES
	dialog.add_filter("*.png", "灰度 PNG")
	dialog.title = "选择一张灰度 PNG 作为雾气底图"
	dialog.file_selected.connect(func(path: String) -> void:
		var before := field.data.duplicate()
		if not field.load_from_png(path):
			_set_status("导入失败：%s" % path)
			return
		field.image_path = path
		field.ensure_data()
		_after_bulk_edit(field, before, "Fog Brush: 导入底图")
		dialog.queue_free()
	)
	dialog.canceled.connect(func() -> void: dialog.queue_free())
	get_editor_interface().get_base_control().add_child(dialog)
	dialog.popup_centered_ratio(0.6)


func _on_rebuild_requested() -> void:
	if target == null:
		_create_default_field()
		return
	var field := _ensure_brush_field()
	if field != null:
		# 面板改了分辨率：按新尺寸重建网格（保留旧内容能保留的部分由 ensure_data 处理）
		if field.grid_size != _dock_grid_size():
			var old := field.data.duplicate()
			var old_size := field.grid_size
			field.grid_size = _dock_grid_size()
			field.data = PackedFloat32Array()
			field.ensure_data()
			_resample_into(field, old, old_size)
			field.save_to_png(field.image_path)
	# 走公开方法：编辑器里它会更新预览，运行期它会交给求解器
	target.set_brush_field(field)
	_set_status("已应用到雾气场：%s（网格 %dx%d）"
			% [target.name, field.grid_size.x, field.grid_size.y])


## 把旧网格按比例重采样到新网格（分辨率调整不该让画好的雾整张消失）。
func _resample_into(field: FogBrushField, old: PackedFloat32Array, old_size: Vector2i) -> void:
	if old.is_empty() or old_size.x <= 0 or old_size.y <= 0:
		return
	var new_size := field.grid_size
	for j in range(new_size.y):
		for i in range(new_size.x):
			var u := (float(i) + 0.5) / float(new_size.x)
			var v := (float(j) + 0.5) / float(new_size.y)
			var source_x := clampi(int(u * float(old_size.x)), 0, old_size.x - 1)
			var source_y := clampi(int(v * float(old_size.y)), 0, old_size.y - 1)
			field.data[j * new_size.x + i] = old[source_y * old_size.x + source_x]


func _on_refresh_requested() -> void:
	_refresh_target()
	_set_status("已刷新目标与底图")


## 场景里没有 FogField 时，替用户建一个（挂在编辑中的场景根下）。
func _create_default_field() -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		_set_status("当前没有打开的场景")
		return
	var field := FOG_FIELD_SCRIPT.new() as FogField
	field.name = "FogField"
	scene_root.add_child(field)
	field.owner = scene_root
	field.position = Vector3.ZERO
	var brush := BRUSH_FIELD_SCRIPT.new() as FogBrushField
	brush.grid_size = _dock_grid_size()
	brush.image_path = _default_image_path()
	brush.ensure_data()
	field.set_brush_field(brush)
	target = field
	get_editor_interface().get_selection().clear()
	get_editor_interface().get_selection().add_node(field)
	_set_status("已创建 FogField（域 %.0fx%.0f 米）" % [field.domain_size.x, field.domain_size.y])

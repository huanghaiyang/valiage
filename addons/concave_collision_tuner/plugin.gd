@tool
extends EditorPlugin
## 凹多边形碰撞调参：两个入口
##   1. 检查器面板 —— 选中形状为 ConcavePolygonShape3D 的 CollisionShape3D 时自动出现
##   2. 3D 视图工具栏按钮「碰撞调参」—— 同一批操作，弹窗里做（选中合适碰撞体时才显示）
##
## 两个入口共用 tuner_panel.gd 的面板与重建逻辑。

const InspectorPluginScript := preload("res://addons/concave_collision_tuner/inspector.gd")
const TunerPanelScript := preload("res://addons/concave_collision_tuner/tuner_panel.gd")

var _inspector: EditorInspectorPlugin = null
var _button: Button = null
var _popup: PopupPanel = null
var _popup_margin: MarginContainer = null
var _panel: Control = null


func _enter_tree() -> void:
	# ---- 入口 1：检查器面板 ----
	_inspector = InspectorPluginScript.new()
	add_inspector_plugin(_inspector)

	# ---- 入口 2：3D 视图工具栏（和「网格」「视图」同一行）----
	_button = Button.new()
	_button.text = "碰撞调参"
	_button.tooltip_text = "凹多边形碰撞调参：选中形状为 ConcavePolygonShape3D 的 CollisionShape3D 后，在这里按系数重建碰撞面数"
	_button.pressed.connect(_on_button_pressed)
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _button)

	var sel := EditorInterface.get_selection()
	if sel != null and not sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.connect(_on_selection_changed)
	_on_selection_changed()
	print("[凹多边形碰撞调参] 已启用：检查器面板 + 3D 视图工具栏「碰撞调参」")


func _exit_tree() -> void:
	if _button != null:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _button)
		_button.queue_free()
		_button = null
	var sel := EditorInterface.get_selection()
	if sel != null and sel.selection_changed.is_connected(_on_selection_changed):
		sel.selection_changed.disconnect(_on_selection_changed)
	if _popup != null:
		_popup.queue_free()
		_popup = null
		_popup_margin = null
		_panel = null
	if _inspector != null:
		remove_inspector_plugin(_inspector)
		_inspector = null
	print("[凹多边形碰撞调参] 已停用")


# ------------------------------------------------------------------ 选择 / 工具栏

## 当前选中的、形状是凹多边形的 CollisionShape3D（没有就返回 null）
func _selected_collider() -> CollisionShape3D:
	var sel := EditorInterface.get_selection()
	if sel == null:
		return null
	for n in sel.get_selected_nodes():
		if n is CollisionShape3D and (n as CollisionShape3D).shape is ConcavePolygonShape3D:
			return n as CollisionShape3D
	return null


func _on_selection_changed() -> void:
	if _button == null:
		return
	var cs := _selected_collider()
	_button.visible = cs != null          # 选了别的就不占地方
	if _popup != null and _popup.visible:
		if cs == null:
			_popup.hide()
		else:
			_show_popup(cs)               # 换选另一个碰撞体时跟着切换


func _on_button_pressed() -> void:
	var cs := _selected_collider()
	if cs == null:
		return
	_show_popup(cs)


func _ensure_popup() -> void:
	if _popup != null:
		return
	_popup = PopupPanel.new()
	_popup.title = "凹多边形碰撞调参"
	_popup.wrap_controls = true
	_popup_margin = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		_popup_margin.add_theme_constant_override("margin_" + side, 10)
	_popup.add_child(_popup_margin)
	# 弹窗挂在编辑器根控件下（插件不能直接往场景树里塞窗口）
	EditorInterface.get_base_control().add_child(_popup)


func _show_popup(cs: CollisionShape3D) -> void:
	_ensure_popup()
	if _panel != null:
		_panel.queue_free()
		_panel = null
	_panel = TunerPanelScript.new()
	_panel.custom_minimum_size = Vector2(360, 0)
	_popup_margin.add_child(_panel)
	_panel.call("setup", cs)
	_popup.reset_size()
	_popup.popup_centered()

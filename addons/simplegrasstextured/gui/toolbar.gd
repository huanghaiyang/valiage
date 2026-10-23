# toolbar.gd
# This file is part of: SimpleGrassTextured
# Copyright (c) 2023 IcterusGames
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the 
# "Software"), to deal in the Software without restriction, including 
# without limitation the rights to use, copy, modify, merge, publish, 
# distribute, sublicense, and/or sell copies of the Software, and to 
# permit persons to whom the Software is furnished to do so, subject to 
# the following conditions: 
#
# The above copyright notice and this permission notice shall be 
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, 
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF 
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. 
# IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY 
# CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, 
# TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE 
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

@tool
extends Control

## ★ 本项目改动：内置草叶面数（1~6）切换信号
signal planes_changed(planes: int)
## ★ 本项目改动：V 字张开开关 / 张开量
signal v_fold_changed(enabled: bool)
signal v_spread_changed(spread: float)
## ★ 本项目改动：笔刷分类切换（0=花, 1=草, 2=树, 3=藤蔓）
signal category_changed(category: int)

enum MENU_SHAPE_ID {
	TOOL_SHAPE_SPHERE,
	TOOL_SHAPE_CYLINDER,
	TOOL_SHAPE_CYLINDER_INF_H,
	TOOL_SHAPE_BOX,
	TOOL_SHAPE_BOX_INF_H,
}

const DEFAULT_RADIUS := 2.0
const DEFAULT_DENSITY := 25.0
const DEFAULT_SCALE := 1.0
const DEFAULT_ROTATION := 0.0
const DEFAULT_ROTATION_RAND := 1.0
const DEFAULT_DISTANCE := 0.25

var _shortcut_radius_inc := Shortcut.new()
var _shortcut_radius_dec := Shortcut.new()
var _shortcut_density_inc := Shortcut.new()
var _shortcut_density_dec := Shortcut.new()
var _plugin: EditorPlugin = null
var _grass_selected = null

@onready var button_airbrush :Button = %ButtonAirbrush
@onready var button_pencil :Button = %ButtonPencil
@onready var button_eraser :Button = %ButtonEraser
@onready var button_density :Button = %IconDensity
@onready var slider_radius :HSlider = $HSliderRadius
@onready var slider_density :HSlider = $HSliderDensity
@onready var edit_slope_range: Control = %SlopeRange
@onready var edit_scale :EditorSpinSlider
@onready var edit_rotation :EditorSpinSlider
@onready var edit_rotation_rand :EditorSpinSlider
@onready var edit_distance :EditorSpinSlider
@onready var label_stats :Label = $LabelStats
## ★ 本项目改动：面数选择控件
@onready var option_planes :OptionButton = %OptionPlanes
## ★ 本项目改动：V 字张开控件（**代码创建**，不改 toolbar.tscn —— 手写 unique_id 容易让 % 查找失效）
var check_v_fold :CheckBox = null
var edit_v_spread :EditorSpinSlider = null
var _v_cont :HBoxContainer = null
## ★ 本项目改动：笔刷分类控件（代码构建，同上理由）
var _category_option :OptionButton = null
var _category_cont :HBoxContainer = null
## ★ 本项目改动：同步守卫（OptionButton 无 select_no_signal，用 bool 挡住 set_current_grass 里的回写）
var _syncing := false

@onready var _label_radius :Label = $HSliderRadius/Label
@onready var _label_density :Label = $HSliderDensity/Label
@onready var _button_more :MenuButton = $ButtonMore
@onready var _airbrush_options: MenuButton = %AirbrushOptions
@onready var _pencil_options: MenuButton = %PencilOptions
@onready var _eraser_options: MenuButton = %EraserOptions
@onready var _tween_radius :Tween = null
@onready var _tween_density :Tween = null


func _ready() -> void:
	edit_scale = _create_slider("", 0.01, 10.0, 0.01, DEFAULT_SCALE)
	edit_rotation = _create_slider("", 0.0, 360.0, 0.1, DEFAULT_ROTATION)
	edit_rotation_rand = _create_slider("", 0.0, 1.0, 0.01, DEFAULT_ROTATION_RAND)
	edit_distance = _create_slider("", 0.0, 5.0, 0.01, DEFAULT_DISTANCE)
	%ScaleCont.add_child(edit_scale)
	%RotationCont.add_child(edit_rotation)
	%RotationRandCont.add_child(edit_rotation_rand)
	%DistanceCont.add_child(edit_distance)
	# ★ 本项目改动：面数下拉（信号在 _ready 里接线，避免场景连接漏掉）
	if option_planes != null:
		option_planes.clear()
		# ★ 支持 1~6 面：面数越多，同一株草在各观察方向上的覆盖越均匀（也更耗顶点）
		for planes in range(1, 7):
			option_planes.add_item("%d 面" % planes, planes)
		option_planes.select(option_planes.get_item_index(2))
		if not option_planes.item_selected.is_connected(_on_option_planes_item_selected):
			option_planes.item_selected.connect(_on_option_planes_item_selected)
	# ★ 本项目改动：V 字张开控件（开关 + 张开量），紧跟在"面数"后面
	_build_v_controls()
	# ★ 本项目改动：笔刷分类控件，紧跟在 V 字控件后面
	_build_category_controls()


func _unhandled_input(event :InputEvent) -> void:
	if not event.is_pressed():
		return
	if _shortcut_radius_inc.matches_event(event):
		slider_radius.value += 0.1
	if _shortcut_radius_dec.matches_event(event):
		slider_radius.value -= 0.1
	if slider_density.editable and _shortcut_density_inc.matches_event(event):
		slider_density.value += 1
	if slider_density.editable and _shortcut_density_dec.matches_event(event):
		slider_density.value -= 1


func set_plugin(plugin :EditorPlugin) -> void:
	_plugin = plugin
	theme_changed.connect(_on_theme_changed)
	%ButtonMore.set_plugin(plugin)
	var config := ConfigFile.new()
	config.load("res://addons/simplegrasstextured/plugin.cfg")
	%LabelVersion.text = config.get_value("plugin", "version")
	button_airbrush.shortcut = plugin.get_custom_setting("SimpleGrassTextured/Shortcuts/airbrush_tool")
	button_pencil.shortcut = plugin.get_custom_setting("SimpleGrassTextured/Shortcuts/pencil_tool")
	button_eraser.shortcut = plugin.get_custom_setting("SimpleGrassTextured/Shortcuts/eraser_tool")
	button_airbrush.gui_input.connect(_on_button_tool_gui_input.bind(button_airbrush, _airbrush_options))
	button_pencil.gui_input.connect(_on_button_tool_gui_input.bind(button_pencil, _pencil_options))
	button_eraser.gui_input.connect(_on_button_tool_gui_input.bind(button_eraser, _eraser_options))
	_shortcut_radius_inc = plugin.get_custom_setting("SimpleGrassTextured/Shortcuts/radius_increment")
	_shortcut_radius_dec = plugin.get_custom_setting("SimpleGrassTextured/Shortcuts/radius_decrement")
	_shortcut_density_inc = plugin.get_custom_setting("SimpleGrassTextured/Shortcuts/density_increment")
	_shortcut_density_dec = plugin.get_custom_setting("SimpleGrassTextured/Shortcuts/density_decrement")
	_airbrush_options.get_popup().add_radio_check_item("Cylinder", MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER)
	_airbrush_options.get_popup().add_radio_check_item("Box", MENU_SHAPE_ID.TOOL_SHAPE_BOX)
	_airbrush_options.get_popup().about_to_popup.connect(_on_tool_options_about_to_popup.bind(_airbrush_options))
	_airbrush_options.get_popup().id_pressed.connect(_on_sgt_shape_menu_pressed.bind("airbrush", _airbrush_options.get_popup()))
	_pencil_options.get_popup().add_radio_check_item("Cylinder", MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER)
	_pencil_options.get_popup().add_radio_check_item("Box", MENU_SHAPE_ID.TOOL_SHAPE_BOX)
	_pencil_options.get_popup().about_to_popup.connect(_on_tool_options_about_to_popup.bind(_pencil_options))
	_pencil_options.get_popup().id_pressed.connect(_on_sgt_shape_menu_pressed.bind("pencil", _pencil_options.get_popup()))
	_eraser_options.get_popup().add_radio_check_item("Sphere", MENU_SHAPE_ID.TOOL_SHAPE_SPHERE)
	_eraser_options.get_popup().add_radio_check_item("Cylinder", MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER)
	_eraser_options.get_popup().add_radio_check_item("Infinite vertical cylinder", MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER_INF_H)
	_eraser_options.get_popup().add_radio_check_item("Box", MENU_SHAPE_ID.TOOL_SHAPE_BOX)
	_eraser_options.get_popup().add_radio_check_item("Infinite vertical box", MENU_SHAPE_ID.TOOL_SHAPE_BOX_INF_H)
	_eraser_options.get_popup().about_to_popup.connect(_on_tool_options_about_to_popup.bind(_eraser_options))
	_eraser_options.get_popup().id_pressed.connect(_on_sgt_shape_menu_pressed.bind("eraser", _eraser_options.get_popup()))
	_on_theme_changed()


func set_current_grass(grass) -> void:
	_grass_selected = grass
	%ButtonMore.set_current_grass(grass)
	if _grass_selected == null:
		return
	# ★ 本项目改动：把草节点上的面数同步到下拉（类型安全：读不到/类型不对就保持当前选择）
	if option_planes != null:
		var planes: Variant = _grass_selected.get("mesh_planes")
		var idx := -1
		if planes is int:
			idx = option_planes.get_item_index(int(planes))
		elif planes is float:
			idx = option_planes.get_item_index(int(round(float(planes))))
		if idx >= 0:
			option_planes.select(idx)
	# ★ 本项目改动：同步 V 字开关 / 张开量（类型安全：读不到或类型不对就保持当前值）
	#   set_pressed_no_signal / set_value_no_signal：同步时**不能**触发信号，
	#   否则会把工具栏的初始值反向写回刚选中的草节点。
	if check_v_fold != null:
		var fold: Variant = _grass_selected.get("v_fold")
		if fold is bool:
			check_v_fold.set_pressed_no_signal(fold)
	if edit_v_spread != null:
		var spread: Variant = _grass_selected.get("v_spread")
		if spread is float or spread is int:
			edit_v_spread.set_value_no_signal(float(spread))
	# ★ 本项目改动：同步笔刷分类（类型安全 + 同步守卫避免回写）
	if _category_option != null:
		var cat: Variant = _grass_selected.get("brush_category")
		var cat_idx := -1
		if cat is int:
			cat_idx = _category_option.get_item_index(int(cat))
		elif cat is float:
			cat_idx = _category_option.get_item_index(int(round(float(cat))))
		# 找不到（旧节点没这个属性时）就保持默认草(1)，不做任何操作
		if cat_idx >= 0:
			_syncing = true
			_category_option.select(cat_idx)
			_syncing = false
	for tool_name in _grass_selected.sgt_tool_shape:
		match tool_name:
			"airbrush":
				_update_shape_menu_from_grass(_airbrush_options.get_popup(), _grass_selected.sgt_tool_shape[tool_name])
			"pencil":
				_update_shape_menu_from_grass(_pencil_options.get_popup(), _grass_selected.sgt_tool_shape[tool_name])
			"eraser":
				_update_shape_menu_from_grass(_eraser_options.get_popup(), _grass_selected.sgt_tool_shape[tool_name])


func set_density_modulate(color: Color) -> void:
	%IconDensity.self_modulate = color
	slider_density.modulate = color


## ★ 本项目改动：V 字张开控件。
##   全部**代码创建**，不手写 toolbar.tscn：那需要编 unique_id，写错会让 `%名字` 查找失效。
##   位置紧跟"面数"（PlaneCont）之后。
func _build_v_controls() -> void:
	if _v_cont != null:
		return
	_v_cont = HBoxContainer.new()
	_v_cont.name = "VCont"
	_v_cont.tooltip_text = "V 字张开：每面两片从底部向两侧张开，让草从正上方看也有体积（不再是纸片）"
	check_v_fold = CheckBox.new()
	check_v_fold.name = "CheckVFold"
	check_v_fold.tooltip_text = "开启 V 字张开（关掉 = 原来的单片竖直卡）"
	check_v_fold.button_pressed = true
	_v_cont.add_child(check_v_fold)
	edit_v_spread = _create_slider("", 0.0, 1.5, 0.05, 0.45)
	edit_v_spread.tooltip_text = "顶部水平张开量（米）：0 = 平卡；0.4~0.6 较自然"
	_v_cont.add_child(edit_v_spread)
	add_child(_v_cont)
	# 插到"面数"后面（PlaneCont 是直接子节点）
	var plane_cont := get_node_or_null("PlaneCont")
	if plane_cont != null:
		move_child(_v_cont, plane_cont.get_index() + 1)
	check_v_fold.toggled.connect(_on_check_v_fold_toggled)
	edit_v_spread.value_changed.connect(_on_edit_v_spread_value_changed)


func _on_check_v_fold_toggled(enabled :bool) -> void:
	v_fold_changed.emit(enabled)


func _on_edit_v_spread_value_changed(value :float) -> void:
	v_spread_changed.emit(value)


## ★ 本项目改动：笔刷分类控件。
##   代码构建 HBoxContainer + OptionButton，紧跟 VCont 之后。
##   四个选项：花(0)、草(1)、树(2)、藤蔓(3)，默认草。
func _build_category_controls() -> void:
	if _category_cont != null:
		return
	_category_cont = HBoxContainer.new()
	_category_cont.name = "CategoryCont"
	var label := Label.new()
	label.text = "分类"
	_category_cont.add_child(label)
	_category_option = OptionButton.new()
	_category_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_category_option.custom_minimum_size.x = 90
	_category_option.add_item("花", 0)
	_category_option.add_item("草", 1)
	_category_option.add_item("树", 2)
	_category_option.add_item("藤蔓", 3)
	_category_option.select(_category_option.get_item_index(1))   # 默认草
	_category_option.tooltip_text = "笔刷分类：花 / 草 / 树 / 藤蔓，便于按类别管理草地节点"
	_category_cont.add_child(_category_option)
	add_child(_category_cont)
	# 插到 VCont 后面
	var v_cont := get_node_or_null("VCont")
	if v_cont != null:
		move_child(_category_cont, v_cont.get_index() + 1)
	if not _category_option.item_selected.is_connected(_on_category_option_item_selected):
		_category_option.item_selected.connect(_on_category_option_item_selected)


func _on_category_option_item_selected(index: int) -> void:
	if _syncing:
		return
	if _category_option == null:
		return
	category_changed.emit(_category_option.get_item_id(index))


func _create_slider(label :String, min_value :float, max_value :float, step :float, value :float = 0.0) -> EditorSpinSlider:
	var slider := EditorSpinSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.step = step;
	slider.min_value = min_value
	slider.max_value = max_value
	slider.label = label
	slider.value = value
	slider.custom_minimum_size.x = 75
	return slider


func _on_tool_options_about_to_popup(_button_options: MenuButton) -> void:
	set_current_grass(_grass_selected)


func _update_shape_menu_from_grass(popupmenu: PopupMenu, plugin_id_shape: int) -> void:
	for i in popupmenu.item_count:
		popupmenu.set_item_checked(i, false)
	var idx := -1
	match _plugin.get_tool_shape_name(plugin_id_shape):
		"sphere":
			idx = popupmenu.get_item_index(MENU_SHAPE_ID.TOOL_SHAPE_SPHERE)
		"cylinder":
			idx = popupmenu.get_item_index(MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER)
		"cylinder_inf_h":
			idx = popupmenu.get_item_index(MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER_INF_H)
		"box":
			idx = popupmenu.get_item_index(MENU_SHAPE_ID.TOOL_SHAPE_BOX)
		"box_inf_h":
			idx = popupmenu.get_item_index(MENU_SHAPE_ID.TOOL_SHAPE_BOX_INF_H)
		_:
			idx = -1
	if idx == -1:
		return
	popupmenu.set_item_checked(idx, true)


func _on_sgt_shape_menu_pressed(id: int, tool_name: String, popupmenu: PopupMenu) -> void:
	if _grass_selected == null:
		return
	for i in popupmenu.item_count:
		popupmenu.set_item_checked(i, false)
	var idx := popupmenu.get_item_index(id)
	if idx == -1:
		return
	popupmenu.set_item_checked(idx, true)
	var shape_name := ""
	match id:
		MENU_SHAPE_ID.TOOL_SHAPE_SPHERE:
			shape_name = "sphere"
		MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER:
			shape_name = "cylinder"
		MENU_SHAPE_ID.TOOL_SHAPE_CYLINDER_INF_H:
			shape_name = "cylinder_inf_h"
		MENU_SHAPE_ID.TOOL_SHAPE_BOX:
			shape_name = "box"
		MENU_SHAPE_ID.TOOL_SHAPE_BOX_INF_H:
			shape_name = "box_inf_h"
	_plugin.set_tool_shape(tool_name, shape_name)
	_plugin.set_tool(tool_name)


func _on_h_slider_radius_value_changed(value :float) -> void:
	if _tween_radius != null:
		_tween_radius.kill()
	_label_radius.set(&"theme_override_colors/font_outline_color", _label_radius.get_theme_color(&"font_color").inverted())
	_tween_radius = _label_radius.create_tween()
	_tween_radius.tween_property(_label_radius, ^"modulate", Color.WHITE, 0.1)
	_tween_radius.tween_interval(2)
	_tween_radius.tween_property(_label_radius, ^"modulate", Color(1,1,1,0), 2)
	_label_radius.text = "%0.1f" % value
	slider_radius.tooltip_text = "(" + _shortcut_radius_dec.get_as_text() + ") - (" + _shortcut_radius_inc.get_as_text() + ")\n"
	slider_radius.tooltip_text += "Radius = %0.1f" % value


func _on_h_slider_density_value_changed(value :float) -> void:
	if _tween_density != null:
		_tween_density.kill()
	_label_density.set(&"theme_override_colors/font_outline_color", _label_density.get_theme_color(&"font_color").inverted())
	_tween_density = _label_density.create_tween()
	_tween_density.tween_property(_label_density, ^"modulate", Color.WHITE, 0.1)
	_tween_density.tween_interval(2)
	_tween_density.tween_property(_label_density, ^"modulate", Color(1,1,1,0), 2)
	_label_density.text = str(value)
	slider_density.tooltip_text = "(" + _shortcut_density_dec.get_as_text() + ") - (" + _shortcut_density_inc.get_as_text() + ")\n"
	slider_density.tooltip_text += "Density = %0.0f" % value


func _on_theme_changed() -> void:
	%IconScale.icon = get_theme_icon(&"ToolScale", &"EditorIcons")
	%IconRotation.icon = get_theme_icon(&"ToolRotate", &"EditorIcons")
	%IconRotationRand.icon = get_theme_icon(&"RandomNumberGenerator", &"EditorIcons")
	var base_color: Color = EditorInterface.get_base_control().get_theme_color(&"base_color", &"Editor")
	if base_color.get_luminance() < 0.5:
		button_airbrush.icon = load("res://addons/simplegrasstextured/images/sgt_icon_airbrush.svg")
		button_pencil.icon = load("res://addons/simplegrasstextured/images/sgt_icon_pen.svg")
		button_eraser.icon = load("res://addons/simplegrasstextured/images/sgt_icon_eraser.svg")
		_airbrush_options.icon = load("res://addons/simplegrasstextured/images/sgt_icon_arrow_up.svg")
		_pencil_options.icon = load("res://addons/simplegrasstextured/images/sgt_icon_arrow_up.svg")
		_eraser_options.icon = load("res://addons/simplegrasstextured/images/sgt_icon_arrow_up.svg")
		%IconSlope.icon = load("res://addons/simplegrasstextured/images/sgt_icon_slope.svg")
		%IconRadius.icon = load("res://addons/simplegrasstextured/images/sgt_icon_radius.svg")
		%IconDensity.icon = load("res://addons/simplegrasstextured/images/sgt_icon_density.svg")
		%IconDistance.icon = load("res://addons/simplegrasstextured/images/sgt_icon_distance.svg")
	else:
		button_airbrush.icon = load("res://addons/simplegrasstextured/images/sgt_icon_airbrush_dark.svg")
		button_pencil.icon = load("res://addons/simplegrasstextured/images/sgt_icon_pen_dark.svg")
		button_eraser.icon = load("res://addons/simplegrasstextured/images/sgt_icon_eraser_dark.svg")
		_airbrush_options.icon = load("res://addons/simplegrasstextured/images/sgt_icon_arrow_up_dark.svg")
		_pencil_options.icon = load("res://addons/simplegrasstextured/images/sgt_icon_arrow_up_dark.svg")
		_eraser_options.icon = load("res://addons/simplegrasstextured/images/sgt_icon_arrow_up_dark.svg")
		%IconSlope.icon = load("res://addons/simplegrasstextured/images/sgt_icon_slope_dark.svg")
		%IconRadius.icon = load("res://addons/simplegrasstextured/images/sgt_icon_radius_dark.svg")
		%IconDensity.icon = load("res://addons/simplegrasstextured/images/sgt_icon_density_dark.svg")
		%IconDistance.icon = load("res://addons/simplegrasstextured/images/sgt_icon_distance_dark.svg")
	if _button_more != null:
		_button_more.icon = get_theme_icon(&"GuiTabMenuHl", &"EditorIcons")
	# Test that the icons size matches with editor UI scale
	var _ed_scale := 1.0
	var es: int = EditorInterface.get_editor_settings().get_setting("interface/editor/display_scale")
	if es == 7:
		_ed_scale = EditorInterface.get_editor_settings().get_setting("interface/editor/custom_display_scale")
	else:
		_ed_scale = [1.0, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0][clamp(es, 0, 6)]
	if load("res://addons/simplegrasstextured/images/sgt_icon_density.svg").get_width() != roundi(16 * _ed_scale):
		$TimerReimportIcons.start()


func _on_panel_container_gui_input(event) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var win = load("res://addons/simplegrasstextured/gui/about.tscn").instantiate()
			get_window().add_child(win)
			win.popup_centered()


func _on_icon_slope_pressed() -> void:
	edit_slope_range.set_value_min(0)
	edit_slope_range.set_value_max(45)


func _on_icon_scale_pressed() -> void:
	edit_scale.value = DEFAULT_SCALE


func _on_icon_rotation_pressed() -> void:
	edit_rotation.value = DEFAULT_ROTATION


func _on_icon_rotation_rand_pressed() -> void:
	edit_rotation_rand.value = DEFAULT_ROTATION_RAND


func _on_icon_distance_pressed() -> void:
	edit_distance.value = DEFAULT_DISTANCE


func _on_icon_radius_pressed() -> void:
	slider_radius.value = DEFAULT_RADIUS


func _on_icon_radius_2_pressed() -> void:
	slider_density.value = DEFAULT_DENSITY


## ★ 本项目改动：面数下拉改变
func _on_option_planes_item_selected(index: int) -> void:
	if option_planes == null:
		return
	planes_changed.emit(option_planes.get_item_id(index))


func _on_timer_reimport_icons_timeout() -> void:
	if EditorInterface.get_resource_filesystem().is_scanning():
		return
	$TimerReimportIcons.stop()
	EditorInterface.get_resource_filesystem().reimport_files([
	"res://addons/simplegrasstextured/sgt_icon.svg",
	"res://addons/simplegrasstextured/sgt_icon_48.svg",
	"res://addons/simplegrasstextured/images/sgt_icon_density.svg",
	"res://addons/simplegrasstextured/images/sgt_icon_distance.svg",
	"res://addons/simplegrasstextured/images/sgt_icon_radius.svg",
	"res://addons/simplegrasstextured/images/sgt_icon_slope.svg",
	"res://addons/simplegrasstextured/images/sgt_icon_airbrush.svg",
	"res://addons/simplegrasstextured/images/sgt_icon_pen.svg",
	"res://addons/simplegrasstextured/images/sgt_icon_eraser.svg"
	])


func _on_button_tool_gui_input(event: InputEvent, tool: Button, button_options: MenuButton) -> void:
	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			button_options.get_popup().popup(Rect2(tool.global_position + Vector2(tool.size.x, 0), Vector2.ZERO))

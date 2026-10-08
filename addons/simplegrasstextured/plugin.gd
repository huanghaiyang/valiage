# plugin.gd
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
extends EditorPlugin

const DEFAULT_POINTER_DEPTH := 10.0
# ★ 本项目改动：「定位」相机取景参数
#   相机到目标的最小距离：小于它就被推远，大于它保持原距离（绝不拉近）
const LOCATE_MIN_DISTANCE := 18.0
#   视线俯角（0.35 ≈ 19°），让画面里能看到地面而不是平视
const LOCATE_TILT := 0.35
#   视野中心相对草抬高多少米（草因此落在画面偏下，上方留出环境）
const LOCATE_VIEW_HEIGHT := 4.0
#   选中高亮环的半径（米），以及一次最多显示多少个环
const LOCATE_SELECTION_RADIUS := 0.85
const LOCATE_MAX_MARKERS := 256
# ★ 本项目改动：草地数据外挂的默认目录（相对 res://，不要放 addons/ 里以免插件重装被删）
const EXTERNALIZE_DIR := "res://maps"
#   记录「这个节点对应的外挂文件名 id」的节点 meta key（随场景保存，改名后仍复用同一文件）
const EXTERNALIZE_META_KEY := &"sgt_external_id"

enum EVENT_MOUSE {
	EVENT_NONE,
	EVENT_MOVE,
	EVENT_CLICK,
}

enum TOOL {
	NONE,
	PENCIL,
	AIRBRUSH,
	ERASER
}

enum TOOL_SHAPE {
	SPHERE,
	CYLINDER,
	CYLINDER_INF_H,
	BOX,
	BOX_INF_H
}

var _raycast_3d : RayCast3D = null
var _pointer_decal : Decal = null
var _pointer_img_circle = load("res://addons/simplegrasstextured/images/pointer.png")
var _pointer_img_rect = load("res://addons/simplegrasstextured/images/pointer_rect.png")
var _pointer_depth: float = DEFAULT_POINTER_DEPTH
var _pointer_rotate: bool = true
var _grass_selected = null
var _position_draw := Vector3.ZERO
var _normal_draw := Vector3.ZERO
var _object_draw : Object = null
var _edit_density: float = 25.0
var _edit_radius := 2.0
var _edit_slope := Vector2(0, 45)
var _edit_scale := Vector3.ONE
var _edit_rotation := 0.0
var _edit_rotation_rand := 1.0
var _edit_tool: TOOL = TOOL.AIRBRUSH : set = _on_set_tool
var _gui_toolbar = null
var _gui_toolbar_up = null
var _time_draw := 0
var _draw_paused := true
var _mouse_event := EVENT_MOUSE.EVENT_NONE
var _project_ray_origin := Vector3.INF
var _project_ray_normal := Vector3.INF
var _inspector_plugin : EditorInspectorPlugin = null
var _evaluate_draw_time: int = 100
var _prev_config := ""
# ★ 本项目改动：左侧「草地实例」停靠面板 + 定位/选中高亮
var _gui_grass_list = null
var _focus_helper : MeshInstance3D = null
var _focus_helper_material : StandardMaterial3D = null
var _focus_helpers : Array[MeshInstance3D] = []
var _custom_settings := [{
		"name": "SimpleGrassTextured/General/default_terrain_physics_layer",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_LAYERS_3D_PHYSICS,
		"hint_string": "",
		"default": pow(2, 32) - 1,
		"basic": true
	},{
		"name": "SimpleGrassTextured/General/evaluate_draw_time",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Slow:150,Normal:100,Fast:50,Very fast:25",
		"default": 50,
		"basic": false
	},{
		"name": "SimpleGrassTextured/General/interactive_resolution",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Low:256,High:512",
		"default": 512,
		"basic": false
	},{
		"name": "SimpleGrassTextured/General/interactive_resolution.android",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Low:256,High:512",
		"default": 256,
		"basic": false
	},{
		"name": "SimpleGrassTextured/General/interactive_resolution.ios",
		"type": TYPE_INT,
		"hint": PROPERTY_HINT_ENUM,
		"hint_string": "Low:256,High:512",
		"default": 256,
		"basic": false
	},{
		"name": "SimpleGrassTextured/Shortcuts/airbrush_tool",
		"type": TYPE_OBJECT,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shortcut",
		"default": _create_shortcut(KEY_D),
		"basic": true
	},{
		"name": "SimpleGrassTextured/Shortcuts/pencil_tool",
		"type": TYPE_OBJECT,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shortcut",
		"default": _create_shortcut(KEY_B),
		"basic": true
	},{
		"name": "SimpleGrassTextured/Shortcuts/eraser_tool",
		"type": TYPE_OBJECT,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shortcut",
		"default": _create_shortcut(KEY_X),
		"basic": true
	},{
		"name": "SimpleGrassTextured/Shortcuts/radius_increment",
		"type": TYPE_OBJECT,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shortcut",
		"default": _create_shortcut(KEY_BRACKETRIGHT),
		"basic": true
	},{
		"name": "SimpleGrassTextured/Shortcuts/radius_decrement",
		"type": TYPE_OBJECT,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shortcut",
		"default": _create_shortcut(KEY_BRACKETLEFT),
		"basic": true
	},{
		"name": "SimpleGrassTextured/Shortcuts/density_increment",
		"type": TYPE_OBJECT,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shortcut",
		"default": _create_shortcut(KEY_EQUAL),
		"basic": true
	},{
		"name": "SimpleGrassTextured/Shortcuts/density_decrement",
		"type": TYPE_OBJECT,
		"hint": PROPERTY_HINT_RESOURCE_TYPE,
		"hint_string": "Shortcut",
		"default": _create_shortcut(KEY_MINUS),
		"basic": true
	}
]


func _enter_tree() -> void:
	if not get_tree().has_user_signal(&"sgt_globals_params_changed"):
		get_tree().add_user_signal(&"sgt_globals_params_changed")
	_verify_global_shader_parameters()
	_enable_shaders(true)
	_init_default_project_settings()
	_prev_config = _custom_config_memorize()
	if ProjectSettings.has_signal(&"settings_changed"):
		ProjectSettings.connect(&"settings_changed", _on_project_settings_changed)
	# Must ensure the resource file of default_mesh.tres match the current Godot version
	var default_mesh = load("res://addons/simplegrasstextured/default_mesh.tres")
	if not default_mesh or not default_mesh.has_meta(&"GodotVersion") or default_mesh.get_meta(&"GodotVersion") != Engine.get_version_info()["string"]:
		push_warning("SimpleGrassTextured, updating file res://addons/simplegrasstextured/default_mesh.tres")
		default_mesh = null
		var mesh_builder = load("res://addons/simplegrasstextured/default_mesh_builder.gd").new()
		mesh_builder.rebuild_and_save_default_mesh()
		default_mesh = load("res://addons/simplegrasstextured/default_mesh.tres")
		if default_mesh:
			default_mesh.emit_changed()
			print("SimpleGrassTextured, file updated successfully res://addons/simplegrasstextured/default_mesh.tres")
		else:
			push_error("SimpleGrassTextured, error updating file res://addons/simplegrasstextured/default_mesh.tres")
	add_custom_type(
		"SimpleGrassTextured",
		"MultiMeshInstance3D",
		load("res://addons/simplegrasstextured/grass.gd"),
		load("res://addons/simplegrasstextured/sgt_icon.svg")
	)
	
	ProjectSettings.set_setting("layer_names/3d_render/layer_17", "SimpleGrassTextured interactive layer")
	
	_gui_toolbar = load("res://addons/simplegrasstextured/gui/toolbar.tscn").instantiate()
	_gui_toolbar.visible = false
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, _gui_toolbar)
	_gui_toolbar.set_plugin(self)
	
	_gui_toolbar_up = load("res://addons/simplegrasstextured/gui/toolbar_up.tscn").instantiate()
	_gui_toolbar_up.visible = false
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _gui_toolbar_up)
	_gui_toolbar_up.set_plugin(self)
	
	# ★ 本项目改动：在编辑器左侧停靠区加一个「草地实例」面板
	#   列出当前草地节点刷出的每一株草（总数 / 世界坐标），
	#   左键单击定位、右键删除（删除进入编辑器撤销堆栈）。
	_gui_grass_list = load("res://addons/simplegrasstextured/gui/grass_list_dock.gd").new()
	_gui_grass_list.name = "SimpleGrassTexturedInstances"
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UR, _gui_grass_list)
	_gui_grass_list.set_plugin(self)
	var editor_selection := EditorInterface.get_selection()
	if editor_selection != null and not editor_selection.selection_changed.is_connected(_on_editor_selection_changed):
		editor_selection.selection_changed.connect(_on_editor_selection_changed)
	
	_inspector_plugin = load("res://addons/simplegrasstextured/sgt_inspector.gd").new()
	add_inspector_plugin(_inspector_plugin)
	
	_raycast_3d = RayCast3D.new()
	_raycast_3d.collision_mask = 4294967295
	_raycast_3d.visible = false
	_pointer_decal = Decal.new()
	_pointer_decal.set_texture(Decal.TEXTURE_ALBEDO, _pointer_img_circle)
	_pointer_decal.visible = false
	_pointer_decal.extents = Vector3(_edit_radius, _pointer_depth, _edit_radius)
	_pointer_decal.upper_fade = 0
	_pointer_decal.lower_fade = 0
	add_child(_raycast_3d)
	add_child(_pointer_decal)
	
	_gui_toolbar.slider_radius.value_changed.connect(_on_slider_radius_value_changed)
	_gui_toolbar.slider_density.value_changed.connect(_on_slider_density_value_changed)
	_gui_toolbar.button_airbrush.toggled.connect(_on_button_airbrush_toggled)
	_gui_toolbar.button_pencil.toggled.connect(_on_button_pencil_toggled)
	_gui_toolbar.button_eraser.toggled.connect(_on_button_eraser_toggled)
	_gui_toolbar.edit_slope_range.value_changed.connect(_on_edit_slope_range_changed)
	_gui_toolbar.edit_scale.value_changed.connect(_on_edit_scale_value_changed)
	_gui_toolbar.edit_rotation.value_changed.connect(_on_edit_rotation_value_changed)
	_gui_toolbar.edit_rotation_rand.value_changed.connect(_on_edit_rotation_rand_value_changed)
	_gui_toolbar.edit_distance.value_changed.connect(_on_edit_distance_value_changed)
	_edit_tool = TOOL.AIRBRUSH


func _exit_tree() -> void:
	var current_config := _custom_config_memorize()
	if current_config != _prev_config:
		# Force save settings if some shortcut has been changed
		ProjectSettings.save()
	_grass_selected = null
	_raycast_3d.queue_free()
	_pointer_decal.queue_free()
	# ★ 本项目改动：卸下草地实例面板 / 定位高亮，并断开选择变化信号
	var editor_selection := EditorInterface.get_selection()
	if editor_selection != null and editor_selection.selection_changed.is_connected(_on_editor_selection_changed):
		editor_selection.selection_changed.disconnect(_on_editor_selection_changed)
	if _gui_grass_list != null:
		remove_control_from_docks(_gui_grass_list)
		_gui_grass_list.queue_free()
		_gui_grass_list = null
	clear_selection_highlights()
	_focus_helper = null
	remove_custom_type("SimpleGrassTextured")
	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_BOTTOM, _gui_toolbar)
	_gui_toolbar.queue_free()
	remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _gui_toolbar_up)
	_gui_toolbar_up.queue_free()
	if _inspector_plugin != null:
		remove_inspector_plugin(_inspector_plugin)


func _enable_plugin() -> void:
	_verify_global_shader_parameters()


func _disable_plugin() -> void:
	_enable_shaders(false)
	remove_autoload_singleton("SimpleGrass")
	if ProjectSettings.has_setting("shader_globals/sgt_legacy_renderer"):
		ProjectSettings.set_setting("shader_globals/sgt_legacy_renderer", null)
	if ProjectSettings.has_setting("shader_globals/sgt_player_position"):
		ProjectSettings.set_setting("shader_globals/sgt_player_position", null)
	if ProjectSettings.has_setting("shader_globals/sgt_player_mov"):
		ProjectSettings.set_setting("shader_globals/sgt_player_mov", null)
	if ProjectSettings.has_setting("shader_globals/sgt_normal_displacement"):
		ProjectSettings.set_setting("shader_globals/sgt_normal_displacement", null)
	if ProjectSettings.has_setting("shader_globals/sgt_motion_texture"):
		ProjectSettings.set_setting("shader_globals/sgt_motion_texture", null)
	if ProjectSettings.has_setting("shader_globals/sgt_wind_direction"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_direction", null)
	if ProjectSettings.has_setting("shader_globals/sgt_wind_movement"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_movement", null)
	if ProjectSettings.has_setting("shader_globals/sgt_wind_strength"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_strength", null)
	if ProjectSettings.has_setting("shader_globals/sgt_wind_turbulence"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_turbulence", null)
	if ProjectSettings.has_setting("shader_globals/sgt_wind_pattern"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_pattern", null)
	# Remove custom settings from Project Settings
	for entry in _custom_settings:
		if ProjectSettings.has_setting(entry["name"]):
			ProjectSettings.set_setting(entry["name"], null)
	# Fix editor crash when disable plugin while SimpleGrassTextured node is selected
	_grass_selected = null
	var scene_root = EditorInterface.get_edited_scene_root()
	if scene_root != null:
		EditorInterface.edit_node(scene_root)
		var selection = EditorInterface.get_selection()
		if selection != null:
			selection.clear()


func _get_plugin_name() -> String:
	return "SimpleGrassTextured"


func _handles(object) -> bool:
	if object != null and object.has_meta("SimpleGrassTextured") and object.visible:
		_grass_selected = object
		_update_gui()
		_update_pointer()
		if _gui_grass_list != null:
			_gui_grass_list.set_grass(object)
		return true
	_grass_selected = null
	return false


func _edit(object) -> void:
	_grass_selected = object
	_update_gui()
	_update_pointer()
	# 只有真正选中草地节点时才切换面板对象；选中别的节点时保留上次的列表
	if _gui_grass_list != null and object != null and object.has_meta(&"SimpleGrassTextured"):
		_gui_grass_list.set_grass(object)
		_gui_grass_list.refresh_later()


func _make_visible(visible : bool) -> void:
	if visible:
		if _grass_selected != null:
			_update_gui()
		_gui_toolbar.visible = true
		_gui_toolbar_up.visible = true
	else:
		_gui_toolbar.visible = false
		_gui_toolbar_up.visible = false
		_pointer_decal.visible = false
		_grass_selected = null
		_gui_toolbar.set_current_grass(null)
		_gui_toolbar_up.set_current_grass(null)
		if _gui_grass_list != null:
			_gui_grass_list.clear_highlights()


func _physics_process(_delta) -> void:
	if _mouse_event == EVENT_MOUSE.EVENT_CLICK:
		_raycast_3d.global_transform.origin = _project_ray_origin
		_raycast_3d.global_transform.basis.y = _project_ray_normal
		_raycast_3d.target_position = Vector3(0, 100000, 0)
		_raycast_3d.collision_mask = _grass_selected.collision_mask
		_raycast_3d.force_raycast_update()
		if _raycast_3d.is_colliding():
			_position_draw = _raycast_3d.get_collision_point()
			_normal_draw = _raycast_3d.get_collision_normal()
			_object_draw = _raycast_3d.get_collider()
			_eval_brush()
			_time_draw = Time.get_ticks_msec()
			_draw_paused = false
		else:
			_time_draw = 0
			_draw_paused = true
			_object_draw = null
		_mouse_event = EVENT_MOUSE.EVENT_NONE
	elif _mouse_event == EVENT_MOUSE.EVENT_MOVE:
		_raycast_3d.global_transform.origin = _project_ray_origin
		_raycast_3d.global_transform.basis.y = _project_ray_normal
		_raycast_3d.target_position = Vector3(0, 100000, 0)
		_raycast_3d.collision_mask = _grass_selected.collision_mask
		_raycast_3d.force_raycast_update()
		if ( not _raycast_3d.is_colliding()
		or ( _object_draw != null and _raycast_3d.get_collider() != _object_draw )):
			_pointer_decal.visible = false
			_draw_paused = true
			_mouse_event = EVENT_MOUSE.EVENT_NONE
			return
		else:
			_draw_paused = false
		_position_draw = _raycast_3d.get_collision_point()
		_normal_draw = _raycast_3d.get_collision_normal()
		if _pointer_rotate:
			var trans := Transform3D()
			if abs(_normal_draw.z) == 1:
				trans.basis.x = Vector3(1,0,0)
				trans.basis.y = Vector3(0,0,_normal_draw.z)
				trans.basis.z = Vector3(0,_normal_draw.z,0)
			else:
				trans.basis.y = _normal_draw
				trans.basis.x = _normal_draw.cross(trans.basis.z)
				trans.basis.z = trans.basis.x.cross(_normal_draw)
				trans.basis = trans.basis.orthonormalized()
			trans.origin = _position_draw
			_pointer_decal.global_transform = trans
		else:
			_pointer_decal.global_position = _position_draw
			_pointer_decal.rotation = Vector3.ZERO
		_pointer_decal.extents = Vector3(_edit_radius, _pointer_depth, _edit_radius)
		_pointer_decal.visible = _edit_tool != TOOL.NONE
		_mouse_event = EVENT_MOUSE.EVENT_NONE
	
	if _time_draw > 0:
		if not _draw_paused:
			if Time.get_ticks_msec() - _time_draw >= _evaluate_draw_time:
				_time_draw = Time.get_ticks_msec()
				_eval_brush()


func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if _grass_selected == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if _grass_selected.multimesh != null:
		_gui_toolbar.label_stats.text = "Count: " + str(_grass_selected.multimesh.instance_count)
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if _edit_tool == TOOL.NONE:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			if event.pressed:
				if _edit_tool == TOOL.AIRBRUSH:
					get_undo_redo().create_action(_grass_selected.name + " Airbrush tool")
				elif _edit_tool == TOOL.PENCIL:
					get_undo_redo().create_action(_grass_selected.name + " Pencil tool")
				elif _edit_tool == TOOL.ERASER:
					get_undo_redo().create_action(_grass_selected.name + " Eraser tool")
				else:
					get_undo_redo().create_action(_grass_selected.name)
				get_undo_redo().add_undo_property(_grass_selected, &"baked_height_map", _grass_selected.baked_height_map)
				get_undo_redo().add_undo_property(_grass_selected, &"multimesh", _grass_selected.multimesh)
				_project_ray_origin = viewport_camera.project_ray_origin(event.position)
				_project_ray_normal = viewport_camera.project_ray_normal(event.position)
				_mouse_event = EVENT_MOUSE.EVENT_CLICK
			else:
				get_undo_redo().add_do_property(_grass_selected, &"baked_height_map", _grass_selected.baked_height_map)
				get_undo_redo().add_do_property(_grass_selected, &"multimesh", _grass_selected.multimesh)
				get_undo_redo().commit_action()
				# ★ 本项目改动：笔刷一次操作结束 -> 让草地面板补一次延迟刷新
				if _gui_grass_list != null:
					_gui_grass_list.refresh_later()
				_time_draw = 0
				_object_draw = null
				_mouse_event = EVENT_MOUSE.EVENT_NONE
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion:
		if _mouse_event != EVENT_MOUSE.EVENT_CLICK:
			_project_ray_origin = viewport_camera.project_ray_origin(event.position)
			_project_ray_normal = viewport_camera.project_ray_normal(event.position)
			_mouse_event = EVENT_MOUSE.EVENT_MOVE
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _verify_global_shader_parameters() -> void:
	if not ProjectSettings.has_setting("shader_globals/sgt_legacy_renderer"):
		ProjectSettings.set_setting("shader_globals/sgt_legacy_renderer", {
			"type": "int",
			"value": 0
		})
		if RenderingServer.global_shader_parameter_get("sgt_legacy_renderer") == null:
			var using_legacy_renderer = ProjectSettings.get_setting_with_override("rendering/renderer/rendering_method")	== "gl_compatibility"
			RenderingServer.global_shader_parameter_add("sgt_legacy_renderer", RenderingServer.GLOBAL_VAR_TYPE_INT, 1 if using_legacy_renderer else 0)
	
	if not ProjectSettings.has_setting("shader_globals/sgt_player_position"):
		ProjectSettings.set_setting("shader_globals/sgt_player_position", {
			"type": "vec3",
			"value": Vector3(1000000, 1000000, 1000000)
		})
		if RenderingServer.global_shader_parameter_get("sgt_player_position") == null:
			RenderingServer.global_shader_parameter_add("sgt_player_position", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(1000000,1000000,1000000))
	if not ProjectSettings.has_setting("shader_globals/sgt_player_mov"):
		ProjectSettings.set_setting("shader_globals/sgt_player_mov", {
			"type": "vec3",
			"value": Vector3.ZERO
		})
		if RenderingServer.global_shader_parameter_get("sgt_player_mov") == null:
			RenderingServer.global_shader_parameter_add("sgt_player_mov", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	if not ProjectSettings.has_setting("shader_globals/sgt_normal_displacement"):
		ProjectSettings.set_setting("shader_globals/sgt_normal_displacement", {
			"type": "sampler2D",
			"value": "res://addons/simplegrasstextured/images/normal.png"
		})
		if RenderingServer.global_shader_parameter_get("sgt_normal_displacement") == null:
			RenderingServer.global_shader_parameter_add("sgt_normal_displacement", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, load("res://addons/simplegrasstextured/images/normal.png"))
	if not ProjectSettings.has_setting("shader_globals/sgt_motion_texture"):
		ProjectSettings.set_setting("shader_globals/sgt_motion_texture", {
			"type": "sampler2D",
			"value": "res://addons/simplegrasstextured/images/motion.png"
		})
		if RenderingServer.global_shader_parameter_get("sgt_motion_texture") == null:
			RenderingServer.global_shader_parameter_add("sgt_motion_texture", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, load("res://addons/simplegrasstextured/images/motion.png"))
	if not ProjectSettings.has_setting("shader_globals/sgt_wind_direction"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_direction", {
			"type": "vec3",
			"value": Vector3(1, 0, 0)
		})
		if RenderingServer.global_shader_parameter_get("sgt_wind_direction") == null:
			RenderingServer.global_shader_parameter_add("sgt_wind_direction", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3(1, 0, 0))
	if not ProjectSettings.has_setting("shader_globals/sgt_wind_movement"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_movement", {
			"type": "vec3",
			"value": Vector2.ZERO
		})
		if RenderingServer.global_shader_parameter_get("sgt_wind_movement") == null:
			RenderingServer.global_shader_parameter_add("sgt_wind_movement", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	if not ProjectSettings.has_setting("shader_globals/sgt_wind_strength"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_strength", {
			"type": "float",
			"value": 0.15
		})
		if RenderingServer.global_shader_parameter_get("sgt_wind_strength") == null:
			RenderingServer.global_shader_parameter_add("sgt_wind_strength", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.15)
	if not ProjectSettings.has_setting("shader_globals/sgt_wind_turbulence"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_turbulence", {
			"type": "float",
			"value": 1.0
		})
		if RenderingServer.global_shader_parameter_get("sgt_wind_turbulence") == null:
			RenderingServer.global_shader_parameter_add("sgt_wind_turbulence", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 1.0)
	if not ProjectSettings.has_setting("shader_globals/sgt_wind_pattern"):
		ProjectSettings.set_setting("shader_globals/sgt_wind_pattern", {
			"type": "sampler2D",
			"value": "res://addons/simplegrasstextured/images/wind_pattern.png"
		})
		if RenderingServer.global_shader_parameter_get("sgt_wind_pattern") == null:
			RenderingServer.global_shader_parameter_add("sgt_wind_pattern", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, load("res://addons/simplegrasstextured/images/wind_pattern.png"))
	if not ProjectSettings.has_setting("autoload/SimpleGrass"):
		add_autoload_singleton("SimpleGrass", "res://addons/simplegrasstextured/singleton.tscn")


func _enable_shaders(enable :bool) -> void:
	if enable:
		var dir := DirAccess.open("res://")
		var scan := false
		if dir.file_exists("res://addons/simplegrasstextured/shaders/.gdignore"):
			dir.remove("res://addons/simplegrasstextured/shaders/.gdignore")
			scan = true
		if dir.file_exists("res://addons/simplegrasstextured/materials/.gdignore"):
			dir.remove("res://addons/simplegrasstextured/materials/.gdignore")
			scan = true
		if scan:
			EditorInterface.get_resource_filesystem().scan.call_deferred()
	else:
		var file := FileAccess.open("res://addons/simplegrasstextured/shaders/.gdignore", FileAccess.WRITE)
		file.close()
		file = FileAccess.open("res://addons/simplegrasstextured/materials/.gdignore", FileAccess.WRITE)
		file.close()
		EditorInterface.get_resource_filesystem().scan.call_deferred()


func _create_shortcut(keycode :Key) -> Shortcut:
	var shortcut := Shortcut.new()
	var key := InputEventKey.new()
	key.keycode = keycode
	key.pressed = true
	shortcut.events.append(key)
	return shortcut


func _custom_config_memorize() -> String:
	var config := ConfigFile.new()
	for entry in _custom_settings:
		config.set_value("s", entry["name"], ProjectSettings.get_setting_with_override(entry["name"]))
	return config.encode_to_text()


func get_custom_setting(setting_name :String) -> Variant:
	if ProjectSettings.has_setting(setting_name):
		return ProjectSettings.get_setting_with_override(setting_name)
	for entry in _custom_settings:
		if entry["name"] != setting_name:
			continue
		return entry["default"]
	push_error("SimpleGrassTextured, setting not found: ", setting_name)
	return null


func set_tool(tool_name: String) -> void:
	match tool_name:
		"none":
			_edit_tool = TOOL.NONE
		"airbrush":
			_edit_tool = TOOL.AIRBRUSH
		"pencil":
			_edit_tool = TOOL.PENCIL
		"eraser":
			_edit_tool = TOOL.ERASER


func set_tool_shape(tool_name: String, shape_name: String) -> void:
	if _grass_selected == null:
		return
	var shape_id: TOOL_SHAPE
	match shape_name:
		"sphere":
			shape_id = TOOL_SHAPE.SPHERE
		"cylinder":
			shape_id = TOOL_SHAPE.CYLINDER
		"cylinder_inf_h":
			shape_id = TOOL_SHAPE.CYLINDER_INF_H
		"box":
			shape_id = TOOL_SHAPE.BOX
		"box_inf_h":
			shape_id = TOOL_SHAPE.BOX_INF_H
	_grass_selected.sgt_tool_shape[tool_name] = shape_id
	_update_pointer()


func get_tool_shape_name(shape_id: int) -> String:
	match shape_id:
		TOOL_SHAPE.SPHERE:
			return "sphere"
		TOOL_SHAPE.CYLINDER:
			return "cylinder"
		TOOL_SHAPE.CYLINDER_INF_H:
			return "cylinder_inf_h"
		TOOL_SHAPE.BOX:
			return "box"
		TOOL_SHAPE.BOX_INF_H:
			return "box_inf_h"
	return ""


func _init_default_project_settings() -> void:
	for entry in _custom_settings:
		if not ProjectSettings.has_setting(entry["name"]):
			ProjectSettings.set(entry["name"], entry["default"])
		ProjectSettings.set_initial_value(entry["name"], entry["default"])
		ProjectSettings.add_property_info(entry)
		if entry.has("basic") and ProjectSettings.has_method(&"set_as_basic"):
			ProjectSettings.call(&"set_as_basic", entry["name"], entry["basic"])


func _update_gui() -> void:
	if _grass_selected != null:
		if not _grass_selected.sgt_tool_shape.has("airbrush"):
			_grass_selected.sgt_tool_shape["airbrush"] = TOOL_SHAPE.CYLINDER
		if not _grass_selected.sgt_tool_shape.has("pencil"):
			_grass_selected.sgt_tool_shape["pencil"] = TOOL_SHAPE.CYLINDER
		if not _grass_selected.sgt_tool_shape.has("eraser"):
			_grass_selected.sgt_tool_shape["eraser"] = TOOL_SHAPE.SPHERE
		_gui_toolbar.slider_radius.value = _grass_selected.sgt_radius
		_gui_toolbar.slider_density.value = _grass_selected.sgt_density
		_gui_toolbar.edit_scale.value = _grass_selected.sgt_scale
		_gui_toolbar.edit_rotation.value = _grass_selected.sgt_rotation
		_gui_toolbar.edit_rotation_rand.value = _grass_selected.sgt_rotation_rand
		_gui_toolbar.edit_distance.value = _grass_selected.sgt_dist_min
		_gui_toolbar.edit_slope_range.set_value(_grass_selected.sgt_slope.x, _grass_selected.sgt_slope.y)
		_gui_toolbar.set_current_grass(_grass_selected)
		_gui_toolbar_up.set_current_grass(_grass_selected)
		if _grass_selected.multimesh != null:
			_gui_toolbar.label_stats.text = "Count: " + str(_grass_selected.multimesh.instance_count)
		_raycast_3d.collision_mask = _grass_selected.collision_mask


func _update_pointer() -> void:
	if _grass_selected == null:
		_pointer_decal.visible = false
		return
	_pointer_decal.visible = true
	var tool_name := ""
	match _edit_tool:
		TOOL.NONE:
			_pointer_decal.visible = false
			return
		TOOL.PENCIL:
			tool_name = "pencil"
			_pointer_rotate = true
		TOOL.AIRBRUSH:
			tool_name = "airbrush"
			_pointer_rotate = true
		TOOL.ERASER:
			tool_name = "eraser"
			_pointer_rotate = false
	match _grass_selected.sgt_tool_shape[tool_name]:
		TOOL_SHAPE.SPHERE:
			if _edit_tool == TOOL.ERASER:
				_pointer_rotate = true
			_pointer_depth = _edit_radius
			_pointer_decal.set_texture(Decal.TEXTURE_ALBEDO, _pointer_img_circle)
		TOOL_SHAPE.CYLINDER:
			if _edit_tool == TOOL.ERASER:
				_pointer_rotate = true
			_pointer_depth = DEFAULT_POINTER_DEPTH
			_pointer_decal.set_texture(Decal.TEXTURE_ALBEDO, _pointer_img_circle)
		TOOL_SHAPE.CYLINDER_INF_H:
			_pointer_depth = 1000000
			_pointer_decal.set_texture(Decal.TEXTURE_ALBEDO, _pointer_img_circle)
		TOOL_SHAPE.BOX:
			if _edit_tool == TOOL.ERASER:
				_pointer_rotate = true
			_pointer_depth = _edit_radius
			_pointer_decal.set_texture(Decal.TEXTURE_ALBEDO, _pointer_img_rect)
		TOOL_SHAPE.BOX_INF_H:
			_pointer_depth = 1000000
			_pointer_decal.set_texture(Decal.TEXTURE_ALBEDO, _pointer_img_rect)


# ★ 本项目改动（草地实例面板）开始 --------------------------------------------
# 编辑器里选中的节点变化时，把「当前草地」同步给面板：
#   选中 SimpleGrassTextured -> 面板显示它；选中的是别的节点 -> 保持原样不打扰。
func _on_editor_selection_changed() -> void:
	if _gui_grass_list == null:
		return
	var selection := EditorInterface.get_selection()
	if selection == null:
		return
	for node in selection.get_selected_nodes():
		if node != null and node.has_meta(&"SimpleGrassTextured"):
			_gui_grass_list.set_grass(node)
			return
	_gui_grass_list.refresh(false)


## 面板「定位」：把编辑器 3D 相机移到指定世界坐标，并在该处放一个高亮球。
## 取景规则（避免「拉太近」）：
##   1. 相机到目标的距离不小于 LOCATE_MIN_DISTANCE（原来更远就保持原距离，绝不拉近）；
##   2. 相机始终守在目标点的水平方向上、比目标高一点，视线带一点俯角；
##   3. 视野中心抬高 LOCATE_VIEW_HEIGHT，草落在画面偏下，上方留出环境。
func focus_grass_point(world_position : Vector3) -> void:
	_show_focus_helper(world_position)
	var viewport := EditorInterface.get_editor_viewport_3d(0)
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return
	if camera.projection == Camera3D.PROJECTION_ORTHOGONAL:
		camera.global_position = world_position
		return
	var look_at_point := world_position + Vector3.UP * LOCATE_VIEW_HEIGHT
	if look_at_point.distance_to(camera.global_position) < 0.001:
		return
	# 观察方向：优先用当前相机->目标的水平方向，相机正上/正下方时退回相机自身朝向
	var horizontal := world_position - camera.global_position
	horizontal.y = 0.0
	if horizontal.length() < 0.001:
		horizontal = -camera.global_transform.basis.z
		horizontal.y = 0.0
	if horizontal.length() < 0.001:
		horizontal = Vector3.BACK
	horizontal = horizontal.normalized()
	# 视线方向 = 水平方向 + 俯角
	var look_dir := (horizontal + Vector3.DOWN * LOCATE_TILT).normalized()
	# 距离：保持原来的三维距离，但不小于 LOCATE_MIN_DISTANCE（只推远、不拉近）
	var distance := camera.global_position.distance_to(world_position)
	distance = maxf(distance, LOCATE_MIN_DISTANCE)
	# 相机沿 look_dir 反方向退到目标身后：高度由俯角决定，不会钻到地下
	camera.global_position = world_position - look_dir * distance
	camera.look_at(look_at_point, Vector3.UP)


## 面板「删除」：按实例下标删除草，整个操作进入编辑器撤销堆栈（Ctrl+Z 可还原）。
## 撤销数据用**值快照**（transform 数组），避免外挂 .res 时资源缓存复用同一对象导致撤销失效。
func delete_grass_instances(grass, indices : PackedInt32Array) -> void:
	if grass == null or not is_instance_valid(grass):
		return
	if indices.is_empty() or grass.multimesh == null:
		return
	var count_before : int = int(grass.multimesh.instance_count)
	var before : Array = grass.delete_instances_by_indices(indices)
	if before.size() < 2:
		return
	var prev_snapshot : Array = _undo_snapshot(before[0])
	var prev_height_map : Image = before[1]
	var after_snapshot : Array = grass.get_instance_snapshot()
	var after_height_map : Image = grass.baked_height_map
	var removed : int = count_before - after_snapshot.size()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("%s - 删除 %d 株草" % [grass.name, removed], UndoRedo.MERGE_DISABLE, grass)
	undo_redo.add_do_method(grass, &"restore_multimesh_from_snapshot", after_snapshot, after_height_map)
	undo_redo.add_undo_method(grass, &"restore_multimesh_from_snapshot", prev_snapshot, prev_height_map)
	undo_redo.commit_action()
	if _gui_toolbar != null:
		_gui_toolbar.label_stats.text = "Count: " + str(grass.multimesh.instance_count)
	_update_pointer()


## 撤销数据统一成「transform 快照数组」：
## 新接口直接返回快照；若拿到的是旧接口返回的 MultiMesh（脚本版本不一致时），
## 就地从它导出快照，避免类型不匹配报错，也保证撤销仍然有效。
func _undo_snapshot(data) -> Array:
	if data is Array:
		return data
	if data is MultiMesh:
		var out : Array = []
		var mm : MultiMesh = data
		out.resize(mm.instance_count)
		for i in range(mm.instance_count):
			out[i] = mm.get_instance_transform(i)
		return out
	return []


## 面板选中若干株草 -> 给每一株都放一个高亮环（多选也能一眼看到选中了哪些）。
## positions 为空表示清空高亮；超过 LOCATE_MAX_MARKERS 只显示前若干个。
func set_selection_highlights(positions : PackedVector3Array, limit : int = LOCATE_MAX_MARKERS) -> void:
	var wanted := positions
	if wanted.size() > limit:
		wanted = wanted.slice(0, limit)
	# 先把「定位」留下的单个标记也纳入管理，避免它游离在外
	if not wanted.is_empty() and _focus_helper != null and not _focus_helpers.has(_focus_helper):
		if is_instance_valid(_focus_helper):
			var first : MeshInstance3D = _focus_helper
			_focus_helpers.append(first)
			if _focus_helpers.size() > wanted.size():
				_focus_helpers.pop_back()
				first.queue_free()
	_focus_helper = null
	while _focus_helpers.size() > wanted.size():
		var extra : MeshInstance3D = _focus_helpers.pop_back()
		if is_instance_valid(extra):
			extra.queue_free()
	while _focus_helpers.size() < wanted.size():
		var marker := _create_focus_marker("SGTSelectionMarker%d" % _focus_helpers.size(), LOCATE_SELECTION_RADIUS)
		_focus_helpers.append(marker)
	for i in range(_focus_helpers.size()):
		var marker : MeshInstance3D = _focus_helpers[i]
		if not is_instance_valid(marker):
			continue
		marker.global_position = wanted[i]
		marker.visible = true
	# _focus_helper 只作为「有没有高亮」的标志；这里统一指向第一个环
	_focus_helper = _focus_helpers[0] if not _focus_helpers.is_empty() else null


## 清空全部高亮环
func clear_selection_highlights() -> void:
	for marker in _focus_helpers:
		if is_instance_valid(marker):
			marker.queue_free()
	_focus_helpers.clear()
	_focus_helper = null


func _create_focus_marker(marker_name : String, radius : float) -> MeshInstance3D:
	if _focus_helper_material == null:
		_focus_helper_material = StandardMaterial3D.new()
		_focus_helper_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_focus_helper_material.albedo_color = Color(1.0, 0.55, 0.05, 1.0)
		_focus_helper_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# 不做深度测试：草丛 / 地形挡在前面时这个标记仍然可见
		_focus_helper_material.no_depth_test = true
	var marker := MeshInstance3D.new()
	marker.name = marker_name
	marker.mesh = _create_ring_mesh(radius, maxf(radius * 0.28, 0.06))
	marker.material_override = _focus_helper_material
	marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	marker.visible = false
	add_child(marker)
	return marker


## 生成一个水平圆环（放在草地上像个标记环）。每次调用都新建网格，
## 因为标记数量很少，不值得为不同半径做缓存。
func _create_ring_mesh(radius : float, thickness : float) -> ArrayMesh:
	var steps := 40
	var r_in := maxf(radius - thickness * 0.5, 0.01)
	var r_out := radius + thickness * 0.5
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for i in range(steps):
		var a := TAU * float(i) / float(steps)
		var dir := Vector3(cos(a), 0.0, sin(a))
		verts.append(dir * r_in)
		verts.append(dir * r_out)
		normals.append(Vector3.UP)
		normals.append(Vector3.UP)
	for i in range(steps):
		var v := i * 2
		var next := ((i + 1) % steps) * 2
		indices.append(v); indices.append(v + 1); indices.append(next)
		indices.append(v + 1); indices.append(next + 1); indices.append(next)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _show_focus_helper(world_position : Vector3) -> void:
	if _focus_helper == null or not is_instance_valid(_focus_helper):
		var marker := _create_focus_marker("SGTLocateMarker", LOCATE_SELECTION_RADIUS)
		_focus_helper = marker
	_focus_helper.global_position = world_position
	_focus_helper.visible = true
# ★ 本项目改动（草地实例面板）结束 --------------------------------------------


## ★ 本项目改动（草地数据外挂）开始 --------------------------------------------
## 判断 MultiMesh 是否已经是「真正的外挂资源文件」。
## 注意：内联子资源的 resource_path 也不是空的（形如 res://scenes/main.tscn::MultiMesh_xxx），
## 含 "::" 说明数据还嵌在场景里，需要外挂；只有独立路径（res://maps/xxx.res）才算外挂。
func _is_external_file_grass(mm : MultiMesh) -> bool:
	if mm == null:
		return false
	var path := String(mm.resource_path)
	return path.length() > 0 and path.find("::") == -1


## 一键把内联的草地数据外挂成单独 .res：
##   场景里巨大的 buffer 行会被换成一句 `multimesh = ExtResource(...)`，
##   之后笔刷 / 擦除 / 删除都会继续写回这个文件（grass.gd 里的 take_over_path 逻辑）。
##   整个替换进撤销堆栈；撤销会把草地恢复成内联。
func externalize_grass_multimesh(grass) -> void:
	if grass == null or not is_instance_valid(grass):
		return
	var mm : MultiMesh = grass.multimesh
	if mm == null or mm.instance_count == 0:
		print("SimpleGrassTextured: 草地里还没有草，先刷一些再外挂")
		return
	# 只有「真正的外挂文件」（不含 :: 的独立路径）才提前返回；内联子资源要继续外挂
	if _is_external_file_grass(mm):
		print("SimpleGrassTextured: 草地数据已经是外挂资源：", mm.resource_path)
		return
	var path := _build_externalize_path(grass)
	if path.is_empty():
		push_error("SimpleGrassTextured: 生成外挂路径失败")
		return
	# 内联数据先取快照，供 _externalize_now 写盘用
	var inline_snapshot : Array = grass.get_instance_snapshot()
	var height_map : Image = grass.baked_height_map
	# 1) 先真正执行外挂，拿到带 resource_path 的新对象
	var multi_new : MultiMesh = _externalize_now(grass, inline_snapshot, path)
	if multi_new == null:
		return
	var inline_multimesh : MultiMesh = _inline_shadow_multimesh(grass, inline_snapshot)
	# 2) 再把「外挂 -> 内联」这对状态记进撤销堆栈。
	#    用 callable 而不是 add_do_property/add_undo_property：do 阶段已经改过同一个属性，
	#    属性式撤销在这种「do 之后再撤销」的组合下不可靠，自己写赋值最稳。
	var undo_redo := get_undo_redo()
	undo_redo.create_action("%s - 外挂草地数据 (.res)" % grass.name, UndoRedo.MERGE_DISABLE, grass)
	undo_redo.add_do_method(self, &"_assign_multimesh", grass, multi_new, null)
	undo_redo.add_undo_method(self, &"_assign_multimesh", grass, inline_multimesh, height_map)
	undo_redo.add_do_reference(multi_new)
	undo_redo.add_undo_reference(inline_multimesh)
	undo_redo.commit_action()
	print("SimpleGrassTextured: 草地数据已外挂到 ", path, "（可 Ctrl+Z 撤销）")
	_gui_grass_list_refresh()


## 撤销 / 重做统一入口：把指定 MultiMesh（与高度图）装到节点上，并重算 AABB
func _assign_multimesh(grass, multi : MultiMesh, height_map : Image) -> void:
	if grass == null or not is_instance_valid(grass):
		return
	if multi != null and is_instance_valid(multi):
		grass.multimesh = multi
	grass.baked_height_map = height_map
	grass.custom_aabb.position = Vector3.ZERO
	grass.custom_aabb.end = Vector3.ZERO
	_gui_grass_list_refresh()


## 造一个「内联版」的 MultiMesh（没有 resource_path），撤销时用它把节点还原成内联
func _inline_shadow_multimesh(grass, snapshot : Array) -> MultiMesh:
	var multi_inline := MultiMesh.new()
	multi_inline.transform_format = MultiMesh.TRANSFORM_3D
	multi_inline.use_custom_data = true
	multi_inline.mesh = grass.multimesh.mesh if grass.multimesh != null else null
	if multi_inline.mesh == null:
		multi_inline.mesh = grass.mesh if grass.mesh != null else load("res://addons/simplegrasstextured/default_mesh.tres")
	multi_inline.instance_count = snapshot.size()
	for i in range(snapshot.size()):
		multi_inline.set_instance_transform(i, snapshot[i])
	return multi_inline


## 执行外挂：写盘 + **直接把带 resource_path 的 MultiMesh 装到节点上**
## （不依赖 UndoRedo 的 do_property 赋值，行为更可控）
func _externalize_now(grass, snapshot : Array, path : String) -> MultiMesh:
	if grass == null or not is_instance_valid(grass):
		return null
	var source_mesh : Mesh = null
	if grass.multimesh != null and grass.multimesh.mesh != null:
		source_mesh = grass.multimesh.mesh
	elif grass.mesh != null:
		source_mesh = grass.mesh
	else:
		source_mesh = load("res://addons/simplegrasstextured/default_mesh.tres")
	var multi_new := MultiMesh.new()
	multi_new.transform_format = MultiMesh.TRANSFORM_3D
	multi_new.use_custom_data = true
	multi_new.mesh = source_mesh
	multi_new.instance_count = snapshot.size()
	for i in range(snapshot.size()):
		multi_new.set_instance_transform(i, snapshot[i])
	var err := ResourceSaver.save(multi_new, path)
	if err != OK:
		push_error("SimpleGrassTextured: 外挂保存失败(%d)：%s" % [err, path])
		return null
	multi_new.take_over_path(path)
	grass.multimesh = multi_new
	grass.baked_height_map = null
	# 节点上的自定义 AABB 归零，让引擎按新数据重算
	grass.custom_aabb.position = Vector3.ZERO
	grass.custom_aabb.end = Vector3.ZERO
	return multi_new


## 生成外挂路径：res://maps/<场景名>_<节点id>_grass.res
##
## ★ 命名按「节点 id」而不是节点名：Godot 没有把 .tscn 里的 unique_id 暴露给 GDScript
##   （Node.get_scene_unique_id 不存在，get_path(unique) 也只返回 ".."），
##   所以这里用「首次外挂时生成并写进节点 meta 的 id」—— meta 会随场景一起保存，
##   之后无论你把节点改成什么名字，都复用同一个文件，不会再多出几个 .res。
func _build_externalize_path(grass) -> String:
	DirAccess.make_dir_recursive_absolute(EXTERNALIZE_DIR)
	# 1) 已经记过 id：直接用（节点名改了也不影响）
	var recorded := String(grass.get_meta(EXTERNALIZE_META_KEY, ""))
	if not recorded.is_empty():
		var recorded_path := EXTERNALIZE_DIR.path_join(_externalize_filename(_scene_base_name(), recorded))
		if FileAccess.file_exists(recorded_path):
			return recorded_path
	# 2) 首次：生成一个稳定且唯一的 id 并记到节点 meta
	var id := _make_externalize_id(grass)
	grass.set_meta(EXTERNALIZE_META_KEY, id)
	return EXTERNALIZE_DIR.path_join(_externalize_filename(_scene_base_name(), id))


## 生成「不依赖节点名」的唯一 id，例如：g3_1a2b3c4d
func _make_externalize_id(grass) -> String:
	# 节点在场景里的序号（同类草节点的第几个），改名/移动都不会变
	var index := 0
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null:
		var all: Array = []
		_collect_grass_nodes(scene_root, all)
		for i in range(all.size()):
			if all[i] == grass:
				index = i
				break
	var scene_tail := _scene_base_name()
	var path_tail := String(grass.get_path()) if grass.is_inside_tree() else String(grass.name)
	var mixed := ("%s|%s|%d" % [scene_tail, path_tail, Time.get_unix_time_from_system()])
	var digest := "%08x" % (hash(mixed) & 0xFFFFFFFF)
	return "g%d_%s" % [index, digest]


func _externalize_filename(scene_base : String, id : String) -> String:
	return "%s_%s_grass.res" % [_sanitize_filename_part(scene_base), _sanitize_filename_part(id)]


func _scene_base_name() -> String:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root != null and not String(scene_root.scene_file_path).is_empty():
		return String(scene_root.scene_file_path).get_file().get_basename()
	return "scene"


func _sanitize_filename_part(text : String) -> String:
	var out := text.strip_edges()
	for bad in ["/", "\\", ":", "@", "*", "?", "\"", "<", ">", "|", "::", "."]:
		out = out.replace(bad, "_")
	if out.is_empty():
		out = "unnamed"
	return out


func _collect_grass_nodes(node : Node, out : Array) -> void:
	if node.has_meta(&"SimpleGrassTextured"):
		out.append(node)
	for child in node.get_children():
		_collect_grass_nodes(child, out)


func _gui_grass_list_refresh() -> void:
	if _gui_grass_list != null:
		_gui_grass_list.refresh_later()
# ★ 本项目改动（草地数据外挂）结束 --------------------------------------------


func _on_project_settings_changed() -> void:
	_prev_config = _custom_config_memorize()
	_evaluate_draw_time = get_custom_setting("SimpleGrassTextured/General/evaluate_draw_time")


func _on_button_airbrush_toggled(pressed : bool) -> void:
	if pressed:
		_edit_tool = TOOL.AIRBRUSH
	elif _edit_tool == TOOL.AIRBRUSH:
		_edit_tool = TOOL.NONE
	_update_pointer()


func _on_button_pencil_toggled(pressed : bool) -> void:
	if pressed:
		_edit_tool = TOOL.PENCIL
	elif _edit_tool == TOOL.PENCIL:
		_edit_tool = TOOL.NONE
	_update_pointer()


func _on_button_eraser_toggled(pressed : bool) -> void:
	if pressed:
		_edit_tool = TOOL.ERASER
	elif _edit_tool == TOOL.ERASER:
		_edit_tool = TOOL.NONE
	_update_pointer()


func _on_slider_radius_value_changed(value : float) -> void:
	_edit_radius = value
	_update_pointer()
	_pointer_decal.extents = Vector3(_edit_radius, _pointer_depth, _edit_radius)
	if _grass_selected != null:
		_grass_selected.sgt_radius = value


func _on_slider_density_value_changed(value : float) -> void:
	_edit_density = value
	if _grass_selected != null:
		_grass_selected.sgt_density = value


func _on_edit_slope_range_changed(value_min: float, value_max: float) -> void:
	_edit_slope = Vector2(value_min, value_max)
	if _grass_selected != null:
		_grass_selected.sgt_slope = _edit_slope


func _on_edit_scale_value_changed(value : float) -> void:
	_edit_scale = Vector3(value, value, value)
	if _grass_selected != null:
		_grass_selected.sgt_scale = value


func _on_edit_rotation_value_changed(value : float) -> void:
	_edit_rotation = value
	if _grass_selected != null:
		_grass_selected.sgt_rotation = value


func _on_edit_rotation_rand_value_changed(value : float) -> void:
	_edit_rotation_rand = value
	if _grass_selected != null:
		_grass_selected.sgt_rotation_rand = value


func _on_edit_distance_value_changed(value : float) -> void:
	if _grass_selected != null:
		_grass_selected.sgt_dist_min = value


func _on_set_tool(value : TOOL) -> void:
	_edit_tool = value
	if _edit_tool == TOOL.AIRBRUSH:
		_pointer_decal.modulate = Color.WHITE
		_gui_toolbar.slider_density.editable = true
		_gui_toolbar.button_density.disabled = false
		_gui_toolbar.button_airbrush.button_pressed = true
		_gui_toolbar.button_pencil.button_pressed = false
		_gui_toolbar.button_eraser.button_pressed = false
		_gui_toolbar.set_density_modulate(Color.WHITE)
	elif _edit_tool == TOOL.PENCIL:
		_pointer_decal.modulate = Color.YELLOW
		_gui_toolbar.slider_density.editable = false
		_gui_toolbar.button_density.disabled = true
		_gui_toolbar.button_airbrush.button_pressed = false
		_gui_toolbar.button_pencil.button_pressed = true
		_gui_toolbar.button_eraser.button_pressed = false
		_gui_toolbar.set_density_modulate(Color(1, 1, 1, 0.25))
	elif _edit_tool == TOOL.ERASER:
		_pointer_decal.modulate = Color.RED
		_gui_toolbar.slider_density.editable = false
		_gui_toolbar.button_density.disabled = true
		_gui_toolbar.button_airbrush.button_pressed = false
		_gui_toolbar.button_pencil.button_pressed = false
		_gui_toolbar.button_eraser.button_pressed = true
		_gui_toolbar.set_density_modulate(Color(1, 1, 1, 0.25))
	if _grass_selected != null:
		_pointer_decal.visible = _edit_tool != TOOL.NONE
	else:
		_pointer_decal.visible = false


func _eval_brush() -> void:
	if _grass_selected == null:
		return
	if _edit_tool == TOOL.PENCIL:
		var steep : float = _grass_selected.sgt_dist_min
		var list_trans := []
		var follow_normal : bool = _grass_selected.sgt_follow_normal
		var slope := Vector2(deg_to_rad(_grass_selected.sgt_slope.x), deg_to_rad(_grass_selected.sgt_slope.y))
		if steep < 0.05:
			steep = 0.4
		_grass_selected.temp_dist_min = steep
		var x := -_edit_radius
		while x < _edit_radius:
			var z := -_edit_radius
			while z < _edit_radius:
				var variation: Vector3
				match _grass_selected.sgt_tool_shape["pencil"]:
					TOOL_SHAPE.SPHERE, TOOL_SHAPE.CYLINDER, TOOL_SHAPE.CYLINDER_INF_H:
						variation = Vector3(x + (randf() * steep * 0.5), 0, z + (randf() * steep * 0.5))
						if variation.length() >= _edit_radius:
							z += steep
							continue
					TOOL_SHAPE.BOX, TOOL_SHAPE.BOX_INF_H:
						variation = Vector3(x + (randf() * steep * 0.5), 0, z + (randf() * steep * 0.5))
					_:
						variation = Vector3(x + (randf() * steep * 0.5), 0, z + (randf() * steep * 0.5))
						if variation.length() >= _edit_radius:
							z += steep
							continue
				variation = _pointer_decal.to_global(variation) - _pointer_decal.global_position
				_raycast_3d.global_transform.basis.x = Vector3.RIGHT
				_raycast_3d.global_transform.basis.y = _normal_draw * -1
				_raycast_3d.global_transform.basis.z = Vector3.BACK
				_raycast_3d.global_transform.origin = _position_draw + (_normal_draw * _pointer_depth / 2.0) + variation
				_raycast_3d.target_position = Vector3(0, _pointer_depth, 0)
				_raycast_3d.collision_mask = _grass_selected.collision_mask
				_raycast_3d.force_raycast_update()
				if _raycast_3d.is_colliding() and _raycast_3d.get_collider() == _object_draw:
					var normal := _raycast_3d.get_collision_normal()
					if normal.angle_to(Vector3.UP) < slope.x or normal.angle_to(Vector3.UP) > slope.y:
						z += steep
						continue
					if not follow_normal:
						normal = Vector3.UP
					list_trans.append(_grass_selected.eval_grass_transform(
						_raycast_3d.get_collision_point() - _grass_selected.global_position,
						normal,
						_edit_scale,
						deg_to_rad(_edit_rotation) + (PI * (_edit_rotation_rand - (randf() * _edit_rotation_rand * 2.0)))
					))
				z += steep
			x += steep
		_grass_selected.add_grass_batch(list_trans)
	elif _edit_tool == TOOL.AIRBRUSH:
		var follow_normal : bool = _grass_selected.sgt_follow_normal
		var slope := Vector2(deg_to_rad(_grass_selected.sgt_slope.x), deg_to_rad(_grass_selected.sgt_slope.y))
		for i in _edit_density:
			var variation: Vector3
			match _grass_selected.sgt_tool_shape["airbrush"]:
				TOOL_SHAPE.SPHERE, TOOL_SHAPE.CYLINDER, TOOL_SHAPE.CYLINDER_INF_H:
					variation = Vector3.RIGHT * _edit_radius * randf()
					variation = variation.rotated(Vector3.UP, randf() * TAU)
				TOOL_SHAPE.BOX, TOOL_SHAPE.BOX_INF_H:
					variation = Vector3(randf_range(-1, 1), 0, randf_range(-1, 1)) * _edit_radius
				_:
					variation = Vector3.RIGHT * _edit_radius * randf()
					variation = variation.rotated(Vector3.UP, randf() * TAU)
			variation = _pointer_decal.to_global(variation) - _pointer_decal.global_position
			_raycast_3d.global_transform.basis.x = Vector3.RIGHT
			_raycast_3d.global_transform.basis.y = _normal_draw * -1
			_raycast_3d.global_transform.basis.z = Vector3.BACK
			_raycast_3d.global_transform.origin = _position_draw + (_normal_draw * _pointer_depth / 2.0) + variation
			_raycast_3d.target_position = Vector3(0, _pointer_depth, 0)
			_raycast_3d.collision_mask = _grass_selected.collision_mask
			_raycast_3d.force_raycast_update()
			if _raycast_3d.is_colliding() and _raycast_3d.get_collider() == _object_draw:
				var normal := _raycast_3d.get_collision_normal()
				if normal.angle_to(Vector3.UP) < slope.x or normal.angle_to(Vector3.UP) > slope.y:
					continue
				if not follow_normal:
					normal = Vector3.UP
				_grass_selected.add_grass(
					_raycast_3d.get_collision_point() - _grass_selected.global_position,
					normal,
					_edit_scale,
					deg_to_rad(_edit_rotation) + (PI * (_edit_rotation_rand - (randf() * _edit_rotation_rand * 2.0)))
				)
	elif _edit_tool == TOOL.ERASER:
		match _grass_selected.sgt_tool_shape["eraser"]:
			TOOL_SHAPE.SPHERE:
				_grass_selected.erase(_position_draw - _grass_selected.global_position, _edit_radius)
			TOOL_SHAPE.CYLINDER:
				_grass_selected.erase_cylinder(_edit_radius, _pointer_depth, _edit_radius, _pointer_decal.global_transform)
			TOOL_SHAPE.CYLINDER_INF_H:
				_grass_selected.erase_cylinder(_edit_radius, 1000000, _edit_radius, _pointer_decal.global_transform)
			TOOL_SHAPE.BOX:
				_grass_selected.erase_box(Vector3(_edit_radius, _edit_radius, _edit_radius) * 2, _pointer_decal.global_transform)
			TOOL_SHAPE.BOX_INF_H:
				_grass_selected.erase_box(Vector3(_edit_radius, 1000000, _edit_radius) * 2, _pointer_decal.global_transform)
	if _grass_selected.multimesh != null:
		_gui_toolbar.label_stats.text = "Count: " + str(_grass_selected.multimesh.instance_count)

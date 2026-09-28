@tool
extends EditorPlugin


enum StrokeMode {
	NONE,
	PAINT,
	ERASE,
}


enum HeightOffsetMode {
	WORLD_Y,
	SURFACE_NORMAL,
}


const DOCK_SCENE: PackedScene = preload(
	"res://addons/world_brush/ui/world_brush_dock.tscn"
)

const LOD_INSTANCE_SCRIPT: Script = preload(
	"res://addons/world_brush/world_brush_lod_instance.gd"
)

const AUTO_LOD_CONTROLLER_SCRIPT: Script = preload(
	"res://addons/world_brush/world_brush_auto_lod_controller.gd"
)

const RAY_LENGTH: float = 100000.0
const MAX_RAY_SKIPS: int = 64
const SAMPLE_VERTICAL_RANGE: float = 100000.0

const BRUSH_SEGMENTS: int = 64
const BRUSH_HEIGHT_OFFSET: float = 0.08

const PAINT_PREVIEW_COLOR := Color(
	0.10,
	0.80,
	1.00,
	1.00
)

const ERASE_PREVIEW_COLOR := Color(
	1.00,
	0.12,
	0.08,
	1.00
)

const STAMP_STEP_RADIUS_FACTOR: float = 0.35
const MINIMUM_STAMP_STEP: float = 0.5

const PLACEMENT_ATTEMPTS_PER_INSTANCE: int = 30
const MINIMUM_PLACEMENT_ATTEMPTS: int = 80
const MAX_TOTAL_PLACEMENT_ATTEMPTS: int = 2000

const TERRAIN_SCAN_INTERVAL_MS: int = 1000
const INVALID_TERRAIN_LIMIT: float = 3.0e38

const CONTAINER_NAME: StringName = &"WorldBrushInstances"
const CONTAINER_META: StringName = &"world_brush_container"
const INSTANCE_META: StringName = &"world_brush_instance"
const SOURCE_SCENE_META: StringName = &"world_brush_source_scene_path"
const LOD_GROUP_META: StringName = &"world_brush_lod_group"
const LOD_NODE_GROUP: StringName = &"world_brush_distance_lod"
const AUTO_LOD_CONTROLLER_NAME: StringName = &"WorldBrushAutoLOD"
const AUTO_LOD_IMPORT_EXTENSIONS := [
	"glb", "gltf", "fbx", "obj", "blend"
]


var world_brush_dock: EditorDock
var dock_content: Control

var selected_scene: PackedScene

var brush_enabled: bool = false
var brush_radius: float = 5.0
var instances_per_click: int = 5
var minimum_spacing: float = 1.0

var random_y_rotation: bool = true
var align_to_surface: bool = false

var maximum_slope_degrees: float = 85.0

var height_offset: float = 0.0
var height_offset_mode: int = HeightOffsetMode.SURFACE_NORMAL

var random_scale_enabled: bool = true
var minimum_scale: float = 0.8
var maximum_scale: float = 1.3

var lod_enabled: bool = false
var lod1_scene: PackedScene
var lod2_scene: PackedScene
var lod1_distance: float = 25.0
var lod2_distance: float = 60.0
var lod_cull_distance: float = 0.0
var editor_lod_preview_elapsed: float = 0.0
var auto_lod_enabled: bool = false
var auto_lod_bias: float = 1.0
var auto_lod_cull_distance: float = 0.0


# =========================================================
# السطح الحالي
# =========================================================

var has_surface_hit: bool = false
var surface_position: Vector3 = Vector3.ZERO
var surface_normal: Vector3 = Vector3.UP
var surface_type: String = ""


# =========================================================
# حالة السحبة
# =========================================================

var stroke_mode: int = StrokeMode.NONE

var has_last_stamp_position: bool = false
var last_stamp_position: Vector3 = Vector3.ZERO

var stroke_scene_root: Node3D
var stroke_container: Node3D
var stroke_created_container: bool = false


# =========================================================
# عناصر سحبة الرسم والحذف
# =========================================================

var painted_instances: Array[Node3D] = []
var painted_transforms: Array[Transform3D] = []

var erased_instances: Array[Node3D] = []
var erased_transforms: Array[Transform3D] = []


# =========================================================
# معاينة الفرشاة
# =========================================================

var brush_preview: MeshInstance3D
var brush_preview_mesh: ImmediateMesh
var brush_preview_material: StandardMaterial3D

var erase_preview_active: bool = false


# =========================================================
# Terrain3D Cache
# =========================================================

var cached_scene_root: Node
var cached_terrain_nodes: Array[Node] = []
var last_terrain_scan_time: int = 0


var random_generator: RandomNumberGenerator


# =========================================================
# تشغيل وإيقاف الإضافة
# =========================================================

func _enter_tree() -> void:
	random_generator = RandomNumberGenerator.new()
	random_generator.randomize()

	set_process(true)

	dock_content = DOCK_SCENE.instantiate() as Control

	if dock_content == null:
		push_error(
			"World Brush: Failed to instantiate dock content."
		)
		return

	_create_editor_dock()
	_connect_dock_signals()
	if not scene_changed.is_connected(
		_on_editor_scene_changed
	):
		scene_changed.connect(
			_on_editor_scene_changed
		)

	set_input_event_forwarding_always_enabled()

	call_deferred(
		"_show_world_brush_dock"
	)
	call_deferred(
		"_upgrade_existing_lod_groups"
	)
	call_deferred(
		"_apply_lod_settings_to_existing_groups"
	)
	call_deferred(
		"_apply_auto_lod_settings_to_existing_instances"
	)

	print(
		"World Brush: Plugin enabled successfully."
	)


func _exit_tree() -> void:
	_end_active_stroke()
	if scene_changed.is_connected(
		_on_editor_scene_changed
	):
		scene_changed.disconnect(
			_on_editor_scene_changed
		)

	set_process(false)

	brush_enabled = false
	selected_scene = null

	has_surface_hit = false
	surface_type = ""

	_clear_terrain_cache()
	_remove_brush_preview()

	if is_instance_valid(world_brush_dock):
		remove_dock(
			world_brush_dock
		)

		world_brush_dock.queue_free()

	world_brush_dock = null
	dock_content = null
	random_generator = null

	print(
		"World Brush: Plugin disabled successfully."
	)


func _process(
	delta: float
) -> void:
	_update_editor_lod_preview(delta)

	if stroke_mode == StrokeMode.NONE:
		return

	if stroke_mode == StrokeMode.PAINT:
		if not Input.is_mouse_button_pressed(
			MOUSE_BUTTON_LEFT
		):
			_end_active_stroke()

	elif stroke_mode == StrokeMode.ERASE:
		if not Input.is_mouse_button_pressed(
			MOUSE_BUTTON_RIGHT
		):
			_end_active_stroke()


func _handles(
	object: Object
) -> bool:
	if object == null:
		var edited_root := (
			get_editor_interface()
			.get_edited_scene_root()
		)

		return edited_root is Node3D

	return object is Node3D


# =========================================================
# نافذة الإضافة
# =========================================================

func _create_editor_dock() -> void:
	world_brush_dock = EditorDock.new()

	world_brush_dock.name = (
		"WorldBrushEditorDock"
	)

	world_brush_dock.title = "World Brush"

	world_brush_dock.layout_key = (
		"world_brush_editor_dock"
	)

	world_brush_dock.default_slot = (
		EditorDock.DOCK_SLOT_RIGHT_UL
	)

	world_brush_dock.global = true

	world_brush_dock.add_child(
		dock_content
	)

	add_dock(
		world_brush_dock
	)


func _connect_dock_signals() -> void:
	if not _connect_required_signal(
		&"selected_scene_changed",
		&"_on_selected_scene_changed"
	):
		return

	if not _connect_required_signal(
		&"brush_enabled_changed",
		&"_on_brush_enabled_changed"
	):
		return

	if not _connect_required_signal(
		&"brush_radius_changed",
		&"_on_brush_radius_changed"
	):
		return

	if not _connect_required_signal(
		&"instances_per_click_changed",
		&"_on_instances_per_click_changed"
	):
		return

	if not _connect_required_signal(
		&"minimum_spacing_changed",
		&"_on_minimum_spacing_changed"
	):
		return

	if not _connect_required_signal(
		&"random_y_rotation_changed",
		&"_on_random_y_rotation_changed"
	):
		return

	if not _connect_required_signal(
		&"align_to_surface_changed",
		&"_on_align_to_surface_changed"
	):
		return

	if not _connect_required_signal(
		&"maximum_slope_changed",
		&"_on_maximum_slope_changed"
	):
		return

	if not _connect_required_signal(
		&"height_offset_changed",
		&"_on_height_offset_changed"
	):
		return

	if not _connect_required_signal(
		&"height_offset_mode_changed",
		&"_on_height_offset_mode_changed"
	):
		return

	if not _connect_required_signal(
		&"random_scale_enabled_changed",
		&"_on_random_scale_enabled_changed"
	):
		return

	if not _connect_required_signal(
		&"minimum_scale_changed",
		&"_on_minimum_scale_changed"
	):
		return

	if not _connect_required_signal(
		&"maximum_scale_changed",
		&"_on_maximum_scale_changed"
	):
		return

	if not _connect_required_signal(
		&"lod_settings_changed",
		&"_on_lod_settings_changed"
	):
		return

	if not _connect_required_signal(
		&"auto_lod_settings_changed",
		&"_on_auto_lod_settings_changed"
	):
		return

	if not _connect_required_signal(
		&"auto_lod_import_requested",
		&"_on_auto_lod_import_requested"
	):
		return


func _connect_required_signal(
	signal_name: StringName,
	method_name: StringName
) -> bool:
	if not dock_content.has_signal(
		signal_name
	):
		push_error(
			"World Brush: Missing signal -> %s"
			% signal_name
		)

		return false

	var signal_callable := Callable(
		self,
		method_name
	)

	if not dock_content.is_connected(
		signal_name,
		signal_callable
	):
		dock_content.connect(
			signal_name,
			signal_callable
		)

	return true


func _show_world_brush_dock() -> void:
	if not is_instance_valid(
		world_brush_dock
	):
		return

	world_brush_dock.open()
	world_brush_dock.make_visible()


# =========================================================
# إدخال نافذة 3D
# =========================================================

func _forward_3d_gui_input(
	camera: Camera3D,
	event: InputEvent
) -> int:
	if event is InputEventKey:
		_handle_keyboard_event(
			event as InputEventKey
		)

		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if not brush_enabled:
		_end_active_stroke()
		_hide_brush_preview()

		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseMotion:
		return _handle_mouse_motion(
			camera,
			event as InputEventMouseMotion
		)

	if event is InputEventMouseButton:
		return _handle_mouse_button(
			camera,
			event as InputEventMouseButton
		)

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _handle_keyboard_event(
	key_event: InputEventKey
) -> void:
	if not key_event.pressed:
		return

	if key_event.echo:
		return

	var undo_shortcut := (
		(
			key_event.ctrl_pressed
			or key_event.meta_pressed
		)
		and key_event.keycode == KEY_Z
	)

	if undo_shortcut:
		_end_active_stroke()


func _handle_mouse_motion(
	camera: Camera3D,
	mouse_motion: InputEventMouseMotion
) -> int:
	_update_surface_hit(
		camera,
		mouse_motion.position
	)

	if _event_uses_modifier(
		mouse_motion
	):
		_end_active_stroke()

		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var left_button_down := (
		mouse_motion.button_mask
		& MOUSE_BUTTON_MASK_LEFT
	) != 0

	var right_button_down := (
		mouse_motion.button_mask
		& MOUSE_BUTTON_MASK_RIGHT
	) != 0

	if right_button_down:
		if stroke_mode != StrokeMode.ERASE:
			_end_active_stroke()
			_begin_erase_stroke()
		else:
			_continue_active_stroke()

		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if left_button_down:
		if stroke_mode != StrokeMode.PAINT:
			_end_active_stroke()
			_begin_paint_stroke()
		else:
			_continue_active_stroke()

		return EditorPlugin.AFTER_GUI_INPUT_STOP

	if stroke_mode != StrokeMode.NONE:
		_end_active_stroke()

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _handle_mouse_button(
	camera: Camera3D,
	mouse_button: InputEventMouseButton
) -> int:
	_update_surface_hit(
		camera,
		mouse_button.position
	)

	var is_left_button := (
		mouse_button.button_index
		== MOUSE_BUTTON_LEFT
	)

	var is_right_button := (
		mouse_button.button_index
		== MOUSE_BUTTON_RIGHT
	)

	if not is_left_button and not is_right_button:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if _event_uses_modifier(
		mouse_button
	):
		_end_active_stroke()

		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if mouse_button.pressed:
		if is_left_button:
			_end_active_stroke()
			_begin_paint_stroke()

		elif is_right_button:
			_end_active_stroke()
			_begin_erase_stroke()

	else:
		if (
			is_left_button
			and stroke_mode == StrokeMode.PAINT
		):
			_end_active_stroke()

		elif (
			is_right_button
			and stroke_mode == StrokeMode.ERASE
		):
			_end_active_stroke()

	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _event_uses_modifier(
	event: InputEventWithModifiers
) -> bool:
	return (
		event.alt_pressed
		or event.ctrl_pressed
		or event.shift_pressed
		or event.meta_pressed
	)


# =========================================================
# إدارة السحبة
# =========================================================

func _begin_paint_stroke() -> void:
	if selected_scene == null:
		_set_dock_status(
			"Select An Active Scene First"
		)

		return

	if not has_surface_hit:
		_set_dock_status(
			"No Valid Surface"
		)

		return

	_reset_stroke_data()

	stroke_mode = StrokeMode.PAINT

	has_last_stamp_position = false
	last_stamp_position = Vector3.ZERO

	_set_erase_preview_active(
		false
	)

	_stamp_brush(
		true
	)


func _begin_erase_stroke() -> void:
	if not has_surface_hit:
		_set_dock_status(
			"No Valid Surface"
		)

		return

	_reset_stroke_data()

	stroke_mode = StrokeMode.ERASE

	has_last_stamp_position = false
	last_stamp_position = Vector3.ZERO

	_set_erase_preview_active(
		true
	)

	_stamp_brush(
		true
	)


func _continue_active_stroke() -> void:
	if stroke_mode == StrokeMode.NONE:
		return

	_stamp_brush(
		false
	)


func _end_active_stroke() -> void:
	var finished_mode := stroke_mode

	if finished_mode == StrokeMode.NONE:
		return

	stroke_mode = StrokeMode.NONE

	has_last_stamp_position = false
	last_stamp_position = Vector3.ZERO

	_set_erase_preview_active(
		false
	)

	if finished_mode == StrokeMode.PAINT:
		_commit_paint_stroke()

	elif finished_mode == StrokeMode.ERASE:
		_commit_erase_stroke()

	_reset_stroke_data()


func _reset_stroke_data() -> void:
	stroke_scene_root = null
	stroke_container = null
	stroke_created_container = false

	painted_instances.clear()
	painted_transforms.clear()

	erased_instances.clear()
	erased_transforms.clear()


func _stamp_brush(
	force_stamp: bool
) -> void:
	if not has_surface_hit:
		return

	if (
		not force_stamp
		and has_last_stamp_position
	):
		var required_step := (
			_get_stamp_step()
		)

		var distance_squared := (
			_horizontal_distance_squared(
				surface_position,
				last_stamp_position
			)
		)

		if (
			distance_squared
			< required_step * required_step
		):
			return

	var affected_count: int = 0

	if stroke_mode == StrokeMode.PAINT:
		affected_count = (
			_paint_scene_instances_live()
		)

	elif stroke_mode == StrokeMode.ERASE:
		affected_count = (
			_erase_scene_instances_live()
		)

	last_stamp_position = surface_position
	has_last_stamp_position = true

	if stroke_mode == StrokeMode.PAINT:
		if affected_count > 0:
			_set_dock_status(
				"Painted In Stroke: %d"
				% painted_instances.size()
			)

	elif stroke_mode == StrokeMode.ERASE:
		if affected_count > 0:
			_set_dock_status(
				"Erased In Stroke: %d"
				% erased_instances.size()
			)
		else:
			_set_dock_status(
				"Erase Brush — No Instances Here"
			)


func _get_stamp_step() -> float:
	var radius_step := (
		brush_radius
		* STAMP_STEP_RADIUS_FACTOR
	)

	return maxf(
		MINIMUM_STAMP_STEP,
		maxf(
			minimum_spacing,
			radius_step
		)
	)


# =========================================================
# الرسم المباشر
# =========================================================

func _paint_scene_instances_live() -> int:
	if selected_scene == null:
		return 0

	if not selected_scene.can_instantiate():
		_set_dock_status(
			"Selected Scene Cannot Be Instantiated"
		)

		return 0

	var edited_root := (
		get_editor_interface()
		.get_edited_scene_root()
	)

	if not edited_root is Node3D:
		_set_dock_status(
			"Scene Root Must Be Node3D"
		)

		return 0

	var scene_root := edited_root as Node3D
	var world_3d := scene_root.get_world_3d()

	if world_3d == null:
		_set_dock_status(
			"3D World Not Available"
		)

		return 0

	if stroke_scene_root == null:
		stroke_scene_root = scene_root

	if stroke_scene_root != scene_root:
		_set_dock_status(
			"Edited Scene Changed During Stroke"
		)

		return 0

	if not is_instance_valid(
		stroke_container
	):
		stroke_container = (
			_find_world_brush_container(
				scene_root
			)
		)

		if stroke_container == null:
			stroke_container = Node3D.new()
			stroke_container.name = CONTAINER_NAME

			stroke_container.set_meta(
				CONTAINER_META,
				true
			)

			scene_root.add_child(
				stroke_container,
				true
			)

			stroke_container.owner = scene_root
			stroke_created_container = true

	if not is_instance_valid(
		stroke_container
	):
		_set_dock_status(
			"Failed To Create Container"
		)

		return 0

	var placement_samples := (
		_generate_brush_samples(
			scene_root,
			world_3d,
			stroke_container
		)
	)

	if placement_samples.is_empty():
		_set_dock_status(
			"No Valid Space Inside Brush"
		)

		return 0

	var placed_count: int = 0

	for sample in placement_samples:
		var created_node := (
			_instantiate_selected_scene()
		)

		if created_node == null:
			continue

		if not created_node is Node3D:
			created_node.free()

			_set_dock_status(
				"Selected Scene Root Must Inherit Node3D"
			)

			break

		var instance := created_node as Node3D

		instance.set_meta(
			INSTANCE_META,
			true
		)
		instance.set_meta(
			SOURCE_SCENE_META,
			selected_scene.resource_path
		)
		var authored_basis := (
			instance.transform.basis
		)

		var placement_position: Vector3 = (
			sample.get(
				"position",
				Vector3.ZERO
			)
		)

		var placement_normal: Vector3 = (
			sample.get(
				"normal",
				Vector3.UP
			)
		)

		var placement_basis: Basis = (
			sample.get(
				"placement_basis",
				Basis.IDENTITY
			)
		)

		placement_position = _apply_height_offset(
			placement_position,
			placement_normal
		)

		var scale_factor := (
			_get_random_scale_factor()
		)

		var final_basis := (
			placement_basis
			* authored_basis
		)

		final_basis = final_basis.scaled_local(
			Vector3.ONE * scale_factor
		)

		var final_transform := Transform3D(
			final_basis,
			placement_position
		)

		stroke_container.add_child(
			instance,
			true
		)

		instance.owner = scene_root
		_apply_auto_lod_to_instance(instance, scene_root)
		_assign_lod_child_owners(
			instance,
			scene_root
		)
		instance.global_transform = final_transform

		painted_instances.append(
			instance
		)

		painted_transforms.append(
			final_transform
		)

		placed_count += 1

	return placed_count


func _instantiate_selected_scene() -> Node3D:
	if not lod_enabled:
		return _instantiate_scene_root(
			selected_scene
		)

	var levels: Array[Dictionary] = [
		{
			"scene": selected_scene,
			"begin": 0.0,
			"name": "Near",
		},
	]

	if lod1_scene != null:
		levels.append({
			"scene": lod1_scene,
			"begin": lod1_distance,
			"name": "Medium",
		})

	if lod2_scene != null:
		levels.append({
			"scene": lod2_scene,
			"begin": lod2_distance,
			"name": "Distant",
		})

	if levels.size() == 1 and lod_cull_distance <= 0.0:
		return _instantiate_scene_root(
			selected_scene
		)

	var group := Node3D.new()
	group.name = "%s_LOD" % selected_scene.resource_path.get_file().get_basename()
	group.set_script(LOD_INSTANCE_SCRIPT)
	group.add_to_group(LOD_NODE_GROUP, true)
	group.set_meta(LOD_GROUP_META, true)
	group.set_meta(
		&"lod_source_scene_path",
		selected_scene.resource_path
	)
	group.set_meta(&"lod_enabled", lod_enabled)
	group.set_meta(
		&"lod1_scene_path",
		lod1_scene.resource_path if lod1_scene != null else ""
	)
	group.set_meta(
		&"lod2_scene_path",
		lod2_scene.resource_path if lod2_scene != null else ""
	)
	group.set_meta(&"lod1_distance", lod1_distance)
	group.set_meta(&"lod2_distance", lod2_distance)
	group.set_meta(&"lod_cull_distance", lod_cull_distance)

	var authored_basis := Basis.IDENTITY

	for index in range(levels.size()):
		var level: Dictionary = levels[index]
		var level_scene := level.get("scene") as PackedScene
		var level_root := _instantiate_scene_root(level_scene)

		if level_root == null:
			group.free()
			return null

		if index == 0:
			authored_basis = level_root.transform.basis

		level_root.name = str(level.get("name", "LOD"))
		level_root.transform = Transform3D.IDENTITY
		group.add_child(level_root, true)
		level_root.visible = index == 0

		_disable_native_lod_ranges(
			level_root
		)

	group.transform = Transform3D(
		authored_basis,
		Vector3.ZERO
	)
	group.call(
		&"configure",
		lod1_distance,
		lod2_distance,
		lod_cull_distance
	)
	return group


func _instantiate_scene_root(
	scene: PackedScene
) -> Node3D:
	if scene == null or not scene.can_instantiate():
		_set_dock_status(
			"LOD Scene Cannot Be Instantiated"
		)
		return null

	var created_node := scene.instantiate(
		PackedScene.GEN_EDIT_STATE_INSTANCE
	)

	if created_node is Node3D:
		return created_node as Node3D

	if created_node != null:
		created_node.free()

	_set_dock_status(
		"LOD Scene Root Must Inherit Node3D"
	)
	return null


func _disable_native_lod_ranges(
	root: Node
) -> bool:
	var geometry_instances: Array[GeometryInstance3D] = []
	_collect_geometry_instances(
		root,
		geometry_instances
	)
	var changed := false

	for geometry in geometry_instances:
		if (
			not is_zero_approx(geometry.visibility_range_begin)
			or not is_zero_approx(geometry.visibility_range_end)
			or not is_zero_approx(geometry.visibility_range_begin_margin)
			or not is_zero_approx(geometry.visibility_range_end_margin)
		):
			changed = true

		geometry.visibility_range_begin = 0.0
		geometry.visibility_range_end = 0.0
		geometry.visibility_range_begin_margin = 0.0
		geometry.visibility_range_end_margin = 0.0
		geometry.visibility_range_fade_mode = (
			GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		)

	return changed


func _collect_geometry_instances(
	node: Node,
	result: Array[GeometryInstance3D]
) -> void:
	if node is GeometryInstance3D:
		result.append(node as GeometryInstance3D)

	for child in node.get_children():
		_collect_geometry_instances(
			child,
			result
		)


func _assign_lod_child_owners(
	instance: Node3D,
	scene_root: Node3D
) -> void:
	if not bool(instance.get_meta(LOD_GROUP_META, false)):
		return

	for child in instance.get_children():
		if child is Node3D:
			(child as Node3D).owner = scene_root


func _on_editor_scene_changed(
	_scene_root: Node
) -> void:
	call_deferred(
		"_upgrade_existing_lod_groups"
	)
	call_deferred(
		"_apply_lod_settings_to_existing_groups"
	)
	call_deferred(
		"_apply_auto_lod_settings_to_existing_instances"
	)


func _upgrade_existing_lod_groups() -> void:
	var scene_root := (
		get_editor_interface()
		.get_edited_scene_root()
	)
	if scene_root == null:
		return

	var upgraded := _upgrade_lod_groups_recursive(
		scene_root
	)
	if upgraded <= 0:
		return

	var editor_interface := get_editor_interface()
	if editor_interface.has_method(
		&"mark_scene_as_unsaved"
	):
		editor_interface.call(
			&"mark_scene_as_unsaved"
		)

	print(
		"World Brush: Upgraded existing LOD groups -> ",
		upgraded
	)


func _upgrade_lod_groups_recursive(
	node: Node
) -> int:
	var upgraded := 0
	if (
		node is Node3D
		and bool(node.get_meta(LOD_GROUP_META, false))
	):
		var lod_group := node as Node3D
		var group_changed := false
		if not lod_group.is_in_group(LOD_NODE_GROUP):
			lod_group.add_to_group(LOD_NODE_GROUP, true)
			group_changed = true
		if lod_group.get_script() != LOD_INSTANCE_SCRIPT:
			lod_group.set_script(
				LOD_INSTANCE_SCRIPT
			)
			group_changed = true

		lod_group.call(
			&"configure",
			float(lod_group.get_meta(&"lod1_distance", 25.0)),
			float(lod_group.get_meta(&"lod2_distance", 60.0)),
			float(lod_group.get_meta(&"lod_cull_distance", 0.0))
		)

		for level in lod_group.get_children():
			if _disable_native_lod_ranges(level):
				group_changed = true

		if group_changed:
			upgraded += 1

	for child in node.get_children():
		upgraded += _upgrade_lod_groups_recursive(
			child
		)

	return upgraded


func _update_editor_lod_preview(
	delta: float
) -> void:
	editor_lod_preview_elapsed += delta
	if editor_lod_preview_elapsed < 0.15:
		return

	editor_lod_preview_elapsed = 0.0
	var scene_root := (
		get_editor_interface()
		.get_edited_scene_root()
	)
	if scene_root == null:
		return

	var editor_viewport := (
		get_editor_interface()
		.get_editor_viewport_3d(0)
	)
	if editor_viewport == null:
		return

	var camera := editor_viewport.get_camera_3d()
	if camera == null:
		return

	for candidate in get_tree().get_nodes_in_group(
		LOD_NODE_GROUP
	):
		if not candidate is Node3D:
			continue

		var lod_group := candidate as Node3D
		if (
			lod_group != scene_root
			and not scene_root.is_ancestor_of(lod_group)
		):
			continue

		if lod_group.has_method(&"update_for_distance"):
			lod_group.call(
				&"update_for_distance",
				camera.global_position.distance_to(
					lod_group.global_position
				)
			)


func _apply_height_offset(
	position: Vector3,
	normal: Vector3
) -> Vector3:
	if is_zero_approx(
		height_offset
	):
		return position

	if (
		height_offset_mode
		== HeightOffsetMode.WORLD_Y
	):
		return (
			position
			+ Vector3.UP * height_offset
		)

	var safe_normal := normal

	if not _is_valid_normal(
		safe_normal
	):
		safe_normal = Vector3.UP
	else:
		safe_normal = safe_normal.normalized()

	return (
		position
		+ safe_normal * height_offset
	)


func _get_random_scale_factor() -> float:
	if not random_scale_enabled:
		return 1.0

	var safe_minimum := maxf(
		minimum_scale,
		0.01
	)

	var safe_maximum := maxf(
		maximum_scale,
		safe_minimum
	)

	if is_equal_approx(
		safe_minimum,
		safe_maximum
	):
		return safe_minimum

	return random_generator.randf_range(
		safe_minimum,
		safe_maximum
	)


# =========================================================
# الحذف المباشر
# =========================================================

func _erase_scene_instances_live() -> int:
	var edited_root := (
		get_editor_interface()
		.get_edited_scene_root()
	)

	if not edited_root is Node3D:
		_set_dock_status(
			"Scene Root Must Be Node3D"
		)

		return 0

	var scene_root := edited_root as Node3D

	if stroke_scene_root == null:
		stroke_scene_root = scene_root

	if stroke_scene_root != scene_root:
		_set_dock_status(
			"Edited Scene Changed During Stroke"
		)

		return 0

	if not is_instance_valid(
		stroke_container
	):
		stroke_container = (
			_find_world_brush_container(
				scene_root
			)
		)

	if not is_instance_valid(
		stroke_container
	):
		_set_dock_status(
			"No World Brush Instances"
		)

		return 0

	var radius_squared := (
		brush_radius * brush_radius
	)

	var erased_count: int = 0

	for child in stroke_container.get_children():
		if not child is Node3D:
			continue

		var instance := child as Node3D

		if not bool(
			instance.get_meta(
				INSTANCE_META,
				false
			)
		):
			continue

		var distance_squared := (
			_horizontal_distance_squared(
				instance.global_position,
				surface_position
			)
		)

		if distance_squared > radius_squared:
			continue

		erased_instances.append(
			instance
		)

		erased_transforms.append(
			instance.global_transform
		)

		instance.owner = null

		stroke_container.remove_child(
			instance
		)

		erased_count += 1

	return erased_count


# =========================================================
# Undo لسحبة الرسم
# =========================================================

func _commit_paint_stroke() -> void:
	if painted_instances.is_empty():
		_remove_empty_created_container()
		return

	if not is_instance_valid(
		stroke_scene_root
	):
		return

	if not is_instance_valid(
		stroke_container
	):
		return

	var instances_snapshot: Array = (
		painted_instances.duplicate()
	)

	var transforms_snapshot: Array = (
		painted_transforms.duplicate()
	)

	var saved_scene_root := stroke_scene_root
	var saved_container := stroke_container

	var saved_created_container := (
		stroke_created_container
	)

	var undo_redo := get_undo_redo()

	undo_redo.create_action(
		"World Brush: Paint Stroke (%d)"
		% instances_snapshot.size(),
		UndoRedo.MERGE_DISABLE,
		saved_scene_root
	)

	undo_redo.add_do_method(
		self,
		&"_redo_paint_batch",
		saved_scene_root,
		saved_container,
		instances_snapshot,
		transforms_snapshot,
		saved_created_container
	)

	undo_redo.add_undo_method(
		self,
		&"_undo_paint_batch",
		saved_scene_root,
		saved_container,
		instances_snapshot,
		saved_created_container
	)

	if saved_created_container:
		undo_redo.add_do_reference(
			saved_container
		)

	for instance_value in instances_snapshot:
		if instance_value is Node3D:
			var instance := (
				instance_value as Node3D
			)

			if is_instance_valid(instance):
				undo_redo.add_do_reference(
					instance
				)

	undo_redo.commit_action(
		false
	)

	_set_dock_status(
		"Paint Stroke Saved: %d"
		% instances_snapshot.size()
	)


func _redo_paint_batch(
	scene_root: Node3D,
	container: Node3D,
	instances: Array,
	transforms: Array,
	created_container: bool
) -> void:
	if not is_instance_valid(scene_root):
		return

	if not is_instance_valid(container):
		return

	if (
		created_container
		and container.get_parent() == null
	):
		scene_root.add_child(
			container,
			true
		)

		container.owner = scene_root

	for index in range(
		instances.size()
	):
		var instance_value: Variant = (
			instances[index]
		)

		if not instance_value is Node3D:
			continue

		var instance := (
			instance_value as Node3D
		)

		if not is_instance_valid(instance):
			continue

		if instance.get_parent() == null:
			container.add_child(
				instance,
				true
			)

		instance.owner = scene_root
		_assign_lod_child_owners(
			instance,
			scene_root
		)

		if index < transforms.size():
			var saved_transform: Variant = (
				transforms[index]
			)

			if saved_transform is Transform3D:
				instance.global_transform = (
					saved_transform
				)


func _undo_paint_batch(
	scene_root: Node3D,
	container: Node3D,
	instances: Array,
	created_container: bool
) -> void:
	if not is_instance_valid(container):
		return

	for instance_value in instances:
		if not instance_value is Node3D:
			continue

		var instance := (
			instance_value as Node3D
		)

		if not is_instance_valid(instance):
			continue

		if instance.get_parent() == container:
			instance.owner = null

			container.remove_child(
				instance
			)

	if (
		created_container
		and is_instance_valid(scene_root)
		and container.get_parent() == scene_root
		and container.get_child_count() == 0
	):
		container.owner = null

		scene_root.remove_child(
			container
		)


# =========================================================
# Undo لسحبة الحذف
# =========================================================

func _commit_erase_stroke() -> void:
	if erased_instances.is_empty():
		return

	if not is_instance_valid(
		stroke_scene_root
	):
		return

	if not is_instance_valid(
		stroke_container
	):
		return

	var instances_snapshot: Array = (
		erased_instances.duplicate()
	)

	var transforms_snapshot: Array = (
		erased_transforms.duplicate()
	)

	var saved_scene_root := stroke_scene_root
	var saved_container := stroke_container

	var undo_redo := get_undo_redo()

	undo_redo.create_action(
		"World Brush: Erase Stroke (%d)"
		% instances_snapshot.size(),
		UndoRedo.MERGE_DISABLE,
		saved_scene_root
	)

	undo_redo.add_do_method(
		self,
		&"_redo_erase_batch",
		saved_container,
		instances_snapshot
	)

	undo_redo.add_undo_method(
		self,
		&"_undo_erase_batch",
		saved_scene_root,
		saved_container,
		instances_snapshot,
		transforms_snapshot
	)

	for instance_value in instances_snapshot:
		if instance_value is Node3D:
			var instance := (
				instance_value as Node3D
			)

			if is_instance_valid(instance):
				undo_redo.add_undo_reference(
					instance
				)

	undo_redo.commit_action(
		false
	)

	_set_dock_status(
		"Erase Stroke Saved: %d"
		% instances_snapshot.size()
	)


func _redo_erase_batch(
	container: Node3D,
	instances: Array
) -> void:
	if not is_instance_valid(container):
		return

	for instance_value in instances:
		if not instance_value is Node3D:
			continue

		var instance := (
			instance_value as Node3D
		)

		if not is_instance_valid(instance):
			continue

		if instance.get_parent() == container:
			instance.owner = null

			container.remove_child(
				instance
			)


func _undo_erase_batch(
	scene_root: Node3D,
	container: Node3D,
	instances: Array,
	transforms: Array
) -> void:
	if not is_instance_valid(scene_root):
		return

	if not is_instance_valid(container):
		return

	if container.get_parent() == null:
		scene_root.add_child(
			container,
			true
		)

		container.owner = scene_root

	for index in range(
		instances.size()
	):
		var instance_value: Variant = (
			instances[index]
		)

		if not instance_value is Node3D:
			continue

		var instance := (
			instance_value as Node3D
		)

		if not is_instance_valid(instance):
			continue

		if instance.get_parent() == null:
			container.add_child(
				instance,
				true
			)

		instance.owner = scene_root
		_assign_lod_child_owners(
			instance,
			scene_root
		)

		if index < transforms.size():
			var saved_transform: Variant = (
				transforms[index]
			)

			if saved_transform is Transform3D:
				instance.global_transform = (
					saved_transform
				)


func _remove_empty_created_container() -> void:
	if not stroke_created_container:
		return

	if not is_instance_valid(
		stroke_container
	):
		return

	if stroke_container.get_child_count() > 0:
		return

	var parent := stroke_container.get_parent()

	if parent != null:
		stroke_container.owner = null

		parent.remove_child(
			stroke_container
		)

	stroke_container.free()


# =========================================================
# العثور على حاوية العناصر
# =========================================================

func _find_world_brush_container(
	scene_root: Node3D
) -> Node3D:
	for child in scene_root.get_children():
		if not child is Node3D:
			continue

		if bool(
			child.get_meta(
				CONTAINER_META,
				false
			)
		):
			return child as Node3D

	return null


# =========================================================
# اكتشاف السطح
# =========================================================

func _update_surface_hit(
	camera: Camera3D,
	mouse_position: Vector2
) -> void:
	var edited_root := (
		get_editor_interface()
		.get_edited_scene_root()
	)

	if not edited_root is Node3D:
		_clear_surface_hit(
			"Open A 3D Scene First"
		)

		return

	var scene_root := edited_root as Node3D
	var world_3d := scene_root.get_world_3d()

	if world_3d == null:
		_clear_surface_hit(
			"3D World Not Available"
		)

		return

	var ray_origin := (
		camera.project_ray_origin(
			mouse_position
		)
	)

	var ray_direction := (
		camera.project_ray_normal(
			mouse_position
		).normalized()
	)

	var ray_end := (
		ray_origin
		+ ray_direction * RAY_LENGTH
	)

	var result := _find_cursor_surface(
		scene_root,
		world_3d,
		ray_origin,
		ray_direction,
		ray_end
	)

	if result.is_empty():
		_clear_surface_hit(
			"No Surface Under Cursor"
		)

		return

	var hit_position: Vector3 = (
		result.get(
			"position",
			Vector3.ZERO
		)
	)

	var hit_normal: Vector3 = (
		result.get(
			"normal",
			Vector3.UP
		)
	)

	if not hit_position.is_finite():
		_clear_surface_hit(
			"Invalid Surface Position"
		)

		return

	if not _is_valid_normal(
		hit_normal
	):
		hit_normal = Vector3.UP

	has_surface_hit = true

	surface_position = hit_position
	surface_normal = hit_normal.normalized()

	surface_type = str(
		result.get(
			"surface_type",
			"Surface"
		)
	)

	_show_brush_preview(
		scene_root
	)

	if stroke_mode == StrokeMode.NONE:
		_set_dock_status(
			"%s | X %.2f | Y %.2f | Z %.2f" % [
				surface_type,
				surface_position.x,
				surface_position.y,
				surface_position.z,
			]
		)


func _find_cursor_surface(
	scene_root: Node3D,
	world_3d: World3D,
	ray_origin: Vector3,
	ray_direction: Vector3,
	ray_end: Vector3
) -> Dictionary:
	var physics_hit := (
		_intersect_physics_surface(
			world_3d,
			ray_origin,
			ray_end
		)
	)

	var terrain_hit := (
		_intersect_terrain_cursor(
			scene_root,
			ray_origin,
			ray_direction
		)
	)

	if physics_hit.is_empty():
		return terrain_hit

	if terrain_hit.is_empty():
		return physics_hit

	var physics_position: Vector3 = (
		physics_hit.get(
			"position",
			Vector3.ZERO
		)
	)

	var terrain_position: Vector3 = (
		terrain_hit.get(
			"position",
			Vector3.ZERO
		)
	)

	var physics_distance := (
		ray_origin.distance_squared_to(
			physics_position
		)
	)

	var terrain_distance := (
		ray_origin.distance_squared_to(
			terrain_position
		)
	)

	if physics_distance <= terrain_distance:
		return physics_hit

	return terrain_hit


func _intersect_terrain_cursor(
	scene_root: Node3D,
	ray_origin: Vector3,
	ray_direction: Vector3
) -> Dictionary:
	var terrain_nodes := (
		_get_terrain3d_nodes(
			scene_root
		)
	)

	var closest_result: Dictionary = {}
	var closest_distance: float = INF

	for terrain_node in terrain_nodes:
		if not is_instance_valid(
			terrain_node
		):
			continue

		if not terrain_node.has_method(
			&"get_intersection"
		):
			continue

		var point_value: Variant = (
			terrain_node.call(
				&"get_intersection",
				ray_origin,
				ray_direction,
				false
			)
		)

		if typeof(point_value) != TYPE_VECTOR3:
			continue

		var terrain_point: Vector3 = point_value

		if not _is_valid_terrain_point(
			terrain_point
		):
			continue

		var direction_to_point := (
			terrain_point - ray_origin
		)

		if (
			direction_to_point.dot(
				ray_direction
			)
			<= 0.0
		):
			continue

		var distance_squared := (
			ray_origin.distance_squared_to(
				terrain_point
			)
		)

		if distance_squared >= closest_distance:
			continue

		closest_distance = distance_squared

		closest_result = {
			"position": terrain_point,
			"normal": _get_terrain_normal(
				terrain_node,
				terrain_point
			),
			"collider": terrain_node,
			"surface_type": "Terrain3D",
		}

	return closest_result


# =========================================================
# عينات السطح
# =========================================================

func _sample_surface_at_xz(
	scene_root: Node3D,
	world_3d: World3D,
	x_position: float,
	z_position: float,
	reference_height: float
) -> Dictionary:
	var ray_origin := Vector3(
		x_position,
		reference_height + SAMPLE_VERTICAL_RANGE,
		z_position
	)

	var ray_end := Vector3(
		x_position,
		reference_height - SAMPLE_VERTICAL_RANGE,
		z_position
	)

	var physics_hit := (
		_intersect_physics_surface(
			world_3d,
			ray_origin,
			ray_end
		)
	)

	var terrain_hit := (
		_sample_terrain_height(
			scene_root,
			x_position,
			z_position,
			reference_height
		)
	)

	if physics_hit.is_empty():
		return terrain_hit

	if terrain_hit.is_empty():
		return physics_hit

	var physics_position: Vector3 = (
		physics_hit.get(
			"position",
			Vector3.ZERO
		)
	)

	var terrain_position: Vector3 = (
		terrain_hit.get(
			"position",
			Vector3.ZERO
		)
	)

	if physics_position.y >= terrain_position.y:
		return physics_hit

	return terrain_hit


func _sample_terrain_height(
	scene_root: Node3D,
	x_position: float,
	z_position: float,
	reference_height: float
) -> Dictionary:
	var terrain_nodes := (
		_get_terrain3d_nodes(
			scene_root
		)
	)

	var best_result: Dictionary = {}
	var highest_height: float = -INF

	var query_position := Vector3(
		x_position,
		reference_height,
		z_position
	)

	for terrain_node in terrain_nodes:
		if not is_instance_valid(
			terrain_node
		):
			continue

		var terrain_data := (
			_get_terrain_data(
				terrain_node
			)
		)

		if terrain_data == null:
			continue

		if not terrain_data.has_method(
			&"get_height"
		):
			continue

		var height_value: Variant = (
			terrain_data.call(
				&"get_height",
				query_position
			)
		)

		if (
			typeof(height_value) != TYPE_FLOAT
			and typeof(height_value) != TYPE_INT
		):
			continue

		var terrain_height := float(
			height_value
		)

		if (
			is_nan(terrain_height)
			or is_inf(terrain_height)
		):
			continue

		if terrain_height <= highest_height:
			continue

		var terrain_position := Vector3(
			x_position,
			terrain_height,
			z_position
		)

		highest_height = terrain_height

		best_result = {
			"position": terrain_position,
			"normal": _get_terrain_normal(
				terrain_node,
				terrain_position
			),
			"collider": terrain_node,
			"surface_type": "Terrain3D",
		}

	return best_result


func _get_terrain_data(
	terrain_node: Node
) -> Object:
	if terrain_node == null:
		return null

	if terrain_node.has_method(
		&"get_data"
	):
		var data_value: Variant = (
			terrain_node.call(
				&"get_data"
			)
		)

		if data_value is Object:
			return data_value as Object

	var property_value: Variant = (
		terrain_node.get(
			"data"
		)
	)

	if property_value is Object:
		return property_value as Object

	return null


func _get_terrain_normal(
	terrain_node: Node,
	global_position: Vector3
) -> Vector3:
	var terrain_data := (
		_get_terrain_data(
			terrain_node
		)
	)

	if terrain_data == null:
		return Vector3.UP

	if not terrain_data.has_method(
		&"get_normal"
	):
		return Vector3.UP

	var normal_value: Variant = (
		terrain_data.call(
			&"get_normal",
			global_position
		)
	)

	if typeof(normal_value) != TYPE_VECTOR3:
		return Vector3.UP

	var terrain_normal: Vector3 = normal_value

	if not _is_valid_normal(
		terrain_normal
	):
		return Vector3.UP

	return terrain_normal.normalized()


# =========================================================
# RayCast للأسطح العادية
# =========================================================

func _intersect_physics_surface(
	world_3d: World3D,
	ray_origin: Vector3,
	ray_end: Vector3
) -> Dictionary:
	var excluded_objects: Array[RID] = []

	for _attempt in range(
		MAX_RAY_SKIPS
	):
		var query := (
			PhysicsRayQueryParameters3D.create(
				ray_origin,
				ray_end
			)
		)

		query.collide_with_bodies = true
		query.collide_with_areas = true
		query.exclude = excluded_objects

		var result := (
			world_3d
			.direct_space_state
			.intersect_ray(
				query
			)
		)

		if result.is_empty():
			return {}

		var collider: Object = (
			result.get(
				"collider"
			)
		)

		if not _belongs_to_world_brush_instance(
			collider
		):
			result["surface_type"] = "Physics"
			return result

		if collider is CollisionObject3D:
			var collision_object := (
				collider as CollisionObject3D
			)

			excluded_objects.append(
				collision_object.get_rid()
			)

			continue

		return {}

	return {}


func _belongs_to_world_brush_instance(
	collider: Object
) -> bool:
	if not collider is Node:
		return false

	var current_node := collider as Node

	while current_node != null:
		if bool(
			current_node.get_meta(
				INSTANCE_META,
				false
			)
		):
			return true

		current_node = (
			current_node.get_parent()
		)

	return false


# =========================================================
# توليد نقاط الرسم
# =========================================================

func _generate_brush_samples(
	scene_root: Node3D,
	world_3d: World3D,
	container: Node3D
) -> Array[Dictionary]:
	var generated_samples: Array[Dictionary] = []

	var occupied_positions := (
		_get_existing_positions(
			container
		)
	)

	var spacing_squared := (
		minimum_spacing
		* minimum_spacing
	)

	var maximum_attempts := maxi(
		MINIMUM_PLACEMENT_ATTEMPTS,
		instances_per_click
		* PLACEMENT_ATTEMPTS_PER_INSTANCE
	)

	maximum_attempts = mini(
		maximum_attempts,
		MAX_TOTAL_PLACEMENT_ATTEMPTS
	)

	var attempts: int = 0

	while (
		generated_samples.size()
		< instances_per_click
		and attempts < maximum_attempts
	):
		attempts += 1

		var candidate_x := surface_position.x
		var candidate_z := surface_position.z

		if instances_per_click > 1:
			var angle := (
				random_generator.randf_range(
					0.0,
					TAU
				)
			)

			var distance_from_center := (
				sqrt(
					random_generator.randf()
				)
				* brush_radius
			)

			candidate_x += (
				cos(angle)
				* distance_from_center
			)

			candidate_z += (
				sin(angle)
				* distance_from_center
			)

		var surface_sample := (
			_sample_surface_at_xz(
				scene_root,
				world_3d,
				candidate_x,
				candidate_z,
				surface_position.y
			)
		)

		if surface_sample.is_empty():
			continue

		var candidate_position: Vector3 = (
			surface_sample.get(
				"position",
				Vector3.ZERO
			)
		)

		var candidate_normal: Vector3 = (
			surface_sample.get(
				"normal",
				Vector3.UP
			)
		)

		if not candidate_position.is_finite():
			continue

		if not _is_valid_normal(
			candidate_normal
		):
			continue

		candidate_normal = (
			candidate_normal.normalized()
		)

		if not _is_slope_allowed(
			candidate_normal
		):
			continue

		if not _has_required_spacing(
			candidate_position,
			occupied_positions,
			generated_samples,
			spacing_squared
		):
			continue

		var rotation_angle: float = 0.0

		if random_y_rotation:
			rotation_angle = (
				random_generator.randf_range(
					0.0,
					TAU
				)
			)

		var placement_basis := (
			_create_placement_basis(
				candidate_normal,
				rotation_angle,
				align_to_surface
			)
		)

		generated_samples.append(
			{
				"position": candidate_position,
				"normal": candidate_normal,
				"placement_basis": placement_basis,
				"surface_type": surface_sample.get(
					"surface_type",
					"Surface"
				),
			}
		)

	return generated_samples


func _create_placement_basis(
	normal: Vector3,
	rotation_angle: float,
	should_align_to_surface: bool
) -> Basis:
	if not should_align_to_surface:
		if is_zero_approx(
			rotation_angle
		):
			return Basis.IDENTITY

		return Basis(
			Vector3.UP,
			rotation_angle
		).orthonormalized()

	var up_vector := normal.normalized()

	if not _is_valid_normal(
		up_vector
	):
		up_vector = Vector3.UP

	var surface_basis := (
		_create_surface_basis(
			up_vector
		)
	)

	if is_zero_approx(
		rotation_angle
	):
		return surface_basis

	var rotation_basis := Basis(
		up_vector,
		rotation_angle
	)

	return (
		rotation_basis
		* surface_basis
	).orthonormalized()


func _create_surface_basis(
	up_vector: Vector3
) -> Basis:
	var up := up_vector.normalized()

	if not _is_valid_normal(up):
		up = Vector3.UP

	var forward := (
		Vector3.FORWARD
		- up * Vector3.FORWARD.dot(up)
	)

	if forward.length_squared() < 0.000001:
		forward = (
			Vector3.RIGHT
			- up * Vector3.RIGHT.dot(up)
		)

	if forward.length_squared() < 0.000001:
		return Basis.IDENTITY

	forward = forward.normalized()

	var right := (
		forward.cross(up).normalized()
	)

	if not _is_valid_normal(right):
		return Basis.IDENTITY

	var backward := (
		right.cross(up).normalized()
	)

	if not _is_valid_normal(backward):
		return Basis.IDENTITY

	return Basis(
		right,
		up,
		backward
	).orthonormalized()


func _is_slope_allowed(
	normal: Vector3
) -> bool:
	if not _is_valid_normal(
		normal
	):
		return false

	var safe_normal := normal.normalized()

	var up_alignment := clampf(
		safe_normal.dot(
			Vector3.UP
		),
		-1.0,
		1.0
	)

	var slope_radians := acos(
		up_alignment
	)

	var slope_degrees := rad_to_deg(
		slope_radians
	)

	return (
		slope_degrees
		<= maximum_slope_degrees
	)


func _get_existing_positions(
	container: Node3D
) -> Array[Vector3]:
	var positions: Array[Vector3] = []

	if not is_instance_valid(container):
		return positions

	if not container.is_inside_tree():
		return positions

	for child in container.get_children():
		if child is Node3D:
			positions.append(
				(child as Node3D).global_position
			)

	return positions


func _has_required_spacing(
	candidate: Vector3,
	existing_positions: Array[Vector3],
	new_samples: Array[Dictionary],
	spacing_squared: float
) -> bool:
	if spacing_squared <= 0.0:
		return true

	for existing_position in existing_positions:
		if (
			_horizontal_distance_squared(
				candidate,
				existing_position
			)
			< spacing_squared
		):
			return false

	for sample in new_samples:
		var new_position: Vector3 = (
			sample.get(
				"position",
				Vector3.ZERO
			)
		)

		if (
			_horizontal_distance_squared(
				candidate,
				new_position
			)
			< spacing_squared
		):
			return false

	return true


func _horizontal_distance_squared(
	first: Vector3,
	second: Vector3
) -> float:
	var difference := Vector2(
		first.x - second.x,
		first.z - second.z
	)

	return difference.length_squared()


# =========================================================
# Terrain3D Cache
# =========================================================

func _get_terrain3d_nodes(
	scene_root: Node
) -> Array[Node]:
	var current_time := (
		Time.get_ticks_msec()
	)

	var root_changed := (
		not is_instance_valid(
			cached_scene_root
		)
		or cached_scene_root != scene_root
	)

	var scan_expired := (
		current_time
		- last_terrain_scan_time
		>= TERRAIN_SCAN_INTERVAL_MS
	)

	var cache_invalid := false

	for terrain_node in cached_terrain_nodes:
		if not is_instance_valid(
			terrain_node
		):
			cache_invalid = true
			break

	if (
		root_changed
		or scan_expired
		or cache_invalid
	):
		cached_scene_root = scene_root
		cached_terrain_nodes.clear()

		_collect_terrain3d_nodes(
			scene_root,
			cached_terrain_nodes
		)

		last_terrain_scan_time = current_time

	return cached_terrain_nodes


func _collect_terrain3d_nodes(
	current_node: Node,
	result: Array[Node]
) -> void:
	if _is_terrain3d_node(
		current_node
	):
		result.append(
			current_node
		)

	for child in current_node.get_children(
		true
	):
		if child is Node:
			_collect_terrain3d_nodes(
				child as Node,
				result
			)


func _is_terrain3d_node(
	node: Node
) -> bool:
	if node == null:
		return false

	if node.get_class() == "Terrain3D":
		return true

	return node.is_class(
		"Terrain3D"
	)


func _clear_terrain_cache() -> void:
	cached_scene_root = null
	cached_terrain_nodes.clear()
	last_terrain_scan_time = 0


# =========================================================
# دائرة الفرشاة
# =========================================================

func _show_brush_preview(
	scene_root: Node3D
) -> void:
	_ensure_brush_preview(
		scene_root
	)

	if not is_instance_valid(
		brush_preview
	):
		return

	brush_preview.global_transform = Transform3D(
		Basis.IDENTITY,
		surface_position
		+ Vector3.UP * BRUSH_HEIGHT_OFFSET
	)

	brush_preview.visible = true


func _ensure_brush_preview(
	scene_root: Node3D
) -> void:
	if is_instance_valid(
		brush_preview
	):
		if brush_preview.get_parent() == scene_root:
			return

		_remove_brush_preview()

	brush_preview = MeshInstance3D.new()
	brush_preview.name = "_WorldBrushPreview"
	brush_preview.top_level = true
	brush_preview.visible = false

	brush_preview.cast_shadow = (
		GeometryInstance3D
		.SHADOW_CASTING_SETTING_OFF
	)

	brush_preview_mesh = ImmediateMesh.new()
	brush_preview.mesh = brush_preview_mesh

	brush_preview_material = StandardMaterial3D.new()

	brush_preview_material.shading_mode = (
		BaseMaterial3D.SHADING_MODE_UNSHADED
	)

	brush_preview_material.no_depth_test = true

	_apply_preview_color()

	scene_root.add_child(
		brush_preview,
		false,
		Node.INTERNAL_MODE_BACK
	)

	_rebuild_brush_preview_mesh()


func _rebuild_brush_preview_mesh() -> void:
	if not is_instance_valid(
		brush_preview_mesh
	):
		return

	brush_preview_mesh.clear_surfaces()

	brush_preview_mesh.surface_begin(
		Mesh.PRIMITIVE_LINE_STRIP,
		brush_preview_material
	)

	for index in range(
		BRUSH_SEGMENTS + 1
	):
		var percentage := (
			float(index)
			/ float(BRUSH_SEGMENTS)
		)

		var angle := percentage * TAU

		var point := Vector3(
			cos(angle) * brush_radius,
			0.0,
			sin(angle) * brush_radius
		)

		brush_preview_mesh.surface_add_vertex(
			point
		)

	brush_preview_mesh.surface_end()


func _set_erase_preview_active(
	enabled: bool
) -> void:
	erase_preview_active = enabled
	_apply_preview_color()


func _apply_preview_color() -> void:
	if not is_instance_valid(
		brush_preview_material
	):
		return

	if erase_preview_active:
		brush_preview_material.albedo_color = (
			ERASE_PREVIEW_COLOR
		)
	else:
		brush_preview_material.albedo_color = (
			PAINT_PREVIEW_COLOR
		)


func _hide_brush_preview() -> void:
	if is_instance_valid(
		brush_preview
	):
		brush_preview.visible = false


func _remove_brush_preview() -> void:
	if is_instance_valid(
		brush_preview
	):
		brush_preview.queue_free()

	brush_preview = null
	brush_preview_mesh = null
	brush_preview_material = null
	erase_preview_active = false


# =========================================================
# التحقق والحالة
# =========================================================

func _is_valid_terrain_point(
	point: Vector3
) -> bool:
	if not point.is_finite():
		return false

	if absf(point.x) >= INVALID_TERRAIN_LIMIT:
		return false

	if absf(point.y) >= INVALID_TERRAIN_LIMIT:
		return false

	if absf(point.z) >= INVALID_TERRAIN_LIMIT:
		return false

	return true


func _is_valid_normal(
	normal: Vector3
) -> bool:
	if not normal.is_finite():
		return false

	return (
		normal.length_squared()
		>= 0.000001
	)


func _clear_surface_hit(
	message: String
) -> void:
	has_surface_hit = false

	surface_position = Vector3.ZERO
	surface_normal = Vector3.UP
	surface_type = ""

	_hide_brush_preview()

	_set_dock_status(
		message
	)


func _set_dock_status(
	message: String
) -> void:
	if not is_instance_valid(
		dock_content
	):
		return

	var status_label := (
		dock_content.get_node_or_null(
			"StatusLabel"
		) as Label
	)

	if status_label != null:
		status_label.text = message


# =========================================================
# إشارات الواجهة
# =========================================================

func _on_selected_scene_changed(
	scene: PackedScene
) -> void:
	_end_active_stroke()

	selected_scene = scene

	if selected_scene == null:
		has_surface_hit = false
		surface_type = ""

		_hide_brush_preview()

		print(
			"World Brush: Scene selection cleared."
		)

		return

	print(
		"World Brush: Selected scene -> ",
		selected_scene.resource_path
	)


func _on_brush_enabled_changed(
	enabled: bool
) -> void:
	if not enabled:
		_end_active_stroke()

	brush_enabled = enabled

	if not brush_enabled:
		has_surface_hit = false
		surface_type = ""

		_hide_brush_preview()

	print(
		"World Brush: Brush enabled -> ",
		brush_enabled
	)


func _on_brush_radius_changed(
	radius: float
) -> void:
	brush_radius = maxf(
		radius,
		0.5
	)

	_rebuild_brush_preview_mesh()


func _on_instances_per_click_changed(
	count: int
) -> void:
	instances_per_click = maxi(
		count,
		1
	)


func _on_minimum_spacing_changed(
	spacing: float
) -> void:
	minimum_spacing = maxf(
		spacing,
		0.0
	)


func _on_random_y_rotation_changed(
	enabled: bool
) -> void:
	random_y_rotation = enabled


func _on_align_to_surface_changed(
	enabled: bool
) -> void:
	align_to_surface = enabled


func _on_maximum_slope_changed(
	value: float
) -> void:
	maximum_slope_degrees = clampf(
		value,
		0.0,
		90.0
	)

	print(
		"World Brush: Maximum slope -> ",
		maximum_slope_degrees
	)


func _on_height_offset_changed(
	value: float
) -> void:
	height_offset = value

	print(
		"World Brush: Height offset -> ",
		height_offset
	)


func _on_height_offset_mode_changed(
	mode: int
) -> void:
	height_offset_mode = clampi(
		mode,
		HeightOffsetMode.WORLD_Y,
		HeightOffsetMode.SURFACE_NORMAL
	)

	print(
		"World Brush: Height offset mode -> ",
		height_offset_mode
	)


func _on_random_scale_enabled_changed(
	enabled: bool
) -> void:
	random_scale_enabled = enabled

	print(
		"World Brush: Random scale -> ",
		random_scale_enabled
	)


func _on_minimum_scale_changed(
	value: float
) -> void:
	minimum_scale = maxf(
		value,
		0.01
	)

	if minimum_scale > maximum_scale:
		maximum_scale = minimum_scale

	print(
		"World Brush: Minimum scale -> ",
		minimum_scale
	)


func _on_maximum_scale_changed(
	value: float
) -> void:
	maximum_scale = maxf(
		value,
		0.01
	)

	if maximum_scale < minimum_scale:
		minimum_scale = maximum_scale

	print(
		"World Brush: Maximum scale -> ",
		maximum_scale
	)


func _on_auto_lod_settings_changed(
	enabled: bool,
	detail_bias: float,
	cull_distance: float
) -> void:
	auto_lod_enabled = enabled
	auto_lod_bias = clampf(detail_bias, 0.0, 4.0)
	auto_lod_cull_distance = maxf(cull_distance, 0.0)
	_apply_auto_lod_settings_to_existing_instances()
	print(
		"World Brush: Auto LOD -> ",
		auto_lod_enabled,
		" | bias ",
		auto_lod_bias,
		" | cull ",
		auto_lod_cull_distance
	)


func _on_auto_lod_import_requested(
	scene_path: String,
	enabled: bool
) -> void:
	call_deferred(
		"_apply_auto_lod_import_setting",
		scene_path,
		enabled
	)


func _apply_auto_lod_to_instance(
	instance: Node3D,
	scene_owner: Node = null
) -> bool:
	var controller := instance.get_node_or_null(
		NodePath(AUTO_LOD_CONTROLLER_NAME)
	)
	var effective_cull := auto_lod_cull_distance
	if bool(instance.get_meta(LOD_GROUP_META, false)):
		effective_cull = 0.0
	if auto_lod_enabled:
		var created := false
		if controller == null:
			controller = Node.new()
			controller.name = AUTO_LOD_CONTROLLER_NAME
			controller.set_script(AUTO_LOD_CONTROLLER_SCRIPT)
			instance.add_child(controller, true)
			created = true
		if scene_owner != null:
			controller.owner = scene_owner
		controller.call(
			"configure",
			true,
			auto_lod_bias,
			effective_cull
		)
		return created or true
	if controller == null:
		return false
	if controller.has_method("restore_original_settings"):
		controller.call("restore_original_settings")
	instance.remove_child(controller)
	controller.free()
	return true


func _apply_auto_lod_settings_to_existing_instances() -> void:
	if selected_scene == null or selected_scene.resource_path.is_empty():
		return
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root == null:
		return
	var roots: Array[Node3D] = []
	_collect_painted_instance_roots(scene_root, roots)
	var updated := 0
	for instance in roots:
		if _get_painted_source_path(instance) != selected_scene.resource_path:
			continue
		if _apply_auto_lod_to_instance(instance, scene_root):
			updated += 1
	if updated <= 0:
		return
	var editor_interface := get_editor_interface()
	if editor_interface.has_method(&"mark_scene_as_unsaved"):
		editor_interface.call(&"mark_scene_as_unsaved")
	print("World Brush: Updated Auto LOD instances -> ", updated)


func _collect_painted_instance_roots(
	node: Node,
	result: Array[Node3D]
) -> void:
	if node is Node3D and (
		bool(node.get_meta(INSTANCE_META, false))
		or bool(node.get_meta(LOD_GROUP_META, false))
	):
		result.append(node as Node3D)
		return
	for child in node.get_children():
		_collect_painted_instance_roots(child, result)


func _get_painted_source_path(instance: Node3D) -> String:
	var source_path := str(instance.get_meta(SOURCE_SCENE_META, ""))
	if source_path.is_empty():
		source_path = str(instance.get_meta(&"lod_source_scene_path", ""))
	if source_path.is_empty():
		source_path = instance.scene_file_path
	if source_path.is_empty() and bool(instance.get_meta(LOD_GROUP_META, false)):
		var near_level := instance.get_node_or_null(^"Near") as Node3D
		if near_level != null:
			source_path = near_level.scene_file_path
	return source_path


func _apply_auto_lod_import_setting(
	scene_path: String,
	enabled: bool
) -> void:
	if scene_path.is_empty() or not ResourceLoader.exists(scene_path, "PackedScene"):
		_set_dock_status("Auto LOD: Active scene is missing or unsaved")
		return
	var import_paths := PackedStringArray()
	_collect_import_sources_from_path(scene_path, import_paths)
	if import_paths.is_empty():
		_set_dock_status("Auto LOD: No supported imported model found in active scene")
		return
	var changed_paths := PackedStringArray()
	for source_path in import_paths:
		var sidecar_path := source_path + ".import"
		var config := ConfigFile.new()
		if config.load(sidecar_path) != OK:
			continue
		var current_value := bool(config.get_value("params", "meshes/generate_lods", true))
		if current_value == enabled:
			changed_paths.append(source_path)
			continue
		config.set_value("params", "meshes/generate_lods", enabled)
		if config.save(sidecar_path) == OK:
			changed_paths.append(source_path)
	if changed_paths.is_empty():
		_set_dock_status("Auto LOD: Import settings could not be updated")
		return
	_set_dock_status("Auto LOD: Reimporting active model only...")
	get_editor_interface().get_resource_filesystem().reimport_files(changed_paths)
	_set_dock_status(
		"Auto LOD enabled for active model" if enabled
		else "Auto LOD disabled for active model"
	)
	print("World Brush: Reimported Auto LOD sources -> ", changed_paths)


func _collect_import_sources_from_path(
	scene_path: String,
	result: PackedStringArray
) -> void:
	_add_import_source_if_supported(scene_path, result)
	var packed_scene := load(scene_path) as PackedScene
	if packed_scene == null or not packed_scene.can_instantiate():
		return
	var instance := packed_scene.instantiate()
	_collect_import_sources_from_node(instance, result)
	instance.free()


func _collect_import_sources_from_node(
	node: Node,
	result: PackedStringArray
) -> void:
	if node is Node3D:
		_add_import_source_if_supported((node as Node3D).scene_file_path, result)
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh != null:
			_add_import_source_if_supported(mesh.resource_path, result)
	for child in node.get_children():
		_collect_import_sources_from_node(child, result)


func _add_import_source_if_supported(
	resource_path: String,
	result: PackedStringArray
) -> void:
	if resource_path.is_empty():
		return
	var source_path := resource_path.get_slice("::", 0)
	if not AUTO_LOD_IMPORT_EXTENSIONS.has(source_path.get_extension().to_lower()):
		return
	if not FileAccess.file_exists(source_path + ".import"):
		return
	if not result.has(source_path):
		result.append(source_path)


func _on_lod_settings_changed(
	enabled: bool,
	medium_scene: PackedScene,
	distant_scene: PackedScene,
	medium_distance: float,
	distant_distance: float,
	cull_distance: float
) -> void:
	lod_enabled = enabled
	lod1_scene = medium_scene
	lod2_scene = distant_scene
	lod1_distance = maxf(medium_distance, 1.0)
	lod2_distance = maxf(
		distant_distance,
		lod1_distance + 1.0
	)
	lod_cull_distance = maxf(cull_distance, 0.0)
	_apply_lod_settings_to_existing_groups()
	_apply_auto_lod_settings_to_existing_instances()

	print(
		"World Brush: Distance LOD -> ",
		lod_enabled,
		" | ",
		lod1_distance,
		" | ",
		lod2_distance,
		" | ",
		lod_cull_distance
	)


func _apply_lod_settings_to_existing_groups() -> void:
	if selected_scene == null:
		return

	var source_path := selected_scene.resource_path
	if source_path.is_empty():
		return

	var scene_root := (
		get_editor_interface()
		.get_edited_scene_root()
	)
	if scene_root == null:
		return

	var lod1_path := (
		lod1_scene.resource_path if lod1_scene != null else ""
	)
	var lod2_path := (
		lod2_scene.resource_path if lod2_scene != null else ""
	)
	var updated := 0
	for candidate in get_tree().get_nodes_in_group(
		LOD_NODE_GROUP
	):
		if not candidate is Node3D:
			continue

		var lod_group := candidate as Node3D
		var group_source_path := str(
			lod_group.get_meta(
				&"lod_source_scene_path",
				""
			)
		)
		if group_source_path.is_empty():
			var near_level := lod_group.get_node_or_null(
				^"Near"
			) as Node3D
			if near_level != null:
				group_source_path = near_level.scene_file_path

		if group_source_path != source_path:
			continue

		var settings_changed := (
			bool(lod_group.get_meta(&"lod_enabled", true))
			!= lod_enabled
			or str(lod_group.get_meta(&"lod1_scene_path", ""))
			!= lod1_path
			or str(lod_group.get_meta(&"lod2_scene_path", ""))
			!= lod2_path
			or not is_equal_approx(
				float(lod_group.get_meta(&"lod1_distance", -1.0)),
				lod1_distance
			)
			or not is_equal_approx(
				float(lod_group.get_meta(&"lod2_distance", -1.0)),
				lod2_distance
			)
			or not is_equal_approx(
				float(lod_group.get_meta(&"lod_cull_distance", -1.0)),
				lod_cull_distance
			)
		)
		if not settings_changed:
			continue

		lod_group.set_meta(&"lod_source_scene_path", source_path)
		lod_group.set_meta(&"lod_enabled", lod_enabled)
		lod_group.set_meta(&"lod1_scene_path", lod1_path)
		lod_group.set_meta(&"lod2_scene_path", lod2_path)
		lod_group.set_meta(&"lod1_distance", lod1_distance)
		lod_group.set_meta(&"lod2_distance", lod2_distance)
		lod_group.set_meta(&"lod_cull_distance", lod_cull_distance)
		_sync_existing_lod_level(
			lod_group,
			&"Medium",
			lod1_scene if lod_enabled else null,
			scene_root
		)
		_sync_existing_lod_level(
			lod_group,
			&"Distant",
			lod2_scene if lod_enabled else null,
			scene_root
		)
		if lod_group.has_method(&"configure"):
			lod_group.call(
				&"configure",
				lod1_distance,
				lod2_distance,
				lod_cull_distance
			)
		updated += 1

	if updated <= 0:
		return

	var editor_interface := get_editor_interface()
	if editor_interface.has_method(&"mark_scene_as_unsaved"):
		editor_interface.call(&"mark_scene_as_unsaved")

	print(
		"World Brush: Updated painted LOD distances -> ",
		updated
	)


func _sync_existing_lod_level(
	lod_group: Node3D,
	level_name: StringName,
	desired_scene: PackedScene,
	scene_root: Node3D
) -> void:
	var existing := lod_group.get_node_or_null(
		NodePath(level_name)
	) as Node3D
	if desired_scene == null:
		if existing != null:
			lod_group.remove_child(existing)
			existing.free()
		return

	if (
		existing != null
		and existing.scene_file_path == desired_scene.resource_path
	):
		return

	var replacement := _instantiate_scene_root(desired_scene)
	if replacement == null:
		return

	if existing != null:
		lod_group.remove_child(existing)
		existing.free()

	replacement.name = str(level_name)
	replacement.transform = Transform3D.IDENTITY
	replacement.visible = false
	lod_group.add_child(replacement, true)
	replacement.owner = scene_root
	_disable_native_lod_ranges(replacement)

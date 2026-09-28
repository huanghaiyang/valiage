@tool
extends Node3D


@export_range(1.0, 100000.0, 1.0, "or_greater")
var medium_distance: float = 25.0

@export_range(2.0, 100000.0, 1.0, "or_greater")
var distant_distance: float = 60.0

@export_range(0.0, 100000.0, 1.0, "or_greater")
var cull_distance: float = 0.0

var _elapsed: float = 0.0
var _active_level: int = -2


func _ready() -> void:
	if Engine.is_editor_hint():
		show_editor_preview()
		set_process(false)
		return

	set_process(true)
	_update_from_camera()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.15:
		return

	_elapsed = 0.0
	_update_from_camera()


func configure(
	new_medium_distance: float,
	new_distant_distance: float,
	new_cull_distance: float
) -> void:
	medium_distance = maxf(new_medium_distance, 1.0)
	distant_distance = maxf(
		new_distant_distance,
		medium_distance + 1.0
	)
	cull_distance = maxf(new_cull_distance, 0.0)
	show_editor_preview()


func show_editor_preview() -> void:
	_active_level = -2
	_set_active_level(0)


func update_for_distance(distance: float) -> void:
	var near_level := get_node_or_null(^"Near") as Node3D
	var medium_level := get_node_or_null(^"Medium") as Node3D
	var distant_level := get_node_or_null(^"Distant") as Node3D
	var target_level := 0

	if cull_distance > 0.0 and distance >= cull_distance:
		target_level = -1
	elif distant_level != null and distance >= distant_distance:
		target_level = 2
	elif medium_level != null and distance >= medium_distance:
		target_level = 1
	elif near_level == null:
		if medium_level != null:
			target_level = 1
		elif distant_level != null:
			target_level = 2
		else:
			target_level = -1

	_set_active_level(target_level)


func _update_from_camera() -> void:
	var viewport := get_viewport()
	if viewport == null:
		return

	var camera := viewport.get_camera_3d()
	if camera == null:
		return

	update_for_distance(
		camera.global_position.distance_to(global_position)
	)


func _set_active_level(level: int) -> void:
	if bool(get_meta("harvest_hidden", false)):
		_active_level = -2
		_set_level_visible(^"Near", false)
		_set_level_visible(^"Medium", false)
		_set_level_visible(^"Distant", false)
		return

	if level == _active_level:
		return

	_active_level = level
	_set_level_visible(^"Near", level == 0)
	_set_level_visible(^"Medium", level == 1)
	_set_level_visible(^"Distant", level == 2)


func set_harvest_hidden(hidden: bool) -> void:
	set_meta("harvest_hidden", hidden)
	_active_level = -2
	if hidden:
		_set_level_visible(^"Near", false)
		_set_level_visible(^"Medium", false)
		_set_level_visible(^"Distant", false)
	else:
		_update_from_camera()


func _set_level_visible(path: NodePath, level_visible: bool) -> void:
	var level := get_node_or_null(path) as Node3D
	if level != null:
		level.visible = level_visible

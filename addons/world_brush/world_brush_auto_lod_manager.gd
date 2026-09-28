extends Node

const TARGET_REFRESH_FRAMES := 15
const MAX_CHECKS_PER_FRAME := 64

var _controllers: Array[WeakRef] = []
var _cursor := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	add_to_group(&"world_brush_auto_lod_manager")


func register_controller(controller: Node) -> void:
	if controller == null:
		return
	_controllers.append(weakref(controller))


func _process(_delta: float) -> void:
	if _controllers.is_empty():
		return
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return
	var checks := clampi(
		ceili(float(_controllers.size()) / float(TARGET_REFRESH_FRAMES)),
		1,
		MAX_CHECKS_PER_FRAME
	)
	var completed := 0
	while completed < checks and not _controllers.is_empty():
		_cursor %= _controllers.size()
		var controller := _controllers[_cursor].get_ref() as Node
		if controller == null or not controller.is_inside_tree():
			_controllers.remove_at(_cursor)
			continue
		controller.call(&"_update_runtime_distance_state", camera)
		_cursor += 1
		completed += 1

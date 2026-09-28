@tool
extends Node

@export var auto_lod_enabled := true
@export_range(0.0, 4.0, 0.05) var lod_bias := 1.0
@export_range(0.0, 100000.0, 1.0) var cull_distance := 0.0
@export var original_settings: Dictionary = {}

const REACTIVATION_RATIO := 0.9
const RUNTIME_MANAGER_SCRIPT: Script = preload(
	"res://addons/world_brush/world_brush_auto_lod_manager.gd"
)

var _runtime_states: Dictionary = {}
var _runtime_far := false
var _runtime_registered := false


func _ready() -> void:
	call_deferred("_apply_settings")
	if not Engine.is_editor_hint():
		call_deferred("_register_with_runtime_manager")


func configure(enabled: bool, detail_bias: float, hide_after: float) -> void:
	auto_lod_enabled = enabled
	lod_bias = clampf(detail_bias, 0.0, 4.0)
	cull_distance = maxf(hide_after, 0.0)
	_apply_settings()
	if not Engine.is_editor_hint() and is_inside_tree():
		_register_with_runtime_manager()


func restore_original_settings() -> void:
	_set_runtime_far(false)
	var instance_root := get_parent()
	if instance_root == null:
		return
	for raw_path in original_settings:
		var geometry := instance_root.get_node_or_null(NodePath(str(raw_path))) as GeometryInstance3D
		if geometry == null:
			continue
		var values: Dictionary = original_settings[raw_path]
		geometry.lod_bias = float(values.get("lod_bias", 1.0))
		geometry.visibility_range_end = float(values.get("visibility_range_end", 0.0))


func _register_with_runtime_manager() -> void:
	if Engine.is_editor_hint() or _runtime_registered or not is_inside_tree():
		return
	_capture_runtime_states()
	var manager := get_tree().get_first_node_in_group(
		&"world_brush_auto_lod_manager"
	)
	if manager == null:
		manager = Node.new()
		manager.name = "WorldBrushAutoLODManager"
		manager.set_script(RUNTIME_MANAGER_SCRIPT)
		var host := get_tree().current_scene
		if host == null:
			host = get_tree().root
		host.add_child(manager)
	if not manager.has_method(&"register_controller"):
		return
	manager.call(&"register_controller", self)
	_runtime_registered = true


func _update_runtime_distance_state(camera: Camera3D = null) -> void:
	if not auto_lod_enabled or cull_distance <= 0.0:
		_set_runtime_far(false)
		return
	var instance_root := get_parent() as Node3D
	if camera == null:
		camera = get_viewport().get_camera_3d()
	if instance_root == null or camera == null:
		return
	var distance_squared := instance_root.global_position.distance_squared_to(
		camera.global_position
	)
	var threshold := cull_distance
	if _runtime_far:
		threshold *= REACTIVATION_RATIO
	_set_runtime_far(distance_squared > threshold * threshold)


func _capture_runtime_states() -> void:
	if not _runtime_states.is_empty():
		return
	var instance_root := get_parent()
	if instance_root == null:
		return
	_capture_runtime_node(instance_root, instance_root)


func _capture_runtime_node(instance_root: Node, node: Node) -> void:
	if node == self:
		return
	var path := str(instance_root.get_path_to(node))
	var values := {
		"process_mode": node.process_mode,
	}
	if node is CollisionObject3D:
		values["collision_layer"] = node.collision_layer
		values["collision_mask"] = node.collision_mask
	if node is CollisionShape3D:
		values["disabled"] = node.disabled
	if node is GeometryInstance3D:
		values["visible"] = node.visible
		values["cast_shadow"] = node.cast_shadow
		values["gi_mode"] = node.gi_mode
	if node is Area3D:
		values["monitoring"] = node.monitoring
		values["monitorable"] = node.monitorable
	_runtime_states[path] = values
	for child in node.get_children():
		_capture_runtime_node(instance_root, child)


func _set_runtime_far(far: bool) -> void:
	if _runtime_far == far:
		return
	_runtime_far = far
	var instance_root := get_parent()
	if instance_root == null:
		return
	if _runtime_states.is_empty():
		_capture_runtime_states()
	for raw_path in _runtime_states:
		var node := instance_root.get_node_or_null(NodePath(str(raw_path)))
		if node == null or node == self:
			continue
		var values: Dictionary = _runtime_states[raw_path]
		# Keep the instance root alive so this controller can wake it again.
		if node != instance_root:
			node.process_mode = (
				Node.PROCESS_MODE_DISABLED
				if far
				else int(values.get("process_mode", Node.PROCESS_MODE_INHERIT))
			)
		if node is CollisionObject3D:
			node.collision_layer = 0 if far else int(values.get("collision_layer", 1))
			node.collision_mask = 0 if far else int(values.get("collision_mask", 1))
		if node is CollisionShape3D:
			node.set_deferred(
				"disabled",
				true if far else bool(values.get("disabled", false))
			)
		if node is GeometryInstance3D:
			node.visible = false if far else bool(values.get("visible", true))
			node.cast_shadow = (
				GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				if far
				else int(values.get(
					"cast_shadow",
					GeometryInstance3D.SHADOW_CASTING_SETTING_ON
				))
			)
			node.gi_mode = (
				GeometryInstance3D.GI_MODE_DISABLED
				if far
				else int(values.get(
					"gi_mode",
					GeometryInstance3D.GI_MODE_STATIC
				))
			)
		if node is Area3D:
			node.set_deferred(
				"monitoring",
				false if far else bool(values.get("monitoring", true))
			)
			node.set_deferred(
				"monitorable",
				false if far else bool(values.get("monitorable", true))
			)


func _apply_settings() -> void:
	if not auto_lod_enabled:
		restore_original_settings()
		return
	var instance_root := get_parent()
	if instance_root == null:
		return
	var geometry_instances: Array[GeometryInstance3D] = []
	_collect_geometry_instances(instance_root, geometry_instances)
	for geometry in geometry_instances:
		var geometry_path := str(instance_root.get_path_to(geometry))
		if not original_settings.has(geometry_path):
			original_settings[geometry_path] = {
				"lod_bias": geometry.lod_bias,
				"visibility_range_end": geometry.visibility_range_end,
			}
		geometry.lod_bias = lod_bias
		geometry.visibility_range_end = cull_distance


func _collect_geometry_instances(
	node: Node,
	result: Array[GeometryInstance3D]
) -> void:
	if node is GeometryInstance3D:
		result.append(node as GeometryInstance3D)
	for child in node.get_children():
		if child == self:
			continue
		_collect_geometry_instances(child, result)

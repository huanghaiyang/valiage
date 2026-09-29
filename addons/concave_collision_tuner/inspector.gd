@tool
extends EditorInspectorPlugin
## 只对"形状是 ConcavePolygonShape3D 的 CollisionShape3D"生效。

const TunerPanelScript := preload("res://addons/concave_collision_tuner/tuner_panel.gd")


func _can_handle(object: Object) -> bool:
	if not (object is CollisionShape3D):
		return false
	return (object as CollisionShape3D).shape is ConcavePolygonShape3D


func _parse_begin(object: Object) -> void:
	var panel: Control = TunerPanelScript.new()
	add_custom_control(panel)
	panel.call("setup", object as CollisionShape3D)

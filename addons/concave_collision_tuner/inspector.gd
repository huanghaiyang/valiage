@tool
extends EditorInspectorPlugin
## 对"形状是 ConcavePolygonShape3D（凹三角网）或 ConvexPolygonShape3D（凸包）的 CollisionShape3D"生效。
## 凹模式：按系数抽面重建三角网；凸模式：按系数抽面后重算**凸包**（点数可控，simplify=false 不额外削面）。

const TunerPanelScript := preload("res://addons/concave_collision_tuner/tuner_panel.gd")


func _can_handle(object: Object) -> bool:
	if not (object is CollisionShape3D):
		return false
	var sh := (object as CollisionShape3D).shape
	return sh is ConcavePolygonShape3D or sh is ConvexPolygonShape3D


func _parse_begin(object: Object) -> void:
	var panel: Control = TunerPanelScript.new()
	add_custom_control(panel)
	panel.call("setup", object as CollisionShape3D)

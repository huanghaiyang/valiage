@tool
class_name SpawnPoint
extends Marker3D
## 出生点：位置取自本节点（在场景里直接拖动即可改出生位置）
## yaw 为出生朝向（弧度，0 = 面向 -Z）；face_target 非零时朝向该点。

## 出生朝向（度）。face_target 有效时忽略本项。
## 注意：这是**角色朝向**（背对第三人称相机）；相机 yaw 由 aim_from_player() 反推。
@export_range(-180.0, 180.0, 0.1, "degrees") var yaw_degrees := 0.0

## 非零时：出生点朝向该世界坐标（原逻辑即"看向演示小屋"）
@export var face_target := Vector3.ZERO

## 出生悬空高度（米）：略高于地面，靠重力自然落位
@export var hover_height := 2.0

## 初始俯仰角（度）：负值 = 略微俯视（相机 pitch 约定，负为向下）
@export_range(-89.0, 89.0, 0.1, "degrees") var pitch_degrees := -9.4

## 取出生坐标：y = 地形高度 + hover_height
## terrain 为空时退回节点自身 y。
func resolve_position(terrain: Node = null) -> Vector3:
	var p := global_position
	if terrain != null and terrain.has_method("get_height_at"):
		var h: float = terrain.get_height_at(p.x, p.z)
		p.y = h + hover_height
	return p

## 取出生朝向 yaw（弧度）——角色朝向
func resolve_yaw() -> float:
	if face_target != Vector3.ZERO:
		var p := resolve_position()
		var d := face_target - p
		# 角色朝向约定：atan2(dx, dz)，与 face_direction 一致
		return atan2(d.x, d.z)
	return deg_to_rad(yaw_degrees)

## 取出生俯仰（弧度）
func resolve_pitch() -> float:
	return deg_to_rad(pitch_degrees)

func _get_configuration_warnings() -> PackedStringArray:
	if hover_height < 0.0:
		return PackedStringArray(["hover_height 不应为负"])
	return PackedStringArray()

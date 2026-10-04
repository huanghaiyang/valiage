@tool
class_name SpawnPoint
extends Marker3D
## 出生点：位置与朝向都取自本节点（在场景里直接拖动 / 旋转即可）。
##
## ★ 修过一个 bug：「在编辑器里转 SpawnPoint，进游戏不生效」。
##   原因是 resolve_yaw() 原来**只读 yaw_degrees 导出量，完全无视节点自身的 rotation**。
##   实测场景里节点早已转到 -128.94°，而 yaw_degrees 还是旧的 -135° —— 游戏用的是 -135°，
##   所以怎么转都没反应。
##
## 朝向约定（与 camera_rig 一致，务必别改）：
##   camera_rig 里 forward = (-sin(yaw), 0, -cos(yaw))，
##   而一个绕 Y 旋转 yaw 的 Godot 节点，其 -Z 轴恰好也是 (-sin yaw, 0, -cos yaw)。
##   所以**节点的 rotation.y 可以直接当出生 yaw 用**，无需换算、也没有正负号陷阱。

## 出生朝向来源：
##   true  = 用**本节点自身的旋转**（推荐：在编辑器里直接转 Marker3D）
##   false = 用下面的 yaw_degrees（旧场景兼容用）
@export var use_node_rotation := true

## 出生朝向（度）—— 仅当 use_node_rotation = false 时生效。
## 注意：这是**角色朝向**（背对第三人称相机）；相机 yaw 由 aim_from_player() 反推。
@export_range(-180.0, 180.0, 0.1, "degrees") var yaw_degrees := 0.0

## 非零时：朝向该世界坐标（优先级最高，盖过上面两项）
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


## 取出生朝向 yaw（弧度）—— 角色朝向
func resolve_yaw() -> float:
	if face_target != Vector3.ZERO:
		var p := resolve_position()
		var d := face_target - p
		# ★ 要让角色的 forward(-Z) 指向 d，需要 yaw = atan2(-dx, -dz)。
		#   原来写的是 atan2(dx, dz)，按本项目的 yaw 约定那正好是**反 180°**
		#   （会背对目标）。这条以前没被发现，是因为 face_target 一直是 0、分支没走过。
		return atan2(-d.x, -d.z)
	# 默认：直接拿节点自身的旋转 —— 在编辑器里转 Marker3D 就是最直觉的改朝向方式
	if use_node_rotation:
		return global_rotation.y
	return deg_to_rad(yaw_degrees)


## 取出生俯仰（弧度）
func resolve_pitch() -> float:
	return deg_to_rad(pitch_degrees)


func _get_configuration_warnings() -> PackedStringArray:
	var w := PackedStringArray()
	if hover_height < 0.0:
		w.append("hover_height 不应为负")
	# 两项都设了的时候必须说清谁赢，否则又是一个"改了没反应"的坑
	if use_node_rotation and absf(yaw_degrees) > 0.001:
		w.append("朝向取自节点旋转（use_node_rotation = true），yaw_degrees = %s 会被忽略；"
				% str(yaw_degrees) + "建议把它设为 0 以免误解")
	return w

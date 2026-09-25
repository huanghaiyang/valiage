class_name CameraRig
extends Node3D
## 第一/第三人称相机控制器（默认第三人称）
## WASD 移动 · 鼠标旋转视角 · Shift 加速跑 · Space 跳跃 · T 切换视角 · Esc 释放/捕获鼠标

@export var camera: Camera3D
@export var player: Player
@export var terrain: TerrainSystem

@export var move_speed := 5.0
@export var run_speed := 9.0
@export var jump_speed := 6.5
@export var gravity := 18.0
@export var mouse_sensitivity := 0.0028
@export var min_pitch := -1.45
@export var max_pitch := 0.4     # 限制俯视最大角度，避免镜头看到地面以下
@export var eye_height := 1.28
@export var interact_range := 18.0

# 第三人称相机参数
@export var tps_distance := 4.8
@export var tps_height := 2.0

var third_person := true
var _current_yaw := 0.0
var _current_pitch := 0.0
var _mouse_captured := true
var _velocity_y := 0.0       # 垂直速度（跳跃/重力）
var _space_prev := false     # 上一帧空格状态（防按住连跳）

func _ready() -> void:
	# 初始站在小屋旁，看向演示小屋（spawn 略高于地面，靠重力自然落位）
	player.global_position = Vector3(6.0, 2.0, 11.0)
	var look_target := Vector3(0.0, 1.0, 5.0)
	var d := look_target - player.global_position
	_current_yaw = atan2(-d.x, -d.z)
	_current_pitch = 0.22
	# 初始让角色面向看向的方向（背对第三人称相机，呈现背影）
	var fwd := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
	player.face_direction(fwd)
	_set_mouse_captured(true)

func _set_mouse_captured(captured: bool) -> void:
	_mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _mouse_captured:
		_current_yaw -= event.relative.x * mouse_sensitivity
		# 鼠标上移→抬头（pitch 减小），下移→低头（pitch 增大），并夹紧到上下限
		_current_pitch = clampf(_current_pitch + event.relative.y * mouse_sensitivity, min_pitch, max_pitch)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_set_mouse_captured(not _mouse_captured)
		elif event.keycode == KEY_T:
			third_person = not third_person

func _physics_process(delta: float) -> void:
	# WASD 水平移动：始终响应键盘（不依赖鼠标捕获）
	var moved := false
	var dir := _get_move_input()
	var move_xz := Vector3.ZERO
	if dir.x != 0.0 or dir.y != 0.0:
		moved = true
		var speed := run_speed if Input.is_key_pressed(KEY_SHIFT) else move_speed
		var forward := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
		var right := Vector3(cos(_current_yaw), 0.0, -sin(_current_yaw))
		move_xz = (forward * dir.y + right * dir.x) * speed
		# 角色面向水平移动方向
		var face := forward * dir.y + right * dir.x
		if face.length_squared() > 0.001:
			player.face_direction(face.normalized())
		# 鼠标释放时旋转视线短暂面向移动方向，便于无鼠标浏览
		if not _mouse_captured:
			_current_yaw = lerp_angle(_current_yaw, atan2(-face.x, -face.z), 8.0 * delta)

	# 重力 + 跳跃：用物理引擎 is_on_floor 判断地面
	if not player.is_on_floor():
		_velocity_y -= gravity * delta
	else:
		_velocity_y = 0.0

	var space_now := Input.is_key_pressed(KEY_SPACE)
	if space_now and not _space_prev and player.is_on_floor():
		_velocity_y = jump_speed
	_space_prev = space_now

	# 用 move_and_slide 走物理碰撞（地面/建筑/树的碰撞体生效，禁止穿入）
	player.velocity = Vector3(move_xz.x, _velocity_y, move_xz.z)
	player.move_and_slide()
	if player.is_on_floor():
		_velocity_y = 0.0

	player.set_moving(moved)

	# 相机定位 + 角色模型显隐（第一人称隐藏身体，避免相机卡进头部）
	if third_person:
		player.set_body_visible(true)
		var yaw_vec := Vector3(sin(_current_yaw), 0.0, cos(_current_yaw))
		var dist_h := cos(_current_pitch) * tps_distance
		var dist_v := sin(_current_pitch) * tps_distance
		var cam_pos := player.global_position + yaw_vec * dist_h + Vector3(0.0, tps_height + dist_v, 0.0)
		camera.global_position = cam_pos
		camera.look_at(player.global_position + Vector3(0.0, 1.05, 0.0), Vector3.UP)
	else:
		player.set_body_visible(false)
		var rot := Basis.from_euler(Vector3(_current_pitch, _current_yaw, 0.0))
		camera.global_transform = Transform3D(rot, player.global_position + Vector3(0.0, eye_height, 0.0))

## 只返回水平移动方向（x=左右，y=前后）。跳跃在 _physics_process 单独处理。
func _get_move_input() -> Vector2:
	var dir := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.y += 1.0
	if Input.is_key_pressed(KEY_S):
		dir.y -= 1.0
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		dir.x += 1.0
	return dir.normalized()

## 是否正在捕获鼠标（第一人称操作中）
func is_mouse_captured() -> bool:
	return _mouse_captured

## 获取屏幕中心射线（准星拾取）
func get_center_ray() -> Array:
	if camera == null:
		return [Vector3.ZERO, Vector3.UP]
	var center := get_viewport().get_visible_rect().size * 0.5
	var from := camera.project_ray_origin(center)
	var dir := camera.project_ray_normal(center)
	return [from, dir]

## 用准星射线求地面交点（返回 null 表示未命中或超出交互距离）
func get_ground_point_center(terrain: TerrainSystem) -> Variant:
	var result := get_center_ray()
	var from: Vector3 = result[0]
	var dir: Vector3 = result[1]
	if absf(dir.y) < 0.0001:
		return null
	var t := -from.y / dir.y
	if t < 0.0:
		return null
	var hit := from + dir * t
	if from.distance_to(hit) > interact_range:
		return null
	# 迭代修正：用地形真实高度近似地面
	for i in 3:
		var h := terrain.get_height_at(hit.x, hit.z)
		hit.y = h
	return hit
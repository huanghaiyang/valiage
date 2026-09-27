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
var interact_freeze := false    # 家具互动期间冻结角色物理驱动（位置由 player 管理）
var ui_override := false     # UI（动作菜单等）占用时让出鼠标/键盘控制

func _ready() -> void:
	# 玩家引用可能尚未注入（父节点 _ready() 晚于子节点）：先接管鼠标，
	# 角色朝向与出生点由 main.gd 在装配阶段调用 aim_from_player() 完成。
	_set_mouse_captured(true)
	if player != null:
		aim_from_player()

## 依据当前 yaw/pitch 让角色面向镜头前方（出生时呈现背影）
func aim_from_player() -> void:
	if player == null:
		return
	var fwd := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
	player.face_direction(fwd)

func _set_mouse_captured(captured: bool) -> void:
	_mouse_captured = captured
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if captured else Input.MOUSE_MODE_VISIBLE

## UI（动作菜单等）请求释放/恢复鼠标捕获
func set_ui_capture(captured: bool) -> void:
	_set_mouse_captured(captured)

func _unhandled_input(event: InputEvent) -> void:
	if ui_override:
		return
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
	# 家具互动（坐/睡/爬梯）期间：冻结移动/重力驱动，位置由 player 管理，相机仍跟随
	if interact_freeze:
		_update_camera_only()
		return
	# WASD 水平移动：始终响应键盘（不依赖鼠标捕获）
	var moved := false
	var dir := _get_move_input()
	var move_xz := Vector3.ZERO
	var running := Input.is_key_pressed(KEY_SHIFT)
	player.set_running(running)
	if dir.x != 0.0 or dir.y != 0.0:
		moved = true
		var speed := run_speed if running else move_speed
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
	# 注意：on_floor 为真时必须把垂直速度归零。旧写法保留上一帧的负值，
	# 会和贴地吸附互相拉扯，导致上坡/上台阶被"拽住"。
	if not player.is_on_floor():
		_velocity_y -= gravity * delta
	else:
		_velocity_y = 0.0

	var space_now := Input.is_key_pressed(KEY_SPACE)
	if space_now and not _space_prev and player.is_on_floor():
		_velocity_y = jump_speed
		player.on_jump()
	_space_prev = space_now

	# 用 move_and_slide 走物理碰撞（地面/建筑/树的碰撞体生效，禁止穿入）
	var was_air := not player.is_on_floor()
	player.velocity = Vector3(move_xz.x, _velocity_y, move_xz.z)
	player.move_and_slide()

	# 自动抬步：被低台阶挡住时跨上去（楼梯无需按 E；E 只留给梯子）
	if moved and move_xz.length_squared() > 0.001 and player.is_on_floor():
		if player.try_step_up(move_xz):
			_velocity_y = 0.0

	if player.is_on_floor():
		_velocity_y = 0.0
		if was_air:
			player.on_land()
	elif player.in_step_grace():
		# 抬步后短暂无接触帧：抑制重力，避免刚上踏面就被拉回
		_velocity_y = 0.0

	# 地形高度同步与防穿透
	# 1) 刷地同步：仅在刷地后短暂窗口内（0.5s），且角色位于刷地影响范围且接近地面时，
	#    高度直接跟随地形高度（网格 0.1s 先更新、碰撞 0.35s 后更新，此间隙内角色不再悬空/被埋/卡住）。
	#    窗口结束后恢复正常物理，角色可在已下陷/抬升的地形上正常跳跃。
	var th := terrain.get_height_at(player.global_position.x, player.global_position.z)
	var bc := terrain._last_brush_center
	var br := terrain._last_brush_radius
	var in_brush := false
	if bc != Vector3.ZERO and br > 0.0:
		var bdx := player.global_position.x - bc.x
		var bdz := player.global_position.z - bc.z
		in_brush = bdx * bdx + bdz * bdz < (br + 1.2) * (br + 1.2)
	if in_brush and Time.get_ticks_msec() - terrain._last_brush_time < 500 and absf(player.global_position.y - th) < 1.5:
		player.global_position.y = th + 0.05
		_velocity_y = 0.0
	elif player.global_position.y < th - 0.5:
		# 2) 深度穿透兜底：任何原因掉到地面以下都吸回地表
		player.global_position.y = th + 0.1
		_velocity_y = 0.0

	player.set_moving(moved)

	# 仰视角动态限制：角色前方地形越高，允许抬头越少（避免低处看高山时镜头看到山体内部/穿模）
	var fwd2 := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
	var ahead := player.global_position + fwd2 * 8.0
	var ahead_h := terrain.get_height_at(ahead.x, ahead.z)
	var foot_h := terrain.get_height_at(player.global_position.x, player.global_position.z)
	var rise := ahead_h - foot_h
	var min_pitch_dyn := min_pitch
	if rise > 1.0:
		min_pitch_dyn = lerpf(min_pitch, -0.08, clampf((rise - 1.0) / 6.0, 0.0, 1.0))
	_current_pitch = clampf(_current_pitch, min_pitch_dyn, max_pitch)

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
## 互动冻结期间仅更新相机（跟随玩家位置/朝向）
func _update_camera_only() -> void:
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
## 物理射线直接打地形碰撞体（层2），在深坑/陡坡等复杂地形上也能精确命中目标点，
## 不再用 y=0 平面交点 + 迭代修正（深坑里会漂移导致刷错位置，如"下陷处无法抬升"）
func get_ground_point_center(terrain: TerrainSystem) -> Variant:
	var result := get_center_ray()
	var from: Vector3 = result[0]
	var dir: Vector3 = result[1]
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * interact_range)
	query.collision_mask = 2   # 只检测地形层
	var res := space.intersect_ray(query)
	if res.is_empty():
		return null
	return res.position
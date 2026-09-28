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
## 垂直视角是否反转。默认关：鼠标上移 = 抬头。
## 不同玩家习惯差别很大，运行时按 F2 切换，也可以在检查器里改。
@export var invert_y := false
@export var min_pitch := -1.45
@export var max_pitch := 0.4     # 限制俯视最大角度，避免镜头看到地面以下
@export var eye_height := 1.28
@export var interact_range := 18.0

# 第三人称相机参数
## 第三人称机位：**整个偏移向量**（水平距离 + 高度）都按 0.5 缩了一档（用户要求"拉近 50%"）。
## 注意只改 tps_distance 是不对的：相机位置是
##   eye + yaw*(cos(pitch)*D) + up*(tps_height + sin(pitch)*D)
## 高度里那项 tps_height 是**常数**偏移，只把 D 减半会让相机相对角色抬高、
## 变成俯视头顶；两个一起缩才是"沿同一条视线拉近"。
# 再拉远 25%：2.4/1.0 -> 3.0/1.25（同样是整个偏移向量一起缩，
# 只改距离会让相机相对角色抬高、变成俯视头顶）
@export var tps_distance := 3.0
@export var tps_height := 1.25

## ---- 俯视角（暗黑破坏神 4 那种斜俯视）----
## 锁定后：鼠标不再转相机、朝向与俯角固定、相机跟着角色跑，
## 但 WASD 仍然是"按相机朝向"移动（这条别改，否则锁定后手感全乱）。
@export var iso_locked := true
@export var iso_yaw_deg := 45.0      # 斜 45 度是经典等距视角
@export var iso_pitch_deg := 52.0    # 从上往下压 52 度
@export var iso_distance := 14.0     # 默认再拉远一档（用户要求）
## 滚轮缩放：只是 iso_distance 的倍率。0.75 = 最近（当前距离的 75%），2.0 = 最远
@export var iso_zoom := 1.0
const ISO_ZOOM_MIN := 0.75
const ISO_ZOOM_MAX := 2.0
const ISO_ZOOM_STEP := 0.12
@export var iso_look_height := 1.15  # 注视点抬高 -> 角色落在画面偏下
@export var iso_fov := 45.0          # 小 FOV 减少透视畸变，更像 D4

# ---- 遮挡穿透（相机被挡住时把挡路物体淡化）----
@export var occlusion_fade := true       # 总开关
## 洞的半径 = 角色在屏幕上的高度 * 这个系数（越大抠得越多）
@export var hole_radius_scale := 1.05
@export var hole_min_radius := 0.06
@export var hole_softness := 0.035       # 洞边缘过渡宽度（UV）
@export var hole_alpha := 0.08           # 洞内保留的不透明度（0=全透，1=不淡）
@export var occlusion_probe_interval := 0.08   # 采样间隔（秒）
## 只处理这一层上的物体。这个项目里：地形=2，**建筑（树/房/墙/塔）=4**，植被=8。
## 不做过滤的话，射线平时打到地面，会把整块地形也淡化掉（实测踩过这个 Bug）。
## 地面也不需要挖洞：角色站在地上，地面本来挡不住他，挖洞反而露出天空盒。
@export_flags_3d_physics var occlusion_layer_mask := 4
## 挖洞着色器（只影响被遮挡的那一块，不是整棵变透明）
const OCCLUSION_SHADER := preload("res://scripts/shaders/occlusion_hole.gdshader")

var third_person := true
var _current_yaw := 0.0
var _current_pitch := 0.0
var _mouse_captured := true
var _velocity_y := 0.0       # 垂直速度（跳跃/重力）
var _space_prev := false     # 上一帧空格状态（防按住连跳）
var interact_freeze := false    # 家具互动期间冻结角色物理驱动（位置由 player 管理）

## 遮挡挖洞：MeshInstance3D -> 是否已装洞材质
var _occ_holes := {}
var _occ_seen := {}
var _occ_timer := 0.0
# ---- 卡墙自救 ----
## 持续想走却走不动时，侧向蹭一下绕过障碍。
## 正面顶墙时 move_and_slide 正好把速度抵消为零，玩家会完全钉在原地；
## 单靠玩家自己转向才能脱困，手感很差（试玩反馈：跑一段就推不动了）。
const STUCK_FRAMES := 12        # 连续多少物理帧没位移算被卡住（0.2s，越短越跟手）
const STUCK_EPS := 0.015        # 一帧位移小于这个值算没动
const UNSTUCK_SPEED := 4.4      # 自救侧移速度（米/秒），要接近正常步速才不拖沓
const UNSTUCK_TIME := 0.5       # 每次自救持续时长（秒）
var _stuck_frames := 0
var _unstuck_timer := 0.0
var _unstuck_side := 1.0
var _last_pos := Vector3.ZERO
var _last_move_dir := Vector3.ZERO
## 本帧 move_and_slide 撞到的墙面法线（世界空间），卡墙自救用它算切向
var _wall_normal := Vector3.ZERO
## 是否正在卡墙自救（供 UI 提示）
var unstuck_active := false
## 打印卡墙自救的诊断信息（排查用）
var stuck_debug := false
var ui_override := false     # UI（动作菜单等）占用时让出鼠标/键盘控制

func _ready() -> void:
	# 玩家引用可能尚未注入（父节点 _ready() 晚于子节点）：先接管鼠标，
	# 角色朝向与出生点由 main.gd 在装配阶段调用 aim_from_player() 完成。
	# **鼠标默认不锁定**（俯视角不需要它转相机）：锁定时鼠标转视角已经关掉了，
	# 再捕获光标只会让人没法用鼠标瞄准。放置改成"以鼠标位置为准"，见 get_ground_point_mouse()。
	_set_mouse_captured(false)
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
	if event is InputEventMouseMotion and _mouse_captured and not iso_locked:
		# 俯视角锁定：鼠标不再转相机（D4 也是完全不能转视角）
		_current_yaw -= event.relative.x * mouse_sensitivity
		# 鼠标上移→抬头（pitch 减小），下移→低头（pitch 增大），并夹紧到上下限。
		# invert_y 打开时整体反号（F2 切换）。
		var dy: float = event.relative.y * mouse_sensitivity
		if invert_y:
			dy = -dy
		_current_pitch = clampf(_current_pitch + dy, min_pitch, max_pitch)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_set_mouse_captured(not _mouse_captured)
		elif event.keycode == KEY_T:
			# 锁定俯视角时，第三人称分支永远走不到 -> T 改成切换"锁定"本身
			if iso_locked:
				iso_locked = false
				third_person = true
				camera.fov = 75.0
				print("[camera] 俯视角锁定 = 关（回到第三人称）")
			else:
				iso_locked = true
				print("[camera] 俯视角锁定 = 开（暗黑破坏神式斜俯视）")
		elif event.keycode == KEY_F2:
			invert_y = not invert_y
			print("[camera] 垂直视角反转 = %s" % str(invert_y))

## ---------------- 遮挡穿透（屏幕空间挖洞） ----------------
##
## 只把"盖住角色"的那块抠掉，模型其余部分照旧不透明 ——
## 这样既能看到角色，又不会整棵树糊成一片半透明。

## 每帧：更新角色的屏幕位置/半径（写全局 uniform）+ 定期重新采样遮挡物。
func _update_occlusion_fade(delta: float) -> void:
	if not occlusion_fade or camera == null or player == null:
		_clear_all_holes()
		return
	# --- 角色在屏幕上的位置与半径 ---
	var vp := get_viewport().get_visible_rect().size
	if vp.y < 1.0:
		return
	var base: Vector3 = player.global_position
	var p_top := camera.unproject_position(base + Vector3(0.0, 1.75, 0.0))
	var p_bot := camera.unproject_position(base)
	var h_px: float = (p_top - p_bot).length()
	var uv := Vector2(0.5, 0.5)
	var pr := camera.unproject_position(base + Vector3(0.0, 0.9, 0.0))
	if vp.x > 1.0 and vp.y > 1.0:
		uv = Vector2(pr.x / vp.x, pr.y / vp.y)
	var radius: float = maxf(hole_min_radius, (h_px / vp.y) * hole_radius_scale)
	# 这三个全局 uniform 必须先在 project.godot 的 [shader_globals] 里注册
	# （编辑器扫描着色器时会自动写进去；命令行跑就得手动加，否则这里会报
	#  "!global_shader_uniforms.variables.has(p_name)"）
	RenderingServer.global_shader_parameter_set("occ_player_uv", uv)
	RenderingServer.global_shader_parameter_set("occ_radius", radius)
	RenderingServer.global_shader_parameter_set("occ_softness", hole_softness)
	RenderingServer.global_shader_parameter_set("occ_hole_alpha", hole_alpha)

	# --- 定期重新采样 ---
	_occ_timer -= delta
	if _occ_timer <= 0.0:
		_occ_timer = occlusion_probe_interval
		_rescan_occluders()


## 找出挡住角色的建筑，给它们装"挖洞"材质；没挡住的恢复原材质。
func _rescan_occluders() -> void:
	_occ_seen.clear()
	var from: Vector3 = camera.global_position
	var base: Vector3 = player.global_position
	var probes := [base + Vector3(0.0, 1.35, 0.0),
			base + Vector3(0.0, 0.75, 0.0),
			base + Vector3(0.0, 0.15, 0.0)]
	var exclude: Array[RID] = []
	var body: Variant = player.get("body")
	if body is CollisionObject3D:
		exclude.append((body as CollisionObject3D).get_rid())
	for to in probes:
		var params := PhysicsRayQueryParameters3D.create(from, to)
		params.exclude = exclude
		params.collide_with_areas = false
		var hit := get_world_3d().direct_space_state.intersect_ray(params)
		if hit.is_empty():
			continue
		var col: Object = hit.get("collider")
		if col == null or not (col is Node):
			continue
		if col is CollisionObject3D:
			var co := col as CollisionObject3D
			if (co.collision_layer & occlusion_layer_mask) == 0:
				continue                     # 地形/植被：跳过
		var root := _occluder_root(col as Node)
		if root == null:
			continue
		for gi in _geometry_instances(root):
			if gi is MeshInstance3D:
				_occ_seen[gi] = true
				if not _occ_holes.has(gi):
					_install_hole(gi as MeshInstance3D)
	# 不再挡路的：恢复
	for gi in _occ_holes.keys():
		if not is_instance_valid(gi):
			_occ_holes.erase(gi)
			continue
		if not _occ_seen.has(gi):
			_remove_hole(gi as MeshInstance3D)


func _install_hole(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	var n := mi.mesh.get_surface_count()
	for i in n:
		var src := mi.get_active_material(i)
		var m := ShaderMaterial.new()
		m.shader = OCCLUSION_SHADER
		var tint := Color.WHITE
		if src is StandardMaterial3D:
			var std := src as StandardMaterial3D
			if std.albedo_texture != null:
				m.set_shader_parameter("albedo_tex", std.albedo_texture)
			tint = std.albedo_color
			m.set_shader_parameter("roughness", std.roughness)
			m.set_shader_parameter("metallic", std.metallic)
		else:
			# 自定义着色器材质：拿不到它的贴图，退回原材质不动（别把模型弄白）
			continue
		m.set_shader_parameter("tint", tint)
		mi.set_surface_override_material(i, m)
	_occ_holes[mi] = true


func _remove_hole(mi: MeshInstance3D) -> void:
	if not is_instance_valid(mi) or mi.mesh == null:
		_occ_holes.erase(mi)
		return
	for i in mi.mesh.get_surface_count():
		mi.set_surface_override_material(i, null)
	_occ_holes.erase(mi)


func _clear_all_holes() -> void:
	for gi in _occ_holes.keys():
		if is_instance_valid(gi):
			_remove_hole(gi as MeshInstance3D)
	_occ_holes.clear()
	_occ_seen.clear()


## 射线打到的是碰撞体（挂在模型实例下面的子节点），往上找到"那一个被放置的物体"。
func _occluder_root(n: Node) -> Node3D:
	var cur: Node = n
	var depth := 0
	while cur != null and depth < 4:
		var p := cur.get_parent()
		if p == null or p == get_tree().current_scene:
			return null
		if not (cur is Node3D):
			return null
		if _has_geometry(cur):
			return cur as Node3D
		cur = p
		depth += 1
	return null


func _has_geometry(n: Node) -> bool:
	if n is GeometryInstance3D:
		return true
	for c in n.get_children():
		if c is GeometryInstance3D:
			return true
	return false


func _geometry_instances(root: Node3D) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GeometryInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _physics_process(delta: float) -> void:
	_update_occlusion_fade(delta)
	if iso_locked:
		# 每帧强制写回固定朝向与俯角：下面还有"爬坡时动态夹紧俯角"
		# 和"鼠标没捕获时朝向跟移动方向"两段逻辑，都会把这个值改掉。
		_current_yaw = deg_to_rad(iso_yaw_deg)
		_current_pitch = -deg_to_rad(iso_pitch_deg)
	# 家具互动（坐/睡/爬梯）期间：冻结移动/重力驱动，位置由 player 管理，相机仍跟随
	if interact_freeze:
		_update_camera_only()
		return
	# WASD 水平移动：始终响应键盘（不依赖鼠标捕获）
	var moved := false
	var dir := _get_move_input()
	var move_xz := Vector3.ZERO
	var running := Input.is_key_pressed(KEY_SHIFT)
	if _last_pos == Vector3.ZERO:
		_last_pos = player.global_position
	var yaw_before: float = player.get_facing_yaw()
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
	# 记录本帧墙面法线：卡墙自救要用它算切向（见 _wall_slide_dir）
	_wall_normal = Vector3.ZERO
	for ci in player.get_slide_collision_count():
		var c := player.get_slide_collision(ci)
		var nrm := c.get_normal()
		# 只关心接近竖直的墙（地面法线朝上，不算卡墙）
		if absf(nrm.y) < 0.6:
			_wall_normal = Vector3(nrm.x, 0.0, nrm.z).normalized()
			break

	# 自动抬步：被低台阶挡住时跨上去（楼梯无需按 E；E 只留给梯子）
	if moved and move_xz.length_squared() > 0.001 and player.is_on_floor():
		if player.try_step_up(move_xz):
			_velocity_y = 0.0

	# 卡墙自救：想走却完全没位移时侧向蹭出去（见 STUCK_* 常量注释）
	_update_stuck(delta, moved, move_xz)

	# 转向过渡：侧向速度 → 侧移动画；朝向突变 → 转向动画 + 压弯
	var yaw_after: float = player.get_facing_yaw()
	player.notify_facing_change(angle_difference(yaw_before, yaw_after))
	player.set_lateral(_lateral_speed(move_xz, yaw_after))
	player.update_turn(delta, moved, running)

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
	if not iso_locked:
		_current_pitch = clampf(_current_pitch, min_pitch_dyn, max_pitch)

	# 相机定位 + 角色模型显隐（第一人称隐藏身体，避免相机卡进头部）
	# 相机跟 visual_height()：抬步时根部瞬间上到台阶顶、模型缓动追上去，
	# 若跟根节点，上台阶瞬间镜头会先猛跳一下再被模型追平。
	var eye_y := player.visual_height()
	var focus := Vector3(player.global_position.x, eye_y, player.global_position.z)
	if iso_locked:
		player.set_body_visible(true)
		_place_iso_camera(focus)
	elif third_person:
		player.set_body_visible(true)
		var yaw_vec := Vector3(sin(_current_yaw), 0.0, cos(_current_yaw))
		var dist_h := cos(_current_pitch) * tps_distance
		var dist_v := sin(_current_pitch) * tps_distance
		var cam_pos := Vector3(player.global_position.x, eye_y, player.global_position.z) + yaw_vec * dist_h + Vector3(0.0, tps_height + dist_v, 0.0)
		camera.global_position = cam_pos
		camera.look_at(Vector3(player.global_position.x, eye_y + 1.05, player.global_position.z), Vector3.UP)
	else:
		player.set_body_visible(false)
		var rot := Basis.from_euler(Vector3(_current_pitch, _current_yaw, 0.0))
		camera.global_transform = Transform3D(rot, Vector3(player.global_position.x, eye_y + eye_height, player.global_position.z))

## 俯视角机位：从 focus 正上方偏后按固定角度摆相机（暗黑破坏神 4 那种）。
## 与第三人称的区别是"完全不吃鼠标输入"，朝向/俯角/距离都是常量。
func _place_iso_camera(focus: Vector3) -> void:
	var y := deg_to_rad(iso_yaw_deg)
	var p := deg_to_rad(iso_pitch_deg)
	var d := iso_distance * iso_zoom
	var horiz := d * cos(p)                 # 水平后退距离
	var vert := d * sin(p)                  # 抬高量
	camera.global_position = focus + Vector3(sin(y) * horiz, vert, cos(y) * horiz)
	camera.look_at(focus + Vector3(0.0, iso_look_height, 0.0), Vector3.UP)
	if not is_equal_approx(camera.fov, iso_fov):
		camera.fov = iso_fov


## 滚轮缩放（未选任何放置工具时）：dir=+1 拉远、-1 拉近。
## 返回 true 表示这次滚轮被缩放吃掉了。
func zoom_by(dir: int) -> bool:
	var before := iso_zoom
	iso_zoom = clampf(iso_zoom + dir * ISO_ZOOM_STEP, ISO_ZOOM_MIN, ISO_ZOOM_MAX)
	return not is_equal_approx(before, iso_zoom)


## 只返回水平移动方向（x=左右，y=前后）。跳跃在 _physics_process 单独处理。
## 互动冻结期间仅更新相机（跟随玩家位置/朝向）
func _update_camera_only() -> void:
	if iso_locked:
		player.set_body_visible(true)
		_place_iso_camera(Vector3(player.global_position.x, player.visual_height(),
				player.global_position.z))
		return
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

## 朝向坐标系下的侧向速度分量（右为正）：用于选择侧移动画与压弯方向
func _lateral_speed(move_xz: Vector3, facing_yaw: float) -> float:
	if move_xz.length_squared() < 0.0001:
		return 0.0
	var right := Vector3(cos(facing_yaw), 0.0, -sin(facing_yaw))
	return move_xz.dot(right)


## 自动化测试用：非零时替代键盘输入（headless 探测无法模拟按键）
var test_move_override := Vector2.ZERO


## 检测想走但走不动，并给一个持续 0.55s 的侧向速度把玩家从墙上蹭开。
## 侧向正负按卡住前一瞬间的移动方向取，保证是绕过障碍而不是原地抖。
func _update_stuck(delta: float, moved: bool, move_xz: Vector3) -> void:
	var p := player.global_position
	var step := Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
	_last_pos = p
	if move_xz.length_squared() > 0.001:
		_last_move_dir = move_xz.normalized()
	if not moved:
		_stuck_frames = 0
		_unstuck_timer = 0.0
		unstuck_active = false
		return
	if _unstuck_timer > 0.0:
		_unstuck_timer = maxf(0.0, _unstuck_timer - delta)
		if _unstuck_timer <= 0.0:
			unstuck_active = false
	if step < STUCK_EPS and moved:
		_stuck_frames += 1
	else:
		_stuck_frames = 0
		# 已经能动就把自救窗口收掉，避免持续被推着走
		_unstuck_timer = 0.0
		unstuck_active = false
	if _unstuck_timer > 0.0:
		# 自救：找一个**站得下的落点**直接瞬移过去。
		#
		# 试过两版都是错的：
		#   1. 沿墙切向推 —— 卡进楔形缝隙时相邻两帧拿到法线相反的墙，切向抵消，
		#      位置在 0.001m 内反复横跳，表现为完全冻结；
		#   2. 检查 p+dir*0.55 是否干净 —— 通过也不代表能走：胶囊此刻可能仍嵌在
		#      碰撞体里，move_and_slide 会把整帧速度吃掉，人还是不动。
		# 所以这里由近及远做环状搜索，找到一个真正干净的落点就瞬移过去。
		var escape: Variant = _find_free_spot(p)
		if escape != null:
			player.global_position = escape
	elif _stuck_frames >= STUCK_FRAMES:
		_stuck_frames = 0
		_unstuck_timer = UNSTUCK_TIME
		unstuck_active = true
		if stuck_debug:
			print("[stuck] 卡住 pos=%s normal=%s move=%s air=%s floor=%s" % [str(p), str(_wall_normal), str(_last_move_dir), str(player._jump_air), str(player.is_on_floor())])


## 由近及远环状搜索一个"胶囊放得下"的落点；找不到返回 null。
##
## 半径从 0.9m 递到 4.2m，方向先试墙面切向/侧后方，再绕整圈。
## 找到就返回该点，调用方直接瞬移 —— 这样无论卡在多窄的缝隙里都能出来。
func _find_free_spot(p: Vector3) -> Variant:
	var space := player.get_world_3d().direct_space_state
	var pref := _wall_slide_dir()
	if pref == Vector3.ZERO:
		pref = Vector3(-_last_move_dir.z, 0.0, _last_move_dir.x)
	if pref == Vector3.ZERO:
		pref = Vector3.RIGHT
	# 候选方向：优先与 preferred 同向的（沿墙滑更像是"绕过去"而不是"弹开"）
	var dirs: Array = []
	for step in 16:
		var ang := TAU * float(step) / 16.0
		var d := Vector3(cos(ang), 0.0, sin(ang))
		if d.dot(pref) > 0.35:
			dirs.append(d)
	for step in 16:
		var ang2 := TAU * float(step) / 16.0
		var d2 := Vector3(cos(ang2), 0.0, sin(ang2))
		if d2.dot(pref) <= 0.35:
			dirs.append(d2)
	for radius in [0.9, 1.4, 2.0, 2.8, 3.6, 4.4]:
		for d in dirs:
			var cand: Vector3 = p + (d as Vector3) * radius
			if _spot_is_free(space, cand):
				return cand
	return null


## 该位置站得住吗（用略瘦的胶囊做形状查询；只查水平位移后的落点）
func _spot_is_free(space: PhysicsDirectSpaceState3D, at: Vector3) -> bool:
	var shape := CapsuleShape3D.new()
	if player != null:
		shape.radius = player.COLLIDER_RADIUS * 0.8
		shape.height = maxf(shape.radius * 2.0 + 0.05, player.COLLIDER_HEIGHT * 0.8)
	else:
		shape.radius = 0.22
		shape.height = 0.9
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = shape
	q.collision_mask = 2 | 4 | 8
	q.transform = Transform3D(Basis.IDENTITY, at + Vector3(0.0, shape.height * 0.5, 0.0))
	if player != null:
		q.exclude = [player.get_rid()]
	return space.intersect_shape(q, 1).is_empty()


## 从本帧 move_and_slide 记录的墙面法线里推出一个顺墙方向。
## 取与当前移动方向夹角更小的一侧，也就是障碍物更靠边的那一侧。
func _wall_slide_dir() -> Vector3:
	if _wall_normal == Vector3.ZERO or _last_move_dir == Vector3.ZERO:
		return Vector3.ZERO
	var tangent := Vector3(-_wall_normal.z, 0.0, _wall_normal.x).normalized()
	if tangent.dot(_last_move_dir) < 0.0:
		tangent = -tangent
	return tangent


func _get_move_input() -> Vector2:
	if test_move_override != Vector2.ZERO:
		return test_move_override.normalized()
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

## 鼠标位置的地面落点（俯视角下用它代替"屏幕中心准星"）。
## 与 get_ground_point_center 同一套逻辑，只是射线从鼠标位置发出。
func get_ground_point_mouse(terrain: TerrainSystem) -> Variant:
	if camera == null:
		return null
	var mpos := get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mpos)
	var dir := camera.project_ray_normal(mpos)
	var near := _cast_ground(from, dir, interact_range)
	if not near.is_empty():
		return _clamp_place_point(near.position, terrain)
	var far := _cast_ground(from, dir, GROUND_RAY_MAX)
	if not far.is_empty():
		return _clamp_place_point(far.position, terrain)
	return null


## 准星落地射线的探测距离上限。
## 第三人称相机在角色后上方（+2.0m 高、-9.4 度俯角），准星射线每前进 1m 只下降 0.036m，
## 要落回地面需要走约 45m —— 而交互距离只有 18m，于是默认视角下准星**永远打不到地面**，
## 树木/花草/家具/山体这些需要地面点的工具全部放不下去（试玩实测：点左键毫无反应）。
## 所以先按交互距离探测，没命中再用这个上限补一次。
const GROUND_RAY_MAX := 260.0
## 放置点离角色的最大水平距离。第三人称相机加缓俯角会让射线落到 25m 外，
## 那个距离放东西等于往天边扔，所以超出就沿射线拉回来重新贴回地面。
const PLACE_MAX_DIST := 9.0


## 用准星射线求地面交点（返回 null 表示没命中地形）
## 物理射线直接打地形碰撞体（层2），在深坑/陡坡等复杂地形上也能精确命中目标点，
## 不再用 y=0 平面交点 + 迭代修正（深坑里会漂移导致刷错位置，如下陷处无法抬升）
func get_ground_point_center(terrain: TerrainSystem) -> Variant:
	var r := get_center_ray()
	var from: Vector3 = r[0]
	var dir: Vector3 = r[1]
	var near := _cast_ground(from, dir, interact_range)
	if not near.is_empty():
		return _clamp_place_point(near.position, terrain)
	var far := _cast_ground(from, dir, GROUND_RAY_MAX)
	if not far.is_empty():
		return _clamp_place_point(far.position, terrain)
	return null


## 把过远的放置点沿 角色到目标 方向拉近到 PLACE_MAX_DIST，并重新贴回地表
func _clamp_place_point(target: Vector3, terrain: TerrainSystem) -> Vector3:
	if player == null or terrain == null:
		return target
	var base := player.global_position
	var flat := Vector3(target.x - base.x, 0.0, target.z - base.z)
	var dist := flat.length()
	if dist <= PLACE_MAX_DIST or dist < 0.001:
		return target
	var pulled := base + flat / dist * PLACE_MAX_DIST
	return Vector3(pulled.x, terrain.get_height_at(pulled.x, pulled.z), pulled.z)


func _cast_ground(from: Vector3, dir: Vector3, length: float) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * length)
	query.collision_mask = 2   # 只检测地形层
	return space.intersect_ray(query)
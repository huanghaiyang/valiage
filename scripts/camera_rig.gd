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
## 坡度速度规则（只影响"平常走路/跑步"的水平速度）：
##   上坡减速、下坡加速，两者都按坡度角线性过渡，并被下面两个比例**钳住**。
## 两个限制都是"相对当前基础速度"的比例 —— 基础速度已经含 Shift 跑步，
## 所以走路(5)与跑步(9)各自按同一比例受限，不需要为跑步再写一套。
## slope_speed_angle 设为 0 或负数 = 关闭整条规则。
@export var slope_speed_angle := 40.0
@export var slope_speed_min_ratio := 0.45   ## 上坡最低速度比例（走路 5→2.25，跑步 9→4.05）
@export var slope_speed_max_ratio := 1.25   ## 下坡最高速度比例（走路 5→6.25，跑步 9→11.25）
## 裂缝/窄坑守卫：角色走进窄缝会扎进地形，move_and_slide 去穿插时会把它"瞬间弹走"。
## 所以在缝边就拦住：向前探一步，若前方地面下沉、而对面在 crack_max_width 内又回到脚面高度，
## 判定为"缝"（不是悬崖），本帧不允许朝这个方向移动。
@export var crack_guard := true
@export var crack_probe_ahead := 0.55      ## 向前探多远（约半个身位）
@export var crack_max_drop := 0.45         ## 下沉超过这个深度才算"前方是坑"
@export var crack_max_width := 1.6         ## 对面在这么远内重新升高 → 是缝而非悬崖
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
## 相机俯角。**52° 太陡**：那个角度基本在俯视头顶，角色的侧身/轮廓看不见
## （用户反馈"只能看到角色头部"）。42° 保留斜俯视观感，同时能看到身体侧面。
@export var iso_pitch_deg := 42.0
## 到角色的距离。14m 时角色只占屏幕高度约 10%（720p 下实测 ~74px），
## 那个尺寸下只能辨认出头顶的帽子。12m 放大 17%；再把俯角从 52° 降到 42°
## （角色竖直方向的投影系数 cos42°/cos52° ≈ 1.21），屏幕上高度约 74px → 104px。
## 滚轮仍可在 75%~200% 之间缩放（0.75 时约 9m）。
@export var iso_distance := 12.0
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
## 候选物体名单的重建间隔（秒）。树/房子会被笔刷不断增删，定期重扫一遍最简单。
@export var occlusion_candidate_interval := 1.0
## 只考虑离角色这么近的候选（米）。更远的树不可能挡住近在眼前的角色。
@export var occlusion_candidate_range := 40.0
## 挡路判定用**物理射线打真实碰撞体**，而不是包围盒。
## 包围盒分不清"树干在旁边"和"树叶真的挡在前面"：树冠的盒子有 4.6×10.7×4.3m，
## 角色一走进盒子范围（离树 2~3m）线段就已经穿过盒子，于是被判成"被挡住"
## （用户反馈："人物一靠近物体，物体就会被挖洞"）。
## 只有这一层上的碰撞体算遮挡物。本项目：地形=2，**建筑/树=4**，植被=8。
@export_flags_3d_physics var occlusion_layer_mask := 4
## 单条采样线最多穿透几层遮挡物（密林里相机到角色之间可能叠着好几棵）。
@export var occlusion_max_hits := 8
## 放进这个组的节点（含子树）永不挖洞，给"不想被透视"的物件留后门。
const OCCLUSION_IGNORE_GROUP := &"occlusion_ignore"
## 挖洞着色器（只影响被遮挡的那一块，不是整棵变透明）
const OCCLUSION_SHADER := preload("res://scripts/shaders/occlusion_hole.gdshader")

var third_person := true
var _current_yaw := 0.0
var _current_pitch := 0.0
var _mouse_captured := true
var _velocity_y := 0.0       # 垂直速度（跳跃/重力）
# ★ 平滑后的地面法线（"法线中值"）：修掉三角网逐面法线跳变导致的抖动/被弹开
var _ground_up := Vector3.UP
var _ground_ready := false
const GROUND_SMOOTH_RATE := 14.0    # 时域平滑速率（越大跟得越快）
var _space_prev := false     # 上一帧空格状态（防按住连跳）
var interact_freeze := false    # 家具互动期间冻结角色物理驱动（位置由 player 管理）

## 遮挡挖洞：MeshInstance3D -> 是否已装洞材质
var _occ_holes := {}
var _occ_seen := {}
## MeshInstance3D -> 烘好的挖洞材质（按 surface 下标）。
## 挖洞是"命中就装、离开就卸"，树一多会每 0.08s 反复 new/丢 ShaderMaterial；
## 缓存下来只切换 override，省掉分配与材质重建的抖动。
var _occ_mat_cache := {}
## 可能挡住角色的网格（场景里的 MeshInstance3D，排除角色自身），定期重建
var _occ_candidates: Array = []
## 上面这些网格里哪些**有碰撞体**（MeshInstance3D -> true）。
## 有碰撞体的走物理射线精确判定；没有的（编辑器里手摆的模型）才退回包围盒兜底。
var _occ_backed := {}
var _occ_cand_timer := 0.0
var _occ_timer := 0.0
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

	# --- 定期重建候选名单 + 重新采样 ---
	_occ_cand_timer -= delta
	if _occ_cand_timer <= 0.0 or _occ_candidates.is_empty():
		_occ_cand_timer = occlusion_candidate_interval
		_collect_occlusion_candidates()
	_occ_timer -= delta
	if _occ_timer <= 0.0:
		_occ_timer = occlusion_probe_interval
		_rescan_occluders()


## 重建"可能挡住角色"的候选网格名单。
##
## **为什么不再用物理射线找遮挡物**：射线只能回答"这条线上最近的是谁"。
## 实测：屏幕上包围盒盖住角色的树有 19 棵，射线方案只挖到 4 棵 —— 就是反馈的
## "遮挡角色的树木过多，还是看不到角色"。屏幕空间判定问的是"这块网格在屏幕上
## 盖不盖住角色"，几十棵叠在一起也能一次全挖掉。
## 附带好处：不再要求物体有碰撞体、也不用管碰撞层，编辑器里手摆的模型照样生效。
func _collect_occlusion_candidates() -> void:
	_occ_candidates.clear()
	_occ_backed.clear()
	var scene := get_tree().current_scene
	if scene == null:
		return
	_collect_candidates_under(scene, player as Node)


func _collect_candidates_under(n: Node, player_node: Node) -> void:
	for c in n.get_children():
		if c == player_node:
			continue                       # 角色自己的模型：挖自己的洞就成透明的了
		if c.is_in_group(OCCLUSION_IGNORE_GROUP):
			continue                       # 留后门：这棵子树永不挖洞
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			if mi.mesh != null:
				_occ_candidates.append(mi)
				_occ_backed[mi] = _mesh_has_collider(mi)
		_collect_candidates_under(c, player_node)


## 网格是否"有碰撞体"：自己、子孙、或往上 3 层内出现 CollisionObject3D。
## 有碰撞体的走物理射线（贴着模型，精确）；没有的才退回包围盒兜底。
func _mesh_has_collider(mi: MeshInstance3D) -> bool:
	var cur: Node = mi
	var depth := 0
	while cur != null and depth < 3:
		if cur is CollisionObject3D:
			return true
		for c in cur.get_children():
			if c is CollisionObject3D:
				return true
		cur = cur.get_parent()
		depth += 1
	return false


## 角色身上用于"是否被挡"判定的采样点（世界空间）：头 / 胸 / 胯 + 左右肩。
## 用多个点是为了覆盖轮廓：只打中线的话，从侧后方斜着盖住半个身子的树冠会被漏掉
## （那是"树木过多还是看不到角色"的老问题）。
func _char_sample_points() -> Array:
	var base: Vector3 = player.global_position
	var right: Vector3 = camera.global_transform.basis.x
	var chest := base + Vector3(0.0, 1.0, 0.0)
	return [base + Vector3(0.0, 1.7, 0.0),
			chest,
			base + Vector3(0.0, 0.25, 0.0),
			chest + right * 0.35,
			chest - right * 0.35]


## 每轮：找出真正挡在"相机 → 角色"之间的物体，给它们的网格挖洞。
##
## **判定用物理射线打真实碰撞体**，不用包围盒。包围盒分不清"树干在旁边"和
## "树叶真的挡在前面"：树冠的盒子有 4.6×10.7×4.3m，角色只要走进盒子范围
## （离树 2~3m），"相机→角色"的线段就已经从盒子空着的上半部分穿过去了，
## 于是被判成"被挡住" —— 表现就是"人物一靠近物体，物体就被挖洞"（用户反馈）。
## 碰撞体是贴着模型的（秋树笔刷场景用的就是模型的三角网），射线打上去才知道真假。
##
## 每条采样线**一路打穿**：`intersect_ray` 只返回最近的一个碰撞体，密林里
## 相机到角色之间叠着好几棵，只挖最近那棵的话，透过洞看到的还是第二棵完整的树
## （老反馈："树木过多还是看不到角色"）。
func _rescan_occluders() -> void:
	_occ_seen.clear()
	if camera == null or player == null:
		return
	var base: Vector3 = player.global_position
	var cam_pos: Vector3 = camera.global_position
	var samples := _char_sample_points()
	var space := get_world_3d().direct_space_state
	# 角色自己的碰撞体永远排除：否则射线停在角色身上，后面的树一棵都查不到
	var player_rid := RID()
	var body: Variant = player.get("body")
	if body is CollisionObject3D:
		player_rid = (body as CollisionObject3D).get_rid()
	# ---- ① 物理射线（贴着真实模型，精确）----
	for sp in samples:
		var to: Vector3 = sp
		var from: Vector3 = cam_pos
		var dir: Vector3 = to - from
		if dir.length_squared() < 0.0001:
			continue
		dir = dir.normalized()
		var exclude: Array[RID] = []
		if player_rid.is_valid():
			exclude.append(player_rid)
		for _i in occlusion_max_hits:
			var params := PhysicsRayQueryParameters3D.create(from, to)
			params.exclude = exclude
			params.collide_with_areas = false
			params.collision_mask = occlusion_layer_mask
			var hit := space.intersect_ray(params)
			if hit.is_empty():
				break
			var col: Object = hit.get("collider")
			if col is CollisionObject3D:
				# 已命中的物体排除掉，否则下一轮打到的还是它
				exclude.append((col as CollisionObject3D).get_rid())
			from = (hit.get("position", from) as Vector3) + dir * 0.05
			if from.distance_squared_to(to) < 0.01:
				break                      # 已经贴到采样点，别再往回打
			if col == null or not (col is Node):
				continue
			var root := _occluder_root(col as Node)
			if root == null:
				continue
			for gi in _geometry_instances(root):
				if gi is MeshInstance3D:
					_occ_seen[gi] = true
					if not _occ_holes.has(gi):
						_install_hole(gi as MeshInstance3D)
	# ---- ② 没有碰撞体的物件（编辑器里手摆的模型）：才退回包围盒兜底 ----
	# **但要求角色在它包围盒之外** —— 否则"人走进树冠盒子就挖洞"的误判又回来了。
	# 宁可漏挖这类物件，也不要一靠近就乱挖。
	var range_sq := occlusion_candidate_range * occlusion_candidate_range
	for c in _occ_candidates:
		# 先判存活再转换：候选可能已被释放（例如卡位监测的标记会自行回收），
		# 对已释放对象做 as 转换会报 "Trying to cast a freed object"。
		if not is_instance_valid(c):
			continue
		var mi := c as MeshInstance3D
		if mi == null:
			continue
		if _occ_backed.has(mi):
			continue                       # 有碰撞体：上面射线已经处理过
		if not is_instance_valid(mi) or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		if mi.global_position.distance_squared_to(base) > range_sq:
			continue
		var ab_world: AABB = mi.global_transform * mi.mesh.get_aabb()
		if ab_world.has_point(base):
			continue                       # 角色就在盒子里，分不清 -> 不挖
		var blocks := false
		for sp in samples:
			var pt: Vector3 = sp
			# 4.7 的 intersects_segment 返回交点 Vector3 或 null（不是 bool），按类型判断
			var hit: Variant = ab_world.intersects_segment(cam_pos, pt)
			if typeof(hit) == TYPE_VECTOR3 or (typeof(hit) == TYPE_BOOL and bool(hit)):
				blocks = true
				break
		if not blocks:
			continue
		_occ_seen[mi] = true
		if not _occ_holes.has(mi):
			_install_hole(mi)
	# 不再挡路的：恢复
	for gi in _occ_holes.keys():
		if not is_instance_valid(gi):
			_occ_holes.erase(gi)
			_occ_mat_cache.erase(gi)
			continue
		if not _occ_seen.has(gi):
			_remove_hole(gi as MeshInstance3D)


## 射线打到的是碰撞体（通常挂在模型实例下面），往上找到"那一个被放置的物体"。
## **先看自己有没有几何体、再看父节点**：上一版先判 `父 == 场景根` 就 return，
## 结果"直接挂在场景根下的手摆物体"永远找不到（早期 Bug）。
func _occluder_root(n: Node) -> Node3D:
	var cur: Node = n
	var depth := 0
	var scene := get_tree().current_scene
	while cur != null and depth < 6:
		if cur == scene:
			return null                   # 兜底：别把整个场景当成一个物体
		if cur is Node3D and _has_geometry(cur):
			return cur as Node3D
		cur = cur.get_parent()
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


## 装洞：优先复用缓存材质，只切 override（树木多时别再每轮重新 new 一遍）
func _install_hole(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	var n := mi.mesh.get_surface_count()
	var mats: Array = _occ_mat_cache.get(mi, [])
	if mats.size() != n:
		mats = _build_hole_materials(mi, n)
		_occ_mat_cache[mi] = mats
	for i in n:
		if mats[i] != null:
			mi.set_surface_override_material(i, mats[i])
	_occ_holes[mi] = true


## 按原材质烘出每个 surface 的挖洞材质；拿不到原材质的 surface 记 null（保持原样）
func _build_hole_materials(mi: MeshInstance3D, n: int) -> Array:
	var out: Array = []
	out.resize(n)
	for i in n:
		var src := mi.get_active_material(i)
		if not (src is StandardMaterial3D):
			# 自定义着色器材质：拿不到它的贴图，退回原材质不动（别把模型弄白）
			out[i] = null
			continue
		var std := src as StandardMaterial3D
		var m := ShaderMaterial.new()
		m.shader = OCCLUSION_SHADER
		if std.albedo_texture != null:
			m.set_shader_parameter("albedo_tex", std.albedo_texture)
		m.set_shader_parameter("roughness", std.roughness)
		m.set_shader_parameter("metallic", std.metallic)
		# 这三样以前漏了，才导致"被挖洞的物体贴图变了"
		m.set_shader_parameter("uv_scale_offset",
				Vector4(std.uv1_scale.x, std.uv1_scale.y,
						std.uv1_offset.x, std.uv1_offset.y))
		m.set_shader_parameter("use_vertex_color", std.vertex_color_use_as_albedo)
		if std.normal_enabled and std.normal_texture != null:
			m.set_shader_parameter("normal_tex", std.normal_texture)
			m.set_shader_parameter("normal_strength", std.normal_scale)
			m.set_shader_parameter("use_normal_map", true)
		m.set_shader_parameter("tint", std.albedo_color)
		out[i] = m
	return out


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
		else:
			_occ_mat_cache.erase(gi)
	_occ_holes.clear()
	_occ_seen.clear()
	_occ_mat_cache.clear()


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
	var yaw_before: float = player.get_facing_yaw()
	player.set_running(running)
	if dir.x != 0.0 or dir.y != 0.0:
		moved = true
		var forward := Vector3(-sin(_current_yaw), 0.0, -cos(_current_yaw))
		var right := Vector3(cos(_current_yaw), 0.0, -sin(_current_yaw))
		var face := forward * dir.y + right * dir.x
		var base_speed := run_speed if running else move_speed
		# 上坡减速、下坡加速、限制在 min/max 比例内。地形和物体模型的坡面走的是同一套
		# floor_normal，所以"在物体上移动"自动同样生效。
		# ★ 用**平滑后**的地面法线（逐面法线会跳变 -> 速度因子每帧抖）
		var factor := slope_speed_factor(_ground_up if _ground_ready else player.get_floor_normal(), face.normalized(), player.is_on_floor())
		move_xz = face * base_speed * factor
		# 裂缝守卫：前方是窄缝时本帧停下（否则会扎进地形、被去穿插弹飞）
		if player.is_on_floor() and face.length_squared() > 0.001:
			if crack_ahead(get_world_3d().direct_space_state, player.global_position, face.normalized()):
				move_xz = Vector3.ZERO
		# 角色面向水平移动方向
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

	# ★ 先把水平移动按**平滑地面**投影一次，并把投影得到的 y 分量带上：
	#   旧写法 velocity.y 只放 _velocity_y，等于"水平向量是平的"，
	#   引擎只能每帧拿逐三角法线去重新投影 -> 三角网地形上必然抖动/被弹开。
	if player.is_on_floor() and _ground_ready:
		var before_proj := move_xz
		move_xz = move_xz.slide(_ground_up)
		if move_xz.length_squared() < 0.0001:
			move_xz = before_proj            # 兜底：别把移动整帧吃掉
	# 用 move_and_slide 走物理碰撞（地面/建筑/树的碰撞体生效，禁止穿入）
	var was_air := not player.is_on_floor()
	player.velocity = Vector3(move_xz.x, move_xz.y + _velocity_y, move_xz.z)
	player.move_and_slide()
	# ★ 采样并平滑地面法线（要在 move_and_slide 之后，is_on_floor 才是本帧结果）
	update_ground_up(delta)

	# ★ 脚底灰尘：用 move_and_slide **之后**的真实水平速度驱动
	#   （撞墙/上坡/被挡时真实速度会掉下来 -> 灰尘自然变小，不用额外判断）
	var hv := Vector2(player.velocity.x, player.velocity.z).length()
	var dust_ratio := 0.0
	if player.is_on_floor() and hv > player.DUST_SPEED_MIN:
		dust_ratio = clampf((hv - player.DUST_SPEED_MIN) / maxf(0.001, run_speed - player.DUST_SPEED_MIN), 0.0, 1.0)
		dust_ratio = pow(dust_ratio, 1.3)     # 起步轻、跑起来明显
	player.update_dust(dust_ratio)

	# 自动抬步：被低台阶/小突起挡住时跨上去（楼梯无需按 E；E 只留给梯子）
	# ★ 门槛放宽：原来只在 is_on_floor 时尝试，而顶在小突起上时 is_on_floor 往往已为假
	#   -> 抬步根本不触发 -> 卡死。现在"被挡住且不在上升"也允许尝试。
	var blocked_now := player.get_slide_collision_count() > 0
	if moved and move_xz.length_squared() > 0.001 and (player.is_on_floor() or (blocked_now and _velocity_y <= 0.0)):
		if player.try_step_up(move_xz):
			_velocity_y = 0.0

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
	# **Terrain3D 接管时整段跳过**：地形碰撞由 Terrain3D 自己提供，
	# 再用 get_height_at() 去"吸回地表"会和 move_and_slide 打架 ——
	# 高度图值与碰撞面在坡地上有出入，于是"瞬移上去 -> 物理落回"反复发生，
	# 表现就是角色在非平坦地面上**上下抖动**（用户报的 bug）。
	# 老的刷地同步也只对已删除的程序化地形有意义，这里一并停用。
	var th := terrain.get_height_at(player.global_position.x, player.global_position.z)
	if not terrain.using_terrain3d():
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
	# Terrain3D 模式下的兜底：极端情况（掉出世界）才拉回来，平时绝不干预物理
	elif player.global_position.y < -50.0:
		player.global_position.y = th + 1.0
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
## 坡度速度系数：只影响水平移动速度。
##   平地 / 空中 / 没输入 → 1.0（完全不影响现有手感）
##   上坡 → 1.0 向 slope_speed_min_ratio 过渡（越陡越慢）
##   下坡 → 1.0 向 slope_speed_max_ratio 过渡（越陡越快，但有上限）
##   斜着走 → 按"顺着坡走的分量"过渡，所以沿坡横移不会被误减速/误加速
## 返回前统一用 [min_ratio, max_ratio] 钳住，这就是最大/最小速度限制。
## 纯判定：脚下高度 feet_y，前方地面 ahead_y（可能没有），对面 far_y（可能没有）。
## 前方下沉、且对面在 crack_max_width 内回到脚面高度 → 是"缝"，返回 true（要拦住）。
func crack_verdict(feet_y: float, has_ahead: bool, ahead_y: float,
		has_far: bool, far_y: float) -> bool:
	if not crack_guard:
		return false
	if not has_ahead:
		return has_far                       # 前方是空的，对面有地 → 缝
	if feet_y - ahead_y <= crack_max_drop:
		return false                         # 前方地面没怎么下沉（小坑洼），照常走
	if not has_far:
		return false                         # 对面也没有地 → 悬崖/深渊，允许过去（该掉就掉）
	return far_y > feet_y - crack_max_drop   # 对面回到脚面附近 → 是缝


## 物理探针：沿 dir 向前探，判断前方是不是"能卡住人的缝"
func crack_ahead(space: PhysicsDirectSpaceState3D, feet: Vector3, dir: Vector3) -> bool:
	if not crack_guard or space == null:
		return false
	var d := Vector3(dir.x, 0.0, dir.z)
	if d.length_squared() < 0.0001:
		return false
	d = d.normalized()
	var from := feet + Vector3.UP * 0.4
	var ahead_from := from + d * crack_probe_ahead
	var far_from := from + d * (crack_probe_ahead + crack_max_width)
	var a := _ray_down(space, ahead_from, 4.0)
	var b := _ray_down(space, far_from, 4.0)
	var has_a := not a.is_empty()
	var has_b := not b.is_empty()
	var ay: float = (a.get("position", Vector3.ZERO) as Vector3).y
	var by: float = (b.get("position", Vector3.ZERO) as Vector3).y
	return crack_verdict(feet.y, has_a, ay, has_b, by)


func _ray_down(space: PhysicsDirectSpaceState3D, from: Vector3, dist: float) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.new()
	q.from = from
	q.to = from + Vector3.DOWN * dist
	q.collide_with_areas = false
	if player != null:
		q.exclude = [player.get_rid()]
	return space.intersect_ray(q)


## 逐轴取**中值**（抗异常值）：三角网上某条射线可能正好打到一块陡面，
## 用平均会被它拽偏，中值不会 —— 这就是"法线中值"的核心。
func median_normal(normals: Array) -> Vector3:
	if normals.is_empty():
		return Vector3.UP
	var xs: Array = []
	var ys: Array = []
	var zs: Array = []
	for v in normals:
		var n: Vector3 = v
		xs.append(n.x)
		ys.append(n.y)
		zs.append(n.z)
	xs.sort()
	ys.sort()
	zs.sort()
	var mid: int = xs.size() / 2
	var med := Vector3(xs[mid], ys[mid], zs[mid])
	if med.length_squared() < 0.000001:
		return Vector3.UP
	med = med.normalized()
	# 中值偏得太离谱（几乎不是地面）-> 不采信
	if med.y < 0.2:
		return Vector3.UP
	return med


## 在脚下采 5 个点（中心 + 四周）的地面法线，滤掉陡面，再取中值
func sample_ground_up(space: PhysicsDirectSpaceState3D) -> Vector3:
	var feet := player.global_position
	var r := 0.28                      # 采样半径（和胶囊半径同量级）
	var probe := 1.4                   # 向下探的距离
	var offs := [
		Vector3.ZERO,
		Vector3(r, 0.0, 0.0), Vector3(-r, 0.0, 0.0),
		Vector3(0.0, 0.0, r), Vector3(0.0, 0.0, -r),
	]
	var got: Array = []
	for off in offs:
		var hit := _ray_down(space, feet + Vector3(0.0, 0.5, 0.0) + off, probe)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		# 法线太斜 -> 那是墙/侧面，不是地面，丢掉（避免被它推走）
		if n.angle_to(Vector3.UP) > player.floor_max_angle:
			continue
		got.append(n.normalized())
	return median_normal(got)


## 每帧更新平滑地面法线（接地时快速跟随，离地时缓慢回正）
func update_ground_up(delta: float) -> void:
	if player.is_on_floor():
		var med := sample_ground_up(get_world_3d().direct_space_state)
		var k := 1.0 - exp(-GROUND_SMOOTH_RATE * delta)
		_ground_up = _ground_up.lerp(med, k)
		if _ground_up.length_squared() > 0.000001:
			_ground_up = _ground_up.normalized()
		_ground_ready = true
	elif _ground_ready:
		var k2 := 1.0 - exp(-4.0 * delta)
		_ground_up = _ground_up.lerp(Vector3.UP, k2).normalized()


func slope_speed_factor(normal: Vector3, move_dir: Vector3, on_floor: bool) -> float:
	if not on_floor or move_dir.length_squared() < 0.000001:
		return 1.0
	if slope_speed_angle <= 0.0:
		return 1.0
	var n := normal.normalized()
	var angle := n.angle_to(Vector3.UP)
	if angle < 0.01:
		return 1.0                                  # 平地
	# 法线的水平投影指向"下坡方向"；移动方向与它相反 = 上坡
	var downhill := Vector3(n.x, 0.0, n.z)
	if downhill.length_squared() < 0.000001:
		return 1.0                                  # 坡面几乎垂直，交给物理挡
	var along := move_dir.normalized().dot(-downhill.normalized())   # +1 正上坡，-1 正下坡
	var t := clampf(angle / deg_to_rad(slope_speed_angle), 0.0, 1.0)
	var factor := 1.0
	if along > 0.0:
		factor = lerpf(1.0, slope_speed_min_ratio, t * along)        # 上坡：减速
	elif along < 0.0:
		factor = lerpf(1.0, slope_speed_max_ratio, t * -along)       # 下坡：加速
	return clampf(factor, slope_speed_min_ratio, slope_speed_max_ratio)


func _lateral_speed(move_xz: Vector3, facing_yaw: float) -> float:
	if move_xz.length_squared() < 0.0001:
		return 0.0
	var right := Vector3(cos(facing_yaw), 0.0, -sin(facing_yaw))
	return move_xz.dot(right)


## 自动化测试用：非零时替代键盘输入（headless 探测无法模拟按键）
var test_move_override := Vector2.ZERO


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

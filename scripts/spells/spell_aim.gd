@tool
extends RefCounted
## 法术的「瞄准方向」+「喷射起点」—— 粒子版与着色器版**共用这一份实现**。
##
## 为什么要独立出来：这两段逻辑原来在 flame_jet_particles.gd 和 flame_visual.gd 里
## 各抄了一份（再往前还抄自已删除的 flame_jet.gd）。同一段代码存两份的后果已经出现过：
## 「角色静止时火焰喷射方位差 90°」的 bug 就写在两份拷贝里，只修一处就会两边行为不一致。
##
## 用法（视觉脚本持有它，自己不再实现这两段）：
##     var _aim := SpellAim.new()
##     func setup(player, staff) -> void: _aim.setup(player, staff, self)
##     _aim.aim_dir() / _aim.origin_global()
##
## 想改"从法杖顶端喷"还是"从角色身前喷"，只改这里的 origin_at_staff —— 两个实现同时生效。

const StaffTip := preload("res://scripts/spells/staff_tip.gd")

## 方向长度低于此值就认为"这个来源没有有效输入"，退化到下一条来源
const DIR_EPS_SQ := 0.0004
## 全部来源都失效时的终判阈值
const ALL_EPS_SQ := 0.000001

var player: Node3D = null
var staff: Node3D = null

## true  = 从法杖顶端喷（走 StaffTip 数据驱动算杖头）
## false = 从角色身前喷（角色位置 + 高度偏移 + 朝向前方偏移）
var origin_at_staff := false
var front_height := 1.05     ## origin_at_staff = false 时的高度偏移（米）
var front_offset := 0.6      ## origin_at_staff = false 时朝角色正前方的水平偏移（米）

## 宿主节点（视觉脚本自己）：只用来取 viewport / 相机 / 自身位置
var _host: Node3D = null
## 所有来源都失效时保持上一次的方向，避免站着不动时朝向乱跳
var _last_dir := Vector3.FORWARD


func setup(p_player: Node3D, p_staff: Node3D, host: Node3D) -> void:
	player = p_player
	staff = p_staff
	_host = host


## 喷射方向（水平、世界空间）
func aim_dir() -> Vector3:
	var d := Vector3.ZERO

	# 1) 移动中：朝移动方向喷。角色本来就面向水平移动方向（player.gd::face_direction），
	#    所以这条和下面第 2 条结果基本一致，保留它是为了移动时用**瞬时**方向而不是平滑后的朝向。
	if _valid(player) and "velocity" in player:
		var v: Variant = player.get("velocity")
		if v is Vector3:
			d = Vector3(v.x, 0.0, v.z)

	# 2) 静止：朝**角色面朝方向**喷。
	#    模型 +Z 是脸的方向：player.gd::face_direction() 用 atan2(face.x, face.z) 设 rotation.y，
	#    所以 face = (sin(yaw), 0, cos(yaw))。
	#    ★ 别用相机的 (-sin, 0, -cos)：那是相机自己的 -Z 约定（camera_rig.gd::aim_from_player），
	#      套在角色 yaw 上正好差 180°；而且本作是锁定的俯视角（"鼠标默认不锁定"），
	#      角色静止时朝向 ≠ 相机前方 —— 这就是"站着不动喷歪"的原因（实测差 90°）。
	if d.length_squared() < DIR_EPS_SQ and _has_facing():
		var yaw := float(player.call("get_facing_yaw"))
		d = Vector3(sin(yaw), 0.0, cos(yaw))

	# 3) 兜底：拿不到角色朝向才退回相机水平前向
	if d.length_squared() < DIR_EPS_SQ:
		var cam := _camera()
		if cam != null:
			var cf := -cam.global_transform.basis.z
			d = Vector3(cf.x, 0.0, cf.z)

	# 4) 都没有：保持上一次
	if d.length_squared() < ALL_EPS_SQ:
		return _last_dir

	d = d.normalized()
	_last_dir = d
	return d


## 喷射起点（世界坐标）
func origin_global() -> Vector3:
	if origin_at_staff and _valid(staff):
		var tip: Vector3 = StaffTip.tip_global(staff)
		if tip != Vector3.ZERO:
			return tip
	if _valid(player):
		return player.global_position + Vector3.UP * front_height + aim_dir() * front_offset
	return _host.global_position if _valid(_host) else Vector3.ZERO


# ---------------------------------------------------------------- 内部
func _valid(n: Node) -> bool:
	return n != null and is_instance_valid(n)


func _has_facing() -> bool:
	return _valid(player) and player.has_method("get_facing_yaw")


func _camera() -> Camera3D:
	if not _valid(_host) or not _host.is_inside_tree():
		return null
	return _host.get_viewport().get_camera_3d()

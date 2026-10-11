# ==============================================================================
# spell_aim.gd —— 法术「瞄准方向 + 喷射起点」的共用实现
# ------------------------------------------------------------------------------
# 系统归属：法术系统（scripts/spells/）里的纯逻辑工具类，被多个法术视觉脚本复用。
#   不是 autoload、不挂场景、不注册进任何管理器；由使用方各自 SpellAim.new() 持有实例。
#
# 为什么存在：这两段逻辑曾经在 flame_jet_particles.gd（粒子版）和 flame_visual.gd
#   （着色器版）里各存一份（更早还抄自已删除的 flame_jet.gd）。同一段代码存两处已经
#   出过事故：「角色静止时喷射方位差 90°」只修了其中一份，导致两个实现行为不一致。
#   收敛到本文件后，改这里两个实现同时生效。
#
# 关键依赖：
#   · scripts/spells/staff_tip.gd（const StaffTip = preload(...)）——
#     仅在 origin_at_staff = true 时被 origin_global() 间接调用，用于数据驱动地算杖头。
#   · player（由 setup 注入）：需要是 Node3D。可选能力：
#       - velocity: Vector3（读水平分量作为移动方向）；
#       - get_facing_yaw() -> float（弧度），静止时用它取角色面朝方向。
#   · _host（由 setup 注入，即使用方视觉脚本自身）：只用来取 viewport / 当前 Camera3D
#     / 自身 global_position。
#   · 无 autoload 依赖；不读写文件；不发任何信号；不改场景树。
#
# 主要对外接口（使用方只需这三个 + 三个配置项）：
#   setup(player, staff, host)   绑定依赖，装载后调用一次
#   aim_dir() -> Vector3         水平单位方向（世界空间，y 恒为 0）
#   origin_global() -> Vector3   喷射起点（世界坐标）
#   配置项：origin_at_staff（起点模式）/ front_height / front_offset
#
# 已知的坑与注意事项：
#   1) 本类**有状态**：aim_dir() 会写 _last_dir，全部来源失效时返回上一次的方向。
#      所以它不是纯函数；同帧重复调用是设计意图（避免站着不动时方向乱跳）。
#   2) origin_global() 在 origin_at_staff = false 时会**再次调用** aim_dir()，
#      因此这两个接口应当成对使用，不要假设方向与起点来自两次不同时刻的采样。
#   3) 别用相机的 (-sin, 0, -cos) 反推角色朝向 —— 那是相机自己的 -Z 约定，套在角色 yaw
#      上正好差 180°；细节见 aim_dir() 中第 2 条来源前的注释。
#   4) player / staff / _host 都允许为 null 或已被释放：所有访问统一走 _valid() 兜底。
#   5) （推测）文件带 @tool，是为了使用方视觉脚本在编辑器内预览时也能 new() 出本类。
# ==============================================================================
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

# ==================== 依赖与常量 ====================
## 杖头计算模块（class，不是 autoload，也没有实例）。仅 origin_at_staff = true 时被调用。
## 用 preload 而不是 load：路径固定、启动期就解析好，避免首次施法时才去读盘。
const StaffTip := preload("res://scripts/spells/staff_tip.gd")

## 判定单条方向来源是否"有效"的阈值，比较对象是**未归一化**向量的 length_squared()。
## 取 0.0004 = 0.02² —— 即速度小于约 0.02 m/s 就视为"没在移动"，退化到下一条来源。
## 调大：更容易被判成"无输入"而提前退到相机前向（角色刚起步时会切来源）；
## 调小：极慢的漂移也被当作有效方向（方向抖动、且移动方向噪声被放大）。
## 因为比较的是平方值，所以这里不用开方，阈值也必须写成平方口径。
## 方向长度低于此值就认为"这个来源没有有效输入"，退化到下一条来源
const DIR_EPS_SQ := 0.0004
## 最终的"完全没有方向"阈值（1e-6 = 0.001² 量级）。
## 之所以取得这么小：只有在真的逼近零向量时才允许走"保持上一次方向"的回退，
## 避免把合法的极小方向（例如刚起步、速度还没起来）误判成无效。
## 全部来源都失效时的终判阈值
const ALL_EPS_SQ := 0.000001

# ==================== 运行期状态与配置 ====================
## 施法角色根节点。由 setup() 注入；允许为 null 或已被释放。
## 用途：取 global_position（起点基准）、读 velocity（移动方向）、调 get_facing_yaw()（面朝方向）。
## 传 null 不会报错，但 aim_dir() 会退化到相机前向或上一次方向。
var player: Node3D = null
## 法杖节点（即挂法杖模型的那个 holder）。由 setup() 注入；允许为 null。
## 当前默认 origin_at_staff = false，所以它只有在开启"从杖顶喷"时才真正被使用。
var staff: Node3D = null

## true  = 从法杖顶端喷（走 StaffTip 数据驱动算杖头）
## false = 从角色身前喷（角色位置 + 高度偏移 + 朝向前方偏移）
## 起点模式开关 —— 三个视觉实现共用的**唯一**切换点。
##   true  = 走数据驱动算杖头（StaffTip.tip_global），能自动适配不同大小的法杖；
##   false = 用"角色身前"这个近似点（详见 front_height / front_offset），当前默认值。
## 默认 false（推测原因：从角色身前喷不会被法杖模型和握持动画遮挡）。
## 改成 true 后 front_height / front_offset 立刻失效，且两个视觉实现同时改变弹道起点。
var origin_at_staff := false
## 仅 origin_at_staff = false 时生效：起点相对玩家原点的**向上**偏移（单位：米）。
## 默认 1.05 —— 大约在角色胸口/手部高度，让火看起来是从手中而不是从地面喷出。
## 调大：起点升高（可能高过头顶）；调小：贴近脚面；0.0 = 玩家原点（地面高度）。
## 使用方可以覆盖：blue_tornado.gd 会把它改成 0.0（龙卷风要贴地生成）。
var front_height := 1.05     ## origin_at_staff = false 时的高度偏移（米）
## 仅 origin_at_staff = false 时生效：沿 aim_dir() 朝角色正前方推开的水平偏移（单位：米）。
## 默认 0.6 —— 让起点离开角色胶囊体，避免粒子生成在身体内部（穿模或被自身遮挡）。
## 调大：起点更靠前（观感上像"从手里喷出"）；调小：可能嵌进角色身体里。
## 使用方可以覆盖：blue_tornado.gd 会把它改成法术配置的 spawn_distance。
var front_offset := 0.6      ## origin_at_staff = false 时朝角色正前方的水平偏移（米）

## 宿主节点（视觉脚本自己）：只用来取 viewport / 相机 / 自身位置
## setup() 的第三个参数，指向使用方自己（flame_jet_particles / flame_visual / blue_tornado 等）。
## 只被两处使用：_camera() 里取 viewport 与当前相机；origin_global() 的最后兜底位置。
## 为 null 不会崩，但相机兜底与最终兜底会直接失效（退化路径更短，方向/起点更容易不准）。
var _host: Node3D = null
## 所有来源都失效时保持上一次的方向，避免站着不动时朝向乱跳
## aim_dir() 的"记忆"：上一次成功算出的方向（始终是已归一化的单位向量）。
## 初值 Vector3.FORWARD(+Z) 只是占位，目的是首帧就有一个合法方向，
## 而不是 ZERO —— ZERO 会被调用方拿去 normalize() 或搭基向量，产生非法变换/报错。
var _last_dir := Vector3.FORWARD


# ==================== 初始化 ====================
## 注入依赖，绑定施法者 / 法杖 / 宿主。
##
## 参数：
##   p_player — 施法角色根节点（Node3D）。允许 null；
##              为 null 时 aim_dir 的第 1、2 条来源与 origin_global 的主路径全部失效。
##              若希望静止时方向正确，该节点必须实现 get_facing_yaw() -> float（弧度 yaw）。
##   p_staff  — 法杖节点（holder）。允许 null；仅 origin_at_staff = true 时才会用到。
##   host     — 使用方自己（视觉脚本节点）。被 _camera() 与最终兜底位置使用。
##
## 返回值：无。
## 副作用：写入 player / staff / _host 三个成员。不触碰场景树、不发信号、不改 _last_dir。
## 调用时机：装载阶段调用一次（spell_caster 装载法术时），必须早于第一次 aim_dir()。
## 注意事项：可以重复调用，会整体覆盖上一次的绑定；但 _last_dir 不会随之重置，
##           所以"换角色"场景下方向记忆会残留在上一帧的朝向上（本作目前不会发生）。
func setup(p_player: Node3D, p_staff: Node3D, host: Node3D) -> void:
	player = p_player
	staff = p_staff
	_host = host


# ==================== 对外接口：方向与起点 ====================
## 计算喷射方向（世界空间、纯水平）。
##
## 参数：无 —— 方向来源全部来自 setup() 注入的依赖。
##
## 返回值：Vector3，**已归一化**且 y 分量恒为 0 的单位向量。永不返回 ZERO：
##         所有来源都失效时返回内部记忆的 _last_dir。
##
## 取值优先级（逐条退化：上一条的 length_squared() 低于 DIR_EPS_SQ 就试下一条）：
##   1) player.velocity 的水平分量 (v.x, 0, v.z) —— 移动中用**瞬时**方向；
##   2) player.get_facing_yaw() -> (sin(yaw), 0, cos(yaw)) —— 静止时用角色面朝方向；
##   3) 当前相机的水平前向（-camera.basis.z 取 xz）—— 拿不到角色朝向时的兜底；
##   4) 全无效 —— 保持上一次的方向（见 _last_dir）。
##
## 副作用：更新成员 _last_dir。因此本方法**有状态、不是纯函数**；
##         同一帧内重复调用会返回同一个值（第 1/2 条来源决定），不会互相干扰。
## 调用时机：每帧（粒子/视觉更新时）；也允许在 setup() 之前调用（此时走 3、4 分支）。
## 注意事项：应与 origin_global() 成对使用 —— origin_global() 内部会再调一次本方法。
## 喷射方向（水平、世界空间）
func aim_dir() -> Vector3:
	# 逐条来源依次尝试；d 一直是 ZERO 就表示「当前还没拿到有效方向」。
	# 用 length_squared() 比较而不开方：省掉每帧开方，阈值也因此写成平方口径。
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

	# 归一化后再写入 _last_dir：保证"记忆"里永远是单位向量，
	# 这样第 4 条回退分支不需要再做任何长度处理，调用方也可直接拿去当方向用。
	d = d.normalized()
	_last_dir = d
	return d


## 计算喷射起点（世界空间）。
##
## 参数：无。
##
## 返回值：Vector3，世界坐标。取值优先级：
##   ① origin_at_staff = true 且 staff 有效，且 StaffTip.tip_global(staff) 返回非 ZERO
##      -> 法杖杖头。tip_global 用 ZERO 表示「算不出杖头」（见 staff_tip.gd），
##         所以这里把非 ZERO 当成功，失败则继续退到 ②；
##   ② player 有效 -> player.global_position + UP * front_height + aim_dir() * front_offset；
##   ③ 否则 -> _host.global_position；连 _host 也无效时返回 Vector3.ZERO。
##
## 副作用：第 ② 步会调用 aim_dir()，因此会更新 _last_dir（严格说本方法不是只读的）。
## 调用时机：每帧，且必须晚于 setup()；否则 player / staff 全是 null，只会走 ③ 分支。
## 注意事项：返回的 ZERO 既可能是"合法的世界原点"，也可能是"什么都算不出来"的哨兵值，
##           所以调用方不要用 `== Vector3.ZERO` 来判断本方法是否失败。
## 喷射起点（世界坐标）
func origin_global() -> Vector3:
	# 先短路配置开关再做节点有效性检查：两个条件都为真才去走代价较高的杖头计算。
	if origin_at_staff and _valid(staff):
		# tip_global 走的是"读模型包围盒 / 握持脚本提供的 _head_local"这条数据驱动路径，
		# 对大小不同的法杖都成立，所以不能用写死的偏移量代替（那会让小杖喷在杖身中间）。
		var tip: Vector3 = StaffTip.tip_global(staff)
		if tip != Vector3.ZERO:
			return tip
	# 主路径（默认配置就走这里）。因为 aim_dir() 保证是纯水平单位向量，
	# 所以垂直偏移量 front_height 不会被方向污染：起点高度永远等于 front_height。
	if _valid(player):
		return player.global_position + Vector3.UP * front_height + aim_dir() * front_offset
	# 最后一层兜底（player 为 null：setup 未调用、或角色节点已被释放）：
	# 宁可把起点放在宿主视觉节点自己身上，也不返回 ZERO —— ZERO 会让调用方
	# 用 origin_global() 拼出的 Transform3D 落在世界原点，出现"火喷在地图中心"的怪象。
	return _host.global_position if _valid(_host) else Vector3.ZERO


# ==================== 内部工具 ====================
# ---------------------------------------------------------------- 内部
## 判定节点「存在且未被释放」。
## 参数：n — 任意 Node，允许 null。
## 返回值：true = 可以安全读它的属性/调它的方法。
## 副作用：无（纯查询）。
## 为什么不能只用 `n != null`：Godot 的节点被 queue_free() 之后引用仍非 null，
##   但访问其属性会报错；is_instance_valid() 才是唯一可靠的判据。
## 用法：所有对 player / staff / _host 的访问都先过这一层，因此传 null 也不会崩。
func _valid(n: Node) -> bool:
	# n != null 放前面做短路（顺手排除显式传入的 null），真正可靠的判据是 is_instance_valid()。
	return n != null and is_instance_valid(n)


## 判断 player 是否**具备**"静止时的朝向来源"，即是否实现了 get_facing_yaw()。
## 参数：无。
## 返回值：true = player 有效且带 get_facing_yaw() 方法。
## 副作用：无。
## 为什么用 has_method() 而不是直接 call()：不同角色脚本能力不一，
##   缺这个方法时应当静默退化到相机前向，而不是每帧抛错刷日志。
func _has_facing() -> bool:
	return _valid(player) and player.has_method("get_facing_yaw")


## 取当前真正生效的 3D 相机，供 aim_dir() 的第 3 条兜底来源使用。
## 参数：无（用 _host 定位 viewport）。
## 返回值：Camera3D；_host 为 null / 不在场景树里 / 该 viewport 没有相机时返回 null。
## 副作用：无（纯查询）。
## 为什么走 get_viewport() 而不是固定节点路径：相机是运行时由 camera_rig 注入的，
##   写死路径会在没有相机的场景（如编辑器预览、截图工具场景）里报错。
func _camera() -> Camera3D:
	# 不在场景树里时 get_viewport() 拿不到有效 viewport，必须先挡掉再取。
	if not _valid(_host) or not _host.is_inside_tree():
		return null
	return _host.get_viewport().get_camera_3d()

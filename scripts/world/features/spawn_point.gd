# =====================================================================
# spawn_point.gd —— 出生点数据源（World / Features 系统）
# =====================================================================
#
# 【本文件职责】
#   只是一个"配置节点"：在场景里用 Marker3D 标出**出生位置**与**出生朝向**，
#   并提供几个纯函数，把编辑器里摆好的 / 导出的数据换算成 world_builder 需要的格式。
#   它自己**不移动角色、不操作相机、不写任何状态**：三个 resolve_* 都是只读计算，
#   不修改成员变量、不发信号、不碰场景树，重复调用结果一致。
#
# 【所属系统 / 调用链】
#   scripts/world/world_builder.gd :: place_spawn() 是唯一调用方，流程为：
#     Main/SpawnPoint（本节点，缺失时为 null）
#       → resolve_position(terrain) / resolve_yaw() / resolve_pitch()
#       → 写入 player.global_position / camera_rig._current_yaw / _current_pitch
#       → camera_rig.aim_from_player()
#   节点在 scenes/main.tscn 中挂在 Main 根节点下，名字必须是 "SpawnPoint"
#   （world_builder 按这个名字 get_node_or_null；改名 = 静默退回场景里 Player 的摆放坐标）。
#
# 【关键依赖】
#   · 第一行 @tool：只有工具脚本才会在编辑器里调用 _get_configuration_warnings()，
#     从而在检查器里显示配置警告。删掉它 = 配置错误不再有提示（逻辑仍能跑）。
#   · 无 autoload 依赖、不连信号、不加载资源；唯一外部耦合是
#     terrain.has_method("get_height_at") 这个**鸭子类型**接口
#     （scripts/world/terrain.gd :: get_height_at(x: float, z: float) -> float）。
#   · 与 scripts/camera_rig.gd 共用同一套 yaw / pitch 约定，改这里必须同步看那边。
#
# 【主要对外接口】
#   resolve_position(terrain: Node = null) -> Vector3     出生世界坐标
#   resolve_yaw() -> float                                出生角色朝向 yaw（弧度）
#   resolve_pitch() -> float                              出生相机俯仰（弧度）
#   _get_configuration_warnings() -> PackedStringArray    编辑器配置校验（Godot 回调）
#
# 【朝向约定（与 camera_rig 一致，务必别改）】
#   角色朝向 = (-sin(yaw), 0, -cos(yaw))；而绕 Y 旋转 yaw 的 Godot 节点，
#   其 -Z 轴恰好也是这个向量，所以**节点的 rotation.y 可以直接当出生 yaw 用**。
#   这里给的是**角色朝向**（角色背对第三人称相机）；相机 yaw 由 aim_from_player() 反推。
#
# 【已知的坑 / 注意事项】
#   1. 三个朝向来源有严格优先级：face_target（非零时最高）> use_node_rotation > yaw_degrees。
#      高优先级一旦生效，低优先级被**完全忽略**而不是合并。历史上曾因 resolve_yaw()
#      只读 yaw_degrees 而出现"在编辑器里转 SpawnPoint，进游戏没反应"的 bug。
#   2. resolve_position() 的 y 只在**传入了带 get_height_at 的 terrain** 时才被地形高度覆盖；
#      不传 terrain 时 y 就是节点自身摆放的高度（resolve_yaw() 内部调用就没传）。
#   3. hover_height 是出生瞬间的悬空补偿，之后靠重力落位；为负会陷进地里，
#      因此 _get_configuration_warnings() 专门挡了 < 0。调大/调小的副作用见该导出量说明。
#   4. 本文件是纯数据节点：不要在这里加 _ready/_process 去"自动摆角色"。
#      角色摆放的时机由 world_builder 控制（地形 rebuild() 之后），乱加会与其抢顺序。
#   5. 注释语言中文、标识符英文；查不到实现依据的推断会标"（推测）"。
# =====================================================================

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

# ==================== 导出参数（编辑器里配置的出生数据源） ====================
# 下面 5 个导出量分两类：位置类（hover_height）与朝向类（use_node_rotation /
# yaw_degrees / face_target / pitch_degrees）。朝向类的优先级见各自说明与 resolve_yaw()。

## 出生朝向来源：
##   true  = 用**本节点自身的旋转**（推荐：在编辑器里直接转 Marker3D）
##   false = 用下面的 yaw_degrees（旧场景兼容用）
## 默认值 true 的原因：场景里最常见的需求就是"直接拖 Marker3D 转朝向"，默认走节点旋转
## 可以让"改了没反应"这类坑从源头消失；旧场景若要复现旧行为才改成 false。
## 注意：本量与 yaw_degrees 同时配置时**本量优先**，yaw_degrees 会被完全忽略
##       （_get_configuration_warnings() 会给出提示，避免又变成"改了没反应"）。
@export var use_node_rotation := true

## 出生朝向（度）—— 仅当 use_node_rotation = false 时生效。
## 注意：这是**角色朝向**（背对第三人称相机）；相机 yaw 由 aim_from_player() 反推。
## 取值范围 -180 ~ 180（度，编辑器里是滑杆，步进 0.1）；0 = 面朝 -Z 世界方向（默认朝向）。
## 生效条件：use_node_rotation = false 且 face_target = Vector3.ZERO；两条件任一不满足都会被盖过。
## 改动效果：只影响"出生那一瞬间的角色朝向"，出生后朝向完全由输入/相机接管。
## 改动注意：与节点自身旋转同时存在时改这里**看不出任何变化**，先确认 use_node_rotation。
@export_range(-180.0, 180.0, 0.1, "degrees") var yaw_degrees := 0.0

## 非零时：朝向该世界坐标（优先级最高，盖过上面两项）
## 取值：一个世界坐标点（米）。ZERO 表示"未启用"，此时才回落到 use_node_rotation / yaw_degrees。
## 为什么用零向量当哨兵：Vector3 没有 null 可用，用 ZERO 表示"没设"是 Godot 里的常见做法；
##   代价是**无法精确朝向世界原点** —— 真需要的话请改用节点旋转或 yaw_degrees。
## 计算见 resolve_yaw() 的 face_target 分支：它按"朝向目标"反解 yaw，注意那一步用的是
##   节点自身坐标（未做地形贴合），与最终出生点可能略有高度差。
@export var face_target := Vector3.ZERO

## 出生悬空高度（米）：略高于地面，靠重力自然落位
## 单位：米。默认 2.0 是"略高于地面"的经验值 —— 与 world_builder.place_spawn() 里
## 兜底分支写死的 hover = 2.0 保持一致，两条路径手感相同。
## 调大：出生后下落时间变长、可能一进游戏先悬空一会儿；
## 调小：贴地更干脆，但地形与碰撞体有误差时容易卡进地面。
## **不允许为负**（会直接陷进地表以下，配置警告里挡了这种情况）。
@export var hover_height := 2.0

## 初始俯仰角（度）：负值 = 略微俯视（相机 pitch 约定，负为向下）
## 取值范围 -89 ~ 89（度）：刻意避开 ±90，否则相机俯仰到极限时朝向向量会退化（万向锁）。
## 默认 -9.4 与 scenes/main.tscn 里 SpawnPoint 的实测取值一致（略微俯视的默认手感）。
## 注意：pitch **只**来自这个导出量 —— 本文件不读取节点自身的 X 旋转（见 resolve_pitch()）。
## 另注：符号含义请以 scripts/camera_rig.gd 的 pitch 约定为准；本文件上方那句"负值 = 俯视"
##   与 camera_rig 的表述方向相反，改动前先到 camera_rig 里确认，不要照抄本行。
@export_range(-89.0, 89.0, 0.1, "degrees") var pitch_degrees := -9.4


# ==================== 对外查询接口（只读纯计算，唯一调用方是 world_builder.place_spawn） ====================
# 三个 resolve_* 都不修改成员变量、不发信号、不碰场景树，重复调用结果一致。

## 取出生坐标：y = 地形高度 + hover_height
## terrain 为空时退回节点自身 y。
## 参数 terrain：任何带 get_height_at(x: float, z: float) -> float 的节点
##   （实际传入的是 scripts/world/terrain.gd 的 TerrainSystem）。
##   传 null 或方法不匹配时**静默**退回节点自身 y，不报错。
## 返回：出生用的世界坐标（米）。x/z 恒等于节点 global_position 的 x/z，只有 y 可能被改写。
## 副作用：无 —— 只读 global_position 与导出量，不写节点、不碰 player。
## 调用时机：world_builder.place_spawn() 中、地形 rebuild() 之后调用（必须等高度数据就绪，
##   否则会按旧地形高度出生，可能落进地里）。
## 注意：用的是 global_position（世界坐标），因此出生点被放进带旋转的父节点下也不会偏
##   （**推测**：这是选 global 而非 local 的有意理由）。
func resolve_position(terrain: Node = null) -> Vector3:
	var p := global_position
	# 鸭子类型检查：不 import TerrainSystem，只要对方拿得出 get_height_at 就够用
	# （**推测**：这样便于换地形实现或在测试里塞替身，也避免 scripts 之间产生硬依赖）
	if terrain != null and terrain.has_method("get_height_at"):
		var h: float = terrain.get_height_at(p.x, p.z)
		# 只改写 y：x/z 保留在编辑器里摆好的位置，否则出生点会漂到地形原点附近
		p.y = h + hover_height
	return p


## 取出生朝向 yaw（弧度）—— 角色朝向
## 返回：角色朝向 yaw（**弧度**，与 camera_rig._current_yaw 同量纲）。
##   来自 atan2，值域 (-PI, PI]；本项目约定 0 = 面朝 -Z。
## 优先级（高 → 低）：face_target 非零 > use_node_rotation = true > yaw_degrees。
## 副作用：无 —— 不写任何成员变量。
## 注意：face_target 分支内部会调用 resolve_position()，但**不传 terrain**，
##   也就是说方向是基于节点自身坐标反解的，而不是地形贴合后的实际出生点。
## 调用时机：world_builder.place_spawn() 里赋给 camera_rig._current_yaw，
##   随后 camera_rig.aim_from_player() 按它把镜头摆到角色身后。
func resolve_yaw() -> float:
	# 分支 1（优先级最高）：朝世界坐标点。非零即**完全接管**朝向，下面两个来源都被忽略
	if face_target != Vector3.ZERO:
		# 这里不传 terrain：p 用的是节点自身坐标（地形贴合后的 y 没参与计算）。
		# 水平方向仍准确；节点与地面高度差很大时，朝向的垂直分量会略有偏差。
		var p := resolve_position()
		var d := face_target - p
		# ★ 要让角色的 forward(-Z) 指向 d，需要 yaw = atan2(-dx, -dz)。
		#   原来写的是 atan2(dx, dz)，按本项目的 yaw 约定那正好是**反 180°**
		#   （会背对目标）。这条以前没被发现，是因为 face_target 一直是 0、分支没走过。
		return atan2(-d.x, -d.z)
	# 默认：直接拿节点自身的旋转 —— 在编辑器里转 Marker3D 就是最直觉的改朝向方式
	# 分支 2（默认路径）：节点自身旋转。用 global_rotation 而非 rotation，
	# （**推测**）是为了让出生点被放到带旋转的父节点下时，yaw 仍按世界朝向解释
	if use_node_rotation:
		# 无需换算：本项目的 yaw 约定下，节点 -Z 轴就是角色 forward（见文件头）
		return global_rotation.y
	# 分支 3：兼容旧场景的导出量，度 → 弧度
	return deg_to_rad(yaw_degrees)


## 取出生俯仰（弧度）
## 返回：出生时的相机俯仰角（**弧度**，与 camera_rig._current_pitch 同量纲）。
## 实现：只做 度 → 弧度 换算，**不读节点自身的 X 旋转** ——
##   节点的 X 旋转在本项目的第三人称相机里没有对应含义，读了反而会引入一份"隐式朝向来源"。
## 副作用：无。
## 调用时机：world_builder.place_spawn() 里赋给 camera_rig._current_pitch，
##   再由 camera_rig.aim_from_player() 实际应用。
## 注意：符号语义请以 camera_rig.gd 的 pitch 约定为准（本文件的文字描述与之表述不一致）。
func resolve_pitch() -> float:
	# 纯粹的度→弧度换算
	return deg_to_rad(pitch_degrees)


# ==================== 编辑器配置校验（仅 @tool 在编辑器里生效） ====================

## Godot 编辑器回调：返回非空数组时，检查器里本节点会显示黄色警告、场景树标警示图标。
## 返回：PackedStringArray，每个元素是一条给美术看的中文提示（**纯提示，不影响任何逻辑**）。
## 副作用：无 —— 只读成员变量。**绝对不要**在这里改配置（会被编辑器反复调用）。
## 调用时机：只有脚本带 @tool 时，编辑器在打开场景 / 改动本节点属性时调用；
##   **运行时不会被调用**，所以这里不能当运行时校验用。
## 注意：改动警告文案不会影响出生逻辑，放心改。
func _get_configuration_warnings() -> PackedStringArray:
	# 累加式收集：多条问题要能同时显示，所以逐条 append 而不是命中第一条就 return
	var w := PackedStringArray()
	if hover_height < 0.0:
		w.append("hover_height 不应为负")
	# 两项都设了的时候必须说清谁赢，否则又是一个"改了没反应"的坑
	# 现实情况：scenes/main.tscn 里的 SpawnPoint 并未覆盖 use_node_rotation（取默认 true），
	# 而 yaw_degrees = -180.0 —— 所以这条警告在当前主场景里是"预期会出现"的。
	# 它提示的是"yaw_degrees 不生效"，不是场景坏了；别为了消警告去动朝向来源的优先级。
	if use_node_rotation and absf(yaw_degrees) > 0.001:
		w.append("朝向取自节点旋转（use_node_rotation = true），yaw_degrees = %s 会被忽略；"
				% str(yaw_degrees) + "建议把它设为 0 以免误解")
	return w

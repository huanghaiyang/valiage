extends Node3D
## 手持法杖：把 assets/models/crafted 下的 GLB 挂到右手骨骼上。
##
## 这是**按新模型重写**的一版（旧的 569 行版本随低多边形法杖一起删掉了）。
## 新模型（make_staff_spectrum.py 导出）的特点让代码能简单很多：
##
##   * Blender 里是 Z 轴向上、模型底面正好落在原点、水平居中，
##     glTF 导出用 export_yup=True -> 到 Godot 里**模型局部 +Y 就是杖身方向、
##     原点在杖底中心**。所以不需要再做"扫描 48 组旋转去找对齐角"那种事
##     （旧 GLB 的轴向是各种歪的，才有那段旁举扫描）。
##   * 朝向直接写**世界 basis**：法杖挂在会旋转的手骨上，奔跑摆臂时手骨自己在转，
##     挂在它下面的杖会被杠杆放大（手往前摆、杖头往后甩）。在局部轴上加补偿修不好，
##     所以每帧算世界方向直接写 —— 挂点只决定"握在哪"，朝向由我们说了算。
##
## 握点：模型按"目标世界长度"缩放后，把**从杖底往上 32%** 处对到挂点原点。

# ==================== 文件头：职责 · 依赖 · 对外接口 ====================
#
# 【职责】本文件只做"把一根法杖模型正确地挂在手骨上"这一件事：
#   ① 摆放：量模型包围盒 → 按目标世界长度缩放 → 把杖身握点对到挂点原点（_place）
#   ② 朝向：世界空间稳定（误差伺服）或在世界稳定关闭时用一次性标定刚性跟手
#      （_process 的后半段 / _apply_pose）
#   ③ 表现：悬浮呼吸、杖头发光与脉冲、可选的调试圆柱与诊断日志
#
# 【所属系统】法杖握持与朝向系统（详见 docs/法杖握持与朝向系统-技术文档.md）。
#   节点链路：角色 glb → Visual → Skeleton3D → hand.l → HandSocket(BoneAttachment3D)
#             → HeldStaff（本脚本）→ Model(法杖实例) / Glow / SparkCore
#
# 【关键依赖】
#   * autoload：/root/StaffSystem —— 用 call("get_def", id) 取法杖定义（model 路径、
#     world_len 等），用 call("element_color", e) 取元素颜色。走 call() 是**弱调用**：
#     单例缺失或方法改名时退化为 null / 默认色，而不是解析期报错。
#   * scripts/player.gd —— 写入 grip_offset / out_dir / len_scale / world_stable /
#     debug_verbose 等参数，并把握点写进**本节点的 position**（本脚本不再自己加 grip_offset）。
#   * scripts/character_profile.gd —— 提供 hand_grip_offset() / hand_out_normal() 等，
#     由 player.gd 调用后转交到上面的参数里。
#   * 资源路径：assets/models/crafted/*.glb（make_staff_spectrum.py 导出，
#     约定"模型局部 +Y = 杖身方向、原点 = 杖底中心"，见文件顶部说明）。
#
# 【主要对外接口】
#   * set_staff(id, elem) -> void   换杖；id 传空字符串表示收起（不显示任何模型）
#   * request_place() -> void       请求下一帧重新摆放（运行中改了 grip_offset/grip_frac 后调用）
#   * flash(strength := 1.6)        施法瞬间让杖头闪一下
#   * debug_info() -> Dictionary    一次性导出的自检快照（位置/朝向/世界长度）
#
# 【已知的坑（改代码前务必先读这段）】
#   * 本脚本**从不写 global_transform**（只在伺服里只读地"量"当前杖身方向）：
#     写 global 会让位置被连带重算（与手骨的运动打架 → 抖动），而且全局↔局部换算里
#     夹着缩放，缩放会逐帧累积 → 法杖"越变越大"。只改局部 basis 的旋转，缩放原样写回。
#   * 缩放藏在 basis 里，**绝不能用 basis.orthonormalized()**（它会把缩放抹成 1 →
#     法杖撑满全屏）；要取纯旋转请用 _pure_rot()。
#   * 刚 add_child 完的那一帧**不能量** global 变换（Godot 惰性求值，读到的是入树前的旧值），
#     所以摆放被推迟到下一帧 _process 的 _need_place 分支。
#   * _model.position 属于 HeldStaff 局部空间（该空间带着**杖的朝向**），
#     握点偏移只能放在本节点的 position 上；放在 _model.position 上会被杖的旋转带歪。
#   * 任何新增的"每帧写朝向"逻辑都要和 world_stable 分支排他，否则两边互相覆盖（抖动）。
#
# 【不变量】position = 握点（手骨本地坐标）｜basis = 朝向 + 挂载缩放（缩放只被原样写回）
# =====================================================================

# ==================== 参数（由 player.gd 在挂载/换杖时写入） ====================
## 法杖在世界里的目标长度（米）。默认按 1.7m 角色定的 1.45m；
## 角色身高不同时由 player.gd 设 len_scale（= 身高 / 1.7）等比缩放。
var staff_len := 1.45
## 长度缩放系数（角色身高适配）。1.5m 角色 → 1.5/1.7 ≈ 0.88
var len_scale := 1.0
## 掌心偏移（手骨本地坐标）：由 player.gd 按角色档案算，见 CharacterProfile.hand_grip_offset
var grip_offset := Vector3.ZERO
# ★ 注意：这里只是"记录值"（用于日志），真正的握点偏移由 player.gd 写进**本节点的 position**。
#   本脚本绝不能再把它加进 _model.position —— 那个空间带着杖的朝向，会双重偏移 + 方向被带歪。
## 握点：从杖底往上算的比例（默认 0.32 = 下三分之一）。player.gd 可覆盖（不同杖模型可调）。
const GRIP_FRAC := 0.32
# 与 GRIP_FRAC 同义，但**可在运行中被 player.gd 按角色档案覆盖**（const 不能改）；
# 取值 0~1：0 = 握杖底端（杖头离手最远）、0.5 = 握正中、1 = 握杖顶。
# 改大 → 手握得更靠杖头，露在手外的杖身变短、杖头离身体更近。
var grip_frac := GRIP_FRAC
## 杖身**半径**方向的外移量（米）：手掌握着杖时，杖的"轴"应该在掌心外侧
## 约一个半径处，否则杖身会插进手里。0 = 不偏移（旧行为）。
var grip_out := 0.0
## 掌心外法线（**手骨本地空间**，由 player.gd 按手部几何算好）：
## 用于"半径补偿"—— 把杖沿这个方向推出一个**杆半径**，让杆的表面贴着掌心，
## 而不是让有粗细的杖压进手里（用户："总感觉法杖的横截面半径没算进去"）。
var out_dir := Vector3.ZERO
## 调试：在握点渲染一个"与杖同粗、同朝向"的半透明圆柱（穿透显示），
## 用来目视核对 ① 握点位置 ② 杖轴朝向 ③ 半径补偿 对不对。
var debug_grip_cylinder := false
## 调试圆柱"只建一次"的哨兵：_add_grip_debug_cylinder() 是幂等的。
## 副作用：运行中打开 debug_grip_cylinder 必须再调一次 request_place()（否则不会新建），
## 而且**不会**跟随后续的握点/半径变化重建（想看新数值要重挂一次法杖）。
var _grip_cyl_done := false
## 调试：打印"握点高度切片"的顶点统计（默认关闭 ✓ 每帧/每次摆放都会打，很吵 ✗）
var debug_slice := false
## 诊断日志总开关（由 player.gd 的 debug_verbose 传进来 ✓，默认关闭 ✓）
var debug_verbose := false
## ★ 世界朝向稳定（0~1）：手上其实是"松握" —— 位置跟手 ✓，但**朝向钉在世界空间** ✓。
##   1.0 = 完全稳定（跑动时杖不再跟着手臂甩 ✓，物理上更合理 ✓）
##   0.0 = 旧的刚性跟随（杖随手臂旋转 ✗，跑步时"杖尾前倾" ✗）
var world_stable := 1.0
## 稳定时杖的前后倾角（度）：**正 = 杖头朝前 / 杖尾向后** ✓（沿角色朝向 ✓，不是世界轴 ✓）
var world_lean_deg := 0.0
## ★ 跑动时额外的前后倾（度，按速度 0→1 渐变）：
##   正 = 杖头朝前、**杖尾向后拖** ✓（跑起来更自然 ✓）；0 = 跑动也保持竖直
var world_run_lean_deg := 12.0


# ==================== 调试：握点可视化圆柱 ====================
## 在握点处放一个"与杖同粗、同朝向"的半透明绿圆柱（开了 no_depth_test，可穿透模型看到），
## 用来目视核对三件事：① 握点在不在掌心 ② 杖轴朝向对不对 ③ 半径补偿位移合不合理。
##
## 参数：
##   r_local  —— 圆柱半径，单位是**本节点(HeldStaff)局部单位**。调用方传 shaft_r * sc
##               （模型局部半径 × 模型缩放），所以打印时再乘 _parent_scale 就是世界半径。
##               传 <= 0 时会被夹到 0.5 mm，避免出现半径为 0 的退化网格。
##   grip_pos —— 圆柱中心（= 杖身轴线应该穿过的点），HeldStaff 局部坐标；
##               调用方传 grip_offset +（半径补偿的位移）。
##
## 返回值：无（void）。
## 副作用：新建一个 MeshInstance3D("GripDebugCylinder") + StandardMaterial3D 并 add_child 到本节点；
##   **只建一次**（靠 _grip_cyl_done 保证幂等），场景树里会一直留着这个调试件，直到 _clear() 换杖。
## 调用时机：只在 _place() 末尾且 debug_grip_cylinder == true 时调用。
## 注意：
##   * 圆柱长度固定为 0.14 / _parent_scale（世界 14 cm 的一小段杖身），刻意不跟随杖的真实长度。
##   * （推测）grip_offset 名义上是**手骨本地**坐标，而这里被当作**HeldStaff 局部**坐标使用，
##     两者只在 HeldStaff 的旋转近似单位时才重合 → 本圆柱只适合目视近似核对；
##     要判定"杖轴是否穿过拳心"请以 player.gd 的青色握点小球 / [握点一致性] 日志为准。
##   * 运行中打开开关需要再调一次 request_place()，否则不会新建。
## 圆柱挂在 HeldStaff 自身：+Y 就是杖身方向，原点就是挂点（= 握点）
func _add_grip_debug_cylinder(r_local: float, grip_pos: Vector3) -> void:
	# 幂等：调试圆柱只在第一次摆放时创建，避免每次 request_place() 都堆一根出来
	if _grip_cyl_done:
		return
	_grip_cyl_done = true
	# 网格与材质都在运行时 new，不落任何资源文件（纯调试件，换杖时随 _clear() 一起释放）
	var mi := MeshInstance3D.new()
	mi.name = "GripDebugCylinder"
	var cyl := CylinderMesh.new()
	cyl.top_radius = maxf(0.0005, r_local)
	cyl.bottom_radius = maxf(0.0005, r_local)
	cyl.height = 0.14 / maxf(0.0001, _parent_scale)     # 世界 14 cm 长的一段杖身
	# 分段数 24 已经足够圆；rings = 1（圆柱侧壁没有纵向细分，省顶点）
	cyl.radial_segments = 24
	cyl.rings = 1
	mi.mesh = cyl
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.15, 1.0, 0.35, 0.5)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# 关闭深度测试：让圆柱能"穿透"手掌与杖的网格被看见（否则大半截会被挡在模型内部 ✗）
	mat.no_depth_test = true
	mi.material_override = mat
	mi.position = grip_pos
	add_child(mi)
	print("HeldStaff | 调试圆柱：世界半径 %.2f cm｜长 14.0 cm｜中心 %s（杖身轴线经过点）✓" % [
		r_local * _parent_scale * 100.0,
		str(grip_pos.snapped(Vector3(0.001, 0.001, 0.001)))])
# ★ 生效范围（重要）：只有 world_stable ≈ 0（旧的"刚性跟手"模式）时，_apply_pose() 才会用它
#   标定 _local_basis。默认 world_stable = 1.0（世界稳定伺服）时朝向由伺服独占，
#   此时改 hold_rot_deg 只影响首帧标定与日志，看不出朝向差别（位置始终不受影响）。
#   想手工决定握法 → 把 world_stable 设为 0。
## 握持角（相对手骨的固定旋转，度）：由 tools/solve_staff_hold.gd 从参考动作解出。
## 非零时直接用它当本地朝向（不再用"骨骼 rest + 世界前倾"那套标定）。
var hold_rot_deg := Vector3.ZERO

# ---- 展示姿态 ----
## 默认从竖直朝角色正前方倒 60°（用户要求）
const FORWARD_TILT_DEG := 60.0
## 奔跑时再往前挥一档 + 一点正弦摆动
## 全速奔跑时额外前倾的角度（度）：正 = 杖头朝前压、杖尾向后。按速度 0→1 线性渐变，
## 所以半速时只加一半。改大 → 跑起来杖身更前伸（观感更"冲锋"）。
const RUN_TILT_DEG := 22.0
## 奔跑时叠加的正弦摆动幅度（度）：随 _run_phase 往复，给跑动姿态加一点"晃杖"的活气。
## 0 = 摆动完全关掉（只剩恒定的 RUN_TILT_DEG 前倾）。
const RUN_SWING_DEG := 7.0
## 上述正弦摆动的频率（Hz，每秒循环几圈）。1.9 Hz 的步频感（推测：对齐奔腾节奏，非步频严格同步）。
const RUN_SWING_HZ := 1.9
## 达到这个水平速度算全速（角色走 5.0 / 跑 9.0）
const RUN_FULL_SPEED := 9.0

## 悬浮的角速度（弧度/秒）：_hover_t += delta * HOVER_SPEED，再取 sin。
## 1.5 rad/s ≈ 0.24 Hz（一个上下往复约 4.2 s），慢到像"呼吸"而不是"抖动"。
const HOVER_SPEED := 1.5
## 悬浮振幅（**世界米**）：0.020 = 上下各 ±2 cm。乘进局部前会除以 _world_to_local()，
## 所以无论法杖被缩放多少，肉眼看到的浮动距离都是 2 cm（改大 → 杖在手里"浮"得更明显）。
const HOVER_AMOUNT := 0.020
## 杖头发光脉冲的角速度（弧度/秒）：2.2 rad/s ≈ 0.35 Hz，配合 _glow.light_energy 的 ±35% 起伏。
const PULSE_SPEED := 2.2

## 当前法杖的 id（对应 StaffSystem 里登记的定义）。空字符串 = 未装备/已收起。
var staff_id := ""
## 当前法杖的元素编号（int，具体取值由 StaffSystem 定义）：本文件只拿它去取发光颜色。
var element := 0
## 调试/自检用：>= 0 时直接当作角色速度（跑动姿态的数值验收）
# 负数（默认 -1.0）= 读角色真实速度；注意不能默认 0，否则跑动姿态会被永远判成静止。
var debug_speed := -1.0

## 法杖模型实例（GLB 实例化后的根节点，名字被改成 "Model"）。
## null = 当前没有装备法杖（_clear() 之后 / set_staff("") 之后）；所有逻辑都必须先判空。
var _model: Node3D = null
## 杖头的小灯（OmniLight3D），由 _build_glow() 创建。null = 还没建或已被 _clear() 释放。
## 注意：它挂在 _model 下面，会继承 _model 的缩放，所以距离/尺寸都要除掉缩放来补偿。
var _glow: OmniLight3D = null
## （推测）历史遗留的特效挂点：本文件里只被声明、并在 _clear() 里置空，
## 没有创建处也没有读取处；接法杖特效前先确认是否真的没人用。
var _fx: Node3D = null
## 模型的原始高度（**模型局部单位**，未缩放前），由 _place() 从合并 AABB 量出。
## 用途：算缩放 sc、算杖头位置 _head_local()、以及诊断日志里的世界高度。
## 初值 1.0 只是"还没量过"的安全值 —— 量不到模型时 _place() 会继续保持原尺寸，于是它一直是 1.0。
var _model_h := 1.0          # 模型原始高度（模型局部单位）
## 奔跑摆动相位（弧度，每帧累加），供 _apply_pose() 的 RUN_SWING_DEG * sin(_run_phase) 用。
var _run_phase := 0.0
## 悬浮相位（弧度，每帧累加），供 _process() 的 sin(_hover_t) 用。
var _hover_t := 0.0
## 发光脉冲相位（弧度，每帧累加），供 sin(_pulse) 调 _glow.light_energy 用。
var _pulse := 0.0
## 父节点（挂点 HandSocket / BoneAttachment3D）的世界缩放，由 _place() 实测后存入。
## 模型局部单位 → 世界米 = _model.scale × _parent_scale，所以它是所有尺寸换算的分母。
## 初值 1.0 只是"尚未量过"的安全值；实测值会被夹到最小 0.0001 以避免除零。
var _parent_scale := 1.0
## 握点偏移（模型局部单位，负值）。_place() 里量出来存下，_process 的悬浮基于它。
var _grip_y := 0.0
## "请求重新摆放"标志：置 true 后，下一帧 _process 会先走 _place() + _build_glow() 然后 return。
## 为什么必须延后一帧：刚 add_child 的当帧父链 global 变换尚未刷新（Godot 惰性求值），
## 立刻量会读到入树前的旧值（父级缩放被读成 1.0），法杖只有目标的 0.368 倍高。
var _need_place := false
## "悬浮基准"日志只打一次的哨兵（本身不改变行为），避免每帧刷同一条日志。
var _hover_logged := false


## 请求"重新摆放"（下一帧重新量模型/重算握点）。运行中改 grip_offset 后调用即可生效。
## 参数：无。返回值：无（void）。
## 副作用：只置 _need_place = true —— 真正的重算发生在**下一帧** _process 的 _need_place 分支里：
##   _place() 重新量 AABB / 重算缩放与握点，_build_glow(_pending_glow) 重建杖头发光。
## 调用时机：player.gd 挂载后、运行中改了 grip_offset / grip_frac / len_scale 之后，或调试时。
## 注意：重复调用不会叠加（只是单个布尔标志）；但每重摆一次都会**重建** Glow/SparkCore，不复用旧的。
func request_place() -> void:
	_need_place = true
## 挂起中的法杖定义字典（StaffSystem.call("get_def", id) 的返回值），由 set_staff() 暂存。
## 为什么要缓存：set_staff() 当帧不能量模型（父链变换未就绪），摆放被推到下一帧，
## 而 _build_glow() 还需要定义/元素信息 → 只能先存这里，等 _place() 之后再取用。
## {} = 没有待建的发光体（收起、换杖失败、或刚被消费掉）。
var _pending_glow: Dictionary = {}


# ==================== 生命周期 ====================
## Godot 生命周期回调：本节点进入场景树时调用一次。
## 这里只做一件事：显式打开每帧处理（朝向伺服 / 悬浮 / 光脉冲都依赖 _process）。
## 参数：无。返回值：无。副作用：set_process(true)，此后 _process(delta) 每帧被调用。
## 注意：不要在这里量模型或读 global 变换 —— 该时机仍早于父链变换就绪（见 _need_place 的说明）。
func _ready() -> void:
	set_process(true)


# ============================================================ 装配

## 换杖（id 为空 = 收起）
## 作用：清掉旧模型 → 从 StaffSystem 取定义 → 实例化 GLB → 挂到本节点，并请求下一帧摆放。
## 参数：
##   id   —— StaffSystem 里登记的 id；"" 表示收起（手里不放任何东西）
##   elem —— 元素编号（int，取值由 StaffSystem 定义），只用来决定发光颜色
## 返回值：无（void）。
## 副作用：_clear()（移除并 queue_free 旧模型）、把 _local_ok 置 false（朝向需重新标定）、
##   写 staff_id / element、add_child 新模型、置 _need_place = true、缓存 _pending_glow = 定义字典。
## 调用时机：player.gd 装备 / 切换 / 收起法杖时。**同一帧内不要连调两次**：两个模型都会挂在树上，
##   而 _model 只指向后者（目前靠调用方保证只调一次）。
## 失败路径（都会直接 return，此时旧模型已被清掉 = 手里没有杖）：
##   * id == ""                    → 正常的"收起"
##   * 取不到 /root/StaffSystem    → 静默返回（不 push_warning，方便在没有单例的工具场景里跑）
##   * get_def 返回空字典          → push_warning("没有登记过的法杖 id=…")
##   * model 路径为空 / 资源不存在 → push_warning("模型不存在 …")
##   * 实例化结果不是 Node3D       → 静默返回
## 注意：这里**故意不量任何 global 变换**（当帧读到的是脏值），尺寸与握点全部交给下一帧 _place()。
func set_staff(id: String, elem: int) -> void:
	_local_ok = false      # 换杖 -> 重新标定局部朝向
	staff_id = id
	element = elem
	_clear()
	if id == "":
		return
	var sys := _staff_system()
	if sys == null:
		return
	var d: Dictionary = sys.call("get_def", id)
	if d.is_empty():
		push_warning("HeldStaff: 没有登记过的法杖 id=%s" % id)
		return
	var path := str(d.get("model", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("HeldStaff: 模型不存在 %s" % path)
		return
	var scene: PackedScene = load(path)
	_model = scene.instantiate() as Node3D
	if _model == null:
		return
	_model.name = "Model"
	_pivot_add(_model)
	# **不在这一帧量**：global 变换是惰性求值的，刚 add_child 完读父级 global 拿到的是
	# 入树前的值（父级 Visual 的 0.368 缩放会读成 1.0），于是杖只有目标的 0.368 倍高。
	# 实测：1.45m 的杖在游戏里只有 0.53m，截图里几乎看不见。交给下一帧的 _process。
	_need_place = true
	_pending_glow = d


## 把法杖模型挂进本节点的子树（唯一的挂载点）。
## 参数：n —— 要挂的节点（通常是 set_staff() 实例化出来的法杖模型根）。
## 返回值：无。副作用：n 进入本节点子树 → 继承本节点的朝向与缩放（本节点在父链上是手骨挂点）。
## 为什么单独包一层：历史上这里会插入一层 pivot 来对齐"歪轴"的旧 GLB；
## 新模型的轴已经规范（局部 +Y = 杖身、原点在杖底中心），所以现在它只是 add_child 的直通壳。
## 注意：真正的尺寸/握点摆放不在这里，而在 _place()；改挂载方式前请先看文件头的不变量。
func _pivot_add(n: Node) -> void:
	add_child(n)


## 量模型（**沿局部 transform 累乘**，不用 global_transform —— 它入树后要等一帧
## 才刷新，当帧读到的是脏值），然后定尺寸与握点。
##
## 执行顺序：
##   1. 自上而下对整条祖先链 force_update_transform()，再读父节点世界缩放存进 _parent_scale
##   2. 收集所有 MeshInstance3D 的局部 AABB → 合并成 bb（**模型局部空间**）
##      —— 量不到（空、或高度 < 0.05）→ push_warning 后**保持原始尺寸**返回
##   3. 缩放 sc = 目标世界长 / (_model_h × _parent_scale)，写 _model.scale = ONE * sc
##   4. 握点高度 gy = bb.position.y + gf × bb.size.y（flip_in_hand 时 gf 取 1 - grip_frac）
##   5. _shaft_slice(gy, band) 量"握点高度切片"的轴线 (cx, cz) 与平均半径 shaft_r
##   6. 半径补偿：out_dir 非零且量到半径 → _model.position += out_dir × (shaft_r × sc)
##   7. 可选：建调试圆柱；记录 _grip_y = -gy * sc（悬浮的基准）
##   8. 最终摆放 _model.position = Vector3(-cx*sc, _grip_y, -cz*sc)（再叠加手动 grip_out）
## 参数：无。返回值：无。
## 副作用：写 _parent_scale / _model_h / _model.scale / _model.position / _grip_y；
##   可能 add_child 调试圆柱；可能 push_warning；debug_verbose 时 print 诊断日志。
## 调用时机：**只在** _process 的 _need_place 分支里调用（= 挂载后的下一帧），不要手动提前调。
## 注意：
##   * 不要在这里把 grip_offset 加进 _model.position：握点由**父节点的 position** 承担，
##     加在这里既双重偏移、又会被杖的旋转带歪（详见技术文档 §11.8）。
##   * 本函数不改本节点(HeldStaff)的 basis —— 朝向由 _process / _apply_pose 负责。
func _place() -> void:
	# 自上而下刷新：自下而上调用 force_update_transform 时，下层用的是父级的旧值
	var chain: Array = []
	var n: Node = self
	while n != null:
		chain.append(n)
		n = n.get_parent()
	for i in range(chain.size() - 1, -1, -1):
		if chain[i] is Node3D:
			(chain[i] as Node3D).force_update_transform()
	var pn := get_parent()
	if pn is Node3D:
		_parent_scale = maxf(0.0001, (pn as Node3D).global_transform.basis.get_scale().x)
	var boxes := _mesh_aabbs(_model)
	var bb := _merge_aabbs(boxes)
	# 0.05 是"明显不是一根杖"的下限：量不到或小得离谱时宁可不缩放直接返回，
	# 否则 sc = want / (极小高度) 会算出天文数字，把法杖缩成看不见或撑爆画面
	if boxes.is_empty() or bb.size.y < 0.05:
		push_warning("HeldStaff: 量不到模型包围盒，保持原始尺寸")
		return
	_model_h = bb.size.y
	# 模型局部单位 -> 世界米 = _model.scale * _parent_scale
	# 所以要让世界高度等于目标长度：scale = 目标 / (原始高 * 父级缩放)
	var want := float(_sys_def().get("world_len", staff_len)) * len_scale
	var sc := want / (_model_h * _parent_scale)
	_model.scale = Vector3.ONE * sc
	# 水平居中 + 把"杖身下三分之一处"对到挂点
	# ★ flip_in_hand 会把模型绕挂点转 180°（修"杖头朝下"），此时握点比例必须取反：
	#   否则手会抓在靠近杖头的位置、杖身从手里垂下去（"法杖姿势不对"）。
	var gf := (1.0 - grip_frac) if flip_in_hand else grip_frac
	var gy := bb.position.y + gf * bb.size.y
	# ★ 杖身轴线与粗细：用"握点高度切片"量，而不是整模型包围盒中心
	#   （花/龙饰会把包围盒撑宽，只看包围盒会让杖身偏出手心）
	var cx := bb.position.x + bb.size.x * 0.5
	var cz := bb.position.z + bb.size.z * 0.5
	var shaft_r := 0.0
	# 切片带宽取杖高的 10%（下限 0.05）：太窄会取不到足够顶点（_shaft_slice 要求 >= 8 个），
	# 太宽则会把花/龙饰的顶点一起平均进来，反而把轴线算偏
	var slice := _shaft_slice(gy, maxf(0.05, bb.size.y * 0.10))
	var slice_n := 0
	if slice.size() >= 3:
		cx = float(slice[0])
		cz = float(slice[1])
		shaft_r = float(slice[2])
		slice_n = int(slice[3]) if slice.size() > 3 else 0
	# ★ 半径补偿：握点在"拳心"时，杖的**表面**会压进掌心 —— 需要沿掌心外法线
	#   再推出一个"杖身半径"，让杆的表面正好贴着掌心。方向由 player.gd 算好
	#   （朝手指卷曲那一侧，用指尖位置判定），这里只需要乘上实测半径。
	if out_dir.length() > 0.0001 and shaft_r > 0.0:
		var w_local := shaft_r * sc                    # = 世界半径 ÷ 父级缩放
		_model.position += out_dir.normalized() * w_local
		if debug_verbose:
			print("HeldStaff | 半径补偿：沿掌心外法线推出 %.2f cm（实测杖径 %.2f cm）" % [
				w_local * _parent_scale * 100.0, shaft_r * 2.0 * sc * _parent_scale * 100.0])
	# 调试圆柱：与杖同粗、同朝向、同握点 —— 用来目视核对"位置/朝向/半径"三件事
	if debug_grip_cylinder:
		# ★ 圆柱中心 = 杖身轴线经过的点 = grip_offset +（半径补偿的位移）
		#   注意不能用 _model.position：那是法杖**模型底部**的偏移（为了让握点落到原点）
		var grip_local := grip_offset
		if out_dir.length() > 0.0001 and shaft_r > 0.0:
			grip_local = grip_offset + out_dir.normalized() * (shaft_r * sc)
		_add_grip_debug_cylinder(shaft_r * sc if shaft_r > 0.0 else 0.01, grip_local)
	_grip_y = -gy * sc                     # 存下来：悬浮是在这个基准上叠加
	# ★ 握点偏移由**父节点（挂点）的 position** 承担 —— 见 player.gd: held_staff.position = 握点。
	#   这里**不能再加** grip_offset ✗：_model.position 属于 HeldStaff 的局部空间，
	#   而那个空间带着**杖的朝向** → 偏移会被杖的旋转带歪（症状：杖轴偏出掌心几厘米 ✗）。
	_model.position = Vector3(-cx * sc, _grip_y, -cz * sc)
	# 杖身半径外移（沿手骨的本地 X 轴；正负号不合就传负值）：
	# 让"杖的轴线"落在掌心外侧约一个半径处，杖身才不会插进手里。
	if absf(grip_out) > 0.0001:
		_model.position.x += grip_out / _parent_scale
		print("HeldStaff | 杖身半径外移 %.1f cm（世界）" % (grip_out * 100.0))
	if debug_verbose:
		print("HeldStaff | 握点比例 %.2f（翻转=%s）｜世界长 %.3f m｜握点处杖径 ≈ %.2f cm｜切片顶点 %d｜原点离挂点 %.3f m" % [
			gf, str(flip_in_hand), _model_h * sc * _parent_scale,
			shaft_r * 2.0 * sc * _parent_scale * 100.0,
			slice_n,
			absf(_grip_y) * _parent_scale])
	if grip_offset.length() > 0.0001:
		if debug_verbose:
			print("HeldStaff | 应用掌心偏移 %s（骨内单位，约 %.1f cm 世界）" % [
				str(grip_offset.snapped(Vector3(0.001, 0.001, 0.001))), grip_offset.length() * _parent_scale * 100.0])


# ==================== 内部工具：StaffSystem 查询与清理 ====================
## 取当前法杖的定义字典（等价于 StaffSystem.call("get_def", staff_id)）。
## 参数：无 —— 用成员 staff_id 去查（staff_id 为空时返回什么由 StaffSystem 决定）。
## 返回值：Dictionary；**没有 StaffSystem 单例时返回空字典 {}**，调用方必须容忍空字典。
## 副作用：无（只读查询）。
## 调用时机：_place()（取 world_len）与标定完成时的诊断日志里。
## 注意：不做缓存，每次进单例查一遍；只在摆放 / 打日志时调用，不在每帧的热路径上。
func _sys_def() -> Dictionary:
	var sys := _staff_system()
	return {} if sys == null else sys.call("get_def", staff_id)


## 取 StaffSystem 单例节点（autoload 路径 "/root/StaffSystem"）。
## 返回值：Node；**不存在时返回 null**，所以所有调用点都必须判空。
## 副作用：无。
## 为什么用 get_node_or_null 而不是 get_node：单例缺失时只退化成"没有法杖数据"，
##   不会抛错打断调用方（工具场景 / 单元脚本里常常没有 autoload）。
## 这也是本文件与法杖数据系统之间**唯一**的耦合点。
func _staff_system() -> Node:
	return get_node_or_null("/root/StaffSystem")


## 卸掉当前法杖模型及挂在它下面的表现件（收起法杖 / 换杖前会调用）。
## 参数：无。返回值：无。
## 副作用：_model / _glow / _fx 全部置 null；remove_child + queue_free() 掉模型，
##   于是挂在模型下的 Glow(灯) 与 SparkCore(自发光球) 会随模型一起释放。
##   （_fx 只是跟着置空：本文件里没有节点被它引用。）
## 注意：
##   * **先 remove_child 再 queue_free**：立刻脱离场景树，避免本帧后续逻辑又遍历到它。
##   * queue_free() 是延迟释放（本帧末才真正删），但引用已清空 → 不会误用。
##   * 本函数**不**重置 staff_id / element（那是 set_staff() 的职责），也不动 _need_place。
func _clear() -> void:
	if _model != null:
		var m := _model
		_model = null
		_glow = null
		_fx = null
		remove_child(m)
		m.queue_free()


# ==================== 杖头表现：灯 + 自发光光点 ====================
## 杖头位置（模型局部）：朝 +Y 走 88% 处
## 为什么是 88% 而不是 100%：（推测）杖顶那 12% 多半是法球/花饰的几何，
##   从 88% 处开始摆灯与光点才不会把装饰"糊住"。
## 参数：无。返回值：Vector3 —— **_model 的局部空间**坐标（既不是 HeldStaff 局部，也不是世界）。
## 副作用：无（纯计算）。调用时机：_build_glow() 里摆灯与摆光点各用一次。
## 注意：依赖 _model_h（模型原始高度），所以必须在 _place() 量完模型之后调用；_model 为 null 时别调。
func _head_local() -> Vector3:
	return Vector3(0.0, 0.88 * _model_h, 0.0)


## 建杖头表现：一盏 OmniLight3D("Glow") 小灯 + 一个自发光小球("SparkCore")，都挂到 _model 下。
## 参数：d —— 法杖定义字典（当前实现只承接传参这一动作：颜色取自 _elem_color(element)，
##   所以即使传空字典也能正常建出灯与球）。
## 返回值：无。
## 副作用：向 _model 添加两个子节点，并写成员 _glow（脉冲每帧改它的 light_energy）。
##   位置用的是 _head_local() → **必须在模型量过尺寸之后调用**，否则 _model_h 还是默认值。
##   _model == null（收起状态）时直接返回，什么都不建。
## 调用时机：只在 _process 的 _need_place 分支中、紧跟 _place() 之后，参数是缓存的 _pending_glow。
## 注意：**本函数不幂等** —— 每调一次就多加一灯一球（灯会叠加变亮）；只有 _clear() 能清掉它们。
func _build_glow(d: Dictionary) -> void:
	if _model == null:
		return
	var col := _elem_color(element)
	# 杖头小灯：让杖在夜里也有存在感
	_glow = OmniLight3D.new()
	_glow.name = "Glow"
	_glow.light_color = col
	_glow.omni_range = 3.0
	_glow.light_energy = 1.1
	_glow.shadow_enabled = false
	# hs = 模型在 HeldStaff 局部的缩放。灯与球都是 _model 的子节点，会**继承**这层缩放，
	# 所以凡是想按"世界尺寸"给的值都必须除回去（hs × _parent_scale = 模型局部 → 世界）
	var hs := _model.scale.x
	# 在 88% 的基础上再乘 0.92 → 落在模型约 81% 高度处（推测：让灯芯落在杖杆上、不露在杖顶几何外面）
	_glow.position = _head_local() * 0.92
	# 上面那行 3.0 只是"世界 3 m 照射范围"的直觉常量（紧接着被覆盖）；真正生效的是这一行的换算结果
	_glow.omni_range = 3.0 / maxf(0.05, hs * _parent_scale)
	_model.add_child(_glow)
	# 杖头光点：一个小小的自发光球，比纯灯光更像"宝石在发亮"
	var mi := MeshInstance3D.new()
	mi.name = "SparkCore"
	var sm := SphereMesh.new()
	# 目标世界半径 3 cm；同样要除掉缩放（球挂在 _model 下，会继承模型缩放）
	var r := 0.030 / maxf(0.05, hs * _parent_scale)
	sm.radius = r
	sm.height = r * 2.0
	sm.radial_segments = 12
	sm.rings = 6
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.emission_enabled = true
	mat.emission = col
	mat.emission_energy_multiplier = 3.0
	mi.material_override = mat
	mi.position = _head_local()
	_model.add_child(mi)


## 按元素编号取发光颜色（灯与光点共用）。
## 参数：e —— 元素编号（int，具体含义由 StaffSystem 定义；本文件只做转发）。
## 返回值：Color；**取不到 StaffSystem 时返回默认淡紫 Color(0.86, 0.74, 1.0)**，保证永远有颜色可用。
## 副作用：无。
## 调用时机：_build_glow() 里各调一次（灯色与自发光色）。
## 注意：这里是 call("element_color", e) 弱调用 —— 它只兜住"没有单例"，**兜不住"方法被改名"**
##   （改名后 call() 会报错并返回 null，而本函数声明返回 Color）。改 StaffSystem 时记得同步这里。
func _elem_color(e: int) -> Color:
	var sys := _staff_system()
	if sys != null:
		return sys.call("element_color", e)
	return Color(0.86, 0.74, 1.0)


# ============================================================ 每帧

## 每帧主循环：先保证"摆好"，再做朝向稳定，最后叠加悬浮与光脉冲。
## 参数：delta —— 距上一帧的秒数（Godot 传入）。它只参与相位累加与伺服的 k 比例，不影响目标角度。
## 返回值：无。
## 副作用：写本节点 basis（伺服）、写 _model.position.y（悬浮）、写 _glow.light_energy（脉冲）；
##   首帧还会建节点（_place() / _build_glow()）；debug_verbose 时可能打印一次悬浮基准日志。
## 执行顺序：
##   ① _model 为空或不在场景树 → 直接返回（收起状态 / 还没挂好）
##   ② _need_place → 走 _place() + _build_glow(_pending_glow) 后 **return**（这一帧不做姿态与悬浮）
##   ③ _apply_pose(delta)：旧模式的标定，并在 world_stable ≈ 0 时写局部朝向
##   ④ world_stable > 0 → 误差伺服：把**当前杖身方向**逐步拉向"世界竖直 + 沿角色朝向的前后倾"
##   ⑤ 悬浮：_model.position.y = _grip_y + sin(_hover_t) × HOVER_AMOUNT / _world_to_local()
##   ⑥ 光脉冲：_glow.light_energy = (1 + 0.35·sin(_pulse)) × 1.1
## 注意：
##   * 第 ④ 步**只改本节点局部 basis 的旋转、缩放原样写回**，绝不读写 global_transform ——
##     写 global 会连带重算位置（与手骨打架 → 抖动）并让缩放逐帧累积（法杖越变越大）。
##   * 第 ④ 步与 _apply_pose 的写朝向是**排他**的（world_stable > 0 时 _apply_pose 不写朝向），
##     否则两边每帧互相覆盖 → 稳态仍以跟手为主 + 抖动。
##   * 第 ⑤ 步是在**模型局部 Y** 上叠加（单位也是模型局部单位，所以除 _world_to_local() 换成世界距离）；
##     默认世界里这条轴已被伺服摆到接近世界竖直，所以看上去仍像"沿竖直上下呼吸"。
func _process(delta: float) -> void:
	# 双保险：_model 为空（收起/换杖中）或已脱离场景树（正在被 queue_free）时都不要继续 ——
	# 对游离节点读 global_transform 会拿到无意义的值，伺服会把它当成误差乱转
	if _model == null or not _model.is_inside_tree():
		return
	if _need_place:
		# 入树后第一帧才量：这时父链的 global 变换已经刷新过了
		_need_place = false
		_place()
		_build_glow(_pending_glow)
		_pending_glow = {}
		return
	_apply_pose(delta)
	# ★ 世界朝向稳定（"松握"）：位置仍然跟手 ✓（父节点就是手骨 ✓），
	#   但把**朝向**钉回世界空间 —— 跑步时杖不再跟着手臂前后甩 ✗
	#   原理：模型的"握点"被摆在 HeldStaff 原点 ✓ → 绕原点旋转**不会**让握点离开手心 ✓
	if world_stable > 0.0001:
		# ★ 目标朝向 = 世界竖直 + 沿**角色朝向**的前后倾：
		#   站立 → 基本竖直 ✓；跑动 → 杖头朝前 / **杖尾向后拖** ✓（按速度渐变 ✓）
		#   注意：倾斜必须沿角色朝向 ✗不要绕世界 X 轴（那样方向会随角色转身而错 ✓）
		var run_f := clampf(_owner_speed() / RUN_FULL_SPEED, 0.0, 1.0)
		var deg_w := world_lean_deg + world_run_lean_deg * run_f
		var tilt_w := deg_to_rad(deg_w)
		var fwd_w := _facing()
		if fwd_w.length() < 0.001:
			fwd_w = Vector3.BACK
		fwd_w = fwd_w.normalized()
		var ycol_w := (Vector3.UP * cos(tilt_w) + fwd_w * sin(tilt_w)).normalized()
		var zcol_w := (-fwd_w - ycol_w * (-fwd_w).dot(ycol_w))
		if zcol_w.length() < 0.001:
			zcol_w = Vector3.BACK
		zcol_w = zcol_w.normalized()
		var xcol_w := ycol_w.cross(zcol_w).normalized()
		var up_basis := Basis(xcol_w, ycol_w, zcol_w)
		if flip_in_hand:
			up_basis = up_basis * Basis(Vector3.RIGHT, PI)
		# ★★ 只改**本节点的局部旋转** ✓ —— 绝对不要读写 global_transform ✗：
		#   ① 写 global 会连带重算**位置** → 与手骨的运动打架 → 抖动 ✗
		#   ② 全局↔局部换算里带缩放（BoneAttachment 的换算不干净）→ 缩放逐帧累积 →
		#      法杖"越变越大" ✗✗（v3 的 bug）
		#   ③ 本节点自己的 basis.get_scale() 是**稳定值**（挂载/摆放时定好的 ✓），
		#      所以用它的逆运算做"世界 → 局部"是安全的 ✓ 不会形成反馈 ✗
		var par := get_parent() as Node3D
		if par != null:
			# ★★ 误差伺服（最稳 ✓）：不猜"局部目标" ✗（模型自身还有一层内部旋转 ✗），
			#   而是每帧**量出当前杖身方向** → 算出把它转到目标方向所需的旋转 →
			#   只叠加 k 比例 ✓。这样对未知的内部旋转/缩放都免疫 ✓，也绝不会累积 ✗。
			# ★ 这里是全文件**唯一**读 global_transform 的地方，而且是"只读地量方向"：
			#   读不会改变节点状态，所以既不抖、也不会累积缩放；千万别在这里把结果写回去 ✗
			var cur_dir := _model.global_transform.basis.y.normalized()   # 模型 +Y = 杖身 ✓
			# 0.99995 ≈ 夹角 0.57°：已经对齐就跳过 —— 两个近乎同向的向量求 Quaternion(a, b)
			# 是退化情形（旋转轴不确定），会算出抖动甚至 NaN 的旋转增量
			if cur_dir.length() > 0.0001 and absf(cur_dir.dot(ycol_w)) < 0.99995:
				var q := Quaternion(cur_dir, ycol_w)          # 当前方向 → 目标方向 的旋转 ✓
				var delta_rot := Basis(q)
				var par_rot := _pure_rot(par.global_transform.basis)
				# 世界旋转差 → 本节点的局部旋转差（左乘父级旋转的逆、右乘父级旋转 ✓）
				var local_delta := par_rot.inverse() * delta_rot * par_rot
				var sc_now := basis.get_scale()               # 只读**自己**的缩放 ✓（不回读全局 ✗）
				# 比例伺服增益 8.0（单位 1/秒）：k = world_stable × delta × 8 → 60fps 下每帧约 13%，
				# 约 0.5 s 收敛。只有比例项、没有速度项，所以是"指数逼近"不会过冲（极端速度下会有轻微滞后）
				var k := clampf(world_stable * delta * 8.0, 0.0, 1.0)
				# 局部：右乘"阻尼后的旋转增量" ✓（只动旋转 ✓ 缩放原样写回 ✓）
				basis = (_pure_rot(basis) * Basis.IDENTITY.slerp(local_delta, k)).scaled(sc_now)
	# 悬浮：沿世界竖直轻轻上下（不是模型局部轴 —— 那个已经被倾斜过了）
	_hover_t += delta * HOVER_SPEED
	# ★ 握点偏移已改由父节点 position 承担 ✓ → 这里不能再加 grip_offset（否则双重偏移 ✗）
	_model.position.y = _grip_y + sin(_hover_t) * HOVER_AMOUNT / _world_to_local()
	if not _hover_logged:
		_hover_logged = true
		if debug_verbose:
			print("HeldStaff | 悬浮基准 = _grip_y %.3f + 握点 Y %.3f → 模型 Y %.3f（不再丢偏移 ✓）" % [
				_grip_y, grip_offset.y, _model.position.y])
	if _glow != null:
		_pulse += delta * PULSE_SPEED
		# 基线 1.1 与 _build_glow() 里的 light_energy 初值保持一致，±35% 才是"呼吸"而不是跳变
		_glow.light_energy = (1.0 + 0.35 * sin(_pulse)) * 1.1


## 取出 basis 的纯旋转（只去掉缩放，保留旋转方向 ✓）
## 参数：b —— 任意可能带缩放的 Basis。返回值：Basis —— 只保留旋转方向的（单位正交）basis。
## 副作用：无（纯函数）。
## 为什么必须用它而不是 b.orthonormalized()：后者会把缩放**抹成 1**，而法杖的缩放就藏在 basis 里 ——
##   一旦被抹掉就会"撑满全屏"。本函数逐轴除以各自长度：只去缩放，不动旋转轴方向。
## 注意：分母用 maxf(absf(s), 1e-6) 兜底，避免某轴缩放为 0（退化矩阵）时除出 INF/NaN。
##   某轴长度为负（镜像）时方向会翻转，属预期外输入，正常挂载不会出现。
func _pure_rot(b: Basis) -> Basis:
	var s := b.get_scale()
	return Basis(
		b.x / maxf(absf(s.x), 0.000001),
		b.y / maxf(absf(s.y), 0.000001),
		b.z / maxf(absf(s.z), 0.000001))


## 换算系数：1 个**模型局部单位**等于多少世界米（= 本节点 global 缩放 × _model.scale）。
## 参数：无。
## 返回值：float；**下限 0.0001**（模型尚未缩放或缩放近 0 时避免除零 → 悬浮量爆成 INF/NaN）。
## 副作用：无（只读）。
## 调用时机：_process 的悬浮一行 —— 把 HOVER_AMOUNT（世界米）换成模型局部单位。
## 注意：这里读的是本节点自己的 global_transform（只读）。"不要碰 global"指的是**不要写**；
##   而本节点的缩放自挂载后不再变化，所以读它不会形成反馈。
func _world_to_local() -> float:
	# 1 模型局部单位 = 多少世界米
	var s := global_transform.basis.get_scale().x * _model.scale.x
	return maxf(0.0001, s)


## 法杖在手里上下翻转 180°（修「杖头朝下 / 反向握」）。检查器里一键切换。
## 参数：无（导出的 bool 属性，检查器可勾选；默认 false = 按模型原始朝向握）。
## 生效点是**两处**，改代码时必须同时顾及：
##   ① _place()：翻转时握点比例取 1 - grip_frac（否则手会抓在靠近杖头处、杖身从手里垂下去）
##   ② _apply_pose() / _process 伺服：目标 basis 再右乘 Basis(RIGHT, PI)
## 为什么是绕 X 轴转 π：模型局部 +Y 就是杖身方向，绕 X 轴 180° 正好把 +Y 变成 -Y ——
##   "杖头朝下 ↔ 朝上"互换，而杖身轴线仍然落在原来的直线上。
## 注意：它改的是朝向与握点比例，不改变尺寸/半径补偿；换新杖模型后若"杖头朝下"，
##   优先勾这个开关，而不是去改 grip_frac 或各角度常量。
@export var flip_in_hand := false

## 手骨局部朝向（标定一次）——「刚性固定在手上」就靠它
## 补充：只在 world_stable ≈ 0（旧刚性跟手模式）下使用；标定成功后不再重算。
## 内容是"想要的世界朝向"换算到手骨局部的结果；之后每帧 basis = _local_basis.scaled(保留的缩放)。
var _local_basis := Basis.IDENTITY
## 标定完成标志：false 时 _apply_pose() 每帧都会尝试标定（拿不到骨骼 rest 时会每帧临时算一次），
## true 之后不再重算。set_staff() 换杖时会把它置回 false，强制重新标定。
var _local_ok := false
## （推测）历史残留的自转累加器：本文件里只有这一行声明，没有任何读取或写入处，可忽略。
var _spin := 0.0
## "角色已静止"的连续帧计数：只在**挂点不是 BoneAttachment3D**（拿不到骨骼 rest）时使用 ——
## 要连续 2 帧处于静止才允许锁定标定，否则容易抓到摆臂过程中的某一帧（位置会概率性不对）。
var _idle_ok := 0
## 日志"只打一次"的哨兵（标定完成日志 / 握点诊断日志），避免每帧刷屏。
var _logged := false

# ==================== 姿态标定与朝向 ====================
## 每帧把法杖的**世界朝向**写成目标方向：默认前倾 60°，奔跑时再前挥一档。
## 见文件头说明：法杖挂在会旋转的手骨上，只有绕开局部轴才不会"手往前摆、杖往后甩"。
##
## 实际行为分三种情况（这套分支是历史叠加出来的，读代码时先认清哪一条在生效）：
##   ① 尚未标定（_local_ok == false）：
##        a. hold_rot_deg 非零 → 直接用档案握持角当 _local_basis（写 basis 后 return）
##        b. 挂点是 BoneAttachment3D → 用"骨骼 rest 姿势"换算局部朝向（与当前动画帧无关）
##        c. 否则 → 用"角色静止满 2 帧后的姿势"换算；静止前每帧临时标定，保证至少有姿势
##   ② 默认（world_stable > 0）：本函数**不写朝向**，只做上面的标定；朝向由 _process 的伺服独占
##   ③ world_stable ≈ 0（旧刚性跟随）：每帧写 basis = _local_basis.scaled(保留的缩放) → 完全跟手
## 参数：delta —— 帧间隔（秒）。本函数当前其实用不到 delta，保留签名是为了将来做平滑。
## 返回值：无。
## 副作用：可能写本节点 basis（仅 ①a 与 ③）、写 _local_ok / _local_basis / _logged / _idle_ok；
##   标定成功时**必定**打印一条日志（没有开关控制）。
## 调用时机：_process 每帧第一步（在悬浮与光脉冲之前）。
## 注意：
##   * 标定只做一次：set_staff() 换杖时已把 _local_ok 置 false，所以每次换杖都会重新标定一次。
##   * 用骨骼 **rest** 而不是"当前动画帧"是有意为之：否则切杖那一帧若正在跑动，
##     记下的就是摆臂姿势 → 位置概率性不正确（用户反馈的"反复切换法杖位置会不对"）。
##   * 写 basis 一律 `.scaled(保留的缩放)`，绝不用 orthonormalized()（会抹掉缩放 → 撑满全屏）。
func _apply_pose(delta: float) -> void:
	var fwd := _facing()
	if fwd == Vector3.ZERO:
		return
	_run_phase += delta * TAU * RUN_SWING_HZ
	# run ∈ [0,1] 是"速度比例"，三个角度项都乘它：静止时只剩 FORWARD_TILT_DEG（60°），
	# 全速时再加上 RUN_TILT_DEG 与正弦摆动；_run_phase 不乘 run，所以摆动相位不会因停下而回卷
	var run := clampf(_owner_speed() / RUN_FULL_SPEED, 0.0, 1.0)
	var deg := FORWARD_TILT_DEG + RUN_TILT_DEG * run \
			+ RUN_SWING_DEG * run * sin(_run_phase)
	var tilt := deg_to_rad(deg)
	# 杖身方向：从世界竖直朝角色正前方倒 tilt
	var ycol := (Vector3.UP * cos(tilt) + fwd * sin(tilt)).normalized()
	# 右手系：z = -fwd（Godot 的"前"是 -Z）正交化到 ycol 上，x = y x z
	var zcol := (-fwd - ycol * (-fwd).dot(ycol))
	if zcol.length() < 0.001:
		zcol = Vector3.BACK
	zcol = zcol.normalized()
	var xcol := ycol.cross(zcol).normalized()
	var want := Basis(xcol, ycol, zcol)
	# 模型自身方向修正：Tripo 出的法杖有的"头"在 -Y、有的在 +Y。
	# 打开就把法杖在手里**上下翻转 180°**（绕模型局部 X 轴），用来修"杖头朝下/反向握"。
	if flip_in_hand:
		want = want * Basis(Vector3.RIGHT, PI)
	# ---- 刚性固定在手上（用户要求）----
	# 原来这里每帧写 `global_transform`（世界朝向），而位置跟着手骨 ——
	# 两者打架：手一摆，法杖就以握点为轴自己转一圈（"按 WASD 就复现"）。
	# 现在只做**一次标定**：把"想要的世界朝向"换算成手骨的局部朝向存下来，
	# 之后只写局部 basis，位置完全交给手骨 —— 手怎么动法杖就怎么动，
	# 这才是"固定在角色手上"。
	var hand := get_parent() as Node3D
	if hand == null:
		return
	if not _local_ok:
		# ★ 优先：用"从参考动作解出的握持角"（相对手骨的固定旋转）。
		#   它是拿 Standing Torch Idle 01 的手骨姿势解出来的，让杖身在那个姿势下竖直 ——
		#   比"骨骼 rest + 世界前倾 60°"更贴合动画的自然握法。
		if hold_rot_deg.length() > 0.01:
			_local_basis = Basis.from_euler(Vector3(
				deg_to_rad(hold_rot_deg.x), deg_to_rad(hold_rot_deg.y), deg_to_rad(hold_rot_deg.z)))
			_local_ok = true
			if not _logged:
				_logged = true
				print("HeldStaff | 用档案握持角 %s（度）标定（解自 %s）" % [str(hold_rot_deg), "Torch Idle"])
			basis = _local_basis.scaled(basis.get_scale())
			return
		# **用骨骼的静止姿势(rest)标定，而不是当前动画帧**。
		# 原来用手骨"当前"的 global basis：切杖那一刻若角色正在走/跑，
		# 记下来的是那一帧的摆臂姿势 -> 法杖位置概率性不对
		# （用户："反复切换法杖，法杖的位置就会有概率不正确"）。
		# 骨骼 rest 与动画无关，所以结果稳定、可复现。
		var rest_basis := Basis.IDENTITY
		var got_rest := false
		var ba := hand as BoneAttachment3D
		if ba != null:
			var skel: Skeleton3D = ba.get_skeleton()
			if skel != null and ba.bone_idx >= 0:
				rest_basis = (skel.global_transform.basis
						* skel.get_bone_global_rest(ba.bone_idx).basis)
				got_rest = true
		if not got_rest:
			# 挂点不是 BoneAttachment3D（拿不到骨骼 rest）：
			# **等角色静止下来再锁定**，避免抓到摆臂中的某一帧。
			# 静止前先每帧临时标定，保证不至于完全没姿势。
			rest_basis = hand.global_transform.basis
			if _owner_speed() > 0.05:
				_idle_ok = 0
			else:
				_idle_ok += 1
			if _idle_ok < 2:
				_local_basis = (rest_basis.inverse() * want).orthonormalized()
				return
		_local_basis = (rest_basis.inverse() * want).orthonormalized()
		_local_ok = true
		if not _logged:
			_logged = true
			print("HeldStaff | 标定完成：%s（%s）" % [
					"骨骼 rest 姿势" if got_rest else "静止姿势",
					"BoneAttachment3D" if got_rest else str(hand.get_class())])
			# 诊断（排查"法杖脱离手臂"用）：世界长度 / 挂点是否真的在杖身上
			var boxes_d := _mesh_aabbs(_model)
			var bb_d := _merge_aabbs(boxes_d)
			var world_h := _model_h * _model.scale.x * _parent_scale
			var gp := _model.global_position
			print("HeldStaff | 世界长 %.3f m（目标 %.3f）｜模型局部高 %.2f｜缩放 %.5f × 父级 %.5f｜模型原点离挂点 %.3f m" % [
				world_h, float(_sys_def().get("world_len", staff_len)) * len_scale,
				_model_h, _model.scale.x, _parent_scale, hand.global_position.distance_to(gp)])
	var sc := basis.get_scale()          # 保留挂载时算好的缩放
	if world_stable <= 0.0001:
		# 旧的刚性跟随：朝向 = 手骨朝向（跑动时会随手臂甩 ✗）
		basis = _local_basis.scaled(sc)
	# ★ world_stable > 0 时这里**不写朝向** ✓ —— 交给 _process 里的"世界朝向稳定"独占：
	#   否则两边每帧互相覆盖 → 稳态仍以跟手为主（跑动时杖尾朝前 ✗）+ 抖动 ✗


## 沿父链向上找角色本体（第一个 CharacterBody3D）。
## 参数：无。
## 返回值：Node3D —— 角色本体；**找不到时返回 null**（法杖挂在非角色节点下时就会这样）。
## 副作用：无。
## 注意：_facing() / _owner_speed() 每帧都会调它；都是纯父链遍历，开销可忽略。
##   不要把它缓存成成员引用 —— 节点被重新挂载（换角色 / 重载场景）后缓存会失效。
func _owner_body() -> Node3D:
	var n := get_parent()
	while n != null:
		if n is CharacterBody3D:
			return n as Node3D
		n = n.get_parent()
	return null


## 角色**面朝**方向（世界空间、水平、已归一化）。
## 参数：无。
## 返回值：Vector3 —— 角色模型 +Z 在水平面的投影；投影太短（< 0.001）或取不到角色时返回 Vector3.ZERO。
## 副作用：无（纯计算）。
## 为什么取 +Z：player.gd 用 atan2(face.x, face.z) 设 rotation.y，即把 face 对齐到模型的 +Z；
##   历史上取的是 -basis.z（= 背面）→ "前倾 60°"变成朝身后倒（用户："杖头应该在身体前，而不是身体后"）。
## 调用时机：_apply_pose() 与 _process 的伺服各一次（同一帧可能算两遍，纯计算，可接受）。
## 注意：先把 y 清零再归一化 —— 这样上下坡 / 模型整体俯仰都不会让"前倾"跟着歪。
func _facing() -> Vector3:
	var b := _owner_body()
	if b == null:
		return Vector3.ZERO
	# 角色**面朝**方向 = 模型的 +Z。
	# player.gd::face_direction() 用 atan2(face.x, face.z) 设 rotation.y，
	# 即把 face 对齐到 +Z（文件里也写着「Mage 模型 +Z 为面部前方」）。
	# 原来取 -basis.z（= 背面），于是「前倾 60°」变成朝身后倒 ——
	# 用户：「杖头应该在身体前，而不是身体后」。
	var f := b.global_transform.basis.z
	f.y = 0.0
	return f.normalized() if f.length() > 0.001 else Vector3.ZERO


## 角色当前**水平**速度（米/秒），是跑动姿态的唯一驱动量。
## 参数：无。
## 返回值：float —— debug_speed >= 0 时直接返回该调试值；否则取角色 velocity 的 XZ 分量长度；
##   取不到角色（_owner_body() 为 null）时返回 0.0。
## 副作用：无。
## 注意：
##   * 只取 XZ：掉落 / 跳跃的竖直速度不会被误判成"在跑"。
##   * 量纲与 RUN_FULL_SPEED = 9.0 对齐（角色走 5.0 / 跑 9.0）。
##   * 调用方都是 `clampf(_owner_speed() / RUN_FULL_SPEED, 0, 1)` → 得到 0~1 的速度比例。
func _owner_speed() -> float:
	if debug_speed >= 0.0:
		return debug_speed
	var b := _owner_body()
	if b == null:
		return 0.0
	return Vector2(b.velocity.x, b.velocity.z).length()


# ============================================================ 包围盒（局部累乘）

## 收集 node 子树里所有 MeshInstance3D 的 AABB，并累乘各自的局部 transform，
## 换到 **node 的局部空间**（不含 node 自己那一层变换）。
## 参数：node —— 通常传 _model（法杖模型根）。
## 返回值：Array（元素是 AABB）；一个网格都没有时返回空数组（_place() 会因此保持原始尺寸）。
## 副作用：无。
## 为什么是"局部 transform 累乘"（`xf = n.transform * xf`，从网格往上一路左乘到 node）：
##   global_transform 入树后要等一帧才刷新，加载当帧读它是脏值（历史上打印出过 715 cm 之类的假数据）。
## 为什么跳过 node 自身的那层变换：量出来的是"几何在 node 局部空间里的盒子"，
##   于是**再次调用也不会被上次写下去的 _model.scale 污染** —— 重摆是幂等的。
## 注意：只统计 MeshInstance3D 的 mesh；碰撞体、CSG、其它可视节点都不算在内。
func _mesh_aabbs(node: Node3D) -> Array:
	var out: Array = []
	for c in node.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D()
		var n: Node = mi
		while n != null and n != node:
			if n is Node3D:
				xf = (n as Node3D).transform * xf
			n = n.get_parent()
		out.append(xf * mi.mesh.get_aabb())
	return out


## 把若干 AABB 合并成一个能包住它们的最小轴对齐盒子。
## 参数：list —— AABB 数组（通常是 _mesh_aabbs() 的返回值）。
## 返回值：AABB；**list 为空时返回 AABB()**（原点 + 零尺寸的默认盒子，_place() 会用 `size.y < 0.05` 判掉）。
## 副作用：无（纯计算）。
## 调用时机：_place()、标定完成时的诊断、debug_info()。
func _merge_aabbs(list: Array) -> AABB:
	if list.is_empty():
		return AABB()
	var bb: AABB = list[0]
	for i in range(1, list.size()):
		bb = bb.merge(list[i])
	return bb


## 取"握点高度附近"的杖身顶点（_model 局部坐标）：返回 [平均 x, 平均 z, 平均半径]
## ★ 为什么不能只用整体包围盒中心：法杖的花/龙饰会把包围盒撑宽，杖身轴线会被带偏。
## 用握点高度切片内的顶点平均，才是"手实际握到的那段杖身"的轴线与粗细。
## 参数：y0 —— 切片中心高度（**_model 局部单位**；_place() 传的是量出来的握点高度 gy）。
##   band —— 半带宽（同一单位；_place() 传 max(0.05, 杖高 × 10%)）→ 实际取 |p.y - y0| <= band 的顶点。
## 返回值：Array —— 有效时是 4 个元素 [cx, cz, 平均半径, 顶点数]；
##   **带内顶点少于 8 个时返回空数组 []**（调用方据此回退到整体包围盒的中心）。
## 副作用：不改状态；debug_slice 为 true 时会对**每个** MeshInstance3D 打一行统计（很吵，默认关）。
## 注意：平均半径 = 带内各顶点到 (cx, cz) 的**水平距离平均值**（不是最大半径，也不是最小二乘圆），
##   所以带内若有花纹凸起会把半径略微抬高一点。
func _shaft_slice(y0: float, band: float) -> Array:
	var sx := 0.0
	var sz := 0.0
	var n := 0
	var pts: Array[Vector2] = []
	for c in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := c as MeshInstance3D
		if mi.mesh == null:
			continue
		var xf := Transform3D()
		var nn: Node = mi
		while nn != null and nn != _model:
			if nn is Node3D:
				xf = (nn as Node3D).transform * xf
			nn = nn.get_parent()
		var mesh_total := 0
		var mesh_in := 0
		var ymin := INF
		var ymax := -INF
		for si in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(si)
			if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
				continue
			var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			mesh_total += verts.size()
			for v in verts:
				var p: Vector3 = xf * v
				ymin = minf(ymin, p.y)
				ymax = maxf(ymax, p.y)
				if absf(p.y - y0) > band:
					continue
				mesh_in += 1
				pts.append(Vector2(p.x, p.z))
				sx += p.x
				sz += p.z
				n += 1
		if debug_slice:
			print("HeldStaff | 切片调试：%s 顶点 %d｜y %.3f~%.3f｜带内 %d（y0=%.3f band=%.3f）" % [
				String(mi.name), mesh_total, ymin, ymax, mesh_in, y0, band])
	if n < 8:
		return []
	var cx := sx / float(n)
	var cz := sz / float(n)
	var r := 0.0
	for p in pts:
		r += p.distance_to(Vector2(cx, cz))
	return [cx, cz, r / float(pts.size()), n]


# ==================== 诊断：角色/相机位置 · 世界包围盒 ====================
## 角色本体的世界坐标（诊断用）。
## 参数：无。返回值：Vector3；**取不到角色时返回 Vector3.ZERO**（无法与"角色恰好在原点"区分，
##   所以 debug_info() 里它只适合当粗略参考）。
## 副作用：无。
func _body_pos() -> Vector3:
	var b := _owner_body()
	return Vector3.ZERO if b == null else b.global_position


## 当前 3D 相机的世界坐标（诊断用：判断"法杖是不是跑到画面外了"）。
## 参数：无。返回值：Vector3；**没有视口或没有当前 3D 相机时返回 Vector3.ZERO**
##   （headless 运行经常就是这种情况，不要把 ZERO 当成"相机在原点"）。
## 副作用：无。
func _cam_pos() -> Vector3:
	var vp := get_viewport()
	if vp == null:
		return Vector3.ZERO
	var c := vp.get_camera_3d()
	return Vector3.ZERO if c == null else c.global_position


## 参数：bb —— **模型局部空间**的 AABB（通常是 _merge_aabbs(_mesh_aabbs(_model)) 的结果）。
## 返回值：AABB —— 世界空间的轴对齐包围盒（8 个角都变换后再取 min/max，所以比只变换中心更准）。
## 副作用：无。调用时机：debug_info()。
## 注意：变换取自 _model.global_transform（只读）；缩放与旋转都已吃进这个盒子里。
# 用下标 i 的 3 个二进制位当"角的方向"（bit0=x / bit1=y / bit2=z）来枚举 8 个角：
# 比手写 8 个 Vector3 更不容易漏角（漏一个角就会算出一个偏小的世界盒）
## 把模型局部包围盒的 8 个角变换到世界，得到世界空间的包围盒
func _world_aabb(bb: AABB) -> AABB:
	var xf := _model.global_transform
	var out := AABB()
	var first := true
	for i in 8:
		var c := bb.position + Vector3(
				bb.size.x * float(i & 1),
				bb.size.y * float((i >> 1) & 1),
				bb.size.z * float((i >> 2) & 1))
		var w := xf * c
		if first:
			out = AABB(w, Vector3.ZERO)
			first = false
		else:
			out = out.expand(w)
	return out


## 诊断：把"到底挂成什么样"打成一行，不靠肉眼猜。
## 参数：无。
## 返回值：Dictionary —— 打包好的自检快照；**_model == null 时只返回 {"ok": false}**。
##   成功时含键：model_h_local / model_scale / world_h / global_scale / up_dot_world_up / fwd_dot /
##   node_pos / model_pos / grip_y / aabb_local / world_aabb / facing / body_pos / cam。
## 副作用：无（只读；会现场再量一遍 AABB，开销约等于 _place() 的测量部分）。
## 调用时机：调试控制台 / 工具脚本**按需**调用，不要每帧调（每帧都会重新遍历所有顶点）。
## 两个判据键：
##   * up_dot_world_up = 杖身方向 · 世界上方：默认配置（world_stable=1、world_lean_deg=0）站立时应接近 1，
##     对应自检日志里"与竖直夹角 ~0~1°"；刚性模式（前倾 60°）时约为 cos60° ≈ 0.5。
##   * fwd_dot = 杖身方向 · 角色面朝方向：反映前后倾的方向与大小（正 = 朝前倒）。
func debug_info() -> Dictionary:
	if _model == null:
		return {"ok": false}
	var boxes := _mesh_aabbs(_model)
	var bb := _merge_aabbs(boxes)
	var gs := _model.global_transform.basis.get_scale()
	var up := (_model.global_transform.basis * Vector3.UP).normalized()
	var facing := _facing()
	return {
		"ok": true,
		"model_h_local": _model_h,
		"model_scale": _model.scale.x,
		"world_h": _model_h * _model.scale.x * _parent_scale,
		"global_scale": gs.x,
		"up_dot_world_up": up.dot(Vector3.UP),
		"fwd_dot": up.dot(facing),
		"node_pos": global_position,
		"model_pos": _model.global_position,
		"grip_y": _grip_y,
		"aabb_local": bb,
		"world_aabb": _world_aabb(bb),
		"facing": facing,
		"body_pos": _body_pos(),
		"cam": _cam_pos(),
	}


## 施法瞬间：杖头闪一下（供技能/长老仪式调用）
## 参数：strength —— 闪光强度倍率（float，默认 1.6）；实际写入的 light_energy = strength × 4.0。
## 返回值：无。
## 副作用：**直接赋值** _glow.light_energy（一次性尖峰），随后 _process 的光脉冲会在接下来几帧
##   把它拉回 1.1 ± 35% 的呼吸区间 —— 所以"衰减"是脉冲逻辑顺带完成的，本函数不做动画。
## 调用时机：施法瞬间 / 长老仪式等事件由外部调用；收起状态（_glow == null）时静默无效。
## 注意：light_energy 没有 clamp —— 调用越密越亮、strength 给大就会很刺眼。
func flash(strength: float = 1.6) -> void:
	if _glow != null:
		_glow.light_energy = strength * 4.0

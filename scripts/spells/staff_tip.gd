# ==============================================================================
# staff_tip.gd —— 法杖"杖头（喷火口）"位置 / 方向 / 尺度的数据驱动计算器
# ------------------------------------------------------------------------------
# 系统归属：法术系统（scripts/spells/）里的**纯静态工具类**。
#   不是 autoload、不挂场景、不注册进任何管理器、不持有任何状态；
#   由使用方以 `const StaffTip := preload("res://scripts/spells/staff_tip.gd")` 的方式取用
#   （见 spell_aim.gd L56），因此**没有任何实例**，也不会被 _ready/_process 驱动。
#   带 @tool 的目的（推测）：让依赖它的视觉脚本在编辑器内预览时也能正常解析本类。
#
# 本文件职责：
#   给定"挂法杖的那个节点"（holder，通常是 HeldStaff），只靠**法杖模型自身的数据**
#   算出杖头的世界坐标、世界朝向、以及一个可用于缩放的"特征长度"。
#   设计目标是"不写死任何坐标"：法杖有大有小（staff_system 中每根都有 scale / world_len），
#   用固定偏移的话小杖会喷在杖身中间、大杖会喷在杖外，所以一切尺寸都从模型实测。
#
# 关键依赖（全为**弱依赖**，本文件不 preload 任何脚本）：
#   · holder 可选能力 _head_local() -> Vector3：由 scripts/held_staff.gd L466 提供，
#     返回 **_model 局部单位**的杖头坐标（朝 +Y 走模型高度的 88% 处）。有它就走快路径。
#   · holder 可选属性 _model: Node3D：由 held_staff.gd 持有的模型根引用，用动态 get() 读取。
#   · 依赖模型约定"模型局部 +Y = 杖身/杖尖方向"（held_staff.gd 里同一套约定）。
#     ⚠ 改朝向约定时必须同时改这里，否则杖头位置与朝向会一起歪掉。
#   · 不依赖任何 autoload；不发信号；不读写文件；不修改场景树。
#   · 被 spell_aim.gd::origin_global() 在 origin_at_staff = true 时调用（当前默认 false）。
#
# 主要对外接口（全部为 static，可无实例直接调用）：
#   tip_global(holder)  -> Vector3  杖头世界坐标（holder 无效时 Vector3.ZERO）
#   tip_forward(holder) -> Vector3  杖头世界朝向（已归一化；按模型 +Y）
#   tip_length(holder)  -> float    特征长度（世界米，≥ 0.05；拿不到模型时 1.0）
#
# 已知的坑与注意事项：
#   1) 三个对外接口对 null 的容忍度**不一致**：只有 tip_global() 开头做了
#      null / is_instance_valid 防御；tip_forward() 与 tip_length() 传 null 会直接报错。
#      调用方必须自己保证 holder 有效（或统一只走 tip_global()）。
#   2) tip_global() 的返回值 Vector3.ZERO 是一个"看起来合法"的坐标（世界原点），
#      调用方不能只靠 `!= Vector3.ZERO` 判断失败语义 —— 那只是本文件的约定，不是错误码。
#   3) 快路径（_head_local）依赖 held_staff.gd 已经量完模型尺寸；在法杖尚未摆放完
#      （掉落中 / 收起中 / 换杖中）的帧里调用，结果可能不准，不要把返回值长期缓存。
#   4) _merged_aabb() 在世界空间做轴对齐包围盒，所以 tip_length() 不是旋转不变量：
#      法杖斜着拿时数值会变小（见 tip_length() 的说明）。
#   5) 每次调用都会重新遍历网格（无缓存）；本类被调用的时机是"施法瞬间"，
#      频率低，当前不做缓存是刻意的取舍（避免缓存失效带来的脏数据）。
#   6) 常量 HOLD_FALLBACK_RATIO 当前**没有任何代码读取**（预留），不要以为它在生效。
# ==============================================================================
@tool
extends RefCounted
## 从**法杖模型本身**算出"杖头（喷火口）"的世界位置 —— 不写死任何坐标。
##
## 为什么必须读模型：法杖有大有小（staff_system 里每根都有 scale / world_len），
## 拿固定偏移的话，小杖会喷在杖身中间、大杖会喷在杖外。
##
## 优先级：
##   1) 持有脚本自己提供了 _head_local()（held_staff.gd L466 就有）-> 直接用它 + 模型缩放
##   2) 兜底：把模型里所有 MeshInstance3D 的世界包围盒合起来，取"离握持点最远的那个端面中心"
##      —— 这个对所有法杖都成立，且完全是数据驱动。

# ==================== 常量 ====================
## 兜底握持点比例（0.25 = 杖长的 25% 处，从杖底往上量；无量纲）。
## 语义：当**拿不到**真实握持点、又必须估一个"杖头方向"时，假设手大约握在杖长 1/4 的位置。
## 默认 0.25 的依据（推测）：法杖这类道具的手持部位通常偏下，取 1/4 处比取中点更接近真实握法。
## 调大：假想握点更高，"离握点最远的那端"更容易判到杖底，杖头可能反而指错；
## 调小：假想握点贴近杖底，几乎总是判杖顶为最远端（结果与 HOLD_FALLBACK_RATIO → 0 趋同）。
## ★ 现状提示：本文件当前**没有任何代码读取**它 —— 属于预留（推测：为"没有 Holder 位置时
##   的握点估算"分支预留的常量）。它只是常量，不影响编译与运行结果，不要误以为它在生效。
const HOLD_FALLBACK_RATIO := 0.25     ## 握持点大约在杖长的这个比例处（只在没法拿握持点时用）


# ==================== 对外接口：杖头位置 / 方向 / 尺度 ====================
## 返回杖头的世界坐标。holder 一般是"挂法杖的那个节点"（HeldStaff）。
##
## 参数：holder —— 期望是 Node3D；实际允许传 null 或已被 queue_free 的实例（开头有防御）。
##   本文件不校验 holder 是否真的"挂着一根法杖"：传角色根节点也能跑，只是结果没意义。
## 返回值：Vector3，**世界坐标**（不是局部坐标）。
##   · holder 为 null / 已失效 → Vector3.ZERO（调用方拿到的会是世界原点，属于"明确的无效值"）；
##   · 找到了模型但它没有任何网格时 → holder.global_position（退化到握点本身）；
##   · 正常情况 → 杖头世界位置。
## 副作用：**无**。不建节点、不改 transform、不发信号、不写文件；只是读模型变换做计算。
## 调用时机：施法时按需现算（spell_aim.gd::origin_global() 在 origin_at_staff = true 时调用）。
##   因为是静态纯函数，同一帧内重复调用是安全的。
## 注意事项：
##   1) 与 held_staff.gd::_head_local() 的约定必须一致：_head_local() 返回的是
##      **_model 的局部单位**坐标（不是世界、也不是 HeldStaff 局部），所以这里先乘缩放
##      再整体走 model.global_transform 转到世界。改了那边的单位口径，这里必须同步改。
##   2) _head_local() 依赖 _model_h（模型量过尺寸后才有值），所以在"掉落中/收起中/换杖中"
##      这些还没摆放完的帧里调用，返回值可能是不对的 —— 别把它当稳定量缓存。
##   3) 优先级 1 的判定条件是 has_method("_head_local")，不是"这个 holder 是 HeldStaff 类型"，
##      所以任何实现了同名方法的节点都会走快路径。
static func tip_global(holder: Node3D) -> Vector3:
	if holder == null or not is_instance_valid(holder):
		return Vector3.ZERO
	var model := _find_model(holder)
	if model == null:
		return holder.global_position

	# 1) 模型自身提供的"杖头局部坐标"（held_staff.gd 里有）
	if holder.has_method("_head_local"):
		var hl: Variant = holder.call("_head_local")
		if hl is Vector3:
			var s := _model_world_scale(holder, model)
			# _head_local() 是"模型局部单位"里的位置；乘上缩放再转到世界
			return model.global_transform * ((hl as Vector3) * s)
	# 2) 兜底：世界包围盒的最远端
	return _tip_from_aabb(holder, model)


## 杖头的朝向（法杖自身 +Y 方向的世界向量）；喷火按它喷
##
## 参数：holder —— 同 tip_global()，允许 null / 已失效。
## 返回值：Vector3，**世界空间已归一化的单位向量**（方向，无单位长度）。
##   · 拿不到模型时 → holder 自身 basis 的 +Y（不归一化后再归一化，长度为 1）；
##   · holder 为 null 时会直接解引用报错（推测：本函数未像 tip_global() 那样加 null 防御，
##     调用方需自行保证 holder 有效）。
## 副作用：无（纯读变换）。
## 调用时机：算完 tip_global() 之后紧接着取喷射方向。
## 注意事项：
##   · 取的是**模型的 +Y**，不是 Holder 的 +Y：法杖摆放时模型可能带额外旋转/偏移，
##     所以必须以模型自身坐标轴为准（held_staff.gd 里"模型 +Y = 杖身"是同一套约定）。
##   · 结果来自 basis 的 +Y 列；若 holder/model 的缩放是负数（镜像），方向会被翻转——
##     当前法杖不使用负缩放，这里不做补偿。
static func tip_forward(holder: Node3D) -> Vector3:
	var model := _find_model(holder)
	if model == null:
		return (holder.global_transform.basis * Vector3.UP).normalized()
	# 模型局部 +Y = 杖尖方向（held_staff 的 _head_local 也是按 +Y 算的）
	return (model.global_transform.basis * Vector3.UP).normalized()


## 杖头的"有效长度"（世界单位）—— 给粒子用，保证不同大小的杖喷出的火柱比例一致
##
## 取法杖的"特征长度"（世界单位，米）：合并包围盒三条边长里的最大值。
##
## 参数：holder —— 同 tip_global()；为 null 时会在 _find_model() 内报错（无防御）。
## 返回值：float，单位为**世界米**，且被夹在 [0.05, +∞)：
##   · 拿不到模型 → 1.0（一个"普通法杖大小"的中性默认值，避免调用方除以 0 或拿到 0 长度）；
##   · 正常 → max(size.y, size.x, size.z)，再用 maxf(0.05, ...) 兜底。
## 副作用：无（只读网格 AABB 与变换）。
## 调用时机：给粒子系统定尺寸/速度比例时调用（例如让"火柱长度 ≈ 杖长的某个倍数"）。
## 注意事项：
##   · 返回的是**世界空间轴对齐包围盒**的边长，所以法杖倾斜/旋转后这个值会变（不是旋转不变量）：
##     竖直时接近真实杖长，斜着拿会偏小，完全水平时可能变成"杖粗"级别的数。
##   · 取三条边的 max 而不是只取 size.y：就是为了在法杖快躺平时仍能给出一个有意义的"尺度"。
##   · 下限 0.05 米（5 cm）是防止退化值（空网格/极薄装饰片）把后续的粒子缩放算成 0。
static func tip_length(holder: Node3D) -> float:
	var model := _find_model(holder)
	if model == null:
		return 1.0
	var ab := _merged_aabb(holder, model)
	var l := maxf(ab.size.y, maxf(ab.size.x, ab.size.z))
	return maxf(0.05, l)


# ==================== 内部实现（模型查找 / 尺寸换算 / 包围盒求解杖头） ====================
# 说明：除上面的三个对外接口（tip_global / tip_forward / tip_length）外，
#   其余 static 函数都以下划线开头，属于**内部实现**，不要从其它脚本调用：
#   _find_model() / _model_world_scale() / _merged_aabb() / _tip_from_aabb()
#   其中只有 _find_model() 是三个接口共用的第一步，其余只在特定分支里被用到。
## 定位"法杖模型根节点"。
##
## 参数：holder —— 挂法杖的节点（HeldStaff）。本函数假定它非 null。
## 返回值：Node3D —— 模型根；找不到返回 null。**可能返回 holder 自己之外的后代节点**。
## 副作用：无（只读节点树；不实例化、不改父子关系）。
## 调用时机：tip_global() / tip_forward() / tip_length() 各自的第一步。
##
## 两条查找路径（先 A 后 B）：
##   A) 直接读属性 `_model` —— held_staff.gd 持有的模型引用（约定俗成的地下接口）。
##      注意用的是动态 get("_model") 而不是强类型访问：本文件不 preload held_staff.gd，
##      所以不能依赖类型；同时也让"任何有 _model: Node3D 字段的脚本"都能被复用。
##   B) 兜底：从 holder 开始**深度优先遍历**，命中第一个 MeshInstance3D 就返回它的父节点。
##      为什么返回父节点而不是网格本身：网格往往只是模型里的一个部件，模型根才是
##      整体变换（含摆放偏移与缩放）的载体，后续 _model_world_scale / global_transform 都基于它。
##
## 注意事项：
##   · 路径 B 的返回类型做了显式防护：MeshInstance3D 的父节点若不是 Node3D（例如直接挂在
##     Node/场景根下）会返回 null，而不是抛类型错误。
##   · 用显式栈（stack，pop_back 取尾部）而不是递归：法杖层级深、部件多，递归没有深度收益，
##     而显式栈在遍历途中被销毁/释放时更容易控制；pop_back 让顺序近似后进先出（顺序无关紧要，
##     因为只取"第一个"网格）。
static func _find_model(holder: Node3D) -> Node3D:
	# held_staff.gd 把模型放在 _model；拿不到就找第一个带 MeshInstance3D 的子树
	var v: Variant = holder.get("_model")
	if v is Node3D:
		return v as Node3D
	var stack: Array = [holder]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			return (n as MeshInstance3D).get_parent() as Node3D if n.get_parent() is Node3D else null
		for c in n.get_children():
			stack.append(c)
	return null


## 求"模型局部单位 → 世界米"的比例系数。
##
## （本函数属于"尺寸换算"：把 _head_local() 的模型局部单位换算成世界米）
## 参数：
##   holder —— 当前实现**未使用**（保留在签名里是为了与其它内部函数统一调用形式；推测）。
##   model  —— 模型根节点（通常来自 _find_model()）。
## 返回值：float，无量纲比例。1.0 表示"1 个模型局部单位 = 1 米"。
##   当 model 的**局部**缩放接近 0（< 1e-6）时返回 1.0，避免除零得到 inf/nan。
## 副作用：无。
## 调用时机：仅 tip_global() 的快路径（holder 提供 _head_local()）里，把局部坐标换成世界尺度。
##
## 为什么不能直接读 model.scale.x：
##   model.scale 只是"本节点相对父节点的缩放"，而模型可能被挂在**带缩放的上层**之下
##   （held_staff.gd 的 _parent_scale 就是干的这件事）。所以这里用
##   "global_transform 的缩放 ÷ transform 的缩放" = 从本节点到世界之间的**累积缩放**，
##   把所有祖先的缩放一次性吃进来。这也正是 held_staff.gd 里
##   "模型局部单位 → 世界米 = _model.scale × _parent_scale" 的同一条公式。
##
## 注意事项：
##   · 只取 basis 缩放向量的 .x：假定法杖是等比例缩放（x=y=z）。非等比缩放时其余两轴会被忽略，
##     换算会不准；当前所有法杖都是等比，所以不额外处理。
##   · 用 get_scale() 而不是 basis.get_scale() 的某个分量做近似 —— get_scale() 内部做的是
##     "取列向量长度"，因此它要求 basis 是"有旋转、无剪切"的常规变换（Godot 节点默认满足）。
static func _model_world_scale(holder: Node3D, model: Node3D) -> float:
	# 用"世界变换 vs 局部变换"的缩放比，把模型局部单位换成世界单位
	var lm := model.transform.basis.get_scale().x
	var wm := model.global_transform.basis.get_scale().x
	if lm < 0.000001:
		return 1.0
	return wm / lm


# ==================== 内部实现：包围盒求解杖头（兜底路径） ====================
## 把 holder 子树里所有 MeshInstance3D 的世界 AABB 合并
##
## 参数：holder —— 仅在"完全没找到任何网格"时用来取退化盒子的位置；model —— 遍历起点（模型根）。
## 返回值：AABB，**世界空间**的轴对齐包围盒（已经吃进缩放与旋转）。
##   · 一个网格都没命中时 → AABB(holder.global_position, Vector3.ONE * 0.1)，
##     即以握点为中心、边长 10 cm 的退化小盒（保证调用方永远拿到非空盒子，不必自己判空）。
## 副作用：无（只读 mesh.get_aabb() 与 global_transform）。
## 调用时机：tip_length() 与 _tip_from_aabb() 各调一次（两处会重复遍历一遍网格，当前不求缓存）。
##
## 实现要点：
##   · 逐网格取 8 个角点（get_endpoint(0..7)）并用 mi.global_transform 变换到世界后 expand()：
##     MeshInstance3D.global_transform 已经包含旋转，但网格自身的 AABB 是**局部轴对齐**的，
##     所以只变换 8 个角点得到的是"旋转后的凸包"的外包盒 —— 会略微偏大，但足够用（推测取舍）。
##   · 第一个角点走的是"AABB(w, ZERO)"的初始化分支：因为 AABB.expand() 对空盒子
##     （first = true 时的 out）语义不可靠，这里显式区分"第一次"和"后续"。
##   · 跳过 mesh == null 的网格实例（占位节点没有几何，get_aabb() 无意义）。
static func _merged_aabb(holder: Node3D, model: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var ab := mi.mesh.get_aabb()
			for i in range(8):
				var w: Vector3 = mi.global_transform * ab.get_endpoint(i)
				if first:
					out = AABB(w, Vector3.ZERO)
					first = false
				else:
					out = out.expand(w)
		for c in n.get_children():
			stack.append(c)
	if first:
		return AABB(holder.global_position, Vector3.ONE * 0.1)
	return out


## 取包围盒里"离握持点最远的那一端"的中心当杖头
##
## 参数：holder —— 同时提供"握持点"（holder.global_position）与退化盒子的位置；
##   model —— 传给 _merged_aabb() 的遍历起点。
## 返回值：Vector3，**世界坐标**：合并包围盒的 y_min 面中心或 y_max 面中心里更远的那一端。
## 副作用：无。
## 调用时机：tip_global() 的最后兜底（holder 没提供 _head_local() 时）。
##
## 判定逻辑与"为什么这么写"：
##   · 只比较**最低面中心**与**最高面中心**两点，而不是比较盒子的 8 个角：
##     杖头必然在杖身轴向的两端之一，比较 Y 两端即可；两点的 x/z 都取盒子中心，
##     这样结果始终落在靠近"杖的轴线"的位置，不会跑到盒子某个斜角上（斜角会明显偏离杖身）。
##   · 用 >= 而不是 >：平手时取上端（high_c），这是有意的**方向偏好** ——
##     比起把杖头判到杖底，判到上端在视觉上更不容易出错（喷火点偏低会像从脚边冒火）。
##   · 依赖"包围盒基本竖直 + 握点位于两端之间"这两个前提：法杖被大幅倾斜、或握点被摆到
##     盒子外侧时，这里可能选错端 —— 所以它只是兜底，正常路径优先走 _head_local()。
static func _tip_from_aabb(holder: Node3D, model: Node3D) -> Vector3:
	var ab := _merged_aabb(holder, model)
	var hold := holder.global_position
	var low_c := Vector3(ab.get_center().x, ab.position.y, ab.get_center().z)
	var high_c := Vector3(ab.get_center().x, ab.end.y, ab.get_center().z)
	if hold.distance_to(high_c) >= hold.distance_to(low_c):
		return high_c
	return low_c
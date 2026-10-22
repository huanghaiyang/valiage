@tool
class_name Butterfly
extends Node3D
## 单只蝴蝶 —— 网格 + 逐帧扑翼 + AI（状态机 / Boids 转向 / 风 / 能量）。
##
## ★★ 它长什么样（「居中折叠」的落点）★★
##   素材是**正面展开的蝴蝶**（x = 左翅→右翅）。这里贴的是一片**单位方块**
##   （顶点 x,y ∈ [-0.5, 0.5]，法线 +Z），真正的"折"在 butterfly_wings.gdshader 里做：
##     以 x = 0 这条竖线（= 不透明包围盒的水平中心）为折轴，
##     右翅绕 +Y 转 -θ、左翅转 +θ，翅尖一起抬向 +Y，形成 **V 形双翅**，
##     V 的开口朝上、书脊朝下 —— 这正是蝴蝶侧视时的真实轮廓。
##   θ（二面角）由本脚本每帧按 flap_hz 的正弦推着走，**每只蝴蝶相位/频率都不同**，
##   所以整群不会像机器人一样整齐扇翅。
##
## ★★ 坐标系约定（与 CONTRACT.md 第 1 节一致，改之前先读那节）★★
##   · +X = 纹理 +u（翅尖方向）  · -Y = 头（纹理上边）
##   · +Z = 额面法线（正面朝 +Z）
##   · **飞行方向 = 局部 -Z**（尾部在 +Y、头在 -Y）
##     —— 这条是为了跟 Godot 的 `look_at()` 约定一致（它把 **-Z** 对准目标）。
##     ⚠ 早期注释写的是"+Z = 飞行方向"，那是错的：照着它做树外回退时，
##       树内（look_at，-Z 朝前）与树外会**掉头 180°**（实测点乘 -1.000000）。
##       着色器里两翅的几何与基都在（+X/-X 对称、+Y 朝头尾、+Z 是法线），所以
##       "哪一侧朝前"只由这个约定决定；改这里请同时检查 `_sync_transform()` 的两条分支。
##   · 因此**扑翼绕局部 Y 轴**、**转体绕局部 Y 轴**、**侧倾绕局部 Z 轴**互不打架
##   · 飞行时用 `look_at` 把 +Z 对准速度方向，于是"头"自动朝前（因为纹理 up=-Y 朝后）
##
## ★★ 为什么 AI 必须是纯数学（不碰渲染）★★
##   无头模式（CI / `--headless`）没有渲染，但**测试要验证 AI 能跑、不飞出区域、不钻地**。
##   所以 `advance()` 里只有向量运算与内置数学，节点变换更新放在末尾（无头下也不会崩）。
##
## ★ 性能取向：12~60 只，每只一个 MeshInstance3D + 一个独立 ShaderMaterial
##   （独立是必需项：每只的 dihedral/相位不同）。不做物理体、不做 raycast 循环
##   （避障用"群体共享的高度场/一次性 ground_avoid"实现，见 step_ai）。

# ==================== 依赖（preload，不用 global class 名） ====================
## ★ 为什么用 preload 而不是直接写 `ButterflyIO.xxx`：
##   全局类名（class_name）依赖 .godot/global_script_class_cache.cfg。新增脚本后若缓存没刷新，
##   游戏里会报 "Identifier ButterflyIO not declared" 直接崩，而**编辑器里却是好的**。
##   preload 是编译期绑定，不依赖那份缓存，两种环境下行为一致。
const BFLY_IO := preload("res://addons/butterfly_swarm/butterfly_io.gd")

# ==================== 状态机 ====================
## 行为状态。★ 数值是对外契约吗？不是 —— 但 `stats()["state"]` 会把名字暴露给测试/调试 UI，
## 所以**新增状态时请同步 _state_name()**，否则测试会拿到 "?"。
enum State {
	CRUISE,   ## 巡飞：绕着区域自由飞（默认态）
	SEEK,     ## 趋花/趋水/趋伴：主动飞向一个目标点
	COURT,    ## 求偶/追逐：两只蝴蝶绕圈（由 swarm 分配 partner）
	BASK,     ## 停歇：落在地面/叶子上晒太阳、回能量
	SHELTER,  ## 避风避雨：天气恶劣时躲到低处/障碍背后
	FLEE,     ## 受惊逃逸：附近有威胁（玩家/捕食者）时的直线冲刺
	DRINK,    ## 汲水：在地面水洼/花丛停留（与 BASK 类似但位置在目标点）
}

# ==================== 对外状态（swarm / 测试只读） ====================
## 当前行为状态（State 枚举）。
var state: int = State.CRUISE
## 能量 0..1：飞行时按 energy_drain 下降，低于 rest_energy 去 BASK，回到 1.0 重新起飞。
var energy := 1.0
## 贴图（蝴蝶 PNG）。由 setup() 注入。
var sprite_tex: Texture2D = null
## 该 PNG 上**不透明包围盒**（像素）。折轴 = 它的水平中心，UV 裁剪 = 它的范围。
var crop := Rect2i(0, 0, 0, 0)
## 视觉节点（MeshInstance3D + ShaderMaterial）。setup() 里建。
var visual: MeshInstance3D = null
## 本只蝴蝶的着色器材质（独立实例：每只的 dihedral 不同）。
var mat: ShaderMaterial = null
## 身体材质（surface 1 的 override）。每帧只改 albedo，用来跟随天气压暗。
var _body_mat: StandardMaterial3D = null
## 身体的基础色（从素材采样，见 sample_body_color）。天气只在上面临时乘它，不改这个基色。
var _body_base := Color(0.24, 0.17, 0.12)

# ==================== 运动学（AI 的唯一真实来源） ====================
## 世界坐标下的速度（米/秒）。加速度积分进它，位置再积分速度。
var velocity := Vector3.ZERO
## 本帧的目标加速度（诊断用，也是测试可以观察的量）。
var accel_now := Vector3.ZERO
## 当前朝向（单位向量）。**不等于** velocity 的方向：朝向做平滑，避免高频抖动。
var heading := Vector3(0, 0, 1)

# ==================== 内部时序 ====================
## 扑翼相位（弧度）。每帧 += TAU * flap_hz * delta，取 sin 得二面角。
var _flap_phase := 0.0
## 本只蝴蝶的扑翼频率（Hz）= tuning.flap_hz ± jitter。
var _flap_hz := 8.5
## 漫游方向（单位向量，水平面）：被 wander_jitter 缓慢推着转。
var _wander := Vector3(1, 0, 0)
## 状态剩余时间（秒）。<= 0 时允许状态机重新决策。
var _state_timer := 0.0
## 当前目标点（SEEK/DRINK 用）。为 null 表示没有目标。
var _target: Variant = null
## 目标缓存有效期（秒）：避免每帧在场景树里找花找玩家。
var _target_scan_t := 0.0
## 受惊源（**本地坐标**）：FLEE 时记住"从哪儿逃"，用于持续远离。
## 注意：是坐标而不是节点引用 —— 这样 advance() 完全不依赖场景树（无头可测），
##   也避免"威胁节点被释放"造成的悬空引用。
var _threat := Vector3.ZERO
## 停歇/汲水时的落脚点（BASK/DRINK 期间位置被它钉住）。
var _perch := Vector3.ZERO
## 本帧的区域 AABB（**本地空间**），由 `advance()` 每帧记下。
## 为什么要有它：状态决策 `_update_state()` 的签名里没有 bounds，
##   而 CRUISE 现在需要"按区域挑一个偏低处的巡飞航点"（_pick_cruise_waypoint）。
##   用成员传递而不是给 _update_state 加参数 —— 那个签名被测试与其它调用点依赖。
## 默认值是一个"到处都装得下"的盒子：树外调用 advance() 之前也不会取到零值而算错。
var _bounds := AABB(Vector3(-1, 0, -1), Vector3(2, 3, 2))
## 上次起飞时刻（秒，累加时钟）：用于"停歇至少 N 秒"的判定。
var _clock := 0.0
## 调试用：本只蝴蝶累计飞行距离（米）。测试可用它证明"真的在飞"。
var distance_travelled := 0.0
## 低频噪声的内部相位（见 _signed_noise）。每只独立，所以整群的"飘"不同步。
var _noise_phase := 0.0

# ==================== 移动生态学状态（CRW / Lévy / ARS）====================
# 为什么要有这些状态：原来 CRUISE 是"随机游走 + 往航点直飞"，
#   表现就是**直飞**（用户实测反馈："蝴蝶现在都是直飞的"）。
#   真实蝴蝶的运动是**方向相关随机游走（CRW）**：方向和上一步强相关（小转角为主），
#   偶尔来一次大转角（重尾），步长服从重尾分布（Lévy），并且在感知到资源时
#   自动切成"原地打转"（区域限制搜索 ARS）。下面这几个变量就是这套模型的状态。
## 当前"决策段"的航向（单位向量，本地空间）。CRW 的核心状态：它**跨帧保持**，
## 所以轨迹是连续的而不是每帧重掷。
var _crw_heading := Vector3.ZERO
## 距离下次更新航向还剩多少秒（0 -> 本帧重新决策）。
var _crw_timer := 0.0
## 当前决策段的 Lévy 步长（米）：段内一直用它当"目标速度"，段末重掷。
var _crw_step_len := 0.6
## 侧向摆动相位（弧度）：给直线段叠一层左右摆，避免"镭射直线"。
var _weave_phase := 0.0
## 本帧是否处于区域限制搜索（ARS，附近有资源 -> 打转搜索）。
var _ars_active := false
## ARS 的"资源在哪个方向"（本地空间，单位向量；进入 ARS 时由 swarm 灌进来）。
var _ars_dir := Vector3.ZERO
## 上一次 ARS 切换的时刻（秒）：用于节流，避免每帧来回切。
var _ars_switch_t := -1.0
## ★ 这只蝴蝶"对资源的兴趣"（0~1，setup 时随机定死，之后不变）。
## 用途：只有 `_ars_bias < ars_participation` 的个体才会被资源点吸住 ——
##   这样队伍里总有一部分在照常巡飞，整群不会**同步**收拢/散开。
##   （用户反馈"反复在两点之间散开再重聚"：整群同步收拢是最主要的视觉原因之一。）
var _ars_bias := 0.5
## 上一处趋花目标（本地坐标）。用于**避免重复回同一个点**（见 `_find_flower_world`）。
var _last_seek_target: Variant = null

# ==================== 确定性随机 ====================
## 由 swarm 注入的随机数发生器（同 seed_value 可复现）。
## ★ 注入 rng 而不是用全局 randf()：整群的初始位置/相位应当只由 seed_value 决定。
var rng: RandomNumberGenerator = null

# ==================== 调参（setup 时从 swarm 灌入） ====================
var _t: Dictionary = {}


func _ready() -> void:
	# 纯逻辑节点，不需要每帧 process（由 swarm 统一驱动，便于固定步长与无头测试）
	set_process(false)
	set_physics_process(false)


# ==================== 构建 ====================

## 一次性装配：贴图 / 裁剪 / 调参 / 随机源 / 着色器材质。
## 参数：
##   tex      —— 蝴蝶 PNG（Texture2D）；null 时不建视觉（AI 仍可跑，便于测试）
##   crop_rect—— 该 PNG 的不透明包围盒（ButterflyIO.detect_bbox 的结果）
##   r        —— 随机数发生器（swarm 注入）
##   tuning   —— 调参字典（见 ButterflySwarm.tuning_dict() 的键）
##   shader   —— 已加载的翅膀着色器（null 时自动去 load 契约里的绝对路径）
## 返回值：无。
## 副作用：建出 visual 子节点与 ShaderMaterial；写 crop/_t/_flap_hz/初始相位。
## 注意：**可重复调用**（重建时用）：会先释放旧 visual，不会重复挂子节点。
func setup(tex: Texture2D, crop_rect: Rect2i, r: RandomNumberGenerator, tuning: Dictionary,
		shader: Shader = null) -> void:
	sprite_tex = tex
	crop = crop_rect
	rng = r
	_t = tuning
	# 每只蝴蝶自己的扑翼频率：基础值 ± jitter，且**相位随机**（整群不同步的关键）
	_flap_hz = maxf(0.5, _num("flap_hz", 8.5) + r.randf_range(-1.0, 1.0) * _num("flap_hz_jitter", 2.5))
	_flap_phase = r.randf_range(0.0, TAU)
	_wander = Vector3(r.randf_range(-1.0, 1.0), 0.0, r.randf_range(-1.0, 1.0))
	if _wander.length_squared() < 0.0001:
		_wander = Vector3(1, 0, 0)
	_wander = _wander.normalized()
	# ★ 每只蝴蝶对资源的"兴趣"：随机定死（不随时间抖），配合 swarm 的 `ars_participation`
	#   让"被蜜源吸住"的只有一部分个体 -> 整群不会同步收拢/散开。
	_ars_bias = r.randf()
	_last_seek_target = null
	var sh := shader
	if sh == null:
		if ResourceLoader.exists(WINGS_SHADER):
			sh = load(WINGS_SHADER) as Shader
	if visual != null and is_instance_valid(visual):
		visual.queue_free()
		visual = null
	if tex == null or sh == null:
		# 没有贴图/没有着色器时仍然允许 AI 跑（测试与"只剩逻辑"的场景）
		return
	visual = MeshInstance3D.new()
	visual.name = "Wings"
	visual.mesh = build_unit_quad()
	mat = ShaderMaterial.new()
	mat.shader = sh
	visual.material_override = mat
	visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# ★★ 禁止被「合批」吃掉（用户实测踩过：勾上合批后蝴蝶变成冻结的白片）★★
	#   本仓库主场景的 `scripts/world/prop_merge.gd` 会把带 `meta["allow_batch"] = true`
	#   的节点的**整棵子树里所有 MeshInstance3D** 合并成一个静态 ArrayMesh，
	#   然后 `queue_free()` 掉原节点（见它第 173 行收件、273 行释放）。
	#   蝴蝶的翅膀正好是它的后代 —— 一旦被合批：
	#     · 逐只的 ShaderMaterial（扑翼相位/张翼角）失效 -> 全群一个静态姿态
	#     · 顶点被烘焙进世界空间且不再更新 -> **冻结**
	#     · 合并后材质分组错乱 -> **白片**
	#   而 prop_merge 的契约里就有逃生口：子件 `meta["batch"] = false` 即排除（它第 173 行）。
	#   所以这里显式打上这个 meta：**蝴蝶永远不参与合批**。
	#   （蝴蝶是运行时逐帧改顶点/材质的动态物体，合批在语义上本来就不适用。）
	visual.set_meta("batch", false)
	add_child(visual)
	_apply_material()
	_update_visual_scale()


## 翅膀着色器的**硬编码路径**（契约第 2 节）。改文件名会静默变成"没有蝴蝶翅膀"。
const WINGS_SHADER := "res://assets/shaders/butterfly_wings.gdshader"
## 翅面网格的细分段数（x 方向 = 翼展，y 方向 = 头尾）。
## ★ 为什么必须细分（不再是单个方块）：着色器里的**弧度 camber** 与**厚度**都依赖"顶点够密"。
##   4 顶点的方块只能被整体折叠（还是一个平板 + 两条对角线），
##   细分成 GRID_X × GRID_Y 之后，二面角才能随翼展位置连续变化 -> 翅面真的是**曲面**。
##   8×8（81 顶点 / 128 三角）在 12~60 只的规模下开销可以忽略，视觉上已经够圆。
const GRID_X := 8
const GRID_Y := 8


## 构建**双表面**网格：
##   surface 0 = 翅面（(GRID_X+1)×(GRID_Y+1) 的细分网格，初始躺在 z=0 平面）
##   surface 1 = **身体**（沿头尾方向拉长的低模胶囊，8 边环 × 4 段 + 两端封口）
##
## ★★ 为什么身体要单独做一个实体（"体积感"的关键）★★
##   素材只有一对翅膀，没有身体。而蝴蝶的"有没有体积"几乎全靠**身体**：
##   翅是薄片（再怎么折也只是面），身体是**真的有体积的椭圆截面实体** ——
##   它随节点朝向一起转，从任何角度看都是一个立体的小圆柱，
##   于是整只蝴蝶在任何姿态下都有"看得见的质量"。
##   颜色从**素材自身**采样（蝶身中轴那几列），所以不同蝴蝶的身体颜色自动匹配它的翅膀。
##
## 返回值：ArrayMesh（2 个 surface）。
## 说明：顶点顺序沿用契约的方块约定（+X = 翅尖、-Y = 头、+Z = 初始法线、UV v=0 在纹理上边）；
##   细分后"上边"只在第一行，契约里"上边顶点 UV.y 必须为 0"的断言需要按网格来查。
func build_unit_quad() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	_fill_wing_surface(mesh)
	_append_body_surface(mesh)
	# ★ 自检：surface 建不出来时**必须报警**（历史上就是这里静默失败，蝴蝶全不可见）
	if mesh.get_surface_count() == 0:
		push_error("[蝴蝶] 翅膀网格构建失败（surface_count=0）—— 蝴蝶将不可见，请检查 arrays 的数据类型")
	return mesh


## 翅面：把单位方块细分成 (GRID_X+1)×(GRID_Y+1) 的网格，并生成**闭合外壳**（真实厚度）。
##
## ★★ 为什么是"外壳"而不是单片平面（体积感的第二来源）★★
##   单片平面无论怎么折都只是**一张纸**：侧视没有边、掠射没有高光、厚度为零。
##   这里生成一个真正的闭合薄壳：
##     · 前层（z = +t/2）、后层（z = −t/2）：两层都朝外，构成正反两面
##     · 四条边的**侧壁**（rim）：把上下两层的边界缝起来 -> 侧视时看到的是"一条有宽度的边"
##   闭合 + 剔除背面之后，从任何角度看它都是"有体积的片状物体"，而不是零厚度纹理。
##   ⚠ 这也是**唯一可靠的做法**：`FRONT_FACING` 在 Godot 的**顶点阶段不可用**
##     （实测：顶点里写它会 `Unknown identifier in expression: 'FRONT_FACING'`，
##      整份着色器编译失败），所以"在顶点里按正面/背面往外推"这条路根本走不通 ——
##      厚度只能在几何里做出来。
##
## 坐标系：x ∈ [-0.5, 0.5] 沿翼展，y ∈ [-0.5, 0.5] 沿头尾，z = 0 是中性面，
##   法线 +Z，UV 的 v=0 在 y=+0.5 那行（纹理上边 = 蝴蝶的头侧）。
func _fill_wing_surface(mesh: ArrayMesh) -> void:
	var s := maxf(0.01, _num("size_m", 0.22))
	# 厚度是**模型单位**（单位方块参照系）：wing_thickness 是"占翼展的比例"
	var half_t := clampf((_num("wing_thickness", 0.035) * s) * 0.5, 0.0, 0.25)
	var nx := GRID_X + 1
	var ny := GRID_Y + 1
	# 先算出中性面上的 (x, y) 网格坐标（前层/后层/侧壁都要用）
	var xy: Array = []
	for iy in range(ny):
		for ix in range(nx):
			xy.append(Vector2(float(ix) / float(GRID_X) - 0.5, 0.5 - float(iy) / float(GRID_Y)))
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# ---- 前层（z=+half_t，法线 +Z）与后层（z=−half_t，法线 −Z）----
	for layer in range(2):
		var zsign := 1.0 if layer == 0 else -1.0
		for p in xy:
			var q: Vector2 = p
			st.set_normal(Vector3(0.0, 0.0, zsign))
			st.set_uv(Vector2(q.x + 0.5, 0.5 - q.y))
			st.add_vertex(Vector3(q.x, q.y, zsign * half_t))
	var layer_size := nx * ny
	# 顶点索引：前层 iy*nx+ix；后层 layer_size + iy*nx+ix
	for iy in range(GRID_Y):
		for ix in range(GRID_X):
			var i0 := iy * nx + ix
			var i1 := i0 + 1
			var i2 := i0 + nx + 1
			var i3 := i0 + nx
			# 前层：从 +Z 看逆时针
			st.add_index(i0)
			st.add_index(i1)
			st.add_index(i2)
			st.add_index(i0)
			st.add_index(i2)
			st.add_index(i3)
			# 后层：绕序反过来（从 −Z 看才是逆时针）
			var b0 := layer_size + i0
			var b1 := layer_size + i1
			var b2 := layer_size + i2
			var b3 := layer_size + i3
			st.add_index(b0)
			st.add_index(b2)
			st.add_index(b1)
			st.add_index(b0)
			st.add_index(b3)
			st.add_index(b2)
	# ---- 侧壁：沿四条边界把前后两层缝起来（这一步才让它是"闭合外壳"）----
	var loop: Array = []
	for ix in range(nx):
		loop.append(ix)                              # 上边（iy=0）
	for iy in range(1, ny):
		loop.append(iy * nx + GRID_X)                # 右边（ix=GRID_X）
	for ix in range(GRID_X - 1, -1, -1):
		loop.append(GRID_Y * nx + ix)                # 下边（iy=GRID_Y）
	for iy in range(GRID_Y - 1, 0, -1):
		loop.append(iy * nx)                         # 左边（ix=0）
	for k in range(loop.size()):
		var a: int = loop[k]
		var b: int = loop[(k + 1) % loop.size()]
		var qa: Vector2 = xy[a]
		var qb: Vector2 = xy[b]
		# 外法线 = 该段在 XY 面内的外法线（把段方向转 90°）
		var dir := (qb - qa)
		var nrm := Vector3(dir.y, -dir.x, 0.0)
		if nrm.length_squared() < 1e-9:
			nrm = Vector3(1.0, 0.0, 0.0)
		nrm = nrm.normalized()
		var uva := Vector2(qa.x + 0.5, 0.5 - qa.y)
		var uvb := Vector2(qb.x + 0.5, 0.5 - qb.y)
		var pa := Vector3(qa.x, qa.y, half_t)
		var pb := Vector3(qb.x, qb.y, half_t)
		var pa2 := Vector3(qa.x, qa.y, -half_t)
		var pb2 := Vector3(qb.x, qb.y, -half_t)
		# 两个三角：外法线方向一致地绕
		st.set_normal(nrm)
		st.set_uv(uva)
		st.add_vertex(pa)
		st.set_normal(nrm)
		st.set_uv(uva)
		st.add_vertex(pa2)
		st.set_normal(nrm)
		st.set_uv(uvb)
		st.add_vertex(pb)
		st.set_normal(nrm)
		st.set_uv(uvb)
		st.add_vertex(pb)
		st.set_normal(nrm)
		st.set_uv(uva)
		st.add_vertex(pa2)
		st.set_normal(nrm)
		st.set_uv(uvb)
		st.add_vertex(pb2)
	st.commit(mesh)


## 给网格**追加身体**表面（surface 1）：沿 Y 轴的 8 边形柱 + 两端收口，做成一枚细长纺锤。
## 尺寸：长 0.62、最大半径 0.062（单位方块参照系，也就是"翼展的 6%" —— 蝴蝶身体本来就很细）。
##   ★ 半径会乘 `body_scale`（来自 tuning；1.0 = 默认，0 = 不画身体）。
##   注意：`body_scale` 只**粗化**身体（不改长度），保持"细长纺锤"的比例。
## 头部略上翘（`bend`），避免看起来像一根直棍。
func _append_body_surface(mesh: ArrayMesh) -> void:
	var scale_b := clampf(_num("body_scale", 1.0), 0.0, 3.0)
	if scale_b <= 0.001:
		return   # 用户把身体关掉了：只留翅面
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	const SEG := 8
	var half_len := 0.31
	var rings := [-1.0, -0.62, -0.18, 0.30, 0.72, 1.0]
	var radii := [0.010, 0.052, 0.062, 0.046, 0.026, 0.008]
	var positions: Array = []
	for ri in range(rings.size()):
		var ty: float = rings[ri]
		var rr: float = radii[ri] * scale_b
		var ring: Array = []
		for si in range(SEG):
			var ang := TAU * float(si) / float(SEG)
			var bend := 0.02 * ty * ty
			ring.append(Vector3(cos(ang) * rr, ty * half_len, sin(ang) * rr + bend))
		positions.append(ring)
	# 侧面（每条边两个三角）
	for ri in range(rings.size() - 1):
		var ra: Array = positions[ri]
		var rb: Array = positions[ri + 1]
		for si in range(SEG):
			var s2 := (si + 1) % SEG
			var a0: Vector3 = ra[si]
			var a1: Vector3 = ra[s2]
			var b0: Vector3 = rb[si]
			var b1: Vector3 = rb[s2]
			var na := Vector3(a0.x, 0.0, a0.z).normalized()
			var nb := Vector3(b1.x, 0.0, b1.z).normalized()
			var u0 := float(si) / float(SEG)
			var u1 := float(s2) / float(SEG)
			var v0 := float(ri) / float(rings.size())
			var v1 := float(ri + 1) / float(rings.size())
			st.set_normal(na)
			st.set_uv(Vector2(u0, v0))
			st.add_vertex(a0)
			st.set_normal(nb)
			st.set_uv(Vector2(u1, v1))
			st.add_vertex(b1)
			st.set_normal(na)
			st.set_uv(Vector2(u1, v0))
			st.add_vertex(a1)
			st.set_normal(na)
			st.set_uv(Vector2(u0, v0))
			st.add_vertex(a0)
			st.set_normal(na)
			st.set_uv(Vector2(u0, v1))
			st.add_vertex(b0)
			st.set_normal(nb)
			st.set_uv(Vector2(u1, v1))
			st.add_vertex(b1)
	# 两端封口（三角扇）
	for endi in [0, rings.size() - 1]:
		var ring2: Array = positions[endi]
		var dir := -1.0 if endi == 0 else 1.0
		var tip := Vector3(0.0, float(rings[endi]) * half_len + dir * 0.026, 0.0)
		for si in range(SEG):
			var s2 := (si + 1) % SEG
			var v0: Vector3 = ring2[si]
			var v1: Vector3 = ring2[s2]
			st.set_normal(Vector3(0.0, dir, 0.0))
			st.set_uv(Vector2(0.5, 0.5))
			st.add_vertex(tip)
			st.set_normal(Vector3(v0.x, dir * 0.5, v0.z).normalized())
			st.set_uv(Vector2(0.5, 0.5))
			st.add_vertex(v0)
			st.set_normal(Vector3(v1.x, dir * 0.5, v1.z).normalized())
			st.set_uv(Vector2(0.5, 0.5))
			st.add_vertex(v1)
	st.commit(mesh)


## 把 static 的贴图/裁剪/风格参数写进材质（**每次 setup 调一次**，不是每帧）。
## 副作用：写 albedo_tex / tex_scale / tex_offset / tint / alpha / iridescence / backlight /
##         camber / thickness / min_edge / rim / bend_y；并给身体表面装上材质。
## 注意：每帧变化的只有 dihedral / fold_dz / flutter_u / flutter_v / view_dir / sprite_rot
##   （见 _update_visual_params）。
func _apply_material() -> void:
	if mat == null:
		return
	mat.set_shader_parameter("albedo_tex", sprite_tex)
	var w := 0
	var h := 0
	if sprite_tex != null:
		w = sprite_tex.get_width()
		h = sprite_tex.get_height()
	var uv := BFLY_IO.crop_to_uv(crop, w, h)
	mat.set_shader_parameter("tex_scale", uv["scale"])
	mat.set_shader_parameter("tex_offset", uv["offset"])
	mat.set_shader_parameter("tint", _color("tint", Color(1, 1, 1, 1)))
	mat.set_shader_parameter("alpha", _num("alpha", 1.0))
	mat.set_shader_parameter("iridescence", _num("iridescence", 0.25))
	mat.set_shader_parameter("backlight", _num("backlight", 0.15))
	# ★ 立体感三件套：弧度 / 厚度 / 最小正对度 + 边缘压暗
	var s := maxf(0.01, _num("size_m", 0.22))
	mat.set_shader_parameter("camber", _num("wing_camber", 0.30))
	# thickness 是**模型单位**（单位方块参照系）：乘 size_m 后换算成与翼展成比例的真实厚度
	mat.set_shader_parameter("thickness", _num("wing_thickness", 0.035) * s)
	mat.set_shader_parameter("bend_y", _num("wing_bend_y", 0.0))
	mat.set_shader_parameter("min_edge", _num("edge_min_facing", 0.25))
	mat.set_shader_parameter("rim", _num("rim_dark", 0.55))
	mat.set_shader_parameter("view_dir", Vector3(0.0, 0.0, -1.0))
	mat.set_shader_parameter("sprite_rot", 0.0)
	# ---- 身体材质（surface 1）----
	# ⚠ 必须先确认"网格里真的有 surface 1"：`body_scale = 0` 时 `_append_body_surface()`
	#   会直接返回、不建身体面，此时给 index 1 设材质会报
	#   `Index p_surface = 1 is out of bounds (surface_override_materials.size() = 1)`。
	if visual != null:
		var m: Mesh = visual.mesh
		if m != null and m.get_surface_count() > 1:
			_body_base = sample_body_color()
			_body_mat = StandardMaterial3D.new()
			_body_mat.albedo_color = _body_base
			_body_mat.roughness = 0.75
			_body_mat.metallic = 0.0
			visual.set_surface_override_material(1, _body_mat)
		else:
			_body_mat = null


## ★ 换掉裁剪框（不重建网格、不动位置/状态）—— UV 重建按钮走这里。
## 参数 crop_rect：新的不透明包围盒（像素坐标，来自 ButterflyIO.detect_bbox）。
## 副作用：改 crop 并把 tex_scale/tex_offset 重算进材质。
## 注意：裁剪框变了会让贴图在翅面上的位置/比例变化，但**几何不变**，
##   所以"换图之后重新裁剪"不需要重建几十个节点，改一下 uniform 即可。
func set_crop(crop_rect: Rect2i) -> void:
	crop = crop_rect
	_apply_material()


## 从**素材自身**采样蝶身颜色（蝶身中轴那几列），保证身体颜色与该蝴蝶的翅膀匹配。
## 返回值：Color。取不到图时回落成深棕灰（蝴蝶身体的常见色），不会返回 null。
##
## ★★ 实测坑：压缩纹理不能直接 get_pixel ★★
##   本项目的 PNG 按 BPTC/ETC2 导入（`.import` 里 `compress/mode=2`），
##   于是 `CompressedTexture2D.get_image()` 回来的图**是压缩格式**，
##   直接 `get_pixel()` 会报 `Can't get_pixel() on compressed image, sorry.`
##   （编辑器和运行时都会刷，用户实测遇到过）。
##   正确做法：先 `decompress()` 再取像素。另外没有 mipmap 的图要用 `decompress()` 而非
##   `decompress()` 之外的 API；这里统一 `is_compressed()` 判断 + 转 RGBA8 兜底。
func sample_body_color() -> Color:
	var fallback := Color(0.24, 0.17, 0.12)
	if sprite_tex == null or crop.size.x <= 0:
		return fallback
	var img := sprite_tex.get_image()
	if img == null or img.get_width() <= 0:
		return fallback
	# ★ 压缩图先解压（见上面注释：不解压的话 get_pixel 直接报错）
	if img.is_compressed():
		var err := img.decompress()
		if err != OK:
			return fallback
	# 统一成 RGBA8 再取像素，避免 Unsupported format 的取像素问题
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	# 裁剪区域在贴图上的 UV 范围（注意 get_image() 的尺寸可能与原始 PNG 差几个像素，
	# 所以这里按采样出来的图尺寸比例换算，而不是用 crop 的绝对像素）
	var u0 := float(crop.position.x) / float(maxi(1, sprite_tex.get_width()))
	var v0 := float(crop.position.y) / float(maxi(1, sprite_tex.get_height()))
	var du := float(crop.size.x) / float(maxi(1, sprite_tex.get_width()))
	var dv := float(crop.size.y) / float(maxi(1, sprite_tex.get_height()))
	var iw := img.get_width()
	var ih := img.get_height()
	var acc := Color(0, 0, 0, 0)
	var n := 0
	# 沿中轴取 4 个高度（0.25..0.80），横向取 3 个（-0.04..+0.04），只统计不透明像素
	for vy in [0.25, 0.45, 0.62, 0.80]:
		for ux in [-0.04, 0.0, 0.04]:
			var px := int(clampf(u0 + du * (0.5 + ux), 0.0, 0.999) * float(iw))
			var py := int(clampf(v0 + dv * vy, 0.0, 0.999) * float(ih))
			var c := img.get_pixel(px, py)
			if c.a < 0.4:
				continue
			acc += c
			n += 1
	if n == 0:
		return fallback
	var avg := Color(acc.r / float(n), acc.g / float(n), acc.b / float(n))
	# 身体通常比翅膀暗一档（有阴影），压到 70% 并避免过暗
	return Color(maxf(0.06, avg.r * 0.70), maxf(0.05, avg.g * 0.70), maxf(0.05, avg.b * 0.70))


## 视觉缩放：单位方块 -> 目标**翼展**。
## 参数语义（别搞混）：`size_m` = 蝴蝶的**翼展**（米，翅膀尖到翅膀尖）。
## 因为 UV 已经被 tex_scale 压到"不透明包围盒"上，单位方块的 x 方向就是整幅翼展，所以：
##   scale.x = size_m                        （x = 翼展）
##   scale.y = size_m * (bbox_h / bbox_w)    （y 按**该图自己的宽高比**，保证不拉伸变形）
## ⚠ 早期版本把 size_m 同时乘到 x 和 y 上（scale = (s, s*aspect, s)），
##   再叠上节点 scale 的 x 分量 -> 实际翼展只有 size_m * 该方向的…… 总之小了一圈，
##   表现为"蝴蝶比预期小"。现在 x 上不再重复乘。
func _update_visual_scale() -> void:
	var s := maxf(0.01, _num("size_m", 0.22))
	var aspect := 1.0
	if crop.size.x > 0 and crop.size.y > 0:
		aspect = float(crop.size.y) / float(crop.size.x)
	scale = Vector3(s, s * aspect, s)


# ==================== 调参读取（容错：缺失/类型不对一律回落默认值） ====================

## 从 tuning 字典读一个 float。★ 不做危险构造转换（ProjectSettings/字典里可能是 null）。
func _num(key: String, fallback: float) -> float:
	if _t.has(key):
		var v: Variant = _t[key]
		if v is float or v is int:
			return float(v)
	return fallback


## 从 tuning 字典读一个 bool。
func _flag(key: String, fallback: bool) -> bool:
	if _t.has(key):
		var v: Variant = _t[key]
		if v is bool:
			return v
		if v is float or v is int:
			return float(v) != 0.0
	return fallback


## 从 tuning 字典读一个 Color。
func _color(key: String, fallback: Color) -> Color:
	if _t.has(key):
		var v: Variant = _t[key]
		if v is Color:
			return v as Color
	return fallback


# ==================== 生成 / 重置 ====================

## 把这只蝴蝶放到区域内的随机位置并清空运动学状态（spawn / respawn_all 用）。
## 参数 bounds：区域的世界空间 AABB（swarm 算好传进来）。
## 副作用：写 position/velocity/heading/_flap_phase/energy/state。
## 注意：**只动位置与状态，不动视觉资源**（不重新 load 贴图）。
func spawn(bounds: AABB, start_state: int = State.CRUISE) -> void:
	if rng == null:
		rng = RandomNumberGenerator.new()
		rng.randomize()
	var jitter := _num("spawn_height_jitter", 0.6)
	var p := Vector3(
		rng.randf_range(bounds.position.x, bounds.position.x + bounds.size.x),
		rng.randf_range(bounds.position.y + bounds.size.y * 0.15, bounds.position.y + bounds.size.y * 0.85)
			+ rng.randf_range(-jitter, jitter) * 0.5,
		rng.randf_range(bounds.position.z, bounds.position.z + bounds.size.z))
	# 高度再夹一次：spawn_height_jitter 可能把它顶出区域
	p.y = clampf(p.y, bounds.position.y + 0.15, bounds.position.y + maxf(0.2, bounds.size.y - 0.05))
	position = p
	velocity = _random_dir() * rng.randf_range(0.3, 1.0) * _num("speed_max", 2.2) * 0.5
	heading = velocity.normalized() if velocity.length_squared() > 0.0001 else Vector3(0, 0, 1)
	_flap_phase = rng.randf_range(0.0, TAU)
	energy = rng.randf_range(0.6, 1.0)
	state = start_state
	_state_timer = rng.randf_range(1.0, 3.0)
	_target = null
	distance_travelled = 0.0
	_sync_transform(0.0)


## 随机水平方向（单位向量）。y 分量恒 0：漫游不想让蝴蝶自己上下乱窜。
func _random_dir() -> Vector3:
	var a := rng.randf_range(0.0, TAU)
	return Vector3(cos(a), 0.0, sin(a))


# ==================== 每帧主循环 ====================

## 推进这只蝴蝶一帧：AI 决策 -> 加速度 -> 积分 -> 视觉参数 -> 变换同步。
## 参数：
##   delta   —— 帧间隔（秒）。<=0 时直接返回（防除零）。
##   bounds  —— **本地空间** AABB（相对所属 swarm；见下"坐标系"）。
##   wind    —— 风字典，见 ButterflySwarm.wind_now()；
##              至少要有 dir(Vector2, 世界 XZ) / strength / turbulence。
##   weather —— 天气字典：{wind, gust, rain, cloud, shelter: bool}；可为空字典。
##              用它决定"要不要去躲、要不要减速"。
##   neighbors—— 同群其它蝴蝶的**本地坐标**（Array[Vector3]）；用于分离力。传空数组也可跑。
##   extra   —— 可选附加输入，全部可选，且**都是本地坐标/标量**：
##              {"attract_to": Vector3, "threat": Vector3, "partner": Vector3, "hover": float}
## 返回值：无。
## 副作用：改 position/velocity/energy/state，并更新 visual 的着色器参数与节点变换。
## 注意：
##   · **坐标系**：本函数全在所属 swarm 的本地空间里算（position/velocity/neighbors/bounds/
##     extra 的坐标都是本地）。这样"区域"就是节点上的一个盒子常量，不用每帧做空间变换；
##     需要世界坐标的地方（找花、找威胁、raycast）由 swarm 转换后灌进来。
##   · 这个函数**不建/不释放节点**，无头模式下也安全
##   · 所有随机都走 self.rng（同 seed 可复现）
func advance(delta: float, bounds: AABB, wind: Dictionary = {}, weather: Dictionary = {},
		neighbors: Array = [], extra: Dictionary = {}) -> void:
	if delta <= 0.0:
		return
	_clock += delta
	_state_timer -= delta
	_target_scan_t -= delta
	energy = clampf(energy - _num("energy_drain", 0.035) * delta, 0.0, 1.0)
	# 记住本帧的区域 AABB：状态决策（_update_state -> _pick_cruise_waypoint）要用它挑巡飞航点。
	# 用成员而不是加参数：`_update_state` 的签名被测试与其它调用点依赖，加参数会扩大改动面。
	_bounds = bounds

	var force := Vector3.ZERO

	# ---- ① 状态决策（只在计时器到点时重新决策，避免每帧翻状态） ----
	_update_state(delta, weather, extra)

	# ---- ② 各状态贡献的"主动力" ----
	match state:
		State.BASK, State.DRINK:
			force += _force_perch(delta)
		State.SHELTER:
			force += _force_shelter(delta, bounds)
		State.FLEE:
			force += _force_flee(delta, extra)
		State.SEEK, State.COURT, State.CRUISE:
			force += _force_seek_or_cruise(delta, bounds, extra)

	# ---- ③ 同群分离（Boids 的 separation；cohesion/alignment 不适用于蝴蝶，故意不做） ----
	if _flag("flocking", true) and not neighbors.is_empty():
		force += _force_separation(neighbors)

	# ---- ④ 风的拖曳：这是"接天气"的核心 —— 风把蝴蝶整体吹偏 ----
	var wdir := _wind_vec(wind)
	if wdir.length_squared() > 0.0001:
		var strength := _wind_strength(wind)
		# 风对**速度**的直接拖曳（不是加速度）：让蝴蝶明显被推着走
		var drag := clampf(_num("wind_drag", 0.35) * (0.4 + 0.6 * strength), 0.0, 1.0)
		velocity = velocity.lerp(wdir * (1.0 + strength * 1.4), clampf(drag * delta * 2.0, 0.0, 1.0))
		# 阵风还会"推歪"：给一个与飞行方向垂直的抖动力，飞得歪歪扭扭
		var side := wdir.cross(Vector3.UP)
		if side.length_squared() > 0.0001:
			var turb := float(wind.get("turbulence", 0.3))
			force += side.normalized() * (turb * 1.4 + strength) * _signed_noise(delta)
		# 顺风省力：迎着风飞时多给一点推力，免得整群被吹出区域后回不来
		var along := velocity.normalized().dot(wdir)
		force += velocity.normalized() * maxf(0.0, -along) * (0.4 + strength)

	# ---- ⑤ 避地 / 边界软回弹（含"别飞出指定区域"这条硬需求） ----
	force += _force_bounds(delta, bounds)
	if _flag("ground_avoid", true):
		force += _force_ground(delta, bounds)

	# ---- ⑥ 积分：a -> v -> p（限速 + 限加速度，语义清晰且数值稳定） ----
	var accel_limit := maxf(0.01, _num("accel", 1.8))
	force = force.limit_length(accel_limit * 3.0)
	accel_now = force
	velocity += force * delta
	var speed_cap := _speed_cap(weather)
	velocity = velocity.limit_length(speed_cap)
	# 兜底：速度几乎为零时给一个随机方向，否则蝴蝶会"悬停死"在某个点（数值上极其难看）
	if velocity.length_squared() < 0.0004:
		velocity = _random_dir() * speed_cap * 0.35
	var before := position
	position += velocity * delta
	# ---- ⑥b ★ 单帧位移上限（"禁止飞行时瞬移"的最后一道闸）----
	#   为什么需要它：位置不止在这里被推进 —— `_force_bounds()` 会**硬夹**下边界、
	#   `_force_ground()` 可能把蝴蝶顶起来、BASK/DRINK 会朝落脚点靠拢。
	#   任一处一旦算错（或帧长抖动、区域被改小），蝴蝶就会在一帧里"闪"出很远，
	#   而肉眼对位置突变的容忍度几乎为零 —— 所以这里统一加一道**物理上不可能超出**的上限：
	#     单帧位移 <= min(speed_cap, speed_max) * delta * 系数
	#   正常飞行时这个上限永远够用（推不动它），只在异常时才咬合，把"瞬移"降级成"快速移动"。
	var max_step := maxf(0.01, _speed_cap(weather)) * delta * maxf(1.2, _num("max_step_factor", 1.6))
	var moved := position - before
	var md := moved.length()
	if md > max_step and md > 1e-6:
		position = before + moved / md * max_step
		# 速度也跟着收敛，否则下一帧还会再冲一次
		velocity = velocity.limit_length(max_step / maxf(0.0001, delta))
		moved = position - before
	distance_travelled += before.distance_to(position)

	# ---- ⑦ 贴图/视觉参数与变换 ----
	_update_visual_params(delta, wind, weather)
	_sync_transform(delta)


## 状态机：决定"现在该干什么"。
## 优先级（高 -> 低）：受惊逃逸 > 避风避雨 > 停歇回能 > 觅食趋花 > 巡飞。
## 参数：delta（秒）、weather（天气字典，可空）、extra（附加输入，可空，坐标为本地空间）。
## 副作用：改 state / _state_timer / _target / _threat / _perch。
func _update_state(delta: float, weather: Dictionary, extra: Dictionary) -> void:
	# ① 受惊：extra.threat（本地坐标）很近 -> FLEE（每只蝴蝶独立判定，不用每帧都查）
	#    ★ 出生后的 `flee_grace`（默认 1.5 秒）内不进入 FLEE：
	#      实测教训 —— 蝴蝶群被"注入到玩家面前 4 米"时，正好落在 4 米的受惊半径内，
	#      于是整群一出生就在逃（实测 90 帧后 12 只里 10 只 FLEE），观感很怪。
	#      给一段缓冲期，让它们先正常飞起来；之后玩家再靠近才会惊飞。
	var threat_v: Variant = extra.get("threat", null)
	if threat_v is Vector3 and _clock >= 1.5:
		var d := position.distance_to(threat_v as Vector3)
		if d < 4.0:
			_threat = threat_v as Vector3
			if state != State.FLEE:
				state = State.FLEE
				_state_timer = 1.6
				_target = null
		elif state == State.FLEE and d > 6.0:
			state = State.CRUISE
			_state_timer = 1.0

	# ② 恶劣天气 -> SHELTER（风大或雨大）。天气是**全局**的，所以整群会一起改行为 —— 这是对的。
	var need_shelter := false
	if not weather.is_empty():
		var wv := float(weather.get("wind", 0.0))
		var rv := float(weather.get("rain", 0.0))
		need_shelter = wv >= _num("shelter_wind", 0.75) or rv >= _num("shelter_rain", 0.30)
	if need_shelter:
		if state != State.SHELTER:
			state = State.SHELTER
			_target = null
			_state_timer = 3.0
		return
	if state == State.SHELTER:
		# 天气好转 -> 出来飞
		state = State.CRUISE
		_state_timer = 1.0

	# ③ 停歇回能
	if state == State.BASK or state == State.DRINK:
		if energy >= 0.995 or _state_timer <= 0.0:
			state = State.CRUISE
			_state_timer = rng.randf_range(1.0, 2.5)
		return

	# ④ 能量低 -> 落地晒太阳
	if energy <= _num("rest_energy", 0.25) and state != State.FLEE:
		# ★ 先兜底把 `_perch` 设成**当前位置**，再尝试找花/叶落脚点。
		#   为什么必须先兜底（实测的瞬移 bug）：`_find_perch()` 在**节流窗口内**会直接
		#   返回传入的 `from`，而 `_perch` 的默认值是**原点 (0,0,0)** ——
		#   只要这次没算过落脚点，蝴蝶就会朝世界原点冲（旧实现是每帧 lerp 25%）。
		#   现在即使找不到落脚点，也只会在原地"停下"，不会跳。
		_perch = position
		state = State.BASK
		_state_timer = rng.randf_range(2.5, 6.0)
		# 落脚点：附近的花/叶子上，找不到就原地地面上方一点
		_perch = _find_perch(position, 6.0)
		_target = null
		return

	# ⑤ 到点重新决策：巡飞 / 趋花 / 求偶
	if _state_timer > 0.0:
		return
	var roll := rng.randf()
	if roll < 0.42:
		var t := _find_flower_local(position, _num("seek_range_m", 12.0))
		if t != null:
			state = State.SEEK
			_target = t
			_state_timer = rng.randf_range(3.0, 7.0)
		else:
			state = State.CRUISE
			_target = _pick_cruise_waypoint()
			_state_timer = rng.randf_range(2.0, 5.0)
	elif roll < 0.56:
		var p: Variant = extra.get("partner", null)
		if p is Vector3:
			state = State.COURT
			_target = p
			_state_timer = rng.randf_range(2.0, 4.0)
		else:
			state = State.CRUISE
			_target = _pick_cruise_waypoint()
			_state_timer = rng.randf_range(2.0, 5.0)
	else:
		state = State.CRUISE
		_target = _pick_cruise_waypoint()
		_state_timer = rng.randf_range(2.0, 5.0)


## ★ 巡飞航点：区域内的随机点，但**高度偏好下部**（体积加权偏向低处）。
##
## 为什么需要它（用户实测反馈："蝴蝶都飘在天上"）：
##   原来 CRUISE 只有"随机游走 + 噪声"，垂直方向**没有任何偏置** ——
##   于是一个 28×6×28 的大区域里，蝴蝶会均匀铺满整个 6 米高度，
##   多数飘在半空/天上、离人很远，远看就是一颗颗白点。真实蝴蝶绝大多数时间在
##   离地 0.3~2 米的**花层**活动（那里才有蜜源，也方便躲避）。
##   这里用 `u^1.8` 把随机数往 0 压（偏向区域下部），再夹到 [min_height_m, 区域高 45%]。
##
## 参数：无（用 advance() 记下的 `_bounds`，本地空间）。
## 返回值：本地坐标的航点 Vector3。
func _pick_cruise_waypoint() -> Vector3:
	var lo := _bounds.position
	var hi := _bounds.position + _bounds.size
	var floor_y := lo.y + maxf(0.2, _num("min_height_m", 0.35))
	# 天花板取"区域高的 35%"与"绝对 2.5 米"的**较小者**：
	#   只按比例的话，6 米高的区域会算出 2.1 米（加上区域底就更高），仍然偏高；
	#   真实蝴蝶绝大多数时间在花层（离地 0.3~2 米）——那里才有蜜源，也才看得见。
	var band := minf(_bounds.size.y * 0.35, 2.5)
	var ceil_y: float = floor_y + maxf(0.35, band)
	var u := pow(rng.randf(), 1.8)          # 偏向 0 -> 偏低
	var y := floor_y + (ceil_y - floor_y) * u
	# 水平留 8% 边距：航点别正好落在软回弹带里，否则一到就被推走
	var mx := _bounds.size.x * 0.08
	var mz := _bounds.size.z * 0.08
	return Vector3(
		rng.randf_range(lo.x + mx, hi.x - mx),
		y,
		rng.randf_range(lo.z + mz, hi.z - mz))


# ==================== 各状态的力 ====================

## 巡飞 / 趋目标（SEEK、COURT 共用 seek 力；CRUISE 用移动生态学模型）。
##
## ★★ CRUISE 的做法（对应"蝴蝶现在都是直飞的"这条反馈）★★
##   不再用"随机游走 + 往航点直飞"，改成**方向相关随机游走（CRW）+ Lévy 步长 +
##   区域限制搜索（ARS）**，模型出处见 butterfly_tuning.gd 顶部：
##     ① 每个"决策段"（step_time_s）掷一次航向：
##        · 以**上一个航向**为基准（heading_persistence）—— 这就是"相关"；
##        · 小转角为主（turn_scale_deg），另有 turn_heavy_p 概率来一次大转角（重尾）
##          -> 轨迹是"一段直、忽然拐"，而不是激光直线、也不是无头苍蝇；
##     ② 段内速度目标随 Lévy 重尾步长起落 -> 长直段与短促搜索交替；
##     ③ 段内再叠一层正弦侧摆（lateral_weave）-> 连直飞段也在小幅左右晃；
##     ④ 附近有资源时进 ARS：转角放大、速度压低 -> 在花丛里打转。
##   这样"直飞"消失，"环境互动"也有一半（感知资源就改变飞行模式）。
##
## 参数：delta、bounds、extra（含 ars_dir / ars_active，本地坐标）。
## 返回值：本状态贡献的加速度（米/秒²）。
func _force_seek_or_cruise(delta: float, bounds: AABB, extra: Dictionary) -> Vector3:
	var f := Vector3.ZERO
	# ---- 资源感知（ARS）：由 swarm 注入"资源在哪"，这里算"朝它偏"的方向 ----
	var ars_on := _flag("area_restricted_search", true)
	_ars_active = false
	# ★ 参与度门槛：每只蝴蝶有一个**固定的**随机偏置 `_ars_bias`（setup 时定），
	#   只有 `_ars_bias < ars_participation` 的才吃 ARS。
	#   为什么需要它（用户反馈"反复在两点之间散开再重聚"）：
	#     如果整群都响应同一个资源点，它们就会**同步**一起收拢、一起散开、再一起收回 —— 
	#     看着像一个整体在两点间来回。真实蝴蝶群里只有一部分个体会被某处蜜源吸住，
	#     其余照常巡飞 —— 群就不会整体收拢，也不会整体散开。
	var part := 1.0
	var pv: Variant = extra.get("ars_participation", 1.0)
	if pv is float:
		part = clampf(pv as float, 0.0, 1.0)
	if ars_on and _ars_bias < part:
		var hit: Variant = extra.get("ars_hit", false)
		var ap: Variant = extra.get("ars_pos", null)
		if hit is bool and (hit as bool) and ap is Vector3:
			var to_res := (ap as Vector3) - position
			var d_res := to_res.length()
			# 只有在感知半径内才算"找到资源"（这就是 ARS 的感知半径语义）
			if d_res > 0.05 and d_res <= maxf(0.2, _num("ars_radius_m", 3.0)):
				_ars_dir = to_res / d_res
				_ars_active = true
	if not _ars_active:
		_ars_dir = Vector3.ZERO

	# ---- ① CRW：按决策段更新航向 ----
	var step_time := maxf(0.05, _num("step_time_s", 0.45))
	_crw_timer -= delta
	if _crw_timer <= 0.0 or _crw_heading.length_squared() < 1e-6:
		_crw_timer = step_time * rng.randf_range(0.7, 1.3)   # 段长也抖动一下，避免整群同步转弯
		_crw_step_len = _levy_step()
		_crw_heading = _crw_turn()
	# ---- ② Lévy 步长 + 速度目标 ----
	# ARS 时速度压低（在花丛里飞得慢而黏）
	var speed_scale := _num("ars_speed_scale", 0.55) if _ars_active else 1.0
	var want_speed := clampf(_crw_step_len / step_time, 0.25, 1.0) * _num("speed_max", 2.2) * speed_scale
	f += _crw_heading * maxf(0.0, want_speed - velocity.dot(_crw_heading)) * 3.2
	# ---- ③ 侧向摆动：绕上行轴做小幅正弦摆 ----
	var weave := _num("lateral_weave", 0.55)
	if weave > 0.0:
		_weave_phase += TAU * _num("lateral_weave_hz", 1.1) * delta
		var up := Vector3.UP if absf(_crw_heading.dot(Vector3.UP)) < 0.95 else Vector3.RIGHT
		var side := _crw_heading.cross(up)
		if side.length_squared() > 1e-6:
			f += side.normalized() * (sin(_weave_phase) * weave)
	# ---- ③b ARS：朝资源点**轻微**牵引（不是直冲过去，而是"在附近打转"）----
	#   为什么要"轻微"：真蝴蝶在花丛里是绕来绕去地搜，不是直线扑向某一朵花。
	#   转角尺度已经在 _crw_turn 里放大了（ars_turn_scale_deg），这里只补一点点朝向偏置。
	if _ars_active:
		f += _ars_dir * 0.9
	# ---- ④ 高频小噪声：让轨迹不是光滑曲线 ----
	#    ⚠ 幅度**必须远小于** CRW 的转向力（上面那项 3.2×速度差）。
	#      第一版给 0.35，实测结果：噪声完全主导方向 —— 把 heading_persistence
	#      从 0.72 调到 0.99、turn_scale 从 25° 调到 1°，平均转角反而从 3.25° 变到 4.08°
	#      （CRW 参数等于失效）。降到 0.08 后 CRW 才是方向的主导项。
	#      量级参考：CRW 转向项在典型速度差 0.5 m/s 时约 1.6 m/s²。
	if _flag("flight_jitter", true):
		f += Vector3(rng.randf_range(-1.0, 1.0), rng.randf_range(-0.4, 0.4),
				rng.randf_range(-1.0, 1.0)) * 0.08

	# ---- ④b 先算"聚散阶段"：散 / 聚 的强度，以及本轮聚散中心 ----
	#   为什么要提前算：聚散阶段要**压制个体趋花力**（见 ⑤ 的 cycle_v），
	#   否则每只蝴蝶各自冲向自己的花，整群根本不会在同一处聚/散 ——
	#   实测：只加收拢力 2.8 而不压制个体目标时，质心到中心距离在"聚"阶段
	#   反而比"散"阶段更大（4.73 m > 4.51 m），等于只散不聚。
	var gpos: Variant = extra.get("gather_pos", null)
	var pulse_v := float(extra.get("pulse", 0.0))
	var regroup_v := float(extra.get("regroup", 0.0))
	var cycle_v := maxf(pulse_v, clampf(regroup_v, 0.0, 1.0))

	# ---- ⑤ 趋目标（SEEK/DRINK/COURT 才是"冲着某个点去"；CRUISE 不直冲）----
	var goal: Variant = null
	if state == State.SEEK or state == State.DRINK or state == State.COURT:
		goal = _target
	# extra.attract_to：由 swarm 注入的"群组级吸引点"（例如玩家手里的花、蜜源）
	if goal == null:
		var av: Variant = extra.get("attract_to", null)
		if av is Vector3:
			goal = av
	if goal != null:
		var gp := Vector3.ZERO
		if goal is Vector3:
			gp = goal as Vector3
		else:
			# 只接受 Vector3（本地坐标）。非 Vector3 的目标视为"没有目标"并清掉，
			# 避免残留一个永远够不着的目标把蝴蝶钉在某个方向上。
			_target = null
			return f
		var to := gp - position
		var dist := to.length()
		var max_range := _num("seek_range_m", 12.0)
		if dist > 0.05 and dist <= max_range * 1.5:
			# 距离越近推力越小（接近目标时自然减速/盘旋，而不是一头撞上去）
			# ★ 聚散阶段把个体趋花力压到 25%：让"整群聚到新中心 / 从新中心散开"真的发生，
			#   而不是每个个体都继续各奔各的花（那正是"散不开也聚不拢"的原因）。
			var seek_k := 1.0 - 0.75 * cycle_v
			f += to.normalized() * (2.2 * clampf(dist / maxf(0.5, max_range * 0.4), 0.15, 1.0) * seek_k)
		else:
			_target = null
	# ★★ 群体聚散周期：散 = 从**本轮新中心**外推，聚 = 朝同一个新中心收拢 ★★
	#   为什么不再用"靠近自己的目标就外推"（旧实现，就是它造成"两点之间反复聚散"）：
	#     蝴蝶的目标（SEEK 的花 / COURT 的同伴）几乎固定不变，于是
	#     "冲向目标 -> 进半径后被推开 -> 再冲回去" 形成一个**稳定振荡环**：
	#     每 25~70 秒重复一次，聚散发生在同一批坐标上。
	#   现在中心每轮换（swarm 侧 `_new_gather_center()`），所以聚、散都在新地方发生。
	if gpos is Vector3:
		var to_g := (gpos as Vector3) - position
		var d_g := to_g.length()
		if d_g > 0.05:
			var dir_g := to_g / d_g
			# ★★ 关键：**同时改航向**，不能只加力 ★★
			#   实测教训：CRW 的推进力是 `heading * (want_speed - v·heading) * 3.2`，
			#   典型可达 7 m/s²，而收拢力只有 2.8 —— 光加力会被 CRW 的随机航向完全盖住，
			#   实测"聚"阶段质心到中心距离反而变大（6.24 m > 散 5.78 m），等于只散不聚。
			#   这和之前"边界只推不拐 -> 蝴蝶顶在边界排队"是同一个问题：
			#   **力只能推，航向才能真的带它走过去**。
			if pulse_v > 0.5:
				_crw_heading = (_crw_heading - dir_g * (2.2 * delta)).normalized()
			elif regroup_v > 0.001:
				# 收拢时朝中心偏转（强度随 regroup 时间衰减）
				_crw_heading = (_crw_heading + dir_g * (2.6 * regroup_v * delta)).normalized()
				_crw_timer = maxf(_crw_timer, 0.15)
			if pulse_v > 0.5:
				# 散：离中心越近推得越狠（在中心原地"炸开"的感觉），并整体拔高
				var hover := maxf(0.5, float(extra.get("hover", 3.0)))
				var closeness := clampf(1.0 - d_g / hover, 0.0, 1.0)
				f -= dir_g * (1.0 + 2.0 * closeness)
				f.y += 0.9
			elif regroup_v > 0.001:
				# 聚：朝新中心收拢（强度随时间衰减，避免"啪"一下吸成一坨）
				# ⚠ 实测调参：原来 1.3 太弱 —— 散开平均 5.9 m 后，收拢阶段质心反而更远
				#   （6.06 m > 5.86 m），等于"只散不聚"。2.8 才能把质心明显拉回来。
				f += dir_g * (2.8 * regroup_v)
	return f


# ==================== 移动生态学模型（CRW / Lévy / ARS）====================

## Lévy 步长：**Pareto 重尾**采样 `L = Lmin * (1-U)^(-1/(α-1))`，再夹到合理区间。
##
## 为什么用 Pareto 而不是高斯：高斯步长的随机游走会"均匀糊开"，
## 而昆虫觅食实测是**重尾**的 —— 大量短步（原地搜索）+ 少量超长步（远距离迁移），
## 这正是"在一丛花里打转，忽然直线飞走去下一丛"的来源。
## 参数 α = `levy_alpha`（默认 1.6，昆虫典型区间 1.5~2.0）。
## 返回值：米。长步上限取 4 倍基准，避免偶发极端值把蝴蝶"甩"到区域边界。
func _levy_step() -> float:
	var alpha := clampf(_num("levy_alpha", 1.6), 1.05, 3.0)
	var base := maxf(0.15, _num("speed_max", 2.2) * 0.35)   # 基准步长 ~0.77 m
	var u := clampf(rng.randf(), 1e-6, 0.999999)
	var l := base * pow(1.0 - u, -1.0 / (alpha - 1.0))
	# ARS 时把长步砍掉大半：在资源附近不该"一飞而去"
	if _ars_active:
		l *= 0.45
	return clampf(l, base * 0.35, base * 4.0)


## CRW 转角：以**上一段航向**为基准偏转一个角度，返回新的单位航向。
##
## 转角分布 = 小转角为主 + 重尾大转角：
##   · 基础尺度 `turn_scale_deg`（默认 25°）—— 决定"有多歪"；
##   · 以 `turn_heavy_p` 概率改用 `turn_heavy_deg`（默认 110°）—— 就是"忽然换方向"；
##   · ARS 时把小转角尺度换成 `ars_turn_scale_deg`（默认 55°）—— 原地打转；
##   · 偏转方向是**三维**的（绕一个随机轴转），所以也会拐上下，不再只在水平面里绕圈。
## 参数：无（用 `_crw_heading` 与 rng）。
## 返回值：单位向量（本地空间）。
func _crw_turn() -> Vector3:
	# 基准方向：已有航向（CRW 的"相关"），首次用当前速度方向，兜底用随机方向
	var base := _crw_heading
	if base.length_squared() < 1e-6:
		base = velocity
	if base.length_squared() < 1e-6:
		base = _random_dir()
	base = base.normalized()
	# ARS：偏转尺度放大（打转）；否则小转角为主，偶尔重尾大转角
	var scale_deg := _num("turn_scale_deg", 25.0)
	if _ars_active:
		scale_deg = _num("ars_turn_scale_deg", 55.0)
	elif rng.randf() < _num("turn_heavy_p", 0.06):
		scale_deg = _num("turn_heavy_deg", 110.0)
	# 用两三个均匀样本近似"集中在 scale_deg 附近"的偏转（比高斯更抗极端值）
	var ang := deg_to_rad(scale_deg * rng.randf_range(0.35, 1.0))
	# 偏转轴：与 base 垂直的随机方向（三维，所以上下也会拐）
	var axis := _perp(base, rng)
	var dir := base.rotated(axis, ang)
	# 与基础方向保持 persistence 的"拉回"：persistence 越高越贴近 base
	var p := clampf(_num("heading_persistence", 0.72), 0.0, 0.99)
	dir = (dir * (1.0 - p) + base * p)
	if dir.length_squared() < 1e-6:
		return base
	return dir.normalized()


## 取一个与 `v` 垂直的随机单位向量（用于把航向绕随机轴偏转）。
## 参数 v：基准单位向量；r：随机源。
## 返回值：单位向量，与 v 点积 ≈ 0。
func _perp(v: Vector3, r: RandomNumberGenerator) -> Vector3:
	# 选一个与 v 不平行的参考轴（挑最不平行的那个基轴，数值最稳）
	var ref := Vector3.RIGHT
	if absf(v.dot(Vector3.RIGHT)) > 0.9:
		ref = Vector3.UP
	var t := v.cross(ref)
	if t.length_squared() < 1e-6:
		t = v.cross(Vector3.FORWARD)
	t = t.normalized()
	t = t.rotated(v, r.randf_range(0.0, TAU))    # 绕 v 随机转到某个方位
	return t.normalized()


## 同群分离力：对太近的邻居施加反向推力（1/r 权重，越近越强）。
## 参数 neighbors：Array[Vector3]（**世界坐标**；swarm 每帧算一次，所有蝴蝶共用，避免 O(n²) 重复）。
## 返回值：加速度。
func _force_separation(neighbors: Array) -> Vector3:
	var r := maxf(0.05, _num("separation_m", 0.35))
	var w := _num("separation_weight", 1.8)
	var f := Vector3.ZERO
	var me := position
	var hits := 0
	for nv in neighbors:
		if not (nv is Vector3):
			continue
		var other: Vector3 = nv
		var d := me - other
		d.y *= 0.5   # 垂直方向上的分离弱一点：允许上下错开而不用绕开
		var dist := d.length()
		if dist < 0.0001 or dist >= r:
			continue
		f += (d / dist) * ((r - dist) / r)
		hits += 1
	if hits == 0:
		return Vector3.ZERO
	return (f / float(hits)) * w * 2.0


## 停歇（BASK）时的力：把蝴蝶拉向落脚点并"钉"在那里（速度强行衰减）。
## 返回值：加速度。
## 注意：停歇时能量回升在 _update_state 之后由本函数顺带回（见下）。
func _force_perch(delta: float) -> Vector3:
	energy = clampf(energy + _num("energy_gain", 0.16) * delta, 0.0, 1.0)
	var to := _perch - position
	# 强阻尼 + 弹簧：视觉上就是"贴住了"
	velocity *= clampf(1.0 - delta * 4.0, 0.0, 1.0)
	return to * 6.0 - velocity * 3.0


## 避风避雨（SHELTER）的力：往区域的**低处/背风侧**钻，并压低速度。
## 参数 delta、bounds。
## 返回值：加速度。
func _force_shelter(delta: float, bounds: AABB) -> Vector3:
	# 目标：区域底部偏背风一侧（背风 = 风去向的反面，即上风侧；蝴蝶会"躲到上风角的低处"）
	var low := Vector3(
		bounds.position.x + bounds.size.x * 0.5,
		bounds.position.y + maxf(0.2, _num("min_height_m", 0.35)),
		bounds.position.z + bounds.size.z * 0.5)
	var to := low - position
	var f := to.normalized() * 1.8
	f += -velocity * 1.2
	f.y -= 0.6   # 主动下沉，减少暴露在风里
	velocity *= clampf(1.0 - delta * 0.9, 0.0, 1.0)
	return f


## 受惊逃逸（FLEE）：朝远离威胁的方向冲刺。
## 参数 delta、extra（extra.threat 是**本地坐标** Vector3）。
## 返回值：加速度。
func _force_flee(delta: float, extra: Dictionary) -> Vector3:
	var away := Vector3.ZERO
	var tv: Variant = extra.get("threat", null)
	if tv is Vector3:
		away = position - (tv as Vector3)
		away.y = 0.0
		if away.length_squared() < 0.0001:
			away = _random_dir()
		away = away.normalized()
	elif _threat != Vector3.ZERO:
		away = position - _threat
		away.y = 0.0
		away = away.normalized() if away.length_squared() > 0.0001 else -heading
	else:
		away = -heading
	# 冲刺 + 往上窜一点（蝴蝶受惊会先拔高）
	return away * 4.5 + Vector3.UP * 0.8


## 边界约束（**保证"只在指定区域内飞"这条需求**）：
##   · 水平 / 上方超出 -> 反向力，**力随"超出量"线性增长**（软回弹 + 超调越界越难）
##   · 下方超出 -> 硬夹住位置（贴着下边界飞，但不允许穿出去）
## 参数：delta（未用，保留签名一致性）、bounds。
## 返回值：加速度。
##
## ★★ 为什么力要随超出量增长（实测教训）★★
##   第一版是"进边缘带就给固定大小的力"，实测在**阵风**下会外溢：
##   16 只跑 120 帧（风速 strength 0.288 + gust 0.24，wind_influence=1.6）时
##   实测最大越界 **0.392 m** —— 因为固定力只有 ~3 m/s²，而蝴蝶在区域外的速度可以到 1.5 m/s，
##   拐回来要时间，越界就被"看见"了。
##   现在改成 margin 内用基础力、margin 外按 (超出/margin) 线性放大（上限 30 倍），
##   越界越远回弹越猛 -> 实测越界收敛到 ≈0（见 CONTRACT 的验收项）。
## 注意：这里就地改 position（硬夹下方），因为调用它的 advance() 之后才积分位置。
func _force_bounds(delta: float, bounds: AABB) -> Vector3:
	var margin := maxf(0.01, _num("edge_margin_m", 0.8))
	var lo := bounds.position
	var hi := bounds.position + bounds.size
	var f := Vector3.ZERO
	var p := position
	# 水平 X
	if p.x < lo.x + margin:
		f.x += _edge_push(lo.x + margin - p.x, margin)
	elif p.x > hi.x - margin:
		f.x -= _edge_push(p.x - (hi.x - margin), margin)
	# 水平 Z
	if p.z < lo.z + margin:
		f.z += _edge_push(lo.z + margin - p.z, margin)
	elif p.z > hi.z - margin:
		f.z -= _edge_push(p.z - (hi.z - margin), margin)
	# 上方：超出就往下压回（比"撞天花板"更自然）
	if p.y > hi.y - margin:
		f.y -= _edge_push(p.y - (hi.y - margin), margin)
	# 下方：硬夹 + 向上推（防钻地）
	var floor_y := lo.y + maxf(0.05, _num("min_height_m", 0.35))
	if p.y < floor_y:
		p.y = floor_y
		position = p
		if velocity.y < 0.0:
			velocity.y = 0.0
		f.y += 2.0
	# ★★ 把"只推不拐"升级成"真的拐回去"（用户反馈"反复在两点之间散开再重聚"）★★
	#   实测：只施加反弹力时风力会与边界力**打平**，蝴蝶于是长期**顶在下风边界**排队
	#   （诊断抓到的聚集点全部落在下风角落 ~(8, 1, -7.5)，紧贴区域边界）。
	#   阵风一变就散开、风再起又吹回同一角落 —— 看起来就是"总在同一处聚散"。
	#   真实蝴蝶不会顶着边界飞，它们会**转身**。所以这里顺手改变 CRW 航向：
	#   在边缘带内把 `_crw_heading` 往**区域内部**偏一点，让它们自己拐出去。
	#   为什么改航向而不是加大力：力再大也只是"顶着推"，航向一转才是真的离开。
	var inward := Vector3.ZERO
	if p.x < lo.x + margin:
		inward.x += 1.0
	elif p.x > hi.x - margin:
		inward.x -= 1.0
	if p.z < lo.z + margin:
		inward.z += 1.0
	elif p.z > hi.z - margin:
		inward.z -= 1.0
	if inward.length_squared() > 1e-6:
		inward = inward.normalized()
		var cx := (lo.x + hi.x) * 0.5
		var cz := (lo.z + hi.z) * 0.5
		var outness := clampf(maxf(
				absf(p.x - cx) / maxf(0.01, (hi.x - lo.x) * 0.5),
				absf(p.z - cz) / maxf(0.01, (hi.z - lo.z) * 0.5)), 0.0, 1.0)
		var steer := lerpf(0.15, 0.6, outness) * 0.35
		_crw_heading = (_crw_heading + inward * steer * 2.0).normalized()
		# 航向刚被改过：本决策段别被 CRW 计时器立刻覆盖（否则等于白改）
		_crw_timer = maxf(_crw_timer, 0.12)
	return f


## 越界推力的幅值：`d` 是"离最近边界的距离"，`margin` 是软回弹带宽度。
## 返回值：加速度（m/s²）。带宽内 3.0、带宽外按超出比例线性放大（上限 30 倍）。
## 说明：这是"软墙"而非硬约束 —— 蝴蝶被吹出去仍能自己拐回来，但越界深度被压到极小。
func _edge_push(d: float, margin: float) -> float:
	if d <= 0.0:
		return 0.0
	var over := maxf(0.0, d - margin)
	return 3.0 + 27.0 * clampf(over / margin, 0.0, 1.0)


## 避地 / 避障：只在水平速度朝下且高度偏低时起效（避免常态干扰）。
## 参数 delta、bounds。
## 返回值：加速度。
## 注意：这里**不做 raycast**（每只每帧 raycast 在 60 只时开销可观，且地形碰撞体分布未知）。
##   改为"高度带"判定：低于 min_height 上方一点的软带内就向上推。
##   真正的"撞地形"由 _force_bounds 的硬夹兜底；要更精确可把 swarm.ground_avoid 配合
##   外部注入的地面高度使用（见 ButterflySwarm 的 ground_probe 约定）。
func _force_ground(delta: float, bounds: AABB) -> Vector3:
	var floor_y := bounds.position.y + maxf(0.05, _num("min_height_m", 0.35))
	var soft := floor_y + maxf(0.05, _num("avoid_distance_m", 1.2)) * 0.5
	var f := Vector3.ZERO
	if position.y < soft:
		var k := (soft - position.y) / maxf(0.001, soft - floor_y)
		f.y += k * 3.0
		if velocity.y < 0.0:
			velocity.y *= 0.85
	return f


# ==================== 视觉 ====================

## 每帧更新着色器里"会动"的参数。
## 参数：delta、wind、weather。
## 副作用：写 mat 的 dihedral / fold_dz / flutter_u / flutter_v / view_dir / sprite_rot / tint / alpha。
## 注意：
##   · 二面角 = 正弦在 [dihedral_min, dihedral_max] 之间摆动 -> 这就是"扑翼"
##   · 大风时把二面角下限抬高（翅膀被吹得合不拢）、并加一点随机歪斜
##   · flock 里每只的 _flap_hz 与 _flap_phase 都不同，所以整群不会同步
##   · `view_dir` / `sprite_rot` 是**面向镜头自适应**的输入（见 _view_dir_local / _sprite_rot_now）
func _update_visual_params(delta: float, wind: Dictionary, weather: Dictionary) -> void:
	_flap_phase = fmod(_flap_phase + TAU * _flap_hz * delta, TAU)
	if mat == null:
		return
	var lo := _num("dihedral_min", 6.0)
	var hi := _num("dihedral_max", 78.0)
	var strength := _wind_strength(wind)
	# 风大：翅膀合不拢（下限抬高）+ 幅度略降
	lo = clampf(lo + strength * 12.0, 0.0, 85.0)
	hi = clampf(hi - strength * 6.0, lo + 2.0, 90.0)
	var s := sin(_flap_phase)
	# 二面角在 [lo, hi] 之间按正弦摆动：s=-1 时贴 lo（下扑到底），s=+1 时到 hi（上扑到顶）
	var dih := (lo + hi) * 0.5 + (hi - lo) * 0.5 * s
	# 停歇时翅合拢（像真的停在叶子上）
	if state == State.BASK or state == State.DRINK:
		dih = lerpf(dih, hi * 0.92, 0.7)
	mat.set_shader_parameter("dihedral", dih)
	# 前后折出：让 V 形有"厚度感"，且随扑翼一起变
	var fold_dz := _num("size_m", 0.22) * 0.28 * (dih / 90.0)
	mat.set_shader_parameter("fold_dz", fold_dz)
	# 薄翅的形变抖动
	var fa := _num("flutter_amount", 0.05)
	mat.set_shader_parameter("flutter_u", 1.0 + fa * sin(_flap_phase * 1.7 + 1.1))
	mat.set_shader_parameter("flutter_v", 1.0 + fa * 0.5 * cos(_flap_phase * 1.3))
	# ★ 面向镜头自适应：把"相机在本地方向"与"额外面内旋转"喂给着色器
	mat.set_shader_parameter("view_dir", _view_dir_local())
	mat.set_shader_parameter("sprite_rot", _sprite_rot_now())
	# 天气微调：雨/阴天时略微压暗并偏冷（与场景其它受weather影响的物件保持一致）
	if not weather.is_empty():
		var base := _color("tint", Color(1, 1, 1, 1))
		var dark := clampf(float(weather.get("cloud", 0.0)) * 0.35 + float(weather.get("rain", 0.0)) * 0.25, 0.0, 0.6)
		var t := Color(base.r * (1.0 - dark), base.g * (1.0 - dark * 0.9), base.b * (1.0 - dark * 0.7), base.a)
		mat.set_shader_parameter("tint", t)
		# 雨里翅膀湿 -> 更暗、更不透
		mat.set_shader_parameter("alpha", clampf(_num("alpha", 1.0) - float(weather.get("rain", 0.0)) * 0.15, 0.05, 1.0))
	if visual != null:
		visual.visible = true
		# ★ 身体的颜色/透明度也跟着天气走（否则阴雨天身体还是亮的，一眼假）
		if _body_mat != null:
			var bt := _color("tint", Color(1, 1, 1, 1))
			if not weather.is_empty():
				var bd := clampf(float(weather.get("cloud", 0.0)) * 0.35 + float(weather.get("rain", 0.0)) * 0.25, 0.0, 0.6)
				bt = Color(bt.r * (1.0 - bd), bt.g * (1.0 - bd * 0.9), bt.b * (1.0 - bd * 0.7), bt.a)
			_body_mat.albedo_color = Color(_body_base.r * bt.r, _body_base.g * bt.g, _body_base.b * bt.b)
			_body_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			_body_mat.albedo_color.a = 1.0


## "相机 - 蝴蝶"方向在**模型本地空间**的单位向量（喂给着色器的 view_dir）。
## 数学：对正交基（基向量为单位长度）来说，`basis.transposed() * v` 就等于把 v 变换到本地空间
##   —— 不需要 `inverse()`（蝴蝶的 scale 只影响长度不影响方向，但我们照样归一化）。
## 返回值：Vector3。拿不到相机（无头 / 无 Camera3D）时返回 (0,0,-1)：
##   表示"从前方看" -> 不着色器不触发自适应旋转，行为与关闭该功能一致。
func _view_dir_local() -> Vector3:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam == null:
		return Vector3(0, 0, -1)
	var to_cam := cam.global_position - global_position
	if to_cam.length_squared() < 1e-8:
		return Vector3(0, 0, -1)
	return (global_transform.basis.transposed() * to_cam).normalized()


## 面向镜头自适应的**面内旋转量**（弧度，带符号）。
## 目标：当蝴蝶"侧对镜头"时（view_dir 在本地近似落在 ±X 上），把翅面往镜头转，
##   让最小正对度 >= edge_min_facing。绕的是模型 +Z（额面法线），所以**不改变飞行朝向**。
## 返回值：radians(edge_min_deg)，符号由相机在本地 X 的方向决定。
## 注意：这里只算"该转多少"和"往哪边转"，实际的角度下限（min_edge）与安全上限由着色器处理 ——
##   着色器知道精确的 facing，并且能在接近正对时自动把旋转量收到 0。
func _sprite_rot_now() -> float:
	var vd := _view_dir_local()
	var facing := absf(vd.z)
	var want := deg_to_rad(_num("edge_min_deg", 26.0))
	# 已经够正对就不转（避免"甩头"）
	if facing >= sin(want):
		return 0.0
	var sign := 1.0 if vd.x >= 0.0 else -1.0
	return want * sign


## 把 heading / velocity 同步到节点变换：
##   · 朝向：`look_at` 把 +Z 对准"前方"（前方 = heading，但**上方用 (heading × 侧向)** 以支持侧倾）
##   · 侧倾（bank）：转弯时绕前进轴滚转，用"水平速度变化率"估计转弯量
##   · 俯仰：速度的 y 分量 -> 抬头/低头
## 参数 delta：用于侧倾的平滑（<=0 时只做瞬时对齐，spawn 时用）。
## 注意：
##   · position 已在 advance 里更新，这里**只动旋转**
##   · 不能直接用 look_at(global_position + heading) 再来加侧倾（会互相覆盖），
##     所以先算出目标基，再用 lerp 平滑（用 `basis` 手工混，避免欧拉角万向锁）
func _sync_transform(delta: float) -> void:
	if velocity.length_squared() > 0.0004:
		var desired := velocity.normalized()
		# 朝向平滑：蝴蝶转向有惯性，别让 yaw 跟着噪声抖
		if delta > 0.0:
			heading = heading.lerp(desired, clampf(delta * 3.5, 0.0, 1.0))
		else:
			heading = desired
		if heading.length_squared() < 0.0001:
			heading = desired
		heading = heading.normalized()
	var up := Vector3.UP
	# 侧倾：用"朝向的横向变化"估计转弯强度（heading 与 velocity 的横向差）
	var lateral := 0.0
	if velocity.length_squared() > 0.0004:
		var vdir := velocity.normalized()
		var right := vdir.cross(Vector3.UP)
		if right.length_squared() > 0.0001:
			lateral = right.normalized().dot(accel_now)
	var bank := clampf(-lateral * 4.0, -1.0, 1.0) * deg_to_rad(_num("bank_max_deg", 35.0))
	if bank != 0.0:
		up = Vector3.UP.rotated(heading, bank)
	# look_at 需要一个非零 up 且与方向不平行；已有兜底
	if heading.cross(up).length_squared() < 1e-6:
		up = Vector3.UP.rotated(heading, 0.2)
	if is_inside_tree():
		look_at(global_position + heading, up)
	else:
		# ★ 树外回退：`look_at()` 硬性要求节点在场景树里，否则**每帧刷一条 ERROR**
		#   （`Condition "!is_inside_tree()" is true` + `Node not inside tree.`）。
		#   无头测试/工具会在树外直接调 advance()，所以这条必须有。
		#
		# ★★★ 这里踩过三个坑，别再用"手工叉乘 + 整体赋 transform" ★★★
		#   第一版写的是 `r = f.cross(up); uu = r.cross(f); transform = Transform3D(Basis(r,uu,f), pos)`：
		#     ① **左手系**：f=+Z、u=+Y 时 r=(-1,0,0)、uu=(0,1,0)，X×Y=-Z -> 行列式 = -1，
		#        节点被镜像；而 `Basis.get_scale()` 会按 det 符号整体乘 -1，
		#        于是 scale 被读成 (-1,-1,-1)（实测）
		#     ② **掉头 180°**：把 +Z 对准 heading，而 `look_at()` 按 Godot 约定把 **-Z** 对准 heading
		#        -> 同一只蝴蝶在树内/树外方向相反（实测 树外基+Z·树内基+Z = -1.000000）
		#     ③ **抹掉缩放**：整体赋 `transform` 会把 `_update_visual_scale()` 写进去的
		#        size_m/aspect 缩放覆盖掉（实测树外 scale=1.0/1.0/1.0，树内=0.22/0.148958/0.22）
		#   现在改用 `Basis.looking_at()`：它与 `Node3D.look_at()` **同一套约定与实现**，
		#   再用 `.scaled()` 把缩放乘回去（只改基、不动 position），三个坑一次解决。
		if absf(heading.normalized().dot(up.normalized())) > 0.999:
			# 与 up 近乎共线时 looking_at 会退化（Godot 会自己纠一下，但会刷警告），先给一点偏置
			up = Vector3.UP.rotated(heading, 0.2)
		basis = Basis.looking_at(heading, up).scaled(scale)
	# 俯仰微调：上升时轻微抬头（直接叠在 basis 上，比再算一次 look_at 省）
	var pitch := clampf(-velocity.y * _num("pitch_per_speed", 8.0), -20.0, 20.0)
	if absf(pitch) > 0.01:
		rotate_object_local(Vector3.RIGHT, deg_to_rad(pitch))
	# 停歇/汲水时不该显示为"悬空平飞"：朝落脚点**缓慢**靠拢（不是瞬移过去）。
	#
	# ★★ 这里原来是一个真实的"瞬移"bug（用户反馈："禁止蝴蝶飞行时瞬移"）★★
	#   旧写法 `position = position.lerp(_perch, 0.25)` 每帧强行拉 25% 到 `_perch`。
	#   而 `_perch` 的**默认值是原点 (0,0,0)**，`_find_perch()` 返回 null 时它也不会被更新 ——
	#   于是每次进 BASK/DRINK（能量耗尽、或 DRINK 判定）蝴蝶都会**朝世界原点以 ~15 m/s 跳过去**
	#   （0.75 m × 60 fps，而且是每帧都把剩余距离砍掉 1/4，视觉上就是"闪一下换位置"）。
	#   现在：① 状态机进 BASK/DRINK 时先把 `_perch` 兜底成**当前位置**（见 _update_state）；
	#        ② 靠拢改成**限速**的（每秒最多 perch_speed 米），落地过程看得见。
	var to_perch := _perch - position
	var d_perch := to_perch.length()
	if state == State.BASK or state == State.DRINK:
		# ★ 二次兜底：落脚点离得太远就**重新就近落脚**（而不是长途跋涉/瞬移过去）。
		#   触发场景：`_perch` 被换区域/换种子后的残留值、或 `respawn_all()` 后忘了清。
		#   没有这条，蝴蝶会以 `perch_speed` 一路直线"飞"回几米外的旧落脚点，看着像瞬移。
		var rearm := maxf(0.5, _num("perch_rearm_distance", 3.0))
		if d_perch > rearm:
			_perch = position
			velocity = Vector3.ZERO
		elif d_perch > 0.0005:
			# 限速靠拢：每秒最多 perch_speed 米，落地过程看得见
			var max_step := maxf(0.05, _num("perch_speed", 1.2)) * delta
			if d_perch <= max_step:
				position = _perch
				velocity = Vector3.ZERO
			else:
				position += to_perch / d_perch * max_step


# ==================== 目标查找（缓存的场景查询） ====================

## 找附近的一朵花/蜜源，返回**本地**坐标；找不到返回 null。
## 参数 from：本地坐标；radius：米。
## 注意：与 _find_perch 一样带 0.75 秒节流（同一次状态决策里不重复扫树）。
func _find_flower_local(from: Vector3, radius: float) -> Variant:
	if _target_scan_t > 0.0:
		return null
	_target_scan_t = 0.75
	var world := to_global(from)
	var hit := _find_flower_world(world, radius)
	if hit.distance_squared_to(world) < 0.0001:
		return null
	return to_local(hit)


## 找附近的一朵花/蜜源。查两个分组：`butterfly_target`（插件专用）与 `flower`（本项目通用）。
## 参数：from（**世界**坐标）、radius（米）。
## 返回值：**世界**坐标 Vector3；找不到时返回 from 本身（调用方自行判断"是否真的找到了"）。
## 注意：**每次调用都遍历场景树**，所以只允许在状态重新决策时调（由 _state_timer 与
##   _target_scan_t 节流），绝不要每帧调。
func _find_flower_world(from_world: Vector3, radius: float) -> Vector3:
	var tree := get_tree()
	if tree == null:
		return from_world
	# ★★ 不再"永远取最近的一朵"（用户反馈："反复在两点之间散开再重聚"）★★
	#   旧实现：`if d < best_d` 只保留**距离最小**的那一朵 —— 场景布局不变时
	#   同一片区域的蝴蝶会永远飞向同一朵花，散开后又收回同一个点。
	#   现在：
	#     ① 收集半径内**所有**候选；
	#     ② 按"**离上一处太近的优先剔除**"（`seek_repeat_avoid_m`）—— 保证下次换地方；
	#     ③ 在剩下的候选里**偏向近的随机挑**（取最近 K=3 作为池，池内随机）——
	#        既保持"就近觅食"的合理性，又不会整片区的蝴蝶挤在同一朵上。
	var cands: Array = []
	var r2 := radius * radius
	for g in ["butterfly_target", "flower"]:
		for n in tree.get_nodes_in_group(g):
			if n is not Node3D or n == self:
				continue
			var p: Vector3 = (n as Node3D).global_position
			var d := p.distance_squared_to(from_world)
			if d <= r2:
				cands.append([d, p])
	if cands.is_empty():
		return from_world
	cands.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	# ② 排除"离上一处太近"的（给"换地方"用）
	var avoid := maxf(0.0, _num("seek_repeat_avoid_m", 3.0))
	var pool: Array = []
	if _last_seek_target is Vector3 and avoid > 0.0:
		for c in cands:
			if (c[1] as Vector3).distance_to(_last_seek_target as Vector3) >= avoid:
				pool.append(c)
	if pool.is_empty():
		# 全都太近（候选本来就少/挤）-> 退而求其次：用全量候选
		pool = cands
	# ③ 偏向近的随机：取最近 K 个作为池，池内随机
	var k := mini(3, pool.size())
	var pick: Vector3 = pool[rng.randi_range(0, k - 1)][1]
	_last_seek_target = to_local(pick)
	return pick


## 找落脚点（停歇用）：优先花/叶，其次原地。
## 参数 from：**本地**坐标（调用时是 self.position）。
## 返回值：**本地**坐标。
## 注意：内部做世界<->本地转换；没有 swarm 父节点时 to_global/to_local 退化为恒等（Godot 会按
##   当前变换算，仍安全）。带 0.75 秒节流：一次状态决策内多次调用只查一次场景树。
func _find_perch(from: Vector3, radius: float) -> Vector3:
	if _target_scan_t > 0.0:
		return from
	_target_scan_t = 0.75
	var world := to_global(from)
	var hit := _find_flower_world(world, radius)
	if hit.distance_squared_to(world) < 0.0001:
		return from
	return to_local(hit + Vector3(0, 0.05, 0))


# ==================== 风 / 天气读取 ====================

## 把风字典转成**世界空间的水平风向单位向量**（含 y 分量 0）。
## 参数 wind：ButterflySwarm.wind_now() 的结构；dir 约定为 Vector2(x, z)。
func _wind_vec(wind: Dictionary) -> Vector3:
	if wind.is_empty():
		return Vector3.ZERO
	var d: Variant = wind.get("dir", null)
	if d is Vector2:
		var d2: Vector2 = d
		if d2.length_squared() < 1e-8:
			return Vector3.ZERO
		return Vector3(d2.x, 0.0, d2.y).normalized()
	return Vector3.ZERO


## 风的归一化强度（0..~1.5），用来调扑翼、拖曳与"合不拢"程度。
func _wind_strength(wind: Dictionary) -> float:
	if wind.is_empty():
		return 0.0
	var s := float(wind.get("strength", 0.0))
	var g := float(wind.get("gust", 0.0))
	return clampf(s + g * 0.3, 0.0, 1.6)


## 本帧速度上限：风速越大越难控（gust_penalty），雨里略慢，停歇时几乎不动。
func _speed_cap(weather: Dictionary) -> float:
	var base := maxf(0.05, _num("speed_max", 2.2))
	if state == State.BASK or state == State.DRINK:
		return base * 0.12
	if state == State.SHELTER:
		base *= 0.55
	if not weather.is_empty():
		base *= (1.0 - clampf(float(weather.get("rain", 0.0)), 0.0, 1.0) * 0.35)
		base *= (1.0 - clampf(float(weather.get("wind", 0.0)), 0.0, 1.5) * 0.15)
	return maxf(0.05, base)


## 有符号的低频噪声（-1..1）：用两个不同频率的正弦叠出"不像随机数"的缓慢扰动。
## 参数 delta：用于推进内部相位（本函数是**有状态**的，靠 _noise_phase 累加）。
## 注意：故意不用 rng.randf_range(-1,1)（那会变成白噪声，每帧跳变，视觉上是抖动而不是飘）。
func _signed_noise(delta: float) -> float:
	_noise_phase = fmod(_noise_phase + delta * 1.7, TAU * 100.0)
	return sin(_noise_phase) * 0.6 + sin(_noise_phase * 2.3 + 1.7) * 0.4


# ==================== 只读快照 ====================

## 状态名（测试与调试 UI 用）。★ 新增 State 时记得补这里，否则返回 "?"。
static func state_name(s: int) -> String:
	match s:
		State.CRUISE: return "CRUISE"
		State.SEEK: return "SEEK"
		State.COURT: return "COURT"
		State.BASK: return "BASK"
		State.SHELTER: return "SHELTER"
		State.FLEE: return "FLEE"
		State.DRINK: return "DRINK"
	return "?"


## 只读快照（测试断言用）。不改任何状态。
## 返回值：{state, state_name, energy, position, velocity, speed, dihedral,
##          distance_travelled, has_visual, sprite, crop}
func stats() -> Dictionary:
	var dih := 0.0
	if mat != null:
		var v: Variant = mat.get_shader_parameter("dihedral")
		if v is float:
			dih = float(v)
	return {
		"state": state,
		"state_name": state_name(state),
		"energy": energy,
		"position": position,
		"velocity": velocity,
		"speed": velocity.length(),
		"dihedral": dih,
		"distance_travelled": distance_travelled,
		"has_visual": visual != null and is_instance_valid(visual),
		"sprite": String(sprite_tex.resource_path) if sprite_tex != null else "",
		"crop": crop,
	}

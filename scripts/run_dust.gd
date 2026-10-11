extends Node3D
## 跑动脚底灰尘：**落脚时喷一次**，左右脚交替（两个 GPUParticles3D，one_shot 爆发）。
##
## 触发方式：按**走过的水平距离**判定落脚（每 STRIDE_LENGTH 米 = 一步）。
##   -> 跑得越快，落脚越频繁，灰尘自然越多越大；而且不依赖动画事件，侧移/后退也正常。
##   -> 只有"扬尘强度 > 0"（在地面且有速度）时才累计与触发。
##
## 用法：
##   const RunDustScript := preload("res://scripts/run_dust.gd")
##   if RunDustScript.is_supported():      # headless 下别加进场景树（见下）
##       _dust = RunDustScript.new()
##       add_child(_dust)
##   _dust.set_intensity(0.7)              # 0~1，由调用方按"实际水平速度"算好

##
## ------------------------------------------------------------------ 系统归属与依赖
## 所属系统：玩家（player.gd）的**表现层子模块** —— 纯视觉，不参与任何物理/玩法判定，
##   也不读写角色状态（只读自身的 global_position）。
## 调用方：scripts/player.gd 通过 preload 本脚本 → new() 出节点 → add_child 到角色下，
##   之后每物理帧调用 set_intensity(ratio) 转发"实际水平速度归一化后的扬尘强度"。
## 关键依赖：
##   * 引擎类：Node3D / GPUParticles3D / ParticleProcessMaterial / QuadMesh /
##     StandardMaterial3D / Gradient / GradientTexture2D / GradientTexture1D / AABB；
##   * 无 autoload、无自定义 signal、无外部资源路径 —— 圆斑贴图在 _make_texture() 里
##     程序化生成，所以本文件不依赖任何美术资源，也不需要预导入（.import）文件。
## 主要对外接口：
##   * static is_supported() -> bool      当前环境能否安全使用粒子（入树前的必查项）；
##   * set_intensity(float 0~1)           每帧写强度（0 = 停喷并停止累计距离）；
##   * get_intensity() -> float           读回当前强度（自检/调试用）；
##   * trigger_step()                     触发一次落脚；通常由 _process() 按步幅自动调用。
## 已知的坑与注意事项：
##   1) **绝不要**在 headless 环境把本节点加进场景树：GPUParticles3D 入树会卡死进程（实测）。
##   2) 本节点自身不移动，只靠读 global_position 累计"走过的水平距离"；落脚判定粒度取决于
##      _process 的调用频率（默认每渲染帧一次），掉帧时宁可略微丢步也不会补喷。
##   3) 两只脚的发射器**共享同一个 ParticleProcessMaterial**（_mat）：set_intensity() 改缩放
##      是一次改两只脚；但 amount_ratio 是每只脚各自的，由 trigger_step() 在喷前单独设置。
##   4) 尘团外观在 _setup() 里一次性定型；若 _ready() 因 headless 提前 return，
##      则 _left/_right/_mat 全为 null —— 此后调用 set_intensity() 只写数值不会崩
##      （所有对外访问都带 null 判断）。
##   5) 节点位置决定"脚在哪"：本节点必须挂在角色（或角色脚底）之下，Y 靠 OFFSET_Y 抬一点，
##      否则灰尘会从模型内部冒出来。

# ==================== 可调参数（全在这里） ====================
const FOOT_SPREAD_X := 0.11      # 左右脚横向偏移（两团灰的距离）
const STRIDE_LENGTH := 0.45      # ★ 每走/跑这么远算"落一次脚"（按你的步幅调）
const BURST_AMOUNT := 14         # ★ 每次落脚喷多少颗（满额；实际 = BURST_AMOUNT × 强度）
const QUAD_SIZE := 0.12          # 尘片基准边长（有效大小 = QUAD_SIZE * scale）
# 慢速档缩放区间（无量纲倍数，最终片大小 ≈ QUAD_SIZE × 该值）。调大 = 慢走时灰尘也显得大。
# 全速档见下面的 SCALE_MIN_FAST / SCALE_MAX_FAST；set_intensity() 会按强度在这两组之间插值。
const SCALE_MIN := 0.14          # 慢速缩放区间
const SCALE_MAX := 0.36
const SCALE_MIN_FAST := 0.26     # 全速缩放区间
const SCALE_MAX_FAST := 0.68
# 单颗尘片存活时间（秒）。调大 = 灰在空中停留更久、看着更"厚/脏"；调小 = 更干脆的一闪。
# 注意：one_shot 发射器每次 restart() 后新喷的粒子都活这么久，与落脚频率无关。
const LIFETIME := 0.85
const COLOR := Color(0.72, 0.66, 0.55, 0.55)   # 灰土色
# 初速度方向相对 _mat.direction=(0,1,0) 的锥角（度）。加大 = 更四散、更"炸"；
# 减小 = 更像一股细烟直着往上。35° 是"有散布但不至于横着飞"的折中值（推测）。
const SPREAD := 35.0
# 初速度大小区间（米/秒）。区间拉开 = 快慢不一致，看起来更自然、不像整齐的弹幕。
# 整体调大 = 尘喷得更高更远（但重力只有 0.35 的轻微上浮，别指望它冲天）。
const VEL_MIN := 0.15
const VEL_MAX := 0.90
const GRAVITY_Y := 0.35          # 轻微上浮（尘）
# 阻尼区间（每秒的减速量）。加大 = 尘片很快停在原地，显得"重/贴地"；
# 减小 = 飘得远、显得"轻/散"。（推测：上限 2.0 配合 VEL_MAX=0.9 时，粒子约半秒内就基本停住。）
const DAMP_MIN := 0.8
const DAMP_MAX := 2.0
const EMIT_RADIUS := 0.05        # 每只脚内的小簇半径
const OFFSET_Y := 0.02           # 脚底高度
const EXPLOSIVENESS := 1.0       # 一次全喷出来（落脚是一瞬间）
# 手动给定发射器的局部包围盒，避免粒子刚生成、真实 AABB 还没算出来的那一两帧被视锥剔除
# （表现为整团灰偶尔闪一下/看不见）。范围按"脚边水平 ±2m、上 2m、下 1m"放宽估的；
# 调小到贴近实际范围有可能又出现闪烁，调大只是略微多花剔除开销。
const LOCAL_AABB := AABB(Vector3(-2.0, -1.0, -2.0), Vector3(4.0, 3.0, 4.0))

# ==================== 运行时状态 ====================
# _left / _right：两只脚的发射器节点（_setup() 里创建）。headless 下 _ready() 提前返回，两者恒为 null。
# _mat：两脚共享的 ParticleProcessMaterial；set_intensity() 会动态改写它的 scale_min / scale_max。
# _intensity：当前扬尘强度 0~1。默认 0 —— 静止时不扬尘，且 _process() 会暂停距离累计（死区）。
var _left: GPUParticles3D = null
var _right: GPUParticles3D = null
var _mat: ParticleProcessMaterial = null
var _intensity := 0.0
var _dist := 0.0                 # 距离累计（走满 STRIDE_LENGTH 就落一次脚）
# 上一帧的位置快照（世界坐标，见 _here()）。_ready() 里先填一次，避免第一帧把
# "从原点走到当前位置"的整段距离当成一步而误喷。
var _last_pos := Vector3.ZERO
var _next_foot := 0              # 0 = 下次左脚，1 = 下次右脚


# ==================== 支持性检测（环境兼容） ====================
## 作用：判断当前环境是否允许安全创建/加入 GPUParticles3D。
## 参数：无（static，可在 new() 之前直接调用）。
## 返回：true = 有真实渲染设备（编辑器 / 普通窗口运行）；false = headless（--headless 启动、
##   无显示设备的 CI / 自动化测试）。
## 副作用：无 —— 纯查询，调多少次都安全，不创建任何节点。
## 调用时机：调用方必须在"创建本节点之前"问一次（见文件头用法示例）；
##   一旦节点入了树再发现是 headless 就来不及了（进程会被卡住）。
## 注意：判据只能是 DisplayServer 的名字 —— 同一平台上照样能跑 headless，
##   所以不能按操作系统/平台名来判断。
## headless（无渲染设备）下 GPUParticles3D 一旦进入场景树会把进程卡死 —— 实测确认。
## 调用方在无头环境（自动化测试/CI）请**不要**创建或加入本节点。
static func is_supported() -> bool:
	return DisplayServer.get_name() != "headless"


# ==================== 生命周期 ====================
## Godot 生命周期回调：节点进入场景树、子节点就绪后由引擎调用一次。
## 作用：环境守卫 → 构建两只脚的发射器与共享材质 → 记录起始位置。
## 参数：无（_ready 不带参数）。返回：无。
## 副作用：向场景树 add_child 两个 GPUParticles3D（节点名 DustLeft / DustRight）；
##   并把 _last_pos 初始化为当前世界位置（否则第一帧会把"从原点走到这里"算成一步）。
## 调用时机：引擎自动调用，只调一次；调用方不需要手动调。
## 注意：headless 下直接 return —— 什么都不建，_left/_right/_mat 保持 null；
##   之后调 set_intensity()/trigger_step() 也只会改数值，不会崩（都有 null 判断）。
func _ready() -> void:
	# 环境守卫必须放在最前：本节点一旦带着粒子入树，headless 下进程就卡住了
	if not is_supported():
		return
	# 两脚发射器与共享材质在这里一次性建好；运行期只改强度与 amount_ratio
	_setup()
	# 记录初始位置，避免第一帧的位移被当成一步而误喷
	_last_pos = _here()


# ==================== 步幅累计与落脚判定 ====================
## Godot 每帧回调：把"这一帧走过的水平距离"累加进 _dist，够一步就触发一次落脚。
## 参数：_delta —— 帧间隔秒数。本函数**刻意不用**它：判定基于位移而非时间，
##   这样帧率波动时步频依然稳定，慢走/快跑/侧移/后退都按同一套步幅计算。
## 返回：无。
## 副作用：写 _dist / _last_pos；满足条件时调用 trigger_step()，让某只脚的粒子爆发一次。
## 调用时机：每渲染帧（_process），不是物理帧 —— 纯表现层对时序不敏感，帧回调更省事。
## 注意：
##   * 只取 XZ 平面的距离（Vector2(p.x-last.x, p.z-last.z)），上下坡/跳跃的垂直位移不计步；
##   * 0.02 是强度死区：几乎静止时直接清零累计，免得角色微微挪动磨出一路脏灰；
##   * 因此"原地转身/原地跳"不喷灰，只有真的产生水平位移才计数。
func _process(_delta: float) -> void:
	# 不扬尘时只跟位置，不累计
	var p := _here()
	if _intensity <= 0.02:
		_last_pos = p
		return
	# 用"本帧位移长度"累加（而不是速度 × delta）：帧率变化时步频不会跟着变
	_dist += Vector2(p.x - _last_pos.x, p.z - _last_pos.z).length()
	_last_pos = p
	if _dist >= STRIDE_LENGTH:
		# 直接归零而不是减去 STRIDE_LENGTH：宁可略微丢步，也不要在低帧率下追赶式连喷一串灰
		_dist = 0.0
		trigger_step()


## 作用：取"当前位置"用于步幅累计。参数：无。
## 返回：已在场景树中时返回 global_position（世界坐标）；未入树时退化为 position（局部坐标）。
## 副作用：无（纯只读）。
## 调用时机：_ready() 初始化基准点、_process() 每帧取点。
## 注意：入树必须用世界坐标 —— 角色会被父节点/动画/场景位移带着走，只看局部坐标会漏算父级运动，
##   导致步幅累计偏小甚至为 0；未入树的分支只服务于自检/单测场景（此时没有父级，局部即世界）。
## 当前位置：入树用世界坐标（角色旋转/位移都算得准）；未入树（自检）退化成局部坐标
func _here() -> Vector3:
	return global_position if is_inside_tree() else position


# ==================== 落脚触发与对外接口 ====================
## 作用：让"下一只脚"的发射器爆发一次灰尘，并把下一次落脚切换到另一只脚。
## 参数：无。返回：无。
## 副作用：写 _next_foot（左右交替翻转）；写该脚发射器的 amount_ratio 并 restart() 粒子系统。
## 调用时机：由 _process() 在累计距离达到 STRIDE_LENGTH 时自动调用；外部也可手动调
##   （例如将来接线到动画事件/落地硬直），但会打乱左右交替的节奏。
## 注意：
##   * 每次落脚真的喷出的颗数 ≈ BURST_AMOUNT × _intensity —— "跑得越快灰越多"靠强度实现，
##     而不是靠喷发次数（次数只由步幅决定）；
##   * 强度很低时 amount_ratio 很小，可能肉眼几乎看不到，这是刻意为之（慢走=几乎不扬尘）；
##   * headless 下 _left/_right 为 null：这里只翻转交替标志后安全返回，不报错。
## ★ 触发一次落脚灰尘：左右脚交替，喷的量随强度
func trigger_step() -> void:
	# 按交替标志选脚：_next_foot == 0 用左脚，否则用右脚
	var foot: GPUParticles3D = _left if _next_foot == 0 else _right
	# 1 - x 在 {0,1} 上就是取反，比 if/else 短，也不会漏改某个分支
	_next_foot = 1 - _next_foot
	if foot == null:
		return
	foot.amount_ratio = _intensity     # 跑得越快 -> 这一脚喷得越多
	# one_shot 的发射器必须 restart() 才会重新爆发；只改 emitting 在 one_shot 下不会重播
	foot.restart()


## 设置扬尘强度（外部每帧写入的唯一入口）。
## 参数：intensity —— 0~1 的归一化强度（0 = 完全不扬尘；1 = 全速跑）。
##   入参允许任意外部算法给的裸值（负数、大于 1 等）—— 内部用 clampf 夹到 [0,1]，
##   所以调用方不需要自己先夹。（注意：NaN 被 clampf 后的结果未经验证，调用方应避免传 NaN。）
## 返回：无。
## 副作用：写 _intensity；并在 _mat 存在时线性插值改写共享材质的 scale_min / scale_max
##   （慢速档 → 全速档），于是"跑得越快，尘团越大"。
## 调用时机：由 player.gd 的 update_dust() 转发，每个物理帧都会调（人静止时传 0）。
## 注意：headless 下 _mat 为 null，此分支跳过 —— 只记录数值，不会有任何粒子效果。
## intensity: 0~1（0 = 不扬尘）。决定"每脚喷多少"和"尘团多大"
func set_intensity(intensity: float) -> void:
	var r := clampf(intensity, 0.0, 1.0)
	_intensity = r
	if _mat != null:
		# lerpf(慢速档, 全速档, r)：强度就是"慢/快外观"之间的插值权重
		_mat.scale_min = lerpf(SCALE_MIN, SCALE_MIN_FAST, r)
		_mat.scale_max = lerpf(SCALE_MAX, SCALE_MAX_FAST, r)


## 读取当前扬尘强度。
## 参数：无。返回：0~1 的 _intensity（注意是"夹紧之后"的值，不是调用方传入的原始值）。
## 副作用：无。调用时机：自检/调试，例如判断"现在是否真的在扬尘"。
func get_intensity() -> float:
	return _intensity


# ==================== 程序化资源构建（贴图 / 网格 / 材质） ====================
## 作用：生成一张柔和圆斑贴图，用作粒子的 albedo_texture —— 因此本文件完全不依赖美术资源。
## 参数：无。返回：新建的 GradientTexture2D。
## 副作用：无（纯内存对象，不入场景树、不写文件）。
## 注意：不缓存 —— 每次调用都新建；本文件只在 _make_quad() 里调用一次，所以无需缓存。
## 程序化生成一张柔和圆斑（不依赖任何美术资源）
func _make_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	# 在 45% 处补一个半透明停靠点：没有它，径向渐变从圆心到边缘是直线衰减，圆斑边缘会显得发硬
	g.add_point(0.45, Color(1, 1, 1, 0.55))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	# 64×64 足够：圆斑只在脚边几厘米范围显示，再大只是白占显存
	tex.width = 64
	tex.height = 64
	# 径向填充（从圆心 fill_from 到外沿 fill_to）：得到实心圆斑，而不是条纹
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	return tex


## 作用：造一块粒子用的方形面片（QuadMesh）并配好它的材质。
## 参数：无。返回：带 StandardMaterial3D 的 QuadMesh，边长 = QUAD_SIZE（尚未赋给任何节点）。
## 副作用：无（内部会调 _make_texture() 现场生成一张圆斑贴图）。
## 调用时机：只由 _make_foot() 调用 —— 每只脚一块，共两块，不做共享。
## 注意（下面这几行属性缺一不可）：
##   * SHADING_MODE_UNSHADED —— 尘不受光照影响，暗处/阴影里也不会变黑；
##   * TRANSPARENCY_ALPHA —— 圆斑靠 alpha 抠形，否则会渲染成一个白方块；
##   * BILLBOARD_PARTICLES —— 面片永远正对相机（跟随相机而非跟随速度），侧看不会变成薄片；
##   * vertex_color_use_as_albedo —— 必须开启，否则粒子颜色与 color_ramp 淡出全部失效。
func _make_quad() -> QuadMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2(QUAD_SIZE, QUAD_SIZE)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true      # ★ 不开的话粒子颜色/淡出都不生效
	sm.albedo_texture = _make_texture()
	quad.material = sm
	return quad


## 作用：创建"一只脚"的粒子发射器（one_shot 型，靠 restart() 触发一次爆发）。
## 参数：offset_x —— 该脚相对本节点原点的 X 轴横向偏移（米）。调用方传 ±FOOT_SPREAD_X：
##   负值给左脚（DustLeft）、正值给右脚（DustRight）—— 只是命名约定，本身不影响行为。
## 返回：配置完成的 GPUParticles3D（**尚未** add_child，入树统一由 _setup() 负责）。
## 副作用：无（只改新建对象的属性，不碰任何外部状态）。
## 调用时机：_setup() 里调用两次（左右脚各一次）。
## 注意：process_material 直接复用共享的 _mat —— 因此这里不新建材质，也保证两只脚外观完全一致；
##   运行期唯一能两脚不同的参数是 amount_ratio（由 trigger_step() 逐脚单独设置）。
## 造一只脚的发射器（两只脚共享同一个材质：省资源，缩放改一次就够）
func _make_foot(offset_x: float) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	# amount 是粒子池上限（按满额分配）；一次实际喷多少由触发时的 amount_ratio 决定
	p.amount = BURST_AMOUNT
	# 存活时长取自节点自身属性（不是材质里的参数），两者别混淆
	p.lifetime = LIFETIME
	p.local_coords = false                    # ★ 灰尘留在世界里，不跟着角色跑
	p.one_shot = true                         # ★ 一次爆发（落脚是一瞬间）
	p.explosiveness = EXPLOSIVENESS
	p.draw_pass_1 = _make_quad()
	p.process_material = _mat
	p.position = Vector3(offset_x, OFFSET_Y, 0.0)   # ★ 左脚 / 右脚
	p.visibility_aabb = LOCAL_AABB
	p.emitting = false
	p.amount_ratio = 0.0
	return p


# ==================== 发射器装配 ====================
## 作用：一次性构建两脚共享的粒子材质 _mat，再创建左右两只脚的发射器并入树。
## 参数：无。返回：无。
## 副作用：写 _mat / _left / _right；对自身 add_child 两个 GPUParticles3D（节点名 DustLeft、DustRight）。
## 调用时机：只由 _ready() 调用一次；headless 下根本不会执行到。
## 注意：
##   * _mat 必须在 _make_foot() 之前建好 —— 发射器只是引用它，建晚了就会拿到 null；
##   * 所有粒子手感参数都在这里定型；运行期唯一的动态量是 set_intensity() 改的 scale_min/scale_max
##     与 trigger_step() 改的 amount_ratio，因此要调手感请优先改文件顶部的常量；
##   * 入树顺序决定了节点在场景树里的排列（DustLeft 在前），但不影响渲染结果。
func _setup() -> void:
	# 颜色随时间淡出（与 color 相乘）
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 1))
	ramp.set_color(1, Color(1, 1, 1, 0))
	# 包成 1D 纹理：color_ramp 只接受 Texture，不能直接塞 Gradient
	var rtex := GradientTexture1D.new()
	rtex.gradient = ramp

	# 共享材质：两只脚公用这一份，省一次实例化，也保证左右外观完全一致
	_mat = ParticleProcessMaterial.new()
	# 球形发射区（半径 EMIT_RADIUS）而不是点发射：出生点散开，粒子不会叠成一颗亮星
	_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	_mat.emission_sphere_radius = EMIT_RADIUS
	# 基准方向朝上（配合 GRAVITY_Y=0.35 的轻微上浮），像被脚跟带起来的浮尘
	_mat.direction = Vector3(0, 1, 0)
	_mat.spread = SPREAD
	_mat.initial_velocity_min = VEL_MIN
	_mat.initial_velocity_max = VEL_MAX
	_mat.gravity = Vector3(0, GRAVITY_Y, 0)
	_mat.damping_min = DAMP_MIN
	_mat.damping_max = DAMP_MAX
	_mat.scale_min = SCALE_MIN
	_mat.scale_max = SCALE_MAX
	_mat.color = COLOR
	# color_ramp 与 color 相乘：color 定基调（灰土色），ramp 只负责 alpha 从 1 淡到 0
	_mat.color_ramp = rtex

	# 先建左脚（-X）再建右脚（+X）：与 _next_foot 初值 0 对应，保证第一次落脚喷的是左脚
	_left = _make_foot(-FOOT_SPREAD_X)
	_left.name = "DustLeft"
	_right = _make_foot(FOOT_SPREAD_X)
	_right.name = "DustRight"
	# 两个发射器挂在本节点下（因此随角色移动），但粒子用 local_coords=false 留在世界里
	add_child(_left)
	add_child(_right)
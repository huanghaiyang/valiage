extends Node3D
## 火焰编织 —— 粗大的**横向**螺旋火柱（粒子实现，场景：scenes/fire_tornado.tscn）。
##
## 与火焰喷射一样是朝瞄准方向喷出去的：柱轴（着色器里的本地 +Y）每帧对齐 aim_dir()，
## 起点也走同一套（角色身前 1.05 米高、前方 0.6 米）。
##
## 形状在 assets/shaders/fire_tornado.gdshader 里：沿轴推进 + 绕轴旋转 + 半径张开（漏斗），
## 并且每颗粒子会**沿自己的运动方向被拉长**成火舌（不是圆点）。
##   ★ 那个 billboard 是着色器用 cam_local_pos 自己算的（这样"朝向相机"和"沿运动拉长"
##     才能同时成立），所以场景里节点必须保持 transform_align = DISABLED，别打开。
##
## **分两层**（关键，不是为了堆数量）：
##   · outer 外层：大半径 = 龙卷外壳
##   · inner 内层：小半径 + 大 radius_jitter = 把柱心填满
## 单层只沿圆柱面转，斜着看过去中间是空的（像根管子）。
##
## 对外接口（与另外两个实现一致）：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()
##
## ──────────────────────────── 补充说明 ────────────────────────────
## 【所属系统】术法系统（scripts/spells/），术法 id = "fire_tornado"（中文名"火焰编织"，
##   见 scripts/spells/spell_wheel.gd 的 SPELL_NAMES）。
##   注册处：spell_caster.gd 里的 SPELLS 字典 —— 那张表是本脚本的**唯一入口**，
##   把 id 删掉/改掉，本文件就永远不会被实例化。
##   同类实现对照：flame_jet_particles.gd（粒子火焰喷射）、flame_visual.gd（着色器火焰喷射）、
##   blue_tornado.gd（**竖直**龙卷 —— 与本文的区别就在 _place() 用的基向量，那边保持世界对齐）。
##
## 【关键依赖】
##   1. res://scenes/fire_tornado.tscn —— 视觉实体，里面有 4 个 GPUParticles3D。
##   2. assets/shaders/fire_tornado.gdshader —— 螺旋运动 + 自算 billboard 全在这个着色器里；
##      场景里 4 个 ShaderMaterial 各带一份参数（半径 / 相位 / 热度按层递增）。
##   3. scripts/spells/spell_aim.gd —— aim_dir() / origin_global() 的**唯一**实现，与火焰喷射共用，
##      所以两把法术的弹道行为永远一致（历史上"同一段代码抄两份、只修一处"出过
##      "角色静止时方位差 90°"的事故，别在这里再抄一份）。
##   4. autoload Mana（scripts/spells/mana.gd）—— 每帧调 Mana.spend_rate(delta, mana_per_sec)。
##   5. autoload SpellCaster（scripts/spells/spell_caster.gd）—— 本脚本的**唯一调用方**。
##
## 【对外接口】setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()
##   —— 与其它术法视觉实现签名一致，spell_caster 才能无差别地 call()。
##   ★ 本脚本**没有** has_targeting() / cast_at() / cast_sector() / wants_cast_anim()：
##     它属于"按住左键持续施法"型，永远不会走 spell_caster 的选点/一次性法术分支
##     （对照 flame_scorch.gd 的 cast_at、flame_advance.gd 的 cast_sector）。
##
## 【生命周期 / 调用时机】（可与 spell_caster.gd 逐条对上）
##   1) _ready()：被 add_child 时立刻跑 —— 实例化 .tscn、收集粒子、先全部关掉发射。
##      此刻 setup() **还没被调**（spell_caster 是 add_child 之后才 call("setup")）。
##   2) setup(player, staff)：把玩家/法杖交给 spell_aim.gd；本脚本自己不存位置。
##      若忘了调（或传 null），aim_dir() 会退化到相机前向/上一次方向，起点退化成宿主位置。
##   3) 按住左键期间每帧：spell_caster 对共享实例 call("start_cast")/call("stop_cast")，
##      本脚本再在自己的 _process 里逐帧扣蓝，扣不出来就自己停喷
##      （spell_caster 刻意不看蓝量，理由见那边 _process 的注释：免得施法动画跟着蓝量抖）。
##   4) 本节点被挂在**玩家的父节点**下（见 spell_caster._ensure_jet），不是玩家的子节点 ——
##      所以定位必须写 global_transform（见 _place()）；改成 position 会漏掉父节点变换。
##
## 【已知的坑 / 注意事项】
##   · 场景里 4 个 GPUParticles3D 必须保持 local_coords = true：着色器算出来的是**节点本地坐标**。
##     ★ 与 flame_jet_particles.gd 相反（那边刻意改成 false，好让喷出去的火留在原地）；
##     本文件**不要**照抄那一步，否则粒子不再随火柱轴走，柱体会散架。
##   · 场景里节点 transform_align 必须保持 DISABLED(0)：朝向是着色器自己按 cam_local_pos 算的，
##     引擎的 billboard 会把那个朝向整个覆盖掉（详见本文件头部 ★ 注记）。
##   · cam_local_pos 在 .tscn 里填的 Vector3(0, 0, 10) 只是占位，真实值由 _update_cam_uniform()
##     每帧覆盖。若场景里没有相机（get_camera_3d() 返回 null），这个 uniform 不会更新，
##     粒子朝向会按占位方向算，视觉上像"侧着的薄片"（推测）。
##   · ★ 与本文件上部"分两层"那句话对齐一下：scenes/fire_tornado.tscn 里**实际是 4 层**
##     （outer / mid_outer / mid_inner / inner，每层 amount = 400，合计 1600 颗粒子），
##     4 层的 phase_offset 依次是 0 / 0.25 / 0.5 / 0.75 —— 着色器要求多层必须错开相位，
##     否则各层会叠成同一条飘带而不是一个涡柱。上部那两句"大半径外壳 + 小半径填心"
##     对应**最外与最内**两层，中间两层是过渡层（推测）。
##   · 观感参数（半径、速度、相位、拉长、alpha、heat）全在 .tscn 的 ShaderMaterial 里，
##     想调外观优先改场景；本脚本只负责"什么时候喷、朝哪喷、喷多贵"。

# ==================== 依赖与常量 ====================
## 火柱的场景资产（PackedScene，preload 在**加载期**解析）。
## 路径写死：res://scenes/fire_tornado.tscn 必须存在，否则本脚本连加载都过不去
## （preload 不是运行时查表）。
## 实例化后 add_child 到本节点下并改名为 "FireTornado"；里面预期结构：
##   fire_tornado(Node3D) / vfx_fire_tornado(Node3D) / 4 × GPUParticles3D。
## 换视觉（例如换成蓝色龙卷的资产）只需要换这一行，其余代码不用动。
const TORNADO_SCENE: PackedScene = preload("res://scenes/fire_tornado.tscn")
## 方向 + 起始位置：与火焰喷射的两个实现共用同一份
##
## 这里 preload 到的是 spell_aim.gd 的**类**（RefCounted，不是 autoload），下面用 SpellAim.new()
## 实例化出 _aim；别把它当成自动加载名去直接调用。
## 想改成"从法杖顶端喷"：只改 spell_aim.gd 里的 origin_at_staff（两个术法实现同时生效），
## 本脚本一行都不用动。当前默认 origin_at_staff = false，于是起点 = 角色身前：
## 高度偏移 front_height = 1.05 米、朝角色正前方水平偏移 front_offset = 0.6 米。
## 为什么不让本脚本自己算方向/起点：见文件头【关键依赖】第 3 条（历史上抄两份导致只修一处）。
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

## 每秒耗蓝（单位：点/秒），每帧原样传给 Mana.spend_rate(delta, mana_per_sec)；
## 显式传参是为了**覆盖** mana.gd 里那个 @export spend_per_sec = 22.0
## （22 是火焰喷射的默认值，不显式传就会被那个默认值接管）。
##
## 为什么默认是 34.0：火焰编织比火焰喷射（22）更猛 —— 柱体更粗、覆盖面更大，所以定价更贵。
## Mana 默认 max_mana = 100，所以满蓝连续喷约 100 / 34 ≈ 2.9 秒就耗尽；
## 耗尽后按 mana.gd 的规则恢复（regen_per_sec = 6.0 点/秒、regen_delay = 1.2 秒后才开始回）。
## 调大：更贵、更容易"秒空"，按住一会儿就断；调小：能一直喷，但代价与威力不匹配。
## 想按法术分别调平衡，改这个 @export 即可（这也是本文件唯一一个可调平衡参数）。
@export var mana_per_sec := 34.0     ## 大火柱，比火焰喷射（22）贵

# ==================== 运行时状态 ====================
## 本帧是否"处于施法中"（对外可见，spell_caster 与其它术法实现都读它）。
## 语义是**意图**开关，不代表粒子真的在喷：蓝不够时 _ran_out 会变 true，但 casting 仍为 true
## （spell_caster 刻意不把施法姿势跟着蓝量一起抖）。
## 只由 start_cast() / stop_cast() 改写；本文件其它地方只读。
## ★ 名字别随便改：spell_caster._spawn_cast_instance() 的兜底副本会按属性名复位
##   ["_state", "_state_t", "casting", "_wave_t"]，改名那套兜底就失效了。
var casting := false

## 瞄准方向 + 起点的实现（RefCounted，本文件自己 new，不是 autoload）。
## setup() 之前 player/staff 都是 null：此时 aim_dir() 会退到相机前向或"上一次的方向"，
## 所以**必须先 setup() 再 start_cast()**（这个顺序由 spell_caster 保证）。
var _aim := SpellAim.new()
## .tscn 实例化出来的火柱根节点。只当容器用：位置由本节点（self）的 global_transform 决定，
## 它自己不再单独摆位。_ready 里实例化失败或类型转换失败时保持 / 退回 null。
var _tornado: Node3D = null
## .tscn 里**全部** GPUParticles3D（当前资产是 4 个：outer/mid_outer/mid_inner/inner，各 400 颗）。
## 用遍历收集而**不写死节点路径**，所以往场景里加层/删层都不用改代码。
## 空数组 = 资产坏了（_ready 会 push_warning）：此时 _process 每帧直接空转，什么都不会发生。
## 柱长由着色器决定 = speed × lifetime（场景没显式写 lifetime，用引擎默认 1.0，
## 于是柱长约 4.2～4.6 米 —— 推测）；节点上的 speed_scale = 5.0 只影响推进节奏，
## 想改长度优先动 .tscn 的 lifetime 或着色器的 speed，别指望 speed_scale。
var _emitters: Array[GPUParticles3D] = []
## 上面那些粒子节点里，process_material 恰好是 ShaderMaterial 的那些 —— 只有它们认
## cam_local_pos 这个 uniform，_update_cam_uniform() 要往这些材质上写。
## ★ 收集的是 **process_material**（粒子处理材质），不是 material_override
##   （后者是 StandardMaterial3D，只管外观贴图/混色，没有 cam_local_pos）。
var _materials: Array[ShaderMaterial] = []
## 最近一帧"蓝不够、已停喷"：Mana.spend_rate 返回 false 时置 true，能扣蓝时立刻回 false。
## 语义是**最近一帧**的状态，不是"法力永久耗尽"；回蓝后会自动复燃。
## 由对外接口 ran_out_of_mana() 返回。
var _ran_out := false


# ==================== 生命周期 ====================
## Godot 回调：节点进入场景树时**自动**跑一次（本文件由 spell_caster 在 add_child 时触发）。
##
## 作用：实例化火柱资产 → 挂到自己名下 → 收集粒子与着色器材质 → **先全部关闭发射**
##   （避免场景一加载就在原地满屏喷火）。
## 参数：无（Godot 回调固定签名）。返回值：无。
## 副作用：改场景树（多一个名为 "FireTornado" 的子节点）、写 _tornado/_emitters/_materials、
##   写各 GPUParticles3D 的 emitting = false。
## 调用时机注意：此刻 **setup() 还没被调用**（spell_caster 是 add_child 之后才 call("setup")），
##   所以这里绝不能调 _place()：那时 _aim 的 player/staff 都是 null，摆出来的位置是废的，
##   真正摆位由 start_cast() / _process() 负责。
## 失败路径（两条，都只警告不崩）：资产根节点不是 Node3D；资产里一个 GPUParticles3D 都没有。
##   两种情况下函数直接 return，后续靠 _emitters.is_empty() 自然空转。
## 注意：这不是"传参初始化"的地方（没有参数），player/staff 一律走 setup()。
func _ready() -> void:
	# 显式打开逐帧处理。Node 默认就是开着的，这里写出来是为了让"本脚本要靠 _process 扣蓝"这件事
	# 一眼可见（曾经有过视觉脚本靠 _process 干活却被 set_process(false) 关掉的坑）。
	set_process(true)
	# 资产根节点按约定是 Node3D；`as Node3D` 转换失败时**返回 null 而不报错**，
	# 所以紧跟着必须判空（下面这条 if 就是它的配套）。
	_tornado = TORNADO_SCENE.instantiate() as Node3D
	if _tornado == null:
		push_warning("[FireTornado] 场景根节点不是 Node3D: " + TORNADO_SCENE.resource_path)
		return
	# 改名只为在远程场景树里好认（spell_caster 那边看到的节点名是 "Spell_fire_tornado"）。
	# add_child 之后 _ready 会**立刻**在这个子节点上跑（它自己没有脚本，无副作用）。
	_tornado.name = "FireTornado"
	add_child(_tornado)
	# 收集过程材质：asset 是 4 层，写死路径容易和资产脱节，所以走遍历。
	_collect(_tornado)
	if _emitters.is_empty():
		push_warning("[FireTornado] " + TORNADO_SCENE.resource_path + " 里没找到 GPUParticles3D")
		return
	# 初始一律不喷：spell_caster 是"按住才 start_cast"，这里不关的话选完法术就一直在喷。
	for p in _emitters:
		p.emitting = false        # 没施法不喷


# ==================== 对外接口（全部由 spell_caster 调用） ====================
## 注入施法主体：把玩家与法杖交给 spell_aim.gd，本脚本自己**不保存**位置/朝向。
##
## 参数：
##   player —— 角色根节点（Node3D）。必须带 get_facing_yaw() 方法，spell_aim 才能拿到角色朝向；
##             实际由 spell_caster 按 "player" 分组查找得到（不是硬编码路径）。
##   staff  —— 手里的法杖节点（Node3D）。当前 origin_at_staff = false，所以它暂时用不到，
##             留着是为了与其它术法实现接口一致、且以后切成"从法杖顶端喷"时立刻可用。
## 返回值：无。
## 副作用：只写 _aim 内部字段（player / staff / _host = self），不动场景树、不发信号。
## 调用时机：spell_caster 每次选中本术法、创建视觉实例后**紧接着**调用一次（见 _ensure_jet）。
## 注意：传 null 不会报错 —— spell_aim 会走退化路径（相机前向 / 宿主位置），
##   表现为"火柱从奇怪的固定位置冒出"，排查时先看这里有没有被调到。
func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)


# ==================== 施法开关与状态查询 ====================
# ---------------------------------------------------------------- 对外
## 开始施法（spell_caster 在"按住左键且未被 UI 挡住"时**每帧**调用，必须幂等）。
##
## 作用：置 casting = true → 摆位 → 打开粒子发射。
## 参数：无。返回值：无。
## 副作用：写 casting、写本节点 global_transform（经 _place）、写 4 个粒子的 emitting、
##   并顺带刷新各材质的 cam_local_pos uniform。
## 调用时机：可以在同一帧被连续调多次（spell_caster 的 _process 就是这么写的），
##   所以这里不能有"只生效一次"的累加逻辑；重复调用只会重复摆位，无其它代价。
## 顺序不可换：_place() 必须在 _set_emitting(true) 之前 —— 否则第一帧的粒子会从
##   上一帧的旧位置（首次施法就是节点默认位置/世界原点附近）冒出来，观感像"先炸一小撮再飞出去"。
func start_cast() -> void:
	casting = true
	# ★ 先摆好位置再开喷，避免第一帧从世界原点冒出来。
	#   也正因为先摆位，spell_caster 才能在本帧就拿到正确的 aim_dir()/origin_global()。
	_place()            # 先摆好位置再开喷，避免第一帧从世界原点冒出来
	_set_emitting(true)


## 停止施法（spell_caster 在"松开左键 / 被 UI 挡住 / 换术法"时调用；换术法后本节点会被 queue_free）。
##
## 作用：置 casting = false 并关闭发射。
## 参数：无。返回值：无。
## 副作用：写 casting、写各粒子的 emitting。
## 注意：**刻意不重置本节点的 transform**，也不清空已发射的粒子 ——
##   场景里 4 层都是 local_coords = true，节点停住不动，最后一批粒子就能在原地自然演完、
##   不会跟着玩家瞬移，也不会"啪"地整片消失。
## 注意：停喷后 _process 直接 return，于是 cam_local_pos 也不再更新；
##   若此时相机快速移动，残留的最后一批粒子 billboard 朝向会略有偏差（可接受的小瑕疵）。
func stop_cast() -> void:
	casting = false
	_set_emitting(false)


## 查询是否在施法（spell_caster._sweep_instances() 用它判断"这一发演完没有"，
## 以及兜底副本/kill 流程；接口签名与其它术法实现一致）。
##
## 参数：无。返回值：bool —— true = start_cast() 之后、stop_cast() 之前；false = 其余时候。
## 注意：它读的是 casting 这个**意图**标志，所以"蓝耗尽自动停喷"期间仍会返回 true
##   （此时看 ran_out_of_mana() 才是"喷不出来"）。副作用：无（纯读）。
func is_casting() -> bool:
	return casting


## 查询"最近一帧是否因为蓝不够而停喷"（对外接口，与其它术法实现同名）。
##
## 参数：无。返回值：bool —— true = 上一帧 Mana.spend_rate 扣蓝失败、已经关掉发射。
## 语义是**最近一帧**，不是永久状态：蓝恢复后下一帧就会变回 false（也就是"断续复燃"）。
## 副作用：无（纯读 _ran_out）。
## 注意：本仓库目前**没有**调用点 —— tools/ 下的 verify_*.gd 只验证了其它术法的这个接口
##   （火焰编织暂无对应验证脚本）。保留它一是为了与另外几个实现签名一致，
##   二是留给以后"蓝不够时给 UI/音效反馈"用；不要因为没人调就删掉。
func ran_out_of_mana() -> bool:
	return _ran_out


## 喷射方向（水平、世界空间）—— 实现在 spell_aim.gd，与火焰喷射共用
##
## 参数：无。返回值：Vector3 —— **单位向量**，且 y 分量恒为 0（水平方向）。
##   取值优先级（详见 spell_aim.aim_dir()）：移动中取水平速度方向 → 静止取角色面朝方向
##   → 再退到相机水平前向 → 都没有则**保持上一次的方向**（避免站着不动时朝向乱跳）。
## 副作用：无（但会更新 spell_aim 内部的 _last_dir，所以严格说是"读且带记忆"）。
## 调用时机：_place() 每帧调它；spell_caster 也会直接 call 本方法（选点/调试/验证脚本）。
## 注意：永远不要在这里再写一套方向逻辑 —— 两份拷贝只修一处就会让两个火焰术法行为不一致
##   （历史事故：角色静止时方位差 90°，见 spell_aim.gd 头部说明）。
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 起点（世界坐标）—— 实现在 spell_aim.gd，与火焰喷射共用
##
## 参数：无。返回值：Vector3 —— 世界空间的喷射原点，通常不是本节点当前位置（本节点正是被它摆过去的）。
##   取值优先级（详见 spell_aim.origin_global()）：
##     ① origin_at_staff 为 true 且法杖有效 → 法杖顶端（StaffTip.tip_global，当前**不启用**）；
##     ② 玩家有效 → 玩家位置 + UP × front_height(1.05 米) + aim_dir() × front_offset(0.6 米)；
##     ③ 都没有 → 宿主节点（self）的位置；再没有则 ZERO。
## 副作用：无。
## 调用时机：_place() 每帧调它；spell_caster / 验证脚本也会直接 call。
## ★ 因为第 ② 步又调了一次 aim_dir()，所以它和 aim_dir() 必须**成对**使用，
##   只取起点不取方向会让起点与柱轴对不上（火柱像是斜着长出来的）。
func origin_global() -> Vector3:
	return _aim.origin_global()


# ==================== 每帧更新 ====================
# ---------------------------------------------------------------- 每帧
## 每帧回调（Godot 自动调用；节点在场景树里且 set_process(true) 时每帧跑一次）。
##
## 作用：把火柱位姿刷到当前瞄准方向，并按 mana_per_sec 扣蓝；扣不出来就停喷。
## 参数：delta —— 上一帧到这一帧的秒数（float）。正常约 0.0167（60 FPS），卡顿时会变大；
##   它会被 Mana.spend_rate 乘上 mana_per_sec，所以掉帧**不会**让耗蓝变便宜。
## 返回值：无。
## 副作用：写本节点 global_transform、写各材质 cam_local_pos（经 _place/_update_cam_uniform）、
##   写 _ran_out、写各粒子的 emitting、间接改 autoload Mana 的 current
##   （并触发 Mana 的 changed / emptied 信号 —— 量表面板靠它刷新）。
## 调用时机：施法期间每帧；未施法或资产坏掉时**第一行就 return**（见下）。
## 注意 ①：_place() 在扣蓝**之前**执行 —— 保证"这一帧刚好扣不出来"时，柱体姿态也已经摆到正确位置，
##   否则耗尽那一帧的火柱会晚一帧才摆正（观感上是停喷瞬间柱子闪一下）。
## 注意 ②：本函数只判 casting，不看瞄准是否有效、也不看鼠标是否压在 UI 上 ——
##   那些门禁全在 spell_caster（见那边 _ui_blocks_cast / _cast_armed 的长注释）。
## 注意 ③：蓝耗尽后这里**不会**调 stop_cast()：casting 保持 true，只关 emitting，
##   于是施法姿势和"我在施法"的状态都留着（回蓝后能自动复燃）。
func _process(delta: float) -> void:
	# 资产坏了（_emitters 为空）或没在施法 -> 整帧什么都不做。
	# 放在最前面是刻意的：停喷后连 global_transform / uniform 都不再写，
	# 最后一批粒子就停在原地自然演完（见 stop_cast 的说明）。
	if _emitters.is_empty() or not casting:
		return

	_place()

	# 扣蓝的唯一入口：true = 这一帧的蓝够扣；false = 不够（mana.gd 会顺手把 current 清零）。
	if Mana.spend_rate(delta, mana_per_sec):
		_ran_out = false
		_set_emitting(true)
	else:
		# 记下"这一帧喷不出来"并关掉发射，但**不动 casting**：
		# spell_caster 会继续把施法姿势演下去（它刻意不看蓝量）。
		# ★ 已知观感（推测，未实测）：mana.gd 的恢复有 regen_delay = 1.2 秒延迟，
		#   而且只有扣蓝成功才重置那个延迟计时，所以耗尽后大致是
		#   "停约 1.2 秒 → 攒够一帧的量、复燃一两帧 → 又停"的断续节拍，而不是干脆利落地熄灭。
		_ran_out = true
		_set_emitting(false)


# ==================== 内部实现 ====================
# ---------------------------------------------------------------- 内部
## 柱轴（本地 +Y）对准瞄准方向 -> 横向喷射；起点与火焰喷射一致
##
## 参数：无（方向与起点都从 _aim 现取，保证与本帧的瞄准一致）。
## 返回值：无。
## 副作用：① 写本节点的 global_transform（摆位 + 定姿）；② 经 _update_cam_uniform() 写各材质的
##   cam_local_pos。
## 调用时机：start_cast() 每次调用都跑一遍；施法期间 _process() 每帧跑一遍。
## 为什么要构造完整基向量（而不是只设 rotation.y）：着色器把柱轴写死成本地 +Y，所以必须让
##   **本地 +Y 正好等于瞄准方向**；只转 yaw 只能得到水平柱，且无法保证与瞄准严格重合。
## 坐标系不变量：X = right、Y = d（瞄准方向）、Z = fwd，三者正交且都是单位向量（Basis 的三个参数
##   是**列向量**）。所以本节点**没有缩放/斜切**，粒子不会被压扁；写错顺序/漏 normalized 会让柱体变形。
## 注意：这里写 global_transform 而不是 transform/position —— 本节点挂在玩家的**父节点**下，
##   父节点可能带旋转（比如整个关卡/相机根），用 global 才不受影响。
func _place() -> void:
	var d := aim_dir()
	var ref := Vector3.UP
	# ★ 防退化：若 d 与参考向量平行，叉乘会得到零向量，再 normalized() 仍是零向量，
	#   于是 Basis 不可逆（粒子被压成一条线/彻底错位）。
	#   实际上 spell_aim.aim_dir() 保证 y 分量恒为 0，所以 d·UP 恒为 0、这个分支正常**永不触发**——
	#   它是防御性代码：万一上游把方向改成带竖直分量（比如以后做"朝天喷"），这里才不会崩掉（推测）。
	if absf(d.dot(Vector3.UP)) >= 0.99:
		ref = Vector3.FORWARD
	# right = UP × d：与 d 正交的水平向量（用于构成基的第一个轴）。
	var right := ref.cross(d).normalized()
	var fwd := right.cross(d).normalized()          # Z = X × Y，保持右手系
	# Y 轴放 d（不是 Z）：着色器的柱轴是本地 +Y，对准它火柱才是"朝着瞄准方向横着射出去"。
	global_transform = Transform3D(Basis(right, d, fwd), origin_global())
	# ★ 必须放在 global_transform 之后：cam_local_pos 是 to_local(相机位置)，依赖刚写好的基；
	#   顺序反了的话 billboard 会用上一帧的基，快速转身时柱体朝向会抖一帧。
	_update_cam_uniform()


## 着色器要自己算 billboard，所以得让它知道相机在**节点本地空间**里的位置
##
## 参数：无（相机从 get_viewport().get_camera_3d() 现取，不缓存 —— 支持观战/切换相机）。
## 返回值：无。
## 副作用：对 _materials 里每个 ShaderMaterial 调 set_shader_parameter("cam_local_pos", p)，
##   会顺带让 4 层材质各自重新绑定 uniform。
## 单位：节点本地空间的**米**（Vector3）；本地 +Y 是柱轴、+X 是 right、+Z 是 fwd，见 _place()。
## 早退（什么都不做，也不报错）：材质列表为空 / 本节点不在场景树里 / 场景里没有 Camera3D。
## 调用时机：只被 _place() 调用 —— 也就是施法期间每帧。**停喷后不再更新**（见 stop_cast）。
## 为什么要传本地坐标而不是世界坐标：着色器里的 pos 是本地坐标，两个空间必须一致才能算视线；
##   用 to_local() 正好走的是本帧刚设好的 global_transform 的逆变换。
## 注意：别在这里 get_camera_3d() 之后又缓存到一个成员变量里长期使用 ——
##   相机可能在运行时被换掉（本作有相机 rig），每帧现取是刻意的（推测：与 flame_visual 的做法一致）。
func _update_cam_uniform() -> void:
	# 不在场景树里时 get_viewport() 可能拿不到有效视口；材质为空时写了也没意义。
	if _materials.is_empty() or not is_inside_tree():
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := to_local(cam.global_position)
	for m in _materials:
		m.set_shader_parameter("cam_local_pos", p)


## 统一开关所有层的粒子发射（start_cast / stop_cast / _process 都用它，避免漏掉某一层）。
##
## 参数：on —— true = 开始发射；false = 停止发射（**不会**立刻清掉已在空中的粒子，
##   它们会按自己的 lifetime 自然消失，这正是"停喷后火舌还在飘"的观感来源）。
## 返回值：无。副作用：写各 GPUParticles3D 的 emitting。
## 调用时机：start_cast() / stop_cast() / _process() 扣蓝成功与否时，可能一帧内被调多次
##   （spell_caster 每帧都调 start_cast，本脚本每帧也可能调一次），所以必须幂等。
## 注意：只在值真的变化时才写 —— 重复赋同一个值虽不会重启发射，但会白走一次属性写入
##   和粒子系统的重算（推测：这是从火焰喷射实现沿用的写法）。
func _set_emitting(on: bool) -> void:
	for p in _emitters:
		if p.emitting != on:
			p.emitting = on


## 从给定的根节点开始，把场景里**所有** GPUParticles3D 收进 _emitters，
## 其中 process_material 是 ShaderMaterial 的再收一份引用进 _materials。
##
## 参数：root —— 遍历起点（唯一调用点是 _ready，传的是 .tscn 实例化的 _tornado 根节点）。
## 返回值：无。
## 副作用：**追加**（不是覆盖）_emitters / _materials；本文件只在 _ready 里调一次，
##   所以不存在重复；如果以后有人重复调用同一棵树，列表里会出现重复项 → 同一个粒子会被写两次
##   （功能上无害，但别依赖列表长度）。
## 为什么用显式栈做迭代遍历而不是递归：深度优先的逻辑一样，但迭代写法不消耗调用栈，
##   资源层级再深也不会爆栈，而且与 flame_jet_particles.gd 的收集实现保持同构（推测）。
## 遍历顺序：pop_back() 从尾部取 + 依次 push 子节点 → 得到"逆序深度优先"，顺序对功能没有影响，
##   **不要**依赖列表顺序（比如别写 _emitters[0] 当"外层"用）。
## 注意：判类型用的是 `is`，所以任何脚本挂的 GPUParticles3D 子类也会被收进来；
##   只认 process_material 是 ShaderMaterial 的层（material_override 是 StandardMaterial3D，不参与）。
func _collect(root: Node) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is GPUParticles3D:
			var p := n as GPUParticles3D
			_emitters.append(p)
			# 只有 process_material 才是那个认 cam_local_pos 的粒子着色器材质；
			# 逐一判类型是因为某一层可能被换成普通 ParticleProcessMaterial（那样就没有 cam_local_pos 可写）。
			var m := p.process_material
			if m is ShaderMaterial:
				_materials.append(m as ShaderMaterial)
		for c in n.get_children():
			stack.append(c)

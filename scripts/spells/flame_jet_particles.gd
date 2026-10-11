extends Node3D
## 火焰喷射 —— **粒子实现**：视觉直接实例化 scenes/fire_jet.tscn（GPUParticles3D）。
##
## 与着色器版（flame_visual.gd）的差别只在"怎么画"；施法、耗蓝、**瞄准方向**、**喷射起点**
## 全部共用 spell_aim.gd —— 两个实现的弹道行为因此永远一致（不想再出现"同一段代码抄两份、
## 只修一处"的事故）。
##
## 对外接口（与 flame_visual.gd 一模一样）：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()
##
## 两个实现要点：
##   1) 喷射方向每帧写进 ParticleProcessMaterial.direction，**本节点不旋转**。
##      同时把全局基向量强制成世界对齐，避免父节点带旋转时把写进去的世界方向带歪。
##   2) fire_jet.tscn 里的 spark 带了一个约 1.1 米的摆位偏移（当初在别的场景里对位用的），
##      这里把 emitter 的局部位置归零，让喷口严格等于 origin_global()。
##      —— 故意不修改那个场景文件：它是未提交的新资产，且可能正开在编辑器里。

## ---------------------------------------------------------------------------
## 所属系统：法术系统（scripts/spells/），由自动加载 SpellCaster 驱动。
##   spell_caster.gd 的 SPELLS["flame_jet"] 指向本脚本；把那一行改成 flame_visual.gd
##   就能切回着色器版火焰喷射 —— 两者对外接口完全相同，其它代码不需要动。
##
## 生命周期（本脚本不认识输入系统，全部由 SpellCaster 调用）：
##   选中术法 -> SpellCaster 实例化本脚本 -> _ready() -> setup(player, staff)
##   -> 按住左键期间每帧 start_cast() -> 松开 / 被 UI 挡住 / 未选中 -> stop_cast()
##
## 关键依赖：
##   Mana（autoload）       扣蓝；本脚本只调 Mana.spend_rate(delta, mana_per_sec)
##   scenes/fire_jet.tscn   视觉资产：根 Node3D + 3 个 GPUParticles3D（spark / spark2 / spark3）
##   spell_aim.gd           瞄准方向 + 喷射起点，与 flame_visual.gd 共用同一份实现
##   staff_tip.gd           仅当 spell_aim.origin_at_staff = true 时才被间接用到
##   player.gd              间接：spell_aim 会读 player.velocity 与 get_facing_yaw()
##
## 已知的坑（改之前先看）：
##   1) speed_scale_mul 只在 _ready 里乘进每个 emitter 一次：运行中改它不会重算，
##      要重新实例化节点（换一次术法即可）才有新速度。
##      mana_per_sec 没有这个限制 —— _process 每帧都从属性读它，改了立刻生效。
##   2) _ran_out 只在 casting == true 的 _process 里刷新；没在施法时它保持上一次的值，
##      所以"没在喷火" ≠ ran_out_of_mana() == false。
##   3) 本节点**不旋转**：方向靠每帧写 ParticleProcessMaterial.direction 表达，
##      因此 _place() 把全局基强制成单位阵（详见 _place 的注释），别在这里加 rotation。
##   4) fire_jet.tscn 里 3 个 emitter 的局部位置被强制归零 -> 三者会**重叠在同一点**，
##      资产中 x ≈ -0.25 / 1.46 / 3.26、y ≈ +1.096 的摆位铺开被抹掉了
##      （推测：这里只想要"一束火"，不要资产里那种横向排开）。
## ---------------------------------------------------------------------------

# ==================== 常量与依赖 ====================
## 火焰喷射的视觉资产：scenes/fire_jet.tscn（根 Node3D，子层 vfx_spark_fire_jet 下挂 3 个
## GPUParticles3D：spark / spark2 / spark3，各 200 个粒子、lifetime 0.22 s、fixed_fps 60）。
## 用 preload 而不用 load：路径写死，编译期就绑定好，免得运行到施法那一刻才发现路径写错。
## 换资产 = 换这一行；换成非粒子资产会让 _ready 告警并静默失效。
const JET_SCENE: PackedScene = preload("res://scenes/fire_jet.tscn")
## 瞄准方向 + 喷射起点：与着色器版共用同一份实现。
## 这里只 preload 脚本本身；实例是下面的 _aim（RefCounted，不挂场景树）。
## 默认 origin_at_staff = false -> 从"角色身前"喷（高度 1.05 m、正前方 0.6 m），不是从杖顶。
## 想改成"从法杖顶端喷"，改 spell_aim.gd 里的 origin_at_staff（两个实现同时生效）。
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

# ==================== 导出参数 ====================
## 每秒耗蓝（单位：魔法点/秒）。默认 22.0 与 mana.gd 的 spend_per_sec 默认值一致
## （同一档手感：满蓝 100 大约能连续喷 4.5 秒）。
## 调大 -> 更快耗空、被迫停火；调小 -> 一次按住能喷更久。
## 注意：这个值会被显式传给 Mana.spend_rate()，所以改 mana.gd 里的 spend_per_sec
##       不会影响火焰喷射（那个值只在别处不传参时当兜底）。
@export var mana_per_sec := 22.0        ## 每秒耗蓝（显式传给 Mana.spend_rate，不用 mana.gd 的默认值）
## 粒子速度倍率：在 _ready 里乘到每个 emitter 自身的 speed_scale 上。
## 1.0 = 沿用 fire_jet.tscn 自己的 speed_scale（该资产没写这个属性 -> 引擎默认 1.0）。
## 调大 -> 火柱飞得更快更远（穿透感更强，但粒子更快飞出视野、命中感反而变虚）；
## 调小 -> 火团更"贴脸"、更短促。
## 注意：只在 _ready 乘一次，运行中修改这个值不生效（见文件头"已知的坑"第 1 条）。
@export var speed_scale_mul := 1.0      ## 相对 fire_jet.tscn 自身 speed_scale 的倍率（1.0 = 沿用资产里的值）

# ==================== 内部状态 ====================
## 是否处于"施法"状态（唯一写入点：start_cast / stop_cast）。
## is_casting() 直接返回它；SpellCaster._sweep_instances() 也靠 is_casting() 判断
## 一次性法术的独立实例是否还在"演"。
## ★ 与蓝量无关：蓝耗尽时它仍是 true，只是 emitter 被关掉（见 _process）——
##   这样玩家手上的施法姿势不会在回蓝阈值附近来回抖。
var casting := false

## 瞄准 / 起点实现（RefCounted，不挂场景树）。setup() 时把 player / staff / self 交给它；
## 本节点只是它的宿主（_host），供它取 viewport / 相机来兜底判方向。
var _aim := SpellAim.new()
## 实例化出来的 fire_jet.tscn 根节点（add_child 到本节点下）。
## 可能为 null：资产根节点不是 Node3D 时 _ready 直接 return，之后所有逻辑空转。
var _jet: Node3D = null
## 从 _jet 子树里收集到的全部 GPUParticles3D（当前资产是 3 个）。
## 为空 = 资产里没有粒子节点 -> _process 每帧直接 return（不报错、不喷火）。
var _emitters: Array[GPUParticles3D] = []
## 最近一次施法帧"想喷但蓝不够"的结果。只在 casting == true 的 _process 里刷新，
## 由 ran_out_of_mana() 对外只读。
var _ran_out := false


# ==================== 初始化 ====================
## 节点首次进入场景树时初始化：实例化 fire_jet.tscn、递归收集 emitter，并把它们的初始
## 状态统一归到"未施法"（不发射 / 世界空间 / 位置归零 / 速度乘倍率）。
##
## 时机：SpellCaster 里 script.new() + add_child 之后由引擎自动调用；只在首次入树时一次，
##       换术法时旧节点被 queue_free、新节点重新走一遍这里。
## 副作用：改场景树（把资产根节点挂到本节点下）、写 emitter 的多个属性；不扣蓝、不发信号。
## 失败处理：资产路径失效 / 根节点不是 Node3D / 资产里没有 GPUParticles3D 时，
##       只 push_warning 并 return —— 节点本身仍留在树上，只是永远不喷火。
##       故意不 assert、不崩：一个坏资产不该把整个施法系统拖垮。
## 返回值：无。
## 注意：_emitters 为空是所有后续逻辑的"静默失效"开关（_process 会直接 return）。
func _ready() -> void:
	# 显式开每帧处理：Node 定义了 _process 时本来就默认开启，这行是冗余保险 ——
	# 表明"本脚本必须每帧跑"的意图（推测：防止将来有人把 process 回调关掉）。
	set_process(true)
	# 用 as 而不是强转：资产根节点若被换成非 Node3D，这里得到 null 走下面的告警分支，
	# 而不是在 instantiate 当场抛错（坏资产不炸整个施法系统）。
	_jet = JET_SCENE.instantiate() as Node3D
	if _jet == null:
		push_warning("[FlameJet] 场景根节点不是 Node3D: " + JET_SCENE.resource_path)
		return
	# 固定名字：远程调试 / 远程场景树里一眼能认出是哪个法术的视觉。
	_jet.name = "FireJet"
	# 把资产根节点挂到本节点下（本节点由 SpellCaster 挂在玩家的父节点下）；
	# 它的 global_transform 随后由 _place() 每帧覆盖。
	add_child(_jet)
	# 递归全收，而不是按 "vfx_spark_fire_jet/spark" 这类写死路径取：
	# 资产内部再加一层节点 / 改名都不会漏掉 emitter。
	_collect_emitters(_jet)
	if _emitters.is_empty():
		push_warning("[FlameJet] " + JET_SCENE.resource_path + " 里没找到 GPUParticles3D")
		return
	# 统一归零到"未施法"状态：下面几条都是对资产默认值的显式覆盖（不依赖资产怎么存）。
	for p in _emitters:
		# GPUParticles3D.emitting 默认是 true：不显式关掉，节点一入树就会自己喷起来
		# （玩家还没按左键就看见火）。
		p.emitting = false            # 没施法时不喷
		# 资产里写的是 local_coords = true（粒子跟着发射器走）；这里改成世界空间：
		# 已喷出的火留在原地，角色转身 / 移动时自然形成拖尾。
		p.local_coords = false        # 世界空间：喷出去的火留在原地，转身时自然拖尾
		# 抹掉资产里烘焙的摆位偏移（spark 的 y ≈ +1.096、x ≈ -0.25 / 1.46 / 3.26，当初在
		# 别的场景里对位用的）。归零后喷口严格等于本节点原点 = origin_global()；
		# 副作用是 3 个 emitter 会重叠在同一点（见文件头"已知的坑"第 4 条）。
		# —— 故意不改那个场景文件：它是未提交的新资产，且可能正开在编辑器里。
		p.position = Vector3.ZERO     # 抹掉场景里烘焙的摆位偏移，喷口 = 本节点原点
		# 用 *= 而不是 =：保留资产里可能存在的 speed_scale（本资产没写，实际是 1.0），
		# 只在其基础上乘这个倍率。注意只在 _ready 乘一次，运行中改导出值不会重算。
		p.speed_scale *= speed_scale_mul


## 初始化入口：把玩家、手里的法杖、本节点（作为宿主）交给 spell_aim。
## 参数：
##   player —— 玩家根节点（Node3D）。用于取 velocity / get_facing_yaw() 定朝向，以及
##             origin_at_staff = false 时算"身前"起点。允许为 null（找不到玩家时）。
##   staff  —— 手里的法杖节点（挂 held_staff.gd 的那个）。仅当 spell_aim.origin_at_staff
##             = true 时才会被用到（走 staff_tip.gd 数据驱动算杖头）。允许为 null。
## 返回值：无。
## 副作用：只写 _aim 的内部字段（player / staff / _host）——不改场景树、不发信号、不扣蓝。
## 调用时机：SpellCaster 里 add_child 之后立刻调用（因此在 _ready 之后），换一次术法调一次。
## 注意：参数允许 null —— spell_aim 内部有 _valid() 校验，null 只是让该来源失效、退化到下一档。
func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
# ==================== 对外接口（SpellCaster 调用） ====================
## 开始施法。SpellCaster 在"按住左键 + 没被 UI 挡住 + 选中了本术法"时**每帧**调用，
## 所以这里必须幂等。
## 参数：无。返回值：无。
## 副作用：casting = true；先把节点摆到 origin_global()，再打开 emitter 发射。
## 调用时机：按住施法的每一帧（不是只在"按下"那一瞬）。
## 注意：_place() 必须排在 _set_emitting(true) 之前 —— emitting 一打开就会在本帧发射粒子，
##       若那时节点还停在上次的位置，会看到"第一撮火从上一次的位置 / 世界原点冒出"。
## 另外：本函数不检查蓝量 —— 蓝不够的情况交给随后的 _process 统一处理（关 emitter + 记 _ran_out）。
func start_cast() -> void:
	casting = true
	_place()            # 先摆好位置再开喷，避免第一帧从世界原点喷出一小撮
	_set_emitting(true)


## 结束施法。松开左键 / 被 UI 挡住 / 切换或清空术法时调用。
## 参数：无。返回值：无。
## 副作用：casting = false；关闭 emitter 的**新粒子发射**。
## 注意：已经在飞的粒子不会被清除 —— 资产用世界空间（local_coords = false），
##       这些火头留在原地按自身 lifetime（0.22 s）烧完，看起来才像"松手后火焰脱手拖尾"。
func stop_cast() -> void:
	casting = false
	_set_emitting(false)


## 是否正在施法（casting 的只读访问器）。
## 参数：无。返回值：true = 施法中。
## 调用方：SpellCaster._sweep_instances() 用它判断一次性法术的独立实例是否演完、可释放。
## 注意：它不代表此刻真的有火 —— 蓝耗尽时仍是 true（_process 只关 emitter，不动 casting）。
func is_casting() -> bool:
	return casting


## 最近一次施法帧是否"想喷但蓝不够"。
## 参数：无。返回值：true = 最近一次施法帧 Mana.spend_rate() 失败（蓝被扣到 0、emitter 已关）；
##              false = 那一次扣蓝成功，或退出施法后一直没再刷新。
## 副作用：无（纯读 _ran_out）。
## 注意：_ran_out 只在 casting == true 的 _process 里刷新，stop_cast 之后它是"陈旧值"，
##       别用"现在没喷火"去推断它。当前 spell_caster.gd 并不读这个接口（验证脚本会读）。
func ran_out_of_mana() -> bool:
	return _ran_out


## 喷射方向（水平、世界空间）—— 实现在 spell_aim.gd，与着色器版共用
## 参数：无。返回值：**单位向量**，y 恒为 0（水平）；所有来源都失效时返回上一次的方向。
## 来源优先级（见 spell_aim.aim_dir）：1) 移动方向的水平分量 2) 角色面朝 yaw -> (sin yaw, 0, cos yaw)
##   3) 相机水平前向 4) 保持上一次，避免站着不动时朝向乱跳。
## 副作用：会刷新 spell_aim 内部的 _last_dir（即"写状态"），所以每帧调用是正常用法。
## 注意：模型 +Z 是脸的方向（player.gd 用 atan2(face.x, face.z) 设 rotation.y），
##       别套相机自己的 (-sin, 0, -cos) 约定 —— 那套在角色 yaw 上正好差 180°。
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 喷射起点（世界坐标）—— 实现在 spell_aim.gd，与着色器版共用
## 参数：无。返回值：世界坐标 Vector3（只表示"在哪"，不带方向含义）。
## 取值：origin_at_staff = false（默认）-> 玩家位置 + (0, 1.05, 0) + aim_dir() * 0.6，
##   即"角色身前 0.6 m、离地 1.05 m"处；origin_at_staff = true 且拿得到杖头 -> 法杖顶端。
## 全部来源失效时退到宿主（本节点）位置；宿主本身无效（null / 已释放）时返回 Vector3.ZERO。
## 副作用：内部会调用 aim_dir()，因此顺带刷新 spell_aim 的 _last_dir；本身不改场景树。
func origin_global() -> Vector3:
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
# ==================== 每帧逻辑 ====================
## 每帧：写发射方向（把世界方向直写进 ParticleProcessMaterial.direction），并在施法时把
## 喷口摆到 origin_global()、按蓝量开关 emitter。
## 参数 delta：距上一帧的秒数（秒）。只用于 Mana.spend_rate 的"每秒耗蓝 × delta"。
## 返回值：无。
## 副作用：写 emitter 的 process_material.direction；施法时改本节点 global_transform；
##         扣 Mana（Mana.changed / emptied 等信号由 mana.gd 自己发）；刷新 _ran_out。
## 调用时机：节点在树上且 process 开启时每帧（包括未施法期间）。
## 注意：
##   · 方向**每帧都写，即使没在施法** —— 这样"人刚转身就按下"的那一帧方向才是新的；
##   · 未施法时不走摆位：本节点停在上次施法的位置（不影响已喷出的火，它们是世界空间）；
##   · 扣蓝在摆位之后：位置每帧对齐，蓝量只决定"这帧要不要发射粒子"。
func _process(delta: float) -> void:
	# 没有 emitter（资产缺粒子节点 / _ready 提前 return）时整帧空转：
	# 这是在"资产坏了"的情况下保护每帧逻辑不报错的一道闸。
	if _emitters.is_empty():
		return

	var d := aim_dir()
	# 方向直接写世界方向（节点不旋转），每帧更新 -> 人转身，新喷出的火立刻跟着转
	for p in _emitters:
		# 资产不保证一定用 ParticleProcessMaterial（也可能是 ShaderMaterial）：
		# 取出来先判类型，不是就当这个 emitter 没有方向可写，跳过而不是强转报错。
		var pm := p.process_material
		if pm is ParticleProcessMaterial:
			(pm as ParticleProcessMaterial).direction = d

	if not casting:
		return

	# 每帧重申位置：origin_global() 会随角色移动 / 转身变化（默认从身前喷，火口跟着人走）。
	_place()

	# 扣蓝与开关：spend_rate 返回 false = 这帧蓝不够（mana.gd 里会把 current 归零并 emit emptied）。
	# 卡帧时 delta 变大 -> 一次扣更多，这是"按秒耗蓝"的预期行为，不用特判。
	if Mana.spend_rate(delta, mana_per_sec):
		# 每帧重新赋值（而不是"只在变化时"）：回蓝后下一帧就能立刻清掉标记。
		_ran_out = false
		_set_emitting(true)
	else:
		# 蓝不够：记下状态并关掉发射 —— 已在飞的粒子继续按 lifetime 烧完（世界空间，不受开关影响）。
		_ran_out = true
		_set_emitting(false)


# ---------------------------------------------------------------- 内部
# ==================== 内部实现 ====================
## 为什么必须用**单位基向量**：ParticleProcessMaterial.direction 写在 emitter 的局部坐标里
## （引擎发射时会乘上 emitter 的全局基），而本脚本写进去的是**世界方向** —— 只有让本节点的
## 全局基 = 单位阵，写进去的方向才等于实际方向；否则父节点（带旋转）会把方向带歪。
## 顺带把缩放归一，避免父节点的缩放把粒子尺寸 / 速度一起放大。
## 参数：无。返回值：无。副作用：改本节点 global_transform。
## 调用时机：start_cast() 里一次 + 施法中每帧一次（见 _process）。
## 把喷口摆到 origin_global()；基向量强制世界对齐，父节点带旋转/缩放也不会跑偏
func _place() -> void:
	# Basis.IDENTITY = 无旋转、无缩放（见上面的理由）；位置取自 spell_aim 的世界坐标。
	# 本节点的"指向"不靠旋转表达 —— 方向是每帧写给粒子的（见文件头"已知的坑"第 3 条）。
	# 用 Transform3D 一次写完整变换，不拆成 global_position + rotation 两步，免得中途被子节点读到半成品。
	global_transform = Transform3D(Basis.IDENTITY, origin_global())


## 统一切换所有 emitter 的"新粒子发射"开关。
## 参数 on：true = 开始发射；false = 停止发射（已在飞的粒子不受影响，继续按 lifetime 烧完）。
## 返回值：无。副作用：写 emitter.emitting。
## 调用方：start_cast / stop_cast / _process（蓝量不足时）。
## 实现细节：只在值真的变化时才写 —— 避免每帧重复设置同一属性；
##   （推测）也避免某些版本里重复赋 false 打断正在收尾的粒子。
func _set_emitting(on: bool) -> void:
	for p in _emitters:
		# 值没变就别碰属性：这个函数在第一次开喷 / 停火时会被反复调用（施法中每帧都会走这里）。
		if p.emitting != on:
			p.emitting = on


## 递归收集 root 子树里**所有** GPUParticles3D，按遍历顺序追加到 _emitters。
## 参数 root：起点节点（_ready 里传实例化出来的 _jet）。
## 返回值：无。副作用：_emitters.append(...) —— **只追加、不清空**，所以别重复调用
##   （目前只在 _ready 里调一次）。
## 为什么用显式栈而不是函数递归：GDScript 有最大调用深度限制，资产嵌套深了会栈溢出；
##   用数组当栈只是把递归摊平，语义等价。
## 注意：pop_back 取节点 + 顺序 append 子节点 => 是深度优先，但**兄弟顺序是反的**。
##   对"把粒子节点全收一遍"没有影响（收集顺序不影响开关语义）。
func _collect_emitters(root: Node) -> void:
	# 显式栈代替递归：避开 GDScript 的调用深度上限；pop_back 保证深度优先。
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		# 只认粒子节点本身；容器层（如资产的 vfx_spark_fire_jet）不需要记录。
		if n is GPUParticles3D:
			# 存进类型化数组 Array[GPUParticles3D]，所以要 as 成具体类型（Node 塞不进去）。
			_emitters.append(n as GPUParticles3D)
		# 无条件把所有子节点入栈：emitter 可能藏在任意层，不做剪枝。
		for c in n.get_children():
			stack.append(c)

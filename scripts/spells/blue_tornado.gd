extends Node3D
## 蓝色龙卷风 —— 把 scenes/法术特效/蓝色龙卷风.tscn 接进法术体系。
##
## 与另外两个法术的**实现方式不同**，这点很关键：
##   · 火焰喷射 / 火焰编织 = GPUParticles3D，靠 `emitting` 开关；
##   · 蓝色龙卷风        = **静态网格 + VisualShader**，动画由着色器里的 TIME 驱动，
##                        所以"施法/停法"就是显隐节点，没有 emitting 可切。
##
## 摆放参考上游原始工程（spells-design/scenes/map.tscn）：
##   那边是**竖直、贴地、缩放 0.7**（演示场景，网格 12 单位高）。
##   本作角色约 1.08m，所以默认缩到 0.3（≈3.6m 高），在角色正前方地面升起。
##
## 对外接口与另外两个法术完全一致：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()

# ==================== 文件补充说明：依赖清单与不变量 ====================
# 所属系统：法术系统（scripts/spells/ 下的"施法体"之一，由 spell_caster.gd 装载与驱动）。
# 依赖清单（改代码前请确认这些依赖仍存在）：
#   · 场景资源：res://scenes/法术特效/蓝色龙卷风.tscn —— 根节点必须是 Node3D；
#     其动画由 VisualShader 内的 TIME 驱动（推测），因此本脚本不向它喂任何时间参数。
#   · 脚本：scripts/spells/spell_aim.gd（方向 / 起点计算，三个法术共用同一份实现）；
#     scripts/spells/spell_sheet.gd（数值表读取）。
#   · 数据文件：data/spell_sheet.json —— 行键名由下面的 SHEET_ID 指定。
#   · autoload：Mana —— 需要 get("current") / try_spend() / spend_rate() 三个接口。
#   · 全局着色器参数：tornado_pos / tornado_radius / tornado_strength / tornado_swirl，
#     植被 shader 侧用 `global uniform` 声明后读取（详见 _publish_wind 的注释）。
#   · 敌人节点：必须加入组 "enemies" 且实现 take_damage(int) 方法（沿用 flame_scorch 的约定）。
#
# 已知的坑与不变量：
#   1) 本文件不做瞄准输入：圈选确认后 caster 只调 cast_at()，施法必须由 cast_at() 自己发起。
#   2) one_shot = true（默认，前摇为 0）时 caster 会在同一帧就调 stop_cast()，故 stop_cast() 必须忽略它。
#   3) 风场是**全局**状态：任何结束路径都要走 _clear_wind()，否则植被会永久残留风。
#   4) 龙卷风基向量始终保持世界对齐 → 永远竖直，不随瞄准俯仰倾斜。
# ==================== 常量与导出配置 ====================
## 龙卷风特效场景（本文件唯一的硬编码资源路径）。
## 默认值说明：换特效只需改这一处；新场景的根节点仍须是 Node3D，
## 否则 _ready() 会走 push_warning 分支并保持 _tornado == null（法术整体静默失效）。
const TORNADO_SCENE: PackedScene = preload("res://scenes/法术特效/蓝色龙卷风.tscn")
## 方向 + 起始位置：与另外两个法术共用同一份实现
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

@export var mana_per_sec := 0.0        ## 每秒耗蓝（本次改为**一次性** ✓ 故默认 0 ✓）
## ★★ 数值表接入（用户需求 ✓）：下面这些默认值会被 data/spell_sheet.json 覆盖 ✓
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
## 数值表行键名：在 data/spell_sheet.json 里查找名为 "blue_tornado" 的那一行（具体层级结构推测）。
## 改这个字符串时数据表里必须有同名行，否则 setup() / has_targeting() / targeting_config() 会全部退化为默认值。
const SHEET_ID := "blue_tornado"
@export var one_shot := true           ## 一次性施放 ✓
@export var mana_cost := 20.0          ## 单次耗蓝 20 ✓
@export var duration := 8.0            ## 持续时间 8s ✓
@export var fade_time_sheet := 0.8     ## 收尾淡出 ✓
@export var total_time := 8.0          ## 整体时长 ✓
@export var damage_per_sec := 20.0     ## 圈内每秒扣血 20 ✓
## ★★★ 进阶：局部风场（用户需求 ✓ 龙卷风影响周围植被的风速与风向）
@export var wind_radius_mul := 1.8     ## 风场半径 = 圈半径 × 这个系数 ✓（想影响更远 → 调大 ✓）
@export var wind_strength_add := 0.6   ## 局部风速的增量 ✓（越大越剧烈 ✓）
@export var swirl_ccw := false         ## 环流方向：**false = 顺时针** ✓（与龙卷风模型一致 ✓ 用户要求）
# ==================== 运行期状态（圈选 / 计时 / 伤害累积 / 施法句柄） ====================
## ★ 圈选选择器状态（由 spell_targeting 通过 cast_at() 写入 ✓）
## 圈选圆心（世界坐标）：由 cast_at() 写入。保持 Vector3.ZERO 表示"用户从未圈选过"，
##   _place() 会据此回退到"角色正前方 spawn_distance 米"；因此圆心正好落在世界原点时会被误判为未选（推测，属已知取舍）。
var _center := Vector3.ZERO
## 圈选半径（米，水平距离）：cast_at() 里被下限 clamp 到 0.5；它同时决定伤害判定范围
##   与龙卷风的缩放倍率（_place 中 mul = _radius / 2.5，且再 clamp 到 0.5~3.0）。默认 2.5 = 缩放基准 1.0。
var _radius := 2.5
var _life_t := 0.0                     ## 本次已存活时间（到 total_time 自动结束 ✓）
var _dmg_acc: Dictionary = {}          ## 目标 id -> 累积小数伤害（保证 take_damage 收到整数 ✓）
@export var tornado_scale := 0.3      ## 网格原始 12 单位高 -> 0.3 ≈ 3.6m
@export var spawn_distance := 2.2     ## 落点：角色正前方多少米

## 是否处于"正在施法"：is_casting() 的唯一来源；为 false 时 _process 直接空转（不推进计时 / 伤害 / 风场）。
var casting := false

## spell_aim.gd 的实例：负责"角色前方方向"与"起点"的计算（三个法术各持一份，不共享实例）。
var _aim := SpellAim.new()
## 实例化出来的龙卷风特效节点，_ready() 里创建并挂到自身；null 表示场景根节点不是 Node3D，法术整体静默失效。
var _tornado: Node3D = null
## 蓝量耗尽标记：仅在 mana_per_sec > 0（持续耗蓝型）且 Mana.spend_rate() 返回 false 时置 true。
## 当前默认配置是一次性施法（mana_per_sec = 0），故恒为 false，仅为兼容旧配置保留。
var _ran_out := false


# ==================== 生命周期 ====================
## 节点进入场景树时初始化：开启每帧处理，并实例化龙卷风特效（初始隐藏后挂到自身）。
## 参数：无（引擎回调，不带参）。
## 返回：无。
## 副作用：add_child() 改变场景树；设置子节点的 name / scale / visible。
## 时机：spell_caster 装载本脚本生成节点后由引擎自动调用一次，早于 setup()。
## 注意：这里**不读数值表也不施法**，所以特效初始一定不可见；
##       若场景根节点不是 Node3D，只 push_warning 并 return，_tornado 保持 null，后续逻辑全部静默跳过。
func _ready() -> void:
	# 显式开启每帧处理：不依赖 .tscn 里的开关，保证节点被复用/暂停后 _process 依然生效（推测原意如此）
	set_process(true)
	# 用 as 做安全转换：根节点类型不符时得到 null，而不是让后续 add_child 直接报错中断
	_tornado = TORNADO_SCENE.instantiate() as Node3D
	if _tornado == null:
		push_warning("[BlueTornado] 场景根节点不是 Node3D: " + TORNADO_SCENE.resource_path)
		return
	_tornado.name = "BlueTornado"
	_tornado.scale = Vector3.ONE * tornado_scale
	_tornado.visible = false          # 没施法时不显示
	add_child(_tornado)


# ==================== 初始化：绑定角色 / 读取数值表 ====================
## 由 spell_caster 装载后调用一次：绑定施法者与法杖（转交 spell_aim），并用数值表覆盖导出默认值。
## 参数：
##   player — 施法角色节点（Node3D）；spell_aim 用它取世界变换与朝向，传 null 会让方向/起点计算失效。
##   staff  — 法杖节点（Node3D）；spell_aim 取它的握点。本法术 origin_global() 已关闭握点模式，故实际影响很小。
## 返回：无。
## 副作用：写入 one_shot / mana_cost / mana_per_sec / duration / fade_time_sheet / total_time / damage_per_sec，
##         并往控制台打印一行数值摘要（不发信号、不动场景树、不施法）。
## 时机：在 add_child() 之后、start_cast() / cast_at() 之前（spell_caster.gd:256-257 先挂节点再 call("setup")），
##       所以 _ready() 一定早于本函数；一次性法术每发都由 _spawn_cast_instance() 新建实例，故每次施法前都会重新读表。
## 注意：row 为空时只打印提示并沿用 .tscn 上的导出默认值，**不会提前 return**，所以后续施法照常可用。
func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)
	# ★★★ 读数值表（用户需求 ✓）：一次性 / 20 蓝 / 8 秒 / 圈内每秒 20 伤害
	#   圈选参数（targeting）由 spell_targeting 通过 targeting_config() 读取 ✓
	var row: Dictionary = SHEET.get_spell(SHEET_ID)
	if row.is_empty():
		print("[蓝色龙卷风] ✗ 数值表里没有 %s（用导出默认值）" % SHEET_ID)
	else:
		# 每个字段都带"表里没写就沿用当前值"的兜底：数值表可以只覆盖部分字段
		one_shot = bool(row.get("one_shot", one_shot))
		mana_cost = float(row.get("mana_cost", mana_cost))
		mana_per_sec = float(row.get("mana_per_sec", mana_per_sec))
		duration = float(row.get("duration", duration))
		fade_time_sheet = float(row.get("fade_time", fade_time_sheet))
		# total_time 缺省 = duration + fade_time：所以表里只给 duration 时，整体时长会自动把收尾淡出算进去
		total_time = float(row.get("total_time", duration + fade_time_sheet))
		var tg: Dictionary = row.get("targeting", {})
		damage_per_sec = float(tg.get("damage_per_sec", damage_per_sec))
		print("[蓝色龙卷风] 数值表 ✓ one_shot=%s ｜ 耗蓝=%.0f ｜ 持续=%.1fs ｜ 每秒伤害=%.0f ｜ 圈选=%s" % [
				str(one_shot), mana_cost, duration, damage_per_sec, str(tg.get("enabled", false))])


# ==================== 对外接口（契约与另外两个法术完全一致） ====================
# ---------------------------------------------------------------- 对外
## 开始施法：先校验并一次性扣除 mana_cost，再重置计时与伤害累积，最后摆位 + 显示龙卷风。
## 参数：无。返回：无（是否真的生效请用 is_casting() 查询）。
## 副作用：Mana.try_spend() 扣蓝；casting = true；_life_t / _dmg_acc 归零；写 global_transform；_tornado.visible = true。
## 时机：① 非圈选路径下由 caster 直接调用；② 圈选确认后由 cast_at() 调用（caster 不会再调，详见 cast_at 的注释）。
## 注意：蓝不足或扣蓝失败会**直接 return**，不留下"特效已显示但没扣蓝"的中间状态（先判后扣，保证原子性）。
##       一次性模式下 caster 可能同帧再调 stop_cast()，本函数不做特殊处理，由 stop_cast() 内部忽略。
func start_cast() -> void:
	# ★★★ 一次性施放（用户需求 ✓）：由自己计时结束 ✓（忽略 caster 的提前 stop ✗）
	#   前摇 0 → caster 会在同帧调 stop_cast() ✗ → 必须忽略 ✓（否则刚出现就消失 ✓）
	#   耗蓝 20 一次扣 ✓（先判余额 ✓ 照 flame_scorch 的写法 ✓）
	if mana_cost > 0.0:
		# 先只读地查余额、再调用扣蓝：这样"余额不足"和"扣蓝失败"都在改动自身状态之前退出
		var cur := float(Mana.get("current"))
		if cur < mana_cost:
			print("[蓝色龙卷风] ✗ 法力不足（需要 %.0f，当前 %.0f）→ 本次不生效" % [mana_cost, cur])
			return
		if not Mana.try_spend(mana_cost):
			print("[蓝色龙卷风] ✗ 扣蓝失败 → 本次不生效")
			return
	_life_t = 0.0
	_dmg_acc.clear()
	casting = true
	_place()                          # 先摆好位置再显示，避免第一帧闪在旧位置
	_set_visible(true)
	print("[蓝色龙卷风] 生效 ✓ 持续 %.1fs ｜ 圈内每秒 %.0f 伤害 ｜ 半径 %.2f ｜ 缩放 ×%.2f（%.1f m 高）" % [
			total_time, damage_per_sec, _radius, clampf(_radius / 2.5, 0.5, 3.0),
			tornado_scale * clampf(_radius / 2.5, 0.5, 3.0) * 12.0])


## 外部请求停止施法。调用方（见 spell_caster.gd）：
##   · 每帧分派：holder 未按住施法键时对共享实例 call("stop_cast")（:125-129）；
##   · 换法术 / 清空选中：select_spell 收尾（:297）与 stop_spell()（:430-433）。
## 参数：无。返回：无。
## 副作用：one_shot == false 时把 casting 置 false 并隐藏特效；one_shot == true 时**什么都不做**（空操作）。
## 时机：可能在任何帧被调用，包括 cast_at() → start_cast() 的同一帧。
## 注意：一次性模式下结束权完全归本脚本（_process 计时到点），外部 stop 被有意忽略，
##       所以调用 stop_cast() 之后 is_casting() 可能仍为 true —— 反直觉但必需，
##       否则前摇为 0 的法术会在出现的同一帧就被停掉、看都看不到。
func stop_cast() -> void:
	# 一次性：忽略 caster 的提前 stop ✗（前摇 0 时它会同帧调用 ✓）
	if one_shot:
		return
	casting = false
	_set_visible(false)


## 查询是否正在施法。
## 返回：casting 的当前值（true = 特效可见、每帧在结算计时/伤害/风场）。
## 副作用：无。时机：caster 每帧可用它决定是否维持施法姿态与动画。
## 注意：一次性模式下，即使外部已调 stop_cast()，本函数仍会返回 true，直到总时长耗尽。
func is_casting() -> bool:
	return casting


## 查询上一次施法是否因蓝量耗尽而中断（caster 用它决定是否播"没蓝"的反馈）。
## 返回：_ran_out。当前默认配置下恒为 false —— 只有把 mana_per_sec 调回 > 0（持续耗蓝型）才有意义。
## 副作用：无。注意：该标记只在 _process 的兼容分支里被赋值，start_cast() 不会重置它（推测无影响）。
func ran_out_of_mana() -> bool:
	return _ran_out


## 方向（水平、世界空间）—— 实现在 spell_aim.gd，与另外两个法术共用
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 起点（世界坐标）—— 竖直的龙卷风贴地升起，所以高度取 0
func origin_global() -> Vector3:
	# 每次调用都重设这三个开关：_aim 的参数是可变状态，而本法术要求恒定"贴地 + 角色正前方固定距离"
	_aim.origin_at_staff = false
	_aim.front_height = 0.0
	_aim.front_offset = spawn_distance
	return _aim.origin_global()


# ==================== 每帧驱动（摆位 / 计时 / 风场 / 伤害 / 结束判定） ====================
# ---------------------------------------------------------------- 每帧
## 每帧推进主循环：重新摆位 → 累加存活时间 → 广播风场 → 结算圈内伤害 → 判结束 →（兼容分支）持续耗蓝。
## 参数 delta：距上一帧的秒数（float，引擎保证 > 0）；既用于计时，也用于把"每秒伤害"折算成本帧伤害。
## 返回：无。
## 副作用：global_transform、_life_t、_dmg_acc、_ran_out、casting、_tornado.visible、
##         RenderingServer 的四个全局着色器参数、以及对敌人节点调用 take_damage(int)。
## 时机：每帧调用（_ready 已显式 set_process(true)）；但 _tornado == null 或未施法时立即 return。
## 注意：结束判定排在伤害结算**之后**，所以到点的最后一帧仍会结算一次伤害（推测为有意保留）；
##       结束时必须调 _clear_wind()，否则植被会永久以为旁边有龙卷风。
func _process(delta: float) -> void:
	# 未施法（或特效实例化失败）时立即返回：不推进计时、不写全局风场，避免污染植被 shader
	if _tornado == null or not casting:
		return

	# 每帧重新摆位：角色或圈心可能在两帧之间移动，且缩放要跟着圈半径实时变化
	_place()
	_life_t += delta
	# ★★★ 进阶（用户需求 ✓）：广播**局部风场**给植被 shader ✓
	#   机制同 camera_rig 的 occ_player_uv ✓：RenderingServer.global_shader_parameter_set ✓
	#   植被 shader 里 `global uniform vec3 tornado_pos;` 等声明后即可就地使用 ✓
	# 传入"剩余寿命比例"作衰减系数；maxf(..., 0.01) 是防除零（total_time 被配成 0 也不会崩）
	_publish_wind(clampf(1.0 - _life_t / maxf(total_time, 0.01), 0.0, 1.0))
	# ★★★ 圈内每秒扣血 20（用户需求 ✓）：持续阶段每帧调用 ✓（按 delta 累积成整数伤害 ✓）
	_apply_damage(delta)

	# ★★ 整体到点自动结束（一次性 ✓ 用户需求 8 秒）
	# 用 >= 而不是 ==：delta 逐帧累加几乎不会正好等于 total_time（浮点误差）
	if _life_t >= total_time:
		print("[蓝色龙卷风] 整体 %.1fs 到点 ✓ 结束" % total_time)
		casting = false
		_set_visible(false)
		_clear_wind()          # ★ 局部风场归零 ✓（否则植被会一直以为旁边有龙卷风 ✗）
		return

	# 兼容：表里 mana_per_sec 若改回 >0（持续耗蓝型）则保留原逻辑 ✓；现在为 0 不会扣 ✓
	# 为什么必须放在最后：这一段会按"是否扣得起蓝"直接改写 casting / 可见性（兜底关停），
	# 排在到点判定之后才不会把"正常结束"的那一帧再覆盖一次（推测原意如此）
	if mana_per_sec > 0.0:
		if Mana.spend_rate(delta, mana_per_sec):
			_ran_out = false
			_set_visible(true)
		else:
			_ran_out = true
			_set_visible(false)


# ==================== 圈选选点器契约（与火焰灼烧同一套） ====================
# ---------------------------------------------------------------- 圈选（同火焰灼烧 ✓）
## ★ span_targeting 契约：法术是否使用"圈选选点器"
func has_targeting() -> bool:
	var row: Dictionary = SHEET.get_spell(SHEET_ID)
	var tg: Dictionary = row.get("targeting", {})
	return bool(tg.get("enabled", false))


## 交给通用选点器的参数（与 flame_scorch 同一套 ✓）
func targeting_config() -> Dictionary:
	return SHEET.get_spell(SHEET_ID).get("targeting", {})


## 选点完成 → 记下圆心与半径 + ★**自己开始施法** ✓
## ★★★ 关键（对照火焰灼烧 ✓）：caster 在选点确认后**只调 `cast_at()`** ✗
##   （见 spell_caster.gd:399-408，它**不会**再调 start_cast() ✗）
##   → 所以"开始施法"必须由 cast_at() 自己完成 ✓
##   （火焰灼烧就是这么做 ✓：它的 cast_at 里记下圆心/半径后直接进入自己的状态机 ✓）
func cast_at(center: Vector3, radius: float) -> void:
	_center = center
	# 半径下限 0.5m：滚轮缩到极小时伤害圈会退化成点，且缩放系数 mul = _radius / 2.5 也会失真
	_radius = maxf(radius, 0.5)
	start_cast()          # ★ 真正开始（扣蓝 20 ✓ 摆到圈心 ✓ 开始计时 8 秒 ✓ 开打）


# ==================== 圈内伤害结算（照 flame_scorch ✓） ====================
# ---------------------------------------------------------------- 圈内伤害（照 flame_scorch ✓）
## 每秒扣血：只在**持续阶段**调用 ✓（余烬/淡出不扣 ✓）
func _apply_damage(delta: float) -> void:
	# 把"每秒伤害"折算成"本帧伤害"：否则帧率越高总伤害越高，伤害会随机器性能漂移
	var dmg := damage_per_sec * delta
	if dmg <= 0.0:
		return
	for t in _find_targets():
		var node := t as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var p := node.global_position
		var flat := Vector3(p.x - _center.x, 0.0, p.z - _center.z)
		if flat.length() > _radius:
			continue                                   # 不在圈内 ✓
		var id := node.get_instance_id()
		# 用实例 id 当键累积小数伤害：目标接口只吃整数，若直接 int() 截断会永远打不出伤害（高帧率下每帧伤害 < 1）
		var acc := float(_dmg_acc.get(id, 0.0)) + dmg
		var whole := int(floor(acc))
		if whole > 0:
			acc -= float(whole)
			node.call("take_damage", whole)            # 敌人在组 "enemies" ✓ 且有 take_damage ✓
		# 把不足 1 点的零头写回，下一帧继续累积（这样每秒总伤害才严格等于 damage_per_sec）
		_dmg_acc[id] = acc


## 找敌人：组 "enemies" 优先（与 flame_scorch 完全一致 ✓）
func _find_targets() -> Array:
	var tree := get_tree()
	if tree == null:
		return []
	return tree.get_nodes_in_group("enemies")


# ==================== 内部辅助（摆位 / 风场 / 显隐） ====================
# ---------------------------------------------------------------- 内部
## 起点摆到 origin_global()；基向量保持**世界对齐** -> 龙卷风永远竖直（不随瞄准倾斜）
func _place() -> void:
	# ★★ 圈选（用户需求 ✓）：选了圆心就落在圆心 ✓；没选过（_center 为 0）则退回"角色正前方"✓
	var pos := _center if _center != Vector3.ZERO else origin_global()
	pos.y = 0.0                       # 竖直贴地 ✓（与原来一致 ✓）
	# ★★★ 圆的大小**控制龙卷风缩放**（用户需求 ✓）：滚轮放大/缩小圆 → 龙卷风同步变大/变小 ✓
	#   基准 = 默认半径 2.5（对应 tornado_scale 0.3 ≈ 3.6m 高 ✓）
	#   范围夹在 0.5~3.0 倍 ✓（防止极端缩放出问题 ✓）
	var mul := clampf(_radius / 2.5, 0.5, 3.0)
	# 整体赋 global_transform 而不是只改 position：basis 用 IDENTITY 才能保证世界对齐竖直；
	# 若改成基于父节点/自身朝向的 basis，龙卷风会随角色转身或瞄准俯仰而倾斜（推测这正是必须整体赋值的原因）
	global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * mul), pos)


## ★★★ 广播局部风场（用户需求 ✓ 进阶：龙卷风影响周围植被的风速与风向）
##   用**全局着色器参数**（无需注册材质 ✓ 所有用到的 shader 都能读到 ✓）
##   植被 shader 侧需声明（见 tree_leaves_burn_ds / tree_burn_keep_ds / grass_wind*）：
##     global uniform vec3  tornado_pos;       // 龙卷风中心（世界坐标）
##     global uniform float tornado_radius;    // 影响半径（米）
##     global uniform float tornado_strength;  // 局部风速强度（0 = 无风 ✓ 结束时会归零 ✓）
##     global uniform float tornado_swirl;     // 环流方向：+1 逆时针 / -1 顺时针
func _publish_wind(decay: float) -> void:
	var r := RenderingServer
	# 影响半径 = 圆半径 × 系数（默认 1.8 ✓ 想影响更远就调大 wind_radius_mul ✓）
	var rad := _radius * wind_radius_mul
	# 强度 = 基础强度 × 衰减（越接近尾声越弱 ✓）× 圆越大越强（半径/2.5 ✓）
	var strg := wind_strength_add * decay * clampf(_radius / 2.5, 0.5, 3.0)
	r.global_shader_parameter_set("tornado_pos", global_position)
	r.global_shader_parameter_set("tornado_radius", rad)
	r.global_shader_parameter_set("tornado_strength", strg)
	r.global_shader_parameter_set("tornado_swirl", 1.0 if swirl_ccw else -1.0)


## 结束/销毁时**必须归零** ✓（否则植被会一直以为旁边有龙卷风 ✓）
func _clear_wind() -> void:
	var r := RenderingServer
	# 只归零"强度 / 半径"就等效于无风：位置与环流方向留着无害，可省下两次全局参数写入
	r.global_shader_parameter_set("tornado_strength", 0.0)
	r.global_shader_parameter_set("tornado_radius", 0.0)


## 运行期统一的显隐开关，供 start_cast / stop_cast / _process 调用
##   （_ready() 里初始化时另有一次对 _tornado.visible 的直接赋值，那是本函数生效前的一次性设置）。
## 参数 v：true = 显示龙卷风，false = 隐藏；它不做淡出，收尾淡出由特效/shader 自身负责（推测）。
## 返回：无。副作用：改子节点 visible；_tornado 为 null 时是安全空操作。
## 时机：施法开始 / 停止 / 每帧蓝量分支里都可能被调用，重复调用无副作用。
## 注意：内部用 "值有变化才写" 去重，避免每帧触发无谓的可见性变更通知。
func _set_visible(v: bool) -> void:
	# 只在可见性真正变化时赋值：可见性写入会触发引擎侧通知，去重可避免每帧抖动
	if _tornado != null and _tornado.visible != v:
		_tornado.visible = v

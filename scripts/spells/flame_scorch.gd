extends Node3D
## 火焰灼烧 —— **一次性范围法术**。
##
## 流程（数值全部来自 data/spell_sheet.json）：
##   ① 选点   由通用选点器 spell_targeting 负责（本术法只声明 has_targeting/cast_at）
##   ② 点燃   cast_climb = 0.35s   圈内各处火焰从 0.2 长到 1
##   ③ 灼烧   duration   = 8.0s    圈内敌人每秒扣 damage_per_sec(默认 10) 点血
##   ④ 余烬   fade_time  = 1.2s    火焰逐渐消失，**这一阶段不扣血**
##
## 「火焰逐渐消失」用的是 fire_burst 的 grow（每张焰卡**在原位**缩小变暗），
## 绝不缩放特效根节点 —— 焰卡围成一圈，缩放根节点会让它们向中心靠拢（用户明确否过）。
##
## 对外接口除标准那几个外，另加选点法术需要的两个：
##   has_targeting() -> bool  /  targeting_config() -> Dictionary  /  cast_at(center, radius)
##
## 敌人约定：节点在组 "enemies" 里，或自身有 take_damage(整数) 方法。
## 目前项目里没有敌人系统，所以扣血走的是**宽松探测**：两种约定都试，都没有就安静跳过。
##
## 【所属系统】法术系统（scripts/spells/）里的一次性范围术法。
##   · 注册处：scripts/spells/spell_caster.gd 的法术表（键 "flame_scorch"）
##   · 轮盘槽位：scripts/spells/spell_wheel.gd（第 4 格，"火焰灼烧"）
##   · 选点器：scripts/spells/spell_targeting.gd（本文件只声明 has_targeting / targeting_config / cast_at）
##   · 子类：scripts/spells/flame_advance.gd（extends 本文件，把"整圆"收紧成"扇形"并做火焰推进）
##
## 【关键依赖】
##   · autoload `Mana`（res://scripts/spells/mana.gd）：读 current、调 try_spend()。
##     本文件**直接按名引用**它，所以必须在自动加载注册完成之后再加载/实例化本脚本，
##     否则会报"未定义标识符 Mana"（tools/verify_flame_advance.gd 里有对应说明）。
##   · data/spell_sheet.json + scripts/spells/spell_sheet.gd（静态表；缺行/缺键时用 @export 兜底值）
##   · scenes/法术特效/火焰燃烧特效.tscn（单簇火焰；其脚本 fire_burst.gd 暴露 grow 属性）
##   · scripts/vfx/foliage_burn.gd（逐株植被的燃烧控制器）
##   · assets/shaders/fire_ground.gdshader + assets/textures/法术特效/龙卷风/T_FirePanningCyl45.png
##     （贴地燃烧光斑的材质与贴图）
##
## 【主要对外接口】（由 spell_caster 统一调用；缺任何一个都不会崩，但功能会退化）
##   setup(player, staff) / start_cast() / stop_cast() / is_casting() / ran_out_of_mana()
##   aim_dir() / origin_global() / wants_cast_anim()
##   has_targeting() / targeting_config() / cast_at(center, radius)
##
## 【子类扩展钩子】（基类均有默认实现，子类按需覆盖）
##   has_targeting() / targeting_config() / start_cast() / _process(delta)
##   _spawn_patches() / _apply_grow(s) / _node_touches_circle(n)
##   _ignite_vegetation() / _burn_instance_indices(mmi) / _burn_instance_delays(mmi)
##   （_ignite_one(t, i) 是基类与子类**共用**的，子类不覆盖它）
##
## 【已知的坑 / 注意事项】
##   1. 状态机门禁：_state 既不是 ST_OFF 也不是 ST_AFTER 时，cast_at() / start_cast() **静默返回**。
##      这是刻意的 —— spell_caster 造不出独立实例时会退回**共享实例**，此时第二发必须被忽略。
##   2. "火焰消失"永远走 fire_burst 的 grow（逐张焰卡**原位**缩小变暗），
##      **绝不缩放本节点**（用户明确否过：焰卡围成一圈，缩放根节点会让它们往中心靠拢）。
##   3. @export 变量**散布在文件中段**（burn_vegetation 在状态变量之后、debug_vegetation 在函数之间），
##      不是集中在文件头 —— 查数值时别只看开头。
##   4. 扣血走 take_damage(整数)：小数伤害在 _dmg_acc 里累积，攒够 1 点才发一次调用。
##   5. 文件里有若干"注释与紧邻声明错位"的历史遗留（例如 _scanned_instances 行尾的注释其实在
##      描述 _burns）。本次注释只**新增说明**，原有注释一律原样保留、没有搬动。
##
## 【相关文档】docs/火焰推进与火焰灼烧选点器-技术文档.md（射线掩码与选点分工）

# ==================== 常量与资源路径 ====================
## 单簇火焰的场景。实例化**不便宜**（多张焰卡 + 材质 + 灯光），所以只建一次进池复用。
## 其根脚本 fire_burst.gd 暴露 grow（1.0 = 正常燃烧，0 = 完全熄灭）。
const FIRE_SCENE: PackedScene = preload("res://scenes/法术特效/火焰燃烧特效.tscn")
## 数值表脚本。全部是 static 函数（has(id) / f(id, key, def) / get_spell(id)），无需实例化。
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
## 本术法在 data/spell_sheet.json 里的行键。子类 flame_advance 用的是**另一个键**（"flame_advance"），
## 两者不可混用（该文件头部有专门说明）。
const SHEET_ID := "flame_scorch"
## 贴地燃烧光斑用的 shader 路径；uniform 为 fade（0 = 不可见，1 = 全亮），由 _apply_grow 统一驱动。
## 用字符串路径 + load()（不是 preload），所以资源缺失时只是没有光斑，不会让脚本加载失败。
const GROUND_SHADER := "res://assets/shaders/fire_ground.gdshader"
## 光斑用的火焰纹理（黑底火舌图；加法/透明混合下黑底即透明）。同样是 load() 可缺省。
const FIRE_TEX := "res://assets/textures/法术特效/龙卷风/T_FirePanningCyl45.png"
## 植被燃烧控制器脚本。它用 new() 构造（不是 instantiate 场景），所以 _ignite_one 必须自己找宿主节点挂载。
const FOLIAGE_BURN := preload("res://scripts/vfx/foliage_burn.gd")
## 植被名字提示（**兜底**用）：项目里的植被没有统一分组，
## 优先用组 "burnable"；没有分组时才按名称匹配，属于权宜之计。
const VEG_HINTS := ["grass", "bush", "flower", "plant", "leaf", "foliage", "weed",
		"shrub", "fern", "clover", "tree", "草", "花", "灌木", "树", "植"]
## 头顶数量上限：0 = 不限；> 0 = 只烧距离最近的 N 株（距离由 _node_distance() 计算）。
## 现在是 0（用户要求取消限制），所以代码里走的是"全都要"分支。
const VEG_MAX := 0                     ## 0 = **不限制数量**（用户要求取消限制）

# ==================== 可调数值（表中缺键时的兜底值） ====================
## 下面这些 @export 都是**兜底**：_load_sheet() 会用 data/spell_sheet.json 里同名字段覆盖它们。
## 所以改这里的默认值，只要表里有对应键就**不生效**（自检 tools/verify_flame_scorch.gd 读的是表）。
## 注意键名与变量名并非一一对应，映射关系见 _load_sheet()。
# ---- 数值（表缺失时的兜底）----
## 单次耗蓝（点）。表键 mana_cost（当前 30）。<= 0 表示完全跳过蓝量检查（见 cast_at）。
## 调大 = 更少能放；调小到 0 = 无限连放。
@export var mana_cost := 30.0
## 点燃阶段时长（秒）。表键 cast_climb（当前 0.35）。这段里 grow 从 0.2 按 sqrt 曲线长到 1.0。
## 调大 = 火爬得更慢（前摇更长）；内部有 maxf(..., 0.01) 兜底，填 0 也不会除零。
@export var ignite_time := 0.35
## 灼烧阶段时长（秒）。表键 duration（当前 8.0）。**只有这一段扣血**，每秒 damage_per_sec 点。
## 调大 = 总伤害线性增加（同时总时长变长、整体观感更久）。
@export var burn_time := 8.0
## 余烬淡出时长（秒）。表键 fade_time（当前 1.2）。此阶段**不扣血**，只把 grow 收到 0。
## 内部同样有 maxf(..., 0.01) 兜底。
@export var afterburn_time := 1.2
## 灼烧期每秒伤害（点/秒）。来自 targeting.damage_per_sec（当前 10.0），缺键时保留本默认值。
## 小数伤害不会丢：在 _dmg_acc 里按目标累积，攒够 1 点才发一次 take_damage(整数)。
@export var damage_per_sec := 10.0
## 影响：它同时放大每簇火与"占地半径"（见 _spawn_patches 的 pscale）；
##   圈很小时 pscale 会被下限 0.45 夹住，所以调大不会让小火堆无限膨胀。
@export var fire_scale := 1.1          ## 单簇火焰的整体缩放
## 每簇火焰大约覆盖多少平方米（用来按圈面积算簇数）
## 单位：平方米/簇。簇数 want = round(πr² / area_per_patch)，再被 patch_min/patch_max 夹住。
## 调大 = 火更稀（省性能）；调小 = 火更密（更费性能，池子会变大且只增不减）。
@export var area_per_patch := 6.0
## 布点数量下限（簇）。半径极小时也至少这么多簇，否则圈里空得看不出有火。
## 调大 = 小圈也铺满，代价是性能；注意要 <= patch_max，否则 clampi 参数非法。
@export var patch_min := 6
## 布点数量上限（簇）。既是观感上限，也是性能护栏（防止大范围一次造出几十份特效）。
@export var patch_max := 14
## 单位：米（scale = 1 时）。默认 1.1 = 实测的火焰水平半径。
## 影响：调大 -> 布点半径更保守（火更挤在中心）；调小 -> 最外圈的火可能压到圈外。
## ★ 单簇火焰在 scale=1 时的**水平半径**（米）。
##   布点半径必须扣掉它，否则火焰会**溢出圈外**（用户实测症状）。
@export var patch_footprint := 1.1

# ==================== 姿态参数（让火焰"坐"在表面上） ====================
# ---- 姿态：让火焰"坐"在表面而不是悬浮 ----
## 姿态向面法线靠拢的比例（1 = 完全贴合表面，0 = 永远竖直）
## 取值：内部 clampf(tilt_gain, 0, 1)，越界会被夹住；纯插值系数，无单位。
## 调大 = 更贴表面（陡坡上更像"趴着烧"）；调小 = 更竖直（更像立着的火苗）。
@export var tilt_gain := 0.55
## 最大倾斜角（度）。火焰毕竟该是向上的，不能跟着陡坡倒下去
## 取值：内部 maxf(max_tilt_deg, 0)，负值按 0 处理（= 永远竖直）。默认 20° 是"看得出贴地、
## 又不会倒成贴纸"的折中；调大 = 陡坡更贴合，过大就会像贴纸。
@export var max_tilt_deg := 20.0
## 沿姿态轴向下沉多少米：把底面压进地面，消掉"悬浮缝"
## 单位：米。默认 0.07 ≈ 火焰底面与地面之间的那条缝；调大 = 底部更深地扎进地形
## （过头会看到火焰被地面切掉一截）。贴地光斑还会额外抬 0.03（见 _spawn_patches）。
@export var ground_sink := 0.07

# ==================== 物体边缘检测参数 ====================
# ---- 物体边缘检测 ----
## 探针距离（米）：在火焰位置四周这个距离上再打射线找"物体"
## 单位：米。太小 = 探不到立着的物体；太大 = 会把远处的地面起伏误判成"边缘"。
@export var edge_probe_dist := 0.55
## 探针命中面的法线朝上程度低于此值 -> 认为碰到了**立面（物体边缘）**
## 取值 0~1（法线 y 分量）。调大 = 更容易判成立面（可能把斜坡也当边缘）。
@export var edge_normal_min := 0.75
## 探针相对中心的高度差超过此值 -> 也认为碰到了边缘/台阶
## 单位：米。调小 = 对台阶更敏感（可能把地面噪声当边缘）；调大 = 只有明显落差才算。
@export var edge_height_delta := 0.35

# ==================== 运行时状态 ====================
## 成功扣蓝后置 true 的"已开始施法"标志。**本文件内没有任何地方把它复位**（状态机回到 ST_OFF 也不动它），
## 所以它只表示"放过至少一发"；判断这一发是否还在演，请用 is_casting()。
## （外部是否读取本字段未在本文件内体现 —— 推测供诊断/自检使用。）
var casting := false

## 施法者（由 spell_caster 通过 setup() 注入）。start_cast()/aim_dir() 用它算落点与朝向；
## 为 null 时分别退回本节点 global_position 与 Vector3.FORWARD。只存引用，**不建立父子关系**。
var _player: Node3D = null
## 上一次 cast_at 是否因**蓝不够**而放弃（ran_out_of_mana() 的返回值）。
## 每次 cast_at 进入时先置 false；只有两个"蓝不足"分支会置 true。
var _ran_out := false
## 状态机当前状态：ST_OFF / ST_IGNITE / ST_BURN / ST_AFTER（常量定义在本段之后）。
## 它同时是**门禁**：不是 ST_OFF/ST_AFTER 时 cast_at/start_cast 会静默忽略（见文件头第 1 条坑）。
var _state := ST_OFF
## 当前状态已持续的时间（秒）。_process 每帧**先加后分派**，所以 ST_OFF 期间它也在涨
## （无影响：每次切换状态都会显式归零）。
var _state_t := 0.0
## 圈心（世界坐标）。cast_at 写入；扣血判定、植被筛选、贴地探测、贴地光斑全部以它为准。
## 未施法时为 Vector3.ZERO（origin_global() 也就返回它）。
var _center := Vector3.ZERO
## 圈半径（米）。cast_at 里用 maxf(radius, 0.5) 兜底；默认 2.5 与 start_cast 的兜底半径一致。
var _radius := 2.5
var _patches: Array[Node3D] = []       ## 复用的火焰簇（避免每次施法现建十几份特效）
var _glows: Array[MeshInstance3D] = []  ## 每簇火脚下的一层"贴地燃烧"光斑（粘滞感）
## 所有光斑**共用**的 ShaderMaterial（uniform：fire_tex / fade）。共用是刻意的：
## 整片火的 grow 是统一的，改一次参数全体生效，也就省下十几个材质对象。
var _glow_mat: ShaderMaterial = null
## 圈内被点着的植被燃烧控制器列表（foliage_burn.gd 实例，挂在本节点的父节点下）。
## 注意：紧邻的下一行 _scanned_instances 的**行尾旧注释**内容实际描述的是本变量
## （历史错位，原样保留未改动）。
var _burns: Array[Node] = []
## 自检用：累计扫描过的 MultiMesh 实例数（证明没有抽样）
## 自检计数：累计扫描过的 MultiMesh 实例数（用来证明块索引"先按块筛"确实生效）。
## tools/verify_flame_scorch.gd 会把它清零后断言：圆在 300 米外时必须为 0。
var _scanned_instances := 0            ## 圈内被点着的植被燃烧控制器
## 是否点燃圈内植被
## 关掉它 = 只留火焰特效、不烧任何植被（调试 / 性能排查用）。
## 注意：它声明在状态变量之后，不在文件头部的数值区（见文件头第 3 条坑）。
@export var burn_vegetation := true
## 本轮实际使用的火焰簇数量（<= _patches.size()）。_apply_grow 只遍历前 _used 个，
## 池里多出来的簇保持在 visible=false 的隐藏状态。
var _used := 0
var _dmg_acc: Dictionary = {}          ## 目标 id -> 累积的小数伤害（保证 take_damage 收到整数）

# ==================== 状态机常量 ====================
## 空闲 / 已结束：不做任何计算（但 _state_t 仍会随帧累加，无影响）。
const ST_OFF := 0
## 点燃：grow 从 0.2 按 sqrt 曲线长到 1.0，时长 ignite_time；此阶段 wants_cast_anim() 返回 true。
const ST_IGNITE := 1
## 灼烧：grow 恒为 1.0，是**唯一**扣血阶段，时长 burn_time。
const ST_BURN := 2
## 余烬：grow 按 pow(1-k, 0.6) 收到 0，**不扣血**，时长 afterburn_time；结束后 _hide_all()。
const ST_AFTER := 3


## 回调：本节点进入场景树时执行一次。
## 作用：打开 _process（状态机靠它推进）、从数值表加载本术法的参数。
## 副作用：set_process(true)；写 mana_cost / ignite_time / burn_time / afterburn_time / damage_per_sec。
## 注意：本文件没有 _exit_tree / _notification 清理逻辑 —— 火簇、光斑、_burns 列表
##   都随本节点一起销毁（spell_caster 在 is_casting() 变 false 后释放实例）。
func _ready() -> void:
	set_process(true)
	_load_sheet()


## 注入施法者引用（spell_caster 创建法术实例后调用一次）。
## 参数 player：施法者节点（通常玩家）。允许 null —— 之后 start_cast/aim_dir 会走兜底分支。
## 参数 staff：法杖节点。**本文件不使用它**，保留只是为了与统一签名兼容。
## 返回值：无。副作用：只写 _player（不建节点、不扣蓝、不发信号）。
## 已知坑参照：docs/法杖握持与朝向系统-技术文档.md（握点/朝向/坐标系的不变量）。
func setup(player: Node3D, staff: Node3D) -> void:
	_player = player


# ==================== 数值表加载 ====================
# ---------------------------------------------------------------- 数值表
## 从 data/spell_sheet.json（经 spell_sheet.gd 静态表）读本行数值，覆盖上面 @export 的兜底值。
## 调用时机：只在 _ready() 里调用一次 —— 因此**运行中改表不会热更**。
## 副作用：写 mana_cost / ignite_time / burn_time / afterburn_time / damage_per_sec。
## 表里没有 "flame_scorch" 这一行时**整体直接 return**（所有 @export 保持默认值）。
## 注意键名与变量名不一致：cast_climb -> ignite_time、duration -> burn_time、
##   fade_time -> afterburn_time；damage_per_sec 在 targeting 段里。
## targeting 段缺失时按 {} 处理（damage_per_sec 保留原值，不会变 0）。
func _load_sheet() -> void:
	if not SHEET.has(SHEET_ID):
		return
	mana_cost = SHEET.f(SHEET_ID, "mana_cost", mana_cost)
	ignite_time = SHEET.f(SHEET_ID, "cast_climb", ignite_time)
	burn_time = SHEET.f(SHEET_ID, "duration", burn_time)
	afterburn_time = SHEET.f(SHEET_ID, "fade_time", afterburn_time)
	var row := SHEET.get_spell(SHEET_ID)
	var tg: Dictionary = row.get("targeting", {})
	damage_per_sec = float(tg.get("damage_per_sec", damage_per_sec))


# ==================== 选点法术接口（供 spell_targeting 使用） ====================
# ---------------------------------------------------------------- 选点法术接口
## 本术法是否需要"圈选选点"：读表里 targeting.enabled（当前为 true）。
## 返回：true = spell_caster 先出示施法区域圆圈，玩家确认后调 cast_at()；
##   false = 走 start_cast() 的兜底落点。
## 纯查询、无副作用；**每次都重新读表**（因此不受 _load_sheet 是否跑过影响）。
func has_targeting() -> bool:
	var row := SHEET.get_spell(SHEET_ID)
	var tg: Dictionary = row.get("targeting", {})
	return bool(tg.get("enabled", false))


## 交给通用选点器 spell_targeting 的参数（直径范围 diameter_min/max、射程 range_min/max、
## 滚轮步长 wheel_step、圈贴图 texture 等）。
## 返回：Dictionary —— **直接返回表里那一段的引用**（当前只作只读使用，调用方不要就地修改）。
## 表缺行/缺段时返回 {}，选点器会退回它自己的默认值。
func targeting_config() -> Dictionary:
	return SHEET.get_spell(SHEET_ID).get("targeting", {})


## 选点确认：在圈定范围内生成火焰
## 参数 center：圈心世界坐标（选点器给出）。参数 radius：圈半径（米）；内部 maxf(radius, 0.5) 兜底。
## 返回值：无。副作用：扣蓝（失败则写 _ran_out）、写 _center/_radius、
##   建/复用火簇与光斑、点燃圈内植被、_state = ST_IGNITE、_state_t 归零、
##   清空 _dmg_acc、grow 置 0.2。
## 注意：① _state 既不是 ST_OFF 也不是 ST_AFTER 时**静默 return**（第二发被忽略 ——
##   spell_caster 回退共享实例时的保护）；② 扣蓝是"先查余额再花"，见下方 ★ 注释。
func cast_at(center: Vector3, radius: float) -> void:
	if _state != ST_OFF and _state != ST_AFTER:
		return
	_ran_out = false
	if mana_cost > 0.0:
		# ★ 先自己判断余额：Mana.try_spend 在不足时会把蓝扣到 0 再返回 false
		if float(Mana.get("current")) < mana_cost:
			_ran_out = true
			return
		if not Mana.try_spend(mana_cost):
			_ran_out = true
			return
	casting = true
	_center = center
	_radius = maxf(radius, 0.5)
	_spawn_patches()
	_ignite_vegetation()               # 圈内的花草树木也跟着烧起来
	_state = ST_IGNITE
	_state_t = 0.0
	_dmg_acc.clear()
	_apply_grow(0.2)


# ==================== 标准接口（spell_caster 统一调用） ====================
# ---------------------------------------------------------------- 标准接口
## 没有选点器时的兜底：直接在角色正前方放一圈（半径用表里的默认）
## 参数：无（朝向取 aim_dir()，落点 = 施法者位置 + 前方 3.6 米）。
## 返回值：无。副作用：同 cast_at（会扣蓝；_player 为 null 时用本节点 global_position 当圆心）。
## 注意：3.6 与 2.5 是**写死的兜底值**，不来自数值表；正常玩法（targeting.enabled = true）走 cast_at。
func start_cast() -> void:
	if _state != ST_OFF and _state != ST_AFTER:
		return
	var fwd := aim_dir()
	var c := (_player.global_position if _player != null else global_position) + fwd * 3.6
	cast_at(c, 2.5)


## 一次性法术：松手不停
## 空实现（故意的）—— 点燃后就自己走完 点燃 0.35s + 灼烧 8s + 余烬 1.2s，松手/按住都不影响。
## spell_caster 在切法术、收武器、离开场景时会调用它，所以必须存在（否则调用点会报错）。
func stop_cast() -> void:
	pass


## 这一发是否还在演出（含余烬阶段）。
## 返回：_state != ST_OFF —— 注意 ST_AFTER（余烬）也算 true，所以"实例可回收"要等余烬结束。
## 纯查询、无副作用。另注：spell_caster 判断"能否再放下一发"用的是 wants_cast_anim()，不是本函数。
func is_casting() -> bool:
	return _state != ST_OFF


## 上一次施法是否因蓝不够而失败（供 spell_caster / UI 提示"法力不足"）。
## 返回：_ran_out —— 每次 cast_at 进入时先置 false，随后只有"余额不足"和"try_spend 失败"两处置 true。
## 纯查询、无副作用。
func ran_out_of_mana() -> bool:
	return _ran_out


## 施法者朝向的水平方向（单位向量），只用于 start_cast() 的兜底落点。
## 返回：_player 的前向 -basis.z 抹掉 y 后归一化；_player 为 null 或已失效时返回 Vector3.FORWARD。
## 纯查询、无副作用。
## 注意：若施法者正好垂直向下/向上看，抹掉 y 后会得到零向量，normalized() 会返回零向量 ——
##   本函数**没有**针对这种退化情形做保护（推测正常玩法下玩家视线不会完全竖直）。
func aim_dir() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.FORWARD
	var d := -(_player as Node3D).global_transform.basis.z
	d.y = 0.0
	return d.normalized()


## 法术"原点"（给 spell_caster 做诊断/绘制用）。
## 返回：_center —— **不是**本节点的 global_position；未施法时是 Vector3.ZERO。
## 纯查询、无副作用。
func origin_global() -> Vector3:
	return _center


## 施法动作保留到点燃结束（保证动作完整走一遍）
## 返回：_state == ST_IGNITE —— 只覆盖点燃的 0.35s；进入灼烧/余烬后就返回 false，
##   所以动作一收就能接下一发（spell_caster 靠它判断"能否再施法"）。
func wants_cast_anim() -> bool:
	return _state == ST_IGNITE


# ==================== 每帧推进（状态机） ====================
# ---------------------------------------------------------------- 每帧
## 主循环：推进状态机 点燃 -> 灼烧 -> 余烬 -> 熄灭。
## 参数 delta：帧间隔（秒），由引擎传入。
## 副作用：_state_t 累加；按状态调 _apply_grow()/_apply_damage()；状态切换时归零 _state_t；
##   进入 ST_AFTER 时清空 _dmg_acc；ST_AFTER 走完调 _hide_all()。
## 注意：_state_t += delta 在 match **之前**，所以 ST_OFF 期间它也在涨（无影响，进新状态会归零）；
##   所有除法都套了 maxf(..., 0.01)，表里把时长填 0 也不会除零。
func _process(delta: float) -> void:
	_state_t += delta
	match _state:
		ST_OFF:
			return
		ST_IGNITE:
			# k = 点燃进度 0..1；maxf(ignite_time, 0.01) 是防"表里填 0"导致除零的兜底
			var k := clampf(_state_t / maxf(ignite_time, 0.01), 0.0, 1.0)
			# ★ 用 sqrt 而不是线性：起步长得快、接近 1 时变慢 —— 更像火苗窜起来，也不会"匀速长高"
			_apply_grow(0.2 + 0.8 * sqrt(k))
			if k >= 1.0:
				_state = ST_BURN
				_state_t = 0.0
		ST_BURN:
			_apply_grow(1.0)
			_apply_damage(delta)
			if _state_t >= burn_time:
				_state = ST_AFTER
				_state_t = 0.0
				_dmg_acc.clear()
		ST_AFTER:
			# ★ 余烬阶段：只缩火，**不扣血**
			var k2 := clampf(_state_t / maxf(afterburn_time, 0.01), 0.0, 1.0)
			# ★ pow(1-k, 0.6)：前段掉得快、后段拖尾，比线性衰减更像余烬自然熄灭；
			#   注意这里只改 grow（逐卡原位缩放），**没有**缩放本节点
			_apply_grow(pow(1.0 - k2, 0.6))
			if k2 >= 1.0:
				_state = ST_OFF
				_hide_all()


# ==================== 内部实现：伤害 ====================
# ---------------------------------------------------------------- 内部
## 圈内扣血：只在整个灼烧阶段被调用（余烬阶段不调用 -> 不扣血）
## 参数 delta：帧间隔（秒）；本帧总伤害 = damage_per_sec * delta。
## 副作用：写 _dmg_acc，并按累积值对目标调 take_damage(整数)；不改 _state、不发信号。
## 注意：① 目标是否在圈内用的是**水平距离**（y 被忽略），所以天上/地下同 xz 的节点也算圈内；
##   ② 距离取节点 global_position（整片草丛这类 MultiMesh 没有特殊处理）；
##   ③ take_damage 是**无 has_method 检查**的直接 call —— 组 "enemies" 里的节点必须实现它，
##     否则会报方法不存在。
func _apply_damage(delta: float) -> void:
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
			continue                       # 不在圈内
		var id := node.get_instance_id()
		var acc := float(_dmg_acc.get(id, 0.0)) + dmg
		# ★ 向下取整：只把"攒够的整数点"发出去，余下的小数留到后续帧（否则每帧取整会丢伤害）
		var whole := int(floor(acc))
		if whole > 0:
			acc -= float(whole)
			node.call("take_damage", whole)
		_dmg_acc[id] = acc


## 找敌人：组 "enemies" 优先；没有就用"树里有 take_damage 方法的节点"兜底
## 返回：Array —— 组 "enemies" 里的节点；当前项目没有敌人系统，因此**通常是空表**。
## 纯查询、无副作用（get_tree() 为 null 时返回空表）。
## 注意：函数名/注释里承诺的"按 take_damage 方法兜底"**实际并没有实现** ——
##   代码在组为空时直接返回空表（原注释如此，本次只做说明，未改代码）。
func _find_targets() -> Array:
	var out: Array = []
	var tree := get_tree()
	if tree == null:
		return out
	out = tree.get_nodes_in_group("enemies")
	if not out.is_empty():
		return out
	# 兜底：项目目前还没有敌人系统，安静返回空表
	return out


## 把生长系数下发给所有"在用"的火簇与贴地光斑。
## 参数 s：0~1 的系数（内部 clampf 夹住）；0 = 完全熄灭，1 = 正常燃烧。
## 副作用：对前 _used 个火簇调 set("grow", g)（fire_burst.gd 的属性）；
##   把共用材质 _glow_mat 的 uniform "fade" 设为 g（一次改全体光斑）。
## 注意：**只改 grow，绝不动本节点的 transform/scale** —— 见文件头第 2 条坑。
##   池里超出 _used 的簇保持 visible=false，不参与本次生长。
func _apply_grow(s: float) -> void:
	var g := clampf(s, 0.0, 1.0)
	for i in range(_used):
		var f := _patches[i]
		if f != null and is_instance_valid(f):
			f.set("grow", g)
	if _glow_mat != null:
		_glow_mat.set_shader_parameter("fade", g)


## 状态机走完（余烬结束）时调用：把火簇与光斑全部隐藏，并把光斑材质 fade 归零。
## 副作用：写各对象的 visible = false 与一个 shader 参数；**不释放节点**（对象池留给下一次施法复用）。
## 注意：是"藏起来"而不是"删掉"，所以 _patches/_glows 会一直挂在本节点下。
func _hide_all() -> void:
	for f in _patches:
		if f != null and is_instance_valid(f):
			f.visible = false
	for mi in _glows:
		if mi != null and is_instance_valid(mi):
			mi.visible = false
	if _glow_mat != null:
		_glow_mat.set_shader_parameter("fade", 0.0)


## 在圈内铺开火焰簇（抖动网格，保证覆盖均匀又不像阵列）
## 调用时机：每次 cast_at() 一次（每发独立实例，互不干扰）。
## 副作用：可能新建池对象（add_child 到本节点）、写 _used、设置每簇的 global_transform / scale / grow、
##   写光斑的 visible 与 global_transform。
## 算法：want = round(πr² / area_per_patch)，夹到 [patch_min, patch_max] -> 取 cols = ceil(sqrt(want)) 的
##   抖动网格布点 -> 超出圆外的点沿径向拉回 -> 每点调 _probe_patch() 取高度、姿态与朝向。
## 注意：① 布点半径 fit = r - patch_footprint*pscale，专门防止火焰**溢出圈外**（用户实测症状）；
##   ② pscale = clampf(r/4, 0.45, 1.0) * fire_scale —— 圈越小，单簇火也越小；
##   ③ 抖动用 randf_range，所以同一发每次布点都不完全一样（不是 bug）。
func _spawn_patches() -> void:
	_area_area_prepare()
	var area := PI * _radius * _radius
	var want := int(round(area / maxf(area_per_patch, 0.5)))
	want = clampi(want, patch_min, patch_max)
	_ensure_pool(want)
	_used = want
	# ★ 火焰自己也有占地 -> 圈越小，火也要越小；布点还要再往里收一个"火半径"，
	#   否则最外圈那几簇会烧到圈外（用户实测症状）。
	var pscale := clampf(_radius / 4.0, 0.45, 1.0) * fire_scale
	var fp := patch_footprint * pscale
	var fit := maxf(_radius - fp, 0.0)
	# 抖动网格布点
	var cols := int(ceil(sqrt(float(want))))
	# 网格边长：可布点区域是 2*fit 见方，除以列数得到格子大小；maxi(cols, 1) 防除零
	var cell := (fit * 2.0) / float(maxi(cols, 1))
	var placed := 0
	for ix in range(cols):
		for iy in range(cols):
			if placed >= want:
				break
			var gx := -fit + cell * (float(ix) + 0.5)
			var gz := -fit + cell * (float(iy) + 0.5)
			# 抖动 + 圆内裁剪（超出可布点半径的点沿径向拉回来）
			var jx := gx + randf_range(-cell * 0.3, cell * 0.3)
			var jz := gz + randf_range(-cell * 0.3, cell * 0.3)
			var d := sqrt(jx * jx + jz * jz)
			if d > fit and d > 0.001:
				var s := fit / d
				jx *= s
				jz *= s
			var f := _patches[placed]
			f.visible = true
			var x := _center.x + jx
			var z := _center.z + jz
			# ★ 姿态：贴合表面 + 底面下沉消缝 +（若有物体）朝边缘对齐而不是随机角
			var pr := _probe_patch(x, z, _center.y)
			var up: Vector3 = pr["up"]
			var y: float = float(pr["y"]) - ground_sink
			var yaw: float = float(pr["yaw"])
			var basis := Basis(Vector3.UP, yaw)          # 先定朝向
			var axis := basis.y.cross(up)                # 再把"上"倾到姿态轴
			# ★ 右乘（* basis）：把"倾斜"叠加进**已经定好 yaw 的局部基**里；
			#   改成左乘会把 yaw 覆盖掉，火焰的朝向就丢了
			if axis.length_squared() > 1e-8:
				basis = Basis(axis.normalized(), basis.y.angle_to(up)) * basis
			f.global_transform = Transform3D(basis, Vector3(x, y, z))
			f.scale = Vector3.ONE * pscale
			f.set("grow", 0.2)
			# ★ 贴地燃烧底光：让火焰"粘"在地表（消掉悬浮的观感）
			var glow := _glows[placed]
			glow.visible = true
			var gup: Vector3 = (pr["up"] as Vector3)
			var gfwd := Vector3(sin(yaw), 0.0, cos(yaw))
			var gright := gfwd.cross(gup)
			if gright.length_squared() < 1e-6:
				gright = Vector3.RIGHT
			gright = gright.normalized()
			gfwd = gup.cross(gright).normalized()
			glow.global_transform = Transform3D(Basis(gright, gfwd, gup),
					Vector3(x, y, z) + gup * (ground_sink + 0.03))
			glow.scale = Vector3.ONE * pscale
			placed += 1


## 空实现（no-op）钩子：在 _spawn_patches() 开头被调用（子类 flame_advance 的 _spawn_patches 也调它）。
## 全工程没有子类覆盖它（推测是历史遗留的预留扩展点）。调用它不产生任何副作用。
func _area_area_prepare() -> void:
	pass


# ==================== 内部实现：对象池 ====================
## 池子：不够才新建（新建火焰特效不便宜，所以复用）
## 参数 n：本轮需要的簇数。
## 副作用：不足时 instantiate(FIRE_SCENE) 并 add_child 到本节点（池子**只增不减**），
##   新对象的 grow 置 0、visible 置 false；最后转调 _ensure_glow_pool(n)。
## 注意：instantiate 失败（返回 null）时会**提前 return**（连光斑池都不建），
##   但调用方仍按 want 设置 _used —— 越界风险由调用方承担（推测正常场景不会失败）。
func _ensure_pool(n: int) -> void:
	while _patches.size() < n:
		var f := FIRE_SCENE.instantiate() as Node3D
		if f == null:
			return
		f.name = "ScorchPatch%d" % _patches.size()
		f.visible = false
		add_child(f)
		f.set("grow", 0.0)
		_patches.append(f)
	_ensure_glow_pool(n)


## 贴地燃烧光斑的池子（共用一份材质：整片火的 grow 是统一的）
## 参数 n：需要的光斑数。
## 副作用：首次调用时创建 _glow_mat（load shader 与纹理；shader 加载失败会 return，
##   于是只有火没有光斑）；不足时新建 QuadMesh(2.6×2.6 米) + MeshInstance3D 并 add_child。
## 注意：① 面片尺寸 2.6 是写死的（不是 patch_footprint）；② 材质**故意共用**，
##   所以 _apply_grow/_hide_all 里改一次 fade 就是全体生灭；
##   ③ cast_shadow 关掉是必须的，否则十几个透明面片会在火下投出方块阴影。
func _ensure_glow_pool(n: int) -> void:
	if _glow_mat == null:
		_glow_mat = ShaderMaterial.new()
		var sh := load(GROUND_SHADER) as Shader
		if sh == null:
			return
		_glow_mat.shader = sh
		var ft := load(FIRE_TEX) as Texture2D
		if ft != null:
			_glow_mat.set_shader_parameter("fire_tex", ft)
	while _glows.size() < n:
		var q := QuadMesh.new()
		q.size = Vector2(2.6, 2.6)
		q.surface_set_material(0, _glow_mat)
		var mi := MeshInstance3D.new()
		mi.name = "ScorchGlow%d" % _glows.size()
		mi.mesh = q
		mi.material_override = _glow_mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_glows.append(mi)


# ==================== 内部实现：植被燃烧 ====================
## 点燃圈内的花草树木：每株一个燃烧控制器，逐株错开点燃（错开才像"火在蔓延"）
## ★ 取"这一片 MultiMesh 里要烧的实例下标"。
##   基类：圆内的全部实例。**扇形子类覆盖它**，把范围收紧成扇区内 ——
##   不覆盖的话扇形法术的逐实例燃烧还是按整圆筛，地面焦痕会是一圈圆（实测症状）。
## 返回：Array，元素是 MultiMesh 实例下标（int），基类实现 = _mm_scan_circle() 命中的全部实例。
## 注意：紧邻上方注释块的**前两行讲的是 _ignite_vegetation**（历史错位，原文未改动），
##   后三行才是本函数；扇形子类 flame_advance 覆盖本函数把"圆内"收成"扇区内"。
func _burn_instance_indices(mmi: MultiMeshInstance3D) -> Array:
	var ids: Array = []
	for h in _mm_scan_circle(mmi, _center, _radius):
		ids.append(int(h["i"]))
	return ids


## 点燃圈内所有可烧植被：逐个交给 _ignite_one()，索引 i 只用于命名与错开延迟。
## 副作用：对每个命中节点**新建**一个 foliage_burn 控制器（挂在父节点下）。
## 注意：① _find_vegetation() 可能返回 0 个（组没建/名字不匹配）—— 此时安静什么都不做；
##   ② 基类这里是"立刻全点"；子类 flame_advance 覆盖成"先记下待烧清单、随波前逐个点"；
##   ③ 调用点在 cast_at()（在状态机进入 ST_IGNITE 之前）。
func _ignite_vegetation() -> void:
	var targets := _find_vegetation()
	var i := 0
	for t in targets:
		if t is Node3D:
			_ignite_one(t, i)
		i += 1


## ★ 点燃一株植被（基类/子类共用）。
##   子类（火焰推进）**推迟到波前到达时**才调它 —— 否则远处的草在火到之前就黑了。
## 参数 t：目标植被节点（MeshInstance3D 走逐实例通道，普通 Node3D 走整节点通道）。
## 参数 i：序号，用于节点命名 FoliageBurn%d 与 0.12*i 秒的错开点燃延迟。
## 副作用：new() 一个 foliage_burn、挂到 get_parent()（无父节点则挂 tree.root）、
##   写入 burn_center/burn_radius/preset_mm/preset_indices/preset_delays，
##   成功则加入 _burns，失败则立即 queue_free。
## 注意：burn_node() 返回 false 表示这株不支持燃烧，此时不留残留节点。
func _ignite_one(t: Node3D, i: int) -> void:
	var b: Node3D = FOLIAGE_BURN.new()
	b.name = "FoliageBurn%d" % i
	var host := get_parent()
	if host == null:
		host = get_tree().root
	host.add_child(b)
	# ★ 逐实例燃烧要"只烧圈内实例"，所以把圆心/半径交给它
	b.set("burn_center", _center)
	b.set("burn_radius", _radius)
	# ★ 把"块内实例表"直接交给控制器：整次施法**只做一次**块扫描，
	#   控制器不再全量遍历（先按块、再查块内）。
	#   ★ 用 _burn_instance_indices()：扇形子类会覆盖它，把"圆内"进一步收成"扇区内"
	#     （不覆盖的话扇形法术会把整圈草都烧黑 —— 实测症状）。
	if t is MultiMeshInstance3D:
		b.set("preset_mm", t)
		b.set("preset_indices", _burn_instance_indices(t as MultiMeshInstance3D))
		# ★ 每实例的延迟：扇形子类按"离角色的距离"给 -> 火焰推进的波前
		var delays := _burn_instance_delays(t as MultiMeshInstance3D)
		if not delays.is_empty():
			b.set("preset_delays", delays)
	if bool(b.call("burn_node", t, float(i) * 0.12)):
		_burns.append(b)
	else:
		b.queue_free()


## 每实例的点燃延迟（秒）。基类不给 -> 控制器用随机错开。
## 返回：Array —— 基类恒为 []（空表 = 让 foliage_burn 自己随机错开）；
##   子类 flame_advance 按"离角色的距离"给秒数，形成火焰推进的波前。
## 纯构造、无副作用。元素必须与 _burn_instance_indices() 的返回**一一对应**。
func _burn_instance_delays(mmi: MultiMeshInstance3D) -> Array:
	return []


## 找圈内可烧的植被：优先组 "burnable"，没有分组时退回名字提示（见 VEG_HINTS 注释）
## 诊断开关：编辑器里跑一次就能在输出面板看到"到底找到了什么植被"，
## 用来排查"某个来源的植被不烧"这类问题（而不是靠猜）。
@export var debug_vegetation := true

## 找出圈内可烧的植被列表（按距离由近到远排序，受 VEG_MAX 上限约束）。
## 返回：Array[Node3D]（可能为空表）。**不创建任何节点**（点燃在 _ignite_vegetation）。
## 搜索顺序：① 优先取组 "burnable"；② 组为空时退回"全树遍历 + 名称提示匹配"（VEG_HINTS，权宜之计），
##   该遍历带 cand.size() < 400 的硬上限（防止大场景卡顿）。
## 筛选：只收 _node_touches_circle() 为真的节点；再按 _node_distance() 升序；VEG_MAX > 0 时截断。
## 副作用：debug_vegetation 为真时向输出面板 print（圆心/半径、候选数、命中数、最近 3 个候选、前 5 个命中）。
## 注意：名字匹配是**兜底**，项目里植被没有统一分组时才生效；靠名字匹配可能漏掉自定义命名的植被。
func _find_vegetation() -> Array:
	var out: Array = []
	var tree := get_tree()
	if tree == null or not burn_vegetation:
		return out
	var cand: Array = []
	var grouped := tree.get_nodes_in_group("burnable")
	if not grouped.is_empty():
		cand = grouped
	else:
		var st: Array = [tree.root]
		# 迭代式遍历（显式栈，不用递归）—— 场景树再深也不会爆栈；400 是防止大场景卡顿的硬上限
		while st.size() > 0 and cand.size() < 400:
			var cur: Node = st.pop_back()
			if cur is MeshInstance3D:
				var nm := String(cur.name).to_lower()
				for hint in VEG_HINTS:
					if nm.contains(String(hint)):
						cand.append(cur)
						break
			for c in cur.get_children():
				st.append(c)
	# 先按"是否触及圈内"筛，再按距离从近到远取前 VEG_MAX 个
	# （否则静态草先把名额占满，addon 草丛永远轮不上）
	var hits: Array = []
	for n in cand:
		if not (n is Node3D) or not is_instance_valid(n):
			continue
		if not _node_touches_circle(n as Node3D):
			continue
		var p := (n as Node3D).global_position
		hits.append({"n": n, "d": _node_distance(n as Node3D)})
	hits.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	for h in hits:
		out.append(h["n"])
		if VEG_MAX > 0 and out.size() >= VEG_MAX:
			break
	if debug_vegetation:
		print("[火焰灼烧] 圆心=%s 半径=%.2f" % [str(_center), _radius])
		print("[火焰灼烧] burnable 组共 %d 个；触及圈内 %d 个；实际点燃 %d 个" % [
				cand.size(), hits.size(), out.size()])
		# ★ 不管在不在圈内，列出最近的 3 个候选：这样"0 个命中"能立刻看出是
		#   距离判定错、还是候选本身的 global_position 不对劲（不用靠猜）。
		var probe: Array = []
		for n in cand:
			if n is Node3D and is_instance_valid(n):
				probe.append({"n": n, "d": _node_distance(n as Node3D)})
		probe.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
		for i in range(mini(probe.size(), 3)):
			var pn := probe[i]["n"] as Node3D
			print("    ~ 最近候选 %d: %s (%s) 距离=%.2f 位置=%s" % [i, pn.name,
					pn.get_class(), float(probe[i]["d"]), str(pn.global_position)])
		for i in range(mini(out.size(), 5)):
			var nn := out[i] as Node3D
			print("    · %s (%s) @ %s" % [nn.name, nn.get_class(), str(nn.global_position)])
	return out


## 这个植被节点距圆心的**有效距离**。
## ★ MultiMesh（addon 的整片草丛）必须取**最近实例**的距离：整片草地是一个节点，
##   原点常常离实际草很远（甚至在世界原点）。用原点距离排序的话草丛永远排最后，
##   会被 VEG_MAX(12) 个名额挤掉 —— 实测诊断：组里 836、圈内 63，点燃的 12 个
##   全是个体道具，草丛一个没轮到。
## MultiMesh 的**块索引**：把实例按 cell 米见方的格子归类；查询时**先筛块、再看块内**。
## 键 = MultiMesh 实例 id；值 = {cell, count, blocks:{Vector2i -> Array[实例下标]}}
## 补充说明：键用的是 MultiMesh 的**实例 id**（mm.get_instance_id()），不是节点 id；
##   值里的 count 用来判断"实例数变没变"，变了就整片重建索引。
##   当前实现只增不删（推测施法次数不多，这点缓存可以接受）。
var _mm_index: Dictionary = {}
## 块大小（米）。太小 -> 块数爆炸；太大 -> 每块实例太多。8 米对草地比较合适。
## 影响：调小 -> 块数变多（建索引更慢、内存更多）；调大 -> 每块实例多，"先按块筛"的收益变小。
## 内部有 maxf(mm_cell_size, 0.5) 下限保护，填 0 不会除零。
@export var mm_cell_size := 8.0


## 参数 mmi：一片草（MultiMeshInstance3D）。返回：索引字典；multimesh 为 null 时返回 {}。
## 副作用：首次构建（或实例数变化后重建）时写缓存 _mm_index —— 只增不删。
## 取（必要时建）某片草丛的块索引；实例数没变就命中缓存
func _mm_block_index(mmi: MultiMeshInstance3D) -> Dictionary:
	var mm := mmi.multimesh
	if mm == null:
		return {}
	var key := mm.get_instance_id()
	var idx: Dictionary = _mm_index.get(key, {})
	# 缓存命中条件：实例数没变就复用；实例数变了（草被增删）必须整片重建，否则存的下标会错位
	if not idx.is_empty() and int(idx.get("count", -1)) == mm.instance_count:
		return idx
	var cell := maxf(mm_cell_size, 0.5)
	var blocks := {}
	for i in range(mm.instance_count):
		var w: Vector3 = mmi.global_transform * mm.get_instance_transform(i).origin
		var bk := Vector2i(int(floor(w.x / cell)), int(floor(w.z / cell)))
		if not blocks.has(bk):
			blocks[bk] = []
		(blocks[bk] as Array).append(i)
	var built := {"cell": cell, "count": mm.instance_count, "blocks": blocks}
	_mm_index[key] = built
	return built


## 参数 center：圆心（世界坐标）；radius：半径（米）。返回：[{i: 实例下标, w: 实例世界坐标}]。
## 副作用：构建/命中块索引；对每个真正检查过的实例累加自检计数 _scanned_instances。
## 判定用**水平距离**（忽略 y）——与扣血的口径一致。
## ★ 两级过滤：**先按块**（只保留与圆相交的块）**再查块内**实例。
## 直接全量遍历上万实例太浪费 —— 这就是块索引的意义。
## 返回 [{i, w}]，w = 实例世界坐标。
func _mm_scan_circle(mmi: MultiMeshInstance3D, center: Vector3, radius: float) -> Array:
	var idx := _mm_block_index(mmi)
	if idx.is_empty():
		return []
	var cell: float = idx["cell"]
	var blocks: Dictionary = idx["blocks"]
	var mm := mmi.multimesh
	var out: Array = []
	var bx0 := int(floor((center.x - radius) / cell))
	var bx1 := int(floor((center.x + radius) / cell))
	var bz0 := int(floor((center.z - radius) / cell))
	var bz1 := int(floor((center.z + radius) / cell))
	for bx in range(bx0, bx1 + 1):
		for bz in range(bz0, bz1 + 1):
			var bk := Vector2i(bx, bz)
			if not blocks.has(bk):
				continue                  # 空块直接跳过（这才是"先按块"的收益）
			for i in (blocks[bk] as Array):
				var w: Vector3 = mmi.global_transform * mm.get_instance_transform(int(i)).origin
				# 自检计数：只有真正被逐个检查过的实例才累加
				# （tools/verify_flame_scorch.gd 靠它证明"先按块筛"确实跳过了远处整片实例）
				_scanned_instances += 1
				if Vector2(w.x - center.x, w.z - center.z).length() <= radius:
					out.append({"i": int(i), "w": w})
	return out


## 节点到圆心的**有效水平距离**（米）。
## 参数 n：候选节点（普通节点用其 global_position；MultiMeshInstance3D 用最近实例位置）。
## 返回：float —— 越小越"该被优先点燃"。
## 副作用：会构建/命中该 MultiMesh 的块索引，并累加自检计数 _scanned_instances（查询但有计数副作用）。
## 注意：整片草丛的**节点原点**通常离实际草很远（甚至在世界原点），所以必须取最近实例距离；
##   否则草丛排序永远靠后、会被 VEG_MAX 名额挤掉
##   （实测诊断：组里 836 个、圈内 63 个，实际点燃的 12 个全是个体道具，草丛一个没轮到）。
##   圈内一个实例都没有时退回节点原点距离 —— 该节点随后必然被 _node_touches_circle() 排除。
func _node_distance(n: Node3D) -> float:
	if n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		if mmi.multimesh != null:
			# ★ 先按块筛、再查块内（见 _mm_scan_circle）：命中就返回其中最近的距离
			var hit := _mm_scan_circle(mmi, _center, _radius)
			if not hit.is_empty():
				var best := 1e9
				for h in hit:
					var w: Vector3 = h["w"]
					best = minf(best, Vector2(w.x - _center.x, w.z - _center.z).length())
				return best
			# 圈内没有 -> 用节点原点距离参与排序（它必然被排除）
			return Vector2(mmi.global_position.x - _center.x,
					mmi.global_position.z - _center.z).length()
	return Vector2(n.global_position.x - _center.x, n.global_position.z - _center.z).length()


## 是否触及圈内（= 有效距离在半径内）
## 参数 n：候选节点。返回：bool，等价于 _node_distance(n) <= _radius。
## 副作用：同 _node_distance()（MultiMesh 会走块索引并累加 _scanned_instances）。
func _node_touches_circle(n: Node3D) -> bool:
	return _node_distance(n) <= _radius


## 从上方朝下打射线找地面
## 参数 pos：采样点（只用到 x/z）；fallback：射线没命中时返回的高度。
## 返回：命中点的 y，否则 fallback。副作用：只读物理空间。
## 注意：本文件内**没有调用点**（推测是为自检 / 后续扩展留的小工具；
##   实际贴地走的是 _probe_patch -> _ray_down 那条路）。
func _ground_y(pos: Vector3, fallback: float) -> float:
	var hit := _ray_down(pos.x, pos.z, fallback)
	if hit.is_empty():
		return fallback
	return (hit["position"] as Vector3).y


## 朝下打一条射线取"脚下表面"（贴地探测的原子操作）。
## 参数 x/z：世界水平坐标；base_y：参考高度 —— 射线从 base_y+15 打到 base_y-60。
## 返回：{}（没世界/没命中）或 intersect_ray 的字典（含 position / normal / collider 等）。
## 副作用：无（只读物理空间）。每次调用是一条射线。
## 算法（两级，见函数体内的 ★ 注释）：
##   ① 精确几何：排除 Layer 3（值 4：导入模型上"比可见网格大一圈"的假碰撞盒），
##      纳入 Layer 16（1<<15：编辑器里烘焙的精确三角网格）；
##   ② 回退：再用全掩码打一条；若②的结果比①明显更高（> 0.35m），说明那个物件只有假盒、
##      没有精确几何，就采用②的顶面（免得火焰掉到物件脚下）。
## 注意：①里的掩码值必须与 scripts/spells/spell_targeting.gd 的 ray_ignore_layer_mask /
##   prop_visual_layer_mask **保持一致**，改一处必须同步改另一处
##   （docs/火焰推进与火焰灼烧选点器-技术文档.md 有登记）。
func _ray_down(x: float, z: float, base_y: float) -> Dictionary:
	var world := get_world_3d()
	if world == null:
		return {}
	var from := Vector3(x, base_y + 15.0, z)
	var to := Vector3(x, base_y - 60.0, z)
	var q := PhysicsRayQueryParameters3D.create(from, to)
	# ★ 第一级（精确几何）：排除 Layer 3（值 4，导入模型那些"比可见网格大一圈"的假碰撞盒），
	#   纳入 Layer 16（1<<15，编辑器里烘的精确三角网格）—— 能穿栅栏缝、不被假盒抬高。
	#   ★ 这两个值必须与 spell_targeting.gd 的 ray_ignore_layer_mask / prop_visual_layer_mask 一致。
	q.collision_mask = (0xFFFFFFFF & ~(1 << 2)) | (1 << 15)
	var hit := world.direct_space_state.intersect_ray(q)
	# ★ 第二级（回退）：没烘过 Layer 16 精确碰撞的物件会被第一级"穿过"，贴地探测就掉到
	#   它下方的地形上。若"旧掩码（含 Layer 3 假盒）"的结果明显更高（差 > 0.35m），
	#   说明那一件只有假盒、没有精确几何 -> 用它的顶面，免得火焰掉到物件脚下。
	#   代价只是一次额外射线（微秒级，与之前的逐面脚本完全不同量级）。
	q.collision_mask = 0xFFFFFFFF
	var hit_old := world.direct_space_state.intersect_ray(q)
	var fallback_drop_m := 0.35
	if hit.is_empty():
		return hit_old
	if not hit_old.is_empty():
		var dy := (hit_old["position"] as Vector3).y - (hit["position"] as Vector3).y
		if dy > fallback_drop_m:
			return hit_old
	return hit


# ==================== 姿态与落点探测（纯函数 + 物理射线） ====================
# ---------------------------------------------------------------- 姿态（纯函数，便于自检）
## 火焰的姿态轴：把面法线**温和地**靠向竖直，并限制最大倾角。
## 参数 normal：射线命中的面法线（世界空间）。返回：单位向量 = 火焰的"上"方向。
## 规则：零向量/退化 -> Vector3.UP；朝下的法线先翻正；再按 tilt_gain 向竖直插值；
##   最后把倾角夹到 max_tilt_deg 以内。
## 纯函数（不写任何状态），所以 tools/verify_flame_scorch.gd 会直接 call 它做自检。
## 为什么不能直接用面法线：陡坡上火焰会整个倒下去，看起来像贴纸。
func _patch_up(normal: Vector3) -> Vector3:
	var nn := normal
	if nn.length_squared() < 1e-8:
		return Vector3.UP
	nn = nn.normalized()
	if nn.y < 0.0:
		nn = -nn                                   # 朝下的法线翻上来
	var blended := Vector3.UP.lerp(nn, clampf(tilt_gain, 0.0, 1.0)).normalized()
	var ang := Vector3.UP.angle_to(blended)
	var lim := deg_to_rad(maxf(max_tilt_deg, 0.0))
	if ang > lim and ang > 1e-5:
		var axis := Vector3.UP.cross(blended)
		if axis.length_squared() < 1e-8:
			return Vector3.UP
		blended = Vector3.UP.rotated(axis.normalized(), lim)
	return blended


## 参数 obstacle_dir：从火焰指向障碍物的水平方向（y 会被忽略）。
## 返回：绕 Y 的 yaw（弧度），使 Basis(UP, yaw) 的 -Z 与边缘走向平行。
## 纯函数、无副作用；obstacle_dir 退化为零向量时返回 0.0（此时保持"未对齐"的中性朝向）。
## 检测到物体边缘时火焰的朝向：**沿着边缘**（垂直于"指向物体"的方向），不再随机。
## 返回绕 Y 的 yaw；该 yaw 下火焰的正前方(-Z)与边缘平行。
func _edge_yaw(obstacle_dir: Vector3) -> float:
	var d := Vector3(obstacle_dir.x, 0.0, obstacle_dir.z)
	if d.length_squared() < 1e-8:
		return 0.0
	d = d.normalized()
	var edge := Vector3(-d.z, 0.0, d.x)            # 水平面上与 d 垂直 = 边缘走向
	return atan2(-edge.x, -edge.z)                 # 使 Basis(UP, yaw) 的 -Z 指向 edge


## 参数 x/z：火焰落点的世界水平坐标；base_y：参考高度（圈心 y，射线的上下界以它为准）。
## 返回：Dictionary {"y": 地面最低点高度, "up": 姿态轴(_patch_up 结果),
##   "yaw": 绕 Y 朝向（无边缘时是 randf()*TAU 的随机值）,
##   "has_edge": bool（四向探针是否碰到立面/台阶）}。
## 副作用：**有** —— 调 randf() 决定随机朝向，并打 13 + 4 条物理射线；不写任何成员变量。
## 采样：中心 1 条 + 两圈（0.45*patch_footprint / 0.9*patch_footprint，各 6 向）共 13 条，取**最低**的那个；
##   再以 edge_probe_dist 向四方向探针找立面（法线不够朝上）或台阶（高差超阈值）。
## 探测一个落点：地面高度（**多点取最低**）/ 姿态轴 / 朝物体边缘对齐的 yaw
## ★ 只打中心一根射线是不够的：火焰簇占地 ~2 米，地面在这个范围内一有起伏，
##   火就架在低处上方 = **悬浮**（用户实测反馈）。所以按占地撒点、取**最低**：
##   宁可让高处的土稍微扎进火里，也不能让火悬空。
func _probe_patch(x: float, z: float, base_y: float) -> Dictionary:
	var out := {"y": base_y, "up": Vector3.UP, "yaw": randf() * TAU, "has_edge": false}
	var c := _ray_down(x, z, base_y)
	var cy := base_y
	var normal := Vector3.UP
	if not c.is_empty():
		cy = (c["position"] as Vector3).y
		normal = c.get("normal", Vector3.UP)
	# 多点采样（中心 + 一圈 + 半径 0.6 处）取最低
	var lowest := cy
	for ring in [0.45, 0.9]:
		for i in range(6):
			var a: float = float(i) / 6.0 * TAU
			var px: float = x + cos(a) * patch_footprint * float(ring)
			var pz: float = z + sin(a) * patch_footprint * float(ring)
			var h := _ray_down(px, pz, base_y)
			if not h.is_empty():
				lowest = minf(lowest, (h["position"] as Vector3).y)
	out["y"] = lowest
	out["up"] = _patch_up(normal)
	# 四向探针找物体边缘
	var best := Vector3.ZERO
	var found := false
	for i in range(4):
		var a2 := float(i) / 4.0 * TAU
		var dir := Vector3(cos(a2), 0.0, sin(a2))
		var s := _ray_down(x + dir.x * edge_probe_dist, z + dir.z * edge_probe_dist, base_y)
		if s.is_empty():
			continue
		var n: Vector3 = s.get("normal", Vector3.UP)
		var sy: float = (s["position"] as Vector3).y
		var is_face := n.normalized().y < edge_normal_min
		var is_step := absf(sy - cy) > edge_height_delta
		if is_face or is_step:
			out["has_edge"] = true
			if not found or absf(sy - cy) > absf(best.length()):
				best = dir * maxf(absf(sy - cy), 0.001)
				found = true
	if out["has_edge"]:
		out["yaw"] = _edge_yaw(best)
	return out

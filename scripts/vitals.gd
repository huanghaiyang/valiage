extends Node
## 角色状态数值：血量 / 精力值 / 舒适度（自动加载为 Vitals）。
##
## 为什么单独做：**魔法值已经有了**（scripts/spells/mana.gd -> Mana），这三项在项目里不存在。
## 接口刻意跟 Mana 对齐，这样 UI 可以用同一套写法绑定：
##     只读   current(stat) / maximum(stat) / ratio(stat) / is_empty(stat)
##     改值   add() / damage() / heal() / spend_stamina() / refill()
##     信号   changed(stat, cur, max) / emptied(stat) / refilled(stat)
## 和 Mana 的差异：Mana 是单值所以用 current/max_mana 两个属性；这里是四选一，
## 所以统一走 stat 参数（枚举 Stat），避免写四套几乎一样的属性。
##
## 驱动来源（**尽量挂到已有系统上，不自己造一套**）：
##   · 精力值 <- 玩家奔跑：player.gd::set_running()（camera_rig 每帧告知"是否按着加速键"）
##              再结合 velocity 判断"是不是真的在跑"，站着按 Shift 不掉精力。
##   · 舒适度 <- 天气：Weather 自动加载里已有的 rain / wind / fog（没有天气时自动回满）。
##   · 血量   <- 目前**只有对外接口**，项目里还没有任何伤害源。
##              以后接摔落/受击/怪物时调 damage() 即可，UI 不用改。
##
## 注意：process_mode 设为 ALWAYS，和 Mana 一致（暂停时也继续跑恢复逻辑）。

##
## ── 所属系统 ──
##   角色数值层（"数据"），不含任何表现：血条/图标全在 scripts/ui/vitals_hud.gd。
##   本文件注册为自动加载单例：project.godot 第 75 行 `Vitals="*res://scripts/vitals.gd"`，
##   加载顺序在 Mana(第 73 行) 之后、VitalsHud(第 76 行) 之前 —— HUD 在 _ready() 里
##   直接读 current()/maximum() 时，本节点必然已经初始化完毕（顺序是有意安排的）。
##   全局访问方式：`/root/Vitals` 或自动加载名 `Vitals`（两者同一节点）。
##
## ── 关键依赖 ──
##   · 天气节点（main.tscn 的 "Weather"，scripts/world/weather.gd，分组 weather_system）：
##     只读 rain / wind / fog 三个参数（取值范围 rain 0..1、fog 0..1、wind 0..1.5，
##     见该文件的天气参数表）。用分组查找并判空，所以天气缺失时舒适度按满值处理，不会报错。
##   · player.gd（CharacterBody3D，且 _ready() 里 add_to_group("player")）：
##     本文件读它的 is_running()（= "加速键被按住"，由 camera_rig 每物理帧告知）
##     与 velocity（Vector3）。两个都拿不到时精力只是"不消耗"，不会崩。
##   · scripts/spells/gold_body.gd：唯一与本文件有隐式协议的外部模块 —— 它在**玩家节点**
##     上写 meta `gold_guard`（gold_body.gd 第 245 行；到期/取消时 remove_meta），
##     本文件 damage() 读这个 meta 来做 100% 抵挡。
##   · scripts/spells/mana.gd：**只是接口风格的对齐参考**（changed/emptied/refilled、
##     try_spend 失败即清零、process_mode = ALWAYS 都是照它抄的），本文件不调用 Mana。
##   · 无 preload / 无外部资源路径：本文件不加载任何场景或资源。
##
## ── 主要对外接口 ──
##   只读：maximum(stat) / current(stat) / ratio(stat) / is_empty(stat) / name_of(stat)
##   改值：set_value(stat, v) / add(stat, amount) / try_spend(stat, amount)
##         / spend_rate(stat, delta, per_sec) / refill(stat = -1)
##   血量：damage(amount) / heal(amount) / is_dead()
##   查询：comfort_target()
##   信号：changed(stat, current, maximum) / emptied(stat) / refilled(stat)
##   枚举：Stat{HP, STAMINA, COMFORT}（外部写 `Vitals.Stat.HP` 即可）
##   目前的生产调用方只有 scripts/ui/vitals_hud.gd（只读 + 连三个信号）；
##   damage()/heal()/add()/refill() 在项目里**还没有**任何调用点（见文件头血量那条）。
##
## ── 已知的坑与注意事项 ──
##   1) 所有写操作必须走 set_value()：它负责 clamp 到 [0, maximum] 并发信号。
##      绕过它直接改 _cur（或外部 set("_cur", ...)）会导致 UI 收不到 changed、数值还可能越界。
##   2) set_value() 用 is_equal_approx 判"没变就不发信号"，所以每帧 <1e-5 量级的增删
##      会被整体吞掉 —— 这是刻意的防刷屏设计，不要指望用它做"滴血"级视觉反馈。
##   3) emptied / refilled 都是**边沿触发**（只在跨过 0 的那一次发），
##      而 mana.gd 的 refill() 是无条件发的。两者行为不同，移植代码时别照搬。
##   4) try_spend() 余额不足时会**把该项清零**（和 Mana.try_spend 一致），
##      "不够就别扣"的调用方必须先用 current() 自己判断。
##   5) _cur / _since_spend 是 Dictionary，键为 Stat 枚举（int）：
##      查不到的键走 get 兜底（-1/0.0），但**写**会新增键；对外只应传三个合法枚举值。
##   6) refill() 的 stat 参数用负数当"三项全满"的哨兵；传非法正数会走 set_value 被夹成 0，
##      等于把该项清零 —— 这是接口的坑，不是笔误。
##   7) 本文件不做任何持久化（没有 save/load 接口）；要存档请自行读 current(stat)。
##   8) 本文件不自己做伤害/回复来源，_process 里只有精力与舒适度两条 tick。
##   9) 本文件头第 7 行提到的 `spend_stamina()` **在这里并不存在** —— 实际接口是
##      try_spend()（按次扣）与 spend_rate()（按速率扣）。推测是早期命名残留；
##      因为约定"只新增注释"，所以不改动那行旧注释，只在此更正。

# ==================== 段：信号与枚举 ====================
## 某项数值真的发生变化时发出（扣、加、回满都算）。
## 参数 stat：Stat 枚举值（int），可用 name_of(stat) 转成中文名。
## 参数 current：变化**之后**的当前值（点，已 clamp 在 [0, maximum]）。
## 参数 maximum：该项上限，一次带上，接收方不必再调 maximum(stat)。
## 副作用：无（纯通知，接收方自己决定刷新什么）。
## 频率：clamp 后与旧值近似相等则**完全不发**；回血/回精力期间基本是每帧一次。
## 接收方约定：vitals_hud.gd 收到后只置一个 dirty 标记，下一帧再统一读值。
signal changed(stat: int, current: float, maximum: float)
## 某项被扣到 0（耗尽）时发出，用于播"没血了 / 没精力了"的提示。
## 触发点：只由 set_value() 在"旧值 > 0 且新值 <= 0"那一次发出（边沿触发）。
## 注意：已经是 0 再被扣 0 不会重复发；从 0 回升时发的是 refilled，两者互斥。
signal emptied(stat: int)
## 某项从 0 恢复为正数时发出（回血、回精力、refill 都可能触发它）。
## 触发点：只由 set_value() 在"旧值 <= 0 且新值 > 0"那一次发出（边沿触发）。
## 注意：本来就是满值时调 refill() **不会**发本信号 —— 这一点与 mana.gd 的 refill() 不同。
signal refilled(stat: int)

## 三项状态项的标识。所有对外方法的 stat 参数都取这里的值（int）。
## 顺序即 UI 常见显示顺序（血 / 精力 / 舒适度），被 vitals_hud.gd 直接使用。
## 注意：值会以 int 形式穿过信号与 meta，被外部当稳定 id 使用；
##       往后追加新状态请**加在末尾**，不要插在中间（会改变已有项的 int 值）。
enum Stat { HP, STAMINA, COMFORT }

# ==================== 段：常量与成员变量 ====================
## 枚举值 -> 中文显示名，供 name_of() 查询（UI 文本 / 调试日志用）。
## 查不到的键由 name_of() 返回 "?"，所以这里不需要穷举所有可能输入。
## 值都是短名而不是完整句子：HUD 一行要放四根条，太长会挤（推测）。
## 注意：本项目未接本地化，这些是写死的中文串（推测：i18n 接入时应整表替换）。
const NAMES := {
	Stat.HP: "血量",
	Stat.STAMINA: "精力",
	Stat.COMFORT: "舒适度",
}

# ==================== 段：可调参数（Inspector / @export） ====================
# 以下参数都能在 Inspector 里调，或被场景/工具脚本 set() 覆盖。
# 注意：上限类参数在运行中改动**不会**自动补满或削减当前值（见 _ready 与 set_value 说明）。
@export_group("上限")
## 血量上限（点）。默认 100.0：整数好读，UI 百分比与"100 滴血"的心智模型一致。
## 改动效果：调大 = 更耐打、进度条同样一格代表的绝对血量更多；
##   调小 = 更容易被一击打空（当前项目还没有伤害源，所以改动暂时只影响 UI 满格读数）。
## 注意：运行中改它只是换分母/夹紧上界 —— 已损失的血量差额会保留（不会因为调大就回满）。
@export var max_hp := 100.0
## 精力上限（点）。默认 100.0，与 max_hp 对齐，HUD 四根条可以复用同一套尺寸与配色逻辑。
## 改动效果：按 sprint_cost_per_sec = 22.0 计，满精力可跑 100/22 ≈ 4.5 秒；
##   调大 = 冲刺更持久；调小 = 更容易 sprint 到空（emptied 触发更频繁）。
@export var max_stamina := 100.0
## 舒适度上限（点）。默认 100.0；它同时是"天气晴朗时的满值"与比例分母。
## 实际舒适度由 comfort_target() 从天气算出来，所以本值决定舒适度的**绝对量级**。
## 改动效果：调大 = 同样天气下舒适度数值更大、每秒向目标靠拢的绝对量也更大；
##   调小 = 曲线整体被压低（按比例算的 0.15 下限不变，天气再差也不会归零）。
@export var max_comfort := 100.0

# ---- 精力：奔跑消耗 + 延迟恢复（数值默认值都是手感调过的，改前先读说明） ----
@export_group("精力")
## 奔跑时每秒消耗的精力（点/秒）。
## 默认 22.0 的理由：满精力 100 / 22 ≈ 4.5 秒冲刺 —— 够横穿一段空地，又不能无限跑。
## 调大：冲刺窗口更短、emptied 更频繁；调小：可以长时间奔跑（低于约 1.0 就几乎无感）。
## 生效前提：只有 _tick_stamina() 判定"真的在跑"（is_running() 且水平速度 > 阈值）才按本值扣。
@export var sprint_cost_per_sec := 22.0     ## 奔跑时每秒消耗
## 停止消耗后每秒恢复的精力（点/秒）。
## 默认 16.0 的理由：100 / 16 = 6.25 秒回满一整条 —— 比冲刺消耗(22)慢，跑完要喘一会儿。
## 调大：回得更快、更难被耗空（调到 0 = 永不自动回精力，只能靠 refill()）；
## 调小：长时间跑动会真正被榨干精力。
## 注意：恢复不是立刻开始的，要先等 stamina_regen_delay 秒（见下一条）；
##   且恢复量按 delta 积分（点/秒，与帧率无关）；已经满值时不做任何写入。
@export var stamina_regen_per_sec := 16.0   ## 停止消耗后每秒恢复
## 停止消耗后多久才开始恢复精力（秒，默认 0.8）。
## 默认 0.8 的理由：按住 Shift 的间隙（换向、撞墙顿一下）不该立刻回精力，避免"边跑边回"的假象。
## 调大：走走停停的惩罚更重、恢复更迟钝；调小（甚至 0.0）：几乎一停就回。
## 实现：_since_spend[STAMINA] 在"真的扣了精力"的那一帧被清零，之后每帧累加；
##   它小于本值就完全不恢复（见 _tick_stamina）。
@export var stamina_regen_delay := 0.8      ## 停止消耗后多久开始恢复（秒）
## 判定"真的在跑"的水平速度下限（米/秒，默认 1.5）。
## 为什么需要它：is_running() 只表示"Shift 被按住"（scripts/player.gd::is_running），
##   站着按住 Shift 也会是 true；因此还要看 velocity 的水平分量是否超过本阈值，
##   否则会出现"站着不动也在掉精力"的假象。
## 测量方式：Vector2(velocity.x, velocity.z).length()（忽略 Y，跳跃下落不算跑）。
## 调大：慢速移动/贴墙蹭行时不掉精力（更容易"白嫖"奔跑）；调小到 0：站着按 Shift 也掉。
@export var sprint_speed_threshold := 1.5   ## 水平速度低于此值不算"在跑"（站着按 Shift 不掉）

# ---- 舒适度：只受天气影响，用"每秒靠拢比例"平滑逼近目标 ----
@export_group("舒适度")
## 每秒向"天气目标值"靠拢的比例（默认 0.35，1.0 = 一帧到位）。
## 实际用法：每帧 lerpf(cur, target, clampf(comfort_track_speed * delta, 0.0, 1.0))，
##   所以它是**指数逼近**而不是线性速度：每秒消掉约 35% 的差距，永远到不了精确目标，
##   靠 _tick_comfort 里的 is_equal_approx 收尾；乘上 delta 后与帧率无关。
## 调大：天气变化时舒适度反应更灵敏（1.0 = 瞬间跳变，观感很硬）；
## 调小：更"迟钝"、慢慢缓过来（0.0 = 舒适度锁死不动）。
@export var comfort_track_speed := 0.35     ## 每秒向"天气目标值"靠拢的比例（1 = 立刻到位）

# ==================== 段：内部状态 ====================
## 三项状态的**当前值**（点），本文件唯一的真实数据源。
## 键：Stat 枚举；值：float，始终被 set_value() 夹在 [0, maximum(stat)] 内。
## 这里的初值 100.0 只是占位兜底：_ready() 会立刻用 @export 的上限覆盖，
##   所以在 Inspector 里把 max_hp 改成 250 后开局就是满血 250（而不是这里的 100）。
## 外部只应通过 current(stat) 读；直接改这个字典会绕过 clamp 与 changed 信号。
var _cur := {
	Stat.HP: 100.0,
	Stat.STAMINA: 100.0,
	Stat.COMFORT: 100.0,
}
## 距上次消耗过去了多久（用来做"停了才恢复"的延迟）
## 初值 999.0 = 远大于任何恢复延迟，等价于"开局立刻处于可恢复状态"；
##   若初值给 0.0，开局就要白等 stamina_regen_delay 秒才开始回精力。
## 写入点：_tick_stamina() 里"正在消耗"时清零、"没消耗"时累加；
##   spend_rate() 在**真的扣成功**时也会把它清零。
## 注意：本文件内部只用到 STAMINA 这一项 —— COMFORT 这一项目前没有任何生产写入点
##   （舒适度走 lerpf 平滑逼近，不是"消耗-恢复"模型），保留它只是为了让 spend_rate()
##   对任意带延迟语义的状态都通用（推测是为将来预留）。
var _since_spend := {
	Stat.STAMINA: 999.0,
	Stat.COMFORT: 999.0,
}
## 缓存的玩家引用（_find_player() 的结果）。
## 为什么要缓存：_tick_stamina() **每帧**都要玩家，而查找要走 group 查询甚至场景树遍历，
##   缓存后正常情况下每帧零成本；玩家被 queue_free 后靠 is_instance_valid 兜底重查。
## 只允许 _find_player() 写它；读之前先判 null + is_instance_valid，不要直接调方法。
var _player: Node3D = null


# ==================== 段：生命周期（autoload 启动） ====================
## 自动加载单例就绪时调用（游戏启动阶段，远早于绝大多数场景节点）。
## 参数：无。返回值：无。
## 副作用：
##   · 把 process_mode 设为 ALWAYS（暂停时本节点的 _process 依然跑，精力/舒适度照常恢复）；
##   · 用三个 max_* 把 _cur 填满（开局一律满值）。
## 调用时机：引擎启动时自动调用一次；外部不要手动调 —— 它会无提示地把三项拉满（等于重置/作弊）。
## 注意：这里**刻意不走 set_value()**，所以开局不会发 changed / refilled：
##   此刻 VitalsHud 还没 _ready、信号连上也收不到，发了纯属浪费；
##   HUD 的做法是自己 _ready 时直接读一次 current()/maximum()（见 vitals_hud.gd）。
func _ready() -> void:
	# 暂停菜单弹出时也要继续恢复精力/舒适度，所以用 ALWAYS（和 Mana 保持一致）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 用 Inspector 的上限覆盖 _cur 的占位初值：改过 max_* 之后开局值必须跟着变。
	_cur[Stat.HP] = max_hp
	_cur[Stat.STAMINA] = max_stamina
	_cur[Stat.COMFORT] = max_comfort


# ==================== 段：只读查询 ====================
# 本段全部无副作用：不改 _cur、不发信号、不动场景树，UI 每帧调用也安全。
# ---------------------------------------------------------------- 只读
## 取某项的上限（点）。stat：Stat 枚举值。
## 返回值：max_hp / max_stamina / max_comfort 三者之一；stat 非法时返回 0.0（不报错）。
## 副作用：无（纯只读）。
## 为什么非法值返回 0.0 而不是 assert：ratio() / set_value() 都拿它当分母或夹紧上界，
##   返回 0 会让非法 stat 自然被夹成 0（静默失败比让 UI 传参错误直接崩掉更合适）。
## 注意：读的是 @export 上限，所以运行中 set() 改 max_* 之后本函数立刻反映新值。
func maximum(stat: int) -> float:
	match stat:
		Stat.HP: return max_hp
		Stat.STAMINA: return max_stamina
		Stat.COMFORT: return max_comfort
	return 0.0


## 取某项的当前值（点）。stat：Stat 枚举值。
## 返回值：_cur 里的值（float）；键不存在时由 Dictionary.get 兜底返回 0.0（不报错、也不新增键）。
## 副作用：无（纯只读，不触发任何信号）。
## 调用时机：想显示数字、或自己算比例时用它；想被"值变了"通知则连 changed 信号
##   （vitals_hud.gd 就是"收信号置 dirty -> 下一帧再读 current()"的模式）。
func current(stat: int) -> float:
	return float(_cur.get(stat, 0.0))


## 取 0.0~1.0 的归一化比例，可直接喂给进度条宽度 / 着色强度。
## stat：Stat 枚举值。返回值：clampf(current(stat) / maximum(stat), 0.0, 1.0)。
## 边界：maximum <= 0.0（非法 stat，或上限被 set 成 0）时返回 0.0 —— 除零保护。
## 副作用：无（每次调用现算，不缓存）。
## 注意：因为已经 clamp，返回值不可能 > 1 或 < 0，外部无需再夹；
##   调大 max_* 会让 ratio 立刻变小（分母变了，分子不变）。
func ratio(stat: int) -> float:
	var m := maximum(stat)
	return 0.0 if m <= 0.0 else clampf(current(stat) / m, 0.0, 1.0)


## 查询某项是否已耗尽。stat：Stat 枚举值。
## 返回值：true = current(stat) <= 0.0；stat 非法时也是 true（current 兜底 0.0）。
## 副作用：无（随时可问的状态查询，与"只发一次"的信号互补）。
## 为什么用 <= 而不是 == 0.0：值来自 clampf 与浮点累减，可能停在 0 附近的极小负数上；
##   mana.gd::is_empty() 也用的同一种写法，保持一致。
## 与 emptied 信号的区别：信号是"归零那一刻"的一次性通知；本函数是任意时刻的状态。
## 语义提示：HP 为空 == 死亡（见 is_dead()）；STAMINA 为空表示"跑不动了"，
##   但本文件**不会**因精力为空而阻止任何行为 —— 拦截逻辑（若有）在调用方。
func is_empty(stat: int) -> bool:
	return current(stat) <= 0.0


## 把 Stat 枚举转成中文短名（"血量" / "精力" / "舒适度"），用于 UI 文本与调试日志。
## 参数 stat：Stat 枚举值（int）。返回值：NAMES 表中的字符串；未知 stat 返回 "?"（不报错）。
## 副作用：无。返回的是 NAMES 里的常量字符串，不是每次新构造的文本（比较时可放心）。
func name_of(stat: int) -> String:
	return String(NAMES.get(stat, "?"))


# ==================== 段：改值入口 ====================
# 约定：所有写操作最终都落到 set_value()；其它函数只是它前面的语义包装（夹紧/边沿/延迟）。
# ---------------------------------------------------------------- 改值
## 唯一写入口：夹紧范围 + 发信号（跟 Mana 一样，UI 只认信号不轮询）
## 参数 stat：Stat 枚举值；v：期望的新值（会被 clampf 到 [0, maximum(stat)]，传负数或超上限都安全）。
## 返回值：无。
## 副作用：写 _cur[stat]；emit changed；跨过 0 时额外 emit emptied 或 refilled。
## 时序：先 changed（已带新值）后 emptied/refilled —— 订阅方先拿到数值，再播"空了"的表现。
## 注意：
##   · 用 is_equal_approx 判"没变就不写不发"：每帧 <1e-5 量级的增删会被整体吞掉（刻意的防刷屏）。
##   · 传非法 stat：maximum 为 0 -> 值被夹成 0，并且会在 _cur 里**新建一个键**（副作用）。
##   · v 必须是有限数：传 NaN / INF 时夹紧与近似比较都会失效，行为不可靠（推测）。
##   · 本函数不重置 _since_spend：它只管数值，恢复延迟由 spend_rate() / 调用方负责。
func set_value(stat: int, v: float) -> void:
	var m := maximum(stat)
	var old := current(stat)
	# 先算出夹紧后的目标值再比较：哪怕 v 越界，只要结果与现值相同就不该发信号。
	var nv := clampf(v, 0.0, m)
	# 近似相等 = "没变"（浮点累加/lerp 的尾差很常见）-> 直接返回：不改值、不发信号。
	if is_equal_approx(nv, old):
		return
	_cur[stat] = nv
	changed.emit(stat, nv, m)
	# emptied / refilled 都是**边沿触发**：只在"跨过 0"的这一次发，避免每帧重复通知。
	if nv <= 0.0 and old > 0.0:
		emptied.emit(stat)
	elif nv > 0.0 and old <= 0.0:
		refilled.emit(stat)


## 增减某项。参数 stat：Stat 枚举值；amount：正数 = 加，负数 = 减，单位与上限相同（点）；0 直接返回。
## 返回值：无。副作用：内部走 set_value -> 改 _cur + emit changed（跨过 0 时还有 emptied/refilled）。
## 调用时机：回血、物品加成、调试改值都可以用它（damage()/heal() 就是它的薄包装）。
## 注意：减过头只会被夹到 0（不会变负），**并且拿不到"够不够扣"的结果**；
##   想知道成败请用 try_spend()，想读精确数值用 current()。
func add(stat: int, amount: float) -> void:
	# amount == 0 提前返回：省掉一次 clamp/比较，也让"空操作"完全不惊动 set_value。
	if amount == 0.0:
		return
	set_value(stat, current(stat) + amount)


## 扣值；够就扣掉返回 true，不够返回 false（不扣成负数）
## 参数 stat：Stat 枚举值；amount：要扣的点数（<= 0.0 视为"不需要扣"，直接返回 true 且不动状态）。
## 返回值：true = 扣款成功；false = 余额不足（见下面这条重要的副作用）。
## 副作用：
##   · 成功：set_value 扣掉 amount -> emit changed（若正好扣到 0 还会 emit emptied）；
##   · 失败：**把该项清零**（不是原样不动！）-> 先 changed，旧值 > 0 时再 emptied，然后返回 false。
## 注意（本文件最容易踩的坑，行为与 Mana.try_spend 一致）：失败即清零。
##   "不够就别花"的调用方必须**先**用 current(stat) 判断余额、再决定要不要调本函数，
##   否则会出现"事情没做成、数值却被清空"的诡异现象。
## 不变量：返回后 current(stat) 一定落在 [0, maximum] 内，绝不会是负数。
## 补充：若进来时已经是 0，失败分支里的 set_value(0.0) 会因"没变化"而不发任何信号。
func try_spend(stat: int, amount: float) -> bool:
	# 扣 0 或负数没有意义：算"成功"且不动任何状态（调用方可以放心传 0）。
	if amount <= 0.0:
		return true
	# 余额不足 -> 按"榨干"处理（清零）并返回 false；这次清零若跨过 0 会触发 emptied。
	if current(stat) < amount:
		set_value(stat, 0.0)
		return false
	set_value(stat, current(stat) - amount)
	return true


## 按"每秒消耗 × delta"扣（和 Mana.spend_rate 同款用法）
## 参数 stat：Stat 枚举值；delta：本帧时长（秒），由调用方的 _process/_physics_process 透传；
##   per_sec：消耗速率（点/秒），<= 0.0 时本帧扣 0（try_spend(0) 视为成功）。
## 返回值：透传 try_spend 的结果 —— true = 本帧扣成功；false = 不够（此时该项已被清零）。
## 副作用：同 try_spend；另外在"确实发生了消耗"时把 _since_spend[stat] 清零，
##   这正是"停止消耗 stamina_regen_delay 秒后才恢复"的计时起点（只在真的扣成功时才重置）。
## 调用时机：凡是"持续消耗"型需求都应走它，而不是每帧自己乘 delta 再调 add(-x)。
## 注意：乘的是 delta，所以掉帧时单帧扣得多、高帧率时扣得少，总消耗仍与真实时间成正比
##   （不会因为帧率低而省精力）；单帧量很小（22 × 1/60 ≈ 0.37），别按整数假设。
func spend_rate(stat: int, delta: float, per_sec: float) -> bool:
	# 速率 × 本帧时长 = 本帧应扣的量（与帧率无关，掉帧不会少扣）。
	var ok := try_spend(stat, per_sec * delta)
	# 只有"真的消耗了"才重置延迟计时；per_sec <= 0 或字典里没这一项时保持原值不动。
	if ok and _since_spend.has(stat) and per_sec > 0.0:
		_since_spend[stat] = 0.0
	return ok


## 把某项（或全部）回满。
## 参数 stat：Stat 枚举值；省略或传负数 = **三项全回满**（默认 -1，方便一键重置 / 复活用）。
## 返回值：无。副作用：逐项走 set_value -> 每项各发一次 changed，从 0 起来的还会发 refilled。
## 与 mana.gd::refill() 的差异：Mana 是"无条件发 refilled"，本函数**本来就满时什么都不发**
##   （set_value 的近似相等分支直接返回）—— 订阅方不要假设调 refill() 一定会收到通知。
## 注意：传一个非法（非负）的 stat 会走 set_value -> maximum 为 0 -> 把该项**清零**；
##   调用方要么省略参数，要么只传 Stat 里的合法枚举值。
func refill(stat: int = -1) -> void:
	# 负数当"全部"的哨兵值：Stat 枚举都是 >= 0，不会与合法值冲突。
	if stat < 0:
		for s in [Stat.HP, Stat.STAMINA, Stat.COMFORT]:
			set_value(s, maximum(s))
		return
	set_value(stat, maximum(stat))


# ==================== 段：血量对外接口（伤害 / 治疗 / 死亡） ====================
# 本段是"给未来伤害源用的入口"：目前项目里没有任何生产调用方，所以改动的风险很低。
# ---------------------------------------------------------------- 血量对外接口
## 以后接伤害源（摔落/受击/怪物）时调这两个即可，UI 不用动
## 作用：扣血。参数 amount：伤害量，内部取绝对值 —— 传负数也一样是扣血，不会被当成治疗。
## 返回值：无。副作用：add(Stat.HP, -|amount|) -> set_value -> emit changed；
##   这一下把血量打到 0 时会 emit emptied(Stat.HP)。
## 调用时机：由伤害源调用（摔落 / 受击 / 怪物 / 陷阱）。当前项目内还没有调用方。
## 护盾协议（重要，细节见函数体内注释）：
##   · 判据是 meta `gold_guard`，由 scripts/spells/gold_body.gd 施放时写在**玩家节点**上；
##   · 本节点自身也会查一次（给 Vitals 自己 set_meta 同样能免伤，调试/无敌模式方便）；
##   · 本节点是 autoload，父节点是 /root 而**不是**玩家 —— gold_body 的标记打在玩家身上，
##     所以"父节点分支"在当前项目里其实命中不到（除非有人把 Vitals 挪到玩家节点下，推测）；
##     真要吃到护盾，伤害源得先查玩家身上的 meta，或由玩家脚本代为转发伤害。
##   · 护盾生效时**完全不打折**：不扣血、不发 changed / emptied，因此也没有受击表现（需求如此）。
func damage(amount: float) -> void:
	# ★★ 金色守护：**100% 抵挡**（用户需求 ✓）
	#   判据：本节点自身或其**父节点**（玩家）带 meta `gold_guard` ✓
	#   meta 由 `scripts/spells/gold_body.gd` 施放时设置 ✓、效果结束时清除 ✓
	#   → 护盾期间任何伤害**直接返回** ✓（不扣血、不触发受击表现 ✓）
	if get_meta("gold_guard", false) or (get_parent() != null and get_parent().has_meta("gold_guard")):
		return
	# 先取绝对值再取负：保证"伤害方向"恒定，调用方传负数也不会变成回血。
	add(Stat.HP, -absf(amount))


## 治疗 / 回血。参数 amount：回血量，内部取绝对值 —— 传负数也只会回血，不会变成伤害。
## 返回值：无。副作用：add(Stat.HP, +|amount|) -> set_value -> emit changed；
##   若血量是从 0 回到正数，还会 emit refilled(Stat.HP)（可当作"复活"的信号用）。
## 边界：回血不会超过 max_hp（set_value 夹紧）；本来就满血时调用它**不发任何信号**。
## 调用时机：目前项目内没有生产调用方（没有伤害源，自然也没人回血）。
func heal(amount: float) -> void:
	add(Stat.HP, absf(amount))


## 查询是否死亡。参数：无。返回值：is_empty(Stat.HP)，即血量 <= 0.0。副作用：无（纯只读）。
## 注意：本文件**不会**因为死亡做任何事 —— 不停止 _process、不隐藏角色、不发额外信号；
##   死亡表现（倒地 / 重生 / 弹 UI）需要外部监听 emptied(Stat.HP) 或主动轮询本函数。
func is_dead() -> bool:
	return is_empty(Stat.HP)


# ==================== 段：每帧驱动 ====================
# 用 _process 而不是 _physics_process：数值平滑不需要物理步长精度；
# 又因为 process_mode = ALWAYS，暂停菜单弹出时这里仍然在跑。
# ---------------------------------------------------------------- 每帧
## 每帧驱动：先算精力（消耗或延迟恢复），再让舒适度向天气目标滑动。不做血量相关的任何事。
## 参数 delta：距上一帧的秒数（引擎传入；因为 ALWAYS，暂停期间 delta 仍按真实时间流逝）。
## 返回值：无。
## 副作用：可能改 _cur[STAMINA] / _cur[COMFORT] 并发 changed（跨过 0 时还有 emptied/refilled）。
## 调用时机：引擎每帧自动调用，不要手动调（会额外跑一次消耗/恢复）。
## 顺序：精力在前、舒适度在后；两者互不依赖（一个读玩家、一个读天气），先后只是可读性选择。
## 性能：每帧成本 ≈ 一次缓存的玩家查询 + 一次天气取值，可忽略。
func _process(delta: float) -> void:
	_tick_stamina(delta)
	_tick_comfort(delta)


## 推进精力：在"真的在跑"时按 sprint_cost_per_sec 消耗，否则等过恢复延迟后按 stamina_regen_per_sec 恢复。
## 参数 delta：本帧时长（秒），由 _process() 透传。
## 返回值：无。
## 副作用：写 _since_spend[STAMINA]；可能改 _cur[STAMINA] 并发 changed（耗尽那一次还会发 emptied）。
## 判据（关键）：sprinting = is_running() **且** 水平速度 > sprint_speed_threshold，两个条件缺一不可 ——
##   只看 is_running() 会让"站着按住 Shift"也掉精力；
##   只看速度又会让"被推着滑行 / 坐骑带着走"莫名消耗。
## 调用时机：每个 _process 帧由 _process() 调用（不要外部调，否则精力会被重复扣）。
## 注意：
##   · 拿不到玩家（p == null）时 sprinting 恒为 false —— 精力只恢复、不消耗，不会崩；
##   · 消耗分支会 return 掉本帧，所以同一帧绝不会"既消耗又恢复"。
func _tick_stamina(delta: float) -> void:
	var p := _find_player()
	var sprinting := false
	if p != null:
		var running := p.has_method("is_running") and bool(p.call("is_running"))
		var v: Variant = p.get("velocity")
		var speed := 0.0
		# 防御性类型判断：is_running() 走 call()、velocity 走 get()，脚本被替换/缺字段时都不会崩。
		if v is Vector3:
			# 只取水平分量（丢掉 Y）：跳跃下落 / 被抬升时的竖直速度不算"在跑"。
			speed = Vector2((v as Vector3).x, (v as Vector3).z).length()
		# 按住加速键 **且** 真的在移动才算奔跑 —— 站着按 Shift 不掉精力（阈值见 sprint_speed_threshold）。
		sprinting = running and speed > sprint_speed_threshold

	if sprinting:
		# 消耗同样乘 delta：掉帧时单帧扣得多，总消耗与真实时间一致。
		try_spend(Stat.STAMINA, sprint_cost_per_sec * delta)
		# 正在消耗 -> 把恢复延迟计时清零（一停下来必须重新等 stamina_regen_delay 秒）。
		_since_spend[Stat.STAMINA] = 0.0
		return

	# 没在跑：累加"距上次消耗"的时间，下面若不足延迟就直接 return（不恢复）。
	_since_spend[Stat.STAMINA] += delta
	if _since_spend[Stat.STAMINA] < stamina_regen_delay:
		return
	# 已经满值就不写：省掉一次无意义的 set_value（它的近似相等分支本来也会直接返回）。
	if current(Stat.STAMINA) < max_stamina:
		set_value(Stat.STAMINA, current(Stat.STAMINA) + stamina_regen_per_sec * delta)


## 让舒适度向 comfort_target() 平滑靠拢（指数逼近，不是线性速度）。
## 参数 delta：本帧时长（秒），由 _process() 透传。
## 返回值：无。副作用：可能改 _cur[COMFORT] 并发 changed（跨过 0 时还有 emptied，但天气公式不会到 0）。
## 实现：lerpf(cur, target, clampf(comfort_track_speed * delta, 0.0, 1.0)) ——
##   权重按 delta 缩放，所以高/低帧率下靠拢速度一致；权重再夹到 <= 1，掉帧时也不会冲过目标。
## 收敛性：指数逼近永远到不了精确目标，所以用 is_equal_approx 做"够近了就停"的收尾，
##   否则会每帧写一次值、发一次 changed（HUD 会长期处于 dirty）。
## 调用时机：每个 _process 帧由 _process() 调用。
func _tick_comfort(delta: float) -> void:
	# 目标值每帧现算（天气参数正在渐变），不缓存。
	var target := comfort_target()
	var cur := current(Stat.COMFORT)
	# 已经"够接近"目标就停手：防止 lerp 的浮点尾差让 _tick 每帧都发一次 changed。
	if is_equal_approx(cur, target):
		return
	# 权重 = 靠拢速度 × delta 并夹到 [0,1]：与帧率无关，且掉帧时不会过冲超过目标。
	set_value(Stat.COMFORT, lerpf(cur, target, clampf(comfort_track_speed * delta, 0.0, 1.0)))


## 舒适度目标值：由**已有**的天气系统给出（下雨/大风/雾 -> 降低）
## 参数：无。返回值：目标舒适度（点），范围 0.15 * max_comfort ~ max_comfort 之间。
## 副作用：无 —— 只读天气节点的参数，不写任何状态、不发信号（实际靠拢由 _tick_comfort 做）。
## 依赖：场景里的天气节点（分组 weather_system）= scripts/world/weather.gd 的
##   rain(0..1) / wind(0..1.5) / fog(0..1)。
##   取不到该节点时返回 max_comfort（没有天气系统就当天气晴朗，方便单场景/无头测试）。
## 公式：penalty = rain*0.55 + max(0, wind-0.35)*0.45 + fog*0.25
##       目标 = max_comfort * clampf(1 - penalty, 0.15, 1.0)
##   · 权重：雨(0.55) > 风(0.45) > 雾(0.25) —— 下雨最难受，雾最轻；
##   · wind 有 0.35 的免罚阈值：weather.gd 里 CLEAR=0.18、CLOUDY=0.35 落在阈值内（不扣分），
##     超出阈值才按超出量扣：OVERCAST 0.45（极少）、RAIN 0.60、WINDY 0.95、STORM 1.10（最多）；
##   · 下限 0.15 是刻意的：STORM 满参数算出的 penalty ≈ 0.975 会被兜到 0.15，
##     即"天气再差也不把舒适度压到 0"，所以天气本身永远不会触发 emptied。
## 调用时机：_tick_comfort() 每帧调一次；也可以被外部调用来"预览"当前天气下的目标值。
func comfort_target() -> float:
	# 按分组找天气节点是刻意的：这就是"挂到已有天气系统上"的落点；
	# 取不到时返回满舒适度而不是报错（单场景调试/无头脚本里没有 Weather 也能跑）。
	var w := get_tree().get_first_node_in_group(&"weather_system") if is_inside_tree() else null
	if w == null:
		return max_comfort
	# w 的静态类型是 Node，直接写 w.rain 会编译不过，所以必须走 get()；
	# 顺带好处：参数缺失时 get 返回 null、float(null) 视为 0.0（推测），天气脚本改名也不会让本文件崩。
	var rain := float(w.get("rain"))
	var wind := float(w.get("wind"))
	var fog := float(w.get("fog"))
	# 三个系数是手感权重；风只算**超出 0.35 的部分**，所以微风/多云不扣舒适度。
	var penalty := rain * 0.55 + maxf(0.0, wind - 0.35) * 0.45 + fog * 0.25
	# 下限 0.15：极端天气最多压到 15%，舒适度不会因天气归零（因此也不会发 emptied）。
	return max_comfort * clampf(1.0 - penalty, 0.15, 1.0)


# ==================== 段：玩家查找（缓存 + 两级兜底） ====================
# 之所以要这套查找：Vitals 是 autoload，启动时场景还没加载，不能直接引用玩家节点。
# ---------------------------------------------------------------- 找玩家
## 优先 group（player.gd 在 _ready 里进组），兜底按名字递归找（和 spell_caster 同款策略）
## 作用：找到并缓存玩家节点。参数：无。
## 返回值：Node3D 玩家；实在找不到返回 null（调用方必须判空 —— _tick_stamina 已经判了）。
## 副作用：写 _player 缓存（命中缓存后不再做任何遍历）。
## 查找顺序：① 有效缓存 -> ② get_first_node_in_group("player") -> ③ 从 current_scene 起深度优先
##   遍历，取名字里含 "player"（忽略大小写）的第一个 Node3D。
## 调用时机：_tick_stamina() 每帧调用，所以必须便宜 —— 缓存就是为它准备的。
## 注意：
##   · get_tree() 为 null（节点还没进树 / 正在退出）时立刻返回 null，避免空引用；
##   · 缓存用 is_instance_valid 判活：玩家被 queue_free（例如切场景）后会自动重新查找；
##   · 名字兜底是惰性的：**一直找不到玩家时每帧都会完整遍历一次场景树**，
##     超大场景有开销（推测：正常流程 group 分支先命中，走不到这里）。
func _find_player() -> Node3D:
	# 缓存快路径：绝大多数帧在第 1 步就返回，不碰场景树。
	# is_instance_valid 而非仅判 null：玩家被 queue_free 后引用仍在，但节点已失效。
	if _player != null and is_instance_valid(_player):
		return _player
	# 还没进树（或正在退出树）时 get_tree() 为 null —— 后面的调用都靠这层保护。
	if get_tree() == null:
		return null
	# 首选分组查询：player.gd::_ready() 会 add_to_group("player")，这是最便宜的正规路径。
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		_player = g as Node3D
		return _player
	var root := get_tree().current_scene
	if root == null:
		return null
	# 兜底：旧注释写的是"递归找"，实现其实是**迭代栈**的深度优先遍历（深场景不会爆栈），效果等价。
	var stack: Array = [root]
	while not stack.is_empty():
		# pop_back 取栈顶 + 子节点继续压栈 = 深度优先；顺序不影响"找到第一个即可"的语义。
		var n: Node = stack.pop_back()
		# 用"名字里含 player"（小写化后比较）而不是精确等号：兼容 Player / PlayerRig / player_node 等命名。
		if n is Node3D and String(n.name).to_lower().contains("player"):
			_player = n as Node3D
			return _player
		# get_children() 返回的是副本数组，所以边遍历边压栈不会破坏本次迭代。
		for c in n.get_children():
			stack.append(c)
	return null

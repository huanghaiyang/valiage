# ==============================================================================
# mana.gd —— 魔法值（蓝量）系统
# ==============================================================================
# 【所属系统】法术系统（scripts/spells/）的公共资源层。本项目把它注册成自动加载
#   单例 "Mana"（project.godot 的 [autoload] 段：Mana="*res://scripts/spells/mana.gd"），
#   所以全局访问方式只有两种：Mana.try_spend(...) 这种直接点方法，
#   或 Mana.get("current") / Mana.set("current", ...) 这种按名字读写。
#   注意：本文件**没有 class_name**，外部拿到的静态类型就是 Node，
#   写错方法名/属性名只有运行时才会报错，改动时请用 grep 确认调用点。
#
# 【职责】维护"当前魔法值 current / 上限 max_mana"这一个数值池，提供：
#   · 扣蓝：try_spend()（按次）/ spend_rate()（按 每秒×delta，持续型法术每帧调）
#   · 查询：has_mana() / ratio() / is_empty()（也可以直接读 current、max_mana）
#   · 自动恢复：_process() 里按 regen_per_sec 积分回蓝，用 _since_spend 实现 regen_delay 延迟
#   · 补蓝：add_mana()（魔法瓶占位接口，目前没有生产调用方）/ refill()（调试与验收用）
#
# 【依赖】本文件**不引用任何其它脚本、场景、资源路径，也不读任何配置表**；
#   所有对外交流都通过属性 + 上述方法 + 下面三个信号完成（零硬依赖）。
#
# 【调用方一览】（静态检索所得，改接口前先评估这些点）
#   · 持续耗蓝型法术每帧调 Mana.spend_rate(delta, mana_per_sec)：
#       scripts/spells/flame_jet_particles.gd、flame_visual.gd、
#       fire_tornado_particles.gd、blue_tornado.gd、gold_body.gd
#   · 按次耗蓝型法术先读 float(Mana.get("current")) 判余额、再 Mana.try_spend(cost)：
#       scripts/spells/water_heal.gd、flame_scorch.gd、detect_pulse.gd
#   · UI：scripts/ui/vitals_hud.gd —— 连接 changed / emptied / refilled 三个信号，
#       并读 current、max_mana 画进度条（约定是"只认信号，不轮询"，见该文件注释）
#   · 调试/验收：tools/ 下的 shot_helper.gd 与 verify_*.gd 用 Mana.call("refill") 回满，
#       用 Mana.call("set", "current", 0.0) 抽干
#
# 【已知的坑与不变量】（改本文件前务必先读）
#   1. try_spend() 在余额不足时**会把 current 直接扣到 0** 再返回 false ——
#      也就是说"没喷出来"同样会清空蓝条。所以"蓝不够就不该施法"的调用方必须**先**
#      自己判余额（water_heal.gd / flame_scorch.gd / gold_body.gd 里的 ★ 注释就是为此写的）。
#      这是有意保留的语义：宁可喷不出，也绝不允许扣成负数。
#   2. 不变量：任何公开接口返回后，current 都落在 [0.0, max_mana] 区间内；
#      且 current 一旦变化就会发 changed（没变化则不发）。
#   3. _ready() 把 process_mode 设成 ALWAYS：游戏暂停（get_tree().paused）时回蓝照样跑，
#      与 scripts/vitals.gd 的处理一致，避免暂停前后数值跳变。
#   4. 回蓝只在 current < max_mana 时执行；满蓝后每帧直接 return，**不再发信号**。
#      所以满蓝静止时收不到持续的 changed，HUD 靠"回满那一帧"的最后一次 changed 停在满条。
#   5. 本文件没有"预留/锁定"概念：has_mana() 只是只读查询、不预扣；同一帧内多个法术
#      按调用顺序先到先得（Godot 主线程顺序执行，不存在并发竞争）。
#   6. 若 max_mana 被设成 0 或负数：ratio() 有除零保护返回 0.0，但所有法术会立刻喷不出来；
#      正常不要把上限设成 0 或负数。
#   7. current 是浮点：每帧扣款量级约 22 × 1/60 ≈ 0.37，不要按整数假设。
# ==============================================================================
extends Node
## 魔法值系统（自动加载为 Mana）。
##
## 规则（按需求）：
##   · 有魔法就能一直喷，耗尽就暂停（喷不出来，但不会"扣成负数"）
##   · 缓慢自动恢复
##   · 魔法瓶预留占位接口（add_mana / refill，具体物品以后接）
##
## 别的系统只读这几个值：current / max_mana / ratio / empty

# ==================== 信号 ====================
## 魔法值发生变化时发出（扣蓝、回蓝、add_mana、refill 都会发）。
## 参数 current：变化**之后**的当前魔法值（浮点，始终 >= 0.0 且 <= max_mana）。
## 参数 maximum：即 max_mana，一次带上上限，接收方不必再读属性。
## 副作用：无（纯通知；接收方自己决定刷新什么）。
## 频率：跟随"值真的变了"的次数 —— 回蓝期间每帧一次；满蓝静止、或还没过回蓝延迟时不发。
## 接收方约定：scripts/ui/vitals_hud.gd 收到后只置一个 dirty 标记，下一帧再统一读值。
signal changed(current: float, maximum: float)
## 魔法值被扣到 0（耗尽）时发出，用于播"没蓝了"的提示/音效。
## 触发点：只有 try_spend() 里"余额不足"的分支会发（见该函数文档）。
## 注意：回蓝把 0 变回正数时**不**发本信号，而是发 refilled；两者语义互斥。
signal emptied()
## 魔法值从 0 恢复为正数，或 refill() 强制回满时发出。
## 触发点：add_mana() 补完由空变有、refill() 每次调用。
## 注意：refill() 是无条件发的（本来就满也会发），订阅方不要假设它是边沿触发。
signal refilled()

# ==================== 可调参数（@export，Inspector 可视） ====================
## 魔法值上限（点）。所有消耗量、恢复量都以此为参照，current 用 minf 夹在本值以内。
## 默认 100.0 的理由：与法术配置表的消耗量同量级 —— 火焰喷射 22 点/秒约能连喷 4.5 秒，
##   单发法术（water_heal 20、flame_scorch 30 等）都能连放几发，手感不紧张。
## 调大：连续施法时间变长，但回蓝速度不变，要更久才回满；
## 调小：更容易出现"喷一半就空了"，emptied 触发更频繁。
## 注意：设为 0 或负数会让所有法术立刻喷不出来（见文件头坑 6）。
@export var max_mana := 100.0
## 启动时是否直接把蓝填满。
## 默认 true：进游戏就有满蓝，玩家不用干等回蓝，也方便 tools/ 下的验收脚本起跑。
## 设为 false：开局空蓝，只能靠 _process 的回蓝慢慢涨（目前没有别的补蓝来源，
##   因为 add_mana 是占位接口、没有生产调用方），会明显拖慢开局体验。
## 生效时机：只在 _ready() 里读一次；运行中在 Inspector 改它**不会**立刻生效。
@export var start_full := true
## 自动恢复速度（点/秒）。
## 在 _process() 里以 current += regen_per_sec * delta 积分实现，所以与帧率无关
## （单位是"每秒"，不是"每帧"）。
## 默认 6.0 的理由：100 / 6 ≈ 16.7 秒回满一整条，节奏上属于"停下来歇十几秒就能再喷"。
## 调大：回蓝更快、更难耗尽；调到 0.0 则完全不回蓝（只能靠 refill / add_mana）。
## 注意：回蓝要等 _since_spend >= regen_delay 之后才开始（见下一个参数）。
@export var regen_per_sec := 6.0          ## 每秒恢复
## 停止消耗后多久才开始回蓝（秒）。
## 默认 1.2 的理由：喷射/连发法术中间的短暂停顿不会立刻回蓝，避免"边喷边回"的假象。
## 调大：停手后要等更久才回蓝，观感更"迟钝"；
## 调小（甚至 0.0）：几乎一停就回蓝，持续喷射期间也容易看到蓝条回升。
## 实现：_since_spend 每帧累加、try_spend() 成功扣款时清零；_process() 里它小于本值就直接 return。
@export var regen_delay := 1.2            ## 停止消耗后多久才开始恢复（秒）
## 默认的持续消耗速率（点/秒）—— 只作为 spend_rate() 不传 per_sec 时的兜底默认值。
## 默认 22.0 的理由：与火焰喷射类法术（flame_jet_particles.mana_per_sec 也是 22.0）同量级，
##   满蓝约能连喷 100 / 22 ≈ 4.5 秒。
## 注意：实际法术基本都会显式传自己的 mana_per_sec，所以改这个值通常**不会**影响那些法术，
##   只影响"没传 per_sec"的调用点（当前项目内的持续型法术都显式传了）。
## 调大：未显式传参的持续型法术更快耗尽；调小则更持久。
@export var spend_per_sec := 22.0         ## 火焰喷射每秒消耗

# ==================== 运行时状态（外部只读） ====================
## 当前魔法值（点）。**唯一的真实数据源**，加法和减法都写在它上面。
## 初值 100.0 与 max_mana 默认值相同，只是兜底；_ready() 会用
##   max_mana / 0.0（取决于 start_full）覆盖它，所以真正的开局值以 _ready 为准。
## 外部读法：Mana.current（若能静态类型化）或 float(Mana.get("current"))。
## 不变量：始终位于 [0.0, max_mana]。外部不要直接赋值 —— 那会绕过 changed 信号；
##   只有调试/验收脚本会刻意 set("current", ...)。
var current := 100.0
## 距上次"成功扣蓝"过去了多少秒，用于实现 regen_delay 的延迟回蓝。
## 初值 999.0（远大于任何 regen_delay）=> 开局立刻处于"可以回蓝"的状态；
##   若初值给 0.0，start_full=false 时开局还要白等 regen_delay 秒才开始回蓝。
## try_spend() 成功扣款时清零；余额不足而失败的**分支不会**清零（直接 return 了）。
var _since_spend := 999.0


# ==================== 生命周期回调 ====================
## 自动加载单例就绪时调用（游戏启动阶段，远早于绝大多数场景节点）。
## 参数：无。返回值：无。
## 副作用：
##   · 把 process_mode 设为 ALWAYS（暂停时 _process 仍继续跑）；
##   · 按 start_full 决定 current 的初值（true -> max_mana，false -> 0.0）。
## 调用时机：引擎启动时自动调用一次；外部不要手动调（会重置蓝量，误用会打断施法状态）。
## 注意：这里**不**发 changed 信号 —— 此刻 HUD 还没 _ready、连上信号也收不到；
##   HUD 是在自己 _ready 时直接读一次 current / max_mana 的（见 vitals_hud.gd）。
func _ready() -> void:
	# 暂停时也继续回蓝：与 vitals.gd 保持一致，否则"暂停 -> 恢复"的瞬间数值会跳变
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 开局蓝量由 start_full 决定；此处刻意不发信号（理由见函数文档）
	current = max_mana if start_full else 0.0


## 每帧驱动：推进"距上次消耗"的计时，并在条件满足时自动回蓝。
## 参数 delta：距上一帧的秒数（引擎传入）。虽然本节点是 PROCESS_MODE_ALWAYS，
##   暂停时 delta 依然按真实时间流逝，所以暂停期间也会回蓝。
## 返回值：无。
## 副作用：写 _since_spend；满足条件时写 current 并 emit changed。
## 调用时机：引擎每帧自动调用（Node._process），顺序由场景树决定；不要手动调。
## 注意：
##   · 刚消耗过（_since_spend < regen_delay）时不回蓝，避免"边喷边回"的假象；
##   · 已经满蓝时直接 return，不写值也不再发信号（见文件头坑 4）；
##   · 恢复量按 delta 积分（单位是点/秒），掉帧不会让回蓝变慢或变快。
func _process(delta: float) -> void:
	# 先无条件累加：无论这帧回不回蓝都要走这一行，否则"回蓝延迟"永远不会结束
	_since_spend += delta
	# 刚消耗过 -> 延迟一会儿再恢复（避免"边喷边回"的假象）
	if _since_spend < regen_delay:
		return
	# 满蓝就早退：不再 minf、也不再发 changed（所以满蓝静止时收不到持续信号）
	if current >= max_mana:
		return
	# 按 点/秒 × 秒数 积分恢复，并用 minf 夹住上限（避免最后一帧冲过头）
	current = minf(max_mana, current + regen_per_sec * delta)
	# 回蓝也发 changed，HUD 靠它刷新蓝条（发的是夹紧之后的值）
	changed.emit(current, max_mana)


# ==================== 对外接口：扣蓝 ====================
## 这帧想消耗 amount；够就扣掉返回 true，不够返回 false（并标记耗尽）
## 参数 amount：本次想消耗的魔法值点数，单位与 max_mana 相同；amount <= 0.0 视为"不消耗"，
##   直接返回 true 且不动任何状态（法术可以放心传 0）。
## 返回值：true = 扣款成功（current 已减去 amount）；false = 余额不足（见下面副作用）。
## 副作用：
##   · 成功：写 current、把 _since_spend 清零（重新开始回蓝延迟）、发 changed。
##   · 失败：**current 被扣到 0.0**（不是原样不动！）、先发 changed 再发 emptied，然后返回 false。
## 调用时机：由具体法术决定 —— 按次耗蓝的法术在"一发"开始时调一次；
##   持续耗蓝型法术请改用 spend_rate()（它会替你乘 delta）。
## 注意（全文件最重要的一条坑）：失败时会把蓝清零。所以"蓝不够就不该放技能"的调用方
##   必须**先**读 float(Mana.get("current")) 判断余额、再调本函数，
##   否则会出现"技能没放出来、蓝却被清空"的诡异现象（water_heal.gd / flame_scorch.gd 就是这么做的）。
## 不变量：返回后 current 一定落在 [0.0, max_mana] 内，绝不会是负数。
func try_spend(amount: float) -> bool:
	# 0 消耗视为"成功了"：法术配置表里 mana_cost 可能配成 0（免费法术），不该被判失败
	if amount <= 0.0:
		return true
	# 余额不足：把 current 归零（有意为之：保证"喷不出但不会扣成负数"）再返回 false。
	# ★ 这个分支同样发 changed + emptied，调用方别以为"失败 = 什么都没发生"
	if current < amount:
		current = 0.0
		changed.emit(current, max_mana)
		emptied.emit()
		return false
	current -= amount
	# 只有真的扣到蓝才重置回蓝延迟；上面余额不足的分支提前 return，不会走到这里
	_since_spend = 0.0
	changed.emit(current, max_mana)
	return true


## 按"每秒消耗 × delta"扣（喷射每帧调用）
## 参数 delta：本帧时长（秒），由调用方的 _process(delta) 直接透传。
## 参数 per_sec：每秒消耗速率（点/秒）。传负数（默认 -1.0）= 使用本文件的 spend_per_sec 兜底；
##   传 0.0 = 本帧不扣蓝（rate*delta = 0，try_spend 会视为成功，等于免费喷射）。
## 返回值：透传 try_spend 的结果 —— true = 本帧扣款成功；false = 蓝不够（此时 current 已被清零）。
## 副作用：同 try_spend（成功：扣蓝 + 重置回蓝延迟 + changed；失败：清零 + changed + emptied）。
## 调用时机：flame_jet_particles / flame_visual / fire_tornado_particles / blue_tornado /
##   gold_body 的 _process 里每帧调用一次。
## 注意：
##   · 因为乘的是 delta，掉帧时单帧扣得多、帧率高时单帧扣得少，总消耗与真实时间成正比
##     （**不会**因为帧率低而省蓝）；
##   · 单帧扣款是小数量级（22 × 1/60 ≈ 0.37），余额与消耗都是浮点，不要按整数假设。
## 为什么不叫 spend：这是"速率型"接口，扣款金额随帧长变化，与按次的 try_spend 语义不同。
func spend_rate(delta: float, per_sec: float = -1.0) -> bool:
	# 负数当哨兵用：没传 per_sec 时退回本文件默认速率；若把负数直接透传会变成"加蓝"
	var rate := spend_per_sec if per_sec < 0.0 else per_sec
	return try_spend(rate * delta)


# ==================== 对外接口：查询（纯读，无副作用） ====================
## 查询"现在蓝够不够"。
## 参数 amount：需要的魔法值点数，默认 0.0。
## 返回值：true = current > 0.0 且 current >= amount。
##   · 用默认参数时 = "现在有蓝"（等价于 !is_empty()）；
##   · 传具体消耗量时 = "够付这笔钱"。
## 副作用：无 —— 纯只读，不改状态、不发信号、也不预扣。
## 调用时机：想"先判断、再决定要不要施法"时用；多数法术是直接读 current 自己比（两种都行）。
## 注意：本函数不会把钱扣掉，判断完到真正 try_spend 之间值理论上可能被别的法术改掉
##   （同一帧按调用顺序先到先得），要求严格的场景应直接用 try_spend 的返回值。
func has_mana(amount: float = 0.0) -> bool:
	return current > 0.0 and current >= amount


## 当前蓝量占上限的比例，供进度条 / 着色 / 特效强度等 UI 消费。
## 参数：无。
## 返回值：0.0 ~ 1.0 的浮点。max_mana <= 0.0 时返回 0.0（除零保护）；
##   正常时是 clampf(current / max_mana, 0.0, 1.0)，顺带兜住 current 越界的情况。
## 副作用：无 —— 每次调用现算，不缓存。
## 调用时机：任何需要 0~1 归一化数值的地方。注意 vitals_hud.gd 走的是自己算
##   current / max_mana，本函数是留给其它调用方（特效、镜头反馈等）的入口。
## 注意：返回 1.0 不代表"刚刚回满"，只表示当前值达到了上限（例如 refill() 后立刻调用）。
func ratio() -> float:
	return 0.0 if max_mana <= 0.0 else clampf(current / max_mana, 0.0, 1.0)


## 查询魔法值是否已经耗尽。
## 参数：无。返回值：true = current <= 0.0。副作用：无。
## 为什么用 <= 而不是 == 0.0：current 是浮点，而且调试脚本可能把它 set() 成负数，
##   用 <= 能同时兜住"略小于零"和"被外部写坏"两种情况。
## 与 emptied 信号的区别：信号是"归零那一刻"的一次性通知，本函数是"随时可问"的状态。
## 注意：它不是 has_mana() 的完整反面 —— has_mana(5.0) 为 false 时蓝也可能还没空。
func is_empty() -> bool:
	return current <= 0.0


# ==================== 占位：魔法瓶（物品系统以后接） ====================
# ---------------------------------------------------------------- 占位：魔法瓶
## 以后接物品时调它；现在没有任何东西调用（按需求"暂时不实现，占位"）
## 增加魔法值（补蓝），供将来的魔法瓶等物品调用。
## 参数 amount：要补的点数（点）。amount <= 0.0 直接 return —— 不扣、不发信号（幂等）。
## 返回值：无。
## 副作用：
##   · current = minf(max_mana, current + amount)，用 minf 夹住上限，补多了不会溢出；
##   · 发 changed；
##   · 若"补之前是空的"且"补完之后不空"，额外发一次 refilled。
## 调用时机：目前**没有任何生产代码调用**（魔法瓶物品系统尚未接入，按需求先占位）；
##   tools/ 下的验收脚本用的是 refill() 和 set("current", ...)，也不走本函数
##   （推测：将来由魔法瓶物品的 use() 把瓶子的补蓝量传进来调用）。
## 注意：本函数不重置 _since_spend，即补蓝不会打断、也不会延后既有的回蓝节奏；
##   补到满之后，下一次 _process 会因 current >= max_mana 直接 return。
func add_mana(amount: float) -> void:
	# 非正数直接忽略：负数补蓝没有意义，0 也不必发信号（避免让 UI 白刷一次）
	if amount <= 0.0:
		return
	# 先记住"补之前是不是空的"，用来决定补完要不要发 refilled（必须在改 current 之前取）
	var was_empty := current <= 0.0
	current = minf(max_mana, current + amount)
	changed.emit(current, max_mana)
	# 只有"从空变有"才算重新充能；本来就有蓝时补蓝不发 refilled
	if was_empty and current > 0.0:
		refilled.emit()


## 把魔法值直接拉满（无条件）。
## 参数：无。返回值：无。
## 副作用：写 current = max_mana、发 changed、再发 refilled —— **即使本来就是满的**也照发。
## 调用时机：tools/ 下的验收脚本（shot_helper.gd、verify_flame_scorch.gd 等）在每个用例
##   开始前 call("refill") 把蓝回满；生产代码目前没有调用点
##   （推测：将来用于睡觉 / 复活 / 传送等"回满"场景）。
## 注意：
##   · 由于无条件发 refilled，连调两次会收到两次通知，订阅方不要假设它是边沿触发；
##   · 它同样不碰 _since_spend，回满后 _process 会因 current >= max_mana 直接 return；
##   · 调试时"抽干蓝"用的是 set("current", 0.0)，本文件没有对应的 drain 接口。
func refill() -> void:
	current = max_mana
	changed.emit(current, max_mana)
	refilled.emit()
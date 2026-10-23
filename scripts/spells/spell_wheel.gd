# ==============================================================================
# spell_wheel.gd —— 法术圆盘（Spell Wheel）
# ==============================================================================
# 【本文件职责】
#   提供一个全屏 CanvasLayer 形态的"环形法术选择盘"：把已实现的术法按 4 层同心环带
#   摆成扇区，鼠标悬停高亮、左键点击选择；选中有术法的格子后关闭圆盘，并把该术法的
#   英文 id 通过信号抛给施法控制器。
#   它是**纯 UI / 选择器**：自己不创建、不驱动任何术法视觉，也不碰魔法值（Mana）、
#   玩家节点或场景，只负责"把玩家点到的术法 id 交出去"。
# 【所属系统】
#   scripts/spells/ 法术系统的最上层交互界面（施法链路：本文件 -> spell_caster.gd -> 各术法脚本）。
# 【关键依赖】
#   · 宿主：由 scripts/spells/spell_caster.gd 在 _ready 里 SpellWheel.new() 创建，
#     命名 "SpellWheel" 后 add_child 到 get_tree().root。所以本节点不出现在任何 .tscn 里，
#     改场景不用动它，但它也不在场景树里"被设计器摆好"，一切都靠代码在 _ready 里搭。
#   · 输入动作：project.godot 的 InputMap 动作 "spell_wheel"（当前绑 Q）由 spell_caster
#     自己轮询；本文件**不读键盘**，只处理鼠标。
#     ★ 注意：本文件顶部原有注释写"按 E 唤出"是历史文案，实际唤出键以 spell_caster.gd 为准
#       （它优先用 InputMap 动作 spell_wheel，项目里没有该动作时才退回直接读 E）。
#   · 信号消费方：spell_caster.gd 的 _on_spell_chosen(id)，收到后按 id 去它的 SPELLS 表
#     取视觉脚本并开始施法。
#   · 反向依赖：spell_caster.gd 在事件阶段调 is_open() 判断"鼠标下压着圆盘"从而屏蔽施法；
#     所以本文件是它的一环，不能独立使用。
#   · 字体：绘制文字用 ThemeDB.fallback_font（首次 _on_draw 时懒取），不依赖自定义主题资源。
#   · 校验脚本：tools/verify_water_heal.gd、tools/verify_gold_body.gd 会用
#     get_script_constant_map() 读取 RING_COUNTS / SPELL_NAMES / ASSIGNED 做一致性校验。
# 【主要对外接口】
#   signal spell_chosen(id: String) —— 选中了"有术法"的格子；参数为术法英文 id
#   signal closed()                 —— 圆盘由开到关（选中后自动关闭也算）
#   open() / close() / toggle()     —— 显隐控制（spell_caster 用动态 call("toggle") 调）
#   is_open() -> bool               —— 供 spell_caster 判断是否要屏蔽世界点击/施法
#   slot_at(control, pos) -> int    —— 局部坐标 -> 槽位键 i*1000+k，-1 = 未命中
#   slot_id_at(control, pos) -> int —— slot_at 的同义别名（历史遗留，见其注释）
# 【已知的坑 / 注意事项】（常量与函数处还有更细的说明）
#   1. 槽位键编码为 层*1000+格，**格号必须小于该层格子数**（见 RING_COUNTS）。第 1 层只有
#      6 格，把第 7 个术法塞进键 6 会导致它在圆盘里永远选不到（实测踩过，见 ASSIGNED）。
#   2. 命中判定是"角度 / step 后 floor"，**不能 +0.5**，否则整体错一格（鼠标指向与高亮不符）。
#   3. 绘制时每格两侧留 0.012 弧度的小缝是纯视觉的；命中判定不含这条缝，贴缝点击会落到
#      相邻格，属于有意接受的偏差。
#   4. 绘制全部由 _draw 手工完成：任何影响画面的状态变化都必须自己 queue_redraw()，
#      否则画面不会刷新（_process 只在打开期间负责这件事）。
#   5. 本节点不是 CanvasItem，自己画不了东西；所有绘制/鼠标处理都落在 _ready 里动态创建的
#      第 0 个子节点 "WheelArea"（Control）上，代码里靠 get_child(0) 取它。
# ==============================================================================
extends CanvasLayer
## 法术圆盘（按 E 唤出）。
##
## 结构（按需求）：4 层，第 1/2/3/4 层分别 6/9/12/15 个术法位。
##   第 1 层第 1 格 = 火焰喷射，其余暂空。
##   选中"有术法"的格子 -> 发信号 + 关闭圆盘；空格子 -> 不关，只提示"空"。
##
## 用 _draw() 画：圆盘天然就是环 + 扇区，比摆一堆 Button 更贴合，也更好命中。

# ==================== 信号 ====================
## 选中"有术法"的格子时发出。
## 参数 id：术法英文 id（= SPELL_NAMES 的 key，也是 spell_caster.gd 的 SPELLS 表的 key），
##   例如 "flame_jet"；永远非空（空格子不发这个信号）。
## 发出时机：圆盘已经 close() **之后**（见 _choose），订阅者拿到的瞬间圆盘已不可见，
##   状态自洽 —— 否则订阅者的施法判定会以为"鼠标下还压着 UI"。
## 副作用（对本文件而言）：发信号前已经改了 _open/visible 并停掉 _process。
signal spell_chosen(id: String)
## 圆盘被关闭时发出（toggle 收起、close()、以及"选中术法后自动关闭"都会走到 close()）。
## 无参数。**幂等**：只有真正从"开着"变成"关着"才会发一次，重复 close() 不再发。
## 当前仓库内没有订阅者（spell_caster 只连了 spell_chosen），保留给外部联动（暂停/HUD 等）用。
signal closed()

# ==================== 配置常量：层数 / 环带几何 / 术法表 ====================
## 每层的格子数。数组下标 = 层号（0 = 最内圈），值 = 该层格子数。
## [6, 9, 12, 15]：从内到外每圈 +3 格，使每格张角依次为 60° / 40° / 30° / 24° ——
##   内圈格子少才放得下长名字，外圈格子多了角度仍不至于挤到点不准。
## ★ 改动影响面很大：它同时是"槽位键的合法格号范围"，必须同步检查 ASSIGNED
##   （每层的格号必须 < 本层的格子数），也要看 tools/verify_water_heal.gd 的校验逻辑。
##   层数（数组长度）也不能随意增减：slot_at/_on_draw 靠它循环，且键编码里的"层"是 0..size-1。
## 当前外圈半径：RING_INNER + 3*(RING_WIDTH+GAP) + RING_WIDTH ≈ 271px（约 542px 直径）。
const RING_COUNTS := [6, 9, 12, 15]      ## 4 层，每层格子数
## 最内圈的**内**半径（像素）。整个圆盘以它为起点向外堆叠。
## 46.0 的取值理由：中心圆盘画在 RING_INNER - 8 处，还要放得下 15px 的提示文字；
##   再调小中心区会挤，再调大第 4 层外沿就会顶到 1080p 屏幕边缘。
## 同时它也是命中判定的下界：鼠标到圆心距离 < 46 时落在中心区，slot_at() 返回 -1（未命中）。
const RING_INNER := 46.0                 ## 最内层半径
## 每层环带的厚度（像素）。54.0 比格子里 13px 的字高出一截，保证文字不压到相邻层；
## 调小 -> 圆盘更紧凑、外圈更靠内（但文字更贴边）；调大 -> 文字更舒展、外圈变大。
## 注意它会改变 _ring_bounds() 算出的每层半径，而命中判定直接复用该函数，所以视觉与命中天然同步。
const RING_WIDTH := 54.0                 ## 每层厚度
## 相邻两层环带之间的空隙（像素）。3.0 很小，只起到"看得出分层"的作用。
## ★ 这个空隙在命中判定里是**真正的死区**：落在缝里的鼠标不匹配任何一层，slot_at() 返回 -1
##   （不选中也不高亮）。所以不要为了视觉好看把它调大，否则会在圆盘上出现一圈"点不动"的环形带。
const GAP := 3.0                         ## 层与层之间的缝
## 术法英文 id -> 圆盘上显示的中文名。**只影响显示文案**，不影响功能
## （功能映射在 spell_caster.gd 的 SPELLS 表里，两边必须同时登记，否则会出现"选了没反应"）。
## 未登记的 id 在绘制时会退回显示 id 原文（见 _on_draw），便于一眼发现漏登记。
## 当前 9 条与 spell_caster.gd 的 SPELLS 一一对应：
##   flame_jet 火焰喷射 / fire_tornado 火焰编织 / blue_tornado 蓝色龙卷风 / detect_pulse 物体探测
##   flame_scorch 火焰灼烧 / gold_body 金色守护 / water_heal 流水治疗 / flame_advance 火焰推进
##   invisibility 隐身（一次性 10 蓝 / 60s / 可刷新）
## 注意：value 是 Variant，取用时必须 String(...) 转换（见 _on_draw / 中心提示文案）。
const SPELL_NAMES := { "flame_jet": "火焰喷射", "fire_tornado": "火焰编织", "blue_tornado": "蓝色龙卷风", "detect_pulse": "物体探测", "flame_scorch": "火焰灼烧", "gold_body": "金色守护", "water_heal": "流水治疗", "flame_advance": "火焰推进", "invisibility": "隐身" }
## 槽位分配表：key = 层*1000 + 格（int），value = 术法英文 id（String）。
##   层 = i（0 = 最内圈，向上到 RING_COUNTS.size()-1）；格 = k（0 = **正上方**，顺时针递增）。
##   这套约定必须与 slot_at() 的起点、_on_draw 的 a0 = -PI/2 完全一致，否则高亮会偏。
## 表中**没有**的键就是空格子：画成暗灰、不写名字、点击不关圆盘、提示显示"空"。
## 例：0 -> 第 1 层第 1 格（正上方）= flame_jet；1000 -> 第 2 层第 1 格 = water_heal。
## 增删术法的步骤：① 这里加/改键；② SPELL_NAMES 补中文名；③ spell_caster.gd 的 SPELLS 注册视觉。
##   三步缺一不可，且键的格号一定要 < 该层格子数（下一条注释就是当年踩过的坑）。
## 另：tools/verify_gold_body.gd、tools/verify_water_heal.gd 会直接读这张表做校验。
## 已实现的术法：key = 层*1000 + 格（层从 0 开始，格从正上方顺时针）
## ★★ 格号必须小于该层的格子数（见 RING_COUNTS）！
##   第一圈只有 6 格（键 0~5），所以第 7 个法术必须放到**第二圈**（键 1000 起，9 格）。
##   之前把 water_heal 放在键 6 上，而 slot_at() 对第一圈只可能返回 0~5，
##   于是这个法术**在轮盘里永远选不到**（实测踩过）。
const ASSIGNED := {
	0: "flame_jet",
	1: "fire_tornado",
	2: "blue_tornado",
	3: "detect_pulse",
	4: "flame_scorch",
	5: "gold_body",          # 第一圈到此满（6 格）
	1000: "water_heal",      # 第二圈第 1 格
	1001: "flame_advance",   # 第二圈第 2 格（新法术：火焰推进）
	1002: "invisibility",    # 第二圈第 3 格（新法术：隐身）
}

# ==================== 运行时状态 ====================
## 圆盘是否打开。唯一的权威开关量：open()/close() 只改它 + visible，
## is_open() 直接返回它；spell_caster 也靠它判断"鼠标下压着圆盘 -> 不施法"。
## 初值 false：进场时圆盘必须是收起的（visible 也在 _ready 里设成 false）。
var _open := false
## 当前鼠标悬停的槽位键（i*1000+k，与 ASSIGNED 的键同域）。-1 = 没悬停在任何格子上
## （鼠标在中心区、在环带之外、或落在层间缝里）。只在 _on_gui_input 里更新；
## _on_draw 用它决定哪一格加亮、中心提示文案优先显示哪一格。
var _hover := -1
## 绘制文字用的字体，**懒加载**（第一次 _on_draw 才取 ThemeDB.fallback_font），初值 null。
## 为什么不在 _ready 里取：本节点是 spell_caster 用 .new() 建的，_ready 可能早于主题就绪；
## 而且字体只有打开圆盘后才真正用到，没必要提前查。null 是"还没取"的哨兵。
var _font: Font = null
## 圆盘已打开的时长（秒）。open() 时清零，_process 里按 delta 累加。
## 唯一用途：打开后的前 3 秒在中心显示引导文案（见 _on_draw 的 _t < 3.0），之后换成默认提示。
## 所以它的精度不重要（帧驱动即可），也没有需要跨帧持久化的语义。
var _t := 0.0


# ==================== 生命周期 ====================
## 初始化：定层级 / 先隐藏自己 / 无视暂停，然后**动态创建一个全屏 Control** 作为绘制与鼠标的载体。
## 参数：无。返回值：无。
## 副作用：往自己（CanvasLayer）下挂一个名为 "WheelArea" 的 Control 子节点，
##   并把该 Control 的 draw 与 gui_input 两个信号接到本脚本的回调上（改场景树 + 建立连接）。
## 调用时机：由 Godot 在本节点进入场景树时自动调用一次（本节点是 spell_caster 运行时 add_child 进来的）。
## 注意：
##   · 本节点不是 CanvasItem，自己画不了东西，所有绘制都发生在 WheelArea 上；因此后面
##     _process / _on_gui_input 都用 get_child(0) 取它 —— 若以后再加子节点，必须保证 WheelArea 仍是第 0 个。
##   · 这里**没有** set_process(false)：脚本定义了 _process，Godot 默认就会每帧调用它。
##     圆盘没打开时 _on_draw 会在 not _open 处提前 return，没有绘制开销；
##     第一次 close() 之后才会真正停掉 _process（见 close）。
func _ready() -> void:
	# 90：压在普通 HUD/字幕层之上、模态设置菜单（settings_menu 用 100）之下。
	# 圆盘的 WheelArea 是全屏遮罩，层级一旦排在菜单之上就会挡住菜单的鼠标操作。
	layer = 90
	# 默认收起：只有 open() 才显示，避免一进场就糊一层半透明黑。
	visible = false
	# 即使 get_tree().paused 为真也继续处理，否则暂停中打不开/选不了法术（圆盘常和暂停态一起用）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 本节点不需要 _input：鼠标事件由子 Control 的 gui_input 精确投递；
	# 关掉它也避免和 spell_caster（它自己开了 _input 判"按下是否落在 UI 上"）抢/重复处理事件。
	set_process_input(false)
	# WheelArea：承载全部绘制与鼠标交互的 Control。
	var c := Control.new()
	c.name = "WheelArea"
	# 铺满整个视口：圆盘以视口中心为圆心，遮罩也必须全屏，这样点空白/边缘处也会被它吃掉。
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	# STOP：拦住鼠标。一是防止点击穿透到 3D 世界（否则点空白格会同时触发世界交互），
	# 二是让 spell_caster 的"鼠标下压着 Control"命中测试能检测到圆盘正开着。
	c.mouse_filter = Control.MOUSE_FILTER_STOP
	# draw 信号无参数，用 bind 把要绘制的 Control 直接塞进回调，
	# 省掉回调里再 get_child(0)（也避免子节点顺序变化时画错对象）。
	c.draw.connect(_on_draw.bind(c))
	# gui_input：悬停与点击都在这个回调里处理（本节点自己不开 _input，见上）。
	c.gui_input.connect(_on_gui_input)
	add_child(c)


# ==================== 对外接口：开 / 关 / 查询 ====================
## 查询圆盘当前是否打开。
## 参数：无。返回：true = 圆盘可见且正在接受鼠标（_open 的值）。
## 副作用：无（纯读取，不改状态、不发信号、不触发重绘）。
## 调用时机：任意时刻。spell_caster 在**事件阶段**（它的 _input）用它判断"鼠标下压着圆盘"
##   从而屏蔽施法，所以这个函数必须保持廉价且无副作用。
func is_open() -> bool:
	return _open


## 打开圆盘。
## 参数：无。返回值：无。
## 副作用：_open = true、visible = true、_hover 重置为 -1、_t 清零、开启每帧 _process（驱动重绘）。
## 调用时机：由 toggle() 在圆盘关着时调用（spell_caster 检测到 InputMap 动作 spell_wheel，当前绑 Q）。
## 注意：
##   · **不发信号**：打开这件事没有对外广播的需求，只有关闭才发 closed。
##   · 重复调用是安全的：已经开着再 open() 只会把悬停高亮和 3 秒引导计时重置，等价于"重新打开"。
func open() -> void:
	_open = true
	visible = true
	# 清掉上次的悬停：否则刚打开就会高亮上次停留的那一格（鼠标此时可能根本不在那儿）。
	_hover = -1
	# 重置提示计时：让"第 1 圈已满…"这段引导文案每次打开都重新显示 3 秒（见 _on_draw 的 _t < 3.0）。
	_t = 0.0
	# 打开期间需要每帧重绘（_t 影响中心文案），关闭时由 close() 关掉。
	set_process(true)


## 关闭圆盘。
## 参数：无。返回值：无。
## 副作用：_open = false、visible = false、_hover = -1、停掉每帧 _process；
##   并且**只在真正从开到关时**发一次 closed 信号。
## 调用时机：① toggle() 收起；② _choose() 选中"有术法"的格子后自动关闭；③ 宿主可直接调用。
## 注意：
##   · **幂等**：已经关着时立刻 return。不能去掉这个闸门 —— 否则订阅者可能重复收到 closed
##     （比如将来用它做暂停/存档联动），而且"选中后关闭"再叠加宿主关闭会发两遍。
##   · 先改状态、后发信号（_choose 里也是先 close() 再 emit spell_chosen）：这样订阅者回调里
##     读到的圆盘状态一定是最新的，is_open() 不会返回过期的 true。
func close() -> void:
	# 幂等闸门：见函数说明（不能去掉）。
	if not _open:
		return
	_open = false
	visible = false
	_hover = -1
	# 关闭后没有需要刷新的画面，停掉 _process 省掉每帧的 queue_redraw（下次 open() 会重新打开）。
	set_process(false)
	closed.emit()


## 开 / 关二选一（SPELL WHEEL 的开关键走这里）。
## 参数：无。返回值：无。
## 副作用：转调 open() 或 close()，具体见那两个函数。
## 调用时机：spell_caster 每帧轮询到 InputMap 动作 spell_wheel（当前 Q）刚按下时，
##   通过 wheel.call("toggle") 动态调用 —— 宿主只持有 CanvasLayer 类型，所以是用字符串调用的，
##   **本函数名不能改**（改了宿主就静默失效）。
func toggle() -> void:
	if _open:
		close()
	else:
		open()


# ==================== 每帧刷新 ====================
## 打开期间每帧推进提示计时并请求重绘。
## 参数 delta：距上一帧的秒数（引擎传入，约 1/帧率），用于累加 _t。
## 返回值：无。
## 副作用：_t += delta；对第 0 个子 Control 调 queue_redraw()（真正的绘制在 _on_draw 里）。
## 调用时机：set_process(true) 之后每帧，即圆盘打开期间（close() 会停掉它）。
## 注意：
##   · 为什么必须每帧重绘：圆盘完全靠 _draw 手绘，Godot 不会自动重画；而中心提示文案在
##     打开前 3 秒（_t < 3.0）与之后不同，没有帧驱动就永远停在第一句上。
##   · _ready 里没关 _process，所以"还没打开过圆盘"时它也在跑；此时 _on_draw 会在
##     not _open 处提前 return，没有实际绘制成本。首次 close() 之后才真正停掉。
##   · get_child(0) 就是 _ready 里建的 WheelArea（见 _ready 的注意事项）。
func _process(delta: float) -> void:
	_t += delta
	var c := get_child(0) as Control
	if c != null:
		c.queue_redraw()


# ==================== 几何：圆心 / 环带半径 / 命中换算 ====================
# ---------------------------------------------------------------- 几何
## 取圆盘圆心。
## 参数 c：承载绘制与鼠标的 Control（即 get_child(0)，名为 WheelArea）。
## 返回：c 的尺寸一半 —— 因为 WheelArea 是 FULL_RECT，所以结果就是视口中心（像素）。
## 副作用：无（纯计算）。
## 注意：本文件里所有坐标都是**该 Control 的局部坐标**；gui_input 给的 position 也是局部坐标，
##   所以鼠标位置可以直接和圆心/半径比较，不需要做屏幕坐标换算。改窗口大小后 c.size 会变，
##   圆心自然跟着变（每一帧现算，没有缓存，所以不存在"改分辨率后圆盘错位"的隐患）。
func _center(c: Control) -> Vector2:
	return c.size * 0.5


## 计算第 i 层环带的内外半径。
## 参数 i：层号，0 = 最内圈，合法范围 0 .. RING_COUNTS.size()-1（4 层时为 0~3）。
##   越界不会报错，但会算出一个半径很大的环（调用点应自行保证 i 合法）。
## 返回：Vector2(内半径, 外半径)，单位像素；内半径 = RING_INNER + i*(RING_WIDTH + GAP)，
##   外半径 = 内半径 + RING_WIDTH。
## 副作用：无（纯计算）。
## 用法：_on_draw 用它画扇区，slot_at 用它做命中测试 —— 两边共用同一个函数，
##   所以"看到的环"和"点到能命中的环"天然一致，改 RING_INNER/RING_WIDTH/GAP 只需改常量。
func _ring_bounds(i: int) -> Vector2:
	# 第 i 层的内半径：最内层就是 RING_INNER，往外每层再加"厚度 + 缝"。
	var r0 := RING_INNER + float(i) * (RING_WIDTH + GAP)
	return Vector2(r0, r0 + RING_WIDTH)


## 命中测试：把 Control 局部坐标换算成槽位键。
## 参数 c：承载绘制的 Control（= WheelArea，提供圆心与尺寸）；
##   pos：鼠标位置，**必须是 c 的局部坐标**（gui_input 的 motion.position / mb.position 正好是）。
## 返回：i*1000 + k（i = 层号从 0 起，k = 格号从**正上方**顺时针从 0 起）；
##   -1 = 没命中任何格子：在中心圆盘内（r < RING_INNER）、在最外圈之外，或恰好落在层之间的 GAP 缝里。
## 副作用：无（纯函数，不改状态、不发信号、不触发重绘）。
## 算法：先用"到圆心的距离 r"决定落在第几层（由内向外扫，命中即返回），再用极角决定哪一格；
##   两层几何都取自 _ring_bounds()/RING_COUNTS，与绘制共用，所以视觉与命中天然一致。
## 注意：
##   · 角度约定必须与 _on_draw 的 a0 = -PI/2 + k*step 完全一致（第 0 格在正上方、顺时针递增），
##     任何一边改了都要同步改另一边，否则出现"鼠标指向与选中不符"。
##   · 落在 GAP 缝里返回 -1 是刻意行为（不选中也不高亮），不要"就近吸附"到某一层。
## 返回 层*1000+格；-1 = 没命中
func slot_at(c: Control, pos: Vector2) -> int:
	var v := pos - _center(c)
	var r := v.length()
	# 由内向外逐层试：半径 r 只能落进某一层；层与层之间的 GAP 是死区，落进去就一路扫完并返回 -1。
	for i in range(RING_COUNTS.size()):
		var b := _ring_bounds(i)
		if r >= b.x and r <= b.y:
			var n: int = RING_COUNTS[i]
			var step := TAU / float(n)
			# 第 0 格从正上方开始，顺时针
			# +PI*0.5：把 Godot 的"0 弧度 = 正右方"旋转到"正上方"（2D 里 y 轴向下，角度增大即顺时针）；
			# fposmod 再把结果归一化到 [0, TAU)，后面的除法与取模才安全。
			var a := fposmod(v.angle() + PI * 0.5, TAU)
			# ★ 不要 +0.5：格子中心在 a0+step/2，再加 0.5 会整体错一格（实测症状=鼠标指向与选中不符）
			# floor 而不是 round：格子边界正好是 step 的整数倍；% n 兜住 a 接近 TAU 的极值情形。
			var idx := int(floor(a / step)) % n
			return i * 1000 + idx
	return -1


## slot_at() 的同义别名（返回同样的 i*1000+k，-1 = 未命中），参数与副作用完全相同。
## 保留原因：早期接口名（推测是为了兼容旧调用/外部脚本）；当前仓库内除本文件外没有调用点，
##   真正的命中测试都直接调 slot_at()。新代码请用 slot_at()，不要在这条路径上叠加新逻辑。
func slot_id_at(c: Control, pos: Vector2) -> int:
	return slot_at(c, pos)


# ==================== 鼠标输入：悬停 / 点击 ====================
# ---------------------------------------------------------------- 输入
## WheelArea（第 0 个子 Control）的鼠标事件回调，连接于 _ready。
## 参数 ev：该 Control 局部坐标系下的事件 —— 位置是 WheelArea 局部坐标，与 _center() 同一坐标系，
##   所以可以直接喂给 slot_at()，不需要任何换算。
## 返回值：无。
## 副作用：鼠标移动 -> 更新 _hover 并 queue_redraw()（只重绘，不动 _open、不发信号）；
##   左键按下 -> 命中则调 _choose()（可能关圆盘 + 发信号），并且两种情况都会把事件标记为已处理。
## 调用时机：圆盘可见时由 Godot 在 GUI 阶段投递（mouse_filter = STOP 才收得到，见 _ready）。
## 注意：
##   · 这里**只处理鼠标**：键盘开合由 spell_caster 轮询 InputMap 动作 spell_wheel 完成，本文件不读键盘。
##   · 选择发生在左键"按下那一瞬"（pressed），抬起不再处理；因为选中后立刻 close()（visible=false），
##     后续事件不会再投递到这里，所以不会出现"一次按住选两格"。
##   · set_input_as_handled() 写在 if 之外是刻意的：即使点了中心/缝隙/圈外（id < 0）也要吃掉这次点击，
##     否则事件会继续传播到世界，出现"点了个空格子却顺手打到场景"的串扰。
func _on_gui_input(ev: InputEvent) -> void:
	# 取 _ready 里建的 WheelArea；理论上不会为空，空判纯粹是防御（后面所有坐标换算都依赖它）。
	var c := get_child(0) as Control
	if c == null:
		return
	if ev is InputEventMouseMotion:
		# 悬停只更新状态 + 请求重绘：不改 _open、不发信号，代价必须保持很低（鼠标一动就触发）。
		_hover = slot_at(c, (ev as InputEventMouseMotion).position)
		c.queue_redraw()
	elif ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		# 只认左键"按下"那一瞬，和 spell_caster 的施法键保持一致，避免左右键混用导致误选。
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			# mb.position 已经是 WheelArea 局部坐标，可直接命中测试。
			var id := slot_at(c, mb.position)
			# id < 0（点中心圆盘、点层间缝、点圈外）时不选任何东西，但下面照样吃掉事件。
			if id >= 0:
				_choose(id)
			# 无论是否选中都标记事件已处理：阻止点击穿透到 3D 世界（否则会顺手触发交互/施法）。
			get_viewport().set_input_as_handled()


## 选中某个槽位（内部函数，只由 _on_gui_input 在左键按下时调用）。
## 参数 id：槽位键 i*1000+k（调用方已保证 >= 0；未命中时根本不会走到这里）。
##   取值必须落在 ASSIGNED 的键域里才有意义，其他值等同于"空格子"。
## 返回值：无。
## 副作用：
##   · 该槽位**有术法** -> 先 close()（会发 closed 信号）再 spell_chosen.emit(sid)；
##   · 该槽位是**空格子** -> 什么都不做（圆盘保持打开，只由 _on_draw 的提示显示"空"）。
## 调用时机：左键点在有效格子上。
## 注意：
##   · 顺序是"先 close() 再 emit"：订阅者（spell_caster）收到信号时圆盘已不可见，
##     它的施法判定才不会把这一下当成"鼠标下压着 UI"而拦掉；反过来写会出现"选了法术但放不出来"。
##   · ASSIGNED.get(id, "") 用空串当"没有术法"的哨兵：表里 value 都是非空 String，
##     不存在合法的 ""，所以 is_empty() 判定是安全的（也用不着 has() 再取一次）。
func _choose(id: int) -> void:
	var sid: String = String(ASSIGNED.get(id, ""))
	if sid.is_empty():
		return                      # 空格子：不关圆盘（按需求只有选中术法才关）
	close()
	spell_chosen.emit(sid)


# ==================== 绘制（全部手工 _draw） ====================
# ---------------------------------------------------------------- 绘制
## 圆盘的全部绘制入口（WheelArea 的 draw 信号 -> 这里，由 _ready 用 bind 绑上要画的 Control）。
## 参数 c：要绘制的 Control（= WheelArea）。所有坐标都是它的局部坐标。
## 返回值：无。
## 副作用：只在 c 上产生绘图命令；不改状态、不发信号、不增删节点。
## 调用时机：由 queue_redraw() 触发（_process 每帧一次；鼠标悬停变化时也一次），
##   且只有 _open 为真时才真正画东西。
## 绘制顺序（后画的盖住先画的）：
##   ① 全屏半透明黑遮罩 -> ② 四层环带（每格一个扇区：空格暗灰 / 有术法橙色 + 描边 + 名字）
##   -> ③ 中心圆盘与描边 -> ④ 中心提示文案。
## 注意：
##   · 每帧重建全部多边形（4 层共 42 格，每格 2*22 个顶点），这是为"只在圆盘打开时才跑"付出的
##     可接受开销；圆盘关闭后 _process 停掉，不要再从别处频繁 queue_redraw。
##   · 配色是内联的常量（不读主题），改风格直接改这里的 Color；深浅以"能看清 13px 白字"为准。
func _on_draw(c: Control) -> void:
	# 关着就什么都不画：queue_redraw 也可能来自 _process 之外的调用，这里再兜一层。
	if not _open:
		return
	# 字体懒加载：第一次绘制时才取 fallback 字体，之后一直复用（null 就是"还没取"的哨兵）。
	if _font == null:
		_font = ThemeDB.fallback_font
	# 圆心每帧现算：窗口尺寸变了会自动跟着走，不需要监听 resize 事件。
	var center := _center(c)
	# 全屏半透明黑（深蓝黑 + alpha 0.55）：压暗场景让圆盘成为焦点。
	# 拦鼠标靠的是 WheelArea 的 MOUSE_FILTER_STOP，不靠这个矩形（矩形本身不参与命中）。
	# 背景遮罩
	c.draw_rect(Rect2(Vector2.ZERO, c.size), Color(0.02, 0.03, 0.05, 0.55))
	# 由内向外、逐层逐格画扇区；每格的几何与命中判定共用 _ring_bounds / RING_COUNTS。
	for i in range(RING_COUNTS.size()):
		var b := _ring_bounds(i)
		var n: int = RING_COUNTS[i]
		var step := TAU / float(n)
		# k = 格号（0 = 正上方，顺时针递增）；槽位键 = 层*1000 + 格，与 ASSIGNED 的键域完全一致。
		for k in range(n):
			var id := i * 1000 + k
			# 是否已分配术法：只影响配色与是否写名字，**不影响命中**（空格子照样能被点中，只是选了不生效）。
			var filled := ASSIGNED.has(id)
			# 本格起始弧度：-PI/2 是正上方，k 越大越顺时针 —— 必须与 slot_at 的角度约定一致。
			var a0 := -PI * 0.5 + float(k) * step
			# 两侧各内缩 0.012 弧度，画出格子间的可见缝。这是**纯视觉**偏差：命中判定按整格 step 算，
			# 不含这条缝，所以贴着缝点击会落到相邻格（有意接受的偏差，换来的是格子边界清楚）。
			var pts := _sector(center, b.x, b.y, a0 + 0.012, a0 + step - 0.012)
			# 基础配色：空格 = 暗灰蓝（表示"这里没东西"），有术法 = 橙色（与火焰系配色统一）。
			var col := Color(0.16, 0.18, 0.24, 0.82) if not filled else Color(0.75, 0.34, 0.10, 0.92)
			# 悬停加亮：有术法的格子加得多（明确"可点"），空格子只轻微加亮（暗示"点了也没用"）。
			if id == _hover:
				col = col.lightened(0.28) if filled else col.lightened(0.12)
			c.draw_colored_polygon(pts, col)
			# 描边色：默认淡蓝灰；有术法的格子换成暖金色，让可选项一眼可辨。
			var lc := Color(0.62, 0.68, 0.78, 0.55)
			if filled:
				lc = Color(1.0, 0.9, 0.6, 0.95)
			# draw_polyline 不会自动闭合，末尾补回首点 pts[0] 才能把环带的外沿与内沿连起来描边。
			c.draw_polyline(pts + PackedVector2Array([pts[0]]), lc, 1.5)
			# 说明：下面代码里的实际条件就是 filled（只给有术法的格子写字）；第 1 圈的 6 格
			# 在 ASSIGNED 里已全部占用，所以"最内层"也全是 filled，两句描述在这个前提下等价。
			# 文字（只给有术法的格子和最内层写，避免糊成一片）
			if filled:
				# 文字锚点 = 扇区角平分线 + 半径中点，正是 slot_at 认定的"格中心"。
				var mid := a0 + step * 0.5
				var rr := (b.x + b.y) * 0.5
				var p := center + Vector2(cos(mid), sin(mid)) * rr
				# 优先取中文名，未登记则退回显示 id 原文（便于一眼发现漏登记）；
				# SPELL_NAMES 的 value 是 Variant，取用必须 String(...) 转一次。
				var txt: String = String(SPELL_NAMES.get(String(ASSIGNED[id]), String(ASSIGNED[id])))
				# 先量出文字尺寸，后面才能做水平居中。
				var sz := _font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
				# 居中修正：横向减去半宽；纵向只扣约 1/4 字高 —— draw_string 的 y 是基线不是顶边。
				c.draw_string(_font, p - Vector2(sz.x * 0.5, -sz.y * 0.25), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.98))
	# 中心与提示
	# 中心圆盘：半径取"最内圈内半径 - 8"，留出 8px 视觉缝，让中心明确是一个标题区而不是第 0 层。
	c.draw_circle(center, RING_INNER - 8.0, Color(0.08, 0.09, 0.13, 0.92))
	# 64 段折线近似画出整圆描边（_draw 没有现成的"圆环描边"API，只能自己补一圈）。
	c.draw_arc(center, RING_INNER - 8.0, 0.0, TAU, 64, Color(0.5, 0.56, 0.66, 0.6), 1.5)
	# 提示文案优先级：悬停格（有术法 -> 名字 / 空格 -> "空"）> 打开后 3 秒的引导 > 默认提示。
	var tip := "点击选择术法 ｜ 空格子暂未开放"
	# 悬停优先：鼠标指向哪格就报哪格（_hover 由 _on_gui_input 更新，-1 = 没悬停在任何格子）。
	if _hover >= 0:
		var sid2: String = String(ASSIGNED.get(_hover, ""))
		if not sid2.is_empty():
			tip = String(SPELL_NAMES.get(sid2, sid2))
		else:
			# 键的整除 / 取模就是层号与格号；两处 +1 是换成人类习惯的 1 起计数（"第 1 层" = 最内圈）。
			tip = "%d 层第 %d 格：空" % [_hover / 1000 + 1, _hover % 1000 + 1]
	# 刚打开的前 3 秒给一次"哪一圈有什么"的引导文案（_t 由 _process 累加，open() 时清零）。
	elif _t < 3.0:
		tip = "第 1 圈已满（6 格）｜第 2 圈：流水治疗 / 火焰推进 / 隐身（其余暂空）"
	# 提示文字 15px（比格子里的 13px 略大），同样做水平居中。
	var ts := _font.get_string_size(tip, HORIZONTAL_ALIGNMENT_LEFT, -1, 15)
	c.draw_string(_font, center - Vector2(ts.x * 0.5, -ts.y * 0.25), tip, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(0.9, 0.94, 1.0, 0.95))


## 生成一段"环带扇区"多边形的顶点（供 draw_colored_polygon / draw_polyline 使用）。
## 参数：
##   center 圆心（Control 局部坐标）；r0 内半径；r1 外半径；
##   a0 / a1 起始与结束弧度（a1 > a0，对应屏幕上的顺时针方向）。
## 返回：PackedVector2Array —— 先沿外弧从 a0 走到 a1（steps+1 个点），再沿内弧从 a1 走回 a0（steps+1 个点）。
##   首尾**不重复**：填充由 draw_colored_polygon 自动闭合，描边则由调用方补首点。
## 副作用：无（纯计算，不改状态、不绘制）。
## 调用时机：_on_draw 里每格调一次（4 层共 42 格）。
## 注意：
##   · 22 段是把圆弧离散成折线的精度（每段约 (a1-a0)/22 弧度）：段数少则外沿有棱角，
##     段数多则每帧顶点数与开销上升；在 46~271px 的半径下 22 段肉眼已经够圆。
##   · 顶点顺序（外弧正序 + 内弧逆序）构成不自交的简单多边形，符合 Godot 三角化要求；
##     若把内弧也写成正序，填充会出现残缺/自交。
##   · 本函数不含任何"格子"语义：格间要不要留缝由调用方决定（_on_draw 传的是 a0+0.012 与 a0+step-0.012）。
func _sector(center: Vector2, r0: float, r1: float, a0: float, a1: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	# 圆弧离散精度：每段 = 总弧长的 1/22，取舍见函数注释。
	var steps := 22
	# 第一趟：外弧 a0 -> a1，取半径 r1 上的点。
	for k in range(steps + 1):
		var a := lerpf(a0, a1, float(k) / float(steps))
		pts.append(center + Vector2(cos(a), sin(a)) * r1)
	# 第二趟：内弧 a1 -> a0（**反向**），取半径 r0 上的点 —— 两趟合起来才是"环带"而不是"扇形"。
	for k in range(steps + 1):
		var a2 := lerpf(a1, a0, float(k) / float(steps))
		pts.append(center + Vector2(cos(a2), sin(a2)) * r0)
	# 首尾不重复地返回，是否闭合交给调用方（描边需要自己补 pts[0]）。
	return pts
# ==============================================================================
# vitals_hud.gd —— 左下角角色量表 HUD（血量 / 魔法值 / 精力值 / 舒适度）
# ==============================================================================
# 【所属系统】UI 层（scripts/ui/），但**不是场景节点**：project.godot 的 [autoload] 段把它
#   注册成自动加载单例 VitalsHud="*res://scripts/ui/vitals_hud.gd"（project.godot 第 76 行），
#   所以游戏一启动它就存在，自己 new 出全部节点，不依赖任何 .tscn。
#   本文件**没有 class_name**，外部拿到的静态类型就是节点自身（CanvasLayer）；
#   全局访问只有两条路：`/root/VitalsHud` 或自动加载名 VitalsHud。
#   （静态检索确认：全项目除 project.godot 与本文件外，没有任何脚本引用 VitalsHud ——
#     main.gd 第 15 行只在注释里列了它的名字。也就是说它目前既没有对外调用方，
#     也没有任何地方能关掉/隐藏它。）
#
# 【职责】在屏幕左下角紧贴小地图右侧画一个面板，四行，每行 = 中文标题 +
#   右对齐的"当前值 / 上限"文本 + 一条细进度条。
#   本文件只负责**显示**：不产生、不消耗任何数值，也不参与任何游戏逻辑。
#
# 【关键依赖】
#   · 数据源（全部是已有系统，本文件不新建一套数值）
#       /root/Vitals（scripts/vitals.gd，自动加载）
#         信号 changed(stat, cur, max) / emptied(stat) / refilled(stat)
#         只读方法 current(stat) / maximum(stat)，枚举 Vitals.Stat{HP, STAMINA, COMFORT}
#         -> 负责"血量 / 精力值 / 舒适度"三行
#       /root/Mana（scripts/spells/mana.gd，自动加载）
#         信号 changed(current, maximum) / emptied() / refilled()
#         只读属性 current / max_mana（单值系统，没有 Stat 枚举）
#         -> 负责"魔法值"一行
#   · 布局基准：preload("res://scripts/ui/minimap.gd") **只为借它的两个常量**：
#       MARGIN   = 14.0 （小地图到屏幕左/下边的距离，px）
#       MAP_SIZE = 120  （小地图边长，px）
#     面板位置与尺寸完全由这两个常量推出，不是写死的像素（见 _build 的位置算法）。
#   · 配色：硬编码在下面的 COLORS 里，深墨绿底 + 金边与小地图（minimap.gd 的 StyleBoxFlat）
#     是同一套，目的是"看起来像同一个 UI"。
#
# 【主要对外接口】本文件**没有公开方法**（函数全部列在下面，_ 前缀是私有约定）：
#   · 引擎回调：_ready() / _process(delta)
#   · 可读写的成员：margin、map_size（普通 var，不是 const、也不是 @export；
#     因为它是 autoload 节点、Inspector 里看不到）。别的脚本理论上可以改它们，
#     但 _build() 只在 _ready 跑一次 -> 运行中改这两个值**不会**重排 UI（推测）。
#   · 节点名约定：面板节点名为 "VitalsPanel"（方便在调试器里找）。
#
# 【已知的坑与注意事项】
#   1. 重复调用 _build() / _bind() **没有幂等保护**：会再叠一层面板，并把信号再连一遍
#      （一次 changed 触发两次刷新）。它们只应由 _ready() 各调用一次。
#   2. 面板位置假设"小地图锚在屏幕左下角"。若把小地图挪到别的角（改 minimap.gd 的
#      锚点/偏移），本文件不会跟着走，两者会重叠或错位。
#   3. 层次假设小地图是 CanvasLayer.layer = 2（minimap.gd::setup() 里设置），
#      本文件在 _ready 里把自己设成 3 以便盖在上面；改小地图层次时要一起看一眼。
#   4. autoload 顺序是有意义的：project.godot 里 Mana(第 73 行) -> Vitals(第 75 行) ->
#      VitalsHud(第 76 行)，所以本节点 _ready() 时两个数据源**已经**初始化完毕，
#      _refresh() 首次读到的是已初始化的满值，不会出现"开局空条"。
#   5. 数据源缺失**不会报错**：get_node_or_null() 返回 null 时对应行停在初始的 "—" 与空条
#      （单独跑本文件的空场景就是这个表现），这是有意做的容错。
#   6. 刷新采用"信号置脏 + _process 里 50ms 节流"，且 _timer 在"不脏"期间**不归零**
#      —— 单次变化的响应其实是"下一帧立刻刷新"，详见 _process 的文档。
#   7. 本文件不 emit 任何信号、不写文件；副作用只有建节点，以及改 Label.text 与
#      ProgressBar.value。
#   8. process_mode 被设成 ALWAYS：游戏暂停时 _process 照跑（此时数值本就不变，只是空转
#      一遍计时），与 Mana._ready / Vitals._ready 的处理保持一致。
#   9. 截图开关 --no-ui 只隐藏 main.gd 里的 ui 与 _minimap（main.gd 第 516-517 行），
#      **没有**隐藏这个 autoload（推测：所以 --no-ui 的验收截图里这块量表仍然可见）。
#  10. 进度条只表达"比例"，精确数值在右侧文本里；量程固定为 BAR_STEPS=1000 个整数刻度，
#      见 _set_bar()。
# ==============================================================================
extends CanvasLayer
## 左下角量表：血量 / 魔法值 / 精力值 / 舒适度，紧贴**小地图右侧**。
##
## 为什么做成自动加载 + 运行时建 UI：
##   小地图是 main.tscn 里的节点（main.gd: @onready var _minimap = $Minimap），
##   但那个场景很大，为一个 HUD 去改它不合适；本项目也已有先例——
##   SpellCaster（自动加载）就是在运行时自己建法术圆盘的。
##
## 位置**按小地图脚本里的常量算**，不是写死数字：
##   小地图矩形 = x:[MARGIN, MARGIN+MAP_SIZE]，高度 MAP_SIZE，左下角对齐
##   量表贴在它右边 GAP 处，上下与小地图齐平
## 以后小地图改尺寸/边距，量表自动跟着走。
##
## 数据来源全部是**已有系统**：
##   魔法值 -> Mana  (scripts/spells/mana.gd)
##   其余三项 -> Vitals (scripts/vitals.gd)
## 刷新走"信号置脏 + 50ms 节流"，避免每帧给中文 Label 重新 shaping（小地图那边也有同款考量）。

# ==================== 段 1：依赖与小地图布局基准 ====================
## 只为拿小地图的两个常量（MARGIN / MAP_SIZE）而 preload 它的脚本，**不实例化、不调用它**。
## 用 preload（编译期解析）而不是 load：路径写错时是加载期报错，而不是运行到 _ready 才发现。
## 注意：preload 一个 CanvasLayer 脚本不会建节点，也不会把 minimap.gd 的 _process 带进来；
##   但它建立了"本文件依赖 minimap.gd"的耦合 —— 小地图脚本被删/改名，本文件会直接加载失败。
const MinimapScript := preload("res://scripts/ui/minimap.gd")

## 量表与小地图之间的**水平间距**（px）。
## 10.0 的理由：既能让人一眼看出这是两块独立 UI（不粘在一起），又不会离得太远显散。
## 调大：量表整体右移（右边更可能压到别的 HUD/画面）；调到 0：紧贴小地图边框。
## 单位是设计分辨率（1280×720）下的像素，由 offset 直接消费；本项目 stretch 模式是
## canvas_items，整块 2D 画布会随窗口等比缩放，所以这里不需要自己再做分辨率适配。
const GAP := 10.0        ## 与小地图的水平间距
## 量表面板宽度（px）。
## 150.0 的理由：左边要放下最长标题"舒适度"（11px 字号 3 个汉字），右边还要放下
##   "100 / 100" 这样的数值文本，150px 刚好不挤。
## 调大：右侧数值不会被截断，但面板会盖住更多画面；调小：数值文本可能被压缩/换行。
## 注意：面板高度不在这里定，而是等于 map_size（与小地图上下对齐、等高）。
const WIDTH := 150.0     ## 量表宽度
## 刷新节流间隔（秒）。0.05 = 50ms，即刷新频率上限约 20Hz。
## 为什么不每帧刷：每次给中文 Label 赋文本都要 TextServer 重新做 shaping（小地图那边
##   同款考量、实测这块约 2.2ms/帧），而这几项数值变化很慢（回蓝/精力都是渐变），
##   20Hz 完全够顺滑。小地图同款常量是 MAP_UPDATE_INTERVAL=0.066(≈15Hz)。
## 调大：更省 CPU 但数值看起来会"顿"；调小（甚至 0.0）：接近每帧刷新，更跟手但更费。
## 注意：它约束的是**连续变化**时的刷新周期；单次变化的响应其实是下一帧立刻刷新
##   （因为不脏期间 _timer 只会累加、不会归零，见 _process 文档）。
const REFRESH_INTERVAL := 0.05
## 进度条量程：ProgressBar.max_value 用它，而实际写入的 value = 比例 × BAR_STEPS。
## 取 1000.0（整数刻度）的理由：条只有 7px 高，浮点像素宽度容易在半个像素上来回抖，
##   量化成 1000 步后填充边缘只落在整刻度上（1 步 = 0.1%），视觉更稳。
## 调大：更平滑，但逐渐回到浮点抖动；调小：条会一跳一跳（例如 100 步就是 1% 一格）。
## 注意：它是**固定量程**，与 cur/mx 的真实量级无关 —— 真实数值只影响比例，精确值走文本。
const BAR_STEPS := 1000.0   ## 进度条量程（用整数刻度避免浮点抖动）

## 小地图到屏幕左/下边的距离（px），直接取自 minimap.gd 的常量，不是写死的数字。
## 面板用它做"与小地图对齐"的基准（见 _build 的位置算法），所以小地图改边距时量表自动跟随。
## 它是普通 var 而非 const：理论上外部可以改，但改完**不会**重排 UI
##   （_build 只在 _ready 跑一次，推测：想让它生效只能重启或手动重建）。
## 注意：类型标注 float 是必要的 —— minimap.gd 的 MARGIN 是 14.0（浮点），
##   而 MAP_SIZE 是 120（整型），标成 float 才能在下面直接参与浮点 offset 运算。
var margin: float = MinimapScript.MARGIN
## 小地图边长（px），同样来自 minimap.gd 的常量（MAP_SIZE = 120，整型赋给 float）。
## 面板高度**直接等于它**（上沿齐平、下沿齐平），所以小地图一改尺寸，量表跟着变高。
## 注意：面板宽度是独立的 WIDTH(150)，两者不相等是刻意的 —— 高度必须对齐小地图，
##   宽度只为放下文本。
var map_size: float = MinimapScript.MAP_SIZE

# ==================== 段 2：配色表（与小地图同一套风格） ====================
## 四个行键 -> 该行主色。键是字符串，必须与 _row() 传的 key、_set_bar() 用的键严格一致
##   （三者对不上时表现为"某一行永远不刷新"，或 COLORS[key] 直接抛错）。
## 用字符串键而不是 Vitals.Stat 枚举（推测）：魔法值来自 Mana、Mana 没有 Stat 枚举，
##   用字符串才能让四行共用同一张表和同一套 _row/_set_bar 代码。
## 每行颜色同时用于两处：标题右侧数值 Label 的 font_color，以及该行进度条的 fill。
## 取值风格：hp 红 / mana 蓝 / stamina 绿 / comfort 暖黄，配合深墨绿底 + 金边的面板。
## 注意：Color(r, g, b) 三分量都在 0~1（不是 0~255），改色时别按 255 写。
const COLORS := {
	"hp": Color(0.86, 0.28, 0.28),
	"mana": Color(0.32, 0.56, 0.95),
	"stamina": Color(0.38, 0.78, 0.44),
	"comfort": Color(0.93, 0.73, 0.33),
}

# ==================== 段 3：运行时状态（全部私有） ====================
## 行键（String）-> 该行的 ProgressBar。由 _row() 在 _ready 阶段填满 4 个键，
##   _set_bar() 按 key 取用。没有标泛型类型（Dictionary[String, ProgressBar]），
##   所以取出来是 Variant -> 在 _set_bar 里显式赋给 ProgressBar 变量（Godot 会做类型检查）。
## 注意：键集合 = {"hp","mana","stamina","comfort"}，_refresh() 只写这四个键。
var _bars := {}
## 行键（String）-> 右侧数值 Label（显示 "当前 / 上限"）。同样由 _row() 填满 4 个键。
## 与 _bars 一一对应：_set_bar() 会同时取这两个字典，缺任何一个就静默返回（不画也不写）。
var _values := {}
## "值变过了、需要重画"的脏标记：数据源信号里置 true，_process() 消费后置回 false。
## 初值 true 是刻意的：即使 _ready 里已经手动刷过一次，开局第一帧之后还会再刷一次
##   （多一次自检，代价是一次赋值，无害）。
## 不变量：只有 _bind() 里的 lambda 会置 true，只有 _process() 会置 false。
var _dirty := true
## 刷新计时预算（秒）：每帧累加 delta，够 REFRESH_INTERVAL 才允许重画。
## 注意它不是"距上次刷新的时间"而是"计时预算" —— **不脏的时候不清零**，
##   所以长时间空闲后它会一直增大；这正是"变化后下一帧就能画出来"的原因（见 _process）。
## 只有真正执行刷新时才会被清零。
var _timer := 0.0


# ==================== 段 4：生命周期（_ready） ====================
## 引擎回调：本节点进入场景树时调用一次（autoload 情形下 = 游戏启动阶段，比主场景还早）。
## 参数：无。返回值：无。
## 作用（四步，顺序不能换）：设层次与暂停策略 -> 建 UI -> 绑数据信号 -> 立刻刷新一次。
## 副作用：
##   · 改本节点 layer（默认 1 -> 3）与 process_mode（继承值 -> ALWAYS）；
##   · 在场景树里新建一个 PanelContainer（名为 VitalsPanel）及其全部子节点；
##   · 连接 /root/Vitals 与 /root/Mana 的信号（各挂一个 lambda，只置脏）；
##   · 调 _refresh() 写一遍 4 个 Label.text 与 4 个 ProgressBar.value。
## 调用时机：引擎按 project.godot 里 autoload 的注册顺序自动调用（VitalsHud 排在 Mana、
##   Vitals 之后）；外部**不要**手动调，否则会再建一套 UI、再连一遍信号。
## 注意：
##   · 这里必须晚于 Mana / Vitals 的 _ready（靠 autoload 顺序保证），否则首次 _refresh() 读到的
##     会是数据源尚未初始化的兜底值；
##   · 数据源缺失（例如单独跑一个空场景）时 _bind() 会静默跳过，HUD 仍然被建出来，
##     只是永远停在 "—" 与空条 —— 这是刻意容错，不是 bug。
func _ready() -> void:
	layer = 3                       # 小地图是 2，量表盖在它上面一层
	# 暂停时也继续走 _process：与 Mana._ready / Vitals._ready 的处理保持一致，
	# 避免"暂停 -> 恢复"的瞬间 HUD 与数值脱节（数值在暂停期间本就不变，这里只是统一策略）
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 顺序有讲究：先建节点（填满 _bars/_values）、再绑信号、最后立刻读一次值。
	# 若先 _bind 后 _build，_refresh() 会因为字典还是空的而什么都不画。
	_build()
	# 只在这里绑一次；重复调用会把同一个信号连两遍（一次变化刷新两次）
	_bind()
	# 立刻刷新一次，显示"开局值"：满血满蓝时数据源不会发任何信号，靠信号是等不到首帧画面的
	_refresh()


# ==================== 段 5：UI 构建（运行时建节点，不依赖 .tscn） ====================
# ---------------------------------------------------------------- 建 UI
## 造一个圆角 StyleBoxFlat —— 本文件所有面板/进度条外观都出自这里。
## 参数 color：背景填充色（含 alpha，分量 0~1）。面板用 0.78 透明度，进度条底/填充用 0.9/不透明。
## 参数 radius：四角的圆角半径（px，整数）。面板 8、进度条 3。
##   调大：更圆润；调小到 0：直角（进度条 3px 的圆角在 7px 高的条上看不出明显差别，属于细节）。
## 参数 border：边框宽度（px），默认 0 = **不画边框**。
##   进度条故意用默认 0（推测：底色 + 填充两段颜色已经把"槽"表达清楚了，再加金边会显得脏）。
##   传 > 0 时边框色固定为 Color(0.68, 0.58, 0.34, 0.95)，与小地图（minimap.gd）的
##   边框**完全同色**，这是"看起来像同一套 UI"的关键。
## 返回值：新建的 StyleBoxFlat（**每次调用都新建**，不复用、不缓存：各控件颜色/圆角都不同，
##   共用一份的话以后改某处会连带改到别处）。
## 副作用：无（只 new 一个资源对象，由 add_theme_stylebox_override 持有引用）。
## 调用时机：_build() 给面板调一次；_row() 给每条进度条的 background/fill 各调一次。
## 注意：border 若传 0 或负数都等价于不画边框（下面判的是 border > 0）。
func _stylebox(color: Color, radius: int, border := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	# 边框色写死成金色（小地图用的是同一个值）：改这里就等于同时改两套 UI 的边框色，
	# 想统一调色的话建议同时看 minimap.gd 的 StyleBoxFlat
	if border > 0:
		sb.border_color = Color(0.68, 0.58, 0.34, 0.95)
		sb.set_border_width_all(border)
	return sb


## 建出整个 HUD：一个 PanelContainer + 一个 VBoxContainer + 4 行（每行由 _row 建）。
## 参数：无。返回值：无。
## 位置/尺寸算法（全部由 margin / map_size / GAP / WIDTH 推出，没有魔法数字）：
##   面板锚在屏幕**左下角**（PRESET_BOTTOM_LEFT），于是四个 offset 都相对左下角量：
##     offset_left   = margin + map_size + GAP -> 小地图右沿再右移 GAP
##     offset_right  = offset_left + WIDTH     -> 宽度固定为 WIDTH
##     offset_top    = -(map_size + margin)    -> 往屏幕上方 120+14 = 134px（与小地图上沿齐平）
##     offset_bottom = -margin                 -> 往屏幕上方 14px（与小地图下沿齐平）
##   默认值下：面板左边 144px、宽 150px、高 120px（= 小地图边长）。
## 副作用：add_child(panel) 改场景树；_row() 还会往 _bars / _values 里登记 4 组控件。
## 调用时机：只在 _ready() 里调一次（没有幂等保护）。
## 注意：
##   · 没有"已建过就跳过"的判断，重复调用会在场景里叠出第二个面板（Godot 会把重名节点改成
##     @VitalsPanel@2），两个面板显示同一份数据；
##   · 面板高度被 offset 钉死成 map_size(120)，若以后调大字号/行距/条高导致内容最小高度
##     超过 120，PanelContainer 会被撑破而与小地图不再等高（推测）—— 改样式时请把总高一起算；
##   · 行是写死的 4 项（血量/魔法值/精力值/舒适度），要加第 5 项必须同时改 _refresh()。
func _build() -> void:
	var panel := PanelContainer.new()
	panel.name = "VitalsPanel"
	# 锚点选左下角（而不是左上角/居中）是关键：只有锚在左下角，
	# 下面那四个 offset 才会相对"屏幕左下角"量，窗口拉伸/分辨率变化时贴着左下角不漂
	panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	# 先算"小地图右沿"这个基准值再派生出左右 offset：小地图尺寸/边距一变，这里自动跟着变
	var left := margin + map_size + GAP
	panel.offset_left = left
	panel.offset_right = left + WIDTH
	# 注意符号：锚在左下角时，offset_top/bottom 为"负"才表示往上（bottom 是相对下边界的距离，
	# 所以 -margin 正好让小地图与量表的下沿都离屏幕底边 margin 像素）
	panel.offset_top = -(map_size + margin)     # 与小地图上沿齐平
	panel.offset_bottom = -margin               # 与小地图下沿齐平
	# 配色沿用小地图（深墨绿 + 金边），看起来才像同一套 UI
	var sb := _stylebox(Color(0.09, 0.13, 0.11, 0.78), 8, 2)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	# PanelContainer 的背景/边框/内边距**只认主题项名 "panel"**；
	# content_margin_* 也写在 stylebox 上，由它决定 4 行内容到面板边框的距离（见上面几行）
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)

	var vbox := VBoxContainer.new()
	# 行与行之间留 4px：4 行（标题行 + 7px 条）加行距刚好能塞进 120px 高的面板
	# （推测：这个间距是与 11px 字号、7px 条高一起凑的，余量不大）；
	# 调大会把内容顶出面板高度，因为面板高度由 offset 钉死、不会跟着内容长
	vbox.add_theme_constant_override("separation", 4)
	panel.add_child(vbox)

	# 下面 4 个 key 必须同时满足三处约定：存在于 COLORS、在这里被建出来、在 _refresh() 里被写值。
	# 顺序也是显示顺序（血量/魔法值/精力值/舒适度），改顺序只是视觉变化、不影响数据。
	_row(vbox, "hp", "血量")
	# 魔法值来自 Mana（单值系统，没有 Stat 枚举）；其余三行来自 Vitals（用 Stat 枚举取值）
	_row(vbox, "mana", "魔法值")
	# 精力值由玩家奔跑驱动消耗/恢复（vitals.gd::_tick_stamina），HUD 只是显示
	_row(vbox, "stamina", "精力值")
	# 舒适度由天气系统驱动（vitals.gd::comfort_target 读天气节点 / 分组 weather_system 的 rain/wind/fog）
	_row(vbox, "comfort", "舒适度")


## 建**一行**：上面是"中文标题 + 右对齐数值"的 HBox，下面是细进度条；并把这行登记进字典。
## 参数 parent：挂到哪个父容器下（_build 传的是那个 VBoxContainer）。
##   类型是 Node（不是 Container），实际必须是能 add_child 的节点；传 null 会在这里报错。
## 参数 key：本行的唯一键，**必须**是 COLORS 里已有的 4 个键之一
##   （"hp" / "mana" / "stamina" / "comfort"）。它同时是 _bars、_values 的字典键，
##   _set_bar() 后续全靠它取值：写错（不在 COLORS 里）会在 COLORS[key] 处直接抛错；
##   写成另一个已存在的键则会覆盖前一行的字典项（前一行永远不再刷新）。
## 参数 title：显示在左侧的中文标题（血量 / 魔法值 / 精力值 / 舒适度）。
##   Label 按文本撑宽度，标题越长越挤右边数值的空间（4 个标题长度接近是有意为之）。
## 返回值：无（一行建完就结束，不返回控件；要拿控件用 _bars[key] / _values[key]）。
## 副作用：
##   · 新建并挂上 5 个节点：VBoxContainer(row) / HBoxContainer(head) /
##     Label(nm 标题) / Label(val 数值) / ProgressBar(bar)；
##   · 往 _bars[key] 存进度条、_values[key] 存数值 Label。
## 调用时机：只由 _build() 调 4 次（每个键一次）。
## 注意：
##   · 数值 Label 的初始文字是 "—"（破折号占位），要等第一次 _refresh() 才变成 "cur / max"；
##     只建不刷会看到占位符 —— 猜测是刻意的（比空串好在首帧前不塌宽度，也让"没绑上"一眼可见）；
##   · 字号/条高都是硬编码的小尺寸（11px / 7px）（推测：为了让 4 行能塞进 120px 高、
##     与小地图等高的面板里；汉字 11px 在 1280×720 下仍清晰可读）。
func _row(parent: Node, key: String, title: String) -> void:
	# 刻意不做兜底（不用 COLORS.get(key, 白)）：key 是内部约定，写错就该立刻炸出来，
	# 而不是悄悄画成白色让人以为"颜色没生效"
	var color: Color = COLORS[key]

	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 1)

	var head := HBoxContainer.new()
	var nm := Label.new()
	nm.text = title
	nm.add_theme_font_size_override("font_size", 11)
	# 标题用灰白（而不是行主色）：主色留给右边的数值和进度条，视觉上"标题不动、数值跳色"
	nm.add_theme_color_override("font_color", Color(0.84, 0.87, 0.84))
	head.add_child(nm)

	var val := Label.new()
	# 占位符 "—"：_ready 里随后就会 _refresh() 覆盖它；（推测）写占位符而非空串是为了首帧前
	# 不塌宽度，同时也让"数据源缺失"一眼可见（停在 "—" 就是没绑上/没刷过）
	val.text = "—"
	# 靠右对齐 + 允许横向撑满：这样 "5 / 100" 与 "100 / 100" 位数变化时，
	# 变化的只是文本左边界，右侧数字始终贴在同一列上（否则整行会左右抽动）
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	# 必须让数值 Label 抢走标题剩下的宽度，否则 HBoxContainer 只会按文本自然宽度排，
	# 数值不会贴到右侧（horizontal_alignment=RIGHT 也就无从体现）
	val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val.add_theme_font_size_override("font_size", 11)
	val.add_theme_color_override("font_color", color)
	head.add_child(val)

	var bar := ProgressBar.new()
	# 关掉自带百分比文本：右边已经有 "cur / max" 了，两者叠在同一条上会糊成一团
	bar.show_percentage = false
	# 量程固定 BAR_STEPS(1000)，_set_bar 写进来的就是"比例 × 1000"（见 BAR_STEPS 的说明）
	bar.max_value = BAR_STEPS
	# 宽 0 = 最小宽度不参与计算（由容器横向拉满），高 7px = 细条：
	# 这是"4 行能塞进 120px"的关键，调高会挤掉标题行的高度
	bar.custom_minimum_size = Vector2(0, 7)
	# ProgressBar 的槽与填充分别对应主题项名 "background" / "fill"（不是 "bg" / "bar"）；
	# 槽用近黑色（0.04, 0.06, 0.05，alpha 0.9）压住面板底色，填充用该行主色
	bar.add_theme_stylebox_override("background", _stylebox(Color(0.04, 0.06, 0.05, 0.9), 3))
	bar.add_theme_stylebox_override("fill", _stylebox(color, 3))

	row.add_child(head)
	row.add_child(bar)
	parent.add_child(row)
	# 登记到字典：_set_bar() 只认这两个字典，没有登记 = 那一行永远不刷新
	_bars[key] = bar
	_values[key] = val


# ==================== 段 6：数据绑定（信号 -> 只置脏，不刷新） ====================
# ---------------------------------------------------------------- 绑数据
## 把两个数据源的信号接到"置脏"上 —— 本函数**全部的工作就是把 _dirty 置 true**。
## 参数：无。返回值：无。
## 副作用：在 /root/Vitals 与 /root/Mana 上各 connect 若干个 lambda（匿名函数）。
## 调用时机：只在 _ready() 里调一次（没有幂等保护：重复调用会把同一信号连两遍，
##   之后每次数值变化都会刷新两次，白白多花 CPU）。
## 为什么只置脏、不在这里直接刷新：
##   changed 在回蓝期间**每帧**都发，若在信号回调里刷 Label，等于每帧给中文 Label 赋文本
##   （TextServer 要重新 shaping，小地图那边同款实测约 2.2ms/帧）；统一交给 _process()
##   做 50ms 节流，才能把刷新压到约 20Hz。
## 注意：
##   · 用 get_node_or_null 而不是 $Vitals / get_node：数据源缺失（单元场景里）时不报错，
##     HUD 照常建出来，只是不刷新；
##   · emptied / refilled 也接进来了：它们同样是"值变了"的边缘时刻（回满/抽干时
##     changed 也发，这两个信号属于冗余保险，多置一次脏只是多刷一帧）；
##   · 没有对应的 disconnect：本节点是 autoload、与游戏同生共死，不需要 unbind。
func _bind() -> void:
	# 数据源全是已有系统；用信号置脏，不轮询
	# 参数名用下划线开头表示"刻意不用"：Vitals.changed 的参数是 (stat, cur, max)，
	# 这里只关心"变过了"，具体值等 _process 里统一去读；参数个数写错会直接报错
	var vitals := get_node_or_null("/root/Vitals")
	if vitals != null:
		vitals.changed.connect(func(_s, _c, _m): _dirty = true)
		vitals.emptied.connect(func(_s): _dirty = true)
		vitals.refilled.connect(func(_s): _dirty = true)

	# Mana 的 changed 只有 (current, maximum) 两个参数，所以 lambda 签名与上面那组不同：
	# 这两个信号（Vitals / Mana）名字一样但参数个数不同，抄错个数运行时会直接抛错
	var mana := get_node_or_null("/root/Mana")
	if mana != null:
		mana.changed.connect(func(_c, _m): _dirty = true)
		mana.emptied.connect(func(): _dirty = true)
		mana.refilled.connect(func(): _dirty = true)


# ==================== 段 7：帧驱动与刷新节流 ====================
## 每帧回调：HUD 的"节流刷新"在这里 —— 信号只负责置脏，真正读值集中在本函数。
## 参数 delta：距上一帧的秒数（秒；60fps ≈ 0.0167）。因为本节点 process_mode=ALWAYS，
##   游戏暂停时它也会被调用（此时数值本就不变，等于空转一遍计时，代价可忽略）。
## 返回值：无。
## 副作用：每帧写 _timer；条件满足时写 _timer=0、_dirty=false 并调 _refresh()，
##   进而写 4 个 Label.text 与 4 个 ProgressBar.value。
## 调用时机：引擎每帧自动调用；**不要手动调**（手动调会打乱节流计时）。
## 算法与"为什么这么写"：
##   · _dirty 由数据源信号置 true，含义是"值变过了，需要重画"；
##   · _timer 累加真实时间，只有累计到 REFRESH_INTERVAL(50ms) 才允许重画，
##     于是连续变化（回蓝）时的刷新频率上限 ≈ 20Hz，中文 Label 不必每帧重新 shaping；
##   · **最容易看错的一处**：不脏时这里提前 return，_timer **不归零**，会一直累加。
##     所以"长时间空闲 -> 某值突然变化"时，下一帧必然满足 _timer >= REFRESH_INTERVAL，
##     变化后**最多等 1 帧**就画出来（没有 50ms 延迟）；50ms 上限只在"信号接连不断"
##     （回蓝期间每帧 changed）时才真正起作用 —— 那时 _timer 刚被上一轮刷新清零，
##     下一次要等满 50ms。若在提前 return 之前顺手清零 _timer，单次变化就会迟到最多 50ms。
##   · 条件写成 `not _dirty or _timer < REFRESH_INTERVAL`：不脏时根本不必比较时间，
##     短路求值让最常见的路径（大多数帧都不脏）只做一次布尔取反。
## 注意：
##   · _dirty = false 放在 _refresh() **之前**：先把这一轮的脏标记消化掉，再去读值。
##     这样即使刷新前后数据源又发了新信号（本文件自己不 emit），也会留下新的脏标记
##     让下一帧再刷一次，不会丢更新；
##   · _timer 单调增大不会溢出（GDScript 的 float 是 64 位双精度，跑几小时也只有几千）。
func _process(delta: float) -> void:
	# 无条件累加：不脏的那些帧也要走这一行 —— 正因为它们不清零，_timer 才会攒到很大，
	# 使得"下一次变脏"时下一帧就能立刻刷新（详见上面函数文档里的说明）
	_timer += delta
	# 不脏 -> 直接早退（不碰 _timer）；脏了但还没攒够 50ms -> 也早退，留到下一帧再攒
	if not _dirty or _timer < REFRESH_INTERVAL:
		return
	# 只有真正执行刷新时才清零计时预算（所以 _timer 不是"距上次刷新的时间"）
	_timer = 0.0
	# 先清脏再刷新：把这轮更新"认领"掉；刷新期间若数据源又发信号，会留下新脏标记供下一帧消费
	_dirty = false
	_refresh()


# ==================== 段 8：写条与整表刷新 ====================
## 把某一行的进度条与数值文本一起写掉（本文件**唯一**的写值入口）。
## 参数 key：行键（"hp"/"mana"/"stamina"/"comfort"），用来在 _bars/_values 里查控件；
##   两个字典里都没有这个键时静默返回（不报错），这是为了容错（例如以后少建了一行）。
## 参数 cur：当前值（点，浮点）。**允许小数** —— Mana 与 Vitals 都是 float
##   （回蓝一帧只加约 0.1）；允许越界，会被 clampf 夹到 [0, mx]。
## 参数 mx：上限（点，浮点）。<= 0.0 视为"没有有效上限"：条画 0，文本照实显示
##   （例如 max_mana 被误配成 0 的情况，也不会出现除零 / NaN）。
## 返回值：无。
## 副作用：写 bar.value（范围 0 ~ BAR_STEPS）与 lab.text（形如 "87 / 100"）。
## 调用时机：只由 _refresh() 调，每个键一次；不要在别处直接调（会绕过自动节流）。
## 注意：
##   · 条画的是**比例**（cur/mx），精确数值走右侧文本 —— 两者用的是同一对参数，不会打架；
##   · 文本用 roundi 四舍五入成整数点：回蓝时的零头不显示，所以会出现"条在动、数字没变"，
##     这是正常的，不是没刷新。
func _set_bar(key: String, cur: float, mx: float) -> void:
	# 字典里取出来是 Variant，这里靠显式类型标注做一次类型检查（写错类型会立刻报错）
	var bar: ProgressBar = _bars.get(key)
	var lab: Label = _values.get(key)
	# 兜底：键不存在时 _bars.get / _values.get 返回 null（不是报错）。
	# 注意 bar == null **不代表键不存在**：理论上进度条已被释放(被别的代码 free)也会是 null，
	# 这里一并用静默 return 兜住，避免对一个失效节点赋值
	if bar == null or lab == null:
		return
	# mx <= 0 时直接给 0（而不是做除法）：避免 0/0 或 x/0 得到 NaN/inf，
	# ProgressBar 拿到 NaN 会出现填充渲染异常；正常路径是 clampf 成 0~1 的比例，再乘量程 1000
	bar.value = (0.0 if mx <= 0.0 else clampf(cur / mx, 0.0, 1.0)) * BAR_STEPS
	# roundi 先把浮点四舍五入成整数点，再交给 %d 格式化（%d 只吃整数，不 roundi 会报错）；
	# 于是显示成 "87 / 100" 而不是 "87.3245 / 100" —— 条表达比例、文本表达整数点
	lab.text = "%d / %d" % [roundi(cur), roundi(mx)]


## 读一遍两个数据源，把 4 行全部重画（本文件**唯一的读值地点**）。
## 参数：无。返回值：无。
## 副作用：调 4 次 _set_bar()（写 Label.text 与 ProgressBar.value）。不 emit、不写文件、
##   不改场景树。
## 调用时机：_ready() 末尾一次（画开局值），之后只在 _process() 满足节流条件时被调。
## 注意：
##   · 每次都重新 get_node_or_null 现查数据源，**不缓存**节点引用：autoload 与游戏同生共死、
##     查找成本相对 50ms 一次可以忽略，好处是不必操心初始化顺序、也不会持有失效引用
##     （代价是：本函数不适合高频调用）；
##   · Vitals 没有 class_name，静态类型只能是 Node，所以成员访问全是动态的：
##     枚举写成 vitals.Stat.HP（借实例访问枚举），方法名/属性名写错要到运行时才报错；
##   · Mana 是"单值"系统、没有 Stat 枚举，只能按名字读属性；
##   · 四行里三行来自 Vitals（HP / STAMINA / COMFORT），一行来自 Mana；
##     某个源缺失时（get_node_or_null 返回 null）对应行保持上次的样子（初始为 "—"/空条），
##     其余行照常刷新。
func _refresh() -> void:
	# 三行走 Vitals 的 Stat 枚举：HP / STAMINA / COMFORT 分别对应上面建的三行
	var vitals := get_node_or_null("/root/Vitals")
	if vitals != null:
		_set_bar("hp", vitals.current(vitals.Stat.HP), vitals.maximum(vitals.Stat.HP))
		_set_bar("stamina", vitals.current(vitals.Stat.STAMINA), vitals.maximum(vitals.Stat.STAMINA))
		_set_bar("comfort", vitals.current(vitals.Stat.COMFORT), vitals.maximum(vitals.Stat.COMFORT))

	# Mana 没有 Stat 枚举，只能按属性名动态读：get("current") / get("max_mana")。
	# 显式 float() 是必要的：get() 的返回类型是 Variant，不转换的话下面 clampf/除法
	# 与 %d 格式化都可能踩到"类型不明确"的报错
	var mana := get_node_or_null("/root/Mana")
	if mana != null:
		_set_bar("mana", float(mana.get("current")), float(mana.get("max_mana")))

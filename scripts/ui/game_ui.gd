# ============================================================================
# scripts/ui/game_ui.gd —— 游戏内 UI 层（CanvasLayer）
# ============================================================================
# 【本文件职责】
#   挂在主场景 scenes/main.tscn 里名为 UI 的 CanvasLayer 上（main.gd 用
#   `@onready var ui = $UI` 拿到它）。本文件**只做界面**：造控件、开关面板、刷新文本，
#   不执行任何建造 / 放置 / 法术逻辑 —— 那些在 scripts/main.gd 与各系统脚本里。
#   它提供四块东西：
#     1) 创造列表（B）—— 建造工具按钮（5 列网格）+ 生物质/石材/天气信息
#        （资源与天气原本常驻屏幕右上角，按要求整体挪进了这个面板）；
#     2) 动作面板（K）—— 列出 player.get_action_lib() 的动作，点一行试播；
#     3) 装备面板（F）—— StaffSystem 已拥有法杖的可滚动列表 + 元素筛选 + 装备/空手；
#     4) 零散 HUD —— 底部居中 B/K/H/F 键列、右下角法杖装备格、屏幕中央的家具互动提示。
#
# 【所属系统】
#   表现层（UI），是"输入 → 逻辑 → 显示"链路的最后一环：
#     main.gd（输入与装配）→ Game / StaffSystem / 天气节点（状态）→ 本文件（显示）
#   反向出口只有少数几个：main.set_tool() / main.undo() / main.player.play_action() /
#   StaffSystem.equip() / main.call("_show_staff_hint", …)。
#
# 【关键依赖】
#   · autoload（见 project.godot 的 [autoload]）：
#       Game        —— Game.Tool 枚举、Game.current_tool、Game.biomass / Game.stone、
#                      Game.tool_changed / biomass_changed / stone_changed、Game.get_tool_name()
#       StaffSystem —— 法杖注册表 / 解锁 / 装备（本文件一律用 sys.call("…") 动态调用）
#       Weather     —— 不是 autoload：main.tscn 的 "Weather" 节点（分组 weather_system），
#                      本文件只读 wind / wind_dir，并调用 weather_name()
#   · 外部信号（全部在 setup() 里连接）：
#       Game.tool_changed            → _on_tool_changed（按钮高亮 + tooltip）
#       Game.biomass_changed         → _on_biomass_changed
#       Game.stone_changed           → _on_biomass_changed（石材与生物质共用同一个槽，
#                                      一次把两行文本都刷出来）
#       StaffSystem.equipment_changed → _on_equipment_changed（刷装备格；面板开着才重建列表）
#   · 主场景引用（setup() 注入的 main）：
#       main.set_tool() / main.undo() / main.player(get_action_lib / play_action) /
#       main.camera_rig.ui_override / main.get("_variant_sel")
#       —— 后两者是**跨脚本直接读写属性**，main.gd 里改名不会编译报错，只会静默失效。
#   · 场景：res://scenes/main.tscn（脚本由 .tscn 绑定；本文件**没有 class_name**，
#       所以别处想标注类型只能用 CanvasLayer / Node，写不出 GameUI 这个类型名）。
#
# 【主要对外接口】（被本文件之外调用）
#   · setup(main_node: Node3D) -> void  —— main.gd::_setup_ui() 调一次：注入主场景 + 建界面
#   · close_any_panel() -> bool         —— ESC 的统一入口（返回值 = 这次 ESC 是否被吃掉）
#   · show_interact_hint(text) / clear_interact_hint() —— main.gd 的家具/换杖/天气提示
#   · update_staff_slot() -> void       —— 刷新右下角装备格（当前只在本文件内部调用）
#
# 【已知的坑 / 注意事项】
#   1. **函数名是隐式契约**：main.gd 用 `ui.show_interact_hint(...)` 直接调；
#      `_show_staff_hint` 更是用字符串 `main.call("_show_staff_hint", id)` 调的 ——
#      改名 / 删函数在编译期**不会**报错，只在运行时抛 Invalid call 并中断游戏
#      （历史事故的完整记录见 main.gd 里 _show_staff_hint 上方的注释）。
#   2. **列表重建一律 deferred**：装备列表按钮的 pressed 会经 equipment_changed 绕回来
#      把自己 free 掉，所以 _fill_staff_panel() 只能 call_deferred（详见该函数注释）。
#   3. **绝不再改鼠标捕获模式**：_apply_ui_capture() 只写 camera_rig.ui_override，
#      不再调 set_ui_capture() —— 历史上那样做会让"关掉面板就丢鼠标"（用户实测反馈）。
#   4. 四个面板的开关状态分别记在 _create_visible / _action_visible / _staff_visible /
#      _help_visible 里，它们是**状态真源**；判断"面板开没开"不要读 Control.visible
#      （可见性是被这些布尔量驱动的结果，ESC 的顺序判断、快照回滚都依赖它们）。
#   5. 所有回调都做了判空（main / sys / 各 Label）：setup() 注入之前、场景重载的中间态里
#      这些引用都可能是 null，UI 崩掉会连带整个游戏中断，所以宁可静默跳过。
#   6. 位置分两套：创造/帮助/动作/装备四个面板的位置由 _do_layout_panels() 动态排；
#      键列、装备格、互动提示用固定 preset + offset 写死（改动要走常量，别散落魔数）。
# ============================================================================
extends CanvasLayer
## 游戏 UI：顶部工具栏与提示
# （注：上面这行是**旧描述** —— 曾经顶部常驻一排工具栏；现在顶部什么都不留，
#   工具全部收进 B 呼出的创造列表，面板位置由 _do_layout_panels() 动态排布。）
# ==================== 成员变量（注入引用 / 面板 / 可见性状态） ====================


## 主场景根节点（main.gd 所在的那个节点），由 setup() 注入。
## 用途：转调 main.set_tool() / main.undo()，以及读 main.player、main.camera_rig、
##   main.get("_variant_sel")（后两者是跨脚本直接读属性，不算正式接口）。
## 默认 null：注入发生在 main.gd 的装配阶段（_setup_ui()），
##   在那之前的任何回调都必须先判空 —— 本文件所有用到 main 的地方都判了空。
var main: Node3D
## 创造列表（B 呼出）与帮助面板（H 呼出）
var create_panel: PanelContainer
## 底部键列里的 "B" 按钮（创造列表开关）。pressed → _toggle_create_panel()。
## 它建成时是 toggle_mode（见 _make_key_button），按下态由 _set_create_panel() 回写，
##   不要指望引擎自动跟面板可见性同步。
var create_button: Button
## 帮助面板（H 键切换）：里面只有标题 + 一个显示 HELP_TEXT 的 Label。
## 原来是常驻屏幕底部的操作提示，按用户要求改成"按需查看"。
var help_panel: PanelContainer
## 底部键列里的 "H" 按钮（帮助面板开关），toggle 按下态与 help_panel 同步。
var help_button: Button
## 帮助面板的正文 Label（文本 = HELP_TEXT 常量，字号 11）。
## 保存引用是为了以后能改文案；当前只在 _build_ui() 里赋值一次，别处没有写入。
var help_label: Label
## 创造列表当前是否打开 —— **状态真源**：ESC / B 键 / B 按钮三处入口都读它做判断，
##   不要改用 create_panel.visible 判断（可见性是被它驱动的结果）。
var _create_visible := false
## 打开创建菜单前的工具/变体选择（关闭时回滚）
# ↓ 本变量存的是**工具枚举值**快照；下一个变量存的是**变体选择**快照，两者配套使用。
var _tool_before_create: int = Game.Tool.NONE
## 打开创造菜单时的"分类 → 变体下标"快照（main._variant_sel 的副本）。
## 只在 _set_create_panel(true) 的"从关到开"那一次拍，关闭时经 _restore_tool_variants() 回滚。
## 空字典 = 没拍到（main 为 null 或 main 上没有该字段），此时回滚是空操作。
var _variants_before_create: Dictionary = {}
## 帮助面板当前是否打开（状态真源，理由同 _create_visible）。
var _help_visible := false

# ==================== 通用小部件与常量（键列按钮 / 帮助文案 / 工具按钮表） ====================
## 左侧功能键统一用小尺寸按钮（原来 84x48、字号默认太大）
## 造一个底部键列用的小按钮（B/K/H/F 四个都由它造，保证外观一致）。
##
## 参数：
##   label —— 按钮上的字（单字符键名："B"/"K"/"H"/"F"）。
##   tip   —— tooltip_text，鼠标悬停时的中文说明（"创造列表"/"动作"/…）。
## 返回值：新建的 Button —— **尚未 add_child**，由调用方挂进 KeyBar。
## 副作用：无（只 new 对象、设属性；不进场景树、不连信号）。
## 尺寸说明：36×26 + 字号 12 是"功能键统一小尺寸"要求的结果 ——
##   默认的 84×48 + 默认字号在 1280×720 下太占地方，会盖住画面下沿。
##   （注：上面那行注释写的"左侧"是旧位置，现在这一列在屏幕正下方居中。）
## 注意：toggle_mode = true，按下后会保持"按下"外观；
##   四个按钮的 button_pressed 都由各自的面板开关函数回写，引擎不负责互斥。
func _make_key_button(label: String, tip: String) -> Button:
	var b := Button.new()
	b.text = label
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(36, 26)
	b.add_theme_font_size_override("font_size", 12)
	b.toggle_mode = true
	return b


## 帮助面板（H）里显示的按键说明全文。
## 用 """ 多行字面量：改文案只动这一处，Label 会按 \n 分行显示。
## 注意：这**只是给玩家看的文案**，与实际键位是两套独立的东西 ——
##   本文件真正处理的键只有 B/K/H/F/ESC（见 _unhandled_input），
##   WASD / Shift / Space / C / E / R / Q / V / M / Ctrl+Z 等分别在
##   player.gd、main.gd、camera_rig.gd 里处理。改键位时必须人手同步这段文案，
##   否则面板会写错（编译器不会提醒你）。
const HELP_TEXT := """WASD 移动 · Shift 加速 · Space 跳跃 · C 下降
左键 建造/放置 · 右键 旋转视角（未选工具时按住拖动）
滚轮 缩放视野（未选工具时 75%~200%）/ 换模型（选了工具时）
E 交互（坐/睡/攀爬） · F 装备法杖 · Q 换杖 · V 换天气
M 大地图 · Ctrl+Z 撤销 · ESC 关闭面板 · B/K/H 本面板"""

## 工具枚举值 → 按钮 的正向映射（键 = Game.Tool 的整数值，值 = 创造列表里的 Button）。
## _on_tool_changed() 靠它遍历所有按钮刷新按下态。只由 _build_ui() 填一次，之后只读。
var tool_buttons: Dictionary = {}
## 反向映射：按钮 → 工具枚举值（就是上面 tool_buttons 的反表）。
## 按钮的 pressed 信号只把按钮自己传进来，_on_tool_button_pressed() 靠本表查出对应工具。
var tool_button_map: Dictionary = {}  # button -> tool
## 撤销按钮引用。**历史遗留字段**：撤销按钮已按用户要求从创造列表里去掉
##   （功能保留在 Ctrl+Z，由 main.gd 的输入处理直接调 buildings.undo()）。
## 当前全仓库搜索只有本文件这一处声明 —— **无人赋值、无人使用**；
##   配套的 _on_undo_pressed() 也从未被 connect。清理时两者可一起删，
##   但看到它别误以为"撤销按钮在工作"。
var undo_button: Button
## 创造列表顶行的资源文本（"生物质 x · 石材 y"两行，字号 11、浅绿色）。
## 由 _on_biomass_changed() 刷新；初始文本在 _build_ui() 里写成 "生物质 0 · 石材 0"
## （只是占位，`_process` 不会刷它，靠信号驱动）。
var biomass_label: Label
## 底部键列里的 "K" 按钮（动作面板开关），toggle 按下态与 action_panel 同步。
var action_button: Button           # 动作菜单开关按钮
## 动作面板（K）：一个 300 px 高的滚动列表，每行一个动作按钮（内容在开局建界面时定死）。
## 非常驻面板，打开后位置由 _do_layout_panels() 与其它面板一起横向排布。
var action_panel: PanelContainer    # 动作列表面板
## 动作面板当前是否打开（状态真源，理由同 _create_visible）。
var _action_visible := false
# ---- 装备（法杖）面板：F 呼出，与动作面板同样式同位置、互斥 ----
## 底部键列里的 "F" 按钮（装备法杖面板开关），toggle 按下态与 staff_panel 同步。
## （行尾注释里的"工具栏上"是旧位置 —— 现在 F 与 B/K/H 一起排在屏幕正下方的键列里。）
var staff_button: Button            # 工具栏上的「装备 (F)」开关按钮
## 装备面板本体：标题 + 元素筛选行 + 430 px 高的滚动列表。
## 列表**内容**不在建界面时生成，而是每次打开时由 _fill_staff_panel() 重建。
var staff_panel: PanelContainer     # 已拥有法杖的列表（146 根，可滚动 + 元素筛选）
## 装备面板当前是否打开（状态真源）。
var _staff_visible := false
## 当前元素筛选值：-1 = 全部，>= 0 = StaffSystem 的 Element 枚举值。
## 关面板时**不重置**，所以再打开还是上次那个筛选（玩家视角更连贯）。
var _staff_filter := -1             # 元素筛选：-1 = 全部
## 元素值 → 筛选按钮。这些按钮是 toggle_mode，但 Godot 的 toggle 按钮**不成组、不互斥**，
##   所以 _on_staff_filter() 要手动把其它按钮的 button_pressed 置回 false。
var _staff_filter_buttons: Dictionary = {}   # 元素 -> 筛选按钮（toggle 需手动互斥）
## 法杖列表的容器（ScrollContainer 的子树根）。每次刷新都是"旧行全部 free + 重新建"，
##   所以**不要**缓存它下面的行节点引用（那些对象每次刷新都会换一批）。
var _staff_list: VBoxContainer
## 装备面板标题 Label（"装备 · 法杖…已拥有 x/y 根 · 当前 xxx"），_fill_staff_panel() 里更新。
var _staff_cap: Label
## 屏幕中央偏下的互动提示浮层（"按 E 坐下"之类）。
## 由 main.gd 经 show_interact_hint() / clear_interact_hint() 控制，**不是常驻文字**；
##   默认 visible = false，只有真的靠近可互动家具时才会出现。
var interact_label: Label        # 家具互动提示浮层
## 天气/风力显示 Label。行尾注释里的"右上角"是**旧位置** —— 按要求已挪进创造列表顶行，
##   所以现在只有按 B 打开创造列表时才看得见。内容由 _update_weather_label() 每 0.2 s 刷一次。
var weather_label: Label         # 天气/风力信息（右上角）
## 右下角法杖装备格的外框（PanelContainer，约 172×52 px，贴右/下边各留 14 px）。
## 它是**装备 HUD**（显示当前武器），不是提示文字，所以没有被"去掉常驻文字"的改动波及。
var staff_slot: PanelContainer   # 法杖装备格（右下角，武器单占一格）
## 装备格里的文字 Label（两行：杖名+祝福星号+第几根/总数 / 元素名；空手时是获取提示）。
var staff_slot_label: Label
## 装备格左侧的竖条色块（7×32 px）：拿**元素颜色**当法杖图标（项目里没有法杖贴图图标）。
## 空手时被 _update_staff_slot() 压成灰色 Color(0.32, 0.34, 0.36) 表示"没拿东西"。
var staff_slot_icon: ColorRect
## 天气文本的刷新累加器（单位：秒）。
## _process() 每帧累加，累计到 0.2 s 才真正刷一次文本 ——
##   风力数值本身变化很慢，0.2 s 视觉上完全跟手，却能省掉每帧拼字符串 + Label 重排的开销。
var _weather_accum := 0.0
## ★ 本项目改动：Weather 不再是 autoload，而是 main.tscn 里的场景节点。
##   这里懒加载 + 分组查找（"weather_system"），取不到就整块跳过天气文本。
var _weather: Node = null

## 创造列表里的工具按钮表：每项 = [按钮文案, Game.Tool 枚举值]，数组顺序就是网格里的排布顺序。
## 注意：
##   · **没有"选择"(NONE) 按钮** —— 用户要求去掉；取消选择改由"再点一次当前工具"
##     或 ESC 完成（见 _on_tool_button_pressed() 与 close_any_panel()）。
##   · 文案与 Game.TOOL_NAMES 是**两份独立表**，改名要两处一起改，
##     否则按钮标题与 tooltip 会互相矛盾（game.gd 的 TOOL_NAMES 上也写了同样的提醒）。
##   · Game.Tool 还有 PATH / ERASE 等成员没出现在这里（当前没有按钮入口）。
##     新增工具**追加到本数组末尾**即可，不影响已登记的下标。
##   · 元素是普通 Array（非类型化），所以下面 btn_data[0]/[1] 取值没有静态检查。
const TOOL_BUTTONS := [
	# 不在这里放"选择"按钮（用户要求去掉）。取消选择的功能保留：
	#   * ESC：没打开面板时按一下 = 收起当前工具
	#   * 再点一次"当前已选中"的工具按钮 = 取消选择
	["墙壁", Game.Tool.WALL],
	["塔楼", Game.Tool.TOWER],
	["房屋", Game.Tool.ROOF],
	["抬升", Game.Tool.TERRAIN_RAISE],
	["下陷", Game.Tool.TERRAIN_LOWER],
	["平整", Game.Tool.TERRAIN_FLATTEN],
	["树木", Game.Tool.TREE],
	["花草", Game.Tool.FLOWER],
	["家具", Game.Tool.DECOR],
	["山体", Game.Tool.MOUNTAIN],
]

# ==================== 初始化：setup() 与界面构建 ====================
## 初始化入口：注入主场景引用、把整个界面建出来、连上外部信号。
##
## 参数：main_node —— 主场景根节点（main.gd 所在节点），必须已装配完
##   （player / camera_rig 已就绪），因为本函数末尾会立刻读它们刷状态。
## 返回值：无。
## 副作用（顺序有意义）：
##   ① main = main_node —— 此后各回调才拿得到主场景；
##   ② _build_ui() —— 建出全部控件并 add_child 到本 CanvasLayer；
##   ③ 连接 Game 的 tool_changed / biomass_changed / stone_changed；
##   ④ 手动调一次 _on_tool_changed(Game.current_tool)：Game 的信号**只在赋值时发**，
##      开局没人给 current_tool 赋值 → 不主动调这一下，所有工具按钮都是弹起态
##      （界面上看不出"当前工具是什么"）；
##   ⑤ 连接 StaffSystem.equipment_changed（先 is_connected 判重，避免重复连接导致重复重建）；
##   ⑥ update_staff_slot() 立刻把右下角装备格填上（不依赖信号）。
## 调用时机：main.gd::_setup_ui()（_ready 装配阶段第 6 步），**只调一次**。
##   main.gd 的调用点在 `Game.world = self` 之前，所以这里**不能读 Game.world**（还是 null）。
## 注意：
##   · 用 get_node_or_null 取 StaffSystem 是防御性写法：它是 autoload（正常此时已就绪），
##     但缺了/改名了也不该让整个 UI 崩掉 —— 取不到就跳过连接，靠 _process 兜底刷新装备格。
##   · 本函数不返回成功/失败：注入失败（main_node 为 null）也不会报错，
##     后续所有 main 相关行为都会静默失效。
func setup(main_node: Node3D) -> void:
	main = main_node
	_build_ui()
	Game.tool_changed.connect(_on_tool_changed)
	# 开局同步一次按钮高亮：默认工具是"选择"(NONE)，而信号只在**变化**时发，
	# 不主动调一次的话开局没有任何按钮是按下态。
	_on_tool_changed(Game.current_tool)
	# 装备数据一变就刷新右下角格子与（打开着的）面板
	var sys := get_node_or_null("/root/StaffSystem")
	if sys != null and not sys.is_connected("equipment_changed", _on_equipment_changed):
		sys.connect("equipment_changed", _on_equipment_changed)
	update_staff_slot()

## 一次性把整个 UI 造出来（只在 setup() 里调用一次，之后不再重建）。
##
## 参数：无。返回值：无。
## 副作用：new 出大量 Control 并 add_child 到本 CanvasLayer；把资源/天气/工具/筛选按钮的
##   文本与信号都接好；期间会读 Game / StaffSystem / Weather 的当前值填初始文本。
## 结构（按创建顺序）：
##   ① 创造列表 create_panel（默认隐藏）—— 顶行 [创造 · 生物质/石材 · 天气] + 5 列工具网格；
##   ② 帮助面板 help_panel（默认隐藏）—— 标题 + HELP_TEXT；
##   ③ 底部键列 KeyBar（B/K/H/F，屏幕正下方居中）；
##   ④ 动作面板、装备面板（各自交给 _build_action_panel() / _build_staff_panel()）；
##   ⑤ 右下角法杖装备格（色条 + 文本）；
##   ⑥ 屏幕中央的互动提示浮层 interact_label。
## 注意：
##   · 这里只"造控件 + 接信号"，不做显隐决策 —— 面板显隐一律走各 _toggle_*/_set_* 函数；
##   · 位置分两套：创造/帮助面板用 PRESET_TOP_LEFT，实际位置交给 _do_layout_panels() 动态排；
##     键列、装备格、提示浮层用固定 preset + offset 写死坐标（含魔数，改动时看注释）；
##   · 函数末尾又调了一次 _on_tool_changed()（setup() 里也调过）：保证控件造完的瞬间
##     按钮高亮与创造列表 tooltip 就正确，不必等下一次工具变化。
func _build_ui() -> void:
	# ============================================================
	# 布局：顶部**什么都不留**；底部一排 B / K / H 三个按钮；
	# 建造工具全部收进 B 呼出的"创造列表"里。
	# ============================================================

	# ---- 创造列表（默认隐藏，B 键 / B 按钮呼出，ESC 关闭）----
	create_panel = PanelContainer.new()
	create_panel.name = "CreatePanel"
	create_panel.add_theme_stylebox_override("panel", _panel_style())
	# 位置由 _layout_panels() 动态给，这里只定左上锚点
	# 尺寸标志设成 SHRINK_BEGIN：面板贴合内容的最小尺寸，否则 PanelContainer 会按锚点
	# 区域被拉伸（宽/高变成整屏），后面 _do_layout_panels() 按最小宽度排位也就失去意义。
	create_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	create_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	create_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	create_panel.visible = false
	add_child(create_panel)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 10)
	create_panel.add_child(cv)

	# 资源/天气：原来在右上角（顶部 UI），按用户要求挪进创造列表
	# 这一行里三样东西原本都常驻在屏幕右上角（顶部 UI），现按用户要求整体挪进创造列表：
	# 于是各自的刷新逻辑一行没改，只是换了父节点（代价：不打开 B 就看不到资源与天气）。
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 18)
	cv.add_child(top_row)
	var cap := Label.new()
	cap.text = "创 造"
	cap.add_theme_font_size_override("font_size", 13)
	cap.add_theme_color_override("font_color", Color.WHITE)
	top_row.add_child(cap)
	biomass_label = Label.new()
	biomass_label.text = "生物质 0 · 石材 0"
	biomass_label.add_theme_font_size_override("font_size", 11)
	biomass_label.add_theme_color_override("font_color", Color(0.78, 0.95, 0.62))
	top_row.add_child(biomass_label)
	# 两个信号接到**同一个**槽函数：_on_biomass_changed() 一次把生物质与石材两行都写出来，
	# 所以不必再造一个"石材专用"回调（game.gd 的 stone_changed 注释里也记了这一点）。
	Game.biomass_changed.connect(_on_biomass_changed)
	Game.stone_changed.connect(_on_biomass_changed)
	weather_label = Label.new()
	weather_label.text = "晴朗"
	weather_label.add_theme_font_size_override("font_size", 11)
	weather_label.add_theme_color_override("font_color", Color(0.82, 0.90, 1.0))
	top_row.add_child(weather_label)

	# 工具按钮：每行 5 个
	var grid := GridContainer.new()
	# 5 列 × 80 px ≈ 400 px：正好是创造列表的宽度上限（再宽会盖住游戏画面）。
	# 改列数要连带复核上面的按钮宽度与面板 tooltip 的排版。
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	cv.add_child(grid)
	# 工具按钮统一 80×24、字号 11：5 列 × 80 px ≈ 400 px（加面板内边距刚好不超屏宽）。
	# 按钮文案取自 TOOL_BUTTONS（不是 Game.TOOL_NAMES），两处要一起改。
	# 这里同时登记"正向表 tool_buttons"与"反向表 tool_button_map"：
	#   前者给 _on_tool_changed() 遍历刷新高亮，后者给点击回调反查工具值。
	for btn_data in TOOL_BUTTONS:
		var btn := Button.new()
		btn.text = btn_data[0]
		btn.add_theme_font_size_override("font_size", 11)
		btn.custom_minimum_size = Vector2(80, 24)
		btn.pressed.connect(_on_tool_button_pressed.bind(btn))
		grid.add_child(btn)
		tool_buttons[btn_data[1]] = btn
		tool_button_map[btn] = btn_data[1]

	# 这个 HBox 现在是**空行**：撤销按钮与装备按钮都已从这里移走
	#   （撤销只剩 Ctrl+Z，在 main.gd 里处理；装备挪到下方键列的 F）。
	# 推测：留着不删只是历史遗留（空容器不占尺寸，对布局无影响），要清理可直接删这几行。
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 10)
	cv.add_child(brow)
	# 撤销按钮已按用户要求从菜单里去掉；功能保留在 **Ctrl+Z**（main.gd 里处理）
	# 装备按钮已经挪到左侧键列（F），这里不再重复

	# ---- 帮助面板（H 呼出）：把原来常驻底部的操作提示挪进来按需查看 ----
	help_panel = PanelContainer.new()
	help_panel.name = "HelpPanel"
	help_panel.add_theme_stylebox_override("panel", _panel_style())
	help_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	help_panel.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	help_panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	help_panel.visible = false
	add_child(help_panel)
	var hv := VBoxContainer.new()
	hv.add_theme_constant_override("separation", 6)
	help_panel.add_child(hv)
	var ht := Label.new()
	ht.text = "操作"
	ht.add_theme_font_size_override("font_size", 13)
	hv.add_child(ht)
	help_label = Label.new()
	help_label.text = HELP_TEXT
	help_label.add_theme_font_size_override("font_size", 11)
	hv.add_child(help_label)

	# ---- 快捷键：**屏幕正下方居中，横向 B / K / H / F** ----
	var bar := HBoxContainer.new()
	bar.name = "KeyBar"
	bar.add_theme_constant_override("separation", 8)
	# 键列钉在屏幕正下方居中：offset 是相对"底部中心"锚点的 ——
	#   左右各 88 px（共 176 px，容得下 4 个 36 px 小按钮 + 间距），
	#   上下 -42 ~ -14 即距底边 14~42 px（不被贴底的窗口边缘裁掉，也不至于挡准星）。
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_left = -88
	bar.offset_right = 88
	bar.offset_top = -42
	bar.offset_bottom = -14
	add_child(bar)
	create_button = _make_key_button("B", "创造列表")
	create_button.pressed.connect(_toggle_create_panel)
	bar.add_child(create_button)
	action_button = _make_key_button("K", "动作")
	action_button.pressed.connect(_toggle_action_panel)
	bar.add_child(action_button)
	help_button = _make_key_button("H", "操作说明")
	help_button.pressed.connect(_toggle_help_panel)
	bar.add_child(help_button)
	# F：装备面板 —— 用户要求"把 F 放出来"，所以从创造列表挪到左侧键列
	staff_button = _make_key_button("F", "装备法杖")
	staff_button.pressed.connect(_toggle_staff_panel)
	bar.add_child(staff_button)

	# ---- 待建面板（动作 / 装备）----
	_build_action_panel()
	_build_staff_panel()

	# ---- 法杖装备格（右下角，保留：它是装备 HUD 不是提示文字）----
	staff_slot = PanelContainer.new()
	staff_slot.add_theme_stylebox_override("panel", _panel_style())
	# 装备信息在**右下角**（用户要求）
	# 装备格钉在右下角：横向 -186 ~ -14、纵向 -66 ~ -14，即约 172×52 px、离右/下边各 14 px。
	staff_slot.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	staff_slot.offset_left = -186
	staff_slot.offset_top = -66
	staff_slot.offset_right = -14
	staff_slot.offset_bottom = -14
	# 装备格是纯显示件：设成 MOUSE_FILTER_IGNORE 后鼠标事件穿透过去，
	# 否则这块右下角区域会吃掉点击（放置预览取的是鼠标位置，会表现为"点不动"）。
	staff_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(staff_slot)
	var srow := HBoxContainer.new()
	srow.add_theme_constant_override("separation", 8)
	staff_slot.add_child(srow)
	staff_slot_icon = ColorRect.new()
	staff_slot_icon.custom_minimum_size = Vector2(7, 32)
	staff_slot_icon.color = Color(0.5, 0.5, 0.5)
	srow.add_child(staff_slot_icon)
	staff_slot_label = Label.new()
	staff_slot_label.text = "法杖 · 空"
	staff_slot_label.add_theme_font_size_override("font_size", 11)
	staff_slot_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	srow.add_child(staff_slot_label)

	# ---- 家具互动提示（准星下方的浮层，按 E 交互时才出现）----
	# 这是**上下文提示**，不是常驻文字，保留；用户说要去掉的是常驻的那些。
	# 定位：锚点 CENTER + offset_top 44 → 正好落在准星（屏幕正中心）下方 44~78 px 处，
	# 视线不用离开准星就能看到；加描边 + 深色圆角底是因为它叠在任意亮度的场景上，
	# 纯文字会被背景吃掉（尤其雪地/天空）。
	interact_label = Label.new()
	interact_label.text = ""
	interact_label.visible = false
	interact_label.set_anchors_preset(Control.PRESET_CENTER)
	interact_label.custom_minimum_size = Vector2(300, 34)
	interact_label.offset_left = -150
	interact_label.offset_right = 150
	interact_label.offset_top = 44
	interact_label.offset_bottom = 78
	interact_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	interact_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	interact_label.add_theme_font_size_override("font_size", 12)
	interact_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7))
	interact_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	interact_label.add_theme_constant_override("outline_size", 4)
	# 提示框样式：半透明深绿底 + 金色描边 + 10 px 圆角，做成"浮层卡片"而不是一行裸字，
	# 保证在任何背景（雪地/蓝天/暗处）上都看得清。
	var isb := StyleBoxFlat.new()
	isb.bg_color = Color(0.08, 0.12, 0.10, 0.78)
	isb.border_color = Color(0.72, 0.6, 0.34, 0.95)
	isb.set_border_width_all(2)
	isb.set_corner_radius_all(10)
	interact_label.add_theme_stylebox_override("normal", isb)
	add_child(interact_label)

	_on_tool_changed(Game.current_tool)


## Game.biomass_changed / Game.stone_changed 的公共槽函数。
##
## 参数：_v —— 变化**之后**的余额（float，无单位）。**故意不使用**（下划线前缀）：
##   两个信号各传各的值，但本函数一次要把生物质与石材两行都刷出来，
##   所以直接读 Game.biomass / Game.stone 更省事（也避免两份数据打架）。
## 返回值：无。
## 副作用：写 biomass_label.text（两行文本）。不碰任何游戏状态。
## 调用时机：任何一次 `Game.biomass = …` / `Game.stone = …` 赋值（含 `+=` 回收）。
## 注意：Game 的两个 setter **不做值比较**，赋同一个值也会发信号 → 本函数可能被连续
##   触发多次（余额变化频率很低，目前不做节流）。
func _on_biomass_changed(_v: float) -> void:
	biomass_label.text = "生物质 %.1f\n石材 %.1f" % [Game.biomass, Game.stone]

## 创造列表里任一工具按钮的 pressed 槽（所有工具按钮共用这一个回调，靠 bind 传按钮）。
##
## 参数：btn —— 被按下的按钮（_build_ui() 里 `pressed.connect(_on_tool_button_pressed.bind(btn))`）。
## 返回值：无。
## 副作用：调 main.set_tool() —— 它会写 Game.current_tool（其 setter 发 tool_changed →
##   _on_tool_changed 刷新高亮 + tooltip），并让 main 立刻清掉上一次的半透明预览。
## 特殊语义（替代被移除的"选择"按钮）：
##   **再点一次当前已选中的那个工具 = 取消选择**，即回落到 Game.Tool.NONE；
##   点其它工具则正常切换。这就是下面那个三元表达式的意思。
## 注意：main 为 null（setup 注入前的极端时序）时直接 return —— 不会崩，只是这次点击无效。
func _on_tool_button_pressed(btn: Button) -> void:
	var tool: int = tool_button_map[btn]
	if main == null:
		return
	# 再点一次当前已选中的工具 = 取消选择（替代原来的"选择"按钮）
	main.set_tool(Game.Tool.NONE if Game.current_tool == tool else tool)

## 撤销按钮的槽 —— **历史遗留，当前无人调用**（配套的 undo_button 字段也没人赋值）。
##
## 参数/返回值：无。
## 副作用：main 存在**且**有 undo() 方法时调 main.undo()
##   → 转发 BuildingManager.undo()，回滚最后一批放置物（历史栈在 buildings 里维护）。
## 为什么用 has_method 判一下：main 的静态类型是 Node3D，编译期看不见 undo()，
##   直接用 `main.undo()` 会被静态检查拒绝；这也是"脚本间靠名字约定"的代价。
## 注意：键盘的 Ctrl+Z 路径**不经过本函数** —— main.gd 的输入处理直接调 buildings.undo()。
##   清理死代码时本函数与 undo_button 字段应一起删。
func _on_undo_pressed() -> void:
	if main and main.has_method("undo"):
		main.undo()

## Game.tool_changed 的槽（setup() 与 _build_ui() 里也各主动调一次做开局/建完后的同步）。
##
## 参数：tool —— 新的工具枚举值（Game.Tool 的整数）。信号在**赋值之后**才发出，
##   所以这里读 Game.current_tool 与参数必然是同一个值。
## 返回值：无。
## 副作用：
##   ① 遍历 tool_buttons，只把"当前工具"那个按钮的 button_pressed 置 true，其余全置 false
##      —— 按钮是 toggle_mode，这里相当于手动实现单选；
##   ② 写 create_panel.tooltip_text = "工具名：操作提示"（常驻提示行被去掉后，
##      当前工具的操作说明挂到创造列表的 tooltip 上，按 B 打开时悬停可见）。
## 调用时机：任何 Game.current_tool 赋值；另外上面两处主动调用。
## 注意：
##   · 只有 tool_buttons 里登记过的工具才会被点亮：切换到一个**没有按钮入口**的工具
##     （如 PATH / ERASE，见 TOOL_BUTTONS 的说明）时所有按钮都弹起，
##     且下面的 match 没有对应分支 → tip 保持空串，tooltip 会显示成"小径："这种半截提示（推测属预期）；
##   · create_panel 还没建出来（判空那一行）时不写 tooltip，避免 setup 早期崩溃。
func _on_tool_changed(tool: int) -> void:
	for t in tool_buttons:
		var btn: Button = tool_buttons[t]
		btn.button_pressed = (t == tool)
	# 更新提示
	var tip := ""
	match tool:
		Game.Tool.NONE:
			tip = "不放置任何东西 —— 想建造先从左边点一个工具"
		Game.Tool.WALL:
			tip = "拖拽画出墙壁"
		Game.Tool.TOWER:
			tip = "点击放置塔楼"
		Game.Tool.ROOF:
			tip = "点击放置小屋"
		Game.Tool.TERRAIN_RAISE, Game.Tool.TERRAIN_LOWER, Game.Tool.TERRAIN_FLATTEN:
			tip = "按住涂抹地形"
		Game.Tool.TREE:
			tip = "点击种树"
		Game.Tool.FLOWER:
			tip = "点击种花"
		Game.Tool.DECOR:
			tip = "点击放置家具（桌/椅/床/梯子等）"
		Game.Tool.MOUNTAIN:
			tip = "点击放置山体（悬崖岩块）"
	# 常驻提示文字已按用户要求去掉；当前工具的说明挂在**创造列表**的提示上，
	# 按需查看（B 打开列表时会显示），不再在屏幕上常驻一行字。
	if create_panel != null:
		create_panel.tooltip_text = "%s：%s" % [Game.get_tool_name(), tip]

# ==================== 动作面板（K） ====================
# ---------- 动作菜单（快捷键 K 呼出，游戏内测试动作） ----------

## 构建动作面板：标题 + 一个 300 px 高的滚动列表，每行一个动作按钮。
##
## 参数/返回值：无。
## 副作用：new 出 action_panel 并 add_child 到本 CanvasLayer；从
##   main.player.get_action_lib() 读动作库（每项 [显示名, 动画名, 模式]），
##   为每个动作建一个左对齐按钮，pressed → _on_action_pressed.bind(i)（i 是库下标）。
## 调用时机：_build_ui()，**只调一次** —— 所以动作列表是**开局快照**：
##   运行中动作库若有增减，面板不会跟着变（要重建界面才生效）。
## 注意：
##   · main 或 main.player 为 null 时 lib 保持空数组 → 面板只显示标题行（不崩）；
##   · 位置 Vector2(60, 14) 只是初值，面板打开后由 _do_layout_panels() 覆盖成 (12,12) 起排。
func _build_action_panel() -> void:
	action_panel = PanelContainer.new()
	action_panel.visible = false
	action_panel.position = Vector2(60, 14)
	action_panel.custom_minimum_size = Vector2(150, 0)
	action_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(action_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	action_panel.add_child(vbox)

	var cap := Label.new()
	cap.text = "动作测试（点击播放，再次移动/跳跃恢复）"
	cap.add_theme_font_size_override("font_size", 10)
	cap.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	vbox.add_child(cap)

	var scroll := ScrollContainer.new()
	# 高度写死 300 px（约 14 行）：动作库条目不多，超出的部分靠滚动查看，
	# 而不是让面板随条目数无限变高（那会挡住半个屏幕）。
	scroll.custom_minimum_size = Vector2(0, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	scroll.add_child(list)

	var lib: Array = []
	if main != null and main.player != null:
		lib = main.player.get_action_lib()
	for i in lib.size():
		var entry: Array = lib[i]
		var b := Button.new()
		b.text = entry[0]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 20)
		b.add_theme_font_size_override("font_size", 11)
		b.pressed.connect(_on_action_pressed.bind(i))
		list.add_child(b)

## 造一份面板通用样式：深蓝灰底(0.1,0.13,0.16) + 0.88 不透明度、2 px 描边、8 px 圆角、
## 四边 6 px 内容边距。
##
## 参数：无。返回值：**新建的** StyleBoxFlat（每次调用都新造一份，不是共享资源）。
## 副作用：无（只创建资源对象，不挂到任何控件上）。
## 为什么每次新建：StyleBox 是 Resource，若全文件共用一份，日后想单独调某个面板的颜色
##   就会连带改掉所有面板；代价只是多几个小资源对象（面板数量个位数，无所谓）。
## 调用者：创造 / 帮助 / 动作 / 装备面板 + 右下角装备格，共 5 处，保证外观统一。
func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.13, 0.16, 0.88)
	sb.border_color = Color(0.45, 0.55, 0.5, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	return sb

## K 键 / K 按钮：切换动作面板显隐。
##
## 参数/返回值：无（只做"翻转"，不接收目标状态 —— 因为键位与按钮两条路都调它）。
## 副作用：翻转 _action_visible；同步 action_panel.visible 与 action_button 的按下态；
##   再调 _apply_ui_capture()（把键鼠让给 UI）与 _layout_panels()（重排所有面板）。
## 注意：与装备面板**不互斥** —— 两个都允许同时打开，位置由 _do_layout_panels() 横向排开
##   （历史上是"开一个自动关另一个"，被用户否掉了）。
##   没有 _set_action_panel 这种包装函数，是因为动作面板没有"打开时要重建内容"的需求。
func _toggle_action_panel() -> void:
	_action_visible = not _action_visible
	action_panel.visible = _action_visible
	action_button.button_pressed = _action_visible
	_apply_ui_capture()
	_layout_panels()

## 动作面板里某一行的 pressed 槽。
##
## 参数：index —— 动作在动作库数组里的下标（_build_action_panel() 里 bind 好的，
##   开局固定，不会被列表刷新打乱）。
## 返回值：无。
## 副作用：调 main.player.play_action(index) —— 角色播放该动作动画；
##   "播什么、播多久、怎么恢复移动"全在 player.gd 里，本文件不跟踪动作状态、不做勾选标记。
## 注意：main / main.player 任一为 null 时静默跳过（防御性判空；本面板建好后 player 不会被换）。
func _on_action_pressed(index: int) -> void:
	if main != null and main.player != null:
		main.player.play_action(index)


# ==================== 装备（法杖）面板（F） ====================
# ---------- 装备（法杖）面板 ----------
#
# 法杖是武器、单占一格，但一共 146 根 —— 全用滚轮一根根翻不现实，
# 所以给一个「按元素分组的可滚动列表 + 元素筛选」。样式与动作面板完全一致，
# 位置也一样，两者互斥（同屏只有一个侧边面板）。

## 取法杖系统 autoload（project.godot 里注册名 `StaffSystem` → scripts/staff_system.gd）。
##
## 参数：无。返回值：Node；取不到时返回 **null**（静默，不报错、不打日志）。
## 副作用：无（只查场景树）。
## 为什么用 get_node_or_null + `sys.call("…")` 这一套动态调用（推测是作者的防御性设计）：
##   本文件要用到 StaffSystem 的十几个方法/属性，若直接写 `StaffSystem.equip(id)`，
##   一旦该 autoload 被移除/改名/在测试环境没挂上，本脚本会**整体编译失败** →
##   连界面都建不出来（UI 崩会连带游戏中断）；动态调用则只是"装备功能静默失效"。
## 注意：`sys.call("x")` 是**字符串调用**，方法名拼错编译期不报错、运行时才失败
##   （同类事故见 main.gd 里 _show_staff_hint 的记录）—— 改 staff_system.gd 的
##   公开方法名时，务必全仓库搜索 game_ui.gd，别只依赖 IDE 的引用查找。
func _sys() -> Node:
	return get_node_or_null("/root/StaffSystem")


## 构建装备（法杖）面板：标题 + 元素筛选行 + 430 px 高的可滚动列表。
##
## 参数/返回值：无。
## 副作用：new 出 staff_panel 并 add_child；把 _staff_cap / _staff_list 两个成员引用存下来
##   供 _fill_staff_panel() 使用；向 StaffSystem 查 `element_ids()`（全部元素）并用
##   `element_name()` 造筛选按钮（"全部" + 每个元素各一个）。
## 调用时机：_build_ui()，**只调一次**，所以：
##   · 筛选按钮是**开局快照**（元素种类运行中不会变，够用）；
##   · **法杖列表行不在这里建** —— 每次打开面板时由 _fill_staff_panel() 重建，
##     否则开局就要建 146 行，且数据变了还得单独维护。
## 注意：
##   · sys 为 null 时只建"全部"一个筛选按钮，列表永远是空的（不崩）；
##   · 位置 Vector2(12,74) 只是初值，打开后由 _do_layout_panels() 覆盖；
##   · 列表高度写死 430 px（约 15 行）—— 146 根法杖必须滚动查看，这是设计不是 bug。
func _build_staff_panel() -> void:
	staff_panel = PanelContainer.new()
	staff_panel.visible = false
	staff_panel.position = Vector2(12, 74)
	staff_panel.custom_minimum_size = Vector2(420, 0)
	staff_panel.add_theme_stylebox_override("panel", _panel_style())
	add_child(staff_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	staff_panel.add_child(vbox)

	_staff_cap = Label.new()
	_staff_cap.add_theme_font_size_override("font_size", 13)
	_staff_cap.add_theme_color_override("font_color", Color(0.95, 0.95, 0.9))
	vbox.add_child(_staff_cap)

	# 元素筛选行（全部 + 7 种元素）：146 根一次铺开太长，先按元素收窄
	var sys := _sys()
	var frow := HBoxContainer.new()
	frow.add_theme_constant_override("separation", 3)
	vbox.add_child(frow)
	# element_ids() 只返回 ELEMENT_NAMES 里除 NONE 之外的元素（见 staff_system.gd 注释），
	# 所以顺序是"全部"在最前、后面跟 7 个元素按钮 —— 与 _staff_filter 默认值 -1 正好对应。
	frow.add_child(_filter_button("全部", -1, sys))
	if sys != null:
		for e in sys.call("element_ids"):
			frow.add_child(_filter_button(str(sys.call("element_name", int(e))), int(e), sys))

	var scroll := ScrollContainer.new()
	scroll.name = "StaffScroll"
	scroll.custom_minimum_size = Vector2(0, 430)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	vbox.add_child(scroll)

	_staff_list = VBoxContainer.new()
	_staff_list.name = "StaffList"
	_staff_list.add_theme_constant_override("separation", 2)
	scroll.add_child(_staff_list)


## 造一个元素筛选按钮（"全部" + 每种元素，总数 = 1 + 元素种类）。
##
## 参数：
##   text    —— 按钮文字（元素中文名，如"火"/"冰"；"全部"就是字面量）。
##   element —— 该按钮代表的元素枚举值；**-1 表示"全部"**。
##   sys     —— StaffSystem 引用，仅用来查元素颜色；为 null 时跳过着色（保持默认白字）。
## 返回值：新建的 Button —— **尚未 add_child**，调用方负责挂进筛选行。
## 副作用：写 _staff_filter_buttons[element] = b（记住引用，供手动互斥时遍历）；
##   连 pressed → _on_staff_filter.bind(element)。
## 注意：
##   · toggle_mode = true，但 Godot 的 toggle 按钮**不成组、不自动互斥**（见 _on_staff_filter）；
##   · button_pressed 初值取自当时的 _staff_filter；本函数只在建界面时调用，
##     那时 _staff_filter 必然是初值 -1，即开局只有"全部"是按下态。
func _filter_button(text: String, element: int, sys: Node) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.custom_minimum_size = Vector2(36, 26)
	b.button_pressed = (element == _staff_filter)
	b.add_theme_font_size_override("font_size", 12)
	if element >= 0 and sys != null:
		b.add_theme_color_override("font_color", sys.call("element_color", element))
	b.pressed.connect(_on_staff_filter.bind(element))
	_staff_filter_buttons[element] = b
	return b


## 元素筛选按钮的 pressed 槽：切换筛选并重建列表。
##
## 参数：element —— 目标元素枚举值，**-1 = 全部**（由 _filter_button() bind 进来）。
## 返回值：无。
## 副作用：
##   ① 写 _staff_filter（关掉面板再打开仍保持这次的选择）；
##   ② 手动遍历 _staff_filter_buttons，把其它 toggle 按钮的 button_pressed 置回 false；
##   ③ 调 _fill_staff_panel() 立刻重建列表内容。
## 为什么第 ② 步要手写互斥：引擎的 toggle 按钮不成组，不手动清就会出现"多个同时按下"的
##   假状态（视觉上像多选，实际数据只有 _staff_filter 一个真值）。
## 注意：is_instance_valid 是防御性判空 —— 按钮理论上都还挂在树上，
##   但列表每帧可能被重建，这里不依赖"按钮一定存活"。
func _on_staff_filter(element: int) -> void:
	_staff_filter = element
	# toggle 按钮不会自己互斥，这里手动同步一遍选中态
	for e in _staff_filter_buttons.keys():
		var b: Button = _staff_filter_buttons[e]
		if is_instance_valid(b):
			b.button_pressed = (int(e) == element)
	_fill_staff_panel()


## 重建列表。只在打开时/装备数据变化时调用。
## 注意 `equip()` 是从列表按钮的 pressed 里发出来的，那个信号会经
## `equipment_changed` 绕回来把按钮自己 free 掉 —— 所以重建一律 deferred。
## 按当前筛选**重建**整个法杖列表（旧行全 free，再逐根建新行）。
##
## 参数：无（读 _staff_filter 与 StaffSystem 的实时状态）。返回值：无。
## 副作用：
##   · 清空并重建 _staff_list 的所有子节点；
##   · 写 _staff_cap.text（"装备 · 法杖 已拥有 x/y 根 · 当前 xxx / 当前空手"）；
##   · 向 StaffSystem 查询 owned_list / all_ids / equipped / display_name / element_of /
##     element_color / is_blessed / stone_count；
##   · 每个名字按钮连 pressed → _on_staff_picked.bind(id)（bind 的是**那一行**的 id）。
## 调用时机：打开面板时（_set_staff_panel(true)）与装备变化时
##   （_on_equipment_changed，且仅当面板开着，且用 call_deferred 调）。
## 注意（重点）：
##   · **重建必须 deferred**：equip() 是从列表按钮自己的 pressed 槽里发出的，
##     StaffSystem 会立刻 emit equipment_changed 绕回本文件重建列表 ——
##     若同步执行，就会在处理点击的过程中把"正在派发信号的按钮自己"释放掉（freed instance 报错）；
##   · 第一行固定是"空手（收起法杖）"：空手是合法状态（长老祝福只作用于手上的杖），
##     且它的 disabled 与 equipped 绑定，避免"本来就是空手还再点一次空手"；
##   · 每行拆成 [名字按钮 + 元素/石数标签] 两列：中文长名字 + 元素 + 石数拼成一整条字符串
##     会顶到面板右边缘被裁（实测 "石0" 被切了一半），分两列既不被裁、元素标签还能对齐成一列；
##   · sys 为 null 时直接 return（此时列表已被清空，表现为空面板）。
func _fill_staff_panel() -> void:
	if _staff_list == null:
		return
	# 旧行既 queue_free() 又立刻 remove_child()，两个都要：
	#   只 queue_free 的话节点要等到帧末才真正离开场景树，本次重建期间它们仍在参与布局，
	#   列表会闪一帧"新旧行叠着"（重建很频繁，这个闪就看出来了）。
	for c in _staff_list.get_children():
		c.queue_free()
		_staff_list.remove_child(c)
	var sys := _sys()
	if sys == null:
		return
	var owned: Array = sys.call("owned_list", _staff_filter)
	# owned_list() 不传参 = **全部**已拥有，与上面按筛选取的那一份是两个不同口径：
	# total 用于"已拥有 x/y"的分子，必须不受筛选影响 —— 否则一切换筛选总数就跟着变小，
	# 玩家会以为法杖丢了。
	var total: int = int(sys.call("owned_list").size())
	# all_ids() = 注册表里登记的全部法杖（当前项目共 146 根，与是否解锁无关），只用来当分母。
	var all: int = int(sys.call("all_ids").size())
	# sys.get("equipped") 是**直接读属性**（不是 call 方法）：走 get() 是因为静态类型 Node
	# 看不见 StaffSystem 的字段。空串 "" 表示当前空手。
	var equipped := str(sys.get("equipped"))
	# 标题一次拼好：分子/分母都不受筛选影响，末段按"空手 / 当前某根"二选一。
	_staff_cap.text = "装备 · 法杖（点名字换上，世界内 Q / Shift+滚轮 切换）\n已拥有 %d/%d 根%s" % [
			total, all, "   ·   当前空手" if equipped == "" else
			"   ·   当前 %s" % str(sys.call("display_name", equipped))]
	# 「收起法杖」放在最前面：空手也是一种状态（长老祝福只作用于手上的杖）
	var un := Button.new()
	un.text = "空手（收起法杖）"
	un.alignment = HORIZONTAL_ALIGNMENT_LEFT
	un.custom_minimum_size = Vector2(0, 26)
	# 已经空手时把"空手"这一行禁用：避免再点一次走 equip("") 发无意义的信号与写档。
	un.disabled = equipped == ""
	un.pressed.connect(_on_staff_picked.bind(""))
	_staff_list.add_child(un)
	# 每行 = [名字按钮（自动占满，左对齐）] + [元素 · 长老石 标签（自动靠右）]
	# 不用一整条字符串：中文长名字 + 元素 + 石数拼一起会顶到面板边缘被裁掉
	# （实测 "石0" 被切了一半），分成两列既不会裁，元素标签也能对齐成一列。
	for id in owned:
		var sid := str(id)
		var elem := int(sys.call("element_of", sid))
		var col: Color = sys.call("element_color", elem)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		_staff_list.add_child(row)
		# 名字前缀 "▶ " 标出当前装备的那一根（其它行用等宽空格占位，保证文字左对齐），
		# 名字末尾的 " *" 表示这根被长老祝福过（元素被改写）。
		var b := Button.new()
		b.text = "%s%s%s" % ["▶ " if sid == equipped else "   ",
				str(sys.call("display_name", sid)),
				" *" if bool(sys.call("is_blessed", sid)) else ""]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.custom_minimum_size = Vector2(0, 26)
		b.add_theme_font_size_override("font_size", 13)
		b.add_theme_color_override("font_color", Color(1, 1, 1) if sid == equipped else col)
		b.pressed.connect(_on_staff_picked.bind(sid))
		row.add_child(b)
		var tag := Label.new()
		tag.text = "%s · 石%d" % [str(sys.call("element_name", elem)),
				int(sys.call("stone_count", sid))]
		tag.add_theme_font_size_override("font_size", 12)
		tag.add_theme_color_override("font_color", col)
		tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(tag)


## 装备面板里某一行法杖被点击：换上它（或收起）。
##
## 参数：id —— 法杖 id 字符串；**空串 "" 表示"空手 / 收起法杖"**
##   （列表第一行"空手（收起法杖）"bind 的就是 ""）。
## 返回值：无。
## 副作用：
##   ① sys.call("equip", id) —— 写 StaffSystem.equipped 并发 equipment_changed；
##      本文件随即被回调刷新右下角装备格，面板开着时还会 deferred 重建列表；
##   ② main.call("_show_staff_hint", id) —— **字符串调用**，让主场景弹一条换杖提示。
## 提前返回：点的是当前已装备的那一根时直接 return（省掉一次无意义的信号 + 写档）。
## 注意：`main.call("_show_staff_hint", …)` 是历史事故点 —— 该函数曾被删掉，而字符串调用
##   没被当时的静态检查脚本扫出来，于是点任何一行都抛 Invalid call 并中断游戏（用户实测）。
##   所以在 main.gd 里改名/删函数前，必须**全仓库搜字符串**，不能只靠 IDE 的引用查找。
func _on_staff_picked(id: String) -> void:
	var sys := _sys()
	if sys == null or id == str(sys.get("equipped")):
		return
	sys.call("equip", id)
	if main != null:
		main.call("_show_staff_hint", id)


## StaffSystem.equipment_changed 的槽：装备数据（解锁 / 装备 / 长老石 / 祝福）变了。
##
## 参数/返回值：无。
## 副作用：
##   ① update_staff_slot() —— 右下角装备格无条件刷新；
##   ② **面板开着才** _fill_staff_panel.call_deferred() 重建列表
##      （关着就不必白建一遍，下次打开时 _set_staff_panel() 会自己重建）。
## 调用时机：StaffSystem 的 unlock / unlock_all / equip / unequip / bless / add_stone /
##   读档等每次改动后（staff_system.gd 里各处 emit 了 equipment_changed）。
## 注意：重建用 call_deferred 而不是直接调用，原因见 _fill_staff_panel() 的说明
##   （该信号可能正是在列表按钮自己的 pressed 槽里发出来的，同步重建会把按钮自己 free 掉）。
func _on_equipment_changed() -> void:
	update_staff_slot()
	if _staff_visible:
		_fill_staff_panel.call_deferred()


## F 键 / F 按钮：切换装备面板显隐（只做翻转，真正的状态写入在 _set_staff_panel）。
##
## 参数/返回值：无。副作用：见 _set_staff_panel()。
func _toggle_staff_panel() -> void:
	_set_staff_panel(not _staff_visible)


## 设定装备面板的开关 —— F 键、F 按钮、ESC 以及将来任何"程序化关闭"都走这里。
##
## 参数：on —— true 打开 / false 关闭。
## 返回值：无。
## 副作用：
##   · 写 _staff_visible；
##   · **打开时**先 _fill_staff_panel() 重建一次内容（保证看到的是最新装备数据）；
##   · 同步 staff_panel.visible 与 staff_button 的按下态；
##   · 最后 _apply_ui_capture()（让出键鼠给 UI）+ _layout_panels()（重排所有面板）。
## 注意：关闭时**不重建**列表（省一次上百行的构建）——
##   关着的时候数据变了也没关系：equipment_changed 只在面板开着时重建，
##   下次打开时这里会补上最新状态。
func _set_staff_panel(on: bool) -> void:
	_staff_visible = on
	if on:
		_fill_staff_panel()
	staff_panel.visible = on
	staff_button.button_pressed = on
	_apply_ui_capture()
	_layout_panels()


# ==================== UI 占用与面板横向排布 ====================
## 面板打开时把 rig 的输入让给 UI。
##
## **绝不再改鼠标捕获模式**：俯视角下相机不需要鼠标，光标本来就该一直可见。
## 原来这里在"面板全关"时调用 set_ui_capture(true) 把光标重新捕获隐藏 ——
## 于是按 K 做完动作、面板一关，鼠标就"丢了"（用户实测反馈）。
## 把"当前是否有面板占用界面"告诉相机 rig（写 camera_rig.ui_override 这一个布尔量）。
##
## 参数：无（内部读四个面板的可见性布尔量求或）。返回值：无。
## 副作用：写 main.camera_rig.ui_override —— camera_rig._unhandled_input 开头就是
##   "if ui_override: return"，即 UI 占用期间相机不再抢 ESC / T / F2 与鼠标转视角。
## 调用时机：四个面板的每个开关函数末尾（动作、装备、创造、帮助各一处）。
## 注意：main 或 camera_rig 为 null 时直接 return —— setup() 注入前调用到这里也不会崩。
## 与旧版的关键差别：现在**只写这个布尔量**，不再调 rig.set_ui_capture()（原因见下）。
func _apply_ui_capture() -> void:
	if main == null or main.camera_rig == null:
		return
	var rig: CameraRig = main.camera_rig
	rig.ui_override = _staff_visible or _action_visible or _create_visible or _help_visible


## 动态排布所有打开的菜单：**一行横向排开，互不遮挡**（用户要求）。
##
## 以前是"打开一个就自动关掉另一个"来避免重叠，那样用户想同时看两个面板就不行。
## 现在按最小尺寸依次摆放，谁打开都不会压到别人。
## 请求"重新排布所有已打开的面板"（真正的排布逻辑在 _do_layout_panels）。
##
## 参数/返回值：无。副作用：call_deferred("_do_layout_panels")。
## 为什么必须 deferred：PanelContainer 的最小尺寸要**经过一次布局**才是准的 ——
##   刚 set visible = true 的那一帧里 size 还是 0，若同步读取就会把新面板摆到别人的位置上。
## 调用时机：每个面板开关函数末尾（动作、装备、创造、帮助）。
func _layout_panels() -> void:
	# 等一帧：PanelContainer 的最小尺寸要经过一次布局才是准的
	call_deferred("_do_layout_panels")


## 真正的排布实现：把当前打开的面板从左上角 (12,12) 起**一行横向摆开**，互不遮挡。
##
## 参数/返回值：无。副作用：对每个已打开的面板 reset_size()（回落到最小尺寸）并写 position。
## 排布顺序固定为 创造 → 帮助 → 动作 → 装备（**不是**打开顺序），所以同屏多开时位置稳定：
##   关掉其中一个，后面的面板会整体左移补位，不会留下空洞。
## 常量含义：X0/Y0 = 距屏幕左上角的起始边距 12 px（与装备格/提示的留白风格一致）；
##   GAP = 面板之间的间距 8 px。
## 注意：
##   · 只处理 visible == true 的面板（关着的不占位）；
##   · 面板数量少（最多 4 个）且不做换行/回绕：4 个全开时总宽可能超出屏幕右边缘（已知局限）；
##   · 这是 deferred 的落点，不要直接调用它 —— 统一走 _layout_panels()。
func _do_layout_panels() -> void:
	const X0 := 12.0
	const Y0 := 12.0
	const GAP := 8.0
	var x := X0
	var panels: Array = []
	if _create_visible:
		panels.append(create_panel)
	if _help_visible:
		panels.append(help_panel)
	if _action_visible:
		panels.append(action_panel)
	if _staff_visible:
		panels.append(staff_panel)
	for p in panels:
		if p == null or not p.visible:
			continue
		# reset_size() 不能省：内容变过或被拉伸过的面板，size 可能大于最小尺寸，
		# 不重置的话每开一次就会把后面的面板越推越远（横向累加）。
		(p as Control).reset_size()
		(p as Control).position = Vector2(x, Y0)
		x += (p as Control).size.x + GAP


# ==================== 创造列表开关与状态回滚（B / ESC） ====================
## B：创造列表开关
## B 键 / B 按钮：切换创造列表显隐（只做翻转，真正的状态写入在 _set_create_panel）。
##
## 参数/返回值：无。副作用：见 _set_create_panel()。
func _toggle_create_panel() -> void:
	_set_create_panel(not _create_visible)


## 设定创造列表的开关，并处理"关闭时回滚"这套特殊语义（B 键 / B 按钮 / ESC 共用）。
##
## 参数：on —— true 打开 / false 关闭。
## 返回值：无。
## 副作用（分两支）：
##   打开（on 为 true 且此前是关的）：
##     · 记快照 _tool_before_create = Game.current_tool；
##     · 记快照 _variants_before_create = _tool_variant_snapshot()（main._variant_sel 的副本）；
##   关闭（on 为 false 且 main 非空）：
##     · main.set_tool(_tool_before_create) —— 恢复打开前的工具，同时让 main 清掉半透明预览；
##     · _restore_tool_variants(...) —— 把玩家在菜单里滚轮换过的模型选择退回去；
##   两支共同：写 _create_visible、create_panel.visible、create_button 的按下态，
##   再 _apply_ui_capture() + _layout_panels()。
## 快照的"只在从关到开时记"很关键：否则连续调用会把快照覆盖成当前值，回滚就等于没回滚。
## 回滚语义来自用户要求："关闭创建菜单后，还没放置的物品要销毁、状态恢复到打开之前"。
## 注意：这里**不动** Game.biomass / 建筑数据，只回滚工具选择与模型变体选择。
func _set_create_panel(on: bool) -> void:
	# 打开时记下当前工具与变体选择；关闭时回滚 ——
	# 用户要求"关闭创建菜单后，还没放置的物品要销毁、状态恢复到打开之前"。
	if on and not _create_visible:
		_tool_before_create = Game.current_tool
		_variants_before_create = _tool_variant_snapshot()
	_create_visible = on
	create_panel.visible = on
	create_button.button_pressed = on
	if not on and main != null:
		# 回滚：恢复工具 + 变体选择，并让 main 清掉半透明预览
		main.set_tool(_tool_before_create)
		_restore_tool_variants(_variants_before_create)
	_apply_ui_capture()
	_layout_panels()


## 记下"当前工具 -> 选中的模型变体"，关闭创建菜单时回滚用
## 拍一份 main._variant_sel 的副本（键 = 模型分类名 String，值 = 该分类当前选中的变体下标 int）。
##
## 参数：无。返回值：新字典；main 为空、或 main 上没有 `_variant_sel` 字段时返回**空字典 {}**。
## 副作用：无（duplicate() 出的是浅拷贝；本字典的键值都是 String/int 这类值类型，够用了）。
## 为什么用 `"_variant_sel" in main` 这种字符串判字段：main 的静态类型是 Node3D，
##   编译期看不见该字段，只能靠 in + get() 绕过 —— 这属于**跨脚本读写私有状态**的权宜做法：
##   main.gd 里一旦改了字段名，这里会**静默失效**（永远返回空字典、回滚变成空操作），
##   既不会报错也不会打日志。
func _tool_variant_snapshot() -> Dictionary:
	if main == null or not ("_variant_sel" in main):
		return {}
	return (main.get("_variant_sel") as Dictionary).duplicate()


## 把快照写回 main._variant_sel（关闭创造菜单时恢复玩家原来的模型选择）。
##
## 参数：snap —— _tool_variant_snapshot() 拍下来的那份副本。
## 返回值：无。
## 副作用：**就地清空并改写** main 上那个字典对象 —— main.get(...) 取到的是引用，
##   所以 cur.clear() 会真的改到 main 的状态（这也是本函数不返回新字典、而用"清空重填"的原因：
##   main 里的字段不会被重新赋值，所有持有该字典引用的代码都能看到回滚结果）。
## 提前返回：snap 为空 / main 为空 / main 上没有该字段时不动现有选择。
## 注意：清空后只写回快照里的键 —— 玩家在菜单里新选出来的键会被**丢弃**，这正是回滚的目的。
func _restore_tool_variants(snap: Dictionary) -> void:
	if main == null or snap.is_empty() or not ("_variant_sel" in main):
		return
	var cur: Dictionary = main.get("_variant_sel")
	cur.clear()
	for k in snap:
		cur[k] = snap[k]


# ==================== 帮助面板开关（H） ====================
## H：操作说明开关
## H 键 / H 按钮：切换操作说明面板显隐。
##
## 参数/返回值：无。
## 副作用：翻转 _help_visible；同步 help_panel.visible 与 help_button 的按下态；
##   再 _apply_ui_capture() + _layout_panels()。
## 注意：帮助面板没有"打开时重建内容"的需求（正文就是常量 HELP_TEXT），
##   所以不需要 _set_help_panel 这层包装，直接翻转即可。
func _toggle_help_panel() -> void:
	_help_visible = not _help_visible
	help_panel.visible = _help_visible
	help_button.button_pressed = _help_visible
	_apply_ui_capture()
	_layout_panels()


# ==================== 键盘输入入口（ESC 统一处理 + B/K/H/F） ====================
## ESC：关掉当前打开的任意面板；返回 true 表示这次 ESC 被吃掉了
## ESC 的统一处理：按写死的优先级关掉任意一个打开的面板。
##
## 参数：无。
## 返回值：bool —— true 表示这次 ESC **被本函数消费**（调用方应 set_input_as_handled()，
##   别再让别的脚本处理）；false 表示没有任何面板可关、也没工具可取消。
## 优先级（从上到下，**一次只关一个**）：创造列表 → 动作面板 → 帮助面板 → 装备面板；
##   四个都没开时退化成"取消当前工具"（main.set_tool(Game.Tool.NONE)，
##   替代被移除的"选择"按钮 —— 前提是当前工具不是 NONE）。
## 副作用：见各 _set_*/_toggle_*（都会改可见性、让出或收回 UI 占用、重排面板）；
##   最后一条分支会改 Game.current_tool（其 setter 发 tool_changed）。
## 调用时机：本文件 _unhandled_input 的 ESC 分支；返回 false 时事件会继续传播给
##   camera_rig 的 ESC（切换鼠标捕获），这是有意的兜底行为。
## 注意：
##   · 顺序是**有意写死**的，不是"按打开时间关最后一个" —— 创造列表先关，因为它带着
##     "关闭即回滚工具与预览"的语义，先处理它最不容易让玩家困惑；
##   · camera_rig / settings_menu 也处理 ESC，靠 _unhandled_input 的传播顺序 + 
##     set_input_as_handled 决出胜负（tests/test_settings.gd 里有相关用例）。
func close_any_panel() -> bool:
	if _create_visible:
		_set_create_panel(false)
		return true
	if _action_visible:
		_toggle_action_panel()
		return true
	if _help_visible:
		_toggle_help_panel()
		return true
	if _staff_visible:
		_set_staff_panel(false)
		return true
	# 没有面板打开时：ESC = 取消当前工具（"选择"按钮去掉后功能保留在这里）
	if main != null and Game.current_tool != Game.Tool.NONE:
		main.set_tool(Game.Tool.NONE)
		return true
	return false


## 键位入口：B（创造列表）/ K（动作）/ H（帮助）/ F（装备）/ ESC（关面板或取消工具）。
##
## 参数：event —— 未被 UI 消费的输入事件（被 Control 吃掉的事件不会传到 _unhandled_input）。
## 返回值：无。
## 副作用：调各 _toggle_* 与 close_any_panel()；处理成功时调
##   get_viewport().set_input_as_handled() 把事件**吃掉**，避免同一次按键又被其它脚本
##   响应一遍（camera_rig 与 settings_menu 也在 _unhandled_input 里处理 ESC）。
## 关键写法解释：
##   · `event.pressed and not event.echo` —— 只认"首次按下"，否则长按会每秒触发几十次
##     开关（面板疯狂闪烁）；echo 是操作系统的按键重复事件；
##   · 用 event.keycode（按键盘布局映射后的逻辑键）而不是 physical_keycode，
##     所以换到非 QWERTY 布局时这几个键的**物理位置**会变（已知局限）；
##   · ESC 那一支带 `and close_any_panel()`：返回 false（没东西可关）时**不**吃事件，
##     于是 ESC 继续传播给 camera_rig（它的语义是切换鼠标捕获）。
## 注意：其余操作键（WASD / Shift / Space / C / E / R / Q / V / M / Ctrl+Z）都不在这里，
##   分别在 player.gd、main.gd、camera_rig.gd 里处理；改键位时别忘同步 HELP_TEXT 文案。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_B:
			_toggle_create_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_K:
			_toggle_action_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_H:
			_toggle_help_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F:
			_toggle_staff_panel()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE and close_any_panel():
			get_viewport().set_input_as_handled()

# ==================== 互动提示浮层（供 main.gd 调用） ====================
# ---------- 家具互动提示 ----------

## 显示屏幕中央的互动提示浮层（家具"按 E 坐"、换杖提示、滚轮换模型、天气切换都走这里）。
##
## 参数：text —— 提示文本；可以含 \n（Label 宽度固定 300 px，超长会自动换行）。
## 返回值：无。
## 副作用：写 interact_label.text 并把 visible 置 true。
##   **不管何时隐藏** —— 那是调用方的事（要么由 main.gd 调 clear_interact_hint()，
##   要么被下一条 show_interact_hint() 直接覆盖文本）。
## 调用时机：main.gd 多处（家具互动、_show_staff_hint 换杖、_cycle_variant 换模型、
##   天气切换、缩放提示等）。
## 注意：
##   · interact_label 为 null 时直接 return —— 界面没建好之前 main.gd 也可能调它，
##     不判空会直接崩（这类"字符串调用/跨脚本调用"没有编译期保护）；
##   · 本函数**不带计时**：多条提示之间是"后写覆盖先写"，谁最后调用谁留在屏幕上，
##     真正的节流（_variant_hint_time）在 main.gd 那边。
func show_interact_hint(text: String) -> void:
	if interact_label == null:
		return
	interact_label.text = text
	interact_label.visible = true

## 收起互动提示浮层。
##
## 参数：无。返回值：无。副作用：把 interact_label.visible 置 false（**不改 text**，
##   所以下次显示会直接覆盖，不会残留上一句）。
## 调用时机：main.gd 在"互动对象离开判定范围 / 结束互动"时调用（如 _show_interact_hint 的清理分支）。
## 注意：判空写的是 `if interact_label:` —— 真值判断，节点已被 free 或未入树时都为假，
##   效果与 `!= null` 类似但更宽；与 show_interact_hint() 的写法不统一（无实际影响）。
func clear_interact_hint() -> void:
	if interact_label:
		interact_label.visible = false

# ==================== 法杖装备格 HUD（右下角） ====================
# ---------- 法杖装备格 ----------

## 刷新右下角法杖装备格的显示（色条颜色 + 名称 + 长老石星号 + 第几根/总数 + 元素名）。
##
## 参数：无。返回值：无。
## 副作用：写 staff_slot_label.text 与 staff_slot_icon.color；**不改** StaffSystem 的任何状态。
## 调用时机：setup() 末尾一次、equipment_changed 信号、以及 _process 里每 0.2 s 一次的例行刷新
##   （例行刷新是兜底：万一某次信号漏了/被节流吞了，半秒内也会自己纠正成正确显示）。
## 提前返回：staff_slot_label 为 null（界面未建）或 StaffSystem 取不到时直接 return。
## 数据来源：`sys.get("equipped")` 是当前装备的 id（空串 = 空手）、
##   `owned_list().size()` 是已拥有总数、`owned_index(id)` 是"第几根"（**1 起**，未拥有返回 0）。
## 注意：显示用的是 equipped 这个 id，而不是玩家手里的实际模型 —— 换杖的视觉由 player/held_staff 负责。
##
## 右下角显示当前装备的法杖：元素色条 + 名称 + 元素 + 长老石 + 第几根。
## 空手时色条压暗、文字提示怎么拿杖。
func update_staff_slot() -> void:
	if staff_slot_label == null:
		return
	var sys := _sys()
	if sys == null:
		return
	var id := str(sys.get("equipped"))
	var owned: int = int(sys.call("owned_list").size())
	if id == "":
		# 空手分支：提示分两种 —— 已经有杖就写"按 F 装备"，一根都没有就写"找长老领取"。
		var tip := "按 F 装备" if owned > 0 else "（找长老领取）"
		staff_slot_label.text = "法杖 · 空\n%s" % tip
		staff_slot_icon.color = Color(0.32, 0.34, 0.36)
		return
	var elem := int(sys.get("equipped_element"))
	staff_slot_icon.color = sys.call("element_color", elem)
	# 色条用元素色；祝福（被长老石改写元素）的加一个 "*" 记号，与装备面板列表里的记号一致。
	var bless := "*" if bool(sys.call("is_blessed", id)) else ""
	staff_slot_label.text = "%s%s  %d/%d\n%s" % [
			str(sys.call("display_name", id)), bless,
			int(sys.call("owned_index", id)), owned,
			str(sys.call("element_name", elem))]


# ==================== 天气信息与每帧节流刷新 ====================
# ---------- 天气信息 ----------

## 右上角常驻显示当前天气与风力（风向用箭头表示）
## 刷新天气文本：天气名 + 风力数值 + 风力等级 + 风向箭头（两行）。
##
## 参数：无。返回值：无。副作用：写 weather_label.text。
## 数据源：天气节点（main.tscn 的 "Weather"，分组 weather_system）的 wind（相对强度，约 0~1+）
##   与 wind_dir（Vector2 单位方向，Weather 内部用 cos/sin 推进角度算出，
##   见 weather.gd::_wind_direction_now()）；天气名来自 weather.weather_name()。
## 风力分级阈值（本文件自己定的）：>= 0.85 大风 / >= 0.5 有风 / >= 0.3 轻风 / 其余 微风。
## 风向：取 x/y 分量**绝对值较大的那一个轴**，映射成四向箭头 → ← ↓ ↑，
##   即只表达"大致朝哪边"，不给精确角度（文字写角度反而不好读）。
## 调用时机：_process 里每 0.2 s 一次（由 _weather_accum 节流）。
## 注意：本函数上方的旧注释写"右上角常驻" —— 那是**旧位置**：现在这个 Label 在创造列表顶行，
##   只有按 B 打开创造列表时才看得见（刷新逻辑没变，只是换了父节点）。
func _update_weather_label() -> void:
	if weather_label == null:
		return
	# ★ 本项目改动：天气节点是场景节点，按分组懒查找（不依赖 /root 路径）。
	if _weather == null:
		_weather = get_tree().get_first_node_in_group(&"weather_system")
	if _weather == null:
		return
	var w: float = float(_weather.get("wind"))
	var arrow := "→"
	var d: Vector2 = _weather.get("wind_dir") if _weather.get("wind_dir") is Vector2 else Vector2(1.0, 0.0)
	# 只按"分量绝对值大的那个轴"出四向箭头：风向本身是连续角度，
	# 但屏幕上是一行文字，四向箭头比写角度直观得多（代价是丢失斜向细节，可接受）。
	if absf(d.x) > absf(d.y):
		arrow = "→" if d.x > 0.0 else "←"
	else:
		arrow = "↓" if d.y > 0.0 else "↑"
	var level := "微风"
	if w >= 0.85:
		level = "大风"
	elif w >= 0.5:
		level = "有风"
	elif w >= 0.3:
		level = "轻风"
	var weather_name_str := str(_weather.call("weather_name")) if _weather.has_method("weather_name") else "未知"
	weather_label.text = "%s\n风力 %.2f %s %s" % [weather_name_str, w, level, arrow]


## 每帧回调：节流刷新天气与法杖装备格（本文件唯一的轮询逻辑）。
##
## 参数：delta —— 距上一帧的秒数（float，秒）。
## 返回值：无。
## 副作用：每累计满 0.2 s，调一次 _update_weather_label() 与 update_staff_slot()。
## 为什么用 0.2 s 节流而不是每帧刷：风力与装备都是低频变化的数据，
##   每帧重建两个 Label 的文本（还带字符串格式化）纯属浪费；0.2 s 在视觉上完全跟手。
## 注意：
##   · 不到 0.2 s 就 return —— 绝大多数帧的开销只是加一个 float；
##   · 累加器是**直接清零**（= 0.0）而不是减去 0.2：低帧率下刷新间隔会略长于 0.2 s，
##     但误差每轮都被清掉、不会累积漂移；
##   · 两件事放在同一次节流里刷不是巧合：都只依赖 autoload 的当前值，彼此无顺序要求。
func _process(delta: float) -> void:
	_weather_accum += delta
	if _weather_accum < 0.2:
		return
	_weather_accum = 0.0
	_update_weather_label()
	update_staff_slot()

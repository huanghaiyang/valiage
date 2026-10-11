# ============================================================================
# 【文件头】game_settings.gd —— 设置系统总控（autoload 单例名：GameSettings）
# ============================================================================
# 所属系统：设置系统（全部位于 scripts/settings/）
#   · settings_schema.gd —— 设置项的"真源"：键名 / 类型 / 默认值 / 分类 / todo 标记
#   · settings_store.gd  —— 值的持有与落盘（user://settings.cfg，改动即发 changed 信号）
#   · settings_input.gd  —— 按键绑定的还原与改写（存 input/bindings）
#   · settings_apply.gd  —— 把设置真正应用到引擎（画质 / 音频 / 显示 / 辅助功能）
#   · settings_menu.gd   —— 纯代码构建的设置菜单（CanvasLayer，含 ESC 开关逻辑）
#   · game_settings.gd   —— 本文件：把上面几者串起来的唯一常驻总控
#
# 关键依赖：
#   · project.godot 的 [autoload] 段：GameSettings="*res://scripts/settings/game_settings.gd"
#     带 * 表示单例；因此本脚本被实例化为常驻节点，全局用一个名字访问。
#   · user://settings.cfg —— 玩家设置的持久化文件（由 SettingsStore 读写）
#   · SettingsMenu.make_cjk_theme() —— 静态方法；字幕层复用它做中文字体兜底
#   · @tool：本脚本是编辑器脚本。配合 SettingsApply 内部对 Engine.is_editor_hint()
#     的分支判断，保证在编辑器里不会改到编辑器自己的窗口/显示设置。
#
# 主要对外接口（其它脚本一律通过 GameSettings.<方法> 调用）：
#   · open_menu() / close_menu() / toggle_menu() / is_menu_open()
#   · show_subtitle(text, seconds) / hide_subtitle() / subtitles_enabled()
#   · store —— 直接读设置：GameSettings.store.get_value("audio/music")
#   （注：目前项目内除设置系统自身外尚无调用点，接口是给对话/暂停菜单等预留的。）
#
# 已知的坑与注意事项：
#   · 执行顺序不可调换：必须先 load_bindings（还原 InputMap）再 apply_all。
#     反过来的话，依赖按键的设置有概率读到旧绑定，玩家改了键重开就是错的。
#   · SettingsStore.get_value() 对 schema 之外的键（如 input/bindings）在从未存过时
#     返回 null，不是默认值；这里读设置一律要做判空/兜底。
#   · 字幕层是**懒创建**的：没显示过字幕前 _sub_layer 为 null，
#     外部不要直接访问 _sub_layer / _sub_label（私有成员）。
#   · 本节点是常驻 autoload，生命周期跨场景；缓存的节点引用（_sub_layer）用前必须
#     is_instance_valid() 校验，否则场景重载后可能拿到已释放对象。
# ============================================================================
@tool
extends Node
## 设置总控（自动加载为 GameSettings ✓）
##
## 职责：
##   · 启动时加载设置 → 还原按键绑定 → 应用全部设置 ✓
##   · 创建设置菜单 ✓（ESC 开关）
##   · 提供字幕显示接口 ✓
##
## 用法（任意脚本）：
##   GameSettings.open_menu() / close_menu() / toggle_menu()
##   GameSettings.show_subtitle("你好，旅行者。", 3.0)
##   GameSettings.store.get_value("audio/music")

# ==================== 成员变量与外部依赖 ====================

## 设置值的持有与持久化对象（SettingsStore，RefCounted）。
## 由 _ready() 创建并调用 load_from_disk() 从 user://settings.cfg 读盘。
## 外部读设置的入口：GameSettings.store.get_value("audio/music")。
## 注意：对 schema 之外的键（如 input/bindings）从未存过时返回 null，取值要兜底。
var store: SettingsStore = null

## 设置菜单实例（SettingsMenu，CanvasLayer）。
## 由 _ready() 用代码 new 出来再 add_child，不依赖任何 .tscn 场景文件。
## null = 尚未初始化（_ready 还没跑）；下面所有菜单接口都先判空再转发。
var menu: SettingsMenu = null

# ---- 字幕系统的内部状态（私有，外部不要直接访问）----

## 字幕所在的画布层；**懒创建** —— 第一次真正显示字幕时才建（见 _ensure_subtitle_layer）。
## 之所以不在 _ready 里建：没字幕的游戏流程完全零开销，也少一个常驻 UI 节点。
var _sub_layer: CanvasLayer = null

## 真正承载字幕文本的 Label，挂在 _sub_layer 内部的 MarginContainer 下。
## 与 _sub_layer 同生共死：_sub_layer 为 null 时它必定也是 null。
var _sub_label: Label = null

## 字幕剩余显示时间（秒）。> 0 表示正在倒计时，<= 0 表示当前无字幕；
## _process() 每帧递减它，减到 <= 0 就隐藏字幕层。
## 这里显式写 0.0 而不是 0：GDScript 的 := 按字面量推断类型，
## 写成 0 会把变量推断成 int，与后面 _sub_left -= delta 的浮点运算不符（类型报错）。
var _sub_left := 0.0


# ==================== 初始化（autoload 启动流程） ====================

## autoload 启动时回调一次（@tool 下编辑器载入脚本时也会跑，见文件头说明）。
##
## 做的事，顺序不可随意调换：
##   1) 强制 PROCESS_MODE_ALWAYS —— 暂停中也要能开设置菜单、字幕也要继续倒计时；
##   2) 新建 SettingsStore 并从 user://settings.cfg 读盘（缺失的键保留默认值）；
##   3) 还原按键绑定（必须在第 4 步之前，否则会读到旧 InputMap）；
##   4) 应用全部设置（画质/音频/显示…），并打印一行启动摘要；
##   5) 创建并挂上设置菜单节点（ESC 开关逻辑封装在 SettingsMenu 内部）。
##
## 参数：无。
## 返回值：无。
## 副作用：写 InputMap、改引擎显示与音频设置、向场景树 add_child 菜单节点、
##         向控制台打印一行启动日志。
## 调用时机：引擎自动调用，不要在别处手动调。
func _ready() -> void:
	# 暂停（get_tree().paused）时本节点仍需 _process 计时并响应输入，
	# 否则暂停中打开菜单后字幕会僵住、ESC 也收不到。
	process_mode = Node.PROCESS_MODE_ALWAYS
	store = SettingsStore.new()
	# 读盘。返回值是"实际读到了几项"；文件不存在或损坏时返回 0，
	# 此时 store 里全是 schema 默认值，游戏不会因缺配置文件而崩。
	var loaded := store.load_from_disk()
	# 按键绑定必须在应用设置之前还原 ✓
	var rebound := SettingsInput.load_bindings(store)
	# 应用全部设置。返回 {设置键: 状态字符串}，状态取值：
	# "ok" / "failed" / "editor-skip"（编辑器里故意不碰显示设置）/ "todo"（占位未实现）
	# / "unknown"。注意它**不抛异常**，单项失败只体现为字符串，所以下面才要自己统计。
	var applied := SettingsApply.apply_all(store)
	# 统计仍是占位实现（schema 里标了 todo）的项，仅用于启动日志提示，
	# 不影响已接通的设置项生效；todos 变大只说明还有功能没做完。
	var todos := 0
	for k in applied.keys():
		if String(applied[k]) == "todo":
			todos += 1
	print("[设置] 读入 %d 项 ｜ 还原按键 %d 个 ｜ 已应用 ✓（占位待开发 %d 项）" % [loaded, rebound, todos])

	# 菜单用纯代码 new 而不 preload 场景：避免设置菜单与主场景/编辑器场景耦合，
	# 也保证 autoload 在任何场景（包括没有 UI 的场景）里都能开出菜单。
	menu = SettingsMenu.new()
	menu.name = "SettingsMenu"
	# 把同一个 store 交给菜单：菜单里改动即写盘并广播 changed，两边不各存一份数据。
	menu.store = store
	add_child(menu)


# ==================== 设置菜单开关接口（对外） ====================

## 打开设置菜单。
## 参数：无。返回值：无。
## 副作用：菜单接管输入、显示鼠标、按需暂停游戏，并发出 menu_opened 信号
##         （信号与暂停/鼠标恢复都由 SettingsMenu 自己负责）。
## 调用时机：任意脚本、任意场景，通常由暂停菜单或主菜单的"设置"按钮触发。
## 注意：在 _ready 之前调用（menu == null）是安全的 —— 静默忽略，不会报错。
func open_menu() -> void:
	if menu != null:
		menu.open()


## 关闭设置菜单。与 open_menu() 对称。
## 参数：无。返回值：无。
## 副作用：菜单隐藏、恢复打开前的暂停状态与鼠标模式，并发出 menu_closed 信号。
## 注意：菜单本来就关着时再调也无害；menu == null 时静默忽略。
func close_menu() -> void:
	if menu != null:
		menu.close()


## 开/关切换：开着就关，关着就开。适合直接绑到一个按钮或热键上。
## 参数：无。返回值：无。
## 注意：判断依据是菜单自身的打开状态，不是本节点上的标志位 ——
##       所以即使别处直接调过 menu.open()，这里也能正确反向切换。
func toggle_menu() -> void:
	if menu != null:
		menu.toggle()


## 查询设置菜单当前是否打开。
## 参数：无。
## 返回值：true = 菜单已显示且正接管输入；false = 菜单关闭，或菜单尚未创建。
## 注意：menu == null 一律当作"未打开"，让调用方不必先判空再问。
func is_menu_open() -> bool:
	return menu != null and menu.is_open()


# ==================== 字幕系统 ====================

## ---- 字幕系统 ✓ ----
## 受设置项 language/subtitle 控制 ✓（关掉后直接不显示 ✓）
##
## 查询字幕功能是否开启。读取设置键 language/subtitle（schema 里默认为 true）。
## 参数：无。
## 返回值：true = 允许显示字幕；false = 玩家在设置里关闭了字幕。
## 调用时机：show_subtitle() 内部每次都会问一次，因此设置里改了开关立即生效，
##           不需要缓存、也不需要监听 changed 信号。
## 副作用：无（只读设置）。
func subtitles_enabled() -> bool:
	# store == null 表示设置系统还没初始化：此时按"开启"处理 ——
	# 宁可先显示字幕，也不要因初始化顺序问题让所有对话字幕静默消失。
	return store == null or bool(store.get_value("language/subtitle"))


## 显示一条字幕（对话、旁白、系统提示都可走这里）。
## 参数：
##   text    —— 要显示的文本；可含换行，过长时按词智能折行（AUTOWRAP_WORD_SMART）。
##   seconds —— 显示时长（秒），默认 3.0；传 0 或负数会被抬到 0.5（见函数内注释）。
## 返回值：无。
## 副作用：懒创建字幕层、改写 Label.text、重置 _sub_left 倒计时、把字幕层设为可见。
## 调用时机：任意时刻，典型如对话系统播一句台词。
## 注意：若字幕已被设置项关掉（language/subtitle = false），本函数直接返回，
##       连 UI 节点都不会创建；重复调用会覆盖上一条字幕并重新计时。
func show_subtitle(text: String, seconds := 3.0) -> void:
	if not subtitles_enabled():
		return
	# 懒创建：第一次真正显示字幕时才建 CanvasLayer/Label，无字幕流程零开销。
	_ensure_subtitle_layer()
	# 理论上上一步之后不该为 null，这里只是防御性判空：
	# 万一创建被跳过（如节点被禁用），调用方也不会因为空引用而崩。
	if _sub_label == null:
		return
	_sub_label.text = text
	# 时长下限 0.5 秒：若传 0 或负数，_process 下一帧就会隐藏，
	# 玩家根本来不及看清，等于静默失败，所以强制一个最小可读时长。
	_sub_left = maxf(0.5, seconds)
	_sub_layer.visible = true


## 立即隐藏字幕（不等倒计时自然走完）。
## 参数：无。返回值：无。
## 副作用：把 _sub_left 归零以停止计时，并隐藏字幕层；**不销毁**节点，下次可复用。
## 调用时机：切场景、玩家跳过对话、进入演出等需要立刻清屏的场合。
## 注意：字幕层若还没被创建过，本函数只清零计时器，不做任何 UI 操作。
func hide_subtitle() -> void:
	_sub_left = 0.0
	if _sub_layer != null:
		_sub_layer.visible = false


# ==================== 字幕 UI 构建（懒创建） ====================

## 确保字幕层与字幕 Label 已存在（幂等，重复调用直接返回）。
## 参数：无。返回值：无。
## 副作用：首次调用会 new 出 CanvasLayer + MarginContainer + Label 并 add_child 到本节点，
##         且初始 visible = false（先建好但不显示，等 show_subtitle() 打开）。
## 调用时机：只由 show_subtitle() 内部使用，外部不要直接调。
## 注意：
##   · 存活判断用 is_instance_valid() 而不是简单的 != null —— 本节点是常驻 autoload，
##     场景重载或节点被手动 free 之后，_sub_layer 可能是"已释放但仍非 null"的悬空引用，
##     只查 != null 会漏判，随后访问即报错。
##   · 层级、边距、字号、描边等外观参数都硬编码在本函数里，想调外观改这里，
##     不要从外部去改这些私有节点。
func _ensure_subtitle_layer() -> void:
	if _sub_layer != null and is_instance_valid(_sub_layer):
		return
	# 确认需要重建后才 new，并且下面一路 add_child 到本节点（autoload）名下，
	# 这样字幕不随任何具体场景的卸载而消失。
	_sub_layer = CanvasLayer.new()
	_sub_layer.name = "SubtitleLayer"
	# 层级 90：高于普通游戏 UI（layer 0/1），但**低于**设置菜单的 layer = 100，
	# 于是打开设置菜单时字幕会被菜单遮罩压住，不会浮在菜单之上。
	_sub_layer.layer = 90
	add_child(_sub_layer)
	var box := MarginContainer.new()
	# 底部横条：anchor 贴屏幕底边，于是 offset_top = -140 / offset_bottom = -60
	# 表示字幕落在"距底边 60 ~ 140 px"的带子里，下方留 60 px 给快捷栏/提示条，
	# 避免字幕与它们叠在一起。
	box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	box.offset_top = -140
	box.offset_bottom = -60
	box.add_theme_constant_override("margin_left", 60)
	box.add_theme_constant_override("margin_right", 60)
	box.theme = SettingsMenu.make_cjk_theme()      # 中文兜底 ✓
	_sub_layer.add_child(box)
	_sub_label = Label.new()
	_sub_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_sub_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_sub_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_sub_label.add_theme_font_size_override("font_size", 22)
	_sub_label.add_theme_color_override("font_color", Color(1, 1, 1))
	# 黑描边 + 6 px 描边宽度：字幕会压在任意亮度的画面上（雪地白天 / 夜晚），
	# 纯白字不描边经常看不清，这是成本极低的可读性兜底。
	_sub_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_sub_label.add_theme_constant_override("outline_size", 6)
	box.add_child(_sub_label)
	# 建好先隐藏：字幕只在 show_subtitle() 的时长内可见；
	# 否则空 Label 虽无文字，但可见的层会白白参与绘制与布局。
	_sub_layer.visible = false


# ==================== 字幕计时（每帧） ====================

## 每帧推进字幕倒计时。
## 参数 delta：距上一帧的秒数（引擎传入，受 time_scale 影响；因为本节点
##             process_mode = ALWAYS，暂停中同样会被调用，所以暂停时字幕照样会走完）。
## 返回值：无。
## 副作用：递减 _sub_left；减到 <= 0 时把字幕层隐藏（只隐藏，不销毁节点）。
## 注意：这是常驻 autoload 的每帧回调，所以先做"没有字幕就立刻 return"的早退优化，
##       空转时要尽量便宜；字幕节点的创建不在这里做（那是 _ensure_subtitle_layer 的事）。
func _process(delta: float) -> void:
	if _sub_left <= 0.0:
		return
	_sub_left -= delta
	# 只在"这一帧刚好走完"时才碰 visible：一旦归零，下一帧就被上面的早退拦下，
	# 因此这里实际只执行一次，不会每帧重复写同一个属性触发无谓的重绘。
	if _sub_left <= 0.0 and _sub_layer != null:
		_sub_layer.visible = false
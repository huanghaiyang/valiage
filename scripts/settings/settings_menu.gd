@tool
class_name SettingsMenu
extends CanvasLayer
## 游戏内设置菜单（纯代码构建 ✓ 不依赖 .tscn ✓）
##
## 分类：画质 / 音频 / 语言 / 操作 / 游戏 / 辅助功能 / 关于
## 已能真生效的项即时生效 ✓；标了 todo 的项置灰并显示（待开发）✓
##
## ⚠️ CanvasLayer **没有** visible 属性 ✗ —— 显隐由内部子 Control 控制 ✓

## 【所属系统】设置系统（scripts/settings/），运行时由 autoload `GameSettings` 创建并挂在它下面。
##   同目录协作脚本（本文件全部依赖它们，且**不含**任何 `.tscn` ✓）：
##     · settings_schema.gd （SettingsSchema）→ 设置项定义表：分类 ORDER / 条目 Kind / 默认值 / 步长
##     · settings_store.gd  （SettingsStore） → 值的持有 + user://settings.cfg 持久化（纯逻辑 ✓）
##     · settings_apply.gd  （SettingsApply） → 把值真的写进引擎（音频总线 / 窗口 / MSAA / 阴影 / 画质档）
##     · settings_input.gd  （SettingsInput） → 按键改绑：改 InputMap + 存进 store 的 input/bindings
##     · game_settings.gd   （GameSettings）  → 总控：加载设置、创建本菜单、字幕层、_process 计时
##
## 【主要对外接口】
##   · open() / close() / toggle() / is_open()：开关菜单（GameSettings.open_menu() 等直接转发到这里 ✓）
##   · signal menu_opened / menu_closed：显隐时发出 ✓（外部想联动 HUD/暂停时可监听 ✓）
##   · category_names() -> Array：返回**实际建出来**的分类按钮文字 ✓（测试用，别硬猜 UI 层级 ✗）
##   · static make_cjk_theme() -> Theme：系统 CJK 字体主题 ✓（game_settings.gd 的字幕层也复用它 ✓）
##   · 属性 store：外部（GameSettings / 测试）应在 add_child() 之前注入 ✓，否则本脚本自建一份 ✓
##
## 【已知的坑与注意事项】（每条都有历史依据，改动前务必先读）
##   1. CanvasLayer 没有 visible ✗ → 显隐**只能**靠内部 _root（Control）的 visible ✓
##   2. HSlider 没有 disabled ✗（那是 BaseButton 才有的 ✓）→ 用 editable ✓；
##      写成 sl.disabled = todo 会在打开音频页时当场运行时报错 ✗（已被日志精确定位过 ✓）
##   3. 输入处理必须放 _input（输入链最早一站 ✓），**不能**放 _unhandled_input ✗ ——
##      项目里 camera_rig.gd 与 game_ui.gd 都直接处理 ESC ✓，谁先 set_input_as_handled() 谁赢 ✗；
##      GameSettings 是 autoload → 在场景树里排在主场景之前 ✓，所以这里能抢在它们前面 ✓
##   4. ESC 只在"**可见的**文本输入框（LineEdit/TextEdit）有焦点"时才让路 ✓；
##      早期写成"只要有焦点就让路" ✗ → HUD 上一个残留焦点的按钮就让 ESC 永久失效 ✗（被单测逮住 ✓）
##   5. 打开菜单会**暂停场景树**并改鼠标模式 ✓ → 关闭时必须精确还原 ✓
##      （_saved_pause / _saved_mouse 快照，硬写 false / VISIBLE 会把别人的状态冲掉 ✗）
##   6. 本脚本带 @tool ✓ → 编辑器里**绝不**改暂停 / 鼠标 / 显示设置 ✗（Engine.is_editor_hint() 守卫 ✓），
##      否则会改掉编辑器自己的窗口 ✗
##   7. 切换分类时先 remove_child 再 queue_free ✓ —— 只 queue_free 会让新旧行叠一帧 ✗
##   8. 所有 UI 都是代码构建 ✓：改界面 = 改本文件，改**设置项** = 改 settings_schema.gd ✓（别混）

# ==================== 信号 ====================

## 菜单被打开后发出 ✓（在 _is_open = true、_root.visible = true、可能已暂停场景树之后 ✓）
## 用途：外部按需隐藏 HUD / 停掉自己那套输入 ✓ —— 本脚本不监听自己的信号 ✓
signal menu_opened
## 菜单被关闭后发出 ✓（此时暂停状态与鼠标模式已还原 ✓、store 已落盘 ✓）
signal menu_closed

# ==================== 对外配置与内部状态 ====================

## 是否允许用 ESC 打开/关闭菜单（默认 true ✓，因为 ESC 是玩家最习惯的"设置键"）
## 关掉后：ESC **完全**不再与本菜单交互 ✓（打开与关闭都关掉 ✓），
##   但 open_keys 里的 F10 备用键**依旧可用** ✓ —— 这就是这个开关存在的意义 ✓：
##   给"ESC 要留给别处"的玩法或调试场景留后门，同时不至于把玩家彻底锁在设置外面 ✓。
@export var open_with_escape := true

## _ready() 时默认展开的分类名（"" = 回落到 SettingsSchema.ORDER[0]，即「画质」✓）
## 取值必须是 SettingsSchema 里的分类常量（CAT_GRAPHICS/CAT_AUDIO/... 的字符串值，如 "音频"）；
## 写错或留空都**不会崩** ✓ —— _show_category() 用 table.get(cat, []) 兜底，只会建出一个空页 ✓。
@export var default_category := ""

## 设置值仓库（SettingsStore）。**应在 add_child()/_ready() 之前注入** ✓：
##   · GameSettings 注入全局唯一的那一份 → 菜单与游戏读同一份设置 ✓
##   · 单元测试注入 cfg_path 指向临时目录的那一份 ✓（否则会把玩家真实设置写坏 ✗）
## 若为 null：_ready() 会自己 new 一份并 load_from_disk() ✓（单独把本节点拖进场景也不会崩 ✓），
##   代价是与 GameSettings 那份额外读一次 user://settings.cfg（无害但会各持一份 ✓）。
var store: SettingsStore = null

## 全屏根节点（Control）。它是**唯一**的显隐开关 ✓（CanvasLayer 没有 visible ✗），
## 同时也是整块 UI 的 theme 宿主 → 中文兜底字体由它往下继承 ✓。
var _root: Control = null
## 右侧设置行容器。每次切分类都**清空重填** ✓（每行由 _make_row() 生成 ✓）。
var _content: VBoxContainer = null
## 左侧分类按钮容器，_build() 里按 SettingsSchema.ORDER 逐个建按钮 ✓。
var _cat_box: VBoxContainer = null
## 底部状态栏：显示"某项已应用 / 功能待开发 / 保存成功但应用失败"等即时反馈 ✓。
## 各写入点都做了判空 ✓（即使 _build() 尚未跑过调用也不会崩 ✓）。
var _status: Label = null
## 分类名(String) → 分类按钮(Button) 的映射 ✓。
## 切分类时靠它把**所有**按钮的 toggle 态同步刷新 ✓（只改被点的那个会留下两个高亮 ✗）。
var _cat_buttons := {}
## 当前显示的分类名 ✓。用途：open() 后回到上次那页 ✓；"恢复默认"后原地重刷 ✓。
var _current_cat := ""
## 菜单是否开着 —— 这是**唯一权威状态** ✓。外部请用 is_open() 读 ✓，
## 别去判断 _root.visible ✗（它只反映可见性，不反映暂停/鼠标模式有没有被改过 ✓）。
var _is_open := false
## open() 之前的 get_tree().paused 快照 → close() 精确还原 ✓。
## 为什么必须存而不是硬写 false ✗：暂停可能是别的系统设的（过场/对话 ✓），
## 一律写 false 会把它们的状态冲掉 ✗。
var _saved_pause := false
## open() 之前的 Input.mouse_mode 快照 → close() 精确还原 ✓（同理，可能是别的系统设的 ✓）。
## 初值取 MOUSE_MODE_VISIBLE 只是给一个合法值 ✓（close() 在未 open 时会提前 return，用不到它 ✓）。
var _saved_mouse := Input.MOUSE_MODE_VISIBLE


# ==================== 生命周期与初始化 ====================

## 节点入树回调：准备 store → 构建整棵 UI → 默认隐藏 → 预热一页内容。
##
## 参数：无（Godot 回调 ✓）
## 返回：无
## 副作用（都是实质性的 ✓）：
##   · 新建大量 UI 节点并 add_child 到 self（CanvasLayer）✓
##   · store == null 时新建 SettingsStore 并**读 user://settings.cfg** ✓
##   · 把 layer 提到 100、process_mode 设为 ALWAYS ✓
## 调用时机：本节点 add_child() 进场景树之后由引擎调用 ✓（GameSettings 就是这样创建的 ✓）。
## 注意：
##   · 这里**不会**自动 open() ✓ —— 初始是关闭的（_root.visible = false ✓），等外部调 open() ✓
##   · layer / process_mode 放在这里而不是 _init() ✓：CanvasLayer 的属性要在入树后才真正生效 ✓
##   · process_mode = ALWAYS 是**必须**的 ✓ —— 菜单自己会把 get_tree().paused 置 true ✓，
##     若跟随暂停，开着菜单时就再收不到 _input 了 ✗（会变成"打开就关不掉" ✗）
##   · 顺序不能换：先 _build() 才能拿到 _root ✓，否则 _root.visible 会空引用崩 ✗
func _ready() -> void:
	# 100：压过字幕层（game_settings.gd 里 SubtitleLayer.layer = 90 ✓），保证设置菜单在最上层 ✓
	layer = 100
	# ALWAYS：菜单打开时场景树被暂停 ✓，本层必须继续处理输入与 UI ✓
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 只在**没有被外部注入** store 时才自建 ✓（GameSettings 注入全局那份 ✓；测试注入临时路径那份 ✓）
	if store == null:
		store = SettingsStore.new()
		store.load_from_disk()
	_build()
	# CanvasLayer 没有 visible ✗ → 隐藏整个界面只能靠子 Control ✓
	_root.visible = false
	# 预热一页：让玩家一打开就有内容 ✓；default_category 留空则回落 ORDER[0] = 画质 ✓
	_show_category(default_category if default_category != "" else SettingsSchema.ORDER[0])


# ==================== 中文主题 ====================

## 中文兜底：用**系统字体**，项目里没有 CJK 字体也不会显示成方块 ✓
##
## 参数：无（静态方法 ✓，不需要实例 ✓）
## 返回：Theme —— 一个新的主题对象，default_font 是系统 CJK 字体、default_font_size = 16 ✓
## 副作用：无（只 new 两个对象 ✓，不碰场景树、不写文件 ✓）
## 调用时机：
##   · _build() 里赋给 _root.theme ✓ → 整棵设置 UI 继承该字体 ✓
##   · game_settings.gd 的字幕层也调用它 ✓（所以必须是 static ✓，不能依赖菜单实例 ✓）
## 注意事项：
##   · 用 SystemFont + 字体名列表，而不是内嵌 .ttf ✓ —— 避免往仓库里塞 CJK 字体文件（几 MB）✓；
##     代价是**依赖系统装了列表里某一款字体** ✗，全都没有时会退回引擎默认字体（中文变方块 ✓ 已知取舍）
##   · font_names 顺序 = 优先级顺序 ✓：Windows（雅黑 → 黑体 → 宋体）→
##     Linux/跨平台（Noto / 思源）→ macOS（PingFang）✓
##   · 每次调用都新建 Theme（没有缓存 ✓）：调用点很少（菜单一次 + 字幕层一次 ✓），
##     不值得为它加静态缓存 ✓
static func make_cjk_theme() -> Theme:
	var th := Theme.new()
	# SystemFont 会在运行时向操作系统按名字查字体 ✓（项目里不用带字体文件 ✓）
	var f := SystemFont.new()
	# 按优先级排列的多平台字体名 ✓：任一命中即可 ✓（全是别名，不需要字体真实存在 ✓）
	# （推测：这几款覆盖了 Win/Linux/macOS 的常见中文默认字体 ✓）
	f.font_names = PackedStringArray([
		"Microsoft YaHei UI", "Microsoft YaHei", "SimHei", "SimSun",
		"Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC",
	])
	th.default_font = f
	# 16：比引擎默认（~16）持平但显式固定 ✓，避免不同平台 UI 字号漂移 ✓；
	# 标题/提示行用 add_theme_font_size_override 单独覆写（22 / 18 / 12 ✓），全局值只作基准 ✓
	th.default_font_size = 16
	return th


# ==================== UI 代码构建 ====================

## 用**纯代码**搭出整个设置界面（不依赖任何 .tscn ✓）：
## 全屏遮罩 → 居中面板 → 标题栏 → 左分类 / 右内容（HSplitContainer）→ 底部按钮栏 ✓
##
## 参数：无
## 返回：无
## 副作用：new 出整棵 Control 树并挂到 self 上 ✓；同时给 _root / _content / _cat_box / _status 赋值 ✓
## 调用时机：只由 _ready() 调用一次 ✓。**不要重复调用** ✗ —— 它会再造一棵 UI 并重复 add_child ✗。
## 注意事项：
##   · 分类按钮的文字直接用 SettingsSchema.ORDER 的中文常量 ✓ → 分类列表**不要**在这里硬编码 ✗
##   · 只有 _content 里的行是可重建的 ✓（_show_category() 负责清空重建 ✓）；
##     左侧分类按钮、底部按钮栏只建一次 ✓
##   · 所有尺寸写死在代码里（1040x680 的居中面板 ✓）→ 改版式只需改这里的数字 ✓
func _build() -> void:
	# 顶层根：全屏铺满 + STOP 鼠标过滤 ✓ —— 挡住下层游戏的点击 ✗（否则点设置会同时点到游戏 ✓）
	_root = Control.new()
	_root.name = "SettingsRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	# 在这里挂主题 → 下面所有子控件继承 CJK 字体 ✓
	_root.theme = make_cjk_theme()
	add_child(_root)

	# 半透明黑遮罩（alpha 0.55 ✓）：压暗背后的游戏画面 ✓，同时配合 STOP 吞掉鼠标 ✓。
	# 调大更暗（0.8 ≈ 几乎全黑 ✓）；调小更透（0.3 会显得菜单"飘"着 ✓）。
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	# 居中主面板：先 PRESET_CENTER 再手写 anchors=0.5 + offsets ±(520,340) ✓
	# → 效果是**固定 1040x680** 的居中面板 ✓（不随窗口拉伸 ✓，因为四边都锚在中心点 ✓）。
	# 注意顺序：set_anchors_preset(CENTER) 之后又显式写 anchors ✓ 是冗余但无害的（保证不依赖预设行为 ✓）。
	# 想让面板随窗口变大：改成 PRESET_FULL_RECT + 四边留 margin ✓（目前故意不这么做 ✓）。
	var frame := PanelContainer.new()
	frame.set_anchors_preset(Control.PRESET_CENTER)
	frame.anchor_left = 0.5
	frame.anchor_top = 0.5
	frame.anchor_right = 0.5
	frame.anchor_bottom = 0.5
	frame.offset_left = -520
	frame.offset_top = -340
	frame.offset_right = 520
	frame.offset_bottom = 340
	_root.add_child(frame)

	# 竖向总排布：标题 / 主分区 / 底部按钮栏 ✓（separation 8 是三者之间的间距 ✓）
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	frame.add_child(outer)

	# 标题行（22 号字，比主题默认 16 大 ✓，靠 font_size override 覆写 ✓）
	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 22)
	outer.add_child(title)

	# 左右分栏：左边分类列表 / 右边设置内容 ✓
	# size_flags_vertical = EXPAND_FILL ✓ → 主分区吃掉标题与底栏之外的全部高度 ✓
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 150：初始分栏位置 ✓（与下面 _cat_box 的 custom_minimum_size 一致 ✓）；
	# 玩家可以拖这条分隔条 ✓，但拖不到 150 以下（受最小宽度约束 ✓）
	split.split_offset = 150
	outer.add_child(split)

	# 左侧分类栏：固定最小宽度 150 ✓（防止被拖窄到看不见文字 ✓），条目间距 4（按钮贴紧一点 ✓）
	_cat_box = VBoxContainer.new()
	_cat_box.custom_minimum_size = Vector2(150, 0)
	_cat_box.add_theme_constant_override("separation", 4)
	split.add_child(_cat_box)
	# 分类按钮直接从 schema 的 ORDER 生成 ✓：加/删分类只改 settings_schema.gd ✓，本文件不用动 ✓
	for cat in SettingsSchema.ORDER:
		var b := Button.new()
		b.text = String(cat)
		# toggle_mode：让按钮保持"按下"外观以表示当前分类 ✓
		# （互斥是手动的 ✓ —— 见 _show_category() 里按名字逐个同步 button_pressed ✓）
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		# 用 bind 把分类名显式随信号传进去 ✓，不依赖闭包对循环变量 cat 的捕获 ✓（更稳 ✓）
		b.pressed.connect(_show_category.bind(String(cat)))
		_cat_box.add_child(b)
		# 存进映射表 → 切分类时统一刷新按下态 ✓（也供 category_names() 读取 ✓）
		_cat_buttons[String(cat)] = b

	# 右侧滚动容器：设置项多于一屏时可滚 ✓；**禁用横向滚动** ✓（横向滚动条对设置页没意义且会挤压内容 ✓）
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	split.add_child(scroll)
	# 真正的设置行容器（_show_category() 会清空/重建它的子节点 ✓）；行与行间距 10 ✓
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 10)
	scroll.add_child(_content)

	# 底部栏：左「恢复默认」/ 中状态文字 / 右「关闭」✓（状态文字 EXPAND_FILL → 把两个按钮推到两端 ✓）
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	outer.add_child(foot)
	var b_reset := Button.new()
	b_reset.text = "恢复默认"
	b_reset.pressed.connect(_reset_defaults)
	foot.add_child(b_reset)
	# clip_text：状态文字过长时裁掉而不是把底栏撑变形 ✓
	# （状态串形如 "audio/music：0.35 —— 已应用"，键名可能很长 ✓）
	_status = Label.new()
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.clip_text = true
	foot.add_child(_status)
	# 关闭按钮不是 ESC ✓（ESC 由 _input() 处理 ✓）→ 纯鼠标用户也能关 ✓
	var b_close := Button.new()
	b_close.text = "关闭"
	b_close.pressed.connect(close)
	foot.add_child(b_close)


# ==================== 分类页与设置行 ====================

## 切换到指定分类：刷新左侧按钮高亮 → 清空右侧 → 按 schema 重建该页所有行 →（操作页）追加按键绑定段。
##
## 参数 cat：分类名，取值应为 SettingsSchema 的 CAT_* 常量值（"画质"/"音频"/…）。
##   未知/空分类**不会崩** ✓：items() 里没有该键 → table.get(cat, []) 得到空数组 → 只会建出一个空页 ✓。
## 返回：无
## 副作用：
##   · 写 _current_cat ✓
##   · 同步刷新**所有**分类按钮的 button_pressed ✓
##   · 销毁 _content 的全部旧子节点（remove_child + queue_free ✓）
##   · 新建若干行控件 ✓；"操作"页还会读 InputMap（SettingsInput.game_actions() ✓）
##   · 会调用 SettingsApply.about_info()（读引擎/系统信息 ✓，"关于"页显示真实版本与内存 ✓）
## 调用时机：_ready() 预热一次 ✓；点分类按钮 ✓；改键完成后刷新 ✓；"恢复默认"后原地重刷 ✓；
##   open() 时回到上次那页 ✓（由单元测试逐页调用以覆盖每一页构建 ✓）
## 注意事项：
##   · **必须**先 remove_child 再 queue_free ✓。只 queue_free 的话旧行会活到帧末 ✗ →
##     这一帧里新旧行同时存在（布局抖一下，且旧行闭包会短暂持有已释放控件 ✗）
##   · 每次切页都整页重建（不缓存 ✓）：设置页行数少、次数少，重建最省心也最不容易状态不同步 ✓
func _show_category(cat: String) -> void:
	_current_cat = cat
	# 按名字比对逐个按钮同步按下态 ✓ —— 保证**同时只有一个**分类是高亮的 ✓
	for k in _cat_buttons.keys():
		(_cat_buttons[k] as Button).button_pressed = (String(k) == cat)
	# 先 remove_child 再 queue_free ✓ —— 只 queue_free 的话，旧行会留到帧末 ✗，
	# 期间新旧行会叠在一起（而且旧行的闭包会短暂持有已释放的控件 ✗）
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	# 每次取一份新的表（items() 每次调用都新建 Dictionary ✓，改 schema 立即反映 ✓）
	var table: Dictionary = SettingsSchema.items()
	# about_info() 里是**每次打开都实时读**的引擎/内存信息 ✓ → 所以在这里取而不是缓存 ✓
	var info := SettingsApply.about_info()
	# table.get(cat, [])：未知分类得到空数组 ✓（这就是"分类名写错也不崩"的兜底 ✓）
	for it in (table.get(cat, []) as Array):
		var d: Dictionary = it
		_content.add_child(_make_row(d, info))
	# 操作页：按键绑定是**运行时状态** ✓，不能写死在 schema 里 ✗ → 动态生成 ✓
	if cat == SettingsSchema.CAT_CONTROLS:
		_content.add_child(_make_keybindings_section())


## 把 schema 里的**一个条目**渲染成一行控件（行 = 标签 + 值控件 [+（待开发）标签] [+ 提示行] ✓）。
##
## 参数 item：schema 条目字典，来自 SettingsSchema.items()。用到的字段：
##   · "key"（String，必填 ✓）—— store 里的键，如 "audio/music"；同时是写回时的键 ✓
##   · "kind"（int，必填 ✓）—— SettingsSchema.Kind 枚举：TOGGLE/SLIDER/CHOICE/INFO ✓
##   · "label"（String，可选）—— 左侧文字，缺省时回落为 key ✓
##   · "todo"（bool，可选，默认 false）—— true = 功能未实现：控件置灰 + 加"（待开发）"标签 ✓
##   · "default"（SLIDER/CHOICE 用 ✓）、"min"/"max"/"step"（SLIDER ✓，默认 0/1/0.01 ✓）、
##     "choices"（CHOICE ✓，显示文字数组 ✓）、"values"（CHOICE 可选 ✓，索引→真实值映射 ✓）、
##     "hint"（可选 ✓）、"value_text"（INFO 的兜底文字 ✓）
## 参数 info：SettingsApply.about_info() 的结果 ✓，仅 kind=INFO 且 key 命中时**覆盖** value_text ✓
##   （"关于"页的引擎版本/内存占用等是实时读的 ✓，不该写死 ✓）
## 返回：Control —— 一个 VBoxContainer（该行）✓；调用方负责 add_child 到 _content ✓
## 副作用：
##   · 会**立刻用 store.get_value(key) 初始化控件当前值** ✓
##   · 会把控件的 toggled / value_changed / item_selected **连到 _commit** ✓ →
##     一旦玩家操作就写 store + 立即应用 + 刷状态栏 ✓（闭包捕获了本行的 key ✓，各行的 key 互不干扰 ✓）
##   · 不主动写 store ✓（只是读 ✓）；todo 项不允许操作 ✓（disabled / editable=false ✓）
## 调用时机：_show_category() 逐条调用 ✓（每次切页重建 ✓，所以闭包随控件一起销毁 ✓，不会泄漏 ✓）
## 注意事项：
##   · SLIDER 的 min/max/step 是"条目自己声明"的 ✓（灵敏度 0.2~3.0 步长 0.05 ✓、音量 0~1 步长 0.01 ✓）
##   · HSlider 没有 disabled ✗ → 必须用 editable ✓（见下方原地注释 ✓）
##   · CHOICE 存进 store 的是**真实值**而不是索引 ✓（如 fps_limit 存 60 而不是 2 ✓），
##     所以回填用 SettingsSchema.value_to_index() ✓
func _make_row(item: Dictionary, info: Dictionary) -> Control:
	var key := String(item["key"])
	var kind := int(item["kind"])
	var todo := bool(item.get("todo", false))
	# 行 = 竖排（标签行 + 可选提示行 ✓）；间距 2 让提示行紧贴标签 ✓
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 2)
	# 标签行 = 横排 ✓（名称 / 值控件 /（待开发）标签 ✓）；间距 12 避免挨太近 ✓
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 12)
	row.add_child(line)

	# 左侧名称列：固定最小宽 170 ✓ → 各行的值控件能在同一竖线上对齐 ✓（不固定就会参差不齐 ✓）
	var name_label := Label.new()
	name_label.text = String(item.get("label", key))
	name_label.custom_minimum_size = Vector2(170, 0)
	# todo 项整行文字降到 55% 不透明度 ✓ → 视觉上"不可用" ✓（与置灰的控件一致 ✓）
	if todo:
		name_label.modulate = Color(1, 1, 1, 0.55)
	line.add_child(name_label)

	# 按 kind 造对应的值控件（ctl 为 null 表示 kind 不认识 ✓ → 下面会跳过 add_child ✓，只留标签行 ✓）
	var ctl: Control = null
	match kind:
		SettingsSchema.Kind.TOGGLE:
			# 开关：CheckBox ✓；初始态直接读 store ✓（store 没有该键时会取 schema 的 default ✓）
			var cb := CheckBox.new()
			cb.button_pressed = bool(store.get_value(key))
			# 占位项禁用 ✓；CheckBox 是 BaseButton 子类 → 有 disabled ✓（这点与 HSlider 不同 ✗）
			cb.disabled = todo
			# 闭包只捕获 key（本函数局部变量 ✓，每个 key 一份 ✓）→ 不会串行 ✓
			cb.toggled.connect(func(v: bool): _commit(key, v))
			ctl = cb
		SettingsSchema.Kind.SLIDER:
			# 滑条 + 右侧百分比标签，横排一个盒子 ✓（滑条本身不含"值文字"→ 自己配一个 ✓）
			var box := HBoxContainer.new()
			box.add_theme_constant_override("separation", 8)
			var sl := HSlider.new()
			# min/max/step 全部来自条目声明 ✓（缺省 0~1 步长 0.01 适合音量/缩放 ✓）
			sl.min_value = float(item.get("min", 0.0))
			sl.max_value = float(item.get("max", 1.0))
			# step：拖动的离散步长 ✓（0.05 的灵敏度、0.01 的音量 ✓），同时决定滑条数值的吸附精度 ✓
			sl.step = float(item.get("step", 0.01))
			# 260：滑条固定宽度 ✓；不设的话会被 VBox 拉长，各页宽度不一致 ✓
			sl.custom_minimum_size = Vector2(260, 0)
			# 初始值从 store 读 ✓（store 无此键时 get_value 会回落到 schema default ✓）
			sl.value = float(store.get_value(key))
			# ★ HSlider **没有** disabled 属性 ✗（那是 BaseButton 才有的 ✓）→ 用 editable ✓
			#   曾经写成 sl.disabled = todo ✗ → 点开音频页当场运行时报错 ✗（被日志精确定位到本行 ✓）
			sl.editable = not todo
			if todo:
				# 用 modulate 表达"置灰" ✓（因为 HSlider 没有 disabled 的灰化效果 ✓）
				sl.modulate = Color(1, 1, 1, 0.5)
			# 右侧百分比标签 ✓（音量/缩放都是 0~1.x 的小数，用百分比更直白 ✓）
			var vlab := Label.new()
			vlab.text = "%.0f%%" % (sl.value * 100.0)
			# 56：给"100%"预留固定宽度 ✓，防止数字变化时整行左右抖动 ✓
			vlab.custom_minimum_size = Vector2(56, 0)
			# 拖动时：先刷新文字 ✓ 再落库 ✓（顺序无关紧要，v 与 snapped 后的值只差最后一位 ✓）
			sl.value_changed.connect(func(v: float):
				vlab.text = "%.0f%%" % (v * 100.0)
				# snappedf：按 step 吸附后再存 ✓ —— 鼠标拖出的浮点值会有长尾小数 ✗，
				# 不吸附会出现"存的 0.30000001 与滑条 0.3 不相等"的隐性不同步 ✗
				_commit(key, snappedf(v, float(item.get("step", 0.01))))
			)
			box.add_child(sl)
			box.add_child(vlab)
			ctl = box
		SettingsSchema.Kind.CHOICE:
			# 下拉：条目按 choices 顺序加项 ✓（顺序就是界面上看到的顺序 ✓）
			var ob := OptionButton.new()
			for c in (item.get("choices", []) as Array):
				ob.add_item(String(c))
			# ★ store 里存的是**真实值**（如 fps_limit 的 60）而不是索引（2）✓ → 必须换算回索引 ✓
			# value_to_index 找不到匹配时返回 0 ✓（不会崩 ✓，但会静默显示第一项 ✓）
			ob.selected = SettingsSchema.value_to_index(key, store.get_value(key))
			ob.disabled = todo
			# 选中索引 → 反查真实值（没声明 values 时就是索引本身 ✓）→ 落库 ✓
			ob.item_selected.connect(func(i: int): _commit(key, SettingsSchema.choice_value(key, i)))
			ctl = ob
		SettingsSchema.Kind.INFO:
			# 信息行：只显示文字、不可交互 ✓；优先用 about_info() 的**实时**值 ✓，否则用条目自带的 value_text ✓
			var il := Label.new()
			var txt := String(item.get("value_text", ""))
			if info.has(key):
				txt = String(info[key])
			il.text = txt
			# 存档目录之类的长路径要能换行 ✓（按词智能换行 ✓，中英混排下比按字符换行好看 ✓）
			il.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			il.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			# 略偏冷的浅灰 ✓：与可点击项区分开，表明这是"只读信息" ✓
			il.modulate = Color(0.85, 0.85, 0.9, 0.9)
			ctl = il
	if ctl != null:
		# 值控件撑满剩余宽度 ✓ —— 但 SLIDER 例外 ✗：它外面那层 box 撑满会让滑条被拉长 ✓，
		# 而滑条宽度是刻意固定的（custom_minimum_size 260 ✓）→ 保持原样 ✓
		if kind != SettingsSchema.Kind.SLIDER:
			ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(ctl)
	if todo:
		# 右上角的占位标记 ✓：控件已置灰，但文字提示玩家"这项还没做" ✓（避免以为是 bug ✓）
		var tag := Label.new()
		tag.text = "（待开发）"
		tag.modulate = Color(1, 0.85, 0.4, 0.75)
		line.add_child(tag)
	# 可选的说明行（schema 的 "hint" ✓）：空串就不建节点 ✓，避免无谓的空行 ✓
	var hint := String(item.get("hint", ""))
	if hint != "":
		var hl := Label.new()
		# 前面 4 个空格：让说明文字相对名称列**缩进** ✓（纯空格排版，比再套一层容器省事 ✓）
		hl.text = "    " + hint
		# 12 号小字 ✓（比标题 22 与全局 16 小一级 ✓，明确它是"次要信息" ✓）
		hl.add_theme_font_size_override("font_size", 12)
		hl.modulate = Color(1, 1, 1, 0.5)
		hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(hl)
	return row


# ==================== 设置写入与应用 ====================

## 一项改动：写进 store ✓ 立刻应用 ✓ 反馈状态 ✓
##
## 参数 key：设置键，形如 "audio/music" / "graphics/tier" / "input/bindings" ✓
## 参数 value：新值（Variant ✓）。类型约定：TOGGLE→bool、SLIDER→float、CHOICE→schema 声明的真实值 ✓
## 返回：无
## 副作用：
##   · **写 store** ✓ —— SettingsStore.set_value() 内部会 save() 落盘到 user://settings.cfg ✓
##     （也就是说：玩家拖一下滑条就已经写盘了 ✓，不用等关菜单 ✓；值未变时 set_value 会提前 return ✓）
##   · **立刻调用 SettingsApply.apply_one()** ✓ → 真的改引擎状态（音频总线 / 窗口 / MSAA / 画质档…✓）
##   · 更新底部状态栏文字 ✓（_status 为 null 时跳过 ✓，所以 _build 之前调用也安全 ✓）
## 调用时机：各控件回调闭包（toggled / value_changed / item_selected ✓）→ 玩家一操作就跑 ✓。
## 注意事项：
##   · 这里的 match 只**覆写**非顺利路径 ✓；"ok" 与 "unknown" 都会落到默认的"已应用" ✓。
##     key 一律来自 schema ✓，所以实际不会出现 "unknown" ✓（推测：真出现也只会把状态栏写得偏乐观 ✓，不影响功能 ✓）
##   · todo 项虽然置灰不触发回调 ✓，但本函数不检查 todo ✓ —— 语义上"能不能改"由控件层把关 ✓
func _commit(key: String, value: Variant) -> void:
	store.set_value(key, value)
	var r := SettingsApply.apply_one(store, key)
	var word := "已应用"
	match r:
		"todo": word = "已保存（功能待开发）"
		"editor-skip": word = "已保存（编辑器内不改变窗口 ✓）"
		"failed": word = "保存成功，但应用失败 ✗"
		"queued": word = "已保存（画质系统稍后生效）"
	# 状态串带上 key 与值 ✓ → 出问题时截图就能定位是哪一项 ✓（clip_text 会裁掉过长部分 ✓）
	if _status != null:
		_status.text = "%s：%s —— %s" % [key, str(value), word]


## 「恢复默认」按钮的回调：全部重置为 schema 默认值 → 落盘 → 逐项重新应用 → 原地重刷当前页。
##
## 参数：无（直接连到按钮 pressed ✓）
## 返回：无
## 副作用：
##   · store.reset_all() **覆盖整份设置表**（内存 ✓；input/bindings 之类的非 schema 键也会被清掉 ✓）
##   · store.save() 落盘 ✓
##   · 对 schema 的**每一个默认键**调用 SettingsApply.apply_one() ✓ → 音频/画质/显示全部回到默认 ✓
##   · 重建当前分类页 ✓（否则滑条/下拉还停在旧值上，界面与实际不一致 ✗）
##   · 状态栏写"已恢复默认并应用 ✓"
## 调用时机：底部「恢复默认」按钮 ✓（**没有任何二次确认** ✓ —— 目前是即点即生效 ✓；
##   如果以后要加确认框，注意别让它落在暂停中的场景树之外 ✗）
## 注意事项：
##   · 遍历 SettingsSchema.defaults().keys() 而不是 store 里的键 ✓：
##     input/bindings 不是"设置项"✓（是按键表，由 SettingsInput 管 ✓）→ 不该在这里重放 ✓
##   · 编辑器内 apply_one 会返回 "editor-skip" ✓（不碰窗口 ✓）；返回值这里**不检查** ✓ ——
##     整体是"尽力应用"语义 ✓，单项失败不影响其余项 ✓
func _reset_defaults() -> void:
	store.reset_all()
	store.save()
	# 逐键重放：一个键失败不影响其它键 ✓（apply_one 自带 try 语义：最多返回 "failed" ✓）
	for key in SettingsSchema.defaults().keys():
		SettingsApply.apply_one(store, String(key))
	_show_category(_current_cat)
	if _status != null:
		_status.text = "已恢复默认并应用 ✓"


# ==================== 对外查询接口 ====================

## 实际建出来的分类按钮文字（供测试/外部确认 UI 真的构建成功 ✓）
##
## 参数：无
## 返回：Array（String 数组 ✓），顺序 = _cat_box 里子节点的顺序 = SettingsSchema.ORDER 的顺序 ✓；
##   _cat_box 尚未构建（_ready 未跑 ✓）时返回**空数组** ✓，不崩 ✓
## 副作用：无（只读场景树 ✓，不改状态 ✓）
## 调用时机：单元测试在 add_child() 之后调用它来断言分类数与首个分类名 ✓。
## 注意事项：
##   · 这里刻意遍历**真实子节点**并做 `is Button` 过滤 ✓，而不是直接返回 _cat_buttons 的键 ✗ ——
##     测试要验证的是"UI 真的建出来了" ✓（读映射表只能证明逻辑跑了 ✗，证明不了节点存在 ✗）
##   · 也**不要**在测试里硬猜 UI 层级路径 ✗（比如 get_node("root/panel/split/...") ✓）—— 版式一改测试就碎 ✗
func category_names() -> Array:
	var out: Array = []
	# 空守卫：允许在 _ready() 之前（或 _build() 失败后）安全调用 ✓
	if _cat_box == null:
		return out
	for k in _cat_box.get_children():
		# 过滤掉未来可能加进 _cat_box 的非按钮节点（标题/分隔线等 ✓）→ 只报按钮文字 ✓
		if k is Button:
			out.append((k as Button).text)
	return out


# ==================== 按键绑定 UI ====================

## ---- 按键绑定段 ✓ ----
## 正在等待玩家按键的**动作名**（"" = 当前没在改键 ✓）。
## 它是本菜单的"输入状态机开关" ✓：_input() 里第一件事就检查它 ✓ ——
## 非空时**吃掉所有按键** ✓（包括 ESC = 取消 ✓），保证改键过程中不会误触发打开/关闭菜单 ✗。
## 取值：InputMap 里的动作名（如 "jump" ✓）；只由 _start_capture() 写入 ✓、
## 由 _input() 的三处分支清零 ✓（取消 / 改键成功 / 改键失败，都会清 ✓）。
var _capturing := ""

## 动态生成「按键绑定」段（只有"操作"分类页才会被创建 ✓）。
##
## 参数：无
## 返回：Control —— 一个 VBoxContainer（标题 + 操作提示 + 每个动作一行 ✓）
## 副作用：
##   · **读 InputMap**（SettingsInput.game_actions() ✓）→ 该列表是每次调用现算的 ✓，
##     所以项目里新增/删除动作后，重新切页即可看到 ✓，不需要改本文件 ✓
##   · 建按钮时读当前绑定文字（SettingsInput.current_text() ✓ = 实时状态 ✓）
##   · 把"改键"按钮连到 _start_capture(action, button) ✓（用 bind 显式传参 ✓）
##   · 把"恢复默认"按钮连到一个闭包 ✓：先 SettingsInput.reset_action() ✓ 再重建本页 ✓
## 调用时机：_show_category()，且仅当 cat == SettingsSchema.CAT_CONTROLS ✓。每次切到"操作"页都重建 ✓。
## 注意事项：
##   · 段内**每个动作一行**，行数 = 可改键动作数 ✓ → 动作多时靠外层 ScrollContainer 滚动 ✓，
##     这里不需要也不能再套滚动容器 ✗（嵌套滚动会让滚轮行为变怪 ✓）
##   · "恢复默认"是**单个动作**的默认 ✓（从 project.godot 的 input/<action> 读回来 ✓），
##     与底部的全局「恢复默认」（重置所有设置项 ✓）不是一回事 ✓，别混淆 ✓
func _make_keybindings_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	# 段内小标题（18 号 ✓，介于页标题 22 与正文 16 之间 ✓，形成层级 ✓）
	var head := Label.new()
	head.text = "按键绑定"
	head.add_theme_font_size_override("font_size", 18)
	box.add_child(head)
	# 操作提示行 ✓：把"怎么改键 / 怎么取消 / 会自动保存"三件事一次讲清 ✓（12 号小字 ✓）
	var tip := Label.new()
	tip.text = "    点右侧按钮 → 按下新键即可改绑；按 ESC 取消。改动会立即保存 ✓"
	tip.add_theme_font_size_override("font_size", 12)
	tip.modulate = Color(1, 1, 1, 0.55)
	box.add_child(tip)
	# 只列**可改键**的动作 ✓（SettingsInput 会排除 ui_* 与编辑器动作 ✓，并按名字排序 ✓ → 列表稳定 ✓）
	for a in SettingsInput.game_actions():
		var action := String(a)
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		# 左列：动作名（英文标识符 ✓，不翻译 ✓ —— 玩家要靠它对应 InputMap ✓）
		var name_label := Label.new()
		name_label.text = action
		name_label.custom_minimum_size = Vector2(220, 0)
		row.add_child(name_label)
		# 中列：当前绑定文字（显示成 "W" / "Ctrl+K" / "鼠标右键" ✓，多个绑定用顿号连 ✓）
		var b := Button.new()
		b.text = SettingsInput.current_text(action)
		b.custom_minimum_size = Vector2(200, 0)
		# 把按钮自身也传进去 ✓ → 点下后能把按钮文字改成"请按键…" ✓（给玩家明确反馈 ✓）
		b.pressed.connect(_start_capture.bind(action, b))
		row.add_child(b)
		# 右列：单动作恢复默认 ✓（重置后重建本页 ✓ → 按钮文字立刻变回默认值 ✓；
		# 不重建的话按钮上还显示旧绑定 ✗，玩家会以为没生效 ✗）
		var rb := Button.new()
		rb.text = "恢复默认"
		rb.pressed.connect(func():
			SettingsInput.reset_action(store, action)
			_show_category(SettingsSchema.CAT_CONTROLS)
		)
		row.add_child(rb)
		box.add_child(row)
	return box


## 进入"等待按键"状态：记下要改的动作名，并把入口按钮改成提示文字。
##
## 参数 action：要改绑的动作名（InputMap 里的英文标识符 ✓，如 "jump" ✓）
## 参数 button：玩家点的那个按钮（Button ✓）—— 用来原地改文字做反馈 ✓；
##   允许为 null ✓（不崩 ✓，只是没有按钮文字反馈 ✓；由 _start_capture.bind() 保证正常路径总是非 null ✓）
## 返回：无
## 副作用：
##   · 写 _capturing = action ✓ → 从此刻起 _input() 会**吃掉所有按键** ✓ 直到改键结束或取消 ✓
##   · 修改该按钮的 text ✓（"请按键…（ESC 取消）" ✓）—— 这是**临时**文字 ✓：
##     改键结束/取消后由 _show_category(CAT_CONTROLS) 整页重建来恢复 ✓，
##     所以这里不需要（也不该 ✓）记住原文字 ✗
##   · 写状态栏 ✓（_status 为 null 时跳过 ✓）
## 调用时机：只由"操作"页每行的改键按钮 pressed 触发 ✓。
## 注意事项：
##   · 本函数**不**接收任何按键 ✓ —— 真正的按键在 _input() 的"① 正在改键"分支里处理 ✓
##   · 如果玩家点了按钮却一直不按键 ✓，菜单就停在 capture 状态 ✓（ESC 可取消 ✓，不会卡死 ✓）
func _start_capture(action: String, button: Button) -> void:
	_capturing = action
	if button != null:
		button.text = "请按键…（ESC 取消）"
	if _status != null:
		_status.text = "正在为 %s 改键…" % action


# ==================== 输入处理 ====================

## 打开菜单的按键：ESC 是常规键 ✓，F10 是**不会被别的脚本抢走**的备用键 ✓✓
## （本行以下是补充说明 ✓，原注释一字未改 ✓）
## 取值：Key 枚举数组 ✓；默认 [KEY_ESCAPE, KEY_F10]。
## 改动效果：
##   · 往里加键 → 多一个开关键 ✓（别加 WASD/空格这类游戏常用键 ✗，会把玩家的操作抢走 ✗）
##   · 删掉 KEY_ESCAPE → 关掉"用 ESC 打开"；但注意**菜单开着时 ESC 仍能关闭** ✓
##     （关闭分支只看 _is_open 与 code == KEY_ESCAPE ✓，不看本数组 ✓）→ 与 open_with_escape 语义略有差别 ✓
##   · F10 之所以是兜底 ✓：项目里没有别处处理它 ✓，所以不会被 camera_rig / game_ui 抢走 ✓
## 注意：这是 @export ✓（编辑器里可被 Inspector 覆写 ✓），但 GameSettings 是**代码 new** 的本脚本 ✓ →
##   运行时用的始终是这里写的默认值 ✓。
@export var open_keys := [KEY_ESCAPE, KEY_F10]

## 输入处理放在 _input（Node 能拿到的最早一站 ✓）而不是 _unhandled_input ✗ ——
## 项目里 camera_rig.gd:156 与 game_ui.gd:645 都**直接处理 ESC** ✗，
## 它们若先 set_input_as_handled()，_unhandled_input 就永远收不到 ✗。
## 而 GameSettings 是 autoload ✓ → 在场景树里排在主场景之前 ✓ → 这里能抢在它们前面 ✓。
##
## 参数 event：任意输入事件（InputEvent ✓；非键盘事件会被立刻丢弃 ✓）
## 返回：无
## 副作用（按状态三选一 ✓）：
##   ① 正在改键（_capturing != "" ✓）→ 改 InputMap + 落盘（SettingsInput.rebind ✓）+ 重建操作页 ✓
##   ② 菜单开着 → close()（还原暂停与鼠标 ✓、store 落盘 ✓、发 menu_closed ✓）
##   ③ 菜单关着且按了 open_keys → open()（暂停场景树 ✓、显示鼠标 ✓、发 menu_opened ✓）
##   · 命中处理时用 get_viewport().set_input_as_handled() ✓ 阻止事件继续传给游戏 ✓
## 调用时机：引擎输入阶段每帧调用 ✓（本节点 process_mode = ALWAYS ✓ → 暂停中也照收 ✓）
## 注意事项：
##   · **不要**改回 _unhandled_input ✗ —— 会被 camera_rig / game_ui 抢掉 ✓（见上，已有单测守着 ✓）
##   · 每个分支结束都要 return ✓，否则会继续走到底部再开一次菜单 ✗
##   · k.echo（长按重复 ✓）必须忽略 ✓，否则按住 ESC 会疯狂开/关菜单 ✗
##   · 关卡里若出现别的"改键 UI" ✗，必须与 _capturing 互斥 ✓（本菜单的 capture 会吞掉所有按键 ✗）
func _input(event: InputEvent) -> void:
	# 只关心键盘 ✓：鼠标点击/手柄事件交给 UI 系统自己走聚焦与按钮逻辑 ✓，这里一概不插手 ✓
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	# 只认"按下" ✓，忽略 k.echo（长按重复 ✓）—— 否则按住 ESC 会连续开关菜单 ✗
	if not k.pressed or k.echo:
		return
	# ★ physical_keycode 优先 ✓（物理位置，不受键盘布局影响 ✓ —— AZERTY/QWERTY 下 WASD 位置才一致 ✓）；
	#   只有在物理码为 0 时才回落到 keycode ✓（合成事件/测试里可能物理码为空 ✓）。
	#   与 SettingsInput.event_text() 的取码规则**完全一致** ✓ → 界面显示什么，这里就按什么匹配 ✓
	var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode

	# ① 正在改键：优先吃掉所有按键 ✓
	#   这是**最高优先级** ✓：capture 期间即使菜单是开着/关着、键是 ESC 还是 F10 ✓，都不再触发开关菜单 ✓
	if _capturing != "":
		if code == KEY_ESCAPE:
			# ESC 一律当"取消" ✓ → 玩家**无法**把 ESC 绑给某个动作 ✓（刻意的取舍 ✓，见下"否则"分支 ✓）
			_capturing = ""
			_show_category(SettingsSchema.CAT_CONTROLS)
			if _status != null:
				_status.text = "已取消改键 ✓"
		else:
			# 先取出并**立刻清空** _capturing ✓ 再调 rebind：rebind 内部会动 InputMap 并触发 set_value ✓，
			# 若中途有回调重入 _input，空值可避免二次改键 ✗（推测：先清后调是有意的 ✓）
			var act := _capturing
			_capturing = ""
			# rebind：清掉该动作旧绑定 → 写入新键 → 把全部绑定存进 store 的 input/bindings ✓
			# 返回 Dictionary：{ok: bool, text: String, saved: int} 或 {ok: false, message: String} ✓
			var r: Dictionary = SettingsInput.rebind(store, act, k)
			# 整页重建 ✓：让该行按钮文字从"请按键…"变回真实绑定 ✓（否则提示文字会一直留着 ✗）
			_show_category(SettingsSchema.CAT_CONTROLS)
			# 成功显示 "动作 → 键名 ✓"；失败显示 rebind 给的 message ✓（如动作不允许改键 ✓）
			if _status != null:
				_status.text = ("%s → %s ✓" % [act, str(r.get("text", ""))]) if bool(r.get("ok", false)) else String(r.get("message", "改键失败"))
		# capture 期间无论成功/取消都**吞掉事件** ✓：防止这一下按键又去触发游戏操作或开关菜单 ✗
		get_viewport().set_input_as_handled()
		return

	# ② 菜单开着：ESC 关闭 ✓
	#   这里**只看 ESC** ✓：菜单开着时 F10 等其它 open_keys **不会**把它关掉 ✓（避免误关 ✓），
	#   而关掉后如果再按 F10 才会在下面 ③ 重新打开 ✓
	if _is_open:
		if code == KEY_ESCAPE:
			close()
			get_viewport().set_input_as_handled()
		# 非 ESC：直接 return 且**不**标记已处理 ✓ → 事件会继续传给别人 ✓
		# （推测：这是刻意的 —— 菜单开着时场景树已暂停 ✓，常规游戏脚本收不到 ✓；
		#   而 PROCESS_MODE_ALWAYS 的脚本（如本菜单、总控 ✓）仍能正常收到自己的按键 ✓。
		#   不要擅自改成"菜单开着就吞掉全部输入" ✗，那会顺手废掉那些 ALWAYS 脚本的快捷键 ✓）
		return

	# ③ 菜单关着：按 open_keys 打开 ✓
	#   不在 open_keys 里 → 直接放过 ✓（连 set_input_as_handled 都不调 ✓，绝不干扰游戏操作 ✓）
	if not open_keys.has(code):
		return
	# ESC 额外受 open_with_escape 开关控制 ✓（F10 不受影响 ✓ → 这就是"兜底键"的意义 ✓）
	if code == KEY_ESCAPE:
		if not open_with_escape:
			return
		# 只有"正在输入文字"时才让路 ✓。
		# 早期写成"只要有焦点就让路" ✗ —— 那会导致游戏里只要有个**残留焦点的 HUD 按钮** ✗，
		# ESC 就永久打不开 ✗（被单元测试逮住 ✓）。
		# 只有"**可见的**输入框"有焦点时才让路 ✓。
		# 加上可见性判断很重要 ✓：已经隐藏/待释放的输入框会**残留焦点** ✗，
		# 那种情况下再挡 ESC 就等于 ESC 无故失效 ✗（测试里就踩到了这个 ✓）。
		var fo := get_viewport().gui_get_focus_owner()
		if (fo is LineEdit or fo is TextEdit) and (fo as Control).is_visible_in_tree():
			return
	# 打开 ✓；并标记已处理 ✓ → 同一次 ESC 不会既开菜单又触发游戏里的 ESC 行为 ✓
	# 注意：焦点让路逻辑只对 ESC 生效 ✓（F10 是兜底键 ✓，即便输入框有焦点也要能开菜单 ✓）
	open()
	get_viewport().set_input_as_handled()


# ==================== 开关接口（供 GameSettings 转发） ====================

## 菜单当前是否开着。
##
## 参数：无
## 返回：bool ✓（读的是 _is_open ✓，即**唯一权威状态** ✓，与 _root.visible 无关 ✓）
## 副作用：无（纯读 ✓）
## 调用时机：GameSettings.is_menu_open() 会转发到这里 ✓；外部想判断"菜单是不是占着输入"时也用它 ✓
## 注意：不要改用 _root.visible 判断 ✗ —— 那只能说明"节点可见 ✓"，说明不了暂停/鼠标模式是否被本菜单改过 ✓。
func is_open() -> bool:
	return _is_open


## 打开菜单：显示 UI、暂停场景树、显示鼠标、刷新当前页、发信号。
##
## 参数：无
## 返回：无
## 副作用：
##   · _is_open = true ✓、_root.visible = true ✓（这才是真正"显示"起来 ✓）
##   · **非编辑器**下：快照并覆盖 get_tree().paused = true ✓、Input.mouse_mode = MOUSE_MODE_VISIBLE ✓
##   · 重建当前分类页 ✓（_show_category(_current_cat) ✓ → 每次打开都取一遍最新值/实时关于信息 ✓）
##   · 发 menu_opened 信号 ✓
## 调用时机：ESC/F10（_input 分支 ③ ✓）、GameSettings.open_menu() ✓、toggle() ✓
## 注意事项：
##   · **幂等** ✓：已经开着时直接 return ✓ —— 但这样也意味着**不会**重新发 menu_opened ✓，
##     监听方不要指望重复 open() 会重复收到信号 ✓
##   · 编辑器（@tool）里**不动暂停与鼠标** ✓（Engine.is_editor_hint() 守卫 ✓）——
##     否则会暂停编辑器本身/抢走编辑器鼠标 ✗
##   · 暂停是**整个场景树**级别的 ✓：打开期间所有 PROCESS_MODE_PAUSABLE 的脚本都会停 ✓
##     （所以 ALWAYS 模式的脚本要自己判断 is_open() ✓）
func open() -> void:
	if _is_open:
		return
	_is_open = true
	_root.visible = true
	if not Engine.is_editor_hint():
		# 先快照再覆盖 ✓ —— 关掉时要精确还原，不能假设原来一定是"未暂停/鼠标可见" ✓
		_saved_pause = get_tree().paused
		_saved_mouse = Input.mouse_mode
		get_tree().paused = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# 每次打开都重建当前页 ✓（期间设置可能被别处改过，重建能顺带同步界面 ✓）
	_show_category(_current_cat)
	menu_opened.emit()


## 关闭菜单：隐藏 UI、还原暂停与鼠标、把设置落盘、发信号。
##
## 参数：无
## 返回：无
## 副作用：
##   · _is_open = false ✓、_root.visible = false ✓
##   · **非编辑器**下：get_tree().paused = _saved_pause ✓、Input.mouse_mode = _saved_mouse ✓（还原快照 ✓）
##   · store.save() 落盘 ✓（兜底：改键等路径也会即时落盘 ✓，这里是"关掉就写一次"的保险 ✓）
##   · 发 menu_closed 信号 ✓
## 调用时机：ESC（_input 分支 ② ✓）、GameSettings.close_menu() ✓、toggle() ✓、「关闭」按钮 ✓
## 注意事项：
##   · **幂等** ✓：没开着时直接 return ✓（也不会重复发 menu_closed ✓）
##   · 还原的是 open() 时的**快照** ✓ 而不是写死 false / VISIBLE ✗ ——
##     暂停与鼠标模式可能是别的系统设的 ✓，写死会把它们的意图冲掉 ✗
##   · 若在编辑器里 open 又 close ✓，暂停与鼠标始终没被碰过 ✓（两侧的 is_editor_hint() 守卫是对称的 ✓）
func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_root.visible = false
	if not Engine.is_editor_hint():
		get_tree().paused = _saved_pause
		Input.mouse_mode = _saved_mouse
	store.save()
	menu_closed.emit()


## 切换开关状态（开着就关、关着就开 ✓）。
##
## 参数：无
## 返回：无
## 副作用：转发到 open() 或 close() ✓（副作用见上面两个函数 ✓）
## 调用时机：GameSettings.toggle_menu() ✓；外部想做"一个按键开关设置"时用它 ✓
## 注意事项：
##   · 本函数**不带任何输入处理** ✓（不碰 set_input_as_handled ✓、不看按键 ✓）→
##     适合被 UI 按钮或外部脚本调用 ✓；按键路径仍走 _input() ✓
func toggle() -> void:
	if _is_open:
		close()
	else:
		open()


# ==================== 备注：为什么不在这里写 _unhandled_input ====================

## 说明：这里**故意不再处理 ESC** ✗ —— 全部逻辑都在上面的 _input 里 ✓
## （原来用 _unhandled_input 会被 camera_rig / game_ui 的 ESC 处理抢掉 ✗）
##
## 补充：
##   · 本文件末尾没有 _unhandled_input / _unhandled_key_input 定义 ✓ —— 这是**刻意的** ✓，
##     不是漏写 ✓。若将来有人为了"更规范"把 _input 挪成 _unhandled_input ✗，
##     ESC 会再次被抢走 ✗（tests/test_settings.gd 的 test_menu_input_priority 会失败 ✓）。
##   · 同理**不要**改成 _shortcut_input / _gui_input ✗：
##     _shortcut_input 只对本节点可见的 UI 生效 ✓，_gui_input 需要焦点 ✓，
##     而菜单关闭时 _root 是隐藏的 ✓ → 两者都打不开菜单 ✗。
##   · 唯一的例外是 _input 里的"可见输入框有焦点才让路" ✓（见 ③ 分支 ✓），
##     那是**功能需要** ✓，不是把 ESC 让给别的脚本 ✓。

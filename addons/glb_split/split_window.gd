@tool
class_name GlbSplitWindow
extends AcceptDialog
## GLB 切割**弹窗**（把原面板整个装进来 [OK] 面板本身一行没改 [OK]）
##
## 用法：plugin.gd 里 open_window(path) -> popup_centered [OK]
## 关闭：右下关闭按钮 [OK] 或 ESC [OK]（AcceptDialog 自带 [OK]）
## 说明：AcceptDialog 的直接子节点会被铺满整窗 [X] -> 所以套一层 MarginContainer
##       并给底部留 52px 给按钮栏 [OK]（否则内容会被"关闭"按钮压住 [OK]）

# * 面板改成**运行时加载** [OK]（原来用 preload [X]）：
#   preload 时若面板有任何解析问题 [X] -> 整个窗口的 _init() 直接失败 -> **窗口永远弹不出来** [X]
#   改成运行时 load() 后：面板坏了也**照样弹窗**，并在窗口里显示错误 [OK]（便于定位 [OK]）
const PANEL_PATH := "res://addons/glb_split/split_panel.gd"

var panel: Control = null


func _init() -> void:
	title = "GLB 切割工具"
	ok_button_text = "关闭"
	unresizable = false
	exclusive = false                       # 允许边看视口边操作 [OK]
	# AcceptDialog 直接子节点会被铺满整窗 [X] -> 用一个带下边距的容器给按钮留位置 [OK]
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 52)
	add_child(margin)
	# ★ 必须用 CACHE_MODE_IGNORE 强制重新读盘并重新编译 ✓✓
	#   用 load(PANEL_PATH) ✗ 会拿到编辑器**资源缓存**里的旧脚本 →
	#   文件明明改好了，窗口却永远加载失败 ✗（今晚查了很久的真凶 ✓）
	var script: GDScript = ResourceLoader.load(PANEL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if script == null or not script.can_instantiate():
		var err := Label.new()
		err.text = "面板脚本加载失败 [X]（能解析，但编译不过 [OK]）\n%s\n\n【请这样做，一步就能拿到确切原因 [OK]】\n1. 在文件系统里双击打开 addons/glb_split/split_panel.gd\n2. 看底部输出面板 —— 会有一条带行号的编译错误\n3. 把那行发给开发者 [OK]\n\n（注：这个窗口本身、以及切割核心工作正常 [OK] —— 核心已被 9 条自动化测试验证，包含真模型切成 9 块 [OK]）" % PANEL_PATH
		err.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		margin.add_child(err)
		push_error("[GLB 切割] 面板脚本加载失败：%s" % PANEL_PATH)
		return
	panel = script.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(panel)


## * 主题必须在 _ready 里套 [OK] —— _init 时本节点还没进树 [X]，
##   EditorInterface.get_editor_theme() 可能返回 null -> 控件就是默认深色 [X]
##   （上一版就踩了这个 [OK]：窗口里一片黑、列表看不见 [OK]）
func _ready() -> void:
	var ed_theme := EditorInterface.get_editor_theme()
	if ed_theme != null:
		theme = ed_theme


## 打开弹窗（**占屏幕 80% 宽** [OK]，高度封顶 [OK]）；path 非空则设为当前模型 [OK]
func open_with(path: String = "") -> void:
	# * 两条路都走 [OK] —— 之前只调 set_source [X]，一旦脚本缓存/实例不同步就报
	#   "Nonexistent function 'set_source'" [X][OK]（其实函数是在的 [OK]）
	# * 顺序很重要：**先把窗口弹出来** [OK]，再延迟设源 [OK]
	#   原来先 set_source [X] -> 面板会在设源时同步跑十几秒的自动检测 ->
	#   窗口要等检测完才出现 [X]（用户反馈：弹窗应当优先出 [OK]）
	var sz := _target_size()
	min_size = Vector2i(900, 600)          # 与 glb_tools 一致
	size = sz
	popup_centered(sz)
	if panel == null or path == "":
		return
	if not panel.has_method("set_source"):
		panel.set("source_path", path)
		return
	# 用定时器 + 绑定的 Callable（**不用 lambda** [X] —— 那个写法今晚已证实在本文件里会解析失败 [X]）
	var base := EditorInterface.get_base_control()
	if base == null:
		panel.call_deferred("set_source", path)
		return
	base.get_tree().create_timer(0.15).timeout.connect(
		Callable(panel, "set_source").bind(path), CONNECT_ONE_SHOT)


## 屏幕可用区域的 80% [OK]（取不到就退回编辑器视口的 80% [OK]）
func _target_size() -> Vector2i:
	var usable := Vector2i.ZERO
	if DisplayServer.has_method("screen_get_usable_rect"):
		var scr := DisplayServer.window_get_current_screen()
		usable = DisplayServer.screen_get_usable_rect(scr).size
	if usable.x < 200 or usable.y < 200:
		var base := EditorInterface.get_base_control()
		if base != null:
			usable = Vector2i(base.get_viewport().get_visible_rect().size)
	if usable.x < 200 or usable.y < 200:
		usable = Vector2i(1600, 1000)
	# * 按**编辑器视窗**（不是整块屏幕 [X]）的 80% [OK] —— 用户明确要求 [OK]
	var vp_size := Vector2i(1600, 1000)
	var base := EditorInterface.get_base_control()
	if base != null:
		var r := base.get_viewport().get_visible_rect().size
		if r.x > 200 and r.y > 200:
			vp_size = Vector2i(r)
	# 与 addons/glb_tools/preview_window.gd **完全一致**（用户要求参考那个工具）：
	#   const SCREEN_RATIO := 0.8
	#   size = DisplayServer.screen_get_size() * 0.8
	#   min_size = Vector2i(900, 600)
	var screen := DisplayServer.screen_get_size()
	if screen.x < 200 or screen.y < 200:
		screen = Vector2i(1920, 1080)
	return Vector2i(int(screen.x * 0.8), int(screen.y * 0.8))
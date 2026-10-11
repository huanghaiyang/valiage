# ============================================================================
# 文件：scripts/settings/settings_input.gd
# 职责：按键改绑的"纯逻辑层" —— 只做 InputMap 读写 + 绑定表的编解码，
#       不建 UI、不持有节点、不碰文件路径 ✓（所以能脱离场景树直接单测 ✓）。
# 所属系统：设置系统 scripts/settings/
#   · game_settings.gd  GameSettings（autoload 总控：启动时调用本文件还原按键 ✓）
#   · settings_menu.gd  SettingsMenu（"操作"页的按键表，改键捕获也在这里 ✓）
#   · settings_store.gd SettingsStore（设置值仓库：本文件通过形参 store 读写 ✓）
#   · settings_schema.gd SettingsSchema（玩家可见设置项表；**不含**绑定表 ✗）
#   · settings_apply.gd SettingsApply（把设置应用到引擎；按键由本文件负责，不走它 ✓）
#
# 关键依赖：
#   · InputMap        —— 引擎全局静态输入映射。改动**立即对所有脚本生效** ✓
#   · ProjectSettings —— 读 "input/<action>" 拿项目默认绑定（恢复默认的权威来源 ✓）
#   · store（形参，无类型标注 ✗）—— 实际是 SettingsStore 实例（推测：故意不标类型，
#                        既避免脚本间硬依赖、也方便单测塞替身 ✓）
#   · OS.get_keycode_string() —— 键码 → 本地化可读键名
#   · GameSettings（autoload）—— 启动时在 store 读盘之后调 load_bindings() 还原按键 ✓，
#                        且**必须先于** SettingsApply.apply_all() ✓（其它系统可能按动作名读绑定；
#                        game_settings.gd 里也标注了这条顺序不可调换 ✓）
#   · SettingsMenu._make_keybindings_section() —— 用 game_actions()/current_text() 铺界面 ✓
#
# 对外接口（全部是 static ✓ 无需实例化 ✗）：
#   is_rebindable(action) -> bool           该动作允不允许玩家改键
#   game_actions() -> Array                 按键表要显示的动作（已排序）
#   event_text(ev) -> String                单个事件 → 可读文字（如 "Ctrl+K"）
#   current_text(action) -> String          动作当前绑定 → 可读文字（多个用"、"连）
#   rebind(store, action, ev) -> Dictionary 改绑（改 InputMap + 立刻落盘）
#   reset_action(store, action) -> bool     单个动作恢复项目默认
#   reset_all(store) -> int                 挨个恢复项目默认（当前仓库里没有调用点 ✓）
#   save_bindings(store) -> int             把当前 InputMap 全部存进设置
#   load_bindings(store) -> int             用设置里的绑定覆盖 InputMap
#
# 已知的坑（动这个文件之前先看这里）：
#   1. InputMap 的改动**不会自动持久化** ✗ —— 本文件存在的全部理由就是自己存、自己还原 ✓
#   2. rebind()/reset_action()/reset_all() 会立刻写盘，是**不可撤销**的副作用 ✗；
#      真要二次确认，请由调用方（菜单）弹窗，本层不做 UI ✗
#   3. save_bindings() **只序列化 InputEventKey** ✗ → 鼠标/手柄绑定重启后会丢（详见该函数）
#   4. 存档里用动作名当键：跨版本重命名/删除动作会让该条静默失配（load_bindings 直接跳过 ✓）
#   5. 编辑器里跑单测时项目自定义动作**不存在** ✗（tests/test_settings.gd 因此自建临时动作 ✓）
#   6. 绑定表是"全存全还"：project.godot 改了默认键之后，老存档会把玩家按键盖回旧值 ✗
#      （可通过"恢复默认"救回来 ✓）
# ============================================================================


@tool
class_name SettingsInput
extends RefCounted
## 按键改绑（操作 InputMap ✓ 逻辑可单测 ✓）
##
## 关键难点 ✓：**InputMap 的改动不会自动持久化** ✗ ——
## 所以绑定的存档由我们自己负责：存进设置 store 的 "input/bindings" ✓，
## 启动时由 GameSettings 调 load_bindings() 还原 ✓。

# ==================== 常量与存储键 ====================
# 绑定表在设置文件里的落脚点：写进 user://settings.cfg 的 [input] 段、bindings 键 ✓
# （SettingsStore.save() 会把 "a/b" 这类键拆成 [a] 段的 b ✓）
# 它**不是** SettingsSchema 里声明的设置项 ✗ —— schema 只管玩家可见条目；
# 所以在"从未改过键"时 store.get_value() 返回的是 null（而不是默认值 ✓），
# load_bindings() 正是靠这个区分"没存过"与"存过但是空的" ✓
# ⚠ 改这个字符串 = 所有老存档的绑定静默失效 ✗（键名对不上 → 读回 null → 不还原，也不报错 ✗）
const STORE_KEY := "input/bindings"

# ==================== 动作过滤与枚举 ====================
## 不参与改键的动作：引擎内置的 ui_* 与编辑器专用动作 ✓
##
## 参数 action：InputMap 里的动作名（如 "move_forward" / "ui_cancel"）。
## 返回：true = 允许玩家改键；false = 不给改（列进按键表只会误导玩家 ✗）。
## 副作用：无（纯判断 ✓，可以随便调 ✓）。
##
## 为什么这两类必须挡掉：
##   · ui_* 是 Godot 内置 UI 系统真正消费的动作（菜单导航/确认/取消）——
##     玩家把它改掉之后，设置菜单、对话框、物品栏可能当场没法用 ✗；
##   · spatial_editor/* 与 editor/* 只存在于编辑器的输入映射里，运行时根本用不到 ✗。
## 注意：这里是**前缀匹配**，项目自定义动作若起名 "ui_xxx" 会被顺带禁掉 ✗
##       （推测：项目里没有这种命名 ✓）。
static func is_rebindable(action: String) -> bool:
	if action.begins_with("ui_"):
		return false
	# 编辑器专用动作只在编辑器的输入映射里存在，运行时玩家按不到 ✗
	# 两个前缀都要判：3D 视口的导航动作是 spatial_editor/*，其余编辑器快捷键是 editor/* ✓
	if action.begins_with("spatial_editor/") or action.begins_with("editor/"):
		return false
	return true


## 游戏自己的动作（按键表就显示这些 ✓）
##
## 返回：动作名数组（元素是 String），已按字典序排序 ✓；只含 is_rebindable() 为 true 的动作。
## 副作用：无（只读 InputMap 的全局动作表 ✓，不实例化任何东西 ✓）。
##
## 取值来源：InputMap.get_actions() 是引擎的全局静态表 —— 含 project.godot 的 input/ 段，
##           以及运行时用 add_action() 临时加的动作 ✓。
## 为什么排序：让菜单顺序与引擎内部注册顺序彻底脱钩 ✓ ——
##           否则 project.godot 里条目顺序一变，玩家找同一个键就得重新扫一遍 ✗。
## 注意：编辑器里跑单测时项目自定义动作**不加载** ✗（tests/test_settings.gd 因此自造临时动作 ✓），
##       所以本函数在编辑器里返回的集合可能与实际运行不同 —— 别在测试里断言"必须有某动作" ✗。
static func game_actions() -> Array:
	var out: Array = []
	for a in InputMap.get_actions():
		# 引擎给的元素是 StringName ✓：先统一转成 String，
		# 后面的 begins_with() 判断与 sort() 排序行为才稳定（避免两种字符串类型混用 ✗，推测）
		var action := String(a)
		if is_rebindable(action):
			out.append(action)
	out.sort()
	return out


# ==================== 按键文字（纯显示层） ====================
## 一个事件的可读名字："W" / "空格" / "Ctrl+Shift+K" / "鼠标左键"
##
## 参数 ev：任意 InputEvent。已支持 键盘 / 鼠标键 / 手柄键 / 手柄轴，其余类型走 ev.as_text() 兜底 ✓。
## 返回：给玩家看的短文字；**不会是空串**（最差也能拿到引擎的 as_text() ✓），可直接塞进按钮文字 ✓。
## 副作用：无（不读不写 InputMap，纯函数 ✓，可单测 ✓）。
## 调用时机：current_text() 内部、rebind() 构造返回值、单测断言（tests/test_settings.gd ✓）。
##
## ★ 关键设计：键码优先取 physical_keycode（物理位置），只有它为 0 才退回 keycode（字符）✓。
##   physical 表示"键盘上哪个位置"，与键盘布局无关 —— AZERTY/Dvorak 玩家换布局后，
##   游戏里的前进键仍显示在原来的物理位置 ✓；只认 keycode 会跟着布局漂移 ✗。
##   存盘（save_bindings）、还原（load_bindings）、菜单捕获新键（SettingsMenu._input）都是同一口径 ✓，
##   这几处必须保持一致，否则会出现"显示是一个键、按下去却是另一个键"的鬼故事 ✗。
## 注意：修饰键固定按 Ctrl→Shift→Alt→Meta 的顺序拼 ✓（只影响显示；存盘存的是四个独立布尔位 ✓）。
## 注意：不判断 pressed/echo —— 这里只关心"这个事件是什么键"，与是否按下无关 ✓。
static func event_text(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var mods := ""
		if k.ctrl_pressed: mods += "Ctrl+"
		if k.shift_pressed: mods += "Shift+"
		if k.alt_pressed: mods += "Alt+"
		if k.meta_pressed: mods += "Meta+"
		# ★ 物理键优先：physical_keycode 是"键位"（跨布局稳定），keycode 是"字符"（跟着布局变）
		#   它为 0 说明该事件只填了 keycode（手写事件/引擎内部事件可能如此）→ 这时才退回 keycode ✓
		var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode
		return mods + OS.get_keycode_string(code)
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return "鼠标左键"
			MOUSE_BUTTON_RIGHT: return "鼠标右键"
			MOUSE_BUTTON_MIDDLE: return "鼠标中键"
			_: return "鼠标键 %d" % int((ev as InputEventMouseButton).button_index)
	if ev is InputEventJoypadButton:
		return "手柄键 %d" % int((ev as InputEventJoypadButton).button_index)
	if ev is InputEventJoypadMotion:
		return "手柄轴 %d" % int((ev as InputEventJoypadMotion).axis)
	# 兜底：触摸/屏幕拖拽/输入动作等其它事件直接交给引擎自带的 as_text() ✓
	# 宁可显示一个生硬的英文名，也绝不让界面因为没见过的类型崩掉 ✗
	return ev.as_text()


## 某动作当前的按键文字（多个就顿号连起来 ✓）
##
## 参数 action：动作名（动作不存在也不会崩：InputMap 返回空数组 ✓）。
## 返回：该动作所有绑定事件的可读文字，用"、"连接；一个都没有时返回"（未绑定）"✓。
## 副作用：无（只读 InputMap ✓）。
## 调用时机：① 菜单铺按键表时的初始按钮文字 ② 改键后刷新按钮文字
##           ③ 单测用它断言"InputMap 真的被改掉了"（tests/test_settings.gd 的改键端到端用例 ✓）。
## 注意：这里按**多个**事件展示 ✓ —— rebind() 之后确实只剩一个绑定 ✓，
##       但项目默认给同一动作绑多个键很常见（方向键 + WASD ✓），全部显示出来才诚实 ✓。
static func current_text(action: String) -> String:
	var names := PackedStringArray()
	for ev in InputMap.action_get_events(action):
		names.append(event_text(ev))
	if names.is_empty():
		return "（未绑定）"
	return "、".join(names)


# ==================== 改绑 / 恢复默认 ====================
## 改绑：先清掉旧绑定再写新的（单一绑定便于玩家理解 ✓）
##
## 参数 store：设置仓库（SettingsStore 实例；形参故意不标类型，方便单测塞替身 ✓）。
## 参数 action：要改的动作名。
## 参数 ev：新的按键事件（菜单传的是 InputEventKey ✓；鼠标键事件也收 ✓，但存不下来，见 save_bindings）。
## 返回 Dictionary：
##   · 被拒时 {"ok": false, "message": "该动作不允许改键：<动作名>"}
##   · 成功时 {"ok": true, "action": <动作名>, "text": <新绑定的可读文字>, "saved": <本次落盘的动作条数>}
## 副作用（三件，且都不可撤销 ✗）：
##   ① 改全局 InputMap（对所有脚本、所有在跑的逻辑立即生效 ✓）
##   ② 内部调 save_bindings() → 立刻写 user://settings.cfg ✓
##   ③ 触发 SettingsStore.changed 信号 ✓
## 调用时机：设置菜单捕获到新键时（SettingsMenu._input 的改键分支 ✓）。
## 注意：调用方**必须判 ok** ✗，否则被拒的改键会被当成功显示（菜单目前判了 ✓）。
## 注意：不要假设还能"还原"回改之前 —— 旧绑定已被 erase，只能靠恢复默认/再改一次 ✓。
static func rebind(store, action: String, ev: InputEvent) -> Dictionary:
	# 双重保险：菜单理论上只列出可改键动作 ✓，但这是公开 static 接口（单测/别的系统也会直接调 ✓）
	# → 入口再挡一次，避免有人从代码里把 ui_cancel 之类的动作改掉 ✗
	if not is_rebindable(action):
		return {"ok": false, "message": "该动作不允许改键：%s" % action}
	# 先 erase 再 add，而不是直接 add：后者会让新旧绑定**叠加**，
	# 玩家按老键仍然触发 → 会被当成 bug 报上来 ✗（单一绑定是刻意的产品选择 ✓）
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, ev)
	# 立刻落盘 ✓：InputMap 是全局静态状态，改了不存就等于重启后失效 ✗；
	# 这里同步保存，玩家关菜单/崩溃/强杀都不会丢 ✓
	var saved := save_bindings(store)
	return {"ok": true, "action": action, "text": event_text(ev), "saved": saved}


## 单个动作恢复项目默认 ✓（从 project.godot 的 input/<action> 读回来 ✓）
##
## 参数 store：设置仓库。参数 action：动作名。
## 返回：true = 已恢复并已落盘；false = 没恢复（动作不存在，或项目根本没给这个动作设默认绑定）。
## 副作用：改 InputMap + 写盘（save_bindings ✓）；同样不可撤销（玩家当前的改键会被覆盖 ✗）。
## 调用时机：按键表每行的"恢复默认"按钮（SettingsMenu 的按键表构建处 ✓）。
## 注意：默认绑定的**唯一权威是 project.godot** ✓ —— 千万不要在本文件里再抄一份默认键表 ✗，
##       两份表迟早漂移，而且换版本时没人知道该信谁 ✗。
static func reset_action(store, action: String) -> bool:
	# 动作可能只存在于 project.godot 而当前 InputMap 里没有（运行时临时加的、被删掉的）
	# → 直接失败返回 false ✓，不要顺手 add_action 造一个新动作 ✗（那会污染全局输入映射）
	if not InputMap.has_action(action):
		return false
	InputMap.action_erase_events(action)
	# project.godot 里的 input/<action> 是一个 Array[InputEvent] ✓ —— 这就是项目默认绑定 ✓
	var defs: Array = ProjectSettings.get_setting("input/" + action, [])
	if defs.is_empty():
		# ⚠ 走到这里时上面已经把事件清空了 ✗：项目没给默认绑定的动作，"恢复默认"的净效果是变成没绑定 ✗
		#   返回 false 让调用方知道"没恢复成默认"✓（推测：这是可接受的取舍，这类动作很少 ✓）
		return false
	for e in defs:
		# 防御性过滤：数组理论上全是 InputEvent ✓，但 project.godot 可能被手改/被插件写脏 ✗
		if e is InputEvent:
			InputMap.action_add_event(action, e)
	# 恢复默认也要落盘 ✓，否则"恢复默认"只在本次会话生效，重启又变回玩家的自定义键 ✗
	save_bindings(store)
	return true


## 把所有可改键动作挨个恢复项目默认 ✓
##
## 参数 store：设置仓库。
## 返回：成功恢复的动作个数（0 ~ 项目动作数）；调用方可用它显示"已恢复 N 项"✓。
## 副作用：批量改 InputMap + **每个动作各写一次盘** ✗（动作数少时可忽略 ✓；
##         若将来动作上百，应改成"全部改完只 save_bindings 一次" ✗ 这一版没做 ✓）。
## 调用时机：当前仓库里**没有调用点**（推测：预留给"全部恢复默认"入口 ✓）；单测可直接 call() ✓。
## 注意：失败的动作（项目没默认绑定的）不计入返回值 ✓，但仍会被 reset_action 里的 erase 清空 ✗。
static func reset_all(store) -> int:
	var n := 0
	# game_actions() 返回的是 Array（元素 Variant）→ 显式 String(a) 转成 String 才能匹配 String 形参 ✓
	for a in game_actions():
		if reset_action(store, String(a)):
			n += 1
	return n


# ==================== 持久化：存盘格式与还原 ====================
## 把所有动作的按键写进设置 ✓（只存改过的更省事，这里全存便于跨版本稳定 ✓）
##
## 参数 store：设置仓库（写 STORE_KEY = "input/bindings"）。
## 返回：写进 data 的**动作条数**（= 当前可改键动作数，不是事件数 ✗）。
## 副作用：store.set_value() → 立即落盘 user://settings.cfg + 发 changed 信号 ✓；
##         本文件自己不碰文件路径 ✓（cfg_path 由 SettingsStore 决定，测试可换成临时路径 ✓）。
## 调用时机：rebind()、reset_action() 内部；也可由调用方主动调（例如退出前兜底 ✓）。
##
## 存盘格式（两层嵌套的纯数据，无引擎对象 ✓，ConfigFile 能直接序列化 ✓）：
##   { "<动作名>": [ {"code": int, "ctrl": bool, "shift": bool, "alt": bool, "meta": bool}, ... ] }
## 为什么存"键码 + 四个布尔位"而不是 OS.get_keycode_string() 的文字 ✗：
##   文字受系统语言/键盘布局影响，跨机器、跨语言都不可靠 ✗；数字键码 + 修饰位才能无损往返 ✓。
## 为什么"全存"而不是只存改过的动作 ✓：
##   全存让存档自描述 —— load_bindings() 可以无条件按存档覆盖，不必去猜"哪些算改过"✓；
##   代价：project.godot 里改了默认键之后，老存档会把旧键重新盖回来 ✗（玩家需"恢复默认"✓）。
## ⚠ 已知限制：这里**只序列化 InputEventKey** ✗ —— 鼠标键/手柄事件会被静默丢掉 ✗，
##   于是 rebind() 虽然接受鼠标键，但重启后那个绑定不会还原（推测：项目默认绑定以键盘为主，暂时可接受 ✓）。
static func save_bindings(store) -> int:
	var data := {}
	for a in InputMap.get_actions():
		var action := String(a)
		# 与 game_actions() 用同一套过滤 ✓ —— 保证"存下去的键"和"按键表里显示/可改的键"永远一致 ✓，
		# 不要在这里另写一份过滤条件 ✗（两份迟早不一致，存档里就会多出玩家改不了的幽灵条目）
		if not is_rebindable(action):
			continue
		var codes: Array = []
		for ev in InputMap.action_get_events(action):
			# 只收键盘事件 ✗：鼠标/手柄不序列化（见函数头的"已知限制"）
			if ev is InputEventKey:
				var k := ev as InputEventKey
				# code 取物理键优先 ✓，与 event_text()/load_bindings() 同一口径 ✓
				codes.append({
					"code": int(k.physical_keycode if k.physical_keycode != 0 else k.keycode),
					"ctrl": k.ctrl_pressed, "shift": k.shift_pressed,
					"alt": k.alt_pressed, "meta": k.meta_pressed,
				})
		# 空数组也照样写入 ✓：它表示"这个动作当前没有绑定"，与"键根本不存在"是两种状态 ✓
		# （但 load_bindings() 遇到空数组会跳过 → "故意解绑"重启后保不住 ✗。
		#  推测：当前 UI 没有解绑操作，所以碰不到这个坑 ✓）
		data[action] = codes
	# set_value 会立刻落盘 + 发信号 ✓；绑定表不参与 SettingsSchema 的默认值体系 ✓，是额外寄存的键 ✓
	store.set_value(STORE_KEY, data)
	return data.size()


## 启动时还原 ✓ 返回还原了几个动作。
## 逐个键与当前 InputMap 比对，**一样就不动** ✓ —— 避免把项目默认意外覆盖掉。
##
## 参数 store：设置仓库。返回：被覆盖的动作个数（0 = 没有存档或存档不可用 ✓）。
## 副作用：改全局 InputMap；**不写盘** ✓（只是读存档，不会制造/刷新存档 ✓）。
## 调用时机：GameSettings._ready() 的启动还原阶段 ✓（紧跟在 store.load_from_disk() 之后）；
##           **必须先于** SettingsApply.apply_all() ✓ —— 因为其它系统可能按动作名读绑定，
##           顺序反了会有一批逻辑按旧键生效 ✗（game_settings.gd 里同样标注了顺序不可调换 ✓）。
## 容错（一条都别删，改这里要小心 ✗）：
##   · 从未改过键 → store 里没有这个键 → get_value 返回 null ✓ → 直接返回 0，不动任何绑定 ✓
##   · 存档不是 Dictionary（老版本/被手改）→ 当成"没存过"✓，不崩 ✗
##   · 存档里的动作在当前引擎里不存在（版本删掉/改名了）→ skip ✓，不新建动作 ✗
##   · 某动作的 codes 是空数组 → skip ✓，保留项目默认 ✓
## 幂等：同一份数据反复调用结果相同 ✓（所以可以拿存档"重放"✓，不会越还越乱 ✓）。
## ⚠ 注意：上面第二行"逐个键与当前 InputMap 比对、一样就不动"的说法**与当前实现不符** ✗ ——
##   实现是整组直接覆盖（早期那个"相同就跳过"的优化已被移除，原因见函数体内注释 ✓）。以代码为准 ✓。
static func load_bindings(store) -> int:
	# 用 Variant 接住再判类型 ✓：老存档 / 被手改的 cfg 可能不是 Dictionary ✗
	# （SettingsStore.get_value 对"非 schema 键"在从未存过时返回 null ✓）
	var data: Variant = store.get_value(STORE_KEY)
	if not (data is Dictionary):
		return 0
	var applied := 0
	for action in (data as Dictionary).keys():
		var name := String(action)
		# 存档可能来自旧版本（动作被改名/删掉）或另一台机器 → 跳过，而不是凭空 add_action 造一个 ✗
		# （造出来的动作没有任何系统在读，只会让按键表多出一行垃圾 ✗）
		if not InputMap.has_action(name):
			continue
		var codes: Array = (data as Dictionary)[action]
		# 空数组 = 上次这个动作就没有绑定 → 跳过，保留项目默认 ✓
		# （取舍：无法保留"故意解绑"的状态 ✗；当前 UI 也没有解绑操作 ✓）
		if codes.is_empty():
			continue
		# 先把事件全部建好，再一次性替换 ✓ —— 不要边遍历边改 InputMap ✗
		# （中途出错会留下半套绑定，比"整组失败"更难查 ✗）
		var events: Array = []
		for c in codes:
			var d: Dictionary = c
			# 一律重建为 InputEventKey ✓：与新存盘格式（只存键盘）对齐 ✓
			# → 鼠标/手柄绑定在这里天然还不了（它们从来没被存过 ✗，见 save_bindings）
			var ev := InputEventKey.new()
			# 只写 physical_keycode、不写 keycode ✓：与存盘时"物理键优先"的口径一致 ✓
			# （keycode 留 0 → 推测引擎会按物理键推导/匹配 ✓；本文件显示时也优先读 physical ✓）
			# d.get(...) 带默认值：老存档缺字段时退化成键码 0（该事件实际无效，但不会崩 ✓）
			ev.physical_keycode = int(d.get("code", 0))
			ev.ctrl_pressed = bool(d.get("ctrl", false))
			ev.shift_pressed = bool(d.get("shift", false))
			ev.alt_pressed = bool(d.get("alt", false))
			ev.meta_pressed = bool(d.get("meta", false))
			events.append(ev)
		# 直接应用 ✓（保存下来的绑定就是权威；重复应用是幂等的 ✓）
		# 早期版本写了"与当前相同就跳过"的优化 ✗ —— 那个分支很脆（events 类型/顺序稍有差异判断就错 ✗），去掉。
		# 补充：这里刻意不做任何"有没有差异"的比对 ✓ —— 存档就是权威，
		#       玩家改过键后重启必须以存档为准 ✓；比对只会引入"某些情况下不还原"的隐蔽 bug ✗。
		InputMap.action_erase_events(name)
		for ev in events:
			InputMap.action_add_event(name, ev)
		applied += 1
	return applied
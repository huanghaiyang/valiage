extends Node
## 法杖系统（自动加载单例）—— 同时也是**装备系统**的核心数据层
##
## 设计参考常见游戏的装备策略：
##   * 法杖是**武器**，单手，**占 1 个装备格**（`SLOT_STAFF`），不与工具/材料混放；
##   * 装备格固定 1 格 —— 换杖就是把旧的换下来，不做背包堆叠；
##   * 每根法杖有**元素属性**（火/冰/奥术/自然/神圣），决定它的动态效果；
##   * 元素可以被"长老祝福"改写（见 elder 系统），所以效果不是烘死在模型里的。
##
## 职责：
##   1. 登记所有法杖定义（id / 名称 / 元素 / 网格 / 展示参数）
##   2. 记录已解锁与当前装备
##   3. 广播信号给 UI 与手持挂点
##   4. **存档**：已解锁 / 当前装备 / 长老石 / 被祝福改写的元素 -> `user://equipment.cfg`
##
## 两条入口（都能改装备，最后都汇到 `equip()`）：
##   * `F` 装备面板（game_ui.gd，点名字装备）
##   * `Q` / `Shift+滚轮` 世界内快速切换（main.gd -> `cycle()`）

## ===========================================================================
## 【补充】依赖 / 对外接口 / 已知的坑 —— 与上面的"职责"块配合阅读
##
## 自动加载名：`StaffSystem`（见 project.godot 的 [autoload]，路径 /root/StaffSystem）。
##   调用方一律用 `get_node_or_null("/root/StaffSystem")` 弱引用（player.gd / main.gd /
##   game_ui.gd 都是这么写的），所以单例缺失时游戏照常跑、只是法杖功能静默失效。
## 关键依赖：
##   * `OS.get_cmdline_user_args()` —— 只返回命令行里 `--` **之后**的参数，所以开关必须写成
##     `godot --headless --path . -- --verify`（main.gd 就是这么用的），写 `godot --fresh` 读不到。
##   * `ConfigFile` + `user://equipment.cfg` —— 唯一的持久化载体（见文件末尾"存档"段）。
##   * `res://assets/models/crafted/*.glb` —— 通过 `defs[id]["model"]` 交给 held_staff.gd 加载。
## 对外接口（谁在用）：
##   * 信号：`staff_equipped` → player.gd 的 _on_staff_equipped()；`equipment_changed` →
##     game_ui.gd 的装备面板；`staff_unlocked` / `stone_gained` 目前**全项目无人连接**（预留）。
##   * 查询：`equipped` / `equipped_element` / `base_element`（main.gd 自检直接 get("base_element")）、
##     `get_def()` / `element_of()` / `element_name()` / `element_ids()` / `element_color()` /
##     `display_name()` / `owned_list()` / `all_ids()` / `owned_index()` / `is_blessed()` /
##     `stone_count()`。
##   * 写入：`unlock()` / `unlock_all()` / `equip()` / `unequip()` / `cycle()` / `bless()` /
##     `add_stone()`；以及 `save_game()` / `load_game()`（自检会临时改 `save_path` + `save_enabled`）。
## 已知的坑（改这个文件前先看这四条）：
##   1. 读档发生在 `_ready()`，此时 player 与 UI 都还没实例化，所以 `load_game()` 全程
##      `_loading = true` 且**不发** `staff_equipped`。"读档后手里没模型"要去
##      player.gd 的 `_attach_held_staff` 查，别在这里找原因。
##   2. `defs[id]["element"]` 会被 `bless()` 与 `load_game()` **就地改写**，所以"原始元素"
##      只能读 `base_element`；用 `element_of()` 拿到的是被祝福之后的值。
##   3. `Element` 枚举的整数值会直接写进存档（`blessed` 段存 int），因此枚举只能**往后追加**，
##      不能插队、不能重排，否则老存档的祝福会串到别的元素上。
##   4. `equip("")` 是"收起法杖"的**合法**用法（unequip 就是它的别名），不是错误；
##      `equipped == ""` 时 `display_name("")` 返回"空手"，UI 依赖这个约定。
## 相关文档：docs/法杖握持与朝向系统-技术文档.md —— 握点/朝向/坐标系都在 held_staff.gd 与
##   character_profile.gd 里，本文件**不涉及任何坐标计算**，只负责数据与存档。
## ===========================================================================

# ==================== 信号 ====================

## 装备（或收起）广播：参数 id 是新的法杖 id，**空串 "" 表示收起**。
## 消费方：player.gd 的 _on_staff_equipped()（收到就重挂手持模型）。
## 发射点：equip() 与 bless()（后者只在被祝福的正是当前装备那根时）。
## 注意：元素编号**不在参数里**，player 侧要另读 `equipped_element`；
##   读档路径**不会**发这个信号（见 load_game 的说明）。
signal staff_equipped(id: String)
## 单根法杖被解锁（获得）时广播，参数 id 是被解锁的 id。
## 发射点：unlock() 与 unlock_all()（全解锁时逐根发）。
## 注意：批量解锁期间 UI **不要**连这个信号去重建列表 —— 请连 equipment_changed（只发一次）。
##   当前项目内没有连接方；emit 方式用的是 emit_signal("名字") 字符串形式。
signal staff_unlocked(id: String)
## 长老石增加时广播：id = 这颗石头属于哪根法杖，amount = **本次增加量**（int，正常为正）。
## 只由 add_stone() 发射；当前项目内没有连接方（UI 走 equipment_changed 后自己读 stone_count()）。
signal stone_gained(id: String, amount: int)
## 批量变化后的**单次**通知（UI 只连这个，避免全解锁时重建 146 次列表）
signal equipment_changed()

# ==================== 常量与配置 ====================

## 装备格标识：整个装备系统目前只有这一个格。
## 用字符串而不是枚举 —— 它既要当游戏内的字典 key，也要进存档字段，字符串最省转换。
## 装备格：法杖是武器，单占一格
const SLOT_STAFF := "staff"
## 装备格数量：当前写死 1 —— 法杖是单手武器，一次只能拿一根，换杖就是替换。
## 改动效果：改成 >1 之后，存档里单个 `equipped` 字段的格式、以及所有只认"手里一根"的
##   消费方（player.gd 的手持挂点、game_ui.gd 的装备格）都要同步改，不要只改这里。
const SLOT_COUNT := 1

## 开发阶段便利：默认**拥有全部法杖**，方便逐根试效果与截图。
## 命令行加 `--no-dev-unlock` 关掉（验证"找长老领杖"的正常流程时用）。
const DEV_UNLOCK_ALL := true
## 存档路径；`--fresh` 跳过读取（不删档）
const SAVE_PATH := "user://equipment.cfg"

# ==================== 元素定义 ====================

## 元素枚举（顺序即"元素编号"）。
## 为什么 NONE 必须留在第 0 位：`equipped_element`、`defs[id]["element"]`、存档里的 `blessed`
##   都用 int 表示元素，0 天然就是"无元素 / 空手"的默认值（查不到元素时也回落到它）。
## 为什么不能重排：这些整数值会被写进 user://equipment.cfg（见 save_game 的 blessed 段），
##   顺序是对外契约 —— 只能往末尾追加新元素（现有 EARTH=6 / STORM=7 就是后来加的）。
enum Element { NONE, FIRE, ICE, ARCANE, NATURE, HOLY, EARTH, STORM }

## 元素 id -> 中文显示名。与枚举分开存的原因：显示名会被 UI / 日志直接取用，
## 单独一张表便于以后换文案或做本地化，而枚举保持纯数值语义。
## 注意：必须覆盖枚举的**每一项**；查不到时 element_name() 会返回 "?" 兜底（不报错）。
const ELEMENT_NAMES := {
	Element.NONE: "无",
	Element.FIRE: "火",
	Element.ICE: "冰",
	Element.ARCANE: "奥术",
	Element.NATURE: "自然",
	Element.HOLY: "神圣",
	Element.EARTH: "大地",
	Element.STORM: "雷",
}

## 元素配色（粒子 / 自发光 / HUD 都用它，保持全局一致）
const ELEMENT_COLORS := {
	Element.NONE: Color(0.80, 0.80, 0.82),
	Element.FIRE: Color(1.00, 0.42, 0.10),
	Element.ICE: Color(0.42, 0.78, 1.00),
	Element.ARCANE: Color(0.68, 0.42, 1.00),
	Element.NATURE: Color(0.42, 0.78, 0.32),
	Element.HOLY: Color(1.00, 0.92, 0.55),
	Element.EARTH: Color(0.72, 0.54, 0.30),
	Element.STORM: Color(0.55, 0.75, 1.00),
}

# ==================== 运行时状态 ====================

## 法杖定义表。key = id，值是描述字典。
## 逐根精做时会不断往这里加；`model` 指向 assets/models/crafted/ 下的 GLB。
var defs: Dictionary = {}
## 已解锁的 id
var unlocked: Dictionary = {}
## 当前装备的 id（"" = 空手）
var equipped := ""
## 当前生效的元素（可能是长老祝福改写过的）
var equipped_element: int = Element.NONE
## 用于长老系统的"长老石"，每根杖单独计数（升级/祝福消耗）
var stones: Dictionary = {}
## id -> 登记时的原始元素（祝福改写过 defs 里的值，所以必须另存一份基准）
var base_element: Dictionary = {}
## id -> 被祝福改成过的元素（只有改写过的才在这里，存档只写这部分）
var blessed: Dictionary = {}
## 读档期间为 true：此时不写文件，也不发装备信号
var _loading := false
## 存档总开关。`--fresh`（本次会话不读档）与 `--verify`（自检不许改玩家存档）
## 都会把它关掉；自检里的"存档往返"会临时打开并换成一个临时路径来测。
var save_enabled := true
## 存档路径（做成变量，自检才能指向临时文件而不是玩家存档）
var save_path := SAVE_PATH


# ==================== 生命周期 ====================

## 自动加载单例的入口：登记内置法杖 -> 解析命令行 -> 读档 -> （开发模式）全解锁并拿一根在手上。
##
## 参数：无（Node 回调）。返回值：无。
## 调用时机：游戏启动时由 autoload 机制调用，**早于主场景实例化** —— 所以此刻 player 与 UI
##   都还不存在，读档不能指望有听众（这就是"读档不发 staff_equipped"约定的来源）。
## 副作用（按顺序）：写 defs/base_element；可能改 unlocked / equipped / equipped_element；
##   读档期间 _loading=true 不写文件，之后（含开发模式全解锁）都可能写 user://equipment.cfg；
##   打印两行 [staff] 日志（自检与截图核对用）。
## 注意：
##   * 命令行开关只认 `--` 之后的参数（OS.get_cmdline_user_args() 的语义，见下）；
##   * 开发模式全解锁只在 unlock_all() 末尾发**一次** equipment_changed（避免 UI 重建 N 次），
##     但紧接着的 equip(first) 会再发一次 staff_equipped（这一次是给 player 的）。
func _ready() -> void:
	_register_builtin()
	# 自动加载单例的 _ready() 早于主场景，所以这里读档时 player/UI 都还不存在。
	# 正因为如此，读档**不发** `staff_equipped`：player 挂载手持法杖时会主动
	# 去读 `equipped`（见 player.gd 的 _attach_held_staff），UI 也在自己的 setup 里读一次。
	# 只认 `godot ... -- --fresh` 这种写法：get_cmdline_user_args() 只返回 `--` 之后的参数，
	# 写成 `godot --fresh` 一个都读不到（main.gd 的 --verify 也是同一套约定）。
	var args := OS.get_cmdline_user_args()
	# --fresh：本次会话不读档；--verify：无人值守自检，不许碰玩家存档。语义不同，见下两行。
	var fresh := "--fresh" in args
	# 开发模式默认**开**：DEV_UNLOCK_ALL 为 true 且没有被显式 --no-dev-unlock 关掉。
	# （DEV_UNLOCK_ALL 是编译期常量，要长期关掉得改上面那个 const，不是一个运行时开关。）
	var dev := DEV_UNLOCK_ALL and not ("--no-dev-unlock" in args)
	# 关键：这两个开关必须**先于** load_game() 生效，否则自检会先读进玩家存档、再把它写回去。
	# 注意这里关掉的是"写档"开关，"读档"只受 fresh 控制 —— --verify 仍会读真实存档以便自查。
	if fresh or "--verify" in args:
		save_enabled = false
	# --fresh 连读都不读：文件本身保留（不删档），只是本次会话从空状态开始。
	if not fresh:
		load_game()
	print("[staff] 登记 %d 根，读档=%s，写档=%s，开发全解锁=%s，当前装备=%s"
			% [defs.size(), "跳过(--fresh)" if fresh else save_reason(),
			   save_path if save_enabled else "关闭(自检/--fresh 不写玩家存档)",
			   str(dev), equipped if equipped != "" else "空"])
	# 开发模式放在**读档之后**执行：这样 --no-dev-unlock 时能真实还原"只有解锁过的那几根"。
	if dev:
		# unlock_all() 的返回值是**本次新解锁**数量（读档已拥有的不计入），日志靠它区分"新得/已有"。
		var added := unlock_all()
		# 空手的话顺手拿一根在手里，否则"拥有 146 根但看不见"没有测试价值
		# 空手（存档里没装备过 / 读档失败）时顺手拿第一根在手里：
		# 否则开发模式下"拥有全部但手里空的"看不出任何效果，截图与试玩都没有价值。
		if equipped == "":
			var first := first_id()
			if first != "":
				equip(first)
		print("[staff] 开发模式：新解锁 %d 根 -> 已拥有 %d/%d，当前装备=%s"
				% [added, unlocked.size(), defs.size(),
				   display_name(equipped) if equipped != "" else "空"])


## 给启动日志用的一句话：说明这次读档读的是哪个文件、有没有存档。
## 参数：无。返回值：String —— 存档文件存在时返回路径，否则返回字面量 "无存档"。
## 副作用：无（只查 FileAccess.file_exists，**不读文件内容**）。
## 调用时机：只在 _ready() 的启动日志里。
## 注意：不判断文件能否解析 —— 损坏的存档也会返回路径（load_game 会另行 push_warning）。
func save_reason() -> String:
	return save_path if FileAccess.file_exists(save_path) else "无存档"


## 退出兜底：再写一次档。正常流程里每次改动都已立刻落盘，这里是防"某条路径漏写"的保险。
## 参数：无（Node 回调）。返回值：无。
## 副作用：可能写 user://equipment.cfg；`_loading` 或 `save_enabled` 为 false 时是空操作。
## 注意：节点退出树时 player / UI 可能已先销毁，所以这里**不能**发信号 —— 幸好 save_game() 不发。
func _exit_tree() -> void:
	# 兜底：退出时再写一次（正常流程里每次改动都已经立刻落盘）
	save_game()


# ==================== 内置登记表 ====================

## 先登记已经精做完的 6 根（后续逐根追加）
## 法杖登记表。
##
## 旧的低多边形 146 根已按用户要求全部移除（面数过低）。这里是**新风格**的第一根：
## 高精度几何 + PBR 贴图（35756 面，见 .runtime/make_staff_spectrum.py）。
## 后面每做好一根，在这里加一行 reg(...) 即可。
##
## 当前实际登记 **8 根**：spectrum + fantasy_1..7（上面那句"6 根"是历史值，写它时确实只有 6 根）。
## 登记顺序 = 装备面板列表顺序 = cycle() 的切换顺序 = "第几根/N" 的编号依据 —— 改顺序会改 UI 显示。
func _register_builtin() -> void:
	# spectrum 的 scale=1.0 与下面那批的 1.95 口径不同：spectrum 的 GLB 按真实米制导出，
	# 这批 Tripo 模型已在 .runtime/cut_tripo_parts.py 里缩放到真实尺寸（1.75m）并脚底归零。
	# 注意：`scale` 目前**没有任何消费方**（held_staff.gd 只读 "model"），
	# 所以 1.95 现在不影响画面，它只是登记表里的元数据（推测是为早期挂载实现留的）。
	# world_len 同理：reg() 并没有把它写进 defs（详见 reg() 的说明）。
	reg("spectrum", "虹晶法杖", Element.ARCANE,
			"res://assets/models/crafted/staff_spectrum.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.030, "world_len": 1.45})
	# ---- Tripo3D 出的 7 根奇幻法杖 ----
	# 已用 `.runtime/cut_tripo_parts.py` 从"七支并排"的原文件里**逐份切成独立 glb**，
	# 每根都缩放到真实尺寸（1.75m）、脚底归零；贴图另外做过提亮（见 brighten_tripo_tex.py）。
	# DEV_UNLOCK_ALL=true -> 登记即拥有，玩家开局就全有。
	const DIR := "res://assets/models/crafted/"
	var staves := [
		["fantasy_1", "烈焰法杖", Element.FIRE],
		["fantasy_2", "寒霜法杖", Element.ICE],
		["fantasy_3", "藤木法杖", Element.NATURE],
		["fantasy_4", "圣辉法杖", Element.HOLY],
		["fantasy_5", "岩心法杖", Element.EARTH],
		["fantasy_6", "雷暴法杖", Element.STORM],
		["fantasy_7", "秘银法杖", Element.ARCANE],
	]
	# 用"数组 + 循环"而不是逐根 reg()：这七根的展示参数完全一致，循环能把
	# scale/idle_spin/hover 只维护一份；将来要单根特调，就把它从数组里拆出来单独 reg()。
	for e in staves:
		reg(str(e[0]), str(e[1]), int(e[2]),
				DIR + "staff_" + str(e[0]) + ".glb",
				{"scale": 1.95, "idle_spin": 0.20, "hover": 0.030, "world_len": 1.55})


# ==================== 登记与查询 ====================

## 登记一根法杖
## 参数：
##   id      —— 唯一标识（英文/下划线；存档、信号、UI 全用它）
##   display —— 中文显示名（UI 与日志）
##   element —— 初始元素，取 Element 枚举值（int）
##   model   —— res:// 下的 GLB 路径（文件不存在会在加载侧报错，本函数不校验）
##   extra   —— 可选覆盖项：scale / idle_spin / hover / hand（缺省见下面的默认值）
## 返回值：无。
## 副作用：写 defs[id] 与 base_element[id]；**不发信号、不写档**（登记属于启动期行为）。
## 调用时机：只在 _register_builtin() 里调用；对同一个 id 重复 reg() 会静默覆盖旧定义
##   （base_element 也会被一起覆盖，所以"改登记值"会连带改掉祝福的比较基准）。
## 注意事项：
##   * `base_element` 存的是"登记时的原始元素"，因为 bless() / load_game() 会就地改写
##     `defs[id]["element"]` —— 想拿原始值必须读 base_element，不能读 defs。
##   * `extra` 里的 `world_len` 目前**没有被解析、也没有写进 d**，所以
##     held_staff.gd 里 `get_def(id).get("world_len", 默认长度)` 永远回落到默认值。
##     这是登记表与消费方之间的已知不一致（改字段时请一并处理），不是本函数的笔误。
##   * 缺省值含义：scale=1.0（模型缩放倍率）、idle_spin=0.25（待机自转角速度，弧度/秒）、
##     hover=0.03（上下浮动幅度，米）、hand="r"（挂点标识，右手）。
##     调大 idle_spin / hover 会让手持状态更"飘"，调小更稳；三者目前均无消费方（见上一条）。
func reg(id: String, display: String, element: int, model: String, extra: Dictionary = {}) -> void:
	var d := {
		"id": id,
		"name": display,
		"element": element,
		"model": model,
		"scale": float(extra.get("scale", 1.0)),
		"idle_spin": float(extra.get("idle_spin", 0.25)),
		"hover": float(extra.get("hover", 0.03)),
		"hand": str(extra.get("hand", "r")),
	}
	defs[id] = d
	# 单独留一份"登记基准"：上面的 d["element"] 之后可能被 bless()/load_game() 就地改写，
	# 而"祝福回原元素"和 main.gd 自检的还原逻辑都必须有一个没被改过的参照值。
	base_element[id] = element


## 这根法杖**登记过**吗（只查登记表，与"是否已解锁"无关 —— 后者见 is_unlocked()）。
## 参数：id —— 法杖 id。返回值：bool。副作用：无。
func has(id: String) -> bool:
	return defs.has(id)


## 取一根法杖的定义字典。
## 参数：id —— 法杖 id。
## 返回值：Dictionary —— 未登记时返回**空字典 {}**（不是 null，调用方按"空字典"判空即可）。
## 副作用：无（但返回值是 defs 内部字典的**引用** —— GDScript 的 Dictionary 是引用类型，
##   外部改它会直接改到登记表；main.gd 的 _reset_def_elements 正是利用这一点抹掉内存态。
##   只想读不想被连带修改，就自己 duplicate() 一份）。
## 消费方：held_staff.gd 只取其中的 "model" 去加载 GLB。
func get_def(id: String) -> Dictionary:
	return defs.get(id, {})


## 取显示名（UI 与日志用）。
## 参数：id —— 法杖 id；**空串 "" 被特判为 "空手"**（equip("") 的收起态靠这条显示）。
## 返回值：String —— 已登记时取 `defs[id]["name"]`；未登记时**原样返回 id**（便于日志定位错 id），
##   不会报错也不会返回空串。
func display_name(id: String) -> String:
	if id == "":
		return "空手"
	var d: Dictionary = defs.get(id, {})
	return str(d.get("name", id))


## 取一根法杖的**当前**元素（注意：含长老祝福的改写，不是登记时的原值）。
## 参数：id —— 法杖 id。返回值：int（Element 枚举值；未登记时返回 Element.NONE = 0）。
## 副作用：无。想拿原始元素请直接读 `base_element`（见文件头"已知的坑"第 2 条）。
func element_of(id: String) -> int:
	var d: Dictionary = defs.get(id, {})
	return int(d.get("element", Element.NONE))


## 元素 id -> 中文显示名。
## 参数：e —— 元素枚举值（int，调用方通常来自 element_of()）。
## 返回值：String —— 命中 ELEMENT_NAMES 时是中文名；越界/未知值时返回 "?"（不报错）。
func element_name(e: int) -> String:
	return str(ELEMENT_NAMES.get(e, "?"))


## 全部元素（装备面板的筛选行用），按枚举顺序，不含 NONE
## 参数：无。返回值：Array（元素是 int），可直接喂给 owned_list(element)。
## 副作用：无。顺序 = ELEMENT_NAMES 的键序 = 枚举声明顺序（Dictionary 保持插入顺序）。
## 注意：某个元素一根杖都没有时这里**照样**列出来（筛选行会空着，不是错误）。
func element_ids() -> Array:
	var out: Array = []
	for e in ELEMENT_NAMES.keys():
		if int(e) != Element.NONE:
			out.append(int(e))
	return out


## 元素 id -> 统一配色（粒子 / 自发光 / HUD 共用，保证全局一致）。
## 参数：e —— 元素枚举值（int）。返回值：Color；表里没有的值返回 Color.WHITE 兜底。
## 副作用：无（纯查表）。注意 Element.NONE 有自己那套灰白色，不会走到兜底分支。
func element_color(e: int) -> Color:
	return ELEMENT_COLORS.get(e, Color.WHITE)


## 解锁（获得）一根法杖
## 参数：id —— 法杖 id，**必须在 defs 里登记过**（否则只 push_warning 并返回 false）。
## 返回值：bool —— true 表示这次真的新解锁了；已拥有 / 未登记都返回 false。
## 副作用：写 unlocked；发 staff_unlocked + equipment_changed；写档（立刻落盘）。
## 注意：返回 false 有两种完全不同的原因（"本来就有" vs "根本没这根杖"），
##   调用方若要区分得自己先 has(id) —— 当前所有调用方都没有区分。
func unlock(id: String) -> bool:
	if not defs.has(id):
		push_warning("StaffSystem.unlock: 未登记的法杖 id=%s" % id)
		return false
	if unlocked.has(id):
		return false
	unlocked[id] = true
	emit_signal("staff_unlocked", id)
	emit_signal("equipment_changed")
	save_game()
	return true


## 一次解锁全部（开发便利）。返回新解锁的数量。
## 只在这一批结束后发**一次** `equipment_changed`：UI 收到就重建列表，
## 逐根发的话全解锁会触发 146 次重建。
## 参数：无。返回值：int —— 本次**新解锁**的数量（读档时已拥有/之前解锁过的不计入；
##   全都已有则返回 0，此时既不发信号也不写档）。
## 副作用：写 unlocked；逐根发 staff_unlocked；若有新增则补发一次 equipment_changed 并写档。
## 调用时机：只有 _ready() 的开发模式分支会调它；正常游戏流程没有调用方。
func unlock_all() -> int:
	var n := 0
	for id in defs.keys():
		if not unlocked.has(id):
			unlocked[str(id)] = true
			emit_signal("staff_unlocked", str(id))
			n += 1
	if n > 0:
		emit_signal("equipment_changed")
		save_game()
	return n


## 这根法杖**已拥有**吗（与 has() 的"登记过"是两件事：登记 ≠ 解锁）。
## 参数：id —— 法杖 id。返回值：bool。副作用：无。
func is_unlocked(id: String) -> bool:
	return unlocked.has(id)


## 装备：法杖单占一格，装备新杖即替换
## 参数：id —— 法杖 id；**空串 "" 表示收起法杖**（合法输入，等价于 unequip()）。
## 返回值：bool —— true 表示状态真的变了；未解锁（且非空 id）/ 与当前相同都返回 false。
## 副作用：写 equipped 与 equipped_element；发 staff_equipped + equipment_changed；写档。
## 注意：equipped_element 取自 element_of()，拿到的是**被祝福改写之后**的元素，
##   不是 base_element —— 这一点是长老祝福能立刻改配色的前提。
## 调用时机：装备面板点行（game_ui.gd）、开发模式启动兜底、cycle() 内部。
func equip(id: String) -> bool:
	# 空 id 放行（= 收起法杖），非空才要求已解锁：否则"收起"会走进这个分支报假警告。
	if id != "" and not unlocked.has(id):
		push_warning("StaffSystem.equip: %s 尚未解锁" % id)
		return false
	# 同一根杖重复 equip 直接返回：避免 UI 点同一行时白重挂一次模型、白写一次档。
	# 注意这也意味着"元素被祝福后想刷新"不能靠再次 equip 同一 id，得看 bless() 里那条补发路径。
	if id == equipped:
		return false
	equipped = id
	equipped_element = element_of(id) if id != "" else Element.NONE
	emit_signal("staff_equipped", id)
	emit_signal("equipment_changed")
	save_game()
	return true


## 收起法杖（空手）。等价于 equip("")。
## 参数/返回值：无。
## 副作用：同 equip("") —— 发 staff_equipped("")（player 收到会拆掉手持模型）与
##   equipment_changed，并写档；本来就空手时 equip() 会提前返回（不发信号、也不写档）。
## 注意：当前项目内没有调用方（UI 的"空手"行是直接 `equip("")`），保留作为语义化别名。
func unequip() -> void:
	equip("")


## 在已拥有的法杖里前后切换（dir=+1 下一根 / -1 上一根），到头环绕。
## 顺序 = defs 登记顺序（与装备面板列表一致）；空手时从第一根（或最后一根）开始。
## element >= 0 时只在该元素的杖里切换。
## 返回切换后的 id（没得换时返回当前手上这根）。
## 参数：dir —— 方向，只取正负（>0 往后、否则往前），默认 +1；
##   element —— 元素筛选（Element 枚举值），-1（默认）表示不筛，只在"已拥有"里绕。
## 副作用：内部调 equip()，所以会连带发 staff_equipped + equipment_changed 并写档。
## 注意：列表为空（一根都没解锁）时直接返回 equipped（可能是 ""），不抛异常；
##   当前项目内 main.gd **没有**实际调用点（"Q / Shift+滚轮 换杖"只出现在提示文案里，
##   世界内还没有绑键），所以它目前只能靠 call("cycle") 或自检触发。
func cycle(dir: int = 1, element: int = -1) -> String:
	var list := owned_list(element)
	if list.is_empty():
		return equipped
	# 归一到 ±1：调用方可能把滚轮方向那种大数字（-120 / +120）直接传进来，这里只关心正负。
	var step := 1 if dir > 0 else -1
	var i := list.find(equipped)
	# find 返回 -1 = 当前手上这根不在筛选结果里（空手，或开着元素筛选而手上是别的元素）：
	# 这时从列表头（往后翻）或列表尾（往前翻）起步，语义上等于"绕一圈进入这个列表"。
	if i < 0:
		i = 0 if step > 0 else list.size() - 1
	else:
		# 必须用 posmod 而不是 %：GDScript 的 % 对负数返回负数（-1 % 5 == -1），
		# 从第一根往前翻时会算出负下标，list[i] 直接报越界。
		i = posmod(i + step, list.size())
	equip(str(list[i]))
	return equipped


# ==================== 长老祝福与长老石 ====================

## 长老祝福：改写当前法杖的元素（模型不变，动态效果与配色变）
## 参数：id —— 法杖 id（未登记则静默 return）；element —— 新元素，取 Element 枚举值。
## 返回值：无（void）。失败也不报错、不返回状态 —— 调用方无需判断返回值。
## 副作用：就地写 `defs[id]["element"]`（所以 base_element 必须留作基准）；维护 blessed 名单；
##   若被祝福的正是当前装备那根，则同步 equipped_element 并补发 staff_equipped（player 会重挂）；
##   无论祝福哪根都发 equipment_changed，最后写档。
## 注意：只改"元素"不改模型 —— 手上模型的外观刷新走 staff_equipped 这条路，别指望它自己重载 GLB。
func bless(id: String, element: int) -> void:
	if not defs.has(id):
		return
	# 判断"是否算祝福"必须拿 base_element 比，不能拿 defs 里的当前值比 ——
	# 后者可能已经被上一次祝福改过，用它比会把"改回原元素"误判成"又一次祝福"。
	if int(base_element.get(id, Element.NONE)) == element:
		blessed.erase(id)          # 祝福回原元素等于没祝福
	else:
		blessed[id] = element
	# 就地改写登记表：所有走 element_of()/element_color() 的地方立刻拿到新元素，
	# 代价是原始值只剩 base_element 一份备份（上面那行注释说的就是这件事）。
	defs[id]["element"] = element
	# 只有"祝福的正好是手上这根"才需要补发 staff_equipped —— 否则 player 无事可做，
	# 多发一次只会让它白重挂一次模型。UI 列表的刷新统一由 equipment_changed 负责。
	if equipped == id:
		equipped_element = element
		emit_signal("staff_equipped", id)
	emit_signal("equipment_changed")
	save_game()


## 这根杖当前的元素是不是被祝福改过的（UI 上加个标记）
## 参数：id —— 法杖 id（未登记 / 没祝福过都返回 false，不报错）。返回值：bool。
## 副作用：无（只读 blessed 字典，不看 defs 里的当前值）。
## 注意：这是"相对登记值被改过"的意思 —— 祝福回原元素时 bless() 会把它 erase 掉，
##   所以"元素等于基准值"与"没被祝福过"在这里是同一状态。
func is_blessed(id: String) -> bool:
	return blessed.has(id)


## 给某根法杖加"长老石"（升级 / 祝福用的消耗资源，每根杖单独计数）。
##
## 参数：id —— 法杖 id（**不校验是否登记**，未知 id 也会被记一笔）；amount —— 增加量，int，
##   默认 1；传负数就是扣（当前没有调用方这么做，也没有"余额不足时拒绝"的保护）。
## 返回值：无。
## 副作用：写 stones[id]；发 stone_gained（带上本次增加量）与 equipment_changed；写档。
## 调用时机：预留给长老系统的交互回调 —— 当前项目内暂无调用方（要用得走 call("add_stone", …)）。
func add_stone(id: String, amount: int = 1) -> void:
	# 缺省按 0 兜底：一颗长老石都没有的杖根本不在 stones 字典里，所以每次都要 get(id, 0)。
	stones[id] = int(stones.get(id, 0)) + amount
	emit_signal("stone_gained", id, amount)
	emit_signal("equipment_changed")
	save_game()


## 取某根法杖的长老石数量。
## 参数：id —— 法杖 id。返回值：int —— 从没加过时返回 0（stones 里没有这个 key 的常态）。
## 副作用：无。消费方：game_ui 的装备面板（每行显示"×N"）。
func stone_count(id: String) -> int:
	return int(stones.get(id, 0))


# ==================== 列表与索引 ====================

## 已拥有的 id（按 defs 登记顺序，装备面板、`cycle()`、"第几根"都用它）；
## element >= 0 时只列该元素的
## 参数：element —— 元素筛选（Element 枚举值）；默认 -1 = 不筛。
## 返回值：Array —— 已解锁的 id（元素是 String），按 defs 登记顺序；可能为空数组。
## 副作用：无（只读 unlocked / defs）。
## 注意：元素比较走 element_of()，也就是**按祝福后的当前元素**筛选 —— 祝福改元素后，
##   这根杖会换到另一个筛选分类里去（这是有意为之，UI 与手上效果才能一致）。
## 消费方：game_ui 的装备面板（列表与计数）、cycle()、owned_index()。
func owned_list(element: int = -1) -> Array:
	var out: Array = []
	for id in defs.keys():
		if not unlocked.has(id):
			continue
		if element >= 0 and element_of(str(id)) != element:
			continue
		out.append(id)
	return out


## 保留旧名（历史兼容；当前项目内已无调用方）
## 参数/返回值：等价于 owned_list()（不筛元素）；返回 Array（String id），顺序同登记顺序。
func unlocked_list() -> Array:
	return owned_list()


## 已拥有里的第几根（1 起；未拥有返回 0），装备格显示 "12/146" 用
## 参数：id —— 法杖 id。返回值：int（1..N；不在已拥有列表里则 0）。
## 副作用：无。
## 注意：编号与分母都按**完整**的 owned_list() 算，跟面板上的元素筛选视图无关；
##   分母建议直接用 owned_list().size()，不要写死文案里的数字。
func owned_index(id: String) -> int:
	var list := owned_list()
	var i := list.find(id)
	return i + 1 if i >= 0 else 0


## 登记表里的第一根 id（= `_ready()` 开发模式下"手上先拿哪根"的依据）。
## 参数：无。返回值：String —— 登记表为空时返回 ""（不报错）。
## 副作用：无。
## 注意：顺序来自 `defs.keys()`，也就是 **reg 的调用顺序**；
##   调换 _register_builtin() 里的登记顺序会直接改变"第一根"是谁。
func first_id() -> String:
	var keys := defs.keys()
	return str(keys[0]) if not keys.is_empty() else ""


## 全部 id（调试/图鉴用）
## 参数：无。返回值：Array（元素 String），顺序 = 登记顺序。
## 副作用：无（但它是 defs.keys() 的结果，属于引用型视图语义 —— 只读，别就地排序）。
## 注意：这是**全部登记项**，不是"已拥有"；要有/总数请用 owned_list().size() 与 all_ids().size()。
func all_ids() -> Array:
	return defs.keys()


# ============================================================ 存档

## 写档：已解锁 / 当前装备 / 长老石 / 被祝福改写的元素。
## 每次改动都立刻写 —— 146 个字符串的 ConfigFile 不到 1ms，
## 换成延时写只会多出一堆"退出时丢档"的边界情况。
## 参数/返回值：无。
## 副作用：写 `save_path`（默认 user://equipment.cfg，自检会临时改成临时文件）；
##   失败只 push_warning，不抛异常、不打断游戏。
## 注意：`unlocked.keys()` 是以**数组**写进去的，读回来可能是 Array 也可能是
##   PackedStringArray（见 load_game 的类型判断）；登记表本身不入档。
func save_game() -> void:
	# 两个护栏：_loading 期间（load_game 内部）不写回，避免"读档顺手把半成品内存态覆盖存档"；
	# save_enabled=false（--fresh / --verify）时整个写档动作停掉，保护玩家的真实存档。
	if _loading or not save_enabled:
		return
	var cf := ConfigFile.new()
	# 只存四样"可变状态"：解锁列表 / 当前装备 / 长老石 / 被祝福改写的元素。
	# 登记表（defs / base_element）属于代码，不进存档 —— 加新法杖只需改 _register_builtin()。
	cf.set_value("equipment", "unlocked", unlocked.keys())
	cf.set_value("equipment", "equipped", equipped)
	cf.set_value("equipment", "stones", stones)
	cf.set_value("equipment", "blessed", blessed)
	# ConfigFile.save 返回 Error；失败只 warn 不抛，存档问题不该打断游戏。
	var err := cf.save(save_path)
	if err != OK:
		push_warning("[staff] 存档写入失败 %s err=%d" % [save_path, err])


## 读档。返回是否真的读到东西（没有存档文件时返回 false，不是错误）。
##
## 全程 `_loading = true`：一是不写回文件，二是**不发 `staff_equipped`**。
## 自动加载单例跑 `_ready()` 时 player 与 UI 都还没建，发了也没人听；
## 这两边都在自己初始化时主动读一次 `equipped`。
## 参数：无（路径用成员 `save_path`）。
## 返回值：bool —— true = 真的读到东西；false = 没有存档文件**或**文件损坏
##   （两种都按"新档"处理，不是致命错误，调用方照常继续即可）。
## 副作用：写 unlocked / equipped / equipped_element / stones / blessed，并按 blessed 就地改写
##   `defs[id]["element"]`；**不写档、不发任何信号**；最后打印一行统计。
## 注意：登记表里已经没有的 id 会被**丢弃**（老存档可能还带着被删掉的那 146 根 id）；
##   "已解锁"是装备生效的前提 —— equipped 不在 unlocked 里时会被忽略（宁可可空手）。
func load_game() -> bool:
	# 没有文件不算错误：首次启动走的就是这条路径，返回 false 让调用方照常继续。
	if not FileAccess.file_exists(save_path):
		return false
	var cf := ConfigFile.new()
	# 解析失败（半截文件 / 被手工改坏）也当新档：宁可丢存档，也不能让启动卡在这里。
	if cf.load(save_path) != OK:
		push_warning("[staff] 存档损坏，按新档处理：%s" % save_path)
		return false
	# 从这里到函数末尾 _loading 一直是 true：既挡住中途写档，也保证不发 staff_equipped
	# （此刻 player / UI 还没建，发了也没人听）。
	_loading = true
	var arr: Variant = cf.get_value("equipment", "unlocked", [])
	# Array 与 PackedStringArray 都要收：ConfigFile 存进去的是 Array，
	# 但某些读写路径会回成 PackedStringArray，少判一种就会静默丢档。
	if arr is Array or arr is PackedStringArray:
		for id in arr:
			# 校验 id 是否还登记着：登记表换过（比如那 146 根被移除）后，老存档里会留下
			# 现在不存在的 id，直接跳过而不是记进 unlocked，免得 UI 里出现没名字的幽灵条目。
			if defs.has(str(id)):
				unlocked[str(id)] = true
	var eq := str(cf.get_value("equipment", "equipped", ""))
	# 只有"确实已解锁"才认这个装备 id：存档被改坏或登记表换过时，宁可可空手，
	# 也不要装着一根不存在的杖（player 那边会因为找不到 model 而 warn）。
	if eq != "" and unlocked.has(eq):
		equipped = eq
		equipped_element = element_of(eq)
	var st: Variant = cf.get_value("equipment", "stones", {})
	# 类型不符就维持空字典（不 merge、不报错）：stones 只是计数器，丢了不影响进游戏。
	if st is Dictionary:
		stones = st
	var bl: Variant = cf.get_value("equipment", "blessed", {})
	# 祝福是"登记表之外的改写"，必须重新贴回 defs[id]["element"]：只写 blessed 的话
	# element_of() / element_color() 会拿回原始元素，UI 与手上效果就看不到祝福。
	if bl is Dictionary:
		for id in (bl as Dictionary).keys():
			# 同上：登记表里已经没有的 id 直接丢弃，避免 defs[str(id)] 凭空建出幽灵条目。
			if not defs.has(str(id)):
				continue
			var e := int((bl as Dictionary)[id])
			# 就地把当前元素改掉，并记一份"被祝福过"的名单（is_blessed / UI 星号靠它）。
			defs[str(id)]["element"] = e
			blessed[str(id)] = e
	# 必须在打印之前放开：打印之后的任何写档都不该被这次读档挡住。
	_loading = false
	print("[staff] 读档 %s：已拥有 %d 根，装备=%s，长老石 %d 根有，祝福过 %d 根"
			% [save_path, unlocked.size(), equipped if equipped != "" else "空",
			   stones.size(), blessed.size()])
	return true

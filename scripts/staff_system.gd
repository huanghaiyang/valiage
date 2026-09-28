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
## 三条入口（都能改装备，最后都汇到 `equip()`）：
##   * `F` 装备面板（game_ui.gd，点名字装备）
##   * `Q` / `Shift+滚轮` 世界内快速切换（main.gd -> `cycle()`）
##   * 长老赠杖（elders.gd -> `unlock()` + main.gd 里自动 `equip()`）

signal staff_equipped(id: String)
signal staff_unlocked(id: String)
signal stone_gained(id: String, amount: int)
## 批量变化后的**单次**通知（UI 只连这个，避免全解锁时重建 146 次列表）
signal equipment_changed()

## 装备格：法杖是武器，单占一格
const SLOT_STAFF := "staff"
const SLOT_COUNT := 1

## 开发阶段便利：默认**拥有全部法杖**，方便逐根试效果与截图。
## 命令行加 `--no-dev-unlock` 关掉（验证"找长老领杖"的正常流程时用）。
const DEV_UNLOCK_ALL := true
## 存档路径；`--fresh` 跳过读取（不删档）
const SAVE_PATH := "user://equipment.cfg"

enum Element { NONE, FIRE, ICE, ARCANE, NATURE, HOLY, EARTH, STORM }

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


func _ready() -> void:
	_register_builtin()
	# 自动加载单例的 _ready() 早于主场景，所以这里读档时 player/UI 都还不存在。
	# 正因为如此，读档**不发** `staff_equipped`：player 挂载手持法杖时会主动
	# 去读 `equipped`（见 player.gd 的 _attach_held_staff），UI 也在自己的 setup 里读一次。
	var args := OS.get_cmdline_user_args()
	var fresh := "--fresh" in args
	var dev := DEV_UNLOCK_ALL and not ("--no-dev-unlock" in args)
	if fresh or "--verify" in args:
		save_enabled = false
	if not fresh:
		load_game()
	print("[staff] 登记 %d 根，读档=%s，写档=%s，开发全解锁=%s，当前装备=%s"
			% [defs.size(), "跳过(--fresh)" if fresh else save_reason(),
			   save_path if save_enabled else "关闭(自检/--fresh 不写玩家存档)",
			   str(dev), equipped if equipped != "" else "空"])
	if dev:
		var added := unlock_all()
		# 空手的话顺手拿一根在手里，否则"拥有 146 根但看不见"没有测试价值
		if equipped == "":
			var first := first_id()
			if first != "":
				equip(first)
		print("[staff] 开发模式：新解锁 %d 根 -> 已拥有 %d/%d，当前装备=%s"
				% [added, unlocked.size(), defs.size(),
				   display_name(equipped) if equipped != "" else "空"])


func save_reason() -> String:
	return save_path if FileAccess.file_exists(save_path) else "无存档"


func _exit_tree() -> void:
	# 兜底：退出时再写一次（正常流程里每次改动都已经立刻落盘）
	save_game()


## 先登记已经精做完的 6 根（后续逐根追加）
## 法杖登记表。
##
## 旧的低多边形 146 根已按用户要求全部移除（面数过低）。这里是**新风格**的第一根：
## 高精度几何 + PBR 贴图（35756 面，见 .runtime/make_staff_spectrum.py）。
## 后面每做好一根，在这里加一行 reg(...) 即可。
func _register_builtin() -> void:
	reg("spectrum", "虹晶法杖", Element.ARCANE,
			"res://assets/models/crafted/staff_spectrum.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.030, "world_len": 1.45})


## 登记一根法杖
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
	base_element[id] = element


func has(id: String) -> bool:
	return defs.has(id)


func get_def(id: String) -> Dictionary:
	return defs.get(id, {})


func display_name(id: String) -> String:
	if id == "":
		return "空手"
	var d: Dictionary = defs.get(id, {})
	return str(d.get("name", id))


func element_of(id: String) -> int:
	var d: Dictionary = defs.get(id, {})
	return int(d.get("element", Element.NONE))


func element_name(e: int) -> String:
	return str(ELEMENT_NAMES.get(e, "?"))


## 全部元素（装备面板的筛选行用），按枚举顺序，不含 NONE
func element_ids() -> Array:
	var out: Array = []
	for e in ELEMENT_NAMES.keys():
		if int(e) != Element.NONE:
			out.append(int(e))
	return out


func element_color(e: int) -> Color:
	return ELEMENT_COLORS.get(e, Color.WHITE)


## 解锁（获得）一根法杖
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


func is_unlocked(id: String) -> bool:
	return unlocked.has(id)


## 装备：法杖单占一格，装备新杖即替换
func equip(id: String) -> bool:
	if id != "" and not unlocked.has(id):
		push_warning("StaffSystem.equip: %s 尚未解锁" % id)
		return false
	if id == equipped:
		return false
	equipped = id
	equipped_element = element_of(id) if id != "" else Element.NONE
	emit_signal("staff_equipped", id)
	emit_signal("equipment_changed")
	save_game()
	return true


func unequip() -> void:
	equip("")


## 在已拥有的法杖里前后切换（dir=+1 下一根 / -1 上一根），到头环绕。
## 顺序 = defs 登记顺序（与装备面板列表一致）；空手时从第一根（或最后一根）开始。
## element >= 0 时只在该元素的杖里切换。
## 返回切换后的 id（没得换时返回当前手上这根）。
func cycle(dir: int = 1, element: int = -1) -> String:
	var list := owned_list(element)
	if list.is_empty():
		return equipped
	var step := 1 if dir > 0 else -1
	var i := list.find(equipped)
	if i < 0:
		i = 0 if step > 0 else list.size() - 1
	else:
		i = posmod(i + step, list.size())
	equip(str(list[i]))
	return equipped


## 长老祝福：改写当前法杖的元素（模型不变，动态效果与配色变）
func bless(id: String, element: int) -> void:
	if not defs.has(id):
		return
	if int(base_element.get(id, Element.NONE)) == element:
		blessed.erase(id)          # 祝福回原元素等于没祝福
	else:
		blessed[id] = element
	defs[id]["element"] = element
	if equipped == id:
		equipped_element = element
		emit_signal("staff_equipped", id)
	emit_signal("equipment_changed")
	save_game()


## 这根杖当前的元素是不是被祝福改过的（UI 上加个标记）
func is_blessed(id: String) -> bool:
	return blessed.has(id)


func add_stone(id: String, amount: int = 1) -> void:
	stones[id] = int(stones.get(id, 0)) + amount
	emit_signal("stone_gained", id, amount)
	emit_signal("equipment_changed")
	save_game()


func stone_count(id: String) -> int:
	return int(stones.get(id, 0))


## 已拥有的 id（按 defs 登记顺序，装备面板、`cycle()`、"第几根"都用它）；
## element >= 0 时只列该元素的
func owned_list(element: int = -1) -> Array:
	var out: Array = []
	for id in defs.keys():
		if not unlocked.has(id):
			continue
		if element >= 0 and element_of(str(id)) != element:
			continue
		out.append(id)
	return out


## 保留旧名（verify 与 elders 在用）
func unlocked_list() -> Array:
	return owned_list()


## 已拥有里的第几根（1 起；未拥有返回 0），装备格显示 "12/146" 用
func owned_index(id: String) -> int:
	var list := owned_list()
	var i := list.find(id)
	return i + 1 if i >= 0 else 0


func first_id() -> String:
	var keys := defs.keys()
	return str(keys[0]) if not keys.is_empty() else ""


## 全部 id（调试/图鉴用）
func all_ids() -> Array:
	return defs.keys()


# ============================================================ 存档

## 写档：已解锁 / 当前装备 / 长老石 / 被祝福改写的元素。
## 每次改动都立刻写 —— 146 个字符串的 ConfigFile 不到 1ms，
## 换成延时写只会多出一堆"退出时丢档"的边界情况。
func save_game() -> void:
	if _loading or not save_enabled:
		return
	var cf := ConfigFile.new()
	cf.set_value("equipment", "unlocked", unlocked.keys())
	cf.set_value("equipment", "equipped", equipped)
	cf.set_value("equipment", "stones", stones)
	cf.set_value("equipment", "blessed", blessed)
	var err := cf.save(save_path)
	if err != OK:
		push_warning("[staff] 存档写入失败 %s err=%d" % [save_path, err])


## 读档。返回是否真的读到东西（没有存档文件时返回 false，不是错误）。
##
## 全程 `_loading = true`：一是不写回文件，二是**不发 `staff_equipped`**。
## 自动加载单例跑 `_ready()` 时 player 与 UI 都还没建，发了也没人听；
## 这两边都在自己初始化时主动读一次 `equipped`。
func load_game() -> bool:
	if not FileAccess.file_exists(save_path):
		return false
	var cf := ConfigFile.new()
	if cf.load(save_path) != OK:
		push_warning("[staff] 存档损坏，按新档处理：%s" % save_path)
		return false
	_loading = true
	var arr: Variant = cf.get_value("equipment", "unlocked", [])
	if arr is Array or arr is PackedStringArray:
		for id in arr:
			if defs.has(str(id)):
				unlocked[str(id)] = true
	var eq := str(cf.get_value("equipment", "equipped", ""))
	if eq != "" and unlocked.has(eq):
		equipped = eq
		equipped_element = element_of(eq)
	var st: Variant = cf.get_value("equipment", "stones", {})
	if st is Dictionary:
		stones = st
	var bl: Variant = cf.get_value("equipment", "blessed", {})
	if bl is Dictionary:
		for id in (bl as Dictionary).keys():
			if not defs.has(str(id)):
				continue
			var e := int((bl as Dictionary)[id])
			defs[str(id)]["element"] = e
			blessed[str(id)] = e
	_loading = false
	print("[staff] 读档 %s：已拥有 %d 根，装备=%s，长老石 %d 根有，祝福过 %d 根"
			% [save_path, unlocked.size(), equipped if equipped != "" else "空",
			   stones.size(), blessed.size()])
	return true

extends Node
## 法杖系统（自动加载单例）
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

signal staff_equipped(id: String)
signal staff_unlocked(id: String)
signal stone_gained(id: String, amount: int)

## 装备格：法杖是武器，单占一格
const SLOT_STAFF := "staff"
const SLOT_COUNT := 1

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


func _ready() -> void:
	_register_builtin()


## 先登记已经精做完的 6 根（后续逐根追加）
func _register_builtin() -> void:
	reg("ice", "冰晶法杖", Element.ICE, "res://assets/models/crafted/staff_ice.glb",
			{"scale": 1.0, "idle_spin": 0.35, "hover": 0.035})
	reg("flame", "烈焰法杖", Element.FIRE, "res://assets/models/crafted/staff_flame.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.045})
	reg("gem", "宝石法杖", Element.ARCANE, "res://assets/models/crafted/staff_gem.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.030})
	reg("thorn", "荆棘法杖", Element.NATURE, "res://assets/models/crafted/staff_thorn.glb",
			{"scale": 1.0, "idle_spin": 0.15, "hover": 0.025})
	reg("beast", "兽首法杖", Element.EARTH, "res://assets/models/crafted/staff_beast.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("angel", "圣羽法杖", Element.HOLY, "res://assets/models/crafted/staff_angel.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.050})
	# ---- batch A ----
	reg("lamp", "提灯法杖", Element.FIRE, "res://assets/models/crafted/staff_lamp.glb",
			{"scale": 1.0, "idle_spin": 0.12, "hover": 0.030})
	reg("crescent", "新月法杖", Element.ARCANE, "res://assets/models/crafted/staff_crescent.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.040})
	reg("trident", "三叉法杖", Element.STORM, "res://assets/models/crafted/staff_trident.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.032})
	reg("swordstaff", "剑杖", Element.HOLY, "res://assets/models/crafted/staff_swordstaff.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	# ---- batch B ----
	reg("skull", "骷髅法杖", Element.EARTH, "res://assets/models/crafted/staff_skull.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("mushroom", "蘑菇法杖", Element.NATURE, "res://assets/models/crafted/staff_mushroom.glb",
			{"scale": 1.0, "idle_spin": 0.14, "hover": 0.026})
	reg("cage", "晶笼法杖", Element.ARCANE, "res://assets/models/crafted/staff_cage.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.042})
	reg("tentacle", "触手法杖", Element.ICE, "res://assets/models/crafted/staff_tentacle.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	# ---- batch C ----
	reg("lantern", "提灯杖", Element.FIRE, "res://assets/models/crafted/staff_lantern.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.038})
	reg("lotus", "莲花法杖", Element.NATURE, "res://assets/models/crafted/staff_lotus.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.030})
	reg("hourglass", "沙漏法杖", Element.ARCANE, "res://assets/models/crafted/staff_hourglass.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.034})
	reg("anchor", "锚形法杖", Element.STORM, "res://assets/models/crafted/staff_anchor.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.032})
	# ---- batch D ----
	reg("plume", "羽翎法杖", Element.STORM, "res://assets/models/crafted/staff_plume.glb",
			{"scale": 1.0, "idle_spin": 0.34, "hover": 0.044})
	reg("sunfire", "曜阳法杖", Element.FIRE, "res://assets/models/crafted/staff_sunfire.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("starorb", "星辉法杖", Element.HOLY, "res://assets/models/crafted/staff_starorb.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("voidclaw", "幽爪法杖", Element.EARTH, "res://assets/models/crafted/staff_voidclaw.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	# ---- batch E ----
	reg("talon", "魔爪法杖", Element.EARTH, "res://assets/models/crafted/staff_talon.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.032})
	reg("gild", "鎏金法杖", Element.ARCANE, "res://assets/models/crafted/staff_gild.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.038})
	reg("goldvine", "金藤法杖", Element.NATURE, "res://assets/models/crafted/staff_goldvine.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.030})
	reg("frostfire", "霜焰法杖", Element.ICE, "res://assets/models/crafted/staff_frostfire.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.040})
	# ---- batch F ----
	reg("sapphire", "苍蓝法杖", Element.ICE, "res://assets/models/crafted/staff_sapphire.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.034})
	reg("axestaff", "战斧法杖", Element.EARTH, "res://assets/models/crafted/staff_axestaff.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.028})
	reg("emberspire", "炎棘法杖", Element.FIRE, "res://assets/models/crafted/staff_emberspire.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.036})
	reg("sungold", "阳金法杖", Element.HOLY, "res://assets/models/crafted/staff_sungold.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	# ---- batch G ----
	reg("demon", "魔首法杖", Element.EARTH, "res://assets/models/crafted/staff_demon.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	reg("bramble", "棘冠法杖", Element.NATURE, "res://assets/models/crafted/staff_bramble.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.032})
	reg("violetflame", "幽焰法杖", Element.ARCANE, "res://assets/models/crafted/staff_violetflame.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("thunder", "雷矛法杖", Element.STORM, "res://assets/models/crafted/staff_thunder.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	# ---- batch H ----
	reg("scythe", "藤镰法杖", Element.NATURE, "res://assets/models/crafted/staff_scythe.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("stonemace", "玄石法杖", Element.EARTH, "res://assets/models/crafted/staff_stonemace.glb",
			{"scale": 1.0, "idle_spin": 0.14, "hover": 0.026})
	reg("knotwood", "木灵法杖", Element.NATURE, "res://assets/models/crafted/staff_knotwood.glb",
			{"scale": 1.0, "idle_spin": 0.12, "hover": 0.024})
	reg("prism", "棱镜法杖", Element.HOLY, "res://assets/models/crafted/staff_prism.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.044})
	# ---- batch I ----
	reg("frostbone", "霜骨法杖", Element.ICE, "res://assets/models/crafted/staff_frostbone.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	reg("duskcrystal", "暮晶法杖", Element.STORM, "res://assets/models/crafted/staff_duskcrystal.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("roseflame", "玫焰法杖", Element.ARCANE, "res://assets/models/crafted/staff_roseflame.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("crown", "王冠法杖", Element.HOLY, "res://assets/models/crafted/staff_crown.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	# ---- batch J ----
	reg("frostbrand", "霜锋法杖", Element.ICE, "res://assets/models/crafted/staff_frostbrand.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("thornclaw", "棘爪法杖", Element.NATURE, "res://assets/models/crafted/staff_thornclaw.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("amberlantern", "琥珀灯法杖", Element.FIRE, "res://assets/models/crafted/staff_amberlantern.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.040})
	reg("emerald", "翠玉法杖", Element.NATURE, "res://assets/models/crafted/staff_emerald.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("starfall", "星陨法杖", Element.ARCANE, "res://assets/models/crafted/staff_starfall.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.044})
	reg("woodcrown", "木冠法杖", Element.EARTH, "res://assets/models/crafted/staff_woodcrown.glb",
			{"scale": 1.0, "idle_spin": 0.14, "hover": 0.026})
	# ---- batch K ----
	reg("moonstone", "月石法杖", Element.ICE, "res://assets/models/crafted/staff_moonstone.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("idol", "霜偶法杖", Element.ICE, "res://assets/models/crafted/staff_idol.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	reg("verdant", "碧焰法杖", Element.NATURE, "res://assets/models/crafted/staff_verdant.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("spikedclub", "银棱法杖", Element.EARTH, "res://assets/models/crafted/staff_spikedclub.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("waraxe", "双刃战杖", Element.EARTH, "res://assets/models/crafted/staff_waraxe.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	reg("nightstar", "夜星法杖", Element.STORM, "res://assets/models/crafted/staff_nightstar.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	# ---- batch L ----
	reg("icebloom", "冰蕊法杖", Element.ICE, "res://assets/models/crafted/staff_icebloom.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("treefather", "树父法杖", Element.NATURE, "res://assets/models/crafted/staff_treefather.glb",
			{"scale": 1.0, "idle_spin": 0.14, "hover": 0.026})
	reg("goldloop", "金环法杖", Element.EARTH, "res://assets/models/crafted/staff_goldloop.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("pearl", "珍珠法杖", Element.HOLY, "res://assets/models/crafted/staff_pearl.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("voidhammer", "虚空法杖", Element.ARCANE, "res://assets/models/crafted/staff_voidhammer.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("paleblaze", "冥焰法杖", Element.ICE, "res://assets/models/crafted/staff_paleblaze.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	# ---- batch M ----
	reg("cindergold", "翠金法杖", Element.NATURE, "res://assets/models/crafted/staff_cindergold.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.034})
	reg("blackbriar", "玄棘法杖", Element.ICE, "res://assets/models/crafted/staff_blackbriar.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("silvergild", "银金法杖", Element.HOLY, "res://assets/models/crafted/staff_silvergild.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("royalcrystal", "紫蓝法杖", Element.ICE, "res://assets/models/crafted/staff_royalcrystal.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("bluetrident", "碧叉法杖", Element.STORM, "res://assets/models/crafted/staff_bluetrident.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("jadeorb", "翠球星杖", Element.NATURE, "res://assets/models/crafted/staff_jadeorb.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	# ---- batch N ----
	reg("tealflame", "青焰法杖", Element.ICE, "res://assets/models/crafted/staff_tealflame.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("lavender", "紫晶法杖", Element.ARCANE, "res://assets/models/crafted/staff_lavender.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("tealring", "青环法杖", Element.ICE, "res://assets/models/crafted/staff_tealring.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("palebranch", "素枝法杖", Element.HOLY, "res://assets/models/crafted/staff_palebranch.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("jadeleaf", "蓝叶法杖", Element.NATURE, "res://assets/models/crafted/staff_jadeleaf.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("duskrose", "暮玫法杖", Element.ARCANE, "res://assets/models/crafted/staff_duskrose.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	# ---- batch O ----
	reg("bonelance", "骨脊法杖", Element.EARTH, "res://assets/models/crafted/staff_bonelance.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	reg("goldidol", "金偶法杖", Element.HOLY, "res://assets/models/crafted/staff_goldidol.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("starflame", "星焰法杖", Element.ARCANE, "res://assets/models/crafted/staff_starflame.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("bluering", "蓝环法杖", Element.ICE, "res://assets/models/crafted/staff_bluering.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("frostfan", "霜翎法杖", Element.ICE, "res://assets/models/crafted/staff_frostfan.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("warhammer", "战锤法杖", Element.EARTH, "res://assets/models/crafted/staff_warhammer.glb",
			{"scale": 1.0, "idle_spin": 0.14, "hover": 0.026})
	# ---- batch P ----
	reg("stoneblock", "磐石法杖", Element.EARTH, "res://assets/models/crafted/staff_stoneblock.glb",
			{"scale": 1.0, "idle_spin": 0.14, "hover": 0.026})
	reg("twinjewel", "双瞳法杖", Element.ARCANE, "res://assets/models/crafted/staff_twinjewel.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("sunstone", "阳晶法杖", Element.FIRE, "res://assets/models/crafted/staff_sunstone.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("steelblue", "钢蓝法杖", Element.ICE, "res://assets/models/crafted/staff_steelblue.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("azurevine", "蓝藤法杖", Element.STORM, "res://assets/models/crafted/staff_azurevine.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("blackaxe", "黑刃战杖", Element.EARTH, "res://assets/models/crafted/staff_blackaxe.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	# ---- batch Q ----
	reg("darkbloom", "暗华法杖", Element.STORM, "res://assets/models/crafted/staff_darkbloom.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("glacialspear", "冰棱法杖", Element.ICE, "res://assets/models/crafted/staff_glacialspear.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("rosegem", "玫晶法杖", Element.ARCANE, "res://assets/models/crafted/staff_rosegem.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("opal", "欧泊法杖", Element.HOLY, "res://assets/models/crafted/staff_opal.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("amberpearl", "琥珀珠法杖", Element.FIRE, "res://assets/models/crafted/staff_amberpearl.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("frostmace", "霜棱法杖", Element.ICE, "res://assets/models/crafted/staff_frostmace.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	# ---- batch R ----
	reg("banner", "战旗法杖", Element.STORM, "res://assets/models/crafted/staff_banner.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.044})
	reg("brassflame", "黄铜法杖", Element.HOLY, "res://assets/models/crafted/staff_brassflame.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("bonejewel", "骨玉法杖", Element.ARCANE, "res://assets/models/crafted/staff_bonejewel.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("embercage", "赤笼法杖", Element.FIRE, "res://assets/models/crafted/staff_embercage.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("duskblaze", "暮焰法杖", Element.FIRE, "res://assets/models/crafted/staff_duskblaze.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("sunpearl", "阳珠法杖", Element.HOLY, "res://assets/models/crafted/staff_sunpearl.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	# ---- batch S ----
	reg("wingedmace", "翼槌法杖", Element.HOLY, "res://assets/models/crafted/staff_wingedmace.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("dragonfang", "龙牙法杖", Element.ARCANE, "res://assets/models/crafted/staff_dragonfang.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("greatring", "巨环法杖", Element.HOLY, "res://assets/models/crafted/staff_greatring.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("rosecage", "玫笼法杖", Element.ARCANE, "res://assets/models/crafted/staff_rosecage.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("silverclaw", "银爪法杖", Element.ICE, "res://assets/models/crafted/staff_silverclaw.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("sunburst", "曜火法杖", Element.FIRE, "res://assets/models/crafted/staff_sunburst.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	# ---- batch T ----
	reg("blossom", "花冠法杖", Element.NATURE, "res://assets/models/crafted/staff_blossom.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("arrowhead", "箭头法杖", Element.ICE, "res://assets/models/crafted/staff_arrowhead.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	reg("duskthorn", "幽棘法杖", Element.ARCANE, "res://assets/models/crafted/staff_duskthorn.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("emberwreath", "焰环法杖", Element.FIRE, "res://assets/models/crafted/staff_emberwreath.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("palespire", "苍焰法杖", Element.STORM, "res://assets/models/crafted/staff_palespire.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("kite", "菱晶法杖", Element.ICE, "res://assets/models/crafted/staff_kite.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	# ---- batch U ----
	reg("vinebasket", "藤篮法杖", Element.NATURE, "res://assets/models/crafted/staff_vinebasket.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.030})
	reg("crescentmoon", "月牙法杖", Element.HOLY, "res://assets/models/crafted/staff_crescentmoon.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("goldspear", "金锋法杖", Element.FIRE, "res://assets/models/crafted/staff_goldspear.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("goldstar", "金星法杖", Element.HOLY, "res://assets/models/crafted/staff_goldstar.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("duskmagenta", "幽玫法杖", Element.ARCANE, "res://assets/models/crafted/staff_duskmagenta.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("blueorb", "蓝球法杖", Element.ICE, "res://assets/models/crafted/staff_blueorb.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	# ---- batch V ----
	reg("batwing", "蝠翼法杖", Element.ARCANE, "res://assets/models/crafted/staff_batwing.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("pennant", "旗枪法杖", Element.STORM, "res://assets/models/crafted/staff_pennant.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.044})
	reg("palecrown", "素冠法杖", Element.HOLY, "res://assets/models/crafted/staff_palecrown.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("sunbrass", "曜金法杖", Element.FIRE, "res://assets/models/crafted/staff_sunbrass.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("starcage", "星笼法杖", Element.HOLY, "res://assets/models/crafted/staff_starcage.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("plumflame", "梅焰法杖", Element.ICE, "res://assets/models/crafted/staff_plumflame.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	# ---- batch W ----
	reg("vinecluster", "藤簇法杖", Element.ICE, "res://assets/models/crafted/staff_vinecluster.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("paleaxe", "素斧法杖", Element.EARTH, "res://assets/models/crafted/staff_paleaxe.glb",
			{"scale": 1.0, "idle_spin": 0.16, "hover": 0.028})
	reg("violetblaze", "紫焰法杖", Element.ARCANE, "res://assets/models/crafted/staff_violetblaze.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("roseblaze", "玫焰法杖", Element.FIRE, "res://assets/models/crafted/staff_roseblaze.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("ashflame", "灰焰法杖", Element.STORM, "res://assets/models/crafted/staff_ashflame.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("jadeblaze", "翠焰法杖", Element.NATURE, "res://assets/models/crafted/staff_jadeblaze.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	# ---- batch X ----
	reg("voidcoil", "虚空缠杖", Element.ARCANE, "res://assets/models/crafted/staff_voidcoil.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("goldwing", "金翼圣杖", Element.HOLY, "res://assets/models/crafted/staff_goldwing.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.032})
	reg("vineice", "藤冰枝杖", Element.NATURE, "res://assets/models/crafted/staff_vineice.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("darkcrescent", "黑月法杖", Element.ICE, "res://assets/models/crafted/staff_darkcrescent.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("violettongue", "紫舌焰杖", Element.FIRE, "res://assets/models/crafted/staff_violettongue.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("gildamethyst", "金焰紫晶杖", Element.ARCANE, "res://assets/models/crafted/staff_gildamethyst.glb",
			{"scale": 1.0, "idle_spin": 0.22, "hover": 0.036})
	# ---- batch Y ----
	reg("radiantcross", "曜金十字杖", Element.HOLY, "res://assets/models/crafted/staff_radiantcross.glb",
			{"scale": 1.0, "idle_spin": 0.20, "hover": 0.034})
	reg("duskclaw", "暮爪晶杖", Element.ARCANE, "res://assets/models/crafted/staff_duskclaw.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("stormcore", "雷芯权杖", Element.STORM, "res://assets/models/crafted/staff_stormcore.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.044})
	reg("tealoracle", "青焰先知杖", Element.NATURE, "res://assets/models/crafted/staff_tealoracle.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("vinecrystal", "藤晶杖", Element.NATURE, "res://assets/models/crafted/staff_vinecrystal.glb",
			{"scale": 1.0, "idle_spin": 0.18, "hover": 0.032})
	reg("stonemask", "石面权杖", Element.EARTH, "res://assets/models/crafted/staff_stonemask.glb",
			{"scale": 1.0, "idle_spin": 0.14, "hover": 0.026})
	reg("coilflare", "蓝箍绯焰杖", Element.FIRE, "res://assets/models/crafted/staff_coilflare.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	# ---- batch Z（最后一批） ----
	reg("goldpetal", "金瓣青晶杖", Element.STORM, "res://assets/models/crafted/staff_goldpetal.glb",
			{"scale": 1.0, "idle_spin": 0.24, "hover": 0.038})
	reg("tripleband", "三环金焰杖", Element.FIRE, "res://assets/models/crafted/staff_tripleband.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})
	reg("broadaxe", "阔刃斧杖", Element.EARTH, "res://assets/models/crafted/staff_broadaxe.glb",
			{"scale": 1.0, "idle_spin": 0.12, "hover": 0.024})
	reg("frostburst", "霜爆法杖", Element.ICE, "res://assets/models/crafted/staff_frostburst.glb",
			{"scale": 1.0, "idle_spin": 0.26, "hover": 0.040})
	reg("stormbraid", "青绞雷焰杖", Element.STORM, "res://assets/models/crafted/staff_stormbraid.glb",
			{"scale": 1.0, "idle_spin": 0.30, "hover": 0.044})
	reg("stardome", "星穹法杖", Element.ARCANE, "res://assets/models/crafted/staff_stardome.glb",
			{"scale": 1.0, "idle_spin": 0.34, "hover": 0.048})
	reg("starblaze", "星火蓝焰杖", Element.STORM, "res://assets/models/crafted/staff_starblaze.glb",
			{"scale": 1.0, "idle_spin": 0.28, "hover": 0.042})


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


func has(id: String) -> bool:
	return defs.has(id)


func get_def(id: String) -> Dictionary:
	return defs.get(id, {})


func display_name(id: String) -> String:
	var d: Dictionary = defs.get(id, {})
	return str(d.get("name", id))


func element_of(id: String) -> int:
	var d: Dictionary = defs.get(id, {})
	return int(d.get("element", Element.NONE))


func element_name(e: int) -> String:
	return str(ELEMENT_NAMES.get(e, "?"))


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
	return true


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
	return true


func unequip() -> void:
	equip("")


## 长老祝福：改写当前法杖的元素（模型不变，动态效果与配色变）
func bless(id: String, element: int) -> void:
	if not defs.has(id):
		return
	defs[id]["element"] = element
	if equipped == id:
		equipped_element = element
		emit_signal("staff_equipped", id)


func add_stone(id: String, amount: int = 1) -> void:
	stones[id] = int(stones.get(id, 0)) + amount
	emit_signal("stone_gained", id, amount)


func stone_count(id: String) -> int:
	return int(stones.get(id, 0))


## 已解锁列表（按 defs 顺序，UI 用）
func unlocked_list() -> Array:
	var out: Array = []
	for id in defs.keys():
		if unlocked.has(id):
			out.append(id)
	return out


## 全部 id（调试/图鉴用）
func all_ids() -> Array:
	return defs.keys()

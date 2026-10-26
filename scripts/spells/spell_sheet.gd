extends RefCounted
# ============================================================================
# spell_sheet.gd —— 法术数值表（JSON）读取器
# ============================================================================
#
# 【本文件职责】
#   把"法术数值"从代码里抽出来，集中放在一个 JSON 数据文件里，运行时以只读方式查询。
#   本文件**不含任何法术逻辑**：不生成特效、不扣蓝、不碰场景树，
#   只负责三件事：惰性读盘 → 解析 JSON → 带兜底默认值的类型化取值。
#
# 【所属系统】
#   法术系统（scripts/spells/）的数据层 / 工具层，是全部术法数值的**单一数据源**。
#   被各个术法脚本（water_heal.gd / flame_scorch.gd / flame_advance.gd /
#   blue_tornado.gd / gold_body.gd 等）以及自检工具（tools/verify_*.gd、tools/shot_helper.gd）引用。
#
# 【关键依赖】
#   · 数据文件：res://data/spell_sheet.json
#     顶层结构 = { "_说明": ..., "_字段": {...}, "spells": { "<法术 id>": { ... } } }；
#     本文件只认 "spells" 这一层，下划线开头的元数据键被自然忽略（不会被当成法术行）。
#   · 无 autoload、无信号、无场景/节点依赖：纯 static 工具类，可以 preload 后直接调。
#   · 继承自 RefCounted（不是 Node），本身不实例化、不参与场景树。
#
# 【主要对外接口】（全部 static）
#   get_spell(id) -> Dictionary    取整行原始数据（找不到给空字典，不报错）
#   has(id) -> bool                这一行在不在
#   f(id, key, def) -> float       取浮点字段
#   b(id, key, def) -> bool        取布尔字段
#   s(id, key, def) -> String      取文本字段
#   validate(id) -> Array          自检：时间字段之间的加和关系是否自洽
#
# 【已知的坑与注意事项】
#   1. 全局缓存 + 惰性加载：表只在**首次**访问时读一次盘并解析，之后一直复用 _cache
#      （static var，所有 preload 同一路径的地方共享同一份）。
#      运行时改 JSON 不会自动生效——改数值后需重开游戏（本文件没有提供清缓存接口）。
#   2. 失败不抛异常：文件缺失或 JSON 语法错时只 push_warning 并返回空表，
#      于是 f/b/s 全部退回调用方传入的 def。所以**调用方的默认值必须自己写对**。
#   3. 缓存命中判定是 _cache.is_empty()，因此"加载失败"和"spells 段真的为空"都会被
#      当成没加载：这类情况下**每次调用都会重新读盘并再次告警**（日志可能刷屏）。
#      正常项目里表必定存在，所以实践中不会触发。
#   4. get_spell / _load 返回的是缓存内部那一行的**引用**（Dictionary 是引用类型，不是拷贝）：
#      调用方只应读取，不要原地改字段，否则会污染后续所有读取（推测：当前所有调用方都只读）。
#   5. 本表不携带单位，字段单位由各术法脚本自行解释（秒 / 点蓝量 / 点每秒等），
#      这里不做任何换算与取值范围校验（数值合法性由 validate 只针对时间加和做粗检）。
#
# 【典型用法】（见文件末尾的原生文档块）
#   const SHEET := preload("res://scripts/spells/spell_sheet.gd")
#   var cost := SHEET.f("water_heal", "mana_cost", 0.0)
#   var row  := SHEET.get_spell("water_heal")
# ============================================================================

## 法术数值表读取器 —— 单一数据源：res://data/spell_sheet.json
##
## 用法：
##   const SHEET := preload("res://scripts/spells/spell_sheet.gd")
##   var cost := SHEET.f("water_heal", "mana_cost", 0.0)
##   var row  := SHEET.get_spell("water_heal")
##
## 这样所有数值都集中在一个 JSON 里，改数值不用翻代码。

# ==================== 段 1：配置路径与全局缓存 ====================

## 数值表在项目里的固定 res:// 资源路径（导出时会被打包进 pck=/数据文件）。
## 改这里 = 换一张法术表；注意这是大小写敏感的资源路径写法，不要写成绝对磁盘路径。
## 其它脚本（flame_advance.gd 等）读 targeting 子表时读的也是这个文件。
const PATH := "res://data/spell_sheet.json"

## 解析结果的全局缓存，形如 { "<法术 id>": { "mana_cost": 20, ... }, ... }（即 JSON 的 "spells" 段）。
## 为什么用 static：本类从不实例化，static var 让所有调用方（含 tools/ 里的自检脚本）
##   共享同一份解析结果，避免每个术法脚本各读一次盘。
## 语义坑：空字典既表示"还没加载过"，也表示"加载失败 / 表为空"——
##   加载函数以 is_empty() 判断缓存是否可用，所以空表会导致每次访问都重新读盘（见文件头坑 3）。
## 不要从外部写这个变量（本文件没有提供清缓存或写缓存的接口）。
static var _cache: Dictionary = {}
## Mod 注入的法术行（由 autoload Mods 在启动时写入）：{ "<法术 id>": { ... } }。
## 与 _cache 的关系：_load() 读盘后把这里的行合并进去（同 id 以 Mod 字段为准，逐字段覆盖）。
## 保持独立，是为了让"基础表没变"与"Mod 加了什么"可分开排查。
static var _mod_rows: Dictionary = {}


## 合并 Mod 法术行（由 Mods 调用；重复调用以新内容为准）。
## 参数：rows —— { "<法术 id>": {字段...} }。返回：无。副作用：写 _mod_rows 并刷新 _cache。
static func inject_mod_rows(rows: Dictionary) -> void:
	if rows.is_empty():
		return
	for id in rows.keys():
		var row: Variant = rows[id]
		if not (row is Dictionary):
			continue
		if _mod_rows.has(id) and _mod_rows[id] is Dictionary:
			(_mod_rows[id] as Dictionary).merge(row as Dictionary, true)
		else:
			_mod_rows[id] = (row as Dictionary).duplicate(true)
	_cache = {}


# ==================== 段 2：内部实现 —— 惰性加载与解析 ====================

## 取得"法术行"字典（= JSON 的 "spells" 段），必要时读盘解析一次。
## 返回：{ "<法术 id>": { ... } }；文件缺失或 JSON 解析失败时返回空字典（不抛异常）。
## 副作用：首次成功时写全局 _cache（只读逻辑里唯一会改状态的地方）；
##   失败/空表时不写缓存，于是**下次调用会再次读盘并再次 push_warning**（见文件头坑 3）。
## 调用时机：get_spell / has / f / b / s / validate 内部都会走这里，外部不直接调用。
## 注意：返回的是缓存本身的引用，调用方不要原地修改。
static func _load() -> Dictionary:
	# 快路径：已经成功加载过就零开销返回，避免每帧/每次施法都碰文件系统。
	if not _cache.is_empty():
		return _cache
	# 先单独判存在性，是为了给出"找不到配置表"这种明确告警；
	# （若直接读，只会得到解析失败的笼统信息，排查时看不出是路径写错还是文件损坏）
	if not FileAccess.file_exists(PATH):
		push_warning("[SpellSheet] 找不到配置表: %s" % PATH)
		return {}
	var txt := FileAccess.get_file_as_string(PATH)
	# JSON.parse_string 语法错时返回 null，成功但内容是别的类型时返回对应类型；
	# 所以这里用 typeof 判定，而不是 is_empty()——空 JSON 对象 {} 也算解析成功。
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("[SpellSheet] 配置表解析失败: %s" % PATH)
		return {}
	# 只取 "spells" 这一层：顶层另有 "_说明" / "_字段" 两个下划线元数据键（写给人看的），
	# 它们不是法术行，所以不能把整个根字典当成查询表；缺 "spells" 键时退化为空表。
	_cache = (parsed as Dictionary).get("spells", {})
	# Mod 注入行合并（同 id 逐字段覆盖，Mod 新 id 直接追加）。
	# 先 copy 原行再 merge：基础表被 mod 覆盖时只影响合并结果，不污染 JSON 解析出来的原对象。
	if not _mod_rows.is_empty():
		var base: Dictionary = (_cache as Dictionary).duplicate()
		for id in _mod_rows.keys():
			if base.has(id) and base[id] is Dictionary:
				var merged: Dictionary = (base[id] as Dictionary).duplicate()
				merged.merge(_mod_rows[id] as Dictionary, true)
				base[id] = merged
			else:
				base[id] = _mod_rows[id]
		_cache = base
	return _cache


# ==================== 段 3：对外接口 —— 整行查询 ====================

## 取某个法术在表里的**整行**原始数据（键名就是 JSON 里的键名，未做任何改名/换算）。
##
## 参数 id：法术行名，如 "water_heal" / "flame_scorch" / "blue_tornado"；**区分大小写**，
##   拼错不会报错，只会拿到空字典。
## 返回：该行的字典；找不到时返回**空字典 {}**，不报错也不告警
##   （是否告警由调用方决定：如 blue_tornado.gd 自己 print 提示后沿用导出默认值）。
## 副作用：可能触发一次惰性读盘（首次访问时）；之后只读缓存，不改其它全局状态。
## 调用时机：需要一次读多个字段时用它（比连续调 f/b/s 少查几次表）；
##   也需要它来取**嵌套子表**，例如 get_spell(id).get("targeting", {})。
## 注意：返回的是缓存内部那一行的**引用**（Dictionary 是引用类型，不是拷贝），
##   请只读使用；原地改字段会污染缓存，改数值请改 JSON 源文件。
## 整行（找不到返回空字典）
static func get_spell(id: String) -> Dictionary:
	return _load().get(id, {})


## 判断表里是否存在某个法术行（表可用性探测，比 get_spell(id).is_empty() 更直白）。
## 参数 id：法术行名（区分大小写）。返回：存在 true / 不存在 false。
## 副作用：首次调用可能读盘；表**整体读取失败**时恒返回 false，
##   而且因为失败不写缓存，每次调用都会重新读盘并再次 push_warning（见文件头坑 3）。
## 调用时机：术法脚本在 _load_sheet() 里用它判断"表里有没有我这行"，
##   没有就沿用 @export 上的兜底默认值（如 water_heal.gd、flame_scorch.gd）。
static func has(id: String) -> bool:
	return _load().has(id)


# ==================== 段 4：对外接口 —— 类型化取值（带兜底默认值） ====================
#
# f / b / s 三个函数形状完全一致：查行 → 行不存在或键缺失就返回 def → 否则转成目标类型。
# 它们**永远不会报错、也永远不会告警**（告警只在 _load 阶段发），
# 所以 def 就是调用方的"最后一道防线"，必须与该字段的合理默认值一致。

## 取浮点数值（找不到用 def）
##
## 参数 id：法术行名。key：字段名（如 "mana_cost" / "cast_climb" / "duration"）。
## 参数 def：兜底值——行不存在、或行里没有这个键时原样返回；**取值范围无限制**，
##   由调用方负责给合理值（惯例：工具/自检里给 -1.0 表示"读不到就明显报错"，
##   业务代码里给本术法的 @export 默认值，保证读表失败也能正常施法）。
## 返回：字段值转成的 float；JSON 里写整数（如 20）也会得到 20.0。
## 副作用：无（只读；首次访问可能触发一次读盘）。
## 注意：字段存在但不是数字（例如写成文本）时 float() 会尽力转换，失败得 0.0，
##   不会退回 def——所以表里别把数字字段写成字符串。
static func f(id: String, key: String, def: float) -> float:
	var row := get_spell(id)
	# 行不存在 与 键不存在 走同一条兜底路径：两者对调用方都是"没有可用数值"。
	if row.is_empty() or not row.has(key):
		return def
	# 显式转 float：JSON 数字可能解析成 int（表里 mana_cost 写的 20），
	# 统一成 float 后调用方无需关心类型，也避免 int/float 混合运算的隐式转换歧义。
	return float(row[key])


## 取布尔值
##
## 参数 id：法术行名。key：字段名（本表常用 "one_shot"：true = 点一下放完，false = 按住持续施放）。
## 参数 def：兜底值，行/键缺失时返回它；惯例给 false（即"按持续施法处理"，更保守）。
## 返回：字段值的 bool。副作用：无（只读；首次访问可能触发一次读盘）。
## 注意：bool() 对 0/1、""/非空字符串都能转换，所以表里写 0/1 也能当布尔用（推测：现有表里都写 true/false）。
static func b(id: String, key: String, def: bool) -> bool:
	var row := get_spell(id)
	if row.is_empty() or not row.has(key):
		return def
	return bool(row[key])


## 取文本
##
## 参数 id：法术行名。key：字段名（本表常用 "name" 显示名、"note" 备注）。
## 参数 def：兜底值，默认空串 ""（文本字段一般只用于展示，缺了给空串即可，不必特判）。
## 返回：字段值的 String；副作用：无（只读；首次访问可能触发一次读盘）。
## 注意：这些字段是给人和工具看的（tools/verify_*.gd 会读 name/note 做提示），
##   游戏逻辑**不要**依赖文本字段的内容做判断。
static func s(id: String, key: String, def: String = "") -> String:
	var row := get_spell(id)
	if row.is_empty() or not row.has(key):
		return def
	# JSON 里若误写成数字，String() 会转成 "20" 这样的文本，比直接取用更安全（不会因类型不符崩）。
	return String(row[key])


# ==================== 段 5：自检 —— 时间字段一致性校验 ====================
#
# 本表把"一个法术的整体时间"拆成三段并存了合成值，两处数字必须自洽：
#   cast_time  = cast_climb + cast_veil                    （成型时间，两段施法动作）
#   total_time = cast_time + duration + fade_time          （整体 = 成型 + 持续 + 淡出）
# 这些值分别被不同脚本读取（有的读分段做动画、有的读合计做 UI/耗蓝），
# 一旦手改 JSON 只改了一边，就会出现"动画演完了但 UI 计时没完"之类的错位，
# 所以专门留这个函数在自检/工具里跑一遍。

## 校验：cast_time 是否等于两段之和、total_time 是否等于三段之和（自检用）
##
## 参数 id：法术行名（区分大小写）。
## 返回：Array（字符串数组）——**空数组 = 全部通过**；非空则每项是一条中文错误说明，
##   （说明里带表里值与本函数算出的值，便于直接比对）。行不存在时返回单元素数组，不算异常抛出。
## 副作用：无（纯只读；首次访问可能触发一次读盘），不会修改表也不会告警。
## 调用时机：自检 / 工具脚本在改完数值表后调用（当前仓库里只有定义、没有调用点——
##   推测是给 tools/verify_*.gd 这类自检预留的接口，需要时自行 load 本脚本调用）。
## 注意：只查"加和关系"，不查取值范围（负时长、mana_cost 为 0 等都不算错）；
##   缺字段时的处理见下面各行的注释。
static func validate(id: String) -> Array:
	var errs: Array = []
	var row := get_spell(id)
	if row.is_empty():
		return ["配置表里没有这个法术: %s" % id]
	# 先按表的定义把两段施法时间加起来，作为 cast_time 的"应该值"。
	var cast := f(id, "cast_climb", 0.0) + f(id, "cast_veil", 0.0)
	# 默认值给 -1.0 是当哨兵用的：负数代表"表里没写这个字段"（时长不可能为负），
	# 这样就能把"缺字段"和"真的填了 0"区分开，缺字段时跳过校验而不是误报 0 不匹配。
	var cast_sheet := f(id, "cast_time", -1.0)
	# 容差 0.001 而不是 ==：JSON 里是十进制小数（如 1.15 + 0.55），浮点累加会有舍入误差，
	# 用相等比较会把合法数值判成错。
	if cast_sheet >= 0.0 and absf(cast - cast_sheet) > 0.001:
		errs.append("cast_time 对不上: 表里 %.3f, 两段之和 %.3f" % [cast_sheet, cast])
	# 整体时间 = 成型（复用上面算好的 cast）+ 持续 + 淡出；
	# duration / fade_time 缺省按 0.0 参与计算（即"没有这一段"），不会因此报错。
	var total := cast + f(id, "duration", 0.0) + f(id, "fade_time", 0.0)
	var total_sheet := f(id, "total_time", -1.0)
	# 同 cast_time：total_time 缺字段（-1.0）时跳过，只校验表里确实写了的行。
	if total_sheet >= 0.0 and absf(total - total_sheet) > 0.001:
		errs.append("total_time 对不上: 表里 %.3f, 计算 %.3f" % [total_sheet, total])
	return errs

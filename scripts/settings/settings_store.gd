# ============================================================================
# 【文件头】settings_store.gd —— 设置值的持有与持久化（纯逻辑 ✓ 可单测）
# ============================================================================
# 所属系统：设置系统（scripts/settings/；全部由代码构建/持有，不依赖任何 .tscn）
#   同目录协作脚本（本文件只依赖第 1 个 ✓，其余是调用方 ✓）：
#     · settings_schema.gd（SettingsSchema）—— 设置项的"真源"：分类 ORDER / 条目 Kind /
#         默认值 / 步长。本文件用到它的静态方法 defaults() 与 find(key)
#         （find() 内部就是遍历 items() 线性查找）。
#     · settings_apply.gd（SettingsApply）—— 把值真的写进引擎（音频总线 / 窗口 / MSAA / 画质档）。
#     · settings_input.gd（SettingsInput）—— 按键改绑；绑定表以 "input/bindings" 存进本类。
#     · settings_menu.gd（SettingsMenu）—— 设置菜单 UI；控件每次变化都调本类 set_value()。
#     · game_settings.gd（GameSettings）—— autoload 总控：new 出本类 + load_from_disk()。
#
# 【职责】（一句话）在内存里持有"键 → 值"，把整份值写进 / 读出 user://settings.cfg，
#   并在值变化时广播 changed 信号。
#   · 它**不做**取值合法性 / 范围校验 ✗（那是控件与 SettingsApply 的事 ✓）
#   · 它**不负责**把值应用到引擎 ✗（那是 SettingsApply 的事 ✓）
#   · 它**不持有**节点、不入场景树 ✗（RefCounted ✓，谁 new 谁持有 ✓）
#
# 【关键依赖】
#   · autoload：无 ✓（由 GameSettings / SettingsMenu / 单元测试各自 new ✓）
#   · class_name 全局类 SettingsSchema（纯静态 ✓，无实例 ✓）
#   · 文件：user://settings.cfg（Windows 下形如
#       %APPDATA%\Godot\app_userdata\Cozy Vale\settings.cfg ✓）
#   · 信号：changed(key, value) —— 本类唯一的对外信号 ✓
#
# 【主要对外接口】
#   · cfg_path : String         实际使用的配置文件路径（**可替换** ✓，测试必须替换 ✓）
#   · reset_all() -> void       内存恢复默认（不落盘 ✓、不发信号 ✓）
#   · get_value(key) -> Variant 读一个键；不认识时回落 schema 默认值，再没有就 null ✓
#   · set_value(key, value)     写一个键：改内存 → 立即落盘 → 发 changed ✓
#   · has(key) -> bool          键当前是否在内存表里 ✓（≠ "玩家设过" ✗）
#   · save() -> bool            把内存里全部值写进文件（不发信号 ✓）
#   · load_from_disk() -> int   从文件读回来，返回**读到几项** ✓
#   · modified_keys() -> Array  与 schema 默认值不同的键 ✓（只含 schema 键 ✓）
#
# 【已知的坑与注意事项】（每条都有历史依据，改前先读）
#   1. 只有带 "/" 的键才会被持久化 ✓：键一律按 "分类/名" 解释
#      （"graphics/tier" → [graphics] 段下 tier=… ✓）。没有 "/" 的键在 save() 里被跳过 ✗
#      —— 内存里在、重启就丢 ✗，所以别发明扁平键 ✗。
#   2. 读回时**键不认识就静默丢弃** ✓：load_from_disk() 只接受 schema 里有的键，
#      外加白名单 allowed_extra = ["input/bindings"] ✓；其余一律不读 ✓
#      （防手改文件注入垃圾键 ✓，也防旧版本残留键污染内存 ✓）。
#   3. 本类**不发**"已加载 / 已保存"信号 ✗：changed 只在 set_value() 里发 ✓ ——
#      所以 load_from_disk() / reset_all() 之后，调用方必须自己再 apply 一遍 ✓
#      （game_settings.gd 的顺序就是 load_from_disk() → SettingsApply.apply_all() ✓）。
#   4. **值没变就什么都不做** ✓：set_value() 先查重再写 ✓ —— 不落盘、不发信号 ✓。
#      这是给"拖动滑条（每帧都在 set）/ 打开菜单回填控件"做的节流 ✓，
#      删掉会变成信号风暴 + 无谓磁盘 IO ✗。
#   5. cfg_path 必须在 load_from_disk() / save() **之前**设好 ✓：它只决定"之后读写哪个文件" ✓，
#      改它不会把旧文件搬过去 ✗。单元测试一律指向临时路径 ✓，否则会把玩家真实设置覆盖掉 ✗
#      （见 test_settings.gd 的 _tmp_cfg() ✓）。
#   6. schema 之外的键（如 "input/bindings" ✓）**从未存过时 get_value() 返回 null** ✓，
#      不是默认值 ✗ —— 读的人必须判空 / 兜底 ✓（SettingsInput.load_bindings 就是这么做的 ✓）。
#   7. 本类**不做类型检查 / 范围检查** ✓：塞进去什么类型就存什么类型 ✓；
#      越界值由控件（滑条 min/max ✓）与 settings_apply.gd 各自兜底 ✓。
#   8. @tool ✓：编辑器里也能构造本类（SettingsApply 内有 Engine.is_editor_hint() 分支 ✓），
#      但**不要**在编辑器里对真实的 user://settings.cfg 调 save() ✗（会写坏玩家设置 ✗）。
# ============================================================================
@tool
class_name SettingsStore
extends RefCounted
## 设置值的持有与持久化（纯逻辑 ✓ 可单测）
## 存到 user://settings.cfg ✓；每次改动即时落盘 ✓ 并发出 changed 信号 ✓

# ==================== 信号 ====================

## 某个设置值**真的变了**之后发出 ✓。
##
## 参数 key：设置键，形如 "分类/名"（如 "audio/music" / "graphics/tier" ✓）。
##   SettingsInput 用的 "input/bindings" 也走这条通道 ✓，此时 value 是 Dictionary ✓。
## 参数 value：新值（Variant ✓，类型随 key 而定：bool / int / float / Dictionary…✓）。
## 发出时机：**仅**在 set_value() 里、且新值与旧值确实不同时 ✓ ——
##   而且发出**之前**已经 save() 落盘 ✓，所以监听者里立刻重读或再 save() 都拿到新值 ✓。
## 不会发出的情况（很重要 ✓）：值没变（set_value 提前 return ✓）、reset_all() ✓、
##   save() ✓、load_from_disk() ✓ —— 后三个要由调用方自己 apply ✓（见文件头第 3 条）。
## 用途：监听它做"改动即时生效" ✓（本类**不**监听自己 ✓，UI 与 apply 层负责听 ✓）。
## 注意：本信号**只带** key 与 value ✗，不带"旧值" ✗ —— 想比较旧值只能监听方自己缓存 ✓。
signal changed(key: String, value: Variant)

# ==================== 常量与路径 ====================

## 配置文件**默认**路径（只读常量 ✓，改不了 ✓）。
## 为什么用 user:// 而不是 res:// ✓：导出后的游戏 res:// 一般只读 ✗，写不进去 ✗；
##   user:// 映射到系统用户目录（Windows：%APPDATA%\Godot\app_userdata\Cozy Vale\ ✓），
##   卸载重装 / 换存档目录都不会被覆盖 ✓。
## 文件名固定为 settings.cfg ✓ —— **别改** ✗：改了等于"所有玩家的既有设置全部重置" ✗。
## 实际生效的路径看实例字段 cfg_path ✓（测试会把它换掉 ✓），本常量只是初始值 ✓。
const CFG_PATH := "user://settings.cfg"

## 实际使用的路径。可替换 ✓（测试必须指向别处，否则会把玩家真实设置覆盖掉 ✗）
##
## 初值 = CFG_PATH ✓（常量本身不可改 ✓，所以另开一个可变实例字段来指路 ✓）。
## 类型由 := 推断为 String ✓（不是 StringName ✓）。
## 改动时机：**必须在 load_from_disk() / save() 之前** ✓ —— 它只影响"之后"的读写 ✓，
##   改完不会把旧文件的数据搬过来 ✗（想在两个文件间搬数据：手动 load → 改路径 → save ✓）。
## 为什么可变而不是直接用常量 ✗：单元测试**必须**把它指到临时路径 ✓，
##   否则测试会写玩家真实的 user://settings.cfg ✗（test_settings.gd 的 _tmp_cfg() ✓）。
## 注意事项：路径写错（目录不存在 ✓）不会崩 ✓，只会让 save() 返回 false / load 返回 0 ✓，
##   而 set_value() 丢弃了 save() 的返回值 ✗ → 现象是"设置改得动，但重启就没了" ✓。
var cfg_path := CFG_PATH

# ==================== 内部状态 ====================

## 内存中的"键 → 值"表（本类**唯一**的真源 ✓）。键形如 "分类/名"（如 "audio/music" ✓），
## 值类型随键而定（bool / int / float / Dictionary…✓）。**不做类型校验** ✓。
## 初值不是空表 ✗：_init() → reset_all() 会把它填成 SettingsSchema.defaults() ✓，
##   所以"new 完没读盘就 get_value"拿到的是**默认值** ✓，不会拿到 null ✓。
## 额外键（如 "input/bindings" ✓）也存放在这里 ✓ —— 它不在 schema 里 ✓，
##   但 save() / load_from_disk() 对它做了特批 ✓（见文件头第 2 条 ✓）。
## 生命周期：随实例存活 ✓（RefCounted ✓）；reset_all() 会**整个换成新字典** ✓，
##   所以要长期持有引用的话注意会拿到旧对象 ✗（正常用法是按需 get_value ✓）。
var _values := {}


# ==================== 构造 ====================

## 构造回调（任何 `SettingsStore.new()` 的瞬间由引擎调用 ✓，也可被测试直接 new ✓）。
##
## 参数：无（本类不需要构造参数 ✓；GDScript 的 _init() 本身是可以声明参数的 ✓，
##   声明后由 `Klass.new(参数…)` 传入 ✓ —— 本类刻意留空 ✓，因为值的来源是 schema 与磁盘 ✓）。
## 返回值：无（构造没有返回值 ✓）。
## 副作用：**只**把 _values 填成 SettingsSchema.defaults() ✓（内部走 reset_all() ✓）——
##   不读盘 ✗、不写盘 ✗、不发信号 ✗、不碰场景树 ✗。
## 调用时机：new 的瞬间 ✓（game_settings.gd:_ready() ✓、settings_menu.gd:_ready() ✓、单测 ✓）。
## 注意事项：
##   · 这里**刻意不读盘** ✗：此刻 cfg_path 还是默认值 ✓，测试也还没机会把它指向临时文件 ✓；
##     而且读盘出错时的错误处理应该由调用方决定 ✓。所以调用方必须自己再调 load_from_disk() ✓
##     才会拿到玩家存过的值 ✓（只 new 不 load = 全默认值 ✓，不会崩 ✓）。
##   · 反过来也成立 ✓：测试的固定顺序是 new → 改 cfg_path → reset_all()/load_from_disk() ✓。
func _init() -> void:
	reset_all()


## 全部恢复默认（内存里 ✓ 不落盘）
##
## 参数：无。
## 返回值：无。
## 副作用：把 _values **整个替换**为 SettingsSchema.defaults() 返回的新字典 ✓
##   （旧字典被丢弃 ✓）：不写文件 ✗、不发 changed ✗、**不清磁盘上已有的旧值** ✗。
## 默认值来源：SettingsSchema（每个条目的 "default" 字段 ✓）——
##   所以"默认值是多少"这件事**只**归 settings_schema.gd 管 ✓，
##   本文件里**没有**任何硬编码默认值 ✓，改默认值请改 schema ✓（别在这里加 ✓）。
## 调用时机：
##   · _init() 里 ✓（保证"新建即可用、到处都有默认值" ✓）
##   · 单元测试每个用例开头 ✓（清掉上个用例残留的值 ✓）
##   · 菜单"恢复默认"按钮：先在内存里 reset_all() ✓，再由调用方 save() + 逐项应用 ✓
##     —— 顺序反了（先 save 后 reset）等于没恢复 ✗。
## 注意事项：因为不落盘 ✓，reset 之后忘了 save() ✓ / 忘了 apply ✓，
##   现象就是"点了恢复默认，界面没变 / 重启还是旧值" ✓。
func reset_all() -> void:
	_values = SettingsSchema.defaults()


# ==================== 读取接口 ====================

## 取"非 schema 键"（如 input/bindings）时，若从未存过会返回 null ✓（不会冒充默认值 ✗）
##
## 参数 key：设置键，形如 "分类/名"（如 "audio/music" ✓）。
##   两类来源：schema 里登记过的键 ✓ / 额外键（"input/bindings" ✓）。
## 返回值（三级回落 ✓）：
##   1) _values 里有这个键 → 直接返回存着的值 ✓ —— 这是正常路径 ✓：
##      _init() → reset_all() 已把全部 schema 键（连默认值）填进去了 ✓；
##   2) _values 里没有、但 schema 里有 → 返回该条目的 "default" ✓（**兜底**分支 ✓：
##      只有 _values 被清空 / 替换过，或本实例错过了 reset_all() 时才会走到 ✓）；
##   3) 两边都没有 → **返回 null** ✓（schema 之外的键、且从未 set / load 过 ✓，
##      例如首次运行时的 "input/bindings" ✓）—— 绝不冒充默认值 ✓。
## 副作用：**无** ✓（不改 _values、不读盘、不写盘、不发信号 ✓）→ 纯查询，可安全高频调用 ✓。
## 调用时机：菜单建行时回填控件 ✓、SettingsApply 应用设置时 ✓、SettingsInput 读绑定表时 ✓。
## 注意事项：
##   · 返回类型是 Variant ✓ → 调用方必须自己转换（int() / float() / bool() ✓）并判空 ✓；
##     对 null 直接做算术 / 比较会报类型错 ✗。
##   · 对 "about/version" 这类 INFO 条目：schema 里只有 "value_text" 没有 "default" ✓，
##     而 defaults() 用的是 get("default", null) ✓ → _values 里它们**就是 null** ✓
##     （符合预期 ✓：它们本来就不是可设置项，由菜单单独填实时值 ✓）。
##   · 兜底分支（第 2 级）**不会把结果写回** _values ✗：这里只读不缓存 ✓
##     （所以别指望"调一次 get_value 之后 has() 就变 true" ✓）。
##   · 本函数**不校验** key 是否合法 ✗、**不报错** ✗：拼错的键只会安静地拿到 schema 兜底 / null ✓。
func get_value(key: String) -> Variant:
	# 命中内存表：正常路径 ✓（_init → reset_all 已把 schema 默认值填满 ✓）
	if _values.has(key):
		return _values[key]
	# 未命中 → 兜底查 schema 的 "default" ✓；schema 里也没有就返回 null ✓（不编造默认值 ✓）
	var d := SettingsSchema.find(key)
	return d.get("default", null)


# ==================== 写入接口 ====================

## 写一个设置值：先查重 → 改内存 → 立即落盘 → 最后发 changed ✓。**顺序不可调换** ✓。
##
## 参数 key：设置键，"分类/名" 形式 ✓。
##   注意：无 "/" 的键能存进内存 ✓，但 save() 会跳过它 ✗（重启即丢 ✗，见文件头第 1 条 ✓）。
## 参数 value：新值（Variant ✓）—— **不做类型 / 范围校验** ✓，控件给什么就存什么 ✓；
##   想限制取值范围请在控件（滑条 min/max ✓）或 SettingsApply 层做 ✓。
## 返回值：无（**连落盘失败也不上报** ✗ —— save() 返回的 bool 被丢弃了 ✓）。
## 副作用（三件事，顺序固定 ✓）：
##   1) _values[key] = value ✓（改内存 ✓）
##   2) save() ✓（**每次改动即时落盘** ✓，不做延迟合并 ✗ —— 代价是拖滑条时频繁写盘 ✓，
##      换来的是"崩溃 / 断电也不丢设置" ✓）
##   3) changed.emit(key, value) ✓（**放最后** ✓：保证监听者被叫到时磁盘上已是新值 ✓）
## 调用时机：菜单里控件值一变就调 ✓（settings_menu.gd 的 _commit ✓）；
##   SettingsInput 保存绑定表 ✓（settings_input.gd: save_bindings ✓）。
## 注意事项：
##   · **值没变就直接 return** ✓：不写盘、不发信号 ✓ —— 这是给"拖动滑条 / 打开菜单回填控件"
##     这类反复写入同一个值的场景做的节流 ✓；删掉它会变成信号风暴 + 无谓 IO ✗。
##   · 查重用 == 而不是 is_same() ✓：对 Array 是逐元素比较 ✓；对 Dictionary 也按内容比较
##     （**推测** —— 万一某版本改成引用比较，后果也只是"同样的值多写一次盘" ✓，不丢数据 ✓，
##     所以这里刻意不依赖这个细节 ✓）。
##   · 本函数**不检查** key 是否在 schema 里 ✓ —— 额外键（"input/bindings" ✓）正是靠这点存进去 ✓；
##     读回时的合法性过滤由 load_from_disk() 负责 ✓（写宽松、读严格 ✓）。
##   · 本函数**不检查** cfg_path 是否存在 / 可写 ✗：落盘失败只体现在被丢弃的返回值上 ✓，
##     现象是"内存里改了、重启就没了" ✓（排查落盘问题请看 save() ✓）。
func set_value(key: String, value: Variant) -> void:
	# 值没变 = 无意义写入 ✓：直接返回，省掉一次落盘 + 一次信号广播 ✓（滑条拖动时会被高频调用 ✓）
	if _values.has(key) and _values[key] == value:
		return
	_values[key] = value
	# 即时落盘：不做延迟 / 批量 ✗（宁可多写几次，也不让玩家"改完就崩 = 设置全丢" ✓）
	save()
	# 信号放最后 ✓：监听者被叫到时，内存与磁盘都已是新值 ✓
	changed.emit(key, value)


## 键是否**已经存在于内存表** _values 里 ✓（纯内存判断 ✓：不读文件 ✗、不看 schema ✗）。
##
## 参数 key：设置键，"分类/名" 形式 ✓。
## 返回值：true = 该键当前在 _values 里 ✓；false = 不在 ✓。
## 副作用：无 ✓。
## 语义上的两个坑（重要 ✓，别把它当成"玩家设过这个键" ✗）：
##   · **schema 里的所有键在 _init() → reset_all() 之后恒为 true** ✓ ——
##     哪怕玩家从没动过、配置文件也根本不存在 ✓（因为默认值就已经填进 _values 了 ✓）；
##   · schema 之外的键（"input/bindings" ✓）只有 set_value() 存过、或 load_from_disk() 读过才为 true ✓。
## 所以想表达"有没有被改过"，请用 modified_keys() ✓，不是 has() ✗。
## 调用时机：给调用方做"这个键在内存里有没有数据"的判断 ✓。
##   说明：本文件内部没有调用点 ✓，项目里目前也没有其它调用点（[推测] 属于对外便利接口，
##   多半是给测试 / 后续 UI 用的 ✓）—— 但它的行为是稳定契约 ✓，别按调用点多少决定删留 ✗。
func has(key: String) -> bool:
	return _values.has(key)


# ==================== 持久化（写） ====================

## 只写文件，不发信号（启动加载或整批应用时用 ✓）
##
## 参数：无（路径取 cfg_path ✓，用前必须已设好 ✓）。
## 返回值：bool —— true = ConfigFile.save() 返回 OK（真的写成功了 ✓）；
##   false = 写失败 ✓（目录不存在 / 无写权限 / 磁盘满 / 路径非法 ✓）。
## 副作用：**只写文件** ✓ —— 不改内存 ✗、不发信号 ✗、不抛异常 ✗。
## 落盘格式：ConfigFile（INI 风格 ✓），每个键按 "分类/名" 拆开 ✓ ——
##   "graphics/tier" → [graphics] 段下的 tier=2 ✓；值类型（int / float / bool / Dictionary ✓）
##   由 ConfigFile 自己序列化 ✓，读回来时类型保持不变 ✓。
## 调用时机：
##   · set_value() 内部每次改动后 ✓（所以外部一般**不用**手动调 ✓）
##   · 整批变更（恢复默认 / 导入配置 ✓）之后收尾写一次 ✓
##   · 单测为了显式控制落盘时点会主动调 ✓（test_settings.gd ✓）
## 注意事项：
##   · **没有 "/" 的键会被静默跳过** ✓（`continue` ✓）—— 这些键只在内存里活着、重启读不回来 ✗；
##     这是"键必须写成 分类/名"的强制点 ✓，不是 bug ✓（ConfigFile 必须落在某个 section 下 ✓）。
##   · 只遍历 _values ✓：schema 里有、但 _values 里没有的键**不会**被写 ✗ ——
##     正常流程无影响 ✓（_init 已把默认值填满 ✓），但手工清空过 _values 就会少写 ✓。
##   · 每次都是**全量覆写** ✓（新建一个空 ConfigFile → 把 _values 全塞进去 → 整体写盘 ✓）：
##     文件里那些 _values 里没有的键会被**丢掉** ✓ ——
##     所以"手改 cfg 加进来的自定义键"会在下一次 save() 时消失 ✓
##     （读的时候本来也已被 load_from_disk() 过滤掉 ✓，前后一致 ✓）。
##   · 失败只返回 false ✗，调用方若丢弃返回值就完全无感 ✓（set_value 就是丢弃的 ✓）；
##     **不要**把"没落盘"当成"没改过" ✗ —— 内存里已经改了 ✓。
##   · 返回的是 `== OK` 比较结果 ✓：Godot 的 save() 返回 Error 枚举 ✓，非 OK 即失败 ✓
##     （常见的是 ERR_FILE_CANT_WRITE / ERR_FILE_NOT_FOUND ✓）。
func save() -> bool:
	var cfg := ConfigFile.new()
	# 全量覆写所有持有中的值 ✓（set_value 已即时落盘 ✓，这里相当于再存一次快照 ✓）
	for key in _values.keys():
		# 键按 "段/名" 拆解：parts[0] = 段名 ✓，其余用 "/" 拼回 = 项名 ✓
		var parts := String(key).split("/")
		# 没有 "/" 的键无处安放 ✗：ConfigFile 必须有 section ✓ → 跳过（内存里保留 ✓，磁盘上不写 ✗）
		if parts.size() < 2:
			continue
		cfg.set_value(parts[0], "/".join(parts.slice(1)), _values[key])
	return cfg.save(cfg_path) == OK


# ==================== 持久化（读） ====================

## 读文件；缺的键保留默认 ✓ 返回读到了几项
##
## 参数：无（路径取 cfg_path ✓，**必须在调用前设好** ✓）。
## 返回值：int —— 本次**真正读进 _values 的键数** ✓；文件不存在 / 打不开 / 损坏时返回 0 ✓
##   （不报错 ✓、不抛异常 ✓，此时 _values 保持原样 = 默认值 ✓）。
## 副作用：读文件 ✓ + **覆盖** _values 里同名的键 ✓（不同名的键保持原值 ✓ → 语义是"合并" ✓，
##   不是"整体重置" ✗）。不发信号 ✗ —— 调用方必须自己再 apply ✓（见文件头第 3 条 ✓）。
## 调用时机：
##   · game_settings.gd 的 _ready() 启动链 ✓（autoload 每次启动跑一次 ✓）
##   · settings_menu.gd 自建 store 时 ✓
##   · 单元测试构造"新会话"时 ✓（new 一个实例 + 同一个 cfg_path ✓ → 验证持久化 ✓）
## 注意事项：
##   · **必须先设 cfg_path 再调本函数** ✓，否则读的是默认 user://settings.cfg ✓
##     —— 在测试里这等于读了玩家真实设置 ✗（test_settings.gd 是先 _tmp_cfg() 再 load ✓）。
##   · 只接受两类键 ✓：schema 里登记过的（SettingsSchema.find(key) 非空 ✓）
##     + allowed_extra 白名单里的 ✓；其余一律跳过 ✓。
##   · 返回 0 有**两种**含义 ✓：文件真不存在 ✓ / 文件存在但一个合法键都没有 ✓ ——
##     所以**不能**用返回值 0 判定"文件损坏" ✗。
##   · 重复调用是幂等的 ✓（同一文件读两次结果一样 ✓，只是计数器会再数一遍 ✓）。
##   · 只读不删 ✓：文件里有、而内存里多出来的键不会因此消失 ✓（本类没有删除接口 ✓）。
##   · 段 / 键的遍历顺序由 ConfigFile 决定 ✓，但本函数只做赋值 ✓，与顺序无关 ✓。
func load_from_disk() -> int:
	var cfg := ConfigFile.new()
	# 读不到就返回 0 ✓：文件缺失 / 权限不足 / 内容损坏都走这条 ✓
	if cfg.load(cfg_path) != OK:
		return 0
	# ★ 刻意**不** reset_all()、也**不**报错 ✗ —— 保持 _values 现状（= 默认值 ✓），缺配置文件也不会崩 ✓
	# ★ 必须遍历**文件里实际有的键**，而不是只遍历默认表 ✗ ——
	#   "input/bindings"（按键绑定）不在 schema 里，早期版本因此**永远读不回来** ✗，
	#   等于游戏里改的键重开就失效 ✗（这个 bug 是被单元测试逮住的 ✓）。
	var n := 0
	# 非 schema 键的白名单 ✓：以后新增需要持久化的非 schema 键，**必须**同时加到这里 ✓，
	# 否则就会重演上面那个"存得进、读不回"的 bug ✗。
	# 目前只有 "input/bindings"（SettingsInput.save_bindings 写的按键表 ✓）。
	var allowed_extra := ["input/bindings"]
	# 遍历文件里**实际存在的** 段 → 键 ✓（而不是遍历 schema 的默认表 ✓）—— 这就是上面那段坑的修复点 ✓
	for section in cfg.get_sections():
		for name in cfg.get_section_keys(section):
			var key := String(section) + "/" + String(name)
			# 过滤：只认 schema 里的键 + 白名单额外键 ✓（顺带挡住手改文件注入的垃圾键 ✓）
			# 注意 SettingsSchema.find() 每次都重建整张表做线性查找 ✓ → 键多时是 O(项数²) ✓，
			# 但设置项只有几十条 ✓，这点开销远小于"设置读不全"的代价 ✓，不要为此重构 ✗。
			if SettingsSchema.find(key).is_empty() and not allowed_extra.has(key):
				continue                     # 只接受 schema 里的键 + 明确允许的额外键 ✓
			# 文件里的值就是权威 ✓（含"玩家显式存成默认值"的情况 ✓）：直接覆盖内存 ✓
			_values[key] = cfg.get_value(section, name)
			# 计数只统计**真正读进来**的键 ✓（被上面过滤掉的不算 ✓，段本身也不算 ✓）
			n += 1
	return n


# ==================== 差异查询 ====================

## 与默认值不同的项（便于"是否有改动"判断 ✓）
##
## 参数：无。
## 返回值：Array —— 与 SettingsSchema 默认值**不相等**的键名（String）列表 ✓；
##   顺序 = SettingsSchema.defaults() 的键顺序 ✓（即 schema 的分类 / 条目顺序 ✓）；
##   没有任何改动时返回**空数组** ✓（不是 null ✓，调用方可直接 size() ✓）。
## 副作用：无 ✓（不读盘 ✗、不写盘 ✗、不发信号 ✗）——
##   但内部会调 SettingsSchema.defaults() 重建整张默认表 ✓（每次调用都重建 ✓，别放每帧热路径 ✓）。
## 比较方式：`_values.get(key, null) != defs[key]` ✓ —— 内存里**没有**这个键也算"有改动" ✓
##   （get 的兜底 null 与默认值不等 ✓）；这正是想要的语义：**缺失 ≠ 默认** ✓。
## 调用时机：菜单上标"已修改" ✓；单测断言"确实存下了与默认不同的值" ✓（test_settings.gd ✓）。
## 注意事项：
##   · **只遍历 schema 里的键** ✗ → 额外键（"input/bindings" ✓）**永远不会**出现在结果里 ✓；
##     也就是说"玩家改了按键"不算"设置被改动" ✓ —— 这是刻意的 ✓，别顺手改成遍历 _values ✗。
##   · 它表达的是"**与默认值**不同" ✗，**不是**"与上次启动不同" ✗ ——
##     玩家把某项改回默认值，这一项就会从列表里消失 ✓（语义正确 ✓，但别拿它当操作日志 ✗）。
func modified_keys() -> Array:
	var out: Array = []
	# 默认表每次重建 ✓（SettingsSchema 是纯数据静态类 ✓，没有缓存 ✓）
	var defs := SettingsSchema.defaults()
	# 只遍历 schema 键 ✓ → 额外键不参与"是否改动"的判断 ✓
	for key in defs.keys():
		# get 的兜底 null：内存里缺键也算改动 ✓（"缺失"与"等于默认值"是两回事 ✓）
		if _values.get(key, null) != defs[key]:
			out.append(key)
	return out
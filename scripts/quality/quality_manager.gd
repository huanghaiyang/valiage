@tool
class_name QualityManager
extends Node
## 画质档位管理器。建议在 项目设置 → 全局 → 自动加载 里加为 autoload（名字建议 Quality）。
## 用法：QualityManager.instance.set_tier(QualityTiers.Tier.LOW)
## 会持久化到 user://quality.cfg，并在启动时自动加载。
##
## ============================ 本文件职责 ============================
## 【画质分级系统 · 中枢/单例】整个画质分级系统的"唯一真相源（single source of truth）"：
##   · 持有当前画质档位 tier（0=LOW 低 / 1=MEDIUM 中 / 2=HIGH 高 / 3=ULTRA 极高）；
##   · 把档位持久化到 user://quality.cfg，并在下次启动时自动恢复；
##   · 档位一旦变化就广播 tier_changed，让各处"渲染执行者"各自去改实际参数。
##
## 本文件**只负责"记档位 + 发通知"，自己不直接改任何渲染设置**（职责分工明确 ✓）：
##   · 档位参数表（贴图后缀 / 地形 LOD / 阴影 / 视距）定义在同目录的 QualityTiers（纯数据 + 纯函数）；
##   · 真正的落地由订阅者完成：
##       - scripts/quality/terrain_quality.gd       地表贴图分辨率 + 地形 LOD
##       - scripts/quality/grass_quality.gd         草贴图分辨率
##       - scripts/quality/shadow_quality.gd        平行光阴影绘制距离
##       - scripts/quality/prop_texture_quality.gd  道具贴图分辨率
##       - scripts/settings/settings_apply.gd       设置界面的"画质"选项 → 调用本单例
##   · 反例（**故意不订阅**本档位，别搞混）：scripts/world/prop_visibility.gd 用的是
##     引擎级 visibility_range 视距剔除，其文件头明确写了"画质档不碰模型" ✓。
##
## ============================ 关键依赖 ============================
## 1. **autoload**：project.godot 的 autoload 段里注册为 Quality
##    （Quality="*res://scripts/quality/quality_manager.gd"）。
##    → 因此其它脚本既可用 QualityManager.instance，也可用 get_node_or_null("/root/Quality")；
##      后者在编辑器里更安全（见"坑"第 3 条）。
## 2. **QualityTiers**（scripts/quality/quality_tiers.gd）：档位枚举 Tier、名称表、参数表 PRESETS。
##    本文件的 clampi 上下界直接引用 QualityTiers.Tier.LOW / .ULTRA —— 两处必须一致；
##    若将来增删 Tier 枚举，本文件会自动跟随 ✓，但 settings_apply.gd 里写死的
##    clampi(tier, 0, 3) 需要人工同步 ✗。
## 3. **资源路径**：user://quality.cfg（ConfigFile，段 quality / 键 tier，存 int）。
##    刻意用 user:// 而非 res:// —— 导出后 res:// 是只读的，写不进去 ✗。
## 4. **无场景依赖**：不需 @export、不引用任何节点路径，可被测试脚本直接 new 出来跑 ✓。
##
## ============================ 主要对外接口 ============================
## · QualityManager.instance        : 静态单例引用（_ready 赋值，_exit_tree 置空）
## · tier                           : 当前档位 int，0~3（**只读语义**，改动请走 set_tier）
## · set_tier(t: int) -> void       : 唯一推荐的切档入口（自动夹紧 + 持久化 + 广播）
## · get_preset() -> Dictionary     : 取当前档位的参数表（转发 QualityTiers）
## · save_tier() / load_tier()      : 手动存 / 读档位（一般不需要自己调）
## · signal tier_changed(tier: int) : 档位广播（注意：_ready 时也会发一次，见"坑"第 2 条）
##
## ============================ 已知的坑与注意事项 ============================
## ⚠ 1. **必须用 set_tier() 改档位，不要直接写 tier = x**：
##       tier 是普通变量、**没有 setter** → 直接赋值既不持久化也不发信号，
##       订阅者会停留在旧参数上，表现为"设置界面改了但画面没变"的迷惑现象 ✗。
## ⚠ 2. **_ready 里的 tier_changed 是"状态广播"，不保证被收到**：
##       autoload 的 _ready 早于场景树里所有节点 → 在场景节点 _ready 里才 connect 的订阅者
##       **必然错过这一发** ✗，所以订阅者都额外自己调一次 apply_current() 兜底 ✓；
##       同理，autoload 列表里排在 Quality 之后的 autoload 也会错过。
## ⚠ 3. **@tool 但编辑器里 autoload 不加载**：
##       instance 在编辑器里通常仍是 null ✗ → 编辑器侧取用请用
##       get_node_or_null("/root/Quality") 兜底（settings_apply.gd 就是这么写的 ✓）。
## ⚠ 4. **重复实例会互相覆盖 instance**：若某个场景里又手挂了一个 QualityManager 节点，
##       后进入 _ready 的那个会把自己的指针写进 instance，而 /root/Quality 仍是 autoload 那个
##       → 两处拿到不同对象 ✗。_exit_tree 里用 if instance == self 做保护，避免误清新实例 ✓。
## ⚠ 5. **save_tier() 丢弃了 cfg.save() 的返回码**（推测是有意为之）：
##       存档目录不可写时不会抛异常，只在控制台留一行错误；档位在本次运行内仍然有效，
##       只是下次启动会丢失 ✗。
## ⚠ 6. tier 的默认值是 HIGH(2)：与 QualityTiers.PRESETS 里 HIGH 的 4k 贴图 / 128m LOD 对应，
##       即"首次运行（还没有 cfg 文件）时用高画质" ✓。想改首启默认值就改下面 var tier 声明处的初始化，
##       但**对已有存档的机器无效** ✗（_ready 会用 cfg 里的值覆盖它）。
##
## ============================ 简单用法 ============================
##   if QualityManager.instance != null:
##       QualityManager.instance.set_tier(QualityTiers.Tier.LOW)
##   print(QualityManager.instance.get_preset()["view_distance"])   # 读当前档参数

# ==================== 信号与常量 ====================
## 档位变化广播：参数为新档位 int（0~3，语义同 QualityTiers.Tier）。
## 谁在听（当前项目）：terrain_quality / grass_quality / shadow_quality / prop_texture_quality 等。
## 参数 tier：变化**之后**的档位值（已夹紧，一定落在 LOW~ULTRA 内）。
## 注意：_ready 里**无条件**也会发一次（即使刚从 cfg 读出、值没变）→ 它的语义是
##       "当前档位广播"而不是严格的"变化"通知；但场景节点通常在 _ready 里才 connect，
##       会错过这一发 ✗（所以订阅者都要自己再应用一次当前档位）。
signal tier_changed(tier: int)

## 档位存档路径（ConfigFile 格式：段 "quality" / 键 "tier" / 值 int）。
## 用 user:// 而不是 res://：导出后 res:// 只读，写不进去 ✗。
## 想"重置为默认档位"最省事的做法就是删掉这个文件 ✓。
## 注意：路径是项目级固定的，**没有做多套配置 / 多用户隔离**（推测当前够用 ✓）；
##       也没有版本号字段 —— 将来若改动"档位编号的含义"，老存档会被按新含义解读 ✗。
const CFG_PATH := "user://quality.cfg"

# ==================== 单例与档位状态 ====================
## 静态单例引用：由 _ready 赋值为 self，由 _exit_tree 在合适时机置空。
## 用法：if QualityManager.instance != null: QualityManager.instance.set_tier(...)
## 为什么用静态变量而不是每次都 get_node("/root/Quality")？
##   因为**测试脚本 / 编辑器**里 autoload 可能根本不存在，静态引用 + 节点名兜底两条路并存
##   兼容性最好 ✓（settings_apply.gd 就是先试 instance、再退回节点名）。
## 副作用：读它本身无副作用；但要先判 null（在编辑器里、或节点尚未 _ready 时它是 null）。
## 类型标注为 QualityManager 而非 Node → 拿到手就能直接调 set_tier，无需强转 ✓。
static var instance: QualityManager = null

## 当前画质档位：0=LOW 低 ｜ 1=MEDIUM 中 ｜ 2=HIGH 高 ｜ 3=ULTRA 极高（语义见 QualityTiers.Tier）。
## 默认值 HIGH(2) 的理由：对应 4k 地表贴图 / 128m 地形 LOD0 / 阴影档 2 / 视距 180m，
##   观感与性能比较均衡，作为"没有存档时的首启默认"很稳妥 ✓。
##   想降低首启门槛：改成 MEDIUM(1) 或 LOW(0)（注意对已有 quality.cfg 的机器无效 ✗，
##   因为 _ready 会立刻用存档里的值覆盖它）；想更激进就改 ULTRA(3)。
## ⚠ 只读语义：本变量**没有 setter**，直接 tier = x 既不会落盘也不会发信号 ✗
##   → 改档位请一律调用 set_tier()（见文件头"坑"第 1 条）。
## 取值范围：正常运行时恒为 [QualityTiers.Tier.LOW, QualityTiers.Tier.ULTRA]，即 0~3。
## 单位：无（枚举序号），不是"画质等级分数"，别拿它做插值。
var tier: int = QualityTiers.Tier.HIGH


# ==================== 生命周期 ====================
## 生命周期回调：作为 autoload 在引擎启动时被自动调用一次（**不要手动调用**）。
##
## 参数：无。
## 返回值：无。
##
## 作用（按顺序）：
##   1) 把 self 登记为静态单例 instance（供全局 QualityManager.instance 访问）；
##   2) 从 user://quality.cfg 恢复上次的档位（load_tier）；
##   3) 无条件广播一次 tier_changed(tier)，让"已经就绪"的听众拿到初始档位。
##
## 副作用：
##   · 写静态变量 instance（全局可见状态）；
##   · 读磁盘 user://quality.cfg；
##   · 发信号 tier_changed。
##
## 调用时机：引擎启动 → autoload 挂到 /root 下 → 本节点的 _ready。
##   早于场景树里所有节点的 _ready（也早于 autoload 列表里排在 Quality 之后的那些）。
##
## 注意事项：
##   · 这里**刻意不调用 set_tier()**：set_tier 在"值没变"时会 early-return、
##     在"值变了"时会再 save 一次 —— 刚读出来的值没必要回写磁盘 ✗（也避免启动期无谓写盘）；
##   · 场景节点在 _ready 里才 connect 信号 → **收不到上面第 3 步这一发** ✗，属预期行为，
##     订阅者各自在 _ready 里兜底应用一次当前档位 ✓；
##   · @tool 使它在编辑器里也可能被调用，但编辑器不加载 autoload → 编辑器内 instance 通常仍是 null。
func _ready() -> void:
	# 先登记单例再读档：这样读档过程中若有任何回调来访问 instance，也不会拿到 null ✓
	instance = self
	load_tier()
	# 必发一次（即使值没变）：这是"初始状态广播"，供已就绪的听众（多为更早注册的 autoload）同步 ✓
	emit_signal("tier_changed", tier)


## 生命周期回调：本节点离开场景树时自动调用（autoload 一般在退出游戏 / 换主场景树时触发）。
##
## 参数：无。
## 返回值：无。
##
## 作用：清空静态单例引用，避免 instance 长期指向一个已释放（freed）的对象 ——
##       否则退出阶段其它脚本再访问 QualityManager.instance 就会拿到悬空引用并报错 ✗。
##
## 副作用：**可能**把静态变量 instance 置为 null（仅当它确实指向自己时）。
##
## 调用时机：引擎销毁本节点时（游戏退出）。**顺序不保证**先于其它节点的 _exit_tree
##   → 所以不能假设"到这里时已经没人会再用 instance 了"。
##
## 注意事项：if instance == self 这个判断必不可少 ✓ ——
##   若场景里存在第二个 QualityManager 实例、且它已经把 instance 覆盖成自己，
##   本实例退出时**不许**清空（否则等于把别人的引用误删 ✗）。
func _exit_tree() -> void:
	# 只在"我仍是当前登记的单例"时才清空，防止误删后来者的引用 ✗
	if instance == self:
		instance = null


# ==================== 对外接口：切档 / 查询 ====================
## 切换画质档位（**唯一推荐的对外入口** ✓）。
##
## 参数 t：目标档位，语义见 QualityTiers.Tier：
##   0 = LOW 低 ｜ 1 = MEDIUM 中 ｜ 2 = HIGH 高 ｜ 3 = ULTRA 极高。
##   允许传任意 int：越界值会被**静默夹紧**到 [LOW, ULTRA]，不会报错也不会拒绝 ✓
##   （例：-5 → 0；99 → 3）。传 float 也能调（形参是 int，会隐式取整）。
## 返回值：无（void）。想知道到底生效没有，请自行比较调用前后的 tier，
##   或连接 tier_changed —— 注意值相同时**不发信号** ✗，无法用信号判断"这次被忽略了"。
##
## 副作用（按顺序，缺一不可）：
##   1) 写成员变量 tier；
##   2) 落盘 user://quality.cfg（save_tier）→ **写文件**；
##   3) 发信号 tier_changed(tier) → 各订阅者去改贴图 / LOD / 阴影 / 视距（可能较耗时 ✗）；
##   4) 打一行中文日志（含档位中文名与**整张参数表 Dictionary**，所以日志看起来很长，属正常 ✓）。
##
## 调用时机：设置界面改"画质"选项时（经 settings_apply.apply_tier）、测试脚本、调试命令。
##
## 注意事项：
##   · **幂等短路**：传入与当前相同的档位会直接 return —— 不落盘、不发信号、不打日志 ✓
##     因此无法用 set_tier(当前值) 来"修复 / 重写"cfg ✗（要修就删掉 cfg 文件，或直接改 load_tier 的兜底值）；
##   · 每次真实切档都会**重写整个 cfg 文件**，没有防抖、没有合并；同一帧里连续切多档就写多次磁盘
##     （推测影响可忽略：文件只有几行，且切档是低频的用户操作 ✓）；
##   · 本函数只改"画质档位"，**不碰 Settings autoload 里的 quality** ——
##     那两套系统由 settings_apply.apply_tier() 同时驱动，别忘了它 ✓；
##   · 若订阅者抛错，错误会顺着信号回调冒上来，导致后面的订阅者收不到本档 ✗（推测当前无人抛错 ✓）。
func set_tier(t: int) -> void:
	# 夹紧到合法档位：设置界面 / 存档 / 测试都可能传越界值，静默修正比报错更稳 ✓
	t = clampi(t, QualityTiers.Tier.LOW, QualityTiers.Tier.ULTRA)
	# 值没变就不落盘、不广播、不打日志 —— 避免无谓写盘与重复应用整套画质 ✓
	if t == tier:
		return
	tier = t
	save_tier()
	emit_signal("tier_changed", tier)
	print("[画质] 档位切换为 %s（%s）" % [QualityTiers.tier_name(tier), QualityTiers.get_preset(tier)])


## 取"当前档位"对应的完整参数表。
##
## 参数：无（隐式使用成员变量 tier）。
## 返回值：Dictionary，直接转发 QualityTiers.get_preset(tier)，键与取值含义：
##   "terrain_texture_suffix" : String，地表贴图分辨率后缀，"1k" / "2k" / "4k"；
##   "terrain_lod0_range"     : float，单位米，LOD0 的作用半径（64 / 96 / 128 / 192）；
##   "terrain_mesh_size"      : int，地形网格尺寸（32 / 48 / 64），越大越省 draw call 但 LOD 粒度越粗；
##   "shadow_quality"         : int，0~3，阴影档位序号（由 shadow_quality.gd 翻译成阴影距离 40/70/110/160 米）；
##   "view_distance"          : float，单位米，视距（80 / 120 / 180 / 260）。
## 副作用：无 —— 纯查询，不落盘、不发信号、不改状态 ✓（可在 _process 里随便调）。
##
## 调用时机：订阅者收到 tier_changed 后取本档参数；设置界面显示"当前档位参数"时。
##
## 注意事项：
##   · 返回的是 QualityTiers.PRESETS 里的**同一个字典对象**（GDScript 传引用而非深拷贝；
##     较新版本的 const 容器可能被标为只读 —— 推测）→ 调用方请**只读使用**，
##     原地修改它可能污染全局档位表 ✗（当前项目里都只读 ✓）；
##   · tier 恒为 0~3，所以几乎不会走到 QualityTiers.get_preset 内部的 MEDIUM 兜底分支 ✓。
func get_preset() -> Dictionary:
	return QualityTiers.get_preset(tier)


# ==================== 持久化（user://quality.cfg） ====================
## 把当前档位写入磁盘。
##
## 参数：无。返回值：无。
## 写入内容：段 "quality" / 键 "tier" / 值 = 成员变量 tier（int）。
## 写入路径：常量 CFG_PATH = user://quality.cfg
##   （Windows 上通常落在 %APPDATA%\Godot\app_userdata\<项目名>\quality.cfg 之类；
##    用 user:// 而非 res:// 是因为导出后 res:// 只读 ✗）。
##
## 副作用：**写文件** —— 每次都新建 ConfigFile 并整体覆盖保存，不做增量合并
##   （文件只有几行，没必要为它做优化 ✓）。
##
## 调用时机：set_tier() 内部会调（这才是常态）；
##   也可在测试脚本里手动调用来验证持久化。
##
## 注意事项：
##   · cfg.save(CFG_PATH) 的返回值（Error）**被丢弃** ✗ ——
##     磁盘满 / 目录不可写时不会异常、不会中断流程，只在控制台留一行错误；
##     档位在本次运行内照常生效，只是下次启动会丢 ✗；
##   · 本函数**不发信号、不改内存状态**，只反映当前 tier ✓；
##   · 若你绕过 set_tier 直接改了 tier，再调本函数能把新值落盘，
##     但订阅者依然收不到通知 ✗（不推荐这条路径）。
func save_tier() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("quality", "tier", tier)
	cfg.save(CFG_PATH)


## 从磁盘恢复档位（_ready 时自动调用；也可手动调用做"重新读取"）。
##
## 参数：无。
## 返回值：无 —— **读失败既不报错也不返回错误码** ✗，
##   靠"提前 return、保留当前 tier"来表达失败。
##
## 行为细节：
##   · 文件不存在 / 解析失败（cfg.load(CFG_PATH) != OK）→ 直接 return，
##     tier 保持默认值 HIGH(2) ✓（首次启动即高画质）；
##   · 读到的值先 int() 再 clampi 夹紧到 [LOW, ULTRA] → 手改坏的 cfg（写 99、
##     甚至写成 "abc"）也不会让系统进入非法档位 ✓；
##   · 读键时带了默认值参数 tier → 键缺失时保持当前值（同样是"不覆盖"语义 ✓）。
##
## 副作用：读文件；**可能修改成员变量 tier**。
## 注意：它**不发信号也不落盘** ✓ ——
##   运行时手动调用后，订阅者只会发现 tier 悄悄变了却收不到信号 ✗；
##   运行时想"重新读档并生效"，正确姿势是 set_tier(新值)（但若新值恰好等于当前值会被短路 ✗）。
##
## 调用时机：_ready 里（在任何订阅者连接之前，安全）；测试里也可能直接调用。
func load_tier() -> void:
	var cfg := ConfigFile.new()
	# 读失败（文件不存在 / 内容损坏）就保持默认档位：不报错、也不顺手覆盖存档 ✓
	if cfg.load(CFG_PATH) != OK:
		return
	# 二次防线：手改过的 cfg 里可能是 99 或 "abc"，int() + clampi 保证 tier 永远合法 ✓
	tier = clampi(int(cfg.get_value("quality", "tier", tier)), QualityTiers.Tier.LOW, QualityTiers.Tier.ULTRA)

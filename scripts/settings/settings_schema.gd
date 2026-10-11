# ============================================================================
# settings_schema.gd —— 设置项的"唯一真相源"（纯数据 + 静态查询，无状态、无副作用）
# ============================================================================
# 【所属系统】设置系统（scripts/settings/）。同目录分工：
#   · settings_schema.gd（本文件）—— 定义"有哪些设置项、每项长什么样"：键名 / 控件类型 /
#     分类 / 默认值 / 取值范围 / 是否占位；是本系统数据层的**唯一真相源** ✓
#   · settings_store.gd   —— 值的内存持有 + user://settings.cfg 落盘（改动即时落盘并发 changed 信号）
#   · settings_apply.gd   —— 把值翻译成对引擎的真实调用（画质 / 音频 / 显示 / 辅助功能）
#   · settings_menu.gd    —— 纯代码构建的设置菜单，直接遍历本文件的分类与条目来造控件
#   · settings_input.gd   —— 按键绑定的还原与改写（那些键（如 input/bindings）**不在**本 schema 里，
#     落盘时靠 settings_store.gd 里那个 allowed_extra 白名单才放行）
#   · game_settings.gd    —— autoload 单例 GameSettings，把上面几者串起来的总控
#   本文件位于调用链最底层，被 store（取默认值、校验键）、apply（遍历键、值↔索引换算）、
#   menu（分类 / 条目 / 控件类型）以及 tests/test_settings.gd 共同依赖 ✓。
#
# 【本文件职责】
#   1) Kind 枚举            —— 一个条目用哪种界面控件（开关 / 滑条 / 下拉 / 只读信息）；
#   2) CAT_* 常量 + ORDER   —— 分类的中文显示名（同时是数据字典的键）与菜单里的显示顺序；
#   3) items()              —— "分类 → 条目数组"的总表，本文件的核心数据（唯一来源）；
#   4) 一组 static 查询工具 —— all_items / find / is_todo / defaults / kind_name /
#                              choice_value / value_to_index。
#
# 【关键依赖】无 autoload、无信号、无资源路径、不读写文件、不改场景树 ✓ ——
#   本类 extends RefCounted 且所有方法都是 static，**从不需要 new 出来**。
#   唯一的"隐式契约"是条目字典的字段名（见下）与其它文件里硬编码的设置键字符串。
#
# 【主要对外接口】（调用形如 SettingsSchema.find("audio/music")）
#   · items() -> Dictionary                     分类(String) → 条目数组(Array[Dictionary])
#   · all_items() -> Array                      拍平后的条目数组，每条额外带 "category" 字段
#   · find(key) -> Dictionary                   按键名查条目；**查不到返回空字典 {}**（不是 null）
#   · is_todo(key) -> bool                      该项是否仍是"功能未做、仅占位"
#   · defaults() -> Dictionary                  key → 默认值（**没写 "default" 的条目值为 null**，见坑 4）
#   · kind_name(k) -> String                    控件类型的中文名（日志 / 调试文案用）
#   · choice_value(key, index) -> Variant       下拉索引 → 真正要存储的值
#   · value_to_index(key, value) -> int         真正存储的值 → 下拉索引
#   · Kind / CAT_* / ORDER                      常量，供菜单与测试直接引用
#
# 【条目字典的字段契约】（跨文件口头契约：名字拼错**不会报错**，只会静默失效 ✗）
#   必填："key"   String —— 形如 "分类/名称"；落盘时 SettingsStore.save() 按 "/" 拆成
#                          ConfigFile 的 section 与键名，所以 key 里别多写斜杠；
#         "label" String —— 界面显示名（缺了会回落成显示 key 本身）；
#         "kind"  Kind   —— 控件类型，决定 settings_menu.gd 的 match 分支。
#   按 kind 选填：
#     · TOGGLE —— 无附加字段（值就是 bool）
#     · SLIDER —— "min"/"max"（浮点上下限）与 "step"（离散步长，界面用 snappedf 吸附）
#     · CHOICE —— "choices"(Array[String]) 下拉里显示的文字，
#                 可选 "values"(Array) 与 choices **等长**的真实值表（见 choice_value）
#     · INFO   —— "value_text"(String) 静态文本；运行时会被
#                 SettingsApply.about_info() 里同名 key 的值覆盖（settings_menu.gd 按 key 回填）
#   可选："default"（默认值；INFO 类故意不写 → defaults() 里是 null）、
#         "todo"（true = 功能未实现：界面照常显示但置灰、并标"（待开发）"）、
#         "hint"（String，条目下方的浅色说明文字）
#
# 【已知的坑与注意事项】
#   ⚠ 1. **新增一个设置项要同时改多处**才会真正生效：本文件 items() 里登记 +
#         settings_apply.gd 的 apply_one() 里加对应分支（漏了会静默软着陆成 "todo" ✗）。
#         "界面能改、引擎不生效"就是这么来的。
#   ⚠ 2. **items() 每次调用都重新构造一份字典字面量** → 返回对象可被调用方随意修改，
#         绝不会污染其它调用方 ✓（all_items() 因此在循环里反复调它也安全）。
#         代价：每次查询都要重建整表，而 find() 还是线性扫描 → 别放进每帧的热路径 ✗。
#   ⚠ 3. **find() 查不到返回 {} 而不是 null** → 判空必须用 d.is_empty()，
#         写 == null 判断永远为 false ✗（settings_apply.gd 用的就是 is_empty() ✓）。
#   ⚠ 4. **INFO 类条目没有 "default"** → defaults() 里这些 key 的值是 null，而
#         SettingsStore.save() 遍历的是 store 里的全部键 → cfg 里也会跟着写下 null 条目
#         （无害：读回来还是 null，界面显示由 SettingsApply.about_info() 覆盖，不靠 default ✓（推测））。
#   ⚠ 5. **只有带 "values" 的 CHOICE 才会做"索引 ↔ 真实值"换算**；没有 values 的 CHOICE，
#         存进 store 的就是**下拉索引本身(int)** ✓，所以 default 要按索引给
#         （如 graphics/fps_limit 的 default 语义有坑，见该条目处的说明）。
#   ⚠ 6. **value_to_index 找不到时返回 0、不返回 -1** → 非法/过期值会静默显示第一个选项、
#         不报错；排查"设置显示不对"时先怀疑存档里的值与 values 表对不上。
#   ⚠ 7. **分类顺序以 ORDER 为准**：settings_menu.gd 左侧按钮直接遍历 ORDER，
#         tests/test_settings.gd 还断言了分类数 = 7 → 增删分类必须同步改 ORDER、CAT_* 与测试 ✗。
#   ⚠ 8. 本文件**不校验** key 的拼写与重复：重复 key 会让 find() 只命中第一个、
#         defaults() 里后写的覆盖前一个 ✗（纯数据表的通病，改表时自己盯住 ✓（推测））。
# ============================================================================
@tool
class_name SettingsSchema
extends RefCounted
## 设置项定义表（纯数据 ✓ 便于单测）
##
## 说明：
##   · 分类与条目覆盖常规游戏的设置菜单（画质/音频/语言/操作/游戏/辅助/关于）
##   · todo=true 表示"**功能还没做，先占位**" —— 界面上照常显示，但控件置灰并标注（待开发）
##   · 已经能真生效的：画质档位（接 Quality 系统 ✓）、音量（真实音频总线 ✓）、
##     窗口模式 / 垂直同步 / 帧率上限 / 界面缩放 ✓

# ==================== 控件类型与分类常量 ====================
## 条目的界面控件类型 —— 决定 settings_menu.gd 的 _make_row 走哪个 match 分支建控件，
## 也间接决定 settings_apply.gd 用哪种方式把值落到引擎。
## 取值：TOGGLE=复选框(0) / SLIDER=滑条(1) / CHOICE=下拉(2) / INFO=只读文字(3)。
## 声明顺序即数值，但代码里一律用 Kind.XXX 符号比较 → 顺序本身不影响行为 ✓。
## ⚠ 真正要注意的是：新增一种 kind 必须**同时**改 settings_menu.gd（造控件）与
##   settings_apply.gd（怎么落地），只加枚举不会有人处理它 ✗。
enum Kind { TOGGLE, SLIDER, CHOICE, INFO }

# ---- 分类常量：值就是设置菜单左侧那一列按钮上的中文文字，同时充当 items() 字典的键 ----
# ⚠ 这些字符串是**键**不是文案：改它们等于同时改了 items() 的键、落盘 cfg 的 section 名
#   （SettingsStore.save() 按 "/" 取前缀）以及老存档的兼容性 ✗ → 发布后只新增、不改名。
## 「画质」页：档位 / 窗口模式 / 垂直同步 / 帧率上限 / 抗锯齿 / 阴影 / 贴图（本页落地最完整 ✓）
const CAT_GRAPHICS := "画质"
## 「音频」页：主音量与四条子总线的音量滑条（真实写 AudioServer ✓）
const CAT_AUDIO := "音频"
## 「语言」页：界面语言（占位）与字幕开关（已接字幕系统 ✓）
const CAT_LANGUAGE := "语言"
## 「操作」页：鼠标灵敏度 / 纵向反转（目前均为占位）。按键绑定**不写在本文件里** ——
## 它是运行时状态，由 settings_menu.gd 动态生成（见 settings_input.gd）✓
const CAT_CONTROLS := "操作"
## 「游戏」页：难度 / 自动存档间隔 / 显示帧率 / 新手提示（目前均为占位）
const CAT_GAMEPLAY := "游戏"
## 「辅助功能」页：界面缩放（真生效 ✓）/ 色盲模式 / 字幕大小 / 减少动态效果（占位）
const CAT_ACCESS := "辅助功能"
## 「关于」页：全部是 INFO 只读信息（版本 / 引擎 / 渲染设备 / 内存 / 存档与崩溃目录）
const CAT_ABOUT := "关于"

## 分类在设置菜单里的**显示顺序**（settings_menu.gd 遍历它建左侧按钮、测试遍历它逐页构建）。
## ⚠ 它同时是 all_items() 的遍历顺序 → 也就是 find() 在 key 重复时"谁先命中"的顺序。
## ⚠ 增删分类必须同时改这里 + 上面的 CAT_* 常量 + items() 里的数据；
##   tests/test_settings.gd 断言"逐页构建 7 次"，分类数一变测试直接失败 ✗（这是有意的护栏 ✓）。
const ORDER := [CAT_GRAPHICS, CAT_AUDIO, CAT_LANGUAGE, CAT_CONTROLS, CAT_GAMEPLAY, CAT_ACCESS, CAT_ABOUT]


# ==================== 设置项总表 items() ====================
## 返回**全部设置项**：分类字符串 → 条目数组（每个条目是一个 Dictionary，字段契约见文件头）。
##
## 参数：无。
## 返回值：Dictionary —— 键是 CAT_* 常量的中文值，值是该分类的 Array[Dictionary]。
##   ★ 每次调用都返回**全新构造**的字典字面量（不是缓存的成员变量）→ 调用方可以随意增删改，
##     绝不会影响到别处 ✓；反过来也别指望改它能"改到 schema"（下次调用又变回原样）✗。
## 副作用：无（纯构造；不改状态、不发信号、不写文件、不碰场景树）。
## 调用时机：settings_menu.gd 每次切页取当前分类的条目；
##   settings_store.gd / settings_apply.gd 则通过 all_items() 间接使用它；
##   测试里直接遍历它做校验。
## 注意事项：
##   · **新增设置项就加在这里** —— 但别忘了同时去 settings_apply.gd 的 apply_one() 加分支 ✗
##     （见文件头坑 1：只改这里会让该项"界面能改、引擎不生效"）；
##   · 每个条目的 key 都是字符串字面量，拼错**不会报错**，只会变成一个"谁都对不上的键" ✗；
##   · 同一个分类内条目按书写顺序显示（settings_menu.gd 顺序 add_child ✓）；
##     分类之间的显示顺序不在这里，而在上面的 ORDER 里 ✓；
##   · todo=true 只影响"界面是否可操作 / apply 返回什么状态"，**不影响默认值照样写进 store** ✓。
static func items() -> Dictionary:
	return {
		CAT_GRAPHICS: [
			# ── 画质档位：整套画质的"总开关"，落地点是 settings_apply.apply_tier() ──
			# 取值：**下拉索引 0~3**（本条目没有 values 表，所以存的就是索引本身）；
			#   0=低 1=中 2=高 3=极高。apply_tier 会把它同时写进"项目原有 Settings 单例的
			#   quality 属性（MSAA / 模型 LOD / 草丛 / 植被距离 / 体积雾）"与"新增 Quality 系统的
			#   set_tier()（地表贴图分辨率 / 地形 LOD）"→ 这是两套画质系统唯一的合并点 ✓。
			# 默认 2（=高）的理由（推测）：低档地表贴图明显糊，极高档的贴图/图集显存与带宽开销大；
			#   取中间偏上，让"没动过设置"的画面看起来正常又不越界。
			# 调小=更省性能更糊、调大=更清晰更吃显存；越界值由 apply_tier 内 clampi 夹到 0~3 ✓。
			{"key": "graphics/tier", "label": "画质档位", "kind": Kind.CHOICE, "default": 2,
				"choices": ["低", "中", "高", "极高"],
				"hint": "同时控制地表贴图分辨率与地形 LOD ✓（已接画质分级系统）"},
			# ── 窗口模式：0=窗口 1=无边框全屏 2=独占全屏（无 values 表 → 存的就是索引）──
			# 默认 0（窗口）：对多显示器 / 调试最友好，也最不容易把玩家"锁"在坏状态里；
			#   编辑器内改这一项会被 apply_one 拦成 "editor-skip"（否则会改掉编辑器自己的窗口 ✗）。
			# ⚠ apply_display() 里是"三项整组重写"：改窗口模式会顺手把同步与帧率也写一遍 ✓
			#   （它们互相牵制，逐项单独写会留下中间状态）。
			{"key": "graphics/window_mode", "label": "窗口模式", "kind": Kind.CHOICE, "default": 0,
				"choices": ["窗口", "无边框全屏", "独占全屏"]},
			# ── 垂直同步：默认**开** ──
			# 开着能消除画面撕裂、帧率与显示器刷新率对齐；代价是略微增加输入延迟、并把帧率封顶在刷新率。
			# 想要最低延迟（竞技向）的玩家可关掉 → 关掉后可能出现撕裂，属预期取舍，不是 bug ✓。
			{"key": "graphics/vsync", "label": "垂直同步", "kind": Kind.TOGGLE, "default": true},
			# ── 帧率上限：**本条目是全表唯一"索引 ↔ 真实值"两套体系混用的地方，注意语义** ──
			# choices 是给人看的文字，values 是实际写进 Engine.max_fps 的数字（0 = 不限制）；
			# 界面能选 → 存 values[i]（真实值，如 60），回填 → value_to_index() 反查索引 ✓。
			# ⚠ 已知不一致（推测为历史遗留，**不是笔误**）：default 写的是 2，但 2 **不在 values 表里**
			#   （values 是 [0,30,60,120,144]）→ SettingsStore.reset_all() 会把 2 当"真实值"存进 store，
			#   而 value_to_index("graphics/fps_limit", 2) 查不到 2 就回落索引 0
			#   → 全新安装时**实际生效与界面显示都是"不限制"**（两边自洽，所以不易被发现 ✓）；
			#   若本意是"默认 60"，正确写法是把 default 改成 60（真实值）而不是 2 ✗。
			{"key": "graphics/fps_limit", "label": "帧率上限", "kind": Kind.CHOICE, "default": 2,
				"choices": ["不限制", "30", "60", "120", "144"], "values": [0, 30, 60, 120, 144]},
			# ── 抗锯齿：0=关 1=FXAA 2=MSAA 2x 3=MSAA 4x（无 values 表 → 存索引）──
			# 默认 3（MSAA 4x）的理由：与项目原本的渲染设置一致 → "用户没动过设置" = "画面保持原样" ✓
			#   （apply_aa 里也是按这个约定写的，两处要一起改 ✗）。
			# ⚠ hint 说的"画质档位也会联动这一项"是**经由项目原有 Settings 单例的 quality 处理**发生的，
			#   链路不在本文件（推测）→ 所以在这里改 default 并**不会**改变档位联动出来的值 ✓。
			# FXAA 与 MSAA 互斥：apply_aa 里只有 index==1 才开 FXAA，其它档位一律关（叠加会又糊又有锯齿 ✗）。
			{"key": "graphics/aa", "label": "抗锯齿", "kind": Kind.CHOICE, "default": 3,
				"choices": ["关", "FXAA", "MSAA 2x", "MSAA 4x"],
				"hint": "默认与项目现状一致（MSAA 4x ✓）；「画质档位」也会联动这一项 ✓"},
			# ── 阴影质量：0=低 1=中 2=高 3=极高（无 values 表 → 存索引）──
			# 该索引同时是 settings_apply.gd 里两张常量表（柔化质量 / 阴影图集边长）的下标：
			#   索引 2 → 图集 4096、柔化质量 3；索引 3 → 8192（显存按边长平方暴涨 ✗）。
			# 默认 2（高）而不是 3（极高）：极高档图集显存占用已是数百 MB 量级，默认不该那么贪 ✓。
			# ⚠ 只改本文件不会影响阴影**绘制距离** —— 那是画质分级系统里 shadow_quality.gd 按档位管的 ✓。
			{"key": "graphics/shadow", "label": "阴影质量", "kind": Kind.CHOICE, "default": 2,
				"choices": ["低", "中", "高", "极高"], "hint": "全局方向光阴影精度与图集大小 ✓"},
			# ── 贴图质量：**todo 占位项**，因为它的效果已被上面的「画质档位」整体接管 ──
			# 之所以还留着：菜单里保留这一行作为"入口说明"，玩家能看到贴图质量受哪里控制 ✓。
			# ⚠ todo=true 会让 settings_apply.apply_one 在**任何落地逻辑之前**就返回 "todo"
			#   （它先判 todo，再才分流到 BUS_OF / match）→ 标了 todo 的项不会落到引擎 ✓。
			{"key": "graphics/texture", "label": "贴图质量", "kind": Kind.CHOICE, "default": 2,
				"choices": ["低", "中", "高", "极高"], "todo": true,
				"hint": "已由上面的「画质档位」统一控制 ✓"},
		],
		CAT_AUDIO: [
			# ── 主音量（落到音频总线 "Master"）──
			# 值域 0.0~1.0 的**线性**音量：1.0 = 0dB（原始音量）、0.0 = 静音；步长 0.01 由界面滑条吸附。
			# apply_bus 会先 clampf 到 0~1，再用 linear_to_db() 换算成 dB 写进 AudioServer ✓。
			# 默认 1.0：总输出不该在"玩家没动过设置"时被压掉 ✓。
			# ⚠ 拉到 0 时**不是**写 -inf dB，而是走 set_bus_mute（linear_to_db(0) 是负无穷 ✗），
			#   静音阈值取 0.001 以容忍滑条的浮点残渣 ✓。
			# 调大超过 1.0 没有意义（会被 clampf 截断）→ 想整体放大请改项目的音频总线增益，别改这里 ✗。
			{"key": "audio/master", "label": "主音量", "kind": Kind.SLIDER, "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01},
			# ── 音乐（总线 "Music"，BGM）──
			# 默认 0.8 而不是 1.0（推测）：给背景音乐留一点余量，避免盖住音效与对白 —— 这是常见的调音惯例。
			# 调大=音乐更突出（可能压过音效）、调小=氛围更弱；0 = 静音该总线（音乐仍在播放，只是听不到 ✓）。
			# ⚠ 总线是运行时按需创建的：值先落盘、总线后建，ensure_buses() 里"先建后设"的顺序不能反 ✗。
			{"key": "audio/music", "label": "音乐", "kind": Kind.SLIDER, "default": 0.8, "min": 0.0, "max": 1.0, "step": 0.01},
			# ── 音效（总线 "SFX"：脚步、砍伐、拾取等反馈音）──
			# 默认 1.0：反馈音是"操作是否生效"的重要信息来源，默认给足（推测）✓。
			# 这是玩家最常调的一项：调小到 0.3~0.5 能明显降低疲劳感，但操作手感反馈也会变弱。
			{"key": "audio/sfx", "label": "音效", "kind": Kind.SLIDER, "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01},
			# ── 界面音效（总线 "UI"：按钮、切页、开关等界面点击音）──
			# 单独一条总线的好处：玩家能只压界面音而保留游戏内音效 ✓（两者需求经常相反）。
			# 默认 0.8（推测）：界面音重复出现频率高，默认略低一点更耐听。
			{"key": "audio/ui", "label": "界面音效", "kind": Kind.SLIDER, "default": 0.8, "min": 0.0, "max": 1.0, "step": 0.01},
			# ── 对话音量（总线 "Voice"）—— **todo 占位项** ──
			# 之所以是 todo：项目目前没有配音/对话语音内容，这一项没有可调的对象 ✓。
			# ⚠ 注意一个反直觉的后果：settings_apply.gd 的 BUS_OF 里**确实**登记了 audio/voice
			#   （看名字像是已经接了），但 apply_one 是"先判 todo 再判 BUS_OF"→ 这一项目前
			#   **连总线音量都不会被应用** ✗。总线本身仍会被 apply_all 开头的 ensure_buses() 建出来
			#   （所以音频总线列表里能看到 Voice，但它是空转的）—— 排查"改了没反应"时先看这里 ✓。
			# 将来接上配音后：把 todo 去掉即可自动开始生效（无需再动 apply 的分流代码 ✓）。
			{"key": "audio/voice", "label": "对话音量", "kind": Kind.SLIDER, "default": 1.0, "min": 0.0, "max": 1.0, "step": 0.01, "todo": true},
		],
		CAT_LANGUAGE: [
			# ── 界面语言 —— **todo 占位项**（目前只有一种语言，等于无可切换）──
			# 存的是**下拉索引**（无 values 表），默认 0 = "简体中文"。
			# todo=true 的原因：项目还没有其它语言的翻译文件（hint 已写明）✓。
			# ⚠ 即使把 todo 去掉也依然点不动效果 —— choices 里只有一项，要先有翻译资源才谈得上切换；
			#   新增语言时必须同步：① 加翻译文件 ② 往 choices 里加显示名（推测做法）。
			{"key": "language/locale", "label": "界面语言", "kind": Kind.CHOICE, "default": 0,
				"choices": ["简体中文"], "todo": true, "hint": "尚未添加其它语言的翻译文件 ✓"},
			# ── 显示字幕：本页唯一**真正生效**的开关 ✓ ──
			# 默认 true：字幕属于可达性 / 无声音环境下的必要信息，默认开更友好 ✓。
			# ★ 它的落地点**不在 settings_apply.gd 里**：apply_one 对 "language/subtitle" 直接返回 "ok"
			#   （不碰引擎），真正读它的是 GameSettings.subtitles_enabled() → show_subtitle() ✓
			#   → 所以本项在 apply 侧"没写逻辑"不是漏写，而是刻意如此 ✓（别照抄去 apply 里加分支）。
			# 时机：只影响**此后**调用的 show_subtitle()；已经显示中的那一条不会立刻消失，
			#   它由 GameSettings._process 的倒计时自然结束（没有监听 changed 信号，推测）✓。
			{"key": "language/subtitle", "label": "显示字幕", "kind": Kind.TOGGLE, "default": true, "hint": "已接字幕系统 ✓：GameSettings.show_subtitle(文本, 秒数)"},
		],
		CAT_CONTROLS: [
			# 注：本数组以一行空行开头（就在这条注释下面）—— 括号内的空行不影响 GDScript 解析，
			#   纯属排版遗留（推测），此处保留原样、不做改动 ✓。
			# ★ 按键绑定**故意不写在本文件里**：绑定是运行时状态（随时可被玩家改、
			#   还要按 InputMap 现状生成），所以由 settings_menu.gd 在"操作"页动态生成一节 ✓
			#   → 别为了"整齐"把绑定硬编码进这个数据表 ✗。

			# ── 鼠标灵敏度 —— **todo 占位项**（界面上滑条置灰/不可编辑）──
			# 值域 0.2~3.0（倍率）、步长 0.05、默认 1.0 = 原速：0.2 极慢，3.0 极快（容易晕）。
			# 范围给这么宽（推测）：不同 DPI 的鼠标与不同握姿差异很大，留足调节空间。
			# ⚠ 目前**没有任何脚本读取它**（todo + apply_one 直接返回 "todo"）→ 界面上"改了没反应"是预期现象 ✓；
			#   将来要接的话，落地点应在相机 / 视角处理的脚本里（具体位置推测，需查 camera 相关脚本 ✗）。
			{"key": "controls/sensitivity", "label": "鼠标灵敏度", "kind": Kind.SLIDER, "default": 1.0,
				"min": 0.2, "max": 3.0, "step": 0.05, "todo": true},
			# ── 反转纵向视角 —— **todo 占位项** ──
			# 默认 false（不反转）：符合大多数玩家的操作习惯，也保证"没动过设置"= 原行为 ✓。
			# 需要它的是"推杆向上 = 视角向上"那类习惯的玩家；接法同样是取负相机俯仰增量（推测，位置同上一项）。
			{"key": "controls/invert_y", "label": "反转纵向视角", "kind": Kind.TOGGLE, "default": false, "todo": true},
		],
		CAT_GAMEPLAY: [
			# ── 难度 —— **todo 占位项**（本页四项全是占位）──
			# 存的是**下拉索引**（无 values 表）：0=轻松 1=标准 2=硬核；默认 1（标准）
			#   = 中间档，也是新玩家最可能接受的档位（推测 ✓）。
			# ⚠ 现阶段没有任何战斗 / 生存系统读它 → 改了不影响游戏（界面上也置灰 ✓）。
			{"key": "gameplay/difficulty", "label": "难度", "kind": Kind.CHOICE, "default": 1,
				"choices": ["轻松", "标准", "硬核"], "todo": true},
			# ── 自动存档间隔 —— **todo 占位项** ──
			# 无 values 表 → default=1 表示**索引 1**，即"5 分钟"（不是 1 分钟 ✗，本表里没有 1 分钟这一档）。
			# 默认取 1（推测意图）：默认开启自动存档，且间隔取最短的一档 → 尽量少丢进度；
			#   若想让默认是"关闭"，应写 0；想要默认其它间隔，就改成对应索引（0=关闭 1=5 分钟 2=10 分钟 3=15 分钟）。
			# 关掉（索引 0）的语义是"只靠手动/退出时存档"（推测，需看将来接上的存档脚本 ✗）。
			{"key": "gameplay/autosave", "label": "自动存档间隔", "kind": Kind.CHOICE, "default": 1,
				"choices": ["关闭", "5 分钟", "10 分钟", "15 分钟"], "todo": true},
			# ── 显示帧率 —— **todo 占位项** ──
			# 默认 false：默认不往画面上叠加调试信息，保持画面干净（推测 ✓）。
			# 接上后应控制 HUD 上一个实时 FPS 标签的显隐（落地点在游戏 UI / HUD 脚本，推测）。
			{"key": "gameplay/show_fps", "label": "显示帧率", "kind": Kind.TOGGLE, "default": false, "todo": true},
			# ── 显示新手提示 —— **todo 占位项** ──
			# 默认 true：面向新手友好（与"难度默认标准"同一取向 ✓）；老玩家可自行关掉。
			# 接上后应控制教程 / 气泡提示的显示（落地点在引导相关脚本，推测）。
			{"key": "gameplay/tutorial", "label": "显示新手提示", "kind": Kind.TOGGLE, "default": true, "todo": true},
		],
		CAT_ACCESS: [
			# ── 界面缩放：本页唯一**真正生效**的项 ✓ ──
			# 值域 0.8~1.4（倍率）、步长 0.05、默认 1.0（原始大小）。
			# 范围为什么不更大（推测）：0.8 以下中文字已经明显难认，1.4 以上 HUD 会挤满屏幕、互相遮挡 ——
			#   这是"可用范围"，与"安全边界"是两回事：apply_ui_scale 内部还会再 clampf 到 0.5~3.0，
			#   那只是防损坏存档（0 或负数会让 UI 消失/翻转 ✗）的兜底，不是给玩家用的档位 ✓。
			# 副作用：写根视口的 content_scale_factor → 立刻缩放所有 CanvasItem（HUD / 菜单 / 字幕），
			#   **不影响 3D 世界**（相机看到的景物大小不变）✓；编辑器内会被 editor-skip 拦下 ✓。
			# ⚠ 实际观感还取决于项目的视口拉伸模式：若拉伸模式为 disabled，可能看不出变化（推测）✓。
			{"key": "access/ui_scale", "label": "界面缩放", "kind": Kind.SLIDER, "default": 1.0,
				"min": 0.8, "max": 1.4, "step": 0.05, "hint": "影响所有 HUD 与菜单大小 ✓"},
			# ── 色盲模式 —— **todo 占位项** ──
			# 存**下拉索引**（无 values 表）：0=关 1=红绿色弱 2=蓝黄色弱；默认 0（关）
			#   = 不改变默认画面 ✓（这类辅助功能绝不该默认开启）。
			# ⚠ 目前没有任何"颜色校正 / 调色板切换"逻辑读它 → 改了不起作用（界面上也置灰 ✓）；
			#   将来落地要么走环境后期调色（WorldEnvironment 的颜色校正），要么换 UI 调色板（推测）。
			{"key": "access/colorblind", "label": "色盲模式", "kind": Kind.CHOICE, "default": 0,
				"choices": ["关", "红绿色弱", "蓝黄色弱"], "todo": true},
			# ── 字幕大小 —— **todo 占位项** ──
			# 存**下拉索引**：0=小 1=中 2=大；默认 1（中）= 中间档最保险，也是 GameSettings 里
			#   现在硬编码的字号（22px）所对应的档位（推测 ✓）。
			# ⚠ 字幕层的字号目前**写死在 GameSettings._ensure_subtitle_layer() 里**（add_theme_font_size_override），
			#   本项没有读取方 → 接上时必须去那里按索引取字号 ✗（否则又是一个"界面能改、没反应"）。
			{"key": "access/subtitle_size", "label": "字幕大小", "kind": Kind.CHOICE, "default": 1,
				"choices": ["小", "中", "大"], "todo": true},
			# ── 减少动态效果 —— **todo 占位项** ──
			# 默认 false：默认保持完整动效（推测取向：不擅自削减表现力 ✓）。
			# 接上后应削减/关闭镜头抖动、UI 过渡动画、粒子密度等（落地点分散在 UI 与相机脚本，推测）。
			{"key": "access/reduce_motion", "label": "减少动态效果", "kind": Kind.TOGGLE, "default": false, "todo": true},
		],
		CAT_ABOUT: [
			# ── 以下 6 项全是 INFO 只读项：不可交互、不表示"用户选择"，只用来展示信息 ──
			# ★ 显示逻辑（settings_menu.gd 的 INFO 分支）：**优先**用 SettingsApply.about_info() 里
			#   同名 key 的值，取不到（或没传 info）才回落到条目自己的 "value_text" ✓
			#   → 所以下面的 value_text 只是"没接上时的占位文案"，不是最终显示内容 ✓。
			# ⚠ 这些 key **都没有 "default"**（见文件头坑 4）：defaults() 里是 null；
			#   而 apply_all() 遍历的正是 defaults() 的键 → 它们也会被送进 apply_one，
			#   最后落到 match 末尾返回 "todo"（没有分支处理它们，无害，但结果字典里会多出这些键 ✓（推测））。
			# ⚠ 键名必须与 SettingsApply.about_info() 返回的键**逐字一致**：菜单是按 key 回填的，
			#   拼错不会有任何报错，只会静默显示空白 ✗。
			# 游戏版本：value_text "0.1.0" 是**静态兜底**；运行时会被 about_info() 覆盖，
			#   那里取的是 ProjectSettings 的 application/config/version，若取到空串也兜底成 "0.1.0" ✓
			# → 两处都写 0.1.0 是刻意的（"没配置也得有个像样的版本号"），但真源在 project.godot；
			#   发版改版本号时**三处要一起改**（project.godot / 这里 / about_info 的兜底）✗（推测）。
			{"key": "about/version", "label": "游戏版本", "kind": Kind.INFO, "value_text": "0.1.0"},
			# 引擎版本：空串占位（运行时填 "Godot 4.x.y"）—— 由 Engine.get_version_info() 的
			#   major/minor/patch 拼出；玩家报 bug 时这一行很有用，所以别删 ✓。
			{"key": "about/engine", "label": "引擎版本", "kind": Kind.INFO, "value_text": ""},
			# 渲染设备：空串占位（运行时填 "渲染方式 ｜ 显卡名"，如 "Forward+ ｜ NVIDIA GeForce ..."）。
			#   显卡名在无头 / 远程桌面 / 驱动异常时可能是空串，所以与渲染方式拼在一行显示 ✓（推测用意）。
			{"key": "about/renderer", "label": "渲染设备", "kind": Kind.INFO, "value_text": ""},
			# 内存占用：空串占位（运行时填形如 "123 MB"）。
			# ⚠ 那是 OS.get_static_memory_usage() 的**引擎自报静态内存**（按 MiB 显示），
			#   不含全部系统占用、也不含 GPU 显存 → 当参考值看，别当成任务管理器里的数字 ✓。
			{"key": "about/memory", "label": "内存占用", "kind": Kind.INFO, "value_text": ""},
			# 存档目录：空串占位（运行时填 user:// 的**绝对路径**，ProjectSettings.globalize_path）。
			#   填绝对路径的用途：玩家 / 客服要备份或排查存档时能直接照着路径去翻 ✓。
			{"key": "about/save_dir", "label": "存档目录", "kind": Kind.INFO, "value_text": ""},
			# 崩溃日志目录：空串占位（运行时填 user://crash_monitor 的绝对路径）。
			# ⚠ 该目录由 addons/crash_monitor 插件写入，**本项只负责显示路径**：可能根本还没被创建
			#   → 拿到这一行后不要假定路径一定存在、更不要自动去打开它 ✗（推测，按 about_info 的注释）。
			{"key": "about/crash_dir", "label": "崩溃日志目录", "kind": Kind.INFO, "value_text": ""},
		],
	}


# ==================== 查询：拍平 / 查找 / 默认值 ====================
## 把 items() 的"分类 → 条目"表**拍平**成一个数组，并给每条补上 "category" 字段。
##
## 参数：无。
## 返回值：Array[Dictionary] —— 顺序 = ORDER 的分类顺序，分类内 = items() 里的书写顺序；
##   每个元素是该条目字典的一份副本，额外多一个 "category"(String) 键（值是分类中文名）✓。
## 副作用：无。
## 调用时机：本文件内部的 find() / defaults()；外部想"遍历所有设置项"时也用它（如测试）✓。
## 注意事项：
##   · 为什么还要 duplicate()：条目字典虽然是每次新建的，但复制一份更保险 ——
##     调用方往里塞 "category"、或继续改字段时，绝不会反过来污染 schema 的原始数据 ✓（推测用意：防御性写法）。
##     注意 duplicate() 默认是**浅拷贝**：嵌套的 choices / values 数组仍与字面量共享 ✓（本文件只读它们，够用）。
##   · ⚠ 循环体内每次都调一次 items() —— 也就是把整张表重建 ORDER.size()（7）次 ✗。
##     敢这么写是因为 items() 是纯构造、没有共享状态（见文件头坑 2）；
##     但那是**开销**不是特性：热路径上应自己先调一次 items()，再遍历 ✓。
static func all_items() -> Array:
	var out: Array = []
	for cat in ORDER:
		var table: Dictionary = items()
		for it in (table.get(cat, []) as Array):
			var d: Dictionary = (it as Dictionary).duplicate()
			d["category"] = cat
			out.append(d)
	return out


## 按键名查一个设置项（**线性扫描** all_items()，与 "key" 字段精确匹配、区分大小写）。
##
## 参数 key：完整设置键，形如 "audio/music"（必须与 schema 里的 key 逐字一致，只给后半段查不到 ✗）。
## 返回值：Dictionary —— 命中：条目副本（含 "category"）；**未命中：空字典 {}**（不是 null ✗）。
## 副作用：无。
## 调用时机：settings_store.gd（校验键是否合法 / 取默认值）、settings_apply.gd（取 todo 与 values），
##   以及本文件的 is_todo / choice_value / value_to_index。
## 注意事项：
##   · 判空必须写 `find(key).is_empty()` —— 写 `== null` 永远为 false（见文件头坑 3）✗；
##   · 复杂度 O(n) 且每次都要重建整表（见坑 2）→ **不要放在每帧的热路径里** ✗；
##   · 键重复不报错：会命中 ORDER / 书写顺序里更靠前的那个（见坑 8）✓。
static func find(key: String) -> Dictionary:
	for it in all_items():
		var d: Dictionary = it
		if String(d.get("key", "")) == key:
			return d
	return {}


## 查询某个设置项是否仍是"功能还没做、先占位"（界面据此置灰并标"（待开发）"✓）。
##
## 参数 key：完整设置键。
## 返回值：bool —— 只有条目里 todo 为 true 才返回 true；**键不存在时返回 false**（即"未知键不算占位"）✓。
##   ⚠ 别把它与 settings_apply.apply_one() 的 "unknown" 混为一谈：一个是"未知键"，一个是"未知键不算占位" ✗。
## 副作用：无（内部走一遍 find() → 又是一次全表扫描；别在循环里对每个键反复调它 ✗）。
## 调用时机：界面决定控件是否可操作；tests/test_settings.gd 用它守着"某些项不该再是占位"（回归护栏 ✓）。
static func is_todo(key: String) -> bool:
	return bool(find(key).get("todo", false))


## 收集全部设置项的**默认值**，组成一份可直接塞给 SettingsStore 的字典。
##
## 参数：无。
## 返回值：Dictionary —— key(String) → 默认值(Variant)；返回的是新字典，可以随便改 ✓。
##   ⚠ INFO 类条目没有 "default" → 它们的值是 **null**（键仍在，见文件头坑 4）。
##   ⚠ CHOICE 类要看清语义：带 "values" 的（如帧率上限）这里应当是**真实值**，
##     不带 "values" 的才是**下拉索引** —— 两者混用是本表最容易踩的地方 ✗（现成反例见 graphics/fps_limit）。
## 副作用：无。
## 调用时机：SettingsStore.reset_all()（内存初值）与 modified_keys()、
##   SettingsApply.apply_all()（"要应用哪些键"的清单）、settings_menu 的"恢复默认"、以及测试 ✓。
## 注意事项：
##   · 它同时也是"键全集"的来源 → 新增设置项会自动出现在这里，但 settings_apply 的分支**不会**自动有 ✗（见坑 1）；
##   · 别把它当"存档内容"：cfg 里存的是**当前值**，默认值只用于初始化与比对 ✓；
##   · 这里没有做任何类型校验 / 越界裁剪 —— 值是否合法由用它的那个系统自己负责（推测）✗。
static func defaults() -> Dictionary:
	var out := {}
	for it in all_items():
		var d: Dictionary = it
		out[String(d["key"])] = d.get("default", null)
	return out


# ==================== 小工具：控件类型名 + 下拉换算 ====================
## 把 Kind 枚举翻译成中文名（"开关" / "滑条" / "下拉" / "信息"）。
##
## 参数 k：Kind 的整数值（0=TOGGLE 1=SLIDER 2=CHOICE 3=INFO）。
## 返回值：String —— 已知类型的中文名；**未知值返回 "?"**（不报错，方便在日志里一眼看出脏数据 ✓）。
## 副作用：无（纯 match 查表，全文件最便宜的函数 ✓）。
## 调用时机：日志 / 调试文案；界面上**不用**它（settings_menu.gd 直接 match Kind 造控件）✓。
## 注意事项：新增 Kind 成员时记得在这里补一行，否则日志里只会显示 "?" ✗（不影响功能，只影响排查效率）。
static func kind_name(k: int) -> String:
	match k:
		Kind.TOGGLE: return "开关"
		Kind.SLIDER: return "滑条"
		Kind.CHOICE: return "下拉"
		Kind.INFO: return "信息"
	return "?"


## 下拉框**选中项索引** → 真正要存进 store / 交给引擎的值。
##
## 参数 key：完整设置键（用它的条目定义来决定怎么换算）。
## 参数 index：下拉框里的选中下标（OptionButton.selected），理论上 0 ~ choices.size()-1。
## 返回值：Variant ——
##   · 条目带非空 "values" 且 index 落在 [0, values.size()) 内 → 返回 values[index]（真实值，如 60）；
##   · 其它情况 → **原样返回 index**（所以没有 values 的 CHOICE，存进 store 的就是索引本身 ✓）。
## 副作用：无。
## 调用时机：settings_menu.gd 的下拉 item_selected 回调里 —— 把"用户选了第几项"换成"要存的值"再写 store ✓。
## 注意事项：
##   · ★ **为什么需要 values 表**：下拉里显示的是给人看的文字（"不限制" / "60"），
##     而落盘与引擎要的是数字（Engine.max_fps 需要 0 / 60 / …）→ 把"显示"和"存储"分开，
##     才能做到"界面写不限制、引擎读到 0" ✓。没有这种需求的条目（如窗口模式）就不必带 values ✓。
##   · 越界的 index（含负数）也会被原样返回：不报错、也不裁剪 → 契约是"调用方只传合法索引" ✓；
##   · key 拼错时 find() 返回 {} → values 视作空 → 同样退化成返回 index（静默降级、不崩 ✓）。
## 下拉项 → 索引对应的真实值（没有 values 就用索引本身）
static func choice_value(key: String, index: int) -> Variant:
	var d := find(key)
	var values: Array = d.get("values", [])
	if index >= 0 and index < values.size():
		return values[index]
	return index


## **真实值** → 下拉框选中索引（choice_value 的反函数），用于把 store 里的当前值回填到界面。
##
## 参数 key：完整设置键。
## 参数 value：store 里存着的当前值（对带 values 的条目而言就是 values 里的某个元素）。
## 返回值：int ——
##   · 条目**没有** values（数组为空）→ 直接 `int(value)`（此时 store 里存的本就是索引 ✓）；
##   · 有 values → 线性查找相等元素并返回其下标；
##   · **找不到时返回 0**（回落第一个选项）✗ —— 不返回 -1、也不报错。
## 副作用：无。
## 调用时机：settings_menu.gd 打开 / 重建某页时设置 OptionButton.selected ✓；
##   settings_apply.gd 的 apply_display() 也用它把帧率上限的真实值反查成下标、再取 values ✓。
## 注意事项：
##   · ⚠ "找不到返回 0"会把**非法 / 过期 / 与 values 对不上的值静默显示成第一个选项** →
##     现象是"界面显示的选项和我以为的不一样"且毫无报错；排查时优先对比 cfg 里的值与 values 表 ✗；
##   · graphics/fps_limit 的 default=2 正踩在这个点上（2 不在 values 里 → 实际回落到"不限制"，
##     详见该条目处的说明）→ 给带 values 的条目写 default 时**必须写真实值** ✗；
##   · 比较用的是 `==`：数值字面量 60 与 60.0 在 GDScript 里相等 ✓（推测够用），
##     但字符串 "60" 与数字 60 **不相等** → 别把 values 写成字符串 ✗。
## 真实值 → 下拉索引
static func value_to_index(key: String, value: Variant) -> int:
	var d := find(key)
	var values: Array = d.get("values", [])
	if values.is_empty():
		return int(value)
	for i in range(values.size()):
		if values[i] == value:
			return i
	return 0
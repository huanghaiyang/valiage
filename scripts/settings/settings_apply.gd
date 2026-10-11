# ============================================================================
# settings_apply.gd —— 设置"落地执行器"（把设置值真正写进 Godot 引擎）
# ============================================================================
# 【所属系统】设置系统（scripts/settings/）的**执行层**，同目录三者分工明确：
#   · settings_schema.gd  纯数据：设置项的 key / 控件类型 / 默认值 / 取值范围（唯一真相源）
#   · settings_store.gd   状态：当前值的内存持有 + user://settings.cfg 持久化
#   · settings_apply.gd（本文件）**执行**：把某个 key 的当前值翻译成对引擎的实际调用
#   界面（settings_menu.gd）与总控（game_settings.gd）只负责"改 store + 调本文件"，
#   本文件**不持有状态、不读也不写设置文件**，值全部从传入的 store 现取（纯函数风格 ✓ 便于单测）。
#
# 【本文件职责】
#   1) apply_one(store, key)  — 应用单个设置项，返回一个状态字符串给界面显示；
#   2) apply_all(store)       — 遍历 schema 的全部键（启动加载、"恢复默认"时用）；
#   3) about_info()           — 采集"关于"页的只读信息（版本 / 引擎 / 显卡 / 内存 / 目录）。
#   此外提供了画质档位"一个数字驱动两套系统"的合并点（apply_tier）—— 这是本文件存在的核心理由。
#
# 【关键依赖】
#   · SettingsSchema（scripts/settings/settings_schema.gd）：默认键列表、单项定义、值↔下拉索引换算。
#   · store 形参（由 game_settings.gd / settings_menu.gd 传入）：⚠ **形参没有类型标注**，
#     只要求提供 get_value(key) -> Variant；测试里传的是同签名的假对象 ✓（不是笔误）。
#   · autoload（project.godot → [autoload] 段）：
#       Settings     = res://scripts/settings.gd                     → quality / show_grass / volumetric_fog ...
#       Quality      = res://scripts/quality/quality_manager.gd       → set_tier() 驱动地表贴图与地形 LOD
#       GameSettings = res://scripts/settings/game_settings.gd        → show_subtitle() 读字幕开关
#   · 引擎级单例：AudioServer（总线创建/音量）、RenderingServer（阴影全局参数）、DisplayServer（窗口/同步）、
#     Engine（max_fps / 版本信息 / is_editor_hint）、OS（静态内存）、ProjectSettings（版本号 / 渲染方式 / 路径）。
#
# 【主要对外接口】（全部 static，本类不需要 new 出来；调用形如 SettingsApply.apply_one(...)）
#   · apply_all(store) -> Dictionary   {设置项 key(String) : 状态字符串(String)}
#   · apply_one(store, key) -> String  状态字符串，取值：
#       "ok"          —— 已成功应用到引擎
#       "failed"      —— 值已存盘但应用失败
#       "todo"        —— schema 标了占位（功能未实现），或该 key 忘了登记应用逻辑
#       "unknown"     —— key 不在 SettingsSchema 里
#       "editor-skip" —— 编辑器内拒绝执行显示相关操作（见下"坑"1）
#       "queued"      —— 画质系统尚未就绪，等运行时再补
#   · about_info() -> Dictionary        键名与 schema 的 about/* 键一一对应
#
# 【已知的坑与注意事项】
#   ⚠ 1. **编辑器里绝不碰显示相关**（本文件第 11 行那句的落实）：@tool 使本脚本在编辑器内也可能被执行，
#         而编辑器里的 root 视口就是编辑器自己的窗口 → 改窗口模式/垂直同步/帧率/缩放会把编辑器窗口
#         搞乱 ✗。因此这些分支统一先判 Engine.is_editor_hint() 并返回 "editor-skip"，
#         界面据此提示"已保存（编辑器内不改变窗口 ✓）"。测试 tests/test_settings.gd 专门守着这条不变量 ✓。
#   ⚠ 2. **同一个数字驱动两套画质系统**（apply_tier）：两边都要写，缺一边就会出现"设置界面改了但画面
#         只变一半"✗。编辑器里 autoload 不加载 → 返回 "queued" 属正常现象，**不是失败** ✗。
#   ⚠ 3. **状态字符串只描述"引擎侧应用结果"，不代表值有没有落盘**：落盘由 SettingsStore.set_value 负责，
#         本文件返回 "failed" 时值其实已经写进 cfg 了 ✓（界面文案也确实是这么写的）。
#   ⚠ 4. 音频总线是**运行时按需创建**的（ensure_buses）：项目不保证预先存在这些 bus。
#   ⚠ 5. apply_one 末尾的 match **没有 default 报错分支**：未知键靠开头查 schema 拦截，漏登记的键会
#         软着陆成 "todo" → 新增设置项时必须同时改 schema 与本文件的 match ✗。
# ============================================================================
@tool
class_name SettingsApply
extends RefCounted
## 把设置真的应用到引擎。
##
## ★ 画质档位是**一个数字驱动两套系统** ✓（这是与项目原有 Settings 单例的合并方式）：
##     · 项目原有 scripts/settings.gd（autoload 名 Settings）→ MSAA / 模型 LOD / 草丛 / 植被距离 / 体积雾
##     · 本项目新增的 Quality 系统                        → 地表贴图分辨率 / 地形 LOD
##   这样两侧永远不会各说各话 ✓，也不会删掉任何一方已有的调参逻辑 ✓
##
## ⚠️ 编辑器里**绝不碰显示相关**（窗口/垂直同步/帧率/缩放）✗ —— 那会改掉编辑器自己的窗口 ✗

# ==================== 常量与查找表 ====================
## 设置项 key → 音频总线名 的映射表（**音量类设置靠它被识别出来**）。
## 用途：apply_one 里用 BUS_OF.has(key) 直接把 key 分流到 apply_bus，省掉一长串 match 分支 ✓。
## 键：必须是 settings_schema.gd 里登记过的音频 key（audio/master、audio/music、audio/sfx、
##     audio/ui、audio/voice）；拼错不会报错，只会静默变成"未处理项"（最终返回 todo）✗。
## 值：AudioServer 里的总线名 —— **名称即身份**：总线不存在时 ensure_buses() 按这个名字新建 ✓。
## ⚠ "Master" 是引擎内置总线（永远存在）；其余名字一旦写错，会凭空多出一条新总线，
##    音量就作用不到真实的声音上 ✗（排查音量无效时，先看音频总线列表里到底有哪几条）。
## 单位/默认值：无（字符串常量表）；**不要为了加新音量项而在这里凭空添键** ✗ ——
## 必须先在 schema 里登记同名的 audio/* 项，否则它永远不会出现在设置界面里。
const BUS_OF := {
	"audio/master": "Master",
	"audio/music": "Music",
	"audio/sfx": "SFX",
	"audio/ui": "UI",
	"audio/voice": "Voice",
}

## 阴影质量档 → RenderSettings 用的整数值（避免直接引用可能不存在的枚举常量 ✗）
## 0=硬阴影 1=软·低 2=软·中 3=软·高 4=软·极高
## ★ 补充：为什么存**整数值**而不是枚举常量 ——
##   部分 Godot 版本**没有** SHADOW_QUALITY_* 这类常量，直接写常量名会让整个脚本**解析失败** ✗
##   （那是编译期错误，会把本文件所有设置项一起搞挂）；退化成整数 + has_method 守卫后，
##   接口不存在最多只是少改一项，脚本照常能跑 ✓。
## 数组下标 = 设置界面档位序号（0~3，对应 schema 里的"低/中/高/极高"）；
## 数组里**存的值**才是传给引擎的枚举语义（见上一行）；
## ⚠ 注意下标 0（低档）实际用值 1（软·低）—— **硬阴影 0 有意不使用**（边缘太糙，观感差）。
## 调整效果：某档的值调大 = 更柔和但更糊；调小 = 更锐利但锯齿更明显。
## ⚠ 本表长度必须与 SHADOW_ATLAS_SIZES **一致**，两者共用同一个下标 ✗。
const SHADOW_QUALITY_VALUES := [1, 2, 3, 4]
## 阴影质量档 → 方向光阴影图集边长（单位：像素，正方形边长）。
## 下标含义同上（0~3 = 低/中/高/极高），与 SHADOW_QUALITY_VALUES 一一对应、**必须等长** ✗。
## 档位越高图集越大 → 相同世界范围下每像素覆盖面积更小 → 阴影边缘越清晰；
## 代价是显存占用按边长平方增长（8192² 已是数百 MB 量级，所以只给"极高"档用 ✗）。
## 默认 2048（中档）是"清晰度够用 + 显存温和"的折中；改小到 1024 能省显存但阴影会明显发糊。
const SHADOW_ATLAS_SIZES := [1024, 2048, 4096, 8192]


# ==================== 对外入口：整批 / 单项应用 ====================
## 应用**全部**设置项（启动加载与"恢复默认"都走这里）。
##
## 参数 store：设置值持有者（SettingsStore 实例，或只提供 get_value(key) 的假对象）；
##   本函数**不写 store、不落盘设置** ✓，值的合法性由 store 侧保证（滑条 clamp、下拉存索引）。
## 返回值：Dictionary，{设置项 key(String) : 状态字符串(String)}；状态含义见 apply_one。
##   ⚠ 返回值里**包含 schema 的全部键**（含 todo 占位与 about/* 信息项），
##   所以不要拿它的 size 当"生效了几项"✗；调用方（game_settings.gd）只统计值为 "todo" 的个数。
##
## 副作用（很重，逐项列出）：
##   · 可能新建音频总线、改各总线音量与静音标志；
##   · 可能切换画质档位（**写 user://quality.cfg + 广播 tier_changed**，订阅者会改贴图 / LOD / 阴影 / 视距）；
##   · 在非编辑器环境下可能改窗口模式、垂直同步、帧率上限、UI 缩放；
##   · 可能改抗锯齿与阴影的渲染全局状态。
##
## 调用时机：game_settings.gd 的 _ready（启动加载后应用一次）、settings_menu.gd 的"恢复默认"。
##   一般在主线程、场景就绪后调一次即可；**不要每帧调**✗（会反复写 quality.cfg）。
##
## 注意事项：
##   · 遍历顺序 = schema 的键顺序，各项之间**没有强制依赖顺序**；目前"画质档位"不写抗锯齿/阴影
##     （见 apply_tier 的注意事项），所以同一次遍历里不会出现互相覆盖 ✓；
##   · GDScript 没有异常机制，单项失败只体现为返回值里的 "failed"，**不会中断其它项** ✓；
##   · 编辑器里调用是安全的：显示相关项返回 "editor-skip"，不会真去改编辑器窗口 ✓。
static func apply_all(store) -> Dictionary:
	var result := {}
	# 先确保音频总线存在：apply_bus 虽然也会兜底创建，但先建好能让总线数量一次性稳定，
	# 避免"边遍历边新建总线"导致后续项的索引解释发生漂移 ✓
	ensure_buses()
	for key in SettingsSchema.defaults().keys():
		result[key] = apply_one(store, String(key))
	return result


## 应用**单个**设置项 —— 本文件最主要的入口（界面每改一项就调一次）。
##
## 参数 store：同 apply_all，只读它的 get_value(key)。
## 参数 key：设置项标识，形如 "分类/名称"（如 "graphics/tier"、"audio/music"）。
##   取值范围：SettingsSchema 里登记过的键；表里没有的键不会报错，返回 "unknown" ✓。
## 返回值：状态字符串（界面直接拿去显示，见 settings_menu._commit 的 match）：
##   "ok"          已成功应用到引擎 ✓
##   "failed"      值已存盘，但应用失败（总线建不出来 / 拿不到 SceneTree 等）✗
##   "todo"        schema 标了 todo=true 的占位项（功能未实现，仅存盘）；
##                 ⚠ 也用于"走到函数末尾仍未命中任何分支"的漏登记键 —— 这是有意的软着陆 ✓
##   "unknown"     key 不在 SettingsSchema 里（多半是拼写错误）
##   "editor-skip" 编辑器内拒绝执行显示相关操作（见文件头"坑"1）✓
##   "queued"      画质系统（Settings / Quality）当前取不到，等运行时再补 ✓
##
## 副作用：取决于 key —— 可能改音频总线音量、切画质档位（连带写盘 + 广播）、改窗口模式 /
##   垂直同步 / 帧率 / UI 缩放 / 抗锯齿 / 阴影。**本函数自身不写 store、不落盘设置** ✓。
##
## 调用时机：设置界面每次改动（恢复默认时对全部键逐个重放）、启动时被 apply_all 逐个调用。
##
## 注意事项：
##   · 正确姿势是**先** store.set_value(key, 新值)、**后**调本函数 —— 顺序反了会应用到旧值 ✗
##     （settings_menu._commit 就是先 set_value 再调 ✓）；
##   · "editor-skip" 的分支**值仍然已经落盘**，只是不动引擎 —— 这是有意的：
##     编辑器里调参不该影响窗口，但用户的选择要记住 ✓；
##   · 音量类键在 match **之前**被分流（BUS_OF.has），所以它们永远不会走进下面的 match ✓。
static func apply_one(store, key: String) -> String:
	# 先查 schema：不认识的键立刻判 unknown，避免拼错的键默默落到末尾被当成 "todo" 而看不出问题 ✗
	var d := SettingsSchema.find(key)
	# 表里查不到 → 立刻判 unknown（界面照原样返回，便于发现拼写错误）✓
	if d.is_empty():
		return "unknown"
	# 占位项（schema 里 todo=true）：功能未实现，界面显示"已保存（功能待开发）"，不尝试应用 ✓
	if bool(d.get("todo", false)):
		return "todo"
	# 音量类走专用通道（连带负责"总线不存在就先创建"的兜底），**不进入下面的 match** ✓
	if BUS_OF.has(key):
		return "ok" if apply_bus(store, key) else "failed"
	# 其余键按 key 精确分发。⚠ 下面凡是要改**显示/渲染全局状态**的项，都先判 Engine.is_editor_hint()：
	# @tool 让本脚本在编辑器里也可能被执行，而编辑器里的 root 视口就是编辑器自己的窗口 ——
	# 真去改窗口模式 / VSync / 帧率 / 缩放 / AA 会把编辑器界面搞乱 ✗ → 统一返回 "editor-skip" 只提示不执行 ✓
	match key:
		"graphics/tier":
			# 档位在这里不做编辑器跳过：apply_tier 内部会因 autoload 不可用而自然退化成 "queued" ✓
			return apply_tier(int(store.get_value(key)))
		"graphics/aa":
			# 抗锯齿写的是"当前运行环境"根视口的全局状态，编辑器里会污染编辑器视口 ✗
			if Engine.is_editor_hint():
				return "editor-skip"
			return apply_aa(int(store.get_value(key)))
		"graphics/shadow":
			# 阴影参数挂在 RenderingServer 全局单例上（编辑器与游戏共用同一个实例）→ 同样跳过 ✗
			if Engine.is_editor_hint():
				return "editor-skip"
			return apply_shadow(int(store.get_value(key)))
		"graphics/window_mode", "graphics/vsync", "graphics/fps_limit":
			# ⚠ 三项**共用一个分支**：改任意一项都会整组重写（它们互相牵制，原因见 apply_display 文档）✓
			if Engine.is_editor_hint():
				return "editor-skip"
			apply_display(store)
			return "ok"
		"access/ui_scale":
			# 界面缩放改的是根视口 content_scale_factor —— 编辑器里那是编辑器 UI 自身的缩放 ✗
			if Engine.is_editor_hint():
				return "editor-skip"
			apply_ui_scale(float(store.get_value(key)))
			return "ok"
		"language/subtitle":
			return "ok"          # 字幕由 GameSettings.show_subtitle() 的开关读取 ✓
	# 兜底：能走到这里说明该 key 已在 schema 登记、但本文件忘了给它写应用逻辑 →
	# 当成"待开发"软着陆（界面照常提示"功能待开发"），不抛错、也不影响其它设置项 ✓
	return "todo"


# ==================== 画质档位：一个数字驱动两套系统（合并点） ====================
## ★ 一个档位 → 两套系统（合并点 ✓）
## 把"画质档位"这一个数字**同时**写进项目里并存的两套画质系统 —— 本文件存在的核心理由 ✓。
##
## 参数 tier：目标档位序号，0=低 1=中 2=高 3=极高。
##   取值范围：schema 里 graphics/tier 默认值是 2（高），界面只有 4 个选项（0~3）；
##   传入越界值会被 clampi 静默夹紧（-1→0、9→3），**不报错** ✗ ——
##   不报错是有意的：存档被手改坏时也要能跑起来 ✓。
## 返回值：
##   "ok"     —— 两套系统中至少有一套真的收到了档位 ✓
##   "queued" —— 两套都取不到（**编辑器里 autoload 不加载**时的正常结果，或启动极早期）；
##               值已经存盘，等运行时 GameSettings 再 apply_all 一次即可补上 ✓ —— **不是失败** ✗
##
## 副作用：本文件里副作用最重的函数：
##   · 写 Settings autoload 的 quality 属性 → 其 setter 立刻 apply_quality()：
##     MSAA / 模型 LOD 阈值 / 草丛开关 / 植被绘制距离 / 体积雾（详见 scripts/settings.gd）；
##   · 调 QualityManager.set_tier() → **写 user://quality.cfg + 广播 tier_changed**，
##     订阅者（terrain_quality / grass_quality / shadow_quality / prop_texture_quality）
##     再去改地表贴图分辨率、地形 LOD、阴影距离、道具贴图 ✓。
##
## 调用时机：apply_one 命中 "graphics/tier" 时（设置界面改档位 / 启动加载）。
##
## 注意事项：
##   · 两套系统的档位编号**约定同义**（0~3），但各自的合法范围由各自定义：
##     Settings 用 enum Quality、Quality 用 QualityTiers.Tier → 本函数只统一夹紧一次 0~3 ✓；
##   · 用 touched 计数而不是布尔：只要有一侧生效就返回 "ok"，
##     避免"编辑器里拿不到 Quality 单例"被误报成失败 ✗；
##   · ⚠ 本函数**不会**去改 graphics/aa 与 graphics/shadow 两项 —— schema 里抗锯齿那句
##     "「画质档位」也会联动这一项"目前**并未在此实现**（推测是留给未来），
##     所以改档位后抗锯齿保持用户自己选的值 ✓，别误以为这里会一起改；
##   · 幂等性一般：QualityManager.set_tier 对相同档位会短路（不落盘、不广播），
##     而 Settings.quality 的 setter 每次赋值都会重跑一遍 apply_quality() →
##     同档位重复调用会有重复劳动（开销很小，可接受 ✓）。
static func apply_tier(tier: int) -> String:
	# 夹紧到 0~3：与 schema 的四个选项、Settings.Quality 枚举、QualityTiers.Tier 一一对应；
	# ⚠ 三处编号必须保持同义，而这里 0 和 3 是**硬编码**的 → 将来增删档位需人工同步 ✗
	var t := clampi(tier, 0, 3)
	var project_settings := _autoload("Settings")
	var touched := 0
	# 用 `"quality" in obj` 探测属性而不是先强转类型：Settings.gd 是 autoload，编辑器里不加载 →
	# project_settings 可能是 null 必须能安全跳过；用 in 也顺带防住"名字叫 Settings 却没有 quality 属性"的节点 ✓
	if project_settings != null and "quality" in project_settings:
		project_settings.set("quality", t)          # 你的渲染质量档（MSAA/LOD/草丛/雾）✓
		touched += 1
	# 运行时是 autoload（QualityManager.instance ✓）；编辑器里 autoload 不加载 ✗ → 用节点名兜底 ✓
	# ⚠ q 故意**不写类型标注**：instance 是 QualityManager，而 _autoload() 返回 Node，
	#   两者无法统一标注，且这里走的是 GDScript 鸭子类型动态调用 set_tier() ✓（不是笔误）
	var q = QualityManager.instance
	if q == null:
		q = _autoload("Quality")
	if q != null:
		q.set_tier(t)                               # 地表贴图 / 地形 LOD ✓
		touched += 1
	# 两侧都没摸到 = 画质系统尚未就绪（编辑器 / 启动极早期）→ 报 "queued"，
	# 让界面提示"稍后生效"而不是"应用失败" ✗（当前确实还没有任何东西可改 ✓）
	if touched == 0:
		return "queued"
	return "ok"


## 读出项目原有 Settings 的档位（菜单打开时同步用 ✓）
## 读取**项目原有 Settings**（不是新增的 Quality 系统）里的当前档位 —— 打开设置菜单时用它同步下拉框 ✓。
##
## 参数：无。
## 返回值：int —— 正常是 0~3；**-1 是"读不到"的哨兵值**（编辑器里 autoload 未加载，
##   或那个节点没有 quality 属性）。⚠ -1 **不是合法档位**，调用方必须自己判断并回落到
##   schema 的默认档（graphics/tier 默认 2）✗，不要直接塞进控件索引。
## 副作用：无（纯查询：不落盘、不发信号、不改任何状态）。
## 调用时机：settings_menu 打开 / 刷新时读一次。
## 注意事项：本函数只读"老系统" Settings；**新系统 Quality 的档位不在这里读** ——
##   要新系统的档位请直接看 QualityManager.instance.tier ✓（两边由 apply_tier 保证同步）。
static func read_project_tier() -> int:
	var project_settings := _autoload("Settings")
	if project_settings != null and "quality" in project_settings:
		return int(project_settings.get("quality"))
	# 读不到就返回哨兵 -1，由调用方决定兜底值 —— 这里**不**擅自返回 2，
	# 免得"读失败"和"真的读到中档"两种情形混在一起分不出来 ✗
	return -1


# ==================== 内部工具：autoload / 根节点取用兜底 ====================
## 按节点名从**场景树根节点**取 autoload；取不到返回 null，**不报错** ✓。
##
## 参数 node_name：autoload 注册名（project.godot → [autoload] 段的键）；
##   本文件用到的只有 "Settings" 与 "Quality" 两个。
## 返回值：Node 或 null —— 节点不存在时就是 null，所以**调用方必须判空** ✗。
##
## 副作用：无。
## 调用时机：apply_tier / read_project_tier 内部（也可能被测试间接调用）。
##
## 注意事项：
##   · 这里刻意用 **get_node_or_null** 而不是 get_node：编辑器里 autoload 不加载，
##     用 get_node 会直接抛错并中断整个 apply_all ✗，而 get_node_or_null 只返回 null ✓；
##   · 同理刻意用 Engine.get_main_loop() 而不是 get_tree()：本类是 RefCounted（不是 Node），
##     **根本没有 get_tree()**，只能借主循环拿 /root ✓（这也是本类所有函数都是 static 的原因之一）；
##   · 场景树尚未建立时（自定义 MainLoop / 极早期）主循环还不是 SceneTree → 返回 null ✓，
##     不要假定"调用一次就一定能拿到节点"。
static func _autoload(node_name: String) -> Node:
	var loop := Engine.get_main_loop()
	# 非 SceneTree（自定义 MainLoop 等）时 /root 根本不存在 → 直接返回 null，
	# 让上层按"取不到"处理，比抛错更适合"设置应用"这种非关键路径 ✓
	if loop is SceneTree:
		return (loop as SceneTree).root.get_node_or_null(NodePath(node_name))
	return null


# ==================== 图形：抗锯齿 ====================
## 抗锯齿：0=关 1=FXAA 2=MSAA2x 3=MSAA4x（项目原本就是 MSAA4x，所以默认取 3 ✓）
## 应用抗锯齿设置 —— 改的是**根视口**的 AA 属性（全局 3D 渲染状态 ✓）。
##
## 参数 index：schema 里 graphics/aa 的下拉索引，取值与含义：
##   0 = 关（无 AA）｜ 1 = FXAA（屏幕空间后处理，便宜但画面会糊）｜ 2 = MSAA 2x ｜ 3 = MSAA 4x。
##   越界值（>3 或 <0）落到 match 的 `_` 分支 = 关 MSAA，**不报错** ✓。
##   默认值 3（MSAA 4x）的理由：项目原本就用 MSAA4x，这样"用户没动过设置"= "画面保持原样" ✓。
## 返回值："ok" 成功；"failed" —— 拿不到 SceneTree（编辑器 / 无头运行 / 自定义 MainLoop）✗。
##
## 副作用：写根视口的 screen_space_aa 与 msaa_3d → **影响此后所有 3D 渲染**（3D 相机看到的一切），
##   请在主线程调用 ✓。2D 抗锯齿没有触碰（当前 UI 不需要）。
##
## 调用时机：apply_one 命中 "graphics/aa" 时；**编辑器内不会走到**（apply_one 已提前拦截）✓。
##
## 注意事项：
##   · ⚠ 变量名 vp 容易被误读成"某个 3D 相机"，其实它就是**主窗口**：
##     代码里的 root 是 Window，而 Window 继承自 Viewport —— MSAA / screen_space_aa
##     正是 Viewport 上的属性，所以能直接写 ✓；
##   · FXAA 与 MSAA **互斥**（见下面那行三元表达式）：只有 index==1 才开 FXAA，其余档位一律关 FXAA。
##     两者叠加会又糊又有锯齿，反而更难看 ✗；
##   · 这里的 `is` 判断与 apply_ui_scale 里的 `as` 强转是**两种等价风格**（都判了空），不是笔误 ✓。
static func apply_aa(index: int) -> String:
	var loop := Engine.get_main_loop()
	if not (loop is SceneTree):
		return "failed"
	# root 是主窗口（Window : Viewport）→ MSAA / screen_space_aa 这些属性定义在 Viewport 上 ✓
	var vp := (loop as SceneTree).root
	# 理论上 root 不会为 null，但这是"引擎边界"，防御一下比崩掉整个 apply_all 好 ✓
	if vp == null:
		return "failed"
	# 一条语句表达互斥关系：仅 index==1 开 FXAA，其它档位一律关掉 FXAA（防止 FXAA 与 MSAA 叠加）✓
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if index == 1 else Viewport.SCREEN_SPACE_AA_DISABLED
	# MSAA 档位映射：2→2x，3→4x，其余（0 关 / 1 只有 FXAA / 越界）一律关 MSAA ✓
	match index:
		2:
			vp.msaa_3d = Viewport.MSAA_2X
		3:
			vp.msaa_3d = Viewport.MSAA_4X
		_:
			vp.msaa_3d = Viewport.MSAA_DISABLED
	return "ok"


# ==================== 图形：阴影质量（RenderingServer 全局） ====================
## 阴影质量：走 RenderingServer 的全局方向光阴影设置 ✓
## 用整数值而不是枚举常量：某些版本没有 SHADOW_QUALITY_* 常量，
## 直接写常量名会导致**解析失败** ✗ → 改用整数 + has_method 守卫 ✓
## 应用阴影质量档位 —— 改 RenderingServer 的**全局方向光阴影**参数（不是某个光源自身的属性）。
##
## 参数 index：schema 里 graphics/shadow 的下拉索引，0=低 1=中 2=高 3=极高（默认 2）。
##   越界值被 clampi 夹到 0~3，再作为 SHADOW_QUALITY_VALUES / SHADOW_ATLAS_SIZES 的**下标**使用 ✓。
## 返回值："ok" —— 至少一个引擎接口调用成功（ok 是"或"关系）；
##   "failed" —— 两个接口在当前引擎版本都不存在 ✗（理论上不会发生，属防御性返回）。
##
## 副作用：改全局阴影柔化质量与阴影图集大小 → **立刻影响场景中所有方向光阴影的观感与显存占用**；
##   图集参数第二参传 true 表示"立即刷新"，所以不必等下一帧、也不用手动触发重绘 ✓。
##
## 调用时机：apply_one 命中 "graphics/shadow" 时；编辑器内不会走到（apply_one 已拦截）✓。
##
## 注意事项：
##   · ★ 下面两段为什么写成"has_method 问一句 + call 字符串调用"这么绕？
##     因为部分 Godot 版本**没有** directional_soft_shadow_filter_set_quality / 相关枚举常量，
##     直接写接口名以外的常量名会导致**整个脚本解析失败** ✗（编译期错误，会把本文件所有设置项一起搞挂）；
##     先 ask 再 call 后，接口不存在最多只是"这一项没改到"，脚本照常能跑 ✓；
##   · 两个接口**各自独立**判断：只支持其中一个的引擎也能改到那一半 ✓；
##   · 阴影**距离**（近/远）不在这里改 —— 那是档位系统里 shadow_quality.gd 按档位设距离负责的 ✓，
##     本函数只管"清晰度/柔化"，两者配合使用；
##   · 与 graphics/aa 一样这是**全局**状态，编辑器内调用会污染编辑器渲染 ✗。
static func apply_shadow(index: int) -> String:
	# 夹紧成表下标：两张常量表长度都是 4，夹到 0~3 就保证不会越界 ✓
	var i := clampi(index, 0, 3)
	var ok := false
	# has_method 守卫：接口不存在时**不能直接 call**（会报错中断），先问再调以兼容多版本 ✓
	if RenderingServer.has_method("directional_soft_shadow_filter_set_quality"):
		RenderingServer.call("directional_soft_shadow_filter_set_quality", int(SHADOW_QUALITY_VALUES[i]))
		ok = true
	# 图集大小：第二参 true = 立即生效（不等帧末），保证设置界面点完马上能看到变化 ✓
	if RenderingServer.has_method("directional_shadow_atlas_set_size"):
		RenderingServer.call("directional_shadow_atlas_set_size", int(SHADOW_ATLAS_SIZES[i]), true)
		ok = true
	# 两个接口都不可用才判失败；只有一个可用也算 ok（该版本"能改多少改多少"）✓
	return "ok" if ok else "failed"


# ==================== 音频：总线创建与音量 ====================
## 确保 BUS_OF 里列出的音频总线**全部存在**，缺的按引擎默认新建（幂等，可反复调用 ✓）。
##
## 参数：无。
## 返回值：Array[String] —— **本次新建**的总线名列表（原本就存在的总线不在其中）；
##   调用方一般忽略返回值，测试 / 排查时可以拿它确认"到底建了几条"✓。
##
## 副作用（改全局音频状态）：
##   · AudioServer.add_bus() 追加新总线（**总线数量与顺序会变**）；
##   · 给新总线命名，并把非 Master 的新总线 send 到 Master（保证总输出链路通 ✓）。
##
## 调用时机：apply_all 开头（遍历前先建好总线）、apply_bus 找不到总线时的兜底。
##
## 注意事项：
##   · 为什么运行时才建？项目不保证预先存在这些 bus（工程默认总线布局未必包含它们），
##     而用户可能直接把音量拉起来 —— 那时总线必须先存在才能设值 ✓；
##   · 新总线的初始音量由引擎默认决定（通常 0dB = 原始音量），随后由 apply_bus 按用户设置覆盖 →
##     **"先建后设"的顺序不能反** ✗；
##   · ⚠ 新建的总线**不会**写回项目文件 / 总线布局资源：这是纯运行时行为，
##     所以每轮 apply_all 都会重新确保一次 ✓（别指望重启后自动还在）；
##   · Master 是引擎内置总线，get_bus_index 一定命中，不会走进创建分支 ✓。
static func ensure_buses() -> Array:
	var created: Array = []
	for key in BUS_OF.keys():
		var bus := String(BUS_OF[key])
		# 已存在就跳过：保证幂等，反复调用不会堆出一串同名总线 ✓
		if AudioServer.get_bus_index(bus) != -1:
			continue
		# add_bus() 只能追加到末尾、没有"顺便指定名字"的参数 → 先加再改名，索引就是最后一条 ✓
		AudioServer.add_bus()
		var idx := AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, bus)
		# Master 就是最终输出，让它 send 到自己是无意义/非法的 → 只给子总线设发送目标 ✓
		if bus != "Master":
			AudioServer.set_bus_send(idx, "Master")
		created.append(bus)
	return created


## 应用**单项音量**到对应的音频总线（把 0~1 的线性音量换算成 dB 写进 AudioServer ✓）。
##
## 参数 store：同前，只读 store.get_value(key)。
## 参数 key：必须是 BUS_OF 里登记的音量键（audio/master、music、sfx、ui、voice）；
##   不在表里时直接返回 false（不报错）。
## 返回值：bool —— true = "值已成功写进某条总线"；false = key 不在表里，或总线**建都建不出来**。
##   ⚠ 注意返回 bool 而非状态字符串：由 apply_one 负责翻译成 "ok" / "failed" ✓。
##
## 取值范围：内部把 store 的值 clampf 到 **[0.0, 1.0]** —— 手改过的 cfg 写了 3 或 -1
##   也不会把总线推到 +∞ / −∞ dB ✗。0 = 静音，1 = 原始音量（0dB）。
##
## 副作用：写该总线的音量 dB 与静音标志 → **立刻影响正在播放的音频**，不需要重启音频流 ✓。
##
## 调用时机：apply_one 里命中 BUS_OF 的键时（也就是任何音量滑条被拖动时）。
##
## 注意事项：
##   · 线性 → dB 用 linear_to_db()：**0 会得到负无穷** ✗（引擎日志会出现 -inf），
##     所以先 maxf(v, 0.0001) 夹一个极小值；真正的"静音"交给 set_bus_mute ✓；
##   · 静音阈值用 0.001 而不是 == 0.0：滑条拉到最底可能给到 0.000001 这类浮点残渣，
##     用阈值判断才能稳定静音 ✓；
##   · 总线不存在时会**先兜底创建**再重新取索引；创建后仍是 -1（极端情况）才返回 false ✓。
static func apply_bus(store, key: String) -> bool:
	# 用 get(..., "") 而不是 BUS_OF[key]：key 可能不是音量项，不该崩，返回 false 即可 ✓
	var bus := String(BUS_OF.get(key, ""))
	if bus == "":
		return false
	var idx := AudioServer.get_bus_index(bus)
	if idx == -1:
		# 兜底创建：走 apply_all 时通常已经建好，这一步是为了让"单独调 apply_one"也自洽 ✓
		ensure_buses()
		idx = AudioServer.get_bus_index(bus)
	if idx == -1:
		return false
	var v := clampf(float(store.get_value(key)), 0.0, 1.0)
	# linear_to_db(0) 是负无穷 ✗ → 夹一个极小值；真静音用 mute ✓
	AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(v, 0.0001)))
	# 阈值静音：v 被夹到 0.0 时这里为 true；用 <=0.001 是为了容忍滑条的浮点残渣 ✓
	AudioServer.set_bus_mute(idx, v <= 0.001)
	return true


# ==================== 显示：窗口 / 垂直同步 / 帧率 / 界面缩放 ====================
## 一次性应用**三个显示相关设置**：窗口模式、垂直同步、帧率上限。
##
## 参数 store：同前 —— 这里连续读三个不同的 key，所以形参必须是完整 store 而不是单个值 ✓。
## 返回值：无（void）→ ⚠ **没有返回值也就没有失败反馈** ✗；
##   调用方 apply_one 固定返回 "ok"，只要不崩就算成功。
##
## 副作用：改**当前运行窗口**的模式 / 同步方式 / 帧率上限；
##   在编辑器里执行会把编辑器窗口搞乱 ✗ → 所以 apply_one 已用 Engine.is_editor_hint() 拦在前面，
##   **本函数自己不判**（假定调用方已经判过了，改动时别漏掉这个前提 ✗）。
##
## 调用时机：apply_one 命中 graphics/window_mode / graphics/vsync / graphics/fps_limit
##   **任意一项**时都会把三项整组重写一遍 —— 它们互相牵制（改窗口模式可能把独占全屏的
##   同步行为冲掉，逐项单独写会留下中间状态），整组写最省心 ✓；
##   代价是改一项会顺手把另两项也写一次，执行开销可忽略 ✓。
##
## 注意事项：
##   · 窗口模式取值：0=窗口 1=无边框全屏 2=独占全屏；
##     其它值（含越界 / 损坏存档）落到 `_` 分支 = 窗口模式 ✓（默认值就是 0，所以"坏值回到窗口"是安全兜底 ✓）；
##   · 帧率上限走 schema 的 values 表（[0, 30, 60, 120, 144]），**0 表示不限制**；
##     先 value_to_index 把"真实值"反查成"下拉下标"，再取下标的真实值 —— 中间有一次值↔索引往返，
##     若下标越界则兜底为 0（不限制）✓；
##   · 独占全屏（2）会切换显示分辨率 / 独占显卡输出，窗口化调试时慎用 ✓。
static func apply_display(store) -> void:
	# 窗口模式是"新值全覆盖"：先定模式，再设同步与帧率，顺序上不会互相覆盖 ✓
	match int(store.get_value("graphics/window_mode")):
		# 1 = 无边框全屏：铺满屏幕但仍算"窗口"，Alt+Tab / 弹窗行为最友好，兼容性最好 ✓
		1:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		# 2 = 独占全屏：真正接管显示输出，延迟最低；切出切回可能黑屏一下，调试时慎用 ✓
		2:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN)
		# 0（窗口）以及任何越界 / 损坏的值统一回到窗口模式 —— 最不可能把用户"锁"在坏状态里 ✓
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# VSync 用布尔开关：true=开（画面稳定、帧率受显示器刷新率限制），false=关（帧率放开但可能撕裂）✓
	if bool(store.get_value("graphics/vsync")):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED)
	else:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# 帧率上限：store 里存的是"真实值"（0/30/60/120/144），先反查成下拉下标，再按下标取回真实值 ✓
	var idx := SettingsSchema.value_to_index("graphics/fps_limit", store.get_value("graphics/fps_limit"))
	var vals: Array = SettingsSchema.find("graphics/fps_limit").get("values", [])
	# 越界兜底 0 = 不限制；写成三元式而不是 vals[idx] 直接取，是为了防 schema 表被改动后索引越界崩掉 ✓
	Engine.max_fps = int(vals[idx]) if idx < vals.size() else 0


## 应用**界面缩放**（改根视口的 content_scale_factor，HUD / 菜单 / 字幕会整体变大变小 ✓）。
##
## 参数 scale：倍率，1.0 = 原始大小。
##   schema 给的滑条范围是 0.8~1.4（步长 0.05，默认 1.0）；本函数内部再夹到 **0.5~3.0** ——
##   比 schema 更宽，是为了兼容"别处直接传值"的调用（推测），同时防住损坏存档里的极端值
##   （0 或负数会让 UI 彻底消失 / 翻转 ✗）。
## 返回值：无。
##
## 副作用：写根视口的 content_scale_factor → **立即改变所有 CanvasItem（HUD、菜单、字幕）的缩放**；
##   ⚠ 它**不影响 3D 世界**（相机看到的景物不变）✓。编辑器里调用会缩放编辑器自己的界面 ✗
##   （apply_one 已用 is_editor_hint 拦截）。
##
## 调用时机：apply_one 命中 "access/ui_scale" 时（拖动"界面缩放"滑条）。
##
## 注意事项：
##   · 这里用 `as SceneTree` 强转 + 判空**合并在一步**：非 SceneTree 时强转结果为 null，
##     直接判 null 即可，比 apply_aa 里 `is` 再 `as` 的写法更紧凑 ✓（两种风格并存，不是笔误）；
##   · root 为 null 也要判 —— 场景树尚未就绪时确实可能 ✓（否则会直接报空引用 ✗）；
##   · content_scale_factor 需与项目设置的"视口拉伸模式（stretch mode）"配合才明显生效：
##     若拉伸模式为 disabled，本项可能看不出变化（推测，取决于项目设置）✓。
static func apply_ui_scale(scale: float) -> void:
	# 强转 SceneTree：类型不对时为 null → 下面的判空同时覆盖"类型不对"和"根节点缺失"两种情形 ✓
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null and loop.root != null:
		# 双保险夹紧：schema 的 0.8~1.4 是"界面友好范围"，这里的 0.5~3.0 是**安全边界** ✓
		loop.root.content_scale_factor = clampf(scale, 0.5, 3.0)


# ==================== 关于页信息（只读采集） ====================
## 采集"关于"页要显示的全部信息（**纯读取，不改任何状态** ✓）。
##
## 参数：无。
## 返回值：Dictionary，键名与 SettingsSchema 里 CAT_ABOUT 的键**完全一致**，界面可按 key 直接回填：
##   "about/version"   String  游戏版本（取 application/config/version；空串时回落 "0.1.0"）
##   "about/engine"    String  "Godot 4.x.y"（用 Engine.get_version_info() 拼出三段）
##   "about/renderer"  String  "渲染方式 ｜ 显卡名"（如 "Forward+ ｜ NVIDIA GeForce ..."）
##   "about/memory"    String  "123 MB"（OS.get_static_memory_usage() 换算成 MiB，保留 0 位小数）
##   "about/save_dir"  String  存档目录**绝对路径**（user:// 的 globalize 结果）
##   "about/crash_dir" String  崩溃日志目录绝对路径（user://crash_monitor，由 addons/crash_monitor 写报告）
## 所有值都是 String（**内存也是带单位的字符串**）→ 界面直接当文本用，无需再格式化 ✓。
##
## 副作用：无 —— 仅查询引擎信息与路径（**不创建任何目录**：crash_monitor 目录可能还不存在 ✓，
##   测试里只断言了 save_dir 存在 → 拿到 crash_dir 后不要假定它一定能打开 ✗）。
##
## 调用时机：settings_menu 打开 / 刷新"关于"分类时（每次都实时取，保证内存占用是当前值 ✓）。
##
## 注意事项：
##   · 版本号为什么要手工兜底 "0.1.0"？因为 ProjectSettings.get_setting 的默认值
##     **只在"键不存在"时生效**；项目里该键存在但值是空串时取回来就是空串 ✗ → 只好再判一次 ✓；
##   · 显卡名在无头 / 远程桌面 / 驱动异常时可能是空串 → 所以与渲染方式用 "｜" 拼在一行显示，
##     至少还能看出渲染方式（推测这是拼串的用意 ✓）；
##   · OS.get_static_memory_usage() 是**引擎自报的静态内存**，不含全部系统占用、也不含 GPU 显存 →
##     当"参考值"看，别当成任务管理器里的数字 ✓；
##   · 除以 1048576.0（= 1024×1024）而不是 1000000：按 MiB 展示，与引擎 / 系统口径一致 ✓。
static func about_info() -> Dictionary:
	var v := Engine.get_version_info()
	# 显卡名可能为空串（无头 / 远程桌面）→ 与渲染方式拼在一起显示，避免整行空白 ✓
	var adapter := RenderingServer.get_video_adapter_name()
	# 项目里 application/config/version 可能是空串 ✗（默认值只在键不存在时生效 ✗）
	var ver := String(ProjectSettings.get_setting("application/config/version", ""))
	if ver.strip_edges() == "":
		ver = "0.1.0"
	# 默认按 Forward+ 处理：本项目用的就是 forward_plus，只有显式设为 mobile / gl_compatibility 才改名 ✓
	var renderer := "Forward+"
	match String(ProjectSettings.get_setting("rendering/renderer/rendering_method", "forward_plus")):
		"mobile":
			renderer = "Mobile"
		"gl_compatibility":
			renderer = "Compatibility"
	# ⚠ 这里的键名必须与 SettingsSchema 的 about/* 键**逐字一致**：菜单是按 key 回填的，拼错会显示空值 ✗
	return {
		"about/version": ver,
		# 三段各自 int() 再拼：不同引擎版本里这些字段类型可能不同，先取整可避免 %d 格式化报错 ✓
		"about/engine": "Godot %d.%d.%d" % [int(v["major"]), int(v["minor"]), int(v["patch"])],
		"about/renderer": "%s ｜ %s" % [renderer, adapter],
		# 1048576.0 = 1024×1024，换算成 MiB；"%.0f" 不留小数，界面上更干净 ✓
		"about/memory": "%.0f MB" % (OS.get_static_memory_usage() / 1048576.0),
		# globalize_path 把 user:// 变成真实磁盘路径，方便玩家 / 客服直接去翻存档 ✓
		"about/save_dir": ProjectSettings.globalize_path("user://"),
		# 崩溃报告目录：由 addons/crash_monitor 插件写入（本函数只展示路径，不创建也不检查 ✓）
		"about/crash_dir": ProjectSettings.globalize_path("user://crash_monitor"),
	}
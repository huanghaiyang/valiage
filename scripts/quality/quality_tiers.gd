@tool
class_name QualityTiers
extends RefCounted
##
## ============================================================================
## 【文件】scripts/quality/quality_tiers.gd —— 画质档位定义的"纯数据 + 纯函数"层
## ============================================================================
## 【职责】整个画质分级系统的**唯一数据源**，本身不碰场景、不加载资源：
##   · 定义 4 个档位（Tier 枚举）与中文显示名（NAMES）；
##   · 给出每档的参数表（PRESETS：地表贴图分辨率后缀 / 地形 LOD 半径 / 地形网格尺寸 /
##     阴影等级 / 视距）；
##   · 提供贴图路径的"分辨率后缀"换算（swap_resolution_suffix / texture_for_tier）
##     与逐级回退查找（resolve_existing）。
## 【所属系统】画质分级（scripts/quality/）。因为全是静态纯函数、不依赖引擎状态，
##   所以可以脱离运行场景直接做单元测试（tests/test_quality.gd ✓）。
## 【关键依赖】
##   · 无 autoload 依赖：本类 extends RefCounted 且对外函数全为 static，
##     调用方无需 new()，也不读任何节点；档位"当前值"不在本文件（在 QualityManager）。
##   · 引用/消费本文件的脚本（**改动字段名或命名规则必须同步它们**）：
##       scripts/quality/quality_manager.gd       —— 持有当前档位、持久化 user://quality.cfg、发 tier_changed
##       scripts/quality/terrain_quality.gd       —— 读全部 5 个字段，改 Terrain3D 贴图与 LOD
##       scripts/quality/prop_texture_quality.gd  —— 用后缀规则换道具/墓园贴图
##       scripts/quality/grass_quality.gd         —— 用后缀规则换草贴图
##       scripts/quality/shadow_quality.gd        —— 按**档位序号**取阴影距离（并不直接读 shadow_quality 字段）
##       addons/texture_tier_baker/tier_rules.gd  —— 分档生成器里的**同规则副本**（改名要一起改）
##       tests/test_quality.gd、tests/test_image_convert.gd —— 自检
##   · 资源命名约定（本系统的"隐式接口"）：贴图分档靠**文件名后缀**区分，形如
##       xxx_diff_4k.jpg / xxx_diff_2k.jpg / xxx_diff_1k.jpg
##     （也认 _2048 / _4096 / _8192 这类数字写法）。没有分档文件时靠 resolve_existing() 回退。
## 【主要对外接口】
##   Tier 枚举 ｜ NAMES ｜ PRESETS ｜ all_tiers() ｜ get_preset(tier) ｜ tier_name(tier)
##   ｜ swap_resolution_suffix(path, suffix) ｜ texture_for_tier(path, tier)
##   ｜ resolve_existing(path, tier)
## 【已知的坑 / 注意事项】
##   1. 全静态、无实例状态：本类正常情况下**不会也不该被实例化**，
##      别在这里存运行时状态（存了也没有第二个使用者）。
##   2. 档位必须**单调递增**（越高档 → LOD 半径与视距越大），tests/test_quality.gd 会断言；
##      修改 PRESETS 时必须保持单调，否则分级失去意义。
##   3. get_preset() 返回的是 PRESETS 里的**字典本身（引用，不是拷贝）**，
##      调用方只读即可；（推测）PRESETS 是 const，Godot 4 中其内容应为只读，原地写入会报错。
##   4. 后缀换算**不做文件存在性检查**；要"保证贴图不变白"必须走 resolve_existing() ✓
##      （只有一套 4K 贴图时它会逐级回退，最后回到原图）。
##   5. view_distance 与 shadow_quality 目前**没有真正的运行时消费者**
##      （只有测试与日志在读）—— 改这两个字段不会立刻改变画面，别误以为无效。
##   6. 文件带 @tool 但没有任何编辑器副作用（纯函数），在编辑器里被调用是安全的。
##
## 画质档位定义（纯数据 + 纯函数，便于单元测试）。
##
## 本次范例用**地表贴图**：每档给出"用哪一套分辨率的贴图"
## （靠文件名后缀区分，如 brown_mud_leaves_01_diff_4k.jpg / _2k.jpg / _1k.jpg），
## 以及地形 LOD 参数、阴影、视距。

# ==================== 段：档位枚举与显示名 ====================

## 画质档位枚举。
## 取值范围 0~3，**数值即档位高低**（LOW < MEDIUM < HIGH < ULTRA），
## 因此可以直接参与比较和算术运算 —— 例如 resolve_existing() 里的 `while t >= Tier.LOW` 递减，
## 以及 quality_manager.gd 里的 `clampi(t, Tier.LOW, Tier.ULTRA)`。
## 注意：将来追加新档位**必须加在末尾**，不要插在中间；否则会挪动已有档位的数值，
## 把用户存在 user://quality.cfg 里的档位读成别的档（静默降/升画质）。
enum Tier { LOW, MEDIUM, HIGH, ULTRA }

## 档位中文显示名映射：Tier 枚举值（int）-> 显示用字符串。
## 用途：quality_manager.gd 切档日志、各分级脚本返回结果里的 tier_name 字段。
## 为什么直接写中文短词（"低/中/高/极高"）：项目里的画质日志/UI 是中文的，
##   这里放最终显示文案可以省掉一次翻译；
##   将来要做多语言，改这一张表即可（只影响显示，不影响任何判定逻辑）。
## 注意：键是 int（枚举的底层类型），要用 Tier.LOW 去取而不是字符串 "LOW"；
##   缺键时 tier_name() 会回退成 "未知"（不会崩）。
const NAMES := {
	Tier.LOW: "低",
	Tier.MEDIUM: "中",
	Tier.HIGH: "高",
	Tier.ULTRA: "极高",
}

# ==================== 段：档位参数表（PRESETS） ====================

## 档位参数表
## 键：Tier 枚举值（int）；值：该档的参数字典。四档必须都齐全，
## 缺字段时下游脚本会走各自的兜底默认值（例如 terrain_quality.gd 里 lod0_range 默认 128.0）。
##
## 各字段含义 / 单位 / 取值 / 调整效果：
##   terrain_texture_suffix : String，目标贴图分辨率后缀，取值 "1k"/"2k"/"4k"
##       （**不带**前导下划线；由 texture_for_tier() 拼成 "…_diff_4k.jpg" 这种路径）。
##       调大 → 更清晰，但显存/带宽暴涨（4K 的像素数是 1K 的 16 倍）；
##       这是本系统省显存的**主要杠杆**（草/地表/道具贴图都吃这个值）。
##   terrain_lod0_range : float，单位**米**。Terrain3D 网格资产的 lod0_range ——
##       在此半径内使用最精细的 LOD0 网格。调大 → 近处更精细但绘制更重；
##       调小 → 远处更早降级、省 GPU（代价是地块边缘可能看出简化痕迹）。
##       本文件把 64/96/128/192 排成递增，正好是"档位越高看得越精细"。
##   terrain_mesh_size : int，单位**米**。Terrain3D.mesh_size —— 地形网格单元边长。
##       调大 → 顶点数按平方级减少、更省（但地形起伏与地块接缝精度下降，更"钝"）；
##       调小 → 地形更细腻，顶点数暴增。
##       注意 LOW 档给 32 是**更小/更细**的网格：低档省的是 lod0_range 与视距，不是网格精度。
##   shadow_quality : int，0~3，与档位序号一一对应（0=低 … 3=极高）。
##       目前只是**语义标注**：真正干活的 shadow_quality.gd 按"档位下标"取自己的距离数组
##       （40/70/110/160m），并不读这个字段 —— 所以改这里不会立刻改变阴影表现。
##   view_distance : float，单位**米**。预期视距，供相机/雾/剔除逻辑参考。
##       调大 → 看得更远但需要渲染的物体更多。
##       注意：当前项目**没有运行时脚本消费它**（只有测试和日志在读），
##       改这里不会真的改变画面；要真正生效得先接上消费方。
##
## 单调性：档位越高，terrain_lod0_range 与 view_distance 必须**不减**
##   （tests/test_quality.gd 会断言；分级不单调就没有意义）。
## 数值由来：以 HIGH（4k / 128m / 48m / 2 / 180m）作为"基准画质"——
##   quality_manager.gd 的初始档位也是 HIGH，两者对齐，
##   保证"未做任何配置"时得到中高画质而不是最低画质。
const PRESETS := {
	Tier.LOW: {
		"terrain_texture_suffix": "1k",
		"terrain_lod0_range": 64.0,
		"terrain_mesh_size": 32,
		"shadow_quality": 0,
		"view_distance": 80.0,
	},
	Tier.MEDIUM: {
		"terrain_texture_suffix": "2k",
		"terrain_lod0_range": 96.0,
		"terrain_mesh_size": 48,
		"shadow_quality": 1,
		"view_distance": 120.0,
	},
	Tier.HIGH: {
		"terrain_texture_suffix": "4k",
		"terrain_lod0_range": 128.0,
		"terrain_mesh_size": 48,
		"shadow_quality": 2,
		"view_distance": 180.0,
	},
	Tier.ULTRA: {
		"terrain_texture_suffix": "4k",
		"terrain_lod0_range": 192.0,
		"terrain_mesh_size": 64,
		"shadow_quality": 3,
		"view_distance": 260.0,
	},
}


# ==================== 段：档位查询（纯函数） ====================


## 返回全部档位，**升序**（LOW → ULTRA）。
## 参数：无。
## 返回值：Array，元素是 Tier 枚举值（int），长度固定 4；每次调用都新建数组，
##   调用方可以放心增删/排序这个返回值，不会影响 PRESETS。
## 副作用：无。
## 调用时机：需要"遍历所有档位"的地方 —— tests/test_quality.gd 的单调性检查、
##   以及将来生成档位下拉 UI 时。
## 注意：**不要放进 _process 里反复调用**（每次都新建数组，属于无谓分配），缓存一次即可。
## 维护提醒：新增档位时要同步这里，否则会出现"有档位却没有预设"的不一致。
static func all_tiers() -> Array:
	return [Tier.LOW, Tier.MEDIUM, Tier.HIGH, Tier.ULTRA]


## 取指定档位的参数字典（预置表查询，最常用的入口）。
## 参数 tier：int，期望传 Tier 枚举值（0~3）；传越界值也不会崩。
## 返回值：Dictionary —— 该档的参数字典；**越界或未定义的键**回退到 MEDIUM 档。
## 为什么回退 MEDIUM 而不是报错/返回空：档位来自 user://quality.cfg，可能被手改坏，
##   宁可给一个"中庸"档位继续跑，也不要让画面/游戏崩掉。
## 副作用：无（不加载资源、不改任何状态、不写文件）。
## 重要：返回的是 PRESETS 内部的**同一个字典引用**（不是拷贝）——
##   调用方必须当只读使用；确实需要临时改一份，请自己 .duplicate(true)。
## 调用时机：任何"按档位取参数"的地方（terrain_quality.gd、quality_manager.gd.get_preset()）。
static func get_preset(tier: int) -> Dictionary:
	return PRESETS.get(tier, PRESETS[Tier.MEDIUM])


## 档位 -> 中文显示名的**安全**查询。
## 参数 tier：int，期望 Tier 枚举值；传越界/负数也不会崩。
## 返回值：String —— "低"/"中"/"高"/"极高"；查不到的档位返回 "未知"。
## 为什么外面要套一层 String(...)：Dictionary.get() 的返回类型是 Variant，
##   显式转换后才能满足 `-> String` 的静态返回类型，同时顺手给出了缺省文案。
## 副作用：无。
## 调用时机：日志输出（quality_manager.gd 切档、各分级脚本结果里的 tier_name）。
static func tier_name(tier: int) -> String:
	return String(NAMES.get(tier, "未知"))


# ==================== 段：贴图路径的分辨率后缀换算 ====================

## 把路径结尾的分辨率后缀换成指定值：
## "…_diff_4k.jpg" + "2k" → "…_diff_2k.jpg"
## "…_nor_gl_4k.png" + "1k" → "…_nor_gl_1k.png"
## 没有后缀的会补一个："rock.png" + "2k" → "rock_2k.png"
##
## 参数 path：资源路径（res://…，可带扩展名）；空串直接返回空串（避免造出 ".jpg" 这种垃圾路径）。
## 参数 suffix：目标分辨率后缀，取值 "1k"/"2k"/"4k" 等，**不带**前导下划线（函数自己拼 "_"）。
##   函数**不校验** suffix 是否合法：写错了只会生成一个不存在的路径，由 resolve_existing() 兜底。
## 返回值：String —— 只替换/追加**文件名**上的后缀，目录与扩展名原样保留。
## 副作用：无（不做 ResourceLoader 查询，也不写文件）。
## 调用时机：texture_for_tier() 以及各贴图分级脚本需要"某档的候选路径"时。
## 注意事项：
##   · 只动文件名：先把路径拆成 base（去扩展名）+ ext，因此**目录名里的 "4k" 不会被误伤**；
##   · 同一套规则在 addons/texture_tier_baker/tier_rules.gd 里有一份**自包含副本**（分档生成器用），
##     改命名规则必须两边同步，否则"生成的档位"和"运行时找的档位"会对不上；
##   · 本函数不保证返回的路径真的存在 —— 这是刻意的（见 resolve_existing 的设计）。
static func swap_resolution_suffix(path: String, suffix: String) -> String:
	# 空路径直接放行：否则会拼出 "_2k." 这类无意义路径，还会让下游误以为"有档位文件"
	if path == "":
		return ""
	# 只把"文件名"部分交给正则：否则目录名里若含 4k/2k 字样（如 .../4k/rock.jpg）会被改坏
	var base := path.get_basename()
	# 扩展名单独取出、最后再拼回去（.jpg / .png 原样保留 —— 草地 diff 是 .jpg 而 nor/rough 是 .png）
	var ext := path.get_extension()
	# 每次调用新建 RegEx：本类全静态、没有实例可缓存成员，且切档频率很低，这点开销可忽略
	var re := RegEx.new()
	# 正则：^(.*?) 非贪婪取前缀 ｜ [_-]? 容许 1 个分隔符（_4k 与 -4k 都认）
	# ｜ (\d+k|1024|2048|4096|8192)$ 锚定结尾 —— 只吃掉末尾的分辨率标记，
	# 于是 "…_01_diff_4k" 里 "_01"、"diff" 这些有意义的命名片段会被保留；(?i) 让 "_4K" 也认
	re.compile("(?i)^(.*?)[_-]?(\\d+k|1024|2048|4096|8192)$")   # 同时认 _4k 与 _2048 两种命名
	var m := re.search(base)
	if m != null:
		var head := m.get_string(1)
		# 兜底：文件名本身就是纯分辨率标记（如 "4k.jpg"）时捕获组 1 是空串，
		# 若不兜底会拼出 "_2k.jpg"（名字整段丢失）；这里退化成 "4k_2k.jpg" —— 仍不理想，
		# 但至少保住了非空主干，且这种病态命名在项目资源里并不存在
		if head == "":
			head = base
		return "%s_%s.%s" % [head, suffix, ext]
	# 完全没匹配到分辨率后缀（普通贴图名）：直接追加一个后缀，
	# 这样低档位也能命中"后来用分档生成器产出的"文件
	return "%s_%s.%s" % [base, suffix, ext]


## 该档位应该用的贴图路径
## （返回的是**候选**路径，不保证文件存在）
##
## 参数 path：原始贴图路径（一般是项目里最全的那套 4K 贴图）。
## 参数 tier：int，Tier 枚举值；越界时经 get_preset() 回退成 MEDIUM 的后缀（"2k"）。
## 返回值：String —— 形如 res://…/xxx_diff_2k.jpg；path 为空时返回 ""。
## 副作用：无；**不做存在性检查**。
## 调用时机：需要"严格按档位取路径"时（写日志对比、或配合 ResourceLoader.exists 自行判断）。
## 真正替换贴图的脚本请优先用 resolve_existing()，否则分档文件缺失时会变白 ✗。
## 注意："4k" 这个默认值只在 preset 缺少 terrain_texture_suffix 字段时才生效
##   （正常四档都写了该字段，所以实际不会走到）。
static func texture_for_tier(path: String, tier: int) -> String:
	return swap_resolution_suffix(path, String(get_preset(tier).get("terrain_texture_suffix", "4k")))


# ==================== 段：分档回退（保证绝不丢贴图） ====================

## 逐级回退：本档没有就退到更低档，最后回退到原路径。
## 这样即使只做了 4K 一套贴图，也永远不会出现"贴图丢失/变白"。
##
## 参数 path：原始贴图路径（空串直接返回 ""）。
## 参数 tier：int，起始档位（Tier 枚举值）；传大于 ULTRA 的值也能工作
##   （等价于"从最高档往下试"，因为候选后缀本身都来自档位表，不会去试表外的后缀）。
## 返回值：String —— 第一个**真实存在**的档位路径；全都不存在时原样返回 path
##   （宁可继续用偏重的 4K，也绝不返回不存在的路径导致白图）。
## 副作用：只做 ResourceLoader.exists() 探测 —— 不 load 资源、不改内存、不写磁盘。
## 调用时机：切档时（tier_changed 回调）或 _ready 首次应用；**不要每帧调用**
##   （每次最多 4 次文件系统/导入库探测，虽然便宜但没必要）。
## 注意事项：
##   · 这是所有"贴图分级"脚本共用的**防白图保险丝**（terrain_quality / prop_texture_quality /
##     grass_quality 都最终走这里），改动它等于改整个系统的安全底线；
##   · ResourceLoader.exists() 只认**已导入**的资源：编辑器里刚由分档生成器产出的图，
##     若尚未完成导入，这里可能暂时探测不到（推测），重扫文件系统/重启编辑器即可。
static func resolve_existing(path: String, tier: int) -> String:
	# 空路径放行：否则会拼出无意义路径再去探测，纯属浪费
	if path == "":
		return ""
	# 从调用方给的档位开始往下试（局部变量，避免改到入参语义）
	var t := tier
	# 用 while 递减而不是 for：一旦命中就立刻 return，不必跑完所有档位；
	# 下界写 Tier.LOW（== 0）而不是字面量 0，将来档位枚举扩展时这行不用动
	while t >= Tier.LOW:
		var p := texture_for_tier(path, t)
		# 用 exists() 而不是 load()：只需要知道路径在不在，
		# 避免把大图（4K 贴图可达数十 MB）提前读进内存/显存
		if ResourceLoader.exists(p):
			return p
		# 本档没有对应分档文件 → 降一档再试（Tier 是 int 枚举，可以直接做算术）
		t -= 1
	# 四档都没有分档文件：退回原路径 —— 贴图会偏重，但绝不会丢失/变白 ✓
	return path
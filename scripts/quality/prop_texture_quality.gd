extends Node
## 【画质分级 · 模型贴图】把墓园/道具材质的贴图按当前档位换成"对应分辨率的版本"。
##
## 与 `scripts/quality/terrain_quality.gd`（地表贴图分级）**同一套机制**：
##   · 分辨率后缀由 `QualityTiers` 决定（1k / 2k / 4k）；
##   · 换不到就用 `QualityTiers.resolve_existing()` 回退到存在的最高档
##     -> **永远不会出现"贴图丢失 / 变白"**；
##   · **内嵌贴图（resource_path 为空）直接跳过** —— 与地表贴图完全同一条防护。
##
## ★ 前提：贴图要有分档文件，命名形如 `xxx_diff_4k.jpg / _2k / _1k`（同 QualityTiers 规则）。
##   如果墓园贴图是**嵌在 glb 里**的，它们没有 resource_path -> 会被跳过（日志会报数量），
##   那种情况需要先把贴图导出成文件再分档（我可以再写一个导出工具）。
##
## 用法（main.gd 世界装配后挂上即可，见那里的调用）：
##   var pq := preload("res://scripts/quality/prop_texture_quality.gd").new()
##   add_child(pq)
##
## ── 所属系统 ─────────────────────────────────────────
##   画质分级系统（scripts/quality/）中的"**模型 / 道具贴图**"一路，
##   与 terrain_quality.gd（地表贴图）、shadow_quality.gd（阴影距离）、
##   grass_quality.gd（草）并列；同一批被 main.gd 在世界装配阶段挂上 ✓。
##
## ── 关键依赖（缺一个也不会报错，但功能会退化）──────────
##   · autoload `/root/Quality`（quality_manager.gd）：信号 `tier_changed(tier:int)`、
##     属性 `tier`。**取不到时不报错**，只是退化为"按默认 HIGH 档应用一次" ✓；
##   · `QualityTiers`（quality_tiers.gd，class_name 全局类，无需 autoload）：
##     提供 `Tier` 枚举、`tier_name()`、`texture_for_tier()`、`resolve_existing()` ✓；
##   · `addons/texture_tier_baker`（编辑器侧工具）：负责把原图烘出 _1k/_2k/_4k 变体。
##     它没跑过 → 本脚本一路回退到原图 = 什么都没换，但**绝不报错、绝不白贴图** ✓；
##   · `scripts/quality/terrain_quality.gd`：同机制的参照实现（两边命名规则必须一致 ✓）。
##
## ── 主要对外接口 ─────────────────────────────────────
##   · `apply_current() -> Dictionary`：按 `/root/Quality` 当前档位应用（无 Quality 时按 HIGH）；
##   · `apply_tier(t:int) -> Dictionary`：按指定档位应用（t 取 `QualityTiers.Tier.LOW..ULTRA`）。
##   返回字典字段：`tier` / `tier_name` / `mats`（收集到的材质个数）/ `changed`（换掉的插槽次数）/
##   `embedded`（内嵌贴图跳过次数）/ `missing`（找不到分档文件次数）/ `sources`（最多 8 个来源资源路径），
##   外加"插槽名 -> 该插槽被换的次数"（如 `albedo_texture`、`normal_texture`）✓。
##
## ── 已知的坑与注意事项 ───────────────────────────────
##   · **幂等**：第二次 apply 时贴图已是变体路径，`_base` 里存的原始路径会被复用 ✓，
##     所以 main.gd 里"早挂一个 + 晚挂一个"两个实例各跑一次是安全的 ✓（只多几点开销）；
##   · **只改内存、不落盘**：材质是 load() 出来的共享实例，改它不会写回 .res/.tscn ✓；
##   · 收集范围是 `get_tree().current_scene` **整棵树** → 节点越多越慢，
##     只应在世界装配完成后（或切档时）调用，**不要塞进 _process** ✗；
##   · `_base` 只存路径 String、**绝不持有 Texture 引用** → 被换下的 4K 图能靠引用计数释放 ✓；
##   · 只处理**已进入场景树**的 MeshInstance3D / MultiMeshInstance3D；
##     运行时后加的道具需要再应用一次（推测）。
# ==================== 依赖与导出配置 ====================
## name_hints：节点名关键词白名单（大小写敏感的**子串**匹配，不是通配符 / 正则 ✗）。
##   · 默认 `[]`（空）= **匹配全部**（推荐，理由见下方紧跟的说明 ✓）；
##   · 填了关键词 → 只有"节点自身或它 6 层以内的祖先"名字包含任一关键词才会被处理
##     （例如 `["墓园", "栅栏", "fence"]`）；
##   · 调宽（留空）→ 更全面但更慢；调窄 → 更快，但**漏掉的材质会一直用 4K 占显存** ✗，慎用。
@export var name_hints: PackedStringArray = []
## ★ 留空 = **处理场景里所有 MeshInstance3D 的材质**（推荐）：
##   没有分档文件的贴图会自动回退到原图 ✓（零风险），所以不必按名字挑节点 ——
##   对 glb_split 生成的那些 .tscn/.res（节点名不归我们控制）尤其重要 ✓。
##   想缩小范围再填关键词（如 "墓园" / "栅栏" / "fence"）。
## 编辑器里默认不动手（切档若改到资源引用，保存后档位就被"烤"进场景了 ✗ —— 与地表贴图一致）
@export var apply_in_editor := false

# ==================== 运行时缓存 ====================
## _base：材质**实例** id（int）-> { 插槽名: 原始贴图路径(String) }，本文件唯一的持久状态。
##   · 只存**路径字符串**、绝不存 Texture 引用 ✓ —— 换掉后原图失去最后一个外部引用，
##     能由引用计数自然释放（Godot 没有"强制卸载资源缓存"的 API ✗，只能不留引用 ✓）；
##   · 必须存：换过之后 `tex.resource_path` 已经变成变体路径，不记原路径就无法在档位之间来回切 ✓；
##   · 键用 instance_id（不是 resource_path）→ 同一个 .res 被多处加载成不同实例时互不干扰 ✓；
##   · 只增不减（材质释放后对应条目还留着）→ 内存开销极小、可忽略；
##     （推测）节点释放后 id 可能被系统复用，若同一进程内反复重建场景，建议跟着重建本节点 ✓；
##   · 以"插槽名"为二级键 → 同一材质的 albedo 与 normal 各自记原始路径，切档不会互相污染 ✓。
## 材质实例 id -> { 属性名: 原始路径 }（换过之后 tex.resource_path 变成变体路径，
## 所以必须记住原始路径，否则无法在档位之间来回切换 ✓）
var _base: Dictionary = {}


# ==================== 生命周期与档位回调 ====================
## _ready()：节点进入场景树时装配（add_child 之后立即执行）。
## 调用时机：main.gd 世界装配阶段 —— **首帧渲染之前**，
##   所以 4K 贴图大概率从未被上传到显存（只在加载瞬间存在于内存 ✓，本方案能达到的下限）。
## 副作用：
##   · 连接 `/root/Quality` 的 `tier_changed`（已连过则不重复连 ✓）；
##   · 立刻 `apply_current()` → **替换场景里材质的贴图引用**（只改内存 ✓）；
##   · 打印一行 `[画质] 模型贴图已按「高」应用：{...}` 日志 ✓。
## 注意事项：
##   · 编辑器里且 `apply_in_editor == false` → **直接 return**（不连接、不应用）：
##     否则在编辑器里切档会把"当前档位的贴图路径"烤进场景/资源文件 ✗；
##   · `/root/Quality` 不存在时不报错，只是退化为"按默认 HIGH 档应用一次" ✓；
##   · 依赖 `get_tree()` 解析绝对路径 —— 节点**不在场景树里**时找不到 `/root/Quality`（推测），
##     所以务必先 `add_child()` 再用，不要对 `new()` 出来的裸实例手动调 apply ✗。
func _ready() -> void:
	if Engine.is_editor_hint() and not apply_in_editor:
		return
	var qm := get_node_or_null("/root/Quality")
	if qm != null and qm.has_signal("tier_changed") \
			and not qm.tier_changed.is_connected(_on_tier_changed):
		qm.tier_changed.connect(_on_tier_changed)
	# ★ 自己主动应用一次：**不能只依赖上面的信号** —— QualityManager 在自己的 _ready() 里
	#   就 emit 过一次 tier_changed ✗，本节点若连得晚就错过了那一次 → 首帧会一直是原图 ✗
	apply_current()


## _on_tier_changed(_t)：`/root/Quality` 的 `tier_changed(tier:int)` 信号回调。
## 参数 `_t`：新档位，取值范围 `QualityTiers.Tier.LOW(0) ~ ULTRA(3)`。
##   名字前带下划线 = **有意不使用**它：下面重新向 Quality 查询当前档位，
##   保证"信号参数"与"qm.tier 实际值"永远一致（推测是刻意的防错设计 ✓）。
## 返回值：无。副作用：内部调用 apply_current() → 可能替换材质贴图引用、打印日志、写 `_base`。
## 时机：QualityManager.set_tier() 每次切档时同步触发（调试面板 / 设置界面切档 ✓）。
## 注意：整个场景树的扫描在这里是同步完成的 → 切档瞬间会卡一下（推测，档位不是每帧切换，可接受 ✓）。
func _on_tier_changed(_t: int) -> void:
	apply_current()


# ==================== 对外接口：应用档位 ====================
## apply_current()：按**当前画质档位**应用贴图分级（对外最常用的入口）。
## 参数：无。
## 返回值：`apply_tier()` 的结果字典（字段含义见文件头"主要对外接口"）。
## 副作用：替换材质贴图引用、打印一行日志、写满 `_base` 缓存。
## 档位来源：`/root/Quality.tier`；**取不到时退回 HIGH 而不是 LOW**
##   —— "项目没装画质管理器"时更应该保持原本的高清观感 ✓。
## 时机：_ready() 一次 + 每次 `tier_changed` 一次；也可被外部手动调用（**幂等** ✓）。
## 注意：用 `get_node_or_null("/root/Quality")` + `int(qm.tier)` 的**鸭子类型**写法，
##   而不是 `QualityManager.instance` —— 这样不依赖该脚本被注册成 autoload 类型，
##   换掉画质管理器实现也不会编译不过 ✓；代价是节点名必须叫 `Quality`（约定写死在路径里 ✓）。
func apply_current() -> Dictionary:
	# 兜底档位：只有拿不到 /root/Quality 时才用到这个值（改它 = 改"无管理器"时的默认观感 ✓）
	var t: int = QualityTiers.Tier.HIGH
	var qm := get_node_or_null("/root/Quality")
	if qm != null:
		t = int(qm.tier)
	return apply_tier(t)


## apply_tier(t)：**本文件的核心** —— 按指定档位扫描场景，把每个材质插槽的贴图换成对应分辨率的版本。
## 参数 t：档位枚举 int，`QualityTiers.Tier.LOW(0) / MEDIUM(1) / HIGH(2) / ULTRA(3)`。
##   · 本函数**不做范围校验**：越界值会走 `QualityTiers.get_preset()` 的默认分支（回退 MEDIUM 预设）（推测）；
##   · 正常调用请传 `Tier` 枚举常量，不要传裸数字 ✓。
## 返回值 Dictionary（同时原样打印一行日志）：
##   `tier` / `tier_name` / `mats` / `changed` / `embedded` / `missing` / `sources` / `"<插槽名>": 次数`。
##   · mats     收集到的材质**个数**（含重复引用，见 `_collect_materials()` 说明）；
##   · changed  真正被替换的贴图**插槽次数**（不是材质数，观察省显存效果要看它 ✓）；
##   · embedded 因 `resource_path` 为空（贴图嵌在 glb / 场景里）而跳过的插槽次数；
##   · missing  找不到任何可用分档文件而跳过的插槽次数（保留原图 ✓ 绝不会变白 ✓）；
##   · sources  被修改的材质所属资源路径，**最多 8 个**（防止日志刷屏 ✓）。
## 副作用（**全部只作用于内存**）：
##   · `mat.set(prop, nt)` / `sm.set_shader_parameter(prop, nt)` 替换贴图引用；
##   · 填充/更新 `_base`（记住原始路径，供之后切档回切 ✓）；
##   · `print()` 一行日志。**不写文件、不发信号、不动场景树结构** ✓。
## 性能：遍历 current_scene 整棵树 × 每个材质的全部贴图插槽 → 大场景切档时会同步卡一下（推测）。
## 幂等性：第二次调用时多数插槽 `want == src` → 直接 continue ✓，
##   所以 main.gd 里"早挂一个 + 晚挂一个"两个实例各跑一次是安全的 ✓。
func apply_tier(t: int) -> Dictionary:
	# 统计字典兼作日志载荷：调用方（main.gd）目前**不接收**返回值 ✓；"mats" 先占位，收集完再填真实值
	var out := {"tier": t, "tier_name": QualityTiers.tier_name(t),
			"mats": 0, "changed": 0, "embedded": 0, "missing": 0}
	# 先收集成数组再逐个处理：收集阶段只读场景树 ✓，避免"边遍历边改"带来的不确定性 ✓
	var mats := _collect_materials()
	out["mats"] = mats.size()
	for m in mats:
		# 材质只可能是这两种之一；其余类型没有统一的"贴图插槽"接口 ✗ → 直接跳过
		var mat := m as BaseMaterial3D
		var sm := m as ShaderMaterial                  # ★ blend_tools 的 _blend_mat_* 等 ✓
		if mat == null and sm == null:
			continue
		# 键 = 材质**实例** id：同一张贴图被多个材质引用时，各自独立记录原始路径 ✓
		# （不能用 resource_path 当键 ✗：内嵌/匿名材质的 resource_path 是空串 → 它们会共用同一个
		#   _base 条目而互相覆盖 ✗；用 instance_id 则每个材质实例一份，天然隔离 ✓）
		var id := (mat if mat != null else sm).get_instance_id()
		# 首次见到该材质时建空表；之后一直复用 → 多次 apply 都能拿回原始路径 ✓（幂等的基础）
		# 注意：_base 只增不减（材质被 free 后条目仍留着，开销极小、可忽略）
		if not _base.has(id):
			_base[id] = {}
		# ★ 覆盖**全部贴图插槽**（与生成器的 12 个插槽对齐 ✓）：
		#   之前只换 albedo/normal ✗ → 4K 的 roughness/metallic/ao/height/emission 等
		#   仍然占着显存 ✗（例如 `..._rm.jpg` 4096 单独就 21MB ✗）。
		#   没有分档的贴图会走 resolve_existing 回退到原图 ✓ → 不会白贴图 ✓
		# ★ ShaderMaterial（如 `_blend_mat_石质墓园栅栏*.tres`）**也必须处理** ✗：
		#   它的贴图是 shader 参数，参数名从 Object.get_property_list() 的
		#   `shader_parameter/xxx` 前缀里取 ✓
		#   （不要用 ShaderMaterial.get_shader_parameter_list() —— Godot 4.7 没有这个方法 ✗）
		var props: Array = ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture",
				"emission_texture", "ao_texture", "heightmap_texture", "rim_texture",
				"clearcoat_texture", "anisotropy_texture", "detail_albedo", "detail_normal"]
		# ★ 纯 ShaderMaterial（mat == null）：上面的固定 12 项名字在 shader 里未必存在，
		#   必须丢掉再按"实际暴露的 shader 参数"重建 ✓
		if mat == null and sm != null:
			# 整体清空而不是追加：否则固定列表里不存在的名字会让循环白跑一遍
			# （取到 null 会被下面的 `if not (cur is Texture2D)` 挡住，不会崩 ✓，只是浪费时间）
			props = []
			for p in sm.get_property_list():
				var pn := String(p.get("name", ""))
				if pn.begins_with("shader_parameter/"):
					props.append(pn.substr("shader_parameter/".length()))
		for prop in props:
			# ★ 先 is 再 as：shader 参数可能是 float/vec 等**非对象值** ✗
			#   （`as` 对非对象值会报 "Invalid cast: can't convert a non-object value" ✗）
			var cur: Variant = null
			if mat != null:
				cur = mat.get(prop)
			else:
				cur = sm.get_shader_parameter(String(prop))
			if not (cur is Texture2D):
				continue
			var tex := cur as Texture2D
			# src = **当前实际挂着**的路径（可能是上一档换好的变体 ✗ 不能当原始路径用）
			var src := String(tex.resource_path)
			# orig 优先取 _base 里记的"最初路径"：否则 4k→1k 之后想切回 2k 就找不到起点了 ✗
			var orig := src
			if _base[id].has(prop):
				orig = String(_base[id][prop])
			# 空路径 = 贴图内嵌在 glb / 场景里（没有独立文件）→ 无法分档，直接跳过 ✓
			# （只计数不报错：glb 内嵌贴图是常态，靠日志里的 embedded 数量判断要不要先导出 ✓）
			if orig.is_empty():
				out["embedded"] = int(out["embedded"]) + 1
				continue                      # 内嵌贴图：不碰 ✓
			# 无论本次能否换成功，都先记下原始路径 ✓（下次切档要靠它回切，否则会越切越偏 ✗）
			_base[id][prop] = orig
			# 期望路径：本档位后缀；找不到就逐级往低档回退，最后回退到 orig 本身 ✓（绝不返回空）
			var want := QualityTiers.resolve_existing(orig, t)
			# ★ 关键修正：`resolve_existing()` 在找不到本档位文件时会**回退到原图** ✓
			#   → 此时 want == orig ✗，但磁盘上可能确实存在"本档位后缀 + 别的扩展名" ✓
			#   （例如生成端对数据类贴图强制存 `..._rm_1k.png`，而本档位规则找的是
			#     `..._rm_1k.jpg` ✗）—— 旧写法只判 "not exists" ✗ 会把这种情况漏掉 ✗，
			#   表现就是"磁盘上明明有 _1k 文件，切档却没换" ✓
			# 只要"按同扩展名没找到本档文件"（want 为空 / 退回原图 / 文件不存在）就走下面兜底 ✓
			if want.is_empty() or want == orig or not ResourceLoader.exists(want):
				# 本档位"应当"使用的路径 → 只取文件主干（去扩展名），当作跨扩展名匹配的前缀 ✓
				var stem := QualityTiers.texture_for_tier(orig, t).get_basename()
				want = ""
				# 跨扩展名兜底：只试这 4 种（Godot 能导入为贴图的常见扩展名 ✓）。
				# 用 ResourceLoader.exists() 而不是 FileAccess.file_exists()：
				#   未被 Godot 导入的文件 load() 会失败，所以"能 load"才是有效存在 ✓
				for e in [".png", ".jpg", ".jpeg", ".webp"]:
					var cand := stem + String(e)
					if cand != orig and ResourceLoader.exists(cand):
						want = cand
						break
			# 全部候选都没命中 → 保留原图 ✓（**绝不把贴图置空**，这是"不会变白"的最后一道防线 ✓）
			if want.is_empty():
				out["missing"] = int(out["missing"]) + 1
				continue
			# 当前挂着的就是目标贴图 → 空操作（幂等的关键：第二次 apply 基本都走这里 ✓）
			if want == src:
				continue
			# 同步加载变体：切档本就允许阻塞，异步反而会引入"贴图还没到就写回"的竞态 ✗；
			# 这里用 load() 而非 ResourceLoader.load_threaded_request()（后者还需要 poll 取结果 ✓）
			var nt := load(want) as Texture2D
			# 路径存在但加载失败（导入损坏 / 类型不是 Texture2D）→ 按 missing 计数并保留原图 ✓
			if nt == null:
				out["missing"] = int(out["missing"]) + 1
				continue
			# ★ 写回也要分类型：BaseMaterial3D 用属性，ShaderMaterial 用 shader 参数
			#   （blend 材质下 `mat` 是 null ✗，直接 mat.set(...) 会崩 ✓）
			if mat != null:
				mat.set(prop, nt)
			else:
				sm.set_shader_parameter(String(prop), nt)
			# changed = 插槽次数（不是材质数）：要看"这一档到底少占了多少贴图"，得看它 ✓
			out["changed"] = int(out["changed"]) + 1
			# 按插槽名分别计数 → 日志里一眼能看出是 albedo 还是 normal 被换了 ✓
			out[prop] = int(out.get(prop, 0)) + 1        # 细分计数：albedo_texture / normal_texture ✓
			# ★ 诊断：记录"被改的材质来自哪个资源文件"——这样日志里能直接看到
			#   res://scenes/墓园/石质墓园栅栏_01.res 这种**打包在 .res 里**的材质也被换掉了 ✓
			#   （材质是 load() 出来的共享实例 ✓ 只改内存 ✓ 不会写回 .res ✓）
			# ★ mat 在 ShaderMaterial 分支里是 null ✗ → 取非空的那个的 resource_path ✓
			#   （三元表达式结果是 Variant ✗ 推断不出类型 → 先落到 Resource 再取 String ✓）
			var owner_res: Resource = mat if mat != null else sm
			var src_res := String(owner_res.resource_path)
			# 匿名 / 内嵌材质没有 resource_path → 不计入 sources（否则日志里一堆空串 ✗）
			if src_res != "":
				# out.get("sources", []) 在字段还不存在时返回的是**临时新数组** ✗
				# → 下面必须再写回 out，否则第一次收集到的路径会丢 ✓（这就是要写回的原因）
				var arr: Array = out.get("sources", [])
				# 去重 + 上限 8：这个字段只为日志可读性服务，不能让大场景把它刷屏 ✓
				if not arr.has(src_res) and arr.size() < 8:
					arr.append(src_res)
					out["sources"] = arr
	# 唯一的一行正常日志：每次 apply 打 1 行（main.gd 挂了两个实例 → 实际常见 2 行 ✓）
	# 想确认"到底换了哪些贴图"，看 `changed` / `missing` / `embedded` 与各插槽计数即可 ✓
	print("[画质] 模型贴图已按「%s」应用：%s" % [out["tier_name"], out])
	# 返回同一份统计给调用方（当前 main.gd 不使用返回值，保留是为了排查/自测方便 ✓）
	return out


# ==================== 材质收集（场景树遍历） ====================
## _collect_materials()：深度优先收集 `get_tree().current_scene` 整棵子树里"关注范围内"的材质。
## 参数：无（范围由成员 `name_hints` 决定 ✓）。
## 返回值：Array，元素是 Material，**允许重复** —— 同一材质既做 override 又被网格自带引用时会重复出现；
##   重复**无害**：apply_tier 第二次处理时 `want == src` 会直接 continue ✓。
## 覆盖三类来源（缺一不可，否则会出现"明明有 _1k 却没换"）：
##   ① `material_override`（整体覆盖）；
##   ② 每个表面的 `surface_override_material`（逐表面覆盖）；
##   ③ 网格自带材质 `mesh.surface_get_material()`（glb_split 导出的 .res 常走这条 ✓）。
## 副作用：**只读场景树** ✓ 无任何修改。
## 注意：
##   · 用**显式栈**而不是递归：避免超深场景树递归爆栈，也省函数调用开销（推测是刻意的 ✓）；
##   · `MultiMeshInstance3D` **不是** `MeshInstance3D` 的子类 ✗ → 必须单独一个分支 ✓；
##   · 只有**已进入场景树**的节点才会被扫到 ✗ → 运行时后加的道具需要重新 apply 一次（推测）；
##   · 依赖 `get_tree()`：节点不在场景树里时会崩 ✗ → 只在 add_child 之后调用 ✓；
##   · `current_scene` 为 null（场景尚未装配完）**不会崩**：栈里放的就是 null，下一轮被 continue 挡掉 ✓。
## 收集关注子树下的所有材质（material_override + surface override + 网格自带材质）
func _collect_materials() -> Array:
	# 扁平数组，会丢失"来自哪个节点"的信息 —— 本用途不需要来源节点 ✓
	var out: Array = []
	# 起点 = 当前场景根（Main.tscn 的根；按 main.gd 的挂法本节点是它的子节点 → 自己也会被扫到，
	# 但本节点不是 MeshInstance3D，所以无影响 ✓）
	var st: Array = [get_tree().current_scene]
	# 显式栈 DFS：pop_back 取尾部 → 遍历顺序与结果无关（材质是集合语义 ✓）
	while not st.is_empty():
		var n = st.pop_back()
		# ★ 兜底：current_scene 为 null 时栈里就是 null → 跳过而不是崩 ✓
		if n == null:
			continue
		# 只认这两种"网格载体"；容器/灯光/碰撞体等只负责继续往下找子节点 ✓
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			# 关键词过滤：name_hints 为空时恒真 = 全场景都处理（见 _matches() ✓）
			if _matches(mi):
				if mi.material_override != null:
					# 同一个材质可能同时出现在三类来源里 → 允许重复 append ✓（重复处理幂等无害）
					out.append(mi.material_override)
				# 逐个表面的 override；没有 override 的表面返回 null → 跳过 ✓
				for i in range(mi.get_surface_override_material_count()):
					var sm := mi.get_surface_override_material(i)
					if sm != null:
						out.append(sm)
				# ★ 网格自带材质：glb_split 导出的 .res 材质槽常在这里 ✗（不收集就会漏换）
				if mi.mesh != null:
					for i in range(mi.mesh.get_surface_count()):
						var m2 := mi.mesh.surface_get_material(i)
						if m2 != null:
							out.append(m2)
		elif n is MultiMeshInstance3D:
			# ★ 关键补充：`MultiMeshInstance3D` **不是** `MeshInstance3D` 的子类 ✗
			#   （散置的围栏/草丛/石块常走它 ✓）→ 之前完全没被收集到 ✗
			#   表现为"明明有 _1k 文件，切档却没换" ✓
			var mmi := n as MultiMeshInstance3D
			if _matches(mmi):
				if mmi.material_override != null:
					out.append(mmi.material_override)
				var mm: MultiMesh = mmi.multimesh
				# ★ 走 mm.multimesh → mm.mesh 取材质：MultiMesh 的实例变换与材质都在 multimesh 里 ✓
				if mm != null and mm.mesh != null:
					for i in range(mm.mesh.get_surface_count()):
						var m3 := mm.mesh.surface_get_material(i)
						if m3 != null:
							out.append(m3)
		# 逐层展开子节点（对应上面的显式栈；放在最后 = 先处理自身再处理子树 ✓）
		for c in n.get_children():
			st.append(c)
	return out


# ==================== 关键词匹配 ====================
## _matches(n)：判断节点 n 是否在"关注范围"内（配合 `name_hints` 缩小处理面）。
## 参数 n：任意节点（通常是 MeshInstance3D / MultiMeshInstance3D）。
## 返回值：bool —— true = 处理它的材质；false = 跳过。
## 规则：
##   · `name_hints` 为空 → **直接 true**（默认行为：全场景都处理 ✓ 最安全）；
##   · 否则从 n 自身逐级向上找祖先，**最多 6 层**，任一名字包含任一关键词即 true；
##   · 匹配用 `String.contains()`：**区分大小写**、纯子串（不支持通配符 / 正则 ✗）；
##   · 名字里带数字后缀（`栅栏_01`）不必写全，写 `栅栏` 即可 ✓。
## 副作用：只读 ✓ 无。
## 注意：
##   · 深度上限 6 是"性能 vs 覆盖"的折中；关键词只出现在**更深的祖先**上会被漏掉 ✗
##     （表现为"该换的没换"）→ 此时应放宽 name_hints 或加关键词 ✓；
##   · 用祖先链匹配（而不是只比自身名）是因为道具的 MeshInstance3D 名往往是叶子名，
##     而"墓园 / 栅栏"这类分组关键词挂在父级容器上 ✓。
## 自己或任一祖先的名字命中关键词；★ 关键词为空 = **全部匹配**（默认行为 ✓）
func _matches(n: Node) -> bool:
	# ★ 留空 = 全匹配：靠"找不到分档文件就回退原图"保证零风险 ✓，所以默认不必按名字挑节点
	if name_hints.is_empty():
		return true
	# 从自身开始往上走：关键词命中自身或任一祖先即算"在关注范围内" ✓
	var cur: Node = n
	var depth := 0
	# 深度上限 6：防止在超深场景树里一路走到根（性能考虑 ✓），代价是深祖先的关键词会漏 ✗
	while cur != null and depth < 6:
		var nm := String(cur.name)
		for h in name_hints:
			# 区分大小写的子串匹配；迭代出来的 h 本已 String，这里的 String() 是冗余但无害的显式转换 ✓
			if nm.contains(String(h)):
				return true
		# 沿场景树向上（不是"沿树形遍历"，只是祖先链，最多 6 次 ✓）
		cur = cur.get_parent()
		depth += 1
	# 走完 6 层都没命中 → 不处理该节点 ✓
	return false

## ============================================================================
## 文件：scripts/quality/grass_quality.gd ｜ 名称：【画质分级 · 草贴图】
## ============================================================================
##
## 一、本文件职责
##   把「草」用到的贴图，按当前画质档位（低/中/高/极高 ↔ 1k/2k/4k）换成对应分辨率
##   的那一份，降低显存占用与贴图带宽。**只改内存里的引用**，磁盘上一个字节都不写。
##
## 二、所属系统
##   `scripts/quality/` 画质分级子系统里的一个"应用器（applier）"，与下列文件并列、
##   互不 import：
##     · terrain_quality.gd        —— 地表贴图分级
##     · prop_texture_quality.gd   —— 墓园/道具材质贴图分级
##     · shadow_quality.gd         —— 阴影绘制距离分级
##   全系统共用的"档位定义 + 分档命名规则"都在 QualityTiers（quality_tiers.gd）。
##
## 三、关键依赖
##   1) autoload `Quality`（= scripts/quality/quality_manager.gd，见 project.godot 的
##      [autoload] 段）
##        · 读它的 `tier` 属性拿当前档位；
##        · 订阅它的 `tier_changed` 信号，切档后自动重换。
##        · 一律用 get_node_or_null("/root/Quality") 而不是直接引用：
##          单测 / 独立场景里没有这个 autoload 时必须不崩，能降级到默认档。
##   2) 全局类 `QualityTiers`（class_name 注册，无需 preload）
##        · QualityTiers.tier_name(tier)        → 日志里的中文档位名
##        · QualityTiers.resolve_existing(...)  → "换分辨率后缀 + 逐级回退"
##   3) 资源 `res://scenes/草/_blend_mat_grass_bermuda_01.tres`
##      20+ 个草场景共用的混合材质，换这一处即可覆盖它们全部。
##   4) 插件脚本 `addons/simplegrasstextured/grass.gd`（下文简称 SGT）
##      草实例节点自身还挂着 4 个贴图槽，与"材质"是两套载体，必须分别处理。
##   5) 调用方 `scripts/main.gd`：在 _ready() 里 new() 后 add_child 到 Main 下，
##      而且挂了**两次**（早期 GrassQualityEarly + 稍后 GrassQuality）——
##      本文件的 apply 是幂等的，第二次只是空操作，详见下面 _base 的说明。
##
## 四、主要对外接口
##   · apply_current() -> Dictionary        按 autoload 里的当前档位应用
##   · apply_tier(tier: int) -> Dictionary  按指定档位应用（便于测试 / 手动刷新）
##   返回字典的键（日志与自动化测试都依赖这个形状）：
##     tier / tier_name / changed / materials / nodes / sources(可选)
##   其余 `_` 前缀函数均为内部实现，外部不应调用。
##
## 五、已知的坑与注意事项（★ 改代码前先读这段）
##   1) **只改内存**：load() 出来的 .tres 材质是共享实例，set() 只影响本次运行；
##      绝不写回 .tres / .tscn —— 写了就会把某一档"烤"进场景，之后很难换回来。
##   2) **必须留着"原图路径"才能来回切档**：换过之后 tex.resource_path 已变成变体路径，
##      所以 `_base` 专门存原始路径字符串；并且**只存字符串、不持有 Texture 引用**，
##      这样 4K 原图失去最后一个外部引用后能被引用计数自然释放
##      （Godot 没有"强制卸载资源缓存"的 API，只能靠不留引用）。
##   3) **ShaderMaterial 没有 get_shader_parameter_list()**（Godot 4.7 实测）：
##      只能遍历 Object.get_property_list()，挑 `shader_parameter/` 前缀来取参数名。
##   4) **先 `is` 再 `as`**：shader 参数里可能有 float / vec / int 等非对象值，
##      直接 `cur as Texture2D` 会抛 "Invalid cast: can't convert a non-object value"。
##   5) **找不到档位文件就保持原图**：宁可不降档，也绝不出现白模 / 丢贴图。
##   6) 素材现状：diff / nor 有 1k/2k/4k；**alpha / rough 只有 4k**
##      （推测：这两张要靠"贴图分档生成器"补出来）→ 它们实际永远不会被换掉。
##   7) 编辑器里不执行（Engine.is_editor_hint() 直接 return）：避免在编辑器里改到
##      资源引用后被"保存场景"顺手写进 .tscn。
##   8) 只扫描 `get_tree().current_scene` 子树，不含 autoload 与游离节点。
## ============================================================================

extends Node
## 【画质分级 · 草】让草贴图也按档位降分辨率。
##
## 实测现状（为什么需要这段代码）：
##   · `assets/textures/绿草/textures/` 里 **diff / nor 有 1k/2k/4k** ✓，
##     **alpha / rough 只有 4k** ✗（要补的话用【贴图分档生成器】生成 ✓）；
##   · 但**全项目没有任何代码在用这些分档** ✗ → 运行时永远加载 `_4k`
##     （显存列表里 4 张 4K 草 ≈ 53MB ✗，是当前最大的单项 ✗）。
##
## 贴图挂在两处（都覆盖 ✓）：
##   ① 共用材质 `res://scenes/草/_blend_mat_grass_bermuda_01.tres`（20+ 个草场景都引它 ✓）
##   ② SimpleGrassTextured 节点（`addons/simplegrasstextured/grass.gd`）的
##      `texture_albedo / texture_normal / texture_metallic / texture_roughness` ✓
##
## 安全约束：
##   · **只改内存里的材质实例** ✓（`.tres` / `.tscn` 一个字节都不写 ✓）；
##   · 只有在**确实存在对应档位文件**时才替换 ✓ → 找不到就保持原图 ✓（不会白贴图/变糊 ✗）；
##   · 支持跨扩展名（diff 是 .jpg、nor/rough 是 .png ✓）。
# ==================== 常量与状态 ====================

## 共用草材质的固定路径。20+ 个草场景都引用它，所以只换这一个资源即可覆盖大部分草。
## 注意：该文件被移动 / 改名后，下面的 ResourceLoader.exists() 会返回 false 并静默跳过 ——
## 不报错，但草也不会降档（属于"没生效但不崩"的降级行为）。
const GRASS_MAT := "res://scenes/草/_blend_mat_grass_bermuda_01.tres"
## SGT（SimpleGrassTextured）插件脚本路径的**特征子串**。
## 用法是 `脚本资源路径.contains(SGT_HINT)`，所以只写后半段即可；
## 只要 addons 下的相对路径不变，插件版本更替 / 节点改名都仍然能命中。
const SGT_HINT := "simplegrasstextured/grass.gd"
## SGT 节点身上要处理的 4 个贴图属性名（对应 grass.gd 里声明的同名属性）。
## 注意这是**节点属性名**而非 shader 参数名：SGT 分支走的是普通 Object.get/set。
## · texture_metallic / texture_roughness 在本项目素材里只有 4k → 查不到变体，通常保持原样（推测）
const SGT_PROPS := ["texture_albedo", "texture_normal", "texture_metallic", "texture_roughness"]

## 键：资源/节点 id + "/" + 属性名 → 原始贴图路径（换过之后 resource_path 变体，
## 必须记住原始路径才能在档位间来回切 ✓）
##
## 为什么键要用 get_instance_id()：
##   · 材质是共享实例（多个草场景引用同一个 .tres），用实例 id 恰好"同一材质只记一份"；
##   · SGT 节点没有 resource_path，id 是唯一的稳定标识；
##   · 不能把对象本身当字典键 —— 那会让字典持有强引用，贴图/材质反而无法释放 ✗。
##
## 生命周期：本字典只在运行期存在，进程退出即丢（不写文件）。
## 内存影响：每条记录只是一个路径字符串，忽略不计；真正的收益是 4K 贴图能被释放。
var _base: Dictionary = {}


# ==================== 生命周期：挂载与档位订阅 ====================

## Godot 生命周期回调：节点进入场景树时由引擎调用一次（不要手动调用）。
##
## 作用：订阅 Quality 的切档信号，并立刻按当前档位应用一遍草贴图。
## 参数：无。
## 返回值：无。
##
## 副作用：
##   · 可能连接 autoload Quality 的 tier_changed 信号（最多连一次）；
##   · 修改内存中材质实例与 SGT 节点的贴图引用（不写任何文件）；
##   · 打印一行 [画质] 日志。
##
## 调用时机很重要：main.gd 在 _ready() 阶段 add_child 本节点，而 _ready 发生在
## **首帧渲染之前** → 4K 贴图大概率从未被上传到显存（只在加载瞬间解码过）。
##
## 注意事项：
##   · 编辑器里直接返回，见下面第一行说明；
##   · 没有 Quality autoload 时不崩，走 apply_current() 的默认档。
func _ready() -> void:
	# ★ 编辑器里什么都不做：此时改材质引用有可能被"保存场景"顺手写进 .tscn/.tres，
	#   等于把某一档烤进资源里 ✗（运行时自动加载才是唯一该换图的时机）
	if Engine.is_editor_hint():
		return
	# ★ 用 get_node_or_null 而不是 $Quality / QualityManager.instance：
	#   autoload 缺失（单测、纯脚本运行、特殊启动参数）时这里得到 null，仍能继续跑默认档 ✓
	var qm := get_node_or_null("/root/Quality")
	# ★ 三重防护后才 connect：存在 && 有该信号 && 尚未连接。
	#   `not ...is_connected()` 是幂等的关键 —— 节点被重复挂载 / 编辑器热重载 / 多次 _ready 时
	#   不会把同一个回调连两遍，否则一次切档会应用两次 ✗
	if qm != null and qm.has_signal("tier_changed") and not qm.tier_changed.is_connected(_on_tier_changed):
		qm.tier_changed.connect(_on_tier_changed)
	# 立刻应用一次：不必等用户切档，启动时看到的就是当前档位对应的贴图
	apply_current()


## Quality.tier_changed 信号的回调：档位变化后按新档位重新换一遍贴图。
##
## 参数 _t: int —— 新档位枚举（QualityTiers.Tier），0=LOW … 3=ULTRA。
##   这里**刻意不使用**它（下划线前缀 = 有意忽略）：apply_current() 会自己去 autoload 上
##   读最新值，避免"信号参数"与"管理器当前状态"不一致时产生分歧。
## 返回值：无。
## 副作用：修改内存中的贴图引用，并打印 [画质] 日志。
func _on_tier_changed(_t: int) -> void:
	apply_current()


# ==================== 对外入口：按档位应用草贴图 ====================

## 按 autoload `Quality` 上记录的**当前档位**应用草贴图。
##
## 参数：无。
## 返回值: Dictionary —— 直接透传 apply_tier() 的统计字典（结构与含义见 apply_tier）。
## 副作用：同 apply_tier（改内存贴图引用 + 打印日志）。
##
## 注意事项：
##   · autoload 不存在时使用默认档 2（= QualityTiers.Tier.HIGH），
##     与 QualityManager 里 `var tier := QualityTiers.Tier.HIGH` 保持一致；
##   · 任意时刻可重复调用（幂等），例如手动刷新或切档后重放。
func apply_current() -> Dictionary:
	# ★ 默认 2 = Tier.HIGH，与 quality_manager.gd 的默认档对齐。
	#   刻意不写 0(LOW)：取不到档位属于异常路径，不该顺手把画质砍到最低 ✗
	var tier := 2
	var qm := get_node_or_null("/root/Quality")
	if qm != null:
		tier = int(qm.tier)
	return apply_tier(tier)


## 按指定档位应用草贴图 —— 本文件的核心入口，测试也是直接调它。
##
## 参数 tier: int —— 档位枚举 QualityTiers.Tier，正常取值 0..3
##   （0=LOW→1k / 1=MEDIUM→2k / 2=HIGH→4k / 3=ULTRA→4k）。
##   ★ 本函数**不做范围校验**：越界值会被 QualityTiers 内部规则回退到中档（推测）；
##     正常调用链（apply_current / QualityManager.set_tier）都已经 clampi 过。
## 返回值: Dictionary，键固定为
##   { "tier": int,             输入的档位
##     "tier_name": String,     中文档位名（"低"/"中"/"高"/"极高"；非法档位为"未知"）
##     "changed": int,          本次实际替换的贴图槽数量（0 = 什么都没换到）
##     "materials": int,        处理过的材质数量（当前只可能是 0 或 1：仅那张共用材质）
##     "nodes": int,            扫描到的 SGT 节点数量
##     "sources": Array[String] 可选键，仅在前几次替换时出现：被顶掉的**原贴图路径**，
##                              最多 8 条，纯粹给日志诊断用 }
## 副作用：
##   · 修改内存中材质实例与 SGT 节点的贴图引用（不写文件）；
##   · 写 `_base` 缓存（记录原始路径）；
##   · 打印一行 `[画质] 草贴图已按「X」应用：{...}`。
##
## 注意事项：**幂等** —— 第二次调用时 _base 里存的是原图路径、而当前贴图已是变体，
## 比较后判定"无需更换"直接跳过；所以 main.gd 挂两个实例是安全的（只多一条日志）。
func apply_tier(tier: int) -> Dictionary:
	var out := {"tier": tier, "tier_name": QualityTiers.tier_name(tier),
			"changed": 0, "materials": 0, "nodes": 0}
	# ★ 草贴图分散在**两处载体**上，两处都要处理；漏掉任何一处都会留下 4K 占显存 ✗
	#   ① 共用材质资源（下面这一段）  ② SGT 节点自身的属性（再下面那一段）
	# ① 共用材质（Standard / Shader 都能处理 ✓）
	# 路径不存在（资源被移走/改名）时静默跳过：不报错，也不影响 ② 的节点处理
	if ResourceLoader.exists(GRASS_MAT):
		var m := load(GRASS_MAT)
		# 类型兜底：万一该路径被换成了非 Material 资源，跳过而不是硬传下去
		if m is Material:
			_swap_material(m as Material, tier, out)
	# ② SGT 节点自身的四个贴图槽
	# 只扫当前场景树：autoload 与游离节点里的草不在范围内（草实例都挂在场景内）
	for n in _sgt_nodes(get_tree().current_scene):
		out["nodes"] = int(out["nodes"]) + 1
		_swap_props(n, SGT_PROPS, tier, out)
	# ★ 日志是主要排障手段（本项目没有显示画质状态的 UI）：看 changed 就能判断有没有生效
	print("[画质] 草贴图已按「%s」应用：%s" % [out["tier_name"], out])
	return out


# ==================== 内部实现：材质与属性换图 ====================

## 材质：StandardMaterial3D 按属性名换；ShaderMaterial 遍历所有 Texture2D 参数换 ✓
##
## 参数 mat: Material —— 待处理的材质（调用方已判过 is Material）
## 参数 tier: int —— 目标档位，0..3
## 参数 out: Dictionary —— **就地累加**的统计字典（本函数会改它的 materials/changed/sources）
## 返回值：无（结果通过 out 与 _base 体现）。
## 副作用：
##   · out["materials"] 自增 1；
##   · 进而修改材质实例上的贴图引用（内存，不写文件）。
##
## 注意事项：
##   · ShaderMaterial 与 StandardMaterial3D 的**读写接口不同**，必须分支：
##     ShaderMaterial 用 get/set_shader_parameter，StandardMaterial3D 用属性名 get/set；
##   · 只处理贴图，任何非贴图参数（shader 的 float/vec/int 等）一律跳过。
func _swap_material(mat: Material, tier: int, out: Dictionary) -> void:
	out["materials"] = int(out["materials"]) + 1
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var keys: Array = []
		# ★ 不要用 get_shader_parameter_list()：Godot 4.7 的 ShaderMaterial **没有**这个方法 ✗
		#   改用 Object.get_property_list()（一定存在 ✓）里的 `shader_parameter/xxx` 前缀项 ✓
		# 代价说明：get_property_list() 会列出全部属性（含引擎内置），这里只挑前缀匹配的那些；
		# 每次 apply 只跑一遍且材质只有一个，开销可忽略 ✓
		for p in sm.get_property_list():
			var pn := String(p.get("name", ""))
			if pn.begins_with("shader_parameter/"):
				keys.append(pn.substr("shader_parameter/".length()))
		# keys 里可能混着非贴图参数，_swap_props 内部会用 `is Texture2D` 过滤掉 ✓
		_swap_props(sm, keys, tier, out)
	else:
		# StandardMaterial3D 分支：这 4 个是 BaseMaterial3D 的贴图属性名
		# （草材质只用到这几张；其余插槽本项目没用到，所以不列）
		_swap_props(mat, ["albedo_texture", "normal_texture", "roughness_texture", "metallic_texture"], tier, out)


## 通用换图：owner 上的每个 prop，若能找到"本档位变体"就换 ✓（否则保持原图 ✓）
##
## 参数 owner: Object —— 目标对象：ShaderMaterial，或 SGT 节点（Node）；为 null 时静默返回
## 参数 props: Array —— 要检查的属性/参数名列表（允许混入非贴图项，内部按类型过滤）
## 参数 tier: int —— 目标档位，0..3
## 参数 out: Dictionary —— 就地累加的统计字典（changed / sources）
## 返回值：无。
## 副作用：
##   · 写 `_base[实例id + "/" + 属性名] = 原始贴图路径`（供下次切档回溯）；
##   · 命中变体时改写 owner 上的贴图引用（内存）；
##   · out["changed"] 自增；out["sources"] 记录原路径（最多 8 条，仅诊断用）。
##
## 调用时机：apply_tier() 对共用材质与每个 SGT 节点各调用一次。
##
## 注意事项（四条"保持原图"的安全出口）：
##   · owner == null                 → 返回
##   · 属性值不是 Texture2D           → 跳过（可能是 float/vec/int）
##   · 原路径为空（内嵌贴图）         → 跳过
##   · 无变体 / 变体==当前 / load 失败 → 跳过
func _swap_props(owner: Object, props: Array, tier: int, out: Dictionary) -> void:
	if owner == null:
		return
	# 用 instance_id 做缓存键前缀：对象 id 在一次运行内唯一且稳定。
	# （不用 resource_path：SGT 节点根本没有资源路径；也不把对象当键，避免字典持有强引用）
	var key_base := str(owner.get_instance_id())
	# 循环外判一次类型即可，省掉每个属性重复做 `is` 的开销
	var is_shader := owner is ShaderMaterial
	for prop in props:
		var pname := String(prop)
		# 空属性名会让 get("") 直接报错，这里做防御性跳过（get_property_list 理论上不给空名）
		if pname.is_empty():
			continue
		var cur: Variant = null
		if is_shader:
			cur = (owner as ShaderMaterial).get_shader_parameter(pname)
		else:
			cur = owner.get(pname)
		# ★ 必须先用 `is` 判断再取：
		#   shader 参数里可能是 float / vec / int 等**非对象值** ✗，
		#   直接写 `cur as Texture2D` 会报 "Invalid cast: can't convert a non-object value" ✗
		#   （`is` 对任何值都安全 ✓，`as` 不行 ✗）
		if not (cur is Texture2D):
			continue
		var tex := cur as Texture2D
		# 注意这是**当前**路径：若上一轮已经换过，这里就是变体路径，
		# 下面必须用 _base 里记的原图路径覆盖它，否则会越换越低且换不回来 ✗
		var src := String(tex.resource_path)
		var kk := key_base + "/" + pname
		var orig := src
		# 有历史记录 → 以历史原图路径为准（那才是"原始的那张"）
		if _base.has(kk):
			orig = String(_base[kk])
		if orig.is_empty():
			continue                              # 内嵌/无路径贴图：不碰 ✓
		# ★ 先落缓存再换图：即使下面 load 失败，原图路径也已记住，下次调用仍能正确回溯
		_base[kk] = orig
		var want := _variant(orig, tier)
		# want == ""  → 磁盘上没有可用变体
		# want == src → 目标就是当前这张（说明已经换过了）
		# 两种都跳过：这里同时实现了"幂等"与"绝不白贴图"两条约束 ✓
		if want.is_empty() or want == src:
			continue                              # 没有该档位文件 → 保持原图 ✓
		# load() 走资源缓存：同一个变体被多处引用时只会真正加载一次 ✓
		var nt := load(want) as Texture2D
		if nt == null:
			continue
		if is_shader:
			(owner as ShaderMaterial).set_shader_parameter(pname, nt)
		else:
			owner.set(pname, nt)
		out["changed"] = int(out["changed"]) + 1
		# sources 只用于日志诊断（能看到哪些 4K 原图被顶掉了）；
		# 上限 8 条是为了防止日志爆炸，不是功能限制
		var arr: Array = out.get("sources", [])
		if not arr.has(orig) and arr.size() < 8:
			arr.append(orig)
			out["sources"] = arr


# ==================== 内部实现：分档路径解析与节点查找 ====================

## 本档位对应的分档路径：先同扩展名（QualityTiers 规则 ✓），再跨扩展名 ✓
##
## 参数 orig: String —— **原始**贴图路径（必须来自 _base，不能传变体路径，否则会一直往下探）
## 参数 tier: int —— 目标档位，0..3
## 返回值: String —— 可直接 load() 的路径；返回 "" 表示"没有可用变体，请保持原图"。
## 副作用：无（纯查询，只读磁盘上的资源存在性，不加载、不缓存）。
## 调用时机：由 _swap_props 对每个贴图槽调用一次。
##
## 注意事项：本函数**只找路径、不做替换**；找不到时务必返回 "" 而不是 orig ——
##   因为调用方用 `want == src` 判断"已经换过"，返回 orig 会掩盖这个语义并记出假的 changed。
func _variant(orig: String, tier: int) -> String:
	# 第一步：完全按 QualityTiers 的命名规则推路径（"…_diff_4k.jpg" + 1k → "…_diff_1k.jpg"），
	# 并且它自带逐级回退：本档没有就退更低档，全都没有就回退到 orig 本身
	var want := QualityTiers.resolve_existing(orig, tier)
	if want != "" and ResourceLoader.exists(want):
		return want
	# 第二步：上面没命中时做"跨扩展名"补救。
	# ★ 为什么需要：生成端会把数据类贴图统一存成 .png，而分档规则可能推出来 .jpg
	#   → 磁盘上明明有 _1k 文件却找不到 ✗（与 prop_texture_quality.gd 同一个坑）
	# 取 stem 时优先用上一步推出来的路径：它已经把分辨率后缀换成本档位的了；
	# 若 resolve_existing 回退成了原图，则 want == orig，用 orig 的 stem 同样正确 ✓
	var stem := (want if want != "" else orig).get_basename()
	for e in [".png", ".jpg", ".jpeg", ".webp"]:
		var cand := stem + String(e)
		# cand != orig：绝不用"原图自己"当变体（否则会被误判成"需要更换"而记一次假 changed ✗）
		# ResourceLoader.exists()：只认引擎能加载的路径，比 FileAccess 更贴近真实可用性
		if cand != orig and ResourceLoader.exists(cand):
			return cand
	return ""


## 深度优先扫描整棵子树，找出所有"脚本是 SimpleGrassTextured 插件脚本"的节点。
##
## 参数 root: Node —— 扫描起点（apply_tier 传 get_tree().current_scene）
## 返回值: Array[Node] —— 命中节点列表；顺序由栈决定，调用方只做遍历、不依赖顺序
## 副作用：无（纯查询，不修改场景树）。
## 调用时机：apply_tier() 每次执行时调用一次；apply_tier 被调用几次就扫几次。
##
## 注意事项：
##   · 用显式栈而不是递归：场景树可能很深，递归在极端情况下会爆栈；
##   · root 为 null 时返回空数组（current_scene 在某些时机可能为 null）；
##   · 判断依据是**脚本资源路径包含 SGT_HINT**，而不是节点名或引擎类型 ——
##     所以插件升级 / 节点改名都不影响；反过来说，脚本被内嵌或改名后就认不出来（推测）。
func _sgt_nodes(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	var st: Array = [root]
	while not st.is_empty():
		var n = st.pop_back()
		var s: Variant = n.get_script()      # ★ 必须显式标注类型：n.get_script() 无法推断 ✗
		# get_script() 对非脚本节点返回 null → 先判 null 再 as Script，避免无效转换
		if s != null and String((s as Script).resource_path).contains(SGT_HINT):
			out.append(n)
		# 统一在循环里压子节点：pop_back + 压栈即深度优先，能覆盖根到叶的全部节点
		for c in n.get_children():
			st.append(c)
	return out

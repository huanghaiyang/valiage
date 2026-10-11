extends RefCounted
## 【墓园合批】把"一堆小件"按**材质**合并成 1 个 MeshInstance3D（每个材质 1 个 surface），
## 用来降低 draw call。墓园那种"47 个 part、多半共用同一材质"的情形收益最大 ✓。
##
## ★ 默认关闭（`ENABLED = false`）—— 为什么保守：
##   合并是**运行期**结构改动（`.tscn`/`.res` 一个字节都不改 ✓ 关掉即恢复 ✓），
##   但它会改变节点树：`camera_rig` 的"树叶挖洞"遮挡特性、逐件交互/逐件显隐、
##   以及按件设置的 LOD/可见距离都会受影响 ✗。请先小范围试（把 NAME_HINTS 只留一件），
##   确认外观无异常再全开 ✓。
##
## 做法（只用到稳定的引擎 API ✓）：
##   1. 匹配子树 → 收集其中所有 MeshInstance3D（跳过蒙皮/无法读取的 ✓）；
##   2. 按**材质**分组：每组一个 SurfaceTool，`append_from(mesh, surface, 世界变换)`
##      —— 几何**烘焙到世界空间** ✓（所以合并节点用全局单位变换 ✓）；
##   3. 每组 `commit_to_arrays()` → `ArrayMesh.add_surface_from_arrays()` +
##      `surface_set_material()` → 得到"每个材质 1 个 surface"的单一网格 ✓；
##   4. 新建一个 MeshInstance3D 承载它，并把原来的小件 `queue_free()` ✓（真正省显存 ✓）；
##   5. 沿用原来的可见距离/阴影设置 ✓。
##
## 物理不受影响 ✓：墓园那套 Layer 16 的三角网格碰撞体是**兄弟节点**（不是这些小件的子节点），
## 所以合并/删除小件不会动碰撞 ✓。
##
## ==================== 文件头补充说明（后加，优先级更高） ====================
## 【本文件职责】只做一件事：把"同一合批根下、共用材质的一堆小 MeshInstance3D"
##   在**运行期**合并成 1 个 ArrayMesh（每个材质 1 个 surface），从而降低 draw call ✓。
##   它**不**负责：生成/修复碰撞体、烘焙光照、改材质参数、写盘保存场景 ✓（越界的事一律不做 ✗）。
##
## 【所属系统】world（场景/关卡加载后的可选后处理优化步骤 ✓）。
##   与编辑器侧 `prop_batch` 插件配套：**插件负责勾选**节点 meta，**本文件负责执行**合批 ✓，
##   二者之间唯一的契约就是下面这几个 meta 名字 ✓。
##
## 【关键依赖】
##   · autoload：**无** ✓ —— `extends RefCounted` + 全 `static`，纯工具类 ✓；
##     所以**不要**把它挂到节点上，也不要 `PropMerge.new()` ✓，直接静态调用即可 ✓。
##   · 节点 meta 约定（本文件唯一的对外"接口"）：
##       `allow_batch = true` → 该节点被认作合批根（判定见 `_matched` ✓）；
##       `batch = false`      → 该 MeshInstance3D 子件排除、保持独立（见 `_merge_subtree` ✓）。
##   · 其它脚本：`camera_rig` 的"遮挡挖洞"需要能从**遮挡物（碰撞体）**回溯到可视节点，
##     所以 `_merge_subtree` 里把附属节点 `reparent` 到合并节点的逻辑**不能删** ✓
##     （删了就会出现"挖洞失效"✗，表现是镜头被物件挡住时不再透明 ✓）。
##   · 资源路径：**无硬编码路径** ✓（不 preload/preload 任何 .tscn/.res ✓）。
##
## 【主要对外接口】只有 `apply(root) -> Dictionary` 一个公有静态方法 ✓；
##   其余 `_` 前缀方法均为内部实现，外部请勿调用 ✓。
##
## 【已知的坑 / 注意事项】
##   1. 合并是**运行期**节点树改动：逐件交互、逐件显隐、按件 LOD 会失效 ✗。
##      需要保留独立行为的子件，请在检查器里取消该件的「参与合批」（即 `batch = false`）✓。
##   2. 本文件上方历史注释里"碰撞体是**兄弟**节点"的说法**已被实测推翻** ✗ ——
##      以 `_merge_subtree` 中"碰撞体其实是**子**节点、必须 reparent"那段注释为准 ✓。
##   3. 合并节点的变换被强制设为 `Transform3D.IDENTITY`（因为几何已烘焙到世界空间 ✓），
##      合并之后**不要**再手动改它的 transform/缩放 ✗，否则整块网格会与世界坐标错位 ✗。
##   4. 文件头"默认关闭（ENABLED = false）"是**历史**描述 ✗，当前代码里 `ENABLED := true` ✓（以代码为准 ✓）。
##   5. `queue_free()` 是**帧末延迟释放** ✓，所以同一帧内重复对本根调用 `apply`，
##      可能把"还没真正死掉"的小件再收一遍（推测）✗ —— 请保证每个根只调用一次 ✓。

# ==================== 配置常量 ====================
## 合批总开关。
## · true  = 正常执行合批 ✓（当前值 ✓）；
## · false = `apply()` 立刻返回，返回字典只含 "skipped" 键 ✓，场景树一个节点都不动 ✓。
## 默认值为什么现在是 true：收益稳定且"关掉即恢复"（只改运行期结构、不写盘 ✓）；
##   历史上曾为 false 以便先小范围验证外观 ✓（见文件头"已知的坑" ✓）。
## 改动效果：改成 false 是**唯一**的一键回退手段 ✓，不需要改任何场景/资源文件 ✓。
const ENABLED := true
## （`NAME_HINTS` 已删除 ✓ —— 合批范围改由**节点 meta** 决定：
##   `allow_batch = true` 表示允许合批该模型 ✓；子件 `batch = false` 表示排除 ✓）
## 合批门槛：单个合批根**收集到的可合并 MeshInstance3D 件数**少于此值，就整组放弃 ✓。
## 单位：件（是个数 ✓，不是三角形数、也不是 surface 数 ✓）。
## 默认值为什么是 4：合批本身有成本（新建 ArrayMesh + SurfaceTool 逐面烘焙 + 迁移节点 ✓），
##   1~3 件时省下的 draw call 与付出基本相当，属于白忙一场 ✗。
## 调大的效果：更保守，只合"大簇"，小簇保持独立（逐件控制更完整 ✓，但收益变小 ✓）；
## 调小的效果：更激进（调到 1 时几乎全部可合并 ✓），收益最大但逐件交互/显隐能力几乎全丢 ✗。
## 少于这么多件就不值得合并
const MIN_PARTS := 4


# ==================== 对外入口 ====================
## 对整个场景子树做合批扫描：凡带 `allow_batch = true` 的节点，就把它的子树合并一次 ✓。
##
## 参数 root：扫描起点（通常是场景实例根 / 关卡根 ✓）。
##   取值范围：任意 Node（含 null ✓）；传 null 不崩，直接得到 0 组结果 ✓
##   （循环里 `n == null` 会 continue 跳过 ✓）。
##
## 返回值 Dictionary（调用方可以安全忽略 ✓）：
##   · "groups"   ：成功合批的**根节点个数** ✓（不是网格个数、也不是件数 ✓）；
##   · "parts"    ：被并入合并网格的小件总数 ✓（跨所有组合计 ✓）；
##   · "surfaces" ：生成的 surface 总数 ✓（≈ 合并后的 draw call 数 ✓）；
##   · "skipped"  ：**仅当** `ENABLED == false` 时出现 ✓，值为中文说明字符串 ✓。
##   注意：放弃/失败的分支只返回 {"parts":0,"surfaces":0}（没有完整的键 ✓），
##   所以外部读取请一律用 `r.get("键", 默认值)` 兜底，别直接下标 ✗。
##
## 副作用（重要，调用前请知悉）：
##   1. 改**场景树**：新增 `MERGED_xxx` 的 MeshInstance3D，并 `queue_free()` 原小件 ✓；
##   2. 迁移小件的**非可视子节点**（碰撞体/StaticBody3D 等）到合并节点 ✓；
##   3. 会 `print` 一行汇总日志 ✓（无开关 ✗，发布版若要输出干净请自行处理 ✓）；
##   4. **不发信号、不写文件、不改任何 meta / 材质** ✓。
##
## 调用时机：场景实例化、`add_child()` 之后（此时 `global_transform` 才有效 ✓），
##   并且在任何"按件交互 / 按件显隐 / 按件 LOD"逻辑**之前** ✓ —— 合批后小件被删，旧引用会失效 ✗。
## 注意事项：本函数**不检测**是否已合批过，也没有幂等保护 ✗（见文件头"已知的坑"第 5 条 ✓），
##   请保证每个根只调用一次 ✓。
static func apply(root: Node) -> Dictionary:
	if not ENABLED:
		return {"skipped": "disabled（把 prop_merge.gd 顶部的 ENABLED 改成 true 即启用）"}
	# 三个累加器：被合并件数 / 生成 surface 数 / 成功合批的组数，只在本地累加，最后打包返回 ✓
	var total_parts := 0
	var total_surfaces := 0
	var groups := 0
	# 用**显式栈**做手工 DFS，而不是递归：场景树可能很深（嵌套部件模型 ✓），递归有爆栈风险 ✗；
	# pop_back 是后进先出，遍历顺序无关紧要（统计量与顺序无关 ✓）
	var st: Array = [root]
	while not st.is_empty():
		var n = st.pop_back() as Node
		# 栈里可能混入 null（例如运行期已被释放的节点）→ 先跳过，避免下面 has_meta 崩掉 ✗
		if n == null:
			continue
		# 命中即整棵交给 _merge_subtree；处理完必须 continue，别再往里递归 ✗
		if _matched(n):
			var r := _merge_subtree(n)
			total_parts += int(r.get("parts", 0))
			total_surfaces += int(r.get("surfaces", 0))
			# 只有真合并出东西（parts > 0）才算 1 组：否则"尝试过但放弃"的节点会虚增组数 ✗
			if int(r.get("parts", 0)) > 0:
				groups += 1
			continue                 # 整棵已处理，不再往里递归
		for c in n.get_children():
			st.append(c)
	var out := {"groups": groups, "parts": total_parts, "surfaces": total_surfaces}
	# 汇总日志只打一行：方便在输出面板里直接核对"合批前后收益" ✓
	print("PropMerge | 合批：%d 组 ｜ 小件 %d → 网格 %d 个（draw call ≈ %d）" % [groups, total_parts, groups, total_surfaces])
	return out


# ==================== 合批根判定 ====================
## ★ 唯一判定（按需求）：节点上**存在 meta「allow_batch」且为 true** 才合批 ✓
##   默认不勾选 = 没有该 meta = 不合批 ✓（原来按名称关键词匹配的那套已废弃 ✗）
##   勾选入口：选中该模型根节点 → 自己的检查器最上面那个复选框 ✓（prop_batch 插件 ✓）
## 参数 n：待判定的节点（由 `apply` 遍历时给出 ✓，调用方已保证非 null ✓）。
## 返回：true = 该节点是合批根，其整个子树交给 `_merge_subtree` ✓；false = 普通节点，继续向下遍历 ✓。
## 副作用：**无** ✓（只读 meta，不改节点、不发信号 ✓）—— 纯查询，可安全重复调用 ✓。
## 注意事项：判定只看这一个 meta，**与节点名/路径/类型无关** ✓；
##   所以给什么节点勾选，就以它为单位合批 ✓（勾在过高层级会把整片场景并成一块 ✗，请谨慎勾选 ✓）。
static func _matched(n: Node) -> bool:
	return n.has_meta("allow_batch") and bool(n.get_meta("allow_batch"))


# ==================== 合批核心 ====================
## 收集并合并 `holder` 子树里的全部可合并网格（本文件的主体算法 ✓）。
##
## 参数 holder：已经过 `_matched` 判定为"允许合批"的根节点 ✓（本函数**不**重复校验 meta ✓）。
##   必须已挂进场景树 ✓（否则 `get_parent()` 为 null → 直接返回零值放弃 ✓）。
## 返回值 Dictionary：
##   · 成功：{"parts": 被并入件数, "surfaces": 生成的 surface 数, "moved": 迁移的附属节点数} ✓；
##   · 放弃：{"parts": 0, "surfaces": 0}（件数不足 / 无可读网格 / 没有父节点 ✓）。
##     注意：放弃分支**不含** "moved" 键 ✗ → 读取一律用 `r.get("moved", 0)` ✓。
##
## 副作用：
##   1. 向 holder 的父节点新增一个 `MERGED_xxx` 的 MeshInstance3D ✓（并强制为全局单位变换 ✓）；
##   2. 把小件的**非可视子节点**（碰撞体/StaticBody3D/标记节点…）`reparent` 到合并节点 ✓；
##   3. `queue_free()` 掉全部被合并的小件 ✓（帧末真正释放 ✓）；
##   4. 打印一行本组明细日志 ✓。
## 调用时机：仅由 `apply` 调用 ✓；依赖小件当前 `global_transform` 已生效（几何要按世界坐标烘焙 ✓）。
## 注意事项：几何烘焙到世界空间后，**千万别**再移动/缩放合并节点 ✗（会产生整体偏移 ✗）。
static func _merge_subtree(holder: Node) -> Dictionary:
	var parts: Array = []
	# 同样是显式栈 DFS；注意这里收的是**所有后代**（不只直接子节点 ✓），
	# 所以"模型 → 部件 → 子部件"这种多层嵌套也能被同一个根一次收齐合并 ✓
	var stack: Array = [holder]
	while not stack.is_empty():
		var n = stack.pop_back()
		# 三个条件同时满足才收：① 本身是 MeshInstance3D；② 网格可烘焙（见 _mergeable ✓）；
		# ③ meta「batch」没被显式关掉 ✓（`get_meta("batch", true)` 缺省即 true ✓）
		if n is MeshInstance3D and _mergeable(n as MeshInstance3D) and bool(n.get_meta("batch", true)):
			parts.append(n)      # ★ batch == false 的子件保持独立、不并入合并 ✓（默认 true ✓）
		for c in n.get_children():
			stack.append(c)
	# 件数不够 MIN_PARTS 直接放弃：**不新建任何节点**就返回，所以这条路径零副作用 ✓
	if parts.size() < MIN_PARTS:
		return {"parts": 0, "surfaces": 0}

	# ---- 按材质分组，几何烘焙到世界空间 ----
	var by_mat := {}                 # 材质实例id -> {"mat": Material, "pairs": [[mesh, surface], …]}
	var order: Array = []            # 保持稳定顺序
	# ref = 收集到的第一个小件，**只作为"沿用可见距离/阴影设置"的样板** ✓，不参与几何计算 ✓
	var ref: MeshInstance3D = parts[0]
	for p in parts:
		var mi := p as MeshInstance3D
		var m: Mesh = mi.mesh
		if m == null:
			continue
		var xf: Transform3D = mi.global_transform
		for s in range(m.get_surface_count()):
			# 取"该 surface 实际生效的材质"：优先逐面 override ✓，没有再回落到网格自带材质 ✓
			var mat: Material = mi.get_surface_override_material(s)
			if mat == null:
				mat = m.surface_get_material(s)
			# 分组键用**材质资源实例 id**（不是材质参数、不是名字 ✓）：只有真正同一个材质实例
			# 才会并进同一个 surface ✓；mat 为 null 时统一用 0 表示"无材质"这一组 ✓
			var key := mat.get_instance_id() if mat != null else 0
			if not by_mat.has(key):
				by_mat[key] = {"mat": mat, "pairs": []}
				order.append(key)
			# 存 [网格, surface索引, 世界变换] 三元组：把"世界变换"一起存下来，
			# 后面 append_from 才能一次性把几何摆到正确的世界位置 ✓
			(by_mat[key]["pairs"] as Array).append([m, s, xf])

	var merged := ArrayMesh.new()
	var made := 0
	for key in order:
		var g: Dictionary = by_mat[key]
		var mat: Material = g["mat"]
		# 每个材质组用**独立**的 SurfaceTool：一个材质 → 一个 surface，这正是降 draw call 的关键 ✓
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		if mat != null:
			st.set_material(mat)
		for pr in g["pairs"]:
			# 第 3 个参数是**世界变换** → 顶点直接烘焙进世界空间 ✓
			# （这也是后面承载节点必须保持"全局单位变换"的原因 ✓）
			st.append_from(pr[0] as Mesh, int(pr[1]), pr[2] as Transform3D)
		var arrays := st.commit_to_arrays()
		# 空数组说明这组一个顶点都没提交出来（例如网格全被剔除）→ 跳过，
		# 不要在最终网格里留下"空 surface"占位 ✗
		if arrays.is_empty():
			continue
		merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if mat != null:
			merged.surface_set_material(merged.get_surface_count() - 1, mat)
		made += 1
	# 一个 surface 都没做出来 → 视为失败并返回零值；此时**还没碰过场景树**，零副作用 ✓
	if made == 0:
		return {"parts": 0, "surfaces": 0}

	# ---- 承载节点：几何已在世界空间 → 全局单位变换 ✓ ----
	var node := MeshInstance3D.new()
	node.name = "MERGED_" + String(holder.name).substr(0, 20)
	node.mesh = merged
	# ★ 挖洞（camera_rig 的遮挡透视）改由**逐子件开关**控制 ✓：
	#   这里**不再**统一加入 occlusion_ignore ✗ —— 你在检查器里把底座/地面片的
	#   「参与合批」取消勾选 ✓，它们就保持独立（照常挖洞、但不会被合并网格带穿 ✓）
	node.cast_shadow = ref.cast_shadow
	node.visibility_range_end = ref.visibility_range_end
	node.visibility_range_end_margin = ref.visibility_range_end_margin
	node.visibility_range_fade_mode = ref.visibility_range_fade_mode
	# 合并节点挂在 holder 的**父节点**下（与 holder 同级 ✓），不是挂进 holder 内部：
	# 这样这块网格不依赖被删掉的小件，也不会因为将来动 holder 而被顺手清掉 ✓
	var parent := holder.get_parent()
	if parent == null:
		return {"parts": 0, "surfaces": 0}
	parent.add_child(node)
	# 必须在 `add_child` **之后**再设 global_transform：Godot 需要先知道父链，
	# 才能反算出正确的 local transform ✓（反过来设会被 add_child 覆盖 ✗）
	node.global_transform = Transform3D.IDENTITY
	# ★ 关键：释放小件之前，先把它们的"非可视子节点"**迁移**到合并节点上 ✓
	#   实测：碰撞体（StaticBody3D / CollisionShape3D）是 MeshInstance3D 的**子节点**
	#   （不是兄弟 ✗，我最初判断错了）→ 直接 queue_free 会把碰撞一起删掉 ✗
	#   （表现就是"合批后碰撞失效"）；碰撞没了，camera_rig 也找不到遮挡物 → 挖洞失效 ✓
	#   `reparent(node, true)` 会**保留全局变换** ✓ → 世界位置/尺寸不变 ✓
	#   同时：碰撞体的父节点变成合并后的 MeshInstance3D → camera_rig 解析"遮挡物对应的可视节点"时
	#   会找到这块合并网格 ✓（这正是恢复挖洞所需的关系 ✓）
	# 迁移循环：可视子网格跳过（已经并进合并网格 ✓），其余附属节点整棵迁走 ✓。
	# 顺序上必须在 queue_free 小件**之前**做完，否则附属节点会跟着一起被删 ✗
	var moved := 0
	for p in parts:
		for c in (p as Node).get_children():
			if c is MeshInstance3D:
				continue                      # 可视子网格已并入合并网格 ✓ 无需迁移
			c.reparent(node, true)
			moved += 1
	# 每组一行明细日志：排查"某件模型为什么没被合并"时，主要靠这些数字 ✓
	print("PropMerge |   %s：小件 %d 件 → 网格 %d surface ｜ 迁移碰撞/附属节点 %d 个 ✓" % [String(holder.name), parts.size(), made, moved])
	# 到这里才真正释放小件：附属节点已迁走（碰撞保住 ✓），此时释放才能回收显存/draw call ✓
	for p in parts:
		(p as Node).queue_free()      # 这时才释放小件（真省显存/draw call ✓，碰撞已保住 ✓）
	return {"parts": parts.size(), "surfaces": made, "moved": moved}


# ==================== 网格可烘焙判定 ====================
## 可合并判定：有网格、无蒙皮（蒙皮网格不能这样烘焙 ✗）
## 参数 mi：待判定的 MeshInstance3D（调用方已保证非 null ✓）。
## 返回：true = 这个网格可以被 SurfaceTool 烘焙进合并网格 ✓；false = 必须保持独立 ✓。
## 副作用：**无** ✓（纯查询，不读 meta、不改节点 ✓）。
## 注意事项：这里**不检查** meta「batch」✗ —— 那一步在 `_merge_subtree` 的收集循环里做 ✓，
##   所以单独调用本函数无法判断"某件最终会不会被合并" ✓。
static func _mergeable(mi: MeshInstance3D) -> bool:
	# 没有网格、或网格一个 surface 都没有：没有几何可烘焙 → 直接排除 ✓
	# （不排除的话，后面按 surface 循环会空转，只是白花时间 ✓）
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return false
	# 蒙皮网格的顶点由骨架驱动，append_from 只能取到"绑定姿势"的静态几何 ✗ →
	# 合并后动画会僵住/错位，因此必须排除、让它保持独立 ✓
	if mi.skin != null:
		return false                  # 蒙皮网格：跳过 ✓
	return true

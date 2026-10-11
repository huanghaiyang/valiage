extends RefCounted
## 【公共模块】把材质"叠在物体自己身上"（`material_overlay`）——**物体表面绘制**的公共实现。
##
## 谁在用：
##   · 【物体探测】`detect_pulse.gd`：描边 + 表面扫描带（扫描带挂在描边材质的 `next_pass`）
##   · 【火焰推进】`spell_targeting.gd`：扇形选点器把扇面画到物体表面
##
## 为什么要抽出来（用户要求）：两边原来各写一份"找到物体 -> 挂 material_overlay ->
## 离开/结束还原"，重复实现迟早会不一致（比如一边记得还原透明度、另一边忘了）。
##
## 职责边界：
##   · 本模块只管**挂在哪些网格上 / 怎么还原**（保存并恢复 `material_overlay`、
##     `transparency`、`layers`）；**画什么**完全由调用方给的材质决定。
##   · 每次挂的材质可以各不相同（物体探测是**每个物体一份**，因为它按物体推进揭示半径；
##    扇形选点器是**全场共用一份**，因为形状参数是全局的）。
##   · 用 `next_pass` 串多遍（描边 + 扫描带）也是调用方的事，本模块只是把那份材质挂上去。
##
## ---------------------------------------------------------------- 类型与依赖
##
## · 类型：`extends RefCounted`。**不是 Node** —— 不参与场景树、没有 _ready / _process /
##   _exit_tree。因此它**不会自动清理自己**：清账只能靠调用方显式 detach / clear。
## · 无 `class_name`，调用方一律按路径 preload：
##     `const SurfaceOverlay := preload("res://scripts/spells/surface_overlay.gd")`
##   需要账本的方法用 `SurfaceOverlay.new()` 得到的实例调用；带 `static` 的工具直接类调用。
## · **不依赖任何 autoload**（不碰 Mana / SpellCaster / Weather），**不发信号**，
##   不读资源文件、不写文件、不读输入。用到的只有 Godot 内置类型：
##   MeshInstance3D / Material / World3D / PhysicsShapeQueryParameters3D /
##   SphereShape3D / AABB / Transform3D。
##   ★ 它连"自己属于术法系统"都不知道：把两个调用方的引用删掉，本文件照样编译。
##
## ---------------------------------------------------------------- 对外接口一览
##
## 实例方法（每个实例自带一份 entries 账本，互不干扰）：
##   · count() -> int                       当前账本里有几个网格
##   · has(id) -> bool                      该网格是否已挂
##   · ids() -> Array                       已挂网格的实例 id 列表（每次返回新数组）
##   · get_entry(id) -> Dictionary          取一条记录；不存在时返回**空字典**（不报错）
##   · attach(mi, mat, ghost = 0.0)         挂材质；重复挂只更新材质与透明度
##   · mark_layers(mi, mask)                只记状态 + 置可见层，**不挂材质**
##   · detach(id)                           还原单个网格，并从账本移除
##   · sync(want)                           整批同步：不在 want 里的一律还原
##   · clear()                              把账本里的全部还原（清掉场景残留）
## 静态工具（不需要实例、也不需要 new）：
##   · visible_meshes(node) -> Array        子树里所有 visible 的 MeshInstance3D
##   · resolve_visual(node, max_up = 3)     碰撞体节点 -> 真正持网格的节点（**向上找**）
##   · visual_aabb(visual) -> AABB          一组网格的世界包围盒并集
##   · collect_meshes(...) -> Array         球查询 + 解析 + 包围盒 + 过滤的一条龙
##
## ---------------------------------------------------------------- 使用纪律与已知坑
##
## · ★ **必须成对**：attach / mark_layers 每挂一项，就要有对应的 detach / clear 还原。
##   调用方在"术法结束 / 切换模式 / 节点 _exit_tree()"三处都要收尾；
##   漏一处场景里就会留下**永久描边 / 永久半透明 / 永久可见层**（本模块没有自动兜底）。
## · entries 的键是 `MeshInstance3D.get_instance_id()`。Godot 释放节点后 id 不会复用，
##   所以 detach 先从账本 erase、再判节点有效性 —— 节点已成野指针也不会留下脏条目。
## · 同一份材质可以挂到任意多个网格上（扇形选点器就是全场共用一份）；
##   本模块**不复制材质、不改 shader 参数**，材质怎么变属于调用方的职责。
## · 本模块**不含任何计时或限流**：sync 的成本完全取决于 want 的大小与 attach 次数，
##   调用密集的场合由调用方自己限流（参考 spell_targeting.gd 的 surface_refresh_interval）。
## · 还原写回的是"挂载当时"的快照。若某个网格在挂载期间被**别的系统**改过
##   layers / transparency，detach 会把那笔改动一起抹掉 —— 本模块只保证回到
##   "自己挂载之前"的状态，不负责合并他人对同一网格的并发修改
##   （推测：目前项目里没有别的系统去改这两项）。
##

# ==================== 状态：已挂载条目表 ====================
## 网格实例 id -> {mi, prev_overlay, prev_transparency, prev_layers}
## · 键：网格的 `get_instance_id()`（int，不是 NodePath）；值：一条还原所需的快照。
## · 值里的字段：
##     mi                —— 那个 MeshInstance3D（弱引用：节点可能已被释放，用前必查有效性）；
##     prev_overlay      —— 挂载前的 `material_overlay`（可能是 null）；
##     prev_transparency —— 挂载前的 `transparency`（0~1；0 = 完全不透明）；
##     prev_layers       —— 挂载前的 `layers` 可见层位掩码（int）。
## · 该字典是**公开**的：spell_targeting.gd 会直接读它来刷新调试用的 `_overlaid`（只读）。
##   外部**不要**手工往里塞/删条目 —— 手工塞的条目缺快照，detach 会把网格还原成默认值。
var entries: Dictionary = {}


# ==================== 查询接口（只读，不改账本、不碰场景） ====================
## 当前账本里挂了几个网格。
## 参数：无。返回值：`entries.size()`（int，>= 0）。
## 副作用：无。
## 注意：这是"本实例挂上过、还没还原的网格数"，**不是**"场景里有几个物体" ——
##   同一个物体常有多个可见网格（导入模型的 tripo_part_N 那种），会被逐个计数。
## 调用时机：调试 / 自检里核对"是不是漏还原了"（一次术法打完应该回到 0）。
func count() -> int:
	return entries.size()


## 某个网格是否已经被本实例挂上（挂材质或只置可见层都算）。
## 参数：id —— 网格的 `get_instance_id()`（int），**不是** NodePath / 节点引用。
## 返回值：bool。节点已被释放时，用它的旧 id 查询也照常返回（账本只看 id，不碰节点）。
## 副作用：无。
## 调用时机：批量操作前先跳过已挂的项，省一次重复赋值的开销。
func has(id: int) -> bool:
	return entries.has(id)


## 当前已挂网格的实例 id 列表。
## 参数：无。返回值：Array（元素是 int）。
## ★ 返回的是 `Dictionary.keys()` 产出的**新数组**，可以安全地"边遍历边 detach"；
##   顺序**不保证**稳定（哈希序），不要依赖它做确定性排列。
## 副作用：无（不动账本本体）。
## 调用时机：需要遍历所有已挂项逐个还原时（clear() 就是这么干的）。
func ids() -> Array:
	return entries.keys()


## 取一条账本记录（给只读场合用）。
## 参数：id —— 网格实例 id。
## 返回值：Dictionary，字段见 `entries` 上方的注释；**不存在时返回空字典 `{}`**，
##   而不是 null —— 所以调用方可以安全地接着 `.get(...)`，不会因为找不到就崩。
## ★ 返回的是账本里**同一个 Dictionary 引用**（不是副本）：改它等于改账本。
##   只读用途请勿改；真要改，请走 detach / attach 的正规入口。
## 副作用：无。
func get_entry(id: int) -> Dictionary:
	return entries.get(id, {})


# ==================== 挂载 / 还原（账本在此被改写） ====================
## 挂上材质（第一次挂时记下原 overlay / 透明度 / 可见层，供还原）
##
## 参数：
##   · mi —— 目标网格。**允许传 null / 已释放的节点**：直接静默返回，不报错。
##     调用方常常是在一大串候选里筛出来的，某个节点这一帧刚被释放是常态
##     （物体碎裂、区块卸载），所以这里刻意不 push_error、不 assert。
##   · mat —— 要叠上去的材质（多为 ShaderMaterial）。传 null 同样被静默忽略。
##     ★ 本模块**不接管材质所有权**：创建、shader 参数刷新、释放都归调用方。
##   · ghost —— 期望写入的 `transparency`（0~1；0 = 完全不透明）。默认 0.0。
##     语义是"**大于 0 才动手**"：ghost 传 0（或不传）时**完全不碰**网格原有的
##     transparency —— 于是"我不需要半透明"的调用方不会把别人的透明设置抹成 0。
##     超出 [0,1] 的值会被 clampf 夹住（透明度大于 1 在 Godot 里没有意义）。
##
## 副作用（首次挂）：往 entries 记一条快照（prev_overlay / prev_transparency /
##   prev_layers），把 `material_overlay` 指向 mat；ghost > 0 时再改写 transparency。
## 副作用（重复挂）：**不新增、也不覆盖快照**，只把 material_overlay 换成新材质；
##   若这次 ghost > 0 则顺带更新 transparency（物体探测多圈会换材质，见调用方注释）。
##   ★ 因此快照永远代表"**挂载之前**"的真实状态，重复挂不会把中间态当成原值。
## 返回值：无。
## 调用时机：调用方自己决定；本模块不知道、也不关心现在是不是在施法。
## 注意：**不修改 `layers`**（那是 mark_layers 的活），也不动网格的自有材质
##   （只写 material_overlay 这一个槽），所以物体外观保持原样，只是多了一层叠加。
## 注意：**不会自动还原** —— 谁挂的谁负责 detach / clear。
func attach(mi: MeshInstance3D, mat: Material, ghost := 0.0) -> void:
	if mi == null or not is_instance_valid(mi) or mat == null:
		# 静默返回：候选里混进刚被释放的节点是常态，不该让整批处理被打断
		return
	# 用实例 id 当键：节点引用会在释放后变野指针，id 稳定、轻量、可安全比较
	var id := mi.get_instance_id()
	if entries.has(id):
		# 已经挂了：只更新材质与透明度（物体探测多圈会换材质）
		# 只刷新引用与材质，**不覆盖原快照** —— 否则"挂之前的状态"会被中间态污染
		entries[id]["mi"] = mi
		mi.material_overlay = mat
		if ghost > 0.0:
			# ghost <= 0 时**不碰** transparency：0 是"保持原样"的哨兵，不是"设为全不透明"
			mi.transparency = clampf(ghost, 0.0, 1.0)
		return
	# 首次挂载：**先整体存快照、再改网格**；顺序反了就会把被自己改过的值当原值存下来
	entries[id] = {
		"mi": mi,
		"prev_overlay": mi.material_overlay,
		"prev_transparency": mi.transparency,
		"prev_layers": mi.layers,
	}
	# 只写 material_overlay，不动 material_override / 网格自有材质
	mi.material_overlay = mat
	if ghost > 0.0:
		# 同上：只有明确要求半透明时才改写，避免把别人设好的透明度重置为 0
		mi.transparency = clampf(ghost, 0.0, 1.0)


## 只记状态 + 置可见层（屏幕空间描边那种"不挂材质、只把网格丢进遮罩层"的用法）
##
## 参数：
##   · mi —— 目标网格；null / 已释放时静默返回。
##   · mask —— 要**叠加**上去的可见层位掩码（int 位标志，如 detect_pulse 的 MASK_LAYER）。
##     传 0 等于只建快照、不改任何位（留个还原锚点，通常没意义）。
##     取值是 `VisualInstance3D.layers` 的位域（Godot 里共 20 位可用）。
## 副作用：把网格加进账本（若未在册，先存 prev_layers 等快照），然后 `mi.layers |= mask`；
##   **完全不动 material_overlay / transparency**。
## 返回值：无。
## 调用时机：屏幕空间描边模式（screen_outline = true）下，把被探测到的网格临时
##   挂进遮罩层，让"只开这一位的相机"把它渲进 SubViewport 当 Custom Depth 用。
## 注意：和 attach 一样，属"挂载"操作，**同样必须**由调用方 detach / clear 还原；
##   而且本模块不管 mask 是不是别人也要用（见下面 |= 的注释）。
func mark_layers(mi: MeshInstance3D, mask: int) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	var id := mi.get_instance_id()
	if not entries.has(id):
		# 只在"还没记过"时才存快照：重复调用不能把已经被自己改过的层当成原值
		entries[id] = {
			"mi": mi,
			"prev_overlay": mi.material_overlay,
			"prev_transparency": mi.transparency,
			"prev_layers": mi.layers,
		}
	# 用 |= 叠加而不是 = 覆盖：别的系统也可能占着某些层，直接赋值会把人家的层踢掉
	mi.layers |= mask


## 还原一个网格（overlay / 透明度 / 可见层 全部回到挂之前）
##
## 参数：id —— 网格实例 id（`entries` 的键）。
## 返回值：无。**对不存在的 id 是安全的空操作**（什么都没挂过时也能放心调）。
## 副作用：从 entries 删掉该条目；节点仍有效时把 `material_overlay` /
##   `transparency` / `layers` 三项一起写回快照值。
## 调用时机：单个物体离开范围、或单个覆盖到期时（sync 内部就是靠它做差集还原）。
## 注意：节点已被释放时只清账本、不碰节点（也没法碰）—— 不会有报错。
## 注意：erase 在有效性检查**之前**，见下面注释，这个顺序是有意的。
func detach(id: int) -> void:
	var e: Dictionary = entries.get(id, {})
	# ★ 先取出、立刻 erase：即使下面发现节点已释放，账本也已经清干净，
	#   不会留下"永远还原不掉、还占着 id"的脏条目
	entries.erase(id)
	if e.is_empty():
		return
	var mi := e.get("mi") as MeshInstance3D
	if mi == null or not is_instance_valid(mi):
		return
	# 三项一起回写：只还原 overlay 而漏掉透明度/可见层，会留下"半透明"或"挂在遮罩层"的残留
	mi.material_overlay = e.get("prev_overlay")
	mi.transparency = float(e.get("prev_transparency", 0.0))
	# 兼容老条目：手工塞进来或旧版本存下的记录可能没有 prev_layers 字段
	var pl = e.get("prev_layers")
	if pl != null:
		# 直接赋值（而不是清掉自己加的那一位）：快照就是当时的完整掩码，整份写回才准确
		mi.layers = int(pl)


# ==================== 批量同步与清场 ====================
## 同步"当前该挂的集合"：want = { 实例 id: {mi, mat, ghost(可选)} }，
## 不在 want 里的**全部还原**（物体离开范围时用）。
##
## 参数：want —— Dictionary，键 = 网格实例 id，值 = Dictionary{mi, mat, ghost}。
##   · mi（MeshInstance3D，必填，可为 null —— 会被 attach 静默忽略）
##   · mat（Material，必填）
##   · ghost（float，可选，缺省 0.0 = 不改透明度，语义同 attach）
##   键**不必**与值里的 `mi.get_instance_id()` 一致（本模块只拿键做差集比较，
##   内部实际记录用的是 attach 自己取的 id）。★ 但真不一致时差集会对不上：
##   刚挂上的条目会被判成"不在 want 里"而立刻 detach —— 所以保持一致最省心。
## 返回值：无。
## 副作用：① 对 want 里每一项调 attach（已挂的会走"只换材质"分支，不重建快照）；
##   ② 对账本里**不在 want 中**的每一项调 detach 还原。
## 调用时机：周期性刷新"哪些物体在范围内"（spell_targeting 每 surface_refresh_interval
##   重建一次 want 再整批 sync，比逐个判断增删更不容易漏还原）。
## 注意：这是**幂等**的 —— 用同一份 want 连调多次不会累积副作用（快照仍是首次那笔）。
## 注意：先挂后摘的顺序是有意的：同一个 id 既在 want 又在账本里时只更新，不会被先摘掉。
## 注意：传 `{}`（空字典）等价于 clear()，只是语义上更"我算出来该挂的集合是空的"。
func sync(want: Dictionary) -> void:
	# 先挂/更新：全部交给 attach 判定"首次"还是"重复挂"，这里不做状态判断
	for id in want.keys():
		var w: Dictionary = want[id]
		attach(w.get("mi") as MeshInstance3D, w.get("mat") as Material, float(w.get("ghost", 0.0)))
	# ★ 遍历副本是必须的：循环体里的 detach 会改 entries，
	#   直接遍历 keys() 的视图会在遍历中改动而报错
	for id in entries.keys().duplicate():
		if not want.has(id):
			detach(id)


## 全部还原（术法结束 / 节点退出时必须调，否则场景里会留下只剩线稿的物体）
##
## 参数：无。返回值：无。
## 副作用：对账本里每个 id 调 detach —— 于是所有被挂过的网格的
##   material_overlay / transparency / layers 都回到各自挂载之前的值，账本清空。
## 调用时机：① 术法结束、② 切换渲染模式（圆盘 <-> 扇形）、③ 宿主节点 _exit_tree()。
##   ★ 尤其别忘了 ③：宿主被释放后本对象可能还被别处引用着，但它再也不会来收尾，
##     场景里就会永远留着那层叠加材质。
## 注意：**不释放材质**（材质所有权在调用方），也不清空调用方自己的记录。
## 注意：可以重复调用（第二次是空转）。
func clear() -> void:
	# 同 sync：遍历副本，因为 detach 会把 key 从 entries 里删掉
	for id in entries.keys().duplicate():
		detach(id)


# ==================== 静态工具：节点遍历与碰撞体->网格解析 ====================
# ---------------------------------------------------------------- 静态工具（两边共用）

## 节点下所有可见网格（含自身）
##
## 参数：node —— 任意节点；传 null 返回空数组（不报错）。**含 node 自身**。
## 返回值：Array，元素是 MeshInstance3D（就是原节点引用，不是副本），
##   顺序是深度优先（子节点反向弹出）——**与场景树里的兄弟顺序不一致**，别拿它做配对；
##   只收 `visible == true` 的网格。
## 副作用：无（只读场景树）。
## 调用时机：要给"一个物体"挂叠加材质之前，先问出它身上有哪些网格。
## 注意：**每次调用都完整遍历子树并新建数组**，是 O(子树大小) 的分配操作 ——
##   在循环里反复调同一个节点很浪费；调用方应先取一次存起来（resolve_visual
##   内部对候选节点也各调一次，所以别把它塞进每帧的深层循环里）。
## 注意：只判 `visible`，不判 `layers` / 是否在相机外 —— 被隐藏的网格挂上材质也画不出来，
##   所以刻意跳过它们，免得白占一条还原账目。
static func visible_meshes(node: Node) -> Array:
	var out: Array = []
	if node == null:
		return out
	# 用显式栈做迭代遍历：场景子树可能很深，递归有爆栈与调用开销的风险
	var stack: Array = [node]
	while not stack.is_empty():
		# pop_back + 顺序压入子节点 = 深度优先；这里只需要"找全"，顺序无关紧要
		var n := stack.pop_back() as Node
		if n == null:
			continue
		if n is MeshInstance3D and (n as MeshInstance3D).visible:
			out.append(n)
		for c in n.get_children():
			# 子节点也入栈：配合前面的"自身也判一次"，节点自己就是网格的情况同样覆盖
			stack.append(c)
	return out


## 碰撞体 -> 真正持有网格的节点。
## ★ 本项目的碰撞体与网格常常是**兄弟**（不是父子）：必须**向上找**（最多 3 层）。
##   只查"碰撞体自己的子节点"的话，每个物体都会判成"没有可见网格"（探测波实测踩过：
##   波纹在跑却什么都描不出来）。
##
## 参数：
##   · node —— 从物理查询拿到的碰撞体节点（StaticBody3D / 任何 Node 都能接）。
##   · max_up —— 最多向上找几层，默认 3。调大能找到更远的可视父节点，但
##     **风险是找到整片容器的父级**（把一大堆物体当成"同一个可视节点"），
##     那样按 visual 分组/去重就会失效；调小则会漏掉层级较深（导入模型常见）的物体。
##     调用方可按需放宽：spell_targeting 因为导入模型的网格挂得远，传的是 6。
## 返回值：找到的节点（可能是 node 自身、某个祖先），找不到返回 **null**。
## 副作用：无（只读场景树）。
## 调用时机：每次球查询命中之后、挂材质之前（collect_meshes 内部已经这么做了）。
## 注意：判定标准是"该节点的子树里有 visible 的 MeshInstance3D"，
##   所以它返回的不一定是 MeshInstance3D —— 可能是挂着网格的容器节点。
static func resolve_visual(node: Node, max_up := 3) -> Node:
	if node == null:
		return null
	# 先看自身子树：visible_meshes 已含自身，所以"碰撞体自己就是/就带着网格"在这里就命中
	if not visible_meshes(node).is_empty():
		return node
	var cur := node.get_parent()
	var depth := 0
	# 上限 3 层：再往上就很可能撞到世界容器/场景根，把一整片物体当成一个可视节点
	while cur != null and depth < max_up:
		if not visible_meshes(cur).is_empty():
			return cur
		cur = cur.get_parent()
		depth += 1
	return null


# ==================== 静态工具：包围盒与球查询拾取 ====================
## 一组网格的世界包围盒并集
##
## 参数：visual —— 任意节点（一般传 resolve_visual 的结果，但传别的节点也能工作）。
## 返回值：AABB，世界空间、轴对齐（Godot 在 `Transform3D * AABB` 时会重新展开，
##   所以旋转过的网格拿到的是"能包住它的世界轴对齐盒"，比真实体积略大）。
##   若该节点下没有可见网格、或所有网格的 `mesh` 都是 null，返回**默认的 `AABB()`**
##   （position (0,0,0)、size (0,0,0)）—— 调用方必须自己用 size 判空，别当成有效盒。
## 副作用：无（只读）。
## 调用时机：球查询命中之后，需要把"整组网格"当一个整体做范围判断/屏幕剔除时。
## 注意：只用 `global_transform`（已含缩放与旋转）+ 网格原始 AABB，
##   **不含骨骼动画的姿态**（蒙皮后的真实外形可能超出这个盒，推测：本项目不需要那么精确）；
##   也不覆盖 MultiMeshInstance3D、不覆盖 Particle 类节点。
static func visual_aabb(visual: Node) -> AABB:
	var box := AABB()
	# ★ first 标志不能省：AABB() 表示"原点处的零盒"，直接拿它去 merge
	#   会把世界原点 (0,0,0) 也拉进包围盒，物体在远处时盒会被撑得离谱
	var first := true
	for mi in visible_meshes(visual):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var b: AABB = m.global_transform * m.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## 球查询找到"范围内可能要用到的物体"。
## 返回 [{node: 碰撞体节点, visual: 可视节点, box: 世界包围盒}]；
## filter(collider, visual, box) 返回 false 的会被丢掉（地形过滤、扇区过滤等各法术自己加）。
##
## 参数（顺序即签名顺序）：
##   · world —— 目标 World3D（一般是 `get_world_3d()`）。null 直接返回空数组。
##   · center —— 球心（世界坐标）。调用方通常给施法点/角色脚下；
##     内部会把球心**抬高 0.5 m**（见下），所以"脚下"语义不必自己加偏移。
##   · radius —— 半径（米）。<= 0 直接返回空数组；内部另有 0.05 的下限兜底。
##   · mask —— 碰撞层掩码（对应 `collision_mask`）。**0 = 不与任何层相交**，
##     一次都命中不了 —— 掩码没配好时最典型的现象就是"波纹在跑却什么都描不出来"。
##   · exclude —— 要在查询里排除的 RID 数组（`Array[RID]`），典型内容是玩家自己。
##     默认空数组。
##   · filter —— 可选的 `Callable(collider: Node, visual: Node, box: AABB) -> bool`，
##     返回 false 的命中被丢弃（地形/扇区/名字过滤各法术自己加）。默认空 Callable = 全收。
##   · max_results —— 传给 `intersect_shape()` 的命中上限，默认 64。
##     ★ 它截断的是**物理命中数**，不是"过滤后剩下的数量"；密集场景里地形、植被、
##     玩家、屏外物体都会先占名额，所以物体多的法术要把它调大（物体探测用的是 512），
##     调太小会**凭空漏掉**物体；调大只多花一点遍历时间与内存。
##   · visual_up —— 转发给 resolve_visual 的"向上找层数"，默认 3；
##     导入模型网格挂得远时调大（扇形选点器传 6）。
## 返回值：Array，元素是 Dictionary{node, visual, box}；已按 mask / exclude / filter 过滤，
##   并且**已经剔除了没有可见网格或包围盒为空的命中**。可能为空数组。
## 副作用：一次物理形状查询 + 若干次场景树遍历（每次 resolve_visual / visual_aabb 都要遍历），
##   是**本模块最贵的一步**；不修改任何对象、不改场景树。
## 调用时机：需要"找出范围内物体"时按需调用；调用方应自己限流（它内部没有缓存）。
## 注意：用的是**形状相交查询**，不是射线 —— 命中列表是"与球体相交的所有碰撞体"，
##   所以中心附近早被扫过的物体也会一直命中，靠调用方自己的时序/寿命逻辑去表现。
## 注意：`collide_with_bodies = true` 而 `collide_with_areas = false` 是**刻意的**：
##   Area3D 多为触发区/范围标记，不算"物体"，混进来会导致互相描边。
static func collect_meshes(world: World3D, center: Vector3, radius: float, mask: int,
		exclude: Array = [], filter := Callable(), max_results := 64, visual_up := 3) -> Array:
	var out: Array = []
	if world == null or radius <= 0.0:
		return out
	var space := world.direct_space_state
	if space == null:
		# 无物理世界（极端场景 / 某些无头自检）时安静地返回空，而不是报错中断整批施法
		return out
	var shape := SphereShape3D.new()
	# 兜底 0.05：半径 0 的球体查询没有意义（几乎必然查不到东西），负半径更是非法
	shape.radius = maxf(0.05, radius)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	# 球心略微抬高：以脚下为中心的话一半球体在地下，浪费且容易吃到地形
	# 用 Basis()（单位基）而不是某节点的 transform：查询要的是世界空间的正球，不该跟着谁转
	params.transform = Transform3D(Basis(), center + Vector3.UP * 0.5)
	params.collision_mask = mask
	params.collide_with_bodies = true
	# 只查实体碰撞体：Area3D 通常是触发区/范围标记，不是"物体"，混进来会互相描边
	params.collide_with_areas = false
	# ★ 不要写 params.max_results —— PhysicsShapeQueryParameters3D 没有这个属性
	#   （实测：会直接 "Invalid assignment of property 'max_results'"）；
	#   它只是 intersect_shape() 的第二个实参。
	# 排除表（RID 数组）：调用方一般把玩家自己塞进来，否则每帧都会给玩家描一圈轮廓
	params.exclude = exclude
	# 命中数组的元素形如 {collider, rid, shape, ...}，这里只取 collider
	for h in space.intersect_shape(params, max_results):
		# 用 get 而不是下标取值：不同版本的字段可能有差异，取不到就只当没命中
		var node := h.get("collider") as Node
		if node == null:
			continue
		# 把"碰撞体"翻译成"真正持网格的节点"（本项目二者常为兄弟，必须向上找）
		var visual := resolve_visual(node, visual_up)
		if visual == null:
			continue
		var box := visual_aabb(visual)
		# 空盒 = 没有可见网格或网格没有 mesh（例如只有碰撞体的触发器）：
		# 既没法做范围过滤、挂上去也没有意义，直接丢
		if box.size.length_squared() <= 1e-6:
			continue
		# filter 可选：is_valid() 让"没传 filter"（默认 Callable()）时零成本通过
		if filter.is_valid() and not bool(filter.call(node, visual, box)):
			continue
		# 每条结果都带 node / visual / box：调用方通常用 visual 去取网格、用 box 做范围或屏幕剔除
		out.append({"node": node, "visual": visual, "box": box})
	return out

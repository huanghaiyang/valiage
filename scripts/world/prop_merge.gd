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

const ENABLED := true
## 处理的子树关键词（节点名包含即整棵合并）
const NAME_HINTS := ["墓地", "遗迹"]
## 少于这么多件就不值得合并
const MIN_PARTS := 4


static func apply(root: Node) -> Dictionary:
	if not ENABLED:
		return {"skipped": "disabled（把 prop_merge.gd 顶部的 ENABLED 改成 true 即启用）"}
	var total_parts := 0
	var total_surfaces := 0
	var groups := 0
	var st: Array = [root]
	while not st.is_empty():
		var n = st.pop_back() as Node
		if n == null:
			continue
		if _matched(n):
			var r := _merge_subtree(n)
			total_parts += int(r.get("parts", 0))
			total_surfaces += int(r.get("surfaces", 0))
			if int(r.get("parts", 0)) > 0:
				groups += 1
			continue                 # 整棵已处理，不再往里递归
		for c in n.get_children():
			st.append(c)
	var out := {"groups": groups, "parts": total_parts, "surfaces": total_surfaces}
	print("PropMerge | 合批：%d 组 ｜ 小件 %d → 网格 %d 个（draw call ≈ %d）" % [groups, total_parts, groups, total_surfaces])
	return out


static func _matched(n: Node) -> bool:
	if NAME_HINTS.is_empty():
		return true
	var nm := String(n.name)
	for h in NAME_HINTS:
		if nm.contains(String(h)):
			return true
	return false


static func _merge_subtree(holder: Node) -> Dictionary:
	var parts: Array = []
	var stack: Array = [holder]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and _mergeable(n as MeshInstance3D):
			parts.append(n)
		for c in n.get_children():
			stack.append(c)
	if parts.size() < MIN_PARTS:
		return {"parts": 0, "surfaces": 0}

	# ---- 按材质分组，几何烘焙到世界空间 ----
	var by_mat := {}                 # 材质实例id -> {"mat": Material, "pairs": [[mesh, surface], …]}
	var order: Array = []            # 保持稳定顺序
	var ref: MeshInstance3D = parts[0]
	for p in parts:
		var mi := p as MeshInstance3D
		var m: Mesh = mi.mesh
		if m == null:
			continue
		var xf: Transform3D = mi.global_transform
		for s in range(m.get_surface_count()):
			var mat: Material = mi.get_surface_override_material(s)
			if mat == null:
				mat = m.surface_get_material(s)
			var key := mat.get_instance_id() if mat != null else 0
			if not by_mat.has(key):
				by_mat[key] = {"mat": mat, "pairs": []}
				order.append(key)
			(by_mat[key]["pairs"] as Array).append([m, s, xf])

	var merged := ArrayMesh.new()
	var made := 0
	for key in order:
		var g: Dictionary = by_mat[key]
		var mat: Material = g["mat"]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		if mat != null:
			st.set_material(mat)
		for pr in g["pairs"]:
			st.append_from(pr[0] as Mesh, int(pr[1]), pr[2] as Transform3D)
		var arrays := st.commit_to_arrays()
		if arrays.is_empty():
			continue
		merged.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		if mat != null:
			merged.surface_set_material(merged.get_surface_count() - 1, mat)
		made += 1
	if made == 0:
		return {"parts": 0, "surfaces": 0}

	# ---- 承载节点：几何已在世界空间 → 全局单位变换 ✓ ----
	var node := MeshInstance3D.new()
	node.name = "MERGED_" + String(holder.name).substr(0, 20)
	node.mesh = merged
	node.cast_shadow = ref.cast_shadow
	node.visibility_range_end = ref.visibility_range_end
	node.visibility_range_end_margin = ref.visibility_range_end_margin
	node.visibility_range_fade_mode = ref.visibility_range_fade_mode
	var parent := holder.get_parent()
	if parent == null:
		return {"parts": 0, "surfaces": 0}
	parent.add_child(node)
	node.global_transform = Transform3D.IDENTITY
	# ★ 关键：释放小件之前，先把它们的"非可视子节点"**迁移**到合并节点上 ✓
	#   实测：碰撞体（StaticBody3D / CollisionShape3D）是 MeshInstance3D 的**子节点**
	#   （不是兄弟 ✗，我最初判断错了）→ 直接 queue_free 会把碰撞一起删掉 ✗
	#   （表现就是"合批后碰撞失效"）；碰撞没了，camera_rig 也找不到遮挡物 → 挖洞失效 ✓
	#   `reparent(node, true)` 会**保留全局变换** ✓ → 世界位置/尺寸不变 ✓
	#   同时：碰撞体的父节点变成合并后的 MeshInstance3D → camera_rig 解析"遮挡物对应的可视节点"时
	#   会找到这块合并网格 ✓（这正是恢复挖洞所需的关系 ✓）
	var moved := 0
	for p in parts:
		for c in (p as Node).get_children():
			if c is MeshInstance3D:
				continue                      # 可视子网格已并入合并网格 ✓ 无需迁移
			c.reparent(node, true)
			moved += 1
	print("PropMerge |   %s：小件 %d 件 → 网格 %d surface ｜ 迁移碰撞/附属节点 %d 个 ✓" % [String(holder.name), parts.size(), made, moved])
	for p in parts:
		(p as Node).queue_free()      # 这时才释放小件（真省显存/draw call ✓，碰撞已保住 ✓）
	return {"parts": parts.size(), "surfaces": made, "moved": moved}


## 可合并判定：有网格、无蒙皮（蒙皮网格不能这样烘焙 ✗）
static func _mergeable(mi: MeshInstance3D) -> bool:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return false
	if mi.skin != null:
		return false                  # 蒙皮网格：跳过 ✓
	return true

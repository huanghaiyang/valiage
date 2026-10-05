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

## 网格实例 id -> {mi, prev_overlay, prev_transparency, prev_layers}
var entries: Dictionary = {}


func count() -> int:
	return entries.size()


func has(id: int) -> bool:
	return entries.has(id)


func ids() -> Array:
	return entries.keys()


func get_entry(id: int) -> Dictionary:
	return entries.get(id, {})


## 挂上材质（第一次挂时记下原 overlay / 透明度 / 可见层，供还原）
func attach(mi: MeshInstance3D, mat: Material, ghost := 0.0) -> void:
	if mi == null or not is_instance_valid(mi) or mat == null:
		return
	var id := mi.get_instance_id()
	if entries.has(id):
		# 已经挂了：只更新材质与透明度（物体探测多圈会换材质）
		entries[id]["mi"] = mi
		mi.material_overlay = mat
		if ghost > 0.0:
			mi.transparency = clampf(ghost, 0.0, 1.0)
		return
	entries[id] = {
		"mi": mi,
		"prev_overlay": mi.material_overlay,
		"prev_transparency": mi.transparency,
		"prev_layers": mi.layers,
	}
	mi.material_overlay = mat
	if ghost > 0.0:
		mi.transparency = clampf(ghost, 0.0, 1.0)


## 只记状态 + 置可见层（屏幕空间描边那种"不挂材质、只把网格丢进遮罩层"的用法）
func mark_layers(mi: MeshInstance3D, mask: int) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	var id := mi.get_instance_id()
	if not entries.has(id):
		entries[id] = {
			"mi": mi,
			"prev_overlay": mi.material_overlay,
			"prev_transparency": mi.transparency,
			"prev_layers": mi.layers,
		}
	mi.layers |= mask


## 还原一个网格（overlay / 透明度 / 可见层 全部回到挂之前）
func detach(id: int) -> void:
	var e: Dictionary = entries.get(id, {})
	entries.erase(id)
	if e.is_empty():
		return
	var mi := e.get("mi") as MeshInstance3D
	if mi == null or not is_instance_valid(mi):
		return
	mi.material_overlay = e.get("prev_overlay")
	mi.transparency = float(e.get("prev_transparency", 0.0))
	var pl = e.get("prev_layers")
	if pl != null:
		mi.layers = int(pl)


## 同步"当前该挂的集合"：want = { 实例 id: {mi, mat, ghost(可选)} }，
## 不在 want 里的**全部还原**（物体离开范围时用）。
func sync(want: Dictionary) -> void:
	for id in want.keys():
		var w: Dictionary = want[id]
		attach(w.get("mi") as MeshInstance3D, w.get("mat") as Material, float(w.get("ghost", 0.0)))
	for id in entries.keys().duplicate():
		if not want.has(id):
			detach(id)


## 全部还原（术法结束 / 节点退出时必须调，否则场景里会留下只剩线稿的物体）
func clear() -> void:
	for id in entries.keys().duplicate():
		detach(id)


# ---------------------------------------------------------------- 静态工具（两边共用）

## 节点下所有可见网格（含自身）
static func visible_meshes(node: Node) -> Array:
	var out: Array = []
	if node == null:
		return out
	var stack: Array = [node]
	while not stack.is_empty():
		var n := stack.pop_back() as Node
		if n == null:
			continue
		if n is MeshInstance3D and (n as MeshInstance3D).visible:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## 碰撞体 -> 真正持有网格的节点。
## ★ 本项目的碰撞体与网格常常是**兄弟**（不是父子）：必须**向上找**（最多 3 层）。
##   只查"碰撞体自己的子节点"的话，每个物体都会判成"没有可见网格"（探测波实测踩过：
##   波纹在跑却什么都描不出来）。
static func resolve_visual(node: Node, max_up := 3) -> Node:
	if node == null:
		return null
	if not visible_meshes(node).is_empty():
		return node
	var cur := node.get_parent()
	var depth := 0
	while cur != null and depth < max_up:
		if not visible_meshes(cur).is_empty():
			return cur
		cur = cur.get_parent()
		depth += 1
	return null


## 一组网格的世界包围盒并集
static func visual_aabb(visual: Node) -> AABB:
	var box := AABB()
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
static func collect_meshes(world: World3D, center: Vector3, radius: float, mask: int,
		exclude: Array = [], filter := Callable(), max_results := 64, visual_up := 3) -> Array:
	var out: Array = []
	if world == null or radius <= 0.0:
		return out
	var space := world.direct_space_state
	if space == null:
		return out
	var shape := SphereShape3D.new()
	shape.radius = maxf(0.05, radius)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	# 球心略微抬高：以脚下为中心的话一半球体在地下，浪费且容易吃到地形
	params.transform = Transform3D(Basis(), center + Vector3.UP * 0.5)
	params.collision_mask = mask
	params.collide_with_bodies = true
	params.collide_with_areas = false
	# ★ 不要写 params.max_results —— PhysicsShapeQueryParameters3D 没有这个属性
	#   （实测：会直接 "Invalid assignment of property 'max_results'"）；
	#   它只是 intersect_shape() 的第二个实参。
	params.exclude = exclude
	for h in space.intersect_shape(params, max_results):
		var node := h.get("collider") as Node
		if node == null:
			continue
		var visual := resolve_visual(node, visual_up)
		if visual == null:
			continue
		var box := visual_aabb(visual)
		if box.size.length_squared() <= 1e-6:
			continue
		if filter.is_valid() and not bool(filter.call(node, visual, box)):
			continue
		out.append({"node": node, "visual": visual, "box": box})
	return out

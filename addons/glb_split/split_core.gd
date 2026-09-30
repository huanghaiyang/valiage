@tool
class_name GlbSplitCore
extends RefCounted
## GLB 分块核心（纯逻辑 [OK] 可单测 [OK]）
##
## 为什么不能只按"连通块"完事 [X]：
##   AI 生成（Tripo 等）的模型表面常是**上千个互不相连的补丁壳** [X]
##   （实测 石质墓园栅栏.glb：1.9M 面 -> 118 个连通块 [X]）
##   所以再加一层**空间聚类**把壳归并成 N 组 [OK][OK] —— 与 tools/glb_split.py 同一套思路 [OK]
##
## 输出约定：每个分块的网格**已把中心平移到自身原点** [OK]，
## 调用方把节点 position 设为返回的 center 即可还原原位 [OK]（这就是"中心坐标重置" [OK]）

const WELD_EPS := 100000.0     # 位置焊接精度：round(v * eps) 作 key [OK]
# 说明：焊接是**必须**的 [OK] —— glTF 会按 UV/法线把同一个几何点拆成多个顶点 [X]，
# 不焊就会把一个物体切成上千个碎块 [OK]（实测该栅栏：不焊 118 块，聚类后 9 块 [OK]）


## 并查集查找（带路径压缩 [OK]）。parent 必须是**普通 Array** [OK] 才有引用语义 [OK]
static func _find(parent: Array, x: int) -> int:
	var r := x
	while int(parent[r]) != r:
		r = int(parent[r])
	var cur := x
	while int(parent[cur]) != r:
		var nx := int(parent[cur])
		parent[cur] = r
		cur = nx
	return r


static func _weld_key(v: Vector3, eps := WELD_EPS) -> Vector3i:
	return Vector3i(int(round(v.x * eps)), int(round(v.y * eps)), int(round(v.z * eps)))


## 收集场景里所有网格实例 [OK]，并**自己累加 transform** [OK]
##
## [!]️ 为什么不用 mi.global_transform [X]：
##   GLTFDocument.generate_scene() 产出的场景**没有加进场景树** [X] ->
##   global_transform 会返回单位矩阵并报 "!is_inside_tree()" [X][OK]
##   -> 带局部变换的模型会**整个错位** [OK]（实测日志里刷了 6 条这个错 [OK]）
## 返回 [{inst, xf}]（xf = 从 root 累加下来的世界变换 [OK]）
static func collect_mesh_instances(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var xf: Transform3D = pair[1]
		var here := xf
		if n is Node3D:
			here = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append({"inst": n, "xf": here})
		for c in n.get_children():
			stack.append([c, here])
	return out


## 把一次 surface 的三角形按"焊接后连通性"分组，返回 {tri_count, tri_island} （每三角所属岛 id [OK]）
static func surface_islands(arrays: Array) -> Dictionary:
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var tri_count := (idx.size() / 3) if idx.size() > 0 else (verts.size() / 3)
	# ① 焊接：同位置顶点归到同一个 canonical id [OK]（glTF 会按 UV/法线拆点 [X] 必须焊 [OK]）
	var canon := PackedInt32Array()
	canon.resize(verts.size())
	var seen := {}
	for i in range(verts.size()):
		var k := _weld_key(verts[i])
		if seen.has(k):
			canon[i] = seen[k]
		else:
			seen[k] = i
			canon[i] = i
	# ② 并查集：每个三角形的三条边做 union [OK]
	# * 并查集用**普通 Array**（引用语义 [OK]）—— PackedInt32Array 是值类型 [X]，
	#   传给辅助函数改不动 [OK]；另外**不要给 lambda 起名字** [X]（会解析失败 [OK]）
	var parent: Array = []
	parent.resize(verts.size())
	for i in range(verts.size()):
		parent[i] = i
	for t in range(tri_count):
		var a: int
		var b: int
		var c: int
		if idx.size() > 0:
			a = canon[idx[t * 3]]
			b = canon[idx[t * 3 + 1]]
			c = canon[idx[t * 3 + 2]]
		else:
			a = canon[t * 3]
			b = canon[t * 3 + 1]
			c = canon[t * 3 + 2]
		var ra := _find(parent, a)
		var rb := _find(parent, b)
		var rc := _find(parent, c)
		if ra != rb:
			parent[rb] = ra
		var rr := _find(parent, a)
		var rc2 := _find(parent, c)
		if rr != rc2:
			parent[rc2] = rr
	# ③ 给每个三角形打岛号 [OK]
	var tri_island := PackedInt32Array()
	tri_island.resize(tri_count)
	var island_of := {}
	var next_id := 0
	for t in range(tri_count):
		var a2: int
		if idx.size() > 0:
			a2 = canon[idx[t * 3]]
		else:
			a2 = canon[t * 3]
		var r := _find(parent, a2)
		if not island_of.has(r):
			island_of[r] = next_id
			next_id += 1
		tri_island[t] = island_of[r]
	return {"tri_count": tri_count, "tri_island": tri_island, "island_count": next_id}


## 一站式：把 GLB 切成若干块。opts: {clusters, min_tris, weld_eps, box(可选 AABB)}
## 返回 [{name, mesh(ArrayMesh, 已重定中心 [OK]), center, tris, size, material}]
static func split(path: String, opts: Dictionary = {}) -> Dictionary:
	var res := {"ok": false, "message": "", "parts": [], "islands": 0, "source": path.get_file()}
	# [!]️ 守卫**不能**只用 ResourceLoader.exists [X]：对"保持文件(不导入)"的 glb 它可能是 false [X]
	#    -> 那样就会提前退出、连 GLTFDocument 都没机会试 [X]（那样这次修复就白做了 [OK]）
	#    -> 改成：**磁盘上确实没有文件**才退出 [OK]
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(abs_path) and not ResourceLoader.exists(path):
		res["message"] = "文件不存在：%s" % path
		return res
	# * 加载方式**照抄 addons/glb_tools/preview_window.gd** [OK]（用户指定参考那个工具 [OK]）
	#   它当时就发现：`.glb` 用 load() **常常拿不到场景** [X]
	#   （导入设置若为"保持文件(不导入)" [OK]、或模型很大 [OK] 都会这样 [OK]）
	#   -> 先试 load()，拿不到就改用官方 GLTFDocument 直接读文件 [OK]（不依赖导入设置 [OK]）
	var root: Node = null
	var packed := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if packed is PackedScene:
		root = (packed as PackedScene).instantiate()
	else:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		var err := doc.append_from_file(path, st)
		if err != OK:
			res["message"] = "加载失败（append_from_file 错误码 %d）：%s" % [err, path.get_file()]
			return res
		root = doc.generate_scene(st)
		if root == null:
			res["message"] = "解析出的场景为空 [X]：%s" % path.get_file()
			return res
		print("[GLB 切割] 用 GLTFDocument 直接读取（load() 拿不到场景 [OK]）：%s" % path.get_file())
	var insts := collect_mesh_instances(root)
	if insts.is_empty():
		root.free()
		res["message"] = "场景里没有网格"
		return res

	# ① 每个网格实例 -> 每个 surface 的岛划分 [OK]
	var min_tris := int(opts.get("min_tris", 12))
	var islands: Array = []          # {inst, surf, tris:PackedInt32Array, center:Vector3, tris_n:int}
	var t_start := Time.get_ticks_msec()
	print("[GLB 切割] 开始：%d 个网格实例 [OK]（1.9M 面的模型可能要十几秒 [OK] 不是卡死 [OK]）" % insts.size())
	for entry in insts:
		var mi := (entry as Dictionary)["inst"] as MeshInstance3D
		var m := mi.mesh
		var xf: Transform3D = (entry as Dictionary)["xf"]     # * 用累加来的变换 [OK] 不用 global_transform [X]
		for s in range(m.get_surface_count()):
			var arrays: Array = m.surface_get_arrays(s)
			if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
				continue
			print("[GLB 切割]   surface %d/%d 顶点 %d..." % [s + 1, m.get_surface_count(), (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()])
			var info := surface_islands(arrays)
			print("[GLB 切割]   -> 连通块 %d 个（累计 %d ms）" % [int(info["island_count"]), Time.get_ticks_msec() - t_start])
			var ti: PackedInt32Array = info["tri_island"]
			res["islands"] = int(res["islands"]) + int(info["island_count"])
			var buckets := {}
			for t in range(ti.size()):
				var id := ti[t]
				if not buckets.has(id):
					buckets[id] = PackedInt32Array()
				buckets[id].append(t)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			for id in buckets.keys():
				var tris: PackedInt32Array = buckets[id]
				if tris.size() < min_tris:
					continue
				# 该岛的世界质心（决定聚类位置 [OK]）
				var sum := Vector3.ZERO
				var cnt := 0
				var mn := Vector3(INF, INF, INF)
				var mx := Vector3(-INF, -INF, -INF)
				for t in tris:
					for k in range(3):
						var vi: int = idx[t * 3 + k] if idx.size() > 0 else t * 3 + k
						var wv: Vector3 = xf * verts[vi]
						sum += wv
						cnt += 1
						mn = mn.min(wv)
						mx = mx.max(wv)
				islands.append({"inst": mi, "surf": s, "tris": tris, "center": sum / maxf(1.0, float(cnt)),
								"tris_n": tris.size(), "material": m.surface_get_material(s), "xf": xf,
								"min": mn, "max": mx})
	# [!]️ 这里**绝不能** root.free() [X][X] ——
	#   islands 里存着对 root 下 MeshInstance3D 的引用 [OK]，
	#   而后面 _build_part 还要读 mi.mesh.surface_get_arrays() [X]
	#   -> 提前释放会导致 "Trying to assign invalid previously freed instance" [OK]
	#   -> 而且这个错误在编辑器里是**静默**的 [OK] -> 表现成"点了没反应、切成 0 块" [X]
	#   （实测真模型：9 个连通块 [OK] 全部失效 -> 切成 0 块 [X] 就是这个原因 [OK]）
	if islands.is_empty():
		root.free()
		res["message"] = "没找到任何分块（试试调小最小三角数）"
		return res

	# * 立方体框选改为**逐三角**精确裁剪 [OK] —— 在 _build_part 里按三角重心过滤 [OK]
	#   （早期只按"分块中心"过滤 [X]：跨框的分块会被整体丢掉或整体保留 [X]，不准确 [OK]）
	# ★ 必须是 Variant：盒子既可能是轴对齐数组 [6]，也可能是带朝向的字典（鼠标拖出来的框）
	#   写成 Array ✗ 时，传字典就会报 "Trying to assign value of type 'Dictionary' to a variable of type 'Array'"
	var box: Variant = opts.get("box", []) if opts.has("box") else []

	# ② 组数**自动判定** [OK]（不需要用户填数字 [OK] —— 见 _auto_cluster [OK]）
	# * 自适应 [OK]：连通块本来就不多时**直接一块一个** [OK] —— 再聚类反而会把
	#   "本来就分开的小物件"粘到一起 [X]
	#   实测真模型：GLTFDocument 读出来正好 9 个连通块 [OK]（就是 9 根栅栏柱 [OK]），
	#   但 median×2.5 的阈值把它们又并到了一起 [X] -> 块数 < 9 [X]
	#   只有像原始 Tripo 那种**上千个互不相连的补丁壳**时才需要聚类 [OK]
	var groups: Array = []
	if islands.size() <= 64:
		for isl in islands:
			groups.append([isl])
		print("[GLB 切割] 连通块只有 %d 个 -> 直接一块一个 [OK]（不做聚类 [OK]）" % islands.size())
	else:
		groups = _auto_cluster(islands)

	# ③ 每组合成一个网格并重定中心 [OK]
	for gi in range(groups.size()):
		var g: Array = groups[gi]
		var part := _build_part(g, "part_%02d" % (gi + 1), box)
		if not part.is_empty():
			res["parts"].append(part)
	res["ok"] = res["parts"].size() > 0
	res["message"] = "切成 %d 块（原始连通块 %d 个，候选壳 %d 个）" % [res["parts"].size(), int(res["islands"]), islands.size()]
	root.free()          # * 分块都建完了，这里才释放临时场景 [OK]
	print("[GLB 切割] 完成：%d 块 | 总耗时 %d ms [OK]" % [res["parts"].size(), Time.get_ticks_msec() - t_start])
	return res


## * 自动判定该切成几块 [OK]（用户不需要填任何数字 [OK]）
## 思路：算每个壳到"最近邻壳"的距离 -> 取**中位数**当基准 [OK] -> 阈值 = 中位数 × 2.5
##   · 同一物体内部的补丁壳挨得很近 [OK]（远小于中位数）
##   · 不同物体之间的空隙明显更大 [OK]（远大于中位数）
## 用中位数而不是固定比例 [X]：不同模型尺度差几十倍 [OK]，固定比例会一会儿全并、一会儿全散 [X]
static func _auto_cluster(islands: Array) -> Array:
	var n := islands.size()
	if n <= 1:
		return [islands]
	# 按 x 排序后只比邻近窗口 [OK]（壳常上千个，全比较是 O(n²) 会卡 [OK]）
	var order: Array = []
	for i in range(n):
		order.append(i)
	order.sort_custom(func(a, b): return (islands[a]["center"] as Vector3).x < (islands[b]["center"] as Vector3).x)
	var nn := PackedFloat32Array()
	nn.resize(n)
	var WIN := 24
	for oi in range(n):
		var i: int = order[oi]
		var best := INF
		var lo := maxi(0, oi - WIN)
		var hi := mini(n, oi + WIN + 1)
		for oj in range(lo, hi):
			if oj == oi:
				continue
			var j: int = order[oj]
			var g := _box_gap(islands[i]["min"], islands[i]["max"], islands[j]["min"], islands[j]["max"])
			if g < best:
				best = g
		nn[i] = best if best < INF else 0.0
	var sorted_nn: Array = []
	for v in nn:
		sorted_nn.append(v)
	sorted_nn.sort()
	var med: float = sorted_nn[sorted_nn.size() / 2]
	var thr: float = maxf(med * 2.5, 0.00001)
	# 并查集合并"挨得近"的壳 [OK]
	var parent: Array = []
	parent.resize(n)
	for i in range(n):
		parent[i] = i
	for oi in range(n):
		var i2: int = order[oi]
		var lo2 := maxi(0, oi - WIN)
		var hi2 := mini(n, oi + WIN + 1)
		for oj in range(lo2, hi2):
			if oj == oi:
				continue
			var j2: int = order[oj]
			if _box_gap(islands[i2]["min"], islands[i2]["max"], islands[j2]["min"], islands[j2]["max"]) <= thr:
				var ra := _find(parent, i2)
				var rb := _find(parent, j2)
				if ra != rb:
					parent[rb] = ra
	var groups_by_root := {}
	for i3 in range(n):
		var r3 := _find(parent, i3)
		if not groups_by_root.has(r3):
			groups_by_root[r3] = []
		(groups_by_root[r3] as Array).append(islands[i3])
	var out: Array = []
	for k in groups_by_root.keys():
		out.append(groups_by_root[k])
	print("[GLB 切割] 自动判定：壳 %d 个 -> 分块 %d 块（最近邻中位数 %.4f，阈值 %.4f）" % [n, out.size(), med, thr])
	return out


## 两个 AABB 之间的空隙（相交则为 0 [OK]）
static func _box_gap(mn1: Vector3, mx1: Vector3, mn2: Vector3, mx2: Vector3) -> float:
	var dx: float = maxf(0.0, maxf(mn1.x - mx2.x, mn2.x - mx1.x))
	var dy: float = maxf(0.0, maxf(mn1.y - mx2.y, mn2.y - mx1.y))
	var dz: float = maxf(0.0, maxf(mn1.z - mx2.z, mn2.z - mx1.z))
	return sqrt(dx * dx + dy * dy + dz * dz)


static func _kmeans_groups(islands: Array, k: int) -> Array:
	var pts: Array = []
	for it in islands:
		var c: Vector3 = it["center"]
		pts.append(Vector2(c.x, c.z))
	var cents: Array = []
	var step := maxi(1, int(pts.size() / float(k)))
	for i in range(k):
		cents.append(pts[mini(i * step, pts.size() - 1)])
	var lab := PackedInt32Array()
	lab.resize(pts.size())
	for _iter in range(40):
		for i in range(pts.size()):
			var best := 0
			var bd := INF
			for c in range(k):
				var d: float = (pts[i] as Vector2).distance_squared_to(cents[c])
				if d < bd:
					bd = d
					best = c
			lab[i] = best
		var sums: Array = []
		var cnts: Array = []
		for c in range(k):
			sums.append(Vector2.ZERO)
			cnts.append(0)
		for i in range(pts.size()):
			sums[lab[i]] = (sums[lab[i]] as Vector2) + (pts[i] as Vector2)
			cnts[lab[i]] = int(cnts[lab[i]]) + 1
		for c in range(k):
			if int(cnts[c]) > 0:
				cents[c] = (sums[c] as Vector2) / float(cnts[c])
	var groups: Array = []
	for c in range(k):
		groups.append([])
	for i in range(pts.size()):
		(groups[lab[i]] as Array).append(islands[i])
	return groups


## 把一组岛合成一个 ArrayMesh，并把中心平移到原点 [OK]，返回 {name, mesh, center, tris, size}
## 点是否在切割盒内 [OK]
## box 两种形态都支持：
##   · Array  [x0,y0,z0,x1,y1,z1]  -> 轴对齐（tools/glb_split.py --box 用的就是这种 [OK]）
##   · Dictionary {origin, bx, by, bz, half} -> **任意朝向** [OK]（鼠标在预览里拖出来的框是这个 [OK]）
static func _inside_box(p: Vector3, box: Variant) -> bool:
	if box is Dictionary:
		var d: Dictionary = box
		var o: Vector3 = d["origin"]
		var bx: Vector3 = d["bx"]
		var by: Vector3 = d["by"]
		var bz: Vector3 = d["bz"]
		var hf: Vector3 = d["half"]
		var rel := p - o
		if absf(rel.dot(bx)) > hf.x:
			return false
		if absf(rel.dot(by)) > hf.y:
			return false
		if absf(rel.dot(bz)) > hf.z:
			return false
		return true
	var a: Array = box
	return p.x >= float(a[0]) and p.x <= float(a[3]) \
		and p.y >= float(a[1]) and p.y <= float(a[4]) \
		and p.z >= float(a[2]) and p.z <= float(a[5])


## ★ 用盒子**筛选已有的分块** —— "按框选记录导出"走这条路：
##   不重新加载 66MB glb、不焊接百万顶点、不算连通块，只做逐三角重心判定 -> 毫秒级。
##   （用户反馈："为什么你还要查连通块？？？" —— 就是因为以前每条记录都重跑了一遍完整切割）
## ★ 用盒子**筛选已有的分块**（"按框选记录导出"走这条路）
##   关键优化（实测驱动）：
##     ① 先用分块自己的 AABB 与盒子做粗判 -> 绝大多数分块**一次判断**就定了（全部在内/全部在外）
##     ② 整块都在框内时**原样复用**该网格（零拷贝）；只有"部分在内"才重建网格
##   实测：不做这些优化时 9 块要 6007 ms（因为白重建了 173 万三角）；优化后常见情况是毫秒级
static func slice_parts(parts: Array, box: Variant) -> Array:
	var out: Array = []
	for p in parts:
		var d: Dictionary = p
		var mesh := d.get("mesh") as Mesh
		if mesh == null:
			continue
		var m := mesh as ArrayMesh
		if m == null or m.get_surface_count() == 0:
			continue
		var ar: Array = m.surface_get_arrays(0)
		var vtx: PackedVector3Array = ar[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = ar[Mesh.ARRAY_INDEX] if ar[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var has_idx := idx.size() > 0
		var tc: int = (idx.size() if has_idx else vtx.size()) / 3
		if tc <= 0:
			continue
		var center: Vector3 = d.get("center", Vector3.ZERO)
		var xf := Transform3D(Basis(), center)
		# ① 粗判：分块自己的 AABB（centered 网格 -> 世界空间 = center + 局部包围盒）
		var aabb: AABB = m.get_aabb()
		var verdict := _aabb_vs_box(aabb, center, box)
		if verdict == 0:
			continue                      # 完全在框外 -> 直接丢
		if verdict == 1:
			out.append(d)                  # 完全在框内 -> 原样复用，零拷贝
			continue
		# ② 只有"跨界"的分块才逐三角精确判定
		#    性能要点（实测驱动）：
		#      · 盒子参数提到局部 + **内联判定**（避免每个三角一次函数调用）
		#      · 分块网格是**纯平移**（建块时已重定中心、无旋转）-> 用 v + center 代替矩阵乘法
		var is_arr := box is Array and (box as Array).size() == 6
		var bx := Vector3.RIGHT
		var by := Vector3.UP
		var bz := Vector3.BACK
		var hf := Vector3.ZERO
		var box_o := Vector3.ZERO
		if is_arr:
			var a: Array = box
			var lo := Vector3(float(a[0]), float(a[1]), float(a[2]))
			var hi := Vector3(float(a[3]), float(a[4]), float(a[5]))
			box_o = (lo + hi) * 0.5
			hf = (hi - lo) * 0.5
		elif box is Dictionary:
			var dd: Dictionary = box
			box_o = dd["origin"]
			bx = dd["bx"]
			by = dd["by"]
			bz = dd["bz"]
			hf = dd["half"]
		else:
			out.append(d)          # 没有有效盒子 -> 全部保留
			continue
		var kept := 0
		var ci := center - box_o
		for t in range(tc):
			var c := Vector3.ZERO
			for k in range(3):
				var vi: int = idx[t * 3 + k] if has_idx else t * 3 + k
				c += vtx[vi]
			c = c / 3.0 + ci
			if is_arr:
				if absf(c.x) <= hf.x and absf(c.y) <= hf.y and absf(c.z) <= hf.z:
					kept += 1
			else:
				if absf(c.dot(bx)) <= hf.x and absf(c.dot(by)) <= hf.y and absf(c.dot(bz)) <= hf.z:
					kept += 1
		if kept == 0:
			continue
		if kept == tc:
			out.append(d)
			continue
		var tris := PackedInt32Array()
		tris.resize(tc)
		for t in range(tc):
			tris[t] = t
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var isl := {
			"inst": mi,
			"surf": 0,
			"tris": tris,
			"tris_n": tris.size(),
			"center": center,
			"material": m.surface_get_material(0),
			"xf": xf,
		}
		var r: Dictionary = _build_part([isl], String(d.get("name", "part")), box)
		mi.free()
		if not r.is_empty():
			out.append(r)
	return out


## 分块 AABB（世界空间）与盒子的粗判：1 = 完全在内，0 = 完全在外，-1 = 不确定（要精确判定）
static func _aabb_vs_box(aabb: AABB, offset: Vector3, box: Variant) -> int:
	var mn := aabb.position + offset
	var mx := aabb.position + aabb.size + offset
	# 轴对齐数组盒子：直接比大小，精确
	if box is Array and (box as Array).size() == 6:
		var a: Array = box
		if mx.x < float(a[0]) or mn.x > float(a[3]) or mx.y < float(a[1]) or mn.y > float(a[4]) or mx.z < float(a[2]) or mn.z > float(a[5]):
			return 0
		if mn.x >= float(a[0]) and mx.x <= float(a[3]) and mn.y >= float(a[1]) and mx.y <= float(a[4]) and mn.z >= float(a[2]) and mx.z <= float(a[5]):
			return 1
		return -1
	if not (box is Dictionary):
		return 1
	var dd: Dictionary = box
	var o: Vector3 = dd["origin"]
	var bx: Vector3 = dd["bx"]
	var by: Vector3 = dd["by"]
	var bz: Vector3 = dd["bz"]
	var hf: Vector3 = dd["half"]
	# 8 个角是否全在内 / 全在外（保守：不确定就返回 -1 走精确判定）
	var inside := 0
	for i in range(8):
		var c := Vector3(
			mn.x if (i & 1) == 0 else mx.x,
			mn.y if (i & 2) == 0 else mx.y,
			mn.z if (i & 4) == 0 else mx.z)
		var rel := c - o
		if absf(rel.dot(bx)) <= hf.x and absf(rel.dot(by)) <= hf.y and absf(rel.dot(bz)) <= hf.z:
			inside += 1
	if inside == 8:
		return 1
	if inside == 0:
		# 还要排除"盒子完全落在分块 AABB 内"的情况（这时也要精确判定）
		var c2 := o
		if c2.x >= mn.x and c2.x <= mx.x and c2.y >= mn.y and c2.y <= mx.y and c2.z >= mn.z and c2.z <= mx.z:
			return -1
		return 0
	return -1
static func _build_part(group: Array, name_hint: String, box: Variant = []) -> Dictionary:
	if group.is_empty():
		return {}
	# * 立方体框选：逐三角按**重心**裁掉框外的 [OK]（精确 [OK]，跨框的分块也能正确切开 [OK]）
	if (box is Array and box.size() == 6) or box is Dictionary:
		var filtered: Array = []
		for it in group:
			var mi0: MeshInstance3D = it["inst"]
			var ar0: Array = mi0.mesh.surface_get_arrays(int(it["surf"]))
			var v0: PackedVector3Array = ar0[Mesh.ARRAY_VERTEX]
			var i0: PackedInt32Array = ar0[Mesh.ARRAY_INDEX] if ar0[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var xf0: Transform3D = (it as Dictionary)["xf"]
			var keep := PackedInt32Array()
			for t in (it["tris"] as PackedInt32Array):
				var c := Vector3.ZERO
				for k in range(3):
					var vi0: int = i0[t * 3 + k] if i0.size() > 0 else t * 3 + k
					c += xf0 * v0[vi0]
				c /= 3.0
				if _inside_box(c, box):
					keep.append(t)
			if keep.is_empty():
				continue
			var d0: Dictionary = (it as Dictionary).duplicate()
			d0["tris"] = keep
			d0["tris_n"] = keep.size()
			filtered.append(d0)
		group = filtered
		if group.is_empty():
			return {}
	# 世界空间顶点收集 -> 找出以"材质+源网格"为单位的三角形 [OK]
	var minv := Vector3(INF, INF, INF)
	var maxv := Vector3(-INF, -INF, -INF)
	var packed := {}          # key: inst_id_surf -> {arrays, tris:PackedInt32Array, xf, material}
	for it in group:
		var mi: MeshInstance3D = it["inst"]
		var key := "%d_%d" % [mi.get_instance_id(), int(it["surf"])]
		if not packed.has(key):
			packed[key] = {"inst": mi, "surf": int(it["surf"]),
						   "arrays": mi.mesh.surface_get_arrays(int(it["surf"])),
						   "xf": (it as Dictionary)["xf"],
						   "material": mi.mesh.surface_get_material(int(it["surf"])),
						   "tris": PackedInt32Array()}
		var e: Dictionary = packed[key]
		var acc: PackedInt32Array = e["tris"]
		for t in (it["tris"] as PackedInt32Array):
			acc.append(t)
	# 先算世界 AABB -> 中心 [OK]
	for key in packed.keys():
		var e2: Dictionary = packed[key]
		var arrays: Array = e2["arrays"]
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var xf: Transform3D = e2["xf"]
		for t in (e2["tris"] as PackedInt32Array):
			for kk in range(3):
				var vi: int = idx[t * 3 + kk] if idx.size() > 0 else t * 3 + kk
				var w: Vector3 = xf * verts[vi]
				minv = minv.min(w)
				maxv = maxv.max(w)
	var center := (minv + maxv) * 0.5
	# 再逐 surface 重建（顶点重映射 + 减中心 [OK]）
	var out_mesh := ArrayMesh.new()
	var tri_total := 0
	for key in packed.keys():
		var e3: Dictionary = packed[key]
		var arrays2: Array = e3["arrays"]
		var verts2: PackedVector3Array = arrays2[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays2[Mesh.ARRAY_NORMAL] if arrays2[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		var uvs: PackedVector2Array = arrays2[Mesh.ARRAY_TEX_UV] if arrays2[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		var idx2: PackedInt32Array = arrays2[Mesh.ARRAY_INDEX] if arrays2[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var xf2: Transform3D = e3["xf"]
		var remap := {}
		var nv := PackedVector3Array()
		var nn := PackedVector3Array()
		var nu := PackedVector2Array()
		var ni := PackedInt32Array()
		var has_n := norms.size() > 0
		var has_u := uvs.size() > 0
		for t in (e3["tris"] as PackedInt32Array):
			for kk in range(3):
				var vi2: int = idx2[t * 3 + kk] if idx2.size() > 0 else t * 3 + kk
				if not remap.has(vi2):
					remap[vi2] = nv.size()
					nv.append((xf2 * verts2[vi2]) - center)          # * 中心重置 [OK]
					if has_n:
						nn.append((xf2.basis * norms[vi2]).normalized())
					if has_u:
						nu.append(uvs[vi2])
				ni.append(int(remap[vi2]))
		if ni.is_empty():
			continue
		var a: Array = []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = nv
		a[Mesh.ARRAY_INDEX] = ni
		if has_n:
			a[Mesh.ARRAY_NORMAL] = nn
		if has_u:
			a[Mesh.ARRAY_TEX_UV] = nu
		var s_i := out_mesh.get_surface_count()
		out_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
		if e3["material"] is Material:
			out_mesh.surface_set_material(s_i, e3["material"] as Material)
		tri_total += ni.size() / 3
	return {"name": name_hint, "mesh": out_mesh, "center": center,
			"tris": tri_total, "size": maxv - minv}
@tool
extends RefCounted
## 自动拆分：从贴图图集里找出"素材块"，并把每块与场景里的网格对应起来。
##
## 实测要点：
##  · 图集是**黑底**（Poly Haven 扫描件如此）-> 按亮度阈值二值化 + 连通域 = 素材块。
##  · 网格 UV 与图像坐标**不翻转**（dead_a 的 UV y=.154-.292 正好对应图上左上的枯黄丛）。
##  · 一个网格可能横跨多块（复合草丛）-> 只在"网格 UV 边界大部分落在该块内"时才认领，
##    并在多个候选里取 UV 面积最小的那个（最"纯"的样本）。
##  · 认领不到的块 -> empty = true（UI 显示「模型为空」）。

const N := 128                 # 分析分辨率
const LUM_THRESHOLD := 0.06    # 黑底判定
const MIN_AREA := 18           # 太小的连通域丢掉（噪点/碎屑）


## 返回 [{index, rect: Rect2(图坐标 0..1), mesh: MeshInstance3D 或 null, name, tris, empty}]
static func analyze(meshes: Array, albedo_path: String) -> Array:
	var out: Array = []
	# ---------- 1. 读图 + 连通域 ----------
	var img := Image.load_from_file(albedo_path)
	if img == null:
		return out
	img.resize(N, N, Image.INTERPOLATE_BILINEAR)
	var lum := PackedFloat32Array()
	lum.resize(N * N)
	for y in range(N):
		for x in range(N):
			var c := img.get_pixel(x, y)
			lum[y * N + x] = (c.r + c.g + c.b) / 3.0
	var seen := PackedInt32Array()
	seen.resize(N * N)
	for i in range(N * N):
		seen[i] = -1
	var cuts: Array = []
	for sy in range(N):
		for sx in range(N):
			if lum[sy * N + sx] <= LUM_THRESHOLD or seen[sy * N + sx] != -1:
				continue
			var id := cuts.size()
			var stack: Array = [[sx, sy]]
			var minx := sx; var maxx := sx; var miny := sy; var maxy := sy; var area := 0
			seen[sy * N + sx] = id
			while not stack.is_empty():
				var p: Array = stack.pop_back()
				var px: int = p[0]
				var py: int = p[1]
				area += 1
				minx = mini(minx, px); maxx = maxi(maxx, px)
				miny = mini(miny, py); maxy = maxi(maxy, py)
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						var yy := py + dy
						var xx := px + dx
						if yy < 0 or yy >= N or xx < 0 or xx >= N:
							continue
						if lum[yy * N + xx] > LUM_THRESHOLD and seen[yy * N + xx] == -1:
							seen[yy * N + xx] = id
							stack.append([xx, yy])
			if area >= MIN_AREA:
				cuts.append({"minx": minx, "maxx": maxx, "miny": miny, "maxy": maxy, "area": area})
	cuts.sort_custom(func(a, b): return a["area"] > b["area"])

	# ---------- 2. 每个网格的 UV 边界（图坐标，不翻转）----------
	var boxes := {}
	for m in meshes:
		var mi := m as MeshInstance3D
		if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var ar := mi.mesh.surface_get_arrays(0)
		var uv: PackedVector2Array = ar[Mesh.ARRAY_TEX_UV] if ar[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
		if uv.is_empty():
			continue
		var mn := Vector2(9.0, 9.0)
		var mx := Vector2(-9.0, -9.0)
		for t in uv:
			mn.x = minf(mn.x, t.x); mn.y = minf(mn.y, t.y)
			mx.x = maxf(mx.x, t.x); mx.y = maxf(mx.y, t.y)
		boxes[mi] = {"x0": mn.x, "x1": mx.x, "y0": mn.y, "y1": mx.y,
				"area": maxf(1e-6, (mx.x - mn.x) * (mx.y - mn.y))}

	# ---------- 3. 每个块认领最"纯"的网格 ----------
	var used := {}
	var idx := 0
	for c in cuts:
		idx += 1
		var bx0 := float(c["minx"]) / float(N)
		var bx1 := float(c["maxx"] + 1) / float(N)
		var by0 := float(c["miny"]) / float(N)
		var by1 := float(c["maxy"] + 1) / float(N)
		var best: MeshInstance3D = null
		var best_area := 1e9
		var best_frac := 0.0
		for m in meshes:
			var mi2 := m as MeshInstance3D
			if mi2 == null or not boxes.has(mi2) or used.has(mi2):
				continue
			var d: Dictionary = boxes[mi2]
			var ox0: float = maxf(d["x0"], bx0)
			var ox1: float = minf(d["x1"], bx1)
			var oy0: float = maxf(d["y0"], by0)
			var oy1: float = minf(d["y1"], by1)
			if ox1 <= ox0 or oy1 <= oy0:
				continue
			var ov := (ox1 - ox0) * (oy1 - oy0)
			# 判据用"该网格**覆盖了这块**多少"（不是"网格有多少在块内"）：
			#   dead_a 的 UV 比块略宽，用后者会算出 0.61 被误拒；用前者就正常认领。
			var cut_area := maxf(1e-6, (bx1 - bx0) * (by1 - by0))
			var cover := ov / cut_area
			if cover < 0.45:                           # 覆盖不到一半 -> 不算认领
				continue
			# 同样合格时取 UV 面积最小的那个：把"跨多块的复合草丛"排除掉，留下最纯的样本
			if float(d["area"]) < best_area:
				best_area = float(d["area"])
				best = mi2
				best_frac = cover
		if best != null:
			used[best] = true
		var tris := 0
		if best != null and best.mesh != null:
			for s in range(best.mesh.get_surface_count()):
				var a2 := best.mesh.surface_get_arrays(s)
				var ix := a2[Mesh.ARRAY_INDEX] as PackedInt32Array
				tris += (ix.size() if ix != null and ix.size() > 0 else (a2[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
		out.append({
			"index": idx,
			"rect": Rect2(bx0, by0, bx1 - bx0, by1 - by0),
			"mesh": best,
			"name": String(best.name) if best != null else "",
			"tris": tris,
			"empty": best == null,
			"fit": best_frac,
		})
	return out
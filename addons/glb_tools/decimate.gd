@tool
extends RefCounted
## GLB 降模核心 —— 两条路，各有取舍（下面是实测数据，不是推测）：
##
## ① **即时预览**（拖动滑块用）：Godot 内置的 LOD 生成（底层同样是 meshoptimizer，毫秒级）。
##    限制：`ImporterMesh.generate_lods()` 不能指定比例，只能给出约 50%/25%/12.5%… 的阶梯；
##    而且它**只换索引表、不动顶点表**。
##    → 这条路：面数降、实时，但**导出的 glb 体积基本不降**（顶点一个没少；顶点特别多时
##      甚至因为索引位宽变化而变大）。用户的反馈"精度降了体积反而变大"就是撞在这上面。
##
## ② **精确比例**（点按钮用）：交给 tools/glb_simplify.py（gltf-transform 的 weld + simplify，
##    保留 UV/法线/材质）。weld 会把重复与未被引用的顶点一起去掉，所以**文件是真的变小**：
##    实测 4879 面 → 1462 面（实际 29.965%），440 KB → 300 KB。
##    代价是慢（首次 npx 约 7 秒），所以只在用户点按钮时跑，并且放后台线程。

const TOOL := "res://tools/glb_simplify.py"


## 生成 LOD 阶梯：返回 [{ratio: 实际三角面比例, mesh: Mesh}]，比例从大到小，第一项是原始网格。
static func build_lods(mesh: Mesh) -> Array:
	var out: Array = []
	if mesh == null or mesh.get_surface_count() == 0:
		return out
	out.append({"ratio": 1.0, "mesh": mesh})
	var base_tris := tri_count(mesh)
	if base_tris <= 0:
		return out

	var im: ImporterMesh = ImporterMesh.from_mesh(mesh)
	# 三个参数都是必需的（第三个是骨骼变换数组，没有骨骼就传空）；角度沿用导入器默认值
	im.generate_lods(60.0, 25.0, [])

	var max_lod := 0
	for s in im.get_surface_count():
		max_lod = maxi(max_lod, im.get_surface_lod_count(s) - 1)
	for l in range(1, max_lod + 1):
		var am := ArrayMesh.new()
		var tris := 0
		for s in im.get_surface_count():
			var available := im.get_surface_lod_count(s)
			if available <= 1:
				continue
			# 没索引 / 没生成出 LOD 的网格直接跳过，不要刷报错
			var idx: PackedInt32Array = im.get_surface_lod_indices(s, mini(l, available - 1))
			if idx.is_empty():
				continue
			var arrays: Array = im.get_surface_arrays(s)
			if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null:
				continue
			arrays[Mesh.ARRAY_INDEX] = idx
			am.add_surface_from_arrays(im.get_surface_primitive_type(s), arrays)
			var mat := im.get_surface_material(s)
			if mat == null and s < mesh.get_surface_count():
				mat = mesh.surface_get_material(s)
			if mat != null:
				am.surface_set_material(am.get_surface_count() - 1, mat)
			tris += idx.size() / 3
		if am.get_surface_count() == 0:
			continue
		out.append({"ratio": float(tris) / float(base_tris), "mesh": am})
	return out


## 从阶梯里挑最接近目标比例的一级
static func pick(lods: Array, target: float) -> Dictionary:
	if lods.is_empty():
		return {}
	var best: Dictionary = lods[0]
	var best_d := absf(float(best["ratio"]) - target)
	for item in lods:
		var d := absf(float(item["ratio"]) - target)
		if d < best_d:
			best_d = d
			best = item
	return best


## 精确降模的命令行（真正跑进程由调用方放进线程里）
static func exact_args(src_glb: String, dst_glb: String, ratio: float,
		project_root: String, report_path: String) -> Array:
	return [
		"-X", "utf8",
		ProjectSettings.globalize_path(TOOL),
		"--in", src_glb,
		"--out", dst_glb,
		"--ratio", "%.6f" % clampf(ratio, 0.01, 1.0),
		"--project", project_root,
		"--report", report_path,
	]


## 读工具写出的报告（UTF-8 文件；不要依赖 OS.execute 解码，中文 Windows 上是 GBK 会乱码）
static func read_report(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_buffer(f.get_length()).get_string_from_utf8()
	f.close()
	return text.strip_edges()


static func tri_count(mesh: Mesh) -> int:
	var tris := 0
	if mesh == null:
		return 0
	for i in mesh.get_surface_count():
		var idx_len := 0
		var vtx_len := 0
		if mesh is ArrayMesh:
			idx_len = (mesh as ArrayMesh).surface_get_array_index_len(i)
			vtx_len = (mesh as ArrayMesh).surface_get_array_len(i)
		else:
			var arrays: Array = mesh.surface_get_arrays(i)
			if arrays[Mesh.ARRAY_INDEX] != null:
				idx_len = (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size()
			elif arrays[Mesh.ARRAY_VERTEX] != null:
				vtx_len = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		tris += (idx_len / 3) if idx_len > 0 else (vtx_len / 3)
	return tris


## weld（只压顶点、不降面）的命令行。
## 为什么需要它：Godot 的 LOD 只换索引表、不动顶点表，导出后体积降不下来；
## 再过一遍 weld 把重复/未引用的顶点删掉，体积才真的变小（实测 449KB -> 432KB）。
static func weld_args(glb_path: String, project_root: String, report_path: String) -> Array:
	return [
		"-X", "utf8",
		ProjectSettings.globalize_path(TOOL),
		"--in", glb_path,
		"--out", glb_path,          # 配合 --in-place，实际是先写同目录临时文件再替换
		"--weld-only",
		"--in-place",
		"--project", project_root,
		"--report", report_path,
	]
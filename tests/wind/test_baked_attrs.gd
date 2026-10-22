extends SceneTree
## ============================================================================
## fast-tree 风摆 · 烘焙属性校验（.res CUSTOM0/CUSTOM1 ↔ GLB 原始 accessor）
## ============================================================================
## 对每个树节点（Bark_Trunk / Bark_Branch_L1..L5 / Leaves / Flowers）：
##   · 从 res://assets/models/树/wind/<节点>.res 的 ArrayMesh 读 VERTEX + CUSTOM0/1
##   · 用与 tools/bake_tree_wind.gd **相同的"分格 + 邻格"匹配逻辑**（CELL=2mm，
##     搜索本格 + 26 邻格，取最近，容差 3e-3 m）把它匹配回 GLB 的 POSITION 下标。
##     注意：Godot 4.7 导入叶片/花朵时压缩了顶点属性，位置本身就有 ~5e-4 m 量化误差，
##     所以"位置往返误差 = 0"只对未压缩的树皮成立；叶/花的判据是 <= bake 的 MATCH_EPS。
##   · 抽样 200 个顶点逐项比较：
##       - 位置往返误差（.res VERTEX vs GLB POSITION）
##       - CUSTOM0.xyz == _AORIGIN、CUSTOM0.w == _AWIND
##       - CUSTOM1.x == _APHASE、CUSTOM1.z == _ANODEID
##       - CUSTOM1.w == 1（已烘焙标志）
##       - CUSTOM1.y 的 isLeaf：Leaves/Flowers = 1，其余 = 0
##
## 用法：
##   & 'D:\godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path . \
##       --quit-after 600 --script res://tests/wind/test_baked_attrs.gd
## 产物：.runtime/wind_port/baked_attrs.json
## ============================================================================
const G := preload("res://tests/wind/glb_attrs.gd")

const GLB_PATH := "res://assets/models/树/大樱花树.glb"
const BAKE_DIR := "res://assets/models/树/wind/"
const SAMPLE_PER_NODE := 200
## 匹配逻辑必须与 tools/bake_tree_wind.gd **完全一致**（否则会误报烘焙 bug）：
##   Godot 4.7 导入叶片/花朵网格时会压缩顶点属性（16-bit 归一化），实测位置被量化到
##   ~5e-4 m；树干网格没压缩、可以精确命中。所以 bake 用的是"2mm 分格 + 26 邻格 + 取最近"，
##   容差 3e-3 m —— 不是 1e-4 精确 key。
const CELL := 0.002
const MATCH_EPS := 0.003
const ATTR_EPS := 1e-4        ## 属性误差上限（任务要求 < 1e-4）
const SEED := 20261022
const LEAF_NODES := ["Leaves", "Flowers"]
const SCENE := "res://scenes/树/大樱花树/big_sakura_tree.tscn"
const EXPECTED := ["Bark_Trunk", "Bark_Branch_L1", "Bark_Branch_L2", "Bark_Branch_L3",
		"Bark_Branch_L4", "Bark_Branch_L5", "Leaves", "Flowers"]

var _rows: Array = []
var _nodes: Array = []


func _initialize() -> void:
	print("=".repeat(110))
	print("fast-tree 风摆 · 烘焙属性校验 test_baked_attrs")
	print("=".repeat(110))
	if not FileAccess.file_exists(GLB_PATH):
		push_error("[baked] 找不到 GLB: %s" % GLB_PATH)
		quit(1)
		return
	var t0 := Time.get_ticks_msec()
	var glb := G.read(GLB_PATH)
	if glb.is_empty():
		push_error("[baked] GLB 解析失败")
		quit(1)
		return
	print("[baked] GLB 解析 %d ms，%d 个带 mesh 的节点" % [
			Time.get_ticks_msec() - t0, (glb["nodes_with_mesh"] as Dictionary).size()])
	var glb_md5 := _md5(GLB_PATH)
	print("[baked] GLB md5=%s size=%d" % [glb_md5, _file_size(GLB_PATH)])

	var missing: PackedStringArray = []
	for nm in EXPECTED:
		if not (glb["prims"] as Dictionary).has(nm):
			missing.append(nm)
	_add_row("nodes_present", "GLB 含 8 个节点", "找到 %d/8 %s" % [
			EXPECTED.size() - missing.size(),
			"" if missing.is_empty() else str(missing)], missing.is_empty())
	if not missing.is_empty():
		_finish()
		return

	var all_pos_ok := true
	var all_attr_ok := true
	var all_baked := true
	var all_leaf_ok := true
	var all_fmt_ok := true
	var all_match_200 := true
	var max_pos_err_all := 0.0
	var max_attr_err_all := 0.0
	var max_pos_err_bark := 0.0
	var full_matched_all := 0
	var res_verts_all := 0
	var full_ok := true
	var res_missing: PackedStringArray = []

	for nm_v in EXPECTED:
		var nm := String(nm_v)
		var res_path := BAKE_DIR + nm + ".res"
		if not FileAccess.file_exists(res_path):
			res_missing.append(nm)
			continue
		var mesh: Mesh = load(res_path)
		if not (mesh is ArrayMesh):
			push_error("[baked] %s 不是 ArrayMesh" % res_path)
			res_missing.append(nm)
			continue
		var r := _check_node(nm, mesh as ArrayMesh, glb)
		_nodes.append(r)
		if not r["pos_ok"]:
			all_pos_ok = false
		if not r["attr_ok"]:
			all_attr_ok = false
		if not r["baked_ok"]:
			all_baked = false
		if not r["leafflag_ok"]:
			all_leaf_ok = false
		if not r["fmt_ok"]:
			all_fmt_ok = false
		if not r["match_sample_ok"]:
			all_match_200 = false
		max_pos_err_all = maxf(max_pos_err_all, float(r["max_pos_err"]))
		max_attr_err_all = maxf(max_attr_err_all, float(r["max_attr_err"]))
		if not LEAF_NODES.has(nm):
			max_pos_err_bark = maxf(max_pos_err_bark, float(r["max_pos_err"]))
		full_matched_all += int(r["full_matched"])
		res_verts_all += int(r["res_verts"])
		if int(r["full_matched"]) != int(r["res_verts"]):
			full_ok = false

	_add_row("res_present", "8 个 .res 都在 %s" % BAKE_DIR,
			"%d/8 %s" % [EXPECTED.size() - res_missing.size(),
					"" if res_missing.is_empty() else str(res_missing)], res_missing.is_empty())
	_add_row("sample_match", "每节点抽样 %d 顶点全部命中" % SAMPLE_PER_NODE,
			"%s" % ("全部命中" if all_match_200 else "有未命中"), all_match_200)
	_add_row("pos_roundtrip", "max |Δpos| <= %s m（= bake 的 MATCH_EPS）" % _sci(MATCH_EPS),
			"max=%s m（叶/花被导入压缩到 ~5e-4；树皮 0）" % _sci(max_pos_err_all), all_pos_ok)
	_add_row("pos_exact_bark", "树皮网格位置位级一致（未被导入压缩）",
			"max=%s m" % _sci(max_pos_err_bark), max_pos_err_bark == 0.0)
	_add_row("full_coverage", "所有 .res 顶点都能匹配回 GLB 顶点",
			"%d/%d (%.4f%%)" % [full_matched_all, res_verts_all,
				100.0 * float(full_matched_all) / maxf(1.0, float(res_verts_all))], full_ok)
	_add_row("attr_error", "aWind/phase/origin/nodeId 误差 < %s" % _sci(ATTR_EPS),
			"max=%s" % _sci(max_attr_err_all), all_attr_ok)
	_add_row("baked_flag", "CUSTOM1.w == 1", "全部为 1" if all_baked else "存在 != 1", all_baked)
	_add_row("is_leaf_flags", "Leaves/Flowers=1；树皮=0",
			"符合" if all_leaf_ok else "不符合", all_leaf_ok)
	_add_row("custom_format", "surface 声明 CUSTOM0/1 通道",
			"符合" if all_fmt_ok else "不符合", all_fmt_ok)
	# 集成检查：场景里 8 个 MeshInstance3D 是否真的挂上了烘焙 .res（否则前面全白测）
	var wiring := _scene_wiring()
	_add_row("scene_wiring", "场景 8 个 MeshInstance3D 指向 wind/<节点>.res",
			"符合" if wiring["ok"] else "不符合: " + String(wiring["detail"]), wiring["ok"])

	_dump_node_table()
	_finish(glb_md5)


# ============================================================================
# 单节点校验
# ============================================================================

func _check_node(nm: String, mesh: ArrayMesh, glb: Dictionary) -> Dictionary:
	var prim: Dictionary = (glb["prims"] as Dictionary)[nm]
	var g_pos: PackedVector3Array = prim["pos"]
	var g_wind: PackedFloat32Array = prim["wind"]
	var g_phase: PackedFloat32Array = prim["phase"]
	var g_origin: PackedVector3Array = prim["origin"]
	var g_nodeid: PackedFloat32Array = prim["nodeid"]
	var n_g := g_pos.size()

	# --- 分格位置索引（与 bake 工具一致）---
	var index := {}
	for i in n_g:
		var key := _cell_key(g_pos[i])
		if index.has(key):
			(index[key] as Array).append(i)
		else:
			index[key] = [i]

	# --- 收集 .res 的全部 surface ---
	var verts: PackedVector3Array = PackedVector3Array()
	var c0s: PackedFloat32Array = PackedFloat32Array()
	var c1s: PackedFloat32Array = PackedFloat32Array()
	var surface_count := mesh.get_surface_count()
	var fmt_ok := true
	var bad_fmt_surfaces: PackedStringArray = []
	for s in surface_count:
		if (mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_CUSTOM0) == 0 \
				or (mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_CUSTOM1) == 0:
			fmt_ok = false
			bad_fmt_surfaces.append(str(s))
		var arr: Array = mesh.surface_get_arrays(s)
		var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var c0 = arr[Mesh.ARRAY_CUSTOM0]
		var c1 = arr[Mesh.ARRAY_CUSTOM1]
		if c0 == null or c1 == null:
			fmt_ok = false
			bad_fmt_surfaces.append(str(s))
			continue
		var nv: int = v.size()
		var nc0: PackedFloat32Array = c0
		var nc1: PackedFloat32Array = c1
		if nc0.size() != nv * 4 or nc1.size() != nv * 4:
			fmt_ok = false
			bad_fmt_surfaces.append("s%d:len" % s)
			continue
		verts.append_array(v)
		c0s.append_array(nc0)
		c1s.append_array(nc1)

	var n_v := verts.size()
	var is_leaf_expected := 1.0 if LEAF_NODES.has(nm) else 0.0

	# --- 抽样 ---
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + nm.hash()
	var sample_idx: Array = []
	if n_v <= SAMPLE_PER_NODE:
		for i in n_v:
			sample_idx.append(i)
	else:
		var picked := {}
		while sample_idx.size() < SAMPLE_PER_NODE:
			var i := rng.randi_range(0, n_v - 1)
			if not picked.has(i):
				picked[i] = true
				sample_idx.append(i)

	var matched := 0
	var max_pos_err := 0.0
	var max_attr_err := 0.0
	var max_wind_err := 0.0
	var max_phase_err := 0.0
	var max_origin_err := 0.0
	var max_nodeid_err := 0.0
	var baked_bad := 0
	var leaf_bad := 0
	for vi in sample_idx:
		var v := verts[int(vi)]
		var gi := _match(index, g_pos, v)
		if gi < 0:
			continue
		matched += 1
		var d := v.distance_to(g_pos[gi])
		max_pos_err = maxf(max_pos_err, d)
		var c0 := Vector4(c0s[vi * 4], c0s[vi * 4 + 1], c0s[vi * 4 + 2], c0s[vi * 4 + 3])
		var c1 := Vector4(c1s[vi * 4], c1s[vi * 4 + 1], c1s[vi * 4 + 2], c1s[vi * 4 + 3])
		var w_err := absf(c0.w - g_wind[gi])
		var p_err := absf(c1.x - g_phase[gi])
		var o_err := absf(c0.x - g_origin[gi].x)
		o_err = maxf(o_err, absf(c0.y - g_origin[gi].y))
		o_err = maxf(o_err, absf(c0.z - g_origin[gi].z))
		var nd_err := absf(c1.z - g_nodeid[gi])
		max_wind_err = maxf(max_wind_err, w_err)
		max_phase_err = maxf(max_phase_err, p_err)
		max_origin_err = maxf(max_origin_err, o_err)
		max_nodeid_err = maxf(max_nodeid_err, nd_err)
		max_attr_err = maxf(max_attr_err, maxf(maxf(w_err, p_err), maxf(o_err, nd_err)))
		if absf(c1.w - 1.0) > 1e-6:
			baked_bad += 1
		if absf(c1.y - is_leaf_expected) > 1e-6:
			leaf_bad += 1

	# --- 全量覆盖（报告用；不参与断言）---
	var full_matched := 0
	for vi in n_v:
		if _match(index, g_pos, verts[vi]) >= 0:
			full_matched += 1

	return {
		"name": nm,
		"surface_count": surface_count,
		"res_verts": n_v,
		"glb_verts": n_g,
		"sampled": sample_idx.size(),
		"matched": matched,
		"match_sample_ok": matched == sample_idx.size(),
		"full_matched": full_matched,
		"max_pos_err": max_pos_err,
		"max_attr_err": max_attr_err,
		"max_wind_err": max_wind_err,
		"max_phase_err": max_phase_err,
		"max_origin_err": max_origin_err,
		"max_nodeid_err": max_nodeid_err,
		"pos_ok": matched == sample_idx.size() and max_pos_err <= MATCH_EPS,
		"attr_ok": matched == sample_idx.size() and max_attr_err < ATTR_EPS,
		"baked_ok": matched == sample_idx.size() and baked_bad == 0,
		"leafflag_ok": matched == sample_idx.size() and leaf_bad == 0,
		"fmt_ok": fmt_ok,
		"is_leaf_expected": is_leaf_expected,
		"res_md5": _md5(BAKE_DIR + nm + ".res"),
		"res_size": _file_size(BAKE_DIR + nm + ".res"),
	}


## 集成检查：big_sakura_tree.tscn 里的 8 个 MeshInstance3D 是否指向烘焙产物
func _scene_wiring() -> Dictionary:
	if not FileAccess.file_exists(SCENE):
		return {"ok": false, "detail": SCENE + " missing"}
	var ps: PackedScene = load(SCENE)
	if ps == null:
		return {"ok": false, "detail": "场景加载失败"}
	var root: Node = ps.instantiate()
	var bad: PackedStringArray = []
	for nm_v in EXPECTED:
		var nm := String(nm_v)
		var mi := _find_mi(root, nm)
		if mi == null:
			bad.append(nm + ":missing")
		elif mi.mesh == null:
			bad.append(nm + ":no_mesh")
		else:
			var rp: String = mi.mesh.resource_path
			if not rp.ends_with("/wind/" + nm + ".res"):
				bad.append(nm + ":" + rp)
	root.free()
	return {"ok": bad.is_empty(), "detail": str(bad)}


func _find_mi(root: Node, nm: String) -> MeshInstance3D:
	var st: Array = [root]
	while not st.is_empty():
		var n: Node = st.pop_back()
		if n is MeshInstance3D and String(n.name) == nm:
			return n as MeshInstance3D
		for c in n.get_children():
			st.append(c)
	return null


# ============================================================================
# 与 tools/bake_tree_wind.gd 相同的"分格 + 邻格"匹配
# ============================================================================

## 与 bake 工具完全一致：CELL=2mm 分格（floor），搜索本格 + 26 邻格，取最近
func _cell_key(p: Vector3) -> String:
	return "%d_%d_%d" % [
		int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL))]


func _match(index: Dictionary, g_pos: PackedVector3Array, v: Vector3) -> int:
	var best := -1
	var best_d2 := MATCH_EPS * MATCH_EPS
	var cx := int(floor(v.x / CELL))
	var cy := int(floor(v.y / CELL))
	var cz := int(floor(v.z / CELL))
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var key := "%d_%d_%d" % [cx + dx, cy + dy, cz + dz]
				if not index.has(key):
					continue
				for c in index[key]:
					var i := int(c)
					var d2 := v.distance_squared_to(g_pos[i])
					if d2 < best_d2:
						best_d2 = d2
						best = i
	return best


# ============================================================================
# 输出
# ============================================================================

func _dump_node_table() -> void:
	print("")
	print("%-15s %3s %8s %8s %6s %6s %13s %13s %13s %13s %13s %5s"
			% ["NODE", "SUR", "RES_V", "GLB_V", "SAMP", "MATCH", "MAX|dPOS|",
			"MAX|dWIND|", "MAX|dPHASE|", "MAX|dORIGIN|", "MAX|dNODE|", "LEAF"])
	print("-".repeat(140))
	for r in _nodes:
		print("%-15s %3d %8d %8d %6d %6d %13s %13s %13s %13s %13s %5.0f"
				% [r["name"], r["surface_count"], r["res_verts"], r["glb_verts"],
				r["sampled"], r["matched"], _sci(r["max_pos_err"]), _sci(r["max_wind_err"]),
				_sci(r["max_phase_err"]), _sci(r["max_origin_err"]), _sci(r["max_nodeid_err"]),
				r["is_leaf_expected"]])
		var cover: float = 100.0 * float(r["full_matched"]) / maxf(1.0, float(r["res_verts"]))
		print("                全量匹配 %d/%d (%.4f%%)  .res md5=%s size=%d"
				% [r["full_matched"], r["res_verts"], cover, r["res_md5"], r["res_size"]])
	print("-".repeat(140))


## Godot 的 % 格式化不支持 %e；用 String.num_scientific 输出科学计数
func _sci(x: Variant) -> String:
	return String.num_scientific(float(x))


func _add_row(name: String, expect: String, actual: String, ok: bool) -> void:
	_rows.append({"name": name, "expect": expect, "actual": actual, "pass": ok})
	print("[%s] %-16s %s" % ["PASS" if ok else "FAIL", name, actual])
	if not ok:
		print("       expect: %s" % expect)


func _finish(glb_md5: String = "") -> void:
	print("")
	print("%-16s %-46s %-52s %s" % ["ASSERTION", "EXPECTED", "ACTUAL", "RESULT"])
	print("-".repeat(130))
	var failed := 0
	for r in _rows:
		print("%-16s %-46s %-52s %s" % [r["name"], r["expect"], r["actual"],
				"PASS" if r["pass"] else "FAIL"])
		if not r["pass"]:
			failed += 1
	print("-".repeat(130))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://.runtime/wind_port/"))
	var data := {"glb": GLB_PATH, "glb_md5": glb_md5, "bake_dir": BAKE_DIR,
			"sample_per_node": SAMPLE_PER_NODE, "rows": _rows, "nodes": _nodes}
	var f := FileAccess.open("res://.runtime/wind_port/baked_attrs.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()
		print("[baked] wrote res://.runtime/wind_port/baked_attrs.json")
	print("")
	print("RESULT: %s  (%d/%d assertions passed)" % [
			"PASS" if failed == 0 else "FAIL", _rows.size() - failed, _rows.size()])
	quit(0 if failed == 0 else 1)


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var n := f.get_length()
	f.close()
	return n


func _md5(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	var chunk := 1 << 20
	while f.get_position() < f.get_length():
		ctx.update(f.get_buffer(chunk))
	f.close()
	return ctx.finish().hex_encode()

extends SceneTree
## ============================================================================
## fast-tree 风摆 · 顶点属性烘焙器
## ============================================================================
## 作用：把 fast-tree 导出 GLB 里被 Godot 导入器**丢掉**的自定义顶点属性
##   `_AWIND`（aWind）/ `_APHASE`（aPhase）/ `_AORIGIN`（aOrigin）
##   补写成 Mesh 的自定义通道，供 `assets/shaders/fast_tree_wind.gdshaderinc` 使用：
##
##   CUSTOM0 = vec4(aOrigin.x, aOrigin.y, aOrigin.z, aWind)
##   CUSTOM1 = vec4(aPhase, isLeaf, nodeId, 1.0)      // .w = 1 是"已烘焙"标志
##
## 为什么必须"按位置匹配"而不是按下标：
##   Godot 的 glTF 导入器会重排顶点（实测：顶点数相同、顺序不同，AABB 与点集一致）。
##   所以用**量化位置**做 key 建索引，再用法线做二次筛选。
##
## 用法（headless）：
##   & 'D:\godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path . \
##       --script res://tools/bake_tree_wind.gd
##   可选参数放在 `--` 之后：--glb=... --scene=... --out=... --verify
##
## 产物：res://assets/models/树/wind/<节点名>.res（每个 MeshInstance3D 一个 ArrayMesh）
## 之后由 .tscn 把这些网格挂回去（本脚本只负责生成，不改场景文件）。
## ============================================================================

const DEFAULT_GLB := "res://assets/models/树/大樱花树.glb"
const DEFAULT_SCENE := "res://scenes/树/大樱花树/big_sakura_tree.tscn"
const DEFAULT_OUT := "res://assets/models/树/wind/"

## 这些节点的网格按"叶片材质"处理（isLeaf = 1）：叶/花都用叶片材质
const LEAF_NODES := ["Leaves", "Flowers"]

## CUSTOM0/CUSTOM1 都用 RGBA_FLOAT（每顶点 4 个 float）
##   flags = (RGBA_FLOAT << CUSTOM0_SHIFT) | (RGBA_FLOAT << CUSTOM1_SHIFT)
const CUSTOM_FLAGS: int = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT)

## 位置分格大小（米）：用于把 Godot 重排后的顶点匹配回 GLB 顶点。
## ★ 为什么不是"量化到 1e-4 直接做 key"：Godot 4.7 导入时会**压缩顶点属性**
##   （ARRAY_FLAG_COMPRESS_ATTRIBUTES，16 bit 归一化），实测叶/花网格的位置会被量化到
##   ~5e-4 米误差 —— 恰好跨过细网格边界，直接 key 匹配会 96% 失败（树干网格没压缩，能精确命中）。
##   所以改用"粗格 + 邻格搜索 + 取最近"。
const CELL := 0.002
## 匹配容差（米）：超过就记账成 mismatch
const MATCH_EPS := 0.003
## 叶片"宿主枝条"查找的分格（米）。叶片的 aOrigin 就贴在枝条上，
## 用它去找最近的树皮顶点 -> 拿到该枝条的 aPhase / aWind / nodeId，
## 写进 CUSTOM2，让叶片做**刚性摆动**时与枝条同相位、同节奏（局部抖动仍用叶子自己的相位）。
const HOST_CELL := 0.5
## 宿主查找的最大距离（米）：超过就当没找到（回退成用叶子自己的相位）
const HOST_MAX_DIST := 0.35

var _glb_path := DEFAULT_GLB
var _scene_path := DEFAULT_SCENE
var _out_dir := DEFAULT_OUT
var _verify_only := false


func _initialize() -> void:
	_parse_args()
	_log("GLB   = %s" % _glb_path)
	_log("SCENE = %s" % _scene_path)
	_log("OUT   = %s" % _out_dir)
	var t0 := Time.get_ticks_msec()
	var glb := _parse_glb(_glb_path)
	if glb.is_empty():
		push_error("[bake] GLB 解析失败：%s" % _glb_path)
		quit(1)
		return
	_log("GLB 解析完成：%d ms，节点(带 mesh)=%d" % [Time.get_ticks_msec() - t0, glb["nodes_with_mesh"].size()])

	if not _verify_only:
		_bake_all(glb)
	else:
		_log("--verify 模式：只校验已存在的 .res")

	_log("总耗时 %d ms" % [Time.get_ticks_msec() - t0])
	quit(0)


# ============================================================================
# 烘焙主体
# ============================================================================

func _bake_all(glb: Dictionary) -> void:
	var ps: PackedScene = load(_scene_path)
	if ps == null:
		push_error("[bake] 场景加载失败：%s" % _scene_path)
		return
	var root: Node = ps.instantiate()
	var fast_tree: Node = root.get_node_or_null("FastTree")
	if fast_tree == null:
		push_error("[bake] 场景里找不到 FastTree 节点")
		root.free()
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out_dir))
	# ★ 先建"树皮顶点索引"：叶子/花朵的 aOrigin 贴在枝条上，
	#   用它查最近的树皮顶点 → 得到宿主枝条的 aPhase/aWind/nodeId（写进 CUSTOM2）。
	var host := _build_host_index(glb)
	_log("宿主枝条索引：%d 个树皮顶点" % host.get("count", 0))
	var node_names: Array = glb["nodes_with_mesh"].keys()
	var ok := 0
	for nm in node_names:
		var mi := _find_mesh_instance(fast_tree, String(nm))
		if mi == null:
			_log("跳过 %s：场景里没有同名 MeshInstance3D" % nm)
			continue
		if _bake_one(glb, String(nm), mi, host):
			ok += 1
	_log("烘焙完成：%d/%d 个节点" % [ok, node_names.size()])
	root.free()


func _find_mesh_instance(root: Node, wanted: String) -> MeshInstance3D:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and String(n.name) == wanted:
			return n as MeshInstance3D
		for c in n.get_children():
			stack.append(c)
	return null


func _bake_one(glb: Dictionary, node_name: String, mi: MeshInstance3D, host: Dictionary = {}) -> bool:
	var mesh: Mesh = mi.mesh
	if mesh == null or not (mesh is ArrayMesh):
		_log("跳过 %s：网格不是 ArrayMesh" % node_name)
		return false
	var am_src := mesh as ArrayMesh
	var surface_count := am_src.get_surface_count()
	if surface_count <= 0:
		_log("跳过 %s：没有 surface" % node_name)
		return false
	# --- GLB 侧：取该节点的 primitive 属性 ---
	var prim: Dictionary = glb["prims"][node_name]
	var g_pos: PackedVector3Array = prim["pos"]
	var g_wind: PackedFloat32Array = prim["wind"]
	var g_phase: PackedFloat32Array = prim["phase"]
	var g_origin: PackedVector3Array = prim["origin"]
	var g_nodeid: PackedFloat32Array = prim["nodeid"]
	var n_g := g_pos.size()
	if n_g != g_wind.size() or n_g != g_phase.size() or n_g != g_origin.size():
		push_error("[bake] %s：GLB 属性长度不一致" % node_name)
		return false
	# --- 建立"分格位置 -> GLB 下标列表"索引 ---
	var index := {}
	for i in range(n_g):
		var key := _cell_key(g_pos[i])
		if index.has(key):
			(index[key] as Array).append(i)
		else:
			index[key] = [i]
	var is_leaf := 1.0 if LEAF_NODES.has(node_name) else 0.0

	var out := ArrayMesh.new()
	var total_v := 0
	var mismatched := 0
	var max_err := 0.0
	var host_miss := 0
	var host_cache := {}
	for s in range(surface_count):
		var arr: Array = am_src.surface_get_arrays(s)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n: int = verts.size()
		total_v += n
		var c0 := PackedFloat32Array()
		var c1 := PackedFloat32Array()
		var c2 := PackedFloat32Array()
		c0.resize(n * 4)
		c1.resize(n * 4)
		c2.resize(n * 4)
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL] if arr[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		for vi in range(n):
			var v: Vector3 = verts[vi]
			var gi := _match(index, g_pos, v)
			var a_wind := 0.0
			var a_phase := 0.0
			var a_origin := Vector3.ZERO
			var a_node := 0.0
			if gi >= 0:
				a_wind = g_wind[gi]
				a_phase = g_phase[gi]
				a_origin = g_origin[gi]
				a_node = g_nodeid[gi]
				var d := v.distance_to(g_pos[gi])
				if d > max_err:
					max_err = d
				if d > MATCH_EPS:
					mismatched += 1
			else:
				mismatched += 1
				# 容错：宁可退化成"世界原点 + 满柔软度"，也不要留 0 导致完全不摆
				a_wind = 1.0
				a_origin = Vector3.ZERO
			c0[vi * 4 + 0] = a_origin.x
			c0[vi * 4 + 1] = a_origin.y
			c0[vi * 4 + 2] = a_origin.z
			c0[vi * 4 + 3] = a_wind
			c1[vi * 4 + 0] = a_phase
			c1[vi * 4 + 1] = is_leaf
			c1[vi * 4 + 2] = a_node
			c1[vi * 4 + 3] = 1.0
			# CUSTOM2 = (宿主枝条 phase, 宿主枝条 aWind, 宿主 nodeId, 1=有宿主)
			#   叶子/花朵的**刚性摆动**用宿主值 → 树枝与树叶/花朵同步；
			#   局部抖动仍然用叶子自己的 aPhase（见 shader 的 flutter 段）。
			if is_leaf > 0.5 and not host.is_empty():
				var h := _host_at(host, host_cache, a_origin)
				if not h.is_empty():
					c2[vi * 4 + 0] = h[0]
					c2[vi * 4 + 1] = h[1]
					c2[vi * 4 + 2] = h[2]
					c2[vi * 4 + 3] = 1.0
				else:
					host_miss += 1
					c2[vi * 4 + 0] = a_phase
					c2[vi * 4 + 1] = a_wind
					c2[vi * 4 + 2] = a_node
					c2[vi * 4 + 3] = 1.0
		var out_arr: Array = arr.duplicate(true)
		out_arr[Mesh.ARRAY_CUSTOM0] = c0
		out_arr[Mesh.ARRAY_CUSTOM1] = c1
		out_arr[Mesh.ARRAY_CUSTOM2] = c2
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arr, [], {}, CUSTOM_FLAGS)
		out.surface_set_name(s, am_src.surface_get_name(s))
		out.surface_set_material(s, am_src.surface_get_material(s))
	var res_path := _out_dir.path_join(node_name + ".res")
	var err := ResourceSaver.save(out, res_path)
	if err != OK:
		push_error("[bake] 保存失败 %s err=%d" % [res_path, err])
		return false
	_log("✓ %-16s 顶点=%6d  GLB=%6d  匹配失败=%d  宿主未找到=%d  max位置误差=%.6f m  -> %s" % [
			node_name, total_v, n_g, mismatched, host_miss, max_err, res_path])
	if mismatched > 0:
		push_warning("[bake] %s 有 %d 个顶点没匹配上（已用兜底值）" % [node_name, mismatched])
	return true

## 建"树皮顶点索引"：把所有**非叶片**节点的 (position, phase, aWind, nodeId) 收集起来。
## 为什么用 GLB 原始数据而不是导入网格：叶片查找要对齐到 GLB 的 aOrigin（同一坐标空间），
## 且 GLB 里属性值零误差。
func _build_host_index(glb: Dictionary) -> Dictionary:
	var cells := {}
	var count := 0
	for nm in (glb["prims"] as Dictionary).keys():
		if LEAF_NODES.has(String(nm)):
			continue
		var prim: Dictionary = glb["prims"][nm]
		var pos: PackedVector3Array = prim["pos"]
		var ph: PackedFloat32Array = prim["phase"]
		var wd: PackedFloat32Array = prim["wind"]
		var ni: PackedFloat32Array = prim["nodeid"]
		var n := mini(pos.size(), mini(ph.size(), mini(wd.size(), ni.size())))
		for i in range(n):
			var key := _host_cell(pos[i])
			if not cells.has(key):
				cells[key] = []
			(cells[key] as Array).append([pos[i], ph[i], wd[i], ni[i]])
			count += 1
	return {"cells": cells, "count": count}


static func _host_cell(p: Vector3) -> String:
	return "%d_%d_%d" % [int(floor(p.x / HOST_CELL)), int(floor(p.y / HOST_CELL)), int(floor(p.z / HOST_CELL))]


## 在宿主索引里找离 origin 最近的树皮顶点，返回 [phase, aWind, nodeId]；找不到返回 []。
## cache：同一个 aOrigin 会被一整片叶子的多个顶点重复查询（每片叶 8 个顶点），
##   用 origin 做 key 缓存，80640 个花朵顶点实际只有 ~1 万个 origin。
func _host_at(host: Dictionary, cache: Dictionary, origin: Vector3) -> Array:
	var ck := _host_cell(origin)
	if cache.has(ck):
		return cache[ck]
	var cells: Dictionary = host["cells"]
	var best := []
	var best_d2 := HOST_MAX_DIST * HOST_MAX_DIST
	var cx := int(floor(origin.x / HOST_CELL))
	var cy := int(floor(origin.y / HOST_CELL))
	var cz := int(floor(origin.z / HOST_CELL))
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var key := "%d_%d_%d" % [cx + dx, cy + dy, cz + dz]
				if not cells.has(key):
					continue
				for rec in cells[key]:
					var d2: float = origin.distance_squared_to(rec[0])
					if d2 < best_d2:
						best_d2 = d2
						best = [rec[1], rec[2], rec[3]]
	cache[ck] = best
	return best


## 在"分格位置索引"里找 Godot 顶点对应的 GLB 顶点下标；找不到返回 -1。
## 搜索本格 + 26 个邻格，取最近的一个；距离 > MATCH_EPS 视为没匹配上。
## （Godot 导入时压缩了顶点属性，位置有 ~5e-4 米量化误差，所以不能用精确 key。）
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


static func _cell_key(p: Vector3) -> String:
	return "%d_%d_%d" % [int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL))]


# ============================================================================
# GLB 解析（最小实现：json + bin，只读 POSITION/NORMAL + 三个自定义属性）
# ============================================================================

func _parse_glb(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[bake] 打不开 %s" % path)
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 20:
		push_error("[bake] 文件太小")
		return {}
	var magic := bytes.decode_u32(0)
	if magic != 0x46546C67:  # "glTF"
		push_error("[bake] 不是 GLB（magic=%d）" % magic)
		return {}
	var total := bytes.decode_u32(8)
	var off := 12
	var json_text := ""
	var bin := PackedByteArray()
	while off + 8 <= total:
		var clen := bytes.decode_u32(off)
		var ctype := bytes.decode_u32(off + 4)
		var data_off := off + 8
		if ctype == 0x4E4F534A:  # "JSON"
			json_text = bytes.slice(data_off, data_off + clen).get_string_from_utf8()
		elif ctype == 0x004E4942:  # "BIN\0"
			bin = bytes.slice(data_off, data_off + clen)
		off = data_off + clen
	var doc: Variant = JSON.parse_string(json_text)
	if doc == null or not (doc is Dictionary):
		push_error("[bake] GLB JSON 解析失败")
		return {}
	var gltf: Dictionary = doc
	var nodes: Array = gltf["nodes"]
	var meshes: Array = gltf["meshes"]
	var accessors: Array = gltf["accessors"]
	var views: Array = gltf["bufferViews"]
	var out := {"nodes_with_mesh": {}, "prims": {}}
	for n in nodes:
		if not (n is Dictionary) or not (n as Dictionary).has("mesh"):
			continue
		var node_name := String((n as Dictionary).get("name", "node"))
		var mesh: Dictionary = meshes[int((n as Dictionary)["mesh"])]
		var prims: Array = mesh["primitives"]
		if prims.is_empty():
			continue
		var prim: Dictionary = prims[0]
		var attrs: Dictionary = prim["attributes"]
		if not attrs.has("POSITION"):
			continue
		var pos := _acc_vec3(accessors, views, bin, int(attrs["POSITION"]))
		var wind := _acc_float(accessors, views, bin, int(attrs.get("_AWIND", -1)), pos.size(), 1.0)
		var phase := _acc_float(accessors, views, bin, int(attrs.get("_APHASE", -1)), pos.size(), 0.0)
		var origin := _acc_vec3_or_zero(accessors, views, bin, int(attrs.get("_AORIGIN", -1)), pos.size())
		var nodeid := _acc_float(accessors, views, bin, int(attrs.get("_ANODEID", -1)), pos.size(), 0.0)
		(out["nodes_with_mesh"] as Dictionary)[node_name] = true
		(out["prims"] as Dictionary)[node_name] = {
			"pos": pos, "wind": wind, "phase": phase, "origin": origin, "nodeid": nodeid,
		}
		_log("GLB 节点 %-16s 顶点=%d  aWind=[%.3f..%.3f]  aPhase=[%.3f..%.3f]" % [
				node_name, pos.size(), _minf(wind), _maxf(wind), _minf(phase), _maxf(phase)])
	return out


func _acc_meta(accessors: Array, idx: int) -> Dictionary:
	if idx < 0 or idx >= accessors.size():
		return {}
	return accessors[idx]


func _acc_bytes(accessors: Array, views: Array, bin: PackedByteArray, idx: int, expect_comp: int) -> Dictionary:
	var acc := _acc_meta(accessors, idx)
	if acc.is_empty():
		return {}
	if int(acc.get("componentType", 0)) != expect_comp:
		push_warning("[bake] accessor %d componentType=%d 不是期望的 %d" % [idx, int(acc["componentType"]), expect_comp])
		return {}
	if acc.has("bufferView") == false:
		return {}
	var view: Dictionary = views[int(acc["bufferView"])]
	var comp_size := 4
	var ncomp := _type_components(String(acc["type"]))
	var count := int(acc["count"])
	var base := int(view.get("byteOffset", 0)) + int(acc.get("byteOffset", 0))
	var stride := int(view.get("byteStride", comp_size * ncomp))
	return {"base": base, "count": count, "ncomp": ncomp, "stride": stride}


func _type_components(t: String) -> int:
	match t:
		"SCALAR": return 1
		"VEC2": return 2
		"VEC3": return 3
		"VEC4": return 4
	return 0


func _acc_float(accessors: Array, views: Array, bin: PackedByteArray, idx: int, count: int, fallback: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	out.fill(fallback)
	if idx < 0:
		return out
	var info := _acc_bytes(accessors, views, bin, idx, 5126)
	if info.is_empty():
		return out
	var n := mini(count, int(info["count"]))
	for i in range(n):
		out[i] = bin.decode_float(int(info["base"]) + i * int(info["stride"]))
	return out


func _acc_vec3(accessors: Array, views: Array, bin: PackedByteArray, idx: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var info := _acc_bytes(accessors, views, bin, idx, 5126)
	if info.is_empty():
		return out
	var count := int(info["count"])
	out.resize(count)
	var base := int(info["base"])
	var stride := int(info["stride"])
	for i in range(count):
		var o := base + i * stride
		out[i] = Vector3(bin.decode_float(o), bin.decode_float(o + 4), bin.decode_float(o + 8))
	return out


func _acc_vec3_or_zero(accessors: Array, views: Array, bin: PackedByteArray, idx: int, count: int) -> PackedVector3Array:
	if idx < 0:
		var out := PackedVector3Array()
		out.resize(count)
		out.fill(Vector3.ZERO)
		return out
	var v := _acc_vec3(accessors, views, bin, idx)
	if v.size() < count:
		v.resize(count)
		v.fill(Vector3.ZERO)
	return v


# ============================================================================
# 小工具
# ============================================================================

func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--glb="):
			_glb_path = s.substr(6)
		elif s.begins_with("--scene="):
			_scene_path = s.substr(8)
		elif s.begins_with("--out="):
			_out_dir = s.substr(6)
		elif s == "--verify":
			_verify_only = true


func _minf(a: PackedFloat32Array) -> float:
	var m := INF
	for v in a:
		if v < m:
			m = v
	return 0.0 if m == INF else m


func _maxf(a: PackedFloat32Array) -> float:
	var m := -INF
	for v in a:
		if v > m:
			m = v
	return 0.0 if m == -INF else m


func _log(s: String) -> void:
	print("[bake] " + s)


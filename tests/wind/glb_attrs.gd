extends RefCounted
class_name GlbAttrs
## ============================================================================
## 最小 GLB 属性读取器（验证用；**只读**，与 tools/bake_tree_wind.gd 的读法一致）
## ============================================================================
## 只解这个项目需要的东西：JSON chunk + BIN chunk，按 accessor 读
## POSITION / NORMAL / _AWIND / _APHASE / _AORIGIN / _ANODEID。
##
## ⚠ 与 bake 工具保持同一约定：每个 mesh 只取 `primitives[0]`（本 GLB 实测每个 mesh
##    只有 1 个 primitive，见 docs/wind-port-verification.md 的"已知限制"）。
##
## 用法：
##   const G := preload("res://tests/wind/glb_attrs.gd")
##   var glb := G.read("res://assets/models/树/大樱花树.glb")
##   glb["prims"]["Leaves"]["wind"]  # PackedFloat32Array
## ============================================================================

const MAGIC_GLTF := 0x46546C67
const CHUNK_JSON := 0x4E4F534A
const CHUNK_BIN := 0x004E4942
const COMP_FLOAT := 5126


## 返回 { nodes_with_mesh: {name: true}, prims: {name: {pos, normal, wind, phase, origin, nodeid,
##        prim_count, attrs} } }
static func read(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[glb] 打不开 %s" % path)
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 20:
		push_error("[glb] 文件太小: %s" % path)
		return {}
	if bytes.decode_u32(0) != MAGIC_GLTF:
		push_error("[glb] 不是 GLB: %s" % path)
		return {}
	var total: int = mini(bytes.decode_u32(8), bytes.size())
	var off := 12
	var json_text := ""
	var bin := PackedByteArray()
	while off + 8 <= total:
		var clen := bytes.decode_u32(off)
		var ctype := bytes.decode_u32(off + 4)
		var data_off := off + 8
		if ctype == CHUNK_JSON:
			json_text = bytes.slice(data_off, data_off + clen).get_string_from_utf8()
		elif ctype == CHUNK_BIN:
			bin = bytes.slice(data_off, data_off + clen)
		off = data_off + clen
	var doc: Variant = JSON.parse_string(json_text)
	if doc == null or not (doc is Dictionary):
		push_error("[glb] JSON 解析失败: %s" % path)
		return {}
	var gltf: Dictionary = doc
	var nodes: Array = gltf.get("nodes", [])
	var meshes: Array = gltf.get("meshes", [])
	var accessors: Array = gltf.get("accessors", [])
	var views: Array = gltf.get("bufferViews", [])
	var out := {"nodes_with_mesh": {}, "prims": {}}
	for n in nodes:
		if not (n is Dictionary) or not (n as Dictionary).has("mesh"):
			continue
		var nd: Dictionary = n
		var node_name := String(nd.get("name", "node"))
		var mesh: Dictionary = meshes[int(nd["mesh"])]
		var prims: Array = mesh.get("primitives", [])
		if prims.is_empty():
			continue
		var prim: Dictionary = prims[0]
		var attrs: Dictionary = prim.get("attributes", {})
		if not attrs.has("POSITION"):
			continue
		var pos := _acc_vec3(accessors, views, bin, int(attrs["POSITION"]))
		var normal := _acc_vec3_or(accessors, views, bin, int(attrs.get("NORMAL", -1)), pos.size(), Vector3.ZERO)
		var wind := _acc_float(accessors, views, bin, int(attrs.get("_AWIND", -1)), pos.size(), 0.0)
		var phase := _acc_float(accessors, views, bin, int(attrs.get("_APHASE", -1)), pos.size(), 0.0)
		var origin := _acc_vec3_or(accessors, views, bin, int(attrs.get("_AORIGIN", -1)), pos.size(), Vector3.ZERO)
		var nodeid := _acc_float(accessors, views, bin, int(attrs.get("_ANODEID", -1)), pos.size(), 0.0)
		(out["nodes_with_mesh"] as Dictionary)[node_name] = true
		(out["prims"] as Dictionary)[node_name] = {
			"pos": pos,
			"normal": normal,
			"wind": wind,
			"phase": phase,
			"origin": origin,
			"nodeid": nodeid,
			"prim_count": prims.size(),
			"attrs": attrs.duplicate(),
		}
	return out


# ============================================================================
# accessor 解码
# ============================================================================

static func _type_components(t: String) -> int:
	match t:
		"SCALAR":
			return 1
		"VEC2":
			return 2
		"VEC3":
			return 3
		"VEC4":
			return 4
	return 0


static func _acc_layout(accessors: Array, views: Array, idx: int, expect_comp: int) -> Dictionary:
	if idx < 0 or idx >= accessors.size():
		return {}
	var acc: Dictionary = accessors[idx]
	if int(acc.get("componentType", 0)) != expect_comp:
		push_warning("[glb] accessor %d componentType=%d != %d" % [
				idx, int(acc.get("componentType", 0)), expect_comp])
		return {}
	if not acc.has("bufferView"):
		return {}
	var view: Dictionary = views[int(acc["bufferView"])]
	var ncomp := _type_components(String(acc["type"]))
	if ncomp <= 0:
		return {}
	var comp_size := 4
	return {
		"base": int(view.get("byteOffset", 0)) + int(acc.get("byteOffset", 0)),
		"count": int(acc["count"]),
		"ncomp": ncomp,
		"stride": int(view.get("byteStride", comp_size * ncomp)),
	}


static func _acc_float(accessors: Array, views: Array, bin: PackedByteArray, idx: int,
		count: int, fallback: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	out.fill(fallback)
	var info := _acc_layout(accessors, views, idx, COMP_FLOAT)
	if info.is_empty():
		return out
	var n: int = mini(count, int(info["count"]))
	for i in n:
		out[i] = bin.decode_float(int(info["base"]) + i * int(info["stride"]))
	return out


static func _acc_vec3(accessors: Array, views: Array, bin: PackedByteArray, idx: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var info := _acc_layout(accessors, views, idx, COMP_FLOAT)
	if info.is_empty():
		return out
	var count := int(info["count"])
	out.resize(count)
	var base := int(info["base"])
	var stride := int(info["stride"])
	for i in count:
		var o := base + i * stride
		out[i] = Vector3(bin.decode_float(o), bin.decode_float(o + 4), bin.decode_float(o + 8))
	return out


static func _acc_vec3_or(accessors: Array, views: Array, bin: PackedByteArray, idx: int,
		count: int, fallback: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(count)
	out.fill(fallback)
	if idx < 0:
		return out
	var v := _acc_vec3(accessors, views, bin, idx)
	var n: int = mini(count, v.size())
	for i in n:
		out[i] = v[i]
	return out

@tool
extends RefCounted
## 把 .blend 场景里的若干 MeshInstance3D 导出成 .tscn。
##
## 两个关键点（都是从实际使用里踩出来的）：
##  1. 材质**按名字回链项目里已有的贴图**（diff/nor/rough/alpha，含 textures/ 子目录），
##     导出的是**共享材质 .tres**，贴图一个字节都不复制。
##  2. 如果找到了 alpha 遮罩图 -> 用自带的 shader（图集常见黑底，标准材质没有单独
##     alpha 槽位，不接遮罩就会露出黑色多边形）。

const SHADER_PATH := "res://assets/shaders/grass_wind.gdshader"   # 运行时资产放 assets，不放插件内

## 「初始化风参数」勾上时要写进材质的初始风值（对齐游戏晴朗天气预设）
const WIND_INIT := {
	"wind_direction": Vector2(1.0, 0.0),
	"wind_strength": 0.18,
	"wind_gust": 0.15,
	"wind_speed": 1.4,
	"wind_turbulence": 0.30,
}

## nodes: Array[MeshInstance3D] ｜ out_path: .tscn 路径（单个）或目录（每个一个文件）
## 返回 { ok, message, files }
static func export_nodes(nodes: Array, out_path: String, single_file: bool, init_wind: bool = true, shader_path: String = SHADER_PATH) -> Dictionary:
	var valid: Array = []
	for n in nodes:
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			valid.append(n)
	if valid.is_empty():
		return {"ok": false, "message": "没有可导出的网格", "files": []}

	var out_dir := out_path.get_base_dir() if single_file else out_path
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))

	# 源目录：材质贴图就在 .blend 旁边（或它的 textures/ 子目录里）
	var src_dir := ""
	if valid[0].has_meta("blend_src"):
		src_dir = String(valid[0].get_meta("blend_src"))
	var mat_cache := {}
	var files: Array = []

	if single_file:
		var built := _build_scene(valid, src_dir, out_dir, mat_cache, true, init_wind, shader_path)
		var err := ResourceSaver.save(built["packed"], out_path)
		built["root"].free()
		if err != OK:
			return {"ok": false, "message": "保存失败（错误码 %d）：%s" % [err, out_path], "files": []}
		files.append(out_path)
	else:
		for n in valid:
			var one: Array = [n]
			var built := _build_scene(one, src_dir, out_dir, mat_cache, false, init_wind, shader_path)
			var p := out_dir.path_join(_safe(String(n.name)) + ".tscn")
			var err := ResourceSaver.save(built["packed"], p)
			built["root"].free()
			if err == OK:
				files.append(p)

	if files.is_empty():
		return {"ok": false, "message": "没有写出任何文件", "files": []}
	return {"ok": true, "message": "已导出 %d 个文件（共享材质 %d 个）" % [files.size(), mat_cache.size()], "files": files}


static func _build_scene(nodes: Array, src_dir: String, out_dir: String, mat_cache: Dictionary, single: bool, init_wind: bool = true, shader_path: String = SHADER_PATH) -> Dictionary:
	var root := Node3D.new()
	# 根节点名要有意义：单个对象就用对象名，多个对象就用第一个对象名 + _group。
	# 之前固定叫 BlendExport -> World Brush 会把它当实例名，场景树里就变成
	# BlendExport / BlendExport5 / BlendExport20 一堆，完全看不出是什么。
	if nodes.size() == 1:
		root.name = _safe(String((nodes[0] as MeshInstance3D).name))
	else:
		root.name = "%s_group" % _safe(String((nodes[0] as MeshInstance3D).name))
	var packed_mat := {}
	for n in nodes:
		var mi := (n as MeshInstance3D)
		# 材质要从**原始**网格上读：预览窗口会把 mi.mesh 换成"带贴图的副本"，
		# 那份副本的材质是内存对象（没有 resource_name / 贴图路径）-> 回链不到贴图 -> 导出成灰模型。
		var src_mesh: Mesh = mi.mesh
		var om = mi.get_meta("blend_orig_mesh", null)
		if om is Mesh:
			src_mesh = om
		# 复制网格再改材质（不复制的话，原地 surface_set_material 会把预览一起改掉）
		var mesh: Mesh = (src_mesh as Mesh).duplicate(true)
		# 材质：按源材质缓存成"导出用共享材质"
		for s in range(mesh.get_surface_count()):
			var src := mesh.surface_get_material(s)
			var key := _mat_key(src)
			if not mat_cache.has(key):
				var built := _build_material(src, src_dir, out_dir, key, init_wind, shader_path)
				mat_cache[key] = built
			mesh.surface_set_material(s, mat_cache[key])
		var copy := MeshInstance3D.new()
		copy.name = _safe(String(mi.name))
		copy.mesh = mesh
		# ★ 轴心归位。不依赖 blend 里的任何变换，直接按网格自身的包围盒算：
		#   轴心 = (包围盒 x/z 中心, 包围盒底面 y)
		# 每个对象单独导出时必须归位，否则会带上它在 blend 场景里的摆放偏移
		# （实测 small_f 的局部平移是 -0.280875、single_a 是 +0.916435 -> 就是"中心坐标不正确"）；
		# 合成一个文件时保留 global_transform，这样多个对象之间的相对位置还在。
		if single:
			# 合成一个文件：要保留 blend 里的相对布局。
			# 注意用**局部**变换：实测这些对象的 global_transform 平移全是 (0,0,0)，
			# 用它会把所有对象叠在原点（实测 X 间距只有 0.0106，本该 ~1.3）。
			copy.transform = mi.transform
		else:
			var bb := mesh.get_aabb()
			var pivot := Vector3(bb.get_center().x, bb.position.y, bb.get_center().z)
			copy.transform = Transform3D(Basis(), -pivot)
		root.add_child(copy)
		copy.owner = root
	# 合成模式：把整片草整体平移到"脚底中心在原点"，方便直接摆到场景里
	if single and root.get_child_count() > 0:
		var merged := AABB()
		var first := true
		for ch in root.get_children():
			var cmi := ch as MeshInstance3D
			if cmi == null or cmi.mesh == null:
				continue
			var bb2 := cmi.mesh.get_aabb()
			for i in range(8):
				var w: Vector3 = cmi.transform * bb2.get_endpoint(i)
				if first:
					merged = AABB(w, Vector3.ZERO)
					first = false
				else:
					merged = merged.expand(w)
		if not first:
			var off := Vector3(merged.get_center().x, merged.position.y, merged.get_center().z)
			root.position = -off
	var ps := PackedScene.new()
	ps.pack(root)
	return {"packed": ps, "root": root, "mats": packed_mat}


static func _mat_key(m: Material) -> String:
	if m == null:
		return "__none__"
	if not m.resource_path.is_empty():
		return String(m.resource_path)
	if not m.resource_name.is_empty():
		return String(m.resource_name)
	# 无名材质：不要用实例ID（会生成 _blend_mat_-9223...tres 这种鬼名字）
	return "__unnamed__"


## 造导出用材质：优先用源材质里已经接好的图；没接就按名字在磁盘上找
static func _build_material(src: Material, src_dir: String, out_dir: String, key: String, init_wind: bool = true, shader_path: String = SHADER_PATH) -> Material:
	var base := ""
	var albedo: Texture2D = null
	var normal: Texture2D = null
	var rough: Texture2D = null
	if src is StandardMaterial3D:
		var sm := src as StandardMaterial3D
		base = String(sm.resource_name)
		albedo = sm.albedo_texture
		normal = sm.normal_texture
		rough = sm.roughness_texture
	if base.is_empty():
		base = key.get_file().get_basename() if key.contains("/") else key
	if base.is_empty():
		base = "material"

	# 名字回链（源目录 + textures/ 子目录）
	if src_dir != "":
		if albedo == null:
			albedo = _load_tex(_find_tex(src_dir, base, ["diff", "albedo", "col", "_d."]))
		if normal == null:
			normal = _load_tex(_find_tex(src_dir, base, ["nor", "normal", "_n."]))
		if rough == null:
			rough = _load_tex(_find_tex(src_dir, base, ["rough", "_r.", "rma"]))
	var alpha := _load_tex(_find_tex(src_dir, base, ["alpha", "mask", "_a."])) if src_dir != "" else null

	var mat: Material
	var tr := _transparency_of(src)
	if alpha != null:
		# 有遮罩 -> 用自带 shader（解决图集黑底）
		# 用调用方选的 shader（面板上可换）；没选/载入失败就退回默认
		var sh: Shader = load(shader_path)
		if sh == null:
			sh = load(SHADER_PATH)
		if sh != null:
			var shm := ShaderMaterial.new()
			shm.shader = sh
			shm.set_shader_parameter("albedo_tex", albedo)
			shm.set_shader_parameter("alpha_tex", alpha)
			shm.set_shader_parameter("normal_tex", normal)
			shm.set_shader_parameter("rough_tex", rough)
			shm.set_shader_parameter("alpha_scissor", 0.5)
			shm.set_shader_parameter("has_normal", normal != null)
			# 风：只有勾了「初始化风参数」才写；不勾 -> wind_enabled 保持 shader 默认的 false -> 这株草没风
			shm.set_shader_parameter("wind_enabled", init_wind)
			if init_wind:
				for k in WIND_INIT.keys():
					shm.set_shader_parameter(String(k), WIND_INIT[k])
			mat = shm
	if mat == null:
		var sm2 := StandardMaterial3D.new()
		sm2.albedo_texture = albedo
		if normal != null:
			sm2.normal_enabled = true
			sm2.normal_texture = normal
		sm2.roughness_texture = rough
		if rough != null:
			sm2.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE
		sm2.roughness = 1.0
		sm2.metallic = 0.0
		sm2.cull_mode = BaseMaterial3D.CULL_DISABLED if tr else BaseMaterial3D.CULL_BACK
		mat = sm2
	mat.resource_name = base
	var mp := out_dir.path_join("_blend_mat_%s.tres" % _safe(base))
	if ResourceSaver.save(mat, mp) == OK:
		var reloaded: Material = load(mp)
		if reloaded != null:
			return reloaded
	return mat


static func _transparency_of(src: Material) -> bool:
	if src is StandardMaterial3D:
		var sm := src as StandardMaterial3D
		return sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED or sm.cull_mode == BaseMaterial3D.CULL_DISABLED
	return false


## 同名贴图常有 1k/2k/4k 多个版本 -> 优先取分辨率最高的（没有标记的算最高）
static func _res_rank(f: String) -> int:
	var low := f.to_lower()
	if low.find("4k") >= 0:
		return 4
	if low.find("2k") >= 0:
		return 2
	if low.find("1k") >= 0:
		return 1
	return 3


## 在 dir / dir/textures 里按"基础名 + 关键字"找贴图（跳过 .import 边车），同名取最高分辨率
static func _find_tex(dir: String, base: String, keys: Array) -> String:
	if dir == "" or base == "":
		return ""
	var best := ""
	var best_rank := -1
	for sub in ["", "textures"]:
		var d := dir.path_join(sub) if sub != "" else dir
		var da := DirAccess.open(d)
		if da == null:
			continue
		da.list_dir_begin()
		var f := da.get_next()
		while f != "":
			if not da.current_is_dir() and not f.ends_with(".import") and not f.ends_with(".blend"):
				var low := f.to_lower()
				if low.begins_with(base.to_lower()):
					for k in keys:
						if low.find(String(k)) >= 0:
							var rank := _res_rank(f)
							if rank > best_rank:
								best_rank = rank
								best = d.path_join(f)
							break
			f = da.get_next()
		da.list_dir_end()
	return best


static func _load_tex(p: String) -> Texture2D:
	if p == "" or not ResourceLoader.exists(p):
		return null
	var r = load(p)
	return r as Texture2D


static func _safe(raw: String) -> String:
	var out := ""
	for ch in raw:
		out += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch == "-" or ch == "_") else "_"
	return out if not out.is_empty() else "node"
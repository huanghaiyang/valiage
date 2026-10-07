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
## ratio：导出时**减面比例** ✓（1.0 = 不减面 ✓ 默认；<1.0 走"临时 GLB → npx gltf-transform simplify → 读回" ✓）
static func export_nodes(nodes: Array, out_path: String, single_file: bool, init_wind: bool = true, shader_path: String = SHADER_PATH, ratio: float = 1.0) -> Dictionary:
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
	# ★ 减面比例（唯一入口）：记在静态变量上 ✓ → `_build_scene()` 里对**原始网格**做减面 ✓
	#   实现见 `_decimate_mesh(src, ratio, mi)` ✓ —— **只借预览窗口里那个真实的 MeshInstance3D** ✓
	#   （✗ 不自建游离子树；✗ 不在源目录找 glb —— 那两套废弃方案已无调用点 ✓）
	_ratio = ratio
	var files: Array = []

	if single_file:
		var built := _build_scene(valid, src_dir, out_dir, mat_cache, true, init_wind, shader_path)
		# ★ 已删除 `_apply_decimate(built, ratio)` 调用 ✗ —— 那套 B 方案（在源目录找 glb）已废弃 ✓
		#   减面现在只走 `_build_scene()` 里的 `_decimate_mesh(src_mesh, _ratio, mi)` ✓
		var err := ResourceSaver.save(built["packed"], out_path)
		built["root"].free()
		if err != OK:
			return {"ok": false, "message": "保存失败（错误码 %d）：%s" % [err, out_path], "files": []}
		files.append(out_path)
	else:
		for n in valid:
			var one: Array = [n]
			var built := _build_scene(one, src_dir, out_dir, mat_cache, false, init_wind, shader_path)
			# ★ 同上：`_apply_decimate` 调用已删除 ✓（减面在 _build_scene 里做 ✓）
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
		# ★ A 方案的正确插入点：在复制网格**之前**把原始网格减面 ✓
		#   src_mesh 是 blend 的**原始网格**（不是预览那份带贴图的副本 ✓）
		#   减面只影响几何 ✓；材质随后仍由 _build_material() 建成 .res 引用 ✓
		if _ratio > 0.0 and _ratio < 1.0:
			# ★ 把**预览里那个真实节点** mi 一起传进去 ✓（借它导出临时 glb ✓，不自建游离子树 ✗）
			src_mesh = _decimate_mesh(src_mesh, _ratio, mi)
		# 复制网格再改材质（不复制的话，原地 surface_set_material 会把预览一起改掉）
		var mesh: Mesh = (src_mesh as Mesh).duplicate(true)
		# 材质：按源材质缓存成"导出用共享材质"
		for s in range(mesh.get_surface_count()):
			var src := mesh.surface_get_material(s)
			var key := _mat_key(src)
			if not mat_cache.has(key):
				# ★★ 撤销上一轮的"按顶点色关闭草 shader" ✗ —— 那是错误假设 ✓
				#   实测 grass_wind.gdshader **不依赖顶点色** ✓：
				#     第 126 行 albedo_tex 取颜色 ✓；第 128 行 ALPHA = texture(alpha_tex, UV).r ✓
				#     → 它用"颜色贴图 + **独立 alpha 贴图**"两路 ✓ → 树叶片也能正确镂空 ✓
				#   而 StandardMaterial3D **无法**使用独立 alpha ✗ → 叶子会变实心片 ✗（实测 ✓）
				#   所以：照常允许换 shader ✓；勾选框仍只管 wind_enabled ✓
				var vcol := _has_vertex_color(mesh)
				_cutout_shader_ok = true
				var wind_ok := init_wind
				var built := _build_material(src, src_dir, out_dir, key, wind_ok, shader_path)
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
	if alpha != null and _cutout_shader_ok:
		# ★ 只有"带顶点色"的植被（草 ✓）才走这个 shader ✓
		#   树/灌木叶片无顶点色 ✗ → 落到下面的标准材质分支 ✓（否则贴图表现错乱 ✓）
		# 有遮罩 -> 用自带 shader（解决图集黑底）
		# 用调用方选的 shader（面板上可换）；没选/载入失败就退回默认
		var sh: Shader = load(shader_path)
		if sh == null:
			sh = load(SHADER_PATH)
		if sh != null:
			# ★ 修：albedo(颜色) 若落到 alpha/mask 命名的贴图上 ✗ → 换成同前缀的 diff ✓
			#   实测老导出写的是 albedo_tex = …_**alpha**_4k.png ✗（颜色用了遮罩 ✓）→ 树叶颜色不对 ✓
			var alb_ok := albedo
			if alb_ok != null:
				var ap: String = alb_ok.resource_path.to_lower()
				if ap.contains("alpha") or ap.contains("mask"):
					var alt := _load_tex(_find_tex(src_dir, base, ["diff", "albedo", "col", "_d."]))
					if alt != null:
						print("[BlendExport]   albedo 原为遮罩图 ✗ → 已改用颜色图 ✓：%s" % alt.resource_path)
						alb_ok = alt
			var shm := ShaderMaterial.new()
			shm.shader = sh
			shm.set_shader_parameter("albedo_tex", alb_ok)
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
		# ★ 无顶点色的叶类网格走这里 ✓：用标准材质 + **alpha 裁剪** ✓
		#   这样叶子镂空/边缘仍正确 ✓（不必依赖草 shader ✓）
		#   叶贴图（含颜色+alpha ✓）优先当 albedo ✓
		if alpha != null:
			# ★ 只有**没有颜色贴图**时才拿 alpha 顶替 ✗→✓
			#   实测教训：直接把 alpha 当 albedo ✗ → 树叶纹理不对 ✓
			#   （正确做法：颜色用 leaves_diff_4k.png ✓，alpha 只作遮罩 ✓）
			if albedo == null:
				sm2.albedo_texture = alpha
			sm2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			sm2.alpha_scissor_threshold = 0.5
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


## ★★ 总开关（当前 = **关闭** ✗）：实测 glTF 往返这条路有硬伤 ✓：
##   ① `generate_scene()` 读回的节点树里，**贴图被内嵌** ✓ → `PackedScene.pack()` 会把它们
##      烤进 `.tscn` ✗ → 实测体积从几十 MB 变成 **1 GB+** ✗✗（用户实测 ✓）
##   ② 读回后三角面统计为 **0** ✗（导入的 mesh 很可能不是 indexed 数组 ✓，
##      也说明材质/网格的对应关系没建立起来 ✓）
##   → 在彻底解决这两点之前，**不允许**这条路径生效 ✓（导出恢复为原来的行为 ✓）
##   要重新启用：改成 `true`，并先修好 ② 计数与"摘材质后再写 glb"两点 ✓
const DECIMATE_ENABLED := false


## ★ 导出时减面（方案 A ✓）：当前节点树 → 临时 GLB → `npx @gltf-transform/cli weld + simplify
##   --ratio R` → 读回低模 → 用低模替换（材质按 surface 顺序沿用原材质 ✓）。
##
## 设计原则（重要 ✓）：**任何一步失败都原样返回 + 明确日志** ✓
##   → 绝不会把导出搞坏 ✓（最坏情况 = 按未减面导出 ✓）
## ratio = 1.0 或 <=0 → 直接原样返回 ✓（行为与原来完全一致 ✓）
static func _apply_decimate(built: Dictionary, ratio: float) -> Dictionary:
	# ★★ B 方案（用户确认）：**在已有 glb 上减面** ✓
	#   · 不再做 Godot 侧 glTF 往返 ✗（那会把贴图烤进 .tscn → 1GB+ ✗）
	#   · 直接对"源目录里的 .glb"跑 `npx weld + simplify --ratio R` ✓
	#     → 在**导出目录**产出 `<名字>_low.glb` ✓（`.tscn` 照原流程导出 ✓ 不受影响 ✓）
	#   · 之后用【Blender 预览】打开 `_low.glb` 再导一次，就能得到低模 .tscn ✓
	if ratio > 0.0 and ratio < 1.0:
		_decimate_source_glb(ratio)
		return built
	if not DECIMATE_ENABLED:
		if ratio > 0.0 and ratio < 1.0:
			push_warning("[BlendExport] 减面功能当前**已禁用** ✗（glTF 往返会把贴图烤进 .tscn → 体积 1GB+ ✗）→ 本次按**未减面**导出 ✓")
		return built
	if ratio <= 0.0 or ratio >= 1.0:
		return built
	var root = built.get("root", null)
	if root == null or not is_instance_valid(root):
		return built
	var tris_before := _count_tris(root)
	var npx := _find_npx()
	if npx == "":
		push_warning("[BlendExport] 需要减面(ratio=%.3f)但找不到 npx ✗ → 已按**未减面**导出 ✓（装 Node.js/npm 后重试 ✓）" % ratio)
		return built
	var tmp_abs := ProjectSettings.globalize_path("user://blend_decimate")
	DirAccess.make_dir_recursive_absolute(tmp_abs)
	var raw := tmp_abs.path_join("raw.glb")
	var welded := tmp_abs.path_join("weld.glb")
	var low := tmp_abs.path_join("low.glb")
	# ① 节点树 → 临时 GLB
	# ★★ 根治体积爆炸 ✗：写 glb **之前先把所有材质摘掉** ✓
	#   否则 glTF 会把贴图一起写进 glb ✓ → 读回后变成**内嵌材质** ✗ → pack 进 .tscn → 1GB+ ✗✗
	#   摘掉后 glb 里只有几何 ✓ → 减面 ✓ → 读回 ✓ → 再把原材质装回去 ✓（与原导出同样引用 .res/贴图 ✓）
	var stripped: Array = []                      # [mesh_instance, surface, material]
	for mi in _meshes(root):
		var m: Mesh = (mi as MeshInstance3D).mesh
		if m == null:
			continue
		for s in range(m.get_surface_count()):
			stripped.append([mi, s, m.surface_get_material(s)])
			m.surface_set_material(s, null)
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var ok1 := doc.append_from_scene(root, st) == OK and doc.write_to_filesystem(st, raw) == OK
	# ★ 立刻把材质**装回去** ✓（下面的 _copy_materials_by_surface 要靠它们 ✓）
	#   注意：built["packed"] 是 _build_scene 时就打好包的 ✓ → 摘材质不影响它 ✓
	for e in stripped:
		var rmi: MeshInstance3D = e[0]
		if rmi != null and is_instance_valid(rmi) and rmi.mesh != null:
			rmi.mesh.surface_set_material(int(e[1]), e[2] as Material)
	if not ok1:
		push_warning("[BlendExport] 减面第①步失败（写临时 GLB ✗）→ 按未减面导出 ✓")
		return built
	# ② weld + simplify（与项目里 tools/glb_simplify.py 同一套 ✓）
	var out: Array = []
	if OS.execute(npx, ["--yes", "@gltf-transform/cli", "weld", raw, welded], out, true) != 0:
		push_warning("[BlendExport] weld 失败 → 按未减面导出 ✓\n%s" % "\n".join(out))
		return built
	out.clear()
	var args := ["--yes", "@gltf-transform/cli", "simplify", welded, low,
			"--ratio", "%.6f" % clampf(ratio, 0.01, 1.0), "--error", "0.5"]
	if OS.execute(npx, args, out, true) != 0:
		push_warning("[BlendExport] simplify 失败 → 按未减面导出 ✓\n%s" % "\n".join(out))
		return built
	# ③ 读回低模
	var doc2 := GLTFDocument.new()
	var st2 := GLTFState.new()
	if doc2.append_from_file(low, st2) != OK:
		push_warning("[BlendExport] 读回低模失败 ✗ → 按未减面导出 ✓")
		return built
	var imported: Node = doc2.generate_scene(st2)
	if imported == null:
		push_warning("[BlendExport] 生成低模场景失败 ✗ → 按未减面导出 ✓")
		return built
	var tris_after := _count_tris(imported)
	_copy_materials_by_surface(root, imported)      # 材质沿用原来的 ✓（按 surface 顺序 ✓）
	root.free()                                     # 旧节点树释放 ✓
	var packed := PackedScene.new()
	if packed.pack(imported) != OK:
		push_warning("[BlendExport] 低模打包失败 ✗ → 按未减面导出 ✓")
		return built
	print("[BlendExport] 减面 ✓ ratio=%.3f ｜ 三角面 %d → %d" % [ratio, tris_before, tris_after])
	return {"packed": packed, "root": imported}


## ★ B 方案：**在已有 glb 上减面** ✓
##   源 glb 取"源目录（blend_src）里的第一个 .glb" ✓；用项目里已验证的
##   `npx @gltf-transform/cli weld + simplify --ratio R` ✓（与 tools/glb_simplify.py 同一套 ✓）
##   产出：`<导出目录>/<名字>_low.glb` ✓（以及中间文件 `<名字>_weld.glb` ✗ 可手动删 ✓）
##   任何一步失败 → 只警告 ✓（`.tscn` 导出完全不受影响 ✓）
static var _last_src_dir := ""
static var _last_out_dir := ""


static func _decimate_source_glb(ratio: float) -> void:
	var src_glb := _find_src_glb(_last_src_dir)
	if src_glb == "":
		push_warning("[BlendExport] 想减面但在源目录里没找到 .glb ✗ → 跳过（.tscn 照常导出 ✓）\n  源目录：%s" % _last_src_dir)
		return
	var npx := _find_npx()
	if npx == "":
		push_warning("[BlendExport] 想减面但找不到 npx ✗ → 跳过（装 Node.js/npm 后重试 ✓）")
		return
	var out_abs := ProjectSettings.globalize_path(_last_out_dir)
	DirAccess.make_dir_recursive_absolute(out_abs)
	var base := src_glb.get_file().get_basename()
	var welded := out_abs.path_join(base + "_weld.glb")
	var low := out_abs.path_join(base + "_low.glb")
	var src_abs := ProjectSettings.globalize_path(src_glb)
	var out: Array = []
	if OS.execute(npx, ["--yes", "@gltf-transform/cli", "weld", src_abs, welded], out, true) != 0:
		push_warning("[BlendExport] weld 失败 ✗ → 跳过减面（.tscn 照常导出 ✓）\n%s" % "\n".join(out))
		return
	out.clear()
	var args := ["--yes", "@gltf-transform/cli", "simplify", welded, low,
			"--ratio", "%.6f" % clampf(ratio, 0.01, 1.0), "--error", "0.5"]
	if OS.execute(npx, args, out, true) != 0:
		push_warning("[BlendExport] simplify 失败 ✗ → 跳过减面（.tscn 照常导出 ✓）\n%s" % "\n".join(out))
		return
	print("[BlendExport] 已产出低模 glb ✓ %s ｜ 源 %s ｜ 保留比例 %.3f" % [low, src_glb, ratio])
	# ★ 收尾：中间件 `_weld.glb` 用完即删 ✓（导出目录里只留 `_low.glb` 与 .tscn/.res ✓）
	if FileAccess.file_exists(welded):
		DirAccess.remove_absolute(welded)


## 在目录里找第一个 .glb（优先名字更像源模型的：非 _low/_weld/_mid ✓）
static func _find_src_glb(dir: String) -> String:
	if dir == "":
		return ""
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var best := ""
	for f in d.get_files():
		if not f.to_lower().ends_with(".glb"):
			continue
		var low := f.to_lower()
		if low.ends_with("_low.glb") or low.ends_with("_weld.glb") or low.ends_with("_mid.glb"):
			continue
		if best == "":
			best = f
	return dir.path_join(best) if best != "" else ""


## ★ A 方案：**只对网格做减面** ✓（把"原始网格"过一遍外部简化，再交回原流程 ✓）
##   为什么这样才对：`.tscn` 里内嵌的是**网格数据** ✓，材质是**独立 .res 引用贴图** ✓
##   → 所以只要把"要 pack 进去的那份 Mesh"变小，体积就跟着变小 ✓✓
##
##   实现：mesh → 临时 glb（**只几何**：材质先摘掉 ✓，杜绝内嵌贴图 ✗）
##        → `npx weld + simplify --ratio R` → 读回 → **只取回 Mesh** ✓
##        材质**一律**由 _build_scene 里的 _build_material() 重新建（引用 .res/贴图 ✓）
##   任何一步失败 → 返回**原网格** ✓ + 明确警告 ✓（导出永远安全 ✓）
static var _ratio := 1.0
## ★ 是否允许"换成草的风摆 shader" ✓（由 _build_scene 按网格是否带顶点色设置 ✓）
##   叶类网格没有顶点色 ✗ → 置 false ✓ → _build_material 回退到标准材质 + alpha 裁剪 ✓
static var _cutout_shader_ok := true


static func _decimate_mesh(src: Mesh, ratio: float, mi: MeshInstance3D = null) -> Mesh:
	if src == null or ratio <= 0.0 or ratio >= 1.0:
		return src
	# ★ 借**预览窗口里那个真实 MeshInstance3D** 导出临时 glb ✓
	#   （它已在编辑器场景树里、owner 齐全 ✓ —— 与正常导出能读到网格的节点是同一种 ✓）
	#   ✗ 不要自建游离子树：实测那样写出来的 glb 只有 **276 字节 = 空** ✓
	#      → glb_simplify 直接 struct.error ✗
	if mi == null or not is_instance_valid(mi):
		push_warning("[BlendExport] 减面需要预览里的 MeshInstance3D ✗ → 按原网格导出 ✓")
		return src
	var bare: Mesh = (src as Mesh).duplicate(true)
	for s in range(bare.get_surface_count()):
		bare.surface_set_material(s, null)   # 摘掉材质 → glb 里不会有贴图 ✓
	var prev_mesh: Mesh = mi.mesh            # 记住原来的（预览那份带贴图的副本 ✓）
	mi.mesh = bare                           # 临时换成"只有几何"的网格 ✓
	# ★ 临时文件一律放**项目内的 `.runtime/`** ✓（用户要求：不要写到 C 盘 ✗）
	#   原来是 user://（= %APPDATA%\Godot\app_userdata\… ✗ 在 C 盘 ✓）
	var abs_dir := ProjectSettings.globalize_path("res://.runtime/blend_decimate")
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var raw := abs_dir.path_join("mesh_raw.glb")
	var low := abs_dir.path_join("mesh_low.glb")
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	# ★ 直接用**真实节点 mi** 导出 ✓（不再用游离子树 ✗）
	var ok1 := doc.append_from_scene(mi, st) == OK and doc.write_to_filesystem(st, raw) == OK
	mi.mesh = prev_mesh                                   # ★ 立刻把预览用的网格还回去 ✓
	var raw_bytes := 0
	if FileAccess.file_exists(raw):
		raw_bytes = FileAccess.get_file_as_bytes(raw).size()
	# ★ 阈值 256 → 2048：实测空 glb 是 **276 字节** ✗ 会蒙混过关 ✓ → 现在挡得住 ✓
	if not ok1 or raw_bytes < 2048:
		push_warning("[BlendExport] 减面①失败（临时 glb 只有 %d 字节 ✗）→ 按原网格导出 ✓" % raw_bytes)
		return src
	print("[BlendExport]   临时 glb %d 字节 ✓" % raw_bytes)
	# ② 交给项目里**已验证**的工具做 weld + simplify ✓
	#   （它自己会处理 npx 查找 ✓；不再由我直接起 npx ✗ —— 实测编辑器进程里起不来 ✓）
	var py_script := ProjectSettings.globalize_path("res://tools/glb_simplify.py")
	# ★ 详细日志：把命令、返回码、工具自己的输出、产物大小全部打出来 ✓
	print("[BlendExport] ② 外部减面：python %s --in %s --out %s --ratio %.4f"
			% [py_script, raw, low, clampf(ratio, 0.01, 1.0)])
	var out: Array = []
	var rc := -1
	for py in ["python", "py"]:
		out.clear()
		rc = OS.execute(py, [py_script, "--in", raw, "--out", low,
				"--ratio", "%.4f" % clampf(ratio, 0.01, 1.0)], out, true)
		print("[BlendExport]   用 %s 执行完毕，rc=%d" % [py, rc])
		for line in out:
			print("[glb_simplify] ", String(line).strip_edges())
		if rc == 0:
			break
	var low_bytes := 0
	if FileAccess.file_exists(low):
		low_bytes = FileAccess.get_file_as_bytes(low).size()
	print("[BlendExport]   产物 low.glb = %d 字节 ｜ 临时目录：%s" % [low_bytes, abs_dir])
	if rc != 0 or low_bytes < 256:
		push_warning("[BlendExport] glb_simplify 失败 ✗（rc=%d, low=%d 字节）→ 按原网格导出 ✓" % [rc, low_bytes])
		return src
	# ③ 读回 → **只取 Mesh** ✓（材质一概不用导入的 ✗）
	var doc2 := GLTFDocument.new()
	var st2 := GLTFState.new()
	# ★ 读回时必须给 **base_path** ✓ —— 不给我实测会得到"没有网格的空场景" ✗
	#   （第 4 个参数 = base_path ✓；glb 虽自包含，但 Godot 解析相对引用要用它 ✓）
	if doc2.append_from_file(low, st2, 0, low.get_base_dir()) != OK:
		push_warning("[BlendExport] 读回低模失败 ✗ → 按原网格导出 ✓")
		return src
	var imported: Node = doc2.generate_scene(st2)
	if imported == null:
		push_warning("[BlendExport] 生成低模场景失败 ✗ → 按原网格导出 ✓")
		return src
	var got: Mesh = null
	# ★★ 关键修复（实测解释"headless 通过 / 编辑器失败" ✗→✓）：
	#   编辑器里的 glTF 导入产生的是 **`ImporterMeshInstance3D`** ✓
	#     —— 它是 `Node3D` 的子类，**不是 `MeshInstance3D`** ✗
	#     它的网格属性类型是 **`ImporterMesh`**（也不是 `ArrayMesh` ✗）
	#   原来我只找 `MeshInstance3D` + `.mesh` ✗ → 编辑器里**一个都找不到** ✓
	#     → 就是你看到的「低模里没找到网格」✓✓
	#   （headless/非编辑器跑同一段代码时，Godot 给的是普通 MeshInstance3D ✓
	#     → 所以我那边自测一直通过 ✓ —— 这也解释了两边的差异 ✓）
	#   现在改成**鸭子类型扫描** ✓：认 `.mesh`（是 Mesh 就用 ✓）
	#     或 `ImporterMesh` 的 `.get_mesh()`（转成 ArrayMesh ✓）✓
	var sc_stack: Array = [imported]
	while not sc_stack.is_empty() and got == null:
		var x = sc_stack.pop_back()
		var mm = x.get("mesh") if x is Node3D else null
		if mm is Mesh:
			got = mm as Mesh
		elif mm != null and mm.has_method("get_mesh"):
			var conv = mm.call("get_mesh")
			if conv is Mesh:
				got = conv
		for c in x.get_children():
			sc_stack.append(c)
	imported.free()
	if got == null:
		# ★ 详细日志：把读回场景的**节点类型统计**打出来 ✓
		#   （这样一眼就能看出：是空场景 ✗、还是节点不是 MeshInstance3D ✗、还是网格为 null ✗）
		var types := {}
		var stack2: Array = [imported]
		while not stack2.is_empty():
			var x2 = stack2.pop_back()
			var tn: String = x2.get_class()
			types[tn] = int(types.get(tn, 0)) + 1
			if x2 is MeshInstance3D and (x2 as MeshInstance3D).mesh == null:
				types["(MeshInstance3D 但 mesh==null)"] = int(types.get("(MeshInstance3D 但 mesh==null)", 0)) + 1
			for c2 in x2.get_children():
				stack2.append(c2)
		push_warning("[BlendExport] 低模里没找到网格 ✗ → 按原网格导出 ✓ ｜ 读回节点统计：%s ｜ low=%d 字节"
				% [str(types), FileAccess.get_file_as_bytes(low).size() if FileAccess.file_exists(low) else -1])
		return src
	# ★ 详细日志：完工汇报（surface 数 + 顶点数 前→后 ✓）
	var v0 := 0
	for s0 in range(src.get_surface_count()):
		v0 += src.surface_get_array_len(s0)
	var v1 := 0
	for s1 in range(got.get_surface_count()):
		v1 += got.surface_get_array_len(s1)
	print("[BlendExport] 网格减面 ✓ ratio=%.3f ｜ surface %d→%d ｜ 顶点 %d→%d（%.1f%%）"
			% [ratio, src.get_surface_count(), got.get_surface_count(),
			v0, v1, (100.0 * v1 / float(v0)) if v0 > 0 else 0.0])
	# ★★ 关键：把**原网格的材质**按 surface 序号装回低模 ✓
	#   低模是用"摘掉材质"的网格去减面的 ✗ → 回来时没有任何材质 ✓
	#   不装回去的话，_build_scene 会按 null 材质建出默认白材质 ✗
	#   → 文件名 `_blend_mat__unnamed__.tres` ✗ + **白模** ✓（用户实测 ✓）
	#   材质本身仍由 _build_scene → _build_material() 生成 .res 引用贴图 ✓（这条路没变 ✓）
	for s2 in range(got.get_surface_count()):
		var mat: Material = null
		if s2 < src.get_surface_count():
			mat = src.surface_get_material(s2)
		got.surface_set_material(s2, mat)
		# ★ 详细日志：逐个 surface 打出"拿到了哪个材质" ✓
		#   —— 树干对、树叶丢 这类问题，一眼就能看出是**序号错位**还是**材质名丢失** ✓
		print("[BlendExport]   surface %d ← %s" % [s2, _mat_key(mat) if mat != null else "__null__ ✗"])
	# ★ 属性对比日志：UV / 顶点色 是否存在、长度多少 ✓
	#   —— "树叶纹理消失"这类问题，多半是**UV 塌缩**（薄片被减面压坏 ✗）
	#      或 **COLOR_0/alpha 丢失** ✓，这两行能直接判定 ✓
	_attr_log("原网格", src)
	_attr_log("低模  ", got)
	print("[BlendExport]   原网格 surface=%d ｜ 低模 surface=%d%s"
			% [src.get_surface_count(), got.get_surface_count(),
			"" if src.get_surface_count() == got.get_surface_count() else "  ← ★ 数量不同！序号对齐会错位 ✗"])
	# 临时文件用完即删 ✓（已无 weld 中间件 —— 由 glb_simplify.py 内部处理 ✓）
	for f in [raw, low]:
		if FileAccess.file_exists(f):
			DirAccess.remove_absolute(f)
	return got


static func _count_tris(node: Node) -> int:
	var n := 0
	var stack: Array = [node]
	while not stack.is_empty():
		var x = stack.pop_back()
		if x is MeshInstance3D and (x as MeshInstance3D).mesh != null:
			var m: Mesh = (x as MeshInstance3D).mesh
			for s in range(m.get_surface_count()):
				var arr := m.surface_get_arrays(s)
				if arr.size() > Mesh.ARRAY_INDEX and arr[Mesh.ARRAY_INDEX] != null:
					n += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		for c in x.get_children():
			stack.append(c)
	return n


## Windows 上 npx 实际是 npx.cmd ✓ —— 两个都试 ✓
static func _find_npx() -> String:
	for c in ["npx", "npx.cmd"]:
		var out: Array = []
		if OS.execute(c, ["--version"], out, true) == 0:
			return c
	return ""


static func _meshes(node: Node) -> Array:
	var out: Array = []
	var stack: Array = [node]
	while not stack.is_empty():
		var x = stack.pop_back()
		if x is MeshInstance3D:
			out.append(x)
		for c in x.get_children():
			stack.append(c)
	return out


static func _copy_materials_by_surface(old_root: Node, new_root: Node) -> void:
	var olds := _meshes(old_root)
	var news := _meshes(new_root)
	for i in range(mini(olds.size(), news.size())):
		var om: MeshInstance3D = olds[i]
		var nm: MeshInstance3D = news[i]
		# ★ 必须先清掉导入带来的材质 ✗：
		#   glTF 往返后 surface 上会挂"导入生成的材质 + **内嵌贴图**" ✓ → 若不覆盖，
		#   PackedScene.pack() 会把贴图数据烤进 .tscn → **体积翻几十倍** ✗（用户实测 ✓）
		nm.material_override = null
		if om.mesh == null or nm.mesh == null:
			continue
		# ★ 一律覆盖每个 surface（原材质为空也要覆盖成 null ✗→✓），杜绝任何内嵌资源残留 ✓
		for s in range(nm.mesh.get_surface_count()):
			var mat: Material = null
			if s < om.mesh.get_surface_count():
				mat = om.mesh.surface_get_material(s)
			nm.mesh.surface_set_material(s, mat)


## ★ 诊断用：打印网格属性（顶点数 / UV / 顶点色）✓
##   用途：判定"树叶纹理消失"到底是 **UV 塌缩/丢失** ✗ 还是 **COLOR_0(alpha) 丢失** ✓
static func _attr_log(tag: String, m: Mesh) -> void:
	if m == null:
		print("[BlendExport]   %s：(mesh = null ✗)" % tag)
		return
	for s in range(m.get_surface_count()):
		var a := m.surface_get_arrays(s)
		var vtx := 0
		if a.size() > Mesh.ARRAY_VERTEX and a[Mesh.ARRAY_VERTEX] != null:
			vtx = (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
		var uv := -1
		if a.size() > Mesh.ARRAY_TEX_UV and a[Mesh.ARRAY_TEX_UV] != null:
			uv = (a[Mesh.ARRAY_TEX_UV] as PackedVector2Array).size()
		var col := -1
		if a.size() > Mesh.ARRAY_COLOR and a[Mesh.ARRAY_COLOR] != null:
			col = (a[Mesh.ARRAY_COLOR] as PackedColorArray).size()
		print("[BlendExport]   %s surface %d：顶点=%d ｜ UV=%s ｜ 顶点色=%s"
				% [tag, s, vtx,
				("%d" % uv) if uv >= 0 else "无 ✗",
				("%d" % col) if col >= 0 else "无 ✗"])


## ★ 网格是否带**顶点色** ✓ —— 用来决定"要不要换成草的风摆 shader" ✓
##   草：有顶点色 ✓（wind/burn 需要它 ✓）→ 换 shader ✓
##   树/灌木叶片：无顶点色 ✗ → **保留原材质** ✓（否则贴图表现错乱 ✓）
static func _has_vertex_color(m: Mesh) -> bool:
	if m == null:
		return false
	for s in range(m.get_surface_count()):
		var a := m.surface_get_arrays(s)
		if a.size() > Mesh.ARRAY_COLOR and a[Mesh.ARRAY_COLOR] != null:
			if (a[Mesh.ARRAY_COLOR] as PackedColorArray).size() > 0:
				return true
	return false


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
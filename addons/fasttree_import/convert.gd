@tool
extends RefCounted
## ============================================================================
## fast-tree GLB → Godot 资产（核心转换器；CLI 与编辑器插件共用同一份实现）
## ----------------------------------------------------------------------------
## 输入：fast-tree 导出的 .glb（带 `_AWIND/_APHASE/_AORIGIN` 自定义顶点属性）
## 输出：
##   res://assets/models/树/<name>/wind/<节点>.res   烘焙网格（CUSTOM0/1 风摆数据）
##   res://scenes/树/<name>/_ft_mat_<角色>.tres       树着色器材质（贴图/风参/燃烧元数据）
##   res://scenes/树/<name>/<name>.tscn               可直接拖进场景的预制场景
##      （含 CanopyCull 树冠分块剔除；有树叶/花朵时自动带 FallingLeaves 落叶节点）
##
## 为什么需要它：
##   Godot 的 glTF 导入器会丢弃 `_AWIND/_APHASE/_AORIGIN`（自定义属性），
##   所以"导入 GLB"得到的只是一棵静态树；这里把三组数据重新烘进 ARRAY_CUSTOM0/1。
##
## 用法（代码）：
##   const Convert := preload("res://addons/fasttree_import/convert.gd")
##   var res := Convert.new().run("res://x.glb", {"collision": "convex", "force": true})
##   # res.ok / res.scene / res.res_files / res.materials / res.message
##
## 前置：GLB 必须已被 Godot 导入过。
## ============================================================================

const BARK_SHADER := "res://assets/shaders/tree_burn_keep_ds.gdshader"
const LEAF_SHADER := "res://assets/shaders/tree_leaves_burn_ds.gdshader"
const CANOPY_SCRIPT := "res://scripts/world/canopy_chunk_cull.gd"
const FALLING_SCRIPT := "res://scripts/vfx/falling_leaves.gd"
const CUSTOM_FLAGS: int = (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM2_SHIFT) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM3_SHIFT)
## 位置分格（米）：Godot 导入会压缩顶点属性（~5e-4 m 误差），不能用精确 key 匹配
const CELL := 0.002
const MATCH_EPS := 0.003
## 叶片"宿主枝条"查找的分格（米）与最大距离
const HOST_CELL := 0.5
const HOST_MAX_DIST := 0.35

var _glb := ""
var _name := ""
var _res_dir := ""
var _scene_dir := ""
var _leaf_nodes_arg := ""
var _collision := "none"
var _force := false
var _dry := false
## 树皮顶点索引 + 宿主查找缓存（每次 run 重建）
var _host := {}
var _host_cache := {}
## 可选日志回调（编辑器插件用来把进度打到面板）
var _log_fn := Callable()


# ============================================================================
# 对外入口
# ============================================================================

## 转换一棵 fast-tree GLB。
## opts：
##   name        —— 资产名（默认 GLB 文件名）
##   res_dir     —— 烘焙 .res 目录（默认 res://assets/models/树/<name>/wind）
##   scene_dir   —— .tscn/.tres 目录（默认 res://scenes/树/<name>）
##   leaf_nodes  —— 逗号分隔的"叶片节点"名（默认按名字猜 leaf/flower）
##   collision   —— none | convex | trimesh
##   force       —— 覆盖已存在文件
##   dry_run     —— 只解析不落盘
##   log         —— Callable(String)，编辑器插件用来报进度
## 返回：{ok: bool, message, scene, res_files: Array, materials: Array, nodes: int, height: float}
func run(glb_path: String, opts: Dictionary = {}) -> Dictionary:
	_glb = glb_path
	_name = String(opts.get("name", ""))
	_res_dir = String(opts.get("res_dir", ""))
	_scene_dir = String(opts.get("scene_dir", ""))
	_leaf_nodes_arg = String(opts.get("leaf_nodes", ""))
	_collision = String(opts.get("collision", "none"))
	_force = bool(opts.get("force", false))
	_dry = bool(opts.get("dry_run", false))
	var lv: Variant = opts.get("log", null)
	_log_fn = lv if lv is Callable else Callable()
	if not _normalize_paths():
		return {"ok": false, "message": "参数不合法（看日志）"}
	return _run()


## 补齐/校验参数（CLI 与插件都不必自己拼默认目录）
func _normalize_paths() -> bool:
	if _glb == "":
		push_error("[ft] 缺少 GLB 路径")
		return false
	if _name == "":
		_name = _glb.get_file().get_basename()
	if _res_dir == "":
		_res_dir = "res://assets/models/树/%s/wind" % _name
	if _scene_dir == "":
		_scene_dir = "res://scenes/树/%s" % _name
	if not ["none", "convex", "trimesh"].has(_collision):
		push_error("[ft] collision 只能是 none|convex|trimesh")
		return false
	if not _force and not _dry:
		for p in [_scene_dir.path_join(_name + ".tscn"),
				_scene_dir.path_join("_ft_mat_bark.tres"),
				_scene_dir.path_join("_ft_mat_leaves.tres")]:
			if ResourceLoader.exists(p):
				push_error("[ft] 已存在：%s（要覆盖请 force=true / --force / 勾选「覆盖已存在」）" % p)
				return false
	return true


# ============================================================================
# 主流程
# ============================================================================

func _run() -> Dictionary:
	var t0 := Time.get_ticks_msec()
	_log("GLB      = %s" % _glb)
	_log("名称      = %s" % _name)
	_log("res 目录  = %s" % _res_dir)
	_log("场景目录  = %s" % _scene_dir)

	# ---- 1) GLB 原始数据（自定义属性只在二进制里）----
	var glb := _parse_glb(_glb)
	# 叶子/花朵的刚性摆动要跟枝条同步：先建"树皮顶点索引"（用 aOrigin 查最近树皮顶点）
	_host = _build_host_index(glb) if not glb.is_empty() else {}
	_host_cache = {}
	if not _host.is_empty():
		_log("宿主枝条索引：%d 个树皮顶点" % int(_host.get("count", 0)))
	if glb.is_empty():
		return {"ok": false, "message": "GLB 解析失败：%s" % _glb}

	# ---- 2) Godot 导入后的场景（拿网格拓扑与贴图引用）----
	var glb_scene: PackedScene = load(_glb)
	if glb_scene == null:
		return {"ok": false, "message": "加载失败（先让 Godot 导入一次）：%s" % _glb}
	var src: Node = glb_scene.instantiate()
	if src == null:
		return {"ok": false, "message": "实例化失败：%s" % _glb}
	var meshes := _collect_meshes(src)
	if meshes.is_empty():
		src.free()
		return {"ok": false, "message": "GLB 里没有 MeshInstance3D"}
	_log("网格节点 %d 个：%s" % [meshes.size(), str(meshes.map(func(m): return String(m.name)))])

	# ---- 3) 烘焙每个网格 ----
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_res_dir))
	var baked := {}        # 节点名 -> {path, verts, tris, is_leaf, top}
	var tree_top := 0.0
	for mi in meshes:
		var info := _bake_mesh(glb, mi)
		if info.is_empty():
			continue
		baked[String(mi.name)] = info
		tree_top = maxf(tree_top, info.get("top", 0.0))
	if baked.is_empty():
		src.free()
		return {"ok": false, "message": "一个网格都没烘出来"}
	_log("烘焙完成：%d 个；树高 ≈ %.2f m" % [baked.size(), tree_top])

	# ---- 4) 材质 ----
	var mats := _build_materials(meshes, baked, tree_top)

	# ---- 5) 场景 ----
	var scene_path := _build_scene(src, meshes, baked, mats, tree_top)
	src.free()

	var res_files: Array = []
	for k in baked.keys():
		res_files.append(String(baked[k]["path"]))
	var mat_files: Array = []
	for k in mats.keys():
		mat_files.append(String(mats[k]["path"]))
	_log("完成：%d ms" % [Time.get_ticks_msec() - t0])
	if scene_path == "":
		return {"ok": false, "message": "场景没写出来（看上面的错误）",
				"res_files": res_files, "materials": mat_files}
	return {"ok": true,
			"message": "完成：%d 个网格 / %d 个材质 / 树高 %.2f m" % [baked.size(), mats.size(), tree_top],
			"scene": scene_path, "res_files": res_files, "materials": mat_files,
			"nodes": baked.size(), "height": tree_top}


# ============================================================================
# 烘焙单个网格：把 GLB 的 _AWIND/_APHASE/_AORIGIN 补成 CUSTOM0/1
# ============================================================================

func _bake_mesh(glb: Dictionary, mi: MeshInstance3D) -> Dictionary:
	var nm := String(mi.name)
	if not (glb["prims"] as Dictionary).has(nm):
		_log("跳过 %s：GLB 里没有同名 primitive" % nm)
		return {}
	var mesh: Mesh = mi.mesh
	if mesh == null or not (mesh is ArrayMesh):
		_log("跳过 %s：不是 ArrayMesh" % nm)
		return {}
	var am_src := mesh as ArrayMesh
	var prim: Dictionary = glb["prims"][nm]
	var g_pos: PackedVector3Array = prim["pos"]
	var g_wind: PackedFloat32Array = prim["wind"]
	var g_phase: PackedFloat32Array = prim["phase"]
	var g_origin: PackedVector3Array = prim["origin"]
	var g_nodeid: PackedFloat32Array = prim["nodeid"]
	var g_grow: PackedVector2Array = prim["grow"]
	var is_leaf := _is_leaf_node(nm)
	# 位置索引
	var index := {}
	for i in range(g_pos.size()):
		var key := _cell_key(g_pos[i])
		if index.has(key):
			(index[key] as Array).append(i)
		else:
			index[key] = [i]
	var out := ArrayMesh.new()
	var verts_total := 0
	var tris_total := 0
	var missing := 0
	var top := -INF
	# 该节点对应的烘焙资源路径（整节点一个 .res；多 surface 时合并进同一个 ArrayMesh）
	var res_path := _res_dir.path_join(nm + ".res")
	for s in range(am_src.get_surface_count()):
		var arr: Array = am_src.surface_get_arrays(s)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n := verts.size()
		verts_total += n
		if arr[Mesh.ARRAY_INDEX] != null:
			tris_total += (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
		var c0 := PackedFloat32Array()
		var c1 := PackedFloat32Array()
		var c2 := PackedFloat32Array()
		# CUSTOM3 = (aGrow.x, aGrow.y, 0, 1=有生长数据)
		#   逐顶点生长区间（fast-tree 原版生长动画）：树干 [0,0.30] → L5 [0.74,0.96]，
		#   叶片是逐叶随机 [0.5,0.98]。没读到 _AGROW 时 w=0，着色器按"已长成"处理。
		var c3 := PackedFloat32Array()
		c0.resize(n * 4)
		c1.resize(n * 4)
		c2.resize(n * 4)
		c3.resize(n * 4)
		for vi in range(n):
			var v: Vector3 = verts[vi]
			if v.y > top:
				top = v.y
			var gi := _match(index, g_pos, v)
			var a_wind := 1.0
			var a_phase := 0.0
			var a_origin := Vector3.ZERO
			var a_node := 0.0
			var a_grow := Vector2.ZERO
			var has_grow := 0.0
			if gi >= 0:
				a_wind = g_wind[gi]
				a_phase = g_phase[gi]
				a_origin = g_origin[gi]
				a_node = g_nodeid[gi]
				if gi < g_grow.size():
					a_grow = g_grow[gi]
					has_grow = 1.0
				if v.distance_to(g_pos[gi]) > MATCH_EPS:
					missing += 1
			else:
				missing += 1
			c0[vi * 4 + 0] = a_origin.x
			c0[vi * 4 + 1] = a_origin.y
			c0[vi * 4 + 2] = a_origin.z
			c0[vi * 4 + 3] = a_wind
			c1[vi * 4 + 0] = a_phase
			c1[vi * 4 + 1] = 1.0 if is_leaf else 0.0
			c1[vi * 4 + 2] = a_node
			c1[vi * 4 + 3] = 1.0
			c3[vi * 4 + 0] = a_grow.x
			c3[vi * 4 + 1] = a_grow.y
			c3[vi * 4 + 2] = 0.0
			c3[vi * 4 + 3] = has_grow
			# CUSTOM2 = (宿主枝条 phase, 宿主枝条 aWind, 宿主 nodeId, 1=有宿主)
			#   刚性摆动用宿主值 → 叶片/花朵与枝条同步；局部抖动仍用叶子自己的 aPhase。
			if is_leaf and not _host.is_empty():
				var h := _host_at(_host, _host_cache, a_origin)
				if not h.is_empty():
					c2[vi * 4 + 0] = h[0]
					c2[vi * 4 + 1] = h[1]
					c2[vi * 4 + 2] = h[2]
					c2[vi * 4 + 3] = 1.0
				else:
					c2[vi * 4 + 0] = a_phase
					c2[vi * 4 + 1] = a_wind
					c2[vi * 4 + 2] = a_node
					c2[vi * 4 + 3] = 1.0
		var out_arr: Array = arr.duplicate(true)
		out_arr[Mesh.ARRAY_CUSTOM0] = c0
		out_arr[Mesh.ARRAY_CUSTOM1] = c1
		out_arr[Mesh.ARRAY_CUSTOM2] = c2
		out_arr[Mesh.ARRAY_CUSTOM3] = c3
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out_arr, [], {}, CUSTOM_FLAGS)
		out.surface_set_name(s, am_src.surface_get_name(s))
	if not _dry:
		var err := ResourceSaver.save(out, res_path)
		if err != OK:
			push_error("[ft] 保存失败 %s err=%d" % [res_path, err])
			return {}
	_log("✓ %-16s verts=%6d tris=%6d isLeaf=%s 未匹配=%d -> %s" % [
		nm, verts_total, tris_total, str(is_leaf), missing, res_path])
	return {"path": res_path, "verts": verts_total, "tris": tris_total,
			"is_leaf": is_leaf, "top": top}


# ============================================================================
# 材质：从导入材质的贴图引用直接建树着色器 .tres（贴图一个字节都不复制）
# ============================================================================

func _build_materials(meshes: Array, baked: Dictionary, tree_top: float) -> Dictionary:
	var mats := {}
	var height := maxf(1.0, tree_top)
	for mi in meshes:
		var nm := String(mi.name)
		if not baked.has(nm):
			continue
		var role := _role_of(nm)
		if mats.has(role):
			continue
		var src_mat: Material = null
		if mi.mesh != null and mi.mesh.get_surface_count() > 0:
			src_mat = mi.mesh.surface_get_material(0)
		var shader_path := LEAF_SHADER if (role == "leaves" or role == "flowers") else BARK_SHADER
		var sh: Shader = load(shader_path)
		if sh == null:
			push_error("[ft] 着色器缺失 %s" % shader_path)
			continue
		var sm := ShaderMaterial.new()
		sm.shader = sh
		sm.resource_name = "%s_%s" % [_name, role]
		# ---- 贴图（从 GLB 导入材质回链）----
		var has_normal := false
		var has_rough := false
		var albedo: Texture2D = null
		if src_mat is StandardMaterial3D:
			var std := src_mat as StandardMaterial3D
			albedo = std.albedo_texture
			if albedo != null:
				sm.set_shader_parameter("albedo_tex", albedo)
			if std.normal_texture != null:
				sm.set_shader_parameter("normal_tex", std.normal_texture)
				has_normal = true
			var rough: Texture2D = null
			var rv: Variant = std.get("roughness_texture")
			if rv is Texture2D:
				rough = rv as Texture2D
			if rough == null and std.orm_texture != null:
				rough = std.orm_texture
				sm.set_shader_parameter("rough_channel", 1)   # glTF ORM: G = roughness
			if rough != null:
				sm.set_shader_parameter("rough_tex", rough)
				has_rough = true
			# ---- 透明/裁切：glTF MASK -> 用 albedo 的 a 通道（与项目现有樱花树一致）----
			if std.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and albedo != null:
				sm.set_shader_parameter("alpha_tex", albedo)
				sm.set_shader_parameter("alpha_channel", 3)
				sm.set_shader_parameter("alpha_scissor", 0.35)
		sm.set_shader_parameter("has_normal", has_normal)
		sm.set_shader_parameter("has_rough", has_rough)
		sm.set_shader_parameter("base_color", Color(1, 1, 1, 1))
		# ---- 燃烧参数（跟项目现有树一致）----
		sm.set_shader_parameter("height_ref", height)
		sm.set_shader_parameter("wind_height_ref", height)
		sm.set_shader_parameter("burn", 0.0)
		sm.set_shader_parameter("ash", 0.0)
		# ---- 风摆：树皮 / 叶花 两套默认值 ----
		sm.set_shader_parameter("wind_enabled", true)
		sm.set_shader_parameter("wind_seed", 0.0)
		sm.set_shader_parameter("wind_frequency", 1.0)
		if role == "bark":
			sm.set_shader_parameter("wind_sway", 0.8)
			sm.set_shader_parameter("wind_is_leaf", false)
			sm.set_shader_parameter("wind_leaf_flutter", 0.0)
			sm.set_shader_parameter("wind_leaf_twist", 0.0)
			sm.set_shader_parameter("normal_strength", 0.35)
			# GLB 树皮法线是逐面原始朝向；细枝上会出亮带 -> 用径向法线压平（见树着色器注释）
			sm.set_shader_parameter("radial_normal", 0.55)
			sm.set_meta("burn_mode", "wood")
			sm.set_meta("cull_mode", 0)
			sm.set_meta("cull_shader", "单面")
		else:
			# 刚性摆幅与树皮一致（0.8）：叶片/花朵的"额外"运动全部来自局部抖动，
			# 这样整片叶子跟着枝条平移的量与枝条完全相同（树枝与树叶/花朵同步）。
			sm.set_shader_parameter("wind_sway", 0.8)
			sm.set_shader_parameter("wind_is_leaf", true)
			sm.set_shader_parameter("wind_leaf_flutter", 0.6)
			sm.set_shader_parameter("wind_leaf_twist", 0.5 if role == "leaves" else 0.42)
			sm.set_shader_parameter("wind_flutter_rate", 1.10 if role == "leaves" else 0.72)
			# GLB 叶卡法线每片朝向不同 -> 树冠外扩 + 环境光补偿（否则整片发黑，见着色器注释）
			sm.set_shader_parameter("normal_up_blend", 0.85)
			sm.set_shader_parameter("ambient_fill", 0.3)
			sm.set_meta("burn_mode", "leaf")
			sm.set_meta("cull_mode", 2)
			sm.set_meta("cull_shader", "ds(双面)")
		sm.set_meta("burn_height", height)
		var p := _scene_dir.path_join("_ft_mat_%s.tres" % role)
		if not _dry:
			var err := ResourceSaver.save(sm, p)
			if err != OK:
				push_error("[ft] 材质保存失败 %s err=%d" % [p, err])
				continue
		_log("✓ 材质 %-7s albedo=%s normal=%s rough=%s -> %s" % [
			role, str(albedo != null), str(has_normal), str(has_rough), p])
		mats[role] = {"path": p, "mat": sm}
	return mats


# ============================================================================
# 场景：把导入场景里的网格换成烘焙网格 + 材质，存成独立 tscn
# ============================================================================

func _build_scene(src: Node, meshes: Array, baked: Dictionary, mats: Dictionary, tree_top: float) -> String:
	if _dry:
		_log("[dry-run] 不写场景")
		return ""
	var root := Node3D.new()
	root.name = _pascal(_name)
	var leaf_mat: Material = null
	for role in mats.keys():
		if mats[role]["mat"].get_meta("burn_mode", "") == "leaf":
			leaf_mat = mats[role]["mat"]
			break
	_rebuild_nodes(src, root, root, baked, mats, leaf_mat)
	# 落叶 / 落花：按实际存在的树叶、花朵网格自动挂 FallingLeaves
	_add_falling_leaves(root, baked, tree_top)
	# 树冠分块剔除（只有真的存在叶片网格才挂）
	if leaf_mat != null:
		var cull_script: Script = load(CANOPY_SCRIPT)
		if cull_script != null:
			var cull := Node.new()
			cull.name = "CanopyCull"
			cull.set_script(cull_script)
			root.add_child(cull)
			cull.owner = root
	# 可选碰撞
	if _collision != "none":
		_add_collision(root, baked)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_scene_dir))
	var packed := PackedScene.new()
	var err := packed.pack(root)
	var out_path := ""
	if err == OK:
		out_path = _scene_dir.path_join(_name + ".tscn")
		err = ResourceSaver.save(packed, out_path)
		if err == OK:
			_log("✓ 场景 -> %s" % out_path)
		else:
			push_error("[ft] 场景保存失败 err=%d" % err)
			out_path = ""
	else:
		push_error("[ft] PackedScene.pack 失败 err=%d" % err)
	root.free()
	return out_path


func _rebuild_nodes(src: Node, dst: Node, scene_root: Node, baked: Dictionary, mats: Dictionary, leaf_mat: Material) -> void:
	for child in src.get_children():
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			var nm := String(mi.name)
			if not baked.has(nm):
				continue
			var role := _role_of(nm)
			var out := MeshInstance3D.new()
			out.name = nm
			var baked_mesh: ArrayMesh = load(String(baked[nm]["path"]))
			out.mesh = baked_mesh
			if mats.has(role):
				out.material_override = mats[role]["mat"]
			out.transform = mi.transform
			out.cast_shadow = mi.cast_shadow
			out.gi_mode = mi.gi_mode
			dst.add_child(out)
			out.owner = scene_root
		else:
			# 保留层级（尤其是 "FastTree" 这类中间节点），但重建为普通 Node3D
			var wrap := Node3D.new()
			wrap.name = String(child.name)
			wrap.transform = (child as Node3D).transform if child is Node3D else Transform3D.IDENTITY
			dst.add_child(wrap)
			wrap.owner = scene_root
			_rebuild_nodes(child, wrap, scene_root, baked, mats, leaf_mat)


## 落叶 / 落花：给烘好的树自动挂一个 FallingLeaves 节点。
##   · 挂在树叶（没有树叶就挂花朵）所在的**同一父节点**下，路径才能写成 `../<节点名>`
##   · 只按**实际存在**的来源打开开关（没有花朵的树不会去落花）
##   · 卡片尺寸按树高自适应（大樱花树 27.2 模型单位 → 0.9）
func _add_falling_leaves(root: Node3D, baked: Dictionary, tree_top: float) -> void:
	var script: Script = load(FALLING_SCRIPT)
	if script == null:
		_log("[落叶] 找不到 %s，跳过" % FALLING_SCRIPT)
		return
	var leaves_mi := _foliage_of_role(root, baked, "leaves")
	var flowers_mi := _foliage_of_role(root, baked, "flowers")
	if leaves_mi == null and flowers_mi == null:
		return
	var host: Node = (leaves_mi if leaves_mi != null else flowers_mi).get_parent()
	if host == null:
		return
	var fl: MeshInstance3D = script.new()
	fl.name = "FallingLeaves"
	host.add_child(fl)
	fl.owner = root
	var base := clampf(tree_top * 0.033, 0.25, 2.0)
	fl.set("leaves_size_scale", base)
	fl.set("flowers_size_scale", base * 0.89)
	if leaves_mi != null:
		fl.set("leaves_path", fl.get_path_to(leaves_mi))
	else:
		fl.set("leaves_enabled", false)
	if flowers_mi != null:
		fl.set("flowers_path", fl.get_path_to(flowers_mi))
	else:
		fl.set("flowers_enabled", false)
	_log("落叶 / 落花：树叶 %s ｜ 花朵 %s（卡片尺寸 %.2f）" % [
			"有" if leaves_mi != null else "无",
			"有" if flowers_mi != null else "无", base])


## 按角色（leaves / flowers）找重建后的第一个树冠网格
func _foliage_of_role(root: Node, baked: Dictionary, role: String) -> MeshInstance3D:
	for nm in baked.keys():
		if _role_of(String(nm)) != role:
			continue
		var mi := _find_node(root, String(nm)) as MeshInstance3D
		if mi != null:
			return mi
	return null


func _add_collision(root: Node3D, baked: Dictionary) -> void:
	for node_name in baked.keys():
		if baked[node_name]["is_leaf"]:
			continue
		var mi := _find_node(root, String(node_name)) as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var body := StaticBody3D.new()
		body.name = "Collision"
		body.collision_layer = 32772
		body.collision_mask = 0
		mi.add_child(body)
		body.owner = root
		var cs := CollisionShape3D.new()
		cs.shape = (mi.mesh as Mesh).create_trimesh_shape() if _collision == "trimesh" \
				else (mi.mesh as Mesh).create_convex_shape()
		body.add_child(cs)
		cs.owner = root
	_log("碰撞已生成（%s）" % _collision)


# ============================================================================
# 角色 / 命名
# ============================================================================

func _is_leaf_node(nm: String) -> bool:
	return _role_of(nm) != "bark"


func _role_of(nm: String) -> String:
	var low := nm.to_lower()
	if _leaf_nodes_arg != "":
		for cand in _leaf_nodes_arg.split(",", false):
			if low == String(cand).to_lower():
				# 显式列表里的节点再区分花/叶
				return "flowers" if low.contains("flower") else "leaves"
	var has_fruit := low.contains("fruit") or low.contains("berry") or low.contains("cone")
	if low.contains("flower") or (low.contains("blossom") and not has_fruit):
		return "flowers"
	if low.contains("leaf") or low.contains("leaves") or low.contains("foliage"):
		return "leaves"
	return "bark"


func _pascal(s: String) -> String:
	var out := ""
	for part in s.replace("-", "_").split("_", false):
		out += String(part).substr(0, 1).to_upper() + String(part).substr(1)
	return out if out != "" else "FastTree"


# ============================================================================
# GLB 解析（json + bin；与 tools/bake_tree_wind.gd 同一套读法）
# ============================================================================

func _parse_glb(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[ft] 打不开 %s" % path)
		return {}
	var bytes := f.get_buffer(f.get_length())
	f.close()
	if bytes.size() < 20 or bytes.decode_u32(0) != 0x46546C67:
		push_error("[ft] 不是 GLB")
		return {}
	var total := bytes.decode_u32(8)
	var off := 12
	var json_text := ""
	var bin := PackedByteArray()
	while off + 8 <= total:
		var clen := bytes.decode_u32(off)
		var ctype := bytes.decode_u32(off + 4)
		var data_off := off + 8
		if ctype == 0x4E4F534A:
			json_text = bytes.slice(data_off, data_off + clen).get_string_from_utf8()
		elif ctype == 0x004E4942:
			bin = bytes.slice(data_off, data_off + clen)
		off = data_off + clen
	var doc: Variant = JSON.parse_string(json_text)
	if not (doc is Dictionary):
		push_error("[ft] GLB JSON 解析失败")
		return {}
	var gltf: Dictionary = doc
	var accessors: Array = gltf["accessors"]
	var views: Array = gltf["bufferViews"]
	var out := {"prims": {}}
	for n in gltf["nodes"]:
		if not (n is Dictionary) or not (n as Dictionary).has("mesh"):
			continue
		var node_name := String((n as Dictionary).get("name", "node"))
		var mesh: Dictionary = gltf["meshes"][int((n as Dictionary)["mesh"])]
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
		# 生长区间 [start, end]（fast-tree 的 aGrow）：逐顶点烘焙进 CUSTOM3.xy
		var grow := _acc_vec2_or_zero(accessors, views, bin, int(attrs.get("_AGROW", -1)), pos.size())
		(out["prims"] as Dictionary)[node_name] = {
			"pos": pos, "wind": wind, "phase": phase, "origin": origin, "nodeid": nodeid,
			"grow": grow,
		}
	return out


func _acc_bytes(accessors: Array, views: Array, idx: int, expect_comp: int) -> Dictionary:
	if idx < 0 or idx >= accessors.size():
		return {}
	var acc: Dictionary = accessors[idx]
	if int(acc.get("componentType", 0)) != expect_comp or not acc.has("bufferView"):
		return {}
	var view: Dictionary = views[int(acc["bufferView"])]
	var ncomp := _type_components(String(acc["type"]))
	var comp_size := 4
	return {
		"base": int(view.get("byteOffset", 0)) + int(acc.get("byteOffset", 0)),
		"count": int(acc["count"]),
		"ncomp": ncomp,
		"stride": int(view.get("byteStride", comp_size * ncomp)),
	}


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
	var info := _acc_bytes(accessors, views, idx, 5126)
	if info.is_empty():
		return out
	var n := mini(count, int(info["count"]))
	for i in range(n):
		out[i] = bin.decode_float(int(info["base"]) + i * int(info["stride"]))
	return out


func _acc_vec3(accessors: Array, views: Array, bin: PackedByteArray, idx: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var info := _acc_bytes(accessors, views, idx, 5126)
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


func _acc_vec2_or_zero(accessors: Array, views: Array, bin: PackedByteArray, idx: int, count: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(count)
	out.fill(Vector2.ZERO)
	var info := _acc_bytes(accessors, views, idx, 5126)
	if info.is_empty():
		return out
	var n := mini(count, int(info["count"]))
	var base := int(info["base"])
	var stride := int(info["stride"])
	for i in range(n):
		var o := base + i * stride
		out[i] = Vector2(bin.decode_float(o), bin.decode_float(o + 4))
	return out


# ============================================================================
# 顶点匹配 / 小工具
# ============================================================================

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


## 建"树皮顶点索引"：把所有**非叶片**节点的 (position, phase, aWind, nodeId) 收进来。
## 用 GLB 原始数据（零误差、和 aOrigin 同一坐标空间），不用导入网格。
func _build_host_index(glb: Dictionary) -> Dictionary:
	var cells := {}
	var count := 0
	for nm in (glb.get("prims", {}) as Dictionary).keys():
		if _is_leaf_node(String(nm)):
			continue
		if not (glb["prims"] as Dictionary).has(nm):
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


## 在宿主索引里找离 origin 最近的树皮顶点 -> [phase, aWind, nodeId]；找不到返回 []。
## 同一片叶子的多个顶点共用一个 aOrigin，用 cell key 缓存避免重复搜索。
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


static func _cell_key(p: Vector3) -> String:
	return "%d_%d_%d" % [int(floor(p.x / CELL)), int(floor(p.y / CELL)), int(floor(p.z / CELL))]


func _collect_meshes(root: Node) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


func _find_node(root: Node, nm: String) -> Node:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if String(n.name) == nm:
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _log(s: String) -> void:
	if _log_fn.is_valid():
		_log_fn.call(s)
	print("[ft] " + s)

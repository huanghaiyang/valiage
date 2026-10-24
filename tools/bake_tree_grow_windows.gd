extends SceneTree
## ============================================================================
## 补烤工具：把 fast-tree GLB 的 `_AGROW` 追加为**已烘焙网格**的 CUSTOM3
## ----------------------------------------------------------------------------
## 背景：
##   现有 assets/models/树/wind/*.res 里只有 CUSTOM0/1/2（风摆数据），
##   而 fast-tree 原版生长动画需要逐顶点生长区间 aGrow（树干 [0,.30] → L5 [.74,.96]，
##   叶片逐叶随机 [0.5,.98]）。
##   本工具**只追加 CUSTOM3**，其余顶点数据（位置/法线/UV/顶点色/CUSTOM0~2）
##   原样保留 → 不会改动任何现有风摆/燃烧行为。
##
## 用法（新增树木时把 GLB / RES_DIR 改成对应路径再跑）：
##   godot --headless --path . -s res://tools/bake_tree_grow_windows.gd
##
## 之后着色器里 growth_mode = 1 即可使用 fast-tree 原版生长，
## 驱动脚本：scripts/vfx/tree_growth.gd（play_with_mode(1)）
## ============================================================================

const GLB := "res://assets/models/树/大樱花树.glb"
const RES_DIR := "res://assets/models/树/wind"
const Convert := preload("res://addons/fasttree_import/convert.gd")


func _initialize() -> void:
	var conv = Convert.new()
	var glb: Dictionary = conv._parse_glb(GLB)
	if glb.is_empty():
		push_error("[grow-bake] GLB 解析失败：%s" % GLB)
		quit(1)
		return
	var scene: PackedScene = load(GLB)
	if scene == null:
		push_error("[grow-bake] GLB 还没被 Godot 导入：%s" % GLB)
		quit(1)
		return
	var src := scene.instantiate()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(RES_DIR))
	for mi in conv._collect_meshes(src):
		_patch(conv, glb, mi as MeshInstance3D)
	src.free()
	quit()


func _patch(conv, glb: Dictionary, mi: MeshInstance3D) -> void:
	var nm := String(mi.name)
	if not (glb["prims"] as Dictionary).has(nm):
		print("[grow-bake] 跳过 %s：GLB 里没有同名 primitive" % nm)
		return
	var res_path := RES_DIR.path_join(nm + ".res")
	if not ResourceLoader.exists(res_path):
		print("[grow-bake] 跳过 %s：没有 %s" % [nm, res_path])
		return
	var old: ArrayMesh = load(res_path)
	if old == null:
		print("[grow-bake] 跳过 %s：%s 不是 ArrayMesh" % [nm, res_path])
		return
	var prim: Dictionary = glb["prims"][nm]
	var g_pos: PackedVector3Array = prim["pos"]
	var g_grow: PackedVector2Array = prim["grow"]
	if g_grow.is_empty():
		print("[grow-bake] 跳过 %s：GLB 里没有 _AGROW" % nm)
		return
	# 位置索引（与 convert.gd 同一套 CELL/MATCH_EPS 匹配）
	var index := {}
	for i in range(g_pos.size()):
		var key := Convert._cell_key(g_pos[i])
		if index.has(key):
			(index[key] as Array).append(i)
		else:
			index[key] = [i]
	var out := ArrayMesh.new()
	for s in range(old.get_surface_count()):
		var arr: Array = old.surface_get_arrays(s)
		if arr.is_empty() or arr[Mesh.ARRAY_VERTEX] == null:
			continue
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var n := verts.size()
		var c3 := PackedFloat32Array()
		c3.resize(n * 4)
		var missing := 0
		var lo := INF
		var hi := -INF
		for vi in range(n):
			var gi: int = conv._match(index, g_pos, verts[vi])
			if gi < 0 or gi >= g_grow.size():
				missing += 1
				continue
			var gr: Vector2 = g_grow[gi]
			c3[vi * 4 + 0] = gr.x
			c3[vi * 4 + 1] = gr.y
			c3[vi * 4 + 2] = 0.0
			c3[vi * 4 + 3] = 1.0
			lo = minf(lo, gr.x)
			hi = maxf(hi, gr.y)
		arr[Mesh.ARRAY_CUSTOM3] = c3
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr, [], {}, Convert.CUSTOM_FLAGS)
		out.surface_set_name(s, old.surface_get_name(s))
		print("[grow-bake] %-14s verts=%6d 未匹配=%d grow=[%.2f, %.2f]" % [nm, n, missing, lo, hi])
	var err := ResourceSaver.save(out, res_path)
	print("[grow-bake] %s -> %s (%s)" % [nm, res_path, "ok" if err == OK else "err %d" % err])

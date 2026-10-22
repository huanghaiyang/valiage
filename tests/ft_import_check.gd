extends SceneTree
## 检查 fasttree_import.gd 生成的场景/材质是否完整可用。

func _initialize() -> void:
	var scene_path := "res://_ft_import_test/TestSakura/TestSakura.tscn"
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--scene="):
			scene_path = String(a).substr(8)
	var ps: PackedScene = load(scene_path)
	if ps == null:
		print("FAIL: 场景加载失败")
		quit(1)
		return
	var root: Node = ps.instantiate()
	print("ROOT = %s (%s)  children=%s" % [root.name, root.get_class(), str(root.get_children().map(func(c): return String(c.name)))])
	var stack: Array = [root]
	var meshes := 0
	var ok_custom := 0
	var mats := {}
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			meshes += 1
			var mi := n as MeshInstance3D
			var am := mi.mesh as ArrayMesh
			var arr: Array = am.surface_get_arrays(0) if am != null and am.get_surface_count() > 0 else []
			var has_custom := arr.size() > Mesh.ARRAY_CUSTOM1 and arr[Mesh.ARRAY_CUSTOM1] != null
			if has_custom:
				ok_custom += 1
			var m: Material = mi.material_override
			if m != null:
				mats[String(m.resource_path)] = true
			print("  %-16s parent=%-12s custom=%s mat=%s matName=%s wind_is_leaf=%s" % [
				mi.name, String(mi.get_parent().name), str(has_custom),
				str(m != null), (String(m.resource_name) if m != null else "-"),
				str(m.get_shader_parameter("wind_is_leaf")) if m is ShaderMaterial else "-"])
		for c in n.get_children():
			stack.append(c)
	var cull := root.get_node_or_null("CanopyCull")
	print("MESHES=%d custom_ok=%d 材质=%d CanopyCull=%s" % [meshes, ok_custom, mats.size(), str(cull != null)])
	# 材质参数抽查（从场景所在目录推，不写死测试目录）
	var dir := scene_path.get_base_dir()
	for p in [dir.path_join("_ft_mat_bark.tres"),
			dir.path_join("_ft_mat_leaves.tres"),
			dir.path_join("_ft_mat_flowers.tres")]:
		var sm: ShaderMaterial = load(p)
		if sm == null:
			print("MAT %s 不存在（跳过）" % p.get_file())
			continue
		print("MAT %s shader=%s albedo=%s alpha=%s normal=%s rough=%s" % [
			p.get_file(), String(sm.shader.resource_path),
			str(sm.get_shader_parameter("albedo_tex")), str(sm.get_shader_parameter("alpha_tex")),
			str(sm.get_shader_parameter("normal_tex")), str(sm.get_shader_parameter("rough_tex"))])
	quit(0)


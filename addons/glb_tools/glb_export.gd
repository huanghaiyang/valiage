@tool
extends RefCounted
## 把若干节点（含子树）导出成新的 .glb。
##
## 用 Godot 自带的 glTF 导出器：`GLTFDocument.append_from_scene()` + `write_to_filesystem()`。
## 所以导出结果和编辑器里「导出为 glTF」是同一套管线，材质/贴图会一并写进 .glb（二进制内嵌）。
##
## 典型用途：一个 .glb 里有很多节点（比如那套 30 个 part 的墓地场景），只想留下其中几个。

## 导出。返回 { ok, message, path, bytes, nodes, meshes, materials }
##   nodes                —— 要导出的节点（可以是多层级的；会自动去掉"已被别的选中节点包含"的）
##   path                 —— 输出 .glb 路径（res:// 或绝对路径都行）
##   keep_world_transform —— true 时把每个节点按**世界变换**放好（多选不同位置的节点时保持相对位置）
static func export_nodes(nodes: Array, path: String, keep_world_transform := true) -> Dictionary:
	var picked := top_level_only(nodes)
	if picked.is_empty():
		return {"ok": false, "message": "没有可导出的节点（先在场景树里选中一个或多个节点）"}

	var root: Node = null
	if picked.size() == 1:
		root = _make_copy(picked[0], keep_world_transform)
	else:
		var holder := Node3D.new()
		holder.name = _safe_name(path.get_file().get_basename())
		for n in picked:
			holder.add_child(_make_copy(n, keep_world_transform))
		root = holder

	# 关键一步：glTF 导出器只导出"属于同一个场景"的节点，判断依据是 **owner 链**。
	# duplicate() 出来的子节点 owner 仍指向原场景的根（或为 null），不重挂的话导出的
	# glb 里只有一个光秃秃的根节点（实测：1 node / 0 mesh）。要按 Godot 的约定把
	# 所有后代节点的 owner 指到本次导出的根上。
	_own_all(root)

	var state := GLTFState.new()
	var doc := GLTFDocument.new()
	var err := doc.append_from_scene(root, state)
	if err != OK:
		root.free()
		return {"ok": false, "message": "构建 glTF 失败（append_from_scene 错误码 %d）" % err}

	var stats := _count(root)
	err = doc.write_to_filesystem(state, path)
	root.free()
	if err != OK:
		return {"ok": false, "message": "写文件失败（错误码 %d）：%s" % [err, path]}

	var size := 0
	if FileAccess.file_exists(path):
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size = f.get_length()
			f.close()
	return {
		"ok": true,
		"path": path,
		"bytes": size,
		"nodes": stats["nodes"],
		"meshes": stats["meshes"],
		"materials": stats["materials"],
		"message": "导出成功：%s（%d 个节点 / %d 个网格 / %d 个材质，%.2f MB）"
				% [path, stats["nodes"], stats["meshes"], stats["materials"], size / 1048576.0],
	}


## 这个节点值不值得导出：必须是有网格的 3D 节点（或它子树里有网格）。
## 「导出 GLB」工具栏按钮用它决定是否显示。
static func is_exportable(n: Node) -> bool:
	if not (n is Node3D):
		return false
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		return true
	var stack: Array = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is MeshInstance3D and (cur as MeshInstance3D).mesh != null:
			return true
		for c in cur.get_children():
			stack.append(c)
	return false


## 过滤出可导出的节点（保持原顺序）
static func exportable_only(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		if n is Node and is_instance_valid(n) and is_exportable(n):
			out.append(n)
	return out


## 去掉"被别的选中节点包含"的节点，避免同一个子树被导出两次
static func top_level_only(nodes: Array) -> Array:
	var valid: Array = []
	for n in nodes:
		if n is Node and is_instance_valid(n) and not valid.has(n):
			valid.append(n)
	var out: Array = []
	for n in valid:
		var covered := false
		for other in valid:
			if other != n and (other as Node).is_ancestor_of(n as Node):
				covered = true
				break
		if not covered:
			out.append(n)
	return out


static func _make_copy(n: Node, keep_world: bool) -> Node:
	var dup: Node = n.duplicate()
	if keep_world and n is Node3D and dup is Node3D:
		(dup as Node3D).transform = accumulated_transform(n as Node3D)
	return dup


## 取节点相对"顶层祖先"的变换。
## 注意：不在场景树里的节点（临时节点、单元测试夹具）`global_transform` 会返回单位矩阵
## 并且报错，所以那种情况自己沿父链累乘。
static func accumulated_transform(n: Node3D) -> Transform3D:
	if n.is_inside_tree():
		return n.global_transform
	var xf := Transform3D.IDENTITY
	var cur: Node = n
	while cur is Node3D:
		xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


## 把 root 的所有后代节点的 owner 重新指向 root（root 自己的 owner 保持 null）
static func _own_all(root: Node) -> void:
	for c in root.get_children():
		_stamp_owner(c, root)


static func _stamp_owner(n: Node, owner_node: Node) -> void:
	n.owner = owner_node
	for c in n.get_children():
		_stamp_owner(c, owner_node)


static func _count(root: Node) -> Dictionary:
	var nodes := 0
	var meshes := 0
	var mats := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		nodes += 1
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			meshes += 1
			for i in mi.mesh.get_surface_count():
				var mat := mi.get_active_material(i)
				if mat != null:
					mats[mat.get_instance_id()] = true
		for c in n.get_children():
			stack.append(c)
	return {"nodes": nodes, "meshes": meshes, "materials": mats.size()}


static func _safe_name(raw: String) -> String:
	var out := ""
	for ch in raw:
		if ch.is_valid_identifier() or ch.is_valid_int() or ch in "-_ .":
			out += ch
		else:
			out += "_"
	return out if not out.is_empty() else "Exported"


## 把节点名变成安全的文件名片段（拆分导出时用）
static func safe_name(raw: String) -> String:
	var out := ""
	for ch in raw:
		out += ch if (ch.is_valid_identifier() or ch.is_valid_int() or ch == "-" or ch == "_") else "_"
	return out if not out.is_empty() else "node"
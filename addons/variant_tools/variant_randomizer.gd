@tool
extends RefCounted
## 通用「变体随机化」：把一组节点（场景实例）按权重随机换成你指定的任意 .tscn 之一。
##
## 识别实例的方式：只看节点的 scene_file_path 是否在**变体列表**里 ——
## 所以不依赖任何刷草/摆放插件的内部结构（World Brush、手摆、别的工具都行）。
##
## 保留：节点在层级里的位置、局部变换（位置/旋转/缩放）、名字、可见性。
## 支持编辑器撤销（走 EditorUndoRedoManager）。

## 权重规则：按文件名关键字给权重（越大越常出现）。
## 列表里没匹配到任何关键字的，权重 = 1（即在你选的这批里均匀随机）。
const WEIGHT_RULES := [
	["small", 6], ["medium", 6], ["single", 3], ["seedling", 3],
	["flattened", 2], ["dead", 1],
]


static func weight_for(file_name: String) -> int:
	var low := file_name.to_lower()
	for rule in WEIGHT_RULES:
		if low.contains(String(rule[0])):
			return int(rule[1])
	return 1


## 扫一个目录里的所有 .tscn
static func collect_variants(dir_path: String) -> Array:
	var out: Array = []
	var da := DirAccess.open(dir_path)
	if da == null:
		return out
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if not da.current_is_dir() and f.ends_with(".tscn"):
			out.append(dir_path.path_join(f))
		f = da.get_next()
	da.list_dir_end()
	return out


## 找出一棵子树里所有"属于这批变体"的实例节点
static func find_instances(root: Node, variant_paths: Array) -> Array:
	var out: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		# 注意：**root 自己也算**（用户可能直接选中一个实例节点，而不是容器）
		if not String(n.scene_file_path).is_empty() and variant_paths.has(String(n.scene_file_path)):
			out.append(n)
			continue               # 实例内部不再往下找
		for c in n.get_children():
			stack.append(c)
	return out


## World Brush 用它来认"这是我刷的实例"（常量值见 world_brush_plugin.gd L63）
const WB_INSTANCE_META := &"world_brush_instance"


## 修复：给子树里"是场景实例、但没有 World Brush 标记"的节点补上标记。
## 用途：早期版本随机化出来的实例没继承这个标记 -> World Brush 擦不掉它们。
static func repair_wb_meta(root: Node) -> Dictionary:
	var fixed := 0
	var scanned := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var is_inst := not String(n.scene_file_path).is_empty()
		if is_inst:
			scanned += 1
			if not bool(n.get_meta(WB_INSTANCE_META, false)):
				n.set_meta(WB_INSTANCE_META, true)
				fixed += 1
			continue
		for c in n.get_children():
			stack.append(c)
	return {"ok": true, "scanned": scanned, "fixed": fixed,
			"message": "扫描到 %d 个场景实例，补上 World Brush 标记 %d 个" % [scanned, fixed]}


## 诊断用：列出子树里**所有**场景实例实际引用的场景路径（按出现次数）
## 用途：用户选的变体和实例对不上时，告诉他实例到底是什么。
static func survey_scene_paths(root: Node) -> Dictionary:
	var out := {}
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if not String(n.scene_file_path).is_empty():
			var k := String(n.scene_file_path)
			out[k] = int(out.get(k, 0)) + 1
			continue
		for c in n.get_children():
			stack.append(c)
	return out


## 核心。variant_paths: 允许的变体路径数组（至少 2 个）
static func randomize(root: Node, variant_paths: Array, seed_value: int = 0) -> Dictionary:
	var paths: Array = []
	for p in variant_paths:
		var s := String(p)
		if not s.is_empty() and not paths.has(s):
			paths.append(s)
	if paths.size() < 2:
		return {"ok": false, "message": "至少需要选 2 个变体（现在 %d 个）" % paths.size(), "changed": 0}
	var weights: Array = []
	for p in paths:
		weights.append(weight_for(String(p).get_file()))

	var action: Variant = null
	if Engine.is_editor_hint() and EditorInterface.has_method("get_editor_undo_redo"):
		var ur: Variant = EditorInterface.get_editor_undo_redo()
		if ur != null:
			ur.create_action("随机化变体")
			action = ur

	var rng := RandomNumberGenerator.new()
	if seed_value != 0:
		rng.seed = seed_value
	else:
		rng.randomize()

	var instances := find_instances(root, paths)
	var changed := 0
	var dist := {}
	for inst in instances:
		var node := inst as Node3D
		if node == null:
			continue
		var pick := _pick(rng, paths, weights)
		if pick == String(node.scene_file_path):
			# 抽到和当前一样 -> 换一个，保证每次都有变化
			for i in range(paths.size()):
				var alt := String(paths[(i + 1) % paths.size()])
				if alt != String(node.scene_file_path):
					pick = alt
					break
			if pick == String(node.scene_file_path):
				continue
		var ps: PackedScene = load(pick)
		if ps == null or not ps.can_instantiate():
			continue
		var fresh := ps.instantiate()
		if not (fresh is Node3D):
			fresh.free()
			continue
		fresh.name = node.name
		(fresh as Node3D).transform = node.transform
		fresh.visible = node.visible
		# ★ 继承原节点全部元数据（World Brush 的 INSTANCE_META 就靠这个，
		# 不继承的话随机化后就擦不掉了）
		for k in node.get_meta_list():
			fresh.set_meta(k, node.get_meta(k))
		var parent := node.get_parent()
		if parent == null:
			fresh.free()
			continue
		var idx := node.get_index()
		# 顺序很重要：**先移除旧节点再加新节点**，否则新旧同名会被 Godot 改名成 @Node3D@N
		if action != null:
			action.add_do_method(parent, "remove_child", node)
			action.add_do_method(parent, "add_child", fresh)
			action.add_do_method(parent, "move_child", fresh, idx)
			action.add_do_method(fresh, "set_owner", node.owner)
			action.add_do_reference(node)
			action.add_undo_method(parent, "remove_child", fresh)
			action.add_undo_method(parent, "add_child", node)
			action.add_undo_method(parent, "move_child", node, idx)
			action.add_undo_method(node, "set_owner", parent.owner)
			action.add_undo_reference(fresh)
			parent.remove_child(node)
			parent.add_child(fresh)
			parent.move_child(fresh, idx)
			fresh.owner = node.owner
		else:
			parent.remove_child(node)
			parent.add_child(fresh)
			parent.move_child(fresh, idx)
			fresh.owner = node.owner
			node.queue_free()
		var base := pick.get_file().get_basename()
		dist[base] = int(dist.get(base, 0)) + 1
		changed += 1
	if action != null:
		action.commit_action()
	# 只把**前几名**放进 message：一整行几十种变体会把对话框撑到几千像素宽。
	# 完整的分布放在 dist 里，调用方可以打到 Output 面板。
	var items: Array = []
	for k in dist.keys():
		items.append([String(k), int(dist[k])])
	# 按数量从多到少（数量很少，手写插入排序，避免用 lambda）
	for i in range(1, items.size()):
		var cur: Array = items[i]
		var j := i - 1
		while j >= 0 and int(items[j][1]) < int(cur[1]):
			items[j + 1] = items[j]
			j -= 1
		items[j + 1] = cur
	var top: Array = []
	for i in range(mini(6, items.size())):
		top.append("%s×%d" % [items[i][0], int(items[i][1])])
	var more := ""
	if items.size() > 6:
		more = " 等 %d 种" % items.size()
	return {
		"ok": true,
		"message": "实例 %d 个，替换 %d 个 ｜ %s%s" % [instances.size(), changed, " ".join(top), more],
		"changed": changed,
		"dist": dist,
	}


static func _pick(rng: RandomNumberGenerator, paths: Array, weights: Array) -> String:
	var total := 0
	for w in weights:
		total += int(w)
	if total <= 0:
		return String(paths[0])
	var r := rng.randi_range(1, total)
	var acc := 0
	for i in range(paths.size()):
		acc += int(weights[i])
		if r <= acc:
			return String(paths[i])
	return String(paths[0])
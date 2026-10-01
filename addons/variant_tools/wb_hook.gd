@tool
extends RefCounted
## 监听 World Brush（以及任何工具）新放置的场景实例，按该"来源场景"配置的变体表随机替换。
##
## 做法：接 SceneTree.node_added 信号（**不改 World Brush 源码**）。
## 关键细节：
##  1) node_added 时节点还没被摆好（变换/名字往往在 add_child 之后才设）-> 延后一帧再换。
##  2) 我自己替换进去的新节点会被打上 vt_done 标记，否则会再触发一次 -> 无限递归。

const Randomizer := preload("res://addons/variant_tools/variant_randomizer.gd")
const VariantSets := preload("res://addons/variant_tools/variant_sets.gd")
const DONE_META := &"vt_done"

var _pending: Array = []          # 待处理的节点（下一帧处理）
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	_rng.randomize()


## 由 plugin 在 _process 里调用（每帧一次）
func poll(tree: SceneTree) -> void:
	if tree == null:
		return
	if not tree.node_added.is_connected(_on_node_added):
		tree.node_added.connect(_on_node_added)
	if _pending.is_empty():
		return
	var todo := _pending
	_pending = []
	for item in todo:
		_do_swap(item)


func _on_node_added(node: Node) -> void:
	if not Engine.is_editor_hint():
		return
	if node == null or not is_instance_valid(node):
		return
	if node.has_meta(DONE_META):
		return
	var path := String(node.scene_file_path)
	if path.is_empty():
		return
	var cfg: Dictionary = VariantSets.get_set(path)
	if not bool(cfg.get("on", false)):
		return
	var variants: Array = cfg.get("variants", [])
	if variants.size() < 2:
		return
	_pending.append(node)


func _do_swap(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var path := String(node.scene_file_path)
	var cfg: Dictionary = VariantSets.get_set(path)
	if not bool(cfg.get("on", false)):
		return
	var variants: Array = cfg.get("variants", [])
	if variants.size() < 2:
		return
	var parent := node.get_parent()
	if parent == null:
		return
	var pick := _pick(variants)
	# ★★ 关键：**原地换 mesh，不换节点**。
	# 之前是 remove_child + add_child + queue_free —— 绕过了编辑器的撤销系统，
	# 把场景状态搞乱，导致之后场景树里连"删除"都失灵。
	# 原地换 mesh 则节点/owner/元数据/变换/World Brush 的记账全都不动，
	# 对 World Brush 完全透明（它的 INSTANCE_META、擦除、存档全都照常）。
	if _swap_in_place(node, pick):
		return
	# 兜底：两边结构对不上（例如实例里不是 MeshInstance3D）时才换节点，
	# 而且要在编辑器撤销系统里做，不能裸删。
	_replace_node(node, pick)


## 把 node 里第一个 MeshInstance3D 的网格换成 pick 的网格（节点本身不动）
func _swap_in_place(node: Node3D, pick: String) -> bool:
	var own := _first_mesh(node)
	if own == null:
		return false
	var ps: PackedScene = load(pick)
	if ps == null or not ps.can_instantiate():
		return false
	var tmp := ps.instantiate()
	var dst := _first_mesh(tmp)
	if dst == null or dst.mesh == null:
		tmp.free()
		return false
	own.mesh = dst.mesh
	own.material_override = dst.material_override
	tmp.free()
	return true


func _first_mesh(root: Node) -> MeshInstance3D:
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			return n as MeshInstance3D
		for c in n.get_children():
			stack.append(c)
	return null


## 兜底换节点：走编辑器撤销系统（避免再次搞乱场景状态）
func _replace_node(node: Node3D, pick: String) -> void:
	var ps: PackedScene = load(pick)
	if ps == null or not ps.can_instantiate():
		return
	var fresh := ps.instantiate()
	if not (fresh is Node3D):
		fresh.free()
		return
	for k in node.get_meta_list():
		fresh.set_meta(k, node.get_meta(k))
	fresh.set_meta(DONE_META, true)
	fresh.name = node.name
	(fresh as Node3D).transform = node.transform
	fresh.visible = node.visible
	var parent := node.get_parent()
	if parent == null:
		fresh.free()
		return
	var idx := node.get_index()
	var ur: Variant = null
	if EditorInterface.has_method("get_editor_undo_redo"):
		ur = EditorInterface.get_editor_undo_redo()
	if ur != null:
		ur.create_action("随机变体（放置）")
		ur.add_do_method(parent, "remove_child", node)
		ur.add_do_method(parent, "add_child", fresh)
		ur.add_do_method(parent, "move_child", fresh, idx)
		ur.add_do_method(fresh, "set_owner", node.owner)
		ur.add_do_reference(node)
		ur.add_undo_method(parent, "remove_child", fresh)
		ur.add_undo_method(parent, "add_child", node)
		ur.add_undo_method(parent, "move_child", node, idx)
		ur.add_undo_method(node, "set_owner", node.owner)
		ur.add_undo_reference(fresh)
		parent.remove_child(node)
		parent.add_child(fresh)
		parent.move_child(fresh, idx)
		fresh.owner = node.owner
		ur.commit_action()
	else:
		parent.remove_child(node)
		parent.add_child(fresh)
		parent.move_child(fresh, idx)
		fresh.owner = node.owner


func _pick(variants: Array) -> String:
	var weights: Array = []
	var total := 0
	for v in variants:
		var w := Randomizer.weight_for(String(v).get_file())
		weights.append(w)
		total += w
	if total <= 0:
		return String(variants[0])
	var r := _rng.randi_range(1, total)
	var acc := 0
	for i in range(variants.size()):
		acc += int(weights[i])
		if r <= acc:
			return String(variants[i])
	return String(variants[0])
@tool
extends EditorInspectorPlugin
## 【合批开关 · 两层】都长在**节点自己的检查器**里 ✓
##
##   ① **模型根节点**（有多个子节点时）→「是否允许合批」
##        · 默认**不勾选** ✗
##        · 勾上 = 写 meta `allow_batch = true` ✓（Ctrl+S 保存场景进 .tscn ✓）
##
##   ② **每个子网格**（当它的模型根已允许合批时才显示 ✓）→「参与合批」
##        · 默认**勾选** ✓（= 全部子件都并入 ✓）
##        · 取消 = 写 meta `batch = false` ✓（该子件保持独立 ✓）
##
## 运行时 `scripts/world/prop_merge.gd`：
##   · 只有 **`allow_batch == true`** 的子树才会被合并 ✓
##   · 其中 **`batch == false`** 的子件被跳过、保持独立 ✓
##
## ⚠ 勾/取消根节点后，**重新点一下节点**（或点空白再点回来）即可让子件的复选框出现/消失 ✓
const META_ALLOW := "allow_batch"
const META_SELF := "batch"


func _can_handle(object: Object) -> bool:
	if object is MeshInstance3D:
		return _allow_root_of(object as Node) != null      # ② 根允许了才显示 ✓
	if object is Node3D:
		return _is_model_root(object as Node3D)            # ① 多子件才显示 ✓
	return false


func _parse_begin(object: Object) -> void:
	if object is MeshInstance3D:
		var mi := object as MeshInstance3D
		var c1 := CheckBox.new()
		c1.text = "参与合批（本子件是否并入合并网格）"
		c1.button_pressed = bool(mi.get_meta(META_SELF, true))          # 默认勾上 ✓
		c1.tooltip_text = "取消 = 写 meta「%s = false」✓ → 该子件保持独立、不合并 ✓\n（运行时 prop_merge.gd 会跳过它 ✓）" % META_SELF
		c1.toggled.connect(_on_self_toggled.bind(mi))
		add_custom_control(c1)
		return
	var n := object as Node3D
	if n == null:
		return
	var c2 := CheckBox.new()
	c2.text = "是否允许合批（本节点有多个子件）"
	c2.button_pressed = n.has_meta(META_ALLOW) and bool(n.get_meta(META_ALLOW))   # 默认不勾 ✓
	c2.tooltip_text = "勾上 = 写 meta「%s = true」✓；取消 = 移除该 meta ✓\n运行时只合并「属性存在且为 true」的模型 ✓\n⚠ 勾完后重新点一下本节点，子件的「参与合批」复选框才会出现 ✓" % META_ALLOW
	c2.toggled.connect(_on_allow_toggled.bind(n))
	add_custom_control(c2)


## 从某节点往上找"允许合批"的模型根祖先 ✓（不含自己 ✓）
func _allow_root_of(n: Node) -> Node:
	var cur: Node = n.get_parent()
	while cur != null:
		if cur.has_meta(META_ALLOW) and bool(cur.get_meta(META_ALLOW)):
			return cur
		cur = cur.get_parent()
	return null


## 是否是"值得合批的模型根"：≥2 个子节点 且 ≥2 个网格后代 ✓
func _is_model_root(n: Node3D) -> bool:
	if n.get_child_count() < 2:
		return false
	var meshes := 0
	var st: Array = [n]
	while not st.is_empty() and meshes < 2:
		var x = st.pop_back()
		if x is MeshInstance3D:
			meshes += 1
		for c in x.get_children():
			st.append(c)
	return meshes >= 2


func _on_allow_toggled(v: bool, n: Node3D) -> void:
	if n == null or not is_instance_valid(n):
		return
	if v:
		n.set_meta(META_ALLOW, true)
		print("[合批] 允许合批 ✓ %s（Ctrl+S 保存场景；再点一下本节点即可看到子件复选框 ✓）" % n.name)
	else:
		n.remove_meta(META_ALLOW)
		print("[合批] 不允许合批 ✗ %s（已移除 meta ✓）" % n.name)


func _on_self_toggled(v: bool, mi: MeshInstance3D) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	mi.set_meta(META_SELF, v)                 # 显式写入 true/false ✓（默认 true ✓）
	print("[合批] 子件 %s ｜ 参与合批 = %s" % [mi.name, str(v)])

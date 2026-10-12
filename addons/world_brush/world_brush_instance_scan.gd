@tool
extends RefCounted
##
## ============================ 本文件职责 ============================
## 【World Brush · 实例扫描】纯静态函数集合，回答两个问题：
##   1. 场景树里的某个 Node3D 算不算"笔刷刷出来的实例"（= 右键擦除的目标）？
##   2. WorldBrushInstances 容器的**整棵子树**里都有哪些实例 / 它们的摆放位置？
##
## ============================ 为什么单独一个文件 ============================
## 1. **可测**：插件主体 world_brush_plugin.gd 继承 EditorPlugin，而 EditorPlugin 在编辑器
##    之外根本实例化不了（headless 下实测："Class 'EditorPlugin' can only be instantiated
##    by editor"），所以判定逻辑留在插件里就没法被 tests/test_world_brush_erase.gd 覆盖；
## 2. **一份标准**：这段判定同时被"右键擦除"（收集目标）和"绘制间距"（避让已有实例）
##    使用，写在两处必然会漂移。
##
## ============================ 关键背景（本模块存在的理由） ============================
## 旧版擦除只做两件事：
##   · 遍历容器的**直接子节点**（不递归）；
##   · 只认 world_brush_instance 元数据。
## 但容器里的实例常常**不是直接子节点**，也**不一定带元数据**（别的脚本摆放、外部工具
## 整节点替换、手工归组到一层普通 Node 下都会这样）—— 于是右键擦除对它们**完全无效**
## （实测过一个有几百个实例的项目：旧写法一个都认不出）。本模块就是修法：
##   递归整棵子树 + 「是场景实例即算」。
##
## 注意：元数据常量与 world_brush_plugin.gd 顶部（写入方）必须逐字一致；这里是读取方。


## 与 world_brush_plugin.gd 的 INSTANCE_META 一致（插件刷实例时写入，这里读）。
const INSTANCE_META: StringName = &"world_brush_instance"

## 与 world_brush_plugin.gd 的 SOURCE_SCENE_META 一致。
const SOURCE_SCENE_META: StringName = &"world_brush_source_scene_path"

## 与 world_brush_plugin.gd 的 LOD_GROUP_META 一致（开了距离 LOD 时刷出来的是分组节点）。
const LOD_GROUP_META: StringName = &"world_brush_lod_group"

## 擦除快照的四个平行数组的键（顺序 = 读取顺序，别乱改）。
## instances 与 transforms/parents/indices 一一对应，撤销时按同一下标取用。
const SNAPSHOT_KEYS := [
	"instances",
	"transforms",
	"parents",
	"indices",
]


## 这个节点算不算"笔刷刷出来的实例"（即右键擦除的目标）。任意一条命中即算：
##   1. world_brush_instance 元数据          —— 本插件正常刷出来的实例；
##   2. world_brush_lod_group 元数据         —— 开了距离 LOD 时刷出来的分组节点；
##   3. world_brush_source_scene_path 元数据 —— 同上携带的来源场景信息；
##   4. scene_file_path 非空                —— ★ 兜底：变体工具把实例**整节点换成**另一个
##      .tscn 的实例后元数据可能没跟上（老版本替换、别的脚本摆放、手工归组），这类物体
##      依然挂在 WorldBrushInstances 里，必须照样能擦掉，否则整片都擦不动。
## 普通 Node/Node3D 分组（没有场景路径也没有元数据）不算 —— 所以只会在里面继续找，
## 不会把分组本身当实例删掉。
## 参数写成 Node 而不是 Node3D：调用方（递归扫描）拿到的就是任意子节点，非 3D 分组
## 一律返回 false，不要求调用方先做类型判断。
static func is_brush_instance(node: Node) -> bool:
	if node == null or not is_instance_valid(node):
		return false

	if bool(node.get_meta(INSTANCE_META, false)):
		return true

	if bool(node.get_meta(LOD_GROUP_META, false)):
		return true

	if not str(node.get_meta(SOURCE_SCENE_META, "")).is_empty():
		return true

	if not node is Node3D:
		return false

	return not (node as Node3D).scene_file_path.is_empty()


## 递归收集 node 子树里所有笔刷实例，追加进 result。
## 命中即**整棵不再往下找**：实例内部自带的子网格/附件不是独立实例，不能当擦除目标。
## ★ 必须把**所有**子节点都递归进去，不能只递归 Node3D：很多项目会把实例归到一层
##   普通 Node 分组下，"只处理 Node3D" 会让整片实例一个都扫不到。
static func collect_brush_instances(
	node: Node,
	result: Array[Node3D]
) -> void:
	if node == null:
		return

	for child in node.get_children():
		if child is Node3D and is_brush_instance(child):
			result.append(child as Node3D)

			continue

		collect_brush_instances(child, result)


## 收集 container 子树里**水平距离**落在 radius 内的所有实例。
## 参数：container —— WorldBrushInstances 容器（或其下任意子树）；
##       center    —— 笔刷圆心（编辑器里就是光标命中的表面点）；radius —— 笔刷半径。
## 只用水平距离（忽略 Y）：和绘制时的间距判定同一套语义，山地上也能正常选中。
static func collect_instances_in_radius(
	container: Node3D,
	center: Vector3,
	radius: float
) -> Array[Node3D]:
	var matches: Array[Node3D] = []

	if container == null or not is_instance_valid(container):
		return matches

	var candidates: Array[Node3D] = []

	collect_brush_instances(container, candidates)

	var radius_squared := radius * radius

	for instance in candidates:
		if not is_instance_valid(instance):
			continue

		if (
			horizontal_distance_squared(
				instance.global_position,
				center
			)
			> radius_squared
		):
			continue

		matches.append(instance)

	return matches


## 递归收集子树里所有实例的摆放位置（供绘制间距避让用）。
## 只记**实例**的位置：命中实例就不再往实例内部统计（子网格的 global_position 不是摆放点，
## 统计进来会凭空收紧间距，让笔刷在同一点怎么刷都刷不出来）；普通分组节点只是路过，
## 它自己的原点也不是摆放点，同样不记 —— 但会继续往里找。
static func collect_existing_positions(
	node: Node,
	result: Array[Vector3]
) -> void:
	if node == null:
		return

	for child in node.get_children():
		if child is Node3D and is_brush_instance(child):
			result.append((child as Node3D).global_position)

			continue

		collect_existing_positions(child, result)


## 两个点之间的**水平**（XZ）距离平方。用平方比较省一次开方。
static func horizontal_distance_squared(
	first: Vector3,
	second: Vector3
) -> float:
	var difference := Vector2(
		first.x - second.x,
		first.z - second.z
	)

	return difference.length_squared()


## 把实例从它**当前**的父节点上摘下来。副作用：instance.owner = null。
## 返回 {"parent": Node, "index": int, "transform": Transform3D}；
## 实例无效 / 没有父节点（已经被摘掉过）时返回 {}，调用方据此跳过。
## 为什么要返回这三样：撤销时必须还原到**同一个父节点、同一位次**，而这些信息只有在
## 摘下来之前才是可靠的 —— 父节点可能是容器下的普通 Node 分组，不是容器本身。
static func detach_instance(instance: Node3D) -> Dictionary:
	if instance == null or not is_instance_valid(instance):
		return {}

	var parent := instance.get_parent()

	if parent == null:
		return {}

	var info := {
		"parent": parent,
		"index": instance.get_index(),
		"transform": instance.global_transform,
	}

	instance.owner = null

	parent.remove_child(instance)

	return info


## 批量摘下（擦除一次 = 一批）。返回与传入 instances 同序的四个平行数组：
##   {"instances": Array[Node3D], "transforms": Array[Transform3D],
##    "parents": Array[Node], "indices": Array[int]}
## 摘不下来的（已经不在树上 / 没有父节点）会被跳过，所以返回的数组可能比传入的短。
## 快照的这四个数组就是撤销/重做要用的全部信息，直接喂给 restore_instances()。
static func detach_instances(instances: Array) -> Dictionary:
	var detached: Array[Node3D] = []
	var transforms: Array[Transform3D] = []
	var parents: Array[Node] = []
	var indices: Array[int] = []

	for value in instances:
		# ★ 先 is_instance_valid 再 `is`：已释放实例上做类型判断会抛
		#   "Left operand of 'is' is a previously freed instance"。
		if not is_instance_valid(value):
			continue

		if not value is Node3D:
			continue

		var info := detach_instance(value as Node3D)

		if info.is_empty():
			continue

		var saved_parent: Node = info.get("parent")
		var saved_transform: Transform3D = info.get("transform")

		detached.append(value as Node3D)
		transforms.append(saved_transform)
		parents.append(saved_parent)
		indices.append(int(info.get("index", -1)))

	return {
		"instances": detached,
		"transforms": transforms,
		"parents": parents,
		"indices": indices,
	}


## 把一批实例摘下来并**累加**进 snapshot，返回这一批摘下的数量。
## 为什么要"累加"：擦除是拖着鼠标一路刷出来的 —— 一次 stroke 里每个 stamp 都会摘一批，
## 而撤销要把**整条 stroke** 的实例一起还原。覆盖式写入只会还原最后一笔（实测会丢前面几笔）。
## snapshot 就地改写（GDScript 的 Array/Dictionary 是引用类型）；缺键会自动补齐。
static func detach_into(
	snapshot: Dictionary,
	instances: Array
) -> int:
	var batch := detach_instances(instances)
	var new_instances: Array = batch.get("instances", [])

	if new_instances.is_empty():
		return 0

	for key in SNAPSHOT_KEYS:
		if not snapshot.has(key) or not snapshot[key] is Array:
			snapshot[key] = []

	# 取出来的是字典里**同一个**数组，append 会写回字典。
	var target_instances: Array = snapshot["instances"]
	var target_transforms: Array = snapshot["transforms"]
	var target_parents: Array = snapshot["parents"]
	var target_indices: Array = snapshot["indices"]

	target_instances.append_array(new_instances)
	target_transforms.append_array(batch.get("transforms", []))
	target_parents.append_array(batch.get("parents", []))
	target_indices.append_array(batch.get("indices", []))

	return new_instances.size()


## 快照里的实例数（缺键 / 空快照都安全）。
static func snapshot_count(snapshot: Dictionary) -> int:
	var instances: Variant = snapshot.get("instances", [])

	if not instances is Array:
		return 0

	return (instances as Array).size()


## 从快照数组里取第 index 个"原来的父节点"；取不到（越界 / 分组已被删）就退回 fallback。
## 折返到 fallback 而不是直接放弃，是为了让一次擦除的撤销不会因为某一个分组没了而整体中断。
## ★ 必须**先** is_instance_valid 再判断类型：分组被用户删掉后，快照里存的是已释放实例，
##   直接写 `saved_parent is Node` 会抛 "Left operand of 'is' is a previously freed instance"
##   并中断整个撤销。
static func resolve_saved_parent(
	parents: Array,
	index: int,
	fallback: Node
) -> Node:
	if index >= 0 and index < parents.size():
		var saved_parent: Variant = parents[index]

		if is_instance_valid(saved_parent):
			return saved_parent as Node

	return fallback


## 撤销时把实例挂回去：优先挂回快照记录的 parent（失效则 fallback），恢复位次、owner
## 与**全局**变换。返回实际使用的父节点（挂不回去时返回 null）。
static func restore_instance(
	instance: Node3D,
	parent: Node,
	fallback: Node,
	index: int,
	saved_transform: Variant,
	scene_owner: Node
) -> Node:
	if instance == null or not is_instance_valid(instance):
		return null

	var target := parent

	if target == null or not is_instance_valid(target):
		target = fallback

	if target == null or not is_instance_valid(target):
		return null

	if instance.get_parent() == null:
		target.add_child(
			instance,
			true
		)

		if index >= 0 and index < target.get_child_count():
			target.move_child(
				instance,
				index
			)

	if scene_owner != null:
		instance.owner = scene_owner

	if saved_transform is Transform3D:
		instance.global_transform = saved_transform

	return target


## 批量挂回（撤销一次擦除）。返回实际挂回的数量。
##
## ★★ 必须按**摘下的逆序**挂回 ★★
## 每个实例记下的 index 是"摘下当时、在剩余兄弟里的位次"，不是原始位次。顺序挂回会把
## 后挂的实例插到前面去（实测 [A,B,C] 会变成 [B,A,C]）；逆序挂回才能逐层还原成原顺序：
##   [A,B,C] -> 摘 C(idx 2) -> [A,B] -> 摘 B(idx 1) -> [A]
##   逆序挂回：B(idx 1) -> [A,B]；C(idx 2) -> [A,B,C] ✓
## 分组被删掉时逐个退回 fallback（container），不让整次撤销中断。
static func restore_instances(
	instances: Array,
	parents: Array,
	indices: Array,
	transforms: Array,
	container: Node,
	scene_owner: Node
) -> int:
	var restored := 0

	for index in range(
		instances.size() - 1,
		-1,
		-1
	):
		var value: Variant = instances[index]

		if not is_instance_valid(value):
			continue

		if not value is Node3D:
			continue

		var instance := value as Node3D

		var saved_parent := resolve_saved_parent(
			parents,
			index,
			container
		)

		var saved_index: int = -1

		if index < indices.size():
			saved_index = int(indices[index])

		var saved_transform: Variant = null

		if index < transforms.size():
			saved_transform = transforms[index]

		if (
			restore_instance(
				instance,
				saved_parent,
				container,
				saved_index,
				saved_transform,
				scene_owner
			)
			!= null
		):
			restored += 1

	return restored

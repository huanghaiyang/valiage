@tool
extends McpTestSuite
## World Brush 右键擦除自检（addons/world_brush）。
##
## 修的 bug：**变体工具替换过的物体，World Brush 右键擦不掉**。
## 真实原因有两层，缺一条都擦不动（scenes/main.tscn 实测）：
##   ① 擦除只遍历容器的**直接子节点**，而真实的草被归到普通 Node 分组里：
##      WorldBrushInstances / 墓地周围草丛(普通 Node) / BlendExport1..754(草的场景实例)；
##   ② 只认 world_brush_instance 元数据，而那 754 个实例**一个都没有**（变体工具整节点
##      替换 / 早期脚本摆放 / 手工归组都会丢）。
## 本套件照抄这个结构，验证：
##   · 嵌套 + 无元数据的实例照样能被选中（world_brush_instance_scan.gd 的 collect_instances_in_radius）；
##   · 普通分组节点自己不会被当成实例（不会被误删）；
##   · 半径用的是水平距离（Y 不参与）；
##   · 摘下/挂回能还原到**同一个父节点、同一个全局变换、原来的兄弟顺序**（Ctrl+Z 的关键）；
##   · 一次拖拽擦除的多个 stamp 会**累加**进同一份快照（覆盖式写入只还原最后一笔）；
##   · 分组被删掉时挂回退到容器，不让整次撤销中断；
##   · 插件主体确实把这套逻辑接到了擦除上（防止日后回退成"只扫一层 + 只认元数据"）。
##
## 跑法：MCP 测试工具跑 res://tests/ 下的套件即可；本套件不需要打开场景、不需要编辑器上下文。

const SCAN_PATH := "res://addons/world_brush/world_brush_instance_scan.gd"
const PLUGIN_PATH := "res://addons/world_brush/world_brush_plugin.gd"
const GRASS_SCENE_PATH := "res://scenes/草/grass_bermuda_01_dead_b.tscn"

const CONTAINER_META := &"world_brush_container"
const INSTANCE_META := &"world_brush_instance"
const SOURCE_SCENE_META := &"world_brush_source_scene_path"

## 期望被擦除的实例（照场景真实结构摆）：分组里两个无元数据、深一层分组里一个有元数据、
## 容器直接子节点一个（老路径，必须保持有效）。
var _expected: Array[Node3D] = []

var _root: Node3D
var _container: Node3D
var _group: Node
var _deep_group: Node3D
var _direct: Node3D
var _far: Node3D


func suite_name() -> String:
	return "world_brush_erase"


## 用 CACHE_MODE_IGNORE 读源码：preload 会命中资源缓存，改了脚本却跑旧代码
func _scan() -> GDScript:
	return ResourceLoader.load(SCAN_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _plugin_source() -> String:
	return FileAccess.get_file_as_string(PLUGIN_PATH)


## 造一棵与 scenes/main.tscn 同构的树：
##   _root / WorldBrushInstances(容器) / 墓地周围草丛(普通 Node) / BlendExport...(草实例)
## 所有实例都挂在世界原点附近，方便用 radius 直接筛选。
func setup() -> void:
	_expected.clear()

	var tree := Engine.get_main_loop() as SceneTree
	_root = Node3D.new()
	_root.name = "_McpTestWorldBrushRoot"
	track(_root)
	tree.root.add_child(_root)

	_container = Node3D.new()
	_container.name = "WorldBrushInstances"
	_container.set_meta(CONTAINER_META, true)
	_root.add_child(_container)

	# ① 普通 Node 分组（"墓地周围草丛"）—— 自己不是实例，只能往里找
	_group = Node.new()
	_group.name = "墓地周围草丛"
	_container.add_child(_group)

	var blend_1 := _make_instance("BlendExport", Vector3(0.0, 0.0, 0.0))
	blend_1.scene_file_path = GRASS_SCENE_PATH
	_group.add_child(blend_1)

	# ② 分组里第二个：连 scene_file_path 都被抹掉的极端情况（只有 SOURCE_SCENE_META 兜底）
	var blend_2 := _make_instance("BlendExport2", Vector3(1.5, 0.0, 0.5))
	blend_2.set_meta(SOURCE_SCENE_META, GRASS_SCENE_PATH)
	_group.add_child(blend_2)

	# ③ 更深一层分组 + 带正常元数据的实例（老结构也不能坏）
	_deep_group = Node3D.new()
	_deep_group.name = "sub"
	_deep_group.position = Vector3(0.0, 0.0, 2.0)
	_group.add_child(_deep_group)

	var blend_3 := _make_instance("BlendExport3", Vector3(0.0, 0.0, 2.0))
	blend_3.set_meta(INSTANCE_META, true)
	_deep_group.add_child(blend_3)

	# ④ 容器直接子节点（旧代码唯一能擦到的那一类）
	_direct = _make_instance("BlendExport4", Vector3(-2.0, 0.0, 0.0))
	_direct.set_meta(INSTANCE_META, true)
	_container.add_child(_direct)

	# ⑤ 半径外的实例：证明筛选真的按半径走
	_far = _make_instance("BlendExport5", Vector3(40.0, 0.0, 0.0))
	_far.set_meta(INSTANCE_META, true)
	_container.add_child(_far)

	for node in [_direct, blend_1, blend_2, blend_3]:
		if node != null:
			_expected.append(node)


## 真场景实例（草地）：scene_file_path 由引擎在 instantiate 时写上，最贴近实际
func _make_real_grass_instance(instance_name: String, at: Vector3) -> Node3D:
	var packed := load(GRASS_SCENE_PATH) as PackedScene
	if packed == null or not packed.can_instantiate():
		var fallback := _make_instance(instance_name, at)
		fallback.scene_file_path = GRASS_SCENE_PATH
		return fallback

	var created := packed.instantiate() as Node3D
	if created == null:
		return _make_instance(instance_name, at)

	created.name = instance_name
	created.position = at
	return created


## 普通 Node3D 实例替身：带一个子网格，用来验证"实例内部不再被递归当成实例"
func _make_instance(instance_name: String, at: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = instance_name
	node.position = at

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	mesh.mesh = BoxMesh.new()
	mesh.position = Vector3(0.0, 0.5, 0.0)
	node.add_child(mesh)

	return node


# =========================================================
# ① 选中：嵌套 + 无元数据也要能擦
# =========================================================

func test_nested_and_metadataless_instances_are_selected() -> void:
	var scan := _scan()
	assert_ne(scan, null, "%s 无法加载" % SCAN_PATH)

	var found: Array[Node3D] = scan.collect_instances_in_radius(
		_container,
		Vector3.ZERO,
		10.0
	)

	# 4 个期望的（含 2 个无元数据、1 个深一层嵌套、1 个直接子节点），半径外的 1 个不算
	assert_eq(found.size(), 4, "应选中 4 个实例，实际 %d 个：%s" % [found.size(), _names(found)])

	for instance in _expected:
		assert_true(found.has(instance), "漏掉了 %s（嵌套/无元数据）" % instance.name)

	# 内层子网格不是实例，不能被当成擦除目标
	for instance in found:
		assert_false(instance is MeshInstance3D, "%s 不该是网格节点" % instance.name)
		assert_ne(String(instance.name), "Mesh", "实例内部的子网格被当成了擦除目标")


func test_group_nodes_are_not_targets() -> void:
	var scan := _scan()

	assert_false(scan.is_brush_instance(_group), "普通 Node 分组被当成了实例")
	assert_false(scan.is_brush_instance(_deep_group), "Node3D 分组被当成了实例")
	assert_true(scan.is_brush_instance(_direct), "带元数据的实例判定失败")

	var found: Array[Node3D] = scan.collect_instances_in_radius(
		_container,
		Vector3.ZERO,
		10.0
	)
	assert_false(found.has(_group as Node3D), "分组节点混进了擦除目标")
	assert_false(found.has(_deep_group), "内层分组节点混进了擦除目标")


func test_radius_uses_horizontal_distance() -> void:
	var scan := _scan()

	# 水平距离 3m、但 Y 高 500m -> 仍在半径 5m 内（只看 XZ）
	_direct.position = Vector3(3.0, 500.0, 0.0)
	var near: Array[Node3D] = scan.collect_instances_in_radius(
		_container,
		Vector3.ZERO,
		5.0
	)
	assert_true(near.has(_direct), "只按 XZ 算距离： Y 再高也该命中")

	# 水平距离 40m -> 半径 5m 外，不命中
	assert_false(near.has(_far), "半径外的实例被选中了")


func test_real_scene_instance_is_recognized() -> void:
	var scan := _scan()
	var real := _make_real_grass_instance("_McpTestRealGrass", Vector3(2.0, 0.0, 0.0))
	_container.add_child(real)

	assert_false(String(real.scene_file_path).is_empty(), "instantiate 出来的实例没有 scene_file_path")
	assert_true(scan.is_brush_instance(real), "真实场景实例（变体替换后的典型形态）判定失败")

	var found: Array[Node3D] = scan.collect_instances_in_radius(
		_container,
		Vector3.ZERO,
		5.0
	)
	assert_true(found.has(real), "真实场景实例没被选中")


# =========================================================
# ② 摘下 / 挂回：Ctrl+Z 必须回到原分组、原位次
# =========================================================

func test_detach_then_restore_round_trip() -> void:
	var scan := _scan()

	var found: Array[Node3D] = scan.collect_instances_in_radius(
		_container,
		Vector3.ZERO,
		10.0
	)
	assert_eq(found.size(), 4, "前置条件：应选中 4 个")

	var transforms_before: Array = []
	for instance in found:
		transforms_before.append(instance.global_transform)

	# 摘：整批摘下，快照由插件保存（插件侧就是原样存这四个数组）
	var batch: Dictionary = scan.detach_instances(found)
	var batch_instances: Array = batch.get("instances", [])
	var parents: Array = batch.get("parents", [])
	var indices: Array = batch.get("indices", [])
	var transforms: Array = batch.get("transforms", [])

	assert_eq(batch_instances.size(), 4, "快照数量不对：%d" % batch_instances.size())
	for instance in found:
		assert_eq(instance.get_parent(), null, "%s 摘下后仍挂在父节点上" % instance.name)

	# 摘完之后一次都不该再选中
	var after_detach: Array[Node3D] = scan.collect_instances_in_radius(
		_container,
		Vector3.ZERO,
		10.0
	)
	assert_eq(after_detach.size(), 0, "摘除后仍能选中 %d 个" % after_detach.size())

	# 撤销：整批挂回（内部必须按摘下的逆序还原，否则顺序会乱）
	var restored: int = scan.restore_instances(
		batch_instances,
		parents,
		indices,
		transforms,
		_container,
		_root
	)
	assert_eq(restored, 4, "应挂回 4 个，实际 %d 个" % restored)

	for index in range(found.size()):
		var instance := found[index]
		assert_eq(instance.get_parent(), parents[index], "%s 没挂回原父节点" % instance.name)
		assert_eq(instance.owner, _root, "%s 的 owner 没还原" % instance.name)
		assert_true(
			instance.global_transform.is_equal_approx(transforms_before[index]),
			"%s 的全局变换没还原" % instance.name
		)

	# 原顺序必须完全一致。
	# 注意：快照里的 index 是"摘下当时、在剩余兄弟里的位次"，不是最终位次（擦除是逐个摘的，
	# 位次会随着兄弟一起减少而变化），所以验收点看**最终顺序**而不是逐个 index：
	#   [BlendExport, BlendExport2, sub] -> 摘完 -> 逆序挂回 -> 必须还是这个顺序。
	# 顺序挂回会把 BlendExport2 插到 BlendExport 前面（实测），这条就是那个坑的哨兵。
	assert_eq(_child_names(_group), ["BlendExport", "BlendExport2", "sub"], "分组里的顺序变了")
	assert_eq(
		_child_names(_container),
		["墓地周围草丛", "BlendExport4", "BlendExport5"],
		"容器里的顺序变了"
	)
	assert_eq(_child_names(_deep_group), ["BlendExport3"], "深一层分组里的顺序变了")

	# 重做：再整批摘一次，同样干净
	scan.detach_instances(found)
	var after_redo: Array[Node3D] = scan.collect_instances_in_radius(
		_container,
		Vector3.ZERO,
		10.0
	)
	assert_eq(after_redo.size(), 0, "重做后仍能选中 %d 个" % after_redo.size())


## 拖拽擦除 = 一次 stroke 里很多个 stamp，每个 stamp 摘一批。
## 快照必须**累加**（撤销要把整条 stroke 一起还原），且累加后逆序挂回仍要还原原顺序。
func test_multi_stamp_erase_accumulates_and_restores() -> void:
	var scan := _scan()

	var group_order_before := _child_names(_group)
	var container_order_before := _child_names(_container)

	var snapshot := {}
	var total := 0

	# stamp 1：容器直接子节点（模拟第一批）
	total += scan.detach_into(snapshot, [_direct])
	assert_eq(scan.snapshot_count(snapshot), 1, "第一笔快照数量不对")

	# stamp 2：分组里的两个实例（模拟拖到草上）
	total += scan.detach_into(snapshot, [_expected[1], _expected[2]])
	assert_eq(scan.snapshot_count(snapshot), 3, "快照没有累加（覆盖式写入会只剩最后一笔）")
	assert_eq(total, 3, "累计摘下数量不对：%d" % total)

	# stamp 3：再摘一个
	scan.detach_into(snapshot, [_expected[3]])
	assert_eq(scan.snapshot_count(snapshot), 4, "多笔快照累加数量不对")

	# 整条 stroke 一起撤销
	var restored: int = scan.restore_instances(
		snapshot.get("instances", []),
		snapshot.get("parents", []),
		snapshot.get("indices", []),
		snapshot.get("transforms", []),
		_container,
		_root
	)
	assert_eq(restored, 4, "应挂回 4 个，实际 %d 个" % restored)
	assert_eq(_child_names(_group), group_order_before, "分组顺序没能还原")
	assert_eq(_child_names(_container), container_order_before, "容器顺序没能还原")


func test_restore_falls_back_when_group_is_gone() -> void:
	var scan := _scan()

	var batch: Dictionary = scan.detach_instances([_expected[1]])
	var batch_instances: Array = batch.get("instances", [])
	var parents: Array = batch.get("parents", [])
	var indices: Array = batch.get("indices", [])
	var transforms: Array = batch.get("transforms", [])

	assert_eq(batch_instances.size(), 1, "前置条件：应摘下 1 个")
	var saved_parent: Node = scan.resolve_saved_parent(parents, 0, _container)
	assert_eq(saved_parent, _group, "前置条件：快照里的父节点应是那个普通 Node 分组")

	# 模拟用户把那个分组删掉了
	var group_parent := _group.get_parent()
	group_parent.remove_child(_group)
	_group.free()

	assert_false(is_instance_valid(saved_parent), "前置条件：分组应已失效")

	var fallback: Node = scan.resolve_saved_parent(parents, 0, _container)
	assert_eq(fallback, _container, "分组失效时应退回容器")

	# 分组没了也不能中断撤销：退到容器继续挂
	var restored: int = scan.restore_instances(
		batch_instances,
		parents,
		indices,
		transforms,
		_container,
		_root
	)
	assert_eq(restored, 1, "分组失效时没能兜底挂回")
	assert_eq(_expected[1].get_parent(), _container, "兜底挂回失败")


## 快照里的位次是"摘下当时"的；如果期间那层分组被别的操作清空/大幅缩短，
## 位次就会远大于当前子节点数。往 move_child 传越界值会让引擎报
## `local_vector.h ... Index p_pos = N is out of bounds`（用户真实遇到过：
## 旧变体工具留在撤销栈里的动作拿 630 去 move_child 一个只剩 90 个子节点的分组）。
## 本插件的 restore 必须自己挡掉：越界位次 = 直接追加，绝不能把它传进引擎。
func test_restore_tolerates_stale_indices_after_parent_shrank() -> void:
	var scan := _scan()

	# 造一层 8 个实例的分组（模拟"当年那一层有几百个实例"）
	var group := Node.new()
	group.name = "shrunken_group"
	_container.add_child(group)
	group.owner = _root

	var instances: Array[Node3D] = []
	for i in range(8):
		var instance := _make_instance("Stale%d" % i, Vector3(float(i), 0.0, 0.0))
		group.add_child(instance)
		# owner 必须在入树之后再设（否则引擎报 "Owner must be an ancestor in the tree"）
		instance.owner = _root
		instances.append(instance)

	var batch: Dictionary = scan.detach_instances(instances)
	var batch_instances: Array = batch.get("instances", [])
	var parents: Array = batch.get("parents", [])
	var indices: Array = batch.get("indices", [])
	var transforms: Array = batch.get("transforms", [])

	assert_eq(batch_instances.size(), 8, "前置条件：应摘下 8 个")

	# 分组随后被清空（用户又擦了一大片 / 手动删了）：快照里的位次 0..7 全部越界
	for child in group.get_children():
		group.remove_child(child)
		child.free()

	assert_eq(group.get_child_count(), 0, "前置条件：分组应已清空")

	# 撤销：越界位次必须被挡在 restore 内部（不能进 move_child）
	var restored: int = scan.restore_instances(
		batch_instances,
		parents,
		indices,
		transforms,
		_container,
		_root
	)

	assert_eq(restored, 8, "越界位次也必须全部挂回，实际 %d 个" % restored)
	assert_eq(
		group.get_child_count(),
		8,
		"分组里应重新有 8 个，实际 %d 个" % group.get_child_count()
	)

	for instance in instances:
		assert_eq(instance.get_parent(), group, "%s 没挂回原父节点" % instance.name)
		assert_eq(instance.owner, _root, "%s 的 owner 没还原" % instance.name)


# =========================================================
# ③ 绘制间距：位置统计不能再只扫一层
# =========================================================

func test_existing_positions_cover_nested_instances_only() -> void:
	var scan := _scan()

	var positions: Array[Vector3] = []
	scan.collect_existing_positions(_container, positions)

	assert_eq(positions.size(), 5, "应统计 5 个实例的位置，实际 %d 个" % positions.size())
	assert_true(positions.has(Vector3(-2.0, 0.0, 0.0)), "漏掉容器直接子节点的位置")
	assert_true(positions.has(Vector3(1.5, 0.0, 0.5)), "漏掉分组内实例的位置")
	assert_true(positions.has(Vector3(0.0, 0.0, 4.0)), "漏掉深一层分组内实例的位置")
	# 深一层分组自己的原点（0,0,2）与实例内子网格都不该出现
	assert_false(positions.has(Vector3(0.0, 0.0, 2.0)), "统计到了分组节点自己的原点")
	assert_false(positions.has(Vector3(0.0, 0.5, 0.0)), "统计到了实例内部的子网格位置")


# =========================================================
# ④ 接线：插件主体必须真的用这套逻辑来擦
# =========================================================

func test_plugin_erase_is_wired_to_scan_module() -> void:
	var source := _plugin_source()
	assert_false(source.is_empty(), "读不到 %s" % PLUGIN_PATH)

	assert_contains(source, "world_brush_instance_scan.gd", "插件没有预加载扫描模块")
	assert_contains(
		source,
		"INSTANCE_SCAN_SCRIPT.collect_instances_in_radius(",
		"擦除没有用递归扫描（又退回只扫一层了）"
	)
	assert_contains(
		source,
		"INSTANCE_SCAN_SCRIPT.detach_into(",
		"擦除没有用累加式快照（一次 stroke 会丢前面的笔数）"
	)
	assert_contains(
		source,
		"INSTANCE_SCAN_SCRIPT.detach_instances(",
		"重做没有用统一的整批摘下逻辑"
	)
	assert_contains(
		source,
		"INSTANCE_SCAN_SCRIPT.restore_instances(",
		"撤销没有用统一的整批挂回逻辑"
	)

	# 回退哨兵：旧写法（只扫直接子节点 + 只认元数据）不该再出现在擦除里
	assert_false(
		source.contains("for child in stroke_container.get_children()"),
		"擦除又变回只遍历直接子节点了"
	)
	assert_false(
		source.contains("func _collect_brush_instances"),
		"扫描逻辑被复制回插件主体了（应只留在 world_brush_instance_scan.gd）"
	)


## 回归前提：main.tscn 里确实存在"容器下的嵌套实例"这种结构（否则本 bug 不会出现）。
## 场景结构以后被整理过就自动跳过，不至于把无关改动判成失败。
func test_main_scene_still_has_nested_instances() -> void:
	var text := FileAccess.get_file_as_string("res://scenes/main.tscn")
	if text.is_empty():
		skip("读不到 scenes/main.tscn")
		return

	var nested_prefix := 'parent="WorldBrushInstances/'
	if not text.contains(nested_prefix):
		skip("main.tscn 里已经没有 WorldBrushInstances 下的嵌套实例了（结构被整理过）")
		return

	assert_contains(text, "WorldBrushInstances", "main.tscn 缺少 WorldBrushInstances 容器")
	var nested_count := 0
	for line in text.split("\n"):
		if String(line).begins_with("[node ") and String(line).contains(nested_prefix):
			nested_count += 1
	assert_gt(nested_count, 0, "嵌套实例计数异常")


# =========================================================
# 工具
# =========================================================

func _names(nodes: Array) -> String:
	var out: Array = []
	for node in nodes:
		if node is Node:
			out.append(String((node as Node).name))
	return ", ".join(out)


func _child_names(node: Node) -> Array:
	var out: Array = []
	for child in node.get_children():
		out.append(String(child.name))
	return out

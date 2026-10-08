@tool
extends McpTestSuite
## Object Strings 3D 插件自检（addons/object_strings，作者 32kda）。
## 覆盖：
##   ① 安装完整性：plugin.cfg / 两个脚本存在，且 project.godot 的 editor_plugins/enabled 已登记本插件；
##   ② 沿 Path3D 按 item_distance 成对摆放（左右两侧 number 与横向偏移）；
##   ③ left / right 开关生效；
##   ④ from_dist / to_dist 区间裁剪生效；
##   ⑤ 父节点不是 Path3D 时不生成任何实例（插件原样 printerr 提示）；
##   ⑥ main.tscn 的「墓园石制围墙」实例贴合路径中心线且底座贴地（曾整体偏移 30.55m 并埋进地形）。

const PLUGIN_CFG := "res://addons/object_strings/plugin.cfg"
const OBJECT_STRING_SCRIPT := "res://addons/object_strings/ObjectString.gd"
const PLACER_SCRIPT := "res://addons/object_strings/PathObjectsPlacer.gd"
const ENABLED_ENTRY := "res://addons/object_strings/plugin.cfg"


func suite_name() -> String:
	return "object_strings"


## 用 CACHE_MODE_IGNORE 读源码：preload 会命中资源缓存，改了脚本却跑旧代码
func _script(path: String) -> GDScript:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


## 直线路径：起点 (0,0,0) → 终点 (x_end,0,0)，便于直接用 x 推算采样点
func _make_path(x_end: float) -> Path3D:
	var path := Path3D.new()
	path.name = "TestPath"
	var curve := Curve3D.new()
	curve.add_point(Vector3.ZERO)
	curve.add_point(Vector3(x_end, 0.0, 0.0))
	path.curve = curve
	track(path)
	return path


func _make_item_scene() -> PackedScene:
	var packed := PackedScene.new()
	var mi := MeshInstance3D.new()
	mi.name = "Prop"
	mi.mesh = BoxMesh.new()
	packed.pack(mi)
	mi.free()
	return packed


## 插件用 basis.x 作为横向：左侧落在 -Z，右侧落在 +Z
func _side_counts(node: Node3D) -> Dictionary:
	var counts := {"left": 0, "right": 0, "other": 0}
	for child in node.get_children():
		var z: float = (child as Node3D).position.z
		if z < -0.01:
			counts.left += 1
		elif z > 0.01:
			counts.right += 1
		else:
			counts.other += 1
	return counts


func _new_string_on(path: Path3D, item: PackedScene) -> Node3D:
	var os: Node3D = _script(OBJECT_STRING_SCRIPT).new()
	os.name = "ObjectString"
	path.add_child(os)
	os.item = item
	return os


func test_plugin_installed_and_enabled() -> void:
	assert_true(FileAccess.file_exists(PLUGIN_CFG), "缺少 %s" % PLUGIN_CFG)
	assert_ne(_script(OBJECT_STRING_SCRIPT), null, "ObjectString.gd 无法加载")
	assert_ne(_script(PLACER_SCRIPT), null, "PathObjectsPlacer.gd 无法加载")
	assert_contains(FileAccess.get_file_as_string(PLUGIN_CFG), "ObjectStrings", "plugin.cfg 内容异常")
	# 读磁盘上的 project.godot：编辑器内存中的 ProjectSettings 要下次启动才刷新
	var project_cfg := FileAccess.get_file_as_string("res://project.godot")
	assert_contains(project_cfg, ENABLED_ENTRY, "project.godot 的 editor_plugins/enabled 未登记本插件")


func test_spawns_pairs_along_path() -> void:
	var path := _make_path(100.0)
	var os := _new_string_on(path, _make_item_scene())
	os.item_distance = 10.0
	os.distance_from_center = 3.0
	os.spawn_objects()

	assert_eq(os.get_child_count(), 20, "100m 路径 / 10m 间距 / 左右双侧 → 应为 20 个")
	var counts := _side_counts(os)
	assert_eq(counts.left, 10, "左侧（-Z）实例数")
	assert_eq(counts.right, 10, "右侧（+Z）实例数")
	assert_eq(counts.other, 0, "不应有横向偏移为 0 的实例")

	var first: Node3D = os.get_child(0)
	assert_true(absf(first.position.x - 5.0) < 0.01, "首个实例应在距起点半个间距处 x=5，实际 %s" % first.position.x)
	assert_true(absf(absf(first.position.z) - 3.0) < 0.01, "横向偏移应为 3m，实际 %s" % first.position.z)


func test_single_side_toggle() -> void:
	var path := _make_path(30.0)
	var os := _new_string_on(path, _make_item_scene())
	os.item_distance = 10.0
	os.left = false
	os.right = true
	os.spawn_objects()

	assert_eq(os.get_child_count(), 3, "30m / 10m 单侧 → 应为 3 个")
	var counts := _side_counts(os)
	assert_eq(counts.left, 0, "left=false 时不应有 -Z 实例")
	assert_eq(counts.right, 3, "right=true 时应全部落在 +Z")


func test_distance_window_clips_range() -> void:
	var path := _make_path(100.0)
	var os := _new_string_on(path, _make_item_scene())
	os.item_distance = 10.0
	os.left = false
	os.right = true
	os.from_dist = 20.0
	os.to_dist = 50.0
	os.spawn_objects()

	# 可用长度 30m → 3 个，首个在 from_dist + 半个间距 = 25m
	assert_eq(os.get_child_count(), 3, "20→50 区间 / 10m 间距 → 应为 3 个")
	var first: Node3D = os.get_child(0)
	assert_true(absf(first.position.x - 25.0) < 0.01, "首个实例 x 应为 25，实际 %s" % first.position.x)


func test_wrong_parent_is_rejected() -> void:
	expect_script_error_containing("Parent should be Path3D")
	var not_a_path := Node3D.new()
	not_a_path.name = "NotAPath"
	track(not_a_path)
	var os: Node3D = _script(OBJECT_STRING_SCRIPT).new()
	not_a_path.add_child(os)
	os.item = _make_item_scene()
	os.spawn_objects()

	assert_eq(os.get_child_count(), 0, "父节点不是 Path3D 时不应生成任何实例")


## main.tscn 的「墓园石制围墙」实例：钉死"实例必须落在路径中心线旁 distance_from_center 处、
## 底座贴地"。曾经因为 ObjectString 节点自身 transform 非零（-29.99, 0, -5.80），
## 整排物件被平移 30.55m 到路径外，且 distance_up=0 时整个网格埋在地形下。
func test_cemetery_wall_sits_on_path() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or scene_root.get_node_or_null("墓园石制围墙") == null:
		skip("当前编辑的场景不是 main.tscn（缺少 墓园石制围墙）")
		return
	var path := scene_root.get_node("墓园石制围墙") as Path3D
	var os := path.get_node_or_null("ObjectString") as Node3D
	if os == null or os.get_child_count() == 0:
		skip("墓园石制围墙 上没有已摆放的 ObjectString 实例")
		return

	assert_true(os.position.length() < 0.001, "ObjectString 自身应位于 Path3D 原点，实际 %s" % os.position)

	var length := path.curve.get_baked_length()
	assert_eq(
		os.get_child_count(),
		int(floor(length / os.item_distance)),
		"实例数应等于 floor(曲线长 / 间距)"
	)

	var first := os.get_child(0) as Node3D
	# 采样曲线（世界空间），检查"每个实例到中心线的最近水平距离"都 = distance_from_center
	var samples: Array[Vector3] = []
	for i in 501:
		samples.append(path.global_transform * path.curve.sample_baked(length * float(i) / 500.0, true))
	var min_d := INF
	var max_d := 0.0
	for child in os.get_children():
		var c := child as Node3D
		var best := INF
		for p in samples:
			best = minf(best, Vector2(p.x - c.global_transform.origin.x, p.z - c.global_transform.origin.z).length())
		min_d = minf(min_d, best)
		max_d = maxf(max_d, best)
	# 折线拐角处插件按"下一段"的右向量偏移，会有一点出入；这里只钉死"整排贴着路径"，
	# 而不是像修好之前那样整体跑到 30m 之外。
	assert_true(
		min_d > 1.5 and max_d < 3.1,
		"实例应分布在路径中心线 %.1fm 两侧（拐角略有出入）：实测 %.3f ~ %.3f m" % [os.distance_from_center, min_d, max_d]
	)

	# 底座贴地：网格包围盒顶端在实例原点（y ∈ [-h, 0]），所以 h 应被 distance_up 抵消。
	# 物件可能是包装场景（多一层实例根），必须递归找 MeshInstance3D。
	var found := first.find_children("*", "MeshInstance3D", true, false)
	assert_true(not found.is_empty(), "实例里应能找到 MeshInstance3D（递归）")
	if not found.is_empty():
		var mi := found[0] as MeshInstance3D
		var h := mi.mesh.get_aabb().size.y * mi.global_transform.basis.get_scale().y
		var base_y := first.global_transform.origin.y - h
		assert_true(
			absf(base_y - path.global_transform.origin.y) < 0.08,
			"栅栏底座应贴地（路径高度 %.3f），实际底座 y=%.3f" % [path.global_transform.origin.y, base_y]
		)

@tool
extends McpTestSuite
## GLB 切割核心自检（连通块 + 焊接 + 聚类）

const CORE := "res://addons/glb_split/split_core.gd"


func suite_name() -> String:
	return "glb_split"


func _load(p: String) -> GDScript:
	return ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _arrays(verts: PackedVector3Array, idx: PackedInt32Array) -> Array:
	var a: Array = []
	a.resize(Mesh.ARRAY_MAX)
	a[Mesh.ARRAY_VERTEX] = verts
	a[Mesh.ARRAY_INDEX] = idx
	return a


func test_weld_key_same_position_same_key() -> void:
	var c := _load(CORE)
	assert_true(c != null, "核心加载失败")
	if c == null:
		return
	var a: Vector3i = c.call("_weld_key", Vector3(0.1, 0.2, 0.3))
	var b: Vector3i = c.call("_weld_key", Vector3(0.1, 0.2, 0.3))
	var d: Vector3i = c.call("_weld_key", Vector3(1.5, 0, 0))
	print("[切割] 同位置 key=%s ｜ 异位置 key=%s" % [str(a), str(d)])
	# 注意：Vector3i 用 == 比较，别用 assert_eq（它内部会做类型/格式化处理 ✗ 容易出解析或运行问题 ✓）
	assert_true(a == b, "同位置必须得到同一个 key ✗")
	assert_true(a != d, "不同位置不该同 key ✗")


func test_two_far_triangles_are_two_islands() -> void:
	var c := _load(CORE)
	if c == null:
		return
	var v := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(10, 0, 0), Vector3(11, 0, 0), Vector3(10, 1, 0)])
	var i := PackedInt32Array([0, 1, 2, 3, 4, 5])
	var r: Dictionary = c.call("surface_islands", _arrays(v, i))
	print("[切割] 两个分离三角形 → 岛数=%d" % int(r["island_count"]))
	assert_eq(int(r["island_count"]), 2, "两个互不相连的三角形应当是 2 个岛 ✗")


func test_shared_edge_is_one_island() -> void:
	var c := _load(CORE)
	if c == null:
		return
	var v := PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0)])
	var i := PackedInt32Array([0, 1, 2, 1, 3, 2])          # 共享边 (1,2) ✓
	var r: Dictionary = c.call("surface_islands", _arrays(v, i))
	print("[切割] 共享边 → 岛数=%d" % int(r["island_count"]))
	assert_eq(int(r["island_count"]), 1, "共享一条边的两个三角形必须算同一个岛 ✗")


func test_weld_merges_duplicated_vertices() -> void:
	# ★ 这是最关键的一条 ✓：glTF 会按 UV/法线把顶点拆开 ✗
	#   所以"同一个几何点用不同索引"是常态 ✓ → 不焊接就会把一个物体切成碎片 ✗
	var c := _load(CORE)
	if c == null:
		return
	var v := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0),
		Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)])   # 后三个是同一批点的重复副本 ✓
	var i := PackedInt32Array([0, 1, 2, 3, 4, 5])
	var r: Dictionary = c.call("surface_islands", _arrays(v, i))
	print("[切割] 顶点重复（位置相同索引不同）→ 岛数=%d" % int(r["island_count"]))
	assert_eq(int(r["island_count"]), 1, "同位置重复顶点必须焊在一起，否则一个物体会被切碎 ✗")


func test_kmeans_splits_grid_into_k_groups() -> void:
	var c := _load(CORE)
	if c == null:
		return
	# 3×3 网格（模拟"三行三列"的错位布局 ✓）
	var islands: Array = []
	for row in range(3):
		for col in range(3):
			islands.append({"center": Vector3(col * 1.0, 0.0, row * 1.0), "tris_n": 100})
	var groups: Array = c.call("_kmeans_groups", islands, 9)
	var sizes := PackedInt32Array()
	for g in groups:
		sizes.append((g as Array).size())
	print("[切割] 9 点聚成 9 组 → 各组大小=%s" % str(sizes))
	assert_eq(groups.size(), 9, "应当聚成 9 组 ✗")
	var total := 0
	var max_size := 0
	for s in sizes:
		total += int(s)
		if int(s) > max_size:
			max_size = int(s)
	assert_eq(total, 9, "所有点都要被分到组里 ✗")
	# 注意：PackedInt32Array **没有** max() ✗（那是普通 Array 才有 ✓）→ 手动求 ✓
	assert_true(max_size == 1, "9 个明显分开的点聚成 9 组时，每组应当只有 1 个 ✗")


func test_kmeans_five_groups() -> void:
	var c := _load(CORE)
	if c == null:
		return
	var islands: Array = []
	for i in range(20):
		islands.append({"center": Vector3(float(i) * 5.0, 0.0, 0.0), "tris_n": 10})
	var groups: Array = c.call("_kmeans_groups", islands, 5)
	print("[切割] 20 个点聚成 5 组 → 组数=%d" % groups.size())
	assert_eq(groups.size(), 5, "应当聚成 5 组 ✗")
	for g in groups:
		assert_true((g as Array).size() > 0, "不该有空组 ✗")

func test_auto_cluster_detects_natural_groups() -> void:
	# ★ 这就是那个栅栏的真实形态 ✓：9 个物体，每个物体由**几十个互不相连的补丁壳**组成 ✓
	#   组内间距 0.002（很近 ✓），组间距 0.5（很远 ✓）
	#   → 自动判定必须得出 **9 组** ✓（不需要用户填任何数字 ✓）
	var c := _load(CORE)
	if c == null:
		return
	var islands: Array = []
	for g in range(9):
		var gx := float(g % 3) * 0.5
		var gz := float(int(g / 3)) * 0.5
		for k in range(40):
			var c0 := Vector3(gx + float(k % 8) * 0.002, 0.0, gz + float(int(k / 8.0)) * 0.002)
			islands.append({
				"center": c0,
				"min": c0 - Vector3.ONE * 0.001,
				"max": c0 + Vector3.ONE * 0.001,
				"tris_n": 100,
			})
	var groups: Array = c.call("_auto_cluster", islands)
	var sizes := PackedInt32Array()
	for g2 in groups:
		sizes.append((g2 as Array).size())
	print("[切割] 自动判定：360 个壳 → %d 组，各组壳数=%s" % [groups.size(), str(sizes)])
	assert_eq(groups.size(), 9, "360 个小壳应当自动聚成 9 组 ✗（组内很近、组间很远）")
	for s in sizes:
		assert_eq(int(s), 40, "每组应当正好 40 个壳 ✗")


func test_box_gap_helper() -> void:
	var c := _load(CORE)
	if c == null:
		return
	# 相交 → 0 ✓
	assert_true(is_equal_approx(float(c.call("_box_gap", Vector3.ZERO, Vector3.ONE, Vector3(0.5, 0.5, 0.5), Vector3(2, 2, 2))), 0.0), "相交的两个盒子空隙应为 0 ✗")
	# 沿 x 相隔 3 → 3 ✓
	var g: float = float(c.call("_box_gap", Vector3.ZERO, Vector3.ONE, Vector3(4, 0, 0), Vector3(5, 1, 1)))
	print("[切割] 相隔 3 的盒子空隙 = %.3f" % g)
	assert_true(absf(g - 3.0) < 0.001, "空隙应为 3 ✗")

func test_real_model_split() -> void:
	# ★ 拿**真实模型**跑一次 ✓（1.9M 面 / 1186 个壳 ✓）
	#   这条是判断"自动分离到底能不能用"的硬证据 ✓ —— 不再靠猜 ✓
	var c := _load(CORE)
	if c == null:
		return
	var path := "res://assets/models/buildings/围栏/石质墓园栅栏.glb"
	assert_true(ResourceLoader.exists(path), "样本模型不在：%s" % path)
	var t0 := Time.get_ticks_msec()
	var r: Dictionary = c.call("split", path, {})
	var ms := Time.get_ticks_msec() - t0
	print("[切割·真模型] ok=%s ｜ %s ｜ 耗时 %d ms ｜ 分块 %d" % [
			str(r.get("ok", false)), str(r.get("message", "")), ms, (r["parts"] as Array).size()])
	if not bool(r.get("ok", false)):
		# 失败也要留下清晰证据 ✓（而不是只有一个 false ✓）
		assert_true(false, "真实模型切割失败：%s" % str(r.get("message", "")))
		return
	var parts: Array = r["parts"]
	print("[切割·真模型] 分块数 = %d" % parts.size())
	for i in range(mini(parts.size(), 12)):
		var d: Dictionary = parts[i]
		var sz: Vector3 = d["size"]
		var ct: Vector3 = d["center"]
		print("    %s tris=%d size=(%.3f, %.3f, %.3f) center=(%.3f, %.3f, %.3f)" % [
				str(d.get("name", "?")), int(d["tris"]), sz.x, sz.y, sz.z, ct.x, ct.y, ct.z])
	assert_eq(parts.size(), 9, "这个模型应当自动切成 9 块 ✗（实测原为 1186 个补丁壳 ✓）")
	var total := 0
	for p in parts:
		total += int((p as Dictionary)["tris"])
	print("[切割·真模型] 分块三角合计 = %d（原模型 1914789 ✓ 会被 min_tris 略减 ✓）" % total)
	assert_true(total > 1000000, "分块三角数合计过少 ✗ 说明有大量三角形被漏掉 ✓")

func test_panel_and_core_can_instantiate() -> void:
	# ★ 这才是真正的检查 ✓ —— 弹窗最后做的就是这个：script.new() ✓
	#   （resource_manage(load) 只证明"能解析" ✗；运行时 load 失败是静默的 ✗✓）
	var paths := [
		"res://addons/glb_split/split_core.gd",
		"res://addons/glb_split/split_panel.gd",
		"res://addons/glb_split/split_window.gd",
		"res://addons/glb_split/filesystem_menu.gd",
		"res://addons/glb_split/box_overlay.gd",
	]
	for p in paths:
		# ★ 同一条铁律：测试也必须强制重新读盘 ✓ 否则测的是缓存里的旧脚本 ✗
		var s: GDScript = ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE)
		var nm := String(p).get_file()
		if s == null:
			print("[实例化检查] %s → load() 返回 null ✗" % nm)
			assert_true(false, "%s load() 失败 ✗" % nm)
			continue
		var ci := s.can_instantiate()
		print("[实例化检查] %s → can_instantiate=%s" % [nm, str(ci)])
		# ★ 关键：**无论能否实例化都要调 new()** ✓✓ ——
		#   上一版在 ci=false 时 continue ✗ → new() 从未执行 →
		#   引擎的**真正编译错误从未被打印** ✗✗（日志里因此什么都没有 ✓）
		var inst = s.new()
		if not ci:
			print("[实例化检查]   ↑ 上面这句 new() 会让引擎把**真正的编译错误**打进日志 ✓")
		assert_true(ci, "%s 无法实例化 ✗（编译器报错见「输出」面板 ✓）" % nm)
		if inst == null:
			continue
		assert_true(inst != null, "%s 实例化返回 null ✗" % nm)
		if inst != null:
			print("[实例化检查]   %s 实例化成功 ✓（%s）" % [nm, inst.get_class()])
			# ★ 只有 Node 才能 free() ✓ —— RefCounted（如 split_core）会自动释放 ✗
			#   （上一版直接 free() ✗ → 报 "Attempted to free a RefCounted object" ✓）
			if inst is Node:
				(inst as Node).free()

func test_record_row_selection_restores_box() -> void:
	# 直接模拟"点行 / 勾选"，看框到底回不回来（不靠猜）
	var s: GDScript = ResourceLoader.load("res://addons/glb_split/split_panel.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(s != null, "面板脚本加载失败")
	if s == null or not s.can_instantiate():
		assert_true(false, "面板脚本无法实例化")
		return
	var panel: Control = s.new()
	var host := (Engine.get_main_loop() as SceneTree).root
	host.add_child(panel)                 # 让 _ready 跑起来（建 Tree / SubViewport 等）
	panel.visible = false
	var rec := {
		"origin": Vector3(1.0, 2.0, 3.0),
		"bx": Vector3(1, 0, 0), "by": Vector3(0, 1, 0), "bz": Vector3(0, 0, 1),
		"half": Vector3(0.5, 0.5, 0.5),
	}
	panel.set("_box_records", [rec])
	panel.call("_fill_left_records")
	var tree: Tree = panel.get("_tree_left")
	assert_true(tree != null, "左列表不存在")
	if tree == null:
		panel.free()
		return
	var root_item: TreeItem = tree.get_root()
	var row: TreeItem = root_item.get_first_child() if root_item != null else null
	assert_true(row != null, "左列表没有行")
	if row == null:
		panel.free()
		return
	# ① 点行 -> 应当恢复成可编辑的框
	# 注意：row.select() 是程序化选择，**不会**触发 item_selected（那只由用户点击发出），
	#      所以这里显式调一次处理器，等价于"用户点了这一行"
	row.select(0)
	print("[行选择] is_selected(0) = %s" % str(row.is_selected(0)))
	panel.call("_on_left_selection_changed")
	panel.call("_on_left_multi_selected", 0, 0, true)
	var bd: Dictionary = panel.get("_box_data")
	var mi = panel.get("_box_mi")
	print("[行选择] select 后 origin=%s ｜ _box_mi=%s ｜ visible=%s" % [
			str(bd.has("origin")), str(mi != null), str((mi as MeshInstance3D).visible if mi != null else false)])
	assert_true(bd.has("origin"), "点行没有恢复框")
	if mi != null:
		assert_true((mi as MeshInstance3D).visible, "点行后框没有显示")
	# ② 勾选框 -> 也应当恢复成可编辑的框
	panel.set("_box_data", {})
	if mi != null:
		(mi as MeshInstance3D).visible = false
	row.set_checked(0, true)
	panel.call("_on_left_item_edited")
	var bd2: Dictionary = panel.get("_box_data")
	print("[勾选] item_edited 后 origin=%s" % str(bd2.has("origin")))
	assert_true(bd2.has("origin"), "勾选单条没有恢复框")
	# ④ 有框在编辑时：【创建新的框选】必须置灰
	var nb = panel.get("_new_btn")
	assert_true(nb != null, "找不到 _new_btn")
	assert_true(nb != null and (nb as Button).disabled, "有框编辑时【创建新的框选】没有置灰")
	# ⑤ 只**取消勾选**（不取消行选中 —— 用户就是这么操作的，上一版测试多写了 deselect ✗ 才漏掉这个 bug）
	row.set_checked(0, false)
	panel.call("_on_left_item_edited")
	var bd4: Dictionary = panel.get("_box_data")
	var mi4 = panel.get("_box_mi")
	print("[取消选中] origin=%s ｜ visible=%s ｜ new_btn.disabled=%s" % [
			str(bd4.has("origin")),
			str((mi4 as MeshInstance3D).visible if mi4 != null else false),
			str((nb as Button).disabled if nb != null else true)])
	assert_true(not bd4.has("origin"), "取消选中后 _box_data 还在")
	if mi4 != null:
		assert_true(not (mi4 as MeshInstance3D).visible, "取消选中后框还显示着")
	assert_true(nb != null and not (nb as Button).disabled, "取消选中后【创建新的框选】没有恢复可用")

	# ③ 关窗清状态
	panel.set("_box_records", [rec])
	panel.call("reset_state")
	var bd3: Dictionary = panel.get("_box_data")
	var recs3: Array = panel.get("_box_records")
	print("[清状态] origin=%s ｜ 记录数=%d" % [str(bd3.has("origin")), recs3.size()])
	assert_true(not bd3.has("origin"), "清状态后框还在")
	assert_eq(recs3.size(), 0, "清状态后记录没清空")
	panel.free()

func test_default_box_uses_cached_model_aabb() -> void:
	# 默认框必须**稳定**：不受 holder 里其它东西（散开的分块/线框）影响
	var s: GDScript = ResourceLoader.load("res://addons/glb_split/split_panel.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	if s == null or not s.can_instantiate():
		assert_true(false, "面板脚本无法实例化")
		return
	var panel: Control = s.new()
	var host := (Engine.get_main_loop() as SceneTree).root
	host.add_child(panel)
	panel.visible = false
	# 塞一个"缓存好的模型 AABB"：2 x 2 x 2，中心在原点
	panel.set("_model_aabb", AABB(Vector3(-1, -1, -1), Vector3(2, 2, 2)))
	panel.set("_has_model_aabb", true)
	panel.call("_default_box_from_model")
	var bd: Dictionary = panel.get("_box_data")
	assert_true(bd.has("origin"), "默认框没建出来")
	var h1: Vector3 = bd["half"]
	print("[缓存AABB] 建档 half = %s" % str(h1))
	assert_true(absf(h1.x - 1.0) < 0.001 and absf(h1.y - 1.0) < 0.001 and absf(h1.z - 1.0) < 0.001,
			"默认框不是模型等大")
	# 再往 holder 里扔几个很远的假分块（模拟"自动分离之后散开"）
	var holder: Node3D = panel.get("_holder")
	if holder != null:
		for i in range(3):
			var mi := MeshInstance3D.new()
			mi.mesh = BoxMesh.new()
			mi.position = Vector3(50.0 * float(i + 1), 0.0, 0.0)
			holder.add_child(mi)
	panel.call("_default_box_from_model")
	var bd2: Dictionary = panel.get("_box_data")
	var h2: Vector3 = bd2["half"]
	print("[缓存AABB] 加入远处散块后 half = %s" % str(h2))
	assert_true(absf(h2.x - h1.x) < 0.001 and absf(h2.y - h1.y) < 0.001 and absf(h2.z - h1.z) < 0.001,
			"默认框受散开分块影响（AABB 不稳定）")
	panel.free()

func test_confirm_while_editing_updates_record() -> void:
	# 二次编辑后再点【确定框选】：应当**更新原记录**，而不是新增一条
	var s: GDScript = ResourceLoader.load("res://addons/glb_split/split_panel.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	if s == null or not s.can_instantiate():
		assert_true(false, "面板脚本无法实例化")
		return
	var panel: Control = s.new()
	var host := (Engine.get_main_loop() as SceneTree).root
	host.add_child(panel)
	panel.visible = false
	var rec := {
		"origin": Vector3(0, 0, 0),
		"bx": Vector3(1, 0, 0), "by": Vector3(0, 1, 0), "bz": Vector3(0, 0, 1),
		"half": Vector3(0.5, 0.5, 0.5),
	}
	panel.set("_box_records", [rec])
	panel.call("_fill_left_records")
	panel.call("_enter_edit", 0)                 # 进入二次编辑
	var bd: Dictionary = panel.get("_box_data")
	bd["half"] = Vector3(2.0, 2.0, 2.0)          # 改大一点
	panel.set("_box_data", bd)
	panel.call("confirm_box")
	var recs: Array = panel.get("_box_records")
	print("[二次编辑确定] 记录数=%d ｜ half=%s" % [recs.size(), str((recs[0] as Dictionary)["half"])])
	assert_eq(recs.size(), 1, "二次编辑后【确定框选】新增了记录（应当更新原记录）")
	var h: Vector3 = (recs[0] as Dictionary)["half"]
	assert_true(absf(h.x - 2.0) < 0.001 and absf(h.y - 2.0) < 0.001 and absf(h.z - 2.0) < 0.001,
			"【确定框选】没有把改动写回原记录")
	# 再走一次"新建框"路径：应当**新增**一条
	panel.call("_default_box_from_model")
	panel.call("confirm_box")
	var recs2: Array = panel.get("_box_records")
	print("[新建框确定] 记录数=%d" % recs2.size())
	assert_eq(recs2.size(), 2, "新建的框没有被新增成记录")
	panel.free()

func test_real_model_split_with_box() -> void:
	# ★ 传**带朝向的字典盒子**去切割 —— 这是鼠标拖框后的真实路径
	#   （上一版 split() 里写成 var box: Array ✗ -> 一传字典就报
	#    "Trying to assign value of type 'Dictionary' to a variable of type 'Array'"）
	var c := _load(CORE)
	if c == null:
		return
	var path := "res://assets/models/buildings/围栏/石质墓园栅栏.glb"
	if not ResourceLoader.exists(path):
		assert_true(false, "样本模型不在：%s" % path)
		return
	var box := {
		"origin": Vector3(0.0, 0.25, 0.0),
		"bx": Vector3(1, 0, 0), "by": Vector3(0, 1, 0), "bz": Vector3(0, 0, 1),
		"half": Vector3(0.12, 0.28, 0.55),
	}
	var r: Dictionary = c.call("split", path, {"box": box})
	print("[带框切割] ok=%s ｜ %s ｜ 分块 %d" % [
			str(r.get("ok", false)), str(r.get("message", "")), (r["parts"] as Array).size()])
	assert_true(bool(r.get("ok", false)), "传字典盒子切割失败：%s" % str(r.get("message", "")))
	var parts: Array = r["parts"]
	assert_true(parts.size() > 0, "传字典盒子切成 0 块")
	var total := 0
	for p in parts:
		total += int((p as Dictionary)["tris"])
	print("[带框切割] 分块 %d ｜ 三角合计 %d（未过滤时约 190 万）" % [parts.size(), total])
	assert_true(total > 0 and total < 1914789, "带框切割的三角数不合理：%d" % total)

func test_cut_keeps_original_model_visible() -> void:
	# 按记录切割导出后：预览应当**仍显示原始模型**，而不是切割出的分块
	var s: GDScript = ResourceLoader.load("res://addons/glb_split/split_panel.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	if s == null or not s.can_instantiate():
		assert_true(false, "面板脚本无法实例化")
		return
	var panel: Control = s.new()
	var host := (Engine.get_main_loop() as SceneTree).root
	host.add_child(panel)
	panel.visible = false
	var holder: Node3D = panel.get("_holder")
	assert_true(holder != null, "没有 _holder")
	if holder == null:
		panel.free()
		return
	# 造一个"原始模型节点"
	var mnode := MeshInstance3D.new()
	mnode.name = "FakeModel"
	mnode.mesh = BoxMesh.new()
	holder.add_child(mnode)
	panel.set("_model_node", mnode)
	# 再塞两个"散开的分块"（模拟自动分离后的状态）
	var spread: Array = []
	for i in range(2):
		var mi := MeshInstance3D.new()
		mi.name = "part_%d" % i
		mi.mesh = BoxMesh.new()
		mi.position = Vector3(10.0 * float(i + 1), 0, 0)
		holder.add_child(mi)
		spread.append(mi)
	panel.set("_preview_nodes", spread)
	panel.set("source_path", "")                  # 不需要真的加载模型
	panel.call("_show_model_only")
	var left: int = (panel.get("_preview_nodes") as Array).size()
	print("[切完保持原模型] 残留散块=%d ｜ 模型节点 still valid=%s" % [
			left, str(is_instance_valid(mnode))])
	assert_eq(left, 0, "散开的分块没有被清掉")
	assert_true(is_instance_valid(mnode), "原始模型节点被误删了")
	panel.free()

func test_exported_glb_is_not_empty() -> void:
	# 走**面板真实的导出路径**：切割 -> _do_export_to -> 检查文件不是空的、能读回
	var s: GDScript = ResourceLoader.load("res://addons/glb_split/split_panel.gd", "", ResourceLoader.CACHE_MODE_IGNORE)
	if s == null or not s.can_instantiate():
		assert_true(false, "面板脚本无法实例化")
		return
	var path := "res://assets/models/buildings/围栏/石质墓园栅栏.glb"
	if not ResourceLoader.exists(path):
		assert_true(true, "样本模型不在，跳过")
		return
	var c := _load(CORE)
	if c == null:
		return
	var box := {
		"origin": Vector3(0.0, 0.25, 0.0),
		"bx": Vector3(1, 0, 0), "by": Vector3(0, 1, 0), "bz": Vector3(0, 0, 1),
		"half": Vector3(0.12, 0.28, 0.55),
	}
	var r: Dictionary = c.call("split", path, {"box": box})
	if not bool(r.get("ok", false)):
		assert_true(false, "切割失败：%s" % str(r.get("message", "")))
		return
	var parts: Array = r["parts"]
	assert_true(parts.size() > 0, "没有分块")
	# ★ 先看清分块的网格到底长什么样（别猜）
	var mm: ArrayMesh = (parts[0] as Dictionary)["mesh"]
	print("[导出检查] 分块0 mesh=%s ｜ 面数=%d" % [str(mm), mm.get_surface_count()])
	var mm2 = (parts[0] as Dictionary)["mesh"]
	print("[导出检查] mesh 是 ArrayMesh? %s" % str(mm2 is ArrayMesh))
	if mm2 is ArrayMesh:
		var am := mm2 as ArrayMesh
		for si in range(am.get_surface_count()):
			var arr := am.surface_get_arrays(si)
			var nv := (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if arr[Mesh.ARRAY_VERTEX] != null else -1
			var ni := (arr[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arr[Mesh.ARRAY_INDEX] != null else -1
			print("   面 %d: 顶点=%d 索引=%d 法线=%s UV=%s 材质=%s" % [si, nv, ni,
					str(arr[Mesh.ARRAY_NORMAL] != null), str(arr[Mesh.ARRAY_TEX_UV] != null),
					str(am.surface_get_material(si) != null)])
	var panel: Control = s.new()
	(Engine.get_main_loop() as SceneTree).root.add_child(panel)
	panel.visible = false
	panel.set("source_path", path)
	var out_dir := "res://.runtime_export_check"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var slot := load("res://tests/test_glb_split.gd")    # 占位，避免未使用告警
	panel.call("_do_export_to", parts, [0], "测试", out_dir)
	var out := out_dir.path_join("石质墓园栅栏_01.glb")
	var fa := FileAccess.open(out, FileAccess.READ)
	var sz := fa.get_length() if fa != null else 0
	if fa != null:
		fa.close()
	# 把诊断塞进断言消息（测试运行器不显示 print）
	var diag := "sz=%d" % sz
	if mm2 is ArrayMesh:
		var am3 := mm2 as ArrayMesh
		diag += " ｜ 面数=%d" % am3.get_surface_count()
		for si in range(am3.get_surface_count()):
			var arr3 := am3.surface_get_arrays(si)
			var nv3 := (arr3[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() if arr3[Mesh.ARRAY_VERTEX] != null else -1
			var ni3 := (arr3[Mesh.ARRAY_INDEX] as PackedInt32Array).size() if arr3[Mesh.ARRAY_INDEX] != null else -1
			diag += " ｜[%d]顶点=%d 索引=%d 法线=%s UV=%s 材质=%s" % [si, nv3, ni3,
					str(arr3[Mesh.ARRAY_NORMAL] != null), str(arr3[Mesh.ARRAY_TEX_UV] != null),
					str(am3.surface_get_material(si) != null)]
	print("[导出检查] %s" % diag)
	assert_true(sz > 1000, "DIAG 导出的 glb 是空的 -> %s" % diag)
	var doc2 := GLTFDocument.new()
	var st2 := GLTFState.new()
	var e3 := doc2.append_from_file(out, st2)
	print("[导出检查] 读回 append_from_file = %d" % e3)
	assert_eq(e3, OK, "导出的 glb 读不回来")
	var meshes := 0
	var scene := doc2.generate_scene(st2) if e3 == OK else null
	if scene != null:
		var stack: Array = [scene]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				meshes += 1
			for ch in n.get_children():
				stack.append(ch)
	print("[导出检查] 读回网格数 = %d" % meshes)
	assert_true(meshes > 0, "读回的 glb 里没有网格")
	if scene != null:
		scene.free()
	panel.free()

func test_slice_parts_filters_by_box() -> void:
	# ★ 用盒子"筛"已有分块（按框选记录导出走的就是这条路 —— 毫秒级、不重跑完整切割）
	var c := _load(CORE)
	if c == null:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.add_vertex(Vector3(-2, 0, 0))
	st.add_vertex(Vector3(-1, 0, 0))
	st.add_vertex(Vector3(-1, 1, 0))
	st.add_vertex(Vector3(1, 0, 0))
	st.add_vertex(Vector3(2, 0, 0))
	st.add_vertex(Vector3(2, 1, 0))
	var mesh := st.commit()
	var parts: Array = [{"name": "synth", "mesh": mesh, "center": Vector3.ZERO, "tris": 2}]
	var box := {
		"origin": Vector3(-1.5, 0.5, 0.0),
		"bx": Vector3(1, 0, 0), "by": Vector3(0, 1, 0), "bz": Vector3(0, 0, 1),
		"half": Vector3(0.6, 0.6, 0.6),
	}
	var out: Array = c.call("slice_parts", parts, box)
	assert_eq(out.size(), 1, "筛出来的块数不对（应为 1）")
	if out.size() == 1:
		assert_eq(int((out[0] as Dictionary)["tris"]), 1, "筛出来的三角数不对（应为 1）")
	# 框住全部 -> 两块都留下（这里是一个分块里的两个三角，所以仍是 1 块 2 三角）
	var big := {
		"origin": Vector3(0, 0, 0),
		"bx": Vector3(1, 0, 0), "by": Vector3(0, 1, 0), "bz": Vector3(0, 0, 1),
		"half": Vector3(10, 10, 10),
	}
	var out2: Array = c.call("slice_parts", parts, big)
	assert_eq(out2.size(), 1, "大框应当保留该分块")
	if out2.size() == 1:
		assert_eq(int((out2[0] as Dictionary)["tris"]), 2, "大框应当保留 2 个三角")
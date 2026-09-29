@tool
extends McpTestSuite
## 凹多边形碰撞调参插件 —— 编辑器内自检。
##
## 自带测试夹具（MeshInstance3D → StaticBody3D → CollisionShape3D），不依赖项目里
## 具体的场景文件（那些会被改名/精简，测试不该跟着碎）。

const PANEL := "res://addons/concave_collision_tuner/tuner_panel.gd"


func suite_name() -> String:
	return "concave_tuner"


# ------------------------------------------------------------------ 夹具

func _tetra_faces() -> PackedVector3Array:
	var a := Vector3(0, 0, 0)
	var b := Vector3(1, 0, 0)
	var c := Vector3(0, 1, 0)
	var d := Vector3(0, 0, 1)
	return PackedVector3Array([a, c, b, a, b, d, a, d, c, b, c, d])   # 4 个三角面


## 返回 [根节点, MeshInstance3D, CollisionShape3D]；根节点交给 track() 自动释放
func _make_fixture() -> Array:
	var root := Node3D.new()
	track(root)
	var mi := MeshInstance3D.new()
	mi.name = "TripoPart"
	mi.mesh = BoxMesh.new()                     # 12 个三角面
	root.add_child(mi)
	var body := StaticBody3D.new()
	body.name = "StaticBody3D"
	mi.add_child(body)
	var cs := CollisionShape3D.new()
	cs.name = "CollisionShape3D"
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(_tetra_faces())             # 4 个三角面
	cs.shape = shape
	body.add_child(cs)
	return [root, mi, cs]


# ------------------------------------------------------------------ 用例

func test_panel_builds_and_finds_source() -> void:
	var f := _make_fixture()
	var cs: CollisionShape3D = f[2]
	var panel: Control = track(load(PANEL).new())
	panel.call("setup", cs)

	assert_true(panel.get_child_count() > 0, "面板没有建出任何 UI 节点")
	assert_true(panel.get("_shape") != null, "面板没绑上 shape")
	assert_true(panel.get("_src") is MeshInstance3D, "源网格不是 MeshInstance3D")
	assert_eq(int(panel.get("_src_faces")), 12, "BoxMesh 的三角面数应为 12")
	var cur := (cs.shape as ConcavePolygonShape3D).get_faces().size() / 3
	assert_eq(cur, 4, "夹具碰撞体的三角面数应为 4")
	print("[调参插件] 夹具：源网格 12 面 ／ 碰撞体 %d 面" % cur)


func test_ratio_remembered_on_node() -> void:
	var f := _make_fixture()
	var cs: CollisionShape3D = f[2]
	assert_false(cs.has_meta("concave_tuner_ratio"), "新节点不该已经有记忆")

	# ① 没有记忆时，按"当前形状 / 源网格"预填（4/12 ≈ 33.33%）
	var p1: Control = track(load(PANEL).new())
	p1.call("setup", cs)
	var pre := float((p1.get("_spin") as SpinBox).value)
	print("[调参插件] 无记忆时预填 = %.2f%%（4/12）" % pre)
	assert_true(absf(pre - 100.0 * 4.0 / 12.0) < 0.5, "预填系数不对: %.2f" % pre)

	# ② 记一个系数到节点上
	p1.call("_save_ratio", 0.05)
	assert_true(cs.has_meta("concave_tuner_ratio"), "系数没记到节点 metadata 上")
	assert_eq(snappedf(float(cs.get_meta("concave_tuner_ratio")), 0.001), 0.05, "记住的值不对")
	assert_true(cs.has_meta("concave_tuner_src_faces"), "没一起记住源网格面数")

	# ③ 重新打开面板（相当于切走再选回来 / 重开场景）应恢复
	var p2: Control = track(load(PANEL).new())
	p2.call("setup", cs)
	var restored := float((p2.get("_spin") as SpinBox).value)
	print("[调参插件] 重新打开恢复 = %.2f%%" % restored)
	assert_true(absf(restored - 5.0) < 0.01, "没恢复记住的系数: %.2f" % restored)
	assert_true(bool(p2.call("_has_saved_ratio")), "_has_saved_ratio 应为 true")


func test_node_identity_api() -> void:
	# 顺带记录 4.7 里"节点唯一 id"的脚本接口（面板用节点 metadata 存系数，
	# 不需要外部表 + id 映射，所以这里只做记录，不做依赖）
	var f := _make_fixture()
	var cs: CollisionShape3D = f[2]
	var has_scene_id := cs.has_method("get_scene_unique_id")
	print("[调参插件] 节点唯一 id 接口 get_scene_unique_id = %s" % has_scene_id)
	if has_scene_id:
		print("[调参插件] 该节点 scene_unique_id = %s" % str(cs.call("get_scene_unique_id")))
	assert_eq(String(cs.name), "CollisionShape3D", "夹具节点名不对")


func test_toolbar_button_registered() -> void:
	# 3D 视图工具栏上应该有一个「碰撞调参」按钮（插件启用后由 add_control_to_container 挂上去）
	var found := _find_button(EditorInterface.get_base_control(), "碰撞调参")
	assert_true(found != null, "3D 视图工具栏里没找到「碰撞调参」按钮")
	if found == null:
		return
	print("[调参插件] 工具栏按钮 text=%s visible=%s" % [found.text, found.visible])
	assert_true(not found.tooltip_text.is_empty(), "按钮没有 tooltip")


func test_topology_ui_present() -> void:
	var f := _make_fixture()
	var panel: Control = track(load(PANEL).new())
	panel.call("setup", f[2])
	var btn := _find_button(panel, "拓扑校验（当前形状）")
	assert_true(btn != null, "面板里没有「拓扑校验」按钮")
	var chk := _find_checkbox(panel, "重建时修拓扑")
	assert_true(chk != null, "面板里没有「重建时修拓扑」复选框")
	if chk != null:
		assert_true(chk.button_pressed, "修拓扑应该默认勾上（绕序反了会变单向墙）")


func test_topology_check_runs_end_to_end() -> void:
	# 直接调 _worker（不开线程），把「校验当前形状」这条链路真跑一遍：
	# GDScript dump -> trimesh_check.py -> 报告文本回传
	var probe: Array = []
	if OS.execute("python", ["--version"], probe, true) != 0:
		skip("这台机器上没有 python，跳过端到端校验")
		return
	var f := _make_fixture()
	var panel: Control = track(load(PANEL).new())
	panel.call("setup", f[2])
	var tmp := ProjectSettings.globalize_path("user://concave_tuner_test/")
	DirAccess.make_dir_recursive_absolute(tmp)
	var faces: PackedVector3Array = (f[2] as CollisionShape3D).shape.get_faces()
	assert_true(bool(panel.call("_dump_faces", faces, tmp.path_join("src.f32"))), "dump 失败")
	panel.call("_worker", faces, tmp.path_join("src.f32"), tmp.path_join("out.f32"),
			ProjectSettings.globalize_path("res://"),
			ProjectSettings.globalize_path("res://tools/trimesh_check.py"),
			0.0, "check", false)
	assert_true(bool(panel.get("_thread_ok")), "校验没成功：" + str(panel.get("_thread_log")))
	var report := String(panel.get("_thread_report"))
	print("[调参插件] 校验报告首行：", report.split("\n")[0] if not report.is_empty() else "<空>")
	# 逐字符断言，而不是"包含"：以前乱码时"包含"也能蒙混过关
	assert_eq(report.substr(0, 3), "三角面",
			"报告开头应为「三角面」，实际「%s」——报告编码错了（Godot 按系统代码页解 OS.execute 输出）"
			% report.substr(0, 3))
	assert_contains(report, "绕序", "报告里没有绕序结论")


func _find_button(n: Node, text: String) -> Button:
	if n is Button and (n as Button).text == text:
		return n as Button
	for c in n.get_children():
		var r := _find_button(c, text)
		if r != null:
			return r
	return null


func _find_checkbox(n: Node, text_contains: String) -> CheckBox:
	if n is CheckBox and (n as CheckBox).text.contains(text_contains):
		return n as CheckBox
	for c in n.get_children():
		var r := _find_checkbox(c, text_contains)
		if r != null:
			return r
	return null


func test_raw_face_roundtrip() -> void:
	# 插件 dump 的格式必须和 tools/mesh_decimate.py 里 "<f" 解包一致：
	# 纯 float32 流，每 3 个 float 一个顶点、每 9 个一个三角面，没有任何文件头
	var faces := PackedVector3Array([
		Vector3(1.0, 2.0, 3.0), Vector3(-4.5, 0.25, 8.0), Vector3(0.0, 0.0, 0.0),
		Vector3(0.5, -0.25, 0.125), Vector3(9.0, 9.0, 9.0), Vector3(-1.0, -2.0, -3.0)])
	var panel: Control = track(load(PANEL).new())
	var path := "user://concave_tuner_roundtrip.f32"
	assert_true(bool(panel.call("_dump_faces", faces, path)), "写文件失败: %s" % path)

	var f := FileAccess.open(path, FileAccess.READ)
	assert_true(f != null, "读不到刚写的文件")
	if f == null:
		return
	var size := f.get_length()
	f.close()
	assert_eq(size, faces.size() * 12, "文件字节数应为 %d，实际 %d" % [faces.size() * 12, size])

	var back: PackedVector3Array = panel.call("_load_faces", path)
	assert_eq(back.size(), faces.size(), "读回顶点数不对")
	if back.size() != faces.size():
		return
	var ok := true
	for i in faces.size():
		if not back[i].is_equal_approx(faces[i]):
			ok = false
	assert_true(ok, "往返后顶点值不一致")
	print("[调参插件] 裸 float32 往返 OK：%d 顶点 / %d 字节" % [faces.size(), size])

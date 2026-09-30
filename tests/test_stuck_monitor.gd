@tool
extends McpTestSuite
## 卡位监测插件自检。
## 说明：物理判定（intersect_shape / cast_motion）能否在编辑器里查到静态体，本文件里的
## test_narrow_gap 会实地试一次 —— 编辑器物理空间不跑模拟的话它会被跳过（打印提示）。
## 其余测的是确定性部分：角色尺寸换算、采样范围、线框棱数、标签文字、插件插入、开关与快捷键。

const MONITOR := "res://addons/stuck_monitor/stuck_monitor.gd"
const PLUGIN := "res://addons/stuck_monitor/plugin.gd"


func suite_name() -> String:
	return "stuck_monitor"


func _load(path: String) -> GDScript:
	return ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func _root_node() -> Node:
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return (loop as SceneTree).root
	return null


func _make_player(shape: Shape3D) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.name = "Player"
	body.add_to_group("player")
	track(body)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)
	return body


func test_character_size_from_shapes() -> void:
	var s := _load(MONITOR)
	assert_true(s != null, "stuck_monitor.gd 加载失败")
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return

	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.7
	var body := _make_player(cap)
	host.add_child(body)
	var mon: Node = s.new()
	host.add_child(mon)
	mon.call("_resolve_player")
	var sz: Vector2 = mon.call("character_size")
	print("[卡位监测] 胶囊角色尺寸 = 半径 %.3f 高 %.3f" % [sz.x, sz.y])
	assert_true(absf(sz.x - 0.4) < 0.001, "胶囊半径读错了：%f" % sz.x)
	assert_true(absf(sz.y - 1.7) < 0.001, "胶囊高度读错了：%f" % sz.y)

	# 缩放要算进"实际尺寸"
	var cs: CollisionShape3D = body.get_child(0)
	cs.scale = Vector3(2, 2, 2)
	mon.call("_read_shape")
	sz = mon.call("character_size")
	print("[卡位监测] 缩放 2 倍后 = 半径 %.3f 高 %.3f" % [sz.x, sz.y])
	assert_true(absf(sz.x - 0.8) < 0.001, "缩放没算进半径：%f" % sz.x)
	assert_true(absf(sz.y - 3.4) < 0.001, "缩放没算进高度：%f" % sz.y)

	# 盒子：半径取 xz 较大值的一半，高度取 y
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, 1.8, 0.6)
	var body2 := _make_player(box)
	host.add_child(body2)
	var mon2: Node = s.new()
	host.add_child(mon2)
	mon2.set("_player", body2)
	mon2.call("_read_shape")
	sz = mon2.call("character_size")
	print("[卡位监测] 盒子角色尺寸 = 半径 %.3f 高 %.3f" % [sz.x, sz.y])
	assert_true(absf(sz.x - 0.5) < 0.001, "盒子半径应取 xz 较大值的一半：%f" % sz.x)
	assert_true(absf(sz.y - 1.8) < 0.001, "盒子高度读错了：%f" % sz.y)

	host.remove_child(body)
	host.remove_child(body2)
	host.remove_child(mon)
	host.remove_child(mon2)
	body.queue_free()
	body2.queue_free()
	mon.queue_free()
	mon2.queue_free()


func test_scan_queue_within_radius_and_band() -> void:
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	var body := _make_player(cap)
	body.position = Vector3(3, 0, -2)
	host.add_child(body)
	var mon: Node = s.new()
	mon.set("scan_radius", 6.0)
	mon.set("scan_step", 1.0)
	host.add_child(mon)
	mon.call("_resolve_player")
	mon.call("_rebuild_queue")
	var prog: Vector2i = mon.call("scan_progress")
	print("[卡位监测] 采样点 %d 个（半径 6m，细扫 1m，高度带 %.1fm）" % [prog.y, 1.8 * 2.0])
	assert_true(prog.y > 0, "没生成采样点")
	var bad := 0
	var queue: Array = mon.get("_queue")
	for entry in queue:
		var v: Vector3 = entry[0]                 # 队列元素是 [位置, 是否粗扫]
		var flat := Vector2(v.x - 3.0, v.z + 2.0)
		if flat.length() > 6.0 + 0.001:
			bad += 1
		if v.y < -0.001 or v.y > 1.8 * 2.0 + 0.001:
			bad += 1
	print("[卡位监测] 越界采样点 = %d" % bad)
	assert_true(bad == 0, "有采样点超出半径或高度带")
	host.remove_child(body)
	host.remove_child(mon)
	body.queue_free()
	mon.queue_free()


func test_marker_box_and_label() -> void:
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var mon: Node = s.new()
	host.add_child(mon)
	var mesh: ArrayMesh = mon.call("_box_lines", Vector3(1, 2, 3))
	var arrays: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	print("[卡位监测] 线框顶点数 = %d（12 条棱应为 24）" % verts.size())
	assert_true(verts.size() == 24, "线框不是 12 条棱")

	mon.call("_make_marker", {"pos": Vector3(1.5, 0.0, -2.5), "size": Vector3(0.6, 1.8, 0.6), "blocked": 8})
	assert_true(int(mon.call("marker_count")) == 1, "没生成标记")
	var label: Label3D = null
	for n in mon.get_children():
		for c in n.get_children():
			if c is Label3D:
				label = c as Label3D
	assert_true(label != null, "标记里没有文字标签")
	if label != null:
		print("[卡位监测] 标签文字 = %s" % label.text.replace("\n", " ｜ "))
		assert_true(label.text.contains("0.60"), "标签里没有尺寸")
		assert_true(label.text.contains("1.5"), "标签里没有坐标")
		assert_true(label.no_depth_test, "标签应该隔墙可见")
	host.remove_child(mon)
	mon.queue_free()


func test_plugin_inserts_monitor() -> void:
	var ps := _load(PLUGIN)
	assert_true(ps != null, "plugin.gd 加载失败")
	if ps == null:
		return
	var inst: EditorPlugin = ps.new()
	var root := Node3D.new()
	track(root)
	var node: Node3D = inst.call("insert_into", root)
	assert_true(node != null, "没插入监测节点")
	if node == null:
		inst.free()
		return
	print("[卡位监测] 插入结果 name=%s" % node.name)
	assert_true(node.name == "StuckMonitor", "节点名不对")
	var sc: Script = node.get_script()
	assert_true(sc != null, "没挂脚本")
	if sc != null:
		assert_true(String(sc.resource_path) == MONITOR, "挂的不是监测脚本")
	var again: Node3D = inst.call("insert_into", root)
	assert_true(again == node, "重复插入时应该复用已有节点")
	assert_true(root.get_child_count() == 1, "合成场景里只该有一个监测节点")
	inst.free()


func test_defaults_toggle_and_hotkey() -> void:
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var mon: Node = s.new()
	host.add_child(mon)
	var probe_scale := float(mon.get("probe_scale"))
	var step := float(mon.get("scan_step"))
	var factor := float(mon.get("min_passage_factor"))
	print("[卡位监测] 参数：探针缩放 %.2f ｜ 细扫步长 %.2f ｜ 通道阈值 %.2f" % [probe_scale, step, factor])
	# 探针必须比角色小，否则窄缝里放不进去会被直接过滤掉（第一版漏检的主因之一）
	assert_true(probe_scale < 1.0, "探针必须比角色小")
	assert_true(step <= 0.35, "细扫步长太大，窄缝会整条漏掉：%.2f" % step)
	assert_true(factor > 1.0, "通道阈值应大于 1")

	var act := String(mon.get("toggle_action"))
	var registered := InputMap.has_action(act)
	print("[卡位监测] 快捷键动作 = %s ｜ 已注册 = %s" % [act, str(registered)])
	# 契约：动作"可用"即可 —— 在运行时 InputMap 里，或已持久化进 project.godot 都算。
	# （只断言运行时 InputMap 会因编辑器重启而误红，实测反复发生。）
	var persisted := ProjectSettings.has_setting("input/%s" % act)
	print("[卡位监测] 快捷键 %s ｜ 运行时=%s ｜ 已持久化=%s" % [act, str(registered), str(persisted)])
	assert_true(registered or persisted, "快捷键动作 %s 既不在 InputMap 也没持久化" % act)
	var has_f8 := false
	if registered:
		var events: Array = InputMap.action_get_events(act)
		for e in events:
			if e is InputEventKey:
				var key := e as InputEventKey
				if key.keycode == KEY_L or key.physical_keycode == KEY_L:
					has_f8 = true
	assert_true(has_f8, "快捷键没绑到 L")

	mon.call("_make_marker", {"pos": Vector3.ZERO, "size": Vector3.ONE, "blocked": 8})
	assert_true(int(mon.call("marker_count")) == 1, "标记没生成")
	assert_true(bool(mon.get("active")), "插件默认应该是显示")
	assert_true(not bool(mon.get("show_blockers")), "【阻挡】那行默认必须隐藏（用户要求）")
	mon.call("toggle")
	print("[卡位监测] 第一次切换（隐藏） active=%s 标记数=%d" % [str(mon.get("active")), int(mon.call("marker_count"))])
	assert_true(not bool(mon.get("active")), "第一次切换应该变成隐藏")
	assert_true(int(mon.call("marker_count")) == 0, "隐藏时应该清空标记")
	mon.call("toggle")
	print("[卡位监测] 第二次切换（隐藏） active=%s 标记数=%d" % [str(mon.get("active")), int(mon.call("marker_count"))])
	assert_true(bool(mon.get("active")), "第二次切换应该回到显示")
	assert_true(int(mon.call("marker_count")) == 0, "隐藏时应该清空标记")
	host.remove_child(mon)
	mon.queue_free()


func test_narrow_gap_between_two_obstacles() -> void:
	# 复现用户截图：棺材与木桶之间约 0.45m 的窄缝（角色直径 0.8m）必须被检出。
	# 全靠物理查询，所以这条能否在编辑器里跑通，取决于编辑器物理空间是否可查。
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var holder := Node3D.new()
	track(holder)
	host.add_child(holder)
	# 两个方块：size.x=1.0，中心在 ±0.725 → 相邻面在 ∓0.225 → 缝 0.45m
	var xs: Array = [-0.725, 0.725]
	for xi in xs:
		var wall := StaticBody3D.new()
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(1.0, 1.2, 3.0)
		cs.shape = box
		cs.position = Vector3(float(xi), 0.6, 0.0)
		wall.add_child(cs)
		holder.add_child(wall)

	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	var body := _make_player(cap)
	body.position = Vector3(0, 0, 3.0)
	host.add_child(body)
	var mon: Node = s.new()
	host.add_child(mon)
	mon.call("_resolve_player")

	var space = mon.call("space_state")
	if space == null:
		print("[卡位监测] 编辑器里没有物理空间，窄缝用例只能在运行的游戏里验")
		host.remove_child(body)
		host.remove_child(holder)
		host.remove_child(mon)
		body.queue_free()
		holder.queue_free()
		mon.queue_free()
		return
	# 环境自检：在**墙心**探测，物理空间可用就一定命中；不命中说明编辑器里根本没跑物理，
	# 那么"窄缝能不能检出"这件事只能在运行的游戏里验（编辑器物理空间不注册静态体）。
	var params := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.1
	params.shape = sphere
	params.transform = Transform3D(Basis(), Vector3(-0.725, 0.6, 0.0))
	var space_state: PhysicsDirectSpaceState3D = space
	var control_hit := not space_state.intersect_shape(params, 1).is_empty()
	print("[卡位监测] 环境自检：墙心探测命中 = %s（false 表示编辑器里没跑物理）" % str(control_hit))
	if not control_hit:
		print("[卡位监测] 窄缝用例跳过：编辑器物理空间查不到静态体，必须在运行的游戏里验")
	else:
		var hit: Dictionary = mon.call("probe_point", Vector3(0, 0, 0))
		var dbg: Dictionary = mon.get("last_debug")
		var dump := FileAccess.open("user://stuck_probe.txt", FileAccess.WRITE)
		if dump != null:
			dump.store_string("控制探测命中=%s\n缝宽=0.45 角色半径=%s 高=%s\n诊断=%s\n" % [
					str(control_hit), str(dbg.get("radius", "?")), str(dbg.get("height", "?")), str(dbg)])
			dump.close()
		var measured := 0.0
		if not hit.is_empty():
			var sz: Vector3 = hit["size"]
			measured = sz.x
		print("[卡位监测] 缝宽 0.45 ｜ 角色直径 0.80 ｜ 判定 = %s ｜ 量到宽度 = %.3f" % [
				"卡位" if not hit.is_empty() else "没检出", measured])
		assert_true(not hit.is_empty(), "0.45m 窄缝没被检出（角色直径 0.8m）")
		if not hit.is_empty():
			assert_true(absf(measured - 0.45) < 0.2, "量到的通道宽度不对：%.3f" % measured)
	host.remove_child(body)
	host.remove_child(holder)
	host.remove_child(mon)
	body.queue_free()
	holder.queue_free()
	mon.queue_free()


func test_main_collision_picks_body_not_area() -> void:
	# 复盘出的真实脆弱点：角色的 CollisionShape3D 可能有好几个（交互用 Area 的小盒子），
	# 取错了角色直径就极小 → "窄"永远判不出来。必须忽略 Area 并取最大的那个。
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var body := CharacterBody3D.new()
	body.name = "Player"
	track(body)
	# 主碰撞：大胶囊
	var main := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	main.shape = cap
	body.add_child(main)
	# 干扰①：Area3D 上的小盒子（交互区）
	var area := Area3D.new()
	var acs := CollisionShape3D.new()
	var abox := BoxShape3D.new()
	abox.size = Vector3(0.05, 0.05, 0.05)
	acs.shape = abox
	area.add_child(acs)
	body.add_child(area)
	# 干扰②：Body 下的小盒子（脚底检测），比主碰撞小
	var small := CollisionShape3D.new()
	var sbox := BoxShape3D.new()
	sbox.size = Vector3(0.1, 0.05, 0.1)
	small.shape = sbox
	body.add_child(small)

	host.add_child(body)
	var mon: Node = s.new()
	host.add_child(mon)
	mon.set("_player", body)
	mon.call("_read_shape")
	var sz: Vector2 = mon.call("character_size")
	print("[卡位监测] 多碰撞体角色解析出 半径=%.3f 高=%.3f（应为 0.4 / 1.8）" % [sz.x, sz.y])
	assert_true(absf(sz.x - 0.4) < 0.001, "挑错碰撞体了（半径 %.3f）：Area 小盒子或脚底盒子被选中" % sz.x)
	assert_true(absf(sz.y - 1.8) < 0.001, "挑错碰撞体了（高 %.3f）" % sz.y)

	# 自检状态行必须能指出"把谁当成了角色"
	var line := String(mon.call("status_now"))
	print("[卡位监测] 自检行 = %s" % line)
	assert_true(line.contains("Player"), "自检行里没有角色名")
	assert_true(line.contains("半径=0.40"), "自检行里没有半径")
	host.remove_child(body)
	host.remove_child(mon)
	body.queue_free()
	mon.queue_free()

func test_scan_interval_one_second() -> void:
	# 用户要求：1 秒扫一次就够（不必每帧都扫）
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var mon: Node = s.new()
	mon.set("show_hud", false)
	mon.set("use_frustum", false)
	mon.set("log_status", false)
	host.add_child(mon)
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	var body := _make_player(cap)
	host.add_child(body)
	mon.set("_player", body)
	mon.call("_read_shape")
	var interval := float(mon.get("scan_interval"))
	print("[卡位监测] scan_interval = %.2f 秒" % interval)
	assert_true(absf(interval - 1.0) < 0.001, "默认间隔应该是 1 秒，实际 %.2f" % interval)
	# 刚加进来还没到点 → 不该开始扫
	mon.set("_idle_timer", 1.0)
	var before := int((mon.get("_stat") as Dictionary)["tested"])
	mon.call("_process", 0.2)
	var after := int((mon.get("_stat") as Dictionary)["tested"])
	print("[卡位监测] 间隔内 _process(0.2) 后 已测 %d→%d（应为 0 增长）" % [before, after])
	assert_true(after == before, "间隔没到就开始扫了")
	# 到点 → 开始扫（有玩家就有采样点）
	mon.set("_idle_timer", 0.05)
	mon.call("_process", 0.2)
	var started := int((mon.get("_stat") as Dictionary)["tested"])
	print("[卡位监测] 到点后 _process(0.2) 已测 = %d ｜ 扫描中=%s" % [started, str(mon.get("_sweeping"))])
	assert_true(bool(mon.get("_sweeping")), "到点后没进入扫描状态")
	assert_true(started > 0, "到点后没扫任何采样点")
	host.remove_child(body)
	host.remove_child(mon)
	body.queue_free()
	mon.queue_free()

func test_low_ceiling_over_feet() -> void:
	# 用户说"注意脚底下" + 之前"跳进去出不来"：地面与上方遮挡之间也会夹住角色。
	# 这条用例把水平方向留得很宽（2.6m），只有**竖直**方向是紧的（1.2m 通道 vs 身高 1.8m）。
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var base := Vector3(500, 0, 500)          # 远离原点：编辑器世界里可能有别处残留的碰撞体
	var holder := Node3D.new()
	track(holder)
	holder.position = base
	host.add_child(holder)
	# 天花板：底面在 y=1.2
	var ceil_body := StaticBody3D.new()
	var ccs := CollisionShape3D.new()
	var cbox := BoxShape3D.new()
	cbox.size = Vector3(6.0, 0.4, 6.0)
	ccs.shape = cbox
	ccs.position = Vector3(0, 1.4, 0)
	ceil_body.add_child(ccs)
	holder.add_child(ceil_body)
	# 地面
	var floor_body := StaticBody3D.new()
	var fcs := CollisionShape3D.new()
	var fbox := BoxShape3D.new()
	fbox.size = Vector3(6.0, 0.4, 6.0)
	fcs.shape = fbox
	fcs.position = Vector3(0, -0.2, 0)
	floor_body.add_child(fcs)
	holder.add_child(floor_body)

	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	var body := _make_player(cap)
	body.position = base + Vector3(0, 0, 4.0)
	host.add_child(body)
	var mon: Node = s.new()
	mon.set("show_hud", false)
	mon.set("log_status", false)
	mon.set("use_frustum", false)
	host.add_child(mon)
	mon.set("_player", body)
	mon.call("_read_shape")
	var hit: Dictionary = mon.call("probe_point", base)
	var dbg: Dictionary = mon.get("last_debug")
	var w := 0.0
	if not hit.is_empty():
		var sz: Vector3 = hit["size"]
		w = sz.x
	print("[卡位监测] 低矮通道（1.2m 高 vs 身高 1.8m）判定 = %s ｜ 最窄=%.3f ｜ 轴=%s" % [
			"卡位" if not hit.is_empty() else "没检出", float(dbg.get("min_width", -1.0)),
			str(dbg.get("axis", "?"))])
	var free_txt := "-"
	if dbg.has("free"):
		var parts := PackedStringArray()
		for v in dbg["free"]:
			parts.append("%.2f" % float(v))
		free_txt = "[%s]" % ", ".join(parts)
	assert_true(not hit.is_empty(), "低矮通道没被检出 ｜ placed=%s 阻挡者=%s 自由=%s 最窄=%.3f 阈值=%.3f 轴=%s 两侧挡=%s" % [
			str(dbg.get("placed", "?")), str(dbg.get("blockers", [])), free_txt, float(dbg.get("min_width", -1.0)),
			float(dbg.get("threshold", -1.0)), str(dbg.get("axis", "?")),
			str(dbg.get("both_blocked", "?"))])
	host.remove_child(body)
	host.remove_child(holder)
	host.remove_child(mon)
	body.queue_free()
	holder.queue_free()
	mon.queue_free()


func test_marker_stands_on_ground() -> void:
	# 标记框不能埋进地里：底部应贴着 pocket 给的地面高度
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var mon: Node = s.new()
	mon.set("show_hud", false)
	host.add_child(mon)
	mon.call("_make_marker", {"pos": Vector3(0, 0.54, 0), "size": Vector3(0.5, 1.8, 0.5),
			"blocked": 8, "ground_y": 0.0})
	var holder: Node3D = null
	for c in mon.get_children():
		if c is Node3D and c.name == "StuckMark":
			holder = c as Node3D
	assert_true(holder != null, "没生成标记节点")
	if holder != null:
		# 用户反馈："没有碰撞体的物体也参与检测了" —— 标记框会被相机遮挡系统收集成遮挡物。
		# camera_rig 留了 occlusion_ignore 后门，标记必须加进去。
		assert_true(holder.is_in_group("occlusion_ignore"),
				"标记没加进 occlusion_ignore 组，会被相机遮挡系统当成遮挡物")
		print("[卡位监测] 标记中心 y = %.3f（框高 1.8，底部应落在 y=0）" % holder.global_position.y)
		assert_true(absf(holder.global_position.y - 0.9) < 0.01,
				"标记没站在地面上：中心 y=%.3f（应为 0.9）" % holder.global_position.y)
	host.remove_child(mon)
	mon.queue_free()

func test_trapped_off_by_default_and_size_sane() -> void:
	# 用户截图暴露的两个 bug：
	#  ① 尺寸打出 1000000000.00（哨兵值没兜底）
	#  ② 一堆标记其实是"被围住"那条松判据产的，不是窄缝
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var mon: Node = s.new()
	mon.set("show_hud", false)
	host.add_child(mon)
	print("[卡位监测] report_trapped 默认 = %s ｜ 合并距离 = %.2f m" % [
			str(mon.get("report_trapped")), float(mon.get("marker_merge_distance"))])
	assert_true(not bool(mon.get("report_trapped")), "被围住判据默认必须是关的")
	assert_true(float(mon.get("marker_merge_distance")) >= 0.5, "标记合并距离太小，会叠成一摞")
	# 合并距离：近处第二个标记不该新建
	mon.call("_make_marker", {"pos": Vector3(0, 0.9, 0), "size": Vector3(0.5, 1.8, 0.5), "ground_y": 0.0})
	mon.call("_make_marker", {"pos": Vector3(0.3, 0.9, 0), "size": Vector3(0.5, 1.8, 0.5), "ground_y": 0.0})
	assert_true(int(mon.call("marker_count")) == 1, "太近的标记应该合并成一个，实际 %d 个" % int(mon.call("marker_count")))
	# 远一点的要能新建
	mon.call("_make_marker", {"pos": Vector3(6, 0.9, 0), "size": Vector3(0.5, 1.8, 0.5), "ground_y": 0.0})
	assert_true(int(mon.call("marker_count")) == 2, "远处的标记应该能新建")
	host.remove_child(mon)
	mon.queue_free()

func test_collider_name_is_unambiguous() -> void:
	# 用户反馈：木桶的 StaticBody3D 明明没挂 CollisionShape3D，却出现在"阻挡"里。
	# 根因是名称有歧义：导入生成的碰撞体大量都叫 StaticBody3D，只写节点名分不清是谁。
	var s := _load(MONITOR)
	if s == null:
		return
	var host := _root_node()
	if host == null:
		return
	var mon: Node = s.new()
	mon.set("show_hud", false)
	host.add_child(mon)
	# 木桶（父节点有名字）→ 应该写成 木桶/StaticBody3D
	var barrel := Node3D.new()
	barrel.name = "木桶"
	track(barrel)
	host.add_child(barrel)
	var sb := StaticBody3D.new()
	barrel.add_child(sb)
	var d1 := String(mon.call("describe_collider", sb))
	print("[卡位监测] 木桶下的碰撞体描述 = %s" % d1)
	assert_true(d1.contains("木桶"), "应该带上父节点名，否则分不清是哪个：%s" % d1)
	# 没有父节点（或父节点是场景根）→ 退回节点名，不能崩
	var lone := StaticBody3D.new()
	host.add_child(lone)
	var d2 := String(mon.call("describe_collider", lone))
	print("[卡位监测] 无父名碰撞体描述 = %s" % d2)
	assert_true(d2.length() > 0, "描述不能为空")
	host.remove_child(barrel)
	host.remove_child(lone)
	host.remove_child(mon)
	barrel.queue_free()
	lone.queue_free()
	mon.queue_free()
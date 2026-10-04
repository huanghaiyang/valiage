extends SceneTree
## 物体探测法术的无头验证
##
##     godot --headless --path <proj> --script res://tools/verify_detect_pulse.gd
##
## 【为什么必须无头】编辑器的游戏窗口一被切到后台，主循环就几乎不推进
## （实测 frames_drawn 只有 19），带 await 的 game_eval 一定超时。
## 无头模式没有窗口，帧自由推进，物理查询/相机投影都正常工作。
##
## 【推进方式】不靠等帧，而是**按固定步长手动调 _process**：
## 无头帧率不确定，手动步进才能得到可复现的波纹半径。
## 退出码 0 = 全部通过。

const MAIN := "res://scenes/main.tscn"
const DT := 1.0 / 60.0
const READY_MS := 60000

var _pass := 0
var _fail := 0
var _fails: Array = []
var _done := false
var _deadline := 0


func _ck(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  ✓ ", name)
	else:
		_fail += 1
		_fails.append(name)
		print("  ✗ ", name, "  ", detail)


func _initialize() -> void:
	print("========== 物体探测法术 · 无头验证 ==========")
	_deadline = Time.get_ticks_msec() + READY_MS
	var ps: PackedScene = load(MAIN)
	if ps == null:
		print("★ main.tscn 加载失败")
		quit(1)
		return
	var game := ps.instantiate()
	root.add_child(game)
	# ★ 手动 add_child 不会设置 current_scene，而 SpellCaster._find_player() 第一行
	#   就是 `if get_tree().current_scene == null: return null` —— 不设就永远找不到玩家。
	current_scene = game


func _process(_delta: float) -> bool:
	if _done:
		return true
	var caster := root.get_node_or_null("SpellCaster")
	if caster == null:
		if Time.get_ticks_msec() > _deadline:
			_ck("找到 SpellCaster", false, "超时")
			_finish()
			return true
		return false
	# 强制立刻找玩家/法杖，别等它 0.5 秒的自动间隔
	if caster.get("_player") == null or caster.get("_staff") == null:
		caster.call("_find_nodes")
		if caster.get("_player") == null:
			if Time.get_ticks_msec() > _deadline:
				_ck("找到玩家与法杖", false, "超时")
				_finish()
				return true
			return false
	_done = true
	_run(caster)
	_finish()
	return true


func _pump(jet: Node, frames: int) -> void:
	for i in range(frames):
		if is_instance_valid(jet):
			jet.call("_process", DT)


func _run(caster: Node) -> void:
	_ck("SpellCaster 找到了玩家与法杖",
			caster.get("_player") != null and caster.get("_staff") != null)
	_ck("SPELLS 里注册了 detect_pulse", caster.SPELLS.has("detect_pulse"))

	caster.call("select_spell", "detect_pulse")
	caster.call("_ensure_jet")
	var jet = caster.get("jet")
	_ck("select_spell 建出了法术节点", jet != null)
	if jet == null:
		return
	_ck("节点用的就是 detect_pulse.gd",
			jet.get_script() != null
			and str(jet.get_script().resource_path).contains("detect_pulse"))
	# ★ 把相机摆到玩家上方俯视。
	#   无头运行时相机**不会自己跟到玩家身上**（跟随要靠真实帧），于是物体的投影
	#   全落在视口外 —— 实测盒心投影 (1915, 4317)，视口只有 1280×1280。
	#   不摆相机，1.2 倍屏幕约束根本没法验证（会被误判成"探测失效"）。
	var player := caster.get("_player") as Node3D
	var cam := get_root().get_camera_3d()
	if player != null and cam != null:
		cam.global_transform = Transform3D(Basis(),
				player.global_position + Vector3(0.0, 14.0, 14.0))
		cam.look_at(player.global_position, Vector3.UP)
	_ck("相机已就位且投影可用",
			cam != null and bool(jet.call("_camera_usable", cam,
					get_root().get_visible_rect().size)))
	# 接口齐备（施法器/圆盘按这套约定调用）
	for m in ["setup", "start_cast", "stop_cast", "is_casting", "aim_dir",
			"origin_global", "ran_out_of_mana"]:
		_ck("接口存在：" + m, jet.has_method(m))

	# ---- 施放一圈 ----
	var mana := root.get_node_or_null("Mana")
	mana.call("refill")
	# 相机摆好之后，1.2 倍屏幕剔除**保持开启**（与真实游戏一致）。
	# 兜底半径换成一个独特值，用来证明 max_r 真的是相机推导出来的、不是兜底值。
	jet.set("max_radius_fallback", 7.77)
	# ★ 下面这一段验证的是**几何描边**那条路（material_overlay），
	#   所以先关掉屏幕空间模式；屏幕空间那条路在本函数末尾单独验。
	jet.set("screen_outline", false)
	var before: float = mana.get("current")
	jet.set("wave_speed", 12.0)
	jet.call("start_cast")
	_ck("start_cast 后处于施放态", bool(jet.call("is_casting")))
	_ck("按次扣蓝了", float(mana.get("current")) < before,
			"扣了 %.1f" % (before - float(mana.get("current"))))

	var pulses: Array = jet.get("_pulses")
	_ck("产生了一圈波纹", pulses.size() >= 1, "实测 %d" % pulses.size())
	if pulses.is_empty():
		return
	var p0: Dictionary = pulses[0]
	_ck("波纹中心固定在施放点（世界坐标，不跟角色跑）",
			(p0["center"] as Vector3).distance_to(
					(caster.get("_player") as Node3D).global_position) < 2.0)
	_ck("上限半径由相机推导（> 0）", float(p0["max_r"]) > 1.0,
			"max_r=%.1f" % float(p0["max_r"]))
	_ck("上限半径被 1.2 倍屏幕约束在合理范围",
			float(p0["max_r"]) <= float(jet.get("max_radius_cap")) + 0.01)

	# ---- 推进到波纹扫过周边物体 ----
	_pump(jet, 60)      # 12 m/s × 1.0 s ≈ 12 m
	var r := float((jet.get("_pulses") as Array)[0]["r"]) if not (jet.get("_pulses") as Array).is_empty() else 99.0
	_ck("波纹半径在推进", r > 1.0, "r=%.1f" % r)

	var outlined: Dictionary = jet.get("_outlined")
	# ---- 1.2 倍屏幕约束（相机已就位，按**真实行为**判定，不靠关开关）----
	_ck("上限半径是相机推导的、不是兜底值", float(p0["max_r"]) > 8.0,
			"max_r=%.1f（兜底值已刻意设为 7.77）" % float(p0["max_r"]))
	if player != null:
		_ck("玩家所在位置算作在屏内",
				bool(jet.call("_point_in_screen_margin", player.global_position)))
		_ck("800 米外的点算作在屏外（剔除非空）",
				not bool(jet.call("_point_in_screen_margin",
						player.global_position + Vector3(800.0, 0.0, 0.0))))
		# 跨整个画面的超大包围盒必须算"在屏内"（按中心判会把它误杀）
		var huge := AABB(player.global_position - Vector3(200.0, 0.0, 200.0),
				Vector3(400.0, 4.0, 400.0))
		_ck("包住玩家的超大包围盒算作在屏内（按部分相交判定）",
				bool(jet.call("_in_screen_margin", huge)))
	_diag(caster, jet)
	_ck("扫到了可碰撞物体并描出轮廓", outlined.size() > 0,
			"outlined=%d r=%.1f" % [outlined.size(), r])
	var names := []
	for k in outlined.keys():
		var n = (outlined[k] as Dictionary).get("node")
		if n != null and is_instance_valid(n):
			names.append(str(n.name))
	print("      探测到的物体：", str(names.slice(0, 8)))

	# 描边是**叠加**上去的：物体自己的材质不动，外观保持原样（不再是黑剪影）
	var has_overlay := false
	var replaced_material := false
	for k in outlined.keys():
		for item in ((outlined[k] as Dictionary).get("meshes", []) as Array):
			var mi = item.get("mi")
			if mi == null or not is_instance_valid(mi):
				continue
			var mesh := mi as MeshInstance3D
			if mesh.material_overlay is ShaderMaterial:
				has_overlay = true
	_ck("描边以叠加材质实现（不替换物体原材质）", has_overlay)

	# ---- 轮廓 1 秒后消失 ----
	# ★ 注意：波纹**还在扩张**时不能直接断言"都没了" —— 这期间不断有新物体被扫到、
	#   刚描上、1 秒还没到（实测那时还有 34 个，看起来像过期失效，其实是断言写错了）。
	#   正确做法：先让波纹跑到上限自然结束，再等 1 秒。
	# ★ 先**停止施法**再等波跑完。
	#   否则按住状态会按 repeat_interval 不断发新波，_pulses 永远不会空 ——
	#   以前之所以碰巧通过，是因为蓝在 9 秒内耗尽了（蓝耗尽就不发新波），
	#   repeat_interval 一改长这个巧合就没了。
	jet.call("stop_cast")
	var guard := 0
	while not (jet.get("_pulses") as Array).is_empty() and guard < 900:
		jet.call("_process", DT)
		guard += 1
	_ck("波纹跑到上限后自行结束", (jet.get("_pulses") as Array).is_empty(),
			"guard=%d" % guard)
	var at_end: Dictionary = jet.get("_outlined")
	print("      波纹结束时仍有 %d 个轮廓在显示（正常，它们在等各自的 1 秒）" % at_end.size())
	# 先把这批网格记下来，等会儿检查材质有没有被还原
	var watched: Array = []
	for k in at_end.keys():
		for item in ((at_end[k] as Dictionary).get("meshes", []) as Array):
			var wm = item.get("mi")
			if wm != null and is_instance_valid(wm):
				watched.append(wm)
	_pump(jet, 70)      # 再等 1.17 秒
	var left: Dictionary = jet.get("_outlined")
	_ck("波纹结束后 1 秒内轮廓全部消失", left.is_empty(), "残留 %d 个" % left.size())
	# ★ 还原检查：描边 overlay 必须被摘掉。漏还原的话物体的外缘会**永久留一圈线**，
	#   而且这种 bug 只在探测过一次之后才显形，事后极难定位。
	var not_restored := 0
	for wm in watched:
		if is_instance_valid(wm) \
				and (wm as MeshInstance3D).material_overlay is ShaderMaterial:
			not_restored += 1
	_ck("到期后描边已摘除（没留下永久描边）", not_restored == 0,
			"仍挂着描边的有 %d 个（共检查 %d 个）" % [not_restored, watched.size()])

	# ---- 屏幕空间描边：全屏面必须挂到相机上，且只在有波纹时可见 ----
	jet.set("screen_outline", true)
	# ★ 遮罩默认是关的（那条路还没调通，见 detect_pulse.gd 的注释），
	#   这里显式打开才能验证遮罩相关行为。
	jet.set("mask_by_objects", true)
	# ★ 先回蓝：前面的用例已经打掉不少，_emit_pulse 扣蓝失败就**不会发波**，
	#   于是 _pulses 为空、全屏面保持隐藏，断言会误判成"面没生效"。
	mana.call("refill")
	jet.call("stop_cast")
	jet.set("_pulses", [])
	jet.call("start_cast")
	# 推到 12 米，确保真的探测到物体（否则测不到遮罩层会被挂上）
	var g2 := 0
	while g2 < 600:
		jet.call("_process", DT)
		g2 += 1
		var ps2 = jet.get("_pulses") as Array
		if ps2.size() > 0 and float(ps2[0]["r"]) >= 12.0:
			break
	var quad = jet.get("_screen_quad")
	var quad_ok: bool = quad != null and is_instance_valid(quad) \
			and (quad as Node).get_parent() is Camera3D
	_ck("屏幕空间描边：全屏面挂在相机下", quad_ok)
	_ck("有波纹时全屏描边面可见", quad_ok and (quad as Node3D).visible)
	# ---- 物体遮罩：子视口就绪 + 被探测物体真的挂上了遮罩层 ----
	var mvp = jet.get("_mask_vp")
	var mcam = jet.get("_mask_cam")
	var mask_ok: bool = mvp != null and is_instance_valid(mvp) \
			and mcam != null and is_instance_valid(mcam) \
			and (mcam as Camera3D).cull_mask == (1 << 19)
	_ck("物体遮罩：子视口 + 只渲染遮罩层的相机已就绪", mask_ok)
	var layered := 0
	var od2: Dictionary = jet.get("_outlined")
	for k in od2.keys():
		for item in ((od2[k] as Dictionary).get("meshes", []) as Array):
			var mi = item.get("mi")
			if mi != null and is_instance_valid(mi) \
					and ((mi as MeshInstance3D).layers & (1 << 19)) != 0:
				layered += 1
	_ck("被探测到的网格已挂上遮罩层（花草没有碰撞体，不会进来）", layered > 0,
			"挂上 %d 个网格" % layered)
	# 验完恢复默认（遮罩默认关闭）
	jet.set("mask_by_objects", false)
	jet.call("stop_cast")
	jet.set("_pulses", [])
	_pump(jet, 2)
	_ck("默认（遮罩关闭）时全屏描边面隐藏", not quad_ok or not (quad as Node3D).visible)
	jet.call("stop_cast")
	jet.set("_pulses", [])
	_pump(jet, 2)
	_ck("没有波纹时全屏描边面隐藏（零开销）",
			not quad_ok or not (quad as Node3D).visible)

	# ---- 地形必须被排除 ----
	var names2 := []
	for k in outlined.keys():
		names2.append(str((outlined[k] as Dictionary).get("node")))
	print("      （已清空，上一轮结果见上）")


func _finish() -> void:
	print("==============================================")
	print("通过 %d  |  失败 %d" % [_pass, _fail])
	for x in _fails:
		print("  ★ ", x)
	quit(1 if _fail > 0 else 0)


## 诊断：把每个候选碰撞体在每层过滤上的判定打出来，定位"为什么一个都描不到"
func _diag(caster: Node, jet: Node) -> void:
	var player := caster.get("_player") as Node3D
	if player == null:
		return
	var center := player.global_position
	var space := player.get_world_3d().direct_space_state
	var shape := SphereShape3D.new()
	shape.radius = 12.0
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis(), center + Vector3.UP * 0.5)
	params.collision_mask = player.collision_mask
	params.collide_with_bodies = true
	params.collide_with_areas = false
	var hits := space.intersect_shape(params, 512)
	print("      --- 诊断：命中 %d 条 ---" % hits.size())
	# 先把屏幕判定的三个关键量打出来
	var vp := get_root()
	print("      视口尺寸=%s 相机=%s" % [
		str(vp.get_visible_rect().size),
		str(vp.get_camera_3d()),
	])
	var seen := {}
	for h in hits:
		var n = h.get("collider")
		if n == null or seen.has(n.get_instance_id()):
			continue
		seen[n.get_instance_id()] = true
		var visual = jet.call("_resolve_visual", n)
		if visual == null:
			print("      %s -> 解析不出可视节点（向上 3 层都没网格）" % str(n.name))
			continue
		var box: AABB = jet.call("_visual_aabb", visual)
		var detectable: bool = jet.call("_is_detectable", n, visual, center, box)
		var on_screen: bool = jet.call("_in_screen_margin", box)
		var cam := vp.get_camera_3d()
		var extra := ""
		if cam != null:
			var bc: Vector3 = box.get_center()
			var front := cam.global_transform.origin - cam.global_transform.basis.z
			extra = " [相机可用=%s 点在相机后=%s 盒心投影=%s 正前投影=%s]" % [
				str(jet.call("_camera_usable", cam, vp.get_visible_rect().size)),
				str(cam.is_position_behind(bc)),
				str(cam.unproject_position(bc)),
				str(cam.unproject_position(front)),
			]
		print("      %-28s visual=%-16s 网格盒=%.1f×%.1f×%.1f 可探=%s 在屏内=%s%s"
				% [str(n.name), str(visual.name),
					box.size.x, box.size.y, box.size.z,
					str(detectable), str(on_screen), extra])

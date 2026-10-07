@tool
extends Node3D
## 卡位监测（放进场景里就能用）
##
## 判据：看**通道宽度**，不是看"被围住"。
##   用略小的探针胶囊量出四对相反方向的自由距离，
##   通道宽度 = 自由距离之和 + 探针直径；最窄那一对**两侧都被挡**、且宽度小于
##   "角色直径 × min_passage_factor" → 判为能卡住角色（红色线框 + 尺寸坐标标签）。
##
## 三个踩过的坑（写在这里，别再犯）：
##   * 贴地采样点会被**地面碰撞体**顶住：探针底部在 y=0，而脚下就是地形，
##     intersect_shape 直接判"位置被占" → 所有贴地点被跳过 → 窄缝永远测不到。
##     所以探针要缩矮 + 逐级抬高，直到脱离地面。
##   * 缝比角色窄时全尺寸胶囊放不进去，所以探针要**逐级缩小**（宽度是从自由距离反推的，
##     与探针大小无关）。
##   * 角色的 CollisionShape3D 可能有好几个（交互 Area 的小盒子等），必须挑**最大的那个**，
##     否则角色直径被算得极小，"窄"就永远判不出来。
##
## 运行时快捷键默认 **L**（InputMap 动作 stuck_monitor_toggle，可改键）。
## 别用 F 系列：Godot 编辑器把 F8 当"停止运行"，按下去会把游戏关掉。
##
## 自检：屏幕上显示一行状态（谁被当成角色、半径多高、采样/命中数量），
## 同时写到 user://stuck_monitor_log.txt。查不出问题先看这一行。

@export var active := false             ## 监测开关（快捷键 L 切换）
@export var toggle_action := "stuck_monitor_toggle"
@export var toggle_key := KEY_L
@export var scan_radius := 12.0
@export var scan_step := 0.3
@export var coarse_factor := 2.0
@export var scan_interval := 1.0         ## 每轮扫描之间的间隔（秒）。1 秒扫一次就够，不必每帧扫
@export var samples_per_frame := 80      ## 每帧最多测几个点（一轮约 4800 点，80/帧 ≈ 1 秒扫完）
@export var max_probes_per_frame := 400  ## 每帧最多做几次"放置探针"查询（硬上限，防卡死/崩溃）
@export var max_queue := 4000            ## 采样队列上限（防止粗扫命中处无限追加）
@export var max_markers := 64            ## 标记上限，超出就淘汰最旧的（防 Label3D 爆内存）
@export var marker_grid := 0.6           ## 标记合并网格：同一片窄缝只留一个标记
@export var probe_range := 0.6
@export var probe_scale := 0.6
@export var min_passage_factor := 1.15
@export var blocked_ratio := 0.75
@export var band_factor := 2.0
@export var marker_ttl := 6.0
@export var collision_mask := 0xFFFFFFFF
@export var player_path: NodePath
@export var draw_markers := true
@export var show_blockers := false        ## 标签上是否显示【阻挡: A ↔ B】那行（默认隐藏）
@export var report_trapped := false       ## 是否也报「被围住」的点（默认关：判据太松，会喷一大片）
@export var marker_merge_distance := 1.0  ## 标记合并距离（米）：这么近已有可见标记就不再新建
@export var use_frustum := true
            ## 只扫可视区域；关掉就按半径扫（排查用）
@export var show_hud := true              ## 屏幕左上角显示自检状态
@export var log_status := true            ## 同时写 user://stuck_monitor_log.txt

var _player: Node3D = null
var _player_desc := "未找到"
var _camera: Camera3D = null
var _radius := 0.35
var _height := 1.8
var _queue: Array = []
var _cursor := 0
var _markers := {}
var _scan_time := 0.0
var _key_held := false
var _hud: Label = null
var _stat_timer := 0.0
var _log_timer := 0.0
var _sweeping := false
var _idle_timer := 0.0
var last_debug := {}
var _stat := {"tested": 0, "placed": 0, "tight": 0, "blocked_probe": 0, "round_hit": 0,
		"rounds": 0, "last_probes": 0}
var _shapes: Array = []                    ## 探针形状缓存 [pr, ph, shape]


func _ready() -> void:
	set_process(true)
	_make_hud()                                # 先建好但藏起来，按 L 显示时立刻能出现
	if _hud != null:
		_hud.visible = false
	_resolve_player()
	_camera = _find_camera()
	_rebuild_queue()
	_log_status(true)


func _process(delta: float) -> void:
	_scan_time += delta
	_handle_toggle()
	if not active:
		_update_hud()
		return
	if _player == null or not is_instance_valid(_player):
		_resolve_player()
		if _player == null:
			_update_hud()
			return
		_rebuild_queue()
	if not is_instance_valid(_camera):
		_camera = _find_camera()
	# 节奏：扫完一整轮就歇 scan_interval 秒（默认 1 秒扫一次，不必每帧都扫）
	if _sweeping:
		_scan(space_state())
		_update_hud()
		return
	_idle_timer -= delta
	if _idle_timer > 0.0:
		_update_hud()
		return
	if _queue.is_empty() or _cursor >= _queue.size():
		_rebuild_queue()
	_sweeping = true
	_scan(space_state())
	_update_hud()


# ------------------------------------------------------------------ 自检 HUD / 日志

func _make_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "StuckMonitorHUD"
	layer.layer = 100
	add_child(layer)
	_hud = Label.new()
	_hud.name = "Status"
	_hud.position = Vector2(12, 10)
	_hud.add_theme_font_size_override("font_size", 14)
	_hud.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	_hud.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_hud.add_theme_constant_override("outline_size", 6)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_hud)


func _update_hud() -> void:
	_stat_timer += get_process_delta_time()
	if _stat_timer < 0.4:
		return
	_stat_timer = 0.0
	if _hud != null:
		_hud.visible = active and show_hud
		if _hud.visible:
			_hud.text = status_line()
	# 日志别每 0.4 秒写一次盘，3 秒一次就够（HUD 仍是 0.4 秒刷新）
	_log_timer += 0.4
	if log_status and _log_timer >= 3.0:
		_log_timer = 0.0
		_log_status(false)


func status_line() -> String:
	var cam := "无(不按视野过滤)" if _camera == null else _camera.name
	return "[卡位监测]%s 角色=%s 半径=%.2f 高=%.2f 相机=%s 间隔=%.1fs(%s) 采样=%d 已测=%d(放得下%d) 窄=%d 标记=%d" % [
		"" if active else "(已关)",
		_player_desc, _radius, _height, cam,
		scan_interval, "扫描中" if _sweeping else "等待%.1fs".format([maxf(_idle_timer, 0.0)]),
		_queue.size(), int(_stat["tested"]), int(_stat["placed"]),
		int(_stat["tight"]), _markers.size()]


func _log_status(_force: bool) -> void:
	var f := FileAccess.open("user://stuck_monitor_log.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(status_line() + "\n" + last_status_extra() + "\n")
		f.close()


func last_status_extra() -> String:
	var free_text := "-"
	if last_debug.has("free"):
		var parts := PackedStringArray()
		for v in last_debug["free"]:
			parts.append("%.2f" % float(v))
		free_text = "[%s]" % ", ".join(parts)
	return "最后一次探针：placed=%s ｜ 自由距离=%s ｜ 最窄=%.3f 阈值=%.3f 两侧都被挡=%s" % [
		str(last_debug.get("placed", "?")), free_text,
		float(last_debug.get("min_width", -1.0)), float(last_debug.get("threshold", -1.0)),
		str(last_debug.get("both_blocked", "?"))]


# ------------------------------------------------------------------ 扫描

## 探针形状只建一次（原来每帧 new 几十上百个 CapsuleShape3D，白白 churn）
func _ensure_shapes() -> void:
	if not _shapes.is_empty() and absf(float(_shapes[0][3]) - _radius) < 0.0001:
		return
	_shapes.clear()
	for scale in [probe_scale, 0.4, 0.25, 0.12]:
		var pr := maxf(_radius * float(scale), 0.015)
		var ph := maxf(_height * 0.55, pr * 2.0 + 0.02)
		var shape := CapsuleShape3D.new()
		shape.radius = pr
		shape.height = ph
		_shapes.append([pr, ph, shape, _radius])


func space_state() -> PhysicsDirectSpaceState3D:
	var w := get_world_3d()
	return w.direct_space_state if w != null else null


func _scan(space: PhysicsDirectSpaceState3D) -> void:
	if space == null:
		return
	# 每帧有两个预算：采样点个数 + 物理查询次数。后者是硬上限 ——
	# 之前只有前者，而每个点最坏 20 次查询，300 点就 6000 次/帧，直接把游戏搞崩。
	var budget := maxi(samples_per_frame, 1)
	var probe_budget := maxi(max_probes_per_frame, 8)
	var found := 0
	while budget > 0 and probe_budget > 0 and _cursor < _queue.size():
		var entry = _queue[_cursor]
		_cursor += 1
		budget -= 1
		var p: Vector3 = entry[0]
		var is_coarse: bool = bool(entry[1])
		_stat["tested"] = int(_stat["tested"]) + 1
		var hit := _test_point(space, p)
		probe_budget -= maxi(int(_stat["last_probes"]), 1)
		if not hit.is_empty():
			found += 1
			_stat["tight"] = int(_stat["tight"]) + 1
			_make_marker(hit)
			if is_coarse:
				_queue_refine(p)
	_stat["round_hit"] = found
	if _cursor >= _queue.size():
		_stat["rounds"] = int(_stat["rounds"]) + 1
		_expire_markers()
		_rebuild_queue()          # 重建而不是只把游标归零：细扫补进来的点不再无限累积
		_sweeping = false         # 一轮扫完，歇 scan_interval 秒再扫
		_idle_timer = maxf(scan_interval, 0.05)


func _rebuild_queue() -> void:
	_queue.clear()
	_cursor = 0
	if _player == null:
		return
	var feet := _player.global_position
	var band := _height * band_factor
	for f in [0.15, 0.45, 0.75]:
		var y := band * float(f)
		var step := maxf(scan_step, 0.05) * maxf(coarse_factor, 1.0)
		var x := -scan_radius
		while x <= scan_radius:
			var z := -scan_radius
			while z <= scan_radius:
				if Vector2(x, z).length() <= scan_radius:
					var p := feet + Vector3(x, y, z)
					if _in_view(p):
						_queue.append([p, true])
				z += step
			x += step


func _queue_refine(center: Vector3) -> void:
	var half := maxf(scan_step, 0.05) * maxf(coarse_factor, 1.0) * 0.5
	for ix in range(-1, 2):
		for iz in range(-1, 2):
			if ix == 0 and iz == 0:
				continue
			var p := center + Vector3(half * float(ix), 0.0, half * float(iz))
			if _in_view(p) and _queue.size() < max_queue:
				_queue.append([p, false])


func _in_view(p: Vector3) -> bool:
	if _player != null:
		var flat := Vector2(p.x - _player.global_position.x, p.z - _player.global_position.z)
		if flat.length() > scan_radius:
			return false
	if use_frustum and is_instance_valid(_camera) and not _camera.is_position_in_frustum(p):
		return false
	return true


## 测一个采样点。返回 {} 表示这里不卡人。
func _test_point(space: PhysicsDirectSpaceState3D, pos: Vector3) -> Dictionary:
	# 探针要比角色小、要矮、还要逐级抬高（贴地点会被地面碰撞体顶住，见文件头）
	_ensure_shapes()
	var params := PhysicsShapeQueryParameters3D.new()
	params.collision_mask = collision_mask
	var pr := 0.0
	var ph := 0.0
	var placed := false
	var _blockers: Array = []
	var center := pos
	var probes := 0
	for variant in _shapes:
		if placed:
			break
		pr = float(variant[0])
		ph = float(variant[1])
		params.shape = variant[2]
		for lift in [0.04, 0.15, 0.3, 0.5, 0.8]:
			probes += 1
			var c := pos + Vector3(0, ph * 0.5 + float(lift), 0)
			params.transform = Transform3D(Basis(), c)
			var hits := space.intersect_shape(params, 1)
			if hits.is_empty():
				placed = true
				center = c
				break
			# 把"是谁挡住了"记下来，排查时一看就知道
			var blocker := "?"
			var col = hits[0].get("collider")
			if col is Node:
				blocker = "%s(%s)" % [(col as Node).name, (col as Node).get_class()]
			_blockers.append(blocker)
	if not placed:
		_stat["blocked_probe"] = int(_stat["blocked_probe"]) + 1
		_stat["last_probes"] = probes
		last_debug = {"placed": false, "pos": pos, "radius": _radius, "height": _height,
				"blockers": _blockers.duplicate()}
		return {}
	_stat["placed"] = int(_stat["placed"]) + 1
	_stat["last_probes"] = probes

	# 8 个水平方向 + 上/下：竖直方向必须测 —— "跳进去出不来"往往是地面与上方遮挡夹住，
	# 只看水平方向永远发现不了（用户说的"注意脚底下"）。
	var dirs := [
		Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK,
		Vector3(1, 0, 1).normalized(), Vector3(-1, 0, -1).normalized(),
		Vector3(1, 0, -1).normalized(), Vector3(-1, 0, 1).normalized(),
		Vector3.UP, Vector3.DOWN,
	]
	var free: Array = []
	var blocked := 0
	for d in dirs:
		params.motion = (d as Vector3) * probe_range
		var motion := space.cast_motion(params)
		var safe := float(motion[0]) if motion.size() >= 2 else 1.0
		var dist := safe * probe_range
		free.append(dist)
		if dist < probe_range - 0.001:
			blocked += 1

	var diameter := _radius * 2.0
	var min_width := 1.0e9
	var min_axis := 0
	var min_both_blocked := false
	var tight := false
	var threshold := diameter * min_passage_factor
	var pairs := [[0, 1], [2, 3], [4, 5], [6, 7], [8, 9]]   # 最后一对是 上/下
	for i in pairs.size():
		var pair: Array = pairs[i]
		var vertical := (i == 4)
		# 竖直方向的"通道宽度"要把探针自身高度也算回来，阈值用角色**身高**
		var w: float = float(free[pair[0]]) + float(free[pair[1]]) + (ph if vertical else pr * 2.0)
		var lim: float = _height * min_passage_factor if vertical else diameter * min_passage_factor
		# 两侧都必须被挡住：开阔地上"上"永远是通的，这样就不会把平地误判成卡位
		var both := (float(free[pair[0]]) < probe_range - 0.001
				and float(free[pair[1]]) < probe_range - 0.001)
		if both and w < lim and w < min_width:
			min_width = w
			min_axis = i
			min_both_blocked = true
			threshold = lim
			tight = true
	var trapped := blocked >= int(ceil(float(dirs.size()) * blocked_ratio))
	last_debug = {"placed": true, "pos": pos, "pr": pr, "ph": ph,
			"radius": _radius, "height": _height, "probe_range": probe_range,
			"free": free.duplicate(), "min_width": min_width, "diameter": diameter,
			"threshold": threshold, "tight": tight, "trapped": trapped,
			"blocked": blocked, "both_blocked": min_both_blocked, "axis": min_axis}
	if not tight and not (trapped and report_trapped):
		return {}
	# 查出最窄那一对到底是被**谁**挡住的（射线问一下），写进标记，免得"谁参与了检测"说不清
	var blockers := PackedStringArray()
	if tight and min_axis < pairs.size():
		var pair: Array = pairs[min_axis]
		for idx in pair:
			var dir: Vector3 = dirs[idx]
			var q := PhysicsRayQueryParameters3D.new()
			q.from = center
			q.to = center + dir * (probe_range + 0.2)
			q.collision_mask = collision_mask
			var hit := space.intersect_ray(q)
			if hit.has("collider") and hit["collider"] is Node:
				blockers.append(describe_collider(hit["collider"] as Node))
	last_debug["blockers_pair"] = blockers
	# 尺寸兜底：走"被围住"这条路时最窄宽度从没算过，哨兵值 1e9 会被当成尺寸打出来
	# （用户截图里那个 1000000000.00 就是这么来的）
	if min_width > 1.0e8:
		min_width = _radius * 2.0
	var width := maxf(min_width, 0.05)
	# 框的底部锚到"脚底下的地面"：向下还能走多远 = center 到地面的距离
	var ground_y: float = center.y - ph * 0.5 - float(free[9])
	return {"pos": pos, "size": Vector3(width, _height, width), "blocked": blocked,
			"tight": tight, "ground_y": ground_y, "blockers": blockers}


# ------------------------------------------------------------------ 标记

func _make_marker(pocket: Dictionary) -> void:
	var pos: Vector3 = pocket["pos"]
	var size: Vector3 = pocket["size"]
	# 按 marker_grid 合并：一片窄缝只留一个标记，否则几十个 Label3D 会把内存吃爆
	var g := maxf(marker_grid, 0.05)
	var key := "%d_%d_%d" % [roundi(pos.x / g), roundi(pos.y / g), roundi(pos.z / g)]
	if _markers.has(key) and is_instance_valid(_markers[key]):
		var old := _markers[key] as Node3D
		old.set_meta("last_seen", _scan_time)
		old.visible = true                 # 之前只隐藏没释放，这里复用它
		return
	if not draw_markers:
		return
	# 附近已有可见标记？那就只是刷新它的时间，别再叠一个（否则一片区域会堆成一大摞框）
	var merge := maxf(marker_merge_distance, 0.1)
	for k2 in _markers.keys():
		var m2 = _markers[k2]
		if m2 == null or not is_instance_valid(m2) or not (m2 as Node3D).visible:
			continue
		if (m2 as Node3D).global_position.distance_to(pos) < merge:
			(m2 as Node3D).set_meta("last_seen", _scan_time)
			return
	if _markers.size() >= max_markers:
		_evict_oldest_marker()
		if _markers.size() >= max_markers:
			return
	var holder := Node3D.new()
	holder.name = "StuckMark"
	# 标记框是"有 mesh 没碰撞体"的视觉物件。相机的遮挡淡出系统会收集所有 MeshInstance3D
	# （它刻意不要求碰撞体），于是会把我的标记当成遮挡物——正是用户说的
	# "没有碰撞体的物体也参与检测了"。它留了后门：occlusion_ignore 组里的子树永不挖洞。
	holder.add_to_group("occlusion_ignore")
	holder.top_level = true                   # 不受本节点自身变换影响（否则标记会跑偏）
	add_child(holder)
	# 让框**站在地面上**（原来以采样点为中心，下半截陷进地下，看着像没对准脚）
	holder.global_position = Vector3(pos.x, float(pocket.get("ground_y", pos.y)) + size.y * 0.5, pos.z)
	holder.set_meta("last_seen", _scan_time)

	var mi := MeshInstance3D.new()
	mi.mesh = _box_lines(size)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.15, 0.15)
	mat.no_depth_test = true
	mi.material_override = mat
	holder.add_child(mi)

	var label := Label3D.new()
	var who := ""
	var bl = pocket.get("blockers", null)
	if show_blockers and bl is PackedStringArray and (bl as PackedStringArray).size() > 0:
		who = "\n阻挡: %s" % " ↔ ".join(bl as PackedStringArray)
	label.text = "卡位 %.2f×%.2f×%.2f m\n@ (%.1f, %.1f, %.1f)%s" % [
			size.x, size.y, size.z, pos.x, pos.y, pos.z, who]
	label.font_size = 48
	label.outline_size = 12
	label.modulate = Color(1.0, 0.25, 0.25)
	label.no_depth_test = true
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.position = Vector3(0, size.y * 0.5 + 0.25, 0)
	holder.add_child(label)
	_markers[key] = holder


## 给碰撞体一个**有辨识度**的名字。
## 为什么需要：导入/自动生成的碰撞体大量都叫 StaticBody3D，只写节点名根本分不清是哪一个，
## 用户会以为是旁边那个（比如"木桶"）——而真正打中的是另一个同名碰撞体。
func describe_collider(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return "?"
	# 只写节点名没用（导入生成的碰撞体全叫 StaticBody3D），所以给出**从场景根起的路径**。
	var path := String(node.get_path())
	var scene := get_tree().current_scene if get_tree() != null else null
	if scene != null:
		var prefix := String(scene.get_path()) + "/"
		if path.begins_with(prefix):
			path = path.substr(prefix.length())
	return path


func _box_lines(size: Vector3) -> ArrayMesh:
	var h := size * 0.5
	var c: Array = []
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				c.append(Vector3(sx * h.x, sy * h.y, sz * h.z))
	var pts := PackedVector3Array()
	for i in 8:
		for b in 3:
			var j := i ^ (1 << b)
			if j > i:
				pts.append(c[i])
				pts.append(c[j])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return am


func _expire_markers() -> void:
	for key in _markers.keys():
		var m = _markers[key]
		if m == null or not is_instance_valid(m):
			_markers.erase(key)
			continue
		if _scan_time - float((m as Node3D).get_meta("last_seen", 0.0)) > marker_ttl:
			# 只隐藏、不释放：别的系统（相机遮挡淡出等）会缓存 MeshInstance3D，
			# 频繁释放会让它们的引用悬空报错。节点留着复用，数量由 max_markers 兜住。
			(m as Node3D).visible = false


func _evict_oldest_marker() -> void:
	var oldest_key = null
	var oldest := 1.0e20
	for key in _markers.keys():
		var m = _markers[key]
		if m == null or not is_instance_valid(m):
			_markers.erase(key)
			continue
		var seen := float((m as Node3D).get_meta("last_seen", 0.0))
		if seen < oldest:
			oldest = seen
			oldest_key = key
	if oldest_key != null:
		var m2 = _markers[oldest_key]
		if m2 != null and is_instance_valid(m2):
			(m2 as Node3D).queue_free()
		_markers.erase(oldest_key)


func _clear_markers() -> void:
	for key in _markers.keys():
		var m = _markers[key]
		if m != null and is_instance_valid(m):
			(m as Node3D).queue_free()
	_markers.clear()


# ------------------------------------------------------------------ 角色 / 相机

func _resolve_player() -> void:
	if player_path != NodePath(""):
		_player = get_node_or_null(player_path) as Node3D
		if _player != null:
			_player_desc = "%s(指定)" % _player.name
			_read_shape()
			return
	var tree := get_tree()
	if tree == null:
		return
	var by_group := tree.get_first_node_in_group("player")
	if by_group is Node3D:
		_player = by_group as Node3D
		_player_desc = "%s(player组)" % _player.name
	else:
		# 不是随便第一个 CharacterBody3D —— 必须是"带碰撞形状"的，否则尺寸读不出来
		for n in _all_nodes(tree.root):
			if n is CharacterBody3D and _main_collision(n) != null:
				_player = n as Node3D
				_player_desc = "%s(第一个带碰撞的CharacterBody3D)" % _player.name
				break
		if _player == null:
			for n in _all_nodes(tree.root):
				if (n is RigidBody3D or n is AnimatableBody3D) and _main_collision(n) != null:
					_player = n as Node3D
					_player_desc = "%s(退化的刚体)" % _player.name
					break
	if _player == null:
		_player_desc = "未找到(请设置 player_path 或把角色加进 player 组)"
		return
	_read_shape()


## 挑角色**主要**的碰撞形状：忽略 Area3D 上的（交互区小盒子），直接子节点优先，取体积最大者。
## 挑错了会让角色直径极小 → 永远判不出"窄"。
func _main_collision(node: Node) -> CollisionShape3D:
	var best: CollisionShape3D = null
	var best_vol := -1.0
	var stack: Array = []
	for c in node.get_children():
		stack.append([c, 0])
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var depth: int = item[1]
		if n is Area3D:
			continue
		if n is CollisionShape3D:
			var cs := n as CollisionShape3D
			if cs.shape != null and not cs.disabled:
				var vol := _shape_volume(cs.shape)
				if depth == 0:
					vol *= 2.0                    # 直接子节点优先
				if vol > best_vol:
					best_vol = vol
					best = cs
			continue
		if depth < 3:
			for c in n.get_children():
				stack.append([c, depth + 1])
	return best


func _shape_volume(s: Shape3D) -> float:
	if s is CapsuleShape3D:
		var c := s as CapsuleShape3D
		return PI * c.radius * c.radius * c.height
	if s is CylinderShape3D:
		var y := s as CylinderShape3D
		return PI * y.radius * y.radius * y.height
	if s is BoxShape3D:
		var b := s as BoxShape3D
		return b.size.x * b.size.y * b.size.z
	if s is SphereShape3D:
		var sp := s as SphereShape3D
		return 4.0 / 3.0 * PI * sp.radius * sp.radius * sp.radius
	return 0.0


## 从角色的碰撞形状读"实际尺寸"（含世界缩放）
func _read_shape() -> void:
	if _player == null:
		return
	var cs := _main_collision(_player)
	if cs == null:
		_player_desc += "(没找到碰撞形状)"
		return
	var s: Shape3D = cs.shape
	if s is CapsuleShape3D:
		_radius = (s as CapsuleShape3D).radius
		_height = (s as CapsuleShape3D).height
	elif s is CylinderShape3D:
		_radius = (s as CylinderShape3D).radius
		_height = (s as CylinderShape3D).height
	elif s is BoxShape3D:
		var b: Vector3 = (s as BoxShape3D).size
		_radius = maxf(b.x, b.z) * 0.5
		_height = b.y
	elif s is SphereShape3D:
		_radius = (s as SphereShape3D).radius
		_height = _radius * 2.0
	var sc: Vector3 = cs.global_transform.basis.get_scale()
	_radius *= maxf(sc.x, sc.z)
	_height *= sc.y


func _find_camera() -> Camera3D:
	var tree := get_tree()
	if tree == null:
		return null
	var cam := tree.root.get_camera_3d()
	if cam != null:
		return cam
	for n in _all_nodes(tree.root):
		if n is Camera3D and (n as Camera3D).current:
			return n
	return null


func _all_nodes(root: Node) -> Array:
	var out: Array = []
	if root == null:
		return out
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


# ------------------------------------------------------------------ 快捷键

func _handle_toggle() -> void:
	if InputMap.has_action(toggle_action):
		if not Input.is_action_just_pressed(toggle_action):
			return
	else:
		var down := Input.is_physical_key_pressed(toggle_key)
		var fresh := down and not _key_held
		_key_held = down
		if not fresh:
			return
	toggle()


func toggle() -> void:
	active = not active
	if not active:
		_clear_markers()
	print("[卡位监测] %s" % ("显示" if active else "隐藏"))
	_log_status(true)


# ------------------------------------------------------------------ 供测试/调试

func character_size() -> Vector2:
	return Vector2(_radius, _height)


func marker_count() -> int:
	var n := 0
	for key in _markers.keys():
		var m = _markers[key]
		if m != null and is_instance_valid(m) and (m as Node3D).visible:
			n += 1
	return n


func scan_progress() -> Vector2i:
	return Vector2i(_cursor, _queue.size())


func status_now() -> String:
	return status_line()


## 测试用：直接判断一个点是否卡人（不依赖 _process）
func probe_point(pos: Vector3) -> Dictionary:
	var space := space_state()
	if space == null:
		return {}
	return _test_point(space, pos)

extends Node
## 握持截图：等游戏起来 → 把相机挪到"看手/法杖"的近景 → 截图 → 退出。
## 用法（**必须非 headless**，headless 无法渲染）：
##   godot --path <项目> tools/grip_shot.tscn

const OUT_DIR := "res://.runtime/grip_check"


func _ready() -> void:
	await _run()
	get_tree().quit()


func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var vp := get_viewport()
	if vp == null:
		print("[GripShot] 没有 viewport")
		return
	var img := vp.get_texture().get_image()
	if img == null:
		print("[GripShot] 拿不到画面")
		return
	var err := img.save_png(path)
	print("[GripShot] 保存 %s → %s (%dx%d)" % [path, "OK" if err == OK else str(err),
		img.get_width(), img.get_height()])


func _run() -> void:
	# ★ 先"脱离 current_scene 身份"：否则 change_scene_to_file 会把本节点（以及协程）一起释放 ✗
	var root := get_tree().root
	if get_parent() == root:
		root.remove_child(self)
		get_tree().current_scene = null
		root.add_child(self)
		print("[GripShot] 已脱离场景根身份，切场景后仍存活 ✓")
	# 先切到游戏主场景（单独跑 tools/*.tscn 时不会自动加载主场景）
	var main_path := "res://scenes/main.tscn"
	if not ResourceLoader.exists(main_path):
		print("[GripShot] 找不到主场景 %s" % main_path)
		return
	var err0 := get_tree().change_scene_to_file(main_path)
	print("[GripShot] 切换到主场景 → %s" % str(err0))
	await get_tree().process_frame
	# 用**墙钟计时**等待（这个场景很重、帧率很低，按帧等会等很久）
	await get_tree().create_timer(3.0).timeout
	await get_tree().create_timer(6.0).timeout
	print("[GripShot] 等待完成，开始截图")
	var player: Node3D = null
	var g := get_tree().get_nodes_in_group("player")
	if not g.is_empty():
		player = g[0] as Node3D
	if player == null:
		for c in get_tree().current_scene.get_children():
			if c.get_class() == "CharacterBody3D":
				player = c as Node3D
				break
	print("[GripShot] player = %s" % str(player))
	if player == null:
		print("[GripShot] 找不到玩家，放弃")
		return

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# ① 默认第三人称视角（和玩家看到的接近）→ 全景
	await get_tree().create_timer(1.2).timeout
	await _save(OUT_DIR + "/01_third_person.png")

	# ② 手动相机：贴着左手拍近景（看握点/小球/法杖关系）
	var cam := Camera3D.new()
	cam.name = "GripShotCam"
	cam.fov = 45.0
	cam.near = 0.02
	get_tree().current_scene.add_child(cam)
	cam.current = true

	var hand: Node3D = null
	var stack: Array[Node] = [player]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is BoneAttachment3D and String(cur.name).contains("Hand"):
			hand = cur as Node3D
			break
		for c in cur.get_children():
			stack.append(c)
	if hand == null:
		# 兜底：找名字含 hand 的节点
		stack = [player]
		while not stack.is_empty():
			var cur: Node = stack.pop_back()
			if String(cur.name).to_lower().contains("hand"):
				hand = cur as Node3D
				break
			for c in cur.get_children():
				stack.append(c)
	print("[GripShot] hand socket = %s" % str(hand))
	var center: Vector3 = hand.global_position if hand != null else player.global_position + Vector3.UP * 1.2

	# 相机从角色的"左前方上方"看向手
	var basis_off := Vector3(0.55, 0.28, 0.55)
	cam.global_position = center + basis_off
	cam.look_at(center, Vector3.UP)
	await get_tree().create_timer(0.6).timeout
	await _save(OUT_DIR + "/02_hand_close.png")

	# ③ 更近、从正前方看（看"杖是否穿过掌心/小球"）
	cam.global_position = center + Vector3(0.32, 0.10, 0.42)
	cam.look_at(center, Vector3.UP)
	await get_tree().create_timer(0.6).timeout
	await _save(OUT_DIR + "/03_hand_front.png")

	# ④ 从上方俯视（看杖轴是否落在掌心）
	cam.global_position = center + Vector3(0.10, 0.42, 0.16)
	cam.look_at(center, Vector3.UP)
	await get_tree().create_timer(0.6).timeout
	await _save(OUT_DIR + "/04_hand_top.png")
	print("[GripShot] 完成 ✓")

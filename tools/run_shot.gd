extends Node
## 跑动 / 起跳时的体态截图 —— 用来验证"左右镜像"后跑姿是否协调 ✓
## 用法：godot --path <项目> --resolution 900x700 res://tools/run_shot.tscn
##
## 怎么驱动的：直接调玩家自己的公开接口（set_moving / set_running / on_jump ✓）——
##   无头/无人操作时也能让**跑动动画与跳姿**真的播起来 ✓，比硬塞输入事件可靠 ✓。
## 输出：res://.runtime/run_check/01_run.png、02_jump.png


const OUT := "res://.runtime/run_check"


func _ready() -> void:
	await _run()
	get_tree().quit()


func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var vp := get_viewport()
	if vp == null:
		return
	var img := vp.get_texture().get_image()
	if img != null:
		print("[RunShot] 保存 %s → %s (%dx%d)" % [path, str(img.save_png(path)), img.get_width(), img.get_height()])


func _run() -> void:
	var root := get_tree().root
	if get_parent() == root:
		root.remove_child(self)
		get_tree().current_scene = null
		root.add_child(self)
	print("[RunShot] 切主场景 → %s" % str(get_tree().change_scene_to_file("res://scenes/main.tscn")))
	await get_tree().create_timer(3.0).timeout
	await get_tree().create_timer(5.0).timeout
	var p: Node = null
	var g := get_tree().get_nodes_in_group("player")
	if not g.is_empty():
		p = g[0]
	if p == null:
		print("[RunShot] ✗ 找不到玩家")
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	# 自建斜前方近景相机（游戏自带相机是从上往下 ✗ 看不清跑姿 ✓）
	var cam := Camera3D.new()
	cam.name = "RunShotCam"
	cam.fov = 45.0
	cam.near = 0.05
	get_tree().current_scene.add_child(cam)
	cam.current = true
	var center: Vector3 = (p as Node3D).global_position + Vector3.UP * 0.85
	cam.global_position = center + Vector3(2.4, 0.55, 2.4)
	cam.look_at(center, Vector3.UP)
	await get_tree().create_timer(0.4).timeout
	# ① 跑动：驱动跑动动画（原地跑 ✓ 看的是**体态** ✓）
	p.call("set_moving", true)
	p.call("set_running", true)
	await get_tree().create_timer(1.2).timeout
	await _save(OUT + "/01_run.png")
	# ② 起跳：走玩家的跳跃接口（内部会 seek 到空气段 + 调 speed_scale ✓）
	if p.has_method("on_jump"):
		p.call("on_jump", 0.72)
		await get_tree().create_timer(0.28).timeout
		await _save(OUT + "/02_jump.png")
	# 顺手报一下镜像状态 ✓
	var mirror: Node = p.get("_arm_mirror") as Node
	if mirror != null:
		print("[RunShot] 镜像器 active=%s ✓" % str(mirror.call("is_active")))
	print("[RunShot] 完成 ✓")

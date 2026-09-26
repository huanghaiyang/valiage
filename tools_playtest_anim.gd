extends SceneTree
## TEMP: 主场景真实播放 kaykit 动作，采样骨骼确认动画驱动

func _init() -> void:
	var ps: PackedScene = load("res://scenes/main.tscn")
	var main := ps.instantiate()
	root.add_child(main)
	# 找 Player
	var player: Node = _find(main, "Player")
	if player == null:
		push_error("no Player")
		quit(1)
		return
	var ap: AnimationPlayer = player.get("anim_player")
	if ap == null:
		push_error("no anim_player")
		quit(1)
		return
	var body: Node3D = player.get("body")
	var sk: Skeleton3D = _find_skeleton(body)
	if sk == null:
		push_error("no skeleton")
		quit(1)
		return
	print("library count=", ap.get_animation_library_list())
	for lib_name in ap.get_animation_library_list():
		print("  lib=", lib_name, " anims=", ap.get_animation_library(lib_name).get_animation_list())
	# 播放 Wave
	var rest_arm := sk.get_bone_global_pose(sk.find_bone("upperarm.l")).origin
	ap.play("kaykit/Wave")
	# 等待几帧让动画真正应用
	await process_frame
	await process_frame
	await process_frame
	await process_frame
	await process_frame
	var p := ap.current_animation_position
	var a1 := sk.get_bone_global_pose(sk.find_bone("upperarm.l")).origin
	var h1 := sk.get_bone_global_pose(sk.find_bone("hips")).origin
	print("Wave playing pos=%.2f armΔ=%s hipΔ=%s" % [p, (a1 - rest_arm).round(), (h1 - _rest_hip(sk)).round()])
	# 播放 Hop 确认 hips 上跳
	ap.play("kaykit/Hop")
	await process_frame
	await process_frame
	await process_frame
	await process_frame
	await process_frame
	var p2 := ap.current_animation_position
	var h2 := sk.get_bone_global_pose(sk.find_bone("hips")).origin
	print("Hop playing pos=%.2f hipΔ=%s" % [p2, (h2 - _rest_hip(sk)).round()])
	root.remove_child(main)
	main.free()
	quit()

func _rest_hip(sk: Skeleton3D) -> Vector3:
	return sk.get_bone_global_pose(sk.find_bone("hips")).origin

func _find(n: Node, name: String) -> Node:
	if n.name == name:
		return n
	for c in n.get_children():
		var r := _find(c, name)
		if r != null:
			return r
	return null

func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

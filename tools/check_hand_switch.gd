extends Node
## 端到端验证「游戏内 G 键切换左右手持杖」：
##   加载主场景 → 等玩家就绪 → 用 Input.parse_input_event 真按一次 Q → 检查 staff_hand/挂点骨 →
##   再按一次 Q 切回 → 检查复位 ✓。跑完自己退出。
##
## 用法（窗口/无头都可以；无头更省事）：
##   godot --headless --path <项目> res://tools/check_hand_switch.tscn


func _ready() -> void:
	await _run()
	get_tree().quit()


func _find_player() -> Node:
	var g := get_tree().get_nodes_in_group("player")
	if not g.is_empty():
		return g[0]
	var cur := get_tree().current_scene
	if cur != null:
		for c in cur.get_children():
			if c is CharacterBody3D:
				return c
	return null


func _press_key() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_G
	ev.physical_keycode = KEY_G
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var up := InputEventKey.new()
	up.keycode = KEY_G
	up.physical_keycode = KEY_G
	up.pressed = false
	Input.parse_input_event(up)


func _socket_bone(p: Node) -> String:
	for c in p.get_children():
		var found := _find_socket(c)
		if found != "":
			return found
	return ""


func _find_socket(n: Node) -> String:
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is BoneAttachment3D:
			return String((cur as BoneAttachment3D).bone_name)
		for c in cur.get_children():
			stack.append(c)
	return ""


func _run() -> void:
	# 脱离 current_scene 身份，切主场景后不被释放（同 tools/grip_shot.gd ✓）
	var root := get_tree().root
	if get_parent() == root:
		root.remove_child(self)
		get_tree().current_scene = null
		root.add_child(self)
	var err := get_tree().change_scene_to_file("res://scenes/main.tscn")
	print("[换手测试] 切换到主场景 → %s" % str(err))
	# 墙钟等待（这个场景很重、帧率低 ✓）
	await get_tree().create_timer(3.0).timeout
	await get_tree().create_timer(4.0).timeout
	var p := _find_player()
	if p == null:
		print("[换手测试] ✗ 找不到玩家")
		return
	print("[换手测试] 玩家 = %s｜初始 staff_hand=%s｜挂点骨=%s" % [
		p.name, str(p.get("staff_hand")), _socket_bone(p)])
	var h0 := int(p.get("staff_hand"))
	var _bone0 := _socket_bone(p)
	# 按 G → 应切到另一侧
	await _press_key()
	await get_tree().create_timer(0.8).timeout
	var h1 := int(p.get("staff_hand"))
	var bone1 := _socket_bone(p)
	print("[换手测试] 按 G 后 → staff_hand=%d｜挂点骨=%s %s" % [
		h1, bone1, "✓ 已换到另一侧" if h1 != h0 and bone1 != _bone0 else "✗ 没换"])
	# 再按 G → 应切回
	await _press_key()
	await get_tree().create_timer(0.8).timeout
	var h2 := int(p.get("staff_hand"))
	var bone2 := _socket_bone(p)
	print("[换手测试] 再按 G → staff_hand=%d｜挂点骨=%s %s" % [
		h2, bone2, "✓ 已切回" if h2 == h0 and bone2 == _bone0 else "✗ 没切回"])
	print("[换手测试] 结论：%s" % (
		"✓ 游戏内 G 键切换链路正常（来回都正确）" if (h1 != h0 and h2 == h0 and bone1 != _bone0 and bone2 == _bone0)
		else "✗ 有环节不对，看上面两行"))

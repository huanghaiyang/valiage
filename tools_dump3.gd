extends SceneTree
## TEMP: dump Mage Idle 动画轨道路径前缀 + 循环模式

func _init() -> void:
	var mage_scene: PackedScene = load("res://assets/models/characters/Mage.glb")
	var mage := mage_scene.instantiate()
	root.add_child(mage)
	var ap := _find_anim_player(mage)
	if ap != null and ap.has_animation("Idle"):
		var idle: Animation = ap.get_animation("Idle")
		print("MAGE Idle len=%.2f loop=%d tracks=%d" % [idle.length, idle.loop_mode, idle.get_track_count()])
		for t in idle.get_track_count():
			print("  [%d] type=%d path=%s keys=%d" % [t, idle.track_get_type(t), idle.track_get_path(t), idle.track_get_key_count(t)])
	root.remove_child(mage)
	mage.free()
	quit()

func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null

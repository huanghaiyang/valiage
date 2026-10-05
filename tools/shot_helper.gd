extends Node
## 视觉验证助手：等游戏起来 -> 摆出通用选点圆圈 -> 截图 -> 放一次火焰灼烧 -> 截图
## 由 tools/shot_targeting.tscn 启动，跑完自己退出。


func _ready() -> void:
	await _run()
	get_tree().quit()


func _save(path: String) -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var vp := get_viewport()
	if vp == null:
		push_warning("[Shot] 没有 viewport")
		return
	var img := vp.get_texture().get_image()
	if img == null:
		push_warning("[Shot] 拿不到画面")
		return
	var err := img.save_png(path)
	print("[Shot] 保存 %s -> %s (%dx%d)" % [path, "ok" if err == OK else str(err),
			img.get_width(), img.get_height()])


func _find() -> Array:
	# 等主场景就位
	for i in range(120):
		if get_tree().current_scene != null:
			break
		await get_tree().process_frame
	# 再等游戏自己初始化（地形、玩家生成）
	for i in range(180):
		await get_tree().process_frame
	var caster := get_tree().root.get_node_or_null("SpellCaster")
	var player: Node3D = null
	if caster != null:
		caster.call("_find_nodes")
		player = caster.get("_player")
	if player == null:
		# 兜底：按组找
		var g := get_tree().get_nodes_in_group("player")
		if not g.is_empty():
			player = g[0]
	return [caster, player]


func _run() -> void:
	var pair := await _find()
	var caster: Node = pair[0]
	var player: Node3D = pair[1]
	print("[Shot] caster=%s player=%s" % [str(caster), str(player)])
	if player == null:
		push_warning("[Shot] 找不到玩家，放弃")
		return
	await get_tree().create_timer(2.0).timeout

	# ---- ① 通用选点圆圈（用配置表里的参数）----
	var sheet := load("res://scripts/spells/spell_sheet.gd")
	var tg: Dictionary = sheet.get_spell("flame_scorch").get("targeting", {})
	var t: Node3D = (load("res://scripts/spells/spell_targeting.gd") as GDScript).new()
	t.name = "ShotTargeting"
	get_tree().root.add_child(t)
	t.call("setup", player, get_viewport().get_camera_3d())
	t.call("configure", tg)
	t.call("begin")
	t.set_process(false)          # 关掉鼠标跟随，否则每帧会覆盖下面手动设的中心
	# 摆到主角正前方 2.5 米（肯定在画面里）
	var fwd := -player.global_transform.basis.z
	fwd.y = 0.0
	var c := player.global_position + fwd.normalized() * 2.5
	c.y = player.global_position.y
	t.set("_center", c)
	t.set("_dirty", true)
	t.call("_rebuild_mesh")
	var disc := t.get("_disc") as MeshInstance3D
	var m := disc.material_override as ShaderMaterial
	for i in range(10):
		await get_tree().process_frame
	var aabb := disc.get_aabb()
	var gaabb := aabb
	print("[Shot] 圆圈 中心=%s 直径=%.2f" % [str(c), float(t.call("diameter"))])
	print("[Shot] 圆盘节点全局位置=%s 可见=%s (intree=%s) 材质=%s" % [
			str(disc.global_transform.origin), str(disc.visible),
			str(disc.is_visible_in_tree()), str(m != null and m.shader != null)])
	print("[Shot] 圆盘局部AABB pos=%s size=%s" % [str(aabb.position), str(aabb.size)])
	print("[Shot] 相机位置=%s 朝向=%s" % [str(get_viewport().get_camera_3d().global_position),
			str(-get_viewport().get_camera_3d().global_transform.basis.z)])
	await _save("res://screenshots/verify_targeting.png")

	# ---- ② 火焰灼烧：在圈内放一次 ----
	var spell: Node3D = (load("res://scripts/spells/flame_scorch.gd") as GDScript).new()
	spell.name = "ShotScorch"
	get_tree().root.add_child(spell)
	spell.call("setup", player, null)
	var mana := get_tree().root.get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
	spell.call("cast_at", c, float(t.call("radius")))
	print("[Shot] 施放：state=%d 簇数=%d 蓝=%.1f" % [int(spell.get("_state")),
			int(spell.get("_used")), float(mana.get("current")) if mana != null else -1.0])
	# 等点燃 + 烧起来
	await get_tree().create_timer(1.6).timeout
	await _save("res://screenshots/verify_scorch.png")

	# ---- ③ 靠近一点再看一张（火焰细节）----
	t.call("end")
	if caster != null:
		caster.set("enabled", false)     # 免得它把选点器又拉起来
	await get_tree().create_timer(0.4).timeout
	await _save("res://screenshots/verify_scorch_2.png")
	print("[Shot] 完成")

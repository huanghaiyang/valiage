extends SceneTree
## 自检：金色守护 / 流水治疗 / 隐身 三门法术**同时存在**时的兼容性。
##   ① body_overlay_chain 分层链：叠加、替换、按材质摘除、全部摘完还原原 overlay；
##   ② 切换术法时，仍在生效的共享 jet 不再被 queue_free（金盾/水膜不会被取消）；
##   ③ 金盾碎裂阶段不会被 _sweep_instances 提前回收；
##   ④ 金盾结束只摘下自己那层，水膜继续保留；水膜结束后 overlay 精确还原；
##   ⑤ 隐身（transparency）与水膜（overlay）互不干扰，且切走术法后隐身效果仍在。
## 跑法：godot --headless --path D:\sgames\CozyVale --quit --script res://tools/verify_spell_coexist.gd

const CHAIN := preload("res://scripts/spells/body_overlay_chain.gd")
const DT := 1.0 / 30.0

## ★ 法术脚本改用运行时 load()：--script 模式下 autoload 名字要等启动后才注册，
##   preload 会在编译期把法术脚本（内部引用 Mana）一起编译而报 "Identifier not found: Mana"。
var _CASTER: GDScript

var _fails := 0
var _checks := 0


var _ran := false


## ★ 测试放到第一帧 _process：_initialize 时机点是场景树还没"进树"的，
##   3D 节点取 global_transform 会报 !is_inside_tree()，薄膜/罩壳的尺寸计算会拿到零变换。
func _process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_run()
	return true


func _run() -> void:
	_CASTER = load("res://scripts/spells/spell_caster.gd")
	var root := Node3D.new()
	root.name = "TestRoot"
	get_root().add_child(root)
	# ---- 假角色：两个网格 + 法杖 ----
	var player := Node3D.new()
	player.name = "Player"
	root.add_child(player)
	var meshes: Array[MeshInstance3D] = []
	for i in 2:
		var mi := MeshInstance3D.new()
		mi.name = "Body%d" % i
		var bm := BoxMesh.new()
		bm.size = Vector3(0.4, 1.4, 0.3)
		mi.mesh = bm
		mi.position = Vector3(float(i) * 0.35 - 0.175, 0.7, 0.0)
		player.add_child(mi)
		meshes.append(mi)
	var staff := Node3D.new()
	staff.name = "Staff"
	player.add_child(staff)
	var mana := get_root().get_node_or_null("Mana")
	if mana != null:
		mana.call("refill")
		mana.set("current", 200.0)

	_test_chain(player)
	_test_coexist(root, player, staff, meshes)
	_test_invisibility(root, player, staff, meshes)


# ---------------------------------------------------------------- ① 分层链
func _test_chain(player: Node3D) -> void:
	var m := MeshInstance3D.new()
	m.name = "ChainProbe"
	m.mesh = BoxMesh.new()
	m.position = Vector3(0.0, 0.7, 1.0)
	player.add_child(m)
	var orig := StandardMaterial3D.new()
	m.material_overlay = orig
	var wa := ShaderMaterial.new()
	var wb := ShaderMaterial.new()
	var ga := ShaderMaterial.new()

	CHAIN.attach(m, "water_heal", wa)
	CHAIN.attach(m, "gold_body", ga)
	_check(m.material_overlay == wa, "链：先贴的水膜在 overlay 槽位")
	_check(wa.next_pass == ga, "链：水膜 next_pass 指向金膜")

	CHAIN.detach(m, "water_heal", wa)
	_check(m.material_overlay == ga and ga.next_pass == null, "链：摘水膜后金膜顶上且尾巴断开")
	CHAIN.detach(m, "gold_body", ga)
	_check(m.material_overlay == orig, "链：全部摘完还原原本的 overlay")

	CHAIN.attach(m, "water_heal", wa)
	CHAIN.attach(m, "water_heal", wb)
	_check(m.material_overlay == wb, "链：同种类新膜替换旧膜（不叠成两层）")
	CHAIN.detach(m, "water_heal", wa)
	_check(m.material_overlay == wb, "链：旧实例摘膜不会摘掉新膜")
	CHAIN.detach(m, "water_heal", wb)
	_check(m.material_overlay == orig, "链：替换后摘除仍还原原 overlay")
	m.free()


# ---------------------------------------------------------------- ②③④ 金 + 水
func _test_coexist(root: Node3D, player: Node3D, staff: Node3D, meshes: Array[MeshInstance3D]) -> void:
	var caster: Node = _CASTER.new()
	caster.name = "ProbeCaster"
	root.add_child(caster)
	caster.set("enabled", false)          # 不走输入驱动的自动施法，测试只手动调接口
	caster.set("_player", player)
	caster.set("_staff", staff)

	# 选金色守护 → 建共享 jet 并开始
	caster.set("selected", "gold_body")
	caster.call("_ensure_jet")
	var gold_jet := caster.get("jet") as Node3D
	_check(gold_jet != null and gold_jet.name == "Spell_gold_body", "caster：金色守护视觉已创建")
	gold_jet.call("start_cast")
	var gmat := gold_jet.get("_film") as Material
	_check(int(gold_jet.get("_state")) != 0, "金盾：已开始汇聚")
	_check(player.has_meta("gold_guard"), "金盾：已打上 100% 抵挡标记")
	_check(meshes[0].material_overlay == gmat, "金盾：金膜已贴在角色网格上")

	# 切到流水治疗：旧 jet 不能被释放
	caster.set("selected", "water_heal")
	caster.call("_ensure_jet")
	var water_jet := caster.get("jet") as Node3D
	_check(is_instance_valid(gold_jet), "切术法：金盾视觉未被 queue_free")
	_check((caster.get("_cast_instances") as Array).has(gold_jet), "切术法：金盾视觉转入独立实例表")
	_check(water_jet != null and water_jet.name == "Spell_water_heal", "caster：流水治疗视觉已创建")
	water_jet.call("_warmup")
	water_jet.call("start_cast")
	var wmat := water_jet.get("_mat") as Material
	_check(meshes[0].material_overlay == gmat and gmat.next_pass == wmat,
			"共存：金膜在下、水膜在上串成一条链")
	_check(player.has_meta("gold_guard"), "共存：贴水膜不影响金盾抵挡标记")

	# 金盾推进到碎裂阶段
	var t := 0.0
	while t < 9.3 and int(gold_jet.get("_state")) != 3:
		gold_jet.call("_process", DT)
		t += DT
	_check(int(gold_jet.get("_state")) == 3, "金盾：约 9.3s 进入碎裂阶段")
	_check(not bool(gold_jet.call("is_casting")), "金盾：碎裂阶段 is_casting() = false")
	caster.call("_sweep_instances")
	_check(is_instance_valid(gold_jet), "碎裂阶段：_sweep_instances 未提前回收金盾")
	_check(is_instance_valid(water_jet), "碎裂阶段：水膜视觉仍在")
	_check(meshes[0].material_overlay == gmat and gmat.next_pass == wmat, "碎裂阶段：两层都还在")

	# 金盾碎完：只摘自己那层
	t = 0.0
	while t < 2.0 and int(gold_jet.get("_state")) != 0:
		gold_jet.call("_process", DT)
		t += DT
	_check(int(gold_jet.get("_state")) == 0, "金盾：碎裂结束回到 ST_OFF")
	_check(not player.has_meta("gold_guard"), "金盾：结束后清除抵挡标记")
	_check(meshes[0].material_overlay == wmat and wmat.next_pass == null,
			"金盾结束：水膜仍在且成为唯一一层")
	caster.call("_sweep_instances")
	_check(is_instance_valid(gold_jet), "金盾结束后仍由 _sweep 延迟释放（同帧断言只要求不崩）")

	# 水膜自然结束：overlay 精确还原（本用例原本没有 overlay → null）
	t = 0.0
	while t < 11.0 and int(water_jet.get("_state")) != 0:
		water_jet.call("_process", DT)
		t += DT
	_check(int(water_jet.get("_state")) == 0, "流水治疗：自然结束")
	_check(meshes[0].material_overlay == null, "水膜结束：overlay 还原为空")


# ---------------------------------------------------------------- ⑤ 隐身兼容
func _test_invisibility(root: Node3D, player: Node3D, staff: Node3D, meshes: Array[MeshInstance3D]) -> void:
	var caster := root.get_node("ProbeCaster")
	var water_jet := caster.get("jet") as Node3D
	# 重新放一次水膜（承上：water_jet 仍是当前 jet，状态已回 ST_OFF）
	water_jet.call("start_cast")
	var wmat := water_jet.get("_mat") as Material
	_check(meshes[0].material_overlay == wmat, "隐身用例：水膜已重新贴上")

	# 切到隐身：水膜还在生效 → 应转入实例表；隐身效果宿主挂在角色下
	caster.set("selected", "invisibility")
	caster.call("_ensure_jet")
	var inv_jet := caster.get("jet") as Node3D
	_check(is_instance_valid(water_jet), "切隐身：水膜视觉未被释放")
	_check((caster.get("_cast_instances") as Array).has(water_jet), "切隐身：水膜视觉转入实例表")
	inv_jet.call("start_cast")
	var eff := player.get_node_or_null("InvisibilityEffect")
	_check(eff != null and bool(eff.call("is_active")), "隐身：效果宿主已生效")

	# 淡入 0.5s → 半透明；同时水膜仍在 overlay 上
	for i in int(0.5 / DT):
		eff.call("_process", DT)
	_check(float(meshes[0].transparency) > 0.4, "隐身：网格已半透明（水膜与透明度共存）")
	_check(meshes[0].material_overlay == wmat, "隐身：透明度不影响 overlay 水膜")

	# 再切走：隐身的 jet 会被释放，但 60s 效果宿主必须还在
	caster.set("selected", "water_heal")
	caster.call("_ensure_jet")
	_check(inv_jet.is_queued_for_deletion(), "切走隐身：施法代理 jet 已释放")
	_check(bool(eff.call("is_active")), "切走隐身：60s 效果仍在生效（未被取消）")
	_check(meshes[0].material_overlay == wmat, "切走隐身：水膜层仍在")
	caster.call("_sweep_instances")
	_check(is_instance_valid(water_jet), "切走隐身：仍在生效的水膜未被 _sweep 回收")

	_finish()


# ---------------------------------------------------------------- 工具
func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if ok:
		print("  ✓ " + msg)
	else:
		_fails += 1
		print("  ✗ " + msg)


func _finish() -> void:
	print("==== 失败 %d / %d ====" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)

extends SceneTree
## 植被燃烧 自检：
##  · 材质接管 / 斑点扩大 burn 0->1 / 焦黑停留 / 灰化 ash -> 消失
##  · ★ 火星起点取自**模型真实顶点**（在网格包围盒内），不是凭空撒点
##  · 摆动参数（高度加权）已设置
##  · 火焰灼烧只点着**圈内**的植被

var _done := false
var _pass := 0
var _fail := 0
const DT := 1.0 / 60.0


func _ck(label: String, ok: bool, extra: String = "") -> void:
	if ok:
		_pass += 1
		print("  ✓ %s%s" % [label, ("  " + extra) if extra != "" else ""])
	else:
		_fail += 1
		print("  ✗ %s%s" % [label, ("  " + extra) if extra != "" else ""])


func _pump(node: Node, seconds: float) -> void:
	for i in int(seconds / DT):
		node.call("_process", DT)


func _process(_d: float) -> bool:
	if _done:
		return true
	_done = true
	print("=========== 植被燃烧 自检 ===========")

	# ---- 造一株"灌木"（放在原点侧前方 3 米）----
	var bush := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.9, 1.2, 0.9)
	bush.mesh = bm
	bush.position = Vector3(3.0, 0.6, 0.0)
	bush.add_to_group("burnable")
	get_root().add_child(bush)

	var burn: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(burn)
	_ck("burn_node 成功接管这株植被", bool(burn.call("burn_node", bush, 0.0)))
	# ★ 默认走**叠加**：保留原生材质（草的透明裁剪/自定义着色器都在），
	#   不接管外观 —— 接管会让草片变成不透明方块（观感=模型变大，用户实测反馈）
	_ck("默认用叠加方式挂燃烧材质（**不接管**原生外观）",
			bush.material_overlay != null and bush.material_override == null,
			"overlay=%s override=%s" % [str(bush.material_overlay != null), str(bush.material_override != null)])
	var mat := bush.material_overlay as ShaderMaterial
	_ck("燃烧材质已生效", mat != null and mat.shader != null)
	var ov: Variant = mat.get_shader_parameter("overlay_mode")
	_ck("着色器处于叠加模式（未烧处透明）", ov != null and bool(ov))
	_ck("斑点扩大参数 burn 从 0 开始", absf(float(mat.get_shader_parameter("burn"))) < 0.001)
	var p_sway: Variant = mat.get_shader_parameter("sway_amt")
	var p_hr: Variant = mat.get_shader_parameter("height_ref")
	var p_ph: Variant = mat.get_shader_parameter("phase")
	var v_sway: float = float(p_sway) if p_sway != null else -1.0
	var v_hr: float = float(p_hr) if p_hr != null else -1.0
	var v_ph: float = float(p_ph) if p_ph != null else -1.0
	_ck("已设置摆动参数（高度加权、每株错开）",
			v_sway > 0.0 and v_hr > 0.0 and absf(v_ph) > 0.0,
			"sway=%.3f height_ref=%.2f phase=%.2f" % [v_sway, v_hr, v_ph])

	# ---- ★ 火星起点必须落在模型表面上 ----
	var surf: PackedVector3Array = burn.get("_surface")
	var aabb := bush.mesh.get_aabb()
	var outside := 0
	for p in surf:
		# ★ 控制器现在（正确地）被摆到目标位置，所以 _surface 已经就是"目标局部坐标"，
		#   直接和网格 AABB 比较即可（旧断言按"控制器在原点"换算，已过时）
		var local := p
		var lo := aabb.position - Vector3(0.01, 0.01, 0.01)
		var hi := aabb.position + aabb.size + Vector3(0.01, 0.01, 0.01)
		if local.x < lo.x or local.x > hi.x or local.y < lo.y or local.y > hi.y \
				or local.z < lo.z or local.z > hi.z:
			outside += 1
	_ck("★ 火星起点取自**模型真实顶点**（全部落在网格包围盒内）",
			surf.size() >= 6 and outside == 0,
			"表面点 %d 个，越界 %d 个" % [surf.size(), outside])
	var sparks := burn.get("_sparks") as MultiMeshInstance3D
	_ck("火星已装配", sparks != null and sparks.multimesh.instance_count > 0,
			"数量 %s" % str(sparks.multimesh.instance_count if sparks != null else "无"))

	# ---- 时序：斑点扩大 -> 焦黑 -> 缩放消失 ----
	# ★ 时长从参数推导，不再写死（改 ash_time 时测试不会假失败）
	var bt: float = float(burn.get("burn_time"))
	var t_hold: float = float(burn.get("char_hold"))
	var t_ash: float = float(burn.get("ash_time"))
	_pump(burn, bt * 0.5)
	var pb: Variant = mat.get_shader_parameter("burn")
	var b_mid: float = float(pb) if pb != null else -1.0
	_ck("斑点随时间扩大（burn 递增）", b_mid > 0.2 and b_mid < 1.0, "burn=%.2f" % b_mid)
	_pump(burn, bt * 0.5 + 0.1)
	_ck("斑点扩大到全株（burn→1）", absf(float(mat.get_shader_parameter("burn")) - 1.0) < 0.01,
			"burn=%.2f" % float(mat.get_shader_parameter("burn")))
	_ck("全焦黑阶段 ash 仍为 0（先烧焦、后消失）",
			absf(float(mat.get_shader_parameter("ash"))) < 0.01)
	_pump(burn, t_hold + t_ash * 0.5 + 0.1)
	_ck("之后进入消失阶段（ash 递增）", float(mat.get_shader_parameter("ash")) > 0.3,
			"ash=%.2f" % float(mat.get_shader_parameter("ash")))
	_pump(burn, t_ash * 0.5 + 0.2)
	_ck("消失结束 -> 标记完成", bool(burn.call("is_done")),
			"t=%.2f / 需要 %.2f" % [float(burn.get("_t")), bt + t_hold + t_ash])
	_ck("★ 烧尽后模型消失", not bush.visible)
	_ck("材质已还原（这株被复用/重生时不会还带着焦黑）", bush.material_overlay == null)

	# ---- 与火焰灼烧的联动：只点着圈内植被 ----
	var spell: Node3D = (load("res://scripts/spells/flame_scorch.gd") as GDScript).new()
	get_root().add_child(spell)
	var inside := MeshInstance3D.new()
	var bm2 := BoxMesh.new()
	bm2.size = Vector3(0.5, 0.5, 0.5)
	inside.mesh = bm2
	inside.position = Vector3(1.0, 0.25, 0.0)
	inside.add_to_group("burnable")
	get_root().add_child(inside)
	var far := MeshInstance3D.new()
	far.mesh = bm2
	far.position = Vector3(40.0, 0.25, 0.0)
	far.add_to_group("burnable")
	get_root().add_child(far)
	spell.set("_center", Vector3.ZERO)
	spell.set("_radius", 6.0)
	var found: Array = spell.call("_find_vegetation")
	var has_inside := false
	var has_far := false
	for n in found:
		if n == inside:
			has_inside = true
		if n == far:
			has_far = true
	_ck("火焰灼烧会点着圈内的植被", has_inside)
	_ck("火焰灼烧**不会**点着圈外的植被", not has_far,
			"圈内 %d 株，圈外是否误选 %s" % [found.size(), str(has_far)])

	# ---- 组注册：scenes/草/*.tscn 与 simplegrasstextured 都要能被找到 ----
	var grass_scene := load("res://scenes/草/grass_bermuda_01_single_a.tscn") as PackedScene
	_ck("草场景存在", grass_scene != null)
	if grass_scene != null:
		var gi: Node = grass_scene.instantiate()
		get_root().add_child(gi)
		_ck("scenes/草 的草**已在 burnable 组**", gi.is_in_group("burnable"))
		gi.queue_free()
	# addon 的草丛：实例化 grass.gd（extends MultiMeshInstance3D），_ready 里应注册进组
	var grass_script := load("res://addons/simplegrasstextured/grass.gd")
	_ck("simplegrasstextured/grass.gd 可加载", grass_script != null)
	if grass_script != null:
		var gnode: Node = (grass_script as GDScript).new()
		_ck("simplegrass 草丛是 MultiMeshInstance3D（所以燃烧控制器必须支持它）",
				gnode is MultiMeshInstance3D)
		get_root().add_child(gnode)
		_ck("simplegrass 草丛**已在 burnable 组**", gnode.is_in_group("burnable"))
		gnode.queue_free()

	# ---- 燃烧控制器支持 MultiMesh：火星撒在**整片**草丛的表面 ----
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true            # ★ 必须在创建时打开（addon 已改成这样）
	mm.instance_count = 8
	var blade := BoxMesh.new()
	blade.size = Vector3(0.06, 0.5, 0.06)
	mm.mesh = blade
	var field := MultiMeshInstance3D.new()
	field.multimesh = mm
	# ★ 给真材质（addon 草着色器，其 include 里有逐实例燃烧的 uniform）
	var fmat2 := ShaderMaterial.new()
	fmat2.shader = load("res://addons/simplegrasstextured/shaders/grass.gdshader") as Shader
	mm.mesh.surface_set_material(0, fmat2)
	field.position = Vector3(2.0, 0.25, 0.0)
	for i in range(8):
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(float(i) * 0.8, 0.0, 0.0)))
	field.add_to_group("burnable")
	get_root().add_child(field)
	# ★ 默认**跳过**整片 MultiMesh（否则共享材质会把全图草一起烧黑）
	var burn_skip: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(burn_skip)
	# ★ 守护真正的回归：整片草**绝不能整节点叠加**（那会把全图草一起涂黑）。
	#   现在默认走"逐实例燃烧"，所以 overlay 必须为 null。
	var ok_skip := bool(burn_skip.call("burn_node", field, 0.0))
	_ck("★ 默认走**逐实例燃烧**、且**不整片叠加**（防全图一起烧）",
			ok_skip and field.material_overlay == null,
			"burn_multimesh=%s，圈内实例 %d 个，overlay=%s" % [str(burn_skip.get("burn_multimesh")),
					(burn_skip.get("_mm_burn") as Array).size(), str(field.material_overlay)])
	field.multimesh.set_instance_custom_data(0, Color(0, 0, 0, 0))
	var burn2: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	burn2.set("burn_multimesh", true)          # 显式打开逐实例燃烧
	get_root().add_child(burn2)
	_ck("显式允许时走**逐实例燃烧**（需要支持 INSTANCE_CUSTOM 的材质）",
			bool(burn2.call("burn_node", field, 0.0)) and (burn2.get("_mm_burn") as Array).size() > 0,
			"圈内实例 %d 个" % (burn2.get("_mm_burn") as Array).size())
	# ★ 守护这个坑：INSTANCE_CUSTOM 必须靠 use_custom_data 才能送进着色器
	# 单独造一个"没开 use_custom_data"的 MultiMesh 来测跳过路径
	var mm_off := MultiMesh.new()
	mm_off.transform_format = MultiMesh.TRANSFORM_3D
	mm_off.instance_count = 3
	mm_off.mesh = blade
	mm_off.mesh.surface_set_material(0, fmat2)
	var field_off := MultiMeshInstance3D.new()
	field_off.multimesh = mm_off
	field_off.position = Vector3(2.0, 0.25, 0.0)
	field_off.add_to_group("burnable")
	get_root().add_child(field_off)
	var b_off: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(b_off)
	b_off.set("burn_center", Vector3(2.0, 0.0, 0.0))
	b_off.set("burn_radius", 6.0)
	_ck("★ MultiMesh 没开 use_custom_data 时**优雅跳过**（不静默失败）",
			not mm_off.use_custom_data and not bool(b_off.call("burn_node", field_off, 0.0)),
			"use_custom_data=%s（运行时无法开启，必须在创建时开）" % str(mm_off.use_custom_data))
	# 打开后（模拟 addon 的创建方式）应当能正常走逐实例
	var mm2b := MultiMesh.new()
	mm2b.transform_format = MultiMesh.TRANSFORM_3D
	mm2b.use_custom_data = true          # ★ 创建时打开（addon 已改成这样）
	mm2b.instance_count = 4
	mm2b.mesh = blade
	var field2 := MultiMeshInstance3D.new()
	field2.multimesh = mm2b
	mm2b.mesh.surface_set_material(0, fmat2)
	field2.position = Vector3(2.0, 0.25, 0.0)
	field2.add_to_group("burnable")
	get_root().add_child(field2)
	var burn3b: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(burn3b)
	burn3b.set("burn_center", Vector3(2.0, 0.0, 0.0))
	burn3b.set("burn_radius", 6.0)
	_ck("★ 打开了 use_custom_data 的 MultiMesh 能正常逐实例燃烧",
			bool(burn3b.call("burn_node", field2, 0.0))
			and (burn3b.get("_mm_burn") as Array).size() > 0,
			"圈内实例 %d 个" % (burn3b.get("_mm_burn") as Array).size())
	var surf2: PackedVector3Array = burn2.get("_surface")
	var spread := 0.0
	var minx := 1e9
	var maxx := -1e9
	for p in surf2:
		minx = minf(minx, p.x)
		maxx = maxf(maxx, p.x)
	spread = maxx - minx
	print("    [诊断] _multimeshes=%d instance_count=%d visible=%d 实例7原点=%s" % [
			(burn2.get("_multimeshes") as Array).size(), mm.instance_count,
			mm.visible_instance_count, str(mm.get_instance_transform(7).origin)])
	print("    [诊断] 表面点 x 范围 %.3f ~ %.3f（字段位置 x=%.2f）" % [minx, maxx, field.global_position.x])
	# ★ 注意：**headless 下无法验证"跨实例撒点"**。MultiMesh.get_instance_transform() 读的是
	#   RenderingServer 的缓冲，而 headless 是 dummy 渲染器 -> 实例变换读回来恒为单位变换
	#   （实测：实例 7 的原点是 (0,0,0)）。所以这里只断言"控制器确实识别了 MultiMesh"
	#   以及表面点确实来自网格顶点；"是否撒在整片草丛上"必须实机确认。
	_ck("控制器识别出 MultiMesh 草丛（走实例×顶点采样分支）",
			(burn2.get("_multimeshes") as Array).size() == 1,
			"按实例采样的对象 %d 个" % (burn2.get("_multimeshes") as Array).size())
	_ck("表面点来自网格顶点（数量足够、不是兜底单点）", surf2.size() >= 6,
			"表面点 %d 个（headless 下实例变换恒为单位，跨度 %.2f 米不作判据）" % [surf2.size(), spread])
	# ---- 火星落点必须贴在目标身上（防止"火星被目标位置二次偏移"这类错）----
	var bush2 := MeshInstance3D.new()
	var bm3 := BoxMesh.new()
	bm3.size = Vector3(1.0, 1.0, 1.0)
	bush2.mesh = bm3
	bush2.position = Vector3(20.0, 0.5, 7.0)          # 远离原点，能暴露偏移问题
	bush2.add_to_group("burnable")
	get_root().add_child(bush2)
	var burn3: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(burn3)
	burn3.call("burn_node", bush2, 0.0)
	var surf3: PackedVector3Array = burn3.get("_surface")
	var far_from_target := 0
	var limit := bush2.global_position
	for p in surf3:
		var w: Vector3 = burn3.global_transform * p
		if absf(w.x - limit.x) > 1.2 or absf(w.y - limit.y) > 1.2 or absf(w.z - limit.z) > 1.2:
			far_from_target += 1
	_ck("★ 火星落点贴在目标身上（没有被目标位置二次偏移）", surf3.size() > 0 and far_from_target == 0,
			"样例 %d 个，偏离目标 >1.2m 的 %d 个" % [surf3.size(), far_from_target])
	# ---- 轮廓遮罩：能从材质里取到贴图就必须启用遮罩（否则烧出方块斑块）----
	var mk := MeshInstance3D.new()
	var bm4 := BoxMesh.new()
	bm4.size = Vector3(0.5, 0.5, 0.5)
	mk.mesh = bm4
	var smat := StandardMaterial3D.new()
	# ★ 必须设成"裁剪型"：默认是不透明材质，新逻辑会正确地**不做遮罩**（旧断言按老逻辑写的）
	smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	smat.albedo_texture = ImageTexture.create_from_image(img)
	mk.mesh.surface_set_material(0, smat)
	mk.position = Vector3(0.0, 0.25, 5.0)
	mk.add_to_group("burnable")
	get_root().add_child(mk)
	var burn4: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(burn4)
	burn4.call("burn_node", mk, 0.0)
	var m4 := mk.material_overlay as ShaderMaterial
	var um: Variant = m4.get_shader_parameter("use_mask") if m4 != null else null
	var mt: Variant = m4.get_shader_parameter("mask_tex") if m4 != null else null
	_ck("★ 取到原贴图时启用轮廓遮罩（避免方块斑块）", um != null and bool(um) and mt != null,
			"use_mask=%s mask_tex=%s" % [str(um), str(mt != null)])
	# ---- ShaderMaterial 取贴图：走 Shader 的 uniform 表（ShaderMaterial 上没有那个方法）----
	var sm2 := ShaderMaterial.new()
	var sh2 := load("res://assets/shaders/fire_flame.gdshader") as Shader
	sm2.shader = sh2
	var img2 := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img2.fill(Color(1, 1, 1, 1))
	var tex2 := ImageTexture.create_from_image(img2)
	sm2.set_shader_parameter("fire_tex", tex2)
	var found2: Texture2D = burn4.call("_texture_from_material", sm2)
	_ck("★ 能从自定义 ShaderMaterial 里取出贴图（用 Shader 的 uniform 表）",
			found2 == tex2, "取到 %s" % str(found2))
	var ulist: Array = sh2.get_shader_uniform_list()
	_ck("Shader 的 uniform 表可用（方法是 get_shader_uniform_list）", ulist.size() > 0,
			"%d 个 uniform" % ulist.size())
	# ---- 材质透明度必须被考虑：不同 transparency 得到不同的遮罩/裁剪策略 ----
	var mk2 := MeshInstance3D.new()
	var m2b := BoxMesh.new()
	m2b.size = Vector3(0.4, 0.4, 0.4)
	mk2.mesh = m2b
	var alpha_mat := StandardMaterial3D.new()
	alpha_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA      # Alpha 混合（软边）
	alpha_mat.albedo_texture = tex2
	mk2.mesh.surface_set_material(0, alpha_mat)
	mk2.position = Vector3(6.0, 0.2, 0.0)
	mk2.add_to_group("burnable")
	get_root().add_child(mk2)
	var b_alpha: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(b_alpha)
	b_alpha.call("burn_node", mk2, 0.0)
	var am := mk2.material_overlay as ShaderMaterial
	var se: Variant = am.get_shader_parameter("scissor_enabled")
	_ck("★ Alpha 混合材质**不硬裁**（软边不会被剪刀切）", se != null and not bool(se),
			"scissor_enabled=%s" % str(se))

	var mk3 := MeshInstance3D.new()
	var m3b := BoxMesh.new()
	m3b.size = Vector3(0.4, 0.4, 0.4)
	mk3.mesh = m3b
	var scis_mat := StandardMaterial3D.new()
	scis_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	scis_mat.alpha_scissor_threshold = 0.62
	scis_mat.albedo_texture = tex2
	mk3.mesh.surface_set_material(0, scis_mat)
	mk3.position = Vector3(7.0, 0.2, 0.0)
	mk3.add_to_group("burnable")
	get_root().add_child(mk3)
	var b_scis: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(b_scis)
	b_scis.call("burn_node", mk3, 0.0)
	var scm := mk3.material_overlay as ShaderMaterial
	var se2: Variant = scm.get_shader_parameter("scissor_enabled")
	var sc2: Variant = scm.get_shader_parameter("scissor")
	_ck("★ 裁剪型材质用**它自己的阈值**（不是我写死的 0.35）",
			se2 != null and bool(se2) and sc2 != null and absf(float(sc2) - 0.62) < 0.001,
			"scissor_enabled=%s scissor=%s（材质设的是 0.62）" % [str(se2), str(sc2)])

	var mk4 := MeshInstance3D.new()
	var m4b := BoxMesh.new()
	m4b.size = Vector3(0.4, 0.4, 0.4)
	mk4.mesh = m4b
	var opaque_mat := StandardMaterial3D.new()
	opaque_mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED  # 不透明（树干/石头）
	opaque_mat.albedo_texture = tex2
	mk4.mesh.surface_set_material(0, opaque_mat)
	mk4.position = Vector3(8.0, 0.2, 0.0)
	mk4.add_to_group("burnable")
	get_root().add_child(mk4)
	var b_op: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(b_op)
	b_op.call("burn_node", mk4, 0.0)
	var om := mk4.material_overlay as ShaderMaterial
	var um2: Variant = om.get_shader_parameter("use_mask")
	_ck("★ 不透明材质**不做贴图遮罩**（整块网格就是轮廓）", um2 != null and not bool(um2),
			"use_mask=%s" % str(um2))
	# ---- 安全阀：透明材质但拿不到贴图 -> **不画**（否则整张卡片变半透明色块）----
	var mk5 := MeshInstance3D.new()
	var m5b := BoxMesh.new()
	m5b.size = Vector3(0.5, 0.5, 0.5)
	mk5.mesh = m5b
	var notex := StandardMaterial3D.new()
	notex.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA   # 透明材质
	notex.albedo_texture = null                              # 但没有任何贴图
	mk5.mesh.surface_set_material(0, notex)
	mk5.position = Vector3(9.0, 0.25, 0.0)
	mk5.add_to_group("burnable")
	get_root().add_child(mk5)
	var b_nt: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(b_nt)
	b_nt.call("burn_node", mk5, 0.0)
	_ck("★ 拿不到轮廓的透明材质**不画形体叠加**（避免整块色块）",
			mk5.material_overlay == null, "overlay=%s" % str(mk5.material_overlay))
	_ck("★ 这种情况仍然会放火星", b_nt.get("_sparks") != null)
	# ---- ★ 用**真实草场景 + 真实材质**验证 ----
	# scenes/草 的材质是 ShaderMaterial(grass_wind.gdshader)：
	#   albedo_tex = ..._diff_4k.jpg（JPG 没有 alpha）、alpha_tex = ..._alpha_4k.png
	#   alpha_scissor = 0.5，形状取 `texture(alpha_tex, UV).r`（**红通道**）
	# 现在它也走"材质内建 burn"（因为要支持 scale 消失，叠加层动不了原几何体）。
	var gs := load("res://scenes/草/grass_bermuda_01_single_a.tscn") as PackedScene
	if gs != null:
		var gnode := gs.instantiate() as Node3D
		get_root().add_child(gnode)
		# 草场景的根是 Node3D，材质挂在它的 MeshInstance3D 子节点上
		var cmesh: MeshInstance3D = null
		for ch in gnode.get_children():
			if ch is MeshInstance3D:
				cmesh = ch
				break
		var shared_mat: ShaderMaterial = null
		if cmesh != null and cmesh.mesh != null and cmesh.mesh.get_surface_count() > 0:
			shared_mat = cmesh.mesh.surface_get_material(0) as ShaderMaterial
		var gb2: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
		get_root().add_child(gb2)
		gb2.call("burn_node", gnode, 0.0)
		var dup_mat := (cmesh.get_surface_override_material(0) if cmesh != null else null) as ShaderMaterial
		_ck("★ bermuda 草走**材质内建 burn**（要 scale 消失，叠加层做不到）",
				cmesh != null and cmesh.material_overlay == null and dup_mat != null
				and dup_mat.shader != null and dup_mat.shader.resource_path.contains("grass_wind"),
				"overlay=%s 副本着色器=%s" % [str(cmesh.material_overlay if cmesh != null else null),
						dup_mat.shader.resource_path if dup_mat != null and dup_mat.shader != null else "无"])
		if dup_mat != null:
			_ck("★ 内置 burn 的材质副本带 burn/ash（scale 消失由 ash 驱动）",
					dup_mat.get_shader_parameter("burn") != null
					and dup_mat.get_shader_parameter("ash") != null)
		var shared_burn: Variant = shared_mat.get_shader_parameter("burn") if shared_mat != null else null
		_ck("★ **共享材质未被污染**（否则所有 bermuda 草一起烧）",
				shared_mat != null and (shared_burn == null or float(shared_burn) < 0.001),
				"共享材质 burn=%s（null = 从未被写过，即未被污染）" % str(shared_burn))
		_ck("不接管原外观（material_override 为空 -> 风/倒伏照旧）",
				cmesh != null and cmesh.material_override == null)
		# 叠加层那条路仍在（给"没有 burn 参数的材质"用）：通道解析必须正确
		# （grass_wind.gdshader 是 texture(alpha_tex, UV).r -> 红通道，取 .a 会让遮罩失效）
		_ck("★ 遮罩通道解析：grass_wind 用红通道 .r（不是 .a）",
				shared_mat != null and int(gb2.call("_mask_channel_of", shared_mat, "alpha_tex")) == 0,
				"channel=%s" % str(gb2.call("_mask_channel_of", shared_mat, "alpha_tex") if shared_mat != null else "无"))
	# ---- ★ 内建 burn 路线：不透明植被走这条路（不叠层、不碰透明度问题）----
	var veg_sh := load("res://assets/shaders/vegetation_wind.gdshader") as Shader
	_ck("vegetation_wind 着色器带 burn 参数（本项目新增）", veg_sh != null and (
			func() -> bool:
				for u in veg_sh.get_shader_uniform_list():
					if String(u.get("name", "")) == "burn":
						return true
				return false).call())
	var shared := ShaderMaterial.new()
	shared.shader = veg_sh
	shared.set_shader_parameter("burn", 0.0)
	var veg := MeshInstance3D.new()
	var vmesh := BoxMesh.new()
	vmesh.size = Vector3(0.3, 1.0, 0.3)
	veg.mesh = vmesh
	veg.mesh.surface_set_material(0, shared)
	veg.position = Vector3(0.0, 0.5, 9.0)
	veg.add_to_group("burnable")
	get_root().add_child(veg)
	var bveg: Node3D = (load("res://scripts/vfx/foliage_burn.gd") as GDScript).new()
	get_root().add_child(bveg)
	bveg.call("burn_node", veg, 0.0)
	var smats: Array = bveg.get("_shader_mats")
	_ck("★ 走**材质内建 burn** 路线（复制材质，而不是叠一层）",
			smats.size() > 0 and veg.material_overlay == null,
			"材质副本 %d 份；overlay=%s" % [smats.size(), str(veg.material_overlay)])
	if smats.size() > 0:
		_pump(bveg, 1.2)
		var bdup: Variant = (smats[0] as ShaderMaterial).get_shader_parameter("burn")
		var bshare: Variant = shared.get_shader_parameter("burn")
		_ck("副本的 burn 在推进", bdup != null and float(bdup) > 0.2, "burn=%.2f" % float(bdup))
		_ck("★ **共享材质未被污染**（否则所有同类植被会一起烧）",
				bshare != null and float(bshare) < 0.001, "共享材质 burn=%s" % str(bshare))
		var ph: Variant = (smats[0] as ShaderMaterial).get_shader_parameter("burn_phase")
		_ck("每株 burn_phase 独立（斑点位置不雷同）", ph != null)
	# ---- ★ 焦黑曲线必须随 b 单调增加（着色器里写反过一次："变黑后又变绿"）----
	# 这里复现 grass.gdshaderinc 里的同一公式做逻辑校验（shader 本身没法在 headless 跑）
	var frac := []
	for bv in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var cnt := 0
		for k in range(1000):
			var bn := float(k) / 1000.0
			var amt := 1.0 - smoothstep(bv - 0.02, bv + 0.02, bn)
			if amt > 0.5:
				cnt += 1
		frac.append(float(cnt) / 1000.0)
	var mono := true
	for i in range(1, frac.size()):
		if frac[i] < frac[i - 1] - 0.001:
			mono = false
	_ck("★ 焦黑面积随 burn **单调增加**（b=0 全绿 -> b=1 全黑）",
			mono and frac[0] < 0.05 and frac[frac.size() - 1] > 0.95,
			"b=0 -> %.2f，b=0.5 -> %.2f，b=1 -> %.2f（焦黑占比）" % [frac[0], frac[2], frac[4]])
	print("通过 %d  |  失败 %d" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)
	return true

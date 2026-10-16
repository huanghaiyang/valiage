extends SceneTree
## 一次性工具：生成插件自带的预览场景 addons/butterfly_swarm/butterfly_swarm_demo.tscn。
## 场景内容：地面 + 太阳 + 环境 + 几丛花（butterfly_target 分组）+ 一个配好 10 只蝴蝶的 ButterflySwarm。
## 用法：
##   & 'D:\godot\...console.exe' --headless --path 'D:\sgames\CozyVale' \
##       --script 'res://addons/butterfly_swarm/tools/make_demo_scene.gd'
## 用途：① 用户不用碰 main.tscn 就能看效果 ② 团队/CI 用它做视觉验收的固定靶子
##       （.runtime/bfly_demo_shot.gd 会直接跑它并截图）。

const BFLY_SWARM := preload("res://addons/butterfly_swarm/butterfly_swarm.gd")
const BFLY_IO := preload("res://addons/butterfly_swarm/butterfly_io.gd")
const OUT := "res://addons/butterfly_swarm/butterfly_swarm_demo.tscn"


func _init() -> void:
	var root := Node3D.new()
	root.name = "ButterflySwarmDemo"

	# ---- 环境：暖色天空 + 淡淡环境光（与游戏里卡通风格一致）----
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var mat := ProceduralSkyMaterial.new()
	mat.sky_top_color = Color(0.35, 0.55, 0.92)
	mat.sky_horizon_color = Color(0.86, 0.90, 0.86)
	mat.ground_bottom_color = Color(0.30, 0.38, 0.24)
	mat.ground_horizon_color = Color(0.70, 0.74, 0.62)
	sky.sky_material = mat
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	root.add_child(we)

	# ---- 太阳 ----
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-42, 34, 0)
	sun.light_energy = 1.25
	sun.shadow_enabled = true
	root.add_child(sun)

	# ---- 地面（40×40 的平面）----
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.52, 0.26)
	gm.roughness = 1.0
	ground.material_override = gm
	root.add_child(ground)

	# ---- 花丛：用 MultiMesh 摆 26 个小球当"蜜源"（butterfly_target 分组）----
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261016
	var flower_holder := Node3D.new()
	flower_holder.name = "Flowers"
	root.add_child(flower_holder)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "FlowerHeads"
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var sphere := SphereMesh.new()
	sphere.radius = 0.13
	sphere.height = 0.26
	sphere.radial_segments = 10
	sphere.rings = 6
	mm.mesh = sphere
	mm.instance_count = 26
	mmi.multimesh = mm
	mmi.add_to_group("butterfly_target")
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(1.0, 0.62, 0.30)
	fm.emission_enabled = true
	fm.emission = Color(0.45, 0.22, 0.06)
	fm.emission_energy_multiplier = 0.6
	fm.roughness = 0.85
	mmi.material_override = fm
	flower_holder.add_child(mmi)
	var spots: Array = []
	for i in range(26):
		# 撒在半径 1.2~4.2 的环带里，高度 0.15~0.7
		var a := rng.randf_range(0.0, TAU)
		var r := rng.randf_range(1.2, 4.2)
		var pos := Vector3(cos(a) * r, rng.randf_range(0.15, 0.7), sin(a) * r)
		var t := Transform3D(Basis().scaled(Vector3.ONE * rng.randf_range(0.7, 1.5)), pos)
		mm.set_instance_transform(i, t)
		spots.append(pos)
	# 给花加"茎"（细圆柱），看起来像花丛而不是漂浮的球
	var stem := MeshInstance3D.new()
	stem.name = "Stems"
	var sm_im := ImmediateMesh.new()
	sm_im.surface_begin(Mesh.PRIMITIVE_LINES)
	for p in spots:
		var v: Vector3 = p
		sm_im.surface_set_color(Color(0.25, 0.5, 0.2))
		sm_im.surface_add_vertex(Vector3(v.x, 0.0, v.z))
		sm_im.surface_set_color(Color(0.35, 0.6, 0.25))
		sm_im.surface_add_vertex(v)
	sm_im.surface_end()
	stem.mesh = sm_im
	var stem_m := StandardMaterial3D.new()
	stem_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	stem_m.vertex_color_use_as_albedo = true
	stem.material_override = stem_m
	flower_holder.add_child(stem)

	# ---- 蝴蝶群 ----
	var swarm := BFLY_SWARM.new()
	swarm.name = "ButterflySwarm"
	swarm.set("count", 10)
	swarm.set("region_size", Vector3(7.0, 2.6, 7.0))
	swarm.set("region_offset", Vector3(0, 1.5, 0))
	swarm.set("seed_value", 20261016)
	swarm.set("wind_influence", 1.3)
	swarm.set("debug_draw_region", false)
	# ★ 预览场景把蝴蝶放大到 0.45 m：真蝴蝶（0.12 m）在这个取景下太小，
	#   看不清"折翼 + 厚度 + 身体"的体积细节。做效果展示时放大是常规做法。
	swarm.set("size_m", 0.45)
	var paths := BFLY_IO.list_butterfly_paths()
	var textures: Array = []
	for i in range(mini(6, paths.size())):
		var t := load(String(paths[i])) as Texture2D
		if t != null:
			textures.append(t)
	# ★ 走公开方法：sprites 是 Array[Texture2D]，不能直接赋无类型 Array
	swarm.call("set_sprite_textures", textures)
	root.add_child(swarm)
	# ★ 只**验证**能在编辑器里建出来，随后把蝴蝶子节点清掉再存场景。
	#   为什么清掉：这些 Butterfly 是运行时生成的临时节点，`_ready()` 每次加载都会重建，
	#   把它们写进 .tscn 只会让场景文件白白变大、还会被 `_build()` 的清理逻辑扫掉。
	swarm.call("rebuild")
	print("[demo] 编辑器内验证：live=", swarm.call("live_count"), "（随后从场景里移除，运行时会重建）")
	for c in swarm.get_children():
		swarm.remove_child(c)
		c.free()

	# ---- 相机：斜后方 8 米，看向花丛中心 ----
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	cam.position = Vector3(5.6, 3.0, 6.4)
	cam.rotation_degrees = Vector3(-16, 41, 0)
	cam.fov = 55.0
	cam.current = true
	root.add_child(cam)

	# ---- 打包保存 ----
	# ★★ 必须给每个子节点设 owner，否则 `PackedScene.pack()` **一个子节点都不序列化** ★★
	#   实测教训：漏了这一步，保存出来的 .tscn 里只有根节点一行，加载出来是个空场景，
	#   而 ResourceSaver.save() 依旧返回 OK —— 完全静默。
	_assign_owner_recursive(root, root)
	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		printerr("pack 失败 err=", err)
		root.free()
		quit(1)
		return
	var serr := ResourceSaver.save(packed, OUT)
	print("保存 ", OUT, " -> ", serr, " ｜ 花 ", spots.size(), " ｜ 蝴蝶在运行时由 _ready() 生成")
	root.free()
	quit(0 if serr == OK else 1)


## 递归给所有子孙节点设 owner = scene_root（`PackedScene.pack()` 的硬性要求）。
## 说明：`owner` 只对"保存"有意义；不设的话节点在保存时被跳过（且不报错）。
func _assign_owner_recursive(n: Node, scene_root: Node) -> void:
	for c in n.get_children():
		c.owner = scene_root
		_assign_owner_recursive(c, scene_root)

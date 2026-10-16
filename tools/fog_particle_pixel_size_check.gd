extends Node
## ============================================================================
## fog_particle_pixel_size_check —— 粒子"最小/最大屏幕像素"的**像素级**验证
## ============================================================================
## 为什么这么测：粒子在真场景里做 A/B 不稳（草/雾/时序、emitting 被每帧同步覆盖、
## 8000 颗要 11 秒才长满）。而"按屏幕像素收放四边形"这件事本质是**顶点着色器的几何计算**，
## 与是不是粒子无关 —— 于是这里用**同一个着色器**画一个普通 QuadMesh：
##   固定 SubViewport(256×256) + 固定相机距离 + 黑底白雾团
##   ⇒ 直接数"点亮了多少像素"，就能精确测出：
##     ① 远处极小的粒子（世界尺寸 0.1m @ 40m ⇒ 自然只有 ~0.5 像素）：
##        min_pixel_size = 0 → 几乎不可见；= 8 → 应当出现约 8 像素的小团
##     ② 贴近相机的大粒子（13m @ 4m ⇒ 铺满全屏）：
##        max_pixel_size = 0 → 铺满；= 32 → 应当缩到约 32 像素
## ⚠️ 当前状态：**未跑通**（诚实记录，别当它验证通过）
##   · headless 下 `RenderingServer.frame_post_draw` 不触发 ⇒ 卡死，必须带显卡跑；
##   · 带显卡跑时，本项目的 autoload（HUD CanvasLayer、game.gd）会抢占视口/场景，
##     裸工具场景里的相机+网格渲染不出任何像素（量到的只有 HUD 的 13522 个亮点，
##     已用"藏掉网格"的基线减掉；把 root 下其它 CanvasLayer/相机让开之后基线归 0、网格仍不渲染）。
##   ⇒ 要真正做像素级验证，得放进**一个干净的专用场景**（或直接挂到真实主场景里）再测。
## 用法：godot --path <项目> res://tools/fog_particle_pixel_size_check.tscn（需要显卡）
## ============================================================================

const VIEW := 256

var _pass := 0
var _fail := 0
var camera: Camera3D
var mesh_node: MeshInstance3D
var material: ShaderMaterial
var _shot_index := 0


func _ready() -> void:
	await _run()
	print("通过 %d ｜ 失败 %d" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ck(what: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %-44s %s" % ["OK" if ok else "FAIL", what, detail])


func _run() -> void:
	print("=========== 粒子屏幕像素收放 · 像素级验证 ===========")
	# 黑底（数"点亮了多少像素"用）
	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0, 0, 0)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0, 0, 0)
	env.environment = environment
	add_child(env)

	# ★ 本项目的 autoload 会建 HUD（CanvasLayer）并可能自带相机 ⇒ 先把它们让开，
	#   否则量到的是它们（我前面把 HUD 的 13522 像素当成了四边形）。
	for child in get_tree().root.get_children():
		if child is CanvasLayer:
			(child as CanvasLayer).visible = false
		if child is Camera3D:
			(child as Camera3D).current = false
	camera = Camera3D.new()
	camera.fov = 60.0
	add_child(camera)
	camera.make_current()      # ★ 必须在进树之后：进树前设 current 不生效（3D 全黑就是这么来的）

	mesh_node = MeshInstance3D.new()
	# ★ 必须给顶点色：粒子绘制着色器里 `ALPHA = … × COLOR.a`，
	#   而普通网格没有 ARRAY_COLOR ⇒ COLOR.a = 0 ⇒ 整片全透明（我第一版就是这么测出全 0 的）
	mesh_node.mesh = _unit_quad_with_color()
	material = ShaderMaterial.new()
	material.shader = load("res://assets/shaders/fog_mist_particle_draw.gdshader")
	# 单位不透明度 + 不软化：这样"点亮像素数"≈四边形覆盖的像素数
	material.set_shader_parameter("strength", 1.0)
	material.set_shader_parameter("softness", 0.0)
	material.set_shader_parameter("mist_color", Color(1, 1, 1))
	material.set_shader_parameter("viewport_size_px",
			Vector2(get_viewport().get_visible_rect().size))
	mesh_node.material_override = material
	add_child(mesh_node)

	# ---- ① 远处极小粒子：0.1m @ 40m ----
	_place(Vector3(0, 0, 40.0), 0.1)
	material.set_shader_parameter("min_pixel_size", 0.0)
	material.set_shader_parameter("max_pixel_size", 0.0)
	var tiny_off := await _lit_pixels()
	material.set_shader_parameter("min_pixel_size", 8.0)
	var tiny_on := await _lit_pixels()
	print("  ① 远处 0.1m @40m ：min=0 → %d 像素 ｜ min=8 → %d 像素" % [tiny_off, tiny_on])
	_ck("① 最小像素能把亚像素粒子撑出来", tiny_on > tiny_off + 20,
			"%d → %d 像素（%.1f 倍）" % [tiny_off, tiny_on,
			float(tiny_on) / maxf(float(tiny_off), 1.0)])

	# ---- ② 贴近相机的大粒子：13m @ 4m（铺满）----
	_place(Vector3(0, 0, 4.0), 13.0)
	material.set_shader_parameter("min_pixel_size", 0.0)
	material.set_shader_parameter("max_pixel_size", 0.0)
	var big_off := await _lit_pixels()
	material.set_shader_parameter("max_pixel_size", 34.0)
	var big_on := await _lit_pixels()
	print("  ② 贴近 13m @4m   ：max=0 → %d 像素 ｜ max=34 → %d 像素" % [big_off, big_on])
	_ck("② 最大像素能把糊屏的大团缩下来", big_off > 30000 and big_on > 0 and big_on < 4000,
			"%d → %d 像素" % [big_off, big_on])

	# ---- ③ 关掉两个开关 = 旧行为（不做任何收放）----
	_place(Vector3(0, 0, 8.0), 1.0)
	material.set_shader_parameter("min_pixel_size", 0.0)
	material.set_shader_parameter("max_pixel_size", 0.0)
	var natural := await _lit_pixels()
	material.set_shader_parameter("min_pixel_size", 0.5)
	material.set_shader_parameter("max_pixel_size", 500.0)
	var generous := await _lit_pixels()
	_ck("③ 量级合适时两个开关都不该改变它（旧行为不变）",
			absi(natural - generous) <= 2, "%d → %d 像素" % [natural, generous])


func _place(pos: Vector3, quad_size: float) -> void:
	camera.position = Vector3(0, 0, 0)
	camera.look_at(pos, Vector3.UP)
	mesh_node.position = pos
	# 单位四边形（顶点 ±0.5）+ 节点缩放 = 世界尺寸
	mesh_node.scale = Vector3(quad_size, quad_size, 1.0)


## 顶点 ±0.5 的单位四边形，带 UV 与**白色顶点色**（着色器要用 COLOR.a）
func _unit_quad_with_color() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)
	var verts := [Vector3(-0.5, -0.5, 0.0), Vector3(0.5, -0.5, 0.0),
			Vector3(-0.5, 0.5, 0.0), Vector3(0.5, 0.5, 0.0)]
	var uvs := [Vector2(0, 1), Vector2(1, 1), Vector2(0, 0), Vector2(1, 0)]
	for i in range(4):
		st.set_color(Color(1, 1, 1, 1))
		st.set_uv(uvs[i])
		st.add_vertex(verts[i])
	return st.commit()


var _baseline := -1

## 数"点亮了多少像素"（亮度 > 12/255 记为点亮），并**减掉 HUD 基线**：
## 本项目 HUD 是 autoload，任何场景都在画（第一版就是这么把 HUD 的 13522 像素当成"四边形"的）。
func _lit_pixels() -> int:
	camera.make_current()          # 每次测量前再抢一次（防止 autoload 中途换相机）
	for i in range(4):
		await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		return -1
	DirAccess.make_dir_recursive_absolute("D:/sgames/CozyVale/.tmp_pps")
	image.save_png("D:/sgames/CozyVale/.tmp_pps/lit_%03d.png" % _shot_index)
	_shot_index += 1
	var data := image.get_data()
	var lit := 0
	for k in range(0, data.size() - 3, 4):
		if data[k] > 12 or data[k + 1] > 12 or data[k + 2] > 12:
			lit += 1
	if _baseline < 0:
		# 第一次测量：先量"藏掉网格"的基线（= HUD 等与网格无关的亮点）
		mesh_node.visible = false
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var base_image := get_viewport().get_texture().get_image()
		mesh_node.visible = true
		var base := 0
		if base_image != null:
			var bdata := base_image.get_data()
			for k in range(0, bdata.size() - 3, 4):
				if bdata[k] > 12 or bdata[k + 1] > 12 or bdata[k + 2] > 12:
					base += 1
		_baseline = base
		print("  （基线：与四边形无关的亮点 %d 个 —— 主要是 HUD，已从下面所有测量里减掉）" % base)
	return maxi(lit - _baseline, 0)

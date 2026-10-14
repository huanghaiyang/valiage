extends Node
## ============================================================================
## fog_field_verify.gd —— 雾气场**端到端**自检（真 GPU、真 SubViewport 链路）
## ============================================================================
## 运行方式（编辑器里跑最方便）：
##   编辑器打开 tools/fog_field_verify.tscn -> F6，或 MCP project_run(custom, 该场景)
## 命令行等价物（需要能执行 Godot 可执行文件的终端）：
##   <Godot> --path <项目> --scene res://tools/fog_field_verify.tscn   （普通窗口，别加 --headless）
## 退出码 0 = 全通过，1 = 有失败。
##
## 【这套自检在守什么】CPU 参考实现（tests/test_fog_ns_reference.gd）验证的是**数值格式**；
##   这里验证的是**GPU 装配真的按预期工作**，两者不能互相替代：
##     ① 通道链建对了没有（数量、顺序、纹理都非空）
##     ② 通道之间真的"后一趟看到本帧前一趟的结果"（顺序错位会让整场变成一堆噪声）
##     ③ 浓度场确实被写出来了（不是全 0 的黑图）
##     ④ 风真的把雾吹走了（半拉格朗日 + 单位换算在 GPU 上同样正确）
##     ⑤ 投影真的除掉了散度：对同一帧的"投影前/投影后"速度场做 A/B 对照
##        —— 这是"解的是 NS 而不是随手一个平流"的硬证据
##     ⑥ 截图存盘，人工可核对观感（体积雾 + 粒子）
##
## 【为什么每步都要 await 若干帧】SubViewport 是逐帧渲染的，读回来的永远是**上一帧**
##   的结果；不等帧就断言会读到空图（get_image() 返回 null 或全 0）。
## ============================================================================

const FOG_FIELD_SCRIPT := preload("res://scripts/fx/fog_field.gd")
const BRUSH_FIELD_SCRIPT := preload("res://scripts/fx/fog_brush_field.gd")

const DOMAIN := Vector2(60.0, 60.0)
const RESOLUTION := 64
const JACOBI_PASSES := 6
const SHOT_PATH := "res://screenshots/fog_field.png"

var _pass := 0
var _fail := 0
var _lines: Array[String] = []
var _field: FogField
var _camera: Camera3D


func _ready() -> void:
	print("=========== 雾气场端到端自检 ===========")
	_build_world()
	await _run_checks()
	_report_and_quit()


# =========================================================
# 搭一个最小的可观察世界（地面 + 相机 + 雾场）
# =========================================================

func _build_world() -> void:
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200.0, 200.0)
	ground.mesh = plane
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color(0.35, 0.42, 0.30)
	ground.material_override = ground_material
	add_child(ground)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.light_energy = 1.1
	add_child(sun)

	_camera = Camera3D.new()
	_camera.position = Vector3(0.0, 9.0, 46.0)
	_camera.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
	_camera.far = 400.0
	add_child(_camera)
	_camera.current = true

	_field = FOG_FIELD_SCRIPT.new() as FogField
	_field.name = "FogField"
	_field.domain_size = DOMAIN
	_field.box_height = 12.0
	_field.resolution = RESOLUTION
	_field.jacobi_passes = JACOBI_PASSES
	_field.auto_weather = false
	_field.quality_follows_project = false
	_field.particle_count = 200
	_field.mist_color_lit = Color(0.88, 0.91, 0.96)
	_field.mist_color_shadow = Color(0.66, 0.72, 0.82)
	add_child(_field)
	# 刷一片底雾（这样即便模拟场还没长起来，也能看出体积雾在哪儿）：
	# 用画笔模块的公开 API，顺便验证"画笔 -> 底图 -> 求解器"这条链路。
	var painted := BRUSH_FIELD_SCRIPT.new() as FogBrushField
	painted.grid_size = Vector2i(48, 48)
	painted.ensure_data()
	BRUSH_FIELD_SCRIPT.apply_stamp(painted, Vector2(24.0, 24.0), 12.0, 0.9, 0.4, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	_field.set_brush_field(painted)


# =========================================================
# 检查项
# =========================================================

func _run_checks() -> void:
	await _wait_frames(6)

	# ① 通道链
	var solver: FogNsSolver = _field.solver
	_ck("求解器已建立", solver != null)
	if solver == null:
		return
	var expected_passes := 7 + JACOBI_PASSES
	_ck("通道数量 = 7 + 压力迭代趟数", solver.pass_count() == expected_passes,
			"实际 %d（期望 %d）" % [solver.pass_count(), expected_passes])
	_ck("通道顺序符合链条设计",
			str(solver.pass_names()[0]) == "advect_velocity"
			and str(solver.pass_names()[2]) == "vorticity"
			and str(solver.pass_names()[solver.pass_count() - 1]) == "composite",
			str(solver.pass_names()))
	_ck("速度场纹理非空", _field.velocity_texture() != null)
	_ck("浓度场纹理非空", _field.density_texture() != null)
	var volume: MeshInstance3D = _field.volume_node()
	_ck("体积雾网格已建立且尺寸匹配域",
			volume != null and volume.mesh is BoxMesh
			and (volume.mesh as BoxMesh).size.x > DOMAIN.x - 0.01,
			"size=%s" % str((volume.mesh as BoxMesh).size) if volume != null else "无")
	var particles: GPUParticles3D = _field.particles_node()
	_ck("雾粒子节点已建立且正在发射",
			particles != null and particles.amount > 0 and particles.emitting,
			"amount=%d" % particles.amount if particles != null else "无")

	# ② 步进计数（SubViewport 真的在跑）
	var steps_before := solver.steps_done
	await _wait_frames(5)
	_ck("求解器每帧在推进", solver.steps_done > steps_before,
			"%d -> %d" % [steps_before, solver.steps_done])

	# ③ 浓度场被写出来了
	var density_image := solver.read_density_image()
	_ck("浓度场能回读（GPU 链路通）", density_image != null,
			"null" if density_image == null else "%dx%d" % [density_image.get_width(), density_image.get_height()])
	if density_image == null:
		return
	var mean_density := FogNsSolver.mean_from_image(density_image)
	_ck("浓度场不是全黑（底图链路生效）", mean_density > 0.002,
			"平均浓度 %.5f" % mean_density)

	# ④ 风把雾吹走：先在一侧灌一团，再吹 +X，看重心是否右移
	# ★ 必须先把画笔底图摘掉：底图松弛（base_relax）会把浓度拉回刷出来的形状，
	#   重心因此几乎不动（实测不加这一步时只动 0.004）—— 那是"锚定"在起作用，
	#   不是风没生效。这里要测的是纯输运。
	_field.set_brush_field(null)
	if solver != null:
		solver.base_relax = 0.0
		solver.refresh_materials()
	_field.set_fog_opacity(1.4)
	_field.set_wind_mps(Vector2(0.0, 0.0))
	var origin := _field.global_position
	_field.add_source(origin + Vector3(-18.0, 2.0, 0.0), 9.0, 3.0)
	await _wait_frames(3)
	var centroid_before := FogNsSolver.density_centroid_x_from_image(solver.read_density_image())
	_field.set_wind_mps(Vector2(9.0, 0.0))
	# ★ 按**真实秒**等待，不按帧数：编辑器里启动的游戏常常跑在几百帧/秒，
	#   `await process_frame` 等 60 帧可能只过了 0.2 秒的模拟时间，
	#   于是风"看起来没推动雾"（实测只到 0.029 而非预期的 0.12，就是这个原因）。
	await _wait_seconds(2.0)
	var centroid_after := FogNsSolver.density_centroid_x_from_image(solver.read_density_image())
	var velocity_image := solver.read_velocity_image()
	var speed_during_wind := FogNsSolver.max_speed_from_image(velocity_image, 3)
	var mean_speed := FogNsSolver.mean_speed_from_image(velocity_image, 3)
	_lines.append("       · 诊断：wind_velocity=%s（域单位/秒） wind_strength=%.2f 最大速度=%.5f 平均速度=%.5f"
			% [str(solver.wind_velocity), solver.wind_strength, speed_during_wind, mean_speed])
	_ck("风确实把雾吹向 +X（半拉格朗日 + 单位换算在 GPU 上成立）",
			centroid_before >= 0.0 and centroid_after > centroid_before + 0.02,
			"重心 u：%.4f -> %.4f" % [centroid_before, centroid_after])

	# ⑤ 投影的 A/B 对照：同一帧的"投影前"与"投影后"速度场散度
	# ★ 两个关键细节（都踩过）：
	#   1. 必须**先制造一份明显有散度的场**：周期边界 + 均匀风之下散度恒为 0，
	#      直接回读会得到 0 -> 0，那条断言就失去意义。
	#   2. 只在**紧挨着的两帧内**读回来：源只在一帧里注入，之后每帧的投影都会把散度
	#      压下去；等"0.2 秒"再读等于把待测对象自己擦掉了（实测读到 0.0000000）。
	#      SubViewport 的回读天然是上一帧的结果，所以"连投 3 帧 + 立刻读"最稳。
	_field.set_wind_mps(Vector2(0.0, 0.0))
	for _i in range(3):
		# 强速度源（目标速度 60 m/s 的量级 → 1 域单位/秒，局部散度足够大到可测）
		_field.add_source(origin + Vector3(6.0, 2.0, 0.0), 9.0, 0.0, Vector3(60.0, 0.0, -40.0))
		await get_tree().process_frame
	var before_image := solver.read_pre_projection_velocity_image()
	var after_image := solver.read_velocity_image()
	var divergence_before := FogNsSolver.max_divergence_from_image(before_image, 3)
	var divergence_after := FogNsSolver.max_divergence_from_image(after_image, 3)
	var speed_after := FogNsSolver.max_speed_from_image(after_image, 3)
	_ck("速度场确实在动（最大速度非 0）", speed_after > 0.001, "最大 |u| = %.5f 域单位/秒" % speed_after)
	_ck("投影前存在可测的散度（对照有效）", divergence_before > 1.0e-6,
			"投影前 %.7f（最大速度 %.5f）" % [divergence_before, speed_after])
	_ck("投影后散度小于投影前（链条顺序正确 + 压力解在起作用）",
			divergence_after < divergence_before,
			"投影前 %.7f -> 投影后 %.7f" % [divergence_before, divergence_after])

	# ⑥ 体积雾材质参数被真正写进去了（否则是"节点在、画面没雾"的经典假故障）
	var volume_material := volume.material_override as ShaderMaterial
	_ck("体积雾材质已绑定浓度纹理",
			volume_material != null and volume_material.get_shader_parameter("density_tex") != null)
	_ck("体积雾不透明度 > 0",
			volume_material != null and float(volume_material.get_shader_parameter("opacity")) > 0.0,
			"opacity=%.2f" % float(volume_material.get_shader_parameter("opacity")) if volume_material != null else "")

	# ⑦ 摆一个"可看的"雾景再截图：把画笔底图铺回来 + 连续投几个浓雾源 + 等粒子长起来。
	#    为什么单独做这一步：前面的断言把底图摘掉、源也只是脉冲式投了三帧，
	#    直接截图会得到"粒子飘着、体积雾几乎没有"的画面，不足以人工核对观感。
	var show_field := BRUSH_FIELD_SCRIPT.new() as FogBrushField
	show_field.grid_size = Vector2i(48, 48)
	show_field.ensure_data()
	# 一条斜向的雾带 + 两团浓雾：既能看到体积雾的形状，也能看出它是被风吹动的
	for k in range(26):
		var t := float(k) / 25.0
		BRUSH_FIELD_SCRIPT.apply_stamp(show_field, Vector2(8.0 + t * 34.0, 20.0 + sin(t * 6.0) * 8.0),
				5.0, 0.85, 0.5, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	BRUSH_FIELD_SCRIPT.apply_stamp(show_field, Vector2(36.0, 32.0), 9.0, 0.95, 0.35, BRUSH_FIELD_SCRIPT.Mode.PAINT)
	_field.set_brush_field(show_field)
	if solver != null:
		solver.base_relax = 0.6
		solver.refresh_materials()
	_field.set_wind_mps(Vector2(2.5, 0.6))
	await _wait_seconds(1.5)
	for _i in range(90):
		_field.add_source(origin + Vector3(-12.0, 2.0, 6.0), 8.0, 2.5, Vector3(4.0, 0.0, 1.0))
		await get_tree().process_frame
	await _wait_seconds(1.0)

	# ⑧ 截图（等渲染稳定）
	await _wait_frames(8)
	var image := get_viewport().get_texture().get_image()
	if image != null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
		var error := image.save_png(SHOT_PATH)
		_ck("截图存盘（人工核对雾气观感）", error == OK, "%s err=%d" % [SHOT_PATH, error])
	else:
		_ck("截图存盘（人工核对雾气观感）", false, "拿不到 viewport 图像")


# =========================================================
# 工具
# =========================================================

func _wait_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


## 按**真实秒**等待（而不是帧数）。
## 为什么必须区分：编辑器里启动的游戏常常跑在几百帧/秒，`await process_frame` 等 60 帧
## 可能只过了 0.2 秒的模拟时间 —— 依赖"模拟时间"的断言（风把雾推多远、源累积多少）会
## 因为帧率不同而飘。踩过：预期 0.12 的速度只测到 0.029，看起来像"物理错了"。
func _wait_seconds(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _ck(label: String, ok: bool, extra: String = "") -> void:
	_lines.append("%s%s%s" % ["  [OK]   " if ok else "  [FAIL] ", label,
			("  -> " + extra) if extra != "" else ""])
	if ok:
		_pass += 1
	else:
		_fail += 1


func _report_and_quit() -> void:
	for line in _lines:
		print(line)
	print("通过 %d  |  失败 %d" % [_pass, _fail])
	get_tree().quit(0 if _fail == 0 else 1)

extends Node
## ============================================================================
## fog_particle_gate_check —— 雾粒子两条新功能的**接线哨兵**（headless 可跑、确定性）
## ============================================================================
## 为什么做"接线"而不是"看像素"：这轮踩到的坑全是**接了没接上**（面板改了数量却没人发射、
## 材质 uniform 没被赋值……），而像素 A/B 在真场景里受草/雾/时序影响，极不稳。
## 这里断言的是每一环的**数值**：
##   ① `particles_enabled` → `GPUParticles3D.emitting`
##   ② `particle_min_pixel_size` / 视口尺寸 → 粒子**绘制材质** uniform
##   ③ 画笔底图 + 阈值 + 开关 → 粒子**process 材质**的雾内判据（mask_enabled / fog_mask_tex /
##      mask_min / spawn_inside_only）
## 用法：godot --path <项目> --headless res://tools/fog_particle_gate_check.tscn
## ============================================================================

var _pass := 0
var _fail := 0
var field: Node
var particles: GPUParticles3D
var process_material: ShaderMaterial
var draw_material: ShaderMaterial


func _ready() -> void:
	await _run()
	print("通过 %d ｜ 失败 %d" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ck(what: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
	print("  [%s] %-46s %s" % ["OK" if ok else "FAIL", what, detail])


func _run() -> void:
	print("=========== 雾粒子接线哨兵 ===========")
	var scene := load("res://scenes/main.tscn") as PackedScene
	if scene == null:
		_ck("main.tscn 能加载", false)
		return
	var root := scene.instantiate()
	add_child(root)
	await get_tree().process_frame
	await get_tree().process_frame
	field = root.find_child("FogField", true, false)
	if field == null:
		_ck("找到 FogField", false)
		return
	particles = field.get("_particles")
	process_material = particles.process_material as ShaderMaterial
	draw_material = particles.material_override as ShaderMaterial
	_ck("粒子节点与两个材质都建出来了",
			particles != null and process_material != null and draw_material != null,
			"particles=%s process=%s draw=%s" % [str(particles != null),
			str(process_material != null), str(draw_material != null)])

	# ---------- ① 粒子开关 → emitting ----------
	field.set("particle_count", 8000)
	field.set("particles_enabled", true)
	field.call("_apply_particle_params")
	_ck("① 打开『启用粒子』→ emitting = true",
			particles.emitting, "emitting=%s amount=%d" % [str(particles.emitting), particles.amount])
	field.set("particles_enabled", false)
	field.call("_apply_particle_params")
	_ck("① 关闭『启用粒子』→ emitting = false", not particles.emitting,
			"emitting=%s" % str(particles.emitting))
	field.set("particles_enabled", true)
	field.call("_apply_particle_params")

	# ---------- ② 最小像素 / 视口尺寸 → 绘制材质 ----------
	field.set("particle_min_pixel_size", 2.5)
	field.call("_apply_particle_params")
	var px = draw_material.get_shader_parameter("min_pixel_size")
	_ck("② 粒子最小像素 → 绘制材质 min_pixel_size", is_equal_approx(float(px), 2.5),
			"uniform=%s（属性=2.5）" % str(px))
	var vp = draw_material.get_shader_parameter("viewport_size_px")
	var want := Vector2(get_viewport().get_visible_rect().size)
	_ck("② 视口尺寸 → 绘制材质 viewport_size_px", vp is Vector2 and (vp as Vector2).x > 0.0,
			"uniform=%s ｜ 视口=%s" % [str(vp), str(want)])

	# ---------- ③ 底图/阈值/开关 → process 材质的雾内判据 ----------
	var brush_script: GDScript = load("res://scripts/fx/fog_brush_field.gd")
	var brush = brush_script.new()
	brush.grid_size = Vector2i(32, 32)
	var data := PackedFloat32Array()
	data.resize(32 * 32)
	data.fill(1.0)
	brush.data = data
	brush.mark_texture_dirty()
	field.set("brush_field", brush)
	field.call("set_brush_field", brush)
	field.set("particle_inside_fog_only", true)
	field.set("particle_mask_min", 0.25)
	field.call("_apply_particle_params")
	var enabled = process_material.get_shader_parameter("mask_enabled")
	var mask_tex = process_material.get_shader_parameter("fog_mask_tex")
	var mask_min = process_material.get_shader_parameter("mask_min")
	var inside_only = process_material.get_shader_parameter("spawn_inside_only")
	_ck("③ 有底图 → mask_enabled = 1", int(enabled) == 1, "mask_enabled=%s" % str(enabled))
	_ck("③ 底图纹理真的绑上了", mask_tex != null, "fog_mask_tex=%s" % str(mask_tex))
	_ck("③ 『雾内阈值』→ mask_min", is_equal_approx(float(mask_min), 0.25),
			"uniform=%s（属性=0.25）" % str(mask_min))
	_ck("③ 『粒子只在雾内』开 → spawn_inside_only = 1", int(inside_only) == 1,
			"spawn_inside_only=%s" % str(inside_only))
	field.set("particle_inside_fog_only", false)
	field.call("_apply_particle_params")
	inside_only = process_material.get_shader_parameter("spawn_inside_only")
	_ck("③ 『粒子只在雾内』关 → spawn_inside_only = 0（旧行为）", int(inside_only) == 0,
			"spawn_inside_only=%s" % str(inside_only))

	# 空底图（datasize 不匹配）⇒ 必须关掉限制，否则白图会让"处处都算有雾"
	var empty_brush = brush_script.new()
	empty_brush.grid_size = Vector2i(32, 32)
	field.set("brush_field", empty_brush)
	field.call("set_brush_field", empty_brush)
	field.call("_apply_particle_params")
	enabled = process_material.get_shader_parameter("mask_enabled")
	_ck("③ 空底图 → mask_enabled = 0（不能用白图冒充处处有雾）", int(enabled) == 0,
			"mask_enabled=%s" % str(enabled))
	root.queue_free()

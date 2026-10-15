extends Node
## ============================================================================
## fog_vortex_swirl_verify —— 角色涡流**可视化层**的数值验证（真实场景 + 真实像素读数）
## ============================================================================
## 为什么要这么测：之前用"跨运行的两张截图做像素差"是**不可靠**的 —— 草在摇、角色在动，
## 噪声本身就有几个百分点，于是"看起来有效果"可能全是噪声。这个工具改成：
##   同一次运行、同一个机位、**相邻帧**内切换图层开关，并且**跑一个 alpha=0 的对照组**：
##     · 对照组（alpha=0）的 开关差 ≈ 噪声底 —— 用它来证明测量方法本身干净
##     · 每个用例的 开关差 必须显著高于噪声底，才算"真的画出来了"
## 同时报告图层节点自身的运行时事实（visible / scale / shader uniform），
## 避免再把"我以为它画了"当成"它画了"。
##
## 用法（★ 必须带显卡，不要加 --headless）：
##   godot --path <项目> res://tools/fog_vortex_swirl_verify.tscn
## ============================================================================

const CASE_RADII := [0.2, 0.5, 1.0, 1.5, 3.0, 6.0]
const CASE_HEIGHTS := [0.5, 2.6]
const BASE_ALPHA := 0.62
const SHOT_SIZE := Vector2i(480, 360)      # 小视口足够判别，且读回快
const HIT_LEVEL := 8.0                     # 单像素差 > 8/255 记为"明显变化"

var player: Node3D
var field: Node
var _t := 0.0
var _results: Array[Dictionary] = []


func _ready() -> void:
	await _run()
	get_tree().quit(0)


func _run() -> void:
	var root := get_tree().root
	if get_parent() == root:
		root.remove_child(self)
		get_tree().current_scene = null
		root.add_child(self)
	get_tree().change_scene_to_file("res://scenes/main.tscn")
	for i in range(900):
		await get_tree().process_frame
		if get_tree().current_scene != null:
			break
	await get_tree().create_timer(3.0).timeout

	var group := get_tree().get_nodes_in_group("player")
	if group.is_empty():
		print("[SwirlTest] ✗ 找不到 player 组里的角色")
		return
	player = group[0]
	field = get_tree().current_scene.find_child("FogField", true, false)
	if field == null:
		print("[SwirlTest] ✗ 找不到 FogField")
		return
	field.call("set_wind_mps", Vector2.ZERO)

	var visual: Node = field.get("_vortex_visual")
	var material: ShaderMaterial = field.get("_vortex_material")
	print("=========== 涡流可视化层 · 数值验证 ===========")
	print("图层节点：%s ｜ 材质：%s ｜ 着色器：%s"
			% [str(visual), str(material), str(material.shader) if material != null else "无"])
	if visual == null or material == null:
		print("[SwirlTest] ✗ 图层没建出来 —— 后面全是失败")
		_report()
		return
	var mesh: CylinderMesh = visual.get("mesh")
	print("网格：半径=%s 高=%s cap_top=%s cap_bottom=%s"
			% [str(mesh.top_radius), str(mesh.height), str(mesh.cap_top), str(mesh.cap_bottom)])
	print("着色器 uniform 个数 = %d（0 = 编译失败/没加载）"
			% (material.shader.get_shader_uniform_list().size() if material.shader != null else -1))
	print("视口尺寸 = %s（读回像素用）" % str(SHOT_SIZE))
	print("")

	# ★ 必须把 camera_rig 的物理也冻住：它每帧会把 player.velocity 重置成 0（没输入时），
	#   不冻它的话图层会因为"速度=0"一直隐藏 —— 我上一版就是这么测出一堆噪声的。
	var rig := get_tree().current_scene.find_child("CameraRig", true, false)
	if rig != null:
		rig.set_physics_process(false)
		print("已冻结 CameraRig 的物理：%s" % str(rig))
	player.set_physics_process(false)
	_place_camera()

	# 对照组：alpha = 0（图层开着但完全不透明 ⇒ 应当与关闭无差别 = 噪声底）
	await _case("对照 alpha=0（预期无信号）", 1.5, 2.6, 0.0, false, false)
	# 壳缩在角色身体里的极端值：★ 只断言"**不得糊住角色**"。
	# 不要求"完全无信号"：壳的上下缘/身体轮廓外还会露出一点（信号 1~2，而半径 1.0 是 8~12），
	# 这个残留量会随草与角色动画在阈值附近跳，写成"必须无信号"会变成假失败。
	await _case("半径0.2（壳在身体里：只断言不糊人）", 0.2, 2.6, BASE_ALPHA, false, true, false)
	# 高度独立性
	for h in CASE_HEIGHTS:
		# 高度 0.5 米（贴地一圈）会被草/角色的软遮挡藏住 —— 这是**已知且正确**的行为，
		# 所以这一档预期"无信号"，用例通过即代表行为符合预期（要看得见就把高度取 ≥1.5 米）。
		await _case("半径1.5 × 高%s%s" % [str(h), "（贴地在草里，预期被遮挡）" if h < 1.0 else ""],
				1.5, h, BASE_ALPHA, h >= 1.0, false)
	# 半径独立性（0.2 已单独测过）
	for r in CASE_RADII:
		if r <= 0.21:
			continue
		await _case("半径%s × 高2.6" % str(r), r, 2.6, BASE_ALPHA)

	_report()


func _place_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "SwirlVerifyCam"
	cam.fov = 55.0
	cam.current = true
	get_tree().current_scene.add_child(cam)
	cam.position = player.global_position + Vector3(0.0, 2.0, 4.2)
	cam.look_at(player.global_position + Vector3(0.0, 1.0, 0.0), Vector3.UP)


func _case(label: String, radius: float, height: float, alpha: float,
		expect_signal := true, must_not_cover := false, assert_signal := true) -> void:
	field.set("vortex_visual_radius_m", radius)
	field.set("vortex_visual_height_m", height)
	field.set("vortex_visual_alpha", alpha)
	var visual: Node = field.get("_vortex_visual")
	var material: ShaderMaterial = field.get("_vortex_material")

	# ★ 测法要点（上一版就栽在这里）：
	#   · 噪声底与信号必须**同样间隔帧数**：都是"隔 3 帧"，否则时间累积差异会污染比较；
	#   · visible 必须在**开着的那一帧**读，不能在关掉之后读（上一版读晚了，误报 visible=false）。
	field.set("vortex_visual_enabled", false)
	var a := await _shot()                       # 关
	var off2 := await _shot()                    # 仍关（隔 3 帧）⇒ 噪声底 = a ↔ off2
	field.set("vortex_visual_enabled", true)     # 开
	var on := await _shot()                      # 开（隔 3 帧）⇒ 信号 = off2 ↔ on
	var visible_on: bool = visual.visible if visual != null else false
	var strength_on: float = float(material.get_shader_parameter("strength")) if material != null else -1.0
	field.set("vortex_visual_enabled", false)

	var sig := _diff(off2, on)
	var noise := _diff(a, off2)
	# ★ 角色所在区域（画面中央）的差异：用来判定"图层有没有把角色糊住"
	#   判据：中央区差异不得明显高于噪声（≤ 噪声×2.5）⇒ 角色身上没有多出条纹
	var center := _diff(off2, on, true)
	var center_noise := _diff(a, off2, true)
	# ★ 只在"壳缩在身体里"（半径 < 角色本体半径）时才要求"不得糊住角色"：
	#   半径够大时壳本来就从角色身前经过，"角色区有变化"是**应该的**（那就是环绕效果）。
	var covers_actor: bool = must_not_cover and center.y > maxf(center_noise.y * 2.5, 1.0)
	var scale: Vector3 = visual.scale if visual != null else Vector3.ZERO
	var uniform_r: float = float(material.get_shader_parameter("radius")) if material != null else -1.0
	var uniform_h: float = float(material.get_shader_parameter("height")) if material != null else -1.0
	var uniform_a: float = float(material.get_shader_parameter("alpha_max")) if material != null else -1.0

	# 判定：信号必须明显高于噪声底（3 倍 + 绝对下限）
	var has_signal: bool = sig.y > maxf(noise.y * 3.0, 0.30) and sig.x > noise.x * 3.0 + 0.5
	# assert_signal = false：该用例的信号量本身就在阈值附近（壳在身体里，只有边缘露出），
	# 硬要求"有/无信号"会随草与角色动画来回翻 —— 只断言真正关心的性质（不糊人）。
	var passed: bool = (not assert_signal or has_signal == expect_signal) and not covers_actor
	_results.append({"label": label, "signal": passed, "raw": has_signal, "expect": expect_signal, "on_off": sig, "noise": noise,
			"visible": visible_on, "scale": scale, "u": Vector3(uniform_r, uniform_h, uniform_a),
			"alpha": alpha, "radius": radius, "height": height, "strength": strength_on,
			"center": center, "center_noise": center_noise, "covers": covers_actor})
	print("[%s] %-24s 信号 均值%.2f/命中%.1f%% ｜ 噪声底 均值%.2f/命中%.1f%% ｜ 角色区 %.2f vs 噪声 %.2f（%s）"
			% ["OK" if passed else "FAIL", label, sig.y, sig.x, noise.y, noise.x,
			center.y, center_noise.y, "糊住角色!" if covers_actor else "未糊住"])


func _shot() -> Dictionary:
	for i in range(3):
		await get_tree().process_frame
		var delta := get_process_delta_time()
		player.set("velocity", Vector3(0.0, 0.0, -4.5))     # 持续"走"，注入与图层才活着
		field.call("_update_interactors", delta)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		print("        ✗ 读不到画面（是不是用了 --headless？）")
		return {}
	if image.get_width() > SHOT_SIZE.x:
		image.resize(SHOT_SIZE.x, SHOT_SIZE.y, Image.INTERPOLATE_BILINEAR)
	return {"data": image.get_data(), "w": image.get_width(), "h": image.get_height()}


## 返回 {命中率 %, 平均差值}：逐个像素比较 RGB
func _diff(a: Dictionary, b: Dictionary, center_only := false) -> Vector2:
	if a.is_empty() or b.is_empty():
		return Vector2.ZERO
	var pa: PackedByteArray = a["data"]
	var pb: PackedByteArray = b["data"]
	var hit := 0
	var total := 0.0
	var n := 0
	var w: int = a["w"]
	var h: int = a["h"]
	var step := 4 * 2                                    # 隔一个像素采样，够用且快
	for k in range(0, mini(pa.size(), pb.size()) - 3, step):
		if center_only:
			# 只统计画面中央（角色所在）区域：用来判定"图层有没有糊在角色身上"
			var px := (k / 4) % w
			var py := (k / 4) / w
			if px < int(w * 0.40) or px > int(w * 0.60) or py < int(h * 0.25) or py > int(h * 0.80):
				continue
		var d: float = (absi(pa[k] - pb[k]) + absi(pa[k + 1] - pb[k + 1])
				+ absi(pa[k + 2] - pb[k + 2])) / 3.0
		total += d
		n += 1
		if d > HIT_LEVEL:
			hit += 1
	return Vector2(100.0 * float(hit) / maxf(float(n), 1.0), total / maxf(float(n), 1.0))


func _report() -> void:
	print("")
	print("=========== 汇总 ===========")
	var ok := 0
	for r in _results:
		if r["signal"]:
			ok += 1
		var o: Vector2 = r["on_off"]
		var nz: Vector2 = r["noise"]
		print("  %-5s %-24s 信号/噪声 = %5.1f 倍（均值 %.2f vs %.2f ；命中 %.1f%% vs %.1f%%）"
				% ["OK" if r["signal"] else "FAIL", r["label"],
				o.y / maxf(nz.y, 0.01), o.y, nz.y, o.x, nz.x])
	print("通过 %d ｜ 失败 %d ｜ 合计 %d" % [ok, _results.size() - ok, _results.size()])
	print("判定口径：开关差均值 > max(噪声底×3, 0.30) 且 命中率 > 噪声底×3 + 0.5 个百分点")

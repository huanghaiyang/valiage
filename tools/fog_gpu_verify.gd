extends Node
## ============================================================================
## fog_gpu_verify.gd —— GPU 自检的**场景版入口**（配合 tools/fog_gpu_verify.tscn）
## ============================================================================
## 为什么要有场景版：本仓库的开发机不允许从沙箱里直接启动 D:\godot\ 下的 Godot
## 可执行文件，所以命令行版（tools/verify_fog_gpu.gd）留给使用者自己跑；日常开发
## 用编辑器跑这个场景即可（编辑器 -> 打开该场景 -> F6，或 MCP project_run(custom)）。
## 逻辑本体在 scripts/fx/fog_ns_gpu_probe.gd，两个入口共用同一份断言，不会漂移。
##
## 与命令行版的唯一区别：这里**多测一条显示链路**——把计算纹理挂到 Texture2DRD 上
## 真的画出来，并截图存盘（res://screenshots/fog_probe.png），因为"能算出来"和
## "能画到屏幕上"是两件事，后者坏了 GPU 求解器一样用不了。
##
## 输出：逐条 [OK]/[FAIL] + 通过/失败计数；结束时 quit(0 或 1)。
## ============================================================================

const PROBE := preload("res://scripts/fx/fog_ns_gpu_probe.gd")

const SHOT_PATH := "res://screenshots/fog_probe.png"
## 等渲染稳定再截图/退出：Texture2DRD 的内容要经过渲染线程，第一帧不一定画好。
const SETTLE_FRAMES := 20
## 探针图案的显示位置与尺寸（与 _add_display 保持一致）。
const RECT_POS := Vector2(24, 24)
const RECT_SIZE := Vector2(256, 256)

var _lines: Array[String] = []
var _pass := 0
var _fail := 0
var _frames := 0
var _display_added := false


func _ready() -> void:
	print("=========== 雾气流体 GPU 自检（场景版） ===========")

	var env := PROBE.check_environment()
	_absorb(env)

	if bool(env["ok"]):
		var compute := PROBE.run_compute_probe(env["rd"])
		_absorb(compute)
		if bool(compute["ok"]):
			_add_display(compute["texture"])


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < SETTLE_FRAMES:
		return
	set_process(false)

	if _display_added:
		_save_shot()

	for line in _lines:
		print(line)
	print("通过 %d  |  失败 %d" % [_pass, _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# =========================================================
# 显示链路（Texture2DRD）
# =========================================================

func _add_display(texture: RID) -> void:
	if not texture.is_valid():
		return

	var tex_rd := Texture2DRD.new()
	tex_rd.texture_rd_rid = texture

	var layer := CanvasLayer.new()
	layer.name = "ProbeDisplay"
	var rect := TextureRect.new()
	rect.name = "ProbePattern"
	rect.texture = tex_rd
	rect.position = RECT_POS
	rect.size = RECT_SIZE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.add_child(rect)
	add_child(layer)

	_display_added = true
	_ck("Texture2DRD 能引用计算纹理并挂进场景树", true, "32x32 探针图案放大到 256x256")


func _save_shot() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		_ck("截图存盘（证明纹理真的上了屏）", false, "拿不到 viewport 图像")
		return

	# 先做**数值级**的显示验证：探针图案 R 通道 = 归一化 x，所以屏幕上看这一行
	# 红通道必须单调递增。这能证明"计算纹理 -> Texture2DRD -> 屏幕"整条链路通了，
	# 而不是仅仅"没有报错"（颜色空间转换是单调映射，不影响这个判据）。
	var y := int(RECT_POS.y + RECT_SIZE.y * 0.5)
	var samples: Array[float] = []
	for x_float in PROBE.display_sample_x(RECT_POS.x, RECT_SIZE.x, 5):
		var x := clampi(int(x_float), 0, img.get_width() - 1)
		samples.append(img.get_pixel(x, clampi(y, 0, img.get_height() - 1)).r)

	var monotonic := true
	for i in range(1, samples.size()):
		if samples[i] <= samples[i - 1] + 0.01:
			monotonic = false
	var shown := ""
	for value in samples:
		shown += "%.3f " % value
	_ck("屏幕上沿 x 的红通道单调递增（纹理真的画出来了）", monotonic, shown.strip_edges())
	_ck("显示内容不是全黑（有实际图案）", samples[samples.size() - 1] > 0.05, "最右采样=%.3f" % samples[samples.size() - 1])

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://screenshots"))
	var err := img.save_png(SHOT_PATH)
	_ck("截图存盘（人工可核对）", err == OK, "%s err=%d" % [SHOT_PATH, err])


# =========================================================
# 断言汇总
# =========================================================

func _absorb(result: Dictionary) -> void:
	_pass += int(result.get("pass", 0))
	_fail += int(result.get("fail", 0))
	for line in result.get("lines", []):
		_lines.append(str(line))


func _ck(label: String, ok: bool, extra: String = "") -> void:
	_lines.append("%s%s%s" % ["  [OK]   " if ok else "  [FAIL] ", label,
			("  -> " + extra) if extra != "" else ""])
	if ok:
		_pass += 1
	else:
		_fail += 1

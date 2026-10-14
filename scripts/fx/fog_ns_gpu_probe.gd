class_name FogNsGpuProbe
extends RefCounted
## ============================================================================
## fog_ns_gpu_probe.gd —— GPU 计算能力探针（雾气流体求解器的前置自检）
## ============================================================================
## 【职责】只回答一个问题：**这台机器上"RenderingDevice + compute 着色器 + 回读"
##   这条链路能不能用**。它不参与雾气算法，也不持有任何场景状态。
##
## 【为什么单独存在】GPU 版纳维-斯托克斯求解器依赖四件事同时成立：
##   ① 能拿到 RenderingDevice ② compute 着色器能编译并派发
##   ③ 结果能回读（否则自动化断言无从下手）④ 结果能贴到 Texture2DRD 上显示
##   ①~③ 在这里验证，④ 由调用方（tools/fog_gpu_verify.gd）验证 —— 显示链路要进
##   场景树等渲染帧，不适合放在纯逻辑模块里。
##   任何一条不成立，就必须退回 CPU 参考实现（scripts/fx/fog_ns_reference.gd），
##   所以这里**逐条**报结果，让失败点直接指向坏掉的那一环。
##
## 【对外接口】
##   · check_environment() -> Dictionary         环境与 RenderingDevice（断言 ①②）
##   · run_compute_probe(rd) -> Dictionary       派发 + 回读 + push constant（②③）
##   · texel(bytes, x, y, width) -> Vector4      半精度解码（测试可直接喂已知字节）
##   两个 check 方法都返回 {ok, pass, fail, lines, rd, shader, texture, pipeline}
##   —— shader / texture 供调用方继续做显示链路验证（Texture2DRD）。
##   纯 RefCounted，不依赖场景树 / autoload / 编辑器，可在测试里直接调用静态函数。
##
## 【已知的坑】
##   1. `.glsl` 是**导入资源**：新写的计算着色器必须先被编辑器导入（filesystem scan）
##      才能 load() 到，否则 load() 返回 null —— 表现为"文件明明在，却加载失败"。
##   2. `RDShaderFile.get_spirv()` 即使编译失败也可能返回非 null；真正的错误在
##      `RDShaderSPIRV.get_stage_compile_error()` 里，不读它就会把编译失败误判成成功。
##   3. rgba16f 回读得到的是半精度字节，必须用 PackedByteArray.decode_half() 解码。
##   4. push constant 没送进 GPU 时不会报错，只会静默读到 0 —— 所以本探针专门用
##      B 通道写入一个非零相位来验证它。
## ============================================================================

const PROBE_SHADER := "res://assets/shaders/fog_ns/probe_write.glsl"
const PROBE_SIZE := 32
## 写进 B 通道的相位值：回读必须一致，用来证明 push constant 真的到了 GPU。
const PROBE_PHASE := 0.375
const LOCAL_SIZE := 8

## 半精度 4 通道格式在不同 Godot 版本里的成员名不一样（4.7 上已确认
## `DATA_FORMAT_RGBA16F` 不存在），所以按名字表在运行期解析，而不是把某一个
## 版本的名字硬写进代码 —— 写死会在升级引擎时变成"整份求解器都编译不过"。
const RGBA16F_FORMAT_NAMES := [
	"DATA_FORMAT_R16G16B16A16_SFLOAT",
	"DATA_FORMAT_RGBA16F",
]


## 解析 rgba16f 的 DataFormat 枚举值。返回 [值, 命中的成员名]；都找不到时返回 [-1, ""]。
static func rgba16f_format() -> Array:
	for name in RGBA16F_FORMAT_NAMES:
		if ClassDB.class_has_integer_constant("RenderingDevice", name):
			return [ClassDB.class_get_integer_constant("RenderingDevice", name), name]
	return [-1, ""]


## 诊断用：列出 RenderingDevice 上所有形如 DATA_FORMAT_*16*FLOAT 的成员名。
static func float_format_candidates() -> Array[String]:
	var out: Array[String] = []
	for name in ClassDB.class_get_integer_constant_list("RenderingDevice", true):
		var upper := String(name).to_upper()
		if upper.begins_with("DATA_FORMAT_") and upper.contains("16") and upper.contains("FLOAT"):
			out.append(String(name))
	out.sort()
	return out


## 环境 + RenderingDevice 可用性。
## 返回：{ok, pass, fail, lines, rd, main_rd, local_rd}。
## ok = 拿到了一个可用的 RenderingDevice（优先主 RD：纹理能被 Texture2DRD 直接引用）。
static func check_environment() -> Dictionary:
	var lines: Array[String] = []
	var tally := [0, 0]      # [pass, fail]

	var method := str(ProjectSettings.get_setting("rendering/renderer/rendering_method", "?"))
	_add_ck(lines, tally, "渲染后端是 Forward+（GPU compute 的前提）", method == "forward_plus", method)

	var local_rd := RenderingServer.create_local_rendering_device()
	var main_rd := RenderingServer.get_rendering_device()
	_add_ck(lines, tally, "create_local_rendering_device() 可用", local_rd != null,
			"null" if local_rd == null else "RenderingDevice 就绪")
	_add_ck(lines, tally, "RenderingServer.get_rendering_device() 可用", main_rd != null,
			"null" if main_rd == null else "RenderingDevice 就绪")

	# ★ 必须用**本地** RD：主 RD 的 submit()/sync() 会被引擎直接拒绝
	#   （"Only local devices can submit and sync."），所以手动派发 compute 只能用本地 RD。
	#   代价是纹理跨设备显示，需要 Texture2DRD（由调用方验证）。
	var rd: RenderingDevice = local_rd
	var source := "本地 RD" if local_rd != null else ("主 RD（无法 submit/sync）" if main_rd != null else "无")
	_add_ck(lines, tally, "拿到可用于 submit/sync 的本地 RenderingDevice", rd != null, source)

	return {
		"ok": rd != null,
		"pass": tally[0],
		"fail": tally[1],
		"lines": lines,
		"rd": rd,
		"main_rd": main_rd,
		"local_rd": local_rd,
	}


## 显示链路的取样点：TextureRect 的摆放位置由调用方决定，这里只给出"沿 x 轴均匀取 n 个点"。
## 用途：把计算纹理贴到屏幕上之后，沿 x 方向的红通道应当单调递增（图案左暗右亮）——
## 这比"没报错"强得多，能真正证明纹理上了屏。返回横向取样坐标。
static func display_sample_x(rect_left: float, rect_width: float, count: int = 5) -> Array[float]:
	var out: Array[float] = []
	for i in range(count):
		# 取每段中点，避开左右边界（边界附近可能有缩放/插值过渡）
		var t := (float(i) + 0.5) / float(count)
		out.append(rect_left + rect_width * t)
	return out


## compute 派发 + 回读 + push constant（数值级断言，不只是"没报错"）。
## 返回：{ok, pass, fail, lines, rd, shader, texture, pipeline}。
static func run_compute_probe(rd: RenderingDevice) -> Dictionary:
	var lines: Array[String] = []
	var tally := [0, 0]
	var out := {
		"ok": false, "pass": 0, "fail": 1, "lines": lines,
		"rd": rd, "shader": RID(), "texture": RID(), "pipeline": RID(),
	}
	if rd == null:
		_add_ck(lines, tally, "有可用的 RenderingDevice", false, "null，无法做 compute 自检")
		return _finish(out, tally, lines)

	var shader_file := load(PROBE_SHADER) as RDShaderFile
	_add_ck(lines, tally, "探针着色器能加载（.glsl -> RDShaderFile）", shader_file != null,
			PROBE_SHADER if shader_file != null else "%s（未导入？先在编辑器做一次 filesystem scan）" % PROBE_SHADER)
	if shader_file == null:
		return _finish(out, tally, lines)

	var spirv := shader_file.get_spirv()
	var compile_error := ""
	if spirv != null:
		compile_error = str(spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE))
	_add_ck(lines, tally, "着色器编译通过（SPIR-V 无错误）", spirv != null and compile_error == "",
			"编译通过" if compile_error == "" else compile_error)
	if spirv == null or compile_error != "":
		return _finish(out, tally, lines)

	var shader := rd.shader_create_from_spirv(spirv)
	_add_ck(lines, tally, "shader_create_from_spirv 成功", shader.is_valid(), str(shader))
	if not shader.is_valid():
		return _finish(out, tally, lines)

	var resolved := rgba16f_format()
	var format_value := int(resolved[0])
	_add_ck(lines, tally, "能解析 rgba16f 的 DataFormat 枚举", format_value >= 0,
			"%s = %d" % [resolved[1], format_value] if format_value >= 0
			else "候选名都不存在，可用：%s" % str(float_format_candidates()))
	if format_value < 0:
		return _finish(out, tally, lines)

	var tf := RDTextureFormat.new()
	tf.width = PROBE_SIZE
	tf.height = PROBE_SIZE
	tf.format = format_value
	# 四个 usage 位缺一不可：STORAGE=当 image2D 写；SAMPLING=给 Texture2DRD 显示；
	# CAN_COPY_FROM=回读；CAN_UPDATE=允许 CPU 侧初始化（把画笔刷出的雾塞进去要用）。
	tf.usage_bits = (
		RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
		| RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
	)
	var texture := rd.texture_create(tf, RDTextureView.new(), [])
	_add_ck(lines, tally, "创建 rgba16f 存储纹理", texture.is_valid(), str(texture))
	if not texture.is_valid():
		return _finish(out, tally, lines)

	var uniform := RDUniform.new()
	uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	uniform.binding = 0
	uniform.add_id(texture)
	var uniform_set := rd.uniform_set_create([uniform], shader, 0)
	_add_ck(lines, tally, "创建 uniform set（image2D 绑定）", uniform_set.is_valid(), str(uniform_set))
	if not uniform_set.is_valid():
		return _finish(out, tally, lines)

	var pipeline := rd.compute_pipeline_create(shader)
	_add_ck(lines, tally, "创建 compute pipeline", pipeline.is_valid(), str(pipeline))
	if not pipeline.is_valid():
		return _finish(out, tally, lines)

	var push := PackedFloat32Array([PROBE_PHASE, 0.0, 0.0, 0.0]).to_byte_array()
	var groups := int(ceil(float(PROBE_SIZE) / float(LOCAL_SIZE)))

	var cl := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(cl, pipeline)
	rd.compute_list_bind_uniform_set(cl, uniform_set, 0)
	rd.compute_list_set_push_constant(cl, push, push.size())
	rd.compute_list_dispatch(cl, groups, groups, 1)
	rd.compute_list_end()

	# ★ 4.7 里 RenderingDevice.submit() 返回 void（旧版本返回 Error），所以不能接返回值。
	#   提交是否成功只能靠 `sync()` 之后的回读数据来判断 —— 这正是下面要做数值断言的原因。
	rd.submit()
	rd.sync()
	_add_ck(lines, tally, "submit() + sync() 未崩（能走到这一行）", true, "提交并同步完成")

	_verify_readback(rd, texture, lines, tally)

	out["shader"] = shader
	out["texture"] = texture
	out["pipeline"] = pipeline
	return _finish(out, tally, lines)


## 回读校验：图案 + push constant 都要对得上。
static func _verify_readback(rd: RenderingDevice, texture: RID, lines: Array[String], tally: Array) -> void:
	var bytes := rd.texture_get_data(texture, 0)
	var expected := PROBE_SIZE * PROBE_SIZE * 8      # rgba16f：4 通道 x 2 字节
	_add_ck(lines, tally, "texture_get_data 能回读", bytes.size() == expected,
			"%d 字节（期望 %d）" % [bytes.size(), expected])
	if bytes.size() != expected:
		return

	var corner := texel(bytes, 0, 0)
	var far := texel(bytes, PROBE_SIZE - 1, PROBE_SIZE - 1)
	var mid := texel(bytes, PROBE_SIZE / 2, PROBE_SIZE / 4)

	_add_ck(lines, tally, "左上角 R≈0（x 归一化）", absf(corner.x) < 0.02, "R=%.4f" % corner.x)
	_add_ck(lines, tally, "右上角 R≈1（x 归一化）", absf(far.x - 1.0) < 0.02, "R=%.4f" % far.x)
	_add_ck(lines, tally, "右下角 G≈1（y 归一化）", absf(far.y - 1.0) < 0.02, "G=%.4f" % far.y)
	_add_ck(lines, tally, "中列 R≈0.5（内容正确，不是一片常数）", absf(mid.x - 0.5) < 0.05, "R=%.4f" % mid.x)
	_add_ck(lines, tally, "push constant 抵达 GPU（B = 相位）", absf(mid.z - PROBE_PHASE) < 0.005,
			"B=%.4f 期望 %.4f" % [mid.z, PROBE_PHASE])


## 读 rgba16f 纹理里第 (x, y) 个像素（每像素 8 字节，R/G/B/A 各 2 字节半精度）。
## 独立成静态函数是为了让测试能直接喂已知字节验证解码方向（行优先、RGBA 顺序）。
static func texel(bytes: PackedByteArray, x: int, y: int, width: int = PROBE_SIZE) -> Vector4:
	var offset := (y * width + x) * 8
	return Vector4(
		bytes.decode_half(offset),
		bytes.decode_half(offset + 2),
		bytes.decode_half(offset + 4),
		bytes.decode_half(offset + 6)
	)


## 记一条断言：写进 lines，并把 [pass, fail] 累加进 tally。
static func _add_ck(lines: Array[String], tally: Array, label: String, ok: bool, extra: String = "") -> void:
	lines.append("%s%s%s" % ["  [OK]   " if ok else "  [FAIL] ", label,
			("  -> " + extra) if extra != "" else ""])
	if ok:
		tally[0] += 1
	else:
		tally[1] += 1


static func _finish(out: Dictionary, tally: Array, lines: Array[String]) -> Dictionary:
	out["ok"] = int(tally[1]) == 0
	out["pass"] = int(tally[0])
	out["fail"] = int(tally[1])
	out["lines"] = lines
	return out

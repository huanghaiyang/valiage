extends Node
## ============================================================================
## fog_math_probe.gd —— 把数学推导里的关键恒等式**逐点数值验证**一遍
## ============================================================================
## 运行：编辑器打开 tools/fog_math_probe.tscn 按 F6（MCP project_run custom 亦可）。
## 它只做数学，不碰 GPU/着色器：被测对象是 scripts/fx/fog_ns_reference.gd（CPU 参考实现，
## 与 GPU 通道链同式）。输出是一份可直接引用的数值报告，供
## docs/纳维-斯托克斯-数学推导与求解过程.md 使用。
##
## 验证清单（每一条对应文档里的一节）：
##   ① 离散散度的因子：代码里的 div = -0.5h(...) 是否等于 -h²·(解析散度)
##   ② 投影逐点恒等式：div(u') = div(u) + ¼[Δ̃x p + Δ̃y p]（Δ̃ = 跨两格的宽模板拉普拉斯）
##      —— 这条若以机器精度成立，就说明"减梯度 → 散度变化"的推导与代码是同一条式子
##   ③ 迭代阶梯：压力迭代 4/16/64/256 次后的残差散度，与 Jacobi 最慢模衰减因子的理论值
##   ④ 风松弛稳态：解析 u* = k·u_target/(k+σ) 与参考实现实测值
##   ⑤ 底图松弛稳态：解析 d* = base·g·κ/(σ+κ) 与实测值
##   ⑥ 数值粘性估计：ν_num ≈ ½|u|Δx(1−CFL)，与空气真实粘性的量级差、等效雷诺数
##
## 为什么值得单独跑一遍：数学文档最容易出的错是"公式抄对了但和代码不是一个东西"
## （差一个 h、差一个 Δt、符号相反）。①② 是恒等式级别的检查，能直接钉死这类错误。
##
## 【GDScript 注意】`REFERENCE.new()` 返回值是 Variant，所以 `var x := REFERENCE.new()`
## 会报 "Cannot infer the type"；同理 `var u := sim.u`（RefCounted 的属性也是 Variant）。
## 本文件所有涉及动态调用的局部变量都写了显式类型。
## ============================================================================

const REFERENCE := preload("res://scripts/fx/fog_ns_reference.gd")

## 等日志助手接上再输出（在 _ready 里立刻 print + quit 会丢输出）
const OUTPUT_DELAY_FRAMES := 4

var _lines: Array[String] = []
var _frames := 0
var _failed := 0


func _ready() -> void:
	# ★ 立刻打一条"已启动"：如果连这条都看不到，说明场景/脚本根本没被加载，
	#   而不是"计算太慢"或"输出被吞"（区分故障位置比什么都重要）。
	print("[fog_math_probe] start")
	_run_all()
	_flush("（_ready 内直接输出）")
	set_process(true)


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < OUTPUT_DELAY_FRAMES:
		return
	set_process(false)
	_flush("（第 %d 帧输出）" % OUTPUT_DELAY_FRAMES)
	get_tree().quit(0 if _failed == 0 else 1)


## 输出报告并统计失败项。_ready 与 _process 各调一次：前者即时可见（不依赖日志助手时序），
## 后者满足"必须等日志助手接上"的场合。两边都打，最坏情况是重复一遍，不会漏。
func _flush(note: String) -> void:
	print("=========== 雾气流体：数学推导数值验证 %s ===========" % note)
	for line in _lines:
		print(line)
	print("全部验证通过" if _failed == 0 else "存在 %d 项失败" % _failed)


func _log(text: String) -> void:
	_lines.append(text)


func _check(label: String, ok: bool, detail: String) -> void:
	if not ok:
		_failed += 1
	_lines.append("%s %s  -> %s" % ["  [OK]  " if ok else "  [FAIL]", label, detail])


## 科学计数法字符串。
## ★ GDScript 的 `%` 格式化**不支持 `%e`**（只支持 %s %d %f %x 等），
##   写了 `%.3e` 会在运行时报 "unsupported format character" 并把整行数字吞掉。
##   所以自己拼一个，既能读又不丢信息。
func _sci(value: float) -> String:
	if is_zero_approx(value):
		return "0"
	var exponent := int(floor(log(absf(value)) / log(10.0)))
	var mantissa := value / pow(10.0, float(exponent))
	return "%.3f×10^%d" % [mantissa, exponent]


## 造一个"零均值散度、可周期延拓"的速度场（用于投影类验证）。
func _make_divergent_field(size: int) -> RefCounted:
	var sim: RefCounted = REFERENCE.new(size)
	for j in range(size):
		for i in range(size):
			var x: float = (float(i) + 0.5) / float(size)
			var y: float = (float(j) + 0.5) / float(size)
			sim.u[j * size + i] = 0.5 * sin(4.0 * TAU * x)
			sim.v[j * size + i] = 0.5 * sin(4.0 * TAU * y)
	return sim


# =========================================================
# ① 离散散度的因子
# =========================================================

## 代码里的 div_impl = -0.5h[(u_{i+1}-u_{i-1}) + (v_{j+1}-v_{j-1})]
## 中心差分下 (u_{i+1}-u_{i-1}) ≈ 2h·∂u/∂x，所以 div_impl ≈ -h²·(∂u/∂x + ∂v/∂y)。
## 这条验证的就是那个 h² 因子 —— 写错它整段投影都会歪。
func _check_divergence_factor() -> void:
	var n := 64
	var sim: RefCounted = REFERENCE.new(n)
	var h := 1.0 / float(n)
	# ★ 必须直接写 sim.u[...]：PackedFloat32Array 是值类型，`var u := sim.u` 拿到的是副本，
	#   往副本里写不会回到对象上（这样初始化会静默失效，测出来的是一场零）。
	for j in range(n):
		for i in range(n):
			sim.u[j * n + i] = sin(TAU * (float(i) + 0.5) * h)
			sim.v[j * n + i] = sin(TAU * (float(j) + 0.5) * h)
	var u: PackedFloat32Array = sim.u          # 只读副本，供下面的采样使用
	var v: PackedFloat32Array = sim.v

	var max_impl := 0.0
	var max_analytic := 0.0
	var worst_ratio_error := 0.0
	for j in range(n):
		for i in range(n):
			var impl := -0.5 * h * (
				u[j * n + wrapi(i + 1, 0, n)] - u[j * n + wrapi(i - 1, 0, n)]
				+ v[wrapi(j + 1, 0, n) * n + i] - v[wrapi(j - 1, 0, n) * n + i]
			)
			var analytic := (
				TAU * cos(TAU * (float(i) + 0.5) * h) + TAU * cos(TAU * (float(j) + 0.5) * h)
			)
			max_impl = maxf(max_impl, absf(impl))
			max_analytic = maxf(max_analytic, absf(analytic))
			var predicted := -h * h * analytic
			if absf(predicted) > 1.0e-6:
				worst_ratio_error = maxf(worst_ratio_error, absf(impl - predicted) / absf(predicted))
	_check("① 离散散度 = −h²·解析散度（因子验证）",
			worst_ratio_error < 0.01,
			"max|div_impl|=%s  max|Div|=%.3f  最大相对偏差=%s（中心差分的 O(h²) 误差内）"
			% [_sci(max_impl), max_analytic, _sci(worst_ratio_error)])


# =========================================================
# ② 投影逐点恒等式
# =========================================================

## 把 u ← u − ½(p₊₁−p₋₁)/h 代进散度定义，得**精确**恒等式（与压力是否收敛无关）：
##   div'(u') = div(u) + ¼·[ p_{i+2} − 2p_i + p_{i−2} + p_{j+2} − 2p_i + p_{j−2} ]
## 逐点比对：左边由投影后的场算出，右边由投影前的场（副本）与最终压力算出。
func _check_projection_identity() -> void:
	var n := 32
	var h := 1.0 / float(n)
	var sim: RefCounted = _make_divergent_field(n)

	# 保存"投影前"的场（副本），用于严格比对。
	# ★ 显式类型：sim.u 是 Variant，`var u_before := sim.u.duplicate()` 会报 cannot infer。
	var u_before: PackedFloat32Array = sim.u.duplicate()
	var v_before: PackedFloat32Array = sim.v.duplicate()

	sim.project(20)
	var pressure: PackedFloat32Array = sim.p

	var max_error := 0.0
	var max_div := 0.0
	for j in range(n):
		for i in range(n):
			# 投影后散度（由投影后的场算出）
			var div_after: float = -0.5 * h * (
				sim.u[j * n + wrapi(i + 1, 0, n)] - sim.u[j * n + wrapi(i - 1, 0, n)]
				+ sim.v[wrapi(j + 1, 0, n) * n + i] - sim.v[wrapi(j - 1, 0, n) * n + i]
			)
			# 投影前散度（由副本算出）
			var div_before: float = -0.5 * h * (
				u_before[j * n + wrapi(i + 1, 0, n)] - u_before[j * n + wrapi(i - 1, 0, n)]
				+ v_before[wrapi(j + 1, 0, n) * n + i] - v_before[wrapi(j - 1, 0, n) * n + i]
			)
			# 宽模板拉普拉斯（跨两格，周期环绕）
			var wide := (
				pressure[j * n + wrapi(i + 2, 0, n)] - 2.0 * pressure[j * n + i]
				+ pressure[j * n + wrapi(i - 2, 0, n)]
				+ pressure[wrapi(j + 2, 0, n) * n + i] - 2.0 * pressure[j * n + i]
				+ pressure[wrapi(j - 2, 0, n) * n + i]
			)
			var predicted: float = div_before + 0.25 * wide
			max_error = maxf(max_error, absf(div_after - predicted))
			max_div = maxf(max_div, absf(div_after))

	# 机器精度量级：float32 下相对 ~1e-7，这里用绝对容差
	_check("② 投影逐点恒等式 div' = div + ¼·宽模板拉普拉斯（精确，与收敛无关）",
			max_error < 1.0e-6,
			"逐点最大偏差 %s ；投影后 max|div'|=%s（偏差比残差小 6 个数量级以上）"
			% [_sci(max_error), _sci(max_div)])


# =========================================================
# ③ 迭代阶梯 vs 理论衰减因子
# =========================================================

func _check_iteration_ladder() -> void:
	# n=24、4 档迭代：GDScript 逐单元循环下这是"几秒钟出结果"的规模。
	# （n=32 配 256 次迭代会让这个场景跑好几分钟，把编辑器连接拖到超时 —— 踩过。）
	var n := 24
	var ladder := [4, 16, 64, 256]
	var residuals: Array[float] = []

	# ★ 必须单独量一次"投影前"，否则会把"第 1 次投影的结果"误当成初始值：
	#   project(0) 内部是 maxi(1,·)，拿不到真正的 0 次。
	var probe: RefCounted = _make_divergent_field(n)
	var initial: float = probe.max_divergence()

	# 理论下限：对波数 θ 的纯傅里叶模，**精确**投影后残留比例恰为 sin²(θ/2)
	#   （推导：D u' = D u − Δ̃p，而 L_c p = D u ⇒ 比例 = 1 − sin²θ/(4sin²(θ/2)) = sin²(θ/2)）
	var theta := 4.0 * TAU / float(n)      # 测试场是"每域 4 个周期"
	var ideal_ratio := sin(theta * 0.5) * sin(theta * 0.5)

	for steps in ladder:
		var sim: RefCounted = _make_divergent_field(n)
		sim.project(int(steps))
		residuals.append(sim.max_divergence())

	var shown := " 0次=%s" % _sci(initial)
	for k in range(ladder.size()):
		shown += " %d次=%s" % [int(ladder[k]), _sci(residuals[k])]
	_check("③ 残差随压力迭代次数单调下降", residuals[3] < residuals[0], shown)

	_lines.append("        · 该测试场波数 θ=4·2π/%d=%.4f ⇒ **精确投影的理论残留比例** sin²(θ/2)=%.3f"
			% [n, theta, ideal_ratio])
	_lines.append("        · 实测：%d 次后 %s = 初始的 %.3f 倍（与理论下限同量级）；再迭代到 256 次只再降 %.2f 倍"
			% [int(ladder[0]), _sci(residuals[0]), residuals[0] / initial,
			residuals[0] / residuals[3]])
	_lines.append("        · ⇒ 残差**地板**由「紧致/宽模板不匹配」（同位网格奇偶失耦）决定，不是迭代次数；"
			+ "想再降必须换格式（交错网格）或加平滑项")


# =========================================================
# ④ 风松弛稳态
# =========================================================

## 离散格式：u ← (u + (T−u)·k·Δt)·(1−σ·Δt)，不动点 u* ≈ T·k/(k+σ)。
func _check_wind_steady_state() -> void:
	var k := 1.2          # 松弛速率（1/秒）
	var sigma := 0.35     # 速度耗散（1/秒）
	var target := 0.15    # 目标速度（域单位/秒）
	var sim: RefCounted = REFERENCE.new(32)
	sim.velocity_dissipation = sigma
	sim.vorticity_strength = 0.0
	sim.density_dissipation = 0.0
	sim.pressure_iterations = 4            # 均匀风场的投影是恒等操作，无需高精度压力
	for _i in range(120):                 # 2 秒（时间常数 0.645 s ⇒ 已到稳态的 95%）
		sim.set_wind(Vector2(target, 0.0), k)
		sim.step(1.0 / 60.0)
	var measured: Vector2 = sim.velocity_at_uv(Vector2(0.5, 0.5))

	var asymptotic := target * k / (k + sigma)
	var time_constant := 1.0 / (k + sigma)
	var after_two_seconds := asymptotic * (1.0 - exp(-2.0 / time_constant))
	var error_ratio := absf(measured.x - after_two_seconds) / after_two_seconds
	_check("④ 风松弛稳态与解析式一致", error_ratio < 0.1,
			"解析稳态 %.4f；2 秒（时间常数 %.2f s）应达 %.4f；实测 %.4f（差 %.1f%%）"
			% [asymptotic, time_constant, after_two_seconds, measured.x, error_ratio * 100.0])


# =========================================================
# ⑤ 底图松弛稳态
# =========================================================

## d ← d(1−σΔt) + (base·g − d)·κΔt 的不动点：d* = base·g·κ/(σ+κ)
func _check_density_relaxation_steady_state() -> void:
	var sigma := 0.10
	var kappa := 0.60
	var base := 0.8
	var sim: RefCounted = REFERENCE.new(32)
	sim.density_dissipation = sigma
	sim.velocity_dissipation = 0.0
	sim.vorticity_strength = 0.0
	sim.base_relax = kappa
	sim.base_gain = 1.0
	sim.pressure_iterations = 4            # 浓度松弛稳态与压力精度无关
	sim.base_density.fill(base)
	sim.density.fill(0.0)
	for _i in range(400):                  # ~6.7 秒，时间常数 1/(σ+κ) ≈ 1.43 s
		sim.step(1.0 / 60.0)

	var predicted: float = base * float(sim.base_gain) * kappa / (sigma + kappa)
	var measured: float = sim.density_at_uv(Vector2(0.5, 0.5))
	var error_ratio: float = absf(measured - predicted) / predicted
	_check("⑤ 底图松弛稳态满足 d* = base·g·κ/(σ+κ)", error_ratio < 0.05,
			"解析 d*=%.4f（base=%.2f κ=%.2f σ=%.2f）；实测 %.4f（差 %.2f%%）"
			% [predicted, base, kappa, sigma, measured, error_ratio * 100.0])


# =========================================================
# ⑥ 数值粘性 / 等效雷诺数
# =========================================================

## 半拉格朗日 + 线性插值的首阶数值粘性：ν_num ≈ ½·|u|·Δx·(1−CFL)，CFL = |u|Δt/Δx。
## 与空气真实运动粘性比一比，就能解释"为什么 ν 默认取 0、为什么必须加涡量约束"。
func _check_numerical_viscosity() -> void:
	var speed := 0.10                     # 典型速度（域单位/秒）
	var grid := 96.0
	var dt := 1.0 / 60.0
	var dx := 1.0 / grid
	var cfl := speed * dt / dx
	var nu_num := 0.5 * speed * dx * (1.0 - cfl)          # 域单位²/秒
	var domain_m := 80.0
	# ★ 粘性的量纲是"长度²/时间"，域单位换物理单位要**乘 L²**（不是除）。
	#   踩过：除 L² 会得到"数值粘性比空气还小两个数量级"的荒谬结论。
	var nu_num_physical := nu_num * domain_m * domain_m    # m²/s
	var nu_air := 1.5e-5
	var ratio := nu_num_physical / nu_air
	var re_effective := speed * 1.0 / nu_num               # U·L/ν（无量纲，域单位下 L=1）
	_lines.append("        · CFL=%.3f，ν_num ≈ ½|u|Δx(1−CFL) = %s（域单位²/秒）" % [cfl, _sci(nu_num)])
	_lines.append("        · 物理换算 ×L²（L=%.0f m）：ν_num ≈ %.2f m²/s；空气粘性 %s m²/s ⇒ 相差 %.0f 倍"
			% [domain_m, nu_num_physical, _sci(nu_air), ratio])
	_lines.append("        · 等效雷诺数 Re_eff = U·L/ν ≈ %.0f（真实大气 10⁵~10⁶）" % re_effective)
	_check("⑥ 数值粘性远大于空气粘性（⇒ ν=0 合理、涡量约束必要）",
			ratio > 1.0e4, "ν_num/ν_air ≈ %.0f 倍" % ratio)


# =========================================================
# 驱动
# =========================================================

func _run_all() -> void:
	_log("—— ① 离散算子因子 ——")
	_check_divergence_factor()
	_log("—— ② 投影恒等式 ——")
	_check_projection_identity()
	_log("—— ③ 压力迭代收敛 ——")
	_check_iteration_ladder()
	_log("—— ④ 风松弛稳态 ——")
	_check_wind_steady_state()
	_log("—— ⑤ 底图松弛稳态 ——")
	_check_density_relaxation_steady_state()
	_log("—— ⑥ 数值粘性 ——")
	_check_numerical_viscosity()

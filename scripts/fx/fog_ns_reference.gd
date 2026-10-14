class_name FogNsReference
extends RefCounted
## ============================================================================
## fog_ns_reference.gd —— 不可压纳维-斯托克斯方程的 **CPU 参考实现**（雾气用）
## ============================================================================
## 【职责】用最经典、最容易逐行核对的离散格式把 NS 方程解出来，作为
##   ① 自动化测试的**真值来源**（GPU 版是否写错，靠它对照）
##   ② 算法文档的可执行说明（参数含义、稳定性条件都在这里能读懂）
##   ③ 无 GPU / 无窗口环境下的降级路径（分辨率调小即可跑）
##   它**不是**运行时主路径：GDScript 逐单元循环在 64² 网格上一步就要几百毫秒，
##   游戏里跑的是 scripts/fx/fog_ns_solver.gd（GPU 片元通道版），两者共用同一套
##   离散格式（见下方"数值格式"）。
##
## 【方程】不可压 NS（Boussinesq 近似下把雾当成被动标量输运）：
##     ∂u/∂t = -(u·∇)u - ∇p + ν∇²u + f        ∇·u = 0
##     ∂d/∂t = -(u·∇)d + κ∇²d - σd + S        （d = 雾浓度，被动标量）
##   解法用 Jos Stam《Stable Fluids》(1999) 的算子分裂：
##     ① 加力 → ② 粘性扩散（可选）→ ③ 投影（压力泊松）→ ④ 半拉格朗日自输运
##     → ⑤ 涡量约束（补回数值耗散吃掉的小涡）→ ⑥ 再投影 → ⑦ 浓度输运 + 耗散
##
## 【数值格式】（GPU 版必须与此一致，否则两边结果对不上）
##   · 网格：n×n 均匀交错无关的**同位网格**，域为 [0,1]²；h = 1/n
##   · 速度单位：**域单位/秒**（u = 1 表示每秒横穿整个域一次）。
##     半拉格朗日回trace：x_cells = i - dt*n*u，与 Stam 原文一致
##     （原文用 dt0 = dt*N，速度即域单位；换成"单元/秒"会差一个 n 倍，最容易出错）
##   · 散度：div = -0.5*h*(∂u/∂x + ∂v/∂y)（中心差分，Stam 的符号约定）
##   · 压力：∇²p = div，Jacobi 迭代 p = (div + 四邻域 p) / 4
##   · 投影：u -= 0.5*(p[i+1]-p[i-1])/h，v -= 0.5*(p[j+1]-p[j-1])/h
##   · 涡量：ω = ∂v/∂x - ∂u/∂y；约束力 F = ε*(N × ω)，N = ∇|ω| / (|∇|ω|| + ε)
##   · 周期边界：所有邻域按下标环绕（wrapi / wrapf）。**不是固壁**——原因是"被风吹着走"
##     的雾必须能真的横穿整个域，而固壁 + 不可压约束在闭盒里禁止净流动，压力投影会把
##     风给的速度几乎全部抵消（GPU 端实测：目标 0.15 域单位/秒的风只剩 0.0015）。
##     周期边界的额外好处：离散散度全域求和自动为 0，压力泊松的相容性天然满足。
##
## 【对外接口】
##   · _init(size)                       建 n×n 网格（默认 32：测试用，够小够快）
##   · step(dt)                          推进一步（上面 ①~⑦）
##   · add_force(uv, radius_uv, force)   在 uv 处投一个高斯力（域单位/秒）
##   · add_density(uv, radius_uv, amount)在 uv 处投一团雾
##   · set_wind(velocity)                均匀风场（域单位/秒，全局加力）
##   · project(iterations)               只做投影（测试用它验证"投影后散度大幅下降"）
##   · max_divergence() / total_density() / density_at_uv(uv) / speed_at_uv(uv)
##   · 纯静态工具：bilinear / bilinear2 / divergence_at（GPU 版与测试共用同一套定义）
##
## 【已知的坑】
##   1. **单位**：速度是"域单位/秒"而不是"单元/秒"。所有和 n 有关的换算都在
##      advect() 里做（乘 n），别在别处再乘一次 —— 典型症状是"雾跑得飞快/几乎不动
##      且怎么调风都没用"。
##   2. Jacobi 迭代次数决定压力解的质量：次数太少则投影不干净（雾里会冒出持续的
##      涡旋/穿墙）。参考实现默认 20 次；GPU 版用"每帧若干次 + 上一帧热启动"逼近。
##   3. `dissipation` 是**每秒比例**（不是每步）：step 里按 1-dissipation*dt 缩放，
##      所以固定帧率与变帧率表现一致；dt 大于 1/dissipation 时会削到 0（有 clamp）。
##   4. 本类不创建任何节点 / 资源，纯数值；网格越大越慢（O(n²·iterations)）。
## ============================================================================

## 速度耗散（每秒比例，0 = 无耗散）。雾是"空气"的携带者，速度场不该衰减太快。
const DEFAULT_VELOCITY_DISSIPATION := 0.02
## 浓度耗散（每秒比例）：雾会自然消散，这是让画面"活"起来的关键参数之一。
const DEFAULT_DENSITY_DISSIPATION := 0.035
## 涡量约束强度（0 = 关闭）。数值耗散会把小涡抹平，加一点约束力能把细节找回来。
const DEFAULT_VORTICITY := 0.9

## 网格边长（单元数）
var n: int = 32
## 速度场 x 分量（域单位/秒）
var u: PackedFloat32Array
## 速度场 y 分量（域单位/秒）
var v: PackedFloat32Array
## 压力（中间量，投影用）
var p: PackedFloat32Array
## 散度（中间量，投影用）
var div: PackedFloat32Array
## 涡量（中间量，涡量约束用）
var curl: PackedFloat32Array
## 模拟出的雾浓度（0..1）
var density: PackedFloat32Array
## 基础雾浓度（画笔刷出来的静态层；运行时不参与输运，但参与渲染合成）
var base_density: PackedFloat32Array
## 下一步要施加的力（add_force 累积到这里，step 时统一施加后清空）
var _pending_force: PackedFloat32Array
## 下一步要投入的雾（add_density 累积）
var _pending_density: PackedFloat32Array

## 运动粘性系数 ν（0 = 无粘，雾通常取 0：粘性只会让雾更"稠"而不是更好看）
var viscosity: float = 0.0
## 浓度扩散系数 κ（0 = 只输运不扩散）
var diffusion: float = 0.0
## 压力泊松的迭代次数。40 是"质量/成本"折中：同位网格 + 紧致模板下，
## 单次投影能把中等频率散度削减一半以上（tests/test_fog_ns_reference.gd 有阶梯用例量化
## 迭代次数与残差的关系）；再往上加收益递减。GPU 版每帧做同样的次数（多趟 + 上一帧热启动）。
var pressure_iterations: int = 40
## 速度耗散 / 浓度耗散 / 涡量强度
var velocity_dissipation: float = DEFAULT_VELOCITY_DISSIPATION
var density_dissipation: float = DEFAULT_DENSITY_DISSIPATION
var vorticity_strength: float = DEFAULT_VORTICITY
## 向画笔底图松弛的速率（1/秒）。0 = 不吸附（刷出来的雾会被彻底吹散）。
## 与 GPU 版 ns_advect_density.gdshader 的 base_relax 同式：d += (base·gain − d)·κ·dt
var base_relax: float = 0.0
## 底图增益（>1 让刷出来的雾更浓）
var base_gain: float = 1.0


func _init(size: int = 32) -> void:
	_set_size(size)


## 重建网格（尺寸变化时调用；会清空所有场）。
func _set_size(size: int) -> void:
	n = maxi(8, size)
	var count := n * n
	u = _zeros(count)
	v = _zeros(count)
	p = _zeros(count)
	div = _zeros(count)
	curl = _zeros(count)
	density = _zeros(count)
	base_density = _zeros(count)
	_pending_force = _zeros(count * 2)
	_pending_density = _zeros(count)


static func _zeros(count: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(count)
	out.fill(0.0)
	return out


## 下标：i 沿 x（列）、j 沿 y（行），行优先。与 GPU 的 texel 布局一致（x=列、y=行）。
func index_of(i: int, j: int) -> int:
	return j * n + i


# =========================================================
# 一步推进
# =========================================================

## 推进一步。dt 单位秒；域单位速度下 dt 过大时回trace 会跨很多格，画质变糊但不炸
## （半拉格朗日无条件稳定，这正是选它的原因）。
func step(dt: float) -> void:
	if dt <= 0.0:
		return
	var clamped := minf(dt, 0.1)     # 帧率抖动保护：一帧最多推进 0.1 秒

	_apply_pending(clamped)
	if viscosity > 0.0:
		_diffuse_velocity(clamped)
	project(pressure_iterations)
	_advect_velocity(clamped)
	if vorticity_strength > 0.0:
		_apply_vorticity(clamped)
	project(pressure_iterations)
	_advect_density(clamped)
	_dissipate(clamped)


## 把 add_force / add_density 累积的量一次性施加（高斯核），然后清空待施加缓冲。
func _apply_pending(dt: float) -> void:
	for idx in range(n * n):
		var fx := _pending_force[idx * 2]
		var fy := _pending_force[idx * 2 + 1]
		if fx != 0.0:
			u[idx] += fx * dt
		if fy != 0.0:
			v[idx] += fy * dt
		var dd := _pending_density[idx]
		if dd != 0.0:
			density[idx] = clampf(density[idx] + dd, 0.0, 1.0)
	_pending_force.fill(0.0)
	_pending_density.fill(0.0)


## 在 uv（0..1）处加一团半径 radius_uv 的高斯力。force 单位 = 域单位/秒。
## 力是**累加**到待施加缓冲里的（同一步内多次调用取和），step 时才真正生效。
func add_force(uv: Vector2, radius_uv: float, force: Vector2) -> void:
	_splat_into(_pending_force, uv, radius_uv, Vector2(force.x, force.y), 2)
	# 高斯核里已经带了时间无关的幅度，这里乘 1/dt 的替代方案是"step 时乘 dt"——
	# 选后者（见 _apply_pending），所以参数语义是"每秒加速度"，与 friction 类的直觉一致。


## 在 uv 处投一团雾。amount 是**新增浓度**（0..1 量级），会累加后被 clamp 到 1。
func add_density(uv: Vector2, radius_uv: float, amount: float) -> void:
	_splat_into(_pending_density, uv, radius_uv, Vector2(amount, 0.0), 1)


## 均匀风场：让整域空气**趋向**目标速度（域单位/秒）。
## 实现是松弛力（force = (target - u) * strength），不是直接改写速度场：
##   · 直接改写会把已有的涡旋结构一帧抹平，雾会像被"推着走的贴纸"；
##   · 松弛力让风慢慢把流场拉过去，局部涡旋仍能存活 —— 这也是 real-time fluid 的常规做法。
## strength 单位 1/秒：越大越"硬"（≈1/strength 秒收敛），默认 2.0。
func set_wind(target_velocity: Vector2, strength: float = 2.0) -> void:
	for j in range(n):
		for i in range(n):
			var idx := index_of(i, j)
			_pending_force[idx * 2] += (target_velocity.x - u[idx]) * strength
			_pending_force[idx * 2 + 1] += (target_velocity.y - v[idx]) * strength


## 高斯核投放到任意浮点缓冲。components=2 时按 (x,y) 写两个分量，stride=2；
## components=1 时只用一个分量。这个函数被"力 / 浓度"两条路径共用，避免两份高斯定义漂移。
## ★ 两个单位坑（都踩过，且都会让效果"能跑但很怪"）：
##   1. radius_uv 是**域比例**（0..1），而 dx/dy 是**单元**坐标 —— 必须先把半径换算成
##      单元数再算 σ²。把 UV 半径直接当 σ² 用会让核缩成单个像素（exp(-1/0.02)≈0），
##      雾变成孤立方块、一输运就掉质量。
##   2. 高斯中心必须用**单元中心坐标**（uv*n - 0.5），与 uv_to_cell()/bilinear() 同一套约定。
##      少减那个 0.5 会让整个核偏半格：左右不对称、画笔落点和预览差半格。
func _splat_into(buffer: PackedFloat32Array, uv: Vector2, radius_uv: float,
		value: Vector2, components: int) -> void:
	var radius_cells := maxf(radius_uv * float(n), 0.75)
	var sigma2 := radius_cells * radius_cells
	var center := uv_to_cell(uv, n)
	var reach := int(ceilf(radius_cells * 2.5))
	var i_center := int(center.x)
	var j_center := int(center.y)
	for j in range(maxi(0, j_center - reach), mini(n - 1, j_center + reach) + 1):
		for i in range(maxi(0, i_center - reach), mini(n - 1, i_center + reach) + 1):
			var dx := float(i) - center.x
			var dy := float(j) - center.y
			var falloff := exp(-(dx * dx + dy * dy) / (2.0 * sigma2))
			if falloff < 0.001:
				continue
			var idx := index_of(i, j)
			if components == 2:
				buffer[idx * 2] += value.x * falloff
				buffer[idx * 2 + 1] += value.y * falloff
			else:
				buffer[idx] += value.x * falloff


# =========================================================
# 投影（压力泊松）
# =========================================================

## 投影：把速度场投影到无散度空间（∇·u = 0）。这是"不可压"约束的唯一执行者，
## 也是 NS 求解里最贵的一步（压力迭代）。
## ★ 周期边界下的实现比固壁简单得多：没有边界单元，所有邻域按下标环绕，
##   而且离散散度在全域上自动求和为 0 —— 压力泊松方程的相容性条件天然满足，
##   投影不会留下"消不掉的常数残差"（固壁版本里贴壁那圈单元的散度投影根本管不到，
##   残差会被那一圈顶住，表现为"迭代 2 次和 40 次的最大残差一模一样"）。
func project(iterations: int) -> void:
	var h := 1.0 / float(n)
	for j in range(n):
		for i in range(n):
			var idx := index_of(i, j)
			div[idx] = -0.5 * h * (
				u[index_of(wrapi(i + 1, 0, n), j)] - u[index_of(wrapi(i - 1, 0, n), j)]
				+ v[index_of(i, wrapi(j + 1, 0, n))] - v[index_of(i, wrapi(j - 1, 0, n))]
			)
			p[idx] = 0.0

	var iterations_used := maxi(1, iterations)
	for _k in range(iterations_used):
		for j in range(n):
			for i in range(n):
				var idx := index_of(i, j)
				p[idx] = (
					div[idx]
					+ p[index_of(wrapi(i - 1, 0, n), j)] + p[index_of(wrapi(i + 1, 0, n), j)]
					+ p[index_of(i, wrapi(j - 1, 0, n))] + p[index_of(i, wrapi(j + 1, 0, n))]
				) * 0.25

	for j in range(n):
		for i in range(n):
			var idx := index_of(i, j)
			u[idx] -= 0.5 * (p[index_of(wrapi(i + 1, 0, n), j)] - p[index_of(wrapi(i - 1, 0, n), j)]) / h
			v[idx] -= 0.5 * (p[index_of(i, wrapi(j + 1, 0, n))] - p[index_of(i, wrapi(j - 1, 0, n))]) / h


## 当前速度场的最大离散散度（|∇·u| 的 ∞ 范数，按 Stam 的符号约定）。
## 用途：测试断言"投影前很大、投影后接近 0"。
## ★ 周期边界下全域都可统计（没有"贴壁一圈由边界条件决定"的死角），
##   所以这个数字直接就是投影质量的度量。
func max_divergence() -> float:
	var h := 1.0 / float(n)
	var worst := 0.0
	for j in range(n):
		for i in range(n):
			var value := -0.5 * h * (
				u[index_of(wrapi(i + 1, 0, n), j)] - u[index_of(wrapi(i - 1, 0, n), j)]
				+ v[index_of(i, wrapi(j + 1, 0, n))] - v[index_of(i, wrapi(j - 1, 0, n))]
			)
			worst = maxf(worst, absf(value))
	return worst


## 全域速度模长之和（诊断用：投影不该显著改变总动能）。
func total_speed() -> float:
	var sum := 0.0
	for idx in range(n * n):
		sum += sqrt(u[idx] * u[idx] + v[idx] * v[idx])
	return sum


## 全域雾浓度之和（诊断用：投雾后应上升，耗散后应缓慢下降）。
func total_density() -> float:
	var sum := 0.0
	for idx in range(n * n):
		sum += density[idx]
	return sum


## 域坐标处采样模拟雾浓度（0..1）。测试用它判断"雾团有没有被风吹走"。
func density_at_uv(uv: Vector2) -> float:
	return bilinear(density, uv_to_cell(uv, n), n)


## 域坐标处采样基础雾（画笔层）浓度。
func base_density_at_uv(uv: Vector2) -> float:
	return bilinear(base_density, uv_to_cell(uv, n), n)


## 域坐标处采样速度（域单位/秒）。
func velocity_at_uv(uv: Vector2) -> Vector2:
	var cell := uv_to_cell(uv, n)
	return bilinear2(u, v, cell, n)


## 浓度分布的"重心"（域坐标）。用于断言输运方向：风吹向 +x，重心就该往 +x 走。
func density_centroid() -> Vector2:
	var total := 0.0
	var acc := Vector2.ZERO
	for j in range(n):
		for i in range(n):
			var weight := density[index_of(i, j)]
			if weight <= 0.0:
				continue
			total += weight
			acc += Vector2((float(i) + 0.5) / float(n), (float(j) + 0.5) / float(n)) * weight
	if total <= 0.0:
		return Vector2(0.5, 0.5)
	return acc / total


# =========================================================
# 输运 / 扩散 / 涡量
# =========================================================

## 半拉格朗日速度自输运：按当前位置的速度回trace 到上一时刻的出发点，双线性取值。
func _advect_velocity(dt: float) -> void:
	var source_u := u.duplicate()
	var source_v := v.duplicate()
	_advect_field(u, source_u, source_u, source_v, dt)
	_advect_field(v, source_v, source_u, source_v, dt)


## 浓度输运 + 耗散。基础雾（base_density）不参与输运：它是画笔的静态底图。
func _advect_density(dt: float) -> void:
	var source := density.duplicate()
	_advect_field(density, source, u, v, dt)


## 通用半拉格朗日输运：dest = 沿 (vel_u, vel_v) 回trace 后双线性采样的 source。
## 速度单位是**域单位/秒**，所以乘 n 换算成单元偏移（Stam 的 dt0 = dt*N）。
## ★ 周期边界：回trace 落点绕回域内，四个采样点也都按下标环绕 —— 于是
##   "雾飘出右边 -> 从左边回来"，不需要任何边界条件分支。
func _advect_field(dest: PackedFloat32Array, source: PackedFloat32Array,
		vel_u: PackedFloat32Array, vel_v: PackedFloat32Array, dt: float) -> void:
	var dt0 := dt * float(n)
	for j in range(n):
		for i in range(n):
			var idx := index_of(i, j)
			var x := wrapf(float(i) - dt0 * vel_u[idx], 0.0, float(n))
			var y := wrapf(float(j) - dt0 * vel_v[idx], 0.0, float(n))
			var i0 := int(floor(x))
			var j0 := int(floor(y))
			var s1 := x - float(i0)
			var s0 := 1.0 - s1
			var t1 := y - float(j0)
			var t0 := 1.0 - t1
			var i0w := wrapi(i0, 0, n)
			var i1w := wrapi(i0 + 1, 0, n)
			var j0w := wrapi(j0, 0, n)
			var j1w := wrapi(j0 + 1, 0, n)
			dest[idx] = (
				s0 * (t0 * source[index_of(i0w, j0w)] + t1 * source[index_of(i0w, j1w)])
				+ s1 * (t0 * source[index_of(i1w, j0w)] + t1 * source[index_of(i1w, j1w)])
			)


## 速度扩散（ν∇²u，隐式 Jacobi）。默认 ν=0（雾不需要粘性），保留是为了方程完整。
func _diffuse_velocity(dt: float) -> void:
	var a := viscosity * dt * float(n) * float(n)
	if a <= 0.0:
		return
	var cu := u.duplicate()
	var cv := v.duplicate()
	u = _jacobi_diffuse(cu, a, 4)
	v = _jacobi_diffuse(cv, a, 4)


func _jacobi_diffuse(source: PackedFloat32Array, a: float, iterations: int) -> PackedFloat32Array:
	var result := source.duplicate()
	var c := 1.0 + 4.0 * a
	for _k in range(maxi(1, iterations)):
		for j in range(n):
			for i in range(n):
				var idx := index_of(i, j)
				result[idx] = (
					source[idx]
					+ a * (
						result[index_of(wrapi(i - 1, 0, n), j)] + result[index_of(wrapi(i + 1, 0, n), j)]
						+ result[index_of(i, wrapi(j - 1, 0, n))] + result[index_of(i, wrapi(j + 1, 0, n))]
					)
				) / c
	return result


## 涡量场 ω = ∂v/∂x - ∂u/∂y（填进成员 curl）。独立成公开方法有两个用处：
##   ① 涡量约束力需要它；② 诊断/测试可以在**不施加约束力**时读涡量
##      （否则关掉 vorticity_strength 就永远算不出 curl，没法做对照实验）。
func compute_curl() -> void:
	var h := 1.0 / float(n)
	for j in range(n):
		for i in range(n):
			curl[index_of(i, j)] = 0.5 * (
				(v[index_of(wrapi(i + 1, 0, n), j)] - v[index_of(wrapi(i - 1, 0, n), j)])
				- (u[index_of(i, wrapi(j + 1, 0, n))] - u[index_of(i, wrapi(j - 1, 0, n))])
			) / h


## 涡量约束：先算 ω，再沿 |ω| 的梯度方向施加 F = ε(N × ω)。
## 目的不是"更物理"，而是补回半拉格朗日 + 有限迭代投影抹掉的小尺度涡——
## 没有它，雾会很快糊成一坨匀速平移的云。
func _apply_vorticity(dt: float) -> void:
	var h := 1.0 / float(n)
	compute_curl()
	for j in range(n):
		for i in range(n):
			var dwdx := 0.5 * (
				absf(curl[index_of(wrapi(i + 1, 0, n), j)]) - absf(curl[index_of(wrapi(i - 1, 0, n), j)])
			) / h
			var dwdy := 0.5 * (
				absf(curl[index_of(i, wrapi(j + 1, 0, n))]) - absf(curl[index_of(i, wrapi(j - 1, 0, n))])
			) / h
			var length := sqrt(dwdx * dwdx + dwdy * dwdy) + 1.0e-5
			var nx := dwdx / length
			var ny := dwdy / length
			var omega := curl[index_of(i, j)]
			# 2D 里 N × ω 退化成把 N 旋转 90°：(N.y*ω, -N.x*ω)
			var idx := index_of(i, j)
			u[idx] += vorticity_strength * ny * omega * dt
			v[idx] -= vorticity_strength * nx * omega * dt


## 耗散：速度和浓度按每秒比例衰减（乘 1-σ·dt，并 clamp 到非负）；
## 之后按 GPU 版的同一顺序做"向画笔底图松弛"（d ← d + (base·gain − d)·κ·dt）。
## ★ 顺序与 ns_advect_density.gdshader 一致：输运 → 耗散 → 松弛 → 源 → 钳位。
##   松弛放在耗散之后意味着稳态是 base·gain·κ/(σ+κ)：κ 越大越贴合底图，
##   σ 越大雾越淡 —— 两个旋钮互不遮蔽，调参时手感明确。
func _dissipate(dt: float) -> void:
	var uv_factor := clampf(1.0 - velocity_dissipation * dt, 0.0, 1.0)
	var d_factor := clampf(1.0 - density_dissipation * dt, 0.0, 1.0)
	for idx in range(n * n):
		u[idx] *= uv_factor
		v[idx] *= uv_factor
		density[idx] = clampf(density[idx] * d_factor, 0.0, 1.0)
	if base_relax > 0.0:
		var blend := clampf(base_relax * dt, 0.0, 1.0)
		for idx in range(n * n):
			var painted := base_density[idx] * base_gain
			density[idx] = clampf(density[idx] + (painted - density[idx]) * blend, 0.0, 1.0)


# =========================================================
# 纯静态工具（测试与 GPU 版共用同一套定义）
# =========================================================

## 域坐标（0..1，单元中心在 (i+0.5)/n）转单元坐标。
static func uv_to_cell(uv: Vector2, n_value: int) -> Vector2:
	return Vector2(uv.x * float(n_value) - 0.5, uv.y * float(n_value) - 0.5)


## 单通道场的双线性采样（单元坐标为参数，越界按 clamp-to-edge 处理）。
static func bilinear(field: PackedFloat32Array, cell: Vector2, n_value: int) -> float:
	var x := clampf(cell.x, 0.0, float(n_value) - 1.0)
	var y := clampf(cell.y, 0.0, float(n_value) - 1.0)
	var i0 := int(floor(x))
	var j0 := int(floor(y))
	var i1 := mini(i0 + 1, n_value - 1)
	var j1 := mini(j0 + 1, n_value - 1)
	var fx := x - float(i0)
	var fy := y - float(j0)
	var v00 := field[j0 * n_value + i0]
	var v10 := field[j0 * n_value + i1]
	var v01 := field[j1 * n_value + i0]
	var v11 := field[j1 * n_value + i1]
	return lerpf(lerpf(v00, v10, fx), lerpf(v01, v11, fx), fy)


## 双通道场（速度）的双线性采样。
static func bilinear2(field_x: PackedFloat32Array, field_y: PackedFloat32Array,
		cell: Vector2, n_value: int) -> Vector2:
	return Vector2(
		bilinear(field_x, cell, n_value),
		bilinear(field_y, cell, n_value)
	)


## 单个单元处的离散散度（与 project() 内部同式，供测试逐点核对）。邻域按周期边界环绕。
static func divergence_at(field_u: PackedFloat32Array, field_v: PackedFloat32Array,
		i: int, j: int, n_value: int) -> float:
	var h := 1.0 / float(n_value)
	return -0.5 * h * (
		field_u[j * n_value + wrapi(i + 1, 0, n_value)]
		- field_u[j * n_value + wrapi(i - 1, 0, n_value)]
		+ field_v[wrapi(j + 1, 0, n_value) * n_value + i]
		- field_v[wrapi(j - 1, 0, n_value) * n_value + i]
	)

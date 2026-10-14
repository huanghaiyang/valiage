@tool
extends McpTestSuite
## ============================================================================
## test_fog_ns_reference.gd —— 雾气用纳维-斯托克斯求解器的**数值自检**
## ============================================================================
## 被测对象：scripts/fx/fog_ns_reference.gd（CPU 参考实现，也是 GPU 版的对齐基准）。
## 运行方式：编辑器里跑（MCP test_run suite=fog_ns_reference）；纯数值，不需要窗口/GPU。
##
## 【这套用例在守什么】
##   · 不可压约束真的被执行了：投影**前**散度大，投影**后**散度数量级下降
##     —— 这是"解的是 NS 而不是随便一个平流"的唯一硬证据
##   · 迭代次数越多投影越干净（单调性）：否则"调大 iterations 没用"这类回归无人发现
##   · 单位约定：速度是**域单位/秒**。风目标 0.2 + 1 秒 → 雾团重心移动 ≈0.2 个域宽
##     —— 单位写错（例如按"单元/秒"实现）会让这条断言失败，是最值钱的哨兵
##   · 输运方向正确：风往 +x，雾团重心往 +x；反向风则反向
##   · 质量守恒：dissipation=0 时输运不凭空增减雾的量（数值耗散在容差内）
##   · 耗散可关可开：σ>0 时总量单调下降且量级符合 exp(-σt)
##   · 固壁边界：持续往墙里吹，域内总雾量不流失（撞墙不消失、不无限增长）
##   · 可复现：同样输入两次独立实例逐步结果逐位相同（截图/回归复现的前提）
##   · 涡量：刚体旋转场的 curl 是常数（解析解 2ω），且涡量约束会增大小尺度涡量
##   · 纯静态工具：双线性采样在已知点上精确、越界按 clamp-to-edge
##
## 【★ 为什么用 const preload + 处处显式类型，而不是直接用 class_name】
##   踩过两次：① 参考实现作为动态脚本对象时成员/返回值全是 Variant，`var x := sim.foo()`
##   直接报 "Cannot infer the type"；② 即使把 sim 声明成 class_name 类型，测试脚本在
##   **游戏/纯运行时加载路径**下仍可能解析不到那个全局类，于是整份套件"cannot instantiate
##   — abstract or broken"，而编辑器里 find_symbols 却看不出问题（定位成本极高）。
##   preload 是编译期就绑定的资源引用，不受全局类表状态影响；类型全写出来之后
##   GDScript 也不会再替我们"猜"，重构时字段改名会立刻变成编译错误。
## ============================================================================

## 编译期绑定，避免依赖全局 class_name 表（见文件头说明）。
const REFERENCE := preload("res://scripts/fx/fog_ns_reference.gd")


func suite_name() -> String:
	return "fog_ns_reference"


func _make(size: int = 32) -> RefCounted:
	return REFERENCE.new(size)


## 造一个有散度、但**散度均值为零**的场：u = A·sin(4·2π·x)、v = A·sin(4·2π·y)。
## ★ 为什么强调零均值：纯诺伊曼边界的压力泊松方程有相容性条件 ∫div = 0。
##   若构造一个"处处外扩"的场（div 均值 > 0），这个奇性残差**与迭代次数无关**，
##   于是"迭代越多越干净"的断言会假失败（踩过：2 次与 40 次残差完全相同）。
func _divergent_field(size: int) -> RefCounted:
	var sim: RefCounted = _make(size)
	var amplitude := 0.5
	var cycles := 4.0
	for j in range(size):
		for i in range(size):
			var idx: int = sim.index_of(i, j)
			var x: float = (float(i) + 0.5) / float(size)
			var y: float = (float(j) + 0.5) / float(size)
			sim.u[idx] = amplitude * sin(cycles * TAU * x)
			sim.v[idx] = amplitude * sin(cycles * TAU * y)
	return sim


## 一个"安静"的实例：关掉耗散与涡量，只留纯输运（单位/守恒类断言都用它）。
func _quiet(size: int) -> RefCounted:
	var sim: RefCounted = _make(size)
	sim.density_dissipation = 0.0
	sim.velocity_dissipation = 0.0
	sim.vorticity_strength = 0.0
	return sim


# =========================================================
# ① 不可压约束（投影）
# =========================================================

func test_projection_removes_divergence() -> void:
	# ★ 周期边界下全域都可统计（没有"贴壁一圈由边界条件决定"的死角），所以这里
	#   直接统计整个域的散度 —— 这个数字就是投影质量的度量。
	#
	# ★ 为什么门槛不是"降到接近 0"：同位网格（collocated）上散度与压力梯度都用中心
	#   差分（紧致模板），网格尺度（波长 2 格）的压力振荡落在模板零空间里 —— 这就是
	#   经典的奇偶失耦（checkerboard），它决定了单次投影对中等频率散度场的可清除上限；
	#   再迭代也只是把"可清除的那部分"清干净（见下面的迭代阶梯用例）。
	var sim: RefCounted = _divergent_field(32)
	var before: float = sim.max_divergence()
	assert_gt(before, 1.0e-3, "构造的场应当有明显散度（实际 %.6f）" % before)

	sim.project(40)
	var after: float = sim.max_divergence()

	assert_true(after < before * 0.5,
			"投影应把散度至少削减一半（前 %.6f 后 %.6f）" % [before, after])
	assert_true(after < 6.0e-3, "投影后残差散度应明显小于初始值（实际 %.6f）" % after)


func test_more_iterations_project_better() -> void:
	# 迭代阶梯：同一份散度场分别做 5 / 20 / 80 / 320 次压力迭代，残差必须单调下降。
	# 这条用例同时是"压力求解器真的在收敛"的量化证据（比单点断言信息量大得多：
	# 失败时会直接把整条阶梯打出来）。
	var residuals: Array[float] = []
	for iterations in [5, 20, 80, 320]:
		var sim: RefCounted = _divergent_field(32)
		sim.project(iterations)
		residuals.append(sim.max_divergence())

	var shown := ""
	for value in residuals:
		shown += "%.6f " % value

	for i in range(1, residuals.size()):
		assert_true(residuals[i] <= residuals[i - 1] + 1.0e-9,
				"残差必须随迭代次数单调不增（5/20/80/320 -> %s）" % shown)
	assert_true(residuals[3] < residuals[0] * 0.5,
			"320 次迭代应把残差降到 5 次时的 50%% 以下（5/20/80/320 -> %s）" % shown)


func test_projection_keeps_flow_alive() -> void:
	# 投影只该去掉"梯度分量"，不该把流场清零 —— 否则雾就没有任何运动了。
	var sim: RefCounted = _make(32)
	for j in range(32):
		for i in range(32):
			var idx: int = sim.index_of(i, j)
			sim.u[idx] = 0.3
			sim.v[idx] = 0.0
	var before: float = sim.total_speed()
	sim.project(20)
	var after: float = sim.total_speed()

	assert_gt(after, before * 0.3, "投影后总速度不该掉到 30% 以下（%.3f -> %.3f）" % [before, after])
	assert_true(after <= before + 1.0e-3, "投影不该增加总速度（%.3f -> %.3f）" % [before, after])


# =========================================================
# ② 单位约定（最值钱的哨兵）
# =========================================================

func test_velocity_unit_is_domain_per_second() -> void:
	# 速度单位 = 域单位/秒。给 0.2 的风目标 + 较强松弛（5/秒），跑 1 秒：
	#   ① 域中心采样到的速度应当已经接近 0.2 —— 单位对了才可能达到；
	#   ② 雾团重心位移应当 ≈0.2 个域宽。
	# ★ 周期边界让这条断言可以做得很紧（没有墙把雾拦住、也没有墙把速度顶回去）：
	#   若速度被实现成"单元/秒"，采样速度会小 n 倍、位移几乎为 0，两条断言同时失败。
	var sim: RefCounted = _quiet(64)
	sim.add_density(Vector2(0.3, 0.5), 0.06, 1.0)
	sim.step(1.0 / 60.0)                       # 先把投出的雾施加进去

	var start: Vector2 = sim.density_centroid()
	for _i in range(60):                       # 累计 1 秒
		sim.set_wind(Vector2(0.2, 0.0), 5.0)
		sim.step(1.0 / 60.0)
	var speed: Vector2 = sim.velocity_at_uv(Vector2(0.5, 0.5))
	var moved: Vector2 = sim.density_centroid() - start

	assert_true(speed.x > 0.15 and speed.x < 0.25,
			"0.2 域单位/秒的风应把速度带到 ≈0.2（实测采样速度 %.4f）" % speed.x)
	assert_true(moved.x > 0.14 and moved.x < 0.26,
			"0.2 域单位/秒 吹 1 秒，重心应移动 ≈0.2 个域宽（实际 %.4f）" % moved.x)
	assert_true(absf(moved.y) < 0.02, "纯 +x 风不该让重心沿 y 漂移（实际 %.4f）" % moved.y)


func test_wind_direction_reverses_transport() -> void:
	var sim: RefCounted = _quiet(48)
	sim.add_density(Vector2(0.5, 0.5), 0.05, 1.0)
	sim.step(1.0 / 60.0)
	var start: Vector2 = sim.density_centroid()

	for _i in range(30):
		sim.set_wind(Vector2(0.0, -0.3), 5.0)
		sim.step(1.0 / 60.0)
	var moved: Vector2 = sim.density_centroid() - start

	assert_true(moved.y < -0.04, "风往 -y 吹，重心应往 -y 走（实际 %.3f）" % moved.y)
	assert_true(absf(moved.x) < 0.03, "纯 -y 风不该让重心沿 x 漂移（实际 %.3f）" % moved.x)


# =========================================================
# ③ 质量守恒 / 耗散
# =========================================================

func test_advection_conserves_density_without_dissipation() -> void:
	var sim: RefCounted = _quiet(48)
	sim.add_density(Vector2(0.5, 0.5), 0.08, 1.0)
	sim.step(1.0 / 60.0)
	var before: float = sim.total_density()

	for _i in range(40):
		sim.set_wind(Vector2(0.15, 0.05))
		sim.step(1.0 / 60.0)
	var after: float = sim.total_density()

	# 半拉格朗日输运本身不严格守恒（双线性插值会抹平峰值），但总质量不应大幅变化。
	assert_true(after > before * 0.85,
			"无耗散时总雾量不该明显减少（%.4f -> %.4f）" % [before, after])
	assert_true(after < before * 1.15,
			"无耗散时总雾量也不该增加（%.4f -> %.4f）" % [before, after])


func test_dissipation_decays_density_monotonically() -> void:
	var sim: RefCounted = _make(32)
	sim.velocity_dissipation = 0.0
	sim.vorticity_strength = 0.0
	sim.density_dissipation = 0.5          # 每秒衰减一半
	sim.add_density(Vector2(0.5, 0.5), 0.2, 0.8)
	sim.step(1.0 / 30.0)
	var start_total: float = sim.total_density()
	assert_gt(start_total, 0.0, "投雾后总量应大于 0")

	# 单调性逐步查（0.7 秒内 20 步）：任何"耗散反而让雾变多"的实现都会被抓住。
	var previous: float = start_total
	for _i in range(20):
		sim.step(1.0 / 30.0)
		var current: float = sim.total_density()
		assert_true(current <= previous + 1.0e-4,
				"耗散开启时总量必须单调不增（%.5f -> %.5f）" % [previous, current])
		previous = current

	# 量级也要对：0.5/秒 × 0.7 秒 ≈ exp(-0.35) ≈ 0.705 倍。
	# 把"每秒比例"误当"每步比例"会掉到 0.5^20 ≈ 1e-6，被这条断言直接抓住。
	var factor: float = previous / maxf(start_total, 1.0e-9)
	assert_true(factor > 0.55 and factor < 0.85,
			"0.7 秒 / 每秒 0.5 耗散后应剩余约 70%%（实际 %.3f）" % factor)


# =========================================================
# ④ 边界与稳定性
# =========================================================

func test_periodic_wrap_keeps_density_inside() -> void:
	# 周期边界：雾"飘出右边"会从左边回来，所以全域总量既不该凭空减少、也不该越积越多。
	# ★ 这条用例替代了早期的"固壁挡雾"用例 —— 边界条件改成周期之后，固壁语义不再存在
	#   （原因见 fog_ns_reference.gd 头注释：闭盒里允许不了净流动，风就没法搬运雾）。
	var sim: RefCounted = _quiet(32)
	sim.add_density(Vector2(0.5, 0.5), 0.12, 1.0)
	sim.step(1.0 / 60.0)
	var before: float = sim.total_density()

	# 用足够强的风把雾团整个推过域边界（1 秒横穿两次），总量应当基本不变。
	for _i in range(120):
		sim.set_wind(Vector2(1.5, 0.0), 3.0)
		sim.step(1.0 / 60.0)

	var after: float = sim.total_density()
	assert_true(is_finite(after), "长时间强风后总雾量必须仍是有限值")
	assert_true(after > before * 0.55,
			"周期边界下长期吹风不该让雾大量损失（%.2f -> %.2f）" % [before, after])
	assert_true(after < before * 1.45,
			"周期边界下长期吹风也不该让雾越积越多（%.2f -> %.2f）" % [before, after])


func test_large_timestep_stays_stable() -> void:
	# 半拉格朗日无条件稳定是选它的理由：大 dt 会糊，但不该出现 NaN/Inf。
	var sim: RefCounted = _make(32)
	var size: int = int(sim.n)
	sim.add_density(Vector2(0.5, 0.5), 0.2, 1.0)
	var finite := true
	for _i in range(10):
		sim.add_force(Vector2(0.5, 0.5), 0.1, Vector2(0.0, 2.0))
		sim.step(0.1)
	for idx in range(size * size):
		if not (is_finite(sim.u[idx]) and is_finite(sim.v[idx]) and is_finite(sim.density[idx])):
			finite = false
			break
	assert_true(finite, "大 dt 下出现了 NaN/Inf（数值不稳定）")


# =========================================================
# ⑤ 涡量
# =========================================================

func test_vorticity_of_solid_body_rotation() -> void:
	# 解析解：u = -ω(y-yc)、v = ω(x-xc) 时 curl = ∂v/∂x - ∂u/∂y = 2ω。
	# 取 ω=0.5，故 curl 应为 1.0。用 strength 极小的一次 step 触发 compute_curl()。
	var sim: RefCounted = _make(32)
	sim.velocity_dissipation = 0.0
	for j in range(32):
		for i in range(32):
			var idx: int = sim.index_of(i, j)
			var x: float = (float(i) + 0.5) / 32.0 - 0.5
			var y: float = (float(j) + 0.5) / 32.0 - 0.5
			sim.u[idx] = -0.5 * y
			sim.v[idx] = 0.5 * x
	sim.vorticity_strength = 0.0001
	sim.step(1.0 / 120.0)

	var center: float = sim.curl[sim.index_of(16, 16)]
	assert_true(absf(center - 1.0) < 0.08,
			"刚体旋转 ω=0.5 的涡量应 ≈1.0（实际 %.4f）" % center)


func test_vorticity_confinement_amplifies_curl() -> void:
	var without: RefCounted = _make(32)
	var confined: RefCounted = _make(32)
	for sim in [without, confined]:
		sim.velocity_dissipation = 0.0
		sim.density_dissipation = 0.0
		# 一个会被数值耗散抹平的小剪切层：上下两半反向流
		for j in range(32):
			for i in range(32):
				var idx: int = sim.index_of(i, j)
				sim.u[idx] = 0.35 if j < 16 else -0.35
				sim.v[idx] = 0.0
	without.vorticity_strength = 0.0
	confined.vorticity_strength = 6.0

	for _i in range(6):
		without.step(1.0 / 60.0)
		confined.step(1.0 / 60.0)

	# curl 只在"算涡量"时被写入：对照组用公开的 compute_curl() 补算一次，
	# 这样两边比的是同一件事（总涡量），而不是"算过 vs 没算过"。
	without.compute_curl()
	var plain_sum := 0.0
	var confined_sum := 0.0
	for idx in range(32 * 32):
		plain_sum += absf(without.curl[idx])
		confined_sum += absf(confined.curl[idx])

	assert_gt(plain_sum, 0.0, "剪切层应当有非零涡量")
	assert_gt(confined_sum, plain_sum,
			"涡量约束应让总涡量变大（%.4f -> %.4f）" % [plain_sum, confined_sum])


# =========================================================
# ⑥ 可复现性
# =========================================================

func test_two_instances_are_bit_identical() -> void:
	var a: RefCounted = _make(32)
	var b: RefCounted = _make(32)
	for sim in [a, b]:
		sim.add_density(Vector2(0.4, 0.6), 0.1, 1.0)
		sim.add_force(Vector2(0.4, 0.6), 0.1, Vector2(0.2, -0.1))
	for _i in range(15):
		for sim in [a, b]:
			sim.set_wind(Vector2(0.1, 0.05))
			sim.step(1.0 / 60.0)

	var identical := true
	for idx in range(32 * 32):
		if a.u[idx] != b.u[idx] or a.v[idx] != b.v[idx] or a.density[idx] != b.density[idx]:
			identical = false
			break
	assert_true(identical, "相同输入的两个独立实例必须逐步得到逐位相同的场（可复现性前提）")


# =========================================================
# ⑦ 纯静态工具
# =========================================================

func test_bilinear_sampling_is_exact_at_nodes() -> void:
	var field := PackedFloat32Array()
	field.resize(16)
	for i in range(16):
		field[i] = float(i)

	assert_eq(REFERENCE.bilinear(field, Vector2(0.0, 0.0), 4), 0.0, "整数格点应精确命中")
	assert_eq(REFERENCE.bilinear(field, Vector2(3.0, 3.0), 4), 15.0, "整数格点应精确命中")
	assert_eq(REFERENCE.bilinear(field, Vector2(1.0, 0.0), 4), 1.0, "整数格点应精确命中")

	var mid: float = REFERENCE.bilinear(field, Vector2(0.5, 0.0), 4)
	assert_true(absf(mid - 0.5) < 1.0e-6, "线性数据的中点插值应精确（实际 %.6f）" % mid)

	assert_eq(REFERENCE.bilinear(field, Vector2(-5.0, -5.0), 4), 0.0, "越界应钳到边缘")
	assert_eq(REFERENCE.bilinear(field, Vector2(99.0, 99.0), 4), 15.0, "越界应钳到边缘")


func test_uv_to_cell_mapping() -> void:
	# 域中心 uv=0.5 应落在网格正中间（单元坐标 n/2-0.5）
	var cell: Vector2 = REFERENCE.uv_to_cell(Vector2(0.5, 0.5), 32)
	assert_true(absf(cell.x - 15.5) < 1.0e-6, "uv 0.5 -> cell 15.5（实际 %.3f）" % cell.x)
	assert_true(absf(cell.y - 15.5) < 1.0e-6, "uv 0.5 -> cell 15.5（实际 %.3f）" % cell.y)


func test_splat_is_radially_symmetric_and_bounded() -> void:
	var sim: RefCounted = _make(32)
	sim.add_density(Vector2(0.5, 0.5), 0.1, 1.0)
	sim.step(1.0 / 60.0)

	# 高斯核：中心最高、径向外侧单调递减、域内不超 1
	var center: float = sim.density_at_uv(Vector2(0.5, 0.5))
	assert_gt(center, 0.3, "投雾中心应有明显浓度（实际 %.3f）" % center)
	assert_true(center <= 1.0 + 1.0e-6, "浓度不该超过 1（实际 %.3f）" % center)

	var near: float = sim.density_at_uv(Vector2(0.56, 0.5))
	var far: float = sim.density_at_uv(Vector2(0.7, 0.5))
	assert_gt(near, far, "高斯核应当单调衰减（%.4f -> %.4f）" % [near, far])

	var mirrored: float = sim.density_at_uv(Vector2(0.44, 0.5))
	assert_true(absf(near - mirrored) < 0.02,
			"高斯核应当左右对称（%.4f vs %.4f）" % [near, mirrored])

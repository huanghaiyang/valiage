extends "res://scripts/spells/flame_scorch.gd"
## 火焰推进 —— 扇形、波浪式推进的一次性火焰法术。
##
## 【和【火焰灼烧】的关系】**继承**它：伤害、火焰簇池、贴地光斑、植被燃烧、
##   数值表读取全部复用（需求 3/5 "受火焰灼烧的地方单位扣血与火焰灼烧一致"）。
##   只覆盖两件事：
##     ① _spawn_patches()：把"铺满圆盘"改成"按扇形采样"，并给每簇火记录
##        它到角色的**波前距离 kd（0=脚边，1=扇形最远处）**。
##     ② _apply_grow()：每簇火**各自**计时 —— 波前到达才出现，出现后各自活
##        burn_time 秒再淡出（需求 4：最早生成的火焰最早消失）。
##
## 【波浪推进】波前按 kd 走：k 簇火在 t >= kd*advance_time 时开始生成。
##   advance_time 由张角决定（45° -> 1.0s，80° -> 0.6s，线性插值，来自数值表）。
##
## 【为什么把总时长延长】基类的状态机按 burn_time 结束（并 _hide_all）。
##   最后一簇火比第一簇晚 advance_time 秒生成，又各自活 burn_time 秒，
##   所以总时长要 +advance_time，否则末尾的火焰会被提前收掉。
##   副作用：整体灼烧窗口也长了 advance_time（0.6~1.0s）—— 这是**正确**的，
##   因为"火还在烧"就该继续扣血；每秒扣血量与火焰灼烧完全一致。

const SHEET_ID_NEW := "flame_advance"

var sector_axis := 0.0
var sector_half := 0.785
var advance_time := 1.0
var _wave_t := 0.0                   ## 施法后的波浪时钟
var _kd: Array[float] = []           ## 每簇火的波前距离 0..1（已归一化）
var _pending_veg: Array = []         ## 等波前到达才点燃的植被 [{n, i, kd}]
var _wave_report := 0.0              ## 波前日志节流
## ★ 布点内圈半径（米）：角色前留出这段距离再开始摆火（**最小值**，实际见 place_inner_gap_m）
@export var place_inner_m := 0.5
## ★ **角色脚底留白**（米）：任何火焰簇的**外缘**都要离角色至少这么远。
##   用户反馈"最好角色脚底不要生成火焰"——原来内圈半径只有 0.5~0.68m，
##   而一簇火自己会向中心伸出 **~2.8m**（16 张 ~2m 宽的焰卡围成一团；
##   焰卡的网格原点离簇心最远有 ~2.9 个场景单位、再乘 pscale），
##   实测最近的一张卡离角色只有 **0.10m**（火直接烧在脚上）。
##   所以内圈半径 = 这一簇火的**实际水平伸距** + 这个留白
##   外缘离角色 0.5m（用户：先要"脚底不要有火"，后又要"别离太远"）。
@export var place_inner_gap_m := 0.5
## ★ 火焰簇的**实际半径** ≈ patch_footprint × 该系数。
##   焰卡与核心辉光铺得比 patch_footprint 更开，系数取小了会导致
##   "贴边那几簇溢出到扇区外"（用户实测：扇形周边有多余火焰）。
@export var cluster_radius_scale := 1.6
## ★ 扇形里簇的整体缩放（越小越不容易溢出，但火会显得稀）
@export var place_scale := 0.7
## 摆放朝向的三种模式
## ★ 注意：**真正决定"大面朝哪"的是逐卡 yaw**，不是下面这些模式本身 ——
##   焰卡生成时 yaw 是随机的（fire_burst.random_yaw），只转特效根节点改不了朝向
##   （实测：只转根节点时，边界簇的大面对齐度只有 0.58 ≈ 随机）。
##   这些模式现在只用来：① 给"内部填充"挑一个基准径向（带抖动 -> 体积感）；
##   ② 把簇内的卡片摆布转一下（位置分布）。真正的朝向见 _face_dir_for() +
##   fire_burst.face_cards_to()。
const ORIENT_FILL := 0        ## 内部填充：径向 + 抖动（薄片离散 -> 体积感）
const ORIENT_TO_CASTER := 1   ## **圆弧处**：大面朝**角色**（逐卡法线 = −径向）
const ORIENT_TO_AXIS := 2     ## **两边**：大面朝**扇形中轴线**（逐卡法线 = 指向中轴垂足）
## ★ 边界圈是否按上面两种定向（关掉就退回"随机朝向"）
@export var boundary_face_inward := true
## ★ 火焰簇朝向抖动（度）：**只用在内部填充**上。
##   薄片方向一致时，从某些角度会整片侧着看（又薄又碎），所以内部保持离散度 -> 体积感。
@export var place_yaw_jitter_deg := 40.0
## ★ 朝向基础偏转（度）。若发现"大面朝外"了，设成 180 即可翻转法线。
@export var place_yaw_offset_deg := 0.0
## ★ **边界圈焰卡的逐卡抖动**（度）。0 = 完全整齐（一堵墙，但从侧面看整片侧过去）；
##   默认 10°：每张卡在目标方向左右各偏 ±10°，而簇的**面积加权大面**仍然精确
##   朝向目标（抖动对称抵消）—— 既满足"最大面朝向中轴线/角色"，又不会侧着看时消失。
@export var boundary_jitter_deg := 10.0


func has_targeting() -> bool:
	var tg: Dictionary = SHEET.get_spell(SHEET_ID_NEW).get("targeting", {})
	return bool(tg.get("enabled", false))


func targeting_config() -> Dictionary:
	return SHEET.get_spell(SHEET_ID_NEW).get("targeting", {})


## ★ 覆盖基类的"圆内判定"：扇形法术里，**圆内还要在扇区内**才算。
##   基类用它筛植被（_find_vegetation -> _node_touches_circle），
##   不覆盖的话整圈草都会被烧黑 —— 实测症状就是"最终效果不是扇形，而是一圈圆的焦痕"。
func _node_touches_circle(n: Node3D) -> bool:
	if n is MultiMeshInstance3D:
		var hit := _mm_scan_circle(n as MultiMeshInstance3D, _center, _radius)
		for h in hit:
			if _in_sector(h["w"] as Vector3):
				return true
		return false
	return _in_sector(n.global_position)


## ★ 覆盖：逐实例燃烧只烧**扇区内**的实例（基类只按圆筛 -> 会烧黑整圈草）
func _burn_instance_indices(mmi: MultiMeshInstance3D) -> Array:
	var ids: Array = []
	for h in _mm_scan_circle(mmi, _center, _radius):
		if _in_sector(h["w"] as Vector3):
			ids.append(int(h["i"]))
	return ids


## ★ 覆盖：每实例的点燃延迟按"离角色的距离"给 -> 草按波前依次烧起来
##   （不覆盖的话基类不给延迟、控制器用随机错开，观感是"整片一起黑"）
func _burn_instance_delays(mmi: MultiMeshInstance3D) -> Array:
	var out: Array = []
	for h in _mm_scan_circle(mmi, _center, _radius):
		var w: Vector3 = h["w"]
		if not _in_sector(w):
			continue
		var d := Vector2(w.x - _center.x, w.z - _center.z).length()
		out.append(clampf(d / maxf(_radius, 0.01), 0.0, 1.0) * advance_time)
	return out


## 世界坐标是否落在扇形内（半径 + 张角双重判定）
func _in_sector(w: Vector3) -> bool:
	var d := Vector2(w.x - _center.x, w.z - _center.z)
	if d.length() > _radius:
		return false
	if d.length() < 0.0001:
		return true
	var dd := wrapf(atan2(d.y, d.x) - sector_axis, -PI, PI)
	return absf(dd) <= sector_half


## 诊断：确认扇形参数真的传进来了（否则会退回基类的整圆布点）
@export var debug_sector := true


## 扇形施法：center = 角色位置，radius = 扇形半径，axis = 中轴弧度，half = 半角弧度
func cast_sector(center: Vector3, radius: float, axis: float, half: float) -> void:
	# ★ 防御：扇形**必须以角色为起点**。若选点器给的中心不是角色（例如它还在圆盘模式、
	#   圆心跟着鼠标），这里直接改回角色位置 —— 否则扇形会从鼠标处长出来，不成扇面。
	var org := center
	if _player != null and is_instance_valid(_player):
		var pp := _player.global_position
		org = Vector3(pp.x, center.y, pp.z)
	sector_axis = axis
	sector_half = maxf(half, 0.05)
	# 推进时间按张角插值（45° -> 1.0s，80° -> 0.6s）
	var tg: Dictionary = targeting_config()
	var a_min := float(tg.get("angle_min", 45.0))
	var a_max := float(tg.get("angle_max", 80.0))
	var t_min := float(tg.get("advance_time_at_min", 1.0))
	var t_max := float(tg.get("advance_time_at_max", 0.6))
	var deg := rad_to_deg(sector_half) * 2.0
	var span := a_max - a_min
	var k := 0.0 if absf(span) < 0.0001 else clampf((deg - a_min) / span, 0.0, 1.0)
	advance_time = lerpf(t_min, t_max, k)
	_wave_t = 0.0
	# ★ 总时长加上推进时间：最后一簇火要活满自己的 burn_time（见文件头说明）
	burn_time = float(SHEET.get_spell(SHEET_ID_NEW).get("duration", 8.0)) + advance_time
	if debug_sector:
		print("[火焰推进] 半径 %.1fm | 张角 %.0f度(半角 %.1f度) | 中轴 %.1f度 | 推进 %.2fs | 总时长 %.2fs" % [
				radius, rad_to_deg(sector_half) * 2.0, rad_to_deg(sector_half),
				rad_to_deg(sector_axis), advance_time, burn_time])
	cast_at(org, radius)


func start_cast() -> void:
	super.start_cast()


func _process(delta: float) -> void:
	if casting:
		_wave_t += delta
		_ignite_pending()
	super._process(delta)


## ★ 覆盖：不在施法瞬间点燃植被，只**登记**（波前到达时才点燃）
##   否则远处的草在火到之前就已经黑了（用户 #4）
func _ignite_vegetation() -> void:
	_pending_veg.clear()
	var i := 0
	for t in _find_vegetation():
		if not (t is Node3D):
			continue
		var n := t as Node3D
		var d := Vector2(n.global_position.x - _center.x, n.global_position.z - _center.z).length()
		_pending_veg.append({"n": n, "i": i,
				"kd": clampf(d / maxf(_radius, 0.01), 0.0, 1.0)})
		i += 1
	if debug_sector:
		print("[火焰推进] 待点燃植被 %d 个（波前到达时才点）" % _pending_veg.size())


## 波前每推进一点，就点燃它经过的植被
func _ignite_pending() -> void:
	if _pending_veg.is_empty():
		return
	var left: Array = []
	for e in _pending_veg:
		if float(e["kd"]) * advance_time <= _wave_t:
			_ignite_one(e["n"] as Node3D, int(e["i"]))
		else:
			left.append(e)
	_pending_veg = left


## ★ 覆盖：扇形内采样 + 记录波前距离（原版是铺满圆盘）
func _spawn_patches() -> void:
	# 保险：万一没走 cast_sector（例如被别的入口直接 cast_at），
	# 也不能退回基类的"铺满整圆"—— 那样最终效果就不是扇形了。
	if sector_half <= 0.001:
		var tg0: Dictionary = targeting_config()
		sector_half = deg_to_rad(float(tg0.get("angle_min", 45.0))) * 0.5
	_area_area_prepare()
	var area := 0.5 * (2.0 * sector_half) * _radius * _radius     # 扇形面积
	# ★ 扇形要用**更密**的簇：基类按 area/6 算，45°×10m 只有 6~7 簇，
	#   10 米宽的扇面里 7 簇火看着就是"稀疏一团"，填不满也看不出扇面形状。
	#   这里按 area/2.6 算并把下限提到 10（用户要求：整团火看起来就是个扇面）。
	var want := int(round(area / 2.6))
	want = clampi(want, 10, 28)
	_ensure_pool(want)
	_used = want
	_kd.clear()
	var pscale := clampf(_radius / 6.0, 0.45, 1.0) * fire_scale * place_scale
	var fp := patch_footprint * pscale
	var fit := maxf(_radius - fp, 0.0)
	var placed := 0
	# ★ 单簇火的**实际**半径：焰卡/核心铺开比 patch_footprint 大，按系数放宽，
	#   否则角度余量算小了 -> 贴边的簇会溢出扇区（用户："扇形周边有多余火焰"）
	var cluster_r := fp * cluster_radius_scale
	# ★ 角色脚底留白（用户反馈：先"不要烧在脚上"，再"火焰生成距离角色过远"）：
	#   留白 = 火焰外缘离角色多远。**必须按这一簇"实际"伸出多少来算**，不能用保守上界：
	#   上界（逐级位置长度相加 + 最坏横向倍率）实测比真实伸距大 0.8~1.0m，
	#   结果火被推得老远（用户："火焰生成距离角色过远"）。
	#   做法改成**两遍布点**：① 先按名义半径摆一遍 -> ② 量每簇实际伸距，
	#   取最大值 + 留白当作最内侧半径，整体重映射再摆一遍（重映射保证不会挤成一团）。
	var r_in := maxf(clampf(place_inner_m, 0.5, 6.0), cluster_r * 0.5)
	if r_in > fit:
		r_in = maxf(fit * 0.5, 0.0)         # 扇形太小（留白占满）时只能退让
	# ================================================================
	# 布点（用户建议）：**先用边界圈把扇形钉出来，再填内部**
	#   ① 两条边：角度**锁定**在边线内侧一个簇角宽处 -> 火焰外缘正好压在边线上
	#   ② 外弧：半径锁在 fit，角度在边线内侧铺开
	#   ③ 内部：剩下的簇按环填满扇形
	#   所有簇朝向都沿**径向**，波前距离按半径给（推进仍然由近及远）
	# ================================================================
	# ★ 簇预算：边界圈优先（两条边 + 外弧 = 扇面的轮廓），剩下的才填内部
	var edge_n := maxi(3, int(round(float(want) * 0.22)))     # 每条边上的簇数
	var arc_n := maxi(5, int(round(float(want) * 0.32)))      # 外弧上的簇数
	# ★ 留白重映射的基准：名义分布里**最内侧**那一簇的半径（边圈第一簇用 0.5/edge_n 的分数）
	var r_min_nom := lerpf(r_in, fit, 0.5 / float(edge_n))
	# ================================================================
	# 先把"该摆哪些簇、摆在哪个角度/半径"排成计划，再交给 _place_one 摆。
	# 两遍布点共用这份计划（第二遍只改半径）。
	# ================================================================
	var plan: Array = []
	# ① 两条边（从内圈到外缘，角度锁在边线上）
	#    ★ side 必须显式取 float：数组字面量取出来是 Variant，
	#      `var ang := 表达式` 会因为推断不出类型而**编译失败**（实测踩过）
	for side_v in [-1.0, 1.0]:
		var side := float(side_v)
		for k in range(edge_n):
			if plan.size() >= want:
				break
			var t := (float(k) + 0.5) / float(edge_n)
			var rr_e := lerpf(r_in, fit, t)
			var m_e := asin(clampf(cluster_r / maxf(rr_e, cluster_r + 0.02), 0.0, 0.95))
			var ang_e := sector_axis + side * maxf(sector_half - m_e, 0.01)
			plan.append({"ang": ang_e, "rad": rr_e, "orient": ORIENT_TO_AXIS})
	# ② 外弧（半径锁在 fit）
	var m_arc := asin(clampf(cluster_r / maxf(fit, cluster_r + 0.02), 0.0, 0.95))
	var half_arc := maxf(sector_half - m_arc, 0.01)
	for k in range(arc_n):
		if plan.size() >= want:
			break
		var ka := (float(k) + 0.5) / float(arc_n)
		var ang_a := sector_axis + lerpf(-half_arc, half_arc, ka)
		plan.append({"ang": ang_a, "rad": fit, "orient": ORIENT_TO_CASTER})
	# ③ 内部填充：按行列铺满扇形（半径方向用同一个角余量规则）
	var rest := maxi(0, want - plan.size())
	var rows := maxi(1, int(ceil(sqrt(float(rest)))))
	for ir in range(rows):
		for ia in range(rows):
			if plan.size() >= want:
				break
			var kr := (float(ir) + 0.5) / float(rows)
			var ka2 := (float(ia) + 0.5) / float(rows)
			var rr2 := lerpf(r_in, fit, kr)
			var m_i := asin(clampf(cluster_r / maxf(rr2, cluster_r + 0.02), 0.0, 0.95))
			var hu := maxf(sector_half - m_i, 0.01)
			var ang_i := sector_axis + lerpf(-hu, hu, ka2)
			plan.append({"ang": ang_i, "rad": rr2, "orient": ORIENT_FILL})
	# ---- 第一遍：按名义半径摆，量出"这一遍实际伸出多远" ----
	_kd.clear()
	placed = _place_plan(plan, pscale)
	var reach_max := 0.0
	for i in range(mini(placed, _patches.size())):
		var pf := _patches[i] as Node3D
		if pf != null and is_instance_valid(pf):
			reach_max = maxf(reach_max, _patch_reach(pf))
	# ---- 第二遍：需要留白就把所有半径整体重映射，再摆一遍（不会挤成一团） ----
	var r_clear := minf(reach_max + maxf(place_inner_gap_m, 0.0), fit)
	if r_clear > r_min_nom + 0.001:
		_kd.clear()
		var plan2: Array = []
		for e in plan:
			plan2.append({"ang": float(e["ang"]),
					"rad": _remap_inner(float(e["rad"]), r_min_nom, fit, r_clear),
					"orient": int(e["orient"])})
		placed = _place_plan(plan2, pscale)
	# ★ 只启用摆好的这些簇：多余的池子成员要藏起来
	_used = placed
	for i3 in range(placed, _patches.size()):
		var f3 := _patches[i3]
		if f3 != null and is_instance_valid(f3):
			f3.visible = false
		if _glows.size() > i3 and _glows[i3] != null:
			_glows[i3].visible = false
	# ★ 把 kd 归一化到 0..1：推进总时长必须等于 advance_time（原来最大 1.2 -> 超时）
	var kmax := 0.001
	for v in _kd:
		kmax = maxf(kmax, v)
	for i2 in range(_kd.size()):
		_kd[i2] = _kd[i2] / kmax
	# ★ 贴地光斑用的是**共享材质**（一个 fade 管全部）：子类不再走基类的 _apply_grow，
	#   必须自己把它设成 1，否则光斑永远不显示（观感就是"火一起冒出来"）
	if _glow_mat != null:
		_glow_mat.set_shader_parameter("fade", 1.0)


## 摆一簇火：位置/朝向/缩放/波前距离。返回下一个可用下标。
func _place_one(i: int, ang: float, rad: float, pscale: float, orient := ORIENT_FILL) -> int:
	if i >= _patches.size():
		return i
	var x := _center.x + cos(ang) * rad
	var z := _center.z + sin(ang) * rad
	var f := _patches[i]
	if f == null or not is_instance_valid(f):
		return i + 1
	f.visible = false                              # 等波前到达才显示
	var pr := _probe_patch(x, z, _center.y)
	var up: Vector3 = pr["up"]
	var y: float = float(pr["y"]) - ground_sink
	# ★ 这里的 yaw 只决定**特效根**的朝向 = 簇内 16 张卡的**摆布**（位置分布）：
	#   内部填充用"径向 + 抖动"（薄片离散 -> 有体积感，见 place_yaw_jitter_deg）。
	#   它**不是**大面朝向 —— 大面朝向由下面逐卡写的 face_cards_to 决定（见 ORIENT_* 注释）。
	var yaw := 0.0
	if orient == ORIENT_TO_AXIS and boundary_face_inward:
		var side := 1.0
		if sin(ang - sector_axis) < 0.0:
			side = -1.0
		yaw = PI * 0.5 - ang + (0.0 if side > 0.0 else PI) + deg_to_rad(place_yaw_offset_deg)
	elif orient == ORIENT_TO_CASTER and boundary_face_inward:
		yaw = PI - ang + deg_to_rad(place_yaw_offset_deg)
	else:
		yaw = ang + deg_to_rad(place_yaw_offset_deg) \
				+ deg_to_rad(randf_range(-place_yaw_jitter_deg, place_yaw_jitter_deg))
	var basis := Basis(Vector3.UP, yaw)
	var axis_v := basis.y.cross(up)
	if axis_v.length_squared() > 1e-8:
		basis = Basis(axis_v.normalized(), basis.y.angle_to(up)) * basis
	f.global_transform = Transform3D(basis, Vector3(x, y, z))
	f.scale = Vector3.ONE * pscale
	# ★★ 逐卡朝向（用户需求）：
	#   · 扇形**两条边**的火焰 -> 大面朝**扇形中轴线**
	#   · 扇形**圆弧处**的火焰 -> 大面朝**角色**
	#   · 内部填充 -> 保持随机朝向（薄片要离散度才有体积感）
	#   必须逐卡写：焰卡自身 yaw 在生成时是随机的，只转特效根节点改不了大面朝向
	#   （实测：只转根节点 -> 边界簇对齐度 0.58 ≈ 随机；逐卡写 -> 0.99）。
	if boundary_face_inward and (orient == ORIENT_TO_AXIS or orient == ORIENT_TO_CASTER):
		f.call("face_cards_to", _face_dir_for(orient, x, z), boundary_jitter_deg)
	else:
		f.call("randomize_cards")
	f.set("grow", 0.0)
	# ★★ 贴地光斑：**必须在这里摆好**（基类是在它自己的 _spawn_patches 里摆的，
	#   子类覆盖了那个函数却漏了这一步）。
	#   漏掉的症状（用户实测："角色很远的地方也有火焰效果"）：15 个光斑全都留在
	#   特效根节点的原点、竖着、scale=1、且 visible=true（本文件末尾把 fade 设成 1
	#   让它们显示）—— 而特效根挂在 _player.get_parent() 上，角色一走开，
	#   原地就剩一团火。这里按和基类**完全一样**的规则摆到这一簇的脚下。
	if _glows.size() > i and _glows[i] != null:
		var glow := _glows[i]
		var gup: Vector3 = up
		var gfwd := Vector3(sin(yaw), 0.0, cos(yaw))
		var gright := gfwd.cross(gup)
		if gright.length_squared() < 1e-6:
			gright = Vector3.RIGHT
		gright = gright.normalized()
		gfwd = gup.cross(gright).normalized()
		glow.global_transform = Transform3D(Basis(gright, gfwd, gup),
				Vector3(x, y, z) + gup * (ground_sink + 0.03))
		glow.scale = Vector3.ONE * pscale
		glow.visible = false
	# 波前距离 = 径向距离（边界圈里的簇也按半径参与推进 -> 仍然由近及远）
	_kd.append(clampf(rad / maxf(_radius, 0.01), 0.0, 1.0))
	return i + 1


## 某个落点该让焰卡"大面"朝的世界方向（内部填充不调用）。
##   · ORIENT_TO_CASTER（圆弧处）：指向**角色**（= −径向）。角色就是扇形中心。
##   · ORIENT_TO_AXIS（两条边）：指向**扇形中轴线** —— 取该落点到中轴线的**垂足**方向
##     （"朝向中轴线"的字面意思；等价于垂直于中轴线，与张角无关）。
##     落点正好压在中轴线上时方向退化 -> 兜底取任意垂直于中轴的水平方向。
## ★ place_yaw_offset_deg 在这里**同样生效**（绕世界 UP 转）：默认 0；
##   若哪天觉得"大面朝外了"，设 180 就能整体翻一面（这是原来就有的逃生口）。
func _face_dir_for(orient: int, x: float, z: float) -> Vector3:
	var flat := Vector3(x - _center.x, 0.0, z - _center.z)
	var axis_dir := Vector3(cos(sector_axis), 0.0, sin(sector_axis))
	var dir := Vector3.ZERO
	if orient == ORIENT_TO_CASTER:
		if flat.length_squared() < 1e-8:
			dir = -axis_dir                          # 落点就在角色身上：朝扇形内侧
		else:
			dir = (-flat).normalized()
	else:
		var foot := axis_dir * flat.dot(axis_dir)    # 该落点在中轴线上的垂足
		var to_axis := foot - flat
		if to_axis.length_squared() < 1e-8:
			dir = Vector3(-axis_dir.z, 0.0, axis_dir.x)
		else:
			dir = to_axis.normalized()
	if absf(place_yaw_offset_deg) > 0.001:
		dir = dir.rotated(Vector3.UP, deg_to_rad(place_yaw_offset_deg))
	return dir



## 这一簇火**实际**向水平方向伸出多远（米）：用 AABB 角点（含当前逐卡 yaw 与缩放），
## 是几何体真实伸距的上界。留白按它算 -> 火焰外缘正好落在 place_inner_gap_m 上，
## 不会像「保守上界」那样把火推得老远（用户反馈：火焰生成距离角色过远）。
func _patch_reach(f: Node3D) -> float:
	var inv := f.global_transform.affine_inverse()
	var reach := 0.0
	for mi in _effect_meshes(f):
		var mesh := (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		var rel := inv * (mi as Node3D).global_transform
		var box := mesh.get_aabb()
		for k in range(8):
			var c := box.position + Vector3(
					box.size.x if (k & 1) != 0 else 0.0,
					box.size.y if (k & 2) != 0 else 0.0,
					box.size.z if (k & 4) != 0 else 0.0)
			var w := rel * c
			reach = maxf(reach, Vector2(w.x, w.z).length())
	return reach * f.scale.x


## 按计划摆一遍（返回摆好的簇数）
func _place_plan(plan: Array, pscale: float) -> int:
	var placed := 0
	for e in plan:
		if placed >= _patches.size():
			break
		placed = _place_one(placed, float(e["ang"]), float(e["rad"]), pscale, int(e["orient"]))
	return placed


## 把**名义**半径按"角色脚底留白"重映射：最内侧那簇正好落在 r_clear，最外侧仍是 fit，
## 中间按比例铺开。为什么不直接把小于 r_clear 的簇都夹到 r_clear：那样好几簇会
## 被挤到同一个半径上（实测：4 簇叠成一团）。
func _remap_inner(rn: float, r_min_nom: float, fit: float, r_clear: float) -> float:
	if r_clear <= r_min_nom + 0.001:
		return rn
	var k := (rn - r_min_nom) / maxf(fit - r_min_nom, 0.001)
	return r_clear + k * maxf(fit - r_clear, 0.0)


## 特效里所有网格（含 CoreGlow 光片：它们也是这一簇火的一部分）
func _effect_meshes(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_effect_meshes(c))
	return out


## ★ 覆盖：每簇火**各自**计时（波前到达才出现；出现后各自活 burn_time 秒）
func _apply_grow(_s: float) -> void:
	var shown := 0
	for i in range(mini(_used, _patches.size())):
		if i >= _kd.size():
			break
		var f: Node3D = _patches[i]
		if f == null or not is_instance_valid(f):
			continue
		var age := _wave_t - float(_kd[i]) * advance_time
		var g := 0.0
		if age >= 0.0:
			g = clampf(age / maxf(ignite_time, 0.01), 0.0, 1.0)          # 生成
			if age > burn_time:
				g = clampf(1.0 - (age - burn_time) / maxf(afterburn_time, 0.01), 0.0, 1.0)
		f.set("grow", g)
		f.visible = g > 0.001
		if g > 0.001:
			shown += 1
		if _glows.size() > i:
			_glows[i].visible = g > 0.001
	# ★ 每秒报一次：波前时钟走了多少、已显示几簇（用来判断"推进有没有生效"）
	if debug_sector and _wave_t > _wave_report + 1.0:
		_wave_report = _wave_t
		print("[火焰推进] 波前 t=%.2f/%.2f s | 已显示 %d/%d 簇 | 待点植被 %d"
				% [_wave_t, advance_time, shown, _used, _pending_veg.size()])

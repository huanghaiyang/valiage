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

## ============================================================================
## 【补充说明：所属系统 / 依赖 / 对外接口 / 已知的坑】（与上面的文件头互补）
##
## 所属系统：法术系统（scripts/spells/）里的一次性**扇形**范围法术。
##   实例由 autoload `SpellCaster`（scripts/spells/spell_caster.gd）管理：
##   它的法术表里 "flame_advance" -> preload 本脚本；施法时先
##   `_spawn_cast_instance()` 克隆出**本次施法专用实例**，再对它调用
##   `cast_sector()`（造不出独立实例才退回共享实例）。
##   轮盘里的名字见 spell_wheel.gd（1001 -> "flame_advance"）。
##
## 继承链：extends res://scripts/spells/flame_scorch.gd（火焰灼烧）。
##   基类成员全部可用，其中**被本文件覆盖**的有：
##     _process / _ignite_vegetation / _spawn_patches / _apply_grow /
##     _node_touches_circle / _burn_instance_indices / _burn_instance_delays
##   **直接复用（未改）**的有：cast_at（含扣蓝）、_apply_damage（扣血）、
##     _ensure_pool / _ensure_glow_pool、_find_vegetation / _ignite_one、
##     _mm_scan_circle、_probe_patch / _patch_up / _ray_down、_hide_all、
##     状态机常量 ST_OFF / ST_IGNITE / ST_BURN / ST_AFTER。
##
## 关键依赖（都是**基类里的**常量或脚本，本文件不重复声明）：
##   · 数值表：scripts/spells/spell_sheet.gd（基类 const SHEET = preload(...)，
##     **不是 autoload**）。本法术的行名 = SHEET_ID_NEW（"flame_advance"），
##     数据在 data/spell_sheet.json。用到的字段：
##       mana_cost 30 / cast_climb 0.35 / duration 8.0 / fade_time 1.2 /
##       targeting.mode "sector" / angle_min 45 / angle_max 80 /
##       radius_at_min 10 / radius_at_max 6 /
##       advance_time_at_min 1.0 / advance_time_at_max 0.6 / damage_per_sec 10.0
##   · autoload `Mana`（scripts/spells/mana.gd）：扣蓝只发生在基类 cast_at 里，
##     本文件通过 cast_sector -> cast_at 间接走这条路，自身不直接调用 Mana。
##   · 特效场景：基类 FIRE_SCENE = res://scenes/法术特效/火焰燃烧特效.tscn，
##     每簇火一个实例；实例上必须有 `grow` 属性与 face_cards_to() / randomize_cards()
##     两个方法（本文件会 call 它们）。
##   · 贴地光斑：基类 GROUND_SHADER = res://assets/shaders/fire_ground.gdshader
##     ＋ FIRE_TEX = res://assets/textures/法术特效/龙卷风/T_FirePanningCyl45.png。
##   · 植被燃烧控制器：scripts/vfx/foliage_burn.gd（基类 _ignite_one 里 new）。
##   · 选点器：scripts/spells/spell_targeting.gd（mode=sector）算出
##     center / radius / axis / half，再由 spell_caster 转交给 cast_sector。
##   本文件**不发任何自定义信号**，也不读写文件。
##
## 主要对外接口：
##   · cast_sector(center, radius, axis, half) -> void   ← 本文件新增的入口
##   · has_targeting() -> bool / targeting_config() -> Dictionary（选点器据此决定
##     是否进入选点流程、以及扇形张角上下限）
##   · 继承自基类、外部也会调的：cast_at / start_cast / stop_cast / is_casting /
##     ran_out_of_mana / aim_dir / origin_global / wants_cast_anim
##
## 已知的坑（均为实测踩出来的，改动前请先读对应函数处的注释）：
##   · 基类 _ready() 的 _load_sheet() 读的是**基类常量 SHEET_ID = "flame_scorch"**
##     那一行，所以本文件初始化时 burn_time / mana_cost 等来自**火焰灼烧**的数值。
##     本文件只在 cast_sector() 里用 "flame_advance" 行覆盖 burn_time
##     （= duration + advance_time）。两行当前数值恰好相同（30 蓝 / 8.0s），
##     改表时**必须两行一起改**，否则会出现"推进用的是灼烧的时长"。
##   · 绕过 cast_sector 直接 cast_at：扇形参数没设，会退回基类"铺满整圆"。
##     _spawn_patches() 开头有兜底（用 angle_min 折半填 sector_half），
##     但 sector_axis 仍是 0.0，扇面方向会不对。
##   · _process 里的 delta 上限 0.05（50ms）是**必需**的，删掉会丢推进阶段。
##   · "两遍布点"（先量实际伸距，再整体重映射半径）不能简化成一遍，否则火
##     要么烧到脚上、要么被推得离角色很远（用户两次反馈过的两个极端）。
##   · 贴地光斑必须在本文件的 _place_one() 里摆好；漏掉会出现
##     "角色走开后原地剩一团火"的经典症状。
##
## 调试：@export var debug_sector（下文）打开时会在输出面板打印扇形参数、
##   待点燃植被数，以及每秒一次的波前进度。
## ============================================================================


# ==================== 数值表标识与波前状态 ====================
## 本法术在 data/spell_sheet.json 里的**行名**。
## ★ 注意与基类 const SHEET_ID（= "flame_scorch"）是两个不同的键，不可混用：
##   基类的 _load_sheet / has_targeting / cast_at 用的是 SHEET_ID，
##   本文件只有 cast_sector() 读 SHEET_ID_NEW。改成别的字符串就等于换数值表行
##   （表里没有这一行时，get_spell 会拿不到数据、退回各处的硬编码默认值）。
const SHEET_ID_NEW := "flame_advance"

## 扇形中轴线在**世界 XZ 平面**上的方向角（弧度）。0 = 指向 +X，π/2 = 指向 +Z。
## 由 cast_sector() 从选点器的 axis 写入；_in_sector() 与 _face_dir_for() 都用它。
var sector_axis := 0.0
## 扇形**半角**（弧度），即中轴到边线的夹角。默认 0.785 ≈ 45°，
## 对应数值表 angle_min = 45°（整张角 90°）；_in_sector 判定用 |夹角| <= sector_half。
## cast_sector 里会 maxf(half, 0.05) 兜底（防止 0 或负值导致扇面退化成一条线）。
var sector_half := 0.785
## 波浪推进总时长（秒）：波前从 kd=0 走到 kd=1 所需时间。
## 默认 1.0 对应 45°（advance_time_at_min）；80° 时为 0.6（advance_time_at_max），
## 中间线性插值（见 cast_sector）。调大 = 火铺得更慢更"爬"，调小 = 几乎同时冒火。
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


# ==================== 选点接口（供选点器 spell_targeting 调用） ====================
## 本术法是否需要"先选点、再施法"。
## 返回：true = 走选点流程（当前表里 flame_advance 的 targeting.enabled = true）。
## 副作用：无（只读数值表）。读取失败/表里没有该行时返回 false -> 会退回
##   start_cast() 的正前方兜底施法。注意这里查的是 SHEET_ID_NEW，
##   与基类同名函数（查 SHEET_ID = "flame_scorch"）是两个不同的开关。
## 调用时机：SpellCaster 每帧的 _update_targeting() 里都会调一次（决定这一帧
##   是否由选点器接管操作，而不是"按住施法"）。
func has_targeting() -> bool:
	var tg: Dictionary = SHEET.get_spell(SHEET_ID_NEW).get("targeting", {})
	return bool(tg.get("enabled", false))


## 选点器的配置块（整段 targeting 字典，原样返回，不做拷贝）。
## 返回：Dictionary；本术法用到的键有 mode("sector") / angle_min(45.0) /
##   angle_max(80.0) / radius_at_min(10.0) / radius_at_max(6.0) /
##   advance_time_at_min(1.0) / advance_time_at_max(0.6) / range_min/range_max 等。
## 副作用：无。但返回的是数值表内部字典的引用，调用方**不要就地修改**
##   （会污染法术表缓存，影响其它实例与后续施法）。
## 调用时机：同样在 SpellCaster._update_targeting() 里**每帧**调用一次，用
##   str(cfg) 作签名比对（签名变了才真正重新 configure 选点器 —— 这就是
##   "圆盘 <-> 扇形"切换不会串台的机制）；本文件在 cast_sector 与 _spawn_patches
##   里也用它读推进时间/张角的插值参数。
func targeting_config() -> Dictionary:
	return SHEET.get_spell(SHEET_ID_NEW).get("targeting", {})


# ==================== 扇形范围判定（把基类的"整圆"收紧成"扇区"） ====================
## ★ 覆盖基类的"圆内判定"：扇形法术里，**圆内还要在扇区内**才算。
##   基类用它筛植被（_find_vegetation -> _node_touches_circle），
##   不覆盖的话整圈草都会被烧黑 —— 实测症状就是"最终效果不是扇形，而是一圈圆的焦痕"。
## 参数 n：待判定的植被节点（可能是普通 MeshInstance3D，也可能是整片草丛的
##   MultiMeshInstance3D，后者要按**逐实例**判定，不能用节点原点）。
## 返回：true = 这个节点（或它的任一实例）落在扇形内，应被点燃/波及。
## 副作用：无（纯查询；MultiMesh 扫描会走基类会累积 _scanned_instances 自检计数，
##   并按块索引缓存，见基类 _mm_scan_circle）。
## 调用时机：基类 _find_vegetation() 筛候选植被时，每个候选调一次。
func _node_touches_circle(n: Node3D) -> bool:
	if n is MultiMeshInstance3D:
		var hit := _mm_scan_circle(n as MultiMeshInstance3D, _center, _radius)
		for h in hit:
			if _in_sector(h["w"] as Vector3):
				return true
		return false
	return _in_sector(n.global_position)


## ★ 覆盖：逐实例燃烧只烧**扇区内**的实例（基类只按圆筛 -> 会烧黑整圈草）
## 参数 mmi：一片草丛/花丛的 MultiMeshInstance3D。
## 返回：Array[int] —— 要交给 foliage_burn 的**实例下标**白名单（顺序 = 扫描顺序，
##   不是距离顺序；下标来自 multimesh 的实例编号，基类会用 get_instance_transform 取位）。
## 副作用：无（但会让基类扫描计数增加，并复用/建立块索引缓存）。
## 调用时机：基类 _ignite_one() 点燃某个 MultiMesh 植被时调用一次（每次施法、每片草一次）。
## 注意：这里只做"位置筛选"，不负责点燃时刻（延迟由 _burn_instance_delays 单独给）。
func _burn_instance_indices(mmi: MultiMeshInstance3D) -> Array:
	var ids: Array = []
	for h in _mm_scan_circle(mmi, _center, _radius):
		if _in_sector(h["w"] as Vector3):
			ids.append(int(h["i"]))
	return ids


## ★ 覆盖：每实例的点燃延迟按"离角色的距离"给 -> 草按波前依次烧起来
##   （不覆盖的话基类不给延迟、控制器用随机错开，观感是"整片一起黑"）
## 参数 mmi：同 _burn_instance_indices。
## 返回：Array[float]，单位为**秒**，范围 [0, advance_time]；下标与
##   _burn_instance_indices 返回的实例下标**一一对应**（同一个 _mm_scan_circle 扫描
##   顺序、同样跳过扇区外的实例），所以两者的长度与顺序必须一起改，
##   否则延迟会错配到别的草上。
## 副作用：无。换算方式 = clampf(水平距离 / _radius, 0, 1) * advance_time，
##   即离角色越远点得越晚，正好和火焰簇的 kd 推进同步。
## 调用时机：基类 _ignite_one() 里，交给 foliage_burn 的 preset_delays。
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
## 参数 w：**世界坐标**（不是局部坐标）；只取 x/z 做水平判定，y 不参与。
## 返回：true = 半径内且在张角内；落在圆心（水平距离 < 0.0001m）时**恒为 true**
##   （避免 atan2 在原点无定义）。
## 副作用：无（纯函数，只读 _center / _radius / sector_axis / sector_half）。
## 调用时机：_node_touches_circle、_burn_instance_indices、_burn_instance_delays 里，
##   对每个候选位置调用；本函数是"扇形"这一特性的唯一判定出口，
##   所有"哪里算扇形内"的问题都应改这里，而不要在各个调用点各写一套。
## 注意：角度差用 wrapf(..., -PI, PI) 归一化，所以中轴在 ±π 附近（朝 −X）时
##   跨边界也不会误判（这是必须的写法，别改成直接相减）。
func _in_sector(w: Vector3) -> bool:
	var d := Vector2(w.x - _center.x, w.z - _center.z)
	if d.length() > _radius:
		return false
	if d.length() < 0.0001:
		return true
	var dd := wrapf(atan2(d.y, d.x) - sector_axis, -PI, PI)
	return absf(dd) <= sector_half


# ==================== 施法入口与波浪时钟 ====================
## 诊断：确认扇形参数真的传进来了（否则会退回基类的整圆布点）
## true 时打印：半径 / 张角（整角与半角）/ 中轴角 / 推进时长 / 总时长，
## 以及每秒一次的波前进度（见 _apply_grow 末尾）。
## 只在**编辑器与调试版本**里用它定位"扇形没生效"：正常游玩建议关掉，
## 每次施法会多几行输出（一次性法术，量不大，但刷屏仍然影响看日志）。
@export var debug_sector := true


## 扇形施法：center = 角色位置，radius = 扇形半径，axis = 中轴弧度，half = 半角弧度
## 参数 center：选点器给的中心。**实际会被强制改到角色脚下**（只保留它的 y），
##   见下面第一段"防御"注释 —— 扇形必须以角色为起点。
## 参数 radius：扇形半径（米），表里 45° 时 10m、80° 时 6m，由选点器插值给出；
##   基类 cast_at 里会 maxf(radius, 0.5) 兜底。
## 参数 axis：中轴方向角（弧度，世界 XZ 平面，0 = +X）→ 写入 sector_axis。
## 参数 half：半角（弧度），会 maxf(half, 0.05) 兜底后写入 sector_half；
##   整角 = 2*half，用来插值 advance_time。
## 返回：无。失败时**静默返回**（不返回错误码）：基类 cast_at 在蓝不够、
##   或状态机不在 ST_OFF/ST_AFTER 时会直接 return，此时 casting 不会变 true。
## 副作用：写 sector_axis/sector_half/advance_time/burn_time/_wave_t；
##   经 cast_at 扣蓝（autoload Mana）、置 casting=true、铺火簇、登记待烧植被、
##   进入 ST_IGNITE 状态；可能向输出面板打印（debug_sector）。
## 调用时机：SpellCaster 在"按下左键且法术就绪"时调用**一次**（在本次施法专用的
##   实例上）；不要在别处重复调用，否则会重置波前时钟。
## 注意：burn_time 在这里被覆盖成"表里的 duration + advance_time"，
##   总时长因此比火焰灼烧长 advance_time（文件头解释了为什么这是对的）。
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


## 兜底施法入口（没有选点器时才会走到）：直接调基类的实现 ——
## 在角色正前方 3.6m 处放一个**半径 2.5m 的整圆**火焰（不会摆成扇形）。
## 参数：无。返回：无。
## 副作用：与基类 start_cast 相同（扣蓝、铺簇、进入状态机）；
##   因为这里没走 cast_sector，sector_half/sector_axis 保持默认（或上次施法残留），
##   只有 _spawn_patches 开头的兜底会把 sector_half 补成一个默认张角。
## 调用时机：SpellCaster 判定"这个法术不需要选点/选点不可用"时；
##   正常玩法下 flame_advance 的 targeting.enabled = true，走的是 cast_sector。
## 注意：保留这个覆盖只是为了"入口显式化"，行为完全等于基类；
##   不要在这里偷偷改参数 —— 那会让"两条施法路径"产生两套效果。
func start_cast() -> void:
	super.start_cast()


## 每帧回调：先推进**波浪时钟**并点燃波前经过的植被，再交给基类状态机。
## 参数 delta：距上一帧的秒数（引擎给出，单位秒；这里会**夹到 50ms** 再用，
##   原因见函数内那段 BUG 修复注释）。
## 返回：无。
## 副作用：累加 _wave_t（钳制后的 delta）、可能点燃植被（新建 foliage_burn 节点并
##   挂到父节点上）、可能打印日志；之后基类 _process 会按状态机调 _apply_grow
##   （逐簇设 grow/visible）与 _apply_damage（扣血）。
## 调用时机：引擎每帧调用；未施法（casting=false）时不推进 _wave_t。
## 注意：调用顺序**不能颠倒** —— 基类 _process 在同帧内就会用 _wave_t 算各簇年龄，
##   所以本帧的波前必须先累加，否则火会比波前晚一帧出现（表现为推进"顿"一下）。
func _process(delta: float) -> void:
	if casting:
		# ★ BUG 修复：「有时候前两个推进阶段不生效、直接从第三阶段开始」✗
		#   火焰簇的成长动画按 `_wave_t` 算年龄（见 _apply_grow：age = _wave_t - kd*advance_time）
		#   → `_wave_t` 只要**一次跳过头**（施法瞬间/卡顿帧的大 delta ✓ 或掉帧 ✓），
		#     前几段簇的 age 一上来就超过成长时长 ✗ → 表现为"那两段没播" ✓
		#   修法：给 delta 加上限（20fps = 50ms）→ 波前只**连续推进**、永不跳跃 ✓
		#   （代价：极端卡顿时整体推进略慢，但阶段不会丢 ✓）
		_wave_t += minf(delta, 0.05)
		_ignite_pending()
	super._process(delta)


# ==================== 植被的波前点燃 ====================
## ★ 覆盖：不在施法瞬间点燃植被，只**登记**（波前到达时才点燃）
##   否则远处的草在火到之前就已经黑了（用户 #4）
## 参数：无（用的是基类已设好的 _center / _radius 与基类 _find_vegetation 的结果）。
## 返回：无。
## 副作用：清空并重建 _pending_veg（元素 {n: Node3D, i: int, kd: float}），
##   其中 kd = 水平距离/_radius 夹到 0..1（与火焰簇同一套"波前距离"口径）；
##   debug_sector 打开时打印数量。**本函数不创建任何燃烧节点**（真正的点燃
##   推迟到 _ignite_pending）。
## 调用时机：基类 cast_at 里紧跟 _spawn_patches 之后调用一次（每次施法一次）。
## 注意：i 是"候选序号"（非扇区内序号也照样自增），基类 _ignite_one 会用它给
##   foliage_burn 起名字/错开启动，所以 i 不连续不会有问题，但**顺序必须稳定**。
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
## 参数：无（读 _wave_t 与 _pending_veg）。
## 返回：无。
## 副作用：对到点的植株调基类 _ignite_one() —— 会**新建** foliage_burn 节点、
##   挂到本节点父级、传入预设的块内实例表与逐实例延迟；并把已点燃的元素从
##   _pending_veg 里移除（未到点的原样留到下一帧，**不保证顺序**）。
## 调用时机：本文件 _process 里，**每帧**在 _wave_t 累加之后调用；
##   _pending_veg 为空时立即返回（日常开销近似为零）。
## 注意：_pending_veg 用"重建数组"而不是"按下标删除"，因为一帧内可能连点多个；
##   顺序变化不影响效果（点燃本身无先后依赖）。
func _ignite_pending() -> void:
	if _pending_veg.is_empty():
		return
	var left: Array = []
	for e in _pending_veg:
		# kd * advance_time = 波前到达该植株的时刻（秒），与 _apply_grow 里
		# "age = _wave_t - kd*advance_time" 同一套口径 —— 草和火才是同步的。
		# 改成别的公式（例如直接用距离/速度）会让草比火早或晚。
		if float(e["kd"]) * advance_time <= _wave_t:
			_ignite_one(e["n"] as Node3D, int(e["i"]))
		else:
			left.append(e)
	_pending_veg = left


# ==================== 扇形布点（覆盖基类的"铺满整圆"） ====================
## ★ 覆盖：扇形内采样 + 记录波前距离（原版是铺满圆盘）
## 参数：无 —— 用的是 cast_sector 设好的 _center / _radius / sector_axis /
##   sector_half，以及各种 @export 的布点参数。
## 返回：无（结果写在成员上：_patches/_glows 的 transform 与 visible、_used、_kd）。
## 副作用（顺序很重要）：
##   ① 可能**新建**火焰簇与光斑（基类 _ensure_pool），并隐藏多余成员；
##   ② 两遍布点，第一遍只是"量伸距"（表面上看是白摆一次，其实必须）；
##   ③ 把 _kd 归一化到 0..1；
##   ④ 把共享的贴地光斑材质 fade 设成 1（因为子类不再走基类 _apply_grow）。
## 调用时机：基类 cast_at 里**一次**（每次施法一次），此时 casting 已为 true 但
##   状态机还没进入 ST_IGNITE。
## 注意：这里**不显示**任何火焰簇（_place_one 里一律 f.visible = false），
##   显示时机由 _apply_grow 按波前决定 —— 别在这里打开 visible，
##   否则整片火会在施法瞬间一起冒出来。
func _spawn_patches() -> void:
	# 保险：万一没走 cast_sector（例如被别的入口直接 cast_at），
	# 也不能退回基类的"铺满整圆"—— 那样最终效果就不是扇形了。
	if sector_half <= 0.001:
		var tg0: Dictionary = targeting_config()
		sector_half = deg_to_rad(float(tg0.get("angle_min", 45.0))) * 0.5
	# 基类预留的空钩子（当前实现是 pass）：保留调用是为了以后加"布点前的准备"，
	# 不能删 —— 万一基类将来在里面做事，删掉会让子类静默漏掉那一步。
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
	# ★ 簇的缩放：基类按 _radius/4 缩，这里改成 _radius/6（扇形铺得开，单簇可以小些），
	#   再乘 fire_scale（基类导出，默认 1.1）与 place_scale（本文件导出，默认 0.7，
	#   专治"贴边的簇溢出扇区"）。下限 0.45 保证小扇面时火不会缩成看不见的点。
	var pscale := clampf(_radius / 6.0, 0.45, 1.0) * fire_scale * place_scale
	# fp = 这一簇火的**名义**水平半径（米）；fit = 可布点的最大半径（再往外放，
	# 火就会压到扇形弧线以外 —— 这是"溢出"的第一道防线，第二道是 cluster_r/fit 的
	# 角度余量 m_e/m_arc）。
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
	# 内部填充：按 rows×rows 的**正方形网格**铺（极坐标网格太容易挤在圆心），
	# 多出来的格子由 want 截断 —— 所以最内侧/最后一列会被丢掉，观感是"内部偏稀疏"，
	# 这属于有意妥协：轮廓由①边②外弧保证，内部只需补体积。
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


# ==================== 单簇摆放与朝向（位置 / 姿态 / 逐卡大面） ====================
## 摆一簇火：位置/朝向/缩放/波前距离。返回下一个可用下标。
## 参数 i：要写的那一簇在 _patches/_glows 里的下标（池子下标，不是"第几簇"）。
## 参数 ang：该簇相对**世界 +X 轴**的角度（弧度），与 sector_axis 同一套约定；
##   位置 = _center + (cos(ang), sin(ang)) * rad（见函数内第一条注释）。
## 参数 rad：该簇离角色中心的水平距离（米），必须 <= fit；同时被记成 kd = rad/_radius，
##   决定它的波前时刻。
## 参数 pscale：这一簇的整体缩放（= 上面算好的 pscale），会写进 f.scale 和 glow.scale。
## 参数 orient：簇的定向模式（ORIENT_FILL / ORIENT_TO_CASTER / ORIENT_TO_AXIS），
##   仅在 boundary_face_inward = true 时对后两种生效，决定逐卡法线朝哪。
## 返回：下一个可用下标（正常 = i+1；若 _patches[i] 无效则跳过为 i+1；
##   越界时原样返回 i 表示"没摆下"）。
## 副作用：改 _patches[i].global_transform / scale / visible / grow、
##   改 _glows[i] 的 global_transform / scale / visible、
##   调特效节点的方法（face_cards_to 或 randomize_cards）、向 _kd **追加**一个元素。
## 调用时机：_place_plan 里对计划表逐项调用；一次施法会调用 1~2 遍（两遍布点）。
## 注意：这里刻意把 visible 一律设为 false（等波前），并且 _kd 是 append 的 ——
##   所以调用者必须在开摆之前 _kd.clear()，否则两遍会得到双倍长度、推进全乱。
func _place_one(i: int, ang: float, rad: float, pscale: float, orient := ORIENT_FILL) -> int:
	if i >= _patches.size():
		return i
	# ★ 坐标系约定（务必和 _in_sector 保持一致）：
	#   角度角 ang 落在**世界 XZ 平面**，x = cos、z = sin；_in_sector 里用
	#   atan2(d.y, d.x)（d 是 xz 的 Vector2）反算角度 —— 两边一旦改成
	#   "x=sin / 角度从 +Z 起算"，扇形会整体转 90°，而且只有边线簇看着不对。
	var x := _center.x + cos(ang) * rad
	var z := _center.z + sin(ang) * rad
	var f := _patches[i]
	if f == null or not is_instance_valid(f):
		return i + 1
	f.visible = false                              # 等波前到达才显示
	# 地面高度/姿态轴沿用基类探针（多点取最低，保证不悬浮）；再减 ground_sink
	# 把底面压进地表，消掉"火焰底下一条缝"的观感（与基类同款）。
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
	# 两步构造姿态（与基类 _spawn_patches 完全一致）：
	#   ① Basis(UP, yaw) 先定水平朝向；
	#   ② 绕 "UP × 姿态轴" 把节点自身的上方向转到探针给的姿态轴，火才"坐"在坡面上。
	# 姿态轴与 UP 共线时 axis_v 退化 —— 此时保持竖直（下面的 length_squared 判断）。
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
	# 初始成长值 0（= 不可见、体积极小）；真正的 grow 由 _apply_grow 按波前写。
	# 用 set()/call() 而不是直接访问属性/方法，是因为特效场景的脚本类型在本类里
	# 不可见（基类同样用 set/call，保持同一套鸭子类型约定）—— 改这里请注意：
	# 特效节点必须仍有 grow 属性，否则这一步会静默无效（推不出错误）。
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
		# 光斑是贴在脚下的水平四边形，需要一组与地面姿态一致的基向量：
		# 先取水平前向（= Basis(UP, yaw) 的 +Z 方向），再正交化出 right / forward。
		# 与基类 _spawn_patches 里那套写法完全一致 —— 不要在这里擅自"优化"。
		var gfwd := Vector3(sin(yaw), 0.0, cos(yaw))
		var gright := gfwd.cross(gup)
		if gright.length_squared() < 1e-6:
			gright = Vector3.RIGHT
		gright = gright.normalized()
		gfwd = gup.cross(gright).normalized()
		# y 抬高 ground_sink + 0.03：0.03 是额外的 3cm 偏置（推测：避免与地面共面
		# 产生深度冲突/z-fighting），与基类保持一致；改小可能让光斑闪烁。
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
## 参数 orient：ORIENT_TO_CASTER 或 ORIENT_TO_AXIS（传其它值会走 else 分支 = 中轴垂足，
##   所以内部填充**不要**调它）。
## 参数 x / z：这一簇落点的**世界坐标** xz（y 不参与，方向只算水平面）。
## 返回：**已归一化**的水平方向 Vector3（y 恒为 0），可直接当法线用；
##   退化情形有兜底（落点在角色身上 / 落点压在中轴线上），不会返回零向量。
## 副作用：无（纯函数，只读 _center 与 sector_axis、以及 place_yaw_offset_deg）。
## 调用时机：_place_one 里给边界圈簇调 face_cards_to 时；内部填充不调用。
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



# ==================== 伸距测量、计划摆放与半径重映射 ====================
## 这一簇火**实际**向水平方向伸出多远（米）：用 AABB 角点（含当前逐卡 yaw 与缩放），
## 是几何体真实伸距的上界。留白按它算 -> 火焰外缘正好落在 place_inner_gap_m 上，
## 不会像「保守上界」那样把火推得老远（用户反馈：火焰生成距离角色过远）。
## 参数 f：已经摆好 transform/scale 的一簇火（必须**先摆再量**，否则量的是旧姿态）。
## 返回：该簇相对**自身原点**的最大水平半径（米），已乘 f.scale.x；
##   只看 xz 距离，忽略垂直方向（火焰向上伸不算"占地方"）。
## 副作用：无（只读；内部用 affine_inverse 做局部化，不改任何节点）。
## 调用时机：_spawn_patches 第一遍布点之后，对每个已摆簇调一次，取最大值作为留白基准。
## 注意：用的是 mesh 的 AABB **角点**而不是球/半径，因此在卡面斜置时会略微高估
##   （高估是安全的：宁可火离脚远一点，也不要烧在脚上）。
func _patch_reach(f: Node3D) -> float:
	var inv := f.global_transform.affine_inverse()
	var reach := 0.0
	for mi in _effect_meshes(f):
		var mesh := (mi as MeshInstance3D).mesh
		if mesh == null:
			continue
		var rel := inv * (mi as Node3D).global_transform
		var box := mesh.get_aabb()
		# 8 = 用 k 的低 3 位枚举 AABB 的 8 个角点（&1 -> x、&2 -> y、&4 -> z）。
		# 因为下面取的是 max，必须**枚举全部 8 个角**：少一个 bit 就会低估伸距，
		# 留白随之算小 -> 火焰外缘又会蹭到角色脚上。
		for k in range(8):
			var c := box.position + Vector3(
					box.size.x if (k & 1) != 0 else 0.0,
					box.size.y if (k & 2) != 0 else 0.0,
					box.size.z if (k & 4) != 0 else 0.0)
			var w := rel * c
			reach = maxf(reach, Vector2(w.x, w.z).length())
	return reach * f.scale.x


## 按计划摆一遍（返回摆好的簇数）
## 参数 plan：元素为 {ang: float, rad: float, orient: int} 的字典数组
##   （由 _spawn_patches 排好；两遍布点共用同一份计划，第二遍只改 rad）。
## 参数 pscale：传给 _place_one 的整簇缩放。
## 返回：实际摆好的簇数（同时也就是下一遍该用的 _used 候选值，
##   池子不够/条目无效时会小于 plan.size()）。
## 副作用：逐个调 _place_one —— 写 _patches/_glows 的可见性与变换、
##   调特效的 face_cards_to/randomize_cards、并**追加** _kd。
## 调用时机：_spawn_patches 的两遍布点各调一次。
## 注意：本函数**不清空 _kd**（清空是调用方 _spawn_patches 的职责）——
##   新增调用点时务必沿用这个约定，否则推进距离表会叠两遍。
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
## 参数 rn：名义半径（米），取值范围 [r_min_nom, fit]。
## 参数 r_min_nom：名义分布里最内侧那簇的半径（= 重映射前 k=0 的位置）。
## 参数 fit：可布点的最大半径（重映射后最外侧仍落在它上面，保证不溢出扇形）。
## 参数 r_clear：留白后的最内侧半径 = 实测最大伸距 + place_inner_gap_m。
## 返回：重映射后的半径（米），范围 [r_clear, fit]；留白没必要（r_clear 不比
##   内圈更靠外）时**原样返回 rn**。
## 副作用：无（纯函数）。
## 调用时机：_spawn_patches 第二遍布点前，对计划表每一项算一次。
## 注意：这是**整体线性重映射**而不是 clamp —— 目的是保持簇之间的相对疏密，
##   避免上面说的"叠在同一半径上"；若改成 clamp，需要重新验证火不会挤成一团。
func _remap_inner(rn: float, r_min_nom: float, fit: float, r_clear: float) -> float:
	if r_clear <= r_min_nom + 0.001:
		return rn
	var k := (rn - r_min_nom) / maxf(fit - r_min_nom, 0.001)
	return r_clear + k * maxf(fit - r_clear, 0.0)


## 特效里所有网格（含 CoreGlow 光片：它们也是这一簇火的一部分）
## 参数 n：递归起点（一簇火的根节点）。
## 返回：Array[MeshInstance3D] —— **所有层级**上的网格节点（深度优先，
##   顺序 = 子节点顺序，含嵌套子节点）。
## 副作用：无（只读场景树；不做任何过滤/缓存，每次调用都重新遍历）。
## 调用时机：_patch_reach 里逐簇调用（第一遍布点后每簇一次）。
## 注意：这里**不排除** CoreGlow 之类的光片是有意的 —— 它们也是"占地方"的几何体，
##   漏算它们会让留白偏小；但也因此对性能敏感：簇数（<=28）× 每簇网格数是
##   每次施法固定开销，属于可接受范围（不要放进每帧调用的路径）。
func _effect_meshes(n: Node) -> Array:
	var out: Array = []
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c)
		out.append_array(_effect_meshes(c))
	return out


# ==================== 逐簇成长与淡出（覆盖基类的统一 grow） ====================
## ★ 覆盖：每簇火**各自**计时（波前到达才出现；出现后各自活 burn_time 秒）
## 参数 _s：基类签名沿用的"点火进度"（0..1）。本覆盖**故意不使用它**
##   （下划线前缀即此意）：每簇的成长值改由 _wave_t 与自己的 _kd 算出来，
##   所以基类状态机传什么值都不影响；改回用 _s 就等于丢掉"波浪推进"。
## 返回：无。
## 副作用：逐簇写特效的 grow、逐簇设 f.visible 与 _glows[i].visible；
##   debug_sector 打开时每秒打印一行波前进度。注意**不再改 _glow_mat 的 fade**
##   （那是共享材质，会一次性影响所有光斑 —— 它在 _spawn_patches 末尾被设成 1，
##   由这里的 _glows[i].visible 代替它做逐簇显隐）。
## 调用时机：基类 _process 的状态机里，ST_IGNITE / ST_BURN / ST_AFTER 三个阶段
##   **每帧**都会调（基类原版传 0.2..1.0 的进度值，本类忽略）。
## 注意：这里保证 grow 落到 [0,1]（基类会 clampf，本类靠分段公式 + clampf）；
##   并且"年龄夹到 burn_time 上限"是双保险，删掉会重现"前两段没播"的 bug。
func _apply_grow(_s: float) -> void:
	var shown := 0
	for i in range(mini(_used, _patches.size())):
		if i >= _kd.size():
			break
		var f: Node3D = _patches[i]
		if f == null or not is_instance_valid(f):
			continue
		# ★ 双保险（用户要求）：把"簇年龄"上限夹到 burn_time ✓
		#   原因：age > burn_time 会走下面的**余烬淡出**分支 → 卡顿跳时钟时，
		#         早期簇一上来就被算成"已过燃烧期" ✗ → 表现为"前两段没播" ✓
		#   夹住后：这类簇不再淡出，而是 **g 直接为 1、满状态出现** ✓（阶段不会丢 ✓）
		#   代价：这些簇不播"从小长大"（因为它们的成长时间已经过去了 ✓）—— 可接受 ✓
		var age := clampf(_wave_t - float(_kd[i]) * advance_time, 0.0, burn_time)
		var g := 0.0
		# ★ 注意：age 上面已被 clampf 到 [0, burn_time]，所以 `age >= 0.0` 目前**恒真**。
		#   保留这层判断只是为了与基类结构一致、并给"未到波前"留出语义位
		#   （若哪天把 clamp 的下限去掉，它才会真正起到"跳过"的作用）。
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

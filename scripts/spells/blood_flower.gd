extends Node3D
## ============================================================================
## blood_flower.gd —— 法术【嗜血狂花】（一次性范围术法）
## ----------------------------------------------------------------------------
## 需求（用户确认）：
##   · 施放走现有"圆圈选点"流程（spell_targeting：鼠标位置画圈、滚轮改半径、左键确认）
##   · 圈内长出石蒜花（13 帧精灵：标号 1-6 生长 / 7 盛放 / 8-13 枯萎，美术原始序列，
##     每帧都是完整植株、底边对齐）；时间轴 = 1.5s 长成 + 7s 盛放 + 1.5s 枯萎
##   · 持续时间 10s，单次耗蓝 20，圈内敌人每秒扣 5 点血
##   · 圈内全程血雾弥漫，法术结束后血雾消失
##   · 范围内的敌人体表出现流血效果（暗红血膜 + 向下淌的血痕 + 滴血粒子）
##   · 配套测试场景：scenes/测试/嗜血狂花测试.tscn（scripts/blood_flower_test.gd）
##
## 【所属系统】scripts/spells/ 法术系统里的一次性范围术法：
##   · 注册：spell_caster.gd 的 SPELLS 表（键 "blood_flower"）
##   · 轮盘：spell_wheel.gd（第二圈第 4 格，键 1003，显示名"嗜血狂花"）
##   · 数值：data/spell_sheet.json 的 "blood_flower" 行（targeting 段复用同一套选点参数）
##
## 【关键依赖】
##   · autoload Mana（try_spend / current）
##   · scripts/spells/spell_sheet.gd（数值表读取，缺行时用本文件的 @export 兜底）
##   · scripts/spells/body_overlay_chain.gd（把流血膜叠到敌人网格上，可与金膜/水膜共存）
##   · scripts/spells/surface_overlay.gd（收集敌人身上的 MeshInstance3D）
##   · assets/textures/法术特效/嗜血狂花/growth_0~5 + bloom + wither_0~5.png
##     （13 帧石蒜花，透明底、画布 402×658 完全一致）
##   · assets/shaders/blood_flower_sprite.gdshader（花朵本体：换帧过渡 / 摇曳 / 广告牌 / 埋根）
##   · assets/shaders/blood_flower_ground.gdshader（贴地血泊）
##   · assets/shaders/blood_bleed.gdshader（敌人体表流血）
##   · assets/shaders/fog_mist_particle_draw.gdshader（血雾 / 血滴的软圆片）
##
## 【对外接口】（spell_caster 统一调用）
##   setup(player, staff) / has_targeting() / targeting_config() / cast_at(center, radius)
##   start_cast() / stop_cast() / is_casting() / is_effect_alive() / ran_out_of_mana()
##
## 【已知的坑 / 注意事项】
##   1. 本术法是**一次性**：cast_at() 自己发起施法；stop_cast() 必须忽略外部提前停止，
##      否则 spell_caster 会在施法同一帧把它停掉（前摇为 0 的同类坑，见 blue_tornado.gd）。
##   2. 伤害按 delta 累积成小数再转整数调用 take_damage：目标接口只吃 int，
##      若每帧直接 int() 截断，高帧率下永远打不出伤害。
##   3. 流血膜走 body_overlay_chain，**必须成对** attach/detach：
##      敌人离开圈、法术结束、节点销毁（_exit_tree）三处都要收尾，否则场景里会留下永久红膜。
##   4. 花朵是 MeshInstance3D + QuadMesh + blood_flower_sprite.gdshader（**不是 Sprite3D**）：
##      换帧过渡、摇曳、Y 轴广告牌、埋根全在着色器里做。QuadMesh 是 1×1 单位方片，世界尺寸
##      由 shader 的 flower_size 在顶点阶段放大 —— 所以**节点 AABB 仍然是 1×1**，必须设
##      extra_cull_margin（见 _build_flowers），否则花一离开屏幕中心就被视锥剔除掉。
##   5. 换帧不再硬切：用 sweep（0~1）在相邻两帧之间做噪声软边扫描，生长时从下往上、
##      枯萎时（sweep_from_top = 1）从上往下。13 帧画布 402×658 完全一致、底边对齐、
##      水平锚点在种球中心，所以换帧时花朵"从地里长高"，不会整体变形。
##   6. 埋根茎：ground_cut 以下的像素在 fragment 里 discard，土壤线加噪声避免笔直切口。
##      节点中心因此要抬到地表上方 (0.5 - BURY_RATIO) * 画布高（见 _build_flowers 的定位）。
##      **不要**指望地面网格的深度遮挡来藏根茎：花朵是透明混合、不写深度。
##   7. 血雾是 GPUParticles3D + fog_mist_particle_draw.gdshader（unshaded / blend_mix /
##      depth_draw_never），结束前只调 emission 与 strength，不缩放节点。
## ============================================================================

# ==================== 常量与资源路径 ====================
## 数值表读取器（纯 static，不需要实例）
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
## 本术法在 data/spell_sheet.json 里的行键
const SHEET_ID := "blood_flower"
## 体表流血膜的叠加链（与金色守护/流水治疗共存，不互相覆盖）
const CHAIN := preload("res://scripts/spells/body_overlay_chain.gd")
## 收集敌人子树里的可见网格
const SurfaceOverlay := preload("res://scripts/spells/surface_overlay.gd")
## 这个 overylay 层在链里的键（同一术法重复贴只替换，不叠加）
const BLEED_KEY := "blood_flower"

## 石蒜花 13 帧（美术原始序列）：标号 1-6 生长 / 7 盛放 / 8-13 枯萎。
## 全部由 tools 脚本从一张 sprite 表切出，画布 402×658 一致、底边对齐、种球中心水平锚定。
const FRAME_PATHS := [
	"res://assets/textures/法术特效/嗜血狂花/growth_0.png",
	"res://assets/textures/法术特效/嗜血狂花/growth_1.png",
	"res://assets/textures/法术特效/嗜血狂花/growth_2.png",
	"res://assets/textures/法术特效/嗜血狂花/growth_3.png",
	"res://assets/textures/法术特效/嗜血狂花/growth_4.png",
	"res://assets/textures/法术特效/嗜血狂花/growth_5.png",
	"res://assets/textures/法术特效/嗜血狂花/bloom.png",
	"res://assets/textures/法术特效/嗜血狂花/wither_0.png",
	"res://assets/textures/法术特效/嗜血狂花/wither_1.png",
	"res://assets/textures/法术特效/嗜血狂花/wither_2.png",
	"res://assets/textures/法术特效/嗜血狂花/wither_3.png",
	"res://assets/textures/法术特效/嗜血狂花/wither_4.png",
	"res://assets/textures/法术特效/嗜血狂花/wither_5.png",
]
## 帧号：0~6 = 生长（标号 1~7），7~12 = 枯萎（标号 8~13）
const FRAME_BLOOM := 6
const FRAME_LAST := 12
## 生长段 6 个窗口的终点（第 k 个值 = 帧 k 完全接管、开始混到帧 k+1 的进度）。
## 前两段是种球/抽叶（快），中段是茎拔高（慢），末段花苞鼓大、再爆开。
const GROW_ENDS := [0.12, 0.28, 0.50, 0.70, 0.88, 1.0]
## 生长段时长（秒）：所有花在 _life_t = GROW_TIME 时全部长成（每朵起跑时间错开，见 _flower_delay）
const GROW_TIME := 1.5
## 枯萎段时长（秒）：最后 WITHER_TIME 秒整圈花枯萎（起跑错开，终点对齐 duration）
const WITHER_TIME := 1.5
## 画布底部埋进地下的比例（0.15 ≈ 根须 + 大半个种球）。新美术里种球占画布底部约 19%，
## 藏掉 15% 后种球只露一个"从土里冒头的圆顶"（与旧版观感一致），茎从土里长出来。
const BURY_RATIO := 0.15
## 画布高度里"植株实际占的比例"（实测盛放帧 bbox 高 569 / 画布 658 ≈ 0.86）：
## 用于把"露出地表的高度"换算成整张画布的尺寸（见 _build_flowers）。
const PLANT_FRAC := 0.86
## 花头质心在画布里的归一化坐标（实测 bloom 帧红花像素质心 = (0.534w, 0.274h)；
## growth_5 的花苞质心 (0.547, 0.268) 与之几乎重合）：花苞 -> 盛放这一帧用径向揭开，
## 圆心就用这个点，花瓣才是"从花心向外开"。
const HEAD_UV := Vector2(0.534, 0.274)
## 花朵着色器（MeshInstance3D + QuadMesh 用，替代 Sprite3D）
const SPRITE_SHADER := "res://assets/shaders/blood_flower_sprite.gdshader"
## 贴地血泊 / 体表流血 / 血雾三个着色器
const GROUND_SHADER := "res://assets/shaders/blood_flower_ground.gdshader"
const BLEED_SHADER := "res://assets/shaders/blood_bleed.gdshader"
const MIST_SHADER := "res://assets/shaders/fog_mist_particle_draw.gdshader"

# ==================== 可调数值（表缺失时的兜底） ====================
## 单次耗蓝（点）。表键 mana_cost（当前 20）。<= 0 表示跳过蓝量检查。
@export var mana_cost := 20.0
## 持续/扣血时长（秒）。表键 duration（当前 10.0）。到点后只剩余烬淡出，不再扣血。
@export var duration := 10.0
## 收尾淡出时长（秒）。表键 fade_time（当前 0.8）。此阶段**不扣血**。
@export var fade_time := 0.8
## 圈内每秒伤害（点/秒）。来自 targeting.damage_per_sec（当前 5.0）。
@export var damage_per_sec := 5.0
## 圈的兜底半径（米），只在没有经过选点器直接 start_cast 时使用。
@export var default_radius := 2.5
## 每朵花占用的圈面积（平方米/朵）：圈越大花越多，再被上下限夹住。
@export var area_per_flower := 0.5
## 花朵数量上下限（性能护栏：最多 flower_max 个 MeshInstance3D）。
@export var flower_min := 18
@export var flower_max := 72
## 花朵**露出地表**的世界高度范围（米）：画布上下留白较大，按 PLANT_FRAC 换算成画布高。
@export var flower_height_min := 0.9
@export var flower_height_max := 1.3
## 血雾粒子数量（越大越浓，性能开销线性上升）。
@export var mist_amount := 36
## 血雾整体不透明度上限（0~1）。
@export var mist_strength := 0.55

# ==================== 运行期状态 ====================
## 是否处于效果期（is_casting / is_effect_alive 的唯一来源）。false 时 _process 直接空转。
var casting := false
## 上一次 cast_at 是否因蓝不足而放弃。
var _ran_out := false
## 施法者引用（setup 注入）。只用于选点兜底与射线排除，不建立父子关系。
var _player: Node3D = null
## 圈心（世界坐标，落在选点射线命中的地表上）与半径。
var _center := Vector3.ZERO
var _radius := 2.5
## cast_at 是否给过圈心：只用来区分"选点器给了 (0,0,0)"与"没选点直接施法"，
## 避免真正的世界原点被当成"没传"而改落到角色身前。
var _has_center := false
## 本次施法已存活时间（秒）。
var _life_t := 0.0
## 状态机：0 = 空闲/已结束，1 = 生长+扣血，2 = 收尾淡出。
var _phase := 0
## 伤害小数累积：敌人实例 id -> 不足 1 点的零头。
var _dmg_acc: Dictionary = {}

## 花朵节点、每朵的着色器材质、起跑延迟（生长）、起跑延迟（枯萎）、基础摇曳幅度、当前帧号缓存
var _flowers: Array[MeshInstance3D] = []
var _flower_mats: Array[ShaderMaterial] = []
var _flower_delay: Array[float] = []
var _flower_wdelay: Array[float] = []
var _flower_sway: Array[float] = []
var _flower_frame: Array[int] = []
## 贴地血泊（QuadMesh + blood_flower_ground.gdshader）
var _pool: MeshInstance3D = null
var _pool_mat: ShaderMaterial = null
## 血雾粒子
var _mist: GPUParticles3D = null
var _mist_mat: ShaderMaterial = null
## 圈内的红光（让血雾更"有色"）
var _light: OmniLight3D = null
## 体表流血：敌人实例 id -> {node, meshes, fx}
var _bleeding: Dictionary = {}
## 体表流血材质（全场共用一份，shader 里用 TIME 自走动画）
var _bleed_mat: ShaderMaterial = null
## 花朵帧纹理缓存（首次施法时 load 一次，之后走资源缓存）
var _frames: Array[Texture2D] = []
var _frame_w := 433.0
var _frame_h := 875.0
var _rng := RandomNumberGenerator.new()


# ==================== 生命周期 ====================
## 节点进树时开启每帧处理（状态机靠 _process 推进）。
func _ready() -> void:
	set_process(true)
	_rng.randomize()


## 由 spell_caster 在实例化后调用一次：注入施法者 + 读数值表。
func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	_load_sheet()


## 数值表覆盖 @export 兜底值（表缺行时全部沿用当前默认值）。
func _load_sheet() -> void:
	if not SHEET.has(SHEET_ID):
		push_warning("[嗜血狂花] 数值表里没有 %s（使用导出默认值）" % SHEET_ID)
		return
	mana_cost = SHEET.f(SHEET_ID, "mana_cost", mana_cost)
	duration = SHEET.f(SHEET_ID, "duration", duration)
	fade_time = SHEET.f(SHEET_ID, "fade_time", fade_time)
	var tg: Dictionary = SHEET.get_spell(SHEET_ID).get("targeting", {})
	damage_per_sec = float(tg.get("damage_per_sec", damage_per_sec))


# ==================== 选点器契约（圆圈选点） ====================
## 是否使用通用圈选选点器：读表里 targeting.enabled。
func has_targeting() -> bool:
	var row: Dictionary = SHEET.get_spell(SHEET_ID)
	var tg: Dictionary = row.get("targeting", {})
	return bool(tg.get("enabled", false))


## 交给 spell_targeting 的圈选参数（直径/射程/滚轮步长/圈贴图）。
func targeting_config() -> Dictionary:
	return SHEET.get_spell(SHEET_ID).get("targeting", {})


## 选点确认：记录圆心/半径并**自己发起施法**（caster 选点后只调本函数）。
func cast_at(center: Vector3, radius: float) -> void:
	_center = center
	_has_center = true
	_radius = maxf(radius, 0.5)
	start_cast()


## 开始施法：先查蓝再扣蓝（原子性），然后建全部视觉、重置计时。
func start_cast() -> void:
	if _phase != 0:
		return
	_ran_out = false
	if mana_cost > 0.0:
		var cur := float(Mana.get("current"))
		if cur < mana_cost:
			_ran_out = true
			print("[嗜血狂花] ✗ 法力不足（需要 %.0f，当前 %.0f）→ 本次不生效" % [mana_cost, cur])
			return
		if not Mana.try_spend(mana_cost):
			_ran_out = true
			print("[嗜血狂花] ✗ 扣蓝失败 → 本次不生效")
			return
	# 没经过选点器（直接 start_cast）时：落在角色前方 default_radius 处
	if not _has_center and _player != null:
		_center = _player.global_position + Vector3(0.0, 0.0, -2.2)
	_radius = maxf(_radius, 0.5)
	_life_t = 0.0
	_dmg_acc.clear()
	_phase = 1
	casting = true
	global_transform = Transform3D(Basis.IDENTITY, _center)
	_build_flowers()
	_build_pool()
	_build_mist()
	_build_light()
	print("[嗜血狂花] 生效 ✓ 持续 %.1fs ｜ 每秒 %.0f 伤害 ｜ 半径 %.2f ｜ 花朵 %d 朵" % [
			duration, damage_per_sec, _radius, _flowers.size()])


## 一次性法术：忽略外部提前停止（caster 会在施法同帧调用一次）。
func stop_cast() -> void:
	return


## 是否正在生效。
func is_casting() -> bool:
	return casting


## 供 _sweep_instances 使用：淡出阶段也算"还活着"，不能提前释放。
func is_effect_alive() -> bool:
	return _phase != 0


## 上一次施法是否因为蓝不够而失败。
func ran_out_of_mana() -> bool:
	return _ran_out


# ==================== 每帧驱动 ====================
func _process(delta: float) -> void:
	if _phase == 0:
		return
	_life_t += delta
	if _phase == 2:
		_update_fade()
		return
	_update_flowers()
	_update_enemies(delta)
	_update_mist(true)
	# 10s 到点：停止发射血雾、摘掉流血膜，进入淡出（不再扣血、不再判圈）
	if _life_t >= duration:
		_phase = 2
		if _mist != null:
			_mist.emitting = false
		_clear_bleeding()


## 花朵动画：0~GROW_TIME 生长、GROW_TIME~(duration-WITHER_TIME) 盛放、最后 WITHER_TIME 枯萎。
## 每朵花有自己的延迟，起跑错开但**终点对齐**（避免整圈同步换帧像"翻页"）。
## 换帧走 shader 的 sweep 软边过渡，这里只负责算 (当前帧 idx, 过渡进度 sweep)。
func _update_flowers() -> void:
	var n := _flowers.size()
	var last := _frames.size() - 1
	var wither_start := duration - WITHER_TIME
	for i in range(n):
		var mat := _flower_mats[i]
		if mat == null:
			continue
		var fpos := 0.0
		var from_top := 0.0
		var grow := 0.0
		if _life_t >= wither_start:
			# 枯萎：帧 6(盛放) -> 12(倒伏枯死)，从上往下消失（花头先枯、茎叶后枯）
			grow = 1.0
			from_top = 1.0
			var wd := _flower_wdelay[i]
			var w := clampf((_life_t - wither_start - wd) / maxf(WITHER_TIME - wd, 0.1), 0.0, 1.0)
			fpos = float(FRAME_BLOOM) + w * float(FRAME_LAST - FRAME_BLOOM)
		else:
			# 生长：帧 0 -> 6，从下往上长
			var d := _flower_delay[i]
			var p := clampf((_life_t - d) / maxf(GROW_TIME - d, 0.15), 0.0, 1.0)
			grow = p
			fpos = _frame_pos(p)
		var idx := int(floor(fpos))
		var sweep := 0.0
		if idx >= last:
			idx = last
		else:
			sweep = fpos - float(idx)
		# 贴图只在换帧时改写（idx 不变时纯靠 sweep 在两张之间扫，省掉每帧的贴图重绑）
		if idx != _flower_frame[i]:
			_flower_frame[i] = idx
			mat.set_shader_parameter("flower_a", _frames[idx])
			mat.set_shader_parameter("flower_b", _frames[mini(idx + 1, last)])
			# 只有"花苞 -> 盛放"（帧 5 -> 6）用径向揭开：贴着同一颗花头，花瓣从花心向外开。
			# 其余换帧都是植株拔高/倒伏，纵向擦除（生长向上、枯萎向下）更自然。
			mat.set_shader_parameter("radial", 1.0 if idx == FRAME_BLOOM - 1 else 0.0)
		mat.set_shader_parameter("sweep", sweep)
		mat.set_shader_parameter("sweep_from_top", from_top)
		# 刚冒头的花摇曳幅度小，长成后才进入完整摆动（像萌发/抽穗）
		mat.set_shader_parameter("sway_amp", _flower_sway[i] * (0.25 + 0.75 * grow))


## 把生长进度 p（0~1）映射成"帧浮点号"：0~1 属于帧 0，1~2 属于帧 1，以此类推。
## 窗口按 GROW_ENDS 不等分（种球/抽叶快、茎拔高慢），返回 0~GROW_ENDS.size()（本表 = 6）。
func _frame_pos(p: float) -> float:
	var prev := 0.0
	for i in range(GROW_ENDS.size()):
		var e := float(GROW_ENDS[i])
		if p < e:
			return float(i) + (p - prev) / maxf(e - prev, 0.0001)
		prev = e
	return float(GROW_ENDS.size())


## 淡出：血泊/花朵/血雾一起收到 0，结束后收尾。
func _update_fade() -> void:
	var f := clampf((_life_t - duration) / maxf(fade_time, 0.001), 0.0, 1.0)
	var left := 1.0 - f
	if _pool_mat != null:
		_pool_mat.set_shader_parameter("fade", left)
	if _mist != null:
		_mist.emitting = false
		_update_mist_strength(mist_strength * left)
	for mat in _flower_mats:
		if mat != null:
			mat.set_shader_parameter("fade", left)
	if _light != null:
		_light.light_energy = 0.8 * left
	if f >= 1.0:
		_finish()


## 正常收尾：清流血膜、隐藏所有视觉、退出效果期（剩下的由 caster 的清理回收节点）。
func _finish() -> void:
	_phase = 0
	casting = false
	_clear_bleeding()
	if _mist != null:
		_mist.emitting = false
	for spr in _flowers:
		if spr != null and is_instance_valid(spr):
			spr.visible = false
	if _pool != null:
		_pool.visible = false
	if _light != null:
		_light.visible = false


## 节点销毁兜底：**必须**摘掉所有体表流血膜，否则敌人身上会留下永久红膜。
func _exit_tree() -> void:
	_clear_bleeding()


# ==================== 圈内敌人：扣血 + 体表流血 ====================
## 找敌人（沿用项目约定：组 "enemies"）
func _find_targets() -> Array:
	var tree := get_tree()
	if tree == null:
		return []
	return tree.get_nodes_in_group("enemies")


## 每帧结算圈内敌人：小数伤害累积成整数扣血；进入圈内的敌人贴流血膜 + 滴血粒子，
## 离开圈（或节点销毁）立刻摘下。**伤害只在 _phase == 1 时调用本函数**（淡出不扣血）。
func _update_enemies(delta: float) -> void:
	var dmg := damage_per_sec * delta
	var seen: Dictionary = {}
	for t in _find_targets():
		var node := t as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var p := node.global_position
		var flat := Vector3(p.x - _center.x, 0.0, p.z - _center.z)
		if flat.length() > _radius:
			continue
		var id := node.get_instance_id()
		seen[id] = true
		if dmg > 0.0 and node.has_method("take_damage"):
			var acc := float(_dmg_acc.get(id, 0.0)) + dmg
			var whole := int(floor(acc))
			if whole > 0:
				acc -= float(whole)
				node.call("take_damage", whole)
			_dmg_acc[id] = acc
		_ensure_bleeding(node)
	# 离开圈的敌人：摘膜（用 seen 差集，避免每帧遍历整棵树）
	for id in _bleeding.keys():
		if not seen.has(id):
			_remove_bleeding(id)


## 给圈内敌人贴流血膜并挂滴血粒子（同一敌人只做一次）。
func _ensure_bleeding(node: Node3D) -> void:
	var id := node.get_instance_id()
	if _bleeding.has(id):
		return
	if _bleed_mat == null:
		var sh := load(BLEED_SHADER) as Shader
		if sh == null:
			push_warning("[嗜血狂花] 缺少 blood_bleed.gdshader，体表流血不可用")
			return
		_bleed_mat = ShaderMaterial.new()
		_bleed_mat.shader = sh
	# 网格用 material_overlay 叠加：不动物体自己的材质，多个法术可共存
	var meshes: Array = SurfaceOverlay.visible_meshes(node)
	for mi in meshes:
		if mi is MeshInstance3D and is_instance_valid(mi):
			CHAIN.attach(mi as MeshInstance3D, BLEED_KEY, _bleed_mat)
	# 滴血粒子：挂在敌人节点下（跟随敌人），世界空间发射 -> 血滴落下后留在原地
	var fx := _make_drip_particles(node)
	if fx != null:
		node.add_child(fx)
	_bleeding[id] = {"node": node, "meshes": meshes, "fx": fx}


## 摘掉某个敌人的流血效果（节点已释放也安全）。
func _remove_bleeding(id: int) -> void:
	if not _bleeding.has(id):
		return
	var e: Dictionary = _bleeding[id]
	var meshes: Array = e.get("meshes", [])
	for mi in meshes:
		if mi is MeshInstance3D and is_instance_valid(mi):
			CHAIN.detach(mi as MeshInstance3D, BLEED_KEY, _bleed_mat)
	var fx := e.get("fx") as Node
	if fx != null and is_instance_valid(fx):
		fx.queue_free()
	_bleeding.erase(id)


## 清空全部流血效果（法术结束 / 淡出 / 节点销毁都走这里）。
func _clear_bleeding() -> void:
	for id in _bleeding.keys():
		_remove_bleeding(int(id))


# ==================== 视觉装配：花朵 / 血泊 / 血雾 / 红光 ====================
## 读入 13 帧纹理（资源缓存，重复施法不会重复解码）。
func _ensure_frames() -> void:
	if not _frames.is_empty():
		return
	for path in FRAME_PATHS:
		var tex := load(path) as Texture2D
		if tex != null:
			_frames.append(tex)
	if _frames.is_empty():
		push_warning("[嗜血狂花] 花朵帧纹理全部加载失败（检查 assets/textures/法术特效/嗜血狂花/）")
		return
	_frame_w = float(_frames[0].get_width())
	_frame_h = float(_frames[0].get_height())


## 圈内撒花：随机均匀布点（sqrt 让分布不在圆心堆积），每朵一个 MeshInstance3D + 单位方片。
## 世界尺寸在 shader 顶点阶段放大；埋地比例写进 ground_cut，节点中心据 BURY_RATIO 抬高。
func _build_flowers() -> void:
	_ensure_frames()
	if _frames.is_empty():
		return
	var shader := load(SPRITE_SHADER) as Shader
	if shader == null:
		push_warning("[嗜血狂花] 缺少 blood_flower_sprite.gdshader，花朵不可用")
		return
	var count := clampi(int(round(PI * _radius * _radius / maxf(area_per_flower, 0.05))), flower_min, flower_max)
	# 全部花共用一份 1×1 单位方片：每朵只是自己的 ShaderMaterial 不同
	var quad := QuadMesh.new()
	quad.size = Vector2(1.0, 1.0)
	var aspect := _frame_w / maxf(_frame_h, 1.0)
	for i in range(count):
		var ang := _rng.randf_range(0.0, TAU)
		var rr := _radius * sqrt(_rng.randf()) * 0.94
		var wx := _center.x + cos(ang) * rr
		var wz := _center.z + sin(ang) * rr
		var gy := _ground_y(Vector3(wx, _center.y, wz))
		# 露出地表的高度 = flower_height_*；画布里植株只占 PLANT_FRAC（上下留白 + 埋根），
		# 所以整张画布的世界高度要反推：h = 露出高度 / (PLANT_FRAC - BURY_RATIO)
		var h := _rng.randf_range(flower_height_min, flower_height_max) / (PLANT_FRAC - BURY_RATIO)
		var mi := MeshInstance3D.new()
		mi.name = "BloodFlower_%d" % i
		mi.mesh = quad
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# ★ 顶点阶段把方片放大到 h，但 AABB 还是 1×1：不补余量花会被视锥剔除
		mi.extra_cull_margin = h
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("flower_a", _frames[0])
		mat.set_shader_parameter("flower_b", _frames[mini(1, _frames.size() - 1)])
		mat.set_shader_parameter("flower_size", Vector2(h * aspect, h))
		mat.set_shader_parameter("ground_cut", BURY_RATIO)
		var flip := _rng.randf() < 0.5
		mat.set_shader_parameter("flip_x", 1.0 if flip else 0.0)
		# 镜像后花头质心的 x 要跟着翻，否则径向揭开的圆心会偏
		mat.set_shader_parameter("head_uv",
				Vector2(1.0 - HEAD_UV.x if flip else HEAD_UV.x, HEAD_UV.y))
		mat.set_shader_parameter("head_aspect", aspect)
		var base_sway := h * _rng.randf_range(0.022, 0.045)
		mat.set_shader_parameter("sway_amp", base_sway * 0.25)
		mat.set_shader_parameter("sway_speed", _rng.randf_range(1.1, 2.2))
		mat.set_shader_parameter("sway_phase", _rng.randf_range(0.0, TAU))
		mat.set_shader_parameter("fade", 1.0)
		mi.material_override = mat
		add_child(mi)
		# 土壤线（UV.y = 1 - BURY_RATIO）落在世界地表 => 节点中心在地表上方 (0.5 - BURY_RATIO) * h
		mi.position = to_local(Vector3(wx, gy + h * (0.5 - BURY_RATIO), wz))
		_flowers.append(mi)
		_flower_mats.append(mat)
		# 起跑错开、终点对齐：延迟越大自己那段越短，全部在 GROW_TIME 长成
		_flower_delay.append(_rng.randf_range(0.0, GROW_TIME * 0.25))
		_flower_wdelay.append(_rng.randf_range(0.0, WITHER_TIME * 0.2))
		_flower_sway.append(base_sway)
		_flower_frame.append(0)


## 贴地血泊：一块按圈直径铺开的扁四边形，颜色/透明度由 shader 自己走。
func _build_pool() -> void:
	var sh := load(GROUND_SHADER) as Shader
	if sh == null:
		push_warning("[嗜血狂花] 缺少 blood_flower_ground.gdshader，贴地血泊不可用")
		return
	var quad := QuadMesh.new()
	quad.size = Vector2(_radius * 2.0, _radius * 2.0)
	_pool = MeshInstance3D.new()
	_pool.name = "BloodPool"
	_pool.mesh = quad
	_pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_pool_mat = ShaderMaterial.new()
	_pool_mat.shader = sh
	_pool_mat.set_shader_parameter("fade", 0.0)
	_pool.material_override = _pool_mat
	add_child(_pool)
	var gy := _ground_y(_center) + 0.02
	_pool.position = to_local(Vector3(_center.x, gy, _center.z))
	_pool.rotation = Vector3(-PI * 0.5, 0.0, 0.0)


## 血雾：GPUParticles3D 铺满整个圈，粒子用软圆片 shader，颜色暗红。
func _build_mist() -> void:
	var sh := load(MIST_SHADER) as Shader
	if sh == null:
		push_warning("[嗜血狂花] 缺少 fog_mist_particle_draw.gdshader，血雾不可用")
		return
	_mist = GPUParticles3D.new()
	_mist.name = "BloodMist"
	_mist.amount = mist_amount
	_mist.lifetime = 4.0
	_mist.preprocess = 0.8
	_mist.explosiveness = 0.0
	_mist.randomness = 0.85
	_mist.fixed_fps = 0
	_mist.local_coords = true
	_mist.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD
	_mist.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_mist.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mist.visibility_aabb = AABB(
			Vector3(-_radius - 4.0, -2.0, -_radius - 4.0),
			Vector3(_radius * 2.0 + 8.0, 9.0, _radius * 2.0 + 8.0))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(_radius * 0.82, 0.55, _radius * 0.82)
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 80.0
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.28
	pm.gravity = Vector3(0.01, 0.03, 0.01)
	pm.scale_min = 1.0
	pm.scale_max = 2.3
	pm.angle_min = 0.0
	pm.angle_max = 360.0
	pm.angular_velocity_min = -0.15
	pm.angular_velocity_max = 0.15
	pm.damping_min = 0.05
	pm.damping_max = 0.2
	if "turbulence_enabled" in pm:
		pm.turbulence_enabled = true
		pm.turbulence_noise_strength = 0.35
		pm.turbulence_noise_scale = 2.2
		pm.turbulence_influence_min = 0.02
		pm.turbulence_influence_max = 0.08
	pm.color_ramp = _make_ramp([
		Color(0.55, 0.06, 0.10, 0.0),
		Color(0.50, 0.05, 0.09, 0.85),
		Color(0.42, 0.03, 0.06, 0.55),
		Color(0.35, 0.02, 0.05, 0.0),
	])
	_mist.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(1.35, 1.35)
	_mist.draw_pass_1 = quad
	_mist_mat = ShaderMaterial.new()
	_mist_mat.shader = sh
	_mist_mat.set_shader_parameter("mist_color", Color(0.46, 0.05, 0.09))
	_mist_mat.set_shader_parameter("softness", 0.5)
	_mist_mat.set_shader_parameter("strength", mist_strength)
	_mist_mat.set_shader_parameter("min_pixel_size", 2.0)
	quad.material = _mist_mat
	_mist.emitting = true
	add_child(_mist)
	_mist.position = to_local(Vector3(_center.x, _center.y + 0.9, _center.z))


## 圈中心的暗红补光（不投影，纯氛围）。
func _build_light() -> void:
	_light = OmniLight3D.new()
	_light.name = "BloodGlow"
	_light.light_color = Color(0.55, 0.07, 0.09)
	_light.light_energy = 0.8
	_light.omni_range = _radius * 1.4
	_light.omni_attenuation = 1.2
	_light.shadow_enabled = false
	add_child(_light)
	_light.position = to_local(Vector3(_center.x, _center.y + 1.0, _center.z))


## 血雾强度（淡出阶段由 _update_fade 逐帧压低）。
func _update_mist(on: bool) -> void:
	if _mist != null and _mist.emitting != on:
		_mist.emitting = on
	_update_mist_strength(mist_strength)


func _update_mist_strength(v: float) -> void:
	if _mist_mat != null:
		_mist_mat.set_shader_parameter("strength", v)


## 敌人身上的滴血粒子（小颗软圆片、受重力下落、世界空间）。
func _make_drip_particles(parent_node: Node3D) -> GPUParticles3D:
	var sh := load(MIST_SHADER) as Shader
	if sh == null:
		return null
	var fx := GPUParticles3D.new()
	fx.name = "BloodDrip"
	fx.amount = 16
	fx.lifetime = 0.7
	fx.explosiveness = 0.0
	fx.randomness = 0.9
	fx.local_coords = false
	fx.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.visibility_aabb = AABB(Vector3(-1.0, -2.0, -1.0), Vector3(2.0, 3.0, 2.0))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.28
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 25.0
	pm.initial_velocity_min = 0.05
	pm.initial_velocity_max = 0.35
	pm.gravity = Vector3(0.0, -7.0, 0.0)
	pm.scale_min = 0.35
	pm.scale_max = 0.7
	pm.color_ramp = _make_ramp([
		Color(0.62, 0.05, 0.06, 0.0),
		Color(0.55, 0.03, 0.05, 1.0),
		Color(0.40, 0.02, 0.03, 0.0),
	])
	fx.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(0.09, 0.09)
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("mist_color", Color(0.62, 0.06, 0.07))
	mat.set_shader_parameter("softness", 0.2)
	mat.set_shader_parameter("strength", 1.0)
	mat.set_shader_parameter("min_pixel_size", 1.0)
	quad.material = mat
	fx.draw_pass_1 = quad
	fx.emitting = true
	# 挂在敌人胸口高度（父节点是敌人根，模型一般 1~1.6m 高）
	fx.position = Vector3(0.0, 1.05, 0.0)
	return fx


## 生成三色以上的颜色渐变纹理（ParticleProcessMaterial.color_ramp 用）。
func _make_ramp(colors: Array) -> GradientTexture1D:
	var g := Gradient.new()
	var cols := PackedColorArray()
	var offs := PackedFloat32Array()
	for i in range(colors.size()):
		cols.append(colors[i])
		offs.append(float(i) / float(maxi(colors.size() - 1, 1)))
	g.colors = cols
	g.offsets = offs
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


# ==================== 地表高度 ====================
## 从圈心上方竖直打一条射线找地表；打不到就退回圈心高度。
## 掩码不限层，但排除施法者与敌人（否则可能把花种在角色/靶子头顶）。
func _ground_y(world_pos: Vector3) -> float:
	var space := get_world_3d().direct_space_state
	if space == null:
		return world_pos.y
	var from := Vector3(world_pos.x, world_pos.y + 6.0, world_pos.z)
	var to := Vector3(world_pos.x, world_pos.y - 6.0, world_pos.z)
	var params := PhysicsRayQueryParameters3D.create(from, to, 0xFFFFFFFF)
	var excludes: Array[RID] = []
	if _player is CollisionObject3D:
		excludes.append((_player as CollisionObject3D).get_rid())
	for t in _find_targets():
		if t is CollisionObject3D:
			excludes.append((t as CollisionObject3D).get_rid())
	params.exclude = excludes
	var hit := space.intersect_ray(params)
	if hit.is_empty():
		return world_pos.y
	return float((hit["position"] as Vector3).y)

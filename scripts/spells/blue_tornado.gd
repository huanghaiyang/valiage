extends Node3D
## 蓝色龙卷风 —— 把 scenes/法术特效/蓝色龙卷风.tscn 接进法术体系。
##
## 与另外两个法术的**实现方式不同**，这点很关键：
##   · 火焰喷射 / 火焰编织 = GPUParticles3D，靠 `emitting` 开关；
##   · 蓝色龙卷风        = **静态网格 + VisualShader**，动画由着色器里的 TIME 驱动，
##                        所以"施法/停法"就是显隐节点，没有 emitting 可切。
##
## 摆放参考上游原始工程（spells-design/scenes/map.tscn）：
##   那边是**竖直、贴地、缩放 0.7**（演示场景，网格 12 单位高）。
##   本作角色约 1.08m，所以默认缩到 0.3（≈3.6m 高），在角色正前方地面升起。
##
## 对外接口与另外两个法术完全一致：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()

const TORNADO_SCENE: PackedScene = preload("res://scenes/法术特效/蓝色龙卷风.tscn")
## 方向 + 起始位置：与另外两个法术共用同一份实现
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

@export var mana_per_sec := 0.0        ## 每秒耗蓝（本次改为**一次性** ✓ 故默认 0 ✓）
## ★★ 数值表接入（用户需求 ✓）：下面这些默认值会被 data/spell_sheet.json 覆盖 ✓
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
const SHEET_ID := "blue_tornado"
@export var one_shot := true           ## 一次性施放 ✓
@export var mana_cost := 20.0          ## 单次耗蓝 20 ✓
@export var duration := 8.0            ## 持续时间 8s ✓
@export var fade_time_sheet := 0.8     ## 收尾淡出 ✓
@export var total_time := 8.0          ## 整体时长 ✓
@export var damage_per_sec := 20.0     ## 圈内每秒扣血 20 ✓
## ★★★ 进阶：局部风场（用户需求 ✓ 龙卷风影响周围植被的风速与风向）
@export var wind_radius_mul := 1.8     ## 风场半径 = 圈半径 × 这个系数 ✓（想影响更远 → 调大 ✓）
@export var wind_strength_add := 0.6   ## 局部风速的增量 ✓（越大越剧烈 ✓）
@export var swirl_ccw := false         ## 环流方向：**false = 顺时针** ✓（与龙卷风模型一致 ✓ 用户要求）
## ★ 圈选选择器状态（由 spell_targeting 通过 cast_at() 写入 ✓）
var _center := Vector3.ZERO
var _radius := 2.5
var _life_t := 0.0                     ## 本次已存活时间（到 total_time 自动结束 ✓）
var _dmg_acc: Dictionary = {}          ## 目标 id -> 累积小数伤害（保证 take_damage 收到整数 ✓）
@export var tornado_scale := 0.3      ## 网格原始 12 单位高 -> 0.3 ≈ 3.6m
@export var spawn_distance := 2.2     ## 落点：角色正前方多少米

var casting := false

var _aim := SpellAim.new()
var _tornado: Node3D = null
var _ran_out := false


func _ready() -> void:
	set_process(true)
	_tornado = TORNADO_SCENE.instantiate() as Node3D
	if _tornado == null:
		push_warning("[BlueTornado] 场景根节点不是 Node3D: " + TORNADO_SCENE.resource_path)
		return
	_tornado.name = "BlueTornado"
	_tornado.scale = Vector3.ONE * tornado_scale
	_tornado.visible = false          # 没施法时不显示
	add_child(_tornado)


func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)
	# ★★★ 读数值表（用户需求 ✓）：一次性 / 20 蓝 / 8 秒 / 圈内每秒 20 伤害
	#   圈选参数（targeting）由 spell_targeting 通过 targeting_config() 读取 ✓
	var row: Dictionary = SHEET.get_spell(SHEET_ID)
	if row.is_empty():
		print("[蓝色龙卷风] ✗ 数值表里没有 %s（用导出默认值）" % SHEET_ID)
	else:
		one_shot = bool(row.get("one_shot", one_shot))
		mana_cost = float(row.get("mana_cost", mana_cost))
		mana_per_sec = float(row.get("mana_per_sec", mana_per_sec))
		duration = float(row.get("duration", duration))
		fade_time_sheet = float(row.get("fade_time", fade_time_sheet))
		total_time = float(row.get("total_time", duration + fade_time_sheet))
		var tg: Dictionary = row.get("targeting", {})
		damage_per_sec = float(tg.get("damage_per_sec", damage_per_sec))
		print("[蓝色龙卷风] 数值表 ✓ one_shot=%s ｜ 耗蓝=%.0f ｜ 持续=%.1fs ｜ 每秒伤害=%.0f ｜ 圈选=%s" % [
				str(one_shot), mana_cost, duration, damage_per_sec, str(tg.get("enabled", false))])


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	# ★★★ 一次性施放（用户需求 ✓）：由自己计时结束 ✓（忽略 caster 的提前 stop ✗）
	#   前摇 0 → caster 会在同帧调 stop_cast() ✗ → 必须忽略 ✓（否则刚出现就消失 ✓）
	#   耗蓝 20 一次扣 ✓（先判余额 ✓ 照 flame_scorch 的写法 ✓）
	if mana_cost > 0.0:
		var cur := float(Mana.get("current"))
		if cur < mana_cost:
			print("[蓝色龙卷风] ✗ 法力不足（需要 %.0f，当前 %.0f）→ 本次不生效" % [mana_cost, cur])
			return
		if not Mana.try_spend(mana_cost):
			print("[蓝色龙卷风] ✗ 扣蓝失败 → 本次不生效")
			return
	_life_t = 0.0
	_dmg_acc.clear()
	casting = true
	_place()                          # 先摆好位置再显示，避免第一帧闪在旧位置
	_set_visible(true)
	print("[蓝色龙卷风] 生效 ✓ 持续 %.1fs ｜ 圈内每秒 %.0f 伤害 ｜ 半径 %.2f ｜ 缩放 ×%.2f（%.1f m 高）" % [
			total_time, damage_per_sec, _radius, clampf(_radius / 2.5, 0.5, 3.0),
			tornado_scale * clampf(_radius / 2.5, 0.5, 3.0) * 12.0])


func stop_cast() -> void:
	# 一次性：忽略 caster 的提前 stop ✗（前摇 0 时它会同帧调用 ✓）
	if one_shot:
		return
	casting = false
	_set_visible(false)


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 方向（水平、世界空间）—— 实现在 spell_aim.gd，与另外两个法术共用
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 起点（世界坐标）—— 竖直的龙卷风贴地升起，所以高度取 0
func origin_global() -> Vector3:
	_aim.origin_at_staff = false
	_aim.front_height = 0.0
	_aim.front_offset = spawn_distance
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _tornado == null or not casting:
		return

	_place()
	_life_t += delta
	# ★★★ 进阶（用户需求 ✓）：广播**局部风场**给植被 shader ✓
	#   机制同 camera_rig 的 occ_player_uv ✓：RenderingServer.global_shader_parameter_set ✓
	#   植被 shader 里 `global uniform vec3 tornado_pos;` 等声明后即可就地使用 ✓
	_publish_wind(clampf(1.0 - _life_t / maxf(total_time, 0.01), 0.0, 1.0))
	# ★★★ 圈内每秒扣血 20（用户需求 ✓）：持续阶段每帧调用 ✓（按 delta 累积成整数伤害 ✓）
	_apply_damage(delta)

	# ★★ 整体到点自动结束（一次性 ✓ 用户需求 8 秒）
	if _life_t >= total_time:
		print("[蓝色龙卷风] 整体 %.1fs 到点 ✓ 结束" % total_time)
		casting = false
		_set_visible(false)
		_clear_wind()          # ★ 局部风场归零 ✓（否则植被会一直以为旁边有龙卷风 ✗）
		return

	# 兼容：表里 mana_per_sec 若改回 >0（持续耗蓝型）则保留原逻辑 ✓；现在为 0 不会扣 ✓
	if mana_per_sec > 0.0:
		if Mana.spend_rate(delta, mana_per_sec):
			_ran_out = false
			_set_visible(true)
		else:
			_ran_out = true
			_set_visible(false)


# ---------------------------------------------------------------- 圈选（同火焰灼烧 ✓）
## ★ span_targeting 契约：法术是否使用"圈选选点器"
func has_targeting() -> bool:
	var row: Dictionary = SHEET.get_spell(SHEET_ID)
	var tg: Dictionary = row.get("targeting", {})
	return bool(tg.get("enabled", false))


## 交给通用选点器的参数（与 flame_scorch 同一套 ✓）
func targeting_config() -> Dictionary:
	return SHEET.get_spell(SHEET_ID).get("targeting", {})


## 选点完成 → 记下圆心与半径 + ★**自己开始施法** ✓
## ★★★ 关键（对照火焰灼烧 ✓）：caster 在选点确认后**只调 `cast_at()`** ✗
##   （见 spell_caster.gd:399-408，它**不会**再调 start_cast() ✗）
##   → 所以"开始施法"必须由 cast_at() 自己完成 ✓
##   （火焰灼烧就是这么做 ✓：它的 cast_at 里记下圆心/半径后直接进入自己的状态机 ✓）
func cast_at(center: Vector3, radius: float) -> void:
	_center = center
	_radius = maxf(radius, 0.5)
	start_cast()          # ★ 真正开始（扣蓝 20 ✓ 摆到圈心 ✓ 开始计时 8 秒 ✓ 开打）


# ---------------------------------------------------------------- 圈内伤害（照 flame_scorch ✓）
## 每秒扣血：只在**持续阶段**调用 ✓（余烬/淡出不扣 ✓）
func _apply_damage(delta: float) -> void:
	var dmg := damage_per_sec * delta
	if dmg <= 0.0:
		return
	for t in _find_targets():
		var node := t as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var p := node.global_position
		var flat := Vector3(p.x - _center.x, 0.0, p.z - _center.z)
		if flat.length() > _radius:
			continue                                   # 不在圈内 ✓
		var id := node.get_instance_id()
		var acc := float(_dmg_acc.get(id, 0.0)) + dmg
		var whole := int(floor(acc))
		if whole > 0:
			acc -= float(whole)
			node.call("take_damage", whole)            # 敌人在组 "enemies" ✓ 且有 take_damage ✓
		_dmg_acc[id] = acc


## 找敌人：组 "enemies" 优先（与 flame_scorch 完全一致 ✓）
func _find_targets() -> Array:
	var tree := get_tree()
	if tree == null:
		return []
	return tree.get_nodes_in_group("enemies")


# ---------------------------------------------------------------- 内部
## 起点摆到 origin_global()；基向量保持**世界对齐** -> 龙卷风永远竖直（不随瞄准倾斜）
func _place() -> void:
	# ★★ 圈选（用户需求 ✓）：选了圆心就落在圆心 ✓；没选过（_center 为 0）则退回"角色正前方"✓
	var pos := _center if _center != Vector3.ZERO else origin_global()
	pos.y = 0.0                       # 竖直贴地 ✓（与原来一致 ✓）
	# ★★★ 圆的大小**控制龙卷风缩放**（用户需求 ✓）：滚轮放大/缩小圆 → 龙卷风同步变大/变小 ✓
	#   基准 = 默认半径 2.5（对应 tornado_scale 0.3 ≈ 3.6m 高 ✓）
	#   范围夹在 0.5~3.0 倍 ✓（防止极端缩放出问题 ✓）
	var mul := clampf(_radius / 2.5, 0.5, 3.0)
	global_transform = Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * mul), pos)


## ★★★ 广播局部风场（用户需求 ✓ 进阶：龙卷风影响周围植被的风速与风向）
##   用**全局着色器参数**（无需注册材质 ✓ 所有用到的 shader 都能读到 ✓）
##   植被 shader 侧需声明（见 tree_leaves_burn_ds / tree_burn_keep_ds / grass_wind*）：
##     global uniform vec3  tornado_pos;       // 龙卷风中心（世界坐标）
##     global uniform float tornado_radius;    // 影响半径（米）
##     global uniform float tornado_strength;  // 局部风速强度（0 = 无风 ✓ 结束时会归零 ✓）
##     global uniform float tornado_swirl;     // 环流方向：+1 逆时针 / -1 顺时针
func _publish_wind(decay: float) -> void:
	var r := RenderingServer
	# 影响半径 = 圆半径 × 系数（默认 1.8 ✓ 想影响更远就调大 wind_radius_mul ✓）
	var rad := _radius * wind_radius_mul
	# 强度 = 基础强度 × 衰减（越接近尾声越弱 ✓）× 圆越大越强（半径/2.5 ✓）
	var strg := wind_strength_add * decay * clampf(_radius / 2.5, 0.5, 3.0)
	r.global_shader_parameter_set("tornado_pos", global_position)
	r.global_shader_parameter_set("tornado_radius", rad)
	r.global_shader_parameter_set("tornado_strength", strg)
	r.global_shader_parameter_set("tornado_swirl", 1.0 if swirl_ccw else -1.0)


## 结束/销毁时**必须归零** ✓（否则植被会一直以为旁边有龙卷风 ✓）
func _clear_wind() -> void:
	var r := RenderingServer
	r.global_shader_parameter_set("tornado_strength", 0.0)
	r.global_shader_parameter_set("tornado_radius", 0.0)


func _set_visible(v: bool) -> void:
	if _tornado != null and _tornado.visible != v:
		_tornado.visible = v

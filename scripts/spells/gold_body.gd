extends Node3D
## 金色守护 —— 金色碎片从角色四周（上下左右）汇聚到身上，形成一层金色薄膜；
## 停止施法（**包含法力不足**）后，薄膜逐渐碎裂并向四周发散消失。
##
## 三个阶段：
##   ① 汇聚 gather_time   碎片在角色的**球面**上生成，各自速度不同、按曲线收拢到身上
##   ② 守护                薄膜贴上角色（菲涅尔金边）+ 一层金色罩壳；持续耗蓝
##   ③ 碎裂 shatter_time   薄膜按噪声**一块块被抠掉**，同时碎片向外飞散消失
##
## 装配：薄膜用 material_overlay 逐个贴到角色的网格上（不动物体材质）；
##       碎片用 GPUParticles3D + particles 着色器（位置自己算，见 gold_shard.gdshader）。
##
## 对外接口与其它术法一致：
##   setup / start_cast / stop_cast / is_casting / aim_dir / origin_global / ran_out_of_mana

const FILM_SHADER := "res://assets/shaders/gold_film.gdshader"
const SHARD_SHADER := "res://assets/shaders/gold_shard.gdshader"
const NOISE_TEX := "res://assets/textures/法术特效/Noise1_tiled.png"
const SHARD_TEX := "res://assets/textures/法术特效/kenney/particle-pack/star_04.png"

@export var mana_per_sec := 0.0        ## 每秒耗蓝（本次需求改为**一次性** ✓ 故默认 0 ✓）
## ★★ 数值表接入（用户需求 ✓）：这些默认值会被 data/spell_sheet.json 覆盖 ✓
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
const SHEET_ID := "gold_body"
@export var one_shot := true           ## 一次性施放 ✓
@export var mana_cost := 20.0          ## 单次耗蓝 20 ✓
@export var cast_time := 0.0           ## 前摇（成型）0 秒 ✓
@export var duration := 9.1            ## 护盾持续 ✓
@export var fade_time_sheet := 0.9     ## 碎裂淡出 ✓
@export var total_time := 10.0         ## 总体 10 秒 ✓（到点自动碎裂结束 ✓）
var _life_t := 0.0                     ## 本次护盾已存活时间（用于自动结束 ✓）
## 碎片汇聚时长。0.75 -> 0.55 = **成型速度快约 30%**（原值偏慢）
@export var gather_time := 0.55
@export var shatter_time := 0.9       ## 碎裂发散时长
## 碎片数量。48 -> 96：汇聚与散开时的光点数量**翻倍**（原来看着太稀）
@export var shard_amount := 96
@export var gather_radius := 2.6      ## 碎片生成半径（米）
@export var aura_gain := 1.12         ## 罩壳相对角色高度的比例
@export var aura_body := 0.05         ## 罩壳的实心感（接近 0 = 只留边缘发光的一层壳）

# 0 = 关 / 1 = 汇聚 / 2 = 守护中 / 3 = 碎裂
const ST_OFF := 0
const ST_GATHER := 1
const ST_FILM := 2
const ST_SHATTER := 3

var casting := false

var _player: Node3D = null
var _shards: GPUParticles3D = null
var _shard_mat: ShaderMaterial = null
var _film: ShaderMaterial = null
var _aura: MeshInstance3D = null
var _aura_mat: ShaderMaterial = null
var _mesh_prev: Array[Dictionary] = []      ## {mi, prev}
var _ran_out := false
var _state := ST_OFF
var _state_t := 0.0


func _ready() -> void:
	set_process(true)
	_build_shards()


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	# ★★★ 读数值表（用户需求 ✓）：一次性 / 耗蓝 20 / 前摇 0 / 总体 10 秒
	#   范本见 flame_scorch.gd（同一套 SHEET 读取方式 ✓）
	var row: Dictionary = SHEET.get_spell(SHEET_ID)
	if row.is_empty():
		print("[金色守护] ✗ 数值表里没有 %s（用导出默认值）" % SHEET_ID)
	else:
		one_shot = bool(row.get("one_shot", one_shot))
		mana_cost = float(row.get("mana_cost", mana_cost))
		mana_per_sec = float(row.get("mana_per_sec", mana_per_sec))
		cast_time = float(row.get("cast_time", cast_time))
		duration = float(row.get("duration", duration))
		fade_time_sheet = float(row.get("fade_time", fade_time_sheet))
		total_time = float(row.get("total_time", cast_time + duration + fade_time_sheet))
		print("[金色守护] 数值表 ✓ one_shot=%s ｜ 耗蓝=%.0f ｜ 前摇=%.2fs ｜ 护盾=%.1fs ｜ 总体=%.1fs" % [
				str(one_shot), mana_cost, cast_time, duration, total_time])


## ★ 被直接释放（换法术、场景退出）时也必须把薄膜摘掉。
##   只在"碎裂走完"时还原是不够的：换法术会让这个节点直接被 queue_free，
##   那时角色身上会**永久留着一层金膜**（实测踩过：上一个测试实例释放后金膜还在）。
func _exit_tree() -> void:
	# ★★ 清除护盾标记（用户需求 ✓ "上一次效果消失后才能再用" ✓）
	#   放在这里最稳 ✓：无论正常碎裂结束 ✓ 还是换法术/场景退出被 queue_free ✓ 都会执行 ✓
	if _player != null and is_instance_valid(_player) and _player.has_meta("gold_guard"):
		_player.remove_meta("gold_guard")
		print("[金色守护] 护盾结束 ✓ 已清除标记（现在可以再次施放）")
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).material_overlay = d["prev"]
	_mesh_prev.clear()


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	# ★★ 金色守护（用户需求 ✓）：一次性 + 同一目标**不可重复施放** + 100% 抵挡
	#   ① 目标已有 meta `gold_guard` → 本次实例**不生效** ✗（不建膜/不覆盖标记 ✓）
	#      它的 `is_casting()` 保持 false ✓ → 由 spell_caster 的 _sweep_instances() 自动释放 ✓
	#   ② 真正开始护盾时打标记 ✓ → `vitals.damage()` 看到它直接返回 = **100% 抵挡** ✓✓
	#   ③ 标记只在护盾实例销毁时清除 ✓（见 _exit_tree ✓）→ "上一次消失后才能再用" ✓✓
	# ★★★ 不可重复施放的判据（用户需求 ✓）—— 用**自带过期时间的标记** ✓
	#   为什么不用单纯的布尔标记 ✗：效果结束时若实例被复用/没被释放 ✗
	#     → `_exit_tree()` 永不执行 → 布尔标记永远为真 → **再也放不出来** ✓✓（用户实测 ✓）
	#   现在：`gold_guard_until` = 绝对到期时间（毫秒 ✓）→ **到点自动失效** ✓✓
	#     → 无论清理路径是否走到 ✓ 都能再次施放 ✓（且新一次施法会重新打上标记 ✓ 自愈 ✓）
	var now_ms := Time.get_ticks_msec()
	if _player != null and is_instance_valid(_player):
		var until: int = int(_player.get_meta("gold_guard_until", 0))
		if now_ms < until:
			print("[金色守护] 目标身上已有护盾 ✓ 本次不重复施放（还剩 %.1fs）" % [
					float(until - now_ms) / 1000.0])
			return
		# 到期/首次 → 打标记 ✓（两个都打：布尔给 vitals 判定 ✓ 时间戳给"不可重复"判定 ✓）
		_player.set_meta("gold_guard", true)
		_player.set_meta("gold_guard_until", now_ms + int(total_time * 1000.0))
		print("[金色守护] 护盾生效 ✓ 100% 抵挡（整体 %.1fs = 汇聚 %.2f + 护盾 + 碎裂 %.1f）" % [
				total_time, gather_time, shatter_time])
	# ★★ 扣蓝（用户需求 ✓ 单次 20）：照 flame_scorch 的写法 ✓
	#   先看余额（Mana.try_spend 在不足时会把蓝扣到 0 再返回 false ✗ → 必须先判 ✓）
	if mana_cost > 0.0:
		if float(Mana.get("current")) < mana_cost:
			print("[金色守护] ✗ 法力不足（需要 %.0f，当前 %.0f）→ 本次不生效" % [
					mana_cost, float(Mana.get("current"))])
			if _player != null and is_instance_valid(_player) and _player.has_meta("gold_guard"):
				_player.remove_meta("gold_guard")     # 没蓝就把刚打的标记撤掉 ✓
			return
		if not Mana.try_spend(mana_cost):
			print("[金色守护] ✗ 扣蓝失败 → 本次不生效")
			if _player != null and is_instance_valid(_player) and _player.has_meta("gold_guard"):
				_player.remove_meta("gold_guard")
			return
	_life_t = 0.0                                   # ★ 开始计时（到 total_time 自动结束 ✓）
	casting = true
	if _state == ST_OFF or _state == ST_SHATTER:
		_build_film()                      # 贴薄膜（reveal=0，先不可见）
		_set_shard_mode(0)
		if _shards != null:
			_shards.restart()
			_shards.emitting = true
		_state = ST_GATHER
		_state_t = 0.0


func stop_cast() -> void:
	# ★★★ 一次性护盾（用户需求 ✓）：**由自己计时结束** ✓（见 _process 的 _life_t ✓）
	#   为什么必须忽略 ✗：caster 对一次性法术"只等施法动作演完即可再施法"✓
	#   而本术法 `cast_time = 0`（前摇 0 ✓）→ caster 会在**同帧**就调 stop_cast() ✗
	#   → 若照旧把 casting 设为 false ✗ → 护盾**刚出现就碎裂消失** ✓✓（用户实测 ✓）
	if one_shot:
		return
	casting = false


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


## 本术法不瞄准，方向固定用角色正前方（保持接口一致）
func aim_dir() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.FORWARD
	return -(_player as Node3D).global_transform.basis.z


func origin_global() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return global_position
	return (_player as Node3D).global_position


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	# ★★ 一次性自动结束（用户需求 ✓ 总体 10 秒）：
	#   到达 total_time 就自己碎裂 ✓（不再依赖"按住/松手"✗ 也不依赖 caster 的收尾 ✓）
	#   → 之后的碎裂与标记清除按原有流程走 ✓（_exit_tree 会清掉 gold_guard ✓）
	if casting:
		_life_t += delta
		# ★★★ 整体正好 total_time 秒（用户需求 ✓）：**汇聚 + 护盾 + 散开全算在内** ✓
		#   汇聚（gather_time 0.55）在 start_cast 之后立刻开始 ✓；
		#   所以要在 `total_time - shatter_time`（= 9.1s）就开始碎裂 ✗→✓
		#   这样 `碎裂 0.9` 结束时正好 = 10.0s ✓✓（若在 10.0s 才碎 ✗ → 整体会变 10.9s ✗）
		if _life_t >= total_time - shatter_time:
			print("[金色守护] 整体 %.1fs 到点 ✓ 开始碎裂（散开 %.1fs 后结束 ✓ 合计 %.1fs）" % [
					_life_t, shatter_time, total_time])
			casting = false
			if _state != ST_SHATTER and _state != ST_OFF:
				_begin_shatter()
	if _player != null and is_instance_valid(_player):
		global_position = _player.global_position       # 跟着角色走
	_state_t += delta
	match _state:
		ST_OFF:
			return
		ST_GATHER:
			var k := clampf(_state_t / maxf(gather_time, 0.01), 0.0, 1.0)
			_set_reveal(smoothstep(0.55, 1.0, k))       # 碎片快到齐时薄膜才显形
			if k >= 1.0:
				_state = ST_FILM
				_state_t = 0.0
				_set_reveal(1.0)
		ST_FILM:
			_set_reveal(1.0)
			if Mana.spend_rate(delta, mana_per_sec):
				_ran_out = false
			else:
				_ran_out = true
				_begin_shatter()
			if not casting:
				_begin_shatter()
		ST_SHATTER:
			var k2 := clampf(_state_t / maxf(shatter_time, 0.01), 0.0, 1.0)
			_set_dissolve(k2)                            # 薄膜一块块被抠掉
			if k2 >= 1.0:
				_cleanup()


# ---------------------------------------------------------------- 内部
func _begin_shatter() -> void:
	if _state == ST_SHATTER or _state == ST_OFF:
		return
	_state = ST_SHATTER
	_state_t = 0.0
	# 碎片向外飞散（同一个粒子系统换成 mode 1 重新发射）
	_set_shard_mode(1)
	if _shards != null:
		_shards.restart()
		_shards.emitting = true


func _cleanup() -> void:
	# ★★ 效果真正结束 → **立刻清掉抵挡标记** ✓（用户需求 ✓）
	#   放在这里最稳 ✓：碎裂演完的状态机收尾一定会调用它 ✓
	#   （`_exit_tree()` 里也清一次 ✓ 双保险 ✓ 换法术/退出场景也不会残留 ✓）
	if _player != null and is_instance_valid(_player) and _player.has_meta("gold_guard"):
		_player.remove_meta("gold_guard")
		print("[金色守护] 效果结束 ✓ 已清除抵挡标记（可以再次施放）")
	_state = ST_OFF
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).material_overlay = d["prev"]
	_mesh_prev.clear()
	if _aura != null and is_instance_valid(_aura):
		_aura.queue_free()
		_aura = null
	if _shards != null:
		_shards.emitting = false
	_set_reveal(0.0)
	_set_dissolve(0.0)


# ---------------------------------------------------------------- 装配
func _build_shards() -> void:
	_shard_mat = ShaderMaterial.new()
	var psh := load(SHARD_SHADER) as Shader
	if psh == null:
		push_warning("[GoldBody] 缺少 gold_shard.gdshader")
		return
	_shard_mat.shader = psh
	_shard_mat.set_shader_parameter("mode", 0)
	_shard_mat.set_shader_parameter("radius", gather_radius)

	var draw := StandardMaterial3D.new()
	draw.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	draw.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	draw.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	draw.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	draw.vertex_color_use_as_albedo = true
	draw.disable_receive_shadows = true
	var tex := load(SHARD_TEX) as Texture2D
	if tex != null:
		draw.albedo_texture = tex

	var quad := QuadMesh.new()
	quad.size = Vector2(0.20, 0.20)
	quad.surface_set_material(0, draw)     # 同时设到网格表面：粒子的绘制通道用的是网格材质

	var p := GPUParticles3D.new()
	p.name = "GoldShards"
	p.amount = shard_amount
	p.lifetime = gather_time + 0.15
	p.one_shot = true
	p.explosiveness = 0.25            # 错开一点出现，不要齐刷刷
	p.local_coords = true             # 跟着角色走
	p.process_material = _shard_mat
	p.draw_pass_1 = quad
	p.material_override = draw
	# 注意：**没有** emission_shape 可用 —— 用自定义 particles 着色器时，
	# 生成位置完全由着色器 start() 里的 TRANSFORM[3] 决定（GPUParticles3D 上
	# 也没有 EMISSION_SHAPE_* 这个枚举，那是 ParticleProcessMaterial 的东西）。
	p.emitting = false
	# ★ 碎片在半径 2.6 米处生成，默认可见包围盒太小会被整体剔除
	p.visibility_aabb = AABB(Vector3(-4, -4, -4), Vector3(8, 8, 8))
	add_child(p)
	_shards = p


func _set_shard_mode(m: int) -> void:
	if _shard_mat != null:
		_shard_mat.set_shader_parameter("mode", m)


## 把金色薄膜逐个贴到角色的网格上（material_overlay，不动物体自己的材质），
## 同时量出角色高度，用来自动定金色罩壳的大小。
func _build_film() -> void:
	if _film == null:
		_film = ShaderMaterial.new()
		var fsh := load(FILM_SHADER) as Shader
		if fsh == null:
			push_warning("[GoldBody] 缺少 gold_film.gdshader")
			return
		_film.shader = fsh
		var nt := load(NOISE_TEX) as Texture2D
		if nt != null:
			_film.set_shader_parameter("noise_tex", nt)
		_film.set_shader_parameter("reveal", 0.0)
		_film.set_shader_parameter("dissolve", 0.0)

	if _player == null or not is_instance_valid(_player):
		return
	var meshes: Array[MeshInstance3D] = []
	_gather_meshes(_player, meshes)
	var lo := 1e9
	var hi := -1e9
	for mi in meshes:
		_mesh_prev.append({"mi": mi, "prev": mi.material_overlay})
		mi.material_overlay = _film
		if mi.mesh != null:
			var aabb := mi.mesh.get_aabb()
			var xf := mi.global_transform
			for i in range(8):
				var c := aabb.position + Vector3(
						aabb.size.x if (i & 1) != 0 else 0.0,
						aabb.size.y if (i & 2) != 0 else 0.0,
						aabb.size.z if (i & 4) != 0 else 0.0)
				lo = minf(lo, (xf * c).y)
				hi = maxf(hi, (xf * c).y)
	if lo > hi:
		return
	# 金色罩壳：包住角色的一层光壳（与薄膜共用材质 -> 一起碎裂）
	var h := hi - lo
	var r := maxf(h * 0.5 * aura_gain, 0.35)
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	var aura := MeshInstance3D.new()
	aura.name = "GoldAura"
	aura.mesh = sm
	# ★ 罩壳用**自己的一份材质**：只保留边缘发光（body_strength 接近 0）。
	#   和身体薄膜共用一份材质时，罩壳会变成一个**实心金球**把角色整个盖住，
	#   反而看不到需求要的"一身金色薄膜"。
	_aura_mat = ShaderMaterial.new()
	_aura_mat.shader = _film.shader
	_aura_mat.set_shader_parameter("noise_tex", _film.get_shader_parameter("noise_tex"))
	_aura_mat.set_shader_parameter("reveal", 0.0)
	_aura_mat.set_shader_parameter("dissolve", 0.0)
	_aura_mat.set_shader_parameter("body_strength", aura_body)
	_aura_mat.set_shader_parameter("rim_strength", 1.7)
	_aura_mat.set_shader_parameter("rim_power", 3.2)
	_aura_mat.set_shader_parameter("crack_glow", 1.4)
	aura.material_override = _aura_mat
	aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(aura)
	aura.position = Vector3(0.0, (lo + hi) * 0.5 - global_position.y, 0.0)
	_aura = aura


func _set_reveal(v: float) -> void:
	var r := clampf(v, 0.0, 1.0)
	if _film != null:
		_film.set_shader_parameter("reveal", r)
	if _aura_mat != null:
		_aura_mat.set_shader_parameter("reveal", r)


func _set_dissolve(v: float) -> void:
	var d := clampf(v, 0.0, 1.0)
	if _film != null:
		_film.set_shader_parameter("dissolve", d)
	if _aura_mat != null:
		_aura_mat.set_shader_parameter("dissolve", d)


func _gather_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		else:
			_gather_meshes(c, out)

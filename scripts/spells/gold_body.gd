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
##
## 所属系统：scripts/spells/ 术法集合之一。由 spell_caster.gd 以 SPELLS["gold_body"] 注册、
##   spell_wheel.gd 以 "gold_body" 放进轮盘；施法时 caster 会**复制出独立实例**并调用
##   setup(player, staff) + start_cast()，之后每帧用 _sweep_instances() 检查 is_casting()，
##   一旦返回 false 就 queue_free 掉这个实例。
## 关键依赖：
##   · autoload `Mana`（scripts/spells/mana.gd）：
##       Mana.get("current") 只读查余额；Mana.try_spend(amount) 单次扣蓝；
##       Mana.spend_rate(delta, per_sec) 按帧扣蓝（per_sec < 0 时才回落到 Mana.spend_per_sec）。
##       ⚠ try_spend() 在余额不足时会把 current **扣到 0 再返回 false** →
##         必须先自己判余额再调它，否则法力会被白扣（详见 start_cast）。
##   · 数值表 scripts/spells/spell_sheet.gd（静态工具，内部 PATH = res://data/spell_sheet.json）：
##       本文件用 SHEET.get_spell(SHEET_ID) 取行，覆盖下面那批 @export 默认值。
##   · 着色器 assets/shaders/gold_film.gdshader（角色薄膜 + 金色罩壳共用）、
##       assets/shaders/gold_shard.gdshader（碎片，位置/年龄全在粒子着色器里自己算）。
##   · 贴图 assets/textures/法术特效/Noise1_tiled.png（碎裂噪声）、
##       .../kenney/particle-pack/star_04.png（单个碎片外形）。
## 对外信号 / 跨文件契约（**改名要全局同步**）：
##   · 在角色节点上写 meta `gold_guard`(bool) 与 `gold_guard_until`(int，毫秒时间戳)；
##     vitals.gd 的 damage() 只要发现"自己或父节点"带 `gold_guard` 就直接返回 = 100% 抵挡。
##   · caster 侧只看 is_casting() 与 one_shot 两个语义（配合 stop_cast 的空实现，见其注释）。
##   · 本文件不发任何自定义 signal。
## 场景树副作用：
##   · 给角色身上**每一个** MeshInstance3D 设 material_overlay（原值备份在 _mesh_prev，
##     _cleanup() / _exit_tree() 时逐个还原）；绝不改角色自己的材质资源。
##   · 自己 new 出 GPUParticles3D（碎片，_ready() 建一次后长期复用）与
##     MeshInstance3D "GoldAura"（罩壳，每轮施法重建、_cleanup() 里 queue_free）。
## 已知的坑：
##   · caster 把施法实例挂在 _player.get_parent()（世界层级），本节点每帧把自己的
##     global_position 对齐到角色 → 两者同一坐标系，可直接相减（见 _build_film 里算罩壳位置）。
##   · one_shot = true 时 stop_cast() 是空操作，护盾**只**靠 _process 的 _life_t 收尾；
##     一旦 set_process(false) 或 _process 被卡住，护盾会永远不碎，而且会一直占着
##     `gold_guard_until` → 玩家再也放不出第二次。
##   · 数值契约见 data/spell_sheet.json 的 gold_body 行（10.0 = 前摇 0 + 护盾 9.1 + 碎裂 0.9）。

# ==================== 常量：资源路径与数值表 ====================
## 薄膜着色器：角色"金色薄膜"与外围"金色罩壳"共用同一份 shader，
## 靠 reveal（显形）/ dissolve（碎裂）/ body_strength / rim_strength 等 uniform 区分外观（见 _build_film）。
const FILM_SHADER := "res://assets/shaders/gold_film.gdshader"
## 碎片着色器：碎片**不用 ParticleProcessMaterial**，生成方向/速度/曲线/半径全在着色器里算，
## 因此 GDScript 侧只给它 mode 与 radius 两个 uniform（见 _build_shards / _set_shard_mode）。
const SHARD_SHADER := "res://assets/shaders/gold_shard.gdshader"
## 碎裂噪声贴图：gold_film.gdshader 用世界坐标采样它的 R 通道当 dissolve 阈值，
## 决定薄膜"哪一块先被抠掉"。用 *_tiled 平铺版，保证整个角色身上的花纹不拉伸。
const NOISE_TEX := "res://assets/textures/法术特效/Noise1_tiled.png"
## 单个碎片的外形贴图（四角星），只在 _build_shards() 里给 StandardMaterial3D 当 albedo。
const SHARD_TEX := "res://assets/textures/法术特效/kenney/particle-pack/star_04.png"

# ==================== 可调参数（默认值会被数值表覆盖） ====================
## 下面这批 @export 只是"离线默认值"（没有 data/spell_sheet.json 时也能跑起来），
## setup() 里会用 SHEET.get_spell("gold_body") 的字段逐项覆盖；
## 表里若缺字段，就回落到这里的默认值（见 setup 里的 row.get(key, 当前值) 写法）。
## 当前数值契约：one_shot=true / mana_cost=20 / mana_per_sec=0 / cast_time=0 /
##   duration=9.1 / fade_time=0.9 / total_time=10.0，
##   即 total_time(10.0) = cast_time(0) + duration(9.1) + fade_time(0.9)。
@export var mana_per_sec := 0.0        ## 每秒耗蓝（本次需求改为**一次性** ✓ 故默认 0 ✓）
## ★★ 数值表接入（用户需求 ✓）：这些默认值会被 data/spell_sheet.json 覆盖 ✓
## 数值表工具（全部是 static 函数，可直接 SHEET.get_spell(...)）。用 preload 而不是 load：
## 让它进依赖表，导出后的包体里一定带上（热更/误删路径时会在启动期就报错，而不是施法时才炸）。
const SHEET := preload("res://scripts/spells/spell_sheet.gd")
## 本术法在数值表里的键名。它同时是 spell_caster.gd 的注册名和 spell_wheel.gd 的轮盘名，
## 三处必须一致（改这里要同步改那两处，否则表读不到、轮盘也选不出来）。
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

# ==================== 状态机常量与运行时状态 ====================
# 0 = 关 / 1 = 汇聚 / 2 = 守护中 / 3 = 碎裂
# 语义补充：ST_GATHER 只在算 reveal（碎片快到齐时薄膜才显形）；ST_FILM 保持 reveal=1 并等待结束条件；
#           ST_SHATTER 把 dissolve 从 0 推到 1（一块块抠掉薄膜），推满后调 _cleanup() 回到 ST_OFF。
# 迁移：ST_OFF --start_cast()--> ST_GATHER --汇聚满--> ST_FILM
#         --到 total_time 到点 / 没蓝 / casting=false--> ST_SHATTER --碎裂满--> ST_OFF
const ST_OFF := 0
const ST_GATHER := 1
const ST_FILM := 2
const ST_SHATTER := 3

## 对外状态位：is_casting() 直接返回它。
## true = 这一发还在"演"，caster 会继续保留实例；false = caster 可以把实例 queue_free 掉。
## one_shot 护盾里它只由 start_cast() 置 true、由 _process 计时到点置 false（stop_cast() 刻意不动它）。
var casting := false

## setup() 传入并缓存的**角色根节点**（不是法杖）。meta 标记、每帧跟随、网格收集都作用于它；
## 全程可能为 null（setup 之前被调用），所以每处使用都配了 is_instance_valid() 判空。
var _player: Node3D = null
## 碎片粒子系统：_ready() 里建**一次**后长期复用，汇聚与飞散共用它，
## 靠重启 + 切 mode 区分（见 _set_shard_mode / _begin_shatter）。shader 缺失时为 null。
var _shards: GPUParticles3D = null
## 碎片材质：GDScript 只往它写两个 uniform —— mode（0=汇聚 / 1=飞散）与 radius（生成/飞散半径）。
var _shard_mat: ShaderMaterial = null
## 薄膜材质：作为 overlay 贴到角色每个网格上（角色自己的材质一份都不改）。
## 只建一次并复用，所以 _cleanup() 里必须把 reveal / dissolve 参数归零，避免残留上一轮进度。
## 罩壳材质 _aura_mat 是用**同一个 shader** 另建的一份（不能共用，见 _build_film 的注释）。
var _film: ShaderMaterial = null
## 金色罩壳（包住角色的一层光壳，SphereMesh + _aura_mat）。每轮施法在 _build_film() 里新建，
## _cleanup() 里 queue_free 并置 null；它是本节点的子节点，位置要由世界坐标换算成局部坐标。
var _aura: MeshInstance3D = null
## 罩壳专用的薄膜材质：body_strength 压到接近 0、rim_strength 提高 → 只留一圈边缘发光。
var _aura_mat: ShaderMaterial = null
## 覆盖前的备份表，元素形如 { "mi": MeshInstance3D, "prev": 该网格原本的 material_overlay }。
## 为什么不能"结束时就地清成 null"：角色网格**原本可能已经挂着别的 overlay**（其它状态特效/染色），
## 一律清空会顺手把别人的效果抹掉，所以必须逐个还原原值（见 _cleanup / _exit_tree）。
## 每次 _build_film() 追加、_cleanup() / _exit_tree() 里 clear()。
var _mesh_prev: Array[Dictionary] = []      ## {mi, prev}
## "因没蓝而中断"的标志，对外由 ran_out_of_mana() 返回，供 caster / UI 统一提示。
## ⚠ 实际取值：mana_per_sec 默认 0、数值表里也是 0 → Mana.spend_rate(delta, 0.0) 内部走
##   try_spend(0) → amount <= 0 直接返回 true → 本变量一直是 false。
##   它是各术法统一接口的一部分，留着给"以后改成持续耗蓝"用（推测：故不删）。
var _ran_out := false
## 当前状态机状态（ST_OFF / ST_GATHER / ST_FILM / ST_SHATTER）。
## 初值必须是 ST_OFF：start_cast() 里只有 `_state == ST_OFF or _state == ST_SHATTER` 才重建薄膜。
var _state := ST_OFF
## **当前状态**已经持续的秒数（不是总存活时间，总时间看 _life_t）。
## 每帧无条件累加（含 ST_OFF），所以任何一次进入新状态都必须手动归零，否则新状态一进来就被判成"已完成"。
var _state_t := 0.0


# ==================== 生命周期：初始化 / 注入 / 销毁 ====================
## 引擎回调：节点进树时调用一次。
## 参数 / 返回值：无。
## 副作用：打开每帧处理（Node 默认本来就是 true，这里显式写出来是提醒：护盾的计时**完全**依赖 _process）、
##   建立长期复用的碎片粒子系统（_build_shards）。
## 注意：此刻 _player 还是 null（setup() 由 caster 稍后调用），所以这里只做与角色无关的装配；
##   任何需要角色的逻辑（贴薄膜、收集网格、打 meta）都必须等到 setup / start_cast 之后。
func _ready() -> void:
	# 显式打开每帧处理：护盾的结束**只**由 _process 的 _life_t 计时驱动（stop_cast 对一次性护盾是空操作），
	# 这里关掉的话护盾会永远不碎、并一直占着 gold_guard_until。
	set_process(true)
	_build_shards()


## 由 spell_caster 在实例化后立刻调用：注入依赖 + 从数值表同步全部参数。
## 参数 player：角色根节点（本术法的所有效果都作用在它身上，会存进 _player）。
## 参数 staff：法杖节点。本术法不瞄准，**故意忽略**它（保留形参只为与其它术法统一接口）。
## 返回值：无。
## 副作用：覆盖 one_shot / mana_cost / mana_per_sec / cast_time / duration / fade_time_sheet /
##   total_time 这批 @export，并打一条 print 摘要。
## 调用时机：caster 的每次施法都会新建实例并调用一次；换法术时共享实例也会被调用。
## 注意：
##   · 表里缺行（row.is_empty()）时**只 print 不报错**，继续用导出默认值跑（保证游戏不炸）。
##   · total_time 的兜底值是 cast_time + duration + fade_time_sheet（= 10.0，与表里一致）。
##   · 这里不碰法力、不碰 meta、不建特效 —— 那些都是 start_cast() 的职责。
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
## 参数 / 返回值：无（引擎回调，节点离开场景树时调用）。
## 副作用：清掉角色的 `gold_guard` meta（并打日志）；把 _mesh_prev 里备份的每个网格
##   material_overlay 还原成原值，然后清空备份表。
## 注意：这里**不**手动释放 _aura / _shards —— 本节点正在被销毁，子节点会跟着一起回收；
##   正常走完碎裂时由 _cleanup() 负责处理它们。
func _exit_tree() -> void:
	# ★★ 清除护盾标记（用户需求 ✓ "上一次效果消失后才能再用" ✓）
	#   放在这里最稳 ✓：无论正常碎裂结束 ✓ 还是换法术/场景退出被 queue_free ✓ 都会执行 ✓
	#   这里**故意只清布尔** `gold_guard`、不清时间戳 `gold_guard_until`：
	#   时间戳到点会自动失效，是"某条清理路径没走到"时的兜底（设计说明见 start_cast 顶部）。
	if _player != null and is_instance_valid(_player) and _player.has_meta("gold_guard"):
		_player.remove_meta("gold_guard")
		print("[金色守护] 护盾结束 ✓ 已清除标记（现在可以再次施放）")
	for d in _mesh_prev:
		var mi = d["mi"]
		if mi != null and is_instance_valid(mi):
			(mi as MeshInstance3D).material_overlay = d["prev"]
	_mesh_prev.clear()


# ==================== 对外接口（spell_caster 调用） ====================
# ---------------------------------------------------------------- 对外
## 开始施放金色守护，并立刻建立 100% 抵挡标记（由 spell_caster 在按下施法时调用）。
## 参数：无（角色在 setup() 时已注入 _player）。
## 返回值：无。它是"过程式"接口 —— 失败靠**提前 return** 表达，不返回 bool。
## 副作用（按执行顺序）：
##   ① 幂等检查：角色身上 `gold_guard_until` 未到期 → 直接 return（本次不生效）；
##   ② 否则写入 meta `gold_guard` = true、`gold_guard_until` = now + total_time * 1000（毫秒）；
##   ③ 扣蓝：余额不足或 Mana.try_spend() 失败 → **撤回刚打的 gold_guard** 并 return；
##   ④ 成功：_life_t 归零、casting = true；
##      若 _state 是 ST_OFF / ST_SHATTER → _build_film() 贴薄膜 + _set_shard_mode(0) +
##      重启碎片粒子 + 切到 ST_GATHER。
## 提前返回时**不动** _state 与 casting（保持 false）→ caster 的 _sweep_instances() 会立刻回收这个实例。
## 注意：因为 cast_time = 0，caster 会在同一帧紧跟一次 stop_cast()，所以护盾的结束绝不能依赖它。
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


## 结束施法的"松手"回调（由 spell_caster 调用）。
## 参数 / 返回值：无。
## 行为被**刻意做成近空操作**：
##   · one_shot = true（本术法的默认值，数值表里也是 true）→ 直接 return，**不动 casting**；
##     护盾何时碎裂只由 _process 的 _life_t 计时决定。
##   · one_shot = false（若数值表改成持续型）→ 才把 casting 置 false，
##     随后 _process 的 ST_FILM 分支会立刻 _begin_shatter()。
## 为什么必须忽略：cast_time = 0 → caster 会在施法**同一帧**就调用本函数；
##   若照旧把 casting 置 false，护盾会刚成型就直接碎裂（历史实测踩过）。
## 注意：不要"顺手"在这里补清理逻辑 —— 清理只在 _begin_shatter / _process 到点 / _cleanup / _exit_tree 里做。
func stop_cast() -> void:
	# ★★★ 一次性护盾（用户需求 ✓）：**由自己计时结束** ✓（见 _process 的 _life_t ✓）
	#   为什么必须忽略 ✗：caster 对一次性法术"只等施法动作演完即可再施法"✓
	#   而本术法 `cast_time = 0`（前摇 0 ✓）→ caster 会在**同帧**就调 stop_cast() ✗
	#   → 若照旧把 casting 设为 false ✗ → 护盾**刚出现就碎裂消失** ✓✓（用户实测 ✓）
	if one_shot:
		return
	casting = false


## 查询"这一发还在演吗"，供 spell_caster._sweep_instances() 决定是否 queue_free 本实例。
## 参数：无。返回值：casting（true = 继续保留；false = caster 可以立即释放）。
## 契约：一次护盾真正演完（_process 计时到点 / 碎裂结束）后它必须回到 false，否则实例永远不被回收；
##   而"被拒绝施放"（已有护盾 / 没蓝）的实例从头到尾都是 false → caster 当场释放它。
func is_casting() -> bool:
	return casting


## 统一接口：本发术法是否因为法力不足而中断（供 caster / UI 统一提示"没蓝了"）。
## 参数：无。返回值：_ran_out。
## 注意：金色守护一次性扣蓝、mana_per_sec = 0，所以这个值实际上恒为 false（原因见 _ran_out 的说明）；
##   真正"没蓝"的情况在 start_cast() 里就已经提前 return，连特效都不会出现。
func ran_out_of_mana() -> bool:
	return _ran_out


## 本术法不瞄准，方向固定用角色正前方（保持接口一致）
func aim_dir() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return Vector3.FORWARD
	return -(_player as Node3D).global_transform.basis.z


## 统一接口：特效的世界原点。本术法返回**角色**的世界坐标（而不是法杖尖端）。
## 参数：无。返回值：Vector3，_player 的世界位置；_player 为 null / 已释放时退回本节点自身位置
##   （这样调用方永远拿到合法向量，不会因为角色失效而崩溃）。
## 说明：薄膜与罩壳都贴在角色身上，所以"原点"取角色中心；_process 里也用它让本节点跟随角色。
func origin_global() -> Vector3:
	if _player == null or not is_instance_valid(_player):
		return global_position
	return (_player as Node3D).global_position


# ==================== 每帧更新（计时 + 状态机推进） ====================
# ---------------------------------------------------------------- 每帧
## 每帧推进：一次性护盾的计时、跟随角色、执行状态机（三段职责在函数体里依次排开）。
## 参数 delta：距上一帧的秒数（引擎传入），会同时累加到 _life_t（总存活时间）与 _state_t（当前状态计时）。
## 返回值：无。
## 副作用：可能改 casting / _state / _state_t；把本节点 global_position 对齐到角色；
##   写 shader uniform（reveal / dissolve）；重启碎片粒子；调 _begin_shatter() / _cleanup()。
## 调用时机：_ready() 里 set_process(true)，之后引擎每帧调用。
## 注意：本函数是护盾**唯一**的结束驱动源（stop_cast() 被刻意忽略）；
##   ST_OFF 分支里的 return 只跳过状态机推进，前面的计时与跟随已经执行过了。
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
	# 这里**无条件**累加（ST_OFF 期间也在加），所以每一次切换状态都必须自己把 _state_t 归零；
	# 否则第一次施法之前累积的秒数会让 ST_GATHER 一进来就被判成"汇聚已完成"，薄膜瞬现。
	_state_t += delta
	match _state:
		ST_OFF:
			return
		ST_GATHER:
			# k = 汇聚进度 0→1；除数是 maxf(gather_time, 0.01) 而不是 gather_time，
			# 因为 gather_time 是导出值、还可能被数值表覆盖成 0，直接作除数会得到 inf。
			var k := clampf(_state_t / maxf(gather_time, 0.01), 0.0, 1.0)
			_set_reveal(smoothstep(0.55, 1.0, k))       # 碎片快到齐时薄膜才显形
			if k >= 1.0:
				_state = ST_FILM
				_state_t = 0.0
				_set_reveal(1.0)
		ST_FILM:
			_set_reveal(1.0)
			# 逐帧按 mana_per_sec 扣蓝：返回 false = 余额不够 → 立刻转为碎裂。
			# ⚠ 本术法 mana_per_sec 默认 0、数值表里也是 0 → spend_rate 内部 try_spend(0) 恒返回 true，
			#   所以这一支实际上不会触发（是给"以后改成持续耗蓝"预留的路径）。
			if Mana.spend_rate(delta, mana_per_sec):
				_ran_out = false
			else:
				_ran_out = true
				_begin_shatter()
			if not casting:
				_begin_shatter()
		ST_SHATTER:
			# k2 = 碎裂进度 0→1，直接当 dissolve 阈值交给 shader（同样用 maxf 防除零）；
			# 推到 1.0 说明"整层薄膜已被噪声全部抠完"，才真正收拾现场。
			var k2 := clampf(_state_t / maxf(shatter_time, 0.01), 0.0, 1.0)
			_set_dissolve(k2)                            # 薄膜一块块被抠掉
			if k2 >= 1.0:
				_cleanup()


# ==================== 内部：碎裂与收尾 ====================
# ---------------------------------------------------------------- 内部
## 从汇聚/守护态切到碎裂态（只切状态与粒子模式，**不做任何清理**）。
## 参数 / 返回值：无。
## 副作用：_state = ST_SHATTER、_state_t 归零、碎片着色器 mode = 1（向外飞散）、重启并发射 _shards；
##   角色金膜本身不在这里动，它靠 _process 里逐帧的 _set_dissolve(k2) 被噪声"一块块抠掉"。
## 调用时机：三处 —— ① _process 到 total_time - shatter_time（= 9.1s）；② ST_FILM 里没蓝；③ ST_FILM 里 casting 变 false。
## 注意：开头有幂等保护（已是 ST_SHATTER / ST_OFF 就直接 return），
##   所以上面三处即使在同一帧全部命中（比如到点那帧同时没蓝）也不会重复触发。
func _begin_shatter() -> void:
	if _state == ST_SHATTER or _state == ST_OFF:
		return
	_state = ST_SHATTER
	_state_t = 0.0
	# 碎片向外飞散（同一个粒子系统换成 mode 1 重新发射）
	# 复用同一个粒子系统：只切 mode uniform + restart()，让新一波碎片按 mode=1（向外飞散）生成。
	# 只改 mode 不 restart 是不够的：老粒子年龄已经走完，只有 restart 才会重新跑 start() 并把
	# 自算年龄 CUSTOM.w 归零（见 gold_shard.gdshader 顶部说明）。
	_set_shard_mode(1)
	if _shards != null:
		_shards.restart()
		_shards.emitting = true


## 一轮护盾的最终收尾：标记、覆盖材质、罩壳、粒子、shader uniform 全部复位（碎裂演满时由 _process 调用）。
## 参数 / 返回值：无。
## 副作用：
##   · 清掉角色 meta `gold_guard`（`gold_guard_until` **故意保留**，理由见 start_cast 顶部注释）；
##   · _state 回到 ST_OFF（此后 _process 的 match 直接 return，但计时与跟随仍在跑）；
##   · 用 _mesh_prev 的备份逐个还原角色网格的 material_overlay，然后清空备份表；
##   · queue_free 掉金色罩壳 _aura 并置 null；把 _shards 停掉发射（**不释放**，它要长期复用）；
##   · reveal / dissolve 归零（_film 是复用材质，不归零的话下一轮施法一开始就是"碎完"的样子）。
## 调用时机：ST_SHATTER 里 k2 >= 1.0 时；_exit_tree() 是它的兜底（实例被直接 queue_free 的场景）。
## 注意：可以安全地重复调用 —— _state 已置 ST_OFF，其它字段也都逐项判空。
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


# ==================== 装配：碎片粒子与金色薄膜/罩壳 ====================
# ---------------------------------------------------------------- 装配
## 建立碎片粒子系统（_ready() 里调用一次，之后整个生命周期复用）。
## 参数 / 返回值：无。
## 副作用：new 出 _shard_mat / StandardMaterial3D / QuadMesh / GPUParticles3D 并 add_child 到本节点。
## shader 缺失时只 push_warning 并提前返回 → _shards 保持 null，后续所有用到它的地方都有判空（不会崩）。
## 为什么材质要设两处（网格 surface + material_override）：使用自定义 particles 着色器后，
##   粒子绘制吃的是 QuadMesh 的表面材质（顶点色/混合），而 material_override 同步设一份最稳妥。
## 注意：
##   · 这里写入 _shard_mat 的 radius 只影响**之后新生成**的粒子，改它不会移动已经在飞的碎片。
##   · 粒子不设 emission_shape —— 生成位置完全由 gold_shard.gdshader 自己算（它连 GPUParticles3D
##     的 EMISSION_SHAPE_* 枚举都没有，那是 ParticleProcessMaterial 的东西）。
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
	# 粒子寿命比汇聚时长多 0.15s：让最后一批碎片活到薄膜完全显形之后才自然消失，
	# 避免"碎片已经收拢完了、金膜却还没亮"的空档（推测：这 0.15s 余量就是为此留的）。
	p.lifetime = gather_time + 0.15
	# 一波一波地发射（不是常驻喷雾）：每次 start_cast / _begin_shatter 都靠 restart() 重新起一波，
	# 平时 emitting = false，粒子系统不产生任何开销。
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


## 切换碎片的生成模式，对应 gold_shard.gdshader 的 mode uniform。
## 参数 m：0 = 汇聚（在角色四周球面上生成、逐片收拢到身上）；1 = 发散（从角色身上向外飞散、越飞越淡）。
##   着色器里是 `if (mode == 0) ... else ...`，所以除 0 以外任何值都走发散分支。
## 返回值：无。副作用：只写 _shard_mat 的一个 uniform，**不**重启粒子。
## 注意：对已经生成、正在飞的粒子无效，必须紧接着 _shards.restart() 才看得到变化（见 _begin_shatter）；
##   材质为 null（shader 缺失）时静默跳过，调用方不必判空。
func _set_shard_mode(m: int) -> void:
	if _shard_mat != null:
		_shard_mat.set_shader_parameter("mode", m)


## 把金色薄膜逐个贴到角色的网格上（material_overlay，不动物体自己的材质），
## 同时量出角色高度，用来自动定金色罩壳的大小。
## 参数 / 返回值：无。
## 副作用：给角色的每个 MeshInstance3D 设 material_overlay = _film（原值先备份进 _mesh_prev）；
##   量到高度后在角色竖直中点新建 SphereMesh 罩壳（_aura + _aura_mat）并 add_child 到本节点。
## 细节：_film 只在第一次调用时创建、之后复用（不会一轮轮泄漏材质资源）；罩壳则每轮重建，由 _cleanup() 回收。
## 失败路径：shader 加载失败或 _player 失效时，都会在**碰任何网格之前**提前 return，
##   所以不会留下"贴了一半"的中间状态（最多只是 _film 已经建好但没用上）。
## 注意：算法依赖 _process 已把本节点 global_position 对齐到角色，否则罩壳位置会算偏。
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
		# 先备份再覆盖：角色网格上原本可能已经挂着别的 overlay（其它状态特效 / 染色），
		# 结束时必须还原成原值而不是一律置空，否则会顺手把别人的效果抹掉（见 _cleanup / _exit_tree）。
		_mesh_prev.append({"mi": mi, "prev": mi.material_overlay})
		mi.material_overlay = _film
		if mi.mesh != null:
			var aabb := mi.mesh.get_aabb()
			var xf := mi.global_transform
			# 用 AABB 的 8 个角点（用位运算枚举 0~7）求世界 Y 范围：
			# 角色各部件可能自带缩放/旋转，只拿 AABB.position/size 加一下原点 Y 会算错高度，
			# 逐个角点经 global_transform 变换后才准确（x/z 分量这里故意不用）。
			for i in range(8):
				var c := aabb.position + Vector3(
						aabb.size.x if (i & 1) != 0 else 0.0,
						aabb.size.y if (i & 2) != 0 else 0.0,
						aabb.size.z if (i & 4) != 0 else 0.0)
				lo = minf(lo, (xf * c).y)
				hi = maxf(hi, (xf * c).y)
	# lo > hi 说明上面一个带 mesh 的网格都没量到（lo 还是 1e9、hi 还是 -1e9）→ 无法定罩壳尺寸，
	# 直接放弃建罩壳。此时薄膜已经贴上去了，仍能正常显形与碎裂，只是没有外层光壳。
	if lo > hi:
		return
	# 金色罩壳：包住角色的一层光壳（与薄膜共用材质 -> 一起碎裂）
	var h := hi - lo
	# 罩壳半径 = 角色高度的一半 × aura_gain(1.12)，即比角色略大一圈，避免边缘穿进身体里；
	# 下限 0.35 米是兜底：角色高度若被量成极小值（只剩一个小部件有 mesh），罩壳也不会缩到看不见。
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
	# 用导出值 aura_body(0.05) 而不是 shader 默认 0.16：罩壳只要"近乎只有边"的一层光。
	# 调大它 → 罩壳越来越像实心金球（用户要的是"一身金色薄膜"，不是把人扣在球里）。
	_aura_mat.set_shader_parameter("body_strength", aura_body)
	# 下面三个是**硬编码覆盖** gold_film.gdshader 的默认值（默认 rim_strength 2.2 / rim_power 2.6 /
	# crack_glow 1.6）：刻意把罩壳边缘提亮、把碎裂裂纹做得更明显。
	# 想调罩壳观感改这里；想调角色身上薄膜的观感改 shader 里的默认值。
	_aura_mat.set_shader_parameter("rim_strength", 1.7)
	_aura_mat.set_shader_parameter("rim_power", 3.2)
	_aura_mat.set_shader_parameter("crack_glow", 1.4)
	aura.material_override = _aura_mat
	aura.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(aura)
	# 罩壳是本节点（Node3D）的子节点，而 lo/hi 是世界坐标的 Y → 必须减掉本节点的世界 Y
	# 才是正确的局部坐标；又因为 _process 每帧把本节点对齐到角色，这行等于把罩壳摆在角色身体竖直中点。
	aura.position = Vector3(0.0, (lo + hi) * 0.5 - global_position.y, 0.0)
	_aura = aura


# ==================== 着色器参数工具与网格收集 ====================
## 设置"薄膜显形程度"（gold_film.gdshader 的 reveal uniform）。
## 参数 v：0 = 完全看不见，1 = 完全显形；函数内部会 clampf 到 [0, 1]，所以调用方可以直接传公式结果。
## 返回值：无。
## 副作用：**同时**写 _film（角色身上的薄膜）与 _aura_mat（罩壳）两个材质；某个为 null 时跳过那一半。
## 调用时机：ST_GATHER 每帧（smoothstep 让薄膜在碎片快到齐时才浮现）、进入 ST_FILM 时置 1、_cleanup() 时置 0。
## 注意：两处必须一起改 —— 只改一个会出现"人还没穿上金衣、外面先浮起一个球"的怪相。
func _set_reveal(v: float) -> void:
	var r := clampf(v, 0.0, 1.0)
	if _film != null:
		_film.set_shader_parameter("reveal", r)
	if _aura_mat != null:
		_aura_mat.set_shader_parameter("reveal", r)


## 设置"碎裂进度"（gold_film.gdshader 的 dissolve uniform，配合噪声贴图把薄膜一块块抠掉）。
## 参数 v：0 = 薄膜完整，1 = 整层已被抠完；内部同样 clampf 到 [0, 1]。
## 返回值：无。
## 副作用：**同时**写 _film 与 _aura_mat —— 保证角色身上的薄膜与外围罩壳同步碎裂，不会一先一后。
## 调用时机：ST_SHATTER 期间每帧由 _process 推进；_cleanup() 时强制归零。
## 注意：材质是复用的，_cleanup() 不归零的话，下一轮施法一开场薄膜就已经是"碎完"的样子。
func _set_dissolve(v: float) -> void:
	var d := clampf(v, 0.0, 1.0)
	if _film != null:
		_film.set_shader_parameter("dissolve", d)
	if _aura_mat != null:
		_aura_mat.set_shader_parameter("dissolve", d)


## 递归收集节点树里所有的 MeshInstance3D（含深层子节点，例如角色骨骼/模型下的各个部件）。
## 参数 n：起始节点（_build_film 里传 _player）；out：输出数组，**原地追加、不清空**（调用方自己建空数组）。
## 返回值：无（结果通过 out 带出）。
## 副作用：纯读场景树，不修改任何节点。
## 注意：递归没有深度上限，n 必须是场景树里的一棵子树；
##   只认 MeshInstance3D —— MultiMeshInstance3D / Sprite3D / 纯 CSG 等可视节点**不会**被收集，
##   也就不会贴上金色薄膜（角色模型若有这类部件，需要单独处理）。
func _gather_meshes(n: Node, out: Array[MeshInstance3D]) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			out.append(c as MeshInstance3D)
		else:
			_gather_meshes(c, out)

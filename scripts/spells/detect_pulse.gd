extends Node3D
## 物体探测 —— 声呐式脉冲：从角色脚下发出一圈扩张的波纹，
## 波面扫到可碰撞物体时**描出它的轮廓**，1 秒后轮廓消失。
##
## 对外接口与其它术法一致（见 spell_caster.gd 顶部注册表）：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()
##
## ---------------------------------------------------------------- 设计要点
##
## 【1. 波纹中心固定在**施放点**，不跟着角色走】
##   需求里特意点了"考虑角色移动的情况"。如果把圆心每帧绑在角色身上，
##   角色往前走时波面会**拖着一起平移**：已经扫过的区域被再次扫，
##   而波面本身永远追不上前方物体（圆心和半径同时在动）。
##   这里把圆心在施放那一瞬定死，波面在**世界空间**独立扩张 —— 与真实声呐一致：
##   人走开，波纹留在原地继续扩散。
##
## 【2. 用"半径内的球形查询"而不是"环形查询"】
##   波面是一个薄环，但检测用**整球**（半径 = 当前波面半径）。
##   原因：低帧率下半径一帧可能涨 1 米以上，只查薄环会**漏掉**恰好跨过的那批物体。
##   查整球 = 半径内一律命中，天然没有漏检；观感上因为轮廓有 1 秒寿命，
##   仍然是"波纹扫过时才亮"。
##
## 【3. 只探测地形之上的物体】
##   地形自己是个巨大的碰撞体，不排除的话会画出铺满全屏的轮廓。
##   排除方式两条：① 祖先里有 Terrain3D / 名字含地形关键字；
##   ② 物体中心低于角色脚下（说明在地面以下）。
##
## 【4. 限制在屏幕 1.2 倍区域】
##   两处都做：波纹的**最大半径**由相机推导（屏幕四角投到水平面取最远 ×1.2），
##   物体再逐帧做一次**屏幕矩形**判定（允许超出屏幕边缘各 10%）。
##   前者让波纹视觉上停在屏幕边，后者保证逻辑上不探测屏外的东西。
##
## 【5. 轮廓怎么画 —— 物体保持原样 + 一圈动漫描边】
##   给物体叠加一层描边材质（material_overlay），**不替换它自己的材质**。
##   描边思路：在**视图空间**把顶点沿"远离视线轴"方向外扩，只画背面，
##   于是屏幕上剪影向外胀出一圈；内部则查**深度纹理**得到该像素上场景已有的深度，
##   如果它在片元前面就 `discard` —— 于是只剩轮廓外缘那圈线。
##   探测结束后把 overlay 还原即可。
##
## 【6. 波纹长什么样 —— 细线 + 震荡】
##   一块平面网格 + 着色器按**径向距离**画：半径天生是正圆；用正弦取正幂次
##   得到很细的线；一串间隔 wavelength 的环从中心向外传播、逐圈按 decay 衰减，
##   就是水波那种震荡感。同理不用实体圆环（管子粗、地形上会被埋）。

const SpellAim := preload("res://scripts/spells/spell_aim.gd")
## 地面波纹：按径向距离画一圈圈**细线**（正圆 + 衰减震荡），不用实体圆环
const RIPPLE_SHADER := "res://assets/shaders/detect_ripple.gdshader"
## 描边：视图空间外扩的剪影线，内部按深度丢弃（物体外观不受影响）
const OUTLINE_SHADER := "res://assets/shaders/detect_outline.gdshader"
## 屏幕空间描边（全屏后处理，靠深度突变找轮廓）—— 四周都有线、线宽恒定
const SCREEN_OUTLINE_SHADER := "res://assets/shaders/detect_screen_outline.gdshader"

# ---------------------------------------------------------------- 可调参数
@export var mana_per_cast := 12.0          ## 每发一圈的耗蓝
@export var repeat_interval := 2.4         ## 按住时每隔多久再发一圈；0 = 只发一圈（间隔太短会让多圈叠在一起，看着很密）
@export var wave_speed := 26.0             ## 波面扩张速度（米/秒）—— 太慢会显得拖
@export var outline_life := 1.0            ## 轮廓显示多久（秒）—— 需求指定 1s

# ---- 描边：动漫风格（物体保持原样，只在外缘加一圈线）----
@export var line_color := Color(0.30, 0.95, 1.0)
@export var line_grow := 0.016             ## 视图空间外扩（米）= 线有多粗（细线）
@export var depth_bias := 0.02             ## 深度比较容差（米）：太小挡不住内部，太大会吃掉边线
## 揭示边缘的柔化宽度（米）：线条随波面长出来时，前沿这一小段是渐入的
@export var reveal_soft := 0.35
## 让轮廓**提前**这么多米出现。用户反馈"轮廓绘制有延迟" —— 因为轮廓严格等波面扫到
## 才画，观感上会慢半拍；提前一点点（相对 26 m/s 只有几十毫秒）就没有"在等"的感觉了。
@export var reveal_ahead := 1.2
## 物体半透明度（0 = 保持原样）。调大一点更接近"只显示轮廓"，
## 又不至于像早先的实心填充那样糊成黑疙瘩。
@export_range(0.0, 0.95, 0.01) var ghost := 0.0

# ---- 屏幕空间描边（推荐）：四周都有线、线宽固定为像素，与视角无关 ----
## true = 用屏幕空间描边（此时上面那套几何描边不生效，二者只取其一）
@export var screen_outline := true
@export var screen_line_alpha := 0.9
@export var screen_sample_px := 1.0        ## 邻域采样偏移（像素）= 线宽（1.0 ≈ 1px 细线）
@export var screen_depth_threshold := 2.2  ## 视深度梯度阈值（米）：实测 0.6 会把草也描出来，2.2 只剩大物体
## 只描"被探测到的物体"所占屏幕区域 —— 花草没有碰撞体、探测不到，于是不会被描。
## ★★ 目前默认**关闭**：遮罩通道（SubViewport + cull_mask）还没拿到干净的物体图，
##    开着会导致**一条轮廓线都画不出来**。关掉时走"主画面深度突变"那条路，
##    也就是评价过"效果还可以"的版本（代价：草会被一起描）。
##    已确认的测量事实记录在 _ensure_mask_pass() 的注释里，别重复踩。
@export var mask_by_objects := false
## 波纹是否**跟随角色移动**（true = 圆心每帧跟到角色脚下）
@export var follow_caster := true

## 遮罩用的渲染层。
## ★★ 用**低位**（第 8 位），不要用 1<<19 那种最高位：实测用 1<<19 时，
##    网格的 layers 确实置位了、遮罩相机的 cull_mask 也是同一位（AND 非零），
##    但子视口里**看不到任何物体**（遮罩一片背景色）—— 高位在渲染端疑似不被支持。
const MASK_LAYER := 1 << 7

# ---- 地面波纹：细线环 + 波前亮带 + 噪声扭曲 ----
@export var wave_color := Color(0.35, 0.90, 1.0)
@export var wavelength := 9.0              ## 相邻细环的间距（米），越小越密（9.0 = 圈数更少）
@export var sharpness := 180.0             ## 越大，线越细
@export var decay := 2.8                   ## 后面的环衰减得多快（越大越少）
@export var wave_intensity := 1.25
@export var wave_lift := 0.12              ## 波纹抬离地面多少（免得被地表吃掉）
@export var wave_warp := 0.55              ## 噪声扭曲幅度（米）：0 = 标准圆
@export var lead_width := 0.9              ## 波前亮带宽度（米）
@export var lead_gain := 1.5               ## 波前亮带强度
@export var screen_margin := 1.2           ## 需求指定：屏幕 1.2 倍区域
## 关掉屏幕内剔除（**只给无头自检用**）。
## 无头运行时相机不会跟到玩家身上（跟随要真实帧），物体投影会落在视口外，
## 于是屏幕剔除会把一切拒掉 —— 那时该测的是"检测/轮廓/过期"，不是取景。
## 真实游戏里必须保持 true。
@export var screen_cull := true
@export var max_radius_cap := 42.0         ## 最大半径上限（防止超大分辨率下失控）
@export var max_radius_fallback := 16.0    ## 取不到相机时的兜底半径
@export var detect_mask := 0               ## 0 = 沿用玩家自己的碰撞掩码
## 命中名字含这些就跳过。排除逻辑是**沿可视节点向上逐级匹配父节点名字**，
## 所以只要祖先里有这个词就会被排除。
## 花草虽然有碰撞体的不多，但 bush / flower / grass_bermuda_01_* 都挂在
## WorldBrushInstances 下，靠这几个特征词一次全排掉（不需要额外代码）。
@export var exclude_name_hints := "terrain,ground,grass,bush,flower,plant,leaf,foliage,weed,shrub,fern,clover,草,花,灌木,植物"
@export var max_results := 512

## 波动画：中心到当前半径
var casting := false

var _aim := SpellAim.new()
var _player: Node3D = null
var _pulses: Array = []                    ## 在飞的波纹：{center, r, max_r, ripple}
var _outlined: Dictionary = {}             ## 实例 id -> {node, meshes:[{mi, prev}], until}
var _ran_out := false
var _cooldown := 0.0
## 自己累加的游戏时钟。★ 刻意**不用 Time.get_ticks_msec()**：
## 真实时间不跟随暂停 / Engine.time_scale，也会让"按帧步进"的自检无法推进
## （实测：手动步进 1.25 秒，真实时间没过，轮廓永远不过期）。
var _clock := 0.0
## "物体在地形之上"的判定结果缓存（按实例 id）。每个物体只问一次，不是每帧射线。
var _terrain_ok: Dictionary = {}
## 地形所在碰撞层，运行时自己找（0 = 还没找到）
var _terrain_layer_cache := 0
## 屏幕空间描边用的全屏面（挂在相机下，所以必须自己回收）
var _screen_quad: MeshInstance3D = null
## 物体遮罩用的子视口 + 只渲染 MASK_LAYER 的相机
var _mask_vp: SubViewport = null
var _mask_cam: Camera3D = null
## 本帧被探测物体的**世界包围盒**（每个元素 = [min:Vector3, max:Vector3]），
## 供屏幕描边做三维判定：只有像素的世界坐标落在盒子里才算"这是物体本身"。
var _boxes: Array = []


func _ready() -> void:
	set_process(true)
	# ★ 处理优先级提到很高，让本节点的 _process **在相机 rig 之后**执行。
	#   遮罩相机是在这里同步主相机变换的；如果它先执行、相机 rig 后执行，
	#   遮罩就会**慢一帧**，画出来的轮廓看起来"跟不上"（用户报过轮廓有延迟）。
	process_priority = 1000


func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
func start_cast() -> void:
	if not casting:
		# 按下那一瞬：立刻发一圈（不等 _process，避免第一帧从静默开始）
		_emit_pulse()
	casting = true


func stop_cast() -> void:
	casting = false
	# ★ 刻意**不**清掉在飞的波纹和已画出的轮廓：
	#   波纹是独立于角色的世界事件，松手后它该继续扩散、轮廓该自然到期消失。
	#   在这里清掉会变成"一松手效果就没了"，观感很廉价。
	_cooldown = 0.0


func is_casting() -> bool:
	return casting


func ran_out_of_mana() -> bool:
	return _ran_out


func aim_dir() -> Vector3:
	return _aim.aim_dir()


func origin_global() -> Vector3:
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	_clock += delta
	_boxes.clear()             # 每帧重建：只反映"本帧被探测到的物体"
	_tick_pulses(delta)
	_update_reveal()
	_update_screen_outline()
	_expire_outlines()

	if not casting:
		return
	# 按住时按间隔续发（tap 一下就是单发一圈）
	if repeat_interval > 0.0:
		_cooldown -= delta
		if _cooldown <= 0.0:
			_emit_pulse()
			_cooldown = repeat_interval


# ---------------------------------------------------------------- 发波
func _emit_pulse() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	# 一次性扣蓝：不够就这一圈不放（并标记耗尽，交给上层/HUD）
	if not Mana.try_spend(mana_per_cast):
		_ran_out = true
		return
	_ran_out = false

	var center := _player.global_position      # 脚下，世界坐标；此后**不再跟随角色**
	var max_r := _screen_max_radius(center)
	var ripple := _make_ripple(max_r)
	add_child(ripple)
	ripple.global_position = center + Vector3.UP * wave_lift
	_pulses.append({
		"center": center,
		"r": 0.0,
		"max_r": max_r,
		"ripple": ripple,
	})


func _tick_pulses(delta: float) -> void:
	if _pulses.is_empty():
		return
	var alive: Array = []
	for p in _pulses:
		var pulse: Dictionary = p
		pulse["r"] = float(pulse["r"]) + wave_speed * delta
		var r := float(pulse["r"])
		var max_r := float(pulse["max_r"])
		# ★ 跟随角色：圆心每帧跟到角色脚下（用户要求"探测波随人物移动"）。
		#   注意这会改变语义 —— 圆心与半径同时在动，已经扫过的区域会被重复扫。
		if follow_caster and _player != null and is_instance_valid(_player):
			pulse["center"] = _player.global_position
			var rn = pulse["ripple"]
			if rn != null and is_instance_valid(rn):
				(rn as Node3D).global_position = _player.global_position + Vector3.UP * wave_lift
		# 视觉：只把"波前推进到哪"交给着色器，后面那一串衰减的细环由它自己画
		_apply_ripple(pulse["ripple"], r, max_r)
		var pcenter: Vector3 = pulse["center"]
		_detect(r, pcenter, max_r, pulse)

		if r < max_r:
			alive.append(pulse)
		else:
			# 到顶：清掉波纹节点（轮廓自己按寿命消失，不在这里清）
			var n = pulse["ripple"]
			if n != null and is_instance_valid(n):
				n.queue_free()
	_pulses = alive


func _apply_ripple(node: Variant, radius: float, max_r: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var mi := node as MeshInstance3D
	var mat := mi.material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("progress",
				clampf(radius / maxf(max_r, 0.001), 0.0, 1.0))


# ---------------------------------------------------------------- 检测
## 半径内的球形查询；命中 -> 描轮廓
func _detect(radius: float, center: Vector3, max_r: float, pulse: Dictionary) -> void:
	if radius <= 0.0:
		return
	var world := get_world_3d()
	if world == null:
		return
	var space := world.direct_space_state
	if space == null:
		return

	var shape := SphereShape3D.new()
	shape.radius = maxf(0.05, radius)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	# 球心略微抬高：以角色脚下为中心的话，一半球体在地下，浪费且容易吃到地形
	params.transform = Transform3D(Basis(), center + Vector3.UP * 0.5)
	params.collision_mask = _mask()
	params.collide_with_bodies = true
	params.collide_with_areas = false
	# ★ 不要写 params.max_results —— PhysicsShapeQueryParameters3D **没有这个属性**
	#   （实测：会直接 "Invalid assignment of property 'max_results'"，并把游戏停在
	#   调试断点上）。max_results 只是 intersect_shape() 的**第二个实参**。
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())
	params.exclude = exclude

	var hits := space.intersect_shape(params, max_results)
	var now := _now()
	for h in hits:
		var collider: Object = h.get("collider")
		var node := collider as Node
		if node == null:
			continue
		# 解析出真正持有网格的节点，并用**几何包围盒**（而不是容器节点的
		# global_position）来判屏幕位置与"是否在地形之上"。
		# ★ 外部导入的容器原点常在 (0,0,0)、几何体是偏移的 —— 拿容器的
		#   global_position 做屏幕判定会把所有物体都判到屏幕外（实测踩过：
		#   波纹半径都涨到 31 米了，outlined 仍是 0）。
		var visual := _resolve_visual(node)
		if visual == null:
			continue
		var box := _visual_aabb(visual)
		if box.size.length_squared() <= 0.0:
			continue
		if not _is_detectable(node, visual, center, box):
			continue
		if not _in_screen_margin(box):
			continue
		# 记录世界包围盒：屏幕描边靠它把"物体体积之外"的东西（草、地形）排除掉。
		# ★ 不要挂到 mask_by_objects 上：遮罩通道目前是关的，而 AABB 判定正是
		#   遮罩关闭时压草的主力。挂错了会导致过滤器完全不生效（实测 box_count = 0）。
		if screen_outline:
			_add_box(box)
		_outline(visual, now, pulse)


## 记录一个世界包围盒（最多 16 个，按 min 去重）。
## 去重是必要的：同一个 tripo_part_N 下可能挂多个碰撞体，会拿到同一个可视父节点、
## 同一个盒，否则 16 个名额会被一个物体占满。
func _add_box(box: AABB) -> void:
	if _boxes.size() >= 16:
		return
	var lo := box.position
	for b in _boxes:
		if (lo - (b as Array)[0] as Vector3).length_squared() < 0.0025:
			return
	_boxes.append([lo, box.position + box.size])


# ---------------------------------------------------------------- 物体遮罩（SubViewport）
## 把"本帧被探测到的物体"单独渲进一张遮罩图，供屏幕空间描边按像素判定。
##
## 为什么需要：屏幕描边是纯深度边缘检测，被波扫过的屏幕区域里**所有**深度突变都会出线，
## 包括**没有碰撞体的花草**（用户报过"草也被探测到了"）。
## 先用屏幕 AABB 矩形遮罩试过 —— 不够：大件物体的矩形覆盖范围很大，落在矩形里的草照样被描出来。
##
## 做法：所有被探测到的网格临时加上 MASK_LAYER 这一层；遮罩相机只渲染这一层
## （cull_mask = MASK_LAYER），主相机的 cull_mask 是全开的，所以物体在主画面照常显示。
func _ensure_mask_pass() -> bool:
	if _mask_vp != null and is_instance_valid(_mask_vp) and _mask_cam != null \
			and is_instance_valid(_mask_cam):
		return true
	var world := get_world_3d()
	if world == null:
		return false
	var vp := get_viewport()
	var size := vp.get_visible_rect().size if vp != null else Vector2(1280.0, 720.0)
	var sv := SubViewport.new()
	sv.name = "DetectMask"
	# ★★ 背景必须**透明**，而且**不要给遮罩相机设自定义 Environment**。
	#   这两条是量出来的，别再"想当然地修"：
	#     · environment = null + transparent_bg = true   -> 遮罩 RGB 有内容 34% ✅ 物体在遮罩里
	#     · 给它一个自定义 Environment（BG_CLEAR_COLOR 之类）-> 遮罩最大亮度 0.0 ❌ 什么都没渲染
	#   透明背景是必须的：这样没物体的地方 RGB 才恰好为 0，和物体像素区分得开。
	#   （注意不透明几何体不写 alpha，所以判定只能看 RGB，不能看 alpha。）
	sv.transparent_bg = true
	sv.size = Vector2i(maxi(1, int(size.x)), maxi(1, int(size.y)))
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.disable_3d = false
	# ★★ 千万不要给这个子视口设 debug_draw = DEBUG_DRAW_UNSHADED：
	#   实测会把它渲成**整张全黑**（遮罩最大亮度 0.0），于是"是否在遮罩内"的判断恒为假，
	#   **一条轮廓线都画不出来**。保持正常渲染即可 —— 物体受光后虽有明暗，
	#   但亮度都远高于着色器里 0.002 的判定阈值。
	add_child(sv)
	# ★★★ 根因就在这两行（量出来的：不这么写时 world_3d 是 null，子视口什么都渲染不出来，
	#     遮罩最大亮度恒为 0.0 -> 一条轮廓线都没有）。
	#   Godot 里子视口**不会自动继承**父视口的 3D 世界，必须显式共享；
	#   而共享的正确姿势是**先 own_world_3d = true、再赋 world_3d**：
	#   只赋 world_3d 而在 own_world_3d = false 时是不生效的。
	sv.own_world_3d = true
	sv.world_3d = world
	var cam := Camera3D.new()
	cam.name = "MaskCam"
	cam.cull_mask = MASK_LAYER          # 只渲染被探测到的物体
	# ★★ 这里**不要设 cam.environment**（保持 null = 沿用共享世界的环境）。
	#   量过：给遮罩相机一个自定义 Environment 会把整张遮罩渲成全黑（最大亮度 0.0），
	#   一条轮廓线都画不出来。共享世界环境下，物体有光照、亮度正常，够判定用了。
	sv.add_child(cam)
	cam.current = true
	# ★ 保险：主相机必须能看见遮罩层，否则被探测到的物体会**从主画面消失**
	#   （网格被加了这一层，而主相机如果没开这一层就渲染不到它）。
	var main_cam := _camera()
	if main_cam != null and (main_cam.cull_mask & MASK_LAYER) == 0:
		main_cam.cull_mask |= MASK_LAYER
	_mask_vp = sv
	_mask_cam = cam
	return true


## 每帧把遮罩相机同步到主相机（位置/朝向/投影必须一致，否则遮罩和画面对不上）
func _sync_mask_camera() -> void:
	if _mask_cam == null or not is_instance_valid(_mask_cam):
		return
	var cam := _camera()
	if cam == null:
		return
	_mask_cam.global_transform = cam.global_transform
	_mask_cam.projection = cam.projection
	_mask_cam.fov = cam.fov
	_mask_cam.size = cam.size
	_mask_cam.near = cam.near
	_mask_cam.far = cam.far
	_mask_cam.keep_aspect = cam.keep_aspect
	var vp := get_viewport()
	if vp != null and _mask_vp != null:
		var s := vp.get_visible_rect().size
		var want := Vector2i(maxi(1, int(s.x)), maxi(1, int(s.y)))
		if _mask_vp.size != want:
			_mask_vp.size = want


## 一组网格的世界包围盒并集
func _visual_aabb(visual: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi in _visible_meshes(visual):
		var m := mi as MeshInstance3D
		var b: AABB = m.global_transform * m.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## 碰撞体 -> 真正持有网格的节点。
##
## ★★ 必须**向上找**：本项目的碰撞体与网格常常是**兄弟**，不是父子。
##    实测（玩家 12 米内唯一的那批碰撞体）：
##        /root/Main/墓地遗迹/ROOT/tripo_part_0/StaticBody3D    <- 只有 CollisionShape3D
##        /root/Main/墓地遗迹/ROOT/tripo_part_0/<MeshInstance3D> <- 网格在兄弟上
##    第一版只查"碰撞体自己的子节点"，于是每个物体都判成"没有可见网格"，
##    结果 outlined 恒为 0 —— 波纹在跑，却什么都描不出来。
##    向上最多爬 3 层，取最近的那个有可见网格的祖先。
func _resolve_visual(node: Node) -> Node:
	if not _visible_meshes(node).is_empty():
		return node
	var cur := node.get_parent()
	var depth := 0
	while cur != null and depth < 3:
		if not _visible_meshes(cur).is_empty():
			return cur
		cur = cur.get_parent()
		depth += 1
	return null


## 哪些东西不描轮廓
func _is_detectable(node: Node, visual: Node, center: Vector3, box: AABB) -> bool:
	# 玩家自己
	if _player != null and (node == _player or _player.is_ancestor_of(node)):
		return false
	# 地形 / 地面：从真正持有网格的节点向上查（地形碰撞体的父节点就是 Terrain3D）
	var hints := exclude_name_hints.split(",", false)
	var cur: Node = visual
	while cur != null:
		var cls := String(cur.get_class()).to_lower()
		var nm := String(cur.name).to_lower()
		if cls.contains("terrain"):
			return false
		for hint in hints:
			var h := String(hint).strip_edges().to_lower()
			if not h.is_empty() and nm.contains(h):
				return false
		cur = cur.get_parent()
	# 只探测**地形之上**的物体
	return _above_terrain(visual, box)


## "这个物体是否在地形之上"：从它的几何中心向下打一条射线，**必须打到地形**。
##
## ★ 一开始我用的是"几何顶面要高于角色脚下"，那是**错的**：
##   角色站在高处时，旁边低处的遗迹会被判成"在地下"。
##   实测数据：tripo_part_0 的顶面 0.94，而角色脚下 1.82 —— 于是整片墓地遗迹
##   一个都探不到（outlined 恒为 0）。正确做法是**以物体自己为中心**去问地形
##   在不在它下面，跟角色站多高无关。
##
## 结果按实例缓存：只会问一次，不是每帧都打射线。
func _above_terrain(visual: Node, box: AABB) -> bool:
	var id := visual.get_instance_id()
	if _terrain_ok.has(id):
		return bool(_terrain_ok[id])
	var ok := true
	var layer := _terrain_layer()
	if layer != 0:
		var world := get_world_3d()
		if world != null:
			var space := world.direct_space_state
			if space != null:
				var from := box.get_center() + Vector3.UP * 0.05
				var query := PhysicsRayQueryParameters3D.create(
						from, from + Vector3.DOWN * 80.0, layer)
				ok = not space.intersect_ray(query).is_empty()
	_terrain_ok[id] = ok
	return ok


## 地形所在的碰撞层：**运行时按类名找**（含 terrain 的节点下第一个碰撞体），
## 不写死层号 —— 写死的话以后改层就会静默失效，而且没人会发现。
func _terrain_layer() -> int:
	if _terrain_layer_cache != 0:
		return _terrain_layer_cache
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 0
	var stack: Array = [tree.current_scene]
	while not stack.is_empty():
		var n := stack.pop_back() as Node
		if n == null:
			continue
		if String(n.get_class()).to_lower().contains("terrain"):
			var found := _first_collision_layer(n)
			if found != 0:
				_terrain_layer_cache = found
				return found
		for c in n.get_children():
			stack.append(c)
	return 0


func _first_collision_layer(from_node: Node) -> int:
	var stack: Array = [from_node]
	while not stack.is_empty():
		var n := stack.pop_back() as Node
		if n == null:
			continue
		if n is CollisionObject3D:
			var l := (n as CollisionObject3D).collision_layer
			if l != 0:
				return l
		for c in n.get_children():
			stack.append(c)
	return 0


## 屏幕 1.2 倍区域判定 —— **物体只要有任意一部分落在区域内就算**。
##
## ★ 不要只判包围盒中心。实测：墓地遗迹的碰撞体明明在玩家 12 米内，但它解析到的
##   可视部件（tripo_part_N）是个 17 米见方的大件，**中心**投影到 x≈1999，
##   而视口只有 1280 —— 于是被整体判成"在屏外"，一个都描不出来。
##   正确做法：把包围盒 8 个角投影出来，看二维包围矩形是否与区域**相交**。
func _in_screen_margin(box: AABB) -> bool:
	if not screen_cull:
		return true
	var cam := _camera()
	var vp := get_viewport()
	if cam == null or vp == null:
		return true
	var size := vp.get_visible_rect().size
	# 视口尺寸退化或相机投影不可用时不判定（理由见 _camera_usable）
	if size.x <= 1.0 or size.y <= 1.0 or not _camera_usable(cam, size):
		return true
	var m := (screen_margin - 1.0) * 0.5
	var lo := Vector2(-m * size.x, -m * size.y)
	var hi := Vector2((1.0 + m) * size.x, (1.0 + m) * size.y)
	var min_sp := Vector2(1e20, 1e20)
	var max_sp := Vector2(-1e20, -1e20)
	var any := false
	var behind := 0
	for i in range(8):
		var corner := box.position + Vector3(
				box.size.x if (i & 1) != 0 else 0.0,
				box.size.y if (i & 2) != 0 else 0.0,
				box.size.z if (i & 4) != 0 else 0.0)
		if cam.is_position_behind(corner):
			behind += 1
			continue
		var sp := cam.unproject_position(corner)
		min_sp = min_sp.min(sp)
		max_sp = max_sp.max(sp)
		any = true
	# 一部分角在相机后、一部分在前：物体横跨镜头，判它可见（取景已不可靠）
	if behind > 0 and behind < 8:
		return true
	if not any:
		return false
	return min_sp.x <= hi.x and max_sp.x >= lo.x and min_sp.y <= hi.y and max_sp.y >= lo.y


## 单点版本（供自检/调试用；判定物体请用上面的包围盒版）
func _point_in_screen_margin(pos: Vector3) -> bool:
	if not screen_cull:
		return true
	var cam := _camera()
	var vp := get_viewport()
	if cam == null or vp == null:
		return true
	var size := vp.get_visible_rect().size
	if size.x <= 1.0 or size.y <= 1.0 or not _camera_usable(cam, size):
		return true
	if cam.is_position_behind(pos):
		return false
	var sp := cam.unproject_position(pos)
	var m := (screen_margin - 1.0) * 0.5
	return sp.x >= -m * size.x and sp.x <= (1.0 + m) * size.x \
			and sp.y >= -m * size.y and sp.y <= (1.0 + m) * size.y


## 相机投影是否可用。
##
## ★ 无头运行时 Camera3D 的投影矩阵可能根本没被算过（没有真正的渲染），
##   此时 unproject_position() 返回垃圾值。实测现象：视口 1280×1280、相机有效，
##   但**所有**物体都被判成"不在屏幕内" —— outlined 恒为 0，看起来像探测完全失效，
##   很容易误以为是自己逻辑写错（我就在这上面绕了一圈）。
## 自检办法：相机正前方 1 米处**必然**投影在视口中心附近；对不上就认定不可用。
func _camera_usable(cam: Camera3D, size: Vector2) -> bool:
	var front := cam.global_transform.origin - cam.global_transform.basis.z
	if cam.is_position_behind(front):
		return false
	var sp := cam.unproject_position(front)
	return sp.distance_to(size * 0.5) < size.length() * 0.25


## 屏幕四角/四边投到"角色脚底所在水平面"，取最远距离 × screen_margin
func _screen_max_radius(center: Vector3) -> float:
	var cam := _camera()
	var vp := get_viewport()
	if cam == null or vp == null:
		return max_radius_fallback
	var size := vp.get_visible_rect().size
	if size.x <= 1.0 or size.y <= 1.0 or not _camera_usable(cam, size):
		return max_radius_fallback
	var plane := Plane(Vector3.UP, center.y)
	var best := 0.0
	var uvs := [
		Vector2(0.0, 0.0), Vector2(1.0, 0.0), Vector2(0.0, 1.0), Vector2(1.0, 1.0),
		Vector2(0.5, 0.0), Vector2(0.5, 1.0), Vector2(0.0, 0.5), Vector2(1.0, 0.5),
	]
	for uv in uvs:
		var screen_pos: Vector2 = uv * size
		var org := cam.project_ray_origin(screen_pos)
		var dir := cam.project_ray_normal(screen_pos)
		var hit: Variant = plane.intersects_ray(org, dir)
		if hit == null:
			continue
		var p: Vector3 = hit
		best = maxf(best, Vector2(p.x - center.x, p.z - center.z).length())
	if best <= 0.01:
		return max_radius_fallback
	return minf(best * screen_margin, max_radius_cap)


# ---------------------------------------------------------------- 描边（物体原样 + 外缘一圈线）
## 给探测到的物体叠加一层描边（material_overlay），**不替换它自己的材质**。
##
## ★ 为什么不再用 material_override + 实心填充
##   那层近黑不透明填充本来是给"反壳"挡内部用的，结果整个物体变成一个大黑疙瘩，
##   用户反馈"太丑"。现在内部改由描边着色器**查深度纹理 discard** 掉，不需要填充，
##   物体保持原本外观，只在轮廓外缘多一圈线。
##
## ★ 按**解析出来的可视节点**分组、而不是按碰撞体分组：
##   同一个 tripo_part_N 下可能挂着多个碰撞体（实测 StaticBody3D 与 StaticBody3D6 同父），
##   按碰撞体分组会让两组去抢同一批网格的 material_overlay —— 后一组把前一组的
##   描边当成"原值"存下来，到期还原顺序一乱就会留下永久描边或提前取消。
func _outline(visual: Node, now: float, pulse: Dictionary) -> void:
	var id := visual.get_instance_id()
	var entry: Dictionary = _outlined.get(id, {})
	if entry.is_empty():
		var meshes: Array = []
		for mi in _visible_meshes(visual):
			var mesh := mi as MeshInstance3D
			meshes.append({
				"mi": mesh,
				"prev_overlay": mesh.material_overlay,
				"prev_transparency": mesh.transparency,
				"prev_layers": mesh.layers,
			})
		if meshes.is_empty():
			return
		if screen_outline:
			# 屏幕空间模式：**只把网格挂到遮罩层**，材质一点不动。
			# 遮罩图里就只剩"被探测到的物体"，花草（没有碰撞体、探测不到）自然不在其中。
			if mask_by_objects:
				for item in meshes:
					(item["mi"] as MeshInstance3D).layers |= MASK_LAYER
			entry = {"node": visual, "meshes": meshes, "pulse": pulse}
		else:
			var hull := _make_outline_material()
			for item in meshes:
				var mesh := item["mi"] as MeshInstance3D
				# ★ 只加 overlay，**不动物体自己的材质**：物体保持原样，只在外缘多一圈线。
				#   内部由描边着色器查深度纹理 discard 掉，所以不需要遮挡填充 ——
				#   早先用"近黑不透明填充"把内部挡掉，结果整个物体变成一个大黑疙瘩，
				#   用户反馈"太丑"。现在这条路彻底不需要填充了。
				mesh.material_overlay = hull
				if ghost > 0.0:
					mesh.transparency = clampf(ghost, 0.0, 1.0)
			entry = {"node": visual, "meshes": meshes, "mat": hull, "pulse": pulse}
		_outlined[id] = entry
	# 记住**最近一次命中它的那个脉冲**：揭示范围按这个脉冲的波面算。
	# （角色移动时不同脉冲的圆心不同，用全局最大值会算错。）
	entry["pulse"] = pulse
	entry["until"] = now + outline_life


## 每帧把"波面推进到哪"写进各物体的描边材质 —— 于是线条是随波面**逐步长出来**的，
## 而不是一命中就整个物体全亮（用户报过这个）。
func _update_reveal() -> void:
	if _outlined.is_empty():
		return
	for id in _outlined.keys():
		var entry: Dictionary = _outlined[id]
		var mat = entry.get("mat")
		if mat == null or not (mat is ShaderMaterial):
			continue
		var p = entry.get("pulse")
		if p == null:
			continue
		var pd: Dictionary = p
		var c: Vector3 = pd["center"]
		# 脉冲结束后这个 dict 仍被 entry 引用着，r 停在最大值 -> 自然保持"已全部揭示"
		var r := float(pd["r"])
		(mat as ShaderMaterial).set_shader_parameter("wave_center", c)
		# + reveal_ahead：让轮廓比波面早一点点出现，消掉"在等"的延迟感
		(mat as ShaderMaterial).set_shader_parameter("wave_radius", r + reveal_ahead)


# ---------------------------------------------------------------- 屏幕空间描边
## 相机下挂一个覆盖视野的四边形当作全屏后处理面。
## size 取 4×4：相机前 1 米处、fov 45° 时可见范围约 1.5×0.83 米，4 米足够覆盖，
## 而且分辨率/宽高比变化也不用重算。
func _ensure_screen_quad() -> MeshInstance3D:
	if _screen_quad != null and is_instance_valid(_screen_quad):
		return _screen_quad
	var cam := _camera()
	if cam == null:
		return null
	var sh := load(SCREEN_OUTLINE_SHADER) as Shader
	if sh == null:
		push_warning("[DetectPulse] 缺少 detect_screen_outline.gdshader，屏幕空间描边不可用")
		return null
	var quad := QuadMesh.new()
	quad.size = Vector2(4.0, 4.0)
	var m := ShaderMaterial.new()
	m.shader = sh
	m.set_shader_parameter("line_color", line_color)
	m.set_shader_parameter("line_alpha", screen_line_alpha)
	m.set_shader_parameter("sample_px", screen_sample_px)
	m.set_shader_parameter("depth_threshold", screen_depth_threshold)
	m.set_shader_parameter("reveal_soft", reveal_soft)
	m.set_shader_parameter("wave_center", Vector3.ZERO)
	m.set_shader_parameter("wave_radius", 0.0)
	var mi := MeshInstance3D.new()
	mi.name = "DetectScreenOutline"
	mi.mesh = quad
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 这个面是"贴脸"的，别让视锥剔除把它裁掉
	mi.extra_cull_margin = 100.0
	mi.visible = false
	cam.add_child(mi)
	mi.position = Vector3(0.0, 0.0, -1.0)
	_screen_quad = mi
	return mi


## 只有真的有波纹在飞时才打开这个 pass，其余时间整块隐藏（零开销）
func _update_screen_outline() -> void:
	if not screen_outline:
		return
	var mi := _ensure_screen_quad()
	if mi == null:
		return
	var newest: Dictionary = {}
	var best := -1.0
	for p in _pulses:
		var pd: Dictionary = p
		if float(pd["r"]) > best:
			best = float(pd["r"])
			newest = pd
	if newest.is_empty():
		mi.visible = false
		return
	mi.visible = true
	var m := mi.material_override as ShaderMaterial
	if m == null:
		return
	m.set_shader_parameter("wave_center", newest["center"])
	# + reveal_ahead：轮廓比波面早一点出现（消延迟感），见 reveal_ahead 的注释
	m.set_shader_parameter("wave_radius", float(newest["r"]) + reveal_ahead)
	var vp := get_viewport()
	if vp != null:
		m.set_shader_parameter("screen_size", vp.get_visible_rect().size)
	# 物体遮罩：把"只有被探测物体"的那张图交给描边着色器
	if mask_by_objects and _ensure_mask_pass():
		_sync_mask_camera()
		m.set_shader_parameter("mask_tex", _mask_vp.get_texture())
		m.set_shader_parameter("mask_enabled", true)
	else:
		m.set_shader_parameter("mask_enabled", false)
	# ★ 三维判定：世界包围盒。二维遮罩挡不住"物体前后方的草"（实测遮罩覆盖 34%，
	#   草照样被描），必须由像素的世界坐标判断它是否真的在物体体积内。
	var mins := PackedVector4Array()
	var maxs := PackedVector4Array()
	mins.resize(16)
	maxs.resize(16)
	for i in range(16):
		if i < _boxes.size():
			var b: Array = _boxes[i]
			var lo: Vector3 = b[0]
			var hi: Vector3 = b[1]
			mins[i] = Vector4(lo.x, lo.y, lo.z, 0.0)
			maxs[i] = Vector4(hi.x, hi.y, hi.z, 0.0)
	m.set_shader_parameter("box_min", mins)
	m.set_shader_parameter("box_max", maxs)
	m.set_shader_parameter("box_count", _boxes.size())


func _expire_outlines() -> void:
	if _outlined.is_empty():
		return
	var now := _now()
	var dead: Array = []
	for id in _outlined.keys():
		var entry: Dictionary = _outlined[id]
		if now >= float(entry.get("until", 0.0)):
			_clear_entry(entry)
			dead.append(id)
	for id in dead:
		_outlined.erase(id)


func _clear_entry(entry: Dictionary) -> void:
	for item in (entry.get("meshes", []) as Array):
		var mi = item.get("mi")
		if mi != null and is_instance_valid(mi):
			var mesh := mi as MeshInstance3D
			mesh.material_overlay = item.get("prev_overlay")
			mesh.transparency = float(item.get("prev_transparency", 0.0))
			# 遮罩层必须摘掉：留着的话物体每帧都会被多渲染一次（白白多一份开销）
			if mask_by_objects and item.has("prev_layers"):
				mesh.layers = int(item["prev_layers"])
	entry["meshes"] = []


## 术法被换掉/释放时必须还原，否则场景里会留下一堆只剩线稿的物体
func _exit_tree() -> void:
	for id in _outlined.keys():
		_clear_entry(_outlined[id])
	_outlined.clear()
	for p in _pulses:
		var n = (p as Dictionary).get("ripple")
		if n != null and is_instance_valid(n):
			(n as Node).queue_free()
	_pulses.clear()
	# ★ 全屏面挂在**相机**下，不是本节点的子节点 —— 不显式回收就会永久留在相机上
	if _screen_quad != null and is_instance_valid(_screen_quad):
		_screen_quad.queue_free()
		_screen_quad = null
	if _mask_vp != null and is_instance_valid(_mask_vp):
		_mask_vp.queue_free()
		_mask_vp = null
		_mask_cam = null


# ---------------------------------------------------------------- 小工具
func _now() -> float:
	return _clock


func _camera() -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null


## 默认沿用玩家自己的碰撞掩码："玩家会撞到什么，波纹就能探到什么"。
## 写死层号的话，以后加一层碰撞体就会出现"波纹穿墙而过"。
func _mask() -> int:
	if detect_mask != 0:
		return detect_mask
	if _player is CollisionObject3D:
		return (_player as CollisionObject3D).collision_mask
	return 0xFFFFFFFF


func _visible_meshes(node: Node) -> Array:
	var out: Array = []
	var stack: Array = [node]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).visible:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## 描边材质（作为 material_overlay；内部由着色器按深度丢弃）
func _make_outline_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := load(OUTLINE_SHADER) as Shader
	if sh == null:
		push_warning("[DetectPulse] 缺少 detect_outline.gdshader，描边不会显示")
		return m
	m.shader = sh
	m.set_shader_parameter("line_color", line_color)
	m.set_shader_parameter("line_grow", line_grow)
	m.set_shader_parameter("depth_bias", depth_bias)
	m.set_shader_parameter("reveal_soft", reveal_soft)
	# 波面参数由 _update_reveal() 每帧刷新（每个物体用**命中它的那个脉冲**，
	# 而不是全局最大值 —— 角色移动时不同脉冲的圆心不一样）
	m.set_shader_parameter("wave_center", Vector3.ZERO)
	m.set_shader_parameter("wave_radius", 0.0)
	return m


## 地面波纹：一块**平面** + 着色器按径向距离画一圈圈细线。
##
## 不再用实体圆环（torus）：管子粗（看着像厚带子而不是线）、贴地的圆环在起伏地形上
## 会被埋掉、而且一次只能有一道环，没有"波纹"的层叠震荡感。
## 平面尺寸取 2×max_r，UV 天然铺满，径向距离就是半径 —— 恒为正圆。
func _make_ripple(max_r: float) -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * maxf(1.0, max_r * 2.0)
	var m := ShaderMaterial.new()
	var sh := load(RIPPLE_SHADER) as Shader
	if sh == null:
		push_warning("[DetectPulse] 缺少 detect_ripple.gdshader，波纹不会显示")
	else:
		m.shader = sh
		m.set_shader_parameter("wave_color", wave_color)
		m.set_shader_parameter("max_radius", max_r)
		m.set_shader_parameter("progress", 0.0)
		m.set_shader_parameter("wavelength", wavelength)
		m.set_shader_parameter("sharpness", sharpness)
		m.set_shader_parameter("decay", decay)
		m.set_shader_parameter("intensity", wave_intensity)
		m.set_shader_parameter("warp", wave_warp)
		m.set_shader_parameter("lead_width", lead_width)
		m.set_shader_parameter("lead_gain", lead_gain)
	var mi := MeshInstance3D.new()
	mi.name = "Ripple"
	mi.mesh = plane
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

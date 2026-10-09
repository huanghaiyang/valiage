extends Node
## 草的风 + 交互桥（自动加载为 Wind）。
##
## 统一管理三种草：
##   1) 本插件导出的草      -> blend_alpha.gdshader    （uniform: wind_* / player_*）
##   2) SimpleGrassTextured -> grass.gdshaderinc       （uniform: sgt_wind_* / sgt_player_*）
##   3) 植被（树/灌木）      -> 由 Weather 自己驱动，本脚本不碰
##
## ★★ 为什么全部走「逐材质 uniform」，而不用全局着色器参数 ★★
##   scripts/world/weather.gd L191-194 与 assets/shaders/vegetation_wind.gdshader L14 已实测写明：
##   Godot 4.7 运行时下 RenderingServer.global_shader_parameter_* 是坏的 ——
##   get_list() 恒为空、set() 被静默忽略、顶点阶段永远拿 project.godot 的默认值。
##
## ★★ 为什么本脚本自己写风参数，而不是只挂给 Weather ★★
##   Weather.bind_world() 里有 _wind_materials.clear()（weather.gd L100），
##   而 main.gd 是「世界搭好之后」才调 bind_world 的 —— 早先注册进去的草材质会被清掉，
##   表现就是「按 V 换天气，草一点反应都没有」。所以这里每帧自己写，不依赖那个列表。
##
## ★★ 2026-10-08 修复：SGT 草不受风 ✗ ★★
##   材质收集原来只判 `n is MeshInstance3D` ✓
##   但 **MultiMeshInstance3D 不是 MeshInstance3D 的子类** ✗（Godot 4 两条独立继承链）
##   → SimpleGrassTextured 的整片草从来没被收进 _mats_sgt ✓
##   → _write_sgt() 里 `if _mats_sgt.is_empty(): return` 每帧直接返回 ✗
##   → 表现：「simplegrass 的草不受风力影响」✓
##   现在补了 `elif n is MultiMeshInstance3D` → _take_from_multimesh() ✓
##   注意该分支**不能**用 MeshInstance3D 的 API ✗（MultiMeshInstance3D 没有
##   `mesh` 属性 ✓ 网格在 `multimesh.mesh`；也没有 `get_surface_override_material()` ✓）
##
## ★★ 倒伏只由「移动」驱动 ★★
##   站着不动时 player_move = 0 -> 草自动回弹，不会出现「出生点周围一圈草一直倒着」。

@export var enabled := true
## 玩家节点。留空会自动找（分组 "player" -> 按名字含 player 的节点）
@export var player_path: NodePath
@export var player_radius := 0.75      ## 踩踏影响半径
@export var player_bend := 0.55        ## 下压强度
@export var player_spread := 0.30      ## 左右分开力度
@export var move_ref_speed := 3.0      ## 多少米/秒算全速（超过按满算）
## ★ 站着不动时也**持续保持**的一个分开量：身体把草撑开着，不会完全回弹
@export var stand_bend := 0.35
## ★ 站着时把影响半径缩小到多少（只影响紧贴身体那一圈，走路时恢复全半径）
@export var stand_radius_scale := 0.60
@export var move_smooth := 8.0         ## 移动量的平滑速度（越大越跟手）
## 找不到 Weather 时的兜底风
@export var fallback_wind := 0.18
@export var fallback_gust := 0.15
@export var fallback_turbulence := 0.30
@export var fallback_speed := 1.4
@export var fallback_direction := Vector2(1.0, 0.0)
@export var scan_interval := 0.5
## ★ SGT 草的人物倒伏/分开强度（想调手感直接改这里）
##   半径：以玩家为圆心多大范围内动草（米）
##   radial：径向"分开"位移（米，叶尖量级）
##   bend：沿移动方向"倒伏"位移（米，叶尖量级）
##   debug_sgt_player：每 0.5 秒把这条链的数值打到日志（确认有没有生效）
## ★ SGT 草的人物倒伏/分开强度
##   ⚠ Wind 是**脚本型 autoload**（[autoload] Wind="*res://scripts/wind.gd"），
##     编辑器场景树里没有节点 → @export 在 Inspector 里看不到。
##     所以这些参数以**项目设置**为准：项目设置 → Wind → SGT 草人物交互，改完立即生效。
##     （@export 仍保留，作为代码里的默认值 / 供测试直接 new 出来用）
@export var sgt_player_bend_radius := 1.4        ## 影响半径（米）
@export var sgt_player_radial := 1.20            ## 径向"分开"位移（米级手柄）
@export var sgt_player_bend := 1.00              ## 沿移动方向"倒伏"位移（米级手柄）
@export var sgt_player_gain := 0.10              ## 位移总增益（收敛量级）
@export var debug_sgt_player := true             ## 移动时每秒打一条日志（确认链路用）
## ★★ 本项目改动：角色被草遮挡时的 1px 褐色轮廓
##   enable：总开关 ｜ px：轮廓宽度（像素）｜ height：角色高度（米，用于估算屏幕半径）
@export var sgt_occlusion_outline := true        ## 是否启用遮挡轮廓
@export var sgt_occlusion_px := 1.0              ## 轮廓宽度（像素）
@export var sgt_occlusion_height := 1.75         ## 角色高度（米）
@export var sgt_occlusion_radius_scale := 0.30   ## 屏幕半径相对"角色屏幕高"的比例
@export var sgt_occlusion_color := Color(0.30, 0.17, 0.09, 1.0)   ## 褐色
## 每帧算好的角色屏幕量（供 _write_sgt 写入材质）
var _occl_on := 0.0
var _occl_screen := Vector2(-100000.0, -100000.0)
var _occl_radius := 0.0
var _occl_depth := 0.0
## ★ 两套尺寸都要：逻辑视口（unproject 坐标系）与帧缓冲像素（FRAGCOORD 坐标系）
var _occl_vp_logical := Vector2(1280.0, 720.0)
var _occl_vp_pixel := Vector2(1280.0, 720.0)


## ★ 当前风（供火焰/其他 VFX 读取，不必去翻材质）。每次写材质前同步更新。
var cur_dir := Vector2(1.0, 0.0)
var cur_strength := 0.18
var cur_gust := 0.15
var cur_turbulence := 0.30
var cur_speed := 1.4

var _registered := 0
var _scan_timer := 0.0
var _mats_ours: Array[ShaderMaterial] = []
var _mats_sgt: Array[ShaderMaterial] = []
var _seen := {}
var _movement := Vector3.ZERO
var _player: Node3D = null
var _player_prev := Vector3.ZERO
var _player_fwd := Vector3(0.0, 0.0, -1.0)
## 平滑后的移动量 0..1（站着不动 -> 0 -> 草回弹）
var _move_amt := 0.0
## ★ 给 SGT 草用的玩家世界坐标 + 这一帧的水平位移（逐材质写）
##   优先用 SimpleGrass.player_position（项目里若按插件文档更新过就用它），
##   没有（本项目的实际情况）就直接取 "player" 组节点的位置。
var _sgt_player_pos := Vector3(1.0e9, 1.0e9, 1.0e9)
var _sgt_player_step := Vector3.ZERO
var _sgt_player_warned := false
var _dbg_player_t := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_project_settings()
	# ★ 窗口/视口尺寸一变就重算角色屏幕量并立刻写进草材质（否则轮廓会一直按旧尺寸画）
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_size_changed):
		vp.size_changed.connect(_on_viewport_size_changed)
	_scan()


func _process(delta: float) -> void:
	if not enabled:
		return
	_scan_timer += delta
	if _scan_timer >= scan_interval:
		_scan_timer = 0.0
		_scan()
	var p := _find_player()
	var ppos := Vector3(0.0, -100000.0, 0.0)
	var pmov := Vector3.ZERO
	if p != null:
		ppos = p.global_position
		var step := ppos - _player_prev
		step.y = 0.0
		if delta > 0.0001:
			var spd := step.length() / delta
			var target := clampf(spd / maxf(0.01, move_ref_speed), 0.0, 1.0)
			# 指数平滑：起步和停下都有过渡，不会"啪"地弹开/回正
			_move_amt = lerpf(_move_amt, target, clampf(delta * move_smooth, 0.0, 1.0))
		else:
			_move_amt = 0.0
		if not step.is_zero_approx():
			# 朝向优先用**速度方向**（更符合"往前走时草往两边分开"）
			var vf := step.normalized()
			_player_fwd = _player_fwd.lerp(vf, clampf(delta * 8.0, 0.0, 1.0)).normalized()
		pmov = step.limit_length(1.0)
		_player_prev = ppos
	else:
		_move_amt = lerpf(_move_amt, 0.0, clampf(delta * move_smooth, 0.0, 1.0))
	# ★ SGT 草的人物倒伏：位置 + 这一帧的水平位移（逐材质写，见 _write_sgt）
	_update_sgt_player(delta, p, ppos)
	# 天气
	var w: Node = null
	if get_tree() != null:
		w = get_tree().root.get_node_or_null("Weather")
	if w != null:
		_apply_from_weather(w, delta, ppos, pmov)
	else:
		_apply_fallback(ppos, pmov)


# ---------------------------------------------------------------- 材质收集

func _scan() -> void:
	if get_tree() == null:
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var found := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		# ★★ 修复：MultiMeshInstance3D **不是** MeshInstance3D 的子类 ✗
		#   SimpleGrassTextured 的草用的是 MultiMeshInstance3D ✓
		#   → 之前只判 `is MeshInstance3D` ✓ → SGT 草永远不被收集 ✗
		#   → `_write_sgt()` 里 `if _mats_sgt.is_empty(): return` 每帧直接返回 ✗
		#   → 表现就是「simplegrass 的草不受风力影响」✓✓
		if n is MeshInstance3D:
			found += _take_from_mesh(n as MeshInstance3D)
		elif n is MultiMeshInstance3D:
			found += _take_from_multimesh(n as MultiMeshInstance3D)
		for c in n.get_children():
			stack.append(c)
	if found > 0:
		print("[Wind] 新增 %d 个受风材质（累计 %d ｜ SGT %d）" % [found, _registered, _mats_sgt.size()])


## ★ 收集 MultiMeshInstance3D（SimpleGrassTextured 的整片草）的受风材质。
##   ★ MultiMeshInstance3D 与 MeshInstance3D 不是同一条继承链 ✗ 可用 API 也不同：
##     - 没有 `mesh` 属性 ✓ 网格在 `multimesh.mesh` ✓
##     - 没有 `get_surface_override_material()` ✓（那是 MeshInstance3D 的 ✓）
##     所以这里只用「节点 material_override + multimesh.mesh 自带 surface 材质」✓
func _take_from_multimesh(mmi: MultiMeshInstance3D) -> int:
	var got := 0
	var target_mesh: Mesh = null
	if mmi.multimesh != null:
		target_mesh = mmi.multimesh.mesh
	var mh: float = 0.0
	if target_mesh != null and target_mesh.get_surface_count() > 0:
		mh = mmi.get_aabb().size.y
	if mmi.material_override is ShaderMaterial:
		got += _register_h(mmi.material_override as ShaderMaterial, mh)
	if target_mesh != null:
		for s in range(target_mesh.get_surface_count()):
			var sm: Material = target_mesh.surface_get_material(s)
			if sm is ShaderMaterial:
				got += _register_h(sm as ShaderMaterial, mh)
	return got


func _take_from_mesh(mi: MeshInstance3D) -> int:
	var got := 0
	# ★★★ 模型**实际渲染高度**（用户要求 ✓）
	#   `get_aabb()` 给的是**世界空间**包围盒 ✓（已含节点缩放 ✓ 不含父级动画的另一层 ✗）
	#   → size.y 就是它在画面里占据的真实高度（米 ✓）
	#   → 注册成功时写进 `wind_height_ref` ✓
	#     让 shader 的高度权重用**真实高度**，而不是我在材质里手填的常数 ✓
	var mh: float = 0.0
	if mi.mesh != null:
		mh = mi.get_aabb().size.y
	if mi.material_override is ShaderMaterial:
		got += _register_h(mi.material_override as ShaderMaterial, mh)
	if mi.mesh != null:
		for s in range(mi.mesh.get_surface_count()):
			var ov: Material = mi.get_surface_override_material(s)
			if ov is ShaderMaterial:
				got += _register_h(ov as ShaderMaterial, mh)
			var sm: Material = mi.mesh.surface_get_material(s)
			if sm is ShaderMaterial:
				got += _register_h(sm as ShaderMaterial, mh)
	return got


## ★★★ 注册 + 写入**该网格的实际渲染高度**（用户要求 ✓）
##   草 / 叶 / 木三个 shader 的高度 uniform 都叫 `wind_height_ref` ✓
##   （写到不存在的 uniform 上是无害的 ✓ → 对 SGT 等其它 shader 也安全 ✓）
func _register_h(m: ShaderMaterial, h: float) -> int:
	var got := _register(m)
	if got > 0 and m != null and h > 0.0001:
		m.set_shader_parameter("wind_height_ref", h)
		var nm := "?"
		if m.shader != null:
			nm = String(m.shader.resource_path.get_file())
		print("[Wind] 实际高度 ✓ %s ｜ %.3f 米 → wind_height_ref" % [nm, h])
	return got


func _register(m: ShaderMaterial) -> int:
	if m == null or m.shader == null:
		return 0
	var path := String(m.shader.resource_path)
	# 我们的草：shader 现在住在 assets/shaders/grass_wind.gdshader（blend_alpha 是旧名，兼容保留）
	# ★★ 追加（用户反馈 ✓）：**燃烧后的树叶** 用的是 `tree_leaves_burn*.gdshader` ✗
	#   它的路径不含 `grass_wind` ✗ → 之前**不被注册** → 叶子换成燃烧材质后就**不受风** ✓✓
	#   （`tree_burn_keep*` 是木质 ✓ sway_amt=0 ✓ 注册也无位移 ✓ 一并纳入便于统一管理 ✓）
	var is_ours := path.contains("grass_wind") or path.contains("blend_alpha") \
			or path.contains("tree_leaves_burn") or path.contains("tree_burn_keep")
	var is_sgt := path.contains("simplegrasstextured")
	if not (is_ours or is_sgt):
		return 0
	var id := m.get_instance_id()
	if _seen.has(id):
		return 0
	_seen[id] = true
	if is_sgt:
		_mats_sgt.append(m)
	else:
		_mats_ours.append(m)
	_registered += 1
	return 1


# ---------------------------------------------------------------- 玩家

func _find_player() -> Node3D:
	if _player != null and is_instance_valid(_player):
		return _player
	if get_tree() == null:
		return null
	if not player_path.is_empty():
		var n := get_node_or_null(player_path)
		if n is Node3D:
			_player = n
			_player_prev = _player.global_position
			_player_fwd = -_player.global_transform.basis.z
			_player_fwd.y = 0.0
			_player_fwd = _player_fwd.normalized()
			return _player
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		_player = g
		_player_prev = _player.global_position
		_player_fwd = -_player.global_transform.basis.z
		_player_fwd.y = 0.0
		_player_fwd = _player_fwd.normalized()
		return _player
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n2: Node = stack.pop_back()
		if n2 == null:
			continue
		if n2 is Node3D and String(n2.name).to_lower().contains("player"):
			_player = n2 as Node3D
			_player_prev = _player.global_position
			_player_fwd = -_player.global_transform.basis.z
			_player_fwd.y = 0.0
			_player_fwd = _player_fwd.normalized()
			return _player
		for c in n2.get_children():
			stack.append(c)
	return null


# ---------------------------------------------------------------- SGT 人物倒伏

## ★ 把参数注册成项目设置（脚本型 autoload 的 @export 在 Inspector 里看不到）
##   项目设置 → Wind → sgt_player → bend_radius_m / radial / bend / gain / debug_log
##   ⚠ 键名必须用 ASCII：中文键名在 Godot 读取 project.godot 时会失配（实测 has_setting=false）。
##   中文说明走 Godot 原生的 `_doc` 前缀字段，在项目设置里会显示成说明文字。
const SGT_SET_PREFIX := "Wind/sgt_player/"
const SGT_SET_KEYS: Dictionary = {
	"bend_radius_m": "影响半径（米）：以玩家为圆心多大范围内动草",
	"radial": "径向分开（米级手柄）：以玩家为圆心往外推的力度",
	"bend": "沿移动倒伏（米级手柄）：顺着行走方向的倒伏力度（站着只剩 25%）",
	"gain": "位移总增益：最终位移 = 手柄 × 增益 × 权重(0~1)",
	"debug_log": "打印调试日志：移动时每秒输出一条链路日志",
	"occlusion_outline": "角色被草遮挡时是否描一圈褐色轮廓",
	"occlusion_px": "轮廓宽度（像素）",
	"occlusion_height": "角色高度（米）：用于估算角色的屏幕半径",
	"occlusion_radius_scale": "屏幕半径相对角色屏幕高的比例（0.3 ≈ 半个角色宽）",
}

func _ensure_project_settings() -> void:
	var defaults: Dictionary = {
		"bend_radius_m": sgt_player_bend_radius,
		"radial": sgt_player_radial,
		"bend": sgt_player_bend,
		"gain": sgt_player_gain,
		"debug_log": debug_sgt_player,
		"occlusion_outline": sgt_occlusion_outline,
		"occlusion_px": sgt_occlusion_px,
		"occlusion_height": sgt_occlusion_height,
		"occlusion_radius_scale": sgt_occlusion_radius_scale,
	}
	for k in defaults:
		var key: String = SGT_SET_PREFIX + String(k)
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, defaults[k])
		var doc: String = key + "_doc"
		if not ProjectSettings.has_setting(doc):
			ProjectSettings.set_setting(doc, String(SGT_SET_KEYS.get(k, "")))


## 读一条设置（传短键名，如 "radial"；没有 / 类型不对就退回 @export 默认值）
## ★ 必须逐类型判断：ProjectSettings 里可能存着非数值，
##   直接 float(x) 会抛 "Nonexistent 'float' constructor" 并且每帧刷屏。
func _sgt_setting(short_key: String, fallback: Variant) -> Variant:
	var key := SGT_SET_PREFIX + short_key
	if not ProjectSettings.has_setting(key):
		return fallback
	var v: Variant = ProjectSettings.get_setting(key)
	if v is float or v is int:
		return v
	if v is bool:
		return v
	if v is String or v is StringName:
		var s := String(v).strip_edges()
		if s.is_valid_float():
			return s.to_float()
	# 类型不认识：退回默认值，不再尝试构造函数转换
	return fallback


## 从设置里取一个数字（内部用，绝不做危险的构造转换）
func _sgt_num(short_key: String, fallback: float) -> float:
	var v: Variant = _sgt_setting(short_key, fallback)
	if v is float or v is int:
		return float(v)
	return fallback


## 从设置里取一个开关（内部用）
func _sgt_bool(short_key: String, fallback: bool) -> bool:
	var v: Variant = _sgt_setting(short_key, fallback)
	if v is bool:
		return v
	if v is float or v is int:
		return float(v) != 0.0
	return fallback


## ★ SGT 草的人物倒伏参数：玩家世界坐标 + 每帧水平位移
##   位置优先取 SimpleGrass.player_position（插件文档推荐项目每帧调 set_player_position），
##   但本项目 game/player 脚本并没有调它 -> 兜底直接读 "player" 组节点的 global_position。
##   位移用位置差分得到；大于 1.5 米视为传送/初始化，不给推力（避免一瞬间把草吹平）。
func _update_sgt_player(_delta: float, p: Node3D, ppos: Vector3) -> void:
	var pos := Vector3(1.0e9, 1.0e9, 1.0e9)
	var sg: Node = null
	if get_tree() != null:
		sg = get_tree().root.get_node_or_null("SimpleGrass")
	if sg != null:
		var v: Variant = sg.get("player_position")
		if v is Vector3 and (v as Vector3).length() > 1.0:
			pos = v as Vector3
	var using_group := false
	if pos.x > 1.0e8 and p != null:
		pos = ppos
		using_group = true
		if not _sgt_player_warned:
			_sgt_player_warned = true
			print("[Wind] SGT 草人物倒伏：改用 \"player\" 组节点的位置（项目未调用 SimpleGrass.set_player_position）")
	var step := pos - _sgt_player_pos
	step.y = 0.0
	if step.length() > 1.5:
		step = Vector3.ZERO    # 跳变
	_sgt_player_pos = pos
	_sgt_player_step = step
	if using_group and p == null:
		# 连玩家都找不到：把影响半径清零，别让草整片朝一个假点倒
		_sgt_player_pos = Vector3(1.0e9, 1.0e9, 1.0e9)
	# ★ 顺带算"角色在屏幕上的位置/半径/视深度"，供草着色器画遮挡轮廓
	_update_screen_metrics(p)

## ★★ 本项目改动：算出角色在屏幕上的位置、半径与视空间深度。
##   草着色器用它们判断"这一像素是否属于被草挡住角色"的那一圈，从而描出 1px 褐色轮廓。
##   ⚠ 这套量**全都依赖视口尺寸**（半径是"比例"，脚本按视口像素换算），
##     所以窗口一改尺寸就必须重算并**立刻**写进材质 —— 见 _on_viewport_size_changed()。
##   每帧无条件计算（不做开关早退），关闭开关时由调用方把 _occl_on 归零。
func _update_screen_metrics(p: Node3D) -> void:
	if p == null or not is_instance_valid(p) or get_tree() == null:
		return
	var cam := get_tree().root.get_camera_3d()
	if cam == null:
		return
	var vp := cam.get_viewport()
	if vp == null:
		return
	# ★★ 两套尺寸都要，缺一不可（这是"轮廓完全看不到 / 不跟随"的根本原因）：
	#   · unproject_position() 返回的是**视口逻辑坐标**（本机 1280x720）
	#   · 着色器 FRAGCOORD 是**帧缓冲真实像素**（本机 3824x1982，比例约 2.99）
	#   只存一套，圆就会被画到错误的屏幕位置。
	var px_size := _framebuffer_pixel_size()
	var logical := Vector2(vp.get_visible_rect().size)
	if logical.x < 1.0 or logical.y < 1.0:
		logical = px_size
	if px_size.x < 1.0 or px_size.y < 1.0:
		px_size = logical
	var base := p.global_position
	var h := maxf(0.2, _sgt_num("occlusion_height", sgt_occlusion_height))
	var p_bot := cam.unproject_position(base)
	var p_top := cam.unproject_position(base + Vector3(0.0, h, 0.0))
	var h_px := (p_top - p_bot).length()
	if h_px < 0.5:
		return    # 角色几乎在相机背后 / 极远：不画
	var rscale := _sgt_num("occlusion_radius_scale", sgt_occlusion_radius_scale)
	_occl_screen = p_bot                              # 视口逻辑坐标（与 unproject 一致）
	_occl_radius = clampf(h_px * rscale, 1.0, 0.9 * logical.y)
	_occl_depth = -(cam.global_transform.affine_inverse() * (base + Vector3(0.0, h * 0.5, 0.0))).z
	_occl_vp_logical = logical
	_occl_vp_pixel = px_size
	_occl_on = 1.0


## ★ 帧缓冲真实像素尺寸（与着色器 FRAGCOORD 同坐标系）。
##   ⚠ Window 没有 get_render_target_size()（那是 Viewport 的方法，调用会直接崩到断点）。
func _framebuffer_pixel_size() -> Vector2:
	var s := Vector2(DisplayServer.window_get_size())
	if s.x < 1.0 or s.y < 1.0:
		s = Vector2(1280.0, 720.0)
	return s


## ★★ 窗口/视口尺寸变化：立即重算屏幕量并写进材质。
##   不这样做的话，轮廓会一直用**旧视口尺寸**换算（半径、像素宽度全部错位），
##   而且要等到下一次风参数写入才可能纠正 —— 草材质列表为空时更是永远不纠正。
func _on_viewport_size_changed() -> void:
	var p := _find_player()
	if p == null:
		return
	_update_screen_metrics(p)
	_apply_sgt_occlusion()
	if debug_sgt_player:
		print("[Wind] 视口尺寸变化 -> 已刷新轮廓：逻辑=%s 像素=%s 屏幕半径=%.2f 视深度=%.2f" % [
				str(_occl_vp_logical), str(_occl_vp_pixel), _occl_radius, _occl_depth])


## ★ 把"角色屏幕量 + 轮廓参数"写进所有 SGT 草材质。
##   ★ 必须**每次遍历全部材质**（不像风参数那样一帧只写一次也无所谓）：
##     resize 时会立刻调这里，不能只更新第一个材质。
func _apply_sgt_occlusion() -> void:
	var on := _occl_on
	if not _sgt_bool("occlusion_outline", sgt_occlusion_outline):
		on = 0.0
	var px := float(_sgt_num("occlusion_px", sgt_occlusion_px))
	var oc := sgt_occlusion_color
	var col := Color(oc.r, oc.g, oc.b, 1.0)
	for m in _mats_sgt:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("sgt_player_screen", _occl_screen)
		m.set_shader_parameter("sgt_player_screen_r", _occl_radius)
		m.set_shader_parameter("sgt_player_depth", _occl_depth)
		m.set_shader_parameter("sgt_occl_vp_logical", _occl_vp_logical)
		m.set_shader_parameter("sgt_occl_vp_pixel", _occl_vp_pixel)
		m.set_shader_parameter("sgt_occl_on", on)
		m.set_shader_parameter("sgt_occl_px", px)
		m.set_shader_parameter("sgt_occl_color", col)


# ---------------------------------------------------------------- 参数写入

func _apply_from_weather(w: Node, delta: float, ppos: Vector3, pmov: Vector3) -> void:
	var v: Variant = w.get("wind_dir")
	var dir2: Vector2 = v if v is Vector2 else Vector2(1.0, 0.0)
	var strength := float(w.get("wind"))
	var gust := float(w.get("wind_gust"))
	var turb := float(w.get("wind_turbulence"))
	var speed := float(w.get("wind_speed"))
	cur_dir = dir2
	cur_strength = strength
	cur_gust = gust
	cur_turbulence = turb
	cur_speed = speed
	_movement.x += dir2.x * speed * delta * 1.2
	_movement.z += dir2.y * speed * delta * 1.2
	_movement.y += delta * speed * 0.6
	_write_ours(dir2, strength, gust, turb, speed, ppos)
	_write_sgt(dir2, strength, gust, turb, ppos, pmov)


func _apply_fallback(ppos: Vector3, pmov: Vector3) -> void:
	var d := fallback_direction.normalized()
	cur_dir = d
	cur_strength = fallback_wind
	cur_gust = fallback_gust
	cur_turbulence = fallback_turbulence
	cur_speed = fallback_speed
	_movement.x += d.x * fallback_speed * 0.02
	_movement.z += d.y * fallback_speed * 0.02
	_write_ours(d, fallback_wind, fallback_gust, fallback_turbulence, fallback_speed, ppos)
	_write_sgt(d, fallback_wind, fallback_gust, fallback_turbulence, ppos, pmov)


## 我们导出的草：风参数 + 角色倒伏（自己写，不依赖 Weather 的材质列表）
func _write_ours(dir2: Vector2, strength: float, gust: float, turb: float, speed: float, ppos: Vector3) -> void:
	for m in _mats_ours:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("wind_direction", dir2)
		m.set_shader_parameter("wind_strength", strength)
		m.set_shader_parameter("wind_gust", gust)
		m.set_shader_parameter("wind_speed", speed)
		m.set_shader_parameter("wind_turbulence", turb)
		m.set_shader_parameter("player_pos", ppos)
		m.set_shader_parameter("player_forward", _player_fwd)
		m.set_shader_parameter("player_radius", player_radius)
		m.set_shader_parameter("player_bend", player_bend)
		m.set_shader_parameter("player_spread", player_spread)
		# ★ 站着也保持分开：取「站立基础量」和「移动量」的较大者
		var bend_amt := maxf(stand_bend, _move_amt)
		m.set_shader_parameter("player_move", bend_amt)
		# 站着时半径收小（只撑开贴身那一圈），走起来恢复全半径
		m.set_shader_parameter("player_radius", player_radius * lerpf(stand_radius_scale, 1.0, _move_amt))


## SimpleGrassTextured 的草：它自己的 singleton 写的是全局（运行时失效）-> 这里补上
##   ★ 2026-10-08：玩家倒伏/分开也走这条链（逐材质）；着色器里的 uniform 名见
##     addons/simplegrasstextured/shaders/grass.gdshaderinc 的 sgt_player_pos / _bend / _radial
func _write_sgt(dir2: Vector2, strength: float, gust: float, turb: float, ppos: Vector3, pmov: Vector3) -> void:
	if _mats_sgt.is_empty():
		return
	var dir3 := Vector3(dir2.x, 0.0, dir2.y).normalized()
	for m in _mats_sgt:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("sgt_wind_direction", dir3)
		m.set_shader_parameter("sgt_wind_strength", strength * (1.0 + gust))
		m.set_shader_parameter("sgt_wind_turbulence", turb)
		m.set_shader_parameter("sgt_wind_movement", _movement)
		# 玩家（倒伏 + 分开）：位置 + 这一帧的水平位移
	# 强度从**项目设置**实时读取（Wind/sgt_player/*），改完立刻生效，不必重启编辑器
		var p_radius := _sgt_num("bend_radius_m", sgt_player_bend_radius)
		var p_radial := _sgt_num("radial", sgt_player_radial)
		var p_bend := _sgt_num("bend", sgt_player_bend)
		var p_gain := _sgt_num("gain", sgt_player_gain)
		m.set_shader_parameter("sgt_player_pos", _sgt_player_pos)
		m.set_shader_parameter("sgt_player_mov", _sgt_player_step)
		# 走着时倒伏明显、站着时基本回弹（避免出生点一圈草永远是倒的）
		m.set_shader_parameter("sgt_player_bend", p_bend * lerpf(0.25, 1.0, _move_amt))
		m.set_shader_parameter("sgt_player_radial", p_radial)
		m.set_shader_parameter("sgt_player_bend_radius", p_radius)
		m.set_shader_parameter("sgt_player_gain", p_gain)
	# ★ 角色被草遮挡时的 1px 褐色轮廓（屏幕量在 _update_screen_metrics 里算好）
	#   写成独立函数：窗口尺寸变化时要能"立刻"重写全部材质，而不是等下一次风参数更新
	_apply_sgt_occlusion()
	# ★ 诊断台账（打印调试日志 打开时）：只在"确实在动"且每秒最多一次时打出来
	if not _sgt_bool("debug_log", debug_sgt_player):
		return
	_dbg_player_t += get_process_delta_time()
	if _dbg_player_t > 1.0:
		_dbg_player_t = 0.0
		var step_len := _sgt_player_step.length()
		if step_len > 0.002:
			print("[Wind] SGT 人物倒伏: 材质 %d 个 ｜ 玩家 %s ｜ 位移 %.3f ｜ radius=%.2f radial=%.2f bend=%.2f" % [
					_mats_sgt.size(), str(_sgt_player_pos), step_len,
					_sgt_num("bend_radius_m", sgt_player_bend_radius),
					_sgt_num("radial", sgt_player_radial),
					_sgt_num("bend", sgt_player_bend)
					* lerpf(0.25, 1.0, _move_amt)])

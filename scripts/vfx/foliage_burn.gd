extends Node3D
## 植被燃烧控制器 —— 把「burn_foliage」材质贴到一株花草树木上，并跑完整段燃烧：
##   ① 斑点扩大（burn 0->1）② 焦黑停留 ③ 灰化消失（ash 0->1，然后隐藏）
##
## ★ 火星为什么从**表面**出来：火星的起点是从这株模型的**真实顶点**里采样出来的
##   （不是用一个包围盒随机撒点）。所以火只在枝叶表面上生出来，不会凭空飘在空处。
##
## ★ 摆动靠材质里的 vertex()（按高度加权的双频横向位移，每株 phase 不同），
##   所以必须用 material_override 接管外观 —— 用 overlay 的话几何体不会动。
##
## 用法：
##   var b := load("res://scripts/vfx/foliage_burn.gd").new()
##   get_parent().add_child(b)      # 放到场景里
##   b.burn_node(plant_node)        # 点着它

const SHADER := "res://assets/shaders/burn_foliage.gdshader"
const NOISE := "res://assets/textures/法术特效/Noise1_tiled.png"

@export var burn_time := 7.0          ## 斑点扩大所需时间（草/花用 ✓ 用户要求：草可以快 ✓）
@export var burn_time_tree := 18.0    ## ★ 树的燃烧全程（用户定稿 ✓）：**18 秒**
									  ##   （此前 26→52 太慢 ✓ 导致"树干还没烧到中间，树叶都烧完了"✗）
									  ##   判据：材质带 `burn_mode == "wood"`（插件写的 ✓）
									  ##   或 shader 是 tree_burn_keep* ✓ → 走这个时长 ✓
@export var ash_time_tree := 8.0      ## ★ 树烧完后的消失时长（同样更慢 ✓）
@export var char_hold := 0.7          ## 全焦黑后停留
@export var ash_time := 3.3           ## 缩到消失所需时间（用户要求：原来 1.1 秒 ×3）
## ★ 烧透之后多久长回来（秒）。0 = 永久烧毁（不再恢复）。
##   消失与长回都走**缩放**（scale），过程中保持焦黑。
##   ★ 必须**大于火焰本身的时长**：单株草约 6.4 秒烧完（burn 2.4 + 保持 0.7 + 消失 3.3），
##     而「火焰灼烧」整体约 9.55 秒。原来设 8 秒 -> 火还在烧、草就开始长回来
##     （实测：火里长草）。所以默认给 18 秒，等火灭了再慢慢恢复。
@export var regrow_time := 18.0       ## 烧毁后"缓缓长回来"的时长（见 _process 里的 regrow 逻辑 ✓）
@export var spark_count := 18         ## 火星数量
@export var spark_lifetime := 1.1
@export var spark_size := 0.03
## 摆动幅度（米，逐株再随机一次）——"类似不规则风动"
@export var sway_amt := 0.075
## 摆动频率（逐株 phase 不同，两频叠加）
@export var sway_freq := 1.8
## 燃烧斑点噪声的世界尺度（越大斑点越碎）
@export var noise_scale := 1.4
## ★ 是否接管原生材质。**默认 false（用 material_overlay）**：
##   接管会丢掉草的自定义着色器/透明裁剪，草片会变成不透明方块（观感=模型变大）。
##   需要"几何体真的摆动"时才开；开启后外观由本着色器决定。
@export var use_override := false
## 逐目标打印"材质透明度 / 是否拿到贴图 / 最终决定"——用来排查"某个物体烧得不对"
@export var debug_burn := true
## ★ 是否允许烧 MultiMesh（addon 的**整片**草）。
##   默认 **false**：MultiMesh 是一个节点覆盖一大片/全图，材质是整节点共享的，
##   整体烧会把**整张地图的草**一起涂黑（实测截图：全图草地全黑 + 红边）。
##   正确做法是"逐实例燃烧"（INSTANCE_CUSTOM），尚未实现 -> 先关掉。
@export var burn_multimesh := true

var _target: Node3D = null
var _meshes: Array[MeshInstance3D] = []
var _multimeshes: Array[MultiMeshInstance3D] = []   ## addon 的草丛是 MultiMesh 节点
var _prev_override: Array = []
var _mat: ShaderMaterial = null
var _shader_mats: Array[ShaderMaterial] = []
## ★ 逐实例燃烧：要烧的 MultiMesh 实例列表 [{mmi, i, phase, delay, done}]
## ★ 风系统每帧只写**它自己收集的材质**（scripts/wind.gd 的 _mats_ours/_mats_sgt）；
##   我们为燃烧**复制**出来的材质不在名单里 -> 烧起来的草会停止摆动。
##   所以每帧把风参数从**原材质**抄到副本上（原材质一直由风系统更新，抄过来就是实时的）。
const WIND_PARAMS := [
	"wind_direction", "wind_strength", "wind_gust", "wind_speed", "wind_turbulence",
	"player_pos", "player_forward", "player_radius", "player_bend", "player_spread",
	"player_move",
	"sgt_wind_direction", "sgt_wind_strength", "sgt_wind_turbulence", "sgt_wind_movement",
	"sgt_player_position", "sgt_player_mov",
	# ★ 2026-10-08：SGT 草的人物倒伏/分开也是逐材质 uniform（改见 grass.gdshaderinc）
	"sgt_player_pos", "sgt_player_mov", "sgt_player_bend", "sgt_player_radial", "sgt_player_bend_radius",
]
## 与 _shader_mats 一一对应的"原材质"（风参数的来源）
var _shader_src: Array[ShaderMaterial] = []

var _mm_burn: Array = []
var _reported := false            ## 1 秒的状态汇报只打一次
## 被我们打开 use_custom_data 的 MultiMesh（收尾时还原，避免改动 addon 的内存布局）
var _mm_custom_on: Array = []
## 由法术在点燃前设置：只烧这个圆内的实例（0 半径 = 不筛）
var burn_center := Vector3.ZERO
var burn_radius := 0.0
## ★ 法术已经用"先按块、再查块内"算好的实例表（省掉控制器再全量扫一遍）
var preset_mm: MultiMeshInstance3D = null
var preset_indices: Array = []
## ★ 每实例的**点燃延迟**（秒，与 preset_indices 一一对应）。空 = 用随机错开。
##   火焰推进靠它让草按"离角色的距离"依次烧起来（波前），而不是整片一起黑。
var preset_delays: Array = []
var _t := 0.0
var _done := false
var _phase := 0.0

# 火星（MultiMesh + 自己驱动：数量少、需要精确落在表面上）
var _sparks: MultiMeshInstance3D = null
var _sp := PackedVector3Array()       ## 位置（本节点局部坐标）
var _sv := PackedVector3Array()       ## 速度
var _sl := PackedFloat32Array()       ## 剩余寿命
var _surface := PackedVector3Array()  ## 表面点池（取自真实顶点）
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	set_process(false)
	_rng.randomize()


## 点着一株植被。返回是否成功（找不到网格就失败）
func burn_node(n: Node3D, delay: float = 0.0) -> bool:
	# ★★ 按目标分档燃烧时长（用户要求 ✓）：**草可以快 ✓ 树要慢慢慢 ✓**
	#   判据复用 `_target_is_keep()` ✓：材质带 `burn_mode == "wood"` ✓（插件写的 ✓）
	#   或 shader 是 `tree_burn_keep*` ✓ → 走 burn_time_tree / ash_time_tree ✓
	#   （草是 MultiMesh ✓ 判据返回 false ✓ → 保持 burn_time 快节奏 ✓）
	_target = n
	# ★★ 防重入（修复"树枝闪烁"✗）：同一目标**已有燃烧在跑**时直接跳过 ✓
	#   重复施法会在同一棵树上叠加多个燃烧器 ✓ → 每帧互相覆盖 burn/ash → **闪烁** ✓✓
	if n != null and n.has_meta("burning"):
		print("[燃烧] 该目标已在燃烧中 ✓ 跳过重复点燃：%s" % n.name)
		return false
	# ★★★ 已烧毁（用户要求 ✓）：**直接跳过** ✗ 不再播一遍燃烧 ✓
	#   为什么要跳 ✗：第二次施法会**从网格原始材质重新复制一份** ✓（burn=0 ✓）
	#   → 看上去"树叶树枝树干又还原了" ✓✓（用户实测 ✓）
	#   跳过之后，节点上仍挂着第一次冻结好的焦黑材质 ✓ → **保持焦黑** ✓✓
	#   状态记在节点 meta 上 ✓（本次运行内有效 ✓ 场景重载会重置 ✓ 需要持久化再说 ✓）
	if n != null and n.has_meta("burned_out"):
		print("[燃烧] 该目标**已烧毁** ✓ 不再燃烧（保持焦黑）：%s" % n.name)
		return false
	if n != null:
		n.set_meta("burning", true)
	if _target_is_keep():
		burn_time = burn_time_tree
		ash_time = ash_time_tree
		print("[燃烧] 树/木质 ✓ 时长 = %.1fs（烧）+ %.1fs（消失）｜ %s" % [
				burn_time, ash_time, n.name])
	if n == null or not is_instance_valid(n):
		return false
	_target = n
	_meshes.clear()
	_multimeshes.clear()
	var st := [n]
	while st.size() > 0:
		var cur: Node = st.pop_back()
		if cur is MeshInstance3D:
			_meshes.append(cur)
		elif cur is MultiMeshInstance3D:
			# ★ addons/simplegrasstextured 的 grass.gd 就是 MultiMeshInstance3D：
			#   整片草丛是一个节点，材质也是整体接管（摆动按实例作用）。
			_multimeshes.append(cur)
		for c in cur.get_children():
			st.append(c)
	if _meshes.is_empty() and _multimeshes.is_empty():
		return false
	if not _multimeshes.is_empty() and _meshes.is_empty():
		if not burn_multimesh:
			if debug_burn:
				print("[植被燃烧] %s 跳过：burn_multimesh 关闭" % n.name)
			return false
		# ★ 逐实例燃烧：整片草是一个节点，但**每个实例单独一份进度**（INSTANCE_CUSTOM），
		#   所以只有圈内的那几簇会烧，不会把全图草一起涂黑。
		_meshes.clear()
		global_position = Vector3.ZERO
		if not _start_multimesh_burn():
			if debug_burn:
				print("[植被燃烧] %s 跳过：找不到支持 INSTANCE_CUSTOM 的草材质" % n.name)
			return false
		_collect_surface_points()
		_build_sparks()
		set_process(true)
		if debug_burn:
			print("[植被燃烧] %s | 走**逐实例燃烧**（INSTANCE_CUSTOM）：%d 个实例在圈内"
					% [n.name, _mm_burn.size()])
		return true
	_phase = _rng.randf() * TAU
	# 量一下这株的高度/范围：给摆动做高度加权、给火星找表面
	var lo := 1e9
	var hi := -1e9
	for mi in _meshes:
		if mi.mesh == null:
			continue
		var aabb := mi.mesh.get_aabb()
		var xf := mi.global_transform
		for i in range(8):
			var c2 := aabb.position + Vector3(
					aabb.size.x if (i & 1) != 0 else 0.0,
					aabb.size.y if (i & 2) != 0 else 0.0,
					aabb.size.z if (i & 4) != 0 else 0.0)
			var w := xf * c2
			lo = minf(lo, w.y)
			hi = maxf(hi, w.y)
	for mmi in _multimeshes:
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		# 整片草：用基础网格高度做摆动加权即可（逐实例高度加权意义不大）
		var ma := mmi.multimesh.mesh.get_aabb()
		var mx := mmi.global_transform
		lo = minf(lo, (mx * Vector3(ma.position.x, ma.position.y, ma.position.z)).y)
		hi = maxf(hi, (mx * (ma.position + ma.size)).y)
	if hi < lo:
		lo = 0.0
		hi = 1.0
	var height := maxf(hi - lo, 0.2)
	# ★ 若目标材质用的着色器**自带 burn**（如 assets/shaders/vegetation_wind.gdshader），
	#   就走"改材质内建 burn"这条路 —— 对**不透明植被**天然正确：
	#   不需要遮罩/轮廓/透明度处理，未烧部分保持原样，烧过部分在它自己的光照里变焦。
	if _shader_has_burn(_first_material()):
		global_position = n.global_position
		_apply_in_shader_burn()
		_collect_surface_points()      # ★ 不能漏：否则 _surface 为空 -> 火星取模崩溃
		_build_sparks()
		set_process(true)
		if debug_burn:
			print("[植被燃烧] %s | 走**材质内建 burn**（复制材质，逐株独立）" % _target.name)
		return true
	# 材质
	_mat = ShaderMaterial.new()
	var sh := load(SHADER) as Shader
	if sh == null:
		return false
	_mat.shader = sh
	var nt := load(NOISE) as Texture2D
	if nt != null:
		_mat.set_shader_parameter("noise_tex", nt)
	_mat.set_shader_parameter("phase", _phase)
	_mat.set_shader_parameter("height_ref", height)
	# ★ 显式写入摆动参数：不写的话 get_shader_parameter 取回 null（外部核对/调参都读不到）
	_mat.set_shader_parameter("sway_amt", sway_amt * _rng.randf_range(0.8, 1.3))
	_mat.set_shader_parameter("sway_freq", sway_freq)
	_mat.set_shader_parameter("noise_scale", noise_scale)
	_mat.set_shader_parameter("burn", 0.0)
	_mat.set_shader_parameter("ash", 0.0)
	# ★ 叠加模式：只在烧过的地方变黑，未烧处透明 -> 原外观（含透明裁剪）不受影响
	_mat.set_shader_parameter("overlay_mode", not use_override)
	# 尽量沿用原本的贴图（StandardMaterial3D 有 albedo_texture 就传进来）
	var albedo := _find_albedo()
	if albedo != null:
		_mat.set_shader_parameter("albedo_tex", albedo)
		_mat.set_shader_parameter("use_albedo", true)
		# ★ 轮廓遮罩：**优先用专门的透明度贴图**（alpha_tex），它才是草的轮廓；
		#   albedo 常常是 JPG（没有 alpha），拿它当遮罩等于没遮。
		var fmask := _first_material()
		var alpha_tex := _alpha_texture_from_material(fmask)
		var mask: Texture2D = alpha_tex if alpha_tex != null else albedo
		_mat.set_shader_parameter("mask_tex", mask)
		# ★ 通道必须跟原着色器一致（bermuda 草用 .r，不是 .a）
		var mc := _mask_channel_of(fmask, _alpha_uniform_of(fmask))
		_mat.set_shader_parameter("mask_channel", mc)
	# ★ 透明度配置按**原材质**来（不透明就不遮罩；Alpha 混合就不硬裁；裁剪材质用它的阈值）
	var fmat := _first_material()
	var tr := _transparency_from_material(fmat)
	# ★ 安全阀：卡片型（透明）材质**但拿不到贴图**时，**不画**叠加层。
	#   硬画的结果就是"整张卡片被涂成半透明色块"（用户实测：大块半透明红矩形）。
	var is_transparent := _is_transparent_material(fmat)
	var has_alpha_tex := _alpha_texture_from_material(_first_material()) != null
	var skip_overlay := is_transparent and albedo == null and not has_alpha_tex
	_mat.set_shader_parameter("use_mask", bool(tr["use_mask"]) and albedo != null)
	_mat.set_shader_parameter("force_opaque", bool(tr["force_opaque"]))
	_mat.set_shader_parameter("scissor_enabled", bool(tr["scissor_enabled"]))
	_mat.set_shader_parameter("scissor", float(tr["scissor"]))
	if debug_burn:
		print("[植被燃烧] %s | 材质=%s | 透明=%s | 贴图=%s | 遮罩=%s | 裁剪=%s(%.2f) | %s" % [
				_target.name, fmat.get_class() if fmat != null else "无",
				str(is_transparent), str(albedo != null), str(tr["use_mask"]),
				str(tr["scissor_enabled"]), float(tr["scissor"]),
				"跳过叠加（拿不到轮廓）" if skip_overlay else "正常"])
	if skip_overlay:
		# 只保留火星，不画形体叠加
		set_process.call_deferred(false)
		_build_sparks_only()
		return true
	# 接管外观（摆动需要几何体真的动）
	_prev_override.clear()
	if use_override:
		# 接管：几何体会真的被摆动改写，但外观由本着色器决定
		for mi in _meshes:
			_prev_override.append({"n": mi, "m": mi.material_override, "o": mi.material_overlay})
			mi.material_override = _mat
		for mmi in _multimeshes:
			_prev_override.append({"n": mmi, "m": mmi.material_override, "o": mmi.material_overlay})
			mmi.material_override = _mat
	else:
		# 叠加：保留原生材质（草的透明裁剪/自定义着色器都在），只叠一层焦黑与余烬
		for mi in _meshes:
			_prev_override.append({"n": mi, "m": mi.material_override, "o": mi.material_overlay})
			mi.material_overlay = _mat
		for mmi in _multimeshes:
			_prev_override.append({"n": mmi, "m": mmi.material_override, "o": mmi.material_overlay})
			mmi.material_overlay = _mat
	# ★ 顺序很重要：**先把控制器摆到目标位置**，再采样表面点。
	#   反过来写的话，采样时用的是"原点的逆变换"（世界坐标），之后控制器又被移走，
	#   火星会被目标位置二次偏移 -> 飘到别处、看不见（用户实测："火星没有"）。
	global_position = n.global_position
	# 表面点 + 火星
	_collect_surface_points()
	_build_sparks()
	set_process(true)
	if delay > 0.0:
		_t = -delay
	return true


## 找"原贴图"当遮罩：用它的 alpha 裁出植被真实轮廓（否则烧出来是方块斑块）。
## ★ 草的材质是**自定义 ShaderMaterial**（.tres），没有 albedo_texture 这种固定名字，
##   所以要枚举它的参数、挑出贴图参数 —— 这样"取不到贴图"的问题就解决了。
func _find_albedo() -> Texture2D:
	for mi in _meshes:
		var m: Material = mi.material_override
		if m == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			m = mi.mesh.surface_get_material(0)
		var t := _texture_from_material(m)
		if t != null:
			return t
	for mmi in _multimeshes:
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		for s in range(mmi.multimesh.mesh.get_surface_count()):
			var t2 := _texture_from_material(mmi.multimesh.mesh.surface_get_material(s))
			if t2 != null:
				return t2
	return null


## ★ 读取原材质的**透明度配置** —— 燃烧叠加层必须和它一致，否则：
##   · 不透明材质（树干）被错误遮罩 -> 该烧的地方没烧
##   · Alpha 混合的软边被硬切（discard）-> 叶子/草的边缘像被剪刀剪掉
##   · 裁剪材质的真实阈值被我的写死值(0.35)覆盖 -> 形状对不上
func _transparency_from_material(m: Material) -> Dictionary:
	# 默认：当裁剪处理（最保守，能挡住"整张卡片变黑斑"）
	var out := {"scissor_enabled": true, "scissor": 0.35, "force_opaque": false, "use_mask": true}
	if m == null:
		return out
	if m is StandardMaterial3D:
		var sm := m as StandardMaterial3D
		out["force_opaque"] = _get_bool(sm, "albedo_texture_force_opaque")
		out["scissor"] = sm.alpha_scissor_threshold
		match sm.transparency:
			BaseMaterial3D.TRANSPARENCY_DISABLED:
				# 完全不透明（树干/石头）：整块网格就是轮廓，不需要贴图遮罩
				out["use_mask"] = false
				out["scissor_enabled"] = false
			BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR:
				out["use_mask"] = true
				out["scissor_enabled"] = true
				out["scissor"] = maxf(sm.alpha_scissor_threshold, 0.01)
			BaseMaterial3D.TRANSPARENCY_ALPHA:
				# Alpha 混合：**不能裁剪**，否则软边被硬切；只按 alpha 淡出
				out["use_mask"] = true
				out["scissor_enabled"] = false
			_:
				pass
		return out
	if m is ShaderMaterial:
		var shm := m as ShaderMaterial
		if shm.shader != null:
			# 自定义着色器读不到 transparency 枚举，但通常有 scissor/cutoff/threshold 这类 uniform
			for u in shm.shader.get_shader_uniform_list():
				var un := String(u.get("name", "")).to_lower()
				if un.contains("scissor") or un.contains("cutoff") \
						or un.contains("alpha_cut") or un.contains("threshold"):
					var v: Variant = shm.get_shader_parameter(String(u.get("name", "")))
					if v is float or v is int:
						out["scissor_enabled"] = true
						out["scissor"] = clampf(float(v), 0.01, 0.99)
						return out
	return out


## 取第一个可用材质（透明度配置以它为准）
func _first_material() -> Material:
	for mi in _meshes:
		var m: Material = mi.material_override
		if m == null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			m = mi.mesh.surface_get_material(0)
		if m != null:
			return m
	for mmi in _multimeshes:
		# ★ 节点的 material_override 别忘了（漏了就会报"材质=无"，安全阀也跟着失效）
		if mmi.material_override != null:
			return mmi.material_override
		if mmi.multimesh != null and mmi.multimesh.mesh != null \
				and mmi.multimesh.mesh.get_surface_count() > 0:
			var m2 := mmi.multimesh.mesh.surface_get_material(0)
			if m2 != null:
				return m2
	return null


## 这个材质用的着色器是否自带 burn 参数（本项目给 vegetation_wind.gdshader 加过）
func _shader_has_burn(m: Material) -> bool:
	if m == null or not (m is ShaderMaterial):
		return false
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return false
	for u in sm.shader.get_shader_uniform_list():
		if String(u.get("name", "")) == "burn":
			return true
	return false


## 该材质用的着色器是否支持"逐实例燃烧"（读 INSTANCE_CUSTOM）
func _shader_supports_instance_burn(m: Material) -> bool:
	if m == null or not (m is ShaderMaterial):
		return false
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return false
	# ★ 不能只看 shader.code：addon 的 grass 变体把代码放在 **include** 里，
	#   变体自身源码里没有 INSTANCE_CUSTOM（实测会永远判定失败 = 逐实例燃烧不触发）。
	#   正确做法是看 uniform 表 —— include 里的 uniform 会合并进 shader 的 uniform 列表。
	for u in sm.shader.get_shader_uniform_list():
		var un := String(u.get("name", ""))
		if un == "burn_char_color" or un == "burn_ember_gain":
			return true
	return sm.shader.code.contains("INSTANCE_CUSTOM")


## 启动逐实例燃烧：只挑**圈内**的实例，各自带随机相位与错开延迟
func _start_multimesh_burn() -> bool:
	_mm_burn.clear()
	for mmi in _multimeshes:
		if mmi.multimesh == null:
			continue
		var mat := mmi.material_override
		if mat == null and mmi.multimesh.mesh != null and mmi.multimesh.mesh.get_surface_count() > 0:
			mat = mmi.multimesh.mesh.surface_get_material(0)
		if not _shader_supports_instance_burn(mat):
			continue

		# ★★ INSTANCE_CUSTOM 要生效，MultiMesh 必须在**创建时**就打开 use_custom_data；
		#    运行时改会被 Godot 拒绝（multimesh.cpp:348 报错并忽略），
		#    后果就是"日志说成功、画面毫无反应"。已经在 addons/.../grass.gd 里
		#    统一构造时打开；这里只做检查，没开就**明确跳过**（不静默失败）。
		if not mmi.multimesh.use_custom_data:
			if debug_burn:
				print("[植被燃烧] %s 跳过：MultiMesh 没打开 use_custom_data（需在创建时打开）"
						% mmi.name)
			continue
		# ★ 优先用法术算好的"块内实例表"（先按块、再查块内；整次施法只扫一次）
		var use_preset: bool = preset_mm == mmi and not preset_indices.is_empty()
		if use_preset:
			for k in range(preset_indices.size()):
				var i: int = int(preset_indices[k])
				# ★ 有 preset_delays 就按它（火焰推进：按离角色的距离 -> 波前）；
				#   没有就用随机错开（火焰灼烧原本的行为）。
				var dl: float = float(preset_delays[k]) if k < preset_delays.size() \
						else _rng.randf() * 0.6
				_mm_burn.append({"mmi": mmi, "i": i, "phase": _rng.randf() * TAU,
						"delay": dl, "done": false})
			continue
		# 兜底：没传表时才自己遍历（没有块索引，属于退化路径）
		var cnt := mmi.multimesh.instance_count
		for i in range(cnt):
			var w: Vector3 = mmi.global_transform * mmi.multimesh.get_instance_transform(i).origin
			if burn_radius > 0.0 \
					and Vector2(w.x - burn_center.x, w.z - burn_center.z).length() > burn_radius:
				continue
			_mm_burn.append({"mmi": mmi, "i": i, "phase": _rng.randf() * TAU,
					"delay": _rng.randf() * 0.6, "done": false})
	return not _mm_burn.is_empty()


## 每帧推进每个实例的进度（写进 MultiMesh 的 custom data）
## 返回 true 表示全部结束（调用方去做收尾）
func _drive_multimesh_burn(bt: float, hold: float, at: float) -> bool:
	var all_done := true
	for e in _mm_burn:
		var mmi := e["mmi"] as MultiMeshInstance3D
		if mmi == null or not is_instance_valid(mmi) or mmi.multimesh == null:
			continue
		var lt: float = _t - float(e["delay"])
		var b := 0.0
		var a := 0.0
		if lt > 0.0:
			b = clampf(lt / maxf(bt, 0.01), 0.0, 1.0)
			if lt > bt + hold:
				a = clampf((lt - bt - hold) / maxf(at, 0.01), 0.0, 1.0)
		if a >= 1.0:
			# ★ 烧透之后怎么办 —— 三种取舍得说清：
			#   · 清零           -> 草"瞬间又冒出来"（用户反馈过：消失又出现）
			#   · 永久保持烧毁   -> 同一位置第二次烧就"没草可烧"，看着像没效果
			#     （用户反馈过：连变黑都没有了 —— 多半就是上一轮烧掉的还没恢复）
			#   所以默认：先保持烧毁状态，再**缓缓长回来**（regrow_time 秒）。
			if regrow_time <= 0.0:
				mmi.multimesh.set_instance_custom_data(int(e["i"]),
						Color(1.0, 1.0, float(e["phase"]), 0.0))     # 永久烧毁
				e["done"] = true
			else:
				if not e.has("done_t"):
					e["done_t"] = _t
				var rt: float = _t - float(e["done_t"])
				if rt >= regrow_time:
					mmi.multimesh.set_instance_custom_data(int(e["i"]),
							Color(0.0, 0.0, float(e["phase"]), 0.0))  # 完全长回
					e["done"] = true
				else:
					var k := rt / regrow_time
					# ★ 长回阶段 **burn 固定为 0**：草是"正常的绿草在长大"，
					#   不能还带着焦黑和火光（用户明确要求）。只用 ash 驱动缩放。
					mmi.multimesh.set_instance_custom_data(int(e["i"]),
							Color(0.0, 1.0 - k, float(e["phase"]), 0.0))
					all_done = false
		else:
			mmi.multimesh.set_instance_custom_data(int(e["i"]),
					Color(b, a, float(e["phase"]), 0.0))
			all_done = false
	return all_done


## 把原材质的**风参数**抄到第 i 个副本上（见 WIND_PARAMS 的说明）。
## 参数没设过时 get 返回 null，跳过即可。
func _copy_wind_params(i: int) -> void:
	if i < 0 or i >= _shader_mats.size() or i >= _shader_src.size():
		return
	var src: ShaderMaterial = _shader_src[i]
	var dst: ShaderMaterial = _shader_mats[i]
	if src == null or dst == null or src == dst:
		return
	for p in WIND_PARAMS:
		var v: Variant = src.get_shader_parameter(p)
		if v != null:
			dst.set_shader_parameter(p, v)


## 走"改材质内建 burn"：给每个网格复制一份材质（共享 .tres 不能直接改，
## 否则所有同类植被会一起烧），之后逐帧只写这些副本的 burn / ash。
func _apply_in_shader_burn() -> void:
	_shader_mats.clear()
	for mi in _meshes:
		if mi.mesh == null:
			continue
		for s in range(mi.mesh.get_surface_count()):
			var base: Material = mi.mesh.surface_get_material(s)
			if base == null:
				base = mi.material_override
			if base == null:
				continue
			var dup := base.duplicate() as ShaderMaterial
			if dup == null:
				continue
			# ★★ 保险：把**外观参数**从原材质显式抄一遍 ✓
			#   否则 shader 材质（如树的 tree_burn_keep / tree_leaves_burn ✓）在被接管后
			#   会掉成"白模" ✓ —— 症状正是"编辑器里正常 ✓ 游戏内发白" ✓（用户实测 ✓）
			var src_sm := base as ShaderMaterial
			if src_sm != null:
				for pn in ["albedo_tex", "alpha_tex", "base_color", "use_albedo", "use_mask",
						"mask_channel", "scissor", "scissor_enabled", "force_opaque", "use_uv",
						"has_normal", "normal_tex", "has_rough", "rough_tex", "overlay_mode"]:
					var pv: Variant = src_sm.get_shader_parameter(pn)
					if pv != null:
						dup.set_shader_parameter(pn, pv)
			# ★★★ 自动量树高（用户要求 ✓）：用该网格**局部 AABB 的顶部**当 height_ref ✓
			#   为什么必须自动 ✓：shader 的 `v_hgt` 就是**模型空间**的 y ✓
			#     → height_ref 必须是**这个网格自己坐标系里的高度** ✓
			#   手填的风险 ✓：材质写着 8.2 ✗ 而树实际只有 **4.56 米** ✗
			#     → 前沿 `burn × 8.2 × 1.15` 在 burn≈0.43 就**越过树顶** ✗
			#     → 火焰只用前 43% 时间扫完 ✓ 看着"飞快/闪烁"✓ 之后整棵**瞬间全黑**✓（用户实测 ✓）
			if mi.mesh != null:
				var ab: AABB = mi.mesh.get_aabb()
				var top := ab.position.y + ab.size.y
				if top > 0.05:
					dup.set_shader_parameter("height_ref", top)
					print("[燃烧] 自动量高 ✓ height_ref = %.2f 米（%s）" % [top, mi.name])
			dup.set_shader_parameter("burn", 0.0)
			dup.set_shader_parameter("ash", 0.0)
			dup.set_shader_parameter("burn_phase", _phase)
			mi.set_surface_override_material(s, dup)
			_shader_mats.append(dup)
			_shader_src.append(base as ShaderMaterial)
			_copy_wind_params(_shader_src.size() - 1)


## 材质是否"卡片型"（透明/裁剪/哈希）—— 这类必须靠贴图 alpha 才是真实轮廓
func _is_transparent_material(m: Material) -> bool:
	if m is StandardMaterial3D:
		var t := (m as StandardMaterial3D).transparency
		return t != BaseMaterial3D.TRANSPARENCY_DISABLED
	if m is ShaderMaterial:
		# 自定义着色器无从判断，按"是卡片"处理（保守 -> 拿不到贴图就不画）
		return true
	return false


## 只放火星、不画形体叠加（安全阀分支用）
func _build_sparks_only() -> void:
	_collect_surface_points()
	_build_sparks()


## 防御式读布尔属性：不同 Godot 版本/基类里属性名不一定存在，
## 直接点属性会 "Invalid access to property" 并让整个函数中断（实测踩过）。
func _get_bool(o: Object, prop: String, def: bool = false) -> bool:
	if o == null or not o.has_method("get"):
		return def
	var v: Variant = o.get(prop)
	if v == null:
		return def
	return bool(v)


## ★ 找**透明度贴图**。植被的轮廓常常不在 albedo 的 alpha 里：
##   实测 scenes/草 的材质是 albedo_tex=JPG（**没有 alpha**）+ alpha_tex=PNG（单独的透明贴图），
##   拿 albedo 的 alpha 当遮罩恒为 1 -> 等于没遮 -> 整张卡片被涂黑（用户反复反馈的问题）。
func _alpha_texture_from_material(m: Material) -> Texture2D:
	if m == null or not (m is ShaderMaterial):
		return null
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return null
	for u in sm.shader.get_shader_uniform_list():
		var un := String(u.get("name", "")).to_lower()
		var is_alpha := false
		for hint in ["alpha", "opacity", "opac", "transp", "cutout", "mask", "blend_tex"]:
			if un.contains(hint):
				is_alpha = true
				break
		if not is_alpha:
			continue
		var v: Variant = sm.get_shader_parameter(String(u.get("name", "")))
		if v is Texture2D:
			return v
	return null


## 找出遮罩贴图对应的 uniform 名（用来解析它用的是哪个通道）
func _alpha_uniform_of(m: Material) -> String:
	if m == null or not (m is ShaderMaterial):
		return ""
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return ""
	for u in sm.shader.get_shader_uniform_list():
		var un := String(u.get("name", ""))
		var ln := un.to_lower()
		for hint in ["alpha", "opacity", "opac", "transp", "cutout", "mask"]:
			if ln.contains(hint) and sm.get_shader_parameter(un) is Texture2D:
				return un
	return ""


## ★ 原着色器用**哪个通道**表示形状？从它的源码里解析出来（不硬编码）。
##   例：grass_wind.gdshader 写的是 `ALPHA = texture(alpha_tex, UV).r` -> 红通道。
##   取错通道的后果：那张 PNG 的 a 恒为 1 -> 遮罩失效 -> 透明区域也变黑（实测踩过）。
##   返回 0=r 1=g 2=b 3=a（解析不出来时按 a）。
func _mask_channel_of(m: Material, tex_uniform: String) -> int:
	if m == null or not (m is ShaderMaterial) or tex_uniform == "":
		return 3
	var sm := m as ShaderMaterial
	if sm.shader == null:
		return 3
	var code := sm.shader.code
	var re := RegEx.new()
	if re.compile("texture\\s*\\(\\s*" + tex_uniform + "\\s*,[^)]*\\)\\s*\\.([rgba])") != OK:
		return 3
	var r := re.search(code)
	if r == null:
		return 3
	match r.get_string(1):
		"r":
			return 0
		"g":
			return 1
		"b":
			return 2
	return 3


func _texture_from_material(m: Material) -> Texture2D:
	if m == null:
		return null
	if m is StandardMaterial3D:
		return (m as StandardMaterial3D).albedo_texture
	if m is ShaderMaterial:
		var sm := m as ShaderMaterial
		if sm.shader == null:
			return null
		var fallback: Texture2D = null
		# ★ ShaderMaterial **没有** get_shader_parameter_list()（调用会报
		#   "Nonexistent function"，而且会让整个 burn_node 中断 -> 材质贴不上、燃烧失效）。
		#   参数表在 **Shader** 上：get_shader_uniform_list()。
		for u in sm.shader.get_shader_uniform_list():
			var uname := String(u.get("name", ""))
			if uname == "":
				continue
			var v: Variant = sm.get_shader_parameter(uname)
			if not (v is Texture2D):
				continue
			# ★ 优先"确定是 albedo"的名字；并**排除**明显不是的（noise/normal/height/...）。
			#   之前 hints 太松（含 "tex"/"map"），会把 noise_tex 当成 albedo -> 遮罩失效
			#   -> 叠加层盖满整张卡片 = 大黑斑（用户实测反馈）。
			var pn := uname.to_lower()
			var excluded := false
			for bad in ["noise", "normal", "height", "mask", "rough", "metal", "ao",
					"dist", "wind", "detail", "dissolve"]:
				if pn.contains(bad):
					excluded = true
					break
			if excluded:
				continue
			for hint in ["albedo", "color", "colour", "diffuse", "base", "blade", "grass"]:
				if pn.contains(hint):
					return v
			if fallback == null:
				fallback = v
		return fallback
	return null


## 从真实顶点采样"表面点"：火星从这里生出来
func _collect_surface_points() -> void:
	_surface.clear()
	var want := maxi(spark_count * 6, 24)
	for mi in _meshes:
		if mi.mesh == null:
			continue
		var xf := mi.global_transform
		for s in range(mi.mesh.get_surface_count()):
			var arrays := mi.mesh.surface_get_arrays(s)
			if arrays.is_empty():
				continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts == null or verts.is_empty():
				continue
			var stride := maxi(1, int(float(verts.size()) / float(maxi(want, 1))))
			var i := 0
			while i < verts.size() and _surface.size() < want:
				var w := xf * verts[i]
				i += stride
				# 转成"本节点局部坐标"（火星挂在控制器下）
				_surface.append(global_transform.affine_inverse() * w)
	# ★ MultiMesh（addon 的整片草丛）：必须按 **(实例变换 × 顶点)** 采样，
	#   否则火星会全挤在节点原点那一株草上，而不是撒在整片草丛的表面。
	for mmi in _multimeshes:
		if mmi.multimesh == null or mmi.multimesh.mesh == null:
			continue
		var mesh := mmi.multimesh.mesh
		var count := mmi.multimesh.visible_instance_count
		if count <= 0:
			count = mmi.multimesh.instance_count
		if count <= 0:
			continue
		for s in range(mesh.get_surface_count()):
			var arrays2 := mesh.surface_get_arrays(s)
			if arrays2.is_empty():
				continue
			var verts2: PackedVector3Array = arrays2[Mesh.ARRAY_VERTEX]
			if verts2 == null or verts2.is_empty():
				continue
			var tries := 0
			while _surface.size() < want and tries < want * 4:
				tries += 1
				# ★ 必须用 posmod：randi() 返回 uint32，直接 % count 可能是负数下标，
				#   结果 get_instance_transform 取不到实例 -> 火星全挤在一株草上
				#   （实测：横向跨度只有 0.06 米 = 一片草的宽度）。
				var ii := posmod(_rng.randi(), count)
				var vv := verts2[posmod(_rng.randi(), verts2.size())]
				var w2: Vector3 = mmi.global_transform \
						* (mmi.multimesh.get_instance_transform(ii) * vv)
				_surface.append(global_transform.affine_inverse() * w2)
	if _surface.is_empty():
		_surface.append(Vector3.ZERO)


func _build_sparks() -> void:
	if _sparks != null and is_instance_valid(_sparks):
		_sparks.queue_free()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_color = Color(1.0, 0.62, 0.18, 0.95)
	m.disable_receive_shadows = true
	var q := QuadMesh.new()
	q.size = Vector2(spark_size, spark_size)
	q.surface_set_material(0, m)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = spark_count
	mm.mesh = q
	var node := MultiMeshInstance3D.new()
	node.name = "BurnSparks"
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	_sparks = node
	_sp.resize(spark_count)
	_sv.resize(spark_count)
	_sl.resize(spark_count)
	for i in range(spark_count):
		_sl[i] = -1.0


# ---------------------------------------------------------------- 每帧
func _process(delta: float) -> void:
	if _done or _target == null or not is_instance_valid(_target):
		return
	_t += delta
	if _t < 0.0:
		return
	# ★ 1 秒时汇报一次：路径 / 着色器 / **实际写进去的 burn 值**。
	#   用来区分"驱动没生效"和"着色器没表现"，不再靠猜。
	if debug_burn and not _reported and _t >= 1.0:
		_reported = true
		if not _mm_burn.is_empty():
			var cd := "（读不回）"
			var e0 := _mm_burn[0] as Dictionary
			var mmi0 := e0["mmi"] as MultiMeshInstance3D
			if mmi0 != null and mmi0.multimesh != null:
				cd = str(mmi0.multimesh.get_instance_custom_data(int(e0["i"])))
			print("[植被燃烧·1s] %s | 逐实例 | 实例数 %d | 首实例 custom=%s | t=%.2f"
					% [_target.name, _mm_burn.size(), cd, _t])
		elif not _shader_mats.is_empty():
			var b1: Variant = _shader_mats[0].get_shader_parameter("burn")
			var sp := "无"
			if _shader_mats[0].shader != null:
				sp = _shader_mats[0].shader.resource_path
			print("[植被燃烧·1s] %s | 材质内建 burn | 材质副本 %d | burn=%s | 着色器=%s | t=%.2f"
					% [_target.name, _shader_mats.size(), str(b1), sp, _t])
		elif _mat != null:
			print("[植被燃烧·1s] %s | 叠加层 | burn=%s | t=%.2f"
					% [_target.name, str(_mat.get_shader_parameter("burn")), _t])
		else:
			print("[植被燃烧·1s] %s | **什么都没挂上**（无逐实例/无材质副本/无叠加层）"
					% _target.name)
	var burn := clampf(_t / maxf(burn_time, 0.01), 0.0, 1.0)
	var ash := 0.0
	if _t > burn_time + char_hold:
		ash = clampf((_t - burn_time - char_hold) / maxf(ash_time, 0.01), 0.0, 1.0)
	if not _mm_burn.is_empty():
		# ★ 逐实例路线：进度写在 MultiMesh 的 custom data 上
		_update_sparks(delta, burn)
		if _drive_multimesh_burn(burn_time, char_hold, ash_time):
			_finish()
		return
	if not _shader_mats.is_empty():
		# 内建 burn 路线：只写材质副本（每株独立）
		for si in range(_shader_mats.size()):
			var sm2: ShaderMaterial = _shader_mats[si]
			if sm2 != null:
				sm2.set_shader_parameter("burn", burn)
				sm2.set_shader_parameter("ash", ash)
				# ★ 每帧同步天气风：副本不在风系统的材质名单里，不抄就会"一烧就不摆"
				_copy_wind_params(si)
	elif _mat != null:
		_mat.set_shader_parameter("burn", burn)
		_mat.set_shader_parameter("ash", ash)
	_update_sparks(delta, burn)
	if ash >= 1.0:
		_finish()


func _update_sparks(delta: float, burn: float) -> void:
	if _sparks == null or not is_instance_valid(_sparks):
		return
	var mm := _sparks.multimesh
	for i in range(spark_count):
		if _sl[i] <= 0.0:
			# 只在"还在烧"且**确实采到表面点**时重生（空表要跳过，否则取模崩溃）
			if burn < 1.0 and _rng.randf() < 0.35 and _surface.size() > 0:
				var surf: Vector3 = _surface[posmod(_rng.randi(), _surface.size())]
				_sp[i] = surf
				_sv[i] = Vector3(_rng.randf_range(-0.12, 0.12), _rng.randf_range(0.25, 0.7),
						_rng.randf_range(-0.12, 0.12))
				_sl[i] = spark_lifetime * _rng.randf_range(0.6, 1.2)
			else:
				mm.set_instance_transform(i, Transform3D(Basis(), Vector3(0, -999, 0)))
				continue
		_sl[i] -= delta
		_sp[i] += _sv[i] * delta
		_sv[i].y = maxf(_sv[i].y - 0.25 * delta, 0.05)      # 火星上升变慢
		var k := clampf(_sl[i] / maxf(spark_lifetime, 0.01), 0.0, 1.0)
		var b := Basis().scaled(Vector3.ONE * clampf(k, 0.25, 1.0))
		mm.set_instance_transform(i, Transform3D(b, _sp[i]))


## ★★ 目标是否"保留型"（木质：烧完**留下焦黑** ✓ 不消失 ✓）
##   用户要求：叶子靠**材质 alpha 淡出**到透明 ✓ → 同一节点上的枝干必须**不被隐藏** ✓
##   判定依据（任一 ✓）：材质 shader 是 tree_burn_keep ✓ ／ 资源 meta burn_mode == "wood" ✓
func _target_is_keep() -> bool:
	if _target == null or not is_instance_valid(_target):
		return false
	var mi := _target as MeshInstance3D
	if mi == null or mi.mesh == null:
		for c in _target.get_children():
			var cmi := c as MeshInstance3D
			if cmi != null and cmi.mesh != null:
				mi = cmi
				break
		if mi == null:
			return false
	for s in range(mi.mesh.get_surface_count()):
		var m: Material = mi.mesh.surface_get_material(s)
		if m == null:
			m = mi.get_surface_override_material(s)
		if m == null:
			continue
		if m is ShaderMaterial:
			var sm := m as ShaderMaterial
			# ★ 修正（方案 A ✓）：原来用 `ends_with("tree_burn_keep.gdshader")` ✗
			#   而材质实际引用的是 `tree_burn_keep_ds.gdshader` ✗ → 这条判断**一直是失效的** ✓
			#   → 之前只靠材质的 `burn_mode == "wood"` meta 生效 ✓
			#   改用 contains ✓：任何变体（_ds / 无后缀 / 以后改名）都能认出来 ✓
			if sm.shader != null and String(sm.shader.resource_path).contains("tree_burn_keep"):
				return true
		if String(m.get_meta("burn_mode", "")) == "wood":
			return true
	return false


func _finish() -> void:
	_done = true
	set_process(false)
	# ★ 逐实例燃烧**不清零**：烧掉的草要留在烧毁状态（清零会让它"又冒出来"）。
	#   也**不还原 use_custom_data** —— 一还原就等于把每个实例的数据抹掉。
	#   （同一片草再被烧时，_start_multimesh_burn 会重新写入它需要的实例。）
	_mm_custom_on.clear()
	if _sparks != null and is_instance_valid(_sparks):
		_sparks.visible = false
	# ★ MultiMesh（addon 的一整片草）**绝不能隐藏**：那是一片/整张地图的草，
	#   隐藏 = "整个地图的草都烧没了"（用户实测）。它只做视觉燃烧、不消失。
	if _target != null and is_instance_valid(_target):
		# ★ 清掉"燃烧中"标记 ✓（配合 burn_node 的防重入 ✓）
		if _target.has_meta("burning"):
			_target.remove_meta("burning")
		if _multimeshes.is_empty():
			# ★★ 保留型（树干/枝 ✓）：**不隐藏** ✓ —— 叶子已由材质 alpha 缓慢淡出到透明 ✓
			#    → 同一节点上也能做到"叶子没了、枝干焦黑留下" ✓ 不需要拆节点 ✓
			if not _target_is_keep():
				_target.visible = false      # 普通植被（草等）：烧尽 -> 消失 ✓
		elif _mat != null:
			_mat.set_shader_parameter("burn", 0.0)
			_mat.set_shader_parameter("ash", 0.0)
	# ★★ 保留型（树干/枝/整棵树 ✓）：**不还原材质** ✗→✓，而是**定在全焦黑** ✓
	#   原因（用户实测 ✓）：还原 = 烧过的树**恢复原样、变绿** ✗✓
	#   需求：烧过的树要保持"焦黑树架" ✓（再烧也还是焦的 ✓）
	if _target_is_keep():
		# ★★★ 记下"已烧毁"终态（用户要求 ✓）：第二次施法**直接跳过** ✗（见 burn_node 的检查 ✓）
		#   否则第二次会从原始材质重新复制 → 看起来"又还原了" ✓✓（用户实测 ✓）
		_target.set_meta("burned_out", true)
		# ★★ 分类冻结（修复"烧完又长回来"✗）：
		#   之前一律设 `ash = 0` ✗ → 连**叶片**的 ash 也被清零 ✓
		#   → 已经淡出消失的叶子**又变回原样** ✓✓（用户实测"烧完有长回来了"✓）
		#   现在：木质 → 焦黑留存（burn=1 / ash=0 ✓）
		#         叶片等 → 保持"烧尽"（burn=1 / **ash=1** ✓ 淡出到底 ✓ 不再长回来 ✓）
		for m in _shader_mats:
			if m == null or not is_instance_valid(m):
				continue
			var sm := m as ShaderMaterial
			if sm == null:
				continue
			var is_wood := sm.shader != null \
					and String(sm.shader.resource_path).contains("tree_burn_keep")
			sm.set_shader_parameter("burn", 1.0)
			if is_wood:
				sm.set_shader_parameter("ash", 0.0)
			else:
				sm.set_shader_parameter("ash", 1.0)
		print("[燃烧] 保留型 ✓ 已冻结（木质=焦黑 / 叶片=消失）：%s" % [
				_target.name if _target != null else "?"])
		return
	# 还原材质，避免这株被复用（对象池/重生）时还带着焦黑
	for d in _prev_override:
		var nd = d["n"]
		if nd != null and is_instance_valid(nd):
			nd.material_override = d["m"]
			nd.material_overlay = d["o"]


func is_done() -> bool:
	return _done

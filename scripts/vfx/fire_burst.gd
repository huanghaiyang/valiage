extends Node3D
## 大片火焰燃烧特效 —— 用 `tools/glb_split.py` 从 `火焰燃烧.glb` 切出来的
## **5 个独立火焰形状**拼成一团大火。
##
## 场景里能看到的东西（编辑器里可直接调位置/缩放/旋转）：
##   · 底层焰 ×5   五个形状围成一圈（这是火焰的"主体"，最大最亮）
##   · 上层焰 ×5   同样五个形状，抬高、缩小（火舌的尖端，负责"高"）
##   · 中心主焰 ×1 最高的那个形状，放大（撑起整团火的高度）
##   · 闪烁点光     红橙色的 OmniLight3D，照亮周围地面（火光的氛围全靠它）
##
## 本脚本负责三件事：
##   1) 给每个火焰网格装上 fire_flame.gdshader（**每个实例一份材质**，相位各不相同）
##   2) 把焰卡**贴地**：模型的锚点在火焰中腰，这里按 AABB 把底边对到 y=0
##   3) 每帧做独立动画：纵向伸缩 + 亮度闪烁 + 左右摇摆；并让焰卡绕 Y 轴朝向相机
##
## 【为什么焰卡要朝相机】模型是 5 张**竖直的薄片**（法线朝 ±X）。俯视/等距视角下
##   如果不转向，看到的是纸片边缘。绕 Y 轴朝向相机之后，任何角度都能看到火苗轮廓。

const FIRE_SHADER := "res://assets/shaders/fire_flame.gdshader"
const FIRE_TEX := "res://assets/textures/法术特效/龙卷风/T_FirePanningCyl45.png"
const NOISE_TEX := "res://assets/textures/法术特效/Noise1_tiled.png"

## 焰卡是否绕 Y 轴朝向相机。
## ★ 默认**关闭**：需求是"模型不要跟着角色视角旋转"，所以火焰保持自己的固定朝向。
@export var auto_billboard := false
## 每张焰卡的朝向是否在**生成时随机**（之后固定不动）。
## 随机角度让同一团火从任何角度看都有层次，也不会所有卡片都侧对着某个方向。
@export var random_yaw := true
@export var stretch_gain := 0.11        ## 纵向伸缩幅度（火焰呼吸）
@export var flicker_gain := 0.16        ## 亮度闪烁幅度
## 波纹幅度（米，逐卡再随机一次）：随高度线性增强
@export var ripple_amt := 0.05
## 卷曲幅度（米，逐卡再随机一次）：随高度平方增强
@export var curl_amt := 0.10
@export var sway_gain := 0.055          ## 左右摇摆幅度（弧度）
@export var light_flicker := 0.45       ## 点光闪烁幅度
@export var brightness := 2.6           ## 基础亮度（mix 模式下要让核心过曝到白热，才有火焰感）

## ★★ 生长/熄灭系数：1.0 = 正常燃烧，0 = 完全熄灭。
##   熄灭**绝对不能去缩放特效根节点** —— 焰卡是围着中心摆成一圈的，
##   缩放根节点会把它们**往中心拉**（用户原话："火焰熄灭不要向中心靠拢"）。
##   这里改成**每张卡各自在原位缩小 + 变暗**，位置一动不动。
var grow := 1.0

var _items: Array[Dictionary] = []
var _glows: Array[Dictionary] = []
var _light: OmniLight3D = null
var _t := 0.0
## ★ 防重入：_collect 会**累加**贴地偏移，重复执行会把火焰抬离地面
##   （add_child 已经会触发 _ready；自检/工具里再手动 call 一次就会踩这个坑）
var _built := false


func _ready() -> void:
	if _built:
		return
	_built = true
	_light = _find_light(self)
	_collect(self)
	_build_core_glow()
	# 相位随机打散：同一个场景重复摆时不会所有火苗同步
	for i in _items.size():
		_items[i]["phase"] = float(i) * 1.7 + randf() * 0.9


## 核心辉光：几张**加色、始终朝向相机**的方形光片，叠在火心。
## 【为什么需要】T_FirePanningCyl45 是大片黑底的火舌纹理，"火肉"本来就少，
##   光靠叠焰卡填不满中间 —— 用户反馈"火焰密度过低"。
##   这几张光片把中间填实，读数上就是把"稀疏的火舌"变成"一团在烧的火"。
## 【为什么放在单独的子节点下】_collect 会把所有 MeshInstance3D 当成焰卡，
##   所以必须**在收集之后**再建，并挂到一个独立节点下便于区分。
func _build_core_glow() -> void:
	var ft := load(FIRE_TEX) as Texture2D
	var holder := Node3D.new()
	holder.name = "CoreGlow"
	add_child(holder)
	for i in 3:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.disable_receive_shadows = true
		if ft != null:
			mat.albedo_texture = ft
		# 三层：底部最红最暗、高处偏亮，叠出火心的层次
		var k := float(i) / 2.0
		mat.albedo_color = Color(1.0, 0.16 + 0.22 * k, 0.02, 0.55 - 0.10 * k)
		var q := MeshInstance3D.new()
		q.name = "CoreGlow%d" % i
		var qm := QuadMesh.new()
		qm.size = Vector2(2.7 - 0.55 * float(i), 2.3 - 0.45 * float(i))
		q.mesh = qm
		q.material_override = mat
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(q)
		q.position = Vector3(0.0, 0.85 + 0.75 * float(i), 0.0)
		_glows.append({
			"node": q,
			"mat": mat,
			"base_pos": q.position,
			"base_color": mat.albedo_color,
			"base_size": qm.size,
			"phase": randf() * 6.28,
		})


## 递归收集所有火焰网格；给每个实例一份自己的材质
func _collect(n: Node) -> void:
	for c in n.get_children():
		if c is MeshInstance3D:
			var mi := c as MeshInstance3D
			var holder := mi.get_parent() as Node3D
			# ★★ 两种结构都要处理：
			#   · 切片导出的 glb，其**根节点本身就是 MeshInstance3D** -> 直接挂在特效根下。
			#     这种情况必须把动画写回**网格自己**；若写父节点（= 特效根），就会和
			#     法术自身的整体缩放互相覆盖（实际踩过：缩放在两个值之间乱跳）。
			#   · 网格在实例根之下 -> 动画写实例根。
			var anim: Node3D
			if holder == null or holder == self:
				anim = mi
				mi.position.y -= _parent_bottom(mi)      # 贴地：父空间包围盒的最低点
			else:
				anim = holder
				holder.global_position.y -= _world_bottom(mi)   # 贴地：世界空间包围盒
			var mat := _make_fire_material()
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			# ★ 生成时给一个**随机固定朝向**（只在 Y 轴上转，火苗始终竖直）。
			#   不跟随相机 —— 需求明确"模型不要跟着角色视角旋转"。
			if random_yaw:
				anim.rotation.y = randf() * TAU
			_items.append({
				"node": anim,
				"mat": mat,
				"phase": 0.0,
				"base_pos": anim.position,
				"base_scale": anim.scale,
				"freq": 1.6 + randf() * 2.2,        # 每个实例呼吸频率不同
				"flicker_freq": 5.5 + randf() * 5.0,
			})
			continue
		_collect(c)


# ---------------------------------------------------------------- 焰卡朝向（边界圈专用）
## ★ 把这一簇火的**每张焰卡**的大面朝向指定的**世界方向**（水平分量）。
##
## 【为什么必须逐卡写】_collect() 里每张卡的 yaw 是**随机**的（random_yaw，见其注释），
##   随机之后父节点（特效根）转多少都决定不了"大面朝哪"。
##   所以「火焰推进」的边界圈不能用"给特效根一个 yaw"来做朝向 —— 必须逐卡写。
##
## 【大面法线 = 本地 ±X】模型几何实测：16 个焰卡网格**全部**是 X 方向最薄
##   （AABB 约 0.03 × 0.38 × 0.25，见 check_flame_cards.gd），薄片的大面法线
##   就是本地 X 轴。绕 Y 把本地 X 转到方向 u 的角度 = atan2(-u.z, u.x)。
##   u = 目标方向在**卡的父空间**里的水平分量（父节点可能带地面倾斜）。
##
## jitter_deg：逐卡在目标方向两侧的**对称**抖动（度）。
##   0 = 全部完全对齐（一堵整齐的墙）；小角度（如 10°）时，簇的**面积加权大面**
##   仍然精确朝向目标（左右抖动相互抵消），同时保证从侧面看不会整片侧过去。
##
## ★ 默认行为不变：不调用本接口时，焰卡就是 _collect 里那套随机朝向。
##   「火焰灼烧」从不调用它 -> 观感与改动前完全一致。
func face_cards_to(world_dir: Vector3, jitter_deg: float = 0.0) -> void:
	var d := Vector3(world_dir.x, 0.0, world_dir.z)
	if d.length_squared() < 1e-8:
		return
	d = d.normalized()
	var jit := deg_to_rad(maxf(jitter_deg, 0.0))
	for it in _items:
		var node := it["node"] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var par := node.get_parent() as Node3D
		var pb: Basis = par.global_transform.basis.orthonormalized() if par != null else Basis.IDENTITY
		var u: Vector3 = pb.inverse() * d
		u.y = 0.0
		if u.length_squared() < 1e-8:
			continue
		u = u.normalized()
		var yaw := atan2(-u.z, u.x)
		if jit > 0.0:
			yaw += randf_range(-jit, jit)
		node.rotation.y = yaw


## ★ 把这一簇火的每张焰卡还原成**随机朝向**（= _collect 里 random_yaw 的行为）。
##   「火焰推进」的内部填充用它：池子会被多次施法复用，某簇上一次可能是边界圈
##   （已被 face_cards_to 写成整齐朝向），这一次回到内部必须重新随机，
##   否则内部会出现一整片方向一致的薄片（又薄又平、没有体积感）。
func randomize_cards() -> void:
	for it in _items:
		var node := it["node"] as Node3D
		if node != null and is_instance_valid(node):
			node.rotation.y = randf() * TAU


## 网格在**父节点空间**中的包围盒最低点（把网格自身的旋转/缩放算进去）
func _parent_bottom(mi: MeshInstance3D) -> float:
	var aabb := mi.mesh.get_aabb()
	var xf := mi.transform
	var lo := 1e9
	for i in range(8):
		var c := aabb.position + Vector3(
				aabb.size.x if (i & 1) != 0 else 0.0,
				aabb.size.y if (i & 2) != 0 else 0.0,
				aabb.size.z if (i & 4) != 0 else 0.0)
		lo = minf(lo, (xf * c).y)
	return lo if lo < 1e8 else 0.0


## 网格的世界空间 AABB 最低点（y）
func _world_bottom(mi: MeshInstance3D) -> float:
	var aabb := mi.mesh.get_aabb()
	var xf := mi.global_transform
	var lo := 1e9
	for i in range(8):
		var c := aabb.position + Vector3(
				aabb.size.x if (i & 1) != 0 else 0.0,
				aabb.size.y if (i & 2) != 0 else 0.0,
				aabb.size.z if (i & 4) != 0 else 0.0)
		lo = minf(lo, (xf * c).y)
	return lo if lo < 1e8 else 0.0


func _make_fire_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := load(FIRE_SHADER) as Shader
	if sh == null:
		push_warning("[FireBurst] 缺少 fire_flame.gdshader")
		return m
	m.shader = sh
	var ft := load(FIRE_TEX) as Texture2D
	var nt := load(NOISE_TEX) as Texture2D
	if ft != null:
		m.set_shader_parameter("fire_tex", ft)
	if nt != null:
		m.set_shader_parameter("noise_tex", nt)
	m.set_shader_parameter("brightness", brightness)
	# ★ 逐卡随机的滚动倍率：否则所有焰卡的贴图流速完全一样，
	#   整片火会按同一节奏一起窜（"过于有节奏感"）。相位只错开起始，不解决频率。
	m.set_shader_parameter("scroll_scale", randf_range(0.7, 1.4))
	# ★ 每张卡的**运动倍率**：波纹/卷曲的频率也各不相同，
	#   否则整片火会像一块布在齐步抖（和贴图流速同一类问题）
	m.set_shader_parameter("motion_scale", randf_range(0.7, 1.5))
	# 波纹/卷曲幅度也逐卡微随机（同一片火里更自然），并**显式**写进材质
	# （不写的话 get_shader_parameter 取回 null，外部核对时没法读）
	m.set_shader_parameter("ripple_amt", ripple_amt * randf_range(0.8, 1.25))
	m.set_shader_parameter("curl_amt", curl_amt * randf_range(0.8, 1.3))
	# 先给一版风参数（_process 每帧会刷新），免得第一帧是默认风向
	_flame_mats.append(m)
	_apply_wind()
	return m


## ★ 已生成的焰卡材质（每帧把天气风写进去 —— 火焰随风倾倒）
var _flame_mats: Array[ShaderMaterial] = []


## 读 Wind 自动加载的"当前风"（没有 Wind 时用兜底值，保证不报错）
func _apply_wind() -> void:
	var w: Node = null
	if Engine.has_singleton("Wind"):
		w = Engine.get_singleton("Wind")
	if w == null:
		w = get_node_or_null("/root/Wind")
	if w == null:
		return
	var dir: Vector2 = w.get("cur_dir") if w.get("cur_dir") is Vector2 else Vector2(1.0, 0.0)
	for m in _flame_mats:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("wind_dir", dir)
		m.set_shader_parameter("wind_strength", float(w.get("cur_strength")))
		m.set_shader_parameter("wind_turb", float(w.get("cur_turbulence")))
		m.set_shader_parameter("wind_speed", float(w.get("cur_speed")))


func _process(delta: float) -> void:
	_apply_wind()
	_t += delta
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	for it in _items:
		var node := it["node"] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		var phase: float = it["phase"]
		var bs: Vector3 = it["base_scale"]

		# 生长/熄灭系数（0..1）。位置**不动**，只缩自己 + 变暗 —— 所以不会向中心靠拢。
		var g := clampf(grow, 0.0, 1.0)
		var bright := pow(g, 0.6)              # 亮度衰减比尺寸慢，看起来像"烧尽"而不是"缩小"
		var size_mul := g

		# 1) 纵向伸缩（体积守恒：横向跟着缩，火苗才有"喘气"的感觉）
		var st := (1.0 + sin(_t * float(it["freq"]) + phase) * stretch_gain) * size_mul
		var side := 1.0 / sqrt(max(st, 0.05))
		node.scale = Vector3(bs.x * side, bs.y * st, bs.z * side)

		# 2) 左右摇摆
		node.rotation.z = sin(_t * 1.9 + phase * 1.4) * sway_gain
		# 3) ★ 这里原本还有一段"上下浮动"：
		#      node.position.y = bp.y + sin(_t * 1.3 + phase * 0.8) * 0.05
		#    每张卡 ±5cm 上下平移，而且 phase 是**每张卡随机**的 -> 16 张各自不同步地弹，
		#    看起来是一整片火焰在"抖动"（用户实测反馈："火焰生成时有向上抖动的效果"）。
		#    火焰的动感应该来自**纵向伸缩(第 1 条) + 左右摇摆(第 2 条)**，
		#    而不是整体上下平移 —— 所以这里删掉，位置保持 base_pos 不动。

		# 4) 亮度闪烁（每张焰卡频率不同，整体就像火焰在跳动）
		var mat := it["mat"] as ShaderMaterial
		if mat != null:
			var f := 1.0 + sin(_t * float(it["flicker_freq"]) + phase * 2.1) * flicker_gain
			mat.set_shader_parameter("brightness", brightness * f * bright)
			mat.set_shader_parameter("alpha_scale", g)

		# 5) 焰卡绕 Y 轴朝向相机（模型法线是 ±X，所以取 atan2(-dz, dx)）
		if auto_billboard and cam != null:
			var d := cam.global_position - node.global_position
			d.y = 0.0
			if d.length_squared() > 0.0001:
				node.rotation.y = atan2(-d.z, d.x)

	if _light != null and is_instance_valid(_light):
		_light.light_energy = _light_base_energy * (1.0 + sin(_t * 8.3) * light_flicker
				+ sin(_t * 21.7) * light_flicker * 0.35)

	# 核心辉光：跟着 grow 一起生灭 + 轻微脉动
	var gg := clampf(grow, 0.0, 1.0)
	for it in _glows:
		var q := it["node"] as MeshInstance3D
		if q == null or not is_instance_valid(q):
			continue
		var ph: float = it["phase"]
		# 光片跟着 grow 缩小（不是靠根节点缩放），保证熄灭时**不向中心靠拢**
		var s := gg * (1.0 + sin(_t * 2.6 + ph) * 0.06)
		var size: Vector2 = it["base_size"]
		q.mesh.size = Vector2(size.x * s, size.y * s)
		var mat := it["mat"] as StandardMaterial3D
		if mat != null:
			var bc: Color = it["base_color"]
			mat.albedo_color = Color(bc.r, bc.g, bc.b, bc.a * pow(gg, 0.6))


var _light_base_energy := 0.0


func _find_light(n: Node) -> OmniLight3D:
	if n is OmniLight3D:
		_light_base_energy = (n as OmniLight3D).light_energy
		return n as OmniLight3D
	for c in n.get_children():
		var r := _find_light(c)
		if r != null:
			return r
	return null

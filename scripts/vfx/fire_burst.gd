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

# ==================== 文件补充说明（职责 / 依赖 / 接口 / 坑） ====================
# 【所属系统】VFX 法术特效层（scripts/vfx/）。本节点通常是被法术脚本挂在某个位置下的
#   「特效实例」（推测），本身不主动销毁、不自己排队释放 —— 生命周期由外部施法逻辑管。
#   依据本文件内的注释（face_cards_to / randomize_cards 提到池子会被多次施法复用），
#   同一实例可能被反复复用，因此每次复用都要考虑朝向与 grow 的重置（推测）。
# 【关键依赖】
#   · res://assets/shaders/fire_flame.gdshader —— 焰卡着色器。shader 参数名必须与
#     _make_fire_material() / _apply_wind() 里写入的名字一致，改名要两边一起改。
#   · res://assets/textures/法术特效/龙卷风/T_FirePanningCyl45.png —— 火舌滚动贴图
#     （黑底、亮部是火舌），焰卡与核心辉光共用它。
#   · res://assets/textures/法术特效/Noise1_tiled.png —— 噪声扰动贴图（可平铺）。
#   · /root/Wind（自动加载，**可选**）—— 只读 cur_dir / cur_strength / cur_turbulence /
#     cur_speed 四个字段，用来让火焰随风倾倒。没有 Wind 时必须静默跳过、不许报错。
#   · 外部写入的节点属性：本文件不引用任何其它业务脚本，靠 @export 参数 + grow 变量解耦。
# 【主要对外接口】
#   · grow: float（0..1）—— 外部每帧写入的生长/熄灭系数，0=完全熄灭。
#   · face_cards_to(world_dir: Vector3, jitter_deg: float = 0.0) —— 把每张焰卡的大面
#     朝向世界水平方向（「火焰推进」的边界圈专用）。
#   · randomize_cards() —— 把朝向还原成随机（池化复用回内部填充时必须调用）。
#   · 场景内约定：需要有一个 OmniLight3D（点光）子节点，_ready 时会自动被找到并记录基准能量。
# 【已知的坑与注意事项】
#   · _ready 只能生效一次（_built 防重入）：_collect 会对位置做**累加**式贴地偏移，
#     重复执行会把整团火抬离地面，所以绝对不要在外部手动 call _ready()。
#   · 所有逐帧动画只允许写「焰卡网格节点本身」或「它的实例根」，**禁止写特效根节点**：
#     写根节点会和施法方对特效根做的整体缩放互相覆盖（实际踩过，缩放会在两个值之间乱跳）。
#   · 熄灭绝不能缩放特效根：焰卡绕中心围成一圈，缩放根会把它们往中心拉；这里改成逐卡缩小 + 变暗。
#   · 本文件是纯视觉脚本：不参与伤害/判定，不要在这里加玩法逻辑。
#   · 场景里的网格结构由 `tools/glb_split.py` 切 `火焰燃烧.glb` 得到，网格数/层数改了就同步改注释。

# ==================== 资源路径常量 ====================
## 焰卡着色器路径（ShaderMaterial 用）。加载失败时 _make_fire_material() 会 push_warning
## 并返回一个**没有 shader 的空材质**（火焰不可见但不崩），便于定位资源丢失。
const FIRE_SHADER := "res://assets/shaders/fire_flame.gdshader"
## 火舌滚动贴图：黑底 + 亮火舌，焰卡主色与被光片共用的都是它。
## 换图会同时改变焰卡的形状观感和核心辉光的颜色分布，不只是一张花纹。
const FIRE_TEX := "res://assets/textures/法术特效/龙卷风/T_FirePanningCyl45.png"
## 噪声扰动贴图：给火舌边缘做不规则扰动，避免每条火舌边缘过于干净、像贴纸。
const NOISE_TEX := "res://assets/textures/法术特效/Noise1_tiled.png"

# ==================== 导出参数（编辑器里可调） ====================
## 焰卡是否绕 Y 轴朝向相机。
## ★ 默认**关闭**：需求是"模型不要跟着角色视角旋转"，所以火焰保持自己的固定朝向。
@export var auto_billboard := false
## 每张焰卡的朝向是否在**生成时随机**（之后固定不动）。
## 随机角度让同一团火从任何角度看都有层次，也不会所有卡片都侧对着某个方向。
@export var random_yaw := true
## 纵向伸缩幅度（无量纲，正弦振幅）：1.0 表示纵向最大 ±11% 的呼吸。
## 调大 -> 火苗呼吸更夸张、更像在"喘"；调大到 0.3 以上会明显穿帮（穿地/穿顶）。
## 调小 -> 更接近静态图片。默认 0.11 是"看得出在动但不跳"的折中值。
@export var stretch_gain := 0.11        ## 纵向伸缩幅度（火焰呼吸）
## 亮度闪烁幅度（无量纲，正弦振幅，作用在 shader 的 brightness 上）。
## 默认 0.16：亮度在 ±16% 之间摆动，配合每卡不同的 flicker_freq 就像火焰在跳动。
## 调大 -> 更躁动、更"火急"；调过大（>0.5）会看出明暗闪屏感。
@export var flicker_gain := 0.16        ## 亮度闪烁幅度
## 波纹幅度（米，逐卡再随机一次）：随高度线性增强
## 调大 -> 火苗中段的横向摆动更明显（像被风推着抖动）；调太大（>0.2）火舌会散形。
## 实际写进材质时还会逐卡乘 randf_range(0.8, 1.25)，所以这里给的是**基准值**。
@export var ripple_amt := 0.05
## 卷曲幅度（米，逐卡再随机一次）：随高度平方增强
## 调大 -> 火舌末端卷得更弯、更有"舔舐"感；调太大（>0.3）末端会拧成麻花。
## 同样会在材质里逐卡乘 randf_range(0.8, 1.3) 做微随机。
@export var curl_amt := 0.10
## 左右摇摆幅度（弧度，作用在 node.rotation.z 的正弦振幅）：0.055 rad ≈ 3.2°。
## 调大 -> 火苗像被风吹得左右晃；调太大（>0.15）会看出整片火在"扇动"。
@export var sway_gain := 0.055          ## 左右摇摆幅度（弧度）
## 点光闪烁幅度（无量纲，倍率振幅）：0.45 表示亮度在基准值的 ±45% 之间摆动。
## 火光的"忽明忽暗"几乎全靠它；调到 0 火光就是常亮，火焰会显得很假。
@export var light_flicker := 0.45       ## 点光闪烁幅度
## 调大 -> 焰卡更亮、更容易过曝成白心（mix 混合下白心才有"热"的感觉）；
## 调小（<1.5）火焰会发灰、像半透明的橘色贴纸。每帧还会再乘生长系数与闪烁系数。
@export var brightness := 2.6           ## 基础亮度（mix 模式下要让核心过曝到白热，才有火焰感）

## ★★ 生长/熄灭系数：1.0 = 正常燃烧，0 = 完全熄灭。
##   熄灭**绝对不能去缩放特效根节点** —— 焰卡是围着中心摆成一圈的，
##   缩放根节点会把它们**往中心拉**（用户原话："火焰熄灭不要向中心靠拢"）。
##   这里改成**每张卡各自在原位缩小 + 变暗**，位置一动不动。
var grow := 1.0

# ==================== 运行时状态（运行时生成，不要手改） ====================
## 所有**焰卡**的记录表，_collect() 填充。每个元素是一个 Dictionary，字段：
##   node        : Node3D        —— 真正被写 scale/rotation 的节点（网格自己或其实例根）
##   mat         : ShaderMaterial —— 该卡独占的材质（每帧写 brightness / alpha_scale）
##   phase       : float         —— 相位偏移（_ready 里随机打散，避免所有火苗同步）
##   base_pos    : Vector3       —— 贴地后的原始位置（位置**不再被动画修改**，只作参照）
##   base_scale  : Vector3       —— 原始缩放，逐帧以它为基准重算（避免缩放逐帧累积漂移）
##   freq        : float         —— 纵向呼吸角频率（rad/s，1.6..3.8，逐卡随机；代码里直接乘 _t）
##   flicker_freq: float         —— 亮度闪烁角频率（rad/s，5.5..10.5，逐卡随机）
var _items: Array[Dictionary] = []
## 核心辉光光片（QuadMesh + 加色 StandardMaterial3D）的记录表，_build_core_glow() 填充。
## 字段：node / mat / base_pos / base_color / base_size / phase。
## 它们**不在** _items 里：辉光不呼吸、不摇摆，只做整体生灭与轻微脉动。
var _glows: Array[Dictionary] = []
## 场景里找到的第一个 OmniLight3D（火光）。找不到时为 null，_process 会跳过闪烁、不报错。
var _light: OmniLight3D = null
## 累计时间（秒），作为所有正弦的公共相位。**不用 delta 累加位置**，只做相位，
## 这样即使被暂停/池化重播，火苗也不会因为位置累加而漂移或跳变。
var _t := 0.0
## ★ 防重入：_collect 会**累加**贴地偏移，重复执行会把火焰抬离地面
##   （add_child 已经会触发 _ready；自检/工具里再手动 call 一次就会踩这个坑）
var _built := false


# ==================== 生命周期与构建 ====================
## 初始化（节点进入场景树时由引擎自动调用，全脚本只应真正跑一次）。
## 步骤（顺序敏感，不要调换）：
##   1) 递归找第一个 OmniLight3D，并把它的 light_energy 记为闪烁基准（写 _light_base_energy）；
##   2) _collect()：递归收集所有焰卡 -> 逐个贴地 + 每卡一份材质 + 随机朝向；
##   3) _build_core_glow()：在火心叠几张加色光片提高密度（**必须**在收集之后）；
##   4) 给每张卡分配互不相同的相位，避免同一份场景摆两处时所有火苗同步呼吸。
## 副作用：新增子节点 CoreGlow、改写焰卡网格的位置/朝向/材质、写 _light_base_energy。
## 注意：本函数会**累加**贴地偏移，所以用 _built 防止重入；外部工具不要手动 call 它。
func _ready() -> void:
	# 防重入：add_child 期间引擎已经自动调过一次 _ready，手动再 call 一次会把火抬离地面
	if _built:
		return
	_built = true
	# 先找灯：它只读场景、不影响后面的收集顺序
	_light = _find_light(self)
	# 再收集焰卡：这一步会把所有 MeshInstance3D 都当成焰卡，所以辉光必须等它之后
	_collect(self)
	# 最后建核心辉光（晚于 _collect，才不会被自己收进 _items）
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
	# 独立子节点承载光片：_collect 把「特效根之下的 MeshInstance3D」都当焰卡，
	# 挂在这里既便于将来整体开关/销毁，也说明它们不参与焰卡动画
	var holder := Node3D.new()
	holder.name = "CoreGlow"
	add_child(holder)
	# 固定 3 层：层数硬编码，多一层收益很小，但加色混合的 overdraw 成本线性增长
	for i in 3:
		var mat := StandardMaterial3D.new()
		# 不受光照 + 透明加色 + 始终朝相机 + 不接收阴影 = 标准「发光面片」配置
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
		# 尺寸随层号递减：光片自下而上收窄，火心呈锥形，而不是一根方形光柱
		qm.size = Vector2(2.7 - 0.55 * float(i), 2.3 - 0.45 * float(i))
		q.mesh = qm
		q.material_override = mat
		# 加色光片也会参与投影计算，地上可能留一块方形硬影，所以显式关掉（推测：原作者的意图）
		q.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(q)
		# 自下而上排布；最底层起始 0.85m ，略高于地面以免光片与地面相交出现硬边
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
##
## 参数 n：遍历起点（_ready 里传 self；递归时传子节点）。
## 返回值：无。副作用有四处：① 命中网格的材质被换成新的 ShaderMaterial（material_override）；
##   ② 立即对网格做**贴地**（按 AABB 最低点下移）；③ random_yaw 为真时写 rotation.y；
##   ④ 往 _items 追加一条动画记录（含 base_pos / base_scale，供 _process 每帧重算）。
## 调用时机：只在 _ready 里调用一次。重复调用会重复贴地、重复生成材质，所以外面有 _built 保护。
## 注意：判据是「节点类型是 MeshInstance3D」，因此挂在本特效下的任何 MeshInstance3D
##   都会被当成焰卡；要加纯装饰网格，必须挂在 _collect 之后（参考 _build_core_glow 的做法）。
func _collect(n: Node) -> void:
	# 纯深度优先遍历：glb 切片的层级不固定，不能假设焰卡只在第一层子节点
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
			# ★ 每个实例一份材质（刻意不复用）：贴图流速/运动倍率都逐卡随机，
			#   若共享同一份材质，整片火会完全同步（见 _make_fire_material 的注释）
			var mat := _make_fire_material()
			mi.material_override = mat
			# 半透明焰卡投影只会在地上留一块方形硬影，所以关掉
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
			# 命中焰卡后不再深入它的子节点：网格下面不会再挂焰卡，继续递归纯属浪费
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
	# 只取水平分量：焰卡只绕 Y 轴转，方向里的竖直分量对结果没有意义（例如从高处指向地面）
	var d := Vector3(world_dir.x, 0.0, world_dir.z)
	# 退化输入（方向为零）直接返回：否则归一化失败，atan2(0,0)=0 会把所有卡硬转到 +X
	if d.length_squared() < 1e-8:
		return
	d = d.normalized()
	# 负数当 0：抖动只能是"加噪"，不允许把负值当成反向语义
	var jit := deg_to_rad(maxf(jitter_deg, 0.0))
	for it in _items:
		var node := it["node"] as Node3D
		if node == null or not is_instance_valid(node):
			continue
		# 目标方向要换算到**卡的父空间**再求 yaw：父节点可能带地面倾斜或父级旋转
		var par := node.get_parent() as Node3D
		var pb: Basis = par.global_transform.basis.orthonormalized() if par != null else Basis.IDENTITY
		# 注意是 inverse()：世界方向 -> 父空间方向（正交基，逆=转置，成本很低）
		var u: Vector3 = pb.inverse() * d
		u.y = 0.0
		if u.length_squared() < 1e-8:
			continue
		u = u.normalized()
		var yaw := atan2(-u.z, u.x)
		if jit > 0.0:
			yaw += randf_range(-jit, jit)
		# 只写 rotation.y，不动 rotation.x/z —— 保证火苗仍然竖直向上，只是"大面"转了方向
		node.rotation.y = yaw


## ★ 把这一簇火的每张焰卡还原成**随机朝向**（= _collect 里 random_yaw 的行为）。
##   「火焰推进」的内部填充用它：池子会被多次施法复用，某簇上一次可能是边界圈
##   （已被 face_cards_to 写成整齐朝向），这一次回到内部必须重新随机，
##   否则内部会出现一整片方向一致的薄片（又薄又平、没有体积感）。
func randomize_cards() -> void:
	for it in _items:
		var node := it["node"] as Node3D
		if node != null and is_instance_valid(node):
			# 只重置 yaw：位置、缩放、相位都不动，避免误改其它动画状态
			node.rotation.y = randf() * TAU


## 网格在**父节点空间**中的包围盒最低点（把网格自身的旋转/缩放算进去）
##
## 参数 mi：要贴地的焰卡网格。返回值：AABB 的 8 个角点经 mi.transform 变换后的最小 y
##   （父空间坐标，单位米）；角点一个都没算出来时兜底返回 0.0，避免把 1e9 当成高度。
## 副作用：无（纯读）。调用时机：_collect() 判定「网格直接挂在特效根下」时使用。
## 注意：**不能**直接取 aabb.position.y —— 网格自带旋转/缩放时那不是真正的最低点，
##   必须逐个变换 8 个角点取最小，否则火焰会有一截插进地面或者整体悬空。
func _parent_bottom(mi: MeshInstance3D) -> float:
	var aabb := mi.mesh.get_aabb()
	var xf := mi.transform
	var lo := 1e9
	# i 的 3 个二进制位（1/2/4）分别决定 x/y/z 取 max 还是 min，正好枚举 AABB 的 8 个角点
	for i in range(8):
		var c := aabb.position + Vector3(
				aabb.size.x if (i & 1) != 0 else 0.0,
				aabb.size.y if (i & 2) != 0 else 0.0,
				aabb.size.z if (i & 4) != 0 else 0.0)
		lo = minf(lo, (xf * c).y)
	return lo if lo < 1e8 else 0.0


## 网格的世界空间 AABB 最低点（y）
##
## 与 _parent_bottom() 算法完全相同，唯一区别是用 global_transform —— 因为要贴地的
## 是「挂在实例根之下」的网格：给它减偏移时用的是**世界坐标 y**（见 _collect 的分支）。
## 参数 mi：焰卡网格。返回值：世界空间最低点 y（米；算不出角点时兜底 0.0）。副作用：无。
## 注意：本函数要求节点已在场景树中（global_transform 才有意义）—— _ready 里满足。
func _world_bottom(mi: MeshInstance3D) -> float:
	var aabb := mi.mesh.get_aabb()
	var xf := mi.global_transform
	var lo := 1e9
	# 同样遍历 8 个角点：世界空间下角点位置受所有祖先变换影响，更不能只读 aabb.position.y
	for i in range(8):
		var c := aabb.position + Vector3(
				aabb.size.x if (i & 1) != 0 else 0.0,
				aabb.size.y if (i & 2) != 0 else 0.0,
				aabb.size.z if (i & 4) != 0 else 0.0)
		lo = minf(lo, (xf * c).y)
	return lo if lo < 1e8 else 0.0


# ==================== 材质构建与风 ====================
## 为**单个**焰卡实例新建一份 ShaderMaterial（每次调用都新建，刻意不共享）。
##
## 返回值：ShaderMaterial。若 fire_flame.gdshader 加载失败，返回一个**没有 shader 的空材质**
##   （火焰不可见但不崩，并 push_warning，方便定位资源丢失）。
## 副作用：① 把贴图路径与逐卡随机的动效参数写进材质；② 把材质登记到 _flame_mats；
##   ③ 末尾调用 _apply_wind() 给这份新材质补一版当前风参数。
## 调用时机：_collect() 每命中一个焰卡网格调用一次（因此一张焰卡一份材质）。
## 注意事项：
##   · 贴图缺失时只是不写该参数，shader 用自己的默认值，不会报错；
##   · brightness 这里写的是 @export 基准值，_process 每帧会覆盖成「基准 × 闪烁 × 生长」；
##   · scroll_scale / motion_scale / ripple_amt / curl_amt 的逐卡随机是**刻意**的：
##     若所有焰卡参数相同，整片火会按同一节奏一起窜（用户反馈"过于有节奏感"）。
func _make_fire_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := load(FIRE_SHADER) as Shader
	# 缺 shader 时返回空材质：火焰看不见但不会崩，且日志里能立刻定位到资源问题
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
	# 先登记进 _flame_mats，再刷风：_apply_wind() 遍历的正是这个数组，顺序反了这份材质这帧没风
	_flame_mats.append(m)
	# 马上写一版风参数，否则新材质的第一帧还停在 shader 的默认风向上（看起来会突然一抖）
	_apply_wind()
	return m


## ★ 已生成的焰卡材质（每帧把天气风写进去 —— 火焰随风倾倒）
## 补充：本变量声明位置在 _make_fire_material() **之后**，但 GDScript 的类成员在函数体内
##   可直接引用、不需要前向声明，所以那里调用 _flame_mats.append() 是合法的。
##   数组只增不减（一张焰卡一份材质，数量固定），故没有清理逻辑；若将来支持运行时删焰卡，
##   记得同步从本数组里移除，否则 _process 会一直给已释放的材质写参数（有 is_instance_valid 兜住不崩）。
var _flame_mats: Array[ShaderMaterial] = []


## 读 Wind 自动加载的"当前风"（没有 Wind 时用兜底值，保证不报错）
##
## 把风的四个参数（方向/强度/湍流/速度）写给 _flame_mats 里的每份焰卡材质，让火焰随风倾倒。
## 参数：无。返回值：无。副作用：写所有焰卡材质的 shader 参数（每帧都写，很廉价）。
## 调用时机：① _make_fire_material() 末尾（给新材质补一版）；② _process() 每帧开头。
## 注意事项：
##   · 本函数**必须**能在没有 Wind 的情况下安静返回 —— 火焰只是不随风动，绝不 push 错误；
##   · 用 get("字段名") 而非直接属性访问，字段缺失时得到 null 也能被 float()/类型判断消化；
##   · 只有 cur_dir 有类型兜底（默认 +X）；其余三项缺失时按 0 处理，相当于"无风"（推测）。
func _apply_wind() -> void:
	var w: Node = null
	# 双重探测：Wind 既可能是 Engine 单例，也可能是 /root 下的自动加载节点，两种接法都兼容
	if Engine.has_singleton("Wind"):
		w = Engine.get_singleton("Wind")
	if w == null:
		w = get_node_or_null("/root/Wind")
	# 没有 Wind（纯特效预览场景常见）就什么也不做：火焰保持静止，不报错
	if w == null:
		return
	# cur_dir 缺失或类型不对时兜底为 +X 方向：保证着色器拿到的永远是合法 Vector2
	var dir: Vector2 = w.get("cur_dir") if w.get("cur_dir") is Vector2 else Vector2(1.0, 0.0)
	# 遍历全部焰卡材质（含本帧刚创建、已登记但还没进 _items 的那一份）
	for m in _flame_mats:
		if not is_instance_valid(m):
			continue
		m.set_shader_parameter("wind_dir", dir)
		m.set_shader_parameter("wind_strength", float(w.get("cur_strength")))
		m.set_shader_parameter("wind_turb", float(w.get("cur_turbulence")))
		m.set_shader_parameter("wind_speed", float(w.get("cur_speed")))


# ==================== 每帧动画 ====================
## 每帧驱动（引擎每帧自动调用）：刷风 -> 逐焰卡伸缩/摇摆/亮度 -> 点光闪烁 -> 核心辉光脉动。
##
## 参数 delta：本帧时长（秒）。**本函数实际没有使用它** —— 所有动画相位都基于累计时间 _t，
##   这样动画只由全局相位决定，池化重播/暂停恢复时不会残留位置累加误差。
## 返回值：无。副作用（都是视觉属性）：写焰卡节点的 scale 与 rotation.y/.z、写各焰卡材质的
##   brightness/alpha_scale、写点光的 light_energy、改辉光 QuadMesh 的 size 与 albedo_color。
## 调用时机：每帧（本脚本不做可见性早退；如果将来同屏特效数量很大，可考虑不可见时 set_process(false)）。
## 注意：本函数**只写焰卡节点自己 / 辉光网格自己**，绝不写特效根节点 ——
##   写根节点会和施法方对特效根做的整体缩放互相覆盖（实际踩过：缩放在两个值之间乱跳）。
func _process(delta: float) -> void:
	# 先刷风：本帧新建的焰卡材质也在此刻拿到风参数，否则它可能会用一帧默认风向
	_apply_wind()
	_t += delta
	# 相机每帧取一次（is_inside_tree 判断避免离树时 get_viewport 返回 null 报警）；
	# auto_billboard 默认 false，所以这个结果通常根本不会被用到
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
		# 横向倍数由纵向倍数反算（1/sqrt = 面积守恒的近似）：纵向拉长时横向收窄，
		# 火苗看起来是"在喘气"而不是被整体拉伸变形；max(st, 0.05) 防止 st 趋近 0 时除零爆掉
		var side := 1.0 / sqrt(max(st, 0.05))
		node.scale = Vector3(bs.x * side, bs.y * st, bs.z * side)

		# 2) 左右摇摆
		# 摇摆的角频率写死 1.9 rad/s：与呼吸 freq(1.6~3.8)、闪烁 flicker_freq(5.5~10.5) 错开，
		# 避免三个动作同拍（同拍会让整片火看起来像在"整体扇动"而不是各自烧）
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

	# is_instance_valid 双保险：池化复用/切场景时灯可能已经被释放，直接访问会报错
	if _light != null and is_instance_valid(_light):
		# 两个不成整数倍的正弦（8.3 与 21.7 rad/s）叠加：快慢两层闪，合成波形不重复、
		# 看不出明显周期，比单一正弦更像真火；0.35 让高频层只负责"细碎抖动"
		_light.light_energy = _light_base_energy * (1.0 + sin(_t * 8.3) * light_flicker
				+ sin(_t * 21.7) * light_flicker * 0.35)

	# 核心辉光：跟着 grow 一起生灭 + 轻微脉动
	# 辉光的生灭系数（含义与焰卡的 g 相同，这里为下面的循环单独再取一次）
	var gg := clampf(grow, 0.0, 1.0)
	for it in _glows:
		var q := it["node"] as MeshInstance3D
		if q == null or not is_instance_valid(q):
			continue
		var ph: float = it["phase"]
		# 光片跟着 grow 缩小（不是靠根节点缩放），保证熄灭时**不向中心靠拢**
		var s := gg * (1.0 + sin(_t * 2.6 + ph) * 0.06)
		var size: Vector2 = it["base_size"]
		# 直接改 QuadMesh 的 size，而不是缩 node.scale：_glows 的节点位置固定，
		# 改网格尺寸不会牵动节点层级/包围盒语义，也不会和别处写 scale 的逻辑打架
		q.mesh.size = Vector2(size.x * s, size.y * s)
		var mat := it["mat"] as StandardMaterial3D
		if mat != null:
			var bc: Color = it["base_color"]
			# alpha 用 pow(gg, 0.6)：与焰卡亮度走同一条衰减曲线，
			# 保证整团火是"一起变淡"而不是先缩小、最后突然变暗
			mat.albedo_color = Color(bc.r, bc.g, bc.b, bc.a * pow(gg, 0.6))


# ==================== 灯光查找（内部工具） ====================
## 点光的**基准能量**（OmniLight3D.light_energy 的原值）。
## 由 _find_light() 在 _ready 时从场景里的 OmniLight3D 抄下来，_process 的闪烁以它为倍率基准。
## 场景里没放灯时保持 0.0 —— 此时 _light 为 null，闪烁分支根本不执行，所以 0 不会引发异常。
var _light_base_energy := 0.0


## 递归查找本特效下的第一个 OmniLight3D（火焰的点光），并顺手记下它的基准能量。
##
## 参数 n：遍历起点（_ready 里传 self）。返回值：找到的 OmniLight3D；找不到返回 null。
## 副作用：**写 _light_base_energy**（只有真正命中灯时才写，没找到就保持 0）。
## 调用时机：只在 _ready 开头调用一次 —— 晚于此刻再加进来的灯不会被识别。
## 注意：
##   · 深度优先、命中即返回，因此场景里有多个灯时**只认第一个**；
##   · 记录基准能量的意义：让闪烁表现为「基准 × 系数」的倍率，
##     在编辑器里把灯调亮/调暗依然生效，不会被脚本写死成一个固定亮度。
func _find_light(n: Node) -> OmniLight3D:
	# 先抄基准能量再返回：_process 里的闪烁是「基准 × 系数」，基准只在这里取一次
	if n is OmniLight3D:
		_light_base_energy = (n as OmniLight3D).light_energy
		return n as OmniLight3D
	# 深度优先找第一个灯；本特效只有一盏灯，递归开销可以忽略
	for c in n.get_children():
		var r := _find_light(c)
		if r != null:
			return r
	return null

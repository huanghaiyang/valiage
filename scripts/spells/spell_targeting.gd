extends Node3D
## 通用法术施法区域选择器（不绑定任何具体法术）
##
## 用法（法术侧只需两件事）：
##   1. 法术实现 has_targeting() -> true  和  cast_at(center, radius) -> void
##   2. 配置表里给出 targeting 段（直径上下限、施法距离上下限、纹理）
## 施法器（spell_caster）会负责显示/隐藏它，并在鼠标按下时把 (center, radius) 交给法术。
##
## 交互：
##   · 鼠标在地图上移动 -> 圆圈跟着走
##   · 滚轮             -> 缩放（直径 diameter_min ~ diameter_max）
##   · 与主角的水平距离钳制在 range_min ~ range_max
##   · 鼠标按下         -> 发出 confirmed(center, radius)
##
## 贴合地形：圆盘网格的每个顶点都**从上方朝下打射线**落在真实表面上
##   （地形、台阶、地形上的物体都能贴住）—— 思路与「物体探测」法术一致。
##   只有位置/半径变化时才重建网格（脏标记），不是每帧重打射线。

signal confirmed(center: Vector3, radius: float)
signal cancelled()

const TEX_DEFAULT := "res://assets/textures/法术特效/kenney/particle-pack/circle_02.png"
const AREA_SHADER := "res://assets/shaders/spell_area.gdshader"
## ★ 扇形**独立**一套（独立节点 + 独立材质 + 独立着色器）：
##   圆盘材质是全局复用一份的，之前把两种形状做进同一个着色器会互相污染状态
##   （切回圆盘时圆圈被扇形的角度裁掉 -> 圆圈看不见）。独立就没有这个问题。
const SECTOR_SHADER := "res://assets/shaders/spell_sector.gdshader"
## ★ 扇形**物体表面叠加**用的着色器（复用【物体探测】探测波那套做法）
const SURFACE_SHADER := "res://assets/shaders/spell_sector_surface.gdshader"
## ★ 物体表面绘制的公共模块（和【物体探测】的描边/表面扫描带**共用同一份实现**）
const SurfaceOverlay := preload("res://scripts/spells/surface_overlay.gd")
## ★★ 临时 A/B 实验开关（定位"物体上为什么没白"，验完就删）：
##   true = 物体上挂【物体探测】自己的**表面扫描带**着色器（已知好用）。
##          墓碑上出现亮带 -> 挂载链路没问题，问题在我的扇面着色器；
##          仍然什么都没有 -> 问题在挂载写法，改成"逐物体材质 + next_pass"。
const DEBUG_MOUNT_SCAN_SHADER := false   ## 实验版已撤：物体恢复用本项目的扇形着色器
const SEGMENTS := 64          ## 圆周分段
const RINGS := 6              ## 圆盘径向分段（越大贴合越细）
## ★ 扇形径向分段：比圆盘密一倍（12 = 2×RINGS，**必须是 RINGS 的整数倍**：
##  扇形采样时圆盘的环正好是它的偶数子集 -> 一份采样喂两张网格，圆盘不多打射线）。
##  为什么要更密：坡度限幅下"一级最多爬 step 米"，环太稀时一块 1.6m 的石头只压到
##  一个环上 -> 扇面最高只能爬一个 step（实测 1.02m，石头顶 1.6m 盖不住）。
const SECTOR_RINGS := 12

## ---- 以下全部可由配置表覆盖 ----
var diameter_min := 5.0
var diameter_max := 10.0
var range_min := 1.0
var range_max := 12.0
var wheel_step := 0.4
## ---- 扇形模式（火焰推进）----
## mode = "sector"：圆心**锁在主角**，中轴跟随鼠标，滚轮改**张角**而不是半径。
var sector := false
## ★ 问题三定位用：把选点器的鼠标/圆心/半径打进 Output（默认开，定位完改 false）
const DEBUG_LOG_PREVIEW := true
var _dbg_hit_name := "(未命中)"
var _dbg_hit_pos := Vector3.ZERO
var _dbg_t := -1.0

## 诊断：打印每次 configure 生效的模式、以及滚轮改的到底是什么
@export var debug_targeting := true
var angle_min := 45.0
var angle_max := 80.0
var wheel_step_deg := 5.0
var radius_at_min := 10.0      ## 最小张角时的半径（数值表给的）
var radius_at_max := 6.0       ## 最大张角时的半径
var _angle := 45.0
## ★ 扇形内圈半径（米）：角色前留出的空白，扇形从这里才开始画（用户要求 0.5m）
@export var sector_inner_m := 0.5
var _axis := 0.0               ## 中轴方向（弧度）
var _tex_path_loaded := ""     ## 已加载的贴图路径（configure 会反复调用，避免重复 load）
var texture_path := TEX_DEFAULT
## ★ 顶点相对"圆心所在高度"最多抬高多少米。
##   不限制的话，圈边打到石墙/高台时整张圆盘会变成"贴着墙往上爬的布"。
var max_lift := 1.2
## ★ 平滑参数：上下限幅收窄 + 对高度图做多轮三点平均。
##   只限幅不平滑是不够的：相邻顶点一个在地面、一个在墙顶，仍会拉出**尖刺布帘**
##   （用户实测反馈"不规则物体表面显示过于严重，要平滑些"）。
var smooth_lift := 0.35
var smooth_drop := 0.35
## ★ 只认"能站的地面"：射线命中面的法线朝上程度低于这个值，就当作**没有地面**
##   （墙基、栏杆、树干都是竖直面）。不这么滤的话，圆盘会**顺着物体的立面铺上去**，
##   观感就是"圈选从物体表面穿过"（用户实测反馈）。
##   滤掉之后圆盘保持在低位，被物体挡住的部分由**深度测试**自然切断 —— 这才是地面指示圈该有的样子。
var ground_normal_min := 0.6
## ★ 相邻顶点允许的最大落差（米）。坡形靠它保住，尖刺靠它削平。
var slope_step := 0.22
var slope_passes := 4

## ★★ 扇形网格单独一套"贴哪"的参数（用户实测反馈：
##    "扇形选择器，没有在物体表面显示，只对地形有效"）。
##    圆盘那套是**有意**保持低位的（只认能站的地面 + 强平滑 -> 被物体挡住的部分
##    交给深度测试自然切断，见上面 ground_normal_min 的说明），所以**不去动圆盘**，
##    扇形自己一套参数：它得翻到石头/箱子顶上去，玩家才能看清整个扇面。
## 法线朝上程度 >= 这个值才算"表面"（0.35 ≈ 69° 以内的坡）；竖直面（墙/树干）不算。
var sector_normal_min := 0.35
## 扇形相对"圆心（角色脚下）高度"最多抬高多少米 —— 高墙/大树不该被扇面糊上去
var sector_lift_m := 6.0
## 扇形允许向下多少米（台阶、沟）
var sector_drop_m := 6.0
## 扇形的坡度限幅（米/级）与迭代次数。
## ★ 这里必须**允许台阶**：坡限是"相邻环最多差多少"，而石头的顶面比旁边地面高
##   1.6m —— 限到 0.9 时，压在石头上的那一环会被邻居拽下来，扇面只能在石头顶上
##   鼓一个"包"，石头把中间那块挡掉（实测：只能盖住一圈边框）。
##   2.5 的取法：1.6~2.5m 的石头/箱子/矮台**整块盖住**（每环最多抬 2.5m 够用），
##   而孤立细杆（只压到一环）最多鼓 2.5m —— 不会变成无限尖刺（另有 sector_lift_m 上限）。
var sector_slope_step := 2.5
var sector_slope_passes := 0

## ★ 扇形的**最小重建间隔**（秒）。扇形径向密一倍（12 级 = 832 根射线），
##   真实地形实测单次重建 ~13ms；而选点器是"鼠标一动就重建"，每帧都建会吃掉
##   大半个帧预算。28Hz 对地面指示器完全够用，平均到每帧反而比圆盘更便宜。
##   圆盘**不加**这个限制（保持原来的每帧刷新，观感一点不变）。
@export var sector_rebuild_interval := 0.035
## ★ 扇形地面的**填充分量**（加色混合，所以这个值就是"白层有多不透明"）。
##   为什么要调大：底下的深色泥土/湿土太深时，0.55 会让它透上来，看着像"中间没涂到"
##   （用户实测）。1.3 -> 深色地面也饱和成白；想更透就调回 0.7~0.9。
##   ★ 只影响扇形；圆盘（火焰灼烧）用的是另一份材质参数，观感不变。
@export var sector_fill_strength := 0.55
var _last_build := -1.0
var _last_surface := -1.0
## 物体表面叠加的最小刷新间隔（秒）：_rebuild_mesh 可能每帧被调
@export var surface_refresh_interval := 0.05

## ★ 地面贴合网格只打**地形层**（有 Terrain3D 时按类名找它的碰撞层；找不到就退回全层）。
##   为什么：物体表面交给下面的"表面叠加"处理（那是探测波的做法，任何朝向都准），
##   顶点高度场只用来铺地形 —— 不然物体立面会被拉出"裙边"、物体顶面还会被画两遍。
var terrain_layer_cache := 0
var _terrain_node: Node = null
var _terrain_owner: Node = null        ## 项目自己的地形封装（有 get_height_at）
## ★ 扇形"表面叠加"：给扇形范围内的**有碰撞体的物体**挂 material_overlay，
##   形状在片元里按世界坐标算 -> 石头顶/墙面/树干任何朝向都能画出扇面。
## ★ 贴合网格负责覆盖的**贴地物体高度上限**（米）：顶面不高于「脚下 + 这个值」的物体
##   由网格贴住（路面/石板/石棺底座这类矮台），更高的（墓碑/墙/桶）交给物体表面叠加。
##   ★ 这个值必须和 `_extract_rows` 的 prop_cap、以及叠加材质的「跳过贴地物体」阈值
##     **一致**，否则会出现「两边都不管」的空档（用户实测：石棺底座没覆盖到）。
@export var prop_cover_m := 0.6
@export var surface_scan := true
## 表面叠加查找物体用的碰撞层（默认全层；地形自己会被"是不是 Mesh 可视体"过滤掉）
@export var surface_mask := 0xFFFFFFFF
## ★ 物体表面**填充分量**（0 = 物体上只画边线/外弧，像【物体探测】的探测波亮带；
##   0.55 = 和地面那份一样铺满）。
##   为什么要能调：遗迹/墙面是**大面**，铺满时整块涂白、看着像"白斑"（用户实测反馈）；
##   ★ 现在由着色器**按表面朝向**分配：朝上的面按这个值填满（和地面连成一片），
##   立面保留 55%（墓碑/墙这类竖直面必须看得见，否则等于没涂 —— 用户实测）。
@export var surface_fill_strength := 0.5
## ★ 物体表面**边线强度**（两条边 + 外弧亮带；比地面稍强一点，物体上才看得清）
@export var surface_edge_strength := 2.4
## ★ 沿表面往上爬（搬自探测波 detect_scan 的 climb，那里默认 0.8，是它观感好的关键）：
##   越高处扇形的"到达半径"越小 -> 边界顺着立面往上收，像扫描波「爬上墙」，
##   而不是像投影一样平铺上去。0 = 关闭。
@export var surface_climb := 0.4
## ★ 掠射角增强（搬自探测波的 edge_boost）：从侧面看立面时更亮，轮廓才看得清。
@export var surface_edge_boost := 0.6
## ★ 相邻两环落差超过这个值（米）就在那里插一段**竖直裙边**，把地形台阶/突起处的
##   立面盖住（高度场连出来的斜边会钻到地形下面 -> 那一条露在外面）。
##   调小 = 更积极补面（也更容易在平缓起伏上多插面）；0 = 关闭。
@export var riser_threshold_m := 0.25
## 诊断开关：只打地形层采样（= 曾经把路面/石板这类"贴地物体"漏掉、扇面被切断的那个做法）。
## 只给自检/出图复现对照用，游戏里保持 false。
@export var terrain_only_sampling := false
var _surface_mat: ShaderMaterial = null
## ★ 挂/还原材质的活儿交给**公共模块**（【物体探测】的描边+扫描带用的是同一份）
var _surface := SurfaceOverlay.new()
var _overlaid: Dictionary = {}          ## 兼容旧调试脚本：直接读 _surface.entries

var _player: Node3D = null
var _cam: Camera3D = null
var _disc: MeshInstance3D = null
var _mat: ShaderMaterial = null
## ★ 扇形独立节点/材质（与圆盘互不影响，见 SECTOR_SHADER 注释）
var _sector_disc: MeshInstance3D = null
var _sector_mat: ShaderMaterial = null
var _radius := 2.5
var _center := Vector3.ZERO
var _active := false
var _dirty := true
var _has_center := false


func _ready() -> void:
	set_process(false)
	set_process_input(false)
	_build_disc()
	visible = false


func setup(player: Node3D, camera: Camera3D = null) -> void:
	_player = player
	_cam = camera


## 按配置表初始化（法术把 targeting 段原样传进来即可，别的法术也能用）
func configure(cfg: Dictionary) -> void:
	if cfg.is_empty():
		return
	sector = String(cfg.get("mode", "")) == "sector"
	angle_min = float(cfg.get("angle_min", angle_min))
	angle_max = float(cfg.get("angle_max", angle_max))
	wheel_step_deg = float(cfg.get("wheel_step_deg", wheel_step_deg))
	if wheel_step_deg <= 0.001:
		wheel_step_deg = 5.0        # 保险：配置漏了/写成 0 时不能让滚轮失灵
	radius_at_min = float(cfg.get("radius_at_min", radius_at_min))
	radius_at_max = float(cfg.get("radius_at_max", radius_at_max))
	if sector:
		_angle = clampf(_angle, minf(angle_min, angle_max), maxf(angle_min, angle_max))
	diameter_min = float(cfg.get("diameter_min", diameter_min))
	diameter_max = float(cfg.get("diameter_max", diameter_max))
	range_min = float(cfg.get("range_min", range_min))
	range_max = float(cfg.get("range_max", range_max))
	wheel_step = float(cfg.get("wheel_step", wheel_step))
	max_lift = float(cfg.get("max_lift", max_lift))
	texture_path = String(cfg.get("texture", texture_path))
	if _mat != null:
		# 只在贴图路径变化时重新 load（configure 会被反复调用，避免每帧加载 4K 纹理）
		if texture_path != _tex_path_loaded:
			var tex := load(texture_path) as Texture2D
			if tex != null:
				_mat.set_shader_parameter("area_tex", tex)
				_tex_path_loaded = texture_path
	if debug_targeting:
		print("[选点器] configure: mode=%s -> sector=%s | 张角=%.0f度(%.0f~%.0f) | 步长=%.0f | 半径=%.1f | 距离档=%.1f~%.1f" % [
				String(cfg.get("mode", "(未给)")), str(sector), _angle,
				minf(angle_min, angle_max), maxf(angle_min, angle_max), wheel_step_deg,
				_radius, diameter_min, diameter_max])
	if sector:
		_radius = _radius_from_angle()      # 扇形：半径由张角决定
	else:
		_radius = clampf(_radius, diameter_min * 0.5, diameter_max * 0.5)


## 张角 -> 半径（线性插值；两端值都来自数值表，不硬编码）
func _radius_from_angle() -> float:
	var span := angle_max - angle_min
	var k := 0.0 if absf(span) < 0.0001 else clampf((_angle - angle_min) / span, 0.0, 1.0)
	return clampf(lerpf(radius_at_min, radius_at_max, k), 0.5, range_max)


## 扇形张角（度）
func angle() -> float:
	return _angle


## 扇形半角（弧度）—— 交给法术
func half_angle() -> float:
	return deg_to_rad(_angle) * 0.5


## 扇形中轴方向（弧度，XZ 平面 atan2(z, x)）
func axis() -> float:
	return _axis


func begin() -> void:
	if _active:
		return
	_active = true
	visible = true
	# 默认圈在主角前方 range_min+2 米处，避免一开就是脚下
	if _player != null and is_instance_valid(_player) and not _has_center:
		var fwd := -(_player.global_transform.basis.z)
		fwd.y = 0.0
		_center = _player.global_position + fwd.normalized() * minf(range_min + 2.0, range_max)
		_has_center = true
	_dirty = true
	set_process(true)
	set_process_input(true)


func end() -> void:
	if not _active:
		return
	_active = false
	visible = false
	set_process(false)
	set_process_input(false)
	_restore_surface()               # ★ 选点结束：物体表面的扇形叠加必须摘干净
	# ★ 全屏面挂在**相机**下面（不是本节点的子节点），所以 visible = false 关不掉它 ——
	#   必须在结束/退出时显式隐藏，否则技能放出去之后白色扇形还留在屏幕上（用户报的 bug）。
	_hide_screen_pass()
	_hide_decal()


func is_active() -> bool:
	return _active


func center() -> Vector3:
	return _center


func radius() -> float:
	return _radius


func diameter() -> float:
	return _radius * 2.0


## 鼠标按下时由施法器调用：返回是否真的确认了
func confirm() -> bool:
	if not _active:
		return false
	confirmed.emit(_center, _radius)
	return true


# ---------------------------------------------------------------- 输入
func _input(ev: InputEvent) -> void:
	if not _active:
		return
	if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if sector:
				_set_angle(_angle + wheel_step_deg)
				if debug_targeting:
					print("[选点器] 滚轮↑ 张角 %.0f度（步长 %.0f，半径 %.1f）" % [_angle, wheel_step_deg, _radius])
			else:
				_set_diameter(diameter() + wheel_step)
				if debug_targeting:
					print("[选点器] 滚轮↑ 直径 %.1f（**圆盘模式**：扇形配置没生效）" % diameter())
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if sector:
				_set_angle(_angle - wheel_step_deg)
				if debug_targeting:
					print("[选点器] 滚轮↓ 张角 %.0f度（步长 %.0f，半径 %.1f，下限 %.0f度）" % [
							_angle, wheel_step_deg, _radius, angle_min])
			else:
				_set_diameter(diameter() - wheel_step)
			get_viewport().set_input_as_handled()


## 扇形模式：滚轮改**张角**，半径随之由数值表插值算出来
func _set_angle(a: float) -> void:
	a = clampf(a, minf(angle_min, angle_max), maxf(angle_min, angle_max))
	if absf(a - _angle) > 0.0001:
		_angle = a
		_radius = _radius_from_angle()
		_dirty = true


func _set_diameter(d: float) -> void:
	d = clampf(d, diameter_min, diameter_max)
	var r := d * 0.5
	if absf(r - _radius) > 0.0001:
		_radius = r
		_dirty = true


# ---------------------------------------------------------------- 每帧
func _process(_delta: float) -> void:
	if not _active:
		return
	if sector:
		_update_sector()
	else:
		# ★ 圆盘模式：只让圆盘可见（扇形节点隐藏）。
		#   扇形是独立材质 -> 不会再出现"圆圈被扇形的角度裁掉"那种污染（实测踩过）。
		if _disc != null:
			_disc.visible = not use_screen_pass      # 圆盘同样走屏幕空间覆盖
		if _sector_disc != null:
			_sector_disc.visible = false
		_update_screen_pass()                        # ★ 圆环（火焰灼烧）与扇形共用同一套
		# ★ 注意顺序：这里**不能**再隐藏 _sp_quad —— 上面刚由 _update_screen_pass() 打开，
		#   若在它之后又 visible = false，圆环就永远不显示（用户实测："圆环效果没有"）。
		#   关掉 use_screen_pass 时，_update_screen_pass() 自己会隐藏它。
		if _decal != null and is_instance_valid(_decal):
			_decal.visible = false       # 圆盘模式不显示扇形贴花
		_restore_surface()           # 切回圆盘：把物体表面的扇形叠加摘干净
		_update_center_from_mouse()
	if _dirty:
		# ★ 扇形：限流重建（见 sector_rebuild_interval）；圆盘 gap=0 = 每帧重建（原样）
		var gap: float = sector_rebuild_interval if sector else 0.0
		var now := Time.get_ticks_msec() * 0.001
		if now - _last_build >= gap:
			_dirty = false
			_last_build = now
			_rebuild_mesh()
			# 物体表面叠加：跟着重建一起刷新（球查询比逐顶点打射线便宜得多）
			if sector:
				_refresh_surface()
	if DEBUG_LOG_PREVIEW and _player != null and is_instance_valid(_player):
		var now_l := Time.get_ticks_msec() * 0.001
		if now_l - _dbg_t >= 0.25:
			_dbg_t = now_l
			var vp2 := get_viewport()
			var mp := vp2.get_mouse_position() if vp2 != null else Vector2.ZERO
			var pp := _player.global_position
			print("[选点] %s 鼠标=(%.0f,%.0f)px 命中=%s@(%.2f,%.2f,%.2f) 圆心=(%.2f,%.2f,%.2f) 半径=%.2f 角色=(%.2f,%.2f,%.2f) 圆心高于角色=%.2fm 张角=%.0f°"
					% ["圆盘" if not sector else "扇形", mp.x, mp.y, _dbg_hit_name,
					_dbg_hit_pos.x, _dbg_hit_pos.y, _dbg_hit_pos.z,
					_center.x, _center.y, _center.z, _radius,
					pp.x, pp.y, pp.z, _center.y - pp.y, rad_to_deg(half_angle()) * 2.0])


## 扇形：**圆心锁在主角脚下**，中轴指向鼠标（水平方向），半径由张角插值算出
func _update_sector() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var vp := get_viewport()
	if _cam == null or not is_instance_valid(_cam):
		_cam = vp.get_camera_3d() if vp != null else null
	var p := _player.global_position
	var new_axis := _axis
	if _cam != null and vp != null:
		var mouse := vp.get_mouse_position()
		var from := _cam.project_ray_origin(mouse)
		var dirn := _cam.project_ray_normal(mouse)
		# 与"主角所在水平面"求交 -> 鼠标的地面落点 -> 中轴方向
		if absf(dirn.y) > 0.0001:
			var t := (p.y - from.y) / dirn.y
			if t > 0.0:
				var hit := from + dirn * t
				var flat := Vector3(hit.x - p.x, 0.0, hit.z - p.z)
				if flat.length() > 0.05:
					new_axis = atan2(flat.z, flat.x)
	# ★ 扇形参数写到**独立的扇形材质**上（圆盘材质完全不碰 -> 不会被污染）
	#   每帧都写：滚轮改张角时中心/中轴都没变，写在条件里就不会实时生效（实测）
	if _sector_disc != null:
		_sector_disc.visible = not (use_decal or use_screen_pass)   # 有贴花/屏幕覆盖时不用贴合网格
	if _disc != null:
		_disc.visible = false
	# ★ 屏幕空间覆盖：逐像素判定 -> "扫到就变白"（不管是什么物体、多大）
	_update_screen_pass()
	if not use_screen_pass:
		_update_decal()
	if _decal != null and is_instance_valid(_decal) and use_screen_pass:
		_decal.visible = false
	if _sector_mat != null:
		_sector_mat.set_shader_parameter("axis", new_axis)
		_sector_mat.set_shader_parameter("half_angle", half_angle())
		_sector_mat.set_shader_parameter("inner",
				clampf(sector_inner_m / maxf(_radius, 0.01), 0.0, 0.85))
		_sector_mat.set_shader_parameter("fill_strength", sector_fill_strength)
		_sector_mat.set_shader_parameter("edge_strength", 2.2)
	# ★ 物体表面的扇面：每帧写一次参数（形状是 uniforms，改角度/半径立刻生效，不用重建）
	if _surface_mat != null and not _overlaid.is_empty():
		_surface_mat.set_shader_parameter("axis", new_axis)
		_surface_mat.set_shader_parameter("half_angle", half_angle())
		_surface_mat.set_shader_parameter("radius", _radius)
		_surface_mat.set_shader_parameter("sector_center", _center)
		_surface_mat.set_shader_parameter("inner_m", sector_inner_m)
		_surface_mat.set_shader_parameter("fill_strength", surface_fill_strength)
		_surface_mat.set_shader_parameter("edge_strength", surface_edge_strength)
		_surface_mat.set_shader_parameter("rim_strength", surface_edge_strength * 0.7)
		_surface_mat.set_shader_parameter("climb", surface_climb)
		_surface_mat.set_shader_parameter("edge_boost", surface_edge_boost)
	if p.distance_to(_center) > 0.01 or absf(new_axis - _axis) > 0.001:
		_center = p
		_axis = new_axis
		_dirty = true


## 鼠标 -> 世界落点（打射线到地形/物体；打不到就落在一个水平面上）
func _update_center_from_mouse() -> void:
	var vp := get_viewport()
	if vp == null or _player == null or not is_instance_valid(_player):
		return
	if _cam == null or not is_instance_valid(_cam):
		_cam = vp.get_camera_3d()
	if _cam == null:
		return
	var mouse := vp.get_mouse_position()
	var from := _cam.project_ray_origin(mouse)
	var dir := _cam.project_ray_normal(mouse)
	var plane_y := _player.global_position.y
	var world := get_world_3d()
	var pos := Vector3.ZERO
	var ok := false
	if world != null:
		var far := from + dir * 400.0
		var q := PhysicsRayQueryParameters3D.create(from, far)
		q.collision_mask = 0xFFFFFFFF
		q.exclude = [_player.get_rid()] if _player is CollisionObject3D else []
		var hit := world.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			pos = hit["position"]
			ok = true
			# ★ 圆环中心**落到地面**：XZ 用鼠标命中点（指哪打哪），y 取该处地形高度。
			#   之前圆心直接取命中点高度 -> 鼠标打到围栏上时圆心飘到 3m 高空（实测），
			#   日志与调试都被误导。
			var gh := _terrain_visual_height(pos.x, pos.z)
			if not is_nan(gh):
				pos.y = gh
			elif _player != null and is_instance_valid(_player):
				pos.y = _player.global_position.y
			if DEBUG_LOG_PREVIEW:
				var col = hit.get("collider")
				_dbg_hit_name = String((col as Node).name) if col is Node else "(无)"
				_dbg_hit_pos = hit["position"]
	if not ok:
		# 没打到地形：与"主角脚下的水平面"求交
		if absf(dir.y) < 0.0001:
			return
		var t := (plane_y - from.y) / dir.y
		if t <= 0.0:
			return
		pos = from + dir * t
	# ★ 施法距离钳制（距主角的水平距离）
	var p := _player.global_position
	var flat := Vector3(pos.x - p.x, 0.0, pos.z - p.z)
	var d := flat.length()
	if d > range_max:
		flat = flat.normalized() * range_max
	elif d < range_min:
		flat = (flat.normalized() if d > 0.0001 else Vector3.FORWARD) * range_min
	_center = Vector3(p.x + flat.x, pos.y, p.z + flat.z)
	_dirty = true


# ---------------------------------------------------------------- 网格
func _build_disc() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "AreaDisc"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mat = ShaderMaterial.new()
	var sh := load(AREA_SHADER) as Shader
	if sh != null:
		_mat.shader = sh
		var tex := load(texture_path) as Texture2D
		if tex != null:
			_mat.set_shader_parameter("area_tex", tex)
	mi.material_override = _mat
	add_child(mi)
	_disc = mi
	_build_sector()


## ★ 扇形：独立节点 + 独立材质（和圆盘互不影响）
func _build_sector() -> void:
	var mi := MeshInstance3D.new()
	mi.name = "AreaSector"
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sector_mat = ShaderMaterial.new()
	var sh := load(SECTOR_SHADER) as Shader
	if sh != null:
		_sector_mat.shader = sh
	mi.material_override = _sector_mat
	mi.visible = false
	add_child(mi)
	_sector_disc = mi


## 重建两张贴合网格（**各用各的采样/平滑参数**）：
##   · 圆盘（火焰灼烧那种圆）：只认能站的地面 + 强平滑 —— 保持低位，被物体挡住的部分
##     由深度测试自然切断（用户之前明确要的观感，别动）。
##   · 扇形（火焰推进）：要**铺到物体表面上** —— 更宽松的法线阈值 + 更大的抬升上限 +
##     松得多的坡度限幅，让扇面翻到石头/箱子顶上；仍会削掉极端尖刺。
func _rebuild_mesh() -> void:
	if use_screen_pass:
		return          # 屏幕空间覆盖模式下不需要贴合网格（扇形/圆盘都走全屏面）
	if _disc == null:
		return
	# 只在自己这一套模式下才采高分辨率：圆盘模式仍按 RINGS 采（不额外打射线）
	var hi: int = SECTOR_RINGS if sector else RINGS
	var stride: int = maxi(hi / RINGS, 1)
	var raw := _sample_heights(hi)        # ★ 只采一次，两个网格各自筛
	var y0 := _center.y
	_disc.mesh = _build_area_mesh(_smooth_heights(
			_extract_rows(raw, y0, ground_normal_min, stride), y0), RINGS)
	if _sector_disc != null and not use_decal:
		# 扇形用**全部**环（stride=1），圆盘只用它的偶数子集（stride）
		var sec_rows := _smooth_heights(
				_extract_rows(raw, y0, sector_normal_min, 1, true, prop_cover_m), y0,
				sector_lift_m, sector_drop_m, sector_slope_step, sector_slope_passes, false)
		# ★ 落差大的地方插竖直裙边：高度场连出来的斜边会钻到地形下面，
		#   台阶/突起处那一条就露在外面（用户实测："中间地面与突起处衔接地带没有覆盖到"）
		_sector_disc.mesh = _build_skirt_mesh(
				_rows_with_skirts(sec_rows, hi, riser_threshold_m), 0.05)
	# ★★ 物体表面叠加**必须挂在这里**：选点器的形状由本函数决定，谁重建网格谁就负责
	#    刷新物体表面。以前我只把它挂在 _process 的 _dirty 门后面 —— 那道门没开时
	#    网格照建、物体却一直没挂上（用户实测："地面白了，石棺/墓碑还是没白"）。
	#    探测波之所以没这个问题：它的挂载是 _detect() 的**直接结果**，没有第二道门。
	if sector:
		_refresh_surface()


## 把采样结果按"表面阈值"抽成高度图（hit 且法线够朝上 -> 用命中高度；否则退回基准高度）
## stride > 1 时按步长取环（圆盘从扇形的高分辨率采样里取自己的那几环）
func _extract_rows(raw: Array, y0: float, min_up: float, stride := 1,
		terrain_aware := false, prop_cap := 0.35) -> Array:
	var out: Array = []
	var ring := 0
	while ring < raw.size():
		var src: Array = raw[ring]
		var row := PackedFloat32Array()
		row.resize(SEGMENTS)
		for s in range(SEGMENTS):
			var e: Dictionary = src[s]
			if not bool(e["hit"]) or float(e["ny"]) < min_up:
				row[s] = y0
			elif terrain_aware and not bool(e["terrain"]):
				# ★ 兜底：拿不到地形高度数据时（合成自检等），物体命中按"贴地"处理
				#   （限幅 ±prop_cap）。真实场景走不到这里 —— 见 _sample_heights 里
				#   "不论命中什么都取该 XZ 的地形视觉高度"那一段。
				row[s] = clampf(float(e["y"]), y0 - prop_cap, y0 + prop_cap)
			else:
				row[s] = float(e["y"])
		out.append(row)
		ring += maxi(stride, 1)
	return out


## 由高度图建三角面（顶点是**世界坐标**，节点本身不带变换）
func _build_area_mesh(rows: Array, rings: int, lift := 0.02) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var uv_of = func(rr: float, ss: int) -> Vector2:
		var a := float(ss) / float(SEGMENTS) * TAU
		return Vector2(0.5 + cos(a) * 0.5 * rr, 0.5 + sin(a) * 0.5 * rr)
	var pv = func(ring: int, s: int) -> Vector3:
		var rr := float(ring) / float(maxi(rings, 1))
		var a := float(s % SEGMENTS) / float(SEGMENTS) * TAU
		var x := _center.x + cos(a) * _radius * rr
		var z := _center.z + sin(a) * _radius * rr
		# 抬高一点点，避免与地面 z-fighting
		return Vector3(x, (rows[ring] as PackedFloat32Array)[s % SEGMENTS] + lift, z)
	for ring in range(rings):
		# ★ UV 半径也必须按**本网格的级数**算（不是常量 RINGS）：扇形是 12 级，
		#   写成 ring/RINGS 会让最外圈的 UV 半径到 1.83 —— 着色器按 UV 裁形状，
		#   于是扇面只有内半截可见（实测踩过）。
		var rr0 := float(ring) / float(maxi(rings, 1))
		var rr1 := float(ring + 1) / float(maxi(rings, 1))
		for s in range(SEGMENTS):
			var s2 := (s + 1) % SEGMENTS
			st.set_uv(uv_of.call(rr0, s))
			st.add_vertex(pv.call(ring, s))
			st.set_uv(uv_of.call(rr1, s))
			st.add_vertex(pv.call(ring + 1, s))
			st.set_uv(uv_of.call(rr1, s2))
			st.add_vertex(pv.call(ring + 1, s2))
			st.set_uv(uv_of.call(rr0, s))
			st.add_vertex(pv.call(ring, s))
			st.set_uv(uv_of.call(rr1, s2))
			st.add_vertex(pv.call(ring + 1, s2))
			st.set_uv(uv_of.call(rr0, s2))
			st.add_vertex(pv.call(ring, s2))
	return st.commit()


## ★ 由"带半径的行"建三角面：rows = [{r: 0..1 归一化半径, h: PackedFloat32Array(SEGMENTS)}]
##
## 和 _build_area_mesh 的区别：半径是**每行自带**的，因此可以在同一个半径处放**两行**
## 不同的高度 -> 形成**竖直裙边**。
## 为什么需要它：高度场网格的顶点只能上下动，遇到**地形台阶/竖直落差**时，相邻两环之间
## 只能连出一条斜边，斜边会钻到地形下面 -> 台阶那一条就露在外面没被涂到
## （用户实测："中间地面与突起处衔接地带没有覆盖到"）。
## 在落差处插入一段竖直面把台阶盖住即可。
func _build_skirt_mesh(rows2: Array, lift: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var uv_of = func(rr: float, ss: int) -> Vector2:
		var a := float(ss) / float(SEGMENTS) * TAU
		return Vector2(0.5 + cos(a) * 0.5 * rr, 0.5 + sin(a) * 0.5 * rr)
	var pv = func(j: int, s: int) -> Vector3:
		var e: Dictionary = rows2[j]
		var rr := clampf(float(e["r"]), 0.0, 1.0)
		var hs: PackedFloat32Array = e["h"]
		var a := float(s % SEGMENTS) / float(SEGMENTS) * TAU
		return Vector3(_center.x + cos(a) * _radius * rr,
				hs[s % SEGMENTS] + lift,
				_center.z + sin(a) * _radius * rr)
	for j in range(rows2.size() - 1):
		var rr0 := clampf(float((rows2[j] as Dictionary)["r"]), 0.0, 1.0)
		var rr1 := clampf(float((rows2[j + 1] as Dictionary)["r"]), 0.0, 1.0)
		for s in range(SEGMENTS):
			var s2 := (s + 1) % SEGMENTS
			st.set_uv(uv_of.call(rr0, s))
			st.add_vertex(pv.call(j, s))
			st.set_uv(uv_of.call(rr1, s))
			st.add_vertex(pv.call(j + 1, s))
			st.set_uv(uv_of.call(rr1, s2))
			st.add_vertex(pv.call(j + 1, s2))
			st.set_uv(uv_of.call(rr0, s))
			st.add_vertex(pv.call(j, s))
			st.set_uv(uv_of.call(rr1, s2))
			st.add_vertex(pv.call(j + 1, s2))
			st.set_uv(uv_of.call(rr0, s2))
			st.add_vertex(pv.call(j, s2))
	return st.commit()


## 把高度图转成"带半径的行"，并在**落差大的地方插入竖直裙边**。
## rows 来自 _extract_rows（行数 = rings + 1，半径均匀分布）。
func _rows_with_skirts(rows: Array, rings: int, threshold: float) -> Array:
	var out: Array = []
	var n := rows.size()
	for i in range(n):
		var rf := float(i) / float(maxi(rings, 1))
		var cur: PackedFloat32Array = rows[i]
		if i > 0 and threshold > 0.0:
			var prev: PackedFloat32Array = rows[i - 1]
			var jump := false
			for s in range(SEGMENTS):
				if absf(cur[s] - prev[s]) > threshold:
					jump = true
					break
			if jump:
				# 把上一圈的高度延伸到这一圈的半径处 -> 竖直面（台阶的立面）被盖住
				var wall := PackedFloat32Array()
				wall.resize(SEGMENTS)
				for s in range(SEGMENTS):
					wall[s] = prev[s]
				out.append({"r": rf, "h": wall})
		out.append({"r": rf, "h": cur})
	return out


## 命中面算不算"能站的地面"（纯函数，便于自检）
##   法线朝上程度 >= ground_normal_min 才算地面；竖直面（墙/栏杆/树干）一律不算。
func _is_ground(hit: Dictionary) -> bool:
	if not hit.has("normal"):
		return true
	return (hit["normal"] as Vector3).normalized().y >= ground_normal_min


## 地形所在的碰撞层：**运行时按类名找**（含 terrain 的节点下第一个碰撞体）。
## 与【物体探测】里的同名做法一致：不写死层号（改层了也不会静默失效）。
func _terrain_layer() -> int:
	if terrain_layer_cache != 0:
		return terrain_layer_cache
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return 0
	var stack: Array = [tree.current_scene]
	while not stack.is_empty():
		var n := stack.pop_back() as Node
		if n == null:
			continue
		var nm := String(n.name).to_lower()
		if String(n.get_class()).to_lower().contains("terrain") or nm.contains("terrain"):
			_terrain_node = n
			var found := _first_collision_layer(n)
			if found != 0:
				terrain_layer_cache = found
				return found
		for c in n.get_children():
			stack.append(c)
	return 0


## ★ 地形的**视觉高度**。
## 优先复用**项目自己的地形封装** `scripts/world/terrain.gd` 的 `get_height_at()`
## （内部处理 Terrain3D 与非 Terrain3D 的降级，和 main.gd / camera_rig.gd 用的是同一套），
## 找不到时才退回直接读 Terrain3D 的 `data.get_height`。
##
## 为什么不用射线高度：射线打在**碰撞体**上，Terrain3D 的碰撞与视觉地形有细微偏差，
## 网格就会被视觉地形一片片戳穿（用户实测："扇形中间部分区域还是没有被涂白"，
## 放大看边界是撕裂状）。用高度数据就完全对齐了。
## 都拿不到时返回 NAN，调用方退回射线高度。
func _terrain_visual_height(x: float, z: float) -> float:
	# ① 项目的地形封装（duck-typing：有 get_height_at 就用它）
	if _terrain_owner == null or not is_instance_valid(_terrain_owner):
		_terrain_owner = _find_terrain_owner()
	if _terrain_owner != null and _terrain_owner.has_method("get_height_at"):
		return float(_terrain_owner.call("get_height_at", x, z))
	# ② 退回 Terrain3D 自己的数据
	var t := _terrain_node
	if t == null or not is_instance_valid(t):
		_terrain_layer()               # 顺便把 Terrain3D 节点找出来并缓存
		t = _terrain_node
	if t == null or not is_instance_valid(t):
		return NAN
	var d: Variant = t.get("data")
	if d == null or not (d as Object).has_method("get_height"):
		return NAN
	return float((d as Object).call("get_height", Vector3(x, 0.0, z)))


## 找"项目自己的地形封装"（类名/节点名含 terrain 且提供了 get_height_at 的节点）
func _find_terrain_owner() -> Node:
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	var stack: Array = [tree.current_scene]
	while not stack.is_empty():
		var n := stack.pop_back() as Node
		if n == null:
			continue
		var nm := String(n.name).to_lower()
		if (String(n.get_class()).to_lower().contains("terrain") or nm.contains("terrain")) \
				and n.has_method("get_height_at"):
			return n
		for c in n.get_children():
			stack.append(c)
	return null


func _first_collision_layer(from_node: Node) -> int:
	var stack: Array = [from_node]
	var guard := 0
	while not stack.is_empty() and guard < 4000:
		guard += 1
		var n := stack.pop_back() as Node
		if n == null:
			continue
		if n is CollisionObject3D:
			return (n as CollisionObject3D).collision_layer
		for c in n.get_children():
			stack.append(c)
	return 0


## 采样：外层环逐顶点朝下打射线（内圈半径 0 = 圆心高度）。
## 返回 rows[ring][s] = {"hit": bool, "y": float, "ny": float}（ny = 命中面法线的朝上程度）
##   —— **只采一次**，圆盘/扇形各按自己的阈值筛（见 _extract_rows），不重复打射线。
## 射线排除施法者自己：扇形圆心就在角色脚下，别把角色当成"物体表面"爬上去。
func _sample_heights(rings: int = RINGS) -> Array:
	var world := get_world_3d()
	var y0 := _center.y
	var exclude: Array = []
	if _player is CollisionObject3D:
		exclude = [(_player as CollisionObject3D).get_rid()]
	var rows: Array = []
	# ★ 复用同一个查询对象（只改 from/to）：一次重建最多 832 根射线，
	#   每根都 create 一个 PhysicsRayQueryParameters3D 是白白的分配开销。
	var q := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.ZERO)
	# ★ 打**全层**：地形、台阶、路面/石板这些"贴地物体"都要贴上（它们会把扇面挡住）。
	#   高物体（石头/墙/遗迹）由上面的口径（±0.35m 限幅）自然忽略 -> 交给"表面叠加"。
	var tl := _terrain_layer()
	q.collision_mask = tl if (terrain_only_sampling and tl != 0) else 0xFFFFFFFF
	q.exclude = exclude
	for ring in range(rings + 1):
		var rr := float(ring) / float(maxi(rings, 1))
		var row: Array = []
		row.resize(SEGMENTS)
		for s in range(SEGMENTS):
			var e := {"hit": false, "y": y0, "ny": 0.0, "terrain": false}
			if ring > 0 and world != null:
				var a := float(s) / float(SEGMENTS) * TAU
				var x := _center.x + cos(a) * _radius * rr
				var z := _center.z + sin(a) * _radius * rr
				q.from = Vector3(x, y0 + 12.0, z)
				q.to = Vector3(x, y0 - 60.0, z)
				var hit := world.direct_space_state.intersect_ray(q)
				if not hit.is_empty():
					e["hit"] = true
					e["y"] = (hit["position"] as Vector3).y
					e["ny"] = (hit.get("normal", Vector3.UP) as Vector3).normalized().y
					var col: Variant = hit.get("collider")
					if tl != 0 and col is CollisionObject3D:
						e["terrain"] = ((col as CollisionObject3D).collision_layer & tl) != 0
					# ★ 不论命中地形还是物体，都取该 XZ 的**地形视觉高度**：
					#   · 命中地形：它比碰撞体高度准（视觉/碰撞有偏差）；
					#   · 命中物体：它就是"这个物体下面的地形"。
					#   于是**地面网格只铺地形**，绝不和物体顶面互相戳穿
					#   （用户实测"一块白一块不白"就是网格与物体在阈值处穿模）；
					#   物体表面一律交给"物体表面叠加"——分工按**类型**，不按高度。
					var tvh := _terrain_visual_height(x, z)
					if not is_nan(tvh):
						e["y"] = tvh
						e["terrain"] = true
			row[s] = e
		rows.append(row)
	return rows


## 限幅 + 平滑（**纯函数**：只吃高度图，自检直接喂人造尖刺/斜坡验证）
##   ① 硬限幅：把"墙顶 / 深沟"这种大落差压进 lift / drop
##   ② **坡度限幅**：相邻顶点落差不超过 step，迭代若干轮。
##      这一步才是关键：它**保住整体坡形**（缓坡每级差一点，始终合法），
##      只把"一级跳 3 米"的尖刺一级一级削下来 -> 不再拉出尖刺布帘。
##   ③ 一轮**轻量**三点平均：把削出来的棱角抹圆（幅度小，不会抹掉坡形）
##   ★ 不要用"多轮重度平均"来做平滑：实测 3 轮 4 点平均会把 3 米尖刺压成 0.000，
##     整张盘变成完全平坦 —— 那样就不"适配地形"了。
## lift/drop/step/passes 默认 <0 = 用圆盘那一套（保持原来的行为与自检口径）；
## 扇形传自己的一套（见 sector_* 参数）。
func _smooth_heights(rows: Array, y0: float, lift := -1.0, drop := -1.0,
		step := -1.0, passes := -1, circle := true) -> Array:
	var up_lim: float = smooth_lift if lift < 0.0 else lift
	var dn_lim: float = smooth_drop if drop < 0.0 else drop
	var st: float = slope_step if step < 0.0 else step
	var np: int = maxi(slope_passes if passes < 0 else passes, 0)
	var n := rows.size()
	# ① 硬限幅
	var cur: Array = []
	for ring in range(n):
		var src: PackedFloat32Array = rows[ring]
		var capped := PackedFloat32Array()
		capped.resize(SEGMENTS)
		for s in range(SEGMENTS):
			capped[s] = clampf(src[s], y0 - dn_lim, y0 + up_lim)
		cur.append(capped)
	# ② 坡度限幅
	for pass_i in range(np):
		var nxt: Array = []
		for ring in range(n):
			var row: PackedFloat32Array = cur[ring]
			var out := PackedFloat32Array()
			out.resize(SEGMENTS)
			for s in range(SEGMENTS):
				if ring == 0:
					out[s] = y0                 # 圆心一圈钉住
					continue
				var l := row[(s - 1 + SEGMENTS) % SEGMENTS]
				var r := row[(s + 1) % SEGMENTS]
				var lo := minf(l, r) - st
				var hi := maxf(l, r) + st
				if ring < n - 1:
					var up: PackedFloat32Array = cur[ring - 1]
					var dn: PackedFloat32Array = cur[ring + 1]
					lo = maxf(lo, minf(up[s], dn[s]) - st)
					hi = minf(hi, maxf(up[s], dn[s]) + st)
				out[s] = clampf(row[s], lo, hi)
			nxt.append(out)
		cur = nxt
	# ③ 轻量抹圆（只沿圆周，一轮）
	#   ★ 扇形**不做这一步**：抹圆会把顶点拉向圆周邻居的平均值 -> 凸起处网格沉到
	#     视觉地形下面 -> 地形把扇面戳穿（用户实测："扇形中间部分区域还是没有被涂白"）。
	#     地形本身是连续的、不会出尖刺，所以扇形不需要靠平滑兜底。
	if not circle:
		return cur
	var fin: Array = []
	for ring in range(n):
		var row2: PackedFloat32Array = cur[ring]
		var out2 := PackedFloat32Array()
		out2.resize(SEGMENTS)
		for s in range(SEGMENTS):
			if ring == 0:
				out2[s] = y0
				continue
			var l2 := row2[(s - 1 + SEGMENTS) % SEGMENTS]
			var r2 := row2[(s + 1) % SEGMENTS]
			out2[s] = (l2 + r2 + row2[s] * 2.0) / 4.0
		fin.append(out2)
	return fin


# ---------------------------------------------------------------- 扇形：物体表面叠加
## 把扇面画到**物体自己的表面**上（material_overlay + 世界坐标算形状）——
## 这是【物体探测】探测波的做法：任何朝向的表面都能贴住，不受"顶点高度场"限制。
## 只给**有碰撞体的物体**挂（石头/箱子/房子/树），并在离开范围、切回圆盘、
## 选点结束时**逐个还原**原来的 material_overlay（绝不能留在物体上）。
func _ensure_surface_mat() -> ShaderMaterial:
	if _surface_mat != null:
		return _surface_mat
	_surface_mat = ShaderMaterial.new()
	var sh := load(SURFACE_SHADER) as Shader
	if DEBUG_MOUNT_SCAN_SHADER:
		sh = load("res://assets/shaders/detect_scan.gdshader") as Shader
	if sh == null:
		push_warning("[选点器] 缺少 spell_sector_surface.gdshader，扇形不会画在物体表面")
		return _surface_mat
	_surface_mat.shader = sh
	# ★ 物体上默认"只勾边不铺满"（见 surface_fill_strength 的说明）
	_surface_mat.set_shader_parameter("fill_strength", surface_fill_strength)
	_surface_mat.set_shader_parameter("edge_strength", surface_edge_strength)
	_surface_mat.set_shader_parameter("rim_strength", surface_edge_strength * 0.7)
	_surface_mat.set_shader_parameter("climb", surface_climb)
	_surface_mat.set_shader_parameter("edge_boost", surface_edge_boost)
	return _surface_mat


func _update_surface_params() -> void:
	if _surface_mat == null:
		return
	if DEBUG_MOUNT_SCAN_SHADER:
		# 把"探测波扫描带"调成一道很宽的亮带，压在 4.5m 处 -> 墓碑/石棺正好在带里
		_surface_mat.set_shader_parameter("scan_color", Color(1.0, 1.0, 1.0))
		_surface_mat.set_shader_parameter("scan_alpha", 1.5)
		_surface_mat.set_shader_parameter("band_width", 3.0)
		_surface_mat.set_shader_parameter("band_gain", 2.0)
		_surface_mat.set_shader_parameter("trail_len", 0.6)
		_surface_mat.set_shader_parameter("trail_gain", 0.0)
		_surface_mat.set_shader_parameter("climb", 0.0)
		_surface_mat.set_shader_parameter("edge_boost", 0.0)
		_surface_mat.set_shader_parameter("pattern_freq", 0.0)
		_surface_mat.set_shader_parameter("wave_count", 0)
		_surface_mat.set_shader_parameter("wave_center", _center)
		_surface_mat.set_shader_parameter("wave_radius", 4.5)
		return
	_surface_mat.set_shader_parameter("sector_center", _center)
	_surface_mat.set_shader_parameter("axis", _axis)
	_surface_mat.set_shader_parameter("half_angle", half_angle())
	_surface_mat.set_shader_parameter("radius", _radius)
	_surface_mat.set_shader_parameter("inner_m", sector_inner_m)


## 重新扫描"扇形范围内的物体"，给它们的网格挂/摘叠加材质。
## ★ 挂/还原全部交给**公共模块** SurfaceOverlay（和【物体探测】共用同一份实现）：
##   这里只负责"算出该挂哪些网格 + 参数"。
func _refresh_surface() -> void:
	if not surface_scan or not sector or use_decal or use_screen_pass:
		return
	# 重建可能每帧都在调 -> 这里自己限流（球查询 + 包围盒判定比打射线便宜，但没必要每帧）
	var now_s := Time.get_ticks_msec() * 0.001
	if now_s - _last_surface < surface_refresh_interval:
		return
	_last_surface = now_s
	_ensure_surface_mat()
	if _surface_mat == null or _surface_mat.shader == null:
		return
	_update_surface_params()
	var want := {}
	for mi in _collect_sector_meshes():
		want[mi.get_instance_id()] = {"mi": mi, "mat": _surface_mat}
	_surface.sync(want)          # 不在范围内的会被自动还原
	_overlaid = _surface.entries  # 兼容旧调试脚本（只读）


## 球查询 + 扇区过滤 -> 该范围内物体的所有可见网格
func _collect_sector_meshes() -> Array:
	var out: Array = []
	var world := get_world_3d()
	if world == null:
		return out
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())
	# ★ 球查询 / 碰撞体->可视节点解析 / 包围盒 都在公共模块里
	var tl := _terrain_layer()
	var keep := func(n: Node, _v: Node, box: AABB) -> bool:
		# 地形自己不算"物体"：地面已经由贴合网格画了，再叠一层会重复变亮
		if tl != 0 and n is CollisionObject3D \
				and ((n as CollisionObject3D).collision_layer & tl) != 0:
			return false
		if not _aabb_in_sector(box):
			return false
		return true        # ★ 不再按高度跳过：网格只管地形，物体一律由叠加材质画，
		                  #   两者不再抢同一块表面 -> 也就没有"一块白一块不白"。
	# visual_up=6：碰撞体与网格隔得远的（导入模型常见）也要找得到
	var hits := SurfaceOverlay.collect_meshes(world, _center, maxf(0.1, _radius),
			surface_mask, exclude, keep, 64, 6)
	for h in hits:
		# ★ 再按**每个网格自己的包围盒**过滤：导入模型的"一整片"往往只挂一个碰撞体，
		#   组包围盒巨大（17m），按组放行会把几十个网格全挂上；按网格过滤则只挂
		#   真正被扇面切到的那些 —— 既省 draw pass，也不会出现"一块白一块不白"。
		for mi in SurfaceOverlay.visible_meshes(h["visual"] as Node):
			var mesh := mi as MeshInstance3D
			if mesh.mesh == null:
				continue
			var mb: AABB = mesh.global_transform * mesh.mesh.get_aabb()
			if _aabb_in_sector(mb):
				out.append(mesh)
	return out


## 世界包围盒是否碰到扇形。
## ★ 实测教训：墓地遗迹的碰撞体是**一个 17.2×1.6×16.8 m 的巨盒**（导入模型常见：
##   一整片只挂一个 StaticBody）。这时任何"固定几档采样"都会因为间距太大而全部落在
##   扇区外（3×3×3 时间距 8.6m）-> 整片被判"不在扇区"、一个网格都挂不上，
##   表现出来就是"一块白一块不白"。
##   所以：① 先判"扇形顶点(角色)在盒内"；② 采样间距压到 ≤1m（最多 12 档）× 三个高度。
func _aabb_in_sector(box: AABB) -> bool:
	# ① 角色站在这个盒子上/下 -> 必然相交（也是最快的一条）
	if box.position.x <= _center.x and _center.x <= box.position.x + box.size.x \
			and box.position.z <= _center.z and _center.z <= box.position.z + box.size.z:
		return true
	# ② XZ 密采样（间距 ≤1m，最多 12×12）× 上/中/下三档高度
	var nx := clampi(int(ceil(box.size.x / 1.0)), 1, 12)
	var nz := clampi(int(ceil(box.size.z / 1.0)), 1, 12)
	for ix in range(nx + 1):
		for iz in range(nz + 1):
			for iy in [0.0, 0.5, 1.0]:
				var c := box.position + Vector3(
						box.size.x * float(ix) / float(nx),
						box.size.y * iy,
						box.size.z * float(iz) / float(nz))
				if _in_sector_xz(c):
					return true
	return false


func _in_sector_xz(w: Vector3) -> bool:
	var d := Vector2(w.x - _center.x, w.z - _center.z)
	if d.length() > _radius:
		return false
	if d.length() < 0.0001:
		return true
	return absf(wrapf(atan2(d.y, d.x) - _axis, -PI, PI)) <= half_angle()


## 找到物体真正持有网格的那个可视节点（容器的原点常常在 (0,0,0)、几何体是偏移的）
func _resolve_visual(node: Node) -> Node:
	if node == null:
		return null
	var cur := node
	for i in range(6):
		if cur == null:
			break
		if cur is MeshInstance3D:
			return cur
		if not _visible_meshes(cur).is_empty():
			return cur
		cur = cur.get_parent()
	return node


func _visual_aabb(visual: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi in _visible_meshes(visual):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var b: AABB = m.global_transform * m.mesh.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box


## 节点下所有可见网格（转发到公共模块）
func _visible_meshes(node: Node) -> Array:
	return SurfaceOverlay.visible_meshes(node)


## 还原一个网格（转发到公共模块：overlay / 透明度 / 可见层一起还原）
func _restore_one(id: int) -> void:
	_surface.detach(id)


## 还原**所有**被叠加的物体（切回圆盘 / 选点结束 / 节点退出时都必须调）
func _restore_surface() -> void:
	_surface.clear()
	_overlaid = _surface.entries


func _exit_tree() -> void:
	_restore_surface()
	_hide_screen_pass()
	_hide_decal()
	# 相机下的全屏面是本节点创建的，退出时一并回收，别留在相机上
	if _sp_quad != null and is_instance_valid(_sp_quad):
		_sp_quad.queue_free()
		_sp_quad = null

# ================================================================ 投影贴花（Decal）路线
## ★ Godot 4 的 Decal 节点：盒体沿本地 -Y 投影，**盒内的所有表面**（地形 / 墓碑 / 立面 /
##   碎块拼的底座）都会按世界坐标取到同一张贴图 -> 天然贴合、无需逐物体挂载、
##   也没有高度场的弦切割/裙边/台阶缝（这些正是前面十几轮反复的根源）。
##   形状做成一张**运行时生成**的扇形贴图（角度变化时才重画）。
@export var use_decal := false      ## 第 2 条路径的开关，默认关（用户选定的方案是屏幕空间覆盖）
## 贴图里扇形的填充/边线透明度（贴花最终亮度还受 albedo_mix / emission 影响）
@export var decal_fill_alpha := 0.35
@export var decal_edge_alpha := 0.95
@export var decal_emission := 0.6
## 贴花盒的高度与中心抬升（盒要罩住地面与物体，向下投影）
@export var decal_height_m := 3.0
@export var decal_lift_m := 1.2
var _decal: Decal = null
var _decal_tex: ImageTexture = null
var _decal_half := -1.0
var _decal_inner := -1.0


func _ensure_decal() -> void:
	if _decal != null and is_instance_valid(_decal):
		return
	_decal = Decal.new()
	_decal.name = "SectorDecal"
	add_child(_decal)
	_decal.cull_mask = 0xFFFFFFFF
	_decal.albedo_mix = 0.7
	_decal.upper_fade = 0.55      # 上部淡出：草尖 / 高物体顶部自然过渡，减少白雾
	_decal.lower_fade = 0.25
	_decal.distance_fade_enabled = false
	_decal.emission_energy = decal_emission
	_decal.visible = false


## 扇形贴图：纹理 +U 对齐本地 +X（= 扇形轴），V 对齐本地 +Z；半径按 r<=1 归一化。
## 只有**半角/内圈**变化时才需要重画（转滚轮时），每帧只写 position/rotation/size。
func _make_sector_texture(half: float, inner: float) -> ImageTexture:
	var n := 384
	# ★ Godot 4.4+ 已废弃 Image.create()，用 create_empty()（旧版回退）。
	#   这一步失败会导致 texture_albedo = null -> Decal 退化成"用 modulate 铺满整个盒体"，
	#   表现就是一整块方块白（实测踩过）。
	var img: Image = null
	if ClassDB.class_has_method("Image", "create_empty", true):
		img = Image.create_empty(n, n, false, Image.FORMAT_RGBA8)
	else:
		img = Image.create(n, n, false, Image.FORMAT_RGBA8)
	if img == null:
		push_warning("[选点器] 扇形贴图创建失败（Image 为空），贴花不显示")
		return null
	for y in range(n):
		var v := (float(y) + 0.5) / float(n) * 2.0 - 1.0
		for x in range(n):
			var u := (float(x) + 0.5) / float(n) * 2.0 - 1.0
			var rr := sqrt(u * u + v * v)
			var a := 0.0
			if rr <= 1.0:
				var ang := absf(atan2(v, u))
				if ang <= half and rr >= inner:
					a = decal_fill_alpha
					var e := exp(-pow((ang - half) / 0.018, 2.0))
					var in_rim := 1.0 - smoothstep(0.86, 1.0, rr)
					a = maxf(a, e * decal_edge_alpha * in_rim)
					a = maxf(a, (1.0 - in_rim) * decal_edge_alpha * 0.8)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(a, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


func _update_decal() -> void:
	if not use_decal or not sector:
		if _decal != null and is_instance_valid(_decal):
			_decal.visible = false
		return
	_ensure_decal()
	var half := half_angle()
	var inner := clampf(sector_inner_m / maxf(_radius, 0.01), 0.0, 0.9)
	if absf(half - _decal_half) > 0.001 or absf(inner - _decal_inner) > 0.001:
		_decal_half = half
		_decal_inner = inner
		_decal_tex = _make_sector_texture(half, inner)
		if _decal_tex == null:
			_decal.visible = false       # ★ 没有贴图就绝不上屏：否则会变成一整块方块白
			return
		_decal.texture_albedo = _decal_tex
		_decal.texture_emission = _decal_tex
	_decal.emission_energy = decal_emission
	_decal.size = Vector3(_radius * 2.0, decal_height_m, _radius * 2.0)
	_decal.position = _center + Vector3.UP * decal_lift_m
	_decal.rotation.y = -_axis      # 贴图 +U 对齐扇形轴（角度按 atan2(z, x) 计）
	_decal.visible = true

# ================================================================ 屏幕空间覆盖（扇形"扫到就变白"）
## ★ 用户要求：扇形扫到的地方就变白，**不管它是什么物体、不管多大**，
##   可以是整个物体也可以只是一部分 —— 这句话本身就要求**逐像素判定**，
##   而不是"给物体挂材质"（Decal/overlay 都是 opt-in，天然做不到）。
##   做法：相机前一个全屏面 -> 片元用深度纹理重建世界坐标 -> 落在扇形内就上白。
##   探测波已有同族实现（遮罩子视口 + 相机下全屏面），这里沿用同一套结构。
const SCREEN_SHADER := "res://assets/shaders/spell_sector_screen.gdshader"
## ★★ 选点器的实现路径（**预留开关**，按需切换；默认 = 用户选定方案）：
##   1) use_screen_pass = true  -> **屏幕空间覆盖**（默认）：相机前全屏面 + 深度重建世界坐标，
##      逐像素判"在不在范围内" -> 扫到的一切都变白（地形/草/墓碑/碎块底座/半个物体全对）。
##      扇形 shape_mode=0（两条边 + 外弧 + 内圈留白）；圆环 shape_mode=1（只有外弧）。
##   2) use_screen_pass = false 且 use_decal = true -> **投影贴花 Decal**（盒体 + 运行时扇形贴图）。
##      注意其固有取舍：盒子高则把草也刷白，盒子矮则盖不到高物体。
##   3) 两者都 false -> **射线贴合网格**（顶点高度场）。台阶/竖面/大物体做不到，
##      但**不依赖深度纹理**（Compatibility 渲染器下也能跑）。
##   4) DEBUG_MOUNT_SCAN_SHADER = true -> 物体表面只挂探测波的扫描带（A/B 诊断，默认 false）。
##   另：terrain_only_sampling = true 用来复现"采样只打地形层"的旧 bug（诊断，默认 false）。
@export var use_screen_pass := true
## 世界位置低于"脚下 + 这个值"不画（防止把角色脚下/地下也刷白）
## 已废弃：不再按高度过滤（保留字段只为兼容旧场景文件）
@export var screen_floor_margin := 1000.0
## 扇形填充（推进）：扫到的面都铺一层白
@export var screen_fill_strength := 0.55
## ★ 圆环填充（火焰灼烧）：**要的是圈不是实心盘** -> 只留极淡的一层，靠外弧亮带成形
@export var screen_fill_strength_circle := 0.0    # ★ 用户定稿：圆盘**只要一圈外弧亮带**，内部完全透明
@export var screen_edge_strength := 2.2
var _sp_quad: MeshInstance3D = null
var _sp_mat: ShaderMaterial = null


func _ensure_screen_pass() -> bool:
	if _sp_quad != null and is_instance_valid(_sp_quad):
		return true
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null:
		return false
	var sh := load(SCREEN_SHADER) as Shader
	if sh == null:
		push_warning("[选点器] 缺少 spell_sector_screen.gdshader，屏幕空间扇形不可用")
		return false
	_sp_mat = ShaderMaterial.new()
	_sp_mat.shader = sh
	# ★ 排在透明队列最后：否则草/粒子等后画的东西会盖在白色之上，
	#   出现"白色区域里还夹着没变白的草"（用户实测图二）。
	_sp_mat.render_priority = 127
	_sp_quad = MeshInstance3D.new()
	_sp_quad.name = "SectorScreenPass"
	var q := QuadMesh.new()
	q.size = Vector2(4.0, 4.0)          # 相机前 1m 处足够覆盖视野（同探测波的做法）
	_sp_quad.mesh = q
	_sp_quad.material_override = _sp_mat
	_sp_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_sp_quad.extra_cull_margin = 16384.0
	_sp_quad.position = Vector3(0.0, 0.0, -1.0)
	cam.add_child(_sp_quad)
	_sp_quad.visible = false
	return true


## 隐藏屏幕空间全屏面（技能放出 / 切回圆盘 / 节点退出时都必须调）
func _hide_screen_pass() -> void:
	if _sp_quad != null and is_instance_valid(_sp_quad):
		_sp_quad.visible = false


func _hide_decal() -> void:
	if _decal != null and is_instance_valid(_decal):
		_decal.visible = false


func _update_screen_pass() -> void:
	if not use_screen_pass:
		if _sp_quad != null and is_instance_valid(_sp_quad):
			_sp_quad.visible = false
		return
	if not _ensure_screen_pass():
		return
	var vp := get_viewport()
	var cam := vp.get_camera_3d() if vp != null else null
	if cam == null or _sp_mat == null:
		return
	_sp_mat.set_shader_parameter("sector_center", _center)
	_sp_mat.set_shader_parameter("axis", _axis)
	_sp_mat.set_shader_parameter("half_angle", half_angle())
	_sp_mat.set_shader_parameter("radius", _radius)
	_sp_mat.set_shader_parameter("shape_mode", 0 if sector else 1)
	_sp_mat.set_shader_parameter("inner_m", sector_inner_m if sector else 0.0)
	# ★ 高度过滤锚在**角色脚下**（绝不能锚圆心：圆心会被鼠标抬到围栏顶上，实测 3.02m）
	# ★ 高度过滤锚点取"角色脚下"与"范围所在地面"里**较低**的那个：
	#   只锚脚下时，若范围落在陡下坡（低于脚下 1.5m 以上）会把地面切掉（问题二复现）。
	var gy: float = _center.y
	if _player != null and is_instance_valid(_player):
		gy = minf(_player.global_position.y, _center.y)
	_sp_mat.set_shader_parameter("ground_y", gy)
	_sp_mat.set_shader_parameter("floor_margin", screen_floor_margin)
	_sp_mat.set_shader_parameter("fill_strength", screen_fill_strength if sector else screen_fill_strength_circle)
	_sp_mat.set_shader_parameter("edge_strength", screen_edge_strength)
	_sp_quad.visible = true

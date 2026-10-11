extends Node
## ★★ 角色脚底圈（贴合地形 / 只在被草遮挡时显示 / 无抖动）
##
## 【为什么是"实体网格"而不是屏幕空间的圆】
##   屏幕空间的正圆无法表达坡地的高低起伏，坡上/台阶处必然穿模、浮空。
##   这里照搬【火焰灼烧】圈选器（scripts/spells/spell_targeting.gd）的地形贴合思路：
##   逐点向下打射线求地面高度 -> 用采样高度构建贴着地形的环带网格。
##   参考处已验证的关键经验（已照抄）：
##     · 起终点从 y0+12 打到 y0-60，保证台面/沟壑都能命中；
##     · 命中点抬高 lift 避免与地面 z-fighting；
##     · 法线太斜（墙面）的命中滤掉，否则圈会"爬上墙"；
##     · 高度要**限幅 + 坡度限幅 + 抹圆**，否则不规则地面上顶点会抖
##       （smooth_lift/drop、slope_step、slope_passes —— 与参考同口径）。
##
## 【4 个要求对应的实现】
##   ① 没被草遮住时不显示：整圈**可见性开关**，不是逐像素剔除。
##   ② 圈要完整：着色器只做纯色填充，**没有任何 discard**，且关掉引擎深度测试
##      （否则地形/草会把圈切掉一块）。
##   ③ 走动不抖：重建阈值放大（rebuild_move），大幅降低重建频率。
##   ④ 不规则表面平滑：每次重建做"坡度限幅 + 沿圆周抹圆"（同参考实现），
##      再对高度做一阶低通，抑制相邻两次重建之间的跳变。
##
## 【所属系统 / 装配方式】
##   · 本脚本**不是 autoload**，也不挂在任何 .tscn 上：由 autoload 单例 Wind
##     （res://scripts/wind.gd，见 project.godot 的 [autoload] 段）在 _ready 里
##     load("res://scripts/foot_ring.gd").new() 动态实例化，再 add_child 到 Wind 节点下，
##     节点名固定为 "FootRing"（wind.gd::_setup_foot_ring）。
##   · Wind 侧开关 sgt_foot_ring（project.godot 的 [Wind] sgt_player/sgt_foot_ring=true）关掉后，
##     本脚本根本不会被创建。
##   · Wind 还会用 _foot_ring.get("radius") / get("color") 动态读取这里的参数（wind.gd::_ring_num / _ring_color），
##     让"草着色器里的屏幕圈"（已废弃、默认关）与"这里的实体圈"数值保持一致。
##     ⚠ 因此不要随意重命名 @export 变量，否则 Wind 侧读不到会**静默**退回它自己的 fallback 值。
##
## 【关键依赖】
##   · autoload：Wind（唯一装配入口）；本节点自身没有子节点依赖。
##   · 组："player" 组里的第一个 Node3D 视为角色（player.gd 在其 _ready 里 add_to_group("player")）。
##   · 场景树：生成的网格挂到 get_tree().current_scene 下（**不是**挂在 Wind 下）。
##   · 物理：World3D.direct_space_state + PhysicsRayQueryParameters3D 逐点向下打射线求地面高度；
##     collision_mask = 0xFFFFFFFF，并排除角色自身 RID。
##   · 第三方插件：SimpleGrassTextured（SGT）草的 MultiMeshInstance3D 节点，
##     用 has_meta(&"SimpleGrassTextured") 识别，仅用于"是否被草遮挡"的判定。
##   · 参考实现：scripts/spells/spell_targeting.gd 的地形贴合圈选（本文件的平滑参数与它同口径）。
##   · 信号：本文件不定义、也不连接任何信号（纯 _process 轮询）。
##
## 【主要对外接口】
##   只有 @export 变量，没有对外方法：
##     几何/外观：segments / radius / width / lift / color
##     重建触发：rebuild_move / min_normal_up
##     可见性  ：grass_occlusion_only / grass_check_count / hide_margin / hysteresis
##     平滑    ：smooth_lift / smooth_drop / slope_step / slope_passes / height_lerp
##
## 【已知的坑 / 注意事项】
##   · 着色器里**绝不能加 discard**：圈的可见与否完全由 _mesh.visible 这个整体开关决定，
##     加逐像素剔除会破坏要求①，并与地形深度打架。
##   · render_mode 里**不能**出现 render_priority —— 写在 spatial 着色器里会编译失败。
##   · depth_test_disabled / depth_draw_never 必须保留，否则地形与草会按深度把圈切掉一块。
##   · 网格挂在 current_scene 下而非本节点下，所以 _exit_tree 必须手动 queue_free，否则残留一圈。
##     同理，**切换场景**后 current_scene 变了，本脚本不会自动把网格搬过去（推测：目前未处理）。
##   · 草地缓存 _cache_grass 只扫一次（假设 SGT 草是静态的）；草被重生/移动后需要清空
##     _grass_pts 才会重新扫描（推测：目前没有自动失效机制）。
##   · 每次重建的射线数 = segments × 2（内沿 + 外沿各一条），segments 调大会线性增加开销。

# ==================== 导出参数：几何 / 外观 ====================
## 角度分段（越大越圆；射线数 = 段数 × 2）
##   取值范围：>= 1；真正生效的下限是 8（_rebuild 里有 maxi(8, segments) 兜底）。
##   调大 -> 更圆，但开销线性增长（每次重建的射线数 = segments × 2）；
##   调小 -> 能看出多边形棱角（半径只有 0.30 m，64 段已看不出棱角，一般不必再大）。
@export var segments := 64
## 圈半径 / 环带宽度（米）
## 环带**外**半径（米）：圆心就是角色的水平位置。
##   0.30 约等于角色双肩投影的半径，比脚大一圈，既不显眼又不会被草整片盖住。
##   调大 -> 圈更醒目，但会伸到角色投影之外、坡地边缘处更容易采到陡面；
##   调小 -> 圈缩在脚下，草稍高就完全看不见（要求①下会经常处于隐藏）。
##   ⚠ 该值即 _rebuild 里的 r_out；Wind 会通过 _ring_num("radius", ...) 读取它。
@export var radius := 0.30
## 环带宽度（米）：从外半径向里量，内半径 r_in = maxf(0.01, radius - width)（在 _rebuild 里计算）。
##   默认 0.06 -> 外 0.30 / 内 0.24，细细一条，看起来像"脚下的一圈微光"。
##   调大 -> 环更粗更醒目；一旦 width >= radius，内半径被 0.01 兜底，环带退化成"中间有个小孔的圆盘"。
@export var width := 0.06
## 抬高（米）：避免与地面 z-fighting
##   顶点高度统一加这么多（_rebuild 里 outer[s] 与 inner[s] 都会 + lift）。
##   调大 -> 更不容易被地面遮住，但侧视能看出圈"浮在地面上方"，坡地缝隙处尤其明显；
##   调小 / 为 0 -> 与地面共面，不规则坡地上容易出现 z-fighting 闪烁（1 cm 是经过验证的安全值）。
@export var lift := 0.01

# ==================== 导出参数：重建触发与地面命中 ====================
## ★ ③ 重建阈值（米）：角色移动超过这么多才重建网格。
##   调大 -> 重建更少 -> 更不抖（代价是圈跟随角色的延迟更明显）。
##   调小 -> 圈跟得更紧，但重建频繁，顶点抖动与物理射线开销都会上升；
##   为 0 -> 等于每帧重建（不推荐，要求③会失效）。
##   判据是**三维距离**（当前坐标与 _last_build_pos 的 distance_to），所以跳跃/掉落也会触发重建。
@export var rebuild_move := 0.05
## 允许的最大地面法线倾角（cos 值）：更斜就当没命中（别爬上墙）
##   判据是命中面法线的**向上分量**：normal.y >= min_normal_up 才采纳（在 _rebuild 里检查）。
##   取值范围 0~1：1 = 只接受完全水平的面；0 = 连墙面都算（圈会爬上墙）。
##   0.55 约等于"法线与竖直方向夹角 <= 57°"，正好放过坡地、挡掉墙面与树干立面。
@export var min_normal_up := 0.55
## 圈颜色（半透明白）
##   a（不透明度）默认只有 0.03 —— 极淡，只在被草挡住时起"我还在这"的提示作用。
##   调大 -> 圈更实更抢眼（0.1 以上就明显是一圈白光了）；调小 -> 几乎看不见（0 = 完全不可见）。
##   rgb 默认纯白：在绿色草地背景上最不容易被误认成草的一部分。
##   ⚠ Wind 通过 _ring_color("color") 读它；着色器里的 uniform 名是 ring_color（在 _build_node 里写入）。
@export var color := Color(1.0, 1.0, 1.0, 0.03)

# ==================== 导出参数：可见性（草遮挡） ====================
## ★ ① 只在"被草遮挡"时显示
## 总开关：
##   true  -> 只有"脚底没有明显高于附近草顶"（即被草挡住）时才显示整圈；
##   false -> 无条件常显（调试/截图时用，代价是空旷处也挂着一圈白环）。
##   ⚠ 打开时若场景里根本没有 SGT 草，_nearby_grass_top 返回 null，圈会**一直隐藏**。
@export var grass_occlusion_only := true
## 判定"被草遮挡"时最多检查多少株草
## 含义：每次判定在半径内最多统计多少株草，数到就 break 早退。
##   默认 400 ≈ 一块 4096 株草地的十分之一，足以判断"脚边有没有草"，又不会每帧遍历整片草。
##   调大 -> 判定更准（不容易被遍历顺序骗到），代价是每帧 CPU；
##   调小 -> 更省，但可能漏掉真正盖住角色的那株草 -> 该显示时却没显示。
@export var grass_check_count := 400
## 显示/隐藏余量（米）：脚底要高出草顶这么多才认为"没被遮挡" -> 隐藏
## 含义：判定门槛是"脚底 p.y <= 草顶 + hide_margin" -> 被遮挡 -> 显示；
##       反过来 "p.y > 草顶 + hide_margin" -> 没被遮挡 -> 隐藏。
##   0.12 m 约等于"跳起来 12 cm 以上"才算脱离草丛（草顶本身高低不齐，需要留余量）。
##   调大 -> 更容易判为"没被遮挡" -> 圈更容易隐藏（太大会站着不动也看不到圈）；
##   调小 -> 圈更粘人（跳到很高还在显示）。
@export var hide_margin := 0.12
## 切换滞回（米）：避免在阈值附近来回闪
## 含义：显示/隐藏用**两套不同阈值**，中间留出 hysteresis 的死区（施密特触发、滞回）：
##   已显示时，要"高于草顶 + hide_margin"才隐藏；
##   已隐藏时，要"不高于草顶 + hide_margin - hysteresis"才显示。
##   0.06 m 的死区刚好压住角色上下微动、站在草丛边缘时的来回闪。
##   调大 -> 更稳定但反应更迟钝；调小 / 为 0 -> 阈值附近会快速闪烁。
@export var hysteresis := 0.06

# ==================== 导出参数：平滑（地形贴合去抖） ====================
## ★ ④ 平滑参数（与参考实现同口径）
##   即 scripts/spells/spell_targeting.gd 里同名、同默认值的一组参数；改一处时最好两处一起对。
## 高度**上限**（米）：采样高度最多比角色脚底高 smooth_lift，超出就 clamp 掉。
##   主要对付"墙顶 / 台阶上沿"这类向上突变（射线打到高台上，整圈会被抬起来）。
##   调大 -> 容忍更大的向上起伏（台阶轮廓能保留，但圈可能瞬间抬高）；
##   调小 -> 圈更贴平，但上坡/台阶处圈会切进地里。
@export var smooth_lift := 0.35
## 高度**下限**（米）：采样高度最多比角色脚底低 smooth_drop，超出就 clamp 掉。
##   主要对付"沟壑 / 崖边"这类向下突变（射线打到深沟底，整圈会被拽下去）。
##   调大 -> 圈能跟着下坡走；调小 -> 圈被拉平，下坡处会浮空。
@export var smooth_drop := 0.35
## 相邻顶点允许的最大高度差（米/段）：迭代时把某点夹到"左右邻居 ± slope_step"之间。
##   这一步只削"一级跳几米"的尖刺，**保住整体坡形**（不是全局拉平）。
##   调小 -> 更平滑，但陡坡会被压扁；内部有 maxf(slope_step, 0.0001) 兜底，写 0 也不会把整圈压平。
@export var slope_step := 0.22
## 坡度限幅的迭代轮数：每轮把所有越界点夹回"邻居 ± slope_step"，尖刺被逐轮摊开。
##   0 = 不做坡度限幅（只剩硬限幅 + 抹圆）；4 轮是参考实现验证过的"够平滑又不拖慢"的取值。
##   调大 -> 更平滑，但每次重建成本更高（复杂度 O(n × slope_passes)）。
@export var slope_passes := 4
## 高度低通系数（0~1）：每次重建把新采样与上次结果混合，越小越稳
##   实际公式在 _temporal 里：out = lerpf(prev, 本次采样, height_lerp)。
##   默认 0.55 -> 每次取 55% 新值 + 45% 上次结果，抑制相邻两次重建之间的整圈跳变。
##   调小 -> 更稳但更"粘"（角色快速上下台阶时圈跟不上，会有拖影感）；
##   调大 / 为 1 -> 等于不做时间平滑，走动时能看出圈在抖。
##   段数变化（改了 segments）时 _temporal 会放弃历史值，本参数暂时不生效一轮。
@export var height_lerp := 0.55

# ==================== 运行时状态（全部私有，外部不要依赖） ====================
## 运行时创建的网格节点（name = "FootRing"）。
## 注意：节点本身挂在 get_tree().current_scene 下，**不是**本节点的子节点，这里只持有引用；
## 由 _build_node 创建、_exit_tree 释放。
var _mesh: MeshInstance3D = null
## 圈的 ShaderMaterial（纯色 + 关深度测试 + 无 discard）。
## 与 _mesh 同生共死；改颜色只需 set_shader_parameter("ring_color", ...)，不必重建材质。
var _mat: ShaderMaterial = null
## "player" 组里的角色节点缓存。
## 每帧用 is_instance_valid 校验一次（重开场景 / 换角色后引用会失效），失效后由 _find_player 重查。
var _player: Node3D = null
## 上次重建网格时角色的世界坐标。
## 初值故意设成 1e9（远到任何真实坐标都不可能与之重合），保证**第一帧必定重建一次**，
## 这样就不必再写"是否首次"的分支。
var _last_build_pos := Vector3(1.0e9, 1.0e9, 1.0e9)
## 是否已经成功生成过一次网格。
## 为 false 时 _process 会无视 rebuild_move 强制重建，用于首帧以及"建节点失败后自愈"；
## 注意"整圈射线全打空"时它**不会**被复位（见 _rebuild），避免每帧重试打空射线。
var _has_mesh := false
## 上一次重建的内/外沿高度（时间低通用）
var _prev_inner: PackedFloat32Array = PackedFloat32Array()
var _prev_outer: PackedFloat32Array = PackedFloat32Array()
## ① 可见性滞回状态
var _shown := false
## SGT 草实例缓存（世界坐标 + 顶部高度）
##   · 元素是 Vector4(x, y, z, top)：前三个是该株草在世界空间的**地面点**，w 是它的**顶部世界高度**。
##   · 由 _cache_grass 惰性填充一次（草视为静态）；判定时先按水平距离过滤，再取半径内最大的 w。
##   · 与 wind.gd 的 _sgt_grass_pts 是**两份独立缓存**（格式相同、互不同步），改一处不影响另一处。
var _grass_pts: Array = []


# ==================== 生命周期回调 ====================


## 初始化：强制"暂停时也继续跑"、打开 _process，并创建圈的节点与材质。
## 参数：无。
## 返回值：无。
## 副作用：改 process_mode；创建 MeshInstance3D + ShaderMaterial，并把网格挂到 current_scene 下。
## 调用时机：Wind 在 _ready 里 new() + add_child 后由引擎回调（此时 current_scene 已就绪）。
## 注意事项：这里**不做**地形重建（留给 _process 第一帧），也不检查是否已建过节点，
##           所以不要手动再调一次，否则会多出一个网格节点。
func _ready() -> void:
	# 即使 set_paused(true) / 打开菜单暂停，也让圈继续跟随角色：
	# 否则暂停期间角色被移动（例如调试传送）后圈会留在原地，恢复时视觉上"脱节"一次
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 显式打开 _process：不依赖 Node 的默认值，也避免别处误关
	# （本脚本的全部逻辑都靠 _process 轮询，一旦关掉圈就完全静止）
	set_process(true)
	_build_node()


## 创建脚底圈的渲染资源：MeshInstance3D + ShaderMaterial（内嵌纯色着色器）。
## 参数：无。
## 返回值：无（结果写到 _mesh / _mat 两个成员上）。
## 副作用：new 出节点与材质、写入内嵌 shader 代码、把网格 add_child 到 get_tree().current_scene；
##         初始 visible = false（等可见性判定决定何时显示）。
## 调用时机：只在 _ready 里调用一次。
## 注意事项：着色器的 render_mode 是**刻意**写死的（关深度测试 / 不写深度 / 无 discard），
##           改动前先读文件头的"已知的坑"；`_mesh.visible = false` 必须在首次绘制之前，
##           否则第一帧可能在原点闪出一圈白环。
func _build_node() -> void:
	# ⚠ 场景树里会出现**两个**叫 "FootRing" 的节点：一个是挂在 Wind 下的脚本宿主
	# （wind.gd::_setup_foot_ring 里命名），一个就是这里的网格；按名字查找时要注意区分
	_mesh = MeshInstance3D.new()
	_mesh.name = "FootRing"
	# 关阴影：圈是贴地的半透明薄片，投影没有意义，还容易在地面上留一圈脏影
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 用 ShaderMaterial 而不是 StandardMaterial3D：需要 depth_test_disabled / depth_draw_never
	# 这类空间渲染开关，普通材质给不了
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
// ⚠ render_priority 不能写在 spatial 里（会编译失败）
// ★ depth_test_disabled：圈在地面高度，地形/草在它前面；若让引擎做深度测试，
//   圈的像素会被**直接剔除** -> 圈被切成残缺的一块（用户要求"完整的圈"）。
//   关掉它，圈就是完整的一圈。
//   depth_draw_never：不写深度缓冲，避免影响后续绘制。
// ⚠ 本着色器**不做任何 discard**：可见性由脚本整体开关（要求①）。
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never,
		ambient_light_disabled, fog_disabled, blend_mix;

uniform vec4 ring_color : source_color = vec4(1.0, 1.0, 1.0, 0.55);

void fragment() {
	ALBEDO = ring_color.rgb;
	ALPHA = ring_color.a;
}
"""
	_mat.shader = sh
	# uniform 名必须与上面 shader 代码里的 ring_color 完全一致：
	# 名字写错不会报错，只会静默保持 uniform 的默认值（圈的颜色看起来"没生效"）
	_mat.set_shader_parameter("ring_color", color)
	# 用 material_override 而不是 mesh.surface_set_material：
	# 每次重建都会换掉 _mesh.mesh，material_override 会自动沿用同一个材质，不用重复设置
	_mesh.material_override = _mat
	_mesh.visible = false          # 由可见性判定决定何时显示
	# ★ 直接挂到主场景（先 add_child 到自身再搬会报 "already has a parent"）
	# 挂到 current_scene（主场景）而不是自身：本脚本宿主在 Wind 这个 autoload 下，
	# 网格若挂在自身下就会跟着 Wind 的变换/生命周期走，切场景时容易残留或错位
	if get_tree() != null and get_tree().current_scene != null:
		get_tree().current_scene.add_child(_mesh)
	else:
		add_child(_mesh)


## 每帧驱动：找角色 -> 按位移阈值决定是否重建环带网格 -> 更新可见性。
## 参数：_delta 本帧时间（**未使用**；重建是按"位移阈值"节流，而不是按时间）。
## 返回值：无。
## 副作用：可能重建 _mesh.mesh（替换网格数据）、可能改 _mesh.visible、更新 _last_build_pos。
## 调用时机：每帧（process_mode = ALWAYS，所以暂停时也跑）。
## 注意事项：① _player 为空时**立刻 return**，角色还没进场景前几乎没有开销，
##              但这也意味着"场景里没有 player 组节点"时圈完全不工作（没有兜底按名字搜索）；
##           ② 未建过网格（_has_mesh == false）时会无视 rebuild_move 先建一次；
##           ③ 重建与可见性是两步：即使不重建，可见性每帧都会重新判定。
func _process(_delta: float) -> void:
	# 角色引用可能因重开场景 / 换角色而失效（is_instance_valid 为 false），
	# 这里做一次性重查：失败就本帧放弃（每帧最多查一次，不会反复扫场景树）
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
		if _player == null:
			return
	var p := _player.global_position
	# ③ 大幅降低重建频率，减少顶点跳动
	if not _has_mesh or p.distance_to(_last_build_pos) >= rebuild_move:
		_last_build_pos = p
		_rebuild(p)
	# ① 只在被草遮挡时显示
	_update_visibility(p)


# ==================== 可见性判定（要求①） ====================
## ★ ① 可见性：角色脚底没被草挡住 -> 整圈隐藏。
##   判据：脚底是否明显高于附近草顶（高于 -> 草盖不到角色 -> 隐藏）。
##   用滞回避免在阈值附近来回闪。
## 参数 p：角色的**世界坐标**（脚底位置）——只拿它和附近草顶比较，不做任何几何计算。
## 返回值：无（结果直接写 _mesh.visible）。
## 副作用：改 _mesh.visible、改滞回状态 _shown。
## 调用时机：每帧由 _process 调用一次（与重建解耦：不重建也会重新判定）。
## 注意事项：① _mesh 还没建好时直接返回，此时 _shown 可能停在旧值；
##           ② 判定只在"附近有草"时才成立：附近没有草（返回 null）会立刻隐藏并把 _shown 复位 false；
##           ③ grass_occlusion_only = false 时无条件常显，_shown 状态不再有意义。
func _update_visibility(p: Vector3) -> void:
	if _mesh == null:
		return
	if not grass_occlusion_only:
		_mesh.visible = true
		return
	# ⚠ 显式标注 Variant：函数返回 Variant（可能 null），用 := 会被判为类型不明确
	# 该函数在"附近一株草都没有"时返回 null，所以这里先用 Variant 接住再做判空
	var top: Variant = _nearby_grass_top(p)
	if top == null:
		_mesh.visible = false          # 附近没有 SGT 草：没什么可遮挡的
		_shown = false
		return
	var t: float = top
	if _shown:
		if p.y > t + hide_margin:
			_shown = false
	else:
		if p.y <= t + hide_margin - hysteresis:
			_shown = true
	_mesh.visible = _shown


# ==================== 草地查询：附近最高草顶 ====================
## 附近 SGT 草的**最高顶部**（没有草返回 null）
## 作用：在缓存里找出水平距离 r 以内所有草的最高顶部高度（只做水平过滤，不管高低）。
## 参数 p：角色世界坐标；**只使用 p.x / p.z**，p.y 不参与筛选。
## 返回值：半径内最高的草顶世界 y（float）；半径内一株草都没有时返回 **null**（Variant）。
## 副作用：_grass_pts 为空时会触发一次 _cache_grass（全场景扫描，可能有一次卡顿）。
## 调用时机：每帧由 _update_visibility 调用一次；不缓存查询结果。
## 注意事项：① 搜索半径 r = maxf(0.6, radius + 0.6)，故意比圈大：让"角色还没走进草丛"时就能感知；
##           ② grass_check_count 的早退是**遍历顺序**上的截断，不是"最近优先"，
##              所以草实例顺序变化时结果可能略有不同（推测）；
##           ③ 返回 Variant 而不是 float，正是为了用 null 表达"附近没有草"这个第三种状态。
func _nearby_grass_top(p: Vector3) -> Variant:
	if _grass_pts.is_empty():
		_cache_grass()
	# 半径再小也至少查 0.6 m：小圈同样要能感知到"脚边那株草"才算被遮挡
	var r := maxf(0.6, radius + 0.6)
	# 先算好半径平方，循环里只做乘法比较（避免每株草都开方）
	var r2 := r * r
	# 哨兵值：用 -1e9 表示"还没找到任何草"，循环后仍小于 -1e8 就认为附近没有草
	var best: float = -1.0e9
	# 已检查株数：配合 grass_check_count 给这次查询的开销封顶
	var n := 0
	for v in _grass_pts:
		var p4: Vector4 = v
		var dx := p4.x - p.x
		var dz := p4.z - p.z
		if dx * dx + dz * dz > r2:
			continue
		n += 1
		# w 分量是这株草的**顶部世界高度**，这里只取最大值
		# （"这株草是否真的挡住角色"交给调用方用 hide_margin 判断）
		if p4.w > best:
			best = p4.w
		# 达到上限直接早退（⚠ 依赖 _grass_pts 的遍历顺序，不保证优先看到最近的草）
		if n >= grass_check_count:
			break
	if best < -1.0e8:
		return null
	return best


# ==================== 草地缓存：SGT 实例扫描 ====================
## 缓存 SGT 草实例的世界坐标与顶部高度（草是静态的，缓存一次即可）
## 作用：从 current_scene 起遍历整棵树，收集所有 SimpleGrassTextured 草（MultiMeshInstance3D）
##       每株实例的**世界地面坐标**与**顶部高度**，写进 _grass_pts（元素为 Vector4(x, y, z, 顶部y)）。
## 参数：无（不接收角色位置，扫的是全场景）。
## 返回值：无。
## 副作用：先 clear 再重填 _grass_pts；只读场景树，不修改任何节点。
## 调用时机：_nearby_grass_top 发现 _grass_pts 为空时**惰性**调用（即第一次可见性判定时），
##           所以进游戏的第一帧可能有一次停顿（全场景 DFS + 最多 6000 个实例变换）。
## 注意事项：① 只扫一次，草被视为静态；草被移动/重生后需要手动 _grass_pts.clear() 才会重扫（推测：无自动失效）；
##           ② 单株草高度用"节点 AABB 高 × 实例 Y 缩放"估算，MultiMesh 的 AABB 往往是所有实例的并集（推测），
##              因此这个顶部高度是近似值；
##           ③ 每个 MultiMesh 最多取 6000 个实例，超出的草不参与判定；
##           ④ 用显式栈做深度优先遍历而不是递归，省掉递归调用开销（推测：本意如此）。
func _cache_grass() -> void:
	_grass_pts.clear()
	if get_tree() == null:
		return
	var root := get_tree().current_scene
	if root == null:
		return
	var stack: Array = [root]
	while not stack.is_empty():
		var nd: Node = stack.pop_back()
		# 用 SGT 插件打在节点上的 meta 识别草地，而不是按节点名/类型判断：
		# 场景里可能有别的 MultiMeshInstance3D（灌木、石头、装饰），靠 meta 最不容易误伤
		if nd is MultiMeshInstance3D and nd.has_meta(&"SimpleGrassTextured"):
			var mmi := nd as MultiMeshInstance3D
			if mmi.multimesh != null:
				# 单株草高度直接用节点 AABB 的高度（该值取的是 MultiMesh 的包围盒，可能与单株真实高度有出入）
				var local_h := mmi.get_aabb().size.y
				if local_h <= 0.0001:
					# 兜底 1 m：AABB 高为 0（资源未就绪/未烘焙）时若留着 0，
					# 每株草的"顶部高度"就等于地面高度，圈会被判成"永远被遮挡"而一直显示
					local_h = 1.0
				# 实例变换是**节点局部**的，必须再乘节点的全局变换才能得到世界坐标
				var xf := mmi.global_transform
				# 单块草地最多取 6000 株实例：几万株的草地全扫会明显卡帧
				for i in range(mini(mmi.multimesh.instance_count, 6000)):
					var t := mmi.multimesh.get_instance_transform(i)
					var w: Vector3 = xf * t.origin
					# 缩放可能有负值（翻转），所以取绝对值来换算单株实际高度
					var sy := absf(t.basis.get_scale().y)
					_grass_pts.append(Vector4(w.x, w.y, w.z, w.y + local_h * sy))
		# 把子节点压入栈继续深度优先（显式栈，不递归：场景树再深也不会撑爆调用栈）
		for c in nd.get_children():
			stack.append(c)


# ==================== 环带网格重建（地形贴合） ====================
## ★ 逐点采地形高度并构建环带网格（地形贴合 + 平滑）
## 作用：绕角色一圈，每段采"外沿 + 内沿"两个地面高度 -> 平滑 -> 生成贴着地形的环带网格。
## 参数 p：角色的**世界坐标**；x/z 作为圆心，y 作为所有采样的参考平面 y0。
## 返回值：无（成功时写 _mesh.mesh 并把 _has_mesh 置 true）。
## 副作用：发起 segments × 2 次物理射线查询；替换 _mesh.mesh；可能把 _mesh.visible 置 false；
##         更新 _prev_outer / _prev_inner（供下一次重建做时间低通）。
## 调用时机：_process 里"还没建过网格"或"角色移动距离 >= rebuild_move"时调用。
## 注意事项：① 整圈一条有效射线都没命中（角色悬空/脚下没有可撞地形）时直接把圈隐藏并 return，
##              此时 _has_mesh 保持原值，避免每帧重复打空射线；
##           ② 顶点全部按 "p.x / p.z + 半径" 重新计算，所以重建瞬间圈**必然以角色为圆心**；
##              角色不动时不会重建 -> 这是"不抖"的代价（跟随有阈值延迟）；
##           ③ 查询对象与 exclude 数组在每次重建时新建（不是每帧），开销可接受（推测）。
func _rebuild(p: Vector3) -> void:
	var vp := get_viewport()
	if vp == null or _mesh == null:
		return
	var world: World3D = vp.find_world_3d()
	if world == null:
		return
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return
	# 复用同一个查询对象（参考实现也是这么省分配的）
	var q := PhysicsRayQueryParameters3D.create(Vector3.ZERO, Vector3.ZERO)
	# 打所有碰撞层，避免因项目层配置变化而漏掉地面
	q.collision_mask = 0xFFFFFFFF
	# exclude 收的是 RID 数组；_player 若不是 CollisionObject3D（例如被换成纯 Node3D）就保持空数组
	var exclude: Array = []
	# 必须排除角色自己：射线从 y0+12 往下打，否则第一发命中的永远是角色本体的碰撞体，
	# 每段高度都会变成角色自身高度，圈反而贴不到地面
	if _player is CollisionObject3D:
		exclude = [(_player as CollisionObject3D).get_rid()]
	q.exclude = exclude

	# 所有采样与限幅都以"角色脚底高度"为参考平面
	var y0 := p.y
	# 至少 8 段：segments 被误设成 0 / 负数时，环带也不会退化成一条线
	var n := maxi(8, segments)
	var h_out := PackedFloat32Array()
	var h_in := PackedFloat32Array()
	h_out.resize(n)
	h_in.resize(n)
	var hit_any := false
	var r_out: float = radius
	# 内半径保底 0.01 m：width >= radius 时环带会自交/翻面，这里兜住
	var r_in: float = maxf(0.01, radius - width)
	for s in range(n):
		var a := float(s) / float(n) * TAU
		var dx := cos(a)
		var dz := sin(a)
		# which = 0 采外沿、1 采内沿：两者共用同一段角度，省掉第二个 0..n 循环
		for which in range(2):
			var rr: float = r_out if which == 0 else r_in
			var x := p.x + dx * rr
			var z := p.z + dz * rr
			var y := y0
			# 起终点要远超可能的"最高台面 / 最深沟"：上 12 m、下 60 m；
			# 跨度不够时台阶边缘或沟壑里会采不到地面（参考实现同口径）
			q.from = Vector3(x, y0 + 12.0, z)
			q.to = Vector3(x, y0 - 60.0, z)
			# 复用同一个查询对象 q：每次只改 from/to，省掉每条射线都新建参数对象的分配
			var hit: Dictionary = space.intersect_ray(q)
			if not hit.is_empty():
				var ny: float = (hit.get("normal", Vector3.UP) as Vector3).normalized().y
				# 只接受足够朝上的面：墙面/树干的法线太斜，采到的是立面，圈会"爬上墙"
				if ny >= min_normal_up:
					y = (hit["position"] as Vector3).y
					hit_any = true
			# 没命中、或命中了但法线不合格时，y 仍是初值 y0：该点退回角色脚底高度
			if which == 0:
				h_out[s] = y
			else:
				h_in[s] = y
	# 整圈一条有效射线都没有：与其画一圈悬在角色高度的假圈，不如什么都不画
	if not hit_any:
		_mesh.visible = false
		return
	# ★ ④ 平滑：限幅 -> 坡度限幅 -> 沿圆周抹圆 -> 时间低通（口径同参考实现）
	h_out = _smooth_ring(h_out, y0, n)
	h_in = _smooth_ring(h_in, y0, n)
	h_out = _temporal(h_out, _prev_outer, n)
	h_in = _temporal(h_in, _prev_inner, n)
	_prev_outer = h_out
	_prev_inner = h_in
	# 构建顶点
	var inner := PackedVector3Array()
	var outer := PackedVector3Array()
	inner.resize(n)
	outer.resize(n)
	for s in range(n):
		var a2 := float(s) / float(n) * TAU
		var cx := cos(a2)
		var cz := sin(a2)
		# 外沿、内沿各用自己的采样高度（不取平均），环带因此会顺着地形微微倾斜，而不是一块硬板
		# （+ lift 见 @export lift：整圈略微抬高，避免与地面 z-fighting）
		outer[s] = Vector3(p.x + cx * r_out, h_out[s] + lift, p.z + cz * r_out)
		inner[s] = Vector3(p.x + cx * r_in, h_in[s] + lift, p.z + cz * r_in)
	_mesh.mesh = _build_ring_mesh(inner, outer)
	_has_mesh = true


# ==================== 平滑工具（限幅 / 坡度限幅 / 抹圆 / 时间低通） ====================
## ★ 单环平滑（照搬参考实现的 ①②③）：
##   ① 硬限幅：把"墙顶 / 深沟"的大落差压进 ±limit
##   ② 坡度限幅：相邻顶点落差不超过 slope_step，迭代 slope_passes 轮
##      —— 保住整体坡形，只把"一级跳几米"的尖刺削平
##   ③ 一轮三点平均抹圆（幅度小，不会抹掉坡形）
## 作用：对一整圈（首尾相接）的高度数组做三步处理，消除不规则地面上的顶点抖动。
## 参数 h：本次采样得到的高度数组（长度 n，世界 y 坐标）。
## 参数 y0：角色脚底高度，作为第①步硬限幅的中心。
## 参数 n：采样点数（= maxi(8, segments)）。
## 返回值：新的 PackedFloat32Array（长度 n；**不修改**入参 h）。
## 副作用：无（纯函数，只读 @export 参数）。
## 调用时机：_rebuild 里对外沿、内沿各调一次，结果随后交给 _temporal 做时间低通。
## 注意事项：① 三步顺序不能换：先硬限幅压掉大落差，再坡度限幅削尖刺，最后抹圆；
##           ② 这是"只压不平"式的平滑：单个尖刺会被削平、单个深坑会被垫高（整片宽坡不受影响）；
##           ③ 邻居一律用环形下标 (s±1+n)%n，保证首尾接缝处不出现断口；
##           ④ 复杂度 O(n × slope_passes)，是整个重建过程的主要 CPU 开销。
func _smooth_ring(h: PackedFloat32Array, y0: float, n: int) -> PackedFloat32Array:
	var cur := PackedFloat32Array()
	cur.resize(n)
	for s in range(n):
		cur[s] = clampf(h[s], y0 - smooth_drop, y0 + smooth_lift)
	# 轮数下限 0：负数没有意义（显式钳一下，避免以后改代码时误传负值）
	var passes := maxi(slope_passes, 0)
	# 步长下限 0.0001：slope_step 若写 0，会把所有点都拉到与邻居同高（整圈瞬间被压平）
	var st := maxf(slope_step, 0.0001)
	for _pass in range(passes):
		var nxt := PackedFloat32Array()
		nxt.resize(n)
		for s in range(n):
			# 环形取左右邻居：(s-1+n)%n 处理 s=0 时的负数下标，保证首尾相接不断口
			var l := cur[(s - 1 + n) % n]
			var r := cur[(s + 1) % n]
			# 把当前点夹进"左右邻居 ± 步长"的区间：只削单点尖刺，不改变整体走势
			var lo := minf(l, r) - st
			var hi := maxf(l, r) + st
			nxt[s] = clampf(cur[s], lo, hi)
		cur = nxt
	var fin := PackedFloat32Array()
	fin.resize(n)
	for s in range(n):
		var l2 := cur[(s - 1 + n) % n]
		var r2 := cur[(s + 1) % n]
		# 三点加权平均（自己权重 2、左右邻居各 1）：只做轻微抹圆，抹不掉整体坡形
		fin[s] = (cur[s] * 2.0 + l2 + r2) * 0.25
	return fin


## ★ 时间低通：把本次采样与上次结果混合，抑制相邻两次重建之间的跳变
## 作用：一阶低通（指数平滑）：out[s] = lerpf(prev[s], h[s], height_lerp)。
## 参数 h：本次重建采样（已过 _smooth_ring）的高度数组。
## 参数 prev：上一次重建最终采用的高度数组（外沿传 _prev_outer、内沿传 _prev_inner）。
## 参数 n：本段点数。
## 返回值：混合后的 PackedFloat32Array（长度 n）。
## 副作用：无（写回 _prev_* 是调用方 _rebuild 的事）。
## 调用时机：_rebuild 中在 _smooth_ring 之后、构建顶点之前，外沿内沿各一次。
## 注意事项：prev.size() != n（例如运行中改了 segments）时**直接返回本次采样**，
##           等价于"重新起步"；否则会拿旧段数的旧数组做错位混合，整圈会错乱。
func _temporal(h: PackedFloat32Array, prev: PackedFloat32Array, n: int) -> PackedFloat32Array:
	# 段数变了（segments 被改过 / 首次重建）-> 旧数组下标已无意义，直接放弃历史值
	if prev.size() != n:
		return h
	var k := clampf(height_lerp, 0.0, 1.0)
	var out := PackedFloat32Array()
	out.resize(n)
	for s in range(n):
		# k 越小越信任上一次结果（越稳、越迟钝）；k = 1 等于不做时间平滑
		out[s] = lerpf(prev[s], h[s], k)
	return out


# ==================== 网格构建 ====================
## 由内外两圈顶点构建环带（每段 2 个三角形）
## 参数 inner / outer：长度相同（n）的顶点数组，下标一一对应同一角度上的内沿 / 外沿顶点。
## 补充：顶点已经是**世界坐标**（_rebuild 里算好的），本函数不做任何变换。
## 返回值：SurfaceTool.commit() 得到的 ArrayMesh（纯三角面，无 UV / 无切线）。
## 副作用：无（只是新建 mesh；赋给 _mesh.mesh 是 _rebuild 的事）。
## 调用时机：_rebuild 末尾，每次重建都会新建一个 mesh，旧的由引擎回收。
## 注意事项：① 法线一律写 Vector3.UP，而不是用真实地面法线 —— 着色器是 unshaded，
##              法线只影响极少数后端处理，统一朝上最省事且不会出现黑面；
##           ② 三角形绕序固定 + 着色器 cull_disabled，保证正反面都可见（推测：本意如此）；
##           ③ 每段两个三角形而不是一个四边形：SurfaceTool 只处理三角形。
func _build_ring_mesh(inner: PackedVector3Array, outer: PackedVector3Array) -> ArrayMesh:
	var n := inner.size()
	# 用 SurfaceTool 现搭三角面：顶点数很少（n×2），每次重建现场构建也足够快
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in range(n):
		# s2 是环上的下一个点：最后一段 (n-1) 会连回第 0 点，把环带闭合
		var s2 := (s + 1) % n
		var i0 := inner[s]
		var i1 := inner[s2]
		var o0 := outer[s]
		var o1 := outer[s2]
		# 每段两片三角形：(内0,外0,外1) 与 (内0,外1,内1)，拼成环带上的一个四边形
		# ⚠ set_normal 必须在 add_vertex 之前调用，否则这批顶点拿不到法线
		st.set_normal(Vector3.UP)
		st.add_vertex(i0); st.add_vertex(o0); st.add_vertex(o1)
		st.set_normal(Vector3.UP)
		st.add_vertex(i0); st.add_vertex(o1); st.add_vertex(i1)
	return st.commit()


# ==================== 玩家定位 / 清理 ====================


## 在 "player" 组里找第一个 Node3D 作为角色
##（该组由 scripts/player.gd 在自己的 _ready 里 add_to_group("player") 加入）。
## 参数：无。
## 返回值：找到的 Node3D；没有场景树 / 组里没有 Node3D 时返回 null。
## 副作用：无（纯查询）。
## 调用时机：_process 中 _player 为空或引用失效时调用（每帧最多一次）。
## 注意事项：① 不做按名字含 "player" 的兜底搜索（wind.gd 里那套兜底是另一处实现），
##              所以角色脚本忘了加组时，圈会完全不工作；
##           ② 组里有多个 Node3D 时返回**遍历顺序的第一个**，不保证是主角（推测：项目里只有一个）。
func _find_player() -> Node3D:
	if get_tree() == null:
		return null
	for n in get_tree().get_nodes_in_group("player"):
		if n is Node3D:
			return n as Node3D
	return null


## 清理：本节点离开场景树时释放那个**不属于自己**的网格节点。
## 参数：无。
## 返回值：无。
## 副作用：_mesh.queue_free()，之后 _mesh 变成已释放引用。
## 调用时机：引擎在节点被 remove_child / free / 场景重载时回调（例如切场景）。
## 注意事项：① 网格挂在 current_scene 下，不是本节点的子节点，引擎**不会**自动回收，必须在这里释放，
##              否则会残留一圈白环（wind.gd 仍持有本脚本实例的引用，但它会先做 is_instance_valid 检查）；
##           ② 用 queue_free 而不是 free：在退出流程里同步销毁节点不安全（推测：保守写法）。
func _exit_tree() -> void:
	# 本节点可能没走到 _build_node（或网格已被释放），所以先判空再释放
	if _mesh != null and is_instance_valid(_mesh):
		_mesh.queue_free()

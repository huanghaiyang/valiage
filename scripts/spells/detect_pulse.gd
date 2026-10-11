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

##
## ---------------------------------------------------------------- 依赖清单
##
## · 自动加载：Mana（scripts/spells/mana.gd）—— 本文件只调用 Mana.try_spend()，
##   不做回蓝/上限之外的任何操作；扣不动就标记 _ran_out，交给上层/HUD 读走。
## · 宿主：spell_caster.gd（自动加载为 SpellCaster）在 SPELLS 表里注册本脚本，
##   由它实例化并调用 setup / start_cast / stop_cast / is_casting。
##   ★ 单向依赖：本文件**不反向引用** SpellCaster，删掉宿主也照样单独跑（只是没人调用）。
## · 复用脚本：spell_aim.gd（瞄准方向 + 施法起点，粒子版与着色器版共用一份）；
##   surface_overlay.gd（挂/还原 material_overlay、球查询 + 碰撞体->可视节点解析）。
## · 着色器（任一缺失只 push_warning 并降级，**不会报错中断**）：
##     res://assets/shaders/detect_ripple.gdshader          地面细线波纹
##     res://assets/shaders/detect_outline.gdshader         逐物体反壳描边
##     res://assets/shaders/detect_screen_outline.gdshader  屏幕空间描边
##     res://assets/shaders/detect_scan.gdshader            表面扫描带（挂在描边的 next_pass）
## · 本文件**不发任何信号**：状态由上层轮询 is_casting() / ran_out_of_mana() 获取；
##   探测结果也不对外暴露，只体现在画面的轮廓上。
##
## ---------------------------------------------------------------- 生命周期与清理红线
##
## · 本节点随施法创建、随换术法/结束施法被释放，清理统一走 _exit_tree()。
## · 凡是"临时挂到别处"的东西都必须在 _exit_tree() 里显式回收：
##     相机下的全屏面（_screen_quad）、SubViewport 遮罩（_mask_vp/_mask_cam）、
##     以及各网格的 material_overlay / transparency / layers（经 SurfaceOverlay.detach）。
##   漏掉任何一项，场景里就会留下永久描边或孤儿节点。
## · 无头自检时相机通常不跟随玩家，必须把 screen_cull 关掉（见该字段注释），
##   否则屏幕剔除会把一切命中拒掉；那时该测的是"检测/轮廓/过期"，不是取景。
##
## 公共模块：瞄准方向 + 施法起点（flame_jet_particles / flame_visual 等共用同一份，
## 避免同一段逻辑存两份、只修一处导致两边行为不一致）。
## 本文件只用它来转发 aim_dir() / origin_global()；波纹本身与朝向无关（圆心固定在施法点）。
const SpellAim := preload("res://scripts/spells/spell_aim.gd")
## ★ 公共模块：物体表面绘制（material_overlay 挂/还原 + 球查询找物体）。
##   扇形选点器（火焰推进）用的是同一份 —— 用户要求"别各写一份"。
const SurfaceOverlay := preload("res://scripts/spells/surface_overlay.gd")
## 地面波纹：按径向距离画一圈圈**细线**（正圆 + 衰减震荡），不用实体圆环
const RIPPLE_SHADER := "res://assets/shaders/detect_ripple.gdshader"
## 描边：视图空间外扩的剪影线，内部按深度丢弃（物体外观不受影响）
const OUTLINE_SHADER := "res://assets/shaders/detect_outline.gdshader"
## 屏幕空间描边（全屏后处理，靠深度突变找轮廓）—— 四周都有线、线宽恒定
const SCREEN_OUTLINE_SHADER := "res://assets/shaders/detect_screen_outline.gdshader"
## 扫描带：波面经过物体时，一道亮带贴着物体表面推过去（挂在描边的 next_pass 上）
const SCAN_SHADER := "res://assets/shaders/detect_scan.gdshader"

# ==================== 导出参数 · 表面扫描带 ====================
# ---- 表面扫描带（进阶效果）：波面在物体表面"游走" ----
## 是否启用表面扫描带：波面经过物体时，一道亮带贴着它的表面推过去。
## false = 只留描边；省掉一个 next_pass，低端机可以关掉摊薄像素开销。
@export var surface_scan := true
## 扫描带颜色（默认青蓝）。与 line_color / wave_color 同一色系，
## 让"波纹 + 描边 + 扫描带"被整体识别为同一套探测视觉。
@export var scan_color := Color(0.35, 0.95, 1.0)
## 扫描带整体透明度（0~1）。默认 0.85 = 明显但不刺眼；
## 调到 1.0 在亮地形上容易糊成一片白，调到 0.3 以下基本看不见。
@export var scan_alpha := 0.85
@export var scan_band_width := 0.7      ## 前沿亮带宽度（米）
@export var scan_band_gain := 1.6       ## 前沿亮带强度
@export var scan_trail_len := 2.2       ## 身后余辉长度（米）
@export var scan_trail_gain := 0.10     ## 身后余辉强度（多圈会**叠加**，所以调得低）
@export var scan_climb := 0.8           ## >0 = 波面沿表面往上爬（每米高度减少多少到达半径）
@export var scan_edge_boost := 0.6      ## 掠射角增强
@export var scan_pattern_freq := 1.4    ## 横向条纹频率（0 = 关）
@export var scan_pattern_gain := 0.25   ## 横向条纹强度

# ==================== 导出参数 · 核心节奏与耗蓝 ====================
# ---------------------------------------------------------------- 可调参数
# ★ 这一段是本文件的三个主旋钮：mana_per_cast / repeat_interval / wave_speed。
#   三者的组合决定"探一米要花多少蓝" ≈ mana_per_cast / (repeat_interval × wave_speed)，
#   调平衡先动它们，其余都是观感参数。
## 每发一圈的耗蓝（Mana 单位；Mana.max_mana 默认 100、regen_per_sec 默认 6/s）。
## 12.0 的取值意图：约两秒回蓝 —— "点一下放一圈"不心疼，一直按住会明显吃紧。
## 调大 → 施法更贵，很快 ran_out；调小 → 能连续刷圈，"探测有代价"的设计被削弱。
## ★ 蓝不够时这一圈**整圈不发**（不是发一半），并置 _ran_out = true 通知上层。
@export var mana_per_cast := 12.0          ## 每发一圈的耗蓝
## 按住时每隔多久再发一圈；0 = 只发一圈。
## ★ 真·多圈模式下这个值要**小**：每一圈都是一个独立脉冲（各自一次球查询 + 自己的轮廓时序），
##   所以 0.28 秒 ≈ 每 7 米一圈 —— 你看到的每一圈都在真的扫描。
@export var repeat_interval := 0.28
@export var wave_speed := 26.0             ## 波面扩张速度（米/秒）—— 太慢会显得拖
@export var outline_life := 1.0            ## 轮廓显示多久（秒）—— 需求指定 1s

# ==================== 导出参数 · 逐物体描边 ====================
# ---- 描边：动漫风格（物体保持原样，只在外缘加一圈线）----
## 描边线颜色（默认青蓝，与波纹/扫描带同色系，一眼能认出是探测效果）。
## 只影响**线**，不动物体自己的材质。
@export var line_color := Color(0.30, 0.95, 1.0)
## 线宽（**像素**）：按视深度缩放，远近一样粗
@export var outline_px := 1.0
## 揭示边缘的柔化宽度（米）：线条随波面长出来时，前沿这一小段是渐入的
@export var reveal_soft := 0.35
## 让轮廓**提前**这么多米出现。用户反馈"轮廓绘制有延迟" —— 因为轮廓严格等波面扫到
## 才画，观感上会慢半拍；提前一点点（相对 26 m/s 只有几十毫秒）就没有"在等"的感觉了。
@export var reveal_ahead := 1.2
## 物体半透明度（0 = 保持原样）。调大一点更接近"只显示轮廓"，
## 又不至于像早先的实心填充那样糊成黑疙瘩。
@export_range(0.0, 0.95, 0.01) var ghost := 0.0

# ==================== 导出参数 · 屏幕空间描边与物体遮罩 ====================
# ---- 屏幕空间描边（推荐）：四周都有线、线宽固定为像素，与视角无关 ----
## true = 用屏幕空间后处理描边（全屏 pass，需要 mask 通道才能不描到草）
## false = 用**逐物体反壳描边**（material_overlay）—— 草是结构性排除的，推荐
@export var screen_outline := false
## 屏幕空间描边的线不透明度（只在 screen_outline = true 时有效）。
## 0.9 是"线要看得清、又不盖住物体本身"的经验值；调低会让轮廓在亮背景上消失。
@export var screen_line_alpha := 0.9
@export var screen_sample_px := 1.0        ## 邻域采样偏移（像素）= 线宽（1.0 ≈ 1px 细线）
@export var screen_depth_threshold := 2.2  ## 视深度梯度阈值（米）：实测 0.6 会把草也描出来，2.2 只剩大物体
## 物体遮罩通道（UE Custom Depth/Stencil 的 Godot 等价物）。
## 被探测到的网格临时挂到 MASK_LAYER，由一台 cull_mask 只开该位的相机渲进 SubViewport；
## 着色器把这张图当"Custom Depth"做邻域边缘检测 —— 图里只有被探测到的物体，
## 草/地形根本不在其中，所以草是**结构性排除**，不靠名字也不靠过滤。
##
## ★ 判断遮罩对不对**不能**用 get_texture().get_image()：Godot 未修复的 #91828 表明
##   transparent_bg 打开时 CPU 回读不可信（返回全 0），而 GPU 端采样正常。
##   我上一轮就是被这个回读误导，误判"遮罩没渲染"并把方案关掉了。**只能靠截图验证**。
@export var mask_by_objects := true
## 波纹是否**跟随角色移动**（true = 圆心每帧跟到角色脚下）
@export var follow_caster := true

## 遮罩用的渲染层。
## ★★ 用**低位**（第 8 位），不要用 1<<19 那种最高位：实测用 1<<19 时，
##    网格的 layers 确实置位了、遮罩相机的 cull_mask 也是同一位（AND 非零），
##    但子视口里**看不到任何物体**（遮罩一片背景色）—— 高位在渲染端疑似不被支持。
const MASK_LAYER := 1 << 7
## 扫描带一次最多叠加几圈（与 detect_scan.gdshader 里的 vec4[8] 对应）
const SCAN_MAX_WAVES := 8

# ==================== 导出参数 · 地面波纹 ====================
# ---- 地面波纹：细线环 + 波前亮带 + 噪声扭曲 ----
## 波纹颜色（青蓝）。着色器按乘性亮度使用，所以调暗会**同时**削弱细环与波前亮带。
@export var wave_color := Color(0.35, 0.90, 1.0)
@export var wavelength := 9.0              ## 相邻细环的间距（米），越小越密（9.0 = 圈数更少）
@export var sharpness := 180.0             ## 越大，线越细
@export var decay := 2.8                   ## 后面的环衰减得多快（越大越少）
## 波纹整体亮度系数。调大 → 直接过曝（细线胀成粗白线，失去"细线"观感）；
## 调小 → 地面本身较亮时看不见。1.25 是"亮但不糊"的取值。
@export var wave_intensity := 1.25
@export var wave_lift := 0.12              ## 波纹抬离地面多少（免得被地表吃掉）
@export var wave_warp := 0.55              ## 噪声扭曲幅度（米）：0 = 标准圆
@export var lead_width := 0.5              ## 波前亮带宽度（米）
@export var lead_gain := 0.4               ## 波前亮带强度（真·多圈下细环才是主角，亮带压弱）
## 细环的截断窗口（米）。真·多圈模式下每个脉冲只画一圈，
## 所以"一圈"= 一个真实脉冲（有独立的球查询与轮廓时序），不是视觉余波。
@export var ring_window := 1.5
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
## 一次球查询最多接受多少条命中（传给 SurfaceOverlay.collect_meshes 的第二个实参）。
## 512 是"够用且不至于一帧吃太多内存"的经验值：密集场景里**命中数远大于被接受的物体数**
## （地形、植被、玩家自己、屏外物体都会在后续过滤里被丢掉），
## 调太小会**凭空漏掉**远处物体（表现为"有的东西扫不出来"），调大只多花一点遍历时间。
@export var max_results := 512

# ==================== 内部状态 ====================
## 波动画：中心到当前半径
## 当前是否处于"按住施法"状态（由 start_cast / stop_cast 维护）。
## ★ 它**不代表**还有波纹在飞：松手后立刻变 false，但已发出的波纹会继续扩散、轮廓自然到期。
## 上层用它判断"这次按住是否还在施法"，所以**不要**拿它当"效果演完了吗"的依据。
var casting := false

## 瞄准/起点公共模块实例（spell_aim.gd）。本术法不自己算方向，只把它的两个查询转发出去，
## 保证和别的术法接口一致（见 aim_dir / origin_global）。
var _aim := SpellAim.new()
## 玩家根节点引用（由 setup 注入）。用途：取脚下位置当圆心、取它的 collision_mask 当探测掩码、
## 并在球查询里排除它自己。所有使用点都先查 null / is_instance_valid —— 换场景后它会变野指针。
var _player: Node3D = null
var _pulses: Array = []                    ## 在飞的波纹：{center, r, max_r, ripple}
## ★ 公共模块实例：挂/还原材质 + 找物体（扇形选点器共用同一份实现）
var _surface := SurfaceOverlay.new()
var _outlined: Dictionary = {}             ## 实例 id -> {node, meshes:[{mi, prev}], until}
## "最近一次尝试发波因为蓝不够而失败"的标志，由 ran_out_of_mana() 对外暴露。
## ★ 一旦为 true 会**一直保持**到下一次成功扣蓝才复位（见 _emit_pulse）：
##   这样上层/HUD 在两圈之间的空档里也能稳定读到"没蓝了"，不会一闪而过。
var _ran_out := false
## 按住施法时"距下一圈还有多久"的倒计时（秒）。只在 repeat_interval > 0 时被使用：
## 每发完一圈就重置为 repeat_interval；stop_cast 时归零 ——
## 于是"松手再按"能**立刻**发出新的一圈，不必等上一轮的余量（手感上不发涩）。
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


# ==================== 生命周期 ====================
## 节点进入场景树时由引擎调用（SpellCaster 把它 add_child 到玩家父节点之后）。
##
## 参数：无（引擎回调）。返回值：无。
## 副作用：开启 _process（set_process(true)），并把 process_priority 提到 1000。
## ★ 优先级必须**很高**（数字越大越晚执行）：本脚本在 _process 里同步遮罩相机，
##   而相机 rig 的跟随是在它自己的 _process 里做的；顺序反了遮罩就慢一帧，
##   表现成"轮廓跟不上镜头"（用户报过轮廓延迟）。
## 注意：这里不读场景、不找玩家（引用一律由 setup 注入），所以可以安全地反复实例化。
func _ready() -> void:
	# 显式开启 _process：挂进场景树默认就是开的，写出来是为了表达"每帧都要推进"的意图
	# （而且如果以后有人把本节点的 process_mode 改掉，这行会提醒他这里的依赖）。
	set_process(true)
	# ★ 处理优先级提到很高，让本节点的 _process **在相机 rig 之后**执行。
	#   遮罩相机是在这里同步主相机变换的；如果它先执行、相机 rig 后执行，
	#   遮罩就会**慢一帧**，画出来的轮廓看起来"跟不上"（用户报过轮廓有延迟）。
	process_priority = 1000


## 由 SpellCaster 在实例化本视觉之后调用一次，注入玩家与法杖引用（接口约定见 spell_caster.gd 的 SPELLS）。
##
## 参数：
##   player — 玩家根节点（Node3D）。后续一切以它的 global_position 作为波纹圆心；
##            若它恰好是 CollisionObject3D，还会用它的 collision_mask 当探测掩码（见 _mask），
##            并在球查询里排除它自身（否则每次探测都会把玩家自己描一圈）。
##   staff  — 手杖节点（Node3D）。本术法**不**从杖头出发（波纹从脚下发），
##            它只被转交给 SpellAim，用于保持与其它术法的接口一致、并让兜底起点可用。
## 返回值：无。副作用：写 _player，初始化 _aim（host = self）。
## 注意：不做校验；传 null 时 _emit_pulse 会直接返回（什么都不放，也不报错）。
func setup(player: Node3D, staff: Node3D) -> void:
	_player = player
	_aim.setup(player, staff, self)


# ---------------------------------------------------------------- 对外
# ==================== 对外接口（SpellCaster 调用） ====================
## 上层"按住施法"期间**每帧**都会被调用（spell_caster.gd 的施法段：casting 为真就每帧 call 一次）。
##
## 参数：无。返回值：无。
## 副作用：第一次调用（casting 尚为 false）时**立刻**发一圈，并把 casting 置 true；
##         之后每帧重复调用只维持 casting = true，不再发圈 ——
##         续发由 _process 里的 _cooldown 倒计时按 repeat_interval 触发。
## ★ 为什么第一圈要抢在 _process 之前发：等下一帧的话，"按下"与"第一道波纹"之间会空一帧，
##   手感上像没反应；这里立刻放，按下即有。
## 注意：本函数可以被安全地重复调用（幂等），上层不必自己去重。
func start_cast() -> void:
	if not casting:
		# 按下那一瞬：立刻发一圈（不等 _process，避免第一帧从静默开始）
		_emit_pulse()
	casting = true


## 上层不再按住时**每帧**都会被调用（与 start_cast 交替出现）。
##
## 参数：无。返回值：无。
## 副作用：casting = false；_cooldown 归零（下次按下能立刻出圈）。
## ★ 刻意**不清理**在飞的波纹与已画出的轮廓（见函数内注释）：
##   它们是独立于角色的世界事件，松手后该继续扩散/自然到期。
func stop_cast() -> void:
	casting = false
	# ★ 刻意**不**清掉在飞的波纹和已画出的轮廓：
	#   波纹是独立于角色的世界事件，松手后它该继续扩散、轮廓该自然到期消失。
	#   在这里清掉会变成"一松手效果就没了"，观感很廉价。
	_cooldown = 0.0


## 语义：**"当前是否正在按住施法"**，不是"是否还有波纹在飞"。
##
## 参数：无。返回值：casting 的当前值（bool）。
## 调用时机：上层轮询（spell_caster.gd 用 is_casting 判断一次性法术的实例是否演完）。
## ★ 松手后立刻返回 false，而此时波纹可能还在扩张、轮廓也还亮着 —— 这是有意为之：
##   若让它等到所有波纹结束，外层会以为"施法还没完"，按住续发的语义会变得含糊。
func is_casting() -> bool:
	return casting


## 语义：上一发是否因为蓝不够而**没放出来**（_emit_pulse 里的失败标志）。
##
## 参数：无。返回值：true = 最近一次尝试扣蓝失败；false = 最近一次扣蓝成功（或还没试过）。
## 调用时机：上层/HUD 轮询，用于提示"没蓝了"。
## 注意：它不是"蓝量是否为空"的实时查询 —— 回蓝后也不会自动变回 false，
##       只有**成功发出**新的一圈（Mana.try_spend 返回 true）才会复位。
func ran_out_of_mana() -> bool:
	return _ran_out


## 施法朝向（世界空间、水平单位向量），转发自 SpellAim.aim_dir()。
##
## 参数：无。返回值：Vector3，长度为 1；所有来源都失效时返回 SpellAim 内部记住的上一次方向。
## 说明：本术法的波纹是**以施法点为圆心的正圆**，与朝向无关；
##       保留这个接口只为"和别的术法长得一样"（上层与通用选点不对术法特判）。
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 施法起点（世界坐标），转发自 SpellAim.origin_global()（默认取"角色身前"那个点）。
##
## 参数：无。返回值：Vector3；拿不到玩家/法杖时返回宿主自身位置。
## ★ 注意：这**不是**波纹的圆心 —— 圆心用的是 _player.global_position（脚下），
##   因为地面波纹必须贴地；这里只是给通用逻辑/调试看的接口点。
func origin_global() -> Vector3:
	return _aim.origin_global()


# ---------------------------------------------------------------- 每帧
# ==================== 每帧更新 ====================
## 每帧驱动（process_priority = 1000，排在相机 rig 之后执行，见 _ready）。
##
## 参数：delta — 距上一帧的秒数，用于推进 _clock、波纹半径与续发倒计时。
## 返回值：无。
## 副作用（顺序敏感，别随意调换）：
##   1. _clock 累加 —— 自检可手动步进的游戏时钟（见 _clock 注释）；
##   2. 清空 _boxes —— 它只表示"**本帧**被探测到的物体包围盒"，每帧重建；
##   3. _tick_pulses 推进所有在飞的波纹并顺带做检测；
##   4. _update_reveal 把揭示半径写进每个物体的描边 / 扫描带材质；
##   5. _update_screen_outline 决定全屏描边 pass 是否打开并喂参数；
##   6. _expire_outlines 还原到期物体的材质。
## ★ 以上六步在**不施法时也照跑**，只有后面的续发段会 return ——
##   松手后波纹仍要继续扩张、轮廓仍要到期（这就是"一松手效果就没了"的反例）。
## 注意：_boxes 必须在检测**之前**清空，否则屏幕描边会拿到上一帧的旧盒子。
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
# ==================== 发波与推进 ====================
## 发出**一圈**新波纹：扣蓝 → 定圆心 → 推半径上限 → 建波纹平面 → 登记进 _pulses。
##
## 参数：无（一切取自成员变量与导出参数）。
## 返回值：无。
## 副作用：扣 Mana、写 _ran_out、new 一个 MeshInstance3D 并 add_child 到本节点、_pulses 追加一项。
## 调用时机：start_cast 的第一次调用；以及按住期间每 repeat_interval 秒一次（见 _process）。
## 注意：
##   · 蓝不够时**整圈不发**并置 _ran_out = true（不半发、不留残影）；
##   · 圆心在这一瞬定死（此后是否跟随角色，由 follow_caster 在 _tick_pulses 里决定）；
##   · 波纹节点是本节点的子节点，本节点被释放时会跟着没（_exit_tree 再兜一次）。
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
	# 半径上限在**发波这一瞬**算定并写进材质（着色器据此决定细环密度与衰减），
	# 所以同一条波纹之后不会再因为相机拉远拉近而改尺寸/改形状。
	var ripple := _make_ripple(max_r)
	add_child(ripple)
	ripple.global_position = center + Vector3.UP * wave_lift
	_pulses.append({
		"center": center,
		"r": 0.0,
		"max_r": max_r,
		"ripple": ripple,
	})


## 推进所有在飞的波纹：半径 += wave_speed × delta → 更新视觉 → 做一次检测 → 处理到顶的圈。
##
## 参数：delta — 帧间隔（秒）；半径增量乘了 delta，所以扩张速度与帧率无关。
## 返回值：无。
## 副作用：改每一项的 r（必要时还有 center）、移动波纹节点、触发 _detect（挂描边）、
##         到顶时 queue_free 波纹节点、重写 _pulses。
## ★ 用"重建 alive 列表"而不是边遍历边删：遍历中修改 _pulses 会打乱迭代，
##   而且"到顶"的圈还要顺手释放自己的节点，分开写更清楚（_expire_outlines 同思路）。
## 注意：轮廓**不在这里清** —— 它有独立的 outline_life 寿命，由 _expire_outlines 负责。
func _tick_pulses(delta: float) -> void:
	if _pulses.is_empty():
		return
	var alive: Array = []
	for p in _pulses:
		var pulse: Dictionary = p
		# 半径按 delta 推进而不是固定步长：低帧率时一帧可能跳好几米，
		# 这正是"检测必须查整球、不能只查薄环"的原因（薄环会漏掉跨过去的那批物体）。
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


## 把"波前推进到哪"写进波纹材质（progress = radius / max_r，归一到 0~1）。
##
## 参数：
##   node   — 波纹节点（声明成 Variant 是因为从字典里取出来不带类型；null / 已释放会被忽略）。
##   radius — 当前波面半径（米）。
##   max_r  — 本圈的最大半径（米），用作归一化分母；maxf(..., 0.001) 是防 0 除。
## 返回值：无。
## 副作用：只改着色器参数，**不移动**节点（位置由 _tick_pulses / _emit_pulse 负责）。
## ★ 传归一化进度而不是米：着色器只关心"推进到几成"，
##   这样同一条着色器能被任意屏幕尺寸 / 任意 max_r 复用。
func _apply_ripple(node: Variant, radius: float, max_r: float) -> void:
	if node == null or not is_instance_valid(node):
		return
	var mi := node as MeshInstance3D
	var mat := mi.material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter("progress",
				clampf(radius / maxf(max_r, 0.001), 0.0, 1.0))


# ---------------------------------------------------------------- 检测
# ==================== 检测（球查询 + 过滤） ====================
## 一次检测：以 center 为球心、radius 为半径做球查询，逐条命中做过滤并挂描边。
##
## 参数：
##   radius — **当前波面半径**（米），直接当作查询球半径（查整球而非薄环，理由见文件头【2】）。
##   center — 本圈圆心（世界坐标；follow_caster 打开时每帧被刷成角色脚下）。
##   max_r  — 本圈的最大半径（本函数内不参与裁剪，只随 pulse 传给描边做揭示语义）。
##   pulse  — 本圈的字典（center/r/max_r/ripple），会原样塞进描边条目，供揭示半径取最大使用。
## 返回值：无。
## 副作用：给命中的可视节点挂 material_overlay（或只 mark_layers）、写 _boxes 与 _outlined。
## 调用时机：_tick_pulses 里每圈每帧一次（本帧最贵的一段：物理查询 + 包围盒计算）。
## ★ 故意**不用"环形查询"**：整球查询每帧都是全量命中，靠轮廓 1 秒寿命在观感上实现"只亮波前"；
##   若改成薄环，低帧率会漏检（见文件头【2】的推理）。
## 注意：max_results 会截断命中列表，物体极密时靠它兜底防止一帧爆量。
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

	# ★ 找物体（球查询 + 碰撞体->可视节点解析 + 包围盒）交给**公共模块**，
	#   扇形选点器用的是同一份实现 —— 两边不再各写一遍。
	#   球心略微抬高：以角色脚下为中心的话，一半球体在地下，浪费且容易吃到地形。
	# 把玩家自己排除在球查询之外：不排除的话，玩家身上的碰撞体每次都会被命中，
	# 于是每一圈探测都会给玩家自己描一圈轮廓（用户会看到"自己被描边"）。
	var exclude: Array[RID] = []
	if _player is CollisionObject3D:
		exclude.append((_player as CollisionObject3D).get_rid())
	var now := _now()
	for h in SurfaceOverlay.collect_meshes(world, center, maxf(0.05, radius),
			_mask(), exclude, Callable(), max_results):
		var node := h["node"] as Node
		var visual := h["visual"] as Node
		var box: AABB = h["box"]
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
	# 0.0025 = (0.05 m)^2：用"5 厘米以内"当近重合判据。
	# 同一个可视父节点下的多个碰撞体会解析出同一个可视节点、同一个盒子（只差浮点误差），
	# 不判重的话 16 个名额会被同一个物体占满，别的物体反而进不来。
	for b in _boxes:
		if (lo - (b as Array)[0] as Vector3).length_squared() < 0.0025:
			return
	_boxes.append([lo, box.position + box.size])


# ---------------------------------------------------------------- 物体遮罩（SubViewport）
# ==================== 物体遮罩（SubViewport） ====================
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
	# 每帧都重渲染：遮罩相机每帧跟着主相机同步变换、被探测物体集合也会变，
	# 用 UPDATE_ONCE / WHEN_VISIBLE 会拿到过期的一帧（表现成轮廓与画面错位）。
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


# ==================== 可探测性过滤（玩家 / 名字 / 地形） ====================
## 一组网格的世界包围盒并集（转发到公共模块）
func _visual_aabb(visual: Node) -> AABB:
	return SurfaceOverlay.visual_aabb(visual)


## 碰撞体 -> 真正持有网格的节点（转发到公共模块）。
## ★★ 本项目的碰撞体与网格常常是**兄弟**：必须**向上找**（最多 3 层）。
##    只查"碰撞体自己的子节点"的话每个物体都会判成"没有可见网格"，
##    结果 outlined 恒为 0 —— 波纹在跑，却什么都描不出来（探测波实测踩过）。
func _resolve_visual(node: Node) -> Node:
	return SurfaceOverlay.resolve_visual(node)


## 可探测性总判定（每个命中问一次）：玩家自身 / 地形与植被关键字 / 是否在地形之上。
##
## 参数：
##   node   — 命中的碰撞体节点（用于"是不是玩家"的判断）。
##   visual — 解析出来的可视节点（名字过滤要**沿它向上**逐级查父节点）。
##   center — 本圈圆心；保留参数，当前版本不直接参与判定。
##   box    — 可视节点的世界包围盒（交给 _above_terrain 当射线起点）。
## 返回值：true = 这个物体可以描轮廓。
## 副作用：可能触发一次向下的地形射线（结果按实例缓存在 _terrain_ok，只问一次）。
## ★ 名字过滤必须从 visual 向上查：地形碰撞体的父节点才是 Terrain3D，
##   只看碰撞体自己的类名是查不到地形的。
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
	# 连"否"的结果也缓存：地形不会在同一次施法里凭空出现/消失，
	# 不缓存的话每圈每帧都要为同一批物体重复打射线，纯属浪费。
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
	# 用显式栈做深度优先遍历而不是递归：场景树深时递归有栈溢出风险；
	# 这里只关心"找到第一个类名含 terrain 的节点"，遍历顺序无所谓。
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


## 从 from_node 的子树里找**第一个非 0 的碰撞层**（显式栈做深度优先，顺序无所谓）。
##
## 参数：from_node — 遍历起点（调用方传的是"类名含 terrain 的节点"）。
## 返回值：碰撞层位掩码（int）；找不到返回 0（调用方据此走"无法判定 -> 放行"的降级路径）。
## 用途：给 _above_terrain 的向下射线当 collision_mask。
## ★ 只取第一个、不做合并：地形通常就是一个大碰撞体，任何一块能挡住向下的射线都够用。
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


# ==================== 屏幕判定与最大半径推导 ====================
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
	# screen_margin = 1.2 表示"允许到屏幕的 1.2 倍"，也就是四边各放宽 10%，
	# 所以外扩量是 (1.2 - 1.0) / 2 = 0.1 → m 乘上宽高就是每边多出来的像素数。
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


## 由相机反推"波纹最多该扩到多大"：把视口边框投到角色脚底所在的水平面，
## 取最远落点距离 × screen_margin，并夹在 max_radius_cap 以内。
##
## 参数：center — 本圈圆心（世界坐标）；用它的 y 作为"水平面"的高度。
## 返回值：最大半径（米）。相机/投影不可用时返回 max_radius_fallback（兜底 16 米）。
## 副作用：无（纯计算，可安全地每圈调用一次）。
## 注意：结果只在**发波那一瞬**用一次（写进波纹材质），
##       所以同一条波纹不会因为之后相机移动而改尺寸或形状。
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
	# 除了四角，再取四条边的中点：俯视角倾斜时"最远落点"往往出现在屏幕边的中段
	# （比如画面上边中点在远处的投影比两个角更远），只投四角会低估波纹半径。
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
# ==================== 描边：挂载 / 揭示 / 到期 ====================
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
		for mi in SurfaceOverlay.visible_meshes(visual):
			meshes.append(mi as MeshInstance3D)
		if meshes.is_empty():
			return
		if screen_outline:
			# 屏幕空间模式：**只把网格挂到遮罩层**，材质一点不动。
			# 遮罩图里就只剩"被探测到的物体"，花草（没有碰撞体、探测不到）自然不在其中。
			if mask_by_objects:
				for mesh in meshes:
					_surface.mark_layers(mesh, MASK_LAYER)
			entry = {"node": visual, "meshes": meshes, "pulse": pulse}
		else:
			var hull := _make_outline_material()
			# 扫描带挂在描边的 next_pass 上：同一次绘制的后续 pass。
			# 这样只用一个 material_overlay 槽位就能同时有描边 + 表面扫描带。
			# （顺序上让描边先建好，即使 next_pass 出问题也只是少了扫描带，描边不受影响。）
			var scan: ShaderMaterial = null
			if surface_scan:
				scan = _make_scan_material()
				hull.next_pass = scan
			for mesh in meshes:
				# ★ 只加 overlay，**不动物体自己的材质**：物体保持原样，只在外缘多一圈线。
				#   内部由深度测试自然挡掉（不再手工查深度纹理，那会丢掉靠镜头那侧的边线）。
				#   挂/还原（含透明度、可见层）由公共模块统一负责。
				_surface.attach(mesh, hull, ghost)
			entry = {"node": visual, "meshes": meshes, "mat": hull, "scan": scan, "pulse": pulse}
		_outlined[id] = entry
	# ★ 真·多圈：同一个物体每帧会被**多个**脉冲命中（球查询覆盖整个圆盘内）。
	#   这里只保留**半径最大**的那个 —— 揭示半径取最大，已经扫过的部分才会保持显示；
	#   若取"最后一次命中"的（最小圈），轮廓会随着内圈推进而**往回缩**。
	var cur = entry.get("pulse")
	if cur == null or float((cur as Dictionary)["r"]) < float(pulse["r"]):
		entry["pulse"] = pulse
	# ★ 每次命中都刷新到期时间：多圈连续命中同一个物体时，轮廓不会在两道脉冲之间闪断，
	#   而是从**最后一次**命中起再活 outline_life 秒。
	entry["until"] = now + outline_life


## 每帧把"波面推进到哪"写进各物体的描边材质 —— 于是线条是随波面**逐步长出来**的，
## 而不是一命中就整个物体全亮（用户报过这个）。
func _update_reveal() -> void:
	if _outlined.is_empty():
		return
	# 真·多圈：把**当前所有活跃脉冲**打包给扫描带着色器，最多 SCAN_MAX_WAVES 圈。
	# 于是物体表面会被每一圈**依次**扫过（每一圈都是真实脉冲）。
	var waves := PackedVector4Array()
	# 定长数组：着色器里声明的是 vec4 scan_waves[8]，长度必须与 SCAN_MAX_WAVES 一致；
	# 没被填满的槽位保持为 0，由 wave_count 让着色器忽略它们。
	waves.resize(SCAN_MAX_WAVES)
	var wn := 0
	for p in _pulses:
		if wn >= SCAN_MAX_WAVES:
			break
		var pd0: Dictionary = p
		var pc: Vector3 = pd0["center"]
		waves[wn] = Vector4(pc.x, pc.z, float(pd0["r"]), 0.0)
		wn += 1
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
		# 扫描带用**真实波面半径**（不加提前量）：亮带本来就该压在波前上，
		# 加了提前量会让它跑到波圈前面，看起来脱节。
		var sc = entry.get("scan")
		if sc != null and sc is ShaderMaterial:
			(sc as ShaderMaterial).set_shader_parameter("scan_waves", waves)
			(sc as ShaderMaterial).set_shader_parameter("wave_count", wn)
			(sc as ShaderMaterial).set_shader_parameter("wave_center", c)
			(sc as ShaderMaterial).set_shader_parameter("wave_radius", r)


# ---------------------------------------------------------------- 屏幕空间描边
# ==================== 屏幕空间描边 ====================
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


## 每帧刷新屏幕空间描边：把"半径最大"的活跃脉冲当作波前，并把遮罩图与包围盒喂给着色器。
##
## 参数：无。返回值：无。
## 副作用：可能创建 _screen_quad、切换它的 visible、同步遮罩相机与 SubViewport 尺寸、
##         写若干个着色器参数（wave_center / wave_radius / mask_tex / box_min…）。
## 调用时机：_process 每帧（screen_outline = false 时第一行就返回）。
## 注意：
##   · 没有活跃脉冲时整块 visible = false，不产生全屏 pass 的开销；
##   · 波前取"半径最大的那圈"而不是最后一圈 —— 否则揭示半径会往回缩（与 _outline 的取法同理）。
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


## 每帧检查描边条目是否到期，到期的**还原物体材质**并从 _outlined 里摘掉。
##
## 参数：无。返回值：无。
## 副作用：调 SurfaceOverlay.detach（恢复 overlay / transparency / layers）、修改 _outlined。
## ★ 先收集 dead 再统一 erase：正在遍历 _outlined.keys() 时直接 erase 会破坏迭代。
## 注意：到期只处理"轮廓"；在飞的波纹归 _tick_pulses 管，两者生命周期互相独立。
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


## 还原一个描边条目涉及的所有网格。
##
## 参数：entry — _outlined 里的一个条目字典（{node, meshes, [mat], [scan], [pulse], until}）。
## 返回值：无。
## 副作用：对每个网格调 SurfaceOverlay.detach(id)，把 overlay / transparency / layers 还原；
##         并把 entry["meshes"] 清空。
## 注意：网格可能在期前就被释放（换场景 / 物体销毁），所以逐个查 is_instance_valid；
##       清空 meshes 是为了让"重复清理"变成空操作（_expire_outlines 与 _exit_tree 都会走到这里）。
func _clear_entry(entry: Dictionary) -> void:
	# ★ 还原（overlay / 透明度 / 可见层）统一交给公共模块
	for item in (entry.get("meshes", []) as Array):
		var mesh := item as MeshInstance3D
		if mesh != null and is_instance_valid(mesh):
			_surface.detach(mesh.get_instance_id())
	# 清空引用：这个条目可能被二次清理（先到期、之后 _exit_tree 又扫一遍），
	# 留着旧列表只会让重复 detach 白跑；清掉后重入就是空操作。
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
# ==================== 工具函数与材质工厂 ====================
## 取本脚本自己的游戏时钟（_clock，单位：秒）。
##
## 参数：无。返回值：自节点创建起累加的 delta 之和。
## ★ 为什么不用 Time.get_ticks_msec()：真实时间**不跟随暂停与 Engine.time_scale**，
##   而且会让"按帧步进"的无头自检无法推进（实测手动步进 1.25 秒，真实时间没过，
##   轮廓永远不过期）。用累加 delta 才能让自检的假时间生效。
func _now() -> float:
	return _clock


## 取当前 3D 相机（返回值可空）。
##
## 参数：无。返回值：Camera3D，取不到（视口不存在 / 视口里没有 3D 相机）时返回 null。
## 副作用：无。
## 注意：无头运行、切到 UI 子视口等情况下都可能取不到；
##       所有调用点都必须自己判 null 并走降级路径（兜底半径 / 跳过剔除）。
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


## 取节点子树里所有**可见**的 MeshInstance3D（转发到 SurfaceOverlay.visible_meshes）。
##
## 参数：node — 起点（通常是解析出来的可视节点）；null 时返回空数组。
## 返回值：Array（深度优先、含自身；不可见的网格会被跳过）。
## 用途：挂 material_overlay、把网格标进遮罩层、以及算世界包围盒。
func _visible_meshes(node: Node) -> Array:
	return SurfaceOverlay.visible_meshes(node)


## 描边材质（作为 material_overlay 逐个物体叠加；草不在探测集合里，天然不会被描）
func _make_outline_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := load(OUTLINE_SHADER) as Shader
	if sh == null:
		push_warning("[DetectPulse] 缺少 detect_outline.gdshader，描边不会显示")
		return m
	m.shader = sh
	m.set_shader_parameter("line_color", line_color)
	m.set_shader_parameter("line_alpha", 1.0)
	m.set_shader_parameter("line_px", outline_px)
	m.set_shader_parameter("reveal_soft", reveal_soft)
	# 像素恒定线宽需要 screen_k = 2*tan(fov/2) / 视口高度
	var cam := _camera()
	var vp := get_viewport()
	var h := float(vp.get_visible_rect().size.y) if vp != null else 720.0
	if cam != null and h > 1.0:
		m.set_shader_parameter("screen_k",
				2.0 * tan(deg_to_rad(cam.fov * 0.5)) / h)
	m.set_shader_parameter("wave_center", Vector3.ZERO)
	m.set_shader_parameter("wave_radius", 0.0)
	return m


## 扫描带材质（挂在描边材质的 next_pass 上）：波面经过时一道亮带贴着表面推过去
func _make_scan_material() -> ShaderMaterial:
	var m := ShaderMaterial.new()
	var sh := load(SCAN_SHADER) as Shader
	if sh == null:
		push_warning("[DetectPulse] 缺少 detect_scan.gdshader，表面扫描带不会显示")
		return m
	m.shader = sh
	m.set_shader_parameter("scan_color", scan_color)
	m.set_shader_parameter("scan_alpha", scan_alpha)
	m.set_shader_parameter("band_width", scan_band_width)
	m.set_shader_parameter("band_gain", scan_band_gain)
	m.set_shader_parameter("trail_len", scan_trail_len)
	m.set_shader_parameter("trail_gain", scan_trail_gain)
	m.set_shader_parameter("climb", scan_climb)
	m.set_shader_parameter("edge_boost", scan_edge_boost)
	m.set_shader_parameter("pattern_freq", scan_pattern_freq)
	m.set_shader_parameter("pattern_gain", scan_pattern_gain)
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
	# 2 × max_r 的方片刚好内切整个圆（直径 = 2 × max_r），UV 天然铺满、径向距离就是半径；
	# maxf(1.0, …) 是防 0：半径为 0 时 PlaneMesh 尺寸为 0，网格会退化到被剔除。
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
		m.set_shader_parameter("ring_window", ring_window)
	var mi := MeshInstance3D.new()
	mi.name = "Ripple"
	mi.mesh = plane
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

# ==============================================================================
# spell_targeting.gd —— 通用法术施法区域选择器（下称"选点器"）
# ==============================================================================
# 【本文件职责】
#   为"需要玩家先选区、再施放"的法术提供区域选择 UI 与几何参数：
#     · 圆盘模式（disc）  ：圆心跟鼠标走，滚轮改**直径**   —— 【火焰灼烧】(flame_scorch) 用
#     · 扇形模式（sector）：圆心锁在主角脚下、中轴指向鼠标，滚轮改**张角** —— 【火焰推进】(flame_advance) 用
#   本文件**不认识任何具体法术**：它只负责算出 (center, radius)，扇形再加 (axis, half_angle)，
#   取参由 spell_caster.gd 完成后交给法术。所以这里不该出现任何法术名/伤害/蓝量之类的逻辑。
#
# 【所属系统】法术系统 / 选点子系统。
#   挂载方式：spell_caster.gd 懒创建本脚本实例（const Targeting := preload(...)），
#   把节点加到 `get_tree().root`（**不是**角色、也不是施法器的子节点），
#   角色引用由 setup() 注入 —— 所以本节点在树中的位置与角色无关，别去 get_parent() 找玩家。
#
# 【关键依赖】
#   · scripts/spells/spell_caster.gd   —— 当前唯一的驱动方，调用顺序见下面【对外接口】；
#   · scripts/spells/surface_overlay.gd —— 物体表面叠加公共模块（与【物体探测】共用同一份实现），
#     本文件只负责"算出该挂哪些网格 + 参数"，挂/还原交给它（防止把物体材质留在场景里）；
#   · scripts/world/terrain.gd         —— duck-typing 调 get_height_at(x, z) 取地形**视觉**高度；
#   · 着色器：assets/shaders/spell_area.gdshader        （圆盘贴图指示圈）
#             assets/shaders/spell_sector.gdshader      （扇形贴合网格）
#             assets/shaders/spell_sector_surface.gdshader（物体表面扇面，备用）
#             assets/shaders/spell_sector_screen.gdshader （屏幕空间覆盖，**定稿方案**）
#   · 默认圆盘贴图：res://assets/textures/法术特效/kenney/particle-pack/circle_02.png
#   · 无 autoload 依赖。地形节点、相机、物理空间都是**运行时查找**（不写死路径/层号）。
#
# 【对外接口】（spell_caster.gd 实际调用到的）
#   · setup(player, camera)   注入角色（camera 可传 null，之后每帧自己从 viewport 取相机）
#   · configure(cfg)          下发法术的 targeting 段（模式 / 直径或张角 / 射程 / 贴图）
#   · begin() / end()         开始 / 结束选点；**end() 必须被调**，否则相机下的全屏面会残留
#   · is_active()             是否正在选点（caster 用它决定要不要 begin）
#   · center() / radius()     当前选区（圆盘 = 鼠标处地面；扇形 = 主角脚下）
#   · axis() / half_angle()   仅扇形：中轴角（弧度）与半角（弧度）
#   · confirm()               主动确认并 emit confirmed(...)；当前 caster 不走它（走 center/radius 直取），
#                             confirmed / cancelled 两个信号在本仓库内**没有连接者**，属保留接口
#   · log_preview_snapshot(tag) 只读诊断：施放/结束时打一次快照
#   · 另有若干纯函数/内部函数被 tools/verify_flame_scorch.gd、tools/verify_flame_advance.gd、
#     tools/shot_helper.gd 通过 call() 直接驱动（自检依赖，改名会连带弄坏自检）。
#
# 【已知的坑与注意事项】（完整过程见 docs/火焰推进与火焰灼烧选点器-技术文档.md）
#   1. 定稿方案是**屏幕空间覆盖**（use_screen_pass = true）：相机前一块全屏面 + 深度纹理重建世界
#      坐标 -> 逐像素判定"在不在范围内"。几何逼近路线（射线贴合网格 / 投影贴花 / 逐物体挂材质）
#      全部只是**备用路径**：它们天然做不到台阶、竖直面、17m 巨型碰撞体，默认不要动。
#   2. 全屏面挂在**相机**下：本节点 `visible = false` 关不掉它 —— end()、切回圆盘、_exit_tree()
#      都必须显式 _hide_screen_pass()，否则技能放完白色扇形留在屏幕上（用户报过的 bug）。
#   3. 圆盘与扇形是**两套独立节点 + 独立材质 + 独立着色器**。曾经把两种形状做进同一个着色器，
#      结果状态互相污染（切回圆盘时圆圈被扇形的角度裁掉）。不要为了省一个 draw 合并它们。
#   4. 扇形材质的 uniform **每帧无条件写**：滚轮改张角时圆心/中轴都没变，写进条件分支里就
#      不会实时生效（自检 verify_flame_advance.gd 有专门的回归用例）。
#   5. 层掩码是本工程最容易写错的一处：`1 << N` 对应的是 **Layer N+1**。
#      Layer 3（值 4）= 导入模型的"假碰撞盒"（ray_ignore_layer_mask = 1<<2 负责排除）；
#      Layer 16（值 32768）= 精修三角网格（prop_visual_layer_mask）。改这两个掩码前，
#      先打印 collision_layer 的**实际数值**再动手（文档 §4 有整张约定表）。
#   6. 本工程"警告即错误"：新增代码必须让静态类型可推断（本文件现有写法已按此约束收敛）。
#   7. 注释与打印文本可以是中文，**标识符一律保持英文**。
#   8. 本文件同一份脚本会被自检脚本 `new()` 出来后**不挂进场景树**（此时 get_tree() 为 null，
#      current_scene 也为 null）—— 所以凡是遍历场景树的函数都必须容忍 get_tree() == null。
# ==============================================================================
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

# ==================== 信号与资源路径常量 ====================
## 确认选点时发出：center = 世界坐标圆心；radius = 半径（米）。
## 扇形模式请再配 axis() / half_angle() 才能完整描述扇区。
## 注意：本文件只有 confirm() 会 emit 它，而当前 spell_caster.gd 不调 confirm()。
signal confirmed(center: Vector3, radius: float)
## 取消选点信号：**本文件内没有 emit 点**（保留接口，供将来"右键取消/超时取消"之类使用）。
signal cancelled()

## 圆盘（火焰灼烧那种圆形指示圈）的默认贴图：Kenney particle-pack 的圆环图，圆心在贴图中心。
## 可被 configure() 的 "texture" 键覆盖；加载失败不会报错，只是继续用上一次的贴图。
const TEX_DEFAULT := "res://assets/textures/法术特效/kenney/particle-pack/circle_02.png"
## 圆盘着色器（spell_area.gdshader）。圆盘材质全局只有这一份，与扇形的两套材质**互不相干**。
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
## 圆盘/扇形的圆周分段数（一圈的顶点数）。调大 = 圆周更圆滑，代价是每圈射线数与顶点数同比上涨。
## 64 是本工程的观感/开销折中值；自检与着色器的 UV 约定都按"一圈 SEGMENTS 个点"来。
const SEGMENTS := 64          ## 圆周分段
## 圆盘径向分段数（从圆心到边缘分几环）。调大 = 贴合地形更细，但每加一环就多 SEGMENTS 根射线。
const RINGS := 6              ## 圆盘径向分段（越大贴合越细）
## ★ 扇形径向分段：比圆盘密一倍（12 = 2×RINGS，**必须是 RINGS 的整数倍**：
##  扇形采样时圆盘的环正好是它的偶数子集 -> 一份采样喂两张网格，圆盘不多打射线）。
##  为什么要更密：坡度限幅下"一级最多爬 step 米"，环太稀时一块 1.6m 的石头只压到
##  一个环上 -> 扇面最高只能爬一个 step（实测 1.02m，石头顶 1.6m 盖不住）。
const SECTOR_RINGS := 12

# ==================== 可配置参数：圆盘 / 通用（配置表可覆盖） ====================
## ---- 以下全部可由配置表覆盖 ----
## 圆盘直径下限（米）。本类内部一律用半径（= 直径/2），直径只是对外与配置表的口径。
## 调小 = 圈最小能收得更紧；滚轮的下界就是它。
var diameter_min := 5.0
## 圆盘直径上限（米）。调大 = 圈能张得更大；副作用是采样环距随半径等比变大 -> 贴合更粗糙。
var diameter_max := 10.0
## 圆心与主角的**水平距离下限**（米）——防止圈压在脚底。begin() 的初始圆心用 range_min + 2。
var range_min := 1.0
## 圆心与主角的水平距离上限（米）= 施法距离。
## 它同时是**扇形半径的硬上限**（_radius_from_angle 里 clamp 到 range_max）。
var range_max := 12.0
## 圆盘滚轮步长（米，作用在**直径**上，不是半径）。调小 = 玩家微调更精细。
var wheel_step := 0.4
## ---- 扇形模式（火焰推进）----
## mode = "sector"：圆心**锁在主角**，中轴跟随鼠标，滚轮改**张角**而不是半径。
## 模式开关：false = 圆盘（圆心跟鼠标、滚轮改直径）；true = 扇形（圆心锁主角、滚轮改张角）。
## 由 configure() 从 cfg["mode"] == "sector" 得出。运行中手改它要自己补一次 _dirty/重建，
## 否则网格/材质与新模式不一致（自检里有用例专门验证"切模式后可见性正确"）。
var sector := false
## ★ 问题三定位用：把选点器的鼠标/圆心/半径打进 Output（默认开，定位完改 false）
## 快照日志总开关：false = log_preview_snapshot() 直接不再被调用（纯日志，不影响任何行为）。
const DEBUG_LOG_PREVIEW := true
## 诊断：鼠标射线命中的东西（节点名 / 类名 / collision_layer 实际值 / 是否 ground 组 / 路径）。
## 由 _update_center_from_mouse() 写；扇形模式不走那条分支，所以这里会一直是上一轮的残留值。
var _dbg_hit_name := "(未命中)"
## 诊断：本次圆心判定走的分支 —— "地面 -> 指哪画哪" 或 "物体 -> 垂直落地"。
var _dbg_decision := "(未判定)"
## 诊断：鼠标射线的**世界命中点**（注意不是圆心：圆心是它归到地面之后的位置）。
var _dbg_hit_pos := Vector3.ZERO

## 已废弃字段：aim_ignore_m 目前在本文件内**没有任何读取点**，保留只为兼容旧场景文件里存下的属性值。
## （曾经的用法：用"命中点比地形高多少"来区分地面/物体 —— 高度判定不可靠，已改为按碰撞层判定。）
## 诊断：打印每次 configure 生效的模式、以及滚轮改的到底是什么
## 已废弃：曾用"命中点比地形高多少"来区分地面/物体 —— 高度判定不妥，
## 现改为按**碰撞层**判定（地形层 = 地面）。保留字段仅为兼容旧场景文件。
@export var aim_ignore_m := 0.4

## ★ 方案 C：选点射线**忽略的层**（默认排除 layer 4 —— 导入模型的碰撞盒常比可见网格
##   大一圈，打在它上面会得到"空气命中"、导致误判）。bit = 层号 - 1，故 layer 4 = 1<<3。
## ★ 精修碰撞层（默认 layer 16 = 1<<15）：你在编辑器里给重点物件加的
##   **三角网格碰撞**请放到这一层 + mask 0 —— 角色 mask=14 看不到它（不会卡进凹面），
##   只有这里的"地面选点射线"会去看它（于是能按真实网格判定、穿栅栏缝）。
@export var prop_visual_layer_mask := 1 << 15

@export var ray_ignore_layer_mask := 1 << 2   ## ★ 实测修正：假碰撞盒在 Layer 3 = 值 4（此前误写 1<<3 = Layer 4，等于没排除）

## 总诊断开关：true = configure() 与滚轮分支各打一行日志（专门用来排查"模式没生效 / 滚轮改错了东西"）。
## 纯日志，不影响行为；确认无误后可置 false 以免刷 Output。
@export var debug_targeting := true
## 扇形**最小**张角（度）。注意这里是**总张角**，不是半角（half_angle() 才返回一半，单位弧度）。
var angle_min := 45.0
## 扇形**最大**张角（度）。调大 = 扇面更张开；半径通常随之更小（见 radius_at_max），所以"越张开越近"。
var angle_max := 80.0
## 扇形滚轮步长（度）。configure() 里 <= 0.001 会被强制改回 5.0（防配置漏写导致滚轮完全失灵）。
var wheel_step_deg := 5.0
## 半径 = 张角的**因变量**（_radius_from_angle 在两端的半径之间线性插值），两端值都来自数值表。
## 本工程的取值是"张角越小、半径越远"（窄扇形打远、宽扇形打近），改数值表时保持这个手感。
var radius_at_min := 10.0      ## 最小张角时的半径（数值表给的）
var radius_at_max := 6.0       ## 最大张角时的半径
## 当前张角（度），初值 45 度（= 常见的最小档）。只由 configure() 与 _set_angle() 改，
## 半径必须跟着 _radius_from_angle() 重算，别单独改半径。
var _angle := 45.0
## ★ 扇形内圈半径（米）：角色前留出的空白，扇形从这里才开始画（用户要求 0.5m）
@export var sector_inner_m := 0.5
var _axis := 0.0               ## 中轴方向（弧度）
var _tex_path_loaded := ""     ## 已加载的贴图路径（configure 会反复调用，避免重复 load）
## 圆盘贴图路径（res:// 下）。configure() 的 "texture" 键会覆盖它；
## 加载失败（返回 null）时不写材质、也不记录"已加载路径"，于是下次 configure 还会再试一次。
var texture_path := TEX_DEFAULT
# ==================== 圆盘贴合地形：限幅 / 平滑参数 ====================
## ★ 顶点相对"圆心所在高度"最多抬高多少米。
##   不限制的话，圈边打到石墙/高台时整张圆盘会变成"贴着墙往上爬的布"。
## 单位：米（相对圆心高度 y0）。调大 = 圈边允许爬上更高的台/墙；调小更贴地（但高台边缘会被切掉）。
var max_lift := 1.2
## ★ 平滑参数：上下限幅收窄 + 对高度图做多轮三点平均。
##   只限幅不平滑是不够的：相邻顶点一个在地面、一个在墙顶，仍会拉出**尖刺布帘**
##   （用户实测反馈"不规则物体表面显示过于严重，要平滑些"）。
## 抬升限幅（米，相对 y0）：只比圆心高的那一侧生效，和 smooth_drop 一起把"墙顶/深沟"压平。
var smooth_lift := 0.35
## 下沉限幅（米，相对 y0）：防止圈边掉进深沟时整张圆盘被拽下去。与 smooth_lift 独立。
var smooth_drop := 0.35
## ★ 只认"能站的地面"：射线命中面的法线朝上程度低于这个值，就当作**没有地面**
##   （墙基、栏杆、树干都是竖直面）。不这么滤的话，圆盘会**顺着物体的立面铺上去**，
##   观感就是"圈选从物体表面穿过"（用户实测反馈）。
##   滤掉之后圆盘保持在低位，被物体挡住的部分由**深度测试**自然切断 —— 这才是地面指示圈该有的样子。
## 取值 = 命中面法线的 y 分量（0..1）：0.6 ≈ 53° 以内的坡算地面，1.0 = 只认完全水平的面。
## 调小 = 更陡的面也算地面（圈会顺着立面铺上去）；调大 = 只认平地面（缓坡边缘可能被切）。
var ground_normal_min := 0.6
## ★ 相邻顶点允许的最大落差（米）。坡形靠它保住，尖刺靠它削平。
## 坡度限幅：相邻顶点（含径向相邻）允许的最大落差，单位米/级。
## 调大 = 台阶/尖刺保留得更多（更"照实贴"，也更容易出尖刺）；调小 = 更平（缓坡的细节被抹掉）。
var slope_step := 0.22
## 坡度限幅的迭代轮数（每轮只能把落差削掉一个 step）。轮数越多越平；0 = 不做坡度限幅。
var slope_passes := 4

# ==================== 扇形贴合地形参数（与圆盘刻意不同，别照抄圆盘那套） ====================
## ★★ 扇形网格单独一套"贴哪"的参数（用户实测反馈：
##    "扇形选择器，没有在物体表面显示，只对地形有效"）。
##    圆盘那套是**有意**保持低位的（只认能站的地面 + 强平滑 -> 被物体挡住的部分
##    交给深度测试自然切断，见上面 ground_normal_min 的说明），所以**不去动圆盘**，
##    扇形自己一套参数：它得翻到石头/箱子顶上去，玩家才能看清整个扇面。
## 法线朝上程度 >= 这个值才算"表面"（0.35 ≈ 69° 以内的坡）；竖直面（墙/树干）不算。
## 取值 = 命中面法线的 y 分量（0..1）。调小 = 更陡的立面也当"表面"（扇面会爬上墙）；0 = 任何面都收。
var sector_normal_min := 0.35
## 扇形相对"圆心（角色脚下）高度"最多抬高多少米 —— 高墙/大树不该被扇面糊上去
## 单位：米；调小 = 高台/高墙不再被扇面糊上去（矮物件仍由 prop_cover_m 那条口径管）。
var sector_lift_m := 6.0
## 扇形允许向下多少米（台阶、沟）
## 单位：米；调小 = 台阶/沟里的扇面会被削平（下坡地形看起来会"浮"起来）。
var sector_drop_m := 6.0
## 扇形的坡度限幅（米/级）与迭代次数。
## ★ 这里必须**允许台阶**：坡限是"相邻环最多差多少"，而石头的顶面比旁边地面高
##   1.6m —— 限到 0.9 时，压在石头上的那一环会被邻居拽下来，扇面只能在石头顶上
##   鼓一个"包"，石头把中间那块挡掉（实测：只能盖住一圈边框）。
##   2.5 的取法：1.6~2.5m 的石头/箱子/矮台**整块盖住**（每环最多抬 2.5m 够用），
##   而孤立细杆（只压到一环）最多鼓 2.5m —— 不会变成无限尖刺（另有 sector_lift_m 上限）。
## 单位：米/级。调小 = 更贴地形但矮台盖不住；调大 = 矮台整块盖住但细杆会鼓成尖刺（另有 lift 上限兜底）。
var sector_slope_step := 2.5
## 0 = **不做**坡度迭代（扇形靠"允许大台阶 + 不做圆周平滑"来贴合，见 _smooth_heights 的③与 circle 参数）。
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
## 上次重建贴合网格的时刻（秒，Time.get_ticks_msec()*0.001 口径）。初值 -1.0 保证第一次必建。
var _last_build := -1.0
## 上次刷新"物体表面叠加"的时刻（秒）。初值 -1.0 保证第一次必刷。
var _last_surface := -1.0
## 物体表面叠加的最小刷新间隔（秒）：_rebuild_mesh 可能每帧被调
@export var surface_refresh_interval := 0.05

# ==================== 地形识别 / 物体表面叠加（备用路径）开关 ====================
## 只有 _terrain_layer() 会写它（一次遍历整棵场景树）；缓存后地形中途换层不会自动失效，
## 需要重新识别时要重建本节点（或清掉这个缓存）。
## ★ 地面贴合网格只打**地形层**（有 Terrain3D 时按类名找它的碰撞层；找不到就退回全层）。
##   为什么：物体表面交给下面的"表面叠加"处理（那是探测波的做法，任何朝向都准），
##   顶点高度场只用来铺地形 —— 不然物体立面会被拉出"裙边"、物体顶面还会被画两遍。
var terrain_layer_cache := 0
## 运行时找到的地形节点（类名/节点名含 terrain 的那个）；只有拿不到项目封装时才用它读 data.get_height。
var _terrain_node: Node = null
var _terrain_owner: Node = null        ## 项目自己的地形封装（有 get_height_at）
## ★ 扇形"表面叠加"：给扇形范围内的**有碰撞体的物体**挂 material_overlay，
##   形状在片元里按世界坐标算 -> 石头顶/墙面/树干任何朝向都能画出扇面。
## ★ 贴合网格负责覆盖的**贴地物体高度上限**（米）：顶面不高于「脚下 + 这个值」的物体
##   由网格贴住（路面/石板/石棺底座这类矮台），更高的（墓碑/墙/桶）交给物体表面叠加。
##   ★ 这个值必须和 `_extract_rows` 的 prop_cap、以及叠加材质的「跳过贴地物体」阈值
##     **一致**，否则会出现「两边都不管」的空档（用户实测：石棺底座没覆盖到）。
@export var prop_cover_m := 0.6
## 是否启用"物体表面叠加"（给范围内有碰撞体的物体挂 material_overlay 画扇面）。
## false = 完全不挂（省开销）。注意：屏幕空间覆盖/贴花路径下它本来也不参与（见 _refresh_surface 的门禁）。
@export var surface_scan := true
## 注意：只有**带碰撞体**的物体才可能被找到（球查询走物理空间），纯装饰网格不会进结果集。
## 表面叠加查找物体用的碰撞层（默认全层；地形自己会被"是不是 Mesh 可视体"过滤掉）
@export var surface_mask := 0xFFFFFFFF
## ★ 物体表面**填充分量**（0 = 物体上只画边线/外弧，像【物体探测】的探测波亮带；
##   0.55 = 和地面那份一样铺满）。
##   为什么要能调：遗迹/墙面是**大面**，铺满时整块涂白、看着像"白斑"（用户实测反馈）；
##   ★ 现在由着色器**按表面朝向**分配：朝上的面按这个值填满（和地面连成一片），
##   立面保留 55%（墓碑/墙这类竖直面必须看得见，否则等于没涂 —— 用户实测）。
@export var surface_fill_strength := 0.5
## 边线强度是**无量纲亮度倍率**（加色混合）：调大更亮更"发光"，调小更含蓄；地面那份是着色器里写死的 2.2。
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
## 物体表面叠加用的材质（**所有被叠加的网格共用这一份**：形状是片元里按世界坐标算的，共用才对）。
## null = 还没创建（_ensure_surface_mat 懒创建）。
var _surface_mat: ShaderMaterial = null
## ★ 挂/还原材质的活儿交给**公共模块**（【物体探测】的描边+扫描带用的是同一份）
## 公共模块实例：内部 entries 字典记录"哪些网格被挂了材质、以及怎么还原"（instance_id -> 信息）。
## 本文件只调它的 sync/detach/clear，绝不自己改 material_overlay（否则还原信息会丢）。
var _surface := SurfaceOverlay.new()
## _surface.entries 的**只读镜像**，每轮刷新后重新指向同一个字典（兼容旧调试/自检脚本直接读它）。
## 不要往这里写东西 —— 写它也影响不到 _surface。
var _overlaid: Dictionary = {}          ## 兼容旧调试脚本：直接读 _surface.entries

# ==================== 运行时状态（内部，外部只读/由 caster 间接驱动） ====================
## 注入的施法角色（setup 传入）。射线与球查询都会排除它的 RID，避免把角色自己当物体/地面。
var _player: Node3D = null
## 相机缓存。setup 传 null（当前 caster 就是这样）时，每帧从 viewport.get_camera_3d() 兜底取出，
## 所以换相机不需要重新 setup。
var _cam: Camera3D = null
## 圆盘节点（AreaDisc，挂在**本节点**下）。圆盘模式可见、扇形模式隐藏，两者靠 visible 切换。
var _disc: MeshInstance3D = null
## 圆盘材质（spell_area.gdshader）。全场景只有这一份，**不要**给扇形复用（见文件头说明 3）。
var _mat: ShaderMaterial = null
## ★ 扇形独立节点/材质（与圆盘互不影响，见 SECTOR_SHADER 注释）
var _sector_disc: MeshInstance3D = null
## 扇形贴合网格的材质（spell_sector.gdshader，独立于圆盘 _mat）。
## 用屏幕空间覆盖/贴花路径时这个材质不参与绘制（对应节点被隐藏），但参数仍会被写。
var _sector_mat: ShaderMaterial = null
## 当前半径（米）。圆盘 = 直径/2（滚轮改直径时同步折算）；扇形 = 由张角插值算出（_radius_from_angle）。
## 初值 2.5 只是占位：configure() 一进来就会按模式重新算一次。
var _radius := 2.5
## 当前选区圆心（世界坐标，y 是"落在该处地面/地形视觉高度"的 y）。
## 圆盘 = 鼠标落点；扇形 = 主角 global_position（含 y，所以永远贴着脚下）。
var _center := Vector3.ZERO
## 是否正在选点。false 时 _process/_input 都被关掉（本节点挂在 root 下常驻，不做这事会白跑）。
var _active := false
## 脏标记：圆心/半径/张角变化时置真；_process 里过了限流间隔才真正重建网格（见 sector_rebuild_interval）。
## 初值 true：begin() 后第一帧必定建一次网格（_ready 里只建了空节点）。
var _dirty := true
## 是否已经有圆心：false 时 begin() 会把圆心放到主角正前方；之后（松手再按）不重置位置。
var _has_center := false


## Godot 回调：节点进入场景树时调用一次（caster 把本节点加到 root 之后）。
## 做的事：关掉 _process/_input（选点器未选点时应完全休眠）、建好圆盘+扇形两个空节点、整节点隐藏。
## 副作用：add_child（AreaDisc / AreaSector 挂在**本节点**下）、置 visible = false。
## 注意：这里**不**建网格、也**不**读配置 —— 网格要等 begin() 后第一次 _dirty 时由 _rebuild_mesh() 生成，
##   所以此刻读 _disc.mesh 得到的是 null（自检 shot_helper.gd 是显式调 _rebuild_mesh 才拿到网格的）。
##   自检脚本会 new() 出来但不挂树（此时 _ready 不会被调用，get_tree() 为 null，相关函数必须容忍）。
func _ready() -> void:
	# 休眠启动：本节点被 caster 常驻挂在 root 下，不显式关掉就会每帧空跑 _process/_input
	set_process(false)
	# 选点器是事件驱动的：滚轮在 _input 里收，只有 begin() 之后才需要它
	set_process_input(false)
	# 预建圆盘 + 扇形两个节点（切模式只是切 visible，运行中不再增删节点）
	_build_disc()
	# 整节点隐藏：两个网格节点都是本节点子节点，父节点一隐藏就一起不画
	visible = false


## 注入角色与相机（由 spell_caster 在创建本节点后**立刻**调用；自检脚本也会手动调）。
## 参数 player：施法角色。用来取脚下位置、朝向，以及在所有射线/球查询里排除自身 RID。
## 参数 camera：可为 null —— 传 null 时每帧用 get_viewport().get_camera_3d() 兜底（caster 现在就是传 null），
##   所以换相机/换场景不需要重新 setup。
## 返回值：无。副作用：只保存两个引用，不建网格、不改可见性、不发信号。
func setup(player: Node3D, camera: Camera3D = null) -> void:
	_player = player
	_cam = camera


## 参数 cfg：法术 targeting_config() 给的字典。**所有键都可缺省**（缺省 = 保留当前值）：
##   · "mode"                         "sector" 才切扇形，其它/缺省 = 圆盘
##   · "angle_min" / "angle_max"      扇形张角上下限（度，总张角）
##   · "wheel_step_deg"               扇形滚轮步长（度）
##   · "radius_at_min" / "radius_at_max" 扇形张角两端对应的半径（米）
##   · "diameter_min" / "diameter_max" 圆盘直径上下限（米）
##   · "range_min" / "range_max"      圆心与主角水平距离上下限（米）= 施法距离
##   · "wheel_step"                   圆盘滚轮步长（米，作用于直径）
##   · "max_lift"                     圆盘顶点相对圆心的最大抬升（米）
##   · "texture"                      圆盘贴图路径（res://）
## 副作用：写成员变量；**只在贴图路径真的变化时**重新 load 贴图（caster 每次切法术都会重发配置，
##   不加这个判断会反复解码 4K 纹理）；debug_targeting 为真时打一行日志。
## 调用时机：caster 按 `str(cfg)` 签名去重后调用 —— 切换法术（圆盘 <-> 扇形）时必然重新下发，
##   所以这里必须能**从任意模式切到任意模式**，不能假设"只会配一次"。
## 注意：无论从什么模式进来，末尾都会重算 _radius（扇形按张角、圆盘按直径钳制），
##   避免"上一个法术的半径残留给下一个法术"。
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
		# 切法术时张角可能落在新上下限之外（从上个法术继承而来）-> 先夹到合法区间再算半径，
		# 否则 _radius_from_angle 会拿着越界的 _angle 去插值（k 被 clamp，半径与张角对不上）
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


## 把当前张角 _angle 线性映射成半径（**扇形专用**：圆盘模式的半径由直径决定）。
## 返回：半径（米）。映射 = lerp(radius_at_min, radius_at_max, k)，k = (_angle - angle_min) / span，k 夹到 [0,1]；
##   最后再 clamp 到 [0.5, range_max]（防数值表给 0 或超过施法距离）。
## 副作用：无（纯函数；自检 verify_flame_advance.gd 直接调它核对"滚轮改张角后半径是否同步"）。
## 注意：span ≈ 0（angle_min == angle_max）时不做除法、k 直接取 0 -> 半径 = radius_at_min，避免除零。
## 张角 -> 半径（线性插值；两端值都来自数值表，不硬编码）
func _radius_from_angle() -> float:
	var span := angle_max - angle_min
	var k := 0.0 if absf(span) < 0.0001 else clampf((_angle - angle_min) / span, 0.0, 1.0)
	return clampf(lerpf(radius_at_min, radius_at_max, k), 0.5, range_max)


## 返回：当前总张角（度），取值 [angle_min, angle_max]（两者写反时按 min/max 实际夹取）。
## 副作用：无。滚轮改的就是它（_set_angle），半径随之由 _radius_from_angle 重算。
## 扇形张角（度）
func angle() -> float:
	return _angle


## 返回：扇形半角（弧度）= deg_to_rad(_angle) * 0.5。着色器与法术都按"半角"算边界。
## 注意：**单位是弧度**，而 angle()/angle_min/angle_max 是度 —— 日志里要显示角度时记得 rad_to_deg 反算。
## 扇形半角（弧度）—— 交给法术
func half_angle() -> float:
	return deg_to_rad(_angle) * 0.5


## 返回：扇形中轴方向（弧度，XZ 平面的 atan2(z, x) 口径，和着色器 uniform "axis" 同一套）。
## 副作用：无。由 _update_sector() 按"鼠标落点相对主角的水平方向"每帧更新；
##   还没开始选点/鼠标离主角过近时会保持初值 0（= 指向 +X），这是有意的"不抖动"行为。
## 扇形中轴方向（弧度，XZ 平面 atan2(z, x)）
func axis() -> float:
	return _axis


## 开始选点（caster 在"选中的法术声明 has_targeting() == true"时调用）。
## 副作用：_active = true、整节点 visible = true、打开 _process/_input、_dirty = true（下一帧必建网格）；
##   第一次进入时把圆心放在主角**正前方** min(range_min + 2.0, range_max) 米处
##   （用 -basis.z 取前向并把 y 清零，所以角色抬头/低头不影响落点），避免一开圈就压在脚底。
## 调用时机：每帧都可能被调（caster 里 `if not _targeting.is_active(): begin()`），所以必须幂等。
## 注意：幂等是**刻意**的 —— 已激活时直接返回，圆心不会被重置（否则鼠标一动圈就跳回角色前方）。
##   配置（模式/上下限）必须在此之前由 configure() 下发过。
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


## 结束选点（施放确认后由 caster 调用；法术不可用/取消时也会被调用）。
## 副作用（四件事，缺一不可）：
##   · _active = false、整节点 visible = false、关闭 _process/_input；
##   · DEBUG_LOG_PREVIEW 为真时打一次诊断快照（施放/结束时各一次，用户要求不要每帧刷屏）；
##   · _restore_surface()：把物体表面的叠加材质**逐个还原**（绝不能留在场景里）；
##   · _hide_screen_pass() / _hide_decal()：**显式**隐藏相机下的全屏面与贴花 ——
##     它们不在本节点的可见性树里，仅靠 visible = false 关不掉。
## 调用时机：施放之后、切模式之前、以及法术失效时。
## 注意：幂等（未激活直接返回）。扇形模式下 _center 一直等于主角位置，且 _has_center 已为真，
##   所以下次 begin() 不会再走"放到前方的初始化"。
func end() -> void:
	if not _active:
		return
	_active = false
	visible = false
	set_process(false)
	set_process_input(false)
	if DEBUG_LOG_PREVIEW:
		log_preview_snapshot("施放/结束")
	_restore_surface()               # ★ 选点结束：物体表面的扇形叠加必须摘干净
	# ★ 全屏面挂在**相机**下面（不是本节点的子节点），所以 visible = false 关不掉它 ——
	#   必须在结束/退出时显式隐藏，否则技能放出去之后白色扇形还留在屏幕上（用户报的 bug）。
	_hide_screen_pass()
	_hide_decal()


## 返回：是否正在选点（begin() 之后、end() 之前为 true）。
## 副作用：无。caster 用它决定"要不要 begin()"，自检脚本用它判断状态机。
func is_active() -> bool:
	return _active


## 返回：当前选区圆心（世界坐标）。
##   · 圆盘模式：鼠标射线落点（XZ 用命中点，y 归到该处地面）；
##   · 扇形模式：主角 global_position（扇形顶点就在角色脚下）。
## 副作用：无。施放时 caster 直接读它，所以本函数必须是"最新一帧"的值（由 _process 里的更新保证）。
func center() -> Vector3:
	return _center


## 返回：当前半径（米）。圆盘 = 直径/2；扇形 = 张角对应的插值半径。
## 副作用：无。法术用它决定伤害/效果范围，所以它的口径必须与 UI 上看到的圈一致。
func radius() -> float:
	return _radius


## 返回：当前**直径**（米）= _radius * 2。
## 说明：本类内部一律用半径，这个函数只是给"习惯用直径"的调用方/日志一个口径（圆盘的
##   diameter_min/diameter_max/wheel_step 就是直径口径）。
func diameter() -> float:
	return _radius * 2.0


## 返回：true = 已发出 confirmed 信号（说明本来就在选点）；false = 当前不在选点，什么都没发生。
## 副作用：emit confirmed(_center, _radius)；但不改 _active（要不要 end() 由调用方决定）。
## 注意：当前 spell_caster.gd **不走**这个函数（它直接读 center()/radius() 或 axis()/half_angle() 后 end()），
##   所以 confirmed / cancelled 在本仓库内没有连接者，属保留接口；自检/新调用方想用可以直接连。
## 鼠标按下时由施法器调用：返回是否真的确认了
func confirm() -> bool:
	if not _active:
		return false
	confirmed.emit(_center, _radius)
	return true


# ==================== 输入处理（滚轮） ====================
# ---------------------------------------------------------------- 输入
## Godot 输入回调（由 begin() 打开、end() 关闭；未选点时第一行就返回）。
## 参数 ev：本帧的输入事件。只关心 **滚轮的按下** 事件（WHEEL_UP / WHEEL_DOWN），
##   鼠标移动一概不处理（圆心/中轴是在 _process 里按鼠标**当前位置**算的，不靠事件）。
## 行为：扇形 -> _set_angle(±wheel_step_deg)（改张角，半径随之重算）；
##       圆盘 -> _set_diameter(diameter() ± wheel_step)（改直径）。
## 副作用：改 _angle/_radius、置 _dirty；并把事件 set_input_as_handled() 吃掉（避免相机缩放同帧跟动）。
## 注意：扇形模式下**不能**在这里直接改半径 —— 半径是张角的因变量，否则两者会不一致。
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


## 参数 a：目标张角（度）。先夹到 [min(angle_min, angle_max), max(angle_min, angle_max)]
##   （用 min/max 是为了容忍数值表把上下限写反）。
## 副作用：角度真的变化（差 > 0.0001 度）时，写 _angle、按新张角重算 _radius、置 _dirty；
##   角度没变则**什么都不做**（例如已经顶到 80 度再滚，自检有用例验证"不再增加"）。
## 调用时机：_input 的滚轮分支；自检 verify_flame_advance.gd 直接调它做回归。
## 注意：这里是扇形半径的**唯一**入口 —— 改完必须让 _radius_from_angle() 同步，别只改 _angle。
## 扇形模式：滚轮改**张角**，半径随之由数值表插值算出来
func _set_angle(a: float) -> void:
	a = clampf(a, minf(angle_min, angle_max), maxf(angle_min, angle_max))
	if absf(a - _angle) > 0.0001:
		_angle = a
		_radius = _radius_from_angle()
		_dirty = true


## 圆盘模式：滚轮改**直径**。
## 参数 d：目标直径（米）。先 clamp 到 [diameter_min, diameter_max]，再折半写入 _radius。
## 副作用：半径真的变化（差 > 0.0001m）时才置 _dirty；圆盘的限流间隔是 0（= 每帧重建）。
## 调用时机：_input 的滚轮分支；自检也可直接调。
func _set_diameter(d: float) -> void:
	d = clampf(d, diameter_min, diameter_max)
	var r := d * 0.5
	if absf(r - _radius) > 0.0001:
		_radius = r
		_dirty = true


# ==================== 每帧更新（选点期间才运行） ====================
# ---------------------------------------------------------------- 每帧
## 每帧入口（只在 begin() ~ end() 之间运行）。是整个选点器的调度中枢：
##   ① 按模式更新选区：扇形 -> _update_sector()（圆心锁主角、中轴跟鼠标）；
##      圆盘 -> 先按模式切好 _disc/_sector_disc 可见性，再 _update_screen_pass()，最后 _update_center_from_mouse()；
##   ② _dirty 且已过该模式的重建限流间隔时 _rebuild_mesh()；扇形再顺带 _refresh_surface()。
## 参数 _delta：本帧时长 —— **故意不用**（限流按 Time.get_ticks_msec() 的真实时钟走，
##   这样"帧率高低"不会改变网格重建频率）。
## 副作用：网格、材质 uniform、两个网格节点的 visible、"相机下全屏面"的 uniform。
## 注意（顺序坑）：圆盘分支里**不能**在 _update_screen_pass() 之后又把 _sp_quad 隐藏 ——
##   那会让"圆环（火焰灼烧）永远不显示"（用户实测过）。要关就关 use_screen_pass，让里面自己隐藏。
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
## 参数：无（全部从 _player / _cam / 鼠标当前像素坐标读取）。
## 中轴算法：相机 -> 鼠标的投射射线与"主角所在水平面 y = 主角 y"求交，取交点相对主角的水平向量
##   作 atan2(z, x) —— 所以俯视/仰视都能得到"鼠标在地面上的方向"；射线几乎水平（|dir.y| 极小）
##   或交点在相机背后（t <= 0）时保持上一帧中轴；交点离主角 < 0.05m 时也保持（鼠标压在自己身上）。
## 副作用：每帧**无条件**写扇形材质（axis/half_angle/inner/fill_strength/edge_strength）、
##   物体表面材质（同族参数 + radius/sector_center/climb/edge_boost…）、全屏面 uniform，并切可见性；
##   仅当圆心或中轴真的变化（> 1cm / > 0.001rad）时才置 _dirty（重建网格不便宜）。
## 注意：① 参数必须每帧写、不能塞进"变化才写"的分支里 —— 滚轮改张角时圆心/中轴都没变，
##      塞进去就会"不动鼠标就不生效"（用户实测 + 自检回归用例锁定）；
##      ② _center 恒等于角色位置，所以扇形永远贴着脚下。
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


## 参数：无（鼠标像素坐标 + 相机 + 玩家引用）。
## 射线：从相机经鼠标打到 400m 外；掩码 = (0xFFFFFFFF & ~ray_ignore_layer_mask) | prop_visual_layer_mask
##   （排除导入模型的假碰撞盒层，纳入 Layer 16 的精修三角网格），并排除玩家自己的 RID。
## 命中后的语义判定（**不比高度、不做像素偏移采样**）：
##   · 命中体含地形层，或在组 "ground" / 名字含地面关键词 -> 地面：指哪画哪（XZ 取命中点）；
##   · 其它 -> 物体：只对**地形层**再打一条垂直射线（起点下移 0.3m 跳过物体自身顶面），
##     落到物体下方的地面；打不到就用地形视觉高度兜底。
## 未命中任何东西时：与"主角脚下水平面"求交，仍然给一个可用的圈。
## 距离钳制：与主角的**水平**距离夹到 [range_min, range_max]，方向不变（先算平面向量再整体缩放）。
## 副作用：写 _center（含 y = 该处地面高度）、_dirty = true；DEBUG_LOG_PREVIEW 为真时写 _dbg_* 诊断字段。
## 注意：圆心的 y 只影响"贴合网格的基准高度"与日志可读性 —— 屏幕空间覆盖里真正的形状判定是
##   着色器按世界 XZ + ground_y 做的。
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
		# ★ 方案 C：排除"看不见的碰撞盒"所在层（layer 4 = bit3），射线才落在真实物体/地形上
		q.collision_mask = (0xFFFFFFFF & ~ray_ignore_layer_mask) | prop_visual_layer_mask
		q.exclude = [_player.get_rid()] if _player is CollisionObject3D else []
		var hit := world.direct_space_state.intersect_ray(q)
		if not hit.is_empty():
			pos = hit["position"]
			ok = true
			# ★ 圆环中心**落到地面**：XZ 用鼠标命中点（指哪打哪），y 取该处地形高度。
			#   之前圆心直接取命中点高度 -> 鼠标打到围栏上时圆心飘到 3m 高空（实测），
			#   日志与调试都被误导。
			# ★ 不做任何"越过障碍"的猜测：**鼠标射线打到哪儿，圈就画在哪儿**。
			#   之前的"高度判定 + 周围射线投票"是错的思路 —— 透过围栏可能打到地面，
			#   也可能打到围栏后面的另一个物体；用高度根本分不清（用户指出）。
			#   所以这里只用命中点本身（XZ），y 再落到该处地面（仅为了日志与调试可读）。
			# ★★ 判定"鼠标点上是什么"——**语义判定**，不靠屏幕偏移、不靠高度：
			#   · 命中**地形层**（layer 2）            -> 地面
			#   · 命中体被**显式标记**为地面（组 ground / 名字含 ground、floor、路面、
			#     石板、道路、台阶）                  -> 地面（贴地道具这样标进来即可）
			#   · 其它                                  -> 物体 -> 垂直下落到其下方地面
			#   为什么不做"多打几根偏移射线投票"：屏幕像素偏移在世界里的大小随距离/俯角
			#   剧变（近处几像素=几厘米、远处=几米），不是可控的采样半径（用户指出）。
			# ★ 方案 C（用户定）：**射线直接排除 layer 4**（导入模型那些"看不见的
			#   碰撞盒"所在的层）——它们比可见网格大一圈，是"打到空气/误判"的根源。
			#   排除后射线直接落在真实障碍或地形上，判定简单可靠、也不再卡。
			#   判定规则：地形层 / ground 组 -> 地面（指哪画哪）；其它 -> 物体（垂直落地）。
			var tl_hit := _terrain_layer()
			var hit_col = hit.get("collider")
			var on_ground := true
			if hit_col is CollisionObject3D:
				on_ground = tl_hit != 0 \
						and (((hit_col as CollisionObject3D).collision_layer & tl_hit) != 0)
			if not on_ground and hit_col is Node:
				on_ground = _is_ground_like(hit_col as Node)
			_dbg_decision = "物体 -> 垂直落地" if not on_ground else "地面 -> 指哪画哪"
			var gh3 := _terrain_visual_height(pos.x, pos.z)
			if not on_ground:
				# 物体：垂直向下（起点从命中点稍微下移，跳过物体自身的顶面/侧面）
				var qd := PhysicsRayQueryParameters3D.create(
						Vector3(pos.x, pos.y - 0.3, pos.z), Vector3(pos.x, gh3 - 40.0, pos.z))
				# ★ 只打**地形层**：否则会先撞到下面的另一个物体（或看不见的碰撞盒），
				#   圆心就落到不知道什么东西上（用户指出：这样的结果不可靠）。
				qd.collision_mask = tl_hit if tl_hit != 0 else 0xFFFFFFFF
				qd.exclude = [_player.get_rid()] if _player is CollisionObject3D else []
				var hd := world.direct_space_state.intersect_ray(qd)
				if not hd.is_empty():
					pos = hd["position"]
				else:
					pos = Vector3(pos.x, gh3, pos.z)
			elif not is_nan(gh3):
				pos.y = gh3                        # 地面：XZ 不动，只把 y 归到地面
			if DEBUG_LOG_PREVIEW:
				# ★ 把"鼠标点上到底是什么"记全：节点名 / 类名 / 碰撞层 / 是否在 ground 组 / 路径
				var col = hit.get("collider")
				if col is Node:
					var cn := col as Node
					var clay := (cn as CollisionObject3D).collision_layer if cn is CollisionObject3D else 0
					_dbg_hit_name = "%s 「%s」layer=%d 组=%s ｜ %s" % [cn.name, cn.get_class(), clay,
							"ground" if cn.is_in_group(GROUND_GROUP) else "-",
							String(cn.get_path()).substr(0, 90)]
				else:
					_dbg_hit_name = "(无节点) " + str(col)
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
	# 只夹"水平向量的长度"、不改方向：先算 flat 再整体缩放，比逐分量夹更不容易把方向夹歪
	if d > range_max:
		flat = flat.normalized() * range_max
	elif d < range_min:
		flat = (flat.normalized() if d > 0.0001 else Vector3.FORWARD) * range_min
	_center = Vector3(p.x + flat.x, pos.y, p.z + flat.z)
	_dirty = true


# ==================== 贴合网格：构建 / 采样 / 限幅平滑 ====================
# ---------------------------------------------------------------- 网格
## 建圆盘节点（名字固定为 "AreaDisc"）+ 圆盘材质（AREA_SHADER）+ 初始贴图，然后接着建扇形节点。
## 参数：无。返回值：无。
## 副作用：new 出 MeshInstance3D 与 ShaderMaterial，add_child 到**本节点**（本节点被 caster 挂在 root 下）；
##   写 _disc / _mat；末尾调用 _build_sector()。
## 注意：① 只建结构、不建网格 —— mesh 由 _rebuild_mesh() 在第一次 _dirty 时生成；
##      ② 不投影阴影（cast_shadow = OFF）：地面指示圈不该在地上留影子；
##      ③ 着色器/贴图加载失败时不会崩：材质只是没有 shader/贴图（那时圈不可见，但逻辑照跑）。
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


## 建扇形节点（名字固定为 "AreaSector"）+ 扇形材质（SECTOR_SHADER），初始隐藏。
## 参数：无。返回值：无。副作用：add_child 到本节点、写 _sector_disc / _sector_mat。
## 注意：① 用独立节点 + 独立材质是**刻意的**（见文件头说明 3）：两种形状共用一份材质会互相污染，
##      症状是"切回圆盘时圆圈被扇形的角度裁掉"；
##      ② 着色器参数（axis/half_angle/inner/fill_strength/edge_strength）不在这里写，
##      而是由 _update_sector() 每帧写 —— 这样滚轮改张角能立刻生效；
##      ③ 本节点只在"射线贴合网格"路径下可见。
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


## 参数：无（读 _center / _radius / sector 等成员）。副作用：给 _disc / _sector_disc 换 mesh；
##   sector 模式下顺带调 _refresh_surface()。
## 顶层门禁：use_screen_pass = true（定稿路径）时**直接返回** —— 屏幕空间覆盖不需要贴合网格，
##   也就省掉了这几百根射线。
## 采样策略：无论哪种模式都只 _sample_heights(hi) 采**一次**（扇形 hi=12、圆盘 hi=6），
##   圆盘再用 stride 抽稀取自己的环 —— 所以扇形变密不会让圆盘多打射线。
## 调用时机：_process 里 _dirty 且过了限流间隔时；自检 shot_helper.gd / verify_flame_advance.gd 直接调它出图。
## 注意：物体表面叠加**必须挂在这里**（谁重建网格谁负责刷新表面）—— 曾只把它挂在 _process 的 _dirty
##   门后面，结果"门没开"时网格照建、物体却一直没挂上（用户实测："地面白了，石棺/墓碑还是没白"）。
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
	# 圆盘从这份密采样里"抽稀"取自己的环（SECTOR_RINGS 必须是 RINGS 的整数倍，见常量注释）
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


## 参数 raw：_sample_heights 的原始采样（rows[ring][s] = {hit, y, ny, terrain}）。
## 参数 y0：基准高度（圆心 y）—— 未命中或法线不够朝上时，这一格直接用 y0（= 不抬升，保持低位）。
## 参数 min_up：法线朝上程度阈值（圆盘 = ground_normal_min 0.6；扇形 = sector_normal_min 0.35）。
## 参数 stride：按步长取环（圆盘从扇形的密采样里取自己的偶数子集；必须能整除，见 SECTOR_RINGS 注释）。
## 参数 terrain_aware：为真时，命中体不含地形层（且拿不到地形高度）的格子按"贴地"处理，限幅 ±prop_cap。
## 参数 prop_cap：上面的限幅幅度（米，_rebuild_mesh 传 prop_cover_m）。
## 返回：Array[PackedFloat32Array(SEGMENTS)]，每个元素是一圈的高度（行数 ≈ raw.size() / stride）。
## 注意：纯函数（无副作用）。
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


## 参数 rows：高度图（每行 SEGMENTS 个高度，行数 = rings）；rings：网格环数；lift：整体抬高（默认 0.02m）。
## 返回：ArrayMesh。顶点已经是**世界坐标**（本节点不带变换，所以不用担心父子变换叠加）。
## 副作用：无（只 construct 一个网格资源，交给调用方赋给 MeshInstance3D）。
## 注意：① lift 的作用是避开与地面 z-fighting（0.02m 肉眼看不出来，但足以定胜负）；
##      ② UV 半径必须按**本网格自己的级数 rings** 算 —— 写成常量 RINGS 时扇形（12 级）最外圈 UV
##      半径会到 1.83，而着色器按 UV 裁形状 -> 扇面只剩内半截可见（实测踩过）。
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


## 参数 rows2：行数组，每行 {r: 归一化半径 0..1, h: PackedFloat32Array(SEGMENTS)}；
##   **同一个 r 连续出现两行**时，那两行之间连出来就是一段竖直面（裙边）。
## 参数 lift：整体抬高（_rebuild_mesh 传 0.05m，比主网格的 0.02m 略高，避免共面闪烁）。
## 返回：ArrayMesh（世界坐标顶点）。副作用：无。
## 说明：UV 同样按 r 归一化，所以裙边与主网格的贴图能接上（看上去是一整片）。
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


## 参数 rows：_extract_rows 出来的高度图（行数 = rings + 1，半径均匀分布）；rings：环数；
##   threshold：触发插裙边的落差阈值（米，riser_threshold_m，0 = 关闭）。
## 返回：新数组，元素为 {r, h}（可直接喂 _build_skirt_mesh）；行数 >= rows.size()。
## 判定：本圈与上一圈只要有**任意一个采样点**落差 > threshold，就把上一圈的高度复制到本圈半径处
##   （= 在该半径处插入一段竖直面），然后才追加本圈。
## 副作用：无（纯函数）。注意：是"整圈插"而不是"只插超阈值的那一段" —— 实现简单，
##   多出来的面与上一圈重合、看不出来；代价是顶点数最多翻倍（远小于射线采样的开销）。
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
				# 整圈只判一次：任一点超阈值就整圈插裙边（实现简单、多出的面与上一圈重合看不出来；
				# 代价是顶点数最多翻倍，仍远小于射线采样的开销）
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


## 参数 hit：物理射线结果字典（intersect_ray 的返回值）。返回：法线够朝上则为 true。
## 判定口径：normal.normalized().y >= ground_normal_min（默认 0.6 ≈ 53° 以内算"能站的地面"）。
## 副作用：无（纯函数，tools/verify_flame_scorch.gd 直接喂人造字典验证平地/缓坡/墙/垂面四种情形）。
## 注意：字典里**没有 "normal" 键时返回 true**（宽容处理：宁可当它是地面，也不要让整片判成无地面）。
##   主路径 _extract_rows 用的是等效的内联判断（float(e["ny"]) < min_up），两处口径必须保持一致。
## 命中面算不算"能站的地面"（纯函数，便于自检）
##   法线朝上程度 >= ground_normal_min 才算地面；竖直面（墙/栏杆/树干）一律不算。
func _is_ground(hit: Dictionary) -> bool:
	if not hit.has("normal"):
		return true
	return (hit["normal"] as Vector3).normalized().y >= ground_normal_min


## 参数：无。返回：地形碰撞层的位值（Layer 2 -> 2），找不到返回 0。
## 副作用：缓存到 terrain_layer_cache 与 _terrain_node（第一次调用会遍历整棵场景树，之后是纯读）。
## 查找口径：节点**类名或节点名**小写后含 "terrain" -> 在它的子树里取第一个 CollisionObject3D 的
##   collision_layer。**故意不写死层号**：这样改层/换地形实现也不会静默失效。
## 注意：① 缓存写入后不会自动失效（地形中途换层要重建本节点）；
##      ② get_tree() 或 current_scene 为 null（自检脚本没挂树）时返回 0，调用方必须容忍 0
##      （0 表示"地形层未知"：采样会退回全层、判定会更宽松）。
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
## 参数 x, z：世界水平坐标。返回：地形**视觉**高度（米）；两条路都走不通时返回 NAN。
## 副作用：缓存 _terrain_owner（找一次）；可能间接触发 _terrain_layer() 的场景树遍历。
## 优先级：① 项目自己的地形封装 terrain.gd 的 get_height_at（用 duck-typing：有这个方法就用它，
##   和 main.gd / camera_rig.gd 走同一套）；② Terrain3D 的 data.get_height(Vector3(x, 0, z))。
## 注意：**不要**用射线高度替代它 —— Terrain3D 的碰撞体与视觉地形有细微偏差，贴合网格会被视觉
##   地形一片片戳穿（用户实测："扇形中间部分区域没有被涂白"，边界呈撕裂状）。
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
## 返回：满足"类名/节点名含 terrain 且实现了 get_height_at"的节点；找不到返回 null。
## 副作用：无 —— 每次调用都会遍历整棵场景树，所以 _terrain_visual_height 会把结果缓存在 _terrain_owner。
## 注意：用 duck-typing（has_method("get_height_at")）而不是判断具体类名：项目地形脚本没有 class_name
##   也能命中，换实现（Terrain3D / 自绘地形）也不用改这里。
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


## 在 from_node 的子树里（含自身）用栈遍历，返回**第一个**遇到的 CollisionObject3D 的 collision_layer。
## 参数 from_node：起点（通常就是"名字含 terrain"的节点）。返回：层位值；子树里没有碰撞体则返回 0。
## 副作用：无（纯查询）。guard = 4000 是防呆上限：场景树异常庞大时不至于把一帧卡死。
## 注意：用的是"栈 + pop_back"，所以命中顺序取决于子节点顺序（后进先出）——
##   地形节点下的**第一个**碰撞体必须是地形本体本身（Terrain3D 的碰撞就在它自己下面）。
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


## 参数 rings：环数（圆盘 RINGS=6；扇形 SECTOR_RINGS=12）。环 0 = 圆心那一圈，**不打射线**（直接用 y0）。
## 返回：rows[ring][s] = {hit: bool, y: float, ny: float, terrain: bool}，长度 = rings + 1，
##   每个元素是长度 SEGMENTS 的 Array（注意不是 Packed 类型：里面是字典）。
## 成本：最多 rings * SEGMENTS 根射线（扇形 832 根，真实地形实测 ~13ms），所以上层必须限流重建。
## 副作用：无（只读物理空间，不改任何状态）。参数越界（rings <= 0）时会只采到圆心那一圈。
## 注意：① 复用同一个 PhysicsRayQueryParameters3D 对象、只改 from/to（一次重建上百根射线，
##      逐根 new 一个参数对象纯属浪费）；
##      ② 命中后**一律**取该 XZ 的地形视觉高度并置 terrain = true —— 网格只铺地形，物体顶面
##      交给"物体表面叠加"，两边不抢同一块表面（否则出现"一块白一块不白"）；
##      ③ q.exclude 掉施法者自己的 RID：扇形圆心就在角色脚下，不排除会把角色当"物体表面"爬上去；
##      ④ 默认打**全层**（路面/石板这些贴地物体也要贴上）；terrain_only_sampling = true 时只打地形层
##      （那是复现旧 bug 的诊断开关，保持 false）。
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


## 参数 rows：输入高度图（**不会被原地修改**，输出是新数组）；y0：基准高度（圆心 y）。
## 参数 lift / drop：相对 y0 的抬升、下沉上限（米）。默认 < 0 = 用圆盘的 smooth_lift / smooth_drop。
## 参数 step / passes：坡度限幅的每级最大落差（米）与迭代轮数。默认 < 0 = 用 slope_step / slope_passes。
## 参数 circle：是否做最后那轮"沿圆周的轻量三点平均"（圆盘 true；扇形 false）。
## 返回：新的高度图（Array[PackedFloat32Array]，与输入同形、长度都不变）。
## 副作用：无（纯函数）—— tools/verify_flame_scorch.gd 直接喂人造尖刺/斜坡验证它的三条性质。
## 复杂度：O(passes × rings × SEGMENTS)，纯 CPU 计算、无物理查询。
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


# ==================== 扇形：物体表面叠加（备用路径②，默认不生效） ====================
# ---------------------------------------------------------------- 扇形：物体表面叠加
## 把扇面画到**物体自己的表面**上（material_overlay + 世界坐标算形状）——
## 这是【物体探测】探测波的做法：任何朝向的表面都能贴住，不受"顶点高度场"限制。
## 只给**有碰撞体的物体**挂（石头/箱子/房子/树），并在离开范围、切回圆盘、
## 选点结束时**逐个还原**原来的 material_overlay（绝不能留在物体上）。
## 返回：物体表面叠加用的 ShaderMaterial（已写入基础 uniform）。**懒创建**：首次调用 new 一份并缓存。
## 副作用：写 _surface_mat；着色器缺失/加载失败时 push_warning（返回的还是那个**没有 shader** 的材质，
##   调用方必须自行判空：见 _refresh_surface 里的 `_surface_mat.shader == null` 检查）。
## 注意：① 同一份材质被所有被叠加的网格共用 —— 形状是片元里按世界坐标算的，所以共用才正确，
##      也省掉逐物体建材质（代价是所有物体只能有同一套参数）；
##      ② DEBUG_MOUNT_SCAN_SHADER = true 时故意换成探测波的 detect_scan.gdshader（A/B 诊断，默认关）。
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


## 把"当前扇区"写进物体表面材质的 uniform。
## 参数：无。返回值：无。副作用：只写 uniform（_surface_mat 为 null 时直接返回）。
## 调用时机：_refresh_surface 里"确实要刷新"时调一次（限流之后），不是每帧。
## 注意：因为形状（axis/half_angle/radius/sector_center/inner_m）是**uniform**，改张角/半径立刻生效，
##   不需要重建任何网格；_update_sector 里每帧写的那一组是"实时跟手"，这里是"挂载时保证正确"。
##   DEBUG_MOUNT_SCAN_SHADER = true 时改走探测波的参数名（scan_color/band_width/wave_*），属诊断分支。
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
## 参数：无。副作用：给范围内的网格挂/摘 material_overlay（经 SurfaceOverlay.sync 自动还原不在集合里的）、
##   刷新 _overlaid 镜像字典。
## 门禁（任一不满足就返回）：surface_scan 为 false / 不是扇形 / use_decal 或 use_screen_pass 为真。
##   —— 定稿路径是屏幕空间覆盖，所以**默认配置下这个函数什么都不做**，它是备用路径。
## 限流：距上次刷新不足 surface_refresh_interval（默认 0.05s）则跳过 —— 因为 _rebuild_mesh 可能每帧被调。
## 注意：挂载不能只依赖 _process 的 _dirty 门（见 _rebuild_mesh 的注释：会出现"地面白了、物体没白"）。
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


## 返回：MeshInstance3D 数组 —— 这一轮"应该挂叠加材质"的网格（可能重复，由 SurfaceOverlay.sync 去重）。
## 流程：SurfaceOverlay.collect_meshes 做球查询（球心 = _center，半径 = max(0.1, _radius)，
##   mask = surface_mask，最多 64 个结果，碰撞体向上找 6 层可视节点，并按传入的 keep 过滤）
##   -> 再按**每个网格自己的世界包围盒**与扇区求交，只保留真正被扇面切到的那些。
## 副作用：无（只查询；材质挂载在 _refresh_surface 里做）。
## 注意：① 地形层不算"物体"（地面由贴合网格画，再叠一层会重复变亮）；
##      ② 不按高度跳过任何物体 —— 网格只管地形、物体一律由叠加/屏幕空间画，两者不抢同一块表面；
##      ③ visual_up 传 6：导入模型的碰撞体与网格常常隔得很远，默认 3 层会找不到；
##      ④ 按网格（而不是按碰撞体那一组）过滤很关键：一整片只挂一个碰撞体时组包围盒可到 17m，
##      按组放行会把几十个网格全挂上（既费 draw pass，又出现"一块白一块不白"）。
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
	# 参数含义：64 = 球查询返回上限；6 = 碰撞体沿父链向上找可视节点的层数（导入模型常常隔得远）
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


## 参数 box：世界空间 AABB（物体/网格的包围盒）。返回：true = 认为它与扇形有交集。
## 快速路径：角色（= 扇形顶点）的 XZ 落在盒子的 XZ 范围内 -> 直接算相交（最快，也是巨盒最常见的情形）。
## 慢路径：XZ 密采样（间距 <= 1m，最多 12×12 档）× 上/中/下三档高度，任一采样点落在扇区内即相交。
## 副作用：无（纯判定）。
## 注意：这是**刻意偏宽松**的保守判定（宁可多挂几个网格）—— 漏挂会造成"一块白一块不白"，
##   而多挂的网格在着色器里按世界坐标裁切，画不到东西；所以宽松的代价只是多几次材质挂载。
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


## 参数 w：世界坐标点（只用 XZ）。返回：该点是否落在扇形内。
## 判定三步：① 与圆心 _center 的水平距离 <= _radius；② 距离 < 0.0001（与圆心重合）时直接算在内；
##   ③ 方向角与中轴 _axis 的**最小夹角**（wrapf 到 ±PI）<= half_angle()。
## 副作用：无（纯函数）。注意：圆心是**扇形顶点**（角色脚下），不是圆盘那种"鼠标处圆心"；
##   高度完全不参与判定（高度过滤在着色器里用 ground_y 做）。
func _in_sector_xz(w: Vector3) -> bool:
	var d := Vector2(w.x - _center.x, w.z - _center.z)
	# 先判半径（最便宜），再判角度（要 atan2 + wrapf）；与圆心重合时方向无意义，下面单独放行
	if d.length() > _radius:
		return false
	if d.length() < 0.0001:
		return true
	return absf(wrapf(atan2(d.y, d.x) - _axis, -PI, PI)) <= half_angle()


## 找到物体真正持有网格的那个可视节点（容器的原点常常在 (0,0,0)、几何体是偏移的）
## 参数 node：碰撞体节点（或任意节点）。返回：真正持有可见网格的那个节点；一直找不到就返回传入的 node。
## 逻辑：自身是 MeshInstance3D，或自身子树里有可见网格 -> 用它；否则沿父链**向上**找（最多 6 层）。
## 为什么要向上找：本工程的碰撞体与网格经常是**兄弟**关系（都在同一个容器下），
##   只查"碰撞体自己的子节点"会把每个物体都判成没有网格（探测波实测踩过）。
## 副作用：无（纯查询）。注意：本文件内**没有调用点**，它是与 surface_overlay.gd / detect_pulse.gd
##   同名工具同口径的保留接口，主要供自检/出图脚本 call() 使用（默认 6 层比公共模块的 3 层更宽松）。
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


## 参数 visual：可视节点（一般来自 _resolve_visual）。返回：它子树里所有可见网格的**世界空间**包围盒并集。
## 副作用：无（纯查询）。没有网格或网格没有 mesh 资源时返回一个 size 全 0 的 AABB（调用方注意判断）。
## 注意：本文件内**没有调用点**（surface_overlay.gd 有等价的静态工具 visual_aabb），保留同上供自检调用。
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


## 参数 node：任意节点（含自身）。返回：该节点子树里 **visible == true** 的 MeshInstance3D 数组。
## 副作用：无（纯查询）。注意：隐藏的网格会被排除 —— 所以"物体被隐藏时"它不会出现在叠加集合里；
##   这只是转发到 SurfaceOverlay.visible_meshes（与【物体探测】共用同一份实现，改口径要两边一起改）。
## 节点下所有可见网格（转发到公共模块）
func _visible_meshes(node: Node) -> Array:
	return SurfaceOverlay.visible_meshes(node)


## 参数 id：网格的 get_instance_id()。副作用：把该网格的 material_overlay / 透明度 / 可见层还原成挂载前的值。
## 注意：本文件内**没有调用点**（批量还原走 _restore_surface -> _surface.clear()），
##   保留它是为了兼容"只摘一个物体"的调试/自检脚本。
## 还原一个网格（转发到公共模块：overlay / 透明度 / 可见层一起还原）
func _restore_one(id: int) -> void:
	_surface.detach(id)


## 副作用：逐个还原被叠加的网格，并把 _overlaid 重新指向（已清空的）_surface.entries。
## 调用时机（**三处缺一不可**）：切回圆盘模式时（_process 的圆盘分支）、end() 结束选点时、_exit_tree() 退出时。
## 注意：幂等且廉价（没有叠加时 entries 为空，循环不执行）—— 宁可多调，也不能漏调：
##   漏调的后果是"物体材质被永久改成扇形效果"，只能靠重载场景恢复。
## 还原**所有**被叠加的物体（切回圆盘 / 选点结束 / 节点退出时都必须调）
func _restore_surface() -> void:
	_surface.clear()
	_overlaid = _surface.entries


## Godot 回调：本节点离开场景树时调用（场景切换、caster 被释放等）。
## 必须在这里把"由本节点创建、却挂在别人身上"的东西全部收干净：
##   · 物体表面的叠加材质（_restore_surface）—— 不收会留下外观被改掉的物体；
##   · 相机下的全屏面：先 _hide_screen_pass()，再 queue_free() 并置空 _sp_quad ——
##     它是本节点创建并 add_child 到**相机**下的，不是本节点的子节点，不回收就会留在相机上；
##   · 贴花（_hide_decal）。
## 注意：用 queue_free() 而不是 free()（避免在本帧内销毁仍在渲染队列里的节点）；
##   释放后必须把 _sp_quad 置 null，否则 is_instance_valid 之外的引用会变成悬空。
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
## 贴花的自发光能量（写进 Decal.emission_energy，配合 texture_emission）：调大更亮更"发光"，
## 0 = 只靠 albedo 混色（会明显变暗）。默认 0.6。
@export var decal_emission := 0.6
## 贴花盒的高度与中心抬升（盒要罩住地面与物体，向下投影）
@export var decal_height_m := 3.0
@export var decal_lift_m := 1.2
## 贴花节点（懒创建、挂在**本节点**下）。走屏幕空间覆盖时一直为 null，不会浪费节点。
var _decal: Decal = null
## 运行时生成的扇形贴图（白色 + alpha 编码形状）；半角/内圈变化时重画。
var _decal_tex: ImageTexture = null
## 上次生成贴图时的半角（弧度）。-1.0 = 还没生成过，所以第一次必定生成。
var _decal_half := -1.0
## 上次生成贴图时的内圈归一化半径。-1.0 = 还没生成过。
var _decal_inner := -1.0


## 懒创建贴花节点（名字固定为 "SectorDecal"，挂在**本节点**下；盒体沿本地 -Y 向下投影）。
## 参数：无。副作用：Decal.new() + add_child(到本节点) + 写 _decal；已存在且有效时立即返回。
## 初始化值：cull_mask 全层、albedo_mix 0.7、upper_fade 0.55 / lower_fade 0.25（让草尖与物体顶部自然
##   过渡、减少"白雾"）、distance_fade 关、emission_energy 由 decal_emission 给、初始 visible = false。
## 注意：贴图（texture_albedo / texture_emission）不在这里生成，而是 _update_decal 在**半角/内圈变化**时
##   才重画；在没有贴图时**绝不能**把它设成 visible —— 否则 Decal 会退化成"用 modulate 铺满整个盒体"，
##   表现就是一整块方块白（实测踩过）。
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
## 参数 half：扇形半角（弧度）；inner：内圈留白（**归一化**半径 0..1，= sector_inner_m / radius）。
## 返回：ImageTexture（白色 + alpha 编码形状）；图片创建失败时返回 null（调用方必须判空）。
## 副作用：无（纯生成，384×384 CPU 逐像素，只在滚轮改张角时触发）。像素算法：
##   u/v 映射到 [-1,1] 的圆盘坐标 -> rr = sqrt(u²+v²) 为归一化半径；rr <= 1 且在扇形内（|atan2(v,u)| <= half、
##   rr >= inner）才给 alpha：填充 = decal_fill_alpha；两条直边 = ang 附近的高斯亮线（exp(-((ang-half)/0.018)²)）；
##   外弧 = (1 - smoothstep(0.86, 1.0, rr)) 的亮带；三者取 max 合成。
## 注意：纹理坐标约定（务必与 _update_decal 的 rotation 对上）：+U 对齐本地 +X（= 扇形中轴），
##   +V 对齐本地 +Z，半径按 r <= 1 归一化。n = 384 是"清晰度 / 生成耗时"的折中。
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
			# u/v 映到 [-1,1]：rr 就是归一化半径（1.0 = 贴图里弧的半径 = 世界里的 _radius）
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


## 每帧更新贴花（只有 use_decal = true 且 sector = true 时才真正工作，否则隐藏并返回）。
## 参数：无。副作用：必要时重画贴图 + 写 texture_albedo/texture_emission，写 emission_energy/size/position/
##   rotation.y，最后 visible = true。
## 重画条件：半角或内圈与上次相差 > 0.001 才重画（滚轮改张角时）；其余帧只写 position/rotation/size ——
##   所以"每帧跟随主角移动"很便宜，重画才是贵的（384×384 逐像素）。
## 注意：① size = (2*半径, decal_height_m, 2*半径)、中心 = _center + UP*decal_lift_m，盒体要罩住地面与物体；
##      ② rotation.y = -_axis：贴图 +U 对齐本地 +X，而角度按 atan2(z, x) 计（符号相反）；
##      ③ 这条路径的固有取舍：盒高则把草也刷白、盒矮则盖不到高物体 —— 用户最终没选它。
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
## 边线 / 外弧的亮度倍率（加色混合，无量纲）：2.2 是"看得清但不刺眼"的定稿值。
@export var screen_edge_strength := 2.2
## 相机下的全屏面节点。**注意它挂在相机下**（不是本节点的子节点）：所以 visible = false 关不掉，
## 必须 _hide_screen_pass()；_exit_tree 里还要 queue_free() 才不会留在相机上。
var _sp_quad: MeshInstance3D = null
## 全屏面材质（spell_sector_screen.gdshader）。render_priority = 127，排透明队列最后。
var _sp_mat: ShaderMaterial = null


## 懒创建"屏幕空间覆盖"用的全屏面（材质 + 4×4 QuadMesh，挂到**当前相机**下、位于相机前方 z = -1）。
## 返回：true = 全屏面可用（已存在或刚建好）；false = 没有相机 / 着色器缺失（会 push_warning），调用方放弃本帧。
## 副作用：ShaderMaterial.new()、cam.add_child(_sp_quad)、写 _sp_mat / _sp_quad；初始 visible = false。
## 注意：① 挂在**相机**下（不是本节点下）—— 所以关选点器时 visible = false 关不掉它，必须显式 _hide_screen_pass()；
##      ② render_priority = 127：排到透明队列最后，否则草/粒子会后画、盖在白色之上（"白色区域里还夹着没变白的草"）；
##      ③ extra_cull_margin = 16384：全屏面挂在相机下，一旦被视锥剔除就整块不画，给足余量最稳；
##      ④ 相机前 1m、尺寸 4×4 足够覆盖视野（与【物体探测】同一套做法）。
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
	# 防视锥剔除：全屏面挂在相机下，一旦被剔除就整块不画；16384 是"绝不会被剔"的余量
	_sp_quad.extra_cull_margin = 16384.0
	_sp_quad.position = Vector3(0.0, 0.0, -1.0)
	cam.add_child(_sp_quad)
	_sp_quad.visible = false
	return true


## 隐藏屏幕空间全屏面（技能放出 / 切回圆盘 / 节点退出时都必须调）
func _hide_screen_pass() -> void:
	if _sp_quad != null and is_instance_valid(_sp_quad):
		_sp_quad.visible = false


## 隐藏贴花。参数：无。副作用：把 _decal.visible 置 false（节点无效/为空时什么都不做）。
## 注意：贴花是**本节点**的子节点，父节点 visible = false 时它本来就会一起隐藏 —— 这里显式再关一次，
##   是防止"只隐藏贴花不隐藏整节点"的调用场景（以及 _exit_tree 之前的兜底）。
func _hide_decal() -> void:
	if _decal != null and is_instance_valid(_decal):
		_decal.visible = false


## ★ 屏幕空间探测的重算频率：**每 2 帧一次**（= 当前帧率的一半 ✓，用户要求）
##   · `_dirty` 为真（刚打开选点/换模式/切法术/半径变化…）时**永远立刻重算** ✓ → 不会迟滞 ✓
##   · 其余帧只在"偶数帧"重算 ✓；被跳过的帧沿用上一帧的 uniform ✓
##     （全屏面本身保持可见 ✓ → 观感上仍是连续高亮，只是参数每 2 帧跟新一次 ✓）
const SP_UPDATE_EVERY := 2
## 节流用的帧计数器：只有 _dirty 或 `_sp_frame % SP_UPDATE_EVERY == 0` 时才重算（见 _update_screen_pass）。
var _sp_frame := 0


## 更新屏幕空间覆盖：写全屏面材质的 uniform，并把它设为 visible（定稿方案的核心函数）。
## 参数：无。副作用：写 shape_mode / sector_center / axis / half_angle / radius / inner_m / ground_y /
##   floor_margin / fill_strength / edge_strength，并 _sp_quad.visible = true；use_screen_pass = false 时
##   隐藏全屏面并返回。
## 节流：_dirty 为真时**无条件立刻重算**（刚打开选点/换模式/换法术/半径变化），其余每 SP_UPDATE_EVERY(=2) 帧
##   算一次（被跳过的帧沿用上一帧的 uniform，全屏面本身保持可见 -> 观感上仍是连续高亮）。
## 注意：ground_y 取 min(角色脚下 y, 圆心 y) —— 只锚脚下时，范围落在陡下坡（低于脚下 1.5m 以上）会把
##   地面切掉；锚圆心则会被鼠标抬到围栏顶（实测 3.02m）-> 整片地面掉出范围、只剩高物体变白。
func _update_screen_pass() -> void:
	_sp_frame += 1
	if not _dirty and (_sp_frame % SP_UPDATE_EVERY) != 0:
		return
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
	# shape_mode：0 = 扇形（两条边 + 外弧 + 内圈留白）；1 = 圆环（只有外弧）—— 火焰灼烧要的就是"一圈"
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


# ==================== 地面语义判定（层 / 组 / 名字，圆盘圆心落点用） ====================
## ★ "看着/标着是地面"的判定：地形层之外，还承认**显式标记**过的贴地道具。
##   标记方式任选其一（比任何高度/像素启发式都可靠，且由场景作者决定）：
##     · 把碰撞体或其父节点加入组 "ground"
##     · 名字里含下列关键词之一
const GROUND_GROUP := "ground"
const GROUND_NAME_HINTS := ["ground", "floor", "road", "path", "路面", "石板", "道路", "台阶", "地板"]


## 参数 n：鼠标射线命中的碰撞体节点。返回：true = 把它当成"地面"（圆心指哪画哪，不做垂直下落）。
## 判定（沿父链向上最多 4 层）：① 该节点在组 GROUND_GROUP("ground") 里；② 名字（小写）含
##   GROUND_NAME_HINTS 里的任一关键词（ground/floor/road/path/路面/石板/道路/台阶/地板）。
## 副作用：无（纯查询）。
## 为什么要靠**显式标记**：用"命中点比地形高多少"区分地面/物体，基准取错就整片判错（圆心被鼠标抬到
##   围栏顶 3.02m 的实测案例），而且分不清"障碍"和"透过缝隙看到的另一个物体"（见技术文档 §7.6）。
## 注意：① 名字是**子串**匹配，给物件起名时避开这些词；② 只认 4 层，更深的父节点上打标记无效。
func _is_ground_like(n: Node) -> bool:
	var cur: Node = n
	var depth := 0
	while cur != null and depth < 4:
		if cur.is_in_group(GROUND_GROUP):
			return true
		var nm := String(cur.name).to_lower()
		for h in GROUND_NAME_HINTS:
			if nm.contains(h):
				return true
		cur = cur.get_parent()
		depth += 1
	return false


# ==================== 诊断日志（施放 / 结束选点时各打一次） ====================
## 参数 tag：日志前缀标签（默认 "施放"；end() 里传的是 "施放/结束"）。
## 副作用：往标准输出打 3 行（模式 / 鼠标像素坐标 / 地形层 / 判定分支 / 命中体详情 / 圆心 / 半径 /
##   角色位置 / 圆心比角色高多少 / 张角），**不改任何状态**。
## 数据来源：_update_center_from_mouse 记下的 _dbg_* 字段 —— 所以**扇形模式**下这些字段不会被刷新，
##   日志里的"命中/判定"会是上一次圆盘判定的残留（圆心/半径/张角仍是当帧的真实值）。
## 调用时机：只在 begin 之后的施放/结束各一次（DEBUG_LOG_PREVIEW 控制），用户明确要求不要每帧刷屏。
## 排查用法：`圆心高于角色` 若 > 1m，通常说明"圆心被鼠标抬到物体顶上了"。
## ★ 打一次"鼠标点上是什么 + 圈落在哪"的快照。
##   只在**技能施放/结束选点**时调用（用户要求：不要每帧刷屏）。
func log_preview_snapshot(tag := "施放") -> void:
	if _player == null or not is_instance_valid(_player):
		return
	var pp := _player.global_position
	var vp := get_viewport()
	var mp := vp.get_mouse_position() if vp != null else Vector2.ZERO
	print("[选点·%s] %s 鼠标=(%.0f,%.0f)px 地形层=%d 判定=%s"
			% [tag, "圆盘" if not sector else "扇形", mp.x, mp.y, _terrain_layer(), _dbg_decision])
	print("        命中=%s @(%.2f,%.2f,%.2f)"
			% [_dbg_hit_name, _dbg_hit_pos.x, _dbg_hit_pos.y, _dbg_hit_pos.z])
	print("        圆心=(%.2f,%.2f,%.2f) 半径=%.2f 角色=(%.2f,%.2f,%.2f) 圆心高于角色=%.2fm 张角=%.0f°"
			% [_center.x, _center.y, _center.z, _radius,
			pp.x, pp.y, pp.z, _center.y - pp.y, rad_to_deg(half_angle()) * 2.0])

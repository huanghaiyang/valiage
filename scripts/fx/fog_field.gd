@tool
class_name FogField
extends Node3D
## ============================================================================
## fog_field.gd —— 雾气场：把"NS 求解器 + 体积雾 + 雾粒子 + 画笔底图"装配成一个节点
## ============================================================================
## 【职责】运行时的**唯一入口**。把它拖进场景就能得到一层会流动的雾：
##     · 子节点 FogNsSolver（脚本自建，不可见）：每帧在 GPU 上解 NS 方程
##     · 子节点 MistVolume（自建）：光线步进的体积雾，采样求解器的浓度场
##     · 子节点 MistParticles（自建）：被速度场推着走的雾粒子
##     · 画笔底图（FogBrushField 资源，由 addons/fog_brush 插件在编辑器里刷）
##       → 作为"吸引子"喂进浓度方程，所以**刷出来的雾也会被风吹着走**
##
## 【@tool / 编辑器预览】这个脚本必须是 @tool，否则编辑器里它只是**占位实例**
##   （placeholder instance）：脚本成员全部不可访问，雾气笔刷插件会报
##   "Invalid access to property 'solver'"、"Attempt to call a method on a placeholder
##   instance"。@tool 之后编辑器里的行为被刻意**分成两条路径**：
##     · 编辑器：只建体积雾网格，把**画笔底图直接接到材质上**当静态预览
##       —— 刷完立刻能看见雾的形状，但**不建求解器、不建粒子、不跑流体**
##       （在编辑器里跑 13 个 SubViewport 的 GPU 链既费电，也容易和编辑器视口打架）；
##     · 运行期：完整装配（求解器 + 体积雾 + 粒子 + 天气接线）。
##   两条路径共用同一套参数与同一支体积雾着色器，所以"编辑器里看到的形状"
##   与"运行起来的样子"是一致的（运行时会再加上流动与粒子）。
##
## 【对外接口】
##   · add_source(world_position, radius_m, density_rate, velocity_world)
##        在世界某处加一个雾源（篝火/角色/法术）。velocity_world 单位 m/s。
##   · add_brush_velocity(uv, radius_uv, target_velocity)   笔刷吹风（编辑器安全）
##   · set_wind_mps(velocity_mps)        直接指定风（m/s，世界 XZ）
##   · set_fog_opacity(value)            直接指定整体不透明度（0..2）
##   · apply_quality(tier)               按画质档位调分辨率/迭代/粒子数
##   · set_brush_field(field) / refresh_brush_texture()      画笔底图（编辑器/运行期都可用）
##   · density_texture() / velocity_texture()   底层纹理（自检/特效复用）
##   · solver / brush_field              子对象访问（高级用法）
##   · enabled                           开关（关掉时求解器完全停止渲染）
##
## 【与天气/画质的接线】
##   · auto_weather = true 时每帧读 /root/Weather 的 wind_dir / wind / fog 三个量：
##       风 -> 求解器的目标速度（按域尺寸换算成"域单位/秒"）
##       雾 -> 体积雾的 opacity（并叠加 idle_opacity 保证晴天也有薄薄一层地雾）
##     未装 Weather（无头测试/独立场景）时**自动跳过**，不报错。
##   · quality_follows_project = true 时在 _ready 读一次 /root/Quality 的 tier。
##     注意：只在启动时读一次 + 提供 apply_quality()；画质管理器换档后需要外部调用
##     （没有连信号，避免和 settings.gd 争夺同一批字段的老问题）。
##
## 【已知的坑】
##   1. 体积雾网格的 AABB 必须比域大一圈：盒子每帧跟着节点走，包围盒太紧会在
##      某些视角被整块剔除（表现为雾忽然整片消失）。
##   2. 粒子的 visibility_aabb 同理，必须显式给大值：粒子在负半轴也会出现。
##   3. `base_height` 是**相对本节点**的高度偏移；本节点的 global_position 就是域中心。
##   4. 无 GPU（无头模式）时 SubViewport 不会真的渲染，浓度场恒为 0：
##      雾气效果在那里"不生效但不报错"，数值正确性请用 CPU 参考实现测。
##   5. 所有公开方法都要能在"编辑器（solver == null）"下安全调用 —— 插件会在编辑器里
##      调它们。写新的公开方法时先问一句："编辑器里 solver 是 null 会不会炸？"
##   6. `_process` 在编辑器里**仍然会跑**（@tool 节点），所以它第一件事就是分流；
##      编辑器分支只同步体积雾材质参数（让预览盒子跟着节点走）。
## ============================================================================

const SOLVER_SCRIPT := preload("res://scripts/fx/fog_ns_solver.gd")
const BRUSH_FIELD_SCRIPT := preload("res://scripts/fx/fog_brush_field.gd")
const VOLUME_SHADER := "res://assets/shaders/fog_mist_volume.gdshader"
## 角色周身涡流的**可视化**着色器（独立一层：螺旋条纹的明暗变化，不依赖浓度场）
const VORTEX_SWIRL_SHADER := "res://assets/shaders/fog_vortex_swirl.gdshader"
const PARTICLE_PROCESS_SHADER := "res://assets/shaders/fog_mist_particle_process.gdshader"
const PARTICLE_DRAW_SHADER := "res://assets/shaders/fog_smoke_particle_draw.gdshader"
## 旧的"径向圆盘"粒子绘制（留作回退；默认用新的烟雾绘制）
const PARTICLE_DRAW_SHADER_LEGACY := "res://assets/shaders/fog_mist_particle_draw.gdshader"

# ==================== 域与网格 ====================
## 域的水平尺寸（米）：x -> 世界 X，y -> 世界 Z
@export var domain_size := Vector2(80.0, 80.0)
## 雾层的**整体高度/厚度**（米）：粒子出生与上升都被限制在这个带内，超出就从底部回收。
@export var box_height: float = 14.0:
	set(value):
		box_height = maxf(value, 0.5)
		_apply_height_band()
## 雾层**距地面/距本节点**的高度（米）：整个雾带整体抬升，厚度不变。
## ★ 本节点通常就放在地面上，所以这个值就是"雾离地多高"。
@export var base_height: float = 0.0:
	set(value):
		base_height = value
		_apply_height_band()
## 模拟网格边长（96 = 画质/开销的好折中）
@export var resolution: int = 96
## 每帧压力迭代趟数
@export var jacobi_passes: int = 8

# ==================== 外观 ====================
@export_range(0.0, 4.0, 0.01) var fog_opacity: float = 1.1
@export_range(0.0, 8.0, 0.01) var density_gain: float = 2.4
## ★ **底图地板**强度（0..1）：1 = 旧行为（合成时 `浓度 = max(模拟, 底图×增益)`）。
## 0 = 底图只当"吸引子"（靠 base_relax 把形状拽住），不再当不可跌破的地板。
## 【什么时候要调它】角色/法术的挖雾与涡流**完全看不出效果**时：
##   底图被刷满（浓度 1）⇒ `max` 把可见浓度锁死在 1，模拟怎么搅渲染都读到 1
##   （实测：底图 1.0 + 角色 carve −1.4，角色脚下浓度仍是 1.000）。
##   调 0 之后挖雾/涡流才会真正落到可见浓度上；代价是"笔迹"不再即时可见，
##   而是按 `base_relax`（默认 0.6/秒）在 1~2 秒内长出来。
@export_range(0.0, 1.0, 0.01) var composite_base_floor: float = 1.0
@export_range(0.2, 6.0, 0.01) var height_power: float = 1.6
@export_range(0.0, 0.5, 0.01) var edge_fade: float = 0.14
@export_range(0.0, 1.0, 0.01) var wisp_amount: float = 0.35
@export var mist_color_lit := Color(0.86, 0.89, 0.94)
@export var mist_color_shadow := Color(0.62, 0.68, 0.78)
@export_range(1, 16, 1) var march_steps: int = 6

# ==================== 粒子（烟雾的主体） ====================
## ★ 是否创建**包围盒体积雾**（光线步进的 MeshInstance3D）—— 这是**雾气本体**。
## ★ 默认 **true**：雾气由**体积雾（光线步进的盒子）**渲染 —— 这是本项目的目标效果。
##   粒子只是附加层（默认关），它当年被设为默认是我擅作主张，已纠正。
@export var volumetric_box: bool = true
## ★ 光线步进的**抖动强度**（0 = 旧行为；>0 = 开启"蓝噪声抖动"）。
##   原理：步进是黎曼和，误差沿步长边界周期性排列 ⇒ 条纹/折痕。按像素 + 逐帧偏移采样相位，
##   把相干误差变成帧间不相关的细噪声（业界做法的前半；后半"逐帧重投影"需要历史缓冲，
##   在 Godot 里因 SubViewport 拿不到主视口深度而无法自建）。
##   掩膜由 FogBlueNoise 生成；生成失败时本项自动保持 0，**绝不会改变原有观感**。
@export_range(0.0, 1.0, 0.01) var march_jitter_strength: float = 0.0
## ★ B 深度软融合（soft particles）：雾在距物体表面这么多米内逐渐淡出，治"雾切在物体上的硬边"。
##   **0 = 关闭（旧行为）**。零噪声；建议 0.15~0.5 米。
@export_range(0.0, 2.0, 0.01) var edge_soft_m: float = 0.0
## ★ D 按步长预滤波：用"足迹 ≈ 单步步长"的旋转 2×2 平均去采浓度，滤掉高于采样率的成分
##   （折痕的根因）。**0 = 关闭（旧行为）**，1 = 完全按足迹滤波。确定性、零噪声。
@export_range(0.0, 1.0, 0.01) var march_prefilter: float = 0.0
## ★ C 视角相关羽化：域边缘淡出按 1/cos(视线与竖直夹角) 加宽，治掠射角下雾域边界的硬边。
##   **0 = 关闭（旧行为）**；俯视时几乎不改变观感。零噪声。
@export_range(0.0, 1.0, 0.01) var view_feather: float = 0.0
## ★ 墨迹式图案（inkblot）强度：0 = 关闭（旧行为）。>0 时雾内部由**随机撒落的墨滴**构成，
##   每颗墨滴各自对折（罗夏墨迹的成因）⇒ 不重复、无阈值硬边、无平铺接缝。
@export_range(0.0, 1.0, 0.01) var ink_amount: float = 0.0
## 墨滴间距（米）：越小越密
@export_range(1.0, 40.0, 0.5) var ink_spacing: float = 7.0
## 墨滴覆盖率（半径 = 间距 × 本值）
@export_range(0.05, 0.8, 0.01) var ink_grow: float = 0.35
## 分布演化速度：0 = 完全静止；越大墨滴游走得越快（"动态随机分布"）
@export_range(0.0, 2.0, 0.01) var ink_rate: float = 0.25
## 折纸镜像：1 = 每颗墨滴以**自己的轴**镜像（罗夏式），0 = 不对称
@export_range(0.0, 1.0, 0.01) var ink_fold: float = 1.0
## ★ 金字塔式边缘（治"分层感"）：0 = 关闭（旧行为）。
##   >0 时**顶层透明度最高、水平边缘羽化最宽**，逐级向下变实、变窄 ⇒ 轮廓成楔形，
##   不再是"一层平板"（分层感的根源就是板状轮廓）。
@export_range(0.0, 1.0, 0.01) var pyramid_edge: float = 0.0
## 粒子层是否启用。★ 默认 **false**：粒子是可选附加，不是雾本身；
##   想要"看得见的一团团雾"再打开它，或把 particle_count 调起来。
@export var particles_enabled: bool = false
@export_range(0, 8000, 10) var particle_count: int = 900
@export var particle_size: float = 13.0
@export_range(0.0, 2.0, 0.01) var particle_strength: float = 0.55
@export var particle_color := Color(0.62, 0.63, 0.68)
## 粒子寿命（秒）：烟团越大越该长一些，否则会看到"一茬一茬"刷新
@export_range(1.0, 40.0, 0.5) var particle_lifetime: float = 11.0

# ==================== 物理参数（透传给求解器） ====================
@export_range(0.0, 3.0, 0.01) var velocity_dissipation: float = 0.35
@export_range(0.0, 2.0, 0.01) var density_dissipation: float = 0.10
@export_range(0.0, 20.0, 0.1) var vorticity_strength: float = 2.5
@export_range(0.0, 4.0, 0.01) var base_relax: float = 0.6

# ==================== 体积光照 / 三维细节 ====================
## 三维细节强度：0 = 退回"平面挤出"观感，1 = 强烈翻涌
@export_range(0.0, 1.0, 0.01) var detail_strength: float = 0.65
## 三维细节的空间频率（1/米）
@export_range(0.0, 0.5, 0.005) var detail_scale: float = 0.055
## 体积光照（光轴/丁达尔）强度：0 = 关闭
@export_range(0.0, 8.0, 0.05) var scatter_strength: float = 2.2
## 自遮挡强度：越大光轴越锐利、雾的明暗分层越明显
@export_range(0.0, 8.0, 0.05) var light_absorption: float = 2.6
## 朝太阳方向的采样步数（0 = 关闭体积光照）
@export_range(0, 12, 1) var light_steps: int = 3
## 是否自动找场景里的平行光当太阳（找不到就用默认方向）
@export var auto_sun: bool = true

# ==================== 局部光源 / 光束（暗场景里烟被内部光源照亮） ====================
## 发光体所在的组（OmniLight3D/SpotLight3D 直接放进去即可，无需额外组件）
@export var light_group: String = "fog_light"
## 光束所在的组（放一个 FogBeam 节点即可自动入组）
@export var beam_group: String = "fog_beam"
## 是否收集局部光源与光束
@export var local_lights_enabled: bool = true
## 局部光源散射强度（参考画面里红光渗进烟里的亮度）
@export_range(0.0, 16.0, 0.05) var local_scatter_strength: float = 3.2
## 粒子受光系数。★ 必须与 local_scatter_strength **分开**：后者是体积盒沿光路累积的量，
## 数量级大（3~5）；粒子是逐粒子一次性取值，用同一个数会让每颗粒子都顶到钳位而整片爆白
## （踩过：5.0 让烟全白）。0.2~0.5 是合理区间。
@export_range(0.0, 4.0, 0.01) var particle_light_response: float = 0.32
## 空洞阈值：三维噪声低于它的地方**完全没有雾**（能透过烟看到黑背景）
@export_range(0.0, 1.0, 0.01) var cavity_threshold: float = 0.34
## 空洞边缘软硬：越小边缘越硬、絮状越明显
@export_range(0.02, 1.0, 0.01) var cavity_softness: float = 0.38

# ==================== 风 ====================
## **风系数**：把"天气/外部给的风"整体缩放（1.0 = 原始强度）。
## ★ 默认 0.4：按默认风量级，1.0 会把烟吹得过于剧烈并逐帧抖动（流场本身含网格尺度噪声）。
##   作用于：求解器目标风、以及噪声的流动拖拽（particle_flow_warp 再乘它）。
##   **不**作用于粒子跟风速率（那是响应速度，重复相乘会变成二次缩放）。
@export_range(0.0, 4.0, 0.05) var wind_scale: float = 0.4
## 粒子跟随流场的速率（1/秒）：越小越"钝"、越不容易抖。
@export_range(0.05, 4.0, 0.05) var particle_flow_follow: float = 0.7
## 声被流场拖拽的强度（flowmapping）。★ 调大会闪烁：它吃的是**瞬时**速度场，
## 网格尺度噪声会被逐帧放大成抖动。0.02~0.08 是安全区间。
@export_range(0.0, 1.0, 0.01) var particle_flow_warp: float = 0.05
## **流场强度**：粒子被速度场搬运的倍率。0 = 粒子**完全无视流体**（只受合成风/抖动影响）。
## ★ 为什么需要它：`wind_scale` 只关掉"外部风"，而速度场里还有**涡量约束**（反耗散项，
##   靠数值噪声自发维持小尺度涡）、`add_source` 注入、交互体注入 —— 这些都会让场保持非零，
##   再被 `× domain_size`（80 米）放大成米/秒，表现就是"风都关 0 了，雾还是飞快地抖"。
@export_range(0.0, 4.0, 0.05) var particle_flow_scale: float = 1.0
## **粒子跟随速度上限（米/秒）**：0 = 不限。
## ★ `× domain_size` 是**单位换算**（求解器的速度场是"域单位/秒"，域被归一化成 1×1，
##   所以 1 域单位 = domain_size 米），不是放大倍率。但速度场里除风以外还有
##   `add_source` 注入、交互体径向排开、涡量约束（反耗散），它们能把很小的场值放大成
##   几米/秒 —— 于是"风关到 0 雾还在飞快跑"。这个上限就是那道保险。
@export_range(0.0, 40.0, 0.05) var particle_flow_speed_cap: float = 1.5
## **烟的环境底色亮度**：没被光照到时烟的样子。0.25~0.5 = 参考图那种中灰；0 = 纯黑会看不见
@export_range(0.0, 1.0, 0.01) var particle_ambient: float = 0.34
## **受光叠加量**：亮部（黑体色温）的强度上限。只有被照亮的部分才加，暗部保持底色
@export_range(0.0, 2.0, 0.01) var particle_light_add: float = 0.55
## **点光源衰减指数**：1 = 旧的 1/(1+d²/r²)（20 米外仍有 23% ⇒ 整团均匀泛红）；
## 2~3 = 红光收拢成"从浓烟内部透出一片红"的局部红斑（参考图效果）
@export_range(0.5, 4.0, 0.1) var particle_light_falloff: float = 2.0
## **顺风向拉伸**：<1 = 顺风压扁 ⇒ 丝状"流动感"；1.0 = 各向同性（看起来就是一团团）
@export_range(0.05, 1.0, 0.01) var particle_stretch: float = 0.35
## **边缘侵蚀**：用共享的世界噪声咬掉粒子边界，让相邻粒子连成一片。
## 0 = 一堆软圆盘（团块感），0.6~0.9 = 连续流动的烟
@export_range(0.0, 1.0, 0.01) var particle_erosion: float = 0.8

# ==================== 交互（物体搅动雾气） ====================
@export var interactor_group: String = "fog_interactor"
## 是否扫描交互物体
@export var interactors_enabled: bool = true
## 没有显式指定时，交互体默认的搅动半径（米）
@export_range(0.5, 60.0, 0.5) var interactor_radius: float = 8.0
## 默认"挖雾"速率（每秒）。负值 = 把雾推开
@export_range(-2.0, 2.0, 0.01) var interactor_carve: float = -0.9
## 交互体速度 -> 目标风速的放大系数
@export_range(0.0, 5.0, 0.05) var interactor_velocity_scale: float = 1.0
## 重新扫描交互体列表的间隔（秒）：不必每帧找节点
@export_range(0.05, 5.0, 0.05) var interactor_scan_interval: float = 0.5

# ==================== 角色涡流（人物在雾里走动时绕身卷起） ====================
## ★ 把 `character_group`（默认就是本项目的角色组 "player"）里**正在移动**的节点当作
##   "绕身涡流"源：在它周围注入一个**切向**速度场 ⇒ 雾绕着它转、并被卷成螺旋拖在身后。
##   静止时不注入（沿用交互体那条规则），所以站着不动时观感与旧版一致。
##   想更精细地控制就挂 `FogInteractor` 组件（显式组件的参数优先，且不会被本项重复注入）。
## ★ 受 `interactors_enabled` 总开关控制（两条注入路径共用"物体搅动雾气"这一件事）。
@export var character_stir_enabled: bool = true
## 扫哪个组找角色（player.gd 在 _ready 里 add_to_group("player")）
@export var character_group: String = "player"
## 绕身**切向风速**（m/s）：>0 逆时针、<0 顺时针、0 = 只推开不转（旧观感）
## ★ 用 m/s 而不是"域单位/秒"：域尺寸一改，同一个数在屏幕上表现一致（与 wind_speed_mps 同一约定）。
## ★ 标定：默认 20 m/s + 默认半径 4 米，在 tools/fog_vortex_showcase 的数值自检里
##   实测角色周围环流 ≈ 2.5~4.6 m/s（旋向与参数同号），与走路速度同量级 —— 看得见但不失控。
@export_range(-40.0, 40.0, 0.1) var character_swirl_mps: float = 20.0
## 涡流半径（米）：比角色大一圈比较自然（雾被卷动的范围）。3~4 是"贴着人绕"，
## 5~8 是"整个人带起一团"。
@export_range(0.5, 20.0, 0.1) var character_swirl_radius_m: float = 4.0
## 角色周围的"挖雾"速率（每秒）：负值挖出比周围稀的洞，0 = 只搅不挖
@export_range(-2.0, 2.0, 0.01) var character_carve: float = -0.4
## 涡流强度的**参考速度**（m/s）：角色速度 / 本值 用来缩放切向速度
## （走路≈3 m/s ⇒ 1.0 倍；跑起来更强，但夹在 0.25~1.6 倍之间，避免速度尖峰炸场）
@export_range(0.5, 12.0, 0.1) var character_swirl_ref_speed: float = 3.0

# ============ 角色涡流「可视化」（独立着色器层，做明暗变化） ============
## ★ 为什么单独一层：浓雾里浓度早就饱和成**白幕**了 —— 白幕上没有细节，
##   所以把浓度搅来搅去屏幕上什么都看不出来（这就是"改了参数也没效果"的真相）。
##   这一层**完全不看浓度场**：在角色周身套一个螺旋条带的圆筒，用**明暗差**把涡卷画出来 ——
##     暗带把白雾压成灰蓝条纹；亮带在深色草地/地面上提亮。
##   于是无论背景是浓白雾还是深色地面，都能看见"绕着他卷的那股风"。
##   角色静止时强度自动归零（整层全透明 = 等于没开）。
@export var vortex_visual_enabled: bool = true
## 涡流层**半径**（米）：只围着角色周身一点点空间，别设大（0.8~2.0 米足够）。
## 0 = 自动取 character_swirl_radius_m × 0.25 夹到 0.8~2.0（永远贴住角色）。
@export_range(0.0, 40.0, 0.1) var vortex_visual_radius_m: float = 1.5
## 涡流层**高度**（米）：**任意值**，和半径没有任何关系（不做计算、不按比例推导）。
## 半径、高度是两把独立的尺子：任意组合都成立 —— 着色器内部按各自尺寸完整归一化，
## 所以"半径 1 米 + 高度 1.2 米"和"半径 3 米 + 高度 5 米"看到的是同一个图案，只是大小不同。
@export_range(0.05, 40.0, 0.05) var vortex_visual_height_m: float = 2.6
## 最大不透明度：涡流最浓能压多暗（0.3~0.6 自然；>0.8 会像贴上去的塑料条纹）
@export_range(0.0, 1.0, 0.01) var vortex_visual_alpha: float = 0.62
## 螺旋圈数：越大条纹越密（2~4 像一股风，>6 像细丝）
@export_range(0.0, 8.0, 0.1) var vortex_visual_turns: float = 1.6
## 旋转速度（圈/秒）
@export_range(0.0, 6.0, 0.05) var vortex_visual_spin_speed: float = 1.4
## 暗带颜色（把底下的浓白雾压暗，白幕上就靠它显形）
@export var vortex_visual_dark := Color(0.30, 0.36, 0.47)
## 亮带颜色（在深色草/地面上提亮，形成"被光扫过"的银边）
@export var vortex_visual_light := Color(0.98, 0.99, 1.0)
## 条纹锐度（越大越像细丝）
@export_range(0.5, 8.0, 0.1) var vortex_visual_sharpness: float = 1.7
## 条纹抖动：打散"规则螺旋"的塑料感
@export_range(0.0, 1.0, 0.01) var vortex_visual_wobble: float = 0.28

# ==================== 画笔底图 ====================
## 画笔数据（由 addons/fog_brush 插件在编辑器里刷）。可在编辑器里新建/指定 .tres/.png。
@export var brush_field: FogBrushField

# ==================== 天气 / 画质接线 ====================
## 是否自动跟随 /root/Weather 的风与雾量
@export var auto_weather: bool = true
## 风力换算：weather.wind = 1.0 对应的风速（m/s）
@export var wind_speed_mps: float = 4.0
## 晴天的"底雾"不透明度：保证 Clear 天气也有一层薄地雾（0 = 完全跟随天气）
@export_range(0.0, 2.0, 0.01) var idle_opacity: float = 0.25
## 是否在 _ready 读取一次 /root/Quality 的档位
@export var quality_follows_project: bool = true
## 初始是否启用
@export var start_enabled: bool = true
## 雾源把周围空气拉向目标速度的松弛速率（1/秒）。2.0 ≈ 半秒内见效。
@export_range(0.0, 20.0, 0.1) var source_velocity_rate: float = 2.0

# ==================== 运行时对象 ====================
var solver: FogNsSolver
var brush_texture: Texture2D

var _volume: MeshInstance3D
var _volume_material: ShaderMaterial
var _particles: GPUParticles3D
## 蓝噪声抖动掩膜（懒生成，只做一次）与逐帧序号
var _jitter_texture: ImageTexture
var _jitter_frame: int = 0
var _particles_material: ShaderMaterial
var _weather: Node
var _editor_preview := false
## 三维细节噪声（懒加载：只在需要渲染体积雾时才生成）
var _detail_texture: ImageTexture3D
## 粒子用的二维形状噪声
var _particle_noise: ImageTexture
var _sun: DirectionalLight3D
var _interactors: Array[Node3D] = []
## 角色涡流可视化：跟随角色的螺旋条带圆筒（独立着色器，不看浓度场）
var _vortex_visual: MeshInstance3D
var _vortex_material: ShaderMaterial
## character_group 里的节点（角色涡流的注入对象，与 _interactors 同一趟扫描）
var _characters: Array[Node3D] = []
var _interactor_previous := {}
var _interactor_timer := 0.0
## 风目标（域单位/秒），用来让三维细节跟着风漂移
var _wind_target := Vector2.ZERO
var _base_opacity: float = 1.0
var _opacity_override: float = -1.0
var _wind_override: Vector2 = Vector2.ZERO
var _has_wind_override := false
var _source_queue: Array[Dictionary] = []


func _ready() -> void:
	_editor_preview = Engine.is_editor_hint()
	if _editor_preview:
		# ★ 编辑器路径（@tool 会在每次打开/切换场景时跑）：
		#   建**体积盒 + 粒子**当画笔预览，但**不建求解器**（不在编辑器里跑 13 个 SubViewport）。
		#   为什么要建粒子：不建的话，面板上的风系数/粒子数量/尺寸/强度/受光
		#   **完全没有作用对象**，拖动滑块看不出任何变化（用户反馈"设置跟不设置没区别"）。
		_create_volume()
		_create_particles()
		set_brush_field(brush_field)
		_apply_particle_params()
		_apply_volume_params()
		return

	_create_solver()
	if volumetric_box:
		_create_volume()
	_create_particles()
	# ★ 涡流可视化层：独立于浓度场（浓雾饱和时浓度扰动看不见，这一层直接画明暗条纹）
	_create_vortex_visual()
	# ★ 装配完成后立刻应用一次"雾层高度带"：属性 setter 在 _ready 之前跑过，
	#   那时粒子/体积盒还不存在，所以必须在这里补一次（否则离地高度不生效）。
	_apply_height_band()
	_bind_weather()
	if quality_follows_project:
		_apply_project_quality()
	enabled = start_enabled
	_apply_solver_settings()


func _exit_tree() -> void:
	if is_instance_valid(solver):
		solver.teardown()


# =========================================================
# 装配
# =========================================================

func _create_solver() -> void:
	solver = SOLVER_SCRIPT.new() as FogNsSolver
	solver.name = "FogNsSolver"
	# ★ 配置必须在 add_child **之前**写：add_child 会同步触发 solver._ready()，
	#   而 _ready 里就会按当前参数建好通道链。写完再 add_child 只需要建一次链；
	#   反过来（先 add_child 再改参数）会出现"改分辨率没生效"，或者被迫 setup() 两次
	#   （teardown 用的是 queue_free，旧通道要到帧末才消失，会短暂出现两份通道）。
	solver.domain_size = domain_size
	solver.box_height = box_height
	solver.base_height = base_height
	solver.resolution = resolution
	solver.jacobi_passes = jacobi_passes
	solver.velocity_dissipation = velocity_dissipation
	solver.density_dissipation = density_dissipation
	solver.vorticity_strength = vorticity_strength
	solver.base_relax = base_relax
	add_child(solver)
	set_brush_field(brush_field)


func _create_volume() -> void:
	_volume = MeshInstance3D.new()
	_volume.name = "MistVolume"
	var box := BoxMesh.new()
	box.size = Vector3(domain_size.x, box_height, domain_size.y)
	_volume.mesh = box
	_volume.position = Vector3(0.0, base_height + box_height * 0.5, 0.0)
	_volume.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# ★ 包围盒给足余量：盒子本身巨大且随节点移动，剔除判定保守一点才不会整块闪没。
	_volume.extra_cull_margin = maxf(domain_size.x, domain_size.y)

	_volume_material = ShaderMaterial.new()
	_volume_material.shader = load(VOLUME_SHADER)
	_volume_material.set_shader_parameter("domain_size", domain_size)
	_volume_material.set_shader_parameter("box_height", box_height)
	_volume_material.set_shader_parameter("opacity", fog_opacity)
	_volume_material.set_shader_parameter("density_gain", density_gain)
	_volume_material.set_shader_parameter("height_power", height_power)
	_volume_material.set_shader_parameter("edge_fade", edge_fade)
	_volume_material.set_shader_parameter("wisp_amount", wisp_amount)
	_volume_material.set_shader_parameter("mist_color_lit", mist_color_lit)
	_volume_material.set_shader_parameter("mist_color_shadow", mist_color_shadow)
	_volume_material.set_shader_parameter("march_steps", march_steps)
	# 体积光照（光轴）与三维细节：这是"真体积感"的两个来源，见 fog_mist_volume.gdshader
	_volume_material.set_shader_parameter("detail_strength", detail_strength)
	_volume_material.set_shader_parameter("detail_scale", detail_scale)
	_volume_material.set_shader_parameter("scatter_strength", scatter_strength)
	_volume_material.set_shader_parameter("absorption", light_absorption)
	_volume_material.set_shader_parameter("light_steps", light_steps)
	_volume_material.set_shader_parameter("cavity_threshold", cavity_threshold)
	_volume_material.set_shader_parameter("cavity_softness", cavity_softness)
	_volume_material.set_shader_parameter("local_scatter_strength", local_scatter_strength)
	var detail := _ensure_detail_texture()
	if detail != null:
		_volume_material.set_shader_parameter("detail_tex", detail)
	_volume.material_override = _volume_material
	add_child(_volume)
	_base_opacity = fog_opacity
	_bind_density_texture()


func _create_vortex_visual() -> void:
	_vortex_visual = MeshInstance3D.new()
	_vortex_visual.name = "VortexSwirl"
	# ★ 用"半径 1、高 1"的开口圆筒 + scale 缩放：改半径/高度不用重建网格
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 1.0
	cylinder.bottom_radius = 1.0
	cylinder.height = 1.0
	cylinder.radial_segments = 64
	cylinder.rings = 0
	cylinder.cap_top = false
	cylinder.cap_bottom = false
	_vortex_visual.mesh = cylinder
	_vortex_material = ShaderMaterial.new()
	_vortex_material.shader = load(VORTEX_SWIRL_SHADER)
	# ★ 必须画在体积雾**之后**：体积雾是 depth_test_disabled 的透明层，
	#   优先级相同的话顺序不保证，涡流会被雾盖掉（表现就是"加了 shader 也看不见"）。
	_vortex_material.render_priority = 1
	_apply_vortex_visual_params()
	_vortex_visual.material_override = _vortex_material
	_vortex_visual.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 圆筒在角色周围、随时可能被视锥剔除判定得保守一点
	_vortex_visual.extra_cull_margin = 64.0
	_vortex_visual.visible = false          # 角色没动之前不显示
	add_child(_vortex_visual)


## 样式类 uniform 的同步（形状/强度在 _update_vortex_visual 里每帧按角色更新）。
func _apply_vortex_visual_params() -> void:
	if _vortex_material == null:
		return
	_vortex_material.set_shader_parameter("alpha_max", vortex_visual_alpha)
	_vortex_material.set_shader_parameter("turns", vortex_visual_turns)
	_vortex_material.set_shader_parameter("spin_speed", vortex_visual_spin_speed)
	_vortex_material.set_shader_parameter("dark_color", vortex_visual_dark)
	_vortex_material.set_shader_parameter("light_color", vortex_visual_light)
	_vortex_material.set_shader_parameter("streak_sharpness", vortex_visual_sharpness)
	_vortex_material.set_shader_parameter("wobble", vortex_visual_wobble)
	if _vortex_visual != null and not vortex_visual_enabled:
		_vortex_visual.visible = false


## 每帧把涡流层摆到角色身上（形状 + 强度 + 旋向）。
## 强度按角色速度缩放 ⇒ 走得快卷得猛；速度 < 0.05 直接隐藏（站着不动什么都不显示）。
func _update_vortex_visual(node: Node3D, speed_mps: float) -> void:
	if _vortex_visual == null or _vortex_material == null:
		return
	if not vortex_visual_enabled or speed_mps < 0.05:
		_vortex_visual.visible = false
		return
	# ★ 半径、高度是**两把独立的尺子**，不做任何互相推导：
	#   半径只决定"围多大一圈"，高度只决定"这层有多高"，任意组合都成立。
	#   着色器内部把 r 除以 radius、y 除以 height 全部归一化，
	#   所以半径 1 米×高 1.2 米 与 半径 3 米×高 5 米 是同一个图案，只是大小不同。
	var radius := vortex_visual_radius_m
	if radius <= 0.0:
		# 0 = 自动：取流体涡流半径的 1/4 并夹在 0.8~2.0 米 —— 永远只是"围着角色一点点"
		radius = clampf(character_swirl_radius_m * 0.25, 0.8, 2.0)
	radius = maxf(radius, 0.05)
	var height := maxf(vortex_visual_height_m, 0.05)
	_vortex_visual.visible = true
	# 竖直居中在角色身上（底边贴地）：高度多高，就裹到多高，跟半径无关
	_vortex_visual.global_position = node.global_position + Vector3(0.0, height * 0.5, 0.0)
	_vortex_visual.scale = Vector3(radius, height, radius)
	_vortex_material.set_shader_parameter("radius", radius)
	_vortex_material.set_shader_parameter("height", height)
	# 旋向跟 character_swirl_mps 的符号一致（0 时用 +1，靠强度为 0 不显示）
	_vortex_material.set_shader_parameter("spin_sign",
			1.0 if character_swirl_mps >= 0.0 else -1.0)
	var reference := maxf(character_swirl_ref_speed, 0.1)
	_vortex_material.set_shader_parameter("strength",
			clampf(speed_mps / reference, 0.15, 1.6))


func _create_particles() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "MistParticles"
	_particles.amount = maxi(particle_count, 1)
	_particles.lifetime = particle_lifetime
	# ★ 雾**不投影**：粒子若不透明，会在地面上留下"脏斑/阴影"的观感（用户实测反馈）。
	#   几何体本身也不投影（_create_volume 里同样设了 OFF），两边保持一致。
	_particles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_particles.one_shot = false
	_particles.local_coords = true
	_particles.explosiveness = 0.0
	_particles.randomness = 0.9
	_particles.fixed_fps = 0
	# 面向相机的方片（Godot 4 里粒子的朝向由节点控制，不是材质里的 billboard 渲染模式）
	_particles.transform_align = GPUParticles3D.TRANSFORM_ALIGN_Z_BILLBOARD
	_particles.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	_particles.emitting = particles_enabled and particle_count > 0
	# ★ 必须显式给一个大包围盒：粒子会跑到 x/z 负半轴，自动 AABB 在首帧可能算不出来。
	var half := Vector3(domain_size.x * 0.5, box_height, domain_size.y * 0.5)
	_particles.visibility_aabb = AABB(-half - Vector3(2, 2, 2), half * 2.0 + Vector3(4, 4, 4))

	var process_material := ShaderMaterial.new()
	process_material.shader = load(PARTICLE_PROCESS_SHADER)
	process_material.set_shader_parameter("domain_size", domain_size)
	process_material.set_shader_parameter("box_height", box_height)
	# 与节点 lifetime 保持一致：粒子着色器里 LIFETIME 只读，逐粒子寿命要靠这个 uniform 折算。
	process_material.set_shader_parameter("lifetime_seconds", _particles.lifetime)
	# ★ 编辑器预览没有流场：必须关掉流场采样并改用合成风，否则未赋值的 sampler 会绑成白图，
	#   粒子会瞬间飞出画面（这也是"预览里粒子乱飞"的根因）。
	process_material.set_shader_parameter("flow_enabled", 0 if _editor_preview else 1)
	_particles.process_material = process_material

	var quad := QuadMesh.new()
	quad.size = Vector2(particle_size, particle_size)
	_particles.draw_pass_1 = quad

	_particles_material = ShaderMaterial.new()
	_particles_material.shader = load(PARTICLE_DRAW_SHADER)
	_particles_material.set_shader_parameter("smoke_color", particle_color)
	_particles_material.set_shader_parameter("strength", particle_strength * maxf(fog_opacity, 0.0))
	var particle_noise := _ensure_particle_noise()
	if particle_noise != null:
		_particles_material.set_shader_parameter("noise_tex", particle_noise)
	_particles.material_override = _particles_material

	add_child(_particles)
	_bind_flow_texture()


## 把求解器的纹理接到体积雾/粒子上。求解器重建通道后必须重新调用（纹理对象会变）。
func _bind_density_texture() -> void:
	if solver == null or _volume_material == null:
		return
	var texture := solver.density_texture()
	if texture != null:
		_volume_material.set_shader_parameter("density_tex", texture)


func _bind_flow_texture() -> void:
	if solver == null or _particles == null:
		return
	var texture := solver.velocity_texture()
	if texture == null:
		return
	var process_material := _particles.process_material as ShaderMaterial
	if process_material != null:
		process_material.set_shader_parameter("flow_tex", texture)
		process_material.set_shader_parameter("domain_size", domain_size)
	# ★ 绘制材质也要速度场：粒子烟雾用它对噪声做 **flowmapping**（域扭曲），
	#   否则烟只会平移、不会"被风拉扯折叠"（FluidNinja 的 velocity-based flowmapping）。
	if _particles_material != null:
		_particles_material.set_shader_parameter("flow_tex", texture)
		_particles_material.set_shader_parameter("domain_size", domain_size)


# =========================================================
# 每帧
# =========================================================

## 把"雾层高度带"应用到所有渲染器：粒子、体积盒、交互体。
## ★ 必须在**两条渲染路径**上都生效，否则调了参数只有一半东西动：
##     · 粒子路径：抬高粒子节点 + 把 box_height 传给粒子着色器（出生/上升范围）+ 更新包围盒
##     · 体积盒路径（volumetric_box = true）：重建盒子的尺寸与位置
##   这个方法可以被**属性 setter** 调用（编辑器里拖 SpinBox 立刻看到），也可以运行期调。
func _apply_height_band() -> void:
	if _particles != null:
		# 抬高整个粒子节点：出生范围 [0, box_height] 于是落在世界 [base_height, base_height+box_height]
		_particles.position = Vector3(0.0, base_height, 0.0)
		var process_material := _particles.process_material as ShaderMaterial
		if process_material != null:
			process_material.set_shader_parameter("box_height", box_height)
			process_material.set_shader_parameter("base_height", base_height)
		# 包围盒要覆盖抬高后的整个带（粒子在负半轴也会出现，所以留余量）
		var half := Vector3(domain_size.x * 0.5, maxf(box_height, 1.0), domain_size.y * 0.5)
		_particles.visibility_aabb = AABB(-half - Vector3(2, 2, 2), half * 2.0 + Vector3(4, 4, 4))
	if _volume != null:
		var box := _volume.mesh as BoxMesh
		if box != null:
			box.size = Vector3(domain_size.x, box_height, domain_size.y)
		_volume.position = Vector3(0.0, base_height + box_height * 0.5, 0.0)
	if _volume_material != null:
		_volume_material.set_shader_parameter("box_height", box_height)
	# 交互体的抬升要跟着雾带一起走，否则"挖洞"会挖在地面高度上（雾已经抬上去了）
	_apply_volume_params()


func _process(delta: float) -> void:
	# 编辑器预览：不跑流体，只把参数同步给粒子/体积雾，让面板上的每个滑块都有可见效果
	if _editor_preview:
		_apply_particle_params()
		_apply_volume_params()
		return
	if solver == null:
		return
	if not enabled:
		return

	_apply_pending_sources()
	_apply_weather()
	if interactors_enabled:
		_update_interactors(delta)
	else:
		_hide_vortex_visual()       # 关掉交互时别把涡流层留在原地
	solver.step(delta)
	_apply_volume_params()


## 生成粒子用的**二维**形状噪声（256²，FastNoiseLite 分形）。
## ★ 粒子烟必须有内部纹理，否则就退化成"一串能数出来的圆球"。用世界坐标采样它，
##   相邻粒子纹理连续、移动时纹理流动，不需要任何额外贴图资产。
func _ensure_particle_noise() -> ImageTexture:
	if _particle_noise != null:
		return _particle_noise
	var size := 256
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.012
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.5
	noise.fractal_lacunarity = 2.1
	var image := Image.create(size, size, false, Image.FORMAT_R8)
	for y in range(size):
		for x in range(size):
			var value := clampf(noise.get_noise_2d(float(x), float(y)) * 0.5 + 0.5, 0.0, 1.0)
			value = clampf(pow(value, 0.75) * 1.15, 0.0, 1.0)   # 拉开对比：烟丝要有"洞"
			image.set_pixel(x, y, Color(value, value, value, 1.0))
	_particle_noise = ImageTexture.create_from_image(image)
	return _particle_noise


## 生成三维细节噪声（64³ 的 FastNoiseLite 切片）。
## ★ 用 ImageTexture3D 手搓而不是找现成资源：**不引入依赖**，且尺寸/频率可控；
##   32³ = 32 张 32×32 图，生成一次约几十毫秒，只在首次需要体积雾时做。
func _ensure_detail_texture() -> ImageTexture3D:
	if _detail_texture != null:
		return _detail_texture
	var size := 64
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.06
	noise.fractal_octaves = 3
	noise.fractal_gain = 0.55
	var slices: Array[Image] = []
	for z in range(size):
		var image := Image.create(size, size, false, Image.FORMAT_R8)
		for y in range(size):
			for x in range(size):
				var value := clampf(
					noise.get_noise_3d(float(x), float(y), float(z)) * 0.5 + 0.5, 0.0, 1.0)
				image.set_pixel(x, y, Color(value, value, value, 1.0))
		slices.append(image)
	var texture := ImageTexture3D.new()
	var error := texture.create(Image.FORMAT_R8, size, size, size, false, slices)
	if error != OK:
		push_warning("FogField: 三维细节纹理创建失败（err=%d），雾将退回二维层次" % error)
		return null
	_detail_texture = texture
	return _detail_texture


## 找场景里的第一盏可见平行光当太阳（用于体积光照方向与颜色）。
## ★ 只找 DirectionalLight3D：点光/聚光的体积散射需要另外的采样方式，超出当前实现。
func _find_sun() -> DirectionalLight3D:
	if not auto_sun:
		return null
	if is_instance_valid(_sun):
		return _sun
	var root: Node = null
	if get_tree() != null:
		root = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
	if root == null:
		return null
	_sun = _find_sun_recursive(root)
	return _sun


func _find_sun_recursive(node: Node) -> DirectionalLight3D:
	if node is DirectionalLight3D:
		var light := node as DirectionalLight3D
		if light.visible:
			return light
	for child in node.get_children():
		var found := _find_sun_recursive(child)
		if found != null:
			return found
	return null


## ★ 收集"烟内部的发光体"与"光束"并打包进着色器。
##   为什么从场景组里收：暗场景里让烟显形的不是太阳，而是红光/激光/火焰。
##   支持两类发光体，都不需要写代码：
##     · 组 fog_light：OmniLight3D / SpotLight3D（用它的 range 与颜色×能量），
##                     或任意带 fog_light_radius / fog_light_color 属性的 Node3D；
##     · 组 fog_beam ：FogBeam 组件（起点/终点/半径/颜色/强度）。
##   上限 8 个局部光 + 4 束光（着色器里的 uniform 数组长度）：超出会按顺序截断，
##   所以**把最重要的光源放在场景里靠前的位置**。
func _apply_local_sources() -> void:
	# ★ 这里**不能**因为 _volume_material == null 就 return：关掉体积盒（纯粒子模式）时
	#   它确实是 null，但粒子照样需要这份光源数据 —— 暗场景里烟就是靠它显形的。
	#   （踩过：这一行 early-return 让纯粒子模式整片黑，且自检读到的光源数是 null。）
	# ★ 不在场景树里就直接返回：box_height/base_height 的 setter 会在 add_child **之前**
	#   触发这条链路，此时 get_tree() 不可用（引擎报 "Parameter data.tree is null"）。
	#   真正的打包会在进树后的第一帧 _process 里完成，所以这里跳过没有副作用。
	if not is_inside_tree():
		return
	if not local_lights_enabled:
		if _volume_material != null:
			_volume_material.set_shader_parameter("fog_light_count", 0)
			_volume_material.set_shader_parameter("beam_count", 0)
		return

	var lights: Array[PackedVector4Array] = []
	var light_positions := PackedVector4Array()
	var light_colors := PackedVector3Array()
	for node in get_tree().get_nodes_in_group(light_group) if get_tree() != null else []:
		if not (node is Node3D) or not (node as Node3D).visible:
			continue
		if light_positions.size() >= 8:
			break
		var spatial := node as Node3D
		var radius := 20.0
		var color := Color(1, 0.35, 0.2)
		if spatial is OmniLight3D:
			var omni := spatial as OmniLight3D
			radius = omni.omni_range
			color = omni.light_color * clampf(omni.light_energy, 0.0, 16.0)
		elif spatial.get("fog_light_radius") != null:
			radius = float(spatial.get("fog_light_radius"))
			if spatial.get("fog_light_color") != null:
				color = spatial.get("fog_light_color")
		light_positions.append(Vector4(
			spatial.global_position.x, spatial.global_position.y, spatial.global_position.z,
			maxf(radius, 0.5)))
		light_colors.append(Vector3(color.r, color.g, color.b))

	var beam_starts := PackedVector4Array()
	var beam_ends := PackedVector4Array()
	var beam_colors := PackedVector3Array()
	for node in get_tree().get_nodes_in_group(beam_group) if get_tree() != null else []:
		if not (node is Node3D) or beam_starts.size() >= 4:
			continue
		var spatial := node as Node3D
		if spatial.get("fog_beam_start") == null or spatial.get("fog_beam_radius") == null:
			continue
		var start: Vector3 = spatial.get("fog_beam_start")
		var finish: Vector3 = spatial.get("fog_beam_end")
		var color: Color = spatial.get("fog_beam_color")
		var radius := float(spatial.get("fog_beam_radius"))
		var intensity := float(spatial.get("fog_beam_intensity"))
		beam_starts.append(Vector4(start.x, start.y, start.z, maxf(radius, 0.02)))
		beam_ends.append(Vector4(finish.x, finish.y, finish.z, maxf(intensity, 0.0)))
		beam_colors.append(Vector3(color.r, color.g, color.b))

	# ★ 必须把数组**补到固定长度**再上传：着色器里声明的是 fog_lights[8]/beam_start[4]，
	#   短数组会有未定义的尾部（表现为随机颜色的杂光）。
	while light_positions.size() < 8:
		light_positions.append(Vector4.ZERO)
		light_colors.append(Vector3.ZERO)
	while beam_starts.size() < 4:
		beam_starts.append(Vector4.ZERO)
		beam_ends.append(Vector4.ZERO)
		beam_colors.append(Vector3.ZERO)

	if _volume_material != null:
		_volume_material.set_shader_parameter("fog_lights", light_positions)
		_volume_material.set_shader_parameter("fog_light_colors", light_colors)
		_volume_material.set_shader_parameter("fog_light_count",
				light_colors.size() - _count_zero_colors(light_colors))
		_volume_material.set_shader_parameter("beam_start", beam_starts)
		_volume_material.set_shader_parameter("beam_end", beam_ends)
		_volume_material.set_shader_parameter("beam_colors", beam_colors)
		_volume_material.set_shader_parameter("beam_count", _count_nonzero_beams(beam_ends))

	# ★ 把"噪声纹理 + 密度纹理 + 雾域"推给每束光（亮线的颗粒感与"被浓雾吸收"都需要它）。
	#   推的是 FogField 自己生成的资源，光束不需要知道雾体在哪（分层：光束只是数据节点）。
	for node in get_tree().get_nodes_in_group(beam_group) if is_inside_tree() else []:
		if node.has_method("set_glow_textures"):
			node.call("set_glow_textures", _ensure_particle_noise(), brush_texture,
					domain_size, Vector2(global_position.x, global_position.z))

	# ★ 同一批光源/光束也要喂给**粒子**着色器：暗场景里烟团是靠它们显形的，
	#   只给体积盒的话"关掉盒子"就整片黑（这正是从体积雾切到粒子时的头号坑）。
	var process_material := _particles.process_material as ShaderMaterial if _particles != null else null
	if process_material != null:
		process_material.set_shader_parameter("fog_lights", light_positions)
		process_material.set_shader_parameter("fog_light_colors", light_colors)
		process_material.set_shader_parameter("fog_light_count", light_colors.size() - _count_zero_colors(light_colors))
		process_material.set_shader_parameter("beam_start", beam_starts)
		process_material.set_shader_parameter("beam_end", beam_ends)
		process_material.set_shader_parameter("beam_colors", beam_colors)
		process_material.set_shader_parameter("beam_count", _count_nonzero_beams(beam_ends))
		process_material.set_shader_parameter("light_response", particle_light_response)


## 数一下真正有效的局部光（颜色非零）
func _count_zero_colors(colors: PackedVector3Array) -> int:
	var used := 0
	for color in colors:
		if color != Vector3.ZERO:
			used += 1
	return 8 - used if used <= 8 else 0


## 数一下真正有效的光束（强度非零）
func _count_nonzero_beams(ends: PackedVector4Array) -> int:
	var used := 0
	for entry in ends:
		if entry.w > 0.0:
			used += 1
	return used


## 重新扫描交互体（组 fog_interactor）+ 角色（组 character_group）。
func _scan_interactors() -> void:
	_interactors.clear()
	_characters.clear()
	if get_tree() == null:
		return
	for node in get_tree().get_nodes_in_group(interactor_group):
		if node is Node3D:
			_interactors.append(node as Node3D)
	if not character_stir_enabled or character_group.is_empty():
		return
	for node in get_tree().get_nodes_in_group(character_group):
		if node is Node3D:
			_characters.append(node as Node3D)


## 取节点本帧的速度：CharacterBody3D 用它的 velocity（更准，不受帧率抖动影响），
## 其余节点（动画骨骼、被 tween 推的道具）用**位置差分** —— 对任何 Node3D 都成立。
func _node_velocity(node: Node3D, delta: float) -> Vector3:
	var position := node.global_position
	var previous: Vector3 = _interactor_previous.get(node, position)
	_interactor_previous[node] = position
	if node is CharacterBody3D:
		return (node as CharacterBody3D).velocity
	return (position - previous) / delta


## 这个角色是不是已经挂了 FogInteractor（自己或祖先/子节点）？是的话不再自动注入，
## 否则同一个位置会被注入两份（浓度与速度都翻倍，看起来就像"参数突然变猛"）。
func _handled_by_interactor(node: Node3D) -> bool:
	for other in _interactors:
		if not is_instance_valid(other):
			continue
		if other == node or other.is_ancestor_of(node) or node.is_ancestor_of(other):
			return true
	return false


## ★ 交互的核心：把"会动的东西"变成速度源 + 挖雾源投进流体场。
##   为什么用位移算速度而不是直接读 velocity：雾不该只对 CharacterBody3D 生效 ——
##   动画骨骼、被 tween 推动的道具、粒子发射器都没有 velocity 属性，但对雾来说它们
##   一样在"推空气"。所以默认用**位置差分**（对任何 Node3D 都成立），若节点是
##   CharacterBody3D 则优先用它的 velocity（更精确，不受帧率抖动影响）。
func _update_interactors(delta: float) -> void:
	if delta <= 0.0:
		return
	_interactor_timer -= delta
	if _interactor_timer <= 0.0:
		_interactor_timer = interactor_scan_interval
		_scan_interactors()
	if _interactors.is_empty() and _characters.is_empty():
		return

	for node in _interactors:
		if not is_instance_valid(node):
			continue
		var velocity := _node_velocity(node, delta)
		if velocity.length() < 0.05:
			continue                   # 静止的物体不该持续搅动，避免白白吃掉源配额
		# 允许物体自带覆盖参数（FogInteractor 就提供这几个属性）
		var radius := interactor_radius
		var carve := interactor_carve
		if node.get("fog_interactor_radius") != null:
			radius = float(node.get("fog_interactor_radius"))
		if node.get("fog_interactor_carve") != null:
			carve = float(node.get("fog_interactor_carve"))
		# ★ 显式组件可以要"绕身涡流"：0 = 不转（**逐字等于旧行为**），正负 = 两个旋转方向。
		#   组件给的是 m/s，这里换算成求解器的"域单位/秒"。
		var spin := 0.0
		if node.get("fog_interactor_spin_mps") != null:
			spin = float(node.get("fog_interactor_spin_mps")) \
					/ maxf(minf(domain_size.x, domain_size.y), 0.001)
		# ★ 用**沿轴两段球**近似胶囊：交互体多半是竖直的角色/柱体，单球会在高度上失真。
		#   每段都同时做三件事（这就是"物体排开介质"的最小实现）：
		#     ① 挖洞（carve 负浓度）② 径向排开（radial，等价 OutwardVelocityMult）
		#     ③ 沿运动方向拖拽（target_velocity = 物体速度）
		#   外加可选的 ④ 绕心切向（spin，见 shader 的 splat_swirl）：这是"涡流环绕"。
		var half_step := maxf(box_height * 0.18, 0.8)
		var radial := (velocity * float(interactor_velocity_scale)).length() * 0.9 + 0.6
		var radial_domain := radial / maxf(minf(domain_size.x, domain_size.y), 0.001)
		var drag := Vector2(
			velocity.x * float(interactor_velocity_scale) / maxf(domain_size.x, 0.001),
			velocity.z * float(interactor_velocity_scale) / maxf(domain_size.y, 0.001))
		for offset in [-half_step, half_step]:
			# ★ 源的世界高度 = base_height + 带内 1/4 处 + 胶囊两段偏移：
			#   雾带抬高后，交互也必须跟着抬，否则"挖洞"挖在空气里。
			add_source(node.global_position + Vector3(0.0, base_height + box_height * 0.25 + offset, 0.0),
					radius, carve, velocity * float(interactor_velocity_scale),
					drag, radial_domain, spin)

	_stir_characters(delta)


## 角色涡流：把"正在移动的角色"变成绕身涡流源（这也是本项目角色的默认效果）。
## ★ 与交互体**同一套注入**，只是半径/挖雾/切向速度用 character_* 那几个参数，
##   而且挂过 FogInteractor 的角色会被跳过（显式组件优先，避免双份注入）。
func _stir_characters(delta: float) -> void:
	if not character_stir_enabled or _characters.is_empty():
		_hide_vortex_visual()
		return
	var stirred := false
	for node in _characters:
		if not is_instance_valid(node):
			continue
		if _handled_by_interactor(node):
			continue
		var velocity := _node_velocity(node, delta)
		var speed_mps := velocity.length()
		if speed_mps < 0.05:
			continue                   # 站着不动 ⇒ 不注入（旧观感不变）
		# ★ 涡流可视化层：与浓度注入无关，只看"角色在不在动"（见 vortex_visual_* 的说明）
		_update_vortex_visual(node, speed_mps)
		stirred = true
		var reference := maxf(character_swirl_ref_speed, 0.1)
		var speed_factor := clampf(speed_mps / reference, 0.25, 1.6)
		var radius := character_swirl_radius_m
		var carve := character_carve
		# m/s → 域单位/秒（与 add_source 的 target_velocity_domain 同一约定）
		var spin := character_swirl_mps * speed_factor \
				/ maxf(minf(domain_size.x, domain_size.y), 0.001)
		if node.get("fog_interactor_radius") != null:
			radius = float(node.get("fog_interactor_radius"))
		if node.get("fog_interactor_carve") != null:
			carve = float(node.get("fog_interactor_carve"))
		if node.get("fog_interactor_spin_mps") != null:
			spin = float(node.get("fog_interactor_spin_mps")) * speed_factor \
					/ maxf(minf(domain_size.x, domain_size.y), 0.001)
		var radial := speed_mps * 0.9 + 0.6
		var radial_domain := radial / maxf(minf(domain_size.x, domain_size.y), 0.001)
		# 径向排开（把雾挤开）+ 切向环流（绕身卷起）+ 挖雾：一个高斯源全做完
		add_source(node.global_position, radius, carve,
				Vector3.ZERO, Vector2.ZERO, radial_domain, spin)
	if not stirred:
		_hide_vortex_visual()


## 没有一个角色在动 ⇒ 涡流层收起（透明 = 不花任何代价）
func _hide_vortex_visual() -> void:
	if _vortex_visual != null and _vortex_visual.visible:
		_vortex_visual.visible = false


## 把 add_source() 攒下的源转成求解器的高斯源（世界坐标 -> 域坐标）。
func _apply_pending_sources() -> void:
	if _source_queue.is_empty():
		return
	var center := solver.domain_center()
	for source in _source_queue:
		var world: Vector3 = source["position"]
		var radius_m: float = source["radius"]
		var density_rate: float = source["density"]
		var velocity: Vector3 = source["velocity"]
		var local := world - center
		var uv := Vector2(
			clampf(local.x / maxf(domain_size.x, 0.001) + 0.5, 0.0, 1.0),
			clampf(local.z / maxf(domain_size.y, 0.001) + 0.5, 0.0, 1.0)
		)
		# 域半径 = 米 / 域尺寸（u、v 方向各自换算，非正方形域也不会变形）
		var radius_uv := radius_m / maxf(minf(domain_size.x, domain_size.y), 0.001)
		# 目标速度：显式给了就用显式的，否则由 velocity_world（m/s）换算
		var target: Vector2 = source["target"]
		if target == Vector2.ZERO:
			target = Vector2(
				velocity.x / maxf(domain_size.x, 0.001),
				velocity.z / maxf(domain_size.y, 0.001)
			)
		solver.add_splat(uv, radius_uv, target, source_velocity_rate, density_rate,
				float(source["radial"]), float(source["swirl"]))
	_source_queue.clear()


func _apply_weather() -> void:
	if _weather != null and auto_weather and not _has_wind_override:
		var wind_dir: Vector2 = _weather.get("wind_dir")
		var wind_amount: float = float(_weather.get("wind"))
		var speed := wind_amount * wind_speed_mps
		_wind_target = Vector2(
			wind_dir.x * speed / maxf(domain_size.x, 0.001),
			wind_dir.y * speed / maxf(domain_size.y, 0.001)
		)
	elif _has_wind_override:
		_wind_target = _wind_override
	else:
		_wind_target = Vector2.ZERO
	# ★ 风系数在这里**统一**缩放：下游（求解器风场、细节流动、噪声拖拽）都吃它，
	#   调小它就整体变稳，不需要分别去调三个地方。
	_wind_target *= wind_scale
	solver.set_wind(_wind_target)

	if _particles != null:
		_particles.emitting = particles_enabled and particle_count > 0 and enabled


## 求解器侧参数的**每帧同步**。
## ★ 为什么必须每帧：这些值原先只在建场/rebuild 时写进 solver，于是面板上拖
##   `涡量约束` / `速度耗散` 当场没有任何反应（要手动点"重建"才生效）——
##   表现就是"设置后游戏里不生效"。开销只是几个赋值，可以忽略。
func _apply_solver_params() -> void:
	if solver == null:
		return
	solver.velocity_dissipation = velocity_dissipation
	solver.vorticity_strength = vorticity_strength
	# ★ 浓度增益：转发给求解器的画笔吸引增益 base_gain。
	#   （此前 density_gain 在 FogField 里**声明了却从未被读取**，是个死旋钮。）
	solver.set_base_gain(density_gain)
	# ★ 底图地板强度：0 时角色/法术的挖雾与涡流才压得下**可见**浓度（见该属性的说明）
	solver.set_base_floor(composite_base_floor)


## 粒子侧的每帧参数（受光配色之外的运动/外观）。
## ★ 单独成一个方法：纯粒子模式（没有体积盒）也必须走它，否则风系数、
##   强度、噪声拖拽这些在"关掉盒子"后就全都不生效（这是本项目踩过两次的坑）。
func _apply_particle_params() -> void:
	if _particles != null:
		# 数量/尺寸/强度：这三个必须在**每帧**同步，否则面板改了在编辑器里看不出变化
		var wanted := maxi(particle_count, 1)
		if _particles.amount != wanted:
			_particles.amount = wanted
		var quad := _particles.draw_pass_1 as QuadMesh
		if quad != null:
			quad.size = Vector2(particle_size, particle_size)
		_particles.emitting = particles_enabled and particle_count > 0
	if _particles_material != null:
		_particles_material.set_shader_parameter("strength", particle_strength * maxf(fog_opacity, 0.0))
		# 噪声拖拽强度 = 基础值 × 风系数：风越大拖拽越明显，但要能被风系数整体压住
		_particles_material.set_shader_parameter("flow_warp", particle_flow_warp * wind_scale)
		# 颜色模型（拆分后）：底色与受光各管一半，面板上这两个滑块就是"烟多黑/亮部多亮"
		_particles_material.set_shader_parameter("ambient_grey", particle_ambient)
		_particles_material.set_shader_parameter("light_add", particle_light_add)
		# 形态：顺风拉伸（丝状流动感）与边缘侵蚀（相邻粒子连成一片）
		_particles_material.set_shader_parameter("stretch_along", particle_stretch)
		_particles_material.set_shader_parameter("erosion", particle_erosion)
		# 受光也要能实时调（否则面板上的"粒子受光/光源散射"看起来同样"没反应"）
		_particles_material.set_shader_parameter("emissive_clamp", emissive_clamp_color())
	if _particles != null:
		var process_material := _particles.process_material as ShaderMaterial
		if process_material != null:
			# 跟风速率是**响应速度**，不乘风系数（避免二次缩放）；调小它能显著减少抖动
			process_material.set_shader_parameter("flow_gain", particle_flow_follow)
			# ★ 流场强度：0 = 粒子完全无视流体速度场（"风都关 0 了还在飞快抖动"的根治开关）
			process_material.set_shader_parameter("flow_scale", particle_flow_scale)
			# ★ 物理速度上限（米/秒）：0 = 不限。这是"风关了雾还在飞快抖"的刹车
			process_material.set_shader_parameter("flow_speed_cap_mps", particle_flow_speed_cap)
			# 点光衰减指数：红光"局部化"的总开关
			process_material.set_shader_parameter("light_falloff_power", particle_light_falloff)
			# ★ 编辑器预览没有求解器 ⇒ 用"合成风"，让风系数/风速在编辑器里可见地生效；
			#   运行期则用真实求解器风场（域单位/秒 -> 米/秒）。
			var wind_world := Vector2.ZERO
			if _editor_preview:
				wind_world = Vector2(1.0, 0.35).normalized() * (wind_speed_mps * wind_scale)
			else:
				wind_world = _wind_target * domain_size
			process_material.set_shader_parameter("synthetic_wind", wind_world)


## 自发光钳制色（面板可调时用；这里保持与着色器默认一致）
func emissive_clamp_color() -> Color:
	var strength := clampf(local_scatter_strength / 16.0, 0.0, 1.0)
	return Color(1.0, 0.92 - 0.2 * strength, 0.78 - 0.3 * strength)


func _apply_volume_params() -> void:
	# ★ 求解器参数每帧同步（否则面板上的涡量/耗散要等 rebuild 才生效）
	_apply_solver_params()
	_apply_particle_params()
	# ★ 涡流可视化层的**样式**也每帧同步：面板上改颜色/圈数/锐度要立刻看得到
	_apply_vortex_visual_params()
	if _volume_material == null:
		# 纯粒子模式：没有体积盒，但**光源/光束数据仍然要打包给粒子着色器**
		_apply_local_sources()
		return
	# ★ 不在场景树里（测试、编辑器早期调用）时不要碰 global_position / get_tree ——
	#   引擎会报 "Condition !is_inside_tree()" 与 "Parameter data.tree is null"。
	#   用自身的 position 兜底，参数照样能同步到材质。
	var center := Vector3(position.x, position.y + base_height, position.z)
	if is_inside_tree():
		center = Vector3(global_position.x, global_position.y + base_height, global_position.z)
	_volume_material.set_shader_parameter("domain_center", center)
	_volume_material.set_shader_parameter("domain_size", domain_size)
	_volume_material.set_shader_parameter("box_height", box_height)
	_volume_material.set_shader_parameter("march_steps", march_steps)
	_volume_material.set_shader_parameter("detail_strength", detail_strength)
	_volume_material.set_shader_parameter("detail_scale", detail_scale)
	_volume_material.set_shader_parameter("scatter_strength", scatter_strength)
	_volume_material.set_shader_parameter("absorption", light_absorption)
	_volume_material.set_shader_parameter("light_steps", light_steps)
	_volume_material.set_shader_parameter("cavity_threshold", cavity_threshold)
	_volume_material.set_shader_parameter("cavity_softness", cavity_softness)
	_volume_material.set_shader_parameter("local_scatter_strength", local_scatter_strength)
	# ★ 下面这四项原先**只在 _create_volume() 里写一次**，建场之后再改属性永远传不到材质——
	#   用户实测："亮部/暗部颜色在编辑器里改了没有实时预览"。凡是**能被面板/脚本调到**的
	#   外观参数，都必须在每帧路径里重传。判据：能被 UI 改的，就得每帧写。
	_volume_material.set_shader_parameter("mist_color_lit", mist_color_lit)
	_volume_material.set_shader_parameter("mist_color_shadow", mist_color_shadow)
	_volume_material.set_shader_parameter("height_power", height_power)
	_volume_material.set_shader_parameter("opacity", fog_opacity)
	_apply_local_sources()
	# 三维细节跟着风漂移（把域单位/秒换算回世界米/秒，再乘一个小系数）：
	# 这样"雾被吹走"和"细节在翻涌"是同一个方向，观感上才是一体的。
	_volume_material.set_shader_parameter("detail_flow", Vector2(
		_wind_target.x * domain_size.x, _wind_target.y * domain_size.y) * 0.35)
	# 太阳（体积光照的方向与颜色）。不在树里时 get_tree() 不可用（见上面的说明），跳过。
	if is_inside_tree():
		var sun := _find_sun()
		if sun != null:
			_volume_material.set_shader_parameter("sun_direction", -sun.global_basis.z)
			_volume_material.set_shader_parameter(
				"sun_color", sun.light_color * clampf(sun.light_energy, 0.0, 8.0))
	if _particles_material != null:
		_particles_material.set_shader_parameter("strength", particle_strength * maxf(fog_opacity, 0.0))
	# ★ 蓝噪声抖动：掩膜只生成一次；生成失败（null）时强制强度 0 = 完全旧行为。
	if march_jitter_strength > 0.0:
		if _jitter_texture == null:
			_jitter_texture = FogBlueNoise.build()
		if _jitter_texture == null:
			_volume_material.set_shader_parameter("jitter_strength", 0.0)
		else:
			_jitter_frame += 1
			_volume_material.set_shader_parameter("jitter_tex", _jitter_texture)
			_volume_material.set_shader_parameter("jitter_strength", march_jitter_strength)
			_volume_material.set_shader_parameter("jitter_frame_offset",
					FogBlueNoise.frame_offset(_jitter_frame))
	else:
		_volume_material.set_shader_parameter("jitter_strength", 0.0)
	# ★ B / D / C 三项边缘融合（0 = 旧行为，互不影响）：
	#   B 深度软融合：雾在距物体表面 edge_soft_m 米内淡出（治交界硬边）
	#   D 按步长预滤波：滤掉高于采样率的成分（治内部折痕，确定性、无噪声）
	#   C 视角相关羽化：掠射角下加宽域边缘淡出（治域边界硬边）
	_volume_material.set_shader_parameter("edge_soft_m", edge_soft_m)
	_volume_material.set_shader_parameter("march_prefilter", march_prefilter)
	_volume_material.set_shader_parameter("view_feather", view_feather)
	# ★ 墨迹式图案（随机撒墨滴 + 每滴各自对折 + 随时间游走）；ink_amount = 0 时着色器整块跳过
	_volume_material.set_shader_parameter("ink_amount", ink_amount)
	_volume_material.set_shader_parameter("ink_spacing", ink_spacing)
	_volume_material.set_shader_parameter("ink_grow", ink_grow)
	_volume_material.set_shader_parameter("ink_rate", ink_rate)
	_volume_material.set_shader_parameter("ink_fold", ink_fold)
	# ★ 金字塔式边缘（顶层最透、边缘最宽；逐级向下变实变窄）—— 治水平分层感
	_volume_material.set_shader_parameter("pyramid_edge", pyramid_edge)


# =========================================================
# 对外接口
# =========================================================

## 世界坐标处加一个雾源。半径与速度都用**米 / 米每秒**，内部换算成域单位。
## density_rate 是"每秒增加的浓度"（0.5 = 半秒把一格灌满，0 = 只推速度不投雾）。
## ★ **允许负值**：负值 = 把雾推开（角色穿过雾时挖出一个洞），浓度会被 clamp 在 0..1。
## velocity_world 是"这片区域的目标风速"（m/s，只用 XZ 分量），不是冲量。
## radial_speed 是**径向排开速度**（域单位/秒，0 = 关闭）：>0 时该区域的速度被推向
##   "离开源中心"的方向 —— 物体挤开介质（FluidNinja 的 OutwardVelocityMult）。
## swirl_speed 是**绕心切向速度**（域单位/秒，0 = 关闭）：>0 / <0 为两个旋转方向。
##   它给该区域叠加一个绕源中心的切向目标速度 ⇒ 浓度场被卷成螺旋（"涡流环绕"）。
##   ★ 想要"角色跑过、雾绕着转"用这个；只想要"把雾推开"用 radial_speed。
## 若希望源持续起效（篝火/角色），请**每帧**调用本函数（它只影响当帧）。
func add_source(world_position: Vector3, radius_m: float,
		density_rate: float, velocity_world: Vector3 = Vector3.ZERO,
		target_velocity_domain: Vector2 = Vector2.ZERO,
		radial_speed: float = 0.0, swirl_speed: float = 0.0) -> void:
	_source_queue.append({
		"position": world_position,
		"radius": maxf(radius_m, 0.01),
		"density": clampf(density_rate, -1.0, 1.0),
		"velocity": velocity_world,
		"target": target_velocity_domain,
		"radial": maxf(radial_speed, 0.0),
		"swirl": swirl_speed,
	})


## 只投一个**涡流**（绕心环流）的便捷接口：不挖雾、不排开，纯旋转。
## radius_m 是涡流半径（米），spin_mps 是切向风速（m/s，正负 = 旋转方向）。
## 例：`field.add_vortex(pos, 4.0, 8.0)` —— 在 pos 周围卷起一个半径 4 米、切向 8 m/s 的涡。
func add_vortex(world_position: Vector3, radius_m: float = 3.0,
		spin_mps: float = 8.0, density_rate: float = 0.0) -> void:
	var spin := spin_mps / maxf(minf(domain_size.x, domain_size.y), 0.001)
	add_source(world_position, radius_m, density_rate,
			Vector3.ZERO, Vector2.ZERO, 0.0, spin)


## 直接指定风（m/s，世界 XZ）。调用后 auto_weather 的风向不再覆盖它（雾场被"接管"）。
func set_wind_mps(velocity_mps: Vector2) -> void:
	_has_wind_override = true
	_wind_override = Vector2(
		velocity_mps.x / maxf(domain_size.x, 0.001),
		velocity_mps.y / maxf(domain_size.y, 0.001)
	)


## 交还给天气系统控制风。
func clear_wind_override() -> void:
	_has_wind_override = false


## 直接指定整体不透明度（覆盖天气推导值）。传负数恢复由天气/导出值决定。
func set_fog_opacity(value: float) -> void:
	_opacity_override = value
	_apply_opacity()


func _apply_opacity() -> void:
	if _volume_material == null:
		return
	var opacity := _opacity_override
	if opacity < 0.0:
		opacity = _base_opacity
		if _weather != null and auto_weather:
			var fog_amount := clampf(float(_weather.get("fog")), 0.0, 1.0)
			# 天气的 fog 在 Clear 下是 0（死区 0..0.18），所以再叠一个 idle 底雾，
			# 保证"晴天也有一层薄地雾"而不是整片消失。
			opacity = _base_opacity * (idle_opacity + (1.0 - idle_opacity) * minf(1.0, fog_amount * 3.0))
	_volume_material.set_shader_parameter("opacity", maxf(opacity, 0.0))


## 画笔底图：传 null 会清掉底图（求解器改用全 0 兜底）。
## ★ 这个方法**编辑器里也必须能跑**（笔刷插件每刷完一笔就调它）：
##   运行期把图交给求解器当"吸引子"；编辑器里（solver == null）自己包一张
##   ImageTexture 直接喂给体积雾材质，于是"刷完立刻看见雾的形状"。
func set_brush_field(field: FogBrushField) -> void:
	brush_field = field

	# ---- ① 先把底图取成 Image（两条来源：内存网格优先，其次 PNG 资产）----
	var image: Image = null
	if field != null:
		if not field.is_empty_source():
			image = field.to_image()
		elif not field.image_path.is_empty() and FileAccess.file_exists(field.image_path):
			image = Image.load_from_file(ProjectSettings.globalize_path(field.image_path))

	# ---- ② 运行期：交给求解器（它会自己上传成纹理并刷新材质）----
	if solver != null:
		solver.set_base_density_image(image)
		brush_texture = solver.base_texture()
		solver.refresh_materials()
		return

	# ---- ③ 编辑器预览 / 无求解器：自己维护纹理并接到体积雾上 ----
	if _volume_material == null:
		return
	if image != null:
		brush_texture = ImageTexture.create_from_image(image)
		_volume_material.set_shader_parameter("density_tex", brush_texture)
		_volume_material.set_shader_parameter("density_gain", density_gain)
	else:
		brush_texture = null
		# ★ 还没刷过任何东西时**不能**让 sampler2D 落在默认纹理上：未赋值的 sampler 在
		#   Godot 里会绑到一张白图，于是"空底图"会被渲染成一整块实心雾（编辑器里看着
		#   像 bug）。把浓度增益压到 0，alpha 恒为 0，预览就是干净的空场景。
		_volume_material.set_shader_parameter("density_gain", 0.0)


## 编辑期/运行期改过画笔后调用，把最新底图推给求解器（编辑器里是推给预览）。
func refresh_brush_texture() -> void:
	set_brush_field(brush_field)


## 笔刷"吹风"用：把一次落笔当成一个速度源推给求解器。
## ★ 编辑器里 solver 为 null 时**静默跳过**（插件勾了"落笔同时吹动风场"也不会报错）。
## uv 是域坐标，radius_uv 是域比例，target_velocity 是域单位/秒。
func add_brush_velocity(uv: Vector2, radius_uv: float,
		target_velocity: Vector2, velocity_rate: float = 3.0,
		density_rate: float = 0.35) -> void:
	if solver == null:
		return
	solver.add_splat(uv, radius_uv, target_velocity, velocity_rate, density_rate)


## 清空模拟出来的雾（画笔底图保留）。
func clear_simulated() -> void:
	if solver != null:
		solver.clear_density()


## 按画质档位调参。tier 取 QualityTiers.Tier（0=低 1=中 2=高 3=极高）。
func apply_quality(tier: int) -> void:
	var clamped := clampi(tier, 0, 3)
	var presets := [
		{"resolution": 64, "jacobi": 4, "particles": 120, "steps": 3, "light_steps": 2},
		{"resolution": 96, "jacobi": 6, "particles": 240, "steps": 4, "light_steps": 3},
		{"resolution": 128, "jacobi": 8, "particles": 400, "steps": 6, "light_steps": 4},
		{"resolution": 160, "jacobi": 10, "particles": 600, "steps": 8, "light_steps": 6},
	]
	var preset: Dictionary = presets[clamped]
	resolution = int(preset["resolution"])
	jacobi_passes = int(preset["jacobi"])
	particle_count = int(preset["particles"])
	march_steps = int(preset["steps"])
	light_steps = int(preset["light_steps"])
	rebuild()


## 应用当前配置（分辨率/迭代次数/物理参数）——改了导出属性之后调用。
func rebuild() -> void:
	if solver == null:
		return
	solver.resolution = resolution
	solver.jacobi_passes = jacobi_passes
	solver.domain_size = domain_size
	solver.box_height = box_height
	solver.base_height = base_height
	solver.velocity_dissipation = velocity_dissipation
	solver.density_dissipation = density_dissipation
	solver.vorticity_strength = vorticity_strength
	solver.base_relax = base_relax
	solver.setup()
	set_brush_field(brush_field)
	_bind_density_texture()
	_bind_flow_texture()
	_apply_solver_settings()
	if _particles != null:
		_particles.amount = maxi(particle_count, 1)
	if _volume_material != null:
		_volume_material.set_shader_parameter("march_steps", march_steps)
		_volume_material.set_shader_parameter("detail_strength", detail_strength)
		_volume_material.set_shader_parameter("detail_scale", detail_scale)
		_volume_material.set_shader_parameter("scatter_strength", scatter_strength)
		_volume_material.set_shader_parameter("absorption", light_absorption)
		_volume_material.set_shader_parameter("light_steps", light_steps)
	_apply_opacity()


func _apply_solver_settings() -> void:
	if solver == null:
		return
	solver.velocity_dissipation = velocity_dissipation
	solver.density_dissipation = density_dissipation
	solver.vorticity_strength = vorticity_strength
	solver.base_relax = base_relax
	solver.enabled = enabled


## 开关：关掉时求解器停止渲染、粒子停止发射（不花 GPU）。
var enabled: bool = true:
	set(value):
		enabled = value
		if solver != null:
			solver.enabled = value
		if _volume != null:
			_volume.visible = value
		if _particles != null:
			_particles.emitting = value and particles_enabled
		if is_inside_tree():
			_apply_opacity()


func _bind_weather() -> void:
	_weather = get_node_or_null("/root/Weather")
	_apply_opacity()


func _apply_project_quality() -> void:
	var quality := get_node_or_null("/root/Quality")
	if quality == null:
		return
	var tier: int = int(quality.get("tier")) if quality.get("tier") != null else 2
	apply_quality(tier)


# =========================================================
# 自检/调试
# =========================================================

## 底层的雾浓度场纹理。
func density_texture() -> Texture2D:
	return solver.density_texture() if solver != null else null


## 底层的速度场纹理。
func velocity_texture() -> Texture2D:
	return solver.velocity_texture() if solver != null else null


## 体积雾节点（自检用）。
func volume_node() -> MeshInstance3D:
	return _volume


## 粒子节点（自检用）。
func particles_node() -> GPUParticles3D:
	return _particles

@tool
class_name ButterflyTuning
extends Resource
## 蝴蝶行为/外观的**集中调参表**（可选资源，`ButterflySwarm.tuning` 留空则用脚本内置默认值）。
##
## ★ 为什么做成 Resource 而不是散落的 @export：
##   ① 可以存成 .tres 复用（同一套"夏日午后"参数发给几个区域的蝴蝶群）
##   ② 参数一次性在检查器里成组出现，不用在群组节点上翻 30 个属性
##   ③ 测试可以 new() 一个改几个值，不影响项目里已存好的 .tres
##
## ★ 读取方一律走 `get(key)`（Butterfly 里是 `_num("speed_max", 2.2)` 这种），
##   所以**漏写/改名不会崩，只会静默回落到默认值** —— 加字段时记得同步 Butterfly._defaults()。

## 单只蝴蝶的翼展（米）。实测素材里闪蝶翼展约 0.10~0.15 m，
## 但卡通沙盒里 0.12 m 太小看不见，默认放到 0.22 m（约真实 1.5 倍，卡通比例）。
@export var size_m := 0.22
## 最大水平飞行速度（米/秒）。真实蝴蝶 1~2 m/s；沙盒里给到 2.2 才有"看得见在飞"的动感。
@export var speed_max := 2.2
## 加速度上限（米/秒²）：越大越"神经质"，越小越飘。1.8 折中（对应约 1 秒到全速）。
@export var accel := 1.8
## 扑翼频率（次/秒）。真实蝴蝶 5~12 Hz；8.5 在视觉上既不过曝也不呆。
@export var flap_hz := 8.5
## 扑翼频率的群内随机抖动（±Hz）：不同蝴蝶不同步，整群才不像"机器人方阵"。
@export var flap_hz_jitter := 2.5
## 二面角下限（度）：翅几乎摊平的那一瞬（下扑到底）。
@export var dihedral_min := 6.0
## 二面角上限（度）：翅抬到最高的那一瞬（上扑到顶）。90 = 完全合拢成竖 V。
@export var dihedral_max := 72.0
## ★ 立体感：翅膀弧度（二面角沿翼展的增长系数）。0 = 平板；0.3 = 翅尖比根部多抬 30%。
##   曲面才有连续明暗渐变，这是"体积感"的第一来源。
@export var wing_camber := 0.30
## ★ 立体感：翅膀厚度（占翼展比例）。0 = 纸片；0.035 ≈ 翼展的 3.5%。
@export var wing_thickness := 0.035
## 翅面沿头尾方向的弯拱（模型单位，小值）。
@export var wing_bend_y := 0.0
## ★ 立体感：身体粗细倍率（1.0 = 默认，约翼展的 12%；0 = 不画身体）。
@export var body_scale := 1.0
## 最小正对度（0~1）：侧对镜头时自动把翅面转向镜头，避免细成一条线。0 = 关闭。
@export var edge_min_facing := 0.25
## 面向镜头自适应允许的最大转角（度）。
@export var edge_min_deg := 26.0
## 厚度侧壁/边缘环的压暗强度（廉价 AO）。
@export var rim_dark := 0.55
## 无风时蝴蝶自身的"漫游"方向抖动强度（米/秒² 量级）。
## 调大 -> 飞得东倒西歪、更像喝醉；调小 -> 走直线。
@export var wander_jitter := 1.6
## 漫游方向的抖动频率（次/秒）：越高越像被高频噪声推，越低越像"临时改主意"。
@export var wander_rate := 0.6
## 同群分离半径（米）：两只靠得比它近就互相推开，避免叠在一起。
@export var separation_m := 0.35
## 分离力强度（无量纲，乘在 1/距离 权重上）。
@export var separation_weight := 1.8
## 风的拖曳系数：wind_drag=1 表示"完全跟着风走"，0 表示"无视风"。0.35 是"被吹偏但还有主见"。
@export var wind_drag := 0.35
## 阵风对飞行速度的额外乘子：风速越大蝴蝶越难控（0 = 不额外影响）。
@export var gust_penalty := 0.45
## 趋花/趋水/趋伴的感知半径（米）。超出它就不会主动飞过去。
@export var seek_range_m := 12.0
## 能量消耗速率（每秒）。能量 0 -> 去休息（BASK）。
@export var energy_drain := 0.035
## 休息时的回能速率（每秒）。回到 rest_energy 的 1.0 倍就重新起飞。
@export var energy_gain := 0.16
## 低于这个能量值就落地停歇（BASK）。
@export var rest_energy := 0.25
## 风速超过这个值（0..1.5 量级的 Weather.wind）蝴蝶就去躲雨/避风（SHELTER）。
@export var shelter_wind := 0.75
## 雨量超过这个值（0..1 量级的 Weather.rain）蝴蝶就找遮蔽（SHELTER）。
@export var shelter_rain := 0.30
## 飞行时翅膀的虹彩强度（unity 自发光掠射项，见 butterfly_wings.gdshader 的 iridescence）。
## ★ 默认压得很低（0.16）：调高会把蝴蝶染成紫红、盖掉素材本身的蓝（真机实测过）。
@export var iridescence := 0.16
## 逆光透光度（翅膀被光穿过时的透亮感，0 = 完全不透）。
@export var backlight := 0.15
## 整体染色（会乘到纹理上）。默认白 = 不改色；
## 阴雨天由 ButterflySwarm 按天气自动压一点蓝灰，这里不用手填。
@export var tint := Color(1, 1, 1, 1)
## 单个蝴蝶的透明度上限（1 = 不透明）。做"远处淡出"或"群体半透"时调。
@export var alpha := 1.0
## 贴地抬升（米）：蝴蝶最低飞行高度（相对群组原点），防止钻到草皮/地形里。
@export var min_height_m := 0.35
## 地面/障碍感知距离（米）：前方这么近有东西就往上躲（只在 swarm.ground_avoid 打开时用）。
@export var avoid_distance_m := 1.2
## 到区域边界的"软回弹"起始距离（米）：进入这条带就开始往回拐，而不是撞墙式掉头。
@export var edge_margin_m := 0.8
## 身体随转弯的侧倾上限（度）。0 = 永远平飞（假）；35 有"压杆转弯"的感觉。
@export var bank_max_deg := 35.0
## 俯仰随上下运动的强度（米/秒 -> 度）。让"上升时头朝上"。
@export var pitch_per_speed := 8.0
## 弹性/颤抖：翅面 flutter 形变的幅度（0.05 = ±5% 翼展）。制作"薄翅在抖"的质感。
@export var flutter_amount := 0.05
## 生成时的高度抖动（米，相对区域中心）：避免所有蝴蝶都从同一水平面起飞。
@export var spawn_height_jitter := 0.6
## 是否参与同群分离（关掉可以看"叠在一起"的调试效果）。
@export var flocking := true
## 停歇/汲水时朝落脚点靠拢的速度（米/秒）。
## ★ 为什么是"限速靠拢"而不是直接插值过去：旧实现 `position.lerp(_perch, 0.25)` 每帧拉 25%，
##   一旦 `_perch` 是错的（默认原点），蝴蝶就会以 ~15 m/s **瞬移**回原点。
##   1.2 m/s 让"落地"看得见，也不会像被拽过去。
@export_range(0.1, 6.0, 0.1) var perch_speed := 1.2
## 落脚点离得超过这个距离（米）就**重新就近落脚**，而不是长途飞过去。
## 防的是"`_perch` 残留了上一片区域的坐标"这类情况。
@export_range(0.5, 20.0, 0.5) var perch_rearm_distance := 3.0
## 单帧位移上限的松紧系数（乘在 `speed_cap * delta` 上）。
## 1.0 = 严格不超过速度上限；默认 1.6 留出余量（边界推力/硬夹都需要一点空间），
## 只在真正异常时才咬合。调小更"硬"（更不可能瞬移，但极端情况下会拖慢正常飞行）。
@export_range(1.0, 4.0, 0.1) var max_step_factor := 1.6

# ==================== 移动生态学（Movement Ecology）====================
# ★ 这一组的依据是**蝴蝶运动的经典生态学模型**，不是拍脑袋的视觉参数：
#   ① Kareiva & Shigesada (1983) "Analyzing insect movement as a correlated random walk"
#      Oecologia 56:234-238 —— 蝴蝶的**方向相关随机游走（CRW）**：每一步的方向与上一步
#      高度相关（小转角占多数），只有很少几次大转角。这正是"蝴蝶不是直线飞"的数学解释。
#   ② Lévy flight（重尾步长）：长直飞行段与短促原地搜索交替出现。
#      实现上用 **Pareto 重尾**取步长；对应昆虫觅食的"分散-集中"双模态。
#   ③ 区域限制搜索（Area-Restricted Search, ARS）：一旦感知到资源（花/水/同伴），
#      就把"转角变小、步长变短、停留变久"——这就是蝴蝶在花丛里打转、离开花丛就直线飞的原因。
#   ④ 真实蝴蝶飞行速度实测 1~2 m/s、转角分布强烈偏向小角度，
#      所以下面的默认值都落在"看着像蝴蝶"的区间，而不是"像蜜蜂/像鸟"。
#
# 参考（模型出处，代码为本项目按论文自行实现，未复制任何外部源码）：
#   · Kareiva & Shigesada 1983, Oecologia 56:234-238
#   · Turchin 1998 "Quantitative Analysis of Movement"（CRW 与转角分布的标准处理）
#   · 综述与开源对照：https://github.com/conswang/WebGPU-Butterfly（仅参考其"蝴蝶飞行"的
#     视觉目标，未取其代码）、UH 2022 TOG《A Practical Model for Realistic Butterfly Flight
#     Simulation》（转向/扑翼耦合的视觉参考）

## 方向持续性（0~1）：**CRW 的核心参数**。
## 1.0 = 永远直线（就是"直飞"的病）；0 = 每帧随机方向（像无头苍蝇）。
## 实测取 0.72：小转角占多数、偶尔一次大转角 —— 轨迹是"一段直、忽然拐"，像真蝴蝶。
@export_range(0.0, 0.99, 0.01) var heading_persistence := 0.72
## 转角尺度（度）：CRW 里"小转角"的量级，越小越直。
## 配合 heading_persistence 决定"有多歪"。25° 是蝴蝶的典型值。
@export_range(1.0, 90.0, 1.0) var turn_scale_deg := 25.0
## 大转角概率（0~1）：CRW 的**重尾**部分 —— 每次决策有这么多概率来一次"猛拐"。
## 这就是"忽然换个方向飞"的来源；调到 0 会变成纯小转角缓弯（看着很假）。
@export_range(0.0, 0.5, 0.005) var turn_heavy_p := 0.06
## 重尾转角的尺度（度）：命中大转角时，转角在这个量级上分布。
@export_range(10.0, 180.0, 1.0) var turn_heavy_deg := 110.0
## Lévy 步长指数 α（1.0~3.0）。α≈1.5~2.0 是昆虫觅食的典型值：
## 越接近 1 越长直段（更"分散"），越大越像普通随机游走（更"黏"）。
@export_range(1.05, 3.0, 0.05) var levy_alpha := 1.6
## 一次"决策段"的时长（秒）：两次航向更新之间的间隔。
## 太短 -> 每帧都在抖（像噪声）；太长 -> 又变直飞。0.35~0.8 比较像蝴蝶。
@export_range(0.05, 3.0, 0.05) var step_time_s := 0.45
## 资源感知半径（米）：这个范围内有花/水/同伴 -> 进入 ARS（打转搜索）。
## ★ 这就是"环境互动"里的**感知**那一半：蝴蝶会真的因为附近有资源而改变飞行模式。
@export_range(0.2, 20.0, 0.1) var ars_radius_m := 3.0
## 进入 ARS 后的转角尺度（度）：明显比 turn_scale_deg 大 -> 原地打转。
@export_range(1.0, 120.0, 1.0) var ars_turn_scale_deg := 55.0
## 进入 ARS 后的速度上限乘子（0~1）：在花丛里飞得更慢更黏。
@export_range(0.1, 1.0, 0.01) var ars_speed_scale := 0.55
## 是否启用 ARS（区域限制搜索）。关掉 = 只按 CRW/Lévy 飞，不理会附近有没有资源。
@export var area_restricted_search := true
## ★ 资源点**轮换周期**（秒）。每隔这么久重新挑一个资源点。
## 为什么必须有它（用户实测反馈："蝴蝶出现聚集行为后，会反复在两点之间散开再重聚"）：
##   旧实现挑完资源点后**再也不更新**（计时器只设不递减），整群永远被同一个坐标吸引。
@export_range(1.0, 60.0, 0.5) var ars_rotate_s := 8.0
## ★ 新资源点必须离上一个至少这么远（米），防止"抽来抽去还在原地"。
@export_range(0.0, 20.0, 0.5) var ars_min_move_m := 3.0
## ★ 参与度（0~1）：多少比例的蝴蝶响应资源点。全部响应会让整群**同步**收拢/散开。
@export_range(0.0, 1.0, 0.01) var ars_participation := 0.55
## ★ 趋花时避开上一处的半径（米）：下次挑目标会跳过离上次这么近的候选。
@export_range(0.0, 20.0, 0.5) var seek_repeat_avoid_m := 3.0
## 侧向摆动幅度（米/秒²）：给直线段叠一层左右摆（真实蝴蝶在直飞段也在小幅左右晃）。
@export_range(0.0, 3.0, 0.05) var lateral_weave := 0.55
## 侧向摆动的频率（Hz）：太快像蜂鸟、太慢看不出来。
@export_range(0.2, 4.0, 0.05) var lateral_weave_hz := 1.1

# ==================== 与草（SimpleGrassTextured）的交互 ====================
## 蝴蝶把草压弯的影响半径（米）。只有"贴得够低"的蝴蝶才会压草，所以这个值不大。
@export_range(0.05, 2.0, 0.05) var grass_bend_radius := 0.42
## 压草强度（0~3）：0 = 完全不互动；1.0 是"轻轻压一下"。
@export_range(0.0, 3.0, 0.05) var grass_bend_strength := 1.0
## 蝴蝶要低于"区域草层高度"多少米以内才压草（米）。
## 为什么需要它：蝴蝶在 3 米高空飞时不该把草压弯 —— 只有**贴草飞/落草**才压。
## ★ 实测定的 1.15：蝴蝶的常规飞行高度是"区域底 + min_height_m(0.35) + 巡飞带"，
##   实测中心约 **区域底 + 1.0 m**。所以这个带子必须**覆盖到常规飞行高度**，
##   否则 press 恒为 0、交互完全看不见（第一版设 0.6 就踩了这个坑：蝴蝶在 1.0 m，
##   带宽只到 0.6 m，测出来 press 全是 0）。带子越大压草越"远"，1.15 是够到常规高度又不牵连高空的下限。
@export_range(0.05, 3.0, 0.05) var grass_bend_height := 1.15
## 每帧最多向草系统推送几只蝴蝶（取离地最低的几只）。
## 为什么限制：草的着色器里每只蝴蝶要算一次距离，太多会拖累整片草；
##   而且远处蝴蝶压草本来也看不见。2 只足够表现"有东西在草里动"。
@export_range(0, 4, 1) var grass_bend_slots := 2

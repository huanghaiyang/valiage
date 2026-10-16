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

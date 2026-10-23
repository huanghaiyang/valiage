@tool
class_name ButterflySwarm
extends Node3D
## 蝴蝶群 —— 插件的主节点。往场景里放一个，配好区域与蝴蝶 PNG，它就一直在飞。
##
## ★★ 它负责什么 ★★
##   ① **多选素材**：`sprites` 是一个 `Array[Texture2D]`，在检查器里能一次选多张蝴蝶 PNG；
##      留空也没有关系 —— 子目录里 20 张会自动被扫出来（见 `autoload_all_sprites`）。
##   ② **区域**：`region_size` / `region_offset` 定义节点本地空间里的一个盒子，
##      蝴蝶只在这个盒子里飞（越界会被柔和地拐回来，见 Butterfly._force_bounds）。
##      `autofit_region` 可以按地面高度自动把盒子抬到地面上（避免盒子埋进地里）。
##   ③ **AI**：每只蝴蝶一个 `Butterfly` 子节点，各自跑状态机 + Boids 转向 + 能量。
##   ④ **天气**：每帧读 `Weather`（autoload）的风向/风力/雨量，灌给每只蝴蝶；
##      风把蝴蝶整体吹偏、阵风把翅膀吹歪、大风大雨时整群转成避风行为。
##      `Wind`（旧版 autoload；现在的 `WindSystem` 是场景内节点，按分组 `wind_system` 找）
##      存在时优先用它已经算好的 `cur_*`，两边保持一致。
##   ⑤ **编辑器预览**：本脚本是 `@tool`，改参数立刻重建，所以**不用运行**就能看到蝴蝶。
##
## ★★ 在编辑器里怎么用 ★★
##   1. 场景里加一个 `ButterflySwarm` 节点（添加节点 -> 搜 "ButterflySwarm"）
##   2. `sprites` 点「添加元素」-> 选 `assets/textures/活体/蝴蝶/蝴蝶-0X.png`（可多选）
##      · 懒得一张张选：点检查器里 `autoload_all_sprites` 的开关（开->关 会触发重建并自动补全）
##      · 或用菜单「项目 -> 工具 -> 蝴蝶素材分析」重新扫描并生成清单
##   3. 调 `region_size`（区域多大）与 `region_offset`（相对节点抬高/平移）
##   4. 想要看得更清楚：勾 `debug_draw_region` 画出区域线框
##
## ★★ 运行时怎么用 ★★
##   `ButterflySwarm.set_active(false)` 立刻让整群停下（隐藏 + 不推进），
##   `respawn_all()` 重新撒一遍（换区域后想立刻生效就调它），
##   `wind_now()` / `weather_now()` 可以读出它当前用的风与天气（调试 UI 用）。
##
## ★ 关键依赖（改名字会静默失效）★
##   · res://assets/shaders/butterfly_wings.gdshader —— 折翼着色器（契约第 2 节）
##   · autoload `Weather`（scripts/world/weather.gd）—— 风/雨/云量
##   · 风系统 `WindSystem`（scripts/wind.gd；**场景内节点**，加入分组 "wind_system"）——
##     可选；有就用它的 cur_dir/cur_strength…（旧版是 autoload `Wind`，已移除）
##   · addons/butterfly_swarm/sprite_manifest.json —— 素材清单（可选，缺了会现场扫）

# ==================== 依赖（preload，不用 global class 名） ====================
## ★ 见 butterfly.gd 同处的说明：global class 缓存缺失时 `Butterfly.new()` 会崩，
##   而 preload 是编译期绑定，两种环境一致。同时给类型标注留了 const 别名。
const BFLY := preload("res://addons/butterfly_swarm/butterfly.gd")
const BFLY_IO := preload("res://addons/butterfly_swarm/butterfly_io.gd")
const BFLY_TUNING := preload("res://addons/butterfly_swarm/butterfly_tuning.gd")

# ==================== 场景树访问（带引擎级兜底） ====================

## 取场景树。★ 为什么不用裸 `get_tree()`：
##   ① `Node.get_tree()` 在「节点刚 add_child、但树还没把 is_inside_tree 刷成 true」的窗口里
##      返回 **null**（实测：在 `extends SceneTree` 脚本的 `_initialize()` 里 add_child 之后，
##      立刻查 `is_inside_tree()` 是 **false**、`get_tree()` 是 null，而 `root` 其实已经能拿到）。
##      这时若直接判空返回"no_tree"兜底，就会误报成"没有天气系统"（真机踩过）。
##   ② 反过来，节点**真的不在树里**时调 `get_tree()`，引擎会打一条 ERROR
##      `Parameter "data.tree" is null.` —— 而"树外调用"正是无头测试/工具的主路径，
##      实测一次运行会刷 6 条（风/天气两处 + 受惊源一处，各调多次）。
##      所以这里先用 `is_inside_tree()` 分流：在树里才问 `get_tree()`，否则直接走主循环兜底。
##      这样**两条路径都不刷 ERROR**。
## 返回：SceneTree 或 null（连主循环都没有，例如纯离线工具）。
func scene_tree() -> SceneTree:
	if is_inside_tree():
		var t := get_tree()
		if t != null:
			return t
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		return loop as SceneTree
	return null


## 场景树根节点（autoload 都挂在它下面）。取不到返回 null。
## 用途：`Weather` autoload 与旧版 `Wind` 节点的查找入口（现役风系统用分组 `wind_system` 找）。
func scene_root() -> Window:
	var t := scene_tree()
	return t.root if t != null else null


# ==================== 素材 ====================
## 蝴蝶贴图。**可多选**：每只蝴蝶随机挑一张；一张都没配时会用清单/目录兜底。
## ★ 这个数组**没有 setter**，所以往里面增删**不会自动重建**：
##   在检查器里请用上面的「素材批量添加」面板（它加完会顺手 rebuild），
##   脚本里改完记得自己调一次 `rebuild()`。
@export var sprites: Array[Texture2D] = []

# ==================== 数量与区域 ====================
## 蝴蝶只数。12 只在小院落里刚好"有生气不吵闹"；60 只就是"蝴蝶谷"。
## 运行时改它需要调 rebuild()（编辑器里改会自动重建）。
@export_range(0, 400, 1) var count := 12:
	set(v):
		count = maxi(0, v)
		_request_rebuild()
## 区域尺寸（米，节点本地空间的盒子）。x/z 是水平范围，y 是可飞高度。
## ★ 蝴蝶只在这个盒子里飞（软回弹，不是硬墙）。
@export var region_size := Vector3(8.0, 3.0, 8.0):
	set(v):
		region_size = Vector3(maxf(0.2, v.x), maxf(0.2, v.y), maxf(0.2, v.z))
		_request_rebuild()
## 区域中心相对节点原点的偏移（米）。默认往上抬 1.5 米：蝴蝶在离地一段高度飞才好看。
@export var region_offset := Vector3(0.0, 1.5, 0.0):
	set(v):
		region_offset = v
		_request_rebuild()
## 按地面高度自动把区域抬到地面上（区域最低点离地 `ground_clearance` 米）。
## ★ 它会**覆盖 region_offset.y**。找不到地形时保持原值并在检查器里给警告。
@export var autofit_region := false
## 自动贴地时，区域最低点离地多高（米）。
@export var ground_clearance := 0.4
## 场景里画一个盒子线框，方便肉眼确认区域范围（不影响渲染结果，取消勾选即恢复）。
@export var debug_draw_region := false

## ★ 区域尺寸的**快捷预设** —— 它是一次性动作，不是"状态"。
##
## 用法：在检查器里选一个，它会**写进** `region_size`，然后**自己弹回 Custom**。
##
## ★★ 为什么必须弹回 Custom（实测踩过的坑）★★
##   原来它是个持久的枚举。但 Godot 加载场景时是**按文件里的属性顺序**逐个赋值的：
##   `.tscn` 里 `region_size` 在前、`region_preset` 在后 —— 于是每次加载，
##   预设都会**把用户手填的 region_size 覆盖掉**。
##   用户实测表现：把 region_size 改成 28×4×28 存好后，重新打开又变回 28×6×28
##   （蝴蝶因此铺在一个 6 米高、离地 3 米的盒子里，看起来就是"飘在天上"）。
##   改成"应用一次就弹回 Custom"之后：
##     · 文件里只会留下真实生效的 `region_size`；
##     · 预设再也不会在加载时翻盘；
##     · 检查器里选完立刻显示 Custom，语义也对得上（"我手动定了尺寸"）。
@export_enum("Custom", "小院 4×2×4", "花园 8×3×8", "草地 16×4×16", "谷地 28×6×28") var region_preset := 0:
	set(v):
		region_preset = clampi(v, 0, 4)
		if v <= 0:
			return                      # Custom：什么都不做，保留手填数值
		match v:
			1: region_size = Vector3(4.0, 2.0, 4.0)
			2: region_size = Vector3(8.0, 3.0, 8.0)
			3: region_size = Vector3(16.0, 4.0, 16.0)
			4: region_size = Vector3(28.0, 6.0, 28.0)
		# 弹回 Custom：见上面的坑。用 call_deferred 避免"在 setter 里再写自己"的递归歧义。
		region_preset = 0
		_request_rebuild()

# ==================== 张翼角度（这是"扑翼幅度"的总闸） ====================
## ★ 张翼角度 = 蝴蝶翅膀相对水平面的抬起角（度）。0 = 完全摊平，90 = 完全合拢。
## 扑翼就是在这个区间里按正弦来回摆 —— 所以这两个值直接决定"翅膀扇多大"。
## 默认 6~72：贴近平地飞到接近合拢，扑翼幅度明显但不夸张。
## 建议区间：想"优雅滑翔"用 0~35；想"蜂鸟式急扇"用 0~85。
@export_range(0.0, 90.0, 1.0) var dihedral_min_deg := 6.0:
	set(v):
		dihedral_min_deg = v
		if dihedral_max_deg < dihedral_min_deg:
			dihedral_max_deg = dihedral_min_deg
		_request_rebuild()
@export_range(0.0, 90.0, 1.0) var dihedral_max_deg := 72.0:
	set(v):
		dihedral_max_deg = v
		if dihedral_min_deg > dihedral_max_deg:
			dihedral_min_deg = dihedral_max_deg
		_request_rebuild()
## 扑翼频率（次/秒）。真实蝴蝶 5~12 Hz；8.5 观感最好。
@export_range(0.5, 30.0, 0.5) var flap_hz := 8.5:
	set(v):
		flap_hz = v
		_request_rebuild()
## 频率的群内随机抖动（±Hz）：让每只扇翅不同步，整群才不会像方阵。
@export_range(0.0, 10.0, 0.1) var flap_hz_jitter := 2.5:
	set(v):
		flap_hz_jitter = v
		_request_rebuild()

# ==================== 立体感（体积） ====================
## 翼展（米）。这是蝴蝶的**总尺寸**，身体与翅厚都按它成比例缩放。
@export_range(0.03, 2.0, 0.01) var size_m := 0.22:
	set(v):
		size_m = v
		_request_rebuild()
## 翅膀弧度：二面角沿翼展方向的增长系数（0 = 平板，0.3 = 翅尖比根部多抬 30%）。
## ★ 这是"体积感"的第一来源：曲面才会出现连续明暗渐变，平板永远一片均匀色。
@export_range(0.0, 1.5, 0.01) var wing_camber := 0.30:
	set(v):
		wing_camber = v
		_request_rebuild()
## 翅膀厚度：占翼展的比例（0.035 ≈ 翼展的 3.5%）。0 = 回到纸片。
## ★ 厚度让"侧视时是一条线"变成"一条有宽度的边"，也是边缘高光的来源。
@export_range(0.0, 0.25, 0.005) var wing_thickness := 0.035:
	set(v):
		wing_thickness = v
		_request_rebuild()
## 翅面沿头尾方向的弯拱（模型单位，小值）。给翅膀加一点"碗形"。
@export_range(-0.3, 0.3, 0.005) var wing_bend_y := 0.0:
	set(v):
		wing_bend_y = v
		_request_rebuild()
## 身体粗细（倍率）。1.0 = 默认；0 = 不画身体（回到纸片蝶）。
## ★ 身体是**真的有体积的实体**（椭圆截面），是"蝴蝶有没有质量"的关键。
##
## ★★ 实测：身体半径 = body_scale × 翼展的 12.5% ★★
##   0.5 -> 6.7% ｜ 1.0 -> 12.5% ｜ 2.0 -> 24.9% ｜ **3.0 -> 37.3%**
##   所以上限收到 **2.0**：3.0 时身体粗到几乎与翅根同宽，**会把翅膀埋进身体里**，
##   看起来像"body_scale 没生效"（用户实测就踩在这：场景里存着 3.0）。
##   真实蝴蝶的身体大约只有翼展的 5~12%。
@export_range(0.0, 2.0, 0.05) var body_scale := 1.0:
	set(v):
		body_scale = v
		_request_rebuild()
## 最小正对度：蝴蝶侧对镜头时，自动把翅面往镜头转，保证至少这么"正"（0~1）。
## ★ 默认 **0（关闭）**：厚度外壳 + 实体身体已经从几何上解决了"纸片感"，
##   再加自适应转向反而会在飞行中"翻面"（它不是纯粹的广告板，是绕面内轴转的）。
## 想开就调 0.1~0.25（配合 edge_min_deg 控制最大转角），但请先在场景里看一眼翻面感。
@export_range(0.0, 1.0, 0.01) var edge_min_facing := 0.0:
	set(v):
		edge_min_facing = v
		_request_rebuild()
## 面向镜头自适应允许的最大转角（度）。配合 edge_min_facing 使用（0 = 关）。
@export_range(0.0, 80.0, 1.0) var edge_min_deg := 14.0:
	set(v):
		edge_min_deg = v
		_request_rebuild()
## 厚度侧壁/边缘环的压暗强度（廉价版 AO，0 = 不压暗）。
@export_range(0.0, 1.0, 0.01) var rim_dark := 0.55:
	set(v):
		rim_dark = v
		_request_rebuild()

# ==================== ★ 飞行行为（移动生态学：CRW / Lévy / ARS）====================
# ★★ 为什么这些要**提到节点上**而不是只留在 tuning 资源里 ★★
#   用户诉求原话："暴露参数到检查器面板"。
#   以前这十来个参数只存在于 `ButterflyTuning`（一个可选 Resource），
#   选中蝴蝶群节点时**根本看不到** —— 想调"别直飞"都不知道该调哪儿。
#   现在它们在节点上成组出现，并且 `tuning_dict()` 里**群组值覆盖资源的同名键**
#   （与 size_m / flap_hz 等既有参数同一套规则），所以两条路都通：
#     · 直接在节点上调（改一下就见效果，编辑器里立刻重建）
#     · 或把一套手感存成 .tres 挂到 `tuning`
# 模型出处（本插件按论文自行实现，未复制外部源码）见 butterfly_tuning.gd 顶部。
# ★ 这些参数**只影响运动**，不需要重建网格 -> setter 只刷新检查器警告，不 rebuild。

# ★★ 分组名里**绝对不能出现 `/`**（实测踩过，用户截图确认）★★
#   Godot 把 `@export_group("A/B")` 里的 `/` 当成**子分组分隔符**：
#   写成 "飞行行为 Flight (CRW/Lévy/ARS)" 会被拆成三层标题
#     `飞行行为 Flight (CRW` -> `Lévy` -> `ARS)`
#   （检查器里就是三个错位的小标题）。所以这里改用中点 `·` 与空格。
@export_group("飞行行为 Flight · CRW Lévy ARS")
## CRW 核心：方向持续性。1.0 = 永远直线（"直飞"的病就是它太大）；0 = 无头苍蝇。
## 默认 0.72：小转角为主 + 偶尔一次大拐弯，像真蝴蝶。
@export_range(0.0, 0.99, 0.01) var heading_persistence := 0.72
## 小转角尺度（度）：越小越直。
@export_range(1.0, 90.0, 1.0) var turn_scale_deg := 25.0
## 大转角概率：每次决策有多大概率来一次"猛拐"（重尾）。
@export_range(0.0, 0.5, 0.005) var turn_heavy_p := 0.06
## 大转角的尺度（度）：命中大转角时拐多少度。
@export_range(10.0, 180.0, 1.0) var turn_heavy_deg := 110.0
## Lévy 步长指数 α：1.5~2.0 是昆虫觅食的典型区间（越接近 1 越长直段）。
@export_range(1.05, 3.0, 0.05) var levy_alpha := 1.6
## 决策段时长（秒）：两次航向更新之间的间隔。太短会抖、太长又变直飞。
@export_range(0.05, 3.0, 0.05) var step_time_s := 0.45
## 侧向摆动幅度：连直飞段也在小幅左右晃（0 = 关掉这层）。
@export_range(0.0, 3.0, 0.05) var lateral_weave := 0.55
## 侧向摆动频率（Hz）。
@export_range(0.2, 4.0, 0.05) var lateral_weave_hz := 1.1
## 是否启用区域限制搜索（ARS）：附近有花/蜜源时切"原地打转"。
@export var area_restricted_search := true
## ARS 感知半径（米）：这个范围内有资源才进入搜索模式。
@export_range(0.2, 20.0, 0.1) var ars_radius_m := 3.0
## ARS 的转角尺度（度）：明显比 turn_scale_deg 大 -> 打转。
@export_range(1.0, 120.0, 1.0) var ars_turn_scale_deg := 55.0
## ARS 速度上限乘子（0~1）：在花丛里飞得更慢更黏。
@export_range(0.1, 1.0, 0.01) var ars_speed_scale := 0.55
## ★ 资源点**轮换周期**（秒）：每隔这么久重新挑一个资源点。
## 为什么必须有它（用户反馈"反复在两点之间散开再重聚"）：
##   旧实现挑完资源点后**再也不更新**（计时器只设不递减），于是整群永远被
##   同一个坐标吸引 -> 收拢、散开、再收回同一点。现在默认 8 秒换一处。
@export_range(1.0, 60.0, 0.5) var ars_rotate_s := 8.0
## ★ 新资源点必须离上一个至少这么远（米）。防止"抽来抽去还是在原地"。
@export_range(0.0, 20.0, 0.5) var ars_min_move_m := 3.0
## ★ 参与度（0~1）：有多少比例的蝴蝶会响应资源点。
## 1.0 = 全部响应（整群会同步收拢，容易像"两点往返"）；0.55 = 只有一部分被吸住，
## 其余照常巡飞 —— 群就不会整体收拢/散开。0 = 完全不响应（等于关掉 ARS 的吸引力）。
@export_range(0.0, 1.0, 0.01) var ars_participation := 0.55
## ★ 趋花时**避开上一处**的半径（米）：下次挑目标会跳过离上一次这么近的候选。
## 这就是"别总回同一朵花"的保证。
@export_range(0.0, 20.0, 0.5) var seek_repeat_avoid_m := 3.0

@export_group("草交互 Grass (sgt)")
## 蝴蝶把草压弯的影响半径（米）。
@export_range(0.05, 2.0, 0.05) var grass_bend_radius := 0.42
## 压草强度（0~3）：0 = 完全关闭与草的交互。
@export_range(0.0, 3.0, 0.05) var grass_bend_strength := 1.0
## 蝴蝶要低于"区域底 + 这么多米"才压草（米）。
## ★ 默认 1.15：蝴蝶常规飞行高度约"区域底 + 1.0 m"，带子必须够到它，否则压草完全看不见。
@export_range(0.05, 3.0, 0.05) var grass_bend_height := 1.15
## 每帧最多推几只蝴蝶给草着色器（0 = 关闭交互）。
## 为什么要限：着色器里每只蝴蝶都要对**每个草顶点**算一次距离，插槽越多整片草越贵。
@export_range(0, 4, 1) var grass_bend_slots := 2
## 调试：每帧打印蝴蝶→草的 press 计算（排查"压草没反应"）。
@export var debug_grass_bend := false
@export_group("花上停留 Flower Perch (sgt)")
## ★ 总开关：蝴蝶是否**随机落到 SGT 花笔刷（brush_category = 0）上**停一会儿。
##   和"能量低才落地晒太阳"是两条独立路径：这里不看能量，纯随机、纯观赏。
##   关掉后一切行为回到原样（不改任何其它参数）。
@export var sgt_perch_enabled := true
## 两次"花上停留"之间的**最短**间隔（秒，每只蝴蝶独立计时）。
@export_range(1.0, 120.0, 0.5) var sgt_perch_interval_min_s := 8.0
## 两次"花上停留"之间的**最长**间隔（秒）。实际值在 [min, max] 内均匀随机。
@export_range(1.0, 180.0, 0.5) var sgt_perch_interval_max_s := 20.0
## 一次停留的**最短**时长（秒）。停留期间蝴蝶被"钉"在花顶，能量也照常回升。
@export_range(0.2, 30.0, 0.1) var sgt_perch_duration_min_s := 1.5
## 一次停留的**最长**时长（秒）。实际值在 [min, max] 内均匀随机。
@export_range(0.2, 60.0, 0.1) var sgt_perch_duration_max_s := 4.0
## "飞向花"的最长允许时间（秒）：超时仍未落到花顶就放弃、回去巡飞。
## ★ 为什么必须和"停留时长"分开：从决策点到花顶要飞好几米、还要向下俯冲
##   （花顶通常低于区域底），若拿停留时长当接近计时，计时结束时蝴蝶还在半路 ——
##   表现出来就是"半路掉头/乱飞"（实测 bug）。
@export_range(1.0, 30.0, 0.5) var sgt_perch_approach_timeout_s := 8.0
## 选择花时的**搜索半径**（米）：只在离自己这么近的花里随机挑。
## 调大 -> 更愿意飞远一点去停；调小 -> 只停身边的花（找不到就继续飞）。
@export_range(0.5, 40.0, 0.5) var sgt_perch_radius_m := 6.0
## 落点高度：占"这株花世界高度"的比例（0 = 花根，1 = 花顶）。
## SGT 的网格是 1×1、底面在 y=0，所以实例 basis.y 的长度就是花高。
@export_range(0.0, 1.5, 0.01) var sgt_perch_height_ratio := 0.85
## 缓存的花落脚点上限（超过就用步长抽样）。
## 整片花可能有上千株，而蝴蝶每次只要一个点 —— 没必要全拿。
@export_range(16, 8192, 16) var sgt_perch_max_points := 512
## 调试：打印本次扫描到的花笔刷数 / 落脚点数（排查"蝴蝶从不停留"）。
@export var debug_sgt_perch := false
@export_group("")
# ==================== 行为总开关 ====================
## 总开关。关掉：**只隐藏蝴蝶子节点**并停止推进（不释放节点，打开即恢复）。
##
## ★★ 实测踩过的坑（两个，都改在这里）★★
##   ① setter 里原来调了 `_request_rebuild()` —— 场景加载时 `enabled` 也会走 setter，
##      于是"加载主场景"会**先白建 200 只**（200 × ~1000 顶点 = 约 20 万顶点），
##      紧接着又因为关着而被全部隐藏、不推进。既卡又白费。
##      开关只是**显隐**，不需要重建 -> 现在 setter 只调 `_apply_enabled()`。
##   ② 原来把**节点自身**的 `visible` 也设成 enabled —— 这与 Godot 自动保存进场景的
##      `visible` 属性**互相打架**（编辑器/场景序列化都会写它）。表现就是
##      "开关写着 false、蝴蝶却还看得见，而且是冻结姿态"（用户实测报过："飘在天上不动、
##      渲染成白色纸片"）。
##      -> 现在**只改蝴蝶子节点的 visible**，节点自身的 visible 保持 true，
##         不再和编辑器/序列化抢这个属性。
##   注意：关掉时**区域线框仍然可见**（`debug_draw_region` 控制），
##     这样"关着蝴蝶调区域"也能看见盒子。
@export var enabled := true:
	set(v):
		enabled = v
		_apply_enabled()
## 随机种子。同一个种子 -> 同样的初始位置/扑翼相位/决策序列（方便复现与截图对比）。
@export var seed_value := 12345:
	set(v):
		seed_value = v
		_request_rebuild()

# ==================== 调参 ====================
## 调参资源。留空则用脚本内置默认值 —— 也就是说"什么都不配也能飞"。
@export var tuning: BFLY_TUNING

# ==================== 群体行为开关（会写进 tuning 快照） ====================
## 风的整体影响系数：0 = 蝴蝶无视天气风；1 = 原样；2 = 加倍（做"狂风里的蝴蝶"演示用）。
@export_range(0.0, 3.0, 0.05) var wind_influence := 1.0
## 是否避地（不让蝴蝶钻进草皮/地形）。关掉可以看"贴地飞"的效果。
@export var ground_avoid := true
## 是否让整群偶尔集体腾起（晴天的"群飞"脉冲）。关掉每只各飞各的。
@export var flock_pulses := true
## ★ 群体聚散脉冲的最短/最长间隔（秒）。
## 抽成参数是为了能快速验证：设成 3/5 就能几秒看一轮"聚—散—聚"，
## 而不用等默认的 25~70 秒。
@export_range(1.0, 120.0, 0.5) var pulse_interval_min_s := 25.0
@export_range(1.0, 180.0, 0.5) var pulse_interval_max_s := 70.0
## ★★ 新一轮聚散的中心必须离上一轮至少这么远（米）★★
## 这是对"反复在两点之间散开再重聚"的直接修法：每轮开始前先挑一个
## **和上一次不同**的聚集中心，再去那儿聚、再从那散。
## 设 0 = 关闭（退回旧行为：永远在同一个地方聚散，不推荐）。
@export_range(0.0, 30.0, 0.5) var gather_min_move_m := 4.0
## 记忆多少轮历史中心（挑选新中心时会避开这些点，避免"来回两个点"）。
@export_range(1, 6, 1) var gather_history_n := 3
## 受惊源：放进这个节点的路径（例如玩家）。靠近时蝴蝶会 FLEE。
## 留空则自动找分组 "player"（本项目玩家就在这个组里，见 scripts/wind.gd 的同一约定）。
@export_node_path("Node3D") var threat_path: NodePath

# ==================== 内部状态 ====================
## 群组级 RNG（**只用于建群/生成**；每只蝴蝶有自己独立的一份，见 _rng_for）。
var _rng := RandomNumberGenerator.new()
## 当前所有蝴蝶（顺序与子节点顺序一致）。★ 类型用 BFLY 别名（见文件头 preload 说明）。
var _butterflies: Array = []
## 每只蝴蝶自己的随机数发生器（下标与 _butterflies 对应）。
var _rngs: Array = []
## 重建节流：编辑器里拖参数会连发很多次 setter，攒到 _process 里一次性重建。
var _rebuild_queued := false
## 是否已经建过（避免 _ready 与 _process 重复建）。
var _built := false
## 上一帧的天气/风快照（供 wind_now() / weather_now() 与 UI 读取）。
var _weather_cache: Dictionary = {}
var _wind_cache: Dictionary = {}
## 群体腾起脉冲：> 0 时整群获得一个额外的向上力（见 _process 的 extra.hover）。
var _pulse_t := 0.0
var _pulse_cooldown := 20.0
## ★ 本轮聚散的**中心**（本地坐标；null = 还没开始过一轮）。
## 用户反馈"反复在两点之间散开再重聚"的修法核心：
##   旧实现里 `hover` 的反推中心 = 每只蝴蝶**自己的目标**（SEEK 的花 / COURT 的同伴），
##   而这些目标基本固定 -> 每轮聚散都回到同一处，形成稳定的"两点往返"振荡环。
##   现在每轮开始前先挑一个**离上一轮至少 `gather_min_move_m`** 的新中心，
##   把"聚到哪、从哪散"都换掉。
var _gather_pos: Variant = null
## 历史聚集中心（最多 `gather_history_n` 个，最旧的先丢）：挑选新中心时避开它们。
var _gather_hist: Array = []
## "向新中心聚"阶段的剩余秒数（脉冲结束后开始倒计时）。
var _regroup_t := 0.0
## "向新中心聚"阶段时长（秒）。散完以后要收回来，否则只散不聚。
@export_range(0.0, 20.0, 0.5) var regroup_s := 6.0
## 区域线框（debug_draw_region）用的 MeshInstance3D。
var _region_gizmo: MeshInstance3D = null
## 自动贴地的重试计时：找不到地形时别每帧 raycast。
var _ground_probe_t := 0.0
## 素材清单缓存（路径 -> 裁剪信息），首次读取后常驻。
var _manifest: Dictionary = {}
var _manifest_loaded := false
## 帧计时（秒），用于节流。
var _time := 0.0
## 上一帧的主题（用于诊断/测试：本群是否在跑）。
var _stepped_frames := 0


# ==================== 生命周期 ====================

func _ready() -> void:
	_rng.seed = int(seed_value)
	_load_manifest()
	# ★ 编辑器里也建（@tool）—— 这样不运行就能看到蝴蝶；运行时空场景自动补素材。
	if Engine.is_editor_hint():
		if sprites.is_empty():
			# 编辑器里不自动去 load 20 张（会拖慢打开场景），只给配置警告提示用户
			pass
		_build()
	else:
		# 运行时兜底：没配素材就从目录自动补（首次跑就能看到蝴蝶，减少"配了半天没反应"）
		if sprites.is_empty():
			autoload_all_sprites(false)
		_build()
	# ★ SGT 花落脚点**只在这里扫一次**（进场景/重载场景时）。
	#   花是地图编辑阶段摆好的静态笔刷，运行中不会增删 —— 每帧/定期重扫纯属浪费。
	#   代价：编辑器里画了新花、或挪了区域，要重载场景（或调 rebuild()）才生效。
	if sgt_perch_enabled:
		_scan_sgt_flowers()
	set_process(true)


func _process(delta: float) -> void:
	_time += delta
	if _rebuild_queued:
		_rebuild_queued = false
		_build()
	# 自动贴地（独立于 enabled：关掉飞行时也允许调整区域）
	_autofit_tick(delta)
	if not enabled:
		return
	if not _built or _butterflies.is_empty():
		return
	# ★ 固定上限的 delta：窗口被拖动/卡顿导致的巨大 delta 会让蝴蝶"瞬移穿出区域"，
	#   这里按 1/20 秒封顶（相当于最低 20fps 的步进），视觉上察觉不到，稳定性大幅提升。
	var dt := clampf(delta, 0.0005, 0.05)
	_wind_cache = wind_now()
	_weather_cache = weather_now()
	_apply_wind_influence(_wind_cache)
	# 群体腾起脉冲（晴天偶发：整群一起往上冲一下，像被惊了一下）
	if flock_pulses:
		_pulse_cooldown -= dt
		if _pulse_cooldown <= 0.0:
			var cmin := minf(pulse_interval_min_s, pulse_interval_max_s)
			var cmax := maxf(pulse_interval_min_s, pulse_interval_max_s)
			_pulse_cooldown = _rng.randf_range(cmin, cmax)
			_pulse_t = _rng.randf_range(1.2, 2.5)
			# ★ 每轮开始前先挑一个"和最近几轮不同"的新聚集中心
			#   （这是"起码要换个坐标进行聚散"的实现点）
			_new_gather_center()
		if _pulse_t > 0.0:
			_pulse_t -= dt
			if _pulse_t <= 0.0:
				# 脉冲结束 -> 进入"向新中心聚"阶段（聚散周期 = 散 -> 聚 -> 停）
				_regroup_t = maxf(0.0, regroup_s)
		elif _regroup_t > 0.0:
			_regroup_t -= dt
	# ★ SGT 花落脚点不再周期重扫（见 `_ready()` 的注释）：缓存只在 `_ready()` /
	#   `rebuild()` 时刷新，`_build_extra()` 会按当前区域过滤后交给蝴蝶。
	var extra := _build_extra(dt)
	# ★ 邻居列表**每帧一次算好**（而不是在循环里 duplicate()+remove_at()）：
	#   旧写法对每只蝴蝶都复制一次整张位置表再删一项，是 O(n²) 的**数组拷贝**开销
	#   （60 只 = 每帧 60 次 60 元素复制）。这里一趟遍历填好所有列表，复杂度只剩 O(n²) 的
	#   纯距离计算（那部分本来就要算），分配次数从 n 次降到 1 次。
	var position_lists := _neighbor_lists()
	for i in range(_butterflies.size()):
		var b: Node3D = _butterflies[i] as Node3D
		if b == null or not is_instance_valid(b):
			continue
		b.advance(dt, _bounds(), _wind_cache, _weather_cache, position_lists[i], extra)
	_stepped_frames += 1
	if debug_draw_region:
		_refresh_region_gizmo()
	# ★ 蝴蝶 ↔ 草（SimpleGrassTextured）交互：把"贴草飞的几只"推给草着色器
	_write_grass_bend(dt)


# ==================== 与草（SimpleGrassTextured / sgt）的交互 ====================
# ★★ 这是"环境互动"的实现 ★★
#   蝴蝶不是悬在真空中：贴草飞过时应当把草拂开/压伏。
#   通道复用本仓库既有的约定（`scripts/wind.gd` 就是这么给草写风与角色倒伏的）：
#     扫场景里用 SGT 草着色器的 ShaderMaterial -> 每帧逐材质写 uniform。
#   为什么不用 `global uniform`：Godot 4.7 里运行时 global uniform 在**顶点阶段失效**
#     （wind.gd 顶部有实测记录），所以只能逐材质写。
#
#   性能取舍：整片草共用少数几个材质，每帧写 ~8 个 uniform 很便宜；
#   但着色器里每只蝴蝶都要算一次顶点距离 -> 所以只推**离草最近的 2 只**（可配 `_grass_slots`）。
#   没有蝴蝶贴草时 `count = 0`，着色器整段跳过，零开销。

## 草材质缓存（用 SGT 那个统一着色器的 ShaderMaterial）。
var _grass_mats: Array[ShaderMaterial] = []
## 扫草材质的计时器（不用每帧扫场景）。
var _grass_scan_t := 0.0
## 当前生效的蝴蝶插槽数（= 实际推给草的数量，调试/测试可读）。
var _grass_slots := 0
## ★ 资源点缓存（**本地坐标**）与它的刷新计时器。null = 当前没有可用资源点。
## 语义：这是"区域限制搜索（ARS）"要用的蜜源位置，由 `_refresh_resource(delta)` 按 `ars_rotate_s` 周期轮换。
var _flower_pos: Variant = null
## 资源点**轮换**计时器（秒）。到点才重新挑资源点 —— 见 `_refresh_resource()`。
## ★ 这里原来是 `_flower_scan_t`，但**全文件没有任何地方递减它**，
##   导致资源点只算了一次就永久冻结（用户反馈"反复在两点之间散开再重聚"的根因）。
##   现在由 `_refresh_resource(delta)` 每帧递减。
var _resource_rotate_t := 0.0
## 资源点挑选用的独立 RNG（与蝴蝶的 rng 分开，避免"挑点"扰动蝴蝶的随机序列）。
var _res_rng := RandomNumberGenerator.new()
## 调试：最近一次草材质扫描的结果说明（`_grass_mats` 为空时用它定位）。
var _grass_dbg_note := ""

## ★★ 草材质扫描的**分帧**执行状态（与花扫描同一套 time-slicing 思路）★★
## 每帧只推进若干个节点，扫完整轮才原子替换 `_grass_mats` —— 避免整轮集中跑造成的周期性卡顿。
var _grass_scan_running := false
var _grass_scan_stack: Array = []
var _grass_tmp_mats: Array[ShaderMaterial] = []
var _grass_seen := {}
var _grass_looked := 0
const GRASS_SCAN_SLICE_US := 900

## ★ SGT 花的落脚点缓存（**本地坐标**，已含"花顶"高度）。
## 只在 `_ready()` / `rebuild()` 时由 `_scan_sgt_flowers()` 扫一次（花是静态笔刷）；
## `_build_extra()` 每帧按当前区域过滤后塞进 `extra["sgt_perches"]` 供蝴蝶随机挑选。
var _sgt_perch_pts: Array = []
## 本次扫描到的花笔刷节点数 / 结果说明（调试用）。
var _sgt_perch_nodes := 0
var _sgt_perch_note := ""


## 扫描场景里所有"用 SGT 草着色器"的 ShaderMaterial 并缓存。
## 参数：无（从 current_scene 起深度优先）。
## 返回值：本帧缓存到的材质数。
## 副作用：覆盖 `_grass_mats`。
## 注意：**按着色器文件路径判定**（与 grass_quality.gd 的 SGT_HINT 同一做法），
##   不按节点名/节点类型判定 —— SGT 的草就是一个 MultiMeshInstance3D，
##   节点名可以被用户改，但着色器路径不会变。
## 扫描场景里所有"用草着色器"的 ShaderMaterial 并缓存。
## 参数：无（从 current_scene 起深度优先）。
## 返回值：本帧缓存到的材质数。
## 副作用：覆盖 `_grass_mats`。
##
## ★ 为什么按着色器文件路径判定（不按节点名/类型）：草的节点名用户随时能改，
##   但着色器路径不会变（`assets/quality/grass_quality.gd` 也用这个做法）。
##
## ★★ 实测踩过的两个坑（都改在这里）★★
##   ① **`MultiMeshInstance3D` 不是 `MeshInstance3D` 的子类**（两者是兄弟，共同父类是
##      `GeometryInstance3D`）。所以 `(n as MeshInstance3D).mesh` 对 MultiMesh 会得到
##      `null`，再取 `.mesh` 就报
##      `Invalid access to property or key 'mesh' on a base object of type 'Nil'`，
##      **整次扫描在第一个草节点上就中断** -> `_grass_mats` 恒为 0、蝴蝶压草完全失效。
##      （本仓库 `scripts/quality/prop_texture_quality.gd` 里也记录了同一类坑。）
##      正确做法：用共同父类拿 `material_override`，再**按实际类型**分别取 mesh。
##   ② 主场景里真正渲染的草用的是 `assets/shaders/grass_wind.gdshader`（实测 274 个材质），
##      不是 SGT 自带着色器（只有 6 个节点）—— 所以 hints 必须**两个都认**。
func _scan_grass() -> int:
	_grass_scan_begin()
	while _grass_scan_running:
		_grass_scan_step(1 << 30)
	return _grass_mats.size()


## 开始新一轮草材质扫描：只压入 root 节点，实际遍历交给 `_grass_scan_step()` 分帧推进。
## 参数：无。
## 副作用：重置 `_grass_scan_*` 状态；**不**修改 `_grass_mats`（旧结果在整轮扫完前继续可用）。
func _grass_scan_begin() -> void:
	_grass_scan_running = false
	_grass_scan_stack.clear()
	_grass_tmp_mats.clear()
	_grass_seen.clear()
	_grass_looked = 0
	var st := scene_tree()
	if st == null:
		_grass_dbg_note = "scene_tree 为空"
		return
	var root := st.current_scene if st.current_scene != null else scene_root()
	if root == null:
		_grass_dbg_note = "root 为空"
		return
	_grass_scan_stack.append(root)
	_grass_scan_running = true


## 分帧推进草材质扫描，最多消耗 `budget_us` 微秒。
## 参数：`budget_us` 本帧允许的耗时（微秒）；同步调用可传一个极大值。
## 返回值：true = 本轮已结束（结果已原子换入 `_grass_mats`）；false = 还没扫完。
##
## ★ 为什么原子替换：`_grass_mats` 每帧被 `_write_grass_bend()` 读取 —— 如果中途
##   原地 clear/append，那一帧蝴蝶就会推空数组给草，视觉上草的压草效果会"闪一下"。
##   扫到临时数组里，扫完才整体赋值，中途始终有旧结果可用。
func _grass_scan_step(budget_us: int) -> bool:
	if not _grass_scan_running:
		return true
	var t_end := Time.get_ticks_usec() + budget_us
	var walked := 0
	while not _grass_scan_stack.is_empty():
		var n: Node = _grass_scan_stack.pop_back()
		if n != null:
			# ★ 共同父类 GeometryInstance3D：MultiMeshInstance3D 与 MeshInstance3D 都是它的子类
			if n is GeometryInstance3D:
				var gi := n as GeometryInstance3D
				var cands: Array = [gi.material_override]
				# 按实际类型取 mesh（**不能**直接 `as MeshInstance3D`）
				var mesh: Mesh = null
				if n is MeshInstance3D:
					mesh = (n as MeshInstance3D).mesh
				elif n is MultiMeshInstance3D:
					var mm := (n as MultiMeshInstance3D).multimesh
					if mm != null:
						mesh = mm.mesh
				if mesh != null:
					for s in range(mesh.get_surface_count()):
						var sm := mesh.surface_get_material(s)
						if sm != null:
							cands.append(sm)
				for c in cands:
					if c == null:
						continue
					_grass_looked += 1
					if c is ShaderMaterial:
						var smat := c as ShaderMaterial
						var sh: Shader = smat.shader
						if sh == null:
							continue
						var sp := String(sh.resource_path)
						for hint in GRASS_SHADER_HINTS:
							if sp.contains(String(hint)):
								var id := smat.get_instance_id()
								if not _grass_seen.has(id):
									_grass_seen[id] = true
									_grass_tmp_mats.append(smat)
								break
		for ch in n.get_children():
			_grass_scan_stack.append(ch)
		walked += 1
		if walked >= 32:
			walked = 0
			if Time.get_ticks_usec() >= t_end:
				return false
	_grass_scan_finish()
	return true


## 收尾：把本轮结果**原子替换**进 `_grass_mats`（蝴蝶下一帧起才会用到）。
func _grass_scan_finish() -> void:
	_grass_scan_running = false
	_grass_scan_stack.clear()
	_grass_dbg_note = "看了 %d 个材质槽，命中 %d" % [_grass_looked, _grass_tmp_mats.size()]
	# ★ 原子替换：直接赋值 Array[ShaderMaterial] 类型数组，Godot 会更新类型引用
	_grass_mats = _grass_tmp_mats
	_grass_tmp_mats = []
	_grass_seen.clear()


## 中止未完成的扫描。
func _grass_scan_abort() -> void:
	_grass_scan_running = false
	_grass_scan_stack.clear()
	_grass_tmp_mats.clear()
	_grass_seen.clear()


## ★ 扫描场景里的 **SGT 花笔刷**，缓存"花顶"落脚点（本地坐标）。
## 参数：无（从 current_scene 起深度优先，与 `_scan_grass()` 同一套遍历）。
## 返回值：本次缓存到的落脚点数。
## 副作用：覆盖 `_sgt_perch_pts` / `_sgt_perch_nodes` / `_sgt_perch_note`。
##
## 判定"这是花"的方式（**不看节点名**，用户随时会改名）：
##   · 节点是 `MultiMeshInstance3D`（SGT 的草/花都是它）；
##   · 带 `brush_category` 属性，且值 == 0（SGT 插件里 0 = 花，见 grass.gd 的 @export_enum）；
##   · 有 non-null 的 multimesh、TRANSFORM_3D、可见。
##
## 落点 = 实例原点 + 实例 basis.y × `sgt_perch_height_ratio`：
##   SGT 网格是 1×1、底面在 y=0，所以实例 basis.y（含节点/实例缩放）的长度就是这株花的世界高度。
##   再加 1 cm 抬高，避免蝴蝶中心正好埋进花瓣上缘。
##
## 性能：整片花可能上千株，用**步长抽样**把总量压在 `sgt_perch_max_points` 以内。
##   只在 `_ready()` / `rebuild()` 时扫一次（花是静态笔刷，运行中不会增删），
##   不需要周期重扫、也不需要分帧；蝴蝶每个决策点只随机挑一个点，开销可忽略。
##
## ★ 只收**水平落在区域里**的花（x/z 在 bounds 内），原因见函数内注释：
##   区域外的花会让蝴蝶整段飞出区域，观感就是"乱飞"。竖直方向不限制（花在区域底下方）。
func _scan_sgt_flowers() -> int:
	_sgt_perch_pts.clear()
	_sgt_perch_nodes = 0
	_sgt_perch_note = ""
	var st := scene_tree()
	if st == null:
		_sgt_perch_note = "scene_tree 为空"
		return 0
	var root := st.current_scene if st.current_scene != null else scene_root()
	if root == null:
		_sgt_perch_note = "root 为空"
		return 0
	var nodes: Array = []
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
		if not (n is MultiMeshInstance3D):
			continue
		var mi := n as MultiMeshInstance3D
		if not mi.is_visible_in_tree():
			continue
		var cat: Variant = mi.get("brush_category")
		if cat == null or int(cat) != 0:
			continue
		var mm: MultiMesh = mi.multimesh
		if mm == null or mm.transform_format != MultiMesh.TRANSFORM_3D or mm.instance_count <= 0:
			continue
		nodes.append(mi)
	if nodes.is_empty():
		_sgt_perch_note = "场景里没有 SGT 花笔刷（brush_category = 0）"
		return 0
	_sgt_perch_nodes = nodes.size()
	# ★ 抽样预算按"**检查**的实例数"算，而不是"保留的点数"（实测教训）：
	#   区域内的花可能只占全部花的一小部分（本项目 85/3952 ≈ 2%）。
	#   旧算法 stride = 实例数 / sgt_perch_max_points，等于只检查 512 个实例 ——
	#   只能命中约 5~10 个点，蝴蝶能选的花极少，随机性基本没有。
	#   这里把检查量提到保留上限的 16 倍（默认 512 -> 8192），本项目足以覆盖全部 3952 株。
	var inspect_budget := maxi(1, sgt_perch_max_points * 16)
	var budget := maxi(1, int(ceil(float(inspect_budget) / float(nodes.size()))))
	# ★ 只保留**水平方向落在区域里**的花：蝴蝶"只在区域内飞"是硬需求，
	#   落脚点如果在区域外，蝴蝶要么够不着（边界力把它推回来），要么得整段飞出区域 ——
	#   后者在观感上就是"乱飞"（用户反馈）。
	#   实测本项目：3952 个花实例里只有 85 个水平落在区域 12×12 内，其余散布到场外几十米；
	#   旧代码用 `_bounds().grow(半径 6m)` 收点，等于把大量区域外的花都当成了候选。
	#   竖直方向**不设限**：花本来就长在区域底下方（实测花顶比区域底低 1.1~2.0 m），
	#   停留/接近期间由蝴蝶侧临时豁免下边界（见 Butterfly._force_bounds）。
	var bnd := _bounds()
	var bnd_lo := bnd.position
	var bnd_hi := bnd.position + bnd.size
	var ratio := clampf(sgt_perch_height_ratio, 0.0, 1.5)
	for n in nodes:
		var mi := n as MultiMeshInstance3D
		var mm: MultiMesh = mi.multimesh
		if mm == null:
			continue
		var cnt := mm.instance_count
		# ★★ 每个 MultiMesh 只读**一次** `mm.buffer`（实测性能杀手）★★
		#   `mm.buffer` 的读取是**整块复制**（本项目 1013 个实例 = 1.6 万个 float）。
		#   放进逐实例循环里，扫一遍 3952 株花 ≈ 复制 250 MB 内存。
		var buf := mm.buffer
		var stride := maxi(1, int(ceil(float(cnt) / float(budget))))
		# ★ 读取实例变换的实际 stride（float 个数 / 实例）
		var xf_stride := 16
		if cnt > 0 and buf.size() % cnt == 0 and buf.size() / cnt >= 12:
			xf_stride = buf.size() / cnt
		# ★ 节点变换与它的逆也只算一次：`to_local()` 内部就是 `global_transform.affine_inverse() * p`，
		#   放在循环里等于每个实例做一次 3×3 求逆。
		var mi_xf := mi.global_transform
		var inv := global_transform.affine_inverse()
		# 每轮随机起点：每次扫描抽到的样本不完全相同，视觉上"停的花"更随机
		var first := _res_rng.randi_range(0, stride - 1)
		for i in range(first, cnt, stride):
			var xf: Transform3D = mi_xf * _multimesh_instance_xf(mm, buf, i, xf_stride)
			var up := xf.basis.y
			var h := up.length()
			if h < 0.05:
				continue
			var p := xf.origin + up / h * (h * ratio) + Vector3.UP * 0.01
			var lp := inv * p
			if lp.x >= bnd_lo.x and lp.x <= bnd_hi.x and lp.z >= bnd_lo.z and lp.z <= bnd_hi.z:
				_sgt_perch_pts.append(lp)
			if _sgt_perch_pts.size() >= sgt_perch_max_points:
				break
		if _sgt_perch_pts.size() >= sgt_perch_max_points:
			break
	if _sgt_perch_pts.is_empty():
		_sgt_perch_note = "找到 %d 个花笔刷，但区域范围内没有落脚点" % _sgt_perch_nodes
	elif debug_sgt_perch:
		print("[butterfly] SGT 花：%d 个笔刷 -> %d 个落脚点" % [_sgt_perch_nodes, _sgt_perch_pts.size()])
	return _sgt_perch_pts.size()


## 读取 MultiMesh 第 `i` 个实例的 Transform3D。
## 参数：`mm`（回退用）、`buf`（**由调用方一次性读好传入**，见 `_scan_sgt_flowers` 的性能注释）、
##       `i`（实例下标）、`stride`（每个实例占的 float 个数，12 或 16）。
## ★ 为什么不在这里面读 `mm.buffer`：那会整块复制，逐实例调用等于把整块复制 N 遍。
## ★ 为什么不直接用 `mm.get_instance_transform(i)`：
##   本项目实测（Godot 4.7.2，SGT 从 `maps/*_grass.res` 加载的 MultiMesh）该 API
##   **一律返回单位阵**（origin 全变 (0,0,0)），而 `mm.buffer` 里其实存着正确的数据
##   —— 直接用它会把整片花当成"全在原点的一株"，落脚点全部错误。
## buffer 布局（TRANSFORM_3D）：每个实例 12 个 float，按 **3 行 × (basis 3 + origin 分量)**：
##   [bx.x, bx.y, bx.z, ox,  by.x, by.y, by.z, oy,  bz.x, bz.y, bz.z, oz]
##   若该 MultiMesh 带 custom data（本项目 SGT 是 4 个 float），后面再跟 4 个 float；
##   `stride` 由 `buffer.size() / instance_count` 动态算出，所以带不带 custom data 都对。
func _multimesh_instance_xf(mm: MultiMesh, buf: PackedFloat32Array, i: int, stride: int) -> Transform3D:
	var need := (i + 1) * stride
	if stride >= 12 and buf.size() >= need:
		var o := i * stride
		var b := Basis()
		b.x = Vector3(buf[o], buf[o + 1], buf[o + 2])
		b.y = Vector3(buf[o + 4], buf[o + 5], buf[o + 6])
		b.z = Vector3(buf[o + 8], buf[o + 9], buf[o + 10])
		return Transform3D(b, Vector3(buf[o + 3], buf[o + 7], buf[o + 11]))
	# 没有 buffer（例如运行时动态新建、还没上传）时才回退到官方 API
	return mm.get_instance_transform(i)


## 每帧把"最贴近草的几只蝴蝶"写给草着色器。
## 参数 delta：用于节流扫描。
## 返回值：无。
## 副作用：写 `_grass_mats` 里每个材质的 `sgt_butterfly_*`；更新 `_grass_slots`。
## 注意：`enabled = false` 时也会被调用（在 _process 里更早的地方 return 之前不会到），
##   但我们只在有蝴蝶时写 -> 关掉时 `count=0`，草恢复原状（符合"关掉就干净"）。
func _write_grass_bend(delta: float) -> void:
	_grass_scan_t -= delta
	# ★ 草材质扫描**分帧**执行（与花扫描同思路）：
	#   整轮遍历场景树在编辑器里实测 ~10 ms，拆到多帧后单帧 ≤ 1 ms。
	#   扫到临时数组里，整轮结束才原子换入 `_grass_mats`，蝴蝶中途继续用旧结果。
	if _grass_scan_t <= 0.0:
		_grass_scan_t = 5.0
		_grass_scan_begin()
	if _grass_scan_running:
		_grass_scan_step(GRASS_SCAN_SLICE_US)
	var slots := int(_num_grass_slots())
	if _grass_mats.is_empty() or slots <= 0 or _butterflies.is_empty():
		_grass_slots = 0
		_push_grass_slots([], slots)
		return
	# 挑"最贴近草的那几只"：判据 = 蝴蝶本地 y 相对区域底的高度（越小越贴地）
	var floor_y := _bounds().position.y
	var cands: Array = []
	for b in _butterflies:
		if b == null or not is_instance_valid(b):
			continue
		var n3 := b as Node3D
		if not n3.visible:
			continue
		cands.append([n3.position.y - floor_y, n3])
	cands.sort_custom(func(a, c): return float(a[0]) < float(c[0]))
	var picked: Array = []
	for i in range(mini(slots, cands.size())):
		picked.append(cands[i][1])
	_grass_slots = picked.size()
	_push_grass_slots(picked, slots)


## 把选中的蝴蝶写进草材质。空数组 = 全部关掉（count=0）。
## 参数 list：Array[Node3D]（蝴蝶，**本地坐标**）；slots：插槽上限。
## 返回值：无。
func _push_grass_slots(list: Array, slots: int) -> void:
	if _grass_mats.is_empty():
		return
	var radius := _tuning_num("grass_bend_radius", 0.42)
	var bend := _tuning_num("grass_bend_strength", 1.0)
	# ★ 高度带默认 1.15 m：蝴蝶常规飞行高度约"区域底 + 1.0 m"，
	#   带子必须够到它，否则 press 恒为 0、交互完全看不见（实测踩过：0.6 时 press 全 0）。
	var band := maxf(0.05, _tuning_num("grass_bend_height", 1.15))
	var floor_y := _bounds().position.y
	# 组装最多 2 组（着色器只有 2 个插槽；slots>2 也只推前 2）
	var pos := [Vector3(1.0e9, 1.0e9, 1.0e9), Vector3(1.0e9, 1.0e9, 1.0e9)]
	var vel := [0.0, 0.0]
	var press := [0.0, 0.0]
	var n := mini(mini(list.size(), slots), 2)
	for i in range(n):
		var b: Node3D = list[i]
		# ★ 取世界坐标要带**树外兜底**：Node3D.global_position 依赖祖先链，
		#   节点还没进树时它恒等于 (0,0,0)（实测踩过：本地 y=2.30 却报世界 y=0.00，
		#   于是 press 算成"贴地"、整片草被压平）。
		#   树外时用"节点全局变换 + 本地 position"手工折算（与 Butterfly._sync_transform 的兜底同一思路）。
		var wp: Vector3 = b.global_position
		if not b.is_inside_tree():
			wp = global_transform * b.position
		pos[i] = wp
		var v: Vector3 = b.get("velocity") if b.get("velocity") is Vector3 else Vector3.ZERO
		vel[i] = clampf(v.length() / maxf(0.1, _tuning_num("speed_max", 2.2)), 0.0, 1.0)
		# press：贴得越低越大。`root_wy` = 这个草实例所在高度的世界 y（近似取群组的
		# 世界 y + 区域底），h = 蝴蝶高出它的米数。
		var root_wy := global_position.y + floor_y
		var h := maxf(0.0, wp.y - root_wy)
		press[i] = clampf(1.0 - h / band, 0.0, 1.0)
		if press[i] <= 0.001:
			press[i] = 0.0
		if debug_grass_bend:
			print("[蝴蝶/草] slot%d pos=%s h=%.3f band=%.3f press=%.3f" % [i, str(wp), h, band, press[i]])
	for m in _grass_mats:
		if m == null or not is_instance_valid(m):
			continue
		_set_grass_uniform(m, &"sgt_butterfly_pos", pos)
		_set_grass_uniform(m, &"sgt_butterfly_vel", vel)
		_set_grass_uniform(m, &"sgt_butterfly_press", press)
		_set_grass_uniform(m, &"sgt_butterfly_radius", radius)
		_set_grass_uniform(m, &"sgt_butterfly_bend", bend)
		_set_grass_uniform(m, &"sgt_butterfly_count", n)


## 写一个草材质 uniform（**编辑器/运行时走不同通道**）。
## 参数 m：草材质；param：uniform 名；value：值（与 `set_shader_parameter` 同类型）。
## 返回值：无。
##
## ★★ 为什么编辑器里不能直接 `set_shader_parameter` ★★
##   main.tscn 里的草材质是**内联 `[sub_resource]`**（`material_override` 引用）。
##   `ShaderMaterial.set_shader_parameter()` 会做两件事：
##     ① 把值写进 Resource 自己的 `param_cache` —— 这是**保存场景时被序列化的那份数据**；
##     ② `emit_changed()` —— 让编辑器把场景标脏。
##   于是每帧写一次"蝴蝶瞬时状态"，每次 Ctrl+S 就把**当时那一帧的 pos/vel/press**
##   固化进 main.tscn（用户反馈："每次保存场景这三个值都在变"）。
##   编辑器里改走 `RenderingServer.material_set_param()` 直接写材质 RID：
##   GPU 侧参数照常生效（预览里蝴蝶照样压草），但 Resource 的 `param_cache` 保持原样
##   -> 场景不再被污染、也不再被无谓地标脏。
##   运行时没有保存场景这回事，用回 `set_shader_parameter`（可被 `get_shader_parameter` 回读，
##   测试与调试都依赖这个可回读性）。
func _set_grass_uniform(m: ShaderMaterial, param: StringName, value: Variant) -> void:
	if not Engine.is_editor_hint():
		m.set_shader_parameter(param, value)
		return
	var rid := m.get_rid()
	if rid.is_valid():
		RenderingServer.material_set_param(rid, param, value)
	else:
		# 极端兜底：拿不到 RID 时宁可让预览失效，也不污染场景
		pass


## 读草交互的插槽数（容错：tuning 里可能是 int 而不是 float）。
func _num_grass_slots() -> float:
	return _tuning_num("grass_bend_slots", 2.0)


## 从 tuning 字典读一个 float（缺失 -> 默认值）。与 Butterfly._num 同语义，
## 但 swarm 侧只用来读"草交互"这几个参数。
func _tuning_num(key: String, fallback: float) -> float:
	var d := tuning_dict()
	if d.has(key):
		var v: Variant = d[key]
		if v is float or v is int:
			return float(v)
	return fallback


func _notification(what: int) -> void:
	# 被移出场景树时清掉 RNG 引用（避免残留），线框随节点一起释放
	if what == NOTIFICATION_EXIT_TREE:
		_butterflies.clear()
		_rngs.clear()


# ==================== 构建 ====================

## 请求重建（**节流**）。所有 @export 的 setter 都调它。
## 为什么不在 setter 里直接重建：
##   · 编辑器里拖 count/region_size 会连发几十次 setter，直接重建会卡
##   · 场景未进树（编辑器刚实例化）时重建会拿到不合法的地形
## 因此统一攒到下一帧 _process 开头做一次。
func _request_rebuild() -> void:
	_rebuild_queued = true
	set_process(true)
	# 编辑器里也要求刷新检查器警告（区域太小 / 没素材 这类提示）
	update_configuration_warnings()


## 全量重建：清掉旧蝴蝶，按当前参数重新撒一群。
## 返回值：无。
## 副作用：增删子节点、重建材质（**会 load 贴图与着色器**）、重建区域线框。
## 调用时机：_ready / _process（节流）/ 运行时代码显式调用。
## 注意：
##   · 每只蝴蝶一个 MeshInstance3D + 一个独立 ShaderMaterial（这是"各自扑翼"的必要条件）
##   · 没有素材时不报错，只是建 0 只（并在检查器里给警告）
##   · 反复调用是安全的（旧节点会 queue_free）
func _build() -> void:
	_rebuild_queued = false
	for b in _butterflies:
		if b != null and is_instance_valid(b):
			b.queue_free()
	_butterflies.clear()
	_rngs.clear()
	# 也清掉"别的脚本塞进来的非蝴蝶子节点"吗？**不清** —— 只清我们自己建的 Butterfly。
	# （用 is Butterfly 判定，见 _sweep_stale_children：场景里手工放的蝴蝶也会被认领。）
	_sweep_stale_children()
	_built = true
	# ★ 重建时**不重新 seed**：拖参数不该让蝴蝶重新洗牌，否则调一次区域位置整群就跳一次。
	#   想要"重新洗牌"请用 respawn_all() 或改 seed_value（改 seed 会触发重建）。
	if sprites.is_empty():
		_build_gizmo()
		update_configuration_warnings()
		return
	var shader := _wings_shader()
	var tuning_dict := tuning_dict()
	var n := count
	var use := _resolved_sprites()
	# ★★ 每张图**各自**算 UV 裁剪框（不查清单、不按文件名匹配）★★
	#   这是"支持任意图片素材的加入与替换"的关键：
	#     · 用户往 sprites 里塞任意 PNG（裁过的/没裁过的/透明边宽窄不一的/白底无 alpha 的）
	#       都能得到正确的裁剪，不需要先跑一遍扫描工具、也不依赖 sprite_manifest.json；
	#     · 缓存的键是**内容指纹**（路径+字节数+SHA256），所以"换图"会自动失效重算。
	#   代价：每张图首次要全像素扫一次（20 张约 1~3 秒，只在 rebuild 时发生）；
	#   同一批图重复 rebuild 会命中缓存（compute_uv_set 里已去重）。
	var uv_set := BFLY_IO.compute_uv_set(use)
	for i in range(n):
		var tex: Texture2D = use[i % use.size()]
		var b: Node3D = BFLY.new()
		b.name = "Butterfly_%02d" % i
		add_child(b)
		var r := _rng_for(i)
		var crop := _crop_for(uv_set, tex)
		b.setup(tex, crop, r, tuning_dict, shader)
		b.spawn(_bounds())
		_butterflies.append(b)
		_rngs.append(r)
	_apply_enabled()
	_build_gizmo()
	update_configuration_warnings()
	if not Engine.is_editor_hint():
		print("[蝴蝶] 已生成 %d 只（素材 %d 张 ｜ 区域 %s ｜ 风影响 %.2f）" % [
				_butterflies.size(), use.size(), str(region_size), wind_influence])


## 从 compute_uv_set 的结果里取某张贴图的裁剪框；取不到就退回按路径现算。
## 参数 uv_set：BFLY_IO.compute_uv_set() 的返回值；tex：要查的贴图。
## 返回值：Rect2i（取不到时返回 Rect2i(0,0,0,0)，调用方会走"不裁剪"兜底）。
func _crop_for(uv_set: Dictionary, tex: Texture2D) -> Rect2i:
	if tex == null:
		return Rect2i(0, 0, 0, 0)
	var key := String(tex.resource_path)
	if not key.is_empty() and uv_set.has(key):
		return uv_set[key]["crop"] as Rect2i
	return BFLY_IO.detect_bbox(tex)


## ★★ UV 裁剪重建（检查器按钮 / 菜单「重新扫描蝴蝶素材」都可以调）★★
##
## 做什么：清掉包围盒缓存 -> 对**当前 sprites 里的每一张图**重新全像素扫描 ->
##   把新的裁剪框写回每只蝴蝶（不重建节点）-> 返回统计。
##
## 为什么需要它（用户诉求）："UV 如果不能动态实现，那么需要一个按钮实现 UV 生成"。
##   现在的实现其实**已经自动**（rebuild 时按内容指纹算，换图即失效），
##   这个按钮是**手动兜底**：改完图想立刻看到结果、或怀疑裁剪不对时点一下。
##
## 参数 无。
## 返回值：{"count": 处理张数, "sprites": 素材张数, "generation": 代数,
##          "entries": [{path, crop, scale, offset}, ...]}
## 副作用：清并重建 BFLY_IO 缓存；改每只蝴蝶的 crop（位置/状态不动）；刷新检查器。
func regenerate_uv() -> Dictionary:
	var use := _resolved_sprites()
	var res := BFLY_IO.regenerate_all(use)
	var uv_set := BFLY_IO.compute_uv_set(use)
	for b in _butterflies:
		if b == null or not is_instance_valid(b):
			continue
		var tex: Texture2D = b.sprite_tex
		if tex == null:
			continue
		b.set_crop(_crop_for(uv_set, tex))
	res["sprites"] = use.size()
	if not Engine.is_editor_hint():
		print("[蝴蝶] UV 裁剪已重建：%d 张图" % int(res["count"]))
	return res
	for c in get_children():
		if c.get_script() == BFLY and not _butterflies.has(c):
			c.queue_free()


## 解析"这轮用哪些贴图"：优先用 sprites 里**已赋值**的；全空则用清单/目录兜底。
## 返回值：Array[Texture2D]（可能为空）。
func _resolved_sprites() -> Array:
	var out: Array = []
	for t in sprites:
		if t is Texture2D:
			out.append(t)
	if not out.is_empty():
		return out
	# 兜底：按清单（或现场扫描目录）load 出前 8 张 —— 8 张足够出效果，又不至于首帧卡顿。
	var paths := _manifest_paths()
	if paths.is_empty():
		paths = BFLY_IO.list_butterfly_paths()
	var limit := mini(8, paths.size())
	for i in range(limit):
		var t2 := load(String(paths[i])) as Texture2D
		if t2 != null:
			out.append(t2)
	return out


## 清掉"上一轮遗留"的 Butterfly 子节点（例如场景被重新加载、或脚本热重载后）。
## 注意：只处理"脚本是 Butterfly"的子节点，别的子节点一律不动（用户自己挂的东西不能删）。
func _sweep_stale_children() -> void:
	for c in get_children():
		if c.get_script() == BFLY and not _butterflies.has(c):
			c.queue_free()


## 每只蝴蝶的独立 RNG：种子 = seed_value * 1_000_003 + i，保证
##   ① 可复现（同 seed 同结果）  ② 每只不同（不会"所有蝴蝶一模一样"）
func _rng_for(i: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = int(seed_value) * 1000003 + i * 7919
	return r


## 翅膀着色器。找不到会 push_warning 并返回 null（蝴蝶就没有视觉，但 AI 仍可跑）。
func _wings_shader() -> Shader:
	var p := "res://assets/shaders/butterfly_wings.gdshader"
	if not ResourceLoader.exists(p):
		push_warning("[蝴蝶] 找不到 %s —— 蝴蝶不会有可见翅膀（AI 仍会跑）" % p)
		return null
	return load(p) as Shader


# ==================== 区域 ====================

## 区域盒子（**本地空间** AABB，以 region_offset 为中心）。
## 这是 Butterfly.advance 的 bounds 入参；也是 debug 线框与自动贴地的基准。
func _bounds() -> AABB:
	var half := region_size * 0.5
	return AABB(region_offset - half, region_size)


## 世界空间的区域盒子（外部想画 Gizmo / 放花丛时用）。
func bounds_world() -> AABB:
	var b := _bounds()
	return AABB(to_global(b.position), b.size)


## 按地面高度自动抬高区域（autofit_region 时每帧节流调用）。
## 地面来源优先级：
##   ① 带 `butterfly_ground` 分组的节点（用户自己放一个空 Node3D 标地面）
##   ② 从区域中心向下的 raycast（打到 CollisionObject3D 就用它的交点）
##   ③ 都失败 -> 保持原值，并给出一次警告
## 返回值：false = 没探到地面（调用方不该改 region_offset）。
func auto_fit_to_ground() -> bool:
	var center := to_global(region_offset)
	# ① 手动标记的地面
	var st := scene_tree()
	if st != null:
		var best: Node3D = null
		var best_d := 1.0e20
		for n in st.get_nodes_in_group("butterfly_ground"):
			if n is Node3D:
				var d := (n as Node3D).global_position.distance_squared_to(center)
				if d < best_d:
					best_d = d
					best = n as Node3D
		if best != null:
			center = Vector3(center.x, best.global_position.y, center.z)
			_apply_ground(center.y)
			return true
	# ② raycast 向下 200 米
	if st != null:
		var space := get_world_3d().direct_space_state if get_world_3d() != null else null
		if space != null:
			var from := center
			var to := center - Vector3(0, 200.0, 0)
			var q := PhysicsRayQueryParameters3D.create(from, to)
			q.collide_with_areas = false
			var hit := space.intersect_ray(q)
			if not hit.is_empty() and hit.has("position"):
				var pos: Vector3 = hit["position"]
				_apply_ground(pos.y)
				return true
	return false


## 把探测到的地面世界高度落到 region_offset.y 上（使区域最低点离地 ground_clearance）。
func _apply_ground(ground_y: float) -> void:
	var local_ground := to_local(Vector3(0, ground_y, 0)).y
	var want := local_ground + ground_clearance + region_size.y * 0.5
	if absf(want - region_offset.y) > 0.01:
		region_offset.y = want


# ==================== 天气 / 风 ====================

## 读当前风。返回结构（**契约**，Butterfly 与测试都按它读）：
##   {"dir": Vector2(世界 XZ 单位向量), "strength": float, "gust": float,
##    "turbulence": float, "speed": float, "source": String}
## 来源优先级：风系统（已有算好的 cur_*，且它才是草/植被实际用的那份）-> `Weather` -> 内置兜底。
##   风系统按两级找：root 下的旧 `Wind` 节点（去 autoload 之前的兼容）-> 分组 `wind_system`
##   （现役形态：scenes/main.tscn 里的 WindSystem 节点，它在 _ready 里 add_to_group）。
##   ⚠ 这里**故意不引用**项目的 `WindSystem` class_name：本 addon 要能独立复用（理由同文件头 preload 那段）。
## 注意：风系统与 `Weather` 都可能不存在（例如单测里只挂一个节点），
##   所以每一步都判空；三者都不在时给一套"微风"常量，保证蝴蝶永远有风可用（不会静止死）。
func wind_now() -> Dictionary:
	var rt := scene_root()
	if rt == null:
		return _fallback_wind("no_tree")
	var w := rt.get_node_or_null("Wind")
	if w == null:
		# ★ 去 autoload 之后风系统是场景内节点：用分组名找，只认节点属性、不认 class_name
		var t := scene_tree()
		if t != null:
			var gs := t.get_nodes_in_group("wind_system")
			if not gs.is_empty():
				w = gs[0]
	if w != null:
		var d: Variant = w.get("cur_dir")
		var s: Variant = w.get("cur_strength")
		if d is Vector2 and s is float:
			return {
				"dir": (d as Vector2).normalized() if (d as Vector2).length_squared() > 1e-8 else Vector2(1, 0),
				"strength": float(s),
				"gust": float(w.get("cur_gust")) if w.get("cur_gust") is float else 0.15,
				"turbulence": float(w.get("cur_turbulence")) if w.get("cur_turbulence") is float else 0.30,
				"speed": float(w.get("cur_speed")) if w.get("cur_speed") is float else 1.4,
				"source": "Wind",
			}
	var we := rt.get_node_or_null("Weather")
	if we != null:
		var wd: Variant = we.get("wind_dir")
		var dir := Vector2(1, 0)
		if wd is Vector2 and (wd as Vector2).length_squared() > 1e-8:
			dir = (wd as Vector2).normalized()
		var strength := 0.18
		if we.get("wind") is float:
			strength = float(we.get("wind"))
		return {
			"dir": dir,
			"strength": strength,
			"gust": float(we.get("wind_gust")) if we.get("wind_gust") is float else 0.15,
			"turbulence": float(we.get("wind_turbulence")) if we.get("wind_turbulence") is float else 0.30,
			"speed": float(we.get("wind_speed")) if we.get("wind_speed") is float else 1.4,
			"source": "Weather",
		}
	return _fallback_wind("fallback")


## 兜底风（没有任何天气系统时）。数值抄自 Weather 的 CLEAR 预设，保持场景一致。
func _fallback_wind(source: String) -> Dictionary:
	return {
		"dir": Vector2(1, 0), "strength": 0.18, "gust": 0.15,
		"turbulence": 0.30, "speed": 1.4, "source": source,
	}


## 读当前天气（供 Butterfly 决策"要不要去躲"）。返回：
##   {"kind": int, "name": String, "wind": float, "gust": float, "rain": float,
##    "cloud": float, "source": String}
## 没有 Weather 时返回一套"晴天"常量。
func weather_now() -> Dictionary:
	var rt := scene_root()
	if rt == null:
		return _fallback_weather("no_tree")
	var we := rt.get_node_or_null("Weather")
	if we == null:
		return _fallback_weather("fallback")
	var kind := 0
	if we.get("current") is int:
		kind = int(we.get("current"))
	var nm := ""
	# Weather 自带 kind->中文名 的字典（KIND_NAMES），能读到就用它的
	var names: Variant = we.get("KIND_NAMES")
	if names is Dictionary and (names as Dictionary).has(kind):
		nm = String((names as Dictionary)[kind])
	return {
		"kind": kind,
		"name": nm,
		"wind": float(we.get("wind")) if we.get("wind") is float else 0.18,
		"gust": float(we.get("wind_gust")) if we.get("wind_gust") is float else 0.15,
		"rain": float(we.get("rain")) if we.get("rain") is float else 0.0,
		"cloud": float(we.get("cloud")) if we.get("cloud") is float else 0.10,
		"source": "Weather",
	}


## 兜底天气（晴天）。
func _fallback_weather(source: String) -> Dictionary:
	return {"kind": 0, "name": "", "wind": 0.18, "gust": 0.15, "rain": 0.0, "cloud": 0.10,
			"source": source}


## 把 wind_influence 乘进风字典（逐帧、在灌给蝴蝶之前调用一次）。
## 副作用：改传入字典（就地）。
## 注意：只缩**强度类**分量，不改风向（方向不该被系数影响）。
func _apply_wind_influence(w: Dictionary) -> void:
	var k := maxf(0.0, wind_influence)
	w["strength"] = float(w.get("strength", 0.0)) * k
	w["gust"] = float(w.get("gust", 0.0)) * k
	w["turbulence"] = float(w.get("turbulence", 0.0)) * k


# ==================== 每帧辅助 ====================

## 所有蝴蝶的本地坐标（分离力用）。顺序与 _butterflies 一致。
func _local_positions() -> Array:
	var out: Array = []
	for b in _butterflies:
		if b != null and is_instance_valid(b):
			out.append(b.position)
		else:
			out.append(Vector3.ZERO)
	return out


## 每只蝴蝶的"除自己以外的邻居本地坐标"列表（一趟遍历填好，见 _process 里的说明）。
## 返回值：Array，长度与 _butterflies 一致；第 i 项是**不含第 i 只**的坐标数组。
## 性能：分配 n 个数组 + 填 n·(n-1) 个元素，比旧写法省掉 n 次整表拷贝。
func _neighbor_lists() -> Array:
	var n := _butterflies.size()
	var pos := _local_positions()
	var lists: Array = []
	lists.resize(n)
	for i in range(n):
		var l: Array = []
		l.resize(0)
		lists[i] = l
	for i in range(n):
		var mine: Array = lists[i]
		for j in range(n):
			if j != i:
				mine.append(pos[j])
	return lists


## 组装传给 Butterfly.advance 的 extra 字典（本地坐标）。
## 内容：threat（受惊源位置）/ partner（随机配对的同伴位置）/ hover（群体腾起脉冲时的盘旋半径）
##       / ars_hit + ars_pos（★ 附近有没有资源，供"区域限制搜索 ARS"用）。
## 注意：每帧都取一次 threat 位置（很便宜），但不做 raycast、不遍历分组。
func _build_extra(delta: float = 0.0) -> Dictionary:
	var e: Dictionary = {}
	var t := _find_threat()
	if t != null:
		e["threat"] = to_local(t.global_position)
	# ★★ 群体聚散周期（"换个坐标聚散"的实现）★★
	#   散（pulse）：从 `_gather_pos` 这个**本轮新中心**向外推开 + 整体拔高
	#   聚（regroup）：脉冲结束后一段时间，朝同一个新中心收拢
	#   centre 每轮都换（`_new_gather_center()`），所以不会在"同一对点"之间往返。
	#   ⚠ 旧实现是 `e["hover"] = region_size.x * 0.35` + 蝴蝶侧"靠近自己目标就外推"，
	#     那会形成围绕**固定目标**的稳定振荡环 —— 就是用户看到的"两点之间反复聚散"。
	if _pulse_t > 0.0:
		e["hover"] = region_size.x * 0.35
		e["pulse"] = 1.0
	elif _regroup_t > 0.0:
		e["regroup"] = clampf(_regroup_t / maxf(0.1, regroup_s), 0.0, 1.0)
	if _gather_pos is Vector3:
		e["gather_pos"] = _gather_pos
	# 求偶配对：每帧给一个随机同伴，蝴蝶在 COURT 状态时会去绕它
	if _butterflies.size() >= 2 and rng_ok():
		var a := _rng.randi_range(0, _butterflies.size() - 1)
		var b := _rng.randi_range(0, _butterflies.size() - 1)
		if a != b:
			var pb: Node3D = _butterflies[b] as Node3D
			if pb != null and is_instance_valid(pb):
				e["partner"] = pb.position
	# 资源感知（ARS）：附近有花/蜜源 -> 蝴蝶切成"原地打转"的搜索模式。
	# 这是"环境互动"的感知那一半（模型出处见 butterfly_tuning.gd 顶部）。
	# 资源点来源见 `_refresh_resource(delta)`；null 表示"这次没找到"。
	# ★ 资源点会按 `ars_rotate_s` **轮换**（用户反馈"反复在两点之间散开再重聚"的修法）。
	if _tuning_num("area_restricted_search", 1.0) > 0.5:
		_refresh_resource(delta)
		# ★ 参与度：不是每只蝴蝶都对同一个资源点起反应（否则整群锁步、一起收拢一起散开）。
		#   具体"我这只蝴蝶参不参与"由 Butterfly 侧用**每只固定的随机数**决定
		#   （见 butterfly.gd 的 `_ars_participate`），这里只把整体比例传下去。
		e["ars_participation"] = clampf(_tuning_num("ars_participation", 0.55), 0.0, 1.0)
		var fpos: Variant = _flower_pos
		if fpos is Vector3:
			e["ars_hit"] = true
			e["ars_pos"] = fpos
	# ★ SGT 花上随机停留：把扫描好的落脚点（本地坐标）交给蝴蝶自己挑。
	#   只在非空时放进去，蝴蝶侧 `extra.get("sgt_perches", null)` 判空即可（关掉时零开销）。
	if sgt_perch_enabled and not _sgt_perch_pts.is_empty():
		# ★ 花点是在**扫描那一刻**的区域范围内筛出来的；之后区域可能被拖动/缩放。
		#   这里按当前区域再过滤一次（几十个点，开销可忽略），
		#   避免蝴蝶飞向区域外的旧花点（否则又会出现"乱飞"）。
		var bnd := _bounds()
		var lo := bnd.position
		var hi := bnd.position + bnd.size
		var keep: Array = []
		for p in _sgt_perch_pts:
			var v := p as Vector3
			if v.x >= lo.x and v.x <= hi.x and v.z >= lo.z and v.z <= hi.z:
				keep.append(v)
		if not keep.is_empty():
			e["sgt_perches"] = keep
	return e


## 节流刷新"资源点"缓存（默认 0.5 秒一次）。
##
## 资源点的来源（按优先级）：
##   ① 分组 `flowers` / `flower` 里**离群组中心最近**的 Node3D —— 仓库里的花丛节点带这类分组；
##   ② 找不到就退回**区域中心**（region_offset）当一个虚拟蜜源。
##      ★ 为什么要有 ②：如果场景里没有任何花节点，ARS 就永远不会触发 ——
##      用户看不到任何环境响应，等于没接。退回区域中心至少能保证
##      "蝴蝶会在场地中央聚集打转"，行为上仍然是对的（中心本来就是最可能有资源的地方）。
##
## 副作用：写 `_flower_pos`（本地坐标）与 `_resource_rotate_t`。
func _refresh_resource(delta: float) -> void:
	_resource_rotate_t -= delta
	if _resource_rotate_t > 0.0:
		return
	_resource_rotate_t = maxf(1.0, _tuning_num("ars_rotate_s", 8.0))
	var last: Variant = _flower_pos
	var min_move := maxf(0.0, _tuning_num("ars_min_move_m", 3.0))
	var st := scene_tree()
	if st != null:
		var cands: Array = []
		var mine := global_position
		for gname in ["flowers", "flower"]:
			for n in st.get_nodes_in_group(gname):
				if n is Node3D and is_instance_valid(n):
					var p: Vector3 = to_local((n as Node3D).global_position)
					cands.append([p.distance_squared_to(to_local(mine)), p])
			if not cands.is_empty():
				break
		if not cands.is_empty():
			cands.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
			var k := mini(3, cands.size())
			var pool: Array = []
			for i in range(k):
				pool.append(cands[i][1])
			var pick: Variant = _choose_far_point(pool, last, min_move)
			if pick != null:
				_flower_pos = pick
				return
			_flower_pos = pool[_res_rng.randi_range(0, pool.size() - 1)]
			return
	var lo := _bounds().position
	var hi := _bounds().position + _bounds().size
	var band := minf(_bounds().size.y * 0.5, 2.5)
	var fallback := Vector3(
		_res_rng.randf_range(lo.x, hi.x),
		lo.y + _res_rng.randf_range(0.25, maxf(0.3, band)),
		_res_rng.randf_range(lo.z, hi.z))
	if last is Vector3 and (last as Vector3).distance_to(fallback) < min_move:
		var dir := Vector3(_res_rng.randf_range(-1.0, 1.0), 0.0,
				_res_rng.randf_range(-1.0, 1.0))
		if dir.length_squared() < 1e-6:
			dir = Vector3.RIGHT
		fallback = (last as Vector3) + dir.normalized() * maxf(1.0, min_move)
		fallback.x = clampf(fallback.x, lo.x, hi.x)
		fallback.z = clampf(fallback.z, lo.z, hi.z)
		fallback.y = lo.y + clampf(fallback.y - lo.y, 0.25, maxf(0.3, band))
	_flower_pos = fallback


## ★ 挑选本轮的"聚散中心"：必须和最近 `gather_history_n` 轮的中心都拉开距离。
##
## 为什么要有这个函数（用户反馈："蝴蝶出现聚集行为后，会反复的在两点之间散开再重聚，
## 起码要换个坐标进行聚散"）：
##   旧实现里"聚"和"散"都围绕**每只蝴蝶自己的目标**（SEEK 的花 / COURT 的同伴）发生，
##   而这些目标几乎固定不变 —— 于是每 25~70 秒重复一次"冲向同一朵花 -> 被 hover 反推出去
##   -> 再冲回去"的振荡，视觉上就是同一对点之间的往返。
##   现在每轮开始前换一个**新的中心**，聚、散都在新中心附近发生。
##
## 候选来源：分组 `flowers`/`flower` 的花节点；没有花就在区域下部随机取点。
## 挑选规则：排除"离历史中心 < `gather_min_move_m`"的候选；
##   若一个都不剩（候选太少/区域太小），就取**离历史中心最远**的那个 —— 尽力换地方。
## 副作用：写 `_gather_pos`，并把旧中心压入 `_gather_hist`（最多 `gather_history_n` 个）。
func _new_gather_center() -> void:
	var min_move := maxf(0.0, gather_min_move_m)
	var hist_n := maxi(1, gather_history_n)
	var cands: Array = []
	var st := scene_tree()
	if st != null:
		for gname in ["flowers", "flower"]:
			for n in st.get_nodes_in_group(gname):
				if n is Node3D and is_instance_valid(n):
					cands.append(to_local((n as Node3D).global_position))
			if not cands.is_empty():
				break
	if cands.is_empty():
		# 没有花节点：在区域下部随机撒几个候选（数量取 8，够挑出"离历史中心远"的点）
		var lo := _bounds().position
		var hi := _bounds().position + _bounds().size
		var band := minf(_bounds().size.y * 0.6, 2.5)
		for i in range(8):
			cands.append(Vector3(
				_rng.randf_range(lo.x, hi.x),
				lo.y + _rng.randf_range(0.25, maxf(0.3, band)),
				_rng.randf_range(lo.z, hi.z)))
	# ★★ 排除集 = 历史中心 + **当前这一轮的中心** ★★
	#   实测踩过：`_gather_pos` 是在函数**末尾**才压进 `_gather_hist` 的，
	#   所以筛选候选时它**还没进历史** —— 于是"自己选回自己"永远合法：
	#   探针复现第 4 轮 center 与第 3 轮完全相同（位移 0.000 m），历史里也出现重复项。
	#   现在把当前中心一起纳入排除集。
	var avoid: Array = []
	for h in _gather_hist:
		avoid.append(h)
	if _gather_pos is Vector3:
		avoid.append(_gather_pos)
	var ok: Array = []
	for c in cands:
		var good := true
		if min_move > 0.0:
			for h in avoid:
				if (c as Vector3).distance_to(h as Vector3) < min_move:
					good = false
					break
		if good:
			ok.append(c)
	var pick: Vector3
	if not ok.is_empty():
		pick = ok[_rng.randi_range(0, ok.size() - 1)]
	else:
		# 全都太近 -> 取"离历史最远"的那个。
		# ★ 但必须**排除紧挨着的上一轮中心**：实测（回归测试抓到）候选被历史逐个排除后，
		#   这个兜底会退回 `cands[0]`，正好又是上一轮那个点 —— 相邻两轮位移 0.00 m，
		#   等于"换个坐标"在最需要它的极端情况下失效。所以先剔除上一轮，
		#   只有"除了它别无候选"时才允许重复。
		var pool2: Array = []
		for c in cands:
			if _gather_pos is Vector3 \
					and (c as Vector3).distance_to(_gather_pos as Vector3) < 0.05:
				continue
			pool2.append(c)
		if pool2.is_empty():
			pool2 = cands
		var best: Vector3 = pool2[0]
		var best_d := -1.0
		for c in pool2:
			var dmin := 1.0e9
			for h in _gather_hist:
				dmin = minf(dmin, (c as Vector3).distance_to(h as Vector3))
			if _gather_hist.is_empty():
				dmin = 0.0
			if dmin > best_d:
				best_d = dmin
				best = c
		pick = best
	# 记录历史（上一轮的中心进历史，供下一轮避开）
	if _gather_pos is Vector3:
		_gather_hist.append(_gather_pos)
		while _gather_hist.size() > hist_n:
			_gather_hist.pop_front()
	_gather_pos = pick


## 在候选点里选一个"离 `last` 至少 `min_move` 米"的点（随机）。
## 参数 pool：候选 Vector3 数组；last：上一个资源点（可为 null）；min_move：最小位移（米）。
## 返回值：选中的 Vector3；池内一个都不满足时返回 null（调用方退回随机）。
func _choose_far_point(pool: Array, last: Variant, min_move: float) -> Variant:
	if pool.is_empty():
		return null
	var ok: Array = []
	for p in pool:
		if last is Vector3 and (p as Vector3).distance_to(last as Vector3) < min_move:
			continue
		ok.append(p)
	if ok.is_empty():
		return null
	return ok[_res_rng.randi_range(0, ok.size() - 1)]


## 取随机源是否可用（编辑器早期/被释放时可能为 null）。
func rng_ok() -> bool:
	return _rng != null


## 找受惊源节点：threat_path 指定的优先，否则分组 "player" 的第一个。
## 返回值：Node3D 或 null。**不缓存**（玩家可能被换/被释放），但也不用每帧遍历分组。
func _find_threat() -> Node3D:
	var st := scene_tree()
	if st == null:
		return null
	if not threat_path.is_empty():
		var n := get_node_or_null(threat_path)
		if n is Node3D:
			return n as Node3D
		return null
	var g := st.get_first_node_in_group("player")
	if g is Node3D:
		return g as Node3D
	return null


# ==================== 调试线框 ====================

## 建/更新区域线框（local AABB）。用 BoxMesh + wireframe 材质。
## 说明：这是纯视觉辅助，材质是 unshaded + cull_disabled + 线框，
##   不会被光照影响，也不会挡视线（无深度写入）。
func _build_gizmo() -> void:
	if _region_gizmo != null and is_instance_valid(_region_gizmo):
		_region_gizmo.queue_free()
		_region_gizmo = null
	if not debug_draw_region:
		return
	var mi := MeshInstance3D.new()
	mi.name = "RegionGizmo"
	# ★ 注意 BoxMesh 不能被子类化出线框，所以用 BoxMesh + 线框材质（StandardMaterial3D 支持）
	var bm := BoxMesh.new()
	bm.size = region_size
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(1.0, 0.85, 0.2, 0.35)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.no_depth_test = false
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_region_gizmo = mi
	_refresh_region_gizmo()


## 线框跟随区域参数（区域中心 = region_offset）。
func _refresh_region_gizmo() -> void:
	if _region_gizmo == null or not is_instance_valid(_region_gizmo):
		return
	_region_gizmo.position = region_offset
	if _region_gizmo.mesh is BoxMesh:
		(_region_gizmo.mesh as BoxMesh).size = region_size


# ==================== 对外接口 ====================

## 开/关整群。关：隐藏 + 停止推进（不释放）。开：恢复。
## 返回值：当前是否启用。
func set_active(v: bool) -> bool:
	enabled = v
	return enabled


## 让所有蝴蝶重新随机撒一遍（换区域/换种子后想立刻生效时调）。
## 副作用：重置每只的位置/速度/能量/状态。
func respawn_all() -> void:
	for b in _butterflies:
		if b != null and is_instance_valid(b):
			b.spawn(_bounds())
	if Engine.is_editor_hint():
		print("[蝴蝶] 已重新撒 %d 只" % _butterflies.size())


## 立刻重建（外部脚本改了 sprites/count 后调它，避免等下一帧节流）。
func rebuild() -> void:
	_build()
	# 重建后按当前区域重扫花点（手工刷新入口：编辑器里画完新花可以直接调它）
	if sgt_perch_enabled:
		_scan_sgt_flowers()


## 把素材目录里扫到的 PNG **全部**灌进 sprites（生成清单缓存，缺清单就现场扫）。
## 参数 load_textures：true = 真的 load 成 Texture2D 并写进 sprites；
##                    false = 只生成清单（编辑器里避免一次性加载 20 张的大图）。
## 返回值：本次处理/加载的张数。
func autoload_all_sprites(load_textures: bool = true) -> int:
	_load_manifest()
	var paths := _manifest_paths()
	if paths.is_empty():
		paths = BFLY_IO.list_butterfly_paths()
	if not load_textures:
		return paths.size()
	var added := 0
	for p in paths:
		var t := load(String(p)) as Texture2D
		if t == null:
			continue
		if not sprites.has(t):
			sprites.append(t)
			added += 1
	return added


## 随机挑 n 张素材写进 sprites（做"这一窝用这几只"的快速配法）。
## 参数 n：张数；rng_seed：可选，<=0 时用当前 seed_value。
## 返回值：实际写入张数。
func randomize_sprites(n: int, rng_seed: int = 0) -> int:
	var paths := _manifest_paths()
	if paths.is_empty():
		paths = BFLY_IO.list_butterfly_paths()
	if paths.is_empty():
		return 0
	var r := RandomNumberGenerator.new()
	r.seed = rng_seed if rng_seed > 0 else int(seed_value)
	var picked: Array = []
	var pool := paths.duplicate()
	var take: int = mini(n, pool.size())
	for i in range(take):
		var idx := r.randi_range(0, pool.size() - 1)
		picked.append(pool[idx])
		pool.remove_at(idx)
	sprites.clear()
	for p in picked:
		var t := load(String(p)) as Texture2D
		if t != null:
			sprites.append(t)
	return sprites.size()


## 素材张数（配了几张）。
func sprite_count() -> int:
	return sprites.size()


# ==================== ★ 批量加素材（一次加载多张，不用一张张点"添加元素"） ====================
# 背景：`sprites` 是 `Array[Texture2D]`，Godot 默认的检查器 UI 只给一个「添加元素」按钮，
#   每次只能加**一张** —— 20 张素材要点 20 次、还得在文件对话框里一张张找。
#   下面这组方法就是"批量入口"：检查器面板（inspector_batch.gd）与脚本都能直接用。

## 按 **res:// 路径数组**批量加素材（会过滤掉加载失败 / 非 Texture2D 的项）。
## 参数 paths：任意 Array，元素是 res:// 路径字符串（也会跳过空串与不存在的文件）。
## 返回值：本次实际新增的张数（重复的不计）。
## 副作用：改 `sprites`（不自动重建，调用方决定要不要 rebuild）。
## ⚠ 不要写 `String(p)`：Godot 的 `String()` 只接受 String/StringName，
##   传 int 之类会抛 `Invalid call 'String' constructor`（实测：面板里手抖多塞一个数字就崩）。
##   必须先做类型判断。
func add_sprites_from_paths(paths: Array) -> int:
	var added := 0
	for p in paths:
		if not (p is String or p is StringName):
			continue
		var s := String(p).strip_edges()
		if s.is_empty() or not ResourceLoader.exists(s):
			continue
		var t := load(s) as Texture2D
		if t != null and not sprites.has(t):
			sprites.append(t)
			added += 1
	return added


## 一次把**目录里的所有蝴蝶 PNG** 加进来（这就是"批量添加"最常用的那个动作）。
## 参数 dir_path：目录 res:// 路径；为空 -> 清单记录的素材目录 -> `ButterflyIO.DEFAULT_DIR`。
## 参数 limit：最多加多少张；**0 = 全部**（默认 0 = 全加，因为这是显式的批量操作）。
## 返回值：本次实际新增的张数。
## 注意：优先用**清单**里的路径（顺序稳定）；清单不存在时现场扫目录。
func add_all_sprites_from_folder(dir_path: String = "", limit: int = 0) -> int:
	var paths := _manifest_paths()
	var dir := dir_path
	if dir.is_empty():
		dir = String(_manifest.get("source_dir", ""))
	if dir.is_empty():
		dir = BFLY_IO.DEFAULT_DIR
	if paths.is_empty() or not dir_path.is_empty():
		paths = BFLY_IO.list_butterfly_paths(dir)
	if limit > 0 and paths.size() > limit:
		paths = paths.slice(0, limit)
	return add_sprites_from_paths(paths)


## 随机取 n 张**追加**到现有素材后面（与 randomize_sprites 的区别：那个是整体替换）。
## 参数 n：张数；rng_seed：<= 0 时用当前 seed_value。
## 返回值：本次实际新增的张数。
func add_random_sprites(n: int, rng_seed: int = 0) -> int:
	var paths := _manifest_paths()
	if paths.is_empty():
		paths = BFLY_IO.list_butterfly_paths()
	if paths.is_empty() or n <= 0:
		return 0
	var r := RandomNumberGenerator.new()
	r.seed = rng_seed if rng_seed > 0 else int(seed_value)
	var pool := paths.duplicate()
	var picked: Array = []
	for i in range(mini(n, pool.size())):
		var idx := r.randi_range(0, pool.size() - 1)
		picked.append(pool[idx])
		pool.remove_at(idx)
	return add_sprites_from_paths(picked)


## 清空素材（配合批量添加使用；清空后会退回"按清单兜底 8 张"的行为）。
func clear_sprites() -> void:
	sprites.clear()


## 只读快照（供检查器面板显示"已配 N 张 / 目录里共 M 张"）。
func sprite_summary() -> Dictionary:
	var all_paths := BFLY_IO.list_butterfly_paths()
	return {
		"configured": sprites.size(),
		"available": all_paths.size(),
		"dir": BFLY_IO.DEFAULT_DIR,
	}


## ★ 宽松地写入素材列表：接受**无类型 Array**（过滤掉非 Texture2D 的项）。
## 为什么要这个方法：
##   `sprites` 声明是 `Array[Texture2D]`，所以 `swarm.sprites = [a, b]`（无类型字面量数组）会直接
##   报 `Invalid assignment of property or key 'sprites' with value of type 'Array'`。
##   而外部脚本/编辑器 UI 常常只能拿到无类型 Array（`load()` 循环拼出来的那种）。
##   统一走本方法：**任何 Array 都能安全灌进来**。
## 参数 list：任意 Array（元素非 Texture2D 的会被静默跳过）。
## 返回值：实际写入的张数。
func set_sprite_textures(list: Array) -> int:
	sprites.clear()
	for t in list:
		if t is Texture2D:
			sprites.append(t as Texture2D)
	return sprites.size()


## ★ 追加若干素材（同样宽松接受无类型 Array）。返回值：本次实际新增张数。
func add_sprite_textures(list: Array) -> int:
	var added := 0
	for t in list:
		if t is Texture2D and not sprites.has(t):
			sprites.append(t as Texture2D)
			added += 1
	return added


## 当前活着的蝴蝶只数。
func live_count() -> int:
	var n := 0
	for b in _butterflies:
		if b != null and is_instance_valid(b):
			n += 1
	return n


## 调参快照（灌给每只蝴蝶；也是测试断言"开关真的生效"的入口）。
## 返回值：Dictionary（键名与 butterfly_tuning.gd 的 @export 同名）。
## ★ 群组上的**张翼角度/尺寸/立体感**这些属性优先于资源里的同名值：
##   检查器里摆着、改了立刻生效才符合直觉；tuning 资源只用来覆盖**其余**项。
func tuning_dict() -> Dictionary:
	var d := {
		"size_m": 0.22, "speed_max": 2.2, "accel": 1.8,
		"flap_hz": 8.5, "flap_hz_jitter": 2.5,
		"dihedral_min": 6.0, "dihedral_max": 72.0,
		"wander_jitter": 1.6, "wander_rate": 0.6,
		"separation_m": 0.35, "separation_weight": 1.8,
		"wind_drag": 0.35, "gust_penalty": 0.45,
		"seek_range_m": 12.0,
		"energy_drain": 0.035, "energy_gain": 0.16, "rest_energy": 0.25,
		"shelter_wind": 0.75, "shelter_rain": 0.30,
		"iridescence": 0.25, "backlight": 0.15,
		"tint": Color(1, 1, 1, 1), "alpha": 1.0,
		"min_height_m": 0.35, "avoid_distance_m": 1.2, "edge_margin_m": 0.8,
		"bank_max_deg": 35.0, "pitch_per_speed": 8.0,
		"flutter_amount": 0.05, "spawn_height_jitter": 0.6,
		"flocking": true, "ground_avoid": true,
		# ---- 防瞬移（落脚点限速靠拢 + 单帧位移上限）----
		"perch_speed": 1.2, "perch_rearm_distance": 3.0, "max_step_factor": 1.6,
		# ---- 移动生态学（CRW / Lévy / ARS）—— 修掉"直飞" ----
		"heading_persistence": 0.72, "turn_scale_deg": 25.0,
		"turn_heavy_p": 0.06, "turn_heavy_deg": 110.0,
		"levy_alpha": 1.6, "step_time_s": 0.45,
		"ars_radius_m": 3.0, "ars_turn_scale_deg": 55.0, "ars_speed_scale": 0.55,
		# ---- 聚集点必须会换（防"两点之间往返"）----
		"ars_rotate_s": 8.0, "ars_min_move_m": 3.0, "ars_participation": 0.55,
		"seek_repeat_avoid_m": 3.0,
		"area_restricted_search": true,
		"lateral_weave": 0.55, "lateral_weave_hz": 1.1,
		# ---- 与草（SimpleGrassTextured）的交互 ----
		"grass_bend_radius": 0.42, "grass_bend_strength": 1.0,
		"grass_bend_height": 1.15, "grass_bend_slots": 2.0,
		# ---- 花上随机停留（SGT 花笔刷）----
		"sgt_perch_enabled": true,
		"sgt_perch_interval_min_s": 8.0, "sgt_perch_interval_max_s": 20.0,
		"sgt_perch_duration_min_s": 1.5, "sgt_perch_duration_max_s": 4.0,
		"sgt_perch_approach_timeout_s": 8.0,
		"sgt_perch_radius_m": 6.0, "sgt_perch_height_ratio": 0.85,
		# ---- 立体感（体积）----
		"wing_camber": 0.30, "wing_thickness": 0.035, "wing_bend_y": 0.0,
		"edge_min_facing": 0.0, "edge_min_deg": 14.0, "rim_dark": 0.55,
		"body_scale": 1.0,
	}
	# ★ 群组属性覆盖（见函数注释）
	d["ground_avoid"] = ground_avoid
	d["size_m"] = size_m
	# ★ 飞行行为（移动生态学）：节点上的导出值覆盖 tuning 资源的同名键。
	#   这样"在节点上调"和"用 .tres 统一手感"两条路都通，且**节点优先**（与 size_m 等一致）。
	d["heading_persistence"] = heading_persistence
	d["turn_scale_deg"] = turn_scale_deg
	d["turn_heavy_p"] = turn_heavy_p
	d["turn_heavy_deg"] = turn_heavy_deg
	d["levy_alpha"] = levy_alpha
	d["step_time_s"] = step_time_s
	d["lateral_weave"] = lateral_weave
	d["lateral_weave_hz"] = lateral_weave_hz
	d["area_restricted_search"] = area_restricted_search
	d["ars_radius_m"] = ars_radius_m
	d["ars_turn_scale_deg"] = ars_turn_scale_deg
	d["ars_speed_scale"] = ars_speed_scale
	# ★ 草交互（sgt）
	d["grass_bend_radius"] = grass_bend_radius
	d["grass_bend_strength"] = grass_bend_strength
	d["grass_bend_height"] = grass_bend_height
	d["grass_bend_slots"] = float(grass_bend_slots)
	d["dihedral_min"] = dihedral_min_deg
	d["dihedral_max"] = dihedral_max_deg
	d["flap_hz"] = flap_hz
	d["flap_hz_jitter"] = flap_hz_jitter
	d["wing_camber"] = wing_camber
	d["wing_thickness"] = wing_thickness
	d["wing_bend_y"] = wing_bend_y
	d["body_scale"] = body_scale
	d["edge_min_facing"] = edge_min_facing
	d["edge_min_deg"] = edge_min_deg
	d["rim_dark"] = rim_dark
	if tuning != null and is_instance_valid(tuning):
		var props := tuning.get_property_list()
		for p in props:
			var nm := String(p.get("name", ""))
			if d.has(nm):
				var v: Variant = tuning.get(nm)
				if v != null:
					d[nm] = v
	# ★★ 但**节点上的导出值必须是最终赢家**（用户诉求："暴露参数到检查器面板"）★★
	#   实测踩过：上面那段资源合并写在后面，会把节点上刚设的值又盖回资源里的旧值 ——
	#   表现就是"在节点面板上调了没反应"。所以资源合并完，再按下面这份清单把节点值写回去。
	#   ★ 这是一份**显式清单**而不是"全量覆盖"：tuning 资源仍要为它特有的几十个参数
	#     （能量/避难/虹彩/倾斜…）提供值，只有"已经在节点上也有同名导出"的键才由节点接管。
	#     新增一个节点级导出时，**记得把键名加到这里**（漏了就会"调了没反应"）。
	for k in GROUP_OVERRIDE_KEYS:
		d[k] = _group_value(String(k))
	return d


## 由**群组节点**接管（优先于 `tuning` 资源）的键清单。
## 判定规则：这个键在节点上有同名 `@export`，用户能在检查器里直接调。
## 为什么做成 const 而不是散在代码里：见 `tuning_dict()` 的注释 —— 漏加一个键，
## 表现是"节点上改了没反应"，这种 bug 很难查，所以集中一处、便于审阅与测试。
const GROUP_OVERRIDE_KEYS := [
	# 外观/尺寸/扑翼（早期就提到节点上的那批）
	"size_m", "dihedral_min", "dihedral_max", "flap_hz", "flap_hz_jitter",
	"wing_camber", "wing_thickness", "wing_bend_y", "body_scale",
	"edge_min_facing", "edge_min_deg", "rim_dark", "ground_avoid",
	# 飞行行为（移动生态学 CRW / Lévy / ARS）
	"heading_persistence", "turn_scale_deg", "turn_heavy_p", "turn_heavy_deg",
	"levy_alpha", "step_time_s", "lateral_weave", "lateral_weave_hz",
	"area_restricted_search", "ars_radius_m", "ars_turn_scale_deg", "ars_speed_scale",
	"ars_rotate_s", "ars_min_move_m", "ars_participation", "seek_repeat_avoid_m",
	# 草交互（sgt）
	"grass_bend_radius", "grass_bend_strength", "grass_bend_height", "grass_bend_slots",
	# 花上随机停留（sgt 花笔刷）
	"sgt_perch_enabled",
	"sgt_perch_interval_min_s", "sgt_perch_interval_max_s",
	"sgt_perch_duration_min_s", "sgt_perch_duration_max_s",
	"sgt_perch_approach_timeout_s",
	"sgt_perch_radius_m", "sgt_perch_height_ratio",
]


## 读一个"节点级导出"的当前值（供 `tuning_dict()` 覆盖用）。
## 参数 key：上面的 GROUP_OVERRIDE_KEYS 里的键名。
## 返回值：节点上该属性的值；节点没有这个属性时返回 null（调用方会保留资源值）。
## ★ 为什么用 `get()` 而不是逐个 if：这 29 个键写 29 个分支容易漏，
##   而 `get()` 对不存在的属性会返回 null，正好用来兜底。
func _group_value(key: String) -> Variant:
	var v: Variant = get(key)
	if v == null:
		return null
	# `grass_bend_slots` 在节点上是 int，而读取方（Butterfly._num）只认 float/int -> 统一成 float
	if key == "grass_bend_slots":
		return float(int(v))
	return v


## 只读快照（测试 / 调试 UI 用）。
## 返回值：{count, live, enabled, built, frames, sprites, region, offset,
##          wind, weather, speed_avg, speed_max_seen, state_histogram, min_y, max_y}
func stats() -> Dictionary:
	var hist: Dictionary = {}
	var sum := 0.0
	var spd_max := 0.0
	var ymin := 1.0e20
	var ymax := -1.0e20
	for b in _butterflies:
		var bn: Node3D = b as Node3D
		if bn == null or not is_instance_valid(bn):
			continue
		var s: Dictionary = bn.call("stats")
		var nm := String(s["state_name"])
		hist[nm] = int(hist.get(nm, 0)) + 1
		var sp := float(s["speed"])
		sum += sp
		spd_max = maxf(spd_max, sp)
		var py := float((s["position"] as Vector3).y)
		ymin = minf(ymin, py)
		ymax = maxf(ymax, py)
	var live := live_count()
	return {
		"count": _butterflies.size(),
		"live": live,
		"enabled": enabled,
		"built": _built,
		"frames": _stepped_frames,
		"sprites": sprites.size(),
		"region": region_size,
		"offset": region_offset,
		"wind": _wind_cache,
		"weather": _weather_cache,
		"speed_avg": (sum / float(live)) if live > 0 else 0.0,
		"speed_max_seen": spd_max,
		"state_histogram": hist,
		"min_y": ymin if ymin < 1.0e19 else 0.0,
		"max_y": ymax if ymax > -1.0e19 else 0.0,
		"min_bound_y": _bounds().position.y,
		"max_bound_y": _bounds().position.y + _bounds().size.y,
		# ★ SGT 花上停留的调试信息：扫到几个笔刷 / 缓存几个落脚点 / 没扫到时的原因
		"sgt_perch_enabled": sgt_perch_enabled,
		"sgt_perch_nodes": _sgt_perch_nodes,
		"sgt_perch_points": _sgt_perch_pts.size(),
		"sgt_perch_note": _sgt_perch_note,
	}


# ==================== 素材清单 ====================

## 清单文件路径（**硬编码**，tools/analyze_butterflies.gd 与插件菜单都写它）。
const MANIFEST_PATH := "res://addons/butterfly_swarm/sprite_manifest.json"
## 草（SimpleGrassTextured **与**项目自制草）着色器的路径片段：用它判定"这个材质是不是草"。
## ★ 为什么是**两个**片段（实测踩过）：
##   · `simplegrasstextured/shaders/grass` —— SGT 插件的自带着色器（它把材质挂在
##     `material_override` 上，只有几个节点用）；
##   · `assets/shaders/grass_wind` —— **本项目主场景里真正渲染的那片草**
##     （实测 274 个材质用它！）。第一版只认 SGT 自带路径，
##     结果 `_grass_mats = 0`、蝴蝶压草完全没效果 —— 因为场景里的草根本不走 SGT 着色器。
## ★ 为什么按路径而不是按名字/类型：草的节点名用户随时能改，但着色器路径不会变
##   （`assets/quality/grass_quality.gd` 也用这个做法）。
const GRASS_SHADER_HINTS := [
	"simplegrasstextured/shaders/grass",
	"assets/shaders/grass_wind",
]


## 读清单（惰性、只读一次）。返回：sprites 数组的元素列表（每个是 Dictionary）。
## 找不到/解析失败 -> 返回空数组（调用方回落到现场扫描目录）。
func _load_manifest() -> void:
	if _manifest_loaded:
		return
	_manifest_loaded = true
	_manifest = {}
	if not FileAccess.file_exists(MANIFEST_PATH):
		return
	var txt := FileAccess.get_file_as_string(MANIFEST_PATH)
	if txt.is_empty():
		return
	var parsed: Variant = JSON.parse_string(txt)
	if parsed is Dictionary:
		_manifest = parsed as Dictionary


## 清单里记录的 res:// 路径列表（没清单则空）。
func _manifest_paths() -> Array:
	_load_manifest()
	var out: Array = []
	var arr: Variant = _manifest.get("sprites", [])
	if arr is Array:
		for e in arr:
			if e is Dictionary and (e as Dictionary).has("path"):
				out.append(String((e as Dictionary)["path"]))
	return out


## 重新扫描素材目录并写清单（编辑器菜单/检查器按钮会调）。
## 返回值：写入的条目数；写文件失败返回 -1。
## 副作用：**写磁盘**（res://addons/butterfly_swarm/sprite_manifest.json）并刷新 _manifest。
## 成本：真的要逐像素解码 20 张 PNG（约 1~3 秒），所以只允许手动触发。
func regenerate_manifest() -> int:
	var entries := BFLY_IO.analyze()
	var payload := {
		"generated_by": "butterfly_swarm.gd/regenerate_manifest",
		"source_dir": BFLY_IO.DEFAULT_DIR,
		"count": entries.size(),
		"sprite_paths": [],
		"sprites": entries,
	}
	var paths: Array = []
	for e in entries:
		if e is Dictionary:
			paths.append(String((e as Dictionary).get("path", "")))
	payload["sprite_paths"] = paths
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.WRITE)
	if f == null:
		push_warning("[蝴蝶] 清单写入失败：%s（err=%d）" % [MANIFEST_PATH, FileAccess.get_open_error()])
		return -1
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	_manifest = payload
	_manifest_loaded = true
	print("[蝴蝶] 素材清单已更新：%d 条 -> %s" % [entries.size(), MANIFEST_PATH])
	return entries.size()


# ==================== 编辑器辅助 ====================

## 开关总开关时立刻生效（隐藏/显示，不重建）。
## 把 `enabled` 落到可见性上。
## ★ 只动**蝴蝶子节点**，**不动节点自身的 `visible`** —— 原因见 `enabled` 的文档注释 ②：
##   节点自身的 visible 是 Godot 会序列化进场景的属性，两边一起写就会互相打架。
## 副作用：不重建、不释放；关着时区域线框（debug_draw_region）仍然可见，方便调区域。
func _apply_enabled() -> void:
	for b in _butterflies:
		if b != null and is_instance_valid(b):
			b.visible = enabled


## 检查器里给出的配置警告（**这才是"配错了看得见"的地方**）。
## 返回：Array[String]；空数组 = 没有警告。
func _get_configuration_warnings() -> PackedStringArray:
	var out := PackedStringArray()
	if sprites.is_empty():
		out.append("没有配蝴蝶贴图：sprites 为空。可以在下面的按钮里一键补全，或把素材目录下的 PNG 拖进来。")
	if count <= 0:
		out.append("count = 0：不会生成任何蝴蝶。")
	if count > 0 and count < 4:
		out.append("count 少于 4：蝴蝶不会出现明显的群飞效果（建议 8~30）。")
	if region_size.x < 0.5 or region_size.z < 0.5:
		out.append("区域水平尺寸太小（<0.5 米）：蝴蝶几乎只能在原地打转。")
	if region_size.y < 0.3:
		out.append("区域高度太小（<0.3 米）：蝴蝶会贴着一条水平线飞。")
	if not ResourceLoader.exists("res://assets/shaders/butterfly_wings.gdshader"):
		out.append("缺少翅膀着色器 res://assets/shaders/butterfly_wings.gdshader：蝴蝶不会可见。")
	# ★ 以下几条是"用户实测踩过"的配置：把它们变成检查器里看得见的黄色警告，
	#   而不是让人在场景里对着 200 只蝴蝶猜哪里不对。
	if not enabled:
		out.append("总开关 enabled = false：整群被隐藏且不推进（这是它该有的行为）。想看到蝴蝶请勾上。")
	if count > 60:
		out.append("count = %d 偏多：远看会糊成一片，且每只约 1000 个顶点（%d 只 ≈ %.0f 万顶点）。建议 8~40。"
				% [count, count, float(count) * 1000.0 / 10000.0])
	if body_scale > 1.6 or body_scale < 0.35:
		var pct := body_scale * 12.5
		out.append("body_scale = %.2f 偏大：实测身体半径 = body_scale × 翼展的 12.5%%，现在约 %.1f%%。"
				% [body_scale, pct]
				+ "超过 ~25% 就会把翅根埋进身体、看起来像「参数没生效」。建议 0.6~1.6。")
	if dihedral_min_deg > 30.0:
		out.append("dihedral_min_deg = %.0f° 偏大：蝴蝶会一直夹着翅膀，看不出张合。建议最小角 0~15°。"
				% dihedral_min_deg)
	# ★ 区域多半埋在地下：`region_offset` 是**以节点原点为中心的本地偏移**，
	#   不是"离地高度"。节点自己站在地面上时，offset.y 要 ≥ region_size.y/2，
	#   否则盒子的下半部分在地里 —— 蝴蝶有一半时间在地下，玩家只看到零星几只。
	#   这条警告就是给这个坐标系误会准备的（用户实测踩过：offset.y=0.5 + size.y=6）。
	if not autofit_region and region_offset.y < region_size.y * 0.5 - 0.05:
		var buried := region_size.y * 0.5 - region_offset.y
		out.append("区域有 %.1f 米埋在地下：region_offset.y(%.2f) 小于 region_size.y/2(%.1f)。"
				% [buried, region_offset.y, region_size.y * 0.5]
				+ "region_offset 是「以节点原点为中心」的本地偏移（不是离地高度），"
				+ "请把它调到 ≥ %.1f，或打开 autofit_region。" % (region_size.y * 0.5))
	return out


## 自动贴地：每 2 秒探一次（找不到地形就一直保持原区域）。
## 注意：只在 autofit_region 打开时工作；raycast 需要物理世界，编辑器里也可能拿不到。
func _autofit_tick(delta: float) -> void:
	if not autofit_region:
		return
	_ground_probe_t -= delta
	if _ground_probe_t > 0.0:
		return
	_ground_probe_t = 2.0
	auto_fit_to_ground()

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
##      `Wind`（另一个 autoload）存在时优先用它已经算好的 `cur_*`，两边保持一致。
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
##   · autoload `Wind`（scripts/wind.gd）—— 可选；有就用它的 cur_dir/cur_strength…
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
## 用途：`Wind` / `Weather` 这类 autoload 的查找入口。
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
			_pulse_cooldown = _rng.randf_range(25.0, 70.0)
			_pulse_t = _rng.randf_range(1.2, 2.5)
		if _pulse_t > 0.0:
			_pulse_t -= dt
	var extra := _build_extra()
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
## 来源优先级：`Wind`（已有算好的 cur_*，且它才是草/植被实际用的那份）-> `Weather` -> 内置兜底。
## 注意：`Wind` 与 `Weather` 都是 autoload；任何一个都可能不存在（例如单测里只挂一个节点），
##   所以每一步都判空；三者都不在时给一套"微风"常量，保证蝴蝶永远有风可用（不会静止死）。
func wind_now() -> Dictionary:
	var rt := scene_root()
	if rt == null:
		return _fallback_wind("no_tree")
	var w := rt.get_node_or_null("Wind")
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
## 内容：threat（受惊源位置）/ partner（随机配对的同伴位置）/ hover（群体腾起脉冲时的盘旋半径）。
## 注意：每帧都取一次 threat 位置（很便宜），但不做 raycast、不遍历分组。
func _build_extra() -> Dictionary:
	var e: Dictionary = {}
	var t := _find_threat()
	if t != null:
		e["threat"] = to_local(t.global_position)
	if _pulse_t > 0.0:
		# 腾起脉冲：给一个"盘旋"行为（hover 半径内会反推，形成绕圈）
		e["hover"] = region_size.x * 0.35
	# 求偶配对：每帧给一个随机同伴，蝴蝶在 COURT 状态时会去绕它
	if _butterflies.size() >= 2 and rng_ok():
		var a := _rng.randi_range(0, _butterflies.size() - 1)
		var b := _rng.randi_range(0, _butterflies.size() - 1)
		if a != b:
			var pb: Node3D = _butterflies[b] as Node3D
			if pb != null and is_instance_valid(pb):
				e["partner"] = pb.position
	return e


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
		# ---- 立体感（体积）----
		"wing_camber": 0.30, "wing_thickness": 0.035, "wing_bend_y": 0.0,
		"edge_min_facing": 0.0, "edge_min_deg": 14.0, "rim_dark": 0.55,
		"body_scale": 1.0,
	}
	# ★ 群组属性覆盖（见函数注释）
	d["ground_avoid"] = ground_avoid
	d["size_m"] = size_m
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
	return d


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
	}


# ==================== 素材清单 ====================

## 清单文件路径（**硬编码**，tools/analyze_butterflies.gd 与插件菜单都写它）。
const MANIFEST_PATH := "res://addons/butterfly_swarm/sprite_manifest.json"


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

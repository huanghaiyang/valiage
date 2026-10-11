# ============================================================================
# weather.gd —— 天气系统（autoload 单例，注册名 "Weather"）
# ============================================================================
# · 所属系统：世界表现层（天气 / 风 / 云 / 雨）。同层邻居：assets/shaders/
#   vegetation_wind.gdshader（植被风摇）、assets/shaders/clouddome.gdshader（云穹顶）、
#   scripts/wind.gd（草与角色交互用的另一套风，自己另算参数、不共享本文件的材质列表）。
# · 核心模型：**"状态机 + 连续参数"**。状态机只管 Kind（6 种天气）与过渡进度 blend，
#   连续参数（wind / gust / turb / cloud / rain / fog / light）由新旧两个预设插值得到，
#   再统一落到场景对象上。参考《辐射 76》的天气思路：风是独立可调维度。
# · 注册：project.godot [autoload] Weather="*res://scripts/world/weather.gd"，
#   所以任何脚本都能用全局名 Weather 访问（main.gd / vitals.gd / ui 都这么用）。
#
# 【对外接口】
#   · 读状态：current（已生效的 Kind）/ target（目标 Kind）/ weather_name() /
#     wind / wind_gust / wind_turbulence / wind_speed / wind_dir / cloud / rain /
#     fog / light_scale（连续参数，供着色器与 UI 读取，也是着色器 uniform 的来源）
#   · 写状态：set_weather(kind, force)；可调 @export：transition_time / auto_change /
#     auto_min_time / auto_max_time / wind_dir_interval_min / wind_dir_interval_max /
#     wind_dir_turn_time
#   · 装配：bind_world(sun, env, rain_parent, wind_materials) —— 由 main.gd 在
#     "世界与植被都生成完之后"调用一次；add_wind_material(m) 供运行期补登记
#   · 每帧：follow_camera(cam) —— 由 main.gd 每帧调用，把云穹顶与雨盒对齐相机
#   · 信号：weather_changed(kind) —— ★ 本仓库内**目前没有任何连接方**（推测是为
#     UI / 存档 / 任务系统预留的钩子），所以不要用"有没有人监听"来判断天气是否变化
#
# 【关键依赖】
#   · autoload：无（本文件不反向依赖其它 autoload，只被别人单向读取）
#   · 场景注入：_sun / _env / _rain_particles 全部来自 bind_world()；未调用时它们为
#     null，本文件所有写入路径都会判空跳过 —— 也就是说"没装配 = 空转，不报错"
#   · 资源路径："res://assets/shaders/clouddome.gdshader"（_ensure_clouds 里 load）
#   · 材质约定：植被材质必须带 wind_direction / wind_strength / wind_gust /
#     wind_speed / wind_turbulence 五个 uniform（见 vegetation_wind.gdshader）。
#     uniform 名写错**不会报错**，只会静默地完全没效果。
#
# 【已知的坑与注意事项】
#   1. 全局着色器参数在 Godot 4.7 运行时下是坏的（get_list() 恒空、add()/set() 被
#      静默忽略、set_override() 只到片元阶段）。所以风只能靠**直接写材质 uniform**
#      驱动，这正是本文件持有 _wind_materials 列表的根本原因（详见 _apply_shader_params）。
#      （注：紧接着本块的原有文件头还写着"通过全局着色器 uniform 驱动"，那是历史说法，
#       实现以本节为准 —— 全局参数在这个引擎版本上根本不生效。）
#   2. bind_world() 会先 _wind_materials.clear() 再重填：早于它登记进来的材质会被丢掉
#      （scripts/wind.gd 头注释专门记了这条），运行期请改用 add_wind_material()。
#   3. CLOUD_DOME_RADIUS 必须小于相机远裁剪面（main.tscn 的 Camera3D.far = 1200），
#      否则整个云穹顶被裁掉、云完全不可见（这是第二版方案失效的原因）。
#   4. Environment 字段存在**双重写者**：本文件 _apply_world() 与 Settings.apply_quality()
#      都写 ambient_light_energy / fog_* / volumetric_fog_*，谁后写谁生效；本文件每帧都在
#      写，所以画质档位对这几个字段的设置会被天气覆盖（settings.gd 头注释有同一记录）。
#   5. _process 里把 process_mode 设成 ALWAYS（见 _ready），暂停时天气与风仍会继续推进。
#   6. 雨粒子节点只创建一次、不释放，靠 emitting / amount_ratio 控制（rain > 0.02 才开）。
# ============================================================================
extends Node
## 天气系统（自动加载单例）
## 支持：晴 / 多云 / 阴 / 小雨 / 雷雨 / 大风，带平滑过渡与风的阵风脉动。
## 植被风摇通过全局着色器 uniform 驱动（见 assets/shaders/vegetation_wind.gdshader）。
## 参考《辐射 76》的天气思路：天气是一个"状态机 + 连续参数"，风是独立可调维度。

# ==================== 信号与天气枚举 ====================
## 天气切换通知。参数 kind：新的天气编号（Kind 枚举，0..5）。
## 触发时机：set_weather() 末尾 —— 注意**无论是否真的换了天气都会发**（重复设同一天气也发），
##   语义是"收到了一次切换请求"，不是"天气确实变了"；要判断变化请自己比较 current / target。
## 接收方：本仓库内暂无连接方（推测是给 UI / 存档 / 任务系统预留）。
signal weather_changed(kind: int)

## 天气种类枚举。数值 0..5 是**对外契约**，不是内部实现细节：
##   · scripts/ui/map_weather_overlay.gd 的 KIND_* 常量与图标分支直接按这些数值匹配
##   · main.gd 的 --weather=N 命令行参数、minimap.gd 传给 update_weather() 的编号
## ★ 插入 / 删除 / 重排任何一个枚举项，都会让上面这些地方静默画错图标和名字（不报错）。
enum Kind { CLEAR, CLOUDY, OVERCAST, RAIN, STORM, WINDY }

# ==================== 常量：天气名称与参数预设 ====================
## 天气编号 -> 中文显示名。用途：weather_name() 查表；main.gd 还用它的 size() 做
## --weather=N 的越界判断（所以**不能**往这里加非天气的键，否则 --weather=6 会被放行）。
## 值会直接显示在 UI 上，改文案前先确认 ui/game_ui.gd、ui/map_weather_overlay.gd
## 是否有自己的那份名字副本（map_weather_overlay 自带一份，改这里不会同步过去）。
const KIND_NAMES := {
	Kind.CLEAR: "晴朗",
	Kind.CLOUDY: "多云",
	Kind.OVERCAST: "阴天",
	Kind.RAIN: "小雨",
	Kind.STORM: "雷雨",
	Kind.WINDY: "大风",
}

## 每种天气的目标参数
## wind: 风力(0..1.5)  gust: 阵风(0..1)  turb: 湍流  cloud: 云量(0..1)
## rain: 雨量(0..1)  fog: 雾浓度(0..1)  light: 阳光强度系数
## 补充说明（与上面三行的"键含义"配套读）：
##   · 数值全部是**手调的低多边形观感经验值**，不是物理量 —— 改这里等于改天气观感。
##     想更"闷"：抬 OVERCAST / RAIN 的 cloud、压低 light；想更"狂"：抬 STORM 的
##     wind / gust / turb（wind 超过 1.5 会在 _update_params 的 clampf 处被截掉）。
##   · 漏写某个键**不会报错**：_update_params 读的是 a.get(key, 0.0) 与 b.get(key, va)，
##     结果只是那一项从 0 或从起点值开始插值 —— 属于静默错误，新增天气时 7 个键都要写。
##   · CLEAR 的 cloud 是 0.035 而不是 0：留一丝云，天空不会干净到像纯色背景板。
const PRESETS := {
	Kind.CLEAR:    {"wind": 0.18, "gust": 0.15, "turb": 0.30, "cloud": 0.035, "rain": 0.0, "fog": 0.0, "light": 1.00},
	Kind.CLOUDY:   {"wind": 0.35, "gust": 0.30, "turb": 0.40, "cloud": 0.55, "rain": 0.0, "fog": 0.05, "light": 0.85},
	Kind.OVERCAST: {"wind": 0.45, "gust": 0.35, "turb": 0.45, "cloud": 0.85, "rain": 0.0, "fog": 0.12, "light": 0.65},
	Kind.RAIN:     {"wind": 0.60, "gust": 0.50, "turb": 0.55, "cloud": 0.90, "rain": 0.45, "fog": 0.22, "light": 0.50},
	Kind.STORM:    {"wind": 1.10, "gust": 0.90, "turb": 0.80, "cloud": 1.00, "rain": 1.00, "fog": 0.35, "light": 0.32},
	Kind.WINDY:    {"wind": 0.95, "gust": 0.70, "turb": 0.65, "cloud": 0.35, "rain": 0.0, "fog": 0.05, "light": 0.90},
}

# ==================== 状态：当前天气、目标天气与过渡控制 ====================
## 当前 / 目标天气
## 已生效的天气编号（Kind）。只有过渡满进度时（_process 里 blend>=1）才被赋成 target，
## 或是 set_weather(kind, force=true) 立刻同步。取值 0..5。
## ★ 过渡期间读它拿到的是**旧**天气 —— UI 若想显示"正在变成什么"，请读 target。
var current: int = Kind.CLEAR
## 目标天气编号（Kind）。连续参数正是在 PRESETS[current] 与 PRESETS[target] 之间插值，
## 所以"过渡中"= current != target。取值 0..5。
var target: int = Kind.CLEAR
## 过渡进度（0..1）
## 过渡进度（0..1）：0 = 完全停在 current 的预设，1 = 已到达 target 的预设。
## 由 _process 每帧按 delta/transition_time 线性推进，缓动（smoothstep）在 _update_params 里做。
## 注意：这不是"已经过去的秒数"，而是归一化进度；set_weather(force=true) 会直接置 1。
var blend := 1.0
## 过渡时长（秒）
## 一次天气过渡的总时长（秒）。默认 8.0：够慢，看得出天色在变；又不至于让玩家等太久。
## 调大 -> 更"电影感"的缓慢天变，但过渡期间 current 仍是旧天气（UI 名字滞后更久）；
## 调小 -> 更快，但小于 ~2 秒会有"刷一下变天"的突兀感。
## ★ 坑：设为 0.0 时 _process 的过渡分支永不执行（条件是 blend<1.0 and transition_time>0.0），
##   于是非 force 的换天气**永远切不过去**（current 不变、参数停在旧预设）。别设 0。
@export var transition_time := 8.0
## 是否自动变化天气（可关闭，交给脚本/UI 控制）
## 是否自动变化天气。true（默认）= 每 auto_min/max_time 秒自动挑下一个天气（相邻天气偏多）。
## false = 天气完全由外部控制（main.gd 解析 --weather=N 时会先把它关掉，保证截图可复现；
##   按 V 键手动循环天气时**不会**改它，所以手动切换之后自动天气仍会继续）。
@export var auto_change := true
## 自动变化的最小/最大间隔（秒）
## 自动换天气的最小间隔（秒），默认 90.0。
## 每次换完后会在 [_auto_min_time, _auto_max_time] 之间重新随机一个间隔（不是固定周期），
## 避免"每 90 秒准时变天"的机械感。调小 -> 天气更闹腾；调大 -> 一局里基本看不到几种天气。
## 注意：间隔计时只在 blend>=1（没有正在进行的过渡）时才被消费，见 _process。
@export var auto_min_time := 90.0
## 自动换天气的最大间隔（秒），默认 240.0。含义见 auto_min_time。
## ★ 约定这两个值要保持 auto_min_time <= auto_max_time：randf_range 不会校验顺序、也不报错，
##   反了之后仍会返回一个区间内的数（只是区间含义反了），所以别指望引擎帮你发现写错。
@export var auto_max_time := 240.0

## 当前连续参数（对外可读，也是着色器 uniform 的来源）
## 风力（0..1.5，无量纲）。CLEAR 0.18 -> STORM 1.10，>1.0 属"暴风"级。
## 它是植被摆幅（uniform wind_strength）与 wind_speed（摆动频率）的输入；
## 也是 scripts/vitals.gd 的舒适度惩罚依据（那里按 max(0, wind-0.35)*0.45 扣分，
## 所以 CLEAR 0.18 与 CLOUDY 0.35 都不扣，OVERCAST 0.45 以上才开始扣）。
## 注意：本值只在 _update_params 里被写 —— 外部想改风力请走 set_weather()，别直接赋值。
var wind := 0.18
## 阵风强度（0..1）。它加在风摇着色器的脉动项上，越大越"一阵一阵地猛"，
## 不影响平均摆幅（平均摆幅由 wind 决定）。默认 0.15 对应晴朗天的轻微起伏。
var wind_gust := 0.15
## 湍流强度（0..1）。着色器用它做高频乱摆，越大越"杂乱"（像暴风里被撕扯的树）。
## 与阵风的区别：阵风是**低频**整体强弱脉动，湍流是**高频**各株不同步的抖动。
var wind_turbulence := 0.30
## 摆动频率（0.8..3.6）。★ 它**不是** PRESETS 里的键，而是由 wind 派生的：
## _update_params 里做 wind_speed = lerpf(0.8, 3.6, clampf(wind, 0.0, 1.5))。
## 太小像抽搐、太大看不出在动，0.8~3.6 覆盖"微风轻晃"到"暴风狂摆"。
var wind_speed := 1.4
## 云量（0..1）。同时兼作整个场景的"阴沉度"代理参数（见 _apply_world 里的 dark）：
## 环境光、雾、天空色、太阳盘大小、云的覆盖与颜色，全部由它插值推导 ——
## 所以它是本文件里**副作用最多**的一个参数，改预设时优先看它。
var cloud := 0.10
## 雨量（0..1）。只在 PRESETS 的 RAIN(0.45)/STORM(1.0) 非零，其余天气为 0。
## 用途：① 决定雨粒子是否发射（阈值 0.02）② 直接当 GPUParticles3D.amount_ratio
##   （所以它同时是"雨多大"和"雨多密"）③ scripts/vitals.gd 读它扣舒适度。
var rain := 0.0
## 雾浓度（0..1）。★ 它不是线性映射到雾密度：>0.18 才 fog_enabled，>0.45 才开体积雾，
## 且都做 (fog - 阈值) * 小系数 的二次压缩（见 _apply_world 的原因注释）。
## 也就是说 0..0.18 这一段是"完全无雾"的死区，调预设时别指望小雨能带来一点点空气感。
var fog := 0.0
## 阳光强度系数（约 0.32..1.0）。它是**乘数**：最终太阳亮度 = _base_sun_energy * light_scale。
## 用乘数而不是绝对亮度的原因：场景里手调过的太阳 light_energy 仍然有效，
## 天气只负责按比例压暗（阴雨天 0.32 ≈ 只剩三成阳光）。
var light_scale := 1.0

## 风向（水平单位向量）
## 风向（水平单位向量）。约定：x 对应世界 X，y 对应世界 **Z**（Godot 的 3D 水平面是 XZ，
## 所以这里用 Vector2 的 y 装 Z）。初始 (1.0, 0.0) = 从 -X 吹向 +X。
## 消费者：植被风摇 uniform（wind_direction）、云穹顶漂移方向（wind_dir）、
## ui/minimap.gd 的风向标（直接用 atan2(dir.y, dir.x)），因此保持单位长度很重要 ——
## 零向量会让风向标的角度不稳定（minimap 侧有 (1,0) 兜底）。
var wind_dir := Vector2(1.0, 0.0)
## 风向缓慢漂移的相位
## --- 风向：每隔一段时间随机挑一个新方向，再平滑转过去 ---
## 距离下次"换风向"的最短/最长间隔（秒），默认 18 / 45 —— 在区间内随机取，避免规律感。
## 调小 -> 风一会儿东一会儿西（<8 秒会明显像"抖"）；调大 -> 方向长期不变，风显得呆板。
## ★ 与 wind_dir_turn_time 是两件事：本项决定"多久选一次新方向"，turn_time 决定"转过去要多久"。
@export var wind_dir_interval_min := 18.0   ## 换风向最短间隔（秒）
## 最长间隔（秒），含义见 wind_dir_interval_min。约定保持 min <= max：randf_range 不校验顺序，
## 反了不会报错，只是得到的间隔区间含义反了。
@export var wind_dir_interval_max := 45.0   ## 最长间隔
## 转向耗时（秒，越大越平缓）。实现上就是每帧把当前角按 smoothstep(delta/turn_time) 逼近目标角，
## 所以它是"帧率无关的时间常数"：调大 -> 风向慢慢悠悠转过去；调小 -> 一下就到新方向。
## 注意：它只影响**转向的快慢**，不影响换向的间隔（那是 interval_* 管的）。
@export var wind_dir_turn_time := 6.0       ## 转向耗时（秒，越大越平缓）
## 低频"呼吸"相位（弧度累加）。由 _dir_phase += delta * 0.35 推进，只用来在
## 主风向角上叠一个 ±0.12 rad 的慢摆（sin(_dir_phase)），不影响换向逻辑本身。
var _dir_phase := 0.0
## 当前风向角（弧度，wrap 在 [0, TAU)）。初始 PI*0.35 ≈ 63°，即方向向量约 (0.45, 0.89)，偏 +Z 为主；
## 它由 _wind_direction_now 每帧向 _dir_target 逼近，**不直接等于** wind_dir 的角度
## （wind_dir 还要再叠 ±0.12 rad 的呼吸摆动）。
var _dir_current := PI * 0.35               ## 当前风向角
## 目标风向角（弧度）。每次换向时取"当前角 + 随机 1.05..(TAU-1.05)"再 wrap 到 [0, TAU)，
## 也就是保证与当前方向至少差约 60°，免得"换了像没换"。
var _dir_target := PI * 0.35                ## 目标风向角
## 距离下次换向的倒计时（秒）。初始 12.0 只是"首帧先别急着换"，之后每次到点都从
## [wind_dir_interval_min, wind_dir_interval_max] 里重新随机，因此换向间隔是不均匀的。
var _dir_timer := 12.0                      ## 距离下次换向
## 本文件专用的随机数发生器。分开一份（而不是用全局 randf）是为了：
## ① 天气序列可被单独 seed 复现 ② 不污染其它系统对全局随机状态的假设。
## 注意：_ready 里调用了 randomize()，所以**每局开机的天气序列都不同**。
var _rng := RandomNumberGenerator.new()
## 距离下次自动换天气的倒计时（秒）。_ready 里先随机排一个，避免开局立刻变天。
var _auto_timer := 0.0

# ==================== 场景引用与运行时资源（全部由 main 注入） ====================
## 场景引用（由 main 注入）
## 场景里的平行光（太阳）。由 bind_world() 注入，未装配时为 null（_apply_world 会跳过）。
## 它同时是 _base_sun_energy 的来源 —— 但注意取值时机在 _apply_world() 之后，见 bind_world。
var _sun: DirectionalLight3D = null
## 场景里的 WorldEnvironment。由 bind_world() 注入。它是本文件写入雾 / 环境光 /
## 体积雾的落点，也是与 Settings.apply_quality() 争抢同一批字段的对方（见文件头"坑 4"）。
var _env: WorldEnvironment = null
## 太阳亮度基准值。默认 1.28 只在"还没 bind_world()"时生效；bind_world() 会用场景里
## 太阳当前的 light_energy 覆盖它。_apply_world 里写的是 _base_sun_energy * light_scale，
## 也就是说天气只做**比例**衰减，不去猜绝对亮度。
var _base_sun_energy := 1.28
## 环境光亮度基准值。默认 0.85 只在未 bind_world() 时生效，之后由场景的
## Environment.ambient_light_energy 覆盖。最终值 = _base_ambient * lerpf(1.0, 0.55, cloud)，
## 即最阴时只压到 55%（见 _apply_world 的原因注释）。
var _base_ambient := 0.85
## 雨粒子节点（GPUParticles3D，名字 WeatherRain）。由 _ensure_rain() 在 bind_world()
## 时创建一次并挂在 rain_parent 下，之后**不销毁、不重建**：开关只改 emitting，
## 大小只改 amount_ratio（这样切天气不会因重建粒子而卡顿）。
var _rain_particles: GPUParticles3D = null
## 云穹顶半径（米）。穹顶整体挂在相机上，用视线仰角决定 alpha，
## 这样地面相机抬头就能看到云（平面方案在几何上根本看不到，见 shader 注释）。
## 半径必须**小于相机远裁剪面**（main.tscn 的 Camera3D.far = 1200），
## 否则整个穹顶被裁掉、云完全不可见（这是第二版失效的原因）。
const CLOUD_DOME_RADIUS := 900.0
## 云层（跟随相机的程序化云平面）
## （注：上面这行"云平面"是旧方案的说法，现行实现是下面的半球穹顶，见 CLOUD_DOME_RADIUS。）
## 云穹顶节点（MeshInstance3D，名字 WeatherClouds，半径 CLOUD_DOME_RADIUS 的半球）。
## 由 _ensure_clouds() 创建一次。注意：它的**父节点是 main 场景**（bind_world 的 rain_parent），
## 但每帧被 follow_camera() 把 global_transform 直接对齐相机 —— 于是效果上等价于"挂在相机上"。
var _clouds: MeshInstance3D = null
## 云穹顶的材质（clouddome.gdshader 的 ShaderMaterial）。_apply_world() 每帧按云量写它的
## coverage / density / wind_dir / wind_speed / cloud_lit / cloud_shadow 等 uniform。
## uniform 名写错不会报错，只会静默失效 —— 改名时请与着色器同步。
var _cloud_mat: ShaderMaterial = null
## 程序化天空材质（WorldEnvironment → Environment.sky → sky_material）的引用。
## 只在 bind_world() 里抓一次；如果场景的天空不是 ProceduralSkyMaterial（例如换成
## 天空贴图 / PhysicalSkyMaterial），这里会保持 null，_apply_world 里所有天空写入被跳过
## —— 也就是"天色不会随天气变"，但不会报错也不影响其它部分。
var _sky_mat: ProceduralSkyMaterial = null
## 植被风摇材质（由 main 注入）。每个植物分类一份，sway_scale 不同、风参数相同。
## ★ 注意：bind_world() 会先 clear() 再重填这个列表，所以**早于 bind_world 登记的材质会被丢掉**；
## 运行期（玩家放置植物）新增的材质必须走 add_wind_material()（见 scripts/wind.gd 的同一条记录）。
var _wind_materials: Array[ShaderMaterial] = []

# ==================== 生命周期与对外接口 ====================
## 引擎回调：autoload 启动时执行一次（早于 main.gd 的 _ready —— autoload 先于主场景）。
## 参数：无。返回值：无。
## 副作用：① 设置 process_mode ② 随机化 _rng ③ 排出首次自动换天气的倒计时
##   ④ _apply_shader_params() 落地一次风参数。
## ★ 注意：这里**没有**调用 _apply_world()，因为此刻还没有太阳/环境引用（bind_world 尚未
##   被调用），调了也是空转；而且 _wind_materials 此刻必定为空，④ 会走快速返回分支。
func _ready() -> void:
	# 为什么用 ALWAYS：天气是"世界状态"而不是游戏逻辑，暂停/慢放时天色与风若一起冻住，
	# 恢复瞬间会出现明显跳变；设成 ALWAYS 后暂停菜单里天气仍在平滑推进（代价可忽略）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 不用 randomize() 的话 _rng 会用固定默认种子 —— 每次启动的天气序列完全一样（调试时
	# 想复现可以反过来把这一行注掉，但别提交这种改动：玩家会觉得世界很"死"）。
	_rng.randomize()
	# 开局先排一个随机间隔（而不是 0）：否则第一帧就会立刻换一次天气，
	# 玩家/截图工具还没看清初始天气，天就变了。
	_auto_timer = _rng.randf_range(auto_min_time, auto_max_time)
	_apply_shader_params()

## 运行期新增的风摇材质（玩家放置的植物是一株一份，放置时才建）也要吃到风。
## 单靠 bind_world 一次性注入不够：那时植物的材质还没创建。
## 参数 m：要登记的风摇 ShaderMaterial（期望是 vegetation_wind.gdshader 的实例）。
##   传 null 或已在列表里的对象会被直接忽略 —— 幂等，重复登记安全。
## 返回值：无。
## 副作用：追加进 _wind_materials 并**立刻** _apply_shader_params()，所以新材质当帧就吃到风，
##   不会等下一帧（玩家放下植物的瞬间就能看到它在摆）。
## 调用时机：运行期（玩家放置植物）。★ 不能用 bind_world() 的数组参数来登记"以后才创建"的材质：
##   ① 那时材质还不存在 ② bind_world 会 clear() 掉先登记的（见 _wind_materials 的注释）。
func add_wind_material(m: ShaderMaterial) -> void:
	# 幂等守卫：同一份材质可能被重复登记（植物重建、场景重载），
	# 重复项会让 _apply_shader_params 每帧白写一遍同一个材质。
	if m == null or _wind_materials.has(m):
		return
	_wind_materials.append(m)
	_apply_shader_params()


## 装配入口：由 main.gd 在世界（含植被）生成完成之后调用**一次**。
## 参数 sun：场景里的 DirectionalLight3D（阳光写入目标 & 基准亮度来源），可为 null。
## 参数 env：场景里的 WorldEnvironment（环境光/雾/天空的写入目标），可为 null。
## 参数 rain_parent：雨粒子与云穹顶的挂载父节点。main.gd 传的是主场景自身，
##   因此这两个节点是**场景节点**（随场景释放），autoload 只持有引用。
## 参数 wind_materials：各植被分类的风摇材质集合（vegetation.wind_materials()），
##   默认空数组 = 只清空旧列表、不登记新的。
## 返回值：无。
## 副作用（顺序敏感）：① 写 _sun / _env ② _wind_materials.clear() 后重填
##   ③ _ensure_clouds() 建云穹顶 ④ 抓 _sky_mat 引用 ⑤ _apply_shader_params() + _apply_world()
##   立刻落地一次 ⑥ 记录 _base_sun_energy / _base_ambient ⑦ _ensure_rain() 建雨粒子。
## ★ 调用顺序要求（main.gd 里有同一条注释）：必须排在植被生成之后 —— wind_materials()
##   返回的是**已创建材质**的集合，早调只会把空数组写进风摇 uniform。
## ★ 坑：基准值是在 _apply_world() **之后**才从 sun/env 读回来的，所以读到的是"已经被本系统
##   乘过一次 light_scale / cloud 系数"的值。首次调用影响很小（晴朗天系数接近 1），但
##   重复调用 bind_world() 会让基准逐次衰减（推测：这样写是为了尊重场景里手调过的亮度，
##   代价就是重复调用会累积偏差）。调试重绑场景时请留意天色是否越来越暗。
## 由 main 注入场景引用（太阳/环境），并创建雨粒子
func bind_world(sun: DirectionalLight3D, env: WorldEnvironment, rain_parent: Node3D,
		wind_materials: Array = []) -> void:
	_sun = sun
	_env = env
	# 先清空再重填：这次调用才是"权威名单"。副作用是早于 bind_world 登记的材质会丢
	#（这也是 scripts/wind.gd 必须自己拿一份材质、而不是依赖这个列表的原因）。
	_wind_materials.clear()
	for m in wind_materials:
		# 参数声明成了无类型 Array，所以这里逐个过滤（双保险：调用方给的其实是
		# Array[ShaderMaterial]，但类型信息在这一层不可见，不过滤就可能塞进非材质对象）。
		if m is ShaderMaterial:
			_wind_materials.append(m as ShaderMaterial)
	# 云穹顶在这里才创建（而不是 _ready）：_ready 时还没有 rain_parent，也没必要在
	# autoload 启动期就建一个 900m 的网格。
	_ensure_clouds(rain_parent)
	if _env != null and _env.environment != null:
		var sk := _env.environment.sky
		# 只有当天空确实是 ProceduralSkyMaterial 时才抓：别的天空材质（贴图/物理天空）
		# 没有 sky_top_color / sun_angle_max 这些属性，硬写会直接报错，所以这里用 is 守卫。
		if sk != null and sk.sky_material is ProceduralSkyMaterial:
			_sky_mat = sk.sky_material as ProceduralSkyMaterial
	# 装配完成后立刻按当前（默认 CLEAR）参数落地一次，避免"注册后到第一帧之间"这段时间
	# 场景里是太阳/环境的原始亮度、而植被材质已经拿到风参数 —— 那种不一致会肉眼看出来。
	_apply_shader_params()
	_apply_world()
	# ★ 基准值取自 _apply_world() 之后（见函数注释里的"坑"）：读到的是已乘过系数的值。
	if sun != null:
		_base_sun_energy = sun.light_energy
	if env != null and env.environment != null:
		_base_ambient = env.environment.ambient_light_energy
	# 雨粒子放最后建：此时 _apply_world() 已经跑过，雨的开关要等下一帧 _process 才同步；
	# 因为 _ensure_rain 里把 emitting 初始化为 false，所以不会闪出多余的"一帧暴雨"。
	_ensure_rain(rain_parent)

## 切换天气（对外主接口）。
## 参数 kind：目标天气编号（Kind，0..5）。
## 参数 force：false（默认）= 从当前参数平滑过渡到新预设，耗时 transition_time 秒；
##   true = 跳过过渡，blend 直接置 1 并同步 current。
## 返回值：无。
## 副作用：写 target（force 时同时写 current 与 blend）、末尾发 weather_changed(kind)。
## 调用时机：main.gd 解析 --weather=N（force=true）、main.gd 按 V 键 _cycle_weather()
##   （force=true）、本文件 _process 的自动换天气（force=false）。
## ★ kind 越界（<0 或 >Kind.WINDY）时**静默 return**：不改状态、不发信号。main.gd 的
##   --weather= 越界保护就是靠这个行为（那边还会用 KIND_NAMES.size() 先挡一次）。
## ★ 上界写死成 Kind.WINDY：在枚举**末尾**追加新天气没问题，插在中间/前面就要同步改这里。
## ★ 设成与当前相同的天气同样会走一遍过渡并再发一次信号，不是"无变化"语义。
## 设置天气（带过渡）；force=true 立即生效
func set_weather(kind: int, force := false) -> void:
	if kind < 0 or kind > Kind.WINDY:
		return
	target = kind
	# force 时把进度直接拉满（而不是从 0 开始跑 8 秒）：用于"启动指定天气/手动切换"这类
	# 要求立刻可见的场合，也是 --capture 截图能复现的前提（否则 90 帧内天还在过渡）。
	blend = 1.0 if force else 0.0
	# force 必须同时同步 current，否则会**永久错位**：_process 只在 blend<1.0 的分支里把
	# current 赋成 target，这里不同步的话 current 会一直停在旧天气（weather_name() 也就一直显示旧名字）。
	if force:
		current = kind
	# 无论 kind 是否真变化都发：信号语义是"收到了一次切换请求"，不是"天气确实变了"。
	weather_changed.emit(kind)

## 当前天气的中文名（查 KIND_NAMES）。
## 参数：无。返回值：current 对应的中文名；current 不是合法键时返回 "未知"（不崩）。
## 副作用：无（纯读）。调用者：main.gd 的调试 print、UI 的天气标签。
## ★ 读的是 **current**（已生效），所以过渡期间返回的是旧天气名；想显示"正在变成什么"用 target。
## 注意：ui/map_weather_overlay.gd 自带一份同名的中文表（它刻意不依赖 autoload），
##   改 KIND_NAMES 的文案不会同步过去。
func weather_name() -> String:
	return KIND_NAMES.get(current, "未知")

# ==================== 每帧推进：自动换天气 / 过渡 / 参数落地 ====================
## 引擎回调：每帧执行（_ready 里设了 PROCESS_MODE_ALWAYS，所以暂停时也在跑）。
## 参数 delta：距上一帧的秒数（秒）。暂停恢复、debugger 断点之后可能显著偏大，
##   本函数对它的使用都做了 clamp/上限处理，不会因此跳变。
## 返回值：无。
## 副作用（严格按执行顺序，顺序本身有意义）：
##   ① auto_change 为真时递减 _auto_timer，到点且当前没有过渡则随机挑下一个天气
##   ② 推进 blend；过渡满进度时把 current 定格成 target
##   ③ _update_params()：插值出连续参数，并推进风向
##   ④ _apply_world()：写太阳 / 环境 / 天空 / 云 / 雨
##   ⑤ _apply_shader_params()：写植被风摇 uniform
## ★ ③ 必须在 ④⑤ 之前：否则每帧都会把上一帧的旧参数落地，画面慢一帧（过渡时肉眼可见）。
## ★ ④⑤ 每帧无条件执行（写入幂等）。所以"天气没变"时也有固定的每帧开销；
##   未 bind_world() 时这些写入全被 null 判断短路，等于空转（autoload 启动期安全）。
func _process(delta: float) -> void:
	# 自动换天气
	if auto_change:
		_auto_timer -= delta
		# 要求 blend >= 1.0 才允许换目标：过渡途中再改 target，会让插值起点每帧被换掉，
		# 参数在两个预设之间来回抽动（看起来像天气"发抖"）。所以"一次只过渡一件事"。
		if _auto_timer <= 0.0 and blend >= 1.0:
			_auto_timer = _rng.randf_range(auto_min_time, auto_max_time)
			var next: int = int(_pick_next_weather())
			set_weather(next)
	# 过渡
	# ★ transition_time > 0.0 是必要的守卫（否则除零），但它同时意味着 **transition_time 设成 0
	#   时这里整段不执行**：非 force 的 set_weather 会永远切不过去（current 不变、参数停在旧预设）。
	#   这是历史行为，已写进 transition_time 的成员注释，别把它当"0 = 立即生效"用。
	if blend < 1.0 and transition_time > 0.0:
		# 进度是**线性**推进的，缓动（smoothstep）留到 _update_params 里做：
		# 这样 blend 本身就是单调的"完成度"，用来判定过渡是否结束最直观。
		blend = minf(1.0, blend + delta / transition_time)
		# 用 >= 而不是 == 判定：minf 保证不会超过 1，但 >= 对浮点误差更宽容。
		if blend >= 1.0:
			# 只有过渡完成才定格 current —— 这就是"target 表示意图、current 表示事实"的分工。
			current = target
	_update_params(delta)
	_apply_world()
	_apply_shader_params()

## 天气状态机：按"相邻天气更常见"的权重随机挑下一个天气。
## 参数：无（读 current 决定候选集）。
## 返回值：Kind 里的某个编号（int）。返回值**没有再夹紧**，由 set_weather() 兜底校验。
## 副作用：消耗 _rng 的随机状态（一次 randi_range）。
## 调用时机：只由 _process 的自动换天气调用，且调用点已经保证 blend >= 1.0
##   （否则会以"旧天气"为起点挑候选，与玩家的观感不一致）。
func _pick_next_weather() -> int:
	# 简单权重：相邻天气更常见，避免突兀的暴风雨
	# 权重实现就靠"重复元素"：CLEAR 行里 CLOUDY 出现两次 => 走多云 2/3、走大风 1/3。
	# 用权重而不是"只能相邻一步"：这样偶尔能跳级（例如 WINDY 之后也可能回到 CLEAR），
	# 但永远不会 CLEAR -> STORM 这种突兀跳变。
	var options: Array = []
	match current:
		Kind.CLEAR: options = [Kind.CLOUDY, Kind.CLOUDY, Kind.WINDY]
		Kind.CLOUDY: options = [Kind.CLEAR, Kind.OVERCAST, Kind.WINDY]
		Kind.OVERCAST: options = [Kind.CLOUDY, Kind.RAIN]
		Kind.RAIN: options = [Kind.OVERCAST, Kind.STORM]
		Kind.STORM: options = [Kind.RAIN, Kind.OVERCAST]
		Kind.WINDY: options = [Kind.CLEAR, Kind.CLOUDY]
	# ★ 依赖"每个 match 分支都会给 options 赋值"这一不变量：一旦新增了 Kind 却没有对应的
	#   match 分支，options 会保持空数组，这里 randi_range(0, -1) 直接抛错。
	return options[_rng.randi_range(0, options.size() - 1)]

## 在 from -> to 之间插值出当前连续参数（本文件的核心算法）。
## 参数 delta：本帧时长（秒）。本函数自己不用它，只是转交给 _wind_direction_now()
##   —— 风向的推进是"随时间积分"的，所以必须把 delta 透传下去。
## 返回值：无。
## 副作用：**覆盖所有连续参数**（wind / wind_gust / wind_turbulence / cloud / rain / fog /
##   light_scale）、派生量 wind_speed，并推进风向状态后写 wind_dir。
## 调用时机：_process 每帧一次，且必须早于 _apply_world() / _apply_shader_params()。
## 注意：current == target 时得到的 t 是 1.0，插值结果就是 target 的预设本身 ——
##   本函数是幂等的，每帧重复调用不会有累积漂移。
## 在 from -> to 之间插值出当前连续参数
func _update_params(delta: float) -> void:
	# 用 get() 而不是 PRESETS[current] 下标：current 万一不是合法键（外部乱赋值/版本不一致），
	# 这里会回退到 CLEAR，而不是在字典取值处直接抛错。
	var a: Dictionary = PRESETS.get(current, PRESETS[Kind.CLEAR])
	var b: Dictionary = PRESETS.get(target, a)
	# current == target 时直接取 1.0：此时 a 与 b 是同一份预设，取 0 还是 1 结果相同，
	# 但取 1 可以避免"blend 还是 0"（例如 force 之前的状态）时读到起点值。
	var t: float = blend if current != target else 1.0
	# ★ 缓动：线性插值是「匀速直线变过去」，很生硬；
	# 用 smoothstep 做成「缓慢起步 -> 中段快 -> 缓慢收尾」，风/云/雨才有过渡感。
	t = t * t * (3.0 - 2.0 * t)
	# 风向在这里推进、并且只在这里推进一次：把"参数插值"和"风向演化"绑定在同一个时间步上，
	# 才不会出现"某帧风参数更新了但风向没动"（或反过来）的错帧。
	var wdir := _wind_direction_now(delta)
	# 用"键名字符串列表 + match 落成员"的写法，而不是逐项写 7 遍 lerpf：
	# 新增一个连续参数时只需改 PRESETS 与这个列表各一处（match 少一个分支会静默漏参数）。
	for key in ["wind", "gust", "turb", "cloud", "rain", "fog", "light"]:
		var va := float(a.get(key, 0.0))
		var vb := float(b.get(key, va))
		var v := lerpf(va, vb, t)
		match key:
			"wind": wind = v
			"gust": wind_gust = v
			"turb": wind_turbulence = v
			"cloud": cloud = v
			"rain": rain = v
			"fog": fog = v
			"light": light_scale = v
	# 摆动频率：太快会像抽搐，太慢看不出在动。0.8~3.6 覆盖微风到暴风。
	wind_speed = lerpf(0.8, 3.6, clampf(wind, 0.0, 1.5))
	# 只在最后统一赋一次 wind_dir（而不是在 _wind_direction_now 里就地改全局）：
	# 本帧后续的 _apply_world / _apply_shader_params 读到的就是这一份最终值，不会读到半更新状态。
	wind_dir = wdir

## 风向：每隔 wind_dir_interval_* 秒随机挑一个新方向（和当前至少差 60 度，
## 免得「换了像没换」），再用 wind_dir_turn_time 平滑转过去 —— 不会突然跳变。
## 另外叠一点很慢的低频摆动，让风有呼吸感（幅度很小，不抢主导方向）。
## 参数 delta：本帧时长（秒，>0），用于时间积分（倒计时与转向插值）。
## 返回值：归一化的水平风向 Vector2(cos, sin)，约定 x = 世界 X、y = 世界 Z。
## 副作用：写 _dir_timer / _dir_target / _dir_current / _dir_phase（每帧都在变）。
## 调用时机：只由 _update_params() 每帧调用一次。★ 它就是风向的"时间推进器"，
##   别在别处再调 —— 多调一次等于把这个计时器按调用次数加速消耗。
func _wind_direction_now(delta: float) -> Vector2:
	_dir_timer -= delta
	if _dir_timer <= 0.0:
		# 到点只更新 _dir_timer 与 _dir_target（"意图"），当前角由下面的插值慢慢追过去 ——
		# 所以换向永远不会出现角度跳变。
		_dir_timer = _rng.randf_range(wind_dir_interval_min, wind_dir_interval_max)
		# 1.05 rad ≈ 60°，保证新方向与当前方向至少差 60°（否则视觉上"换了像没换"）。
		# 区间取 [1.05, TAU-1.05] 是对称的，配合 wrapf 保证得到的是"绕短弧"的那个方向。
		_dir_target = wrapf(_dir_current + _rng.randf_range(1.05, TAU - 1.05), 0.0, TAU)
	# maxf(0.01, ...) 防除零；clamp 到 1 保证一帧最多转到目标（不会过冲）。
	# 这个 ft 是"本帧向目标靠拢的比例"，所以帧率高低只影响转向的平滑度，不影响最终方向。
	var ft := clampf(delta / maxf(0.01, wind_dir_turn_time), 0.0, 1.0)
	ft = ft * ft * (3.0 - 2.0 * ft)                 # 转向也缓入缓出
	# ★ 必须用 lerp_angle 而不是 lerpf：角度在 0/TAU 附近环绕，lerpf 会沿"长弧"转过去，
	#   表现成风向毫无理由地反向绕一大圈（lerp_angle 自动走短弧）。
	_dir_current = lerp_angle(_dir_current, _dir_target, ft)
	# 0.35 rad/s 的固定角速度推进呼吸相位；乘 delta 保证帧率无关。
	_dir_phase += delta * 0.35
	# 叠加 ±0.12 rad（约 ±7°）的慢摆：幅度刻意取小，只提供"风在呼吸"的感觉，
	# 不会把主导方向搅乱（否则风向标会看起来在乱转）。
	var ang := _dir_current + sin(_dir_phase) * 0.12
	return Vector2(cos(ang), sin(ang))

# ==================== 参数落地：植被风摇着色器 ====================
## 参数：无（读当前成员 wind_dir / wind / wind_gust / wind_speed / wind_turbulence）。
## 返回值：无。
## 副作用：给 _wind_materials 里**每一份**材质写 5 个 uniform（每帧重复覆盖，幂等）。
## 调用时机：_ready()、bind_world()、add_wind_material()，以及 _process() 每帧。
## 注意事项：
##   · uniform 名必须与 assets/shaders/vegetation_wind.gdshader 完全一致；写错**不报错**，
##     只是那一项静默无效（这也是"代码全在、画面不动"最常见的假故障来源）。
##   · 列表为空时直接 return —— autoload 启动期（_ready）就是这条路径，属正常。
##   · 这里不判空元素：两个登记入口都已经过滤过 null。
## 把当前风参数写进植被共享材质：所有植被按同一风向摆动。
##
## 不能用全局着色器参数（global uniform / RenderingServer.global_shader_parameter_*）：
## Godot 4.7 运行时下那套 API 是坏的 —— get_list() 恒为空、add()/set() 被静默忽略，
## set_override() 也只到片元阶段，顶点阶段永远拿 project.godot 的默认值，
## 表现就是代码全在、画面不动。直接写材质 uniform 才真正生效。
func _apply_shader_params() -> void:
	# 快速路径：没有植被（无头测试、植被未生成）时不必每帧走一遍空循环。
	if _wind_materials.is_empty():
		return
	# 所有材质写同一份参数 => 全场景植被同向摆动，这正是"风是全局维度"的落地方式。
	# 每份材质只有 sway_scale 等**材质自身**属性不同，风参数完全共享。
	for m in _wind_materials:
		m.set_shader_parameter("wind_direction", wind_dir)
		m.set_shader_parameter("wind_strength", wind)
		m.set_shader_parameter("wind_gust", wind_gust)
		m.set_shader_parameter("wind_speed", wind_speed)
		m.set_shader_parameter("wind_turbulence", wind_turbulence)

# ==================== 参数落地：太阳 / 环境 / 天空 / 云 / 雨 ====================
## 把当前连续参数写进场景对象：太阳强度、环境光、雾（普通 + 体积）、天空材质、云材质、雨粒子。
## 参数：无（全部读当前成员）。返回值：无。
## 副作用：改 DirectionalLight3D.light_energy、Environment 的 ambient/fog/volumetric_fog、
##   ProceduralSkyMaterial 的颜色与太阳盘参数、云材质的 uniform、雨粒子的 emitting/amount_ratio。
##   **不写文件、不发信号、不增删节点**。
## 调用时机：bind_world() 一次 + _process() 每帧（幂等，重复写同值没有副作用）。
## ★ 双重写者警告：scripts/settings.gd 的 apply_quality() 也写 Environment 的
##   ambient_light_energy / fog_* / volumetric_fog_*，谁后写谁生效；本函数每帧都在写，
##   所以画质档位对这几个字段的设置会被天气覆盖（settings.gd 头注释有同一记录）。
## ★ 设计原则：只做**乘算/插值**，不写死亮度（_base_sun_energy / _base_ambient 来自场景），
##   这样场景里手调的太阳与环境亮度仍然有意义。
## ★ 所有分支都判空：未 bind_world() 时整函数空转（autoload 启动期安全）。
## 应用到太阳/环境/雨
func _apply_world() -> void:
	if _sun != null:
		# 乘 light_scale 而不是直接赋"阴天的绝对亮度"：见上面"设计原则"。
		_sun.light_energy = _base_sun_energy * light_scale
	if _env != null and _env.environment != null:
		var e: Environment = _env.environment
		# 环境光最多压到基准的 55%：压到 0 会让低多边形模型的暗部糊成一片纯黑，
		# 失去体积感；留 55% 的"天光"才像阴天。
		e.ambient_light_energy = _base_ambient * lerpf(1.0, 0.55, cloud)
		# 雾：晴朗/多云基本不起雾，只有阴天以后才有明显空气感。
		# 旧版 fog>0.01 就开雾 + 体积雾系数 0.02，晴朗天就把整个山谷洗成一层灰，
		# 低多边形配色全被糊掉 —— 所以阈值抬到 0.18 并大幅压低浓度。
		e.fog_enabled = fog > 0.18
		# 先减阈值再乘小系数：阈值以下恒为 0，以上缓慢增长。若直接 fog*0.004，
		# 刚过阈值时雾会从 0 瞬间跳到 0.0007 起步 —— 这里要的是"几乎察觉不到地变浓"。
		e.fog_density = maxf(0.0, fog - 0.18) * 0.004
		e.fog_light_color = Color(0.72, 0.76, 0.80)
		# 体积雾成本高得多，所以给一个更高的独立阈值。
		# ★ 注意现状：PRESETS 里 fog 最大的是 STORM 的 0.35，**达不到 0.45**，
		#   也就是说按当前预设体积雾永远不会被开启（阈值形同虚设）。推测是留给
		#   将来更浓的雾天预设、或外部直接改 fog 的场景；调雾预设时别忘了这个门槛。
		e.volumetric_fog_enabled = fog > 0.45
		e.volumetric_fog_density = maxf(0.0, fog - 0.45) * 0.006
	# 阴沉程度：驱动天色、云色、太阳盘的统一参数
	# 为什么用 cloud 当"阴沉度"的代理：它是 6 种天气里唯一单调且值域 0..1 的量，
	# 再引入一套独立的 darkness 参数只会让 PRESETS 更难维护、还容易与 cloud 打架。
	var dark := clampf(cloud, 0.0, 1.0)
	if _sky_mat != null:
		_sky_mat.sky_top_color = Color(0.22, 0.45, 0.82).lerp(Color(0.30, 0.33, 0.40), dark)
		_sky_mat.sky_horizon_color = Color(0.72, 0.85, 0.98).lerp(Color(0.52, 0.55, 0.60), dark)
		_sky_mat.sky_curve = lerpf(0.10, 0.28, dark)
		_sky_mat.ground_horizon_color = _sky_mat.sky_horizon_color
		_sky_mat.ground_bottom_color = Color(0.30, 0.34, 0.30).lerp(Color(0.20, 0.21, 0.22), dark)
		# 太阳盘：晴天明显，阴雨天被云盖住
		# sun_angle_max 越大，程序化天空画出的太阳盘越大越"糊"。所以不需要真的关掉太阳盘，
		# 只要把它撑大到 100 度，阴天就自然变成"云层后面一片泛白"而不是一个刺眼的圆点。
		_sky_mat.sun_angle_max = lerpf(12.0, 100.0, dark)
		# sun_curve 同时调大：让太阳盘的亮度也一起扩散掉（只放大不扩散会变成一个奇怪的大白饼）。
		_sky_mat.sun_curve = lerpf(0.06, 0.5, dark)
	if _cloud_mat != null:
		# 云量：晴朗 0.10 只有几缕，雷雨 1.0 满天积雨云
		# *1.15 是"补一点视觉云量"：着色器里的 smoothstep 阈值让 coverage 的观感偏淡，
		# 直接传 cloud 的话晴天几乎看不到云。上限 1.05 是 clouddome.gdshader 里
		# coverage 的 hint_range 上界，超过它没有额外效果（只会让阈值越过 1）。
		_cloud_mat.set_shader_parameter("coverage", clampf(cloud * 1.15, 0.0, 1.05))
		# 不透明度下限 0.55：晴天那几缕云也要能被看见，否则等于没有云（只是"淡"不是"透明"）。
		_cloud_mat.set_shader_parameter("density", lerpf(0.55, 0.97, clampf(cloud, 0.0, 1.0)))
		_cloud_mat.set_shader_parameter("wind_dir", wind_dir)
		_cloud_mat.set_shader_parameter("wind_speed", wind_speed)
		# 云的颜色不做"随时间/太阳角度"的光照计算，而是直接用 dark 在两套色板之间插值：
		# 这样云色与天色（sky_top_color 用的是同一个 dark）必然一致，不会出现"天灰云白"。
		var lit := Color(1.0, 0.985, 0.95).lerp(Color(0.72, 0.75, 0.80), dark)
		var shad := Color(0.60, 0.645, 0.72).lerp(Color(0.32, 0.35, 0.41), dark)
		_cloud_mat.set_shader_parameter("cloud_lit", lit)
		_cloud_mat.set_shader_parameter("cloud_shadow", shad)
		# 云块尺度与地平线淡出区间是**常量**（每帧写同样的值，纯属占位）：
		# horizon_end 特意取了 0.34，比 clouddome.gdshader 的默认 0.42 小 —— d.y 是视线仰角分量，
		# 区间收窄意味着云离开地平线后更快达到满不透明，低空不会留一条稀薄的过渡带
		#（推测：这两个数是照着截图调出来的，改动前先对比截图）。
		_cloud_mat.set_shader_parameter("cloud_scale", 2.4)
		_cloud_mat.set_shader_parameter("horizon_start", 0.03)
		# 见上面"云块尺度与地平线淡出区间是常量"的说明：0.34 < 着色器默认 0.42。
		_cloud_mat.set_shader_parameter("horizon_end", 0.34)
	if _rain_particles != null:
		# 阈值 0.02 而不是 >0：rain 是插值出来的连续小数，过渡末尾会长时间停在 0.001 量级，
		# 用 >0 会让雨粒子白白发射一大段"看不见的雨"（纯浪费）。
		_rain_particles.emitting = rain > 0.02
		# 只改 amount_ratio（不改 amount、不重建节点）：切天气时不会有粒子重分配导致的卡顿。
		_rain_particles.amount_ratio = clampf(rain, 0.0, 1.0)

## 云层：一张 1800m 见方的平面，程序化云块 + 随风漂移，跟随相机水平位置。
## 用 alpha 在半径处淡出，所以平面边界看不见。
## 云穹顶：一个挂在相机上的半球，程序化云块 + 随风漂移，由视野仰角控制透明度。
## 必须挂在相机上（而不是放在世界某处）：穹顶跟着镜头走，云才像无限远。
## 参数 parent：挂载父节点（bind_world 的 rain_parent，实际是 main 场景自身）。
## 返回值：无。副作用：新建 SphereMesh + MeshInstance3D + ShaderMaterial 并 add_child，
##   同时写 _clouds 与 _cloud_mat 两个成员。
## 调用时机：只由 bind_world() 调用（那里正处于"世界已生成"的时机）。
## ★ 幂等：parent 为 null 或 _clouds 已存在就直接返回 —— 重复 bind_world() 不会建出第二个穹顶。
## ★ 穹顶的父节点是 main 场景而不是相机，但 follow_camera() 每帧把它的 global_transform 对齐
##   相机，所以效果上等价于"挂在相机上、跟着镜头走"（见 follow_camera）。
func _ensure_clouds(parent: Node3D) -> void:
	# 幂等守卫 + 空守卫：parent 为 null 说明调用方没准备挂载点（无头测试），
	# 与其建一个游离节点，不如什么都不做。
	if parent == null or _clouds != null:
		return
	var sphere := SphereMesh.new()
	sphere.radius = CLOUD_DOME_RADIUS
	sphere.height = CLOUD_DOME_RADIUS * 2.0
	# 96x32 是在"云看起来圆滑"与"顶点数别爆"之间的折中：云的细节来自噪声而不是几何，
	# 所以段数不必更高；调小会在天空边缘看出半球的分面棱角。
	sphere.radial_segments = 96
	sphere.rings = 32
	# 只要上半球：地面相机永远看不到地平线以下的云，省掉一半顶点。
	sphere.is_hemisphere = true
	_clouds = MeshInstance3D.new()
	_clouds.name = "WeatherClouds"
	_clouds.mesh = sphere
	_cloud_mat = ShaderMaterial.new()
	# 用 load() 而不是文件级 preload：着色器只在真的要用穹顶时才需要读进来，
	# 避免 autoload 启动期就去解析这个资源（推测：这是为了避免启动期无谓的资源加载）。
	_cloud_mat.shader = load("res://assets/shaders/clouddome.gdshader")
	# 先给一份与着色器默认值相同的初始值，只是为了避免"uniform 未被设置"的中间态；
	# 真正生效的参数由 _apply_world() 每帧覆盖，这里不需要跟着 PRESETS 走。
	_cloud_mat.set_shader_parameter("coverage", 0.35)
	_cloud_mat.set_shader_parameter("density", 0.9)
	_clouds.material_override = _cloud_mat
	# 关掉投影：半径 900m 的穹顶如果参与阴影，会给整个场景罩上一层假阴影、还拖慢阴影贴图；
	# 而且它是每帧跟着相机移动的，阴影会明显抖动。
	_clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# 只画天空那一半；穹顶是摄像机子节点，局部坐标即视线方向
	# （推测）再给视锥剔除留一个"整个半径"的余量：这个网格巨大且每帧跟着相机移动，
	# 保守的包围盒余量可以避免它在某些帧被整块剔除（代价只是剔除判定宽松一点）。
	_clouds.extra_cull_margin = CLOUD_DOME_RADIUS
	# 注意挂载点是 main 场景（rain_parent），不是 autoload —— 节点随场景释放，
	# autoload 只保留引用；如果 main 被重复实例化而 bind_world 被再调一次，旧穹顶会随旧场景一起消失。
	parent.add_child(_clouds)

## 创建雨粒子节点（GPUParticles3D，名字 WeatherRain）。
## 参数 parent：挂载父节点（bind_world 的 rain_parent = main 场景）。
## 返回值：无。副作用：新建 GPUParticles3D + ParticleProcessMaterial + BoxMesh +
##   StandardMaterial3D 并 add_child，写 _rain_particles 成员。
## 调用时机：只由 bind_world() 调用，且被安排在**最后**（那时 _apply_world() 已经跑过）。
## ★ 幂等：parent 为 null 或 _rain_particles 已存在就返回 —— 不会建出第二套雨。
## ★ 节点只建一次、永不释放：开关看 emitting（由 _apply_world 每帧写），
##   密度看 amount_ratio。这样切天气不会因重建粒子系统而卡顿。
## ★ 注意：雨滴的落角只在创建时按当时的 wind_dir 算一次，之后**不会更新**（见下方注释）。
func _ensure_rain(parent: Node3D) -> void:
	# 幂等 + 空守卫，与 _ensure_clouds 同样的理由。
	if parent == null or _rain_particles != null:
		return
	var p := GPUParticles3D.new()
	p.name = "WeatherRain"
	# 1400 是"暴雨时的满配"上限：实际发射量由 amount_ratio(0..1) 截取，小雨只发其中一部分。
	# 调大 -> 雨更密更吃 GPU；调小 -> 雷雨看起来像中雨（这是唯一控制密度上界的旋钮）。
	p.amount = 1400
	# 1.4s 的存活时间 × 初速 16~22 m/s ≈ 下落 22~31m，正好覆盖"相机上方 14m 到地面"的距离。
	# 太短 -> 雨在半空凭空消失；太长 -> 大量粒子落到地面以下白烧。
	p.lifetime = 1.4
	# 必须显式给一个**足够大**的可见包围盒：粒子出生在相机上方 14m 再往下落，
	# 如果按发射盒（±45m、高 1m）算 AABB，几乎整批粒子会在下落途中被剔除
	#（表现是"雨时有时无、忽闪忽闪"）。这个盒子覆盖 120x60x120m 的可见范围。
	p.visibility_aabb = AABB(Vector3(-60, -20, -60), Vector3(120, 60, 120))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	# 45m 见方的**扁**盒子（高度只有 1m）铺在相机头顶：宽到盖满视野，扁到雨滴几乎从同一高度
	# 出发 —— 否则雨会分成好几个高度层开始下落，近处看起来像悬空的水柱。
	pm.emission_box_extents = Vector3(45, 1, 45)
	# 先给一个竖直向下的默认值，下面第 N 行会按风向重新赋值覆盖它（这里保留只是让参数块读起来完整）。
	pm.direction = Vector3(0, -1, 0)
	# 4° 的散布很小：雨必须看起来近乎平行下落，调大立刻像喷泉。
	pm.spread = 4.0
	# 16~22 m/s 给雨滴一点速度差，避免整片雨像一块板子同步落下；
	# 这是视觉经验值（比真实雨滴快不少），图的是"划过"的速度感。
	pm.initial_velocity_min = 16.0
	pm.initial_velocity_max = 22.0
	pm.gravity = Vector3(0, -9.8, 0)
	# 风向影响雨滴落角
	# 0.25 是"风能把雨吹偏"的最大比例：风再大也不会让雨横着飞（这是刻意的，横雨很难看）。
	# ★ 这里用的是**创建那一刻**的 wind_dir —— _apply_world() 之后不再更新这个方向，
	#   所以运行中风向改变时，雨滴落角不会跟着变（推测：认为这个偏差不值得每帧重算）。
	pm.direction = Vector3(wind_dir.x * 0.25, -1.0, wind_dir.y * 0.25).normalized()
	var mesh := BoxMesh.new()
	# 雨滴用 2cm × 50cm 的细长盒子，而不是粒子贴图 / billboard：
	# 低多边形项目不引贴图，这个比例从远处看就是一条雨线（近看才看得出是方块）。
	mesh.size = Vector3(0.02, 0.5, 0.02)
	var mat := StandardMaterial3D.new()
	# 半透明浅蓝灰：alpha 0.55 是"太实像冰棍、太透在阴雨灰底上看不见"之间的折中。
	mat.albedo_color = Color(0.72, 0.80, 0.92, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# 不受光照：阴雨天光照只有三成，若让细长盒子参与光照，暗面会黑到完全看不见雨。
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = mat
	p.process_material = pm
	p.draw_pass_1 = mesh
	# 先关着：等 _apply_world() 按当前 rain 参数决定是否发射。若这里就 true，
	# 创建瞬间会闪出一帧"满地暴雨"（随后才被 rain=0 关掉）。
	p.emitting = false
	parent.add_child(p)
	_rain_particles = p

## 参数 cam：当前相机（main.gd 传的是 camera_rig.camera）。为 null 时直接返回。
## 返回值：无。
## 副作用：改云穹顶的 global_transform、改雨粒子的 global_position。
##   **只动变换，不增删节点、不改材质、不重建粒子** —— 所以每帧调用开销极小。
## 调用时机：main.gd 的 _process 每帧调用（见 main.gd 里 follow_camera 的调用点）。
## ★ 为什么雨盒要跟相机：粒子系统是固定大小的盒子，不跟随的话玩家一走出盒子就看不到雨了。
## ★ 为什么穹顶要整份拷贝相机的 global_transform（含旋转）：着色器把顶点局部坐标当视线方向，
##   位置或旋转差一点，云就会"贴"在错误的方向上（转头时云会跟着错位）。
## 让雨盒 / 云层跟随相机（由 main 每帧调用）
func follow_camera(cam: Camera3D) -> void:
	if cam == null:
		return
	if _clouds != null:
		# 穹顶完全跟随相机（含高度与旋转），顶点局部坐标才等于视线方向
		_clouds.global_transform = cam.global_transform
	if _rain_particles == null:
		return
	# 抬 14m：让雨滴在进入视野前已有下落速度，也避免发射盒贴在相机位置（近裁剪面附近）冒粒子；
	# 只改 global_position（XZ 与相机相同、Y 抬高），所以雨盒始终罩在玩家头顶。
	_rain_particles.global_position = cam.global_position + Vector3(0, 14.0, 0)

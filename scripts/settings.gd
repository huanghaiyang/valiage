## ============================================================================
## settings.gd —— 全局画质 / 性能设置单例（autoload 名 `Settings`）
## ============================================================================
##
## 【本文件职责】
##   把"画质档位"这**一个整数**翻译成一整组渲染 / 植被 / 雾效开关，并在档位变化时立即落地：
##     · 视口 MSAA            → Viewport.msaa_3d
##     · 自动 LOD 阈值        → Viewport.mesh_lod_threshold
##     · 植被视野 / 草丛显隐  → VegetationSystem.view_radius / set_grass_visible()
##     · 体积雾开关与雾密度   → WorldEnvironment.environment
##
## 【所属系统】渲染质量分级 —— 项目"一个档位驱动两套系统"里的**项目原有那一侧**
##   （合并方式见 scripts/settings/settings_apply.gd 顶部说明）：
##     · 本文件 autoload `Settings`  → MSAA / 模型 LOD / 草丛 / 植被距离 / 体积雾
##     · autoload `Quality`（scripts/quality/quality_manager.gd）→ 地表贴图分辨率 / 地形 LOD
##   两侧由 SettingsApply.apply_tier() 用同一个 tier 驱动，所以本文件枚举值必须与
##   设置菜单的 graphics/tier 完全对齐：0=低 1=中 2=高 3=极高（见 settings_schema.gd）。
##
## 【注册位置】project.godot [autoload]：Settings="*res://scripts/settings.gd"
##   （列表中排在 Game= 之后、GameSettings= 之前 —— GameSettings._ready() 要靠
##     SettingsApply.apply_tier() 把磁盘上的档位灌进来，所以本单例必须先存在）
##   ★ 编辑器里 autoload **不加载**：tests/test_settings.gd 是手动 new 出来再加进树测的。
##
## 【主要对外接口】
##   Settings.quality : int        # 0..3；**赋值即落地**（setter 里自动 apply_quality()）
##   Settings.apply_quality()      # 按当前档位重新同步一遍（main.gd 装配完世界后调用）
##   Settings.world_environment / Settings.vegetation_root   # 由 main.gd 注入的场景引用
##   其余开关（show_grass / volumetric_fog / vegetation_distance / mesh_lod_threshold /
##   show_grid / dynamic_sky）都是"纯数据"：改完**需要自己再调 apply_quality()** 才生效。
##   SettingsApply.read_project_tier() 会反读 Settings.quality 用于设置菜单显示当前档位。
##
## 【关键依赖】
##   · 场景：main.tscn 里的 WorldEnvironment 与 VegetationSystem，由 main.gd 在世界生成后注入
##   · 脚本：scripts/world/vegetation.gd（class_name VegetationSystem）、main.gd、settings_apply.gd
##   · 调用方：scripts/main.gd（注入引用 + apply_quality）、scripts/settings/settings_apply.gd
##     （apply_tier / read_project_tier）、tests/test_settings.gd（test_tier_drives_project_settings）
##   · 环境字段还有第二个写入者：scripts/world/weather.gd 的 _apply_world()（见下方"坑"）
##
## 【已知的坑 / 注意事项】
##   1. 声明处的默认值只在"没有任何档位跑过"时有效：apply_quality() 一跑，
##      mesh_lod_threshold / show_grass / vegetation_distance / volumetric_fog 就被档位**覆盖**。
##      想改游戏里实际看到的画面，要改 apply_quality() 的 match 分支，而不是改这里的初值。
##   2. GDScript 语义：属性**声明时的初始值不会走 setter**，所以 quality / mesh_lod_threshold
##      的副作用必须靠 _ready() 手动补一次，否则视口 LOD 会停在引擎默认值。
##   3. apply_quality() 必须在 main.gd 注入 world_environment / vegetation_root **之后**调用；
##      提前调用只更新视口那部分，雾与植被因 is_instance_valid() 为 false 而静默跳过。
##   4. _update_scene_settings() 是**直接改 Environment 资源本体**：main.tscn 里它是场景内嵌的
##      SubResource（不是外部 .tres），因此改动不会写回磁盘，场景重载即恢复文件里的值。
##   5. 只有 `--quality=` 这一个命令行入口（须写在 `--` 之后的用户参数区），且
##      String.to_int() 解析失败会得到 0（最低档）而不是报错；多个 --quality= 时最后一个生效。
##   6. 本文件**不负责持久化**：档位落盘 / 读盘在 scripts/settings/ 下
##      （SettingsStore + GameSettings._ready() → SettingsApply.apply_all()），重启后靠那条链灌回来。
##   7. show_grid / dynamic_sky 目前全项目**没有其它读取方**（推测：预留开关），apply_quality()
##      也不碰它们 —— 改这两个变量不会产生任何可见效果。
##   8. ⚠ 雾的"双重写入"（推测结论，代码事实见 _update_scene_settings 注释）：
##      Weather 会按天气反复写 volumetric_fog_enabled / fog_density，与档位写的**是同一批字段**，
##      谁后写谁生效 —— 所以高画质档位的"体积雾"在晴朗天气里可能被天气关掉。
## ============================================================================
extends Node
# ==================== 一、质量档位定义（枚举 + 显示名） ====================
## 全局设置管理（自动加载单例）
## 管理渲染质量等级与性能选项，支持 NVIDIA/AMD 全系显卡

## 画质档位枚举。数值 0..3 与设置菜单里的 graphics/tier 选项一一对应
## （settings_schema.gd：choices ["低","中","高","极高"]，apply_tier 里 clampi(tier, 0, 3)），
## ★ 因此**不要重排、不要插入新值**，否则菜单档位与本文件的画面设置就会错位。
## 本枚举只用于 apply_quality() 的 match 分支，不参与持久化，也没有对应的字符串存档。
enum Quality { LOW, MEDIUM, HIGH, ULTRA }

## 档位 → 中文显示名的映射表，供 UI / 日志打印用（例如设置菜单标题栏显示"高画质"）。
## 键必须是 enum Quality 的成员，值就是纯展示文案（含括号说明，非本地化资源）。
## ★ 目前全项目搜不到读取方（推测：UI 走的是 settings_schema.gd 里的 ["低","中","高","极高"]，
##   这张表是给调试/后续 UI 预留的）—— 增删条目对画面没有任何影响。
## 注意 LOW 的名字叫"低画质（兼容模式）"，因为该档会关 MSAA、关草、把 LOD 阈值抬到 4.0，
## 主要是为了让 NVIDIA/AMD 的老卡与集显也能跑（与本文件头部说明对应）。
const QUALITY_NAMES := {
	Quality.LOW: "低画质（兼容模式）",
	Quality.MEDIUM: "中画质",
	Quality.HIGH: "高画质",
	Quality.ULTRA: "极致画质",
}

# ==================== 二、画质开关状态（由档位驱动，也可外部直接读写） ====================
## 当前质量等级
## 取值见 enum Quality：0=LOW 1=MEDIUM 2=HIGH 3=ULTRA。
## 默认 HIGH(2)：与设置菜单 graphics/tier 的默认值一致（settings_schema.gd default=2），
##   也与项目原有 MSAA 4x 的现状一致 —— 选它当默认既不放大也不缩水（推测：这就是取 2 的理由）。
## ★ 写这个变量**会立刻落地**：setter 里先 clamp 再调 apply_quality()，
##   所以 `Settings.quality = 3` 等价于"切到极高档并把所有画质开关同步一遍"。
## 非法值：不报错，而是被 clamp 到 [LOW, ULTRA]（-5 → LOW，99 → ULTRA，1.7 → 1）。
## 谁在写它：SettingsApply.apply_tier()（设置菜单 / 启动读盘）、本文件 _ready() 里的 --quality=、
##   以及 tests/test_settings.gd 的档位联动测试。
## 读它：SettingsApply.read_project_tier()（菜单打开时反向同步当前档位）。
var quality: int = Quality.HIGH:
	set(v):
		# 在属性自己的 setter 内给同名属性赋值**不会**再次触发 setter（Godot 4 语义），
		# 所以这里是"写回被 clamp 后的合法值"，不是无限递归。
		quality = clamp(v, Quality.LOW, Quality.ULTRA)
		# 写档位 = 整套落地。放在 clamp 之后，保证 apply_quality() 读到的一定是合法档位。
		apply_quality()

# ---- 草丛 / 雾 / 植被距离：这三项都由 apply_quality() 按档位覆盖 ----
## 是否显示草丛细节
## false 时经 VegetationSystem.set_grass_visible(false) 整体隐藏草丛实例
##   （只切显隐，不销毁实例，所以来回切档不会反复重建植被）。
## 声明默认 true；实际生效值由档位决定：LOW=false，MEDIUM/HIGH/ULTRA=true。
## ★ 只写这个变量不会生效，写完后必须再调 apply_quality()（或直接写 quality 触发级联）。
var show_grass := true

## 是否启用体积雾（高配专属）
## 最终写进 Environment.volumetric_fog_enabled。
## 声明默认 false；档位取值 LOW=false / MEDIUM=false / HIGH=true / ULTRA=true。
## 为什么默认关：体积雾是本档位组里最贵的一项，中低端卡上直接掉帧（注释里"高配专属"即此意）。
## ★ 两个连带副作用（见 _update_scene_settings）：
##   ① 开它时会把**普通雾密度** fog_density 也设成 0.004，关它时设成 0.0；
##   ② Weather 系统按天气写同一批 Environment 字段，可能把这里的值覆盖掉（头注"坑 8"）。
var volumetric_fog := false

## 植被绘制距离
## 单位：米。写进 VegetationSystem.view_radius，决定"哪些植被块被激活/剔除"。
## 声明初值 120.0，但档位会覆盖成 LOW=130 / MEDIUM=170 / HIGH=220 / ULTRA=280 ——
##   即 apply_quality() 跑过之后这个声明值**永远不会被用到**（单改它看不到任何效果）。
## 调大 = 更远也画植被（更卡、更耗显存与物理）；调小 = 近处整块消失（省性能，
##   但块在视野边缘被剔除/激活时容易看到"植被突然冒出来"）。
## ★ 两个参考值别搞混：vegetation.gd 自己的 view_radius 默认 220.0（与本文件初值不同），
##   而植被碰撞体的半径是 vegetation.gd 里**独立**的 collision_radius(60m)，不随本值变化。
var vegetation_distance := 120.0

# ==================== 三、模型精度（自动 LOD 阈值） ====================
## 单位与取值（Godot 语义：阈值越大 → 越早换成低精度 LOD）：
##   0.0        = 关闭自动 LOD（永远用 LOD0，最精细也最贵；即注释里的"0 = 关闭"）
##   0.5        = ULTRA 档用值（比引擎默认更晚降级）
##   1.0        = 引擎默认值，也是 HIGH 档用值（"1.0 是引擎默认值"）
##   2.0 / 4.0  = MEDIUM / LOW 档用值（4.0 = 最早掉精度，为老卡兜底）
## 单位：对应项目设置 rendering/mesh_lod/lod_change/threshold_pixels，可理解为像素阈值。
## 副作用：setter 会调 _apply_mesh_lod() 立刻写进视口；但**声明初值不走 setter**，
##   所以 _ready() 里还手动补了一次。见下方原有说明与 _apply_mesh_lod() 的文档。
## ★ 这里只决定"用哪一级 LOD"，不会重新生成模型：LOD 层级是导入时就烘好的，
##   所以运行期改这个值只花一次赋值的代价，不需要把高模抽面成低模。
## ---- 模型精度（自动 LOD 阈值）----
## 越大 = 越早切到模型的**低精度 LOD 版本**（省 GPU）；越小 = 越精细。
## 引擎在**导入模型时**就生成好了 LOD 层级（导入设置 meshes/generate_lods，默认开），
## 所以"改精度"是**运行时切换**，不需要把高模拿去抽面成低模 ——
## 例如 1.8M 面的水晶树，近距离用 LOD0，中远距离自动降级。
## 0 = 关闭自动 LOD（永远最高精度，最费）。1.0 是引擎默认值。
var mesh_lod_threshold := 1.0:
	set(v):
		mesh_lod_threshold = maxf(0.0, float(v))
		_apply_mesh_lod()

## 是否显示网格辅助线
## 调试用开关：声明默认 false（正式发行不该看到网格）；apply_quality() **完全不碰它**，不会被档位覆盖。
## ★ 全项目搜不到第二个读取方（推测：预留 / 尚未接线）—— 改它目前没有任何可见效果。
var show_grid := false

## 是否启用动态天空
## 天空材质随天气/时间变化。声明默认 true，但同样**没有其它读取方**（推测：天空实际由 Weather 与天空材质资源自己管，
##   见 scripts/world/weather.gd 里 _sky_mat / _cloud_mat 的写法），apply_quality() 也不碰它 ——
##   所以这也是个"看起来能调、其实无效"的开关。
var dynamic_sky := true

# ==================== 四、场景引用（由 main 注入；未注入时为 null） ====================
## 场景引用（由 main 注入）
##
## main.tscn 里的 WorldEnvironment 节点；main.gd 在世界生成后赋值（早于此赋值时为 null）。
## 用途：apply_quality() → _update_scene_settings() 改它的 environment.volumetric_fog_enabled / fog_density。
## 为什么是 null 初值：autoload 先于任何场景存在，无从自取，只能由 main 反向注入
##   （applied by main.gd `Settings.world_environment = env`）。
## ★ 判空用的是 is_instance_valid() 而不是 `!= null`，所以场景切换后残留的"已释放对象"也不会崩。
var world_environment: WorldEnvironment = null
## 植被系统根节点（运行时实际类型为 VegetationSystem，见 scripts/world/vegetation.gd），同样由 main.gd 注入。
## 用途：_update_scene_settings() 里写 view_radius 与调 set_grass_visible()。
## ★ 类型故意声明成宽松的 Node3D（而不是 VegetationSystem）：注入方只要是 Node3D 即可，
##   转换失败（`as VegetationSystem` 得到 null）时静默跳过，不报错。
var vegetation_root: Node3D = null

# ==================== 五、生命周期回调 ====================
## 生命周期回调：确定"档位从哪里来"，并把不吃 setter 的那部分初值补一次。
##
## 参数：无（引擎自动调用）。返回值：无。
## 副作用：
##   1. 把本节点设为 PROCESS_MODE_ALWAYS（暂停时仍照常处理）。本文件目前没有 _process / _input，
##      所以这一行现在**没有可观察效果**（推测：为将来"暂停菜单里改画质"的写法预留）。
##   2. 解析 `--quality=N` 用户参数并写入 quality（写 = 触发 apply_quality()，见函数内注释）。
##   3. 显式调用一次 _apply_mesh_lod()（理由见函数内注释）。
## 调用时机：autoload 挂到 SceneTree.root 时由引擎调用，**早于 main.tscn 的 _ready()**。
## 注意事项：此刻 world_environment / vegetation_root 还是 null，apply_quality() 里
##   "雾/植被"那一步会静默跳过 —— 那部分由 main.gd 在世界装配完成后**再调一次** apply_quality() 补上。
func _ready() -> void:
	# 暂停（get_tree().paused）时本节点仍需响应，否则暂停菜单里切画质不生效（推测用意）。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# 从命令行参数读取质量等级（用于导出版本切换）
	# ★ OS.get_cmdline_user_args() 只返回 `--` 之后的用户参数，所以导出版要用
	#   `CozyVale.exe -- --quality=2` 这种写法，写在 `--` 前面的会被引擎自己吃掉。
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--quality="):
			# 解析失败（如 --quality=abc）时 to_int() 返回 0 = 最低档，**不会报错**；
			# 越界值（--quality=99）由 quality 的 setter clamp 掉；多个参数以最后一个为准。
			var q := arg.trim_prefix("--quality=").to_int()
			quality = q
	# 初始值不会走 setter，所以这里显式把"模型精度"写进视口
	# ★ 没有任何 --quality= 参数时，quality 保持声明初值、其 setter 从未执行过，
	#   所以必须在这里补写一次视口 LOD；有参数时上面 setter 已写过，这里是幂等的重复写。
	_apply_mesh_lod()

# ==================== 六、档位落地（apply_quality 与两个内部函数） ====================
## 按当前 quality 档位，把整组画质参数重新算一遍并落地到引擎与场景。
##
## 参数：无（直接读成员变量 quality，取值 0..3）。
## 返回值：无。
## 副作用（三处，顺序有讲究）：
##   1. 视口级：vp.msaa_3d 按档位设为 DISABLED / 2X / 4X / 8X；
##   2. 成员变量级：mesh_lod_threshold / show_grass / vegetation_distance / volumetric_fog
##      被**档位表覆盖**（其中写 mesh_lod_threshold 会经其 setter 立刻写进视口）；
##   3. 场景级：_update_scene_settings() 写 Environment 的雾与 VegetationSystem 的剔除半径。
## 调用时机：① quality 被赋值时（setter 内）；② main.gd 注入场景引用后显式调一次；
##   ③ SettingsApply.apply_tier() 通过 `set("quality", t)` 间接触发（设置菜单 / 启动读盘）。
## 注意事项：
##   · 每次调用都会把上面 4 个成员变量**重置**为档位预设 —— 所以"手动调一下 vegetation_distance
##     再切档位"会被覆盖掉；要持久生效就改下面 match 分支里的数值。
##   · world_environment / vegetation_root 还没注入时不报错：第 3 步静默跳过（安全但无效）。
##   · 只影响"渲染精度 / 可见性"，不碰分辨率、窗口模式、垂直同步 —— 那些在 settings_apply.gd。
##   · 本函数对同一档位是幂等的：反复调用结果相同，只是白跑几次可见性重建。
func apply_quality() -> void:
	# 将质量设置同步到渲染器
	# 下面每个分支里的 `if vp:` 是 GDScript 的对象真值判断：vp 为 null 时整句短路，
	# 所以"取不到视口"（例如编辑器里 autoload 不加载 / 尚未入树）只会跳过 MSAA，不会崩。
	var vp := get_viewport()
	match quality:
		# 低档（兼容模式）：关 MSAA、LOD 阈值抬到 4.0（最早掉精度）、关草、雾全关。
		# 这一档是给集显/老卡兜底的，画面损失最大，宁可难看也要跑得动。
		Quality.LOW:
			if vp: vp.msaa_3d = Viewport.MSAA_DISABLED
			mesh_lod_threshold = 4.0
			show_grass = false
			vegetation_distance = 130.0
			volumetric_fog = false
		# 中档：MSAA 2X、LOD 2.0、开草但视野较近；仍不开体积雾（体积雾是本组最贵的一项）。
		Quality.MEDIUM:
			if vp: vp.msaa_3d = Viewport.MSAA_2X
			mesh_lod_threshold = 2.0
			show_grass = true
			vegetation_distance = 170.0
			volumetric_fog = false
		# 高档（默认档）：MSAA 4X 与项目原有默认一致；LOD 回到引擎默认 1.0；首次开启体积雾。
		Quality.HIGH:
			if vp: vp.msaa_3d = Viewport.MSAA_4X
			mesh_lod_threshold = 1.0
			show_grass = true
			vegetation_distance = 220.0
			volumetric_fog = true
		# 极高档：MSAA 8X（很费，老卡上会明显掉帧）、LOD 0.5（比默认更晚降级）、
		# 植被视野最远 280m（植被块激活数量最多，CPU/显存开销随之上升）、体积雾开。
		Quality.ULTRA:
			if vp: vp.msaa_3d = Viewport.MSAA_8X
			mesh_lod_threshold = 0.5
			show_grass = true
			vegetation_distance = 280.0
			volumetric_fog = true
	# 场景级落地必须放在最后：上面的赋值才是本次档位的最终值，先算后写才一致。
	# （world_environment / vegetation_root 未注入时此调用无副作用，见其文档。）
	_update_scene_settings()


## 把"模型精度"写进视口。Viewport.mesh_lod_threshold 就是引擎的自动 LOD 阈值，
## 等价于项目设置 rendering/mesh_lod/lod_change/threshold_pixels。
##
## 参数：无（读成员变量 mesh_lod_threshold；量纲可理解为像素阈值，引擎默认 1.0）。
## 返回值：无。
## 副作用：直接写 get_viewport().mesh_lod_threshold —— 这是**视口全局**属性，
##   同时影响该视口内所有带 LOD 的网格（远景降级、近景保持）；不写盘、不进设置文件。
## 调用时机：① mesh_lod_threshold 的 setter 内（所以 apply_quality() 的档位赋值会自动带上这一步）；
##   ② _ready() 里手动补一次（因为声明初值不走 setter）。
## 注意事项：
##   · 视口取不到时**静默跳过**（if vp != null），不报错、也不缓存待办 —— 这是可接受的，
##     因为后续任何一次赋值/切档都会再调到这里。
##   · 只影响"用哪一级 LOD"，不会重新生成模型：LOD 层级是导入时烘好的（见文件头/上方说明）。
func _apply_mesh_lod() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.mesh_lod_threshold = mesh_lod_threshold

## 把档位里"必须落到具体场景节点上"的那几项（雾、植被剔除半径、草丛显隐）同步给场景。
##
## 参数：无（读成员变量 volumetric_fog / vegetation_distance / show_grass 与两个场景引用）。
## 返回值：无。
## 副作用：
##   1. world_environment 有效时：改其 Environment 的 volumetric_fog_enabled，
##      并把 fog_density 在 0.004（开）与 0.0（关）之间切换；
##   2. vegetation_root 有效时：写 VegetationSystem.view_radius，并调 set_grass_visible()。
## 调用时机：只由 apply_quality() 在最后调用（档位变化的唯一出口），外部不应直接调。
## 注意事项（都是踩过的坑）：
##   · 两段 if 互相独立：缺少哪个引用就跳哪一段，因此 main.gd 注入前调用是"安全但无效"。
##   · 改的是 Environment **资源本体**（main.tscn 里是内嵌 SubResource，非外部 .tres）：
##     改动不写盘，重载场景就恢复文件里的值；若该资源被多处引用也会一起变（推测）。
##   · world_environment 存在但没挂 Environment 时，env 为 null → 整段被 `if env` 跳过。
##   · 这里**只写 fog_density，不写 fog_enabled**：也就是"密度为 0"来表达没有雾（推测作法）。
##     而 fog_enabled / volumetric_fog_enabled / volumetric_fog_density 还被
##     scripts/world/weather.gd 的 _apply_world() 按天气反复写 —— **两套系统写同一批字段**，
##     谁后写谁生效。结论（推测）：高画质档位开的体积雾，可能在下一次天气刷新时被天气关掉；
##     main.gd 里 apply_quality() 排在 Weather.bind_world() 之后，只是让档位先落一次。
##   · view_radius 与 set_grass_visible() 的 setter 都会**立刻**跑一次完整的 _update_visibility()，
##     所以一次档位切换会连续触发两次可见性重建（推测：可接受，切档本身不频繁）。
##     另外第一次调用时草丛标志还是旧值，靠第二次调用纠正 —— 结果正确，只是多跑一次。
##   · ★ 植被**碰撞体**半径是 vegetation.gd 里独立的 collision_radius(60m)，不随本档位变化：
##     把 vegetation_distance 调大只增加"看得见"的范围，不会同步扩大建碰撞的范围。
func _update_scene_settings() -> void:
	# is_instance_valid 而非 `!= null`：场景切换后引用可能指向已释放对象，这里能安全跳过。
	if is_instance_valid(world_environment):
		var env: Environment = world_environment.environment
		if env:
			env.volumetric_fog_enabled = volumetric_fog
			# 开体积雾时给普通深度雾一个很淡的底（0.004），关时清零 ——
			# 用同一个开关同时表达两种雾，避免"体积雾关了但画面还有一层灰"（推测用意）。
			env.fog_density = 0.004 if volumetric_fog else 0.0
	if is_instance_valid(vegetation_root):
		# 转换失败（节点不是 VegetationSystem）时 veg 为 null → 静默跳过，不报错。
		var veg := vegetation_root as VegetationSystem
		if veg != null:
			veg.view_radius = vegetation_distance
			veg.set_grass_visible(show_grass)

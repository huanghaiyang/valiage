## ============================================================================
## scripts/game.gd —— 全局游戏状态单例（autoload 名 `Game`）
## ============================================================================
## 【本文件职责】
##   项目里唯一的"全局可变状态口袋"：记录玩家当前选中的建造工具、
##   资源余额（生物质 / 石材）、搭建（拖拽）标志，以及主场景根节点引用。
##   它本身**不处理输入、不执行建造、不画 UI**，只做两件事：
##     1) 存状态；2) 状态变化时广播信号，让 UI 等订阅方被动刷新。
##
## 【所属系统】
##   建造 / 放置系统。真正干活的是：
##     · scripts/main.gd        —— 输入、预览、落地建造、植被回收
##     · scripts/ui/game_ui.gd  —— 工具栏按钮、资源条显示
##   本文件处于两者之间，是它们唯一的共享状态源。
##
## 【关键依赖】
##   · autoload 注册：project.godot 的 [autoload] **第一项**
##       Game="*res://scripts/game.gd"
##     → 全局名 `Game`；且本文件的 _ready 早于主场景与其它 autoload，
##       注册着色器全局参数必须抢这个时机（详见 _register_shader_globals）。
##   · 本文件发出的信号：tool_changed / biomass_changed / stone_changed。
##   · 订阅方：ui/game_ui.gd（tool_changed → _on_tool_changed，
##       biomass_changed / stone_changed → _on_biomass_changed）。
##   · 写入方：main.gd（`Game.world = self`、`Game.current_tool = tool`、
##       回收植被时 `Game.biomass += …` / `Game.stone += …`）。
##   · 着色器：assets/shaders/grass_wind.gdshader、tree_leaves_burn_ds.gdshader、
##       tree_burn_keep_ds.gdshader 等声明了 `global uniform tornado_*`，
##       这些 uniform 必须由本文件注册，否则 shader 直接编译失败。
##
## 【主要对外接口】
##   · var current_tool: int      —— 枚举 Tool，赋值即发 tool_changed
##   · var biomass / stone: float —— 赋值即发对应信号
##   · var is_building: bool      —— 拖拽搭建中标志
##   · var world: Node3D          —— 由 main.gd 注入的场景根
##   · enum Tool、const TOOL_NAMES、get_tool_name() -> String
##
## 【已知的坑 / 注意事项】
##   1. 三个 setter 都是"赋值即发信号"，**不做值比较**：把同一个值再赋一次
##      也会触发信号（UI 会重复刷新一遍）。余额很小，目前可接受；
##      若日后遇到信号风暴，应在 setter 里加 `if v == 字段: return`。
##   2. biomass / stone 全是 **float**（回收量按植被体积给小数），不是整数货币。
##   3. 这两个值是**只增不减**：仓库内唯一的写入点是 main.gd 的回收逻辑（+=），
##      目前没有任何消费/扣除代码（推测：留给后续建造消耗）。
##   4. is_building 仅在此处声明，仓库内暂无其它脚本读写（截止当前代码），
##      属于预留字段（推测：为拖拽建造状态预留，勿随手删除）。
##   5. world 由 main.gd 在场景组装完成后才注入；在此之前的 _ready 早期访问
##      会拿到 null，使用前必须判空。
##   6. 本文件没有 _process：状态全部事件驱动，无需每帧轮询（唯一回调是 _ready）。
## ============================================================================
extends Node
## 游戏状态管理（自动加载单例）
## 记录当前工具、搭建状态、场景引用，供各系统间通信

# ==================== 工具定义（枚举 + 显示名表） ====================
## 工具集：植物不是独立工具，它作为额外变体挂在「树木」「花草」下面
## （见 vegetation.gd 的 _plant_extras），所以这里没有 PLANT。
## 各枚举值含义（枚举值就是整数下标，输入映射 / UI 数组 / 调试打印都直接用它）：
##   NONE=0            无工具（显示名"选择"）：不放置任何东西，鼠标只做选择与相机操作
##   WALL=1            墙壁：单段墙，可拖拽连成一排
##   TOWER=2           塔楼：占地较大的竖向建筑
##   ROOF=3            房屋：整体房屋（显示名与枚举名 ROOF 不同，别被名字误导）
##   TERRAIN_RAISE=4   地形抬升：把地面抬高（其上的植被会被回收换资源）
##   TERRAIN_LOWER=5   地形下陷：把地面压低
##   TERRAIN_FLATTEN=6 地形平整：把地面拉平到目标高度
##   TREE=7            树木：植物变体作为额外选项挂在其下
##   FLOWER=8          花草：同上，植物变体挂在花草下
##   PATH=9            小径：铺设路面
##   DECOR=10          家具：装饰物（显示名"家具"）
##   ERASE=11          橡皮擦：删除已放置的物件
##   MOUNTAIN=12       山体：大块地形隆起
## 注意：新增工具必须**追加到末尾**，不能插在中间 —— 中间插入会平移后面所有值的
##       整数下标，而 main.gd 的按键映射（KEY_1…KEY_0）与 game_ui.gd 的按钮数组
##       都是按顺序写死的，会直接错位。
enum Tool { NONE, WALL, TOWER, ROOF, TERRAIN_RAISE, TERRAIN_LOWER, TERRAIN_FLATTEN, TREE, FLOWER, PATH, DECOR, ERASE, MOUNTAIN }

# ==================== 工具显示名表 ====================
## 枚举值 → 中文显示名。供 UI 提示与调试打印使用（game_ui.gd 经 get_tool_name() 取用）。
## 这里的文案是"给玩家看的"，与枚举名不一定字面一致（例：ROOF → "房屋"）。
## 依赖：game_ui.gd 里另有一份独立的按钮文案数组，改文案时两处都要动，
##       否则工具提示（tooltip）与按钮标题会互相矛盾。
## 注意：值必须覆盖上面枚举的全部成员；缺失时 get_tool_name() 会退回 "未知"。
const TOOL_NAMES := {
	Tool.NONE: "选择",
	Tool.WALL: "墙壁",
	Tool.TOWER: "塔楼",
	Tool.ROOF: "房屋",
	Tool.TERRAIN_RAISE: "地形抬升",
	Tool.TERRAIN_LOWER: "地形下陷",
	Tool.TERRAIN_FLATTEN: "地形平整",
	Tool.TREE: "树木",
	Tool.FLOWER: "花草",
	Tool.PATH: "小径",
	Tool.DECOR: "家具",
	Tool.ERASE: "橡皮擦",
	Tool.MOUNTAIN: "山体",
}

# ==================== 全局状态（工具 / 资源 / 标志位 / 场景引用） ====================
## 当前激活的工具
## 默认**不选中任何放置工具**：开局就举着塔楼/墙壁，点一下鼠标就误建，体验很差。
## 想建造时先在工具栏里点一个（工具列表第一项是"选择"= 无工具）。
## 类型写成 int 而不是 Tool：赋值来源包含 UI 传回的裸整数（推测是为了免去类型转换）。
var current_tool: int = Tool.NONE:
	set(v):
		# setter 里对同名属性赋值实际写的是**底层字段**，不会递归调用 setter
		# （GDScript 4 语义），所以这行不是自赋值 bug，别"顺手修掉"。
		current_tool = v
		# 无条件广播：即使新旧值相同也会发一次信号，订阅方需容忍重复刷新。
		tool_changed.emit(v)

## 工具切换广播。参数 tool 为 Tool 枚举的整数值（已赋值之后才发出，
## 因此槽函数里读 Game.current_tool 拿到的一定是新值）。
## 发出的时机：任何对 current_tool 的赋值（含 main.set_tool() 与快捷键切工具）。
signal tool_changed(tool: int)

## 生物质余额（操作地形/放置时回收植被获得）
## 单位：无（游戏内抽象资源量）；类型 float，因为回收量按植被体积/大小给出小数。
## 默认 0.0 的理由：新开局没有任何回收物，资源必须靠实际清理植被赚取。
## 只增不减：仓库内唯一写入点是 main.gd 的回收逻辑（`Game.biomass += …`），
##   目前没有消费扣除（推测：留给后续建造消耗）。
## 注意：本值属于 autoload 单例，**不随场景切换/重开一局自动归零**。
var biomass := 0.0:
	set(v):
		biomass = v
		biomass_changed.emit(v)

## 生物质变化广播。参数 value 是变化**之后**的余额（不是增量），
## 订阅方（game_ui.gd 资源条）直接拿它刷新显示即可。
## 发出的时机：任何对 biomass 的赋值，一次 `+=` 发一次。
signal biomass_changed(value: float)

## 石材余额（石头单独回收为石材，不混入生物质）
## 单位：无；类型 float，与 biomass 保持一致的接口形态。
## 默认 0.0：同样是开局无资源。石块与生物质**分成两个池子**，是因为
##   两者的来源/用途不同（stone 来自石头，biomass 来自植被），混在一起无法分别扣除。
## 只增不减：唯一写入点是 main.gd 的回收逻辑（`Game.stone += …`）。
var stone := 0.0:
	set(v):
		stone = v
		stone_changed.emit(v)

## 石材变化广播。参数 value 是变化**之后**的余额。
## 注意：game_ui.gd 把本信号也接到 _on_biomass_changed，
##   该槽函数一次同时刷新生物质与石材两行文本，所以没必要再单独刷新石材。
signal stone_changed(value: float)

## 当前是否处于搭建（拖拽）状态
## 语义：玩家按住键进入连续放置（拖拽成排）时为 true，松手/切换工具后为 false。
## 默认 false：开局不在拖拽。目前仓库内暂无其它脚本读写它（截止当前代码），
##   属于预留字段（推测：给拖拽建造状态用的），改动前先全局搜索确认。
var is_building := false

## 场景根节点（由 main 注入）
## 指向 main.gd 所在的主场景根（main.gd 在场景组装完成后执行 `Game.world = self`）。
## 默认 null：autoload 的 _ready 早于主场景，注入前访问只能拿到 null，
##   任何使用点都必须先判空，否则会崩。
## 目前仓库内只有写入方、暂无读取方（截止当前代码），属于预留接口。
var world: Node3D = null

# ==================== 生命周期（_ready 与着色器全局参数注册） ====================
## Godot 生命周期回调：autoload 节点进入场景树时由引擎调用一次，无需手写调用。
## 参数：无。
## 返回值：无。
## 副作用：
##   1) 把自身进程模式设为 ALWAYS。settings_menu.gd 打开设置会真的执行
##      get_tree().paused = true；本文件当前没有 _process/输入回调，
##      所以这行现在更像"与其它 autoload（settings.gd / wind.gd 等）统一的约定"，
##      作用是保证日后若在此加入轮询逻辑，暂停期间也不会跟着停摆。
##      注意：暂停**不会**阻止属性赋值与信号广播，它只停 _process 一类回调。
##   2) 注册 tornado_* 全局着色器参数（幂等，已存在的跳过）。
## 调用时机：游戏启动时，早于主场景与其它 autoload 的 _ready；
##   因此这里**不能**访问主场景节点（此时 master 场景还没实例化，Game.world 仍是 null）。
## 注意：本函数必须保持"轻、无依赖"，否则会拖慢甚至打断启动。
func _ready() -> void:
	# 设为 ALWAYS：settings_menu.gd 打开设置时会把 get_tree().paused 置为 true，
	# 若保持默认的 INHERIT，本节点会随场景树一起被冻结（_process/输入回调停发）。
	# 本文件目前没有这类回调，此行是为日后加轮询逻辑留的安全垫，也与其它 autoload 一致。
	process_mode = Node.PROCESS_MODE_ALWAYS
	# ★★★ 注册龙卷风风场的全局着色器参数（用户要求：**用代码注册** ✓）
	_register_shader_globals()


## ★★★ 用代码注册全局着色器参数 ✓（龙卷风的局部风场 tornado_* ✓）
##   为什么需要 ✗：project.godot 的 [shader_globals] 里虽然声明了 ✓
##     但运行中的编辑器/实例用的是**启动时的内存设置** ✓
##     → 一旦没读到，所有含 `global uniform tornado_*` 的 shader 都会**编译失败** ✓✓
##     （实测报错：`全局 uniform"tornado_pos"不存在。请在项目设置中创建。` ✓）
##   放在这里 ✓：Game 是**第一个 autoload** ✓ → 它的 _ready 早于主场景 ✓
##     → 一定赶在材质/着色器编译之前 ✓（放 blue_tornado 里就太晚了 ✗）
##   幂等 ✓：已存在的跳过（重复 add 会报错 ✓）
## 参数：无 —— 要注册的参数表（defs）写死在函数体内，增减参数只能改这里。
## 返回值：无。
## 副作用：向 RenderingServer 注册全局着色器变量；仅当本次真的补注册了参数时才打印日志。
## 调用时机：只由 _ready 调用一次，必须早于任何材质/着色器编译。
## 注意：函数体必须先取一次已有参数列表再比对，保证重复启动/热重载时不报错。
func _register_shader_globals() -> void:
	# 取当前已注册参数名的快照，循环里直接查这份列表，避免反复查询引擎。
	var existing := RenderingServer.global_shader_parameter_get_list()
	# 待注册参数表，每项为 [名称, Variant 类型, 默认值]。
	# 默认值刻意取"风场关闭"态（strength/radius = 0）：shader 里用
	# `if (tornado_strength > 0.001)` 判断，为 0 时整段风场位移不生效，
	# 所以即使这里刚注册完没人写入，也不会把草/树叶吹歪。
	var defs := [
		["tornado_pos", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO],
		["tornado_radius", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
		["tornado_strength", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0],
		["tornado_swirl", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 1.0],
	]
	# 只用来决定要不要打印日志，不参与逻辑。
	var added := 0
	# d[0] = 参数名，d[1] = RenderingServer 的 GLOBAL_VAR_TYPE_* 常量，d[2] = 默认值。
	for d in defs:
		# 幂等的关键：只在缺失时注册 —— 对已存在的同名参数再 add 会直接报错。
		if not existing.has(d[0]):
			RenderingServer.global_shader_parameter_add(d[0], d[1], d[2])
			added += 1
	# 参数由 project.godot 的 [shader_globals] 提供时通常为 0，保持启动日志干净。
	if added > 0:
		print("[ShaderGlobals] ✓ 补注册龙卷风风场参数 %d 个（其余已存在 ✓）" % added)


# ==================== 对外查询接口 ====================
## 取当前工具的**中文显示名**（给 UI 提示 / 调试打印用）。
## 参数：无（读取成员 current_tool）。
## 返回值：TOOL_NAMES 中对应的字符串；若 current_tool 不是已知枚举值（越界或未初始化），
##   返回兜底字符串 "未知"，不会报错也不会返回 null。
## 副作用：无（纯查询，不发信号、不改状态）。
## 注意：这是 UI 层唯一被允许的"工具名"来源（game_ui.gd 的 tooltip 用它），
##   新增工具时若忘了补 TOOL_NAMES，这里就会静默显示 "未知"。
func get_tool_name() -> String:
	return TOOL_NAMES.get(current_tool, "未知")

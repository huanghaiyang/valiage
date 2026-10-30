extends Node
## ============================================================================
## 文件：scripts/spells/spell_caster.gd　（自动加载名：SpellCaster，见 project.godot 的 [autoload]）
## 所属系统：法术系统（scripts/spells/）的**控制器 / 宿主**。本文件不做任何视觉表现，
##   只负责五件事：找玩家与法杖 -> 按 SPELLS 表实例化"术法视觉脚本" -> 处理施法输入
##   -> 驱动通用选点器 -> 把施法动作转交给 player.gd。
##
## 关键依赖（一律用 has_method/call 松耦合，对方缺接口时降级而不是崩）：
##   · 自动加载：Mana（蓝量）。扣蓝在**各视觉脚本内部**；本文件刻意不读蓝量，理由见 _process。
##   · 脚本：spell_wheel.gd（法术圆盘，_ready 里 new 一个挂到 root）、
##           spell_targeting.gd（通用选点器，首次需要时才懒创建，挂到 root）。
##   · 组："player"（_find_player 优先按组找；找不到再全树按名字兜底）。
##   · 玩家侧接口：player.gd::start_spell_cast / stop_spell_cast（**幂等**，可每帧调）。
##   · 术法视觉侧接口（按需实现，全部 has_method 探测）：
##       setup(player, staff) / start_cast() / stop_cast()   —— 基础三件（必需）
##       is_casting()       —— 独立实例"这一发演完没有"，_sweep_instances 靠它回收
##       wants_cast_anim()  —— 一次性法术要求"动作没演完就别收势"
##       has_targeting() / targeting_config() / cast_at(c, r) / cast_sector(c, r, axis, half)
##   · 资源路径：SPELLS 表里的 8 个 res://scripts/spells/*.gd。
##
## 主要对外接口：
##   select_spell(id: String) -> void   选中术法（传 "" = 清空）；会先把施法"上膛"锁掉
##   stop_spell() -> void               清空选中并让当前视觉 stop_cast()
##   可读成员：selected / jet / wheel / enabled / wheel_action / cast_action
##
## 已知的坑（动这些地方之前先看对应位置的注释）：
##   1. "按下那一瞬是否落在 UI 上"**只能在 _input（事件阶段）判定**；放 _process 会误判成
##      世界区按下 -> 选完法术当帧自动施法（见 _input / _ui_blocks_cast 的说明）。
##   2. 施法键状态用 Input.is_*_pressed() **轮询**，不能用 _unhandled_input：main.gd /
##      camera_rig.gd 也在 _unhandled_input 里处理鼠标，谁先 set_input_as_handled() 谁吃掉事件。
##   3. 一次性法术必须走**独立实例**（_spawn_cast_instance）；退回共享 jet 时第二发会被
##      法术自己的状态机静默忽略。
##   4. 切法术必须**重新下发 targeting_config**（靠签名比对），否则"圆盘 <-> 扇形"配置串台。
##   5. 本节点是 autoload，不在 current_scene 下，所以视觉/实例一律挂在
##      **player.get_parent()**（玩家的兄弟节点）上，而不是 player 的子节点。
## ============================================================================
## 法术施放控制器（自动加载为 SpellCaster）。
##
## 为什么做成自动加载：这样**完全不用改你的场景** —— 它自己在运行时找到玩家和手里的法杖，
## 挂上当前选中的术法视觉，并弹出法术圆盘。
##
## 操作：
##   Q          -> 唤出 / 收起 法术圆盘（InputMap 动作 spell_wheel；没有该动作才退回读 E）
##   E          -> 交给 main.gd 做场景交互（_try_interact），**法术这边不再占用 E**
##   左键点圆盘 -> 选中术法 -> 圆盘关闭
##   按住左键   -> 持续施放（火焰喷射朝前方喷、火焰编织在身前竖起火柱），魔法值耗尽自动停
##
## 术法在下面的 SPELLS 里注册；换术法时旧视觉会被停掉并释放。

# ==================== 常量：圆盘脚本 / 术法注册表 ====================
## 法术圆盘界面脚本（CanvasLayer + Control，铺满全屏，靠 visible 开关）。
## 本文件只 new() 一个实例挂到 root，并消费它的 spell_chosen 信号；
## 布局、按钮、开关逻辑全在 spell_wheel.gd 内部，这里不碰。
const SpellWheel := preload("res://scripts/spells/spell_wheel.gd")
## 术法注册表：id -> 视觉来源（GDScript 或 PackedScene）。视觉脚本只要实现
##   setup(player, staff) / start_cast() / stop_cast()
## 这三件事即可；瞄准方向与起始位置由 scripts/spells/spell_aim.gd 共用。
## 想换回着色器版火焰喷射：把 "flame_jet" 的值改成 preload(".../flame_visual.gd")。
## ★ 用 var 而不是 const：Mod 系统（autoload Mods）启动时会通过 register_spell() 追加条目。
var SPELLS := {
	"flame_jet": preload("res://scripts/spells/flame_jet_particles.gd"),
	"fire_tornado": preload("res://scripts/spells/fire_tornado_particles.gd"),
	"blue_tornado": preload("res://scripts/spells/blue_tornado.gd"),
	"detect_pulse": preload("res://scripts/spells/detect_pulse.gd"),
	"flame_scorch": preload("res://scripts/spells/flame_scorch.gd"),
	"flame_advance": preload("res://scripts/spells/flame_advance.gd"),
	"gold_body": preload("res://scripts/spells/gold_body.gd"),
	"water_heal": preload("res://scripts/spells/water_heal.gd"),
	"invisibility": preload("res://scripts/spells/invisibility.gd"),
	"blood_flower": preload("res://scripts/spells/blood_flower.gd"),
}
# 注册表小抄（按各视觉脚本的实际实现核对，改动术法时可对照）：
#   需要选点进圈(has_targeting)：blue_tornado / flame_advance / flame_scorch / blood_flower
#     其中只有 flame_advance 提供 cast_sector（中轴 + 半角 -> 扇形），其余走 cast_at（圆心 + 半径）
#   一次性法术(wants_cast_anim)：flame_scorch / water_heal —— 动作没演完不收起施法姿势
#   invisibility 没有视觉节点：效果宿主挂在角色下（invisibility_effect.gd），
#     共享 jet 只负责"每次按下 -> refresh"，切法术时 jet 被释放也不影响 60s 计时
#   flame_jet / fire_tornado 只有基础三件：按住期间持续演，松手停，不参与选点


# ==================== 术法动态注册（Mod 用） ====================
## 注册一个新术法（由 autoload Mods 在启动时调用；普通玩法不需要碰）。
## 参数：
##   id     —— 术法英文 id（= SPELLS 的键，也是圆盘槽位的 value）；重名会被拒绝。
##   source —— GDScript（走 new()）或 PackedScene（走 instantiate()），两种都支持。
##   name   —— 圆盘上显示的中文名（空则退回显示 id）。
## 返回值：true = 注册成功；false = id 空/重名/来源类型不支持。
## 副作用：写 SPELLS、转发给圆盘 register_spell()（分配一个空槽位）。
## 注意：必须在圆盘建好之后调用（autoload Mods 排在 SpellCaster 之后）；
##   圆盘还没建好时只登记 SPELLS，术法能施放但圆盘里选不到。
func register_spell(id: String, source: Variant, name := "") -> bool:
	if id.is_empty() or SPELLS.has(id):
		return false
	if not (source is Script or source is PackedScene):
		return false
	SPELLS[id] = source
	if wheel != null and is_instance_valid(wheel) and wheel.has_method("register_spell"):
		wheel.call("register_spell", id, name if not name.is_empty() else id)
	return true


## 把注册表里的"术法来源"实例化成节点（GDScript -> new() / PackedScene -> instantiate()）
func _spell_new(source: Variant) -> Node3D:
	if source is PackedScene:
		return (source as PackedScene).instantiate() as Node3D
	if source is Script:
		return (source as Script).new() as Node3D
	return null


# ==================== 导出配置（可在检查器里改，不写场景也能生效） ====================
## 法术系统总开关。false 时 _process 一进来就把角色从施法姿势放出来（_update_cast_anim(false)），
## 并且不再处理圆盘与施法输入；**不会**主动释放已选中的术法与视觉节点（selected/jet 保持原样）。
## 默认 true：这是玩家的核心操作入口，只有做剧情/过场时才建议临时关掉。
@export var enabled := true
## 法术圆盘的唤出/收起动作名。InputMap 里存在该动作就用它；
## 不存在则退回直接读 **E 键**（见 _just_pressed_wheel）。E 已不再用于世界交互
## （交互交给 main.gd 的 _try_interact），所以缺动作时用 E 是安全的。
@export var wheel_action := "spell_wheel"     ## 输入动作名（没有就退回直接读 E）
## 施法键的输入动作名。InputMap 里存在该动作就用它；不存在则退回直接读 **鼠标左键**
## （见 _cast_held）。所以就算忘了配动作，鼠标左键也一定能施法。
## 改名的效果：换成别的动作即可把施法改绑到键盘/手柄按键，其余逻辑无需改动。
@export var cast_action := "spell_cast"       ## 没有就退回直接读鼠标左键
## 自动重新搜索玩家 / 法杖的间隔（单位：秒）。默认 0.5s 是"够快又不浪费"的折中：
## 换场景、重载、换角色或法杖被替换后最多半秒就能重新挂上。
## 调小（如 0.1）反应更快，但每次触发都要全树遍历（_find_player 的兜底搜索是 O(节点数)）；
## 调大（如 3.0）则切场景后法术会"哑"几秒才恢复。
@export var auto_find_interval := 0.5


# ==================== 运行期状态 ====================
## 法术圆盘实例（_ready 里 new 出来挂到 root）。它自己铺满全屏，靠 visible 控制开关；
## 别的地方不要再 new 一份，否则两个圆盘会抢输入、is_open 判定也会互相打脸。
var wheel: CanvasLayer = null
## 当前术法的"共享视觉节点"（同一时刻最多一个；换术法时旧的 stop_cast + queue_free）。
## 用途：按住式法术（火焰喷射 / 火龙卷）在这里持续演出；
## 一次性法术只用它当"当前选中"的代理（挂选点配置、查 wants_cast_anim），
## 真正演出的节点是 _spawn_cast_instance() 造出来的独立实例。
var jet: Node3D = null            ## 当前术法的视觉节点
## 当前选中的术法 id（SPELLS 的键）；"" = 没选 = 不施法也不进选点。
## 注意：主动技**施放一次后会被立刻清空**（见 _update_targeting 尾部 select_spell("")），
## 想连发必须重新开圆盘选一次（松手即可立刻再放）。
var selected := ""
var _jet_spell := ""              ## jet 是哪个术法的视觉（换术法时据此重建）

## 运行时找到的玩家节点（可能为 null）。每 auto_find_interval 秒重找一次，
## 用组 "player" 优先、全树按名字兜底（见 _find_player）。
var _player: Node3D = null
## 玩家手里的法杖节点（优先挂 held_staff.gd 的节点，其次名字含 staff 的 Node3D）。
## 本文件只把它原样传给视觉脚本的 setup()，**不读也不改它的变换**（握点/朝向的坑见技术文档）。
var _staff: Node3D = null
## 自动重找玩家 / 法杖的计时器（秒）：累加到 auto_find_interval 就触发一次 _find_nodes()
var _timer := 0.0
## 本帧是否"正在施法"（按住 + 已上膛 + 没被 UI 挡 + 选中非空）。每帧重算，
## 只用于本帧启停视觉与动画，**不要**当跨帧状态用。
var _holding := false
## 施法许可：这一轮"按住"是否允许施法（规则见 _process 里的施法段）
var _cast_armed := true
var _cast_down_prev := false      ## 上一帧的按键状态：用来自己检测"按下"那一瞬
## 这一次"按下"是否落在 UI 上。**必须在事件阶段判定**（见 _input），
## 不能在 _process 里判：点圆盘选法术时圆盘会在同一帧内 close()，等到 _process
## 跑起来鼠标下已经没有 Control 了，会被误判成"在世界区按下"从而当帧施法。
var _cast_press_blocked := false
## 施法动作是否已经打开（对应 player 侧的施法动画状态）。只在开关切换时通知 player，
## 避免每帧重复 play() 把施法剪辑重置回第一帧。
var _cast_anim_on := false
## 通用施法区域选择器（懒创建；哪个法术声明 has_targeting() 就用它）
const Targeting := preload("res://scripts/spells/spell_targeting.gd")
var _targeting: Node3D = null
## 上一次下发给选点器的配置签名 —— 切换法术（圆盘 <-> 扇形）时靠它触发重新 configure
var _targeting_cfg_sig := ""
## 刚放完法术 -> 等鼠标抬起再让圆圈重新出现，否则会立刻又冒出来
var _target_wait_release := false


# ==================== 生命周期 ====================
## autoload 首次进树时由引擎调用（**只跑一次**）：建圆盘、接信号。
##
## 参数：无。
## 返回值：无。
## 副作用：把 process_mode 设成 ALWAYS（暂停中也处理输入与施法）、开启 _input 回调、
##   把一个全新的 spell_wheel.gd 实例**延迟**挂到 get_tree().root，
##   并连接 wheel.spell_chosen -> _on_spell_chosen。
## 时机：autoload 注册阶段；此时 current_scene 可能还没就绪，所以这里**不**去找玩家/法杖，
##   那件事交给 _process 里的定时重找（_find_nodes）。
## 注意：圆盘必须挂 root —— 本节点是普通 Node（不是 CanvasItem），挂在自己下面显示不出来；
##   而且挂 root 才不会被 current_scene 的切换连带影响。
func _ready() -> void:
	# 暂停（Paused）时也要能开圆盘、结算法术，所以不跟随场景的 process_mode
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_input(true)        # 施法"按下"要在事件阶段判定是否落在 UI 上，见 _input
	# 圆盘推迟到本帧末入树：_ready 期间场景树还在构建，直接 add_child 到 root 可能报"树正忙"（推测）
	wheel = SpellWheel.new()
	wheel.name = "SpellWheel"
	get_tree().root.add_child.call_deferred(wheel)
	# 圆盘只负责回答"用户点了哪个法术"，施法规则全部留在本文件
	wheel.spell_chosen.connect(_on_spell_chosen)


# ==================== 主循环：每帧状态机 ====================
## 每帧驱动整套法术流程：清理实例 -> 重找玩家/法杖 -> 圆盘开关 -> 施法轮询 -> 选点 -> 施法动画。
##
## 参数：delta = 距上一帧的秒数（本文件只拿它累加 _timer，做 auto_find_interval 计时）。
## 返回值：无。
## 副作用：可能 queue_free 已演完的独立实例、创建/释放视觉节点、开关选点器、
##   调用 player.start_spell_cast / stop_spell_cast、调用视觉的 start_cast / stop_cast，
##   以及在诊断分支里 print（见 _update_targeting 里的两处）。
## 时机：每帧（process_mode = ALWAYS，游戏暂停时照跑）。
## 注意：**判定顺序是有意义的，不要随手重排**：
##   _sweep_instances 必须最先；enabled 检查必须最早；_update_targeting 的 return
##   必须早于"按住施法"段 —— 这两种施法模型互斥（选点法术不走按住逻辑）。
func _process(delta: float) -> void:
	_sweep_instances()      # ★ 每帧清理"已演完"的独立实例 ✓（不加数量上限 ✓）
	if not enabled:
		# 控制器被关掉时不能把角色留在施法姿势上
		_update_cast_anim(false)
		return
	_timer += delta
	# 定时重找或引用已失效：换场景 / 换角色 / 法杖被整体替换后，靠这一步自动重新挂上
	if _timer >= auto_find_interval or _player == null or _staff == null:
		_timer = 0.0
		_find_nodes()
	# 圆盘开关
	if _just_pressed_wheel():
		if wheel != null:
			wheel.call("toggle")
	# 施法（按住左键）
	# 规则两条，**全部轮询判定**，不依赖事件是否被 UI 消费：
	#   1. 鼠标下压着 UI 时不施法（面板 / 圆盘 / 小地图 / 量表，见 _ui_blocks_cast）；
	#   2. "按下"那一瞬若落在 UI 上，这一整轮按住作废 —— 直到真正抬起才重新上膛。
	#      这条专治"点轮盘选法术 / 点法杖列表，法术当场放出去"。
	# 为什么不用 _unhandled_input 收施法：main.gd / camera_rig.gd 也在 _unhandled_input
	# 里处理鼠标，谁先 set_input_as_handled() 谁就把事件吃掉，用事件接收会时灵时不灵
	# （settings_menu.gd 里有同款坑的注记）。Input.is_mouse_button_pressed() 是全局
	# 按键状态、不受消费影响，所以这里自己逐帧检测"按下"那一瞬，再配一次 UI 命中测试。
	var down := _cast_held()
	if down and not _cast_down_prev:
		_cast_armed = not _cast_press_blocked     # 按下那一瞬是否在 UI 上（_input 里已判定）
	elif not down:
		_cast_armed = true                       # 真正抬起 -> 重新上膛
	var just_pressed := down and not _cast_down_prev
	_cast_down_prev = down
	_holding = down and _cast_armed and not _ui_blocks_cast()
	_ensure_jet()          # 选中变化 -> 换视觉
	# ★ 通用选点：法术声明 has_targeting() 时先给它显示施法区域圆圈，
	#   鼠标按下才把 (中心, 半径) 交给法术（一次性），不走"按住施法"那套。
	if _update_targeting(down, just_pressed):
		return
	# 是否真的在施法：选了法术 + 按住 + 没被 UI 挡住 + 视觉节点有效。
	# ★ 刻意**不看蓝量**：蓝耗尽时视觉自己会停（各视觉的 ran_out_of_mana），
	#   但动画若跟着蓝量一起抖，会在回蓝阈值上来回闪。手上保持"我在施法"的
	#   姿势更稳，观感也更像在硬撑。
	var casting := _holding and not selected.is_empty() \
			and jet != null and is_instance_valid(jet)
	# ★ 施法动作：按住施放时跟着按住；**一次性法术**则由法术自己要求保持 ——
	#   否则松手那一瞬 stop_spell_cast() 就把动作切断了
	#   （症状：一次性法术的施法动作没完整执行一次）。
	var anim_on := casting
	if not anim_on and jet != null and is_instance_valid(jet) \
			and jet.has_method("wants_cast_anim"):
		anim_on = bool(jet.call("wants_cast_anim"))
	# 动画状态与视觉启停**分开算**：动画可以因为"一次性法术要求保持"而继续开着，
	# 而共享视觉的 start/stop 只看 casting，两者不必一致（见下一段）
	_update_cast_anim(anim_on)
	# 共享视觉只负责"按住式"演出；一次性法术真正演出的是独立实例，
	# 因此这里对共享视觉反复 start/stop 不会打断已经在跑的独立实例
	if jet != null and is_instance_valid(jet):
		if casting:
			jet.call("start_cast")
		else:
			jet.call("stop_cast")


# ==================== 输入判定（动作优先，缺失就退回读键） ====================
# ---------------------------------------------------------------- 输入（动作优先，缺失就退回读键）
## 本帧是否"刚刚按下"圆盘键（只报"按下"沿，按住不会连续为 true）。
##
## 参数：无。
## 返回值：true = 这一帧是按下那一瞬（上一帧尚未按下）；false = 没按 / 一直按着。
## 副作用：无输入副作用，但会更新成员 _e_prev（仅退回读 E 的分支）。
## 时机：每帧由 _process 调用**恰好一次**（每次调用都会推进 _e_prev）。
## 注意：配了 InputMap 动作时直接用引擎的 just_pressed；没配才退回读 E 并自算沿。
func _just_pressed_wheel() -> bool:
	if InputMap.has_action(wheel_action):
		return Input.is_action_just_pressed(wheel_action)
	# ★ _e_prev 必须**每帧都更新**，所以不能用 `... and not _e_was_down_prev()` 那种写法：
	#   更新 _e_prev 的代码一旦放到 and 右边，GDScript 的短路求值会在"E 没按下"时整段跳过，
	#   于是松开 E 后 _e_prev 永远停在 true -> E 一局只能生效一次
	#   （症状：选完法术再按 E 唤不出轮盘）。
	var now := Input.is_key_pressed(KEY_E)
	var just := now and not _e_prev
	_e_prev = now
	return just

## 上一帧 E 键是否按下（只给"没配 spell_wheel 动作"的退回分支用）。
## 写在函数后面是历史写法（GDScript 允许成员变量出现在函数之间），顺序不影响语义。
var _e_prev := false


## 施法键是否处于"按下"（只读全局按键状态；**不**代表允许施法，许可见 _cast_armed）
##
## 参数：无。
## 返回值：true = 物理上按着（配了动作就查动作，否则查鼠标左键）。
## 副作用：无（纯查询）。
## 时机：_process 每帧调用一次，用来自己算"按下 / 松开"的沿（_cast_down_prev）。
## 注意：它**不**看 UI 命中、也不看上膛状态；能否真的施法还要 _cast_armed 与 _ui_blocks_cast。
func _cast_held() -> bool:
	if InputMap.has_action(cast_action):
		return Input.is_action_pressed(cast_action)
	return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


## 事件阶段记录"这一次按下是否落在 UI 上"。
## 为什么必须在这里判：Godot 的事件顺序是
##     Node._input  ->  GUI(Control._gui_input)  ->  Node._unhandled_input
## 而 _process 在这三者之后才跑。点圆盘选法术时，圆盘会在 GUI 阶段就 close()
## （visible = false），等 _process 再判"鼠标下有没有 Control"时已经什么都没有了，
## 于是被当成"在世界区按下"-> 当帧施法（实测症状：选完法术立刻被释放）。
## 在 _input 里判，看到的还是"点击前"的 UI 状态（圆盘还开着），判定才准。
##
## 参数：ev = 引擎下发的事件；本函数只看鼠标左键按钮事件，或（配了 cast_action 时的）该动作事件。
## 返回值：无。
## 副作用：写 _cast_press_blocked。
## 时机：输入事件阶段，早于 GUI 与 _process。
## 注意：**绝不** set_input_as_handled() —— main.gd / camera_rig.gd 还要用同一个事件。
##   松开时也会重算一次（pressed=false -> 标志为 false），但"按下那一瞬"的结论此刻
##   已经在 _process 里结算进 _cast_armed 了，所以不会把本轮的判定抹掉。
func _input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_cast_press_blocked = mb.pressed and _ui_blocks_cast()
	elif InputMap.has_action(cast_action) and ev.is_action(cast_action):
		_cast_press_blocked = ev.is_pressed() and _ui_blocks_cast()


## 鼠标下是否压着 UI（面板 / 圆盘 / 小地图 / 量表…）——**操作 UI 时不施法**。
## 全屏 Control 只在打开时才 visible（轮盘关闭时 CanvasLayer.visible = false；
## 大地图 big_root.visible = false），所以它们不会常年把鼠标挡成"UI 区域"。
##
## 参数：无。
## 返回值：true = 鼠标下压着 UI（或圆盘正开着）→ 本轮不该施法。
## 副作用：无（纯查询；不会真的派发 UI 事件）。
## 时机：被 _input（记录"按下那一瞬"）与 _process（每帧过滤）两处调用。
## 注意：判定分两半 —— 圆盘单独用 is_open()（它虽铺满全屏，但鼠标未必已在它上面），
##   其余 UI 用 viewport 的 gui_get_hovered_control()（只能查出"鼠标当前位置"的控件）。
func _ui_blocks_cast() -> bool:
	# 圆盘铺满全屏，但鼠标未必已经移到它上面，所以单独判"是否打开"
	if wheel != null and is_instance_valid(wheel) and bool(wheel.call("is_open")):
		return true
	var vp := get_viewport()
	if vp == null:
		return false
	return vp.gui_get_hovered_control() != null


# ==================== 玩家 / 法杖 定位 ====================
# ---------------------------------------------------------------- 找玩家与法杖
## 定时（或引用失效时）重新缓存 _player / _staff。
##
## 参数：无。
## 返回值：无。
## 副作用：写成员 _player / _staff（只做"还没有或已失效"才重找，不会每帧覆盖有效引用）。
## 时机：_process 里 _timer 到达 auto_find_interval 时，或 _player / _staff 为 null 时。
## 注意：_staff 只在"已经有 _player"时才找（法杖是玩家子树里的节点）；
##   找不到玩家时保留旧的 _staff 引用不动，避免雪崩式清空。
func _find_nodes() -> void:
	if get_tree() == null:
		return
	if _player == null or not is_instance_valid(_player):
		_player = _find_player()
	if _player != null and (_staff == null or not is_instance_valid(_staff)):
		_staff = _find_staff(_player)


## 找出玩家节点。两级策略：先按组 "player"，失败再全树深度优先按名字兜底。
##
## 参数：无。
## 返回值：找到的 Node3D；找不到返回 null（不是报错——场景可能还没加载完）。
## 副作用：无（纯查询）。
## 时机：由 _find_nodes 调用，频率受 auto_find_interval 限制。
## 注意：兜底搜索遍历的是 current_scene 整棵树，节点多时是 O(N)，
##   所以别把 auto_find_interval 调得过小；组优先也保证了正常项目走的是 O(1) 分支。
func _find_player() -> Node3D:
	if get_tree().current_scene == null:
		return null
	# 优先按组找：角色脚本自己 add_to_group("player") 时最可靠
	var g := get_tree().get_first_node_in_group("player")
	if g is Node3D:
		return g
	# 兜底：全树遍历，取名字里含 "player" 的 Node3D（大小写不敏感，兼容 Player / player_01）
	var stack: Array = [get_tree().current_scene]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is Node3D and String(n.name).to_lower().contains("player"):
			return n as Node3D
		for c in n.get_children():
			stack.append(c)
	return null


## 手里的法杖：优先找挂了 held_staff.gd 的节点；否则找名字像 staff 的 Node3D
##
## 参数：root = 搜索起点（调用方传的是玩家节点，法杖就在它子树里）。
## 返回值：法杖 Node3D；找不到返回 null（此时施法整体停摆，见 _ensure_jet 的前置判断）。
## 副作用：无（纯查询）。
## 时机：由 _find_nodes 调用，频率受 auto_find_interval 限制。
## 注意：
##   · 优先看脚本路径里有没有 "held_staff"（比名字可靠：模型节点常改中文名）；
##   · 名字兜底只认第一个命中的（fallback），因为角色身上可能还有 StaffTip 之类的子节点；
##   · 本函数**只定位**，不读也不写法杖的变换（握点/朝向由 held_staff.gd 自己维护）。
func _find_staff(root: Node) -> Node3D:
	var fallback: Node3D = null
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		# n.get_script() 在纯 Node/无脚本节点上是 null，必须先判空再取 resource_path，
		# 否则这里会直接报错（法杖子树里通常还有 Model/Marker 等无脚本节点）
		var s := String(n.get_script().resource_path) if n.get_script() != null else ""
		if s.contains("held_staff"):
			return n as Node3D
		if fallback == null and n is Node3D and String(n.name).to_lower().contains("staff"):
			fallback = n as Node3D
		for c in n.get_children():
			stack.append(c)
	return fallback


# ==================== 独立施法实例（每次施法一份，互不干扰） ====================
## ★ 本次施法产生的**独立实例**（各自演完自己的效果 ✓，互不影响 ✓）
##   用户确认：一次性技能"每次施法 = 一个新实例" ✓；**不加数量上限** ✓
var _cast_instances: Array = []


## 为**这一次施法**新建独立实例 ✓（初始化方式与共享 jet 一致 ✓）
##   生命周期：它自己的 `is_casting()` 变回 false（= 这一发演完）时，由 _sweep_instances() 释放 ✓
##
## 参数：无（读 selected / _player / _staff / jet）。
## 返回值：新建（或兜底复制）出来的 Node3D；彻底造不出来时返回 null
##   —— 调用方 _update_targeting 会在 null 时退回共享 jet（并 push_warning）。
## 副作用：往场景树加节点、调用其 setup(_player, _staff)、把它追加进 _cast_instances；
##   兜底分支里会 push_warning；**不**扣蓝（扣蓝在各法术自己的 cast_* / start_cast 里）。
## 时机：选点类法术"按下且已上膛"的那一瞬，一次施法调一次。
## 注意：只有**点击式（选点类）**法术才走这里；按住式法术（flame_jet / fire_tornado）直接用共享 jet。
func _spawn_cast_instance() -> Node3D:
	var source: Variant = SPELLS.get(selected, null)
	if source == null or _player == null or _staff == null:
		# ★ 兜底（用户要求）：脚本/参数取不到时，用**共享实例的副本** ✓（副本状态独立 ✓）
		#   —— 比"回退到共享实例"好得多 ✗（后者会让第二发被法术状态机忽略 ✗）
		if jet != null and is_instance_valid(jet):
			var d := jet.duplicate() as Node3D
			if d != null:
				d.name = "SpellCastCopy_" + selected
				# 副本会带上原实例的当前状态 ✗ → 尽力复位到"未施法"
				# （按约定：0 = ST_OFF ✓ / casting=false ✓ / 时钟清零 ✓）
				for prop in ["_state", "_state_t", "casting", "_wave_t"]:
					if prop in d:
						d.set(prop, 0)
				var parent: Node = _player.get_parent() if _player != null else jet.get_parent()
				if parent != null:
					parent.add_child(d)
				_cast_instances.append(d)
				push_warning("[SpellCaster] %s：走兜底 —— 用共享实例副本 ✓（已尽量复位状态 ✓）" % selected)
				return d
		return null
	# 每次施法都 new 一个：这样法术脚本内部的状态机（很多是"非 ST_OFF 就忽略新施法"）
	# 各自独立，第二发不会被第一发挡住
	var inst: Node3D = _spell_new(source)
	if inst == null:
		return null
	inst.name = "SpellCast_" + selected
	# 挂在玩家父节点下 = 玩家的**兄弟节点**：本节点是 autoload 不在场景树该位置，
	# 也避免实例继承玩家骨骼/模型变换（世界坐标由各视觉脚本自己算）
	_player.get_parent().add_child(inst)
	inst.call("setup", _player, _staff)
	# 沿用共享实例上已经算好的参数（advance_time / burn_time 等 ✓）
	if jet != null and is_instance_valid(jet):
		for prop in ["advance_time", "burn_time"]:
			if prop in jet and prop in inst:
				inst.set(prop, jet.get(prop))
	# 登记进清理表：这一发演完后由 _sweep_instances 回收（刻意不设数量上限）
	_cast_instances.append(inst)
	return inst


## 清理已经演完的实例 ✓（**不加数量上限** ✓ —— 用户明确要求 ✓）
##
## 参数：无（读 _cast_instances）。
## 返回值：无。
## 副作用：对演完的实例 queue_free()，并把 _cast_instances 收缩成剩下还活着的那些。
## 时机：_process 每帧第一件事（必须在别的判定之前，否则上一发的实例会多活一帧）。
## 注意：
##   · "演完"是由实例自己的 is_casting() 决定的 —— 没有该方法的实例会被当作演完而立刻回收；
##   · 已经在演的实例**绝不打断**（连发多个实例同时存在是预期行为）；
##   · 已被别处 free 掉的引用（is_instance_valid 为 false）直接跳过，顺手从表里剔除。
func _sweep_instances() -> void:
	if _cast_instances.is_empty():
		return
	var left: Array = []
	for x in _cast_instances:
		var n := x as Node3D
		if n == null or not is_instance_valid(n):
			continue
		# ★ 优先用 is_effect_alive()：它把"碎裂 / 淡出"这类收尾阶段也算作还活着。
		#   只认 is_casting() 的话，金色守护一进入碎裂（casting=false）就会被回收，
		#   碎裂动画与薄膜消失直接丢掉。
		var busy := false
		if n.has_method("is_effect_alive"):
			busy = bool(n.call("is_effect_alive"))
		elif n.has_method("is_casting"):
			busy = bool(n.call("is_casting"))
		if busy:
			left.append(n)          # 还在演 → 留着 ✓（绝不打断前一次施法 ✓）
		else:
			n.queue_free()          # 演完了 → 释放 ✓
	# 只有真的清掉了东西才重建数组：省掉每帧一次无意义的数组分配（实例存活期间数组不变）
	if left.size() != _cast_instances.size():
		_cast_instances = left


# ==================== 共享视觉节点的创建 / 切换 ====================
## 保证 jet 与 selected 一致：不一致就停掉旧视觉、建一个新的。
##
## 参数：无（读成员 selected / _player / _staff / jet / _jet_spell）。
## 返回值：无。
## 副作用：旧视觉若还在生效（is_effect_alive）则转交给 _cast_instances 继续演完，
##   否则调 stop_cast 并 queue_free；再 new 出新视觉挂到 **玩家父节点**下，
##   并调用它的 setup(_player, _staff)；更新 jet / _jet_spell。
## 时机：_process 每帧调用一次（位置在施法判定之前，保证这一帧用的就是新视觉）。
## 注意：
##   · selected 为空时**直接返回**，所以"施放后清空选中"不会拆掉共享视觉，
##     它也正因此被 _update_targeting 当作"残留 jet"用来查选点配置；
##   · 幂等：已经是同一个术法的视觉时不做任何事（避免每帧重建导致特效闪烁）；
##   · 未注册的 id 只 push_warning 后返回，不会崩（圆盘数据与 SPELLS 表不同步时的保护）。
func _ensure_jet() -> void:
	if selected.is_empty() or _player == null or _staff == null:
		return
	# 已经是这个术法的视觉：什么都不用做
	if jet != null and is_instance_valid(jet) and _jet_spell == selected:
		return
	var source: Variant = SPELLS.get(selected, null)
	if source == null:
		# 圆盘给的 id 不在 SPELLS 表里：只警告不崩，保持旧视觉不动（便于热改法术表）
		push_warning("[SpellCaster] 未注册的术法: " + selected)
		return
	# ★ 换术法：旧视觉**还在生效**时不能直接释放。
	#   金色守护 / 流水治疗这类一次性的长时法术，真正演出的是共享 jet 自身；
	#   直接 queue_free 会触发它的 _exit_tree（摘膜 / 清 `gold_guard` 标记）= 施放别的法术就把效果取消。
	#   所以对声明了 is_effect_alive() 且仍为 true 的实例，转交给 _cast_instances：
	#   它继续按自己的状态机演完，演完后由 _sweep_instances() 释放。
	#   隐身没有 is_effect_alive（效果宿主挂在角色下，与 jet 无关）→ 照旧释放，不影响 60s 计时。
	if jet != null and is_instance_valid(jet):
		var still := jet.has_method("is_effect_alive") and bool(jet.call("is_effect_alive"))
		if still:
			_cast_instances.append(jet)
		else:
			jet.call("stop_cast")
			jet.queue_free()
		jet = null
	var j: Node3D = _spell_new(source)
	if j == null:
		push_warning("[SpellCaster] 术法来源无法实例化: " + selected)
		return
	j.name = "Spell_" + selected
	# 与独立实例同理：挂在玩家父节点（兄弟节点）下，不继承玩家骨骼/模型变换
	_player.get_parent().add_child(j)
	j.call("setup", _player, _staff)
	jet = j
	# 单独记一份"这个视觉属于哪个术法"：selected 随时可能被清空，不能拿它当依据
	_jet_spell = selected


# ==================== 施法动作桥接（-> player.gd） ====================
## 施法动作：驱动玩家角色的施法动画（player.gd::start_spell_cast / stop_spell_cast）。
##
## start 每帧都调 —— player 侧是**幂等**的（只在当前剪辑不是施法动画时才 play），
## 所以这里不必自己判断"是否已开始"；好处是起跳、被别的动作顶掉之后，
## 下一帧就能自动把施法姿势找回来。
## stop 只在"由开到关"那一次调，避免多余的动画切换。
##
## 用 has_method 而不是直接调 player.start_spell_cast()：player 是**运行时按 group
## 找到的**，可能被换成别的角色脚本（见 _find_player 的兜底搜索），
## 硬调会在换角色时直接报错。
func _update_cast_anim(casting: bool) -> void:
	var p := _player
	var ok := p != null and is_instance_valid(p)
	if casting:
		# 先记下"动作已开"，再调 player：本函数每帧都会被调，这个标志决定后面要不要发 stop
		_cast_anim_on = true
		if ok and p.has_method("start_spell_cast"):
			p.call("start_spell_cast")
		return
	# 本来就关着：直接返回（stop 只在"由开到关"那一次发，避免多余的动画切换）
	if not _cast_anim_on:
		return
	_cast_anim_on = false
	if ok and p.has_method("stop_spell_cast"):
		p.call("stop_spell_cast")


# ==================== 通用选点（圆盘 / 扇形，一次性施法） ====================
## 通用选点：返回 true 表示这一帧由选点器接管（不走"按住施法"）
##
## 参数：down = 本帧施法键是否按住（来自 _cast_held）；
##   just_pressed = 本帧是否"刚按下"（down and not 上一帧 down）。
## 返回值：true = 这一帧已被选点流程接管（调用方 _process 必须立即 return）；
##   false = 当前术法不需要选点 / 没选中法术 -> 调用方继续走"按住施法"。
## 副作用：创建并驱动选点器（begin / configure / end）、可能创建**独立施法实例**、
##   调用 _update_cast_anim（保持施法姿势）、施放完把 selected 清空、
##   并在两处诊断分支里 print（"按下被挡"）。
## 时机：_process 里"按住施法"判定之前，每帧一次。
## 注意：本函数里的顺序不能乱 —— 先判"这个术法要不要选点"、再保证配置下发、
##   最后才在 just_pressed 时真正施放；_cast_armed 必须参与判断（见下面的长注释）。
func _update_targeting(down: bool, just_pressed: bool) -> bool:
	# 用 has_method 探测"这个术法要不要选点"：选点接口是**可选**的，
	# 按住式法术（flame_jet 等）压根没有这些方法，硬调会报错
	var has_t := jet != null and is_instance_valid(jet) \
			and jet.has_method("has_targeting") and bool(jet.call("has_targeting"))
	if selected.is_empty():
		has_t = false          # ★ 施放后已清空选中 ✓ → 不进入选点模式 ✓（否则会靠残留 jet 再放 ✗）
	if not has_t:
		if _targeting != null and _targeting.is_active():
			_targeting.end()
		return false
	if _targeting == null:
		# 选点器挂 root 而不是挂玩家：它内部按世界坐标做射线/圆形采样，
		# 挂玩家下面会继承角色缩放与旋转（角色缩放不是 1，见法杖技术文档 §2.1）
		_targeting = Targeting.new()
		_targeting.name = "SpellTargeting"
		get_tree().root.add_child(_targeting)
		# camera 传 null：让选点器自己去取当前相机（本项目相机会随场景替换）
		_targeting.call("setup", _player, null)
		# 置空签名 -> 下面一定会 configure 一次，避免新选点器用默认配置（圆盘）跑扇形法术
		_targeting_cfg_sig = ""
	# ★ 每次切换法术都要**重新下发选点配置**：原来只在创建选点器时配置一次，
	#   于是从"火焰灼烧"(圆盘) 切到"火焰推进"(扇形) 时选点器还留着圆盘配置
	#   -> sector=false -> 圆心跟鼠标、半径按圆盘算 -> 扇形退化成鼠标处的圆盘火
	#   （用户实测反馈"最终效果不是扇形"）。
	if jet.has_method("targeting_config"):
		var cfg: Dictionary = jet.call("targeting_config")
		# 用 str(字典) 当签名：只读、开销可忽略，且**任意字段变了签名就变**；
		# 比直接比较两个 Dictionary 更稳（字典/嵌套数组的比较语义跨版本有差异）（推测）
		var sig := str(cfg)
		if sig != _targeting_cfg_sig:
			_targeting_cfg_sig = sig
			_targeting.call("configure", cfg)
	# 刚放完法术：等鼠标抬起 **且法术演完** 再允许重新显示圆圈，
	# 否则圆圈会立刻又冒出来（用户："施放技能后圈圈应该消失"）
	if _target_wait_release:
		# ★ 注意：下面这个 anim_running **算出来之后并没有被使用** —— 同一表达式在
		#   _update_cast_anim(...) 那一行又算了一遍。疑似历史遗留（推测）；
		#   按"只新增注释、不改代码"的约定原样保留，删之前请先确认没有其它引用。
		# ★ 玩法优化：一次性技能**只等"施法动作"演完**即可再施法 ✓（原来等 is_casting ✗ = 等整段效果 ✗ → 无法连发 ✓）
		var anim_running := jet.has_method("wants_cast_anim") and bool(jet.call("wants_cast_anim"))
		# ★ 修复"施放完圆圈不回来、必须重开轮盘" ✗：
		#   原来这里还要等 `wants_cast_anim()` 归零 ✗ —— 但该标志现在查的是**共享实例**
		#   （真正施法的是独立实例 ✓），一旦它不归零，就永远不恢复选点 ✓
		#   → 现在**鼠标一抬起就恢复** ✓（松开左键即可再次选点/连发 ✓）
		if not down:
			_target_wait_release = false
		# 保持施法姿势：动作还没演完（wants_cast_anim 仍为 true）就别收势，
		# 否则一次性法术的动作会在生效中途被 stop_spell_cast 切掉
		_update_cast_anim(jet.has_method("wants_cast_anim")
				and bool(jet.call("wants_cast_anim")))
		return true
	# 每帧检查而不是只 begin 一次：end()（施放完 / 切走法术）之后，下一帧还能自动把圆圈捡回来
	if not _targeting.is_active():
		_targeting.call("begin")
	# 选点期间保持施法姿势
	_update_cast_anim(true)
	# ★ 必须带 _cast_armed：它表示"按下那一瞬没落在 UI 上"。
	#   漏了它的话，**点圆盘选法术的那一下点击**会被当成在世界区按下 -> 圈还没落下
	#   法术就自动放了（用户实测症状）。
	if just_pressed and not _cast_armed:
		print("[SpellCaster] 按下被挡 ✗ _cast_armed=false（上膛尚未完成：需要先**松开一次左键** ✓）")
	if just_pressed and _cast_armed and _ui_blocks_cast():
		print("[SpellCaster] 按下被挡 ✗ 被 UI 挡住（轮盘还开着 / 鼠标压在 UI 上 ✓）｜selected=%s" % selected)
	if just_pressed and _cast_armed and not _ui_blocks_cast():
		# 圆心/半径在"按下那一瞬"取一次快照就固定下来，随后 end() 收起圆圈，
		# 法术按这份快照自己演（不跟随鼠标继续变）
		var c: Vector3 = _targeting.call("center")
		var r: float = _targeting.call("radius")
		# ★ 扇形法术（火焰推进）还要"中轴 + 半角"，用 cast_sector 分派；
		#   没有它的法术仍走 cast_at（向后兼容）。
		if jet.has_method("cast_sector"):
			var ax := 0.0
			var ha := 0.0
			if _targeting.has_method("axis"):
				ax = float(_targeting.call("axis"))
			if _targeting.has_method("half_angle"):
				ha = float(_targeting.call("half_angle"))
			# ★ 状态隔离（用户要求）：这一次施法用**独立实例** ✓（造不出就退回共享实例 ✓）
			var inst := _spawn_cast_instance()
			(inst if inst != null else jet).call("cast_sector", c, r, ax, ha)
		elif jet.has_method("cast_at"):
			# ★ 同上：独立实例 ✓
			var inst := _spawn_cast_instance()
			# ★ 诊断：独立实例没造出来时会回退共享实例 ✗
			#   → 火焰灼烧的 cast_at 会被 `_state != ST_OFF` 静默忽略 ✗（第二发不生效 ✓）
			if inst == null:
				push_warning("[SpellCaster] %s：独立实例创建失败 ✗ 回退共享实例（第二发会被法术的状态机忽略 ✗）" % selected)
			else:
				print("[SpellCaster] %s：新独立实例已创建 ✓ %s" % [selected, inst.name])
			(inst if inst != null else jet).call("cast_at", c, r)
		_targeting.call("end")
		# ★ 主动技（用户确认的玩法）：**施放一次后立即清空选中** ✓
		#   → 圈圈消失 ✓、该技能不再"待发" ✓、必须重新打开轮盘选择才能再放 ✓
		#   （"松开左键即解锁"的优化保留 ✓ → 重新选中后可以**立刻**再放 ✓，
		#     不会被上一个法术的效果时长卡住 ✓；每次施法仍是独立实例 ✓ 互不影响 ✓）
		select_spell("")
		_target_wait_release = true
	return true


## 圆盘信号回调：用户点选了某个术法。
##
## 参数：id = SPELLS 的键（圆盘里显示的术法 id，可能为空字符串 = 取消选择）。
## 返回值：无。
## 副作用：转调 select_spell(id)（会改 selected 并锁掉施法"上膛"），并打印一行日志。
## 时机：由 spell_wheel.gd 的 spell_chosen 信号触发（_ready 里连接）。
## 注意：这里**不**立即施法 —— 用户必须先松开左键，_process 才会重新上膛（见 _cast_armed）。
func _on_spell_chosen(id: String) -> void:
	select_spell(id)
	print("[SpellCaster] 选中术法：", id, "（松开左键后，再按住左键施法）")


# ==================== 对外接口 ====================
# ---------------------------------------------------------------- 对外
## 选中术法（唯一的外部入口；圆盘回调与内部"施放后清空"都走这里）。
##
## 参数：id = SPELLS 的键；传 "" 表示清空选中（不施法、不进选点）。
##   取值必须是 SPELLS 里注册过的 id，否则 _ensure_jet 只会 push_warning、不会有视觉。
## 返回值：无。
## 副作用：写 selected；把 _cast_armed 置 false（锁掉这一轮施法）。
## 时机：圆盘点选、或 _update_targeting 施放完主动清空。
## 注意：**任何选中都会先上锁**（包括传 ""），必须等左键真正抬起后
##   _process 才会重新上膛；这正是"点圆盘选法术的那一下不会顺带施法"的关键。
func select_spell(id: String) -> void:
	selected = id
	# 选中的这一下不算施法：先上锁，等左键抬起后由 _process 解锁（见 _cast_armed）
	_cast_armed = false

## 清空选中，并让当前共享视觉停止演出。
##
## 参数：无。
## 返回值：无。
## 副作用：selected = ""；若 jet 有效则调它的 stop_cast()。
## 时机：外部需要"收起法术"时调用（本文件内部施放完用的是 select_spell("")，不调这里）。
## 注意：**不释放** jet（保留共享视觉供下次选中复用）、也**不动** _cast_anim_on ——
##   施法姿势会在下一帧 _process 里因 casting 变 false 而自动收掉。
func stop_spell() -> void:
	selected = ""
	if jet != null and is_instance_valid(jet):
		jet.call("stop_cast")
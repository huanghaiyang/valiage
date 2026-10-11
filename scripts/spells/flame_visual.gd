extends Node3D
## 火焰喷射 —— 纯 VisualShader 实现（本项目特效统一用节点着色器制作）。
##
## 载体：4 片"圆柱公告板"四边形（法线转向相机、只错开 ±23 度），沿喷射方向铺开。
##   为什么这么做：固定角度的交叉片从俯视看会变成星形/花瓣；公告板才会叠成一束。
## 着色器：assets/shaders/flame_jet_visual.tres —— VisualShader 节点图，编辑器里可直接改。
##   节点图里是一个 Expression 节点（output0 -> Albedo / output1 -> Alpha / output2 -> Emission）。
##
## 瞄准方向 / 喷射起点不再自己实现，改用与粒子版共用的 spell_aim.gd —— 两个实现的弹道
## 行为因此永远一致（不想再出现"同一段代码抄两份、只修一处"的事故）。
##
## 对外接口（spell_caster 调用，与 flame_jet_particles.gd 完全一致）：
##   setup(player, staff) / start_cast() / stop_cast() / is_casting()
##   / aim_dir() / origin_global() / ran_out_of_mana()
##
## ---- 所属系统与当前状态 ------------------------------------------------------
## 所属系统：法术视觉层。自动加载 SpellCaster 按 SPELLS 注册表 new() 出本节点、
##   add_child 到**玩家父节点**下，再依次调 setup / start_cast / stop_cast / is_casting。
## 当前状态：spell_caster.gd 里 SPELLS["flame_jet"] 默认指向**粒子版**
##   （flame_jet_particles.gd），本文件是同一术法的着色器版实现；想启用它，只需把注册表
##   那一行的值换成 preload("res://scripts/spells/flame_visual.gd")，其余代码无需改动
##   —— 两个实现的对外接口是刻意逐一对齐的。
##
## ---- 关键依赖 ---------------------------------------------------------------
## · Mana（自动加载，res://scripts/spells/mana.gd）：每帧用 spend_rate() 扣蓝；
##   蓝不够时由它自己把 current 夹到 0 并发 emptied 信号（本文件不直接读写 current）。
## · res://assets/shaders/flame_jet_visual.tres：外观的**唯一**来源（VisualShader 节点图，
##   图里一个 Expression 节点输出 Albedo / Alpha / Emission）。载入失败只警告，
##   本脚本不做任何替代绘制 —— 表现就是"火不见了"。
## · scripts/spells/spell_aim.gd：瞄准方向 + 喷射起点，与粒子版共用同一份实现。
## · spell_caster.gd / spell_wheel.gd：调用方（选术法、按住左键持续施放）。
##
## ---- 已知的坑与注意事项 -----------------------------------------------------
## 1. 几何与材质只在 _ready() 里建一次：jet_length / jet_width / blade_count /
##    SHADER_PATH 属于"出生参数"，运行中修改只影响**之后新建**的实例。
## 2. blade_count 片刀片共用**同一个 ShaderMaterial 实例**（见 _ready）：视觉完全一致，
##    想单片调参必须先在 _ready 里给每片各建一份材质。
## 3. casting 与 _root.visible 是两件事：蓝耗尽时 casting 仍为 true（刻意的，见 _process），
##    只是把 _root 藏起来。spell_caster 刻意不看蓝量来驱动施法动画，所以这里若把 casting
##    置 false，按住不放时施法动作会在回蓝阈值上反复闪。
## 4. 本节点挂在玩家父节点下（世界空间的兄弟节点），位置每帧被 origin_global() 覆写，
##    因此它的 local_position / 编辑器里摆的位置不参与任何运算。
## 5. _orient_blades() 依赖"_root 只当喷射局部空间的平移容器、旋转由本节点 look_at 承担"
##    这一前提（它用 _root.global_transform.basis 的逆做世界->局部换算）；
##    不要给 _root 加旋转或缩放。
## 6. 取不到相机（刚 new() 还没进树、或场景里没有 Camera3D）时 _orient_blades 会退到
##    世界 UP 方向：只是刀片朝向不"正对镜头"，不报错、不崩。

# ==================== 常量：资源路径与共用模块 ====================
const SHADER_PATH := "res://assets/shaders/flame_jet_visual.tres"
## 瞄准方向 + 喷射起点：与粒子版共用同一份实现。
## 想改成"从法杖顶端喷"，改 spell_aim.gd 里的 origin_at_staff（两个实现同时生效）。
## 类型是 RefCounted 脚本，用 .new() 按实例创建 —— 每个火焰节点持有自己独立的一份 _aim。
const SpellAim := preload("res://scripts/spells/spell_aim.gd")

# ==================== 可调参数（@export） ====================
## 每秒耗蓝（点/秒），默认 22.0。
## 默认值刻意与 mana.gd 的 spend_per_sec 默认值、以及粒子版的 mana_per_sec 对齐，
## 这样"换成粒子版/着色器版"时手感和续航完全不变。
## 注意：本值不是让 mana.gd 用它的默认值，而是**显式**传给 Mana.spend_rate(delta, mana_per_sec)。
## 调大：喷得更贵，满蓝（max_mana = 100）能连喷的时间更短（100 / 22 ≈ 4.5 秒）；
## 调小则更持久。
@export var mana_per_sec := 22.0
## 火柱长度（米），默认 3.2。
## 3.2 约为主角默认身高（character_profile 默认 1.5 米；矮个角色可低到 1.08）的两倍 ——
## 站定喷射时火能明显盖住身前一整段距离，又不至于夸张。
## 作用点：QuadMesh 的 size.y（FACE_Y 下对应本地 Z 长度轴），以及刀片的推出位移
## -jet_length / 2。调大 = 火更远更长（太长会穿到墙/遮挡物里，视觉上穿帮）；
## 调小 = 更短更紧凑。
## 只在 _ready() 建网格时生效，运行中改不会重建当前实例（见文件头注意事项 1）。
@export var jet_length := 3.2          ## 火柱长度（米）
## 火柱宽度（米），默认 1.10。
## 1.10 与主角肩宽同量级，所以贴脸喷射时看起来是"一束火"而不是"一根线"。
## 作用点：QuadMesh 的 size.x（本地 X 宽度轴）。调大 = 更粗、更像喷火器，
## 但多片交叠区域也会更宽，容易显得糊；调小 = 纤细，但交叉片之间的缝隙更明显。
## 同样只在 _ready() 时生效。
@export var jet_width := 1.10          ## 火柱宽度（米）
## 构成火柱的"圆柱公告板"片数，默认 4。
## 4 片是视觉与开销的折中：少了撑不出体积；再多了也不会更丰富（材质共用），
## 只是覆盖率更高，而且 _orient_blades 每帧的循环开销随它线性增长。
## 取值 <= 0 时 _ready 用 maxi(1, ...) 兜底成 1 片。
## 同样只在 _ready() 时生效。
@export var blade_count := 4           ## 交叉片数（圆柱公告板）

# ==================== 运行时状态 ====================
## 是否"被要求持续施法"（spell_caster 按住左键、且选中本术法时为 true）。
## 注意：true ≠ 这一帧真的有火 —— 蓝不够时 _root 会被隐藏，但这里仍是 true（见 _process）。
var casting := false
## 本实例私有的瞄准/起点计算器（spell_aim.gd，RefCounted）。
## 每个火焰节点各持一份，_last_dir 之类的内部缓存互不干扰。
var _aim := SpellAim.new()
## 承载所有刀片的容器节点。_ready 里着色器载入失败时保持 null；
## 其余函数一律先判 _root != null —— 于是"载入失败"表现为静默地没有火，而不是报错。
var _root: Node3D = null
## 已建好的刀片，数量 = maxi(1, blade_count)。
## 元素类型写死成 MeshInstance3D，_orient_blades 里就能直接写 basis，不必再做类型转换。
var _blades: Array[MeshInstance3D] = []
## 最近一帧扣蓝是否失败（= 火被隐藏）。只在 _process 里更新，对外由 ran_out_of_mana() 读。
var _ran_out := false


# ==================== 生命周期：构建刀片与共享材质 ====================
## 构建火焰本体：载入着色器 -> 建一个隐藏容器 _root -> 把 blade_count 片四边形挂进去。
##
## 调用时机：节点进入场景树时自动调用一次（spell_caster 用 script.new() + add_child
##   创建本节点，随即触发）。
## 参数：无（几何参数取自本文件的 @export）。
## 返回值：无。
## 副作用：写 _root / _blades；向场景树添加 _root 及若干 MeshInstance3D 子节点。
## 注意事项：
##   · 着色器载入失败会**直接 return**：_root 保持 null，之后 start_cast / stop_cast /
##     _process 全部变成空操作（不崩，但也不会喷火）。
##   · blade_count <= 0 时用 maxi(1, ...) 兜底成 1 片，避免 _orient_blades 按 0 片计算。
##   · 只在这里建几何，见文件头注意事项 1。
func _ready() -> void:
	# 显式声明开启逐帧处理；GDScript 定义了 _process 时代码通常已自动开启，这里写明意图。（推测）
	set_process(true)
	# load() 走 ResourceLoader 缓存：多个火焰实例共用同一份 Shader 资源（只读，安全）。
	var sh: Shader = load(SHADER_PATH)
	# 载入失败不抛异常：警告后停在这里，其余函数靠 _root == null 的空判兜底。
	if sh == null:
		push_warning("[FlameJet] 着色器载入失败: " + SHADER_PATH)
		return
	# 材质只建一份、所有刀片共用（见文件头注意事项 2）：外观一致，代价是没法单片调参。
	var mat := ShaderMaterial.new()
	mat.shader = sh
	# _root 只当"喷射局部空间"的平移容器：旋转由本节点的 look_at 承担，
	# _orient_blades 再用它的逆变换把刀片摆回来。
	_root = Node3D.new()
	# 出生即隐藏：显示与否完全交给 start_cast 与 _process 的蓝量判定。
	_root.visible = false
	add_child(_root)
	# maxi(1, ...) 兜底：blade_count 被设成 0 或负数时也至少留 1 片，避免除以 0 片。
	for i in range(maxi(1, blade_count)):
		var q := QuadMesh.new()
		# FACE_Y：平面躺在 XZ（本地 X=宽度、本地 Y=法线、本地 Z=长度）
		q.orientation = PlaneMesh.FACE_Y
		# FACE_Y 下 size.x 沿本地 X（宽度轴）、size.y 沿本地 Z（长度轴）：
		# 所以宽度传 jet_width、长度传 jet_length —— 顺序写反会变成一面又扁又宽的墙。
		q.size = Vector2(jet_width, jet_length)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		# 用 material_override 而非 mesh.material：不受 QuadMesh 自带 surface 材质影响，
		# 也正好共用上面那份 ShaderMaterial（见文件头注意事项 2）。
		mi.material_override = mat
		# 沿本地 -Z 推出半个长度（本地 -Z 稍后会被 look_at 对齐到喷射方向）：
		# 这样四边形只占本地 -Z 半轴，喷口严格落在本节点原点 = origin_global()，
		# 火不会"从身后/脚下冒出来"。
		mi.position = Vector3(0.0, 0.0, -jet_length * 0.5)
		# 火焰是自发光特效：投影既不符合物理也白花性能，直接关掉。
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_root.add_child(mi)
		_blades.append(mi)


# ==================== 装配：绑定玩家与法杖 ====================
## 绑定施法者与法杖，把"瞄准方向 / 喷射起点"整个交给共用的 spell_aim.gd。
##
## 调用时机：spell_caster 创建本节点后立即调用一次；切换术法重建节点时会再调一次。
## 参数：
##   player -- 玩家根节点（Node3D）。spell_aim 用它的 get_facing_yaw() / velocity /
##             global_position 推导方向与起点；允许为 null（spell_aim 内部判有效性）。
##   staff  -- 手持法杖节点（Node3D）。仅在 spell_aim.origin_at_staff 为 true 时用于取杖尖；
##             当前默认为 false，所以传什么都一样（仍建议如实传入，便于以后切换）。
## 返回值：无。
## 副作用：写 _aim.player / _aim.staff / _aim._host（_host = self）。
## 注意：这里不缓存强引用、也不做存活性快照 —— 节点被释放后由 spell_aim 的
##   is_instance_valid 兜底，避免留下悬空引用。
func setup(player: Node3D, staff: Node3D) -> void:
	_aim.setup(player, staff, self)


# ==================== 对外接口（spell_caster 调用） ====================
# ---------------------------------------------------------------- 对外
## 开始喷射：置 casting = true 并显示火焰。
##
## 调用时机：spell_caster._process 每帧在"按住左键 + 选中本术法"时调用；重复调用幂等。
## 参数：无。
## 返回值：无。
## 副作用：casting = true；_root.visible = true（_root 为 null 时跳过）。
## 注意：
##   · 只改标志与可见性，**不**在这里摆位置：位置要等本帧稍后的 _process 才写入
##     （与粒子版不同 —— 粒子版会先摆一次位再开喷）。
##   · 蓝不够时本函数照样把 _root 显示出来，同一帧 _process 又会隐藏它；结果只是一帧内
##     的来回，肉眼不可见（推测：取决于两个节点的处理顺序，但不影响观感）。
func start_cast() -> void:
	casting = true
	if _root != null:
		_root.visible = true


## 停止喷射：置 casting = false 并隐藏火焰；几何与材质全部保留，下次施法直接复用。
##
## 调用时机：spell_caster 在"松开左键 / 切换术法 / 关闭控制器"时调用；重复调用幂等。
## 参数：无。
## 返回值：无。
## 副作用：casting = false；_root.visible = false。
## 注意：
##   · 不清 _ran_out、也不复位位置：下一帧 _process（或下次 start_cast）会重新摆位。
##   · spell_caster 换术法时是"先 stop_cast() 再 queue_free()"，所以这里不需要释放资源。
func stop_cast() -> void:
	casting = false
	if _root != null:
		_root.visible = false


## 是否处于"施法中"= 是否被要求持续喷射（**不代表这一帧真的有火**）。
##
## 调用时机：spell_caster._sweep_instances() 靠它判断一次性法术的独立实例"演完没有"
##   （返回 false 的实例会被 queue_free()）。
## 参数：无。
## 返回值：bool，即 casting 的值。
## 副作用：无（纯读取）。
## 注意：蓝耗尽时仍返回 true（刻意与粒子版一致），因为它是"这个实例还在演吗"的唯一判据：
##   spell_caster._sweep_instances() 会 queue_free 掉返回 false 的独立实例。
##   本术法没有声明 has_targeting()，所以目前不会产生这类独立实例（推测其用途），
##   但接口语义必须保持正确 —— 否则一旦它被当作实例使用，效果会在回蓝瞬间被回收重建。
func is_casting() -> bool:
	return casting


## 最近一次扣蓝是否失败（= 施法中蓝不够、火被隐藏）。
##
## 调用时机：本项目内目前**没有调用者**（spell_caster 只看 is_casting 与若干 has_method
##   钩子，本版没有声明 wants_cast_anim 等钩子，所以那些分支会自动跳过）。
##   它是留给 HUD / 音效 / 状态机查询的只读接口（推测其用途）。
## 参数：无。
## 返回值：bool，true = 最近一帧扣蓝失败。未施法期间该值停留在上一次施法的结果 ——
##   它不是"当前蓝量"的实时读数。
## 副作用：无。
func ran_out_of_mana() -> bool:
	return _ran_out


## 喷射方向（水平、世界空间）—— 实现在 spell_aim.gd，与粒子版共用
## 参数：无。
## 返回值：归一化的**水平**单位向量（y 恒为 0）。spell_aim 内部有四级来源与兜底
##   （移动方向 -> 角色朝向 -> 相机水平前向 -> 上一次方向），所以永不返回零向量。
## 副作用：会推进 spell_aim 内部的 _last_dir 缓存（所以它并非纯函数，但同一帧内幂等）。
## 注意：不接 delta，方向本身不做平滑；平滑由 spell_aim 的来源选择间接体现。
func aim_dir() -> Vector3:
	return _aim.aim_dir()


## 喷射起点（世界坐标）—— 实现在 spell_aim.gd，与粒子版共用
## 参数：无。
## 返回值：世界坐标 Vector3。spell_aim.origin_at_staff 为 false（当前默认）时等于
##   "角色位置 + UP*1.05 + 朝向*0.6"，即角色身前胸口高度；为 true 时取法杖杖尖全局坐标。
##   角色/法杖都失效时退回宿主（本节点）自身坐标或 Vector3.ZERO。
## 副作用：内部会调用 aim_dir()，因此可能推进方向缓存。
## 注意：起点含"朝向 * 0.6"的前置偏移，转身时**喷口会跟着转**（不是绕角色画圆）；
##   每帧调用即可平滑跟随，无需自己做插值。
func origin_global() -> Vector3:
	return _aim.origin_global()


# ==================== 每帧更新：摆位、转向、扣蓝 ====================
# ---------------------------------------------------------------- 每帧
## 每帧主循环：取方向 -> 摆位置 -> 转向 -> 摆刀片 -> 扣蓝 -> 按蓝量开关可见性。
##
## 调用时机：Node3D 的 _process，每渲染帧一次。
## 参数：delta -- 距上一帧的秒数（float，> 0；引擎传入，本函数不做上限截断）。
## 返回值：无。
## 副作用：写本节点的 global_position（覆写位置）与旋转（look_at）、写每片刀片的 basis、
##   写 _ran_out、写 _root.visible，并通过 Mana.spend_rate() 扣蓝。
## 注意：
##   · casting == false 或 _ready 建节点失败（_root == null）时**立即返回**：
##     不施法期间本节点零开销、也不会移动。
##   · 语句顺序不能调换：先写 global_position 再 look_at，否则朝向是按上一帧位置算的。
##   · Mana.spend_rate() 返回 false 时，mana.gd 已把 current 夹到 0 并发 emptied 信号。
##   · ★ 实用坑：按住不放时本函数每帧都会重试扣蓝，而 mana.gd::try_spend 在不够时把
##     current 直接归零；每帧恢复量（6 * delta）远小于每帧消耗（22 * delta），
##     所以**蓝耗光后按住不放不会自己回蓝**，必须松开按键、过了 regen_delay(1.2s)
##     才会回。（推测：这是 mana.gd 侧 try_spend 的行为后果，本文件无法改变。）
func _process(delta: float) -> void:
	if not casting or _root == null:
		return
	# 每帧重取方向：施法中边转身边喷时，方向来自移动方向 / 角色朝向（spell_aim 决定）。
	var d := aim_dir()
	# 先摆位、再转向：look_at 的方向参考点就用刚写好的全局位置（顺序不能反）。
	global_position = origin_global()
	var up := Vector3.UP
	# look_at 的 up 与朝向平行时基会退化（抖动 / NaN），所以在"几乎朝正上/正下"时换一根 up。
	# 阈值 0.999 约等于夹角 2.6°。推测：spell_aim 目前恒返回水平方向（y=0），
	# 这条分支实际几乎走不到，属于防御性写法。
	if absf(d.dot(up)) > 0.999:
		up = Vector3.FORWARD
	# look_at 让**本地 -Z**指向 d；刀片几何正好铺在本地 -Z 半轴，两者天然对齐。
	look_at(global_position + d, up)
	_orient_blades()
	# Mana 是自动加载单例（res://scripts/spells/mana.gd）：够蓝就扣掉 mana_per_sec * delta
	# 并返回 true；不够则返回 false（它自己把 current 归零并发 emptied）。
	if Mana.spend_rate(delta, mana_per_sec):
		# 这一帧扣蓝成功 -> 有火（顺便清掉"没蓝"标记）。
		_ran_out = false
		_root.visible = true
	# 蓝不够：只藏火柱，**不动 casting** —— spell_caster 刻意不看蓝量来驱动施法动画，
	# 保持 casting = true 才能让角色维持施法姿势（见文件头注意事项 3）。
	else:
		_ran_out = true
		_root.visible = false


# ==================== 圆柱公告板朝向算法 ====================
## 圆柱公告板：在 _root 的局部空间里摆每片（局部 -Z 就是喷射方向）
##
## 作用：让 blade_count 片四边形各自绕**喷射轴**转一个角度，同时它们的法线尽量朝向相机，
##   于是从任何角度看上去都像"一束有厚度的火"（而不是几片薄纸或一朵花）。
## 调用时机：_process 里每次 look_at 之后调用（本节点转向变了，刀片必须重摆）。
##   也可以理解为"每帧一次"，未施法时不会被调用。
## 参数：无（用 _blades / _root / 当前相机）。
## 返回值：无。
## 副作用：写每个 _blades[i].basis（**在 _root 的局部空间**里的旋转 + 正交轴）。
## 注意事项：
##   · 必须在本节点 look_at 之后调用：这里用 _root.global_transform.basis 的逆把
##     "朝相机"从世界空间搬进局部空间，前提是 _root 只做平移容器（见文件头注意事项 5）。
##   · _blades 为空时 maxi(1, ...) 兜底，避免浮点除法除以 0；循环体自然不会执行。
##   · 相机取不到时不报错，只是刀片朝向退化成"由世界 UP 推出"的固定方向。
##   · 开销：每次 blade_count 次归一化/叉乘，量级极小（4 片），无需缓存。
func _orient_blades() -> void:
	# 本地 -Z 就是喷射方向（look_at 的约定），所以喷射轴是个常量，不必再算一遍。
	var ax := Vector3(0.0, 0.0, -1.0)
	# 取不到相机时的兜底"朝相机"方向：世界 UP。它保证下面永远不会拿到零向量。
	var to_cam_w := Vector3.UP
	# is_inside_tree() 的判空是必需的：不在树里时 get_viewport() 会报错
	# （例如刚 script.new()、还没 add_child 的瞬间）。
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null and is_instance_valid(cam):
		to_cam_w = cam.global_position - global_position
	# 世界 -> _root 局部：本节点已被 look_at 旋转，而刀片的 basis 是局部量，
	# 所以必须用逆变换把"朝相机"搬进局部空间，否则转身时刀片会跟着歪。
	var inv := _root.global_transform.basis.inverse()
	var to_cam := inv * to_cam_w
	# Gram-Schmidt 正交化：把"朝相机"投影到**垂直于喷射轴**的平面上，
	# 得到刀片法线的候选方向（刀片必须绕轴张开，法线不能带轴向分量）。
	var perp := to_cam - ax * to_cam.dot(ax)
	# 相机正好在喷射轴上（顺着火柱看过去）时投影退化成零向量：改用 UP 再造一个垂直方向。
	if perp.length_squared() < 0.0001:
		perp = Vector3.UP - ax * Vector3.UP.dot(ax)
	# 连 UP 都与轴平行（正上/正下喷）时才退到世界 RIGHT；只要非零即可，下面会归一化。
	if perp.length_squared() < 0.0001:
		perp = Vector3.RIGHT
	perp = perp.normalized()
	# 兜底成 1，防止 _blades 为空时下面 float(i) / float(n) 除以 0。
	var n := maxi(1, _blades.size())
	for i in range(_blades.size()):
		# roll 由 i/n - 0.5 线性取值，范围是 [-23°, +23° * (n-1)/n]；
		# 推测：n = 4 时实际是 -23° / -11.5° / 0° / +11.5°，并不关于 0 对称，
		# 与下一行"正负 23 度"的措辞略有出入，但这是既有实现，注释不改行为。
		# 只错开正负 23 度左右：既叠成一束、又有厚度
		var roll := deg_to_rad(46.0 * (float(i) / float(n) - 0.5))
		# 把候选法线绕喷射轴 roll 一下 = 这一片的法线；normalized() 抹掉浮点误差累积。
		var nrm := (Basis(ax, roll) * perp).normalized()
		# 宽度方向的候选 = 法线 × 轴向（与法线、轴向都正交）；真正的基向量 X 取它的相反数，
		# 理由见下面 basis 那两行。
		var wid := nrm.cross(ax).normalized()
		# Basis 的三列是 (X, Y, Z)。X 取 **-wid** 而不是 +wid：这样 X × Y 才等于 Z，
		# 基是右手系（正交且行列式 +1）；取 +wid 会得到镜像基，四边形的正反面与
		# 着色器里的 UV 方向都会翻过来（火会变成背面朝向相机）。
		# 长度轴取 -ax：叶片几何在本地 z 的负半轴，所以"本地 -Z"要指向喷射方向
		_blades[i].basis = Basis(-wid, nrm, -ax)

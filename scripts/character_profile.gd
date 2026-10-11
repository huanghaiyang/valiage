class_name CharacterProfile
extends RefCounted
## 角色档案：换角色 = 换一份档案（模型 / 目标身高 / 动画库 / 动作名映射 / 右手挂点）。
##
## 设计意图（对应需求"后期换模型"）：
##   * 模型路径、目标身高都写在这里，player.gd 不再硬编码 Mage；
##   * 身高**自动量模型的网格包围盒**再算缩放 → 换任何模型都能精确到目标身高（1.5m）；
##   * 动画来源按档案指定：没有自带动画的模型（如森林男）会自动建 AnimationPlayer
##     并把烘焙好的动画库挂上去，轨道路径是 `root/Skeleton3D:<骨骼>`（与本档案模型结构一致）；
##   * 手部挂点用**名字列表**查找（hand.r / RightHand / handslot_r…），换骨架也能挂上法杖。
##
## ==================== 文件职责 / 依赖 / 接口 / 已知坑 ====================
## 【系统归属】
##   角色外观系统（"后期换模型"能力）的**唯一数据源**；同时为法杖握持系统提供挂点与握点几何。
##   与法杖相关的历史坑、坐标系不变量，见 docs/法杖握持与朝向系统-技术文档.md（本文件注释与它保持一致）。
##
## 【关键依赖】
##   * 无 autoload 依赖：本文件不碰单例、不读写全局状态；整个类只有 static 函数（纯工具类）。
##   * 调用方：
##       - scripts/player.gd：preload 后别名 CharProfile，真正负责 instantiate / 缩放 / 挂杖；
##       - tools/check_character.gd、tools/check_socket.gd：离线自检脚本（改接口会一并影响它们）。
##   * PROFILES 里写死的资源路径必须真实存在（不存在时 player.gd 只 push_warning、不崩溃）：
##       - 角色场景：res://assets/models/characters/主角.glb、Mage.glb
##       - 动画库：res://assets/animations/zhujue.tres（tools/ 里烘焙面板的产物）
##   * staff_hold_rot_deg 的数值由 tools/solve_staff_hold.gd 解算得出
##     （在 Torch Idle 的手骨姿势下解出"让杖身竖直"的固定欧拉角）；重新解算会覆盖档案里的这一行。
##
## 【主要对外接口】（全部 static，不需要实例化本类）
##   get_profile(id)                      -> Dictionary  取档案；未知 id 回退 zhujue（不是 mage）
##   ids()                                -> Array       全部档案 id（当前仓库未见调用点）
##   measure_height(scene)                -> float       网格 AABB 高度（模型局部单位）
##   find_hand(node, names)               -> Node3D      查找/创建手部挂点
##   hand_grip_offset(skel, bone, along)  -> Vector3     腕 → 掌心的握点偏移（手骨本地坐标）
##   hand_out_normal(skel, bone)          -> Vector3     掌心外法线（手骨本地坐标）
##   clip_of(profile, logical, available) -> String      逻辑动作名 → 本档案实际剪辑名
##
## 【已知的坑 / 注意事项】
##   1. PROFILES 是 const Dictionary，get_profile() 返回的是**共享引用**而不是拷贝 ——
##      调用方不要就地修改返回值（改一次就会污染整个运行期的档案）。
##   2. 存在硬编码的骨骼命名假设：hand_out_normal() 只认 ARP/Mixamo 风格的 index1_base.l 这套名字，
##      换骨架（KayKit 等）会找不到骨骼并返回 Vector3.ZERO —— 调用方必须把零向量当成"该能力不可用"。
##   3. "身高"量的是**网格**包围盒（含头发/帽子），不是骨骼高度；骨骼 AABB 会明显偏小。
##   4. 注释里提到的"森林男"档案与 clips_from 继承，当前 PROFILES 里并不存在（只有 zhujue / mage），
##      所以 clip_of() 里那条继承分支暂时走不到（推测：为后续新档案预留）。
##   5. 本文件里的 print(...) 是**既有调试输出**，不是 TODO；删掉只影响日志，不影响几何结果。
##
# ---------- 档案字典的字段含义（PROFILES 里每个档案都是这些 key） ----------
#   label              : 显示名，只用于日志/报错文案，不参与任何逻辑判断
#   scene              : 角色模型资源路径（.glb），player.gd 会 load() 后 instantiate()
#   height             : 目标身高（米）。模型网格原始高会被缩放到这个值
#                        （1.5 = 主角，写实成年偏矮；mage 1.08 = KayKit 矮胖体型）
#                        调大 → 角色更高更瘦长，碰撞半径/胶囊高/步高上限/法杖长度都会跟着放大
#   lib                : 烘焙好的 AnimationLibrary(.tres) 路径；空字符串 "" = 走
#                        "模型自带动画"或 KayKit 回退（player.gd：lib 为空时自动挂 kaykit 库）
#   hand_bones         : 手部挂点候选名列表，**顺序即优先级**；比较前先经 _norm() 规范化
#   staff_hold_rot_deg : 法杖握持角（度，欧拉 XYZ）。只在"刚性跟手"旧模式（world_stable=0）
#                        生效；稳定模式（默认）下不影响朝向，但位置仍会受影响
#   clips              : 逻辑动作名 → 剪辑名映射。字符串 = 唯一候选；数组 = 按顺序取
#                        "库里真实存在"的第一个（判定逻辑见 clip_of）
#   clips_from（可选）  : 本档案 clips 为空时，继承该 id 档案的 clips（省得重复维护几十项映射）
##
# ==================== 档案数据表（换角色只改这里） ====================

const PROFILES := {
	## 主角（Tripo + ARP 骨架）—— 当前唯一角色，动作映射直接写在本档案里
	"zhujue": {
		"label": "主角",
		"scene": "res://assets/models/characters/主角.glb",
		"height": 1.5,
		"lib": "res://assets/animations/zhujue.tres",
		# 挂点候选名在比较前会过 _norm()（转小写 + 删掉 . _ - : 空格），所以 hand.l / hand_l / HandL
		# 是同一个名字；顺序 = 优先级，find_hand() 从头往后试，命中即返回。
		# ★ 左手排在右手之前：Torch 系列动作是**左手持物**（player.gd 里那句"右手挂点"是历史文案）
		"hand_bones": ["hand.l", "hand_l", "LeftHand", "mixamorig_LeftHand",
			"handslot_l", "hand_L", "Wrist_L", "Left_Hand",
			"hand.r", "hand_r", "RightHand", "mixamorig_RightHand", "handslot_r"],
		## 握持角：tools/solve_staff_hold.gd 解出（Torch Idle 手骨姿势下让杖身竖直）
		# 单位：度（欧拉 XYZ）。held_staff.gd 在标定阶段用它组 Basis（Basis.from_euler），
		# 因此这是"手骨局部"的固定朝向补偿；改大/改小 = 杖在掌心里绕某轴自转一档。
		# ★ 稳定模式（staff_world_stable > 0，默认）下朝向由世界稳定逻辑独占，**不读这个值** ——
		#   想靠改这里纠正朝向是无效的，要先关掉稳定模式（见技术文档 §5.4 / §11.14）。
		"staff_hold_rot_deg": Vector3(-61.6, -45.0, -29.5),
		# 逻辑动作名 → 剪辑名。值是**字符串**（唯一候选）或**数组**（按顺序取库里真实存在的第一个）；
		# 全部候选都不存在时，clip_of() 会返回逻辑名本身，player.gd 找不到该动画就回退 Idle。
		# 带 "kaykit/" 前缀的 key 是 player.gd **现用**的逻辑名（ANIM_STRAFE_L / ANIM_ROLL 等常量
		# 就是这些字符串），改名必须同步改 player.gd，否则等于没有映射。
		"clips": {
			# —— 移动（用户规格：Torch 系列；走和跑共用一条，跑用 1.4× 速度）——
			# 注意："-stuff" 那条是**改过 rest** 的版本 —— 手臂相对旋转≈0，重定向后会变成夹臂，
			#       所以排在原版之后（原版可用时就用原版）。
			"Idle": ["Standing Torch Idle 01", "Standing Torch Idle 01-stuff", "Unarmed Idle", "Great Sword Idle"],
			"Walking_A": ["Standing Torch Run Forward", "Great Sword Run", "Standard Walk"],
			"Running_A": ["Standing Torch Run Forward", "Great Sword Run", "Fast Run"],
			# 侧移 / 转向：用 Torch 的左右走与 90° 转身（比原来的"用冲刺凑"贴合）
			"kaykit/Strafe_Left": ["Standing Torch Walk Left", "Standing Torch Run Forward", "Standard Walk"],
			"kaykit/Strafe_Right": ["Standing Torch Walk Right", "Standing Torch Run Forward", "Standard Walk"],
			"kaykit/DashLeft": ["Standing Torch Turn Left 90", "Walking Left Turn"],
			"kaykit/DashRight": ["Standing Torch Turn Right 90", "Running Right Turn"],
			"kaykit/DashFront": ["Standing Torch Run Forward", "Unarmed Run Forward"],
			"kaykit/DashBack": ["Standing Torch Run Back", "Unarmed Run Back"],
			# —— 跳跃：Standing Torch Jump ——
			"Jump_Full_Long": ["Standing Torch Jump", "Great Sword Jump", "Jumping"],
			"Jump_Full_Short": ["Standing Torch Jump", "Great Sword Jump", "Jumping"],
			"Jump_Idle": ["Standing Torch Jump", "Great Sword Jump", "Jumping"],
			"kaykit/Hop": ["Standing Torch Jump", "Great Sword Jump", "Jumping"],
			# —— 爬坡 / 爬梯：库里已有 Mixamo 的"爬墙"动作（比"上台阶跑"贴合）——
			"kaykit/Climbing": "Climbing Up Wall",
			# —— 翻滚（用闪避替代）——
			"kaykit/Roll": "Dodging Right",
			# —— 施法：Spell Cast ——
			"Spellcasting": ["Spell Cast", "Sword And Shield Casting", "Standing 1H Magic Attack 01"],
			# —— 重击：临时也用施法动作 ——
			"kaykit/HeavyAttack": ["Spell Cast", "Sword And Shield Casting", "Standing 1H Magic Attack 01"],
			# —— 受击/倒地：Sword And Shield Death ——
			"kaykit/Defeat": ["Sword And Shield Death", "Jogging Stumble"],
			# —— 坐：Male Sitting Pose 是"静态姿势"，被烘焙的"跳过静止 take"过滤掉了，
			#    先用待机顶替；想要真坐姿：面板勾「保留静止姿势」再点②，然后把这里改成该剪辑名 ——
			"Sit_Floor_Idle": "Unarmed Idle",
			"Sit_Chair_Idle": "Unarmed Idle",
			"Lie_Idle": "Laying Nodding",
			"Lie_Down": "Laying Nodding",
			"kaykit/LayingDownIdle": "Laying Nodding",
			# 仍缺失（需要再从 Mixamo 下）：kaykit/Wave（挥手）、kaykit/Dance（跳舞）
			# —— 不映射，播放时会自动回退到 Idle
		},
	},
	## 旧的 KayKit Mage（保留，便于一键回退或对比）
	## 换回旧角色的办法：把 player.gd 的 character_id 改成 "mage"（模型自带的 1H_Wand / 2H_Staff
	## / Spellbook 会被 player.gd 自动隐藏，避免和自定义法杖叠在一起）。
	# lib 为空串 → player.gd 在 _ready 里把 KayKit 动画库挂到 "kaykit" 前缀下；
	# clips 为空 → clip_of() 原样回传逻辑名，所以此时逻辑名本身必须带 "kaykit/..." 前缀才找得到动画；
	# 这里也刻意没有 clips_from（推测：不让旧角色继承主角的 Torch 系列动作）。
	# height 1.08 = KayKit Mage 的矮胖体型目标身高（比主角 1.5 明显小，法杖长度会跟着缩短）。
	"mage": {
		"label": "KayKit Mage",
		"scene": "res://assets/models/characters/Mage.glb",
		"height": 1.08,
		"lib": "",
		"hand_bones": ["handslot_r"],
		"clips": {},
	},
}


# ==================== 档案查询接口 ====================

## 按 id 取角色档案。
## 参数 id：档案 key（"zhujue" / "mage"…），**大小写敏感**，必须与 PROFILES 的 key 逐字符一致。
## 返回：档案字典的**共享引用**（不是拷贝）——调用方只读，就地修改会污染整个运行期的档案。
## 副作用：仅未命中时 push_warning（文本带 [CharacterProfile] 前缀，可据此搜日志）。
## 调用时机：player.gd::_ready() 取一次并缓存；_instantiate_character() 在缓存为空时再兜底取一次。
## 注意事项：未知 id 回退到 **zhujue**（不是 mage）—— 拼错 id 不会崩，只会静默变成主角，
##          只有看日志/看模型才发现，排查"换了模型没效果"时优先怀疑这里。
static func get_profile(id: String) -> Dictionary:
	if PROFILES.has(id):
		return PROFILES[id]
	push_warning("[CharacterProfile] 未知角色 id=%s，回退到 zhujue（主角）" % id)
	return PROFILES["zhujue"]


## 列出全部可用档案 id（= PROFILES.keys()，顺序为字典书写顺序）。
## 返回：Array（未标注元素类型，元素是 String key）；无副作用。
## 调用时机：当前仓库内未见调用点（推测：给编辑器面板/角色下拉列表遍历用）。
## 注意事项：返回的是**新建的 key 数组**，改它不会影响 PROFILES；但不要用它做运行期增删档案，
##          换角色应当直接改本文件的 PROFILES 常量。
static func ids() -> Array:
	return PROFILES.keys()


# ==================== 身高测量（网格包围盒） ====================

## 量模型的网格包围盒高度（模型局部单位）。用网格而不是骨骼：
## "身高"看的是可见外形（含头发/帽子），骨骼高度会偏小。
## 参数 scene：角色模型的 PackedScene（**未实例化的模板资源**；函数内部自己临时实例化一份）。
## 返回：AABB 的 y 尺寸（模型局部单位，尚未乘任何缩放）；scene 为空或模型无网格时返回 0.0。
## 副作用：临时实例化并立即释放一份模型；不改动传入的 scene 资源。
## 调用时机：player.gd::_instantiate_character() 在 add_child 之前调用，用来算 _auto_scale
##          （= 档案目标身高 / 本函数返回值）；tools/check_character.gd、check_socket.gd 用它打印原始高。
## 注意事项：
##   * 返回 0.0 必须由调用方兜底（player.gd 判 raw_h > 0.01，否则缩放按 1.0 处理，
##     角色会保持模型原始大小而不是档案里的目标身高）；
##   * 量的是模板几何，与当前动画帧/骨骼姿势无关 —— 所以同一模型任何时候量出来都一样，结果可复现。
static func measure_height(scene: PackedScene) -> float:
	if scene == null:
		return 0.0
	# 只为量尺寸而临时实例化：传进来的是模板资源，实例化后不进场景树、也不会触发 _ready，
	# 所以量到的是模型原始（未摆姿势）的几何。
	var root := scene.instantiate()
	var box := _aabb_of(root, Transform3D.IDENTITY)
	# ★ 用 free() 而非 queue_free()：该实例从未 add_child 进树，立即释放即可，
	#   免得把一整份模型拖到帧末（这里只想要一个数）。
	root.free()
	# size == ZERO 有两种来源（这里不需要区分）：模型里没有任何 VisualInstance3D，
	# 或所有网格的 AABB 都退化。统一按"量不到"返回 0.0，交给调用方回退。
	if box.size == Vector3.ZERO:
		return 0.0
	# 只取 y（高度）。x/z 也被 _aabb_of 一并算出（合并 AABB 必须知道完整包围盒），但这里不用。
	return box.size.y


## 递归求世界空间 AABB（模型未入树，自己累积变换）
## 参数 node：子树根；xf：**父级累积到本节点之前**的变换（顶层调用传 Transform3D.IDENTITY）。
## 返回：合并了本子树所有 VisualInstance3D 的 AABB（世界/模型根空间）；一个网格都没有时 size 为 ZERO。
## 副作用：无（纯计算，不改节点）。
## 调用时机：只被 measure_height() 调用（即只需要一个"高多少"的标量时）。
## 注意事项：这里**不能**读 global_transform —— 模型还没 add_child 进树，变换尚未就绪，
##          历史上这么读会打印出 715 cm 之类的假数据（见技术文档 §2.3）。
static func _aabb_of(node: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	# ★ first 标志是"看起来多余但必要"的写法：AABB() 默认 position=0、size=0，
	#   如果拿它去 merge 第一个子盒，就等于把世界原点 (0,0,0) 也裹进包围盒里 →
	#   量出来的身高会莫名其妙变大（帽子/脚底被原点撑开）。所以第一个有效盒是"赋值"而不是"合并"。
	var first := true
	var here := xf
	# 手动自上而下累积变换：节点未入树，global_transform 不可信（见函数头注释）。
	if node is Node3D:
		here = xf * (node as Node3D).transform
	# 只有 VisualInstance3D 才有 get_aabb()；用 is 判断可一次性覆盖 MeshInstance3D 等所有子类。
	if node is VisualInstance3D:
		var local := (node as VisualInstance3D).get_aabb()
		var box := _xform_aabb(local, here)
		out = box
		first = false
	for c in node.get_children():
		var b := _aabb_of(c, here)
		# 跳过空子树：没有网格时子递归返回的是 AABB()（position 在原点、size 为 0），
		# 直接 merge 进来同样会把世界原点算进包围盒。
		if b.size == Vector3.ZERO:
			continue
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


## 把一个局部 AABB 变换到父空间，仍保持**轴对齐**。
## 参数 a：源 AABB（如 MeshInstance3D.get_aabb()）；xf：要施加的变换（可能含旋转/缩放）。
## 返回：变换后 8 个角点的最小轴对齐包围盒。有旋转时会比真实包围体略大（保守值，正合适量身高）。
## 副作用：无。调用时机：由 _aabb_of 处理每个 VisualInstance3D 时调用。
static func _xform_aabb(a: AABB, xf: Transform3D) -> AABB:
	# 起点 = 变换后的最小角，size 先置零；随后 expand 会把它扩到覆盖全部 8 个角点。
	var out := AABB(xf * a.position, Vector3.ZERO)
	# 用位掩码一次枚举 8 个角点：i & 1 → x 取 size.x、i & 2 → y、i & 4 → z，其余取 0。
	for i in 8:
		var corner := a.position + Vector3(
			a.size.x if (i & 1) else 0.0,
			a.size.y if (i & 2) else 0.0,
			a.size.z if (i & 4) else 0.0)
		# ★ 必须**逐角点**变换：一旦 xf 含旋转或非等比缩放，"只变换 position 再拼 size" 得到的
		#   轴对齐盒会明显变大或变小（这是包围盒变换最经典的坑）。
		var p := xf * corner
		out = out.expand(p)
	return out


# ==================== 手部挂点查找与握点几何 ====================

# （下面这句"右手挂点"与函数名 find_hand 都是历史文案：函数返回的是候选列表里第一个命中的手，
#  当前档案把左手排在前面，所以通常拿到左手 —— 详见本函数末尾的注意事项）
## 找右手挂点：
##   1) 模型自带的挂点节点（KayKit 的 handslot_r、已有 BoneAttachment3D…）；
##   2) 没有就从 Skeleton3D 的**骨骼名**里找，并创建一个 BoneAttachment3D 当挂点
##      （ARP / Mixamo 这类骨架只有骨骼、没有挂点节点 —— 骨骼不是场景节点，get_node 找不到）。
## 参数 node：角色模型根（已实例化，通常已 add_child 进树）；names：候选挂点名列表（String，
##          大小写与 . _ - : 空格均不敏感，比较前统一过 _norm()）。
## 返回：Node3D 挂点；找不到返回 null（调用方 player.gd 只 push_warning，法杖就不挂了）。
## 副作用：**会改场景树** —— 命中骨骼但模型没有现成挂点时，会在 Skeleton3D 下新建/复用
##        "HandSocket" 这个 BoneAttachment3D 子节点，因此反复调用不会产生一堆重复节点。
## 调用时机：player.gd::_attach_held_staff()（换角色/重载模型时各一次）；
##          tools/check_socket.gd 离线自检也用它。
## 注意事项：
##   * 函数名是历史遗留的 find_hand，实际返回的是**候选列表里第一个命中的手**；档案把左手排在前面
##     （Torch 系列左手持物），所以实际常拿到左手 —— player.gd 注释里的"右手挂点"是旧文案，别被误导。
##   * 返回的节点优先级：作者手放的挂点节点 > 骨骼名新建的挂点。前者位置/朝向是美术调过的，更好。
static func find_hand(node: Node, names: Array) -> Node3D:
	# 先把候选名规范化一次，避免在后面几百根骨骼的循环里反复 _norm()（骨骼数量级不小）。
	var want: Array[String] = []
	for n in names:
		want.append(_norm(String(n)))
	# 1) 现成的挂点节点
	# 用栈做深度优先遍历而不是递归/按名查找：骨骼不是场景节点，只能扫节点树；
	# 顺序无所谓 —— 精确名字命中即返回，不依赖遍历先后。
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is Node3D and want.has(_norm(String(cur.name))):
			return cur as Node3D
		for c in cur.get_children():
			stack.append(c)
	# 2) 骨骼名精确匹配
	# 只有"节点里找不到挂点"才走骨骼：优先复用美术放好的挂点（位置/朝向人工调过）。
	var skel := _find_skeleton(node)
	if skel == null:
		return null
	for i in skel.get_bone_count():
		# 这里要求**整名相等**（不是 contains）：否则 hand 骨旁边可能误命中 hand_ik_target 之类。
		if want.has(_norm(skel.get_bone_name(i))):
			return _make_socket(skel, skel.get_bone_name(i))
	# 3) 退一步：先找左手 hand 骨骼，再找右手（Torch 系列是左手持物，所以优先左）
	# ★ 写成两趟（pass 0 左、pass 1 右）而不是"一趟顺序扫描"：一趟会变成"骨骼表里排在前面的手赢"，
	#   结果依赖模型作者导出顺序；两趟才能保证"只要存在左手 hand 骨就一定优先左手"。
	for pass_i in 2:
		for i in skel.get_bone_count():
			var nm := _norm(skel.get_bone_name(i))
			if not nm.contains("hand"):
				continue
			# 规范化已把所有分隔符删掉，只剩一个紧凑的小写名字，所以 "left"/"right" 与结尾 "l"/"r"
			# 两种命名风格都能覆盖（hand.l → handl 以 l 结尾；mixamorig_lefthand 含 left）。
			var is_left := nm.contains("left") or nm.ends_with("l")
			var is_right := nm.contains("right") or nm.ends_with("r")
			if pass_i == 0 and is_left:
				return _make_socket(skel, skel.get_bone_name(i))
			if pass_i == 1 and is_right:
				return _make_socket(skel, skel.get_bone_name(i))
	# 三条路都没找到：返回 null，由调用方决定降级方式（player.gd 只打警告，不抛异常）。
	return null


## 掌心偏移：手骨 → 第一根手指骨的 45% 处（在**手骨本地坐标**里）。
## ARP/Mixamo 的 hand 骨是**腕关节**，而 KayKit 的 handslot_r 是作者放在握点上的 ——
## 直接挂在腕关节上，法杖会差几厘米，看起来像"脱离手臂"。
## 注意：不能改 BoneAttachment3D 自己的 position（每帧会被骨骼姿态覆盖），
## 要把这个偏移交给法杖模型（HeldStaff.grip_offset）。
## 默认系数 0.45 = 从腕关节沿"掌心方向"走 45%；调大 → 握点更靠指尖、法杖更前伸；
## 调小 → 更贴腕关节，法杖像挂在手腕上。
## 注意：player.gd 调用时**总是显式传自己的 staff_grip_along**（检查器默认 1.0），
## 所以这个 0.45 只对省略参数的调用方（工具脚本/手工调用）生效 —— 游戏内实际多半是 1.0。
const GRIP_ALONG_HAND := 0.45

## 计算"腕关节 → 掌心"的握点偏移（在**手骨本地坐标**里，可直接喂给法杖模型当 grip_offset）。
## 参数 skel：含该手骨的 Skeleton3D；bone_name：手骨名（可用 find_bone 找到的任意写法）；
##          along：沿掌心方向的比例系数，默认 GRIP_ALONG_HAND(0.45)，player.gd 传 staff_grip_along(1.0)。
## 返回：手骨本地空间的偏移向量（单位是"骨内单位"，含骨骼 rest 缩放的量级，不是米！）；
##      skel 为空 / 骨骼找不到 / 骨骼没有任何子骨 时返回 Vector3.ZERO。
## 副作用：无状态改动；每次调用会 print 一行"掌心方向"调试日志（既有行为，不是 TODO）。
## 调用时机：player.gd::_attach_held_staff() 挂杖时一次（作为自动拳心算法失败后的回退值）；
##          对标定前/加载早期的姿势敏感调用要当心 —— 见下方"为什么用 rest 姿势"的注释。
## 注意事项：返回值是**手骨本地**坐标，绝不能直接塞进世界/父节点空间（技术文档 §3.4：偏移由
##          HeldStaff 这个挂点子节点承载，_model.position 里不能再加一次，否则双重偏移）。
static func hand_grip_offset(skel: Skeleton3D, bone_name: String, along := GRIP_ALONG_HAND) -> Vector3:
	if skel == null:
		return Vector3.ZERO
	var hi := skel.find_bone(bone_name)
	if hi < 0:
		return Vector3.ZERO
	# ★ 用 get_bone_global_rest（**rest 姿势**）而不是当前动画帧：结果稳定、可复现，
	#   避免"切杖那一刻角色正在跑/正在挥"导致握点概率性变化（技术文档 §5.4 同类历史坑）。
	var hand_rest := skel.get_bone_global_rest(hi)
	# ★ 用**四根指骨的平均方向**当"掌心方向"。
	#   只用第一根子骨是不行的：手骨的第一根子骨常是拇指侧的，会把法杖推到手掌一侧 ✗
	var acc := Vector3.ZERO
	var cnt := 0
	for ci in skel.get_bone_count():
		if skel.get_bone_parent(ci) != hi:
			continue
		# 排除拇指：拇指朝向与其余四指张开约 90°，混进平均值会把"掌心方向"拽向掌侧。
		# 用 to_lower().contains("thumb") 而不是精确名，兼容 thumb.01 / mixamorig_Thumb1 等写法。
		if skel.get_bone_name(ci).to_lower().contains("thumb"):
			continue
		acc += skel.get_bone_global_rest(ci).origin - hand_rest.origin
		cnt += 1
	# 兜底：手骨没有任何非拇指子骨（极端/精简骨架）时退回"第一根子骨"的方向，
	# 宁可给一个不太准的偏移，也不要返回 ZERO（返回零会让法杖完全贴腕关节，差几厘米）。
	if cnt == 0:
		for ci in skel.get_bone_count():
			if skel.get_bone_parent(ci) == hi:
				return hand_rest.basis.inverse() * (skel.get_bone_global_rest(ci).origin - hand_rest.origin) * along
		return Vector3.ZERO
	# 把"骨架全局空间的平均方向"用 rest basis 的**逆**转回手骨本地空间；
	# 因为 basis 里含骨骼 rest 缩放，结果量级是"骨内单位"而非米（要乘父级缩放才是世界距离）。
	var local := hand_rest.basis.inverse() * (acc / float(cnt))
	# 既有调试日志：每次挂杖打印一次，方便核对"掌心方向"是否合理；删掉它不影响任何几何结果。
	print("[staff] 掌心方向 = %d 根指骨的均值｜沿手指 %.2f 处｜偏移 %.3f 骨内单位" % [cnt, along, (local * along).length()])
	return local * along


## 在骨架上取（或新建）一个 BoneAttachment3D 挂点（内部使用，由 find_hand 调用）。
## 参数 skel：含目标骨骼的 Skeleton3D；bone_name：挂点要跟随的**骨骼名**（非节点名）。
## 返回：挂点节点（一定是 skel 的子节点，会跟随 bone_name 所指骨骼的姿态）。
## 副作用：**改场景树** —— 首次调用会在 skel 下 add_child 一个名为 "HandSocket" 的 BoneAttachment3D；
##        若已存在同名节点则只改它的 bone_name（复用），因此重复调用不会挂出一堆重复挂点。
## 调用时机：find_hand() 在"模型没有现成挂点节点、但骨骼名命中"时调用一次。
## 注意事项：BoneAttachment3D 的 transform 每帧由骨骼姿态覆盖 —— **不要**去写它的 position
##          来承载握点，握点必须交给法杖模型（HeldStaff.grip_offset / position），否则每帧被抹掉。
static func _make_socket(skel: Skeleton3D, bone_name: String) -> BoneAttachment3D:
	# 先找同名节点复用：模型重载/多次调用时不重复建节点；也避免 Godot 给重名节点自动改名
	# （HandSocket2、HandSocket3…），那会让后续按名字取挂点的代码失效。
	var old := skel.get_node_or_null("HandSocket")
	if old is BoneAttachment3D:
		(old as BoneAttachment3D).bone_name = bone_name
		return old as BoneAttachment3D
	var att := BoneAttachment3D.new()
	att.name = "HandSocket"
	skel.add_child(att)
	# 保持原有的书写顺序（先 add_child、后设 bone_name），没有特殊理由不要调换：
	# BoneAttachment3D 的骨骼索引是在入树/骨架就绪阶段解析的（推测：反序或许也能补上，但不必冒这个险）。
	att.bone_name = bone_name
	return att


## 深度优先找子树里第一个 Skeleton3D（内部使用）。
## 参数 node：子树根（通常是角色模型根节点）；返回命中的 Skeleton3D，没有则 null。
## 副作用：无。
## 注意事项：只返回**第一个**骨架 —— 若一个模型里有多套骨架（角色 + 道具/坐骑），
##          结果取决于子节点顺序；当前各档案模型都只有一套骨架，够用
##          （推测：将来模型带多骨架时需要改成按名字/路径查找）。
static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null


## 归一化名字：转小写并删掉 . _ - : 和空格，用于手骨名/挂点名的"宽松比较"（内部使用）。
## 参数 s：原始名字（节点名或骨骼名）；返回：删掉上述分隔符后的小写名字。
## 副作用：无。调用时机：find_hand 预处理候选名一次，之后每次比较再各调一次。
## 注意事项：这是**有意的宽松匹配** —— hand.l / hand_l / hand-l / Hand L 会被当成同一个名字；
##          代价是 handl 与 hand_l 无法区分（本项目接受该风险，因为它只用于手骨名比较）。
static func _norm(s: String) -> String:
	return s.to_lower().replace(".", "").replace("_", "").replace("-", "").replace(":", "").replace(" ", "")


## 逻辑动作名 → 本档案的实际剪辑名。
## 映射值可以是字符串（唯一候选），也可以是数组（按顺序取**库里真实存在**的第一个）。
# ⚠ 上面的两行 ## 文档（"逻辑动作名 → 实际剪辑名"）其实描述的是文件末尾的 clip_of()，与本函数无关：
#   属于历史错位文档，原样保留、没有搬动（clip_of 的完整文档写在它自己上方）。
## 掌心外法线（**手骨本地空间**，单位向量）：
##   掌轴 = 腕 → 4 根掌骨(*1_base) 的均值方向；
##   手宽 = 食指基 → 小指基；
##   法线 = 掌轴 × 手宽；方向取"**手指卷曲那一侧**"（用指尖 index3/middle3 的位置判定）。
## 用途：杖身半径补偿 —— 让有粗细的杖沿这个方向推出去，杆的表面贴住掌心。
## 参数 skel：含该手骨的骨架；bone_name：手骨名（必须是能 find_bone 到的写法）。
## 返回：**手骨本地空间**的单位向量（掌心外法线）；下面任何一步缺骨骼/向量退化都会返回 Vector3.ZERO
##      —— 调用方必须把零向量读作"该能力不可用"，而不是"方向为零"。
## 副作用：无（纯计算）。用的是骨骼 **rest 姿势**，与当前动画帧无关，因此结果稳定可复现。
## 调用时机：当前仓库内未找到调用点（推测：原本用于自动杖身半径补偿，后来 player.gd 改成用
##          检查器里的 staff_grip_out 手动补一点，见技术文档 §6.1）。
## 注意事项：命名是硬编码的 ARP/Mixamo 风格（index1_base.l / pinky1_base.l / index3.l）——
##          换成 KayKit 或自定义骨架必然一根都找不到并返回 ZERO。这是设计取舍，不是 bug。
static func hand_out_normal(skel: Skeleton3D, bone_name: String) -> Vector3:
	if skel == null:
		return Vector3.ZERO
	var hi := skel.find_bone(bone_name)
	if hi < 0:
		return Vector3.ZERO
	# 左右只能从**手骨名**猜：下面的指骨名是 "index1_base.l"/"index1_base.r" 这种后缀风格，
	# 所以先定 side 再去拼名字。默认 "l"（Torch 系列是左手持物，命中率更高）。
	var side := "l"
	var low := bone_name.to_lower()
	# ends_with("r") 是为了兼容 hand.r / handr 这类没有 right 字样的写法。
	# 注意这里只做了小写化、没有过 _norm()：所以 "hand.r" 以 r 结尾 → 判右手 ✓；
	# "hand.l" 不属于上述任何情况 → 落到默认左手 ✓（本案正是左手持杖，方向对）。
	if low.contains("right") or low.ends_with("r"):
		side = "r"
	var hrest := skel.get_bone_global_rest(hi)
	var ho := hrest.origin
	var acc := Vector3.ZERO
	var n := 0
	# 掌轴（腕 → 掌骨根方向）取 index/middle/ring/pinky 四根 *1_base 的**均值**：
	# 单取一根会受该手指的张开角度影响，均值才能代表整只手掌的朝向。
	# 用 n 计数而不是"命中一根就 return"：缺一两根指骨时照样能算均值，
	# 只有四根全缺（n == 0）才在下面判定"命名风格不匹配"。
	for f in ["index", "middle", "ring", "pinky"]:
		var bi := skel.find_bone("%s1_base.%s" % [f, side])
		if bi >= 0:
			acc += skel.get_bone_global_rest(bi).origin - ho
			n += 1
	# 四根掌骨一根都没命中 → 说明命名风格不匹配（换骨架的典型情况），直接判定"不可用"。
	if n == 0:
		return Vector3.ZERO
	var palm := acc / float(n)
	var i1 := skel.find_bone("index1_base." + side)
	var p1 := skel.find_bone("pinky1_base." + side)
	# 手宽需同时有食指基与小指基，缺一个就无法定义"横向"，所以这里是硬失败。
	if i1 < 0 or p1 < 0:
		return Vector3.ZERO
	var across := skel.get_bone_global_rest(i1).origin - skel.get_bone_global_rest(p1).origin
	# 掌轴 × 手宽 = 垂直掌面的法线。此刻只知道它垂直于掌面，指向掌心还是掌背**尚不确定**。
	var normal := palm.cross(across)
	# 掌轴与手宽平行（手指并拢成一条线）时叉乘退化；用工程阈值 0.0001 拦掉，避免 normalize 出 NaN。
	if normal.length() < 0.0001:
		return Vector3.ZERO
	normal = normal.normalized()
	var tip := skel.find_bone("index3." + side)
	# 食指指尖缺失时退到中指指尖（同样能判定掌面朝向）。
	if tip < 0:
		tip = skel.find_bone("middle3." + side)
	var s := 1.0
	if tip >= 0:
		# ★ 用"指尖相对腕关节在法线上的投影符号"决定法线指掌心还是指掌背：
		#   手指天然朝掌心侧卷曲，所以指尖必然落在掌心那一侧 → 投影为正说明当前法线已朝外。
		var proj := (skel.get_bone_global_rest(tip).origin - ho).dot(normal)
		# 投影≈0（指尖几乎躺在掌面上）时不敢翻转：此时 signf(0)=0 会把向量清零，
		# 所以用 0.0001 阈值兜底，宁可保持原方向也不要返回零向量。
		s = signf(proj) if absf(proj) > 0.0001 else 1.0
	# 转回手骨本地空间并归一化（与 hand_grip_offset 同一套坐标约定：调用方拿到的都是"手骨本地"）。
	var local := hrest.basis.inverse() * (normal * s)
	return local.normalized()


# ==================== 逻辑动作名 → 剪辑名映射 ====================

## 把逻辑动作名翻译成本档案里真实存在的剪辑名（player.gd::_clip() 会再给它拼上动画库前缀）。
## 参数 profile：档案字典（get_profile() 的返回值）；
##      logical：逻辑动作名，取 player.gd 的 ANIM_* 常量（如 "Idle"、"kaykit/Strafe_Left"）；
##      available：当前 AnimationPlayer 里的剪辑名列表（player.gd 传 get_animation_list()）；
##                传空数组 = 不做存在性过滤。
## 返回：候选里第一个"库里存在"的名字；available 为空时返回第一个候选；
##      该逻辑名没有任何映射时返回**逻辑名本身**（让调用方按原名去找，找不到再回退 Idle）。
## 副作用：无（纯查表，不碰动画播放器）。
## 调用时机：每次切动画（player.gd::_clip() ← _play_anim / _play_move_anim），属热路径但只做字典查找。
## 注意事项：
##   * 映射值写错（库里没这个名字）**不会报任何错**：会被静默过滤成别的候选或逻辑名，
##     表现为"动作不对/角色不动"。排查时对照 player.gd 打印的动画清单，不能只看有没有报错。
##   * available 为空时**不做过滤**（见下面 `available.is_empty() or ...`）：工具脚本不传清单也能用，
##     代价是可能拿到库里不存在的名字。
static func clip_of(profile: Dictionary, logical: String, available := PackedStringArray()) -> String:
	# 用 get 而不是 []：档案允许不写 clips 字段（旧档案/精简档案不会因此报错）。
	var m: Dictionary = profile.get("clips", {})
	# clips 为空且写了 clips_from → 继承另一个档案的动作映射
	# （法师与森林男同一套 Mixamo 逻辑名/剪辑名，不用重复维护一份 40 项的映射表）
	# 注意：当前 PROFILES 里 mage 是 clips={} 且**没有** clips_from，所以它走的是"原样回传逻辑名"那条路。
	if m.is_empty() and profile.has("clips_from"):
		var src: Dictionary = PROFILES.get(String(profile["clips_from"]), {})
		m = src.get("clips", {})
	# ★ 默认值就是 logical 本身：没写映射的动作"原样返回"，等价于"未映射时按原名找，找不到就回退 Idle"
	#   （player.gd 的回退逻辑因此不需要额外分支）。
	var v: Variant = m.get(logical, logical)
	# 值是数组 → 候选优先级列表；值是字符串（唯一候选）则跳过整段，最后统一 String(v) 返回。
	if v is Array:
		var cands: Array = v
		# 按顺序取第一个"库里真实存在"的候选 —— 这样档案可以同时写"新动作优先、旧动作兜底"。
		for c in cands:
			var cn := String(c)
			if available.is_empty() or available.has(cn):
				return cn
		# 一个都不存在时返回第一候选而不是空串：保证调用方拿到非空名字，
		# 由它的 has_animation() 判定自然回退到 Idle（返回空串会让那类判断出现意外分支）。
		return String(cands[0]) if cands.size() > 0 else logical
	return String(v)

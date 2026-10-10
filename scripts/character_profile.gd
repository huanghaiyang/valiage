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

const PROFILES := {
	## 森林男（Tripo3D 白模 + Auto-Rig Pro 骨架），动画来自 Mixamo 重定向烘焙库
	"forest": {
		"label": "森林男",
		"scene": "res://assets/models/characters/森林男.glb",
		"height": 1.5,
		"lib": "res://assets/animations/mixamo.tres",
		"hand_bones": ["hand.l", "hand_l", "LeftHand", "mixamorig_LeftHand",
			"handslot_l", "hand_L", "Wrist_L", "Left_Hand",
			# 兜底：模型只有右手骨骼时也还能挂上
			"hand.r", "hand_r", "RightHand", "mixamorig_RightHand", "handslot_r"],
		## 握持角（相对手骨的固定旋转，单位度）：由 tools/solve_staff_hold.gd 解出 ——
		## 在 "Standing Torch Idle 01" 的手骨姿势下，让杖身（模型 +Y）**竖直**。
		## Vector3.ZERO = 关闭（回退到旧的"骨骼 rest + 前倾 60°"标定）。
		"staff_hold_rot_deg": Vector3(-75.8, -54.3, -22.6),
		"clips": {
			# —— 移动（用户规格：Torch 系列；走和跑共用一条，跑用 1.4× 速度）——
			"Idle": ["Standing Torch Idle 01", "Unarmed Idle", "Great Sword Idle"],
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
	"mage": {
		"label": "KayKit Mage",
		"scene": "res://assets/models/characters/Mage.glb",
		"height": 1.08,
		"lib": "",
		"hand_bones": ["handslot_r"],
		"clips": {},
	},
}


static func get_profile(id: String) -> Dictionary:
	if PROFILES.has(id):
		return PROFILES[id]
	push_warning("[CharacterProfile] 未知角色 id=%s，回退到 forest" % id)
	return PROFILES["forest"]


static func ids() -> Array:
	return PROFILES.keys()


## 量模型的网格包围盒高度（模型局部单位）。用网格而不是骨骼：
## "身高"看的是可见外形（含头发/帽子），骨骼高度会偏小。
static func measure_height(scene: PackedScene) -> float:
	if scene == null:
		return 0.0
	var root := scene.instantiate()
	var box := _aabb_of(root, Transform3D.IDENTITY)
	root.free()
	if box.size == Vector3.ZERO:
		return 0.0
	return box.size.y


## 递归求世界空间 AABB（模型未入树，自己累积变换）
static func _aabb_of(node: Node, xf: Transform3D) -> AABB:
	var out := AABB()
	var first := true
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
	if node is VisualInstance3D:
		var local := (node as VisualInstance3D).get_aabb()
		var box := _xform_aabb(local, here)
		out = box
		first = false
	for c in node.get_children():
		var b := _aabb_of(c, here)
		if b.size == Vector3.ZERO:
			continue
		if first:
			out = b
			first = false
		else:
			out = out.merge(b)
	return out


static func _xform_aabb(a: AABB, xf: Transform3D) -> AABB:
	var out := AABB(xf * a.position, Vector3.ZERO)
	for i in 8:
		var corner := a.position + Vector3(
			a.size.x if (i & 1) else 0.0,
			a.size.y if (i & 2) else 0.0,
			a.size.z if (i & 4) else 0.0)
		var p := xf * corner
		out = out.expand(p)
	return out


## 找右手挂点：
##   1) 模型自带的挂点节点（KayKit 的 handslot_r、已有 BoneAttachment3D…）；
##   2) 没有就从 Skeleton3D 的**骨骼名**里找，并创建一个 BoneAttachment3D 当挂点
##      （ARP / Mixamo 这类骨架只有骨骼、没有挂点节点 —— 骨骼不是场景节点，get_node 找不到）。
static func find_hand(node: Node, names: Array) -> Node3D:
	var want: Array[String] = []
	for n in names:
		want.append(_norm(String(n)))
	# 1) 现成的挂点节点
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is Node3D and want.has(_norm(String(cur.name))):
			return cur as Node3D
		for c in cur.get_children():
			stack.append(c)
	# 2) 骨骼名精确匹配
	var skel := _find_skeleton(node)
	if skel == null:
		return null
	for i in skel.get_bone_count():
		if want.has(_norm(skel.get_bone_name(i))):
			return _make_socket(skel, skel.get_bone_name(i))
	# 3) 退一步：先找左手 hand 骨骼，再找右手（Torch 系列是左手持物，所以优先左）
	for pass_i in 2:
		for i in skel.get_bone_count():
			var nm := _norm(skel.get_bone_name(i))
			if not nm.contains("hand"):
				continue
			var is_left := nm.contains("left") or nm.ends_with("l")
			var is_right := nm.contains("right") or nm.ends_with("r")
			if pass_i == 0 and is_left:
				return _make_socket(skel, skel.get_bone_name(i))
			if pass_i == 1 and is_right:
				return _make_socket(skel, skel.get_bone_name(i))
	return null


## 掌心偏移：手骨 → 第一根手指骨的 45% 处（在**手骨本地坐标**里）。
## ARP/Mixamo 的 hand 骨是**腕关节**，而 KayKit 的 handslot_r 是作者放在握点上的 ——
## 直接挂在腕关节上，法杖会差几厘米，看起来像"脱离手臂"。
## 注意：不能改 BoneAttachment3D 自己的 position（每帧会被骨骼姿态覆盖），
## 要把这个偏移交给法杖模型（HeldStaff.grip_offset）。
const GRIP_ALONG_HAND := 0.45

static func hand_grip_offset(skel: Skeleton3D, bone_name: String, along := GRIP_ALONG_HAND) -> Vector3:
	if skel == null:
		return Vector3.ZERO
	var hi := skel.find_bone(bone_name)
	if hi < 0:
		return Vector3.ZERO
	var hand_rest := skel.get_bone_global_rest(hi)
	# ★ 用**四根指骨的平均方向**当"掌心方向"。
	#   只用第一根子骨是不行的：手骨的第一根子骨常是拇指侧的，会把法杖推到手掌一侧 ✗
	var acc := Vector3.ZERO
	var cnt := 0
	for ci in skel.get_bone_count():
		if skel.get_bone_parent(ci) != hi:
			continue
		if skel.get_bone_name(ci).to_lower().contains("thumb"):
			continue
		acc += skel.get_bone_global_rest(ci).origin - hand_rest.origin
		cnt += 1
	if cnt == 0:
		for ci in skel.get_bone_count():
			if skel.get_bone_parent(ci) == hi:
				return hand_rest.basis.inverse() * (skel.get_bone_global_rest(ci).origin - hand_rest.origin) * along
		return Vector3.ZERO
	var local := hand_rest.basis.inverse() * (acc / float(cnt))
	print("[staff] 掌心方向 = %d 根指骨的均值｜沿手指 %.2f 处｜偏移 %.3f 骨内单位" % [cnt, along, (local * along).length()])
	return local * along


static func _make_socket(skel: Skeleton3D, bone_name: String) -> BoneAttachment3D:
	var old := skel.get_node_or_null("HandSocket")
	if old is BoneAttachment3D:
		(old as BoneAttachment3D).bone_name = bone_name
		return old as BoneAttachment3D
	var att := BoneAttachment3D.new()
	att.name = "HandSocket"
	skel.add_child(att)
	att.bone_name = bone_name
	return att


static func _find_skeleton(node: Node) -> Skeleton3D:
	if node is Skeleton3D:
		return node
	for c in node.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null


static func _norm(s: String) -> String:
	return s.to_lower().replace(".", "").replace("_", "").replace("-", "").replace(":", "").replace(" ", "")


## 逻辑动作名 → 本档案的实际剪辑名。
## 映射值可以是字符串（唯一候选），也可以是数组（按顺序取**库里真实存在**的第一个）。
static func clip_of(profile: Dictionary, logical: String, available := PackedStringArray()) -> String:
	var m: Dictionary = profile.get("clips", {})
	var v: Variant = m.get(logical, logical)
	if v is Array:
		var cands: Array = v
		for c in cands:
			var cn := String(c)
			if available.is_empty() or available.has(cn):
				return cn
		return String(cands[0]) if cands.size() > 0 else logical
	return String(v)

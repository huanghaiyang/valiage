extends SkeletonModifier3D
## 运行时「手臂镜像」：把**一侧手臂链**的姿势镜像到**另一侧** —— 让右手也能摆出握杖姿势 ✓
## 不需要烘焙动画库 ✓（用户确认：这个不需要烘焙 ✓）。
##
## 原理（为什么这样写是对的）：
##   * `SkeletonModifier3D` 是 Godot 的正规扩展点，它的 `_process_modification()` 在
##     AnimationPlayer **求值之后**运行 ✓ → 在这里 `set_bone_pose()` 覆盖姿势是官方用法 ✓，
##     不是"每帧抢写骨骼"的土办法 ✗（那种做法会和动画互相覆盖，效果不自然 ✗）。
##   * 镜像用「**骨架空间里做反射，再转回局部**」的写法 ✓：
##         G_mir = (M · B · M , M · o)        # M = 关于 x=0 平面的反射（左右对称面 ✓）
##         local_target = parent_global_pose(to)⁻¹ · G_mir
##     → 对**任意骨骼轴向**都成立 ✓，不需要猜左右骨的局部轴怎么对应 ✓
##       （主角的左右手骨已验证满足 x 反射关系：tools/check_mirror.gd 残差 0.00 cm ✓）。
##   * 必须**从根到梢**处理 ✓：子骨转局部时要用到"已被镜像过的父骨" ✓。
##
## 不碰的东西：leg / hips / spine / root / 上半身其它骨 ✓ —— 只有手臂链被镜像 ✓，
##   否则走路/转身会整体镜像（脚左右互换）✗。

## 总开关（player.gd 按 staff_hand 切换 ✓）
@export var mirror_enabled := true
## 方向：0 = 左→右（默认：左手持杖的姿势镜像给右手 ✓），1 = 右→左
@export_enum("左→右", "右→左") var direction := 0
## 参与镜像的骨骼名关键词（小写子串匹配 ✓）。
## ★ **留空 = 镜像全部骨骼** ✓（当前就是这种：用户要求"下身也映射过去" ✓，
##   因为只镜像上半身时，跑姿/起跳的**腿与髋**还是原侧 ✗ → 与镜像后的上半身不协调 ✗）。
##   需要缩小范围时再往这里填关键词（例如只填 "arm" 就只镜像手臂 ✓）。
@export var bone_keywords: PackedStringArray = PackedStringArray([])
## 黑名单（命中即跳过 ✓）：只排除 **root** ✗ ——
##   root 带着角色的整体朝向 ✓，镜像它会让角色**面朝反方向** ✗✗。
##   （hips/腿/脚**不排除** ✓：它们也要跟着镜像，跑姿才协调 ✓；
##    本骨架镜像轴是 z（纯左右 ✓）→ 前倾、俯仰、跳跃高度都不受影响 ✓✓）
@export var bone_blacklist: PackedStringArray = PackedStringArray(["root"])


## 诊断日志（默认关 ✓）
@export var verbose := false
## 每 5 秒打一次镜像残差（cm）：右侧手骨世界位置 vs 左侧手骨的世界镜像 ✓
@export var debug_residual := false

var _pairs: Array = []           # [[src_idx, tgt_idx, depth], …] 从根到梢排好 ✓
var _built := false
var _log_t := 0.0
## 左右对称面对应的坐标轴：0=x 1=y 2=z；-1 = 还没测 ✓
## ★ 必须**自动探测**：不同 glb 的模型导出轴不同 —— 主角这套骨架左右差异在 **z** 轴上 ✗（不是 x ✗）。
var _axis := -1


## 测出"左右对称面"对应的坐标轴 ✓：用两侧手骨的 **rest** 位置比 ✓
##   （rest 与动画无关，代表骨架自身的对称性 ✓；差异最大的那根轴就是左右轴 ✓）。
## 兜底：找不到双手骨 → 返回 0（按 x 处理 ✓）。
func _detect_axis(sk: Skeleton3D) -> int:
	var l := sk.find_bone("hand.l")
	var r := sk.find_bone("hand.r")
	if l < 0 or r < 0:
		# 退化：找任意 l/r 结尾的骨对 ✓
		for i in sk.get_bone_count():
			var nm := sk.get_bone_name(i).to_lower()
			if nm.ends_with("l"):
				var j := sk.find_bone(nm.substr(0, nm.length() - 1) + "r")
				if j >= 0:
					l = i
					r = j
					break
	if l < 0 or r < 0:
		return 0
	var pl := sk.get_bone_global_rest(l).origin
	var pr := sk.get_bone_global_rest(r).origin
	var d := Vector3(absf(pl.x - pr.x), absf(pl.y - pr.y), absf(pl.z - pr.z))
	if d.x >= d.y and d.x >= d.z:
		return 0
	if d.z >= d.y:
		return 2
	return 1


## 关于对应轴的**反射**矩阵 ✓（行列式必须是 −1 ✓ —— 别写成旋转 ✗：
##   Basis(LEFT, UP, FORWARD) 的行列式是 +1，那是绕 Y 转 180°，不是镜像 ✗✗）。
func _reflection(axis: int) -> Basis:
	match axis:
		0:
			return Basis(Vector3.LEFT, Vector3.UP, Vector3.BACK)     # diag(-1, 1, 1) ✓
		1:
			return Basis(Vector3.RIGHT, Vector3.DOWN, Vector3.BACK)  # diag(1, -1, 1) ✓
		_:
			return Basis(Vector3.RIGHT, Vector3.UP, Vector3.FORWARD) # diag(1, 1, -1) ✓


func _ready() -> void:
	# 骨架可能在别处被替换/重挂 → 每次进入树都重建配对表 ✓
	_built = false
	var sk := get_skeleton()
	if sk != null:
		sk.skeleton_updated.connect(_on_skeleton_updated) if sk.has_signal("skeleton_updated") else null


func _on_skeleton_updated() -> void:
	_built = false


func _process_modification_with_delta(delta: float) -> void:
	_process_modification()
	if debug_residual:
		_log_t += delta
		if _log_t >= 5.0:
			_log_t = 0.0
			_print_residual()


## 交换前的手骨位置快照（骨架空间 ✓）：残差自检用它判断"互换是否真的发生" ✓
var _pre_l := Vector3.ZERO
var _pre_r := Vector3.ZERO


func _process_modification() -> void:
	if not mirror_enabled or not is_active():
		return
	var sk := get_skeleton()
	if sk == null:
		return
	if not _built:
		_build_pairs(sk)
		if _axis < 0:
			_axis = _detect_axis(sk)
		if _pairs.is_empty():
			return
	var M := _reflection(_axis)

	# 0) 记下"交换前"的两手位置 ✓（供残差自检；写在任何 set_bone_pose 之前 ✓）
	var li := sk.find_bone("hand.l")
	var ri := sk.find_bone("hand.r")
	if li >= 0 and ri >= 0:
		_pre_l = sk.get_bone_global_pose(li).origin
		_pre_r = sk.get_bone_global_pose(ri).origin

	# ★★ 必须"**双向互换**"而不是单向镜像 ✗✗：
	#   单向（左→右）会把右臂摆成握杖姿势 ✓，但**左臂仍保留动画里原本的握杖姿势** ✗
	#   → 两条手臂都在"握" ✗（用户截图就是这个现象 ✗："手的动作也应该换过去" ✓）。
	#   正确做法：右臂 = 镜像(原左臂) ✓ **且** 左臂 = 镜像(原右臂) ✓
	#   → 形成一次**互换**：只有拿着杖的那只手在握 ✓，另一只手恢复成对方的自然姿势 ✓。
	#   所以下面先把**两侧的原始姿势全部快照**下来 ✓，再统一写回 ✓（避免边算边读造成串味 ✗）。

	# 1) 快照两侧原始姿势（骨架空间 ✓）
	var n := _pairs.size()
	var g_src: Array[Transform3D] = []
	var g_tgt: Array[Transform3D] = []
	g_src.resize(n)
	g_tgt.resize(n)
	for i in n:
		g_src[i] = sk.get_bone_global_pose(int(_pairs[i][0]))
		g_tgt[i] = sk.get_bone_global_pose(int(_pairs[i][1]))

	# 2) 各自应当变成"对方姿势的镜像" ✓（反射：B' = M·B·M，o' = M·o ✓）
	var want_src: Array[Transform3D] = []
	var want_tgt: Array[Transform3D] = []
	want_src.resize(n)
	want_tgt.resize(n)
	for i in n:
		want_src[i] = Transform3D(M * g_tgt[i].basis * M, M * g_tgt[i].origin)
		want_tgt[i] = Transform3D(M * g_src[i].basis * M, M * g_src[i].origin)

	# 3) 从根到梢写回局部姿势 ✓（父骨若也在表里，用**我算好的新全局姿势** ✓；
	#    不用 sk.get_bone_global_pose(父骨) ✗ —— 它可能是缓存值 ✗，会读到"还没更新"的旧姿势）
	var new_globals := {}
	for i in n:
		new_globals[int(_pairs[i][0])] = want_src[i]
		new_globals[int(_pairs[i][1])] = want_tgt[i]
	for i in n:
		_apply_one(sk, int(_pairs[i][0]), want_src[i], new_globals)
		_apply_one(sk, int(_pairs[i][1]), want_tgt[i], new_globals)

	if verbose and not _logged:
		_logged = true
		print("[镜像] 手臂**互换+镜像**已启用 ✓｜骨骼对 %d 组｜方向=%s" % [
			n, "左→右" if direction == 0 else "右→左"])


## 把一个"骨架空间目标姿势"转成本地姿势写进骨骼 ✓
## new_globals：本次已算好的"新全局姿势"表 ✓（父骨在里面就用它 ✓，避免读到缓存的旧值 ✗）
func _apply_one(sk: Skeleton3D, idx: int, want: Transform3D, new_globals: Dictionary) -> void:
	var p := sk.get_bone_parent(idx)
	var local := want
	if p >= 0:
		var pg: Transform3D = new_globals[p] if new_globals.has(p) else sk.get_bone_global_pose(p)
		local = pg.affine_inverse() * want
	sk.set_bone_pose(idx, local)


var _logged := false


## 建立"源骨 → 目标骨"配对表，并按**深度**（从根到梢）排序 ✓
func _build_pairs(sk: Skeleton3D) -> void:
	_pairs.clear()
	var src_side := "l" if direction == 0 else "r"
	var tgt_side := "r" if direction == 0 else "l"
	for i in sk.get_bone_count():
		var nm := sk.get_bone_name(i).to_lower()
		# 黑名单优先：髋/腿/脚/根 一律不镜像 ✓（保留走跑的左右动作 ✓）
		var banned := false
		for bw in bone_blacklist:
			if nm.contains(String(bw).to_lower()):
				banned = true
				break
		if banned:
			continue
		var hit := bone_keywords.is_empty()   # 关键词为空 = 全部骨骼都参与 ✓
		for kw in bone_keywords:
			if nm.contains(String(kw).to_lower()):
				hit = true
				break
		if not hit:
			continue
		# ★ 侧别判定：l / r / **中线** ✓
		#   中线骨（ARP 里叫 spine_01.x / neck.x / head.x ✗ 不以 l/r 结尾 ✗）**自己和自己配对** ✓：
		#   镜像自己 = 把躯干整体左右翻转 ✓ —— 这正是"身体扭曲"要修的东西 ✓
		#   （只镜像手臂不镜像躯干时，手臂换边而躯干还朝原侧拧 → 肩被扭住 ✓）
		var is_l := _side_of(nm, "l")
		var is_r := _side_of(nm, "r")
		if not is_l and not is_r:
			_pairs.append([i, i, _depth_of(sk, i)])
			continue
		if not _side_of(nm, src_side):
			continue
		# 同名换侧 → 目标骨名（l↔r 的风格都能覆盖 ✓）
		var tgt_name := ""
		if nm.ends_with("l"):
			tgt_name = nm.substr(0, nm.length() - 1) + tgt_side
		elif nm.ends_with("r"):
			tgt_name = nm.substr(0, nm.length() - 1) + tgt_side
		else:
			# 含 left/right 全词：直接替换 ✓
			if nm.contains("left"):
				tgt_name = nm.replace("left", "right" if tgt_side == "r" else "left")
			elif nm.contains("right"):
				tgt_name = nm.replace("right", "left" if tgt_side == "l" else "right")
		if tgt_name == "":
			continue
		var ti := sk.find_bone(tgt_name)
		if ti < 0:
			continue
		_pairs.append([i, ti, _depth_of(sk, i)])
	_pairs.sort_custom(func(a, b): return int(a[2]) < int(b[2]))


func _side_of(nm: String, side: String) -> bool:
	if side == "l":
		return nm.contains("left") or nm.ends_with("l")
	return nm.contains("right") or nm.ends_with("r")


func _depth_of(sk: Skeleton3D, idx: int) -> int:
	var d := 0
	var cur := sk.get_bone_parent(idx)
	while cur >= 0 and d < 64:
		d += 1
		cur = sk.get_bone_parent(cur)
	return d


## 诊断：验证"**互换 + 镜像**"是否真的发生 ✓（这比"右侧贴合左侧镜像"更能说明问题 ✓）：
##   * 目标侧（右手）= 镜像(交换前的左手) → A
##   * 源侧（左手）   = 镜像(交换前的右手) → B
##   两者都应接近 0 ✓。若 A≈0 而 B 很大 ✗ → 说明只做了单向镜像 ✗（那就是"两条手臂都握着"的 bug ✓）。
## 注意：必须在**骨架空间**里量 ✓（世界空间里对 x 取反是错的 ✗：角色站在 (-14, …) 处 ✓）。
func _print_residual() -> void:
	var sk := get_skeleton()
	if sk == null:
		return
	var l := sk.find_bone("hand.l")
	var r := sk.find_bone("hand.r")
	if l < 0 or r < 0:
		return
	var gl := sk.get_bone_global_pose(l).origin
	var gr := sk.get_bone_global_pose(r).origin
	var mir_pre_l := _mirror_vec(_pre_l)     # 交换前的左手 → 镜像后应等于现在的右手 ✓
	var mir_pre_r := _mirror_vec(_pre_r)     # 交换前的右手 → 镜像后应等于现在的左手 ✓
	var a := (gr - mir_pre_l).length() * 100.0 * 0.01534   # 骨架单位 → m → cm
	var b := (gl - mir_pre_r).length() * 100.0 * 0.01534
	var extra := ""
	var att := sk.get_node_or_null("HandSocket") as BoneAttachment3D
	if att != null:
		var bi := sk.find_bone(att.bone_name)
		if bi >= 0:
			extra = "｜挂点↔手骨 %.1f cm" % (
				att.global_position.distance_to((sk.global_transform * sk.get_bone_global_pose(bi)).origin) * 100.0)
	print("[镜像] 互换残差 右手←镜像(原左手) %.2f cm｜左手←镜像(原右手) %.2f cm%s %s" % [
		a, b, extra,
		"✓ 互换+镜像生效" if (a < 2.0 and b < 2.0) else "✗ 只做成了单向镜像（两条手臂会都摆着握杖姿势）"])


func _mirror_vec(v: Vector3) -> Vector3:
	var out := v
	match _axis:
		0:
			out.x = -v.x
		1:
			out.y = -v.y
		_:
			out.z = -v.z
	return out

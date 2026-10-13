extends SceneTree
## 校验"左右手骨骼互为镜像"（左右手切换持杖功能的前提假设）：
##   分别取两侧手骨的"拳心"（当前姿势下四指 16 个关节的平均位置，换算成**手骨本地坐标**），
##   检查 right ≈ mirror_local(left)（x 反号、y/z 基本一致）。
##
## 用法：godot --headless --path <项目> --script res://tools/check_mirror.gd
## 输出：两侧拳心、镜像残差（cm）、结论 ✓/✗
##
## 为什么需要它：CharacterProfile.mirror_local() 用的是"ARP/Mixamo 左右手骨 X 轴相反"这一**常见约定**，
## 不是所有骨架都成立 —— 换角色/换骨架后跑一次，就能确认该约定是否还成立。

const MODEL := "res://assets/models/characters/主角.glb"
const JOINT_SEGS := ["1_base", "1", "2", "3"]
const FINGERS := ["index", "middle", "ring", "pinky"]


func _find_skeleton(n: Node) -> Skeleton3D:
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is Skeleton3D:
			return cur as Skeleton3D
		for c in cur.get_children():
			stack.append(c)
	return null


## 拳心 + 手骨本地换算：返回 [拳心(骨内), 采样点数, 手骨世界位置]
func _fist_local(sk: Skeleton3D, bone: String) -> Array:
	var hi := sk.find_bone(bone)
	if hi < 0:
		return [Vector3.ZERO, 0, Vector3.ZERO]
	var low := bone.to_lower()
	var side := "r" if (low.contains("right") or low.ends_with("r")) else "l"
	var hg := sk.get_bone_global_pose(hi)
	var hxf := sk.global_transform * hg
	var sum := Vector3.ZERO
	var n := 0
	for f in FINGERS:
		for seg in JOINT_SEGS:
			var bi := sk.find_bone("%s%s.%s" % [f, seg, side])
			if bi < 0:
				continue
			sum += sk.global_transform * sk.get_bone_global_pose(bi).origin
			n += 1
	if n == 0:
		return [Vector3.ZERO, 0, hxf.origin]
	var c := sum / float(n)
	return [hxf.basis.inverse() * (c - hxf.origin), n, hxf.origin]


func _initialize() -> void:
	print("=== 左右手镜像校验 ===")
	if not ResourceLoader.exists(MODEL):
		print("✗ 找不到模型 %s" % MODEL)
		quit()
		return
	var scene: PackedScene = load(MODEL)
	var root := scene.instantiate()
	# 需要入树后骨骼姿态才有效（rest 也行：本校验比的是**绑定姿势**下的几何关系）
	root.visible = false
	get_root().add_child(root)
	var sk := _find_skeleton(root)
	if sk == null:
		print("✗ 模型里没有 Skeleton3D")
		quit()
		return
	# 找左右手骨名（只认含 hand 且侧别明确的）
	var bl := ""
	var br := ""
	for i in sk.get_bone_count():
		var nm := sk.get_bone_name(i).to_lower()
		if not nm.contains("hand"):
			continue
		var is_l := nm.contains("left") or nm.ends_with("l")
		var is_r := nm.contains("right") or nm.ends_with("r")
		if is_l and bl == "":
			bl = sk.get_bone_name(i)
		if is_r and br == "":
			br = sk.get_bone_name(i)
	print("左手骨 = %s｜右手骨 = %s" % [bl if bl != "" else "✗ 未找到", br if br != "" else "✗ 未找到"])
	if bl == "" or br == "":
		quit()
		return
	var a: Array = _fist_local(sk, bl)
	var b: Array = _fist_local(sk, br)
	var fl: Vector3 = a[0]
	var fr: Vector3 = b[0]
	var mir := Vector3(-fl.x, fl.y, fl.z)          # 镜像（x 反号）
	var mm := (fr - mir).length() * 100.0          # 残差（cm）
	var sc := 0.01534                              # 角色缩放（模型单位 → 米）
	print("左手拳心（骨内）%s｜右手拳心（骨内）%s" % [
		str(fl.snapped(Vector3(0.001, 0.001, 0.001))), str(fr.snapped(Vector3(0.001, 0.001, 0.001)))])
	print("镜像期望        %s" % str(mir.snapped(Vector3(0.001, 0.001, 0.001))))
	print("残差 %.2f cm（阈值 1.5 cm）→ %s" % [
		mm, "✓ 镜像关系成立（左右手切换可用）" if mm < 1.5 * 0.01 / sc else "✗ 镜像关系不成立（需按骨架调整 mirror_local）"])
	quit()

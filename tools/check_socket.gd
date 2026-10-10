extends SceneTree

## 右手挂点诊断：挂点有没有真的跟着手骨？法杖世界尺寸对不对？
##   复刻 player.gd 的装配（缩放 / 动画库 / 挂点 / HeldStaff），播一段动画后对比：
##   * 手骨世界位置 vs 挂点世界位置（BoneAttachment3D 应该 ≈ 重合）
##   * 法杖世界高度（应 ≈ 1.45 × 1.5/1.7 ≈ 1.28 m）

const CharProfile := preload("res://scripts/character_profile.gd")
const HeldStaffScript := preload("res://scripts/held_staff.gd")

var _tgt: Node3D
var _skel: Skeleton3D
var _ap: AnimationPlayer
var _socket: Node3D
var _staff: Node3D
var _k := 0
var _hand_idx := -1


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _world_aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array[Node] = [n]
	while not stack.is_empty():
		var cur: Node = stack.pop_back()
		if cur is VisualInstance3D and not (cur is BoneAttachment3D):
			var b := _xform((cur as VisualInstance3D).get_aabb(), (cur as Node3D).global_transform)
			out = b if first else out.merge(b)
			first = false
		for c in cur.get_children():
			stack.append(c)
	return out


func _xform(a: AABB, xf: Transform3D) -> AABB:
	var o := AABB(xf * a.position, Vector3.ZERO)
	for i in 8:
		o = o.expand(xf * (a.position + Vector3(
			a.size.x if (i & 1) else 0.0, a.size.y if (i & 2) else 0.0, a.size.z if (i & 4) else 0.0)))
	return o


func _initialize() -> void:
	var prof := CharProfile.get_profile("forest")
	var ps: PackedScene = load(String(prof["scene"]))
	_tgt = ps.instantiate()
	root.add_child(_tgt)
	var raw := CharProfile.measure_height(ps)
	_tgt.scale = Vector3.ONE * (float(prof["height"]) / raw)
	_ap = _find(_tgt, "AnimationPlayer") as AnimationPlayer
	if _ap == null:
		_ap = AnimationPlayer.new()
		_ap.name = "AnimPlayer"
		_tgt.add_child(_ap)
	var lib: AnimationLibrary = load(String(prof["lib"]))
	if lib != null:
		_ap.add_animation_library("", lib)
	_skel = _find(_tgt, "Skeleton3D") as Skeleton3D
	_socket = CharProfile.find_hand(_tgt, prof["hand_bones"])
	print("① 挂点：%s（%s）｜模型缩放 %.5f" % [
		_socket.name if _socket != null else "找不到 ✗",
		_socket.get_class() if _socket != null else "-", _tgt.scale.x])
	if _skel != null:
		# 按挂点自己的骨骼比对（挂点可能在左手或右手）
		var bn_want := "hand.r"
		if _socket is BoneAttachment3D:
			bn_want = (_socket as BoneAttachment3D).bone_name
		_hand_idx = _skel.find_bone(bn_want)
		print("   比对骨骼 = %s（索引 %d）" % [bn_want, _hand_idx])
		var bn := "?"
		if _socket is BoneAttachment3D:
			bn = "%s（bone_idx=%d）" % [(_socket as BoneAttachment3D).bone_name, (_socket as BoneAttachment3D).bone_idx]
		print("   BoneAttachment3D.bone_name = %s｜骨骼 hand.r 索引 = %d" % [bn, _hand_idx])
	if _socket == null:
		quit()
		return
	_staff = HeldStaffScript.new()
	_staff.name = "HeldStaff"
	_staff.position = Vector3.ZERO
	_staff.rotation_degrees = Vector3.ZERO
	_staff.set("len_scale", float(prof["height"]) / 1.7)
	_socket.add_child(_staff)
	# 装备一根真实的法杖（跟游戏一致：id/元素取自 StaffSystem）
	var sys := root.get_node_or_null("/root/StaffSystem")
	var sid := "fantasy_3"
	var elem := 0
	if sys != null:
		sid = String(sys.get("equipped"))
		elem = int(sys.get("equipped_element"))
	_staff.call("set_staff", sid, elem)
	print("   已装备法杖 id=%s（元素 %d）" % [sid, elem])
	_ap.play("Standard Walk")


func _process(_d: float) -> bool:
	_k += 1
	if _k < 20:
		return false
	var hand_gp := Vector3.ZERO
	if _skel != null and _hand_idx >= 0:
		hand_gp = _skel.global_transform * _skel.get_bone_global_pose(_hand_idx).origin
	var sock_gp := _socket.global_position
	var d := hand_gp.distance_to(sock_gp)
	print("② 手骨世界位置 %s" % str(hand_gp.snapped(Vector3(0.001, 0.001, 0.001))))
	print("   挂点世界位置 %s｜距离 %.4f m → %s" % [
		str(sock_gp.snapped(Vector3(0.001, 0.001, 0.001))), d,
		"绑上了 ✓（含掌心偏移）" if d < 0.15 else "没跟上手骨 ✗（BoneAttachment3D 有问题）"])
	var box := _world_aabb(_staff)
	print("③ 法杖世界包围盒：高 %.3f m｜中心 %s｜中心到挂点 %.3f m" % [
		box.size.y, str(box.get_center().snapped(Vector3(0.001, 0.001, 0.001))),
		box.get_center().distance_to(sock_gp)])
	print("   期望世界高 ≈ %.2f m（1.45 × 1.5/1.7）→ %s" % [
		1.45 * 1.5 / 1.7, "OK ✓" if absf(box.size.y - 1.45 * 1.5 / 1.7) < 0.25 else "偏差过大 ✗"])
	print("【结论】%s" % ("挂点跟手 ✓（偏移 = 掌心位置，属预期）" if d < 0.15 else "挂点没绑上 ✗"))
	return true

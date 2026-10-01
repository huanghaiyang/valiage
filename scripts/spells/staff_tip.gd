@tool
extends RefCounted
## 从**法杖模型本身**算出"杖头（喷火口）"的世界位置 —— 不写死任何坐标。
##
## 为什么必须读模型：法杖有大有小（staff_system 里每根都有 scale / world_len），
## 拿固定偏移的话，小杖会喷在杖身中间、大杖会喷在杖外。
##
## 优先级：
##   1) 持有脚本自己提供了 _head_local()（held_staff.gd L151 就有）-> 直接用它 + 模型缩放
##   2) 兜底：把模型里所有 MeshInstance3D 的世界包围盒合起来，取"离握持点最远的那个端面中心"
##      —— 这个对所有法杖都成立，且完全是数据驱动。

const HOLD_FALLBACK_RATIO := 0.25     ## 握持点大约在杖长的这个比例处（只在没法拿握持点时用）


## 返回杖头的世界坐标。holder 一般是"挂法杖的那个节点"（HeldStaff）。
static func tip_global(holder: Node3D) -> Vector3:
	if holder == null or not is_instance_valid(holder):
		return Vector3.ZERO
	var model := _find_model(holder)
	if model == null:
		return holder.global_position

	# 1) 模型自身提供的"杖头局部坐标"（held_staff.gd 里有）
	if holder.has_method("_head_local"):
		var hl: Variant = holder.call("_head_local")
		if hl is Vector3:
			var s := _model_world_scale(holder, model)
			# _head_local() 是"模型局部单位"里的位置；乘上缩放再转到世界
			return model.global_transform * ((hl as Vector3) * s)
	# 2) 兜底：世界包围盒的最远端
	return _tip_from_aabb(holder, model)


## 杖头的朝向（法杖自身 +Y 方向的世界向量）；喷火按它喷
static func tip_forward(holder: Node3D) -> Vector3:
	var model := _find_model(holder)
	if model == null:
		return (holder.global_transform.basis * Vector3.UP).normalized()
	# 模型局部 +Y = 杖尖方向（held_staff 的 _head_local 也是按 +Y 算的）
	return (model.global_transform.basis * Vector3.UP).normalized()


## 杖头的"有效长度"（世界单位）—— 给粒子用，保证不同大小的杖喷出的火柱比例一致
static func tip_length(holder: Node3D) -> float:
	var model := _find_model(holder)
	if model == null:
		return 1.0
	var ab := _merged_aabb(holder, model)
	var l := maxf(ab.size.y, maxf(ab.size.x, ab.size.z))
	return maxf(0.05, l)


# ---------------------------------------------------------------- 内部

static func _find_model(holder: Node3D) -> Node3D:
	# held_staff.gd 把模型放在 _model；拿不到就找第一个带 MeshInstance3D 的子树
	var v: Variant = holder.get("_model")
	if v is Node3D:
		return v as Node3D
	var stack: Array = [holder]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			return (n as MeshInstance3D).get_parent() as Node3D if n.get_parent() is Node3D else null
		for c in n.get_children():
			stack.append(c)
	return null


static func _model_world_scale(holder: Node3D, model: Node3D) -> float:
	# 用"世界变换 vs 局部变换"的缩放比，把模型局部单位换成世界单位
	var lm := model.transform.basis.get_scale().x
	var wm := model.global_transform.basis.get_scale().x
	if lm < 0.000001:
		return 1.0
	return wm / lm


## 把 holder 子树里所有 MeshInstance3D 的世界 AABB 合并
static func _merged_aabb(holder: Node3D, model: Node3D) -> AABB:
	var out := AABB()
	var first := true
	var stack: Array = [model]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var ab := mi.mesh.get_aabb()
			for i in range(8):
				var w: Vector3 = mi.global_transform * ab.get_endpoint(i)
				if first:
					out = AABB(w, Vector3.ZERO)
					first = false
				else:
					out = out.expand(w)
		for c in n.get_children():
			stack.append(c)
	if first:
		return AABB(holder.global_position, Vector3.ONE * 0.1)
	return out


## 取包围盒里"离握持点最远的那一端"的中心当杖头
static func _tip_from_aabb(holder: Node3D, model: Node3D) -> Vector3:
	var ab := _merged_aabb(holder, model)
	var hold := holder.global_position
	var low_c := Vector3(ab.get_center().x, ab.position.y, ab.get_center().z)
	var high_c := Vector3(ab.get_center().x, ab.end.y, ab.get_center().z)
	if hold.distance_to(high_c) >= hold.distance_to(low_c):
		return high_c
	return low_c
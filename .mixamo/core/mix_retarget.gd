extends RefCounted

## Mixamo → 任意人形角色 的重定向内核（实验版，供 .mixamo 下的驱动脚本 preload 使用）
##   1) 支持一个 FBX 里有多条动画
##   2) 多条动画汇总成一份 AnimationLibrary
##   3) 只依赖"语义槽位"映射，任何角色都能用（换角色只需重建映射）
##   4) 自动按身高/髋高比缩放位移 + 自动对齐朝向（yaw）

# ------------------------------------------------------------------ 槽位表
# src: 源（Mixamo / 通用）可能的名字；tgt: 目标（Auto-Rig Pro 导出链优先）可能的名字
const SLOTS := {
	"root": {"src": ["root", "Reference", "Armature"], "tgt": ["c_traj", "root.x", "root", "Root"]},
	"hips": {"src": ["hips", "pelvis"], "tgt": ["root.x", "hips", "Hips", "pelvis"]},
	"spine": {"src": ["spine", "spine1", "spine_01"], "tgt": ["spine_01.x", "spine", "Spine", "spine_01"]},
	"chest": {"src": ["spine2", "chest", "upperchest"], "tgt": ["spine_03.x", "spine_02.x", "chest", "Chest", "UpperChest"]},
	"neck": {"src": ["neck"], "tgt": ["neck.x", "neck", "Neck"]},
	"head": {"src": ["head"], "tgt": ["head.x", "head", "Head"]},
	"shoulder_l": {"src": ["leftshoulder", "shoulder.l", "clavicle.l"], "tgt": ["shoulder.l", "shoulder_l", "LeftShoulder"]},
	"upperarm_l": {"src": ["leftarm", "upperarm.l", "upper_arm.l"], "tgt": ["arm_stretch.l", "upperarm.l", "upper_arm.l", "LeftArm"]},
	"lowerarm_l": {"src": ["leftforearm", "lowerarm.l", "forearm.l"], "tgt": ["forearm_stretch.l", "lowerarm.l", "forearm.l", "LeftForeArm"]},
	"hand_l": {"src": ["lefthand", "hand.l"], "tgt": ["hand.l", "LeftHand", "hand_l"]},
	"shoulder_r": {"src": ["rightshoulder", "shoulder.r", "clavicle.r"], "tgt": ["shoulder.r", "shoulder_r", "RightShoulder"]},
	"upperarm_r": {"src": ["rightarm", "upperarm.r", "upper_arm.r"], "tgt": ["arm_stretch.r", "upperarm.r", "upper_arm.r", "RightArm"]},
	"lowerarm_r": {"src": ["rightforearm", "lowerarm.r", "forearm.r"], "tgt": ["forearm_stretch.r", "lowerarm.r", "forearm.r", "RightForeArm"]},
	"hand_r": {"src": ["righthand", "hand.r"], "tgt": ["hand.r", "RightHand", "hand_r"]},
	"upperleg_l": {"src": ["leftupleg", "upperleg.l", "thigh.l", "upper_leg.l"], "tgt": ["thigh_stretch.l", "upperleg.l", "thigh.l", "LeftUpLeg"]},
	"lowerleg_l": {"src": ["leftleg", "lowerleg.l", "shin.l"], "tgt": ["leg_stretch.l", "lowerleg.l", "shin.l", "LeftLeg"]},
	"foot_l": {"src": ["leftfoot", "foot.l"], "tgt": ["foot.l", "LeftFoot"]},
	"toes_l": {"src": ["lefttoebase", "toes.l", "toe.l", "ball.l"], "tgt": ["toes_01.l", "toes.l", "toe.l", "LeftToeBase"]},
	"upperleg_r": {"src": ["rightupleg", "upperleg.r", "thigh.r", "upper_leg.r"], "tgt": ["thigh_stretch.r", "upperleg.r", "thigh.r", "RightUpLeg"]},
	"lowerleg_r": {"src": ["rightleg", "lowerleg.r", "shin.r"], "tgt": ["leg_stretch.r", "lowerleg.r", "shin.r", "RightLeg"]},
	"foot_r": {"src": ["rightfoot", "foot.r"], "tgt": ["foot.r", "RightFoot"]},
	"toes_r": {"src": ["righttoebase", "toes.r", "toe.r", "ball.r"], "tgt": ["toes_01.r", "toes.r", "toe.r", "RightToeBase"]},
}

const CONTROL_WORDS := ["ik", "pole", "ctrl", "control", "helper", "nub", "traj", "bend",
	"roll", "twist", "stretch", "offset", "shape", "picker", "target", "master", "ref", "mch"]

## 归一化：小写、去掉 . _ - 空格，剥掉 "mixamorig:" / "mixamorig_" / "Armature|" 之类前缀
static func normalize(bone_name: String) -> String:
	var s := bone_name.to_lower()
	var cut := 0
	for i in s.length():
		var c := s[i]
		if c == ":" or c == "|":
			cut = i + 1
	if cut > 0 and cut < s.length():
		s = s.substr(cut)
	s = s.replace("mixamorig_", "").replace("mixamorig", "")
	var out := ""
	for i in s.length():
		var c := s[i]
		if c == "." or c == "_" or c == "-" or c == " " or c == ":" or c == "|":
			continue
		out += c
	return out

static func match_slot(bone_name: String) -> Dictionary:
	var n := normalize(bone_name)
	if n == "":
		return {}
	for slot in SLOTS:
		var aliases: Array = SLOTS[slot]["src"]
		for i in aliases.size():
			if normalize(String(aliases[i])) == n:
				return {"slot": slot, "rank": i}
	return {}

static func looks_like_control(name: String) -> bool:
	var n := normalize(name)
	for w in CONTROL_WORDS:
		if n.contains(w):
			return true
	return false

static func target_aliases(slot: String) -> Array:
	return SLOTS[slot]["tgt"] if SLOTS.has(slot) else []

# ------------------------------------------------------------------ 映射

static func build_mapping(src_skel: Skeleton3D, tgt_skel: Skeleton3D) -> Dictionary:
	var tgt_index := {}
	for i in tgt_skel.get_bone_count():
		var k := normalize(tgt_skel.get_bone_name(i))
		if not tgt_index.has(k):
			tgt_index[k] = i
	var out := {}
	var used := {}
	for si in src_skel.get_bone_count():
		var m := match_slot(src_skel.get_bone_name(si))
		if m.is_empty():
			continue
		for alias in target_aliases(String(m["slot"])):
			var k := normalize(String(alias))
			if tgt_index.has(k) and not used.has(int(tgt_index[k])):
				out[si] = int(tgt_index[k])
				used[int(tgt_index[k])] = true
				break
	return out

# ------------------------------------------------------------------ 尺寸 / 朝向

static func skeleton_height(skel: Skeleton3D) -> float:
	if skel == null or skel.get_bone_count() == 0:
		return 0.0
	var lo := INF
	var hi := -INF
	for i in skel.get_bone_count():
		var y: float = skel.get_bone_global_rest(i).origin.y
		lo = minf(lo, y)
		hi = maxf(hi, y)
	return maxf(0.0, hi - lo) if lo < INF else 0.0

static func bone_y(skel: Skeleton3D, names: PackedStringArray) -> float:
	for n in names:
		var i := skel.find_bone(n)
		if i >= 0:
			return skel.get_bone_global_rest(i).origin.y
	return 0.0

## 水平朝向：脚 → 脚趾
static func forward_of(skel: Skeleton3D, foot: String, toe: String) -> Vector3:
	var fi := skel.find_bone(foot)
	var ti := skel.find_bone(toe)
	if fi < 0 or ti < 0:
		return Vector3.ZERO
	var d: Vector3 = skel.get_bone_global_rest(ti).origin - skel.get_bone_global_rest(fi).origin
	d.y = 0.0
	return d.normalized()

## 找出骨骼里第一个名字匹配的（支持 Mixamo 的 mixamorig_ 前缀）
static func find_bone_like(skel: Skeleton3D, want: String) -> int:
	var w := normalize(want)
	for i in skel.get_bone_count():
		if normalize(skel.get_bone_name(i)) == w:
			return i
	return -1

# ------------------------------------------------------------------ 烘焙

const MAX_KEYS := 1200

## 把 src_ap 里的每条动画重定向到目标骨架，返回 {"library", "clips", "report"}
## opts: sample_fps, pos_scale_mode("auto"/"height"/"none"), height_ratio, yaw_offset_deg, skip_static
static func bake(src_ap: AnimationPlayer, src_skel: Skeleton3D, tgt_skel: Skeleton3D,
		mapping: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var fps: float = maxf(1.0, float(opts.get("sample_fps", 30.0)))
	var yaw_b := Basis(Vector3.UP, deg_to_rad(float(opts.get("yaw_offset_deg", 0.0))))
	var skip_static := bool(opts.get("skip_static", true))
	var path_prefix := String(opts.get("path_prefix", "Skeleton3D"))

	# 源 / 目标 rest
	var src_n := src_skel.get_bone_count()
	var tgt_n := tgt_skel.get_bone_count()
	var src_parent := PackedInt32Array(); src_parent.resize(src_n)
	var src_rest_local: Array[Transform3D] = []
	var src_rest_global: Array[Transform3D] = []
	for i in src_n:
		src_parent[i] = src_skel.get_bone_parent(i)
		src_rest_local.append(src_skel.get_bone_rest(i))
		src_rest_global.append(src_skel.get_bone_global_rest(i))
	var tgt_parent := PackedInt32Array(); tgt_parent.resize(tgt_n)
	var tgt_rest_local: Array[Transform3D] = []
	var tgt_rest_global: Array[Transform3D] = []
	for i in tgt_n:
		tgt_parent[i] = tgt_skel.get_bone_parent(i)
		tgt_rest_local.append(tgt_skel.get_bone_rest(i))
		tgt_rest_global.append(tgt_skel.get_bone_global_rest(i))

	var order_src := _topo(src_skel)
	var order_tgt := _topo(tgt_skel)
	var src_of_tgt := {}
	for si in mapping.keys():
		src_of_tgt[int(mapping[si])] = int(si)

	# 位移缩放
	var pos_scale := 1.0
	var mode := String(opts.get("pos_scale_mode", "auto"))
	if mode == "height":
		pos_scale = float(opts.get("height_ratio", 1.0))
	elif mode == "auto":
		for si in mapping.keys():
			if String(match_slot(src_skel.get_bone_name(int(si))).get("slot", "")) != "hips":
				continue
			var sy := src_rest_global[int(si)].origin.y
			var ty := tgt_rest_global[int(mapping[si])].origin.y
			if absf(sy) > 0.0001:
				pos_scale = ty / sy
			break

	var lib := AnimationLibrary.new()
	var clips: Array = []
	var skipped: Array = []
	for lname in src_ap.get_animation_library_list():
		var slab: AnimationLibrary = src_ap.get_animation_library(lname)
		for an in slab.get_animation_list():
			var src_anim: Animation = slab.get_animation(an)
			var clip_name := String(an)
			if lname != "" and lname != "default":
				clip_name = "%s/%s" % [String(lname), String(an)]
			if src_anim.get_track_count() == 0 or src_anim.get_length() <= 0.0:
				continue
			# 只保留源里被映射骨骼的轨道，并判断是否"静止 take"
			var rots := {}      # 被映射的源骨骼 -> 轨道（用于静止判定 / 是否输出位移）
			var poss := {}
			var rots_all := {}  # 源动画的**全部**骨骼轨道：姿态链必须完整，否则未映射的中间骨骼会丢失旋转
			var poss_all := {}
			for ti in src_anim.get_track_count():
				var bn := String(src_anim.track_get_path(ti).get_concatenated_subnames())
				var bi := src_skel.find_bone(bn)
				if bi < 0:
					continue
				var is_rot := src_anim.track_get_type(ti) == Animation.TYPE_ROTATION_3D
				var is_pos := src_anim.track_get_type(ti) == Animation.TYPE_POSITION_3D
				if is_rot:
					rots_all[bi] = ti
				elif is_pos:
					poss_all[bi] = ti
				if not mapping.has(bi):
					continue
				if is_rot:
					rots[bi] = ti
				elif is_pos:
					poss[bi] = ti
			if rots.is_empty():
				skipped.append("%s（没有可用骨骼轨道）" % clip_name)
				continue
			# 静止判定：所有旋转轨道在整段里的最大变化量
			var motion := 0.0
			for bi in rots.keys():
				var ti: int = int(rots[bi])
				var kc := src_anim.track_get_key_count(ti)
				if kc < 2:
					continue
				var q0: Quaternion = src_anim.rotation_track_interpolate(ti, src_anim.track_get_key_time(ti, 0))
				var m := 0.0
				for k in kc:
					var q: Quaternion = src_anim.rotation_track_interpolate(ti, src_anim.track_get_key_time(ti, k))
					m = maxf(m, rad_to_deg(absf(q0.angle_to(q))))
				motion = maxf(motion, m)
			if skip_static and motion < 0.5:
				skipped.append("%s（静止，最大变化 %.2f°）" % [clip_name, motion])
				continue

			var n_samples := int(ceil(src_anim.get_length() * fps)) + 1
			var step := maxi(1, int(ceil(float(n_samples) / float(MAX_KEYS))))
			var times := PackedFloat32Array()
			var t := 0.0
			while t <= src_anim.get_length() + 0.0001:
				times.append(t)
				t += float(step) / fps
			var n_s := times.size()
			if n_s < 2:
				continue

			var out_anim := Animation.new()
			out_anim.set_length(src_anim.get_length())
			out_anim.set_loop_mode(src_anim.loop_mode)
			var rot_keys := {}
			var pos_keys := {}
			for ti in src_of_tgt.keys():
				rot_keys[ti] = []
				pos_keys[ti] = []

			var g_s: Array[Transform3D] = []; g_s.resize(src_n)
			var g_t: Array[Transform3D] = []; g_t.resize(tgt_n)
			for ti in src_of_tgt.keys():
				rot_keys[ti] = []
				pos_keys[ti] = []

			for k in n_s:
				var tt: float = times[k]
				# 源：只覆盖有轨道的骨骼，其余保持 rest
				for bi in src_n:
					var local: Transform3D = src_rest_local[bi]
					if rots_all.has(bi):
						local.basis = Basis(src_anim.rotation_track_interpolate(int(rots_all[bi]), tt))
					if poss_all.has(bi):
						local.origin = src_anim.position_track_interpolate(int(poss_all[bi]), tt)
					g_s[bi] = local
				for bi in order_src:
					var pp := src_parent[bi]
					if pp >= 0:
						g_s[bi] = g_s[pp] * g_s[bi]
				# 目标
				for ti in order_tgt:
					var pt := tgt_parent[ti]
					var pg := Transform3D.IDENTITY
					if pt >= 0:
						pg = g_t[pt]
					var local2: Transform3D = tgt_rest_local[ti]
					if src_of_tgt.has(ti):
						var si: int = int(src_of_tgt[ti])
						var d_src: Basis = g_s[si].basis * src_rest_global[si].basis.inverse()
						var want: Basis = yaw_b * d_src * tgt_rest_global[ti].basis
						local2.basis = (pg.basis.inverse() * want).orthonormalized()
						if poss.has(si):
							var delta: Vector3 = g_s[si].origin - src_rest_global[si].origin
							var want_o: Vector3 = tgt_rest_global[ti].origin + yaw_b * delta * pos_scale
							local2.origin = pg.affine_inverse() * want_o
							(pos_keys[ti] as Array).append(local2.origin)
					g_t[ti] = pg * local2
					if src_of_tgt.has(ti):
						(rot_keys[ti] as Array).append(local2.basis)

			for ti in src_of_tgt.keys():
				var bname := tgt_skel.get_bone_name(int(ti))
				var rt := out_anim.add_track(Animation.TYPE_ROTATION_3D)
				out_anim.track_set_path(rt, NodePath(path_prefix + ":" + bname))
				out_anim.track_set_interpolation_type(rt, Animation.INTERPOLATION_LINEAR)
				var keys: Array = rot_keys[ti]
				var prev := Quaternion.IDENTITY
				for k in keys.size():
					var q := Quaternion((keys[k] as Basis))
					if k > 0 and q.dot(prev) < 0.0:
						q = Quaternion(-q.x, -q.y, -q.z, -q.w)
					out_anim.rotation_track_insert_key(rt, times[k], q)
					prev = q
				var pk: Array = pos_keys[ti]
				if pk.size() == n_s:
					var pt2 := out_anim.add_track(Animation.TYPE_POSITION_3D)
					out_anim.track_set_path(pt2, NodePath(path_prefix + ":" + bname))
					out_anim.track_set_interpolation_type(pt2, Animation.INTERPOLATION_LINEAR)
					for k in pk.size():
						out_anim.position_track_insert_key(pt2, times[k], pk[k])
			lib.add_animation(StringName(clip_name), out_anim)
			clips.append({
				"name": clip_name, "length": src_anim.get_length(),
				"frames": n_s, "tracks": out_anim.get_track_count(), "motion": motion,
			})
	return {"library": lib, "clips": clips, "skipped": skipped,
		"pos_scale": pos_scale, "mapping_size": mapping.size()}


static func _topo(skel: Skeleton3D) -> PackedInt32Array:
	var n := skel.get_bone_count()
	var depth := PackedInt32Array(); depth.resize(n)
	for i in n:
		var d := 0
		var p := skel.get_bone_parent(i)
		while p >= 0:
			d += 1
			p = skel.get_bone_parent(p)
		depth[i] = d
	var idx: Array = []
	for i in n:
		idx.append(i)
	idx.sort_custom(func(a, b): return depth[a] < depth[b])
	return PackedInt32Array(idx)

## 两只脚的平均朝向（单脚会带自然外八，平均后抵消）
static func forward_avg(skel: Skeleton3D, feet: PackedStringArray, toes: PackedStringArray) -> Vector3:
	var acc := Vector3.ZERO
	var n := 0
	for i in mini(feet.size(), toes.size()):
		var v := forward_of(skel, String(feet[i]), String(toes[i]))
		if v.length() > 0.5:
			acc += v
			n += 1
	return acc.normalized() if n > 0 else Vector3.ZERO

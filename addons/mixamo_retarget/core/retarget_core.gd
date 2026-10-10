@tool
class_name MixamoRetargetCore
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


# ------------------------------------------------------------------ 高层流程（面板用）

static func instantiate_scene(path: String) -> Node:
	var ps: PackedScene = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
	if ps == null:
		push_error("[MixamoRetarget] 无法加载场景：" + path)
		return null
	return ps.instantiate()


static func find_first(node: Node, cls: String) -> Node:
	if node.is_class(cls):
		return node
	for c in node.get_children():
		var r := find_first(c, cls)
		if r != null:
			return r
	return null


## 扫描目录下的动画源（fbx / glb / gltf）
static func scan_sources(dir: String) -> Dictionary:
	var out := {"files": [], "error": ""}
	if dir.begins_with("res://") and dir.get_file().begins_with("."):
		out["error"] = "以 . 开头的目录 Godot 不会扫描，请换成普通目录：" + dir
		return out
	var d := DirAccess.open(dir)
	if d == null:
		var abs_dir := ProjectSettings.globalize_path(dir)
		d = DirAccess.open(abs_dir)
	if d == null:
		out["error"] = "打不开目录：" + dir
		return out
	var files: Array = []
	for f in d.get_files():
		var lf := String(f).to_lower()
		if lf.ends_with(".fbx") or lf.ends_with(".glb") or lf.ends_with(".gltf"):
			files.append(dir.path_join(String(f)))
	files.sort()
	out["files"] = files
	return out


## 一键：把 src_dir 下所有源动画重定向到目标角色。
## 返回 {library, clips, skipped, mapping_size, measures, warnings, error}
static func bake_all(src_dir: String, tgt_scene_path: String, opts: Dictionary = {}, log := Callable()) -> Dictionary:
	var res := {"library": null, "clips": [], "skipped": [], "mapping_size": 0,
		"measures": {}, "warnings": [], "error": ""}
	var say := func(m: String) -> void:
		if log.is_valid():
			log.call(m)
	var scan := scan_sources(src_dir)
	if String(scan["error"]) != "":
		res["error"] = String(scan["error"])
		return res
	var files: Array = scan["files"]
	if opts.has("only_files"):
		files = opts["only_files"]
	if files.is_empty():
		res["error"] = "目录里没有 fbx/glb：" + src_dir
		return res
	var tgt_root := instantiate_scene(tgt_scene_path)
	if tgt_root == null:
		res["error"] = "目标场景加载失败：" + tgt_scene_path
		return res
	var tgt_skel := find_first(tgt_root, "Skeleton3D") as Skeleton3D
	if tgt_skel == null:
		tgt_root.free()
		res["error"] = "目标角色里没有 Skeleton3D：" + tgt_scene_path
		return res
	var path_prefix := String(opts.get("path_prefix", String(tgt_root.get_path_to(tgt_skel))))
	var tgt_hips := bone_y(tgt_skel, PackedStringArray(["root.x", "hips", "Hips"]))
	var master := AnimationLibrary.new()
	var mapping := {}
	var yaw_deg := 0.0
	var pos_scale := 1.0
	var seen_source := false

	for path in files:
		var ps: PackedScene = ResourceLoader.load(String(path), "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		if ps == null:
			(res["warnings"] as Array).append("加载失败（Godot 没导入？）：" + String(path).get_file())
			continue
		var sroot := ps.instantiate()
		var sskel := find_first(sroot, "Skeleton3D") as Skeleton3D
		var sap := find_first(sroot, "AnimationPlayer") as AnimationPlayer
		if sskel == null or sap == null:
			(res["warnings"] as Array).append("缺少骨架或动画：" + String(path).get_file())
			sroot.free()
			continue
		var base := String(path).get_file().get_basename()
		if not seen_source:
			seen_source = true
			mapping = build_mapping(sskel, tgt_skel)
			res["mapping_size"] = mapping.size()
			var src_hips := bone_y(sskel, PackedStringArray(["mixamorig_Hips", "Hips"]))
			var sf := forward_avg(sskel, PackedStringArray(["mixamorig_LeftFoot", "mixamorig_RightFoot", "LeftFoot", "RightFoot"]),
				PackedStringArray(["mixamorig_LeftToeBase", "mixamorig_RightToeBase", "LeftToeBase", "RightToeBase"]))
			var tf := forward_avg(tgt_skel, PackedStringArray(["foot.l", "foot.r"]), PackedStringArray(["toes_01.l", "toes_01.r"]))
			yaw_deg = rad_to_deg(sf.signed_angle_to(tf, Vector3.UP)) if sf.length() > 0.5 and tf.length() > 0.5 else 0.0
			pos_scale = tgt_hips / src_hips if absf(src_hips) > 0.0001 else 1.0
			res["measures"] = {
				"src_hips": src_hips, "tgt_hips": tgt_hips, "pos_scale": pos_scale,
				"src_height": skeleton_height(sskel), "tgt_height": skeleton_height(tgt_skel),
				"src_forward": sf, "tgt_forward": tf, "yaw_deg": yaw_deg,
				"src_bones": sskel.get_bone_count(), "tgt_bones": tgt_skel.get_bone_count(),
			}
			say.call("映射 %d 对｜髋高比 %.4f（源 %.3f → 目标 %.3f）｜自动 yaw %.1f°" % [
				mapping.size(), pos_scale, src_hips, tgt_hips, yaw_deg])
		var o := opts.duplicate()
		o["path_prefix"] = path_prefix
		o["yaw_offset_deg"] = (yaw_deg if bool(opts.get("auto_yaw", true)) else 0.0) + float(opts.get("yaw_offset_deg", 0.0))
		o["pos_scale_mode"] = String(opts.get("pos_scale_mode", "auto"))
		var r := bake(sap, sskel, tgt_skel, mapping, o)
		for s in r["skipped"]:
			(res["skipped"] as Array).append("%s：%s" % [base, String(s)])
		var lib: AnimationLibrary = r["library"]
		var clips: Array = r["clips"]
		for an in lib.get_animation_list():
			var nm := base if clips.size() == 1 else "%s/%s" % [base, String(an)]
			var uniq := nm
			var n := 2
			while master.has_animation(StringName(uniq)):
				uniq = "%s (%d)" % [nm, n]
				n += 1
			master.add_animation(StringName(uniq), lib.get_animation(an))
			var meta := {}
			for c in clips:
				if String(c["name"]) == String(an):
					meta = c
			(res["clips"] as Array).append({
				"name": uniq, "file": String(path).get_file(),
				"length": float(meta.get("length", 0.0)), "frames": int(meta.get("frames", 0)),
				"tracks": int(meta.get("tracks", 0)), "motion": float(meta.get("motion", 0.0)),
			})
		sroot.free()
	tgt_root.free()
	if String(res["error"]) == "" and master.get_animation_list().is_empty():
		res["error"] = "没有生成任何动画（源文件里没有可用动作？）"
	res["library"] = master
	res["yaw_deg"] = yaw_deg
	res["pos_scale"] = pos_scale
	return res


## 生成继承场景：角色 + AnimationPlayer + 动画库
static func save_scene(tgt_scene_path: String, lib_path: String, out_path: String, player := "AnimationPlayer") -> String:
	if not ResourceLoader.exists(tgt_scene_path):
		return "目标场景不存在：" + tgt_scene_path
	if not ResourceLoader.exists(lib_path):
		return "动画库不存在：" + lib_path
	var root := instantiate_scene(tgt_scene_path)
	if root == null:
		return "无法实例化目标场景"
	var root_name := String(root.name)
	root.free()
	var text := ""
	text += "[gd_scene load_steps=3 format=3]\n\n"
	text += "[ext_resource type=\"PackedScene\" path=\"%s\" id=\"1_char\"]\n" % tgt_scene_path
	text += "[ext_resource type=\"AnimationLibrary\" path=\"%s\" id=\"2_lib\"]\n\n" % lib_path
	text += "[node name=\"%s\" instance=ExtResource(\"1_char\")]\n\n" % root_name
	text += "[node name=\"%s\" type=\"AnimationPlayer\" parent=\".\" index=\"0\"]\n" % player
	text += "libraries = {\n&\"\": ExtResource(\"2_lib\")\n}\n"
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		return "无法写入 %s（错误码 %d）" % [out_path, FileAccess.get_open_error()]
	f.store_string(text)
	f.close()
	if Engine.is_editor_hint() and Engine.has_singleton("EditorInterface"):
		EditorInterface.get_resource_filesystem().update_file(out_path)
	return ""

## 侦察：列出目录里每个源文件包含的动画（名字/时长/轨道数/动作幅度/是否静止），不烘焙
static func inspect_sources(dir: String) -> Dictionary:
	var out := {"rows": [], "error": ""}
	var scan := scan_sources(dir)
	if String(scan["error"]) != "":
		out["error"] = String(scan["error"])
		return out
	for path in scan["files"]:
		var ps: PackedScene = ResourceLoader.load(String(path), "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
		var fname := String(path).get_file()
		if ps == null:
			(out["rows"] as Array).append({"file": fname, "clip": "", "error": "加载失败（Godot 还没导入这个文件）"})
			continue
		var sroot := ps.instantiate()
		var sap := find_first(sroot, "AnimationPlayer") as AnimationPlayer
		var sskel := find_first(sroot, "Skeleton3D") as Skeleton3D
		if sap == null:
			(out["rows"] as Array).append({"file": fname, "clip": "", "error": "没有 AnimationPlayer（没有动画）"})
			sroot.free()
			continue
		for lname in sap.get_animation_library_list():
			var lib: AnimationLibrary = sap.get_animation_library(lname)
			for an in lib.get_animation_list():
				var a: Animation = lib.get_animation(an)
				var motion := motion_score(a)
				var nm := String(an)
				if lname != "" and lname != "default":
					nm = "%s/%s" % [String(lname), String(an)]
				(out["rows"] as Array).append({
					"file": fname, "clip": nm, "length": a.get_length(), "tracks": a.get_track_count(),
					"motion": motion, "static": motion < 0.5,
					"bones": sskel.get_bone_count() if sskel != null else 0, "error": "",
				})
		sroot.free()
	return out


## 动作幅度（度）：所有旋转轨道里最大的角度变化；≈0 说明是静止 take
static func motion_score(a: Animation) -> float:
	var m := 0.0
	for ti in a.get_track_count():
		if a.track_get_type(ti) != Animation.TYPE_ROTATION_3D:
			continue
		var kc := a.track_get_key_count(ti)
		if kc < 2:
			continue
		var q0: Quaternion = a.rotation_track_interpolate(ti, a.track_get_key_time(ti, 0))
		for k in kc:
			var q: Quaternion = a.rotation_track_interpolate(ti, a.track_get_key_time(ti, k))
			m = maxf(m, rad_to_deg(absf(q0.angle_to(q))))
	return m

# ------------------------------------------------------------------ 增量更新

## 源文件的签名（大小 + 修改时间）
static func _file_sig(path: String) -> Dictionary:
	var fa := FileAccess.open(path, FileAccess.READ)
	var size := 0
	if fa != null:
		size = fa.get_length()
		fa.close()
	return {"size": size, "mtime": FileAccess.get_modified_time(path)}


## 增量更新：只烘焙「新增 / 改动」的源，已有的动画原样保留。
## 每个源的签名记在库自身的 metadata（mixamo_sources）里，所以只有一个 .tres 文件、不需要额外清单。
## 返回 {library, added, updated, skipped, removed, clips, measures, warnings, error}
static func bake_update(existing_lib_path: String, src_dir: String, tgt_scene_path: String,
		opts: Dictionary = {}, log := Callable()) -> Dictionary:
	var res := {"library": null, "added": [], "updated": [], "skipped": [], "removed": [],
		"clips": [], "measures": {}, "warnings": [], "error": ""}
	var say := func(m: String) -> void:
		if log.is_valid():
			log.call(m)
	var lib := AnimationLibrary.new()
	var manifest := {}
	if ResourceLoader.exists(existing_lib_path):
		var old: AnimationLibrary = ResourceLoader.load(existing_lib_path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
		if old != null:
			lib = old
			manifest = lib.get_meta("mixamo_sources", {})
			say.call("读入现有动画库：%d 条动画，已知源 %d 个" % [lib.get_animation_list().size(), manifest.size()])
	var scan := scan_sources(src_dir)
	if String(scan["error"]) != "":
		res["error"] = String(scan["error"])
		return res
	var files: Array = scan["files"]
	if files.is_empty():
		res["error"] = "目录里没有 fbx/glb：" + src_dir
		return res

	# 1) 先清理「源已不存在」的记录（可选）
	if bool(opts.get("prune_missing", false)):
		for key in manifest.keys().duplicate():
			var rec: Dictionary = manifest[key]
			if not FileAccess.file_exists(String(rec.get("path", ""))):
				for cn in rec.get("clips", []):
					if lib.has_animation(StringName(cn)):
						lib.remove_animation(StringName(cn))
				manifest.erase(key)
				(res["removed"] as Array).append(String(key))

	# 2) 判断哪些需要烘焙（新增 / 签名变了）
	var todo: Array = []
	for path in files:
		var key := String(path).get_file()
		var sig := _file_sig(String(path))
		var rec: Dictionary = manifest.get(key, {})
		if not rec.is_empty() and int(rec.get("size", -1)) == int(sig["size"]) and int(rec.get("mtime", -1)) == int(sig["mtime"]):
			(res["skipped"] as Array).append(key)
			continue
		todo.append(String(path))
		if rec.is_empty():
			(res["added"] as Array).append(key)
		else:
			(res["updated"] as Array).append(key)

	if not todo.is_empty():
		var o := opts.duplicate()
		o["only_files"] = todo
		var r := bake_all(src_dir, tgt_scene_path, o, log)
		if String(r["error"]) != "":
			res["error"] = String(r["error"])
			return res
		var new_lib: AnimationLibrary = r["library"]
		for c in r["clips"]:
			var cn := String(c["name"])
			var fkey := String(c["file"])
			var rec0: Dictionary = manifest.get(fkey, {})
			if (rec0.get("deleted", []) as Array).has(cn):
				if lib.has_animation(StringName(cn)):
					lib.remove_animation(StringName(cn))
				(res["skipped"] as Array).append("%s（手动删除过，跳过）" % cn)
				continue
			if lib.has_animation(StringName(cn)):
				lib.remove_animation(StringName(cn))
			lib.add_animation(StringName(cn), new_lib.get_animation(StringName(cn)))
			(res["clips"] as Array).append(c)
		for path in todo:
			var key := String(path).get_file()
			var names: Array = []
			for c in r["clips"]:
				if String(c["file"]) == key:
					names.append(String(c["name"]))
			var sig2 := _file_sig(String(path))
			var old_rec: Dictionary = manifest.get(key, {})
			manifest[key] = {"size": sig2["size"], "mtime": sig2["mtime"], "clips": names,
				"path": String(path), "deleted": old_rec.get("deleted", [])}
		res["measures"] = r["measures"]
		res["warnings"] = r["warnings"]

	lib.set_meta("mixamo_sources", manifest)
	res["library"] = lib
	return res

# ------------------------------------------------------------------ 目录提示 / 重复检测

## 粗略找出项目里"含动画源（fbx/glb/gltf）"的目录，用于提示用户该扫哪里
static func find_source_dirs(root_dir := "res://", max_depth := 3) -> Array:
	var out: Array = []
	_scan_dir_tree(root_dir, 0, max_depth, out)
	out.sort()
	return out


static func _scan_dir_tree(dir: String, depth: int, max_depth: int, out: Array) -> void:
	if depth > max_depth:
		return
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		var lf := String(f).to_lower()
		if lf.ends_with(".fbx") or lf.ends_with(".glb") or lf.ends_with(".gltf"):
			out.append(dir)
			break
	for sub in d.get_directories():
		var name := String(sub)
		if name.begins_with(".") or name.begins_with("addons"):
			continue
		_scan_dir_tree(dir.path_join(name), depth + 1, max_depth, out)


## 看起来是"副本"的源文件（同名 + copy / (1) …），提示会产生重复动画
static func likely_duplicates(files: Array) -> Array:
	var seen := {}
	var dups: Array = []
	for path in files:
		var base := String(path).get_file().get_basename().to_lower()
		var norm := base
		for suffix in [" copy", " (1)", "(1)", " (2)", "(2)", " - copy", "- copy", "_copy"]:
			norm = norm.replace(suffix, "")
		norm = norm.strip_edges()
		if seen.has(norm):
			dups.append("%s ↔ %s" % [String(seen[norm]).get_file(), String(path).get_file()])
		else:
			seen[norm] = path
	return dups

# ------------------------------------------------------------------ 动画删除

## 列出库里的动画（名字/时长/轨道数），按名字排序
static func list_clips(lib: AnimationLibrary) -> Array:
	var out: Array = []
	if lib == null:
		return out
	var arr: Array = []
	for an in lib.get_animation_list():
		arr.append(String(an))
	arr.sort()
	for nm in arr:
		var a: Animation = lib.get_animation(StringName(nm))
		out.append({"name": nm, "length": a.get_length(), "tracks": a.get_track_count()})
	return out


## 从库里删除指定动画；同时在它所属源的 deleted 列表里登记，
## 这样以后"增量更新"不会把它加回来（全量重建则会恢复）。
## 返回实际删除的条数。
static func delete_clips(lib: AnimationLibrary, names: PackedStringArray) -> int:
	if lib == null:
		return 0
	var manifest: Dictionary = lib.get_meta("mixamo_sources", {})
	var n := 0
	for nm in names:
		var cn := String(nm)
		if not lib.has_animation(StringName(cn)):
			continue
		for key in manifest.keys():
			var rec: Dictionary = manifest[key]
			var clips: Array = rec.get("clips", [])
			if clips.has(cn):
				var del: Array = rec.get("deleted", [])
				if not del.has(cn):
					del.append(cn)
				rec["deleted"] = del
				manifest[key] = rec
				break
		lib.remove_animation(StringName(cn))
		n += 1
	lib.set_meta("mixamo_sources", manifest)
	return n

# ------------------------------------------------------------------ 运行时场景

## 生成"运行时重定向"场景：角色 + MixRetarget 节点（节点自己实例化隐藏的 Mixamo 源，不需要 .tres）
static func save_runtime_scene(tgt_scene_path: String, src_dir: String, out_path: String,
		auto_yaw := true, pos_scale_mode := "auto") -> String:
	if not ResourceLoader.exists(tgt_scene_path):
		return "目标场景不存在：" + tgt_scene_path
	var root := instantiate_scene(tgt_scene_path)
	if root == null:
		return "无法实例化目标场景：" + tgt_scene_path
	var skel := find_first(root, "Skeleton3D") as Skeleton3D
	if skel == null:
		root.free()
		return "目标角色里没有 Skeleton3D：" + tgt_scene_path
	var skel_path := String(root.get_path_to(skel))
	var root_name := String(root.name)
	root.free()
	var text := ""
	text += "[gd_scene load_steps=3 format=3]\n\n"
	text += "[ext_resource type=\"PackedScene\" path=\"%s\" id=\"1_char\"]\n" % tgt_scene_path
	text += "[ext_resource type=\"Script\" path=\"res://addons/mixamo_retarget/runtime/mix_retarget_node.gd\" id=\"2_script\"]\n\n"
	text += "[node name=\"%s\" instance=ExtResource(\"1_char\")]\n\n" % root_name
	text += "[node name=\"MixRetarget\" type=\"Node3D\" parent=\".\"]\n"
	text += "script = ExtResource(\"2_script\")\n"
	text += "source_dir = \"%s\"\n" % src_dir
	text += "target_path = NodePath(\"../%s\")\n" % skel_path
	text += "auto_yaw = %s\n" % ("true" if auto_yaw else "false")
	text += "pos_scale_mode = \"%s\"\n" % pos_scale_mode
	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		return "无法写入 %s（错误码 %d）" % [out_path, FileAccess.get_open_error()]
	f.store_string(text)
	f.close()
	return ""

# ------------------------------------------------------------------ 对话框尺寸

## 宽而矮的对话框尺寸：尽量 1100×520，但不超过宿主窗口/屏幕（否则嵌入子窗口会被裁成又窄又高）
static func dialog_size(want := Vector2i(1100, 520), host: Node = null) -> Vector2i:
	var avail := Vector2i(1280, 720)
	var host_win: Window = null
	if host != null:
		host_win = host.get_window()
	if host_win != null and host_win.size.x > 200 and host_win.size.y > 200:
		avail = Vector2i(int(host_win.size.x * 0.88), int(host_win.size.y * 0.74))
	else:
		var r := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
		if r.size.x > 200 and r.size.y > 200:
			avail = Vector2i(int(r.size.x * 0.72), int(r.size.y * 0.72))
	var w := clampi(want.x, 660, maxi(660, avail.x))
	var h := clampi(want.y, 340, maxi(340, avail.y))
	if w < h * 3 / 2:                       # 保证"宽矮"：宽至少是高的 1.5 倍
		w = mini(maxi(660, avail.x), h * 3 / 2)
	return Vector2i(w, h)
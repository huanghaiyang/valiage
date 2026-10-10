extends SceneTree

## 带手指映射重新烘焙整库（替换 assets/animations/mixamo.tres，先备份）
## 目标：让手指骨骼真正跟随动画（此前只映射 21 个主骨骼 → 手一直张开）

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const SRC := "res://assets/mixamo"
const TGT := "res://assets/models/characters/森林男.glb"
const OUT := "res://assets/animations/mixamo.tres"
const BAK := "res://assets/animations/mixamo.tres.bak_prefingers"


func _log(msg: String) -> void:
	print("   " + msg)


func _initialize() -> void:
	var raw := FileAccess.get_file_as_bytes(OUT)
	if raw.size() > 0:
		var bf := FileAccess.open(BAK, FileAccess.WRITE)
		bf.store_buffer(raw)
		bf.close()
		print("已备份 → %s（%.0f KB）" % [BAK.get_file(), raw.size() / 1024.0])

	var r: Dictionary = Core.bake_all(SRC, TGT, {"sample_fps": 30.0, "in_place": true}, _log)
	if String(r["error"]) != "":
		print("✗ 烘焙失败：" + String(r["error"]))
		quit()
		return
	var lib: AnimationLibrary = r["library"]
	var m: Dictionary = r["measures"]
	print("映射 %d 对（骨骼 %d → %d）｜动画 %d 条" % [
		int(r["mapping_size"]), int(m["src_bones"]), int(m["tgt_bones"]),
		(r["clips"] as Array).size()])
	var err := ResourceSaver.save(lib, OUT)
	print("保存 → %s" % ("OK ✓" if err == OK else "失败 %d" % err))

	# 验证：手指轨道是否存在、是否真的在动
	var finger_tracks := 0
	var moved := 0.0
	var names := PackedStringArray()
	for an in lib.get_animation_list():
		var a: Animation = lib.get_animation(an)
		for ti in a.get_track_count():
			if a.track_get_type(ti) != Animation.TYPE_ROTATION_3D:
				continue
			var bn := String(a.track_get_path(ti).get_concatenated_subnames())
			for pre in ["index", "thumb", "middle", "ring", "pinky"]:
				if bn.begins_with(pre):
					finger_tracks += 1
					if names.size() < 8:
						names.append(bn)
					if String(an) == "Standard Walk" and bn == "index1_base.l":
						var kc := a.track_get_key_count(ti)
						if kc > 1:
							var q0: Quaternion = a.rotation_track_interpolate(ti, a.track_get_key_time(ti, 0))
							for k in kc:
								var q: Quaternion = a.rotation_track_interpolate(ti, a.track_get_key_time(ti, k))
								moved = maxf(moved, rad_to_deg(absf(q0.angle_to(q))))
					break
	print("手指旋转轨道 %d 条（示例：%s）" % [finger_tracks, ", ".join(names)])
	print("Standard Walk 里 left index1_base 最大变化 = %.1f° → %s" % [
		moved, "手指在动 ✓" if moved > 1.0 else "手指没动 ✗"])
	quit()

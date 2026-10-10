extends SceneTree

## 把库里动画的"自带水平位移"去掉（原地化）：髋(root.x)的水平 X/Z 锁成起始值，保留 Y 起伏。
## 为什么需要：Mixamo 下载时没勾 "In Place" → 髋部带了前向位移（Sword And Shield Run 约 2.04 m/循环），
## 播完循环会瞬间弹回，表现就是"前跑一段又退回"。
## 先备份原文件，再原地改写。

const P := "res://assets/animations/mixamo.tres"
const BAK := "res://assets/animations/mixamo.tres.bak_inplace"


func _initialize() -> void:
	var raw := FileAccess.get_file_as_bytes(P)
	if raw.size() == 0:
		print("✗ 读不到 " + P)
		quit()
		return
	var bf := FileAccess.open(BAK, FileAccess.WRITE)
	bf.store_buffer(raw)
	bf.close()
	print("已备份 → %s（%.0f KB）" % [BAK.get_file(), raw.size() / 1024.0])

	var lib: AnimationLibrary = ResourceLoader.load(P, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	if lib == null:
		print("✗ 载入失败")
		quit()
		return
	var fixed := 0
	for an in lib.get_animation_list():
		var a: Animation = lib.get_animation(an)
		for ti in a.get_track_count():
			if a.track_get_type(ti) != Animation.TYPE_POSITION_3D:
				continue
			var bn := String(a.track_get_path(ti).get_concatenated_subnames())
			if bn != "root.x" and bn != "hips" and bn != "Hips" and bn != "mixamorig_Hips":
				continue
			var kc := a.track_get_key_count(ti)
			if kc < 2:
				continue
			var first: Vector3 = a.position_track_interpolate(ti, a.track_get_key_time(ti, 0))
			var moved := 0
			for k in kc:
				var t := a.track_get_key_time(ti, k)
				var v: Vector3 = a.position_track_interpolate(ti, t)
				var nv := Vector3(first.x, v.y, first.z)
				if nv.distance_to(v) > 0.0005:
					a.position_track_insert_key(ti, t, nv)   # 同一时间点会覆盖
					moved += 1
			if moved > 0:
				fixed += 1
				print("  原地化 %-30s 调整 %d 键" % [String(an), moved])
	var err := ResourceSaver.save(lib, P)
	print("保存 → %s｜共 %d 条动画做了原地化" % ["OK" if err == OK else "失败 %d" % err, fixed])
	quit()

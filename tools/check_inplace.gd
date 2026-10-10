extends SceneTree

## 诊断：库里的动画在髋（root.x）上有没有**水平位移**（自带前向位移 → 循环时会"前跑一段又退回"）

const P := "res://assets/animations/mixamo.tres"

func _initialize() -> void:
	var lib: AnimationLibrary = ResourceLoader.load(P, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	if lib == null:
		print("读取失败")
		quit()
		return
	print("剪辑                                  水平位移范围（X/Z，模型单位）   垂直Y范围")
	for an in lib.get_animation_list():
		var a: Animation = lib.get_animation(an)
		for ti in a.get_track_count():
			if a.track_get_type(ti) != Animation.TYPE_POSITION_3D:
				continue
			var bn := String(a.track_get_path(ti).get_concatenated_subnames())
			if bn != "root.x" and bn != "hips" and bn != "Hips" and bn != "mixamorig_Hips":
				continue
			var mn := Vector3(INF, INF, INF)
			var mx := Vector3(-INF, -INF, -INF)
			for k in a.track_get_key_count(ti):
				var v: Vector3 = a.position_track_interpolate(ti, a.track_get_key_time(ti, k))
				mn = mn.min(v)
				mx = mx.max(v)
			var dx: float = mx.x - mn.x
			var dz: float = mx.z - mn.z
			print("%-34s X %7.2f  Z %7.2f  %s   Y %6.2f~%6.2f" % [
				String(an), dx, dz,
				"← 有水平位移 ✗" if maxf(dx, dz) > 0.5 else "原地 ✓",
				mn.y, mx.y])
			break
	quit()

extends SceneTree

## 量源 FBX 跳跃动画的"腾空窗口"：髋部 Y 高于站立基准的时间区间
## godot --headless --path <项目> --script res://tools/check_jump_window.gd

const SRC := "res://assets/mixamo/Standing Torch Jump.fbx"
const TAKES := ["mixamo_com"]


func _find(n: Node, cls: String) -> Node:
	if n.is_class(cls):
		return n
	for c in n.get_children():
		var r := _find(c, cls)
		if r != null:
			return r
	return null


func _initialize() -> void:
	var ps: PackedScene = load(SRC)
	if ps == null:
		print("✗ 载入失败")
		quit()
		return
	var m := ps.instantiate()
	var ap := _find(m, "AnimationPlayer") as AnimationPlayer
	if ap == null:
		print("✗ 没有 AnimationPlayer")
		m.free()
		quit()
		return
	for take in TAKES:
		if not ap.has_animation(take):
			continue
		var a: Animation = ap.get_animation(take)
		var ti := -1
		for i in a.get_track_count():
			if a.track_get_type(i) == Animation.TYPE_POSITION_3D \
					and String(a.track_get_path(i).get_concatenated_subnames()) == "mixamorig_Hips":
				ti = i
				break
		if ti < 0:
			print("✗ 没有髋部位置轨道")
			continue
		var dur := a.get_length()
		var base := a.position_track_interpolate(ti, 0.0).y
		print("=== %s / %s：时长 %.3f s｜站立基准 Y %.3f ===" % [SRC.get_file(), take, dur, base])
		var t0 := -1.0
		var t1 := -1.0
		var peak := -INF
		var peak_t := 0.0
		var n := 60
		for i in n + 1:
			var t := dur * float(i) / float(n)
			var y: float = a.position_track_interpolate(ti, t).y
			if y > peak:
				peak = y
				peak_t = t
			var air := y > base + 0.02
			if air and t0 < 0.0:
				t0 = t
			if air:
				t1 = t
			if i % 5 == 0:
				print("   t=%.3f  Y=%.3f  %s" % [t, y, "↑腾空" if air else ""])
		print("→ 腾空窗口 ≈ [%.3f, %.3f]（%.3f s）｜最高点 %.3f m @ %.3f s｜基准 %.3f" % [
			t0, t1, t1 - t0, peak - base, peak_t, base])
		print("  对比：物理滞空 2×6.5/18 = %.3f s｜动画全长 %.3f s" % [2.0 * 6.5 / 18.0, dur])
	m.free()
	quit()

extends SceneTree
## 最小解析检查：只确认几个关键脚本能不能被 Godot 编译。
## 为什么单独写：verify_flame_advance.gd 会继续跑一堆逻辑，
## 一旦某个依赖挂了会卡很久；这个脚本只做 load()，立刻出结果。
func _init() -> void:
	var files := [
		"res://scripts/spells/flame_advance.gd",
		"res://scripts/spells/spell_targeting.gd",
		"res://scripts/vfx/foliage_burn.gd",
		"res://scripts/ui/map_weather_overlay.gd",
	]
	var bad := 0
	for p in files:
		var s := load(p)
		# ★ 解析失败时 load() 仍会返回一个 GDScript 对象，所以必须看 can_instantiate()
		var ok := s != null and (s as GDScript).can_instantiate()
		if not ok:
			bad += 1
		print("  %s %s" % ["OK  " if ok else "FAIL", p])
	print("解析失败 %d / %d" % [bad, files.size()])
	quit(0 if bad == 0 else 1)

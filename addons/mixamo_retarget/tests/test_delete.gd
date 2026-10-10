extends SceneTree

## 删除动画自检
##   1) 用 2 个源烘焙一个临时库
##   2) 删除其中 1 条 → 库里少 1 条、清单记下 deleted
##   3) 篡改该源的签名（模拟"重新下载"）→ 增量更新
##      期望：被删的那条**不会回来**，同源的其它动画正常保留
##   4) 只写临时库 _selftest_del.tres，跑完删除

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const SRCDIR := "res://assets/mixamo"
const TGT := "res://assets/models/characters/森林男.glb"
const OUT := "res://assets/animations/_selftest_del.tres"


func _quiet(_m: String) -> void:
	pass


func _names(lib: AnimationLibrary) -> String:
	var s := PackedStringArray()
	for an in lib.get_animation_list():
		s.append(String(an))
	return ", ".join(s)


func _initialize() -> void:
	var abs_out := ProjectSettings.globalize_path(OUT)
	if FileAccess.file_exists(OUT):
		DirAccess.remove_absolute(abs_out)

	var scan := Core.scan_sources(SRCDIR)
	var files: Array = scan["files"]
	if files.size() < 2:
		print("✗ 源文件不足 2 个，无法测试：" + SRCDIR)
		quit()
		return
	var two: Array = [files[0], files[1]]
	print("用 %d 个源烘焙临时库：%s" % [two.size(), ", ".join(PackedStringArray([String(two[0]).get_file(), String(two[1]).get_file()]))])
	var r := Core.bake_all(SRCDIR, TGT, {"only_files": two}, _quiet)
	if String(r["error"]) != "":
		print("✗ 烘焙失败：" + String(r["error"]))
		quit()
		return
	var lib: AnimationLibrary = r["library"]
	ResourceSaver.save(lib, OUT)
	print("【1】烘出 %d 条：%s" % [lib.get_animation_list().size(), _names(lib)])
	var before := lib.get_animation_list().size()
	var victim := String(lib.get_animation_list()[0])
	var victim_file := ""
	var man1: Dictionary = lib.get_meta("mixamo_sources", {})
	for key in man1.keys():
		if (man1[key].get("clips", []) as Array).has(victim):
			victim_file = String(key)
			break

	# 2) 删除
	var lib2: AnimationLibrary = ResourceLoader.load(OUT, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	var n := Core.delete_clips(lib2, PackedStringArray([victim]))
	ResourceSaver.save(lib2, OUT)
	var man2: Dictionary = lib2.get_meta("mixamo_sources", {})
	var recorded := (man2.get(victim_file, {}).get("deleted", []) as Array).has(victim)
	print("【2】删除「%s」（属于 %s）：删了 %d 条 → 库内 %d 条（原 %d）｜清单登记 deleted=%s" % [
		victim, victim_file, n, lib2.get_animation_list().size(), before, recorded])

	# 3) 篡改签名 → 增量重烘该源
	var man3: Dictionary = lib2.get_meta("mixamo_sources", {})
	var rec: Dictionary = man3[victim_file]
	rec["mtime"] = 1
	man3[victim_file] = rec
	lib2.set_meta("mixamo_sources", man3)
	ResourceSaver.save(lib2, OUT)
	var r2 := Core.bake_update(OUT, SRCDIR, TGT, {"only_files": two}, _quiet)
	ResourceSaver.save(r2["library"], OUT)
	var lib3: AnimationLibrary = ResourceLoader.load(OUT, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
	var came_back := lib3.has_animation(StringName(victim))
	print("【3】篡改 %s 的签名后增量更新：更新 %s → 库内 %d 条｜被删的「%s」回来了吗 = %s" % [
		victim_file, r2["updated"], lib3.get_animation_list().size(), victim, came_back])
	print("     库内：%s" % _names(lib3))

	var ok := (lib3.get_animation_list().size() == before - 1) and not came_back and recorded and n == 1
	print("【结论】%s" % ("删除 + 增量不复活：OK ✓" if ok else "有问题 ✗"))
	DirAccess.remove_absolute(abs_out)
	print("（临时库已删除）")
	quit()

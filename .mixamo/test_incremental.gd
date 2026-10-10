extends SceneTree

## 增量更新自检（用真实 Mixamo 源，输出到临时库，不碰你的正式文件）
##   1) 首次全量
##   2) 增量·源没变  → 全部跳过
##   3) 增量·签名变了  → 只重烘那个源，且不产生重复动画
##   4) 库里没有清单（模拟你之前烘的那份）→ 重建但不重复
##   5) meta 是否写进 .tres（下次才能判断"没变"）

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const SRCDIR := "res://assets/models/mixamo"
const TGT := "res://assets/models/characters/森林男.glb"
const OUT := "res://assets/animations/_inc_test.tres"

func _quiet(_m: String) -> void:
	pass


func _names(r: Dictionary) -> String:
	var s := PackedStringArray()
	for c in r["clips"]:
		s.append(String(c["name"]))
	return ", ".join(s)


func _save(lib: AnimationLibrary) -> void:
	ResourceSaver.save(lib, OUT)


func _load_lib() -> AnimationLibrary:
	return ResourceLoader.load(OUT, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE) as AnimationLibrary


func _initialize() -> void:
	var abs_out := ProjectSettings.globalize_path(OUT)
	if FileAccess.file_exists(OUT):
		DirAccess.remove_absolute(abs_out)

	# 1) 首次全量
	var r1 := Core.bake_all(SRCDIR, TGT, {"sample_fps": 30.0}, _quiet)
	print("【1 首次全量】动画 %d 条：%s" % [r1["clips"].size(), _names(r1)])
	_save(r1["library"])
	print("     库内 %d 条" % (_load_lib().get_animation_list().size()))

	# 2) 增量·源没变 → 全部跳过
	var r2 := Core.bake_update(OUT, SRCDIR, TGT, {}, _quiet)
	var lib2 := _load_lib()
	print("【2 增量·没变】新增 %d｜更新 %d｜跳过 %d｜库内 %d 条（应仍为 5）" % [
		(r2["added"] as Array).size(), (r2["updated"] as Array).size(),
		(r2["skipped"] as Array).size(), lib2.get_animation_list().size()])

	# 3) 篡改某个源的签名 → 只重烘它
	var man: Dictionary = lib2.get_meta("mixamo_sources", {})
	var key: String = String(man.keys()[0])
	var rec: Dictionary = man[key]
	rec["mtime"] = 1
	man[key] = rec
	lib2.set_meta("mixamo_sources", man)
	_save(lib2)
	var r3 := Core.bake_update(OUT, SRCDIR, TGT, {}, _quiet)
	var lib3 := _load_lib()
	print("【3 签名变了】新增 %d｜更新 %s｜跳过 %d｜库内 %d 条（应仍为 5，且无重名）" % [
		(r3["added"] as Array).size(), r3["updated"], (r3["skipped"] as Array).size(),
		lib3.get_animation_list().size()])

	# 4) 库里没有清单（旧库）→ 全部当作新增重建，但不重复
	var lib4 := _load_lib()
	lib4.set_meta("mixamo_sources", {})
	_save(lib4)
	var r4 := Core.bake_update(OUT, SRCDIR, TGT, {}, _quiet)
	var lib5 := _load_lib()
	print("【4 无清单重建】新增 %d｜库内 %d 条（应仍为 5）" % [
		(r4["added"] as Array).size(), lib5.get_animation_list().size()])
	var dup := {}
	var has_dup := false
	for an in lib5.get_animation_list():
		if dup.has(String(an)):
			has_dup = true
		dup[String(an)] = true
	print("     重名检查：%s" % ("有重名 ✗" if has_dup else "无重名 ✓"))

	# 5) 清单是否写进 .tres
	var txt := FileAccess.get_file_as_string(OUT)
	print("【5】.tres 内含 mixamo_sources = %s" % txt.contains("mixamo_sources"))
	var man5: Dictionary = lib5.get_meta("mixamo_sources", {})
	print("     清单记录 %d 个源：%s" % [man5.size(), ", ".join(man5.keys())])

	DirAccess.remove_absolute(abs_out)
	print("【完成】（已删除临时库）")
	quit()

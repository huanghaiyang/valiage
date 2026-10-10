extends SceneTree

## 列出某个目录里插件能识别的动画源（用来确认"新下的动画有没有被看到"）
## 用法：改下面 DIR 为你放置 Mixamo 文件的目录，然后：
##   & "D:\godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path "D:\sgames\CozyVale" `
##     --script "res://addons/mixamo_retarget/tests/list_sources.gd"

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const DIR := "res://assets/mixamo"


func _initialize() -> void:
	print("目录：" + DIR)
	var scan := Core.scan_sources(DIR)
	if String(scan["error"]) != "":
		print("✗ " + String(scan["error"]))
		print("项目里含动画源的目录：")
		for d in Core.find_source_dirs("res://", 3):
			print("   " + String(d))
		quit()
		return
	var files: Array = scan["files"]
	print("找到 %d 个源文件：" % files.size())
	var ins := Core.inspect_sources(DIR)
	for r in ins["rows"]:
		if String(r.get("error", "")) != "":
			print("  %-28s %s" % [String(r["file"]), String(r["error"])])
		else:
			print("  %-28s %-24s %.2fs %d 轨道 幅度 %.1f° %s" % [
				String(r["file"]), String(r["clip"]), float(r["length"]), int(r["tracks"]),
				float(r["motion"]), "静止(跳过)" if bool(r["static"]) else "可用"])
	var dups := Core.likely_duplicates(files)
	print("疑似重复源：%d 对" % dups.size())
	for d in dups:
		print("  " + String(d))

	# 现有动画库的增量状态
	var lib_path := "res://assets/animations/mixamo.tres"
	if ResourceLoader.exists(lib_path):
		var lib: AnimationLibrary = ResourceLoader.load(lib_path, "AnimationLibrary", ResourceLoader.CACHE_MODE_IGNORE)
		var man: Dictionary = lib.get_meta("mixamo_sources", {}) if lib != null else {}
		print("现有库 %s：动画 %d 条，清单记录 %d 个源" % [
			lib_path.get_file(), lib.get_animation_list().size() if lib != null else 0, man.size()])
		var names := PackedStringArray()
		if lib != null:
			for an in lib.get_animation_list():
				names.append(String(an))
		print("  库里动画：" + ", ".join(names))
		var missing_from_manifest := PackedStringArray()
		for path in files:
			var key := String(path).get_file()
			var rec: Dictionary = man.get(key, {})
			var sig := Core._file_sig(String(path))
			if rec.is_empty():
				missing_from_manifest.append(key + "(新)")
			elif int(rec.get("size", -1)) != int(sig["size"]) or int(rec.get("mtime", -1)) != int(sig["mtime"]):
				missing_from_manifest.append(key + "(已改动)")
		if missing_from_manifest.size() > 0:
			print("  下次②会处理（新增/改动）：" + ", ".join(missing_from_manifest))
		else:
			print("  下次②没有需要处理的源（全部已是最新）")
	quit()
